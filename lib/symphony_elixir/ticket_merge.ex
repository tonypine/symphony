defmodule SymphonyElixir.TicketMerge do
  @moduledoc """
  Merges, once, the records a ticket was left with under more than one repository into its one
  by-ticket record (TP-1338).

  A ticket's record was keyed by the pair (repository, ticket), and a ticket that moved to another
  Linear project was routed to another repository, where a second record opened: the old one kept
  its questions, pauses and events, stranded. The by-ticket index (`SymphonyElixir.RunStore`,
  `ticket_index_v1`) names one record per ticket from then on, but a ticket already left with two
  is not indexed: which record is its own is this merge's call.

  `run/1` lists every ticket the pair key holds and merges each one held under more than one
  repository (`merge/3`, written by `SymphonyElixir.RunStore.merge_ticket_records/2` in one
  transaction):

    * the repository is the ticket's current route: the one the index names, else the one whose
      record observed the ticket last (observations are routed by project);
    * the events of every record, oldest first, each once (by id), renumbered from 1 under that
      repository, with their artifacts;
    * the questions of every record: a question two records hold is kept once (its ended copy,
      else the newest), and two open questions with the same title and text collapse to one (the
      route's, else the first asked); the pause reasons of every record, each once; the decisions
      and the path grants of every record, each once;
    * the newest phase (by when it was written), the newest PR facts (by when they were read), the
      last observation, and the newest record's verdicts, CI states, signals and run history;
    * an open question only a record of another repository held was asked before the ticket moved
      to its route's project, which answered it: it is withdrawn with the cause
      `superseded_by_move` and its `question.withdrawn` event is recorded; its pause reason goes.

  No record row is deleted: the records left under other repositories stay where they are, and the
  store lists and reads the ticket through the index, so they are never seen again. A merge run
  again finds the same events, questions and reasons and writes the same record.

  The run is guarded by the store marker `records_merged_v1`: a start with it set does nothing. Its
  report (`t:report/0`, `records.merged`) is kept beside the marker and read by the state payload
  (`report/0`). A failed read or write leaves the marker unset, so the next start runs it again;
  the failure is kept in memory for the payload.
  """

  require Logger

  alias SymphonyElixir.{Pauses, RunStore, TicketEvents, TicketState}
  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.TicketEvents.Event
  alias SymphonyElixirWeb.ObservabilityPubSub

  @marker "records_merged_v1"
  @report_name "records.merged"
  @failure_key {__MODULE__, :failure}
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
  What a run did (`records.merged`): when it ran, how many tickets it checked, how many it merged,
  each merge, and the questions it withdrew as `superseded_by_move`.
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

  @typedoc """
  `run/1`'s and `start/1`'s options: `now:` (default the current time), `store:` (default
  `SymphonyElixir.RunStore`), `project:` (what makes Linear follow a withdrawal, default
  `SymphonyElixir.Pauses.Projector.project_now/1`), and for `start/1` `enabled:` and `supervisor:`.
  """
  @type opt ::
          {:now, DateTime.t()}
          | {:store, module()}
          | {:project, (Pauses.subject() -> term())}
          | {:enabled, boolean()}
          | {:supervisor, GenServer.name()}

  @doc "The store marker that says the merge ran."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Starts `run/1` in a task of the boot pass, so startup never waits for it; `:disabled` when
  `enabled:` (default the `:ticket_merge` application setting, true) is false.
  """
  @spec start([opt()]) :: DynamicSupervisor.on_start_child() | :disabled | {:error, term()}
  def start(opts \\ []) do
    if Keyword.get(opts, :enabled, Application.get_env(:symphony_elixir, :ticket_merge, true)) do
      Task.Supervisor.start_child(Keyword.get(opts, :supervisor, SymphonyElixir.TaskSupervisor), fn -> run(opts) end)
    else
      :disabled
    end
  catch
    :exit, reason ->
      Logger.warning("Failed to start the merge of duplicate ticket records: #{inspect(reason)}")
      {:error, reason}
  end

  @doc """
  Merges every ticket held under more than one repository, once (see the module doc), and returns
  the report, which the store keeps with the marker. With the marker set, nothing is read or
  written and `{:ok, :already_merged}` is returned. A failed read or write is returned, logged and
  kept for `report/0`, with the marker left unset.
  """
  @spec run([opt()]) :: {:ok, report() | :already_merged} | {:error, term()}
  def run(opts) do
    store = Keyword.get(opts, :store, RunStore)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    result =
      case store.get_marker(@marker) do
        %DateTime{} -> {:ok, :already_merged}
        nil -> merge_all(store, now, opts)
        {:error, _reason} = error -> error
      end

    log(result, now)
  end

  @doc """
  The last run's report as the store keeps it, or the failure of this start's run
  (`%{name, at, error}`) while the marker is unset; nil before any run.
  """
  @spec report(module()) :: report() | %{name: String.t(), at: DateTime.t(), error: String.t()} | nil
  def report(store \\ RunStore) do
    case store.get_report(@marker) do
      %{} = report -> report
      _none -> :persistent_term.get(@failure_key, nil)
    end
  end

  @doc "Forgets this start's failure, so `report/1` reads only the store."
  @spec reset() :: :ok
  def reset do
    _ = :persistent_term.erase(@failure_key)
    :ok
  end

  defp merge_all(store, now, opts) do
    with %{} = tickets <- store.ticket_record_repositories(),
         {:ok, merges} <- merge_duplicates(store, tickets, now) do
      report = %{
        name: @report_name,
        at: now,
        checked: map_size(tickets),
        merged: length(merges),
        merges: Enum.map(merges, &Map.take(&1, [:issue_id, :issue_identifier, :repo_key, :folded])),
        withdrawn: merges |> Enum.map(&length(&1.withdrawn)) |> Enum.sum()
      }

      with :ok <- store.put_marker_with_report(@marker, now, report) do
        Enum.each(merges, &announce(&1, opts))
        {:ok, report}
      end
    end
  end

  defp merge_duplicates(store, tickets, now) do
    tickets
    |> Enum.filter(fn {_issue_id, repo_keys} -> length(repo_keys) > 1 end)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {issue_id, _repo_keys}, {:ok, merges} ->
      case store.merge_ticket_records(issue_id, &merge(issue_id, &1, now)) do
        {:ok, :skip} -> {:cont, {:ok, merges}}
        {:ok, merge} -> {:cont, {:ok, [Map.put(merge, :issue_id, issue_id) | merges]}}
        {:error, reason} -> {:halt, {:error, {:merge_failed, issue_id, reason}}}
      end
    end)
    |> then(fn
      {:ok, merges} -> {:ok, merges |> Enum.reverse() |> Enum.map(&Map.put(&1, :issue_identifier, &1.record.issue_identifier))}
      error -> error
    end)
  end

  # What a withdrawal changes outside the store: the events are announced, the ticket's pause is
  # read again, and Linear follows (labels, the request's `## Action withdrawn` reply).
  defp announce(%{withdrawn: []}, _opts), do: :ok

  defp announce(%{repo_key: repo_key, issue_id: issue_id, events: events, withdrawn: withdrawn}, opts) do
    ids = MapSet.new(withdrawn, & &1.id)
    events |> Enum.filter(&(&1.type == "question.withdrawn" and MapSet.member?(ids, &1.payload[:question_id]))) |> Enum.each(&TicketEvents.notify/1)
    ObservabilityPubSub.broadcast_ticket_record_changed(repo_key, issue_id, [:pause])
    Keyword.get(opts, :project, &Projector.project_now/1).({:ticket, repo_key, issue_id})
  end

  @doc """
  The one record of ticket `issue_id` from its `entries` (one per repository, as
  `SymphonyElixir.RunStore.merge_ticket_records/2` gives them), at `now`, as the module doc says:
  `{:ok, merge}`, or `:skip` for fewer than two. Pure.
  """
  @spec merge(String.t(), [entry()], DateTime.t()) :: {:ok, merge()} | :skip
  def merge(_issue_id, entries, _now) when length(entries) < 2, do: :skip

  def merge(issue_id, entries, %DateTime{} = now) do
    route = route(entries)
    records = Enum.map(entries, & &1.record)
    newest = Enum.max_by(records, &stamp(&1.updated_at))
    {questions, superseded} = entries |> questions(route) |> supersede(now)
    open = for %{state: :open, id: id} <- questions, into: MapSet.new(), do: id

    record =
      newest
      |> Map.merge(Map.take(Enum.max_by(records, &stamp(&1.phase_at)), [:phase, :phase_at, :phase_owner]))
      |> Map.put(:pr_watch, Enum.max_by(records, &stamp(&1.pr_watch && &1.pr_watch.read_at)).pr_watch)
      |> Map.merge(Map.take(observed(records), observed_fields()))
      |> Map.merge(%{
        repo_key: route,
        issue_id: issue_id,
        questions: questions,
        pause: pause(records, route, issue_id, open),
        decisions: union(records, :decisions, & &1.key),
        path_unlocks: union(records, :path_unlocks, & &1.id),
        pending_projection: union(records, :pending_projection, & &1)
      })

    events =
      entries
      |> Enum.flat_map(& &1.events)
      |> Enum.uniq_by(&event_key/1)
      |> Enum.sort_by(&{stamp(&1.at), &1.seq || 0})

    {:ok,
     %{
       repo_key: route,
       record: record,
       events: events ++ Enum.map(superseded, &withdrawal(route, issue_id, &1, record.phase, now)),
       withdrawn: superseded,
       folded: entries |> Enum.map(& &1.repo_key) |> List.delete(route)
     }}
  end

  # The index's repository, else the repository whose record saw the ticket last.
  defp route(entries) do
    case Enum.find(entries, & &1.indexed) do
      %{repo_key: repo_key} -> repo_key
      nil -> entries |> Enum.max_by(&{stamp(&1.record.linear_updated_at), stamp(&1.record.observed_at), stamp(&1.record.updated_at)}) |> Map.fetch!(:repo_key)
    end
  end

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

  # An event is the same event under any repository by its id; one without an id by what it says.
  defp event_key(%Event{id: id}) when is_binary(id), do: id
  defp event_key(%Event{} = event), do: {event.type, event.at, event.idempotency, event.run_id, event.payload}

  defp stamp(%DateTime{} = at), do: {1, DateTime.to_unix(at, :microsecond)}
  defp stamp(_none), do: {0, 0}

  defp log({:ok, :already_merged} = result, _now), do: result

  defp log({:ok, report} = result, _now) do
    reset()

    folded = Enum.map_join(report.merges, ", ", &"#{&1.issue_identifier || &1.issue_id} (#{Enum.join(&1.folded, ", ")} into #{&1.repo_key})")

    Logger.info(
      "Merged duplicate ticket records: checked #{report.checked} ticket(s), merged #{report.merged}, withdrew #{report.withdrawn} question(s)" <>
        if(folded == "", do: "", else: ": #{folded}")
    )

    result
  end

  defp log({:error, reason} = error, now) do
    :persistent_term.put(@failure_key, %{name: @report_name, at: now, error: inspect(reason)})
    Logger.warning("Failed to merge duplicate ticket records; the next start retries: #{inspect(reason)}")
    error
  end
end
