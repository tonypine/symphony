defmodule SymphonyElixir.ChecksHoldTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ChecksHold, DecisionMove, TicketChecks, TicketEvents, TicketPlan}

  setup do
    n = System.unique_integer([:positive])
    issue_id = "hold-#{n}"
    :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: issue_id, issue_identifier: "HOLD-#{n}", phase: "In Progress"})

    plan = %{shape: "single", layers: ["engine"], summary: "s", text: "t", size: %{tokens: 1, runs: 1}, reason: "Grooming", by: "grooming"}
    checks = [%{id: "c1", kind: "outcome", statement: "The export\n matches.", proof: "test"}, %{id: "c2", kind: "evidence", statement: "A file.", proof: "attached"}]
    {:ok, _plan} = TicketPlan.write("default", issue_id, Map.put(plan, :checks, checks))
    %{issue_id: issue_id, plan: Map.put(plan, :checks, checks)}
  end

  defp run!(issue_id, run_id, kind \\ "implementation") do
    {:ok, _started} = TicketEvents.record("default", issue_id, "run.started", %{run_id: run_id, run_kind: kind}, run_id: run_id)
  end

  defp refused(issue_id, run_id, head \\ "sha-1"), do: ChecksHold.refused("default", issue_id, TicketChecks.open(issue_id), %{run_id: run_id, head: head})

  defp notes(issue_id), do: TicketEvents.query(issue_id, types: ["note"])

  test "a refusal is noted once per run and head, and the first run goes on", ctx do
    run!(ctx.issue_id, "run-1")
    assert refused(ctx.issue_id, "run-1") == :retry
    assert refused(ctx.issue_id, "run-1") == :retry
    assert [%{run_id: "run-1", payload: %{text: text}}] = notes(ctx.issue_id)
    assert text =~ "- [c1] The export matches. (proof: test)"
    assert refused(ctx.issue_id, "run-1", "sha-2") == :retry
    assert length(notes(ctx.issue_id)) == 2
  end

  test "the second coding run in a row that is refused asks the person", ctx do
    run!(ctx.issue_id, "run-1")
    assert refused(ctx.issue_id, "run-1") == :retry
    # A run of another kind in between is not a coding run.
    run!(ctx.issue_id, "run-qa", "qa")
    run!(ctx.issue_id, "run-2", "rework")
    assert refused(ctx.issue_id, "run-2") == :ask
    assert refused(ctx.issue_id, nil) == :ask
  end

  test "a run that was not refused, a new plan version or a waiver in between starts the count again", ctx do
    run!(ctx.issue_id, "run-1")
    assert refused(ctx.issue_id, "run-1") == :retry
    run!(ctx.issue_id, "run-2")
    run!(ctx.issue_id, "run-3")
    assert refused(ctx.issue_id, "run-3") == :retry

    run!(ctx.issue_id, "run-4")
    {:ok, _waived} = TicketChecks.waive("default", ctx.issue_id, "c2", "No file exists.")
    assert refused(ctx.issue_id, "run-4") == :retry

    run!(ctx.issue_id, "run-5")
    assert refused(ctx.issue_id, "run-5") == :ask
    {:ok, _plan} = TicketPlan.write("default", ctx.issue_id, %{ctx.plan | reason: "The ask changed", by: "recalibration"})
    assert refused(ctx.issue_id, "run-5", "sha-3") == :retry
  end

  test "the question names the checks, and waiving them is its option's move", ctx do
    question = ChecksHold.question("HOLD-1", TicketChecks.open(ctx.issue_id), "Code Review")

    assert question.title == "HOLD-1: checks of its plan are still not proved"
    assert question.question =~ "[c1] The export matches. (proof: test); [c2] A file. (proof: attached)"

    assert [%{label: "Send it back for the checks", recommended: true} = back, %{label: "Waive them and pass it on", move: move}, %{label: "Cancel the ticket", move: %{to: "Canceled"}}] =
             question.options

    refute Map.has_key?(back, :move)
    assert %{to: "Code Review", waive: [%{check_id: "c1", reason: reason}, %{check_id: "c2"}]} = move
    assert reason =~ "The person waived it"

    # Picking it records each waiver, then moves the ticket; a check the plan no longer holds is skipped.
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    gone = %{move | waive: move.waive ++ [%{check_id: "c9", reason: "x"}]}
    log = capture_log(fn -> assert DecisionMove.perform("default", ctx.issue_id, gone, issue_identifier: "HOLD-1") == {:ok, "Code Review"} end)
    assert log =~ "Could not waive check c9"
    assert TicketChecks.open(ctx.issue_id) == []
    assert [%{state: :waived, waived: %{reason: ^reason}}, %{state: :waived}] = TicketChecks.list(ctx.issue_id)
  end
end
