defmodule SymphonyElixir.Dispatch.DependsOn.Backfill do
  @moduledoc """
  The first start of the release that stores dependencies (TP-1627) turns the order Symphony itself
  recorded for open sub-tickets into stored dependencies (`depends_on` on
  `SymphonyElixir.TicketState`, `SymphonyElixir.RunStore.add_dependency/3`), so a sub-ticket that
  waited on a Linear blocker link waits on the `:depends_on` dispatch gate instead. It reads
  Symphony's events and records only, never the tracker:

    * a split's plan (`SymphonyElixir.TicketPlan.current/1` over the parent's events): each entry
      with an `identifier` and an `after` gives that sub-ticket a `:done` dependency on each sibling
      its `after` names;
    * a sub-ticket the Conductor filed from a run to do after its ticket (the parent's
      `ticket.filed` by the Conductor, `kind: follow_up`, of a ticket its record lists among its
      sub-tickets) gets a `:done` dependency on the parent.

  Only an open sub-ticket (its record's phase not terminal) is given one; a sibling already done
  gives a dependency met at once. A sub-ticket or sibling Symphony holds no record of is skipped,
  and a dependency the store refuses (a cycle) is logged. Adding a dependency that is there already
  replaces it, so a second run changes nothing; `run/1` runs once all the same, marked done with
  `SymphonyElixir.RunStore.put_marker/2`.
  """

  require Logger

  alias SymphonyElixir.Conductor.Facts
  alias SymphonyElixir.{Config, RunStore, TicketPlan, TicketState}

  @marker "depends_on_backfill_v1"

  @doc """
  Converts what the moduledoc says, once: a start that finds the marker set does nothing. Answers
  the number of dependencies stored. `opts`: `:terminal_states` (default the settings'), `:now`.
  """
  @spec run(keyword()) :: non_neg_integer()
  def run(opts \\ []) do
    case RunStore.get_marker(@marker) do
      nil ->
        stored = convert(Keyword.get_lazy(opts, :terminal_states, fn -> Config.settings!().tracker.terminal_states end))
        _ = RunStore.put_marker(@marker, Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))
        Logger.info("Stored #{stored} dependencies from the order Symphony recorded for open sub-tickets")
        stored

      _done_or_unreadable ->
        0
    end
  end

  @doc "The marker `run/1` sets once it ran."
  @spec marker() :: String.t()
  def marker, do: @marker

  defp convert(terminal_states) do
    terminal = MapSet.new(terminal_states, &normalize/1)
    records = List.wrap(with({:error, _reason} <- RunStore.list_all_ticket_states(), do: []))

    by_id =
      for record <- records, record = TicketState.normalize(record), is_binary(record.issue_id), into: %{} do
        {record.issue_id, record}
      end

    by_id
    |> Map.values()
    |> Enum.flat_map(&wanted/1)
    |> Enum.filter(fn {issue_id, _on_issue_id} -> open?(Map.get(by_id, issue_id), terminal) end)
    |> Enum.uniq()
    |> Enum.count(&store/1)
  end

  # The pairs `{sub-ticket id, id it depends on}` the parent's events name.
  defp wanted(%{sub_issues: [_ | _] = sub_issues} = parent) do
    ids =
      for %{id: id, identifier: identifier} when is_binary(id) and is_binary(identifier) <- sub_issues, into: %{} do
        {identifier, id}
      end

    events = Facts.events(parent.issue_id)
    planned(TicketPlan.current(events), ids) ++ filed_after(events, parent.issue_id, ids)
  end

  defp wanted(_parent), do: []

  defp planned(%{sub_tickets: [_ | _] = entries}, ids) do
    by_key =
      for %{key: key, identifier: identifier} when is_binary(identifier) <- entries, into: %{} do
        {key, identifier}
      end

    for %{identifier: identifier, after: [_ | _] = waits} <- entries,
        id = Map.get(ids, identifier),
        key <- waits,
        on = Map.get(ids, Map.get(by_key, key)),
        is_binary(id) and is_binary(on),
        do: {id, on}
  end

  defp planned(_plan, _ids), do: []

  defp filed_after(events, parent_id, ids) do
    for %{type: "ticket.filed", payload: %{by: "conductor", kind: "follow_up", identifier: identifier}} <- events,
        id = Map.get(ids, identifier),
        is_binary(id),
        do: {id, parent_id}
  end

  defp open?(%{phase: phase}, terminal) when is_binary(phase), do: not MapSet.member?(terminal, normalize(phase))
  defp open?(_record, _terminal), do: false

  defp store({issue_id, on_issue_id}) do
    case RunStore.add_dependency(issue_id, on_issue_id, :done) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("Could not store the dependency of issue_id=#{issue_id} on issue_id=#{on_issue_id}: #{inspect(reason)}")
        false
    end
  end

  defp normalize(state), do: state |> to_string() |> String.trim() |> String.downcase()
end
