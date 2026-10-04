defmodule SymphonyElixir.StrayProcessesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StrayProcesses
  alias SymphonyElixirWeb.ObservabilityPubSub

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:snapshot, _from, opts), do: {:reply, Keyword.fetch!(opts, :snapshot), opts}
  end

  setup do
    base = Path.join(System.tmp_dir!(), "stray-processes-#{System.unique_integer([:positive])}")
    root = Path.join(base, "workspaces")
    idle = Path.join([root, "symphony", "TP-1"])
    running = Path.join([root, "symphony", "TP-2"])
    qa_worktree = Path.join([root, ".qa", "symphony", "TP-3-0123456789ab"])
    claude_tmp_dir = Path.join(base, "tmp")
    claude_dir = Path.join(claude_tmp_dir, "claude-501")
    running_task_dir = Path.join(claude_dir, String.replace(running, ~r/[^a-zA-Z0-9]/, "-"))
    tmp_dir = Path.join(base, "tmpdir")
    prompt_dir = Path.join(tmp_dir, "symphony-claude-prompt.abc")

    for dir <- [idle, running, qa_worktree, running_task_dir, Path.join(claude_dir, "other"), prompt_dir], do: File.mkdir_p!(dir)
    File.write!(Path.join(tmp_dir, "symphony-notes.txt"), "")
    on_exit(fn -> File.rm_rf(base) end)

    write_watchdog!(root, 10)

    {:ok,
     root: root,
     idle: idle,
     running: running,
     qa_worktree: qa_worktree,
     claude_tmp_dir: claude_tmp_dir,
     claude_dir: claude_dir,
     running_task_dir: running_task_dir,
     tmp_dir: tmp_dir,
     prompt_dir: prompt_dir}
  end

  defp write_watchdog!(root, cpu_minutes, tick_interval_ms \\ 60_000) do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      watchdog: %{
        enabled: true,
        tick_interval_ms: tick_interval_ms,
        no_progress_threshold_ms: 600_000,
        stray_process_cpu_minutes: cpu_minutes
      }
    )
  end

  defp entry(pid, attrs) do
    Map.merge(%{pid: pid, ppid: 1, start_time: "Sun Oct  4 08:00:00 2026", cpu_time: "0:00.00", command: "sleep 600", cwd: "/"}, Map.new(attrs))
  end

  # A table that returns each result in `results` once, then repeats the last one.
  # A result that is a function is called instead, so it can block or raise.
  defp table(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)

    fn ->
      agent
      |> Agent.get_and_update(fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)
      |> case do
        result when is_function(result, 0) -> result.()
        result -> result
      end
    end
  end

  defp start_server(ctx, opts) do
    name = :"stray_processes_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          name: name,
          own_pid: 999_999,
          claude_tmp_dir: ctx.claude_tmp_dir,
          tmp_dirs: [ctx.tmp_dir],
          running_workspaces: fn -> {:ok, [ctx.running, ctx.qa_worktree]} end
        ],
        opts
      )
      |> Enum.reject(&match?({_key, nil}, &1))

    start_supervised!({StrayProcesses, opts}, id: name)
    name
  end

  test "flags a process over the threshold under a watched folder with no run attached", ctx do
    entries = [
      entry(101, command: "yes", cwd: ctx.idle, cpu_time: "10:01.00"),
      entry(102, cwd: ctx.running <> "/deps", cpu_time: "120:00.00"),
      entry(103, cwd: ctx.idle, cpu_time: "10:00.00"),
      entry(104, cwd: ctx.running_task_dir, cpu_time: "120:00.00"),
      entry(105, cwd: Path.join(ctx.claude_dir, "other"), cpu_time: "30:00.00"),
      entry(106, command: "node #{ctx.prompt_dir}/run.js", cpu_time: "1-00:00:00"),
      entry(107, cwd: "/Users/someone/elsewhere", cpu_time: "999:00.00"),
      entry(108, cwd: ctx.idle, cpu_time: "999:00.00"),
      entry(109, ppid: 108, cwd: ctx.idle, cpu_time: "999:00.00"),
      entry(110, cwd: ctx.qa_worktree, cpu_time: "999:00.00"),
      entry(111, cwd: ctx.idle, cpu_time: "bad"),
      entry(112, command: "tail -f #{ctx.tmp_dir}/symphony-notes.txt", cpu_time: "999:00.00")
    ]

    server = start_server(ctx, table: fn -> {:ok, entries} end, own_pid: 108)

    log = capture_log(fn -> assert [_, _, _] = StrayProcesses.check(server) end)

    assert StrayProcesses.warnings(server) == [
             %{pid: 106, start_time: "Sun Oct  4 08:00:00 2026", command: "node #{ctx.prompt_dir}/run.js", cwd: "/", cpu_time: "1-00:00:00", cpu_seconds: 86_400},
             %{pid: 105, start_time: "Sun Oct  4 08:00:00 2026", command: "sleep 600", cwd: Path.join(ctx.claude_dir, "other"), cpu_time: "30:00.00", cpu_seconds: 1_800},
             %{pid: 101, start_time: "Sun Oct  4 08:00:00 2026", command: "yes", cwd: ctx.idle, cpu_time: "10:01.00", cpu_seconds: 601}
           ]

    assert log =~ ~s(Process using CPU with no run attached pid=101 cwd=#{ctx.idle} cpu_time=10:01.00 command="yes")
    refute log =~ "pid=102"
  end

  test "clears a warning once the process is gone, logging and updating the dashboard on each change", ctx do
    yes = entry(101, command: "yes", cwd: ctx.idle, cpu_time: "11:00.00")
    later = %{yes | cpu_time: "12:00.00"}
    no_cwd = entry(102, command: "#{ctx.idle}/bin/spin", cwd: nil, cpu_time: "15:00.00")
    server = start_server(ctx, table: table([{:ok, [yes]}, {:ok, [later, no_cwd]}, {:ok, [later, no_cwd]}, {:ok, []}]))
    :ok = ObservabilityPubSub.subscribe()

    log =
      capture_log(fn ->
        assert [%{pid: 101, cpu_seconds: 660}] = StrayProcesses.check(server)
        assert_receive {:observability_updated, _}
        assert [%{pid: 102}, %{pid: 101, cpu_seconds: 720}] = StrayProcesses.check(server)
        assert_receive {:observability_updated, _}
        assert [_, _] = StrayProcesses.check(server)
        refute_receive {:observability_updated, _}, 50
        assert [] = StrayProcesses.check(server)
        assert_receive {:observability_updated, _}
      end)

    assert length(String.split(log, "Process using CPU with no run attached pid=101")) == 2
    assert log =~ "Process using CPU with no run attached pid=102 cwd=unknown cpu_time=15:00.00"
    assert log =~ ~s(Process no longer flagged as stray pid=101 command="yes")
    assert StrayProcesses.warnings(server) == []
  end

  test "keeps the previous warnings when the table or the runs can't be read, or the check crashes", ctx do
    yes = entry(101, command: "yes", cwd: ctx.idle, cpu_time: "11:00.00")
    {:ok, runs} = Agent.start_link(fn -> [{:ok, []}, {:error, :busy}] end)
    running_workspaces = fn -> Agent.get_and_update(runs, fn [next | rest] -> {next, rest ++ [next]} end) end
    crash = fn -> raise "table exploded" end
    tables = table([{:ok, [yes]}, {:ok, [yes]}, {:error, :denied}, crash])
    server = start_server(ctx, table: tables, running_workspaces: running_workspaces)

    log =
      capture_log(fn ->
        assert [%{pid: 101}] = StrayProcesses.check(server)
        assert [%{pid: 101}] = StrayProcesses.check(server)
        assert [%{pid: 101}] = StrayProcesses.check(server)
        assert [%{pid: 101}] = StrayProcesses.check(server)
      end)

    assert log =~ "Could not check for stray processes: :busy"
    assert log =~ "Could not check for stray processes: :denied"
    assert log =~ "Could not check for stray processes: {:check_crashed"
    assert StrayProcesses.warnings(server) == [%{pid: 101, start_time: yes.start_time, command: "yes", cwd: ctx.idle, cpu_time: "11:00.00", cpu_seconds: 660}]
  end

  test "asks the orchestrator and the QA runner for running workspaces only when a process is over the threshold", ctx do
    over = entry(101, command: "yes", cwd: ctx.idle, cpu_time: "11:00.00")
    attached = entry(102, cwd: ctx.running, cpu_time: "11:00.00")
    under = entry(103, cwd: ctx.idle, cpu_time: "1:00.00")
    missing = :"missing_orchestrator_#{System.unique_integer([:positive])}"
    opts = [running_workspaces: nil, orchestrator: missing, qa_runner: missing]

    quiet = start_server(ctx, Keyword.merge(opts, table: fn -> {:ok, [under]} end))
    unavailable = start_server(ctx, Keyword.merge(opts, table: fn -> {:ok, [over]} end))

    log =
      capture_log(fn ->
        assert [] = StrayProcesses.check(quiet)
        assert [] = StrayProcesses.check(unavailable)
      end)

    assert length(String.split(log, "Could not check for stray processes")) == 2
    assert log =~ "{:orchestrator_snapshot, :unavailable}"

    orchestrator = :"fake_orchestrator_#{System.unique_integer([:positive])}"
    snapshot = %{running: [%{workspace_path: ctx.running}, %{workspace_path: nil}]}
    start_supervised!({FakeOrchestrator, name: orchestrator, snapshot: snapshot})
    server = start_server(ctx, Keyword.merge(opts, table: fn -> {:ok, [over, attached]} end, orchestrator: orchestrator))

    assert [%{pid: 101}] = StrayProcesses.check(server)
  end

  test "flags nothing when the threshold is null", ctx do
    write_watchdog!(ctx.root, nil)
    server = start_server(ctx, table: fn -> {:ok, [entry(101, cwd: ctx.idle, cpu_time: "999:00.00")]} end)

    assert [] = StrayProcesses.check(server)
  end

  test "checks on every watchdog tick and runs one check at a time", ctx do
    test_pid = self()
    yes = entry(101, command: "yes", cwd: ctx.idle, cpu_time: "11:00.00")

    blocking = fn ->
      send(test_pid, {:table_read, self()})

      receive do
        :release -> {:ok, [yes]}
      end
    end

    server = start_server(ctx, table: table([blocking, {:ok, []}]))
    checker = Task.async(fn -> StrayProcesses.check(server) end)
    assert_receive {:table_read, reader}

    # A tick and a second caller during the check join it instead of starting another.
    send(server, :tick)
    second = Task.async(fn -> StrayProcesses.check(server) end)
    wait_until(fn -> match?(%{waiters: [_, _]}, :sys.get_state(server)) end)
    send(reader, :release)

    capture_log(fn ->
      assert [%{pid: 101}] = Task.await(checker)
      assert [%{pid: 101}] = Task.await(second)
    end)

    send(server, :unrelated)
    write_watchdog!(ctx.root, 10, 10)
    send(server, :tick)
    capture_log(fn -> wait_until(fn -> StrayProcesses.warnings(server) == [] end) end)
  end

  test "reads the configured process table and the default temp folders" do
    name = :"stray_processes_#{System.unique_integer([:positive])}"
    start_supervised!({StrayProcesses, name: name}, id: name)

    assert [] = StrayProcesses.check(name)
  end

  test "has no warnings when the server isn't running" do
    assert StrayProcesses.warnings(:"missing_stray_processes_#{System.unique_integer([:positive])}") == []
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
