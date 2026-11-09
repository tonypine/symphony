defmodule SymphonyElixir.TicketEvents.Journal do
  @moduledoc """
  The events across every ticket, newest first: the Journal's source
  (`GET /api/v1/events`, `SymphonyElixirWeb.JournalController`).

  `read/1` reads every ticket's events and Symphony's own stream (`RunStore.list_all_ticket_events/1`),
  keeps the ones its filters (`t:opt/0`) let through, and pages them newest first. Each entry is the
  event with the ticket it is on (its repository, identifier and title, from the ticket's record;
  none for Symphony's own stream), its class (`class/1`), whether it is notable
  (`SymphonyElixir.TicketEvents.Notable`) and who did it (`by/1`).

  A page holds `limit` events, and more when its last event shares its `at` with the next ones, so a
  reader that pages with `until:` the last event's `at` (`next_until`) never skips an event.
  """

  alias SymphonyElixir.{RunStore, TicketState}
  alias SymphonyElixir.TicketEvents.{Event, Notable}

  @default_limit 50
  @max_limit 200
  @symphony_stream "symphony"
  @classes %{
    "verdict.recorded" => "verdict",
    "phase.entered" => "move",
    "ticket.moved" => "move",
    "ticket.cancelled" => "move",
    "drift.detected" => "move",
    "drift.reverted" => "move",
    "drift.revert_failed" => "move",
    "question.asked" => "question",
    "question.answered" => "question",
    "question.withdrawn" => "question",
    "question.reopened" => "question",
    "question.not_asked" => "question",
    "decision.requested" => "question",
    "decision.recorded" => "question",
    "decision.withdrawn" => "question",
    "pause.set" => "pause",
    "pause.reason_added" => "pause",
    "pause.reason_cleared" => "pause",
    "pause.cleared" => "pause",
    "hold.set" => "pause",
    "hold.cleared" => "pause",
    "park.backfilled" => "pause",
    "rule.action" => "rule",
    "ticket.filed" => "ticket",
    "situation.changed" => "situation",
    "run.started" => "run",
    "run.started_by_person" => "run",
    "run.ended" => "run",
    "attempt.pushed" => "run",
    "step.started" => "run",
    "step.completed" => "run",
    "finding.recorded" => "finding",
    "finding.resolved" => "finding",
    "finding.confirmed" => "finding",
    "evidence" => "finding",
    "checklist.answered" => "finding",
    "person.action" => "person",
    "note" => "note",
    "note.read" => "note"
  }

  @typedoc """
  `read/1`'s options: `since:` and `until:` (exclusive, on `at`), `repo:` (a repository's key:
  its tickets' events, and Symphony's own), `epic:` (an epic's identifier: the epic's events and
  its sub-tickets'), `classes:` (`class/1`'s names to keep), `notable:` (true keeps the notable
  events only; false, the default here, keeps every event), `limit:` (default #{@default_limit},
  at most #{@max_limit}) and `now:` (the time the rules read, default now).
  """
  @type opt ::
          {:since, DateTime.t() | nil}
          | {:until, DateTime.t() | nil}
          | {:repo, String.t() | nil}
          | {:epic, String.t() | nil}
          | {:classes, [String.t()] | nil}
          | {:notable, boolean()}
          | {:limit, pos_integer() | nil}
          | {:now, DateTime.t()}

  @typedoc "Who did it: Symphony, a named rule, a person (the Director) or a run (with its `run_id` when known)."
  @type by :: %{
          required(:kind) => String.t(),
          required(:name) => String.t() | nil,
          optional(:run_id) => String.t() | nil
        }

  @typedoc """
  One entry: the event, its ticket (`repo_key`, `identifier`, `title`; nil fields for Symphony's
  own stream), its class, whether it is notable and who did it.
  """
  @type entry :: %{
          event: Event.t(),
          ticket: %{repo_key: String.t() | nil, identifier: String.t() | nil, title: String.t() | nil},
          class: String.t(),
          notable: boolean(),
          by: by()
        }

  @doc "Every class `class/1` names, sorted."
  @spec classes() :: [String.t()]
  def classes, do: @classes |> Map.values() |> Enum.uniq() |> Enum.sort()

  @doc "The class of an event's `type`: `verdict`, `move`, `question`, `pause`, `rule`, …; `other` for a type the table doesn't name."
  @spec class(String.t() | nil) :: String.t()
  def class(type), do: Map.get(@classes, type, "other")

  @doc """
  The page of entries `opts` asks for (`t:opt/0`), newest first, and the `until` the next page
  passes (nil when this page is the last). A store error is returned as it is.
  """
  @spec read([opt()]) :: {:ok, %{entries: [entry()], next_until: DateTime.t() | nil}} | {:error, term()}
  def read(opts \\ []) do
    with events when is_list(events) <- RunStore.list_all_ticket_events([]),
         records when is_list(records) <- RunStore.list_all_ticket_states() do
      records = records |> Enum.map(&TicketState.normalize/1) |> Map.new(&{&1.issue_id, &1})
      now = Keyword.get(opts, :now) || DateTime.utc_now()
      streams = events |> Enum.sort_by(&{at_key(&1), &1.seq || 0}) |> Enum.group_by(& &1.issue_id)

      entries =
        events
        |> Enum.filter(&(in_window?(&1, opts) and in_scope?(&1, records, opts) and in_classes?(&1, opts[:classes])))
        |> Enum.map(&entry(&1, records, %{events: Map.get(streams, &1.issue_id, []), now: now}))
        |> Enum.filter(&(opts[:notable] != true or &1.notable))
        |> Enum.sort_by(&{at_key(&1.event), &1.event.seq || 0, &1.event.id}, :desc)

      {:ok, page(entries, limit(opts[:limit]))}
    end
  end

  @doc """
  Who did `event`: the rule a `rule.action` names; the person or the run its actor is; the rule
  or person a pause's or a question's payload names as its setter (`set_by`, `by`, `asked_by`); a
  run the machine recorded the event for (`run_id`); else Symphony.
  """
  @spec by(Event.t()) :: by()
  def by(%Event{type: "rule.action", payload: payload}), do: %{kind: "rule", name: string(Map.get(payload, :rule))}
  def by(%Event{actor: %{kind: :person, name: name}}), do: %{kind: "person", name: name}
  def by(%Event{actor: %{kind: :agent} = actor}), do: %{kind: "run", name: string(Map.get(actor, :run_kind)), run_id: Map.get(actor, :run_id)}

  def by(%Event{payload: payload, run_id: run_id}) do
    case Enum.find_value([:set_by, :by, :asked_by], &setter(Map.get(payload, &1))) do
      nil when is_binary(run_id) -> %{kind: "run", name: nil, run_id: run_id}
      nil -> %{kind: "symphony", name: "Symphony"}
      by -> by
    end
  end

  # A setter a pause or a question names: a rule or a person by name, a run; Symphony's own is no
  # answer, so the run the event belongs to may be.
  defp setter(%{kind: kind} = setter) when kind in [:rule, :person, :run, "rule", "person", "run"],
    do: %{kind: to_string(kind), name: string(Map.get(setter, :name))}

  defp setter(_setter), do: nil

  defp entry(event, records, context) do
    record = Map.get(records, event.issue_id)

    %{
      event: event,
      ticket: ticket(event, record),
      class: class(event.type),
      notable: Notable.notable?(event, context),
      by: by(event)
    }
  end

  defp ticket(%Event{issue_id: @symphony_stream}, _record), do: %{repo_key: nil, identifier: nil, title: nil}
  defp ticket(event, nil), do: %{repo_key: event.repo_key, identifier: nil, title: nil}
  defp ticket(event, record), do: %{repo_key: event.repo_key || record.repo_key, identifier: record.issue_identifier, title: record.title}

  # A stored event always has its `at` (`SymphonyElixir.TicketEvents.record/5`).
  defp in_window?(%Event{at: at}, opts) do
    since = opts[:since]
    until = opts[:until]
    (is_nil(since) or DateTime.compare(at, since) == :gt) and (is_nil(until) or DateTime.compare(at, until) == :lt)
  end

  # Symphony's own stream is every repository's, and no epic's.
  defp in_scope?(%Event{issue_id: @symphony_stream}, _records, opts), do: is_nil(opts[:epic])

  defp in_scope?(event, records, opts) do
    record = Map.get(records, event.issue_id)
    (is_nil(opts[:repo]) or event.repo_key == opts[:repo]) and in_epic?(record, opts[:epic])
  end

  defp in_epic?(_record, nil), do: true
  defp in_epic?(nil, _epic), do: false
  defp in_epic?(record, epic), do: record.issue_identifier == epic or match?(%{identifier: ^epic}, record.parent)

  defp in_classes?(_event, nil), do: true
  defp in_classes?(event, classes), do: class(event.type) in classes

  defp at_key(%Event{at: at}), do: DateTime.to_unix(at, :microsecond)

  defp limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp limit(_limit), do: @default_limit

  defp page(entries, limit) do
    case Enum.split(entries, limit) do
      {page, []} ->
        %{entries: page, next_until: nil}

      {page, rest} ->
        last_at = List.last(page).event.at
        {same, rest} = Enum.split_while(rest, &(DateTime.compare(&1.event.at, last_at) == :eq))
        %{entries: page ++ same, next_until: if(rest == [], do: nil, else: last_at)}
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp string(_value), do: nil
end
