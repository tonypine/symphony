defmodule SymphonyElixir.ProtectedPathsGate do
  @moduledoc """
  Holds back the landing of a `Merging` pull request whose `protected paths` check failed.

  The `protected paths` CI job (`mix protected_paths.check`) fails a pull request whose own commits
  change an agent-protected path, but the base branch doesn't require it, so GitHub auto-merge
  would merge past it. The PR and CI watcher asks `check/4` when that check is the only red one on a
  `Merging` head (`SymphonyElixir.PrWatch.Repo`): the head lands only when the ticket's
  `SymphonyElixir.PathUnlock` grants, a person's decisions, cover every protected path the pull
  request changes; until then it waits for a person (rule R18).

  The changed paths are read with git in the ticket's workspace as the CI job reads them
  (`SymphonyElixir.AgentTools.ProtectedPaths.verify/5`, with the granted paths left out), between
  the pull request's base and head commits, fetched from `origin` when the workspace lacks them. A
  read that fails holds the landing back, as an uncovered path does.
  """

  alias SymphonyElixir.AgentTools.ProtectedPaths
  alias SymphonyElixir.{PathUnlock, Workspace}
  alias SymphonyElixir.Repo.Fetcher

  @typedoc "`:ok` to land, `{:blocked, reason}` to hold the landing back."
  @type result :: :ok | {:blocked, String.t()}

  @doc """
  Whether the PR may land with `failed`, the names of the human-only checks that failed on its head.
  `pr` gives the ticket's `workspace_path` and the PR's `base_sha` and `head_sha`; `issue` is the
  ticket as the watcher read it, or nil. `opts[:git]` overrides the git runner (tests): it is called
  as `git.(args, cwd)` and returns `{output, status}`.
  """
  @spec check([String.t()], map(), map() | nil, keyword()) :: result()
  def check(failed, pr, issue, opts \\ [])
  def check([], _pr, _issue, _opts), do: :ok
  def check(failed, pr, issue, opts), do: covered(pr, issue, Enum.join(failed, ", "), opts)

  defp covered(pr, issue, names, opts) do
    case granted_paths(issue) do
      [] ->
        {:blocked, "#{names} failed and no decision on the ticket unlocks the protected paths the PR changes"}

      granted ->
        case uncovered(pr, granted, Keyword.get(opts, :git, &default_git/2)) do
          {:ok, []} -> :ok
          {:ok, paths} -> {:blocked, "#{names} failed and no decision on the ticket unlocks #{Enum.join(paths, ", ")}"}
          {:error, reason} -> {:blocked, "#{names} failed and the protected paths the PR changes couldn't be read: #{reason}"}
        end
    end
  end

  defp granted_paths(nil), do: []
  defp granted_paths(issue), do: issue |> PathUnlock.grants() |> PathUnlock.paths()

  defp uncovered(pr, granted, git) do
    workspace = Map.get(pr, :workspace_path)
    base = Map.get(pr, :base_sha)
    head = Map.get(pr, :head_sha)

    cond do
      not (is_binary(workspace) and File.dir?(workspace)) -> {:error, "the ticket has no workspace"}
      not is_binary(base) -> {:error, "the PR's base commit is unknown"}
      true -> read_uncovered(workspace, base, head, granted, git)
    end
  end

  defp read_uncovered(workspace, base, head, granted, git) do
    with :ok <- ensure_commits(workspace, [base, head], git) do
      diff(base, head, granted, fn args -> run_git(git, args, workspace) end)
    end
  end

  defp diff(base, head, granted, run_git) do
    case ProtectedPaths.verify(base, head, nil, run_git, granted) do
      :ok -> {:ok, []}
      {:error, {:protected_paths_changed, files}} -> {:ok, files}
      {:error, {:git_failed, args, status, output}} -> {:error, git_error(args, status, output)}
    end
  end

  # A commit the workspace lacks (the base moved, GitHub merged the base branch in) is fetched
  # under the repo's fetch lock: the workspace shares its `.git` with the source checkout.
  defp ensure_commits(workspace, shas, git) do
    Enum.reduce_while(shas, :ok, fn sha, :ok ->
      case ensure_commit(workspace, sha, git) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp ensure_commit(workspace, sha, git) do
    with {_output, status} when status != 0 <- git.(["cat-file", "-e", sha <> "^{commit}"], workspace),
         {output, status} when status != 0 <- Fetcher.fetch(workspace, fn -> git.(["fetch", "--quiet", "origin", sha], workspace) end) do
      {:error, git_error(["fetch", "origin", sha], status, output)}
    else
      {_output, 0} -> :ok
    end
  end

  defp run_git(git, args, workspace) do
    case git.(args, workspace) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  end

  defp git_error(args, status, output) do
    detail = output |> to_string() |> String.trim()
    "git #{Enum.join(args, " ")} exited #{status}" <> if(detail == "", do: "", else: ": #{detail}")
  end

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)
end
