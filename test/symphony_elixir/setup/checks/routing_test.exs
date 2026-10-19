defmodule SymphonyElixir.Setup.Checks.RoutingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.Routing.{PollLog, Resolver}
  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.Checks.Routing

  @t0 ~U[2026-10-19 09:00:00Z]

  @symphony_id "8e6f0c39-6a8b-4c1e-9d0e-1f2a3b4c5d6e"
  @symphony_slug "a1abb875ac02"
  @jobs_id "2b7d1e44-0c5f-4a8e-8f3d-6c5b4a392817"

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ets.delete_all_objects(PollLog)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_projects_list, [
      %{id: @symphony_id, name: "Symphony", slug_id: @symphony_slug},
      %{id: @jobs_id, name: "Job search", slug_id: "c3d4e5f60718"},
      %{id: "web-a", name: "Web A", slug_id: "d4e5f6071829"},
      %{id: "web-b", name: "Web B", slug_id: "e5f60718293a"}
    ])

    Application.put_env(:symphony_elixir, :memory_tracker_teams_list, [
      %{id: "team-tp", key: "TP", name: "Tony Pine"},
      %{id: "team-ops", key: "OPS", name: "Operations"}
    ])

    on_exit(fn ->
      :ets.delete_all_objects(PollLog)

      for key <- [:memory_tracker_recipient, :memory_tracker_projects_list, :memory_tracker_teams_list],
          do: Application.delete_env(:symphony_elixir, key)
    end)

    :ok
  end

  defp issue(number, attrs \\ []) do
    struct!(
      %Issue{
        id: "issue-#{number}",
        identifier: "TP-#{number}",
        title: "Ticket #{number}",
        state: "Todo",
        url: "https://linear.app/tonypine/issue/TP-#{number}",
        team: %{key: "TP", name: "Tony Pine"},
        # As Linear gives it for the walkthrough: the project's UUID and nothing else.
        project: %{id: @symphony_id}
      },
      attrs
    )
  end

  defp repo(key, route, attrs \\ %{}), do: Map.merge(%{"key" => key, "route" => route}, attrs)

  defp route!(repos) do
    path = Workflow.symphony_file_path()
    repos = Enum.map(repos, &Map.put(&1, "workflow", Workflow.workflow_file_path()))
    File.write!(path, String.replace(File.read!(path), ~r/^repositories: .*$/m, "repositories: " <> Jason.encode!(repos)))
    Cache.clear()
  end

  defp issues!(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  # Each repo's poll, as the orchestrator's poll task records it.
  defp poll!(at \\ @t0) do
    for repo <- Config.system!().repos, do: PollLog.record(repo, Tracker.fetch_candidate_issues_for_repo(repo), at)
  end

  defp record!(name, issues) do
    repo = Enum.find(Config.system!().repos, &(&1.name == name))
    PollLog.record(repo, {:ok, issues}, @t0)
  end

  defp problems(now \\ @t0) do
    %{problems: problems, not_checked: []} = Setup.check(checks: [Routing], now: fn -> now end)
    problems
  end

  defp detail(problem, label), do: Enum.find_value(problem.details, &(&1.label == label && &1.value))

  test "names itself and reads Linear; without a config it has nothing to check" do
    assert Routing.id() == "routing"
    assert Routing.title() == "Each repo's route in Linear"
    assert Routing.needs_linear?()
    assert Routing in Setup.checks()
    assert Routing.run(%{system: nil}) == []
  end

  describe "round-trip" do
    test "a repo routed by a slug its polled tickets don't carry is an error, and its fix routes them back" do
      route!([repo("symphony", %{"projects" => [@symphony_slug]})])
      issues!(Enum.map(1..7, &issue/1))
      poll!()

      assert [problem] = problems()
      assert problem.id == "routing:round_trip:symphony"
      assert problem.severity == "error"
      assert problem.category == "routing"
      assert problem.title == "7 tickets symphony polls don't route back to it"
      assert problem.consequence =~ "Inbox decisions fail"
      assert problem.repos == ["symphony"]
      assert problem.tickets == Enum.map(1..5, &%{identifier: "TP-#{&1}", url: "https://linear.app/tonypine/issue/TP-#{&1}"})
      assert detail(problem, "Route") == "projects #{@symphony_slug}"
      assert detail(problem, "Resolves") == "0 of 7 come back to symphony"
      assert detail(problem, "Fix adds") == "project #{@symphony_id} to route.projects"
      assert problem.fix == %{kind: "config_edit", path: "repositories[symphony].route.projects", action: "add", value: @symphony_id}

      # The app applies the fix: the old route's poll is not judged against the new route.
      route!([repo("symphony", %{"projects" => [@symphony_slug, @symphony_id]})])
      assert problems() == []

      poll!()
      assert problems() == []
      repos = Config.system!().repos
      assert Enum.all?(Enum.map(1..7, &issue/1), &(Resolver.with_repo_key(&1, repos).repo_key == "symphony"))
    end

    test "the fix names the project, and is offered only when adding its id routes every ticket back" do
      route!([
        repo("named", %{"projects" => [@symphony_slug]}),
        repo("loose", %{"team" => "OPS"}),
        repo("labelled", %{"projects" => [@symphony_slug], "labels" => ["backend"]}),
        repo("listed", %{"projects" => [@symphony_id], "labels" => ["frontend"]})
      ])

      record!("named", [issue(1, project: %{id: @symphony_id, name: "Symphony"})])
      # No project to add.
      record!("loose", [issue(2, project: nil)])
      # Adding the id still leaves the label unmatched.
      record!("labelled", [issue(3)])
      # The id is on the route already.
      record!("listed", [issue(4)])

      assert [named, loose, labelled, listed] = problems()
      assert named.title == "1 ticket named polls don't route back to it"
      assert named.consequence =~ "which repo it belongs to"
      assert detail(named, "Fix adds") == "project Symphony (#{@symphony_id}) to route.projects"
      assert named.fix.kind == "config_edit"

      for problem <- [loose, labelled, listed] do
        assert problem.fix == %{kind: "open", target: "repos", url: nil}
        refute detail(problem, "Fix adds")
      end

      assert detail(loose, "Route") == "team OPS"
      assert detail(labelled, "Route") == "projects #{@symphony_slug}; labels backend"
    end

    test "a default repo's poll of tickets a scoped repo takes is routing as designed" do
      route!([repo("catch-all", %{"team" => "TP"}, %{"default" => true}), repo("symphony", %{"projects" => [@symphony_id]})])
      issues!([issue(1), issue(2, project: nil)])
      poll!()

      assert problems() == []
    end

    test "a default repo's ticket that routes nowhere is an error of the default repo" do
      route!([repo("catch-all", %{"team" => "TP"}, %{"default" => true}), repo("symphony", %{"projects" => [@symphony_id]})])
      record!("catch-all", [issue(1, team: %{key: "OPS"}, project: nil)])

      assert [%{id: "routing:round_trip:catch-all", fix: %{kind: "open"}}] = problems()
    end
  end

  describe "unknown route values" do
    test "a project or team Linear doesn't have is an error; one near match gets a set fix" do
      route!([
        repo("typo", %{"projects" => ["a1abb875ac03", "Job search"]}),
        repo("missing", %{"projects" => ["nothing-like-this"]}),
        repo("vague", %{"projects" => ["Web C"]}),
        repo("cased", %{"team" => "ops"}),
        repo("short", %{"team" => "ZZ", "labels" => ["x"]}),
        repo("by-id", %{"team" => "team-tp", "labels" => ["y"]})
      ])

      assert [typo, missing, vague, cased, short] = problems()

      assert typo.id == "routing:unknown_project:typo:a1abb875ac03"
      assert typo.severity == "error"
      assert typo.title == ~s(typo routes by project "a1abb875ac03", which Linear doesn't have)
      assert detail(typo, "Key") == "repositories[typo].route.projects"
      assert detail(typo, "Near match") == "Symphony (slug id #{@symphony_slug}, id #{@symphony_id})"
      assert typo.fix == %{kind: "config_edit", path: "repositories[typo].route.projects", action: "set", value: [@symphony_id, "Job search"]}

      assert missing.fix == nil
      assert detail(missing, "Looked for") == ~s(a Linear project whose id, slug id or name is "nothing-like-this")
      refute detail(missing, "Near match")

      # Web A and Web B are both one letter off.
      assert vague.fix == nil

      assert cased.id == "routing:unknown_team:cased"
      assert cased.title == ~s(cased routes by team "ops", which Linear doesn't have)
      assert detail(cased, "Near match") == "Operations (key OPS)"
      assert cased.fix == %{kind: "config_edit", path: "repositories[cased].route.team", action: "set", value: "OPS"}

      # Two letters are too short for an edit distance to mean anything.
      assert short.fix == nil
      assert detail(short, "Looked for") == ~s(a Linear team whose key or id is "ZZ")

      # One request for the projects and teams, however many values the routes name.
      assert_received {:memory_tracker_projects_and_teams}
      refute_received {:memory_tracker_projects_and_teams}
    end

    test "routes that name no project or team ask Linear nothing" do
      route!([repo("only", %{"labels" => ["backend"]})])

      assert problems() == []
      refute_received {:memory_tracker_projects_and_teams}
    end

    test "a workspace that lists no team calls no value unknown" do
      Application.put_env(:symphony_elixir, :memory_tracker_teams_list, [])
      route!([repo("missing", %{"projects" => ["nothing-like-this"]})])

      assert problems() == []
    end

    test "a failed read of the projects leaves the check not checked" do
      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, {:error, :boom})
      route!([repo("symphony", %{"projects" => [@symphony_slug]})])

      assert %{problems: [], not_checked: [%{id: "routing", reason: reason}]} = Setup.check(checks: [Routing], now: fn -> @t0 end)
      assert reason =~ "couldn't reach Linear"
    end
  end

  describe "overlapping routes" do
    test "two repos taking the same tickets are one error naming both" do
      route!([repo("symphony", %{"projects" => [@symphony_id]}), repo("web", %{"projects" => [@symphony_slug]})])
      issues!([issue(2), issue(1)])
      poll!()

      assert [problem] = problems()
      assert problem.id == "routing:overlap:symphony+web"
      assert problem.severity == "error"
      assert problem.title == "symphony and web both take the same tickets"
      assert problem.consequence =~ "runs none of them"
      assert problem.repos == ["symphony", "web"]
      assert Enum.map(problem.tickets, & &1.identifier) == ["TP-1", "TP-2"]
      assert detail(problem, "symphony route") == "projects #{@symphony_id}"
      assert detail(problem, "web route") == "projects #{@symphony_slug}"
      assert detail(problem, "Tickets") == "2 tickets"
      assert problem.fix == %{kind: "open", target: "repos", url: nil}
    end

    test "repos whose routes all match a ticket are named together" do
      route!([
        repo("api", %{"labels" => ["backend"], "assignee" => "me"}),
        repo("symphony", %{"projects" => [@symphony_id]}),
        repo("web", %{"projects" => [@symphony_slug]})
      ])

      issues!([issue(1, labels: ["backend"], assignee_id: "me")])
      poll!()

      assert [problem] = problems()
      assert problem.title == "api, symphony and web all take the same ticket"
      assert problem.consequence =~ "should run it"
      assert detail(problem, "api route") == "labels backend; assignee me"
    end
  end

  describe "idle repos" do
    test "a route that matched nothing for 24 hours is a warning" do
      route!([repo("symphony", %{"projects" => [@jobs_id]})])
      issues!([issue(1)])
      poll!(@t0)
      poll!(DateTime.add(@t0, 3600))

      assert problems(DateTime.add(@t0, 23 * 3600)) == []

      assert [problem] = problems(DateTime.add(@t0, 24 * 3600))
      assert problem.id == "routing:idle:symphony"
      assert problem.severity == "warning"
      assert problem.title == "symphony's route matched no ticket in 24 hours"
      assert problem.consequence =~ "since 2026-10-19T09:00:00Z"
      assert detail(problem, "Route") == "projects #{@jobs_id}"
      assert detail(problem, "Nothing since") == "2026-10-19T09:00:00Z"
      assert problem.fix == nil

      issues!([issue(1, project: %{id: @jobs_id})])
      poll!(DateTime.add(@t0, 25 * 3600))
      assert problems(DateTime.add(@t0, 50 * 3600)) == []
    end

    test "a repo with no route of its own says so" do
      route!([repo("only", %{})])
      issues!([])
      poll!()

      assert [problem] = problems(DateTime.add(@t0, 24 * 3600))
      assert detail(problem, "Route") == "no route of its own (the tracker's scope)"
    end
  end

  test "a healthy multi-repo config returns no routing problems" do
    route!([
      repo("catch-all", %{"team" => "TP"}, %{"default" => true}),
      repo("symphony", %{"projects" => [@symphony_slug, @symphony_id]}),
      repo("jobs", %{"projects" => ["Job search"]})
    ])

    issues!([issue(1), issue(2, project: %{id: @jobs_id, name: "Job search", slug_id: "c3d4e5f60718"}), issue(3, project: nil)])
    poll!()

    assert problems() == []
  end
end
