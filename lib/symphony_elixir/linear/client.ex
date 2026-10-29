defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger

  alias SymphonyElixir.{
    AuditLog,
    Config,
    Connected,
    IssueSummary,
    Linear.Issue,
    Linear.IssueNormalizer,
    Secret,
    StateMachine
  }

  alias SymphonyElixir.Linear.{RateLimit, Usage}

  @issue_page_size 50
  # Kept small: every polled issue pays for this nested connection in Linear query complexity.
  @sub_issue_page_size 20
  @enrichment_comment_last 20
  @enrichment_relation_first 50
  @max_error_body_log_bytes 1_000
  # Upload URLs in descriptions and comments need Linear's key unless the response signs them.
  # Six hours outlasts a run (the default turn timeout is one hour); agent reads re-sign each time.
  @signed_file_url_ttl_seconds 21_600
  @team_id_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  @operation_name_pattern ~r/^\s*(?:query|mutation)\s+([A-Za-z_][A-Za-z0-9_]*)/

  @query """
  query SymphonyLinearPoll($filter: IssueFilter!, $first: Int!, $relationFirst: Int!, $commentLast: Int!, $after: String) {
    issues(filter: $filter, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        team {
          key
          name
        }
        project {
          id
          name
          slugId
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        comments(last: $commentLast, orderBy: createdAt) {
          nodes {
            id
            body
            createdAt
            parent {
              id
            }
            user {
              name
            }
          }
        }
        children(first: #{@sub_issue_page_size}) {
          nodes {
            id
            identifier
            state {
              name
            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!, $commentLast: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        team {
          key
          name
        }
        project {
          id
          name
          slugId
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        comments(last: $commentLast, orderBy: createdAt) {
          nodes {
            id
            body
            createdAt
            parent {
              id
            }
            user {
              name
            }
          }
        }
        children(first: #{@sub_issue_page_size}) {
          nodes {
            id
            identifier
            state {
              name
            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @query_by_identifier """
  query SymphonyLinearIssueByIdentifier($id: String!, $relationFirst: Int!, $commentLast: Int!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      priority
      state {
        name
      }
      team {
        key
        name
      }
      project {
        id
        name
        slugId
      }
      branchName
      url
      assignee {
        id
      }
      labels {
        nodes {
          name
        }
      }
      comments(last: $commentLast, orderBy: createdAt) {
        nodes {
          id
          body
          createdAt
          parent {
            id
          }
          user {
            name
          }
        }
      }
      children(first: #{@sub_issue_page_size}) {
        nodes {
          id
          identifier
          state {
            name
          }
        }
      }
      inverseRelations(first: $relationFirst) {
        nodes {
          type
          issue {
            id
            identifier
            state {
              name
            }
          }
        }
      }
      createdAt
      updatedAt
    }
  }
  """

  @viewer_id_cache_key {__MODULE__, :viewer_id}

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @enrichment_query """
  query SymphonyLinearIssueEnrichment($id: String!, $commentLast: Int!, $relationFirst: Int!) {
    issue(id: $id) {
      description
      comments(last: $commentLast, orderBy: createdAt) {
        nodes {
          body
          createdAt
          user {
            name
          }
        }
      }
      relations(first: $relationFirst) {
        nodes {
          type
          relatedIssue {
            identifier
            title
            state {
              name
            }
          }
        }
      }
      parent {
        identifier
        title
        children(first: #{@sub_issue_page_size}) {
          nodes {
            createdAt
            state {
              type
            }
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, context} <- repo_poll_context(),
         {:ok, repo_results} <-
           fetch_repo_issue_results(context.repos, dispatch_states_for(context.tracker), context.tracker, &graphql/2) do
      {:ok, aggregate_repo_results(repo_results).dispatchable}
    end
  end

  @spec fetch_candidate_issues_for_repo(term()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues_for_repo(repo) do
    with {:ok, context} <- repo_poll_context() do
      do_fetch_repo_by_states(repo, StateMachine.tracker_active_states(context.tracker), context.tracker)
    end
  end

  # Dispatch picks work up from the machine's active states: the tracker's configured active states
  # plus the phase states.
  defp dispatch_states_for(tracker), do: fn _repo -> StateMachine.tracker_active_states(tracker) end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_by_identifier(identifier) when is_binary(identifier) do
    do_fetch_issue_by_identifier(identifier, &graphql/2)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      with {:ok, context} <- repo_poll_context(),
           {:ok, repo_results} <-
             fetch_repo_issue_results(context.repos, normalized_states, context.tracker, &graphql/2) do
        {:ok, dedupe_repo_issues(repo_results)}
      end
    end
  end

  @doc """
  The issues in these states across every configured repo, with the repos whose read failed
  (`{repo_name, reason}`), for callers that must say a list is partial. Errors when every repo fails.
  """
  @spec fetch_issues_by_states_with_failures([String.t()]) ::
          {:ok, [Issue.t()], [{String.t(), term()}]} | {:error, term()}
  def fetch_issues_by_states_with_failures(state_names) when is_list(state_names) do
    do_fetch_issues_by_states_with_failures(state_names, &graphql/2)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec fetch_issue_enrichment(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_enrichment(%Issue{} = issue) do
    do_fetch_issue_enrichment(issue, &graphql(&1, &2, sign_file_urls: true))
  end

  def fetch_issue_enrichment(_issue), do: {:error, :invalid_issue}

  @doc """
  Runs a Linear GraphQL request with Symphony's key.

  `sign_file_urls: true` asks Linear to pre-sign the upload URLs in the response, so an agent
  without the key can download the images and files in a description or comment. Only reads
  that feed an agent set it: a signed URL written back into Linear would stop working.
  """
  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)
    now_ms_fun = Keyword.get(opts, :now_ms_fun, &RateLimit.now_ms/0)

    with gate when gate in [:ok, :probe] <- RateLimit.check(now_ms_fun.()),
         {:ok, headers} <- graphql_headers(Keyword.get(opts, :sign_file_urls, false)) do
      RateLimit.record_request()
      Usage.record(Map.get(payload, "operationName") || operation_name(query))

      payload
      |> request_fun.(headers)
      |> handle_graphql_response(payload, now_ms_fun.(), gate == :probe)
    else
      {:error, {:linear_rate_limited, _retry_ms}} = error -> error
      {:error, reason} -> graphql_request_failed(reason)
    end
  end

  defp handle_graphql_response({:ok, response}, payload, now_ms, probe?) do
    case RateLimit.record_response(response, now_ms, probe?) do
      {:rate_limited, retry_ms} ->
        Logger.warning(
          "Linear rate limit reached; pausing Linear requests until " <>
            "#{retry_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()}, then probing" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_rate_limited, retry_ms}}

      :resumed ->
        Logger.info("Linear rate-limit probe succeeded; resuming Linear requests")
        graphql_response_result(response, payload)

      :ok ->
        graphql_response_result(response, payload)
    end
  end

  defp handle_graphql_response({:error, reason}, _payload, _now_ms, _probe?), do: graphql_request_failed(reason)

  defp graphql_response_result(%{status: 200, body: body}, _payload), do: {:ok, body}

  defp graphql_response_result(response, payload) do
    Logger.error(
      "Linear GraphQL request failed status=#{response.status}" <>
        linear_error_context(payload, response)
    )

    {:error, {:linear_api_status, response.status, Map.get(response, :body)}}
  end

  defp graphql_request_failed(reason) do
    Logger.error("Linear GraphQL request failed: #{AuditLog.redact_for_log(reason)}")
    {:error, {:linear_api_request, reason}}
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    IssueNormalizer.from_graphql_node(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    IssueNormalizer.from_graphql_node(issue, assignee_filter)
  end

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_enrichment_for_test(
          Issue.t(),
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_enrichment_for_test(%Issue{} = issue, graphql_fun)
      when is_function(graphql_fun, 2) do
    do_fetch_issue_enrichment(issue, graphql_fun)
  end

  @doc false
  @spec reset_viewer_cache_for_test() :: :ok
  def reset_viewer_cache_for_test do
    :persistent_term.erase(@viewer_id_cache_key)
    :ok
  end

  @doc false
  @spec assignee_filter_ids_for_test(term()) :: [String.t()] | nil
  def assignee_filter_ids_for_test(assignee_filter), do: assignee_filter_ids(assignee_filter)

  @doc false
  @spec fetch_candidate_issues_for_test((String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues_for_test(graphql_fun) when is_function(graphql_fun, 2) do
    with {:ok, context} <- repo_poll_context(),
         {:ok, repo_results} <-
           fetch_repo_issue_results(context.repos, dispatch_states_for(context.tracker), context.tracker, graphql_fun) do
      {:ok, aggregate_repo_results(repo_results).dispatchable}
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, graphql_fun)
      when is_list(state_names) and is_function(graphql_fun, 2) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      with {:ok, context} <- repo_poll_context(),
           {:ok, repo_results} <-
             fetch_repo_issue_results(context.repos, normalized_states, context.tracker, graphql_fun) do
        {:ok, dedupe_repo_issues(repo_results)}
      end
    end
  end

  @doc false
  @spec fetch_issues_by_states_with_failures_for_test(
          [String.t()],
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) ::
          {:ok, [Issue.t()], [{String.t(), term()}]} | {:error, term()}
  def fetch_issues_by_states_with_failures_for_test(state_names, graphql_fun)
      when is_list(state_names) and is_function(graphql_fun, 2) do
    do_fetch_issues_by_states_with_failures(state_names, graphql_fun)
  end

  @doc false
  @spec fetch_issue_by_identifier_for_test(String.t(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_by_identifier_for_test(identifier, graphql_fun)
      when is_binary(identifier) and is_function(graphql_fun, 2) do
    do_fetch_issue_by_identifier(identifier, graphql_fun)
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter(graphql_fun) do
          do_fetch_issue_states(ids, assignee_filter, graphql_fun)
        end
    end
  end

  defp repo_poll_context do
    tracker = Config.settings!().tracker

    if is_nil(tracker.api_key) do
      {:error, :missing_linear_api_token}
    else
      with {:ok, repos} <- Config.repos() do
        {:ok, %{tracker: tracker, repos: repos}}
      end
    end
  end

  defp do_fetch_issues_by_states_with_failures(state_names, graphql_fun) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, [], []}
    else
      with {:ok, context} <- repo_poll_context() do
        context.repos
        |> collect_repo_issue_results(states_reader(normalized_states), context.tracker, graphql_fun)
        |> issues_with_failures()
      end
    end
  end

  defp issues_with_failures({[], [_ | _] = errors}), do: {:error, {:repo_poll_failed, errors}}
  defp issues_with_failures({results, errors}), do: {:ok, dedupe_repo_issues(results), errors}

  defp fetch_repo_issue_results(repos, states, tracker, graphql_fun)
       when is_list(repos) and is_function(graphql_fun, 2) do
    states_for_repo = states_reader(states)
    {results, errors} = collect_repo_issue_results(repos, states_for_repo, tracker, graphql_fun)

    cond do
      errors == [] ->
        {:ok, results}

      results != [] ->
        Logger.warning("Linear repo poll returned partial results; failed repos: #{inspect(errors)}")
        {:ok, results}

      true ->
        {:error, {:repo_poll_failed, errors}}
    end
  end

  # Callers that poll one fixed state list for every repo pass it directly; callers whose states
  # depend on the repo (its resolved state machine) pass a function.
  defp states_reader(states) when is_list(states), do: fn _repo -> states end
  defp states_reader(states_for_repo) when is_function(states_for_repo, 1), do: states_for_repo

  defp collect_repo_issue_results(repos, states_for_repo, tracker, graphql_fun) do
    {results, errors} =
      Enum.reduce(repos, {[], []}, fn repo, {results, errors} ->
        repo_key = repo_key(repo)

        case do_fetch_repo_by_states(repo, states_for_repo.(repo), tracker, graphql_fun: graphql_fun) do
          {:ok, issues} -> {[{repo_key, issues} | results], errors}
          {:error, reason} -> {results, [{repo_key, reason} | errors]}
        end
      end)

    {Enum.reverse(results), Enum.reverse(errors)}
  end

  defp do_fetch_repo_by_states(repo, state_names, tracker, opts \\ []) do
    graphql_fun = Keyword.get(opts, :graphql_fun, &graphql/2)

    with {:ok, filter} <- repo_issue_filter(repo, tracker, state_names, graphql_fun) do
      do_fetch_by_states_page(filter, nil, [], graphql_fun)
    end
  end

  @doc """
  The issue filter a repo route polls with (team, project, labels and assignee), without a state
  clause, for callers that query the same scope with their own conditions.
  """
  @spec repo_scope_filter(term()) :: {:ok, map()} | {:error, term()}
  def repo_scope_filter(repo) do
    with {:ok, context} <- repo_poll_context() do
      repo_issue_filter(repo, context.tracker, nil, &graphql/2)
    end
  end

  @doc """
  The project filter for the projects a repo route polls: its `projects`, else the tracker's
  `project_slug`. `:none` when the route names no project (it routes by team or label alone).
  """
  @spec repo_project_filter(term(), map()) :: {:ok, map()} | :none
  def repo_project_filter(repo, tracker) do
    case {repo_projects(repo), effective_project_slug(repo, tracker)} do
      {[], slug} when is_binary(slug) -> {:ok, %{"slugId" => %{"eq" => slug}}}
      {[], _slug} -> :none
      {projects, _slug} -> {:ok, project_filter_clause(projects)}
    end
  end

  defp repo_issue_filter(repo, tracker, state_names, graphql_fun) do
    with {:ok, assignee_filter} <- repo_assignee_filter(repo, tracker, graphql_fun) do
      {labels, label_mode} = effective_labels(repo, tracker)

      {:ok,
       build_issue_filter(
         state_names: state_names,
         project_slug: effective_project_slug(repo, tracker),
         projects: repo_projects(repo),
         team: effective_team(repo, tracker),
         labels: labels,
         label_mode: label_mode,
         assignee_ids: assignee_filter_ids(assignee_filter)
       )}
    end
  end

  defp do_fetch_by_states_page(filter, after_cursor, acc_issues, graphql_fun) do
    with {:ok, body} <-
           graphql_fun.(@query, %{
             filter: filter,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             commentLast: @enrichment_comment_last,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, nil) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(filter, next_cursor, updated_acc, graphql_fun)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_issue_filter(opts) do
    %{}
    |> maybe_put("state", opts[:state_names], &%{"name" => %{"in" => &1}})
    |> maybe_put("project", opts[:project_slug], &%{"slugId" => %{"eq" => &1}})
    |> maybe_put("project", opts[:projects], &project_filter_clause/1)
    |> maybe_put("team", opts[:team], &team_filter_clause/1)
    |> put_label_filters(opts[:labels], opts[:label_mode])
    |> maybe_put("assignee", opts[:assignee_ids], &%{"id" => %{"in" => &1}})
  end

  @doc false
  @spec aggregate_repo_results([{String.t(), [Issue.t()]}]) :: %{
          dispatchable: [Issue.t()],
          conflicts: [Issue.t()]
        }
  def aggregate_repo_results(repo_results) when is_list(repo_results) do
    grouped =
      repo_results
      |> Enum.flat_map(fn {repo_key, issues} ->
        issues
        |> Enum.reject(&is_nil(issue_id(&1)))
        |> Enum.map(&{issue_id(&1), repo_key, tag_issue_repo(&1, repo_key)})
      end)
      |> Enum.group_by(fn {issue_id, _repo_key, _issue} -> issue_id end)

    {conflicts, dispatchable} =
      grouped
      |> Enum.map(fn {_issue_id, entries} -> aggregate_issue_entries(entries) end)
      |> Enum.split_with(fn %Issue{conflict_repo_keys: repo_keys} -> length(repo_keys) > 1 end)

    %{
      dispatchable: sort_issues(dispatchable),
      conflicts: sort_issues(conflicts)
    }
  end

  defp aggregate_issue_entries(entries) do
    repo_keys =
      entries
      |> Enum.map(fn {_issue_id, repo_key, _issue} -> repo_key end)
      |> Enum.uniq()
      |> Enum.sort()

    {_issue_id, first_repo_key, issue} =
      Enum.min_by(entries, fn {_issue_id, repo_key, issue} ->
        {repo_key, issue.identifier || issue.id || ""}
      end)

    case repo_keys do
      [_repo_key] -> %{issue | repo_key: first_repo_key, conflict_repo_keys: []}
      repo_keys -> %{issue | repo_key: nil, conflict_repo_keys: repo_keys}
    end
  end

  defp dedupe_repo_issues(repo_results) do
    repo_results
    |> aggregate_repo_results()
    |> then(fn %{dispatchable: dispatchable, conflicts: conflicts} -> sort_issues(dispatchable ++ conflicts) end)
  end

  defp tag_issue_repo(%Issue{} = issue, repo_key), do: %{issue | repo_key: repo_key, conflict_repo_keys: []}
  defp tag_issue_repo(issue, _repo_key), do: issue

  defp issue_id(%Issue{id: id}) when is_binary(id) and id != "", do: id
  defp issue_id(_issue), do: nil

  defp sort_issues(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue -> {issue.identifier || "", issue.id || ""}
      _issue -> {"", ""}
    end)
  end

  defp effective_team(repo, tracker), do: normalize_string(repo_value(repo, :team) || tracker.team)

  defp effective_project_slug(repo, tracker) do
    case repo_projects(repo) do
      [] -> tracker.project_slug
      _projects -> nil
    end
  end

  defp repo_projects(repo), do: repo_value(repo, :projects) |> normalized_string_list()

  defp effective_labels(repo, tracker) do
    case repo_value(repo, :labels) |> normalized_string_list() do
      [] -> {tracker.labels, :any}
      labels -> {labels, :all}
    end
  end

  defp repo_assignee_filter(repo, tracker, graphql_fun) do
    case repo_value(repo, :assignee) || tracker.assignee do
      nil -> {:ok, nil}
      assignee -> build_assignee_filter(assignee, graphql_fun)
    end
  end

  defp repo_key(repo) do
    repo_value(repo, :name) || repo_value(repo, "name") || inspect(repo)
  end

  defp repo_value(repo, key) when is_atom(key) do
    cond do
      is_map(repo) and Map.has_key?(repo, key) -> Map.get(repo, key)
      is_map(repo) and Map.has_key?(repo, Atom.to_string(key)) -> Map.get(repo, Atom.to_string(key))
      true -> nil
    end
  end

  defp repo_value(repo, key) when is_binary(key) do
    if is_map(repo) and Map.has_key?(repo, key) do
      Map.get(repo, key)
    end
  end

  defp normalized_string_list(nil), do: []

  defp normalized_string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalized_string_list(value), do: normalized_string_list([value])

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp project_filter_clause(projects) when is_list(projects) do
    projects = normalized_string_list(projects)
    project_ids = Enum.filter(projects, &Regex.match?(@team_id_pattern, &1))

    [
      %{"name" => %{"in" => projects}},
      %{"slugId" => %{"in" => projects}},
      project_ids != [] && %{"id" => %{"in" => project_ids}}
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> case do
      [filter] -> filter
      filters -> %{"or" => filters}
    end
  end

  defp put_label_filters(filter, labels, :all) do
    labels = normalized_string_list(labels)

    case labels do
      [] ->
        filter

      [label] ->
        Map.put(filter, "labels", %{"some" => %{"name" => %{"eqIgnoreCase" => label}}})

      labels ->
        label_filters =
          Enum.map(labels, fn label ->
            %{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => label}}}}
          end)

        Map.update(filter, "and", label_filters, &(&1 ++ label_filters))
    end
  end

  defp put_label_filters(filter, labels, _mode) do
    maybe_put(filter, "labels", labels, &%{"some" => %{"name" => %{"in" => &1}}})
  end

  defp maybe_put(filter, _key, nil, _builder), do: filter
  defp maybe_put(filter, _key, [], _builder), do: filter
  defp maybe_put(filter, key, value, builder), do: Map.put(filter, key, builder.(value))

  defp team_filter_clause(team) when is_binary(team) do
    if Regex.match?(@team_id_pattern, team) do
      %{"id" => %{"eq" => team}}
    else
      %{"key" => %{"eq" => team}}
    end
  end

  defp assignee_filter_ids(%{match_values: match_values}) when is_struct(match_values, MapSet) do
    match_values
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp assignee_filter_ids(nil), do: nil

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    with {:ok, body} <-
           graphql_fun.(@query_by_ids, %{
             ids: batch_ids,
             first: length(batch_ids),
             relationFirst: @issue_page_size,
             commentLast: @enrichment_comment_last
           }),
         {:ok, issues} <- decode_linear_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)
      do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
    end
  end

  defp do_fetch_issue_enrichment(%Issue{id: issue_id} = issue, graphql_fun)
       when is_function(graphql_fun, 2) do
    case normalize_issue_id(issue_id) do
      nil ->
        {:error, :missing_issue_id}

      id ->
        with {:ok, body} <-
               graphql_fun.(@enrichment_query, %{
                 id: id,
                 commentLast: @enrichment_comment_last,
                 relationFirst: @enrichment_relation_first
               }),
             {:ok, enrichment} <- decode_issue_enrichment_response(body) do
          {:ok,
           %{
             issue
             | description: IssueSummary.strip(Map.get(enrichment, "description", issue.description)),
               comments: IssueNormalizer.comments(enrichment),
               linked_issues: extract_linked_issues(enrichment),
               parent: Connected.parent(enrichment["parent"])
           }}
        end
    end
  end

  defp do_fetch_issue_by_identifier(identifier, graphql_fun)
       when is_binary(identifier) and is_function(graphql_fun, 2) do
    case normalize_issue_id(identifier) do
      nil ->
        {:error, :missing_issue_identifier}

      id ->
        with {:ok, body} <-
               graphql_fun.(@query_by_identifier, %{
                 id: id,
                 relationFirst: @issue_page_size,
                 commentLast: @enrichment_comment_last
               }) do
          decode_linear_issue_response(body, nil)
        end
    end
  end

  defp normalize_issue_id(issue_id) when is_binary(issue_id) do
    case String.trim(issue_id) do
      "" -> nil
      id -> id
    end
  end

  defp normalize_issue_id(_issue_id), do: nil

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp operation_name(query) do
    case Regex.run(@operation_name_pattern, query, capture: :all_but_first) do
      [name] -> name
      nil -> nil
    end
  end

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> AuditLog.redact_for_log(printable_limit: @max_error_body_log_bytes)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
  end

  defp summarize_error_body(body) do
    body
    |> AuditLog.redact_for_log(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers(sign_file_urls?) do
    case Config.settings!().tracker.api_key |> Secret.unwrap() do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
           | signed_file_url_headers(sign_file_urls?)
         ]}
    end
  end

  defp signed_file_url_headers(true), do: [{"public-file-urls-expire-in", Integer.to_string(@signed_file_url_ttl_seconds)}]
  defp signed_file_url_headers(_sign_file_urls?), do: []

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&IssueNormalizer.from_graphql_node(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp decode_linear_issue_response(%{"data" => %{"issue" => issue}}, assignee_filter) when is_map(issue) do
    case IssueNormalizer.from_graphql_node(issue, assignee_filter) do
      %Issue{} = issue -> {:ok, issue}
      nil -> {:error, :linear_invalid_issue}
    end
  end

  defp decode_linear_issue_response(%{"data" => %{"issue" => nil}}, _assignee_filter), do: {:error, :issue_not_found}

  defp decode_linear_issue_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_issue_response(_unknown, _assignee_filter), do: {:error, :linear_unknown_payload}

  defp decode_issue_enrichment_response(%{"data" => %{"issue" => issue}}) when is_map(issue) do
    {:ok, issue}
  end

  defp decode_issue_enrichment_response(%{"data" => %{"issue" => nil}}), do: {:error, :issue_not_found}

  defp decode_issue_enrichment_response(%{"errors" => errors}) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_issue_enrichment_response(_unknown), do: {:error, :linear_unknown_payload}

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter(graphql_fun \\ &graphql/2) do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee, graphql_fun)
    end
  end

  defp build_assignee_filter(assignee, graphql_fun \\ &graphql/2) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter(graphql_fun)

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter(graphql_fun) when is_function(graphql_fun, 2) do
    with {:ok, viewer_id} <- cached_viewer_id(graphql_fun) do
      {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
    end
  end

  # The user behind an API key never changes, so `assignee: me` asks Linear once per key instead
  # of once per poll and repo. One entry holds the current key's viewer, so a key change replaces it.
  defp cached_viewer_id(graphql_fun) do
    api_key_hash = :erlang.phash2(Secret.unwrap(Config.settings!().tracker.api_key))

    case :persistent_term.get(@viewer_id_cache_key, nil) do
      {^api_key_hash, viewer_id} ->
        {:ok, viewer_id}

      _missing_or_other_key ->
        with {:ok, viewer_id} <- fetch_viewer_id(graphql_fun) do
          :persistent_term.put(@viewer_id_cache_key, {api_key_hash, viewer_id})
          {:ok, viewer_id}
        end
    end
  end

  defp fetch_viewer_id(graphql_fun) do
    case graphql_fun.(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil -> {:error, :missing_linear_viewer_identity}
          viewer_id -> {:ok, viewer_id}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_linked_issues(%{"relations" => %{"nodes" => relations}}) when is_list(relations) do
    Enum.flat_map(relations, &normalize_linked_issue/1)
  end

  defp extract_linked_issues(_issue), do: []

  defp normalize_linked_issue(%{"type" => relation_type, "relatedIssue" => related_issue})
       when is_binary(relation_type) and is_map(related_issue) do
    case normalize_relation_type(relation_type) do
      relation when relation in ["related", "blocks"] ->
        case related_issue["identifier"] do
          identifier when is_binary(identifier) and identifier != "" ->
            [
              %{
                relation: relation,
                identifier: identifier,
                title: related_issue["title"],
                state: get_in(related_issue, ["state", "name"])
              }
            ]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp normalize_linked_issue(_relation), do: []

  defp normalize_relation_type(relation_type) when is_binary(relation_type) do
    relation_type
    |> String.trim()
    |> String.downcase()
  end
end
