defmodule SymphonyElixir.Conductor.FactsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Conductor.{Answer, Facts}
  alias SymphonyElixir.{RunStore, TicketEvents, TicketPlan}

  @description """
  Intro line.

  ## Problem
  The login button does nothing.

  ## Acceptance criteria
  - Clicking it signs in.

  ## User walkthrough
  1. Open the app.
  2. Click Login.
  """

  setup do
    n = System.unique_integer([:positive])
    repo = "facts-#{n}"
    issue_id = "issue-facts-#{n}"

    record = %{
      repo_key: repo,
      issue_id: issue_id,
      issue_identifier: "FACT-#{n}",
      phase: "Rework",
      title: "Fix login",
      description: @description,
      url: "https://linear.app/t/FACT-#{n}",
      decisions: [%{key: "k1", date: "2026-11-18", title: "Scope", question: "Which?", answer: "Only the button.", scope: "ticket"}]
    }

    :ok = RunStore.put_ticket_state(record)
    %{repo: repo, issue_id: issue_id, record: record, identifier: record.issue_identifier}
  end

  defp record!(ctx, type, payload, opts \\ []) do
    {:ok, event} = TicketEvents.record(ctx.repo, ctx.issue_id, type, payload, opts)
    event
  end

  defp agent(run_id, kind), do: {:agent, run_id, kind}

  defp seed!(ctx) do
    record!(ctx, "run.started", %{run_id: "run-1", run_kind: "implementation", model: "model-a"}, run_id: "run-1")
    build = record!(ctx, "step.completed", %{step_id: "build", title: "Build", mode: "machine", outcome: "failed", returns_to: "code"}, run_id: "run-1")
    brief = record!(ctx, "brief.written", %{text: "Signs a person in.", walkthrough: "Click Login."}, actor: agent("run-1", "implementation"))
    record!(ctx, "run.ended", %{run_id: "run-1", run_kind: "implementation", exit: "normal", tokens: 1_000}, run_id: "run-1")
    record!(ctx, "run.started", %{run_id: "run-2", run_kind: "qa"}, run_id: "run-2")

    finding =
      record!(ctx, "finding.recorded", %{class: "login", severity: "high", description: "Expected a session; got nothing.", evidence: "shot.png"}, actor: agent("run-2", "qa"))

    verdict = record!(ctx, "verdict.recorded", %{kind: "qa", outcome: "fail", reason: "Login broken"})
    record!(ctx, "run.ended", %{run_id: "run-2", run_kind: "qa", exit: "normal", tokens: %{total_tokens: 500}}, run_id: "run-2")
    note = record!(ctx, "note", %{text: "Keep the old button."}, actor: {:person, "Director"})
    record!(ctx, "note", %{text: "An agent's note."}, actor: agent("run-2", "qa"))
    record!(ctx, "question.asked", %{question_id: "q1", title: "Which button?", question: "Keep which button?"})
    answer = record!(ctx, "question.answered", %{question_id: "q1", answer: "The old one.", option: "Old"})
    record!(ctx, "run.started", %{run_id: "run-3", run_kind: "rework"}, run_id: "run-3")
    resolution = record!(ctx, "finding.resolved", %{finding_id: finding.id, how: "Wired the handler.", head: "abc123"}, actor: agent("run-3", "rework"))
    record!(ctx, "run.ended", %{run_id: "run-3", run_kind: "rework", exit: "normal"}, run_id: "run-3")
    record!(ctx, "run.started", %{run_id: "run-4", run_kind: "qa"}, run_id: "run-4")
    reopened = record!(ctx, "finding.recorded", %{class: "login", severity: "high", description: "Still nothing."}, actor: agent("run-4", "qa"), supersedes: resolution.id)
    record!(ctx, "run.ended", %{run_id: "run-4", run_kind: "qa", exit: "normal", tokens: 250}, run_id: "run-4")
    update = record!(ctx, "conductor.update", %{junction: "after_qa_fail", text: "QA failed the login again.", refs: [reopened.id]}, run_id: "conductor-1")
    record!(ctx, "run.started", %{run_id: "conductor-1", run_kind: "conductor"}, run_id: "conductor-1")
    record!(ctx, "run.ended", %{run_id: "conductor-1", run_kind: "conductor", exit: "answered", tokens: 40, counted: false}, run_id: "conductor-1")

    %{build: build, brief: brief, finding: finding, verdict: verdict, note: note, answer: answer}
    |> Map.merge(%{resolution: resolution, reopened: reopened, update: update})
  end

  test "builds one document from the ticket's record and events, each fact with its event's id", ctx do
    seeded = seed!(ctx)
    facts = Facts.build(ctx.record, "after_qa_fail", token_cap: 5_000, diff_stat: fn _record -> [%{path: "lib/a.ex", added: 3, removed: 1}] end)

    assert facts.schema == "symphony.conductor.facts/1"
    assert facts.junction == "after_qa_fail"
    assert facts.focus =~ "rework"

    assert %{identifier: identifier, title: "Fix login", problem: "The login button does nothing.", acceptance: "- Clicking it signs in."} = facts.ticket
    assert identifier == ctx.identifier
    assert facts.ticket.walkthrough =~ "Click Login."
    assert facts.ticket.brief == %{event_id: seeded.brief.id, text: "Signs a person in.", walkthrough: "Click Login."}
    assert facts.ticket.decisions == [%{title: "Scope", answer: "Only the button."}]
    assert [%{event_id: note_id, text: "Keep the old button."}] = facts.ticket.notes
    assert note_id == seeded.note.id
    assert [%{event_id: answer_id, question: "Which button?", answer: "The old one.", option: "Old"}] = facts.ticket.answers
    assert answer_id == seeded.answer.id

    assert facts.standing == %{phase: "Rework", attempt: 2, pull_request: nil, head: nil}

    assert %{kind: "qa", run_id: "run-4", exit: "normal", tokens: 250, steps: [], resolved_findings: []} = facts.last_run
    assert facts.last_run.files_changed == [%{path: "lib/a.ex", added: 3, removed: 1}]

    assert [finding] = facts.findings
    assert finding.event_id == seeded.finding.id
    assert finding.state == "reopened"
    assert finding.class == "login"
    assert finding.class_count == 2
    assert finding.evidence == ["shot.png"]
    assert finding.reopened_by == seeded.reopened.id

    assert [%{event_id: verdict_id, kind: "qa", outcome: "fail", reason: "Login broken"}] = facts.verdicts
    assert verdict_id == seeded.verdict.id
    assert [%{event_id: update_id, type: "update", junction: "after_qa_fail", text: "QA failed the login again."}] = facts.conductor
    assert update_id == seeded.update.id

    assert facts.budget == %{tokens_used: 1_790, tokens_cap: 5_000, qa_passes: 2, rework_runs: 1}
    assert %{open: true, filed: [], left: 2} = facts.filings
    assert {:ok, _json} = Jason.encode(facts)
  end

  test "the last run carries its steps and the findings it resolved", ctx do
    seeded = seed!(ctx)
    events = Facts.events(ctx.issue_id)
    first_run = Enum.take_while(events, &(&1.type != "run.started" or &1.payload.run_id != "run-2"))
    rework = Enum.take_while(events, &(&1.type != "run.started" or &1.payload.run_id != "run-4"))

    assert %{kind: "implementation", model: "model-a", steps: [step]} = Facts.build(ctx.record, nil, events: first_run, diff_stat: fn _record -> nil end).last_run
    assert step == %{event_id: seeded.build.id, step_id: "build", title: "Build", mode: "machine", outcome: "failed", returns_to: "code"}

    answered = %SymphonyElixir.TicketEvents.Event{
      id: "s9",
      type: "step.completed",
      run_id: "run-1",
      payload: %{
        step_id: "walk_1",
        title: "Walk",
        mode: "orchestrated",
        outcome: "passed",
        result: %{status: "blocked", expected: "Rows", actual: "Empty state"},
        verdict_summary: "Blocked."
      }
    }

    assert %{steps: [_build, walked]} = Facts.build(ctx.record, nil, events: first_run ++ [answered], diff_stat: fn _record -> nil end).last_run
    assert walked.result == %{status: "blocked", expected: "Rows", actual: "Empty state"}
    assert walked.outcome == "blocked", "a QA check's word is what it judged, not that it ran"
    assert walked.verdict_summary == "Blocked."

    layout = %{answered | payload: Map.put(answered.payload, :answer, [%{label: "layout", value: "two columns"}, %{"label" => "why", "value" => "fits"}, "junk"])}

    assert %{steps: [_build, %{answer: [%{label: "layout", value: "two columns"}, %{label: "why", value: "fits"}]}]} =
             Facts.build(ctx.record, nil, events: first_run ++ [layout], diff_stat: fn _record -> nil end).last_run

    string_keys = %{answered | payload: %{answered.payload | result: %{"status" => "blocked", "expected" => "Rows", "actual" => "Empty"}}}
    assert %{steps: [_build, %{result: %{status: "blocked", actual: "Empty"}}]} = Facts.build(ctx.record, nil, events: first_run ++ [string_keys], diff_stat: fn _record -> nil end).last_run

    facts = Facts.build(ctx.record, "after_rework", events: rework, diff_stat: fn _record -> nil end, token_cap: nil)
    assert facts.last_run.resolved_findings == [%{event_id: seeded.resolution.id, finding_id: seeded.finding.id, how: "Wired the handler."}]
    refute Map.has_key?(facts.last_run, :files_changed)
    refute Map.has_key?(Facts.build(%{ctx.record | issue_identifier: nil}, nil, events: rework, token_cap: nil).last_run, :files_changed)
    assert [%{state: "resolved", resolution: %{how: "Wired the handler."}}] = facts.findings
  end

  test "TP-1550: after a blocked QA the facts hold every QA pass, why each was blocked, and the Conductor's earlier routes and steers", ctx do
    record!(ctx, "run.started", %{run_id: "qa-1", run_kind: "qa"}, run_id: "qa-1")

    step =
      record!(
        ctx,
        "step.completed",
        %{step_id: "walk_1", title: "Walk 1", mode: "orchestrated", outcome: "passed", result: %{status: "blocked", expected: "A state error", actual: "QA cannot make the state request fail"}},
        run_id: "qa-1"
      )

    passed = %{step_id: "walk_2", title: "Walk 2", mode: "orchestrated", outcome: "passed", result: %{status: "pass", expected: "Rows", actual: "Rows"}}
    record!(ctx, "step.completed", passed, run_id: "qa-1")
    record!(ctx, "step.completed", %{step_id: "plan", title: "Plan", mode: "orchestrated", outcome: "passed"}, run_id: "qa-1")
    evidence = record!(ctx, "evidence", %{caption: "Step 3: blocked", step: "Step 3", status: "blocked", details: "No way to fail the request."}, actor: agent("qa-1", "qa"))
    record!(ctx, "evidence", %{caption: "Step 1: pass", step: "Step 1", status: "pass"}, actor: agent("qa-1", "qa"))
    first = record!(ctx, "verdict.recorded", %{kind: "qa", outcome: "blocked", head: "aaa", details: %{reason: "QA cannot make the state request fail"}}, run_id: "qa-1")
    record!(ctx, "conductor.instructions", %{junction: "after_qa_blocked", text: "Use the stand-in server.", route: "rerun"}, run_id: "conductor-1")
    record!(ctx, "conductor.steer", %{text: "Leave the blocked step.", when: "next_turn", trigger: "qa_step_answer"}, run_id: "qa-2")
    ci = record!(ctx, "verdict.recorded", %{kind: "qa", outcome: "blocked", head: "bbb", details: %{reason: "CI is red on this head", component: "ci"}})
    record!(ctx, "verdict.recorded", %{kind: "code_review", outcome: "approve", head: "bbb"})

    facts = Facts.build(ctx.record, "after_qa_blocked", diff_stat: fn _record -> nil end, token_cap: nil)
    assert facts.focus =~ "QA could not judge the change"

    assert [blocked, on_ci] = facts.qa_passes

    assert blocked == %{
             event_id: first.id,
             run_id: "qa-1",
             outcome: "blocked",
             head: "aaa",
             reason: "QA cannot make the state request fail",
             blocked_steps: [
               %{event_id: step.id, step_id: "walk_1", title: "Walk 1", result: %{status: "blocked", expected: "A state error", actual: "QA cannot make the state request fail"}},
               %{event_id: evidence.id, step: "Step 3", details: "No way to fail the request."}
             ]
           }

    assert on_ci == %{event_id: ci.id, outcome: "blocked", head: "bbb", reason: "CI is red on this head", on_ci: true, blocked_steps: []}
    assert Enum.find(facts.verdicts, &(&1.event_id == first.id)).reason == "QA cannot make the state request fail"

    assert [%{type: "instructions", route: "rerun", junction: "after_qa_blocked"}, %{type: "steer", text: "Leave the blocked step.", when: "next_turn", trigger: "qa_step_answer"}] =
             facts.conductor

    refute Map.has_key?(Facts.build(ctx.record, "after_qa_fail", diff_stat: fn _record -> nil end, token_cap: nil), :qa_passes)
    assert {:ok, _json} = Jason.encode(facts)
  end

  test "the walkthrough steps recorded as proved by a test are in the facts, the newest proof of each", ctx do
    record!(ctx, "evidence", %{caption: "Step 2 proof", proof: %{step: 2, test: "old_test.exs"}}, actor: agent("run-1", "implementation"))
    newest = record!(ctx, "evidence", %{caption: "Step 2 proof", proof: %{step: 2, test: "test/walkthrough_test.exs"}}, actor: agent("run-2", "rework"))
    first = record!(ctx, "evidence", %{caption: "Step 1 proof", proof: %{step: 1, test: "parses each step"}}, actor: agent("run-2", "rework"))
    record!(ctx, "evidence", %{caption: "A screenshot"}, actor: agent("run-2", "rework"))

    facts = Facts.build(ctx.record, "after_rework", diff_stat: fn _record -> nil end, token_cap: nil)

    assert facts.ticket.proved_steps == [
             %{step: 1, test: "parses each step", event_id: first.id},
             %{step: 2, test: "test/walkthrough_test.exs", event_id: newest.id}
           ]
  end

  test "a ticket with no events, no description and no pull request reads empty facts", ctx do
    record = %{ctx.record | description: nil} |> Map.put(:pull_request, %{number: 7, url: "https://github.com/o/r/pull/7", state: "OPEN", head_sha: "def456"})
    facts = Facts.build(record, nil, events: [], diff_stat: fn _record -> nil end, token_cap: nil)

    assert facts.junction == nil and facts.focus == nil and facts.last_run == nil
    assert %{problem: nil, acceptance: nil, walkthrough: nil, proved_steps: [], brief: nil, notes: [], answers: []} = facts.ticket
    assert facts.standing.pull_request == %{number: 7, url: "https://github.com/o/r/pull/7", state: "OPEN"}
    assert facts.standing.head == "def456"

    assert Facts.build(%{issue_id: nil}, nil).findings == []
  end

  test "a description with no heading is the problem; long texts are cut with a marker", ctx do
    long = String.duplicate("x", 3_100)
    facts = Facts.build(%{ctx.record | description: long}, nil, events: [], diff_stat: fn _ -> nil end, token_cap: nil)

    assert String.ends_with?(facts.ticket.problem, " [cut by Symphony]")
    assert String.length(facts.ticket.problem) == 3_000 + String.length(" [cut by Symphony]")
    assert Facts.cut("  ", 10) == nil
    assert Facts.cut(nil, 10) == nil
  end

  test "reads the git numstat and a run's tokens in either shape" do
    assert Facts.numstat("3\t1\tlib/a.ex\n-\t-\tpriv/logo.png\n") == [%{path: "lib/a.ex", added: 3, removed: 1}, %{path: "priv/logo.png", added: nil, removed: nil}]
    assert Facts.tokens(5) == 5
    assert Facts.tokens(%{total_tokens: 6}) == 6
    assert Facts.tokens(%{"total_tokens" => 7}) == 7
    assert Facts.tokens("8") == nil
  end

  test "read/3 finds the ticket by identifier in any case or by id, and refuses an unknown one or junction", ctx do
    assert {:ok, %{ticket: %{identifier: identifier}, junction: "after_coding"}} = Facts.read(String.downcase(ctx.identifier), "after_coding", diff_stat: fn _ -> nil end, token_cap: 1)
    assert identifier == ctx.identifier
    assert {:ok, %{junction: nil}} = Facts.read(ctx.issue_id, "", diff_stat: fn _ -> nil end, token_cap: 1)
    assert Facts.read("NOPE-1", nil) == {:error, :not_found}

    assert {:error,
            {:invalid,
             "junction must be one of: grooming, after_coding, after_qa_fail, after_qa_blocked, after_rework, before_merge, message, sub_ticket_ended, final_check, child_message, during_run"}} =
             Facts.read(ctx.identifier, "whenever")
  end

  describe "fit/2" do
    test "keeps a text that fits, trimmed" do
      assert Facts.fit("  short  ", 20) == "short"
    end

    test "cuts at the last sentence end that leaves room for the marker" do
      assert Facts.fit("One sentence here. Two sentence here. Three sentence here.", 56) == "One sentence here. Two sentence here. [cut by Symphony]"
      "One sentence here. Two sentence here. [cut by Symphony]" |> then(fn _ -> Facts.fit("One sentence here. Two sentence here. Three sentence here.", 40) end)

      assert Facts.fit("Alpha beta gamma. Delta epsilon zeta eta theta.", 40) == "Alpha beta gamma. [cut by Symphony]"
    end

    test "cuts at a line end, else at a word end, else mid-word" do
      assert Facts.fit("First line is here\nsecond line is here too and more", 40) == "First line is here [cut by Symphony]"
      assert Facts.fit("alpha beta gamma delta epsilon zeta", 30) == "alpha beta [cut by Symphony]"
      assert Facts.fit(String.duplicate("x", 50), 30) == String.duplicate("x", 12) <> " [cut by Symphony]"
    end

    test "never goes over the limit" do
      for max <- [25, 40, 100], text <- ["a. b. c. d. e. f. g. h. i. j. k. l. m. n.", String.duplicate("é ", 80)] do
        assert String.length(Facts.fit(text, max)) <= max
      end
    end
  end

  describe "at grooming" do
    defp family!(ctx) do
      n = System.unique_integer([:positive])
      parent = %{repo_key: ctx.repo, issue_id: "parent-#{n}", issue_identifier: "PAR-#{n}", phase: "Waiting on sub-tickets", title: "Filters"}
      child_of = %{identifier: parent.issue_identifier}
      sibling = %{repo_key: ctx.repo, issue_id: "sibling-#{n}", issue_identifier: "SIB-#{n}", phase: "Done", title: "The API filter", parent: child_of}
      quiet = %{sibling | issue_id: "quiet-#{n}", issue_identifier: "QUIET-#{n}"}
      for record <- [parent, sibling, quiet], do: :ok = RunStore.put_ticket_state(record)
      child = Map.put(ctx.record, :parent, child_of)
      :ok = RunStore.put_ticket_state(child)
      %{parent: parent, sibling: sibling, child: child}
    end

    defp plan do
      %{
        reason: "Grooming",
        by: "grooming",
        shape: "split",
        layers: ["api", "screen"],
        summary: "Two sub-tickets: the API, then the list.",
        text: "Approach: the API first.",
        checks: [%{id: "c1", kind: "outcome", statement: "The list is filtered.", proof: "test"}],
        size: %{tokens: 1, runs: 1},
        sub_tickets: [%{key: "s1", title: "The API filter", ask: "Add it."}]
      }
    end

    test "the document is what was asked and the layer vocabulary, with no run facts", ctx do
      {:ok, ask} = TicketPlan.record_ask(ctx.repo, ctx.issue_id, "Keep the filter after a reload.")
      note = record!(ctx, "note", %{text: "Only the list."}, actor: {:person, "Director"})

      facts = Facts.build(ctx.record, "grooming", token_cap: 10)

      assert %{schema: "symphony.conductor.facts/1", junction: "grooming", parent: nil, siblings: [], sub_tickets: [], conductor: []} = facts
      assert %{tokens_used: 0, tokens_cap: 10} = facts.budget
      assert facts.focus =~ "you write its plan"
      assert facts.ticket == %{identifier: ctx.identifier, title: "Fix login", url: ctx.record.url, repo: ctx.repo, labels: []}
      assert facts.asks == [%{event_id: ask.id, source: "linear", text: "Keep the filter after a reload."}]
      assert [%{event_id: id, text: "Only the list."}] = facts.notes
      assert id == note.id
      assert facts.decisions == [%{title: "Scope", answer: "Only the button."}]
      assert facts.answers == []
      assert Enum.map(facts.layers, & &1.name) == Answer.layers()
      assert Enum.all?(facts.layers, &is_binary(&1.means))
      refute Map.has_key?(facts, :last_run)
      assert {:ok, _json} = Jason.encode(facts)
    end

    test "a sub-ticket reads its parent's plan and notes, and its siblings' tagged notes", ctx do
      family = family!(ctx)
      {:ok, written} = TicketPlan.write(ctx.repo, family.parent.issue_id, plan())
      {:ok, base} = TicketEvents.record(ctx.repo, family.parent.issue_id, "note", %{text: "main fails to build.", tag: "base_fault"}, actor: agent("run-p", "implementation"))
      {:ok, found} = TicketEvents.record(ctx.repo, family.sibling.issue_id, "note", %{text: "The endpoint pages by 50.", tag: "discovery"}, actor: agent("run-s", "implementation"))
      {:ok, _plain} = TicketEvents.record(ctx.repo, family.sibling.issue_id, "note", %{text: "No tag."}, actor: agent("run-s", "implementation"))

      facts = Facts.build(family.child, "grooming", token_cap: nil)

      assert facts.parent == %{
               identifier: family.parent.issue_identifier,
               title: "Filters",
               plan: %{
                 event_id: written.id,
                 version: 1,
                 shape: "split",
                 layers: ["api", "screen"],
                 summary: "Two sub-tickets: the API, then the list.",
                 text: "Approach: the API first.",
                 sub_tickets: [%{key: "s1", title: "The API filter"}]
               },
               notes: [%{event_id: base.id, tag: "base_fault", text: "main fails to build."}]
             }

      assert facts.siblings == [
               %{identifier: family.sibling.issue_identifier, title: "The API filter", phase: "Done", notes: [%{event_id: found.id, tag: "discovery", text: "The endpoint pages by 50."}]}
             ]
    end

    test "a ticket that already has sub-tickets lists them, for a split to adopt", ctx do
      family = family!(ctx)
      known = %{id: family.sibling.issue_id, identifier: family.sibling.issue_identifier, state: "Done"}
      parent = Map.put(family.parent, :sub_issues, [known, %{id: "untracked", identifier: "NEW-1", state: "Backlog"}])

      assert Facts.build(parent, "grooming", token_cap: nil).sub_tickets == [
               %{identifier: family.sibling.issue_identifier, title: "The API filter", state: "Done"},
               %{identifier: "NEW-1", title: nil, state: "Backlog"}
             ]

      assert Facts.build(Map.put(family.parent, :sub_issues, :unknown), "grooming", token_cap: nil).sub_tickets == []
    end

    test "a parent Symphony does not track, or one with no plan yet, gives what there is", ctx do
      orphan = Map.put(ctx.record, :parent, %{identifier: "GONE-1"})
      assert %{parent: nil, siblings: []} = Facts.build(orphan, "grooming", token_cap: nil, records: [])

      family = family!(ctx)
      assert %{parent: %{plan: nil, notes: []}, siblings: []} = Facts.build(family.child, "grooming", token_cap: nil)
      assert {:ok, %{junction: "grooming"}} = Facts.read(ctx.identifier, "grooming", token_cap: nil)
    end
  end

  describe "at a turn on a ticket with sub-tickets" do
    test "the document is the tree: the plan, each sub-ticket's standing, what merged and the rounds", ctx do
      family = family!(ctx)
      parent_id = family.parent.issue_id
      {:ok, ask} = TicketPlan.record_ask(ctx.repo, parent_id, "Filter the list.")
      {:ok, written} = TicketPlan.write(ctx.repo, parent_id, plan())
      {:ok, _round} = TicketPlan.write(ctx.repo, parent_id, %{plan() | reason: "Final check: the docs are missing.", by: "recalibration"})
      {:ok, _plan} = TicketPlan.write(ctx.repo, family.sibling.issue_id, %{plan() | shape: "single", summary: "The API takes a filter."})
      {:ok, child_ask} = TicketPlan.record_ask(ctx.repo, family.sibling.issue_id, "Add it.", source: "parent", from: family.parent.issue_identifier)
      agent = agent("run-s", "implementation")
      {:ok, found} = TicketEvents.record(ctx.repo, family.sibling.issue_id, "note", %{text: "The endpoint pages by 50.", tag: "discovery"}, actor: agent)
      url = "https://github.com/acme/app/pull/77"
      :ok = SymphonyElixir.TicketPullRequest.put(ctx.repo, family.sibling.issue_id, %{pr_url: url})
      :ok = SymphonyElixir.TicketPullRequest.mark_finished(ctx.repo, url, "merged")
      known = %{id: family.sibling.issue_id, identifier: family.sibling.issue_identifier, state: "Done"}
      parent = Map.put(family.parent, :sub_issues, [known, %{id: "untracked", identifier: "NEW-1", state: "Canceled"}])

      facts = Facts.build(parent, "final_check", token_cap: nil)

      assert %{schema: "symphony.conductor.facts/1", junction: "final_check", conductor: [], decisions: [], notes: [], answers: []} = facts
      assert facts.focus =~ "The last sub-ticket ended"
      assert facts.ticket == %{identifier: family.parent.issue_identifier, title: "Filters", url: nil, repo: ctx.repo, phase: "Waiting on sub-tickets", pull_request: "none"}
      assert facts.asks == [%{event_id: ask.id, source: "linear", text: "Filter the list."}]
      assert %{version: 2, shape: "split", summary: "Two sub-tickets: the API, then the list."} = facts.plan
      assert facts.plan.event_id != written.id
      assert facts.checks == [%{id: "c1", kind: "outcome", statement: "The list is filtered.", proof: "test", state: "open"}]
      assert facts.rounds == %{made: 1, limit: 3, left: 2}

      assert facts.sub_tickets == [
               %{
                 identifier: family.sibling.issue_identifier,
                 title: "The API filter",
                 phase: "Done",
                 state: "Done",
                 pull_request: "merged",
                 plan: "The API takes a filter.",
                 checks: [%{id: "c1", kind: "outcome", statement: "The list is filtered.", proof: "test", state: "open"}],
                 notes: [%{event_id: found.id, tag: "discovery", text: "The endpoint pages by 50."}],
                 asks: [%{event_id: child_ask.id, source: "parent", from: family.parent.issue_identifier, text: "Add it."}]
               },
               %{identifier: "NEW-1", state: "Canceled"}
             ]

      assert {:ok, _json} = Jason.encode(facts)
      assert %{junction: "sub_ticket_ended", sub_tickets: [_tracked, _untracked]} = Facts.build(parent, "sub_ticket_ended", token_cap: nil)
      # A ticket with no plan reads as at any other junction.
      assert %{ticket: %{problem: _problem}} = Facts.build(ctx.record, "final_check", token_cap: nil)
    end
  end

  describe "a groomed ticket at the other junctions" do
    setup ctx do
      checks = [
        %{id: "c1", kind: "outcome", statement: "The button signs in.", proof: "test"},
        %{id: "c2", kind: "qa", statement: "The login works.", proof: "qa", state: "Signed out", action: "Click Login", expect: "The home screen"},
        %{id: "c3", kind: "outcome", statement: "The export matches.", proof: "attached"}
      ]

      plan = %{shape: "single", layers: ["screen"], summary: "s", text: "t", checks: checks, size: %{tokens: 1, runs: 1}}
      plan = Map.merge(plan, %{reason: "Grooming", by: "grooming"})
      {:ok, _ask} = TicketPlan.record_ask(ctx.repo, ctx.issue_id, "Make the login button work.")
      {:ok, _plan} = TicketPlan.write(ctx.repo, ctx.issue_id, plan)
      :ok
    end

    test "the ticket is read through its ask and its checks, never its description", ctx do
      {:ok, proof} = SymphonyElixir.TicketChecks.prove(ctx.repo, ctx.issue_id, %{check_id: "c1", by: "test", test: "login_test › signs in"})
      {:ok, _waived} = SymphonyElixir.TicketChecks.waive(ctx.repo, ctx.issue_id, "c3", "No export exists to attach.")
      {:ok, note} = TicketEvents.record(ctx.repo, ctx.issue_id, "note", %{text: "c3 cannot be proved: there is no export."}, actor: {:agent, "run-1", "implementation"}, run_id: "run-1")
      {:ok, _own} = TicketEvents.record(ctx.repo, ctx.issue_id, "note", %{text: "Symphony's own note.", status: true})

      facts = Facts.build(ctx.record, "after_coding", token_cap: nil)

      assert %{problem: "Make the login button work.", acceptance: "[c1] The button signs in.", walkthrough: walkthrough} = facts.ticket
      assert walkthrough =~ "[c2] The login works.\nState: Signed out\nAction: Click Login\nExpect: The home screen"
      assert facts.ticket.proved_steps == [%{step: 1, test: "login_test › signs in", event_id: proof.id}]
      assert facts.ticket.decisions == [%{title: "Scope", answer: "Only the button."}]

      assert facts.checks == [
               %{id: "c1", kind: "outcome", statement: "The button signs in.", proof: "test", state: "proved"},
               %{id: "c2", kind: "qa", statement: "The login works.", proof: "qa", state: "open"},
               %{id: "c3", kind: "outcome", statement: "The export matches.", proof: "attached", state: "waived", waived: "No export exists to attach."}
             ]

      assert [%{event_id: id, run_id: "run-1", text: "c3 cannot be proved: there is no export."}] = facts.check_notes
      assert id == note.id
      assert facts.waive =~ "waive it"
    end

    test "a ticket with no plan holds none of it", ctx do
      ungroomed = %{ctx.record | issue_id: ctx.issue_id <> "-plain"}
      :ok = RunStore.put_ticket_state(ungroomed)
      facts = Facts.build(ungroomed, "after_coding", token_cap: nil)
      assert facts.ticket.problem == "The login button does nothing."
      refute Map.has_key?(facts, :checks)
      refute Map.has_key?(facts, :waive)
    end

    test "at message the document is the conversation's, and a ticket with no plan reads as at any other junction", ctx do
      assert %{conversation: [%{kind: "ask", text: "Make the login button work."}], plan: %{summary: "s"}, ticket: ticket} = Facts.build(ctx.record, "message", token_cap: nil, records: [])
      refute Map.has_key?(ticket, :parent)
      assert %{ticket: %{parent: "FACT-1"}} = Facts.build(Map.put(ctx.record, :parent, %{identifier: "FACT-1"}), "child_message", token_cap: nil, records: [])

      ungroomed = %{ctx.record | issue_id: ctx.issue_id <> "-plain"}
      assert %{ticket: %{problem: _problem}} = Facts.build(ungroomed, "message", token_cap: nil)
    end
  end
end
