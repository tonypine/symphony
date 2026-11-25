defmodule SymphonyElixir.QaAgent.StepPayloadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaAgent.StepPayload
  alias SymphonyElixir.TicketEvents.Types

  defp valid!(payload) do
    base = %{step_id: "s", title: "S", mode: "orchestrated", outcome: "passed"}
    assert {:ok, _} = Types.validate("step.completed", Map.merge(base, payload), :machine, nil)
  end

  describe "result/1" do
    test "keeps the status, expected and actual, cut to 1500 characters and never blank" do
      assert StepPayload.result(%{"status" => "pass", "expected" => "a", "actual" => "b"}) == %{status: "pass", expected: "a", actual: "b"}
      assert %{expected: "not given", actual: "not given"} = StepPayload.result(%{"status" => "blocked", "expected" => "  ", "actual" => nil})
      assert %{expected: "7", actual: ~s({"a":1})} = StepPayload.result(%{"status" => "fail", "expected" => 7, "actual" => %{"a" => 1}})

      long = StepPayload.result(%{"status" => "fail", "expected" => String.duplicate("e", 4_000), "actual" => "ok"})
      assert String.length(long.expected) == 1_500 and String.ends_with?(long.expected, "…")
      valid!(%{result: long})

      assert StepPayload.result(%{"expected" => "no status"}) == nil
      assert StepPayload.result(%{"status" => 3}) == nil
    end
  end

  describe "results/1" do
    test "keeps one result per walkthrough step of a grouped walk, each with its step, at most 20" do
      results = [
        %{"step" => 1, "status" => "pass", "expected" => "a", "actual" => "a", "details" => "d", "evidence" => []},
        %{"step" => 2, "status" => "fail", "expected" => "b", "actual" => "c"}
      ]

      assert StepPayload.results(results) == [
               %{step: 1, status: "pass", expected: "a", actual: "a"},
               %{step: 2, status: "fail", expected: "b", actual: "c"}
             ]

      many = for step <- 1..25, do: %{"step" => step, "status" => "pass", "expected" => String.duplicate("e", 4_000), "actual" => "ok"}
      assert length(StepPayload.results(many)) == 20
      valid!(%{results: StepPayload.results(many)})
    end
  end

  describe "plan/2" do
    test "maps each walk brief and gallery entry to a check, and the skips" do
      answer = %{
        "needs_app" => false,
        "walk" => [
          %{"step" => 1, "where" => "Settings", "do" => "Open it", "expect" => "It shows"},
          %{"step" => "2", "expect" => "Menu"},
          %{"where" => "The menu"},
          %{},
          "not a brief"
        ],
        "gallery" => [%{"entry" => "button", "variations" => ["primary", "danger"]}, %{"entry" => "chip", "why" => "changed"}, "card", %{}],
        "notes" => "Careful."
      }

      skips = [%{title: "Wide pass", why: "nothing on screen"}]
      plan = StepPayload.plan(answer, skips)

      assert plan.checks == [
               %{title: "Step 1: Settings", expect: "It shows"},
               %{title: "Step 2", expect: "Menu"},
               %{title: "The menu", expect: "not given"},
               %{title: "Check", expect: "not given"},
               %{title: "Gallery: button", expect: "primary, danger"},
               %{title: "Gallery: chip", expect: "changed"},
               %{title: "Gallery: card", expect: "not given"},
               %{title: "Gallery: ", expect: "not given"}
             ]

      assert plan.skips == skips
      assert plan.summary =~ "QA plan. Needs the app: no."
      assert plan.summary =~ "- Step 1: Settings; Open it; expect It shows"
      assert plan.summary =~ "Notes: Careful."
      valid!(%{plan: plan})
    end

    test "an empty plan and an oversized one stay within the bounds" do
      empty = StepPayload.plan(%{}, [])
      assert %{checks: [], skips: [], summary: "QA plan. Needs the app: no.\nWalk: nothing.\nGallery: nothing.\nNotes: "} = empty

      walk = for n <- 1..60, do: %{"step" => n, "where" => String.duplicate("w", 300), "expect" => String.duplicate("x", 900)}
      big = StepPayload.plan(%{"needs_app" => true, "walk" => walk, "notes" => String.duplicate("n", 5_000)}, [%{title: String.duplicate("t", 300), why: String.duplicate("y", 900)}])

      assert length(big.checks) == 40
      assert Enum.all?(big.checks, &(String.length(&1.title) <= 120 and String.length(&1.expect) <= 400))
      assert String.length(big.summary) == 600
      assert [%{title: title, why: why}] = big.skips
      assert String.length(title) == 120 and String.length(why) == 400
      valid!(%{plan: big})
    end
  end

  describe "recheck/1" do
    test "gives one entry per brief: a short title, each instruction on its own, expect and design" do
      briefs = [
        %{"step" => 2, "where" => "Page 2, scrolled", "do" => "1. Scroll down\n- Click the row\n\n  \n* Look", "expect" => "Row 9 shows", "design" => " Screen 3 "},
        %{"where" => "The menu", "do" => ["Open it", ["Close it"], 5], "expect" => nil, "design" => "  "},
        %{"do" => 12},
        "not a brief"
      ]

      assert StepPayload.recheck(briefs) == [
               %{title: "Step 2: Page 2, scrolled", do: ["Scroll down", "Click the row", "Look"], expect: "Row 9 shows", design: "Screen 3"},
               %{title: "The menu", do: ["Open it", "Close it"], expect: "not given"},
               %{title: "Check", do: [], expect: "not given"}
             ]

      valid!(%{recheck: StepPayload.recheck(briefs)})
    end

    test "cuts each string, then drops whole trailing briefs, and trims what is left" do
      long = %{
        "step" => 1,
        "where" => String.duplicate("w", 300),
        "do" => String.duplicate("d\n", 30) <> String.duplicate("z", 900),
        "expect" => String.duplicate("e", 4_000),
        "design" => String.duplicate("g", 2_000)
      }

      [only] = StepPayload.recheck([long])
      assert String.length(only.title) == 120 and length(only.do) == 12 and String.length(only.expect) == 1_500 and String.length(only.design) == 600
      valid!(%{recheck: [only]})

      three = StepPayload.recheck([long, %{long | "step" => 2}, %{long | "step" => 3}])
      assert Enum.map(three, &(&1.title =~ ~r/\AStep [12]: w/)) == [true, true]
      valid!(%{recheck: three})

      # One brief that alone passes the size is trimmed, not dropped.
      heavy = %{long | "do" => Enum.map(1..12, fn _n -> String.duplicate("i", 400) end)}
      assert [trimmed] = StepPayload.recheck([heavy])
      assert length(trimmed.do) == 3 and Enum.all?(trimmed.do, &(String.length(&1) <= 100))
      assert String.length(trimmed.expect) <= 600 and String.length(trimmed.design) <= 200
      valid!(%{recheck: [trimmed]})

      assert [plain] = StepPayload.recheck([Map.delete(heavy, "design")])
      refute Map.has_key?(plain, :design)
    end
  end

  describe "verdict_summary/1" do
    test "is the review's summary cut, or nil when there is none" do
      assert StepPayload.verdict_summary(" Every step behaved. ") == "Every step behaved."
      assert String.length(StepPayload.verdict_summary(String.duplicate("s", 700))) == 600
      assert StepPayload.verdict_summary("  ") == nil
      assert StepPayload.verdict_summary(nil) == nil
    end
  end

  test "reason/1 cuts to 300 characters and is never blank" do
    assert StepPayload.reason("no answer") == "no answer"
    assert String.length(StepPayload.reason(String.duplicate("r", 500))) == 300
    assert StepPayload.reason("") == "none"
    valid!(%{outcome: "failed", returns_to: "review", reason: StepPayload.reason(String.duplicate("r", 500))})
  end
end
