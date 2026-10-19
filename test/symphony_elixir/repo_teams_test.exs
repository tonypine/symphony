defmodule SymphonyElixir.RepoTeamsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RepoTeams
  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.TeamCache

  @tracker %{team: nil, project_slug: nil}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    repo_key = "repo-#{System.unique_integer([:positive])}"
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      RepoTeams.forget(repo_key)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_projects)
    end)

    {:ok, repo_key: repo_key}
  end

  @symphony %{id: "p1", name: "Symphony", slug_id: "s1", team_keys: ["TP"]}

  defp lookup(projects), do: fn refs -> send(self(), {:lookup, refs}) && {:ok, projects} end

  # Resolves with no `issues` team or project unless the test gives `tracker`, and the projects given.
  defp resolve(repo, projects, tracker \\ @tracker), do: RepoTeams.resolve(repo, tracker: tracker, projects: lookup(projects))

  defp issue(team), do: %Issue{id: "i-#{team}", team: %{key: team, name: nil}}

  describe "resolve/2" do
    test "route.team wins, and the issues team counts as the route's", %{repo_key: key} do
      repo = %{name: key, team: " TP ", projects: ["Symphony"]}

      assert {:ok, %{source: :route, teams: ["TP"], projects: ["Symphony"]}} = resolve(repo, [])
      issues_team = %{@tracker | team: "OPS"}
      assert {:ok, %{source: :route, teams: ["OPS"]}} = resolve(%{name: key, team: nil, projects: []}, [], issues_team)

      refute_received {:lookup, _refs}
    end

    test "a repo routed only by project finds its projects' teams, by name, slug id or id", %{repo_key: key} do
      projects = [
        %{id: "p1", name: "Symphony", slug_id: "a1abb875ac02", team_keys: ["TP"]},
        %{id: "p2", name: "Other", slug_id: "b2", team_keys: ["OPS", "TP"]}
      ]

      assert {:ok, %{source: :projects, teams: ["TP"], project_teams: ["TP"], unresolved_projects: []}} =
               resolve(%{name: key, projects: ["a1abb875ac02"]}, projects)

      assert_received {:lookup, ["a1abb875ac02"]}

      assert {:ok, %{source: :projects, teams: ["TP", "OPS"], unresolved_projects: ["Gone"]}} =
               resolve(%{name: key, projects: ["Symphony", "p2", "Gone", " "]}, projects)
    end

    test "the issues project counts when the route names none", %{repo_key: key} do
      issues_project = %{@tracker | project_slug: "s1"}

      assert {:ok, %{source: :projects, teams: ["TP"], projects: ["s1"]}} =
               resolve(%{name: key}, [@symphony], issues_project)
    end

    test "with no project team, the polled issues' teams count, else there is none", %{repo_key: key} do
      repo = %{name: key, projects: ["Gone"]}

      assert {:ok, %{source: :none, teams: [], unresolved_projects: ["Gone"]}} = resolve(repo, [])
      assert {:ok, %{source: :none, projects: []}} = resolve(%{name: key}, [])
      refute_received {:lookup, []}

      :ok = RepoTeams.observe(key, {:ok, [issue("TP"), %Issue{id: "no-team"}, issue("TP")]})

      assert {:ok, %{source: :issues, teams: ["TP"], unresolved_projects: ["Gone"]}} = resolve(repo, [])
    end

    test "a failed projects lookup is an error", %{repo_key: key} do
      failing = fn _refs -> {:error, :timeout} end
      assert {:error, :timeout} = RepoTeams.resolve(%{name: key, projects: ["Symphony"]}, tracker: @tracker, projects: failing)
    end

    test "reads the running config's issues settings and the tracker by default", %{repo_key: key} do
      Application.put_env(:symphony_elixir, :memory_tracker_projects, [@symphony])

      assert {:ok, %{source: :projects, teams: ["TP"]}} = RepoTeams.resolve(%{name: key, projects: ["Symphony"]})
      assert_received {:memory_tracker_fetch_projects, ["Symphony"]}
    end

    test "a config that doesn't load leaves only the route's own team and projects", %{repo_key: key} do
      File.write!(Workflow.symphony_file_path(), "pull_request: 1\n")
      Cache.clear()

      assert {:ok, %{source: :none, projects: []}} = RepoTeams.resolve(%{name: key}, projects: lookup([]))
      assert {:ok, %{source: :route, teams: ["TP"]}} = RepoTeams.resolve(%{name: key, team: "TP"})
    end

    test "reads through the running Setup server's team cache", %{repo_key: key} do
      Application.put_env(:symphony_elixir, :memory_tracker_projects, [@symphony])
      start_supervised!({Setup, checks: [], name: Setup})
      assert %TeamCache{} = Setup.team_cache()

      for _read <- 1..2, do: assert({:ok, %{teams: ["TP"]}} = RepoTeams.resolve(%{name: key, projects: ["Symphony"]}))

      assert_received {:memory_tracker_fetch_projects, ["Symphony"]}
      refute_received {:memory_tracker_fetch_projects, _refs}
    end
  end

  describe "routed_teams/2" do
    test "the resolved teams", %{repo_key: key} do
      assert RepoTeams.routed_teams(%{name: key, team: "TP"}, tracker: @tracker) == ["TP"]
      assert RepoTeams.routed_teams(%{name: key, projects: ["Gone"]}, tracker: @tracker, projects: lookup([])) == []
    end

    test "a failed projects lookup is logged and the polled issues' teams still count", %{repo_key: key} do
      :ok = RepoTeams.observe(key, {:ok, [issue("OPS")]})
      repo = %{name: key, projects: ["Symphony"]}

      log =
        capture_log(fn ->
          assert RepoTeams.routed_teams(repo, tracker: @tracker, projects: fn _refs -> {:error, :timeout} end) == ["OPS"]
        end)

      assert log =~ "Could not look up the Linear teams of repo=#{key}'s routed projects: :timeout"
    end
  end

  describe "observe/2" do
    test "a failed or empty poll keeps what an earlier one saw, and another repo key sees nothing", %{repo_key: key} do
      assert RepoTeams.issue_teams(key) == []
      assert RepoTeams.issue_teams(nil) == []

      :ok = RepoTeams.observe(key, {:ok, [issue("TP")]})
      :ok = RepoTeams.observe(key, {:ok, []})
      :ok = RepoTeams.observe(key, {:error, :timeout})
      :ok = RepoTeams.observe(nil, {:ok, [issue("OPS")]})
      assert RepoTeams.issue_teams(key) == ["TP"]

      :ok = RepoTeams.observe(key, {:ok, [issue("OPS"), issue("TP")]})
      assert RepoTeams.issue_teams(key) == ["OPS", "TP"]

      assert :ok = RepoTeams.forget(key)
      assert RepoTeams.issue_teams(key) == []
    end
  end

  test "without a running Setup server there is no shared team cache" do
    assert Setup.team_cache(Module.concat(__MODULE__, "NotRunning")) == nil

    # A server that goes away while it is asked.
    name = Module.concat(__MODULE__, "Exiting")
    test_pid = self()

    spawn(fn ->
      Process.register(self(), name)
      send(test_pid, :registered)

      receive do
        {:"$gen_call", _from, :team_cache} -> exit(:normal)
      end
    end)

    assert_receive :registered
    assert Setup.team_cache(name) == nil
  end
end
