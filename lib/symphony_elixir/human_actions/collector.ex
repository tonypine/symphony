defmodule SymphonyElixir.HumanActions.Collector do
  @moduledoc """
  Reads the open human actions in Symphony's scope from Linear, grouped by project.

  One query per repository route, in the scope that route polls, returns every non-terminal issue
  that sits in `In Review` or the Human Review state (`SymphonyElixir.HumanReview`), is a
  `Final verification:` ticket, or carries a deprecated request label
  (`SymphonyElixir.HumanReview.legacy_request_labels/1`). From those:

  - each open `## Decision needed:` comment, or older `## Action needed:` one, is a `:request`
    (see `SymphonyElixir.HumanActions.Request`); a withdrawn one is not listed;
  - an issue with a deprecated request label and no request comment is itself a `:task`;
  - a plan parent in a review state is a `:plan_review`;
  - an issue in a review state whose `## Symphony QA Report` says `blocked` for a cause only the
    operator can clear (the running app lacks a QA tool, a tool missing on the Symphony host, the
    QA host's macOS permissions) is a `:qa_blocked`, unless it is a `Final verification:` ticket.
    It asks for that one step, never for a test by hand, and the issues blocked on the same cause
    share one action. A block for any other cause, a QA tool the PR itself adds among them, is the
    supervisor's: nothing is listed for it, not even as a `:human_review`;
  - a `Final verification:` ticket, in any state, whose parent walkthrough report says `blocked`
    is a `:verification_blocked` on its parent's project, while the ticket stays in the state the
    walkthrough moved it to;
  - an issue in the Human Review state with none of the above is a `:human_review`.

  Every action on an issue in the Human Review state is marked `human_review`, so the update lists
  it first.

  Neither lists a `blocked` verdict whose QA agent was stopped by the provider's usage limit: that
  pass runs again once the limit resets.

  An issue's comments and history are read in full, past the first page the issue query returns,
  up to ten more pages of 100 each.

  Issues outside a project are skipped: there is no project to post the update to.

  `collect_all/2` also returns, from the same read, the issues waiting on a person
  (`SymphonyElixir.HumanActions.Waiting`), with or without a project.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.{Action, Request, Waiting}
  alias SymphonyElixir.{HumanReview, RunKind, SubIssueWait}
  alias SymphonyElixir.Linear.{Client, Issue}
  alias SymphonyElixir.QaAgent.Report

  @issue_first 50
  @comment_last 30
  @history_first 50
  # An issue's comments and history past the first read come in pages of this size, up to this
  # many pages each.
  @more_page_size 100
  @more_pages_max 10
  @max_task_steps 12
  @plan_review_minutes 10
  @human_review_minutes 10
  @verdict_pattern ~r/^\*\*Verdict:\*\*\s*(\w+)/m
  @reason_pattern ~r/^Reason:\s*(.+)$/m
  # The `blocked` reason of a QA agent that hit the provider's usage limit, as older QA reports
  # wrote it: `the QA agent could not finish: {:qa_agent_failed, {:usage_limited, ...}}`.
  @usage_limit_pattern ~r/:usage_limited\b/
  # A parent walkthrough's report names the verification ticket and the state it moved it to.
  @walkthrough_target_pattern ~r/^\*\*Verdict:\*\*\s*\w+\s*→\s*(\S+)\s+(.+?)\s*$/m
  @blocked_step_pattern ~r/^- \*\*blocked\*\* (.+?)(?: \(evidence: .*\))?$/m
  @permission_pattern ~r/permission|privacy & security|screen recording/i
  # The causes of a QA block only the operator can clear, read from the QA report's reason. A tool
  # the PR itself adds is not one: the running app gets it once the PR merges.
  @pr_adds_tool_pattern ~r/\b(this|the) PR\b[^.;]*\badds?\b|\badded (by|in) (this|the) PR\b/i
  @app_update_pattern ~r/\b(running|installed) (Symphony )?(app|build)\b|\bapp update\b|\bupdate (the |Symphony(?:'s)? )?app\b/i
  @host_tool_pattern ~r/`([^`]+)` is not installed on the Symphony host; run `([^`]+)` there once/
  @npx_missing_pattern ~r/`npx` \(Node\.js\) is not on Symphony's PATH/
  @qa_permission_pattern ~r/screen recording|accessibility permission|privacy & security/i
  @qa_cause_minutes 5
  @gap_state "Todo"

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
        actions = nodes |> Enum.flat_map(&issue_actions(&1, settings)) |> merge_qa_blocked()
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
    labelled = Enum.map(HumanReview.legacy_request_labels(settings), &%{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => &1}}}})
    in_review = Enum.map(HumanReview.review_states(settings), &%{"state" => %{"name" => %{"eqIgnoreCase" => &1}}})
    final_verification = %{"title" => %{"startsWith" => RunKind.final_verification_prefix()}}
    wanted = %{"or" => labelled ++ in_review ++ [final_verification]}

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
    in_review? = HumanReview.review_state?(issue.state, settings)
    human_review? = HumanReview.in_state?(issue.state, settings)
    final_verification? = RunKind.classify(%Issue{title: issue.title}) == :final_verification

    legacy_labelled? = Enum.any?(HumanReview.legacy_request_labels(settings), &(&1 in labels))

    qa_blocked? = in_review? and not final_verification? and qa_blocked?(context.node)

    actions =
      request_actions(context, legacy_labelled?) ++
        plan_review_actions(context, in_review? and Enum.any?(labels, &Issue.breakdown_label?/1)) ++
        qa_blocked_actions(context, qa_blocked?) ++
        verification_blocked_actions(context, final_verification?)

    # A QA block is the operator's one step, or the supervisor's: never a review left to a person.
    actions
    |> human_review_actions(context, human_review? and not qa_blocked?)
    |> Enum.map(&%{&1 | human_review: human_review?})
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
  A request with an `## Action withdrawn` reply under it is closed.
  """
  @spec open_requests(map(), Schema.t()) :: [{String.t(), Request.t()}]
  def open_requests(node, settings) do
    changes = state_changes(node)
    owned = owned_states(settings)
    withdrawn = withdrawn_ids(node)

    Enum.filter(requests(node), fn {comment_id, request} ->
      not MapSet.member?(withdrawn, comment_id) and Request.open?(request, changes, owned)
    end)
  end

  defp withdrawn_ids(node) do
    for %{"parent" => %{"id" => parent_id}} = comment <- comments(node), Request.withdrawal?(comment["body"]), into: MapSet.new(), do: parent_id
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
      question: request.question,
      options: request.options,
      steps: request.steps,
      done_when: request_done_when(context, request)
    })
  end

  defp request_done_when(context, %{options: [_ | _]}),
    do: "you reply with your pick and move #{context.issue.identifier} out of #{context.issue.state}, or the agent withdraws the request."

  defp request_done_when(context, _request),
    do: "you move #{context.issue.identifier} out of #{context.issue.state} once it is unblocked, or the agent withdraws the request."

  defp task_action(context) do
    action(context, %{
      key: "task:#{context.issue.id}",
      kind: :task,
      title: context.issue.title || context.issue.identifier,
      steps: context.node["description"] |> Request.text_steps() |> Enum.take(@max_task_steps),
      done_when: "you close #{context.issue.identifier}, or move it on."
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
        title: "Approve the plan for #{issue.identifier}",
        why: "#{issue.identifier} is split into sub-tickets, and none of them starts before you approve the plan.",
        unblocks: "its sub-tickets, waiting in Backlog",
        est_minutes: @plan_review_minutes,
        steps: [
          "Read the plan in the `## Symphony Workpad` comment on #{issue.identifier}.",
          approve,
          "To reject it, comment what to change and move #{issue.identifier} to `Rework`."
        ],
        done_when: "#{issue.identifier} leaves #{issue.state}."
      })
    ]
  end

  defp qa_blocked_actions(_context, false), do: []

  # A block with a cause only the operator can clear is listed as that one step, merged with the
  # other issues blocked on the same cause by `merge_qa_blocked/1`. Any other block is the
  # supervisor's, so nothing is listed for it.
  defp qa_blocked_actions(%{issue: issue} = context, true) do
    reason = latest_qa_report(context.node).reason

    case qa_cause(reason) do
      %{} = cause ->
        [
          action(context, %{
            key: "qa:#{cause.id}:#{issue.id}",
            kind: :qa_blocked,
            title: cause.title,
            why: String.trim_trailing(reason, "."),
            est_minutes: @qa_cause_minutes,
            steps: [cause.step]
          })
        ]

      nil ->
        []
    end
  end

  # A pass that hit the usage limit runs again once the limit resets: nobody needs to unblock it.
  defp qa_blocked?(node), do: match?(%{verdict: "blocked", usage_limited?: false}, latest_qa_report(node))

  defp qa_cause(reason) when is_binary(reason) do
    cond do
      Regex.match?(@pr_adds_tool_pattern, reason) ->
        nil

      Regex.match?(@app_update_pattern, reason) ->
        %{id: "app_update", title: "Update the Symphony app", step: "Update the Symphony app to its latest release."}

      match = Regex.run(@host_tool_pattern, reason) ->
        [_, tool, command] = match
        %{id: "tool:#{tool}", title: "Install `#{tool}` on the Symphony host", step: "Run `#{command}` on the Symphony host once."}

      Regex.match?(@npx_missing_pattern, reason) ->
        %{id: "tool:npx", title: "Install Node.js on the Symphony host", step: "Install Node.js on the Symphony host, so `npx` is on Symphony's PATH."}

      Regex.match?(@qa_permission_pattern, reason) ->
        %{
          id: "qa_permissions",
          title: "Grant the QA host's permissions",
          step: "On the QA host, open System Settings > Privacy & Security and grant Screen Recording and Accessibility to the app the QA reports name."
        }

      true ->
        nil
    end
  end

  defp qa_cause(_reason), do: nil

  # One action per cause and project, naming every issue blocked on it.
  defp merge_qa_blocked(actions) do
    {blocked, others} = Enum.split_with(actions, &(&1.kind == :qa_blocked))

    merged =
      blocked
      |> Enum.group_by(&{&1.project.id, &1.title})
      |> Enum.map(fn {_cause, group} -> merge_qa_group(Enum.sort_by(group, & &1.issue.identifier)) end)

    others ++ merged
  end

  defp merge_qa_group([first | _] = group) do
    issues = Enum.map(group, & &1.issue)

    %{
      first
      | key: String.replace_suffix(first.key, ":" <> first.issue.id, ":") <> Enum.map_join(issues, ",", & &1.id),
        issue: nil,
        human_review: false,
        why: Enum.map_join(group, " ", &"#{&1.issue.identifier}: #{&1.why}."),
        unblocks: "the QA of " <> join_words(Enum.map(issues, &issue_link/1)),
        done_when: qa_done_when(Enum.map(issues, & &1.identifier))
    }
  end

  defp qa_done_when([identifier]), do: "#{identifier} leaves its review state, or its next QA report is not blocked."
  defp qa_done_when(identifiers), do: "#{join_words(identifiers)} each leave their review state, or their next QA reports are not blocked."

  defp issue_link(%{identifier: identifier, url: url}) when is_binary(url), do: "[#{identifier}](#{url})"
  defp issue_link(%{identifier: identifier}), do: identifier

  defp join_words([one]), do: one
  defp join_words(words), do: Enum.join(Enum.drop(words, -1), ", ") <> " and " <> List.last(words)

  # An issue in the Human Review state is waiting on a person even when nothing else names what for.
  defp human_review_actions([], %{issue: issue} = context, true) do
    [
      action(context, %{
        key: "review:#{issue.id}",
        kind: :human_review,
        title: "Review #{issue.identifier}",
        why: "#{issue.identifier} waits in #{issue.state}: only you can move it on.",
        est_minutes: @human_review_minutes,
        steps: [
          "Read the `## Symphony Workpad` comment and the latest QA report on #{issue.identifier}, and its PR if it has one.",
          "Move #{issue.identifier} to `Merging` to approve its PR, to `Rework` to send it back, " <>
            "or to `Done` to sign off a final verification."
        ],
        done_when: "#{issue.identifier} leaves #{issue.state}."
      })
    ]
  end

  defp human_review_actions(actions, _context, _human_review?), do: actions

  defp verification_blocked_actions(_context, false), do: []

  # The verdict line says where the walkthrough left the ticket: `In Review`, or `Todo` when the
  # failing steps it could run were filed as gap tickets.
  # A walkthrough that hit the usage limit runs again once the limit resets: nobody needs to unblock it.
  defp verification_blocked_actions(%{issue: issue} = context, true) do
    with %{verdict: "blocked", usage_limited?: false, body: body} = report <- latest_qa_report(context.node),
         [_, target, target_state] <- Regex.run(@walkthrough_target_pattern, body),
         true <- target == issue.identifier and state_is?(issue.state, target_state) do
      [verification_blocked_action(context, report, target_state)]
    else
      _not_blocked -> []
    end
  end

  defp verification_blocked_action(%{issue: issue, node: node} = context, report, target_state) do
    parent = node["parent"] || %{}
    of_parent = "the final verification of #{parent["identifier"] || issue.identifier}"
    blocked_steps = @blocked_step_pattern |> Regex.scan(report.body, capture: :all_but_first) |> List.flatten()
    permissions? = Regex.match?(@permission_pattern, Enum.join([report.reason || "" | blocked_steps], "\n"))

    {title, fix} =
      if permissions?,
        do:
          {"Grant the QA host's permissions for #{of_parent}",
           "On the QA host, open System Settings > Privacy & Security and grant Screen Recording and Accessibility to the app the reason above names."},
        else: {"Unblock #{of_parent}", "Fix the cause above, on the machine QA runs on."}

    rerun =
      if state_is?(target_state, @gap_state),
        do: "#{issue.identifier} runs the walkthrough again by itself once the gap tickets that block it are done.",
        else: "Then move #{issue.identifier} to `#{@gap_state}` so the walkthrough runs again."

    project =
      case parent["project"] do
        %{"id" => project_id} = project when is_binary(project_id) -> %{id: project_id, name: project["name"]}
        _no_project -> context.project
      end

    action(%{context | project: project}, %{
      key: "verification:#{issue.id}",
      kind: :verification_blocked,
      title: title,
      why: "The Auto Review walkthrough could not test everything: #{report.reason || "see the QA report on #{issue.identifier}"}#{blocked_steps_text(blocked_steps)}",
      unblocks: of_parent,
      steps: [fix, rerun],
      done_when: "#{issue.identifier} leaves #{target_state}, or its next walkthrough is not blocked."
    })
  end

  defp blocked_steps_text([]), do: ""
  defp blocked_steps_text(steps), do: " Blocked steps: #{Enum.join(steps, "; ")}."

  defp latest_qa_report(node) do
    node
    |> comments()
    |> Enum.filter(&(is_binary(&1["body"]) and String.starts_with?(String.trim(&1["body"]), Report.heading())))
    |> Enum.max_by(&(&1["createdAt"] || ""), fn -> nil end)
    |> case do
      %{"body" => body} ->
        reason = capture(@reason_pattern, body)

        %{
          verdict: capture(@verdict_pattern, body),
          reason: reason,
          usage_limited?: is_binary(reason) and Regex.match?(@usage_limit_pattern, reason),
          body: body
        }

      nil ->
        nil
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
