defmodule SymphonyElixir.PollerLinearRequestsTest do
  # Pins how many Linear requests each poller sends per poll, end to end through
  # `Linear.Client` against a local GraphQL endpoint, so their share of the API
  # key's hourly budget stays flat as watched issues and repositories grow.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CiPoller, PrReviewPoller}

  @repo_key "default"

  defmodule FakeLinear do
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      %{"query" => query, "variables" => variables} = Jason.decode!(body)
      [operation] = Regex.run(~r/(?:query|mutation)\s+(\w+)/, query, capture: :all_but_first)
      send(Keyword.fetch!(opts, :recipient), {:linear_request, operation})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response(operation, variables, Keyword.fetch!(opts, :issues))))
    end

    defp response("SymphonyLinearViewer", _variables, _issues), do: %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}

    # Only the primary repository's team has watched issues; the other answers an empty page.
    defp response("SymphonyLinearPoll", %{"filter" => filter}, issues) do
      states = get_in(filter, ["state", "name", "in"])

      nodes =
        if get_in(filter, ["team", "key", "eq"]) == "TEAM",
          do: Enum.filter(issues, &(&1["state"]["name"] in states)),
          else: []

      %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}
    end

    defp response("SymphonyLinearIssuesById", %{"ids" => ids}, issues) do
      %{"data" => %{"issues" => %{"nodes" => Enum.filter(issues, &(&1["id"] in ids))}}}
    end
  end

  defmodule GreenGitHub do
    def fetch_ci_status(pr_url, _opts) do
      {:ok,
       %{
         pr_url: pr_url,
         pr_title: "Watched",
         state: "OPEN",
         head_ref_name: "feature/watched",
         is_cross_repository: false,
         head_repository: %{"nameWithOwner" => "example/repo"},
         commit_sha: "abc123",
         checks: [%{name: "specs", status: "COMPLETED", conclusion: "SUCCESS", run_id: "987"}]
       }}
    end

    def fetch_activity(pr_url, _opts) do
      {:ok,
       %{
         pr_url: pr_url,
         pr_number: pr_url |> String.split("/") |> List.last() |> String.to_integer(),
         pr_title: "Watched",
         pr_description: "PR body",
         pr_author: nil,
         state: "OPEN",
         review_decision: nil,
         mergeable: nil,
         merge_state_status: nil,
         head_ref_name: nil,
         head_ref_oid: nil,
         base_ref_name: nil,
         base_ref_oid: nil,
         is_cross_repository: false,
         latest_activity_at: ~U[2026-05-06 08:00:00Z],
         latest_review_activity_at: ~U[2026-05-06 08:00:00Z],
         comments: []
       }}
    end
  end

  @now ~U[2026-05-06 09:00:00Z]

  for watched <- [1, 5] do
    test "the CI poller sends one Linear read per repository and poll with #{watched} watched issues" do
      start_linear!(unquote(watched))

      assert {:ok, %{discovered: unquote(watched), processed: unquote(watched)}} =
               CiPoller.poll_once(github: GreenGitHub, now: @now)

      # `assignee: me` resolves the viewer once; each repository's states are read once.
      assert linear_requests() == %{"SymphonyLinearViewer" => 1, "SymphonyLinearPoll" => 2}

      assert {:ok, %{processed: unquote(watched)}} = CiPoller.poll_once(github: GreenGitHub, now: DateTime.add(@now, 1, :minute))
      assert linear_requests() == %{"SymphonyLinearPoll" => 2}
    end

    test "the PR review poller sends one Linear read per repository and poll with #{watched} watched issues" do
      start_linear!(unquote(watched))

      assert {:ok, %{discovered: unquote(watched), processed: unquote(watched)}} =
               PrReviewPoller.poll_once(github: GreenGitHub, current_gh_user: nil, now: @now)

      assert linear_requests() == %{"SymphonyLinearViewer" => 1, "SymphonyLinearPoll" => 2}

      assert {:ok, %{processed: unquote(watched)}} =
               PrReviewPoller.poll_once(github: GreenGitHub, current_gh_user: nil, now: DateTime.add(@now, 1, :minute))

      assert linear_requests() == %{"SymphonyLinearPoll" => 2}
    end
  end

  defp start_linear!(watched) do
    issues = Enum.map(1..watched, &raw_issue/1)
    plug = {FakeLinear, recipient: self(), issues: issues}
    server = start_supervised!({Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "http://127.0.0.1:#{port}/graphql",
      # A fresh key per test, so the cached viewer of another test does not hide this one's lookup.
      tracker_api_token: "token-#{System.unique_integer([:positive])}",
      tracker_assignee: "me",
      tracker_project_slug: nil,
      pr_review_mode: "polling",
      ci: %{enabled: true},
      repos: [
        %{key: @repo_key, workflow: Workflow.workflow_file_path(), default: true, team: "TEAM"},
        %{key: "secondary", workflow: Workflow.workflow_file_path(), team: "OTHER"}
      ]
    )

    Enum.each(1..watched, &put_run/1)
  end

  defp raw_issue(index) do
    %{
      "id" => "issue-#{index}",
      "identifier" => "TEAM-#{index}",
      "title" => "Watched #{index}",
      "state" => %{"name" => "In Review"},
      "url" => "https://linear.test/TEAM-#{index}",
      "assignee" => %{"id" => "viewer-1"},
      "labels" => %{"nodes" => []},
      "attachments" => %{
        "nodes" => [%{"title" => "PR", "url" => "https://github.com/example/repo/pull/#{index}", "sourceType" => "github", "metadata" => %{}}]
      },
      "inverseRelations" => %{"nodes" => []}
    }
  end

  defp put_run(index) do
    :ok =
      RunStore.put_run(%{
        repo_key: @repo_key,
        run_id: "run-#{index}",
        issue_id: "issue-#{index}",
        issue_identifier: "TEAM-#{index}",
        status: "success",
        workspace_path: "/tmp/workspaces/TEAM-#{index}",
        worker_host: nil,
        started_at: DateTime.add(@now, -2, :minute),
        ended_at: DateTime.add(@now, -1, :minute)
      })
  end

  # Drains the requests the fake endpoint saw since the last call, counted per operation.
  defp linear_requests(counts \\ %{}) do
    receive do
      {:linear_request, operation} -> linear_requests(Map.update(counts, operation, 1, &(&1 + 1)))
    after
      0 -> counts
    end
  end
end
