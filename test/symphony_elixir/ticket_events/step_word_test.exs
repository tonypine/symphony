defmodule SymphonyElixir.TicketEvents.StepWordTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TicketEvents.StepWord

  test "a QA check that ran is drawn with what it judged" do
    assert StepWord.word(%{outcome: "passed", result: %{status: "fail"}}) == "failed"
    assert StepWord.word(%{outcome: "passed", result: %{status: "blocked"}}) == "blocked"
    assert StepWord.word(%{outcome: "passed", result: %{status: "pass"}}) == "passed"
    assert StepWord.word(%{"outcome" => "passed", "result" => %{"status" => "fail"}}) == "failed"
  end

  test "a walk that judged several steps in one session is drawn with its worst judgement" do
    assert StepWord.word(%{outcome: "passed", results: [%{status: "pass"}, %{status: "fail"}, %{status: "blocked"}]}) == "failed"
    assert StepWord.word(%{outcome: "passed", results: [%{status: "pass"}, %{status: "blocked"}]}) == "blocked"
    assert StepWord.word(%{"outcome" => "passed", "results" => [%{"status" => "pass"}, %{"status" => "pass"}]}) == "passed"
    assert StepWord.word(%{outcome: "passed", results: [%{status: "pass"}, %{status: "plan_mismatch"}]}) == "passed"
    assert StepWord.word(%{outcome: "passed", results: []}) == "passed"
  end

  test "any other step keeps its outcome" do
    assert StepWord.word(%{outcome: "passed"}) == "passed"
    assert StepWord.word(%{outcome: "passed", result: "fail"}) == "passed"
    assert StepWord.word(%{outcome: "passed", result: %{status: "plan_mismatch"}}) == "passed"
    assert StepWord.word(%{outcome: "failed", result: %{status: "pass"}}) == "failed"
    assert StepWord.word(%{outcome: "skipped", result: %{status: "fail"}}) == "skipped"
    assert StepWord.word(%{outcome: "paused"}) == "paused"
    assert StepWord.word(%{}) == nil
  end
end
