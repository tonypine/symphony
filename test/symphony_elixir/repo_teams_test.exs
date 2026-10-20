defmodule SymphonyElixir.RepoTeamsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RepoTeams
  alias SymphonyElixir.Routing.PollLog
  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.TeamCache

  @tracker %{team: nil, project_slug: nil}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    repo_key = "repo-#{System.unique_integer([:positive])}"
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      :ets.delete(PollLog, repo_key)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_projects_list)
    end)

    {:ok, repo_key: repo_key}
  end

  @symphony %{id: "p1", name: "Symphony", slug_id: "s1", team_keys: ["TP"]}

  defp lookup(projects), do: fn -> send(self(), :lookup) && {:ok, projects} end

  # Resolves with no `issues` team or project unless the test gives `tracker`, and the projects given.
  defp resolve(repo, projects, tracker \\ @tracker), do: RepoTeams.resolve(repo, tracker: tracker, projects: lookup(projects))

  defp issue(team), do: %Issue{id: "i-#{team}", team: %{key: team, name: nil}}

  defp polled(repo, issues), do: PollLog.record(repo, {:ok, issues})

  describe "resolve/2" do
    test "route.team wins, and the issues team counts as the route's", %{repo_key: key} do
      repo = %{name: key, team: " TP ", projects: ["Symphony"]}

      assert {:ok, %{source: :route, teams: ["TP"], projects: ["Symphony"]}} = resolve(repo, [])
      issues_team = %{@tracker | team: "OPS"}
      assert {:ok, %{source: :route, teams: ["OPS"]}} = resolve(%{name: key, team: nil, projects: []}, [], issues_team)

      refute_received :lookup
    end

    test "a repo routed only by project finds its projects' teams, by name, slug id or id", %{repo_key: key} do
      projects = [
        %{id: "p1", name: "Symphony", slug_id: "a1abb875ac02", team_keys: ["TP"]},
        %{id: "p2", name: "Other", slug_id: "b2", team_keys: ["OPS", "TP"]}
      ]

      assert {:ok, %{source: :projects, teams: ["TP"], project_teams: ["TP"], unresolved_projects: []}} =
               resolve(%{name: key, projects: ["a1abb875ac02"]}, projects)

      assert_received :lookup

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
      assert_received :lookup
      refute_received :lookup

      polled(repo, [issue("TP"), %Issue{id: "no-team"}, issue("TP")])

      assert {:ok, %{source: :issues, teams: ["TP"], unresolved_projects: ["Gone"]}} = resolve(repo, [])
    end

    test "a failed projects lookup is an error", %{repo_key: key} do
      failing = fn -> {:error, :timeout} end
      assert {:error, :timeout} = RepoTeams.resolve(%{name: key, projects: ["Symphony"]}, tracker: @tracker, projects: failing)
    end

    test "reads the running config's issues settings and the tracker by default", %{repo_key: key} do
      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, [@symphony])

      assert {:ok, %{source: :projects, teams: ["TP"]}} = RepoTeams.resolve(%{name: key, projects: ["Symphony"]})
      assert_received {:memory_tracker_projects_and_teams}

      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, {:error, :timeout})
      assert {:error, :timeout} = RepoTeams.resolve(%{name: key, projects: ["Symphony"]})
    end

    test "a config that doesn't load leaves only the route's own team and projects", %{repo_key: key} do
      File.write!(Workflow.symphony_file_path(), "pull_request: 1\n")
      Cache.clear()

      assert {:ok, %{source: :none, projects: []}} = RepoTeams.resolve(%{name: key}, projects: lookup([]))
      assert {:ok, %{source: :route, teams: ["TP"]}} = RepoTeams.resolve(%{name: key, team: "TP"})
    end

    test "reads through the running Setup server's team cache, one request for every repo", %{repo_key: key} do
      web = %{id: "p2", name: "Web", slug_id: "w", team_keys: ["WEB"]}
      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, [@symphony, web])
      start_supervised!({Setup, checks: [], name: Setup})
      assert %TeamCache{} = Setup.team_cache()

      assert {:ok, %{teams: ["TP"]}} = RepoTeams.resolve(%{name: key, projects: ["Symphony"]})
      assert {:ok, %{teams: ["WEB"]}} = RepoTeams.resolve(%{name: "#{key}-web", projects: ["Web"]})

      assert_received {:memory_tracker_projects_and_teams}
      refute_received {:memory_tracker_projects_and_teams}
    end
  end

  describe "routed_teams/2" do
    test "the resolved teams", %{repo_key: key} do
      assert RepoTeams.routed_teams(%{name: key, team: "TP"}, tracker: @tracker) == ["TP"]
      assert RepoTeams.routed_teams(%{name: key, projects: ["Gone"]}, tracker: @tracker, projects: lookup([])) == []
    end

    test "a failed projects lookup is logged and the polled issues' teams still count", %{repo_key: key} do
      repo = %{name: key, projects: ["Symphony"]}
      polled(repo, [issue("OPS")])

      log =
        capture_log(fn ->
          assert RepoTeams.routed_teams(repo, tracker: @tracker, projects: fn -> {:error, :timeout} end) == ["OPS"]
        end)

      assert log =~ "Could not look up the Linear teams of repo=#{key}'s routed projects: :timeout"
    end
  end

  describe "issue_teams/1" do
    test "the teams of the last poll under the repo's current route", %{repo_key: key} do
      repo = %{name: key, team: nil, projects: ["Symphony"]}
      assert RepoTeams.issue_teams(repo) == []
      assert RepoTeams.issue_teams(%{team: "TP"}) == []

      polled(repo, [issue("OPS"), issue("TP"), issue("OPS")])
      assert RepoTeams.issue_teams(repo) == ["OPS", "TP"]

      # A failed poll keeps the last one; a route change starts over.
      PollLog.record(repo, {:error, :timeout})
      assert RepoTeams.issue_teams(repo) == ["OPS", "TP"]
      assert RepoTeams.issue_teams(%{repo | projects: ["Web"]}) == []
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
