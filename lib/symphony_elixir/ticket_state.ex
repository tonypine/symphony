defmodule SymphonyElixir.TicketState do
  @moduledoc """
  The canonical per-ticket state machine record.

  A record holds everything the designed machine owns for one ticket: its current phase, the
  holds that pause it (Blocked / Needs Decision), the CI state of each PR head it has seen, its
  verdict records and its signals ledger (the timeline both the machinery and agents read).

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
  # The transition vocabulary of `docs/design/state-machine.md`, kept here as the one list the
  # machinery validates a signal name against.
  @signal_names [
    "claim",
    "handoff",
    "blocked",
    "unblocked",
    "review verdict",
    "QA verdict",
    "fix verdict",
    "plan verdict",
    "epic verdict",
    "decision requested",
    "decision returned",
    "merge settled",
    "restart",
    "deprioritized"
  ]

  @typedoc "A hold pauses the ticket in its phase; the label is only its projection."
  @type hold :: %{
          kind: :blocked | :needs_decision,
          reason: String.t() | nil,
          clearing_condition: String.t() | nil,
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

  @type t :: %{
          repo_key: String.t() | nil,
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          phase: String.t() | nil,
          holds: [hold()],
          ci_states: [ci_state()],
          verdicts: [verdict()],
          signals: [signal()],
          updated_at: DateTime.t() | nil
        }

  @doc "The signal names of the transition vocabulary."
  @spec signal_names() :: [String.t()]
  def signal_names, do: @signal_names

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
      holds: normalize_holds(Map.get(record, :holds)),
      ci_states: normalize_ci_states(Map.get(record, :ci_states)),
      verdicts: normalize_verdicts(Map.get(record, :verdicts)),
      signals: normalize_signals(Map.get(record, :signals)),
      updated_at: map_datetime(record, :updated_at)
    }
  end

  def normalize(_record) do
    %{
      repo_key: nil,
      issue_id: nil,
      issue_identifier: nil,
      phase: nil,
      holds: [],
      ci_states: [],
      verdicts: [],
      signals: [],
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

  defp map_decision(attrs) do
    case Map.get(attrs, :decision) do
      decision when is_map(decision) -> Map.new(decision)
      _decision -> nil
    end
  end

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
