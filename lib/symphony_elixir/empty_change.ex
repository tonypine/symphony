defmodule SymphonyElixir.EmptyChange do
  @moduledoc """
  The rule that decides what a local "nothing to verify" means: a question that may throw a branch
  away rests on GitHub's view of the pull request, never on the workspace.

  `SymphonyElixir.QaPolicy` reads the changed paths from the workspace. A workspace that is not on
  the PR's head (a fresh one built from the base branch, one a sync left behind) diffs empty while
  the pull request carries real work. So when the QA run (`SymphonyElixir.QaVerification`) or the
  Code Review approve (`SymphonyElixir.CodeReview`) finds nothing to verify, it asks GitHub first
  (`check/4`, through `SymphonyElixir.GitHub.PullRequest.fetch_diff/2`):

    * GitHub's compare of the base branch to the PR head changes no file (`{:empty, heads}`): the
      change is truly empty, and the caller asks the Restart-or-Cancel question
      (`SymphonyElixir.ClosedPullRequest`, cause `{:no_change, url, heads}`), whose text names what
      was compared;
    * GitHub's diff is not empty (`{:not_empty, heads}`): the workspace is out of sync. The caller
      re-syncs it once through the one newest-known-head rule (`resync/4`,
      `SymphonyElixir.WorkspaceSync`) and decides again. A sync that fails, or a workspace that still
      finds nothing to verify after it, pauses the ticket on a reason the Director releases with
      Unblock (`pause/3`), naming the workspace's commit, the PR's and the base branch's; never on
      Restart or Cancel;
    * GitHub's diff cannot be read (`{:error, reason}`): nothing is asked, and the caller retries.

  Each read GitHub answers is recorded on the ticket's ledger as an `empty_change_checked` signal
  with the three commits and the changed-file count, so the commits behind the question are on the
  ticket's history even where the question itself must name them in plain words.
  """

  require Logger

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.HumanActions.PlainWords
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{Pauses, TicketSignals, WorkspaceSync}

  @signal "empty_change_checked"
  @condition_prefix "empty_change:"
  @setter %{kind: :rule, name: "Empty change check"}
  @max_text 300

  @typedoc """
  What was compared: the workspace's commit (nil when unreadable), GitHub's PR head, the head of its
  base branch (`base`, on the branch named `base_ref`) and how many files the compare changes.
  """
  @type heads :: %{
          workspace: String.t() | nil,
          pr: String.t(),
          base: String.t(),
          base_ref: String.t(),
          changed_files: non_neg_integer()
        }

  @doc """
  GitHub's answer for the pull request at `pr_url`, whose workspace stands on `workspace_head`:
  `{:empty, heads}` when the compare changes no file, else `{:not_empty, heads}`. `opts`:
  `:repo_key` (the ticket's repo, for the ledger signal) and `:gh_runner` (tests).
  """
  @type answer :: {:empty, heads()} | {:not_empty, heads()} | {:error, term()}

  @spec check(Issue.t(), String.t(), String.t() | nil, keyword()) :: answer()
  def check(%Issue{} = issue, pr_url, workspace_head, opts) when is_binary(pr_url) do
    case PullRequest.fetch_diff(pr_url, Keyword.take(opts, [:gh_runner])) do
      {:ok, diff} ->
        heads = %{workspace: workspace_head, pr: diff.head, base: diff.base, base_ref: diff.base_ref, changed_files: diff.changed_files}
        TicketSignals.record(repo_key(issue, opts), issue.id, @signal, heads)
        if diff.changed_files == 0, do: {:empty, heads}, else: {:not_empty, heads}

      {:error, reason} ->
        {:error, {:pr_diff_unreadable, reason}}
    end
  end

  @doc """
  Re-syncs `workspace` once through the newest-known-head rule after GitHub's diff (`heads`) was not
  empty: `:resynced` when it now stands on the PR's newest head, so the caller decides again; `:ok`
  once the sync failed and the ticket is paused (`pause/3`). `opts[:sync_opts]` go to
  `SymphonyElixir.WorkspaceSync.sync/3`; `opts[:run]` names the run in the pause's line.
  """
  @spec resync(Issue.t(), Path.t(), heads(), keyword()) :: :resynced | :ok | {:error, term()}
  def resync(%Issue{} = issue, workspace, heads, opts) do
    case WorkspaceSync.sync(issue, workspace, Keyword.get(opts, :sync_opts, [])) do
      {:ok, %{head: head}} ->
        Logger.info("#{label(issue)} found nothing to verify while GitHub's PR head #{short(heads.pr)} changes #{heads.changed_files} files; re-synced its workspace to #{short(head)}")
        :resynced

      {:error, reason} ->
        Logger.warning("#{label(issue)}'s workspace could not be re-synced to GitHub's PR head #{short(heads.pr)}: #{inspect(reason)}")
        pause(issue, heads, opts)
    end
  end

  @doc """
  Pauses `issue` on the reason a person releases with Unblock (`reason/2`): its workspace finds no
  change while GitHub's PR head changes files: `:ok` once paused. `opts`: `:repo_key` and `:run` (the
  run's name).
  """
  @spec pause(Issue.t(), heads(), keyword()) :: :ok | {:error, term()}
  def pause(%Issue{} = issue, heads, opts) do
    Logger.warning("Pausing #{label(issue)}: #{reason(heads, run(opts)).text}")

    case Pauses.set({:ticket, repo_key(issue, opts), issue.id}, reason(heads, run(opts)), set_by: @setter) do
      {:ok, _pause} -> :ok
      {:error, reason} -> {:error, {:empty_change_pause_failed, reason}}
    end
  end

  @doc """
  The pause reason for a workspace that finds no change while GitHub's diff of the PR (`heads`) is
  not empty: an `:environment` reason the Director may release, naming the workspace's commit, the
  PR head and the base branch's head.
  """
  @spec reason(heads(), String.t()) :: Pauses.reason_input()
  def reason(heads, run) when is_binary(run) do
    text =
      "#{run} found no change in its workspace at #{short(heads.workspace)}, but GitHub's PR head #{short(heads.pr)} " <>
        "changes #{files(heads.changed_files)} against #{heads.base_ref} at #{short(heads.base)}. Unblock runs it again."

    %{kind: :environment, waits_on: %{condition: @condition_prefix <> short(heads.pr)}, text: String.slice(text, 0, @max_text), releasable: true}
  end

  @doc """
  What the Restart-or-Cancel question says was compared, in the Director's plain words: GitHub's
  compare of the PR's latest commit with the base branch's, and where the workspace stood.
  """
  @spec compared(heads()) :: String.t()
  def compared(heads) do
    "GitHub compared the latest commit of the pull request with the latest commit of the #{PlainWords.scrub(heads.base_ref)} branch and found no changed file. " <>
      workspace_words(heads) <> " The exact commits are in the ticket's history."
  end

  defp workspace_words(%{workspace: nil}), do: "Symphony could not read which commit its copy of the work stood on."
  defp workspace_words(%{workspace: same, pr: same}), do: "Symphony's copy of the work stood on that same commit."
  defp workspace_words(_heads), do: "Symphony's copy of the work stood on another commit, so this answer comes from GitHub alone."

  defp files(1), do: "1 file"
  defp files(count), do: "#{count} files"

  defp short(nil), do: "an unreadable commit"
  defp short(sha), do: String.slice(sha, 0, 12)

  defp run(opts), do: Keyword.get(opts, :run, "The run")

  defp repo_key(issue, opts), do: Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)

  defp label(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp label(%Issue{id: id}), do: inspect(id)
end
