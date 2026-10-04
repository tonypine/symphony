defmodule SymphonyElixir.OrchestratorUsageLimitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Notifications, UsageLimit}

  @anthropic {"anthropic", :all}
  @openai {"openai", :all}

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-usage-limit-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-usage","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-usage","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, clock} = Agent.start_link(fn -> now end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      File.rm_rf(test_root)
    end)

    %{test_root: test_root, fake_claude: fake_claude, now: now, clock: clock}
  end

  defp write_usage_workflow!(ctx, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          workspace_root: Path.join(ctx.test_root, "workspaces"),
          agent_kind: "claude",
          agent_command: ctx.fake_claude,
          max_turns: 1,
          tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"]
        ],
        overrides
      )
    )
  end

  defp start_orchestrator(ctx, name) do
    clock = ctx.clock
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, name), clock: fn -> Agent.get(clock, & &1) end)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    await_boot_poll(pid)
    pid
  end

  # The boot tick starts an async poll whose running-state refresh stops any run the memory
  # tracker does not list. Wait for it to finish so it cannot end the runs `start_run!` fakes.
  defp await_boot_poll(pid) do
    wait_until(fn ->
      state = :sys.get_state(pid)
      not state.poll_check_in_progress and is_nil(state.repo_poll_task_ref) and is_nil(state.startup_workspace_lifecycle_task_ref)
    end)
  end

  defp set_clock(ctx, %DateTime{} = now), do: Agent.update(ctx.clock, fn _ -> now end)

  # Handles `message` inside the orchestrator and returns its state right after, before a poll
  # the message schedules can run against the memory tracker and change it.
  defp deliver(pid, message) do
    :sys.replace_state(pid, fn state ->
      {:noreply, state} = Orchestrator.handle_info(message, state)
      state
    end)
  end

  defp issue(id, identifier, attrs \\ %{}) do
    struct!(
      %Issue{
        id: id,
        identifier: identifier,
        title: "Usage limit #{identifier}",
        description: "Hold on the usage limit",
        state: "In Progress",
        team: %{key: "Test"},
        labels: [],
        url: "https://example.org/issues/#{identifier}"
      },
      attrs
    )
  end

  defp usage_info(ctx, attrs \\ %{}) do
    Map.merge(
      %{
        provider: "anthropic",
        window: "five_hour",
        scope: :all,
        resets_at: DateTime.add(ctx.now, 3600),
        utilization: 1.0,
        overage: nil,
        source: :rate_limit_event
      },
      attrs
    )
  end

  defp unknown_reset_info(ctx), do: usage_info(ctx, %{resets_at: nil, window: nil, source: :result_text})

  defp hold(ctx, attrs \\ %{}) do
    Map.merge(
      %{
        provider: "anthropic",
        scope: :all,
        reason: "claude_usage_limit",
        window: "five_hour",
        since: ctx.now,
        resets_at: DateTime.add(ctx.now, 3600),
        resume_at: DateTime.add(ctx.now, 3720),
        source: :rate_limit_event,
        phase: :paused,
        issue_identifier: "MT-HELD"
      },
      attrs
    )
  end

  defp running_entry(%Issue{} = issue, worker_pid, worker_ref, run_id, attrs) do
    Map.merge(
      %{
        pid: worker_pid,
        ref: worker_ref,
        run_id: run_id,
        identifier: issue.identifier,
        issue: issue,
        worker_host: nil,
        workspace_path: "/tmp/workspaces/#{issue.identifier}",
        session_id: nil,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        turn_count: 0,
        retry_attempt: 3,
        repo_key: Config.repo_key!(),
        started_at: DateTime.utc_now()
      },
      attrs
    )
  end

  defp start_run!(pid, %Issue{} = issue, attrs \\ %{}) do
    worker_pid = spawn(fn -> receive do: (:finish -> :ok) end)
    worker_ref = Process.monitor(worker_pid)
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
        attempt: 3,
        started_at: DateTime.utc_now()
      })

    entry = running_entry(issue, worker_pid, worker_ref, run_id, attrs)

    :sys.replace_state(pid, fn state ->
      %{state | running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)}
    end)

    on_exit(fn -> send(worker_pid, :finish) end)
    {worker_pid, worker_ref, run_id}
  end

  defp run_record(run_id), do: Enum.find(RunStore.list_runs(:all), &(&1.run_id == run_id))

  defp wait_until(fun, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false, []] ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("condition not met in time")
        Process.sleep(25)
        do_wait_until(fun, deadline)

      value ->
        value
    end
  end

  test "a usage-limited exit holds the retry with the same attempt, no backoff and no run_failed", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :PauseOrchestrator)
    issue = issue("issue-usage-pause", "MT-PAUSE")
    {worker_pid, worker_ref, run_id} = start_run!(pid, issue)
    :ok = Notifications.subscribe()

    log =
      capture_log(fn ->
        send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, usage_info(ctx)}})
        state = :sys.get_state(pid)
        send(self(), {:state, state})
      end)

    assert_received {:state, state}

    assert log =~
             "Usage limit pause provider=anthropic scope=all window=five_hour resets_at=#{DateTime.to_iso8601(DateTime.add(ctx.now, 3600))} " <>
               "resume_at=#{DateTime.to_iso8601(DateTime.add(ctx.now, 3720))} source=rate_limit_event issue_identifier=MT-PAUSE"

    assert %{attempt: 3, delay_type: :usage_limit, usage_limit_key: @anthropic, due_at_ms: due_at_ms, error: error} =
             state.retry_attempts[issue.id]

    assert error =~ "usage limit reached (provider=anthropic scope=all)"
    # The delay is the time left until resume_at (3720s), not an exponential backoff.
    delay_ms = due_at_ms - System.monotonic_time(:millisecond)
    assert delay_ms > 3_700_000 and delay_ms <= 3_720_000

    assert %{resume_at: resume_at, phase: :paused, reason: "claude_usage_limit"} = state.usage_limits[@anthropic]
    assert resume_at == DateTime.add(ctx.now, 3720)
    assert is_reference(state.usage_limit_timers[@anthropic])
    assert %{@anthropic => %{resume_at: ^resume_at}} = RunStore.get_usage_limits()
    assert MapSet.member?(state.claimed, issue.id)

    assert %{status: "usage_limited"} = run_record(run_id)
    assert [%{attempt: 3, delay_type: :usage_limit, workspace_path: "/tmp/workspaces/MT-PAUSE"}] = RunStore.list_retries(:all)
    refute_receive {:notification_event, %Notifications.Event{event: "run_failed"}}, 100
  end

  test "a first-run usage-limited exit holds attempt 1, and a refresh keeps the later resume time", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :RefreshOrchestrator)
    first = issue("issue-usage-first", "MT-FIRST")
    second = issue("issue-usage-second", "MT-SECOND")
    {first_pid, first_ref, _run_id} = start_run!(pid, first, %{retry_attempt: 0})
    {second_pid, second_ref, _run_id} = start_run!(pid, second)

    send(pid, {:DOWN, first_ref, :process, first_pid, {:usage_limited, usage_info(ctx)}})
    :sys.get_state(pid)
    # An in-flight run of the same provider hitting the limit without a reset time refreshes the hold.
    log =
      capture_log(fn ->
        send(pid, {:DOWN, second_ref, :process, second_pid, {:usage_limited, unknown_reset_info(ctx)}})
        :sys.get_state(pid)
      end)

    refute log =~ "Usage limit pause"
    state = :sys.get_state(pid)
    assert %{attempt: 1} = state.retry_attempts[first.id]
    assert %{attempt: 3} = state.retry_attempts[second.id]
    assert map_size(state.usage_limits) == 1
    assert state.usage_limits[@anthropic].resume_at == DateTime.add(ctx.now, 3720)
  end

  test "auto_pause false keeps today's failure handling", ctx do
    write_usage_workflow!(ctx, agent_usage_limit: %{auto_pause: false})
    pid = start_orchestrator(ctx, :AutoPauseOffOrchestrator)
    issue = issue("issue-usage-off", "MT-OFF")
    {worker_pid, worker_ref, run_id} = start_run!(pid, issue)
    :ok = Notifications.subscribe()

    send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, usage_info(ctx)}})
    state = :sys.get_state(pid)

    assert state.usage_limits == %{}
    assert %{attempt: 4, delay_type: nil} = state.retry_attempts[issue.id]
    assert %{status: "failure"} = run_record(run_id)
    assert_receive {:notification_event, %Notifications.Event{event: "run_failed"}}, 1_000
    assert RunStore.get_usage_limits() == %{}
  end

  test "a PR run that hits the usage limit creates the hold and is not retried", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :PrRunOrchestrator)
    issue = issue("pr:default:7", "PR-7")
    {worker_pid, worker_ref, _run_id} = start_run!(pid, issue, %{run_kind: :pr})

    send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, usage_info(ctx)}})
    state = :sys.get_state(pid)

    assert Map.has_key?(state.usage_limits, @anthropic)
    refute Map.has_key?(state.retry_attempts, issue.id)
  end

  test "an anthropic hold skips Claude candidates while an openrouter profile still dispatches", ctx do
    write_usage_workflow!(ctx, agent_run_profiles: %{"rework" => %{"provider" => "openrouter", "model" => "openai/gpt-5"}})
    state = %{orchestrator_state() | usage_limits: %{@anthropic => hold(ctx)}}

    log =
      capture_log([level: :debug], fn ->
        refute Orchestrator.should_dispatch_issue_for_test(issue("i-claude", "MT-CLAUDE"), state)
      end)

    assert log =~ "Skipping dispatch; usage limit holds provider=anthropic scope=all"
    assert Orchestrator.should_dispatch_issue_for_test(issue("i-or", "MT-OR", %{state: "Rework"}), state)
    assert Orchestrator.should_dispatch_issue_for_test(issue("i-claude", "MT-CLAUDE"), orchestrator_state())
  end

  test "a Codex hold skips Codex candidates while Claude candidates still dispatch, and the reverse", ctx do
    openai_hold = hold(ctx, %{provider: "openai", reason: "codex_usage_limit", window: "primary"})
    codex_hold = %{orchestrator_state() | usage_limits: %{@openai => openai_hold}}
    claude_hold = %{orchestrator_state() | usage_limits: %{@anthropic => hold(ctx)}}
    candidate = issue("i-run", "MT-RUN")

    write_usage_workflow!(ctx, agent_kind: "codex", agent_command: "codex app-server")

    log =
      capture_log([level: :debug], fn ->
        refute Orchestrator.should_dispatch_issue_for_test(candidate, codex_hold)
      end)

    assert log =~ "Skipping dispatch; usage limit holds provider=openai scope=all"
    assert Orchestrator.should_dispatch_issue_for_test(candidate, claude_hold)

    write_usage_workflow!(ctx)

    refute Orchestrator.should_dispatch_issue_for_test(candidate, claude_hold)
    assert Orchestrator.should_dispatch_issue_for_test(candidate, codex_hold)
  end

  test "a Codex usage-limited exit holds only the openai provider", ctx do
    write_usage_workflow!(ctx, agent_kind: "codex", agent_command: "codex app-server")
    pid = start_orchestrator(ctx, :CodexPauseOrchestrator)
    issue = issue("issue-codex-pause", "MT-CODEX")
    {worker_pid, worker_ref, _run_id} = start_run!(pid, issue)
    info = usage_info(ctx, %{provider: "openai", window: "primary", utilization: 1.0, source: :codex_error})

    send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, info}})
    state = :sys.get_state(pid)

    assert %{attempt: 3, delay_type: :usage_limit, usage_limit_key: @openai} = state.retry_attempts[issue.id]
    assert Map.keys(state.usage_limits) == [@openai]
    assert %{reason: "codex_usage_limit", window: "primary", resume_at: resume_at} = state.usage_limits[@openai]
    assert resume_at == DateTime.add(ctx.now, 3720)
    assert %{@openai => %{provider: "openai"}} = RunStore.get_usage_limits()
  end

  test "a seven_day_opus hold skips only Opus runs", ctx do
    write_usage_workflow!(ctx,
      agent_model: "claude-sonnet-5-5",
      agent_run_profiles: %{"landing" => %{"model" => "claude-opus-5-5"}}
    )

    state = %{orchestrator_state() | usage_limits: %{{"anthropic", "opus"} => hold(ctx, %{scope: "opus", window: "seven_day_opus"})}}

    refute Orchestrator.should_dispatch_issue_for_test(issue("i-land", "MT-LAND", %{state: "Merging"}), state)
    assert Orchestrator.should_dispatch_issue_for_test(issue("i-land", "MT-LAND", %{state: "Merging"}), orchestrator_state())
    assert Orchestrator.should_dispatch_issue_for_test(issue("i-impl", "MT-IMPL"), state)
  end

  test "a retry that comes due while the provider is held is held again with its attempt", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :RetryHoldOrchestrator)
    issue = issue("issue-usage-retry", "MT-RETRY")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    state = %{:sys.get_state(pid) | usage_limits: %{@anthropic => hold(ctx)}}

    assert {:noreply, state} =
             Orchestrator.handle_retry_issue_for_test(state, issue.id, 2, %{identifier: issue.identifier}, fn _ids -> {:ok, [issue]} end)

    assert %{attempt: 2, delay_type: :usage_limit, usage_limit_key: @anthropic, due_at_ms: due_at_ms} = state.retry_attempts[issue.id]
    assert due_at_ms - System.monotonic_time(:millisecond) > 3_700_000
    Process.cancel_timer(state.retry_attempts[issue.id].timer_ref)
  end

  test "the resume timer dispatches the held issue as the canary with the same attempt, and its clean exit clears the hold", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :ResumeOrchestrator)
    issue = issue("issue-usage-resume", "MT-RESUME")
    {worker_pid, worker_ref, _run_id} = start_run!(pid, issue)
    send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, usage_info(ctx)}})
    assert %{attempt: 3} = :sys.get_state(pid).retry_attempts[issue.id]

    # A timer that fires early (the hold was refreshed) changes nothing.
    send(pid, {:usage_limit_resume, @anthropic})
    assert Map.has_key?(:sys.get_state(pid).usage_limits, @anthropic)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    :sys.replace_state(pid, &%{&1 | repo_poll_due_at_ms: %{}})
    set_clock(ctx, DateTime.add(ctx.now, 3720))

    log =
      capture_log(fn ->
        send(pid, {:usage_limit_resume, @anthropic})
        wait_until(fn -> Enum.find(RunStore.list_runs(:all), &(&1.issue_id == issue.id and &1.status != "usage_limited")) end)
        wait_until(fn -> :sys.get_state(pid).usage_limits == %{} end)
      end)

    assert log =~ "Usage limit canary provider=anthropic scope=all issue_identifier=MT-RESUME"
    assert log =~ "Usage limit resumed provider=anthropic scope=all paused_for_s=3720"
    assert %{attempt: 3} = Enum.find(RunStore.list_runs(:all), &(&1.issue_id == issue.id and &1.status != "usage_limited"))
    assert RunStore.get_usage_limits() == %{}
    refute Map.has_key?(:sys.get_state(pid).usage_limits, @anthropic)

    # A resume for a hold that is already gone is ignored.
    send(pid, {:usage_limit_resume, @anthropic})
    assert :sys.get_state(pid).usage_limits == %{}
  end

  test "the snapshot lists the hold and its blocker, and one event goes out per transition", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :SnapshotOrchestrator)
    first = issue("issue-usage-snap-1", "MT-SNAP-1")
    second = issue("issue-usage-snap-2", "MT-SNAP-2")
    {first_pid, first_ref, _run_id} = start_run!(pid, first)
    {second_pid, second_ref, _run_id} = start_run!(pid, second)
    :ok = Notifications.subscribe()

    assert %{usage_limits: [], dispatch_state: %{active?: true, blockers: []}} = GenServer.call(pid, :snapshot)

    send(pid, {:codex_worker_update, first.id, %{event: :notification, timestamp: DateTime.utc_now(), usage_windows: %{"five_hour" => %{resets_at: DateTime.add(ctx.now, 3600), utilization: 0.97}}}})
    # Both runs hit the same limit: one hold, one "paused" event.
    send(pid, {:DOWN, first_ref, :process, first_pid, {:usage_limited, usage_info(ctx)}})
    send(pid, {:DOWN, second_ref, :process, second_pid, {:usage_limited, usage_info(ctx)}})
    snapshot = GenServer.call(pid, :snapshot)

    resume_at = DateTime.add(ctx.now, 3720)
    resets_at = DateTime.add(ctx.now, 3600)

    assert [
             %{
               provider: "anthropic",
               scope: :all,
               reason: "claude_usage_limit",
               window: "five_hour",
               phase: :paused,
               since: since,
               resets_at: ^resets_at,
               resume_at: ^resume_at,
               source: :rate_limit_event,
               utilization: 0.97,
               issue_identifier: "MT-SNAP-2"
             }
           ] = snapshot.usage_limits

    assert since == ctx.now

    # Every run profile is Claude, so dispatch is paused.
    assert %{active?: false, blockers: [blocker]} = snapshot.dispatch_state

    assert blocker == %{
             kind: :usage_limit,
             provider: "anthropic",
             scope: :all,
             window: "five_hour",
             resets_at: resets_at,
             resume_at: resume_at,
             phase: :paused
           }

    assert_receive {:notification_event, %Notifications.Event{event: "usage_limit_paused"} = paused}, 1_000
    assert paused.issue_identifier == "MT-SNAP-1"
    assert paused.reason == "Claude 5-hour limit; resumes at #{DateTime.to_iso8601(resume_at)}"
    assert %{provider: "anthropic", scope: "all", window: "five_hour", resume_at: ^resume_at} = paused.metadata
    refute_receive {:notification_event, %Notifications.Event{event: "usage_limit_paused"}}, 100

    set_clock(ctx, resume_at)

    # Starting the canary is not a resume: the hold stays, shown in the canary phase.
    capture_log(fn -> deliver(pid, {:usage_limit_resume, @anthropic}) end)

    assert %{usage_limits: [%{phase: :canary}], dispatch_state: %{blockers: [%{phase: :canary}]}} = GenServer.call(pid, :snapshot)
    refute_receive {:notification_event, %Notifications.Event{event: "usage_limit_resumed"}}, 100
  end

  # The ticket walkthrough end to end: a fake `claude` rejects the five-hour window once.
  test "a rejected five_hour window pauses, shows in the state API and banner, then resumes", ctx do
    # The limit resets an hour from the injected clock; the test moves the clock there.
    resume_at = DateTime.add(ctx.now, 3600)
    rejected_once = Path.join(ctx.test_root, "rejected-once")
    fake_claude = Path.join(ctx.test_root, "fake-claude-limited")

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    if [ ! -f #{rejected_once} ]; then
      touch #{rejected_once}
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-limit","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
      printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"five_hour","utilization":1.0},"session_id":"sess-limit"}\\n' #{DateTime.to_unix(resume_at)}
      exit 1
    fi
    exec #{ctx.fake_claude}
    """)

    File.chmod!(fake_claude, 0o755)

    write_usage_workflow!(%{ctx | fake_claude: fake_claude},
      agent_usage_limit: %{resume_margin_seconds: 0},
      tracker_active_states: ["Todo"]
    )

    issue = issue("issue-usage-walk", "MT-WALK", %{state: "Todo"})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    :ok = Notifications.subscribe()

    name = Module.concat(__MODULE__, :WalkthroughOrchestrator)

    capture_log(fn ->
      pid = start_orchestrator(ctx, :WalkthroughOrchestrator)

      # 1. The run ends usage_limited.
      wait_until(fn -> Enum.find(RunStore.list_runs(:all), &(&1.issue_id == issue.id and &1.status == "usage_limited")) end)

      # 2. and 3. The state API lists the hold and its blocker; the banner reads from it. The API
      # reads the last published snapshot, so wait for one taken after the pause.
      payload =
        wait_until(fn ->
          payload = SymphonyElixirWeb.Presenter.state_payload(name, 1_000)
          payload.usage_limits != [] and payload
        end)

      expected_resume_at = DateTime.to_iso8601(resume_at)
      assert [%{provider: "anthropic", window: "five_hour", resume_at: ^expected_resume_at} = hold] = payload.usage_limits
      assert [%{kind: :usage_limit, provider: "anthropic", window: "five_hour"}] = payload.dispatch_state.blockers
      assert payload.dispatch_state.active? == false
      assert UsageLimit.banner(hold, DateTime.utc_now()) =~ ~r/^Paused: Claude 5-hour limit, resumes ~\d{2}:\d{2}$/

      # 4. Past resume_at the hold clears and the issue runs again.
      set_clock(ctx, resume_at)
      send(pid, {:usage_limit_resume, @anthropic})
      wait_until(fn -> SymphonyElixirWeb.Presenter.state_payload(name, 1_000).usage_limits == [] end)
      assert SymphonyElixirWeb.Presenter.state_payload(name, 1_000).dispatch_state.blockers == []
      wait_until(fn -> Enum.find(RunStore.list_runs(:all), &(&1.issue_id == issue.id and &1.status != "usage_limited")) end)
    end)

    assert_receive {:notification_event, %Notifications.Event{event: "usage_limit_paused", issue_identifier: "MT-WALK"}}, 1_000
    assert_receive {:notification_event, %Notifications.Event{event: "usage_limit_resumed"}}, 1_000
    refute_receive {:notification_event, %Notifications.Event{event: "usage_limit_" <> _}}, 200
  end

  test "a partial hold is listed but leaves dispatch active for the other provider", ctx do
    write_usage_workflow!(ctx, agent_run_profiles: %{"rework" => %{"provider" => "openrouter", "model" => "openai/gpt-5"}})
    pid = start_orchestrator(ctx, :PartialHoldOrchestrator)
    :sys.replace_state(pid, &%{&1 | usage_limits: %{@anthropic => hold(ctx)}})

    assert %{usage_limits: [%{provider: "anthropic"}], dispatch_state: %{active?: true, blockers: [%{kind: :usage_limit}]}} =
             GenServer.call(pid, :snapshot)
  end

  test "an operator pause set during the hold stays paused after auto-resume", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :OperatorPauseOrchestrator)
    on_exit(fn -> RunStore.set_paused(false, nil) end)
    issue = issue("issue-usage-operator", "MT-OPERATOR")
    {worker_pid, worker_ref, _run_id} = start_run!(pid, issue)
    send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, usage_info(ctx)}})

    assert {:ok, %{paused: true}} = Orchestrator.pause_dispatch(pid, "maintenance")
    set_clock(ctx, DateTime.add(ctx.now, 3720))
    state = deliver(pid, {:usage_limit_resume, @anthropic})

    assert %{phase: :canary, canary_issue_id: "issue-usage-operator"} = state.usage_limits[@anthropic]
    assert %{paused: true, reason: "maintenance"} = state.pause
    assert %{paused: true} = RunStore.get_paused()
    assert %{attempt: 3, reason: "usage limit resumed"} = state.slot_waiting[issue.id]
    refute Map.has_key?(state.retry_attempts, issue.id)
    refute MapSet.member?(state.claimed, issue.id)
  end

  test "the hold survives a restart and its timer is re-armed", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :RestartOrchestrator)
    issue = issue("issue-usage-restart", "MT-RESTART")
    {worker_pid, worker_ref, _run_id} = start_run!(pid, issue)
    send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, usage_info(ctx)}})
    :sys.get_state(pid)
    GenServer.stop(pid)

    restarted = start_orchestrator(ctx, :RestartedOrchestrator)
    state = :sys.get_state(restarted)

    assert %{resume_at: resume_at, issue_identifier: "MT-RESTART"} = state.usage_limits[@anthropic]
    assert resume_at == DateTime.add(ctx.now, 3720)
    assert remaining = Process.read_timer(state.usage_limit_timers[@anthropic])
    assert remaining > 3_700_000
    assert %{attempt: 3, usage_limit_key: @anthropic, delay_type: :usage_limit} = state.retry_attempts[issue.id]

    set_clock(ctx, DateTime.add(ctx.now, 3720))
    assert %{attempt: 3} = deliver(restarted, {:usage_limit_resume, @anthropic}).slot_waiting[issue.id]
  end

  test "an unknown reset uses the remembered window reset time from worker updates", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :WindowsOrchestrator)
    issue = issue("issue-usage-windows", "MT-WINDOWS")
    {worker_pid, worker_ref, _run_id} = start_run!(pid, issue)
    seven_day_reset = DateTime.add(ctx.now, 86_400)

    send(
      pid,
      {:codex_worker_update, issue.id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: "rate_limit seven_day allowed_warning",
         usage_windows: %{
           "five_hour" => %{status: "allowed", resets_at: DateTime.add(ctx.now, 600), utilization: 0.4},
           "seven_day" => %{status: "allowed_warning", resets_at: seven_day_reset, utilization: 0.97}
         }
       }}
    )

    send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, unknown_reset_info(ctx)}})
    state = :sys.get_state(pid)

    assert state.usage_limits[@anthropic].resume_at == DateTime.add(seven_day_reset, 120)
    assert %{{"anthropic", "seven_day"} => %{resets_at: ^seven_day_reset}} = state.usage_windows
  end

  test "an operator PR dispatch is refused while the provider is held", ctx do
    root = Path.join(ctx.test_root, "pr-repo")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ["-C", root, "init", "-b", "main"], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", root, "remote", "add", "origin", "git@github.com:example/repo.git"], stderr_to_stdout: true)
    write_usage_workflow!(ctx, workspace_strategy: "worktree", workspace_repo: root)
    pid = start_orchestrator(ctx, :PrDispatchOrchestrator)
    :sys.replace_state(pid, &%{&1 | usage_limits: %{@anthropic => hold(ctx)}})

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
    assert {:error, :usage_limited} = Orchestrator.dispatch_pr(pid, "123", gh_runner: gh_runner)
  end

  # Holds `held` on the usage limit, then makes `canary` (left running) the hold's canary.
  defp start_canary!(ctx, pid, %Issue{} = canary, held) do
    {canary_pid, canary_ref, _run_id} = start_run!(pid, canary)

    for %Issue{} = issue <- held do
      {worker_pid, worker_ref, _run_id} = start_run!(pid, issue)
      send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, usage_info(ctx)}})
    end

    :sys.replace_state(pid, fn state ->
      %{state | usage_limits: %{@anthropic => UsageLimit.canary(state.usage_limits[@anthropic], canary.id)}}
    end)

    {canary_pid, canary_ref}
  end

  test "at resume_at only the first held run in dispatch order goes out, and the hold keeps the provider's slots", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :CanaryOrchestrator)
    working = issue("issue-canary-working", "MT-WORKING")
    landing = issue("issue-canary-landing", "MT-LANDING", %{state: "Merging"})

    for %Issue{} = held <- [working, landing] do
      {worker_pid, worker_ref, _run_id} = start_run!(pid, held)
      send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, usage_info(ctx)}})
    end

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [working, landing])
    set_clock(ctx, DateTime.add(ctx.now, 3720))

    log =
      capture_log(fn -> send(self(), {:state, deliver(pid, {:usage_limit_resume, @anthropic})}) end)

    assert_received {:state, state}
    assert log =~ "Usage limit canary provider=anthropic scope=all issue_identifier=MT-LANDING"
    assert %{phase: :canary, canary_issue_id: "issue-canary-landing"} = state.usage_limits[@anthropic]
    assert %{phase: :canary} = RunStore.get_usage_limits()[@anthropic]
    assert %{attempt: 3} = state.slot_waiting[landing.id]
    assert %{attempt: 3, usage_limit_key: @anthropic} = state.retry_attempts[working.id]
    refute Map.has_key?(state.usage_limit_timers, @anthropic)

    # Only the canary may take a slot: the other held run and new Claude work stay held.
    assert Orchestrator.should_dispatch_issue_for_test(landing, %{state | claimed: MapSet.new()})
    refute Orchestrator.should_dispatch_issue_for_test(working, %{state | claimed: MapSet.new()})
    refute Orchestrator.should_dispatch_issue_for_test(issue("issue-canary-fresh", "MT-FRESH", %{state: "Todo"}), state)

    # A late resume timer leaves the canary alone, and a held retry that comes due waits the
    # unknown-reset interval rather than spinning.
    assert {:noreply, late} = Orchestrator.handle_info({:usage_limit_resume, @anthropic}, state)
    assert %{phase: :canary, canary_issue_id: "issue-canary-landing"} = late.usage_limits[@anthropic]

    assert {:noreply, retried} =
             Orchestrator.handle_retry_issue_for_test(state, working.id, 3, %{identifier: working.identifier}, fn _ids -> {:ok, [working]} end)

    assert %{attempt: 3, delay_type: :usage_limit, due_at_ms: due_at_ms} = retried.retry_attempts[working.id]
    delay_ms = due_at_ms - System.monotonic_time(:millisecond)
    assert delay_ms > 890_000 and delay_ms <= 900_000
    Process.cancel_timer(retried.retry_attempts[working.id].timer_ref)
  end

  test "the canary falls back to issue id order when the tracker cannot order the held runs", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :CanaryFallbackOrchestrator)

    for %Issue{} = held <- [issue("issue-canary-b", "MT-B"), issue("issue-canary-a", "MT-A")] do
      {worker_pid, worker_ref, _run_id} = start_run!(pid, held)
      send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, usage_info(ctx)}})
    end

    state = :sys.get_state(pid)
    on_exit(fn -> Enum.each(state.retry_attempts, fn {_id, retry} -> Process.cancel_timer(retry.timer_ref) end) end)

    for fetcher <- [fn _ids -> {:error, :boom} end, fn _ids -> {:ok, []} end] do
      canary_state = Orchestrator.start_usage_limit_canary_for_test(state, @anthropic, fetcher)
      assert %{canary_issue_id: "issue-canary-a"} = canary_state.usage_limits[@anthropic]
    end
  end

  test "with nothing held at resume_at the hold clears without a canary", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :CanaryEmptyOrchestrator)
    :sys.replace_state(pid, &%{&1 | usage_limits: %{@anthropic => hold(ctx)}})
    set_clock(ctx, DateTime.add(ctx.now, 3720))

    log =
      capture_log(fn ->
        send(pid, {:usage_limit_resume, @anthropic})
        :sys.get_state(pid)
      end)

    assert :sys.get_state(pid).usage_limits == %{}
    assert log =~ "Usage limit resumed provider=anthropic scope=all paused_for_s=3720"
    refute log =~ "Usage limit canary"
  end

  test "an allowed rate_limit_event from the canary clears the hold and releases the rest", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :CanaryAllowedOrchestrator)
    canary = issue("issue-canary-allowed", "MT-CANARY")
    held = issue("issue-canary-rest", "MT-REST")
    start_canary!(ctx, pid, canary, [held])
    :ok = Notifications.subscribe()

    # Updates without usage windows say nothing about the limit.
    send(pid, {:codex_worker_update, canary.id, %{event: :notification, timestamp: DateTime.utc_now(), payload: "hi", usage_windows: %{}}})
    assert %{phase: :canary} = :sys.get_state(pid).usage_limits[@anthropic]

    send(
      pid,
      {:codex_worker_update, canary.id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: "rate_limit five_hour allowed",
         usage_windows: %{"five_hour" => %{status: "allowed", resets_at: DateTime.add(ctx.now, 18_000), utilization: 0.01}}
       }}
    )

    state = :sys.get_state(pid)
    assert state.usage_limits == %{}
    assert RunStore.get_usage_limits() == %{}
    refute Map.has_key?(state.retry_attempts, held.id)
    assert Map.has_key?(state.running, canary.id)

    # The hold clears once, when the canary clears it.
    assert_receive {:notification_event, %Notifications.Event{event: "usage_limit_resumed"} = resumed}, 1_000
    assert resumed.reason == "Claude 5-hour limit"
    assert resumed.issue_identifier == nil
    refute_receive {:notification_event, %Notifications.Event{event: "usage_limit_resumed"}}, 100
  end

  test "a canary that hits the limit again pauses with the new reset, keeps its attempt and logs it once", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :CanaryRepauseOrchestrator)
    canary = issue("issue-canary-limited", "MT-CANARY")
    held = issue("issue-canary-waiting", "MT-WAITING")
    {canary_pid, canary_ref} = start_canary!(ctx, pid, canary, [held])
    :ok = Notifications.subscribe()
    set_clock(ctx, DateTime.add(ctx.now, 3720))
    next_reset = DateTime.add(ctx.now, 7200)

    log =
      capture_log(fn ->
        info = usage_info(ctx, %{resets_at: next_reset})
        send(pid, {:DOWN, canary_ref, :process, canary_pid, {:usage_limited, info}})
        :sys.get_state(pid)
      end)

    state = :sys.get_state(pid)
    assert log =~ "Usage limit still active provider=anthropic scope=all next_resume_at=#{DateTime.to_iso8601(DateTime.add(next_reset, 120))} issue_identifier=MT-CANARY"
    refute log =~ "Usage limit pause"
    refute log =~ "Usage limit resumed"

    assert %{phase: :paused, canary_issue_id: nil, since: since, resume_at: resume_at} = state.usage_limits[@anthropic]
    assert since == ctx.now
    assert resume_at == DateTime.add(next_reset, 120)
    assert is_reference(state.usage_limit_timers[@anthropic])
    assert %{attempt: 3, usage_limit_key: @anthropic} = state.retry_attempts[canary.id]
    assert %{attempt: 3, usage_limit_key: @anthropic} = state.retry_attempts[held.id]

    # Same episode: no second pause and no resume.
    refute_receive {:notification_event, %Notifications.Event{event: "usage_limit_" <> _}}, 100
  end

  test "a canary that fails for another reason clears the hold and retries on the normal path", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :CanaryFailOrchestrator)
    canary = issue("issue-canary-failed", "MT-CANARY")
    held = issue("issue-canary-next", "MT-NEXT")
    {canary_pid, canary_ref} = start_canary!(ctx, pid, canary, [held])

    state = deliver(pid, {:DOWN, canary_ref, :process, canary_pid, :boom})

    assert state.usage_limits == %{}
    assert %{attempt: 4, delay_type: nil} = state.retry_attempts[canary.id]
    refute Map.has_key?(state.retry_attempts, held.id)
  end

  test "a canary that left the active states is replaced by the next held run", ctx do
    write_usage_workflow!(ctx)
    pid = start_orchestrator(ctx, :CanaryGoneOrchestrator)
    held = issue("issue-canary-replacement", "MT-REPLACEMENT")
    {worker_pid, worker_ref, _run_id} = start_run!(pid, held)
    send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, usage_info(ctx)}})

    :sys.replace_state(pid, fn state ->
      %{state | usage_limits: %{@anthropic => UsageLimit.canary(state.usage_limits[@anthropic], "issue-canary-gone")}}
    end)

    state = :sys.get_state(pid)
    on_exit(fn -> Enum.each(state.retry_attempts, fn {_id, retry} -> Process.cancel_timer(retry.timer_ref) end) end)

    log = capture_log(fn -> send(self(), {:state, Orchestrator.dispatch_chosen_issues_for_test([], state)}) end)
    assert_received {:state, state}

    assert log =~ "Usage limit canary gone provider=anthropic scope=all issue_id=issue-canary-gone"
    assert %{phase: :canary, canary_issue_id: "issue-canary-replacement"} = state.usage_limits[@anthropic]
    assert %{attempt: 3} = state.slot_waiting[held.id]

    # A canary that was dispatched is left alone.
    claimed = %{state | claimed: MapSet.put(state.claimed, held.id)}
    assert Orchestrator.dispatch_chosen_issues_for_test([], claimed).usage_limits == state.usage_limits
  end

  test "a canary restored after a restart is chosen again at resume_at", ctx do
    write_usage_workflow!(ctx)
    :ok = RunStore.put_usage_limits(%{@anthropic => UsageLimit.canary(hold(ctx), "issue-canary-before-restart")})
    pid = start_orchestrator(ctx, :CanaryRestartOrchestrator)
    state = :sys.get_state(pid)

    assert %{phase: :paused, canary_issue_id: nil} = state.usage_limits[@anthropic]
    assert is_reference(state.usage_limit_timers[@anthropic])
  end

  defp orchestrator_state do
    %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  test "AgentRunner exits with the usage limit instead of raising", ctx do
    limited_claude = Path.join(ctx.test_root, "limited-claude")

    File.write!(limited_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-limited","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":true,"duration_ms":5,"num_turns":1,"result":"Claude AI usage limit reached|1790000000","session_id":"sess-limited","usage":{"input_tokens":0,"output_tokens":0}}'
    exit 1
    """)

    File.chmod!(limited_claude, 0o755)
    write_usage_workflow!(ctx, agent_command: limited_claude)
    workspace = Path.join([ctx.test_root, "workspaces", "MT-LIMITED"])
    File.mkdir_p!(workspace)
    run_issue = issue("issue-limited", "MT-LIMITED")

    assert {:usage_limited, %{provider: "anthropic", scope: :all, resets_at: resets_at, source: :result_text}} =
             catch_exit(
               AgentRunner.run(run_issue, nil,
                 workspace_path: workspace,
                 issue_state_fetcher: fn _ids -> {:ok, [run_issue]} end,
                 issue_enricher: fn issue -> {:ok, issue} end
               )
             )

    assert resets_at == DateTime.from_unix!(1_790_000_000)
  end

  test "AgentRunner exits with the Codex usage limit instead of raising", ctx do
    limited_codex = Path.join(ctx.test_root, "limited-codex")

    File.write!(limited_codex, """
    #!/bin/sh
    count=0

    while IFS= read -r _line; do
      count=$((count + 1))

      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thr_limited"}}}' ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn_limited","status":"inProgress","items":[]}}}'
          printf '%s\\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1790000000}}}}'
          printf '%s\\n' '{"method":"error","params":{"willRetry":false,"error":{"message":"You have hit your usage limit.","codexErrorInfo":"usageLimitExceeded"}}}'
          ;;
        *) sleep 1 ;;
      esac
    done
    """)

    File.chmod!(limited_codex, 0o755)
    write_usage_workflow!(ctx, agent_kind: "codex", agent_command: "#{limited_codex} app-server")
    workspace = Path.join([ctx.test_root, "workspaces", "MT-CODEX-LIMITED"])
    File.mkdir_p!(workspace)
    run_issue = issue("issue-codex-limited", "MT-CODEX-LIMITED")

    assert {:usage_limited, %{provider: "openai", scope: :all, window: "primary", resets_at: resets_at, source: :codex_error}} =
             catch_exit(
               AgentRunner.run(run_issue, nil,
                 workspace_path: workspace,
                 issue_state_fetcher: fn _ids -> {:ok, [run_issue]} end,
                 issue_enricher: fn issue -> {:ok, issue} end
               )
             )

    assert resets_at == DateTime.from_unix!(1_790_000_000)
  end

  test "UsageLimit.remaining_ms never goes negative", ctx do
    assert UsageLimit.remaining_ms(hold(ctx), DateTime.add(ctx.now, 4000)) == 0
  end
end
