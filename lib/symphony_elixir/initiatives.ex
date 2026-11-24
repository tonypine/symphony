defmodule SymphonyElixir.Initiatives do
  @moduledoc """
  Each parent Symphony split, followed to done, for the Mac app's Initiatives
  (`GET /api/v1/initiatives`).

  `read/1` builds the list from Symphony's own records, on each call, with no Linear request:

  - A parent is listed because Symphony split it, as its ledger records it: its current plan is a
    `split` (`SymphonyElixir.TicketPlan.current/1`), or it holds a `ticket.filed` of kind
    `split_off` (a sub-ticket the Conductor or a run filed under it). A Linear label (`plan`,
    `breakdown`) lists nothing: a labelled ticket Symphony did not split is left out.
  - Its sub-tickets are the stored parent and sub-ticket link (`SymphonyElixir.Dispatch.Queue.parents/1`,
    shaped by `SymphonyElixir.Home.SubTickets`, as the Home read takes them), which a sub-ticket keeps
    once done: a done one stays under its parent, a cancelled one is left out.
  - It is listed while open (not in Backlog or Triage) and for 7 days once done.

  Each becomes an `SymphonyElixir.Initiatives.Initiative`; `list/4` adds what each sub-ticket depends
  on (its stored dependencies) and what it waits on from the orchestrator snapshot (what runs) and
  the Inbox (what waits on the Director).
  """

  alias SymphonyElixir.{Config, Inbox, RunStore, TicketPlan, TicketState}
  alias SymphonyElixir.Dispatch.Queue
  alias SymphonyElixir.Home.SubTickets
  alias SymphonyElixir.Inbox.FromRecord
  alias SymphonyElixir.Initiatives.Initiative
  alias SymphonyElixir.TicketEvents.Event

  @split_types ["plan.written", "ticket.filed"]

  @typedoc """
  What a read takes instead of the stores: `:records` (the ticket records, default every stored
  one), `:events` (a ticket's `plan.written` and `ticket.filed` events by its issue id, oldest
  first), `:settings` (a repo's settings by its key, nil when it has none) and `:now`.
  """
  @type opt ::
          {:records, [map()]}
          | {:events, (String.t() -> [Event.t()])}
          | {:settings, (String.t() | nil -> term())}
          | {:now, DateTime.t()}

  @doc "The parents Symphony split, each as an initiative, from the records and ledgers (see the moduledoc)."
  @spec read([opt()]) :: [Initiative.t()]
  def read(opts \\ []) do
    records = opts |> Keyword.get_lazy(:records, &stored_records/0) |> Enum.map(&TicketState.normalize/1)
    events = Keyword.get(opts, :events, &split_events/1)
    settings = Keyword.get(opts, :settings, &repo_settings/1)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    index = SubTickets.index(records, Queue.parents(records))

    for record <- records,
        is_binary(record.issue_id),
        Map.has_key?(index, record.issue_identifier) or record.sub_issues != [],
        started_at = split_at(events.(record.issue_id)),
        started_at != :not_split,
        context = %{settings: settings.(record.repo_key), now: now, started_at: started_at},
        initiative = Initiative.from_record(record, SubTickets.of(record, index), context),
        initiative != nil,
        do: initiative
  end

  # When Symphony split the ticket whose events these are: its first split-off filed, else its
  # split plan's time; `:not_split` when it did not split it.
  defp split_at(events) do
    filed = for %Event{type: "ticket.filed"} = event <- events, field(event.payload, :kind) == "split_off", do: event.at

    planned =
      case TicketPlan.current(events) do
        %{shape: "split", at: at} -> [at]
        _plan -> []
      end

    case filed ++ planned do
      [] -> :not_split
      times -> times |> Enum.filter(&match?(%DateTime{}, &1)) |> Enum.min(DateTime, fn -> nil end)
    end
  end

  defp field(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp stored_records, do: List.wrap(RunStore.list_all_ticket_states())

  defp split_events(issue_id), do: List.wrap(RunStore.list_ticket_events(issue_id, types: @split_types))

  @doc """
  The parent (`identifier` and `title`) that has `issue_id` among its sub-tickets in `initiatives`
  (default: `read/1`'s), or nil when none has it.
  """
  @spec parent_of(String.t(), [Initiative.t()]) :: %{identifier: String.t() | nil, title: String.t() | nil} | nil
  def parent_of(issue_id, initiatives \\ read()) when is_binary(issue_id) do
    Enum.find_value(initiatives, fn initiative ->
      if Enum.any?(initiative.sub_tickets, &(&1.id == issue_id)),
        do: %{identifier: initiative.identifier, title: initiative.title}
    end)
  end

  @doc """
  The initiatives `read/1` gives over `opts`, each with what its sub-tickets wait on: `snapshot`'s
  running tickets, the Inbox `inbox` lists, and the human review states of each repo (`settings_fun`).
  """
  @spec list(map(), [opt()], GenServer.name(), (String.t() -> term())) :: [map()]
  def list(snapshot, opts \\ [], inbox \\ Inbox, settings_fun \\ &repo_settings/1) when is_map(snapshot) do
    running = FromRecord.working_ids(snapshot)
    you = snapshot |> Inbox.items(inbox) |> MapSet.new(& &1.issue_id)

    opts
    |> read()
    |> Enum.map(&Initiative.live(&1, %{running: running, you: you, settings: settings_fun.(&1.repo_key)}))
  end

  defp repo_settings(repo_key) when is_binary(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> settings
      _error -> nil
    end
  end

  defp repo_settings(_repo_key), do: nil
end
