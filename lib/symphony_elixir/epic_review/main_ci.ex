defmodule SymphonyElixir.EpicReview.MainCi do
  @moduledoc """
  The wait for CI on the base branch before an epic review is dispatched (TP-1476).

  The epic review judges the head of the base branch, and a commit whose workflow runs are still
  going cannot be judged yet. The check is made before dispatch, in the orchestrator's dispatch
  readiness task (`hold/3`): when the head of the epic's base branch has workflow runs still going,
  the epic is paused on that commit with an `:environment` reason (`reason/3`) that names the
  branch, the commit and the workflows still running, and no run is dispatched. The ticket is then
  listed under `dispatch_skipped` with that line, and its situation reads as the wait for CI.

  Nothing polls the wait. The completion of a workflow run on the commit (a `workflow_run` or
  `check_suite` delivery, `SymphonyElixir.PrWatch.Ingest`, or the release-build watch's read) calls
  `SymphonyElixir.CiWait.finished/2`, which lifts the reason once no run on the commit is still going
  (`settled?/3`); the lift asks the orchestrator for a dispatch cycle at once, so the epic review
  starts in the handling of the delivery for the last run. That cycle checks the base branch again:
  a branch that moved on to a commit with CI still going pauses the epic on the new commit, so the
  wait follows the head. At boot the waits are checked once (`recheck/1`), so an epic whose CI
  finished while Symphony was stopped is dispatched.

  The reason is releasable, so the Director may let the epic go with Unblock. A run still going
  after `stuck_seconds/0` is stuck, not waited on: the review runs and reports it. Anything that
  keeps the read from being sure (no GitHub repository, a failed read) is not waited on either, and
  the epic review's own check on the commit it fetched (`SymphonyElixir.EpicReview`) stays as the
  fallback.

  `opts` everywhere: `:gh_runner` (how `gh` is run), `:github_repo` (the repository, `owner/repo`,
  instead of the configured one's), `:branch` (instead of the configured base branch), `:now`,
  `:pauses` (default `SymphonyElixir.Pauses`) and `:run_store` (default `SymphonyElixir.RunStore`),
  over the application's `:main_ci_opts` (none in production; no GitHub repository in tests, so no
  test reads GitHub unless it says so).
  """

  require Logger

  alias SymphonyElixir.{CiWait, Config, Pauses, TicketState}
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repo.Status

  @setter %{kind: :rule, name: "CI wait"}
  # Longer than any healthy run of CI; a run still going after it is stuck, and the review reports it.
  @stuck_seconds 2 * 3600
  # The longest line a pause reason may have (`SymphonyElixir.Pauses`).
  @text_limit 300

  @doc "How long a workflow run may go before it counts as stuck and is no longer waited on."
  @spec stuck_seconds() :: pos_integer()
  def stuck_seconds, do: @stuck_seconds

  @doc """
  The workflow runs among `runs` still going at `now`: those without the `COMPLETED` status, less
  any started more than `stuck_seconds/0` ago.
  """
  @spec pending_runs([map()], DateTime.t()) :: [map()]
  def pending_runs(runs, %DateTime{} = now) when is_list(runs), do: Enum.filter(runs, &(unfinished?(&1) and not stuck?(&1, now)))

  defp unfinished?(%{status: status}), do: is_binary(status) and status != "COMPLETED"
  defp unfinished?(_run), do: false

  defp stuck?(%{created_at: %DateTime{} = created_at}, now), do: DateTime.diff(now, created_at) > @stuck_seconds
  defp stuck?(_run, _now), do: false

  @doc """
  Checks CI on the head of the base branch of `issue`'s repository (`repo_key`) before its epic
  review is dispatched. With workflow runs still going, pauses the epic on that commit and returns
  `{:waiting, info}`; otherwise, or when the read or the pause fails, `:ready`.
  """
  def hold(issue, repo_key, opts \\ [])

  @spec hold(Issue.t(), String.t() | nil, keyword()) :: :ready | {:waiting, CiWait.info()}
  def hold(%Issue{id: issue_id} = issue, repo_key, opts) when is_binary(issue_id) and is_binary(repo_key) do
    opts = with_defaults(opts)

    with {:pending, branch, sha, runs} <- base_ci(repo_key, opts),
         {:ok, _pause} <- pauses(opts).set({:ticket, repo_key, issue_id}, reason(branch, sha, runs), set_by: @setter) do
      Logger.info("Epic review for #{label(issue)} waits for CI on #{branch} at #{short(sha)}: #{names(runs)} still running; not dispatched until CI finishes")
      {:waiting, %{sha: sha, runs: runs}}
    else
      :settled ->
        :ready

      {:error, reason} ->
        Logger.warning("Could not hold the epic review for #{label(issue)} on CI: #{inspect(reason)}; dispatching it")
        :ready
    end
  end

  def hold(_issue, _repo_key, _opts), do: :ready

  @doc """
  The pause reason of an epic waiting for CI on `sha`, the head of `branch`, with `runs` still
  going: `Waiting for CI on <branch> at <commit>: <workflows> still running`. Its condition is the CI
  wait's (`SymphonyElixir.CiWait`), so the completion of CI on the commit lifts it, and it keeps the
  whole commit (`head`) for `recheck/1`.
  """
  @spec reason(String.t(), String.t(), [map()]) :: Pauses.reason_input()
  def reason(branch, sha, runs) when is_binary(branch) and is_binary(sha) and is_list(runs) do
    text = String.slice("Waiting for CI on #{branch} at #{short(sha)}: #{names(runs)} still running", 0, @text_limit)
    %{kind: :environment, waits_on: %{condition: "ci_wait:" <> short(sha), head: sha}, text: text, releasable: true}
  end

  @doc """
  Whether no workflow run on commit `sha` of `repo_key`'s repository is still going. A read that
  fails is settled: the wait is not kept on what can't be read, and the dispatch checks again.
  """
  @spec settled?(String.t(), String.t() | nil, keyword()) :: boolean()
  def settled?(sha, repo_key, opts) when is_binary(sha) do
    case commit_pending(repo_key, sha, with_defaults(opts)) do
      {:ok, [_ | _]} -> false
      _settled_or_unread -> true
    end
  end

  @doc """
  Checks every epic waiting for CI before dispatch once, as at boot: each wait whose commit has no
  workflow run still going is lifted (`SymphonyElixir.CiWait.finished/2`), which dispatches the epic.
  Returns the ids of the tickets lifted.
  """
  @spec recheck(keyword()) :: [String.t()]
  def recheck(opts) do
    opts = with_defaults(opts)

    opts
    |> waits()
    |> Enum.flat_map(&CiWait.finished(&1, opts))
  end

  @doc "Starts `recheck/1` in a task of its own, so boot never waits on GitHub."
  @spec start_recheck(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_recheck(opts \\ []) do
    Task.Supervisor.start_child(Keyword.get(opts, :supervisor, SymphonyElixir.TaskSupervisor), fn -> recheck(opts) end)
  catch
    :exit, reason ->
      Logger.warning("Failed to start the boot check of the epics waiting for CI: #{inspect(reason)}")
      {:error, reason}
  end

  # The commits the epics waiting before dispatch wait on.
  defp waits(opts) do
    case Keyword.get(opts, :run_store, SymphonyElixir.RunStore).list_all_ticket_states() do
      records when is_list(records) ->
        records
        |> Enum.flat_map(&(&1 |> TicketState.normalize() |> TicketState.pause_reasons()))
        |> Enum.flat_map(&wait_head/1)
        |> Enum.uniq()

      _error ->
        []
    end
  end

  defp wait_head(%{kind: :environment, waits_on: %{condition: "ci_wait:" <> _short, head: head}}) when is_binary(head), do: [head]
  defp wait_head(_reason), do: []

  defp base_ci(repo_key, opts) do
    branch = Keyword.get_lazy(opts, :branch, fn -> Config.base_branch(repo_key) end)

    with {:ok, repo} <- github_repo(repo_key, opts),
         {:ok, sha} <- PullRequest.branch_head(repo, branch, gh_opts(opts)),
         {:ok, [_ | _] = runs} <- pending(repo, sha, opts) do
      {:pending, branch, sha, runs}
    else
      {:ok, []} ->
        :settled

      {:error, reason} ->
        Logger.debug("Could not read CI on #{branch} before an epic review; not waiting for it: #{inspect(reason)}")
        :settled
    end
  end

  defp commit_pending(repo_key, sha, opts) do
    with {:ok, repo} <- github_repo(repo_key, opts), do: pending(repo, sha, opts)
  end

  defp pending(repo, sha, opts) do
    with {:ok, runs} <- PullRequest.list_commit_runs(sha, [repo: repo] ++ gh_opts(opts)),
         do: {:ok, pending_runs(runs, Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))}
  end

  defp github_repo(repo_key, opts) do
    case Keyword.get_lazy(opts, :github_repo, fn -> configured_github_repo(repo_key) end) do
      repo when is_binary(repo) and repo != "" -> {:ok, repo}
      _none -> {:error, :no_github_repository}
    end
  end

  defp configured_github_repo(repo_key) do
    case Config.repo(repo_key) do
      {:ok, repo} -> Status.github_repo(repo)
      {:error, _reason} -> nil
    end
  end

  defp with_defaults(opts), do: Keyword.merge(Application.get_env(:symphony_elixir, :main_ci_opts, []), opts)

  defp gh_opts(opts), do: Keyword.take(opts, [:gh_runner])
  defp pauses(opts), do: Keyword.get(opts, :pauses, Pauses)

  defp names(runs), do: runs |> Enum.map(&(Map.get(&1, :workflow_name) || "a workflow")) |> Enum.uniq() |> Enum.join(", ")
  defp short(sha), do: String.slice(sha, 0, 12)
  defp label(%Issue{identifier: identifier, id: id}), do: identifier || id
end
