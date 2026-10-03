defmodule SymphonyElixir.BlockedByGateTest do
  use SymphonyElixir.TestSupport

  @states ["Todo", "In Progress", "In Review", "Auto Review", "Merging", "Rework"]

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: @states,
      tracker_terminal_states: ["Done", "Canceled", "Duplicate"]
    )

    :ok
  end

  describe "a Todo ticket with a blocker" do
    for blocker_state <- ["Merging", "In Review", "Auto Review", "Rework", "In Progress", "Backlog"] do
      test "is held while the blocker is #{blocker_state}" do
        issue = todo_blocked_by(blocker("MT-2", unquote(blocker_state)))

        assert Issue.blocked?(issue, terminal_states())
        refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
      end
    end

    for blocker_state <- ["Done", "Canceled", "Duplicate", " done "] do
      test "is dispatched once the blocker is #{inspect(blocker_state)}" do
        issue = todo_blocked_by(blocker("MT-2", unquote(blocker_state)))

        refute Issue.blocked?(issue, terminal_states())
        assert Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
      end
    end

    test "is held by a blocker without a known state" do
      assert Issue.blocked?(todo_blocked_by(%{id: "b", identifier: "MT-2", state: nil}), terminal_states())
      assert Issue.blocked?(todo_blocked_by(:unreadable), terminal_states())
    end

    test "outside Todo, a run already under way is not held by its blockers" do
      issue = %{todo_blocked_by(blocker("MT-2", "Merging")) | state: "In Progress"}

      refute Issue.blocked?(issue, terminal_states())
      assert Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
    end

    test "non-issues are never blocked" do
      assert Issue.open_blockers(%{blocked_by: [blocker("MT-2", "Todo")]}, terminal_states()) == []
      refute Issue.blocked?(%Issue{state: nil, blocked_by: [blocker("MT-2", "Todo")]}, terminal_states())
    end
  end

  describe "a final verification waiting on its gaps" do
    test "stays in Todo, shows in the snapshot with its open blockers, and is dispatched once every gap is Done" do
      gap = blocker("MT-323", "In Progress")
      closed_gap = blocker("MT-314", "Done")

      verification = %Issue{
        todo_blocked_by(gap)
        | id: "verify",
          identifier: "MT-272",
          title: "Final verification: Update from the menu bar",
          blocked_by: [closed_gap, gap]
      }

      other = %Issue{id: "other", identifier: "MT-1", title: "Other", state: "Todo"}
      state = Orchestrator.put_blocked_for_test(orchestrator_state(), [other, verification])

      refute Orchestrator.should_dispatch_issue_for_test(verification, state)

      assert state.blocked == [
               %{
                 issue_id: "verify",
                 identifier: "MT-272",
                 title: "Final verification: Update from the menu bar",
                 state: "Todo",
                 blockers: [%{identifier: "MT-323", state: "In Progress"}]
               }
             ]

      assert snapshot_of(state).blocked == state.blocked

      unreadable = %{verification | blocked_by: [:unreadable]}

      assert [%{blockers: [%{identifier: nil, state: nil}]}] =
               Orchestrator.put_blocked_for_test(state, [unreadable]).blocked

      gap_done = %{verification | blocked_by: [closed_gap, %{gap | state: "Done"}]}
      state = Orchestrator.put_blocked_for_test(state, [other, gap_done])

      assert state.blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(gap_done, state)
    end
  end

  defp todo_blocked_by(blocker) do
    %Issue{id: "issue", identifier: "MT-1", title: "Blocked", state: "Todo", blocked_by: [blocker]}
  end

  defp blocker(identifier, state), do: %{id: "id-" <> identifier, identifier: identifier, state: state}

  defp terminal_states, do: Config.settings!().tracker.terminal_states

  defp snapshot_of(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
  end

  defp orchestrator_state do
    %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
