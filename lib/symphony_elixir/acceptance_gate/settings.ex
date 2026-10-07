defmodule SymphonyElixir.AcceptanceGate.Settings do
  @moduledoc """
  The `auto_review.acceptance_gate` block of `symphony.yml`: the kill switch (`mode`), the
  gate agent's run settings and the `escalate` rules that send a PR to a human whatever the
  gate agent says.

  The escalation lists always start with the built-in defaults: a configured list adds to
  them and can't remove one. A `repositories[].acceptance_gate` override is merged on top by
  `merge_override/2`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Config.Schema.Agent

  @modes ["off", "shadow", "enforce"]

  defmodule BusyFiles do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @fields [:top, :window_days, :max_lines]

    # The `top` files changed most often on the default branch over `window_days`; a PR that
    # changes more than `max_lines` lines in one of them escalates.
    embedded_schema do
      field(:top, :integer, default: 10)
      field(:window_days, :integer, default: 14)
      field(:max_lines, :integer, default: 300)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [], message: fn _field, _meta -> "must be a positive integer" end)
      |> validate_number(:top, greater_than: 0, message: "must be a positive integer")
      |> validate_number(:window_days, greater_than: 0, message: "must be a positive integer")
      |> validate_number(:max_lines, greater_than: 0, message: "must be a positive integer")
    end
  end

  defmodule Escalate do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @dependency_modes ["off", "major", "any"]

    @built_in %{
      labels: ["needs-human", "plan", "breakdown"],
      ticket_patterns: [
        "(?i)\\b(human|manual(ly)?)\\s+review",
        "(?i)must not (auto-?approve|auto-?merge)",
        "(?i)\\bneeds?[- ]human\\b"
      ],
      paths: [
        "**/*auth*/**",
        "**/*auth*",
        "**/*token*",
        "**/*secret*",
        "**/*credential*",
        "**/*permission*",
        "**/*sandbox*",
        "**/*.entitlements",
        "**/migrations/**",
        "**/*migration*",
        ".github/workflows/**",
        ".github/CODEOWNERS"
      ],
      diff_patterns: [
        "(?i)\\bdrop\\s+(table|column|index)\\b",
        "(?i)\\btruncate\\s+table\\b",
        "(?i)\\bdelete\\s+from\\b",
        "\\brm\\s+-rf\\b"
      ]
    }

    @list_fields Map.keys(@built_in)
    @pattern_fields [:ticket_patterns, :diff_patterns]

    @primary_key false

    embedded_schema do
      field(:labels, {:array, :string}, default: @built_in.labels)
      field(:ticket_patterns, {:array, :string}, default: @built_in.ticket_patterns)
      field(:paths, {:array, :string}, default: @built_in.paths)
      field(:diff_patterns, {:array, :string}, default: @built_in.diff_patterns)
      field(:dependencies, :string, default: "major")
      field(:max_changed_lines, :integer, default: 1500)
      field(:inconclusive_limit, :integer, default: 2)
      embeds_one(:busy_files, BusyFiles, on_replace: :update, defaults_to_struct: true)
    end

    @doc "The built-in escalation lists every repository gets, whatever its config says."
    @spec built_in() :: %{atom() => [String.t()]}
    def built_in, do: @built_in

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @list_fields ++ [:dependencies, :max_changed_lines, :inconclusive_limit], empty_values: [])
      |> cast_embed(:busy_files, with: &BusyFiles.changeset/2)
      |> keep_built_in_lists()
      |> validate_patterns()
      |> validate_inclusion(:dependencies, @dependency_modes, message: "must be one of: #{Enum.join(@dependency_modes, ", ")}")
      |> validate_number(:max_changed_lines, greater_than: 0, message: "must be a positive integer")
      |> validate_number(:inconclusive_limit, greater_than: 0, message: "must be a positive integer")
    end

    # A configured list adds to the built-in one; it never replaces it.
    defp keep_built_in_lists(changeset) do
      Enum.reduce(@list_fields, changeset, fn field, acc ->
        update_change(acc, field, fn values ->
          values = values |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
          Enum.uniq(@built_in[field] ++ values)
        end)
      end)
    end

    defp validate_patterns(changeset) do
      Enum.reduce(@pattern_fields, changeset, fn field, acc -> validate_change(acc, field, &pattern_errors/2) end)
    end

    defp pattern_errors(field, patterns) do
      for pattern <- patterns, {:error, {reason, _at}} <- [Regex.compile(pattern)] do
        {field, "has an invalid regular expression `#{pattern}`: #{reason}"}
      end
    end
  end

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
