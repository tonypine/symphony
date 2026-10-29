defmodule SymphonyElixir.Linear.IssueNormalizer do
  @moduledoc """
  Turns Linear's view of an issue into Symphony's `Linear.Issue`, from either source: a GraphQL node
  the poll fetched (`from_graphql_node/2`) or the `data` of a webhook delivery
  (`from_webhook_data/1`). Both read the same fields the same way, so the same ticket gives the same
  `Issue` from either.

  A delivery carries less than the poll query: no children, no comments, no project slug, and
  relations only sometimes. A field the delivery doesn't carry is `:unknown` (the project's slug is
  left out of its map), never empty, so a later merge can tell "Linear said none" from "this source
  didn't say" and never erases a known fact with a missing one. A value of the wrong shape in a
  delivery reads as nothing, never a raise.
  """

  alias SymphonyElixir.{AgentLabels, Decisions, IssueSummary, Linear.Issue}

  @comment_limit 3
  @comment_body_limit 800
  @workpad_markers AgentLabels.known_workpad_markers()

  @typedoc "Whose issues the worker takes: nil for anyone's, else the assignee ids it matches."
  @type assignee_filter :: %{required(:match_values) => MapSet.t(String.t()), optional(atom()) => term()} | nil

  @typedoc "A comment as an `Issue` holds it, with its Linear id when the source gives one."
  @type comment :: %{
          optional(:id) => String.t(),
          author: String.t(),
          body: String.t(),
          created_at: DateTime.t() | nil
        }

  @doc """
  The `Issue` for a GraphQL issue node, or nil for anything else. `assigned_to_worker` is true
  without an `assignee_filter`, else whether the node's assignee is one it matches; candidate queries
  filter by assignee server-side, so the by-id refresh is where it matters.
  """
  @spec from_graphql_node(term(), assignee_filter()) :: Issue.t() | nil
  def from_graphql_node(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      # Symphony's own summary block is not part of the ticket's requirements.
      description: IssueSummary.strip(issue["description"]),
      priority: parse_priority(issue["priority"]),
      state: name_of(issue["state"]),
      team: extract_team(issue),
      project: extract_project(issue),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      sub_issues: extract_sub_issues(issue),
      labels: extract_labels(issue),
      comments: comments(issue),
      # A person's rulings in plain comments, which the poll records in the description.
      rulings: Decisions.rulings(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  def from_graphql_node(_issue, _assignee_filter), do: nil

  @doc """
  The `Issue` for the `data` of a Linear `Issue` webhook delivery, or nil for anything else. Linear
  sends it in its REST-like shape: `labels` a list, not a connection. Children, comments (and the
  rulings and linked issues read from them) are never in a delivery, so they are `:unknown`, as are
  `blocked_by` and `branch_name` when the delivery lacks them. A delivery's project has no slug, so
  its map has no `:slug_id` unless the delivery gives one. `assigned_to_worker` keeps its
  default: the assignee filter is the poll's, and the record applies it.
  """
  @spec from_webhook_data(term()) :: Issue.t() | nil
  def from_webhook_data(data) when is_map(data) do
    %Issue{
      id: data["id"],
      identifier: data["identifier"],
      title: data["title"],
      description: IssueSummary.strip(data["description"]),
      priority: parse_priority(data["priority"]),
      state: name_of(data["state"]),
      team: extract_team(data),
      project: webhook_project(data),
      branch_name: Map.get(data, "branchName", :unknown),
      url: data["url"],
      assignee_id: assignee_field(data["assignee"], "id"),
      blocked_by: if(Map.has_key?(data, "inverseRelations"), do: extract_blockers(data), else: :unknown),
      sub_issues: :unknown,
      labels: extract_labels(data),
      comments: :unknown,
      rulings: :unknown,
      linked_issues: :unknown,
      created_at: parse_datetime(data["createdAt"]),
      updated_at: parse_datetime(data["updatedAt"])
    }
  end

  def from_webhook_data(_data), do: nil

  @doc """
  The comments an `Issue` keeps from a node's `comments` connection: the workpad, if any, then the
  newest others, three in all, each body cut to 800 characters. Empty bodies are skipped.
  """
  @spec comments(map()) :: [comment()]
  def comments(%{"comments" => %{"nodes" => comments}}) when is_list(comments) do
    normalized_comments =
      comments
      |> Enum.with_index()
      |> Enum.flat_map(fn {comment, index} ->
        case normalize_comment(comment, index) do
          nil -> []
          normalized -> [normalized]
        end
      end)
      |> Enum.reverse()

    workpad_comment = Enum.find(normalized_comments, & &1.contains_workpad_marker)

    normalized_comments
    |> select_comments(workpad_comment)
    |> Enum.map(&Map.take(&1, [:author, :body, :created_at]))
  end

  def comments(_issue), do: []

  @doc """
  The comment in the `data` of a Linear `Comment` webhook delivery, in the shape an `Issue` holds
  comments, with its id; nil without an id. The body is cut as `comments/1` cuts it.
  """
  @spec comment_from_webhook_data(term()) :: comment() | nil
  def comment_from_webhook_data(%{"id" => id} = data) when is_binary(id) and id != "" do
    body = if is_binary(data["body"]), do: data["body"], else: ""

    %{
      id: id,
      author: comment_author(data),
      body: truncate_comment_body(body),
      created_at: parse_datetime(data["createdAt"])
    }
  end

  def comment_from_webhook_data(_data), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp extract_team(%{"team" => %{} = team}) do
    %{
      key: team["key"],
      name: team["name"]
    }
  end

  defp extract_team(_issue), do: nil

  defp extract_project(%{"project" => %{} = project}) do
    %{
      id: project["id"],
      name: project["name"],
      slug_id: project["slugId"]
    }
  end

  defp extract_project(_issue), do: nil

  # A delivery's project has no `slugId`: the key is left out rather than nil, so the poll's slug
  # (which routes match on) survives a merge.
  defp webhook_project(%{"project" => %{} = project} = data) do
    if Map.has_key?(project, "slugId"), do: extract_project(data), else: Map.delete(extract_project(data), :slug_id)
  end

  defp webhook_project(_data), do: nil

  # The `name` of a nested entity (a state), or nil when it isn't an entity with a string name.
  defp name_of(%{"name" => name}) when is_binary(name), do: name
  defp name_of(_entity), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    case trimmed(assignee["id"]) do
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_value), do: nil

  # A GraphQL connection (`%{"nodes" => [...]}`) or a delivery's plain list.
  defp nodes(%{"nodes" => nodes}) when is_list(nodes), do: nodes
  defp nodes(nodes) when is_list(nodes), do: nodes
  defp nodes(_connection), do: []

  defp extract_labels(issue) do
    issue["labels"]
    |> nodes()
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [String.downcase(name)]
      _label -> []
    end)
  end

  defp extract_blockers(issue) do
    issue["inverseRelations"]
    |> nodes()
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: name_of(blocker_issue["state"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_sub_issues(%{"children" => %{"nodes" => children}}) when is_list(children) do
    Enum.flat_map(children, fn
      %{} = child -> [%{id: child["id"], identifier: child["identifier"], state: name_of(child["state"])}]
      _child -> []
    end)
  end

  defp extract_sub_issues(_), do: []

  defp normalize_comment(%{"body" => body} = comment, index) when is_binary(body) do
    trimmed_body = String.trim(body)

    if trimmed_body == "" do
      nil
    else
      %{
        index: index,
        author: comment_author(comment),
        body: truncate_comment_body(body),
        contains_workpad_marker: Enum.any?(@workpad_markers, &String.contains?(body, &1)),
        created_at: parse_datetime(comment["createdAt"])
      }
    end
  end

  defp normalize_comment(_comment, _index), do: nil

  defp comment_author(%{"user" => %{"name" => name}}) when is_binary(name) do
    case String.trim(name) do
      "" -> "Unknown"
      author -> author
    end
  end

  defp comment_author(_comment), do: "Unknown"

  defp truncate_comment_body(body) when is_binary(body) do
    String.slice(body, 0, @comment_body_limit)
  end

  defp select_comments(comments, nil) do
    Enum.take(comments, @comment_limit)
  end

  defp select_comments(comments, workpad_comment) when is_map(workpad_comment) do
    recent_comments =
      comments
      |> Enum.reject(&(&1.index == workpad_comment.index))
      |> Enum.take(@comment_limit - 1)

    [workpad_comment | recent_comments]
  end

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
