defmodule SymphonyElixir.OperatorStopTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Hold, OperatorStop, RunStore, Workflow}
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-a"
  @issue_id "issue-stop"
  @stopped_at ~U[2026-10-20 08:41:25Z]

  defmodule FailingStore do
    def list_ticket_states(_repo_key), do: {:error, :boom}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue = %Issue{id: @issue_id, identifier: "MT-1", title: "Stopped", state: "Todo"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    :ok = RunStore.clear()
    :ok
  end

  test "a new mark has no confirmed state and no hold yet" do
    assert OperatorStop.mark("MT-1", @repo_key, @stopped_at) ==
             %{identifier: "MT-1", repo_key: @repo_key, stopped_at: @stopped_at, state: nil, held: false}
  end

  test "the hold is a Blocked hold of its own type that a person lifts" do
    attrs = OperatorStop.hold_attrs(OperatorStop.mark("MT-1", @repo_key, @stopped_at))

    assert attrs.reason == "Stopped by you at 2026-10-20 08:41:25 UTC. Unblock runs it again where it stopped; Restart starts it over from main."
    assert attrs.waits_on == %{type: OperatorStop.hold_type(), keys: []}
    assert OperatorStop.hold?(attrs)
    assert Hold.unblockable?(attrs)
    refute OperatorStop.hold?(%{waits_on: %{type: "access", keys: []}})
    refute OperatorStop.hold?(nil)
  end

  test "the skip reason names the stop, then the way on once a poll confirmed it" do
    mark = OperatorStop.mark("MT-1", @repo_key, @stopped_at)

    assert OperatorStop.skip_reason(mark) == "stopped by the operator at 2026-10-20 08:41:25 UTC; waiting for the next poll"

    assert OperatorStop.skip_reason(%{mark | state: "Todo"}) ==
             "stopped by the operator at 2026-10-20 08:41:25 UTC; Unblock or Restart in the Director runs it again"
  end

  describe "confirm/4" do
    setup do
      %{mark: OperatorStop.mark("MT-1", @repo_key, @stopped_at), issue: %Issue{id: @issue_id, state: "Todo"}}
    end

    test "a ticket gone or out of the workflow is cleared", %{mark: mark, issue: issue} do
      assert OperatorStop.confirm(mark, nil, false, false) == :clear
      assert OperatorStop.confirm(%{mark | state: "Todo", held: true}, %{issue | state: "Duplicate"}, false, true) == :clear
    end

    test "the first poll confirms the state; the same state keeps it", %{mark: mark, issue: issue} do
      assert {:keep, %{state: "Todo"} = confirmed} = OperatorStop.confirm(mark, issue, true, false)
      assert OperatorStop.confirm(confirmed, %{issue | state: " todo "}, true, false) == {:keep, confirmed}
    end

    test "a later move on the board clears it", %{mark: mark, issue: issue} do
      assert OperatorStop.confirm(%{mark | state: "Todo"}, %{issue | state: "In Progress"}, true, false) == :clear
      assert OperatorStop.confirm(%{mark | state: "Todo"}, %{issue | state: nil}, true, false) == :clear
    end

    test "a hold a person lifted lifts the mark", %{mark: mark, issue: issue} do
      held = %{mark | held: true, state: "Todo"}
      assert OperatorStop.confirm(held, issue, true, false) == :lifted
      assert OperatorStop.confirm(held, issue, true, true) == {:keep, held}
    end
  end

  describe "the hold in the store" do
    test "set_hold writes the stop's hold, and clear_hold clears it" do
      mark = OperatorStop.mark("MT-1", @repo_key, @stopped_at)

      refute OperatorStop.held?(@repo_key, @issue_id)
      assert :ok = OperatorStop.set_hold(@repo_key, @issue_id, mark)
      assert OperatorStop.held?(@repo_key, @issue_id)
      assert %{reason: "Stopped by you at " <> _} = Hold.get(@repo_key, @issue_id, :blocked)

      assert :ok = OperatorStop.clear_hold(@repo_key, @issue_id)
      refute Hold.held?(@repo_key, @issue_id, :blocked)
      assert :ok = OperatorStop.clear_hold(@repo_key, @issue_id)
    end

    test "another Blocked hold is neither replaced nor cleared" do
      access = %{reason: "Needs a token", waits_on: %{type: "access", keys: []}}
      :ok = Hold.set(@repo_key, @issue_id, :blocked, access)

      assert :ok = OperatorStop.set_hold(@repo_key, @issue_id, OperatorStop.mark("MT-1", @repo_key, @stopped_at))
      assert %{reason: "Needs a token"} = Hold.get(@repo_key, @issue_id, :blocked)

      assert :ok = OperatorStop.clear_hold(@repo_key, @issue_id)
      assert %{reason: "Needs a token"} = Hold.get(@repo_key, @issue_id, :blocked)
    end
  end

  describe "hydrate/2" do
    test "marks each ticket whose Blocked hold is a stop, with its state unconfirmed" do
      :ok = OperatorStop.set_hold(@repo_key, @issue_id, OperatorStop.mark("MT-1", @repo_key, @stopped_at))
      :ok = RunStore.update_ticket_state(@repo_key, @issue_id, %{issue_identifier: "MT-1"})
      :ok = Hold.set(@repo_key, "issue-access", :blocked, %{reason: "Needs a token", waits_on: %{type: "access", keys: []}})
      :ok = RunStore.set_ticket_hold("repo-b", "issue-decision", :needs_decision, %{reason: "Which one?"})

      assert %{@issue_id => %{identifier: "MT-1", repo_key: @repo_key, state: nil, held: true, stopped_at: %DateTime{}}} =
               marks = OperatorStop.hydrate([@repo_key, "repo-b"])

      assert map_size(marks) == 1
    end

    test "a store it can't read marks nothing" do
      assert OperatorStop.hydrate([@repo_key], FailingStore) == %{}
    end
  end
end
