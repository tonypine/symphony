defmodule SymphonyElixir.BlockedHold do
  @moduledoc """
  The Blocked hold: a dependency pauses a ticket in place and lifts on its own.

  A Todo ticket with an open blocked-by blocker gains the
  `Blocked` machine label and a recorded reason (the blockers it waits on) instead of being held
  invisibly. When every blocker goes terminal the hold clears on its own and the ticket dispatches
  — no state move, no person involved. A run that marked its ticket blocked by open tickets and then
  reported a block gets the same dependency hold in its phase (`SymphonyElixir.TransitionGuard`),
  and it lifts the same way; outside `Todo`, a blocker that fixed Symphony itself also waits for the
  running app to include its merge, as the fix-ticket hold below does. `sync/3` reconciles one
  issue's store hold against its blockers; the poll loop runs `sweep/3` over each polled repo's
  issues.

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

  The third is the landing hold (`waits_on` type `landing`): a conflicting pull request waits, in any
  phase, on the open pull requests that change the same files (`SymphonyElixir.PrWatch.Competitors`).
  Only the PR and CI watcher reads those pull requests, so it judges the hold on each of its reads
  (`landing_desired/2`): the hold clears once no competitor is left in the race, and the sweep here
  leaves it alone. A person's `Unblock` lifts it too.

  Only the holds that lift themselves are cleared here — one waiting on an access grant is lifted by
  a person's `Unblock` (see `SymphonyElixir.DirectorMoves`).

  Beside a dependency or fix-ticket hold, the ticket's pause (`SymphonyElixir.Pauses`, the one
  writer) has one `:ticket` reason per ticket the hold waits on (`Pauses.ticket_reason/2`): "Waiting
  for TP-12 to finish". Each sync brings the pause in line with the hold: a reason for a ticket the
  hold waits on and the pause lacks is set (by the rule `reason_setter/1` names), and one for a ticket
  it no longer waits on is cleared — a blocker that went terminal while another is open, or every one
  with the hold — so the pause clears with the last. A dependency hold a run's block report set
  outside Todo keeps naming its terminal blockers until the last one is, but the pause waits only on
  the open ones (and, once none is, on those the hold waits on for an app update). A reason the rules
  or a block report set that no hold names any more is cleared on the next sync, whatever stopped it
  from clearing before. The hold is written first and the reasons after it; a reason write that
  fails is made on the next sync, which finds it missing or still there.
  """

  require Logger

  alias SymphonyElixir.{BuildInfo, Config, Hold, Pauses, RunStore, UpdateHold}
  alias SymphonyElixir.Linear.Issue

  @todo_state "todo"
  @dependency_type "dependency"
  @fix_ticket_type "fix_ticket"
  @landing_type "landing"
  @listed_files 10
  @reason_sources %{@dependency_type => :dependency, @fix_ticket_type => :fix_ticket}
  @setters %{dependency: %{kind: :rule, name: "Blocked-by links"}, fix_ticket: %{kind: :rule, name: "Self-heal"}}

  @typedoc """
  A pull request a landing hold waits on: its ticket when Symphony tracks it, its number, title and
  URL, and the files it shares with the held one.
  """
  @type competitor :: %{
          required(:files) => [String.t()],
          optional(:issue_identifier) => String.t() | nil,
          optional(:pr_number) => pos_integer() | nil,
          optional(:pr_url) => String.t() | nil,
          optional(:title) => String.t() | nil,
          optional(atom()) => term()
        }

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

  @doc "Who sets the pause reasons of a dependency hold (the blocked-by links) and of a fix-ticket hold (self-heal)."
  @spec reason_setter(:dependency | :fix_ticket) :: Pauses.set_by()
  def reason_setter(source), do: Map.fetch!(@setters, source)

  @doc "Whether `hold` is a landing hold: a conflict waiting on the pull requests competing with it."
  @spec landing?(map() | term()) :: boolean()
  def landing?(%{waits_on: %{type: @landing_type}}), do: true
  def landing?(_hold), do: false

  @doc """
  The landing hold for waiting on `competitors`: `Waiting on TP-1 and PR #12 (Title) to land: they
  change the same files (a.ex, b.md)`, keyed by each competitor's ticket, else its pull request.
  """
  @spec landing_attrs([competitor(), ...]) :: map()
  def landing_attrs([_ | _] = competitors) do
    files = competitors |> Enum.flat_map(& &1.files) |> Enum.uniq() |> Enum.take(@listed_files) |> Enum.join(", ")

    %{
      reason: "Waiting on #{Enum.map_join(competitors, " and ", &competitor_name/1)} to land: they change the same files (#{files})",
      clearing_condition: "when every competing pull request lands or leaves the race",
      waits_on: %{type: @landing_type, keys: Enum.map(competitors, &competitor_key/1)}
    }
  end

  @doc """
  What a landing hold calls for, given the competitors still in the race: `:clear` once none is
  left, `{:set, attrs}` when the hold doesn't name the ones left yet, else `:none`. A hold of
  another kind is left as it is.
  """
  @spec landing_desired(map() | nil, [competitor()]) :: {:set, map()} | :clear | :none
  def landing_desired(hold, racing) do
    cond do
      not landing?(hold) -> :none
      racing == [] -> :clear
      Map.get(hold, :reason) == landing_attrs(racing).reason -> :none
      true -> {:set, landing_attrs(racing)}
    end
  end

  defp competitor_name(%{issue_identifier: identifier}) when is_binary(identifier), do: identifier
  defp competitor_name(%{pr_number: number, title: title}) when is_binary(title), do: "PR ##{number} (#{title})"
  defp competitor_name(%{pr_number: number}), do: "PR ##{number}"

  defp competitor_key(%{issue_identifier: identifier}) when is_binary(identifier), do: identifier
  defp competitor_key(competitor), do: Map.get(competitor, :pr_url) || competitor_name(competitor)

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
  up again. A hand-added `Blocked` or `Needs Decision` label with no store record is reported and
  cleared, and a store hold missing its label gets it back, so the board matches the store.
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
    repair_drift(repo_key, issue_id, issue, opts)
    current = Hold.get(repo_key, issue_id, :blocked, opts)

    case action(issue, terminal_states, current, cache, opts) do
      {{:set, attrs}, awaiting, cache} ->
        wanted = waited_on(issue, terminal_states, attrs, awaiting)
        {apply_action(:set, repo_key, issue_id, {current, attrs, wanted}, opts), cache}

      {:clear, _awaiting, cache} ->
        {apply_action(:clear, repo_key, issue_id, current, opts), cache}

      {:none, awaiting, cache} ->
        sync_reasons(repo_key, issue_id, {current, current}, waited_on(issue, terminal_states, current, awaiting))
        {:none, cache}
    end
  end

  # The tickets the pause waits on beside `hold`, by the identifiers a reason takes: the fix ticket of
  # a fix-ticket hold, as long as the hold stands, and the blockers of a dependency hold that are still
  # open or, once none is, those the hold waits on for an app update (`awaiting`). A run's block
  # report holds its ticket outside Todo, where the hold keeps naming a blocker that went terminal
  # until the last one does; its reason goes as soon as it is terminal.
  defp waited_on(issue, terminal_states, hold, awaiting) do
    case reason_source(hold) do
      :dependency ->
        open = for blocker <- Issue.open_blockers(issue, terminal_states), do: Map.get(blocker, :identifier)
        Enum.filter(ticket_keys(hold), &(&1 in open or &1 in awaiting))

      _fix_ticket_or_none ->
        ticket_keys(hold)
    end
  end

  # The pause follows the hold: the reasons of the tickets it waits on (`wanted`) are set, and those of
  # tickets it doesn't wait on cleared — the ones the hold waited on before and the ones a rule or a
  # run's block report set (a ticket has one Blocked hold, so a fix-ticket hold set over a dependency
  # hold leaves the dependency's reasons to clear). With no such hold, a reason they set that is still
  # there — its clear failed, or another hold replaced theirs — is cleared too; any other reason is
  # left as it is. Each write is best-effort, as the hold's ledger writes are: the next sync makes it
  # again.
  defp sync_reasons(repo_key, issue_id, {before, stored}, wanted) do
    ticket = {:ticket, repo_key, issue_id}
    held = held_reasons(ticket)
    owned = for {identifier, set_by} <- held, owned?(set_by), do: identifier

    stale = Enum.uniq(ticket_keys(before) ++ owned) -- wanted

    missing = Enum.reject(wanted, &Map.has_key?(held, &1))
    source = reason_source(stored)
    Enum.each(missing, &Pauses.set(ticket, Pauses.ticket_reason(source, &1), set_by: reason_setter(source)))
    Enum.each(Enum.filter(stale, &Map.has_key?(held, &1)), &Pauses.clear_reason(ticket, ticket_reason_key(&1)))

    :ok
  end

  defp ticket_reason_key(identifier), do: %{kind: :ticket, waits_on: %{identifier: identifier}}

  # The `:ticket` reasons this module answers for: the ones its rules set, and the ones a run's block
  # report set (`SymphonyElixir.TransitionGuard`), which only ever waits on a blocker.
  defp owned?(%{kind: :run}), do: true
  defp owned?(set_by), do: set_by in Map.values(@setters)

  defp reason_source(%{waits_on: %{type: type}}), do: Map.get(@reason_sources, type)
  defp reason_source(_hold), do: nil

  # The tickets a dependency or fix-ticket hold waits on, by the identifiers a reason takes.
  defp ticket_keys(hold) do
    if reason_source(hold), do: Enum.filter(hold.waits_on.keys, &Pauses.identifier?/1), else: []
  end

  # The ticket's `:ticket` reasons, by identifier, with who set each.
  defp held_reasons(ticket) do
    case Pauses.get(ticket) do
      {:ok, %{reasons: reasons}} ->
        for %{kind: :ticket, waits_on: %{identifier: id}} = reason <- reasons, into: %{}, do: {id, reason.set_by}

      _none ->
        %{}
    end
  end

  # What the hold calls for, with the identifiers of the terminal blockers a dependency hold waits on
  # for an app update (none for any other hold) and the build lookups' cache. A fix-ticket hold is
  # judged by the fix ticket's own state, everything else by the issue's blockers. The fix ticket is
  # read from the tracker by the identifier the hold records.
  defp action(issue, terminal_states, %{waits_on: %{type: @fix_ticket_type}} = hold, cache, opts) do
    fix = fix_ticket(hold, opts)

    case fix_ticket_desired(hold, fix && fix.state, terminal_states) do
      :clear -> after_fix_landed(issue, fix, hold, cache, opts)
      :none -> {:none, [], cache}
    end
  end

  defp action(issue, terminal_states, %{waits_on: %{type: @dependency_type}} = hold, cache, opts) do
    case desired(issue, terminal_states, hold) do
      :clear -> after_blockers_landed(issue, hold, cache, opts)
      other -> {other, [], cache}
    end
  end

  # The PR and CI watcher judges a landing hold on its own reads.
  defp action(_issue, _terminal_states, %{waits_on: %{type: @landing_type}}, cache, _opts), do: {:none, [], cache}

  defp action(issue, terminal_states, current, cache, _opts), do: {desired(issue, terminal_states, current), [], cache}

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
        {:clear, [], cache}

      {%{merge_sha: merge_sha}, cache} ->
        {update_wait(hold, update_wait_attrs(hold, fix, merge_sha, build.sha)), [], cache}
    end
  end

  # Every blocker is terminal. A Todo ticket's hold clears at once: its dispatch gate waits for the
  # app update itself (`UpdateHold.hold/4`). A ticket in another phase — held by its run's block
  # report — has no such gate, so its hold waits here, as the fix-ticket hold does, while the running
  # build lacks the merge commit of a blocker that fixed Symphony itself.
  defp after_blockers_landed(%Issue{state: state} = issue, hold, cache, opts) do
    if normalize(state) == @todo_state or skip_labelled?(issue) do
      {:clear, [], cache}
    else
      build = Keyword.get_lazy(opts, :build, &BuildInfo.current/0)

      case blockers_awaiting_update(issue.blocked_by, build, cache, opts) do
        {[], cache} ->
          {:clear, [], cache}

        {waiting, cache} ->
          {update_wait(hold, dependency_update_attrs(hold, waiting, build.sha)), identifiers(waiting), cache}
      end
    end
  end

  # A hold already waiting for the app update in these words is left as it is.
  defp update_wait(hold, attrs), do: if(attrs.reason == Map.get(hold, :reason), do: :none, else: {:set, attrs})

  defp identifiers(merged), do: Enum.map(merged, & &1.identifier)

  # No build sha (a build from a checkout): nothing can be compared, so nothing is waited on.
  defp blockers_awaiting_update(_blockers, %{sha: nil}, cache, _opts), do: {[], cache}

  defp blockers_awaiting_update(blockers, build, cache, opts) do
    {waiting, cache} =
      Enum.reduce(blockers, {[], cache}, fn blocker, {waiting, cache} ->
        case UpdateHold.awaiting_update(blocker_issue(blocker, cache, opts), build, cache, opts) do
          {nil, cache} -> {waiting, cache}
          {merged, cache} -> {[merged | waiting], cache}
        end
      end)

    {Enum.reverse(waiting), cache}
  end

  # A blocker `UpdateHold` already knows needs no read; any other is read from the tracker for its
  # pull requests and labels. One that can't be read is not waited on, as `UpdateHold` does.
  defp blocker_issue(blocker, cache, opts) do
    id = Map.get(blocker, :id)
    identifier = Map.get(blocker, :identifier)

    if Map.has_key?(cache.blockers, id),
      do: %Issue{id: id, identifier: identifier},
      else: read_blocker(identifier, opts)
  end

  defp read_blocker(identifier, opts) when is_binary(identifier) do
    case tracker(opts).fetch_issue_by_identifier(identifier) do
      {:ok, %Issue{} = blocker} -> blocker
      _unreadable -> nil
    end
  end

  defp read_blocker(_identifier, _opts), do: nil

  defp dependency_update_attrs(hold, waiting, build_sha) do
    merged = Enum.map_join(waiting, ", ", &"#{&1.identifier} merged in `#{BuildInfo.short_sha(&1.merge_sha)}`")
    identifiers = Enum.map_join(waiting, ", ", & &1.identifier)

    %{
      reason: "waiting for an app update: #{merged}, running `#{BuildInfo.short_sha(build_sha)}`",
      clearing_condition: "when the running app includes the merge of #{identifiers}",
      waits_on: hold.waits_on
    }
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

  defp apply_action(:set, repo_key, issue_id, {current, attrs, wanted}, opts) do
    case Hold.set(repo_key, issue_id, :blocked, attrs, opts) do
      :ok ->
        sync_reasons(repo_key, issue_id, {current, attrs}, wanted)
        :set

      {:error, reason} ->
        log_failure("set", issue_id, reason)
    end
  end

  defp apply_action(:clear, repo_key, issue_id, current, opts) do
    case Hold.clear(repo_key, issue_id, :blocked, opts) do
      :ok ->
        drop_stale_fix_ticket(repo_key, issue_id, current, opts)
        sync_reasons(repo_key, issue_id, {current, nil}, [])
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

  # The store is the truth for a hold, so the board is repaired to match it in both directions, for
  # both kinds of hold. A hold label with no store hold is a hand-added label: report it and clear
  # it. A store hold whose label is missing — its label write failed, or a person removed it by
  # hand — is re-projected from the store, so a hold that is pausing dispatch is never silently
  # invisible. The Inbox reads held tickets from the store, not by their label, so this poll is what
  # keeps a `Needs Decision` label in line with its hold.
  defp repair_drift(repo_key, issue_id, %Issue{} = issue, opts) do
    case Hold.report_drift(repo_key, issue_id, issue.labels, Keyword.merge(opts, identifier: issue.identifier, url: issue.url)) do
      {:stray_label, kind} -> clear_label(repo_key, issue_id, kind, opts)
      {:missing_label, kind} -> reproject_label(repo_key, issue_id, kind, opts)
      :ok -> :ok
    end
  end

  defp clear_label(repo_key, issue_id, kind, opts) do
    _ = Hold.clear(repo_key, issue_id, kind, opts)
    :ok
  end

  defp reproject_label(repo_key, issue_id, kind, opts) do
    _ = Hold.reproject(repo_key, issue_id, kind, opts)
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
