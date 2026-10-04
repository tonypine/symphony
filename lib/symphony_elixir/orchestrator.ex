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
    AuditLog,
    AutoMerge,
    AutoReview,
    BreakdownReview,
    CiPoller,
    Config,
    EpicLanes,
    Notifications,
    PrReviewPoller,
    PrRun,
    QaRunner,
    Quality,
    QualityGate,
    RunKind,
    RunStore,
    Secret,
    StatusDashboard,
    SubIssueWait,
    Tracker,
    URLUtils,
    UsageLimit,
    Verification,
    Workspace
  }

  alias SymphonyElixir.Linear.{Client, Issue, RateLimit, TransientRetry, Usage}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # A transient Linear error (timeout, refused connection, 5xx) is not the issue's
  # fault: retry soon, without failure backoff. A rate limit waits for its pause.
  @linear_wait_retry_delay_ms 5_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @default_transcript_buffer_size 200
  @default_snapshot_publish_ms 500
  @stop_session_cleanup_timeout_ms 5_000
  @fresh_dispatch_state_grace_ms 120_000
  # A landing session can see its issue turn terminal (for example Linear's
  # "PR merged -> Done" automation) before it posts its final workpad update.
  @merging_state "merging"
  @merging_terminal_grace_ms 300_000
  @snapshot_table :symphony_orchestrator_snapshot
  @snapshot_key :current
  @repo_poll_cold_failure_warm_after 3
  @terminal_agent_setup_error_marker "missing_required_mcp_tools"
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
      watching: %{},
      conflicts: %{},
      repo_poll_cache: %{},
      repo_poll_due_at_ms: %{},
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
      merging_ci_waits: %{},
      epic_lanes: nil,
      blocked: [],
      slot_waiting: %{},
      setup_failed: %{},
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
      usage_limits: %{},
      usage_limit_timers: %{},
      usage_windows: %{},
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
    quality_gate_cache = hydrate_quality_gate_cache()
    quality_gate_comment_keys = hydrate_quality_gate_comment_keys()
    budget_day_started_on = Date.utc_today()
    budget_daily_used = hydrate_budget_daily_used(budget_day_started_on)
    budget_exhausted = hydrate_budget_exhausted()
    :ok = ensure_snapshot_table()

    completed_run_metadata = hydrate_completed_run_metadata(retry_attempts)

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
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
    }

    state = state |> seed_watching_from_completed_run_metadata() |> arm_usage_limit_timers()

    mark_interrupted_runs_for_configured_repos(repo_key)
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
  def handle_info(:publish_snapshot, state) do
    publish_snapshot(state)
    schedule_snapshot_publish(snapshot_publish_interval_ms())
    {:noreply, state}
  end

  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
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

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
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

  def handle_info(:run_poll_cycle, state) do
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

  def handle_info({:watchdog_tick, watchdog_token}, %{watchdog_token: watchdog_token} = state)
      when is_reference(watchdog_token) do
    state =
      state
      |> refresh_runtime_config()
      |> maybe_run_watchdog()
      |> schedule_watchdog_tick(watchdog_tick_interval_ms())

    {:noreply, state}
  end

  def handle_info({:watchdog_tick, _watchdog_token}, state), do: {:noreply, state}

  def handle_info(:watchdog_tick, state) do
    state =
      state
      |> refresh_runtime_config()
      |> maybe_run_watchdog()
      |> schedule_watchdog_tick(watchdog_tick_interval_ms())

    {:noreply, state}
  end

  def handle_info({ref, {:startup_workspace_lifecycle_result, result}}, %{startup_workspace_lifecycle_task_ref: ref} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state =
      state
      |> Map.put(:startup_workspace_lifecycle_task_ref, nil)
      |> apply_startup_workspace_lifecycle_result(result)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({ref, {:repo_poll_result, result}}, %{repo_poll_task_ref: ref} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state =
      state
      |> Map.put(:repo_poll_task_ref, nil)
      |> apply_repo_poll_task_result(result)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({ref, {:quality_gate_result, result}}, %State{quality_gate_tasks: tasks} = state)
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

  def handle_info({ref, {:dispatch_readiness_result, result}}, %State{dispatch_readiness_tasks: tasks} = state)
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

  def handle_info(
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

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
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
          |> Map.put(:last_event_at, last_event_at)

        persist_running_entry(updated_running_entry)
        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:merging_ci_wait, issue_id, wait}, %{running: running} = state)
      when is_binary(issue_id) and is_map(wait) do
    case Map.get(running, issue_id) do
      nil -> {:noreply, state}
      running_entry -> {:noreply, %{state | running: Map.put(running, issue_id, Map.put(running_entry, :merging_ci_wait, wait))}}
    end
  end

  # A run is waiting `delay_ms` on a Linear rate limit or outage; see after_linear_wait/2.
  def handle_info({:linear_wait, issue_id, delay_ms}, %{running: running} = state)
      when is_binary(issue_id) and is_integer(delay_ms) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        wait_until = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
        {:noreply, %{state | running: Map.put(running, issue_id, Map.put(running_entry, :linear_wait_until, wait_until))}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        update = maybe_put_review_agent_verdict_tokens(update, running_entry)
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

        persist_running_entry(updated_running_entry)
        notify_transcript(running_repo_key(state, updated_running_entry), issue_id, update)
        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:usage_limit_resume, key}, %State{} = state) do
    state =
      case Map.fetch(state.usage_limits, key) do
        {:ok, %{phase: :paused} = entry} -> maybe_resume_usage_limit(state, key, entry)
        {:ok, %{phase: :headroom} = entry} -> maybe_clear_usage_headroom(state, key, entry)
        _canary_or_gone -> state
      end

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(msg, state) do
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
        notify_dashboard()
        {:noreply, redispatch_slot_waiting(state)}
    end
  end

  # A slot just freed: run dispatch now rather than at the next poll when an issue is waiting for one.
  defp redispatch_slot_waiting(%State{slot_waiting: waiting} = state) when map_size(waiting) > 0 do
    if poll_tick_coalesced?(state, System.monotonic_time(:millisecond)), do: state, else: schedule_tick(state, 0)
  end

  defp redispatch_slot_waiting(%State{} = state), do: state

  defp poll_tick_coalesced?(%State{} = state, now_ms) do
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    state.poll_check_in_progress == true or already_due?
  end

  defp handle_normal_agent_exit(%State{} = state, issue_id, running_entry, session_id) do
    persist_run_completion(running_entry, "success", nil)

    case pr_run_entry?(running_entry) do
      true ->
        Logger.info("PR agent task completed for issue_id=#{issue_id} session_id=#{session_id}; no Linear continuation scheduled")
        remember_completed_run(state, issue_id, running_entry)

      false ->
        complete_pr_review_comment_cursor(issue_id, running_entry_repo_key(running_entry))
        complete_pending_qa_failure(issue_id, running_entry_repo_key(running_entry))
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

  defp handle_abnormal_agent_exit(%State{} = state, issue_id, running_entry, session_id, {:usage_limited, %{} = info} = reason) do
    if Config.settings!().agent.usage_limit.auto_pause do
      persist_run_completion(running_entry, "usage_limited", "agent exited: #{agent_exit_reason_summary(reason)}")
      pause_for_usage_limit(state, issue_id, running_entry, session_id, info)
    else
      handle_failed_agent_exit(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp handle_abnormal_agent_exit(%State{} = state, issue_id, running_entry, session_id, reason) do
    handle_failed_agent_exit(state, issue_id, running_entry, session_id, reason)
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

      terminal_agent_setup_error?(reason) ->
        Logger.error(
          "Agent task exited for issue_id=#{issue_id} session_id=#{session_id} " <>
            "reason=#{inspect(reason)}; terminal setup error is not retried"
        )

        maybe_comment_terminal_agent_setup_failure(issue_id, running_entry, reason)
        emit_run_failed(running_entry, error, nil)

        state
        |> release_issue_claim(issue_id)
        |> mark_setup_failed(issue_id, running_entry)

      terminal_review_agent_block?(reason) ->
        Logger.error(
          "Agent task exited for issue_id=#{issue_id} session_id=#{session_id} " <>
            "reason=#{inspect(reason)}; reviewer block is not retried"
        )

        blocked_state = review_agent_blocked_state(state, running_entry)
        maybe_comment_review_agent_block(issue_id, running_entry, reason, blocked_state)
        state = maybe_transition_review_agent_blocked_issue(state, issue_id, running_entry, blocked_state)
        emit_run_failed(running_entry, error, nil)
        state

      terminal_tool_failure_circuit_breaker?(reason) ->
        Logger.error(
          "Agent task exited for issue_id=#{issue_id} session_id=#{session_id} " <>
            "reason=#{inspect(reason)}; repeated tool failure circuit breaker is not retried"
        )

        blocked_state = review_agent_blocked_state(state, running_entry)
        maybe_comment_tool_failure_circuit_breaker(issue_id, running_entry, reason, blocked_state)
        state = maybe_transition_review_agent_blocked_issue(state, issue_id, running_entry, blocked_state)
        emit_run_failed(running_entry, error, nil)
        state

      true ->
        Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

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
  end

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

    if pr_run_entry?(running_entry) do
      Logger.warning("PR agent task hit the usage limit for issue_id=#{issue_id} session_id=#{session_id}; PR runs are not retried")
      state
    else
      Logger.info("Agent task hit the usage limit for issue_id=#{issue_id} session_id=#{session_id}; holding the retry until #{DateTime.to_iso8601(entry.resume_at)}")

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

  defp agent_exit_reason_summary({%RuntimeError{message: message}, _stacktrace}) when is_binary(message) do
    strip_ansi(message)
  end

  defp agent_exit_reason_summary({:review_agent_blocked, payload}) do
    "review_agent blocked: #{review_agent_block_reason(payload)}"
  end

  defp agent_exit_reason_summary({:linear_unavailable, reason}) do
    "waiting for Linear: #{inspect(reason)}"
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

  defp terminal_agent_setup_error?({:terminal_agent_setup_error, _reason}), do: true

  defp terminal_agent_setup_error?(reason) do
    reason
    |> inspect()
    |> String.contains?(@terminal_agent_setup_error_marker)
  end

  defp terminal_review_agent_block?({:review_agent_blocked, _reason}), do: true
  defp terminal_review_agent_block?(_reason), do: false

  defp terminal_tool_failure_circuit_breaker?({:tool_failure_circuit_breaker, _payload}), do: true
  defp terminal_tool_failure_circuit_breaker?(_reason), do: false

  defp maybe_comment_review_agent_block(issue_id, running_entry, reason, blocked_state)
       when is_binary(issue_id) and is_map(running_entry) and is_binary(blocked_state) do
    body = review_agent_block_comment(reason, blocked_state)

    case Tracker.create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, comment_reason} ->
        Logger.warning(
          "Failed to post review-agent block comment for issue_id=#{issue_id}: " <>
            "#{inspect(comment_reason)}"
        )
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to post review-agent block comment for issue_id=#{issue_id}: " <>
          "#{Exception.message(exception)}"
      )
  end

  defp maybe_comment_review_agent_block(_issue_id, _running_entry, _reason, _blocked_state), do: :ok

  defp maybe_comment_tool_failure_circuit_breaker(issue_id, running_entry, reason, blocked_state)
       when is_binary(issue_id) and is_map(running_entry) and is_binary(blocked_state) do
    body = tool_failure_circuit_breaker_comment(reason, blocked_state)

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

  defp maybe_comment_tool_failure_circuit_breaker(_issue_id, _running_entry, _reason, _blocked_state), do: :ok

  defp maybe_transition_review_agent_blocked_issue(%State{} = state, issue_id, running_entry, blocked_state)
       when is_binary(issue_id) and is_map(running_entry) and is_binary(blocked_state) do
    case Tracker.update_issue_state(issue_id, blocked_state) do
      :ok ->
        issue =
          running_entry
          |> Map.get(:issue)
          |> case do
            %Issue{} = issue -> %Issue{issue | state: blocked_state, updated_at: DateTime.utc_now()}
            _ -> nil
          end

        state =
          if issue do
            put_watching_issue(state, issue)
          else
            state
          end

        release_issue_claim(state, issue_id)

      {:error, transition_reason} ->
        Logger.warning(
          "Failed to move review-agent blocked issue to #{blocked_state}: " <>
            "issue_id=#{issue_id} reason=#{inspect(transition_reason)}"
        )

        release_issue_claim(state, issue_id)
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to move review-agent blocked issue to #{blocked_state}: " <>
          "issue_id=#{issue_id} reason=#{Exception.message(exception)}"
      )

      release_issue_claim(state, issue_id)
  end

  defp maybe_transition_review_agent_blocked_issue(%State{} = state, _issue_id, _running_entry, _blocked_state), do: state

  defp review_agent_block_comment(reason, blocked_state) do
    """
    Symphony stopped this run without retrying because the reviewer agent returned a verified blocking verdict.

    Reason: #{review_agent_block_reason(reason)}

    #{review_agent_block_findings_section(reason)}

    Target human-review state: #{blocked_state}.
    """
  end

  defp tool_failure_circuit_breaker_comment(reason, blocked_state) do
    """
    Symphony stopped this run without retrying because the agent repeated the same failing tool execution until the circuit breaker tripped.

    #{tool_failure_circuit_breaker_details(reason)}

    Target human-review state: #{blocked_state}.
    """
  end

  defp review_agent_blocked_state(%State{} = state, running_entry) do
    state
    |> running_repo_key(running_entry)
    |> Config.review_agent_blocked_state()
  end

  defp review_agent_block_reason({:review_agent_blocked, payload}), do: review_agent_block_reason(payload)
  defp review_agent_block_reason(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp review_agent_block_reason(reason) when is_binary(reason) and reason != "", do: reason
  defp review_agent_block_reason(_reason), do: "review_agent blocked the run"

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

  defp review_agent_block_findings_section({:review_agent_blocked, payload}), do: review_agent_block_findings_section(payload)

  defp review_agent_block_findings_section(%{findings: findings}) when is_list(findings) and findings != [] do
    body =
      findings
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {finding, index} -> "#{index}. #{review_agent_block_finding_text(finding)}" end)

    "Verified findings:\n#{body}"
  end

  defp review_agent_block_findings_section(_reason), do: "Verified findings: none provided"

  defp review_agent_block_finding_text(finding) when is_map(finding) do
    finding
    |> review_agent_block_finding_summary()
    |> review_agent_block_finding_with_location(review_agent_block_finding_location(finding))
    |> review_agent_block_finding_with_fix(review_agent_block_finding_suggested_fix(finding))
  end

  defp review_agent_block_finding_text(finding), do: inspect(finding)

  defp review_agent_block_finding_summary(finding) do
    review_agent_block_finding_field(finding, :summary, "summary") || "Finding"
  end

  defp review_agent_block_finding_location(finding) do
    file = review_agent_block_finding_field(finding, :file, "file") || "unknown file"

    case review_agent_block_finding_line_range(finding) do
      nil -> file
      {start_line, end_line} -> "#{file}:#{start_line}-#{end_line}"
    end
  end

  defp review_agent_block_finding_suggested_fix(finding) do
    review_agent_block_finding_field(finding, :suggested_fix, "suggested_fix")
  end

  defp review_agent_block_finding_with_location(summary, location), do: "#{summary} (#{location})"

  defp review_agent_block_finding_with_fix(text, fix) when is_binary(fix) and fix != "" do
    "#{text} Suggested fix: #{fix}"
  end

  defp review_agent_block_finding_with_fix(text, _fix), do: text

  defp review_agent_block_finding_field(finding, atom_key, string_key) do
    Map.get(finding, atom_key) || Map.get(finding, string_key)
  end

  defp review_agent_block_finding_line_range(finding) do
    case Map.get(finding, :line_range) || Map.get(finding, "line_range") do
      {start_line, end_line} when is_integer(start_line) and is_integer(end_line) -> {start_line, end_line}
      [start_line, end_line] when is_integer(start_line) and is_integer(end_line) -> {start_line, end_line}
      _ -> nil
    end
  end

  defp maybe_comment_terminal_agent_setup_failure(issue_id, running_entry, reason)
       when is_binary(issue_id) and is_map(running_entry) do
    body = terminal_agent_setup_failure_comment(reason)

    case Tracker.create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, comment_reason} ->
        Logger.warning(
          "Failed to post terminal setup failure comment for issue_id=#{issue_id}: " <>
            "#{inspect(comment_reason)}"
        )
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to post terminal setup failure comment for issue_id=#{issue_id}: " <>
          "#{Exception.message(exception)}"
      )
  end

  defp maybe_comment_terminal_agent_setup_failure(_issue_id, _running_entry, _reason), do: :ok

  defp terminal_agent_setup_failure_comment(reason) do
    """
    Symphony stopped this run before retrying because the agent runtime did not expose
    the required Symphony GitHub MCP tools.

    Reason: #{terminal_agent_setup_error_summary(reason)}

    Fix the agent MCP/tool configuration, then re-dispatch the issue.
    """
  end

  defp terminal_agent_setup_error_summary({:terminal_agent_setup_error, reason}) do
    terminal_agent_setup_error_summary(reason)
  end

  defp terminal_agent_setup_error_summary({:turn_failed, reason}) when is_binary(reason), do: reason

  defp terminal_agent_setup_error_summary(reason) when is_binary(reason), do: reason

  defp terminal_agent_setup_error_summary(reason), do: inspect(reason)

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
    state = sync_repo_poll_state(state, repos, now_ms)

    due_repo = next_due_repo(state, repos, now_ms)
    running_ids = Map.keys(state.running)
    watching_ids = watching_issue_ids(state)

    case start_async_task(fn ->
           {:repo_poll_result,
            %{
              repos: repos,
              now_ms: now_ms,
              running_ids: running_ids,
              running_result: fetch_issue_states_if_needed(running_ids),
              watching_ids: watching_ids,
              watching_result: fetch_issue_states_if_needed(watching_ids),
              repo_result: fetch_due_repo_if_needed(due_repo)
            }}
         end) do
      {:ok, task} ->
        {:ok, task, state}

      {:error, reason} ->
        Logger.warning("Failed to start async repo poll task: #{inspect(reason)}")
        {:skip, state}
    end
  end

  defp fetch_issue_states_if_needed([]), do: {:ok, []}
  defp fetch_issue_states_if_needed(issue_ids), do: Tracker.fetch_issue_states_by_ids(issue_ids)

  defp fetch_due_repo_if_needed(nil), do: :not_due

  defp fetch_due_repo_if_needed(repo) do
    repo_name = repo_name(repo)
    {repo_name, Tracker.fetch_candidate_issues_for_repo(repo)}
  end

  defp apply_repo_poll_task_result(%State{} = state, %{
         repos: repos,
         now_ms: now_ms,
         running_ids: running_ids,
         running_result: running_result,
         watching_ids: watching_ids,
         watching_result: watching_result,
         repo_result: repo_result
       }) do
    state =
      state
      |> apply_running_issue_states_result(running_ids, running_result)
      |> apply_watching_issue_states_result(watching_ids, watching_result)

    case apply_repo_poll_result(state, repos, repo_result, now_ms) do
      {:ok, %{dispatchable: issues}, state} ->
        state =
          state
          |> prune_quality_gate_cache_to_active(issues)
          |> clear_running_quality_gate_cache_entries()
          |> put_epic_lanes(issues)
          |> put_blocked(issues)
          |> release_merging_ci_waits(issues)

        if available_slots(state) > 0 or available_finishing_slots(state) > 0 do
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

  # A claim is only held by a running agent, a queued retry, or a retry whose async quality
  # gate or dispatch readiness check is in flight. Any other claim is orphaned: the poll skips
  # claimed issues, so release it rather than leave the issue undispatchable until a restart.
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
    |> MapSet.new()
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

    case next_due_repo(state, repos, now_ms) do
      nil ->
        buckets = candidate_buckets_from_cache(state, repos)
        {:ok, buckets, put_conflict_bucket(state, buckets.conflicts)}

      repo ->
        poll_due_repo(state, repos, repo, fetcher, now_ms)
    end
  end

  defp poll_due_repo(state, repos, repo, fetcher, now_ms) do
    repo_name = repo_name(repo)
    apply_due_repo_fetch_result(state, repos, repo_name, fetcher.(repo), now_ms)
  end

  defp apply_repo_poll_result(state, repos, :not_due, _now_ms) do
    buckets = candidate_buckets_from_cache(state, repos)
    {:ok, buckets, put_conflict_bucket(state, buckets.conflicts)}
  end

  defp apply_repo_poll_result(state, repos, {repo_name, result}, now_ms) when is_binary(repo_name) do
    apply_due_repo_fetch_result(state, repos, repo_name, result, now_ms)
  end

  defp apply_repo_poll_result(state, _repos, result, _now_ms), do: {:error, {:invalid_repo_poll_result, result}, state}

  defp apply_due_repo_fetch_result(state, repos, repo_name, result, now_ms) do
    case result do
      {:ok, issues} when is_list(issues) ->
        state =
          state
          |> put_repo_poll_cache(repo_name, issues, now_ms)
          |> put_repo_next_due(repo_name, now_ms + linear_poll_interval_ms(state))
          |> record_tracker_poll_success()

        buckets = candidate_buckets_from_cache(state, repos)
        {:ok, buckets, put_conflict_bucket(state, buckets.conflicts)}

      {:error, reason} ->
        state =
          state
          |> put_repo_next_due(repo_name, now_ms + repo_poll_retry_delay_ms(state, repos))
          |> record_tracker_poll_failure(reason)

        cond do
          repo_poll_cache_warmed?(state, repo_name) ->
            Logger.warning("Linear repo poll failed for #{repo_name}; using cached candidate issues: #{inspect(reason)}")
            buckets = candidate_buckets_from_cache(state, repos)
            {:ok, buckets, put_conflict_bucket(state, buckets.conflicts)}

          repo_poll_failure_count(state, repo_name) + 1 >= @repo_poll_cold_failure_warm_after ->
            failure_count = repo_poll_failure_count(state, repo_name) + 1

            Logger.warning("Linear repo poll failed for #{repo_name} #{failure_count} consecutive times; treating cold cache as empty: #{inspect(reason)}")

            state = put_repo_poll_cache(state, repo_name, [], now_ms)
            buckets = candidate_buckets_from_cache(state, repos)
            {:ok, buckets, put_conflict_bucket(state, buckets.conflicts)}

          true ->
            state = put_repo_cold_poll_failure(state, repo_name)
            {:error, reason, state}
        end
    end
  end

  defp candidate_buckets_from_cache(%State{} = state, repos) when is_list(repos) do
    repo_results =
      Enum.map(repos, fn repo ->
        repo_name = repo_name(repo)
        cache_entry = Map.get(state.repo_poll_cache, repo_name, %{issues: []})
        {repo_name, Map.get(cache_entry, :issues, [])}
      end)

    buckets = Client.aggregate_repo_results(repo_results)

    if repo_poll_cache_warmed?(state, repos) do
      buckets
    else
      %{buckets | dispatchable: []}
    end
  end

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
        conflicts: state.conflicts || %{}
    }
  end

  defp next_due_repo(%State{} = state, repos, now_ms) do
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

  defp put_repo_poll_cache(%State{} = state, repo_name, issues, now_ms) do
    cache_entry = %{issues: issues, fetched_at_ms: now_ms}
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
  @spec dispatch_chosen_issues_for_test([Issue.t() | term()], State.t()) :: State.t()
  def dispatch_chosen_issues_for_test(issues, %State{} = state) when is_list(issues), do: dispatch_chosen_issues(issues, state)

  @doc false
  @spec start_usage_limit_canary_for_test(State.t(), UsageLimit.key(), ([String.t()] -> term())) :: State.t()
  def start_usage_limit_canary_for_test(%State{} = state, key, issue_fetcher) when is_function(issue_fetcher, 1) do
    start_usage_limit_canary(state, key, Map.fetch!(state.usage_limits, key), issue_fetcher)
  end

  @doc false
  @spec release_merging_ci_waits_for_test(State.t(), [Issue.t()]) :: State.t()
  def release_merging_ci_waits_for_test(%State{} = state, issues) when is_list(issues), do: release_merging_ci_waits(state, issues)

  @doc false
  @spec put_epic_lanes_for_test(State.t(), [Issue.t()]) :: State.t()
  def put_epic_lanes_for_test(%State{} = state, issues) when is_list(issues), do: put_epic_lanes(state, issues)

  @doc false
  @spec put_blocked_for_test(State.t(), [Issue.t()]) :: State.t()
  def put_blocked_for_test(%State{} = state, issues) when is_list(issues), do: put_blocked(state, issues)

  @doc false
  @spec review_breakdown_parents_for_test([Issue.t()], term(), keyword()) :: term()
  def review_breakdown_parents_for_test(issues, %State{} = state, opts \\ []) when is_list(issues),
    do: review_breakdown_parents(issues, state, opts)

  @doc false
  @spec park_breakdown_parents_for_test([Issue.t()], term()) :: term()
  def park_breakdown_parents_for_test(issues, %State{} = state) when is_list(issues), do: park_breakdown_parents(issues, state)

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
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
    handle_retry_issue_sync_for_test(state, issue_id, attempt, metadata, issue_fetcher)
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
        |> terminate_running_issue(issue.id, true)
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
            %{id: issue_id, identifier: identifier, repo_key: running_repo_key(state, running_entry)},
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

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
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
    else
      state
    end
  end

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

  defp first_turn_started_at(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :started_at)
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

        if is_integer(elapsed_ms) and elapsed_ms >= threshold_ms do
          restart_stuck_issue(state, issue_id, running_entry, elapsed_ms)
        else
          state
        end
    end
  end

  defp watchdog_elapsed_ms(running_entry, now) do
    running_entry
    |> watchdog_last_event_at()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
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

  defp restart_stuck_issue(state, issue_id, running_entry, elapsed_ms) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)
    last_event_at = watchdog_last_event_at(running_entry)
    last_event_at_for_log = if is_struct(last_event_at, DateTime), do: DateTime.to_iso8601(last_event_at), else: "n/a"
    error = "stuck for #{elapsed_ms}ms without transcript activity"
    next_attempt = next_retry_attempt_from_running(running_entry)

    Logger.warning(
      "Agent run stuck: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} last_event_at=#{last_event_at_for_log} elapsed_ms=#{elapsed_ms}; restarting with backoff"
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

    schedule_issue_retry(
      state,
      issue.id,
      attempt,
      Map.merge(metadata, %{
        identifier: issue.identifier,
        title: issue.title,
        error: "quality gate task already in flight; deferred"
      })
    )
  end

  defp start_quality_gate_task(issues, %State{} = state, context, gate_config) do
    cache = state.quality_gate_cache
    comment_keys = state.quality_gate_comment_keys

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

  defp clear_quality_gate_blocking_cache_entry(state, _issue_id), do: state

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
      score: Map.get(entry, :score),
      reason: Map.get(entry, :reason),
      rounds_asked: Map.get(entry, :rounds_asked, 0),
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
      score: Map.get(entry, :score),
      reason: Map.get(entry, :reason),
      error: Map.get(entry, :error),
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

  defp run_dispatch_readiness_checks(%{
         repo_keys: repo_keys,
         active_workspace_identifiers_by_repo: active_identifiers_by_repo,
         run_age_gc?: run_age_gc?,
         now_ms: now_ms
       }) do
    %{
      now_ms: now_ms,
      age_gc_result:
        if(run_age_gc?,
          do: {:ran, workspace_age_gc_result(repo_keys, active_identifiers_by_repo)},
          else: :skipped
        ),
      quota: workspace_quota_status_from_config()
    }
  end

  defp handle_dispatch_readiness_result(%State{} = state, %{kind: context, issues: issues}, result) do
    state =
      state
      |> apply_dispatch_readiness_result(result)
      |> continue_after_dispatch_readiness(context, issues)

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

  defp apply_dispatch_readiness_result(%State{} = state, %{now_ms: now_ms, age_gc_result: age_gc_result, quota: quota}) do
    state
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

    state =
      cond do
        operator_paused?(state) ->
          log_operator_pause(state)

        workspace_quota_paused?(state) ->
          log_workspace_quota_pause(state)

        daily_budget_paused?(state) ->
          log_daily_budget_pause(state)

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
  # can still show `In Progress` for a parent whose breakdown run just moved it to `In Review`, so
  # each one is read again first: moving it on from `In Review` would read as approving its plan.
  defp park_breakdown_parents(issues, %State{} = state) do
    settings = Config.settings!()
    terminal_states = terminal_state_set()
    parkable = Enum.filter(issues, &SubIssueWait.park?(&1, terminal_states, settings))
    already_parked = MapSet.intersection(state.parked_parents, MapSet.new(parkable, & &1.id))

    parked =
      parkable
      |> Enum.reject(&(MapSet.member?(already_parked, &1.id) or issue_claimed_or_running?(state, &1.id)))
      |> still_parkable()
      |> Enum.filter(&park_breakdown_parent(&1, SubIssueWait.state(settings)))
      |> MapSet.new(& &1.id)

    %{state | parked_parents: MapSet.union(already_parked, parked)}
  end

  defp still_parkable([]), do: []

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

  # A human's review of a `breakdown` parent's plan: approving it (In Review to the waiting state)
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

    kept = Map.take(state.breakdown_reviews, Enum.map(pending, &elem(&1, 2)))

    reviews =
      Enum.reduce(pending, kept, fn {issue, action, issue_id}, reviews ->
        backlog = BreakdownReview.backlog_sub_issue_ids(issue)

        cond do
          issue_claimed_or_running?(state, issue_id) or Map.get(reviews, issue_id) == backlog -> reviews
          review_breakdown_parent(issue, action, settings, opts) -> Map.put(reviews, issue_id, backlog)
          true -> Map.delete(reviews, issue_id)
        end
      end)

    %{state | breakdown_reviews: reviews}
  end

  defp review_breakdown_parent(%Issue{id: issue_id} = issue, action, settings, opts) do
    case Tracker.fetch_breakdown_history(issue_id) do
      {:ok, history} ->
        review_breakdown_history(issue, action, history, settings, Keyword.get(opts, :run_store, RunStore))

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
    case BreakdownReview.move(action, sub_issue_id, Tracker.adapter()) do
      :ok ->
        {:ok, identifier}

      {:error, reason} ->
        Logger.warning("Failed to move sub-issue #{identifier} of breakdown parent to #{BreakdownReview.target(action)}: #{issue_context(issue)} reason=#{inspect(reason)}")
        :error
    end
  end

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

  # A rejected plan is made again only once its Backlog sub-issues are cancelled, so the re-plan
  # does not duplicate them.
  defp replan_pending?(%Issue{id: issue_id} = issue, %State{breakdown_reviews: reviews}) do
    BreakdownReview.action(issue, Config.settings!()) == :replace and not Map.has_key?(reviews, issue_id)
  end

  # A landing run that ended on pending checks stays held in `Merging` until the CI poller sees
  # that head go green, the issue leaves `Merging` (a red head takes the CI-failure path), or
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
      _observed -> false
    end
  end

  defp issue_claimed_or_running?(%State{} = state, issue_id) do
    MapSet.member?(state.claimed, issue_id) or Map.has_key?(state.running, issue_id)
  end

  # The move is recorded before it is made, so a review reading the parent's history never sees
  # it without the record that marks it as Symphony's.
  defp park_breakdown_parent(%Issue{id: issue_id} = issue, waiting_state) do
    issue_id |> RunStore.put_own_state_move(DateTime.utc_now()) |> log_run_store_error("record breakdown parent move")

    case Tracker.update_issue_state(issue_id, waiting_state) do
      :ok ->
        Logger.info("Moved breakdown parent to #{waiting_state} while its sub-issues are open: #{issue_context(issue)}")
        true

      {:error, reason} ->
        Logger.warning("Failed to move breakdown parent to #{waiting_state}: #{issue_context(issue)} reason=#{inspect(reason)}")
        false
    end
  end

  # Candidates go out closest-to-done first, each epic lane's tickets nearest the epic first. Once
  # a Merging or Auto Review issue is left waiting for a slot, no Todo issue starts in this pass.
  # `slot_waiting` is rebuilt from the pass, keeping the attempt of any retry that was waiting for a slot.
  defp dispatch_chosen_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    previous_waiting = state.slot_waiting || %{}
    finish_waiting? = qa_pass_queued?()
    auto_review_state = Config.settings!() |> AutoReview.state() |> normalize_issue_state()

    {state, _finish_waiting?} =
      issues
      |> sort_issues_for_dispatch()
      |> then(&EpicLanes.order(state.epic_lanes, &1, fn issue -> stage_rank(issue.state, auto_review_state) end))
      |> Enum.reduce({%{state | slot_waiting: %{}}, finish_waiting?}, fn issue, acc ->
        maybe_dispatch_chosen_issue(issue, acc, previous_waiting, active_states, terminal_states)
      end)

    recover_usage_limit_canaries(state)
  end

  defp maybe_dispatch_chosen_issue(%Issue{} = issue, {state, finish_waiting?}, previous_waiting, active_states, terminal_states) do
    waiting = Map.get(previous_waiting, issue.id, %{})

    cond do
      not dispatch_eligible?(issue, state, active_states, terminal_states) ->
        {state, finish_waiting?}

      finish_waiting? and fresh_issue?(issue) ->
        {put_slot_waiting(state, issue, waiting, "a Merging or Auto Review issue is waiting for a slot"), finish_waiting?}

      issue_dispatch_slots_available?(issue, state) ->
        {dispatch_waiting_issue(state, issue, waiting), finish_waiting?}

      true ->
        state = put_slot_waiting(state, issue, waiting, slot_wait_reason(issue))
        {state, finish_waiting? or finishing_stage?(issue)}
    end
  end

  defp maybe_dispatch_chosen_issue(_issue, acc, _previous_waiting, _active_states, _terminal_states), do: acc

  defp dispatch_waiting_issue(%State{} = state, %Issue{} = issue, waiting) do
    state
    |> clear_setup_failed(issue.id)
    |> dispatch_issue(freeze_issue_repo_key(issue, Map.get(waiting, :repo_key)), Map.get(waiting, :attempt), Map.get(waiting, :worker_host))
  end

  defp put_slot_waiting(%State{} = state, %Issue{} = issue, waiting, reason) do
    entry =
      Map.merge(waiting, %{
        identifier: issue.identifier,
        title: issue.title,
        state: issue.state,
        reason: reason,
        since: Map.get(waiting, :since) || DateTime.utc_now()
      })

    %{state | slot_waiting: Map.put(state.slot_waiting, issue.id, entry)}
  end

  defp slot_wait_reason(%Issue{} = issue) do
    if finishing_issue?(issue), do: "finishing slots full", else: "work slots full"
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    auto_review_state = Config.settings!() |> AutoReview.state() |> normalize_issue_state()

    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {stage_rank(issue.state, auto_review_state), priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {stage_rank(nil, auto_review_state), priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  # Closest to done first: Merging, Auto Review, Rework, other active states (resumes), then Todo.
  defp stage_rank(state_name, auto_review_state) when is_binary(state_name) do
    case normalize_issue_state(state_name) do
      @merging_state -> 0
      ^auto_review_state -> 1
      "rework" -> 2
      "todo" -> 4
      _resume -> 3
    end
  end

  defp stage_rank(_state_name, _auto_review_state), do: 4

  defp fresh_issue?(%Issue{state: state_name}), do: stage_rank(state_name, nil) == 4

  # Merging and Auto Review: the issues "never start fresh work while a finish waits" protects.
  defp finishing_stage?(%Issue{state: state_name}) do
    stage_rank(state_name, Config.settings!() |> AutoReview.state() |> normalize_issue_state()) <= 1
  end

  defp qa_pass_queued? do
    QaRunner.queued() != []
  catch
    :exit, _reason -> false
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
    candidate_issue?(issue, active_states, terminal_states) and
      !issue_held?(issue, terminal_states) and
      !replan_pending?(issue, state) and
      !post_pr_quiet_active_issue?(issue, state) and
      !landing_held?(issue, state) and
      !issue_taken?(issue, state) and
      !setup_failed_suppressed?(state.setup_failed, issue) and
      !usage_limit_held?(issue, state)
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

  # Candidates held in `Todo` by open blockers, recomputed on every poll tick for the snapshot.
  defp put_blocked(%State{} = state, issues) do
    terminal_states = Config.settings!().tracker.terminal_states

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

    %{state | blocked: Enum.sort_by(blocked, & &1.identifier)}
  end

  defp blocker_snapshot(%{} = blocker), do: %{identifier: Map.get(blocker, :identifier), state: Map.get(blocker, :state)}
  defp blocker_snapshot(_blocker), do: %{identifier: nil, state: nil}

  defp epic_lane_slot_available?(%Issue{id: issue_id}, %State{} = state) do
    EpicLanes.slot_for(state.epic_lanes, issue_id, work_running_ids(state.running)) != :none
  end

  # Landing runs finish approved work, so they use their own `finishing_max` allowance instead of
  # `max_total` and the epic lanes.
  defp finishing_issue?(%Issue{} = issue) do
    RunKind.classify(issue, terminal_states: Config.settings!().tracker.terminal_states) == :landing
  end

  defp finishing_entry?(%{run_profile: %{kind: :landing}}), do: true
  defp finishing_entry?(_running_entry), do: false

  defp work_running_ids(running) when is_map(running) do
    for {issue_id, entry} <- running, not finishing_entry?(entry), do: issue_id
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

  defp active_retry_issue?(%Issue{state: state_name} = issue, terminal_states) do
    active_issue_state?(state_name, active_state_set()) and
      !terminal_issue_state?(state_name, terminal_states) and
      !issue_held?(issue, terminal_states)
  end

  defp active_retry_issue?(_issue, _terminal_states), do: false

  # A `Todo` issue waits until every blocker is terminal (see `Issue.blocked?/2`).
  # A `breakdown` parent waits while its sub-issues are worked, in the waiting state or, when that
  # is off, in its active state; it is dispatched again for close-out once every sub-issue is terminal.
  # In `Rework` its plan was rejected, so it is broken down again whatever its sub-issues' states.
  defp issue_held?(issue, terminal_states) do
    Issue.blocked?(issue, terminal_states) or
      (not Issue.replanning?(issue) and
         (Issue.waiting_on_sub_issues?(issue, terminal_states) or
            SubIssueWait.held?(issue, terminal_states, Config.settings!())))
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

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    repo_key = dispatch_repo_key(state, issue)
    sticky_route? = retry_attempt?(attempt)
    terminal_states = terminal_state_set()
    issue_fetcher = &Tracker.fetch_issue_states_by_ids/1

    case revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states, sticky_route?: sticky_route?) do
      {:ok, %Issue{} = refreshed_issue} ->
        refreshed_issue = freeze_issue_repo_key(refreshed_issue, repo_key)
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, repo_key)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        release_undispatched_claim(state, issue.id)

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info(
          "Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)} sub_issues=#{length(refreshed_issue.sub_issues)}"
        )

        release_undispatched_claim(state, issue.id)

      {:error, reason} ->
        skip_dispatch_after_refresh_failure(state, issue, attempt, preferred_worker_host, repo_key, reason)
    end
  end

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
             pull_request_url: issue.pull_request_url,
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
          pull_request_url: issue.pull_request_url
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
    reviewer_run_profile = if review_agent_enabled?(settings), do: Config.pre_push_review_profile(settings)

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

        slot = dispatch_slot_label(state, issue)

        Logger.info(
          "Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"} slot=#{slot} #{run_profile_log_fields(run_profile)}"
        )

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
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
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

  defp run_profile_log_fields(%{kind: kind, model: model, effort: effort}) do
    "run_kind=#{kind} model=#{model || "default"} effort=#{effort || "default"}"
  end

  defp state_reconcile_grace_until_ms do
    System.monotonic_time(:millisecond) + @fresh_dispatch_state_grace_ms
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id} = issue, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states, [])
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states, opts)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) and is_list(opts) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if dispatch_revalidated_issue?(refreshed_issue, terminal_states, Keyword.get(opts, :sticky_route?, false)) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states, _opts), do: {:ok, issue}

  defp dispatch_revalidated_issue?(%Issue{} = issue, terminal_states, true),
    do: active_retry_issue?(issue, terminal_states) and !auto_merge_landing?(issue)

  defp dispatch_revalidated_issue?(%Issue{} = issue, terminal_states, _sticky_route?), do: retry_candidate_issue?(issue, terminal_states)

  defp complete_issue(%State{} = state, issue_id, running_entry) do
    state = delete_persisted_retry(state, issue_id, running_repo_key(state, running_entry))
    state = remember_completed_run(state, issue_id, running_entry)
    state = clear_setup_failed(state, issue_id)

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

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    handle_retry_issue(state, issue_id, attempt, metadata, &Tracker.fetch_issue_states_by_ids/1)
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata, issue_fetcher)
       when is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        retry_issue_refresh_failed(state, issue_id, attempt, metadata, reason)
    end
  end

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

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        state = maybe_emit_issue_completed(state, issue)

        issue
        |> issue_workspace_context(retry_repo_key(state, metadata, %{}))
        |> cleanup_issue_workspace(metadata[:worker_host])

        {:noreply, state |> forget_completed_issue(issue_id) |> release_issue_claim(issue_id)}

      post_pr_quiet_active_issue?(issue, state) ->
        handle_post_pr_quiet_active_issue(state, issue, issue_id, attempt, metadata)

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

  defp handle_post_pr_quiet_active_issue(%State{} = state, %Issue{} = issue, issue_id, attempt, metadata) do
    post_pr_state = AutoReview.post_pr_state(Config.settings!())
    Logger.info("Issue has an opened PR and no rework signal; moving to #{post_pr_state}: #{issue_context(issue)}")

    case Usage.with_caller(:post_pr_transition, fn -> Tracker.update_issue_state(issue_id, post_pr_state) end) do
      :ok ->
        reviewed_issue = %Issue{issue | state: post_pr_state, updated_at: DateTime.utc_now()}

        state =
          state
          |> put_watching_issue(reviewed_issue)
          |> release_issue_claim(issue_id)

        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Failed to move post-PR issue to #{post_pr_state}: #{issue_context(issue)} reason=#{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt,
           metadata
           |> Map.merge(%{
             identifier: issue.identifier,
             title: issue.title,
             error: post_pr_move_error(post_pr_state, reason)
           })
           |> linear_wait_metadata(reason)
         )}
    end
  end

  defp dispatch_refresh_error(reason) do
    if TransientRetry.transient?(reason) do
      "waiting for Linear before dispatch: #{inspect(reason)}"
    else
      "retry issue refresh failed: #{inspect(reason)}"
    end
  end

  defp post_pr_move_error(post_pr_state, reason) do
    if TransientRetry.transient?(reason) do
      "waiting for Linear to move post-PR issue to #{post_pr_state}: #{inspect(reason)}"
    else
      "failed to move post-PR issue to #{post_pr_state}: #{inspect(reason)}"
    end
  end

  defp cleanup_issue_workspace(%{identifier: identifier} = issue, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(issue, worker_host)
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
        teams = AutoReview.configured_teams(settings, repos)
        AutoReview.check_tracker_state(settings, teams)
        SubIssueWait.check_tracker_state(settings, teams)

      {:error, reason} ->
        Logger.warning("Skipping the Auto Review and waiting-on-sub-issues state checks; failed to load repositories: #{inspect(reason)}")
    end
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
        |> issue_workspace_context(repo_key)
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
    with runs when is_list(runs) <- RunStore.list_runs(repo_key, :all),
         retries when is_list(retries) <- RunStore.list_retries(repo_key) do
      identifiers =
        tracked_issue_identifiers ++ run_identifiers(runs) ++ retry_identifiers(retries)

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

  # Workspaces other running or retrying issues in the same repo own. The
  # dispatched agent must not detach their worktrees to take over a shared PR
  # branch (see `Workspace.create_for_issue/4`).
  defp sibling_active_workspace_identifiers(%State{} = state, issue_id, repo_key) do
    running =
      state.running
      |> Enum.reject(fn {running_id, _entry} -> running_id == issue_id end)
      |> Enum.filter(fn {_id, entry} -> (Map.get(entry, :repo_key) || state.repo_key) == repo_key end)
      |> Enum.flat_map(fn {_id, entry} -> running_workspace_identifiers(entry) end)

    retrying =
      state.retry_attempts
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

  defp run_identifiers(runs) when is_list(runs) do
    Enum.flat_map(runs, fn
      %{issue_identifier: identifier} when is_binary(identifier) -> [identifier]
      %{workspace_path: path} when is_binary(path) -> [workspace_identifier_from_path(path)]
      _ -> []
    end)
    |> Enum.reject(&is_nil/1)
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

  defp audit_agent_update(running_entry, update, token_delta) do
    running_entry
    |> AuditLog.record_agent_update(update, token_delta)
    |> log_audit_error("record agent update")
  end

  defp maybe_emit_pr_opened(previous_entry, updated_entry) when is_map(updated_entry) do
    pr_url = URLUtils.pull_request_url(updated_entry)

    if is_nil(URLUtils.pull_request_url(previous_entry)) and is_binary(pr_url) do
      updated_entry
      |> AuditLog.record_pr_opened(pr_url)
      |> log_audit_error("record pr_opened")

      emit_running_event(:pr_opened, updated_entry)
    end
  end

  defp maybe_emit_awaiting_review(state, issue, source)

  defp maybe_emit_awaiting_review(%State{} = state, %Issue{state: issue_state} = issue, source) do
    if in_review_state?(issue_state) do
      maybe_emit_lifecycle_event(state, :awaiting_review, issue, source)
    else
      state
    end
  end

  defp maybe_emit_awaiting_review(state, _issue, _source), do: state

  defp maybe_emit_issue_completed(state, issue, source \\ %{})

  defp maybe_emit_issue_completed(%State{} = state, %Issue{state: issue_state} = issue, source) do
    if done_state?(issue_state) do
      maybe_emit_lifecycle_event(state, :issue_completed, issue, source, close_watch: true)
    else
      state
    end
  end

  defp maybe_emit_issue_completed(state, _issue, _source), do: state

  defp maybe_emit_lifecycle_event(state, event, issue, source, opts \\ [])

  defp maybe_emit_lifecycle_event(%State{} = state, event, %Issue{id: issue_id} = issue, source, opts)
       when is_binary(issue_id) do
    marker = lifecycle_notification_marker(event)
    metadata = lifecycle_metadata(state, issue_id, source)

    if lifecycle_event_notified?(metadata, marker) do
      state
    else
      Notifications.emit_issue_event(event, issue, lifecycle_notification_attrs(state, metadata))
      mark_lifecycle_event_notified(state, issue_id, metadata, marker, issue.state, opts)
    end
  end

  defp maybe_emit_lifecycle_event(state, _event, _issue, _source, _opts), do: state

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
      |> Map.put_new(:pr_url, URLUtils.pull_request_url(running_entry) || URLUtils.pull_request_url(issue))
      |> Map.put_new(:tokens, run_tokens(running_entry))

    Notifications.emit_issue_event(event, issue, attrs)
  end

  defp in_review_state?(state_name) when is_binary(state_name), do: normalize_issue_state(state_name) == "in review"
  defp in_review_state?(_state_name), do: false

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
  defp held_retry_delay_ms(%{phase: :canary}, _now), do: Config.settings!().agent.usage_limit.unknown_reset_retry_seconds * 1000
  defp held_retry_delay_ms(entry, now), do: UsageLimit.remaining_ms(entry, now)

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
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  # Terminal setup failures release the claim so the issue can recover without an
  # orchestrator restart, but record the state it failed in so the next poll does
  # not immediately re-dispatch it into the same failure (tight loop + repeated
  # comments). The suppression lifts once the issue moves to a different tracker
  # state (an explicit operator action) or the orchestrator restarts.
  defp mark_setup_failed(%State{} = state, issue_id, running_entry) when is_binary(issue_id) do
    %{state | setup_failed: Map.put(state.setup_failed, issue_id, setup_failed_issue_state(running_entry))}
  end

  defp setup_failed_issue_state(%{issue: %Issue{state: state_name}}) when is_binary(state_name), do: state_name
  defp setup_failed_issue_state(_running_entry), do: nil

  defp clear_setup_failed(%State{} = state, issue_id) when is_binary(issue_id) do
    %{state | setup_failed: Map.delete(state.setup_failed, issue_id)}
  end

  defp setup_failed_suppressed?(setup_failed, %Issue{id: id, state: state_name}) when is_map(setup_failed) do
    case Map.fetch(setup_failed, id) do
      {:ok, failed_state} -> failed_state == state_name
      :error -> false
    end
  end

  defp setup_failed_suppressed?(_setup_failed, _issue), do: false

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    case retry_delay_type(metadata) do
      :continuation when attempt == 1 -> @continuation_retry_delay_ms
      :linear_wait -> @linear_wait_retry_delay_ms
      :usage_limit -> Map.get(metadata, :usage_limit_delay_ms, 0)
      _delay_type -> failure_retry_delay(attempt)
    end
  end

  defp retry_delay_type(%{delay_type: :continuation}), do: :continuation
  defp retry_delay_type(%{delay_type: "continuation"}), do: :continuation
  defp retry_delay_type(%{delay_type: :linear_wait}), do: :linear_wait
  defp retry_delay_type(%{delay_type: "linear_wait"}), do: :linear_wait
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

  defp hydrate_completed_run_metadata(retry_attempts) when is_map(retry_attempts) do
    case RunStore.list_all_runs(500) do
      runs when is_list(runs) ->
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

      {:error, reason} ->
        Logger.warning("Failed to hydrate completed run metadata from run store: #{inspect(reason)}")
        %{}
    end
  end

  defp hydrate_completed_run_metadata(_retry_attempts), do: %{}

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
      url: URLUtils.present_url(Map.get(metadata, :url)),
      pull_request_url: URLUtils.pull_request_url(metadata)
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
    case RunStore.list_all_runs(:all) do
      runs when is_list(runs) ->
        runs
        |> Enum.filter(&run_started_on_day?(&1, day))
        |> Enum.reduce(0, fn run, total ->
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
    case RunStore.list_all_runs(:all) do
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

  defp run_started_on_day?(%{started_at: %DateTime{} = started_at}, %Date{} = day) do
    DateTime.to_date(started_at) == day
  end

  defp run_started_on_day?(_run, _day), do: false

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

  # The fix run for a failed Auto Review QA pass has finished; the next QA pass on
  # the new head decides whether the finding is fixed.
  defp complete_pending_qa_failure(issue_id, repo_key) when is_binary(issue_id) do
    case CiPoller.complete_pending_qa_failure(issue_id, repo_key_opt(repo_key)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to clear the pending QA failure issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp complete_pending_qa_failure(_issue_id, _repo_key), do: :ok

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
      pull_request_url: URLUtils.pull_request_url(running_entry) || URLUtils.pull_request_url(issue),
      updated_at: now
    }
    |> Map.merge(run_profile_record(Map.get(running_entry, :run_profile)))
    |> Map.merge(reviewer_profile_record(Map.get(running_entry, :reviewer_run_profile)))
  end

  # The pre-push reviewer runs inside this run, so its profile sits next to `reviewer_tokens`.
  defp reviewer_profile_record(nil), do: %{}
  defp reviewer_profile_record(profile), do: %{reviewer_profile: run_profile_record(profile)}

  defp run_profile_record(%{kind: kind, model: model, effort: effort}),
    do: %{run_kind: Atom.to_string(kind), model: model, effort: effort}

  defp run_profile_record(nil), do: %{}

  defp run_update_from_entry(running_entry) when is_map(running_entry) do
    issue = Map.get(running_entry, :issue)

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
      pull_request_url: URLUtils.pull_request_url(running_entry) || URLUtils.pull_request_url(issue),
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

  defp new_run_id(_issue_id) do
    "run-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
  end

  defp attempt_count(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp attempt_count(_attempt), do: 1

  defp terminal_status_for_reason(:timeout), do: "timeout"
  defp terminal_status_for_reason({:timeout, _reason}), do: "timeout"
  defp terminal_status_for_reason({:review_agent_blocked, _reason}), do: "blocked"
  defp terminal_status_for_reason({:tool_failure_circuit_breaker, _payload}), do: "blocked"
  defp terminal_status_for_reason(_reason), do: "failure"

  defp ignore_missing_run({:error, :run_not_found}), do: :ok
  defp ignore_missing_run(other), do: other

  defp log_run_store_error(:ok, _action), do: :ok

  defp log_run_store_error({:error, reason}, action) do
    Logger.warning("Failed to #{action}: #{inspect(reason)}")
    :ok
  end

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
      snapshot = build_snapshot(state, DateTime.utc_now(), monotonic_ms)
      :ets.insert(@snapshot_table, {@snapshot_key, snapshot, monotonic_ms, system_ms})
      :ok
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

  @impl true
  def handle_call({:pause_dispatch, reason}, _from, state) do
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

  def handle_call(:resume_dispatch, _from, state) do
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

  def handle_call(:pause_status, _from, state) do
    {:reply, state.pause || unpaused_state(), state}
  end

  def handle_call({:dispatch_pr, target, opts}, _from, state) do
    state = refresh_runtime_config(state)

    case do_dispatch_pr(state, target, opts) do
      {:ok, result, next_state} ->
        notify_dashboard()
        {:reply, {:ok, result}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:stop_running, issue_id_or_identifier}, _from, state) do
    case find_running_issue(state.running, issue_id_or_identifier) do
      {issue_id, running_entry} ->
        session_id = running_entry_session_id(running_entry)
        Logger.warning("Operator stopping running agent issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}")

        state =
          terminate_running_issue(state, issue_id, true,
            status: "stopped",
            error: "agent stopped by operator",
            track_completed_run: true
          )

        notify_dashboard()

        {:reply,
         {:ok,
          %{
            stopped: true,
            issue_id: issue_id,
            issue_identifier: running_entry.identifier,
            session_id: session_id
          }}, state}

      nil ->
        {:reply, {:ok, %{stopped: false, issue_id: issue_id_or_identifier}}, state}
    end
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    coalesced = poll_tick_coalesced?(state, now_ms)
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    snapshot = build_snapshot(state, DateTime.utc_now(), System.monotonic_time(:millisecond))

    {:reply, snapshot, state}
  end

  defp build_snapshot(%State{} = state, %DateTime{} = now, now_ms) when is_integer(now_ms) do
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
          pull_request_url: URLUtils.pull_request_url(metadata) || URLUtils.pull_request_url(metadata.issue),
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
          runtime_seconds: running_seconds(metadata.started_at, now)
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
          delay_type: retry_delay_type(retry)
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
          transcript_buffer_size: Map.get(watching_entry, :transcript_buffer_size, 0)
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

    awaiting_clarification =
      quality_gate_cache
      |> QualityGate.awaiting_clarification_from_cache()
      |> Enum.map(&snapshot_awaiting_clarification_entry/1)

    %{
      running: running,
      watching: watching,
      waiting_for_ci: waiting_for_ci,
      conflicts: conflicts,
      retrying: retrying,
      awaiting_clarification: awaiting_clarification,
      skipped: skipped,
      run_history: persisted_run_history(state.repo_key),
      codex_totals: state.codex_totals,
      rate_limits: Map.get(state, :rate_limits),
      usage_limits: UsageLimit.snapshot(state.usage_limits, state.usage_windows),
      pause: state.pause || unpaused_state(),
      workspace_lifecycle: workspace_lifecycle_snapshot(state),
      budget: budget_snapshot(state),
      dispatch_state: dispatch_state_snapshot(state),
      epic_lanes: EpicLanes.snapshot(state.epic_lanes, epic_lane_running(state.running)),
      blocked: state.blocked || [],
      finishing: finishing_snapshot(state.running),
      auto_merge: PrReviewPoller.auto_merge_statuses(),
      slot_waiting: slot_waiting_snapshot(state.slot_waiting) ++ merging_ci_waiting_snapshot(state.merging_ci_waits),
      claimed: state.claimed |> MapSet.to_list() |> Enum.sort(),
      pollers: poller_status_snapshot(),
      polling: %{
        checking?: state.poll_check_in_progress == true,
        next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
        poll_interval_ms: state.poll_interval_ms,
        linear: linear_rate_limit_snapshot(state)
      }
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

  defp slot_waiting_snapshot(slot_waiting) do
    slot_waiting
    |> Enum.map(fn {issue_id, entry} ->
      entry
      |> Map.take([:identifier, :title, :state, :reason, :attempt, :since])
      |> Map.put(:issue_id, issue_id)
    end)
    |> Enum.sort_by(& &1.since, DateTime)
  end

  # Merging issues held for CI aren't waiting for a slot, but they show in the same list with why.
  defp merging_ci_waiting_snapshot(merging_ci_waits) do
    merging_ci_waits
    |> Enum.map(fn {issue_id, wait} ->
      %{
        issue_id: issue_id,
        identifier: wait.identifier,
        title: wait.title,
        state: "Merging",
        reason: "waiting for CI on #{wait.commit_sha}",
        attempt: nil,
        since: wait.since
      }
    end)
    |> Enum.sort_by(& &1.since, DateTime)
  end

  defp dispatch_slot_label(%State{} = state, %Issue{} = issue) do
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
    reviewer_uncached_input_tokens = reviewer_uncached_input_tokens(running_entry)
    reviewer_cached_input_tokens = reviewer_cached_input_tokens(running_entry)
    reviewer_cache_creation_input_tokens = reviewer_cache_creation_input_tokens(running_entry)
    reviewer_output_tokens = reviewer_output_tokens(running_entry)
    reviewer_total_tokens = reviewer_total_tokens(running_entry)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    transcript_path = Map.get(running_entry, :transcript_path)
    pull_request_url = URLUtils.pull_request_url(update) || URLUtils.pull_request_url(running_entry)
    last_reported_uncached_input = last_reported_token(running_entry, :uncached_input)
    last_reported_cached_input = last_reported_token(running_entry, :cached_input)
    last_reported_cache_creation_input = last_reported_token(running_entry, :cache_creation_input)
    last_reported_output = last_reported_token(running_entry, :output)
    last_reported_total = last_reported_token(running_entry, :total)
    turn_count = Map.get(running_entry, :turn_count, 0)
    reviewer_delta = reviewer_token_delta(update, token_delta)
    next_uncached_input_tokens = uncached_input_tokens + token_delta.uncached_input_tokens
    next_cached_input_tokens = cached_input_tokens + token_delta.cached_input_tokens
    next_cache_creation_input_tokens = cache_creation_input_tokens + token_delta.cache_creation_input_tokens
    next_input_tokens = next_uncached_input_tokens + next_cached_input_tokens + next_cache_creation_input_tokens
    next_output_tokens = output_tokens + token_delta.output_tokens
    next_total_tokens = total_tokens + token_delta.total_tokens
    next_reviewer_uncached_input_tokens = reviewer_uncached_input_tokens + reviewer_delta.uncached_input_tokens
    next_reviewer_cached_input_tokens = reviewer_cached_input_tokens + reviewer_delta.cached_input_tokens

    next_reviewer_cache_creation_input_tokens =
      reviewer_cache_creation_input_tokens + reviewer_delta.cache_creation_input_tokens

    next_reviewer_input_tokens =
      next_reviewer_uncached_input_tokens + next_reviewer_cached_input_tokens +
        next_reviewer_cache_creation_input_tokens

    next_reviewer_output_tokens = reviewer_output_tokens + reviewer_delta.output_tokens
    next_reviewer_total_tokens = reviewer_total_tokens + reviewer_delta.total_tokens
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
        reviewer_input_tokens: next_reviewer_input_tokens,
        reviewer_uncached_input_tokens: next_reviewer_uncached_input_tokens,
        reviewer_cached_input_tokens: next_reviewer_cached_input_tokens,
        reviewer_cache_creation_input_tokens: next_reviewer_cache_creation_input_tokens,
        reviewer_output_tokens: next_reviewer_output_tokens,
        reviewer_total_tokens: next_reviewer_total_tokens,
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

  defp reviewer_token_delta(%{agent_phase: :reviewer}, token_delta), do: token_delta

  defp reviewer_token_delta(_update, _token_delta) do
    %{
      input_tokens: 0,
      uncached_input_tokens: 0,
      cached_input_tokens: 0,
      cache_creation_input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0
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

  defp maybe_put_review_agent_verdict_tokens(%{event: event} = update, running_entry)
       when event in [:review_agent_verdict, "review_agent_verdict"] and is_map(running_entry) do
    payload =
      update
      |> Map.get(:payload, %{})
      |> put_map_value(:tokens, reviewer_tokens(running_entry))

    Map.put(update, :payload, payload)
  end

  defp maybe_put_review_agent_verdict_tokens(update, _running_entry), do: update

  defp put_map_value(map, key, value) when is_map(map), do: Map.put(map, key, value)
  defp put_map_value(_map, key, value), do: %{key => value}

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
      pull_request_url: URLUtils.pull_request_url(running_entry) || URLUtils.pull_request_url(issue),
      last_ran_at: DateTime.utc_now(),
      session_id: Map.get(running_entry, :session_id),
      started_at: Map.get(running_entry, :started_at),
      last_event_at: Map.get(running_entry, :last_event_at) || Map.get(running_entry, :last_codex_timestamp),
      turn_count: Map.get(running_entry, :turn_count, 0),
      tokens: run_tokens(running_entry),
      reviewer_tokens: reviewer_tokens(running_entry),
      review_agent_enabled: Map.get(running_entry, :review_agent_enabled, false),
      transcript_path: Map.get(running_entry, :transcript_path),
      transcript_buffer: transcript_buffer_list(running_entry),
      transcript_buffer_size: transcript_buffer_size(running_entry)
    }
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

    watching_entry = %{
      repo_key: watching_repo_key(state, issue, completed_metadata, existing),
      identifier: watching_identifier(issue, issue_id, completed_metadata, existing),
      title: watching_title(issue, completed_metadata, existing),
      state: issue.state,
      url: watching_url(issue, completed_metadata, existing),
      pull_request_url: watching_pull_request_url(issue, completed_metadata, existing),
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
      transcript_buffer_size: watching_metadata(:transcript_buffer_size, completed_metadata, existing, 0)
    }

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

  defp watching_pull_request_url(issue, completed_metadata, existing) do
    URLUtils.pull_request_url(issue) ||
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
        watching: Map.delete(state.watching, issue_id)
    }
  end

  defp forget_completed_issue(state, _issue_id), do: state

  defp issue_workspace_context(%Issue{} = issue, repo_key) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      repo_key: repo_key,
      labels: issue.labels || []
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

    entry =
      UsageLimit.put(existing, info,
        now: state.clock.(),
        config: Config.settings!().agent.usage_limit,
        windows: state.usage_windows,
        issue_identifier: identifier
      )

    newly_paused? = is_nil(existing) or existing.phase == :headroom
    if newly_paused?, do: emit_usage_limit_event(:usage_limit_paused, entry, issue_identifier: identifier)

    cond do
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

    state = put_usage_limits(state, Map.put(state.usage_limits, key, entry))
    {arm_usage_limit_timer(state, key, entry), entry}
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
  # hold keeps every other run of the provider back. With nothing held the hold just clears.
  defp start_usage_limit_canary(%State{} = state, key, entry, issue_fetcher) do
    state = %{state | usage_limit_timers: Map.delete(state.usage_limit_timers, key)}

    case held_usage_limit_retries(state, key) do
      [] ->
        clear_usage_limit(state, key, entry)

      held ->
        {issue_id, retry} = pick_usage_limit_canary(held, issue_fetcher)
        Logger.warning("Usage limit canary provider=#{entry.provider} scope=#{UsageLimit.scope_label(entry.scope)} issue_identifier=#{retry[:identifier]}")

        state
        |> put_usage_limits(Map.put(state.usage_limits, key, UsageLimit.canary(entry, issue_id)))
        |> release_usage_limit_retry(issue_id, retry)
        |> schedule_immediate_tick()
    end
  end

  defp held_usage_limit_retries(%State{} = state, key) do
    Enum.filter(state.retry_attempts, fn {_issue_id, retry} -> Map.get(retry, :usage_limit_key) == key end)
  end

  # Issues the tracker no longer returns sort last, by id.
  defp pick_usage_limit_canary(held, issue_fetcher) do
    held_by_id = Map.new(held)
    issue_ids = held_by_id |> Map.keys() |> Enum.sort()

    ordered_ids =
      case issue_fetcher.(issue_ids) do
        {:ok, issues} -> issues |> sort_issues_for_dispatch() |> Enum.map(& &1.id)
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
  # continuation of a run that just ended is not a new run to a headroom hold.
  defp usage_limit_hold(state, issue, continuation? \\ false)

  defp usage_limit_hold(%State{usage_limits: usage_limits}, _issue, _continuation?) when map_size(usage_limits) == 0, do: nil

  defp usage_limit_hold(%State{usage_limits: usage_limits} = state, %Issue{} = issue, continuation?) do
    repo_key = dispatch_repo_key(state, issue)
    profile = AgentRunner.run_profile(issue, Config.settings_for_repo!(repo_key), repo_key: repo_key)
    UsageLimit.holding(usage_limits, Map.put(profile, :continuation, continuation?), issue.id)
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
      !auto_merge_landing?(issue)
  end

  # A `Merging` issue waiting for CI after its landing run, or landed by GitHub auto-merge.
  defp landing_held?(%Issue{} = issue, %State{} = state) do
    Map.has_key?(state.merging_ci_waits, issue.id) or auto_merge_landing?(issue)
  end

  # GitHub auto-merge lands a `Merging` issue without an agent (see AutoMerge); the landing
  # agent only runs when the PR poller falls back to it.
  defp auto_merge_landing?(%Issue{} = issue) do
    if AutoMerge.owns_issue?(issue) do
      Logger.debug("Skipping dispatch; GitHub auto-merge is landing #{issue_context(issue)}")
      true
    else
      false
    end
  end

  defp post_pr_quiet_active_issue?(%Issue{id: issue_id} = issue, %State{} = state)
       when is_binary(issue_id) do
    completed_metadata = Map.get(state.completed_run_metadata, issue_id, %{})

    completed_run_has_pr?(completed_metadata) and
      active_issue_state?(issue.state) and
      !rework_state?(issue.state) and
      !merging_state?(issue.state) and
      !pending_rework_signal?(issue, completed_metadata)
  end

  defp post_pr_quiet_active_issue?(_issue, _state), do: false

  defp completed_run_has_pr?(completed_metadata) when is_map(completed_metadata) do
    is_binary(URLUtils.pull_request_url(completed_metadata))
  end

  defp completed_run_has_pr?(_completed_metadata), do: false

  defp pending_rework_signal?(%Issue{} = issue, completed_metadata) do
    issue_updated_after_last_run?(issue, completed_metadata) or
      pending_reviewer_comments?(issue.id, repo_key_from(completed_metadata)) or
      pending_ci_failure?(issue.id, repo_key_from(completed_metadata)) or
      pending_qa_failure?(issue.id, repo_key_from(completed_metadata))
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
    not is_nil(CiPoller.pending_ci_failure(issue_id, repo_key_opt(repo_key)))
  end

  defp pending_ci_failure?(_issue_id, _repo_key), do: false

  defp pending_qa_failure?(issue_id, repo_key) when is_binary(issue_id) do
    not is_nil(CiPoller.pending_qa_failure(issue_id, repo_key_opt(repo_key)))
  end

  defp pending_qa_failure?(_issue_id, _repo_key), do: false

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

  defp seconds_since(%DateTime{} = timestamp, %DateTime{} = now) do
    max(0, DateTime.diff(now, timestamp, :second))
  end

  defp seconds_since(_timestamp, _now), do: nil

  defp log_audit_error(:ok, _action), do: :ok

  defp log_audit_error({:error, reason}, action) do
    Logger.warning("Audit log failed to #{action}: #{inspect(reason)}")
    :ok
  end
end
