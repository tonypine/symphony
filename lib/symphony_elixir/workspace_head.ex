defmodule SymphonyElixir.WorkspaceHead do
  @moduledoc """
  Reads the commit an issue workspace's `HEAD` points at, so the agent runner can tell
  whether a turn produced a commit, and whether that work is pushed.

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

  defp rev_parse_head(workspace) do
    case git(workspace, ["rev-parse", "--verify", "-q", "HEAD"]) do
      {output, 0} -> String.trim(output)
      _failure -> nil
    end
  end

  defp git(workspace, args), do: Workspace.safe_git(args, cd: workspace, stderr_to_stdout: true)
end
