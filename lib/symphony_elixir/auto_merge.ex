defmodule SymphonyElixir.AutoMerge do
  @moduledoc """
  Lands an approved (`Merging`) issue's pull request with GitHub auto-merge instead of a
  landing agent.

  The PR review poller calls `step/5` for every poll of a `Merging` issue's open PR. It turns
  on auto-merge once per head, and asks GitHub to merge the base branch in once per head when
  the PR is `BEHIND`. GitHub merges the PR when the required checks pass; the poller then
  moves the issue to `Done`. When GitHub refuses auto-merge (the PR can already merge, the
  branch has no protection, or the repository doesn't allow it) but the PR is `CLEAN` with
  green or no checks, it is squash-merged right away. Merge conflicts take the PR poller's
  conflict path, with auto-merge turned off first (see `disable_for_conflict/5`). Red CI takes
  the CI poller's fix path; a fix run that can push code turns auto-merge off first too (see
  `disable_for_ci_fix/5`), while a flaky rerun of the same commit leaves it on.

  A head that moves between reading the PR and turning auto-merge on (a push, or an
  update-branch) is retried with the head the next poll reads; only a head that keeps moving
  falls back.

  When auto-merge can't be used otherwise (a permission error, a refused PR that isn't clean
  and green, or the PR stays blocked on a green head), the issue falls back to the landing
  agent. The state lives under `:auto_merge` in the PR review record.
  """

  require Logger

  alias SymphonyElixir.{CiPoller, Config}
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue

  @merging_state "merging"
  @behind_merge_state "BEHIND"
  @blocked_merge_state "BLOCKED"
  @clean_merge_state "CLEAN"
  @passing_conclusions ["success", "neutral", "skipped"]
  @green_conclusion "SUCCESS"
  @max_reason_length 300
  @max_head_moved_retries 3

  @type state :: String.t()
  @type t :: %{
          state: state(),
          head_sha: String.t() | nil,
          enabled_head_sha: String.t() | nil,
          update_branch_head_sha: String.t() | nil,
          stalled_since: DateTime.t() | nil,
          head_moved_retries: non_neg_integer(),
          disabled_at: DateTime.t() | nil,
          reason: String.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Auto-merge runs with PR polling on (`pull_requests.enabled`) and `pull_requests.auto_merge` on."
  @spec enabled?(map()) :: boolean()
  def enabled?(%{pr_review: %{mode: "polling", auto_merge: true}}), do: true
  def enabled?(_settings), do: false

  @doc "True when the issue is in `Merging`."
  @spec merging?(term()) :: boolean()
  def merging?(%Issue{state: state}) when is_binary(state), do: normalize(state) == @merging_state
  def merging?(_issue), do: false

  @doc """
  True when auto-merge lands this issue, so the orchestrator must not dispatch a landing
  agent: the issue is in `Merging`, has a PR, auto-merge is on for its repository, and the
  PR poller hasn't fallen back to the landing agent.
  """
  @spec owns_issue?(Issue.t(), keyword()) :: boolean()
  def owns_issue?(%Issue{} = issue, opts \\ []) do
    merging?(issue) and match?([url | _] when is_binary(url), issue.pr_urls) and
      enabled_for_repo?(issue.repo_key) and
      not fallback?(Keyword.get(opts, :lookup, &SymphonyElixir.PrReviewPoller.auto_merge/2).(issue.id, repo_opts(issue.repo_key)))
  end

  defp enabled_for_repo?(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> enabled?(settings)
      {:error, _reason} -> false
    end
  end

  defp repo_opts(repo_key) when is_binary(repo_key) and repo_key != "", do: [repo_key: repo_key]
  defp repo_opts(_repo_key), do: []

  @doc "True once the record's auto-merge state hands the issue to the landing agent."
  @spec fallback?(term()) :: boolean()
  def fallback?(%{state: "fallback"}), do: true
  def fallback?(_auto_merge), do: false

  @doc """
  True while auto-merge is off for a CI-fix run (see `disable_for_ci_fix/5`). It stays off until
  the issue leaves `Merging` and is approved into it again.
  """
  @spec held?(term()) :: boolean()
  def held?(%{state: "ci_failure"}), do: true
  def held?(_auto_merge), do: false

  @doc "True when Symphony turned auto-merge on (or merged) for this record, so a later merge moves the issue to `Done`."
  @spec armed?(term()) :: boolean()
  def armed?(%{state: state}) when state in ["enabled", "updating_branch", "merging", "conflict"], do: true
  def armed?(_auto_merge), do: false

  @doc """
  One poll of a `Merging` issue's open, conflict-free PR. Returns the new auto-merge state:

    * `{:ok, auto_merge}`: nothing more to do this poll.
    * `{:conflict, auto_merge}`: GitHub couldn't merge the base branch in; take the conflict path.
    * `{:fallback, auto_merge}`: auto-merge can't land it; the landing agent takes over.
  """
  @spec step(map(), map(), map(), keyword(), DateTime.t()) :: {:ok | :conflict | :fallback, t()}
  def step(record, activity, settings, opts, %DateTime{} = now) do
    previous = Map.get(record, :auto_merge)
    head = Map.get(activity, :head_ref_oid)
    current = for_head(previous, head, now)

    result =
      cond do
        fallback?(current) or held?(current) -> {:ok, current}
        not is_binary(head) or not is_binary(Map.get(activity, :pr_node_id)) -> {:ok, %{current | state: current.state || "waiting"}}
        true -> current |> ensure_enabled(record, activity, opts) |> continue(record, activity, settings, opts, now)
      end

    log_transition(record, previous, result)
    result
  end

  defp continue({:ok, %{state: "merging"}} = result, _record, _activity, _settings, _opts, _now), do: result
  # The head moved under the enable call: nothing else acts on the stale head this poll.
  defp continue({:retry, current}, _record, _activity, _settings, _opts, _now), do: {:ok, current}
  defp continue({:ok, current}, record, activity, settings, opts, now), do: keep_up_to_date(current, record, activity, settings, opts, now)
  defp continue(result, _record, _activity, _settings, _opts, _now), do: result

  defp for_head(previous, head, now) when is_map(previous) do
    base = Map.merge(empty(now), Map.take(previous, Map.keys(empty(now))))

    if base.head_sha == head do
      %{base | updated_at: now}
    else
      %{base | head_sha: head, stalled_since: nil, reason: nil, state: next_head_state(base.state), updated_at: now}
    end
  end

  defp for_head(_previous, head, now), do: %{empty(now) | head_sha: head}

  # A new head starts over from "enabled". A fallback or a CI-fix hold stays until the issue
  # leaves `Merging` (the PR poller clears it then), so pushes during that stay don't flip it back.
  defp next_head_state(state) when state in ["conflict", "merging", "updating_branch"], do: "enabled"
  defp next_head_state(state), do: state

  defp empty(now) do
    %{
      state: nil,
      head_sha: nil,
      enabled_head_sha: nil,
      update_branch_head_sha: nil,
      stalled_since: nil,
      head_moved_retries: 0,
      disabled_at: nil,
      reason: nil,
      updated_at: now
    }
  end

  # Turn auto-merge on once per head. GitHub keeps it on across later pushes, so a PR that
  # already shows it on needs nothing.
  defp ensure_enabled(current, record, activity, opts) do
    head = current.head_sha

    cond do
      Map.get(activity, :auto_merge_enabled) == true ->
        {:ok, %{current | state: enabled_state(current.state), enabled_head_sha: current.enabled_head_sha || head, head_moved_retries: 0, disabled_at: nil}}

      current.enabled_head_sha == head ->
        {:ok, %{current | state: enabled_state(current.state)}}

      true ->
        enable(current, record, activity, opts)
    end
  end

  # Keep what this head is already doing (updating, merging, conflict); otherwise it waits for CI.
  defp enabled_state(state) when state in [nil, "waiting"], do: "enabled"
  defp enabled_state(state), do: state

  defp enable(current, record, activity, opts) do
    github = Keyword.get(opts, :github, PullRequest)
    request = squash_request(activity, current.head_sha)
    pr_url = pr_url(record, activity)
    gh_opts = [cwd: Map.get(record, :workspace_path)]

    case github.enable_auto_merge(pr_url, request, gh_opts) do
      :ok ->
        {:ok, %{current | state: "enabled", enabled_head_sha: current.head_sha, head_moved_retries: 0, disabled_at: nil}}

      {:error, :head_moved} ->
        head_moved(current, record)

      {:error, reason} ->
        refused(current, record, pr_url, request, format_reason(reason), github, gh_opts)
    end
  end

  # The head moved between reading the PR and this call (a push, or an update-branch; auto-merge
  # may even be on already). Keep the record as it is and try again with the head the next
  # poll reads. Only a head that keeps moving goes to the landing agent.
  defp head_moved(current, record) do
    retries = current.head_moved_retries + 1

    if retries >= @max_head_moved_retries do
      fallback(%{current | head_moved_retries: retries}, "the PR head moved #{retries} times in a row before auto-merge could be enabled")
    else
      reason = "the PR head moved from #{short_sha(current.head_sha)} before auto-merge could be enabled"
      Logger.warning("Auto-merge #{identifier(record)}: #{reason}; retrying on the next poll commit_sha=#{current.head_sha}")
      {:retry, %{current | state: current.state || "waiting", head_moved_retries: retries, reason: reason}}
    end
  end

  # GitHub refuses auto-merge for a PR that can already merge (`clean status`), on a branch
  # without protection, or in a repository that doesn't allow it. Look at the PR again: one
  # that merged meanwhile takes the merged path, and a clean one with green or no checks is
  # squash-merged now. Anything else goes to the landing agent.
  defp refused(current, record, pr_url, request, reason, github, gh_opts) do
    head = current.head_sha

    case github.fetch_ci_status(pr_url, gh_opts) do
      {:ok, %{state: "MERGED"}} ->
        Logger.info("Auto-merge #{identifier(record)}: GitHub refused auto-merge (#{reason}); the PR is already merged pr_url=#{pr_url}")
        {:ok, %{current | state: "merging", enabled_head_sha: head}}

      {:ok, %{commit_sha: ^head} = status} ->
        if mergeable_now?(status) do
          merge_now(current, record, pr_url, request, reason, github, gh_opts)
        else
          fallback(current, "enabling auto-merge failed: #{reason}")
        end

      _status ->
        fallback(current, "enabling auto-merge failed: #{reason}")
    end
  end

  defp merge_now(current, record, pr_url, request, reason, github, gh_opts) do
    Logger.info("Auto-merge #{identifier(record)}: GitHub refused auto-merge (#{reason}); squash-merging the clean PR directly pr_url=#{pr_url} commit_sha=#{current.head_sha}")

    case github.squash_merge(pr_url, request, gh_opts) do
      :ok -> {:ok, %{current | state: "merging", enabled_head_sha: current.head_sha}}
      {:error, merge_reason} -> fallback(current, "squash merge failed: #{format_reason(merge_reason)}")
    end
  end

  # An open PR GitHub calls CLEAN whose checks all passed. No checks at all counts too: a
  # repository without CI has nothing to wait for.
  defp mergeable_now?(status) do
    Map.get(status, :state) == "OPEN" and merge_state(status) == @clean_merge_state and
      Enum.all?(Map.get(status, :checks, []), &(normalize(Map.get(&1, :conclusion)) in @passing_conclusions))
  end

  defp squash_request(activity, head) do
    %{
      pr_node_id: Map.get(activity, :pr_node_id),
      head_sha: head,
      pr_number: Map.get(activity, :pr_number),
      pr_title: Map.get(activity, :pr_title),
      pr_description: Map.get(activity, :pr_description)
    }
  end

  # BEHIND: ask GitHub to merge the base branch in, once per head. CI then runs on the
  # combined code and auto-merge fires when it passes.
  defp keep_up_to_date(current, record, activity, settings, opts, now) do
    cond do
      merge_state(activity) != @behind_merge_state -> check_stalled(current, record, activity, settings, now)
      current.update_branch_head_sha != current.head_sha -> update_branch(current, record, activity, opts)
      # Already asked GitHub for this head; wait for the merge commit.
      current.state == "conflict" -> {:ok, current}
      true -> {:ok, %{current | state: "updating_branch"}}
    end
  end

  defp update_branch(current, record, activity, opts) do
    github = Keyword.get(opts, :github, PullRequest)

    case github.update_branch(pr_url(record, activity), current.head_sha, cwd: Map.get(record, :workspace_path)) do
      :ok ->
        {:ok, %{current | state: "updating_branch", update_branch_head_sha: current.head_sha, reason: nil}}

      {:error, :conflict} ->
        {:conflict, %{current | state: "conflict", update_branch_head_sha: current.head_sha, reason: "merging the base branch in conflicts"}}

      {:error, reason} ->
        # Transient (or the head moved under us): try again on the next poll.
        reason = format_reason(reason)
        Logger.warning("Auto-merge update-branch failed for #{identifier(record)} commit_sha=#{current.head_sha}: #{reason}")
        {:ok, %{current | reason: "updating the branch failed: #{reason}"}}
    end
  end

  # Auto-merge is on and the head is green, but GitHub still won't merge (for example a
  # required check that never reports). Past `ci.merging_wait_timeout_ms`, hand it to the
  # landing agent.
  defp check_stalled(current, record, activity, settings, now) do
    if Map.get(activity, :auto_merge_enabled) == true and merge_state(activity) == @blocked_merge_state and
         green_head?(record, current.head_sha) do
      stalled_since = current.stalled_since || now

      if DateTime.diff(now, stalled_since, :millisecond) >= settings.ci.merging_wait_timeout_ms do
        fallback(
          %{current | stalled_since: stalled_since},
          "GitHub still reports BLOCKED on green #{short_sha(current.head_sha)} after #{div(settings.ci.merging_wait_timeout_ms, 60_000)} min; a required check may never report"
        )
      else
        {:ok, %{current | stalled_since: stalled_since}}
      end
    else
      {:ok, %{current | stalled_since: nil}}
    end
  end

  defp green_head?(record, head) do
    case CiPoller.observed_head(Map.get(record, :issue_id), repo_opts(Map.get(record, :repo_key))) do
      %{commit_sha: ^head, conclusion: @green_conclusion} -> true
      _observed -> false
    end
  end

  defp fallback(current, reason), do: {:fallback, %{current | state: "fallback", reason: truncate(reason)}}

  @doc "The Linear comment posted when auto-merge falls back to the landing agent."
  @spec fallback_comment(String.t() | nil, t()) :: String.t()
  def fallback_comment(pr_url, %{reason: reason}) do
    "Symphony couldn't land #{pr_url || "this PR"} with GitHub auto-merge (#{reason}), so a landing agent will merge it instead."
  end

  @doc """
  Short status for the dashboard and `/api/v1/state`, for example
  "auto-merge on, waiting for CI on `abc1234`".
  """
  @spec describe(term()) :: String.t() | nil
  def describe(%{state: "enabled", head_sha: head}), do: "auto-merge on, waiting for CI on #{short_sha(head)}"
  def describe(%{state: "updating_branch", head_sha: head}), do: "updating branch (#{short_sha(head)} is behind the base branch)"
  def describe(%{state: "merging", head_sha: head}), do: "merging #{short_sha(head)}"
  def describe(%{state: "conflict", head_sha: head, disabled_at: %DateTime{}}), do: "blocked: conflict on #{short_sha(head)}; auto-merge off until the fix is approved again"
  def describe(%{state: "conflict", head_sha: head}), do: "blocked: conflict on #{short_sha(head)}"
  def describe(%{state: "ci_failure", head_sha: head}), do: "auto-merge off: CI failed on #{short_sha(head)}; the fix goes back through review"
  def describe(%{state: "fallback", reason: reason}), do: "fell back to the landing agent: #{reason}"
  def describe(%{state: "merged"}), do: "merged"
  def describe(%{state: "waiting"}), do: "waiting for the PR head"
  def describe(_auto_merge), do: nil

  @doc "Marks the state when the PR poller sends a conflicting PR down the conflict path."
  @spec conflict(term(), String.t() | nil, DateTime.t()) :: t()
  def conflict(previous, head, %DateTime{} = now) do
    %{for_head(previous, head, now) | state: "conflict", reason: "the PR conflicts with the base branch"}
  end

  @doc """
  Turns GitHub auto-merge off for a PR going down the conflict path, before the conflict-fix
  run starts. The approval covered the diff before the conflict, so the fix goes back through
  review, and only a fresh move to `Merging` turns auto-merge on again. `current` is the
  conflict state the poller is about to store. Acts only when auto-merge is on: GitHub shows
  it, or `step/5` turned it on for this head on this poll.

    * `{:ok, auto_merge}`: auto-merge was off already; nothing changed.
    * `{:disabled, auto_merge}`: turned off. `disabled_at` records when, and `enabled_head_sha`
      is cleared so the next `Merging` stay turns it on again, even at the same head.
    * `{:error, reason}`: it couldn't be turned off; the PR must not go to a conflict-fix run yet.
  """
  @spec disable_for_conflict(map(), map(), t(), keyword(), DateTime.t()) :: {:ok | :disabled, t()} | {:error, term()}
  def disable_for_conflict(record, activity, current, opts, %DateTime{} = now) do
    turn_off(record, activity, current, opts, now)
  end

  @doc """
  Turns GitHub auto-merge off for a `Merging` PR whose red head goes to a CI-fix run, before
  that run starts. The fix can push code the approval never covered, so it goes back through
  review. `ci_status` is the CI poller's read of the PR (`pr_node_id`, `auto_merge_enabled`).
  The returned state is a `ci_failure` hold, which `step/5` never turns on again; the PR
  poller drops it once the issue leaves `Merging`, so only a fresh move to `Merging` turns
  auto-merge back on, even when the head didn't change. Results as for `disable_for_conflict/5`.
  """
  @spec disable_for_ci_fix(map(), map(), term(), keyword(), DateTime.t()) :: {:ok | :disabled, t()} | {:error, term()}
  def disable_for_ci_fix(record, ci_status, previous, opts, %DateTime{} = now) do
    head = Map.get(ci_status, :commit_sha)
    current = %{for_head(previous, head, now) | state: "ci_failure", enabled_head_sha: nil, reason: "CI failed; the fix goes back through review"}
    activity = %{pr_url: Map.get(ci_status, :pr_url), pr_node_id: Map.get(ci_status, :pr_node_id), auto_merge_enabled: Map.get(ci_status, :auto_merge_enabled)}

    turn_off(record, activity, current, opts, now)
  end

  defp turn_off(record, activity, current, opts, now) do
    if auto_merge_on?(Map.get(record, :auto_merge), activity, current) do
      case disable(record, activity, opts) do
        :ok -> {:disabled, %{current | enabled_head_sha: nil, disabled_at: now, updated_at: now}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, current}
    end
  end

  # The activity was read before `step/5` ran, so a head that step turned auto-merge on for
  # on this poll counts too.
  defp auto_merge_on?(previous, activity, current) do
    previous_enabled_head = if is_map(previous), do: Map.get(previous, :enabled_head_sha)

    Map.get(activity, :auto_merge_enabled) == true or
      (current.enabled_head_sha == current.head_sha and previous_enabled_head != current.head_sha)
  end

  defp disable(record, activity, opts) do
    github = Keyword.get(opts, :github, PullRequest)

    case Map.get(activity, :pr_node_id) do
      node_id when is_binary(node_id) -> github.disable_auto_merge(pr_url(record, activity), node_id, cwd: Map.get(record, :workspace_path))
      _missing -> {:error, :missing_pr_node_id}
    end
  end

  @doc "The Linear comment posted when auto-merge is turned off for a merge conflict."
  @spec conflict_comment(String.t() | nil) :: String.t()
  def conflict_comment(pr_url) do
    "Symphony turned off GitHub auto-merge on #{pr_url || "this PR"} because it conflicts with the base branch. " <>
      "The approval covered the diff before the conflict, so the conflict fix goes back through review; " <>
      "moving this ticket to Merging again turns auto-merge back on."
  end

  @doc "The Linear comment posted when auto-merge is turned off for a CI-fix run."
  @spec ci_fix_comment(String.t() | nil) :: String.t()
  def ci_fix_comment(pr_url) do
    "Symphony turned off GitHub auto-merge on #{pr_url || "this PR"} because CI failed and a fix run may push new code. " <>
      "The approval covered the diff before the fix, so the fix goes back through review; " <>
      "moving this ticket to Merging again turns auto-merge back on."
  end

  @doc "Marks the state once GitHub reports the PR merged."
  @spec merged(term(), DateTime.t()) :: t()
  def merged(previous, %DateTime{} = now) do
    head = if is_map(previous), do: Map.get(previous, :head_sha)
    %{for_head(previous, head, now) | state: "merged", reason: nil}
  end

  @doc "Logs a line when the auto-merge state changes."
  @spec log_transition(map(), term(), {atom(), t()} | t()) :: :ok
  def log_transition(record, previous, {_result, current}), do: log_transition(record, previous, current)

  def log_transition(record, previous, %{} = current) do
    if transition?(previous, current) do
      message = "Auto-merge #{identifier(record)}: #{describe(current)} pr_url=#{Map.get(record, :pr_url)}"
      if current.state == "fallback", do: Logger.error(message), else: Logger.info(message)
    end

    :ok
  end

  defp transition?(%{state: state, head_sha: head}, %{state: state, head_sha: head}), do: false
  defp transition?(_previous, %{state: nil}), do: false
  defp transition?(_previous, _current), do: true

  defp merge_state(activity), do: activity |> Map.get(:merge_state_status) |> normalize() |> String.upcase()

  defp pr_url(record, activity), do: Map.get(activity, :pr_url) || Map.get(record, :pr_url)

  defp identifier(record), do: Map.get(record, :issue_identifier) || Map.get(record, :issue_id)

  defp short_sha(sha) when is_binary(sha), do: "`#{String.slice(sha, 0, 7)}`"
  defp short_sha(_sha), do: "an unknown head"

  defp format_reason(:clean_status), do: "the PR can already merge"
  defp format_reason({:gh_failed, _args, status, output}) when is_binary(output), do: "#{String.trim(output)} (exit #{status})"
  defp format_reason(reason), do: inspect(reason)

  defp truncate(reason) do
    reason = reason |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(reason) > @max_reason_length, do: String.slice(reason, 0, @max_reason_length) <> "…", else: reason
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
