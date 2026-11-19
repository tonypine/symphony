defmodule SymphonyElixir.TicketEvents.SummaryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TicketEvents.{Event, Summary, Types}

  @long String.duplicate("word ", 100)
  @transcript String.duplicate("ab", 32)
  @run_ended %{run_id: "run-3", run_kind: "rework", run_number: 3, exit: "handoff", transcript: @transcript}
             |> Map.merge(%{duration_ms: 1_260_000, tokens: 13_400_000, model: "claude-opus-5-5"})

  # One fixture per catalog type: the event's type, payload and artifacts, then the summary it
  # renders.
  @fixtures [
    {"phase.entered", %{to: "QA", from: "Code Review", via: "verdict", reason: "Code Review approved the head"}, [], %{title: "Entered QA from Code Review", detail: "Code Review approved the head"}},
    {"hold.set", %{kind: "blocked", reason: "Waiting on TP-12"}, [], %{title: "Blocked hold set", detail: "Waiting on TP-12"}},
    {"hold.cleared", %{kind: "blocked", by: "TP-12 done"}, [], %{title: "Blocked hold cleared", detail: "by TP-12 done"}},
    {"run.started", %{run_id: "run-3", run_kind: "rework", run_number: 3, state: "Rework", head: "e051234abcdef", model: "claude-opus-5-5", effort: "high"}, [],
     %{title: "Rework run 3 started", detail: "Claude Opus 5.5 · in Rework · at e051234"}},
    {"run.started_by_person", %{run_id: "run-3", run_kind: "implementation", run_number: 1, by: "the Director", note: "customer demo"}, [],
     %{title: "Implementation run 1 started by the Director", detail: "customer demo"}},
    {"run.ended", @run_ended, [@transcript], %{title: "Rework run 3 ended: handoff", detail: "Claude Opus 5.5 · 21 min · 13.4M tokens · transcript"}},
    {"attempt.pushed", %{head: "e051234abcdef", attempt: 5, intent: "Render the summary on record"}, [], %{title: "Attempt 5 pushed e051234", detail: "Render the summary on record"}},
    {"verdict.recorded", %{kind: "code_review", outcome: "approve", head: "e051234abcdef"}, [], %{title: "Code Review verdict: approve", detail: "on e051234"}},
    {"decision.requested", %{title: "Close TP-612 as a duplicate", question: "Should TP-612 close as a duplicate of TP-668?"}, [],
     %{title: "Decision needed from the Director", detail: "Close TP-612 as a duplicate: Should TP-612 close as a duplicate of TP-668?"}},
    {"decision.recorded", %{answer: "Close it", request: "01REQUEST"}, [], %{title: "The Director decided", detail: "Close it"}},
    {"decision.withdrawn", %{title: "Close TP-612 as a duplicate", request: "01REQUEST"}, [], %{title: "Decision request withdrawn", detail: "Close TP-612 as a duplicate"}},
    {"person.action", %{action: "stop"}, [], %{title: "The Director stopped the run", detail: nil}},
    {"step.started", %{step_id: "build", title: "Build", mode: "machine", command: "mix compile --warnings-as-errors"}, [], %{title: "Build started", detail: nil}},
    {"step.completed",
     Map.merge(%{step_id: "build", title: "Build", mode: "machine"}, %{outcome: "failed", returns_to: "code", returns_to_title: "writing the code"}) |> Map.put(:duration_ms, 240_000), ["out-1"],
     %{title: "Build failed after 4 min: back to writing the code", detail: "output kept"}},
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
    {"finding.resolved", %{finding_id: "01FINDING", how: "Let the row wrap", head: "e051234abcdef"}, [], %{title: "Finding marked resolved", detail: "Let the row wrap · on e051234"}},
    {"finding.confirmed", %{finding_id: "01FINDING", resolution: "01RESOLUTION", head: "f00ba12abcdef"}, [], %{title: "QA confirmed a finding fixed", detail: "on f00ba12"}},
    {"checklist.answered", %{item: "Dark mode checked?", answer: "Yes, both themes"}, [], %{title: "Checklist item answered", detail: "Dark mode checked?: Yes, both themes"}},
    {"ticket.cancelled", %{from: "Backlog", to: "Canceled", note: "superseded"}, [], %{title: "Cancelled from Backlog", detail: "superseded"}},
    {"ticket.moved", %{from: "Backlog", to: "In Progress", note: "its work is committed"}, [], %{title: "Moved to In Progress from Backlog", detail: "its work is committed"}},
    {"drift.detected", %{record_phase: "Code Review", linear_phase: "Done"}, [], %{title: "Moved to Done in Linear by hand", detail: "Symphony's record holds Code Review"}},
    {"drift.reverted", %{record_phase: "Code Review", linear_phase: "Done"}, [], %{title: "Moved back to Code Review: it was moved to Done in Linear by hand", detail: nil}},
    {"drift.revert_failed", %{record_phase: "Code Review", linear_phase: "Done", error: ":timeout"}, [],
     %{title: "Could not move back to Code Review from Done", detail: ":timeout · tried again at the next read of Linear"}},
    {"pause.set", %{reason: "question", text: "Waiting for your answer", waits_on: %{question_id: "q-1"}}, [], %{title: "Paused: waiting for your answer", detail: nil}},
    {"pause.reason_added", %{reason: "ticket", text: "Waiting for TP-1194 to finish", waits_on: %{identifier: "TP-1194"}}, [], %{title: "Also paused: waiting for TP-1194 to finish", detail: nil}},
    {"pause.reason_cleared", %{reason: "question", text: "Waiting for your answer", waits_on: %{question_id: "q-1"}}, [], %{title: "Pause reason cleared: waiting for your answer", detail: nil}},
    {"pause.cleared", %{cleared: [%{reason: "ticket", text: "Waiting for TP-1194 to finish", waits_on: %{identifier: "TP-1194"}}]}, [],
     %{title: "Moving again", detail: "Waiting for TP-1194 to finish"}},
    {"question.asked", %{question_id: "q-1", title: "Ship TP-12 today", question: "Should TP-12 ship before the release?"}, [],
     %{title: "Asked you: Ship TP-12 today", detail: "Should TP-12 ship before the release?"}},
    {"question.answered", %{question_id: "q-1", title: "Ship TP-12 today", answer: "2", option: "Wait for the release"}, [],
     %{title: "You answered: Wait for the release", detail: "Ship TP-12 today"}},
    {"question.withdrawn", %{question_id: "q-1", title: "Ship TP-12 today", reason: "TP-12 was cancelled"}, [], %{title: "Question withdrawn: TP-12 was cancelled", detail: "Ship TP-12 today"}},
    {"question.reopened", %{question_id: "q-1", title: "Ship TP-12 today"}, [], %{title: "You took back your answer: Ship TP-12 today", detail: nil}},
    {"question.not_asked", %{title: "Who may export", question: "Who may export the report?", cap: 12}, [],
     %{title: "Not asked, the run reached its limit of questions: Who may export", detail: "Who may export the report?"}},
    {"park.backfilled", %{added: ["question", "push"], question_id: "q-1", branch: "auto/TP-1248"}, [],
     %{title: "Park brought up to date at start-up", detail: "asked you whether to run it again · pushed its work to auto/TP-1248"}},
    {"workspace.synced", %{workspace_head: "aaa1111aaaa", pr_head: "bbb2222bbbb", winner: "pull_request", action: "reset", head: "bbb2222bbbb", run_kind: "qa"}, [],
     %{title: "Workspace reset to the PR head bbb2222", detail: nil}},
    {"workspace.rebuilt", %{reason: "missing_folder", branch: "auto/TP-1", winner: "pull_request", head: "bbb2222bbbb", pr_head: "bbb2222bbbb", branch_head: "aaa1111aaaa"}, [],
     %{title: "Workspace rebuilt on the PR head bbb2222", detail: "Its workspace folder was missing"}},
    {"workspace.removed", %{reason: "age_gc"}, [], %{title: "Workspace removed", detail: "It went unused too long"}},
    {"situation.changed", %{from: "working", to: "waiting_for_ci", word: "Waiting for CI", cause: "Checks are running on PR #741."}, [],
     %{title: "Waiting for CI", detail: "Checks are running on PR #741."}},
    {"note", %{text: "History before 2026-10-20 was backfilled"}, [], %{title: "Note added", detail: "History before 2026-10-20 was backfilled"}},
    {"note.read", %{note_id: "evt-1", run_id: "run-4"}, [], %{title: "Note read by a run", detail: nil}},
    {"brief.written", %{text: "Each ticket says what it delivers.", walkthrough: "Read a ticket."}, [], %{title: "Brief written", detail: "Each ticket says what it delivers."}},
    {"conductor.update", %{junction: "after_qa_fail", text: "QA failed the login step again.", refs: ["evt_1"]}, [], %{title: "Update", detail: "QA failed the login step again."}},
    {"conductor.instructions", %{junction: "after_coding", text: "Check the empty list first."}, [], %{title: "Conductor instructions", detail: "Check the empty list first."}},
    {"conductor.steer", %{text: "Stop retrying the build; read its error first.", when: "now", trigger: "step_failed_twice"}, [],
     %{title: "Conductor steered", detail: "Stop retrying the build; read its error first."}},
    {"report.published", %{run_id: "report-1", text: "TP-1 merged."}, [], %{title: "Report published", detail: "TP-1 merged."}},
    {"rule.action", %{rule: "PR watcher R22", action: "rerun", text: "A check failed on PR #741: Symphony reran it once"}, [],
     %{title: "Reran the failed checks", detail: "A check failed on PR #741: Symphony reran it once"}},
    {"ticket.filed", %{identifier: "TP-1500", kind: "split_off", title: "Split the parser"}, [], %{title: "Split off TP-1500", detail: "Split the parser"}}
  ]

  defp event(type, payload, artifacts \\ []), do: %Event{type: type, payload: payload, artifacts: artifacts}
  defp render(type, payload, artifacts \\ []), do: Summary.render(event(type, payload, artifacts))

  test "a fixture per catalog type renders the documented wording" do
    assert @fixtures |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Types.catalog() |> Map.keys() |> Enum.sort()

    # The step fixtures are payloads the catalog accepts from Symphony.
    for {"step." <> _ = type, payload, _artifacts, _summary} <- @fixtures do
      assert {:ok, _payload} = Types.validate(type, payload, :machine, nil), type
    end

    for {type, payload, artifacts, summary} <- @fixtures do
      assert Summary.render(event(type, payload, artifacts)) == summary, type
    end
  end

  test "a rule's action says what it did, and the ticket it filed; the rule is who did it" do
    assert render("rule.action", %{rule: "CI wait", action: "paused", text: "Waiting for CI on abc1234 to finish"}) ==
             %{title: "Paused the ticket", detail: "Waiting for CI on abc1234 to finish"}

    assert render("rule.action", %{rule: "Self-heal", action: "filed_ticket", filed: "TP-1501"}) == %{title: "Filed TP-1501", detail: nil}
    assert render("rule.action", %{rule: "Self-heal", action: "filed_ticket"}).title == "Filed a fix ticket"

    for {action, words} <- [
          {"parked", "Parked the ticket"},
          {"lifted_pause", "Lifted a pause"},
          {"moved", "Moved the ticket"},
          {"updated_branch", "Updated the branch"},
          {"auto_merge", "Changed auto-merge"},
          {"asked", "Asked you"},
          {"other", "Acted"}
        ] do
      assert render("rule.action", %{rule: "Idle park", action: action}).title == words, action
    end

    assert render("rule.action", %{}).title == "Acted"
    assert render("ticket.filed", %{identifier: "TP-1502", kind: "follow_up"}) == %{title: "Follow-up TP-1502 filed", detail: nil}
    assert render("ticket.filed", %{}).title == "Split off a ticket"
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
    assert render("pause.set", %{}) == %{title: "Paused", detail: nil}
    assert render("pause.cleared", %{cleared: "all"}) == %{title: "Moving again", detail: nil}
    assert render("pause.cleared", %{cleared: [:junk, %{text: " "}]}) == %{title: "Moving again", detail: nil}
  end

  test "a free-text answer shows its first words; a question event missing its text still renders" do
    answer = "Ship it now, but only once the release notes name the new pause in plain words"
    assert render("question.answered", %{question_id: "q-1", answer: answer}).title == "You answered: Ship it now, but only once the release…"
    assert render("question.answered", %{question_id: "q-1", answer: "  Ship   it  "}).title == "You answered: Ship it"
    assert render("question.answered", %{}) == %{title: "You answered", detail: nil}
    assert render("question.asked", %{}) == %{title: "Asked you", detail: nil}
    assert render("question.withdrawn", %{}) == %{title: "Question withdrawn", detail: nil}
  end

  test "a park brought up to date reads the reason it was paused on, and a push naming no branch" do
    assert render("park.backfilled", %{added: ["releasable_reason", "push"]}) ==
             %{title: "Park brought up to date at start-up", detail: "paused it until you unblock it · pushed its work to its branch"}
  end

  test "a workspace sync names what it did, its heads left for Diagnostics" do
    heads = %{workspace_head: "aaa1111aaaa", pr_head: "bbb2222bbbb"}

    assert render("workspace.synced", Map.merge(heads, %{action: "none", head: "bbb2222bbbb"})).title == "Workspace already on the PR head bbb2222"
    assert render("workspace.synced", Map.merge(heads, %{action: "pushed", head: "aaa1111aaaa"})).title == "Workspace's unpushed head aaa1111 pushed to the PR"

    assert render("workspace.synced", Map.merge(heads, %{action: "reset_and_pushed", head: "ccc3333cccc", recorded_head: "ccc3333cccc"})) ==
             %{title: "Workspace reset to a run's unpushed head ccc3333 and pushed", detail: nil}

    assert render("workspace.synced", Map.merge(heads, %{action: "blocked", reason: "local changes (?? notes.txt)"})) ==
             %{title: "Workspace not synced: it holds local work", detail: "local changes (?? notes.txt)"}

    assert render("workspace.synced", Map.merge(heads, %{action: "failed", reason: ":boom"})).title == "Workspace could not be synced"
    assert render("workspace.synced", %{}) == %{title: "Workspace already on the PR head", detail: nil}
  end

  test "a workspace rebuild names why and the head it chose" do
    assert render("workspace.rebuilt", %{reason: "reclaim", winner: "branch", head: "aaa1111aaaa", branch_head: "aaa1111aaaa"}) ==
             %{title: "Workspace rebuilt on the branch head aaa1111", detail: "Its old workspace was reclaimed"}

    assert render("workspace.rebuilt", %{reason: "host_change", winner: "recorded", head: "ccc3333cccc", recorded_head: "ccc3333cccc"}) ==
             %{title: "Workspace rebuilt on a run's unpushed head ccc3333", detail: "Its last run was on another host"}

    assert render("workspace.rebuilt", %{reason: "missing_folder", winner: "main"}) ==
             %{title: "Workspace rebuilt from main: the ticket has no branch yet", detail: "Its workspace folder was missing"}

    assert render("workspace.rebuilt", %{reason: "stop", winner: "local", head: "ddd4444dddd", local_head: "ddd4444dddd"}) ==
             %{title: "Workspace rebuilt on its local branch head ddd4444", detail: "Its workspace was removed when its run was stopped"}

    assert render("workspace.rebuilt", %{reason: "terminal", winner: "pull_request", head: "bbb2222bbbb", pr_head: "bbb2222bbbb", orphaned_head: "eee5555eeee"}) ==
             %{
               title: "Workspace rebuilt on the PR head bbb2222",
               detail: "Its workspace was removed when it reached a terminal state · Its local work is kept aside"
             }

    assert render("workspace.rebuilt", %{reason: "cleanup", winner: "main"}).detail == "Symphony removed its workspace"

    for {reason, detail} <- [{"stop", "Its run was stopped"}, {"terminal", "The ticket reached a terminal state"}, {"cleanup", "Symphony cleaned it up"}] do
      assert render("workspace.removed", %{reason: reason}) == %{title: "Workspace removed", detail: detail}
    end
  end

  test "a pause reason's line keeps the capital of a name it opens on" do
    assert render("pause.set", %{reason: "ticket", text: "TP-12 has to finish first"}).title == "Paused: TP-12 has to finish first"
    assert render("pause.reason_added", %{reason: "environment", text: "GitHub is down"}).title == "Also paused: GitHub is down"
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
      assert Summary.render(%{event("finding.recorded", Map.put(base, :step, "Step 2"), []) | supersedes: "01RESOLUTION"}).title == "QA reopened text truncated: Step 2"

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
      assert render("person.action", %{action: "add_blocker", blocker: "TP-12"}).title == "The Director added TP-12 as a blocker"
      assert render("person.action", %{action: "remove_blocker", blocker: "TP-12"}).title == "The Director removed TP-12 as a blocker"
      assert render("person.action", %{action: "add_blocker"}).title == "The Director added a ticket as a blocker"
      assert render("person.action", %{action: "remove_blocker"}).title == "The Director removed a ticket as a blocker"
      assert render("person.action", %{action: "set_priority", from: "Low", to: "Urgent"}) |> Map.take([:title, :detail]) == %{title: "The Director set the priority to Urgent", detail: "from Low"}
      assert render("person.action", %{action: "set_priority"}).title == "The Director set the priority to another priority"
      assert render("person.action", %{action: "add_label", label: "qa:skip"}).title == "The Director added the qa:skip label"
      assert render("person.action", %{action: "remove_label", label: "plan"}).title == "The Director removed the plan label"
      assert render("person.action", %{action: "add_label"}).title == "The Director added a label"
      assert render("person.action", %{action: "decide"}).title == "The Director acted: decide"
      assert render("person.action", %{action: "set_due_date"}).title == "The Director acted: set due date"
      assert render("person.action", %{}).title == "The Director acted"
    end

    test "a checklist answer and an evidence without files" do
      assert render("checklist.answered", %{answer: "Yes"}).detail == "Yes"
      assert render("evidence", %{caption: "After"}) == %{title: "Evidence recorded", detail: "After"}
      assert render("evidence", %{caption: "Step 2", artifacts: ["a"], environment: "live"}).title == "Evidence recorded with 1 file, on the live server"
      assert render("evidence", %{caption: "Step 1", environment: "fixture"}).title == "Evidence recorded, on the fixtures"
      assert render("evidence", %{caption: "Step 1", environment: "elsewhere"}).title == "Evidence recorded"
    end
  end

  describe "a step's line" do
    @build %{step_id: "build", title: "Build", mode: "machine"}

    test "one line per outcome" do
      completed = fn attrs -> render("step.completed", Map.merge(@build, attrs)) end

      assert completed.(%{title: "Tests", outcome: "passed", duration_ms: 125_000}) == %{title: "Tests passed in 2 min", detail: nil}
      assert completed.(%{outcome: "passed"}) == %{title: "Build passed", detail: nil}
      assert completed.(%{outcome: "paused", question_id: "q-1"}) == %{title: "Paused on your answer", detail: "Build"}
      assert completed.(%{title: "Checks", outcome: "skipped", reason: "no Elixir changed"}) == %{title: "Checks skipped: no Elixir changed", detail: nil}
      assert completed.(%{outcome: "failed", returns_to: "code", duration_ms: 45_000}) == %{title: "Build failed after 45 s: back to step code", detail: nil}
      assert completed.(%{outcome: "failed"}) == %{title: "Build failed", detail: nil}
    end

    test "a delegated step's title and reason are the agent's words, so they stay in the detail" do
      delegated = %{step_id: "code", title: "Writing the code", mode: "delegated"}

      assert render("step.started", delegated) == %{title: "Step started", detail: "Writing the code"}
      assert render("step.completed", Map.put(delegated, :outcome, "passed")) == %{title: "Step passed", detail: "Writing the code"}

      assert render("step.completed", Map.merge(delegated, %{outcome: "skipped", reason: "nothing to change"})) ==
               %{title: "Step skipped", detail: "Writing the code · nothing to change"}

      assert render("step.completed", Map.merge(delegated, %{outcome: "failed", returns_to: "code", returns_to_title: "writing the code", duration_ms: 240_000})) ==
               %{title: "Step failed after 4 min", detail: "Writing the code · back to writing the code"}

      assert render("step.completed", Map.merge(delegated, %{outcome: "failed", returns_to: "code"})) ==
               %{title: "Step failed", detail: "Writing the code · back to step code"}
    end

    test "a step's own answer, failure reason and verdict summary are in its detail, never in a note" do
      completed = fn attrs -> render("step.completed", Map.merge(@build, attrs)) end

      answered = %{outcome: "passed", answer: [%{label: "layout", value: "two columns"}, %{"label" => "reason", "value" => String.duplicate("v", 400)}]}
      assert %{title: "Build passed", detail: detail} = completed.(answered)
      assert detail =~ "layout: two columns"
      assert detail =~ ~r/reason: v+…/

      result = %{status: "blocked", expected: "Rows", actual: "Empty state"}
      assert completed.(%{outcome: "passed", result: result, verdict_summary: "Blocked."}) == %{title: "Build passed", detail: "blocked · Empty state · Blocked."}
      assert completed.(%{outcome: "passed", result: %{status: "pass"}}) == %{title: "Build passed", detail: "pass"}

      assert completed.(%{outcome: "failed", returns_to: "code", reason: "refused twice"}) ==
               %{title: "Build failed: back to step code", detail: "refused twice"}

      delegated = %{step_id: "code", title: "Writing the code", mode: "delegated", outcome: "failed", returns_to: "code", reason: "no end"}
      assert render("step.completed", delegated) == %{title: "Step failed", detail: "Writing the code · back to step code · no end"}
    end

    test "a step stored before its outcome was recorded, and a stored step.skipped, still read" do
      assert render("step.completed", %{title: "Open the Activity tab", mode: "orchestrated"}) == %{title: "Open the Activity tab completed", detail: nil}
      assert render("step.completed", %{title: "Open the Activity tab", mode: "output"}) == %{title: "Step completed", detail: "Open the Activity tab"}
      assert render("step.skipped", %{title: "Open the Activity tab", mode: "output"}) == %{title: "Step skipped", detail: "Open the Activity tab"}
    end
  end

  describe "run_group/1" do
    defp run_event(seq, type, payload), do: %Event{seq: seq, type: type, payload: payload, run_id: "run-1"}

    @started %{run_id: "run-1", run_kind: "implementation", run_number: 2, state: "In Progress"}

    test "while the run is under way, its line names the step it is on" do
      started = run_event(1, "run.started", @started)
      build = run_event(2, "step.started", Map.put(@build, :command, "mix compile"))
      code = run_event(4, "step.started", %{step_id: "code", title: "Writing the code", mode: "delegated"})
      failed = run_event(3, "step.completed", Map.merge(@build, %{outcome: "failed", returns_to: "code"}))
      paused = run_event(5, "step.completed", %{step_id: "code", title: "Writing the code", mode: "delegated", outcome: "paused", question_id: "q-1"})

      assert Summary.run_group([started]) == %{title: "Implementation run 2 started", detail: "in In Progress"}
      assert Summary.run_group([started, build]) == %{title: "Implementation run 2 running: Build", detail: nil}
      # Between steps the run reads as started.
      assert Summary.run_group([started, build, failed]) == %{title: "Implementation run 2 started", detail: "in In Progress"}
      assert Summary.run_group([started, build, failed, code]) == %{title: "Implementation run 2 running a step", detail: "Writing the code"}
      assert Summary.run_group([started, build, failed, code, paused]) == %{title: "Implementation run 2 paused on your answer", detail: "Writing the code"}
    end

    test "once the run ended, its line is its end's; a run with neither reads nil" do
      started = run_event(1, "run.started", @started)
      build = run_event(2, "step.started", Map.put(@build, :command, "mix compile"))
      ended = run_event(3, "run.ended", %{run_id: "run-1", run_kind: "implementation", run_number: 2, exit: "handoff"})

      assert Summary.run_group([started, build, ended]) == %{title: "Implementation run 2 ended: handoff", detail: nil}
      assert Summary.run_group([build]) == nil
      assert Summary.run_group([]) == nil
    end
  end

  describe "run_outcome/2" do
    defp ended(exit), do: %Event{seq: 9, type: "run.ended", payload: %{run_id: "run-1", exit: exit}, run_id: "run-1"}
    defp verdict(kind, outcome), do: %Event{type: "verdict.recorded", payload: %{kind: kind, outcome: outcome}}

    test "an ended run comes out as the question it asked, else its verdict, else how it ended" do
      started = %Event{seq: 1, type: "run.started", payload: @started, run_id: "run-1"}
      paused = %Event{seq: 2, type: "step.completed", payload: %{step_id: "code", outcome: "paused", question_id: "q-1"}, run_id: "run-1"}
      passed = %Event{seq: 2, type: "step.completed", payload: %{step_id: "code", outcome: "passed"}, run_id: "run-1"}

      assert Summary.run_outcome([started], nil) == nil
      assert Summary.run_outcome([started, paused, ended("ended normally")], verdict("code_review", "approve")) == "Asked you a question"
      assert Summary.run_outcome([started, passed, ended("handoff")], verdict("code_review", "approve")) == "Approved"
      assert Summary.run_outcome([started, ended("handoff")], verdict("code_review", "rework")) == "Sent back to Rework"
      assert Summary.run_outcome([started, ended("handoff")], verdict("code_review", "block")) == "Raised a decision for you"
      assert Summary.run_outcome([started, ended("ended normally")], verdict("qa", "pass")) == "Every walkthrough step passed"
      assert Summary.run_outcome([started, ended("ended normally")], verdict("qa", "fail")) == "Sent back to Rework"
      assert Summary.run_outcome([started, ended("ended normally")], verdict("qa", "skip")) == "QA skipped"
      # A verdict the table doesn't name says nothing; the run's end does.
      assert Summary.run_outcome([started, ended("handoff")], verdict("epic_review", "pass")) == "Pushed and handed off"
      assert Summary.run_outcome([ended("handoff")], %Event{type: "verdict.recorded", payload: nil}) == "Pushed and handed off"
    end

    test "how a run ended, in a person's words" do
      outcome = &Summary.run_outcome([ended(&1)], nil)

      assert outcome.("handoff") == "Pushed and handed off"
      assert outcome.("usage limit") == "Stopped at the usage limit"
      assert outcome.("model API unreachable") == "Couldn't reach the model"
      assert outcome.("waiting for CI") == "Ended to wait for CI"
      assert outcome.("stopped: its ticket moved to Done") == "Stopped: its ticket moved to Done"
      assert outcome.("failed (exit status 1)") == "Failed"
      assert outcome.("token budget spent (12M tokens of a 10M limit)") == "Stopped: its token budget was spent"
      assert outcome.("ended normally") == nil
      assert outcome.(nil) == nil
    end
  end

  describe "bounds" do
    test "agent-supplied strings appear only in the detail, one line, cut at 200 characters with an ellipsis" do
      for {type, payload} <- [
            {"decision.requested", %{title: @long, question: @long}},
            {"decision.recorded", %{answer: @long}},
            {"decision.withdrawn", %{title: @long}},
            {"step.started", %{step_id: "s", title: @long, mode: "delegated"}},
            {"step.completed", %{step_id: "s", title: @long, mode: "delegated", outcome: "passed"}},
            {"step.completed", %{step_id: "s", title: "Looking", mode: "delegated", outcome: "skipped", reason: @long}},
            {"step.completed", %{step_id: "s", title: "Look", mode: "delegated", outcome: "failed", returns_to: "code", returns_to_title: @long}},
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

  describe "in a person's words" do
    @sha "2c8b2528430c3d0b69cca1e740b4c563dbb66c9e"
    @watcher_reason "the PR watcher (R24): Checks are running on PR [tonypine/symphony#894](https://linear.app/t/review/tp-1463-abc)'s head"
    @old_note "QA waits on the PR watcher · head #{@sha} · reason #{@watcher_reason} · status running (qa_head_not_green)"
    @rule_setter %{kind: "rule", name: "PR watcher R24"}

    # Every type the feed can emit, each with the codes, rule rows and full hashes Symphony keeps in
    # its payload.
    @coded [
      {"phase.entered", %{to: "Merging", from: "QA", via: "qa_pass", reason: "every journey verified", signal: "review verdict"}},
      {"hold.set", %{kind: "blocked", reason: "Blocked by #{@watcher_reason}"}},
      {"hold.cleared", %{kind: "blocked", by: "hold_cleared"}},
      {"run.started", %{run_id: "run_1", run_kind: "ci_fix", run_number: 2, state: "CI Fix", head: @sha, model: "claude-opus-5-5", effort: "medium"}},
      {"run.started_by_person", %{run_id: "run_1", by: "the Director", note: "see #{@sha}"}},
      {"run.ended", %{run_id: "run_1", run_kind: "pre_push_review", exit: "handoff_missing", model: "claude-opus-5-5", effort: "medium", head: @sha, unpushed_head: @sha}},
      {"attempt.pushed", %{head: @sha, attempt: 2, intent: "Push #{@sha}"}},
      {"verdict.recorded", %{kind: "code_review", outcome: "changes_requested", head: @sha, reason: "every journey verified (qa_pass)"}},
      {"decision.requested", %{title: "Ship it", question: "Ship #{@sha}?"}},
      {"decision.recorded", %{answer: "Yes", request: "req_1", key: "decision_key"}},
      {"decision.withdrawn", %{title: "Ship it", request: "req_1"}},
      {"question.asked", %{question_id: "q_1", title: "Ship it", question: "Ship it?", step: "write_code"}},
      {"question.answered", %{question_id: "q_1", answer: "Yes", scope: "ticket"}},
      {"question.withdrawn", %{question_id: "q_1", reason: "The ticket moved", cause: "ticket_moved"}},
      {"question.reopened", %{question_id: "q_1", title: "Ship it"}},
      {"question.not_asked", %{title: "Ship it", question: "Ship it?", cap: 5}},
      {"person.action", %{action: "add_blocker", blocker: "TP-12"}},
      {"step.started", %{step_id: "pre_push", title: "Pre-push checks", mode: "machine", command: "mix test test/foo_bar_test.exs"}},
      {"step.completed", %{step_id: "pre_push", title: "Pre-push checks", mode: "machine", outcome: "failed", returns_to: "write_code"}},
      {"evidence", %{caption: "After the fix on #{@sha}", environment: "live", status: "pass"}},
      {"finding.recorded", %{class: "visual_mismatch", severity: "major", description: "Cut at the edge", step: "Step 2"}},
      {"finding.resolved", %{finding_id: "f_1", how: "Wrapped it", head: @sha}},
      {"finding.confirmed", %{finding_id: "f_1", resolution: "r_1", head: @sha}},
      {"checklist.answered", %{item: "Dark mode", answer: "Yes"}},
      {"ticket.cancelled", %{from: "Backlog", to: "Canceled"}},
      {"ticket.moved", %{from: "Backlog", to: "Todo"}},
      {"drift.detected", %{record_phase: "QA", linear_phase: "Done"}},
      {"drift.reverted", %{record_phase: "QA", linear_phase: "Done"}},
      {"drift.revert_failed", %{record_phase: "QA", linear_phase: "Done", error: "the PR watcher (R24) timed out (linear_timeout)"}},
      {"pause.set", %{reason: "ticket", text: "Waiting for TP-1 to finish", set_by: @rule_setter}},
      {"pause.reason_added", %{reason: "build", text: "Waiting for the build", set_by: @rule_setter}},
      {"pause.reason_cleared", %{reason: "build", text: "Waiting for the build", by: @rule_setter}},
      {"pause.cleared", %{cleared: [%{reason: "build", text: "Waiting for the build of #{@sha}"}], by: @rule_setter}},
      {"situation.changed", %{to: "waiting_for_ci", from: "working", word: "Waiting for CI", cause: "Checks are running (qa_head_not_green)"}},
      {"park.backfilled", %{added: ["releasable_reason", "push"], branch: "auto/TP-1"}},
      {"workspace.synced", %{workspace_head: @sha, pr_head: @sha, winner: "equal", action: "none", head: @sha, recorded_head: @sha}},
      {"workspace.rebuilt", %{reason: "missing_folder", branch: "auto/TP-1", winner: "recorded", head: @sha, recorded_head: @sha, orphaned_head: @sha}},
      {"workspace.removed", %{reason: "age_gc"}},
      {"rule.action", %{rule: "PR watcher R29", action: "auto_merge", text: "#{@watcher_reason}: auto-merge on for #{@sha}", head: @sha}},
      {"ticket.filed", %{identifier: "TP-1500", kind: "follow_up", title: "Split the parser"}},
      {"brief.written", %{text: "Plain words.", walkthrough: "Read it."}},
      {"conductor.update", %{junction: "before_merge", text: "QA passed every step; it merges next."}},
      {"conductor.instructions", %{junction: "after_rework", text: "Walk the empty state first."}},
      {"conductor.steer", %{text: "Read the failing test before you change the code again.", when: "next_turn", trigger: "step_failed"}},
      {"report.published", %{run_id: "report_1", text: "TP-1 merged."}},
      {"note.read", %{note_id: "evt_1", run_id: "run_4"}},
      {"note", %{text: @old_note}}
    ]

    @log_words [~r/\bR\d+[a-z]?\b/, ~r/\b[a-z0-9]+_[a-z0-9_]+\b/, ~r/\b[0-9a-f]{40}\b/, ~r/claude-/]

    test "every type's line is a sentence: no rule number, code, full hash or model id" do
      assert @coded |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Types.catalog() |> Map.keys() |> Enum.sort()

      for {type, payload} <- @coded,
          summary = render(type, payload),
          line <- [summary.title, summary.detail],
          is_binary(line),
          pattern <- @log_words do
        refute line =~ pattern, "#{type}: #{line}"
      end
    end

    test "an old machine note reads in the same words, and a commit by its short hash" do
      assert render("note", %{text: @old_note}).detail ==
               "QA waits on the PR watcher · head 2c8b252 · reason the PR watcher: Checks are running on PR tonypine/symphony#894's head · status running"
    end

    test "a note a signal wrote says the signal's words and its reason" do
      note = %{text: @old_note, signal: "qa_head_not_green", signal_details: %{"head" => @sha, "reason" => @watcher_reason}}

      assert render("note", note) == %{title: "QA waits on the PR watcher", detail: "the PR watcher: Checks are running on PR tonypine/symphony#894's head"}
      assert render("note", %{text: "x", signal: "ci_flake", signal_details: "none"}) == %{title: "CI passed on Symphony's rerun, a flake", detail: nil}
      assert render("note", %{text: "x", signal: "dispatch_loop"}).title == "Symphony noted dispatch loop"
    end

    test "a review's move to Rework is a send-back; any other move enters its phase" do
      assert render("phase.entered", %{to: "Rework", from: "QA", reason: "1 finding"}) == %{title: "Sent back to Rework by QA", detail: "1 finding"}
      assert render("phase.entered", %{to: "Rework", from: "Code Review"}).title == "Sent back to Rework by Code Review"
      assert render("phase.entered", %{to: "Rework", from: "In Progress"}).title == "Entered Rework from In Progress"
      assert render("phase.entered", %{to: "Merging", from: "QA", via: "qa_pass"}) == %{title: "Entered Merging from QA", detail: nil}
    end

    test "a code a run, verdict, finding or hold carries reads as words" do
      assert render("run.ended", %{run_id: "r", exit: "handoff_missing"}).title == "Run ended: handoff missing"
      assert render("verdict.recorded", %{kind: "qa", outcome: "changes_requested"}).title == "QA verdict: changes requested"
      assert render("finding.recorded", %{class: "visual_mismatch"}).title == "QA found visual mismatch"
      assert render("hold.cleared", %{kind: "blocked", by: "hold_cleared"}).detail == "by hold cleared"
      assert render("step.completed", %{step_id: "b", title: "Build", mode: "machine", outcome: "failed", returns_to: "write_code"}).title == "Build failed: back to step write code"
    end

    test "only Symphony's bookkeeping is bookkeeping" do
      bookkeeping? = fn type, payload -> Summary.bookkeeping?(event(type, payload)) end

      assert bookkeeping?.("note", %{text: "x", signal: "qa_head_not_green"})
      assert bookkeeping?.("note", %{text: "x", signal: "code_review_head_not_green"})
      assert bookkeeping?.("note", %{text: "x", signal: "stale_check"})
      refute bookkeeping?.("note", %{text: "x", signal: "ci_flake"})
      refute bookkeeping?.("note", %{text: "A person's note"})
      assert bookkeeping?.("workspace.synced", %{action: "none"})
      assert bookkeeping?.("workspace.synced", %{})
      refute bookkeeping?.("workspace.synced", %{action: "reset"})
      refute bookkeeping?.("phase.entered", %{to: "QA"})
    end

    test "a rule is named by what it does, a PR watcher row by what the row did" do
      rule = fn type, payload -> Summary.rule_name(event(type, payload)) end

      assert rule.("rule.action", %{rule: "PR watcher R29", action: "auto_merge"}) == "Merging lands with auto-merge"
      assert rule.("rule.action", %{rule: "PR watcher R22", action: "updated_branch"}) == "keep the branch current"
      assert rule.("rule.action", %{rule: "PR watcher R7b", action: "other"}) == "the PR watcher"
      assert rule.("rule.action", %{rule: "Self-heal", action: "filed_ticket"}) == "a broken tool gets a fix ticket"
      assert rule.("rule.action", %{rule: "Night shift (R3)", action: "other"}) == "Night shift"
      assert rule.("rule.action", %{action: "other"}) == nil
      assert rule.("pause.set", %{set_by: %{kind: :rule, name: "Blocked-by links"}}) == "blockers first"
      assert rule.("pause.cleared", %{"by" => %{"kind" => "rule", "name" => "CI wait"}}) == "a red or running check holds the ticket"
      assert rule.("pause.set", %{set_by: %{kind: :person, name: "Tony"}}) == nil
      assert rule.("pause.set", %{}) == nil
      assert rule.("phase.entered", %{to: "QA"}) == nil
    end

    test "a run names its model as a person reads it" do
      assert Summary.model_name(%{model: "claude-opus-5-5"}) == "Claude Opus 5.5"
      assert Summary.model_name(%{"model" => "claude-haiku-4-5-20251001"}) == "Claude Haiku 4.5"
      assert Summary.model_name(%{}) == nil
    end
  end
end
