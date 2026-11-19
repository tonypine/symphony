defmodule SymphonyElixir.Conductor.Watch do
  @moduledoc """
  The Conductor's watch over running runs (`conductor.watch`, off by default): it looks at a running
  run when something says it may need steering, and runs a Conductor turn on it
  (`SymphonyElixir.Conductor.watch/3`), which may steer the run (`SymphonyElixir.Conductor.Steer`),
  or stop it with a question to the person.

  It looks when (`trigger/4`):

    * a step of the run ended `failed` (`step_failed`), or the same step failed twice
      (`step_failed_twice`);
    * a step of a stepped QA pass answered `plan_mismatch` or `blocked` (`qa_step_answer`), read from
      the machine note the pass records for the step's answer (`SymphonyElixir.QaAgent.Steps`: "<step
      title>: <status>. Expected: ... Actual: ...");
    * the run passed `watch.run_minutes` (`run_minutes`) or `watch.run_tokens` (`run_tokens`).

  Never more often than `watch.min_interval_minutes` per run, at most `watch.max_turns_per_run`
  turns per run, one at a time. It checks the running runs on a timer and, while it is on, as each
  step or note of a running run is recorded (it listens to the ticket events only while on). A failed
  watch turn changes nothing for the run. It owns the steer table;
  a run that ended drops what still waited for it (`Steer.drop/1`).
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Conductor, Config, Orchestrator}
  alias SymphonyElixir.Conductor.{Facts, Steer}
  alias SymphonyElixir.TicketEvents.Event
  alias SymphonyElixirWeb.ObservabilityPubSub

  @tick_ms 30_000
  @qa_answer ~r/\A[^\n]+: (plan_mismatch|blocked)\. Expected:/

  @typedoc "One run's watch: turns run, when the last started (monotonic ms), the events already read, and whether a turn runs."
  @type run_watch :: %{turns: non_neg_integer(), last_ms: integer() | nil, seen: MapSet.t(String.t()), busy: boolean()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    Steer.create_table()
    tick_ms = Keyword.get(opts, :tick_ms, @tick_ms)
    Process.send_after(self(), :tick, tick_ms)

    {:ok,
     %{
       runs: %{},
       tick_ms: tick_ms,
       subscribe: Keyword.get(opts, :subscribe, true),
       subscribed: false,
       running: Keyword.get(opts, :running, &running/0),
       start_turn: Keyword.get(opts, :start_turn) || (&start_turn/3),
       now_ms: Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, look(state, nil)}
  end

  def handle_info({:ticket_event, %{type: type, issue_id: issue_id}}, state) when type in ["step.completed", "note"],
    do: {:noreply, look(state, issue_id)}

  def handle_info({:watch_done, run_id}, state), do: {:noreply, update_in(state, [:runs], &mark_done(&1, run_id))}
  def handle_info(_message, state), do: {:noreply, state}

  defp mark_done(runs, run_id), do: if(Map.has_key?(runs, run_id), do: put_in(runs, [run_id, :busy], false), else: runs)

  # The running runs (all, or `issue_id`'s), each looked at; runs no longer running are forgotten.
  defp look(state, issue_id) do
    settings = Config.conductor_settings()

    on? = settings.enabled and settings.watch.enabled
    state = listen(state, on?)

    if on? do
      running = state.running.()
      state = if is_nil(issue_id), do: forget_ended(state, running), else: state
      running |> Enum.filter(&(is_nil(issue_id) or &1.issue_id == issue_id)) |> Enum.reduce(state, &consider(&2, &1, settings.watch))
    else
      state
    end
  end

  # The ticket events are heard only while the watch is on.
  defp listen(%{subscribe: true, subscribed: false} = state, true) do
    ObservabilityPubSub.subscribe_ticket_events()
    %{state | subscribed: true}
  end

  defp listen(%{subscribed: true} = state, false) do
    ObservabilityPubSub.unsubscribe_ticket_events()
    %{state | subscribed: false}
  end

  defp listen(state, _on?), do: state

  defp forget_ended(state, running) do
    live = MapSet.new(running, & &1.run_id)
    {ended, kept} = Map.split_with(state.runs, fn {run_id, _watch} -> not MapSet.member?(live, run_id) end)
    Enum.each(Map.keys(ended), &Steer.drop/1)
    %{state | runs: kept}
  end

  defp consider(state, %{run_id: run_id} = run, watch) when is_binary(run_id) do
    now = state.now_ms.()
    run_watch = Map.get(state.runs, run_id, %{turns: 0, last_ms: nil, seen: MapSet.new(), busy: false})

    with true <- may_look?(run_watch, watch, now),
         {trigger, seen} <- trigger(run_events(run), run, watch, run_watch.seen) do
      Logger.info("Conductor watch looks at issue_id=#{run.issue_id} run_id=#{run_id} trigger=#{trigger}")
      state.start_turn.(run, trigger, self())
      put_in(state, [:runs, run_id], %{run_watch | turns: run_watch.turns + 1, last_ms: now, seen: seen, busy: true})
    else
      _quiet -> put_in(state, [:runs, run_id], run_watch)
    end
  end

  defp consider(state, _run, _watch), do: state

  @doc "Whether a run may be looked at now: no turn runs on it, it has turns left and the interval passed."
  @spec may_look?(run_watch(), Config.Schema.Conductor.Watch.t(), integer()) :: boolean()
  def may_look?(run_watch, watch, now_ms) do
    not run_watch.busy and run_watch.turns < watch.max_turns_per_run and
      (is_nil(run_watch.last_ms) or now_ms - run_watch.last_ms >= watch.min_interval_minutes * 60_000)
  end

  @doc """
  What makes the watch look at `run` now, from its `events` (oldest first) and its live state
  (`started_at`, `total_tokens`), with the event ids `seen` already: `{trigger, seen}` with the ids
  read now added, or nil. A failed step or a QA step's answer counts once; time and tokens count
  while they stay over the limit.
  """
  @spec trigger([Event.t()], map(), Config.Schema.Conductor.Watch.t(), MapSet.t(String.t())) ::
          {String.t(), MapSet.t(String.t())} | nil
  def trigger(events, run, watch, seen) do
    failed = Enum.filter(events, &(&1.type == "step.completed" and &1.payload[:outcome] == "failed"))
    new = Enum.reject(failed ++ Enum.filter(events, &qa_answer?/1), &MapSet.member?(seen, &1.id))
    seen = Enum.reduce(new, seen, &MapSet.put(&2, &1.id))

    case event_trigger(new, failed) || limit_trigger(run, watch) do
      nil -> nil
      trigger -> {trigger, seen}
    end
  end

  defp event_trigger(new, failed) do
    cond do
      new_failure?(new) and failed_twice?(failed, new) -> "step_failed_twice"
      new_failure?(new) -> "step_failed"
      new != [] -> "qa_step_answer"
      true -> nil
    end
  end

  defp limit_trigger(run, watch) do
    cond do
      minutes(run) >= watch.run_minutes -> "run_minutes"
      (run[:total_tokens] || 0) >= watch.run_tokens -> "run_tokens"
      true -> nil
    end
  end

  defp qa_answer?(%Event{type: "note", actor: %{kind: :machine}, payload: %{text: text}}) when is_binary(text),
    do: Regex.match?(@qa_answer, text)

  defp qa_answer?(_event), do: false

  defp new_failure?(new), do: Enum.any?(new, &(&1.type == "step.completed"))

  defp failed_twice?(failed, new) do
    counts = Enum.frequencies_by(failed, & &1.payload[:step_id])
    Enum.any?(new, &(&1.type == "step.completed" and Map.get(counts, &1.payload[:step_id], 0) >= 2))
  end

  defp minutes(%{started_at: %DateTime{} = started_at}), do: DateTime.diff(DateTime.utc_now(), started_at, :second) / 60
  defp minutes(_run), do: 0

  defp run_events(%{issue_id: issue_id, run_id: run_id}), do: issue_id |> Facts.events() |> Enum.filter(&(&1.run_id == run_id))

  defp running, do: running_in(Orchestrator.snapshot())

  @doc "The running runs of an orchestrator `snapshot`; none while it can't answer (`:timeout`, `:unavailable`)."
  @spec running_in(map() | atom()) :: [map()]
  def running_in(%{running: running}) when is_list(running), do: running
  def running_in(_unavailable), do: []

  # The turn runs on its own: whatever it does, it tells the watch it is done.
  defp start_turn(run, trigger, watch) do
    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      try do
        Conductor.watch(run, trigger, [])
      after
        send(watch, {:watch_done, run.run_id})
      end
    end)
  end

  @doc "The live state a watch turn reads of `run` besides the facts: kind, model, steps, the step it is on, its newest lines, elapsed time and tokens."
  @spec live(map(), [Event.t()]) :: map()
  def live(run, events) do
    completed = for %Event{type: "step.completed"} = step <- events, do: step.payload[:step_id]

    %{
      run_id: run.run_id,
      kind: run_profile(run, :kind),
      model: run_profile(run, :model),
      harness: run_profile(run, :harness),
      steps: for(%Event{type: "step.completed"} = step <- events, do: %{event_id: step.id, step_id: step.payload[:step_id], outcome: step.payload[:outcome]}),
      current_step: events |> Enum.filter(&(&1.type == "step.started" and &1.payload[:step_id] not in completed)) |> List.last() |> current_step(),
      newest_lines: run |> Map.get(:transcript_buffer, []) |> Enum.take(-20) |> Enum.map(&line/1),
      elapsed_minutes: round(minutes(run)),
      tokens: run[:total_tokens]
    }
  end

  defp run_profile(run, key), do: run |> Map.get(:run_profile) |> Kernel.||(%{}) |> Map.get(key) |> to_string_or_nil()

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp current_step(%Event{payload: payload}), do: %{step_id: payload[:step_id], title: payload[:title], mode: payload[:mode]}
  defp current_step(nil), do: nil

  defp line(line) when is_binary(line), do: Facts.cut(line, 300)
  defp line(%{} = line), do: line |> Map.get(:message, Map.get(line, "message", inspect(line))) |> to_string() |> Facts.cut(300)
  defp line(line), do: line |> inspect() |> Facts.cut(300)
end
