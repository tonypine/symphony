defmodule SymphonyElixir.OperatorStopTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Hold, OperatorStop, Pauses, RunStore, TicketEvents, Workflow}
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-a"
  @issue_id "issue-stop"
  @stopped_at ~U[2026-10-20 08:41:25Z]
  @text "Stopped by you at 2026-10-20 08:41:25 UTC. Unblock runs it again; Restart starts it over from main."

  defmodule FailingStore do
    def list_all_ticket_states, do: {:error, :boom}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue = %Issue{id: @issue_id, identifier: "MT-1", title: "Stopped", state: "Todo"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    :ok = RunStore.clear()
    :ok
  end

  test "the hold is a Blocked hold of its own type that a person lifts" do
    attrs = OperatorStop.hold_attrs(@stopped_at)

    assert attrs.reason == "Stopped by you at 2026-10-20 08:41:25 UTC. Unblock runs it again where it stopped; Restart starts it over from main."
    assert attrs.waits_on == %{type: OperatorStop.hold_type(), keys: []}
    assert OperatorStop.hold?(attrs)
    assert Hold.unblockable?(attrs)
    refute OperatorStop.hold?(%{waits_on: %{type: "access", keys: []}})
    refute OperatorStop.hold?(nil)
  end

  describe "the stop on the ticket's pause" do
    test "mark/3 pauses the ticket on the Director's person reason, which the skip reason reads" do
      refute OperatorStop.held?(@repo_key, @issue_id)
      assert OperatorStop.skip_reason(@repo_key, @issue_id) == nil

      assert :ok = OperatorStop.mark(@repo_key, @issue_id, @stopped_at)

      assert {:ok, %{reasons: [reason], set_by: %{kind: :person, name: "Director"}, since: @stopped_at}} = Pauses.get({:ticket, @repo_key, @issue_id})
      assert %{kind: :person, waits_on: %{action: "unblock"}, text: @text, releasable: true, set_at: @stopped_at} = reason
      assert OperatorStop.held?(@repo_key, @issue_id)
      assert OperatorStop.skip_reason(@repo_key, @issue_id) == @text

      # A second stop on the same pause changes nothing.
      assert :ok = OperatorStop.mark(@repo_key, @issue_id, DateTime.add(@stopped_at, 60))
      assert Pauses.why({:ticket, @repo_key, @issue_id}) == [@text]
    end

    test "a stop joins the pause's other reasons, and only its own reason counts" do
      {:ok, _pause} = Pauses.set({:ticket, @repo_key, @issue_id}, %{kind: :ticket, waits_on: %{identifier: "MT-9"}})
      refute OperatorStop.held?(@repo_key, @issue_id)

      assert :ok = OperatorStop.mark(@repo_key, @issue_id, @stopped_at)
      assert OperatorStop.skip_reason(@repo_key, @issue_id) == @text
      assert Pauses.why({:ticket, @repo_key, @issue_id}) == ["Waiting for MT-9 to finish", @text]
    end

    test "a pause the store refuses is an error" do
      assert {:error, {:invalid_subject, _subject}} = OperatorStop.mark(nil, @issue_id, @stopped_at)
      refute OperatorStop.held?(nil, @issue_id)
    end
  end

  describe "stopped/1" do
    test "lists each ticket of every repo whose pause has the stop's reason, with when it stopped and when its phase was written" do
      phase_at = ~U[2026-10-20 08:00:00Z]
      record = %{repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "MT-1", phase: "Todo", phase_at: phase_at}
      :ok = RunStore.put_ticket_state(record)
      :ok = OperatorStop.mark(@repo_key, @issue_id, @stopped_at)
      {:ok, _pause} = Pauses.set({:ticket, @repo_key, "issue-waiting"}, %{kind: :ticket, waits_on: %{identifier: "MT-9"}})
      :ok = Hold.set(@repo_key, "issue-access", :blocked, %{reason: "Needs a token", waits_on: %{type: "access", keys: []}})
      :ok = OperatorStop.mark("repo-b", "issue-b", @stopped_at)

      assert [
               %{issue_id: "issue-b", repo_key: "repo-b", identifier: nil, stopped_at: @stopped_at, phase_at: nil},
               %{issue_id: @issue_id, repo_key: @repo_key, identifier: "MT-1", stopped_at: @stopped_at, phase_at: ^phase_at}
             ] = Enum.sort_by(OperatorStop.stopped(), & &1.repo_key, :desc)
    end

    test "a store it can't read lists nothing" do
      assert OperatorStop.stopped(FailingStore) == []
    end
  end

  describe "confirm/3" do
    setup do
      stop = %{issue_id: @issue_id, repo_key: @repo_key, identifier: "MT-1", stopped_at: @stopped_at, phase_at: nil}
      %{stop: stop, issue: %Issue{id: @issue_id, state: "Todo"}}
    end

    test "a ticket gone or out of the workflow is cleared", %{stop: stop, issue: issue} do
      assert OperatorStop.confirm(stop, nil, false) == :clear
      assert OperatorStop.confirm(stop, %{issue | state: "Duplicate"}, false) == :clear
    end

    test "an active ticket whose phase was not written since the stop keeps it", %{stop: stop, issue: issue} do
      assert OperatorStop.confirm(stop, issue, true) == :keep
      assert OperatorStop.confirm(%{stop | phase_at: DateTime.add(@stopped_at, -60)}, issue, true) == :keep
      assert OperatorStop.confirm(%{stop | phase_at: @stopped_at}, issue, true) == :keep
      assert OperatorStop.confirm(%{stop | stopped_at: nil, phase_at: @stopped_at}, issue, true) == :keep
    end

    test "a phase written after the stop is a move on the board, which clears it", %{stop: stop, issue: issue} do
      assert OperatorStop.confirm(%{stop | phase_at: DateTime.add(@stopped_at, 1)}, %{issue | state: "In Progress"}, true) == :clear
    end
  end

  describe "the hold beside the pause" do
    test "set_hold writes the stop's hold, and clear_hold clears it with the reason" do
      :ok = OperatorStop.mark(@repo_key, @issue_id, @stopped_at)
      assert :ok = OperatorStop.set_hold(@repo_key, @issue_id, @stopped_at)
      assert %{reason: "Stopped by you at " <> _} = hold = Hold.get(@repo_key, @issue_id, :blocked)
      assert OperatorStop.hold?(hold)

      assert :ok = OperatorStop.clear_hold(@repo_key, @issue_id, by: OperatorStop.director())
      refute Hold.held?(@repo_key, @issue_id, :blocked)
      refute OperatorStop.held?(@repo_key, @issue_id)
      assert {:ok, nil} = Pauses.get({:ticket, @repo_key, @issue_id})

      assert [%{type: "pause.set"}, %{type: "pause.cleared", payload: %{by: %{kind: :person, name: "Director"}}}] =
               @repo_key |> TicketEvents.query(@issue_id) |> Enum.filter(&String.starts_with?(&1.type, "pause."))

      assert :ok = OperatorStop.clear_hold(@repo_key, @issue_id)
    end

    test "another Blocked hold, and another reason, are neither replaced nor cleared" do
      access = %{reason: "Needs a token", waits_on: %{type: "access", keys: []}}
      :ok = Hold.set(@repo_key, @issue_id, :blocked, access)
      {:ok, _pause} = Pauses.set({:ticket, @repo_key, @issue_id}, %{kind: :ticket, waits_on: %{identifier: "MT-9"}})
      :ok = OperatorStop.mark(@repo_key, @issue_id, @stopped_at)

      assert :ok = OperatorStop.set_hold(@repo_key, @issue_id, @stopped_at)
      assert %{reason: "Needs a token"} = Hold.get(@repo_key, @issue_id, :blocked)

      assert :ok = OperatorStop.clear_hold(@repo_key, @issue_id)
      assert %{reason: "Needs a token"} = Hold.get(@repo_key, @issue_id, :blocked)
      assert Pauses.why({:ticket, @repo_key, @issue_id}) == ["Waiting for MT-9 to finish"]
    end

    test "a clear the pause refuses leaves the hold" do
      assert {:error, {:invalid_subject, _subject}} = OperatorStop.clear_hold(nil, @issue_id)
    end
  end
end
