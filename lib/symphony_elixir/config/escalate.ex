defmodule SymphonyElixir.Config.Escalate do
  @moduledoc """
  The escalation rules Code Review applies (`SymphonyElixir.EscalationRules`): the person rules
  (`labels`, `ticket_patterns`) pause a Code Review ticket on a Needs Decision hold, and the risk
  rules (`paths`, `diff_patterns`, `dependencies`, `max_changed_lines`, `busy_files`) deepen the
  review with a second reviewer pass.

  During the acceptance gate's deprecation window the rules are still read from the
  `auto_review.acceptance_gate.escalate` block of `symphony.yml` (and a
  `repositories[].acceptance_gate.escalate` override), which loads with a deprecation warning.

  The escalation lists always start with the built-in defaults: a configured list adds to them and
  can't remove one.
  """
  use Ecto.Schema
  import Ecto.Changeset

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
