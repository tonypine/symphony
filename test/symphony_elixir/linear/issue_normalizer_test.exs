defmodule SymphonyElixir.Linear.IssueNormalizerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.{Issue, IssueNormalizer}

  @fixtures Path.expand("../../fixtures/linear_webhook", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  describe "the poll's and the webhook's view of the same ticket" do
    test "agree field by field on what both carry" do
      poll = IssueNormalizer.from_graphql_node(fixture("issue_graphql_node.json"), nil)
      webhook = IssueNormalizer.from_webhook_data(fixture("issue_update.json")["data"])

      fields =
        [:id, :identifier, :title, :description, :state, :labels, :assignee_id, :priority, :url, :team] ++
          [:created_at, :updated_at]

      for field <- fields do
        assert Map.fetch!(poll, field) == Map.fetch!(webhook, field), "#{field} differs"
      end

      assert %Issue{identifier: "TP-1213", state: "In Progress", labels: ["elixir", "reads"], priority: 1} = webhook
      assert webhook.assignee_id == "e4f5a6b7-c8d9-4e0f-9a1b-3c4d5e6f7a8b"
      assert webhook.updated_at == ~U[2026-10-29 09:15:02.118Z]
      assert webhook.project == %{id: "c2d3e4f5-a6b7-4c8d-9e0f-1a2b3c4d5e6f", name: "Symphony", url: "https://linear.app/example/project/symphony-0a1b2c3d4e5f"}
      assert poll.project == webhook.project |> Map.delete(:url) |> Map.put(:slug_id, "0a1b2c3d4e5f")
    end

    test "leave what a delivery never carries unknown, not empty, where the poll knows it" do
      poll = IssueNormalizer.from_graphql_node(fixture("issue_graphql_node.json"), nil)
      webhook = IssueNormalizer.from_webhook_data(fixture("issue_update.json")["data"])

      assert poll.sub_issues == []
      assert [%{author: "Ada Operator"}] = poll.comments
      assert [%{identifier: "TP-1212", state: "Done"}] = poll.blocked_by
      assert poll.branch_name == "auto/TP-1213"

      assert webhook.sub_issues == :unknown
      assert webhook.comments == :unknown
      assert webhook.rulings == :unknown
      assert webhook.linked_issues == :unknown
      assert webhook.blocked_by == :unknown
      assert webhook.branch_name == :unknown
      refute Map.has_key?(webhook.project, :slug_id)
      assert webhook.assigned_to_worker
    end
  end

  describe "from_webhook_data/1" do
    test "reads relations and a branch name when a delivery has them, in either list shape" do
      blocker = %{"type" => "blocks", "issue" => %{"id" => "b1", "identifier" => "TP-1", "state" => %{"name" => "Todo"}}}

      for relations <- [[blocker], %{"nodes" => [blocker]}] do
        issue = IssueNormalizer.from_webhook_data(%{"id" => "i1", "inverseRelations" => relations, "branchName" => "auto/TP-2"})

        assert issue.blocked_by == [%{id: "b1", identifier: "TP-1", state: "Todo"}]
        assert issue.branch_name == "auto/TP-2"
      end

      assert IssueNormalizer.from_webhook_data(%{"inverseRelations" => nil}).blocked_by == []
    end

    test "reads a null assignee, a missing state, team, project and labels, and bad dates as nothing" do
      issue =
        IssueNormalizer.from_webhook_data(%{
          "id" => "i1",
          "assignee" => nil,
          "priority" => "high",
          "labels" => [%{"name" => nil}, "loose", %{"name" => "Plan"}],
          "description" => nil,
          "updatedAt" => "yesterday",
          "createdAt" => 42
        })

      assert %Issue{assignee_id: nil, state: nil, team: nil, project: nil, priority: nil, description: nil} = issue
      assert issue.labels == ["plan"]
      assert issue.updated_at == nil
      assert issue.created_at == nil
    end

    test "keeps a project's slug when a delivery gives one" do
      issue = IssueNormalizer.from_webhook_data(%{"project" => %{"id" => "p1", "name" => "Symphony", "slugId" => "0a1b"}})

      assert issue.project == %{id: "p1", name: "Symphony", slug_id: "0a1b"}
    end

    test "reads a state, a blocker's state or a project of the wrong shape as nothing, without raising" do
      blocker = %{"type" => "blocks", "issue" => %{"id" => "b1", "identifier" => "TP-1", "state" => "Done"}}

      for state <- ["Todo", ["Todo"], 7, %{"name" => 7}, %{}] do
        issue = IssueNormalizer.from_webhook_data(%{"state" => state, "inverseRelations" => [blocker], "project" => "Symphony"})

        assert issue.state == nil
        assert issue.blocked_by == [%{id: "b1", identifier: "TP-1", state: nil}]
        assert issue.project == nil
      end
    end

    test "is nil for anything but a map" do
      assert IssueNormalizer.from_webhook_data(nil) == nil
      assert IssueNormalizer.from_webhook_data("TP-1") == nil
    end
  end

  describe "from_graphql_node/2" do
    test "is nil for anything but a map" do
      assert IssueNormalizer.from_graphql_node(nil, nil) == nil
    end

    test "marks the issue the worker's when its assignee matches the filter" do
      node = fixture("issue_graphql_node.json")
      mine = %{match_values: MapSet.new(["e4f5a6b7-c8d9-4e0f-9a1b-3c4d5e6f7a8b"])}
      others = %{match_values: MapSet.new(["someone-else"])}

      assert IssueNormalizer.from_graphql_node(node, mine).assigned_to_worker
      refute IssueNormalizer.from_graphql_node(node, others).assigned_to_worker
      refute IssueNormalizer.from_graphql_node(Map.put(node, "assignee", %{"id" => "  "}), mine).assigned_to_worker
      refute IssueNormalizer.from_graphql_node(Map.put(node, "assignee", %{"id" => nil}), mine).assigned_to_worker
      refute IssueNormalizer.from_graphql_node(Map.put(node, "assignee", nil), mine).assigned_to_worker
    end

    test "skips relations other than blocks, malformed relations and malformed children" do
      node = %{
        "inverseRelations" => %{"nodes" => [%{"type" => "related", "issue" => %{"id" => "r1"}}, %{"type" => 1}]},
        "children" => %{
          "nodes" => [%{"id" => "c1", "identifier" => "TP-3", "state" => %{"name" => "Done"}}, %{"id" => "c2", "state" => "Done"}, "loose"]
        }
      }

      issue = IssueNormalizer.from_graphql_node(node, nil)

      assert issue.blocked_by == []
      assert issue.sub_issues == [%{id: "c1", identifier: "TP-3", state: "Done"}, %{id: "c2", identifier: nil, state: nil}]
    end
  end

  describe "comments/1" do
    test "keeps the workpad then the newest others, three in all, without empty bodies" do
      nodes =
        [
          %{"body" => "## Symphony Workpad\n\nplan", "user" => %{"name" => "Symphony"}},
          %{"body" => "one", "user" => %{"name" => " "}},
          %{"body" => "   "},
          %{"body" => "two"},
          %{"body" => "three", "createdAt" => "2026-10-29T09:00:00Z"},
          %{"id" => "no-body"}
        ]

      assert [
               %{author: "Symphony", body: "## Symphony Workpad\n\nplan"},
               %{body: "three", created_at: ~U[2026-10-29 09:00:00Z]},
               %{body: "two", author: "Unknown"}
             ] = IssueNormalizer.comments(%{"comments" => %{"nodes" => nodes}})

      assert [%{body: "two"}, %{body: "one", author: "Unknown"}] =
               IssueNormalizer.comments(%{"comments" => %{"nodes" => [%{"body" => "one"}, %{"body" => "two"}]}})

      assert IssueNormalizer.comments(%{}) == []
    end
  end

  describe "comment_from_webhook_data/1" do
    test "is the comment with its id, cut as the poll cuts it" do
      data = fixture("comment_create.json")["data"]

      assert IssueNormalizer.comment_from_webhook_data(data) == %{
               id: "7c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e0f",
               author: "Ada Operator",
               body: "Ship the normaliser first, then the parser.",
               created_at: ~U[2026-10-29 09:20:41.377Z]
             }

      long = IssueNormalizer.comment_from_webhook_data(%{"id" => "c1", "body" => String.duplicate("a", 900)})
      assert String.length(long.body) == 800
      assert IssueNormalizer.comment_from_webhook_data(%{"id" => "c1", "body" => nil}).body == ""
    end

    test "is nil without an id" do
      assert IssueNormalizer.comment_from_webhook_data(%{"body" => "hi"}) == nil
      assert IssueNormalizer.comment_from_webhook_data(%{"id" => ""}) == nil
      assert IssueNormalizer.comment_from_webhook_data(nil) == nil
    end
  end
end
