defmodule SymphonyElixir.AgentRunnerLeftoverProcessesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LeftoverProcesses.Table

  defmodule BackgroundingAgent do
    # Coding-agent stand-in: its one turn runs the configured shell script in the
    # workspace, the way an agent backgrounds a command, and reports the pids it echoes.
    def start_session(workspace, _opts), do: {:ok, %{workspace: workspace}}

    def run_turn(%{workspace: workspace}, _prompt, _issue, _opts) do
      script = Application.get_env(:symphony_elixir, :leftover_agent_script, "true")
      {output, 0} = System.cmd("sh", ["-c", script], cd: workspace)
      pids = output |> String.split() |> Enum.map(&String.to_integer/1)
      send(Application.fetch_env!(:symphony_elixir, :leftover_agent_recipient), {:backgrounded, pids})
      {:ok, %{session_id: "sess-leftover"}}
    end

    def stop_session(_session), do: :ok
  end

  setup do
    Application.put_env(:symphony_elixir, :leftover_agent_recipient, self())
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-leftover-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "TP-367")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      workspace_root: test_root,
      max_turns: 1
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :leftover_agent_recipient)
      Application.delete_env(:symphony_elixir, :leftover_agent_script)
      File.rm_rf(test_root)
    end)

    %{test_root: test_root, workspace: workspace}
  end

  test "stops what the run left in its workspace, temp folder or Claude task folder when the run ends", %{test_root: test_root, workspace: workspace} do
    tmp_dir = Path.join(test_root, "tmp")
    task_dir = Path.join([tmp_dir, "claude-501", String.replace(workspace, ~r/[^a-zA-Z0-9]/, "-")])
    File.mkdir_p!(Path.join(task_dir, "tasks"))

    in_workspace = process(4101, workspace, "yes")
    in_task_dir = process(4102, "/", "zsh -c until [ -f never ]; do :; done 2>#{task_dir}/tasks/b1.output")
    unrelated = process(4103, System.tmp_dir!(), "sleep 1000")
    in_run_tmp_dir = process(4104, "/", "node #{hd(AgentRunner.tmp_dirs(workspace))}/server.js")
    test_pid = self()

    log =
      capture_log(fn ->
        run!(workspace,
          claude_tmp_dir: tmp_dir,
          leftover_processes: [
            table: fn -> {:ok, [in_workspace, in_task_dir, unrelated, in_run_tmp_dir]} end,
            signal: fn pid, signal -> send(test_pid, {:signal, pid, signal}) end,
            grace_ms: 0
          ]
        )
      end)

    for pid <- [4101, 4102, 4104], do: assert_received({:signal, ^pid, "TERM"})
    refute_received {:signal, 4103, _signal}
    assert log =~ "Stopping leftover process issue_id=issue-leftover issue_identifier=TP-367 pid=4101 cwd=#{workspace} cpu_time=165:01.23 command=\"yes\""
    assert log =~ "pid=4102 cwd=/"
  end

  test "leaves a remote worker's processes alone", %{workspace: workspace} do
    test_pid = self()

    assert :ok =
             run!(workspace,
               worker_host: "worker-a",
               leftover_processes: [
                 table: fn -> {:ok, [process(4201, workspace, "yes")]} end,
                 signal: fn pid, signal -> send(test_pid, {:signal, pid, signal}) end
               ]
             )

    assert_received {:backgrounded, []}
    refute_received {:signal, _pid, _signal}
  end

  describe "with the real process table" do
    @describetag :process_table

    test "a run that backgrounds `sleep 1000 &`, a nohup and a setsid variant leaves none of them running", %{workspace: workspace} do
      Application.put_env(:symphony_elixir, :leftover_agent_script, ~S"""
      sleep 1000 >/dev/null 2>&1 &
      echo $!
      nohup sleep 1000 >/dev/null 2>&1 &
      echo $!
      perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!"; exec "sleep", "1000"' >/dev/null 2>&1 &
      echo $!
      """)

      unrelated = detached_sleep(System.tmp_dir!())
      on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(unrelated)]) end)

      log = capture_log(fn -> run!(workspace, leftover_processes: [table: &Table.read/0, grace_ms: 2_000]) end)

      assert_received {:backgrounded, [_sleep, _nohup, _setsid] = pids}

      for pid <- pids do
        refute running?(pid)
        assert log =~ ~r/Stopping leftover process issue_id=issue-leftover issue_identifier=TP-367 pid=#{pid} cwd=\S+ cpu_time=\S+ command="sleep 1000"/
      end

      assert running?(unrelated)
      refute log =~ "pid=#{unrelated} "
    end
  end

  defp run!(workspace, opts) do
    defaults = [
      workspace_path: workspace,
      agent_module: BackgroundingAgent,
      issue_enricher: &{:ok, &1},
      issue_state_fetcher: fn _ids -> {:ok, [%{issue() | state: "Done"}]} end
    ]

    AgentRunner.run(issue(), nil, defaults ++ opts)
  end

  defp issue, do: %Issue{id: "issue-leftover", identifier: "TP-367", title: "Leave nothing running", state: "In Progress"}

  defp process(pid, cwd, command) do
    %{pid: pid, ppid: 1, start_time: "Sun Oct  4 01:00:00 2026", cpu_time: "165:01.23", command: command, cwd: cwd}
  end

  defp detached_sleep(cwd) do
    {output, 0} = System.cmd("sh", ["-c", "sleep 1000 >/dev/null 2>&1 &\necho $!"], cd: cwd)
    output |> String.trim() |> String.to_integer()
  end

  defp running?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_output, _status} -> false
    end
  end
end
