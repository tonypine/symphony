defmodule SymphonyElixir.Setup.Checks.TeamsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RepoTeams
  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.Checks.Teams
  alias SymphonyElixir.Setup.TeamCache

  setup do
    on_exit(fn ->
      RepoTeams.forget("app")
      Application.delete_env(:symphony_elixir, :memory_tracker_projects)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    end)

    :ok
  end

  defp route!(route, overrides \\ []) do
    path = Workflow.workflow_file_path()
    repos = [Map.merge(%{key: "app", workflow: path}, route)]
    write_workflow_file!(path, Keyword.merge([tracker_kind: "memory", repos: repos], overrides))
  end

  defp projects!(projects), do: Application.put_env(:symphony_elixir, :memory_tracker_projects, projects)

  defp check, do: Setup.check(checks: [Teams])

  test "names itself and reads Linear" do
    assert Teams.id() == "teams"
    assert Teams.title() == "Each repo's Linear team"
    assert Teams.needs_linear?()
    assert Teams.run(%{system: nil}) == []
  end

  test "a repo with route.team set is never a problem and needs no lookup" do
    route!(%{team: "TP", projects: ["Gone"]})
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

    assert %{problems: [], not_checked: []} = check()
    refute_received {:memory_tracker_fetch_projects, _refs}
  end

  # Walkthrough 1: a repo routed only by a project of team TP resolves, so it is no error.
  test "a repo routed only by a project of one team is no error, and the warning sets route.team" do
    route!(%{projects: ["Symphony"]})
    projects!([%{id: "p1", name: "Symphony", slug_id: "a1abb875ac02", team_keys: ["TP"]}])

    assert %{problems: [problem], not_checked: []} = check()
    assert problem.id == "teams:app"
    assert problem.severity == "warning"
    assert problem.category == "teams"
    assert problem.title == "app doesn't name its Linear team"
    assert problem.consequence =~ "Symphony finds TP through its projects"
    assert problem.repos == ["app"]
    assert %{label: "Projects", value: "Symphony"} in problem.details
    assert %{label: "Teams", value: "TP"} in problem.details
    # Walkthrough 3: exactly one team, so the fix sets it.
    assert problem.fix == %{kind: "config_edit", path: "repositories[app].route.team", action: "set", value: "TP"}
  end

  # Walkthrough 2: a project whose teams the tracker can't resolve is an error naming the repo.
  test "a repo whose projects have no team is an error naming the repo" do
    route!(%{projects: ["Gone", "Teamless"]})
    projects!([%{id: "p2", name: "Teamless", slug_id: "t2", team_keys: []}])

    assert %{problems: [problem]} = check()
    assert problem.id == "teams:app"
    assert problem.severity == "error"
    assert problem.title == "app has no Linear team"
    assert problem.consequence == "QA self-heal can't file fix tickets, and its states and labels are never checked."
    assert problem.repos == ["app"]
    assert %{label: "Projects with no team", value: "Gone, Teamless"} in problem.details
    refute Enum.any?(problem.details, &(&1.label == "Teams"))
    assert problem.fix == %{kind: "open", target: "symphony_yml", url: nil}
  end

  test "a repo routed by labels alone has no team until its polls show one" do
    route!(%{labels: ["symphony"]}, tracker_project_slug: nil)

    assert %{problems: [%{severity: "error", details: []}]} = check()

    :ok = RepoTeams.observe("app", {:ok, [%Issue{id: "i1", team: %{key: "OPS", name: nil}}]})

    assert %{problems: [problem]} = check()
    assert problem.severity == "warning"
    assert problem.consequence =~ "Symphony finds OPS on the tickets it polls"
    assert problem.fix.value == "OPS"
  end

  test "a repo whose projects belong to several teams is a warning naming the team self-heal uses" do
    route!(%{projects: ["Symphony"]})
    projects!([%{id: "p1", name: "Symphony", slug_id: "s1", team_keys: ["TP", "OPS"]}])

    assert %{problems: [problem]} = check()
    assert problem.severity == "warning"
    assert problem.title == "app is in several Linear teams"
    assert problem.consequence =~ "Symphony finds TP, OPS through its projects. Self-heal files fix tickets for app in TP, the first of them."
    assert problem.fix == %{kind: "open", target: "symphony_yml", url: nil}
  end

  test "Linear unreachable leaves the check not checked" do
    route!(%{projects: ["Symphony"]})
    projects!({:error, :timeout})

    assert %{problems: [], not_checked: [%{id: "teams", reason: reason}]} = check()
    assert reason =~ "couldn't reach Linear"
  end

  test "a run reads each route's projects once, from the team cache" do
    route!(%{projects: ["Symphony"]})
    projects!([%{id: "p1", name: "Symphony", slug_id: "s1", team_keys: ["TP"]}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
    cache = TeamCache.new(ttl_ms: 60_000)
    context = %{system: Config.system!(), team_cache: cache}

    assert [%{id: "teams:app"}] = Teams.run(context)
    assert [%{id: "teams:app"}] = Teams.run(context)
    assert_received {:memory_tracker_fetch_projects, ["Symphony"]}
    refute_received {:memory_tracker_fetch_projects, _refs}
  end
end
