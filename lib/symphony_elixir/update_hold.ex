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

  `resolve/5` does the lookups (Linear for the blocker's pull requests, GitHub for the merge commit
  and whether the build includes it) and keeps their answers in a cache; `hold/4` only reads the
  cache. A lookup that fails is left out of the cache, so the ticket is not held, as before.
  """

  alias SymphonyElixir.{BuildInfo, Tracker}
  alias SymphonyElixir.GitHub.{PullRequest, Repo}
  alias SymphonyElixir.Linear.Issue

  @skip_label "skip-update-hold"
  @todo_state "todo"

  @typedoc """
  What a blocker needs from the app: `:skip` (opted out), `:none` (no merged pull request in the
  build's repository) or the pull request and the commit it merged as.
  """
  @type blocker_fact :: :skip | :none | {:merged, String.t(), String.t()}

  @type cache :: %{
          blockers: %{String.t() => blocker_fact()},
          included: %{{String.t(), String.t()} => boolean()}
        }

  @type hold :: %{
          blockers: [%{identifier: String.t() | nil, merge_sha: String.t()}],
          build_sha: String.t(),
          reason: String.t()
        }

  @spec skip_label() :: String.t()
  def skip_label, do: @skip_label

  @spec empty_cache() :: cache()
  def empty_cache, do: %{blockers: %{}, included: %{}}

  @doc """
  Looks up what `hold/4` needs for the held candidates among `issues` and returns the cache with
  the answers added. Blockers and merge commits already in the cache are not looked up again.

  Options: `:fetch_issues` (`[id] -> {:ok, [Issue.t()]}`), `:merge_commit_sha`
  (`pr_url -> {:ok, sha | nil}`) and `:commit_included?` (`pr_url, sha, build_sha -> {:ok, boolean}`).
  """
  @spec resolve([Issue.t()], BuildInfo.t(), cache(), Enumerable.t(String.t()), keyword()) :: cache()
  def resolve(issues, %{sha: build_sha, repo: build_repo} = build, cache, terminal_states, opts)
      when is_binary(build_sha) and is_binary(build_repo) do
    candidates = Enum.filter(issues, &candidate?(&1, terminal_states))

    cache
    |> resolve_blockers(candidates, build, terminal_states, opts)
    |> resolve_included(candidates, build, opts)
  end

  def resolve(_issues, _build, cache, _terminal_states, _opts), do: cache

  @doc """
  The hold on `issue`, or nil when it may be dispatched as far as app updates go. It is held while a
  blocker's merge commit is known to be missing from the running build.
  """
  @spec hold(Issue.t(), BuildInfo.t(), cache(), Enumerable.t(String.t())) :: hold() | nil
  def hold(%Issue{} = issue, %{sha: build_sha, repo: build_repo}, cache, terminal_states)
      when is_binary(build_sha) and is_binary(build_repo) do
    waiting =
      if candidate?(issue, terminal_states) do
        for %{id: blocker_id} = blocker <- issue.blocked_by,
            {:merged, _pr_url, merge_sha} <- [Map.get(cache.blockers, blocker_id)],
            Map.get(cache.included, {merge_sha, build_sha}) == false do
          %{identifier: Map.get(blocker, :identifier), merge_sha: merge_sha}
        end
      else
        []
      end

    if waiting != [] do
      %{blockers: waiting, build_sha: build_sha, reason: reason(waiting, build_sha)}
    end
  end

  def hold(_issue, _build, _cache, _terminal_states), do: nil

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
  # error when one failed to load and none merged.
  defp merged_pull_request(%Issue{pr_urls: pr_urls}, build, opts) do
    merge_commit_sha = Keyword.get(opts, :merge_commit_sha, &PullRequest.merge_commit_sha/1)

    pr_urls
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
    commit_included? = Keyword.get(opts, :commit_included?, &PullRequest.commit_included?/3)

    merged =
      for %Issue{blocked_by: blockers} <- candidates,
          %{id: blocker_id} <- blockers,
          {:merged, pr_url, merge_sha} <- [Map.get(cache.blockers, blocker_id)],
          not Map.has_key?(cache.included, {merge_sha, build_sha}),
          uniq: true,
          do: {pr_url, merge_sha}

    included =
      for {pr_url, merge_sha} <- merged,
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

  defp reason(waiting, build_sha) do
    merged = Enum.map_join(waiting, ", ", &"#{&1.identifier || "a blocker"} merged in `#{BuildInfo.short_sha(&1.merge_sha)}`")
    "waiting for an app update: #{merged}, running `#{BuildInfo.short_sha(build_sha)}`"
  end

  defp normalize(value), do: value |> String.trim() |> String.downcase()
end
