defmodule SymphonyElixir.HumanReviewTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.HumanReview

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok
  end

  describe "the retired issues.states.human_review config" do
    defp symphony(states) do
      %{
        "issues" => %{"provider" => "memory", "states" => states},
        "agent" => %{"runtime" => "claude", "command" => "claude --dangerously-skip-permissions"},
        "repositories" => [%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}]
      }
    end

    test "still loads, whatever its value, and warns that it does nothing" do
      for value <- ["Human Review", "Needs Person", nil] do
        log =
          capture_log(fn ->
            assert {:ok, system} = SystemSchema.parse(symphony(%{"human_review" => value}))
            assert {:ok, settings} = Schema.parse(SystemSchema.to_config_map(system))
            refute Map.has_key?(settings.tracker, :human_review_state)
          end)

        assert log =~ "`issues.states.human_review` is deprecated and has no effect"
      end
    end

    test "a config without it loads without the warning" do
      log = capture_log(fn -> assert {:ok, _system} = SystemSchema.parse(symphony(%{"active" => ["Todo"]})) end)

      refute log =~ "human_review"
    end

    test "Plan Review must not be an active state" do
      tracker = %{"kind" => "memory", "active_states" => ["Todo", " plan review"]}

      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"tracker" => tracker})
      assert message =~ "tracker.plan_review_state must not be an active state"
      assert {:ok, %Schema{}} = Schema.parse(%{"tracker" => Map.put(tracker, "plan_review_state", nil)})
    end
  end

  describe "plan_review_states/1" do
    test "reads the configured Plan Review state" do
      settings = Config.settings!()

      assert HumanReview.plan_review_state(settings) == "Plan Review"
      assert HumanReview.plan_review_states(settings) == ["Plan Review"]
      assert HumanReview.plan_review_state?(" plan review ", settings)
      # The draining review states are not a plan review state.
      refute HumanReview.plan_review_state?("In Review", settings)
      refute HumanReview.plan_review_state?("Human Review", settings)
      refute HumanReview.plan_review_state?(nil, settings)
    end

    test "a renamed or turned-off state, or settings that are not parsed, read as what they say" do
      settings = Config.settings!()
      renamed = %{settings | tracker: %{settings.tracker | plan_review_state: "Plan Check"}}
      assert HumanReview.plan_review_state(renamed) == "Plan Check"
      assert HumanReview.plan_review_states(renamed) == ["Plan Check"]

      off = %{settings | tracker: %{settings.tracker | plan_review_state: nil}}
      assert HumanReview.plan_review_state(off) == nil
      assert HumanReview.plan_review_states(off) == []

      assert HumanReview.plan_review_state(nil) == nil
      assert HumanReview.plan_review_states(%{}) == []
    end

    test "the settings-free predicate reads the current settings, false when they can't be read" do
      assert HumanReview.plan_review_state?("Plan Review")
      refute HumanReview.plan_review_state?("In Review")

      File.write!(Workflow.symphony_file_path(), "issues: [")
      Cache.clear()
      refute HumanReview.plan_review_state?("Plan Review")
    end
  end

  describe "parked_for_person?/2" do
    test "is true outside the active states with a label that asks for a person" do
      settings = Config.settings!()
      parked = %Issue{state: "Backlog", labels: ["needs-human"]}

      assert HumanReview.parked_for_person?(parked, settings)
      assert HumanReview.parked_for_person?(%{parked | labels: [" needs-human "]}, settings)
      # The retired request label only counts while a config still names it.
      refute HumanReview.parked_for_person?(%{parked | labels: ["Human-Action"]}, settings)
      assert HumanReview.parked_for_person?(%{parked | labels: ["Human-Action"]}, put_in(settings.human_actions.label, "human-action"))
      assert HumanReview.parked_for_person?(%{parked | state: nil}, settings)
      refute HumanReview.parked_for_person?(%{parked | state: " in progress "}, settings)
      refute HumanReview.parked_for_person?(%{parked | labels: ["plan", "breakdown", nil]}, settings)
      refute HumanReview.parked_for_person?(%{parked | labels: nil}, settings)
    end

    test "a draining review state with no label is not parked by itself" do
      settings = Config.settings!()

      refute HumanReview.parked_for_person?(%Issue{state: "Human Review", labels: []}, settings)
      refute HumanReview.parked_for_person?(%Issue{state: "In Review", labels: []}, settings)
    end
  end

  describe "held_for_person?/3" do
    test "holds an issue outside every state the pollers move issues on from, label or not" do
      settings = Config.settings!()
      held? = &HumanReview.held_for_person?(%Issue{id: "issue-1", state: &1, labels: &2}, settings, [])

      for state <- ["Backlog", " backlog ", "Done", "Canceled", "Auto Review", "In Review", "Human Review", nil] do
        assert held?.(state, []), inspect(state)
      end

      for state <- ["Todo", " in progress ", "Code Review", "QA", "Merging"] do
        refute held?.(state, []), state
      end

      assert held?.("Backlog", ["needs-human"])
    end

    test "a poller's watched states are not a wait on a person, unless a label asks for one" do
      settings = Config.settings!()
      issue = %Issue{id: "issue-1", state: "Rework", labels: []}

      assert HumanReview.held_for_person?(issue, settings, [])
      refute HumanReview.held_for_person?(issue, settings, watched_states: ["Rework"])
      assert HumanReview.held_for_person?(%{issue | labels: ["needs-human"]}, settings, watched_states: ["Rework"])
    end
  end

  describe "legacy_request_labels/1" do
    test "lists the deprecated request labels a config still names" do
      settings = Config.settings!()
      assert HumanReview.legacy_request_labels(settings) == []
      assert HumanReview.legacy_request_label() == "human-action"

      escalating = put_in(settings.auto_review.acceptance_gate.escalate.labels, ["needs-human", " Human-Action "])
      assert HumanReview.legacy_request_labels(escalating) == ["human-action"]

      both = put_in(escalating.human_actions.label, "Waiting-On-Tony")
      assert HumanReview.legacy_request_labels(both) == ["waiting-on-tony", "human-action"]
    end
  end
end
