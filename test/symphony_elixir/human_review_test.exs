defmodule SymphonyElixir.HumanReviewTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.HumanReview

  @human_review "Human Review"

  defmodule StateTracker do
    def workflow_state_exists?(state_name, teams) do
      send(self(), {:workflow_state_exists?, state_name, teams})
      Process.get(:human_review_state_result)
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    HumanReview.reset_for_test(@human_review)

    on_exit(fn ->
      HumanReview.reset_for_test(@human_review)
      Application.delete_env(:symphony_elixir, :memory_tracker_workflow_states)
    end)

    :ok
  end

  describe "issues.states.human_review config" do
    test "defaults to Human Review, which is not an active state" do
      settings = Config.settings!()

      assert settings.tracker.human_review_state == @human_review
      refute @human_review in settings.tracker.active_states
      assert HumanReview.state(settings) == @human_review
      assert HumanReview.enabled?(settings)
      assert HumanReview.target_state(settings) == @human_review
      assert HumanReview.review_states(settings) == ["In Review", @human_review]
    end

    test "can be renamed or turned off with null or a blank string" do
      repositories = [%{"key" => "default", "workflow" => "WORKFLOW.md"}]

      for {value, expected_state} <- [{"Needs Tony", "Needs Tony"}, {nil, nil}, {" ", nil}] do
        assert {:ok, system_config} =
                 SystemSchema.parse(%{
                   "issues" => %{"provider" => "memory", "states" => %{"human_review" => value}},
                   "repositories" => repositories
                 })

        tracker = SystemSchema.to_config_map(system_config)["tracker"]
        assert {:ok, %Schema{tracker: parsed}} = Schema.parse(%{"tracker" => tracker})
        assert parsed.human_review_state == expected_state
      end
    end

    test "turned off, every issue goes to In Review as before" do
      assert {:ok, %Schema{} = settings} = Schema.parse(%{"tracker" => %{"kind" => "memory", "human_review_state" => nil}})

      assert HumanReview.state(settings) == nil
      refute HumanReview.enabled?(settings)
      assert HumanReview.target_state(settings) == "In Review"
      assert HumanReview.review_states(settings) == ["In Review"]
      refute HumanReview.in_state?(%Issue{state: @human_review}, settings)
      refute HumanReview.review_state?(@human_review, settings)
      assert :skipped = HumanReview.check_tracker_state(settings, ["TP"], tracker: StateTracker)
      refute_received {:workflow_state_exists?, _state, _teams}
    end

    test "must not be an active state, since Symphony never dispatches from it" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"tracker" => %{"kind" => "memory", "active_states" => ["Todo", " human review"]}})

      assert message =~ "human_review_state must not be an active state"
    end
  end

  describe "state checks" do
    test "match the configured state whatever the case and spacing" do
      settings = Config.settings!()

      assert HumanReview.in_state?(%Issue{state: " human review "}, settings)
      assert HumanReview.in_state?("Human Review", settings)
      refute HumanReview.in_state?("In Review", settings)
      refute HumanReview.in_state?(nil, settings)
      assert HumanReview.review_state?("in review", settings)
      assert HumanReview.review_state?("Human Review", settings)
      refute HumanReview.review_state?("Merging", settings)
      refute HumanReview.review_state?(nil, settings)
    end

    test "in_state?/1 reads the current settings, and is false when they can't be read" do
      assert HumanReview.in_state?("Human Review")
      refute HumanReview.in_state?("In Review")

      File.write!(Workflow.symphony_file_path(), "issues: [")
      Cache.clear()
      refute HumanReview.in_state?("Human Review")
    end
  end

  describe "requested_by_ticket?/2" do
    test "is true for an escalation label other than plan or breakdown, or a ticket pattern" do
      settings = Config.settings!()
      plan = %Issue{title: "Split the importer", description: "Plan the work.", labels: ["breakdown"]}

      refute HumanReview.requested_by_ticket?(plan, settings)
      refute HumanReview.requested_by_ticket?(%{plan | labels: nil}, settings)
      assert HumanReview.requested_by_ticket?(%{plan | labels: ["breakdown", "Needs-Human"]}, settings)
      refute HumanReview.requested_by_ticket?(%{plan | labels: ["Plan"]}, settings)
      assert HumanReview.requested_by_ticket?(%{plan | labels: ["plan", "needs-human"]}, settings)
      assert HumanReview.requested_by_ticket?(%{plan | description: "The plan must not auto-approve."}, settings)
      assert HumanReview.requested_by_ticket?(%{plan | title: "Human review: split the importer"}, settings)
      refute HumanReview.requested_by_ticket?(%{plan | description: "Keep parents in `Human Review` until approved."}, settings)
    end
  end

  describe "check_tracker_state/3" do
    test "keeps the state on when Linear has it" do
      Process.put(:human_review_state_result, {:ok, true})
      settings = Config.settings!()

      assert :ok = HumanReview.check_tracker_state(settings, ["TP"], tracker: StateTracker)
      assert_received {:workflow_state_exists?, @human_review, ["TP"]}
      assert HumanReview.enabled?(settings)
    end

    test "turns the state off with a warning when Linear is missing it, until a later check finds it" do
      settings = Config.settings!()
      Process.put(:human_review_state_result, {:ok, false})

      log = capture_log(fn -> assert :disabled = check(settings, ["TP", "ENG"]) end)

      assert log =~ ~s[Human review state disabled: Linear state "Human Review" is missing for team(s) TP, ENG]
      assert log =~ "issues that need a person go to In Review"
      refute HumanReview.enabled?(settings)
      assert HumanReview.target_state(settings) == "In Review"

      log = capture_log(fn -> assert :disabled = check(settings, []) end)
      assert log =~ ~s(Linear state "Human Review" is missing; issues)

      Process.put(:human_review_state_result, {:ok, true})
      assert :ok = check(settings, [])
      assert HumanReview.enabled?(settings)
    end

    test "leaves the state on when the tracker cannot be asked" do
      Process.put(:human_review_state_result, {:error, :timeout})
      settings = Config.settings!()

      log = capture_log(fn -> assert {:error, :timeout} = check(settings, []) end)

      assert log =~ "leaving it on"
      assert HumanReview.enabled?(settings)
    end

    test "uses the configured tracker by default" do
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states, ["Todo", "In Progress"])

      capture_log(fn -> assert :disabled = HumanReview.check_tracker_state(Config.settings!(), []) end)
      refute HumanReview.enabled?(Config.settings!())
    end
  end

  defp check(settings, teams), do: HumanReview.check_tracker_state(settings, teams, tracker: StateTracker)
end
