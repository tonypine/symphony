defmodule SymphonyElixir.Inbox.FromRecord do
  @moduledoc """
  What waits on the Director, built from the tickets' records (`SymphonyElixir.TicketState`) and the
  orchestrator snapshot instead of Linear: the same items `SymphonyElixir.Inbox.items/2` returns,
  without the `references` and `context` `SymphonyElixir.Inbox.References` reads from Linear.

  Each record gives, in this order of precedence:

  - a plan in `Plan Review` with its captured brief: one `:plan` item (`Item.from_plan_brief/2`),
    whose open choices are its open Questions;
  - otherwise one `:action` item per open Question (`Item.from_question/2`), oldest first;
  - otherwise one `:blocked` item when its pause has a reason the Director may release
    (`Item.from_pause/2`).

  The quality gate's holds and skips in the snapshot add a `:clarify` item each
  (`Item.from_quality_gate/1`) for a ticket nothing else lists. As `Inbox.items/2` does, an item of a
  running ticket goes, so does one whose ticket the orchestrator saw leave the state it was listed
  in (a `:blocked` one stays: the pause is what waits), each takes the state the orchestrator saw,
  and the list is sorted oldest first, an item with no known wait last.

  Nothing serves it yet: the Inbox still reads Linear.
  """

  alias SymphonyElixir.{Config, PlanReview, TicketState}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Inbox.Item

  @typedoc "`:settings_fun`: a repo key's settings (default `Config.settings_for_repo!/1`)."
  @type opt :: {:settings_fun, (String.t() -> Schema.t())}

  @doc "The items of `records` and `snapshot` (see the moduledoc)."
  @spec items([map()], map(), [opt()]) :: [Item.t()]
  def items(records, snapshot, opts \\ []) when is_list(records) and is_map(snapshot) do
    settings_fun = Keyword.get(opts, :settings_fun, &Config.settings_for_repo!/1)
    running_ids = snapshot |> Map.get(:running, []) |> MapSet.new(& &1.issue_id)
    watched_states = snapshot |> Map.get(:watching, []) |> Map.new(&{&1.issue_id, &1.state})

    records
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.filter(&is_binary(&1.issue_id))
    |> Enum.flat_map(&record_items(&1, settings_fun))
    |> Enum.reject(&(MapSet.member?(running_ids, &1.issue_id) or left_review?(&1, watched_states, settings_fun)))
    |> Enum.map(&%{&1 | state: Map.get(watched_states, &1.issue_id, &1.state)})
    |> with_clarify(snapshot)
    |> Enum.sort_by(&{is_nil(&1.waiting_since), sort_key(&1.waiting_since), &1.identifier || ""})
  end

  defp record_items(record, settings_fun) do
    case Item.from_plan_brief(record, settings_fun.(record.repo_key)) do
      %{} = plan -> [plan]
      nil -> questions_or_pause(record)
    end
  end

  defp questions_or_pause(record) do
    case Enum.filter(record.questions, &(&1.state == :open)) do
      [] -> List.wrap(Item.from_pause(record, record.pause))
      open -> Enum.map(open, &Item.from_question(record, &1))
    end
  end

  defp with_clarify(items, snapshot) do
    listed = MapSet.new(items, & &1.issue_id)

    clarify =
      (Map.get(snapshot, :awaiting_clarification, []) ++ Map.get(snapshot, :skipped, []))
      |> Enum.filter(&is_binary(Map.get(&1, :issue_id)))
      |> Enum.uniq_by(& &1.issue_id)
      |> Enum.reject(&MapSet.member?(listed, &1.issue_id))
      |> Enum.map(&Item.from_quality_gate/1)

    items ++ clarify
  end

  # A pause is what waits on the Director, whatever the state; a plan waits in its repo's own plan
  # review state, where the record lists it.
  defp left_review?(%{kind: :blocked}, _watched_states, _settings_fun), do: false

  defp left_review?(item, watched_states, settings_fun) do
    case Map.fetch(watched_states, item.issue_id) do
      {:ok, state} -> not (PlanReview.in_state?(state) or (item.kind == :plan and PlanReview.in_state?(state, settings_fun.(item.repo_key))))
      :error -> false
    end
  end

  defp sort_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp sort_key(_at), do: 0
end
