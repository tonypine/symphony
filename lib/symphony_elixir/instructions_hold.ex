defmodule SymphonyElixir.InstructionsHold do
  @moduledoc """
  Holds every ticket of Symphony's own repository while the running build is behind the base
  branch on the files the prompt rendering must agree with (TP-1416).

  A run reads its instructions (`.symphony/instructions/*.md`, `WORKFLOW.md`) from the ticket's
  checkout of the base branch, but renders them with the running build's prompt builder and its
  variables. A merged pull request that changes both makes every run between its merge and the
  app's update fail on a variable the old build does not supply, whatever the ticket's
  `skip-update-hold` label says. So while the base branch changed one of `renderer_paths/0` since the
  commit the running build was built from, each ticket of the build's repository is held for the
  build that includes the base branch's head: a `:build` reason on its pause
  (`waits_on: %{commit: sha}`), set by the rule "Instructions update hold", that reads "Holding for
  the v0.0.1.839 build: the instructions on main need it". The `skip-update-hold` label does not
  opt out.

  `resolve/4`, in the poll task, compares the running build's commit with the base branch on GitHub
  (`SymphonyElixir.GitHub.PullRequest.compare_to_branch/4`) and brings each polled ticket's pause in
  line: held while the build is behind on those files, released once it is not (the app updated),
  so the same poll dispatches it. A compare that fails changes nothing. A build with no sha or
  repository (a build from a checkout), or a repo that is not the build's, holds nothing.

  A run whose first prompt fails to render asks `check/2`: when the build is behind, the run
  exits as `{:instructions_behind, behind}` and the orchestrator holds the ticket (`hold/3`) instead
  of retrying it; on a current build the failure is a plain failure.
  """

  require Logger

  alias SymphonyElixir.{BuildInfo, Config, Pauses, ReleaseBuild}
  alias SymphonyElixir.GitHub.{PullRequest, Repo}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repo.Status, as: RepoStatus

  @renderer_paths [
    "lib/symphony_elixir/prompt_builder.ex",
    "lib/symphony_elixir/workflow.ex",
    "lib/symphony_elixir/playbook/"
  ]
  @setter %{kind: :rule, name: "Instructions update hold"}
  @default_branch "main"

  @typedoc """
  The running build behind the base branch: the base branch's head it waits on (`commit`), the
  commits the build lacks (`commits`, complete unless `total_commits` says more), the renderer files
  changed (`files`) and the branch's name.
  """
  @type behind :: %{
          commit: String.t(),
          commits: [String.t()],
          total_commits: non_neg_integer(),
          files: [String.t()],
          branch: String.t()
        }

  @doc "The files (or folders, ending in `/`) the prompt rendering of a run must agree with."
  @spec renderer_paths() :: [String.t()]
  def renderer_paths, do: @renderer_paths

  @doc """
  Whether the running build is behind `repo_key`'s base branch on `renderer_paths/0`: `{:ok,
  behind}` when it is, `{:ok, nil}` when it is not (or the repo is not the build's, or the build has
  no sha), `{:error, reason}` when the compare failed.

  Options: `:build` (default `SymphonyElixir.BuildInfo.current/0`), `:github_repo` (`repo_key ->
  "owner/name" | nil`), `:base_branch` (`repo_key -> branch | nil`) and `:compare` (`repo, sha,
  branch -> {:ok, compare} | {:error, term}`, default
  `SymphonyElixir.GitHub.PullRequest.compare_to_branch/3`).
  """
  @spec check(String.t() | nil, keyword()) :: {:ok, behind() | nil} | {:error, term()}
  def check(repo_key, opts \\ []) do
    build = Keyword.get_lazy(opts, :build, &BuildInfo.current/0)

    with %{sha: build_sha, repo: build_repo} when is_binary(build_sha) and is_binary(build_repo) <- build,
         true <- is_binary(repo_key),
         gh_repo when is_binary(gh_repo) <- github_repo(repo_key, opts),
         true <- Repo.same?(gh_repo, Repo.gh_repo_from_url(build_repo)) do
      branch = base_branch(repo_key, opts) || @default_branch
      compare = Keyword.get(opts, :compare, &PullRequest.compare_to_branch/3)

      with {:ok, result} <- compare.(gh_repo, build_sha, branch) do
        {:ok, behind(result, branch)}
      end
    else
      _not_the_build_repo -> {:ok, nil}
    end
  end

  # The base branch is ahead of (or diverged from) the build and changed a renderer file since.
  defp behind(%{status: status, files: files, commits: [_ | _] = commits} = result, branch) when status in ["ahead", "diverged"] do
    case Enum.filter(files, &renderer_file?/1) do
      [] ->
        nil

      changed ->
        %{commit: List.last(commits), commits: commits, total_commits: Map.get(result, :total_commits, length(commits)), files: changed, branch: branch}
    end
  end

  defp behind(_result, _branch), do: nil

  defp renderer_file?(file), do: Enum.any?(@renderer_paths, &(file == &1 or (String.ends_with?(&1, "/") and String.starts_with?(file, &1))))

  @doc """
  Brings the pause of each of `issues` (polled tickets of `repo_key`) in line with `check/2`: while
  the build is behind, each ticket holds one reason waiting on the base branch's head (one it holds
  already stays while the build still lacks its commit); once the build is not behind, every such
  reason is cleared. A failed compare changes nothing. Returns what `check/2` said. `opts`: those of
  `check/2`.
  """
  @spec resolve([Issue.t()], String.t() | nil, keyword()) :: {:ok, behind() | nil} | {:error, term()}
  def resolve(issues, repo_key, opts \\ []) do
    tickets =
      for %Issue{id: issue_id} = issue when is_binary(issue_id) <- issues,
          do: {issue.repo_key || repo_key, issue}

    if tickets == [] do
      {:ok, nil}
    else
      repo_key |> check(opts) |> sync_tickets(tickets, repo_key)
    end
  end

  defp sync_tickets({:ok, behind} = result, tickets, _repo_key) do
    Enum.each(tickets, fn {ticket_repo_key, issue} -> sync(ticket_repo_key, issue, behind) end)
    result
  end

  defp sync_tickets({:error, reason} = result, _tickets, repo_key) do
    Logger.debug("Could not compare the running build with the base branch of #{repo_key}: #{inspect(reason)}")
    result
  end

  defp sync(repo_key, %Issue{id: issue_id} = issue, nil) do
    case reasons(repo_key, issue_id) do
      [] ->
        :ok

      held ->
        Enum.each(held, &Pauses.clear_reason({:ticket, repo_key, issue_id}, &1, by: @setter))
        Logger.info("Released from the instructions update hold: issue_id=#{issue_id} issue_identifier=#{issue.identifier}")
    end
  end

  defp sync(repo_key, %Issue{id: issue_id} = issue, behind) do
    {kept, arrived} = repo_key |> reasons(issue_id) |> Enum.split_with(&still_lacking?(&1, behind))
    Enum.each(arrived, &Pauses.clear_reason({:ticket, repo_key, issue_id}, &1, by: @setter))
    if kept == [], do: put(repo_key, issue, behind)
    :ok
  end

  # The build still lacks the commit a reason waits on while it is among the commits the build
  # lacks, or while that list is cut short and can't say.
  defp still_lacking?(%{waits_on: %{commit: commit}}, behind) do
    commit in behind.commits or behind.total_commits > length(behind.commits)
  end

  @doc """
  Holds `repo_key`'s ticket `issue_id` for the build `behind` waits on: the run whose prompt failed
  to render while the build was behind. `:ok` when the reason is on its pause.
  """
  @spec hold(String.t() | nil, Issue.t() | map(), behind()) :: :ok | {:error, term()}
  def hold(repo_key, %{id: issue_id} = issue, %{commit: _commit} = behind) when is_binary(repo_key) and is_binary(issue_id) do
    if reasons(repo_key, issue_id) == [], do: put(repo_key, issue, behind), else: :ok
  end

  def hold(_repo_key, _issue, _behind), do: {:error, :no_ticket}

  defp put(repo_key, %{id: issue_id} = issue, behind) do
    case Pauses.set({:ticket, repo_key, issue_id}, reason(behind.commit), set_by: @setter) do
      {:ok, _pause} ->
        Logger.info("Holding for an app update: issue_id=#{issue_id} issue_identifier=#{Map.get(issue, :identifier)}; #{line(behind.commit)}")
        :ok

      {:error, reason} ->
        Logger.warning("Could not hold #{Map.get(issue, :identifier)} for the build the instructions need: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp reason(commit), do: %{kind: :build, waits_on: %{commit: commit}, text: line(commit)}

  @doc "Whether a pause reason is one this hold set."
  @spec reason?(Pauses.reason() | term()) :: boolean()
  def reason?(%{kind: :build, waits_on: %{commit: commit}, set_by: @setter}) when is_binary(commit), do: true
  def reason?(_reason), do: false

  @doc "The reasons this hold set on the pause of `repo_key`'s ticket `issue_id`."
  @spec reasons(String.t() | nil, String.t() | nil) :: [Pauses.reason()]
  def reasons(repo_key, issue_id) when is_binary(repo_key) and is_binary(issue_id) do
    case Pauses.get({:ticket, repo_key, issue_id}) do
      {:ok, %{reasons: reasons}} -> Enum.filter(reasons, &reason?/1)
      _none -> []
    end
  end

  def reasons(_repo_key, _issue_id), do: []

  @doc """
  A reason's line as a person reads it, naming the build it waits on once its release run is known
  (`SymphonyElixir.ReleaseBuild.get/2`): "Holding for the v0.0.1.839 build: the instructions on
  main need it", else "Holding for the build of 1a2b3c4: the instructions on main need it".
  `opts`: those of `ReleaseBuild.get/2`.
  """
  @spec line(String.t(), keyword()) :: String.t()
  def line(commit, opts \\ []) when is_binary(commit) do
    build =
      case ReleaseBuild.get(commit, opts) do
        %{number: number} when is_integer(number) -> "v#{BuildInfo.release_version(number)} build"
        _unknown -> "build of #{BuildInfo.short_sha(commit)}"
      end

    "Holding for the #{build}: the instructions on #{@default_branch} need it"
  end

  @doc "The lines of `reasons` (`reasons/2`), each as `line/2` reads it now."
  @spec lines([Pauses.reason()], keyword()) :: [String.t()]
  def lines(reasons, opts \\ []), do: for(%{waits_on: %{commit: commit}} <- reasons, do: line(commit, opts))

  defp github_repo(repo_key, opts) do
    case Keyword.fetch(opts, :github_repo) do
      {:ok, fun} -> fun.(repo_key)
      :error -> with %{} = repo <- configured_repo(repo_key), do: RepoStatus.github_repo(repo)
    end
  end

  defp base_branch(repo_key, opts) do
    case Keyword.fetch(opts, :base_branch) do
      {:ok, fun} -> fun.(repo_key)
      :error -> repo_key |> configured_repo() |> configured_branch()
    end
  end

  defp configured_branch(%{base_branch: branch}) when is_binary(branch) and branch != "", do: branch
  defp configured_branch(_repo), do: nil

  defp configured_repo(repo_key) do
    with {:ok, repos} <- Config.repos(), do: Enum.find(repos, &(&1.name == repo_key))
  end
end
