defmodule SymphonyElixir.TicketEvents.RunEnds do
  @moduledoc """
  The runs a ticket's record started and never ended (a `run.started` with no `run.ended` for its
  run id), and their close.

  A run's end is written when its task exits or when Symphony stops it. A run Symphony was holding
  when it quit (to install an update, say, while the run waited between turns for it) gets neither:
  the shutdown never delivers the task's exit, and the next boot only closed its row in the run
  list. `close_unended/1` runs once at each boot, before the orchestrator holds any run, and records
  every such run's `run.ended` at the time `open/1` gives it, with the exit
  #{inspect("ended; no end was recorded")} and `counted: false`, never a made-up result. The event is
  idempotent by run id, so a run is closed once.

  The events feed reads `open/1` the same way for a run the orchestrator does not hold
  (`SymphonyElixirWeb.Presenter.ticket_timeline_json/5`), so the feed and the boot's close give a
  run the same end.
  """

  require Logger

  alias SymphonyElixir.{RunStore, TicketSignals}
  alias SymphonyElixir.TicketEvents.Event

  @exit "ended; no end was recorded"
  @activity_types ["run.started", "run.ended", "step.started", "step.completed"]

  @doc "The exit a run closed without its end reads with."
  @spec unrecorded_exit() :: String.t()
  def unrecorded_exit, do: @exit

  @doc "The event types `open/1` reads a run's end from: what a reader of it must hold."
  @spec activity_types() :: [String.t()]
  def activity_types, do: @activity_types

  @doc """
  The runs of one ticket's `events` (oldest first) with a `run.started` and no `run.ended`, oldest
  first, each as `{started, ended_at}`. `ended_at` is the `at` of the ticket's next `run.started`,
  the event that proves the run had ended (a ticket holds one run at a time), else the `at` of the
  run's own last event of `activity_types/0` (its last step, else its start): the last time the
  record saw it working. Events of other types are ignored, so any read holding those types gives
  the same ends.
  """
  @spec open([Event.t()]) :: [{Event.t(), DateTime.t()}]
  def open(events) when is_list(events) do
    ended = for %Event{type: "run.ended", payload: payload} <- events, into: MapSet.new(), do: Map.get(payload, :run_id)
    starts = Enum.filter(events, &(&1.type == "run.started" and is_binary(Map.get(&1.payload, :run_id))))

    last_seen =
      for %Event{type: type, run_id: run_id, at: at} <- events,
          type in @activity_types,
          is_binary(run_id),
          into: %{},
          do: {run_id, at}

    starts
    |> Enum.with_index()
    |> Enum.reject(fn {started, _index} -> MapSet.member?(ended, started.payload.run_id) end)
    |> Enum.map(fn {started, index} ->
      {started, next_start(starts, index) || Map.get(last_seen, started.payload.run_id, started.at)}
    end)
  end

  defp next_start(starts, index) do
    case Enum.at(starts, index + 1) do
      %Event{at: at} -> at
      nil -> nil
    end
  end

  @doc """
  The boot's close (`close_unended/1`), unless `opts[:enabled]` (default: the
  `:close_unended_runs` setting of the app, true) turns it off. Returns how many runs it closed.
  """
  @spec close_at_boot(keyword()) :: non_neg_integer()
  def close_at_boot(opts \\ []) do
    if Keyword.get(opts, :enabled, Application.get_env(:symphony_elixir, :close_unended_runs, true)),
      do: close_unended(),
      else: 0
  end

  @doc """
  Records the `run.ended` of every run the store holds that started and never ended, as the module
  doc says, at the end `open/1` gives it. Returns how many it closed. A store that can't be read
  closes none. `opts[:read]` reads the store's events (`RunStore.list_all_ticket_events/1`, the
  default).
  """
  @spec close_unended(keyword()) :: non_neg_integer()
  def close_unended(opts \\ []) do
    read = Keyword.get(opts, :read, &RunStore.list_all_ticket_events/1)

    case read.(types: @activity_types) do
      events when is_list(events) ->
        closed =
          events
          |> Enum.filter(&is_binary(&1.issue_id))
          |> Enum.group_by(& &1.issue_id)
          |> Enum.flat_map(fn {_issue_id, ticket_events} -> ticket_events |> Enum.sort_by(&sort_key/1) |> open() end)
          |> Enum.map(fn {started, ended_at} -> close(started, ended_at) end)

        if closed != [], do: Logger.warning("Closed #{length(closed)} run(s) that ended without a recorded end")
        length(closed)

      {:error, reason} ->
        Logger.warning("Failed to read the runs that ended without a recorded end: #{inspect(reason)}")
        0
    end
  end

  defp sort_key(%Event{at: at, seq: seq}), do: {DateTime.to_unix(at, :microsecond), seq}

  defp close(%Event{repo_key: repo_key, issue_id: issue_id, payload: %{run_id: run_id}} = started, ended_at),
    do: TicketSignals.record_event(repo_key, issue_id, "run.ended", end_payload(started, ended_at), run_id: run_id, at: ended_at)

  @doc """
  The `run.ended` payload of the run `started` (its `run.started`) closed at `ended_at` without its
  end: its run id, kind, number, model and effort, the exit `unrecorded_exit/0`, the time from its
  start to `ended_at` and `counted: false`, since the run's attempt never ended on its own.
  """
  @spec end_payload(Event.t(), DateTime.t()) :: map()
  def end_payload(%Event{payload: payload, at: started_at}, %DateTime{} = ended_at) do
    %{
      run_id: Map.get(payload, :run_id),
      run_kind: Map.get(payload, :run_kind),
      run_number: Map.get(payload, :run_number),
      model: Map.get(payload, :model),
      effort: Map.get(payload, :effort),
      exit: @exit,
      duration_ms: max(DateTime.diff(ended_at, started_at, :millisecond), 0),
      counted: false
    }
  end
end
