defmodule SymphonyElixir.HumanActions.CiSecrets do
  @moduledoc """
  Lists a GitHub Actions workflow on a repository's base branch that keeps failing on a missing
  secret, as a `:ci_secret` human action.

  For each repository, one `gh run list` reads the latest runs on its base branch (newest first).
  A workflow whose two latest finished runs both failed (cancelled and skipped runs aside) has the
  failed-step log of its latest run read, with `gh run view --log-failed` as the CI poller reads a
  PR's. Each secret that log names as missing becomes one action, in the update of every project
  the repository routes. The next green run of the workflow breaks the streak, so the action
  drops out of the next update.

  Only secret names are taken from a log, never values. A run's log is read once: the names found
  are kept by run id while the run stays the latest failure of its workflow. When GitHub or Linear
  cannot be read for a repository, its last actions stay listed, so a failed read does not close
  and reopen them.
  """

  require Logger

  alias SymphonyElixir.AutoReview
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.HumanActions.{Action, Collector}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Repo.Status, as: RepoStatus

  @est_minutes 5
  @max_secrets_per_run 5
  @project_first 10
  @name "[A-Za-z_][A-Za-z0-9_]*"
  @upper_name "[A-Z_][A-Z0-9_]{2,}"
  @quote "[`'\"]?"
  @missing "(?i:(?:is\\s+|was\\s+|has\\s+)?(?:not\\s+(?:been\\s+)?(?:set|configured|provided|defined|found|available)|missing|empty|unset|undefined|required))"

  @secret_patterns [
    # ${{ secrets.SIGNING_KEY }} is empty / Error: secrets.SIGNING_KEY not set
    Regex.compile!("secrets\\.(#{@name})\\b(?=.*?#{@missing})"),
    # secret SIGNING_KEY is not set / Secret `SIGNING_KEY` missing
    Regex.compile!("(?i:\\bsecret)\\s*:?\\s*#{@quote}(#{@upper_name})#{@quote}\\s+#{@missing}"),
    # Missing secret: SIGNING_KEY / missing required secret SIGNING_KEY
    Regex.compile!("(?i:\\b(?:missing|required|empty|unset|undefined)\\s+(?:(?:required|repository|github)\\s+)?secrets?)\\s*:?\\s*#{@quote}(#{@upper_name})\\b"),
    # The SIGNING_KEY secret is not set
    Regex.compile!("#{@quote}\\b(#{@upper_name})#{@quote}\\s+(?i:secret)\\s+#{@missing}")
  ]

  @projects_query """
  query SymphonyHumanActionsRepoProjects($filter: ProjectFilter!, $first: Int!) {
    projects(filter: $filter, first: $first) {
      nodes { id name }
    }
  }
  """

  @typedoc "A workflow whose latest runs failed: its name, its latest run, and how many failed in a row."
  @type failing_workflow :: %{name: String.t(), latest: PullRequest.workflow_run(), failures: pos_integer()}

  @typedoc """
  What one read leaves for the next: per repository, the secret names found per failed run id
  and the last actions listed; and the projects found per project filter.
  """
  @type cache :: %{
          optional(:repos) => %{String.t() => %{logs: %{String.t() => [String.t()]}, actions: [Action.t()]}},
          optional(:projects) => %{map() => [%{id: String.t(), name: String.t() | nil}]}
        }

  @doc """
  The `:ci_secret` actions of `repos`, by project id, and the cache for the next read.

  Options: `:settings` (the tracker settings route a repository to its projects),
  `:linear_client` (`(query, variables, opts)` GraphQL function), `:github` (a module with
  `list_branch_runs/3` and `fetch_failed_log/2`, default `SymphonyElixir.GitHub.PullRequest`),
  `:github_repo` (repo -> GitHub repository or nil) and `:base_branch` (repo key -> branch).
  """
  @spec collect([term()], cache(), keyword()) :: {%{String.t() => Collector.project_actions()}, cache()}
  def collect(repos, cache, opts) do
    {actions, cache} =
      Enum.reduce(repos, {[], cache}, fn repo, {acc, cache} ->
        {actions, cache} = repo_actions(repo, cache, opts)
        {acc ++ actions, cache}
      end)

    collected =
      actions
      |> Enum.uniq_by(&{&1.project.id, &1.key})
      |> Enum.group_by(& &1.project.id)
      |> Map.new(fn {project_id, [first | _] = project_actions} -> {project_id, %{project: first.project, actions: project_actions}} end)

    {collected, cache}
  end

  defp repo_actions(repo, cache, opts) do
    github = Keyword.get(opts, :github, PullRequest)
    repo_key = repo.name
    previous = get_in(cache, [:repos, repo_key]) || %{logs: %{}, actions: []}

    # A repository routed to no project has no update to list its actions in: GitHub is not read.
    with {:ok, project_filter} <- Client.repo_project_filter(repo, Keyword.fetch!(opts, :settings).tracker),
         gh_repo when is_binary(gh_repo) <- Keyword.get(opts, :github_repo, &RepoStatus.github_repo/1).(repo),
         branch = Keyword.get(opts, :base_branch, &AutoReview.base_branch/1).(repo_key),
         {:ok, runs} <- github.list_branch_runs(gh_repo, branch, []),
         {:ok, failing} <- read_logs(failing_workflows(runs), gh_repo, previous.logs, github),
         {:ok, projects, cache} <- projects(project_filter, failing, cache, opts) do
      target = %{repo: gh_repo, branch: branch}

      actions =
        for {workflow, secrets} <- failing, secret <- secrets, project <- projects do
          action(target, workflow, secret, project)
        end

      logs = Map.new(failing, fn {workflow, secrets} -> {workflow.latest.id, secrets} end)
      {actions, put_in(cache, [Access.key(:repos, %{}), repo_key], %{logs: logs, actions: actions})}
    else
      none when none in [nil, :none] ->
        {[], cache}

      {:error, reason} ->
        Logger.warning("Human actions: could not read the failing workflows of #{repo_key}: #{inspect(reason)}")
        {previous.actions, cache}
    end
  end

  @doc """
  The workflows of `runs` (newest first, as `gh run list` returns them) whose two latest finished
  runs failed, with their latest run and how many runs in a row failed. Cancelled and skipped runs
  are neither red nor green.
  """
  @spec failing_workflows([PullRequest.workflow_run()]) :: [failing_workflow()]
  def failing_workflows(runs) do
    runs
    |> Enum.filter(&finished?/1)
    |> Enum.group_by(& &1.workflow_name)
    |> Enum.flat_map(fn {name, [latest | _] = finished} ->
      case Enum.take_while(finished, &(&1.conclusion == "FAILURE")) do
        [_first, _second | _rest] = failed -> [%{name: name, latest: latest, failures: length(failed)}]
        _streak -> []
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp finished?(run) do
    run.status == "COMPLETED" and run.conclusion not in ["CANCELLED", "SKIPPED"] and is_binary(run.workflow_name) and is_binary(run.id)
  end

  # Keeps only the workflows whose log names a missing secret.
  defp read_logs(workflows, gh_repo, logs, github) do
    Enum.reduce_while(workflows, {:ok, []}, fn workflow, {:ok, acc} ->
      case secrets_of(workflow.latest.id, gh_repo, logs, github) do
        {:ok, []} -> {:cont, {:ok, acc}}
        {:ok, secrets} -> {:cont, {:ok, acc ++ [{workflow, secrets}]}}
        {:error, reason} -> {:halt, {:error, {:failed_log_unavailable, workflow.latest.id, reason}}}
      end
    end)
  end

  defp secrets_of(run_id, gh_repo, logs, github) do
    case Map.fetch(logs, run_id) do
      {:ok, secrets} ->
        {:ok, secrets}

      :error ->
        with {:ok, log} <- github.fetch_failed_log(run_id, repo: gh_repo), do: {:ok, missing_secrets(log)}
    end
  end

  @doc """
  The secret names a failed-step log says are missing: an empty `${{ secrets.X }}`, or messages
  such as `secret X is not set`, `Missing secret: X` or `the X secret is empty`. Names only,
  upcased as GitHub stores them, at most #{@max_secrets_per_run}.
  """
  @spec missing_secrets(String.t()) :: [String.t()]
  def missing_secrets(log) when is_binary(log) do
    log
    |> String.split("\n")
    |> Enum.flat_map(fn line -> Enum.flat_map(@secret_patterns, &Regex.scan(&1, line, capture: :all_but_first)) end)
    |> List.flatten()
    |> Enum.map(&String.upcase/1)
    |> Enum.uniq()
    |> Enum.take(@max_secrets_per_run)
  end

  defp projects(_filter, [], cache, _opts), do: {:ok, [], cache}

  defp projects(filter, _failing, cache, opts) do
    case get_in(cache, [:projects, filter]) do
      projects when is_list(projects) -> {:ok, projects, cache}
      nil -> fetch_projects(filter, cache, opts)
    end
  end

  defp fetch_projects(filter, cache, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    case linear_client.(@projects_query, %{filter: filter, first: @project_first}, []) do
      {:ok, %{"data" => %{"projects" => %{"nodes" => nodes}}}} when is_list(nodes) ->
        projects = for %{"id" => id} = node <- nodes, is_binary(id), do: %{id: id, name: node["name"]}
        {:ok, projects, put_in(cache, [Access.key(:projects, %{}), filter], projects)}

      other ->
        {:error, {:linear_projects_query_failed, other}}
    end
  end

  defp action(target, workflow, secret, project) do
    %Action{
      key: "ci_secret:#{target.repo}:#{workflow.name}:#{secret}",
      kind: :ci_secret,
      title: "Add the `#{secret}` secret",
      why:
        "The `#{workflow.name}` workflow has failed on `#{target.branch}` #{workflow.failures} times in a row, " <>
          "and the log of its latest run says the `#{secret}` secret is not set.",
      unblocks: "the `#{workflow.name}` workflow on `#{target.branch}` in #{target.repo}",
      est_minutes: @est_minutes,
      steps:
        [
          "Open #{secrets_url(target.repo)} (the repository's Settings → Secrets and variables → Actions).",
          "Click New repository secret, name it `#{secret}`, and paste its value.",
          rerun_step(workflow.latest.url)
        ]
        |> Enum.reject(&is_nil/1),
      done_when: "the next run of `#{workflow.name}` on `#{target.branch}` is green.",
      issue: nil,
      project: project
    }
  end

  defp rerun_step(url) when is_binary(url), do: "Re-run the failed run: #{url}"
  defp rerun_step(_url), do: nil

  defp secrets_url(gh_repo) do
    case String.split(gh_repo, "/") do
      [owner, name] -> "https://github.com/#{owner}/#{name}/settings/secrets/actions"
      [host, owner, name] -> "https://#{host}/#{owner}/#{name}/settings/secrets/actions"
    end
  end
end
