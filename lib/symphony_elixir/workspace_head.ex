defmodule SymphonyElixir.WorkspaceHead do
  @moduledoc """
  Reads the commit an issue workspace's `HEAD` points at, so the agent runner can tell
  whether a turn produced a commit, and whether that work is pushed, and pushes work that isn't
  before the runner parks the ticket (`push_unpushed/3`).

  Only local workspaces are read. An SSH worker's workspace, a directory that is not a git
  checkout, or a repository without commits reads as nil, and callers treat nil as unknown.
  """

  alias SymphonyElixir.Workspace

  @spec read(Path.t(), String.t() | nil) :: String.t() | nil
  def read(workspace, nil) when is_binary(workspace) do
    if File.dir?(workspace), do: rev_parse_head(workspace), else: nil
  end

  def read(_workspace, _worker_host), do: nil

  @doc """
  The workspace `HEAD` when it has commits no remote-tracking branch has (work the agent committed
  but has not pushed), or nil when everything is pushed or the workspace cannot be read. A checkout
  with no remote-tracking branch at all reads as nil too. Reads local refs only, so it makes no
  network call.
  """
  @spec unpushed_head(Path.t() | nil, String.t() | nil) :: String.t() | nil
  def unpushed_head(workspace, nil) when is_binary(workspace) do
    with head when is_binary(head) <- read(workspace, nil),
         {remote_ref, 0} when remote_ref != "" <- git(workspace, ["for-each-ref", "--count=1", "refs/remotes"]),
         {output, 0} <- git(workspace, ["rev-list", "-n", "1", "HEAD", "--not", "--remotes"]),
         false <- String.trim(output) == "" do
      head
    else
      _pushed_or_unreadable -> nil
    end
  end

  def unpushed_head(_workspace, _worker_host), do: nil

  @doc """
  Pushes the workspace's current branch to `origin` when it has commits no remote has
  (`unpushed_head/2`), so a parked ticket's work is never only in its workspace. Returns `:pushed`
  with the branch, `:nothing` when there is nothing to push (or the workspace is an SSH worker's,
  which is not read), or an error. The push goes only to the origin of `source_repo` (the repo the
  workspace was cloned from): every push URL of the workspace's `origin` must be that one, so a
  rewritten remote is refused. It is Symphony's own push of the agent's commits, not a handoff, so
  it skips the repo's hooks.
  """
  @spec push_unpushed(Path.t() | nil, String.t() | nil, Path.t() | nil) ::
          {:pushed, String.t()} | :nothing | {:error, term()}
  def push_unpushed(workspace, worker_host, source_repo) do
    case unpushed_head(workspace, worker_host) do
      nil -> :nothing
      _head -> push_branch(workspace, source_repo)
    end
  end

  defp push_branch(workspace, source_repo) do
    with {:ok, branch} <- current_branch(workspace),
         :ok <- verify_origin(workspace, source_repo),
         {_output, 0} <- git(workspace, ["push", "--no-verify", "origin", "HEAD:refs/heads/" <> branch]) do
      {:pushed, branch}
    else
      {output, status} when is_integer(status) -> {:error, {:push_failed, status, String.trim(output)}}
      {:error, _reason} = error -> error
    end
  end

  defp current_branch(workspace) do
    with {output, 0} <- git(workspace, ["branch", "--show-current"]),
         branch when branch != "" <- String.trim(output) do
      {:ok, branch}
    else
      _detached -> {:error, :no_current_branch}
    end
  end

  defp verify_origin(workspace, source_repo) when is_binary(source_repo) do
    with {expected, 0} <- Workspace.safe_git(["-C", source_repo, "remote", "get-url", "origin"], stderr_to_stdout: true),
         {urls, 0} <- git(workspace, ["remote", "get-url", "--push", "--all", "origin"]),
         [_ | _] = urls <- String.split(urls, "\n", trim: true),
         true <- Enum.all?(urls, &(String.trim(&1) == String.trim(expected))) do
      :ok
    else
      _mismatch -> {:error, :origin_mismatch}
    end
  end

  defp verify_origin(_workspace, _source_repo), do: {:error, :origin_mismatch}

  defp rev_parse_head(workspace) do
    case git(workspace, ["rev-parse", "--verify", "-q", "HEAD"]) do
      {output, 0} -> String.trim(output)
      _failure -> nil
    end
  end

  defp git(workspace, args), do: Workspace.safe_git(args, cd: workspace, stderr_to_stdout: true)
end
