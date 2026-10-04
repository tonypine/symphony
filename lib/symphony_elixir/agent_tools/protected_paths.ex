defmodule SymphonyElixir.AgentTools.ProtectedPaths do
  @moduledoc """
  Finds a branch's own changes to the paths the agent sandbox write-protects in a workspace
  (`.ai/skills`, `WORKFLOW.md`, ...), and to the files a symlink in one of them points at
  (`priv/skills/pull` for `.ai/skills/pull -> ../../priv/skills/pull`).

  The sandbox keeps an agent from rewriting its own instructions, but git plumbing can still
  commit such a change without writing the file. `github_sync_base` and `github_push_branch` run
  outside the sandbox, so they refuse a branch that changes a protected path itself. Changes
  merged from the base branch don't count: the diff starts at the merge-base with it. Nor do files
  identical to the branch's remote copy: a person may have pushed them. So may an agent's shell
  `git push`, which this check never sees; only a check on the pull request itself covers that.
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
    with {:ok, paths} <- protected_paths([base_sha, head], run_git),
         {:ok, changed} <- changed_files(run_git, paths, ["#{base_sha}...#{head}"]),
         {:ok, changed} <- drop_pushed(changed, paths, head, remote_sha, run_git) do
      case changed do
        [] -> :ok
        files -> {:error, {:protected_paths_changed, files}}
      end
    end
  end

  # The protected paths plus the targets of the symlinks in them, read from each revision's tree.
  defp protected_paths(revisions, run_git) do
    paths = AgentSandboxConfig.workspace_protected_paths()

    list_links = fn paths ->
      with {:ok, links} <- revisions |> Enum.map(&tree_links(run_git, &1, paths)) |> all_ok() do
        {:ok, Enum.concat(links)}
      end
    end

    with {:ok, targets} <- AgentSandboxConfig.link_targets(paths, list_links) do
      {:ok, paths ++ targets}
    end
  end

  # `-z` keeps paths unquoted. A symlink is a mode 120000 blob that holds its target.
  defp tree_links(run_git, revision, paths) do
    with {:ok, output} <- run_git.(["ls-tree", "-r", "-z", revision, "--" | paths]) do
      for entry <- String.split(output, "\0", trim: true),
          ["120000", "blob", sha, path] <- [String.split(entry, [" ", "\t"], parts: 4)] do
        read_link(run_git, path, sha)
      end
      |> all_ok()
    end
  end

  defp read_link(run_git, path, sha) do
    with {:ok, target} <- run_git.(["cat-file", "blob", sha]), do: {:ok, {path, target}}
  end

  defp all_ok(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, values} -> {:cont, {:ok, values ++ [value]}}
      error, _values -> {:halt, error}
    end)
  end

  defp drop_pushed(changed, _paths, _head, nil, _run_git), do: {:ok, changed}
  defp drop_pushed([], _paths, _head, _remote_sha, _run_git), do: {:ok, []}

  defp drop_pushed(changed, paths, head, remote_sha, run_git) do
    with {:ok, unpushed} <- changed_files(run_git, paths, [remote_sha, head]) do
      {:ok, Enum.filter(changed, &(&1 in unpushed))}
    end
  end

  defp changed_files(run_git, paths, revisions) do
    with {:ok, output} <- run_git.(["diff", "--name-only", "--no-renames" | revisions] ++ ["--" | paths]) do
      {:ok, String.split(output, "\n", trim: true)}
    end
  end
end
