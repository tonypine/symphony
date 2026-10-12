defmodule SymphonyElixir.QaPolicy do
  @moduledoc """
  The QA state's skip rule: which changes need a QA run, and which skip it.

  The rule is hybrid, as the design says. A deterministic rule skips QA automatically when the
  changed paths are all docs, tests or `auto_review.skip_globs` paths (or no playbook applies);
  everything else runs it. The Code Review verdict carries the decision — `SymphonyElixir.CodeReview`
  asks this module at approve time and records the outcome with its reason — and the QA state's own
  run re-checks it (`SymphonyElixir.QaVerification`), so a skipped ticket never starts an agent and
  every skip is auditable in the ticket's ledger.
  """

  alias SymphonyElixir.AutoReview
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent.Selection
  alias SymphonyElixir.Verification
  alias SymphonyElixir.Workspace

  @typedoc "Whether the change needs a QA run — and with which playbooks — or skips it, with the recorded reason."
  @type decision :: {:run, [Selection.playbook()], String.t()} | {:skip, String.t()}

  @doc """
  The decision for `issue`'s change: the paths `sha` (default `HEAD`) changes against the merge
  base of `origin/<base>` in `workspace`. A diff that cannot be read runs QA rather than skipping
  it, so a broken read never smuggles a change past verification.
  """
  @spec decide(Issue.t(), map(), keyword()) :: decision()
  def decide(%Issue{} = issue, settings, opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    repo_key = Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)
    sha = Keyword.get(opts, :sha) || "HEAD"

    case changed_paths(workspace, repo_key, sha, opts) do
      {:ok, paths} ->
        decision(issue, settings, paths)

      {:error, reason} ->
        {:run, enabled_playbooks(settings), "the changed paths could not be read (#{format_reason(reason)})"}
    end
  end

  @doc "The decision for an already-listed set of changed paths."
  @spec decision(Issue.t(), map(), [String.t()]) :: decision()
  def decision(%Issue{} = issue, settings, paths) when is_list(paths) do
    case Selection.decide(issue, paths, settings.auto_review, dev_server?: dev_server?(settings)) do
      {:skip, reason} -> {:skip, reason}
      {:run, playbooks} -> {:run, playbooks, "the change delivers or updates a user journey"}
    end
  end

  @doc "Every enabled playbook, the broad set a run falls back to when the diff cannot be read."
  @spec enabled_playbooks(map()) :: [Selection.playbook()]
  def enabled_playbooks(settings), do: Selection.playbooks(settings.auto_review, dev_server?: dev_server?(settings))

  defp dev_server?(settings), do: Verification.dev_server_configured?(settings)

  @doc """
  The paths `sha` changes against the merge base of `origin/<base>` in `workspace`. `opts[:git]`
  overrides the git runner (tests); it is called as `git.(args, cwd)` and returns `{output, status}`.
  """
  @spec changed_paths(Path.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def changed_paths(workspace, repo_key, sha, opts) when is_binary(workspace) do
    git = Keyword.get(opts, :git, &default_git/2)
    base = "origin/" <> AutoReview.base_branch(repo_key)

    with {merge_base, 0} <- git.(["merge-base", base, sha], workspace),
         {output, 0} <- git.(["diff", "--name-only", String.trim(merge_base), sha], workspace) do
      {:ok, output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}
    else
      {output, status} -> {:error, {:git_failed, status, to_string(output)}}
    end
  end

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)

  # `changed_paths/4` is the only producer of a reason here, and it always names a git failure.
  defp format_reason({:git_failed, status, output}), do: trim_output(status, output)

  defp trim_output(status, output) do
    trimmed = output |> to_string() |> String.trim()
    if trimmed == "", do: "git exited #{status}", else: "git exited #{status}: #{trimmed}"
  end
end
