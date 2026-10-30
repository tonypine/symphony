defmodule SymphonyElixir.TicketEvents.SummaryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TicketEvents.{Event, Summary, Types}

  @long String.duplicate("word ", 100)
  @transcript String.duplicate("ab", 32)
  @run_ended %{run_id: "run-3", run_kind: "rework", run_number: 3, exit: "handoff", transcript: @transcript}
             |> Map.merge(%{duration_ms: 1_260_000, tokens: 13_400_000})

  # One fixture per catalog type: the event's type, payload and artifacts, then the summary it
  # renders.
  @fixtures [
    {"phase.entered", %{to: "QA", from: "Code Review", via: "verdict", reason: "Code Review approved the head"}, [],
     %{title: "Entered QA from Code Review", detail: "Code Review approved the head · via verdict"}},
    {"hold.set", %{kind: "blocked", reason: "Waiting on TP-12"}, [], %{title: "Blocked hold set", detail: "Waiting on TP-12"}},
    {"hold.cleared", %{kind: "blocked", by: "TP-12 done"}, [], %{title: "Blocked hold cleared", detail: "by TP-12 done"}},
    {"run.started", %{run_id: "run-3", run_kind: "rework", run_number: 3, state: "Rework", head: "e051234abcdef"}, [], %{title: "Rework run 3 started", detail: "in Rework · at e051234"}},
    {"run.ended", @run_ended, [@transcript], %{title: "Rework run 3 ended: handoff", detail: "21 min · 13.4M tokens · transcript"}},
    {"attempt.pushed", %{head: "e051234abcdef", attempt: 5, intent: "Render the summary on record"}, [], %{title: "Attempt 5 pushed e051234", detail: "Render the summary on record"}},
    {"verdict.recorded", %{kind: "code_review", outcome: "approve", head: "e051234abcdef"}, [], %{title: "Code Review verdict: approve", detail: "on e051234"}},
    {"decision.requested", %{title: "Close TP-612 as a duplicate", question: "Should TP-612 close as a duplicate of TP-668?"}, [],
     %{title: "Decision needed from the Director", detail: "Close TP-612 as a duplicate: Should TP-612 close as a duplicate of TP-668?"}},
    {"decision.recorded", %{answer: "Close it", request: "01REQUEST"}, [], %{title: "The Director decided", detail: "Close it"}},
    {"decision.withdrawn", %{title: "Close TP-612 as a duplicate", request: "01REQUEST"}, [], %{title: "Decision request withdrawn", detail: "Close TP-612 as a duplicate"}},
    {"person.action", %{action: "stop"}, [], %{title: "The Director stopped the run", detail: nil}},
    {"step.started", %{title: "Open the Activity tab", mode: "orchestrated"}, [], %{title: "Step started", detail: "Open the Activity tab"}},
    {"step.completed", %{title: "Open the Activity tab", mode: "delegated"}, [], %{title: "Step completed", detail: "Open the Activity tab"}},
    {"step.skipped", %{title: "Open the Activity tab", mode: "output"}, [], %{title: "Step skipped", detail: "Open the Activity tab"}},
    {"evidence", %{caption: "The Activity tab after the fix", artifacts: ["a-1", "a-2"]}, [], %{title: "Evidence recorded with 2 files", detail: "The Activity tab after the fix"}},
    {"finding.recorded",
     %{
       class: "content clipped",
       viewport: "laptop (1440×900)",
       step: "Activity with a job open",
       severity: "major",
       description: "The job row is cut at the right edge",
       evidence: ["shot-1", "shot-2"],
       class_count: 3
     }, [], %{title: "QA found content clipped at laptop (1440×900): Activity with a job open", detail: "3rd finding of this class on this ticket · 2 screenshots"}},
    {"finding.resolved", %{finding_id: "01FINDING", how: "Let the row wrap", head: "e051234"}, [], %{title: "Finding marked resolved", detail: "Let the row wrap"}},
    {"checklist.answered", %{item: "Dark mode checked?", answer: "Yes, both themes"}, [], %{title: "Checklist item answered", detail: "Dark mode checked?: Yes, both themes"}},
    {"drift.detected", %{record_phase: "Code Review", linear_phase: "Done"}, [], %{title: "Moved to Done in Linear by hand", detail: "Symphony's record holds Code Review"}},
    {"drift.reverted", %{record_phase: "Code Review", linear_phase: "Done"}, [], %{title: "Moved back to Code Review: it was moved to Done in Linear by hand", detail: nil}},
    {"drift.revert_failed", %{record_phase: "Code Review", linear_phase: "Done", error: ":timeout"}, [],
     %{title: "Could not move back to Code Review from Done", detail: ":timeout · tried again at the next read of Linear"}},
    {"note", %{text: "History before 2026-10-20 was backfilled"}, [], %{title: "Note added", detail: "History before 2026-10-20 was backfilled"}}
  ]

  defp event(type, payload, artifacts \\ []), do: %Event{type: type, payload: payload, artifacts: artifacts}
  defp render(type, payload, artifacts \\ []), do: Summary.render(event(type, payload, artifacts))

  test "a fixture per catalog type renders the documented wording" do
    assert @fixtures |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Types.catalog() |> Map.keys() |> Enum.sort()

    for {type, payload, artifacts, summary} <- @fixtures do
      assert Summary.render(event(type, payload, artifacts)) == summary, type
    end
  end

  test "an event of an unknown type renders its type and no detail" do
    assert Summary.render(event("legacy.signal", %{name: "claim"})) == %{title: "legacy.signal", detail: nil}
    assert Summary.render(%Event{type: nil}) == %{title: "unknown event", detail: nil}
    assert Summary.render(%Event{type: "note", payload: nil}) == %{title: "Note added", detail: nil}
    assert Summary.render(%{type: "legacy.signal", payload: "not a map"}) == %{title: "legacy.signal", detail: nil}
  end

  test "a verdict's reason, when it has one, opens its detail" do
    assert render("verdict.recorded", %{kind: "code_review", outcome: "approve", head: "e051234abcdef", reason: "adds 300, changes 50, removes 2,100 lines. ok"}) ==
             %{title: "Code Review verdict: approve", detail: "adds 300, changes 50, removes 2,100 lines. ok · on e051234"}
  end

  test "a known type with a missing or malformed payload renders what it can" do
    for {type, _payload, _artifacts, _summary} <- @fixtures do
      assert %{title: title} = render(type, %{})
      assert is_binary(title) and title != ""
    end

    assert render("phase.entered", %{}) == %{title: "Entered a phase", detail: nil}
    assert render("run.ended", %{run_number: -1, duration_ms: "long", tokens: "many"}) == %{title: "Run ended", detail: nil}
    assert render("attempt.pushed", %{head: " "}) == %{title: "Attempt pushed", detail: nil}
    assert render("verdict.recorded", %{}) == %{title: "Review verdict", detail: nil}
    assert render("finding.recorded", %{evidence: [1, 2]}) == %{title: "QA found a defect", detail: nil}
    assert render("evidence", %{artifacts: "a-1"}) == %{title: "Evidence recorded with 1 file", detail: nil}
    assert render("drift.reverted", %{}) == %{title: "Moved back to its phase: it was moved to another state in Linear by hand", detail: nil}
  end

  test "reads a stored record whose payload kept string keys" do
    record = %{type: "attempt.pushed", payload: %{"head" => "e051234abcdef", "attempt" => 2, "pr_url" => "https://github.com/o/r/pull/1"}}

    assert Summary.render(record) == %{title: "Attempt 2 pushed e051234", detail: "https://github.com/o/r/pull/1"}
  end

  describe "wording" do
    test "a finding's detail counts its class and screenshots when it has them, else it is the description" do
      base = %{class: "text truncated", severity: "minor", description: "The title ends mid-word"}

      assert render("finding.recorded", base).detail == "The title ends mid-word"
      assert render("finding.recorded", Map.put(base, :evidence, "shot-1")).detail == "1 screenshot"
      assert render("finding.recorded", Map.merge(base, %{class_count: 1, evidence: []})).detail == "1st finding of this class on this ticket"
      assert render("finding.recorded", Map.put(base, :class_count, 0)).detail == "The title ends mid-word"
      assert render("finding.recorded", base).title == "QA found text truncated"

      unclassified = %{base | class: "unclassified"} |> Map.merge(%{severity: "unrated", step: "Step 2", viewport: "1400×900 pt"})
      assert render("finding.recorded", unclassified).title == "QA found a defect at 1400×900 pt: Step 2"

      ordinals = [{2, "2nd"}, {4, "4th"}, {11, "11th"}, {12, "12th"}, {13, "13th"}, {21, "21st"}, {22, "22nd"}, {23, "23rd"}, {111, "111th"}]

      for {count, ordinal} <- ordinals do
        assert render("finding.recorded", Map.put(base, :class_count, count)).detail == "#{ordinal} finding of this class on this ticket"
      end
    end

    test "an attempt's detail is its intent, else its pull request link" do
      assert render("attempt.pushed", %{head: "e051234", pr_url: "https://github.com/o/r/pull/9"}) ==
               %{title: "Attempt pushed e051234", detail: "https://github.com/o/r/pull/9"}

      assert render("attempt.pushed", %{head: "e051234"}).detail == nil
    end

    test "a run's detail reads its duration, tokens and transcript" do
      ended = fn payload, artifacts -> render("run.ended", Map.merge(%{run_id: "r", exit: "handoff"}, payload), artifacts) end

      assert ended.(%{}, []) == %{title: "Run ended: handoff", detail: nil}
      assert ended.(%{run_kind: "qa", duration_ms: 45_500, tokens: 999}, ["artifact-1"]).detail == "45 s · 999 tokens"
      assert ended.(%{run_kind: "qa"}, []).title == "QA run ended: handoff"
      assert ended.(%{run_kind: "ci_fix", run_number: 1}, []).title == "CI Fix run 1 ended: handoff"
      assert ended.(%{run_kind: "review_feedback"}, []).title == "Review Feedback run ended: handoff"
      assert ended.(%{duration_ms: 3_600_000, tokens: 12_500}, []).detail == "1 h · 12.5K tokens"
      assert ended.(%{duration_ms: 5_400_000, tokens: 2_000_000}, []).detail == "1 h 30 min · 2M tokens"
      assert ended.(%{tokens: %{total_tokens: 850_000, input_tokens: 800_000}}, []).detail == "850K tokens"
      assert ended.(%{tokens: %{"total_tokens" => 1_000}}, []).detail == "1K tokens"
      # The transcript is the one the payload names: an artifact id is a sha256, never "transcript…".
      assert ended.(%{transcript: @transcript}, [@transcript]).detail == "transcript"
      assert ended.(%{duration_ms: 45_500, transcript: @transcript}, [@transcript]).detail == "45 s · transcript"
      assert ended.(%{}, [@transcript]).detail == nil
    end

    test "a run start without its kind, number, state or head" do
      assert render("run.started", %{run_id: "r", run_kind: "implementation"}) == %{title: "Implementation run started", detail: nil}
    end

    test "a decision reads as asked, then answered or withdrawn" do
      assert render("decision.requested", %{question: "Ship it?"}).detail == "Ship it?"
      assert render("decision.requested", %{}).detail == nil
      assert render("decision.recorded", %{answer: "Yes"}) == %{title: "The Director ruled", detail: "Yes"}
    end

    test "each person action" do
      assert render("person.action", %{action: "move", to: "Rework", from: "QA"}) == %{title: "The Director moved the ticket to Rework", detail: "from QA"}
      assert render("person.action", %{action: "move", move: "backlog"}).title == "The Director moved the ticket to backlog"
      assert render("person.action", %{action: "move"}).title == "The Director moved the ticket"
      assert render("person.action", %{action: "force"}).title == "The Director forced a dispatch"
      assert render("person.action", %{action: "unblock"}).title == "The Director unblocked the ticket"
      assert render("person.action", %{action: "restart"}).title == "The Director restarted the ticket"
      assert render("person.action", %{action: "decide"}).title == "The Director acted: decide"
      assert render("person.action", %{}).title == "The Director acted"
    end

    test "a checklist answer and an evidence without files" do
      assert render("checklist.answered", %{answer: "Yes"}).detail == "Yes"
      assert render("evidence", %{caption: "After"}) == %{title: "Evidence recorded", detail: "After"}
    end
  end

  describe "bounds" do
    test "agent-supplied strings appear only in the detail, one line, cut at 200 characters with an ellipsis" do
      for {type, payload} <- [
            {"decision.requested", %{title: @long, question: @long}},
            {"decision.recorded", %{answer: @long}},
            {"decision.withdrawn", %{title: @long}},
            {"step.started", %{title: @long, mode: "orchestrated"}},
            {"evidence", %{caption: @long}},
            {"finding.resolved", %{finding_id: "f", how: @long}},
            {"checklist.answered", %{item: @long, answer: @long}},
            {"note", %{text: @long}},
            {"attempt.pushed", %{head: "e051234", intent: @long}}
          ] do
        %{title: title, detail: detail} = render(type, payload)

        refute title =~ "word", type
        assert String.length(detail) == 200, type
        assert String.ends_with?(detail, "word…"), type
      end

      assert render("note", %{text: "first line\n\n  second\tline  "}).detail == "first line second line"
    end

    test "titles are at most 120 characters" do
      %{title: title, detail: detail} =
        render("finding.recorded", %{class: String.duplicate("c", 100), viewport: String.duplicate("v", 100), step: "s", description: "d"})

      assert String.length(title) == 120
      assert String.ends_with?(title, "v…")
      assert detail == "d"

      for {type, payload, artifacts, _summary} <- @fixtures do
        assert String.length(Summary.render(event(type, payload, artifacts)).title) <= 120
      end
    end
  end
end
