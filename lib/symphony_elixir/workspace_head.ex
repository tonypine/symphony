defmodule SymphonyElixir.WorkspaceHead do
  @moduledoc """
  Reads the commit an issue workspace's `HEAD` points at, so the agent runner can tell
  whether a turn produced a commit, and whether that work is pushed, and pushes work that isn't
  before the runner parks the ticket (`push_unpushed/3`).

  Only local workspaces are read. An SSH worker's workspace, a directory that is not a git
  checkout, or a repository without commits reads as nil, and callers treat nil as unknown.
  """

  alias SymphonyElixir.Workspace

  @wip_message "WIP: parked by Symphony"

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
  What the workspace holds that no remote has: the commits on `HEAD` no remote-tracking branch has
  (`unpushed_commits`, 0 for a checkout with no commit yet) and the files git does not ignore that
  differ from `HEAD` (`changed_files`, untracked ones included). Nil for an SSH worker's workspace or
  a directory that is not a checkout of its own. Reads local refs only, so it makes no network call.
  """
  @spec progress(Path.t() | nil, String.t() | nil) :: %{unpushed_commits: non_neg_integer(), changed_files: non_neg_integer()} | nil
  def progress(workspace, nil) when is_binary(workspace) do
    with true <- toplevel?(workspace),
         {status, 0} <- git(workspace, ["status", "--porcelain=v1", "--untracked-files=all"]) do
      %{unpushed_commits: unpushed_commits(workspace), changed_files: status |> String.split("\n", trim: true) |> length()}
    else
      _unreadable -> nil
    end
  end

  def progress(_workspace, _worker_host), do: nil

  defp unpushed_commits(workspace) do
    with {count, 0} <- git(workspace, ["rev-list", "--count", "HEAD", "--not", "--remotes"]),
         {count, ""} <- Integer.parse(String.trim(count)) do
      count
    else
      _no_commit -> 0
    end
  end

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

  @doc """
  Pushes the workspace's `HEAD` to its current branch on `origin`, whatever the remotes already
  hold, with the same origin check as `push_unpushed/3`: `SymphonyElixir.WorkspaceSync` pushes a
  head it found newer than the PR's. An SSH worker's workspace is not pushed.
  """
  @spec push_head(Path.t(), String.t() | nil, Path.t() | nil) :: {:pushed, String.t()} | {:error, term()}
  def push_head(workspace, nil, source_repo) when is_binary(workspace), do: push_branch(workspace, source_repo)
  def push_head(_workspace, worker_host, _source_repo), do: {:error, {:remote_worker, worker_host}}

  @doc """
  The workspace's current branch, or nil when `HEAD` is detached, the workspace is an SSH worker's
  or it cannot be read.
  """
  @spec branch(Path.t() | nil, String.t() | nil) :: String.t() | nil
  def branch(workspace, nil) when is_binary(workspace) do
    with true <- File.dir?(workspace),
         {:ok, branch} <- current_branch(workspace) do
      branch
    else
      _unreadable -> nil
    end
  end

  def branch(_workspace, _worker_host), do: nil

  @doc """
  A digest of the workspace's uncommitted changes (tracked and untracked files git does not
  ignore, with their contents), or nil when the tree is clean or the workspace cannot be read. Two
  turns that leave the same digest changed nothing in the tree; a turn that edits, adds or removes a
  file changes it. Reads only: it writes no object and touches no index.
  """
  @spec worktree_digest(Path.t() | nil, String.t() | nil) :: String.t() | nil
  def worktree_digest(workspace, nil) when is_binary(workspace) do
    with true <- toplevel?(workspace),
         {status, 0} when status != "" <- git(workspace, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]),
         {diff, 0} <- git(workspace, ["diff", "HEAD", "--binary", "--no-ext-diff"]),
         {untracked, 0} <- git(workspace, ["ls-files", "-z", "--others", "--exclude-standard"]) do
      untracked
      |> String.split(<<0>>, trim: true)
      |> Enum.map(&untracked_content(workspace, &1))
      |> then(&[status, diff | &1])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    else
      _clean_or_unreadable -> nil
    end
  end

  def worktree_digest(_workspace, _worker_host), do: nil

  @doc """
  Commits every uncommitted change of the workspace (`git add -A`, then a commit `WIP: parked by Symphony`
  that skips the repo's hooks) on its current branch, so a parked ticket's work is never only in its
  working tree: `{:committed, sha}`, `:nothing` when the tree is clean (or the workspace is an SSH
  worker's, or not a checkout of its own), or an error. `push_unpushed/3` pushes the commit after.
  """
  @spec commit_worktree(Path.t() | nil, String.t() | nil) :: {:committed, String.t()} | :nothing | {:error, term()}
  def commit_worktree(workspace, nil) when is_binary(workspace) do
    with true <- toplevel?(workspace),
         {status, 0} <- git(workspace, ["status", "--porcelain=v1", "--untracked-files=all"]),
         false <- String.trim(status) == "" do
      commit_all(workspace)
    else
      {output, status} when is_integer(status) -> {:error, {:status_failed, status, String.trim(output)}}
      _clean_or_not_a_checkout -> :nothing
    end
  end

  def commit_worktree(_workspace, _worker_host), do: :nothing

  defp commit_all(workspace) do
    with {:ok, _branch} <- current_branch(workspace),
         {_output, 0} <- git(workspace, ["add", "-A"]),
         {_output, 0} <- git(workspace, identity(workspace) ++ ["commit", "--no-verify", "-m", @wip_message]),
         {sha, 0} <- git(workspace, ["rev-parse", "HEAD"]) do
      {:committed, String.trim(sha)}
    else
      {output, status} when is_integer(status) -> {:error, {:commit_failed, status, String.trim(output)}}
      {:error, _reason} = error -> error
    end
  end

  # The workspace's own author when its git config names one, else Symphony's, so a checkout with no
  # identity configured still gets its commit.
  defp identity(workspace) do
    Enum.flat_map([{"user.name", "Symphony"}, {"user.email", "symphony@localhost"}], fn {key, default} ->
      case git(workspace, ["config", "--get", key]) do
        {value, 0} when value != "" -> ["-c", "#{key}=#{String.trim(value)}"]
        _unset -> ["-c", "#{key}=#{default}"]
      end
    end)
  end

  # Only the workspace's own checkout: a directory inside another repository is not the ticket's.
  defp toplevel?(workspace) do
    with true <- File.dir?(workspace),
         {output, 0} <- git(workspace, ["rev-parse", "--show-toplevel"]) do
      same_dir?(String.trim(output), workspace)
    else
      _not_a_checkout -> false
    end
  end

  # The same directory, symlinks resolved: git names the top level by its real path.
  defp same_dir?(left, right) do
    with {:ok, %File.Stat{inode: inode, major_device: device}} <- File.stat(left),
         {:ok, %File.Stat{inode: ^inode, major_device: ^device}} <- File.stat(right) do
      true
    else
      _other -> false
    end
  end

  defp untracked_content(workspace, path) do
    case File.read(Path.join(workspace, path)) do
      {:ok, content} -> [path, <<0>>, content]
      {:error, reason} -> [path, <<0>>, Atom.to_string(reason)]
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
