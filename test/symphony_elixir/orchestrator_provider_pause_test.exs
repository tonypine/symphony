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

  describe "while a provider is at its reserve" do
    test "a new run starts on its fallback, as under a pause", ctx do
      fallbacks = [%{"provider" => "openrouter", "model" => "openai/gpt-5"}]

      write_provider_workflow!(ctx,
        agent_run_profiles: %{"implementation" => %{"fallbacks" => fallbacks}},
        execution_providers: %{anthropic: %{reserve: 0.8}}
      )

      state = at_reserve(orchestrator_state())
      todo = issue("fallback", "MT-FALLBACK", "Todo")

      assert %{provider: "openrouter", fallback: 0} = Orchestrator.run_profile_for_test(state, todo, false)
      assert Orchestrator.should_dispatch_issue_for_test(todo, state)

      # A continuation stays on its own choice, and the reserve does not hold it.
      assert %{provider: "anthropic", fallback: nil} = Orchestrator.run_profile_for_test(state, todo, true)
    end

    test "a ticket with no free fallback is skipped naming the provider and its reserve" do
      state = at_reserve(orchestrator_state())
      todo = issue("todo", "MT-TODO", "Todo")
      tracked([todo])

      state = Orchestrator.dispatch_chosen_issues_for_test([todo], state)

      assert state.running == %{}

      assert %{reason: "Anthropic at its 80% reserve: holding new runs", rule: :usage_limit, provider: "anthropic", reserve: 0.8} =
               state.dispatch_skipped["todo"]

      assert %{
               kind: "waiting_for_provider",
               word: "Waiting: Anthropic is at its 80% reserve",
               cause: "The implementation run runs on Anthropic, which stops new runs at its 80% reserve, and none of its fallbacks can take it.",
               next: "Starts when Anthropic's usage resets.",
               waits_on: %{provider: "anthropic"}
             } = situation(state, "todo", "Todo")

      # A hold that doesn't say its reserve still names the provider.
      state = %{state | usage_limits: Map.new(state.usage_limits, fn {key, hold} -> {key, Map.delete(hold, :reserve)} end)}
      state = Orchestrator.dispatch_chosen_issues_for_test([todo], state)
      assert %{word: "Waiting: Anthropic is at its reserve"} = situation(state, "todo", "Todo")
    end

    test "a landing run and a forced ticket's run are not held" do
      state = at_reserve(orchestrator_state())
      landing = issue("landing", "MT-LAND", "Merging")
      assert Orchestrator.should_dispatch_issue_for_test(landing, state)

      todo = issue("todo", "MT-TODO", "Todo")
      refute Orchestrator.should_dispatch_issue_for_test(todo, state)
      assert Orchestrator.should_dispatch_issue_for_test(%{todo | labels: ["expedite"]}, state)
    end

    test "the state's providers fill the reserve and say the provider is at it", ctx do
      write_provider_workflow!(ctx, execution_providers: %{anthropic: %{reserve: 0.8}})

      assert %{reserve: 0.8, at_reserve: false} = provider(snapshot_of(orchestrator_state()), "anthropic")
      assert %{reserve: 0.8, at_reserve: true, held: true} = provider(snapshot_of(at_reserve(orchestrator_state())), "anthropic")
      assert %{reserve: nil, at_reserve: false} = provider(snapshot_of(orchestrator_state()), "openai")
    end
  end

  defp at_reserve(state) do
    now = DateTime.utc_now()

    hold = %{
      provider: "anthropic",
      scope: :all,
      reason: "claude_usage_headroom",
      window: "seven_day",
      phase: :headroom,
      since: now,
      resets_at: DateTime.add(now, 3600),
      resume_at: DateTime.add(now, 3720),
      source: :rate_limit_event,
      canary_issue_id: nil,
      issue_identifier: nil,
      utilization: 0.83,
      reserve: 0.8
    }

    %{state | usage_limits: %{{"anthropic", :all} => hold}}
  end

  describe "a retry waiting for a slot" do
    test "keeps its attempt and claim while its provider is paused, and resume sends it on at once" do
      waiting_issue = issue("waiting", "MT-WAIT", "In Progress")
      tracked([waiting_issue])
      {:reply, {:ok, _status}, paused} = call({:pause_provider, "anthropic"}, orchestrator_state())
      waiting = %{attempt: 2, repo_key: "default", worker_host: nil, since: DateTime.utc_now(), reason: "dispatch readiness task already in flight"}

      state = Orchestrator.dispatch_chosen_issues_for_test([waiting_issue], %{paused | slot_waiting: %{"waiting" => waiting}})

      assert state.running == %{}
      assert state.slot_waiting == %{}
      assert MapSet.member?(state.claimed, "waiting")
      assert %{attempt: 2, held_by_provider: "anthropic", timer_ref: nil, retry_token: token} = state.retry_attempts["waiting"]
      assert %{reason: @paused, rule: :provider_pause, provider: "anthropic"} = state.dispatch_skipped["waiting"]

      {:reply, {:ok, %{pause: nil}}, resumed} = call({:resume_provider, "anthropic"}, state)
      assert_received {:retry_issue, "waiting", ^token}
      assert %{attempt: 2} = resumed.retry_attempts["waiting"]
    end

    test "with no attempt is skipped naming the provider and keeps no retry" do
      fresh = issue("fresh", "MT-FRESH", "Todo")
      tracked([fresh])
      {:reply, {:ok, _status}, paused} = call({:pause_provider, "anthropic"}, orchestrator_state())
      waiting = %{reason: "work slots full", since: DateTime.utc_now()}

      state = Orchestrator.dispatch_chosen_issues_for_test([fresh], %{paused | slot_waiting: %{"fresh" => waiting}})

      assert state.retry_attempts == %{}
      assert %{rule: :provider_pause} = state.dispatch_skipped["fresh"]
    end
  end

  describe "an operator PR dispatch" do
    test "is refused naming the provider while it is paused", ctx do
      root = Path.join(ctx.test_root, "pr-repo")
      File.mkdir_p!(root)
      {_, 0} = System.cmd("git", ["-C", root, "init", "-b", "main"], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", root, "remote", "add", "origin", "git@github.com:example/repo.git"], stderr_to_stdout: true)
      write_provider_workflow!(ctx, workspace_strategy: "worktree", workspace_repo: root)
      pid = start_orchestrator(:ProviderPausePrDispatch)
      assert {:ok, _status} = Orchestrator.pause_provider(pid, "anthropic")

      pr =
        Jason.encode!(%{
          "number" => 123,
          "state" => "OPEN",
          "title" => "Fix CI",
          "body" => "Build is red",
          "url" => "https://github.com/example/repo/pull/123",
          "headRefName" => "feature/fix-ci",
          "baseRefName" => "main",
          "headRepository" => %{"nameWithOwner" => "example/repo"}
        })

      gh_runner = fn ["pr", "view", "123" | _rest], _opts -> {pr, 0} end
      assert {:error, {:provider_paused, "anthropic"}} = Orchestrator.dispatch_pr(pid, "123", gh_runner: gh_runner)
    end
  end

  describe "the state's providers" do
    test "a pause shows with its time in the next snapshot, and a resume clears it" do
      running = running_entry(issue("running", "MT-RUN", "In Progress"), "anthropic")
      state = %{orchestrator_state() | running: %{"running" => running}}

      assert %{paused: false, paused_since: nil, in_use: true, working: 1} = provider(snapshot_of(state), "anthropic")

      {:reply, {:ok, _status}, paused} = call({:pause_provider, "anthropic"}, state)
      assert %{paused: true, paused_since: %DateTime{}, kinds: kinds} = provider(snapshot_of(paused), "anthropic")
      assert "implementation" in kinds
      assert %{paused: false} = provider(snapshot_of(paused), "openrouter")

      {:reply, {:ok, _status}, resumed} = call({:resume_provider, "anthropic"}, paused)
      assert %{paused: false, paused_since: nil} = provider(snapshot_of(resumed), "anthropic")
    end

    test "a usage limit's hold and the windows Symphony read show on its provider" do
      resume_at = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      resets_at = DateTime.add(resume_at, -60, :second)

      hold = %{
        provider: "anthropic",
        scope: :all,
        reason: "claude_usage_limit",
        window: "five_hour",
        phase: :paused,
        since: DateTime.utc_now(),
        resets_at: resets_at,
        resume_at: resume_at,
        source: nil,
        canary_issue_id: nil,
        issue_identifier: nil,
        utilization: 1.0
      }

      windows = %{{"anthropic", "five_hour"} => %{resets_at: resets_at, utilization: 1.0}}
      state = %{orchestrator_state() | usage_limits: %{{"anthropic", :all} => hold}, usage_windows: windows}

      assert %{
               held: true,
               held_until: ^resume_at,
               usage_windows: [%{name: "five_hour", utilization: 1.0, resets_at: ^resets_at}]
             } = provider(snapshot_of(state), "anthropic")

      assert %{held: false, usage_windows: []} = provider(snapshot_of(state), "openai")
    end

    test "a run's tokens count today for the provider it started on, from the store at start and from its updates" do
      provider = "provider-#{System.unique_integer([:positive])}"

      :ok =
        RunStore.put_run(%{
          repo_key: "default",
          run_id: "run-#{provider}",
          issue_id: "tokens",
          started_at: DateTime.utc_now(),
          provider: provider,
          tokens: %{total_tokens: 700}
        })

      pid = start_orchestrator(:ProviderTokensOrchestrator)
      assert :sys.get_state(pid).provider_tokens_today[provider] == 700

      running_entry = running_entry(issue("tokens", "MT-TOKENS", "In Progress"), provider)
      :sys.replace_state(pid, &%{&1 | running: %{"tokens" => running_entry}})

      usage = %{
        input_tokens: 18,
        uncached_input_tokens: 12,
        cached_input_tokens: 4,
        cache_creation_input_tokens: 2,
        output_tokens: 5,
        total_tokens: 23
      }

      update = %{event: :turn_completed, payload: %{method: "turn/completed", usage: usage}, timestamp: DateTime.utc_now()}
      send(pid, {:codex_worker_update, "tokens", update})

      assert :sys.get_state(pid).provider_tokens_today[provider] == 723
    end
  end

  defp provider(snapshot, provider), do: Enum.find(snapshot.providers, &(&1.provider == provider))

  defp running_entry(issue, provider) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_cached_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_cached_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: DateTime.utc_now(),
      run_profile: %{kind: :implementation, provider: provider, model: "m", effort: nil}
    }
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
