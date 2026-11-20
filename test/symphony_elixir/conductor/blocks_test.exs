defmodule SymphonyElixir.Conductor.BlocksTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Artifacts, TicketEvents, TicketState}
  alias SymphonyElixir.Conductor.{Blocks, Facts}

  @png <<137, 80, 78, 71, 13, 10, 26, 10>> <> <<0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1>>

  setup do
    n = System.unique_integer([:positive])
    issue_id = "issue-blocks-#{n}"
    record = %{repo_key: "default", issue_id: issue_id, issue_identifier: "BLK-#{n}", phase: "QA", title: "Fix login", description: "x"}
    :ok = RunStore.put_ticket_state(record)
    %{issue_id: issue_id, record: record}
  end

  defp record!(ctx, type, payload, opts \\ []) do
    {:ok, event} = TicketEvents.record("default", ctx.issue_id, type, payload, opts)
    event
  end

  defp keep!(ctx, kind, name, bytes) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    {:ok, %{id: id}} = Artifacts.ingest(path, %{repo_key: "default", issue_id: ctx.issue_id, kind: kind, label: name})
    id
  end

  defp context(ctx, overrides) do
    base = %{
      record: TicketState.normalize(ctx.record),
      events: Facts.events(ctx.issue_id),
      budget: %{tokens_used: 1_750, tokens_cap: 5_000},
      default_run_id: "run-1",
      now: DateTime.utc_now()
    }

    Map.merge(base, overrides)
  end

  defp resolve(ctx, picks, overrides \\ %{}), do: Blocks.resolve(picks, context(ctx, overrides))

  defp agent(run_id, kind), do: {:agent, run_id, kind}

  test "steps: the run's newest steps with how each ended, skipping paused ones", ctx do
    record!(ctx, "run.started", %{run_id: "run-1", run_kind: "implementation"}, run_id: "run-1")
    failed = %{step_id: "build", title: "Build", mode: "machine", outcome: "failed", returns_to: "code", returns_to_title: "Code"}
    record!(ctx, "step.completed", Map.put(failed, :duration_ms, 4_000), run_id: "run-1")
    record!(ctx, "step.completed", %{step_id: "lint", title: "Lint", mode: "machine", outcome: "passed"}, run_id: "run-1")
    record!(ctx, "step.completed", %{step_id: "ask", title: "Ask", mode: "machine", outcome: "paused", question_id: "q"}, run_id: "run-1")
    record!(ctx, "step.completed", %{step_id: "other", title: "Other", mode: "machine", outcome: "passed"}, run_id: "run-2")

    assert [%{type: "steps", run_id: "run-1", run_kind: "implementation", steps: steps}] = resolve(ctx, [%{type: "steps"}])

    assert steps == [
             %{step_id: "build", title: "Build", outcome: "failed", duration_ms: 4_000, returns_to: "code"},
             %{step_id: "lint", title: "Lint", outcome: "passed"}
           ]

    assert [%{run_id: "run-2", run_kind: nil}] = resolve(ctx, [%{type: "steps", run_id: "run-2"}])

    picks = [%{type: "steps", run_id: "run-9"}, %{type: "steps"}]
    log = capture_log(fn -> assert resolve(ctx, picks, %{default_run_id: nil}) == [] end)
    assert log =~ "Conductor dropped a steps block"
  end

  test "steps keeps the newest 8", ctx do
    for n <- 1..10, do: record!(ctx, "step.completed", %{step_id: "s#{n}", title: "S#{n}", mode: "machine", outcome: "passed"}, run_id: "run-1")
    assert [%{steps: steps}] = resolve(ctx, [%{type: "steps"}])
    assert Enum.map(steps, & &1.step_id) == Enum.map(3..10, &"s#{&1}")
  end

  test "evidence: the screenshot each event carries, captioned; events without one are dropped", ctx do
    shot = keep!(ctx, "screenshot", "shot", @png)
    log = keep!(ctx, "log", "log", "text")
    with_shot = record!(ctx, "evidence", %{caption: "The login page after the click"}, actor: agent("run-1", "qa"), artifacts: [log, shot])
    without = record!(ctx, "evidence", %{caption: "Only a log"}, actor: agent("run-1", "qa"), artifacts: [log])

    long = "A very long description " <> String.duplicate("x", 100)

    finding = record!(ctx, "finding.recorded", %{class: "login", severity: "high", description: long}, actor: agent("run-1", "qa"), artifacts: [shot])

    assert [%{type: "evidence", items: items}] = resolve(ctx, [%{type: "evidence", refs: [with_shot.id, without.id, "missing", finding.id]}])

    assert [%{event_id: id1, artifact_id: ^shot, caption: "The login page after the click"}, second] = items
    assert %{event_id: id2, artifact_id: ^shot, caption: caption} = second
    assert {id1, id2} == {with_shot.id, finding.id}
    assert String.length(caption) <= 80 + String.length(" [cut by Symphony]")

    capture_log(fn -> assert resolve(ctx, [%{type: "evidence", refs: [without.id]}]) == [] end)
  end

  test "compare: text sides, and screenshot sides from evidence events", ctx do
    shot = keep!(ctx, "screenshot", "shot", @png)
    event = record!(ctx, "evidence", %{caption: "Result"}, actor: agent("run-1", "qa"), artifacts: [shot])

    assert [%{type: "compare", expected: %{text: "A list"}, actual: %{event_id: id, artifact_id: ^shot}}] =
             resolve(ctx, [%{type: "compare", expected: %{text: "A list"}, actual: %{ref: event.id}}])

    assert id == event.id

    capture_log(fn -> assert resolve(ctx, [%{type: "compare", expected: %{text: "A"}, actual: %{ref: "missing"}}]) == [] end)
    capture_log(fn -> assert resolve(ctx, [%{type: "compare", expected: %{ref: "missing"}, actual: %{text: "A"}}]) == [] end)
  end

  test "budget: tokens by kind of run, largest first, with the cap when there is one", ctx do
    for {id, kind, tokens} <- [{"r1", "implementation", 1_000}, {"r2", "qa", %{total_tokens: 500}}, {"r3", "qa", 250}, {"r4", nil, 0}] do
      payload = %{run_id: id, exit: "normal", tokens: tokens} |> then(&if(kind, do: Map.put(&1, :run_kind, kind), else: &1))
      record!(ctx, "run.ended", payload, run_id: id)
    end

    assert [%{type: "budget", tokens_used: 1_750, tokens_cap: 5_000, parts: parts}] = resolve(ctx, [%{type: "budget"}])

    assert parts == [
             %{kind: "implementation", runs: 1, tokens: 1_000},
             %{kind: "qa", runs: 2, tokens: 750},
             %{kind: "other", runs: 1, tokens: 0}
           ]

    assert [block] = resolve(ctx, [%{type: "budget"}], %{budget: %{tokens_used: 1_750, tokens_cap: nil}})
    refute Map.has_key?(block, :tokens_cap)
  end

  test "budget is dropped when no run has ended", ctx do
    capture_log(fn -> assert resolve(ctx, [%{type: "budget"}]) == [] end)
  end

  test "path: each phase once in the order of its last visit, the loops and the phases ahead", ctx do
    record!(ctx, "phase.entered", %{to: "In Progress"})
    record!(ctx, "phase.entered", %{to: "Code Review", from: "In Progress"})
    record!(ctx, "phase.entered", %{to: "QA", from: "Code Review"})
    record!(ctx, "run.started", %{run_id: "q1", run_kind: "qa", state: "QA", run_number: 1}, run_id: "q1")
    record!(ctx, "run.started", %{run_id: "q2", run_kind: "qa", state: "QA", run_number: 2}, run_id: "q2")
    record!(ctx, "phase.entered", %{to: "Rework", from: "QA"})
    record!(ctx, "phase.entered", %{to: "QA", from: "Rework"})

    assert [%{type: "path", stops: stops, loops: 1, elapsed_ms: elapsed}] = resolve(ctx, [%{type: "path"}])
    assert is_integer(elapsed) and elapsed >= 0

    assert stops == [
             %{phase: "In Progress", state: "done", times: 1},
             %{phase: "Code Review", state: "done", times: 1},
             %{phase: "Rework", state: "done", times: 1},
             %{phase: "QA", state: "current", times: 2, run_number: 2},
             %{phase: "Merging", state: "upcoming", times: 0},
             %{phase: "Done", state: "upcoming", times: 0}
           ]
  end

  test "path: QA that passed after seven blocked passes reads done at Merging and at Done", ctx do
    record!(ctx, "phase.entered", %{to: "In Progress"})
    record!(ctx, "phase.entered", %{to: "Code Review", from: "In Progress"})
    record!(ctx, "verdict.recorded", %{kind: "code_review", outcome: "approve", head: "h0"})
    record!(ctx, "phase.entered", %{to: "QA", from: "Code Review"})

    for n <- 1..7 do
      record!(ctx, "run.started", %{run_id: "q#{n}", run_kind: "qa", state: "QA", run_number: n}, run_id: "q#{n}")
      record!(ctx, "verdict.recorded", %{kind: "qa", outcome: "blocked", head: "h#{n}"})

      if n == 4 do
        record!(ctx, "phase.entered", %{to: "Rework", from: "QA"})
        record!(ctx, "phase.entered", %{to: "Code Review", from: "Rework"})
        record!(ctx, "verdict.recorded", %{kind: "code_review", outcome: "approve", head: "h4b"})
        record!(ctx, "phase.entered", %{to: "QA", from: "Code Review"})
      end
    end

    record!(ctx, "run.started", %{run_id: "q8", run_kind: "qa", state: "QA", run_number: 8}, run_id: "q8")
    record!(ctx, "verdict.recorded", %{kind: "qa", outcome: "pass", head: "h8"})
    record!(ctx, "phase.entered", %{to: "Merging", from: "QA"})

    merging = %{record: %{TicketState.normalize(ctx.record) | phase: "Merging"}}
    assert [%{stops: stops, loops: 1}] = resolve(ctx, [%{type: "path"}], merging)
    assert Enum.find(stops, &(&1.phase == "QA")) == %{phase: "QA", state: "done", times: 2, run_number: 8}
    assert Enum.map(stops, &{&1.phase, &1.state}) == [{"In Progress", "done"}, {"Rework", "done"}, {"Code Review", "done"}, {"QA", "done"}, {"Merging", "current"}, {"Done", "upcoming"}]

    record!(ctx, "phase.entered", %{to: "Done", from: "Merging"})
    done = %{record: %{TicketState.normalize(ctx.record) | phase: "Done"}}
    assert [%{stops: stops}] = resolve(ctx, [%{type: "path"}], done)
    assert Enum.find(stops, &(&1.phase == "QA")) == %{phase: "QA", state: "done", times: 2, run_number: 8}
    assert List.last(stops) == %{phase: "Done", state: "done", times: 1}
  end

  test "path: QA whose last verdict failed or blocked reads failed, and a skipped QA reads done", ctx do
    record!(ctx, "phase.entered", %{to: "QA"})
    record!(ctx, "verdict.recorded", %{kind: "qa", outcome: "pass", head: "h1"})
    record!(ctx, "verdict.recorded", %{kind: "qa", outcome: "fail", head: "h2"})
    record!(ctx, "phase.entered", %{to: "Rework", from: "QA"})
    assert [%{stops: [%{phase: "QA", state: "failed"}, %{phase: "Rework", state: "current"} | _ahead]}] = resolve(ctx, [%{type: "path"}])

    record!(ctx, "phase.entered", %{to: "QA", from: "Rework"})
    record!(ctx, "verdict.recorded", %{kind: "qa", outcome: "blocked", head: "h3"})
    record!(ctx, "phase.entered", %{to: "CI Fix", from: "QA"})
    [%{stops: stops}] = resolve(ctx, [%{type: "path"}])
    assert [%{phase: "Rework"}, %{phase: "QA", state: "failed", times: 2}, %{phase: "CI Fix", state: "current"} | _ahead] = stops

    record!(ctx, "phase.entered", %{to: "QA", from: "CI Fix"})
    record!(ctx, "verdict.recorded", %{kind: "qa", outcome: "skip", head: "h4"})
    record!(ctx, "verdict.recorded", %{kind: "qa", outcome: "fail", head: "h4", signal: "qa verdict"})
    record!(ctx, "phase.entered", %{to: "Merging", from: "QA"})
    assert [%{stops: stops}] = resolve(ctx, [%{type: "path"}])
    assert Enum.find(stops, &(&1.phase == "QA")) == %{phase: "QA", state: "done", times: 3}
  end

  test "path: Code Review reads failed when sent back, and done once a later visit approves", ctx do
    record!(ctx, "phase.entered", %{to: "Code Review"})
    record!(ctx, "phase.entered", %{to: "Rework", from: "Code Review"})
    [%{stops: stops}] = resolve(ctx, [%{type: "path"}])
    assert [%{phase: "Code Review", state: "failed"}, %{phase: "Rework", state: "current"} | _ahead] = stops

    record!(ctx, "phase.entered", %{to: "Code Review", from: "Rework"})
    record!(ctx, "verdict.recorded", %{kind: "code_review", outcome: "request_changes", head: "h1"})
    record!(ctx, "phase.entered", %{to: "Rework", from: "Code Review"})
    [%{stops: stops}] = resolve(ctx, [%{type: "path"}])
    assert [%{phase: "Code Review", state: "failed", times: 2}, %{phase: "Rework", state: "current", times: 2} | _ahead] = stops

    record!(ctx, "phase.entered", %{to: "Code Review", from: "Rework"})
    record!(ctx, "verdict.recorded", %{kind: "code_review", outcome: "approve", head: "h2"})
    record!(ctx, "phase.entered", %{to: "QA", from: "Code Review"})

    assert [%{stops: stops, loops: 2}] = resolve(ctx, [%{type: "path"}])
    assert [%{phase: "Rework", state: "done"}, %{phase: "Code Review", state: "done", times: 3}, %{phase: "QA", state: "current"} | _ahead] = stops
  end

  test "path: a repeated phase folds, a ticket in Rework goes on from coding, a finished one has nothing ahead", ctx do
    entered = for to <- ["Rework", "Rework", "Done"], do: record!(ctx, "phase.entered", %{to: to}, at: DateTime.utc_now())

    assert [%{stops: [%{phase: "Rework", times: 2, state: "done"}, %{phase: "Done", state: "done", times: 1}], loops: 2}] =
             resolve(ctx, [%{type: "path"}], %{record: %{TicketState.normalize(ctx.record) | phase: "Done"}})

    assert length(entered) == 3
  end

  test "path: a ticket in Rework has the whole normal path ahead, and no phase means no path", ctx do
    capture_log(fn -> assert resolve(ctx, [%{type: "path"}]) == [] end)
    record!(ctx, "phase.entered", %{to: "Rework"})
    assert [%{stops: [%{phase: "Rework", state: "current"}, %{phase: "Code Review", state: "upcoming"} | _rest]}] = resolve(ctx, [%{type: "path"}])
    record!(ctx, "phase.entered", %{to: "CI Fix"})
    assert [%{stops: [_rework, _ci_fix | ahead]}] = resolve(ctx, [%{type: "path"}])
    assert hd(ahead).phase == "Code Review"
  end

  test "path: a ticket that never met the normal path has nothing ahead", ctx do
    record!(ctx, "phase.entered", %{to: "Backlog"})
    assert [%{stops: [%{phase: "Backlog", state: "current"}]}] = resolve(ctx, [%{type: "path"}])
  end

  test "attempts: the tries of one step with the last error-looking line of each output", ctx do
    first = keep!(ctx, "step_output", "o1", "compiling\nerror: undefined function foo/0\ndone\n")
    second = keep!(ctx, "step_output", "o2", "compiling\nerror: undefined function foo/0\n\n")
    third = keep!(ctx, "step_output", "o3", "all fine\nlast line\n")
    base = %{step_id: "build", title: "Build", mode: "machine"}

    record!(ctx, "step.completed", Map.merge(base, %{outcome: "failed", returns_to: "code", duration_ms: 10}), run_id: "run-1", artifacts: [first])
    record!(ctx, "step.completed", Map.merge(base, %{outcome: "failed", returns_to: "code"}), run_id: "run-1", artifacts: [second])
    record!(ctx, "step.completed", Map.merge(base, %{outcome: "passed"}), run_id: "run-1", artifacts: [third])
    record!(ctx, "step.completed", %{step_id: "lint", title: "Lint", mode: "machine", outcome: "passed"}, run_id: "run-1")

    picks = [%{type: "attempts", step_id: "build"}]
    assert [%{type: "attempts", run_id: "run-1", step_id: "build", title: "Build", tries: tries, same_line: true}] = resolve(ctx, picks)
    assert [%{outcome: "failed", duration_ms: 10, line: "error: undefined function foo/0", at: at}, %{outcome: "failed"}, %{outcome: "passed", line: "last line"}] = tries
    assert {:ok, _at, 0} = DateTime.from_iso8601(at)

    capture_log(fn ->
      assert resolve(ctx, [%{type: "attempts", step_id: "nope"}], %{}) == []
      assert resolve(ctx, [%{type: "attempts", step_id: "build"}], %{default_run_id: nil}) == []
    end)
  end

  test "attempts: different failing lines are not the same line, and a try with no output has none", ctx do
    a = keep!(ctx, "step_output", "a", "error: one\n")
    b = keep!(ctx, "step_output", "b", "error: two\n")
    base = %{step_id: "build", title: "Build", mode: "machine", outcome: "failed", returns_to: "code"}
    record!(ctx, "step.completed", base, run_id: "run-1", artifacts: [a])
    record!(ctx, "step.completed", base, run_id: "run-1", artifacts: [b])
    record!(ctx, "step.completed", base, run_id: "run-1", artifacts: ["missing"])

    assert [%{same_line: false, tries: [_one, _two, third]}] = resolve(ctx, [%{type: "attempts", step_id: "build"}])
    refute Map.has_key?(third, :line)
  end

  test "findings: open first, with the first sentence as the title and the counts", ctx do
    first = record!(ctx, "finding.recorded", %{class: "login", severity: "high", description: "The button does nothing.  Second sentence."}, actor: agent("run-1", "qa"))
    record!(ctx, "finding.recorded", %{class: "layout", severity: "low", description: String.duplicate("long ", 40)}, actor: agent("run-1", "qa"))
    record!(ctx, "finding.resolved", %{finding_id: first.id, how: "Wired it.", head: "abc123"}, actor: agent("run-2", "rework"))

    assert [%{type: "findings", items: [open, resolved], open: 1, resolved: 1}] = resolve(ctx, [%{type: "findings"}])
    assert %{state: "open", severity: "low", title: title} = open
    assert String.length(title) == 100 and String.ends_with?(title, "…")
    assert %{id: id, state: "resolved", severity: "high", title: "The button does nothing."} = resolved
    assert id == first.id

    capture_log(fn -> assert resolve(ctx, [%{type: "findings"}], %{events: []}) == [] end)
  end

  test "findings keeps at most 8", ctx do
    for n <- 1..10, do: record!(ctx, "finding.recorded", %{class: "c#{n}", severity: "low", description: "Problem #{n}."}, actor: agent("run-1", "qa"))
    assert [%{items: items, open: 10, resolved: 0}] = resolve(ctx, [%{type: "findings"}])
    assert length(items) == 8
  end

  test "epic: the parent and the sub-tickets Symphony holds, this one marked", ctx do
    parent = %{identifier: "EPIC-1", title: "Sign in", done: 1, total: 3, children: []}
    mine = Map.put(ctx.record, :parent, parent)
    :ok = RunStore.put_ticket_state(mine)

    sibling_id = "issue-sibling-#{System.unique_integer([:positive])}"
    identifier = "AAA-#{System.unique_integer([:positive])}"
    sibling = %{repo_key: "default", issue_id: sibling_id, issue_identifier: identifier, phase: "Done", title: "Sibling", parent: parent}
    :ok = RunStore.put_ticket_state(sibling)

    resolved = resolve(ctx, [%{type: "epic"}], %{record: TicketState.normalize(mine)})
    assert [%{type: "epic", identifier: "EPIC-1", title: "Sign in", rows: rows}] = resolved
    assert Enum.count(rows, & &1.current) == 1
    assert %{state: "QA", title: "Fix login"} = Enum.find(rows, & &1.current)
    assert %{state: "Done", title: "Sibling", current: false} = Enum.find(rows, &(&1.title == "Sibling"))

    capture_log(fn -> assert resolve(ctx, [%{type: "epic"}]) == [] end)
  end

  test "epic: a parent without a title uses its identifier, and this ticket is a row even when unrecorded", ctx do
    record = %{TicketState.normalize(ctx.record) | parent: %{identifier: "EPIC-2", title: nil, done: 0, total: 1, children: []}, issue_id: "unrecorded-#{ctx.issue_id}"}
    assert [%{title: "EPIC-2", rows: [%{current: true, title: "Fix login"}]}] = resolve(ctx, [%{type: "epic"}], %{record: record})
  end

  test "question: the decision the request opened, with its options", ctx do
    record!(ctx, "question.asked", %{
      question_id: "q-1",
      title: "Keep going?",
      question: "Should the run go on?",
      options: [%{label: "Go on", effect: "It goes on.", recommended: true}, %{"label" => "Stop", "effect" => "It stops."}, %{effect: "no label"}]
    })

    events = Facts.events(ctx.issue_id)

    assert Blocks.question(events, %{title: "Keep going?"}) ==
             %{
               type: "question",
               decision_id: "q-1",
               title: "Keep going?",
               question: "Should the run go on?",
               options: [%{label: "Go on", recommended: true}, %{label: "Stop", recommended: false}]
             }

    assert Blocks.question(events, %{title: "Another"}) == nil
  end
end
