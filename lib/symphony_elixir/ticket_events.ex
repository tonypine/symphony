defmodule SymphonyElixir.TicketEvents do
  @moduledoc """
  One durable, typed, append-only event stream per ticket. `record/5` writes an event, `query/3`
  reads them.

  Each event (`SymphonyElixir.TicketEvents.Event`) has a type from a closed vocabulary
  (`SymphonyElixir.TicketEvents.Types`), whose schema its payload is validated against and whose
  writers its actor must be among. The stream is kept by `SymphonyElixir.RunStore`, which assigns
  each event the ticket's next `seq` and makes a second write with the same idempotency key a no-op.

  A run is a sequence of events, not one event. A finding has a lifecycle (`findings/1`):
  `finding.recorded` opens it; `finding.resolved` by an agent, with the head that fixes it, resolves
  it, awaiting QA; the next QA verdict confirms it (a `pass`: `finding.confirmed` naming the
  resolution) or reopens it (a `fail`: a `finding.recorded` whose `supersedes` names the resolution).
  `record/5` refuses a resolution of a finding the ticket does not hold, or of one already resolved.
  A decision a person must make is `decision.requested`, then
  `decision.recorded` when a person answers it or `decision.withdrawn` when it ends unanswered;
  both name the request in their payload's `request`. A question asked through the Question service
  (`SymphonyElixir.Questions`) is `question.asked`, ended by `question.answered` or
  `question.withdrawn` naming its `question_id`, or by a `decision.recorded` naming the event.

  A question asked on Symphony itself or on a repository records the same `question.*` events on
  that subject's own stream (`build_subject/4`, `query_subject/2`), which no ticket's record holds.

  The machinery writes events next to the snapshot fields of `SymphonyElixir.TicketState`
  (`SymphonyElixir.TicketSignals`, `SymphonyElixir.Pauses`, `SymphonyElixir.Questions`, and the
  orchestrator's `run.started` and `run.ended` next to its dispatches) and next to the audit records
  of the Director's stop, force and Inbox moves (`person.action`), and nothing reads them yet: the
  snapshot fields (`signals`, `verdicts`, `decisions`, `dispatches`) stay the source of
  truth until readers move over.
  """

  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketEvents.{Event, Summary, Types}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @default_limit 50
  @max_limit 200
  @string_options [:phase, :run_id, :head_sha, :parent, :supersedes, :idempotency]

  @typedoc """
  `record/5`'s options: `actor:` (`t:Event.actor_input/0`, default the machine), `phase:` (default
  the phase the ticket's record holds), `run_id:` (default an agent actor's run), `head_sha:`,
  `parent:`, `supersedes:`, `idempotency:` (default the key the type derives, if any), `artifacts:`
  and `at:` (default now).
  """
  @type record_opt ::
          {:actor, Event.actor_input()}
          | {:phase, String.t() | nil}
          | {:run_id, String.t() | nil}
          | {:head_sha, String.t() | nil}
          | {:parent, String.t() | nil}
          | {:supersedes, String.t() | nil}
          | {:idempotency, String.t() | nil}
          | {:artifacts, [String.t()]}
          | {:at, DateTime.t()}

  # The events that ask a person something: a decision request, and a Question's.
  @request_types ["decision.requested", "question.asked"]

  @typedoc """
  Where a finding stands (`findings/1`): `:open` (recorded, no resolution yet), `:resolved` (an
  agent resolved it and no QA verdict has judged it yet), `:reopened` (an event superseded its
  resolution), `:confirmed` (a QA pass confirmed its resolution).
  """
  @type finding_state :: :open | :resolved | :reopened | :confirmed

  @typedoc """
  A finding of `findings/1`: its `finding.recorded` event, its state, its standing resolution (nil
  when open or reopened), the event that confirmed it, and the newest event that reopened it with
  the resolution that event superseded.
  """
  @type finding :: %{
          finding: Event.t(),
          state: finding_state(),
          resolution: Event.t() | nil,
          confirmation: Event.t() | nil,
          reopened_by: Event.t() | nil,
          superseded: Event.t() | nil
        }

  @typedoc "Why `record/5` refuses a `finding.resolved`: see `check_resolution/3`."
  @type resolution_error ::
          {:unknown_finding, String.t()}
          | {:finding_already_resolved, String.t(), String.t()}
          | {:no_head, String.t()}

  @typedoc """
  `query/3`'s options: `types:`, `since:` (exclusive, on `at`), `run_id:`, `open_findings:`,
  `open_decisions:` and `limit:` (default #{@default_limit}, at most #{@max_limit}).
  """
  @type query_opt ::
          {:types, [String.t()] | String.t()}
          | {:since, DateTime.t()}
          | {:run_id, String.t()}
          | {:open_findings, boolean()}
          | {:open_decisions, boolean()}
          | {:limit, pos_integer()}

  @doc """
  Records an event of `type` with `payload` on `repo_key`'s ticket `issue_id` (see
  `t:record_opt/0` for `opts`). An event with the idempotency key of one the ticket already holds
  returns that event and writes nothing. The event carries the summary
  `SymphonyElixir.TicketEvents.Summary` renders from its type and payload.

  Once the event is written, a notice of it goes to the subscribers of
  `SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_events/0` (the live channel,
  `GET /api/v1/stream`): its `repo_key`, `issue_id`, the ticket's `issue_identifier` when its record
  knows it, `event_id`, `type` and `at`. The notice is best-effort and never fails the write; a
  refused write or an idempotent no-op sends none.

  A `finding.resolved` is refused, with the reason (`check_resolution/3`), when its `finding_id`
  names no finding of the ticket or one already resolved, or when it carries no head: its payload's
  `head`, else the `head_sha:` it is recorded on, which then fills the payload's `head`.
  """
  @spec record(String.t(), String.t(), String.t(), map(), [record_opt()]) ::
          {:ok, Event.t()} | {:error, Types.error() | resolution_error() | term()}
  def record(repo_key, issue_id, type, payload, opts \\ []) do
    with {:ok, event} <- build(repo_key, issue_id, type, payload, opts),
         :ok <- resolvable(event),
         {:ok, stored} <- RunStore.append_ticket_event(event) do
      # A no-op returns the event the ticket already held, which has another id than the one built.
      if stored.id == event.id, do: notify(stored)
      {:ok, stored}
    end
  end

  @doc """
  The event `record/5` would write, validated and with its summary, without writing it: for a
  writer that appends a ticket's events in one transaction (`RunStore.append_ticket_events/1`).
  """
  @spec build(String.t() | nil, String.t(), String.t(), map(), [record_opt()]) :: {:ok, Event.t()} | {:error, Types.error() | term()}
  def build(repo_key, issue_id, type, payload, opts) do
    with {:ok, actor} <- actor(opts),
         {:ok, payload} <- Types.validate(type, payload, actor.kind, Map.get(actor, :run_kind)),
         {:ok, options} <- options(opts) do
      at = Map.get(options, :at) || DateTime.utc_now()

      %Event{
        id: Event.ulid(at),
        repo_key: repo_key,
        issue_id: issue_id,
        at: at,
        type: type,
        phase: options.phase,
        actor: actor,
        run_id: options.run_id || Map.get(actor, :run_id),
        head_sha: options.head_sha,
        parent: options.parent,
        supersedes: options.supersedes,
        idempotency: Types.idempotency_key(type, payload, options.idempotency),
        payload: payload,
        artifacts: options.artifacts
      }
      |> resolution_head()
      |> then(&{:ok, %{&1 | summary: Summary.render(&1)}})
    end
  end

  # A resolution carries the head that fixes the finding: the one it names, else the one it is
  # recorded on.
  defp resolution_head(%Event{type: "finding.resolved", payload: payload, head_sha: head} = event) when is_binary(head) do
    if is_binary(Map.get(payload, :head)), do: event, else: %{event | payload: Map.put(payload, :head, head)}
  end

  defp resolution_head(event), do: event

  # A write with the idempotency key of an event the ticket holds is the no-op `record/5` promises,
  # never a refusal.
  defp resolvable(%Event{type: "finding.resolved", issue_id: issue_id, payload: payload, idempotency: key}) do
    with events when is_list(events) <- RunStore.list_ticket_events(issue_id, []) do
      if is_binary(key) and Enum.any?(events, &(&1.idempotency == key)),
        do: :ok,
        else: check_resolution(events, Map.get(payload, :finding_id), Map.get(payload, :head))
    end
  end

  defp resolvable(_event), do: :ok

  @doc """
  Whether a `finding.resolved` naming `finding_id` with `head` may be recorded on a ticket holding
  `events` (oldest first): `:ok` for a finding that is open or reopened (`findings/1`), else
  `{:unknown_finding, id}` (no `finding.recorded` of the ticket has that id),
  `{:finding_already_resolved, id, resolution_id}` (resolved, awaiting QA or confirmed) or
  `{:no_head, id}` (no head says what fixes it).
  """
  @spec check_resolution([Event.t()], String.t() | nil, String.t() | nil) :: :ok | {:error, resolution_error()}
  def check_resolution(events, finding_id, head) do
    case Enum.find(findings(events), &(&1.finding.id == finding_id)) do
      nil -> {:error, {:unknown_finding, finding_id}}
      %{state: state, resolution: resolution} when state in [:resolved, :confirmed] -> {:error, {:finding_already_resolved, finding_id, resolution.id}}
      _open when not is_binary(head) or head == "" -> {:error, {:no_head, finding_id}}
      _open -> :ok
    end
  end

  @doc """
  Every finding of a ticket holding `events` (oldest first), in the order they were recorded, with
  where it stands (`t:finding/0`). The events are read in order:

    * a `finding.recorded` opens a finding, unless it supersedes a finding's standing resolution:
      then it is that finding seen again, and reopens it;
    * a `finding.resolved` naming an open or reopened finding resolves it;
    * a `finding.confirmed` naming a finding's standing resolution confirms it;
    * any other event superseding a finding's standing resolution reopens it.
  """
  @spec findings([Event.t()]) :: [finding()]
  def findings(events) do
    {order, by_id} = Enum.reduce(events, {[], %{}}, &finding_step/2)
    order |> Enum.reverse() |> Enum.map(&Map.fetch!(by_id, &1))
  end

  defp finding_step(%Event{} = event, {order, by_id} = acc) do
    case {event.type, reopens(by_id, event)} do
      {_type, {:ok, id}} ->
        {order, Map.update!(by_id, id, &%{&1 | state: :reopened, reopened_by: event, superseded: &1.resolution, resolution: nil, confirmation: nil})}

      {"finding.recorded", :none} ->
        entry = %{finding: event, state: :open, resolution: nil, confirmation: nil, reopened_by: nil, superseded: nil}
        {[event.id | order], Map.put(by_id, event.id, entry)}

      {"finding.resolved", :none} ->
        update_finding(acc, Map.get(event.payload, :finding_id), &(&1.state in [:open, :reopened]), &%{&1 | state: :resolved, resolution: event})

      {"finding.confirmed", :none} ->
        resolution = Map.get(event.payload, :resolution)
        update_finding(acc, Map.get(event.payload, :finding_id), &(&1.state == :resolved and &1.resolution.id == resolution), &%{&1 | state: :confirmed, confirmation: event})

      _other ->
        acc
    end
  end

  # The finding whose standing resolution `event` supersedes.
  defp reopens(_by_id, %Event{supersedes: nil}), do: :none

  defp reopens(by_id, %Event{supersedes: superseded}) do
    case Enum.find(by_id, fn {_id, entry} -> entry.resolution && entry.resolution.id == superseded end) do
      {id, _entry} -> {:ok, id}
      nil -> :none
    end
  end

  defp update_finding({order, by_id} = acc, id, allowed?, update) do
    case Map.fetch(by_id, id) do
      {:ok, entry} -> if allowed?.(entry), do: {order, Map.put(by_id, id, update.(entry))}, else: acc
      :error -> acc
    end
  end

  @doc """
  The events of the ticket `issue_id`, oldest first by `at`, then `seq` (see
  `t:query_opt/0` for `opts`).

  `open_findings: true` keeps the `finding.recorded` event of every finding QA has not confirmed
  fixed (`findings/1`): open, resolved awaiting QA, or reopened; `open_decisions: true` keeps the `decision.requested` and `question.asked`
  events no `decision.recorded` or `decision.withdrawn` names in `request`, and, for a question, no
  `question.answered` or `question.withdrawn` names in `question_id` (both together keep either).

  A page holds `limit` events, and more when its last event shares its `at` with the next ones: a
  page never ends inside a group of events that share one `at`, so a reader that pages with
  `since:` the last event's `at` never skips an event.
  """
  @spec query(String.t(), [query_opt()]) :: [Event.t()] | {:error, term()}
  def query(issue_id, opts \\ []), do: issue_id |> RunStore.list_ticket_events([]) |> read(opts)

  @doc """
  The event stream of a subject that is not a ticket: Symphony itself (`:symphony`) or a repository
  (`{:repository, repo_key}`), whose questions (`SymphonyElixir.Questions`) record the same
  `question.*` events a ticket's do. Its events carry `stream/1`'s `repo_key` and `issue_id`, and
  `SymphonyElixir.RunStore` keeps them apart from every ticket's.
  """
  @spec build_subject(SymphonyElixir.Pauses.subject(), String.t(), map(), [record_opt()]) :: {:ok, Event.t()} | {:error, Types.error() | term()}
  def build_subject(subject, type, payload, opts) do
    {repo_key, issue_id} = stream(subject)
    build(repo_key, issue_id, type, payload, opts)
  end

  @doc """
  The `repo_key` and `issue_id` the events of a subject's own stream carry: none and `symphony` for
  Symphony, the repository's key and `repository` for a repository. No Linear issue has either id.
  """
  @spec stream(:symphony | {:repository, String.t()}) :: {String.t() | nil, String.t()}
  def stream(:symphony), do: {nil, "symphony"}
  def stream({:repository, repo_key}) when is_binary(repo_key), do: {repo_key, "repository"}

  @doc """
  The events of `subject`'s own stream (`build_subject/4`), as `query/3` reads a ticket's, with the
  same options.
  """
  @spec query_subject(:symphony | {:repository, String.t()}, [query_opt()]) :: [Event.t()] | {:error, term()}
  def query_subject(subject, opts \\ []), do: subject |> RunStore.list_subject_events([]) |> read(opts)

  defp read(events, opts) when is_list(events), do: events |> open(opts) |> Enum.filter(&matches?(&1, opts)) |> page(limit(opts))
  defp read({:error, reason}, _opts), do: {:error, reason}

  @doc """
  Sends the live channel's notice of `event`, as `record/5` does once it writes one: for a writer
  that appends a ticket's events in its own transaction, after it commits.
  """
  @spec notify(Event.t()) :: :ok
  def notify(%Event{} = event) do
    ObservabilityPubSub.broadcast_ticket_event(%{
      repo_key: event.repo_key,
      issue_id: event.issue_id,
      issue_identifier: issue_identifier(event.issue_id),
      event_id: event.id,
      type: event.type,
      at: event.at
    })
  end

  defp issue_identifier(issue_id) do
    case RunStore.get_ticket_state(issue_id) do
      %{issue_identifier: identifier} when is_binary(identifier) -> identifier
      _none -> nil
    end
  end

  defp actor(opts) do
    input = Keyword.get(opts, :actor, :machine)

    case Event.normalize_actor(input) do
      nil -> {:error, {:invalid_actor, input}}
      actor -> {:ok, actor}
    end
  end

  defp options(opts) do
    with {:ok, options} <- string_options(opts),
         {:ok, artifacts} <- artifacts(Keyword.get(opts, :artifacts, [])),
         {:ok, at} <- at(Keyword.get(opts, :at)) do
      {:ok, Map.merge(options, %{artifacts: artifacts, at: at})}
    end
  end

  defp string_options(opts) do
    Enum.reduce_while(@string_options, {:ok, %{}}, fn key, {:ok, options} ->
      case Keyword.get(opts, key) do
        nil -> {:cont, {:ok, Map.put(options, key, nil)}}
        value when is_binary(value) -> {:cont, {:ok, Map.put(options, key, blank_to_nil(value))}}
        _value -> {:halt, {:error, {:invalid_option, key}}}
      end
    end)
  end

  defp artifacts(artifacts) when is_list(artifacts) do
    if Enum.all?(artifacts, &(is_binary(&1) and &1 != "")), do: {:ok, artifacts}, else: {:error, {:invalid_option, :artifacts}}
  end

  defp artifacts(_artifacts), do: {:error, {:invalid_option, :artifacts}}

  defp at(nil), do: {:ok, nil}
  defp at(%DateTime{} = at), do: {:ok, at}
  defp at(_at), do: {:error, {:invalid_option, :at}}

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp open(events, opts) do
    findings? = Keyword.get(opts, :open_findings) == true
    decisions? = Keyword.get(opts, :open_decisions) == true

    if findings? or decisions? do
      closed = closed_ids(events)
      live = if findings?, do: live_findings(events), else: MapSet.new()

      Enum.filter(events, fn event ->
        (findings? and MapSet.member?(live, event.id)) or
          (decisions? and event.type in @request_types and not MapSet.member?(closed, event.id) and not answered_question?(closed, event))
      end)
    else
      events
    end
  end

  # The ids of the findings QA has not confirmed fixed.
  defp live_findings(events), do: for(%{state: state, finding: finding} <- findings(events), state != :confirmed, into: MapSet.new(), do: finding.id)

  # The ids of the decision requests an answer or a withdrawal names, in the order they happened: a
  # question the Director reopened since its answer is open again.
  defp closed_ids(events) do
    Enum.reduce(events, MapSet.new(), fn
      %Event{type: type, payload: payload}, closed when type in ["decision.recorded", "decision.withdrawn"] ->
        MapSet.put(closed, Map.get(payload, :request))

      %Event{type: type, payload: payload}, closed when type in ["question.answered", "question.withdrawn"] ->
        MapSet.put(closed, Map.get(payload, :question_id))

      %Event{type: "question.reopened", payload: payload}, closed ->
        MapSet.delete(closed, Map.get(payload, :question_id))

      _event, closed ->
        closed
    end)
  end

  # Whether a `question.asked` event's question is ended by an answer or a withdrawal naming it.
  defp answered_question?(closed, %Event{type: "question.asked", payload: payload}) do
    id = Map.get(payload, :question_id)
    is_binary(id) and MapSet.member?(closed, id)
  end

  defp answered_question?(_closed, _event), do: false

  defp matches?(event, opts) do
    types = Keyword.get(opts, :types)
    run_id = Keyword.get(opts, :run_id)
    since = Keyword.get(opts, :since)

    (is_nil(types) or event.type in List.wrap(types)) and
      (is_nil(run_id) or event.run_id == run_id) and
      (is_nil(since) or DateTime.compare(event.at, since) == :gt)
  end

  defp limit(opts) do
    case Keyword.get(opts, :limit, @default_limit) do
      limit when is_integer(limit) -> limit |> max(1) |> min(@max_limit)
      _limit -> @default_limit
    end
  end

  defp page(events, limit) do
    case Enum.split(events, limit) do
      {[], []} ->
        []

      {page, rest} ->
        %Event{at: last_at} = List.last(page)
        page ++ Enum.take_while(rest, &(DateTime.compare(&1.at, last_at) == :eq))
    end
  end
end
