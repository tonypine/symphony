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

    now = DateTime.utc_now() |> DateTime.truncate(:second)
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
          tracker_kind: "memory",
          workspace_root: Path.join(ctx.test_root, "workspaces"),
          agent_kind: "claude",
          agent_command: ctx.fake_claude,
          max_turns: 1,
          tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"],
          agent_usage_limit: %{headroom_utilization: 0.9}
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

    :sys.get_state(pid)
    pid
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

  defp start_run!(pid, %Issue{} = issue) do
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
        utilization: 0.92
      },
      attrs
    )
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
             "Usage limit headroom hold provider=anthropic utilization=0.92 threshold=0.9 scope=all window=five_hour " <>
               "resets_at=#{DateTime.to_iso8601(resets_at)} resume_at=#{DateTime.to_iso8601(resume_at)} issue_identifier=MT-RUNNING"

    assert log =~ "Usage limit headroom hold provider=anthropic utilization=0.93 threshold=0.9"
    assert length(String.split(log, "Usage limit headroom hold")) == 3

    state = :sys.get_state(pid)
    assert %{phase: :headroom, reason: "claude_usage_headroom", resume_at: ^resume_at, utilization: 0.93} = state.usage_limits[@anthropic]
    assert is_reference(state.usage_limit_timers[@anthropic])
    assert %{@anthropic => %{phase: :headroom}} = RunStore.get_usage_limits()
    assert Map.has_key?(state.running, running.id)

    refute Orchestrator.should_dispatch_issue_for_test(issue("issue-headroom-new", "MT-NEW"), state)
    assert Orchestrator.should_dispatch_issue_for_test(issue("issue-headroom-land", "MT-LAND", %{state: "Merging"}), state)

    assert_receive {:notification_event, %Notifications.Event{event: "usage_limit_headroom"} = event}, 1_000
    assert event.issue_identifier == "MT-RUNNING"
    assert event.reason == "Claude 5-hour limit at 92%; holding new runs until #{DateTime.to_iso8601(resume_at)}"
    refute_receive {:notification_event, %Notifications.Event{event: "usage_limit_" <> _}}, 100

    # Landing runs still go out, so dispatch stays active with the hold listed.
    snapshot = GenServer.call(pid, :snapshot)
    assert [%{phase: :headroom, utilization: 0.93}] = snapshot.usage_limits
    assert %{active?: true, blockers: [blocker]} = snapshot.dispatch_state
    assert %{kind: :usage_limit, phase: :headroom, resume_at: ^resume_at} = blocker
    assert UsageLimit.banner(hd(snapshot.usage_limits), ctx.now) =~ ~r/^Holding new runs: Claude at 93%, resets ~\d{2}:\d{2}$/
  end

  test "below the threshold, a plain allowed window or headroom_utilization null holds nothing", ctx do
    resets_at = DateTime.add(ctx.now, 3600)
    running = issue("issue-headroom-off", "MT-OFF")

    for {name, overrides, update} <- [
          {:BelowOrchestrator, [], warning_update(0.89, resets_at)},
          {:AllowedOrchestrator, [], warning_update(0.95, resets_at, "allowed")},
          {:NullOrchestrator, [agent_usage_limit: %{}], warning_update(0.99, resets_at)}
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
    assert error == "usage limit headroom hold (provider=anthropic scope=all); resuming at #{DateTime.to_iso8601(DateTime.add(ctx.now, 3720))}"
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
    warned_once = Path.join(ctx.test_root, "warned-once")
    fake_claude = Path.join(ctx.test_root, "fake-claude-warning")

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-headroom","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    if [ ! -f #{warned_once} ]; then
      touch #{warned_once}
      resets_at=$(( $(date +%s) + 6 ))
      printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":%s,"rateLimitType":"five_hour","utilization":0.92},"session_id":"sess-headroom"}\\n' "$resets_at"
    fi
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-headroom","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    write_headroom_workflow!(%{ctx | fake_claude: fake_claude},
      agent_usage_limit: %{headroom_utilization: 0.9, resume_margin_seconds: 0},
      tracker_active_states: ["Todo"],
      poll_interval_ms: 250
    )

    first = issue("issue-headroom-walk", "MT-WALK", %{state: "Todo"})
    queued = issue("issue-headroom-queued", "MT-QUEUED", %{state: "Todo"})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [first])
    name = Module.concat(__MODULE__, :WalkthroughOrchestrator)
    runs_for = fn issue_id -> Enum.filter(RunStore.list_runs(:all), &(&1.issue_id == issue_id)) end

    capture_log(fn ->
      {:ok, pid} = Orchestrator.start_link(name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # 1. The warning puts the hold in place and the running issue finishes normally.
      wait_until(fn -> SymphonyElixirWeb.Presenter.state_payload(name, 1_000).usage_limits != [] end)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [first, queued])

      # 2. The state API carries the banner; the issue's continuation runs while new work waits.
      payload = SymphonyElixirWeb.Presenter.state_payload(name, 1_000)
      assert [%{phase: "headroom", reason: "claude_usage_headroom", utilization: 0.92} = hold] = payload.usage_limits
      assert UsageLimit.banner(hold, DateTime.utc_now()) =~ ~r/^Holding new runs: Claude at 92%, resets ~\d{2}:\d{2}$/
      assert payload.dispatch_state.active? == true

      wait_until(fn -> length(runs_for.(first.id)) >= 2 end)
      assert Enum.all?(runs_for.(first.id), &(&1.status != "usage_limited"))
      assert :sys.get_state(pid).usage_limits != %{}
      assert runs_for.(queued.id) == []

      # 3. Past the reset the hold clears and the queued issue dispatches.
      wait_until(fn -> SymphonyElixirWeb.Presenter.state_payload(name, 1_000).usage_limits == [] end)
      wait_until(fn -> runs_for.(queued.id) != [] end)
    end)
  end
end
