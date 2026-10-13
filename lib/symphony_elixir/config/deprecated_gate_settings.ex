defmodule SymphonyElixir.Config.DeprecatedGateSettings do
  @moduledoc """
  The deprecated `auto_review.acceptance_gate` block of `symphony.yml`. The acceptance gate is
  retired (`docs/design/state-machine.md` §Retired): the block still loads during its deprecation
  window, with a warning per key (`SymphonyElixir.Config.SystemSchema`), but only two parts of it
  still act. `mode` derives a repo's `manual_review` when that is unset, and the `escalate` rules
  (`SymphonyElixir.Config.Escalate`) feed Code Review. The gate agent's run settings (`runtime`,
  `command`, `model`, `effort`, `max_turns`, `timeout_ms`, `max_concurrent`) have no effect.

  A `repositories[].acceptance_gate` override is merged on top by `merge_override/2`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Config.Escalate
  alias SymphonyElixir.Config.Schema.Agent

  # Recompile when the escalate rules' defaults change (see the note in `SystemSchema`).
  require Escalate

  @modes ["off", "shadow", "enforce"]

  @type t :: %__MODULE__{}

  @primary_key false
  @fields [:mode, :kind, :command, :model, :effort, :max_turns, :timeout_ms, :max_concurrent]

  embedded_schema do
    field(:mode, :string, default: "off")
    field(:kind, :string)
    field(:command, :string)
    field(:model, :string)
    field(:effort, :string)
    field(:max_turns, :integer, default: 12)
    field(:timeout_ms, :integer, default: 900_000)
    field(:max_concurrent, :integer, default: 2)
    embeds_one(:escalate, Escalate, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, @fields, empty_values: [])
    |> cast_embed(:escalate, with: &Escalate.changeset/2)
    |> validate_inclusion(:mode, @modes, message: "must be one of: #{Enum.join(@modes, ", ")}")
    |> validate_inclusion(:kind, ["codex", "claude"])
    |> validate_number(:max_turns, greater_than: 0)
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_number(:max_concurrent, greater_than: 0)
    |> Agent.validate_profile_fields()
  end

  @doc """
  Merges a repository's override into the global block, both as string-keyed maps: a scalar
  in the override replaces the global one, a list adds to it.
  """
  @spec merge_override(map(), map()) :: map()
  def merge_override(global, override) when is_map(global) and is_map(override) do
    Map.merge(global, override, fn _key, global_value, override_value -> merge_value(global_value, override_value) end)
  end

  defp merge_value(global, override) when is_map(global) and is_map(override), do: merge_override(global, override)
  defp merge_value(global, override) when is_list(global) and is_list(override), do: Enum.uniq(global ++ override)
  defp merge_value(_global, override), do: override
end
