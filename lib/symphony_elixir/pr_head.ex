defmodule SymphonyElixir.PrHead do
  @moduledoc """
  The ticket's pull request head as GitHub has it, and the workspace put on it before Code Review or
  QA judge the change.

  A workspace can hold something other than the pull request's head: it was made again while the
  branch it should continue was not there, or a person pushed to the branch since. Reviewing it, or
  reading its diff for QA, would judge that instead of the change. `sync/3` reads the head from
  GitHub and, when the workspace's `HEAD` differs, resets the workspace to it (fetching the branch
  first when the commit is missing), and logs both heads. `confirm_empty/2` asks GitHub whether the
  pull request changes no files, so an empty local diff is taken for no change only when GitHub
  agrees.

  GitHub is read with `opts[:gh_runner]`, else the `:pr_head_gh_runner` app env (tests keep it
  offline), else `gh`. A head that cannot be read leaves the workspace as it is.
  """

  require Logger

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{TicketPullRequest, Workspace, WorkspaceHead}

  @typedoc """
  `{:ok, head}` once the workspace is on the pull request's head; `:unknown` when there is no head
  to compare with (no open pull request, an SSH worker, GitHub unreadable); an error when the
  workspace could not be put on it.
  """
  @type sync_result :: {:ok, String.t()} | :unknown | {:error, term()}

  @doc """
  Puts the local `workspace` on the head of `issue`'s open pull request. `opts`: `:repo_key` (the
  lane's repo, for an issue read without one), `:worker_host` (an SSH worker's workspace is left
  alone) and `:gh_runner`.
  """
  @spec sync(Issue.t(), Path.t(), keyword()) :: sync_result()
  def sync(%Issue{} = issue, workspace, opts) when is_binary(workspace) do
    with nil <- Keyword.get(opts, :worker_host),
         pr_url when is_binary(pr_url) <- TicketPullRequest.current_url(issue, Keyword.get(opts, :repo_key)),
         {:ok, %{head_sha: sha, head_ref_name: branch}} when is_binary(branch) <- read(pr_url, opts) do
      put_on_head(issue, workspace, branch, sha)
    else
      {:error, reason} ->
        Logger.warning("Could not read the pull request head of #{label(issue)}; judging the workspace as it is: #{inspect(reason)}")
        :unknown

      _remote_no_pull_request_or_branch ->
        :unknown
    end
  end

  @doc """
  Whether GitHub too says the pull request at `pr_url` changes no files. `:empty` then, and for a
  ticket with no pull request (GitHub has nothing to say otherwise); an error when GitHub lists
  changed files, names no count or can't be read, so the caller never takes a local view for an
  empty change.
  """
  @spec confirm_empty(String.t() | nil, keyword()) :: :empty | {:error, term()}
  def confirm_empty(nil, _opts), do: :empty

  def confirm_empty(pr_url, opts) when is_binary(pr_url) do
    case read(pr_url, opts) do
      {:ok, %{changed_files: 0}} ->
        :empty

      {:ok, %{changed_files: count, head_sha: sha}} ->
        Logger.warning("The workspace diff of #{pr_url} is empty, but GitHub lists changed_files=#{inspect(count)} on head=#{sha}; not taking it for no change")
        {:error, {:pull_request_not_empty, count, sha}}

      {:error, reason} ->
        Logger.warning("Could not ask GitHub whether #{pr_url} changes any file; not taking an empty workspace diff for no change: #{inspect(reason)}")
        {:error, {:pull_request_unreadable, reason}}
    end
  end

  defp read(pr_url, opts), do: PullRequest.fetch_head(pr_url, gh_opts(opts))

  defp gh_opts(opts) do
    case Keyword.get(opts, :gh_runner) || Application.get_env(:symphony_elixir, :pr_head_gh_runner) do
      runner when is_function(runner, 2) -> [gh_runner: runner]
      _real_gh -> []
    end
  end

  defp put_on_head(issue, workspace, branch, sha) do
    case WorkspaceHead.read(workspace, nil) do
      ^sha ->
        {:ok, sha}

      local ->
        Logger.warning(
          "Workspace head differs from its pull request head; resetting the workspace to the pull request head #{label(issue)} " <>
            "workspace=#{workspace} workspace_head=#{local || "unknown"} pr_head=#{sha} branch=#{branch}"
        )

        with :ok <- ensure_commit(workspace, branch, sha),
             :ok <- Workspace.reset_to_commit(workspace, branch, sha) do
          {:ok, sha}
        else
          {:error, reason} -> {:error, {:pr_head_reset_failed, reason}}
        end
    end
  end

  defp ensure_commit(workspace, branch, sha) do
    if commit?(workspace, sha), do: :ok, else: fetch(workspace, branch, sha)
  end

  defp fetch(workspace, branch, sha) do
    case git(workspace, ["fetch", "origin", "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"]) do
      {_output, 0} -> if commit?(workspace, sha), do: :ok, else: {:error, {:commit_missing, sha}}
      {output, status} -> {:error, {:fetch_failed, status, output}}
    end
  end

  defp commit?(workspace, sha), do: match?({_output, 0}, git(workspace, ["cat-file", "-e", "#{sha}^{commit}"]))

  defp git(workspace, args), do: Workspace.safe_git(["-C", workspace | args], stderr_to_stdout: true)

  defp label(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp label(%Issue{id: id}), do: inspect(id)
end
