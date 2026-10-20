defmodule SymphonyElixir.TicketSignalsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TicketSignals

  @repo_key "repo-a"

  setup do
    :ok = RunStore.clear()
  end

  test "records a signal in the ticket's ledger" do
    assert :ok = TicketSignals.record(@repo_key, "issue-1", "handoff", %{to: "Code Review"})

    assert %{signals: [%{name: "handoff", details: %{to: "Code Review"}}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")
  end

  test "records a signal with no details" do
    assert :ok = TicketSignals.record(@repo_key, "issue-1", "merge settled", %{})

    assert %{signals: [%{name: "merge settled", details: %{}}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")
  end

  test "records a verdict bound to the head it judged" do
    assert :ok = TicketSignals.record_verdict(@repo_key, "issue-1", "qa", "abc123", "pass")

    assert %{verdicts: [%{kind: "qa", head_sha: "abc123", outcome: "pass"}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")
  end

  test "records the details a verdict carries" do
    assert :ok = TicketSignals.record_verdict(@repo_key, "issue-1", "qa", "abc123", "blocked", %{reason: "no emulator", model: "claude-opus"})

    assert %{verdicts: [%{outcome: "blocked", details: %{reason: "no emulator", model: "claude-opus"}}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")
  end

  test "no-ops when the ticket carries no repo key" do
    assert :ok = TicketSignals.record(nil, "issue-1", "handoff", %{})
    assert :ok = TicketSignals.record(@repo_key, nil, "handoff", %{})
    assert :ok = TicketSignals.record_verdict(nil, "issue-1", "qa", nil, "pass")
    assert :ok = TicketSignals.record_verdict(@repo_key, nil, "qa", nil, "pass")

    assert RunStore.get_ticket_state(@repo_key, "issue-1") == nil
  end

  test "logs and swallows a store failure" do
    log =
      capture_log(fn ->
        assert :ok = TicketSignals.record("  ", "issue-1", "handoff", %{})
        assert :ok = TicketSignals.record_verdict("  ", "issue-1", "qa", nil, "pass")
      end)

    assert log =~ "Failed to record handoff signal"
    assert log =~ "Failed to record qa verdict"
  end
end
