defmodule SymphonyElixir.Routing.PollScopeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Routing.PollScope

  @slug "building-the-harness-f469eb38bbc5"
  @url "https://linear.app/acme/project/#{@slug}"
  @team_id "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e"
  @no_scope %{team: nil, project_slug: nil, labels: [], assignee: nil}

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-1",
        identifier: "TP-1",
        team: %{key: "TP", name: "Tony Pine"},
        project: %{id: "project-1", name: "Harness", url: @url},
        labels: ["backend"],
        assignee_id: "user-1"
      },
      attrs
    )
  end

  defp route(issue, repos, tracker \\ %{}, viewer_id \\ nil) do
    PollScope.route(issue, repos, tracker_settings: fn _repo_key -> {:ok, Map.merge(@no_scope, tracker)} end, viewer_id: fn -> viewer_id end)
  end

  test "an issue goes to the one repo whose scope takes it, as the poll's filter reads it" do
    harness = %{name: "harness", team: "TP", projects: [@slug]}
    other = %{name: "other", team: "OTHER"}

    assert route(issue(), [other, harness]) == {:ok, "harness"}
    assert route(issue(), [other]) == :unrouted
    assert route(issue(%{team: nil}), [harness]) == :unrouted
  end

  test "an issue two repos' scopes take is unrouted, a default repo included, as the poll counts a conflict" do
    repos = [%{name: "default", team: "TP", default: true}, %{name: "harness", team: "TP", projects: [@slug]}]
    assert route(issue(), repos) == :unrouted
  end

  test "a project is named by its name, its id, its URL's slug or the slug id that slug ends in" do
    for named <- ["Harness", "project-1", @slug, "f469eb38bbc5", "other-name-f469eb38bbc5"] do
      assert route(issue(), [%{name: "harness", projects: named}]) == {:ok, "harness"}, named
    end

    by_slug_id = issue(%{project: %{id: "project-1", name: "Harness", slug_id: "f469eb38bbc5"}})
    assert route(by_slug_id, [%{name: "harness", projects: [@slug]}]) == {:ok, "harness"}

    assert route(issue(), [%{name: "harness", projects: ["other-project"]}]) == :unrouted
    assert route(issue(%{project: nil}), [%{name: "harness", projects: [@slug]}]) == :unrouted
  end

  test "the tracker's project slug scopes a route that names no project" do
    assert route(issue(), [%{name: "harness"}], %{project_slug: @slug}) == {:ok, "harness"}
    assert route(issue(), [%{name: "harness"}], %{project_slug: "other"}) == :unrouted
    assert route(issue(), [%{name: "harness", projects: ["Harness"]}], %{project_slug: "other"}) == {:ok, "harness"}
  end

  test "a project whose slug the issue doesn't carry is uncertain, so nothing routes" do
    unslugged = issue(%{project: %{id: "project-1", name: "Harness"}})
    no_path = issue(%{project: %{id: "project-1", name: "Harness", url: "https://linear.app"}})

    for issue <- [unslugged, no_path] do
      assert route(issue, [%{name: "harness", projects: [@slug]}]) == :unrouted
      assert route(issue, [%{name: "other", team: "OTHER"}, %{name: "harness", projects: [@slug]}]) == :unrouted
    end

    assert route(unslugged, [%{name: "harness", projects: ["Harness"]}]) == {:ok, "harness"}
  end

  test "a team named by its key routes; one named by its id is uncertain" do
    assert route(issue(), [%{name: "harness"}], %{team: "TP"}) == {:ok, "harness"}
    assert route(issue(), [%{name: "harness", team: " "}], %{team: "TP"}) == {:ok, "harness"}
    assert route(issue(), [%{name: "harness", team: @team_id}]) == :unrouted
  end

  test "an assignee is the issue's assignee id; me is the key's user once a poll learned it" do
    assert route(issue(), [%{name: "harness", assignee: "user-1"}]) == {:ok, "harness"}
    assert route(issue(), [%{name: "harness", assignee: "user-2"}]) == :unrouted
    assert route(issue(), [%{name: "harness"}], %{assignee: "me"}, "user-1") == {:ok, "harness"}
    assert route(issue(), [%{name: "harness"}], %{assignee: "me"}, "user-2") == :unrouted
    assert route(issue(), [%{name: "harness"}], %{assignee: "me"}, nil) == :unrouted
  end

  test "a route's labels must all be on the issue; the tracker's, any of them" do
    assert route(issue(), [%{name: "harness", labels: ["Backend"]}]) == {:ok, "harness"}
    assert route(issue(), [%{name: "harness", labels: ["backend", "api"]}]) == :unrouted
    assert route(issue(), [%{name: "harness"}], %{labels: ["api", "Backend"]}) == {:ok, "harness"}
    assert route(issue(), [%{name: "harness"}], %{labels: ["api"]}) == :unrouted
    assert route(issue(%{labels: nil}), [%{name: "harness"}], %{labels: ["api"]}) == :unrouted
  end

  test "a repo without a name takes nothing; one whose settings can't be read leaves the issue unrouted" do
    assert route(issue(), [:junk, %{name: "  "}, %{name: "harness"}]) == {:ok, "harness"}
    assert PollScope.route(issue(), [%{name: "harness"}], tracker_settings: fn _repo_key -> {:error, :missing} end) == :unrouted
  end

  test "reads each repo's tracker settings and the known viewer by default" do
    repo_key = Config.repo_key!()
    {:ok, tracker} = Config.settings_for_repo(repo_key) |> then(fn {:ok, settings} -> {:ok, settings.tracker} end)
    project = %{id: "project-1", name: "Harness", url: "https://linear.app/acme/project/#{tracker.project_slug}"}

    assert PollScope.route(issue(%{project: project, team: %{key: "Test", name: "Test"}}), [%{name: repo_key}]) == {:ok, repo_key}
    assert PollScope.route(issue(), [%{name: repo_key}]) == :unrouted
    assert PollScope.route(issue(%{project: project}), [%{name: "harness", assignee: "me"}], tracker_settings: fn _ -> {:ok, @no_scope} end) == :unrouted
  end
end
