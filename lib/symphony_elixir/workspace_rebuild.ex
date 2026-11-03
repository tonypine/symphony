defmodule SymphonyElixir.WorkspaceRebuild do
  @moduledoc """
  Where a ticket's workspace starts when it must be made again: the age GC reclaimed it, a person
  deleted the folder, or the ticket's last run was on another host. `start/2` runs before
  `SymphonyElixir.Workspace.create_for_issue/4` and, when the ticket's local workspace folder is
  missing, picks the newest head Symphony knows of the ticket's branch, with the rule
  `SymphonyElixir.WorkspaceSync` uses (the head every other one is an ancestor of):

    * the head of the ticket's open pull request (`refs/pull/<number>/head`), which holds a
      person's push the watcher observed;
    * the head of the ticket's branch on `origin`;
    * the unpushed head the ticket's newest run recorded when it ended (`run.ended`'s
      `unpushed_head`), when the source repository still holds it.

  Heads that diverge are settled for the pushed one: the PR's, then the branch's. A ticket with no
  head anywhere starts from the configured base branch, as before. What came before the ticket's
  last Restart never counts: its PR is closed, its recorded heads are older than the Restart, and
  its branch on `origin` counts again only once a run pushed after it.

  The choice is recorded on the ticket's ledger as one `workspace.rebuilt` event: why the workspace
  was made again, the heads compared and the one chosen. A first workspace (no earlier run and no
  head anywhere) records nothing. Only a local worktree workspace is rebuilt this way: an SSH
  worker's, or a workspace with no source repository, starts as it always did.
  """

  require Logger

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repo.Fetcher
  alias SymphonyElixir.{RunStore, TicketPullRequest, TicketSignals, Workspace}

  @event "workspace.rebuilt"

  @typedoc "Why the workspace is made again."
  @type reason :: :reclaim | :missing_folder | :host_change

  @typedoc "Which head the workspace starts on; `:main` is the configured base branch."
  @type winner :: :pull_request | :branch | :recorded | :main

  @type choice :: %{
          reason: reason(),
          branch: String.t(),
          winner: winner(),
          head: String.t() | nil,
          pr_head: String.t() | nil,
          branch_head: String.t() | nil,
          recorded_head: String.t() | nil
        }

  @typedoc """
  `start/2`'s options:

    * `:repo_key` - the ticket's repo (default the issue's own).
    * `:settings` - the repo's settings (`workspace.repo` is the source repository).
    * `:worker_host` - an SSH worker's host; its workspace is not rebuilt here.
    * `:run_id` - the run being started, left out when looking for the ticket's previous run.
    * `:now` - the current time, for the age GC's cutoff (tests).
    * `:git` - runs git, `(args, dir -> {output, status})` (tests).
  """
  @type opt ::
          {:repo_key, String.t() | nil}
          | {:settings, map()}
          | {:worker_host, String.t() | nil}
          | {:run_id, String.t() | nil}
          | {:now, DateTime.t()}
          | {:git, (list(String.t()), Path.t() -> {String.t(), integer()})}

  @doc """
  `issue` with `workspace_base_ref` set to the newest known head of its branch when its local
  workspace must be made again (see the moduledoc), and as it is otherwise.
  """
  @spec start(Issue.t(), [opt()] | keyword()) :: Issue.t()
  def start(%Issue{} = issue, opts) do
    case choose(issue, opts) do
      {:ok, %{head: head} = choice} when is_binary(head) ->
        Logger.info("Rebuilding #{issue.identifier}'s workspace (#{choice.reason}) on #{choice.winner} head #{short(head)}")
        %Issue{issue | workspace_base_ref: head}

      _main_or_not_a_rebuild ->
        issue
    end
  end

  @doc """
  The start `start/2` picks for `issue`, recorded as a `workspace.rebuilt` event, or
  `:not_rebuilt` when its workspace is not made again here (it exists, it is an SSH worker's, there
  is no source repository, or it is the ticket's first workspace and no head exists).
  """
  @spec choose(Issue.t(), [opt()] | keyword()) :: {:ok, choice()} | :not_rebuilt
  def choose(%Issue{} = issue, opts) do
    git = Keyword.get(opts, :git, &git/2)
    repo_key = Keyword.get(opts, :repo_key) || issue.repo_key

    with nil <- Keyword.get(opts, :worker_host),
         {:ok, repo} <- source_repo(opts),
         {:ok, workspace} <- Workspace.local_path_for_issue(issue, repo_key),
         false <- File.exists?(workspace) do
      branch = branch(issue)
      events = ledger(issue.id)
      previous = previous_run(repo_key, issue.id, Keyword.get(opts, :run_id))

      heads = %{
        pull_request: pr_head(issue, repo_key, repo, git),
        branch: branch_head(branch, issue, events, repo, git),
        recorded: recorded_head(events, repo, git)
      }

      if previous == nil and Enum.all?(Map.values(heads), &is_nil/1) do
        :not_rebuilt
      else
        choice = choice(reason(previous, opts), branch, heads, newest(heads, repo, git))
        record(issue, repo_key, choice)
        {:ok, choice}
      end
    else
      _not_rebuilt -> :not_rebuilt
    end
  end

  defp source_repo(opts) do
    with %{workspace: %{strategy: "worktree", repo: repo}} when is_binary(repo) and repo != "" <- Keyword.get(opts, :settings),
         repo = Path.expand(repo),
         true <- File.dir?(repo) do
      {:ok, repo}
    else
      _none -> :error
    end
  end

  defp branch(%Issue{workspace_branch: branch}) when is_binary(branch) and branch != "", do: branch
  defp branch(%Issue{identifier: identifier}), do: "auto/#{identifier}"

  defp ledger(issue_id) do
    case RunStore.list_ticket_events(issue_id, types: ["run.ended", "attempt.pushed", "person.action"]) do
      events when is_list(events) -> Enum.sort_by(events, & &1.seq)
      _unreadable -> []
    end
  end

  # The events since the ticket's last Restart: what came before it was thrown away.
  defp since_restart(events) do
    case Enum.find_index(Enum.reverse(events), &restart?/1) do
      nil -> {false, events}
      index -> {true, Enum.take(events, -index)}
    end
  end

  defp restart?(%{type: "person.action", payload: %{action: "restart"}}), do: true
  defp restart?(_event), do: false

  defp previous_run(repo_key, issue_id, run_id) do
    with true <- is_binary(issue_id),
         runs when is_list(runs) <- RunStore.list_issue_runs(repo_key, issue_id) do
      Enum.find(runs, &(Map.get(&1, :run_id) != run_id))
    else
      _unreadable -> nil
    end
  end

  # A last run on another host left its workspace there; a last run that ended before the age GC's
  # cutoff had its workspace reclaimed; any other missing folder was removed by hand.
  defp reason(%{worker_host: host}, _opts) when is_binary(host) and host != "", do: :host_change

  defp reason(%{ended_at: %DateTime{} = ended_at}, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case opts |> Keyword.get(:settings) |> lifecycle() do
      %{age_gc_enabled: true, max_age_days: days} when is_integer(days) ->
        if DateTime.diff(now, ended_at) >= days * 86_400, do: :reclaim, else: :missing_folder

      _no_age_gc ->
        :missing_folder
    end
  end

  defp reason(_previous, _opts), do: :missing_folder

  defp lifecycle(%{workspace: %{lifecycle: lifecycle}}), do: lifecycle
  defp lifecycle(_settings), do: nil

  defp pr_head(issue, repo_key, repo, git) do
    with url when is_binary(url) <- TicketPullRequest.current_url(issue, repo_key),
         {:ok, %{number: number}} <- PullRequest.parse_url(url) do
      fetch_head(repo, "refs/pull/#{number}/head", issue, "pull", git)
    else
      _none -> nil
    end
  end

  # After a Restart, the branch on `origin` still holds the attempt it threw away until a run pushes
  # the new one.
  defp branch_head(branch, issue, events, repo, git) do
    case since_restart(events) do
      {true, since} -> if Enum.any?(since, &(&1.type == "attempt.pushed")), do: fetch_head(repo, "refs/heads/#{branch}", issue, "branch", git)
      {false, _events} -> fetch_head(repo, "refs/heads/#{branch}", issue, "branch", git)
    end
  end

  defp recorded_head(events, repo, git) do
    {_restarted?, since} = since_restart(events)

    with %{payload: %{unpushed_head: head}} when is_binary(head) and head != "" <-
           since |> Enum.filter(&(&1.type == "run.ended")) |> List.last(),
         {_output, 0} <- git.(["cat-file", "-e", head <> "^{commit}"], repo) do
      head
    else
      _none -> nil
    end
  end

  # Fetched into a ref of the ticket's own, read, then dropped: the shared repository's FETCH_HEAD
  # is every run's.
  defp fetch_head(repo, remote_ref, issue, name, git) do
    local_ref = "refs/symphony/rebuild/#{Workspace.safe_identifier(issue.identifier)}/#{name}"

    result =
      with {_output, 0} <- Fetcher.fetch(repo, fn -> git.(["fetch", "--quiet", "origin", "+#{remote_ref}:#{local_ref}"], repo) end),
           {sha, 0} <- git.(["rev-parse", "--verify", "-q", local_ref <> "^{commit}"], repo) do
        String.trim(sha)
      else
        _missing -> nil
      end

    git.(["update-ref", "-d", local_ref], repo)
    result
  end

  # The head every other one is an ancestor of; when they diverge, the pushed one.
  defp newest(heads, repo, git) do
    candidates = Enum.reject([:pull_request, :branch, :recorded], &is_nil(heads[&1]))
    shas = Enum.map(candidates, &heads[&1])

    Enum.find(candidates, fn name -> Enum.all?(shas, &(&1 == heads[name] or ancestor?(&1, heads[name], repo, git))) end) ||
      List.first(candidates) || :main
  end

  defp ancestor?(ancestor, descendant, repo, git),
    do: match?({_output, 0}, git.(["merge-base", "--is-ancestor", ancestor, descendant], repo))

  defp choice(reason, branch, heads, winner) do
    %{
      reason: reason,
      branch: branch,
      winner: winner,
      head: heads[winner],
      pr_head: heads.pull_request,
      branch_head: heads.branch,
      recorded_head: heads.recorded
    }
  end

  defp record(issue, repo_key, choice) do
    payload = %{
      reason: to_string(choice.reason),
      branch: choice.branch,
      winner: to_string(choice.winner),
      head: choice.head,
      pr_head: choice.pr_head,
      branch_head: choice.branch_head,
      recorded_head: choice.recorded_head
    }

    TicketSignals.record_event(repo_key, issue.id, @event, payload, head_sha: choice.head)
  end

  defp short(sha), do: String.slice(sha, 0, 12)

  defp git(args, dir), do: Workspace.safe_git(args, cd: dir, stderr_to_stdout: true)
end
