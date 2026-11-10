defmodule SymphonyElixir.TicketList do
  @moduledoc """
  The tickets a view selects (`GET /api/v1/tickets`, `SymphonyElixir.Views`): every ticket Symphony
  keeps a record of, the ones its filters let through, sorted by its sort, each with the columns it
  asks for (`SymphonyElixir.TicketColumns`).

  A ticket is a record with an identifier that no webhook removed and that Linear still has
  (`removed_at` and `not_found_at` unset). The filters match as the Journal's and the aggregation
  read's do: `epic` keeps the epic and the tickets whose record names it as parent, `repo` a
  repository's tickets; `repo`, `phase` and `label` match in any case; `since` keeps the tickets whose
  record was written after it. The situations are computed (`SymphonyElixir.Situation.read/3`) only
  when the view shows, filters or sorts by one. A sort puts the tickets without a value last, either
  way, and breaks ties by identifier. It reads Symphony's store only and writes nothing.
  """

  alias SymphonyElixir.{RunStore, Situation, TicketColumns, TicketState, Views}

  @doc """
  The rows `spec` selects, each the ticket's `issue_id` and the spec's columns by name, times in
  ISO 8601. `opts` injects `:records` (the ticket records; default the store's) and `:live`
  (`SymphonyElixir.Situation.live_facts/2`, for the situations; default none running).
  """
  @spec select(Views.spec(), keyword()) :: [%{String.t() => term()}]
  def select(spec, opts \\ []) do
    records =
      opts
      |> Keyword.get_lazy(:records, &RunStore.list_all_ticket_states/0)
      |> List.wrap()
      |> Enum.map(&TicketState.normalize/1)

    tickets = Enum.filter(records, &ticket?/1)
    {situation_filters, filters} = Enum.split_with(spec.filters, &(&1.column == "situation"))
    needs_situation? = situation_filters != [] or TicketColumns.situation?([spec.sort.column | spec.columns])
    live = Keyword.get_lazy(opts, :live, fn -> Situation.live_facts(%{}) end)

    tickets
    |> Enum.map(&{&1, TicketColumns.values(&1)})
    |> Enum.filter(fn {_record, values} -> Enum.all?(filters, &matches?(&1, values)) end)
    |> Enum.map(fn {record, values} -> {record, with_situation(values, record, needs_situation?, live, records)} end)
    |> Enum.filter(fn {_record, values} -> Enum.all?(situation_filters, &matches?(&1, values)) end)
    |> sort(spec.sort)
    |> Enum.map(fn {record, values} -> row(record, values, spec.columns) end)
  end

  defp ticket?(record), do: is_binary(record.issue_identifier) and is_nil(record.removed_at) and is_nil(record.not_found_at)

  defp with_situation(values, _record, false, _live, _records), do: values

  defp with_situation(values, record, true, live, records),
    do: Map.merge(values, record |> Situation.read(live, records) |> TicketColumns.situation_values())

  # -- Filters ---------------------------------------------------------------------------------

  defp matches?(%{column: name, value: value}, values) do
    {column, match} = TicketColumns.filter(name)
    hit?(match, Map.get(values, column), value, values)
  end

  defp hit?(:after, %DateTime{} = at, since, _values) do
    {:ok, since, _offset} = DateTime.from_iso8601(since)
    DateTime.compare(at, since) == :gt
  end

  defp hit?(:after, nil, _since, _values), do: false
  defp hit?(:contains, labels, wanted, _values), do: Enum.any?(labels, &(fold(&1) in Enum.map(wanted, fn label -> fold(label) end)))
  defp hit?(:epic, epic, wanted, values), do: epic in wanted or values["identifier"] in wanted
  defp hit?(:any, value, wanted, _values) when is_integer(value), do: value in wanted
  defp hit?(:any, value, wanted, _values) when is_binary(value), do: fold(value) in Enum.map(wanted, &fold/1)
  defp hit?(:any, nil, _wanted, _values), do: false

  defp fold(value), do: String.downcase(value)

  # -- Sort ------------------------------------------------------------------------------------

  defp sort(tickets, %{column: column, direction: direction}) do
    type = TicketColumns.type(column)
    tickets = Enum.sort_by(tickets, fn {_record, values} -> key("identifier", values["identifier"]) end)
    {valued, missing} = Enum.split_with(tickets, fn {_record, values} -> present?(values[column]) end)
    Enum.sort_by(valued, fn {_record, values} -> key(type, values[column]) end, sort_order(direction)) ++ missing
  end

  defp sort_order("asc"), do: :asc
  defp sort_order("desc"), do: :desc

  defp present?(nil), do: false
  defp present?([]), do: false
  defp present?(_value), do: true

  # An identifier sorts by its team key, then its number: TP-9 before TP-10.
  defp key("identifier", identifier) do
    case Regex.run(~r/^(.*)-(\d+)$/, identifier) do
      [_whole, team, number] -> {team, String.to_integer(number)}
      nil -> {identifier, 0}
    end
  end

  defp key("time", %DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp key("list", values), do: values |> Enum.map(&fold/1) |> Enum.sort()
  defp key("integer", value), do: value
  defp key(_string, value), do: fold(value)

  # -- Rows ------------------------------------------------------------------------------------

  defp row(record, values, columns), do: Map.new(columns, &{&1, json(values[&1])}) |> Map.put("issue_id", record.issue_id)

  defp json(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp json(value), do: value
end
