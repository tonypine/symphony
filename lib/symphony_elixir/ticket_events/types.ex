defmodule SymphonyElixir.TicketEvents.Types do
  @moduledoc """
  The closed vocabulary of ticket events (`SymphonyElixir.TicketEvents`): for each type, who may
  write it (`:machine`, `:agent`, `:person`), which agent run kinds may (`:any` or a list of
  `SymphonyElixir.RunKind` names), the payload schema (required and optional fields) and the
  idempotency rule.

  Field specs:

    * `:string` - a non-blank string; `{:string, max}` also bounds its length in characters.
    * `{:enum, values}` - one of `values`, given as a string or an atom, stored as a string.
    * `:non_neg_integer`, `:boolean`, `:map`, `{:list, :string}`, `:list`.
    * `{:nullable, spec}` - `spec` or nil.
    * `{:any_of, specs}` - the first spec that accepts the value.

  An optional field given as nil is left out, unless its spec is nullable. A field the type does
  not name is rejected. Every type a machine or a person writes also takes an optional `signal`, the
  legacy signal name it mirrors, so readers of the signals ledger can move over to events.

  The idempotency rule names the payload fields a key is derived from when the writer passes none
  (`{:fields, fields}`, used only when every field is present); `:writer` dedupes only on a key the
  writer passes.

  A decision a person must make has one representation, whoever asked it: `decision.requested`,
  then `decision.recorded` or `decision.withdrawn`. The Needs Decision hold is its projection, so
  `hold.set` and `hold.cleared` take only the `blocked` kind and `person.action` has no `decide`.
  State is machinery-only: an agent claims `finding.resolved`, it never records a verdict.

  Drift is machinery-only too: `drift.detected` when Linear shows a state other than the phase
  Symphony owns, then `drift.reverted` or `drift.revert_failed` for the move back, each with the
  record's phase and Linear's (`SymphonyElixir.TicketObservation`).

  A pause is machinery-only as well (`SymphonyElixir.Pauses`): `pause.set` for its first reason,
  `pause.reason_added` for each further one, `pause.reason_cleared` for a reason cleared while
  others remain and `pause.cleared` when none is left, with the reasons it cleared. A reason event
  names its kind (`reason`), its one line of plain words (`text`) and what it waits on.
  """

  alias SymphonyElixir.RunKind

  @type actor_kind :: :machine | :agent | :person
  @type field_spec ::
          :string
          | {:string, pos_integer()}
          | {:enum, [String.t()]}
          | :non_neg_integer
          | :boolean
          | :map
          | :list
          | {:list, :string}
          | {:nullable, field_spec()}
          | {:any_of, [field_spec()]}
  @type idempotency_rule :: :writer | {:fields, [atom()]}
  @type entry :: %{
          writers: [actor_kind()],
          run_kinds: :any | [String.t()],
          required: keyword(field_spec()),
          optional: keyword(field_spec()),
          idempotency: idempotency_rule()
        }
  @type error :: {:unknown_type, term()} | {:invalid_payload, [atom() | String.t()]} | {:not_allowed, String.t()}

  @verdict_kinds ~w(code_review qa ci_fix plan_review epic_review)
  @person_actions ~w(stop move force unblock restart)
  @step_modes ~w(orchestrated delegated output)
  @evidence {:any_of, [:string, {:list, :string}]}
  @tokens {:any_of, [:non_neg_integer, :map]}
  @signal [signal: :string]
  @drift [record_phase: :string, linear_phase: :string]
  @pause_reasons ~w(question ticket build person environment)
  @pause_reason [reason: {:enum, @pause_reasons}, text: {:string, 300}]
  @pause_reason_set %{
    writers: [:machine],
    run_kinds: [],
    required: @pause_reason,
    optional: [waits_on: :map, set_by: :map, releasable: :boolean] ++ @signal,
    idempotency: :writer
  }

  @step %{
    writers: [:agent],
    run_kinds: :any,
    required: [title: {:string, 200}, mode: {:enum, @step_modes}],
    optional: [step_id: {:nullable, {:string, 200}}],
    idempotency: :writer
  }

  @catalog %{
    "phase.entered" => %{
      writers: [:machine],
      run_kinds: [],
      required: [to: :string],
      optional: [from: :string, via: :string, reason: :string] ++ @signal,
      idempotency: :writer
    },
    "hold.set" => %{
      writers: [:machine],
      run_kinds: [],
      required: [kind: {:enum, ["blocked"]}],
      optional: [reason: :string, waits_on: :map] ++ @signal,
      idempotency: :writer
    },
    "hold.cleared" => %{
      writers: [:machine],
      run_kinds: [],
      required: [kind: {:enum, ["blocked"]}],
      optional: [by: :string] ++ @signal,
      idempotency: :writer
    },
    "run.started" => %{
      writers: [:machine],
      run_kinds: [],
      required: [run_id: :string, run_kind: :string],
      optional: [run_number: :non_neg_integer, state: :string, head: :string] ++ @signal,
      idempotency: {:fields, [:run_id]}
    },
    "run.ended" => %{
      writers: [:machine],
      run_kinds: [],
      required: [run_id: :string, exit: :string],
      optional:
        [
          run_kind: :string,
          run_number: :non_neg_integer,
          duration_ms: :non_neg_integer,
          tokens: @tokens,
          head: :string,
          counted: :boolean,
          transcript: :string
        ] ++ @signal,
      idempotency: {:fields, [:run_id]}
    },
    "attempt.pushed" => %{
      writers: [:machine],
      run_kinds: [],
      required: [head: :string],
      optional: [attempt: :non_neg_integer, intent: :string, pr_url: :string] ++ @signal,
      idempotency: :writer
    },
    "verdict.recorded" => %{
      writers: [:machine],
      run_kinds: [],
      required: [kind: {:enum, @verdict_kinds}, outcome: :string],
      optional: [head: :string, reason: :string] ++ @signal,
      idempotency: :writer
    },
    "decision.requested" => %{
      writers: [:machine, :agent],
      run_kinds: :any,
      required: [question: :string],
      optional: [title: :string, why: :string, options: :list, confirm: :string] ++ @signal,
      idempotency: :writer
    },
    "decision.withdrawn" => %{
      writers: [:machine, :agent],
      run_kinds: :any,
      required: [title: :string],
      optional: [question: :string, request: :string] ++ @signal,
      idempotency: {:fields, [:request]}
    },
    "decision.recorded" => %{
      writers: [:person],
      run_kinds: [],
      required: [answer: :string],
      optional: [title: :string, question: :string, key: :string, request: :string] ++ @signal,
      idempotency: {:fields, [:key]}
    },
    "person.action" => %{
      writers: [:person],
      run_kinds: [],
      required: [action: {:enum, @person_actions}],
      optional: [move: :string, from: :string, to: :string] ++ @signal,
      idempotency: :writer
    },
    "step.started" => @step,
    "step.completed" => @step,
    "step.skipped" => @step,
    "evidence" => %{
      writers: [:agent],
      run_kinds: :any,
      required: [caption: {:string, 500}],
      optional: [artifacts: {:list, :string}],
      idempotency: :writer
    },
    "finding.recorded" => %{
      writers: [:agent],
      run_kinds: ["qa"],
      required: [class: {:string, 100}, severity: {:string, 50}, description: {:string, 2_000}],
      optional: [viewport: {:string, 100}, step: {:string, 200}, evidence: @evidence],
      idempotency: :writer
    },
    "finding.resolved" => %{
      writers: [:agent],
      run_kinds: :any,
      required: [finding_id: :string, how: {:string, 2_000}],
      optional: [head: :string, evidence: @evidence],
      idempotency: :writer
    },
    "checklist.answered" => %{
      writers: [:agent],
      run_kinds: :any,
      required: [item: {:string, 500}, answer: {:string, 2_000}],
      optional: [],
      idempotency: :writer
    },
    "drift.detected" => %{writers: [:machine], run_kinds: [], required: @drift, optional: @signal, idempotency: :writer},
    "drift.reverted" => %{writers: [:machine], run_kinds: [], required: @drift, optional: @signal, idempotency: :writer},
    "drift.revert_failed" => %{
      writers: [:machine],
      run_kinds: [],
      required: @drift,
      optional: [error: :string] ++ @signal,
      idempotency: :writer
    },
    "pause.set" => @pause_reason_set,
    "pause.reason_added" => @pause_reason_set,
    "pause.reason_cleared" => %{
      writers: [:machine],
      run_kinds: [],
      required: @pause_reason,
      optional: [waits_on: :map, by: :map] ++ @signal,
      idempotency: :writer
    },
    "pause.cleared" => %{
      writers: [:machine],
      run_kinds: [],
      required: [cleared: :list],
      optional: [by: :map] ++ @signal,
      idempotency: :writer
    },
    "note" => %{
      writers: [:machine, :agent, :person],
      run_kinds: :any,
      required: [text: {:string, 4_000}],
      optional: [],
      idempotency: :writer
    }
  }

  @doc "Every event type with its writers, agent run kinds, payload schema and idempotency rule."
  @spec catalog() :: %{String.t() => entry()}
  def catalog, do: @catalog

  @doc "The run kinds an agent actor may carry: every `SymphonyElixir.RunKind` name."
  @spec agent_run_kinds() :: [String.t()]
  def agent_run_kinds, do: RunKind.names()

  @doc """
  Validates a payload of `type` written by an actor of `actor_kind` (an agent also names its
  `run_kind`). Returns the payload with its keys as atoms, its enums as strings and nil optional
  fields left out, or the first error: the type is unknown, the actor may not write it, or the
  payload's fields are missing, out of bounds or not in the schema (each named, in schema order).
  """
  @spec validate(term(), map() | term(), actor_kind(), String.t() | atom() | nil) :: {:ok, map()} | {:error, error()}
  def validate(type, payload, actor_kind, run_kind) do
    with {:ok, entry} <- fetch(type),
         :ok <- allowed(type, entry, actor_kind, run_kind) do
      validate_payload(entry, payload)
    end
  end

  @doc """
  The idempotency key of an event of `type`: the writer's key when it passes one, else the key the
  type's rule derives from the payload (`type:value…`), else nil.
  """
  @spec idempotency_key(String.t(), map(), String.t() | nil) :: String.t() | nil
  def idempotency_key(type, payload, given) do
    case blank_to_nil(given) do
      nil -> derived_key(type, Map.get(@catalog, type), payload)
      key -> key
    end
  end

  defp fetch(type) when is_binary(type) do
    case Map.fetch(@catalog, type) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_type, type}}
    end
  end

  defp fetch(type), do: {:error, {:unknown_type, type}}

  defp allowed(type, %{writers: writers, run_kinds: run_kinds}, actor_kind, run_kind) do
    run_kind = run_kind_name(run_kind)

    cond do
      actor_kind not in writers ->
        {:error, {:not_allowed, "#{type} is not written by #{actor_name(actor_kind)}"}}

      actor_kind != :agent ->
        :ok

      run_kind not in agent_run_kinds() ->
        {:error, {:not_allowed, "#{inspect(run_kind)} is not an agent run kind"}}

      run_kinds == :any or run_kind in run_kinds ->
        :ok

      true ->
        {:error, {:not_allowed, "#{type} is written only by #{Enum.join(run_kinds, ", ")} runs, not #{run_kind}"}}
    end
  end

  defp actor_name(kind) when kind in [:machine, :agent, :person], do: "a #{kind}"
  defp actor_name(kind), do: inspect(kind)

  defp run_kind_name(kind) when is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind)
  defp run_kind_name(kind), do: kind

  defp validate_payload(entry, payload) when is_map(payload) do
    fields = Keyword.keys(entry.required) ++ Keyword.keys(entry.optional)
    {payload, unknown} = atomize(payload, fields)

    {normalized, invalid} =
      Enum.reduce(entry.required, {%{}, []}, &check_required(&1, payload, &2))

    {normalized, invalid} = Enum.reduce(entry.optional, {normalized, invalid}, &check_optional(&1, payload, &2))

    case Enum.reverse(invalid) ++ Enum.sort(unknown) do
      [] -> {:ok, normalized}
      fields -> {:error, {:invalid_payload, fields}}
    end
  end

  defp validate_payload(_entry, _payload), do: {:error, {:invalid_payload, [:payload]}}

  # Payload keys arrive as atoms from the machinery and as strings from a tool's JSON; a string
  # that names a schema field becomes its atom, and any other key is unknown.
  defp atomize(payload, fields) do
    names = Map.new(fields, &{Atom.to_string(&1), &1})

    Enum.reduce(payload, {%{}, []}, fn {key, value}, {known, unknown} ->
      case field_name(key, fields, names) do
        nil -> {known, [key | unknown]}
        field -> {Map.put(known, field, value), unknown}
      end
    end)
  end

  defp field_name(key, fields, _names) when is_atom(key), do: if(key in fields, do: key)
  defp field_name(key, _fields, names) when is_binary(key), do: Map.get(names, key)
  defp field_name(_key, _fields, _names), do: nil

  defp check_required({field, spec}, payload, {normalized, invalid}) do
    case check(spec, Map.get(payload, field)) do
      {:ok, nil} -> {normalized, [field | invalid]}
      {:ok, value} -> {Map.put(normalized, field, value), invalid}
      :error -> {normalized, [field | invalid]}
    end
  end

  defp check_optional({field, spec}, payload, acc) do
    case Map.fetch(payload, field) do
      {:ok, nil} -> if match?({:nullable, _}, spec), do: put_checked({:ok, nil}, field, acc), else: acc
      {:ok, value} -> put_checked(check(spec, value), field, acc)
      :error -> acc
    end
  end

  defp put_checked({:ok, value}, field, {normalized, invalid}), do: {Map.put(normalized, field, value), invalid}
  defp put_checked(:error, field, {normalized, invalid}), do: {normalized, [field | invalid]}

  defp check({:nullable, spec}, value), do: check(spec, value)
  defp check(_spec, nil), do: {:ok, nil}

  defp check(:string, value) when is_binary(value), do: if(String.trim(value) == "", do: :error, else: {:ok, value})

  defp check({:string, max}, value) when is_binary(value) do
    if String.length(value) > max, do: :error, else: check(:string, value)
  end

  defp check({:enum, values}, value) when is_atom(value), do: check({:enum, values}, Atom.to_string(value))
  defp check({:enum, values}, value) when is_binary(value), do: if(value in values, do: {:ok, value}, else: :error)
  defp check(:non_neg_integer, value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp check(:boolean, value) when is_boolean(value), do: {:ok, value}
  defp check(:map, value) when is_map(value), do: {:ok, value}
  defp check(:list, value) when is_list(value), do: {:ok, value}

  defp check({:list, :string}, value) when is_list(value) do
    if Enum.all?(value, &match?({:ok, _}, check(:string, &1))), do: {:ok, value}, else: :error
  end

  defp check({:any_of, specs}, value) do
    Enum.find_value(specs, :error, fn spec ->
      case check(spec, value) do
        {:ok, checked} -> {:ok, checked}
        :error -> nil
      end
    end)
  end

  defp check(_spec, _value), do: :error

  defp derived_key(type, %{idempotency: {:fields, fields}}, payload) when is_map(payload) do
    values = Enum.map(fields, &Map.get(payload, &1))

    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      Enum.join([type | values], ":")
    end
  end

  defp derived_key(_type, _entry, _payload), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
