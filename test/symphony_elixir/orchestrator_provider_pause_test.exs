defmodule SymphonyElixir.OrchestratorProviderPauseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Pauses, Situation, TicketState}

  @paused "you paused Anthropic, and no fallback of its run can take it"

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-provider-pause-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      for provider <- ["anthropic", "openrouter"], do: Pauses.clear({:provider, provider})
      File.rm_rf(test_root)
    end)

    ctx = %{test_root: test_root}
    write_provider_workflow!(ctx)
    ctx
  end

  describe "pause and resume" do
    test "pause stops new runs on the provider alone, survives a restart, and resume clears it" do
      assert Orchestrator.pause_provider("anthropic") == :unavailable
      assert Orchestrator.resume_provider("anthropic") == :unavailable

      pid = start_orchestrator(:ProviderPauseOrchestrator)

      assert {:ok, %{provider: "anthropic", pause: %{reasons: [%{kind: :person, text: "You paused Anthropic", set_by: %{kind: :person}}]}}} =
               Orchestrator.pause_provider(pid, "anthropic")

      assert MapSet.equal?(:sys.get_state(pid).paused_providers, MapSet.new(["anthropic"]))

      stop_process(pid)
      pid = start_orchestrator(:ProviderPauseRestarted)
      assert MapSet.equal?(:sys.get_state(pid).paused_providers, MapSet.new(["anthropic"]))

      assert {:ok, %{provider: "anthropic", pause: nil}} = Orchestrator.resume_provider(pid, "anthropic")
      assert MapSet.size(:sys.get_state(pid).paused_providers) == 0
      refute Pauses.paused?({:provider, "anthropic"})
    end

    test "a provider no harness reaches can't be paused or resumed" do
      for message <- [{:pause_provider, "acme"}, {:resume_provider, "acme"}] do
        assert {:reply, {:error, {:provider_not_found, "acme"}}, _state} = call(message, orchestrator_state())
      end

      refute Pauses.paused?({:provider, "acme"})
    end

    test "a run that works on the paused provider is not stopped" do
      worker = spawn(fn -> receive do: (:finish -> :ok) end)
      on_exit(fn -> send(worker, :finish) end)
      running = issue("running", "MT-RUN", "In Progress")
      state = %{orchestrator_state() | running: %{"running" => %{pid: worker, issue: running, identifier: "MT-RUN"}}, claimed: MapSet.new(["running"])}

      assert {:reply, {:ok, %{provider: "anthropic"}}, state} = call({:pause_provider, "anthropic"}, state)

      assert Process.alive?(worker)
      assert %{pid: ^worker} = state.running["running"]
      assert MapSet.member?(state.claimed, "running")
    end
  end

  describe "while a provider is paused" do
    test "a new run starts on its first fallback whose provider is not paused, as under a usage limit", ctx do
      fallbacks = [%{"provider" => "openrouter", "model" => "openai/gpt-5"}]
      write_provider_workflow!(ctx, agent_run_profiles: %{"implementation" => %{"fallbacks" => fallbacks}})
      {:reply, {:ok, _status}, paused} = call({:pause_provider, "anthropic"}, orchestrator_state())
      todo = issue("fallback", "MT-FALLBACK", "Todo")

      assert %{provider: "openrouter", fallback: 0} = Orchestrator.run_profile_for_test(paused, todo, false)
      assert Orchestrator.should_dispatch_issue_for_test(todo, paused)

      # A continuation stays on its own choice and waits.
      assert %{provider: "anthropic", fallback: nil} = Orchestrator.run_profile_for_test(paused, todo, true)

      # With the fallback's provider paused too, the run waits on its own choice.
      {:reply, {:ok, _status}, both} = call({:pause_provider, "openrouter"}, paused)
      assert %{provider: "anthropic", fallback: nil} = Orchestrator.run_profile_for_test(both, todo, false)
      refute Orchestrator.should_dispatch_issue_for_test(todo, both)
    end

    test "a ticket with no free fallback is skipped naming the provider, and reads that it waits on it" do
      {:reply, {:ok, _status}, paused} = call({:pause_provider, "anthropic"}, orchestrator_state())
      todo = issue("todo", "MT-TODO", "Todo")
      tracked([todo])

      state = Orchestrator.dispatch_chosen_issues_for_test([todo], paused)

      assert state.running == %{}
      assert %{reason: @paused, rule: :provider_pause, provider: "anthropic"} = state.dispatch_skipped["todo"]
      assert state.slot_waiting == %{}

      assert %{
               kind: "waiting_for_provider",
               word: "Waiting: you paused Anthropic",
               cause: "The implementation run runs on Anthropic, and none of its fallbacks can take it.",
               next: "Starts when you resume Anthropic.",
               waits_on: %{provider: "anthropic"}
             } = situation(state, "todo", "Todo")

      order = Orchestrator.put_dispatch_order_for_test(paused, [todo]).dispatch_order
      assert [%{issue_id: "todo", outcome: :held, reason: @paused, rule: :provider_pause}] = order.entries

      # Once resumed, it dispatches.
      {:reply, {:ok, %{pause: nil}}, resumed} = call({:resume_provider, "anthropic"}, paused)
      assert_receive {:tick, _token}
      assert Orchestrator.should_dispatch_issue_for_test(todo, resumed)
    end

    test "a continuation waits as a held retry naming the provider, and resume sends it on at once" do
      continuing = issue("continuing", "MT-CONT", "In Progress")
      tracked([continuing])
      {:reply, {:ok, _status}, paused} = call({:pause_provider, "anthropic"}, %{orchestrator_state() | claimed: MapSet.new(["continuing"])})
      metadata = %{identifier: "MT-CONT", repo_key: "default", continuation: true, delay_type: :continuation}

      log =
        capture_log(fn ->
          fetch = fn _ids -> {:ok, [continuing]} end
          {:noreply, state} = Orchestrator.handle_retry_issue_for_test(paused, "continuing", 1, metadata, fetch)
          send(self(), {:held, state})
        end)

      assert_received {:held, state}
      assert log =~ "Not dispatching retry of issue_id=continuing issue_identifier=MT-CONT: #{@paused}"
      assert state.running == %{}

      assert %{attempt: 1, delay_type: :continuation, held_by_provider: "anthropic", timer_ref: nil, retry_token: token} =
               state.retry_attempts["continuing"]

      assert MapSet.member?(state.claimed, "continuing")
      assert %{rule: :provider_pause, provider: "anthropic"} = state.dispatch_skipped["continuing"]

      # It is no retry to a person, and a poll keeps naming the provider, not its claim.
      assert %{retrying: []} = snapshot_of(state)
      state = Orchestrator.dispatch_chosen_issues_for_test([continuing], state)
      assert %{reason: @paused, rule: :provider_pause, provider: "anthropic"} = state.dispatch_skipped["continuing"]
      assert situation(state, "continuing", "In Progress").kind == "waiting_for_provider"

      # Resume sends the held retry on at once, with its token, and asks for a tick; a retry it
      # did not hold keeps its timer.
      other = %{attempt: 2, timer_ref: nil, retry_token: make_ref(), due_at_ms: 0, identifier: "MT-OTHER", repo_key: "default"}
      state = %{state | retry_attempts: Map.put(state.retry_attempts, "other", other)}
      {:reply, {:ok, %{pause: nil}}, resumed} = call({:resume_provider, "anthropic"}, state)
      assert_received {:retry_issue, "continuing", ^token}
      refute_received {:retry_issue, "other", _token}
      assert resumed.retry_attempts["other"] == other
      assert_receive {:tick, _tick}
      refute Map.has_key?(resumed.retry_attempts["continuing"], :held_by_provider)
      assert %{delay_type: :continuation} = resumed.retry_attempts["continuing"]
    end
  end

  defp situation(state, issue_id, phase) do
    record = TicketState.normalize(%{repo_key: "default", issue_id: issue_id, issue_identifier: issue_id, phase: phase})
    Situation.compute(record, [], Situation.live_facts(snapshot_of(state)))
  end

  defp snapshot_of(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
  end

  defp call(message, state), do: Orchestrator.handle_call(message, {self(), make_ref()}, state)

  defp start_orchestrator(name) do
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, name))
    on_exit(fn -> stop_process(pid) end)
    wait_until(pid, &(is_nil(&1.repo_poll_task_ref) and not &1.poll_check_in_progress))
    pid
  end

  defp wait_until(pid, predicate) do
    Enum.reduce_while(1..200, nil, fn _attempt, _acc ->
      if predicate.(:sys.get_state(pid)), do: {:halt, :ok}, else: Process.sleep(10) && {:cont, nil}
    end)
  end

  defp write_provider_workflow!(ctx, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"],
          tracker_terminal_states: ["Done", "Canceled"],
          workspace_root: Path.join(ctx.test_root, "workspaces"),
          agent_kind: "claude",
          max_turns: 1,
          quality_gate: %{enabled: false}
        ],
        overrides
      )
    )
  end

  defp issue(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Ticket #{identifier}",
      description: "Finish it",
      state: state,
      priority: 3,
      team: %{key: "Test"},
      labels: [],
      repo_key: "default",
      url: "https://example.org/issues/#{identifier}"
    }
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp orchestrator_state do
    %Orchestrator.State{
      repo_key: "default",
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
