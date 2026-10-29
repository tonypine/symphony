defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentProcesses,
    AgentRunner,
    AgentTelemetry,
    Artifacts,
    AuditLog,
    BlockedHold,
    BreakdownReview,
    BuildInfo,
    CiPoller,
    CiWait,
    Config,
    Connected,
    Decisions,
    DispatchLoop,
    EpicLanes,
    ForcedQueue,
    ForcedStatus,
    Handoff,
    Hold,
    Initiatives,
    Notifications,
    OperatorStop,
    PlanComments,
    PlanReview,
    PrReviewPoller,
    PrRun,
    PrWatch,
    Quality,
    QualityGate,
    RetiredStates,
    RunKind,
    RunStore,
    Secret,
    SelfHeal,
    SetupBlock,
    ShippedToday,
    StateMachine,
    StateProvisioning,
    StatusDashboard,
    SubIssueWait,
    TicketEvents,
    TicketObservation,
    TicketPullRequest,
    TicketSignals,
    TicketState,
    TicketStateReconciler,
    Tracker,
    TransitionGuard,
    UpdateHold,
    URLUtils,
    UsageLimit,
    Verification,
    Workspace,
    WorkspaceCleanup,
    WorkspaceHead
  }

  alias SymphonyElixir.Artifacts.Transcript
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Dispatch.{Candidates, Shadow}
  alias SymphonyElixir.Linear.{Client, Issue, RateLimit, TransientRetry, Usage}
  alias SymphonyElixir.QaDriver.DevServerLease
  alias SymphonyElixir.Routing.PollLog
  alias SymphonyElixirWeb.ObservabilityPubSub

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Quiet runs a ticket gets on one head before it is held with `handoff_missing`.
  @max_quiet_handoff_runs 2
  # A transient Linear error (timeout, refused connection, 5xx) is not the issue's
  # fault: retry soon, without failure backoff. A rate limit waits for its pause.
  @linear_wait_retry_delay_ms 5_000
  # An epic review waiting for CI on the commit it reviews: not the issue's fault either, and CI takes
  # minutes, so the review is started again after a fixed wait, without failure backoff.
  @ci_wait_retry_delay_ms 60_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  # A repo Symphony's own moves force due is polled for them at most once per window: moves made
  # before that poll starts share it, and a move made after it started, inside the window, gets one
  # more poll at the window's end.
  @forced_poll_window_ms 2_000
  @default_transcript_buffer_size 200
  @default_snapshot_publish_ms 500
  @slow_callback_ms 1_000
  @running_metadata_persist_ms 5_000
  @stop_session_cleanup_timeout_ms 5_000
  @fresh_dispatch_state_grace_ms 120_000
  # A landing session can see its issue turn terminal (for example Linear's
  # "PR merged -> Done" automation) before it posts its final workpad update.
  @merging_state "merging"
  # The reviewer state, as the fallback when a repo's settings are unavailable.
  @code_review_state "Code Review"
  # The QA state, the fallback when a repo's settings are unavailable.
  @qa_state "QA"
  # The ledger signal recorded when a QA ticket's head is not green.
  @qa_head_not_green_signal "qa_head_not_green"
  # The ledger signal recorded when a Code Review ticket has no reviewer to run;
  # `SymphonyElixir.CodeReview` records the same name when it refuses to review.
  @code_review_reviewer_disabled_signal "code_review_reviewer_disabled"
  @merging_terminal_grace_ms 300_000
  @snapshot_table :symphony_orchestrator_snapshot
  @snapshot_key :current
  @snapshot_timing_key :timing
  @repo_poll_cold_failure_warm_after 3
  @empty_codex_totals %{
    input_tokens: 0,
    uncached_input_tokens: 0,
    cached_input_tokens: 0,
    cache_creation_input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
    defstruct [
      :repo_key,
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :watchdog_timer_ref,
      :watchdog_token,
      :startup_workspace_lifecycle_task_ref,
      :repo_poll_task_ref,
      :linear_requests_last_poll,
      linear_requests_mark: 0,
      running: %{},
      completed: MapSet.new(),
      completed_run_metadata: %{},
      quiet_handoff_runs: %{},
      shipped: %{},
      watching: %{},
      conflicts: %{},
      repo_poll_cache: %{},
      repo_poll_due_at_ms: %{},
      repo_poll_forced: MapSet.new(),
      repo_poll_forced_at_ms: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      rate_limits: nil,
      tracker_health: %{tracker: :unknown, reason: nil, since: nil, consecutive_failures: 0},
      budget_day_started_on: nil,
      budget_daily_used: 0,
      budget_daily_paused_logged: false,
      budget_exhausted: MapSet.new(),
      parked_parents: MapSet.new(),
      breakdown_reviews: %{},
      plan_comment_checks: %{},
      plan_comments_since: nil,
      merging_ci_waits: %{},
      epic_lanes: nil,
      blocked: [],
      update_hold_cache: %{blockers: %{}, included: %{}},
      update_holds: %{},
      forced: %{},
      forced_waiting_noted: MapSet.new(),
      forced_parts: %{},
      forced_touched: %{},
      forced_issues: %{},
      slot_waiting: %{},
      dispatch_skipped: %{},
      operator_stops: %{},
      pause: %{paused: false, reason: nil, paused_at: nil},
      operator_pause_logged: false,
      workspace_lifecycle_last_check_at_ms: nil,
      workspace_lifecycle_quota: %{configured?: false, paused: false, reason: nil},
      workspace_quota_logged: false,
      quality_gate_cache: %{},
      quality_gate_comment_keys: MapSet.new(),
      quality_gate_skipped_errors: %{},
      quality_gate_tasks: %{},
      dispatch_readiness_tasks: %{},
      tracker_tasks: %{},
      dispatch_refresh: nil,
      usage_limits: %{},
      usage_limit_timers: %{},
      usage_windows: %{},
      api_outages: %{},
      self_heal_opts: [],
      clock: &DateTime.utc_now/0
    ]

    @type t :: %__MODULE__{}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Usage.put_caller(:orchestrator)
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()
    repo_key = Config.repo_key!()
    log_quality_gate_config(config.quality_gate)
    :ok = ensure_run_store_started()
    {retry_attempts, claimed} = hydrate_retry_attempts()
    codex_totals = persisted_codex_totals()
    pause = persisted_pause_state()
    usage_limits = persisted_usage_limits() |> Map.new(fn {key, entry} -> {key, UsageLimit.paused(entry)} end)
    forced = persisted_forced(repo_key)
    quality_gate_cache = hydrate_quality_gate_cache()
    quality_gate_comment_keys = hydrate_quality_gate_comment_keys()
    budget_day_started_on = Date.utc_today()
    budget_daily_used = hydrate_budget_daily_used(budget_day_started_on)
    budget_exhausted = hydrate_budget_exhausted()
    :ok = ensure_snapshot_table()
    _ = ObservabilityPubSub.subscribe_ticket_records()

    recent_runs = hydrate_recent_runs()
    completed_run_metadata = hydrate_completed_run_metadata(recent_runs, retry_attempts)

    state = %State{
      repo_key: repo_key,
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      watchdog_timer_ref: nil,
      watchdog_token: nil,
      claimed: claimed,
      retry_attempts: retry_attempts,
      completed_run_metadata: completed_run_metadata,
      shipped: ShippedToday.hydrate(recent_runs, DateTime.utc_now()),
      plan_comments_since: DateTime.utc_now(),
      codex_totals: codex_totals,
      rate_limits: nil,
      tracker_health: empty_tracker_health(config.tracker.kind),
      pause: pause,
      budget_day_started_on: budget_day_started_on,
      budget_daily_used: budget_daily_used,
      budget_daily_paused_logged: false,
      budget_exhausted: budget_exhausted,
      quality_gate_cache: quality_gate_cache,
      quality_gate_comment_keys: quality_gate_comment_keys,
      usage_limits: usage_limits,
      forced: forced,
      operator_stops: OperatorStop.hydrate(configured_repo_keys(repo_key)),
      self_heal_opts: Keyword.get(opts, :self_heal_opts, []),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
    }

    state = state |> seed_watching_from_completed_run_metadata() |> arm_usage_limit_timers()

    mark_interrupted_runs_for_configured_repos(repo_key)
    TicketStateReconciler.reconcile_all()
    TicketPullRequest.Backfill.run(configured_repo_keys(repo_key))
    # The ledger's one-time history backfill runs in a task: startup never waits for it.
    TicketEvents.Backfill.start()
    tick_token = make_ref()
    send(self(), {:tick, tick_token})
    schedule_snapshot_publish(config.observability.snapshot_publish_ms)
    state = %{state | tick_token: tick_token, next_poll_due_at_ms: now_ms}
    state = schedule_watchdog_tick(state, config.watchdog.tick_interval_ms)

    {:ok, state, {:continue, {:startup_workspace_lifecycle, now_ms}}}
  end

  @impl true
  def handle_continue({:startup_workspace_lifecycle, now_ms}, state) do
    case start_startup_workspace_lifecycle_task(configured_repo_keys(state.repo_key), now_ms) do
      {:ok, task} ->
        {:noreply, %{state | startup_workspace_lifecycle_task_ref: task.ref}}

      {:error, reason} ->
        Logger.warning("Skipping async startup workspace lifecycle; failed to start task: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp log_quality_gate_config(%SymphonyElixir.Config.Schema.QualityGate{} = config) do
    threshold = config.pass_threshold || config.min_score

    Logger.info(
      "QualityGate config enabled=#{config.enabled} provider=#{config.provider} model=#{config.model} threshold=#{threshold} " <>
        "clarification_floor=#{inspect(config.clarification_floor)} max_clarification_rounds=#{config.max_clarification_rounds} on_error=#{config.on_error}"
    )
  end

  @impl true
  def handle_info(message, state), do: timed_callback(:handle_info, message, fn -> handle_info_message(message, state) end)

  @impl true
  def handle_call(message, from, state), do: timed_callback(:handle_call, message, fn -> handle_call_message(message, from, state) end)

  @impl true
  def handle_cast(message, state), do: timed_callback(:handle_cast, message, fn -> handle_cast_message(message, state) end)

  # Every caller waits behind a slow callback, and the snapshot isn't published meanwhile, so the
  # dashboards go stale: name the message that took the time.
  defp timed_callback(callback, message, fun) do
    started_ms = System.monotonic_time(:millisecond)
    result = fun.()
    duration_ms = System.monotonic_time(:millisecond) - started_ms

    if duration_ms >= slow_callback_ms() do
      Logger.warning("Orchestrator slow #{callback} duration_ms=#{duration_ms} message=#{inspect(message, limit: 3, printable_limit: 80)}")
    end

    result
  end

  defp slow_callback_ms, do: Application.get_env(:symphony_elixir, :orchestrator_slow_callback_ms, @slow_callback_ms)

  defp handle_cast_message({:request_refresh, repo_key, :now}, state) do
    now_ms = System.monotonic_time(:millisecond)

    case force_repo_due(state, repo_key, now_ms) do
      {:coalesced, state} -> {:noreply, state}
      {{:poll_at, due_at_ms}, state} -> {:noreply, request_poll_by(state, due_at_ms, now_ms)}
    end
  end

  # A ticket's record changed outside the poll cycle (`TicketObservation`, a move, a hold): with
  # dispatch from the record, its repo gets a cycle at once, as a move made there does, so a ticket
  # the change frees is considered within seconds. With dispatch from the poll cache the change waits
  # for the repo's poll.
  defp handle_info_message({:ticket_record, repo_key, _issue_id, :changed, _fields}, state) do
    case dispatch_source_in_use() do
      :record -> handle_cast_message({:request_refresh, repo_key, :now}, state)
      :poll -> {:noreply, state}
    end
  end

  defp handle_info_message(:publish_snapshot, state) do
    publish_snapshot(state)
    schedule_snapshot_publish(snapshot_publish_interval_ms())
    {:noreply, state}
  end

  defp handle_info_message({:tick, tick_token}, %{tick_token: tick_token} = state)
       when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  defp handle_info_message({:tick, _tick_token}, state), do: {:noreply, state}

  defp handle_info_message(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  defp handle_info_message(:run_poll_cycle, state) do
    now_ms = System.monotonic_time(:millisecond)
    state = refresh_runtime_config(state)

    case start_repo_poll_task(state, now_ms) do
      {:ok, task, state} ->
        {:noreply, %{state | repo_poll_task_ref: task.ref}}

      {:skip, state} ->
        state = finish_poll_cycle(state, now_ms)
        notify_dashboard()
        {:noreply, state}
    end
  end

  defp handle_info_message({:watchdog_tick, watchdog_token}, %{watchdog_token: watchdog_token} = state)
       when is_reference(watchdog_token) do
    state =
      state
      |> refresh_runtime_config()
      |> maybe_run_watchdog()
      |> schedule_watchdog_tick(watchdog_tick_interval_ms())

    {:noreply, state}
  end

  defp handle_info_message({:watchdog_tick, _watchdog_token}, state), do: {:noreply, state}

  defp handle_info_message(:watchdog_tick, state) do
    state =
      state
      |> refresh_runtime_config()
      |> maybe_run_watchdog()
      |> schedule_watchdog_tick(watchdog_tick_interval_ms())

    {:noreply, state}
  end

  defp handle_info_message({ref, {:startup_workspace_lifecycle_result, result}}, %{startup_workspace_lifecycle_task_ref: ref} = state)
       when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state =
      state
      |> Map.put(:startup_workspace_lifecycle_task_ref, nil)
      |> apply_startup_workspace_lifecycle_result(result)

    notify_dashboard()
    {:noreply, state}
  end

  defp handle_info_message({ref, {:repo_poll_result, result}}, %{repo_poll_task_ref: ref} = state)
       when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state =
      state
      |> Map.put(:repo_poll_task_ref, nil)
      |> apply_repo_poll_task_result(result)

    notify_dashboard()
    {:noreply, state}
  end

  defp handle_info_message({ref, {:quality_gate_result, result}}, %State{quality_gate_tasks: tasks} = state)
       when is_reference(ref) and is_map(tasks) do
    case Map.pop(tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {context, tasks} ->
        Process.demonitor(ref, [:flush])

        state =
          state
          |> Map.put(:quality_gate_tasks, tasks)
          |> handle_quality_gate_result(context, result)

        {:noreply, state}
    end
  end

  defp handle_info_message({ref, {:dispatch_readiness_result, result}}, %State{dispatch_readiness_tasks: tasks} = state)
       when is_reference(ref) and is_map(tasks) do
    case Map.pop(tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {context, tasks} ->
        Process.demonitor(ref, [:flush])

        state =
          state
          |> Map.put(:dispatch_readiness_tasks, tasks)
          |> handle_dispatch_readiness_result(context, result)

        {:noreply, state}
    end
  end

  defp handle_info_message({ref, {:tracker_task_result, result}}, %State{tracker_tasks: tasks} = state) when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {context, tasks} ->
        Process.demonitor(ref, [:flush])
        state = handle_tracker_task_result(%{state | tracker_tasks: tasks}, context, result)
        notify_dashboard()
        {:noreply, state}
    end
  end

  defp handle_info_message(
         {:DOWN, ref, :process, _pid, reason},
         %{running: running} = state
       ) do
    cond do
      state.startup_workspace_lifecycle_task_ref == ref ->
        Logger.warning("Async startup workspace lifecycle task exited before replying: #{inspect(reason)}")
        {:noreply, %{state | startup_workspace_lifecycle_task_ref: nil}}

      state.repo_poll_task_ref == ref ->
        Logger.warning("Async repo poll task exited before replying: #{inspect(reason)}")
        now_ms = System.monotonic_time(:millisecond)

        state =
          state
          |> Map.put(:repo_poll_task_ref, nil)
          |> finish_poll_cycle(now_ms)

        notify_dashboard()
        {:noreply, state}

      is_map(state.quality_gate_tasks) and Map.has_key?(state.quality_gate_tasks, ref) ->
        {context, tasks} = Map.pop(state.quality_gate_tasks, ref)
        Logger.warning("Async quality gate task exited before replying: #{inspect(reason)}")

        state =
          state
          |> Map.put(:quality_gate_tasks, tasks)
          |> handle_quality_gate_exit(context, reason)

        {:noreply, state}

      Map.has_key?(state.tracker_tasks, ref) ->
        {context, tasks} = Map.pop(state.tracker_tasks, ref)
        Logger.warning("Async Linear task #{context.kind} exited before replying: #{inspect(reason)}")
        state = handle_tracker_task_result(%{state | tracker_tasks: tasks}, context, {:error, {:task_exit, reason}})
        notify_dashboard()
        {:noreply, state}

      is_map(state.dispatch_readiness_tasks) and Map.has_key?(state.dispatch_readiness_tasks, ref) ->
        {context, tasks} = Map.pop(state.dispatch_readiness_tasks, ref)
        Logger.warning("Async dispatch readiness task exited before replying: #{inspect(reason)}")

        state =
          state
          |> Map.put(:dispatch_readiness_tasks, tasks)
          |> handle_dispatch_readiness_exit(context, reason)

        {:noreply, state}

      true ->
        handle_agent_down(ref, reason, running, state)
    end
  end

  defp handle_info_message({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
       when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        last_event_at = Map.get(running_entry, :last_event_at) || Map.get(running_entry, :started_at) || DateTime.utc_now()

        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> maybe_put_runtime_value(:agent_module, runtime_info[:agent_module])
          |> maybe_put_runtime_value(:agent_session, runtime_info[:agent_session])
          |> maybe_put_runtime_value(:comment_ids, runtime_info[:comment_ids])
          |> maybe_put_runtime_value(:linked, runtime_info[:linked])
          |> Map.put(:last_event_at, last_event_at)
          |> maybe_put_workspace_hook(runtime_info)

        persist_running_entry(updated_running_entry)
        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  defp handle_info_message({:merging_ci_wait, issue_id, wait}, %{running: running} = state)
       when is_binary(issue_id) and is_map(wait) do
    case Map.get(running, issue_id) do
      nil -> {:noreply, state}
      running_entry -> {:noreply, %{state | running: Map.put(running, issue_id, Map.put(running_entry, :merging_ci_wait, wait))}}
    end
  end

  # A run is waiting `delay_ms` on a Linear rate limit or outage; see after_linear_wait/2.
  defp handle_info_message({:linear_wait, issue_id, delay_ms}, %{running: running} = state)
       when is_binary(issue_id) and is_integer(delay_ms) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        wait_until = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
        {:noreply, %{state | running: Map.put(running, issue_id, Map.put(running_entry, :linear_wait_until, wait_until))}}
    end
  end

  # One of Symphony's own MCP tool calls in the run started or ended; see pending_tool/2 and
  # watchdog_clock_started_at/1.
  defp handle_info_message({:mcp_tool_call, issue_id, event}, %{running: running} = state) when is_binary(issue_id) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, put_pending_tool_call(running_entry, event))}}
    end
  end

  # Claude Code's heartbeat while a tool runs, every few seconds: it only counts as activity for
  # the first-turn stall check and the no-progress watchdog, so it skips the transcript, the run
  # store and the dashboard.
  defp handle_info_message(
         {:codex_worker_update, issue_id, %{event: :tool_progress, timestamp: %DateTime{} = timestamp}},
         %{running: running} = state
       ) do
    case Map.get(running, issue_id) do
      nil -> {:noreply, state}
      running_entry -> {:noreply, put_running_entry(state, issue_id, Map.merge(running_entry, %{last_event_at: timestamp, agent_observed: true}))}
    end
  end

  defp handle_info_message(
         {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
         %{running: running} = state
       ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
        audit_agent_update(updated_running_entry, update, token_delta)
        maybe_emit_pr_opened(running_entry, updated_running_entry)

        state_after_tokens =
          state
          |> apply_codex_token_delta(token_delta)

        state =
          state_after_tokens
          |> maybe_emit_daily_budget_exceeded(state, issue_id, updated_running_entry)
          |> apply_rate_limits(update)
          |> remember_usage_windows(update)
          |> put_running_entry(issue_id, updated_running_entry)
          |> enforce_issue_budget(issue_id)
          |> clear_usage_limit_on_allowed_canary(issue_id, update)
          |> hold_for_usage_headroom(updated_running_entry, update)
          |> persist_running_metadata(issue_id)

        notify_transcript(running_repo_key(state, updated_running_entry), issue_id, update)
        notify_dashboard()
        {:noreply, state}
    end
  end

  defp handle_info_message({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  defp handle_info_message({:retry_issue, issue_id, retry_token}, state) do
    result =
      if held_for_canary_read?(state, issue_id, retry_token) do
        {:noreply, keep_held_for_canary_read(state, issue_id)}
      else
        case pop_retry_attempt_state(state, issue_id, retry_token) do
          {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
          :missing -> {:noreply, state}
        end
      end

    notify_dashboard()
    result
  end

  defp handle_info_message({:retry_issue, _issue_id}, state), do: {:noreply, state}

  defp handle_info_message({:api_outage_over, key, since}, %State{} = state) do
    state =
      case Map.fetch(state.api_outages, key) do
        {:ok, %{since: ^since} = outage} -> finish_api_outage(state, key, outage)
        _continued_or_gone -> state
      end

    {:noreply, state}
  end

  defp handle_info_message({:usage_limit_resume, key}, %State{} = state) do
    state =
      case Map.fetch(state.usage_limits, key) do
        {:ok, %{phase: :paused} = entry} -> maybe_resume_usage_limit(state, key, entry)
        {:ok, %{phase: :headroom} = entry} -> maybe_clear_usage_headroom(state, key, entry)
        _canary_or_gone -> state
      end

    notify_dashboard()
    {:noreply, state}
  end

  defp handle_info_message(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(ref, reason, running, state) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        Verification.release(Map.get(running_entry, :verification), "agent process exit")
        record_dispatch_outcome(running_entry, reason)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        state =
          case reason do
            :normal ->
              handle_normal_agent_exit(state, issue_id, running_entry, session_id)

            _ ->
              handle_abnormal_agent_exit(state, issue_id, running_entry, session_id, reason)
          end

        state = finish_usage_limit_canary(state, issue_id)
        # The run's end is recorded: the PR watcher reads the ticket now, so the branch upkeep
        # deferred while the run worked fires at once.
        PrWatch.poll_now()
        notify_dashboard()
        {:noreply, redispatch_slot_waiting(state)}
    end
  end

  # A slot just freed: run dispatch now rather than at the next poll when an issue is waiting for one.
  defp redispatch_slot_waiting(%State{slot_waiting: waiting} = state) when map_size(waiting) > 0 do
    if poll_tick_coalesced?(state, System.monotonic_time(:millisecond)), do: state, else: schedule_tick(state, 0)
  end

  defp redispatch_slot_waiting(%State{} = state), do: state

  # Polls now unless a poll is already running or due; true when it was.
  defp request_poll(%State{} = state) do
    if poll_tick_coalesced?(state, System.monotonic_time(:millisecond)) do
      {true, state}
    else
      {false, schedule_tick(state, 0)}
    end
  end

  # Ticks by `due_at_ms` unless a poll is running (it ends by scheduling the earliest due repo) or a
  # tick comes sooner.
  defp request_poll_by(%State{} = state, due_at_ms, now_ms) do
    if poll_tick_coalesced?(state, due_at_ms), do: state, else: schedule_tick(state, due_at_ms - now_ms)
  end

  defp poll_tick_coalesced?(%State{} = state, now_ms) do
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    state.poll_check_in_progress == true or already_due?
  end

  # Symphony's copy of a stopped ticket still reads the state it had until a poll reads Linear
  # again, so the stop marks it (`SymphonyElixir.OperatorStop`): the dispatcher skips it, and a
  # poll is asked for at once to confirm where it is. The mark's Blocked hold is written in a task,
  # so Linear never holds up the stop. A PR run has no ticket to mark.
  defp mark_operator_stop(%State{} = state, issue_id, running_entry, repo_key) do
    if pr_run_entry?(running_entry) do
      state
    else
      mark = OperatorStop.mark(running_entry.identifier, repo_key, state.clock.())
      state = %{state | operator_stops: Map.put(state.operator_stops, issue_id, mark)}
      context = %{kind: :operator_stop_hold, issue_ids: [issue_id], repo_key: repo_key}
      state = start_tracker_task(state, context, fn -> OperatorStop.set_hold(repo_key, issue_id, mark) end)
      {_coalesced, state} = request_poll(state)
      state
    end
  end

  # A hold that landed after the mark was cleared (the poll found the ticket gone or moved first)
  # is cleared again, so it doesn't outlive its mark.
  defp finish_operator_stop_hold(%State{} = state, %{issue_ids: [issue_id], repo_key: repo_key}, :ok) do
    case Map.fetch(state.operator_stops, issue_id) do
      {:ok, mark} ->
        %{state | operator_stops: Map.put(state.operator_stops, issue_id, %{mark | held: true})}

      :error ->
        clear_operator_stop_hold(state, issue_id, repo_key)
    end
  end

  # The mark still keeps the ticket from running while this Symphony runs; only its persistence and
  # its Inbox entry are missing.
  defp finish_operator_stop_hold(%State{} = state, %{issue_ids: [issue_id]}, {:error, reason}) do
    Logger.warning("Failed to hold a ticket the operator stopped: issue_id=#{issue_id} reason=#{inspect(reason)}")
    state
  end

  defp operator_stop_reason(%Issue{id: issue_id}, %State{operator_stops: stops}) do
    case Map.get(stops, issue_id) do
      nil -> nil
      %{held: true, repo_key: repo_key} = mark -> if OperatorStop.held?(repo_key, issue_id), do: OperatorStop.skip_reason(mark)
      mark -> OperatorStop.skip_reason(mark)
    end
  end

  # Each poll reads the marked tickets by id. The marks of tickets stopped after the poll started
  # are not in `stopped_ids`, so a read from before their stop never judges them.
  defp apply_operator_stops_result(%State{} = state, [], _result), do: state

  defp apply_operator_stops_result(%State{} = state, stopped_ids, {:ok, issues}) when is_list(issues) do
    by_id = for %Issue{id: issue_id} = issue <- issues, into: %{}, do: {issue_id, issue}
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    Enum.reduce(stopped_ids, state, fn issue_id, acc ->
      case Map.fetch(acc.operator_stops, issue_id) do
        {:ok, mark} -> confirm_operator_stop(acc, issue_id, mark, Map.get(by_id, issue_id), active_states, terminal_states)
        :error -> acc
      end
    end)
  end

  defp apply_operator_stops_result(%State{} = state, _stopped_ids, {:error, reason}) do
    Logger.warning("Failed to read the tickets the operator stopped; they stay skipped: #{inspect(reason)}")
    state
  end

  defp confirm_operator_stop(%State{} = state, issue_id, mark, issue, active_states, terminal_states) do
    candidate? = match?(%Issue{}, issue) and active_issue_state?(issue.state, active_states) and not terminal_issue_state?(issue.state, terminal_states)
    held? = mark.held and OperatorStop.held?(mark.repo_key, issue_id)

    case OperatorStop.confirm(mark, issue, candidate?, held?) do
      {:keep, ^mark} ->
        state

      {:keep, confirmed} ->
        Logger.info("Operator stop confirmed: issue_id=#{issue_id} issue_identifier=#{mark.identifier} state=#{inspect(confirmed.state)}; it stays skipped until a person acts")
        %{state | operator_stops: Map.put(state.operator_stops, issue_id, confirmed)}

      :lifted ->
        Logger.info("Operator stop lifted by a person: issue_id=#{issue_id} issue_identifier=#{mark.identifier}")
        %{state | operator_stops: Map.delete(state.operator_stops, issue_id)}

      :clear ->
        Logger.info("Clearing operator stop: issue_id=#{issue_id} issue_identifier=#{mark.identifier} state=#{inspect(issue && issue.state)}")
        clear_operator_stop(state, issue_id, mark)
    end
  end

  # A mark whose hold is still being written is cleared when that write finishes.
  defp clear_operator_stop(%State{} = state, issue_id, mark) do
    state = %{state | operator_stops: Map.delete(state.operator_stops, issue_id)}

    if tracker_task_in_flight?(state, :operator_stop_hold, issue_id),
      do: state,
      else: clear_operator_stop_hold(state, issue_id, mark.repo_key)
  end

  defp clear_operator_stop_hold(%State{} = state, issue_id, repo_key) do
    context = %{kind: :operator_stop_clear, issue_ids: [issue_id]}
    start_tracker_task(state, context, fn -> OperatorStop.clear_hold(repo_key, issue_id) end)
  end

  defp handle_normal_agent_exit(%State{} = state, issue_id, running_entry, session_id) do
    persist_run_completion(running_entry, "success", nil)

    case pr_run_entry?(running_entry) do
      true ->
        Logger.info("PR agent task completed for issue_id=#{issue_id} session_id=#{session_id}; no Linear continuation scheduled")
        remember_completed_run(state, issue_id, running_entry)

      false ->
        complete_pr_review_comment_cursor(issue_id, running_entry_repo_key(running_entry))
        complete_active_agent_run(state, issue_id, running_entry, session_id)
    end
  end

  # A landing run that ended on pending checks is held instead of continued (see
  # release_merging_ci_waits/2).
  defp complete_active_agent_run(%State{} = state, issue_id, %{merging_ci_wait: %{} = wait} = running_entry, session_id) do
    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; holding in Merging until CI settles on #{wait[:commit_sha]}")

    hold = %{
      identifier: running_entry.identifier,
      title: running_entry_title(running_entry),
      repo_key: running_entry_repo_key(running_entry),
      pull_request_url: wait[:pr_url],
      commit_sha: wait[:commit_sha],
      since: DateTime.utc_now()
    }

    state = state |> complete_issue(issue_id, running_entry) |> release_issue_claim(issue_id)
    %{state | merging_ci_waits: Map.put(state.merging_ci_waits, issue_id, hold)}
  end

  defp complete_active_agent_run(%State{} = state, issue_id, running_entry, session_id) do
    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

    state
    |> complete_issue(issue_id, running_entry)
    |> schedule_issue_retry(issue_id, 1, %{
      repo_key: running_entry_repo_key(running_entry),
      identifier: running_entry.identifier,
      title: running_entry_title(running_entry),
      delay_type: :continuation,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  # A model API the agent couldn't reach is held as a usage limit is, `auto_pause` or not: no
  # attempt is counted, and the canary is the probe that tells when the API is back.
  defp handle_abnormal_agent_exit(%State{} = state, issue_id, running_entry, session_id, {:model_api_unreachable, %{} = info} = reason) do
    persist_run_completion(running_entry, "model_api_unreachable", "agent exited: #{agent_exit_reason_summary(reason)}")
    pause_for_usage_limit(state, issue_id, running_entry, session_id, info)
  end

  defp handle_abnormal_agent_exit(%State{} = state, issue_id, running_entry, session_id, {:usage_limited, %{} = info} = reason) do
    cond do
      not Config.settings!().agent.usage_limit.auto_pause ->
        handle_failed_agent_exit(state, issue_id, running_entry, session_id, reason)

      usage_limit_holds_run?(state, running_entry, info) ->
        persist_run_completion(running_entry, "usage_limited", "agent exited: #{agent_exit_reason_summary(reason)}")
        pause_for_usage_limit(state, issue_id, running_entry, session_id, info)

      true ->
        hold_other_provider_and_retry(state, issue_id, running_entry, session_id, reason, info)
    end
  end

  # The epic review found CI still running on the commit it reviews (`SymphonyElixir.EpicReview`).
  # Nothing failed: the attempt stays, no `run_failed` goes out, the run counts towards no dispatch
  # loop, and the review starts again once CI had a minute more to finish. The wait is bounded per
  # commit (`SymphonyElixir.CiWait`): past the limit the ticket is held instead.
  defp handle_abnormal_agent_exit(%State{} = state, issue_id, running_entry, session_id, {:ci_pending, %{} = info} = reason) do
    error = agent_exit_reason_summary(reason)
    persist_run_completion(running_entry, "waiting_for_ci", error)
    repo_key = running_entry_repo_key(running_entry)

    case ci_wait(repo_key, issue_id, info) do
      :wait ->
        Logger.info("Agent task for issue_id=#{issue_id} session_id=#{session_id} is #{error}; retrying after CI")
        retry_after_ci(state, issue_id, running_entry, repo_key, error)

      {:over, since} ->
        hold_ci_wait(state, issue_id, running_entry, repo_key, info, since, error)
    end
  end

  defp handle_abnormal_agent_exit(%State{} = state, issue_id, running_entry, session_id, reason) do
    handle_failed_agent_exit(state, issue_id, running_entry, session_id, reason)
  end

  # When the wait for CI on the commit started, from the ticket's store record; the first wait on a
  # commit records its start. A record the store can't read starts no clock, so the review keeps
  # waiting, bounded by the epic review's own limit on a stuck workflow run.
  defp ci_wait(repo_key, issue_id, %{sha: sha}) do
    record = TicketState.normalize(RunStore.get_ticket_state(repo_key, issue_id))
    now = DateTime.utc_now()

    case CiWait.since(record.signals, sha) do
      nil ->
        record_ticket_signal(repo_key, issue_id, CiWait.start_signal(), %{sha: sha})
        :wait

      since ->
        if CiWait.over?(since, now), do: {:over, since}, else: :wait
    end
  end

  # Past the limit the review is not started again: a Blocked hold names the commit and the workflows
  # still running, which a person lifts with Unblock. A hold the store fails to write leaves the
  # ticket unheld and its wait unended, so the review starts again after CI and the next exit, still
  # over the limit, tries the hold again.
  defp hold_ci_wait(%State{} = state, issue_id, running_entry, repo_key, %{sha: sha} = info, since, error) do
    attrs = CiWait.hold_attrs(info, since, DateTime.utc_now())

    case Hold.set(repo_key, issue_id, :blocked, attrs) do
      :ok ->
        Logger.error("Holding #{running_entry.identifier} instead of waiting longer for CI: #{attrs.reason}")
        record_ticket_signal(repo_key, issue_id, CiWait.hold_type(), %{sha: sha})
        release_issue_claim(state, issue_id)

      {:error, reason} ->
        Logger.error("Failed to hold #{running_entry.identifier} after waiting for CI too long; retrying after CI: #{inspect(reason)}")
        retry_after_ci(state, issue_id, running_entry, repo_key, error)
    end
  end

  defp retry_after_ci(%State{} = state, issue_id, running_entry, repo_key, error) do
    schedule_issue_retry(state, issue_id, retry_attempt(Map.get(running_entry, :retry_attempt)), %{
      repo_key: repo_key,
      identifier: running_entry.identifier,
      title: running_entry_title(running_entry),
      error: error,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      delay_type: :ci_wait
    })
  end

  defp handle_failed_agent_exit(%State{} = state, issue_id, running_entry, session_id, reason) do
    error = "agent exited: #{agent_exit_reason_summary(reason)}"
    persist_run_completion(running_entry, terminal_status_for_reason(reason), error)

    cond do
      pr_run_entry?(running_entry) ->
        # PR runs are explicit operator dispatches keyed by a synthetic
        # "pr:<repo>:<n>" id that has no Linear backing. Scheduling a retry or
        # tracking it for Linear watching would push the id through
        # Tracker.fetch_issue_states_by_ids and mis-tag the audit trail; let the
        # operator redispatch instead.
        Logger.warning("PR agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; PR runs are not retried")

        emit_run_failed(running_entry, error, nil)
        state

      terminal_tool_failure_circuit_breaker?(reason) ->
        Logger.error(
          "Agent task exited for issue_id=#{issue_id} session_id=#{session_id} " <>
            "reason=#{inspect(reason)}; repeated tool failure circuit breaker is not retried"
        )

        comment = fn -> maybe_comment_tool_failure_circuit_breaker(issue_id, running_entry, reason) end
        state = maybe_hold_blocked_issue(state, issue_id, running_entry, "the agent repeated a failing tool call until the circuit breaker tripped", comment)
        emit_run_failed(running_entry, error, nil)
        state

      setup_block?(reason) ->
        Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; setup block goes to self-heal, not retried")
        heal_setup_block(state, issue_id, running_entry, reason, error)

      true ->
        Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")
        retry_failed_run(state, issue_id, running_entry, reason, error)
    end
  end

  defp retry_failed_run(%State{} = state, issue_id, running_entry, reason, error) do
    {next_attempt, retry_metadata} = failed_run_retry(running_entry, reason)
    emit_run_failed(running_entry, error, next_attempt)

    schedule_issue_retry(
      state,
      issue_id,
      next_attempt,
      Map.merge(
        %{
          repo_key: running_entry_repo_key(running_entry),
          identifier: running_entry.identifier,
          title: running_entry_title(running_entry),
          error: error,
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        },
        retry_metadata
      )
    )
  end

  defp setup_block?({:setup_block, _cause}), do: true
  defp setup_block?(_reason), do: false

  # A run that failed in its own setup, before the agent's first turn (`SymphonyElixir.SetupBlock`),
  # would fail the same way again, so it is not retried: the self-heal lane names the broken
  # component, files or reuses its fix ticket and holds the ticket on it. It runs in a task so Linear
  # never holds up the orchestrator, and the claim stays held until it answers. A lane that asks for
  # another attempt, or could not record the block, falls back to the crash retry.
  defp heal_setup_block(%State{} = state, issue_id, running_entry, {:setup_block, cause} = reason, error) do
    repo_key = running_repo_key(state, running_entry)
    outcome = SetupBlock.outcome(cause)
    attempts = retry_attempt(Map.get(running_entry, :retry_attempt))
    heal_opts = [outcome: outcome, attempts: attempts, repo_key: repo_key] ++ state.self_heal_opts

    context = %{
      kind: :setup_block,
      issue_ids: [issue_id],
      repo_key: repo_key,
      running_entry: running_entry,
      reason: reason,
      error: error,
      outcome: outcome
    }

    start_tracker_task(state, context, fn -> run_setup_block_heal(Map.get(running_entry, :issue), repo_key, heal_opts) end)
  end

  defp run_setup_block_heal(issue, repo_key, heal_opts) do
    case SelfHeal.heal(issue, heal_opts) do
      :filed -> {:filed, fix_ticket_held_on(repo_key, issue.id, heal_opts)}
      other -> other
    end
  end

  # The fix ticket the hold self-heal just set waits on, as its log line names it.
  defp fix_ticket_held_on(repo_key, issue_id, opts) do
    hold = Hold.get(repo_key, issue_id, :blocked, Keyword.take(opts, [:store])) || %{}
    hold |> get_in([:waits_on, :keys]) |> List.wrap() |> List.first("its fix ticket")
  end

  defp finish_setup_block(%State{} = state, %{issue_ids: [issue_id]} = context, result) do
    %{running_entry: running_entry, outcome: outcome} = context
    component = SelfHeal.component(outcome)

    case setup_block_hold(result) do
      held when is_binary(held) ->
        Logger.warning("Setup block for #{running_entry.identifier}: #{component} — #{outcome.summary}; #{held} issue_id=#{issue_id}")
        emit_run_failed(running_entry, context.error, nil)
        record_ticket_signal(context.repo_key, issue_id, "blocked", %{reason: outcome.summary, held: true})
        release_issue_claim(state, issue_id)

      nil ->
        Logger.warning(
          "Setup block for #{running_entry.identifier}: #{component} — #{outcome.summary}; " <>
            "self-heal answered #{inspect(result)}, scheduling retry issue_id=#{issue_id}"
        )

        retry_failed_run(state, issue_id, running_entry, context.reason, context.error)
    end
  end

  defp setup_block_hold({:filed, fix_ticket}), do: "self-heal holds it on #{fix_ticket}"
  defp setup_block_hold(:escalated), do: "self-heal asks a person to decide"
  defp setup_block_hold(_result), do: nil

  # The run waited for Linear as long as it may and Linear was still rate-limited or
  # unreachable. That is not the issue's fault: keep its attempt and let
  # schedule_issue_retry/4 wait for Linear instead of backing off.
  defp failed_run_retry(running_entry, {:linear_unavailable, _reason}),
    do: {retry_attempt(Map.get(running_entry, :retry_attempt)), %{delay_type: :linear_wait}}

  defp failed_run_retry(running_entry, _reason), do: {next_retry_attempt_from_running(running_entry), %{}}

  # Not the issue's fault: the attempt stays, no backoff is added and no `run_failed` goes
  # out. The retry is held until the provider's limit resets, keeping the workspace.
  defp pause_for_usage_limit(%State{} = state, issue_id, running_entry, session_id, info) do
    {state, entry} = put_usage_limit(state, info, running_entry.identifier)

    cause = if UsageLimit.api_unreachable?(entry), do: "could not reach the model API", else: "hit the usage limit"

    if pr_run_entry?(running_entry) do
      Logger.warning("PR agent task #{cause} for issue_id=#{issue_id} session_id=#{session_id}; PR runs are not retried")
      state
    else
      Logger.info("Agent task #{cause} for issue_id=#{issue_id} session_id=#{session_id}; holding the retry until #{DateTime.to_iso8601(entry.resume_at)}")

      schedule_issue_retry(state, issue_id, retry_attempt(Map.get(running_entry, :retry_attempt)), %{
        repo_key: running_entry_repo_key(running_entry),
        identifier: running_entry.identifier,
        title: running_entry_title(running_entry),
        error: usage_limit_error(entry),
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        delay_type: :usage_limit,
        usage_limit_key: {entry.provider, entry.scope},
        usage_limit_delay_ms: UsageLimit.remaining_ms(entry, state.clock.())
      })
    end
  end

  # A usage limit for another provider seen by a run on this one: recording the hold still pauses
  # that provider's runs, but this run is not held until the other provider resets. It backs off and
  # retries like any other failure. This is the OpenRouter case: an OpenRouter run through the Claude
  # runtime can see the Claude subscription's limit, which must not stop OpenRouter work.
  defp hold_other_provider_and_retry(%State{} = state, issue_id, running_entry, session_id, reason, info) do
    {state, entry} = put_usage_limit(state, info, running_entry.identifier)

    Logger.info(
      "Usage limit provider=#{entry.provider} scope=#{UsageLimit.scope_label(entry.scope)} does not hold " <>
        "this run's provider=#{run_profile_for_issue(state, running_entry.issue).provider}; retrying with backoff " <>
        "issue_id=#{issue_id} session_id=#{session_id}"
    )

    handle_failed_agent_exit(state, issue_id, running_entry, session_id, reason)
  end

  # Whether a usage limit for `info`'s provider holds a run for `running_entry`: only when the run's
  # own provider matches. An OpenRouter run (Claude runtime) never matches a Claude subscription
  # limit. An entry without an issue follows the old behavior and is held.
  defp usage_limit_holds_run?(%State{} = state, %{issue: %Issue{} = issue}, info) do
    {provider, _scope} = UsageLimit.key(info)
    run_profile_for_issue(state, issue).provider == provider
  end

  defp usage_limit_holds_run?(_state, _running_entry, _info), do: true

  defp agent_exit_reason_summary({%RuntimeError{message: message}, _stacktrace}) when is_binary(message) do
    strip_ansi(message)
  end

  defp agent_exit_reason_summary({:model_api_unreachable, info}) do
    "model API unreachable (#{Map.get(info, :error)})"
  end

  defp agent_exit_reason_summary({:linear_unavailable, reason}) do
    "waiting for Linear: #{inspect(reason)}"
  end

  defp agent_exit_reason_summary({:ci_pending, %{sha: sha, runs: runs}}) do
    "waiting for CI on #{String.slice(sha, 0, 12)}: #{Enum.map_join(runs, ", ", &(&1.workflow_name || "a workflow"))} still running"
  end

  defp agent_exit_reason_summary({:setup_block, cause}) do
    "setup block: #{SetupBlock.describe(cause)}"
  end

  defp agent_exit_reason_summary({:tool_failure_circuit_breaker, payload}) do
    "tool failure circuit breaker tripped: #{tool_failure_circuit_breaker_summary(payload)}"
  end

  defp agent_exit_reason_summary({:port_exit, status, %{stderr: stderr}})
       when is_integer(status) and is_binary(stderr) do
    "port_exit #{status}; stderr: #{strip_ansi(stderr)}"
  end

  defp agent_exit_reason_summary({:exit_status, status, %{stderr: stderr}})
       when is_integer(status) and is_binary(stderr) do
    "exit_status #{status}; stderr: #{strip_ansi(stderr)}"
  end

  defp agent_exit_reason_summary({%{__exception__: true} = exception, _stacktrace}) do
    exception
    |> Exception.message()
    |> strip_ansi()
  end

  defp agent_exit_reason_summary(reason) do
    reason
    |> inspect()
    |> strip_ansi()
  end

  defp strip_ansi(text) when is_binary(text), do: String.replace(text, ~r/\x1b\[[0-9;]*m/, "")

  defp terminal_tool_failure_circuit_breaker?({:tool_failure_circuit_breaker, _payload}), do: true
  defp terminal_tool_failure_circuit_breaker?(_reason), do: false

  defp maybe_comment_tool_failure_circuit_breaker(issue_id, running_entry, reason)
       when is_binary(issue_id) and is_map(running_entry) do
    body = tool_failure_circuit_breaker_comment(reason)

    case Tracker.create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, comment_reason} ->
        Logger.warning(
          "Failed to post tool-failure circuit-breaker comment for issue_id=#{issue_id}: " <>
            "#{inspect(comment_reason)}"
        )
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to post tool-failure circuit-breaker comment for issue_id=#{issue_id}: " <>
          "#{Exception.message(exception)}"
      )
  end

  defp maybe_comment_tool_failure_circuit_breaker(_issue_id, _running_entry, _reason), do: :ok

  # The comment saying why and the Blocked hold run in one task, so they land in that order and
  # Linear never holds up the orchestrator; the claim stays held until the hold is set. The ticket
  # keeps its phase: the hold waits on a person's Unblock, as an agent's own block report does.
  defp maybe_hold_blocked_issue(%State{} = state, issue_id, running_entry, reason, comment)
       when is_binary(issue_id) and is_map(running_entry) do
    repo_key = running_repo_key(state, running_entry)
    context = %{kind: :blocked_hold, issue_ids: [issue_id], issue: Map.get(running_entry, :issue), reason: reason}

    start_tracker_task(state, context, fn ->
      comment.()

      Hold.set(repo_key, issue_id, :blocked, %{
        reason: reason,
        clearing_condition: "when a person unblocks it",
        waits_on: %{type: "access", keys: []}
      })
    end)
  end

  defp maybe_hold_blocked_issue(%State{} = state, _issue_id, _running_entry, _reason, _comment), do: state

  defp finish_blocked_hold(%State{} = state, %{issue_ids: [issue_id], issue: issue, reason: reason}, :ok) do
    record_ticket_signal(issue, "blocked", %{reason: reason, held: true})
    release_issue_claim(state, issue_id)
  end

  defp finish_blocked_hold(%State{} = state, %{issue_ids: [issue_id]}, {:error, reason}) do
    Logger.warning("Failed to hold a blocked issue: issue_id=#{issue_id} reason=#{inspect(reason)}")
    release_issue_claim(state, issue_id)
  end

  defp tool_failure_circuit_breaker_comment(reason) do
    """
    Symphony stopped this run without retrying because the agent repeated the same failing tool execution until the circuit breaker tripped.

    #{tool_failure_circuit_breaker_details(reason)}

    The ticket stays where it is on a Blocked hold until a person unblocks it.
    """
  end

  defp tool_failure_circuit_breaker_details({:tool_failure_circuit_breaker, payload}),
    do: tool_failure_circuit_breaker_details(payload)

  defp tool_failure_circuit_breaker_details(payload) when is_map(payload) do
    signature = Map.get(payload, :signature) || Map.get(payload, "signature") || %{}
    count = Map.get(payload, :count) || Map.get(payload, "count") || "unknown"
    threshold = Map.get(payload, :threshold) || Map.get(payload, "threshold") || "unknown"

    """
    Failing signature: #{tool_failure_signature_text(signature)}
    Consecutive failures: #{count}
    Configured threshold: #{threshold}
    """
  end

  defp tool_failure_circuit_breaker_details(_payload), do: "Failing signature: unknown"

  defp tool_failure_circuit_breaker_summary(payload) when is_map(payload) do
    signature = Map.get(payload, :signature) || Map.get(payload, "signature") || %{}
    count = Map.get(payload, :count) || Map.get(payload, "count") || "unknown"
    threshold = Map.get(payload, :threshold) || Map.get(payload, "threshold") || "unknown"

    "#{tool_failure_signature_text(signature)} count=#{count} threshold=#{threshold}"
  end

  defp tool_failure_circuit_breaker_summary(_payload), do: "signature=unknown"

  defp tool_failure_signature_text(signature) when is_map(signature) do
    kind = Map.get(signature, :kind) || Map.get(signature, "kind") || "unknown"
    name = Map.get(signature, :name) || Map.get(signature, "name") || "unknown"
    args_hash = Map.get(signature, :args_hash) || Map.get(signature, "args_hash") || "unknown"

    "kind=#{kind} name=#{inspect(name)} args_hash=#{args_hash}"
  end

  defp tool_failure_signature_text(_signature), do: "unknown"

  defp start_repo_poll_task(%State{repo_poll_task_ref: ref} = state, _now_ms) when is_reference(ref),
    do: {:skip, state}

  defp start_repo_poll_task(%State{} = state, now_ms) do
    state = reconcile_stalled_running_issues(state)

    # While Linear is rate-limiting us, skip the whole cycle so no Linear call
    # leaves this node; finish_poll_cycle/2 schedules the next tick for when the
    # pause ends, and that cycle's first Linear call is the probe.
    if RateLimit.paused_until() do
      {:skip, state}
    else
      start_unpaused_repo_poll_task(state, now_ms)
    end
  end

  defp start_unpaused_repo_poll_task(%State{} = state, now_ms) do
    with :ok <- Config.validate!(),
         {:ok, repos} <- Config.repos() do
      start_repo_poll_task_for_repos(state, repos, now_ms)
    else
      {:error, reason} ->
        log_poll_error(reason)
        {:skip, record_tracker_poll_failure(state, reason)}
    end
  end

  defp start_repo_poll_task_for_repos(%State{} = state, repos, now_ms) do
    {input, state} = repo_poll_task_input(state, repos, now_ms)

    case start_async_task(fn -> {:repo_poll_result, run_repo_poll_task(input)} end) do
      {:ok, task} ->
        {:ok, task, state}

      {:error, reason} ->
        Logger.warning("Failed to start async repo poll task: #{inspect(reason)}")
        {:skip, state}
    end
  end

  # `list_records` stands in for the store's read of every ticket record.
  @doc false
  @spec run_repo_poll_task_for_test(State.t(), [term()], integer(), (-> [map()] | {:error, term()})) ::
          {map(), State.t()}
  def run_repo_poll_task_for_test(%State{} = state, repos, now_ms, list_records \\ &RunStore.list_all_ticket_states/0)
      when is_list(repos) do
    {input, state} = repo_poll_task_input(state, repos, now_ms)
    {run_repo_poll_task(Map.put(input, :list_records, list_records)), state}
  end

  defp repo_poll_task_input(%State{} = state, repos, now_ms) do
    state = sync_repo_poll_state(state, repos, now_ms)
    {due_repo, state} = take_due_repo(state, repos, now_ms)
    ids = %{running: Map.keys(state.running), watching: watching_issue_ids(state), forced: Map.keys(state.forced), stopped: Map.keys(state.operator_stops)}

    input = %{
      repos: repos,
      now_ms: now_ms,
      due_repo: due_repo,
      ids: ids,
      by_id: tick_read_source(state, ids),
      update_hold_cache: state.update_hold_cache
    }

    {input, state}
  end

  defp run_repo_poll_task(%{ids: ids} = input) do
    RetiredStates.refresh_if_due()
    # When Linear was read: the by-id reads below may write newer facts into the records first.
    read_at = DateTime.utc_now()
    repo_result = fetch_due_repo_if_needed(input.due_repo)
    TicketPullRequest.Lookup.start(input.due_repo, repo_result)
    read = tick_reader(input.by_id, Map.get(input, :list_records, &RunStore.list_all_ticket_states/0))
    {running_ids, running_result} = read.(ids.running)
    {watching_ids, watching_result} = read.(ids.watching)
    {forced_ids, forced_result} = read.(ids.forced)
    {stopped_ids, stopped_result} = read.(ids.stopped)

    %{
      repos: input.repos,
      now_ms: input.now_ms,
      read_at: read_at,
      running_ids: running_ids,
      running_result: running_result,
      watching_ids: watching_ids,
      watching_result: watching_result,
      forced_ids: forced_ids,
      forced_result: forced_result,
      stopped_ids: stopped_ids,
      stopped_result: stopped_result,
      repo_result: repo_result,
      update_hold_cache: resolve_update_holds(repo_result, input.update_hold_cache)
    }
  end

  # Where the tick reads its running, watched, forced and operator-stopped tickets: from Linear by id
  # under `dispatch.source: poll`, from the ticket records under `record`. The record path takes the
  # text Symphony already holds for each ticket (`with_held_text/2`), read here in the orchestrator.
  defp tick_read_source(%State{} = state, ids) do
    case dispatch_source_in_use() do
      :poll ->
        :poll

      :record ->
        wanted = ids |> Map.values() |> List.flatten() |> MapSet.new()
        {:record, Map.filter(held_issues(state), fn {issue_id, _issue} -> MapSet.member?(wanted, issue_id) end)}
    end
  end

  # The issue Symphony already holds for each ticket, with the text only a Linear read gives: the
  # repo poll's, else the one a run or `symphony force` holds.
  defp held_issues(%State{} = state) do
    running = for {issue_id, %{issue: %Issue{} = issue}} <- state.running, into: %{}, do: {issue_id, issue}
    polled = for {_repo, entry} <- state.repo_poll_cache, %Issue{id: issue_id} = issue <- Map.get(entry, :issues, []), into: %{}, do: {issue_id, issue}
    running |> Map.merge(state.forced_issues) |> Map.merge(polled)
  end

  defp tick_reader(:poll, _list_records), do: &{&1, fetch_issue_states_if_needed(&1)}
  defp tick_reader({:record, held}, list_records), do: recorded_tick_reader(list_records.(), held)

  # Each ticket read from its record: one Linear no longer has (a webhook said it was removed) is
  # left out, as a by-id read leaves it out, so its run stops and its watch, force or stop ends. One
  # with no observed record is not judged this tick, as a failed read judges none. A watched plan
  # parent whose comments only Linear holds is read by id (`plan_comment_reads/1`).
  defp recorded_tick_reader(records, held) when is_list(records) do
    recorded = recorded_issues(records)

    fn issue_ids ->
      {known, issues} = Enum.reduce(issue_ids, {[], []}, &recorded_tick_issue(&1, &2, recorded, held))
      {Enum.reverse(known), issues |> Enum.reverse() |> plan_comment_reads()}
    end
  end

  defp recorded_tick_reader(error, _held), do: &{&1, error}

  defp recorded_tick_issue(issue_id, {known, issues}, recorded, held) do
    case Map.fetch(recorded, issue_id) do
      {:ok, :removed} -> {[issue_id | known], issues}
      {:ok, %Issue{} = issue} -> {[issue_id | known], [with_held_text(issue, Map.get(held, issue_id)) | issues]}
      :error -> {known, issues}
    end
  end

  # The newest observed record of each ticket across the repos, as the issue it describes, or
  # `:removed`.
  defp recorded_issues(records) do
    records
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.filter(&(is_binary(&1.issue_id) and &1.linear_updated_at != nil))
    |> Enum.sort_by(& &1.linear_updated_at, DateTime)
    |> Map.new(fn
      %{removed_at: nil} = record -> {record.issue_id, Candidates.issue_from_record(record)}
      record -> {record.issue_id, :removed}
    end)
  end

  # A plan parent in `Plan Review` is in no repo poll (it is not an active state) and its record keeps
  # no comments, so the comments a person leaves on a plan under review exist only in Linear. Such a
  # parent the plan-comment reader acts on (`PlanComments.action/3`) is read by id, as under `poll`,
  # so it sees the same comments.
  defp plan_comment_reads(issues) do
    settings = Config.settings!()
    {active_states, terminal_states} = {active_state_set(settings), terminal_state_set(settings)}
    unpolled? = &(PlanComments.action(&1, terminal_states, settings) != nil and not active_issue_state?(&1.state, active_states))

    case Enum.filter(issues, unpolled?) do
      [] ->
        {:ok, issues}

      unpolled ->
        with {:ok, read} <- fetch_observed_issues_by_ids(Enum.map(unpolled, & &1.id)) do
          read_by_id = Map.new(read, &{&1.id, &1})
          {:ok, Enum.map(issues, &Map.get(read_by_id, &1.id, &1))}
        end
    end
  end

  defp fetch_issue_states_if_needed([]), do: {:ok, []}
  defp fetch_issue_states_if_needed(issue_ids), do: fetch_observed_issues_by_ids(issue_ids)

  # Every by-id read the poll and dispatch make also writes what it read into the tickets' records,
  # each under the repo that holds its record, so the record is as fresh as Symphony's newest read.
  defp fetch_observed_issues_by_ids(issue_ids) do
    with {:ok, issues} = result when is_list(issues) <- Tracker.fetch_issue_states_by_ids(issue_ids) do
      TicketObservation.observe_held(issues, source: :by_id)
      result
    end
  end

  defp fetch_due_repo_if_needed(nil), do: :not_due

  # The poll log keeps what the poll fetched for the Setup routing check, which reads no issues itself,
  # and for `RepoTeams`, whose last way to find a repo's team is the team of its polled issues.
  defp fetch_due_repo_if_needed(repo) do
    repo_name = repo_name(repo)
    {repo_name, PollLog.record(repo, Tracker.fetch_candidate_issues_for_repo(repo))}
  end

  # Runs in the poll task: looks up the blockers of the polled repo's Todo tickets that
  # `UpdateHold.hold/4` needs. Tickets of repos not polled this cycle were looked up when they were.
  # The same task writes the rulings people gave in comments into the tickets' Decisions sections.
  defp resolve_update_holds({repo_name, {:ok, issues}}, cache) when is_list(issues) do
    terminal_states = Config.settings!().tracker.terminal_states
    {_changed, cache} = sweep_blocked_holds(repo_name, issues, terminal_states, cache)
    _ = Decisions.sweep(issues, repo_key: repo_name)
    UpdateHold.resolve(issues, BuildInfo.current(), cache, terminal_states, repo_key: repo_name)
  end

  defp resolve_update_holds(_repo_result, cache), do: cache

  # Runs in the poll task: reconciles each polled issue's Blocked hold against its blockers — a
  # ticket in Todo with an open blocker gains the hold (and pauses), and one whose blockers all went
  # terminal loses it and dispatches, with no state move and no person involved. A fix-ticket hold
  # whose fix merged into Symphony itself also waits for the running app, through the same cache as
  # `UpdateHold`. Resolving the repo's settings once here keeps it off the per-issue config read.
  defp sweep_blocked_holds(repo_name, issues, terminal_states, cache) do
    case Config.settings_for_repo(repo_name) do
      {:ok, settings} -> BlockedHold.sweep(issues, terminal_states, settings: settings, repo_key: repo_name, update_hold_cache: cache)
      {:error, _reason} -> {0, cache}
    end
  end

  defp apply_repo_poll_task_result(
         %State{} = state,
         %{
           repos: repos,
           now_ms: now_ms,
           read_at: read_at,
           running_ids: running_ids,
           running_result: running_result,
           watching_ids: watching_ids,
           watching_result: watching_result,
           forced_ids: forced_ids,
           forced_result: forced_result,
           repo_result: repo_result
         } = result
       ) do
    state =
      %{state | update_hold_cache: Map.get(result, :update_hold_cache, state.update_hold_cache)}
      |> apply_running_issue_states_result(running_ids, running_result)
      |> apply_watching_issue_states_result(watching_ids, watching_result)
      |> apply_forced_poll_result(repo_result, forced_ids, forced_result, now_ms)
      |> apply_operator_stops_result(Map.get(result, :stopped_ids, []), Map.get(result, :stopped_result, {:ok, []}))

    case apply_repo_poll_result(state, repos, repo_result, now_ms, read_at) do
      {:ok, %{dispatchable: issues}, state} ->
        state =
          state
          |> prune_quality_gate_cache_to_active(issues)
          |> clear_running_quality_gate_cache_entries()
          |> put_epic_lanes(issues)
          |> put_forced_parts(issues)
          |> remember_forced_issues(issues)
          |> put_blocked(issues)
          |> release_merging_ci_waits(issues)

        if available_slots(state) > 0 or available_finishing_slots(state) > 0 or forced_pass_needed?(state, issues) do
          issues
          |> reject_running_quality_gate_candidates(state)
          |> start_quality_gate_or_dispatch(state, :poll)
        else
          finish_poll_cycle(state, now_ms)
        end

      {:error, reason, state} ->
        log_poll_error(reason)
        finish_poll_cycle(state, now_ms)
    end
  end

  defp apply_repo_poll_task_result(%State{} = state, _result), do: finish_poll_cycle(state, System.monotonic_time(:millisecond))

  defp finish_poll_cycle(%State{} = state, now_ms) do
    requests_total = RateLimit.requests_total()
    state = release_orphaned_claims(state)

    %{
      state
      | linear_requests_last_poll: max(requests_total - state.linear_requests_mark, 0),
        linear_requests_mark: requests_total
    }
    |> schedule_tick(max(next_repo_poll_delay_ms(state, now_ms), RateLimit.remaining_pause_ms()))
    |> Map.put(:poll_check_in_progress, false)
  end

  # A claim is only held by a running agent, a queued retry, a retry whose async quality gate or
  # dispatch readiness check is in flight, or a Linear task that keeps it until its answer is
  # handled (a retry's refresh, the post-PR move, the move to the blocked state). Any other claim is
  # orphaned: the poll skips claimed issues, so release it rather than leave the issue
  # undispatchable until a restart.
  defp release_orphaned_claims(%State{} = state) do
    held = claim_holders(state)

    state.claimed
    |> Enum.reject(&MapSet.member?(held, &1))
    |> Enum.reduce(state, fn issue_id, state ->
      Logger.warning("Releasing orphaned claim with no running agent, retry or slot wait: issue_id=#{issue_id}")
      release_issue_claim(state, issue_id)
    end)
  end

  defp claim_holders(%State{} = state) do
    in_flight_retries =
      Map.values(state.quality_gate_tasks) ++ Enum.map(Map.values(state.dispatch_readiness_tasks), & &1.kind)

    for({:active_retry, %Issue{id: issue_id}, _attempt, _metadata} <- in_flight_retries, do: issue_id)
    |> Enum.concat(Map.keys(state.running))
    |> Enum.concat(Map.keys(state.retry_attempts))
    |> Enum.concat(Map.keys(state.slot_waiting))
    |> Enum.concat(claim_holding_tracker_task_issue_ids(state))
    |> MapSet.new()
  end

  @claim_holding_tracker_task_kinds [:retry_refresh, :blocked_hold, :setup_block]

  defp claim_holding_tracker_task_issue_ids(%State{tracker_tasks: tasks}) do
    for {_ref, %{kind: kind, issue_ids: issue_ids}} <- tasks,
        kind in @claim_holding_tracker_task_kinds,
        issue_id <- issue_ids,
        do: issue_id
  end

  defp log_poll_error(:missing_linear_api_token), do: Logger.error("Linear API token missing in WORKFLOW.md")
  defp log_poll_error(:missing_linear_scoping_filter), do: Logger.error("Linear scoping filter missing in WORKFLOW.md")
  defp log_poll_error(:missing_tracker_kind), do: Logger.error("Tracker kind missing in WORKFLOW.md")

  defp log_poll_error({:unsupported_tracker_kind, kind}) do
    Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")
  end

  defp log_poll_error({:invalid_workflow_config, message}), do: Logger.error("Invalid WORKFLOW.md config: #{message}")

  defp log_poll_error({:missing_workflow_file, path, reason}) do
    Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
  end

  defp log_poll_error(:workflow_front_matter_not_a_map) do
    Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
  end

  defp log_poll_error({:workflow_parse_error, reason}), do: Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
  defp log_poll_error(reason), do: Logger.error("Failed to fetch from Linear: #{inspect(reason)}")

  defp record_tracker_poll_success(%State{} = state) do
    %{state | tracker_health: empty_tracker_health(current_tracker_kind())}
  end

  defp record_tracker_poll_failure(%State{} = state, reason) do
    health = state.tracker_health || %{}
    existing_failures = tracker_failure_count(health)
    consecutive_failures = existing_failures + 1

    since =
      case {existing_failures, Map.get(health, :since)} do
        {failures, %DateTime{} = since} when is_integer(failures) and failures > 0 -> since
        _ -> DateTime.utc_now()
      end

    %{
      state
      | tracker_health: %{
          tracker: current_tracker_kind(),
          reason: tracker_failure_reason(reason),
          since: since,
          consecutive_failures: consecutive_failures
        }
    }
  end

  defp empty_tracker_health(tracker) do
    %{tracker: normalize_tracker_kind(tracker), reason: nil, since: nil, consecutive_failures: 0}
  end

  defp tracker_failure_count(health) when is_map(health) do
    case Map.get(health, :consecutive_failures, 0) do
      failures when is_integer(failures) and failures > 0 -> failures
      _ -> 0
    end
  end

  defp current_tracker_kind do
    Config.settings!().tracker.kind
    |> normalize_tracker_kind()
  rescue
    exception in [ArgumentError, KeyError, MatchError, FunctionClauseError] ->
      Logger.error("tracker_config_failed reason=#{config_exception_reason(exception)}")
      :unknown
  end

  defp normalize_tracker_kind(:linear), do: :linear
  defp normalize_tracker_kind("linear"), do: :linear
  defp normalize_tracker_kind(:memory), do: :memory
  defp normalize_tracker_kind("memory"), do: :memory
  defp normalize_tracker_kind(tracker) when is_atom(tracker), do: tracker
  defp normalize_tracker_kind(_tracker), do: :unknown

  defp tracker_failure_reason(:missing_linear_api_token), do: :missing_linear_api_token
  defp tracker_failure_reason(:linear_api_request), do: :linear_api_request
  defp tracker_failure_reason({:linear_api_request, _reason}), do: :linear_api_request
  defp tracker_failure_reason(:missing_linear_scoping_filter), do: :missing_linear_scoping_filter
  defp tracker_failure_reason(:missing_tracker_kind), do: :missing_tracker_kind
  defp tracker_failure_reason(:workflow_front_matter_not_a_map), do: :workflow_front_matter_not_a_map
  defp tracker_failure_reason({:unsupported_tracker_kind, _kind} = reason), do: reason
  defp tracker_failure_reason({:unsupported_agent_kind, _kind} = reason), do: reason
  defp tracker_failure_reason({:missing_workflow_file, _path, _reason} = reason), do: reason
  defp tracker_failure_reason({:workflow_parse_error, _reason} = reason), do: reason

  defp tracker_failure_reason({:invalid_workflow_config, message}) when is_binary(message),
    do: {:invalid_workflow_config, message}

  defp tracker_failure_reason(_reason), do: :unknown

  @doc false
  @spec force_repo_due_for_test(State.t(), String.t() | nil, integer()) ::
          {:coalesced | {:poll_at, integer()}, State.t()}
  def force_repo_due_for_test(%State{} = state, repo_key, now_ms), do: force_repo_due(state, repo_key, now_ms)

  @doc false
  @spec apply_repo_poll_result_for_test(
          State.t(),
          [term()],
          {String.t(), {:ok, [Issue.t()]} | {:error, term()}},
          integer()
        ) ::
          {:ok, %{dispatchable: [Issue.t()], conflicts: [Issue.t()]}, State.t()}
          | {:error, term(), State.t()}
  def apply_repo_poll_result_for_test(%State{} = state, repos, repo_result, now_ms),
    do: apply_repo_poll_result(state, repos, repo_result, now_ms, DateTime.utc_now())

  @doc false
  @spec poll_candidate_issue_buckets_for_test(
          State.t(),
          [term()],
          (term() -> {:ok, [Issue.t()]} | {:error, term()}),
          integer()
        ) ::
          {:ok, %{dispatchable: [Issue.t()], conflicts: [Issue.t()]}, State.t()}
          | {:error, term(), State.t()}
  def poll_candidate_issue_buckets_for_test(%State{} = state, repos, fetcher, now_ms)
      when is_list(repos) and is_function(fetcher, 1) and is_integer(now_ms) do
    poll_candidate_issue_buckets(state, repos, fetcher, now_ms)
  end

  @doc false
  @spec current_tracker_kind_for_test() :: atom()
  def current_tracker_kind_for_test do
    current_tracker_kind()
  end

  @doc false
  @spec review_agent_enabled_for_repo_for_test(String.t() | nil) :: boolean()
  def review_agent_enabled_for_repo_for_test(repo_key) do
    review_agent_enabled_for_repo(repo_key)
  end

  defp poll_candidate_issue_buckets(%State{} = state, repos, fetcher, now_ms)
       when is_list(repos) and is_function(fetcher, 1) and is_integer(now_ms) do
    state = sync_repo_poll_state(state, repos, now_ms)

    case take_due_repo(state, repos, now_ms) do
      {nil, state} ->
        buckets = candidate_buckets_from_cache(state, repos)
        {:ok, buckets, put_conflict_bucket(state, buckets.conflicts)}

      {repo, state} ->
        poll_due_repo(state, repos, repo, fetcher, now_ms)
    end
  end

  defp poll_due_repo(state, repos, repo, fetcher, now_ms) do
    repo_name = repo_name(repo)
    read_at = DateTime.utc_now()
    result = fetcher.(repo)
    apply_due_repo_fetch_result(state, repos, repo_name, result, now_ms, read_at)
  end

  defp apply_repo_poll_result(state, repos, :not_due, _now_ms, _read_at) do
    buckets = candidate_buckets_from_cache(state, repos)
    {:ok, buckets, put_conflict_bucket(state, buckets.conflicts)}
  end

  defp apply_repo_poll_result(state, repos, {repo_name, result}, now_ms, read_at) when is_binary(repo_name) do
    apply_due_repo_fetch_result(state, repos, repo_name, result, now_ms, read_at)
  end

  defp apply_repo_poll_result(state, _repos, result, _now_ms, _read_at), do: {:error, {:invalid_repo_poll_result, result}, state}

  # `read_at` is when Linear was read, taken just before the fetch. The read is written into the
  # records as of then, so a write the poll made itself is never newer than its own snapshot, and a
  # write that landed while the poll ran (a move of Symphony's, a webhook, the poll task's by-id
  # reads) is.
  defp apply_due_repo_fetch_result(state, repos, repo_name, result, now_ms, read_at) do
    case result do
      {:ok, issues} when is_list(issues) ->
        TicketObservation.observe_all(repo_name, issues, now: read_at)

        state =
          state
          |> put_repo_poll_cache(repo_name, issues, now_ms, read_at)
          |> put_repo_next_due(repo_name, now_ms + linear_poll_interval_ms(state))
          |> keep_forced_repo_due(repo_name)
          |> record_tracker_poll_success()

        buckets = candidate_buckets_from_cache(state, repos)
        {:ok, buckets, put_conflict_bucket(state, buckets.conflicts)}

      {:error, reason} ->
        state =
          state
          |> put_repo_next_due(repo_name, now_ms + repo_poll_retry_delay_ms(state, repos))
          |> keep_forced_repo_due(repo_name)
          |> record_tracker_poll_failure(reason)

        cond do
          repo_poll_cache_warmed?(state, repo_name) ->
            Logger.warning("Linear repo poll failed for #{repo_name}; using cached candidate issues: #{inspect(reason)}")
            buckets = candidate_buckets_from_cache(state, repos)
            {:ok, buckets, put_conflict_bucket(state, buckets.conflicts)}

          repo_poll_failure_count(state, repo_name) + 1 >= @repo_poll_cold_failure_warm_after ->
            failure_count = repo_poll_failure_count(state, repo_name) + 1

            Logger.warning("Linear repo poll failed for #{repo_name} #{failure_count} consecutive times; treating cold cache as empty: #{inspect(reason)}")

            state = put_repo_poll_cache(state, repo_name, [], now_ms, read_at)
            buckets = candidate_buckets_from_cache(state, repos)
            {:ok, buckets, put_conflict_bucket(state, buckets.conflicts)}

          true ->
            state = put_repo_cold_poll_failure(state, repo_name)
            {:error, reason, state}
        end
    end
  end

  # The dispatch candidates of the cycle, from the side `dispatch.source` names, read on each cycle so
  # a change applies at the next one: `poll` from each repo's poll cache, `record` from each repo's
  # ticket records (`Dispatch.Candidates`), a store read with no Linear read. Either way the cycle
  # works out the other side too and reports how the two differ (`Dispatch.Shadow`). A repo whose
  # records can't be read gives no record candidates that cycle. Nothing dispatches until every
  # repo's cache is warm, so after a start the first poll of each repo has refreshed its records.
  defp candidate_buckets_from_cache(%State{} = state, repos) when is_list(repos) do
    settings = Config.settings!()
    in_use = dispatch_source_in_use()
    sides = Enum.map(repos, &dispatch_sides(state, &1, settings, in_use))
    buckets = Client.aggregate_repo_results(for side <- sides, do: {side.repo_key, dispatch_side(side, in_use)})
    shadow_dispatch(sides, in_use, settings)

    if repo_poll_cache_warmed?(state, repos) do
      buckets
    else
      %{buckets | dispatchable: []}
    end
  end

  defp dispatch_source_in_use do
    case Config.dispatch_source() do
      "record" -> :record
      _poll -> :poll
    end
  end

  # One repo's two sides: its poll cache with when it was read, and its candidates from the records
  # (nil when they can't be read) with when each record's phase was written. With the poll in use,
  # the records of a repo whose cache is cold are not read: the shadow leaves it out of the cycle.
  defp dispatch_sides(%State{} = state, repo, settings, in_use) do
    repo_name = repo_name(repo)
    warm? = repo_poll_cache_warmed?(state, repo_name)
    entry = Map.get(state.repo_poll_cache, repo_name, %{})
    {record, phase_at} = if warm? or in_use == :record, do: record_candidates(repo, settings), else: {nil, %{}}

    %{
      repo_key: repo_name,
      warm?: warm?,
      cache: Map.get(entry, :issues, []),
      read_at: Map.get(entry, :read_at),
      record: record,
      phase_at: phase_at
    }
  end

  defp record_candidates(repo, settings) do
    repo_name = repo_name(repo)

    case RunStore.list_ticket_states(repo_name) do
      records when is_list(records) ->
        candidates = Candidates.from_records(repo_name, records, settings, shadow_route_opts(repo, settings)).candidates
        {candidates, Map.new(records, &{Map.get(&1, :issue_id), Map.get(&1, :phase_at)})}

      _error ->
        {nil, %{}}
    end
  end

  @record_issue_fields [
    :id,
    :identifier,
    :title,
    :state,
    :labels,
    :priority,
    :assignee_id,
    :assigned_to_worker,
    :blocked_by,
    :sub_issues,
    :parent,
    :url,
    :repo_key,
    :created_at
  ]

  defp dispatch_side(side, :poll), do: side.cache

  defp dispatch_side(side, :record) do
    polled = Map.new(side.cache, &{&1.id, &1})
    for issue <- side.record || [], do: with_held_text(issue, Map.get(polled, issue.id))
  end

  # An issue rebuilt from its record (`Candidates.issue_from_record/1`) decides with what its record
  # says. What only a Linear read gives (the description, comments, rulings, linked issues, team,
  # project and branch) comes from the issue Symphony already holds for the ticket when it has one
  # (the poll cache's for a candidate, a run's or the started candidate's for the tick and the
  # revalidation), with the `updatedAt` it was read at, so the quality gate keys its verdict on the
  # text it scored and the plan-comment reader sees the comments. A ticket only the records have has
  # none of it until its repo's poll reads it.
  defp with_held_text(%Issue{} = issue, nil), do: issue
  defp with_held_text(%Issue{} = issue, %Issue{} = held), do: struct(held, Map.take(issue, @record_issue_fields))

  # Every poll cycle compares, for each repo, the candidates the poll cache gives with the ones the
  # records give and reports how they differ (`Dispatch.Shadow`), whichever side dispatch reads. It
  # reads the store and no Linear: `assignee: me` takes the viewer the poll already resolved. A
  # difference whose record phase was written after the cache was read is the record being newer
  # (a move of Symphony's, a webhook), counted apart. A repo whose cache is still cold, or whose
  # records can't be read, is left out of the cycle.
  defp shadow_dispatch(sides, in_use, settings) do
    filter = {active_state_set(settings), terminal_state_set(settings)}

    compared =
      for %{warm?: true, record: record} = side <- sides,
          is_list(record),
          do: side |> shadow_repo_differences(in_use, filter) |> Shadow.classify(side.read_at, side.phase_at)

    if compared != [] do
      differences = Enum.flat_map(compared, & &1.differences)
      record_newer = Enum.flat_map(compared, & &1.record_newer)
      Shadow.record(%{differences: differences, record_newer: record_newer}, Config.dispatch_shadow_window())
    end

    :ok
  end

  defp shadow_repo_differences(side, in_use, {active_states, terminal_states}) do
    poll =
      for %Issue{} = issue <- side.cache,
          candidate_issue?(issue, active_states, terminal_states),
          do: %{issue | repo_key: side.repo_key}

    case in_use do
      :poll -> Shadow.compare(poll, side.record, :poll)
      :record -> Shadow.compare(side.record, poll, :record)
    end
  end

  # The route's assignee, else the tracker's, as the poll filters by; `me` is the viewer's id.
  defp shadow_route_opts(repo, settings) do
    case String.trim(route_assignee(repo) || settings.tracker.assignee || "") do
      "me" -> [route: repo, assignee_ids: List.wrap(Client.known_viewer_id())]
      _assignee -> [route: repo]
    end
  end

  defp route_assignee(%{assignee: assignee}), do: assignee
  defp route_assignee(_repo), do: nil

  defp sync_repo_poll_state(%State{} = state, repos, now_ms) do
    repo_names = Enum.map(repos, &repo_name/1)
    existing_due = state.repo_poll_due_at_ms || %{}
    existing_cache = state.repo_poll_cache || %{}
    stagger_ms = repo_poll_stagger_ms(state, repos)

    repo_poll_due_at_ms =
      repos
      |> Enum.with_index()
      |> Map.new(fn {repo, index} ->
        name = repo_name(repo)
        {name, Map.get(existing_due, name, now_ms + index * stagger_ms)}
      end)

    %{
      state
      | repo_poll_due_at_ms: repo_poll_due_at_ms,
        repo_poll_cache: Map.take(existing_cache, repo_names),
        repo_poll_forced: MapSet.intersection(state.repo_poll_forced, MapSet.new(repo_names)),
        repo_poll_forced_at_ms: Map.take(state.repo_poll_forced_at_ms, repo_names),
        conflicts: state.conflicts || %{}
    }
  end

  # A move marks its repo forced, so the next poll due by then takes it ahead of any other due repo.
  # A forcing whose poll has not started yet already covers the move. One whose poll started inside
  # the window may have read Linear before the move, so the move is polled again at the window's end;
  # later moves in the window share that poll. Outside the window the repo is due now.
  defp force_repo_due(%State{} = state, repo_key, now_ms) when is_binary(repo_key) do
    forced_at_ms = Map.get(state.repo_poll_forced_at_ms, repo_key)

    cond do
      MapSet.member?(state.repo_poll_forced, repo_key) ->
        {:coalesced, state}

      is_integer(forced_at_ms) and now_ms - forced_at_ms < @forced_poll_window_ms ->
        mark_repo_forced(state, repo_key, forced_at_ms + @forced_poll_window_ms)

      true ->
        mark_repo_forced(state, repo_key, now_ms)
    end
  end

  defp force_repo_due(%State{} = state, _repo_key, now_ms), do: {{:poll_at, now_ms}, state}

  defp mark_repo_forced(%State{} = state, repo_key, due_at_ms) do
    {{:poll_at, due_at_ms},
     %{
       state
       | repo_poll_due_at_ms: Map.update(state.repo_poll_due_at_ms, repo_key, due_at_ms, &min(&1, due_at_ms)),
         repo_poll_forced: MapSet.put(state.repo_poll_forced, repo_key),
         repo_poll_forced_at_ms: Map.put(state.repo_poll_forced_at_ms, repo_key, due_at_ms)
     }}
  end

  # The repo this poll fetches; its forced mark goes with it, so a move made while it is in flight
  # marks it again.
  defp take_due_repo(%State{} = state, repos, now_ms) do
    case next_due_repo(state, repos, now_ms) do
      nil -> {nil, state}
      repo -> {repo, %{state | repo_poll_forced: MapSet.delete(state.repo_poll_forced, repo_name(repo))}}
    end
  end

  # A repo forced while its poll was in flight stays due by its forcing: that poll may have read it
  # before the move.
  defp keep_forced_repo_due(%State{} = state, repo_name) do
    if MapSet.member?(state.repo_poll_forced, repo_name) do
      forced_at_ms = Map.fetch!(state.repo_poll_forced_at_ms, repo_name)
      %{state | repo_poll_due_at_ms: Map.update!(state.repo_poll_due_at_ms, repo_name, &min(&1, forced_at_ms))}
    else
      state
    end
  end

  # A forced repo whose forcing is due goes first, the oldest forcing first.
  defp next_due_repo(%State{} = state, repos, now_ms) do
    case Enum.filter(repos, &forced_repo_due?(state, repo_name(&1), now_ms)) do
      [] -> next_timed_due_repo(state, repos, now_ms)
      forced -> Enum.min_by(forced, &{Map.fetch!(state.repo_poll_forced_at_ms, repo_name(&1)), repo_name(&1)})
    end
  end

  defp forced_repo_due?(%State{} = state, repo_name, now_ms),
    do: MapSet.member?(state.repo_poll_forced, repo_name) and state.repo_poll_forced_at_ms[repo_name] <= now_ms

  defp next_timed_due_repo(%State{} = state, repos, now_ms) do
    sorted_repos =
      repos
      |> Enum.map(fn repo -> {repo, Map.get(state.repo_poll_due_at_ms, repo_name(repo), now_ms)} end)
      |> Enum.sort_by(fn {repo, due_at_ms} -> {due_at_ms, repo_name(repo)} end)

    sorted_repos
    |> Enum.find(fn {_repo, due_at_ms} -> due_at_ms <= now_ms end)
    |> case do
      {repo, _due_at_ms} ->
        repo

      nil ->
        nil
    end
  end

  defp repo_poll_cache_warmed?(%State{} = state, repos) when is_list(repos) do
    Enum.all?(repos, &repo_poll_cache_warmed?(state, repo_name(&1)))
  end

  defp repo_poll_cache_warmed?(%State{} = state, repo_name) when is_binary(repo_name) do
    case Map.get(state.repo_poll_cache, repo_name) do
      nil -> false
      cache_entry -> Map.get(cache_entry, :warmed?, true)
    end
  end

  # `read_at` is when Linear was read for the snapshot. The dispatch shadow holds it against when each
  # record's phase was written, so only a write after the read is newer than the snapshot.
  defp put_repo_poll_cache(%State{} = state, repo_name, issues, now_ms, read_at) do
    cache_entry = %{issues: issues, fetched_at_ms: now_ms, read_at: read_at}
    %{state | repo_poll_cache: Map.put(state.repo_poll_cache, repo_name, cache_entry)}
  end

  defp put_repo_next_due(%State{} = state, repo_name, due_at_ms) do
    %{state | repo_poll_due_at_ms: Map.put(state.repo_poll_due_at_ms, repo_name, due_at_ms)}
  end

  defp repo_poll_failure_count(%State{} = state, repo_name) do
    state.repo_poll_cache
    |> Map.get(repo_name, %{})
    |> Map.get(:cold_failure_count, 0)
  end

  defp put_repo_cold_poll_failure(%State{} = state, repo_name) do
    failure_entry = %{
      issues: [],
      fetched_at_ms: nil,
      cold_failure_count: repo_poll_failure_count(state, repo_name) + 1,
      warmed?: false
    }

    %{state | repo_poll_cache: Map.put(state.repo_poll_cache, repo_name, failure_entry)}
  end

  defp repo_poll_retry_delay_ms(%State{poll_interval_ms: interval_ms} = state, _repos)
       when is_integer(interval_ms) and interval_ms > 0 do
    linear_poll_interval_ms(state)
  end

  defp repo_poll_retry_delay_ms(state, repos), do: repo_poll_stagger_ms(state, repos)

  # Soft brake: stretch the issue-poll interval while Linear reports little of
  # the hourly budget left, so Symphony rarely runs it down to zero.
  defp linear_poll_interval_ms(%State{poll_interval_ms: interval_ms}) do
    interval_ms * RateLimit.poll_interval_multiplier()
  end

  defp put_conflict_bucket(%State{} = state, conflicts) when is_list(conflicts) do
    conflict_map =
      conflicts
      |> Enum.reject(&(issue_id(&1) == nil))
      |> Map.new(fn issue -> {issue_id(issue), issue} end)

    %{state | conflicts: conflict_map}
  end

  defp next_repo_poll_delay_ms(%State{} = state, now_ms) when is_integer(now_ms) do
    state.repo_poll_due_at_ms
    |> case do
      due_at_ms when is_map(due_at_ms) and map_size(due_at_ms) > 0 ->
        due_at_ms
        |> Map.values()
        |> Enum.min()
        |> Kernel.-(now_ms)
        |> max(0)

      _ ->
        state.poll_interval_ms
    end
  end

  defp repo_poll_stagger_ms(%State{poll_interval_ms: interval_ms}, repos)
       when is_integer(interval_ms) and interval_ms > 0 and is_list(repos) do
    repo_count = max(length(repos), 1)
    max(1, div(interval_ms, repo_count))
  end

  defp repo_poll_stagger_ms(_state, _repos), do: 1

  defp repo_name(repo) when is_map(repo) do
    Map.get(repo, :name) || Map.get(repo, "name") || inspect(repo)
  end

  defp repo_name(repo), do: inspect(repo)

  defp issue_id(%Issue{id: id}) when is_binary(id) and id != "", do: id
  defp issue_id(_issue), do: nil

  defp apply_running_issue_states_result(%State{} = state, [], _result), do: state

  defp apply_running_issue_states_result(%State{} = state, running_ids, {:ok, issues})
       when is_list(running_ids) and is_list(issues) do
    issues
    |> reconcile_running_issue_states(
      state,
      active_state_set(),
      terminal_state_set()
    )
    |> reconcile_missing_running_issue_ids(running_ids, issues)
  end

  defp apply_running_issue_states_result(%State{} = state, _running_ids, {:error, reason}) do
    Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")
    state
  end

  defp apply_running_issue_states_result(%State{} = state, _running_ids, result) do
    Logger.debug("Ignoring invalid running issue state refresh result: #{inspect(result)}")
    state
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec apply_operator_stops_result_for_test(State.t(), [String.t()], term()) :: State.t()
  def apply_operator_stops_result_for_test(%State{} = state, stopped_ids, result) when is_list(stopped_ids),
    do: state |> apply_operator_stops_result(stopped_ids, result) |> await_tracker_tasks()

  @doc false
  @spec dispatch_chosen_issues_for_test([Issue.t() | term()], State.t()) :: State.t()
  def dispatch_chosen_issues_for_test(issues, %State{} = state) when is_list(issues), do: issues |> dispatch_chosen_issues(state) |> await_tracker_tasks()

  @doc false
  @spec start_usage_limit_canary_for_test(State.t(), UsageLimit.key(), ([String.t()] -> term())) :: State.t()
  def start_usage_limit_canary_for_test(%State{} = state, key, issue_fetcher) when is_function(issue_fetcher, 1) do
    state |> start_usage_limit_canary(key, Map.fetch!(state.usage_limits, key), issue_fetcher) |> await_tracker_tasks()
  end

  @doc false
  @spec release_merging_ci_waits_for_test(State.t(), [Issue.t()]) :: State.t()
  def release_merging_ci_waits_for_test(%State{} = state, issues) when is_list(issues), do: release_merging_ci_waits(state, issues)

  @doc false
  @spec put_epic_lanes_for_test(State.t(), [Issue.t()]) :: State.t()
  def put_epic_lanes_for_test(%State{} = state, issues) when is_list(issues), do: put_epic_lanes(state, issues)

  @doc false
  @spec put_forced_parts_for_test(State.t(), [Issue.t()]) :: State.t()
  def put_forced_parts_for_test(%State{} = state, issues) when is_list(issues), do: put_forced_parts(state, issues)

  @doc false
  @spec quality_gate_input_for_test(State.t(), [Issue.t()], term()) :: [Issue.t()]
  def quality_gate_input_for_test(%State{} = state, issues, context \\ :poll) when is_list(issues), do: with_text_read(issues, state, context)

  @doc false
  @spec apply_forced_poll_result_for_test(State.t(), term(), [String.t()], term(), integer()) :: State.t()
  def apply_forced_poll_result_for_test(%State{} = state, repo_result, forced_ids, forced_result, poll_started_ms \\ System.monotonic_time(:millisecond)),
    do: apply_forced_poll_result(state, repo_result, forced_ids, forced_result, poll_started_ms)

  @doc false
  @spec put_blocked_for_test(State.t(), [Issue.t()]) :: State.t()
  def put_blocked_for_test(%State{} = state, issues) when is_list(issues), do: put_blocked(state, issues)

  @doc false
  @spec sweep_blocked_holds_for_test(String.t(), [Issue.t()], [String.t()]) :: non_neg_integer()
  def sweep_blocked_holds_for_test(repo_name, issues, terminal_states) when is_list(issues) do
    {changed, _cache} = sweep_blocked_holds(repo_name, issues, terminal_states, UpdateHold.empty_cache())
    changed
  end

  @doc false
  @spec review_breakdown_parents_for_test([Issue.t()], term(), keyword()) :: term()
  def review_breakdown_parents_for_test(issues, %State{} = state, opts \\ []) when is_list(issues),
    do: issues |> review_breakdown_parents(state, opts) |> await_tracker_tasks()

  @doc false
  @spec act_on_plan_comments_for_test(term(), [Issue.t()]) :: term()
  def act_on_plan_comments_for_test(%State{} = state, issues) when is_list(issues), do: state |> act_on_plan_comments(issues) |> await_tracker_tasks()

  @doc false
  @spec close_finished_parents_for_test([Issue.t()], term()) :: term()
  def close_finished_parents_for_test(issues, %State{} = state) when is_list(issues), do: state |> close_finished_parents(issues) |> await_tracker_tasks()

  @doc false
  @spec park_breakdown_parents_for_test([Issue.t()], term()) :: term()
  def park_breakdown_parents_for_test(issues, %State{} = state) when is_list(issues), do: issues |> park_breakdown_parents(state) |> await_tracker_tasks()

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec dispatch_refresh_ids_for_test(State.t(), [Issue.t()], term()) :: [String.t()]
  def dispatch_refresh_ids_for_test(%State{} = state, issues, context) when is_list(issues), do: dispatch_refresh_ids(state, issues, context)

  @doc false
  @spec revalidate_issue_from_record_for_test(Issue.t(), String.t(), boolean()) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_from_record_for_test(%Issue{} = issue, repo_key, sticky_route? \\ false) do
    opts = [sticky_route?: sticky_route?, repo_key: repo_key, source: :record]
    revalidate_issue_for_dispatch(issue, dispatch_issue_fetcher(nil, :record, repo_key), terminal_state_set(), opts)
  end

  @doc false
  @spec dispatch_revalidated_issue_for_test(Issue.t(), boolean()) :: boolean()
  def dispatch_revalidated_issue_for_test(%Issue{} = issue, sticky_route?) when is_boolean(sticky_route?) do
    dispatch_revalidated_issue?(issue, terminal_state_set(), sticky_route?)
  end

  # Test-only entrypoint that exercises the active-retry path synchronously.
  # The production path goes through start_dispatch_readiness/3 (async Task),
  # but unit tests for retry routing only need the dispatch decision and run
  # against a bare State struct (no Orchestrator GenServer), so they invoke
  # handle_active_retry_after_readiness/4 directly via the *_sync_for_test
  # helpers below. Integration tests in OrchestratorStatusTest exercise the
  # full async chain via wait_for_orchestrator_state/3.
  @doc false
  @spec handle_retry_issue_for_test(State.t(), String.t(), non_neg_integer(), map(), ([String.t()] -> term())) ::
          {:noreply, State.t()}
  def handle_retry_issue_for_test(%State{} = state, issue_id, attempt, metadata, issue_fetcher)
      when is_binary(issue_id) and is_integer(attempt) and is_map(metadata) and is_function(issue_fetcher, 1) do
    {:noreply, state} = handle_retry_issue_sync_for_test(state, issue_id, attempt, metadata, issue_fetcher)
    {:noreply, await_tracker_tasks(state)}
  end

  @doc false
  @spec persist_run_start_for_test(Issue.t(), map(), non_neg_integer() | nil) :: :ok
  def persist_run_start_for_test(%Issue{} = issue, running_entry, attempt) when is_map(running_entry) do
    persist_run_start(issue, running_entry, attempt)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec active_state_set_for_test() :: MapSet.t(String.t())
  def active_state_set_for_test, do: active_state_set()

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec sibling_active_workspace_identifiers_for_test(State.t(), String.t(), String.t() | nil) :: [String.t()]
  def sibling_active_workspace_identifiers_for_test(%State{} = state, issue_id, repo_key) do
    sibling_active_workspace_identifiers(state, issue_id, repo_key)
  end

  @doc false
  @spec seed_watching_for_test(State.t()) :: State.t()
  def seed_watching_for_test(%State{} = state) do
    seed_watching_from_completed_run_metadata(state)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) and merging_terminal_grace?(state, issue) ->
        maybe_start_merging_terminal_grace(state, issue)

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        running_entry = Map.get(state.running, issue.id)

        state
        |> terminate_running_issue(issue.id, true, remove_reason: :terminal, issue_state: issue.state)
        |> maybe_emit_issue_completed(issue, running_entry)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      fresh_dispatch_stale_state?(state, issue) ->
        Logger.debug("Ignoring non-active issue state during fresh dispatch grace: #{issue_context(issue)} state=#{issue.state}")

        state

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        running_entry = Map.get(state.running, issue.id)

        state
        |> terminate_running_issue(issue.id, false, track_completed_run: true)
        |> put_watching_issue(issue)
        |> maybe_emit_awaiting_review(issue, running_entry)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp merging_terminal_grace?(%State{} = state, %Issue{id: issue_id}) do
    case Map.get(state.running, issue_id) do
      %{terminal_grace_until_ms: grace_until_ms} when is_integer(grace_until_ms) ->
        System.monotonic_time(:millisecond) <= grace_until_ms

      %{issue: %Issue{state: running_state}} when is_binary(running_state) ->
        normalize_issue_state(running_state) == @merging_state

      _ ->
        false
    end
  end

  defp maybe_start_merging_terminal_grace(%State{} = state, %Issue{id: issue_id} = issue) do
    case Map.get(state.running, issue_id) do
      %{terminal_grace_until_ms: grace_until_ms} when is_integer(grace_until_ms) ->
        state

      running_entry ->
        Logger.info(
          "Issue moved to terminal state while landing: #{issue_context(issue)} state=#{issue.state}; " <>
            "letting active agent finish for up to #{@merging_terminal_grace_ms}ms"
        )

        grace_until_ms = System.monotonic_time(:millisecond) + @merging_terminal_grace_ms
        running = Map.put(state.running, issue_id, Map.put(running_entry, :terminal_grace_until_ms, grace_until_ms))
        %{state | running: running}
    end
  end

  defp fresh_dispatch_stale_state?(%State{} = state, %Issue{id: issue_id}) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{state_reconcile_grace_until_ms: grace_until_ms} when is_integer(grace_until_ms) ->
        System.monotonic_time(:millisecond) <= grace_until_ms

      _ ->
        false
    end
  end

  defp fresh_dispatch_stale_state?(_state, _issue), do: false

  defp watching_issue_ids(%State{} = state) do
    state.completed_run_metadata
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(Map.keys(state.watching) |> MapSet.new())
    |> MapSet.to_list()
    |> Enum.filter(&watchable_linear_issue_id?/1)
    |> Enum.reject(&Map.has_key?(state.retry_attempts, &1))
  end

  defp apply_watching_issue_states_result(%State{} = state, [], _result), do: state

  defp apply_watching_issue_states_result(%State{} = state, issue_ids, {:ok, issues})
       when is_list(issue_ids) and is_list(issues) do
    issues
    |> reconcile_watching_issue_states(
      state,
      active_state_set(),
      terminal_state_set()
    )
    |> reconcile_missing_watching_issue_ids(issue_ids, issues)
    |> act_on_plan_comments(issues)
  end

  defp apply_watching_issue_states_result(%State{} = state, _issue_ids, {:error, reason}) do
    Logger.warning("Failed to refresh watching issue states: #{inspect(reason)}; keeping watched issues")
    state
  end

  defp apply_watching_issue_states_result(%State{} = state, _issue_ids, result) do
    Logger.warning("Ignoring invalid watching issue state refresh result: #{inspect(result)}")
    state
  end

  defp reconcile_watching_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_watching_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_watching_issue_states(
      rest,
      reconcile_watching_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_watching_issue_state(
         %Issue{id: issue_id, state: state_name} = issue,
         state,
         active_states,
         terminal_states
       )
       when is_binary(issue_id) and is_binary(state_name) do
    cond do
      terminal_issue_state?(state_name, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{state_name}; removing from watching")

        state
        |> maybe_emit_issue_completed(issue, Map.get(state.completed_run_metadata, issue_id, %{}))
        |> forget_completed_issue(issue_id)

      watching_issue_state?(state_name, active_states, terminal_states) ->
        put_watching_issue(state, issue)

      true ->
        %{state | watching: Map.delete(state.watching, issue_id)}
    end
  end

  defp reconcile_watching_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_watching_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Issue no longer visible during watching-state refresh: issue_id=#{issue_id}; removing from watching")
        forget_completed_issue(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_watching_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        refreshed_issue = freeze_issue_repo_key(issue, running_entry_repo_key(running_entry))
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: refreshed_issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, opts \\ []) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        state = maybe_track_completed_run(state, issue_id, running_entry, cleanup_workspace, opts)

        persist_run_completion(
          running_entry,
          Keyword.get(opts, :status, "stopped"),
          Keyword.get(opts, :error, "agent stopped by orchestrator")
        )

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        cleanup_agent_session_for_terminated_issue(running_entry, opts)

        if Keyword.get(opts, :run_after_run_hook, false) do
          run_after_run_cleanup(running_entry)
        end

        Verification.release(Map.get(running_entry, :verification), Keyword.get(opts, :error, "agent stopped by orchestrator"))

        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(
            %{
              id: issue_id,
              identifier: identifier,
              repo_key: running_repo_key(state, running_entry),
              remove_reason: Keyword.get(opts, :remove_reason),
              state: Keyword.get(opts, :issue_state)
            },
            worker_host
          )
        end

        repo_key = running_repo_key(state, running_entry)

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }
        |> delete_persisted_retry(issue_id, repo_key)

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().agent.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = first_turn_stall_elapsed_ms(running_entry, now)

    cond do
      not (is_integer(elapsed_ms) and elapsed_ms > timeout_ms) -> state
      observed_run?(running_entry) -> stall_restart(state, issue_id, running_entry, elapsed_ms)
      true -> log_unobserved_run(state, issue_id, running_entry, now)
    end
  end

  defp stall_restart(state, issue_id, running_entry, elapsed_ms) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)

    Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

    next_attempt = next_retry_attempt_from_running(running_entry)
    error = "stalled for #{elapsed_ms}ms without codex activity"

    state =
      terminate_running_issue(state, issue_id, false, status: "timeout", error: error)

    if pr_run_entry?(running_entry) do
      state
    else
      schedule_issue_retry(state, issue_id, next_attempt, %{
        repo_key: running_entry_repo_key(running_entry),
        identifier: identifier,
        title: running_entry_title(running_entry),
        error: error
      })
    end
  end

  # Silence is proven only once the orchestrator has heard from the run's agent: a session id, a
  # transcript event or a `tool_progress` heartbeat. A run it never heard from is unobserved, not
  # silent (TP-1273: a reviewer whose events never reached the orchestrator was killed while it
  # worked), so both watchdogs leave it to the exit path and the agent's own timeouts.
  defp observed_run?(%{session_id: session_id}) when is_binary(session_id), do: true
  defp observed_run?(%{last_codex_timestamp: %DateTime{}}), do: true
  defp observed_run?(%{agent_observed: true}), do: true
  defp observed_run?(_running_entry), do: false

  defp log_unobserved_run(state, _issue_id, %{unobserved_logged: true}, _now), do: state

  defp log_unobserved_run(state, issue_id, running_entry, now) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    age_ms = max(0, DateTime.diff(now, Map.get(running_entry, :started_at) || now, :millisecond))

    Logger.warning(
      "watchdog.unobserved_run issue_id=#{issue_id} issue_identifier=#{identifier} run_kind=#{watchdog_run_kind(running_entry)} age_ms=#{age_ms}; no session or agent event seen, not restarting"
    )

    put_running_entry(state, issue_id, Map.put(running_entry, :unobserved_logged, true))
  end

  defp watchdog_run_kind(%{run_profile: %{kind: kind}}), do: to_string(kind)
  defp watchdog_run_kind(running_entry), do: if(pr_run_entry?(running_entry), do: "pr", else: "unknown")

  defp first_turn_stall_elapsed_ms(%{last_codex_timestamp: %DateTime{}}, _now), do: nil

  defp first_turn_stall_elapsed_ms(running_entry, now) do
    running_entry
    |> first_turn_started_at()
    |> after_linear_wait(running_entry)
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  # A workspace hook (`after_create` can take minutes) runs under its own timeout, so
  # while one runs the clock starts at its deadline, and once it has ended, at its end.
  defp first_turn_started_at(%{workspace_hook: %{deadline: %DateTime{} = deadline}}), do: deadline

  defp first_turn_started_at(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_event_at) || Map.get(running_entry, :started_at)
  end

  defp first_turn_started_at(_running_entry), do: nil

  defp maybe_run_watchdog(%State{} = state) do
    config = Config.settings!().watchdog

    cond do
      config.enabled != true ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_restart_stuck_issue(state_acc, issue_id, running_entry, now, config.no_progress_threshold_ms)
        end)
    end
  end

  defp maybe_restart_stuck_issue(state, issue_id, _running_entry, now, threshold_ms) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      running_entry ->
        elapsed_ms = watchdog_elapsed_ms(running_entry, now)

        cond do
          not (is_integer(elapsed_ms) and elapsed_ms >= threshold_ms) -> state
          observed_run?(running_entry) -> restart_stuck_issue(state, issue_id, running_entry, elapsed_ms)
          true -> log_unobserved_run(state, issue_id, running_entry, now)
        end
    end
  end

  defp watchdog_elapsed_ms(running_entry, now) do
    running_entry
    |> watchdog_clock_started_at()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  # As for the first-turn stall check, a running workspace hook's clock starts at its deadline.
  # So does the clock of a run waiting on one of Symphony's own tool calls: the agent shows no
  # activity until the call returns, at the latest when its timeout stops it.
  defp watchdog_clock_started_at(%{workspace_hook: %{deadline: %DateTime{} = deadline}}), do: deadline

  defp watchdog_clock_started_at(running_entry) do
    last_event_at = watchdog_last_event_at(running_entry)

    case pending_tool_deadline(running_entry) do
      %DateTime{} = deadline when is_struct(last_event_at, DateTime) -> Enum.max([last_event_at, deadline], DateTime)
      _no_deadline -> last_event_at
    end
  end

  defp watchdog_last_event_at(running_entry) when is_map(running_entry) do
    (Map.get(running_entry, :last_event_at) ||
       Map.get(running_entry, :last_codex_timestamp) ||
       Map.get(running_entry, :started_at))
    |> after_linear_wait(running_entry)
  end

  defp watchdog_last_event_at(_running_entry), do: nil

  # A run waiting out a Linear rate limit or outage is neither stalled nor stuck: the stall
  # and no-progress clocks start again when its latest wait ends.
  defp after_linear_wait(%DateTime{} = timestamp, %{linear_wait_until: %DateTime{} = wait_until}) do
    if DateTime.after?(wait_until, timestamp), do: wait_until, else: timestamp
  end

  defp after_linear_wait(timestamp, _running_entry), do: timestamp

  defp put_pending_tool_call(running_entry, {:started, call_id, call}) do
    Map.update(running_entry, :pending_tool_calls, %{call_id => call}, &Map.put(&1, call_id, call))
  end

  # As for a workspace hook, a tool call's end counts as an event.
  defp put_pending_tool_call(running_entry, {:finished, call_id}) do
    running_entry
    |> Map.update(:pending_tool_calls, %{}, &Map.delete(&1, call_id))
    |> Map.put(:last_event_at, DateTime.utc_now())
  end

  defp oldest_pending_tool_call(%{pending_tool_calls: calls}) when map_size(calls) > 0 do
    calls |> Map.values() |> Enum.min_by(& &1.started_at, DateTime)
  end

  defp oldest_pending_tool_call(_running_entry), do: nil

  # The latest deadline of the run's pending tool calls. A call without one (a `qa_*` tool, which
  # keeps its driver's timeout) does not hold the watchdog.
  defp pending_tool_deadline(running_entry) do
    running_entry
    |> Map.get(:pending_tool_calls, %{})
    |> Map.values()
    |> Enum.map(& &1.deadline)
    |> Enum.filter(&is_struct(&1, DateTime))
    |> Enum.max(DateTime, fn -> nil end)
  end

  # The snapshot shows a run's oldest pending tool call once it has run for
  # `watchdog.pending_tool_report_after_ms` (a minute by default).
  defp pending_tool(running_entry, %DateTime{} = now, report_after_ms) do
    with %{name: name, started_at: started_at} <- oldest_pending_tool_call(running_entry),
         age_ms when age_ms >= report_after_ms <- DateTime.diff(now, started_at, :millisecond) do
      %{name: name, started_at: started_at, age_ms: age_ms}
    else
      _ -> nil
    end
  end

  defp pending_tool_for_log(running_entry, %DateTime{} = now) do
    case oldest_pending_tool_call(running_entry) do
      %{name: name, started_at: started_at} ->
        " pending_tool=#{name} pending_tool_age_ms=#{max(0, DateTime.diff(now, started_at, :millisecond))}"

      nil ->
        ""
    end
  end

  defp restart_stuck_issue(state, issue_id, running_entry, elapsed_ms) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)
    last_event_at = watchdog_last_event_at(running_entry)
    last_event_at_for_log = if is_struct(last_event_at, DateTime), do: DateTime.to_iso8601(last_event_at), else: "n/a"
    error = "stuck for #{elapsed_ms}ms without transcript activity"
    next_attempt = next_retry_attempt_from_running(running_entry)

    pending_tool = pending_tool_for_log(running_entry, DateTime.utc_now())

    Logger.warning(
      "Agent run stuck: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} last_event_at=#{last_event_at_for_log} elapsed_ms=#{elapsed_ms}#{pending_tool}; restarting with backoff"
    )

    emit_run_stuck(running_entry, elapsed_ms, next_attempt)

    state =
      terminate_running_issue(state, issue_id, false,
        status: "timeout",
        error: error,
        stop_agent_session: true,
        run_after_run_hook: true
      )

    if pr_run_entry?(running_entry) do
      state
    else
      schedule_issue_retry(state, issue_id, next_attempt, %{
        repo_key: running_entry_repo_key(running_entry),
        identifier: identifier,
        title: running_entry_title(running_entry),
        error: error,
        reason: :stuck,
        elapsed_ms: elapsed_ms,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp terminate_task(pid) when is_pid(pid) do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      supervisor when is_pid(supervisor) ->
        case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
          :ok ->
            :ok

          {:error, :not_found} ->
            Process.exit(pid, :shutdown)
        end

      nil ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp start_quality_gate_or_dispatch(issues, %State{} = state, context) when is_list(issues) do
    if quality_gate_task_in_flight?(state) do
      defer_quality_gate_request(state, context)
    else
      case Config.settings!().quality_gate do
        %SymphonyElixir.Config.Schema.QualityGate{enabled: true} = gate_config ->
          start_quality_gate_task(issues, state, context, gate_config)

        _disabled ->
          state
          |> Map.put(:quality_gate_skipped_errors, %{})
          |> start_dispatch_readiness(issues, context)
      end
    end
  end

  defp quality_gate_task_in_flight?(%State{quality_gate_tasks: tasks}) when is_map(tasks),
    do: map_size(tasks) > 0

  defp quality_gate_task_in_flight?(_state), do: false

  defp defer_quality_gate_request(%State{} = state, :poll) do
    Logger.debug("Deferring poll dispatch: quality gate task already in flight")
    finish_poll_cycle(state, System.monotonic_time(:millisecond))
  end

  defp defer_quality_gate_request(%State{} = state, {:active_retry, issue, attempt, metadata}) do
    Logger.debug("Deferring active retry dispatch: quality gate task already in flight for #{issue_context(issue)}")
    schedule_issue_retry(state, issue.id, attempt, deferred_retry_metadata(issue, metadata, "quality gate task already in flight; deferred"))
  end

  # `pop_retry_attempt_state/3` turns a continuation's `delay_type` into `continuation: true`, and
  # `schedule_issue_retry/4` reads only `delay_type`. Set it back, or the deferred retry waits the
  # failure backoff and a headroom hold sees a new run when it fires.
  defp deferred_retry_metadata(issue, metadata, error) do
    deferral = %{identifier: issue.identifier, title: issue.title, error: error}
    deferral = if metadata[:continuation] == true, do: Map.put(deferral, :delay_type, :continuation), else: deferral
    Map.merge(metadata, deferral)
  end

  defp start_quality_gate_task(issues, %State{} = state, context, gate_config) do
    cache = state.quality_gate_cache
    comment_keys = state.quality_gate_comment_keys
    issues = with_text_read(issues, state, context)

    case start_async_task(fn ->
           {:quality_gate_result, evaluate_quality_gate_with_comments(issues, gate_config, cache, comment_keys)}
         end) do
      {:ok, task} ->
        %{
          state
          | quality_gate_tasks: Map.put(state.quality_gate_tasks || %{}, task.ref, context)
        }

      {:error, reason} ->
        Logger.warning("Failed to start async quality gate task: #{inspect(reason)}")
        handle_quality_gate_exit(state, context, reason)
    end
  end

  # The gate scores a ticket's text, which only the poll reads. A poll candidate no repo's poll cache
  # has (one only the records have, `dispatch.source: record`) waits for its repo's poll, which a
  # change to its record asks for at once, instead of being scored on an empty description.
  defp with_text_read(issues, %State{} = state, :poll) do
    polled = for {_repo, entry} <- state.repo_poll_cache, %Issue{id: id} <- Map.get(entry, :issues, []), into: MapSet.new(), do: id
    {read, unread} = Enum.split_with(issues, &MapSet.member?(polled, &1.id))
    if unread != [], do: Logger.debug("Quality gate waits for the poll to read #{Enum.map_join(unread, ", ", &issue_context/1)}")
    read
  end

  defp with_text_read(issues, _state, _retry), do: issues

  defp evaluate_quality_gate_with_comments(issues, gate_config, cache, comment_keys) do
    %{passed: passed, skipped: skipped, awaiting_clarification: awaiting_clarification, cache: cache} =
      QualityGate.evaluate(issues, gate_config, cache)

    comment_keys = retain_quality_gate_comment_keys(comment_keys, issues)

    {cache, comment_keys, _awaiting_with_status} =
      post_quality_gate_clarification_comments(awaiting_clarification, gate_config, cache, comment_keys)

    {cache, comment_keys, skipped_with_status} =
      post_quality_gate_skip_comments(skipped, gate_config, cache, comment_keys)

    error_skips_index =
      skipped_with_status
      |> Enum.filter(&match?(%{kind: :error}, &1))
      |> Enum.reduce(%{}, fn entry, acc -> Map.put(acc, entry.issue_id, entry) end)

    %{
      passed: passed,
      cache: cache,
      comment_keys: comment_keys,
      error_skips_index: error_skips_index
    }
  end

  defp apply_quality_gate_evaluation_result(%State{} = state, %{
         cache: cache,
         comment_keys: comment_keys,
         error_skips_index: error_skips_index
       }) do
    persist_quality_gate_cache(cache)
    persist_quality_gate_comment_keys(comment_keys)

    %{
      state
      | quality_gate_cache: cache,
        quality_gate_comment_keys: comment_keys,
        quality_gate_skipped_errors: error_skips_index
    }
  end

  defp handle_quality_gate_result(%State{} = state, {:active_retry, issue, attempt, metadata}, %{passed: passed} = result)
       when is_list(passed) do
    state = apply_quality_gate_evaluation_result(state, result)

    if Enum.any?(passed, fn
         %Issue{id: id} -> id == issue.id
         _ -> false
       end) do
      start_dispatch_readiness(state, passed, {:active_retry, issue, attempt, metadata})
    else
      Logger.info("Skipping retry dispatch after quality gate rejected #{issue_context(issue)}")
      state = release_issue_claim(state, issue.id)
      notify_dashboard()
      state
    end
  end

  defp handle_quality_gate_result(%State{} = state, context, %{passed: passed} = result) when is_list(passed) do
    state
    |> apply_quality_gate_evaluation_result(result)
    |> start_dispatch_readiness(passed, context)
  end

  defp handle_quality_gate_result(%State{} = state, context, result) do
    Logger.warning("Ignoring invalid async quality gate result: #{inspect(result)}")
    handle_quality_gate_exit(state, context, {:invalid_result, result})
  end

  defp handle_quality_gate_exit(%State{} = state, :poll, reason) do
    Logger.warning("Skipping dispatch after quality gate task failure: #{inspect(reason)}")
    state = finish_poll_cycle(state, System.monotonic_time(:millisecond))
    notify_dashboard()
    state
  end

  # Task crash is not a quality gate rejection: keep the claim and schedule a
  # retry, mirroring handle_dispatch_readiness_exit/3 so poll and retry cannot
  # race to re-dispatch the same issue while the timer is still pending.
  defp handle_quality_gate_exit(%State{} = state, {:active_retry, issue, attempt, metadata}, reason) do
    Logger.warning("Skipping retry dispatch after quality gate task failure #{issue_context(issue)} reason=#{inspect(reason)}")

    state =
      schedule_issue_retry(
        state,
        issue.id,
        attempt,
        Map.merge(metadata, %{
          identifier: issue.identifier,
          title: issue.title,
          error: "quality gate task failed: #{inspect(reason)}"
        })
      )

    notify_dashboard()
    state
  end

  defp post_quality_gate_clarification_comments(awaiting, gate_config, cache, comment_keys) do
    Enum.reduce(awaiting, {cache, comment_keys, []}, fn entry, {cache_acc, keys_acc, entries} ->
      case post_quality_gate_comment_if_needed(entry, gate_config, cache_acc, keys_acc) do
        {:posted, updated_cache, updated_keys} ->
          {updated_cache, updated_keys, [%{entry | comment_posted?: true} | entries]}

        {:skipped_post, cache_next, keys_next} ->
          entry = %{entry | comment_posted?: entry.comment_posted? or MapSet.member?(keys_next, quality_gate_comment_key(entry))}
          {cache_next, keys_next, [entry | entries]}
      end
    end)
    |> then(fn {cache_acc, keys_acc, entries_rev} -> {cache_acc, keys_acc, Enum.reverse(entries_rev)} end)
  end

  defp post_quality_gate_skip_comments(skipped, gate_config, cache, comment_keys) do
    Enum.reduce(skipped, {cache, comment_keys, []}, fn entry, {cache_acc, keys_acc, entries} ->
      case post_quality_gate_comment_if_needed(entry, gate_config, cache_acc, keys_acc) do
        {:posted, updated_cache, updated_keys} ->
          {updated_cache, updated_keys, [%{entry | comment_posted?: true} | entries]}

        {:skipped_post, cache_next, keys_next} ->
          entry = %{entry | comment_posted?: entry.comment_posted? or MapSet.member?(keys_next, quality_gate_comment_key(entry))}
          {cache_next, keys_next, [entry | entries]}
      end
    end)
    |> then(fn {cache_acc, keys_acc, entries_rev} -> {cache_acc, keys_acc, Enum.reverse(entries_rev)} end)
  end

  defp post_quality_gate_comment_if_needed(%{comment_posted?: true}, _config, cache, comment_keys),
    do: {:skipped_post, cache, comment_keys}

  defp post_quality_gate_comment_if_needed(entry, gate_config, cache, comment_keys) do
    body = quality_gate_comment_body(entry, gate_config)
    comment_key = quality_gate_comment_key(entry)

    if MapSet.member?(comment_keys, comment_key) do
      {:skipped_post, cache, comment_keys}
    else
      case Tracker.create_comment(entry.issue_id, body) do
        :ok ->
          {:posted, QualityGate.mark_comment_posted(cache, entry, DateTime.utc_now()), MapSet.put(comment_keys, comment_key)}

        {:error, reason} ->
          Logger.warning("QualityGate #{quality_gate_comment_kind(entry)} post failed issue=#{entry.identifier || entry.issue_id} reason=#{inspect(reason)}")

          {:skipped_post, cache, comment_keys}
      end
    end
  end

  defp quality_gate_comment_body(%{kind: :clarification} = entry, gate_config),
    do: QualityGate.clarification_comment_body(entry, gate_config)

  defp quality_gate_comment_body(entry, gate_config), do: QualityGate.skip_comment_body(entry, gate_config)

  defp quality_gate_comment_kind(%{kind: :clarification}), do: "clarification-comment"
  defp quality_gate_comment_kind(_entry), do: "skip-comment"

  defp quality_gate_comment_key(entry) do
    updated_at =
      case Map.get(entry, :updated_at) do
        %DateTime{} = value -> DateTime.to_iso8601(value)
        value when is_binary(value) -> value
        _ -> "unknown"
      end

    kind =
      case entry.kind do
        :scored -> "score"
        :error -> "error"
        :clarification -> "clarification"
      end

    comment_signature = Map.get(entry, :comment_signature) || "none"

    "#{entry.issue_id}:#{updated_at}:#{comment_signature}:#{kind}"
  end

  defp retain_quality_gate_comment_keys(comment_keys, issues) when is_struct(comment_keys, MapSet) and is_list(issues) do
    active_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: id} when is_binary(id) -> [id]
        _ -> []
      end)
      |> MapSet.new()

    comment_keys
    |> Enum.filter(fn key ->
      [issue_id | _rest] = String.split(key, ":", parts: 2)
      MapSet.member?(active_ids, issue_id)
    end)
    |> MapSet.new()
  end

  defp retain_quality_gate_comment_keys(_comment_keys, _issues), do: MapSet.new()

  defp reject_running_quality_gate_candidates(issues, %State{running: running})
       when is_list(issues) and is_map(running) do
    running_ids = running |> Map.keys() |> MapSet.new()

    Enum.reject(issues, fn
      %Issue{id: issue_id} when is_binary(issue_id) -> MapSet.member?(running_ids, issue_id)
      _issue -> false
    end)
  end

  defp reject_running_quality_gate_candidates(issues, _state), do: issues

  defp prune_quality_gate_cache_to_active(%State{quality_gate_cache: cache} = state, issues)
       when is_list(issues) do
    pruned = QualityGate.retain_active_issues(cache, issues)

    if map_size(pruned) == map_size(cache) do
      state
    else
      persist_quality_gate_cache(pruned)
      %{state | quality_gate_cache: pruned}
    end
  end

  defp clear_running_quality_gate_cache_entries(%State{running: running} = state)
       when is_map(running) do
    clear_quality_gate_blocking_cache_entries(state, Map.keys(running))
  end

  defp clear_running_quality_gate_cache_entries(state), do: state

  defp clear_quality_gate_blocking_cache_entry(%State{} = state, issue_id) when is_binary(issue_id) do
    clear_quality_gate_blocking_cache_entries(state, [issue_id])
  end

  defp clear_quality_gate_blocking_cache_entries(%State{quality_gate_cache: cache} = state, issue_ids)
       when is_map(cache) and is_list(issue_ids) do
    {cache, changed?} =
      Enum.reduce(issue_ids, {cache, false}, fn issue_id, {cache_acc, changed?} ->
        if quality_gate_blocking_cache_entry?(Map.get(cache_acc, issue_id)) do
          {Map.delete(cache_acc, issue_id), true}
        else
          {cache_acc, changed?}
        end
      end)

    quality_gate_skipped_errors =
      case state.quality_gate_skipped_errors do
        skipped_errors when is_map(skipped_errors) -> Map.drop(skipped_errors, issue_ids)
        _skipped_errors -> %{}
      end

    state = %{state | quality_gate_skipped_errors: quality_gate_skipped_errors}

    if changed? do
      persist_quality_gate_cache(cache)
      %{state | quality_gate_cache: cache}
    else
      state
    end
  end

  defp clear_quality_gate_blocking_cache_entries(state, _issue_ids), do: state

  defp quality_gate_blocking_cache_entry?(%{passed?: false}), do: true
  defp quality_gate_blocking_cache_entry?(_entry), do: false

  defp quality_gate_snapshot_cache(%State{quality_gate_cache: cache, running: running})
       when is_map(cache) and is_map(running) do
    running_ids = running |> Map.keys() |> MapSet.new()

    cache
    |> Enum.reject(fn {issue_id, _entry} -> MapSet.member?(running_ids, issue_id) end)
    |> Map.new()
  end

  defp quality_gate_snapshot_cache(%State{quality_gate_cache: cache}) when is_map(cache), do: cache
  defp quality_gate_snapshot_cache(_state), do: %{}

  defp quality_gate_snapshot_skipped_errors(%State{quality_gate_skipped_errors: skipped_errors, running: running})
       when is_map(skipped_errors) and is_map(running) do
    Map.drop(skipped_errors, Map.keys(running))
  end

  defp quality_gate_snapshot_skipped_errors(%State{quality_gate_skipped_errors: skipped_errors})
       when is_map(skipped_errors),
       do: skipped_errors

  defp quality_gate_snapshot_skipped_errors(_state), do: %{}

  defp snapshot_awaiting_clarification_entry(entry) do
    %{
      kind: entry.kind,
      issue_id: entry.issue_id,
      repo_key: Map.get(entry, :repo_key),
      identifier: entry.identifier,
      title: Map.get(entry, :title),
      url: URLUtils.present_url(entry.url),
      state: Map.get(entry, :state),
      score: Map.get(entry, :score),
      reason: Map.get(entry, :reason),
      rounds_asked: Map.get(entry, :rounds_asked, 0),
      max_rounds: Map.get(entry, :max_rounds),
      pass_threshold: Map.get(entry, :pass_threshold),
      questions: Map.get(entry, :questions, []),
      scored_at: Map.get(entry, :scored_at),
      updated_at: Map.get(entry, :updated_at)
    }
  end

  defp snapshot_skipped_entry(entry) do
    %{
      kind: entry.kind,
      issue_id: entry.issue_id,
      repo_key: Map.get(entry, :repo_key),
      identifier: entry.identifier,
      title: Map.get(entry, :title),
      url: URLUtils.present_url(entry.url),
      state: Map.get(entry, :state),
      score: Map.get(entry, :score),
      reason: Map.get(entry, :reason),
      error: Map.get(entry, :error),
      rounds_asked: Map.get(entry, :rounds_asked),
      max_rounds: Map.get(entry, :max_rounds),
      pass_threshold: Map.get(entry, :pass_threshold),
      scored_at: Map.get(entry, :scored_at),
      updated_at: Map.get(entry, :updated_at)
    }
  end

  defp start_dispatch_readiness(%State{} = state, issues, context) when is_list(issues) do
    if dispatch_readiness_task_in_flight?(state) do
      defer_dispatch_readiness_request(state, context)
    else
      do_start_dispatch_readiness(state, issues, context)
    end
  end

  defp dispatch_readiness_task_in_flight?(%State{dispatch_readiness_tasks: tasks}) when is_map(tasks),
    do: map_size(tasks) > 0

  defp dispatch_readiness_task_in_flight?(_state), do: false

  defp defer_dispatch_readiness_request(%State{} = state, :poll) do
    Logger.debug("Deferring poll dispatch: dispatch readiness task already in flight")
    finish_poll_cycle(state, System.monotonic_time(:millisecond))
  end

  # A continuation stays a retry so its continuation flag reaches the headroom check; waiting for
  # a slot would send it back through candidate selection, where a headroom hold sees a new run.
  defp defer_dispatch_readiness_request(%State{} = state, {:active_retry, issue, attempt, %{continuation: true} = metadata}) do
    Logger.debug("Deferring continuation retry dispatch: dispatch readiness task already in flight for #{issue_context(issue)}")
    schedule_issue_retry(state, issue.id, attempt, deferred_retry_metadata(issue, metadata, "dispatch readiness task already in flight; deferred"))
  end

  defp defer_dispatch_readiness_request(%State{} = state, {:active_retry, issue, attempt, metadata}) do
    Logger.debug("Deferring active retry dispatch: dispatch readiness task already in flight for #{issue_context(issue)}")
    wait_for_slot(state, issue, attempt, metadata, "dispatch readiness task already in flight")
  end

  defp do_start_dispatch_readiness(%State{} = state, issues, context) do
    now_ms = System.monotonic_time(:millisecond)
    state = reset_daily_budget_if_needed(state)

    task_input = %{
      repo_keys: configured_repo_keys(state.repo_key),
      active_workspace_identifiers_by_repo: active_workspace_identifiers_by_repo(state),
      run_age_gc?: workspace_age_gc_due?(state, now_ms),
      dispatch_refresh_ids: dispatch_refresh_ids(state, issues, context),
      now_ms: now_ms
    }

    case start_async_task(fn ->
           {:dispatch_readiness_result, run_dispatch_readiness_checks(task_input)}
         end) do
      {:ok, task} ->
        task_context = %{kind: context, issues: issues}
        %{state | dispatch_readiness_tasks: Map.put(state.dispatch_readiness_tasks || %{}, task.ref, task_context)}

      {:error, reason} ->
        Logger.warning("Failed to start async dispatch readiness task: #{inspect(reason)}")
        handle_dispatch_readiness_exit(state, %{kind: context, issues: issues}, reason)
    end
  end

  # The issues dispatch may start are read from Linear here, in the readiness task, rather than one
  # by one in `dispatch_issue/4`, which runs inside the orchestrator's callback. A poll reads only
  # the candidates whose dispatch gates are open now; a retry reads its own issue. Under
  # `dispatch.source: record` nothing is read: the revalidation reads each issue's record.
  defp dispatch_refresh_ids(%State{} = state, issues, context) do
    case dispatch_source_in_use() do
      :record -> []
      :poll -> poll_dispatch_refresh_ids(state, issues, context)
    end
  end

  defp poll_dispatch_refresh_ids(_state, _issues, {:active_retry, %Issue{id: issue_id}, _attempt, _metadata}), do: [issue_id]

  defp poll_dispatch_refresh_ids(%State{} = state, issues, :poll) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    for %Issue{id: issue_id} = issue <- issues,
        is_binary(issue_id),
        dispatch_gates_open?(issue, state, active_states, terminal_states),
        do: issue_id
  end

  defp run_dispatch_readiness_checks(%{
         repo_keys: repo_keys,
         active_workspace_identifiers_by_repo: active_identifiers_by_repo,
         run_age_gc?: run_age_gc?,
         dispatch_refresh_ids: dispatch_refresh_ids,
         now_ms: now_ms
       }) do
    %{
      now_ms: now_ms,
      dispatch_refresh: prefetch_dispatch_issues(dispatch_refresh_ids),
      age_gc_result:
        if(run_age_gc?,
          do: {:ran, workspace_age_gc_result(repo_keys, active_identifiers_by_repo)},
          else: :skipped
        ),
      quota: workspace_quota_status_from_config()
    }
  end

  defp prefetch_dispatch_issues([]), do: nil
  defp prefetch_dispatch_issues(issue_ids), do: %{ids: MapSet.new(issue_ids), result: fetch_observed_issues_by_ids(issue_ids)}

  defp handle_dispatch_readiness_result(%State{} = state, %{kind: context, issues: issues}, result) do
    state =
      state
      |> apply_dispatch_readiness_result(result)
      |> continue_after_dispatch_readiness(context, issues)
      |> Map.put(:dispatch_refresh, nil)

    notify_dashboard()
    state
  end

  defp handle_dispatch_readiness_exit(%State{} = state, %{kind: :poll}, reason) do
    Logger.warning("Skipping dispatch after readiness task failure: #{inspect(reason)}")
    state = finish_poll_cycle(state, System.monotonic_time(:millisecond))
    notify_dashboard()
    state
  end

  defp handle_dispatch_readiness_exit(%State{} = state, %{kind: {:active_retry, issue, attempt, metadata}}, reason) do
    Logger.warning("Retry dispatch readiness failed for #{issue_context(issue)} reason=#{inspect(reason)}")

    state =
      schedule_issue_retry(state, issue.id, attempt, Map.merge(metadata, %{identifier: issue.identifier, title: issue.title, error: "dispatch readiness failed: #{inspect(reason)}"}))

    notify_dashboard()
    state
  end

  defp apply_dispatch_readiness_result(%State{} = state, %{now_ms: now_ms, age_gc_result: age_gc_result, quota: quota} = result) do
    %{state | dispatch_refresh: Map.get(result, :dispatch_refresh)}
    |> apply_workspace_age_gc_result(age_gc_result, now_ms)
    |> apply_workspace_quota_result(quota)
  end

  defp apply_dispatch_readiness_result(%State{} = state, result) do
    Logger.warning("Ignoring invalid dispatch readiness result: #{inspect(result)}")
    state
  end

  defp continue_after_dispatch_readiness(%State{} = state, :poll, issues) do
    state =
      issues
      |> park_breakdown_parents(state)
      |> then(&review_breakdown_parents(issues, &1))
      |> close_finished_parents(issues)
      |> act_on_plan_comments(issues)

    state =
      cond do
        operator_paused?(state) ->
          state |> log_operator_pause() |> skip_paused_pass(issues, "dispatch is paused by the operator")

        workspace_quota_paused?(state) ->
          state |> log_workspace_quota_pause() |> skip_paused_pass(issues, "new dispatch is paused: #{workspace_quota_error(state)}")

        daily_budget_paused?(state) ->
          state
          |> log_daily_budget_pause()
          |> skip_paused_pass(issues, "the daily token budget is spent (agent.max_tokens_per_day)")
          |> dispatch_forced_over_daily_budget(issues)

        true ->
          dispatch_chosen_issues(issues, state)
      end

    finish_poll_cycle(state, System.monotonic_time(:millisecond))
  end

  defp continue_after_dispatch_readiness(%State{} = state, {:active_retry, issue, attempt, metadata}, _issues) do
    handle_active_retry_after_readiness(state, issue, attempt, metadata)
  end

  # A `breakdown` parent left `In Progress` with open sub-issues moves to the waiting state, so
  # `In Progress` only holds issues an agent is working. Candidates come from the repo poll cache,
  # so a parent stays in `parked_parents` until the cache stops showing it `In Progress`. The cache
  # can still show `In Progress` for a parent whose breakdown run just moved it to `Plan Review`, so
  # each one is read again first: moving it on from `Plan Review` would read as approving its plan.
  # The reads and moves run in a task; the parents it parks join `parked_parents` when it answers.
  defp park_breakdown_parents(issues, %State{} = state) do
    settings = Config.settings!()
    terminal_states = terminal_state_set()
    parkable = Enum.filter(issues, &SubIssueWait.park?(&1, terminal_states, settings))
    state = %{state | parked_parents: MapSet.intersection(state.parked_parents, MapSet.new(parkable, & &1.id))}

    case Enum.reject(parkable, &(MapSet.member?(state.parked_parents, &1.id) or parent_busy?(state, :park_parents, &1.id))) do
      [] ->
        state

      candidates ->
        waiting_state = SubIssueWait.state(settings)

        start_tracker_task(state, %{kind: :park_parents, issue_ids: Enum.map(candidates, & &1.id)}, fn ->
          {:ok, candidates |> still_parkable() |> Enum.filter(&park_breakdown_parent(&1, waiting_state, settings)) |> Enum.map(& &1.id)}
        end)
    end
  end

  defp parent_busy?(%State{} = state, kind, issue_id),
    do: issue_claimed_or_running?(state, issue_id) or tracker_task_in_flight?(state, kind, issue_id)

  defp still_parkable(issues) do
    case Tracker.fetch_issue_states_by_ids(Enum.map(issues, & &1.id)) do
      {:ok, fresh_issues} ->
        in_progress = for %Issue{id: id} = fresh <- fresh_issues, SubIssueWait.parked_from?(fresh), into: MapSet.new(), do: id
        Enum.filter(issues, &MapSet.member?(in_progress, &1.id))

      {:error, reason} ->
        Logger.warning("Failed to refresh breakdown parents before parking; retrying next poll reason=#{inspect(reason)}")
        []
    end
  end

  # An issue that waits on its sub-issues after its PR merged (not a `breakdown` parent) moves to
  # Done once every sub-issue is terminal; its PR is merged, so no run is needed. Candidates come
  # from the repo poll cache, so each one is read again first: a sub-issue filed meanwhile keeps it
  # waiting, and a person may have moved it on.
  defp close_finished_parents(%State{} = state, issues) do
    settings = Config.settings!()
    terminal_states = terminal_state_set()

    closeable? = &(SubIssueWait.close?(&1, terminal_states, settings) and not parent_busy?(state, :close_parents, &1.id))

    case Enum.filter(issues, closeable?) do
      [] ->
        state

      closeable ->
        issue_ids = Enum.map(closeable, & &1.id)
        close = fn -> close_finished_parents_fresh(issue_ids, terminal_states, settings) end
        start_tracker_task(state, %{kind: :close_parents, issue_ids: issue_ids}, close)
    end
  end

  defp close_finished_parents_fresh(issue_ids, terminal_states, settings) do
    case Tracker.fetch_issue_states_by_ids(issue_ids) do
      {:ok, fresh_issues} ->
        for %Issue{} = issue <- fresh_issues, SubIssueWait.close?(issue, terminal_states, settings), do: close_finished_parent(issue)

      {:error, reason} ->
        Logger.warning("Failed to refresh issues waiting on sub-issues before closing them; retrying next poll reason=#{inspect(reason)}")
    end
  end

  defp close_finished_parent(%Issue{} = issue) do
    case SubIssueWait.close(issue, Tracker.adapter()) do
      :ok ->
        record_ticket_signal(issue, "merge settled", %{sub_issues: length(issue.sub_issues)})

      {:error, reason} ->
        Logger.warning("Failed to move an issue whose sub-issues are finished to Done; retrying next poll: #{issue_context(issue)} reason=#{inspect(reason)}")
    end
  end

  # A human's review of a `breakdown` parent's plan: approving it (Plan Review to the waiting state)
  # promotes its Backlog sub-issues to Todo, rejecting it (Rework) cancels them before the re-plan.
  # `breakdown_reviews` maps each parent to the Backlog sub-issues last acted on, so a re-poll
  # showing the same ones does not ask Linear again; a parent that needs nothing is dropped.
  defp review_breakdown_parents(issues, %State{} = state, opts \\ []) do
    settings = Config.settings!()

    pending =
      Enum.flat_map(issues, fn issue ->
        case BreakdownReview.action(issue, settings) do
          nil -> []
          action -> [{issue, action, issue.id}]
        end
      end)

    state = %{state | breakdown_reviews: Map.take(state.breakdown_reviews, Enum.map(pending, &elem(&1, 2)))}
    run_store = Keyword.get(opts, :run_store, RunStore)

    Enum.reduce(pending, state, fn {issue, action, issue_id}, state ->
      backlog = BreakdownReview.backlog_sub_issue_ids(issue)

      if parent_busy?(state, :breakdown_review, issue_id) or Map.get(state.breakdown_reviews, issue_id) == backlog,
        do: state,
        else: start_breakdown_review(state, issue, action, backlog, settings, run_store)
    end)
  end

  # Until the review answers, the parent counts as not reviewed, so a re-plan waits for it.
  defp start_breakdown_review(%State{} = state, %Issue{id: issue_id} = issue, action, backlog, settings, run_store) do
    review = fn -> {:ok, review_breakdown_parent(issue, action, settings, run_store)} end

    %{state | breakdown_reviews: Map.delete(state.breakdown_reviews, issue_id)}
    |> start_tracker_task(%{kind: :breakdown_review, issue_ids: [issue_id], backlog: backlog}, review)
  end

  defp finish_breakdown_review(%State{} = state, %{issue_ids: [issue_id], backlog: backlog}, {:ok, true}),
    do: %{state | breakdown_reviews: Map.put(state.breakdown_reviews, issue_id, backlog)}

  defp finish_breakdown_review(%State{} = state, _context, _failed), do: state

  defp review_breakdown_parent(%Issue{id: issue_id} = issue, action, settings, run_store) do
    case Tracker.fetch_breakdown_history(issue_id) do
      {:ok, history} ->
        review_breakdown_history(issue, action, history, settings, run_store)

      {:error, reason} ->
        Logger.warning("Failed to read breakdown parent history: #{issue_context(issue)} reason=#{inspect(reason)}")
        false
    end
  end

  # When Symphony last moved the parent itself, so its own move is not read as a person's approval.
  # Without that record nothing is moved; the next poll tries again.
  defp review_breakdown_history(%Issue{id: issue_id} = issue, action, history, settings, run_store) do
    case run_store.get_own_state_move(issue_id) do
      {:error, reason} ->
        Logger.warning("Failed to read Symphony's own moves of breakdown parent: #{issue_context(issue)} reason=#{inspect(reason)}")
        false

      own_move_at ->
        action
        |> BreakdownReview.sub_issues_to_move(history, settings, own_move_at)
        |> Enum.map(&move_breakdown_sub_issue(issue, action, &1))
        |> log_breakdown_review(issue, action)
    end
  end

  defp move_breakdown_sub_issue(issue, action, %{id: sub_issue_id, identifier: identifier}) do
    case BreakdownReview.move(action, sub_issue_id, Tracker.adapter(), %{repo_key: issue_repo_key(issue)}) do
      {:ok, state} ->
        record_breakdown_sub_issue_signal(issue, action, sub_issue_id, identifier, state)
        {:ok, identifier}

      {:error, reason} ->
        Logger.warning("Failed to move sub-issue #{identifier} of breakdown parent to #{BreakdownReview.target(action)}: #{issue_context(issue)} reason=#{inspect(reason)}")
        :error
    end
  end

  # A promoted sub-issue carries the plan's approval; a replaced one is the plan's changes, which
  # cancel the sub-issues it judged. `state` is the one the move entered, the team's own spelling.
  defp record_breakdown_sub_issue_signal(issue, action, sub_issue_id, identifier, state) do
    case issue_repo_key(issue) do
      repo_key when is_binary(repo_key) ->
        details = %{outcome: breakdown_sub_issue_outcome(action), sub_issue: identifier, to: state}
        record_ticket_signal(repo_key, sub_issue_id, breakdown_sub_issue_signal(action), details)

      _repo_key ->
        :ok
    end
  end

  defp breakdown_sub_issue_signal(:promote), do: "plan verdict"
  defp breakdown_sub_issue_signal(_action), do: "deprioritized"

  defp breakdown_sub_issue_outcome(:promote), do: "approve"
  defp breakdown_sub_issue_outcome(_action), do: "changes"

  defp log_breakdown_review([], _issue, _action), do: true

  defp log_breakdown_review(results, issue, action) do
    moved = for {:ok, identifier} <- results, do: identifier

    if moved != [] do
      Logger.info("Moved #{length(moved)} sub-issue(s) of breakdown parent to #{BreakdownReview.target(action)} (#{Enum.join(moved, ", ")}): #{issue_context(issue)}")
      comment_breakdown_review(issue, action, moved)
    end

    length(moved) == length(results)
  end

  # One comment per batch records on the parent what Symphony changed, for the reviewer.
  defp comment_breakdown_review(%Issue{id: issue_id} = issue, action, moved) do
    case Tracker.create_comment(issue_id, BreakdownReview.comment(action, moved)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to comment on breakdown parent: #{issue_context(issue)} reason=#{inspect(reason)}")
    end
  end

  # A person's new comment on a `breakdown` parent's plan (see `PlanComments`): a plan under review
  # goes to `Rework`, where the plan is revised in place, and an approved plan gets a reply. Parents
  # waiting for review come from the watching refresh (which watches `Plan Review` like any
  # non-active state), approved ones from the candidates.
  # `plan_comment_checks` keeps the newest comment each parent's poll showed once it was acted on,
  # so Linear is read again only when a newer comment shows up. `plan_comments_since` is when this
  # orchestrator started: comments on an approved plan from before it get no reply.
  defp act_on_plan_comments(%State{} = state, issues) do
    settings = Config.settings!()
    terminal_states = terminal_state_set()

    Enum.reduce(issues, state, fn issue, state ->
      with action when not is_nil(action) <- PlanComments.action(issue, terminal_states, settings),
           false <- parent_busy?(state, :plan_comments, issue.id),
           %DateTime{} = newest <- newest_comment_at(issue),
           true <- newer_comment?(newest, Map.get(state.plan_comment_checks, issue.id)) do
        start_plan_comments_read(state, issue, action, newest)
      else
        _skip -> state
      end
    end)
  end

  defp start_plan_comments_read(%State{} = state, %Issue{id: issue_id} = issue, action, newest) do
    last_run = last_run(state, issue_id)
    started_at = state.plan_comments_since
    read = fn -> {:ok, read_plan_comments(issue, action, last_run, started_at)} end
    start_tracker_task(state, %{kind: :plan_comments, issue_ids: [issue_id], newest: newest}, read)
  end

  defp finish_plan_comments(%State{} = state, %{issue_ids: [issue_id], newest: newest}, {:ok, true}),
    do: %{state | plan_comment_checks: Map.put(state.plan_comment_checks, issue_id, newest)}

  defp finish_plan_comments(%State{} = state, _context, _failed), do: state

  defp read_plan_comments(%Issue{id: issue_id} = issue, action, last_run, started_at) do
    case Tracker.fetch_plan_comments(issue_id) do
      {:ok, feedback} ->
        pending = PlanComments.pending(action, feedback, issue.state, last_run, started_at)
        log_plan_comments_read(issue, action, feedback, pending, last_run, started_at)
        act_on_pending_plan_comments(issue, action, pending)

      {:error, reason} ->
        Logger.warning("Failed to read comments on breakdown parent: #{issue_context(issue)} reason=#{inspect(reason)}")
        false
    end
  end

  # Each read says what it saw, so a person's comment the poll passed over can be traced: an empty
  # read caches the newest comment, and the parent is not read again until a newer one shows up.
  defp log_plan_comments_read(issue, action, feedback, pending, last_run, started_at) do
    since = PlanComments.since(action, feedback, issue.state, last_run, started_at)
    owned = last_run |> Kernel.||(%{}) |> Map.get(:comment_ids) |> List.wrap() |> length()

    Logger.debug(
      "Read breakdown parent's plan comments: #{issue_context(issue)} action=#{action} comments=#{length(feedback.comments)} " <>
        "pending=#{length(pending)} owned=#{owned} since=#{inspect(since)}"
    )
  end

  defp act_on_pending_plan_comments(_issue, _action, []), do: true

  defp act_on_pending_plan_comments(%Issue{id: issue_id} = issue, :revise, comments) do
    # The move is recorded before it is made, so a review reading the parent's history never sees it
    # without the record that marks it as Symphony's own. The parent goes to `Rework` to be revised
    # in place, and that record is what keeps `BreakdownReview` from reading
    # the move as the person's rejection of the plan — which is what cancels its sub-issues.
    _ = issue_id |> RunStore.put_own_state_move(DateTime.utc_now()) |> log_run_store_error("record breakdown parent move")

    ctx = %{repo_key: issue_repo_key(issue)}
    to_state = TransitionGuard.target(:plan_revise, ctx)

    case TransitionGuard.perform(issue_id, :plan_revise, ctx) do
      :ok ->
        record_ticket_signal(issue, "plan verdict", %{outcome: "changes", to: to_state})
        Logger.info("Moved breakdown parent to #{to_state} to revise its plan from #{length(comments)} new comment(s): #{issue_context(issue)}")
        true

      {:error, reason} ->
        Logger.warning("Failed to move breakdown parent to #{to_state} for its plan's comments: #{issue_context(issue)} reason=#{inspect(reason)}")
        false
    end
  end

  defp act_on_pending_plan_comments(%Issue{id: issue_id} = issue, :answer, comments) do
    comments
    |> Enum.map(&PlanComments.thread_id/1)
    |> Enum.uniq()
    |> Enum.map(fn thread_id ->
      case Tracker.create_reply(issue_id, thread_id, PlanComments.reply(issue.identifier)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to reply to a comment on an approved breakdown plan: #{issue_context(issue)} comment_id=#{thread_id} reason=#{inspect(reason)}")
          :error
      end
    end)
    |> Enum.all?(&(&1 == :ok))
  end

  defp newest_comment_at(%Issue{comments: comments}) when is_list(comments) do
    comments
    |> Enum.flat_map(fn
      %{created_at: %DateTime{} = at} -> [at]
      _comment -> []
    end)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp newest_comment_at(_issue), do: nil

  defp newer_comment?(_newest, nil), do: true
  defp newer_comment?(newest, checked), do: DateTime.compare(newest, checked) == :gt

  defp last_run(%State{completed_run_metadata: metadata}, issue_id) do
    case Map.get(metadata, issue_id) do
      %{} = run -> %{started_at: Map.get(run, :started_at), ended_at: Map.get(run, :last_ran_at), comment_ids: Map.get(run, :comment_ids)}
      _unknown -> nil
    end
  end

  # A rejected plan is made again only once its Backlog sub-issues are cancelled, so the re-plan
  # does not duplicate them.
  defp replan_pending?(%Issue{id: issue_id} = issue, %State{breakdown_reviews: reviews}) do
    BreakdownReview.action(issue, Config.settings!()) == :replace and not Map.has_key?(reviews, issue_id)
  end

  # A landing run that ended on pending checks stays held in `Merging` until the CI poller sees
  # that head go green, or every check its base branch requires pass (`CiPoller.landing_action/1`),
  # the issue leaves `Merging` (a red head takes the CI-failure path), or
  # `ci.merging_wait_timeout_ms` passes. Releasing it lets this poll dispatch the landing agent.
  defp release_merging_ci_waits(%State{merging_ci_waits: waits} = state, _issues) when map_size(waits) == 0, do: state

  defp release_merging_ci_waits(%State{} = state, issues) do
    issues_by_id = Map.new(issues, &{&1.id, &1})
    now = DateTime.utc_now()
    timeout_ms = Config.settings!().ci.merging_wait_timeout_ms

    waits =
      Map.filter(state.merging_ci_waits, fn {issue_id, wait} ->
        case merging_ci_wait_release(Map.get(issues_by_id, issue_id), issue_id, wait, now, timeout_ms) do
          nil ->
            true

          reason ->
            Logger.info("Releasing Merging CI hold: issue_id=#{issue_id} issue_identifier=#{wait.identifier} commit_sha=#{wait.commit_sha} reason=#{reason}")
            false
        end
      end)

    %{state | merging_ci_waits: waits}
  end

  defp merging_ci_wait_release(issue, issue_id, wait, now, timeout_ms) do
    cond do
      not match?(%Issue{}, issue) or not merging_state?(issue.state) -> "left Merging"
      DateTime.diff(now, wait.since, :millisecond) >= timeout_ms -> "timed out after #{timeout_ms}ms"
      merging_ci_head_green?(issue_id, wait) -> "CI green"
      true -> nil
    end
  end

  defp merging_ci_head_green?(issue_id, wait) do
    opts = if is_binary(wait.repo_key), do: [repo_key: wait.repo_key], else: []

    case CiPoller.observed_head(issue_id, opts) do
      %{commit_sha: commit_sha, conclusion: "SUCCESS"} -> commit_sha == wait.commit_sha
      _observed -> is_binary(wait.commit_sha) and CiPoller.landing_ready_head(issue_id, opts) == wait.commit_sha
    end
  end

  defp issue_claimed_or_running?(%State{} = state, issue_id) do
    MapSet.member?(state.claimed, issue_id) or Map.has_key?(state.running, issue_id)
  end

  # The move is recorded before it is made, so a review reading the parent's history never sees
  # it without the record that marks it as Symphony's.
  defp park_breakdown_parent(%Issue{id: issue_id} = issue, waiting_state, settings) do
    issue_id |> RunStore.put_own_state_move(DateTime.utc_now()) |> log_run_store_error("record breakdown parent move")

    case TransitionGuard.perform(issue_id, :plan_approve, %{settings: settings, repo_key: issue_repo_key(issue)}) do
      :ok ->
        record_ticket_signal(issue, "plan verdict", %{outcome: "approve", to: waiting_state})
        Logger.info("Moved breakdown parent to #{waiting_state} while its sub-issues are open: #{issue_context(issue)}")
        true

      {:error, reason} ->
        Logger.warning("Failed to move breakdown parent to #{waiting_state}: #{issue_context(issue)} reason=#{inspect(reason)}")
        false
    end
  end

  # Candidates go out forced first, then closest-to-done, each epic lane's tickets nearest the epic
  # first. Once a Merging issue is left waiting for a slot, no Todo issue starts in this pass,
  # except on the forced allowance; its `slot_waiting` reason names the issue it waits for.
  # `slot_waiting` is rebuilt from the pass,
  # keeping the attempt of any retry that was waiting for a slot; with `keep_waiting: true` the
  # entries of issues outside this pass stay as they were. `dispatch_skipped` is rebuilt the same
  # way: every candidate the pass neither starts nor leaves waiting for a slot gets the reason.
  defp dispatch_chosen_issues(issues, state, opts \\ []) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    previous_waiting = state.slot_waiting || %{}
    previous_skipped = state.dispatch_skipped || %{}
    pass_ids = for %Issue{id: issue_id} <- issues, do: issue_id

    {slot_waiting, dispatch_skipped} =
      if Keyword.get(opts, :keep_waiting, false),
        do: {Map.drop(previous_waiting, pass_ids), Map.drop(previous_skipped, pass_ids)},
        else: {%{}, %{}}

    {state, _hold} =
      issues
      |> sort_issues_for_dispatch()
      |> then(&EpicLanes.order(state.epic_lanes, &1, fn issue -> stage_rank(issue.state) end))
      |> forced_first(state)
      |> Enum.reduce({%{state | slot_waiting: slot_waiting, dispatch_skipped: dispatch_skipped}, nil}, fn issue, acc ->
        maybe_dispatch_chosen_issue(issue, acc, previous_waiting, active_states, terminal_states)
      end)

    state
    |> settle_dispatch_skipped(previous_skipped)
    |> recover_usage_limit_canaries()
  end

  # The daily token budget pauses new dispatch, but not a forced ticket's: the forced candidates
  # still go out, and every other issue waiting for a slot keeps its place.
  defp dispatch_forced_over_daily_budget(%State{} = state, issues) do
    forced = Enum.filter(issues, &forced_candidate?(&1, state))
    next_state = dispatch_chosen_issues(forced, state, keep_waiting: true)

    for %Issue{id: issue_id} = issue <- forced,
        Map.has_key?(next_state.running, issue_id),
        not Map.has_key?(state.running, issue_id) do
      Logger.warning(
        "Daily token budget exhausted daily_used=#{state.budget_daily_used} daily_limit=#{Config.settings!().agent.max_tokens_per_day}; dispatched forced ticket anyway: #{issue_context(issue)} forced=true"
      )
    end

    next_state
  end

  defp maybe_dispatch_chosen_issue(%Issue{} = issue, {state, hold}, previous_waiting, active_states, terminal_states) do
    waiting = Map.get(previous_waiting, issue.id, %{})

    cond do
      reason = dispatch_gate_closed_reason(issue, state, active_states, terminal_states) ->
        {state |> note_blocked_flow_head(issue) |> put_dispatch_skipped(issue, reason), hold}

      # A retry that started waiting for a slot while a dispatch readiness task ran is held again
      # with its attempt, as a retry that comes due during the hold is.
      waiting_retry_held?(waiting, issue, state) ->
        {hold_waiting_retry_for_usage_limit(state, issue, waiting), hold}

      usage_limit_held?(issue, state) ->
        {put_dispatch_skipped(state, issue, UsageLimit.hold_label(usage_limit_hold(state, issue))), hold}

      true ->
        {state, hold} =
          state
          |> note_forced_allowance_full(issue)
          |> dispatch_or_wait_for_slot(issue, waiting, hold)

        {note_dropped_at_dispatch(state, issue), hold}
    end
  end

  defp maybe_dispatch_chosen_issue(_issue, acc, _previous_waiting, _active_states, _terminal_states), do: acc

  # Dispatch read the issue again from Linear and found it no longer dispatchable, or found no
  # worker free; each case is logged where it happens.
  defp note_dropped_at_dispatch(%State{} = state, %Issue{id: issue_id} = issue) do
    if Enum.any?([state.running, state.slot_waiting, state.retry_attempts], &Map.has_key?(&1, issue_id)),
      do: state,
      else: put_dispatch_skipped(state, issue, "not started: the issue read again before dispatch was no longer dispatchable, or no worker was free")
  end

  # A pause starts no dispatch pass, so its candidates are listed here: each with the gate that
  # would hold it anyway, else the pause. Issues waiting for a slot keep their `slot_waiting` entry.
  defp skip_paused_pass(%State{} = state, issues, pause_reason) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> Enum.filter(&match?(%Issue{}, &1))
    |> Enum.reject(&Map.has_key?(state.slot_waiting, &1.id))
    |> Enum.reduce(%{state | dispatch_skipped: %{}}, fn issue, acc ->
      reason = dispatch_gate_closed_reason(issue, acc, active_states, terminal_states) || pause_reason
      put_dispatch_skipped(acc, issue, reason)
    end)
    |> settle_dispatch_skipped(state.dispatch_skipped || %{})
  end

  defp put_dispatch_skipped(%State{} = state, %Issue{} = issue, reason) do
    entry = %{
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      repo_key: issue.repo_key,
      reason: reason,
      connected: Connected.build(issue, nil)
    }

    %{state | dispatch_skipped: Map.put(state.dispatch_skipped, issue.id, entry)}
  end

  # An entry keeps its `since` while its reason stays the same; a new or changed reason is logged once.
  defp settle_dispatch_skipped(%State{dispatch_skipped: skipped} = state, previous) do
    now = DateTime.utc_now()

    settled =
      Map.new(skipped, fn {issue_id, entry} ->
        case Map.get(previous, issue_id) do
          %{reason: reason, since: since} when reason == entry.reason ->
            {issue_id, Map.put(entry, :since, since)}

          _new_or_changed ->
            Logger.debug("Skipping dispatch: issue_id=#{issue_id} issue_identifier=#{entry.identifier} state=#{inspect(entry.state)}; #{entry.reason}")
            {issue_id, Map.put(entry, :since, now)}
        end
      end)

    %{state | dispatch_skipped: settled}
  end

  defp dispatch_or_wait_for_slot(%State{} = state, %Issue{} = issue, waiting, hold) do
    cond do
      is_binary(hold) and fresh_issue?(issue) and not forced_slot_available?(issue, state) ->
        {put_slot_waiting(state, issue, waiting, hold), hold}

      issue_dispatch_slots_available?(issue, state) ->
        {dispatch_waiting_issue(state, issue, waiting), hold}

      true ->
        state = put_slot_waiting(state, issue, waiting, slot_wait_reason(issue, state))
        {state, hold || finishing_hold(issue)}
    end
  end

  # A forced ticket that finds the forced allowance taken gets no extra slot; it still goes first
  # for a normal one. It is logged and notified once per wait, naming the forced runs holding it.
  defp note_forced_allowance_full(%State{} = state, %Issue{id: issue_id} = issue) do
    if forced_issue?(issue, state) and not forced_slot_available?(issue, state) and not MapSet.member?(state.forced_waiting_noted, issue_id) do
      reason = forced_wait_reason(issue, state)

      Logger.warning(
        "Forced ticket waiting: #{issue_context(issue)} forced=true forced_max=#{Config.settings!().agent.forced_max} held_by=#{Enum.join(forced_running_identifiers(state), ",")}; #{reason}"
      )

      Notifications.emit_issue_event(:forced_waiting, issue, %{reason: reason})
      %{state | forced_waiting_noted: MapSet.put(state.forced_waiting_noted, issue_id)}
    else
      state
    end
  end

  defp forced_wait_reason(%Issue{id: issue_id}, %State{} = state) do
    queue_id = forced_queue_id(issue_id, state)
    position = Enum.find_value(ForcedQueue.snapshot(state.forced), &(&1.issue_id == queue_id && &1.position))
    queued = if position, do: "queued ##{position}; ", else: ""
    "#{queued}forced slot taken by #{Enum.join(forced_running_identifiers(state), ", ")}"
  end

  defp forced_running_identifiers(%State{running: running}) do
    Enum.sort(for({_issue_id, entry} <- running, forced_entry?(entry), do: entry.identifier))
  end

  # Forced tickets go first, in `forced_since` order; one the queue has not recorded yet follows
  # the queued ones, and a forced parent's sub-ticket takes its parent's place. The rest keep
  # their order.
  defp forced_first(issues, %State{} = state) do
    {forced_issues, rest} = Enum.split_with(issues, &forced_candidate?(&1, state))
    Enum.sort_by(forced_issues, &forced_sort_key(&1, state)) ++ rest
  end

  defp forced_sort_key(%Issue{id: issue_id}, %State{forced: forced} = state) do
    case Map.get(forced, forced_queue_id(issue_id, state)) do
      %{forced_since: %DateTime{} = forced_since} -> {0, DateTime.to_unix(forced_since, :microsecond)}
      _not_queued -> {1, 0}
    end
  end

  defp dispatch_waiting_issue(%State{} = state, %Issue{} = issue, waiting) do
    dispatch_issue(state, freeze_issue_repo_key(issue, Map.get(waiting, :repo_key)), Map.get(waiting, :attempt), Map.get(waiting, :worker_host))
  end

  defp put_slot_waiting(%State{} = state, %Issue{} = issue, waiting, reason) do
    entry =
      Map.merge(waiting, %{
        identifier: issue.identifier,
        issue_repo_key: issue.repo_key,
        title: issue.title,
        state: issue.state,
        reason: reason,
        since: Map.get(waiting, :since) || DateTime.utc_now(),
        connected: Connected.build(issue, nil)
      })

    %{state | slot_waiting: Map.put(state.slot_waiting, issue.id, entry)}
  end

  defp slot_wait_reason(%Issue{} = issue, %State{} = state) do
    cond do
      forced_issue?(issue, state) and not forced_slot_available?(issue, state) -> forced_wait_reason(issue, state)
      finishing_issue?(issue) -> "finishing slots full"
      true -> "work slots full"
    end
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {stage_rank(issue.state), priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {stage_rank(nil), priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  # Closest to done first: Merging, Rework, other active states (resumes), then Todo.
  defp stage_rank(state_name) when is_binary(state_name) do
    case normalize_issue_state(state_name) do
      @merging_state -> 0
      "rework" -> 2
      "todo" -> 4
      _resume -> 3
    end
  end

  defp stage_rank(_state_name), do: 4

  defp fresh_issue?(%Issue{state: state_name}), do: stage_rank(state_name) == 4

  # Merging: the issues "never start fresh work while a finish waits" protects.
  defp finishing_hold(%Issue{state: state_name} = issue) do
    if stage_rank(state_name) == 0 do
      slot = if finishing_issue?(issue), do: "finishing", else: "work"
      "#{issue.identifier} (#{state_name}) is waiting for a #{slot} slot"
    end
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    dispatch_eligible?(issue, state, active_states, terminal_states) and
      issue_dispatch_slots_available?(issue, state) and
      !agent_left_running?(issue)
  end

  # An agent a previous Symphony left running may still be working in the issue's workspace.
  defp agent_left_running?(%{identifier: identifier} = issue) do
    case AgentProcesses.dispatch_blocked_reason(identifier) do
      nil ->
        false

      reason ->
        Logger.debug("Skipping dispatch; an agent from a previous Symphony may still be running for #{issue_context(issue)}: #{reason}")
        true
    end
  end

  defp dispatch_eligible?(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    dispatch_gates_open?(issue, state, active_states, terminal_states) and !usage_limit_held?(issue, state)
  end

  # Every dispatch gate but the usage limit.
  defp dispatch_gates_open?(%Issue{} = issue, %State{} = state, active_states, terminal_states),
    do: is_nil(dispatch_gate_closed_reason(issue, state, active_states, terminal_states))

  # The reason the first closed dispatch gate (every one but the usage limit) gives, or nil when
  # all are open. `/api/v1/state` lists it under `dispatch_skipped`, so no candidate is passed over
  # in silence. A `Todo` issue waits until every blocker is terminal (`Issue.blocked?/2`), a ticket
  # with a hold waits for it to lift, and a `breakdown` parent waits on its sub-issues (see
  # `issue_held?/2`). The review flow parks a Code Review ticket whose repo has no reviewer
  # enabled, and a Code Review or QA ticket whose head is not green yet: the reviewer and
  # the QA agent only run on a green head. A `Merging` issue waits for CI after its landing run, or
  # is landed by GitHub auto-merge.
  defp dispatch_gate_closed_reason(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    if candidate_issue?(issue, active_states, terminal_states),
      do: hold_reason(issue, state, terminal_states) || review_flow_reason(issue, state) || taken_reason(issue, state),
      else: not_candidate_reason(issue, active_states, terminal_states)
  end

  defp hold_reason(%Issue{} = issue, %State{} = state, terminal_states) do
    repo_key = hold_repo_key(issue)

    cond do
      reason = operator_stop_reason(issue, state) -> reason
      Issue.blocked?(issue, terminal_states) -> "blocked by #{open_blocker_names(issue, terminal_states)}"
      is_nil(repo_key) -> "it has no repo key and several repos are configured, so its holds can't be read"
      (held = Hold.held_kinds(repo_key, issue.id)) != [] -> "on a #{Enum.map_join(held, " and ", &Hold.label/1)} hold"
      waiting_on_sub_issues?(issue, terminal_states) -> "waiting on its sub-tickets"
      Map.has_key?(state.update_holds, issue.id) -> "waiting for an app update: #{state.update_holds[issue.id].reason}"
      replan_pending?(issue, state) -> "its plan waits to be replaced before it runs again"
      true -> nil
    end
  end

  defp review_flow_reason(%Issue{id: issue_id} = issue, %State{merging_ci_waits: merging_ci_waits}) do
    cond do
      code_review_reviewer_disabled?(issue) -> "the reviewer is turned off for its repo"
      is_map_key(merging_ci_waits, issue_id) -> "held in Merging until CI settles on #{merging_ci_waits[issue_id].commit_sha}"
      true -> watch_gate_reason(issue)
    end
  end

  defp taken_reason(%Issue{id: issue_id} = issue, %State{} = state) do
    cond do
      Map.has_key?(state.running, issue_id) -> running_reason(issue_id)
      MapSet.member?(state.claimed, issue_id) -> "claimed by a retry or a Linear update in flight"
      MapSet.member?(state.budget_exhausted, issue_id) -> "its token budget is spent (agent.max_tokens_per_issue)"
      not priority_allowed?(issue, state) -> priority_reason(issue)
      true -> nil
    end
  end

  # A QA pass waiting for another pass's dev server port on the QA host says so (TP-1125).
  defp running_reason(issue_id) do
    case DevServerLease.waiting(issue_id) do
      nil -> "already running"
      wait -> DevServerLease.reason(wait)
    end
  end

  defp not_candidate_reason(%Issue{assigned_to_worker: false}, _active_states, _terminal_states), do: "not assigned to this Symphony's worker"

  defp not_candidate_reason(%Issue{state: state_name}, active_states, terminal_states) do
    cond do
      terminal_issue_state?(state_name, terminal_states) -> "#{state_name} is a terminal state"
      not active_issue_state?(state_name, active_states) -> "#{inspect(state_name)} is not an active state"
      true -> "Linear returned it without an id, identifier or title"
    end
  end

  defp open_blocker_names(%Issue{} = issue, terminal_states) do
    issue |> Issue.open_blockers(terminal_states) |> Enum.map_join(", ", &(Map.get(&1, :identifier) || "an unnamed ticket"))
  end

  defp priority_reason(%Issue{priority: priority}) do
    names = Schema.Tickets.priority_names()
    allowed = Enum.join(Config.settings!().tickets.priorities, ", ")
    "priority #{Enum.at(names, priority || 0, priority)} is not in tickets.priorities (#{allowed})"
  end

  # `tickets.priorities` narrows which priorities may start new work. A forced ticket, and a retry
  # that is waiting for a slot (its claim is released while it waits), bypass it, so the filter only
  # gates fresh picks and never stalls work already under way.
  defp priority_allowed?(%Issue{id: issue_id, priority: priority} = issue, %State{} = state) do
    case Config.ticket_priority_filter() do
      nil ->
        true

      allowed ->
        forced_issue?(issue, state) or
          Map.has_key?(state.slot_waiting, issue_id) or
          MapSet.member?(allowed, priority || 0)
    end
  end

  defp issue_taken?(%Issue{id: issue_id}, %State{} = state) do
    MapSet.member?(state.claimed, issue_id) or MapSet.member?(state.budget_exhausted, issue_id) or Map.has_key?(state.running, issue_id)
  end

  defp issue_dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    dispatch_slots_available?(issue, state) and worker_slots_available?(state)
  end

  # Each active epic reserves a lane out of max_total, recomputed from the candidates every poll.
  defp put_epic_lanes(%State{} = state, issues) do
    max_total = state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents
    %{state | epic_lanes: EpicLanes.plan(issues, max_total, Config.settings!().agent.epic_lanes, terminal_state_set())}
  end

  # Candidates held in `Todo` by open blockers, held by self-heal on a fix ticket, or held by a
  # blocker's fix the running app does not include yet (`UpdateHold`), recomputed on every poll tick
  # for the snapshot.
  defp put_blocked(%State{} = state, issues) do
    terminal_states = Config.settings!().tracker.terminal_states
    build = BuildInfo.current()

    blocked =
      for %Issue{} = issue <- issues, Issue.blocked?(issue, terminal_states) do
        %{
          issue_id: issue.id,
          identifier: issue.identifier,
          title: issue.title,
          state: issue.state,
          blockers: issue |> Issue.open_blockers(terminal_states) |> Enum.map(&blocker_snapshot/1)
        }
      end

    fix_ticket_held =
      for %Issue{} = issue <- issues, not Issue.blocked?(issue, terminal_states), hold = fix_ticket_hold(issue) do
        %{
          issue_id: issue.id,
          identifier: issue.identifier,
          title: issue.title,
          state: issue.state,
          kind: :hold,
          reason: hold.reason,
          blockers: for(key <- hold.waits_on.keys, do: %{identifier: key, state: "fix ticket"})
        }
      end

    update_holds =
      for %Issue{} = issue <- issues,
          hold = UpdateHold.hold(issue, build, state.update_hold_cache, terminal_states),
          into: %{},
          do: {issue.id, Map.merge(hold, %{identifier: issue.identifier, title: issue.title, state: issue.state})}

    log_update_hold_changes(state.update_holds, update_holds)

    update_blocked =
      for {issue_id, hold} <- update_holds do
        %{
          issue_id: issue_id,
          identifier: hold.identifier,
          title: hold.title,
          state: hold.state,
          kind: :app_update,
          reason: hold.reason,
          blockers: for(blocker <- hold.blockers, do: %{identifier: blocker.identifier, state: "merged in #{BuildInfo.short_sha(blocker.merge_sha)}"})
        }
      end

    blocked = Enum.sort_by(blocked ++ fix_ticket_held ++ update_blocked, & &1.identifier)
    %{state | blocked: blocked, update_holds: update_holds}
  end

  # The Blocked hold the self-heal lane set to wait on a fix ticket, or nil.
  defp fix_ticket_hold(%Issue{} = issue) do
    with repo_key when is_binary(repo_key) <- hold_repo_key(issue),
         %{waits_on: %{type: "fix_ticket"}} = hold <- Hold.get(repo_key, issue.id, :blocked) do
      hold
    else
      _none -> nil
    end
  end

  defp log_update_hold_changes(previous, current) do
    for {issue_id, hold} <- current, not Map.has_key?(previous, issue_id) do
      Logger.info("Holding for an app update: issue_id=#{issue_id} issue_identifier=#{hold.identifier}; #{hold.reason}")
    end

    for {issue_id, hold} <- previous, not Map.has_key?(current, issue_id) do
      Logger.info("Released from the app update hold: issue_id=#{issue_id} issue_identifier=#{hold.identifier}")
    end

    :ok
  end

  # Forced tickets are found in the repo this poll fetched, which only holds active states. Each one
  # already queued is refreshed by id on every poll, so it stays queued while it sits outside the
  # active states (Plan Review, ...) and leaves only when its label goes, it is terminal, or Linear no
  # longer returns it. A ticket `symphony force` changed after this poll started keeps what it
  # recorded: the poll's view of that ticket is older.
  defp apply_forced_poll_result(%State{} = state, repo_result, forced_ids, forced_result, poll_started_ms) do
    touched = Map.filter(state.forced_touched, fn {_issue_id, touched_ms} -> touched_ms >= poll_started_ms end)

    discovered =
      case repo_result do
        {_repo_name, {:ok, issues}} when is_list(issues) -> issues
        _not_polled -> []
      end

    {refreshed, gone_ids} =
      case forced_result do
        {:ok, issues} when is_list(issues) ->
          {issues, forced_ids -- for(%Issue{id: issue_id} <- issues, do: issue_id)}

        {:error, reason} ->
          Logger.warning("Failed to refresh forced tickets; keeping them queued: #{inspect(reason)}")
          {[], []}
      end

    observed = Enum.reject(discovered ++ refreshed, &match?(%Issue{id: issue_id} when is_map_key(touched, issue_id), &1))
    gone_ids = Enum.reject(gone_ids, &is_map_key(touched, &1))
    {forced, changes} = ForcedQueue.reconcile(state.forced, observed, gone_ids, Config.settings!(), state.clock.())

    %{put_forced(state, forced, changes) | forced_touched: touched}
    |> remember_forced_issues(observed)
    |> note_forced_milestones()
  end

  # The latest issue seen for each forced ticket and forced parent's part, from the poll's
  # candidates, the by-id refresh and `symphony force`, so the snapshot can work out its phase.
  defp remember_forced_issues(%State{} = state, issues) do
    seen = for %Issue{id: issue_id} = issue <- issues, forced_queued?(issue_id, state), into: %{}, do: {issue_id, issue}
    known = Map.merge(state.forced_issues, seen)
    %{state | forced_issues: Map.filter(known, fn {issue_id, _issue} -> forced_queued?(issue_id, state) end)}
  end

  # Once per forced ticket, a warning and a `forced_stale` notice when it has been forced past
  # `forced_stale_after_hours`; and a `forced_human_gate` notice each time it enters `Plan Review`.
  # When each was sent is kept in the queue entry, so a restart does not send it again.
  defp note_forced_milestones(%State{forced: forced} = state) do
    now = state.clock.()
    stale_after_hours = Config.settings!().agent.forced_stale_after_hours

    noted =
      Map.new(forced, fn {issue_id, entry} ->
        issue = forced_notice_issue(issue_id, entry, state)
        {issue_id, entry |> note_forced_stale(issue, now, stale_after_hours) |> note_forced_human_gate(issue, now)}
      end)

    if noted != forced do
      state.repo_key |> RunStore.put_forced(noted) |> log_run_store_error("persist forced tickets")
    end

    %{state | forced: noted}
  end

  defp note_forced_stale(entry, %Issue{} = issue, now, stale_after_hours) do
    forced_for = ForcedStatus.forced_for_seconds(entry.forced_since, now)

    if ForcedStatus.stale?(forced_for, stale_after_hours) and is_nil(Map.get(entry, :stale_notified_at)) do
      reason = "forced for #{ForcedStatus.duration_label(forced_for)}, past forced_stale_after_hours=#{stale_after_hours}"
      Logger.warning("Forced ticket stale: #{issue_context(issue)} forced_since=#{DateTime.to_iso8601(entry.forced_since)}; #{reason}")
      Notifications.emit_issue_event(:forced_stale, issue, %{reason: reason})
      Map.put(entry, :stale_notified_at, now)
    else
      entry
    end
  end

  defp note_forced_human_gate(entry, %Issue{} = issue, now) do
    in_review? = PlanReview.in_state?(entry.state)
    notified? = not is_nil(Map.get(entry, :human_gate_notified_at))

    cond do
      in_review? and not notified? ->
        reason = if Issue.breakdown?(issue), do: "#{issue.identifier}'s plan is waiting for your review", else: "#{issue.identifier} is waiting for your review"
        Logger.info("Forced ticket at a human gate: #{issue_context(issue)}; #{reason}")
        Notifications.emit_issue_event(:forced_human_gate, issue, %{reason: reason})
        Map.put(entry, :human_gate_notified_at, now)

      not in_review? and notified? ->
        Map.delete(entry, :human_gate_notified_at)

      true ->
        entry
    end
  end

  defp forced_notice_issue(issue_id, entry, %State{forced_issues: issues}) do
    case Map.get(issues, issue_id) do
      %Issue{} = issue -> %{issue | state: entry.state}
      nil -> %Issue{id: issue_id, identifier: entry.identifier, title: entry.title, state: entry.state, repo_key: entry.repo_key}
    end
  end

  defp put_forced(%State{} = state, forced, changes) do
    if changes != [] do
      state.repo_key |> RunStore.put_forced(forced) |> log_run_store_error("persist forced tickets")
      Enum.each(changes, &record_forced_change(&1, state.repo_key))
    end

    state = %{state | forced: forced}

    %{state | forced_waiting_noted: MapSet.filter(state.forced_waiting_noted, &forced_queued?(&1, state))}
    |> release_unforced_runs()
  end

  # A run on the forced allowance gives it back once its ticket is no longer forced (its label was
  # removed, or its forced parent's was): it goes on as a normal run, and a ticket still forced can
  # take the allowance.
  defp release_unforced_runs(%State{running: running} = state) do
    released =
      for {issue_id, entry} <- running, forced_entry?(entry), not forced_queued?(issue_id, state), into: %{} do
        Logger.info("Forced run released the forced allowance: issue_id=#{issue_id} issue_identifier=#{entry.identifier}; no longer forced, running on as a normal run")
        {issue_id, %{entry | forced: false}}
      end

    %{state | running: Map.merge(running, released)}
  end

  # Linear answers an unknown identifier with an "Entity not found" GraphQL error rather than a null issue.
  defp fetch_issue_to_force(identifier) do
    case Tracker.fetch_issue_by_identifier(identifier) do
      {:error, {:linear_graphql_errors, errors}} = error ->
        if Enum.any?(List.wrap(errors), &entity_not_found?/1), do: {:error, :issue_not_found}, else: error

      result ->
        result
    end
  end

  defp entity_not_found?(%{"message" => message}) when is_binary(message), do: message =~ ~r/not found/i
  defp entity_not_found?(_error), do: false

  defp put_force_label(%Issue{labels: labels} = issue, false = _clear?, settings) do
    label = settings.agent.force_label

    cond do
      terminal_issue_state?(issue.state, terminal_state_set()) -> {:error, {:issue_terminal, issue.state}}
      Issue.forced?(issue, settings) -> {:ok, issue}
      true -> with :ok <- Tracker.add_issue_label(issue.id, label), do: {:ok, %{issue | labels: labels ++ [label]}}
    end
  end

  defp put_force_label(%Issue{labels: labels} = issue, true = _clear?, settings) do
    label = settings.agent.force_label
    {removed, kept} = Enum.split_with(labels, &(normalize_issue_state(&1) == normalize_issue_state(label)))

    if removed == [] do
      {:ok, issue}
    else
      with :ok <- Tracker.remove_issue_label(issue.id, label), do: {:ok, %{issue | labels: kept}}
    end
  end

  # The force label is on: the Director's force is recorded on the ticket, best effort, in its repo,
  # else the primary one. A clear records nothing.
  defp record_force_action(_issue, true = _clear?), do: :ok

  defp record_force_action(%Issue{id: issue_id} = issue, false = _clear?) do
    case force_repo_key(issue) do
      {:ok, repo_key} -> TicketSignals.record_event(repo_key, issue_id, "person.action", %{action: "force"}, actor: {:person, "the Director"})
      {:error, _reason} -> :ok
    end
  end

  defp force_repo_key(issue) do
    case issue_repo_key(issue) do
      nil -> Config.repo_key()
      repo_key -> {:ok, repo_key}
    end
  end

  # What `symphony force` reports: whether the ticket is forced now, its place in the queue (nil
  # until it joins), and the tickets holding the `forced_max` slots.
  defp force_result(%Issue{} = issue, forced, settings) do
    queue = ForcedQueue.snapshot(forced)
    forced_max = settings.agent.forced_max

    %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      state: issue.state,
      forced: Issue.forced?(issue, settings),
      position: Enum.find_value(queue, &(&1.issue_id == issue.id and &1.position)),
      forced_max: forced_max,
      holders: for(%{position: position, identifier: identifier} <- queue, position <= forced_max, do: identifier)
    }
  end

  defp record_forced_change({:start, issue_id, entry}, repo_key) do
    Logger.info("Forced ticket queued: issue_id=#{issue_id} issue_identifier=#{entry.identifier} state=#{entry.state}")
    record_forced_audit("forced_start", issue_id, entry, repo_key, %{})
  end

  defp record_forced_change({:end, issue_id, entry, reason}, repo_key) do
    Logger.info("Forced ticket left the queue: issue_id=#{issue_id} issue_identifier=#{entry.identifier} reason=#{reason}")
    record_forced_audit("forced_end", issue_id, entry, repo_key, %{reason: Atom.to_string(reason)})
    if reason == :done, do: remove_force_label(issue_id, entry)
  end

  # A ticket forced through to a terminal state is done with: its force label comes off, so it
  # doesn't read as forced on the board. The Linear call runs outside the orchestrator.
  defp remove_force_label(issue_id, entry) do
    label = Config.settings!().agent.force_label

    remove = fn ->
      case Tracker.remove_issue_label(issue_id, label) do
        :ok -> Logger.info("Removed the force label from a done ticket: issue_id=#{issue_id} issue_identifier=#{entry.identifier} label=#{label}")
        {:error, reason} -> Logger.warning("Failed to remove the force label from a done ticket: issue_id=#{issue_id} issue_identifier=#{entry.identifier} reason=#{inspect(reason)}")
      end
    end

    case start_task_supervisor_child(remove) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.warning("Failed to start removing the force label: issue_id=#{issue_id} issue_identifier=#{entry.identifier} reason=#{inspect(reason)}")
    end
  end

  defp record_forced_audit(event_type, issue_id, entry, repo_key, attrs) do
    %{
      event_type: event_type,
      repo_key: entry.repo_key || repo_key,
      issue_id: issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      forced_since: DateTime.to_iso8601(entry.forced_since)
    }
    |> Map.merge(attrs)
    |> AuditLog.record()
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record #{event_type} audit event: issue_id=#{issue_id} reason=#{inspect(reason)}")
    end
  end

  defp persisted_forced(repo_key) do
    case RunStore.get_forced(repo_key) do
      %{} = forced ->
        forced

      {:error, reason} ->
        Logger.warning("Failed to restore forced tickets from run store: #{inspect(reason)}")
        %{}
    end
  end

  defp blocker_snapshot(%{} = blocker), do: %{identifier: Map.get(blocker, :identifier), state: Map.get(blocker, :state)}
  defp blocker_snapshot(_blocker), do: %{identifier: nil, state: nil}

  defp epic_lane_slot_available?(%Issue{id: issue_id}, %State{} = state) do
    EpicLanes.slot_for(state.epic_lanes, issue_id, work_running_ids(state.running)) != :none
  end

  # Landing runs finish approved work, so they use their own `finishing_max` allowance instead of
  # `max_total` and the epic lanes.
  defp finishing_issue?(%Issue{} = issue) do
    settings = Config.settings!()
    RunKind.classify(issue, terminal_states: settings.tracker.terminal_states, settings: settings) == :landing
  end

  defp finishing_entry?(%{forced: true}), do: false
  defp finishing_entry?(%{run_profile: %{kind: :landing}}), do: true
  defp finishing_entry?(_running_entry), do: false

  # Forced tickets (`agent.concurrency.force_label`) dispatch on their own `forced_max` allowance,
  # past `max_total`, the epic lanes, `finishing_max` and the per-state caps. A run on it carries
  # `forced: true` and takes none of those slots. A forced ticket past `forced_max` competes for a
  # normal slot and runs as a normal run.
  defp forced_issue?(%Issue{} = issue, %State{} = state), do: Issue.forced?(issue, Config.settings!()) or forced_part?(issue.id, state)

  defp forced_candidate?(issue, state), do: match?(%Issue{}, issue) and forced_issue?(issue, state)

  defp forced_entry?(%{forced: true}), do: true
  defp forced_entry?(_running_entry), do: false

  defp forced_slot_available?(%Issue{} = issue, %State{} = state), do: forced_issue?(issue, state) and forced_slot_free?(state)

  defp forced_slot_free?(%State{running: running}) do
    forced_runs = Enum.count(running, fn {_issue_id, entry} -> forced_entry?(entry) end)
    forced_runs < Config.settings!().agent.forced_max
  end

  # With the normal slots full, a poll still runs the dispatch pass for a forced candidate the
  # forced allowance can take, or to note once that one has to wait.
  defp forced_pass_needed?(%State{} = state, issues) do
    Enum.any?(issues, fn issue ->
      forced_candidate?(issue, state) and not issue_taken?(issue, state) and
        (forced_slot_free?(state) or not MapSet.member?(state.forced_waiting_noted, issue.id))
    end)
  end

  # A forced `breakdown` parent waiting on its sub-tickets is one forced unit: its current part, the
  # first ticket on its epic path that can run, counts as forced without the label being written on
  # it. Parts are picked in EpicLanes order (stage, then nearest the epic, then dispatch order), so a
  # blocked sub-ticket waits for its blocker. A part stays the parent's while it runs or waits on a
  # retry, so no second one takes the forced allowance meanwhile. Rebuilt from every poll's
  # candidates.
  defp put_forced_parts(%State{} = state, issues) do
    settings = Config.settings!()
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    states = {active_states, terminal_states}
    ordered = issues |> sort_issues_for_dispatch() |> Enum.with_index()

    parts =
      issues
      |> Enum.filter(&forced_waiting_parent?(&1, settings, terminal_states))
      |> Enum.flat_map(fn %Issue{id: parent_id} = parent ->
        members = EpicLanes.members(state.epic_lanes, parent_id)

        case kept_forced_part(parent, members, state) || next_forced_part(parent, members, ordered, state, states) do
          nil -> []
          part -> [{parent_id, part}]
        end
      end)
      |> Map.new()

    state = %{state | forced_parts: parts}

    %{state | forced_waiting_noted: MapSet.filter(state.forced_waiting_noted, &forced_queued?(&1, state))}
    |> release_unforced_runs()
  end

  defp forced_waiting_parent?(%Issue{} = issue, settings, terminal_states) do
    Issue.forced?(issue, settings) and Issue.waiting_on_sub_issues?(issue, terminal_states) and not Issue.replanning?(issue)
  end

  defp forced_waiting_parent?(_issue, _settings, _terminal_states), do: false

  defp kept_forced_part(%Issue{id: parent_id}, members, %State{} = state) do
    with %{issue_id: issue_id} <- Map.get(state.forced_parts, parent_id),
         %{} = member <- Map.get(members, issue_id),
         true <- issue_taken?(%Issue{id: issue_id}, state) do
      forced_part_entry(issue_id, member)
    else
      _no_part -> nil
    end
  end

  defp next_forced_part(%Issue{id: parent_id}, members, ordered, %State{} = state, {active_states, terminal_states}) do
    for {%Issue{id: issue_id} = issue, index} <- ordered, is_map_key(members, issue_id) do
      member = Map.fetch!(members, issue_id)
      {{stage_rank(issue.state), member.depth, index}, issue, member}
    end
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find_value(fn {_rank, issue, member} ->
      # Judged as the parent's part, so a usage-limit headroom hold does not rule it out.
      as_part = %{state | forced_parts: Map.put(state.forced_parts, parent_id, %{issue_id: issue.id})}

      if dispatch_eligible?(issue, as_part, active_states, terminal_states),
        do: forced_part_entry(issue.id, member)
    end)
  end

  defp forced_part_entry(issue_id, member), do: %{issue_id: issue_id, identifier: member.identifier, state: member.state}

  defp forced_part?(issue_id, %State{forced_parts: parts}), do: Enum.any?(parts, fn {_parent_id, part} -> part.issue_id == issue_id end)

  # Forced on its own, or as a forced parent's part.
  defp forced_queued?(issue_id, %State{} = state), do: Map.has_key?(state.forced, issue_id) or forced_part?(issue_id, state)

  # The forced queue entry an issue waits under: its own, else its forced parent's.
  defp forced_queue_id(issue_id, %State{forced: forced, forced_parts: parts}) do
    if Map.has_key?(forced, issue_id),
      do: issue_id,
      else: Enum.find_value(parts, issue_id, fn {parent_id, part} -> part.issue_id == issue_id && parent_id end)
  end

  # The forced queue for the snapshot: each forced parent with its current part, whether the
  # ticket waits for a person (not yet approved, or in Plan Review) rather than for Symphony, its phase
  # and what it waits on (worked out on the part when a forced parent has one), and how long it has
  # been forced.
  defp forced_snapshot(%State{forced: forced}, _auto_merge) when map_size(forced) == 0, do: []

  defp forced_snapshot(%State{} = state, auto_merge) do
    now = state.clock.()
    stale_after_hours = Config.settings!().agent.forced_stale_after_hours
    context = %{auto_merge_ids: MapSet.new(auto_merge, & &1.issue_id)}

    for entry <- ForcedQueue.snapshot(state.forced) do
      part = Map.get(state.forced_parts, entry.issue_id)
      forced_for = ForcedStatus.forced_for_seconds(entry.forced_since, now)

      entry
      |> Map.merge(%{
        sub_issue: part,
        waiting_on_human: EpicLanes.human_gated_state?(entry.state),
        forced_for_seconds: forced_for,
        stale: ForcedStatus.stale?(forced_for, stale_after_hours)
      })
      |> Map.merge(ForcedStatus.describe(forced_signals(forced_subject(entry, part, state), state, context)))
    end
  end

  # The issue a forced entry's phase is worked out on: its part, else the ticket itself; the latest
  # one a poll saw, else what the queue recorded.
  defp forced_subject(entry, part, %State{forced_issues: issues}) do
    {issue_id, identifier, issue_state} =
      case part do
        %{issue_id: part_id} -> {part_id, part.identifier, part.state}
        nil -> {entry.issue_id, entry.identifier, entry.state}
      end

    Map.get(issues, issue_id) || %Issue{id: issue_id, identifier: identifier, title: entry.title, state: issue_state}
  end

  defp forced_signals(%Issue{id: issue_id} = issue, %State{} = state, context) do
    case Map.get(state.running, issue_id) do
      %{} = running_entry ->
        %{running_kind: get_in(running_entry, [:run_profile, :kind]) || :implementation}

      nil ->
        settings = Config.settings!()
        terminal_states = settings.tracker.terminal_states
        repo_key = dispatch_repo_key(state, issue)

        %{
          state: issue.state,
          plan_review_state: PlanReview.state(settings),
          kind: AgentRunner.run_profile(issue, Config.settings_for_repo!(repo_key), repo_key: repo_key).kind,
          merging_ci_wait?: Map.has_key?(state.merging_ci_waits, issue_id),
          auto_merge?: merging_state?(issue.state) and MapSet.member?(context.auto_merge_ids, issue_id),
          blockers: forced_blockers(issue, state, terminal_states),
          paused?: match?(%{paused: true}, state.pause),
          usage_limit?: not is_nil(usage_limit_hold(state, issue)),
          slot_waiting?: Map.has_key?(state.slot_waiting, issue_id)
        }
    end
  end

  # Its open blockers, else the merged blockers whose fix the running app does not include yet.
  defp forced_blockers(%Issue{} = issue, %State{} = state, terminal_states) do
    if Issue.blocked?(issue, terminal_states) do
      issue |> Issue.open_blockers(terminal_states) |> Enum.map(&blocker_label/1)
    else
      state.update_holds |> Map.get(issue.id, %{blockers: []}) |> Map.fetch!(:blockers) |> Enum.map(&blocker_label/1)
    end
  end

  defp blocker_label(blocker), do: Map.get(blocker, :identifier) || "an unknown issue"

  defp work_running_ids(running) when is_map(running) do
    for {issue_id, entry} <- running, not finishing_entry?(entry), not forced_entry?(entry), do: issue_id
  end

  defp available_finishing_slots(%State{running: running}) do
    max(Config.settings!().agent.finishing_max - Enum.count(running, fn {_issue_id, entry} -> finishing_entry?(entry) end), 0)
  end

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{forced: true}} ->
        false

      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  # A retry or continuation starts new work, so like a fresh dispatch it needs the issue still
  # assigned to this Symphony's worker: unassigning a ticket takes it away from Symphony.
  defp active_retry_issue?(%Issue{state: state_name} = issue, terminal_states) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_state_set()) and
      !terminal_issue_state?(state_name, terminal_states) and
      !issue_held?(issue, terminal_states)
  end

  defp active_retry_issue?(_issue, _terminal_states), do: false

  # A `Todo` issue waits until every blocker is terminal (see `Issue.blocked?/2`).
  # A `breakdown` parent waits while its sub-issues are worked, in the waiting state or, when that
  # is off, in its active state; it is dispatched again for close-out once every sub-issue is terminal.
  # One whose open sub-issues are all still in Backlog was never approved: outside the waiting state
  # it runs to finish or revise its plan. In `Rework` its plan was rejected, so it is broken down
  # again whatever its sub-issues' states.
  defp issue_held?(issue, terminal_states) do
    Issue.blocked?(issue, terminal_states) or hold?(issue) or waiting_on_sub_issues?(issue, terminal_states)
  end

  defp waiting_on_sub_issues?(issue, terminal_states) do
    not Issue.replanning?(issue) and
      (Issue.waiting_on_sub_issues?(issue, terminal_states) or SubIssueWait.held?(issue, terminal_states, Config.settings!()))
  end

  # A hold pauses the ticket in its phase and lifts when its condition does — a `Blocked` one when
  # what it waits on goes terminal or a person grants access, a `Needs Decision` one when the person
  # records the decision — and the ticket then dispatches again from where it stopped. The store is
  # the truth; the board label is only its projection. The store is keyed by repo, so an issue whose
  # repo can't be told (`hold_repo_key/1`) is held rather than read as unheld.
  defp hold?(%Issue{id: issue_id} = issue) do
    case hold_repo_key(issue) do
      nil -> true
      repo_key -> Hold.held_any?(repo_key, issue_id)
    end
  end

  # The repo a ticket's holds are read under: its own, else the only configured repo. With several
  # repos an issue with no repo key could be any of them.
  defp hold_repo_key(%Issue{} = issue), do: issue_repo_key(issue) || sole_repo_key()

  defp sole_repo_key do
    case Config.repos() do
      {:ok, [%{name: name}]} when is_binary(name) and name != "" -> name
      _none_or_several -> nil
    end
  end

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp active_issue_state?(_state_name, _active_states), do: false

  defp watching_issue_state?(state_name, active_states, terminal_states) when is_binary(state_name) do
    !active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp watching_issue_state?(_state_name, _active_states, _terminal_states), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set, do: terminal_state_set(Config.settings!())

  @doc """
  The terminal states of `settings`, trimmed and lowercased: the set the dispatch gate and the
  reconciliation read. Public so the candidates from the record (`SymphonyElixir.Dispatch.Candidates`)
  use the same one.
  """
  @spec terminal_state_set(Schema.t()) :: MapSet.t(String.t())
  def terminal_state_set(%Schema{} = settings) do
    settings.tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set, do: active_state_set(Config.settings!())

  @doc """
  The machine's active states of `settings` (the dispatch gate and the reconciliation filter), trimmed
  and lowercased: the configured active states plus the phase states, never `Plan Review`
  (`StateMachine.tracker_active_states/1`). Public for the same reason as `terminal_state_set/1`.
  """
  @spec active_state_set(Schema.t()) :: MapSet.t(String.t())
  def active_state_set(%Schema{} = settings) do
    settings.tracker
    |> StateMachine.tracker_active_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    repo_key = dispatch_repo_key(state, issue)
    sticky_route? = retry_attempt?(attempt)
    terminal_states = terminal_state_set()
    source = dispatch_source_in_use()
    issue_fetcher = dispatch_issue_fetcher(state, source, repo_key)

    revalidate_opts = [sticky_route?: sticky_route?, repo_key: repo_key, source: source]

    case revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states, revalidate_opts) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, repo_key)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        release_undispatched_claim(state, issue.id)

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info(
          "Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} assigned_to_worker=#{refreshed_issue.assigned_to_worker} blocked_by=#{length(refreshed_issue.blocked_by)} sub_issues=#{length(refreshed_issue.sub_issues)}"
        )

        # A Code Review or QA ticket held back on its head records why, as the poll does.
        state
        |> note_blocked_flow_head(refreshed_issue)
        |> release_undispatched_claim(issue.id)

      {:error, reason} ->
        skip_dispatch_after_refresh_failure(state, issue, attempt, preferred_worker_host, repo_key, reason)
    end
  end

  # Dispatch after a readiness task revalidates with the issues that task read; an issue it did not
  # read (its gates opened in between, or no readiness task ran) is read from Linear here. Under
  # `dispatch.source: record` it revalidates with the issue's record in its repo instead.
  defp dispatch_issue_fetcher(_state, :record, repo_key), do: fn [issue_id] -> recorded_dispatch_issue(repo_key, issue_id) end

  defp dispatch_issue_fetcher(%State{dispatch_refresh: %{ids: prefetched_ids, result: result}}, :poll, _repo_key) do
    fn [issue_id] = issue_ids ->
      if MapSet.member?(prefetched_ids, issue_id),
        do: prefetched_dispatch_issue(result, issue_id),
        else: fetch_observed_issues_by_ids(issue_ids)
    end
  end

  defp dispatch_issue_fetcher(_state, :poll, _repo_key), do: &fetch_observed_issues_by_ids/1

  # The issue's record, through the filter its candidacy went through (`Candidates.from_records/4`:
  # observed, not removed, assigned to the worker, not terminal) with its own phase as the only
  # active one, so the revalidation sees whether it moved. No record, or one the filter leaves out,
  # reads as an issue Linear no longer returns.
  defp recorded_dispatch_issue(repo_key, issue_id) do
    case RunStore.get_ticket_state(repo_key, issue_id) do
      %{} = record ->
        settings = Config.settings!()
        record = TicketState.normalize(record)
        opts = shadow_route_opts(dispatch_route(repo_key), settings) ++ [states: List.wrap(record.phase)]
        {:ok, Candidates.from_records(repo_key, [record], settings, opts).candidates}

      nil ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_route(repo_key) do
    case Config.repo(repo_key) do
      {:ok, route} -> route
      {:error, _reason} -> nil
    end
  end

  defp prefetched_dispatch_issue({:ok, issues}, issue_id), do: {:ok, Enum.filter(issues, &match?(%Issue{id: ^issue_id}, &1))}
  defp prefetched_dispatch_issue({:error, _reason} = error, _issue_id), do: error

  # A retry reaches dispatch with its retry entry already popped and its claim
  # still held. When dispatch starts nothing, release the claim, or the poll skips
  # the issue as claimed until a restart even after it returns to an active state.
  defp release_undispatched_claim(%State{} = state, issue_id) do
    if MapSet.member?(state.claimed, issue_id), do: release_issue_claim(state, issue_id), else: state
  end

  # A retry that skips dispatch here has already left the retry queue while its
  # claim stays; schedule it again so the issue is not stuck claimed with no retry.
  defp skip_dispatch_after_refresh_failure(%State{} = state, issue, attempt, worker_host, repo_key, reason) do
    case reason do
      {:linear_rate_limited, _reset_ms} -> Logger.debug("Skipping dispatch; Linear is rate-limited for #{issue_context(issue)}")
      reason -> Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
    end

    if retry_attempt?(attempt) do
      metadata =
        linear_wait_metadata(
          %{
            identifier: issue.identifier,
            title: issue.title,
            worker_host: worker_host,
            repo_key: repo_key,
            error: dispatch_refresh_error(reason)
          },
          reason
        )

      schedule_issue_retry(state, issue.id, retry_attempt_after_refresh_failure(attempt, reason), metadata)
    else
      state
    end
  end

  defp do_dispatch_pr(%State{} = state, target, opts) when is_binary(target) and is_list(opts) do
    cond do
      operator_paused?(state) ->
        {:error, :dispatch_paused, state}

      workspace_quota_paused?(state) ->
        {:error, workspace_quota_error(state), state}

      true ->
        with :ok <- Config.validate!(),
             {:ok, %{issue: issue, pr: pr, repo_key: repo_key}} <- PrRun.resolve(target, opts),
             :ok <- ensure_pr_dispatch_available(state, issue),
             worker_host <- select_worker_host(state, Keyword.get(opts, :worker_host)),
             :ok <- ensure_worker_available(worker_host),
             {:ok, state} <- spawn_pr_on_worker_host(state, issue, pr, worker_host, repo_key) do
          {:ok,
           %{
             issue_id: issue.id,
             identifier: issue.identifier,
             pull_request_url: ticket_pr_url(issue, repo_key),
             repo_key: repo_key,
             worker_host: worker_host
           }, state}
        else
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp do_dispatch_pr(state, _target, _opts), do: {:error, :invalid_pr_target, state}

  defp ensure_pr_dispatch_available(%State{} = state, %Issue{id: issue_id} = issue) do
    cond do
      Map.has_key?(state.running, issue_id) ->
        {:error, :pr_run_already_running}

      !dispatch_slots_available?(issue, state) ->
        {:error, :no_available_orchestrator_slots}

      usage_limit_hold(state, issue) ->
        {:error, :usage_limited}

      true ->
        :ok
    end
  end

  defp ensure_worker_available(:no_worker_capacity), do: {:error, :no_worker_capacity}
  defp ensure_worker_available(_worker_host), do: :ok

  defp spawn_pr_on_worker_host(%State{} = state, issue, pr, worker_host, repo_key) do
    run_id = new_run_id(issue.id)
    settings = Config.settings_for_repo!(repo_key)

    case Verification.allocate_for_dispatch(issue, run_id, worker_host,
           repo_key: repo_key,
           settings: settings
         ) do
      {:ok, verification} ->
        runner_opts = [
          prompt_mode: :pr,
          pr_context: Map.get(issue, :pr_context) || pr,
          issue_state_fetcher: fn _ids -> {:ok, []} end
        ]

        running_attrs = %{
          run_kind: :pr,
          pr_context: Map.get(issue, :pr_context) || pr,
          pull_request_url: ticket_pr_url(issue, repo_key)
        }

        next_state =
          spawn_allocated_agent_on_worker_host(state, issue, %{
            attempt: nil,
            recipient: self(),
            worker_host: worker_host,
            run_id: run_id,
            verification: verification,
            repo_key: repo_key,
            runner_opts: runner_opts,
            running_attrs: running_attrs
          })

        {:ok, next_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, repo_key) do
    case dispatch_loop(issue, repo_key) do
      :ok -> dispatch_issue_to_worker(state, issue, attempt, preferred_worker_host, repo_key)
      {:loop, loop, record} -> hold_dispatch_loop(state, issue, repo_key, loop, record)
    end
  end

  # The dispatch-loop guard (`SymphonyElixir.DispatchLoop`): the runs of this kind the ticket got
  # since its last progress, against the `watchdog` limits. A record the store can't read lists no
  # runs, so a store error never stops a dispatch.
  defp dispatch_loop(%Issue{id: issue_id, state: issue_state} = issue, repo_key) do
    record = TicketState.normalize(RunStore.get_ticket_state(repo_key, issue_id))
    kind = AgentRunner.run_profile(issue, Config.settings_for_repo!(repo_key), repo_key: repo_key).kind
    attempt = %{kind: kind, state: issue_state, head: pr_head(issue_id, repo_key)}

    case DispatchLoop.check(record.dispatches, attempt, DispatchLoop.limits(Config.settings!().watchdog), DateTime.utc_now()) do
      :ok -> :ok
      {:loop, loop} -> {:loop, loop, record}
    end
  end

  # Past a limit the ticket is held instead of dispatched again: a Blocked hold whose reason names
  # the loop, which a person lifts with Unblock or Restart. A store write that fails leaves the
  # ticket unheld, so the next dispatch finds the same loop and tries again.
  defp hold_dispatch_loop(%State{} = state, %Issue{id: issue_id} = issue, repo_key, loop, record) do
    attrs = DispatchLoop.hold_attrs(loop, record.signals)
    _ = Hold.set(repo_key, issue_id, :blocked, attrs)
    Logger.error("Holding #{issue_context(issue)} instead of dispatching it again: #{attrs.reason}")
    record_ticket_signal(repo_key, issue_id, DispatchLoop.hold_type(), %{kind: loop.kind, count: loop.count, window_ms: loop.window_ms})
    release_undispatched_claim(state, issue_id)
  end

  defp pr_head(issue_id, repo_key) do
    case CiPoller.observed_head(issue_id, repo_key: repo_key) do
      %{commit_sha: head} -> head
      nil -> nil
    end
  end

  defp dispatch_issue_to_worker(%State{} = state, issue, attempt, preferred_worker_host, repo_key) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        release_undispatched_claim(state, issue.id)

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, repo_key)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, repo_key) do
    run_id = new_run_id(issue.id)
    settings = Config.settings_for_repo!(repo_key)

    case Verification.allocate_for_dispatch(issue, run_id, worker_host,
           repo_key: repo_key,
           settings: settings
         ) do
      {:ok, verification} ->
        spawn_allocated_issue_on_worker_host(
          state,
          issue,
          attempt,
          recipient,
          worker_host,
          run_id,
          verification,
          repo_key
        )

      {:error, :exhausted} ->
        Logger.warning("Verification port allocation exhausted for #{issue_context(issue)}; waiting for a free port")

        schedule_issue_retry(state, issue.id, retry_attempt(attempt), %{
          repo_key: repo_key,
          identifier: issue.identifier,
          title: issue.title,
          error: "verification port allocation exhausted",
          worker_host: worker_host
        })

      {:error, reason} ->
        Logger.warning("Verification port allocation failed for #{issue_context(issue)}: #{inspect(reason)}")

        schedule_issue_retry(state, issue.id, retry_attempt(attempt), %{
          repo_key: repo_key,
          identifier: issue.identifier,
          title: issue.title,
          error: "verification port allocation failed: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp spawn_allocated_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, run_id, verification, repo_key) do
    spawn_allocated_agent_on_worker_host(state, issue, %{
      attempt: attempt,
      recipient: recipient,
      worker_host: worker_host,
      run_id: run_id,
      verification: verification,
      repo_key: repo_key,
      runner_opts: [],
      running_attrs: %{}
    })
  end

  defp spawn_allocated_agent_on_worker_host(%State{} = state, issue, dispatch) do
    attempt = Map.fetch!(dispatch, :attempt)
    recipient = Map.fetch!(dispatch, :recipient)
    worker_host = Map.fetch!(dispatch, :worker_host)
    run_id = Map.fetch!(dispatch, :run_id)
    verification = Map.fetch!(dispatch, :verification)
    repo_key = Map.fetch!(dispatch, :repo_key)
    runner_opts = Map.get(dispatch, :runner_opts, [])
    running_attrs = Map.get(dispatch, :running_attrs, %{})
    # Read from the current workflow on every dispatch, so a config edit applies to the next run.
    settings = Config.settings_for_repo!(repo_key)
    run_profile = AgentRunner.run_profile(issue, settings, repo_key: repo_key)
    reviewer_run_profile = if run_profile.kind == :code_review and review_agent_enabled?(settings), do: Config.code_review_profile(settings)
    forced? = forced_slot_available?(issue, state)

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           opts =
             [
               attempt: attempt,
               repo_key: repo_key,
               worker_host: worker_host,
               run_id: run_id,
               run_profile: run_profile,
               reviewer_run_profile: reviewer_run_profile,
               verification: verification,
               active_workspace_identifiers: sibling_active_workspace_identifiers(state, issue.id, repo_key)
             ] ++ runner_opts

           AgentRunner.run(issue, recipient, opts)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        started_at = DateTime.utc_now()

        slot = dispatch_slot_label(state, issue, forced?)

        Logger.info(
          "Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"} slot=#{slot} forced=#{forced?} #{run_profile_log_fields(run_profile)}#{trigger_comment_log_fields(issue, run_profile, repo_key)}"
        )

        record_dispatch(issue, repo_key, run_id, run_profile, running_attrs)

        running_entry =
          %{
            pid: pid,
            ref: ref,
            run_id: run_id,
            repo_key: repo_key,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            run_profile: run_profile,
            reviewer_run_profile: reviewer_run_profile,
            verification: verification,
            workspace_path: nil,
            session_id: nil,
            transcript_path: nil,
            transcript_buffer: :queue.new(),
            transcript_buffer_size: 0,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            last_event_at: started_at,
            codex_app_server_pid: nil,
            agent_module: nil,
            agent_session: nil,
            uncached_input_tokens: 0,
            cached_input_tokens: 0,
            cache_creation_input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            reviewer_uncached_input_tokens: 0,
            reviewer_cached_input_tokens: 0,
            reviewer_cache_creation_input_tokens: 0,
            reviewer_output_tokens: 0,
            reviewer_total_tokens: 0,
            codex_input_tokens: 0,
            codex_cached_input_tokens: 0,
            codex_cache_creation_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            reviewer_input_tokens: 0,
            review_agent_enabled: review_agent_enabled_for_repo(repo_key, issue),
            state_reconcile_grace_until_ms: state_reconcile_grace_until_ms(),
            last_reported_uncached_input_tokens: 0,
            last_reported_cached_input_tokens: 0,
            last_reported_cache_creation_input_tokens: 0,
            last_reported_output_tokens: 0,
            last_reported_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_cached_input_tokens: 0,
            codex_last_reported_cache_creation_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            forced: forced?,
            started_at: started_at
          }
          |> Map.merge(running_attrs)

        persist_run_start(issue, running_entry, attempt)
        state = delete_persisted_retry(state, issue.id, repo_key)

        state = clear_quality_gate_blocking_cache_entry(state, issue.id)
        running = Map.put(state.running, issue.id, running_entry)

        %{
          state
          | running: running,
            watching: Map.delete(state.watching, issue.id),
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id),
            forced_waiting_noted: MapSet.delete(state.forced_waiting_noted, issue.id)
        }

      {:error, reason} ->
        Verification.release(verification, "agent task spawn failed")
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          repo_key: repo_key,
          identifier: issue.identifier,
          title: issue.title,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  # Every run started for a ticket is recorded in its store record, best effort, for the
  # dispatch-loop guard. A PR run is an operator's explicit dispatch with no Linear ticket behind it.
  defp record_dispatch(_issue, _repo_key, _run_id, _run_profile, %{run_kind: :pr}), do: :ok

  defp record_dispatch(%Issue{id: issue_id, state: issue_state}, repo_key, run_id, %{kind: kind}, _running_attrs) do
    dispatch = %{kind: kind, run_id: run_id, state: issue_state, head: pr_head(issue_id, repo_key)}

    repo_key
    |> RunStore.record_ticket_dispatch(issue_id, dispatch)
    |> log_run_store_error("record the dispatch")

    record_run_started(repo_key, issue_id, dispatch)
  end

  # The run's `run.started` event, next to its dispatch, keyed by its run id. Its number counts the
  # ticket's earlier runs of the same kind.
  defp record_run_started(repo_key, issue_id, %{kind: kind, run_id: run_id, state: issue_state, head: head}) do
    run_kind = to_string(kind)
    run_number = length(run_events(repo_key, issue_id, "run.started", &(&1[:run_kind] == run_kind))) + 1
    payload = %{run_id: run_id, run_kind: run_kind, run_number: run_number, state: issue_state, head: head}
    TicketSignals.record_event(repo_key, issue_id, "run.started", payload, phase: issue_state, run_id: run_id)
  end

  # The run's `run.ended` event, keyed by its run id, with how it ended, how long it ran, the tokens
  # it spent and its transcript. A run a usage limit, an unreachable model API or a CI wait stopped
  # records `counted: false`, as its dispatch outcome is dropped.
  defp record_run_ended(repo_key, issue_id, run_id, running_entry, reason) do
    head = pr_head(issue_id, repo_key)
    started = run_events(repo_key, issue_id, "run.started", &(&1[:run_id] == run_id)) |> List.first() || %{}

    payload = %{
      run_id: run_id,
      run_kind: started[:run_kind],
      run_number: started[:run_number],
      exit: run_exit(reason, repo_key, issue_id, head),
      head: head,
      duration_ms: run_duration_ms(Map.get(running_entry, :started_at)),
      tokens: Map.get(running_entry, :total_tokens),
      counted: not uncounted_exit?(reason)
    }

    opts = [run_id: run_id, at: DateTime.utc_now()]

    case run_transcript(repo_key, issue_id, run_id, running_entry) do
      {:ok, path} -> record_run_ended_with_transcript(repo_key, issue_id, path, payload, opts)
      :none -> TicketSignals.record_event(repo_key, issue_id, "run.ended", payload, opts)
    end
  end

  # A local Claude Code run's transcript (`Transcript.locate/4`). A run whose end was already
  # recorded keeps it, so a repeated end ingests nothing a second time.
  defp run_transcript(repo_key, issue_id, run_id, running_entry) do
    with nil <- Map.get(running_entry, :worker_host),
         SymphonyElixir.ClaudeCode.AppServer <- Map.get(running_entry, :agent_module),
         {:ok, path} <-
           Transcript.locate(:claude, Map.get(running_entry, :workspace_path), Map.get(running_entry, :session_id), Map.get(running_entry, :transcript_path)),
         [] <- run_events(repo_key, issue_id, "run.ended", &(&1[:run_id] == run_id)) do
      {:ok, path}
    else
      _none -> :none
    end
  end

  # The transcript is copied and hashed in a task, so a large one never holds up the orchestrator;
  # the event keeps the time the run ended. A transcript the store refuses, or a task that can't
  # start, leaves the event without it.
  defp record_run_ended_with_transcript(repo_key, issue_id, path, payload, opts) do
    case start_task_supervisor_child(fn -> ingest_run_transcript(repo_key, issue_id, path, payload, opts) end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("Recording run.ended without its transcript on issue_id=#{issue_id} run_id=#{payload.run_id}: #{inspect(reason)}")
        TicketSignals.record_event(repo_key, issue_id, "run.ended", payload, opts)
    end
  end

  defp ingest_run_transcript(repo_key, issue_id, path, payload, opts) do
    meta = %{repo_key: repo_key, issue_id: issue_id, kind: "transcript", run_id: payload.run_id}

    case Artifacts.ingest(path, meta, roots: [Transcript.root(:claude)]) do
      {:ok, %{id: id}} ->
        TicketSignals.record_event(repo_key, issue_id, "run.ended", Map.put(payload, :transcript, id), [artifacts: [id]] ++ opts)

      {:error, reason} ->
        Logger.warning("Recording run.ended without its transcript on issue_id=#{issue_id} run_id=#{payload.run_id}: #{inspect(reason)}")
        TicketSignals.record_event(repo_key, issue_id, "run.ended", payload, opts)
    end
  end

  defp run_events(repo_key, issue_id, type, keep?) do
    case RunStore.list_ticket_events(repo_key, issue_id, types: [type]) do
      events when is_list(events) -> events |> Enum.map(& &1.payload) |> Enum.filter(keep?)
      {:error, _reason} -> []
    end
  end

  defp run_exit({:usage_limited, _info}, _repo_key, _issue_id, _head), do: "usage limit"
  defp run_exit({:model_api_unreachable, _info}, _repo_key, _issue_id, _head), do: "model API unreachable"
  defp run_exit({:ci_pending, _info}, _repo_key, _issue_id, _head), do: "waiting for CI"

  defp run_exit(reason, repo_key, issue_id, head) do
    cond do
      is_binary(head) and Handoff.emitted?(repo_key, issue_id, head) -> "handoff"
      reason == :normal -> "ended normally"
      true -> "failed (#{reason |> agent_exit_reason_summary() |> String.slice(0, 120)})"
    end
  end

  defp uncounted_exit?({uncounted, _info}) when uncounted in [:usage_limited, :model_api_unreachable, :ci_pending], do: true
  defp uncounted_exit?(_reason), do: false

  defp run_duration_ms(%DateTime{} = started_at), do: max(DateTime.diff(DateTime.utc_now(), started_at, :millisecond), 0)
  defp run_duration_ms(_started_at), do: nil

  # How the run ended, for the dispatch-loop guard's hold reason: its exit and the PR head it left. A
  # run stopped by a usage limit or an unreachable model API counts no attempt, and an epic review
  # waiting for CI is not a loop (`SymphonyElixir.CiWait` bounds that wait), so both are dropped.
  defp record_dispatch_outcome(%{run_id: run_id, issue: %Issue{id: issue_id}} = running_entry, reason) when is_binary(run_id) do
    if pr_run_entry?(running_entry) do
      :ok
    else
      repo_key = running_entry_repo_key(running_entry)

      repo_key
      |> RunStore.record_ticket_dispatch_outcome(issue_id, run_id, dispatch_outcome(reason, issue_id, repo_key))
      |> log_run_store_error("record the end of the run")

      record_run_ended(repo_key, issue_id, run_id, running_entry, reason)
    end
  end

  defp record_dispatch_outcome(_running_entry, _reason), do: :ok

  defp dispatch_outcome(reason, issue_id, repo_key) do
    if uncounted_exit?(reason), do: %{counted: false}, else: counted_dispatch_outcome(reason, issue_id, repo_key)
  end

  defp counted_dispatch_outcome(:normal, issue_id, repo_key), do: %{exit: "ended normally", head: pr_head(issue_id, repo_key)}

  defp counted_dispatch_outcome(reason, issue_id, repo_key),
    do: %{exit: "failed (#{reason |> agent_exit_reason_summary() |> String.slice(0, 120)})", head: pr_head(issue_id, repo_key)}

  defp run_profile_log_fields(%{kind: kind, model: model, effort: effort}) do
    "run_kind=#{kind} model=#{model || "default"} effort=#{effort || "default"}"
  end

  # Names the PR comment a review_feedback run answers, so a run started by a stray
  # comment can be traced to it.
  defp trigger_comment_log_fields(%Issue{id: issue_id}, %{kind: :review_feedback}, repo_key) do
    " " <> PrReviewPoller.trigger_comment_log_fields(issue_id, repo_key_opt(repo_key))
  end

  defp trigger_comment_log_fields(_issue, _run_profile, _repo_key), do: ""

  defp state_reconcile_grace_until_ms do
    System.monotonic_time(:millisecond) + @fresh_dispatch_state_grace_ms
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id} = issue, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states, [])
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  # A by-id read carries no repo key, so the dispatch's goes on the refreshed issue before its gates
  # are read again: without it its holds would read as none, and a held ticket would dispatch.
  defp revalidate_issue_for_dispatch(%Issue{id: issue_id} = issue, issue_fetcher, terminal_states, opts)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) and is_list(opts) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        refreshed_issue = freeze_issue_repo_key(refreshed_issue, issue_repo_key(refreshed_issue) || Keyword.get(opts, :repo_key) || issue_repo_key(issue))
        judge_revalidated_issue(refreshed_issue, issue, terminal_states, opts)

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states, _opts), do: {:ok, issue}

  defp judge_revalidated_issue(refreshed_issue, issue, terminal_states, opts) do
    source = Keyword.get(opts, :source, :poll)

    if dispatch_revalidated_issue?(refreshed_issue, terminal_states, Keyword.get(opts, :sticky_route?, false)) and
         unmoved_since?(refreshed_issue, issue, source) do
      {:ok, revalidated_issue(refreshed_issue, issue, source)}
    else
      {:skip, refreshed_issue}
    end
  end

  # From the record, the issue starts only when its record still says what the candidate said: the
  # same phase, and a Linear `updatedAt` no older than the candidate's. A by-id read of Linear is
  # judged by the gates alone, as it always was.
  defp unmoved_since?(_refreshed_issue, _issue, :poll), do: true

  defp unmoved_since?(%Issue{} = recorded, %Issue{} = issue, :record) do
    normalize_issue_state(recorded.state) == normalize_issue_state(issue.state) and not older?(recorded.updated_at, issue.updated_at)
  end

  defp older?(%DateTime{} = recorded_at, %DateTime{} = candidate_at), do: DateTime.compare(recorded_at, candidate_at) == :lt
  defp older?(_recorded_at, _candidate_at), do: false

  # The issue the run starts with: Linear's read, or under `record` the record's fields over the text
  # the candidate carries, as dispatch from the record builds it.
  defp revalidated_issue(refreshed_issue, _issue, :poll), do: refreshed_issue
  defp revalidated_issue(recorded, issue, :record), do: with_held_text(recorded, issue)

  defp dispatch_revalidated_issue?(%Issue{} = issue, terminal_states, true),
    do: active_retry_issue?(issue, terminal_states) and !flow_gated?(issue)

  defp dispatch_revalidated_issue?(%Issue{} = issue, terminal_states, _sticky_route?), do: retry_candidate_issue?(issue, terminal_states)

  defp complete_issue(%State{} = state, issue_id, running_entry) do
    state = delete_persisted_retry(state, issue_id, running_repo_key(state, running_entry))
    state = remember_completed_run(state, issue_id, running_entry)

    %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = max(retry_delay(next_attempt, metadata), RateLimit.remaining_pause_ms())
    old_timer = Map.get(previous_retry, :timer_ref)
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    title = pick_retry_title(state, issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    reason = metadata[:reason] || Map.get(previous_retry, :reason)
    elapsed_ms = metadata[:elapsed_ms] || Map.get(previous_retry, :elapsed_ms)
    delay_type = retry_delay_type(metadata)
    repo_key = retry_repo_key(state, metadata, previous_retry)
    usage_limit_key = if delay_type == :usage_limit, do: metadata[:usage_limit_key]

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    persist_retry(%{
      repo_key: repo_key,
      issue_id: issue_id,
      identifier: identifier,
      title: title,
      attempt: next_attempt,
      due_at: DateTime.add(DateTime.utc_now(), delay_ms, :millisecond),
      error: error,
      worker_host: worker_host,
      workspace_path: workspace_path,
      reason: reason,
      elapsed_ms: elapsed_ms,
      delay_type: delay_type,
      usage_limit_key: usage_limit_key,
      updated_at: DateTime.utc_now()
    })

    retry_token = make_ref()
    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            title: title,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            reason: reason,
            elapsed_ms: elapsed_ms,
            delay_type: delay_type,
            usage_limit_key: usage_limit_key,
            repo_key: repo_key
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          title: Map.get(retry_entry, :title),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          reason: Map.get(retry_entry, :reason),
          elapsed_ms: Map.get(retry_entry, :elapsed_ms),
          continuation: Map.get(retry_entry, :delay_type) == :continuation,
          repo_key: Map.get(retry_entry, :repo_key)
        }

        state = delete_persisted_retry(state, issue_id, retry_repo_key(state, retry_entry, %{}))
        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  # The issue is read again in a task; its claim stays held until the answer is handled, so no poll
  # dispatches it meanwhile. The read is written into the ticket's record, as every by-id read is, so
  # the revalidation from the record under `dispatch.source: record` is not older than it.
  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    context = %{kind: :retry_refresh, issue_ids: [issue_id], attempt: attempt, metadata: metadata}
    {:noreply, start_tracker_task(state, context, fn -> fetch_observed_issues_by_ids([issue_id]) end)}
  end

  defp handle_retry_refresh_result(%State{} = state, issue_id, attempt, metadata, {:ok, issues}) do
    issues
    |> find_issue_by_id(issue_id)
    |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)
  end

  defp handle_retry_refresh_result(%State{} = state, issue_id, attempt, metadata, {:error, reason}),
    do: retry_issue_refresh_failed(state, issue_id, attempt, metadata, reason)

  defp retry_issue_refresh_failed(%State{} = state, issue_id, attempt, metadata, reason) do
    Logger.warning("Retry issue refresh failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

    {:noreply,
     schedule_issue_retry(
       state,
       issue_id,
       retry_attempt_after_refresh_failure(attempt, reason),
       metadata
       |> Map.merge(%{error: "retry issue refresh failed: #{inspect(reason)}"})
       |> linear_wait_metadata(reason)
     )}
  end

  # A Linear rate limit or a dropped connection is not the issue's fault; keep its
  # attempt where it was and let schedule_issue_retry/4 wait for Linear.
  defp retry_attempt_after_refresh_failure(attempt, reason) do
    if TransientRetry.transient?(reason), do: retry_attempt(attempt), else: retry_attempt(attempt) + 1
  end

  defp handle_retry_issue_sync_for_test(%State{} = state, issue_id, attempt, metadata, issue_fetcher)
       when is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup_sync_for_test(state, issue_id, attempt, metadata)

      {:error, reason} ->
        retry_issue_refresh_failed(state, issue_id, attempt, metadata, reason)
    end
  end

  defp handle_retry_issue_lookup_sync_for_test(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    if active_retry_issue?(issue, terminal_states) do
      issue = freeze_issue_repo_key(issue, retry_repo_key(state, metadata, %{}))
      {:noreply, handle_active_retry_after_readiness(state, issue, attempt, metadata)}
    else
      handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    end
  end

  defp handle_retry_issue_lookup_sync_for_test(nil, state, issue_id, attempt, metadata) do
    handle_retry_issue_lookup(nil, state, issue_id, attempt, metadata)
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()
    # A refetched issue carries no repo key; without the retry's, its repo's settings (the phase
    # state names, the reviewer) would not be read.
    issue = freeze_issue_repo_key(issue, issue_repo_key(issue) || retry_repo_key(state, metadata, %{}))

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        state = maybe_emit_issue_completed(state, issue)

        issue
        |> terminal_workspace_context(retry_repo_key(state, metadata, %{}))
        |> cleanup_issue_workspace(metadata[:worker_host])

        {:noreply, state |> forget_completed_issue(issue_id) |> release_issue_claim(issue_id)}

      not issue_routable_to_worker?(issue) ->
        Logger.info("Dropping retry of #{issue_context(issue)}: not assigned to this Symphony's worker; releasing its claim")
        {:noreply, %{state | watching: Map.delete(state.watching, issue_id)} |> release_issue_claim(issue_id)}

      quiet_continuation?(issue, state, metadata) ->
        on_pushed = &handle_quiet_handoff(&1, issue, attempt, metadata)
        handle_pushed_quiet_issue(state, issue, issue_id, attempt, metadata, on_pushed)

      active_retry_issue?(issue, terminal_states) ->
        issue = freeze_issue_repo_key(issue, retry_repo_key(state, metadata, %{}))
        handle_quality_gated_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        state =
          if watching_issue_state?(issue.state, active_state_set(), terminal_states) do
            put_watching_issue(state, issue)
          else
            %{state | watching: Map.delete(state.watching, issue_id)}
          end

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, state |> forget_completed_issue(issue_id) |> release_issue_claim(issue_id)}
  end

  # A quiet issue whose workspace holds unpushed commits is looked up again, now marked, so it is
  # dispatched to push them; one with everything pushed takes `on_pushed`.
  defp handle_pushed_quiet_issue(state, issue, issue_id, attempt, metadata, on_pushed) do
    case keep_unpushed_issue_active(state, issue, metadata) do
      {:unpushed, state} -> handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
      :pushed -> on_pushed.(state)
    end
  end

  # The run that last worked on the PR ended with commits in its workspace that no remote has, so
  # the PR is still on its old head. Moving on would put that old head through review, so the
  # issue stays active, and the marker on its completed run lets it be dispatched again to review
  # and push them. The next run's completion replaces the marker.
  defp keep_unpushed_issue_active(%State{} = state, %Issue{id: issue_id} = issue, metadata) do
    completed_metadata = Map.get(state.completed_run_metadata, issue_id, %{})
    workspace = metadata[:workspace_path] || Map.get(completed_metadata, :workspace_path)
    worker_host = metadata[:worker_host] || Map.get(completed_metadata, :worker_host)

    case WorkspaceHead.unpushed_head(workspace, worker_host) do
      nil ->
        :pushed

      head ->
        Logger.warning("Not handing #{issue_context(issue)} off: its workspace HEAD #{head} has commits its PR does not; keeping it in #{issue.state}")
        completed_metadata = Map.put(completed_metadata, :unpushed_head, head)
        {:unpushed, %{state | completed_run_metadata: Map.put(state.completed_run_metadata, issue_id, completed_metadata)}}
    end
  end

  # A ticket whose run went quiet on its PR without the handoff signal. The runner hands off
  # a run whose PR is on its workspace HEAD, so one left here could not show that; each successor
  # would stop the same way, so instead of continuing every second its runs back off and, after
  # `@max_quiet_handoff_runs` on the same head, it is held with `handoff_missing` until a person
  # unblocks it. A new commit starts the count again. A ticket on a hold, such as one waiting on its
  # decision request, went quiet because it waits, not because a handoff is missing: it is not
  # counted, and the claim is released below so the hold alone says when it runs again.
  defp quiet_continuation?(%Issue{} = issue, %State{} = state, metadata) do
    metadata[:continuation] == true and Handoff.origin?(issue.state) and quiet_post_pr_issue?(issue, state) and
      not hold?(issue)
  end

  defp handle_quiet_handoff(%State{} = state, %Issue{id: issue_id} = issue, attempt, metadata) do
    completed_metadata = Map.get(state.completed_run_metadata, issue_id, %{})
    workspace = metadata[:workspace_path] || Map.get(completed_metadata, :workspace_path)
    head = WorkspaceHead.read(workspace, metadata[:worker_host] || Map.get(completed_metadata, :worker_host))

    quiet_runs =
      case Map.get(state.quiet_handoff_runs, issue_id) do
        {^head, count} -> count + 1
        _other_head -> 1
      end

    if quiet_runs >= @max_quiet_handoff_runs do
      hold_quiet_handoff(state, issue, head, quiet_runs)
    else
      Logger.warning("#{issue_context(issue)} went quiet on its PR without the handoff signal (#{quiet_runs} of #{@max_quiet_handoff_runs}); backing off")
      state = %{state | quiet_handoff_runs: Map.put(state.quiet_handoff_runs, issue_id, {head, quiet_runs})}
      retry_metadata = metadata |> Map.drop([:continuation, :delay_type]) |> Map.put(:error, Handoff.missing_signal())

      {:noreply, schedule_issue_retry(state, issue_id, max(attempt, quiet_runs) + 1, retry_metadata)}
    end
  end

  defp hold_quiet_handoff(%State{} = state, %Issue{id: issue_id} = issue, head, quiet_runs) do
    repo_key = issue_repo_key(issue)

    attrs = %{
      reason: "#{Handoff.missing_signal()}: #{quiet_runs} runs went quiet on the PR without handing it off",
      clearing_condition: "when a person unblocks it",
      waits_on: %{type: Handoff.missing_signal(), keys: Enum.reject([head], &is_nil/1)}
    }

    # A store write that fails is as best-effort as the ledger's: the claim is released either way.
    _ = Hold.set(repo_key, issue_id, :blocked, attrs)
    Logger.warning("Holding #{issue_context(issue)}: #{attrs.reason}")

    record_ticket_signal(issue, Handoff.missing_signal(), %{head: head, quiet_runs: quiet_runs, held: true})
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp dispatch_refresh_error(reason) do
    if TransientRetry.transient?(reason) do
      "waiting for Linear before dispatch: #{inspect(reason)}"
    else
      "retry issue refresh failed: #{inspect(reason)}"
    end
  end

  # The removal runs the repo's before_remove hook and git under the repo's fetch lock, which
  # can take minutes, so it is queued with WorkspaceCleanup and the orchestrator moves on. A run
  # of the same issue waits for it before it creates the workspace again.
  defp cleanup_issue_workspace(%{identifier: identifier} = issue, worker_host) when is_binary(identifier) do
    WorkspaceCleanup.remove(issue, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  # The operator pause is checked before the quality gate and readiness tasks, so a paused
  # Symphony reports the pause whatever else is in flight.
  defp handle_quality_gated_active_retry(%State{} = state, %Issue{} = issue, attempt, metadata) do
    state =
      if operator_paused?(state) do
        defer_retry_for_operator_pause(state, issue, attempt, metadata)
      else
        start_quality_gate_or_dispatch([issue], state, {:active_retry, issue, attempt, metadata})
      end

    {:noreply, state}
  end

  defp check_tracker_workflow_states do
    settings = Config.settings!()

    case Config.repos() do
      {:ok, repos} ->
        teams = StateProvisioning.configured_teams(settings, repos)
        # The machine-owned states and labels are created before the checks that read them, so a
        # state a later feature needs exists by the time that feature looks for it.
        StateProvisioning.provision(settings, teams)
        SubIssueWait.check_tracker_state(settings, teams)

      {:error, reason} ->
        Logger.warning("Skipping the waiting-on-sub-issues state check; failed to load repositories: #{inspect(reason)}")
    end

    RetiredStates.report()
  end

  defp startup_candidate_issues_result do
    Tracker.fetch_candidate_issues()
  end

  defp startup_terminal_issues_result do
    Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states)
  end

  defp log_startup_terminal_workspace_cleanup_result({:ok, _issues}), do: :ok

  defp log_startup_terminal_workspace_cleanup_result({:error, reason}) do
    Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
  end

  defp run_terminal_workspace_cleanup(repo_key, {:ok, issues}) do
    issues
    |> Enum.each(fn
      %Issue{} = issue ->
        issue
        |> terminal_workspace_context(repo_key)
        |> cleanup_issue_workspace(nil)

      _ ->
        :ok
    end)
  end

  defp run_terminal_workspace_cleanup(_repo_key, {:error, _reason}), do: :ok

  defp start_startup_workspace_lifecycle_task(repo_keys, now_ms) when is_list(repo_keys) do
    start_async_task(fn ->
      check_tracker_workflow_states()
      candidate_issues_result = startup_candidate_issues_result()
      terminal_issues_result = startup_terminal_issues_result()

      tracked_issue_identifiers_result =
        startup_tracked_issue_identifiers(candidate_issues_result, terminal_issues_result)

      log_startup_terminal_workspace_cleanup_result(terminal_issues_result)

      repo_results =
        Enum.map(repo_keys, fn repo_key ->
          run_terminal_workspace_cleanup(repo_key, terminal_issues_result)

          {repo_key,
           %{
             orphan_sweep_result: startup_orphan_sweep_result(repo_key, tracked_issue_identifiers_result),
             age_gc_scan: Workspace.scan_stale_workspaces(repo_key, DateTime.utc_now())
           }}
        end)

      {:startup_workspace_lifecycle_result,
       %{
         now_ms: now_ms,
         repo_results: repo_results,
         quota: workspace_quota_status_from_config()
       }}
    end)
  end

  defp apply_startup_workspace_lifecycle_result(%State{} = state, %{
         now_ms: now_ms,
         repo_results: repo_results,
         quota: quota
       }) do
    state
    |> apply_startup_orphan_sweep_results(repo_results)
    |> apply_startup_workspace_age_gc_scans(repo_results, now_ms)
    |> Map.put(:workspace_lifecycle_last_check_at_ms, now_ms)
    |> apply_workspace_quota_result(quota)
  end

  defp apply_startup_workspace_lifecycle_result(%State{} = state, result) do
    Logger.warning("Ignoring invalid startup workspace lifecycle result: #{inspect(result)}")
    state
  end

  defp startup_orphan_sweep_result(repo_key, tracked_issue_identifiers_result) do
    with {:ok, tracked_identifiers} <-
           startup_tracked_workspace_identifiers(repo_key, tracked_issue_identifiers_result) do
      case Workspace.sweep_orphan_workspaces(repo_key, tracked_identifiers) do
        {:ok, actions} -> {:ok, actions}
        {:error, reason} -> {:workspace_error, reason}
      end
    end
  end

  defp apply_startup_orphan_sweep_results(%State{} = state, repo_results) when is_list(repo_results) do
    Enum.reduce(repo_results, state, fn
      {_repo_key, %{orphan_sweep_result: orphan_sweep_result}}, acc ->
        apply_startup_orphan_sweep_result(acc, orphan_sweep_result)

      result, acc ->
        Logger.warning("Ignoring invalid startup repo lifecycle result: #{inspect(result)}")
        acc
    end)
  end

  defp apply_startup_orphan_sweep_result(%State{} = state, {:ok, actions}) do
    log_workspace_lifecycle_summary("startup orphan sweep", actions)
    state
  end

  defp apply_startup_orphan_sweep_result(%State{} = state, {:workspace_error, reason}) do
    Logger.warning("Skipping startup orphan workspace sweep; failed to scan workspace root: #{inspect(reason)}")
    state
  end

  defp apply_startup_orphan_sweep_result(%State{} = state, {:error, reason}) do
    Logger.warning("Skipping startup orphan workspace sweep; failed to fetch tracked issue identifiers: #{inspect(reason)}")
    state
  end

  defp apply_startup_orphan_sweep_result(%State{} = state, result) do
    Logger.warning("Ignoring invalid startup orphan sweep result: #{inspect(result)}")
    state
  end

  # The scan ran in the async startup task; only the cheap protected-identifier
  # filter and the bounded deletes run here, against the current active set, so
  # workspaces that became active during startup are never reclaimed.
  defp apply_startup_workspace_age_gc_scans(%State{} = state, repo_results, now_ms) when is_list(repo_results) do
    Enum.reduce(repo_results, state, fn
      {repo_key, %{age_gc_scan: age_gc_scan}}, acc ->
        apply_startup_workspace_age_gc_scan(acc, repo_key, age_gc_scan, now_ms)

      result, acc ->
        Logger.warning("Ignoring invalid startup repo age GC result: #{inspect(result)}")
        acc
    end)
  end

  defp apply_startup_workspace_age_gc_scan(%State{} = state, repo_key, {:ok, stale_entries}, now_ms) do
    actions = Workspace.delete_stale_workspaces(stale_entries, active_workspace_identifiers_for_repo(state, repo_key))
    apply_workspace_age_gc_result(state, {:ran, {:ok, actions}}, now_ms)
  end

  defp apply_startup_workspace_age_gc_scan(%State{} = state, _repo_key, {:error, reason}, now_ms) do
    apply_workspace_age_gc_result(state, {:ran, {:error, reason}}, now_ms)
  end

  defp apply_startup_workspace_age_gc_scan(%State{} = state, _repo_key, other, now_ms) do
    apply_workspace_age_gc_result(state, {:ran, other}, now_ms)
  end

  defp startup_tracked_issue_identifiers({:ok, candidate_issues}, {:ok, terminal_issues}) do
    {:ok, issue_identifiers(candidate_issues ++ terminal_issues)}
  end

  defp startup_tracked_issue_identifiers({:error, reason}, _terminal_issues_result), do: {:error, reason}
  defp startup_tracked_issue_identifiers(_candidate_issues_result, {:error, reason}), do: {:error, reason}

  defp startup_tracked_workspace_identifiers(repo_key, {:ok, tracked_issue_identifiers}) do
    with run_identifiers when is_list(run_identifiers) <- RunStore.list_run_identifiers(repo_key),
         retries when is_list(retries) <- RunStore.list_retries(repo_key) do
      identifiers =
        tracked_issue_identifiers ++ run_identifiers ++ retry_identifiers(retries)

      {:ok, identifiers}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp startup_tracked_workspace_identifiers(_repo_key, {:error, reason}), do: {:error, reason}

  defp workspace_age_gc_due?(%State{} = state, now_ms) do
    lifecycle = Config.settings!().workspace.lifecycle

    lifecycle.age_gc_enabled == true and
      (is_nil(state.workspace_lifecycle_last_check_at_ms) or
         now_ms - state.workspace_lifecycle_last_check_at_ms >= lifecycle.gc_interval_ms)
  end

  defp workspace_age_gc_result(repo_keys, active_identifiers_by_repo) when is_list(repo_keys) do
    action_chunks =
      Enum.reduce(repo_keys, [], fn repo_key, action_chunks ->
        active_identifiers = Map.get(active_identifiers_by_repo, repo_key, [])

        case Workspace.reclaim_stale_workspaces(repo_key, active_identifiers) do
          {:ok, repo_actions} ->
            [repo_actions | action_chunks]

          {:error, reason} ->
            Logger.warning("Skipping workspace age GC for repo_key=#{repo_key}; failed to scan workspace root: #{inspect(reason)}")
            action_chunks
        end
      end)

    {:ok, action_chunks |> Enum.reverse() |> List.flatten()}
  end

  defp apply_workspace_age_gc_result(%State{} = state, :skipped, _now_ms), do: state

  defp apply_workspace_age_gc_result(%State{} = state, {:ran, {:ok, actions}}, now_ms) do
    log_workspace_lifecycle_summary("age GC", actions)
    %{state | workspace_lifecycle_last_check_at_ms: now_ms}
  end

  defp apply_workspace_age_gc_result(%State{} = state, {:ran, {:error, reason}}, now_ms) do
    Logger.warning("Skipping workspace age GC; failed to scan workspace root: #{inspect(reason)}")
    %{state | workspace_lifecycle_last_check_at_ms: now_ms}
  end

  defp apply_workspace_age_gc_result(%State{} = state, result, _now_ms) do
    Logger.warning("Ignoring invalid workspace age GC result: #{inspect(result)}")
    state
  end

  defp log_workspace_lifecycle_summary(_label, []), do: :ok

  defp log_workspace_lifecycle_summary(label, actions) when is_list(actions) do
    counts =
      actions
      |> Enum.map(&Map.get(&1, :action, :unknown))
      |> Enum.frequencies()

    Logger.warning("Workspace #{label} completed count=#{length(actions)} actions=#{inspect(counts)}")
  end

  defp active_workspace_identifiers_for_repo(%State{} = state, repo_key) do
    state
    |> active_workspace_identifiers_by_repo()
    |> Map.get(repo_key, [])
  end

  defp active_workspace_identifiers_by_repo(%State{} = state) do
    state.running
    |> Map.values()
    |> Enum.reduce(%{}, fn running_entry, acc ->
      repo_key = Map.get(running_entry, :repo_key) || state.repo_key
      identifiers = running_workspace_identifiers(running_entry)
      Map.update(acc, repo_key, identifiers, &(identifiers ++ &1))
    end)
  end

  # Workspaces other running or retrying issues in the same repo own, a retry whose issue is being
  # read again included. The dispatched agent must not detach their worktrees to take over a shared
  # PR branch (see `Workspace.create_for_issue/4`).
  defp sibling_active_workspace_identifiers(%State{} = state, issue_id, repo_key) do
    running =
      state.running
      |> Enum.reject(fn {running_id, _entry} -> running_id == issue_id end)
      |> Enum.filter(fn {_id, entry} -> (Map.get(entry, :repo_key) || state.repo_key) == repo_key end)
      |> Enum.flat_map(fn {_id, entry} -> running_workspace_identifiers(entry) end)

    refreshing =
      for {_ref, %{kind: :retry_refresh, issue_ids: [retry_id], metadata: metadata}} <- state.tracker_tasks,
          do: {retry_id, metadata}

    retrying =
      state.retry_attempts
      |> Enum.concat(refreshing)
      |> Enum.reject(fn {retry_id, _retry} -> retry_id == issue_id end)
      |> Enum.filter(fn {_id, retry} -> (Map.get(retry, :repo_key) || state.repo_key) == repo_key end)
      |> Enum.map(fn {_id, retry} -> retry end)
      |> retry_identifiers()

    Enum.uniq(running ++ retrying)
  end

  defp running_workspace_identifiers(running_entry) do
    [
      Map.get(running_entry, :identifier),
      running_entry |> Map.get(:issue) |> issue_identifier(),
      running_entry |> Map.get(:workspace_path) |> workspace_identifier_from_path()
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp issue_identifiers(issues) when is_list(issues) do
    Enum.flat_map(issues, fn
      %Issue{identifier: identifier} when is_binary(identifier) -> [identifier]
      %{identifier: identifier} when is_binary(identifier) -> [identifier]
      _ -> []
    end)
  end

  defp retry_identifiers(retries) when is_list(retries) do
    Enum.flat_map(retries, fn retry ->
      [
        Map.get(retry, :identifier),
        retry |> Map.get(:workspace_path) |> workspace_identifier_from_path()
      ]
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp workspace_identifier_from_path(path) when is_binary(path), do: Path.basename(path)
  defp workspace_identifier_from_path(_path), do: nil

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp notify_transcript(repo_key, issue_id, event) when is_binary(repo_key) and is_binary(issue_id) do
    ObservabilityPubSub.broadcast_transcript_event(repo_key, issue_id, event)
  end

  defp notify_transcript(_repo_key, _issue_id, _event), do: :ok

  # The audit writes go to AuditLog.Writer: done here, they held up every update (and the state
  # API) for as long as the audit log's lock and the disk took.
  defp audit_agent_update(running_entry, update, token_delta) do
    AuditLog.Writer.record_agent_update(running_entry, update, token_delta)
  end

  defp maybe_emit_pr_opened(previous_entry, updated_entry) when is_map(updated_entry) do
    pr_url = URLUtils.pull_request_url(updated_entry)

    if is_nil(URLUtils.pull_request_url(previous_entry)) and is_binary(pr_url) do
      AuditLog.Writer.record_pr_opened(updated_entry, pr_url)
      emit_running_event(:pr_opened, updated_entry)
    end
  end

  defp maybe_emit_awaiting_review(state, issue, source)

  defp maybe_emit_awaiting_review(%State{} = state, %Issue{state: issue_state} = issue, source) do
    if PlanReview.in_state?(issue_state) do
      maybe_emit_lifecycle_event(state, :awaiting_review, issue, source)
    else
      state
    end
  end

  defp maybe_emit_awaiting_review(state, _issue, _source), do: state

  defp maybe_emit_issue_completed(state, issue, source \\ %{})

  defp maybe_emit_issue_completed(%State{} = state, %Issue{state: issue_state} = issue, source) do
    if done_state?(issue_state) do
      attrs = completion_attrs(issue)
      maybe_emit_lifecycle_event(state, :issue_completed, issue, source, close_watch: true, attrs: attrs)
    else
      state
    end
  end

  defp maybe_emit_issue_completed(state, _issue, _source), do: state

  # The plan the ticket belongs to, kept on its run record for `/api/v1/shipped` after the plan
  # leaves the Initiatives cache.
  defp completion_attrs(%Issue{id: issue_id}), do: put_present(%{}, :initiative, Initiatives.parent_of(issue_id))

  defp maybe_emit_lifecycle_event(state, event, issue, source, opts \\ [])

  defp maybe_emit_lifecycle_event(%State{} = state, event, %Issue{id: issue_id} = issue, source, opts)
       when is_binary(issue_id) do
    marker = lifecycle_notification_marker(event)
    metadata = lifecycle_metadata(state, issue_id, source)

    if lifecycle_event_notified?(metadata, marker) do
      state
    else
      Notifications.emit_issue_event(event, issue, lifecycle_notification_attrs(state, metadata))

      state
      |> mark_lifecycle_event_notified(issue_id, metadata, marker, issue.state, opts)
      |> maybe_record_shipped(event, issue, metadata)
    end
  end

  defp maybe_emit_lifecycle_event(state, _event, _issue, _source, _opts), do: state

  # Today's shipped tickets for `/api/v1/state`; entries from an earlier local day are dropped.
  defp maybe_record_shipped(%State{} = state, :issue_completed, %Issue{id: issue_id} = issue, metadata) do
    now = DateTime.utc_now()

    entry = %{
      issue_id: issue_id,
      identifier: issue.identifier,
      title: issue.title,
      repo_key: issue.repo_key || Map.get(metadata, :repo_key),
      completed_at: now
    }

    %{state | shipped: ShippedToday.record(state.shipped, entry, now)}
  end

  defp maybe_record_shipped(state, _event, _issue, _metadata), do: state

  defp lifecycle_notification_marker(:awaiting_review), do: :awaiting_review_notified_at
  defp lifecycle_notification_marker(:issue_completed), do: :issue_completed_notified_at

  defp lifecycle_event_notified?(metadata, marker) when is_map(metadata), do: present_value?(Map.get(metadata, marker))

  defp lifecycle_metadata(%State{} = state, issue_id, source) do
    state.completed_run_metadata
    |> Map.get(issue_id, %{})
    |> Map.merge(lifecycle_source_metadata(source))
    |> maybe_merge_lifecycle_run_store_metadata(issue_id)
    |> Map.put_new(:repo_key, state.repo_key)
  end

  defp maybe_merge_lifecycle_run_store_metadata(%{run_id: run_id} = metadata, _issue_id) when is_binary(run_id), do: metadata

  defp maybe_merge_lifecycle_run_store_metadata(metadata, issue_id) do
    issue_id
    |> lifecycle_run_store_metadata()
    |> Map.merge(metadata)
  end

  @watchable_run_statuses ["success", "stopped"]

  defp lifecycle_run_store_metadata(issue_id) when is_binary(issue_id) do
    case RunStore.list_all_runs(500) do
      runs when is_list(runs) ->
        runs
        |> Enum.find(&(Map.get(&1, :issue_id) == issue_id and Map.get(&1, :status) in @watchable_run_statuses))
        |> lifecycle_source_metadata()

      _ ->
        %{}
    end
  end

  defp lifecycle_source_metadata(source) when is_map(source) do
    %{}
    |> put_present(:repo_key, Map.get(source, :repo_key))
    |> put_present(:run_id, Map.get(source, :run_id))
    |> put_present(:session_id, Map.get(source, :session_id))
    |> put_present(:pull_request_url, URLUtils.pull_request_url(source))
    |> put_present(:awaiting_review_notified_at, Map.get(source, :awaiting_review_notified_at))
    |> put_present(:issue_completed_notified_at, Map.get(source, :issue_completed_notified_at))
    |> put_present(:watch_closed_at, Map.get(source, :watch_closed_at))
    |> put_present(:tokens, lifecycle_tokens(source))
  end

  defp lifecycle_source_metadata(_source), do: %{}

  defp lifecycle_tokens(%{tokens: tokens}) when is_map(tokens), do: tokens

  defp lifecycle_tokens(source) when is_map(source) do
    if Map.has_key?(source, :codex_total_tokens), do: run_tokens(source)
  end

  defp lifecycle_notification_attrs(%State{} = state, metadata) when is_map(metadata) do
    %{}
    |> put_present(:repo_key, Map.get(metadata, :repo_key) || state.repo_key)
    |> put_present(:run_id, Map.get(metadata, :run_id))
    |> put_present(:session_id, Map.get(metadata, :session_id))
    |> put_present(:pr_url, URLUtils.pull_request_url(metadata))
    |> put_present(:tokens, Map.get(metadata, :tokens))
  end

  defp mark_lifecycle_event_notified(%State{} = state, issue_id, metadata, marker, issue_state, opts) do
    now = DateTime.utc_now()

    attrs =
      %{
        marker => now,
        last_observed_state: issue_state,
        updated_at: now
      }
      |> maybe_put_watch_closed_at(now, Keyword.get(opts, :close_watch, false))
      |> Map.merge(Keyword.get(opts, :attrs, %{}))

    persist_lifecycle_event_marker(state, metadata, attrs)
    update_completed_run_metadata(state, issue_id, attrs, Keyword.get(opts, :close_watch, false))
  end

  defp maybe_put_watch_closed_at(attrs, now, true), do: Map.put(attrs, :watch_closed_at, now)
  defp maybe_put_watch_closed_at(attrs, _now, _close_watch?), do: attrs

  defp persist_lifecycle_event_marker(%State{} = state, metadata, attrs) when is_map(metadata) do
    repo_key = Map.get(metadata, :repo_key) || state.repo_key
    run_id = Map.get(metadata, :run_id)

    if is_binary(repo_key) and is_binary(run_id) do
      repo_key
      |> RunStore.update_run(run_id, attrs)
      |> ignore_missing_run()
      |> log_run_store_error("persist lifecycle notification marker")
    end
  end

  defp update_completed_run_metadata(%State{} = state, issue_id, attrs, _close_watch?) do
    if Map.has_key?(state.completed_run_metadata, issue_id) do
      %{state | completed_run_metadata: Map.update!(state.completed_run_metadata, issue_id, &Map.merge(&1, attrs))}
    else
      state
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp emit_run_failed(running_entry, reason, next_attempt) when is_map(running_entry) do
    emit_running_event(:run_failed, running_entry, %{
      reason: reason,
      attempt: next_attempt,
      metadata: %{source: "orchestrator"}
    })
  end

  defp emit_run_stuck(running_entry, elapsed_ms, next_attempt) when is_map(running_entry) do
    emit_running_event(:run_stuck, running_entry, %{
      reason: "stuck",
      attempt: next_attempt,
      metadata: %{source: "orchestrator", reason: "stuck", elapsed_ms: elapsed_ms}
    })
  end

  defp maybe_emit_daily_budget_exceeded(
         %State{} = state_after_tokens,
         %State{} = state_before_tokens,
         issue_id,
         running_entry
       ) do
    daily_budget_just_logged? =
      state_before_tokens.budget_daily_paused_logged != true and
        state_after_tokens.budget_daily_paused_logged == true

    if daily_budget_just_logged? do
      limit = Config.settings!().agent.max_tokens_per_day

      emit_running_event(:budget_exceeded, running_entry, %{
        reason: "daily token budget exhausted: daily_used=#{state_after_tokens.budget_daily_used} limit=#{limit}",
        issue_id: issue_id,
        tokens: %{total_tokens: state_after_tokens.budget_daily_used},
        metadata: %{source: "orchestrator", scope: "day", limit: limit}
      })
    end

    state_after_tokens
  end

  defp maybe_emit_daily_budget_exceeded(state, _state_before_tokens, _issue_id, _running_entry), do: state

  defp emit_budget_exceeded(running_entry, attrs) when is_map(running_entry) and is_map(attrs) do
    attrs = Map.merge(%{metadata: %{source: "orchestrator", scope: "issue"}}, attrs)
    emit_running_event(:budget_exceeded, running_entry, attrs)
  end

  defp emit_running_event(event, running_entry, attrs \\ %{}) when is_map(running_entry) and is_map(attrs) do
    issue = Map.get(running_entry, :issue)

    attrs =
      attrs
      |> Map.put_new(:run_id, Map.get(running_entry, :run_id))
      |> Map.put_new(:repo_key, Map.get(running_entry, :repo_key))
      |> Map.put_new(:session_id, Map.get(running_entry, :session_id))
      |> Map.put_new(:pr_url, running_entry_pr_url(running_entry))
      |> Map.put_new(:tokens, run_tokens(running_entry))

    Notifications.emit_issue_event(event, issue, attrs)
  end

  defp done_state?(state_name) when is_binary(state_name), do: normalize_issue_state(state_name) == "done"
  defp done_state?(_state_name), do: false

  defp handle_active_retry_after_readiness(state, issue, attempt, metadata) do
    cond do
      operator_paused?(state) ->
        defer_retry_for_operator_pause(state, issue, attempt, metadata)

      hold = usage_limit_hold(state, issue, metadata[:continuation] == true) ->
        hold_retry_for_usage_limit(state, issue, attempt, metadata, hold)

      workspace_quota_paused?(state) ->
        state = log_workspace_quota_pause(state)

        schedule_issue_retry(
          state,
          issue.id,
          attempt,
          Map.merge(metadata, %{
            identifier: issue.identifier,
            title: issue.title,
            error: workspace_quota_error(state)
          })
        )

      agent_left_running?(issue) ->
        schedule_issue_retry(
          state,
          issue.id,
          attempt,
          Map.merge(metadata, %{
            identifier: issue.identifier,
            title: issue.title,
            error: "an agent from a previous Symphony may still be running in the workspace"
          })
        )

      active_retry_issue?(issue, terminal_state_set()) and
        dispatch_slots_available?(issue, state) and
          worker_slots_available?(state, metadata[:worker_host]) ->
        dispatch_issue(state, issue, attempt, metadata[:worker_host])

      true ->
        Logger.debug("No available slots for retrying #{issue_context(issue)}; waiting for a slot")
        wait_for_slot(state, issue, attempt, metadata, "no available orchestrator slots")
    end
  end

  defp defer_retry_for_operator_pause(%State{} = state, %Issue{} = issue, attempt, metadata) do
    state
    |> log_operator_pause()
    |> schedule_issue_retry(
      issue.id,
      attempt,
      Map.merge(metadata, %{
        identifier: issue.identifier,
        title: issue.title,
        error: "dispatch paused by operator"
      })
    )
  end

  defp hold_retry_for_usage_limit(%State{} = state, %Issue{} = issue, attempt, metadata, entry) do
    Logger.debug("Holding retry for #{issue_context(issue)}; usage limit provider=#{entry.provider} scope=#{UsageLimit.scope_label(entry.scope)}")

    schedule_issue_retry(
      state,
      issue.id,
      retry_attempt(attempt),
      Map.merge(metadata, %{
        identifier: issue.identifier,
        title: issue.title,
        error: usage_limit_error(entry),
        delay_type: :usage_limit,
        usage_limit_key: {entry.provider, entry.scope},
        usage_limit_delay_ms: held_retry_delay_ms(entry, state.clock.())
      })
    )
  end

  # A canary hold has no time left, so a retry that comes due during the canary waits the
  # unknown-reset interval; the canary's outcome releases it sooner.
  defp held_retry_delay_ms(%{phase: :canary}, _now), do: unknown_reset_retry_ms()
  defp held_retry_delay_ms(entry, now), do: UsageLimit.remaining_ms(entry, now)

  defp unknown_reset_retry_ms, do: Config.settings!().agent.usage_limit.unknown_reset_retry_seconds * 1000

  # Waiting for a slot is not a failure: the retry leaves the backoff queue with its attempt
  # unchanged, and the poll dispatches it in stage order as soon as a slot is free.
  defp wait_for_slot(%State{} = state, %Issue{} = issue, attempt, metadata, reason) do
    waiting = %{
      attempt: attempt,
      repo_key: retry_repo_key(state, metadata, %{}),
      worker_host: metadata[:worker_host],
      since: DateTime.utc_now()
    }

    state
    |> release_issue_claim(issue.id)
    |> put_slot_waiting(issue, waiting, reason)
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    state = delete_persisted_retry(state, issue_id)
    # A released claim ends the quiet cycle, so a later one on the same head counts from zero.
    %{state | claimed: MapSet.delete(state.claimed, issue_id), quiet_handoff_runs: Map.delete(state.quiet_handoff_runs, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    case retry_delay_type(metadata) do
      :continuation when attempt == 1 -> @continuation_retry_delay_ms
      :linear_wait -> @linear_wait_retry_delay_ms
      :ci_wait -> @ci_wait_retry_delay_ms
      :usage_limit -> Map.get(metadata, :usage_limit_delay_ms, 0)
      _delay_type -> failure_retry_delay(attempt)
    end
  end

  defp retry_delay_type(%{delay_type: :continuation}), do: :continuation
  defp retry_delay_type(%{delay_type: "continuation"}), do: :continuation
  defp retry_delay_type(%{delay_type: :linear_wait}), do: :linear_wait
  defp retry_delay_type(%{delay_type: "linear_wait"}), do: :linear_wait
  defp retry_delay_type(%{delay_type: :ci_wait}), do: :ci_wait
  defp retry_delay_type(%{delay_type: "ci_wait"}), do: :ci_wait
  defp retry_delay_type(%{delay_type: :usage_limit}), do: :usage_limit
  defp retry_delay_type(%{delay_type: "usage_limit"}), do: :usage_limit
  defp retry_delay_type(_metadata), do: nil

  defp linear_wait_metadata(metadata, reason) do
    if TransientRetry.transient?(reason), do: Map.put(metadata, :delay_type, :linear_wait), else: metadata
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_title(%State{} = state, issue_id, previous_retry, metadata) do
    metadata[:title] ||
      Map.get(previous_retry, :title) ||
      running_entry_title(Map.get(state.running, issue_id)) ||
      Map.get(state.completed_run_metadata, issue_id, %{}) |> Map.get(:title) ||
      Map.get(state.watching, issue_id, %{}) |> Map.get(:title) ||
      conflict_issue_title(state, issue_id)
  end

  defp conflict_issue_title(%State{conflicts: conflicts}, issue_id) when is_map(conflicts) do
    case Map.get(conflicts, issue_id) do
      %Issue{title: title} -> title
      _ -> nil
    end
  end

  defp conflict_issue_title(_state, _issue_id), do: nil

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  # The runner reports a workspace hook as it starts, with the deadline of the hook's
  # own timeout, and as it ends (`nil`). Both count as activity.
  defp maybe_put_workspace_hook(running_entry, %{workspace_hook: workspace_hook}) do
    running_entry
    |> Map.put(:workspace_hook, workspace_hook)
    |> Map.put(:last_event_at, DateTime.utc_now())
  end

  defp maybe_put_workspace_hook(running_entry, _runtime_info), do: running_entry

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp find_running_issue(running, issue_id_or_identifier)
       when is_map(running) and is_binary(issue_id_or_identifier) do
    Enum.find_value(running, fn
      {issue_id, %{identifier: identifier} = running_entry}
      when issue_id == issue_id_or_identifier or identifier == issue_id_or_identifier ->
        {issue_id, running_entry}

      _entry ->
        nil
    end)
  end

  defp find_running_issue(_running, _issue_id_or_identifier), do: nil

  defp running_entry_repo_key(%{repo_key: repo_key}) when is_binary(repo_key), do: repo_key
  defp running_entry_repo_key(_running_entry), do: nil

  defp pr_run_entry?(%{run_kind: :pr}), do: true
  defp pr_run_entry?(%{run_kind: "pr"}), do: true
  defp pr_run_entry?(%{issue: %Issue{run_kind: :pr}}), do: true
  defp pr_run_entry?(%{issue: %Issue{run_kind: "pr"}}), do: true
  defp pr_run_entry?(_running_entry), do: false

  defp dispatch_repo_key(%State{} = state, %Issue{} = issue), do: issue_repo_key(issue) || state.repo_key
  defp dispatch_repo_key(%State{} = state, _issue), do: state.repo_key

  defp freeze_issue_repo_key(%Issue{} = issue, repo_key) when is_binary(repo_key) and repo_key != "" do
    %{issue | repo_key: repo_key}
  end

  defp freeze_issue_repo_key(%Issue{} = issue, _repo_key), do: issue

  defp running_repo_key(%State{} = state, running_entry) when is_map(running_entry) do
    running_entry_repo_key(running_entry) || state.repo_key
  end

  defp running_repo_key(%State{} = state, _running_entry), do: state.repo_key

  defp retry_repo_key(%State{} = state, metadata, previous_retry) do
    repo_key_from(metadata) || repo_key_from(previous_retry) || state.repo_key
  end

  defp retry_repo_key_from_state(%State{} = state, issue_id) when is_binary(issue_id) do
    state.retry_attempts
    |> Map.get(issue_id, %{})
    |> repo_key_from()
    |> Kernel.||(state.repo_key)
  end

  defp retry_repo_key_from_state(%State{} = state, _issue_id), do: state.repo_key

  defp issue_repo_key(%Issue{repo_key: repo_key}) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp issue_repo_key(_issue), do: nil

  # The ticket's in-flight PR, from Symphony's record. A run entry's issue may carry no repo key, so
  # the entry's own finds the record.
  defp ticket_pr_url(%Issue{} = issue, repo_key), do: TicketPullRequest.current_url(%{issue | repo_key: issue_repo_key(issue) || repo_key})
  defp ticket_pr_url(_issue, _repo_key), do: nil

  # The PR URL the run reported, else the ticket's from Symphony's record.
  defp running_entry_pr_url(running_entry) do
    URLUtils.pull_request_url(running_entry) ||
      ticket_pr_url(Map.get(running_entry, :issue), running_entry_repo_key(running_entry))
  end

  defp repo_key_from(%{repo_key: repo_key}) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp repo_key_from(%{"repo_key" => repo_key}) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp repo_key_from(_value), do: nil

  defp cleanup_agent_session_for_terminated_issue(running_entry, opts) do
    if Keyword.get(opts, :stop_agent_session, false) do
      stop_agent_session_for_stuck_issue(running_entry)
    else
      start_stop_agent_session_cleanup(running_entry, Keyword.get(opts, :error, "agent stopped by orchestrator"))
    end
  end

  defp start_stop_agent_session_cleanup(%{run_id: run_id} = running_entry, cleanup_context) do
    if stop_agent_session_configured?(running_entry),
      do: start_stop_agent_session_cleanup_task(running_entry, run_id, cleanup_context),
      else: :ok
  end

  defp start_stop_agent_session_cleanup(_running_entry, _cleanup_context), do: :ok

  defp start_stop_agent_session_cleanup_task(running_entry, run_id, cleanup_context) do
    case running_entry_repo_key(running_entry) do
      repo_key when is_binary(repo_key) ->
        start_stop_agent_session_cleanup_task(running_entry, run_id, repo_key, cleanup_context)

      _repo_key ->
        :ok
    end
  end

  defp start_stop_agent_session_cleanup_task(running_entry, run_id, repo_key, cleanup_context) do
    case start_task_supervisor_child(fn ->
           running_entry
           |> stop_agent_session_with_timeout(@stop_session_cleanup_timeout_ms)
           |> record_stop_agent_session_cleanup_result(repo_key, run_id, cleanup_context)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        record_stop_agent_session_cleanup_result(
          {:error, {:cleanup_task_start_failed, reason}},
          repo_key,
          run_id,
          cleanup_context
        )
    end
  end

  defp stop_agent_session_configured?(%{agent_module: agent_module, agent_session: session})
       when is_atom(agent_module) and not is_nil(session) do
    function_exported?(agent_module, :stop_session, 1)
  end

  defp stop_agent_session_configured?(_running_entry), do: false

  defp stop_agent_session_for_stuck_issue(running_entry) do
    if stop_agent_session_configured?(running_entry) do
      case stop_agent_session_with_timeout(running_entry, @stop_session_cleanup_timeout_ms) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Agent stop_session cleanup failed while restarting stuck issue issue_identifier=#{Map.get(running_entry, :identifier)} session_id=#{running_entry_session_id(running_entry)} reason=#{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp run_after_run_cleanup(%{workspace_path: workspace} = running_entry)
       when is_binary(workspace) and workspace != "" do
    case start_task_supervisor_child(fn ->
           Workspace.run_after_run_hook(
             workspace,
             Map.get(running_entry, :issue) || Map.get(running_entry, :identifier),
             Map.get(running_entry, :worker_host),
             repo_key: Map.get(running_entry, :repo_key)
           )
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Unable to start async after_run cleanup while restarting stuck issue issue_identifier=#{Map.get(running_entry, :identifier)} session_id=#{running_entry_session_id(running_entry)} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp run_after_run_cleanup(_running_entry), do: :ok

  defp stop_agent_session_with_timeout(running_entry, timeout_ms) do
    case start_stop_agent_session_task(running_entry) do
      {:ok, task} ->
        case Task.yield(task, timeout_ms) do
          {:ok, result} ->
            normalize_stop_session_result(result)

          {:exit, reason} ->
            {:error, {:exit, reason}}

          nil ->
            task
            |> Task.shutdown(:brutal_kill)
            |> normalize_stop_session_shutdown(timeout_ms)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_stop_agent_session_task(running_entry),
    do: start_async_task(fn -> stop_agent_session(running_entry) end)

  defp normalize_stop_session_shutdown({:ok, result}, _timeout_ms), do: normalize_stop_session_result(result)
  defp normalize_stop_session_shutdown({:exit, reason}, _timeout_ms), do: {:error, {:exit, reason}}
  defp normalize_stop_session_shutdown(nil, timeout_ms), do: {:error, {:timeout, timeout_ms}}

  defp stop_agent_session(%{agent_module: agent_module, agent_session: session})
       when is_atom(agent_module) and not is_nil(session) do
    if function_exported?(agent_module, :stop_session, 1) do
      agent_module.stop_session(session)
    end
  rescue
    exception ->
      {:error, Exception.format(:error, exception, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp stop_agent_session(_running_entry), do: :ok

  defp normalize_stop_session_result(:ok), do: :ok
  defp normalize_stop_session_result(nil), do: :ok
  defp normalize_stop_session_result({:error, reason}), do: {:error, reason}
  defp normalize_stop_session_result(other), do: {:error, {:unexpected_result, other}}

  defp record_stop_agent_session_cleanup_result(:ok, _repo_key, _run_id, _cleanup_context), do: :ok

  defp record_stop_agent_session_cleanup_result({:error, reason}, repo_key, run_id, cleanup_context)
       when is_binary(repo_key) and is_binary(run_id) do
    message = "#{cleanup_context}; stop_session cleanup failed: #{inspect(reason)}"
    Logger.warning("Agent stop_session cleanup failed while stopping issue run_id=#{run_id} reason=#{inspect(reason)}")

    repo_key
    |> RunStore.update_run(run_id, %{error: message, updated_at: DateTime.utc_now()})
    |> ignore_missing_run()
    |> log_run_store_error("record stop_session cleanup failure")
  end

  defp record_stop_agent_session_cleanup_result({:error, reason}, _repo_key, _run_id, _cleanup_context) do
    Logger.warning("Agent stop_session cleanup failed while stopping issue reason=#{inspect(reason)}")
    :ok
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        length(work_running_ids(state.running)),
      0
    )
  end

  defp ensure_run_store_started do
    case RunStore.ensure_started() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Run store unavailable; continuing without durable state reason=#{inspect(reason)}")
        :ok
    end
  end

  defp persisted_codex_totals do
    case RunStore.get_codex_totals() do
      %{} = totals ->
        Map.merge(@empty_codex_totals, totals)

      nil ->
        @empty_codex_totals

      {:error, reason} ->
        Logger.warning("Failed to read persisted codex totals: #{inspect(reason)}")
        @empty_codex_totals
    end
  end

  defp persisted_pause_state do
    case RunStore.get_paused() do
      %{} = pause ->
        Map.merge(unpaused_state(), pause)

      {:error, reason} ->
        Logger.warning("Failed to read persisted pause state: #{inspect(reason)}")
        unpaused_state()
    end
  end

  defp unpaused_state do
    %{paused: false, reason: nil, paused_at: nil}
  end

  defp hydrate_quality_gate_cache do
    case RunStore.get_quality_gate_cache() do
      %{} = cache ->
        cache

      nil ->
        %{}

      {:error, reason} ->
        Logger.warning("Failed to read persisted quality gate cache: #{inspect(reason)}")
        %{}
    end
  end

  defp persist_quality_gate_cache(cache) when is_map(cache) do
    cache
    |> RunStore.put_quality_gate_cache()
    |> log_run_store_error("persist quality gate cache")
  end

  defp persist_quality_gate_cache(_cache), do: :ok

  defp hydrate_quality_gate_comment_keys do
    case RunStore.get_quality_gate_comment_keys() do
      %MapSet{} = keys ->
        keys

      nil ->
        MapSet.new()

      {:error, reason} ->
        Logger.warning("Failed to read persisted quality gate comment keys: #{inspect(reason)}")
        MapSet.new()
    end
  end

  defp persist_quality_gate_comment_keys(%MapSet{} = keys) do
    keys
    |> RunStore.put_quality_gate_comment_keys()
    |> log_run_store_error("persist quality gate comment keys")
  end

  defp hydrate_retry_attempts do
    case RunStore.list_retries(:all) do
      retries when is_list(retries) ->
        now = DateTime.utc_now()
        now_ms = System.monotonic_time(:millisecond)

        Enum.reduce(retries, {%{}, MapSet.new()}, fn retry, {retry_attempts, claimed} ->
          hydrate_retry_attempt(retry, retry_attempts, claimed, now, now_ms)
        end)

      {:error, reason} ->
        Logger.warning("Failed to hydrate retry queue from run store: #{inspect(reason)}")
        {%{}, MapSet.new()}
    end
  end

  defp hydrate_retry_attempt(%{issue_id: issue_id} = retry, retry_attempts, claimed, now, now_ms)
       when is_binary(issue_id) do
    delay_ms = retry_due_delay_ms(Map.get(retry, :due_at), now)
    retry_token = make_ref()
    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)
    attempt = retry_attempt(Map.get(retry, :attempt))

    retry_entry = %{
      repo_key: Map.get(retry, :repo_key),
      attempt: attempt,
      timer_ref: timer_ref,
      retry_token: retry_token,
      due_at_ms: now_ms + delay_ms,
      identifier: Map.get(retry, :identifier) || issue_id,
      title: Map.get(retry, :title),
      error: Map.get(retry, :error),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      reason: Map.get(retry, :reason),
      elapsed_ms: Map.get(retry, :elapsed_ms),
      delay_type: retry_delay_type(retry),
      usage_limit_key: Map.get(retry, :usage_limit_key)
    }

    {Map.put(retry_attempts, issue_id, retry_entry), MapSet.put(claimed, issue_id)}
  end

  defp hydrate_retry_attempt(_retry, retry_attempts, claimed, _now, _now_ms), do: {retry_attempts, claimed}

  # The newest runs, read once at start for the completed run metadata and today's shipped tickets.
  defp hydrate_recent_runs do
    case RunStore.list_all_runs(500) do
      runs when is_list(runs) ->
        runs

      {:error, reason} ->
        Logger.warning("Failed to hydrate completed run metadata from run store: #{inspect(reason)}")
        []
    end
  end

  defp hydrate_completed_run_metadata(runs, retry_attempts) when is_map(retry_attempts) do
    runs
    |> Enum.filter(&(Map.get(&1, :status) in @watchable_run_statuses))
    |> Enum.reject(&(watch_closed_run?(&1) or Map.has_key?(retry_attempts, Map.get(&1, :issue_id))))
    |> Enum.filter(&(Map.get(&1, :issue_id) |> watchable_linear_issue_id?()))
    |> Enum.group_by(&Map.get(&1, :issue_id))
    |> Enum.reduce(%{}, fn {issue_id, issue_runs}, acc ->
      most_recent = List.first(issue_runs)

      metadata = %{
        repo_key: Map.get(most_recent, :repo_key) || Config.repo_key_or_nil(),
        run_id: Map.get(most_recent, :run_id),
        identifier: Map.get(most_recent, :issue_identifier),
        title: Map.get(most_recent, :title),
        state: Map.get(most_recent, :last_observed_state) || Map.get(most_recent, :state),
        url: nil,
        pull_request_url: URLUtils.pull_request_url(most_recent),
        last_ran_at: Map.get(most_recent, :ended_at) || Map.get(most_recent, :started_at),
        awaiting_review_notified_at: Map.get(most_recent, :awaiting_review_notified_at),
        issue_completed_notified_at: Map.get(most_recent, :issue_completed_notified_at),
        watch_closed_at: Map.get(most_recent, :watch_closed_at),
        session_id: Map.get(most_recent, :session_id),
        started_at: Map.get(most_recent, :started_at),
        last_event_at: Map.get(most_recent, :last_event_at) || Map.get(most_recent, :ended_at),
        turn_count: Map.get(most_recent, :turn_count, 0),
        tokens: Map.get(most_recent, :tokens, %{}),
        transcript_path: Map.get(most_recent, :transcript_path),
        transcript_buffer: transcript_buffer_list(most_recent),
        transcript_buffer_size: transcript_buffer_size(most_recent)
      }

      Map.put(acc, issue_id, metadata)
    end)
  end

  defp hydrate_completed_run_metadata(_runs, _retry_attempts), do: %{}

  defp seed_watching_from_completed_run_metadata(%State{} = state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    Enum.reduce(state.completed_run_metadata, state, fn {issue_id, metadata}, state_acc ->
      cond do
        !watchable_linear_issue_id?(issue_id) ->
          state_acc

        Map.has_key?(state_acc.retry_attempts, issue_id) ->
          state_acc

        metadata |> Map.get(:state) |> watching_issue_state?(active_states, terminal_states) ->
          put_watching_issue(state_acc, completed_metadata_issue(issue_id, metadata))

        true ->
          state_acc
      end
    end)
  end

  defp completed_metadata_issue(issue_id, metadata) when is_binary(issue_id) and is_map(metadata) do
    %Issue{
      id: issue_id,
      repo_key: Map.get(metadata, :repo_key),
      identifier: Map.get(metadata, :identifier),
      title: Map.get(metadata, :title),
      state: Map.get(metadata, :state),
      url: URLUtils.present_url(Map.get(metadata, :url))
    }
  end

  defp watch_closed_run?(run) when is_map(run) do
    present_value?(Map.get(run, :watch_closed_at)) or present_value?(Map.get(run, :issue_completed_notified_at))
  end

  defp watch_closed_run?(_run), do: false

  defp present_value?(nil), do: false
  defp present_value?(""), do: false
  defp present_value?(_value), do: true

  defp hydrate_budget_daily_used(%Date{} = day) do
    case RunStore.list_runs_started_on(day) do
      runs when is_list(runs) ->
        Enum.reduce(runs, 0, fn run, total ->
          total + run_total_tokens(run)
        end)

      {:error, reason} ->
        Logger.warning("Failed to hydrate daily token budget usage from run store: #{inspect(reason)}")
        0
    end
  end

  defp hydrate_budget_exhausted do
    case Config.settings!().agent.max_tokens_per_issue do
      limit when is_integer(limit) and limit > 0 ->
        hydrate_budget_exhausted(limit)

      _limit ->
        MapSet.new()
    end
  end

  defp hydrate_budget_exhausted(limit) do
    case RunStore.list_runs_with_status("budget_exhausted") do
      runs when is_list(runs) ->
        runs
        |> Enum.flat_map(&budget_exhausted_issue_id(&1, limit))
        |> MapSet.new()

      {:error, reason} ->
        Logger.warning("Failed to hydrate budget-exhausted issues from run store: #{inspect(reason)}")
        MapSet.new()
    end
  end

  defp budget_exhausted_issue_id(%{status: "budget_exhausted", issue_id: issue_id} = run, limit)
       when is_binary(issue_id),
       do: if(budget_exhausted_run_over_limit?(run, limit), do: [issue_id], else: [])

  defp budget_exhausted_issue_id(_run, _limit), do: []

  defp budget_exhausted_run_over_limit?(%{tokens: %{total_tokens: total}}, limit)
       when is_integer(total) do
    max(total, 0) >= limit
  end

  defp budget_exhausted_run_over_limit?(_run, _limit), do: true

  defp run_total_tokens(%{tokens: %{total_tokens: total}}) when is_integer(total), do: max(total, 0)
  defp run_total_tokens(_run), do: 0

  defp retry_due_delay_ms(%DateTime{} = due_at, %DateTime{} = now) do
    max(0, DateTime.diff(due_at, now, :millisecond))
  end

  defp retry_due_delay_ms(_due_at, _now), do: 0

  defp retry_attempt?(attempt) when is_integer(attempt) and attempt > 0, do: true
  defp retry_attempt?(_attempt), do: false

  defp retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp retry_attempt(_attempt), do: 1

  defp mark_interrupted_runs_for_configured_repos(default_repo_key) do
    default_repo_key
    |> configured_repo_keys()
    |> Enum.each(&mark_interrupted_runs/1)
  end

  defp configured_repo_keys(default_repo_key) do
    case Config.repos() do
      {:ok, repos} ->
        repos
        |> Enum.map(&Map.get(&1, :name))
        |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
        |> Enum.uniq()
        |> case do
          [] -> [default_repo_key]
          repo_keys -> repo_keys
        end

      {:error, reason} ->
        Logger.warning("Failed to read configured repos for startup run interruption; using primary repo #{default_repo_key}: #{inspect(reason)}")

        [default_repo_key]
    end
  end

  defp mark_interrupted_runs(repo_key) do
    case RunStore.interrupt_running_runs(repo_key, "orchestrator restarted before worker exit") do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.warning("Marked #{count} previously running agent run(s) as failed after orchestrator startup repo_key=#{repo_key}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to mark interrupted runs in run store repo_key=#{repo_key}: #{inspect(reason)}")
        :ok
    end
  end

  defp persisted_run_history(repo_key) do
    case RunStore.list_runs(repo_key, 50) do
      runs when is_list(runs) ->
        runs

      {:error, reason} ->
        Logger.warning("Failed to read persisted run history: #{inspect(reason)}")
        []
    end
  end

  defp persist_run_start(%Issue{} = issue, running_entry, attempt) when is_map(running_entry) do
    issue
    |> run_record(running_entry, "running", attempt_count(attempt))
    |> RunStore.put_run()
    |> log_run_store_error("persist run start")
  end

  defp persist_running_entry(running_entry) when is_map(running_entry) do
    case {running_entry_repo_key(running_entry), Map.get(running_entry, :run_id)} do
      {repo_key, run_id} when is_binary(repo_key) and is_binary(run_id) ->
        running_entry
        |> run_update_from_entry()
        |> then(&RunStore.update_run(repo_key, run_id, &1))
        |> ignore_missing_run()
        |> log_run_store_error("persist running metadata")

      _ ->
        :ok
    end
  end

  # An agent streams many events a second, and each durable write syncs the Mnesia log, so its run's
  # metadata is written when a field that names the run changes (its session, PR, workspace, host or
  # turn) and otherwise at most once every `running_metadata_persist_ms`. The run's completion
  # writes everything (persist_run_completion/3).
  defp persist_running_metadata(%State{running: running} = state, issue_id) do
    with %{} = entry <- Map.get(running, issue_id),
         key = running_metadata_key(entry),
         now_ms = System.monotonic_time(:millisecond),
         true <- running_metadata_due?(entry, key, now_ms) do
      persist_running_entry(entry)
      entry = Map.merge(entry, %{persisted_metadata_key: key, persisted_metadata_at_ms: now_ms})
      %{state | running: Map.put(running, issue_id, entry)}
    else
      _not_due -> state
    end
  end

  defp running_metadata_due?(%{persisted_metadata_key: key, persisted_metadata_at_ms: at_ms}, key, now_ms),
    do: now_ms - at_ms >= running_metadata_persist_ms()

  defp running_metadata_due?(_entry, _key, _now_ms), do: true

  defp running_metadata_key(entry) do
    {Map.get(entry, :session_id), URLUtils.pull_request_url(entry), Map.get(entry, :workspace_path), Map.get(entry, :worker_host), Map.get(entry, :turn_count, 0)}
  end

  defp running_metadata_persist_ms,
    do: Application.get_env(:symphony_elixir, :orchestrator_running_metadata_persist_ms, @running_metadata_persist_ms)

  defp persist_run_completion(running_entry, status, error) when is_map(running_entry) and is_binary(status) do
    case {running_entry_repo_key(running_entry), Map.get(running_entry, :run_id)} do
      {repo_key, run_id} when is_binary(repo_key) and is_binary(run_id) ->
        now = DateTime.utc_now()

        attrs =
          running_entry
          |> run_update_from_entry()
          |> Map.merge(%{
            status: status,
            ended_at: now,
            error: error,
            runtime_seconds: running_seconds(Map.get(running_entry, :started_at), now),
            updated_at: now
          })

        repo_key
        |> RunStore.update_run(run_id, attrs)
        |> ignore_missing_run()
        |> log_run_store_error("persist run completion")

        persist_quality_eval_async(Map.merge(running_entry, attrs), status, error)

      _ ->
        :ok
    end
  end

  defp persist_run_completion(_running_entry, _status, _error), do: :ok

  defp complete_pr_review_comment_cursor(issue_id, repo_key) when is_binary(issue_id) do
    case PrReviewPoller.complete_pending_reviewer_comments(issue_id, repo_key_opt(repo_key)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to complete pending PR review comments issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp complete_pr_review_comment_cursor(_issue_id, _repo_key), do: :ok

  defp persist_quality_eval_async(%{run_id: run_id} = running_entry, status, error)
       when is_binary(run_id) and is_binary(status) do
    start_quality_eval_task(running_entry, status, error)
  end

  defp persist_quality_eval_async(_running_entry, _status, _error), do: :ok

  defp start_quality_eval_task(running_entry, status, error) do
    case start_task_supervisor_child(fn ->
           Quality.persist_run_eval(running_entry, status, error)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to start async quality eval logger: #{inspect(reason)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning("Unable to start async quality eval logger: #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Unable to start async quality eval logger: #{inspect({kind, reason})}")
      :ok
  end

  defp start_task_supervisor_child(fun) when is_function(fun, 0) do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      pid when is_pid(pid) ->
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fun)

      _ ->
        {:error, :task_supervisor_unavailable}
    end
  catch
    :exit, reason -> {:error, {:task_supervisor_exit, reason}}
  end

  defp handle_tracker_task_result(%State{} = state, %{kind: :retry_refresh, issue_ids: [issue_id]} = context, result) do
    {:noreply, state} = handle_retry_refresh_result(state, issue_id, context.attempt, context.metadata, result)
    state
  end

  defp handle_tracker_task_result(%State{} = state, %{kind: :blocked_hold} = context, result), do: finish_blocked_hold(state, context, result)
  defp handle_tracker_task_result(%State{} = state, %{kind: :operator_stop_hold} = context, result), do: finish_operator_stop_hold(state, context, result)
  defp handle_tracker_task_result(%State{} = state, %{kind: :setup_block} = context, result), do: finish_setup_block(state, context, result)
  defp handle_tracker_task_result(%State{} = state, %{kind: :breakdown_review} = context, result), do: finish_breakdown_review(state, context, result)
  defp handle_tracker_task_result(%State{} = state, %{kind: :plan_comments} = context, result), do: finish_plan_comments(state, context, result)
  defp handle_tracker_task_result(%State{} = state, %{kind: :usage_limit_canary} = context, result), do: finish_usage_limit_canary_read(state, context, result)

  defp handle_tracker_task_result(%State{} = state, %{kind: :park_parents}, {:ok, parked_ids}),
    do: %{state | parked_parents: MapSet.union(state.parked_parents, MapSet.new(parked_ids))}

  # A comment, a failed park, and the close of finished parents change nothing here: the next poll
  # tries again where it needs to.
  defp handle_tracker_task_result(%State{} = state, _context, _result), do: state

  # Linear work whose answer the orchestrator needs runs in a task, so a slow or retrying Linear
  # call never holds up its callbacks, its callers or the snapshot. The context names what the
  # result is for (see handle_tracker_task_result/3), and the issues it is about, so a poll does not
  # start the same work again while it is in flight. A task that exits, or never starts, answers
  # `{:error, reason}`.
  defp start_tracker_task(%State{} = state, %{kind: kind} = context, fun) when is_function(fun, 0) do
    case start_async_task(fn -> {:tracker_task_result, fun.()} end) do
      {:ok, task} ->
        %{state | tracker_tasks: Map.put(state.tracker_tasks, task.ref, context)}

      {:error, reason} ->
        Logger.warning("Failed to start async Linear task #{kind}: #{inspect(reason)}")
        handle_tracker_task_result(state, context, {:error, reason})
    end
  end

  defp tracker_task_in_flight?(%State{tracker_tasks: tasks}, kind, issue_id) do
    Enum.any?(tasks, fn {_ref, context} -> context.kind == kind and issue_id in Map.get(context, :issue_ids, []) end)
  end

  # The test hooks that run on a bare State, with no orchestrator to receive the results, wait for
  # the tasks they started and apply each result as the orchestrator would.
  defp await_tracker_tasks(%State{tracker_tasks: tasks} = state) when map_size(tasks) == 0, do: state

  defp await_tracker_tasks(%State{tracker_tasks: tasks} = state) do
    receive do
      {ref, {:tracker_task_result, _result}} = message when is_map_key(tasks, ref) ->
        {:noreply, state} = handle_info_message(message, state)
        await_tracker_tasks(state)

      {:DOWN, ref, :process, _pid, _reason} = message when is_map_key(tasks, ref) ->
        {:noreply, state} = handle_info_message(message, state)
        await_tracker_tasks(state)
    end
  end

  defp start_async_task(fun) when is_function(fun, 0) do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      pid when is_pid(pid) ->
        {:ok, Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fun)}

      _ ->
        {:error, :task_supervisor_unavailable}
    end
  catch
    :exit, reason -> {:error, {:task_supervisor_exit, reason}}
  end

  defp persist_retry(retry) when is_map(retry) do
    retry
    |> RunStore.put_retry()
    |> log_run_store_error("persist retry")
  end

  defp persist_codex_totals(totals) when is_map(totals) do
    totals
    |> RunStore.put_codex_totals()
    |> log_run_store_error("persist codex totals")
  end

  defp delete_persisted_retry(%State{} = state, issue_id) do
    delete_persisted_retry(state, issue_id, retry_repo_key_from_state(state, issue_id))
  end

  defp delete_persisted_retry(%State{} = state, issue_id, repo_key) do
    repo_key = repo_key_from(%{repo_key: repo_key}) || state.repo_key

    if is_binary(issue_id) do
      repo_key
      |> RunStore.delete_retry(issue_id)
      |> log_run_store_error("delete retry")
    end

    state
  end

  defp run_record(%Issue{} = issue, running_entry, status, attempt_count) do
    now = DateTime.utc_now()
    started_at = Map.get(running_entry, :started_at) || now

    %{
      run_id: Map.fetch!(running_entry, :run_id),
      repo_key: Map.fetch!(running_entry, :repo_key),
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      status: status,
      attempt: attempt_count,
      started_at: started_at,
      ended_at: nil,
      error: nil,
      worker_host: Map.get(running_entry, :worker_host),
      verification_port: verification_port(running_entry),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: Map.get(running_entry, :session_id),
      transcript_path: Map.get(running_entry, :transcript_path),
      codex_app_server_pid: Map.get(running_entry, :codex_app_server_pid),
      turn_count: Map.get(running_entry, :turn_count, 0),
      tokens: run_tokens(running_entry),
      reviewer_tokens: reviewer_tokens(running_entry),
      transcript_buffer: transcript_buffer_list(running_entry),
      transcript_buffer_size: transcript_buffer_size(running_entry),
      runtime_seconds: 0,
      last_event: Map.get(running_entry, :last_codex_event),
      last_event_at: Map.get(running_entry, :last_event_at) || Map.get(running_entry, :last_codex_timestamp),
      pull_request_url: running_entry_pr_url(Map.put(running_entry, :issue, issue)),
      updated_at: now
    }
    |> Map.merge(run_profile_record(Map.get(running_entry, :run_profile)))
    |> Map.merge(reviewer_profile_record(Map.get(running_entry, :reviewer_run_profile)))
  end

  # Code Review's reviewer runs inside the Code Review run, so the run's record keeps its profile.
  defp reviewer_profile_record(nil), do: %{}
  defp reviewer_profile_record(profile), do: %{reviewer_profile: run_profile_record(profile)}

  defp run_profile_record(%{kind: kind, model: model, effort: effort} = profile),
    do: %{run_kind: Atom.to_string(kind), model: model, effort: effort, provider: Map.get(profile, :provider)}

  defp run_profile_record(nil), do: %{}

  defp run_update_from_entry(running_entry) when is_map(running_entry) do
    %{
      worker_host: Map.get(running_entry, :worker_host),
      verification_port: verification_port(running_entry),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: Map.get(running_entry, :session_id),
      transcript_path: Map.get(running_entry, :transcript_path),
      codex_app_server_pid: Map.get(running_entry, :codex_app_server_pid),
      turn_count: Map.get(running_entry, :turn_count, 0),
      tokens: run_tokens(running_entry),
      reviewer_tokens: reviewer_tokens(running_entry),
      transcript_buffer: transcript_buffer_list(running_entry),
      transcript_buffer_size: transcript_buffer_size(running_entry),
      runtime_seconds: running_seconds(Map.get(running_entry, :started_at), DateTime.utc_now()),
      last_event: Map.get(running_entry, :last_codex_event),
      last_event_at: Map.get(running_entry, :last_event_at) || Map.get(running_entry, :last_codex_timestamp),
      pull_request_url: running_entry_pr_url(running_entry),
      updated_at: DateTime.utc_now()
    }
  end

  defp run_tokens(running_entry) when is_map(running_entry) do
    %{
      input_tokens: entry_input_tokens(running_entry),
      uncached_input_tokens: entry_uncached_input_tokens(running_entry),
      cached_input_tokens: entry_cached_input_tokens(running_entry),
      cache_creation_input_tokens: entry_cache_creation_input_tokens(running_entry),
      output_tokens: entry_output_tokens(running_entry),
      total_tokens: entry_total_tokens(running_entry)
    }
  end

  defp reviewer_tokens(running_entry) when is_map(running_entry) do
    %{
      input_tokens: reviewer_input_tokens(running_entry),
      uncached_input_tokens: reviewer_uncached_input_tokens(running_entry),
      cached_input_tokens: reviewer_cached_input_tokens(running_entry),
      cache_creation_input_tokens: reviewer_cache_creation_input_tokens(running_entry),
      output_tokens: reviewer_output_tokens(running_entry),
      total_tokens: reviewer_total_tokens(running_entry)
    }
  end

  defp entry_uncached_input_tokens(entry) when is_map(entry) do
    case Map.get(entry, :uncached_input_tokens) do
      value when is_integer(value) -> max(value, 0)
      _ -> max(Map.get(entry, :codex_input_tokens, 0) - Map.get(entry, :codex_cached_input_tokens, 0), 0)
    end
  end

  defp entry_input_tokens(entry) when is_map(entry) do
    if Map.has_key?(entry, :uncached_input_tokens) do
      entry_uncached_input_tokens(entry) + entry_cached_input_tokens(entry) + entry_cache_creation_input_tokens(entry)
    else
      max(Map.get(entry, :codex_input_tokens, 0), 0)
    end
  end

  defp entry_cached_input_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :cached_input_tokens, Map.get(entry, :codex_cached_input_tokens, 0)), 0)

  defp entry_cache_creation_input_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :cache_creation_input_tokens, Map.get(entry, :codex_cache_creation_input_tokens, 0)), 0)

  defp entry_output_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :output_tokens, Map.get(entry, :codex_output_tokens, 0)), 0)

  defp entry_total_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :total_tokens, Map.get(entry, :codex_total_tokens, 0)), 0)

  defp reviewer_uncached_input_tokens(entry) when is_map(entry) do
    case Map.get(entry, :reviewer_uncached_input_tokens) do
      value when is_integer(value) -> max(value, 0)
      _ -> max(Map.get(entry, :reviewer_input_tokens, 0) - Map.get(entry, :reviewer_cached_input_tokens, 0), 0)
    end
  end

  defp reviewer_input_tokens(entry) when is_map(entry) do
    if Map.has_key?(entry, :reviewer_uncached_input_tokens) do
      reviewer_uncached_input_tokens(entry) + reviewer_cached_input_tokens(entry) +
        reviewer_cache_creation_input_tokens(entry)
    else
      max(Map.get(entry, :reviewer_input_tokens, 0), 0)
    end
  end

  defp reviewer_cached_input_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :reviewer_cached_input_tokens, 0), 0)

  defp reviewer_cache_creation_input_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :reviewer_cache_creation_input_tokens, 0), 0)

  defp reviewer_output_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :reviewer_output_tokens, 0), 0)

  defp reviewer_total_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :reviewer_total_tokens, 0), 0)

  defp review_agent_enabled?(%{review_agent: %{enabled: true}}), do: true
  defp review_agent_enabled?(%{review_agent: %{enabled: false}}), do: false

  defp review_agent_enabled_for_repo(repo_key, issue \\ nil) do
    repo_key
    |> Config.settings_for_repo!()
    |> review_agent_enabled?()
  rescue
    exception in [ArgumentError, KeyError, MatchError, FunctionClauseError] ->
      log_review_agent_config_failed(repo_key, issue, exception)
      false
  end

  defp log_review_agent_config_failed(repo_key, %Issue{} = issue, exception) do
    Logger.error("review_agent_config_failed repo_key=#{log_value(repo_key)} #{issue_context(issue)} reason=#{config_exception_reason(exception)}")
  end

  defp log_review_agent_config_failed(repo_key, _issue, exception) do
    Logger.error("review_agent_config_failed repo_key=#{log_value(repo_key)} reason=#{config_exception_reason(exception)}")
  end

  defp config_exception_reason(exception) do
    "#{inspect(exception.__struct__)}: #{Exception.message(exception)}"
  end

  defp log_value(value) when is_binary(value), do: value
  defp log_value(value), do: inspect(value)

  defp verification_port(%{verification: %{port: port}}) when is_integer(port), do: port
  defp verification_port(_running_entry), do: nil

  defp new_run_id(issue_id) when is_binary(issue_id) do
    "#{issue_id}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
  end

  defp attempt_count(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp attempt_count(_attempt), do: 1

  defp terminal_status_for_reason(:timeout), do: "timeout"
  defp terminal_status_for_reason({:timeout, _reason}), do: "timeout"
  defp terminal_status_for_reason({:tool_failure_circuit_breaker, _payload}), do: "blocked"
  defp terminal_status_for_reason({:setup_block, _cause}), do: "blocked"
  defp terminal_status_for_reason(_reason), do: "failure"

  defp ignore_missing_run({:error, :run_not_found}), do: :ok
  defp ignore_missing_run(other), do: other

  defp log_run_store_error(:ok, _action), do: :ok

  defp log_run_store_error({:error, reason}, action) do
    Logger.warning("Failed to #{action}: #{inspect(reason)}")
    :ok
  end

  # Every move the orchestrator makes is recorded in the ticket's signals ledger and its event stream
  # (`TicketSignals.record/4`), best effort: a store failure must never change a transition, the
  # board or a label.
  defp record_ticket_signal(%Issue{id: issue_id} = issue, name, details) when is_binary(issue_id) do
    case issue_repo_key(issue) do
      repo_key when is_binary(repo_key) -> record_ticket_signal(repo_key, issue_id, name, details)
      _repo_key -> :ok
    end
  end

  defp record_ticket_signal(_issue, _name, _details), do: :ok

  defp record_ticket_signal(repo_key, issue_id, name, details), do: TicketSignals.record(repo_key, issue_id, name, details)

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if server_available?(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @doc """
  Asks for a cycle on `repo_key` at once, after a move Symphony or the Director made there: the repo
  is due now, ahead of its stagger, and the next tick polls it, reads the tickets by id and
  dispatches. When the poll for a move made there less than two seconds earlier has already
  started, the repo is due again two seconds after that move instead, since that poll may have read
  Linear before this one. A cast, so a move recorded inside the orchestrator's own process never
  waits on it; `repo_key` nil asks for a poll of whatever is due.
  """
  @spec request_refresh(String.t() | nil, due: :now) :: :ok
  def request_refresh(repo_key, due: :now), do: request_refresh(__MODULE__, repo_key, due: :now)

  @spec request_refresh(GenServer.server(), String.t() | nil, due: :now) :: :ok
  def request_refresh(server, repo_key, due: :now), do: GenServer.cast(server, {:request_refresh, repo_key, :now})

  @spec pause_dispatch(String.t() | nil) :: {:ok, map()} | :unavailable | {:error, term()}
  def pause_dispatch(reason) do
    pause_dispatch(__MODULE__, reason)
  end

  @spec pause_dispatch(GenServer.server(), String.t() | nil) :: {:ok, map()} | :unavailable | {:error, term()}
  def pause_dispatch(server, reason) do
    if server_available?(server) do
      GenServer.call(server, {:pause_dispatch, reason})
    else
      :unavailable
    end
  end

  @spec resume_dispatch() :: {:ok, map()} | :unavailable | {:error, term()}
  def resume_dispatch do
    resume_dispatch(__MODULE__)
  end

  @spec resume_dispatch(GenServer.server()) :: {:ok, map()} | :unavailable | {:error, term()}
  def resume_dispatch(server) do
    if server_available?(server) do
      GenServer.call(server, :resume_dispatch)
    else
      :unavailable
    end
  end

  @spec pause_status() :: map() | :unavailable
  def pause_status do
    pause_status(__MODULE__)
  end

  @spec pause_status(GenServer.server()) :: map() | :unavailable
  def pause_status(server) do
    if server_available?(server) do
      GenServer.call(server, :pause_status)
    else
      :unavailable
    end
  end

  @doc """
  Holds the provider's runs for a usage-limit `info` hit outside an agent run, as if a run of
  `identifier` had hit it. Returns the hold.
  """
  @spec hold_for_usage_limit(GenServer.server(), map(), String.t() | nil) :: {:ok, UsageLimit.entry()} | :unavailable
  def hold_for_usage_limit(server, info, identifier) when is_map(info) do
    if server_available?(server) do
      GenServer.call(server, {:hold_for_usage_limit, info, identifier})
    else
      :unavailable
    end
  end

  @spec stop_running(String.t()) :: {:ok, map()} | :unavailable | {:error, term()}
  def stop_running(issue_id_or_identifier) do
    stop_running(__MODULE__, issue_id_or_identifier)
  end

  @spec stop_running(GenServer.server(), String.t()) :: {:ok, map()} | :unavailable | {:error, term()}
  def stop_running(server, issue_id_or_identifier) when is_binary(issue_id_or_identifier) do
    if server_available?(server) do
      GenServer.call(server, {:stop_running, issue_id_or_identifier})
    else
      :unavailable
    end
  end

  def stop_running(_server, _issue_id_or_identifier), do: {:error, :invalid_issue_id}

  @spec dispatch_pr(String.t(), keyword()) :: {:ok, map()} | :unavailable | {:error, term()}
  def dispatch_pr(target, opts \\ []) do
    dispatch_pr(__MODULE__, target, opts)
  end

  @spec dispatch_pr(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | :unavailable | {:error, term()}
  def dispatch_pr(server, target, opts) when is_binary(target) and is_list(opts) do
    if server_available?(server) do
      GenServer.call(server, {:dispatch_pr, target, opts})
    else
      :unavailable
    end
  end

  def dispatch_pr(_server, _target, _opts), do: {:error, :invalid_pr_target}

  @doc """
  Adds `agent.concurrency.force_label` to the ticket, or removes it with `clear?`, and puts the change
  into the forced queue at once, so a ticket forced before the next poll queues behind the one
  forced first. The Linear calls run in the caller, not in the orchestrator.
  """
  @spec force_issue(String.t(), boolean()) :: {:ok, map()} | :unavailable | {:error, term()}
  def force_issue(identifier, clear?), do: force_issue(__MODULE__, identifier, clear?)

  @spec force_issue(GenServer.server(), String.t(), boolean()) :: {:ok, map()} | :unavailable | {:error, term()}
  def force_issue(server, identifier, clear?) when is_binary(identifier) and is_boolean(clear?) do
    if server_available?(server) do
      settings = Config.settings!()

      with {:ok, issue} <- fetch_issue_to_force(identifier),
           {:ok, issue} <- put_force_label(issue, clear?, settings),
           :ok <- record_force_action(issue, clear?) do
        GenServer.call(server, {:force_issue, issue})
      end
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    case snapshot_cache_entry(server) do
      {:ok, %{snapshot: snapshot}} ->
        snapshot

      :missing ->
        snapshot_via_call(server, timeout)
    end
  end

  @spec snapshot_cache_entry() ::
          {:ok, %{snapshot: map(), monotonic_ms: integer(), system_ms: integer()}} | :missing
  def snapshot_cache_entry, do: snapshot_cache_entry(__MODULE__)

  @spec snapshot_cache_entry(GenServer.server()) ::
          {:ok, %{snapshot: map(), monotonic_ms: integer(), system_ms: integer()}} | :missing
  def snapshot_cache_entry(server) do
    with {:ok, owner} <- snapshot_table_owner(),
         true <- snapshot_owner_matches?(server, owner),
         [{@snapshot_key, snapshot, monotonic_ms, system_ms}] <- :ets.lookup(@snapshot_table, @snapshot_key),
         true <- is_map(snapshot) and is_integer(monotonic_ms) and is_integer(system_ms) do
      {:ok, %{snapshot: snapshot, monotonic_ms: monotonic_ms, system_ms: system_ms}}
    else
      _ -> :missing
    end
  rescue
    ArgumentError -> :missing
  end

  @doc """
  How well the orchestrator keeps up, for `/api/v1/state`: its message queue, the age of the
  snapshot it last published, and how long that snapshot took to build, in total and for the parts
  that read other processes or the run store. A field is nil when it isn't known.
  """
  @spec diagnostics(GenServer.server()) :: %{
          message_queue_len: non_neg_integer() | nil,
          snapshot_age_ms: non_neg_integer() | nil,
          snapshot_build_ms: non_neg_integer() | nil,
          snapshot_parts_ms: %{optional(atom()) => non_neg_integer()}
        }
  def diagnostics(server \\ __MODULE__) do
    age_ms =
      case snapshot_cache_entry(server) do
        {:ok, %{system_ms: system_ms}} -> max(System.system_time(:millisecond) - system_ms, 0)
        :missing -> nil
      end

    {build_ms, parts_ms} = snapshot_timing(server)

    %{
      message_queue_len: message_queue_len(server),
      snapshot_age_ms: age_ms,
      snapshot_build_ms: build_ms,
      snapshot_parts_ms: parts_ms
    }
  end

  defp message_queue_len(server) do
    with pid when is_pid(pid) <- GenServer.whereis(server),
         {:message_queue_len, len} <- Process.info(pid, :message_queue_len) do
      len
    else
      _dead -> nil
    end
  end

  defp snapshot_timing(server) do
    with {:ok, owner} <- snapshot_table_owner(),
         true <- snapshot_owner_matches?(server, owner),
         [{@snapshot_timing_key, build_ms, parts_ms}] <- :ets.lookup(@snapshot_table, @snapshot_timing_key) do
      {build_ms, parts_ms}
    else
      _missing -> {nil, %{}}
    end
  end

  defp snapshot_via_call(server, timeout) do
    if server_available?(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  defp server_available?(server) when is_pid(server), do: Process.alive?(server)
  defp server_available?(server) when is_atom(server), do: is_pid(Process.whereis(server))
  defp server_available?(_server), do: false

  defp snapshot_table_owner do
    case :ets.info(@snapshot_table, :owner) do
      owner when is_pid(owner) -> {:ok, owner}
      _ -> :missing
    end
  rescue
    ArgumentError -> :missing
  end

  defp snapshot_owner_matches?(server, owner) when is_pid(server), do: server == owner
  defp snapshot_owner_matches?(server, owner) when is_atom(server), do: Process.whereis(server) == owner
  defp snapshot_owner_matches?(_server, _owner), do: false

  defp ensure_snapshot_table do
    case :ets.info(@snapshot_table, :owner) do
      :undefined ->
        :ets.new(@snapshot_table, [
          :named_table,
          :public,
          read_concurrency: true
        ])

        :ok

      owner when owner == self() ->
        :ok

      owner ->
        Logger.warning("snapshot table owned by another process",
          existing_owner: inspect(owner),
          self: inspect(self())
        )

        :ok
    end
  end

  defp publish_snapshot(%State{} = state) do
    with {:ok, owner} <- snapshot_table_owner(),
         true <- owner == self() do
      monotonic_ms = System.monotonic_time(:millisecond)
      system_ms = System.system_time(:millisecond)
      {snapshot, parts_ms} = build_snapshot(state, DateTime.utc_now(), monotonic_ms)
      build_ms = System.monotonic_time(:millisecond) - monotonic_ms
      :ets.insert(@snapshot_table, [{@snapshot_key, snapshot, monotonic_ms, system_ms}, {@snapshot_timing_key, build_ms, parts_ms}])
      log_slow_snapshot_build(build_ms, parts_ms)
    else
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp schedule_snapshot_publish(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :publish_snapshot, delay_ms)
    :ok
  end

  defp schedule_snapshot_publish(_delay_ms), do: :ok

  defp snapshot_publish_interval_ms do
    Config.settings!().observability
    |> Map.get(:snapshot_publish_ms, @default_snapshot_publish_ms)
    |> case do
      interval_ms when is_integer(interval_ms) and interval_ms > 0 -> interval_ms
      _ -> @default_snapshot_publish_ms
    end
  end

  defp handle_call_message({:pause_dispatch, reason}, _from, state) do
    already_paused? = operator_paused?(state)

    case RunStore.set_paused(true, reason) do
      :ok ->
        pause = persisted_pause_state()

        if already_paused? do
          Logger.info("Operator pause requested while dispatch is already paused reason=#{inspect(pause.reason)} paused_at=#{inspect(pause.paused_at)}")
        else
          Logger.warning("Operator paused dispatch reason=#{inspect(pause.reason)} paused_at=#{inspect(pause.paused_at)}")
        end

        notify_dashboard()
        {:reply, {:ok, pause}, %{state | pause: pause, operator_pause_logged: true}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_call_message(:resume_dispatch, _from, state) do
    case RunStore.set_paused(false, nil) do
      :ok ->
        pause = persisted_pause_state()
        Logger.warning("Operator resumed dispatch")
        notify_dashboard()
        {:reply, {:ok, pause}, schedule_tick(%{state | pause: pause, operator_pause_logged: false}, 0)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_call_message({:hold_for_usage_limit, info, identifier}, _from, state) do
    {state, entry} = put_usage_limit(state, info, identifier)
    notify_dashboard()
    {:reply, {:ok, entry}, state}
  end

  defp handle_call_message(:pause_status, _from, state) do
    {:reply, state.pause || unpaused_state(), state}
  end

  defp handle_call_message({:dispatch_pr, target, opts}, _from, state) do
    state = refresh_runtime_config(state)

    case do_dispatch_pr(state, target, opts) do
      {:ok, result, next_state} ->
        notify_dashboard()
        {:reply, {:ok, result}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  defp handle_call_message({:force_issue, %Issue{} = issue}, _from, state) do
    settings = Config.settings!()

    # As in a poll, a ticket joins the queue only in an active state; one already queued is updated.
    {forced, changes} =
      if Map.has_key?(state.forced, issue.id) or active_issue_state?(issue.state) do
        ForcedQueue.reconcile(state.forced, [issue], [], settings, state.clock.())
      else
        {state.forced, []}
      end

    state = state |> put_forced(forced, changes) |> remember_forced_issues([issue])
    state = %{state | forced_touched: Map.put(state.forced_touched, issue.id, System.monotonic_time(:millisecond))}
    {_coalesced, state} = request_poll(state)
    result = force_result(issue, forced, settings)

    Logger.info(
      "Operator #{if result.forced, do: "forced", else: "cleared the force label on"} issue_id=#{issue.id} " <>
        "issue_identifier=#{issue.identifier} state=#{issue.state} position=#{inspect(result.position)}"
    )

    notify_dashboard()
    {:reply, {:ok, result}, state}
  end

  defp handle_call_message({:stop_running, issue_id_or_identifier}, _from, state) do
    case find_running_issue(state.running, issue_id_or_identifier) do
      {issue_id, running_entry} ->
        session_id = running_entry_session_id(running_entry)
        repo_key = running_repo_key(state, running_entry)
        Logger.warning("Operator stopping running agent issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}")

        # The stop removes the workspace, but the ticket didn't end: the `stop` reason keeps a
        # `before_remove` hook that closes PRs from closing the ticket's PR.
        state =
          terminate_running_issue(state, issue_id, true,
            status: "stopped",
            error: "agent stopped by operator",
            track_completed_run: true,
            remove_reason: :stop
          )
          |> mark_operator_stop(issue_id, running_entry, repo_key)

        notify_dashboard()

        {:reply,
         {:ok,
          %{
            stopped: true,
            issue_id: issue_id,
            issue_identifier: running_entry.identifier,
            repo_key: repo_key,
            session_id: session_id
          }}, state}

      nil ->
        {:reply, {:ok, %{stopped: false, issue_id: issue_id_or_identifier}}, state}
    end
  end

  defp handle_call_message(:request_refresh, _from, state) do
    {coalesced, state} = request_poll(state)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp handle_call_message(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    {snapshot, _parts_ms} = build_snapshot(state, DateTime.utc_now(), System.monotonic_time(:millisecond))

    {:reply, snapshot, state}
  end

  defp log_slow_snapshot_build(build_ms, parts_ms) do
    if build_ms >= slow_callback_ms() do
      parts = parts_ms |> Enum.sort() |> Enum.map_join(" ", fn {part, ms} -> "#{part}_ms=#{ms}" end)
      Logger.warning("Orchestrator snapshot build slow build_ms=#{build_ms} #{parts}")
    end

    :ok
  end

  # The parts that read other processes or the run store, timed for `diagnostics/1`.
  defp timed_part(fun) do
    started_ms = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started_ms}
  end

  defp build_snapshot(%State{} = state, %DateTime{} = now, now_ms) when is_integer(now_ms) do
    pending_tool_report_after_ms = Config.settings!().watchdog.pending_tool_report_after_ms

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          repo_key: Map.get(metadata, :repo_key),
          run_kind: Map.get(metadata, :run_kind) || Map.get(metadata.issue, :run_kind),
          run_profile: Map.get(metadata, :run_profile),
          reviewer_run_profile: Map.get(metadata, :reviewer_run_profile),
          identifier: metadata.identifier,
          title: running_entry_title(metadata),
          state: metadata.issue.state,
          url: issue_url(metadata.issue),
          pull_request_url: running_entry_pr_url(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          transcript_path: Map.get(metadata, :transcript_path),
          codex_app_server_pid: Map.get(metadata, :codex_app_server_pid),
          input_tokens: entry_input_tokens(metadata),
          uncached_input_tokens: entry_uncached_input_tokens(metadata),
          cached_input_tokens: entry_cached_input_tokens(metadata),
          cache_creation_input_tokens: entry_cache_creation_input_tokens(metadata),
          output_tokens: entry_output_tokens(metadata),
          total_tokens: entry_total_tokens(metadata),
          codex_input_tokens: entry_input_tokens(metadata),
          codex_cached_input_tokens: entry_cached_input_tokens(metadata),
          codex_cache_creation_input_tokens: entry_cache_creation_input_tokens(metadata),
          codex_output_tokens: entry_output_tokens(metadata),
          codex_total_tokens: entry_total_tokens(metadata),
          reviewer_input_tokens: reviewer_input_tokens(metadata),
          reviewer_uncached_input_tokens: reviewer_uncached_input_tokens(metadata),
          reviewer_cached_input_tokens: reviewer_cached_input_tokens(metadata),
          reviewer_cache_creation_input_tokens: reviewer_cache_creation_input_tokens(metadata),
          reviewer_output_tokens: reviewer_output_tokens(metadata),
          reviewer_total_tokens: reviewer_total_tokens(metadata),
          review_agent_enabled: Map.get(metadata, :review_agent_enabled, false),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          last_event_at: Map.get(metadata, :last_event_at) || metadata.last_codex_timestamp,
          transcript_buffer: transcript_buffer_list(metadata),
          transcript_buffer_size: Map.get(metadata, :transcript_buffer_size, 0),
          forced: forced_entry?(metadata),
          linear_wait_until: active_linear_wait_until(metadata, now),
          pending_tool: pending_tool(metadata, now, pending_tool_report_after_ms),
          runtime_seconds: running_seconds(metadata.started_at, now),
          connected: Connected.build(metadata.issue, Map.get(metadata, :linked))
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          repo_key: Map.get(retry, :repo_key) || state.repo_key,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          title: Map.get(retry, :title),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path),
          reason: Map.get(retry, :reason),
          elapsed_ms: Map.get(retry, :elapsed_ms),
          delay_type: retry_delay_type(retry),
          forced: forced_queued?(issue_id, state)
        }
      end)

    watching =
      state.watching
      |> Enum.map(fn {issue_id, watching_entry} ->
        last_ran_at = Map.get(watching_entry, :last_ran_at)

        %{
          issue_id: issue_id,
          repo_key: Map.get(watching_entry, :repo_key) || state.repo_key,
          identifier: Map.get(watching_entry, :identifier),
          title: Map.get(watching_entry, :title),
          state: Map.get(watching_entry, :state),
          url: URLUtils.present_url(Map.get(watching_entry, :url)),
          pull_request_url: URLUtils.pull_request_url(watching_entry),
          last_ran_at: last_ran_at,
          seconds_since_last_run: seconds_since(last_ran_at, now),
          session_id: Map.get(watching_entry, :session_id),
          started_at: Map.get(watching_entry, :started_at),
          last_event_at: Map.get(watching_entry, :last_event_at),
          turn_count: Map.get(watching_entry, :turn_count, 0),
          tokens: Map.get(watching_entry, :tokens, %{}),
          transcript_path: Map.get(watching_entry, :transcript_path),
          transcript_buffer: Map.get(watching_entry, :transcript_buffer, []),
          transcript_buffer_size: Map.get(watching_entry, :transcript_buffer_size, 0),
          connected: Map.get(watching_entry, :connected)
        }
      end)

    waiting_for_ci =
      Enum.map(state.merging_ci_waits, fn {issue_id, wait} ->
        %{
          issue_id: issue_id,
          repo_key: wait.repo_key || state.repo_key,
          identifier: wait.identifier,
          title: wait.title,
          pull_request_url: wait.pull_request_url,
          commit_sha: wait.commit_sha,
          waiting_since: wait.since,
          seconds_waiting: seconds_since(wait.since, now)
        }
      end)

    conflicts =
      state.conflicts
      |> Map.values()
      |> Enum.map(fn %Issue{} = issue ->
        %{
          issue_id: issue.id,
          identifier: issue.identifier,
          title: issue.title,
          state: "Conflict",
          linear_state: issue.state,
          url: issue_url(issue),
          repo_keys: issue.conflict_repo_keys
        }
      end)

    quality_gate_cache = quality_gate_snapshot_cache(state)

    cached_skipped =
      quality_gate_cache
      |> QualityGate.skipped_from_cache()
      |> Enum.map(&snapshot_skipped_entry/1)

    error_skipped =
      state
      |> quality_gate_snapshot_skipped_errors()
      |> Map.values()
      |> Enum.map(&snapshot_skipped_entry/1)

    skipped = error_skipped ++ cached_skipped

    {auto_merge, auto_merge_ms} = timed_part(&PrWatch.auto_merge_statuses/0)
    {landing_waits, landing_waits_ms} = timed_part(&PrWatch.landing_waits/0)
    {run_history, run_history_ms} = timed_part(fn -> persisted_run_history(state.repo_key) end)

    awaiting_clarification =
      quality_gate_cache
      |> QualityGate.awaiting_clarification_from_cache()
      |> Enum.map(&snapshot_awaiting_clarification_entry/1)

    snapshot = %{
      running: running,
      watching: watching,
      waiting_for_ci: waiting_for_ci,
      conflicts: conflicts,
      retrying: retrying,
      awaiting_clarification: awaiting_clarification,
      skipped: skipped,
      run_history: run_history,
      codex_totals: state.codex_totals,
      rate_limits: Map.get(state, :rate_limits),
      usage_limits: UsageLimit.snapshot(state.usage_limits, state.usage_windows),
      pause: state.pause || unpaused_state(),
      workspace_lifecycle: workspace_lifecycle_snapshot(state),
      budget: budget_snapshot(state),
      dispatch_state: dispatch_state_snapshot(state),
      epic_lanes: EpicLanes.snapshot(state.epic_lanes, epic_lane_running(state.running)),
      blocked: state.blocked || [],
      forced: forced_snapshot(state, auto_merge),
      concurrency: concurrency_snapshot(state),
      finishing: finishing_snapshot(state.running),
      auto_merge: auto_merge,
      landing_waits: landing_waits,
      slot_waiting: slot_waiting_snapshot(state.slot_waiting, state) ++ merging_ci_waiting_snapshot(state),
      dispatch_skipped: dispatch_skipped_snapshot(state.dispatch_skipped),
      shipped_today: ShippedToday.today(state.shipped, now),
      claimed: state.claimed |> MapSet.to_list() |> Enum.sort(),
      pollers: poller_status_snapshot(),
      polling: %{
        checking?: state.poll_check_in_progress == true,
        next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
        poll_interval_ms: state.poll_interval_ms,
        linear: linear_rate_limit_snapshot(state)
      }
    }

    {snapshot, %{run_history: run_history_ms, auto_merge: auto_merge_ms, landing_waits: landing_waits_ms}}
  end

  defp concurrency_snapshot(%State{} = state) do
    agent = Config.settings!().agent

    %{
      max_total: state.max_concurrent_agents || agent.max_concurrent_agents,
      finishing_max: agent.finishing_max,
      forced_max: agent.forced_max
    }
  end

  defp finishing_snapshot(running) do
    landing_runs =
      for {issue_id, entry} <- running, finishing_entry?(entry) do
        %{issue_id: issue_id, identifier: entry.identifier, state: entry.issue.state}
      end

    %{
      slots: Config.settings!().agent.finishing_max,
      used: length(landing_runs),
      running: Enum.sort_by(landing_runs, & &1.identifier)
    }
  end

  defp slot_waiting_snapshot(slot_waiting, %State{} = state) do
    slot_waiting
    |> Enum.map(fn {issue_id, entry} ->
      entry
      |> Map.take([:identifier, :title, :state, :reason, :attempt, :since, :connected])
      |> Map.merge(%{
        issue_id: issue_id,
        repo_key: Map.get(entry, :repo_key) || Map.get(entry, :issue_repo_key),
        forced: forced_queued?(issue_id, state)
      })
    end)
    |> Enum.sort_by(& &1.since, DateTime)
  end

  defp dispatch_skipped_snapshot(dispatch_skipped) do
    dispatch_skipped
    |> Enum.map(fn {issue_id, entry} -> Map.put(entry, :issue_id, issue_id) end)
    |> Enum.sort_by(&(&1.identifier || ""))
  end

  # Merging issues held for CI aren't waiting for a slot, but they show in the same list with why.
  defp merging_ci_waiting_snapshot(%State{merging_ci_waits: merging_ci_waits} = state) do
    merging_ci_waits
    |> Enum.map(fn {issue_id, wait} ->
      %{
        issue_id: issue_id,
        repo_key: wait.repo_key || state.repo_key,
        identifier: wait.identifier,
        title: wait.title,
        state: "Merging",
        reason: "waiting for CI on #{wait.commit_sha}",
        attempt: nil,
        since: wait.since,
        forced: forced_queued?(issue_id, state)
      }
    end)
    |> Enum.sort_by(& &1.since, DateTime)
  end

  defp dispatch_slot_label(_state, _issue, true = _forced?), do: "forced"

  defp dispatch_slot_label(%State{} = state, %Issue{} = issue, false = _forced?) do
    if finishing_issue?(issue), do: "finishing", else: EpicLanes.slot_label(state.epic_lanes, issue.id, work_running_ids(state.running))
  end

  defp epic_lane_running(running) do
    running
    |> Map.take(work_running_ids(running))
    |> Map.new(fn {issue_id, entry} ->
      {issue_id, %{identifier: entry.identifier, state: entry.issue.state}}
    end)
  end

  defp linear_rate_limit_snapshot(%State{} = state) do
    now_ms = RateLimit.now_ms()
    status = RateLimit.status(now_ms)

    %{
      rate_limited_for_ms: RateLimit.remaining_pause_ms(now_ms),
      paused_until_ms: status.paused_until_ms,
      window_resets_in_ms: status.window_reset_ms && max(status.window_reset_ms - now_ms, 0),
      poll_interval_multiplier: status.poll_interval_multiplier,
      requests_last_poll: state.linear_requests_last_poll,
      requests_remaining: status.requests_remaining,
      requests_limit: status.requests_limit,
      usage: Usage.snapshot(now_ms)
    }
  end

  # CiPoller.status/0 and PrReviewPoller.status/0 read from a shared ETS
  # table, so this snapshot never blocks on a busy or degraded poller.
  defp poller_status_snapshot do
    %{
      ci: CiPoller.status(),
      pr_review: PrReviewPoller.status()
    }
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    uncached_input_tokens = entry_uncached_input_tokens(running_entry)
    cached_input_tokens = entry_cached_input_tokens(running_entry)
    cache_creation_input_tokens = entry_cache_creation_input_tokens(running_entry)
    output_tokens = entry_output_tokens(running_entry)
    total_tokens = entry_total_tokens(running_entry)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    transcript_path = Map.get(running_entry, :transcript_path)
    pull_request_url = URLUtils.pull_request_url(update) || URLUtils.pull_request_url(running_entry)
    last_reported_uncached_input = last_reported_token(running_entry, :uncached_input)
    last_reported_cached_input = last_reported_token(running_entry, :cached_input)
    last_reported_cache_creation_input = last_reported_token(running_entry, :cache_creation_input)
    last_reported_output = last_reported_token(running_entry, :output)
    last_reported_total = last_reported_token(running_entry, :total)
    turn_count = Map.get(running_entry, :turn_count, 0)
    next_uncached_input_tokens = uncached_input_tokens + token_delta.uncached_input_tokens
    next_cached_input_tokens = cached_input_tokens + token_delta.cached_input_tokens
    next_cache_creation_input_tokens = cache_creation_input_tokens + token_delta.cache_creation_input_tokens
    next_input_tokens = next_uncached_input_tokens + next_cached_input_tokens + next_cache_creation_input_tokens
    next_output_tokens = output_tokens + token_delta.output_tokens
    next_total_tokens = total_tokens + token_delta.total_tokens
    next_last_reported_uncached_input = max(last_reported_uncached_input, token_delta.uncached_input_reported)
    next_last_reported_cached_input = max(last_reported_cached_input, token_delta.cached_input_reported)

    next_last_reported_cache_creation_input =
      max(last_reported_cache_creation_input, token_delta.cache_creation_input_reported)

    next_last_reported_output = max(last_reported_output, token_delta.output_reported)
    next_last_reported_total = max(last_reported_total, token_delta.total_reported)

    {transcript_buffer, transcript_buffer_size} =
      append_transcript_event(
        Map.get(running_entry, :transcript_buffer, :queue.new()),
        Map.get(running_entry, :transcript_buffer_size, 0),
        update,
        transcript_buffer_limit()
      )

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(Map.get(running_entry, :session_id), update),
        transcript_path: transcript_path_for_update(transcript_path, update),
        pull_request_url: pull_request_url,
        last_codex_event: event,
        last_event_at: timestamp,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        input_tokens: next_input_tokens,
        uncached_input_tokens: next_uncached_input_tokens,
        cached_input_tokens: next_cached_input_tokens,
        cache_creation_input_tokens: next_cache_creation_input_tokens,
        output_tokens: next_output_tokens,
        total_tokens: next_total_tokens,
        codex_input_tokens: next_input_tokens,
        codex_cached_input_tokens: next_cached_input_tokens,
        codex_cache_creation_input_tokens: next_cache_creation_input_tokens,
        codex_output_tokens: next_output_tokens,
        codex_total_tokens: next_total_tokens,
        last_reported_uncached_input_tokens: next_last_reported_uncached_input,
        last_reported_cached_input_tokens: next_last_reported_cached_input,
        last_reported_cache_creation_input_tokens: next_last_reported_cache_creation_input,
        last_reported_output_tokens: next_last_reported_output,
        last_reported_total_tokens: next_last_reported_total,
        codex_last_reported_input_tokens: next_last_reported_uncached_input,
        codex_last_reported_cached_input_tokens: next_last_reported_cached_input,
        codex_last_reported_cache_creation_input_tokens: next_last_reported_cache_creation_input,
        codex_last_reported_output_tokens: next_last_reported_output,
        codex_last_reported_total_tokens: next_last_reported_total,
        turn_count: turn_count_for_update(turn_count, Map.get(running_entry, :session_id), update),
        transcript_buffer: transcript_buffer,
        transcript_buffer_size: transcript_buffer_size
      }),
      token_delta
    }
  end

  defp last_reported_token(running_entry, :uncached_input) do
    case Map.get(running_entry, :last_reported_uncached_input_tokens) do
      value when is_integer(value) ->
        value

      _ ->
        legacy_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
        legacy_cached = Map.get(running_entry, :codex_last_reported_cached_input_tokens, 0)
        max(legacy_input - legacy_cached, 0)
    end
  end

  defp last_reported_token(running_entry, :cached_input) do
    Map.get(running_entry, :last_reported_cached_input_tokens, Map.get(running_entry, :codex_last_reported_cached_input_tokens, 0))
  end

  defp last_reported_token(running_entry, :cache_creation_input) do
    Map.get(
      running_entry,
      :last_reported_cache_creation_input_tokens,
      Map.get(running_entry, :codex_last_reported_cache_creation_input_tokens, 0)
    )
  end

  defp last_reported_token(running_entry, :output) do
    Map.get(running_entry, :last_reported_output_tokens, Map.get(running_entry, :codex_last_reported_output_tokens, 0))
  end

  defp last_reported_token(running_entry, :total) do
    Map.get(running_entry, :last_reported_total_tokens, Map.get(running_entry, :codex_last_reported_total_tokens, 0))
  end

  defp append_transcript_event(_queue, _size, _event, limit) when not is_integer(limit) or limit <= 0,
    do: {:queue.new(), 0}

  defp append_transcript_event(queue, _size, event, limit) do
    queue = if :queue.is_queue(queue), do: queue, else: :queue.new()

    size = :queue.len(queue)

    event
    |> :queue.in(queue)
    |> trim_transcript_buffer(size + 1, limit)
  end

  defp trim_transcript_buffer(queue, size, limit) when size > limit do
    {{:value, _event}, queue} = :queue.out(queue)
    trim_transcript_buffer(queue, size - 1, limit)
  end

  defp trim_transcript_buffer(queue, size, _limit), do: {queue, size}

  defp transcript_buffer_limit do
    Config.settings!().observability
    |> Map.get(:transcript_buffer_size, @default_transcript_buffer_size)
    |> case do
      limit when is_integer(limit) and limit >= 0 -> limit
      _ -> @default_transcript_buffer_size
    end
  end

  defp transcript_buffer_list(%{transcript_buffer: queue}) do
    cond do
      :queue.is_queue(queue) -> :queue.to_list(queue)
      is_list(queue) -> queue
      true -> []
    end
  end

  defp transcript_buffer_list(_metadata), do: []

  defp transcript_buffer_size(%{transcript_buffer: _buffer} = metadata),
    do: length(transcript_buffer_list(metadata))

  defp transcript_buffer_size(%{transcript_buffer_size: size}) when is_integer(size) and size >= 0,
    do: size

  defp transcript_buffer_size(metadata) when is_map(metadata), do: length(transcript_buffer_list(metadata))

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp transcript_path_for_update(_existing, %{transcript_path: transcript_path})
       when is_binary(transcript_path),
       do: transcript_path

  defp transcript_path_for_update(existing, update) when is_map(update) do
    case Map.get(update, "transcript_path") || Map.get(update, :transcriptPath) || Map.get(update, "transcriptPath") do
      transcript_path when is_binary(transcript_path) -> transcript_path
      _ -> existing
    end
  end

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_watchdog_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.watchdog_timer_ref) do
      Process.cancel_timer(state.watchdog_timer_ref)
    end

    watchdog_token = make_ref()
    timer_ref = Process.send_after(self(), {:watchdog_tick, watchdog_token}, delay_ms)

    %{
      state
      | watchdog_timer_ref: timer_ref,
        watchdog_token: watchdog_token
    }
  end

  defp watchdog_tick_interval_ms do
    Config.settings!().watchdog.tick_interval_ms
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp remember_completed_run(%State{} = state, issue_id, running_entry) when is_binary(issue_id) do
    if watchable_linear_issue_id?(issue_id) do
      %{
        state
        | completed: MapSet.put(state.completed, issue_id),
          completed_run_metadata: Map.put(state.completed_run_metadata, issue_id, completed_run_metadata(running_entry))
      }
    else
      state
    end
  end

  defp remember_completed_run(state, _issue_id, _running_entry), do: state

  defp maybe_track_completed_run(state, issue_id, running_entry, cleanup_workspace, opts) do
    cond do
      Keyword.get(opts, :track_completed_run, false) ->
        remember_completed_run(state, issue_id, running_entry)

      cleanup_workspace ->
        forget_completed_issue(state, issue_id)

      true ->
        state
    end
  end

  defp completed_run_metadata(running_entry) when is_map(running_entry) do
    issue = Map.get(running_entry, :issue)

    %{
      repo_key: Map.get(running_entry, :repo_key),
      run_id: Map.get(running_entry, :run_id),
      identifier: Map.get(running_entry, :identifier) || issue_identifier(issue),
      title: running_entry_title(running_entry),
      url: issue_url(issue),
      pull_request_url: running_entry_pr_url(running_entry),
      last_ran_at: DateTime.utc_now(),
      comment_ids: Map.get(running_entry, :comment_ids),
      session_id: Map.get(running_entry, :session_id),
      started_at: Map.get(running_entry, :started_at),
      last_event_at: Map.get(running_entry, :last_event_at) || Map.get(running_entry, :last_codex_timestamp),
      turn_count: Map.get(running_entry, :turn_count, 0),
      tokens: run_tokens(running_entry),
      reviewer_tokens: reviewer_tokens(running_entry),
      review_agent_enabled: Map.get(running_entry, :review_agent_enabled, false),
      transcript_path: Map.get(running_entry, :transcript_path),
      transcript_buffer: transcript_buffer_list(running_entry),
      transcript_buffer_size: transcript_buffer_size(running_entry),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    }
    |> maybe_put_runtime_value(:linked, Map.get(running_entry, :linked))
  end

  defp put_watching_issue(%State{} = state, %Issue{id: issue_id} = issue) when is_binary(issue_id) do
    if watchable_linear_issue_id?(issue_id) do
      do_put_watching_issue(state, issue_id, issue)
    else
      state
    end
  end

  defp put_watching_issue(state, _issue), do: state

  defp do_put_watching_issue(%State{} = state, issue_id, %Issue{} = issue) do
    completed_metadata = Map.get(state.completed_run_metadata, issue_id, %{})
    existing = Map.get(state.watching, issue_id, %{})

    state =
      if existing == %{} do
        maybe_emit_awaiting_review(state, issue, completed_metadata)
      else
        state
      end

    completed_metadata = Map.get(state.completed_run_metadata, issue_id, completed_metadata)
    # The parent and links the last run's enrichment read; each poll's issue carries neither.
    linked = watching_metadata(:linked, completed_metadata, existing)

    repo_key = watching_repo_key(state, issue, completed_metadata, existing)

    watching_entry = %{
      repo_key: repo_key,
      identifier: watching_identifier(issue, issue_id, completed_metadata, existing),
      title: watching_title(issue, completed_metadata, existing),
      state: issue.state,
      url: watching_url(issue, completed_metadata, existing),
      pull_request_url: watching_pull_request_url(issue, repo_key, completed_metadata, existing),
      last_ran_at: watching_last_ran_at(completed_metadata, existing),
      session_id: watching_metadata(:session_id, completed_metadata, existing),
      started_at: watching_metadata(:started_at, completed_metadata, existing),
      last_event_at: watching_metadata(:last_event_at, completed_metadata, existing),
      turn_count: watching_metadata(:turn_count, completed_metadata, existing, 0),
      tokens: watching_metadata(:tokens, completed_metadata, existing, %{}),
      reviewer_tokens: watching_metadata(:reviewer_tokens, completed_metadata, existing, %{}),
      review_agent_enabled: watching_metadata(:review_agent_enabled, completed_metadata, existing, false),
      transcript_path: watching_metadata(:transcript_path, completed_metadata, existing),
      transcript_buffer: watching_metadata(:transcript_buffer, completed_metadata, existing, []),
      transcript_buffer_size: watching_metadata(:transcript_buffer_size, completed_metadata, existing, 0),
      linked: linked
    }

    watching_entry = Map.put(watching_entry, :connected, Connected.build(issue, linked))
    %{state | watching: Map.put(state.watching, issue_id, watching_entry)}
  end

  defp watchable_linear_issue_id?("pr:" <> _rest), do: false
  defp watchable_linear_issue_id?(issue_id) when is_binary(issue_id), do: String.trim(issue_id) != ""
  defp watchable_linear_issue_id?(_issue_id), do: false

  defp watching_repo_key(%State{} = state, issue, completed_metadata, existing) do
    issue_repo_key(issue) ||
      repo_key_from(completed_metadata) ||
      repo_key_from(existing) ||
      state.repo_key
  end

  defp watching_identifier(%Issue{identifier: identifier}, issue_id, completed_metadata, existing) do
    identifier ||
      Map.get(completed_metadata, :identifier) ||
      Map.get(existing, :identifier) ||
      issue_id
  end

  defp watching_title(%Issue{title: title}, completed_metadata, existing) do
    title ||
      Map.get(completed_metadata, :title) ||
      Map.get(existing, :title)
  end

  defp watching_url(issue, completed_metadata, existing) do
    issue_url(issue) ||
      URLUtils.present_url(Map.get(completed_metadata, :url)) ||
      URLUtils.present_url(Map.get(existing, :url))
  end

  defp watching_pull_request_url(issue, repo_key, completed_metadata, existing) do
    ticket_pr_url(issue, repo_key) ||
      URLUtils.pull_request_url(completed_metadata) ||
      URLUtils.pull_request_url(existing)
  end

  defp watching_last_ran_at(completed_metadata, existing) do
    Map.get(completed_metadata, :last_ran_at) ||
      Map.get(existing, :last_ran_at) ||
      DateTime.utc_now()
  end

  defp watching_metadata(key, completed_metadata, existing, default \\ nil) do
    case Map.fetch(completed_metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(existing, key, default)
    end
  end

  defp forget_completed_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    %{
      state
      | completed: MapSet.delete(state.completed, issue_id),
        completed_run_metadata: Map.delete(state.completed_run_metadata, issue_id),
        watching: Map.delete(state.watching, issue_id),
        quiet_handoff_runs: Map.delete(state.quiet_handoff_runs, issue_id)
    }
  end

  defp forget_completed_issue(state, _issue_id), do: state

  # The removal of a terminal ticket's workspace: the `before_remove` hook gets the `terminal`
  # reason and the state the ticket reached.
  defp terminal_workspace_context(%Issue{} = issue, repo_key) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      repo_key: repo_key,
      labels: issue.labels || [],
      remove_reason: :terminal,
      state: issue.state
    }
  end

  defp issue_identifier(%Issue{identifier: identifier}), do: identifier
  defp issue_identifier(_issue), do: nil

  defp running_entry_title(entry) when is_map(entry) do
    case Map.get(entry, :issue) do
      %Issue{title: title} -> title
      _ -> Map.get(entry, :title)
    end
  end

  defp running_entry_title(_entry), do: nil

  defp issue_url(%Issue{url: url}), do: URLUtils.present_url(url)
  defp issue_url(_issue), do: nil

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          uncached_input_tokens: 0,
          cached_input_tokens: 0,
          cache_creation_input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    persist_codex_totals(codex_totals)
    %{state | codex_totals: codex_totals}
  end

  defp refresh_runtime_config(%State{} = state) do
    case Config.settings() do
      {:ok, config} ->
        state = reset_daily_budget_if_needed(state)

        %{
          state
          | poll_interval_ms: config.polling.interval_ms,
            max_concurrent_agents: config.agent.max_concurrent_agents
        }

      {:error, reason} ->
        Logger.error("Failed to refresh runtime config: #{inspect(reason)}")
        state
    end
  end

  defp reset_daily_budget_if_needed(%State{} = state) do
    today = Date.utc_today()

    case state.budget_day_started_on do
      ^today ->
        state

      nil ->
        %{state | budget_day_started_on: today, budget_daily_used: 0, budget_daily_paused_logged: false}

      previous_day ->
        Logger.info("Resetting daily token budget previous_day=#{Date.to_iso8601(previous_day)} previous_daily_used=#{state.budget_daily_used}")

        %{state | budget_day_started_on: today, budget_daily_used: 0, budget_daily_paused_logged: false}
    end
  end

  defp daily_budget_paused?(%State{} = state) do
    case Config.settings!().agent.max_tokens_per_day do
      limit when is_integer(limit) and limit > 0 -> state.budget_daily_used >= limit
      _ -> false
    end
  end

  defp operator_paused?(%State{pause: %{paused: true}}), do: true
  defp operator_paused?(_state), do: false

  # Usage-limit holds (`agent.usage_limit`) are kept apart from the operator pause: resuming
  # one never sets or clears the other.
  defp put_usage_limit(%State{} = state, info, identifier) do
    key = UsageLimit.key(info)
    existing = Map.get(state.usage_limits, key)
    last_outage = Map.get(state.api_outages, key)

    entry =
      UsageLimit.put(existing, info,
        now: state.clock.(),
        config: Config.settings!().agent.usage_limit,
        windows: state.usage_windows,
        issue_identifier: identifier,
        last_outage: last_outage
      )

    {state, continued_outage} = settle_api_outage(state, key, last_outage, info, entry)
    newly_paused? = (is_nil(existing) or existing.phase == :headroom) and is_nil(continued_outage)
    if newly_paused?, do: emit_usage_limit_event(:usage_limit_paused, entry, issue_identifier: identifier)
    log_usage_limit_put(entry, existing || continued_outage, identifier, newly_paused?)

    state = put_usage_limits(state, Map.put(state.usage_limits, key, entry))
    {arm_usage_limit_timer(state, key, entry), entry}
  end

  defp log_usage_limit_put(entry, existing, identifier, newly_paused?) do
    cond do
      entry == existing ->
        :ok

      UsageLimit.api_unreachable?(entry) ->
        log_model_api_unreachable(entry, existing, identifier)

      match?(%{phase: :canary}, existing) ->
        Logger.warning(
          "Usage limit still active provider=#{entry.provider} scope=#{UsageLimit.scope_label(entry.scope)} " <>
            "next_resume_at=#{DateTime.to_iso8601(entry.resume_at)} issue_identifier=#{identifier}"
        )

      newly_paused? or existing.resume_at != entry.resume_at ->
        Logger.warning(
          "Usage limit pause provider=#{entry.provider} scope=#{UsageLimit.scope_label(entry.scope)} window=#{entry.window || "unknown"} " <>
            "resets_at=#{format_optional_datetime(entry.resets_at)} resume_at=#{DateTime.to_iso8601(entry.resume_at)} source=#{entry.source || "unknown"} issue_identifier=#{identifier}"
        )

      true ->
        :ok
    end
  end

  # A run that finds a released outage again continues it: no new pause event, and the outage is
  # no longer due to end. A usage limit from the API shows the API is back.
  defp settle_api_outage(%State{} = state, _key, nil, _info, _entry), do: {state, nil}

  defp settle_api_outage(%State{} = state, key, last_outage, info, entry) do
    cond do
      UsageLimit.api_unreachable?(entry) and entry.since == last_outage.since ->
        {%{state | api_outages: Map.delete(state.api_outages, key)}, last_outage}

      UsageLimit.api_unreachable?(info) ->
        {state, nil}

      true ->
        {finish_api_outage(state, key, last_outage), nil}
    end
  end

  # One line when the outage is found, then one per probe that still can't get through.
  defp log_model_api_unreachable(entry, existing, identifier) do
    if UsageLimit.api_unreachable?(existing || %{}) do
      Logger.warning(
        "Model API still unreachable (#{entry.error}) provider=#{entry.provider} " <>
          "next_probe_at=#{DateTime.to_iso8601(entry.resume_at)} issue_identifier=#{identifier}"
      )
    else
      Logger.warning(
        "Model API unreachable (#{entry.error}); holding dispatch provider=#{entry.provider} " <>
          "probe_at=#{DateTime.to_iso8601(entry.resume_at)} issue_identifier=#{identifier}"
      )
    end
  end

  # `agent.usage_limit.headroom_utilization`: an allowed_warning at or above it holds new runs of
  # the provider until the window resets. A pause or canary already in place is left as it is.
  defp hold_for_usage_headroom(%State{} = state, running_entry, %{usage_windows: %{} = windows}) do
    case Config.settings!().agent.usage_limit.headroom_utilization do
      threshold when is_number(threshold) ->
        windows
        |> UsageLimit.headroom_crossings(threshold, state.clock.())
        |> Enum.reduce(state, &put_usage_headroom(&2, &1, threshold, running_entry.identifier))

      nil ->
        state
    end
  end

  defp hold_for_usage_headroom(%State{} = state, _running_entry, _update), do: state

  defp put_usage_headroom(%State{} = state, info, threshold, identifier) do
    key = UsageLimit.key(info)

    case Map.get(state.usage_limits, key) do
      %{phase: phase} when phase != :headroom ->
        state

      existing ->
        entry =
          UsageLimit.put_headroom(existing, info,
            now: state.clock.(),
            config: Config.settings!().agent.usage_limit,
            issue_identifier: identifier
          )

        if entry == existing, do: state, else: hold_new_runs_for_headroom(state, key, existing, entry, threshold)
    end
  end

  defp hold_new_runs_for_headroom(%State{} = state, key, existing, entry, threshold) do
    if is_nil(existing) do
      emit_usage_limit_event(:usage_limit_headroom, entry, issue_identifier: entry.issue_identifier)
    end

    Logger.warning(
      "Usage limit headroom hold provider=#{entry.provider} utilization=#{entry.utilization} threshold=#{threshold} " <>
        "scope=#{UsageLimit.scope_label(entry.scope)} window=#{entry.window} resets_at=#{DateTime.to_iso8601(entry.resets_at)} " <>
        "resume_at=#{DateTime.to_iso8601(entry.resume_at)} issue_identifier=#{entry.issue_identifier}"
    )

    state = put_usage_limits(state, Map.put(state.usage_limits, key, entry))
    arm_usage_limit_timer(state, key, entry)
  end

  # A headroom hold clears at `resume_at` without a canary: runs that went on under it already
  # showed the provider still serves requests.
  defp maybe_clear_usage_headroom(%State{} = state, key, entry) do
    if UsageLimit.remaining_ms(entry, state.clock.()) > 0 do
      arm_usage_limit_timer(state, key, entry)
    else
      clear_usage_limit(state, key, entry)
    end
  end

  defp put_usage_limits(%State{} = state, usage_limits) do
    usage_limits
    |> RunStore.put_usage_limits()
    |> log_run_store_error("persist usage limits")

    %{state | usage_limits: usage_limits}
  end

  # One event per hold transition: a new hold and its clearing. A refreshed hold, or a run
  # hitting a hold already in place, emits nothing.
  defp emit_usage_limit_event(event, entry, attrs \\ []) do
    reason =
      case event do
        :usage_limit_paused -> "#{UsageLimit.limit_label(entry)}; resumes at #{DateTime.to_iso8601(entry.resume_at)}"
        :usage_limit_headroom -> "#{UsageLimit.limit_label(entry)} at #{round(entry.utilization * 100)}%; holding new runs until #{DateTime.to_iso8601(entry.resume_at)}"
        :usage_limit_resumed -> UsageLimit.limit_label(entry)
      end

    Notifications.emit_event(
      event,
      Map.merge(Map.new(attrs), %{
        reason: reason,
        metadata: %{
          provider: entry.provider,
          scope: UsageLimit.scope_label(entry.scope),
          window: entry.window,
          since: entry.since,
          resets_at: entry.resets_at,
          resume_at: entry.resume_at,
          source: entry.source
        }
      })
    )
  end

  defp format_optional_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_optional_datetime(nil), do: "unknown"

  defp usage_limit_error(%{phase: :headroom} = entry) do
    "usage limit headroom hold (provider=#{entry.provider} scope=#{UsageLimit.scope_label(entry.scope)}); resuming at #{DateTime.to_iso8601(entry.resume_at)}"
  end

  defp usage_limit_error(%{reason: "model_api_unreachable"} = entry) do
    "model API unreachable (provider=#{entry.provider} error=#{entry.error}); probing again at #{DateTime.to_iso8601(entry.resume_at)}"
  end

  defp usage_limit_error(entry) do
    "usage limit reached (provider=#{entry.provider} scope=#{UsageLimit.scope_label(entry.scope)}); resuming at #{DateTime.to_iso8601(entry.resume_at)}"
  end

  defp arm_usage_limit_timers(%State{} = state) do
    Enum.reduce(state.usage_limits, state, fn {key, entry}, acc -> arm_usage_limit_timer(acc, key, entry) end)
  end

  defp arm_usage_limit_timer(%State{} = state, key, entry) do
    case Map.get(state.usage_limit_timers, key) do
      timer_ref when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      nil -> :ok
    end

    timer_ref = Process.send_after(self(), {:usage_limit_resume, key}, UsageLimit.remaining_ms(entry, state.clock.()))
    %{state | usage_limit_timers: Map.put(state.usage_limit_timers, key, timer_ref)}
  end

  # A timer that fires before `resume_at` (the hold was refreshed) is armed again.
  defp maybe_resume_usage_limit(%State{} = state, key, entry) do
    if UsageLimit.remaining_ms(entry, state.clock.()) > 0 do
      arm_usage_limit_timer(state, key, entry)
    else
      start_usage_limit_canary(state, key, entry, &Tracker.fetch_issue_states_by_ids/1)
    end
  end

  # At `resume_at` one held run goes out alone as the canary, first in dispatch order, while the
  # hold keeps every other run of the provider back. With nothing held the hold just clears. The
  # held issues are read in a tracker task to order them; the hold stays as it is until it answers.
  defp start_usage_limit_canary(%State{} = state, key, entry, issue_fetcher) do
    state = %{state | usage_limit_timers: Map.delete(state.usage_limit_timers, key)}
    held = held_usage_limit_retries(state, key)

    cond do
      held == [] -> end_usage_limit_without_canary(state, key, entry)
      usage_limit_canary_read_in_flight?(state, key) -> state
      true -> start_usage_limit_canary_read(state, key, held, issue_fetcher)
    end
  end

  defp start_usage_limit_canary_read(%State{} = state, key, held, issue_fetcher) do
    issue_ids = held |> Enum.map(fn {issue_id, _retry} -> issue_id end) |> Enum.sort()
    context = %{kind: :usage_limit_canary, key: key, issue_ids: issue_ids}
    start_tracker_task(state, context, fn -> issue_fetcher.(issue_ids) end)
  end

  defp end_usage_limit_without_canary(%State{} = state, key, entry) do
    if UsageLimit.api_unreachable?(entry),
      do: release_api_outage(state, key, entry),
      else: clear_usage_limit(state, key, entry)
  end

  defp usage_limit_canary_read_in_flight?(%State{tracker_tasks: tasks}, key) do
    Enum.any?(tasks, fn {_ref, context} -> context.kind == :usage_limit_canary and context.key == key end)
  end

  # The hold may have moved on while its issues were read: cleared, refreshed with time left (its
  # timer is armed again), or given a canary that is still alive. Only a hold still waiting for its
  # canary picks one, from the runs held now. A read that failed or died orders them by id, as the
  # tracker not returning them does.
  defp finish_usage_limit_canary_read(%State{} = state, %{key: key}, result) do
    with {:ok, entry} <- Map.fetch(state.usage_limits, key),
         true <- usage_limit_waiting_for_canary?(state, entry) do
      case held_usage_limit_retries(state, key) do
        [] -> end_usage_limit_without_canary(state, key, entry)
        held -> dispatch_usage_limit_canary(state, key, entry, held, result)
      end
    else
      _moved_on -> state
    end
  end

  defp usage_limit_waiting_for_canary?(%State{} = state, %{phase: :canary} = entry), do: not usage_limit_canary_alive?(state, entry.canary_issue_id)
  defp usage_limit_waiting_for_canary?(%State{} = state, %{phase: :paused} = entry), do: UsageLimit.remaining_ms(entry, state.clock.()) == 0
  defp usage_limit_waiting_for_canary?(%State{}, _entry), do: false

  defp dispatch_usage_limit_canary(%State{} = state, key, entry, held, result) do
    {issue_id, retry} = pick_usage_limit_canary(held, result, state)
    Logger.warning("Usage limit canary provider=#{entry.provider} scope=#{UsageLimit.scope_label(entry.scope)} issue_identifier=#{retry[:identifier]}")

    state
    |> put_usage_limits(Map.put(state.usage_limits, key, UsageLimit.canary(entry, issue_id)))
    |> release_usage_limit_retry(issue_id, retry)
    |> schedule_immediate_tick()
  end

  # A held retry that comes due while its hold's canary read is in flight stays held, so the pick
  # sees it; the pick releases it, or it waits the unknown-reset interval as under a canary.
  defp held_for_canary_read?(%State{} = state, issue_id, retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{retry_token: ^retry_token, usage_limit_key: key} when not is_nil(key) ->
        usage_limit_canary_read_in_flight?(state, key)

      _retry ->
        false
    end
  end

  defp keep_held_for_canary_read(%State{} = state, issue_id) do
    retry = Map.fetch!(state.retry_attempts, issue_id)
    delay_ms = unknown_reset_retry_ms()
    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry.retry_token}, delay_ms)
    retry = Map.merge(retry, %{timer_ref: timer_ref, due_at_ms: System.monotonic_time(:millisecond) + delay_ms})
    %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, retry)}
  end

  defp held_usage_limit_retries(%State{} = state, key) do
    Enum.filter(state.retry_attempts, fn {_issue_id, retry} -> Map.get(retry, :usage_limit_key) == key end)
  end

  # Issues the tracker no longer returns sort last, by id. A forced ticket goes first.
  defp pick_usage_limit_canary(held, result, %State{} = state) do
    held_by_id = Map.new(held)
    issue_ids = held_by_id |> Map.keys() |> Enum.sort()

    ordered_ids =
      case result do
        {:ok, issues} -> issues |> sort_issues_for_dispatch() |> forced_first(state) |> Enum.map(& &1.id)
        {:error, _reason} -> []
      end

    issue_id = Enum.find(ordered_ids ++ issue_ids, &Map.has_key?(held_by_id, &1))
    {issue_id, Map.fetch!(held_by_id, issue_id)}
  end

  # Held retries go back to normal candidate selection with their attempt, as a retry waiting
  # for a slot does; the immediate tick dispatches them unless another gate still applies.
  defp clear_usage_limit(%State{} = state, key, entry) do
    Logger.warning("Usage limit resumed provider=#{entry.provider} scope=#{UsageLimit.scope_label(entry.scope)} paused_for_s=#{DateTime.diff(state.clock.(), entry.since)}")
    emit_usage_limit_event(:usage_limit_resumed, entry)

    state =
      state
      |> put_usage_limits(Map.delete(state.usage_limits, key))
      |> Map.update!(:usage_limit_timers, &Map.delete(&1, key))

    state
    |> held_usage_limit_retries(key)
    |> Enum.reduce(state, fn {issue_id, retry}, acc -> release_usage_limit_retry(acc, issue_id, retry) end)
    |> schedule_immediate_tick()
  end

  # An unreachable-API hold with no run held on it (a hold taken outside an agent run) has no
  # canary: it is released so the next run probes the API, and remembered so a run that finds
  # the outage again continues it. The outage ends, with its resumed event, when no run has found
  # it again for `UsageLimit.outage_memory_seconds/1`.
  defp release_api_outage(%State{} = state, key, entry) do
    memory_seconds = UsageLimit.outage_memory_seconds(Config.settings!().agent.usage_limit)
    Logger.info("Model API hold released provider=#{entry.provider}; the next run probes the API")
    Process.send_after(self(), {:api_outage_over, key, entry.since}, memory_seconds * 1000)

    state
    |> put_usage_limits(Map.delete(state.usage_limits, key))
    |> Map.update!(:api_outages, &Map.put(&1, key, entry))
    |> schedule_immediate_tick()
  end

  defp finish_api_outage(%State{} = state, key, outage) do
    Logger.warning("Usage limit resumed provider=#{outage.provider} scope=#{UsageLimit.scope_label(outage.scope)} paused_for_s=#{DateTime.diff(outage.resume_at, outage.since)}")
    emit_usage_limit_event(:usage_limit_resumed, outage)
    %{state | api_outages: Map.delete(state.api_outages, key)}
  end

  defp schedule_immediate_tick(%State{} = state) do
    if poll_tick_coalesced?(state, System.monotonic_time(:millisecond)), do: state, else: schedule_tick(state, 0)
  end

  # The canary's first `rate_limit_event` came back allowed: only allowed events carry
  # `usage_windows`. A rejection ends the run instead (see finish_usage_limit_canary/2).
  defp clear_usage_limit_on_allowed_canary(%State{} = state, issue_id, %{usage_windows: %{} = windows}) when map_size(windows) > 0 do
    clear_usage_limit_canaries(state, issue_id)
  end

  defp clear_usage_limit_on_allowed_canary(%State{} = state, _issue_id, _update), do: state

  # A canary that hit the same limit was paused again by pause_for_usage_limit/5. Any other end
  # (success, a non-limit failure, another window's limit) clears the hold it was probing; the
  # run itself follows its normal path.
  defp finish_usage_limit_canary(%State{} = state, issue_id), do: clear_usage_limit_canaries(state, issue_id)

  defp clear_usage_limit_canaries(%State{} = state, issue_id) do
    state.usage_limits
    |> Enum.filter(fn {_key, entry} -> UsageLimit.canary?(entry, issue_id) end)
    |> Enum.reduce(state, fn {key, entry}, acc -> clear_usage_limit(acc, key, entry) end)
  end

  # A canary that left the active states before it ran is replaced by the next held run.
  defp recover_usage_limit_canaries(%State{} = state) do
    state.usage_limits
    |> Enum.filter(fn {_key, entry} -> entry.phase == :canary and not usage_limit_canary_alive?(state, entry.canary_issue_id) end)
    |> Enum.reduce(state, fn {key, entry}, acc ->
      Logger.info("Usage limit canary gone provider=#{entry.provider} scope=#{UsageLimit.scope_label(entry.scope)} issue_id=#{entry.canary_issue_id}; choosing another")
      start_usage_limit_canary(acc, key, entry, &Tracker.fetch_issue_states_by_ids/1)
    end)
  end

  defp usage_limit_canary_alive?(%State{} = state, issue_id) do
    issue_claimed_or_running?(state, issue_id) or Map.has_key?(state.retry_attempts, issue_id) or
      Map.has_key?(state.slot_waiting, issue_id)
  end

  defp waiting_retry_held?(waiting, %Issue{} = issue, %State{} = state) do
    retry_attempt?(Map.get(waiting, :attempt)) and not is_nil(usage_limit_hold(state, issue))
  end

  # The retry takes its claim back, as a held retry keeps it, so no poll dispatches it afresh.
  defp hold_waiting_retry_for_usage_limit(%State{} = state, %Issue{} = issue, waiting) do
    metadata = Map.take(waiting, [:repo_key, :worker_host])

    %{state | claimed: MapSet.put(state.claimed, issue.id)}
    |> hold_retry_for_usage_limit(issue, waiting.attempt, metadata, usage_limit_hold(state, issue))
  end

  defp release_usage_limit_retry(%State{} = state, issue_id, retry) do
    if is_reference(retry[:timer_ref]), do: Process.cancel_timer(retry.timer_ref)
    issue = %Issue{id: issue_id, identifier: retry[:identifier], title: retry[:title]}
    metadata = %{repo_key: retry[:repo_key], worker_host: retry[:worker_host]}

    state
    |> wait_for_slot(issue, retry.attempt, metadata, "usage limit resumed")
    |> Map.update!(:retry_attempts, &Map.delete(&1, issue_id))
  end

  defp usage_limit_held?(%Issue{} = issue, %State{} = state) do
    case usage_limit_hold(state, issue) do
      nil ->
        false

      entry ->
        Logger.debug("Skipping dispatch; usage limit holds provider=#{entry.provider} scope=#{UsageLimit.scope_label(entry.scope)} for #{issue_context(issue)}")
        true
    end
  end

  # The run's provider and model come from its run profile, resolved as at dispatch. A
  # continuation of a run that just ended, or a forced ticket's run, is not held by a headroom hold.
  defp usage_limit_hold(state, issue, continuation? \\ false)

  defp usage_limit_hold(%State{usage_limits: usage_limits}, _issue, _continuation?) when map_size(usage_limits) == 0, do: nil

  defp usage_limit_hold(%State{usage_limits: usage_limits} = state, %Issue{} = issue, continuation?) do
    profile = run_profile_for_issue(state, issue)
    UsageLimit.holding(usage_limits, Map.merge(profile, %{continuation: continuation?, forced: forced_issue?(issue, state)}), issue.id)
  end

  # The run's provider and model, resolved as at dispatch.
  defp run_profile_for_issue(%State{} = state, %Issue{} = issue) do
    repo_key = dispatch_repo_key(state, issue)
    AgentRunner.run_profile(issue, Config.settings_for_repo!(repo_key), repo_key: repo_key)
  end

  defp remember_usage_windows(%State{} = state, %{usage_windows: %{} = windows}) do
    %{state | usage_windows: UsageLimit.remember_windows(state.usage_windows, windows)}
  end

  defp remember_usage_windows(%State{} = state, _update), do: state

  defp persisted_usage_limits do
    case RunStore.get_usage_limits() do
      %{} = usage_limits ->
        usage_limits

      {:error, reason} ->
        Logger.warning("Failed to restore usage limits from run store: #{inspect(reason)}")
        %{}
    end
  end

  defp workspace_quota_status_from_config do
    min_free_bytes = Config.settings!().workspace.lifecycle.min_free_bytes

    if is_integer(min_free_bytes) and min_free_bytes > 0 do
      workspace_quota_status(min_free_bytes)
    else
      %{configured?: false, paused: false, reason: nil}
    end
  end

  defp apply_workspace_quota_result(%State{} = state, %{configured?: false} = quota) do
    %{
      state
      | workspace_lifecycle_quota: quota,
        workspace_quota_logged: false
    }
  end

  defp apply_workspace_quota_result(%State{} = state, %{paused: paused?} = quota) do
    logged? = if paused?, do: state.workspace_quota_logged, else: false
    %{state | workspace_lifecycle_quota: quota, workspace_quota_logged: logged?}
  end

  defp apply_workspace_quota_result(%State{} = state, quota) do
    Logger.warning("Ignoring invalid workspace quota result: #{inspect(quota)}")
    state
  end

  defp workspace_quota_status(min_free_bytes) do
    host_statuses =
      workspace_quota_hosts()
      |> Enum.map(&workspace_quota_host_status(&1, min_free_bytes))

    paused? = Enum.any?(host_statuses, &Map.get(&1, :paused))
    reason = host_statuses |> Enum.filter(&Map.get(&1, :paused)) |> Enum.map_join("; ", & &1.reason)
    free_values = host_statuses |> Enum.map(&Map.get(&1, :free_bytes)) |> Enum.filter(&is_integer/1)

    %{
      configured?: true,
      paused: paused?,
      reason: if(reason == "", do: nil, else: reason),
      free_bytes: Enum.min(free_values, fn -> nil end),
      min_free_bytes: min_free_bytes,
      checked_at: DateTime.utc_now(),
      hosts: host_statuses
    }
  end

  defp workspace_quota_hosts do
    case Config.settings!().worker.ssh_hosts do
      hosts when is_list(hosts) and hosts != [] -> hosts
      _ -> [nil]
    end
  end

  defp workspace_quota_host_status(worker_host, min_free_bytes) do
    host = quota_host_label(worker_host)

    case Workspace.free_bytes(worker_host) do
      {:ok, free_bytes} ->
        paused? = free_bytes < min_free_bytes

        %{
          worker_host: host,
          free_bytes: free_bytes,
          min_free_bytes: min_free_bytes,
          paused: paused?,
          reason:
            if(paused?,
              do: "workspace free space below threshold host=#{host} free_bytes=#{free_bytes} min_free_bytes=#{min_free_bytes}"
            )
        }

      {:error, reason} ->
        %{
          worker_host: host,
          free_bytes: nil,
          min_free_bytes: min_free_bytes,
          paused: true,
          reason: "workspace free-space check failed host=#{host} reason=#{inspect(reason)}"
        }
    end
  end

  defp quota_host_label(nil), do: "local"
  defp quota_host_label(worker_host), do: worker_host

  defp workspace_quota_paused?(%State{workspace_lifecycle_quota: %{paused: true}}), do: true
  defp workspace_quota_paused?(_state), do: false

  defp log_workspace_quota_pause(%State{workspace_quota_logged: true} = state), do: state

  defp log_workspace_quota_pause(%State{} = state) do
    Logger.warning("Workspace free-space threshold not met #{workspace_quota_error(state)}; pausing new dispatch")

    %{state | workspace_quota_logged: true}
  end

  defp workspace_quota_error(%State{workspace_lifecycle_quota: %{reason: reason}}) when is_binary(reason),
    do: reason

  defp workspace_quota_error(_state), do: "workspace free-space threshold not met"

  defp log_operator_pause(%State{operator_pause_logged: true} = state), do: state

  defp log_operator_pause(%State{} = state) do
    pause = state.pause || unpaused_state()

    if Map.get(pause, :paused) == true do
      Logger.warning("Operator dispatch pause active reason=#{inspect(Map.get(pause, :reason))} paused_at=#{inspect(Map.get(pause, :paused_at))}; skipping dispatch")
      %{state | operator_pause_logged: true}
    else
      state
    end
  end

  defp log_daily_budget_pause(%State{budget_daily_paused_logged: true} = state), do: state

  defp log_daily_budget_pause(%State{} = state) do
    case Config.settings!().agent.max_tokens_per_day do
      limit when is_integer(limit) and limit > 0 and state.budget_daily_used >= limit ->
        Logger.warning("Daily token budget exhausted daily_used=#{state.budget_daily_used} daily_limit=#{limit} day_started_on=#{Date.to_iso8601(state.budget_day_started_on)}; pausing new dispatch")
        %{state | budget_daily_paused_logged: true}

      _ ->
        state
    end
  end

  defp budget_snapshot(%State{} = state) do
    agent = Config.settings!().agent
    daily_limit = agent.max_tokens_per_day
    daily_used = max(state.budget_daily_used || 0, 0)

    %{
      per_issue_limit: agent.max_tokens_per_issue,
      daily_limit: daily_limit,
      daily_used: daily_used,
      daily_remaining: budget_remaining(daily_limit, daily_used),
      daily_paused: daily_budget_paused?(state)
    }
  end

  defp dispatch_state_snapshot(%State{} = state) do
    settings = Config.settings!()
    agent = settings.agent

    SymphonyElixir.DispatchState.compute(
      %{
        pause: state.pause || unpaused_state(),
        budget_daily_used: state.budget_daily_used,
        budget_day_started_on: state.budget_day_started_on,
        tracker_health: state.tracker_health,
        usage_limits: UsageLimit.snapshot(state.usage_limits, state.usage_windows)
      },
      %{
        run_profiles: run_profiles_in_use(state, settings),
        daily_limit: agent.max_tokens_per_day,
        quality_gate: settings.quality_gate,
        learnings: settings.learnings,
        tracker_kind: settings.tracker.kind,
        tracker_api_key_present?: Secret.present?(settings.tracker.api_key)
      },
      System.get_env()
    )
  end

  # Every provider and model a run could resolve to, across run kinds and configured repos.
  # Only needed (and only resolved) while a usage-limit hold is in place.
  defp run_profiles_in_use(%State{usage_limits: usage_limits}, _settings) when map_size(usage_limits) == 0, do: []

  defp run_profiles_in_use(%State{}, settings) do
    repo_settings =
      for {:ok, repos} <- [Config.repos()], repo <- repos, {:ok, repo_settings} <- [Config.settings_for_repo(repo.name)], do: repo_settings

    for settings <- [settings | repo_settings], kind <- RunKind.names(), uniq: true do
      settings |> Config.run_profile(kind) |> Map.take([:provider, :model]) |> Map.put(:kind, kind)
    end
  end

  defp budget_remaining(limit, used) when is_integer(limit) and limit > 0 do
    max(limit - used, 0)
  end

  defp budget_remaining(_limit, _used), do: nil

  defp workspace_lifecycle_snapshot(%State{} = state) do
    quota = state.workspace_lifecycle_quota || %{configured?: false, paused: false, reason: nil}

    %{
      quota_configured: Map.get(quota, :configured?, false),
      quota_paused: Map.get(quota, :paused, false),
      quota_reason: Map.get(quota, :reason),
      free_bytes: Map.get(quota, :free_bytes),
      min_free_bytes: Map.get(quota, :min_free_bytes),
      checked_at: Map.get(quota, :checked_at),
      hosts: Map.get(quota, :hosts, [])
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !issue_held?(issue, terminal_states) and
      !flow_gated?(issue)
  end

  # A retry or a continuation passes the same review-flow gate as the poll (`review_flow_reason/2`'s
  # reviewer and watcher parts): a Code Review or QA run starts only on a green, conflict-free head,
  # and with auto-merge on the PR and CI watcher lands a `Merging` issue without an agent, the
  # landing agent running only when its decision hands the PR to one
  # (`SymphonyElixir.PrWatch.dispatch_reason/2`). Without it, the continuation of a reviewer run
  # that approved reads the ticket again, now in QA, and starts QA on a red head.
  defp flow_gated?(%Issue{} = issue) do
    if code_review_reviewer_disabled?(issue) or watch_gate_reason(issue) != nil do
      Logger.debug("Skipping dispatch; the review flow holds #{issue_context(issue)} back on its PR")
      true
    else
      false
    end
  end

  # Why the PR and CI watcher's decision holds the issue's run back: a Code Review or QA run starts
  # on a green, conflict-free head (the decision `dispatch`), and a `Merging` landing agent only when
  # the decision hands the PR to one. Nil in every other phase.
  defp watch_gate_reason(%Issue{} = issue) do
    case issue_repo_key(issue) do
      repo_key when is_binary(repo_key) ->
        case Config.settings_for_repo(repo_key) do
          {:ok, settings} -> PrWatch.dispatch_reason(%{issue | repo_key: repo_key}, settings)
          {:error, _reason} -> nil
        end

      nil ->
        PrWatch.dispatch_reason(issue, Config.settings!())
    end
  end

  # A run that went quiet on its PR. The run that opens the PR was dispatched without one, so the
  # ticket's PR in Symphony's record counts too. Quiet never advances a ticket: a move takes the
  # session's explicit handoff signal (`SymphonyElixir.Handoff`).
  defp quiet_post_pr_issue?(%Issue{id: issue_id} = issue, %State{} = state)
       when is_binary(issue_id) do
    completed_metadata = Map.get(state.completed_run_metadata, issue_id)

    is_map(completed_metadata) and
      is_nil(Map.get(completed_metadata, :unpushed_head)) and
      (completed_run_has_pr?(completed_metadata) or ticket_has_pr?(issue, completed_metadata, state)) and
      active_issue_state?(issue.state) and
      !rework_state?(issue.state) and
      !merging_state?(issue.state) and
      !pending_rework_signal?(issue, completed_metadata)
  end

  defp quiet_post_pr_issue?(_issue, _state), do: false

  # The reviewer run starts only on a green, conflict-free head (the PR watcher's `dispatch`). A
  # verdict binds to the head it judged, so a verdict on a red head is not actionable; a head whose
  # checks are still running, or that has none yet, is not green either.
  defp code_review_head_blocked?(%Issue{} = issue) do
    code_review_issue?(issue) and watch_gate_reason(issue) != nil
  end

  # A repo with the reviewer turned off cannot review anything. `ReviewAgent.evaluate/4` answers a
  # disabled reviewer with a fabricated approval, so dispatching the run would record a verdict no
  # reviewer made and move the ticket straight to `Merging`. The ticket is parked instead, with the
  # reason recorded once; turning `review_agent` on opens the gate.
  defp code_review_reviewer_disabled?(%Issue{} = issue) do
    code_review_issue?(issue) and not code_review_reviewer_enabled?(issue)
  end

  # A repo's reviewer setting, read the way every other review-flow decision reads it. A repo whose
  # config cannot be resolved has no reviewer to run, so it parks rather than risk a fabricated
  # approval.
  defp code_review_reviewer_enabled?(%Issue{} = issue) do
    case issue_repo_key(issue) do
      repo_key when is_binary(repo_key) -> review_agent_enabled_for_repo(repo_key, issue)
      _none -> false
    end
  end

  defp code_review_issue?(%Issue{state: state} = issue) when is_binary(state) do
    normalize_issue_state(state) == normalize_issue_state(code_review_state(issue))
  end

  defp code_review_issue?(_issue), do: false

  defp code_review_state(%Issue{} = issue) do
    case issue_repo_key(issue) do
      nil ->
        @code_review_state

      repo_key ->
        case Config.settings_for_repo(repo_key) do
          {:ok, settings} -> settings.tracker.code_review_state
          {:error, _reason} -> @code_review_state
        end
    end
  end

  defp ticket_ci_state(%Issue{id: issue_id} = issue) when is_binary(issue_id) do
    case issue_repo_key(issue) do
      nil ->
        nil

      repo_key ->
        case RunStore.get_ticket_state(repo_key, issue_id) do
          %{} = record -> TicketState.current_ci_state(record)
          _none_or_error -> nil
        end
    end
  end

  defp ticket_ci_state(_issue), do: nil

  # The QA run starts only on a green, conflict-free head, exactly as the reviewer run does.
  defp qa_head_blocked?(%Issue{} = issue) do
    qa_issue?(issue) and watch_gate_reason(issue) != nil
  end

  defp qa_issue?(%Issue{state: state} = issue) when is_binary(state) do
    normalize_issue_state(state) == normalize_issue_state(qa_state(issue))
  end

  defp qa_issue?(_issue), do: false

  defp qa_state(%Issue{} = issue) do
    case issue_repo_key(issue) do
      nil ->
        @qa_state

      repo_key ->
        case Config.settings_for_repo(repo_key) do
          {:ok, settings} -> settings.tracker.qa_state
          {:error, _reason} -> @qa_state
        end
    end
  end

  # Records the no-dispatch event when a gate closed because a Code Review or QA
  # ticket is held back (a head that is not green, or a repo with no reviewer); a no-op for every
  # other blocked ticket.
  defp note_blocked_flow_head(%State{} = state, %Issue{} = issue) do
    cond do
      code_review_reviewer_disabled?(issue) -> note_code_review_reviewer_disabled(state, issue)
      code_review_head_blocked?(issue) -> note_code_review_head(state, issue)
      qa_head_blocked?(issue) -> note_qa_head(state, issue)
      true -> state
    end
  end

  # Parks a Code Review ticket whose head is not green, recording why once per head so the ledger
  # carries the no-dispatch event without repeating it on every poll tick. The ticket stays exactly
  # where it is: the state is returned unchanged.
  defp note_code_review_head(%State{} = state, %Issue{} = issue) do
    case ticket_ci_state(issue) do
      %{head_sha: head, status: status} ->
        unless latest_code_review_head_signal?(issue, head) do
          record_ticket_signal(issue, "code_review_head_not_green", %{head: head, status: status})
        end

        head_status = if status == "", do: "unknown", else: status

        Logger.info("Not dispatching the reviewer for #{issue_context(issue)}: its head is #{head_status}")

      _none ->
        :ok
    end

    state
  end

  defp latest_code_review_head_signal?(issue, head), do: latest_head_signal?(issue, "code_review_head_not_green", head)

  # Parks a QA ticket whose head is not green, recording why once per head, exactly as a Code Review
  # ticket is parked. The ticket stays where it is: the state is returned unchanged, and the run is
  # dispatched once the poll's rollup read calls the head green.
  defp note_qa_head(%State{} = state, %Issue{} = issue) do
    case ticket_ci_state(issue) do
      %{head_sha: head, status: status} ->
        unless latest_head_signal?(issue, @qa_head_not_green_signal, head) do
          record_ticket_signal(issue, @qa_head_not_green_signal, %{head: head, status: status})
        end

        head_status = if status == "", do: "unknown", else: status

        Logger.info("Not dispatching QA for #{issue_context(issue)}: its head is #{head_status}")

      _none ->
        :ok
    end

    state
  end

  # Whether the newest signal on the ticket is `name` for the same head, so a no-dispatch event is
  # recorded once per head rather than on every poll tick.
  defp latest_head_signal?(%Issue{id: issue_id} = issue, name, head) when is_binary(issue_id) do
    with repo_key when is_binary(repo_key) <- issue_repo_key(issue),
         %{} = record <- RunStore.get_ticket_state(repo_key, issue_id) do
      case TicketState.recent_signals(record, 1) do
        [%{name: ^name, details: details}] -> Map.get(details, :head) == head
        _signals -> false
      end
    else
      _none_or_error -> false
    end
  end

  defp latest_head_signal?(_issue, _name, _head), do: false

  # Parks a Code Review ticket whose repo has the reviewer off, recording why once so the ledger
  # carries the no-dispatch event without repeating it on every poll tick. The ticket stays exactly
  # where it is: the state is returned unchanged, and turning `review_agent` on opens the gate.
  defp note_code_review_reviewer_disabled(%State{} = state, %Issue{} = issue) do
    unless code_review_reviewer_disabled_recorded?(issue) do
      record_ticket_signal(issue, @code_review_reviewer_disabled_signal, %{})
    end

    Logger.warning("Not dispatching the reviewer for #{issue_context(issue)}: code_review.enabled is false for its repo")

    state
  end

  # The reason is a repo config, not a head, so one recording per ticket is enough; any signal of
  # this name in the ledger means it was already recorded.
  defp code_review_reviewer_disabled_recorded?(%Issue{id: issue_id} = issue) when is_binary(issue_id) do
    case issue_repo_key(issue) do
      repo_key when is_binary(repo_key) ->
        Enum.any?(Handoff.signals(repo_key, issue_id), &(&1.name == @code_review_reviewer_disabled_signal))

      _none ->
        false
    end
  end

  defp code_review_reviewer_disabled_recorded?(_issue), do: false

  defp ticket_has_pr?(issue, completed_metadata, %State{} = state),
    do: is_binary(ticket_pr_url(issue, repo_key_from(completed_metadata) || state.repo_key))

  defp completed_run_has_pr?(completed_metadata) when is_map(completed_metadata) do
    is_binary(URLUtils.pull_request_url(completed_metadata))
  end

  defp pending_rework_signal?(%Issue{} = issue, completed_metadata) do
    issue_updated_after_last_run?(issue, completed_metadata) or
      pending_reviewer_comments?(issue.id, repo_key_from(completed_metadata)) or
      pending_ci_failure?(issue.id, repo_key_from(completed_metadata))
  end

  defp issue_updated_after_last_run?(%Issue{updated_at: %DateTime{} = updated_at}, %{last_ran_at: %DateTime{} = last_ran_at}) do
    DateTime.compare(updated_at, last_ran_at) == :gt
  end

  defp issue_updated_after_last_run?(_issue, _completed_metadata), do: false

  defp pending_reviewer_comments?(issue_id, repo_key) when is_binary(issue_id) do
    PrReviewPoller.pending_reviewer_comments(issue_id, repo_key_opt(repo_key)) != []
  end

  defp pending_reviewer_comments?(_issue_id, _repo_key), do: false

  defp pending_ci_failure?(issue_id, repo_key) when is_binary(issue_id) do
    not is_nil(PrWatch.pending_ci_failure(issue_id, repo_key_opt(repo_key)))
  end

  defp pending_ci_failure?(_issue_id, _repo_key), do: false

  defp repo_key_opt(repo_key) when is_binary(repo_key) and repo_key != "", do: [repo_key: repo_key]
  defp repo_key_opt(_repo_key), do: []

  defp active_issue_state?(state_name) when is_binary(state_name) do
    MapSet.member?(active_state_set(), normalize_issue_state(state_name))
  end

  defp active_issue_state?(_state_name), do: false

  defp rework_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "rework"
  end

  defp rework_state?(_state_name), do: false

  # A `Merging` issue is approved; keep re-dispatching its landing agent instead of parking it.
  defp merging_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @merging_state
  end

  defp merging_state?(_state_name), do: false

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    forced_slot_available?(issue, state) or normal_slots_available?(issue, state)
  end

  defp normal_slots_available?(%Issue{} = issue, %State{} = state) do
    if finishing_issue?(issue) do
      available_finishing_slots(state) > 0 and state_slots_available?(issue, state.running)
    else
      available_slots(state) > 0 and
        epic_lane_slot_available?(issue, state) and
        state_slots_available?(issue, state.running)
    end
  end

  defp put_running_entry(%State{} = state, issue_id, running_entry)
       when is_binary(issue_id) and is_map(running_entry) do
    %{state | running: Map.put(state.running, issue_id, running_entry)}
  end

  defp put_running_entry(state, _issue_id, _running_entry), do: state

  defp enforce_issue_budget(%State{} = state, issue_id) when is_binary(issue_id) do
    limit = Config.settings!().agent.max_tokens_per_issue
    running_entry = Map.get(state.running, issue_id)
    total_tokens = running_entry_total_tokens(running_entry)

    if is_integer(limit) and limit > 0 and total_tokens >= limit do
      log_issue_budget_exhausted(issue_id, running_entry, limit, total_tokens)

      emit_budget_exceeded(running_entry, %{
        reason: "token budget exhausted: total_tokens=#{total_tokens} limit=#{limit}",
        tokens: run_tokens(running_entry),
        metadata: %{source: "orchestrator", scope: "issue", limit: limit}
      })

      state
      |> terminate_running_issue(issue_id, false,
        status: "budget_exhausted",
        error: "token budget exhausted: total_tokens=#{total_tokens} limit=#{limit}"
      )
      |> mark_budget_exhausted(issue_id)
    else
      state
    end
  end

  defp enforce_issue_budget(state, _issue_id), do: state

  defp running_entry_total_tokens(running_entry) when is_map(running_entry) do
    entry_total_tokens(running_entry)
  end

  defp running_entry_total_tokens(_running_entry), do: 0

  defp log_issue_budget_exhausted(issue_id, running_entry, limit, total_tokens) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)
    input_tokens = entry_uncached_input_tokens(running_entry)
    output_tokens = entry_output_tokens(running_entry)

    Logger.warning(
      "Issue token budget exhausted: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} uncached_input_tokens=#{input_tokens} output_tokens=#{output_tokens} total_tokens=#{total_tokens} limit=#{limit}; stopping active agent without retry"
    )
  end

  defp mark_budget_exhausted(%State{} = state, issue_id) when is_binary(issue_id) do
    %{state | budget_exhausted: MapSet.put(state.budget_exhausted, issue_id)}
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{uncached_input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    state = reset_daily_budget_if_needed(state)
    codex_totals = apply_token_delta(codex_totals, token_delta)
    persist_codex_totals(codex_totals)

    %{
      state
      | codex_totals: codex_totals,
        budget_daily_used: state.budget_daily_used + max(total, 0)
    }
    |> log_daily_budget_pause()
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_rate_limits(%State{} = state, update) when is_map(update) do
    case AgentTelemetry.extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    uncached_input_tokens = codex_totals_uncached_input_tokens(codex_totals) + token_delta.uncached_input_tokens
    cached_input_tokens = Map.get(codex_totals, :cached_input_tokens, 0) + token_delta.cached_input_tokens

    cache_creation_input_tokens =
      Map.get(codex_totals, :cache_creation_input_tokens, 0) + token_delta.cache_creation_input_tokens

    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, uncached_input_tokens + cached_input_tokens + cache_creation_input_tokens),
      uncached_input_tokens: max(0, uncached_input_tokens),
      cached_input_tokens: max(0, cached_input_tokens),
      cache_creation_input_tokens: max(0, cache_creation_input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp codex_totals_uncached_input_tokens(codex_totals) when is_map(codex_totals) do
    case Map.get(codex_totals, :uncached_input_tokens) do
      value when is_integer(value) -> max(value, 0)
      _ -> max(Map.get(codex_totals, :input_tokens, 0) - Map.get(codex_totals, :cached_input_tokens, 0), 0)
    end
  end

  defp codex_totals_uncached_input_tokens(_codex_totals), do: 0

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = AgentTelemetry.extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :uncached_input,
        usage,
        :last_reported_uncached_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :cached_input,
        usage,
        :last_reported_cached_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :cache_creation_input,
        usage,
        :last_reported_cache_creation_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [uncached_input, cached_input, cache_creation_input, output, total] ->
      input_delta = uncached_input.delta + cached_input.delta + cache_creation_input.delta
      input_reported = uncached_input.reported + cached_input.reported + cache_creation_input.reported

      %{
        input_tokens: input_delta,
        uncached_input_tokens: uncached_input.delta,
        cached_input_tokens: cached_input.delta,
        cache_creation_input_tokens: cache_creation_input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input_reported,
        uncached_input_reported: uncached_input.reported,
        cached_input_reported: cached_input.reported,
        cache_creation_input_reported: cache_creation_input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = AgentTelemetry.get_token_usage(usage, token_key)
    prev_reported = reported_token(running_entry, reported_key)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp reported_token(running_entry, :last_reported_uncached_input_tokens),
    do: last_reported_token(running_entry, :uncached_input)

  defp reported_token(running_entry, :last_reported_cached_input_tokens),
    do: last_reported_token(running_entry, :cached_input)

  defp reported_token(running_entry, :last_reported_cache_creation_input_tokens),
    do: last_reported_token(running_entry, :cache_creation_input)

  defp reported_token(running_entry, :last_reported_output_tokens),
    do: last_reported_token(running_entry, :output)

  defp reported_token(running_entry, :last_reported_total_tokens),
    do: last_reported_token(running_entry, :total)

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  # The dashboard shows a run as waiting for Linear until its latest wait ends.
  defp active_linear_wait_until(%{linear_wait_until: %DateTime{} = wait_until}, %DateTime{} = now) do
    if DateTime.after?(wait_until, now), do: wait_until
  end

  defp active_linear_wait_until(_running_entry, _now), do: nil

  defp seconds_since(%DateTime{} = timestamp, %DateTime{} = now) do
    max(0, DateTime.diff(now, timestamp, :second))
  end

  defp seconds_since(_timestamp, _now), do: nil
end
