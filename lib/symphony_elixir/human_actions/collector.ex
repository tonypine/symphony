defmodule SymphonyElixir.HumanActions.Collector do
  @moduledoc """
  Reads the open human actions in Symphony's scope from Linear, grouped by project.

  One query per repository route, in the scope that route polls, returns every non-terminal issue
  that carries the `Needs Decision` hold's label, is a `Final verification:` ticket, or carries a
  deprecated request label (`SymphonyElixir.PersonWait.legacy_request_labels/1`). From those:

  - each open `## Decision needed:` comment, or older `## Action needed:` one, is a `:request`
    (see `SymphonyElixir.HumanActions.Request`); a withdrawn or answered one is not listed;
  - an issue with a deprecated request label and no request comment is itself a `:task`.

  An issue's comments and history are read in full, past the first page the issue query returns,
  up to ten more pages of 100 each.

  Issues outside a project are skipped: there is no project to post the update to.

  `collect_all/2` also returns, from the same read, the issues waiting on a person
  (`SymphonyElixir.HumanActions.Waiting`), with or without a project.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Hold
  alias SymphonyElixir.HumanActions.{Action, Request, Waiting}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.{PersonWait, RunKind, SubIssueWait}

  @issue_first 50
  @comment_last 30
  @history_first 50
  # An issue's comments and history past the first read come in pages of this size, up to this
  # many pages each.
  @more_page_size 100
  @more_pages_max 10
  @max_task_steps 12

  @query """
  query SymphonyHumanActions($filter: IssueFilter!, $first: Int!, $after: String, $commentLast: Int!, $historyFirst: Int!) {
    issues(filter: $filter, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        url
        state { name }
        project { id name }
        parent { identifier project { id name } }
        labels { nodes { name } }
        comments(last: $commentLast, orderBy: createdAt) {
          nodes { id body createdAt parent { id } }
          pageInfo { hasPreviousPage startCursor }
        }
        history(first: $historyFirst) {
          nodes { createdAt fromState { name } toState { name } }
          pageInfo { hasNextPage endCursor }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @comments_query """
  query SymphonyHumanActionsComments($id: String!, $size: Int!, $cursor: String!) {
    issue(id: $id) {
      comments(last: $size, before: $cursor, orderBy: createdAt) {
        nodes { id body createdAt parent { id } }
        pageInfo { hasPreviousPage startCursor }
      }
    }
  }
  """

  @history_query """
  query SymphonyHumanActionsHistory($id: String!, $size: Int!, $cursor: String!) {
    issue(id: $id) {
      history(first: $size, after: $cursor) {
        nodes { createdAt fromState { name } toState { name } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @typedoc "The open actions of one project."
  @type project_actions :: %{project: %{id: String.t(), name: String.t() | nil}, actions: [Action.t()]}

  @doc """
  The open actions in the scope of `repos`, by project id. Fails as a whole when any route's query
  fails, so a project is never reported empty because its route could not be read.

  Options: `:settings` (labels, states), `:linear_client` (`(query, variables, opts)` GraphQL
  function) and `:scope_filter` (the route's issue filter, `SymphonyElixir.Linear.Client.repo_scope_filter/1`).
  """
  @spec collect([term()], keyword()) :: {:ok, %{String.t() => project_actions()}} | {:error, term()}
  def collect(repos, opts) do
    with {:ok, actions, _waiting} <- collect_all(repos, opts), do: {:ok, actions}
  end

  @doc """
  `collect/2`, plus the issues waiting on a person (`SymphonyElixir.HumanActions.Waiting`) read
  from the same query.
  """
  @spec collect_all([term()], keyword()) ::
          {:ok, %{String.t() => project_actions()}, [Waiting.entry()]} | {:error, term()}
  def collect_all(repos, opts) do
    settings = Keyword.fetch!(opts, :settings)

    repos
    |> Enum.reduce_while({:ok, []}, fn repo, {:ok, acc} ->
      case repo_nodes(repo, settings, opts) do
        {:ok, nodes} -> {:cont, {:ok, acc ++ nodes}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, nodes} ->
        nodes = Enum.uniq_by(nodes, & &1["id"])
        actions = Enum.flat_map(nodes, &issue_actions(&1, settings))
        {:ok, by_project(actions), Waiting.entries(nodes, settings)}

      error ->
        error
    end
  end

  defp repo_nodes(repo, settings, opts) do
    scope_filter = Keyword.get(opts, :scope_filter, &Client.repo_scope_filter/1)
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, scope} <- scope_filter.(repo) do
      read_pages(filter(scope, settings), nil, [], linear_client)
    end
  end

  # Reads every page: an issue left past the first page would drop its actions from the update
  # as if they had closed.
  defp read_pages(filter, after_cursor, acc, linear_client) do
    with {:ok, body} <- linear_client.(@query, variables(filter, after_cursor), []),
         {:ok, nodes, next} <- issue_page(body),
         {:ok, nodes} <- read_more(nodes, linear_client) do
      case next do
        {:next, cursor} -> read_pages(filter, cursor, [nodes | acc], linear_client)
        :done -> {:ok, [nodes | acc] |> Enum.reverse() |> Enum.concat()}
      end
    end
  end

  defp variables(filter, after_cursor) do
    %{
      filter: filter,
      first: @issue_first,
      after: after_cursor,
      commentLast: @comment_last,
      historyFirst: @history_first
    }
  end

  defp issue_page(%{"data" => %{"issues" => %{"nodes" => nodes} = issues}}) when is_list(nodes) do
    case issues["pageInfo"] do
      %{"hasNextPage" => true, "endCursor" => cursor} when is_binary(cursor) and cursor != "" -> {:ok, nodes, {:next, cursor}}
      %{"hasNextPage" => true} -> {:error, :linear_missing_end_cursor}
      _page_info -> {:ok, nodes, :done}
    end
  end

  defp issue_page(body), do: {:error, {:human_actions_query_failed, body}}

  @doc """
  Reads the rest of each node's comments and history past the first page, as the issue query
  here does: for a caller (`SymphonyElixir.Inbox`) whose own query reads them with the same fields.
  """
  @spec read_more_pages([map()], (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def read_more_pages(nodes, linear_client), do: read_more(nodes, linear_client)

  # A long-lived issue's review brief, requests and move into its state can sit past the comments
  # and history the issue query reads: read the rest of them, so it keeps its waited time and
  # headline.
  defp read_more(nodes, linear_client) do
    nodes
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      with {:ok, node} <- read_more(node, "comments", linear_client),
           {:ok, node} <- read_more(node, "history", linear_client) do
        {:cont, {:ok, [node | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end
  end

  defp read_more(node, field, linear_client) do
    case more_pages(node["id"], field, get_in(node, [field, "pageInfo"]), @more_pages_max, linear_client) do
      {:ok, []} -> {:ok, node}
      {:ok, pages} -> {:ok, update_in(node, [field, "nodes"], &merge_pages(field, List.wrap(&1), pages))}
      error -> error
    end
  end

  # Past the cap, the issue keeps what was read rather than failing the whole update.
  defp more_pages(_issue_id, _field, _page_info, 0, _linear_client), do: {:ok, []}

  defp more_pages(issue_id, field, page_info, pages_left, linear_client) do
    case more_cursor(field, page_info) do
      :done ->
        {:ok, []}

      {:next, cursor} ->
        variables = %{id: issue_id, size: @more_page_size, cursor: cursor}

        with {:ok, body} <- linear_client.(more_query(field), variables, []),
             {:ok, nodes, page_info} <- connection_page(body, field),
             {:ok, pages} <- more_pages(issue_id, field, page_info, pages_left - 1, linear_client) do
          {:ok, [nodes | pages]}
        end

      error ->
        error
    end
  end

  defp more_query("comments"), do: @comments_query
  defp more_query("history"), do: @history_query

  # Comments are read newest last, so their further pages are older; history reads on forward.
  defp more_cursor("comments", %{"hasPreviousPage" => true} = page_info), do: cursor(page_info["startCursor"])
  defp more_cursor("history", %{"hasNextPage" => true} = page_info), do: cursor(page_info["endCursor"])
  defp more_cursor(_field, _page_info), do: :done

  defp cursor(cursor) when is_binary(cursor) and cursor != "", do: {:next, cursor}
  defp cursor(_cursor), do: {:error, :linear_missing_end_cursor}

  defp connection_page(%{"data" => %{"issue" => %{} = issue}}, field) do
    case issue[field] do
      %{"nodes" => nodes} = connection when is_list(nodes) -> {:ok, nodes, connection["pageInfo"]}
      _connection -> {:error, {:human_actions_query_failed, field}}
    end
  end

  defp connection_page(body, _field), do: {:error, {:human_actions_query_failed, body}}

  defp merge_pages("comments", nodes, pages), do: pages |> Enum.reverse() |> Enum.concat() |> Enum.concat(nodes)
  defp merge_pages("history", nodes, pages), do: Enum.concat([nodes | pages])

  defp filter(scope, settings) do
    labelled = Enum.map(PersonWait.legacy_request_labels(settings), &label_filter/1)
    final_verification = %{"title" => %{"startsWith" => RunKind.final_verification_prefix()}}
    # A request leaves the ticket in its phase, so the hold's label is what finds it.
    held = label_filter(Hold.label(:needs_decision))
    wanted = %{"or" => labelled ++ [final_verification, held]}

    %{"and" => [scope, wanted, %{"state" => %{"name" => %{"nin" => settings.tracker.terminal_states}}}]}
  end

  defp label_filter(name), do: %{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => name}}}}

  defp by_project(actions) do
    actions
    |> Enum.uniq_by(& &1.key)
    |> Enum.group_by(& &1.project.id)
    |> Map.new(fn {project_id, [first | _] = project_actions} -> {project_id, %{project: first.project, actions: project_actions}} end)
  end

  defp issue_actions(%{"project" => %{"id" => project_id} = project} = node, settings) when is_binary(project_id) do
    issue = %{
      id: node["id"],
      identifier: node["identifier"],
      title: node["title"],
      url: node["url"],
      state: get_in(node, ["state", "name"])
    }

    context = %{node: node, issue: issue, project: %{id: project_id, name: project["name"]}, settings: settings}
    labels = node |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(&String.downcase(to_string(&1["name"])))
    legacy_labelled? = Enum.any?(PersonWait.legacy_request_labels(settings), &(&1 in labels))

    request_actions(context, legacy_labelled?)
  end

  defp issue_actions(_node, _settings), do: []

  # A deprecated request label on an issue with no request comment makes the issue itself the task.
  defp request_actions(context, legacy_labelled?) do
    case requests(context.node) do
      [] when legacy_labelled? -> [task_action(context)]
      _requests -> for {comment_id, request} <- open_requests(context.node, context.settings), do: request_action(context, comment_id, request)
    end
  end

  @doc """
  The open `## Action needed:` comments of an issue as read from Linear (its `comments` with
  `id`, `body`, `createdAt` and `parent`, and its state `history`), as `{comment_id, request}`.
  A request with an `## Action withdrawn` reply under it is closed, and so is one a person answered.
  """
  @spec open_requests(map(), Schema.t()) :: [{String.t(), Request.t()}]
  def open_requests(node, settings) do
    changes = state_changes(node)
    owned = owned_states(settings)
    closed = MapSet.union(withdrawn_ids(node), answered_ids(node))

    Enum.filter(requests(node), fn {comment_id, request} ->
      not MapSet.member?(closed, comment_id) and Request.open?(request, changes, owned)
    end)
  end

  @doc """
  The newest open request on the issue node and the id of the comment that carries it, or nil when
  none is open. The comment id is what a reply answers, so the Director app can close it.
  """
  @spec newest_open_request(map(), Schema.t()) :: {String.t(), Request.t()} | nil
  def newest_open_request(node, settings) do
    node
    |> open_requests(settings)
    |> Enum.max_by(&request_at/1, fn -> nil end)
  end

  # When the request was posted, as a comparable integer; a request whose comment carried no
  # `createdAt` sorts oldest.
  defp request_at({_comment_id, request}) do
    (request.created_at && DateTime.to_unix(request.created_at, :microsecond)) || 0
  end

  @doc "The newest open request on the issue node, or nil when none is open."
  @spec newest_request(map(), Schema.t()) :: Request.t() | nil
  def newest_request(node, settings), do: node |> newest_open_request(settings) |> then(&(&1 && elem(&1, 1)))

  defp withdrawn_ids(node) do
    for %{"parent" => %{"id" => parent_id}} = comment <- comments(node), Request.withdrawal?(comment["body"]), into: MapSet.new(), do: parent_id
  end

  # A request does not move its issue, so no state change says it is over: a person's reply under
  # the request is the answer that closes it.
  defp answered_ids(node) do
    for %{"parent" => %{"id" => parent_id}} = comment <- comments(node),
        not Request.withdrawal?(comment["body"]),
        into: MapSet.new(),
        do: parent_id
  end

  defp requests(node) do
    for %{"id" => id, "body" => body} = comment <- comments(node),
        request = Request.parse(body, parse_datetime(comment["createdAt"])),
        request != nil,
        do: {id, request}
  end

  defp request_action(context, comment_id, request) do
    action(context, %{
      key: "request:#{comment_id}",
      kind: :request,
      title: request.title,
      why: request.why,
      if_unanswered: request.if_unanswered,
      unblocks: request.unblocks,
      question: request.question,
      options: request.options,
      steps: request.steps,
      done_when: request_done_when(request)
    })
  end

  # A request never moves its ticket: the person's reply (or the Inbox's Decide) records the
  # decision and clears the hold, so the line names no state move.
  defp request_done_when(%{options: [_ | _]}),
    do: "you reply with your pick (or answer it in the Symphony Inbox), or the agent withdraws the request."

  defp request_done_when(_request), do: "you reply to the request, or the agent withdraws the request."

  defp task_action(context) do
    action(context, %{
      key: "task:#{context.issue.id}",
      kind: :task,
      title: context.issue.title || context.issue.identifier,
      steps: context.node["description"] |> Request.text_steps() |> Enum.take(@max_task_steps),
      done_when: "you close #{context.issue.identifier}, or move it on."
    })
  end

  defp action(context, attrs), do: struct!(Action, Map.merge(attrs, %{issue: context.issue, project: context.project}))

  defp comments(node), do: node |> get_in(["comments", "nodes"]) |> List.wrap()

  defp state_changes(node) do
    for %{"toState" => %{"name" => _to}} = entry <- node |> get_in(["history", "nodes"]) |> List.wrap(),
        at = parse_datetime(entry["createdAt"]),
        at != nil,
        do: %{at: at, from: get_in(entry, ["fromState", "name"])}
  end

  # States Symphony or an agent moves an issue out of; leaving any other state is a person
  # moving the issue on.
  defp owned_states(settings) do
    [SubIssueWait.state(settings) | settings.tracker.active_states]
    |> Enum.filter(&is_binary/1)
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
