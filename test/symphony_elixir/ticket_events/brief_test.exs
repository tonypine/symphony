defmodule SymphonyElixir.TicketEvents.BriefTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketEvents, TicketState}
  alias SymphonyElixir.TicketEvents.{Brief, Event}

  @repo_key "repo-a"
  @issue_id "issue-1"
  @at ~U[2026-10-22 10:00:00Z]
  @head "4f1c2a9e7b3d5f60a1c8e2d4b6f8a0c3e5d7f9b1"
  @qa {:agent, "run-qa", "qa"}

  setup do
    :ok = RunStore.clear()
  end

  defp event(minute, type, payload, opts \\ []) do
    {:ok, event} = TicketEvents.build(@repo_key, @issue_id, type, payload, Keyword.put(opts, :at, DateTime.add(@at, minute * 60)))
    event
  end

  defp finding(minute, class, description, fields \\ %{}, opts \\ []) do
    event(minute, "finding.recorded", Map.merge(%{class: class, severity: "major", description: description}, fields), [actor: @qa] ++ opts)
  end

  describe "render/2" do
    test "reads the ticket's record and every event, past the 200 a query page holds, and leaves nothing out" do
      long = "The export button is cut off at the laptop viewport. " |> String.duplicate(30) |> String.trim()

      findings = for n <- 1..300, do: finding(n, "clipped", "#{n}: #{long}", %{viewport: "laptop 1440×900"})

      decisions =
        for n <- 1..50 do
          event(400 + n, "decision.requested", %{title: "Question #{n}", question: "Should #{n} #{long}?"})
        end

      notes = for n <- 1..40, do: event(500 + n, "note", %{text: "Note #{n}: #{long}"}, actor: {:person, "Sam"})

      assert {:ok, _events} = RunStore.append_ticket_events(findings ++ decisions ++ notes)
      :ok = RunStore.update_ticket_state(@repo_key, @issue_id, %{phase: "Rework"})

      assert {:ok, brief} = Brief.render(@repo_key, @issue_id)

      assert %{decisions: 50, open_findings: 300, notes: 40, runs: 1} = brief
      assert brief.tokens == div(byte_size(brief.text), 4)
      assert brief.text =~ "- Phase: Rework"
      assert brief.text =~ "Open findings (300):\n- clipped (300):"

      for n <- 1..300, do: assert(brief.text =~ "at laptop 1440×900, last seen #{DateTime.to_iso8601(DateTime.add(@at, n * 60))}: #{n}: #{long}\n")
      for n <- 1..50, do: assert(brief.text =~ "Question #{n}: Should #{n} #{long}?\n  Open: it waits on the Director's answer.")
      for n <- 1..40, do: assert(brief.text =~ "the Director (Sam): Note #{n}: #{long}\n")
    end

    test "renders the same bytes for the same ledger" do
      events = [event(0, "note", %{text: "first"}), finding(1, "clipped", "cut off")]
      assert {:ok, _events} = RunStore.append_ticket_events(events)

      assert Brief.render(@repo_key, @issue_id) == Brief.render(@repo_key, @issue_id)
      assert Brief.build(nil, events) == Brief.build(nil, Enum.reverse(events))
    end

    test "returns the store's error" do
      assert Brief.render(@repo_key, nil) == {:error, :invalid_issue_id}
    end
  end

  describe "build/2" do
    test "an empty ledger names every section with nothing in it" do
      assert %{text: text, decisions: 0, open_findings: 0, notes: 0, runs: 0} = Brief.build(nil, [])

      assert text == """
             Phase and pauses:
             - Phase: unknown
             - Pauses: none

             Decisions (0):
             - none

             Open findings (0):
             - none

             Notes (0):
             - none

             Runs (0):
             - none

             Other events, newest first (0):
             - none\
             """
    end

    test "phase and pauses come from the record" do
      symphony = %{kind: :symphony, name: "Symphony"}

      pause = %{
        subject: {:ticket, @repo_key, @issue_id},
        set_by: symphony,
        since: @at,
        reasons: [
          %{kind: :environment, waits_on: %{condition: "tooling"}, text: "tooling", set_by: symphony, set_at: @at, releasable: true},
          %{kind: :question, waits_on: %{question_id: "q-1"}, text: "Waiting for your answer: Ship it", set_by: symphony, set_at: nil, releasable: false}
        ]
      }

      record = TicketState.new(@repo_key, @issue_id, %{phase: "QA"}) |> TicketState.put_pause(pause, @at)

      text = Brief.build(record, []).text

      assert text =~ "Phase and pauses:\n- Phase: QA\n"
      assert text =~ "\n- Paused: environment (tooling), since 2026-10-22T10:00:00Z\n"
      assert text =~ "\n- Paused: question (Waiting for your answer: Ship it)\n"
    end

    test "a Question's request shows as a decision request does: open, answered or withdrawn" do
      options = [%{label: "Merge", effect: "the ticket moves to Merging", good: [], cost: [], risk: [], recommended?: true, unlocks: []}]

      asked = fn minute, id, title ->
        event(minute, "question.asked", %{question_id: id, title: title, question: "#{title}?", why: "It waits.", options: options})
      end

      open = asked.(0, "q-1", "Protected files changed on TP-7")
      answered = asked.(1, "q-2", "Merge TP-7")
      withdrawn = asked.(2, "q-3", "Run it again")
      recorded = asked.(3, "q-4", "Split it")

      events = [
        open,
        answered,
        withdrawn,
        recorded,
        event(4, "question.answered", %{question_id: "q-2", answer: "Merge"}),
        event(5, "question.withdrawn", %{question_id: "q-3", reason: "Not needed"}),
        event(6, "decision.recorded", %{answer: "Two tickets.", request: recorded.id}, actor: {:person, "Sam"}),
        event(7, "question.answered", %{question_id: "q-unknown", answer: "Orphan"})
      ]

      brief = Brief.build(nil, events)

      assert brief.decisions == 4

      assert brief.text =~
               """
               Decisions (4):
               - Asked 2026-10-22T10:00:00Z by Symphony: Protected files changed on TP-7: Protected files changed on TP-7?
                 Why: It waits.
                 Option: Merge: the ticket moves to Merging
                 Open: it waits on the Director's answer.
               - Asked 2026-10-22T10:01:00Z by Symphony: Merge TP-7: Merge TP-7?
                 Why: It waits.
                 Option: Merge: the ticket moves to Merging
                 Answered 2026-10-22T10:04:00Z by Symphony: Merge
               - Asked 2026-10-22T10:02:00Z by Symphony: Run it again: Run it again?
                 Why: It waits.
                 Option: Merge: the ticket moves to Merging
                 Withdrawn 2026-10-22T10:05:00Z by Symphony.
               - Asked 2026-10-22T10:03:00Z by Symphony: Split it: Split it?
                 Why: It waits.
                 Option: Merge: the ticket moves to Merging
                 Answered 2026-10-22T10:06:00Z by the Director (Sam): Two tickets.
               """

      # An answer naming no question the brief shows is one of the other events.
      assert brief.text =~ "Other events"
      assert brief.text =~ "Orphan"
    end

    test "a Question the Director reopened is open again, and its next answer is the one that stands (TP-1240)" do
      asked = event(0, "question.asked", %{question_id: "q-1", title: "Merge TP-7", question: "Merge TP-7?"})
      answered = event(1, "question.answered", %{question_id: "q-1", answer: "Merge"})
      reopened = event(2, "question.reopened", %{question_id: "q-1", title: "Merge TP-7"})

      assert Brief.build(nil, [asked, answered, reopened]).text =~ "Merge TP-7?\n  Open: it waits on the Director's answer."

      again = event(3, "question.answered", %{question_id: "q-1", answer: "Wait"})
      assert Brief.build(nil, [asked, answered, reopened, again]).text =~ "Merge TP-7?\n  Answered 2026-10-22T10:03:00Z by Symphony: Wait"
    end

    test "every decision: answered, withdrawn, open, and a ruling with no request" do
      answered = event(0, "decision.requested", %{title: "Large exports", question: "Background?", why: "It takes long.", options: ["Yes", %{label: "No", effect: "The user waits."}, 7, %{}]})
      withdrawn = event(1, "decision.requested", %{question: "Keep the header?"}, actor: {:agent, "run-1", "implementation"})
      open = event(2, "decision.requested", %{question: "CSV"})

      events = [
        answered,
        withdrawn,
        open,
        event(3, "decision.recorded", %{answer: "Yes, with a notification.", request: answered.id}, actor: {:person, "Sam"}),
        event(4, "decision.withdrawn", %{title: "Keep the header?", request: withdrawn.id}),
        event(5, "decision.recorded", %{answer: "Ship it in two tickets.", title: "Split", question: "One ticket or two?"}, actor: {:person, "Sam"}),
        event(6, "decision.recorded", %{answer: "Plain."}, actor: {:person, "Sam"}),
        event(7, "decision.recorded", %{answer: "No, keep it.", request: answered.id}, actor: {:person, "Sam"}),
        event(8, "decision.withdrawn", %{title: "Gone", request: "evt-unknown"})
      ]

      brief = Brief.build(nil, events)

      assert brief.decisions == 5

      assert brief.text =~
               """
               Decisions (5):
               - Asked 2026-10-22T10:00:00Z by Symphony: Large exports: Background?
                 Why: It takes long.
                 Option: Yes
                 Option: No: The user waits.
                 Answered 2026-10-22T10:03:00Z by the Director (Sam): Yes, with a notification.
               - Asked 2026-10-22T10:01:00Z by an agent (Implementation run): Keep the header?
                 Withdrawn 2026-10-22T10:04:00Z by Symphony.
               - Asked 2026-10-22T10:02:00Z by Symphony: CSV
                 Open: it waits on the Director's answer.
               - Ruled 2026-10-22T10:05:00Z by the Director (Sam) on Split: One ticket or two?: Ship it in two tickets.
               - Ruled 2026-10-22T10:06:00Z by the Director (Sam): Plain.
               """

      assert brief.text =~
               """
               Other events, newest first (2):
               - 2026-10-22T10:08:00Z Decision request withdrawn: Gone
               - 2026-10-22T10:07:00Z The Director decided: No, keep it.\
               """
    end

    test "open findings grouped by class, with viewport, commit, last seen and the whole description" do
      long = String.duplicate("word ", 100) |> String.trim()
      run = event(0, "run.started", %{run_id: "run-qa", run_kind: "qa", run_number: 2, state: "QA", head: @head}, run_id: "run-qa")
      own_head = finding(1, "clipped", "Cut off.\nNo scroll reaches it.", %{viewport: "laptop"}, head_sha: "abcdef1234")
      from_run = event(2, "finding.recorded", %{class: "clipped", severity: "minor", description: long, step: "Open it", evidence: ["a1", "a2"]}, actor: @qa)
      fixed = finding(3, "truncated", "Labels cut.")
      reopened = finding(4, "truncated", "Names cut.")
      unclassified = event(5, "finding.recorded", %{class: "unclassified", severity: "major", description: "Odd.", evidence: "a3"}, actor: @qa)
      fix = event(6, "finding.resolved", %{finding_id: fixed.id, how: "Wrapped."}, actor: {:agent, "run-rw", "rework"})
      claimed = event(7, "finding.resolved", %{finding_id: reopened.id, how: "Widened."}, actor: {:agent, "run-rw", "rework"})
      reopen = event(9, "verdict.recorded", %{kind: "qa", outcome: "fail"}, supersedes: claimed.id)

      brief = Brief.build(nil, [run, own_head, from_run, fixed, reopened, unclassified, fix, claimed, reopen])

      assert brief.open_findings == 4

      assert brief.text =~
               """
               Open findings (4):
               - clipped (2):
                 - major, at laptop, commit abcdef1, last seen 2026-10-22T10:01:00Z: Cut off.
                   No scroll reaches it.
                 - minor, step Open it, commit 4f1c2a9, last seen 2026-10-22T10:02:00Z: #{long} (files: a1, a2)
               - truncated (1):
                 - major, commit 4f1c2a9, last seen 2026-10-22T10:09:00Z: Names cut.
               - unclassified (1):
                 - major, commit 4f1c2a9, last seen 2026-10-22T10:05:00Z: Odd. (files: a3)
               """

      refute brief.text =~ "Labels cut."
    end

    test "every note in full, a person's as the Director's" do
      events = [
        event(0, "note", %{text: "Keep the button.\nUsers know it."}, actor: {:person, "Sam"}),
        event(1, "note", %{text: "Batching rows."}, actor: {:agent, "run-1", "implementation"}),
        event(2, "note", %{text: "Restarted."}),
        # The control API's note (one shared token) names its person "the Director" already.
        event(3, "note", %{text: "Ship it narrow."}, actor: {:person, "the Director"})
      ]

      assert %{notes: 4, text: text} = Brief.build(nil, events)

      assert text =~
               """
               Notes (4):
               - 2026-10-22T10:00:00Z, the Director (Sam): Keep the button.
                 Users know it.
               - 2026-10-22T10:01:00Z, an agent (Implementation run): Batching rows.
               - 2026-10-22T10:02:00Z, Symphony: Restarted.
               - 2026-10-22T10:03:00Z, the Director: Ship it narrow.
               """
    end

    test "one line per earlier run, and the latest run's events in full" do
      long = String.duplicate("checked ", 60) |> String.trim()
      rework = {:agent, "run-3", "rework"}

      events = [
        event(0, "run.started", %{run_id: "run-1", run_kind: "implementation", run_number: 1, state: "In Progress"}, run_id: "run-1"),
        event(1, "step.completed", %{title: "Profile the query", mode: "orchestrated"}, actor: {:agent, "run-1", "implementation"}),
        event(2, "run.ended", %{run_id: "run-1", exit: "success", head: @head}, run_id: "run-1"),
        event(3, "step.started", %{title: "Look", mode: "delegated"}, actor: {:agent, "run-2", "ci_fix"}),
        event(4, "run.started", %{run_id: "run-x", run_kind: "code_review", state: "Code Review"}, run_id: "run-x"),
        event(5, "attempt.pushed", %{head: @head}, run_id: "run-m"),
        event(10, "run.started", %{run_id: "run-3", run_kind: "rework", run_number: 1, state: "Rework", head: @head}, run_id: "run-3"),
        event(11, "step.completed", %{title: "Fix the dialog", mode: "orchestrated"}, actor: rework),
        event(12, "checklist.answered", %{item: "Viewports", answer: long}, actor: rework),
        event(13, "evidence", %{caption: "After the fix"}, actor: rework, artifacts: ["art1"]),
        event(14, "finding.resolved", %{finding_id: "f1", how: long}, actor: rework),
        event(15, "decision.requested", %{title: "Scope", question: "Split?"}, actor: rework),
        event(16, "note", %{text: long}, actor: rework),
        event(17, "verdict.recorded", %{kind: "qa", outcome: "pass", head: @head}, run_id: "run-3"),
        event(18, "decision.recorded", %{answer: long}, actor: {:person, "Sam"}, run_id: "run-3"),
        event(19, "finding.recorded", %{class: "clipped", severity: "major", description: long}, actor: {:agent, "run-3", "qa"})
      ]

      assert %{runs: 5, text: text} = Brief.build(nil, events)

      assert text =~
               """
               Runs (5):
               - Implementation run 1: ended: success, at 4f1c2a9, started 2026-10-22T10:00:00Z
               - CI Fix run: no end recorded, started 2026-10-22T10:03:00Z
               - Code Review run: in Code Review, no end recorded, started 2026-10-22T10:04:00Z
               - Agent run: no end recorded, started 2026-10-22T10:05:00Z
               - Rework run 1 (latest): running in Rework, at 4f1c2a9, started 2026-10-22T10:10:00Z
                 - 2026-10-22T10:11:00Z Step completed: Fix the dialog
                 - 2026-10-22T10:12:00Z Checklist item answered: Viewports: #{long}
                 - 2026-10-22T10:13:00Z Evidence recorded: After the fix (files: art1)
                 - 2026-10-22T10:14:00Z Finding marked resolved: #{long}
                 - 2026-10-22T10:15:00Z Decision needed from the Director: Scope: Split?
                 - 2026-10-22T10:16:00Z Note added: #{long}
                 - 2026-10-22T10:17:00Z QA verdict: pass: on 4f1c2a9
                 - 2026-10-22T10:18:00Z The Director ruled: #{long}
                 - 2026-10-22T10:19:00Z QA found clipped: major: #{long}
               """

      refute text =~ "Profile the query"
    end

    test "a latest run with no steps and no state says so" do
      events = [event(0, "run.started", %{run_id: "run-1", run_kind: "qa"}, run_id: "run-1")]

      assert Brief.build(nil, events).text =~ "Runs (1):\n- QA run (latest): running, started 2026-10-22T10:00:00Z\n  - no steps recorded\n"
    end

    test "every event outside a run, newest first, from its summary, without the ones a section holds" do
      events = [
        event(0, "phase.entered", %{to: "QA", from: "Code Review"}),
        event(1, "person.action", %{action: "stop"}, actor: {:person, "Sam"}),
        event(2, "note", %{text: "in Notes"}),
        event(3, "hold.set", %{kind: "blocked", reason: "tooling"}, artifacts: ["log1"])
      ]

      assert Brief.build(nil, events).text =~
               """
               Other events, newest first (3):
               - 2026-10-22T10:03:00Z Blocked hold set: tooling (files: log1)
               - 2026-10-22T10:01:00Z The Director stopped the run
               - 2026-10-22T10:00:00Z Entered QA from Code Review\
               """
    end

    test "reads stored records, events without a summary and payloads with string keys" do
      records = [
        %{id: "e2", seq: 2, at: ~U[2026-10-22 10:01:00Z], type: "note", actor: %{kind: "person", name: "Sam"}, payload: %{"text" => "string keys"}},
        %{id: "e1", seq: 1, at: nil, type: "phase.entered", payload: %{to: "QA"}},
        %Event{id: "e3", seq: 3, at: ~U[2026-10-22 10:02:00Z], type: "run.started", run_id: "r", payload: %{"run_kind" => 7, "run_number" => -1}},
        %{id: "e4", seq: 4, at: ~U[2026-10-22 10:03:00Z], type: "hold.cleared", run_id: "r", payload: %{kind: "blocked"}},
        %{id: "e5", seq: 5, at: ~U[2026-10-22 10:04:00Z], type: "finding.recorded", run_id: "r", payload: %{description: "No class."}}
      ]

      text = Brief.build(%{phase: "QA"}, records).text

      assert text =~ "- 2026-10-22T10:01:00Z, the Director (Sam): string keys"
      assert text =~ "- Agent run (latest): running, started 2026-10-22T10:02:00Z\n  - 2026-10-22T10:03:00Z Blocked hold cleared\n"
      assert text =~ "- unclassified (1):\n  - last seen 2026-10-22T10:04:00Z: No class."
      assert text =~ "Other events, newest first (1):\n-  Entered QA"
    end
  end
end
