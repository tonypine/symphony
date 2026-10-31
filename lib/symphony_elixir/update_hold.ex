defmodule SymphonyElixir.UpdateHold do
  @moduledoc """
  Holds a `Todo` ticket whose blocker fixed Symphony itself until the running app includes the fix.

  When Symphony works on its own repository, a fix takes effect once the app is updated, not when
  its pull request merges. A blocker counts as such a fix when its merged pull request is in the
  repository the running build was released from (`SymphonyElixir.BuildInfo`). Its dependents stay
  held after the blocker is terminal, until the blocker's merge commit is in the running build.
  Blockers merged in any other repository release their dependents at once, as before, and so does
  every blocker when the running build has no sha (a build from a checkout).

  The `skip-update-hold` label opts out, on the held ticket or on the blocker (a docs-only or
  `WORKFLOW.md` change needs no app update).

  The self-heal lane's wait on a fix ticket, and a run's block report on its blockers, wait the same
  way for a ticket merged in that repository (`awaiting_update/4`, called by
  `SymphonyElixir.Pauses.Dependencies` for a ticket in any phase).

  `resolve/5` does the lookups (Linear for the blockers, Symphony's record of each blocker's pull
  request, GitHub for the merge commit and whether the build includes it) and keeps their answers
  in a cache; `hold/4` decides from the cache alone. A lookup that fails is left out of the cache,
  so it holds no new ticket.

  The wait lives on the ticket's pause (`SymphonyElixir.Pauses`), so it outlasts a restart: `hold/4`
  adds one `:build` reason per blocker the build lacks, "Waiting for a Symphony update that includes
  TP-12's fix" (`waits_on: %{pull_request: number}`), set by the rule "App update hold". `resolve/5`,
  in the poll task, holds each polled ticket so and clears each of those reasons once its build has
  arrived: the build includes the merge commit, the ticket is no longer held for a build (the skip
  label, out of `Todo`, an open blocker, the blocker's fix no longer merged there) or the running
  build has no sha. A reason it can't answer for yet, a lookup having failed, stays. The dispatch
  gate and the snapshot read the pause (`reasons/2`).
  """

  require Logger

  alias SymphonyElixir.{BuildInfo, Pauses, ReleaseBuild, TicketPullRequest, Tracker}
  alias SymphonyElixir.GitHub.{PullRequest, Repo}
  alias SymphonyElixir.Linear.Issue

  @skip_label "skip-update-hold"
  @todo_state "todo"
  @setter %{kind: :rule, name: "App update hold"}

  @typedoc """
  What a blocker needs from the app: `:skip` (opted out), `:none` (no merged pull request in the
  build's repository) or the pull request and the commit it merged as.
  """
  @type blocker_fact :: :skip | :none | {:merged, String.t(), String.t()}

  @type cache :: %{
          blockers: %{String.t() => blocker_fact()},
          included: %{{String.t(), String.t()} => boolean()}
        }

  @typedoc "A blocker the running build lacks: its identifier, the commit it merged as and its pull request's number."
  @type waiting :: %{identifier: String.t() | nil, merge_sha: String.t() | nil, pull_request: pos_integer()}

  @type hold :: %{blockers: [waiting(), ...], build_sha: String.t(), reasons: [Pauses.reason_input(), ...]}

  @spec skip_label() :: String.t()
  def skip_label, do: @skip_label

  @spec empty_cache() :: cache()
  def empty_cache, do: %{blockers: %{}, included: %{}}

  @doc """
  Looks up what `hold/4` needs for the held candidates among `issues` and returns the cache with
  the answers added. Blockers and merge commits already in the cache are not looked up again.

  Options: `:repo_key` (the repo whose record of a blocker's pull request is read, for a blocker
  read without one), `:fetch_issues` (`[id] -> {:ok, [Issue.t()]}`), `:merge_commit_sha`
  (`pr_url -> {:ok, sha | nil}`) and `:commit_included?` (`pr_url, sha, build_sha -> {:ok, boolean}`).
  """
  @spec resolve([Issue.t()], BuildInfo.t(), cache(), Enumerable.t(String.t()), keyword()) :: cache()
  def resolve(issues, %{sha: build_sha, repo: build_repo} = build, cache, terminal_states, opts)
      when is_binary(build_sha) and is_binary(build_repo) do
    candidates = Enum.filter(issues, &candidate?(&1, terminal_states))

    cache =
      cache
      |> resolve_blockers(candidates, build, terminal_states, opts)
      |> resolve_included(candidates, build, opts)

    sync_pauses(issues, build, cache, terminal_states, opts)
    cache
  end

  def resolve(issues, build, cache, terminal_states, opts) do
    sync_pauses(issues, build, cache, terminal_states, opts)
    cache
  end

  @doc """
  The hold on `issue`, or nil when it may be dispatched as far as app updates go. It is held while a
  blocker's merge commit is known to be missing from the running build, and the hold is written on
  its pause: a `:build` reason per such blocker that the pause doesn't hold yet. An issue without a
  repo key writes nothing. Each write is best-effort: the next poll makes it again.
  """
  @spec hold(Issue.t(), BuildInfo.t(), cache(), Enumerable.t(String.t())) :: hold() | nil
  def hold(%Issue{} = issue, build, cache, terminal_states) do
    with %{} = hold <- decide(issue, build, cache, terminal_states) do
      put_reasons(issue, hold, owned_reasons(issue))
      hold
    end
  end

  @doc "Whether a pause reason is one this hold set: a `:build` reason of the rule \"App update hold\"."
  @spec reason?(Pauses.reason() | term()) :: boolean()
  def reason?(%{kind: :build, waits_on: %{pull_request: number}, set_by: @setter}) when is_integer(number), do: true
  def reason?(_reason), do: false

  @doc "The reasons this hold set on the pause of `repo_key`'s ticket `issue_id`, in the order they were set."
  @spec reasons(String.t() | nil, String.t() | nil) :: [Pauses.reason()]
  def reasons(repo_key, issue_id) when is_binary(repo_key) and is_binary(issue_id) do
    case Pauses.get({:ticket, repo_key, issue_id}) do
      {:ok, %{reasons: reasons}} -> Enum.filter(reasons, &reason?/1)
      _none -> []
    end
  end

  def reasons(_repo_key, _issue_id), do: []

  @doc """
  The blocker each of `reasons` (`reasons/2`) waits on, found among `issue`'s blockers by the cached
  pull request: its identifier and merge commit, both nil when the cache doesn't know it (yet).
  """
  @spec blockers(Issue.t(), [Pauses.reason()], cache()) :: [waiting()]
  def blockers(%Issue{} = issue, reasons, cache) do
    merged =
      for %{id: blocker_id} = blocker <- issue.blocked_by,
          {:merged, pr_url, merge_sha} <- [Map.get(cache.blockers, blocker_id)],
          into: %{},
          do: {pr_number(pr_url), %{identifier: Map.get(blocker, :identifier), merge_sha: merge_sha}}

    for %{waits_on: %{pull_request: number}} <- reasons do
      merged |> Map.get(number, %{identifier: nil, merge_sha: nil}) |> Map.put(:pull_request, number)
    end
  end

  @doc """
  The line of each of `reasons` (`reasons/2`) as a person reads it: while the release build of the
  fix it waits on isn't published, what that build is at (`SymphonyElixir.ReleaseBuild.line/3`:
  "Waiting for the v0.0.1.750 build with TP-12's fix: queued on GitHub for 23 min"), else the
  reason's own line. `opts`: those of `ReleaseBuild.line/3`.
  """
  @spec lines(Issue.t(), [Pauses.reason()], cache(), keyword()) :: [String.t()]
  def lines(%Issue{} = issue, reasons, cache, opts \\ []) do
    issue
    |> blockers(reasons, cache)
    |> Enum.zip(reasons)
    |> Enum.map(fn {blocker, reason} -> ReleaseBuild.line(blocker.merge_sha, fix_name(blocker), opts) || reason.text end)
  end

  defp decide(%Issue{} = issue, %{sha: build_sha, repo: build_repo}, cache, terminal_states)
       when is_binary(build_sha) and is_binary(build_repo) do
    waiting =
      if candidate?(issue, terminal_states) do
        for %{id: blocker_id} = blocker <- issue.blocked_by,
            {:merged, pr_url, merge_sha} <- [Map.get(cache.blockers, blocker_id)],
            Map.get(cache.included, {merge_sha, build_sha}) == false do
          %{identifier: Map.get(blocker, :identifier), merge_sha: merge_sha, pull_request: pr_number(pr_url)}
        end
      else
        []
      end

    if waiting != [] do
      %{blockers: waiting, build_sha: build_sha, reasons: Enum.map(waiting, &build_reason/1)}
    end
  end

  defp decide(_issue, _build, _cache, _terminal_states), do: nil

  # Each polled ticket's pause follows the decision: the reasons it calls for are set, and those of
  # its own whose build arrived are cleared.
  defp sync_pauses(issues, build, cache, terminal_states, opts) do
    for %Issue{id: issue_id} = issue when is_binary(issue_id) <- issues do
      issue = %{issue | repo_key: issue.repo_key || Keyword.get(opts, :repo_key)}
      held = owned_reasons(issue)
      hold = decide(issue, build, cache, terminal_states)
      if hold, do: put_reasons(issue, hold, held)
      waiting = if hold, do: Enum.map(hold.blockers, & &1.pull_request), else: []
      clear_arrived(issue, held, &arrived?(&1, issue, build, cache, terminal_states, waiting))
    end

    :ok
  end

  defp owned_reasons(%Issue{repo_key: repo_key, id: issue_id}), do: reasons(repo_key, issue_id)

  defp put_reasons(%Issue{repo_key: repo_key, id: issue_id} = issue, hold, held) when is_binary(repo_key) and is_binary(issue_id) do
    keys = Enum.map(held, &{&1.kind, &1.waits_on})
    missing = Enum.reject(hold.reasons, &({&1.kind, &1.waits_on} in keys))
    Enum.each(missing, &Pauses.set({:ticket, repo_key, issue_id}, &1, set_by: @setter))

    if held == [] and missing != [] do
      Logger.info("Holding for an app update: issue_id=#{issue_id} issue_identifier=#{issue.identifier}; #{Enum.map_join(missing, "; ", & &1.text)}")
    end
  end

  defp put_reasons(_issue, _hold, _held), do: :ok

  defp clear_arrived(%Issue{repo_key: repo_key, id: issue_id} = issue, held, arrived?) do
    case Enum.filter(held, arrived?) do
      [] ->
        :ok

      arrived ->
        Enum.each(arrived, &Pauses.clear_reason({:ticket, repo_key, issue_id}, &1, by: @setter))
        if arrived == held, do: Logger.info("Released from the app update hold: issue_id=#{issue_id} issue_identifier=#{issue.identifier}")
    end
  end

  # A reason the decision still calls for stays; any other is answered once the running build has no
  # sha, the ticket is no longer held for a build, or the cache says its build arrived.
  defp arrived?(%{waits_on: %{pull_request: number}}, issue, build, cache, terminal_states, waiting) do
    cond do
      number in waiting -> false
      not is_binary(Map.get(build, :sha)) or not is_binary(Map.get(build, :repo)) -> true
      not candidate?(issue, terminal_states) -> true
      true -> build_arrived?(issue, number, build.sha, cache)
    end
  end

  # The blocker whose fix it waits on is in the build, or every blocker is known and none of them
  # merged that pull request any more. A blocker the cache doesn't know keeps the reason.
  defp build_arrived?(%Issue{blocked_by: blockers}, number, build_sha, cache) do
    facts = for %{id: blocker_id} when is_binary(blocker_id) <- blockers, do: Map.fetch(cache.blockers, blocker_id)

    merge_sha =
      Enum.find_value(facts, fn
        {:ok, {:merged, pr_url, merge_sha}} -> if pr_number(pr_url) == number, do: merge_sha
        _other -> nil
      end)

    if merge_sha,
      do: Map.get(cache.included, {merge_sha, build_sha}) == true,
      else: Enum.all?(facts, &match?({:ok, _fact}, &1))
  end

  @doc """
  Whether the running build still lacks the fix `ticket` merged: a fix ticket or a blocker a ticket's
  pause waits on (`SymphonyElixir.Pauses.Dependencies`), already terminal. Returns the ticket and its merge commit while
  its merged pull request is in the build's repository and the running build is known not to
  include that commit, else nil (merged elsewhere, not merged, opted out with the skip label, no
  build sha, or a lookup that failed), with the cache the lookups extended. Takes the same lookup
  options as `resolve/5`.
  """
  @spec awaiting_update(Issue.t(), BuildInfo.t(), cache(), keyword()) ::
          {%{identifier: String.t() | nil, merge_sha: String.t()} | nil, cache()}
  def awaiting_update(%Issue{id: ticket_id} = ticket, %{sha: build_sha, repo: build_repo} = build, cache, opts)
      when is_binary(ticket_id) and is_binary(build_sha) and is_binary(build_repo) do
    cache = cache_fact(cache, ticket, build, opts)

    case Map.get(cache.blockers, ticket_id) do
      {:merged, pr_url, merge_sha} ->
        cache = cache_included(cache, [{pr_url, merge_sha}], build_sha, opts)
        waiting = if Map.get(cache.included, {merge_sha, build_sha}) == false, do: %{identifier: ticket.identifier, merge_sha: merge_sha}
        {waiting, cache}

      _not_merged_here ->
        {nil, cache}
    end
  end

  def awaiting_update(_ticket, _build, cache, _opts), do: {nil, cache}

  defp cache_fact(cache, %Issue{id: ticket_id} = ticket, build, opts) do
    if Map.has_key?(cache.blockers, ticket_id) do
      cache
    else
      case blocker_fact(ticket, build, opts) do
        {:ok, fact} -> %{cache | blockers: Map.put(cache.blockers, ticket_id, fact)}
        {:error, _reason} -> cache
      end
    end
  end

  # A `Todo` ticket whose blockers are all terminal: the plain blocked-by gate would release it.
  defp candidate?(%Issue{state: state, blocked_by: [_ | _]} = issue, terminal_states) when is_binary(state) do
    normalize(state) == @todo_state and Issue.open_blockers(issue, terminal_states) == [] and not skip_labelled?(issue)
  end

  defp candidate?(_issue, _terminal_states), do: false

  defp resolve_blockers(cache, candidates, build, terminal_states, opts) do
    missing =
      for %Issue{blocked_by: blockers} <- candidates,
          %{id: blocker_id} when is_binary(blocker_id) <- blockers,
          not Map.has_key?(cache.blockers, blocker_id),
          uniq: true,
          do: blocker_id

    case fetch_blockers(missing, opts) do
      {:ok, blockers} ->
        facts =
          for %Issue{id: blocker_id} = blocker <- blockers,
              blocker_id in missing,
              terminal?(blocker.state, terminal_states),
              {:ok, fact} <- [blocker_fact(blocker, build, opts)],
              into: %{},
              do: {blocker_id, fact}

        %{cache | blockers: Map.merge(cache.blockers, facts)}

      {:error, _reason} ->
        cache
    end
  end

  defp fetch_blockers([], _opts), do: {:ok, []}
  defp fetch_blockers(ids, opts), do: Keyword.get(opts, :fetch_issues, &Tracker.fetch_issue_states_by_ids/1).(ids)

  defp blocker_fact(%Issue{} = blocker, build, opts) do
    if skip_labelled?(blocker), do: {:ok, :skip}, else: merged_pull_request(blocker, build, opts)
  end

  # The first merged pull request in the build's repository; `:none` when there is none, or the last
  # error when one failed to load and none merged. The blocker's pull request is the one Symphony
  # recorded for it, whatever its state (`SymphonyElixir.TicketPullRequest.recorded_urls/2`): a
  # finished blocker's PR is closed or merged by now. A blocker read by id carries no repo, so the
  # record is looked up under `opts[:repo_key]`.
  defp merged_pull_request(%Issue{} = issue, build, opts) do
    merge_commit_sha = Keyword.get(opts, :merge_commit_sha, &PullRequest.merge_commit_sha/1)

    issue
    |> TicketPullRequest.recorded_urls(Keyword.get(opts, :repo_key))
    |> Enum.filter(&same_repo?(&1, build.repo))
    |> Enum.reduce_while({:ok, :none}, fn pr_url, acc ->
      case merge_commit_sha.(pr_url) do
        {:ok, sha} when is_binary(sha) -> {:halt, {:ok, {:merged, pr_url, String.downcase(sha)}}}
        {:ok, nil} -> {:cont, acc}
        {:error, _reason} = error -> {:cont, error}
      end
    end)
  end

  defp resolve_included(cache, candidates, %{sha: build_sha}, opts) do
    merged =
      for %Issue{blocked_by: blockers} <- candidates,
          %{id: blocker_id} <- blockers,
          {:merged, pr_url, merge_sha} <- [Map.get(cache.blockers, blocker_id)],
          uniq: true,
          do: {pr_url, merge_sha}

    cache_included(cache, merged, build_sha, opts)
  end

  # Whether the build includes each merge commit not already in the cache.
  defp cache_included(cache, merged, build_sha, opts) do
    commit_included? = Keyword.get(opts, :commit_included?, &PullRequest.commit_included?/3)

    included =
      for {pr_url, merge_sha} <- merged,
          not Map.has_key?(cache.included, {merge_sha, build_sha}),
          {:ok, included?} <- [commit_included?.(pr_url, merge_sha, build_sha)],
          into: %{},
          do: {{merge_sha, build_sha}, included?}

    %{cache | included: Map.merge(cache.included, included)}
  end

  # The pull request's repository is the one the build was released from, for example
  # `https://github.com/acme/symphony/pull/12` for a build of `https://github.com/acme/symphony`.
  defp same_repo?(pr_url, build_repo) do
    case Regex.run(~r{\A(https://[^/]+/[^/]+/[^/]+)/pull/\d+}, pr_url) do
      [_match, repo_url] -> Repo.same?(Repo.gh_repo_from_url(repo_url), Repo.gh_repo_from_url(build_repo))
      nil -> false
    end
  end

  # A blocker reopened since the poll is left out: its pull request may not be its last.
  defp terminal?(state, terminal_states) when is_binary(state), do: Enum.any?(terminal_states, &(normalize(&1) == normalize(state)))
  defp terminal?(_state, _terminal_states), do: false

  defp skip_labelled?(%Issue{labels: labels}), do: Enum.any?(labels, &(is_binary(&1) and normalize(&1) == @skip_label))

  defp build_reason(%{pull_request: number} = blocker) do
    %{kind: :build, waits_on: %{pull_request: number}, text: "Waiting for a Symphony update that includes #{fix_name(blocker)}"}
  end

  defp fix_name(%{identifier: identifier}) when is_binary(identifier), do: "#{identifier}'s fix"
  defp fix_name(%{pull_request: number}), do: "the fix in PR ##{number}"

  # The pull request's number; `same_repo?/2` let through only a URL with one.
  defp pr_number(pr_url) do
    [_match, number] = Regex.run(~r{/pull/(\d+)}, pr_url)
    String.to_integer(number)
  end

  defp normalize(value), do: value |> String.trim() |> String.downcase()
end
