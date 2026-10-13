defmodule SymphonyElixir.StateMachineTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{Schema, SystemSchema}
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

    test "reads a string-keyed tracker" do
      assert StateMachine.active_states(%{"tracker" => %{"active_states" => ["Todo"]}}) == ["Todo"]
    end

    test "a settings without a tracker has no base active states" do
      assert StateMachine.active_states(%{qa_state: "QA"}) == ["QA"]
    end

    test "settings that are not a map yield no states" do
      assert StateMachine.active_states(nil) == []
      assert StateMachine.phase_states(nil) == []
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

  describe "the retired repositories[].state_machine key" do
    defp symphony(repo_fields) do
      %{
        "issues" => %{"provider" => "memory"},
        "agent" => %{"runtime" => "claude", "command" => "claude --dangerously-skip-permissions"},
        "repositories" => [
          Map.merge(%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}, repo_fields)
        ]
      }
    end

    test "still loads, whatever its value, and warns that it does nothing" do
      for value <- ["legacy", "designed", "sideways"] do
        log =
          capture_log(fn ->
            assert {:ok, system} = SystemSchema.parse(symphony(%{"state_machine" => value}))
            refute Map.has_key?(hd(system.repos), :state_machine)
            assert {:ok, settings} = Schema.parse(SystemSchema.to_config_map(system))
            refute Map.has_key?(settings, :state_machine)
          end)

        assert log =~ "`repositories[app].state_machine` is deprecated and has no effect"
      end
    end

    test "a repository without it loads without the warning" do
      log = capture_log(fn -> assert {:ok, _system} = SystemSchema.parse(symphony(%{"base_branch" => "trunk"})) end)

      refute log =~ "state_machine"
    end
  end
end
