defmodule SymphonyElixir.Config.Escalate do
  @moduledoc """
  The escalation rules Code Review applies (`SymphonyElixir.EscalationRules`): the person rules
  (`labels`, `ticket_patterns`) pause an approved Code Review ticket on a Needs Decision hold, and
  the risk rules (`paths`, `diff_patterns`, `dependencies`, `max_changed_lines`, `busy_files`) tell
  the reviewer what they found, so its one review weighs it. `on_match` sets a risk rule to `ask`
  instead: an approval it matches then pauses on a Needs Decision hold like a person rule's.
  `size_counts` says what `max_changed_lines` counts: every added, changed and removed line
  (`total`), or only the added and changed ones (`added`), so a large deletion doesn't match.

  During the acceptance gate's deprecation window the rules are still read from the
  `auto_review.acceptance_gate.escalate` block of `symphony.yml` (and a
  `repositories[].acceptance_gate.escalate` override), which loads with a deprecation warning.

  The escalation lists always start with the built-in defaults: a configured list adds to them and
  can't remove one. The one exception is `ticket_patterns_builtin: false`, which drops the built-in
  `ticket_patterns` and leaves only the configured ones.
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

  defmodule OnMatch do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    @fields [:paths, :diff_patterns, :dependencies, :max_changed_lines, :busy_files]
    @modes ["inform", "ask"]

    # What a match of each risk rule does: `inform` tells the reviewer, `ask` also asks a person once
    # the reviewer approves.
    embedded_schema do
      for rule <- @fields, do: field(rule, :string, default: "inform")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      changeset = cast(schema, attrs, @fields, empty_values: [])
      Enum.reduce(@fields, changeset, &validate_inclusion(&2, &1, @modes, message: "must be one of: #{Enum.join(@modes, ", ")}"))
    end
  end

  @type t :: %__MODULE__{}

  @dependency_modes ["off", "major", "any"]

  @built_in %{
    labels: ["needs-human", "plan", "breakdown"],
    # A ticket that asks for a person's review, not one that names the `Human Review` state or
    # discusses manual review as a topic.
    ticket_patterns: [
      "(?i)\\b(requires?|needs?|wants?|asks?\\s+for|asking\\s+for|requests?|gets?|getting|send\\s+(it|this)\\s+for|after)\\s+(an?\\s+)?(human|manual)\\s+review\\b",
      "(?i)\\b(human|manual)\\s+review\\s+(is\\s+)?(required|needed)\\b",
      "(?i)\\b(must|should|has\\s+to|needs?\\s+to)\\s+be\\s+(manually\\s+reviewed|reviewed\\s+by\\s+an?\\s+(human|person))\\b",
      "(?i)\\b(please\\s+manually|(want|need)s?\\s+to\\s+manually|have\\s+an?\\s+(human|person)|an?\\s+(human|person)\\s+(must|should|needs?\\s+to))\\s+review\\b",
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
  @size_counts ["total", "added"]
  @fields @list_fields ++
            [:ticket_patterns_builtin, :dependencies, :max_changed_lines, :size_counts, :inconclusive_limit]
  @pattern_fields [:ticket_patterns, :diff_patterns]

  @primary_key false

  embedded_schema do
    field(:labels, {:array, :string}, default: @built_in.labels)
    field(:ticket_patterns, {:array, :string}, default: @built_in.ticket_patterns)
    field(:ticket_patterns_builtin, :boolean, default: true)
    field(:paths, {:array, :string}, default: @built_in.paths)
    field(:diff_patterns, {:array, :string}, default: @built_in.diff_patterns)
    field(:dependencies, :string, default: "major")
    field(:max_changed_lines, :integer, default: 1500)
    field(:size_counts, :string, default: "total")
    field(:inconclusive_limit, :integer, default: 2)
    embeds_one(:busy_files, BusyFiles, on_replace: :update, defaults_to_struct: true)
    embeds_one(:on_match, OnMatch, on_replace: :update, defaults_to_struct: true)
  end

  @doc """
  The built-in escalation lists every repository gets, whatever its config says, but for the
  `ticket_patterns` that `ticket_patterns_builtin: false` drops.
  """
  @spec built_in() :: %{atom() => [String.t()]}
  def built_in, do: @built_in

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, @fields, empty_values: [])
    |> cast_embed(:busy_files, with: &BusyFiles.changeset/2)
    |> cast_embed(:on_match, with: &OnMatch.changeset/2)
    |> drop_built_in_ticket_patterns()
    |> keep_built_in_lists()
    |> validate_patterns()
    |> validate_inclusion(:dependencies, @dependency_modes, message: "must be one of: #{Enum.join(@dependency_modes, ", ")}")
    |> validate_number(:max_changed_lines, greater_than: 0, message: "must be a positive integer")
    |> validate_inclusion(:size_counts, @size_counts, message: "must be one of: #{Enum.join(@size_counts, ", ")}")
    |> validate_number(:inconclusive_limit, greater_than: 0, message: "must be a positive integer")
  end

  # With `ticket_patterns_builtin: false` the field holds the configured patterns, none when the
  # config lists none. A list equal to the defaults casts as no change, hence the params.
  defp drop_built_in_ticket_patterns(changeset) do
    if built_in_ticket_patterns?(changeset) or Keyword.has_key?(changeset.errors, :ticket_patterns) do
      changeset
    else
      configured = if Map.has_key?(changeset.params, "ticket_patterns"), do: get_field(changeset, :ticket_patterns), else: []
      force_change(changeset, :ticket_patterns, configured)
    end
  end

  # A configured list adds to the built-in one; it never replaces it, unless the built-in ticket
  # patterns are off.
  defp keep_built_in_lists(changeset) do
    Enum.reduce(@list_fields, changeset, fn field, acc ->
      update_change(acc, field, fn values ->
        values = values |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        Enum.uniq(built_in(acc, field) ++ values)
      end)
    end)
  end

  defp built_in(changeset, :ticket_patterns) do
    if built_in_ticket_patterns?(changeset), do: @built_in.ticket_patterns, else: []
  end

  defp built_in(_changeset, field), do: @built_in[field]

  defp built_in_ticket_patterns?(changeset), do: get_field(changeset, :ticket_patterns_builtin) != false

  defp validate_patterns(changeset) do
    Enum.reduce(@pattern_fields, changeset, fn field, acc -> validate_change(acc, field, &pattern_errors/2) end)
  end

  defp pattern_errors(field, patterns) do
    for pattern <- patterns, {:error, {reason, _at}} <- [Regex.compile(pattern)] do
      {field, "has an invalid regular expression `#{pattern}`: #{reason}"}
    end
  end
end
