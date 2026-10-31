defmodule SymphonyElixir.OrchestratorSetupBlockTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Pauses, Questions, RunStore, SelfHeal, SetupBlock}
  alias SymphonyElixirWeb.Presenter

  @symphony_repo_key "symphony-self"
  @min_wait_ms 2_000

  # The fix-ticket filer self-heal calls from the orchestrator's task: every call is reported to the
  # test, and filing can be made to fail.
  defmodule FakeFixer do
    def create(attrs, _opts) do
      notify({:fake_fixer_create, attrs})
      Application.get_env(:symphony_elixir, :fake_fixer_create_result, {:ok, %{identifier: "MT-901", url: "https://example.org/issues/MT-901"}})
    end

    def attach(identifier, _body, _opts) do
      notify({:fake_fixer_attach, identifier})
      :ok
    end

    def block(issue, ticket, _opts) do
      notify({:fake_fixer_block, issue.id, ticket.identifier})
      :ok
    end

    defp notify(message), do: send(Application.fetch_env!(:symphony_elixir, :memory_tracker_recipient), message)
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :fake_fixer_create_result) end)
    :ok
  end

  test "a dev server build that exits 127 is held on a fix ticket in the project's repo, not retried, and listed as blocked" do
    issue = issue("issue-setup-build", "MT-SETUP-BUILD")
    {pid, name} = start_orchestrator(:BuildOrchestrator)

    log =
      capture_log(fn ->
        down(pid, issue, {:setup_block, {:verification_failed, {:dev_server_build_failed, 127}}})

        assert_receive {:fake_fixer_create, %{scope: scope, component: "dev_server", title: "Self-heal: repair the dev_server block"}}, @min_wait_ms
        assert scope == Config.repo_key!()
        assert_receive {:fake_fixer_block, "issue-setup-build", "MT-901"}, @min_wait_ms

        state = wait_for_orchestrator_state(pid, &(map_size(&1.running) == 0 and &1.tracker_tasks == %{}))
        refute Map.has_key?(state.retry_attempts, issue.id)
        refute MapSet.member?(state.claimed, issue.id)
      end)

    words = "verification.dev_server build failed with exit 127: a command it runs is not on the sandbox PATH"
    assert log =~ "Setup block for MT-SETUP-BUILD: dev_server — #{words}; self-heal holds it on MT-901"
    refute log =~ "scheduling retry"

    assert log =~ "Self-heal holds MT-SETUP-BUILD on MT-901 for its dev_server block: #{words}"
    reason = "Waiting for MT-901 to finish: it fixes what stopped this ticket"
    assert Pauses.why({:ticket, Config.repo_key!(), issue.id}) == [reason]

    assert [%{run_id: "run-issue-setup-build", status: "blocked", error: "agent exited: setup block: " <> ^words}] =
             Enum.filter(RunStore.list_runs(), &(&1.issue_id == issue.id))

    # A poll lists the ticket under `blocked` with its fix ticket, and skips it with its pause's line.
    :sys.replace_state(pid, fn state ->
      state = Orchestrator.put_blocked_for_test(state, [issue])
      Orchestrator.dispatch_chosen_issues_for_test([issue], state)
    end)

    payload = Presenter.state_payload(name, 1_000)

    assert [%{issue_identifier: "MT-SETUP-BUILD", kind: "hold", reason: ^reason, blocked_by: [%{issue_identifier: "MT-901", state: "fix ticket"}]}] =
             payload.blocked

    assert [%{issue_identifier: "MT-SETUP-BUILD", reason: ^reason}] = payload.dispatch_skipped
  end

  test "a port collision on the dev server's bridge is held on a Symphony fix ticket" do
    issue = issue("issue-setup-port", "MT-SETUP-PORT")
    {pid, _name} = start_orchestrator(:PortOrchestrator)

    log =
      capture_log(fn ->
        down(pid, issue, {:setup_block, {:verification_failed, {:loopback_bridge_unavailable, :eaddrinuse}}})

        assert_receive {:fake_fixer_create, %{scope: @symphony_repo_key, component: "qa_environment"}}, @min_wait_ms
        state = wait_for_orchestrator_state(pid, &(map_size(&1.running) == 0 and &1.tracker_tasks == %{}))
        refute Map.has_key?(state.retry_attempts, issue.id)
      end)

    assert Pauses.why({:ticket, Config.repo_key!(), issue.id}) == ["Waiting for MT-901 to finish: it fixes what stopped this ticket"]
    assert log =~ "the port is already in use (eaddrinuse)"
  end

  test "the same block coming back after its fix landed asks a person instead of retrying" do
    issue = issue("issue-setup-again", "MT-SETUP-AGAIN")
    cause = {:verification_failed, {:dev_server_build_failed, 2}}
    signature = SelfHeal.signature(SetupBlock.outcome(cause))

    :ok =
      RunStore.record_ticket_self_heal(Config.repo_key!(), issue.id, %{
        component: "dev_server",
        scope: Config.repo_key!(),
        signature: signature,
        fix_ticket: nil,
        attempts: 1
      })

    {pid, _name} = start_orchestrator(:AgainOrchestrator)

    log =
      capture_log(fn ->
        down(pid, issue, {:setup_block, cause})

        assert_receive {:memory_tracker_comment, "issue-setup-again", _body}, @min_wait_ms
        state = wait_for_orchestrator_state(pid, &(map_size(&1.running) == 0 and &1.tracker_tasks == %{}))
        refute Map.has_key?(state.retry_attempts, issue.id)
        refute MapSet.member?(state.claimed, issue.id)
      end)

    assert log =~ "Setup block for MT-SETUP-AGAIN: dev_server — verification.dev_server build failed with exit 2; self-heal asks a person to decide"
    refute_received {:fake_fixer_create, _attrs}
    assert Questions.deciding({:ticket, Config.repo_key!(), issue.id})
  end

  test "a block self-heal cannot record falls back to the crash retry" do
    Application.put_env(:symphony_elixir, :fake_fixer_create_result, {:error, :linear_down})
    issue = issue("issue-setup-unfiled", "MT-SETUP-UNFILED")
    {pid, _name} = start_orchestrator(:UnfiledOrchestrator)

    log =
      capture_log(fn ->
        down(pid, issue, {:setup_block, {:verification_failed, :health_timeout}})

        assert_receive {:fake_fixer_create, _attrs}, @min_wait_ms
        state = wait_for_orchestrator_state(pid, &(&1.tracker_tasks == %{} and Map.has_key?(&1.retry_attempts, issue.id)))
        assert %{attempt: 1, error: "agent exited: setup block: verification.dev_server did not pass its health check in time"} = state.retry_attempts[issue.id]
      end)

    assert log =~ "self-heal answered {:error, {:self_heal_fix_ticket_failed, :linear_down}}, scheduling retry"
    refute Pauses.paused?({:ticket, Config.repo_key!(), issue.id})
  end

  defp issue(id, identifier) do
    %Issue{id: id, identifier: identifier, title: "Setup block", state: "In Progress", repo_key: Config.repo_key!()}
  end

  defp start_orchestrator(suffix) do
    name = Module.concat(__MODULE__, suffix)
    self_heal_opts = [fixer: FakeFixer, symphony_repo_key: @symphony_repo_key]
    {:ok, pid} = Orchestrator.start_link(name: name, self_heal_opts: self_heal_opts)

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    # The startup poll would stop runs the memory tracker does not list, so let it finish before
    # injecting the run.
    wait_for_orchestrator_state(pid, &poll_idle?/1)
    {pid, name}
  end

  defp poll_idle?(state), do: is_nil(state.repo_poll_task_ref) and not state.poll_check_in_progress and state.dispatch_readiness_tasks == %{}

  # Starts a run for `issue` in the orchestrator, then ends it with `reason`, as the runner's exit would.
  defp down(pid, %Issue{} = issue, reason) do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    ref = Process.monitor(worker)
    run_id = "run-#{issue.id}"
    started_at = DateTime.utc_now()

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
        started_at: started_at
      })

    entry = %{
      pid: worker,
      ref: ref,
      run_id: run_id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
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
      turn_count: 0,
      retry_attempt: 0,
      repo_key: Config.repo_key!(),
      started_at: started_at
    }

    :sys.replace_state(pid, fn state -> %{state | running: %{issue.id => entry}, claimed: MapSet.put(state.claimed, issue.id)} end)
    send(pid, {:DOWN, ref, :process, worker, reason})
    on_exit(fn -> Process.exit(worker, :kill) end)
  end

  defp wait_for_orchestrator_state(pid, predicate, deadline_ms \\ nil) do
    deadline_ms = deadline_ms || System.monotonic_time(:millisecond) + @min_wait_ms
    state = :sys.get_state(pid, 15_000)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("timed out waiting for orchestrator state: #{inspect(Map.take(state, [:running, :tracker_tasks, :retry_attempts, :dispatch_skipped]))}")

      true ->
        Process.sleep(5)
        wait_for_orchestrator_state(pid, predicate, deadline_ms)
    end
  end
end
