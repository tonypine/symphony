defmodule SymphonyElixir.StateMachineTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.StateMachine

  describe "versions" do
    test "lists the known versions in display order and the default" do
      assert StateMachine.versions() == ["legacy", "designed"]
      assert StateMachine.default_version() == "legacy"
    end
  end

  describe "version/1" do
    test "defaults to legacy for nil, an empty map and an unknown value" do
      assert StateMachine.version(nil) == "legacy"
      assert StateMachine.version(%{}) == "legacy"
      assert StateMachine.version(%{state_machine: "sideways"}) == "legacy"
      assert StateMachine.version(%{state_machine: 5}) == "legacy"
    end

    test "reads the value from a string- or atom-keyed map, trimmed and case-folded" do
      assert StateMachine.version(%{"state_machine" => "designed"}) == "designed"
      assert StateMachine.version(%{state_machine: "DESIGNED"}) == "designed"
      assert StateMachine.version(%{state_machine: " Designed "}) == "designed"
      assert StateMachine.version(%{state_machine: "legacy"}) == "legacy"
    end
  end

  describe "designed?/1" do
    test "is true only for the designed version" do
      refute StateMachine.designed?(nil)
      refute StateMachine.designed?(%{state_machine: "legacy"})
      assert StateMachine.designed?(%{state_machine: "designed"})
    end
  end

  describe "active_states/1" do
    test "legacy uses the configured active states unchanged" do
      settings = %{state_machine: "legacy", tracker: %{active_states: ["Todo", "In Progress"]}}

      assert StateMachine.active_states(settings) == ["Todo", "In Progress"]
    end

    test "designed adds its dispatchable phase states, deduplicated, but never Plan Review" do
      settings = %{
        state_machine: "designed",
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

    test "designed never dispatches from Plan Review, even when the active states name it" do
      tracker = %{active_states: ["Todo", " plan review "], plan_review_state: "Plan Review", qa_state: "QA"}

      assert StateMachine.active_states(%{state_machine: "designed", tracker: tracker}) == ["Todo", "QA"]
      assert StateMachine.tracker_active_states("designed", tracker) == ["Todo", "QA"]
      assert StateMachine.tracker_active_states("legacy", tracker) == ["Todo", " plan review "]
      assert StateMachine.tracker_active_states("designed", %{tracker | plan_review_state: nil}) == ["Todo", " plan review ", "QA"]
    end

    test "a settings without a tracker has no base active states" do
      assert StateMachine.active_states(%{state_machine: "designed", qa_state: "QA"}) == ["QA"]
    end

    test "settings that are not a map yield no states" do
      assert StateMachine.active_states(nil) == []
      assert StateMachine.designed_phase_states(nil) == []
    end
  end

  describe "active_states/3" do
    test "selects the base list for legacy and base plus phase for designed" do
      assert StateMachine.active_states("legacy", ["Todo"], ["QA"]) == ["Todo"]
      assert StateMachine.active_states("designed", ["Todo"], ["QA"]) == ["Todo", "QA"]
    end
  end

  describe "designed_phase_states/1" do
    test "reads the dispatchable phase states, dropping blank and missing ones" do
      settings = %{
        code_review_state: "Code Review",
        qa_state: "QA",
        plan_review_state: "Plan Review",
        epic_review_state: "  ",
        ci_fix_state: "CI Fix"
      }

      assert StateMachine.designed_phase_states(settings) == ["Code Review", "QA", "CI Fix"]
    end
  end

  describe "symphony.yml" do
    defp symphony(repo_fields) do
      %{
        "issues" => %{"provider" => "memory"},
        "agent" => %{"runtime" => "claude", "command" => "claude --dangerously-skip-permissions"},
        "repositories" => [
          Map.merge(%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}, repo_fields)
        ]
      }
    end

    defp repo(key, labels, state_machine) do
      %{
        "name" => key,
        "path" => Path.dirname(Workflow.workflow_file_path()),
        "workflow" => Path.basename(Workflow.workflow_file_path()),
        "team" => "Test",
        "labels" => labels,
        "state_machine" => state_machine
      }
    end

    test "a repository defaults to legacy when it sets no state machine" do
      assert {:ok, system} = SystemSchema.parse(symphony(%{}))
      assert hd(system.repos).state_machine == "legacy"
    end

    test "a repository's state_machine parses" do
      assert {:ok, system} = SystemSchema.parse(symphony(%{"state_machine" => "designed"}))
      assert hd(system.repos).state_machine == "designed"
    end

    test "an unknown value is rejected" do
      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(symphony(%{"state_machine" => "sideways"}))
      assert message =~ "state_machine"
    end

    test "the version resolves per repository through settings_for_repo" do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        repos: [repo("api", ["api"], "designed"), repo("web", ["web"], nil)]
      )

      assert Config.settings_for_repo!("api").state_machine == "designed"
      assert StateMachine.version(Config.settings_for_repo!("api")) == "designed"

      assert Config.settings_for_repo!("web").state_machine == "legacy"
      assert StateMachine.version(Config.settings_for_repo!("web")) == "legacy"
    end
  end
end
