defmodule SymphonyElixir.Situation.RecorderTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.Situation.Recorder
  alias SymphonyElixir.{Pauses, TicketEvents}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @repo "default"
  @id "issue-1"
  @server :situation_recorder_test
  @at ~U[2026-10-30 09:00:00Z]

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: @id, issue_identifier: "TP-1", phase: "Todo"})
    :ok
  end

  defp start do
    pid = start_supervised!({Recorder, name: @server})
    settle(pid)
    pid
  end

  # The notice in its mailbox, then the flush it queued behind it.
  defp settle(pid) do
    :sys.get_state(pid)
    :sys.get_state(pid)
    :ok
  end

  defp snapshot(pid, overrides \\ %{}) do
    Recorder.snapshot_published(Map.merge(%{running: [], retrying: [], slot_waiting: [], dispatch_skipped: []}, overrides), pid)
    settle(pid)
  end

  defp kinds(issue_id \\ @id), do: for(%{payload: payload} <- TicketEvents.query(issue_id, types: ["situation.changed"], limit: :all), do: payload.to)

  test "from its start it computes every ticket not yet ended, once it has a snapshot" do
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "shipped", issue_identifier: "TP-2", phase: "Done"})
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "no-phase", issue_identifier: "TP-3"})
    pid = start()

    assert kinds() == []

    snapshot(pid)

    assert kinds() == ["waiting_for_slot"]
    assert kinds("no-phase") == ["waiting_for_slot"]
    assert kinds("shipped") == []
  end

  test "an event on the ledger is a reason to compute the ticket again, and its own event is not" do
    pid = start()
    snapshot(pid)

    {:ok, _pause} = Pauses.add_reason({:ticket, @repo, @id}, Pauses.ticket_reason(:dependency, "TP-9"), at: @at)
    settle(pid)

    assert kinds() == ["waiting_for_slot", "blocked_by_ticket"]

    send(pid, {:ticket_event, %{type: "situation.changed", issue_id: "unknown"}})
    settle(pid)
    assert %{dirty: dirty} = :sys.get_state(pid)
    assert MapSet.size(dirty) == 0
  end

  test "a record's change is a reason too, and a ticket with no record is left" do
    pid = start()
    snapshot(pid)

    :ok = RunStore.update_ticket_state(@id, %{phase: "Backlog"})
    ObservabilityPubSub.broadcast_ticket_record_changed(@repo, @id, [:phase])
    ObservabilityPubSub.broadcast_ticket_record_changed(@repo, "unknown", [:phase])
    settle(pid)

    assert kinds() == ["waiting_for_slot", "paused_by_rule"]
    assert kinds("unknown") == []
  end

  test "the watcher's read of a pending head is a reason too" do
    pid = start()
    snapshot(pid)

    :ok = RunStore.put_ticket_pr_watch(@repo, @id, "TP-1", %{facts: %Facts{phase: :code_review, ci: :pending, pr: :open, pr_number: 741}})
    Recorder.ticket_changed(@id, pid)
    settle(pid)

    assert kinds() == ["waiting_for_slot", "waiting_for_ci"]
  end

  test "a snapshot computes only the tickets whose facts changed, and writes each change once" do
    pid = start()
    snapshot(pid)
    run = %{running: [%{issue_id: @id, run_kind: "implementation", started_at: @at}]}

    snapshot(pid, run)
    snapshot(pid, run)
    assert kinds() == ["waiting_for_slot", "working"]

    snapshot(pid)
    assert kinds() == ["waiting_for_slot", "working", "waiting_for_slot"]
  end

  test "a write the ledger refuses is logged and the recorder goes on" do
    pid = start()
    snapshot(pid)
    step = %{id: String.duplicate("x", 400), title: "Long"}

    log = capture_log(fn -> snapshot(pid, %{running: [%{issue_id: @id, run_kind: "qa", started_at: @at, step: step}]}) end)

    assert log =~ "situation not recorded: issue_id=#{@id} issue_identifier=TP-1"
    assert Process.alive?(pid)
    assert kinds() == ["waiting_for_slot"]
  end

  test "any other message is ignored" do
    pid = start()
    send(pid, :something_else)
    settle(pid)

    assert Process.alive?(pid)
  end

  test "with no recorder running a notice is nothing" do
    assert Recorder.ticket_changed(@id, :no_recorder) == :ok
    assert Recorder.snapshot_published(%{}, :no_recorder) == :ok
  end
end
