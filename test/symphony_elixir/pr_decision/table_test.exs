defmodule SymphonyElixir.PrDecision.TableTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PrDecision
  alias SymphonyElixir.PrDecision.Table

  test "docs/pr-ci-decisions.md matches what mix pr_decision.table writes" do
    document = File.read!(Table.path())
    assert Table.update(document) == document, "docs/pr-ci-decisions.md is out of date: run mix pr_decision.table"
  end

  test "lists every rule in precedence order, every fact and the waiting actions" do
    generated = Table.generated()
    rows = for line <- String.split(generated, "\n"), [_, id] <- [Regex.run(~r/^\| (R\d+a?) \|/, line)], do: id

    assert rows == Enum.map(PrDecision.rules(), & &1.id)
    assert generated =~ "| R14a | Code Review, QA, Rework, CI Fix, Merging |"
    assert generated =~ "| R1 | all |"
    assert generated =~ "| `ahead` | empty, not empty | `mergeable` is `dirty` or `behind` |"
    assert generated =~ "| `rerun_done` | `false`, `true` | `ci` is `red` and `red_kind` is `failure` |"
    assert generated =~ "| `phase` | `in_progress`, `code_review`, `qa`, `rework`, `ci_fix`, `merging` | always |"
    assert generated =~ "`wait`, `wait_for_competitors`, `file_fix_ticket`, `decision`"
  end

  test "update/1 keeps the prose around the generated part and replaces only that part" do
    stale = String.replace(Table.render(), "| R29 |", "| R99 |")
    document = "# Title\n\nProse before.\n\n" <> generated_part(stale) <> "\n\n## Competing PRs\n\nProse after.\n"

    updated = Table.update(document)
    assert updated == "# Title\n\nProse before.\n\n" <> Table.generated() <> "\n\n## Competing PRs\n\nProse after.\n"
  end

  test "update/1 writes a whole document when there is no generated part" do
    assert Table.update("") == Table.render()
    assert Table.update("hand-written, no markers") == Table.render()
    assert Table.render() =~ ~r/\A# PR and CI decisions\n/
  end

  defp generated_part(document) do
    [_, rest] = String.split(document, "<!-- BEGIN", parts: 2)
    [middle, _] = String.split(rest, "<!-- END mix pr_decision.table -->", parts: 2)
    "<!-- BEGIN" <> middle <> "<!-- END mix pr_decision.table -->"
  end
end
