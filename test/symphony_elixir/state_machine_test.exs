defmodule SymphonyElixir.StateMachineTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StateMachine

  describe "active_states/1" do
    test "adds the dispatchable phase states to the configured active states, deduplicated, but never Plan Review" do
      settings = %{
        tracker: %{active_states: ["Todo", "In Progress", "Code Review"]},
        code_review_state: "Code Review",
        qa_state: "QA",
        plan_review_state: "Plan Review",
        epic_review_state: "Epic Review",
        ci_fix_state: "CI Fix"
      }

      assert StateMachine.active_states(settings) ==
               ["Todo", "In Progress", "Code Review", "QA", "Epic Review", "CI Fix"]
    end

    test "never dispatches from Plan Review, even when the active states name it" do
      tracker = %{active_states: ["Todo", " plan review "], plan_review_state: "Plan Review", qa_state: "QA"}

      assert StateMachine.active_states(%{tracker: tracker}) == ["Todo", "QA"]
      assert StateMachine.tracker_active_states(tracker) == ["Todo", "QA"]
      assert StateMachine.tracker_active_states(%{tracker | plan_review_state: nil}) == ["Todo", " plan review ", "QA"]
    end

    test "reads string-keyed active states" do
      assert StateMachine.active_states(%{"tracker" => %{"active_states" => ["Todo"]}}) == ["Todo"]
    end

    test "a settings without a tracker has no base active states" do
      assert StateMachine.active_states(%{qa_state: "QA"}) == ["QA"]
    end

    test "settings that are not a map yield no states" do
      assert StateMachine.active_states(nil) == []
      assert StateMachine.phase_states(nil) == []
    end

    test "the runtime settings dispatch from the default phase states" do
      assert StateMachine.active_states(Config.settings!()) ==
               ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]
    end
  end

  describe "phase_states/1" do
    test "reads the dispatchable phase states, dropping blank and missing ones" do
      settings = %{
        code_review_state: "Code Review",
        qa_state: "QA",
        plan_review_state: "Plan Review",
        epic_review_state: "  ",
        ci_fix_state: "CI Fix"
      }

      assert StateMachine.phase_states(settings) == ["Code Review", "QA", "CI Fix"]
    end
  end

  describe "phases/1" do
    test "lists the runtime settings' phases once each, in board order, with whether entering one dispatches a run" do
      assert StateMachine.phases(Config.settings!()) == [
               %{name: "Backlog", dispatches: false},
               %{name: "Todo", dispatches: true},
               %{name: "In Progress", dispatches: true},
               %{name: "Code Review", dispatches: true},
               %{name: "QA", dispatches: true},
               %{name: "Plan Review", dispatches: false},
               %{name: "Epic Review", dispatches: true},
               %{name: "Waiting on sub-tickets", dispatches: false},
               %{name: "CI Fix", dispatches: true},
               %{name: "Done", dispatches: false},
               %{name: "Canceled", dispatches: false},
               %{name: "Cancelled", dispatches: false},
               %{name: "Closed", dispatches: false},
               %{name: "Duplicate", dispatches: false}
             ]
    end

    test "names a renamed phase state as configured, places unknown states, and leaves out one turned off" do
      settings = %{
        tracker: %{
          active_states: ["Rework", "Todo", "Shaping", "Merging", "In Progress", "todo"],
          terminal_states: ["Won't Do", "Done"],
          waiting_on_sub_issues_state: nil
        },
        code_review_state: "Peer Review",
        qa_state: nil,
        plan_review_state: "Plan Review",
        epic_review_state: "Epic Review",
        ci_fix_state: "Red Checks"
      }

      assert StateMachine.phases(settings) == [
               %{name: "Backlog", dispatches: false},
               %{name: "Todo", dispatches: true},
               %{name: "In Progress", dispatches: true},
               %{name: "Peer Review", dispatches: true},
               %{name: "Merging", dispatches: true},
               %{name: "Rework", dispatches: true},
               %{name: "Plan Review", dispatches: false},
               %{name: "Epic Review", dispatches: true},
               %{name: "Red Checks", dispatches: true},
               %{name: "Shaping", dispatches: true},
               %{name: "Done", dispatches: false},
               %{name: "Won't Do", dispatches: false}
             ]
    end
  end
end
