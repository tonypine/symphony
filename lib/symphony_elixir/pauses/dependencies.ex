defmodule SymphonyElixir.Pauses.Dependencies do
  @moduledoc """
  Lifts the `:ticket` reasons of a ticket's pause (`SymphonyElixir.Pauses`, the one writer) that wait
  on another ticket, once that ticket no longer holds it, so such a pause lifts on its own.

  Symphony reads no blocker link of Linear's: a ticket's dependencies are the ones Symphony stores
  (`depends_on` on `SymphonyElixir.TicketState`), and the dispatch gate decides them from the records
  on every pass (`SymphonyElixir.Dispatch.DependsOn`), with no pause. What `sweep/3` keeps in line, in
  the poll task, over a repo's polled tickets:

    * A run's block report pauses its ticket on the open stored dependencies it waits on, one reason
      each ("Waiting for TP-12 to finish", `SymphonyElixir.TransitionGuard`). A reason lifts once the
      ticket it names is no longer an open dependency (`SymphonyElixir.Dispatch.DependsOn.open_for/1`:
      met, or removed), unless that ticket fixed Symphony itself and the running app lacks its merge
      (`SymphonyElixir.UpdateHold.awaiting_update/4`): it then stays until the app includes it. In
      `Todo`, and with the `skip-update-hold` label, it lifts at once: in `Todo` the wait for an app
      update is `SymphonyElixir.UpdateHold`'s own.
    * A fix ticket the self-heal lane filed (`SymphonyElixir.SelfHeal`) is read by its identifier;
      its reason ("Waiting for TP-12 to finish: it fixes what stopped this ticket") clears once it is
      terminal, waiting as above for a fix to Symphony itself. The fix-ticket pointer of the
      self-heal bookkeeping goes with it; the failure signature stays, so a break that comes back
      after the repair is compared against the failure the repair was for.
    * A reason the retired hold on Linear's blocker links set (the rule "Blocked-by links") is
      cleared: nothing sets one any more, and the ticket is held by its stored dependencies alone.

  A landing reason (a competing pull request) is the PR and CI watcher's
  (`SymphonyElixir.PrWatch.Competitors`), and any other reason is left as it is. Each write is
  best-effort: one that fails is made again by the next poll, which finds it still there.
  """

  require Logger

  alias SymphonyElixir.{BuildInfo, Pauses, RunStore, TicketState, Tracker, UpdateHold}
  alias SymphonyElixir.Dispatch.DependsOn
  alias SymphonyElixir.Linear.Issue

  @todo_state "todo"
  @setters %{
    fix_ticket: %{kind: :rule, name: "Self-heal"},
    landing: %{kind: :rule, name: "Competing pull requests"}
  }
  # The rule of the retired hold on Linear's blocker links, whose reasons `sweep/3` clears.
  @retired_setter %{kind: :rule, name: "Blocked-by links"}

  @doc "Who sets the `:ticket` reasons of each source: self-heal's fix tickets and the competing pull requests."
  @spec setter(:fix_ticket | :landing) :: Pauses.set_by()
  def setter(source), do: Map.fetch!(@setters, source)

  @doc """
  Lifts the reasons of each polled issue of `opts[:repo_key]` whose ticket no longer holds it (see
  the moduledoc) and returns how many reasons it cleared, with the `SymphonyElixir.UpdateHold` cache
  its build lookups extended. `opts`: `:repo_key` (required: a polled issue names no repo), `:store`
  (default `SymphonyElixir.RunStore`), `:tracker` (the fix tickets' reads, default
  `SymphonyElixir.Tracker`), `:build` (default `SymphonyElixir.BuildInfo.current/0`),
  `:update_hold_cache`, `:open_dependencies` (`issue_id -> [{dependency, record}]`, default
  `SymphonyElixir.Dispatch.DependsOn.open_for/1`) and `SymphonyElixir.UpdateHold`'s lookup options. A
  ticket whose record can't be read is skipped.
  """
  @spec sweep([Issue.t()], Enumerable.t(String.t()), keyword()) :: {non_neg_integer(), UpdateHold.cache()}
  def sweep(issues, terminal_states, opts) when is_list(issues) do
    repo_key = Keyword.fetch!(opts, :repo_key)
    cache = Keyword.get_lazy(opts, :update_hold_cache, &UpdateHold.empty_cache/0)
    terminal = Enum.to_list(terminal_states)

    Enum.reduce(issues, {0, cache}, fn
      %Issue{id: issue_id} = issue, {count, cache} when is_binary(issue_id) ->
        case record(issue, opts) do
          {:ok, %{} = record} ->
            {changes, cache} = lift(%{record | phase: issue.state || record.phase}, {repo_key, terminal}, cache, opts)
            {count + changes, cache}

          _none ->
            {count, cache}
        end

      _issue, acc ->
        acc
    end)
  end

  defp record(%Issue{id: issue_id}, opts) do
    case store(opts).get_ticket_state(issue_id) do
      {:error, reason} ->
        Logger.warning("Failed to read the record of issue_id=#{issue_id} to lift its pause: #{inspect(reason)}")
        :error

      nil ->
        :none

      stored ->
        {:ok, TicketState.normalize(stored)}
    end
  end

  defp lift(record, {repo_key, terminal}, cache, opts) do
    ticket = {:ticket, record.repo_key || repo_key, record.issue_id}
    reasons = TicketState.pause_reasons(record)
    skip? = skip_labelled?(record)
    now? = skip? or normalize(record.phase) == @todo_state

    {retired, reported} = dependency_reasons(reasons)

    {stale, cache} = met_dependencies(reported, record, {now?, cache}, opts)
    {lifted, cache} = landed_fix_tickets(held(reasons, :fix_ticket), {skip?, terminal, cache}, opts)

    Enum.each(retired, &clear(ticket, &1))
    Enum.each(stale, &clear(ticket, &1))
    Enum.each(lifted, &lift_fix_ticket(ticket, &1, opts))

    {length(retired) + length(stale) + length(lifted), cache}
  end

  # The identifiers of the `:dependency` reasons the retired "Blocked-by links" hold set, and of those
  # a run's block report set.
  defp dependency_reasons(reasons) do
    {retired, reported} =
      reasons
      |> Enum.filter(&(Pauses.ticket_source(&1) == :dependency))
      |> Enum.split_with(&(&1.set_by == @retired_setter))

    {Enum.map(retired, & &1.waits_on.identifier), Enum.map(reported, & &1.waits_on.identifier)}
  end

  # The identifiers of the `:ticket` reasons of `source`.
  defp held(reasons, source), do: for(%{waits_on: %{identifier: identifier}} = reason <- reasons, Pauses.ticket_source(reason) == source, do: identifier)

  # The tickets a block report waits on that are no longer open dependencies, whose reasons clear:
  # all of them in Todo or with the skip label, else those the running app need not wait for.
  defp met_dependencies([], _record, {_now?, cache}, _opts), do: {[], cache}

  defp met_dependencies(identifiers, record, {now?, cache}, opts) do
    open = Keyword.get(opts, :open_dependencies, &DependsOn.open_for/1).(record.issue_id)
    open_identifiers = for {entry, on} <- open, identifier = name(entry, on), do: identifier
    met = Enum.reject(identifiers, &(&1 in open_identifiers))

    if now?, do: {met, cache}, else: Enum.reduce(met, {[], cache}, &lift_released(&1, &2, opts))
  end

  defp lift_released(identifier, {lifted, cache}, opts) do
    case awaiting_released(identifier, cache, opts) do
      {nil, cache} -> {lifted ++ [identifier], cache}
      {_awaiting, cache} -> {lifted, cache}
    end
  end

  defp name(%{identifier: identifier}, _record) when is_binary(identifier), do: identifier
  defp name(_entry, %{issue_identifier: identifier}), do: identifier
  defp name(_entry, _record), do: nil

  # Whether the running app still lacks the fix the ticket `identifier` merged, read from the tracker
  # for its pull requests and labels; one that can't be read is not waited on.
  defp awaiting_released(identifier, cache, opts) do
    case read(identifier, opts) do
      %Issue{} = on -> UpdateHold.awaiting_update(on, build(opts), cache, opts)
      nil -> {nil, cache}
    end
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
