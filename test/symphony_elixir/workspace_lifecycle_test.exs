defmodule SymphonyElixir.WorkspaceLifecycleTest do
  # A ticket's workspace is removed only on a terminal state, Restart, the operator's Stop and the
  # age GC of idle workspaces (`docs/design/state-machine.md`, "Workspace"). A phase move between
  # the active phases, a person's push in Merging (R11) and a run that ends with its ticket still
  # in a phase keep it.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunStore

  @wait_ms 5_000
  @phases ["Todo", "In Progress", "Rework", "CI Fix", "Merging", "QA"]

  setup do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-workspace-lifecycle-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      tracker_active_states: @phases,
      workspace_lifecycle: %{max_age_days: 1}
    )

    orchestrator_name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    wait_for_startup(pid)

    on_exit(fn ->
      stop_process(pid)
      File.rm_rf(workspace_root)
    end)

    %{pid: pid, workspace_root: workspace_root}
  end

  test "R11: a person's push sends a Merging ticket back to Code Review and its workspace stays", %{pid: pid} = ctx do
    issue = issue("issue-r11", "MT-R11", "Merging")
    workspace = workspace!(ctx, issue)
    {worker_pid, _worker_ref} = put_running!(pid, issue, workspace)

    # R11 moves the ticket to Code Review; the orchestrator's next read finds it there. Whether the
    # landing run goes on or stops, no removal is queued.
    reconcile(pid, %{issue | state: "Code Review"})

    assert_workspace_kept(issue, workspace)
    send(worker_pid, :finish)
  end

  test "a run stopped because its ticket left the active phases keeps the workspace", %{pid: pid} = ctx do
    issue = issue("issue-sideways", "MT-SIDE", "In Progress")
    workspace = workspace!(ctx, issue)
    {worker_pid, worker_ref} = put_running!(pid, issue, workspace)

    reconcile(pid, %{issue | state: "Backlog"})

    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}, @wait_ms
    assert %{running: []} = GenServer.call(pid, :snapshot)
    assert_workspace_kept(issue, workspace)
  end

  test "a Director move from QA to Rework keeps the workspace", %{pid: pid} = ctx do
    issue = issue("issue-qa-rework", "MT-QAR", "QA")
    workspace = workspace!(ctx, issue)
    {worker_pid, _worker_ref} = put_running!(pid, issue, workspace)

    reconcile(pid, %{issue | state: "Rework"})

    assert Process.alive?(worker_pid)
    assert_workspace_kept(issue, workspace)
    send(worker_pid, :finish)
  end

  test "a retry that finds its ticket waiting in Code Review keeps the workspace", %{pid: pid} = ctx do
    issue = issue("issue-retry-review", "MT-RETRY", "Code Review")
    workspace = workspace!(ctx, issue)
    state = :sys.get_state(pid)

    assert {:noreply, _state} =
             Orchestrator.handle_retry_issue_for_test(state, issue.id, 1, %{identifier: issue.identifier}, fn [_id] -> {:ok, [issue]} end)

    assert_workspace_kept(issue, workspace)
  end

  test "the age GC keeps a retrying ticket's workspace and a watched ticket's with an open PR", %{pid: pid} = ctx do
    retrying = stale_workspace!(ctx, "MT-RETRYING")
    reviewed = stale_workspace!(ctx, "MT-REVIEWED")
    no_pr = stale_workspace!(ctx, "MT-NO-PR")
    idle = stale_workspace!(ctx, "MT-IDLE")

    :sys.replace_state(pid, fn state ->
      %{
        state
        | retry_attempts: %{
            "issue-retrying" => %{
              attempt: 1,
              due_at_ms: System.monotonic_time(:millisecond) + 60_000,
              retry_token: make_ref(),
              identifier: "MT-RETRYING",
              repo_key: Config.repo_key!()
            }
          },
          watching: %{
            "issue-reviewed" => %{identifier: "MT-REVIEWED", repo_key: nil, state: "Code Review", pull_request_url: "https://github.com/o/r/pull/1"},
            "issue-no-pr" => %{identifier: "MT-NO-PR", repo_key: Config.repo_key!(), state: "Code Review", pull_request_url: nil}
          }
      }
    end)

    {:ok, stale_entries} = Workspace.scan_stale_workspaces(Config.repo_key!(), DateTime.utc_now())
    ref = make_ref()
    :sys.replace_state(pid, &%{&1 | startup_workspace_lifecycle_task_ref: ref})

    send(
      pid,
      {ref,
       {:startup_workspace_lifecycle_result,
        %{
          now_ms: System.monotonic_time(:millisecond),
          repo_results: [{Config.repo_key!(), %{orphan_sweep_result: {:ok, []}, age_gc_scan: {:ok, stale_entries}}}],
          quota: %{configured?: false, paused: false, reason: nil}
        }}}
    )

    assert %{startup_workspace_lifecycle_task_ref: nil} = :sys.get_state(pid)
    assert File.dir?(retrying)
    assert File.dir?(reviewed)
    refute File.exists?(no_pr)
    refute File.exists?(idle)
  end

  defp issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "Lifecycle #{identifier}", state: state, url: "https://example.org/issues/#{identifier}"}
  end

  defp workspace!(%{workspace_root: root}, %Issue{identifier: identifier}) do
    workspace = Path.join([root, Config.repo_key!(), identifier])
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "work.txt"), "in progress\n")
    workspace
  end

  defp stale_workspace!(%{workspace_root: root}, identifier) do
    workspace = Path.join([root, Config.repo_key!(), identifier])
    File.mkdir_p!(workspace)
    File.touch!(workspace, System.os_time(:second) - 30 * 86_400)
    workspace
  end

  defp put_running!(pid, %Issue{} = issue, workspace) do
    worker_pid = spawn(fn -> receive do: (:finish -> :ok) end)
    worker_ref = Process.monitor(worker_pid)
    started_at = DateTime.utc_now()
    run_id = "run-#{issue.id}"

    :ok =
      RunStore.put_run(%{
        run_id: run_id,
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        title: issue.title,
        state: issue.state,
        status: "running",
        repo_key: Config.repo_key!(),
        attempt: 1,
        started_at: started_at,
        workspace_path: workspace
      })

    entry = %{
      pid: worker_pid,
      ref: worker_ref,
      run_id: run_id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: workspace,
      session_id: nil,
      transcript_path: nil,
      transcript_buffer: :queue.new(),
      transcript_buffer_size: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 1,
      retry_attempt: 0,
      repo_key: Config.repo_key!(),
      started_at: started_at
    }

    :sys.replace_state(pid, fn state ->
      %{state | running: %{issue.id => entry}, claimed: MapSet.put(state.claimed, issue.id)}
    end)

    {worker_pid, worker_ref}
  end

  defp reconcile(pid, %Issue{} = issue) do
    :sys.replace_state(pid, &Orchestrator.reconcile_issue_states_for_test([issue], &1))
  end

  # A removal is queued with WorkspaceCleanup during the move, so once no removal of the ticket is
  # queued or running, a workspace still there is one no removal was asked for.
  defp assert_workspace_kept(%Issue{identifier: identifier}, workspace) do
    assert :ok = WorkspaceCleanup.await(identifier)
    assert File.read!(Path.join(workspace, "work.txt")) == "in progress\n"
  end

  defp wait_for_startup(pid) do
    Enum.reduce_while(1..200, nil, fn _attempt, _acc ->
      if is_nil(:sys.get_state(pid).startup_workspace_lifecycle_task_ref) do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end)
  end
end
