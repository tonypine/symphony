defmodule SymphonyElixir.HumanActions.Collector do
  @moduledoc """
  Reads the open human actions in Symphony's scope from Linear, grouped by project.

  One query per repository route, in the scope that route polls, returns every non-terminal issue
  that carries the `human_actions.label` label or sits in `In Review`. From those:

  - each open `## Action needed:` comment on a labelled issue is a `:request`
    (see `SymphonyElixir.HumanActions.Request`);
  - a labelled issue with no request comment is itself a `:task`;
  - a `breakdown` parent in `In Review` is a `:plan_review`;
  - an issue in `In Review` whose `## Symphony QA Report` says `blocked` is a `:qa_blocked`.

  Issues outside a project are skipped: there is no project to post the update to.
  """

  require Logger

  alias SymphonyElixir.{AutoReview, SubIssueWait}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.{Action, Request}
  alias SymphonyElixir.Linear.{Client, Issue}
  alias SymphonyElixir.QaAgent.Report

  @issue_first 50
  @comment_last 30
  @history_first 50
  @max_task_steps 12
  @plan_review_minutes 10
  @verdict_pattern ~r/^\*\*Verdict:\*\*\s*(\w+)/m
  @reason_pattern ~r/^Reason:\s*(.+)$/m

  @query """
  query SymphonyHumanActions($filter: IssueFilter!, $first: Int!, $commentLast: Int!, $historyFirst: Int!) {
    issues(filter: $filter, first: $first) {
      nodes {
        id
        identifier
        title
        description
        url
        state { name }
        project { id name }
        labels { nodes { name } }
        comments(last: $commentLast, orderBy: createdAt) {
          nodes { id body createdAt }
        }
        history(first: $historyFirst) {
          nodes { createdAt fromState { name } toState { name } }
        }
      }
      pageInfo { hasNextPage }
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
        actions = nodes |> Enum.uniq_by(& &1["id"]) |> Enum.flat_map(&issue_actions(&1, settings))
        {:ok, by_project(actions)}

      error ->
        error
    end
  end

  defp repo_nodes(repo, settings, opts) do
    scope_filter = Keyword.get(opts, :scope_filter, &Client.repo_scope_filter/1)
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, scope} <- scope_filter.(repo),
         {:ok, body} <- linear_client.(@query, variables(scope, settings), []) do
      issue_nodes(body)
    end
  end

  defp variables(scope, settings) do
    %{filter: filter(scope, settings), first: @issue_first, commentLast: @comment_last, historyFirst: @history_first}
  end

  defp issue_nodes(%{"data" => %{"issues" => %{"nodes" => nodes} = issues}}) when is_list(nodes) do
    if get_in(issues, ["pageInfo", "hasNextPage"]) == true,
      do: Logger.warning("Human actions: more than #{@issue_first} issues to read; listing the first #{@issue_first}")

    {:ok, nodes}
  end

  defp issue_nodes(body), do: {:error, {:human_actions_query_failed, body}}

  defp filter(scope, settings) do
    wanted = %{
      "or" => [
        %{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => settings.human_actions.label}}}},
        %{"state" => %{"name" => %{"eqIgnoreCase" => AutoReview.review_state()}}}
      ]
    }

    %{"and" => [scope, wanted, %{"state" => %{"name" => %{"nin" => settings.tracker.terminal_states}}}]}
  end

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
    in_review? = state_is?(issue.state, AutoReview.review_state())

    labelled_actions(context, String.downcase(settings.human_actions.label) in labels) ++
      plan_review_actions(context, in_review? and Enum.any?(labels, &Issue.breakdown_label?/1)) ++
      qa_blocked_actions(context, in_review?)
  end

  defp issue_actions(_node, _settings), do: []

  defp labelled_actions(_context, false), do: []

  defp labelled_actions(context, true) do
    case requests(context.node) do
      [] -> [task_action(context)]
      _requests -> for {comment_id, request} <- open_requests(context.node, context.settings), do: request_action(context, comment_id, request)
    end
  end

  @doc """
  The open `## Action needed:` comments of an issue as read from Linear (its `comments` with
  `id`, `body` and `createdAt`, and its state `history`), as `{comment_id, request}`.
  """
  @spec open_requests(map(), Schema.t()) :: [{String.t(), Request.t()}]
  def open_requests(node, settings) do
    changes = state_changes(node)
    owned = owned_states(settings)
    Enum.filter(requests(node), fn {_comment_id, request} -> Request.open?(request, changes, owned) end)
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
      unblocks: request.unblocks,
      est_minutes: request.est_minutes,
      steps: request.steps,
      done_when: "you remove the `#{context.settings.human_actions.label}` label from #{context.issue.identifier}, or move it on once it is unblocked."
    })
  end

  defp task_action(context) do
    action(context, %{
      key: "task:#{context.issue.id}",
      kind: :task,
      title: context.issue.title || context.issue.identifier,
      steps: context.node["description"] |> Request.text_steps() |> Enum.take(@max_task_steps),
      done_when: "you close #{context.issue.identifier}, or remove its `#{context.settings.human_actions.label}` label."
    })
  end

  defp plan_review_actions(_context, false), do: []

  defp plan_review_actions(%{issue: issue} = context, true) do
    approve =
      case SubIssueWait.state(context.settings) do
        waiting when is_binary(waiting) -> "To approve, move #{issue.identifier} to `#{waiting}`; Symphony moves its sub-tickets to Todo."
        nil -> "To approve, move the sub-tickets you accept to Todo."
      end

    [
      action(context, %{
        key: "plan:#{issue.id}",
        kind: :plan_review,
        title: "Approve the breakdown plan for #{issue.identifier}",
        why: "#{issue.identifier} is split into sub-tickets, and none of them starts before you approve the plan.",
        unblocks: "its sub-tickets, waiting in Backlog",
        est_minutes: @plan_review_minutes,
        steps: [
          "Read the plan in the `## Symphony Workpad` comment on #{issue.identifier}.",
          approve,
          "To reject it, comment what to change and move #{issue.identifier} to `Rework`."
        ],
        done_when: "#{issue.identifier} leaves #{AutoReview.review_state()}."
      })
    ]
  end

  defp qa_blocked_actions(_context, false), do: []

  defp qa_blocked_actions(%{issue: issue} = context, true) do
    case latest_qa_report(context.node) do
      %{verdict: "blocked", reason: reason} ->
        [
          action(context, %{
            key: "qa:#{issue.id}",
            kind: :qa_blocked,
            title: "Unblock QA for #{issue.identifier}",
            why: "Auto Review could not test the PR: #{reason || "see the QA report on #{issue.identifier}"}",
            unblocks: "the review of its PR",
            steps: [
              "Fix the cause above, on the machine QA runs on.",
              "Then test the PR yourself and move #{issue.identifier} to `Merging` to approve it, or to `Rework` to send it back."
            ],
            done_when: "#{issue.identifier} leaves #{AutoReview.review_state()}, or its next QA report is not blocked."
          })
        ]

      _report ->
        []
    end
  end

  defp latest_qa_report(node) do
    node
    |> comments()
    |> Enum.filter(&(is_binary(&1["body"]) and String.starts_with?(String.trim(&1["body"]), Report.heading())))
    |> Enum.max_by(&(&1["createdAt"] || ""), fn -> nil end)
    |> case do
      %{"body" => body} -> %{verdict: capture(@verdict_pattern, body), reason: capture(@reason_pattern, body)}
      nil -> nil
    end
  end

  defp capture(pattern, body) do
    case Regex.run(pattern, body) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
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
    [SubIssueWait.state(settings), settings.auto_review.state | settings.tracker.active_states]
    |> Enum.filter(&is_binary/1)
  end

  defp state_is?(state, expected) when is_binary(state), do: String.downcase(String.trim(state)) == String.downcase(expected)
  defp state_is?(_state, _expected), do: false

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
