defmodule SymphonyElixir.Initiatives.Initiative do
  @moduledoc """
  One plan ticket followed to done, for the Mac app's Initiatives (`GET /api/v1/initiatives`).

  `from_node/4` reads what Linear said about the plan ticket on Symphony's poll: its group (`active`,
  `in_review` or `done`), its sub-tickets in landing order and its `Final verification:` sub-ticket.
  `live/2` adds what each open sub-ticket waits on from what Symphony knows locally at GET time (the
  running tickets, the Inbox, the epic lanes), so a GET never reads Linear:

  - `done`: the sub-ticket is completed;
  - `working`: an agent, QA pass or landing runs it;
  - `you`: it waits on the Director (an Inbox item, a review state, or Backlog: not promoted yet);
  - `blocker`: an open sub-ticket or ticket it is blocked by;
  - `ci`: a machine-owned phase (Code Review, QA, Merging, CI Fix) with nothing running yet;
  - `slot`: it can run and waits for a free slot.

  Landing order is blocked-by order between the sub-tickets, then creation order. Canceled
  sub-tickets are left out.
  """

  alias SymphonyElixir.HumanReview

  @final_verification_prefix "final verification:"
  @machine_states MapSet.new(["code review", "qa", "merging", "ci fix", "epic review"])
  @stages ~w(done working you queued blocked)

  @type sub_ticket :: %{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          url: String.t() | nil,
          state: String.t() | nil,
          state_type: String.t() | nil,
          created_at: String.t() | nil,
          blocked_by: [%{identifier: String.t() | nil, state: String.t() | nil, open: boolean()}]
        }

  @type t :: %{
          id: String.t(),
          identifier: String.t() | nil,
          title: String.t() | nil,
          url: String.t() | nil,
          state: String.t() | nil,
          repo_key: String.t(),
          group: String.t(),
          completed_at: String.t() | nil,
          sub_tickets: [sub_ticket()],
          final_verification: sub_ticket() | nil
        }

  @typedoc "What Symphony knows locally at GET time: running and waiting-on-you issue ids, the human-gated states."
  @type live :: %{
          running: MapSet.t(String.t()),
          you: MapSet.t(String.t()),
          settings: term()
        }

  @doc "The stages counted on each initiative, in the bar's order."
  @spec stages() :: [String.t()]
  def stages, do: @stages

  @doc """
  The initiative a plan ticket's Linear node describes, or nil for one outside the three groups (in
  Backlog, canceled, or done more than `recent_days` before `now`).
  """
  @spec from_node(map(), String.t(), term(), DateTime.t()) :: t() | nil
  def from_node(%{"id" => id} = node, repo_key, settings, %DateTime{} = now) when is_binary(id) do
    case group(node, settings, now) do
      nil ->
        nil

      group ->
        children =
          node
          |> get_in(["children", "nodes"])
          |> List.wrap()
          |> Enum.map(&sub_ticket/1)
          |> Enum.reject(&(&1.state_type == "canceled"))

        {final, parts} = Enum.split_with(children, &final_verification?/1)

        %{
          id: id,
          identifier: node["identifier"],
          title: node["title"],
          url: node["url"],
          state: get_in(node, ["state", "name"]),
          repo_key: repo_key,
          group: group,
          completed_at: node["completedAt"],
          sub_tickets: landing_order(parts),
          final_verification: List.first(final)
        }
    end
  end

  def from_node(_node, _repo_key, _settings, _now), do: nil

  @recent_days 7

  defp group(node, settings, now) do
    state = get_in(node, ["state", "name"])

    case get_in(node, ["state", "type"]) do
      "completed" -> if recent?(node["completedAt"], now), do: "done"
      type when type in ["canceled", "backlog", "triage"] -> nil
      _type -> if in_review?(state, settings), do: "in_review", else: "active"
    end
  end

  defp recent?(completed_at, now) when is_binary(completed_at) do
    case DateTime.from_iso8601(completed_at) do
      {:ok, at, _offset} -> DateTime.diff(now, at, :second) <= @recent_days * 86_400
      _error -> false
    end
  end

  defp recent?(_completed_at, _now), do: false

  defp in_review?(state, settings) do
    HumanReview.review_state?(state, settings) or HumanReview.plan_review_state?(state, settings) or
      normalize(state) == "epic review"
  end

  defp sub_ticket(node) do
    %{
      id: node["id"],
      identifier: node["identifier"],
      title: node["title"],
      url: node["url"],
      state: get_in(node, ["state", "name"]),
      state_type: get_in(node, ["state", "type"]),
      created_at: node["createdAt"],
      blocked_by: blockers(node)
    }
  end

  defp blockers(node) do
    for %{"type" => type, "issue" => %{} = issue} <- node |> get_in(["inverseRelations", "nodes"]) |> List.wrap(),
        normalize(type) == "blocks" do
      type = get_in(issue, ["state", "type"])
      %{identifier: issue["identifier"], state: get_in(issue, ["state", "name"]), open: type not in ["completed", "canceled"]}
    end
  end

  defp final_verification?(%{title: title}) when is_binary(title),
    do: title |> String.trim_leading() |> String.downcase() |> String.starts_with?(@final_verification_prefix)

  defp final_verification?(_sub_ticket), do: false

  # Kahn's walk over the blocked-by links between siblings, taking the oldest ready ticket each step.
  # A cycle is broken by creation order.
  defp landing_order(parts) do
    parts = Enum.sort_by(parts, &{&1.created_at || "", &1.identifier || ""})
    siblings = MapSet.new(parts, & &1.identifier)

    deps =
      Map.new(parts, fn part ->
        {part.identifier, part.blocked_by |> Enum.map(& &1.identifier) |> Enum.filter(&MapSet.member?(siblings, &1)) |> MapSet.new()}
      end)

    walk(parts, deps, [])
  end

  defp walk([], _deps, acc), do: Enum.reverse(acc)

  defp walk(remaining, deps, acc) do
    next = Enum.find(remaining, &MapSet.equal?(deps[&1.identifier], MapSet.new())) || hd(remaining)
    deps = Map.new(deps, fn {identifier, blockers} -> {identifier, MapSet.delete(blockers, next.identifier)} end)
    walk(List.delete(remaining, next), deps, [next | acc])
  end

  @doc """
  The initiative with what each sub-ticket waits on, the final verification's open-ticket count, the
  counts by stage and the waiting-on-you headline, from what Symphony knows locally.
  """
  @spec live(t(), live()) :: map()
  def live(initiative, live) do
    sub_tickets = Enum.map(initiative.sub_tickets, &with_wait(&1, live))
    open = Enum.count(sub_tickets, &(&1.waits_on != "done"))

    final =
      case initiative.final_verification do
        nil -> nil
        final -> final |> with_wait(live) |> Map.put(:open_tickets, open)
      end

    counts = Map.new(@stages, &{&1, 0})
    counts = Enum.reduce(sub_tickets, counts, &Map.update!(&2, stage(&1.waits_on), fn count -> count + 1 end))

    initiative
    |> Map.merge(%{sub_tickets: sub_tickets, final_verification: final, counts: Map.put(counts, "total", length(sub_tickets))})
  end

  defp with_wait(sub_ticket, live) do
    open_blockers = for %{open: true, identifier: identifier} <- sub_ticket.blocked_by, do: identifier
    waits_on = waits_on(sub_ticket, open_blockers, live)

    sub_ticket
    |> Map.put(:waits_on, waits_on)
    |> Map.put(:waiting_for, if(waits_on == "blocker", do: open_blockers, else: []))
  end

  defp waits_on(%{state_type: "completed"}, _open_blockers, _live), do: "done"

  defp waits_on(%{id: id, state: state, state_type: type}, open_blockers, live) do
    cond do
      MapSet.member?(live.running, id) -> "working"
      MapSet.member?(live.you, id) or type in ["backlog", "triage"] -> "you"
      HumanReview.review_state?(state, live.settings) or HumanReview.plan_review_state?(state, live.settings) -> "you"
      open_blockers != [] -> "blocker"
      MapSet.member?(@machine_states, normalize(state)) -> "ci"
      true -> "slot"
    end
  end

  defp stage("done"), do: "done"
  defp stage(working) when working in ["working", "ci"], do: "working"
  defp stage("you"), do: "you"
  defp stage("blocker"), do: "blocked"
  defp stage("slot"), do: "queued"

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: nil
end
