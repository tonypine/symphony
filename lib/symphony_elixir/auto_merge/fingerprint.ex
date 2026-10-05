defmodule SymphonyElixir.AutoMerge.Fingerprint do
  @moduledoc """
  A fingerprint of a pull request's own diff, so `SymphonyElixir.AutoMerge` can tell whether a
  head pushed after approval changes what was approved.

  The fingerprint is `git patch-id --stable` over `git diff <merge-base(base, head)> head`, read
  in the issue's workspace. Merging the base branch in (Symphony's update-branch) or a clean
  rebase moves the merge-base along with the head, so the PR's own diff, and its fingerprint,
  stay the same. A commit that changes the PR's code changes it. The patch-id ignores
  whitespace and line numbers, but not the context lines around each change.

  The base branch is fetched from `origin` first, under the per-repo fetch lock, so the
  merge-base is read against the current base tip; the head is fetched only when it is missing.
  """

  alias SymphonyElixir.AutoReview
  alias SymphonyElixir.Repo.Fetcher
  alias SymphonyElixir.Workspace

  @empty_diff "empty"

  @type git_fun :: ([String.t()], Path.t() -> {String.t(), non_neg_integer()})

  @doc """
  The fingerprint of the PR diff at `head_sha`. `record` is the issue's PR review record
  (`workspace_path`, `repo_key`). An empty diff has the fingerprint `"empty"`.

  `{:error, :no_workspace}` means the record has no local workspace to read the diff in (a PR
  opened outside Symphony, a remote worker): there is nothing to compare, so no re-review.

  Options: `:git` (`(args, cwd) -> {output, status}`) and `:patch_id` (`(diff_path) -> {output,
  status}`).
  """
  @spec compute(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def compute(record, head_sha, opts \\ []) when is_map(record) and is_binary(head_sha) do
    git = Keyword.get(opts, :git, &default_git/2)
    base = AutoReview.base_branch(Map.get(record, :repo_key))

    with {:ok, workspace} <- workspace(record),
         {:ok, _output} <- run(&fetch(git, &1, &2), ["fetch", "--quiet", "origin", "+refs/heads/#{base}:refs/remotes/origin/#{base}"], workspace),
         :ok <- ensure_commit(workspace, head_sha, git),
         {:ok, merge_base} <- run(git, ["merge-base", "refs/remotes/origin/#{base}", head_sha], workspace) do
      patch_id(workspace, String.trim(merge_base), head_sha, git, Keyword.get(opts, :patch_id, &default_patch_id/1))
    end
  end

  defp workspace(record) do
    case Map.get(record, :workspace_path) do
      path when is_binary(path) and path != "" -> if File.dir?(path), do: {:ok, path}, else: {:error, :no_workspace}
      _missing -> {:error, :no_workspace}
    end
  end

  defp ensure_commit(workspace, sha, git) do
    with {_output, status} when status != 0 <- git.(["cat-file", "-e", sha <> "^{commit}"], workspace),
         {output, status} when status != 0 <- fetch(git, ["fetch", "--quiet", "origin", sha], workspace) do
      {:error, {:commit_unavailable, sha, status, String.trim(output)}}
    else
      {_output, 0} -> :ok
    end
  end

  # `git patch-id` reads the diff from stdin, so the diff goes through a temporary file.
  defp patch_id(workspace, merge_base, head_sha, git, patch_id) do
    diff = Path.join(System.tmp_dir!(), "symphony-fingerprint-#{System.unique_integer([:positive])}.diff")

    try do
      with {:ok, _output} <- run(git, ["diff", "--no-color", "--no-ext-diff", "--output=" <> diff, merge_base, head_sha], workspace) do
        case patch_id.(diff) do
          {output, 0} -> {:ok, output |> String.split() |> List.first() || @empty_diff}
          {output, status} -> {:error, {:git_failed, "patch-id", status, String.trim(output)}}
        end
      end
    after
      File.rm(diff)
    end
  end

  defp run(git, args, cwd) do
    case git.(args, cwd) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, git_command(args), status, String.trim(output)}}
    end
  end

  # Under the per-repo fetch lock: the workspace shares its `.git` with the source checkout and
  # every other worktree of it.
  defp fetch(git, args, cwd), do: Fetcher.fetch(cwd, fn -> git.(args, cwd) end)

  defp git_command(args), do: Enum.find(args, &(not String.starts_with?(&1, "-")))

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)

  defp default_patch_id(diff), do: System.cmd("/bin/sh", ["-c", ~s(exec git patch-id --stable < "$0"), diff], stderr_to_stdout: true)
end
