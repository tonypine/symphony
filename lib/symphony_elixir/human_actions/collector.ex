defmodule SymphonyElixir.HumanActions.Collector do
  @moduledoc """
  The open human actions in Symphony's scope, grouped by project, built from the tickets' records
  (`SymphonyElixir.RunStore.list_all_ticket_states/0`) and never from Linear.

  Every open Question (`SymphonyElixir.Questions`) on the record of a ticket of an enabled
  repository is a `:request` action, with its title and its ticket, worded as the request comment
  the pause projector posts for it. A Question answered or withdrawn
  in the Director is no longer open, so it drops from the next update without a Linear read, and
  the update lists the same questions the Inbox does (`SymphonyElixir.Inbox.FromRecord`).

  A ticket outside a project is skipped: there is no project to post the update to.

  The issue node helpers (`open_requests/2` and `read_more_pages/2`) read a ticket's Linear
  comments for the callers that still parse them.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.{Action, Request}
  alias SymphonyElixir.{RunStore, SubIssueWait, TicketState}

  # An issue's comments and history past the first read come in pages of this size, up to this
  # many pages each.
  @more_page_size 100
  @more_pages_max 10

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
  The open actions of the tickets of `repos` (each by its `name`, the repo key its records carry),
  by project id. Fails when the records cannot be read, so a project is never reported empty
  because its records were not there.

  Options: `:records` (a function returning the records, default
  `SymphonyElixir.RunStore.list_all_ticket_states/0`).
  """
  @spec collect([%{name: String.t()}], keyword()) :: {:ok, %{String.t() => project_actions()}} | {:error, term()}
  def collect(repos, opts) do
    repo_keys = MapSet.new(repos, & &1.name)

    with records when is_list(records) <- Keyword.get(opts, :records, &RunStore.list_all_ticket_states/0).() do
      actions =
        records
        |> Enum.map(&TicketState.normalize/1)
        |> Enum.filter(&MapSet.member?(repo_keys, &1.repo_key))
        |> Enum.flat_map(&record_actions/1)

      {:ok, by_project(actions)}
    end
  end

  defp record_actions(%{project: %{id: project_id} = project} = record) when is_binary(project_id) do
    issue = %{id: record.issue_id, identifier: record.issue_identifier, title: record.title, url: record.url, state: record.phase}

    for %{state: :open} = question <- record.questions do
      %Action{
        key: "question:#{question.id}",
        kind: :request,
        title: question.title,
        why: question.why,
        if_unanswered: question.if_unanswered,
        unblocks: question.unblocks,
        question: question.question,
        options: Enum.map(question.options, &option_line/1),
        done_when: done_when(question.options),
        issue: issue,
        project: %{id: project_id, name: project.name}
      }
    end
  end

  defp record_actions(_record), do: []

  # An option as the request comment renders it, without its trade-offs.
  defp option_line(option) do
    marker = if Map.get(option, :recommended?), do: " (recommended)"
    "**#{Request.label(option)}**#{marker}: #{Request.one_line(option.effect)}"
  end

  # A request never moves its ticket: the person's answer in the Director (or a reply) records the
  # decision and clears the hold, so the line names no state move.
  defp done_when([_ | _]), do: "you reply with your pick (or answer it in the Symphony Inbox), or the agent withdraws the request."
  defp done_when(_options), do: "you reply to the request, or the agent withdraws the request."

  defp by_project(actions) do
    actions
    |> Enum.uniq_by(& &1.key)
    |> Enum.group_by(& &1.project.id)
    |> Map.new(fn {project_id, [first | _] = project_actions} -> {project_id, %{project: first.project, actions: project_actions}} end)
  end

  @doc """
  Reads the rest of each issue node's comments and history past the first page, for a caller
  (`SymphonyElixir.PlanBrief`) whose own query reads them with `id`, `body`, `createdAt` and
  `parent` for a comment, and `createdAt`, `fromState` and `toState` for a history entry.
  """
  @spec read_more_pages([map()], (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def read_more_pages(nodes, linear_client), do: read_more(nodes, linear_client)

  # A long-lived issue's review brief, requests and move into its state can sit past the comments
  # and history its first read returns: read the rest of them.
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
