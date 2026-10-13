defmodule SymphonyElixir.Routing.ResolverTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Routing.Resolver

  describe "resolve/2" do
    test "returns the matched repo for a unique team-only route" do
      web = repo("web", team: "ACME")
      api = repo("api", team: "API")
      issue = issue(team: %{key: "ACME", name: "Acme Team"})

      assert Resolver.resolve(issue, [web, api]) == {:matched, web}
    end

    test "returns a conflict when multiple repos match" do
      backend = repo("backend", team: "ACME", labels: ["backend"])
      api = repo("api", team: "ACME", labels: ["api"])
      issue = issue(team: %{key: "ACME"}, labels: ["backend", "api"])

      assert Resolver.resolve(issue, [backend, api]) == {:conflict, [backend, api]}
    end

    test "returns unmatched when no repos match" do
      issue = issue(team: %{key: "ACME"})

      assert Resolver.resolve(issue, [repo("api", team: "API")]) == :unmatched
    end

    test "matches team plus projects with any-of semantics" do
      repo = repo("web", team: "ACME", projects: ["Project Alpha", "Project Beta"])

      matching_issue = issue(team: %{key: "ACME"}, project: %{id: "project-1", name: "Project Beta"})
      other_project_issue = issue(team: %{key: "ACME"}, project: %{id: "project-2", name: "Project Gamma"})

      assert Resolver.resolve(matching_issue, [repo]) == {:matched, repo}
      assert Resolver.resolve(other_project_issue, [repo]) == :unmatched
      assert Resolver.resolve(issue(team: %{key: "ACME"}), [repo]) == :unmatched
    end

    test "matches team plus labels with AND semantics" do
      repo = repo("web", team: "ACME", labels: ["Backend", "API"])

      matching_issue = issue(team: %{key: "ACME"}, labels: ["api", "backend", "urgent"])
      missing_label_issue = issue(team: %{key: "ACME"}, labels: ["api"])

      assert Resolver.resolve(matching_issue, [repo]) == {:matched, repo}
      assert Resolver.resolve(missing_label_issue, [repo]) == :unmatched
    end

    test "matches labels without requiring a team selector" do
      repo = repo("web", labels: ["Backend"])

      assert Resolver.resolve(issue(team: %{key: "ACME"}, labels: ["backend"]), [repo]) == {:matched, repo}
    end

    test "matches team plus assignee by id, name, or email" do
      id_repo = repo("by-id", team: "ACME", assignee: "user-1")
      name_repo = repo("by-name", team: "ACME", assignee: "Chi Hsuan")
      email_repo = repo("by-email", team: "ACME", assignee: "chi@example.com")

      assert Resolver.resolve(issue(team: %{key: "ACME"}, assignee_id: "user-1"), [id_repo]) ==
               {:matched, id_repo}

      assert Resolver.resolve(%{team: %{key: "ACME"}, assignee: %{name: "Chi Hsuan"}}, [name_repo]) ==
               {:matched, name_repo}

      assert Resolver.resolve(%{team: %{key: "ACME"}, assignee: %{email: "chi@example.com"}}, [email_repo]) ==
               {:matched, email_repo}
    end

    test "matches all selectors together" do
      repo =
        repo("web",
          team: "ACME",
          projects: ["project-1"],
          labels: ["backend", "agent-ready"],
          assignee: "user-1"
        )

      issue =
        issue(
          team: %{key: "ACME"},
          project: %{id: "project-1", name: "Project Alpha"},
          labels: ["agent-ready", "backend", "triaged"],
          assignee_id: "user-1"
        )

      assert Resolver.resolve(issue, [repo]) == {:matched, repo}
    end

    test "matches canonical repo structs from the system schema" do
      repo =
        struct!(SystemSchema.Repo,
          name: "web",
          path: "/tmp/web",
          workflow: "WORKFLOW.md",
          team: "ACME",
          labels: ["backend"]
        )

      issue = issue(team: %{key: "ACME"}, labels: ["backend", "triaged"])

      assert Resolver.resolve(issue, [repo]) == {:matched, repo}
    end
  end

  describe "matches?/2" do
    test "supports string-keyed repo entries" do
      issue = issue(team: %{name: "Acme Team"}, labels: ["backend"])

      assert Resolver.matches?(issue, %{
               "name" => "web",
               "team" => "Acme Team",
               "labels" => ["backend"]
             })
    end

    test "supports scalar project values and non-string label values" do
      issue = %{team: "ACME", project: "project-1", labels: ["backend"]}
      repo = %{"name" => "web", "team" => "ACME", "projects" => "project-1", "labels" => [:Backend]}

      assert Resolver.matches?(issue, repo)
    end

    test "returns false for invalid routes" do
      refute Resolver.matches?(issue(team: %{key: "ACME"}), :not_a_repo)
      refute Resolver.matches?(nil, repo("web", team: "ACME"))
      refute Resolver.matches?(:not_an_issue, repo("web", team: "ACME"))
    end
  end

  describe "validate_repos/1" do
    test "accepts distinct match rules" do
      assert :ok =
               Resolver.validate_repos([
                 repo("web", team: "ACME", labels: ["web"]),
                 repo("api", team: "ACME", labels: ["api"]),
                 repo("docs", team: "DOCS")
               ])
    end

    test "accepts single unscoped repo" do
      assert :ok = Resolver.validate_repos([repo("web")])
    end

    test "accepts routes scoped without a team" do
      web = repo("web", labels: ["web"])
      api = repo("api", projects: ["API"])

      assert :ok = Resolver.validate_repos([web, api])
    end

    test "rejects unscoped non-default repos when multiple repos are configured" do
      blank_team = repo("blank", team: " ")
      missing_team = %{"name" => "missing"}

      assert {:error, errors} = Resolver.validate_repos([blank_team, missing_team])
      assert Enum.any?(errors, &match?({:unscoped_repo, ^blank_team}, &1))
      assert Enum.any?(errors, &match?({:unscoped_repo, ^missing_team}, &1))

      assert :ok = Resolver.validate_repos([Map.put(blank_team, :default, true), repo("api", labels: ["api"])])
    end

    test "rejects identical match rules across repos" do
      web = repo("web", team: "ACME", projects: ["P2", "P1"], labels: ["Backend", "API"], assignee: "user-1")
      api = repo("api", team: "ACME", projects: ["P1", "P2"], labels: ["api", "backend"], assignee: "user-1")

      assert {:error, errors} = Resolver.validate_repos([web, api])

      assert Enum.any?(errors, fn
               {:identical_match_rules, repos} -> repos == [web, api]
               _error -> false
             end)
    end

    test "rejects multiple team-only catch-all repos for the same team" do
      web = repo("web", team: "ACME")
      api = repo("api", team: "ACME")

      assert {:error, errors} = Resolver.validate_repos([web, api])

      assert Enum.any?(errors, fn
               {:ambiguous_team_catch_all, "ACME", repos} -> repos == [web, api]
               _error -> false
             end)
    end

    test "requires an explicit default when a team catch-all shares a team with specific repos" do
      catch_all = repo("default", team: "ACME")
      api = repo("api", team: "ACME", labels: ["api"])

      assert {:error, errors} = Resolver.validate_repos([catch_all, api])

      assert Enum.any?(errors, fn
               {:ambiguous_team_catch_all, "ACME", repos} -> repos == [catch_all]
               _error -> false
             end)

      assert :ok = Resolver.validate_repos([Map.put(catch_all, :default, true), api])
    end

    test "rejects more than one default repo per team" do
      web = repo("web", team: "ACME", labels: ["web"], default: true)
      api = repo("api", team: "ACME", labels: ["api"], default: true)

      assert {:error, errors} = Resolver.validate_repos([web, api])

      assert Enum.any?(errors, fn
               {:multiple_defaults, "ACME", repos} -> repos == [web, api]
               _error -> false
             end)
    end
  end

  describe "validate_repos!/1" do
    test "returns ok for valid repo rules" do
      assert Resolver.validate_repos!([repo("web", team: "ACME")]) == :ok
    end

    test "raises on invalid repo rules" do
      assert_raise ArgumentError, ~r/invalid routing repos/, fn ->
        Resolver.validate_repos!([repo("web"), repo("api")])
      end
    end
  end

  describe "with_repo_key/2" do
    test "gives a fetched issue the key of the repo its project routes to" do
      repos = [repo("symphony", team: "TP", projects: ["Symphony"]), repo("site", team: "TP", projects: ["Site"])]
      issue = issue(team: %{key: "TP"}, project: %{name: "Symphony"})

      assert Resolver.with_repo_key(issue, repos).repo_key == "symphony"
    end

    test "routes a fetched issue by its project's slug id, as route.projects names it" do
      repos = [repo("symphony", team: "TP", projects: ["0c2a9b1d7e3f"]), repo("site", team: "TP", projects: ["9f8e7d6c5b4a"])]
      issue = issue(team: %{key: "TP"}, project: %{id: "project-uuid", name: "Symphony", slug_id: "0c2a9b1d7e3f"})

      assert Resolver.with_repo_key(issue, repos).repo_key == "symphony"
    end

    test "keeps the key an issue already has" do
      issue = issue(team: %{key: "TP"}, repo_key: "polled")

      assert Resolver.with_repo_key(issue, [repo("symphony", team: "TP")]).repo_key == "polled"
    end

    test "prefers the one scoped repo over the team's default, and leaves an ambiguous or unrouted issue alone" do
      default = repo("catch-all", team: "TP", default: true)
      scoped = repo("symphony", team: "TP", projects: ["Symphony"])
      issue = issue(team: %{key: "TP"}, project: %{name: "Symphony"}, repo_key: "")

      assert Resolver.with_repo_key(issue, [default, scoped]).repo_key == "symphony"
      assert Resolver.with_repo_key(issue, [scoped, repo("other", team: "TP", labels: [])]).repo_key == ""
      assert Resolver.with_repo_key(issue, [repo("api", team: "API")]).repo_key == ""
    end
  end

  defp repo(name, attrs \\ []) do
    attrs
    |> Map.new()
    |> Map.put(:name, name)
  end

  defp issue(attrs) do
    struct!(Issue, attrs)
  end
end
