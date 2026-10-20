defmodule SymphonyElixir.TicketEvents.Event do
  @moduledoc """
  One event of a ticket's append-only event stream (`SymphonyElixir.TicketEvents`).

  `id` is a ULID, `seq` the ticket's own monotonic sequence number (assigned by
  `SymphonyElixir.RunStore.append_ticket_event/1`), `type` one of the catalog's types
  (`SymphonyElixir.TicketEvents.Types`), `phase` the ticket's phase when it happened, and `actor`
  who wrote it: the machine, an agent (its run and run kind) or a person (their name). `parent`
  nests a step under another event, `supersedes` names an earlier event a later fact replaces, and
  `idempotency` is the key a second write is a no-op for. `summary` (`%{title, detail}`) is rendered
  by Symphony, never written by an agent, and nil until a renderer exists.
  """

  @type actor ::
          %{kind: :machine}
          | %{kind: :agent, run_id: String.t() | nil, run_kind: String.t()}
          | %{kind: :person, name: String.t()}

  @typedoc "The forms an actor is given in: `:machine`, `{:agent, run_id, run_kind}`, `{:person, name}`, or `t:actor/0`."
  @type actor_input :: :machine | {:agent, String.t() | nil, String.t() | atom()} | {:person, String.t()} | map()

  @type t :: %__MODULE__{
          id: String.t() | nil,
          seq: non_neg_integer() | nil,
          repo_key: String.t() | nil,
          issue_id: String.t() | nil,
          at: DateTime.t() | nil,
          type: String.t() | nil,
          phase: String.t() | nil,
          actor: actor(),
          run_id: String.t() | nil,
          head_sha: String.t() | nil,
          parent: String.t() | nil,
          supersedes: String.t() | nil,
          idempotency: String.t() | nil,
          payload: map(),
          summary: %{title: String.t(), detail: String.t() | nil} | nil,
          artifacts: [String.t()]
        }

  defstruct id: nil,
            seq: nil,
            repo_key: nil,
            issue_id: nil,
            at: nil,
            type: nil,
            phase: nil,
            actor: %{kind: :machine},
            run_id: nil,
            head_sha: nil,
            parent: nil,
            supersedes: nil,
            idempotency: nil,
            payload: %{},
            summary: nil,
            artifacts: []

  @crockford "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @doc """
  An event from a map (a stored record, or one a caller built), with every field in its expected
  shape: strings blank-trimmed to nil, a malformed actor read as the machine, a non-map payload as
  empty, a malformed summary as nil and artifacts kept only as strings.
  """
  @spec normalize(map() | t()) :: t()
  def normalize(%__MODULE__{} = event), do: event |> Map.from_struct() |> normalize()

  def normalize(record) when is_map(record) do
    %__MODULE__{
      id: string(record, :id),
      seq: non_neg_integer(Map.get(record, :seq)),
      repo_key: string(record, :repo_key),
      issue_id: string(record, :issue_id),
      at: datetime(Map.get(record, :at)),
      type: string(record, :type),
      phase: string(record, :phase),
      actor: normalize_actor(Map.get(record, :actor)) || %{kind: :machine},
      run_id: string(record, :run_id),
      head_sha: string(record, :head_sha),
      parent: string(record, :parent),
      supersedes: string(record, :supersedes),
      idempotency: string(record, :idempotency),
      payload: map_or_empty(Map.get(record, :payload)),
      summary: summary(Map.get(record, :summary)),
      artifacts: artifacts(Map.get(record, :artifacts))
    }
  end

  @doc "The event as the plain map the store keeps, so a stored record never depends on this struct."
  @spec to_record(t()) :: map()
  def to_record(%__MODULE__{} = event), do: Map.from_struct(event)

  @doc """
  The actor `input` names (see `t:actor_input/0`), or nil when it names none: an agent without a run
  kind, a person without a name, anything else.
  """
  @spec normalize_actor(actor_input() | term()) :: actor() | nil
  def normalize_actor(:machine), do: %{kind: :machine}
  def normalize_actor({:agent, run_id, run_kind}), do: agent(run_id, run_kind)
  def normalize_actor({:person, name}), do: person(name)
  def normalize_actor(%{kind: kind}) when kind in [:machine, "machine"], do: %{kind: :machine}
  def normalize_actor(%{kind: kind} = actor) when kind in [:agent, "agent"], do: agent(Map.get(actor, :run_id), Map.get(actor, :run_kind))
  def normalize_actor(%{kind: kind} = actor) when kind in [:person, "person"], do: person(Map.get(actor, :name))
  def normalize_actor(_input), do: nil

  @doc "The actor's kind: `:machine`, `:agent` or `:person`."
  @spec actor_kind(actor()) :: :machine | :agent | :person
  def actor_kind(%{kind: kind}), do: kind

  @doc """
  A new ULID for an event at `at`: 48 bits of Unix milliseconds then 80 random bits, as 26
  characters of Crockford base32, so ids sort by time.
  """
  @spec ulid(DateTime.t()) :: String.t()
  def ulid(%DateTime{} = at) do
    millis = at |> DateTime.to_unix(:millisecond) |> max(0)
    <<value::unsigned-size(128)>> = <<millis::unsigned-size(48), :crypto.strong_rand_bytes(10)::binary>>

    for shift <- 125..0//-5, into: "" do
      binary_part(@crockford, Bitwise.band(Bitwise.bsr(value, shift), 31), 1)
    end
  end

  defp agent(run_id, run_kind) do
    case kind_string(run_kind) do
      nil -> nil
      run_kind -> %{kind: :agent, run_id: normalize_string(run_id), run_kind: run_kind}
    end
  end

  defp person(name) do
    case normalize_string(name) do
      nil -> nil
      name -> %{kind: :person, name: name}
    end
  end

  defp kind_string(kind) when is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind)
  defp kind_string(kind), do: normalize_string(kind)

  defp summary(%{title: title} = summary) when is_binary(title), do: %{title: title, detail: normalize_string(Map.get(summary, :detail))}
  defp summary(_summary), do: nil

  defp artifacts(artifacts) when is_list(artifacts), do: Enum.filter(artifacts, &(is_binary(&1) and &1 != ""))
  defp artifacts(_artifacts), do: []

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_value), do: %{}

  defp non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_neg_integer(_value), do: nil

  defp datetime(%DateTime{} = at), do: at
  defp datetime(_value), do: nil

  defp string(map, key), do: normalize_string(Map.get(map, key))

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil
end
