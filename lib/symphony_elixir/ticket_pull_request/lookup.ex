defmodule SymphonyElixir.TicketPullRequest.Lookup do
  @moduledoc """
  Finds a ticket's pull request on GitHub by its branch when Symphony holds no open record of it
  (`SymphonyElixir.TicketPullRequest`): a PR a person opened by hand, or one the startup backfill
  missed.

  It runs once per repo per poll cycle, on the tickets the poll just read from the tracker
  (`start/2`). When every one of them already has an `open` record it does nothing, so the steady
  state costs no GitHub request. Otherwise it lists the repo's open PRs in one GitHub query
  (`PullRequest.list_repo_open_pull_requests/2`), then in the same pass:

  - re-checks each `open` record whose PR is not in that list with one PR read, and marks it
    `closed` or `merged`;
  - records, with source `github_lookup`, the open PR whose head branch is a ticket's Symphony
    branch (`auto/<identifier>`) or its tracker branch name, for each ticket left with no `open`
    record.

  A PR on a branch of any other name is not found. The listing covers the 100 most recently updated
  open PRs. A GitHub failure is logged once and leaves every record as it is.
  """

  require Logger

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repo.Status
  alias SymphonyElixir.TicketPullRequest

  @open "open"

  @doc """
  Starts `sweep/3` for the repo a poll just read, under `supervisor` (the app's
  `SymphonyElixir.TaskSupervisor`), so a slow GitHub read never holds up the poll. `repo_result`
  is the poll's `{repo_name, {:ok, issues}}`; anything else (no repo due, a failed read) starts
  nothing, and neither does a supervisor that is not running.
  """
  def start(repo, repo_result, supervisor \\ SymphonyElixir.TaskSupervisor)

  @spec start(SystemSchema.Repo.t() | nil, term(), Supervisor.supervisor()) :: {:ok, pid()} | :ok
  def start(%SystemSchema.Repo{name: repo_key} = repo, {_repo_name, {:ok, issues}}, supervisor) when is_binary(repo_key) and is_list(issues) do
    opts = [github_repo: fn -> Status.github_repo(repo) end] ++ gh_opts([])
    {:ok, _pid} = Task.Supervisor.start_child(supervisor, fn -> sweep(repo_key, issues, opts) end)
  catch
    :exit, _reason -> :ok
  end

  def start(_repo, _repo_result, _supervisor), do: :ok

  @doc """
  Looks up the PRs of `repo_key`'s active tickets `issues` on GitHub. Options:

  - `:github_repo`: the repo's GitHub repository (`owner/repo`, or `host/owner/repo`), or a
    function returning it (or nil), called only when a listing is needed;
  - `:gh_runner`: how `gh` runs (`SymphonyElixir.GitHub.PullRequest`), defaulting to the
    `:ticket_pull_request_gh_runner` app env, else the real `gh`.
  """
  @spec sweep(String.t(), [Issue.t()], keyword()) :: :ok
  def sweep(repo_key, issues, opts) when is_binary(repo_key) and is_list(issues) and is_list(opts) do
    issues = for %Issue{id: id} = issue <- issues, is_binary(id), do: issue

    with {:ok, open_records} <- open_records(repo_key),
         true <- Enum.any?(issues, &(not Map.has_key?(open_records, &1.id))),
         slug when is_binary(slug) <- github_repo(Keyword.get(opts, :github_repo)),
         {:ok, pulls} <- list(repo_key, slug, gh_opts(opts)) do
      still_open = reconcile(repo_key, open_records, pulls, gh_opts(opts))

      issues
      |> Enum.reject(&Map.has_key?(still_open, &1.id))
      |> Enum.each(&match(repo_key, &1, pulls))
    end

    :ok
  end

  defp open_records(repo_key) do
    case TicketPullRequest.list(repo_key) do
      records when is_list(records) ->
        {:ok, for(%{state: @open, issue_id: issue_id} = record <- records, into: %{}, do: {issue_id, record})}

      {:error, reason} ->
        Logger.warning("Failed to read the ticket pull request records repo_key=#{repo_key}: #{inspect(reason)}")
        :error
    end
  end

  defp github_repo(fun) when is_function(fun, 0), do: fun.()
  defp github_repo(slug), do: slug

  defp gh_opts(opts) do
    case Keyword.get(opts, :gh_runner) || Application.get_env(:symphony_elixir, :ticket_pull_request_gh_runner) do
      runner when is_function(runner, 2) -> [gh_runner: runner]
      _real_gh -> []
    end
  end

  defp list(repo_key, slug, gh_opts) do
    case PullRequest.list_repo_open_pull_requests(slug, gh_opts) do
      {:ok, pulls} ->
        {:ok, pulls}

      {:error, reason} ->
        Logger.warning("Failed to list the open pull requests of #{slug} for repo_key=#{repo_key}; ticket pull request records unchanged: #{inspect(reason)}")
        :error
    end
  end

  # Re-checks each open record whose PR GitHub no longer lists open, marks the finished ones, and
  # returns the open records left.
  defp reconcile(repo_key, open_records, pulls, gh_opts) do
    listed = MapSet.new(pulls, & &1.url)

    Map.reject(open_records, fn {_issue_id, %{pr_url: pr_url}} ->
      not MapSet.member?(listed, pr_url) and finished?(repo_key, pr_url, gh_opts)
    end)
  end

  defp finished?(repo_key, pr_url, gh_opts) do
    case PullRequest.fetch_summary(pr_url, gh_opts) do
      {:ok, %{state: state}} when state in ["MERGED", "CLOSED"] ->
        TicketPullRequest.mark_finished(repo_key, pr_url, String.downcase(state))
        true

      {:ok, _still_open} ->
        false

      {:error, reason} ->
        Logger.warning("Failed to re-check the pull request #{pr_url} for repo_key=#{repo_key}; its record is unchanged: #{inspect(reason)}")
        false
    end
  end

  defp match(repo_key, %Issue{id: issue_id} = issue, pulls) do
    branches = branches(issue)

    with %{} = pull <- Enum.find(pulls, &(is_binary(&1.url) and &1.head_branch in branches)),
         {:error, reason} <- record(repo_key, issue, pull) do
      Logger.warning("Failed to record the pull request found on GitHub for issue_id=#{issue_id}: #{inspect(reason)}")
    end
  end

  # The ticket's Symphony branch (the workspace branch) and the tracker's branch name for it.
  defp branches(%Issue{identifier: identifier, branch_name: branch_name}) do
    [if(is_binary(identifier), do: "auto/" <> identifier), branch_name]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp record(repo_key, %Issue{id: issue_id, identifier: identifier}, %{url: url, head_branch: branch}) do
    with :ok <- TicketPullRequest.put(repo_key, issue_id, %{pr_url: url, branch: branch, source: "github_lookup"}) do
      Logger.info("Found the pull request #{url} of issue_identifier=#{identifier} on GitHub by its branch #{branch}")
    end
  end
end
