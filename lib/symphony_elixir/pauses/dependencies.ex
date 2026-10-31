defmodule SymphonyElixir.Pauses.Dependencies do
  @moduledoc """
  Keeps the `:ticket` reasons of a ticket's pause (`SymphonyElixir.Pauses`, the one writer) in line
  with the tickets it waits on, so a dependency pauses a ticket in place and lifts on its own.

  `sweep/3` runs in the poll task over a repo's polled tickets. Each one is read as its record
  observes it (`SymphonyElixir.TicketState.observe/4`, the observation the poll writes): its phase,
  its labels and its open blockers. Under `dispatch.source: record`, where dispatch reads every
  repo's records each cycle, `sync_records/3` also brings each `Todo` record's pause in line with the
  open blockers it observed, from the store alone, so a blocker a read wrote into a record holds the
  ticket before its repo's next poll.

    * A `Todo` ticket has one reason per open blocker ("Waiting for TP-12 to finish", set by the rule
      "Blocked-by links"), and a blocker's reason clears once it is no longer open: the ticket
      dispatches with no state move and no person involved. The wait for the running app to include
      a blocker that fixed Symphony itself is `SymphonyElixir.UpdateHold`'s, on the same pause.
    * A run's block report pauses its ticket outside `Todo` on the blockers it named
      (`SymphonyElixir.TransitionGuard`). Each such reason clears once its blocker is no longer open,
      unless the blocker fixed Symphony itself and the running app lacks its merge
      (`SymphonyElixir.UpdateHold.awaiting_update/4`): it then stays until the app includes it.
    * A fix ticket the self-heal lane filed (`SymphonyElixir.SelfHeal`) is read by its identifier;
      its reason ("Waiting for TP-12 to finish: it fixes what stopped this ticket") clears once it is
      terminal, waiting as above for a fix to Symphony itself. The fix-ticket pointer of the
      self-heal bookkeeping goes with it; the failure signature stays, so a break that comes back
      after the repair is compared against the failure the repair was for.

  The `skip-update-hold` label on the ticket skips the wait for an app update. A landing reason
  (a competing pull request) is the PR and CI watcher's (`SymphonyElixir.PrWatch.Competitors`), and
  any other reason is left as it is. Each write is best-effort: one that fails is made again by the
  next poll, which finds it missing or still there.
  """

  require Logger

  alias SymphonyElixir.{BuildInfo, Pauses, RunStore, TicketState, Tracker, UpdateHold}
  alias SymphonyElixir.Linear.Issue

  @todo_state "todo"
  @setters %{
    dependency: %{kind: :rule, name: "Blocked-by links"},
    fix_ticket: %{kind: :rule, name: "Self-heal"},
    landing: %{kind: :rule, name: "Competing pull requests"}
  }

  @doc """
  Who sets the `:ticket` reasons of each source: the blocked-by links, self-heal's fix tickets and
  the competing pull requests.
  """
  @spec setter(Pauses.ticket_source()) :: Pauses.set_by()
  def setter(source), do: Map.fetch!(@setters, source)

  @doc """
  Brings the pause of each polled issue of `opts[:repo_key]` in line with what it waits on (see the
  moduledoc) and returns how many reasons it set or cleared, with the `SymphonyElixir.UpdateHold`
  cache its build lookups extended. `opts`: `:repo_key` (required: a polled issue names no repo),
  `:now`, `:store` (default `SymphonyElixir.RunStore`), `:tracker` (the fix tickets' and blockers'
  reads, default `SymphonyElixir.Tracker`), `:build` (default `SymphonyElixir.BuildInfo.current/0`),
  `:update_hold_cache` and `SymphonyElixir.UpdateHold`'s lookup options. A ticket whose record can't
  be read is skipped.
  """
  @spec sweep([Issue.t()], Enumerable.t(String.t()), keyword()) :: {non_neg_integer(), UpdateHold.cache()}
  def sweep(issues, terminal_states, opts) when is_list(issues) do
    repo_key = Keyword.fetch!(opts, :repo_key)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cache = Keyword.get_lazy(opts, :update_hold_cache, &UpdateHold.empty_cache/0)
    terminal = Enum.to_list(terminal_states)

    Enum.reduce(issues, {0, cache}, fn
      %Issue{id: issue_id} = issue, {count, cache} when is_binary(issue_id) ->
        case observed(repo_key, issue, terminal, now, opts) do
          {:ok, record} ->
            {changes, cache} = sync(record, issue, terminal, cache, opts)
            {count + changes, cache}

          :error ->
            {count, cache}
        end

      _issue, acc ->
        acc
    end)
  end

  # The ticket's record as the poll's observation writes it: its stored record with this read's
  # phase, labels and open blockers.
  defp observed(repo_key, %Issue{id: issue_id} = issue, terminal, now, opts) do
    case store(opts).get_ticket_state(repo_key, issue_id) do
      {:error, reason} ->
        Logger.warning("Failed to read the record of issue_id=#{issue_id} to sync its dependencies: #{inspect(reason)}")
        :error

      stored ->
        record = stored || TicketState.new(repo_key, issue_id)
        {observed, _outcome} = TicketState.observe(record, %{issue | blocked_by: Issue.open_blockers(issue, terminal)}, now, :poll)
        {:ok, observed}
    end
  end

  defp sync(record, issue, terminal, cache, opts) do
    ticket = {:ticket, record.repo_key, record.issue_id}
    reasons = TicketState.pause_reasons(record)
    open = for %{identifier: identifier} <- record.blockers, Pauses.identifier?(identifier), do: identifier
    held = held(reasons, :dependency)
    skip? = skip_labelled?(record)
    todo? = normalize(record.phase) == @todo_state

    missing = if todo?, do: open -- held, else: []
    {stale, cache} = stale_blockers(held -- open, issue, {todo? or skip?, cache}, opts)
    {lifted, cache} = landed_fix_tickets(held(reasons, :fix_ticket), {skip?, terminal, cache}, opts)

    Enum.each(missing, &Pauses.set(ticket, Pauses.ticket_reason(:dependency, &1), set_by: setter(:dependency)))
    Enum.each(stale, &clear(ticket, &1))
    Enum.each(lifted, &lift_fix_ticket(ticket, &1, opts))

    {length(missing) + length(stale) + length(lifted), cache}
  end

  @doc """
  Brings the pause of each `Todo` record of `records` (`SymphonyElixir.TicketState` records) in line
  with the open blockers it observed, as `sweep/3` does for a `Todo` ticket, from the records alone:
  no tracker read and no other phase. `opts[:skip]` names a repo whose records are left out (the one
  this cycle polled, which `sweep/3` swept from the poll's own read). Returns how many reasons it set
  or cleared.
  """
  @spec sync_records([map()], Enumerable.t(String.t()), keyword()) :: non_neg_integer()
  def sync_records(records, terminal_states, opts \\ []) when is_list(records) do
    skip = Keyword.get(opts, :skip)
    terminal = MapSet.new(terminal_states, &normalize/1)

    records
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.filter(&(is_binary(&1.repo_key) and is_binary(&1.issue_id) and &1.repo_key != skip and normalize(&1.phase) == @todo_state))
    |> Enum.reduce(0, fn record, count ->
      open = for blocker <- record.blockers, Pauses.identifier?(blocker.identifier), not MapSet.member?(terminal, normalize(blocker.state)), do: blocker.identifier
      held = held(TicketState.pause_reasons(record), :dependency)
      ticket = {:ticket, record.repo_key, record.issue_id}

      Enum.each(open -- held, &Pauses.set(ticket, Pauses.ticket_reason(:dependency, &1), set_by: setter(:dependency)))
      Enum.each(held -- open, &clear(ticket, &1))
      count + length(open -- held) + length(held -- open)
    end)
  end

  # The identifiers of the `:ticket` reasons of `source`.
  defp held(reasons, source), do: for(%{waits_on: %{identifier: identifier}} = reason <- reasons, Pauses.ticket_source(reason) == source, do: identifier)

  # The blockers no longer open whose reasons clear: all of them in Todo or with the skip label, else
  # those the running app need not wait for.
  defp stale_blockers([], _issue, {_now?, cache}, _opts), do: {[], cache}
  defp stale_blockers(stale, _issue, {true, cache}, _opts), do: {stale, cache}

  defp stale_blockers(stale, issue, {false, cache}, opts) do
    build = build(opts)

    Enum.reduce(stale, {[], cache}, fn identifier, {lifted, cache} ->
      case UpdateHold.awaiting_update(blocker(issue, identifier, cache, opts), build, cache, opts) do
        {nil, cache} -> {lifted ++ [identifier], cache}
        {_awaiting, cache} -> {lifted, cache}
      end
    end)
  end

  # The fix tickets that went terminal, unless the running app still lacks a fix to Symphony itself.
  # A fix ticket that can't be read is waited on.
  defp landed_fix_tickets(identifiers, {skip?, terminal, cache}, opts) do
    Enum.reduce(identifiers, {[], cache}, fn identifier, {lifted, cache} ->
      with %Issue{} = fix <- read(identifier, opts),
           true <- Enum.any?(terminal, &(normalize(&1) == normalize(fix.state))),
           {nil, cache} <- awaiting(fix, skip?, cache, opts) do
        {lifted ++ [identifier], cache}
      else
        {_awaiting, cache} -> {lifted, cache}
        _open_or_unread -> {lifted, cache}
      end
    end)
  end

  defp awaiting(_fix, true = _skip?, cache, _opts), do: {nil, cache}
  defp awaiting(fix, false, cache, opts), do: UpdateHold.awaiting_update(fix, build(opts), cache, opts)

  defp clear(ticket, identifier), do: Pauses.clear_reason(ticket, %{kind: :ticket, waits_on: %{identifier: identifier}})

  # The fix landed, so the fix-ticket pointer is stale and goes with the reason. The component, the
  # failure signature and the retry count stay.
  defp lift_fix_ticket({:ticket, repo_key, issue_id} = ticket, identifier, opts) do
    clear(ticket, identifier)

    with {:error, reason} <- store(opts).clear_ticket_fix_ticket(repo_key, issue_id) do
      Logger.warning("Failed to drop the stale fix ticket from the self-heal bookkeeping on issue_id=#{issue_id}: #{inspect(reason)}")
    end
  end

  # A blocker `UpdateHold` already knows needs no read; any other is read from the tracker for its
  # pull requests and labels. One that can't be read is not waited on, as `UpdateHold` does.
  defp blocker(%Issue{blocked_by: blockers}, identifier, cache, opts) do
    case Enum.find(List.wrap(blockers), &(Map.get(&1, :identifier) == identifier)) do
      %{id: id} when is_map_key(cache.blockers, id) -> %Issue{id: id, identifier: identifier}
      _unknown -> read(identifier, opts)
    end
  end

  defp read(identifier, opts) do
    case Keyword.get(opts, :tracker, Tracker).fetch_issue_by_identifier(identifier) do
      {:ok, %Issue{} = issue} -> issue
      _unreadable -> nil
    end
  end

  defp skip_labelled?(record), do: Enum.any?(record.labels, &(normalize(&1) == UpdateHold.skip_label()))

  defp build(opts), do: Keyword.get_lazy(opts, :build, &BuildInfo.current/0)

  defp store(opts), do: Keyword.get(opts, :store, RunStore)

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
