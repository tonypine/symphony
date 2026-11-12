defmodule SymphonyElixir.Reports.Scheduler do
  @moduledoc """
  Starts report runs (`SymphonyElixir.Reports`) on their own: at the cadence of `reports.cadence`
  and on each event a switch of `reports.triggers` turns on. Each run covers the period since the
  last report's (`report.published`) end, up to now; with no report yet, one cadence interval back
  (six hours when the cadence is `none`).

  The cadence's boundaries are on the UTC clock: every full hour (`hourly`), 00:00, 06:00, 12:00 and
  18:00 (`six_hours`), midnight (`daily`). A boundary runs a report when no report ended at or
  after it and the scheduler did not already run one for it; a boundary that passed while Symphony
  was down runs at startup, which checks the schedule once at once. The scheduler wakes at each full
  hour and reads `reports` again then, so a cadence changed in Settings needs no restart.

  A trigger (`trigger/2`) reads the ticket event the live channel announces
  (`SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_events/0`): a ticket shipped (it entered
  Done, not from Epic Review), an epic closed (Done from Epic Review), a CI-fix loop past three
  rounds (the ticket entered CI Fix for the fourth time), a self-heal fix ticket filed
  (a rule's `filed_ticket` action), a release installed (the `:release_installed` rule of
  `SymphonyElixir.TicketEvents.Notable`) and the factory paused by a rule (Symphony's pause set by
  anyone but the Director). A trigger starts a report at once, and any trigger within a minute of a
  report's start starts none: its event is in the next report's period.

  One report run at a time: a boundary or a trigger that comes while one runs waits for it, and a
  run waits like any run for a usage-limit hold on its model's provider (`SymphonyElixir.UsageLimit`),
  until the hold's `resume_at`. A period without a notable event writes no report. Once a run
  published its report, the project update (`SymphonyElixir.HumanActions`) is read again, so it
  carries the new report.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, HumanActions, Reports, RunStore, UsageLimit}
  alias SymphonyElixir.Config.Schema.Reports.Triggers
  alias SymphonyElixir.TicketEvents.{Event, Notable}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @coalesce_ms 60_000
  @ci_fix_loop_past 3
  @hour 3_600
  @intervals %{"hourly" => @hour, "six_hours" => 6 * @hour, "daily" => 24 * @hour}
  @first_period_seconds 6 * @hour
  @symphony_stream "symphony"
  @trigger_types ~w(phase.entered rule.action pause.set pause.reason_cleared pause.cleared)

  @type trigger ::
          :ticket_shipped
          | :epic_closed
          | :ci_fix_loop
          | :self_heal_filed
          | :release_installed
          | :paused_by_rule
  @type reason :: :cadence | trigger()

  @doc """
  Starts the scheduler. `opts` (for tests): `name:`; `subscribe:` (default true, the live channel);
  `now:` (`-> DateTime.t()`); `settings:` (`-> SymphonyElixir.Config.Schema.Reports.t()`, default
  `SymphonyElixir.Config.report_settings/0`); `latest_report:` (`-> Event.t() | nil`, default
  `SymphonyElixir.Reports.latest/0`); `launch:` (`(period, opts) -> {:ok, started, task} |
  {:error, reason}`, default `SymphonyElixir.Reports.launch/2`, with the run as a task this process
  awaits); `holding:` (`model -> UsageLimit.entry() | nil`); `read_event:` (`notice -> {:ok, event,
  stream_events} | :error`) and `published:` (`-> term()`, default `SymphonyElixir.HumanActions.refresh/0`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "How long after a report's start a trigger starts no report of its own: a minute."
  @spec coalesce_ms() :: pos_integer()
  def coalesce_ms, do: @coalesce_ms

  @doc "How many CI-fix rounds a ticket's loop passes before it triggers a report."
  @spec ci_fix_loop_past() :: pos_integer()
  def ci_fix_loop_past, do: @ci_fix_loop_past

  @doc "The seconds between two boundaries of `cadence`, or nil for `none`."
  @spec interval(String.t()) :: pos_integer() | nil
  def interval(cadence), do: Map.get(@intervals, cadence)

  @doc """
  The newest boundary of `cadence` at or before `now`, on the UTC clock, or nil for `none`.
  """
  @spec boundary(String.t(), DateTime.t()) :: DateTime.t() | nil
  def boundary(cadence, %DateTime{} = now) do
    with interval when is_integer(interval) <- interval(cadence) do
      seconds = DateTime.to_unix(now)
      DateTime.from_unix!(seconds - rem(seconds, interval))
    end
  end

  @doc """
  The trigger `event` fires, given the events of its stream oldest first, or nil (see the
  moduledoc).
  """
  @spec trigger(Event.t(), [Event.t()]) :: trigger() | nil
  def trigger(%Event{type: "phase.entered", issue_id: issue_id, payload: payload} = event, events) when issue_id != @symphony_stream do
    case phase(field(payload, :to)) do
      "done" -> if phase(field(payload, :from)) == "epic review", do: :epic_closed, else: :ticket_shipped
      "ci fix" -> if ci_fix_round(event, events) == @ci_fix_loop_past + 1, do: :ci_fix_loop
      _other -> nil
    end
  end

  def trigger(%Event{type: "rule.action", issue_id: issue_id, payload: payload}, _events) when issue_id != @symphony_stream do
    if field(payload, :action) == "filed_ticket", do: :self_heal_filed
  end

  def trigger(%Event{type: "pause.set", issue_id: @symphony_stream, payload: payload}, _events) do
    if field(Map.get(payload, :set_by) || Map.get(payload, "set_by"), :kind) != "person", do: :paused_by_rule
  end

  def trigger(%Event{issue_id: @symphony_stream} = event, events) do
    if Notable.holds?(:release_installed, event, %{events: events, now: DateTime.utc_now()}), do: :release_installed
  end

  def trigger(_event, _events), do: nil

  # Which time the ticket enters CI Fix with `event`: the CI Fix entries of its stream up to it.
  defp ci_fix_round(event, events) do
    events
    |> Enum.take_while(&(&1.id != event.id))
    |> Enum.concat([event])
    |> Enum.count(&(&1.type == "phase.entered" and phase(field(&1.payload, :to)) == "ci fix"))
  end

  defp phase(nil), do: nil
  defp phase(name), do: name |> String.trim() |> String.downcase()

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: ObservabilityPubSub.subscribe_ticket_events()
    # Startup is a trigger: the schedule is checked once at once.
    send(self(), :cadence)
    {:ok, %{opts: opts, timer: nil, hold_timer: nil, running: nil, queued: nil, last_start_ms: nil, handled_slot: nil}}
  end

  @impl true
  def handle_info(:cadence, state) do
    now = now(state)
    settings = settings(state)
    state = schedule_tick(state, now)

    case due_slot(settings.cadence, now, state) do
      nil -> {:noreply, state}
      slot -> {:noreply, request(%{state | handled_slot: slot}, :cadence)}
    end
  end

  def handle_info({:ticket_event, notice}, state) do
    settings = settings(state)

    with type when type in @trigger_types <- Map.get(notice, :type),
         true <- Enum.any?(Triggers.names(), &Map.fetch!(settings.triggers, &1)),
         {:ok, event, events} <- read_event(state, notice),
         name when not is_nil(name) <- trigger(event, events),
         true <- Map.fetch!(settings.triggers, name) do
      {:noreply, triggered(state, name)}
    else
      _no_trigger -> {:noreply, state}
    end
  end

  def handle_info(:hold_over, state), do: {:noreply, start_queued(%{state | hold_timer: nil})}

  def handle_info({ref, result}, %{running: %{ref: ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, _event} -> Keyword.get(state.opts, :published, &HumanActions.refresh/0).()
      _no_report -> :ok
    end

    {:noreply, start_queued(%{state | running: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref}} = state) do
    Logger.warning("Report run ended without a report reason=#{inspect(reason)}")
    {:noreply, start_queued(%{state | running: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A trigger within a minute of a report's start starts none; its event is in the next period.
  defp triggered(state, name) do
    if is_integer(state.last_start_ms) and now_ms(state) - state.last_start_ms < @coalesce_ms do
      Logger.debug("Report trigger #{name} coalesced into the report started less than a minute ago")
      state
    else
      request(state, name)
    end
  end

  # The boundary a report is due for: the newest one, when no report ended at or after it and none
  # was run for it.
  defp due_slot(cadence, now, state) do
    with %DateTime{} = slot <- boundary(cadence, now),
         true <- after?(slot, state.handled_slot),
         true <- after?(slot, latest_end(state)) do
      slot
    else
      _not_due -> nil
    end
  end

  defp after?(_slot, nil), do: true
  defp after?(slot, at), do: DateTime.compare(slot, at) == :gt

  # The next full hour, where every cadence's boundaries fall.
  defp schedule_tick(state, now) do
    if state.timer, do: Process.cancel_timer(state.timer)
    seconds = DateTime.to_unix(now)
    delay_ms = (@hour - rem(seconds, @hour)) * 1_000
    %{state | timer: Process.send_after(self(), :cadence, delay_ms)}
  end

  defp request(%{running: %{}} = state, reason), do: %{state | queued: state.queued || reason}
  defp request(%{hold_timer: timer} = state, reason) when not is_nil(timer), do: %{state | queued: state.queued || reason}
  defp request(state, reason), do: start(%{state | queued: reason})

  defp start_queued(%{queued: nil} = state), do: state
  defp start_queued(state), do: start(state)

  defp start(%{queued: reason} = state) do
    settings = settings(state)
    now = now(state)

    case holding(state, settings.model) do
      %{resume_at: %DateTime{} = resume_at} ->
        delay_ms = max(DateTime.diff(resume_at, now, :millisecond), 1_000)
        Logger.info("Report run #{reason} waits for the usage-limit hold until #{DateTime.to_iso8601(resume_at)}")
        %{state | hold_timer: Process.send_after(self(), :hold_over, delay_ms)}

      nil ->
        launch(%{state | queued: nil, last_start_ms: now_ms(state)}, reason, settings, now)
    end
  end

  defp launch(state, reason, settings, now) do
    from = latest_end(state) || DateTime.add(now, -(interval(settings.cadence) || @first_period_seconds), :second)

    if DateTime.compare(from, now) == :lt do
      launch = Keyword.get(state.opts, :launch, &Reports.launch/2)

      case launch.(%{from: from, to: now}, model: settings.model, start_task: &Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, &1)) do
        {:ok, started, %{ref: ref}} ->
          Logger.info("Report run started by #{reason} run_id=#{started.run_id}")
          %{state | running: %{ref: ref, reason: reason}}

        {:error, :no_events} ->
          Logger.debug("Report run #{reason} skipped: no notable event since #{DateTime.to_iso8601(from)}")
          state

        {:error, error} ->
          Logger.warning("Report run #{reason} could not start: #{inspect(error)}")
          state
      end
    else
      state
    end
  end

  # When the newest report's period ended, or nil when there is no report.
  defp latest_end(state) do
    case Keyword.get(state.opts, :latest_report, &Reports.latest/0).() do
      %Event{payload: payload, at: at} -> period_end(payload) || at
      nil -> nil
    end
  end

  defp period_end(payload) do
    with %{} = period <- Map.get(payload, :period) || Map.get(payload, "period"),
         to when is_binary(to) <- Map.get(period, :to) || Map.get(period, "to"),
         {:ok, to, _offset} <- DateTime.from_iso8601(to) do
      to
    else
      _other -> nil
    end
  end

  defp holding(state, model) do
    case Keyword.fetch(state.opts, :holding) do
      {:ok, holding} -> holding.(model)
      :error -> UsageLimit.persisted_holding(%{provider: "anthropic", model: model})
    end
  end

  defp read_event(state, notice) do
    case Keyword.fetch(state.opts, :read_event) do
      {:ok, read_event} -> read_event.(notice)
      :error -> read_stream_event(notice)
    end
  end

  defp read_stream_event(%{issue_id: issue_id, event_id: event_id}) when is_binary(issue_id) do
    with events when is_list(events) <- stream_events(issue_id),
         %Event{} = event <- Enum.find(events, &(&1.id == event_id)) do
      {:ok, event, events}
    else
      _missing -> :error
    end
  end

  defp read_stream_event(_notice), do: :error

  defp stream_events(@symphony_stream), do: RunStore.list_subject_events(:symphony, [])
  defp stream_events(issue_id), do: RunStore.list_ticket_events(issue_id, [])

  defp settings(state), do: Keyword.get(state.opts, :settings, &Config.report_settings/0).()
  defp now(state), do: Keyword.get(state.opts, :now, &DateTime.utc_now/0).()
  defp now_ms(state), do: DateTime.to_unix(now(state), :millisecond)

  defp field(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_atom(value) and not is_nil(value) and not is_boolean(value) -> Atom.to_string(value)
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp field(_map, _key), do: nil
end
