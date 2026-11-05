defmodule SymphonyElixir.TicketMerge do
  @moduledoc """
  The one record of a ticket a store left under more than one repository (TP-1338), and the report
  of the merges a store's start made. Pure: `SymphonyElixir.RunStore.contract_ticket_key/0` reads the
  records and writes what `merge/3` returns, in the one transaction that moves the store off the
  (repository, ticket) key.

  A ticket's record was keyed by the pair (repository, ticket), and a ticket that moved to another
  Linear project was routed to another repository, where a second record opened: the old one kept
  its questions, pauses and events, stranded. `merge/3` folds them:

    * the repository is the ticket's current route: the one the by-ticket index names, else the one
      whose record observed the ticket last (observations are routed by project);
    * the events of every record, oldest first, each once (by id);
    * the questions of every record: a question two records hold is kept once (its ended copy,
      else the newest), and two open questions with the same title and text collapse to one (the
      route's, else the first asked); the pause reasons of every record, each once; the decisions
      and the path grants of every record, each once;
    * every record's signals, verdicts and dispatches from before the event stream
      (`SymphonyElixir.TicketState.legacy_history/1`), each once, for the ledger's backfill to convert;
    * the newest phase (by when it was written), the newest PR facts (by when they were read), the
      last observation, and the newest record's CI states;
    * an open question only a record of another repository held was asked before the ticket moved
      to its route's project, which answered it: it is withdrawn with the cause
      `superseded_by_move`, its `question.withdrawn` event is recorded, its pause reason goes, and
      the record's `:pause` projection is marked pending, so the reconciler makes Linear follow.
  """

  alias SymphonyElixir.{Pauses, TicketEvents, TicketState}
  alias SymphonyElixir.TicketEvents.Event

  @report_name "records.merged"
  @symphony %{kind: :symphony, name: "Symphony"}
  @cause "superseded_by_move"

  @typedoc "One merged ticket: its id and identifier, the repository it lives under and the ones folded into it."
  @type merged :: %{
          issue_id: String.t(),
          issue_identifier: String.t() | nil,
          repo_key: String.t(),
          folded: [String.t()]
        }

  @typedoc """
  What a store's merges did (`records.merged`): when, how many tickets were checked, how many merged,
  each merge, and the questions withdrawn as `superseded_by_move`.
  """
  @type report :: %{
          name: String.t(),
          at: DateTime.t(),
          checked: non_neg_integer(),
          merged: non_neg_integer(),
          merges: [merged()],
          withdrawn: non_neg_integer()
        }

  @typedoc "One record of a ticket as the store hands it to `merge/3`."
  @type entry :: %{repo_key: String.t(), record: TicketState.t(), events: [Event.t()], indexed: boolean()}

  @typedoc "`merge/3`'s result: the record and events to write under `repo_key`, and the questions it withdrew."
  @type merge :: %{
          repo_key: String.t(),
          record: TicketState.t(),
          events: [Event.t()],
          withdrawn: [map()],
          folded: [String.t()]
        }

  @doc "The one record of ticket `issue_id` from its `entries` (two or more, one per repository), at `now`, as the module doc says."
  @spec merge(String.t(), [entry(), ...], DateTime.t()) :: merge()
  def merge(issue_id, [_first, _second | _rest] = entries, %DateTime{} = now) do
    route = route(entries)
    records = Enum.map(entries, & &1.record)
    newest = Enum.max_by(records, &stamp(&1.updated_at))
    {questions, superseded} = entries |> questions(route) |> supersede(now)
    open = for %{state: :open, id: id} <- questions, into: MapSet.new(), do: id

    record =
      newest
      |> Map.merge(Map.take(phased(entries, route), [:phase, :phase_at, :phase_owner]))
      |> Map.put(:pr_watch, Enum.max_by(records, &stamp(&1.pr_watch && &1.pr_watch.read_at)).pr_watch)
      |> Map.merge(Map.take(observed(records), observed_fields()))
      |> Map.merge(%{
        repo_key: route,
        issue_id: issue_id,
        questions: questions,
        pause: pause(records, route, issue_id, open),
        decisions: union(records, :decisions, & &1.key),
        path_unlocks: union(records, :path_unlocks, & &1.id),
        pending_projection: union(records, :pending_projection, & &1),
        legacy_history: legacy_history(records)
      })

    events =
      entries
      |> Enum.flat_map(& &1.events)
      |> Enum.uniq_by(&event_key/1)
      |> Enum.sort_by(&{stamp(&1.at), &1.seq || 0})

    %{
      repo_key: route,
      record: follow_withdrawals(record, superseded, now),
      events: events ++ Enum.map(superseded, &withdrawal(route, issue_id, &1, record.phase, now)),
      withdrawn: superseded,
      folded: entries |> Enum.map(& &1.repo_key) |> List.delete(route)
    }
  end

  @doc "The report (`t:report/0`) of the `merges` of `issue_id => merge` a start made at `now`, having checked `checked` tickets."
  @spec report([{String.t(), merge()}], non_neg_integer(), DateTime.t()) :: report()
  def report(merges, checked, %DateTime{} = now) do
    %{
      name: @report_name,
      at: now,
      checked: checked,
      merged: length(merges),
      merges: Enum.map(merges, fn {issue_id, merge} -> %{issue_id: issue_id, issue_identifier: merge.record.issue_identifier, repo_key: merge.repo_key, folded: merge.folded} end),
      withdrawn: merges |> Enum.map(fn {_issue_id, merge} -> length(merge.withdrawn) end) |> Enum.sum()
    }
  end

  # The index's repository, else the repository whose record saw the ticket last.
  defp route(entries) do
    case Enum.find(entries, & &1.indexed) do
      %{repo_key: repo_key} -> repo_key
      nil -> entries |> Enum.max_by(&{stamp(&1.record.linear_updated_at), stamp(&1.record.observed_at), stamp(&1.record.updated_at)}) |> Map.fetch!(:repo_key)
    end
  end

  # The record that last changed phase. A release before epic 1 kept no phase time, so with none to
  # tell them apart the route's record speaks: the repository the ticket is on now.
  defp phased(entries, route), do: Enum.max_by(entries, &{stamp(&1.record.phase_at), &1.repo_key == route}).record

  defp observed(records), do: Enum.max_by(records, &{stamp(&1.linear_updated_at), stamp(&1.observed_at)})

  defp observed_fields do
    ~w(issue_identifier title description team project labels priority assignee blockers sub_issues parent url created_at linear_updated_at observed_at observed_from removed_at not_found_at)a
  end

  # Every record's questions, each once: a question several records hold keeps its ended copy, else
  # the newest asked; then two open ones asking the same keep one. Each is tagged with whether the
  # route's record held it.
  defp questions(entries, route) do
    entries
    |> Enum.flat_map(fn entry -> Enum.map(entry.record.questions, &{&1, entry.repo_key == route}) end)
    |> Enum.group_by(fn {question, _on_route} -> question.id end)
    |> Enum.map(fn {_id, copies} ->
      {question, _on_route} = Enum.max_by(copies, fn {question, _on_route} -> {question.state != :open, stamp(question.asked_at)} end)
      {question, Enum.any?(copies, &elem(&1, 1))}
    end)
    |> Enum.sort_by(fn {question, _on_route} -> stamp(question.asked_at) end)
    |> collapse()
  end

  defp collapse(questions) do
    {open, ended} = Enum.split_with(questions, fn {question, _on_route} -> question.state == :open end)

    kept =
      open
      |> Enum.group_by(fn {question, _on_route} -> {question.title, question.question} end)
      |> Enum.map(fn {_text, copies} -> Enum.find(copies, hd(copies), &elem(&1, 1)) end)

    Enum.sort_by(ended ++ kept, fn {question, _on_route} -> stamp(question.asked_at) end)
  end

  # An open question no record of the route held was asked before the ticket moved: withdrawn.
  defp supersede(questions, now) do
    Enum.map_reduce(questions, [], fn
      {%{state: :open} = question, false}, superseded ->
        withdrawn = %{question | state: :withdrawn, withdrawn: %{reason: superseded_reason(), at: now}}
        {withdrawn, superseded ++ [withdrawn]}

      {question, _on_route}, superseded ->
        {question, superseded}
    end)
  end

  defp superseded_reason, do: "The ticket moved to another project after this was asked, so the move it waited on has happened."

  # The payload is always valid (a string id and reason, Symphony): a refusal would abort the merge.
  defp withdrawal(route, issue_id, question, phase, now) do
    payload = %{question_id: question.id, title: question.title, reason: question.withdrawn.reason, by: @symphony, cause: @cause}
    {:ok, event} = TicketEvents.build(route, issue_id, "question.withdrawn", payload, at: now, phase: phase)
    event
  end

  # The store merges while it starts, before anything can write to Linear: the reconciler does it.
  defp follow_withdrawals(record, [], _now), do: record
  defp follow_withdrawals(record, _superseded, now), do: TicketState.mark_projection(record, :pause, "questions withdrawn by the merge of the ticket's records", now)

  # Every record's pause reasons, each once, less the reasons of questions no longer open.
  defp pause(records, route, issue_id, open) do
    pauses = for %{pause: %{} = pause} <- records, do: pause

    reasons =
      for %{reasons: reasons} <- Enum.sort_by(pauses, &stamp(&1.since)),
          reason <- reasons,
          reason.kind != :question or MapSet.member?(open, reason.waits_on[:question_id]),
          do: reason

    case pauses do
      [] ->
        nil

      [first | _rest] ->
        Pauses.normalize(%{subject: {:ticket, route, issue_id}, reasons: reasons, set_by: first.set_by, since: nil})
    end
  end

  defp union(records, field, key), do: records |> Enum.sort_by(&stamp(&1.updated_at)) |> Enum.flat_map(&Map.fetch!(&1, field)) |> Enum.uniq_by(key)

  # Each list newest first, as the record kept it; a record with none adds nothing.
  defp legacy_history(records) do
    histories = Enum.map(records, &TicketState.legacy_history/1)

    %{
      signals: history_union(histories, :signals, :at),
      verdicts: history_union(histories, :verdicts, :recorded_at),
      dispatches: history_union(histories, :dispatches, :at)
    }
  end

  defp history_union(histories, field, at) do
    histories |> Enum.flat_map(&Map.fetch!(&1, field)) |> Enum.uniq() |> Enum.sort_by(&stamp(Map.get(&1, at)), :desc)
  end

  # An event is the same event under any repository by its id; one without an id by what it says.
  defp event_key(%Event{id: id}) when is_binary(id), do: id
  defp event_key(%Event{} = event), do: {event.type, event.at, event.idempotency, event.run_id, event.payload}

  defp stamp(%DateTime{} = at), do: {1, DateTime.to_unix(at, :microsecond)}
  defp stamp(_none), do: {0, 0}
end
