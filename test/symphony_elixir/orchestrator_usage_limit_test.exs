defmodule SymphonyElixir.OrchestratorUsageLimitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Notifications, UsageLimit}

  @anthropic {"anthropic", :all}

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

    # Let the boot tick finish so later state changes are not raced by it.
    :sys.get_state(pid)
    pid
  end

  defp set_clock(ctx, %DateTime{} = now), do: Agent.update(ctx.clock, fn _ -> now end)

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

  test "the resume timer clears the hold and dispatches the held issue with the same attempt", ctx do
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
      end)

    assert log =~ "Usage limit resumed provider=anthropic scope=all paused_for_s=3720"
    assert %{attempt: 3} = Enum.find(RunStore.list_runs(:all), &(&1.issue_id == issue.id and &1.status != "usage_limited"))
    assert RunStore.get_usage_limits() == %{}
    refute Map.has_key?(:sys.get_state(pid).usage_limits, @anthropic)

    # A resume for a hold that is already gone is ignored.
    send(pid, {:usage_limit_resume, @anthropic})
    assert :sys.get_state(pid).usage_limits == %{}
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
    send(pid, {:usage_limit_resume, @anthropic})
    state = :sys.get_state(pid)

    assert state.usage_limits == %{}
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
    send(restarted, {:usage_limit_resume, @anthropic})
    assert %{attempt: 3} = :sys.get_state(restarted).slot_waiting[issue.id]
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

  test "UsageLimit.remaining_ms never goes negative", ctx do
    assert UsageLimit.remaining_ms(hold(ctx), DateTime.add(ctx.now, 4000)) == 0
  end
end
