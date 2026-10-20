defmodule SymphonyElixir.Setup.Checks.StatusesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.Checks.Statuses
  alias SymphonyElixir.Setup.TeamCache

  # Each designed state with its type and its place on a team's board.
  @board [
    {"Backlog", "backlog", 0},
    {"Todo", "unstarted", 0},
    {"In Progress", "started", 1},
    {"Code Review", "started", 2},
    {"QA", "started", 3},
    {"Merging", "started", 4},
    {"Rework", "started", 5},
    {"Plan Review", "started", 6},
    {"Epic Review", "started", 7},
    {"Waiting on sub-tickets", "started", 8},
    {"CI Fix", "started", 9},
    {"Done", "completed", 0},
    {"Canceled", "canceled", 0}
  ]

  setup do
    on_exit(fn ->
      for key <- [:memory_tracker_workflow_states_list, :memory_tracker_projects_list, :memory_tracker_recipient],
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

  # The board of `team`, but for `except`, with `extra` added.
  defp states!(except \\ [], extra \\ [], team \\ "TP") do
    board = for {name, type, position} <- @board, name not in except, do: state(name, type, position, team)
    Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, board ++ extra)
  end

  defp state(name, type, position, team \\ "TP"), do: %{id: "#{team}:#{name}", name: name, team_id: "id-#{team}", team_key: team, type: type, position: position}

  defp check, do: Setup.check(checks: [Statuses])

  test "names itself, reads Linear, and picks a color by type" do
    assert Statuses.id() == "statuses"
    assert Statuses.title() == "The workflow states in each Linear team"
    assert Statuses.needs_linear?()
    assert Statuses.run(%{system: nil}) == []
    assert Statuses.color("started") == "#f2c94c"
    assert Statuses.color("triage") == "#bec2c8"
  end

  test "a team with every designed state is clean, from one states read" do
    states!()
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert %{problems: [], not_checked: []} = check()
    assert_received {:memory_tracker_team_workflow_states, "TP"}
    refute_received {:memory_tracker_team_workflow_states, _team}
  end

  test "a team whose states read returns none is not judged" do
    assert %{problems: [], not_checked: []} = check()
  end

  test "a team missing Epic Review is an error with a create_state fix: name, type and place" do
    states!(["Epic Review"])

    assert %{problems: [problem]} = check()
    assert problem.id == "statuses:missing:TP:Epic Review"
    assert problem.severity == "error"
    assert problem.category == "statuses"
    assert problem.title == ~s(Team TP has no "Epic Review" state)
    assert problem.consequence == "An epic whose sub-tickets are all done can't be reviewed, so it never closes."
    assert problem.repos == ["app"]

    assert problem.details == [
             %{label: "Team", value: "TP"},
             %{label: "State", value: "Epic Review"},
             %{label: "Type", value: "started"},
             %{label: "After", value: "Plan Review"},
             %{label: "Set by", value: "issues.states.epic_review"}
           ]

    # Halfway between Plan Review and the next started state, Waiting on sub-tickets.
    assert problem.fix == %{kind: "linear", action: "create_state", team: "TP", name: "Epic Review", type: "started", after: "Plan Review", position: 7.0}
  end

  test "a missing state goes after the last of its type, first of its type, or where Linear puts it" do
    # A started state of the team's own sits before Code Review: In Progress still goes first.
    states!(["CI Fix", "In Progress", "Todo"], [state("Design", "started", 0.5)])

    assert %{problems: [todo, in_progress, ci_fix]} = check()
    assert %{name: "Todo", type: "unstarted", after: nil, position: nil} = todo.fix
    assert %{name: "In Progress", type: "started", after: nil, position: -0.5} = in_progress.fix
    assert %{name: "CI Fix", after: "Waiting on sub-tickets", position: 9} = ci_fix.fix
    assert todo.consequence =~ "only from Todo"
  end

  test "a board read without positions still names the state before" do
    board = for {name, type, _position} <- @board, name != "QA", do: %{id: name, name: name, team_key: "TP", type: type}
    Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, board)

    assert %{problems: [%{fix: %{name: "QA", after: "Code Review", position: nil}}]} = check()
  end

  test "a designed state of the wrong type is its own error, opening Linear; one read without a type isn't judged" do
    states!(["QA", "Merging"], [state("QA", "unstarted", 1), %{id: "m", name: "merging ", team_id: "TP", team_key: "TP"}])

    assert %{problems: [problem]} = check()
    assert problem.id == "statuses:wrong_type:TP:QA"
    assert problem.severity == "error"
    assert problem.title == ~s(Team TP's "QA" state is unstarted, not started)
    assert problem.consequence =~ "Linear groups and counts its tickets as unstarted"
    assert %{label: "Symphony's type", value: "started"} in problem.details
    assert problem.fix == %{kind: "open", target: "linear", url: nil}
  end

  test "Cancelled will do for Canceled, and a phase state turned off is not wanted" do
    states!(["Canceled", "Plan Review"], [state("Cancelled", "canceled", 0)])
    route!([%{key: "app", team: "TP"}], tracker_plan_review_state: nil)

    assert %{problems: []} = check()

    states!(["Canceled"])
    assert %{problems: [problem]} = check()
    assert problem.id == "statuses:missing:TP:Canceled"
    assert %{label: "Also accepted", value: "Cancelled"} in problem.details
  end

  test "a phase state goes by the name the config gives it" do
    states!()
    {:ok, system} = Config.system()
    system = put_in(system.tracker.code_review_state, "Review")
    cache = TeamCache.new(ttl_ms: 60_000)

    assert [problem] = Statuses.run(%{system: system, team_cache: cache})
    assert problem.id == "statuses:missing:TP:Review"
    assert %{label: "Set by", value: "issues.states.code_review"} in problem.details
    assert problem.fix.after == "In Progress"
  end

  test "an active state no state of the team has is an error naming the key and the value" do
    states!()
    route!([%{key: "app", team: "TP"}], tracker_active_states: ["Todo", "In Progres"])

    assert %{problems: [problem]} = check()
    assert problem.id == "statuses:unknown:TP:issues.states.active:In Progres"
    assert problem.severity == "error"
    assert problem.title == ~s(issues.states.active names "In Progres", which team TP has no state for)
    assert problem.consequence =~ ~s(Symphony never picks up tickets from "In Progres")

    assert problem.details == [
             %{label: "Key", value: "issues.states.active"},
             %{label: "Value", value: "In Progres"},
             %{label: "Team", value: "TP"},
             %{label: "Closest state", value: "In Progress"}
           ]

    assert problem.fix == %{kind: "open", target: "settings", url: nil}
  end

  test "a terminal list is judged once it is set, never as the default spellings" do
    states!()
    assert %{problems: []} = check()

    route!([%{key: "app", team: "TP"}], tracker_terminal_states: ["Done", "Archived", "Canceled"])
    assert %{problems: [problem]} = check()
    assert problem.id == "statuses:unknown:TP:issues.states.terminal:Archived"
    assert problem.consequence =~ ~s(Symphony doesn't count "Archived" as finished)
    refute Enum.any?(problem.details, &(&1.label == "Closest state"))
  end

  test "each routed team is judged on its own board" do
    route!([%{key: "app", team: "TP"}, %{key: "ops", team: "OPS"}])
    ops = for {name, type, position} <- @board, name != "QA", do: state(name, type, position, "OPS")
    states!(["Rework"], ops)

    assert %{problems: [tp, ops]} = check()
    assert tp.id == "statuses:missing:TP:Rework"
    assert tp.repos == ["app"]
    assert ops.id == "statuses:missing:OPS:QA"
    assert ops.repos == ["ops"]
  end

  test "Linear unreachable leaves the check not checked" do
    Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, {:error, :timeout})

    assert %{problems: [], not_checked: [%{id: "statuses", reason: reason}]} = check()
    assert reason =~ "couldn't reach Linear"
  end

  test "a project lookup that fails leaves the check not checked" do
    route!([%{key: "app", projects: ["Symphony"]}], tracker_team: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_projects_list, {:error, :timeout})

    assert %{problems: [], not_checked: [%{id: "statuses"}]} = check()
  end
end
