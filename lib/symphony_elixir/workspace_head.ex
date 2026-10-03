defmodule SymphonyElixir.WorkspaceHead do
  @moduledoc """
  Reads the commit an issue workspace's `HEAD` points at, so the agent runner can tell
  whether a turn produced a commit.

  Only local workspaces are read. An SSH worker's workspace, a directory that is not a git
  checkout, or a repository without commits reads as nil, and callers treat nil as unknown.
  """

  alias SymphonyElixir.Workspace

  @spec read(Path.t(), String.t() | nil) :: String.t() | nil
  def read(workspace, nil) when is_binary(workspace) do
    if File.dir?(workspace), do: rev_parse_head(workspace), else: nil
  end

  def read(_workspace, _worker_host), do: nil

  defp rev_parse_head(workspace) do
    case Workspace.safe_git(["rev-parse", "--verify", "-q", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _failure -> nil
    end
  end
end
