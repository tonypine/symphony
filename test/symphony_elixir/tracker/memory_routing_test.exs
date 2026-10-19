defmodule SymphonyElixir.Tracker.MemoryRoutingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Memory

  @project %{id: "8e6f0c39-6a8b-4c1e-9d0e-1f2a3b4c5d6e", name: "Symphony", slug_id: "a1abb875ac02"}

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      for key <- [:memory_tracker_recipient, :memory_tracker_projects_list, :memory_tracker_teams_list],
          do: Application.delete_env(:symphony_elixir, key)
    end)

    :ok
  end

  describe "projects_and_teams/0" do
    test "answers the seeded projects and teams, announcing each request" do
      assert Memory.projects_and_teams() == {:ok, %{projects: [], teams: []}}
      assert_received {:memory_tracker_projects_and_teams}

      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, [@project])
      Application.put_env(:symphony_elixir, :memory_tracker_teams_list, [%{id: "t1", key: "TP", name: "Tony Pine"}])
      assert Memory.projects_and_teams() == {:ok, %{projects: [Map.put(@project, :team_keys, [])], teams: [%{id: "t1", key: "TP", name: "Tony Pine"}]}}
    end

    test "a seeded project without team keys is in the teams of its issues" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{id: "i1", team: %{key: "TP", name: nil}, project: %{id: @project.id, name: nil, slug_id: nil}},
        %Issue{id: "i2", team: %{key: "OPS", name: nil}, project: %{id: nil, name: "Symphony", slug_id: nil}},
        %Issue{id: "i3", team: %{key: "TP", name: nil}, project: %{id: "other", name: nil, slug_id: nil}},
        %Issue{id: "i4", team: nil, project: %{id: @project.id, name: nil, slug_id: nil}},
        %Issue{id: "i5", team: %{key: "TP", name: nil}, project: nil}
      ])

      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, [@project, %{id: "seeded", team_keys: ["WEB"]}])

      assert {:ok, %{projects: [%{team_keys: ["TP", "OPS"]}, %{id: "seeded", team_keys: ["WEB"]}]}} = Memory.projects_and_teams()
    end

    test "passes on a configured error" do
      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, {:error, :timeout})
      assert Memory.projects_and_teams() == {:error, :timeout}

      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, [])
      Application.put_env(:symphony_elixir, :memory_tracker_teams_list, {:error, :forbidden})
      assert Memory.projects_and_teams() == {:error, :forbidden}
    end

    test "reads projects, teams and each issue's team and project from the issues file" do
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      issues_file = Path.join(Path.dirname(Workflow.symphony_file_path()), "issues.json")

      File.write!(
        issues_file,
        Jason.encode!([
          %{"kind" => "project", "id" => @project.id, "name" => "Symphony", "slug_id" => "a1abb875ac02"},
          %{"kind" => "project", "id" => "p2", "name" => "Ops", "teams" => ["OPS", 7]},
          %{"kind" => "team", "id" => "t1", "key" => "TP", "name" => "Tony Pine"},
          %{"id" => "issue-1", "identifier" => "TP-1", "state" => "Todo", "team" => %{"key" => "TP"}, "project" => %{"id" => @project.id}},
          %{"id" => "issue-2", "identifier" => "TP-2", "state" => "Todo", "project" => "not a map"}
        ])
      )

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_memory_issues_file: "issues.json")

      assert Memory.projects_and_teams() ==
               {:ok,
                %{
                  projects: [Map.put(@project, :team_keys, ["TP"]), %{id: "p2", name: "Ops", slug_id: nil, team_keys: ["OPS"]}],
                  teams: [%{id: "t1", key: "TP", name: "Tony Pine"}]
                }}

      assert {:ok, [first, second]} = Memory.fetch_candidate_issues()
      assert first.team == %{key: "TP", name: nil}
      assert first.project == %{id: @project.id, name: nil, slug_id: nil}
      assert second.project == nil
    end
  end

  describe "fetch_candidate_issues_for_repo/1" do
    setup do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{id: "issue-1", identifier: "TP-1", state: "Todo", project: %{id: @project.id}},
        %Issue{id: "issue-2", identifier: "TP-2", state: "Todo", project: %{id: "other"}}
      ])

      :ok
    end

    test "a route value polls the issues of the project it names, as Linear filters it" do
      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, [@project])

      for value <- [@project.slug_id, @project.name, @project.id] do
        assert {:ok, [%Issue{id: "issue-1"}]} = Memory.fetch_candidate_issues_for_repo(%{name: "symphony", projects: [value]})
      end
    end

    test "a value no seeded project has matches the issue itself only" do
      assert {:ok, []} = Memory.fetch_candidate_issues_for_repo(%{name: "symphony", projects: [@project.slug_id]})

      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, {:error, :timeout})
      assert {:ok, [%Issue{id: "issue-2"}]} = Memory.fetch_candidate_issues_for_repo(%{name: "web", projects: ["other"]})
      assert {:ok, [_first, _second]} = Memory.fetch_candidate_issues_for_repo(%{name: "all"})
    end
  end
end
