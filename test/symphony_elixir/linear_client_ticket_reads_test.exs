defmodule SymphonyElixir.LinearClientTicketReadsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.{Client, Issue}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "token")
    :ok
  end

  test "no ticket read requests attachments, and each read costs one request" do
    issue = raw_issue("issue-a", "MOT-42")

    graphql_fun =
      graphql(%{
        "SymphonyLinearPoll" => %{"data" => %{"issues" => %{"nodes" => [issue], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}},
        "SymphonyLinearIssuesById" => %{"data" => %{"issues" => %{"nodes" => [issue]}}},
        "SymphonyLinearIssueByIdentifier" => %{"data" => %{"issue" => issue}}
      })

    assert {:ok, [%Issue{identifier: "MOT-42"}]} = Client.fetch_candidate_issues_for_test(graphql_fun)
    assert {:ok, [%Issue{identifier: "MOT-42"}]} = Client.fetch_issue_states_by_ids_for_test(["issue-a"], graphql_fun)
    assert {:ok, %Issue{identifier: "MOT-42"}} = Client.fetch_issue_by_identifier_for_test("MOT-42", graphql_fun)

    for operation <- ["SymphonyLinearPoll", "SymphonyLinearIssuesById", "SymphonyLinearIssueByIdentifier"] do
      assert_received {:linear_query, ^operation, query, variables}
      refute query =~ "attachment"
      refute Map.has_key?(variables, :attachmentFirst)
      refute_received {:linear_query, ^operation, _query, _variables}
    end

    refute_received {:linear_query, _operation, _query, _variables}
  end

  test "a ticket carries no PR of its own, even when Linear's answer holds a PR attachment" do
    issue =
      "issue-a"
      |> raw_issue("MOT-40")
      |> Map.put("attachments", %{
        "nodes" => [%{"title" => "PR #37", "url" => "https://github.com/example/repo/pull/37", "sourceType" => "github", "metadata" => %{}}]
      })

    graphql_fun = graphql(%{"SymphonyLinearIssueByIdentifier" => %{"data" => %{"issue" => issue}}})

    assert {:ok, %Issue{} = read} = Client.fetch_issue_by_identifier_for_test("MOT-40", graphql_fun)
    refute Map.has_key?(read, :pull_request_url)
    refute Map.has_key?(read, :pr_urls)
  end

  test "no ticket read asks Linear for blocker links, still reads the parent and sub-tickets, and a link in an answer is ignored" do
    blocker = %{"type" => "blocks", "issue" => %{"id" => "issue-b", "identifier" => "MOT-41", "state" => %{"name" => "Todo"}}}

    issue =
      "issue-a"
      |> raw_issue("MOT-42")
      |> Map.put("inverseRelations", %{"nodes" => [blocker]})
      |> Map.put("children", %{"nodes" => [%{"id" => "issue-c", "identifier" => "MOT-43", "state" => %{"name" => "Todo"}}]})

    enrichment = %{
      "description" => "body",
      "comments" => %{"nodes" => []},
      "relations" => %{
        "nodes" => [
          %{"type" => "blocks", "relatedIssue" => %{"identifier" => "MOT-41", "title" => "Blocker", "state" => %{"name" => "Todo"}}},
          %{"type" => "related", "relatedIssue" => %{"identifier" => "MOT-44", "title" => "Related", "state" => %{"name" => "Todo"}}}
        ]
      },
      "parent" => nil
    }

    graphql_fun =
      graphql(%{
        "SymphonyLinearPoll" => %{"data" => %{"issues" => %{"nodes" => [issue], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}},
        "SymphonyLinearIssuesById" => %{"data" => %{"issues" => %{"nodes" => [issue]}}},
        "SymphonyLinearIssueByIdentifier" => %{"data" => %{"issue" => issue}},
        "SymphonyLinearIssueEnrichment" => %{"data" => %{"issue" => enrichment}}
      })

    assert {:ok, [polled]} = Client.fetch_candidate_issues_for_test(graphql_fun)
    assert {:ok, [by_id]} = Client.fetch_issue_states_by_ids_for_test(["issue-a"], graphql_fun)
    assert {:ok, by_identifier} = Client.fetch_issue_by_identifier_for_test("MOT-42", graphql_fun)

    for read <- [polled, by_id, by_identifier] do
      refute Map.has_key?(read, :blocked_by)
      assert [%{identifier: "MOT-43"}] = read.sub_issues
    end

    assert {:ok, enriched} = Client.fetch_issue_enrichment_for_test(polled, graphql_fun)
    assert Enum.map(enriched.linked_issues, & &1.identifier) == ["MOT-44"]

    for operation <- ["SymphonyLinearPoll", "SymphonyLinearIssuesById", "SymphonyLinearIssueByIdentifier", "SymphonyLinearIssueEnrichment"] do
      assert_received {:linear_query, ^operation, query, variables}
      refute query =~ "inverseRelations"
      refute query =~ "issueRelation"
      assert query =~ "children"

      if operation == "SymphonyLinearIssueEnrichment" do
        # The parent link is read; `relations` stays for the related links, of which blockers are dropped.
        assert query =~ ~r/\n\s+parent \{\n\s+identifier/
      else
        refute query =~ "relations"
        refute Map.has_key?(variables, :relationFirst)
      end
    end
  end

  defp graphql(responses) do
    parent = self()

    fn query, variables ->
      [_match, operation] = Regex.run(~r/^\s*query\s+(\w+)/, query)
      send(parent, {:linear_query, operation, query, variables})
      {:ok, Map.fetch!(responses, operation)}
    end
  end

  defp raw_issue(id, identifier) do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => identifier,
      "state" => %{"name" => "In Progress"},
      "labels" => %{"nodes" => []}
    }
  end
end
