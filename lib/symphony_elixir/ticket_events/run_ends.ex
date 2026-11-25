defmodule SymphonyElixir.TicketEvents.RunEnds do
  @moduledoc """
  The runs a ticket's record started and never ended (a `run.started` with no `run.ended` for its
  run id), and their close.

  A run's end is written when its task exits or when Symphony stops it. A run Symphony was holding
  when it quit (to install an update, say, while the run waited between turns for it) gets neither:
  the shutdown never delivers the task's exit, and the next boot only closes its row in the run
  list. The row keeps what Symphony last held for the run while it worked (its tokens and its last
  agent event, written as the run reports them). `close_unended/1` runs once at each boot, before
  the orchestrator holds any run, and records every such run's `run.ended` at the time `open/2`
  gives it, with the tokens its row kept (`kept/2`), the exit
  #{inspect("ended; no end was recorded")} and `counted: false`: the run's attempt never ended on
  its own, so it counts toward no loop limit, while its tokens count in the ticket's budget. A run
  with no row keeps no tokens, never a made-up count. The event is idempotent by run id, so a run is
  closed once.

  The events feed reads `open/2` and `end_payload/3` the same way for a run the orchestrator does
  not hold (`SymphonyElixirWeb.Presenter.ticket_timeline_json/5`), so the feed and the boot's close
  give a run the same end.
  """

  require Logger

  alias SymphonyElixir.{RunStore, TicketSignals}
  alias SymphonyElixir.TicketEvents.Event

  @exit "ended; no end was recorded"
  @activity_types ["run.started", "run.ended", "step.started", "step.completed"]

  @doc "The exit a run closed without its end reads with."
  @spec unrecorded_exit() :: String.t()
  def unrecorded_exit, do: @exit

  @doc "The event types `open/2` reads a run's end from: what a reader of it must hold."
  @spec activity_types() :: [String.t()]
  def activity_types, do: @activity_types

  @doc """
  The runs of one ticket's `events` (oldest first) with a `run.started` and no `run.ended`, oldest
  first, each as `{started, ended_at}`. `ended_at` is the run's own last activity: the latest of its
  own last event of `activity_types/0` and the last agent event its run list row kept (`kept`, by
  run id, as `kept/2` reads it). A run with no activity after its start ends at the next
  `run.started` of the ticket that is not a Conductor turn (a ticket holds one such run at a time,
  while Conductor turns run beside it, so a Conductor turn never gives another run's end), else at
  its start. Events of other types are ignored, so any read holding those types gives the same ends.
  """
  @spec open([Event.t()], %{optional(String.t()) => kept()}) :: [{Event.t(), DateTime.t()}]
  def open(events, kept \\ %{}) when is_list(events) and is_map(kept) do
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
      run_id = started.payload.run_id
      own = latest([Map.get(last_seen, run_id), kept |> Map.get(run_id, %{}) |> Map.get(:last_event_at)])

      ended_at =
        if own && DateTime.compare(own, started.at) == :gt,
          do: own,
          else: next_start(starts, index) || started.at

      {started, ended_at}
    end)
  end

  defp latest(times) do
    times
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp next_start(starts, index) do
    starts
    |> Enum.drop(index + 1)
    |> Enum.find_value(fn %Event{payload: payload, at: at} -> if Map.get(payload, :run_kind) != "conductor", do: at end)
  end

  @typedoc "What a run's row in the run list kept for it: its tokens and its last agent event, nil when unknown."
  @type kept :: %{tokens: non_neg_integer() | nil, last_event_at: DateTime.t() | nil}

  @doc """
  What the run list kept for each run of issue `issue_id` in `repo_key`, by run id: the total tokens
  Symphony last held for the run and the time of its last agent event, each nil when the row has
  none. A store that can't be read keeps nothing. `read` reads the rows
  (`RunStore.list_issue_runs/2`, the default).
  """
  @spec kept(String.t() | nil, String.t(), (String.t() | nil, String.t() -> [map()] | {:error, term()})) ::
          %{optional(String.t()) => kept()}
  def kept(repo_key, issue_id, read \\ &RunStore.list_issue_runs/2) do
    case read.(repo_key, issue_id) do
      records when is_list(records) ->
        for %{run_id: run_id} = record <- records, is_binary(run_id), into: %{} do
          {run_id, %{tokens: kept_tokens(Map.get(record, :tokens)), last_event_at: kept_time(Map.get(record, :last_event_at))}}
        end

      _error ->
        %{}
    end
  end

  defp kept_tokens(%{} = tokens) do
    case Map.get(tokens, :total_tokens, Map.get(tokens, "total_tokens")) do
      count when is_integer(count) and count >= 0 -> count
      _other -> nil
    end
  end

  defp kept_tokens(_tokens), do: nil

  defp kept_time(%DateTime{} = at), do: at

  defp kept_time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp kept_time(_at), do: nil

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
  doc says, at the end `open/2` gives it and with the tokens its row kept. Returns how many it
  closed. A store that can't be read closes none. `opts[:read]` reads the store's events
  (`RunStore.list_all_ticket_events/1`, the default); `opts[:runs]` reads a ticket's rows in the
  run list (`RunStore.list_issue_runs/2`, the default), only for a ticket with a run to close.
  """
  @spec close_unended(keyword()) :: non_neg_integer()
  def close_unended(opts \\ []) do
    read = Keyword.get(opts, :read, &RunStore.list_all_ticket_events/1)
    runs = Keyword.get(opts, :runs, &RunStore.list_issue_runs/2)

    case read.(types: @activity_types) do
      events when is_list(events) ->
        closed =
          events
          |> Enum.filter(&is_binary(&1.issue_id))
          |> Enum.group_by(& &1.issue_id)
          |> Enum.flat_map(fn {issue_id, ticket_events} ->
            close_ticket(issue_id, Enum.sort_by(ticket_events, &sort_key/1), runs)
          end)

        if closed != [], do: Logger.warning("Closed #{length(closed)} run(s) that ended without a recorded end")
        length(closed)

      {:error, reason} ->
        Logger.warning("Failed to read the runs that ended without a recorded end: #{inspect(reason)}")
        0
    end
  end

  defp close_ticket(issue_id, events, runs) do
    case open(events) do
      [] ->
        []

      [{%Event{repo_key: repo_key}, _ended_at} | _rest] ->
        kept = kept(repo_key, issue_id, runs)

        events
        |> open(kept)
        |> Enum.map(fn {started, ended_at} -> close(started, ended_at, Map.get(kept, started.payload.run_id)) end)
    end
  end

  defp sort_key(%Event{at: at, seq: seq}), do: {DateTime.to_unix(at, :microsecond), seq}

  defp close(%Event{repo_key: repo_key, issue_id: issue_id, payload: %{run_id: run_id}} = started, ended_at, kept) do
    payload = end_payload(started, ended_at, kept)
    TicketSignals.record_event(repo_key, issue_id, "run.ended", payload, run_id: run_id, at: ended_at)
  end

  @doc """
  The `run.ended` payload of the run `started` (its `run.started`) closed at `ended_at` without its
  end: its run id, kind, number, model and effort, the exit `unrecorded_exit/0`, the time from its
  start to `ended_at`, the tokens its row in the run list kept (`kept`, from `kept/2`; left out
  when it kept none) and `counted: false`, since the run's attempt never ended on its own.
  """
  @spec end_payload(Event.t(), DateTime.t(), kept() | nil) :: map()
  def end_payload(%Event{payload: payload, at: started_at}, %DateTime{} = ended_at, kept \\ nil) do
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
    |> put_tokens(kept)
  end

  defp put_tokens(payload, %{tokens: tokens}) when is_integer(tokens), do: Map.put(payload, :tokens, tokens)
  defp put_tokens(payload, _kept), do: payload
end
