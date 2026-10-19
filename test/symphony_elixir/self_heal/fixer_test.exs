defmodule SymphonyElixir.SelfHeal.FixerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Linear, RepoTeams}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.SelfHeal.Fixer

  @scope "repo-symphony"
  # `issues` settings with no team and no project, whatever the test config names.
  @no_issues_scope %{team: nil, project_slug: nil}

  # The tracker the fixer reads the fix ticket from and comments on.
  defmodule Tracker do
    def fetch_issue_by_identifier(identifier), do: Process.get({:fix_ticket, identifier}, {:error, :not_found})

    def create_comment(issue_id, body) do
      Process.put(:comment, {issue_id, body})
      Process.get(:comment_result, :ok)
    end
  end

  # The Linear client the adapter calls, dispatched on the operation name in the query.
  defmodule LinearClient do
    def graphql(query, variables) do
      Process.put(:graphql_calls, [{query, variables} | Process.get(:graphql_calls, [])])

      cond do
        query =~ "SymphonyTeams" -> Process.get(:teams_result, {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "t1", "key" => "TP"}]}}}})
        query =~ "SymphonyCreateIssueScope" -> Process.get(:scope_result, {:ok, scope_response()})
        query =~ "SymphonyCreateIssueRelation" -> Process.get(:relation_result, {:ok, %{"data" => %{"issueRelationCreate" => %{"success" => true}}}})
        query =~ "SymphonyCreateIssue" -> Process.get(:create_result, {:ok, create_response()})
        query =~ "SymphonyProjectTeams" -> Process.get(:projects_result, {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}})
        query =~ "SymphonyIssueId" -> Process.get(:issue_id_result, {:ok, %{"data" => %{"issue" => %{"id" => "blocker-id"}}}})
        true -> flunk("unexpected query: #{query}")
      end
    end

    defp scope_response do
      %{
        "data" => %{
          "team" => %{
            "id" => "t1",
            "states" => %{"nodes" => [%{"id" => "s-todo", "name" => "Todo"}]},
            "projects" => %{
              "nodes" => [
                %{"id" => "p1", "name" => "Fix Project", "slugId" => "a1abb875ac02"},
                %{"id" => "p2", "name" => "Symphony", "slugId" => "b2"}
              ]
            }
          }
        }
      }
    end

    defp create_response do
      %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "i1", "identifier" => "TP-900", "url" => "https://linear.app/acme/issue/TP-900"}
          }
        }
      }
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, LinearClient)

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :linear_client_module, previous)
      else
        Application.delete_env(:symphony_elixir, :linear_client_module)
      end
    end)

    :ok
  end

  # The scope repo, and the issue filter its route polls with (no assignee unless a test gives one).
  defp repo(team, projects, scope_filter \\ {:ok, %{}}) do
    [repo: fn _scope -> {:ok, %{team: team, projects: projects}} end, scope_filter: fn _repo -> scope_filter end]
  end

  defp assignee_filter(ids), do: {:ok, %{"assignee" => %{"id" => %{"in" => ids}}}}

  defp created_input do
    {_query, %{input: input}} = Enum.find(Process.get(:graphql_calls), &(elem(&1, 0) =~ "SymphonyCreateIssue("))
    input
  end

  defp create_attrs do
    %{scope: @scope, component: "qa_environment", title: "Self-heal: repair the qa_environment block", description: "the evidence"}
  end

  describe "create/2" do
    test "files the fix ticket in Todo, at high priority, in the scope repo's team and project" do
      assert {:ok, %{identifier: "TP-900"}} = Fixer.create(create_attrs(), repo("TP", ["Fix Project"]))

      {_query, %{input: input}} = Enum.find(Process.get(:graphql_calls), &(elem(&1, 0) =~ "SymphonyCreateIssue("))
      assert input["teamId"] == "t1"
      assert input["stateId"] == "s-todo"
      assert input["projectId"] == "p1"
      assert input["title"] == "Self-heal: repair the qa_environment block"
      assert input["priority"] == 2
      refute Map.has_key?(input, "assigneeId")
    end

    test "assigns the fix ticket to the user the scope repo's route polls with, so Symphony picks it up" do
      opts = [
        repo: fn _scope -> {:ok, %{team: "TP", projects: ["Fix Project"], assignee: "me"}} end,
        scope_filter: fn repo ->
          send(self(), {:scope_filter, repo})
          assignee_filter(["viewer-id"])
        end
      ]

      assert {:ok, _ticket} = Fixer.create(Map.put(create_attrs(), :issue, %Issue{assignee_id: "someone-else"}), opts)

      assert_received {:scope_filter, %{assignee: "me"}}
      assert created_input()["assigneeId"] == "viewer-id"
    end

    test "a route with no assignee gives the fix ticket the affected ticket's assignee" do
      issue = %Issue{assignee_id: "affected-assignee"}

      assert {:ok, _ticket} = Fixer.create(Map.put(create_attrs(), :issue, issue), repo("TP", ["Fix Project"]))
      assert created_input()["assigneeId"] == "affected-assignee"

      Process.delete(:graphql_calls)
      assert {:ok, _ticket} = Fixer.create(Map.put(create_attrs(), :issue, issue), repo("TP", ["Fix Project"], assignee_filter([])))
      assert created_input()["assigneeId"] == "affected-assignee"
    end

    test "an assignee that cannot be resolved still files the fix ticket, with the affected ticket's assignee" do
      opts = repo("TP", ["Fix Project"], {:error, :missing_linear_api_token})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          issue = %Issue{id: "affected-id", identifier: "TP-1", assignee_id: "affected-assignee"}
          assert {:ok, _ticket} = Fixer.create(Map.put(create_attrs(), :issue, issue), opts)
        end)

      assert log =~ "issue_id=affected-id issue_identifier=TP-1 repo=#{@scope} reason=:missing_linear_api_token"
      assert created_input()["assigneeId"] == "affected-assignee"

      Process.delete(:graphql_calls)

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, _ticket} = Fixer.create(create_attrs(), opts) end)

      assert log =~ "issue_id= issue_identifier= repo=#{@scope}"
      refute Map.has_key?(created_input(), "assigneeId")
    end

    test "an Urgent affected ticket files an Urgent fix ticket, so tickets.priorities dispatches it" do
      assert {:ok, _ticket} = Fixer.create(Map.put(create_attrs(), :issue, %Issue{priority: 1}), repo("TP", ["Fix Project"]))

      assert created_input()["priority"] == 1
    end

    test "a High affected ticket files a High fix ticket" do
      assert {:ok, _ticket} = Fixer.create(Map.put(create_attrs(), :issue, %Issue{priority: 2}), repo("TP", ["Fix Project"]))

      assert created_input()["priority"] == 2
    end

    test "an affected ticket with no priority, or a lower one, files a High fix ticket" do
      for priority <- [nil, 0, 3, 4] do
        Process.delete(:graphql_calls)

        assert {:ok, _ticket} = Fixer.create(Map.put(create_attrs(), :issue, %Issue{priority: priority}), repo("TP", ["Fix Project"]))

        assert created_input()["priority"] == 2
      end
    end

    test "an explicit priority and a repo with no project are carried through" do
      assert {:ok, %{identifier: "TP-900"}} = Fixer.create(Map.merge(create_attrs(), %{issue: %Issue{project: nil}, repo_key: @scope}), repo("TP", []) ++ [priority: 1])

      {_query, %{input: input}} = Enum.find(Process.get(:graphql_calls), &(elem(&1, 0) =~ "SymphonyCreateIssue("))
      assert input["priority"] == 1
      refute Map.has_key?(input, "projectId")
    end

    test "a repo routed only by project files in the affected ticket's team and project" do
      issue = %Issue{id: "affected-id", team: %{key: "TP", name: "Tony"}, project: %{id: "p2", name: "Symphony"}}

      assert {:ok, %{identifier: "TP-900"}} =
               Fixer.create(Map.merge(create_attrs(), %{issue: issue, repo_key: @scope}), repo(nil, ["a1abb875ac02"]))

      {_query, %{input: input}} = Enum.find(Process.get(:graphql_calls), &(elem(&1, 0) =~ "SymphonyCreateIssue("))
      assert input["teamId"] == "t1"
      assert input["projectId"] == "p2"
    end

    test "a fix for another repo files in that repo's routed project, matched by its slug id" do
      issue = %Issue{id: "affected-id", team: %{key: "TP", name: "Tony"}, project: %{id: "p2", name: "Symphony"}}

      assert {:ok, %{identifier: "TP-900"}} =
               Fixer.create(Map.merge(create_attrs(), %{issue: issue, repo_key: "repo-other"}), repo("", ["a1abb875ac02"]))

      {_query, %{input: input}} = Enum.find(Process.get(:graphql_calls), &(elem(&1, 0) =~ "SymphonyCreateIssue("))
      assert input["projectId"] == "p1"
    end

    test "a repo routed only by project files in its project's team when the affected ticket carries none" do
      project = %{"id" => "p1", "name" => "Fix Project", "slugId" => "a1abb875ac02", "teams" => %{"nodes" => [%{"id" => "t1", "key" => "TP"}]}}
      Process.put(:projects_result, {:ok, %{"data" => %{"projects" => %{"nodes" => [project]}}}})

      # Through the Linear adapter's projects lookup, whichever tracker the test config names.
      lookup = fn refs -> Linear.Adapter.fetch_projects(refs) end
      routed_teams = &RepoTeams.routed_teams(&1, tracker: @no_issues_scope, projects: lookup)
      opts = Keyword.put(repo(nil, ["a1abb875ac02"]), :routed_teams, routed_teams)

      assert {:ok, %{identifier: "TP-900"}} = Fixer.create(Map.merge(create_attrs(), %{issue: %Issue{id: "affected-id"}}), opts)

      {_query, %{input: input}} = Enum.find(Process.get(:graphql_calls), &(elem(&1, 0) =~ "SymphonyCreateIssue("))
      assert input["teamId"] == "t1"
      assert input["projectId"] == "p1"
    end

    test "the first routed team counts, as `RepoTeams` resolves it" do
      opts = Keyword.put(repo(nil, []), :routed_teams, fn _repo -> ["TP", "OPS"] end)

      assert {:ok, %{identifier: "TP-900"}} = Fixer.create(create_attrs(), opts)

      {_query, %{input: input}} = Enum.find(Process.get(:graphql_calls), &(elem(&1, 0) =~ "SymphonyCreateIssue("))
      assert input["teamId"] == "t1"
    end

    test "reports a repo that cannot own a fix ticket, or one that cannot be resolved" do
      # No route team, no `issues` team or project, no project and no polled issue to find one in.
      routed_teams = &RepoTeams.routed_teams(&1, tracker: @no_issues_scope)
      opts = Keyword.put(repo(nil, []), :routed_teams, routed_teams)
      assert {:error, {:self_heal_team_unknown, @scope}} = Fixer.create(create_attrs(), opts)

      assert {:error, :repo_not_found} = Fixer.create(create_attrs(), repo: fn _scope -> {:error, :repo_not_found} end)
    end
  end

  describe "attach/2" do
    test "comments the body on the fix ticket" do
      Process.put({:fix_ticket, "TP-900"}, {:ok, %Issue{id: "fix-id", identifier: "TP-900"}})

      assert :ok = Fixer.attach("TP-900", "the evidence", tracker: Tracker)
      assert Process.get(:comment) == {"fix-id", "the evidence"}
    end

    test "reports an unreadable ticket and a failed comment" do
      assert {:error, :not_found} = Fixer.attach("TP-900", "the evidence", tracker: Tracker)

      Process.put({:fix_ticket, "TP-900"}, {:ok, %Issue{id: "fix-id", identifier: "TP-900"}})
      Process.put(:comment_result, {:error, :rate_limited})

      assert {:error, :rate_limited} = Fixer.attach("TP-900", "the evidence", tracker: Tracker)
    end
  end

  describe "block/3" do
    test "records that the fix ticket blocks the affected ticket" do
      assert :ok = Fixer.block(%Issue{id: "affected-id"}, %{identifier: "TP-900"}, [])

      {_query, %{input: input}} = Enum.find(Process.get(:graphql_calls), &(elem(&1, 0) =~ "SymphonyCreateIssueRelation"))
      assert input == %{"issueId" => "blocker-id", "relatedIssueId" => "affected-id", "type" => "blocks"}
    end

    test "reports a relation that could not be recorded, and refuses invalid arguments" do
      Process.put(:relation_result, {:error, :rate_limited})
      assert {:error, :rate_limited} = Fixer.block(%Issue{id: "affected-id"}, %{identifier: "TP-900"}, [])

      Process.delete(:relation_result)
      Process.put(:issue_id_result, {:ok, %{"data" => %{"issue" => nil}}})
      assert {:error, {:issue_not_found, "TP-900"}} = Fixer.block(%Issue{id: "affected-id"}, %{identifier: "TP-900"}, [])

      assert {:error, :invalid_blocked_by} = Fixer.block(%Issue{id: nil}, %{identifier: "TP-900"}, [])
      assert {:error, :invalid_blocked_by} = Fixer.block(%Issue{id: "affected-id"}, %{identifier: nil}, [])
    end
  end
end
