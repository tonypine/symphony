defmodule SymphonyElixir.Connected do
  @moduledoc """
  Where a ticket Symphony tracks sits among the others, for `connected` on
  `/api/v1/:issue_identifier`: its `parent` with its sub-tickets' progress, its `sub_tickets`,
  `blocked_by`, `blocks` and `related`, in the shape of the Inbox's `context`
  (`SymphonyElixir.Inbox.References`).

  It is built from what the orchestrator already holds, so serving it reads no Linear: each poll's
  `blocked_by` and `sub_issues` (identifier and state; the poll reads no titles), and what the
  run's enrichment read once at dispatch (`linked/1`): the parent and the `blocks` and `related`
  links, with their titles.
  """

  alias SymphonyElixir.Linear.Issue

  @type ticket :: %{identifier: String.t(), title: String.t() | nil, state: String.t() | nil}

  @typedoc "The parent and its sub-tickets' state types (`completed`, `started`...) in landing order."
  @type parent :: %{
          identifier: String.t(),
          title: String.t() | nil,
          done: non_neg_integer(),
          total: non_neg_integer(),
          children: [String.t() | nil]
        }

  @type t :: %{
          parent: parent() | nil,
          sub_tickets: [ticket()],
          blocked_by: [ticket()],
          blocks: [ticket()],
          related: [ticket()]
        }

  @typedoc "What the run's enrichment read: the ticket's parent and its outward links."
  @type linked :: %{parent: parent() | nil, linked_issues: [map()]}

  @doc """
  The ticket's connections: its blockers and sub-tickets from `issue`, its parent and links from
  `linked` (the issue's own when nil).
  """
  @spec build(Issue.t() | map(), linked() | nil) :: t()
  def build(issue, linked) when is_map(issue) do
    %{parent: parent, linked_issues: linked_issues} = linked || linked(issue)

    %{
      parent: parent,
      sub_tickets: tickets(Map.get(issue, :sub_issues)),
      blocked_by: tickets(Map.get(issue, :blocked_by)),
      blocks: links(linked_issues, "blocks"),
      related: links(linked_issues, "related")
    }
  end

  @doc "What an enriched issue knows beyond the poll: its parent and its links."
  @spec linked(Issue.t() | map()) :: linked()
  def linked(issue) when is_map(issue), do: %{parent: Map.get(issue, :parent), linked_issues: List.wrap(Map.get(issue, :linked_issues))}

  @doc """
  A Linear parent node (`identifier`, `title`, `children` with `createdAt` and `state { type }`) as
  `parent()`: its sub-tickets in landing order (their creation order), canceled ones left out.
  """
  @spec parent(map() | nil) :: parent() | nil
  def parent(%{"identifier" => identifier} = node) when is_binary(identifier) do
    children =
      node
      |> get_in(["children", "nodes"])
      |> List.wrap()
      |> Enum.reject(&(get_in(&1, ["state", "type"]) == "canceled"))
      |> Enum.sort_by(&(&1["createdAt"] || ""))
      |> Enum.map(&get_in(&1, ["state", "type"]))

    %{identifier: identifier, title: node["title"], done: Enum.count(children, &(&1 == "completed")), total: length(children), children: children}
  end

  def parent(_node), do: nil

  defp links(linked_issues, relation), do: linked_issues |> Enum.filter(&(Map.get(&1, :relation) == relation)) |> tickets()

  defp tickets(tickets) do
    for %{identifier: identifier} = ticket <- List.wrap(tickets), is_binary(identifier) do
      %{identifier: identifier, title: Map.get(ticket, :title), state: Map.get(ticket, :state)}
    end
  end
end
