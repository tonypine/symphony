defmodule SymphonyElixir.TicketEvents.VerdictFactsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{QaAgent, ReviewAgent, TicketSignals, TicketState}
  alias SymphonyElixir.TicketEvents.{Event, Types, VerdictFacts}

  @finding %{
    "summary" => "Handle the empty list.",
    "file" => "lib/app.ex",
    "line_range" => "12-15",
    "quoted_snippet" => "def run([]), do: :ok",
    "suggested_fix" => "Return an error.",
    "decision" => "d2"
  }

  defp event(payload), do: %Event{type: "verdict.recorded", actor: %{kind: :machine}, payload: payload, at: ~U[2026-11-25 12:00:00Z]}

  # The payload `TicketSignals.record_verdict/7` records, checked against the catalog as the store does.
  defp recorded(kind, outcome, opts) do
    {"verdict.recorded", payload, _opts} = TicketSignals.verdict_event(kind, outcome, "abc1234", opts)
    assert {:ok, validated} = Types.validate("verdict.recorded", payload, :machine, nil)
    validated
  end

  describe "a code review's verdict" do
    test "keeps every part the reviewer gave as typed fields, each finding with its file and line range" do
      {:ok, result} =
        ReviewAgent.Verdict.from_map(%{
          "verdict" => "request_changes",
          "findings" => [@finding],
          "comments" => ["A note."],
          "unread_files" => ["lib/b.ex"]
        })

      payload = recorded("code_review", "request_changes", reason: "Handle it.", facts: VerdictFacts.review(result), details: %{findings_count: 1})

      assert payload == %{
               kind: "code_review",
               outcome: "request_changes",
               head: "abc1234",
               reason: "Handle it.",
               details: %{findings_count: 1},
               findings: [
                 %{
                   summary: "Handle the empty list.",
                   file: "lib/app.ex",
                   line_range: %{start: 12, end: 15},
                   quoted_snippet: "def run([]), do: :ok",
                   suggested_fix: "Return an error.",
                   decision: "D2"
                 }
               ],
               comments: ["A note."],
               unread_files: ["lib/b.ex"]
             }

      assert VerdictFacts.findings(payload) == payload.findings
    end

    test "marks a finding with whether its lines changed since the last review" do
      finding = %{summary: "s", file: "f", line_range: {1, 2}, quoted_snippet: "q", suggested_fix: "x", since_last_review: :unchanged}

      assert %{findings: [%{since_last_review: "unchanged"}]} = payload = recorded("code_review", "request_changes", facts: VerdictFacts.review(%{findings: [finding]}))
      assert [%{since_last_review: "unchanged", line_range: %{start: 1, end: 2}}] = VerdictFacts.findings(payload)
    end

    test "an approval with nothing said carries no typed field" do
      assert VerdictFacts.review(%{verdict: :approve, findings: [], comments: []}) == %{}
      assert VerdictFacts.review(nil) == %{}
      assert recorded("code_review", "approve", facts: %{}) == %{kind: "code_review", outcome: "approve", head: "abc1234"}
    end
  end

  describe "QA's verdict" do
    test "keeps its summary, steps and findings as typed fields" do
      {:ok, outcome} =
        QaAgent.Verdict.from_map(%{
          "verdict" => "fail",
          "summary" => "Clipped.",
          "steps" => [
            %{"name" => "Epic row", "status" => "fail", "checklist" => true, "gap" => "Clipped", "defect" => "clip", "blocked_by" => ["TP-1"]}
          ],
          "findings" => [%{"actual" => "half a row", "viewport" => "1400×900 pt"}]
        })

      payload = recorded("qa", "fail", facts: VerdictFacts.qa(outcome))

      assert payload.summary == "Clipped."
      assert payload.steps == [%{name: "Epic row", status: "fail", checklist: true, gap: "Clipped", defect: "clip", blocked_by: ["TP-1"]}]
      assert payload.qa_findings == [%{line: "At 1400×900 pt: Actual: half a row.", viewport: "1400×900 pt", actual: "half a row"}]
      assert VerdictFacts.qa_findings(payload) == payload.qa_findings
    end

    test "a verdict with nothing said, or no verdict, carries no typed field" do
      assert VerdictFacts.qa(%{verdict: :pass, summary: "", steps: [], finding_details: []}) == %{}
      assert VerdictFacts.qa(%{verdict: :blocked, finding_details: [%{line: " "}, :junk]}) == %{}
      assert VerdictFacts.qa(nil) == %{}
      assert VerdictFacts.qa_findings(nil) == []
      assert VerdictFacts.qa_findings(%{"qa_findings" => [%{"line" => "Read back.", "evidence" => ["a.png", 3]}]}) == [%{line: "Read back.", evidence: ["a.png"]}]
    end
  end

  describe "a verdict stored before its findings were typed" do
    test "still reads, its findings taken from the open details it kept" do
      old_round =
        event(%{
          kind: "code_review",
          outcome: "request_changes",
          head: "old1234",
          details: %{
            findings_count: 2,
            previous_head: "older12",
            missed_earlier: 1,
            missed_findings: [%{summary: "Was there before.", file: "lib.ex", line_range: [2, 3]}]
          }
        })

      deepened = event(%{kind: "code_review", outcome: "request_changes", details: %{"findings" => [%{"summary" => "s", "file" => "f", "line_range" => %{"start" => 4, "end" => 5}}]}})
      plain = event(%{kind: "qa", outcome: "pass", details: "not a map"})

      assert [plain_verdict, deepened_verdict, round_verdict] = TicketState.verdicts_in([old_round, deepened, plain])

      assert %{outcome: "request_changes", head_sha: "old1234", details: %{findings_count: 2, missed_earlier: 1}} = round_verdict
      assert round_verdict.findings == [%{summary: "Was there before.", file: "lib.ex", line_range: %{start: 2, end: 3}}]
      assert deepened_verdict.findings == [%{summary: "s", file: "f", line_range: %{start: 4, end: 5}}]
      assert %{kind: "qa", details: %{}, findings: [], qa_findings: []} = plain_verdict
    end

    test "reads nothing from a payload that is not a verdict's" do
      assert VerdictFacts.findings(nil) == []
      assert VerdictFacts.findings(%{details: %{findings: "a sentence"}}) == []
      assert VerdictFacts.findings(%{findings: [%{summary: "s", line_range: nil, since_last_review: "later"}]}) == [%{summary: "s"}]
    end
  end
end
