defmodule SymphonyElixir.IdleParkSaidTest do
  # TP-1566: the hold's question quotes what the idle run said, read from the ticket's history.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DecisionRequest, IdlePark, Questions, TicketEvents}

  @repo "default"
  @issue_id "issue-said"
  @run_id "run-said"

  test "the hold's why quotes the run's last note and the reason of its last skipped step, in plain words" do
    said = %{note: "Run started in the symphony workspace, but MOT-104 targets the Cycle Android repo", step: "wrong repository"}
    request = IdlePark.hold_question_attrs("MOT-104", "In Progress", 2, said)

    assert request.why =~ "The last 2 turns on MOT-104 made no new commit"
    assert request.why =~ ~s(The run's last note said: "Run started in the symphony workspace, but MOT-104 targets the Cycle Android repo")
    assert request.why =~ ~s(It ended its step saying: "wrong repository".)
    assert DecisionRequest.check(request) == :ok

    # Nothing said: the fixed text alone, as before.
    assert IdlePark.hold_question_attrs("MOT-104", "In Progress", 2).why == IdlePark.hold_question_attrs("MOT-104", "In Progress", 2, %{}).why
    refute IdlePark.hold_question_attrs("MOT-104", "In Progress", 2).why =~ "last note"
    assert IdlePark.hold_question_attrs("MOT-104", "In Progress", 2, %{step: "no code"}).why =~ ~s(\n\nIt ended its step saying: "no code".)
  end

  test "said/2 reads the run's newest agent note and its newest skipped or failed step reason" do
    agent = [actor: {:agent, @run_id, "implementation"}, run_id: @run_id]
    record = fn type, payload, opts -> {:ok, _event} = TicketEvents.record(@repo, @issue_id, type, payload, opts) end

    record.("note", %{text: "an older note"}, agent)
    record.("step.completed", %{step_id: "code", title: "Write the code", mode: "delegated", outcome: "skipped", reason: "wrong `repository`"}, agent)
    record.("step.completed", %{step_id: "code", title: "Write the code", mode: "delegated", outcome: "failed", returns_to: "code"}, agent)
    record.("step.completed", %{step_id: "code", title: "Write the code", mode: "delegated", outcome: "passed"}, agent)
    record.("note", %{text: "The run's  `own` note,\nin plain words"}, agent)
    record.("note", %{text: "Symphony's own note"}, run_id: @run_id)
    record.("note", %{text: "another run's note"}, actor: {:agent, "run-other", "implementation"}, run_id: "run-other")

    assert IdlePark.said(@issue_id, @run_id) == %{note: "The run's own note, in plain words", step: "wrong repository"}
    assert IdlePark.said(@issue_id, "run-other") == %{note: "another run's note"}
    assert IdlePark.said(@issue_id, "run-none") == %{}
    assert IdlePark.said(@issue_id, nil) == %{}
  end

  test "said/2 keeps a long note to its first characters and drops a note with nothing left in plain words" do
    agent = [actor: {:agent, @run_id, "implementation"}, run_id: @run_id]
    {:ok, _event} = TicketEvents.record(@repo, @issue_id, "note", %{text: String.duplicate("word ", 200)}, agent)

    assert %{note: note} = IdlePark.said(@issue_id, @run_id)
    assert String.length(note) == 300
    assert String.ends_with?(note, "…")

    {:ok, _event} = TicketEvents.record(@repo, "issue-blank", "note", %{text: "``"}, agent)
    assert IdlePark.said("issue-blank", @run_id) == %{}
  end

  test "a hold after a run that said why asks the question with the run's words" do
    agent = [actor: {:agent, @run_id, "implementation"}, run_id: @run_id]
    {:ok, _event} = TicketEvents.record(@repo, @issue_id, "note", %{text: "The ticket targets another repository"}, agent)
    ticket = {:ticket, @repo, @issue_id}

    capture_log(fn -> :ok = IdlePark.hold(ticket, "MOT-104", "In Progress", 2, nil, nil, @run_id) end)

    assert [%{why: why}] = Questions.open(ticket)
    assert why =~ ~s(The run's last note said: "The ticket targets another repository".)
  end
end
