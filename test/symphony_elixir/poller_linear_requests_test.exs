defmodule SymphonyElixir.PollerLinearRequestsTest do
  # Pins how many Linear requests each poller sends per poll, end to end through
  # `Linear.Client` against a local GraphQL endpoint, so their share of the API
  # key's hourly budget stays flat as watched issues and repositories grow.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CiPoller, OperatorStop, PrReviewPoller, TicketObservation, TicketPullRequest}
  alias SymphonyElixir.Linear.Usage

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
      send(Keyword.fetch!(opts, :recipient), {:linear_query, operation, query})

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

    # The CI-label projection looks a label name up before writing it: nothing on the issue yet,
    # a workspace label to add.
    defp response("SymphonyResolveIssueLabel", _variables, _issues) do
      %{
        "data" => %{
          "issue" => %{"team" => %{"id" => "team-1"}, "labels" => %{"nodes" => []}},
          "issueLabels" => %{"nodes" => [%{"id" => "label-1", "team" => nil}]}
        }
      }
    end

    defp response("SymphonyAddIssueLabel", _variables, _issues), do: %{"data" => %{"issueAddLabel" => %{"success" => true}}}
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

      # `assignee: me` resolves the viewer once; each repository's states are read once. The poll
      # only observes: the PR and CI watcher projects the machine CI labels, so it writes none.
      assert linear_requests() == %{"SymphonyLinearViewer" => 1, "SymphonyLinearPoll" => 2}

      # The steady-state budget stays flat as watched issues grow.
      assert {:ok, %{processed: unquote(watched)}} = CiPoller.poll_once(github: GreenGitHub, now: DateTime.add(@now, 1, :minute))
      assert linear_requests() == %{"SymphonyLinearPoll" => 2}

      # Ticket reads carry no attachments: each watched ticket's PR comes from Symphony's record,
      # and no attachment page is read, so none shows in `linear_usage`.
      refute_ticket_reads_request_attachments()
    end

    test "the PR review poller sends one Linear read per repository and poll with #{watched} watched issues" do
      start_linear!(unquote(watched))

      assert {:ok, %{discovered: unquote(watched), processed: unquote(watched)}} =
               PrReviewPoller.poll_once(github: GreenGitHub, current_gh_user: nil, now: @now)

      assert linear_requests() == %{"SymphonyLinearViewer" => 1, "SymphonyLinearPoll" => 2}

      assert {:ok, %{processed: unquote(watched)}} =
               PrReviewPoller.poll_once(github: GreenGitHub, current_gh_user: nil, now: DateTime.add(@now, 1, :minute))

      assert linear_requests() == %{"SymphonyLinearPoll" => 2}
      refute_ticket_reads_request_attachments()
    end
  end

  describe "under dispatch.source: record" do
    # The operator's usage block after an hour: neither poller counts a Linear request, and each still
    # reads its tickets' PRs from GitHub, so CI results and review comments still reach them.
    test "the CI poller and the PR review poller send no Linear request and still read every watched ticket's PR" do
      start_linear!(5)
      dispatch_from!("record")
      learn_viewer!()
      observe_watched(5)
      Usage.reset()

      assert {:ok, %{discovered: 5, processed: 5, actions: ci_actions}} =
               Usage.with_caller(:ci_poller, fn -> CiPoller.poll_once(github: GreenGitHub, now: @now) end)

      assert Enum.sort(ci_actions) == for(n <- 1..5, do: {:observed, "issue-#{n}", "green"})

      assert {:ok, %{discovered: 5, processed: 5}} =
               Usage.with_caller(:pr_review_poller, fn ->
                 PrReviewPoller.poll_once(github: GreenGitHub, current_gh_user: nil, now: @now)
               end)

      assert RunStore.list_pr_reviews(@repo_key) |> Enum.map(& &1.issue_id) |> Enum.sort() == for(n <- 1..5, do: "issue-#{n}")
      assert linear_requests() == %{}
      assert Usage.snapshot().callers |> Enum.map(& &1.caller) |> Enum.filter(&(&1 in ["ci_poller", "pr_review_poller"])) == []
    end
  end

  describe "the orchestrator's tick" do
    # The repo poll's own requests (the poll, and the reads it makes once per interval) are left
    # out: the tick's by-id reads are the difference between the sources.
    test "under dispatch.source: poll reads its running, watched, forced and stopped tickets by id" do
      start_linear!(4)
      dispatch_from!("poll")
      observe_records()

      {result, _state} = Orchestrator.run_repo_poll_task_for_test(tick_state(), repos(), 0)

      assert %{"SymphonyLinearPoll" => _polls, "SymphonyLinearIssuesById" => 4} = linear_requests()
      assert {:ok, [%Issue{id: "issue-1", state: "Code Review"}]} = result.running_result
    end

    test "under dispatch.source: record sends no Linear request but the repo poll's" do
      start_linear!(4)
      dispatch_from!("record")
      observe_records()
      Usage.reset()

      {result, _state} = Orchestrator.run_repo_poll_task_for_test(tick_state(), repos(), 0)

      assert %{"SymphonyLinearPoll" => _polls} = requests = linear_requests()
      assert Map.keys(requests) -- ["SymphonyLinearPoll", "SymphonyLinearViewer"] == []
      refute "SymphonyLinearIssuesById" in Enum.map(Usage.snapshot().queries, & &1.query)
      assert {:ok, [%Issue{id: "issue-1", state: "Code Review"}]} = result.running_result
      assert {:ok, [%Issue{id: "issue-4"}]} = result.stopped_result
    end
  end

  defp dispatch_from!(source) do
    File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "dispatch:\n  source: #{source}\n")
    Cache.clear()
  end

  defp observe_records do
    for index <- 1..4 do
      issue = %Issue{id: "issue-#{index}", identifier: "TEAM-#{index}", title: "Watched #{index}", state: "Code Review", updated_at: @now}
      {:ok, :updated} = TicketObservation.observe(@repo_key, issue, source: :poll)
    end
  end

  # `assignee: me`: the viewer a Linear read already learned, as the orchestrator's poll does once per key.
  defp learn_viewer! do
    graphql_fun = fn query, _variables ->
      if query =~ "SymphonyLinearViewer",
        do: {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}},
        else: {:ok, %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}
    end

    on_exit(&Client.reset_viewer_cache_for_test/0)
    assert {:ok, []} = Client.fetch_candidate_issues_for_test(graphql_fun)
  end

  # The records the poll observed of the watched tickets, assigned to the API key's user.
  defp observe_watched(count) do
    for index <- 1..count do
      issue = %Issue{
        id: "issue-#{index}",
        identifier: "TEAM-#{index}",
        title: "Watched #{index}",
        state: "Code Review",
        url: "https://linear.test/TEAM-#{index}",
        assignee_id: "viewer-1",
        updated_at: @now
      }

      {:ok, :updated} = TicketObservation.observe(@repo_key, issue, source: :poll)
    end
  end

  defp repos do
    {:ok, repos} = Config.repos()
    Enum.filter(repos, &(&1.name == @repo_key))
  end

  defp tick_state do
    running = %Issue{id: "issue-1", identifier: "TEAM-1", state: "Code Review"}

    %Orchestrator.State{
      running: %{running.id => %{issue: running, identifier: running.identifier}},
      watching: %{"issue-2" => %{}},
      forced: %{"issue-3" => %{}},
      operator_stops: %{"issue-4" => OperatorStop.mark("TEAM-4", @repo_key, @now)}
    }
  end

  defp refute_ticket_reads_request_attachments do
    queries = linear_queries()
    assert queries != []
    refute Enum.any?(queries, fn {_operation, query} -> query =~ "attachments" end)
    recorded = Enum.map(Usage.snapshot().queries, & &1.query)
    assert "SymphonyLinearPoll" in recorded
    refute "SymphonyLinearIssueAttachments" in recorded
  end

  defp linear_queries(acc \\ []) do
    receive do
      {:linear_query, operation, query} -> linear_queries([{operation, query} | acc])
    after
      0 -> acc
    end
  end

  defp start_linear!(watched) do
    suspend_background_readers()
    issues = Enum.map(1..watched, &raw_issue/1)
    plug = {FakeLinear, recipient: self(), issues: issues}
    server = start_supervised!({Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "http://127.0.0.1:#{port}/graphql",
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

  # The application's own Linear readers poll on their timers and read the workflow this test
  # points at the fake endpoint, so a tick during the test would add its reads to the counts.
  defp suspend_background_readers do
    for name <- [SymphonyElixir.Inbox, SymphonyElixir.Initiatives, SymphonyElixir.HumanActions],
        pid = Process.whereis(name),
        is_pid(pid) do
      :ok = :sys.suspend(pid)
      on_exit(fn -> resume(pid) end)
    end
  end

  defp resume(pid), do: if(Process.alive?(pid), do: :sys.resume(pid))

  defp raw_issue(index) do
    %{
      "id" => "issue-#{index}",
      "identifier" => "TEAM-#{index}",
      "title" => "Watched #{index}",
      "state" => %{"name" => "Code Review"},
      "url" => "https://linear.test/TEAM-#{index}",
      "assignee" => %{"id" => "viewer-1"},
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []}
    }
  end

  defp put_run(index) do
    :ok = TicketPullRequest.record_created(@repo_key, "issue-#{index}", "https://github.com/example/repo/pull/#{index}", "auto/TEAM-#{index}")

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
