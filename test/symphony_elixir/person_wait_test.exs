defmodule SymphonyElixir.PersonWaitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PersonWait

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok
  end

  describe "parked?/2" do
    test "is true outside the active states with a label that asks for a person" do
      settings = Config.settings!()
      parked = %Issue{state: "Backlog", labels: ["needs-human"]}

      assert PersonWait.parked?(parked, settings)
      assert PersonWait.parked?(%{parked | labels: [" needs-human "]}, settings)
      # The retired request label only counts while a config still names it.
      refute PersonWait.parked?(%{parked | labels: ["Human-Action"]}, settings)
      assert PersonWait.parked?(%{parked | labels: ["Human-Action"]}, put_in(settings.human_actions.label, "human-action"))
      assert PersonWait.parked?(%{parked | state: nil}, settings)
      refute PersonWait.parked?(%{parked | state: " in progress "}, settings)
      refute PersonWait.parked?(%{parked | labels: ["plan", "breakdown", nil]}, settings)
      refute PersonWait.parked?(%{parked | labels: nil}, settings)
    end

    test "is false without a label, whatever the state" do
      settings = Config.settings!()

      refute PersonWait.parked?(%Issue{state: "Human Review", labels: []}, settings)
      refute PersonWait.parked?(%Issue{state: "Code Review", labels: []}, settings)
    end
  end

  describe "held?/3" do
    test "holds an issue outside every state the pollers move issues on from, label or not" do
      settings = Config.settings!()
      held? = &PersonWait.held?(%Issue{id: "issue-1", state: &1, labels: &2}, settings, [])

      for state <- ["Backlog", " backlog ", "Done", "Canceled", "Auto Review", "In Review", "Human Review", "Rework", nil] do
        assert held?.(state, []), inspect(state)
      end

      for state <- ["Todo", " in progress ", "Code Review", "QA", "CI Fix", "Merging"] do
        refute held?.(state, []), state
      end

      assert held?.("Code Review", ["needs-human"])
    end

    test "a poller's watched states count as states it moves issues on from" do
      settings = Config.settings!()
      issue = %Issue{id: "issue-1", state: "Rework", labels: []}

      refute PersonWait.held?(issue, settings, watched_states: ["Rework"])
      assert PersonWait.held?(%{issue | labels: ["needs-human"]}, settings, watched_states: ["Rework"])
    end
  end

  describe "legacy_request_labels/1" do
    test "lists the deprecated request labels a config still names" do
      settings = Config.settings!()
      assert PersonWait.legacy_request_labels(settings) == []
      assert PersonWait.legacy_request_label() == "human-action"

      escalating = put_in(settings.auto_review.acceptance_gate.escalate.labels, ["needs-human", " Human-Action "])
      assert PersonWait.legacy_request_labels(escalating) == ["human-action"]

      both = put_in(escalating.human_actions.label, "Waiting-On-Tony")
      assert PersonWait.legacy_request_labels(both) == ["waiting-on-tony", "human-action"]
    end
  end
end
