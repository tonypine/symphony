defmodule SymphonyElixir.PlanReviewTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.PlanReview

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok
  end

  test "reads the configured Plan Review state, nil when it is turned off or the settings are not parsed" do
    settings = Config.settings!()

    assert PlanReview.state(settings) == "Plan Review"
    assert PlanReview.state(put_in(settings.tracker.plan_review_state, "Plan Check")) == "Plan Check"
    assert PlanReview.state(put_in(settings.tracker.plan_review_state, nil)) == nil
    assert PlanReview.state(%{}) == nil
  end

  test "matches the configured state whatever the case and spacing" do
    settings = Config.settings!()

    assert PlanReview.in_state?(%Issue{state: " plan review "}, settings)
    assert PlanReview.in_state?("Plan Review", settings)
    refute PlanReview.in_state?("In Review", settings)
    refute PlanReview.in_state?(nil, settings)
    refute PlanReview.in_state?("Plan Review", put_in(settings.tracker.plan_review_state, nil))
  end

  test "in_state?/1 reads the current settings, false when they can't be read" do
    assert PlanReview.in_state?("Plan Review")
    refute PlanReview.in_state?("Todo")

    File.write!(Workflow.symphony_file_path(), "issues: [")
    Cache.clear()
    refute PlanReview.in_state?("Plan Review")
  end

  test "must not be an active state, since no run starts there" do
    tracker = %{"kind" => "memory", "active_states" => ["Todo", " plan review"]}

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"tracker" => tracker})
    assert message =~ "tracker.plan_review_state must not be an active state"
    assert {:ok, %Schema{}} = Schema.parse(%{"tracker" => Map.put(tracker, "plan_review_state", nil)})
  end
end
