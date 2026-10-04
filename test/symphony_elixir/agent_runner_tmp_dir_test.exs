defmodule SymphonyElixir.AgentRunnerTmpDirTest do
  use SymphonyElixir.TestSupport

  defmodule TmpDirAgent do
    # Coding-agent stand-in: reports the session opts, writes a file to its `$TMPDIR` the way an
    # agent's command would, and waits for the test to end the turn.
    def start_session(workspace, opts), do: {:ok, %{workspace: workspace, opts: opts}}

    def run_turn(%{workspace: workspace, opts: opts}, _prompt, _issue, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :tmp_dir_agent_recipient)
      tmp_dir = opts[:extra_env] |> Map.values() |> List.first()
      written = tmp_dir && File.write(Path.join(tmp_dir, "scratch.txt"), workspace)
      send(recipient, {:turn, self(), workspace, opts, written})

      receive do
        {:end_turn, result} -> result
      end
    end

    def stop_session(_session), do: :ok
  end

  setup do
    Application.put_env(:symphony_elixir, :tmp_dir_agent_recipient, self())
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-tmp-dir-#{System.unique_integer([:positive])}")
    bases = [Path.join(test_root, "tmp")]
    File.mkdir_p!(hd(bases))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      workspace_root: test_root,
      agent_kind: "claude",
      max_turns: 1
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :tmp_dir_agent_recipient)
      File.rm_rf(test_root)
    end)

    %{test_root: test_root, bases: bases}
  end

  test "two concurrent runs each get a private, writable temp folder of their own, removed when they succeed", ctx do
    runs = for identifier <- ["TP-1", "TP-2"], do: start_run(ctx, identifier)
    turns = for _run <- runs, do: assert_receive({:turn, _pid, _workspace, _opts, _written}, 5_000)

    dirs =
      for {:turn, _pid, workspace, opts, written} <- turns do
        assert %{"CLAUDE_CODE_TMPDIR" => tmp_dir} = opts[:extra_env]
        assert [^tmp_dir] = AgentRunner.tmp_dirs(workspace, ctx.bases)
        assert tmp_dir in opts[:settings].workspace.sandbox.allow_write_paths
        assert written == :ok
        assert File.stat!(tmp_dir).access == :read_write
        assert Bitwise.band(File.stat!(tmp_dir).mode, 0o777) == 0o700
        tmp_dir
      end

    assert length(Enum.uniq(dirs)) == 2

    for {:turn, pid, _workspace, _opts, _written} <- turns, do: send(pid, {:end_turn, {:ok, %{session_id: "sess"}}})
    for run <- runs, do: assert(:ok = Task.await(run, 5_000))

    for tmp_dir <- dirs, do: refute(File.exists?(tmp_dir))
  end

  test "a failed run keeps its temp folder for debugging, and the next run starts with a fresh one", ctx do
    run = start_run(ctx, "TP-3")
    assert_receive {:turn, pid, _workspace, opts, :ok}, 5_000
    %{"CLAUDE_CODE_TMPDIR" => tmp_dir} = opts[:extra_env]

    log =
      capture_log(fn ->
        send(pid, {:end_turn, {:error, :boom}})
        assert {:raised, %RuntimeError{}} = Task.await(run, 5_000)
      end)

    assert File.read!(Path.join(tmp_dir, "scratch.txt")) =~ "TP-3"
    assert log =~ "Keeping the temp folder of a failed run for debugging issue_id=issue-TP-3 issue_identifier=TP-3 path=#{tmp_dir}"

    File.write!(Path.join(tmp_dir, "stale.txt"), "")
    rerun = start_run(ctx, "TP-3")
    assert_receive {:turn, pid, _workspace, _opts, :ok}, 5_000
    assert File.ls!(tmp_dir) == ["scratch.txt"]
    send(pid, {:end_turn, {:ok, %{session_id: "sess"}}})
    assert :ok = Task.await(rerun, 5_000)
  end

  test "a codex run gets the folder as TMPDIR", ctx do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      workspace_root: ctx.test_root,
      agent_kind: "codex",
      max_turns: 1
    )

    run = start_run(ctx, "TP-4")
    assert_receive {:turn, pid, workspace, opts, :ok}, 5_000
    assert opts[:extra_env] == %{"TMPDIR" => hd(AgentRunner.tmp_dirs(workspace, ctx.bases))}
    send(pid, {:end_turn, {:ok, %{session_id: "sess"}}})
    assert :ok = Task.await(run, 5_000)
  end

  test "a run that can't create a temp folder keeps the runtime's default", ctx do
    blocker = Path.join(ctx.test_root, "not-a-dir")
    File.write!(blocker, "")

    log =
      capture_log(fn ->
        run = start_run(ctx, "TP-5", agent_tmp_bases: [blocker])
        assert_receive {:turn, pid, _workspace, opts, nil}, 5_000
        assert opts[:extra_env] == %{}
        send(pid, {:end_turn, {:ok, %{session_id: "sess"}}})
        assert :ok = Task.await(run, 5_000)
      end)

    assert log =~ "Could not create a temp folder for issue_id=issue-TP-5 issue_identifier=TP-5"
  end

  test "a remote worker's run keeps its host's temp folder", ctx do
    run = start_run(ctx, "TP-6", worker_host: "worker-a")
    assert_receive {:turn, pid, _workspace, opts, nil}, 5_000
    assert opts[:extra_env] == %{}
    send(pid, {:end_turn, {:ok, %{session_id: "sess"}}})
    assert :ok = Task.await(run, 5_000)
    assert File.ls!(hd(ctx.bases)) == []
  end

  defp start_run(ctx, identifier, opts \\ []) do
    workspace = Path.join(ctx.test_root, identifier)
    File.mkdir_p!(workspace)
    issue = %Issue{id: "issue-#{identifier}", identifier: identifier, title: "Use a private temp folder", state: "In Progress"}

    defaults = [
      workspace_path: workspace,
      agent_module: TmpDirAgent,
      agent_tmp_bases: ctx.bases,
      issue_enricher: &{:ok, &1},
      issue_state_fetcher: fn _ids -> {:ok, [%{issue | state: "Done"}]} end,
      leftover_processes: [table: fn -> {:ok, []} end]
    ]

    # A failed run raises; the task returns it so the test sees it.
    Task.async(fn ->
      try do
        AgentRunner.run(issue, nil, Keyword.merge(defaults, opts))
      rescue
        error -> {:raised, error}
      end
    end)
  end
end
