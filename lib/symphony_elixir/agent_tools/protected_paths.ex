defmodule SymphonyElixir.AgentTools.ProtectedPaths do
  @moduledoc """
  Finds a branch's own changes to the paths the agent sandbox write-protects in a workspace
  (`.ai/skills`, `WORKFLOW.md`, ...).

  The sandbox keeps an agent from rewriting its own instructions, but git plumbing can still
  commit such a change without writing the file. `github_sync_base` and `github_push_branch` run
  outside the sandbox, so they refuse a branch that changes a protected path itself. Changes
  merged from the base branch don't count: the diff starts at the merge-base with it. Nor do files
  identical to the branch's remote copy, which a person pushed.
  """

  alias SymphonyElixir.AgentSandboxConfig

  @type git_runner :: ([String.t()] -> {:ok, String.t()} | {:error, term()})

  @doc """
  Returns `:ok` when `head` changes no protected path since it forked from `base_sha`. Files
  identical to `remote_sha`, the branch's remote copy (`nil` when it has none), don't count.
  """
  @spec verify(String.t(), String.t(), String.t() | nil, git_runner()) ::
          :ok | {:error, {:protected_paths_changed, [String.t()]}} | {:error, term()}
  def verify(base_sha, head, remote_sha, run_git) do
    with {:ok, changed} <- changed_files(run_git, ["#{base_sha}...#{head}"]),
         {:ok, changed} <- drop_pushed(changed, head, remote_sha, run_git) do
      case changed do
        [] -> :ok
        files -> {:error, {:protected_paths_changed, files}}
      end
    end
  end

  defp drop_pushed(changed, _head, nil, _run_git), do: {:ok, changed}
  defp drop_pushed([], _head, _remote_sha, _run_git), do: {:ok, []}

  defp drop_pushed(changed, head, remote_sha, run_git) do
    with {:ok, unpushed} <- changed_files(run_git, [remote_sha, head]) do
      {:ok, Enum.filter(changed, &(&1 in unpushed))}
    end
  end

  defp changed_files(run_git, revisions) do
    paths = AgentSandboxConfig.workspace_protected_paths()

    with {:ok, output} <- run_git.(["diff", "--name-only", "--no-renames" | revisions] ++ ["--" | paths]) do
      {:ok, String.split(output, "\n", trim: true)}
    end
  end
end
