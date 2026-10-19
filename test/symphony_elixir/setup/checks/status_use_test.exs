defmodule SymphonyElixir.Setup.Checks.StatusUseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{RetiredStates, Setup, SubIssueWait}
  alias SymphonyElixir.Setup.Checks.StatusUse
  alias SymphonyElixir.Tracker.Memory

  @waiting "Waiting on sub-tickets"

  setup do
    RetiredStates.reset_for_test()
    SubIssueWait.reset_for_test(@waiting)

    on_exit(fn ->
      RetiredStates.reset_for_test()
      SubIssueWait.reset_for_test(@waiting)
      Application.delete_env(:symphony_elixir, :memory_tracker_workflow_states)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok
  end

  defp check, do: Setup.check(checks: [StatusUse])

  defp issue(identifier, state), do: %Issue{id: "id-#{identifier}", identifier: identifier, url: "https://linear.app/t/issue/#{identifier}", state: state}

  # The drain report as the poll leaves it, from the issues in the memory tracker.
  defp drain!(issues) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    capture_log(fn -> RetiredStates.report(tracker: Memory) end)
  end

  test "names itself and reads nothing from Linear" do
    assert StatusUse.id() == "status_use"
    assert StatusUse.title() =~ "States Symphony turned off"
    refute StatusUse.needs_linear?()
    assert StatusUse.run(%{system: nil}) == []
  end

  test "a setup with nothing turned off, drained and no phase listed as active is clean" do
    assert %{problems: [], not_checked: []} = check()
  end

  test "the waiting state the startup check turned off is a warning, not only a log line" do
    Application.put_env(:symphony_elixir, :memory_tracker_workflow_states, ["Todo", "In Progress"])
    settings = Config.settings!()
    log = capture_log(fn -> assert SubIssueWait.check_tracker_state(settings, ["TP"], tracker: Memory) == :disabled end)
    assert log =~ "Waiting on sub-issues state disabled"
    assert SubIssueWait.disabled_teams(@waiting) == ["TP"]
    assert SubIssueWait.disabled_teams(nil) == nil

    assert %{problems: [problem]} = check()
    assert problem.id == "status_use:waiting_off"
    assert problem.severity == "warning"
    assert problem.category == "statuses"
    assert problem.title == ~s(Symphony turned "Waiting on sub-tickets" off)
    assert problem.consequence =~ ~s(found no "Waiting on sub-tickets" state in team TP, so approved plans stay In Progress)
    assert problem.consequence =~ "then restart Symphony"

    assert problem.details == [
             %{label: "State", value: @waiting},
             %{label: "Teams", value: "TP"},
             %{label: "Set by", value: "issues.states.waiting_on_sub_issues"}
           ]

    assert problem.fix == nil

    # Checked in every team, it names none.
    capture_log(fn -> SubIssueWait.check_tracker_state(Config.settings!(), [], tracker: Memory) end)
    assert %{problems: [problem]} = check()
    assert problem.consequence =~ ~s(found no "Waiting on sub-tickets" state, so)
    refute Enum.any?(problem.details, &(&1.label == "Teams"))
  end

  test "tickets left in a retired state are a warning per state, naming them and opening the drain report" do
    drain!([issue("TP-1", "In Review"), issue("TP-2", "In Review"), issue("TP-3", "In Review"), issue("TP-4", "Auto Review")])

    assert %{problems: [in_review, auto_review]} = check()
    assert in_review.id == "status_use:retired:In Review"
    assert in_review.severity == "warning"
    assert in_review.title == "3 tickets are still in the retired In Review state"
    assert in_review.consequence =~ "In Review is retired"
    assert Enum.map(in_review.tickets, & &1.identifier) == ["TP-1", "TP-2", "TP-3"]
    assert %{identifier: "TP-1", url: "https://linear.app/t/issue/TP-1"} in in_review.tickets
    assert %{label: "TP-1", value: "move it by hand to Code Review (its PR is open) or In Progress"} in in_review.details
    assert in_review.fix == %{kind: "open", target: "drain_report", url: nil}

    assert auto_review.title == "TP-4 is still in the retired Auto Review state"
    assert auto_review.fix == %{kind: "open", target: "drain_report", url: nil}
  end

  test "a phase state listed as active is a warning whose fix removes it" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["Todo", "In Progress", "code review"])

    assert %{problems: [problem]} = check()
    assert problem.id == "status_use:active_phase:Code Review"
    assert problem.severity == "warning"
    assert problem.title == ~s(issues.states.active lists the "Code Review" phase)
    assert problem.consequence =~ "tickets there would be worked as ordinary work"
    assert %{label: "Value", value: "code review"} in problem.details
    assert problem.fix == %{kind: "config_edit", path: "issues.states.active", action: "remove", value: "code review"}
  end
end
