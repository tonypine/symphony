defmodule SymphonyElixir.PrDecision.Table do
  @moduledoc """
  Renders the PR and CI decision table from `SymphonyElixir.PrDecision.upkeep_rules/0`,
  `SymphonyElixir.PrDecision.rules/0` and
  `SymphonyElixir.PrDecision.Facts.domains/0` as Markdown, for `docs/pr-ci-decisions.md`.

  The generated part sits between two markers, so prose written around it survives
  `mix pr_decision.table`; the drift test fails when the file and the rules disagree.
  """

  alias SymphonyElixir.PrDecision
  alias SymphonyElixir.PrDecision.{Action, Facts}

  @path "docs/pr-ci-decisions.md"
  @begin_marker "<!-- BEGIN mix pr_decision.table: generated from SymphonyElixir.PrDecision.rules/0, do not edit by hand -->"
  @end_marker "<!-- END mix pr_decision.table -->"

  @doc "Where the table lives in the repository."
  @spec path() :: String.t()
  def path, do: @path

  @doc "A whole new document: a title, a line on how it is made, and the generated part."
  @spec render() :: String.t()
  def render do
    """
    # PR and CI decisions

    What the PR and CI watcher does for a ticket in each phase and PR situation. The upkeep rules
    act first, each one that matches; then the flow rules are checked in order and the first that
    matches decides.

    #{generated()}
    """
  end

  @doc "`document` with its generated part replaced, or a whole new document when it has none."
  @spec update(String.t()) :: String.t()
  def update(document) do
    with [before, rest] <- String.split(document, @begin_marker, parts: 2),
         [_old, after_end] <- String.split(rest, @end_marker, parts: 2) do
      before <> generated() <> after_end
    else
      _no_markers -> render()
    end
  end

  @doc "The generated part, markers included."
  @spec generated() :: String.t()
  def generated do
    Enum.join([@begin_marker, upkeep_section(), rules_section(), facts_section(), waits_section(), @end_marker], "\n\n")
  end

  defp upkeep_section do
    """
    ## Upkeep

    Checked first on every read of a PR, by poll or by a delivery. Every upkeep rule that matches acts, and none stops the chain: the flow rule \
    below still decides on the same read, from the same facts. Upkeep never waits on a hold or a flow wait, only on a run: while one is \
    active it is deferred, and it fires on the read that sees the run end.

    #{rule_table(PrDecision.upkeep_rules())}\
    """
  end

  defp rules_section do
    "## Rules\n\nThe flow decision: the first rule that matches decides what happens to the ticket.\n\n" <> rule_table(PrDecision.rules())
  end

  defp rule_table(rules) do
    table(["Rule", "Phases", "When", "Then"], Enum.map(rules, fn rule -> row([rule.id, phases(rule.phases), rule.when, rule.then]) end))
  end

  defp facts_section do
    rows = Enum.map(Facts.domains(), &fact_row/1)

    """
    ## Facts

    Each fact a rule decides on, the values the table test enumerates, and when the fact is read. Counts list the value under the limit and the limit \
    (`max_red_attempts` is #{%Facts{}.max_red_attempts} by default; a conflict gets #{PrDecision.max_conflict_attempts()} fix runs).

    #{table(["Fact", "Values", "Read when"], rows)}\
    """
  end

  defp waits_section do
    """
    ## Waits

    These actions leave the ticket waiting, so each names who it waits on and what ends the wait: #{code_list(Action.waiting_kinds())}.

    Owners: #{code_list(Action.owners())}.\
    """
  end

  defp fact_row({field, values}), do: row(["`#{field}`", Enum.map_join(values, ", ", &value/1), "always"])
  defp fact_row({field, values, condition}), do: row(["`#{field}`", Enum.map_join(values, ", ", &value/1), Enum.map_join(condition, " and ", &holds/1)])

  defp holds({on, allowed}), do: "`#{on}` is #{Enum.map_join(allowed, " or ", &value/1)}"

  defp value([]), do: "empty"
  defp value([_ | _]), do: "not empty"
  defp value(value), do: "`#{value}`"

  defp phases(phases) do
    if phases == Facts.phases(), do: "all", else: Enum.map_join(phases, ", ", &PrDecision.phase_name/1)
  end

  defp code_list(atoms), do: Enum.map_join(atoms, ", ", &"`#{&1}`")

  defp table(header, rows), do: Enum.join([row(header), row(Enum.map(header, fn _cell -> "---" end)) | rows], "\n")

  defp row(cells), do: "| " <> Enum.join(cells, " | ") <> " |"
end
