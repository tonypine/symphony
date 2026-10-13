defmodule SymphonyElixir.TicketState do
  @moduledoc """
  The canonical per-ticket state machine record.

  A record holds everything the machine owns for one ticket: its current phase, the phase
  a CI Fix stay came from (so a mechanical repair can return it), the holds that pause it
  (Blocked / Needs Decision), the CI state of each PR head it has seen, its verdict records and its
  signals ledger (the timeline both the machinery and agents read).

  The record is persisted by `SymphonyElixir.RunStore`; this module owns its shape and the
  operations that move it. It is inert by design: nothing dispatches on a record yet. It exists so
  every later sub-ticket of the state-machine redesign reads and writes the ticket's state in one
  place, and so the signals ledger can be injected into run prompts (see
  `SymphonyElixir.PromptBuilder`).
  """

  @max_signals 50
  @max_verdicts 50
  @max_ci_states 20

  @hold_kinds [:blocked, :needs_decision]

  @typedoc """
  What a hold waits on, structured so the machine can clear it on its own: the dependency key(s)
  it is blocked by (`type: "dependency"`), an access need (`type: "access"`) or the fix ticket a
  self-heal filed (`type: "fix_ticket"`).
  """
  @type waits_on :: %{type: String.t(), keys: [String.t()]} | nil

  @typedoc "A hold pauses the ticket in its phase; the label is only its projection."
  @type hold :: %{
          kind: :blocked | :needs_decision,
          reason: String.t() | nil,
          clearing_condition: String.t() | nil,
          waits_on: waits_on(),
          decision: map() | nil,
          set_at: DateTime.t() | nil
        }

  @typedoc "A verdict record binds an outcome to the head SHA it judged."
  @type verdict :: %{
          kind: String.t(),
          head_sha: String.t() | nil,
          outcome: String.t(),
          recorded_at: DateTime.t() | nil
        }

  @typedoc "One entry of the signals ledger."
  @type signal :: %{name: String.t(), details: map(), at: DateTime.t()}

  @typedoc "The CI state of one PR head."
  @type ci_state :: %{head_sha: String.t() | nil, status: String.t(), updated_at: DateTime.t() | nil}

  @typedoc """
  What the self-heal lane last did for this ticket: the broken component and the failure signature
  it last saw, the repo that owns the fix (the design's scope rule), the fix ticket it filed or
  reused, and how many times the flow has retried the block. It is how a recurring block is
  compared old against new (`SymphonyElixir.SelfHeal`).
  """
  @type self_heal :: %{
          component: String.t(),
          scope: String.t() | nil,
          signature: String.t(),
          fix_ticket: String.t() | nil,
          attempts: non_neg_integer(),
          at: DateTime.t() | nil
        }

  @type t :: %{
          repo_key: String.t() | nil,
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          phase: String.t() | nil,
          ci_fix_origin: String.t() | nil,
          holds: [hold()],
          ci_states: [ci_state()],
          verdicts: [verdict()],
          signals: [signal()],
          self_heal: self_heal() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  A new record for `repo_key`'s `issue_id`, with any `attrs` applied. `attrs` may set `:phase`,
  `:issue_identifier`, `:holds`, `:ci_states`, `:verdicts` and `:signals`; anything else is kept.
  """
  @spec new(String.t(), String.t(), map()) :: t()
  def new(repo_key, issue_id, attrs \\ %{}) when is_binary(issue_id) do
    attrs
    |> Map.new()
    |> Map.put(:repo_key, repo_key)
    |> Map.put(:issue_id, issue_id)
    |> normalize()
  end

  @doc """
  Fills a record's defaults and normalizes its lists, so a record read from the store and a record
  built by a caller have the same shape. A non-map is treated as an empty record.
  """
  @spec normalize(map() | term()) :: t()
  def normalize(record) when is_map(record) do
    %{
      repo_key: map_string(record, :repo_key),
      issue_id: map_string(record, :issue_id),
      issue_identifier: map_string(record, :issue_identifier),
      phase: map_string(record, :phase),
      ci_fix_origin: map_string(record, :ci_fix_origin),
      holds: normalize_holds(Map.get(record, :holds)),
      ci_states: normalize_ci_states(Map.get(record, :ci_states)),
      verdicts: normalize_verdicts(Map.get(record, :verdicts)),
      signals: normalize_signals(Map.get(record, :signals)),
      self_heal: normalize_self_heal(Map.get(record, :self_heal)),
      updated_at: map_datetime(record, :updated_at)
    }
  end

  def normalize(_record) do
    %{
      repo_key: nil,
      issue_id: nil,
      issue_identifier: nil,
      phase: nil,
      ci_fix_origin: nil,
      holds: [],
      ci_states: [],
      verdicts: [],
      signals: [],
      self_heal: nil,
      updated_at: nil
    }
  end

  @doc "Sets the record's phase, the state the machine believes the ticket is in."
  @spec put_phase(t(), String.t() | nil, DateTime.t()) :: t()
  def put_phase(record, phase, at \\ DateTime.utc_now()) do
    record
    |> normalize()
    |> Map.put(:phase, normalize_string(phase))
    |> Map.put(:updated_at, at)
  end

  @doc """
  Records the phase a CI Fix ticket came from, so a mechanical repair can return it there. The
  origin is recorded when the ticket enters the CI Fix state (see `SymphonyElixir.CiFix`); a `nil`
  clears it.
  """
  @spec put_ci_fix_origin(t(), String.t() | nil, DateTime.t()) :: t()
  def put_ci_fix_origin(record, origin, at \\ DateTime.utc_now()) do
    record
    |> normalize()
    |> Map.put(:ci_fix_origin, normalize_string(origin))
    |> Map.put(:updated_at, at)
  end

  @doc "The phase the ticket's current CI Fix stay came from, or nil."
  @spec ci_fix_origin(t()) :: String.t() | nil
  def ci_fix_origin(record), do: record |> normalize() |> Map.fetch!(:ci_fix_origin)

  @doc """
  Records what the self-heal lane last did for the ticket: the broken component, the repo that owns
  the fix, the failure signature, the fix ticket it filed or reused and the retry count. A record
  with no `:component` clears it, which is how a healed ticket forgets the block.
  """
  @spec put_self_heal(t(), map(), DateTime.t()) :: t()
  def put_self_heal(record, attrs, at \\ DateTime.utc_now()) do
    record
    |> normalize()
    |> Map.put(:self_heal, self_heal_from(attrs, at))
    |> Map.put(:updated_at, at)
  end

  @doc "The ticket's self-heal bookkeeping, or nil when it has none."
  @spec self_heal(t()) :: self_heal() | nil
  def self_heal(record), do: record |> normalize() |> Map.fetch!(:self_heal)

  @doc """
  Drops the stale fix-ticket pointer from the ticket's self-heal bookkeeping, keeping the broken
  component, the failure signature and the retry count. The fix ticket a hold waited on has gone
  terminal, so it no longer owns the component; the signature stays so a block that recurs after the
  repair landed is compared against the failure the repair was for rather than judged as a first
  one. A record with no bookkeeping is unchanged.
  """
  @spec clear_fix_ticket(t(), DateTime.t()) :: t()
  def clear_fix_ticket(record, at \\ DateTime.utc_now()) do
    record
    |> normalize()
    |> Map.update!(:self_heal, &drop_fix_ticket/1)
    |> Map.put(:updated_at, at)
  end

  @doc """
  Records a named signal at the head of the ledger, with `details` (a map) and the time it
  happened. Unknown signal names are kept as given; the ledger is bounded to the newest entries.
  """
  @spec record_signal(t(), String.t(), map(), DateTime.t()) :: t()
  def record_signal(record, name, details \\ %{}, at \\ DateTime.utc_now()) do
    signal = %{name: normalize_string(name) || "", details: Map.new(details || %{}), at: at}

    record
    |> normalize()
    |> Map.update!(:signals, &Enum.take([signal | &1], @max_signals))
    |> Map.put(:updated_at, at)
  end

  @doc """
  Sets (or replaces) a hold of `kind`. A hold records why the ticket waits and what clears it; a
  Needs Decision hold also carries its decision payload.
  """
  @spec set_hold(t(), :blocked | :needs_decision, map(), DateTime.t()) :: t()
  def set_hold(record, kind, attrs \\ %{}, at \\ DateTime.utc_now()) when kind in @hold_kinds do
    hold = %{
      kind: kind,
      reason: map_string(attrs, :reason),
      clearing_condition: map_string(attrs, :clearing_condition),
      waits_on: map_waits_on(attrs),
      decision: map_decision(attrs),
      set_at: at
    }

    record
    |> normalize()
    |> Map.update!(:holds, fn holds -> [hold | Enum.reject(holds, &(&1.kind == kind))] end)
    |> Map.put(:updated_at, at)
  end

  @doc "Clears the hold of `kind`, if set; the ticket continues in place."
  @spec clear_hold(t(), :blocked | :needs_decision, DateTime.t()) :: t()
  def clear_hold(record, kind, at \\ DateTime.utc_now()) when kind in @hold_kinds do
    record
    |> normalize()
    |> Map.update!(:holds, &Enum.reject(&1, fn hold -> hold.kind == kind end))
    |> Map.put(:updated_at, at)
  end

  @doc "The hold of `kind` on the record, or nil."
  @spec get_hold(t(), :blocked | :needs_decision) :: hold() | nil
  def get_hold(record, kind) when kind in @hold_kinds do
    record |> normalize() |> Map.fetch!(:holds) |> Enum.find(&(&1.kind == kind))
  end

  @doc "Whether a hold of `kind` is set."
  @spec hold?(t(), :blocked | :needs_decision) :: boolean()
  def hold?(record, kind) when kind in @hold_kinds do
    record |> normalize() |> Map.fetch!(:holds) |> Enum.any?(&(&1.kind == kind))
  end

  @doc "Records a verdict bound to the head SHA it judged."
  @spec record_verdict(t(), String.t(), String.t() | nil, String.t(), DateTime.t()) :: t()
  def record_verdict(record, kind, head_sha, outcome, at \\ DateTime.utc_now()) do
    verdict = %{
      kind: normalize_string(kind) || "",
      head_sha: normalize_string(head_sha),
      outcome: normalize_string(outcome) || "",
      recorded_at: at
    }

    record
    |> normalize()
    |> Map.update!(:verdicts, &Enum.take([verdict | &1], @max_verdicts))
    |> Map.put(:updated_at, at)
  end

  @doc "Upserts the CI state (`running` / `green` / `red`) of one PR head, newest first."
  @spec record_ci_state(t(), String.t() | nil, String.t(), DateTime.t()) :: t()
  def record_ci_state(record, head_sha, status, at \\ DateTime.utc_now()) do
    head_sha = normalize_string(head_sha)
    state = %{head_sha: head_sha, status: normalize_string(status) || "", updated_at: at}

    record
    |> normalize()
    |> Map.update!(:ci_states, fn states ->
      [state | Enum.reject(states, &(&1.head_sha == head_sha))] |> Enum.take(@max_ci_states)
    end)
    |> Map.put(:updated_at, at)
  end

  @doc """
  Upserts the CI state of one PR head with last-write-wins ordering: a write whose `at` is older
  than the entry the record already holds for that head is dropped (`:stale`), so a slow webhook
  delivery can't overwrite a newer poll. A write that repeats the held status is `:unchanged`; any
  other accepted write is `:changed`, which is what projects the ticket's CI label. `at` is the
  check's completion time (or the observation time when the read carries none).
  """
  @spec put_ci_state(t(), String.t() | nil, String.t(), DateTime.t()) ::
          {t(), :changed | :unchanged | :stale}
  def put_ci_state(record, head_sha, status, at) when is_struct(at, DateTime) do
    record = normalize(record)
    head_sha = normalize_string(head_sha)
    status = normalize_string(status) || ""

    case ci_state(record, head_sha) do
      %{updated_at: %DateTime{} = existing_at} = existing ->
        cond do
          DateTime.compare(at, existing_at) == :lt -> {record, :stale}
          existing.status == status -> {record, :unchanged}
          true -> {record_ci_state(record, head_sha, status, at), :changed}
        end

      _none ->
        {record_ci_state(record, head_sha, status, at), :changed}
    end
  end

  @doc """
  The ticket's current (newest) CI state, or nil before any was recorded. Entries are kept
  newest-first, so this is the state of the head the ticket is on now.
  """
  @spec current_ci_state(t()) :: ci_state() | nil
  def current_ci_state(record) do
    record |> normalize() |> Map.fetch!(:ci_states) |> List.first()
  end

  @doc "The record's CI state for `head_sha`, or nil."
  @spec ci_state(t(), String.t() | nil) :: ci_state() | nil
  def ci_state(record, head_sha) do
    head_sha = normalize_string(head_sha)

    record
    |> normalize()
    |> Map.fetch!(:ci_states)
    |> Enum.find(&(&1.head_sha == head_sha))
  end

  @doc "The newest `limit` signals, newest first, for prompt injection."
  @spec recent_signals(t(), non_neg_integer()) :: [signal()]
  def recent_signals(record, limit \\ 10) when is_integer(limit) and limit >= 0 do
    record |> normalize() |> Map.fetch!(:signals) |> Enum.take(limit)
  end

  defp normalize_holds(holds) when is_list(holds) do
    holds
    |> Enum.flat_map(&normalize_hold/1)
    |> Enum.uniq_by(& &1.kind)
  end

  defp normalize_holds(_holds), do: []

  defp normalize_hold(%{kind: kind} = hold) when kind in @hold_kinds do
    [
      %{
        kind: kind,
        reason: map_string(hold, :reason),
        clearing_condition: map_string(hold, :clearing_condition),
        waits_on: map_waits_on(hold),
        decision: map_decision(hold),
        set_at: map_datetime(hold, :set_at)
      }
    ]
  end

  defp normalize_hold(_hold), do: []

  defp normalize_verdicts(verdicts) when is_list(verdicts) do
    verdicts
    |> Enum.flat_map(&normalize_verdict/1)
    |> Enum.take(@max_verdicts)
  end

  defp normalize_verdicts(_verdicts), do: []

  defp normalize_verdict(%{kind: kind} = verdict) when is_binary(kind) do
    [
      %{
        kind: kind,
        head_sha: map_string(verdict, :head_sha),
        outcome: map_string(verdict, :outcome) || "",
        recorded_at: map_datetime(verdict, :recorded_at)
      }
    ]
  end

  defp normalize_verdict(_verdict), do: []

  defp normalize_ci_states(states) when is_list(states) do
    states
    |> Enum.flat_map(&normalize_ci_state/1)
    |> Enum.take(@max_ci_states)
  end

  defp normalize_ci_states(_states), do: []

  defp normalize_ci_state(%{head_sha: head_sha} = state) when is_binary(head_sha) or is_nil(head_sha) do
    [
      %{
        head_sha: normalize_string(head_sha),
        status: map_string(state, :status) || "",
        updated_at: map_datetime(state, :updated_at)
      }
    ]
  end

  defp normalize_ci_state(_state), do: []

  defp normalize_signals(signals) when is_list(signals) do
    signals
    |> Enum.flat_map(&normalize_signal/1)
    |> Enum.take(@max_signals)
  end

  defp normalize_signals(_signals), do: []

  defp normalize_signal(%{name: name} = signal) when is_binary(name) do
    [%{name: name, details: Map.new(Map.get(signal, :details) || %{}), at: map_datetime(signal, :at)}]
  end

  defp normalize_signal(_signal), do: []

  # Self-heal bookkeeping keeps only a non-blank component: anything else is no bookkeeping at all.
  defp normalize_self_heal(attrs) when is_map(attrs), do: self_heal_from(attrs, map_datetime(attrs, :at))

  defp normalize_self_heal(_attrs), do: nil

  # A record with no bookkeeping has no fix ticket to drop.
  defp drop_fix_ticket(nil), do: nil
  defp drop_fix_ticket(self_heal), do: Map.put(self_heal, :fix_ticket, nil)

  defp self_heal_from(attrs, at) do
    case normalize_string(Map.get(attrs, :component)) do
      nil ->
        nil

      component ->
        %{
          component: component,
          scope: map_string(attrs, :scope),
          signature: map_string(attrs, :signature) || "",
          fix_ticket: map_string(attrs, :fix_ticket),
          attempts: normalize_attempts(Map.get(attrs, :attempts)),
          at: at
        }
    end
  end

  defp normalize_attempts(value) when is_integer(value) and value >= 0, do: value
  defp normalize_attempts(_value), do: 0

  defp map_decision(attrs) do
    case Map.get(attrs, :decision) do
      decision when is_map(decision) -> Map.new(decision)
      _decision -> nil
    end
  end

  # `waits_on` keeps only its structured half: a non-empty string type and a list of string keys.
  defp map_waits_on(attrs) do
    case Map.get(attrs, :waits_on) do
      %{type: type} = waits_on when is_binary(type) ->
        case String.trim(type) do
          "" -> nil
          trimmed -> %{type: trimmed, keys: normalize_keys(Map.get(waits_on, :keys))}
        end

      _waits_on ->
        nil
    end
  end

  defp normalize_keys(keys) when is_list(keys) do
    keys
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_keys(_keys), do: []

  defp map_string(map, key), do: normalize_string(Map.get(map, key))

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp map_datetime(map, key) do
    case Map.get(map, key) do
      %DateTime{} = datetime -> datetime
      _datetime -> nil
    end
  end
end
