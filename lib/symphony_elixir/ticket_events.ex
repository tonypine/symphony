defmodule SymphonyElixir.TicketEvents do
  @moduledoc """
  One durable, typed, append-only event stream per ticket. `record/5` writes an event, `query/3`
  reads them.

  Each event (`SymphonyElixir.TicketEvents.Event`) has a type from a closed vocabulary
  (`SymphonyElixir.TicketEvents.Types`), whose schema its payload is validated against and whose
  writers its actor must be among. The stream is kept by `SymphonyElixir.RunStore`, which assigns
  each event the ticket's next `seq` and makes a second write with the same idempotency key a no-op.

  A run is a sequence of events, not one event. A finding has a lifecycle: `finding.recorded`, then
  `finding.resolved` by an agent, then confirmed or reopened by the next QA verdict, whose event
  `supersedes` the resolution. A decision a person must make is `decision.requested`, then
  `decision.recorded` when a person answers it or `decision.withdrawn` when it ends unanswered;
  both name the request in their payload's `request`.

  Nothing writes events yet and nothing reads them: the snapshot fields of
  `SymphonyElixir.TicketState` (`signals`, `verdicts`, `dispatches`) stay the source of truth until
  readers move over.
  """

  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketEvents.{Event, Types}

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
  returns that event and writes nothing.
  """
  @spec record(String.t(), String.t(), String.t(), map(), [record_opt()]) :: {:ok, Event.t()} | {:error, Types.error() | term()}
  def record(repo_key, issue_id, type, payload, opts \\ []) do
    with {:ok, actor} <- actor(opts),
         {:ok, payload} <- Types.validate(type, payload, actor.kind, Map.get(actor, :run_kind)),
         {:ok, options} <- options(opts) do
      at = Map.get(options, :at) || DateTime.utc_now()

      RunStore.append_ticket_event(%Event{
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
      })
    end
  end

  @doc """
  The events of `repo_key`'s ticket `issue_id`, oldest first by `at`, then `seq` (see
  `t:query_opt/0` for `opts`).

  `open_findings: true` keeps the `finding.recorded` events no unsuperseded `finding.resolved`
  names in `finding_id`; `open_decisions: true` keeps the `decision.requested` events no
  `decision.recorded` or `decision.withdrawn` names in `request` (both together keep either).

  A page holds `limit` events, and more when its last event shares its `at` with the next ones: a
  page never ends inside a group of events that share one `at`, so a reader that pages with
  `since:` the last event's `at` never skips an event.
  """
  @spec query(String.t(), String.t(), [query_opt()]) :: [Event.t()] | {:error, term()}
  def query(repo_key, issue_id, opts \\ []) do
    case RunStore.list_ticket_events(repo_key, issue_id, []) do
      events when is_list(events) ->
        events
        |> open(opts)
        |> Enum.filter(&matches?(&1, opts))
        |> page(limit(opts))

      {:error, reason} ->
        {:error, reason}
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

      Enum.filter(events, fn event ->
        ((findings? and event.type == "finding.recorded") or (decisions? and event.type == "decision.requested")) and
          not MapSet.member?(closed, event.id)
      end)
    else
      events
    end
  end

  # The ids of the findings an unsuperseded resolution names and of the decision requests an answer
  # or a withdrawal names. Event ids are unique, so one set holds both.
  defp closed_ids(events) do
    superseded = events |> Enum.map(& &1.supersedes) |> MapSet.new()

    events
    |> Enum.flat_map(fn
      %Event{type: "finding.resolved", id: id, payload: payload} -> if MapSet.member?(superseded, id), do: [], else: [Map.get(payload, :finding_id)]
      %Event{type: type, payload: payload} when type in ["decision.recorded", "decision.withdrawn"] -> [Map.get(payload, :request)]
      _event -> []
    end)
    |> MapSet.new()
  end

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
