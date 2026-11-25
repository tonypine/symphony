defmodule SymphonyElixir.OrchestratorUsageHeadroomTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Notifications, UsageLimit}

  @anthropic {"anthropic", :all}

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-usage-headroom-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-headroom","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-headroom","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    # A fixed instant, so a reset an hour ahead stays on the same day whatever the wall clock says.
    now = ~U[2026-10-03 12:00:00Z]
    {:ok, clock} = Agent.start_link(fn -> now end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      RunStore.put_usage_limits(%{})
      File.rm_rf(test_root)
    end)

    %{test_root: test_root, fake_claude: fake_claude, now: now, clock: clock}
  end

  defp write_headroom_workflow!(ctx, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          workspace_root: Path.join(ctx.test_root, "workspaces"),
          agent_kind: "claude",
          agent_command: ctx.fake_claude,
          max_turns: 1,
          tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"],
          execution_providers: %{anthropic: %{reserve: 0.9}}
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
      poll_idle? = not state.poll_check_in_progress and is_nil(state.repo_poll_task_ref)
      poll_idle? and is_nil(state.startup_workspace_lifecycle_task_ref)
    end)
  end

  defp set_clock(ctx, %DateTime{} = now), do: Agent.update(ctx.clock, fn _ -> now end)

  defp issue(id, identifier, attrs \\ %{}) do
    struct!(
      %Issue{
        id: id,
        identifier: identifier,
        title: "Headroom #{identifier}",
        description: "Leave room for interactive sessions",
        state: "In Progress",
        team: %{key: "Test"},
        labels: [],
        url: "https://example.org/issues/#{identifier}"
      },
      attrs
    )
  end

  defp start_run!(pid, %Issue{} = issue, attrs \\ %{}) do
    worker_pid = spawn(fn -> receive do: (:finish -> :ok) end)
    worker_ref = Process.monitor(worker_pid)

    entry = %{
      pid: worker_pid,
      ref: worker_ref,
      run_id: "run-#{issue.id}",
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
      retry_attempt: 0,
      repo_key: Config.repo_key!(),
      started_at: DateTime.utc_now()
    }

    entry = Map.merge(entry, attrs)

    :sys.replace_state(pid, fn state ->
      %{state | running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)}
    end)

    on_exit(fn -> send(worker_pid, :finish) end)
    {worker_pid, worker_ref}
  end

  defp warning_update(utilization, resets_at, status \\ "allowed_warning") do
    %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: "rate_limit five_hour #{status}",
      usage_windows: %{"five_hour" => %{status: status, resets_at: resets_at, utilization: utilization}}
    }
  end

  defp headroom_hold(ctx, attrs \\ %{}) do
    Map.merge(
      %{
        provider: "anthropic",
        scope: :all,
        reason: "claude_usage_headroom",
        window: "five_hour",
        since: ctx.now,
        resets_at: DateTime.add(ctx.now, 3600),
        resume_at: DateTime.add(ctx.now, 3720),
        source: :rate_limit_event,
        phase: :headroom,
        canary_issue_id: nil,
        issue_identifier: "MT-RUNNING",
        utilization: 0.92,
        reserve: 0.9
      },
      attrs
    )
  end

  # A retry reads its issue again in a task; the state is read once its answer is handled.
  defp retry_handled_state(pid) do
    wait_until(fn ->
      state = :sys.get_state(pid)
      state.tracker_tasks == %{} and state
    end)
  end

  defp wait_until(fun, timeout_ms \\ 15_000) do
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

  test "crossing the threshold holds new runs, leaves the running one alone and lets landing runs through", ctx do
    write_headroom_workflow!(ctx)
    pid = start_orchestrator(ctx, :CrossingOrchestrator)
    running = issue("issue-headroom-running", "MT-RUNNING")
    start_run!(pid, running)
    :ok = Notifications.subscribe()
    resets_at = DateTime.add(ctx.now, 3600)
    resume_at = DateTime.add(ctx.now, 3720)

    log =
      capture_log(fn ->
        send(pid, {:codex_worker_update, running.id, warning_update(0.92, resets_at)})
        # The same window reported higher raises the held utilization; reported again it changes nothing.
        send(pid, {:codex_worker_update, running.id, warning_update(0.93, resets_at)})
        send(pid, {:codex_worker_update, running.id, warning_update(0.93, resets_at)})
        :sys.get_state(pid)
      end)

    assert log =~
             "Usage limit headroom hold provider=anthropic utilization=0.92 reserve=0.9 scope=all window=five_hour " <>
               "resets_at=#{DateTime.to_iso8601(resets_at)} resume_at=#{DateTime.to_iso8601(resume_at)} issue_identifier=MT-RUNNING"

    assert log =~ "Usage limit headroom hold provider=anthropic utilization=0.93 reserve=0.9"
    assert length(String.split(log, "Usage limit headroom hold")) == 3

    state = :sys.get_state(pid)

    assert %{phase: :headroom, reason: "claude_usage_headroom", resume_at: ^resume_at, utilization: 0.93, reserve: 0.9} =
             state.usage_limits[@anthropic]

    assert is_reference(state.usage_limit_timers[@anthropic])
    assert %{@anthropic => %{phase: :headroom}} = RunStore.get_usage_limits()
    assert Map.has_key?(state.running, running.id)

    refute Orchestrator.should_dispatch_issue_for_test(issue("issue-headroom-new", "MT-NEW"), state)
    assert Orchestrator.should_dispatch_issue_for_test(issue("issue-headroom-land", "MT-LAND", %{state: "Merging"}), state)

    assert_receive {:notification_event, %Notifications.Event{event: "usage_limit_headroom"} = event}, 1_000
    assert event.issue_identifier == "MT-RUNNING"

    assert event.reason ==
             "Anthropic at its 90% reserve: holding new runs (Claude 5-hour limit at 92%) until #{DateTime.to_iso8601(resume_at)}"

    refute_receive {:notification_event, %Notifications.Event{event: "usage_limit_" <> _}}, 100

    # Landing runs still go out, so dispatch stays active with the hold listed.
    snapshot = GenServer.call(pid, :snapshot)
    assert [%{phase: :headroom, utilization: 0.93}] = snapshot.usage_limits
    assert %{active?: true, blockers: [blocker]} = snapshot.dispatch_state
    assert %{kind: :usage_limit, phase: :headroom, resume_at: ^resume_at} = blocker
    assert UsageLimit.banner(hd(snapshot.usage_limits), ctx.now, to_local: & &1) == "Holding new runs: Anthropic at its 90% reserve, resets ~13:00"
  end

  test "below the reserve, a refused window or no reserve holds nothing", ctx do
    resets_at = DateTime.add(ctx.now, 3600)
    running = issue("issue-headroom-off", "MT-OFF")

    for {name, overrides, update} <- [
          {:BelowOrchestrator, [], warning_update(0.89, resets_at)},
          {:RejectedOrchestrator, [], warning_update(0.95, resets_at, "rejected")},
          {:NullOrchestrator, [execution_providers: nil], warning_update(0.99, resets_at)}
        ] do
      write_headroom_workflow!(ctx, overrides)
      pid = start_orchestrator(ctx, name)
      start_run!(pid, running)
      send(pid, {:codex_worker_update, running.id, update})
      state = :sys.get_state(pid)

      assert state.usage_limits == %{}
      assert Orchestrator.should_dispatch_issue_for_test(issue("issue-headroom-other", "MT-OTHER"), state)
      GenServer.stop(pid)
    end
  end

  test "a pause in place is left alone, and a pause over a headroom hold replaces it as a new pause", ctx do
    write_headroom_workflow!(ctx)
    pid = start_orchestrator(ctx, :PauseOrchestrator)
    running = issue("issue-headroom-pause", "MT-PAUSE")
    {worker_pid, worker_ref} = start_run!(pid, running)
    paused = %{headroom_hold(ctx) | phase: :paused, reason: "claude_usage_limit", resume_at: DateTime.add(ctx.now, 600)}
    :sys.replace_state(pid, &%{&1 | usage_limits: %{@anthropic => paused}})

    send(pid, {:codex_worker_update, running.id, warning_update(0.95, DateTime.add(ctx.now, 3600))})
    assert :sys.get_state(pid).usage_limits == %{@anthropic => paused}

    :sys.replace_state(pid, &%{&1 | usage_limits: %{@anthropic => headroom_hold(ctx)}})
    :ok = Notifications.subscribe()
    info = %{provider: "anthropic", window: "five_hour", scope: :all, resets_at: DateTime.add(ctx.now, 3600), utilization: 1.0, source: :rate_limit_event}

    log =
      capture_log(fn ->
        send(pid, {:DOWN, worker_ref, :process, worker_pid, {:usage_limited, info}})
        :sys.get_state(pid)
      end)

    assert log =~ "Usage limit pause provider=anthropic scope=all window=five_hour"
    assert %{phase: :paused, reason: "claude_usage_limit", since: since} = :sys.get_state(pid).usage_limits[@anthropic]
    assert since == ctx.now
    assert_receive {:notification_event, %Notifications.Event{event: "usage_limit_paused", issue_identifier: "MT-PAUSE"}}, 1_000

    # A held run's retry names the headroom hold until the pause replaced it.
    held = issue("issue-headroom-held", "MT-HELD")
    state = %{:sys.get_state(pid) | usage_limits: %{@anthropic => headroom_hold(ctx)}}

    assert {:noreply, state} =
             Orchestrator.handle_retry_issue_for_test(state, held.id, 2, %{identifier: held.identifier}, fn _ids -> {:ok, [held]} end)

    assert %{attempt: 2, delay_type: :usage_limit, usage_limit_key: @anthropic, error: error} = state.retry_attempts[held.id]
    assert error == "provider at its reserve (provider=anthropic reserve=0.9 scope=all); resuming at #{DateTime.to_iso8601(DateTime.add(ctx.now, 3720))}"
    Process.cancel_timer(state.retry_attempts[held.id].timer_ref)
  end

  test "a continuation of a run that just ended is not held", ctx do
    write_headroom_workflow!(ctx)
    pid = start_orchestrator(ctx, :ContinuationOrchestrator)
    continuing = issue("issue-headroom-continue", "MT-CONTINUE")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [continuing])
    state = %{:sys.get_state(pid) | usage_limits: %{@anthropic => headroom_hold(ctx)}}
    metadata = %{identifier: continuing.identifier, continuation: true}

    assert {:noreply, state} = Orchestrator.handle_retry_issue_for_test(state, continuing.id, 1, metadata, fn _ids -> {:ok, [continuing]} end)

    assert Map.has_key?(state.running, continuing.id)
    refute Map.has_key?(state.retry_attempts, continuing.id)
  end

  test "a continuation deferred behind a dispatch readiness task stays a continuation and runs under the hold", ctx do
    write_headroom_workflow!(ctx, poll_interval_ms: 600_000)
    continuing = issue("issue-headroom-deferred", "MT-DEFERRED")
    # Listed after the boot poll, or it dispatches a run whose continuation replaces the planted retry.
    pid = start_orchestrator(ctx, :DeferredContinuationOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [continuing])
    token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | usage_limits: %{@anthropic => headroom_hold(ctx)},
          dispatch_readiness_tasks: %{make_ref() => %{kind: :poll, issues: []}},
          retry_attempts: %{
            continuing.id => %{attempt: 1, retry_token: token, identifier: continuing.identifier, delay_type: :continuation, repo_key: Config.repo_key!()}
          },
          claimed: MapSet.new([continuing.id])
      }
    end)

    capture_log(fn ->
      send(pid, {:retry_issue, continuing.id, token})
      state = retry_handled_state(pid)

      assert %{attempt: 1, delay_type: :continuation, retry_token: rescheduled} = state.retry_attempts[continuing.id]
      assert rescheduled != token
      refute Map.has_key?(state.slot_waiting, continuing.id)
      assert MapSet.member?(state.claimed, continuing.id)

      :sys.replace_state(pid, &%{&1 | dispatch_readiness_tasks: %{}})
      send(pid, {:retry_issue, continuing.id, rescheduled})

      wait_until(fn -> Enum.any?(RunStore.list_runs(:all), &(&1.issue_id == continuing.id)) end)
      assert %{phase: :headroom} = :sys.get_state(pid).usage_limits[@anthropic]
    end)
  end

  test "a continuation deferred behind a quality gate task stays a continuation and runs under the hold", ctx do
    write_headroom_workflow!(ctx, poll_interval_ms: 600_000)
    continuing = issue("issue-headroom-gate-deferred", "MT-GATE-DEFERRED")
    # Listed after the boot poll, or it dispatches a run whose continuation replaces the planted retry.
    pid = start_orchestrator(ctx, :GateDeferredContinuationOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [continuing])
    token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | usage_limits: %{@anthropic => headroom_hold(ctx)},
          quality_gate_tasks: %{make_ref() => :poll},
          retry_attempts: %{
            continuing.id => %{attempt: 1, retry_token: token, identifier: continuing.identifier, delay_type: :continuation, repo_key: Config.repo_key!()}
          },
          claimed: MapSet.new([continuing.id])
      }
    end)

    capture_log(fn ->
      send(pid, {:retry_issue, continuing.id, token})
      state = retry_handled_state(pid)

      assert %{attempt: 1, delay_type: :continuation, retry_token: rescheduled, error: "quality gate task already in flight; deferred"} =
               state.retry_attempts[continuing.id]

      assert rescheduled != token
      assert MapSet.member?(state.claimed, continuing.id)

      :sys.replace_state(pid, &%{&1 | quality_gate_tasks: %{}})
      send(pid, {:retry_issue, continuing.id, rescheduled})

      wait_until(fn -> Enum.any?(RunStore.list_runs(:all), &(&1.issue_id == continuing.id)) end)
      assert %{phase: :headroom} = :sys.get_state(pid).usage_limits[@anthropic]
    end)
  end

  test "a failure retry deferred behind a quality gate task does not become a continuation", ctx do
    write_headroom_workflow!(ctx, poll_interval_ms: 600_000)
    failed = issue("issue-headroom-gate-failure", "MT-GATE-FAILURE")
    # Listed after the boot poll, or it dispatches a run whose continuation replaces the planted retry.
    pid = start_orchestrator(ctx, :GateDeferredFailureOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [failed])
    token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | quality_gate_tasks: %{make_ref() => :poll},
          retry_attempts: %{failed.id => %{attempt: 2, retry_token: token, identifier: failed.identifier, repo_key: Config.repo_key!()}},
          claimed: MapSet.new([failed.id])
      }
    end)

    capture_log(fn ->
      send(pid, {:retry_issue, failed.id, token})

      assert %{attempt: 2, delay_type: nil, retry_token: rescheduled, error: "quality gate task already in flight; deferred"} =
               retry_handled_state(pid).retry_attempts[failed.id]

      assert rescheduled != token
    end)
  end

  test "the hold clears at resetsAt plus the margin without a canary and releases held runs", ctx do
    write_headroom_workflow!(ctx)
    pid = start_orchestrator(ctx, :ClearOrchestrator)
    held = issue("issue-headroom-release", "MT-RELEASE")
    state = %{:sys.get_state(pid) | usage_limits: %{@anthropic => headroom_hold(ctx)}}
    {:noreply, state} = Orchestrator.handle_retry_issue_for_test(state, held.id, 2, %{identifier: held.identifier}, fn _ids -> {:ok, [held]} end)
    :sys.replace_state(pid, fn _ -> state end)
    :ok = Notifications.subscribe()

    # A timer that fires early is armed again.
    set_clock(ctx, DateTime.add(ctx.now, 3719))
    send(pid, {:usage_limit_resume, @anthropic})
    state = :sys.get_state(pid)
    assert %{phase: :headroom} = state.usage_limits[@anthropic]
    assert is_reference(state.usage_limit_timers[@anthropic])

    set_clock(ctx, DateTime.add(ctx.now, 3720))

    log =
      capture_log(fn ->
        send(pid, {:usage_limit_resume, @anthropic})
        :sys.get_state(pid)
      end)

    state = :sys.get_state(pid)
    assert state.usage_limits == %{}
    assert RunStore.get_usage_limits() == %{}
    assert log =~ "Usage limit resumed provider=anthropic scope=all paused_for_s=3720"
    refute log =~ "Usage limit canary"
    refute Map.has_key?(state.retry_attempts, held.id)
    assert_receive {:notification_event, %Notifications.Event{event: "usage_limit_resumed", reason: "Claude 5-hour limit"}}, 1_000
  end

  test "a headroom hold survives a restart as a headroom hold", ctx do
    write_headroom_workflow!(ctx)
    :ok = RunStore.put_usage_limits(%{@anthropic => headroom_hold(ctx)})

    state = :sys.get_state(start_orchestrator(ctx, :RestartOrchestrator))

    assert %{phase: :headroom} = state.usage_limits[@anthropic]
    assert is_reference(state.usage_limit_timers[@anthropic])
  end

  # The ticket walkthrough: a fake `claude` warns at 92% of the five-hour window once, then succeeds.
  test "the running issue finishes and continues, new runs wait, and they dispatch after the reset", ctx do
    # The window resets an hour from the injected clock; the test moves the clock there.
    resets_at = DateTime.add(ctx.now, 3600)
    warned_once = Path.join(ctx.test_root, "warned-once")
    fake_claude = Path.join(ctx.test_root, "fake-claude-warning")

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-headroom","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    if [ ! -f #{warned_once} ]; then
      touch #{warned_once}
      printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":%s,"rateLimitType":"five_hour","utilization":0.92},"session_id":"sess-headroom"}\\n' #{DateTime.to_unix(resets_at)}
    fi
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-headroom","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    write_headroom_workflow!(%{ctx | fake_claude: fake_claude},
      agent_usage_limit: %{resume_margin_seconds: 0},
      execution_providers: %{anthropic: %{reserve: 0.9}},
      tracker_active_states: ["Todo"],
      poll_interval_ms: 250
    )

    first = issue("issue-headroom-walk", "MT-WALK", %{state: "Todo"})
    queued = issue("issue-headroom-queued", "MT-QUEUED", %{state: "Todo"})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [first])
    name = Module.concat(__MODULE__, :WalkthroughOrchestrator)
    runs_for = fn issue_id -> Enum.filter(RunStore.list_runs(:all), &(&1.issue_id == issue_id)) end

    # The snapshot waits up to 15 s: under the full suite the orchestrator can be busy for over a
    # second starting a run, and a timed-out snapshot has no usage_limits key.
    capture_log(fn ->
      pid = start_orchestrator(ctx, :WalkthroughOrchestrator)

      # 1. The warning puts the hold in place and the running issue finishes normally.
      wait_until(fn -> SymphonyElixirWeb.Presenter.state_payload(name, 15_000).usage_limits != [] end)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [first, queued])

      # 2. The state API carries the banner; the issue's continuation runs while new work waits.
      payload = SymphonyElixirWeb.Presenter.state_payload(name, 15_000)
      assert [%{phase: "headroom", reason: "claude_usage_headroom", utilization: 0.92, reserve: 0.9} = hold] = payload.usage_limits
      assert UsageLimit.banner(hold, ctx.now, to_local: & &1) == "Holding new runs: Anthropic at its 90% reserve, resets ~13:00"
      assert payload.dispatch_state.active? == true

      wait_until(fn -> length(runs_for.(first.id)) >= 2 end)
      assert Enum.all?(runs_for.(first.id), &(&1.status != "usage_limited"))
      assert :sys.get_state(pid).usage_limits != %{}
      assert runs_for.(queued.id) == []

      # 3. Past the reset the hold clears and the queued issue dispatches.
      set_clock(ctx, resets_at)
      send(pid, {:usage_limit_resume, @anthropic})
      wait_until(fn -> SymphonyElixirWeb.Presenter.state_payload(name, 15_000).usage_limits == [] end)
      wait_until(fn -> runs_for.(queued.id) != [] end)
    end)
  end

  describe "OpenCode Go's usage, read from its usage API (TP-1642)" do
    @opencode_go {"opencode-go", :all}
    @go_run %{provider: "opencode-go", model: "deepseek-v4.1-flash", fallback: nil, kind: :implementation}

    defp go_windows(ctx, weekly, status \\ "allowed") do
      %{
        "five_hour" => %{status: "allowed", utilization: 0.3, resets_at: DateTime.add(ctx.now, 2 * 3600)},
        "seven_day" => %{status: status, utilization: weekly, resets_at: DateTime.add(ctx.now, 3 * 86_400)},
        "monthly" => %{status: "allowed", utilization: 0.55, resets_at: DateTime.add(ctx.now, 20 * 86_400)}
      }
    end

    defp go_workflow!(ctx, reserves) do
      write_headroom_workflow!(ctx,
        execution_providers: reserves,
        agent_run_profiles: %{"implementation" => %{"provider" => "opencode-go", "model" => "deepseek-v4.1-flash"}}
      )
    end

    defp go_provider(pid), do: Enum.find(GenServer.call(pid, :snapshot).providers, &(&1.provider == "opencode-go"))

    test "its windows show on its provider entry, and a window at its reserve holds new runs on it until it resets", ctx do
      go_workflow!(ctx, %{anthropic: %{reserve: 0.9}, "opencode-go": %{reserve: 0.9}})
      pid = start_orchestrator(ctx, :GoReserveOrchestrator)
      new_run = issue("issue-go-new", "MT-GO-NEW")
      assert Orchestrator.should_dispatch_issue_for_test(new_run, :sys.get_state(pid))

      log =
        capture_log(fn ->
          send(pid, {:provider_usage_read, "opencode-go", {:ok, go_windows(ctx, 0.92)}})
          :sys.get_state(pid)
        end)

      state = :sys.get_state(pid)
      resets_at = DateTime.add(ctx.now, 3 * 86_400)

      assert %{phase: :headroom, provider: "opencode-go", window: "seven_day", utilization: 0.92, reserve: 0.9, resets_at: ^resets_at} =
               state.usage_limits[@opencode_go]

      refute Map.has_key?(state.usage_limits, @anthropic)
      refute Orchestrator.should_dispatch_issue_for_test(new_run, state)
      assert log =~ "Usage limit headroom hold provider=opencode-go utilization=0.92 reserve=0.9"
      assert UsageLimit.hold_label(state.usage_limits[@opencode_go]) == "OpenCode Go at its 90% reserve: holding new runs"

      assert %{usage_windows: windows, reserve: 0.9, at_reserve: true, held: true} = go_provider(pid)

      assert windows == [
               %{name: "five_hour", utilization: 0.3, resets_at: DateTime.add(ctx.now, 2 * 3600)},
               %{name: "monthly", utilization: 0.55, resets_at: DateTime.add(ctx.now, 20 * 86_400)},
               %{name: "seven_day", utilization: 0.92, resets_at: resets_at}
             ]

      # Anthropic's own windows stay apart.
      assert Enum.find(GenServer.call(pid, :snapshot).providers, &(&1.provider == "anthropic")).usage_windows == []

      # Past the reset the hold clears and runs go out on OpenCode Go again.
      set_clock(ctx, DateTime.add(resets_at, 3600))
      send(pid, {:usage_limit_resume, @opencode_go})
      wait_until(fn -> :sys.get_state(pid).usage_limits == %{} end)
      assert Orchestrator.should_dispatch_issue_for_test(new_run, :sys.get_state(pid))
    end

    test "a used-up window holds at the reserve too; below it, or with no reserve, nothing is held", ctx do
      go_workflow!(ctx, %{"opencode-go": %{reserve: 0.9}})
      pid = start_orchestrator(ctx, :GoUsedUpOrchestrator)
      send(pid, {:provider_usage_read, "opencode-go", {:ok, go_windows(ctx, 1.0, "rejected")}})
      assert %{phase: :headroom, window: "seven_day", utilization: 1.0} = :sys.get_state(pid).usage_limits[@opencode_go]
      GenServer.stop(pid)

      for {name, reserves, weekly} <- [
            {:GoBelowOrchestrator, %{"opencode-go": %{reserve: 0.9}}, 0.89},
            {:GoNoReserveOrchestrator, %{anthropic: %{reserve: 0.9}}, 1.0}
          ] do
        go_workflow!(ctx, reserves)
        pid = start_orchestrator(ctx, name)
        send(pid, {:provider_usage_read, "opencode-go", {:ok, go_windows(ctx, weekly)}})
        state = :sys.get_state(pid)

        assert state.usage_limits == %{}
        assert state.usage_windows[{"opencode-go", "seven_day"}].utilization == weekly
        assert Orchestrator.should_dispatch_issue_for_test(issue("issue-go-free", "MT-GO-FREE"), state)
        GenServer.stop(pid)
      end
    end

    test "a failed read keeps the last windows and holds nothing", ctx do
      go_workflow!(ctx, %{"opencode-go": %{reserve: 0.9}})
      pid = start_orchestrator(ctx, :GoFailedReadOrchestrator)
      send(pid, {:provider_usage_read, "opencode-go", {:ok, go_windows(ctx, 0.5)}})
      before = :sys.get_state(pid).usage_windows

      log =
        capture_log(fn ->
          send(pid, {:provider_usage_read, "opencode-go", {:error, {:http_status, 403}}})
          :sys.get_state(pid)
        end)

      state = :sys.get_state(pid)
      assert state.usage_windows == before
      assert state.usage_limits == %{}
      assert log =~ "Provider usage read failed; keeping the last windows provider=opencode-go"
      assert log =~ "HTTP 403"
    end

    test "it is read at boot, when a run on it starts and ends, and while it works at most once a minute", ctx do
      test = self()
      windows = go_windows(ctx, 0.5)

      Application.put_env(:symphony_elixir, :provider_usage_reader, fn provider ->
        send(test, {:usage_read, provider})
        {:ok, windows}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :provider_usage_reader) end)
      go_workflow!(ctx, %{"opencode-go": %{reserve: 0.9}})
      pid = start_orchestrator(ctx, :GoTriggersOrchestrator)

      # Boot.
      assert_receive {:usage_read, "opencode-go"}, 5_000
      wait_until(fn -> :sys.get_state(pid).usage_windows[{"opencode-go", "five_hour"}] end)

      # A run on Anthropic reads nothing of OpenCode Go's.
      claude = issue("issue-go-claude", "MT-GO-CLAUDE")
      start_run!(pid, claude, %{run_profile: %{@go_run | provider: "anthropic"}})
      send(pid, {:codex_worker_update, claude.id, %{event: :notification, timestamp: DateTime.utc_now(), payload: "working"}})
      :sys.get_state(pid)
      refute_receive {:usage_read, _provider}, 200

      # A run on OpenCode Go working: its first update within the minute after boot reads nothing;
      # a minute later it reads, and once more only after another minute.
      go = issue("issue-go-run", "MT-GO-RUN")
      {worker_pid, worker_ref} = start_run!(pid, go, %{run_profile: @go_run})
      update = %{event: :notification, timestamp: DateTime.utc_now(), payload: "working"}
      send(pid, {:codex_worker_update, go.id, update})
      :sys.get_state(pid)
      refute_receive {:usage_read, _provider}, 200

      set_clock(ctx, DateTime.add(ctx.now, 61))
      send(pid, {:codex_worker_update, go.id, update})
      send(pid, {:codex_worker_update, go.id, update})
      assert_receive {:usage_read, "opencode-go"}, 5_000
      :sys.get_state(pid)
      refute_receive {:usage_read, _provider}, 200

      # The run ends: read at once.
      capture_log(fn ->
        send(pid, {:DOWN, worker_ref, :process, worker_pid, :normal})
        assert_receive {:usage_read, "opencode-go"}, 5_000
        :sys.get_state(pid)
      end)
    end
  end
end
