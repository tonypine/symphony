defmodule SymphonyElixir.WorkspaceLifecycleTest do
  # A ticket's workspace is removed only for a reason on the allow list (`SymphonyElixir.WorkspaceRemoval`):
  # a terminal state, Start over and the age GC of an ended or missing ticket's idle workspace. A
  # phase move between the active phases, a person's push in Merging (R11), a Stop, a run that times
  # out, fails or is cut short by an app update, and a run that ends with its ticket still in a phase
  # keep it.
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
    wait_until_quiet(pid)
    hold_ticks(pid)

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

  test "a run that times out, fails, or is cut short by an app update keeps the workspace", %{pid: pid} = ctx do
    # The stall watchdog restarts a run silent past the stall timeout.
    timed_out = issue("issue-timeout", "MT-TIMEOUT", "In Progress")
    timed_out_workspace = workspace!(ctx, timed_out)
    {worker_pid, worker_ref} = put_running!(pid, timed_out, timed_out_workspace)

    :sys.replace_state(pid, fn state ->
      state
      |> put_in([Access.key!(:running), timed_out.id, :session_id], "sess-timeout")
      |> put_in([Access.key!(:running), timed_out.id, :last_codex_timestamp], DateTime.add(DateTime.utc_now(), -86_400, :second))
      |> Orchestrator.run_watchdogs_for_test()
    end)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, @wait_ms
    assert %{running: []} = GenServer.call(pid, :snapshot)
    assert_workspace_kept(timed_out, timed_out_workspace)

    # A run whose task exits abnormally (the agent failed or refused) is retried in its workspace.
    failed = issue("issue-failed", "MT-FAILED", "In Progress")
    failed_workspace = workspace!(ctx, failed)
    {failed_pid, failed_ref} = put_running!(pid, failed, failed_workspace)
    send(pid, {:DOWN, failed_ref, :process, failed_pid, {:agent_failed, "refused"}})
    assert %{running: []} = GenServer.call(pid, :snapshot)
    assert_workspace_kept(failed, failed_workspace)
    send(failed_pid, :finish)

    # An app update ends the process with a run in flight. The next start's sweeps keep the
    # workspace of a ticket that is still open, even one outside the tracked states (Backlog here)
    # with the startup sweep set to delete orphans.
    interrupted = issue("issue-update", "MT-UPDATE", "In Progress")
    interrupted_workspace = workspace!(ctx, interrupted)
    {interrupted_pid, _interrupted_ref} = put_running!(pid, interrupted, interrupted_workspace)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{interrupted | state: "Backlog"}])
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)
    stop_process(pid)
    send(interrupted_pid, :finish)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: ctx.workspace_root,
      tracker_active_states: @phases,
      workspace_lifecycle: %{max_age_days: 1, orphan_action: "delete"}
    )

    {:ok, restarted} = Orchestrator.start_link(name: Module.concat(__MODULE__, "Restarted#{System.unique_integer([:positive])}"))
    on_exit(fn -> stop_process(restarted) end)
    wait_until_quiet(restarted)
    assert_workspace_kept(interrupted, interrupted_workspace)
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

    {:ok, stale_entries} = Workspace.scan_stale_workspaces(Config.repo_key!(), DateTime.utc_now())
    ref = make_ref()

    result =
      {:startup_workspace_lifecycle_result,
       %{
         now_ms: System.monotonic_time(:millisecond),
         repo_results: [{Config.repo_key!(), %{orphan_sweep_result: {:ok, []}, age_gc_scan: {:ok, stale_entries}}}],
         quota: %{configured?: false, paused: false, reason: nil}
       }}

    # The retry and watch state the GC reads and the result it acts on arrive in one step, inside
    # the Orchestrator, so no other message can change that state in between.
    :sys.replace_state(pid, fn state ->
      state = %{
        state
        | startup_workspace_lifecycle_task_ref: ref,
          retry_attempts: %{
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

      {:noreply, state} = Orchestrator.handle_info({ref, result}, state)
      state
    end)

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

  # Startup is done once its workspace lifecycle result is applied and no poll or dispatch
  # readiness task it set off is still out. A readiness task started before that result runs the
  # age GC over a kept set read before the test's state was in place; once the result is applied,
  # the GC is not due again for the configured interval.
  defp wait_until_quiet(pid, attempts \\ 500) do
    cond do
      quiet?(:sys.get_state(pid)) ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        wait_until_quiet(pid, attempts - 1)

      true ->
        flunk("the Orchestrator did not finish its startup work")
    end
  end

  defp quiet?(state) do
    is_nil(state.startup_workspace_lifecycle_task_ref) and
      is_integer(state.workspace_lifecycle_last_check_at_ms) and
      is_nil(state.repo_poll_task_ref) and
      state.dispatch_readiness_tasks == %{} and
      state.poll_check_in_progress != true
  end

  # The Orchestrator's own poll and watchdog ticks are held off for the test: a tick already sent
  # carries a token that no longer matches and is dropped, so only the test's own messages change
  # the state it sets with `:sys.replace_state`.
  defp hold_ticks(pid) do
    :sys.replace_state(pid, fn state ->
      for timer_ref <- [state.tick_timer_ref, state.watchdog_timer_ref], is_reference(timer_ref) do
        Process.cancel_timer(timer_ref)
      end

      %{
        state
        | tick_timer_ref: nil,
          tick_token: nil,
          next_poll_due_at_ms: nil,
          watchdog_timer_ref: nil,
          watchdog_token: nil
      }
    end)
  end
end
