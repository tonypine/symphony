defmodule SymphonyElixir.LinearClientAttachmentsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  @pr_url "https://github.com/example/repo/pull/37"

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "token")
    :ok
  end

  describe "an issue whose PR attachment is past the first page of attachments" do
    test "still gets its PR URL from a poll, reading the next pages only until the PR shows up" do
      # MOT-40: 19 QA screenshots and a notes file pushed the PR attachment to 21st.
      past_first_page = raw_issue("issue-a", "MOT-40", screenshots(1..20), next_cursor: "a-1")
      on_first_page = raw_issue("issue-b", "MOT-41", [pr_attachment(41) | screenshots(1..19)], next_cursor: "b-1")

      graphql_fun =
        graphql(
          %{"SymphonyLinearPoll" => poll_response([past_first_page, on_first_page])},
          %{
            {"issue-a", "a-1"} => {screenshots(21..70), "a-2"},
            {"issue-a", "a-2"} => {[pr_attachment(37) | screenshots(71..72)], nil}
          }
        )

      assert {:ok, issues} = Client.fetch_candidate_issues_for_test(graphql_fun)

      assert [%{identifier: "MOT-40", pull_request_url: @pr_url}, %{identifier: "MOT-41", pull_request_url: pr_41}] = issues
      assert pr_41 == "https://github.com/example/repo/pull/41"

      assert_received {:linear_query, "SymphonyLinearPoll", query, %{attachmentFirst: 20}}
      assert query =~ ~r/attachments\(first: \$attachmentFirst\) \{.*?pageInfo \{\s*hasNextPage\s*endCursor/s
      assert_received {:linear_query, "SymphonyLinearIssueAttachments", query, %{id: "issue-a", first: 50, after: "a-1"}}
      assert query =~ "attachments(first: $first, after: $after)"
      assert_received {:linear_query, "SymphonyLinearIssueAttachments", _query, %{id: "issue-a", first: 50, after: "a-2"}}
      refute_received {:linear_query, "SymphonyLinearIssueAttachments", _query, %{id: "issue-b"}}
    end

    test "still gets its PR URL when refreshed by id or read by identifier" do
      issue = raw_issue("issue-a", "MOT-40", screenshots(1..20), next_cursor: "a-1")
      pages = %{{"issue-a", "a-1"} => {[pr_attachment(37)], nil}}

      graphql_fun =
        graphql(
          %{
            "SymphonyLinearIssuesById" => %{"data" => %{"issues" => %{"nodes" => [issue]}}},
            "SymphonyLinearIssueByIdentifier" => %{"data" => %{"issue" => issue}}
          },
          pages
        )

      assert {:ok, [%{pull_request_url: @pr_url}]} = Client.fetch_issue_states_by_ids_for_test(["issue-a"], graphql_fun)
      assert {:ok, %{pull_request_url: @pr_url}} = Client.fetch_issue_by_identifier_for_test("MOT-40", graphql_fun)

      for operation <- ["SymphonyLinearIssuesById", "SymphonyLinearIssueByIdentifier"] do
        assert_received {:linear_query, ^operation, query, _variables}
        assert query =~ ~r/attachments\(first: \$attachmentFirst\) \{.*?pageInfo \{\s*hasNextPage\s*endCursor/s
      end
    end

    test "reads past a closed PR on the first page to the open one" do
      closed = Map.put(pr_attachment(12), "metadata", %{"status" => "closed"})
      issue = raw_issue("issue-a", "MOT-40", [closed | screenshots(1..19)], next_cursor: "a-1")
      pages = %{{"issue-a", "a-1"} => {[pr_attachment(37)], nil}}
      graphql_fun = graphql(%{"SymphonyLinearPoll" => poll_response([issue])}, pages)

      assert {:ok, [issue]} = Client.fetch_candidate_issues_for_test(graphql_fun)
      assert %{pull_request_url: @pr_url, pr_urls: [@pr_url]} = issue
    end
  end

  test "an issue whose attachments fit in one page costs one request on each read" do
    issue = raw_issue("issue-a", "MOT-42", screenshots(1..5), next_cursor: nil)

    graphql_fun =
      graphql(
        %{
          "SymphonyLinearPoll" => poll_response([issue]),
          "SymphonyLinearIssuesById" => %{"data" => %{"issues" => %{"nodes" => [issue]}}},
          "SymphonyLinearIssueByIdentifier" => %{"data" => %{"issue" => issue}}
        },
        %{}
      )

    assert {:ok, [%{identifier: "MOT-42", pull_request_url: nil}]} = Client.fetch_candidate_issues_for_test(graphql_fun)
    assert {:ok, [%{identifier: "MOT-42"}]} = Client.fetch_issue_states_by_ids_for_test(["issue-a"], graphql_fun)
    assert {:ok, %{identifier: "MOT-42"}} = Client.fetch_issue_by_identifier_for_test("MOT-42", graphql_fun)

    for operation <- ["SymphonyLinearPoll", "SymphonyLinearIssuesById", "SymphonyLinearIssueByIdentifier"] do
      assert_received {:linear_query, ^operation, _query, _variables}
      refute_received {:linear_query, ^operation, _query, _variables}
    end

    refute_received {:linear_query, "SymphonyLinearIssueAttachments", _query, _variables}
  end

  test "an issue with no PR reads all its attachment pages and still has no PR URL" do
    issue = raw_issue("issue-a", "MOT-40", screenshots(1..20), next_cursor: "a-1")
    graphql_fun = graphql(%{"SymphonyLinearPoll" => poll_response([issue])}, %{{"issue-a", "a-1"} => {screenshots(21..25), nil}})

    assert {:ok, [%{pull_request_url: nil, pr_urls: []}]} = Client.fetch_candidate_issues_for_test(graphql_fun)
    assert_received {:linear_query, "SymphonyLinearIssueAttachments", _query, %{after: "a-1"}}
  end

  test "a failed attachment page keeps the attachments already read and says the PR URL may be missing" do
    issue = raw_issue("issue-a", "MOT-40", screenshots(1..20), next_cursor: "a-1")

    for {response, reason} <- [
          {{:error, :timeout}, ":timeout"},
          {{:ok, %{"errors" => [%{"message" => "boom"}]}}, ~s({:linear_graphql_errors, [%{"message" => "boom"}]})},
          {{:ok, %{"data" => %{"issue" => nil}}}, ":linear_unknown_payload"}
        ] do
      graphql_fun = graphql(%{"SymphonyLinearPoll" => poll_response([issue])}, %{{"issue-a", "a-1"} => response})

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, [%{identifier: "MOT-40", pull_request_url: nil}]} = Client.fetch_candidate_issues_for_test(graphql_fun)
        end)

      assert log =~ "Could not read more Linear attachments for issue_id=issue-a issue_identifier=MOT-40; its PR URL may be missing reason=#{reason}"
    end
  end

  test "stops reading attachment pages after ten more pages without a PR" do
    issue = raw_issue("issue-a", "MOT-40", screenshots(1..20), next_cursor: "a-0")

    pages =
      Map.new(0..10, fn page ->
        {{"issue-a", "a-#{page}"}, {screenshots((page * 50 + 21)..(page * 50 + 70)), "a-#{page + 1}"}}
      end)

    graphql_fun = graphql(%{"SymphonyLinearPoll" => poll_response([issue])}, pages)

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, [%{pull_request_url: nil}]} = Client.fetch_candidate_issues_for_test(graphql_fun)
      end)

    assert log =~ "Stopped reading Linear attachments for issue_id=issue-a issue_identifier=MOT-40 after 10 more pages without finding a PR attachment"

    for page <- 0..9 do
      cursor = "a-#{page}"
      assert_received {:linear_query, "SymphonyLinearIssueAttachments", _query, %{after: ^cursor}}
    end

    refute_received {:linear_query, "SymphonyLinearIssueAttachments", _query, %{after: "a-10"}}
  end

  # `responses` maps an operation name to its response body; `pages` maps `{issue_id, cursor}` to
  # the attachment page after that cursor, as `{nodes, next_cursor}`, or to a raw graphql result.
  defp graphql(responses, pages) do
    parent = self()

    fn query, variables ->
      [_match, operation] = Regex.run(~r/^\s*query\s+(\w+)/, query)
      send(parent, {:linear_query, operation, query, variables})

      case operation do
        "SymphonyLinearIssueAttachments" -> attachment_page(Map.fetch!(pages, {variables.id, variables.after}))
        operation -> {:ok, Map.fetch!(responses, operation)}
      end
    end
  end

  defp attachment_page({nodes, next_cursor}) when is_list(nodes) do
    {:ok, %{"data" => %{"issue" => %{"attachments" => attachments(nodes, next_cursor)}}}}
  end

  defp attachment_page(result), do: result

  defp poll_response(issues) do
    %{"data" => %{"issues" => %{"nodes" => issues, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}
  end

  defp raw_issue(id, identifier, attachments, opts) do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => identifier,
      "state" => %{"name" => "In Progress"},
      "attachments" => attachments(attachments, Keyword.fetch!(opts, :next_cursor)),
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []}
    }
  end

  defp attachments(nodes, next_cursor) do
    %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => is_binary(next_cursor), "endCursor" => next_cursor}}
  end

  defp screenshots(range) do
    Enum.map(range, fn n ->
      %{"title" => "Screenshot #{n}", "url" => "https://uploads.linear.app/qa/#{n}.png", "sourceType" => "upload", "metadata" => %{}}
    end)
  end

  defp pr_attachment(number) do
    %{
      "title" => "PR ##{number}",
      "url" => "https://github.com/example/repo/pull/#{number}",
      "sourceType" => "github",
      "metadata" => %{"status" => "open"}
    }
  end
end
