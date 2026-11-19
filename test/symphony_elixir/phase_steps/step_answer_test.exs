defmodule SymphonyElixir.PhaseSteps.StepAnswerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PhaseSteps.StepAnswer
  alias SymphonyElixir.TicketEvents.Types

  defp valid!(answer) do
    payload = %{step_id: "s", title: "S", mode: "orchestrated", outcome: "passed", answer: answer}
    assert {:ok, %{answer: ^answer}} = Types.validate("step.completed", payload, :machine, nil)
  end

  describe "fields/1" do
    test "gives a label and a text value per key: scalars as text, lists one per line, nested maps as key: value lines" do
      answer = %{
        "layout" => "two columns",
        "column_count" => 2,
        "wide" => true,
        "files" => ["a.ex", "b.ex"],
        "checks" => [%{"name" => "unit", "ok" => true}, ["x", "y"], 3],
        "limits" => %{"max" => 5, "inner" => %{"deep" => "yes"}, "tags" => ["a", "b"]},
        "missing" => nil,
        "empty_list" => [],
        "empty_map" => %{},
        "blank" => "  ",
        "mixed" => {:tuple}
      }

      fields = Map.new(StepAnswer.fields(answer), &{&1.label, &1.value})

      assert fields["layout"] == "two columns"
      assert fields["column count"] == "2"
      assert fields["wide"] == "true"
      assert fields["files"] == "a.ex\nb.ex"
      assert fields["checks"] == "name: unit, ok: true\nx, y\n3"
      assert fields["limits"] == "inner.deep: yes\nmax: 5\ntags: a, b"
      assert fields["missing"] == "none"
      assert fields["empty list"] == "none"
      assert fields["empty map"] == "none"
      assert fields["blank"] == "none"
      assert fields["mixed"] == "{:tuple}"
      valid!(StepAnswer.fields(answer))
    end

    test "keeps the answer's key order, at most 12 entries, labels of 60 and values of 1500 characters" do
      many = Map.new(1..15, &{"k#{String.pad_leading("#{&1}", 2, "0")}", "v"})
      assert StepAnswer.fields(many) |> Enum.map(& &1.label) == for(n <- 1..12, do: "k#{String.pad_leading("#{n}", 2, "0")}")

      [entry] = StepAnswer.fields(%{String.duplicate("a_", 60) => String.duplicate("v", 4_000)})
      assert String.length(entry.label) == 60 and String.ends_with?(entry.label, "…")
      assert String.length(entry.value) == 1_500
      valid!([entry])

      assert StepAnswer.fields(%{"" => "x", :atom_key => "y"}) |> Enum.sort_by(& &1.label) == [%{label: "answer", value: "x"}, %{label: "atom key", value: "y"}]
      assert StepAnswer.fields(%{}) == []
    end
  end

  test "reason/1 is the failure's why, cut to 300 characters and never blank" do
    assert StepAnswer.reason(" refused twice ") == "refused twice"
    assert String.length(StepAnswer.reason(String.duplicate("r", 500))) == 300
    assert StepAnswer.reason("  ") == "none"
    assert StepAnswer.reason(nil) == "none"
    assert StepAnswer.reason(:oops) == "oops"
  end
end
