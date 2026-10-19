defmodule SymphonyElixir.Setup.Checks.LabelsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.Checks.Labels
  alias SymphonyElixir.StateProvisioning

  setup do
    on_exit(fn ->
      for key <- [:memory_tracker_labels_list, :memory_tracker_projects_list, :memory_tracker_recipient],
          do: Application.delete_env(:symphony_elixir, key)
    end)

    route!()
    :ok
  end

  defp route!(repos \\ [%{key: "app", team: "TP"}], overrides \\ []) do
    path = Workflow.workflow_file_path()
    repos = Enum.map(repos, &Map.put(&1, :workflow, path))
    write_workflow_file!(path, Keyword.merge([tracker_kind: "memory", repos: repos], overrides))
  end

  # Every label the check wants, as team labels of `team`, but for `except`, plus `extra`.
  defp labels!(except \\ [], extra \\ [], team \\ "TP") do
    wanted = for %{names: [name | _]} <- StateProvisioning.machine_labels("expedite", ["needs-human"]), name not in except, do: name
    Application.put_env(:symphony_elixir, :memory_tracker_labels_list, Enum.map(wanted, &team_label(&1, team)) ++ extra)
  end

  defp team_label(name, team), do: %{id: "#{team}:#{name}", name: name, team_id: "id-#{team}", team_key: team}
  defp workspace_label(name), do: %{id: "ws:#{name}", name: name, team_id: nil, team_key: nil}

  defp check, do: Setup.check(checks: [Labels])

  test "names itself and reads Linear" do
    assert Labels.id() == "labels"
    assert Labels.title() == "Symphony's labels in each Linear team"
    assert Labels.needs_linear?()
    assert Labels.run(%{system: nil}) == []
  end

  test "a team with every label is clean, from one labels read" do
    labels!()
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert %{problems: [], not_checked: []} = check()
    assert_received {:memory_tracker_team_labels, "TP"}
    refute_received {:memory_tracker_team_labels, _team}
  end

  test "a team whose labels read returns none is not judged" do
    assert %{problems: [], not_checked: []} = check()
  end

  test "a team missing Needs Decision is an error with a Create fix for exactly that label" do
    labels!(["Needs Decision"])

    assert %{problems: [problem]} = check()
    assert problem.id == "labels:missing:TP:Needs Decision"
    assert problem.severity == "error"
    assert problem.category == "labels"
    assert problem.title == ~s(Team TP has no "Needs Decision" label)
    assert problem.consequence == "Decisions you are asked for can't be marked on the ticket."
    assert problem.repos == ["app"]
    assert problem.details == [%{label: "Team", value: "TP"}, %{label: "Label", value: "Needs Decision"}]
    assert problem.fix == %{kind: "linear", action: "create_label", team: "TP", name: "Needs Decision", type: nil}
  end

  test "a near-miss spelling names both, and the exact name is still missing" do
    labels!(["Needs Decision"], [team_label("Needs decision ", "TP")])

    assert %{problems: [missing, near]} = check()
    assert missing.id == "labels:missing:TP:Needs Decision"
    assert missing.severity == "error"

    assert near.id == "labels:near_miss:TP:Needs decision "
    assert near.severity == "warning"
    assert near.title == ~s(Team TP's label "Needs decision " looks like "Needs Decision")
    assert near.consequence =~ ~s(Symphony reads only "Needs Decision", so it ignores "Needs decision ")
    assert %{label: "Label", value: "Needs decision "} in near.details
    assert %{label: "Symphony's label", value: "Needs Decision"} in near.details
    assert %{label: "Scope", value: "team label"} in near.details
    assert near.fix == %{kind: "open", target: "linear", url: nil}
  end

  test "a label a short edit away is a near miss, in the workspace too" do
    labels!([], [workspace_label("qa skip"), workspace_label("Bug")])

    assert %{problems: [near]} = check()
    assert near.title == ~s(Team TP's label "qa skip" looks like "qa:skip")
    assert %{label: "Scope", value: "workspace label"} in near.details
  end

  test "a label Symphony reads counts in any case, and plan or breakdown will do" do
    labels!(["plan", "breakdown", "qa:skip"], [team_label("Plan", "TP"), team_label("QA:Skip", "TP")])
    assert %{problems: []} = check()

    labels!(["plan", "breakdown"])
    assert %{problems: [problem]} = check()
    assert problem.id == "labels:missing:TP:plan"
    assert problem.severity == "warning"
    assert %{label: "Also accepted", value: "breakdown"} in problem.details
    assert problem.fix.name == "plan"
  end

  test "a machine label that is both a team and a workspace label is a duplicate" do
    labels!([], [workspace_label("Blocked")])

    assert %{problems: [problem]} = check()
    assert problem.id == "labels:duplicate:TP:Blocked"
    assert problem.severity == "warning"
    assert problem.title == ~s("Blocked" is both a team TP label and a workspace label)
    assert %{label: "Workspace label", value: "Blocked"} in problem.details
    assert problem.fix == %{kind: "open", target: "linear", url: nil}
  end

  test "the force label and each escalate label are wanted, in the teams of the repos that name them" do
    route!(
      [%{key: "app", team: "TP", acceptance_gate: %{"escalate" => %{"labels" => ["security"]}}}, %{key: "ops", team: "OPS"}],
      force_label: "rush"
    )

    labels!([], [], "TP")
    ops = for %{names: [name | _]} <- StateProvisioning.machine_labels("expedite", ["needs-human"]), do: team_label(name, "OPS")
    tp = Application.get_env(:symphony_elixir, :memory_tracker_labels_list)
    Application.put_env(:symphony_elixir, :memory_tracker_labels_list, tp ++ ops)

    {%{problems: problems}, _log} = with_log(fn -> check() end)

    assert Enum.map(problems, & &1.id) == [
             "labels:missing:TP:rush",
             "labels:missing:TP:security",
             "labels:missing:OPS:rush"
           ]

    assert Enum.find(problems, &(&1.id == "labels:missing:TP:rush")).consequence == "No ticket can be expedited past the queue."
    assert Enum.find(problems, &(&1.id == "labels:missing:TP:security")).consequence =~ "Code Review can't be told to ask you"
  end

  test "Linear unreachable leaves the check not checked" do
    Application.put_env(:symphony_elixir, :memory_tracker_labels_list, {:error, :timeout})

    assert %{problems: [], not_checked: [%{id: "labels", reason: reason}]} = check()
    assert reason =~ "couldn't reach Linear"
  end

  test "a project lookup that fails leaves the check not checked" do
    route!([%{key: "app", projects: ["Symphony"]}], tracker_team: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_projects_list, {:error, :timeout})

    assert %{not_checked: [%{id: "labels"}]} = check()
  end
end
