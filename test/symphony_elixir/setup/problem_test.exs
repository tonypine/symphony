defmodule SymphonyElixir.Setup.ProblemTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Setup.Problem

  test "a problem carries the fields the app reads, with defaults for the optional ones" do
    problem = Problem.new(id: "check:subject", severity: :error, category: :teams, title: "Title", consequence: "What breaks.")

    assert problem == %{
             id: "check:subject",
             severity: "error",
             category: "teams",
             title: "Title",
             consequence: "What breaks.",
             repos: [],
             tickets: [],
             details: [],
             fix: nil
           }
  end

  test "details drop the lines with no value" do
    problem =
      Problem.new(
        id: "x",
        severity: :warning,
        category: :labels,
        title: "T",
        consequence: "C",
        repos: ["app"],
        tickets: [%{identifier: "TP-1", url: "https://linear.app/t/issue/TP-1"}],
        details: [Key: "a.b", Line: nil, Count: 3]
      )

    assert problem.details == [%{label: "Key", value: "a.b"}, %{label: "Count", value: "3"}]
    assert problem.tickets == [%{identifier: "TP-1", url: "https://linear.app/t/issue/TP-1"}]
  end

  test "the three kinds of fix" do
    assert Problem.config_edit("issues.states.qa", :set, "QA") == %{kind: "config_edit", path: "issues.states.qa", action: "set", value: "QA"}
    assert Problem.linear("create_label", "TP", "plan") == %{kind: "linear", action: "create_label", team: "TP", name: "plan", type: nil}
    assert Problem.linear("create_state", "TP", "QA", "started").type == "started"
    assert Problem.open(:linear, "https://linear.app") == %{kind: "open", target: "linear", url: "https://linear.app"}
  end

  test "an unknown severity, category, edit action or target raises" do
    attrs = [id: "x", severity: :error, category: :keys, title: "T", consequence: "C"]

    assert_raise ArgumentError, ~r/severity :fatal/, fn -> Problem.new(Keyword.put(attrs, :severity, :fatal)) end
    assert_raise ArgumentError, ~r/category :misc/, fn -> Problem.new(Keyword.put(attrs, :category, :misc)) end
    assert_raise ArgumentError, ~r/action :rename/, fn -> Problem.config_edit("a", :rename) end
    assert_raise ArgumentError, ~r/target :finder/, fn -> Problem.open(:finder) end
  end
end
