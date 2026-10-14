defmodule SymphonyElixir.BlockedHold do
  @moduledoc """
  The Blocked hold: a dependency pauses a ticket in place and lifts on its own.

  A Todo ticket with an open blocked-by blocker gains the
  `Blocked` machine label and a recorded reason (the blockers it waits on) instead of being held
  invisibly. When every blocker goes terminal the hold clears on its own and the ticket dispatches
  — no state move, no person involved. `sync/3` reconciles one issue's store hold against its
  blockers; the poll loop runs `sweep/3` over each polled repo's issues.

  The other hold that lifts on its own is the self-heal lane's: a ticket blocked on the fix ticket
  `SymphonyElixir.SelfHeal` filed waits for that ticket, and resumes in place the moment it goes
  terminal — the fix landed, so the flow retries with nothing asked of a person. A fix to Symphony
  itself (its pull request merged in the repository the running build comes from) only helps once
  the running app includes it, as `SymphonyElixir.UpdateHold` holds a `Todo` ticket: the hold stays,
  its reason saying it waits for the app update, until the running build includes the fix's merge
  commit, then lifts on its own. Only the stale
  fix-ticket pointer is dropped with the hold: the failure signature stays, so a break that comes
  back after the repair is compared against the failure the repair was for rather than judged as a
  fresh one that files another fix ticket.

  Only the holds that lift themselves are cleared here — one waiting on an access grant is lifted by
  a person's `Unblock` (see `SymphonyElixir.DirectorMoves`).
  """

  require Logger

  alias SymphonyElixir.{BuildInfo, Config, Hold, RunStore, UpdateHold}
  alias SymphonyElixir.Linear.Issue

  @todo_state "todo"
  @dependency_type "dependency"
  @fix_ticket_type "fix_ticket"

  @typedoc "What the dependency state calls for: set the hold, clear it, or leave it as it is."
  @type action :: {:set, map()} | :clear | :none

  @doc """
  The action the issue's blockers call for, given the blocked hold it already has (or nil):
  `{:set, attrs}` when a Todo ticket has an open blocker and no hold yet describes it, `:clear`
  when the hold it has waits on blockers that are now all terminal, else `:none`.
  """
  @spec desired(Issue.t() | term(), Enumerable.t(String.t()), map() | nil) :: action()
  def desired(%Issue{} = issue, terminal_states, current_hold) do
    open = Issue.open_blockers(issue, terminal_states)

    cond do
      dependency_hold?(current_hold) and open == [] ->
        :clear

      todo_with_open_blockers?(issue, open) and not same_dependency?(current_hold, open) ->
        {:set, dependency_attrs(open)}

      true ->
        :none
    end
  end

  def desired(_issue, _terminal_states, _current_hold), do: :none

  @doc """
  The action a fix-ticket hold calls for, given the state of the fix ticket it waits on: `:clear`
  once that ticket is terminal — the fix landed, so the affected ticket resumes in place — else
  `:none`. A hold waiting on something else, or a fix ticket whose state could not be read, is left
  as it is.
  """
  @spec fix_ticket_desired(map() | term(), String.t() | nil, Enumerable.t(String.t())) :: :clear | :none
  def fix_ticket_desired(%{waits_on: %{type: @fix_ticket_type, keys: [identifier | _]}}, state, terminal_states)
      when is_binary(identifier) do
    if terminal?(state, terminal_states), do: :clear, else: :none
  end

  def fix_ticket_desired(_hold, _state, _terminal_states), do: :none

  @doc """
  Reconciles the Blocked hold of one issue against its blockers. `opts[:settings]` is the repo's
  resolved settings (the poll loop passes it once per repo); without it the issue's repo is
  resolved through `Config.settings_for_repo/1`. A polled issue carries no repo key, so
  `opts[:repo_key]` names the repo it was polled for, and the hold is read and written under it.
  Returns `:skipped` when the issue's repo can't be resolved, else the action taken (`:set`,
  `:clear` or `:none`).

  A fix-ticket hold whose fix is terminal checks the running build (`opts[:build]`, default
  `SymphonyElixir.BuildInfo.current/0`) through `SymphonyElixir.UpdateHold.awaiting_update/4`, with
  its lookup options and `opts[:update_hold_cache]` (default empty).
  """
  @spec sync(Issue.t() | term(), Enumerable.t(String.t()), keyword()) :: :skipped | :set | :clear | :none
  def sync(issue, terminal_states, opts \\ []) do
    {action, _cache} = sync_cached(issue, terminal_states, update_hold_cache(opts), opts)
    action
  end

  @doc """
  Runs `sync/3` over a repo's polled issues and returns how many holds it changed, with the
  `SymphonyElixir.UpdateHold` cache its build lookups extended, so the next poll does not look them
  up again. A hand-added `Blocked` label with no store record is reported and cleared, so the board
  matches the store.
  """
  @spec sweep([Issue.t()] | term(), Enumerable.t(String.t()), keyword()) :: {non_neg_integer(), UpdateHold.cache()}
  def sweep(issues, terminal_states, opts \\ []) do
    issues = if is_list(issues), do: issues, else: []

    Enum.reduce(issues, {0, update_hold_cache(opts)}, fn issue, {count, cache} ->
      {action, cache} = sync_cached(issue, terminal_states, cache, opts)
      {if(action in [:set, :clear], do: count + 1, else: count), cache}
    end)
  end

  defp sync_cached(issue, terminal_states, cache, opts) do
    with %Issue{} = issue <- with_repo_key(issue, Keyword.get(opts, :repo_key)),
         %{} <- settings(issue, opts) do
      sync_issue(issue, terminal_states, cache, opts)
    else
      _skipped -> {:skipped, cache}
    end
  end

  defp with_repo_key(%Issue{repo_key: key} = issue, repo_key) when key in [nil, ""] and is_binary(repo_key),
    do: %{issue | repo_key: repo_key}

  defp with_repo_key(issue, _repo_key), do: issue

  defp sync_issue(%Issue{id: issue_id, repo_key: repo_key} = issue, terminal_states, cache, opts) do
    repair_drift(repo_key, issue_id, issue.labels, opts)
    current = Hold.get(repo_key, issue_id, :blocked, opts)

    case action(issue, terminal_states, current, cache, opts) do
      {{:set, attrs}, cache} ->
        {apply_action(:set, repo_key, issue_id, attrs, opts), cache}

      {:clear, cache} ->
        {apply_action(:clear, repo_key, issue_id, current, opts), cache}

      {:none, cache} ->
        {:none, cache}
    end
  end

  # A fix-ticket hold is judged by the fix ticket's own state, everything else by the issue's
  # blockers. The fix ticket is read from the tracker by the identifier the hold records.
  defp action(issue, terminal_states, %{waits_on: %{type: @fix_ticket_type}} = hold, cache, opts) do
    fix = fix_ticket(hold, opts)

    case fix_ticket_desired(hold, fix && fix.state, terminal_states) do
      :clear -> after_fix_landed(issue, fix, hold, cache, opts)
      :none -> {:none, cache}
    end
  end

  defp action(issue, terminal_states, current, cache, _opts), do: {desired(issue, terminal_states, current), cache}

  defp fix_ticket(%{waits_on: %{keys: [identifier | _]}}, opts) when is_binary(identifier) do
    case tracker(opts).fetch_issue_by_identifier(identifier) do
      {:ok, %Issue{} = fix} -> fix
      _unreadable -> nil
    end
  end

  defp fix_ticket(_hold, _opts), do: nil

  # The fix ticket is terminal. A fix to Symphony itself helps only once the running app includes
  # it, so while the running build lacks its merge commit the hold stays, its reason saying so
  # (written once, then left alone), and it lifts on the poll that sees the updated app.
  defp after_fix_landed(issue, fix, hold, cache, opts) do
    build = Keyword.get_lazy(opts, :build, &BuildInfo.current/0)

    case awaiting_update(issue, fix, build, cache, opts) do
      {nil, cache} ->
        {:clear, cache}

      {%{merge_sha: merge_sha}, cache} ->
        attrs = update_wait_attrs(hold, fix, merge_sha, build.sha)
        {if(attrs.reason == Map.get(hold, :reason), do: :none, else: {:set, attrs}), cache}
    end
  end

  defp awaiting_update(issue, fix, build, cache, opts) do
    if skip_labelled?(issue), do: {nil, cache}, else: UpdateHold.awaiting_update(fix, build, cache, opts)
  end

  defp update_wait_attrs(hold, fix, merge_sha, build_sha) do
    %{
      reason:
        "waiting for an app update: fix ticket #{fix.identifier} merged in `#{BuildInfo.short_sha(merge_sha)}`, " <>
          "running `#{BuildInfo.short_sha(build_sha)}`",
      clearing_condition: "when the running app includes the fix ticket #{fix.identifier}'s merge",
      waits_on: hold.waits_on
    }
  end

  defp skip_labelled?(%Issue{labels: labels}), do: Enum.any?(labels, &(is_binary(&1) and normalize(&1) == UpdateHold.skip_label()))

  defp update_hold_cache(opts), do: Keyword.get_lazy(opts, :update_hold_cache, &UpdateHold.empty_cache/0)

  defp apply_action(:set, repo_key, issue_id, attrs, opts) do
    case Hold.set(repo_key, issue_id, :blocked, attrs, opts) do
      :ok -> :set
      {:error, reason} -> log_failure("set", issue_id, reason)
    end
  end

  defp apply_action(:clear, repo_key, issue_id, current, opts) do
    case Hold.clear(repo_key, issue_id, :blocked, opts) do
      :ok ->
        drop_stale_fix_ticket(repo_key, issue_id, current, opts)
        :clear

      {:error, reason} ->
        log_failure("clear", issue_id, reason)
    end
  end

  # The fix landed, so the fix-ticket pointer is stale and goes. The component, the failure
  # signature and the retry count stay, so a break that comes back after the repair is compared
  # against the failure the repair was for instead of being judged a fresh one.
  defp drop_stale_fix_ticket(repo_key, issue_id, %{waits_on: %{type: @fix_ticket_type}}, opts) do
    case store(opts).clear_ticket_fix_ticket(repo_key, issue_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to drop the stale fix ticket from the self-heal bookkeeping on issue_id=#{issue_id}: #{inspect(reason)}")
    end
  end

  defp drop_stale_fix_ticket(_repo_key, _issue_id, _current, _opts), do: :ok

  # The store is the truth for a hold, so the board is repaired to match it in both directions. A
  # `Blocked` label with no store hold is a hand-added label: report it and clear it. A store hold
  # whose `Blocked` label is missing — its label write failed, or a person removed it by hand — is
  # re-projected from the store, so a hold that is pausing dispatch is never silently invisible.
  defp repair_drift(repo_key, issue_id, labels, opts) do
    case Hold.report_drift(repo_key, issue_id, labels, opts) do
      {:stray_label, :blocked} -> clear_label(repo_key, issue_id, opts)
      {:missing_label, :blocked} -> reproject_label(repo_key, issue_id, opts)
      _ok_or_missing -> :ok
    end
  end

  defp clear_label(repo_key, issue_id, opts) do
    _ = Hold.clear(repo_key, issue_id, :blocked, opts)
    :ok
  end

  defp reproject_label(repo_key, issue_id, opts) do
    _ = Hold.reproject(repo_key, issue_id, :blocked, opts)
    :ok
  end

  defp log_failure(action, issue_id, reason) do
    Logger.warning("Failed to #{action} the Blocked hold on issue_id=#{issue_id}: #{inspect(reason)}")
    :none
  end

  defp dependency_hold?(%{waits_on: %{type: @dependency_type}}), do: true
  defp dependency_hold?(_hold), do: false

  defp terminal?(state, terminal_states) when is_binary(state) do
    normalized = normalize(state)
    Enum.any?(terminal_states || [], &(normalize(&1) == normalized))
  end

  defp terminal?(_state, _terminal_states), do: false

  defp tracker(opts), do: Keyword.get(opts, :tracker, SymphonyElixir.Tracker)

  defp store(opts), do: Keyword.get(opts, :store, RunStore)

  defp todo_with_open_blockers?(%Issue{state: state}, open), do: open != [] and normalize(state) == @todo_state

  defp same_dependency?(hold, open) do
    dependency_hold?(hold) and hold.waits_on.keys == blocker_keys(open)
  end

  defp dependency_attrs(open) do
    keys = blocker_keys(open)

    %{
      reason: "waiting on " <> Enum.join(keys, ", "),
      clearing_condition: "when every blocker is terminal",
      waits_on: %{type: @dependency_type, keys: keys}
    }
  end

  defp blocker_keys(open) do
    open
    |> Enum.map(&(&1.identifier || &1.id))
    |> Enum.reject(&is_nil/1)
  end

  # The repo's resolved settings: the caller's once-per-repo value when it passed one, else resolved
  # from the issue's repo key.
  defp settings(%Issue{repo_key: repo_key}, opts) do
    case Keyword.fetch(opts, :settings) do
      {:ok, settings} -> settings
      :error -> settings_for_repo(repo_key)
    end
  end

  defp settings_for_repo(nil), do: nil

  defp settings_for_repo(repo_key) when is_binary(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> settings
      {:error, _reason} -> nil
    end
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
