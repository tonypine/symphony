defmodule SymphonyElixir.WorkspaceSync do
  @moduledoc """
  The one rule that brings a ticket's workspace to the newest known head of its pull request before
  a run that must stand on it: a Code Review run (`SymphonyElixir.CodeReview`), a QA run
  (`SymphonyElixir.QaVerification`), a landing run in `Merging` and a rework on a kept workspace
  (`SymphonyElixir.AgentRunner`).

  A workspace survives phase moves, so it can be behind its PR (a person pushed, branch upkeep merged
  the base branch in) or ahead of it (a run committed and never pushed). `sync/3` compares three
  heads: the workspace's `HEAD`, the PR's head on GitHub (`refs/pull/<number>/head`, which GitHub
  keeps for every pull request) and the unpushed head the ticket's newest run recorded when it
  ended (`run.ended`'s `unpushed_head`). The newest one, the head every other one is an ancestor
  of, wins:

    * all equal: nothing changes;
    * the PR's: the workspace is reset to it;
    * the workspace's: its commits are pushed to the PR's branch first;
    * the recorded one: the workspace is reset to it, then it is pushed.

  A reset never loses work: a workspace with uncommitted or untracked files is never reset, and
  neither is one whose heads diverge (each has commits the other lacks). Both are blocked, naming
  the work. The choice is recorded on the ticket's ledger as one `workspace.synced` event with the
  heads compared, the one that won and what was done.

  Only a local workspace is synced: an SSH worker's is left as it is.
  """

  require Logger

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repo.Fetcher
  alias SymphonyElixir.{RunStore, TicketPullRequest, TicketSignals, Workspace, WorkspaceHead}

  @event "workspace.synced"
  @reason_max 2_000

  @typedoc "Which head won: all `equal`, or the `workspace`'s, the `pull_request`'s, the `recorded` one, or `none` when they diverge."
  @type winner :: :equal | :workspace | :pull_request | :recorded | :none
  @typedoc "What the rule did to stand the workspace on the winning head."
  @type action :: :none | :reset | :pushed | :reset_and_pushed

  @type outcome :: %{
          head: String.t(),
          workspace_head: String.t(),
          pr_head: String.t(),
          recorded_head: String.t() | nil,
          winner: winner(),
          action: action()
        }

  @typedoc """
  Why the workspace could not be synced. `{:workspace_dirty, head, target, work}` blocks the run:
  the workspace at `head` was not reset to `target` because of `work`, each in plain words.
  """
  @type error ::
          :remote_worker
          | :head_unreadable
          | :no_pull_request
          | {:branch_mismatch, String.t() | nil, String.t()}
          | {:pr_head_fetch_failed, String.t(), integer(), String.t()}
          | {:workspace_dirty, String.t(), String.t(), [String.t()]}
          | {:pr_head_reset_failed, integer(), String.t()}
          | {:push_failed, term()}

  @typedoc """
  `sync/3`'s options:

    * `:repo_key` - the ticket's repo (default the issue's own).
    * `:worker_host` - an SSH worker's host; its workspace is not synced.
    * `:run_kind` - the run the sync stands before, named on the event.
    * `:expected_branch` - the branch the workspace must be on, when the caller knows the PR's.
    * `:source_repo` - the repo the workspace was cloned from, whose `origin` a push must match
      (default `settings.workspace.repo`).
    * `:settings` - the repo's settings.
    * `:git` - runs git, `(args, dir -> {output, status})` (tests).
    * `:pusher` - pushes the workspace head, as `WorkspaceHead.push_head/3` (tests).
    * `:recorded_head` - the recorded unpushed head, in place of the ledger's (tests).
  """
  @type opt ::
          {:repo_key, String.t() | nil}
          | {:worker_host, String.t() | nil}
          | {:run_kind, String.t() | atom() | nil}
          | {:expected_branch, String.t() | nil}
          | {:source_repo, Path.t() | nil}
          | {:settings, map()}
          | {:git, (list(String.t()), Path.t() -> {String.t(), integer()})}
          | {:pusher, (Path.t(), String.t() | nil, Path.t() | nil -> {:pushed, String.t()} | {:error, term()})}
          | {:recorded_head, String.t() | nil}

  @doc """
  Brings `workspace` to the newest known head of `issue`'s pull request (see the moduledoc) and
  records the choice. Returns the head the workspace now stands on, or why it could not.
  """
  @spec sync(Issue.t(), Path.t(), [opt()] | keyword()) :: {:ok, outcome()} | {:error, error()}
  def sync(%Issue{} = issue, workspace, opts) when is_binary(workspace) do
    git = Keyword.get(opts, :git, &git/2)

    with :ok <- local(opts),
         {:ok, head} <- local_head(workspace),
         :ok <- on_expected_branch(workspace, opts),
         {:ok, number} <- pr_number(issue, opts),
         {:ok, pr_head} <- fetch_pr_head(workspace, number, git) do
      heads = %{workspace: head, pull_request: pr_head, recorded: recorded_head(issue, opts, workspace, git)}
      winner = newest(heads, git, workspace)
      result = stand_on(winner, workspace, heads, git, opts)
      record(issue, opts, heads, winner, result)
      result
    end
  end

  @doc """
  `sync/3` before a run that must stand on the PR's head (a Code Review or a landing run): `:ok` once
  the workspace stands on it, or when there is no PR head to stand on (no PR recorded, a workspace
  with no head yet, an SSH worker's), in which case the run goes on as before on the head it has.
  A workspace that cannot be brought there (local work a reset would lose, a fetch or a push that
  failed) is `{:error, {:workspace_sync_failed, reason}}`: the run is not started on a stale head,
  it fails naming why and is retried.
  """
  @spec before_run(Issue.t(), Path.t(), [opt()] | keyword()) :: :ok | {:error, {:workspace_sync_failed, error()}}
  def before_run(%Issue{} = issue, workspace, opts) when is_binary(workspace) do
    case sync(issue, workspace, opts) do
      {:ok, %{head: head}} ->
        Logger.info("#{issue.identifier}'s #{run_kind(opts) || "run"} stands on the PR head #{short(head)}")
        :ok

      {:error, reason} when reason in [:no_pull_request, :head_unreadable, :remote_worker] ->
        :ok

      {:error, reason} ->
        Logger.warning("Not starting #{issue.identifier}'s #{run_kind(opts) || "run"}: its workspace could not be brought to the PR head: #{inspect(reason)}")
        {:error, {:workspace_sync_failed, reason}}
    end
  end

  @doc """
  The unpushed head the newest run of the ticket `issue_id` recorded when it ended, or nil when that
  run left everything pushed (or no run ended yet). The newest by when it ended, not by when its
  event was written: a run closed late at a boot (`SymphonyElixir.TicketEvents.RunEnds`) never hides
  the end of a run after it.
  """
  @spec recorded_unpushed_head(String.t() | nil) :: String.t() | nil
  def recorded_unpushed_head(issue_id) when is_binary(issue_id) do
    case RunStore.list_ticket_events(issue_id, types: ["run.ended"]) do
      [_ | _] = events -> events |> List.last() |> Map.get(:payload) |> unpushed_head()
      _none -> nil
    end
  end

  def recorded_unpushed_head(_issue_id), do: nil

  defp unpushed_head(%{unpushed_head: head}) when is_binary(head) and head != "", do: head
  defp unpushed_head(_payload), do: nil

  defp local(opts) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) -> {:error, :remote_worker}
      _local -> :ok
    end
  end

  defp local_head(workspace) do
    case WorkspaceHead.read(workspace, nil) do
      nil -> {:error, :head_unreadable}
      head -> {:ok, head}
    end
  end

  defp on_expected_branch(workspace, opts) do
    case Keyword.get(opts, :expected_branch) do
      expected when is_binary(expected) ->
        case WorkspaceHead.branch(workspace, nil) do
          ^expected -> :ok
          branch -> {:error, {:branch_mismatch, branch, expected}}
        end

      _any ->
        :ok
    end
  end

  defp pr_number(issue, opts) do
    with url when is_binary(url) <- TicketPullRequest.current_url(issue, repo_key(issue, opts)),
         {:ok, %{number: number}} <- PullRequest.parse_url(url) do
      {:ok, number}
    else
      _none -> {:error, :no_pull_request}
    end
  end

  defp fetch_pr_head(workspace, number, git) do
    ref = "refs/pull/#{number}/head"

    with {_output, 0} <- Fetcher.fetch(workspace, fn -> git.(["fetch", "--quiet", "origin", ref], workspace) end),
         {sha, 0} <- git.(["rev-parse", "--verify", "-q", "FETCH_HEAD^{commit}"], workspace) do
      {:ok, String.trim(sha)}
    else
      {output, status} -> {:error, {:pr_head_fetch_failed, ref, status, String.trim(output)}}
    end
  end

  # A recorded head the workspace's repository no longer holds cannot be stood on: it is named on
  # the event and left out of the comparison.
  defp recorded_head(issue, opts, workspace, git) do
    head = Keyword.get_lazy(opts, :recorded_head, fn -> recorded_unpushed_head(issue.id) end)

    cond do
      not is_binary(head) ->
        nil

      match?({_output, 0}, git.(["cat-file", "-e", head <> "^{commit}"], workspace)) ->
        head

      true ->
        Logger.warning("The unpushed head #{short(head)} a run of #{issue.identifier} recorded is not in its workspace's repository; comparing the other heads")
        nil
    end
  end

  defp stand_on(:equal, _workspace, heads, _git, _opts), do: {:ok, outcome(heads, heads.workspace, :equal, :none)}
  defp stand_on(:pull_request, workspace, heads, git, _opts), do: reset(workspace, heads, heads.pull_request, git, :pull_request)
  defp stand_on(:workspace, workspace, heads, _git, opts), do: push(workspace, heads, :workspace, :pushed, opts)
  defp stand_on(:recorded, workspace, heads, git, opts), do: reset_and_push(workspace, heads, git, opts)

  defp stand_on(:none, workspace, %{workspace: head, pull_request: pr_head}, git, _opts),
    do: {:error, {:workspace_dirty, head, pr_head, diverged_work(workspace, pr_head, git)}}

  # The head every other one is an ancestor of; `:equal` when the workspace already is the PR's
  # head and nothing newer was recorded, `:none` when the heads diverge.
  defp newest(%{workspace: head, pull_request: pr_head, recorded: recorded}, git, workspace) do
    candidates = Enum.uniq(Enum.reject([head, pr_head, recorded], &is_nil/1))
    newest = Enum.find(candidates, fn candidate -> Enum.all?(candidates, &(&1 == candidate or ancestor?(&1, candidate, git, workspace))) end)

    cond do
      newest == nil -> :none
      newest == head and newest == pr_head -> :equal
      newest == pr_head -> :pull_request
      newest == head -> :workspace
      true -> :recorded
    end
  end

  defp ancestor?(ancestor, descendant, git, workspace) do
    match?({_output, 0}, git.(["merge-base", "--is-ancestor", ancestor, descendant], workspace))
  end

  defp reset(workspace, %{workspace: head} = heads, target, git, winner) do
    case local_work(workspace, target, git) do
      [] ->
        case git.(["reset", "--hard", "--quiet", target], workspace) do
          {_output, 0} -> {:ok, outcome(heads, target, winner, :reset)}
          {output, status} -> {:error, {:pr_head_reset_failed, status, String.trim(output)}}
        end

      work ->
        {:error, {:workspace_dirty, head, target, work}}
    end
  end

  defp reset_and_push(workspace, %{recorded: recorded} = heads, git, opts) do
    with {:ok, _reset} <- reset(workspace, heads, recorded, git, :recorded) do
      push(workspace, heads, :recorded, :reset_and_pushed, opts)
    end
  end

  defp push(workspace, heads, winner, action, opts) do
    pusher = Keyword.get(opts, :pusher, &WorkspaceHead.push_head/3)

    case pusher.(workspace, nil, source_repo(opts)) do
      {:pushed, _branch} -> {:ok, outcome(heads, Map.fetch!(heads, winner), winner, action)}
      {:error, reason} -> {:error, {:push_failed, reason}}
    end
  end

  defp source_repo(opts) do
    case Keyword.fetch(opts, :source_repo) do
      {:ok, repo} -> repo
      :error -> opts |> Keyword.get(:settings) |> settings_repo()
    end
  end

  defp settings_repo(%{workspace: %{repo: repo}}), do: repo
  defp settings_repo(_settings), do: nil

  defp outcome(heads, head, winner, action) do
    %{
      head: head,
      workspace_head: heads.workspace,
      pr_head: heads.pull_request,
      recorded_head: heads.recorded,
      winner: winner,
      action: action
    }
  end

  # What a reset would lose, in plain words; a git read that fails counts as local work, so a
  # workspace that cannot be read is never reset.
  defp local_work(workspace, target, git) do
    changes = git_lines(git, ["status", "--porcelain=v1", "--untracked-files=all"], workspace)
    unpushed = git_lines(git, ["rev-list", "HEAD", "--not", target, "--remotes"], workspace)

    Enum.reject(
      [
        work(changes, &"local changes (#{few(Enum.map(&1, fn line -> String.trim(line) end))})"),
        work(unpushed, &"#{length(&1)} unpushed commit(s) (#{few(Enum.map(&1, fn sha -> short(sha) end))})")
      ],
      &is_nil/1
    )
  end

  # Heads that diverge are never reset over, even when the workspace's own commits are on a remote:
  # with nothing local to name, the work is the divergence itself.
  defp diverged_work(workspace, pr_head, git) do
    case local_work(workspace, pr_head, git) do
      [] -> ["commits the PR head does not have"]
      work -> work
    end
  end

  defp git_lines(git, args, workspace) do
    case git.(args, workspace) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      {output, status} -> {:error, "git #{hd(args)} exited #{status}: #{String.trim(output)}"}
    end
  end

  defp work({:error, unread}, _describe), do: "a state git could not read (#{unread})"
  defp work({:ok, []}, _describe), do: nil
  defp work({:ok, lines}, describe), do: describe.(lines)

  defp few(items) when length(items) > 5, do: Enum.join(Enum.take(items, 5), ", ") <> " and #{length(items) - 5} more"
  defp few(items), do: Enum.join(items, ", ")

  defp record(issue, opts, heads, winner, result) do
    payload =
      Map.merge(
        %{
          workspace_head: heads.workspace,
          pr_head: heads.pull_request,
          recorded_head: heads.recorded,
          run_kind: run_kind(opts),
          winner: to_string(winner)
        },
        result_fields(result)
      )

    TicketSignals.record_event(repo_key(issue, opts), issue.id, @event, payload, head_sha: payload[:head] || heads.workspace)
  end

  defp result_fields({:ok, %{head: head, action: action}}), do: %{head: head, action: to_string(action)}
  defp result_fields({:error, {:workspace_dirty, _head, _target, work}}), do: %{action: "blocked", reason: bounded(Enum.join(work, " and "))}
  defp result_fields({:error, reason}), do: %{action: "failed", reason: bounded(inspect(reason))}

  # The event's reason is bounded (`SymphonyElixir.TicketEvents.Types`); the run's error keeps it whole.
  defp bounded(reason), do: String.slice(reason, 0, @reason_max)

  defp run_kind(opts) do
    case Keyword.get(opts, :run_kind) do
      nil -> nil
      kind -> to_string(kind)
    end
  end

  defp repo_key(issue, opts), do: Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)

  defp short(sha), do: String.slice(sha, 0, 12)

  defp git(args, workspace), do: Workspace.safe_git(args, cd: workspace, stderr_to_stdout: true)
end
