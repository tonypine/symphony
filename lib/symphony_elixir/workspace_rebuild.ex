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
      `unpushed_head`), when the source repository still holds it;
    * the ticket's local branch in the source repository, which a folder deleted by hand leaves
      behind with whatever a crashed run committed on it.

  Heads that diverge are settled for the pushed one: the PR's, then the branch's, then the
  recorded one. The worktree is added with `-B`, which moves the local branch onto the chosen
  head, so a local head that is neither the chosen one nor behind it is kept under
  `refs/symphony/orphaned/<sha>` first, as `SymphonyElixir.WorkspaceSync`'s reset keeps a dirty
  workspace. A ticket with no head anywhere starts from the configured base branch, as before. What
  came before the ticket's last Restart never counts: its PR is closed, its recorded heads are older
  than the Restart, its local branch was deleted with its workspace, and its branch on `origin`
  counts again only once a run pushed after it.

  Why the workspace is made again is read from what Symphony recorded since the ticket's previous
  run started, never guessed: a `workspace.removed` event (`record_removal/3`, `record_reclaims/1`)
  names Symphony's own removal (the age GC's reclaim, a Stop, a terminal state); a Restart
  (`person.action` `restart`) starts the ticket over, which is no rebuild; a previous run on an SSH
  worker is a host change; and a folder missing with none of these was removed by hand.

  The choice is recorded on the ticket's ledger as one `workspace.rebuilt` event: why the workspace
  was made again, the heads compared and the one chosen. A first workspace (no earlier run and no
  head anywhere) records nothing, nor does the first workspace after a Restart. Only a local
  worktree workspace is rebuilt this way: an SSH worker's, or a workspace with no source
  repository, starts as it always did.
  """

  require Logger

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repo.Fetcher
  alias SymphonyElixir.{RunStore, TicketPullRequest, TicketSignals, Workspace}

  @event "workspace.rebuilt"
  @removed "workspace.removed"

  @typedoc """
  Why the workspace is made again: Symphony removed it (`:reclaim` by the age GC, `:stop`,
  `:terminal`, `:cleanup` for another removal), the previous run was on another host, or the folder
  went missing without Symphony removing it.
  """
  @type reason :: :reclaim | :stop | :terminal | :cleanup | :missing_folder | :host_change

  @typedoc "Which head the workspace starts on; `:main` is the configured base branch."
  @type winner :: :pull_request | :branch | :recorded | :local | :main

  @type choice :: %{
          reason: reason(),
          branch: String.t(),
          winner: winner(),
          head: String.t() | nil,
          pr_head: String.t() | nil,
          branch_head: String.t() | nil,
          recorded_head: String.t() | nil,
          local_head: String.t() | nil,
          orphaned_head: String.t() | nil
        }

  @typedoc """
  `start/2`'s options:

    * `:repo_key` - the ticket's repo (default the issue's own).
    * `:settings` - the repo's settings (`workspace.repo` is the source repository).
    * `:worker_host` - an SSH worker's host; its workspace is not rebuilt here.
    * `:run_id` - the run being started, left out when looking for the ticket's previous run.
    * `:git` - runs git, `(args, dir -> {output, status})` (tests).
  """
  @type opt ::
          {:repo_key, String.t() | nil}
          | {:settings, map()}
          | {:worker_host, String.t() | nil}
          | {:run_id, String.t() | nil}
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
  is no source repository, it is the ticket's first workspace and no head exists, or the ticket was
  restarted since its previous run started).
  """
  @spec choose(Issue.t(), [opt()] | keyword()) :: {:ok, choice()} | :not_rebuilt
  def choose(%Issue{} = issue, opts) do
    git = Keyword.get(opts, :git, &git/2)
    repo_key = Keyword.get(opts, :repo_key) || issue.repo_key

    with nil <- Keyword.get(opts, :worker_host),
         {:ok, repo} <- source_repo(opts),
         {:ok, workspace} <- Workspace.local_path_for_issue(issue, repo_key),
         false <- File.exists?(workspace),
         previous = previous_run(repo_key, issue.id, Keyword.get(opts, :run_id)),
         events = ledger(issue.id),
         {:ok, reason} <- reason(previous, since_run(events, previous)) do
      branch = branch(issue)

      heads = %{
        pull_request: pr_head(issue, repo_key, repo, git),
        branch: branch_head(branch, issue, events, repo, git),
        recorded: recorded_head(events, repo, git),
        local: local_head(branch, repo, git)
      }

      if previous == nil and Enum.all?(Map.values(heads), &is_nil/1) do
        :not_rebuilt
      else
        winner = newest(heads, repo, git)
        choice = choice(reason, branch, heads, winner, keep_local(heads, winner, repo, git))
        record(issue, repo_key, choice)
        {:ok, choice}
      end
    else
      _not_rebuilt -> :not_rebuilt
    end
  end

  @doc """
  Records on the ticket's ledger that Symphony removed its workspace, as a `workspace.removed`
  event: `"stop"` and `"terminal"` for those removals, `"age_gc"` for the age GC's reclaim, and
  `"cleanup"` for any other. A ticket read without its id records nothing.
  """
  @spec record_removal(String.t() | nil, String.t() | nil, atom() | String.t() | nil) :: :ok
  def record_removal(repo_key, issue_id, reason) when is_binary(issue_id) do
    _ = TicketSignals.record_event(repo_key, issue_id, @removed, %{reason: removal_reason(reason)})
    :ok
  end

  def record_removal(_repo_key, _issue_id, _reason), do: :ok

  @doc """
  Records the age GC's deletions (`SymphonyElixir.Workspace.reclaim_stale_workspaces/3`'s
  `:deleted` actions) as `workspace.removed` events with the reason `"age_gc"`, on the ticket the
  repo's runs name for each workspace's identifier. A workspace no run names records nothing.
  """
  @spec record_reclaims([map()]) :: :ok
  def record_reclaims(actions) when is_list(actions) do
    actions
    |> Enum.filter(&match?(%{action: :deleted, reason: :age_gc, repo_key: repo_key, identifier: id} when is_binary(repo_key) and is_binary(id), &1))
    |> Enum.group_by(& &1.repo_key)
    |> Enum.each(fn {repo_key, reclaimed} ->
      issue_ids = issue_ids_by_identifier(repo_key)
      Enum.each(reclaimed, &record_removal(repo_key, Map.get(issue_ids, &1.identifier), "age_gc"))
    end)
  end

  defp issue_ids_by_identifier(repo_key) do
    case RunStore.list_runs(repo_key, :all) do
      runs when is_list(runs) ->
        runs |> Enum.reverse() |> Enum.flat_map(&identifier_and_id/1) |> Map.new()

      _unreadable ->
        %{}
    end
  end

  defp identifier_and_id(%{issue_identifier: identifier, issue_id: id}) when is_binary(identifier) and is_binary(id),
    do: [{Workspace.safe_identifier(identifier), id}]

  defp identifier_and_id(_incomplete_run), do: []

  defp removal_reason(reason) when reason in [:stop, :terminal, :age_gc, "stop", "terminal", "age_gc"], do: to_string(reason)
  defp removal_reason(_reason), do: "cleanup"

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
    case RunStore.list_ticket_events(issue_id, types: ["run.ended", "attempt.pushed", "person.action", @removed]) do
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

  # What happened since the previous run started: what took its workspace away.
  defp since_run(events, %{started_at: %DateTime{} = started_at}),
    do: Enum.filter(events, &(match?(%DateTime{}, &1.at) and DateTime.compare(&1.at, started_at) != :lt))

  defp since_run(events, _previous), do: events

  # A Restart starts the ticket over: its first workspace after it is no rebuild. Symphony's own
  # removal names itself; a previous run on another host left its workspace there; any other missing
  # folder was removed by hand.
  defp reason(previous, since) do
    removal = since |> Enum.filter(&(&1.type == @removed)) |> List.last()

    cond do
      Enum.any?(since, &restart?/1) -> :restarted
      removal != nil -> {:ok, removal_kind(removal.payload)}
      host_change?(previous) -> {:ok, :host_change}
      true -> {:ok, :missing_folder}
    end
  end

  defp removal_kind(%{reason: "age_gc"}), do: :reclaim
  defp removal_kind(%{reason: "stop"}), do: :stop
  defp removal_kind(%{reason: "terminal"}), do: :terminal
  defp removal_kind(_payload), do: :cleanup

  defp host_change?(%{worker_host: host}) when is_binary(host) and host != "", do: true
  defp host_change?(_previous), do: false

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

  defp local_head(branch, repo, git) do
    case git.(["rev-parse", "--verify", "-q", "refs/heads/#{branch}^{commit}"], repo) do
      {sha, 0} -> String.trim(sha)
      _missing -> nil
    end
  end

  # The local branch moves onto the chosen head; work on it that the chosen head doesn't hold is
  # kept under refs/symphony/orphaned/<sha>.
  defp keep_local(%{local: local} = heads, winner, repo, git) when is_binary(local) and winner != :local do
    head = heads[winner]

    if is_binary(head) and ancestor?(local, head, repo, git) do
      nil
    else
      ref = "refs/symphony/orphaned/#{local}"
      git.(["update-ref", ref, local], repo)
      Logger.warning("Kept the local branch head #{short(local)} under #{ref}: the rebuilt workspace starts on #{winner}")
      local
    end
  end

  defp keep_local(_heads, _winner, _repo, _git), do: nil

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
    candidates = Enum.reject([:pull_request, :branch, :recorded, :local], &is_nil(heads[&1]))
    shas = Enum.map(candidates, &heads[&1])

    Enum.find(candidates, fn name -> Enum.all?(shas, &(&1 == heads[name] or ancestor?(&1, heads[name], repo, git))) end) ||
      List.first(candidates) || :main
  end

  defp ancestor?(ancestor, descendant, repo, git),
    do: match?({_output, 0}, git.(["merge-base", "--is-ancestor", ancestor, descendant], repo))

  defp choice(reason, branch, heads, winner, orphaned) do
    %{
      reason: reason,
      branch: branch,
      winner: winner,
      head: heads[winner],
      pr_head: heads.pull_request,
      branch_head: heads.branch,
      recorded_head: heads.recorded,
      local_head: heads.local,
      orphaned_head: orphaned
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
      recorded_head: choice.recorded_head,
      local_head: choice.local_head,
      orphaned_head: choice.orphaned_head
    }

    TicketSignals.record_event(repo_key, issue.id, @event, payload, head_sha: choice.head)
  end

  defp short(sha), do: String.slice(sha, 0, 12)

  defp git(args, dir), do: Workspace.safe_git(args, cd: dir, stderr_to_stdout: true)
end
