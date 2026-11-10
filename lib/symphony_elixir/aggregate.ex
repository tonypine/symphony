defmodule SymphonyElixir.Aggregate do
  @moduledoc """
  One aggregation read by period, unit, repository and epic, for the Insights pages (Quality, Usage
  and Shipped): `GET /api/v1/aggregate` (`SymphonyElixirWeb.AggregateController`,
  `docs/control-api.md`).

  Each series is bucketed by `unit` at UTC boundaries (`30m`, `1h` and `6h` from midnight, `day` at
  midnight, `week` from Monday's midnight), every bucket of the period present, empty ones at zero:

  - `tokens`: the run records' tokens (the run's and its reviewer's), at the run's start, by
    provider: the numbers `GET /api/v1/history` gives per day.
  - `time_by_stage`: the time tickets spent in each stage (`SymphonyElixir.Lifecycle`'s stages, from
    the ledger's phase moves), in milliseconds, split across the buckets a stay overlaps.
  - `runs`: the runs started, by the status their record ends with.
  - `verdicts`: the `verdict.recorded` verdicts, by `kind:outcome` (`code_review:approve`).
  - `shipped`: the tickets merged (Symphony noted their `issue_completed` event), one per ticket at
    its latest completion, by repository, with their identifiers.
  - `findings`: the `finding.recorded` findings, by class.

  `repo` keeps a repository's runs and tickets; `epic` an epic's own and its sub-tickets' (a ticket's
  epic is the parent on its record, never a parse of Linear text). It reads Symphony's store only and
  writes nothing.
  """

  alias SymphonyElixir.{History, Lifecycle, RunStore, TicketState}
  alias SymphonyElixir.TicketEvents.Event

  @series ~w(tokens time_by_stage runs verdicts shipped findings)
  @units %{"30m" => 1_800, "1h" => 3_600, "6h" => 21_600, "day" => :day, "week" => :week}
  @default_unit "day"
  @default_days 7
  @max_buckets 5_000
  @max_days 366
  # The run that carries a ticket's completion can start well before the merge (`SymphonyElixir.Shipped`).
  @lookback_days 30
  @symphony_stream "symphony"
  @run_series ~w(tokens runs shipped)
  @event_series ~w(time_by_stage verdicts findings)

  @typedoc "A bucket: its start and end, its value and that value split `by` the series' key."
  @type bucket :: %{
          start: String.t(),
          end: String.t(),
          value: non_neg_integer(),
          by: %{String.t() => non_neg_integer()}
        }

  @typedoc "A series: its total over the period, split `by` its key and by ticket identifier, and its buckets."
  @type series :: %{
          total: non_neg_integer(),
          by: %{String.t() => non_neg_integer()},
          tickets: %{String.t() => non_neg_integer()},
          buckets: [bucket()]
        }

  @doc "The series names the read knows, in the order it answers them."
  @spec series_names() :: [String.t()]
  def series_names, do: @series

  @doc "The units the read buckets by."
  @spec units() :: [String.t()]
  def units, do: ~w(30m 1h 6h day week)

  @doc """
  The aggregation `params` ask for (string keys `from`, `to`, `unit`, `repo`, `epic`, `series`).

  `from` and `to` are ISO 8601 times or dates; a date `from` starts at its midnight and a date `to`
  takes in its whole day. The period widens to whole buckets. Without them the period is the
  #{@default_days} days that end with the bucket holding now. `opts` injects the sources: `:now`,
  `:runs_started_on` (a UTC `Date` → runs function), `:events` (every ticket's events),
  `:ticket_states` (the ticket records) and `:lifecycle_facts` (`SymphonyElixir.Lifecycle.facts/1`).
  """
  @spec read(map(), keyword()) :: {:ok, map()} | {:error, {:invalid, String.t()}}
  def read(params, opts \\ []) when is_map(params) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, unit} <- unit(params["unit"]),
         {:ok, series} <- series(params["series"]),
         {:ok, starts} <- period(params["from"], params["to"], unit, now) do
      scope = %{repo: blank_to_nil(params["repo"]), epic: blank_to_nil(params["epic"])}
      sources = sources(series, starts, scope, Keyword.put(opts, :now, now))
      period_end = next(List.last(starts), unit)

      {:ok,
       %{
         generated_at: iso8601(now),
         from: iso8601(List.first(starts)),
         to: iso8601(period_end),
         unit: unit,
         repo: scope.repo,
         epic: scope.epic,
         series: Map.new(series, &{&1, &1 |> data(sources) |> bucketize(starts, unit) |> put_tickets(&1)})
       }}
    end
  end

  # -- Parameters ------------------------------------------------------------------------------

  defp unit(value) when value in [nil, ""], do: {:ok, @default_unit}
  defp unit(value) when is_map_key(@units, value), do: {:ok, value}
  defp unit(_value), do: {:error, {:invalid, "unit must be one of #{Enum.join(units(), ", ")}"}}

  defp series(value) when value in [nil, ""], do: {:ok, @series}

  defp series(value) when is_binary(value) do
    names = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case Enum.reject(names, &(&1 in @series)) do
      [] when names != [] -> {:ok, Enum.filter(@series, &(&1 in names))}
      [] -> {:ok, @series}
      unknown -> {:error, {:invalid, "Unknown series: #{Enum.join(unknown, ", ")}"}}
    end
  end

  defp series(_value), do: {:error, {:invalid, "series must be a comma-separated list"}}

  defp period(from, to, unit, now) do
    with {:ok, to} <- time(to, "to", :end),
         {:ok, from} <- time(from, "from", :start) do
      to = to || next(floor_to(now, unit), unit)
      from = from || DateTime.add(to, -@default_days, :day)

      cond do
        DateTime.compare(from, to) != :lt -> {:error, {:invalid, "from must be before to"}}
        DateTime.diff(to, from, :day) > @max_days -> {:error, {:invalid, "the period is at most #{@max_days} days"}}
        true -> starts(floor_to(from, unit), to, unit)
      end
    end
  end

  defp time(value, _name, _edge) when value in [nil, ""], do: {:ok, nil}

  defp time(value, name, edge) when is_binary(value) do
    case {DateTime.from_iso8601(value), Date.from_iso8601(value)} do
      {{:ok, at, _offset}, _date} -> {:ok, at}
      {_time, {:ok, date}} when edge == :start -> {:ok, midnight(date)}
      {_time, {:ok, date}} -> {:ok, date |> Date.add(1) |> midnight()}
      _invalid -> {:error, {:invalid, "#{name} must be an ISO 8601 time or date"}}
    end
  end

  defp time(_value, name, _edge), do: {:error, {:invalid, "#{name} must be an ISO 8601 time or date"}}

  defp starts(first, to, unit) do
    starts = first |> Stream.iterate(&next(&1, unit)) |> Stream.take_while(&(DateTime.compare(&1, to) == :lt)) |> Enum.take(@max_buckets + 1)

    if length(starts) > @max_buckets,
      do: {:error, {:invalid, "the period holds more than #{@max_buckets} buckets of #{unit}"}},
      else: {:ok, starts}
  end

  # -- Buckets ---------------------------------------------------------------------------------

  defp floor_to(%DateTime{} = at, unit) do
    at = DateTime.shift_zone!(at, "Etc/UTC")

    case Map.fetch!(@units, unit) do
      :day -> midnight(DateTime.to_date(at))
      :week -> at |> DateTime.to_date() |> Date.beginning_of_week() |> midnight()
      seconds -> at |> DateTime.to_unix() |> div(seconds) |> Kernel.*(seconds) |> DateTime.from_unix!() |> usec()
    end
  end

  defp next(start, unit) do
    case Map.fetch!(@units, unit) do
      :day -> DateTime.add(start, 1, :day)
      :week -> DateTime.add(start, 7, :day)
      seconds -> DateTime.add(start, seconds, :second)
    end
  end

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
  defp usec(at), do: %{at | microsecond: {0, 6}}

  # Points (`at`) fall in the bucket holding them; spans (`from`, `to`) give each bucket they overlap
  # the milliseconds they spend in it. Data outside the period count nowhere.
  defp bucketize(data, starts, unit) do
    index = starts |> Enum.with_index() |> Map.new(fn {start, i} -> {DateTime.to_unix(start, :microsecond), i} end)
    period = {List.first(starts), next(List.last(starts), unit)}

    pieces = Enum.flat_map(data, &pieces(&1, index, period, unit))
    by_bucket = Enum.group_by(pieces, & &1.bucket)

    buckets =
      starts
      |> Enum.with_index()
      |> Enum.map(fn {start, i} ->
        in_bucket = Map.get(by_bucket, i, [])

        %{
          start: iso8601(start),
          end: iso8601(next(start, unit)),
          value: sum(in_bucket),
          by: sum_by(in_bucket, & &1.key),
          pieces: in_bucket
        }
      end)

    %{
      total: sum(pieces),
      by: sum_by(pieces, & &1.key),
      tickets: pieces |> Enum.filter(&is_binary(&1.ticket)) |> sum_by(& &1.ticket),
      buckets: buckets
    }
  end

  defp pieces(%{at: at} = datum, index, {from, to}, unit) do
    if in_period?(at, from, to),
      do: [%{bucket: bucket_index(at, index, unit), value: datum.value, key: datum.key, ticket: datum.ticket}],
      else: []
  end

  defp pieces(%{from: span_from, to: span_to} = datum, index, {from, to}, unit) do
    span_from = latest(span_from, from)
    span_to = earliest(span_to, to)

    span_from
    |> floor_to(unit)
    |> Stream.iterate(&next(&1, unit))
    |> Stream.take_while(&(DateTime.compare(&1, span_to) == :lt))
    |> Enum.map(fn start ->
      overlap = DateTime.diff(earliest(next(start, unit), span_to), latest(start, span_from), :millisecond)
      %{bucket: Map.fetch!(index, DateTime.to_unix(start, :microsecond)), value: overlap, key: datum.key, ticket: datum.ticket}
    end)
  end

  defp bucket_index(at, index, unit), do: Map.fetch!(index, at |> floor_to(unit) |> DateTime.to_unix(:microsecond))

  defp in_period?(at, from, to), do: DateTime.compare(at, from) != :lt and DateTime.compare(at, to) == :lt

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp sum(pieces), do: pieces |> Enum.map(& &1.value) |> Enum.sum()
  defp sum_by(pieces, key), do: pieces |> Enum.group_by(key, & &1.value) |> Map.new(fn {k, values} -> {k, Enum.sum(values)} end)

  # A shipped bucket names its tickets too, an empty one none; no other series lists them.
  defp put_tickets(series, "shipped"), do: %{series | buckets: Enum.map(series.buckets, &Map.put(Map.delete(&1, :pieces), :tickets, bucket_tickets(&1.pieces)))}
  defp put_tickets(series, _name), do: %{series | buckets: Enum.map(series.buckets, &Map.delete(&1, :pieces))}

  defp bucket_tickets(pieces), do: pieces |> Enum.map(& &1.ticket) |> Enum.reject(&is_nil/1) |> Enum.sort()

  # -- Sources ---------------------------------------------------------------------------------

  defp sources(series, [first | _], scope, opts) do
    now = Keyword.fetch!(opts, :now)
    records = opts |> Keyword.get_lazy(:ticket_states, &RunStore.list_all_ticket_states/0) |> list_or_empty() |> Enum.map(&TicketState.normalize/1)
    records = Map.new(records, &{&1.issue_id, &1})

    %{
      scope: scope,
      records: records,
      runs: if(Enum.any?(series, &(&1 in @run_series)), do: runs(first, now, records, scope, opts), else: []),
      events: if(Enum.any?(series, &(&1 in @event_series)), do: events(records, scope, opts), else: %{}),
      lifecycle_facts: if("time_by_stage" in series, do: Keyword.get_lazy(opts, :lifecycle_facts, fn -> Lifecycle.facts(now) end))
    }
  end

  # The runs started from the lookback before the period to today, in scope.
  defp runs(first, now, records, scope, opts) do
    runs_started_on = Keyword.get(opts, :runs_started_on, &RunStore.list_runs_started_on/1)

    first
    |> DateTime.to_date()
    |> Date.add(-@lookback_days)
    |> Date.range(DateTime.to_date(now))
    |> Enum.flat_map(&list_or_empty(runs_started_on.(&1)))
    |> Enum.filter(&(match?(%DateTime{}, Map.get(&1, :started_at)) and run_in_scope?(&1, records, scope)))
  end

  # Every ticket's events, oldest first, by ticket, for the tickets in scope. Symphony's own stream
  # is no ticket's.
  defp events(records, scope, opts) do
    opts
    |> Keyword.get_lazy(:events, fn -> RunStore.list_all_ticket_events([]) end)
    |> list_or_empty()
    |> Enum.reject(&(&1.issue_id == @symphony_stream))
    |> Enum.filter(&ticket_in_scope?(&1.repo_key, Map.get(records, &1.issue_id), scope))
    |> Enum.sort_by(&{DateTime.to_unix(&1.at, :microsecond), &1.seq || 0})
    |> Enum.group_by(& &1.issue_id)
  end

  defp run_in_scope?(run, records, scope) do
    record = Map.get(records, Map.get(run, :issue_id))
    (is_nil(scope.repo) or Map.get(run, :repo_key) == scope.repo) and in_epic?(record, Map.get(run, :issue_identifier), scope.epic)
  end

  defp ticket_in_scope?(repo_key, record, scope) do
    (is_nil(scope.repo) or (repo_key || (record && record.repo_key)) == scope.repo) and in_epic?(record, nil, scope.epic)
  end

  defp in_epic?(_record, _identifier, nil), do: true
  defp in_epic?(nil, identifier, epic), do: identifier == epic
  defp in_epic?(record, _identifier, epic), do: record.issue_identifier == epic or match?(%{identifier: ^epic}, record.parent)

  # -- Series ----------------------------------------------------------------------------------

  defp data("tokens", %{runs: runs}) do
    for run <- runs, do: %{at: run.started_at, value: run_tokens(run), key: History.provider(run), ticket: Map.get(run, :issue_identifier)}
  end

  defp data("runs", %{runs: runs}) do
    for run <- runs, do: %{at: run.started_at, value: 1, key: string(Map.get(run, :status)) || "unknown", ticket: Map.get(run, :issue_identifier)}
  end

  defp data("shipped", %{runs: runs}) do
    runs
    |> Enum.filter(&(is_binary(Map.get(&1, :issue_id)) and match?(%DateTime{}, Map.get(&1, :issue_completed_notified_at))))
    |> Enum.group_by(&{Map.get(&1, :repo_key), &1.issue_id})
    |> Enum.map(fn {{repo_key, _issue_id}, ticket_runs} ->
      run = Enum.max_by(ticket_runs, & &1.issue_completed_notified_at, DateTime)
      %{at: run.issue_completed_notified_at, value: 1, key: repo_key || "unknown", ticket: Map.get(run, :issue_identifier)}
    end)
  end

  defp data("verdicts", %{events: events, records: records}) do
    for {issue_id, ticket_events} <- events,
        %{kind: kind, outcome: outcome, recorded_at: at} <- TicketState.verdicts_in(ticket_events),
        do: %{at: at, value: 1, key: "#{kind}:#{outcome}", ticket: identifier(records, issue_id)}
  end

  defp data("findings", %{events: events, records: records}) do
    for {issue_id, ticket_events} <- events,
        %Event{type: "finding.recorded", payload: payload, at: at} <- ticket_events,
        do: %{at: at, value: 1, key: string(Map.get(payload, :class)) || "unknown", ticket: identifier(records, issue_id)}
  end

  defp data("time_by_stage", %{events: events, records: records, lifecycle_facts: facts}) do
    for {issue_id, ticket_events} <- events,
        %{stage: stage, from: from, to: to} <- Lifecycle.stage_spans(ticket_events, facts),
        do: %{from: from, to: to, key: stage, ticket: identifier(records, issue_id)}
  end

  defp identifier(records, issue_id) do
    case Map.get(records, issue_id) do
      %{issue_identifier: identifier} -> identifier
      nil -> nil
    end
  end

  defp run_tokens(run), do: total_tokens(Map.get(run, :tokens)) + total_tokens(Map.get(run, :reviewer_tokens))

  defp total_tokens(%{total_tokens: tokens}) when is_integer(tokens), do: tokens
  defp total_tokens(_tokens), do: 0

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_error), do: []

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp string(_value), do: nil

  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp blank_to_nil(_value), do: nil

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
