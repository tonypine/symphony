defmodule SymphonyElixir.LinearClientCandidatesTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.GitHub.Hosts
  alias SymphonyElixir.Linear.Client

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client reads no blocker link from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "comments" => %{
        "nodes" => [
          %{
            "body" => "Clarifying answer",
            "createdAt" => "2026-01-01T01:00:00Z",
            "user" => %{"name" => "Reviewer"}
          }
        ]
      },
      "children" => %{
        "nodes" => [
          %{"id" => "issue-4", "identifier" => "MT-4", "state" => %{"name" => "Backlog"}},
          %{"id" => "issue-5", "identifier" => "MT-5"},
          "not-a-child"
        ]
      },
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    # Linear's blocker links are not read: the issue carries no blocker at all.
    refute Map.has_key?(Map.from_struct(issue), :blocked_by)
    assert issue.sub_issues == [%{id: "issue-4", identifier: "MT-4", state: "Backlog"}, %{id: "issue-5", identifier: "MT-5", state: nil}]
    assert issue.labels == ["backend"]
    assert issue.comments == [%{author: "Reviewer", body: "Clarifying answer", created_at: ~U[2026-01-01 01:00:00Z]}]
    assert issue.priority == 2
    assert issue.state == "Todo"

    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "configured GitHub Enterprise hosts are normalized and allowed" do
    write_workflow_file!(Workflow.workflow_file_path(), github: %{enterprise_hosts: ["GITHUB.EXAMPLE.COM", " github.example.com "]})

    assert Config.settings!().github.enterprise_hosts == ["github.example.com"]
    assert Config.settings!().github.failed_run_log_max_bytes == 65_536
    assert Hosts.allowed_github_hosts() == ["github.com", "www.github.com", "github.example.com"]
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client sends configured assignee in candidate filter" do
    write_workflow_file!(Workflow.workflow_file_path(), linear_tracker(tracker_assignee: "user-1"))

    graphql_fun = fn query, variables ->
      send(self(), {:candidate_query, query, variables})

      {:ok, linear_page_response([raw_linear_issue("issue-1", "MT-1", "user-1")])}
    end

    assert {:ok, issues} = Client.fetch_candidate_issues_for_test(graphql_fun)

    assert Enum.map(issues, & &1.identifier) == ["MT-1"]
    assert Enum.all?(issues, & &1.assigned_to_worker)

    assert_receive {:candidate_query, query, variables}

    assert query =~ "SymphonyLinearPoll"
    assert query =~ "$filter: IssueFilter!"
    assert query =~ "issues(filter: $filter"
    assert query =~ "comments(last: $commentLast, orderBy: createdAt)"

    assert variables == %{
             filter: %{
               "state" => %{"name" => %{"in" => ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]}},
               "project" => %{"slugId" => %{"eq" => "project"}},
               "team" => %{"key" => %{"eq" => "Test"}},
               "assignee" => %{"id" => %{"in" => ["user-1"]}}
             },
             first: 50,
             commentLast: 20,
             after: nil
           }
  end

  test "linear client normalizes team and project from graphql responses" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "token")

    raw_issue =
      raw_linear_issue("issue-1", "MT-1", "user-1")
      |> Map.merge(%{
        "team" => %{"key" => "ACME", "name" => "Acme Team"},
        "project" => %{"id" => "project-1", "name" => "Multi-repo support", "slugId" => "a1b2c3d4e5f6"}
      })

    graphql_fun = fn query, variables ->
      send(self(), {:candidate_query, query, variables})

      {:ok, linear_page_response([raw_issue])}
    end

    assert {:ok, [issue]} = Client.fetch_candidate_issues_for_test(graphql_fun)

    assert issue.team == %{key: "ACME", name: "Acme Team"}
    assert issue.project == %{id: "project-1", name: "Multi-repo support", slug_id: "a1b2c3d4e5f6"}

    assert_receive {:candidate_query, query, _variables}
    assert query =~ ~r/team\s*\{\s*key\s*name\s*\}/
    assert query =~ ~r/project\s*\{\s*id\s*name\s*slugId\s*\}/
  end

  test "linear client resolves assignee me before sending candidate filter" do
    write_workflow_file!(Workflow.workflow_file_path(), linear_tracker(tracker_assignee: "me"))

    graphql_fun = fn query, variables ->
      if query =~ "SymphonyLinearViewer" do
        send(self(), {:viewer_query, variables})
        {:ok, %{"data" => %{"viewer" => %{"id" => "user-2"}}}}
      else
        send(self(), {:candidate_query, variables})
        {:ok, linear_page_response([raw_linear_issue("issue-2", "MT-2", "user-2")])}
      end
    end

    assert {:ok, issues} = Client.fetch_candidate_issues_for_test(graphql_fun)

    assert Enum.map(issues, & &1.identifier) == ["MT-2"]

    assert_receive {:viewer_query, %{}}
    assert_receive {:candidate_query, variables}
    assert get_in(variables, [:filter, "assignee", "id", "in"]) == ["user-2"]
  end

  test "linear client fails loud when assignee filter shape drifts" do
    assert Client.assignee_filter_ids_for_test(nil) == nil
    assert Client.assignee_filter_ids_for_test(%{match_values: MapSet.new(["user-2", "user-1"])}) == ["user-1", "user-2"]

    assert_raise FunctionClauseError, fn ->
      Client.assignee_filter_ids_for_test(%{matches: MapSet.new(["user-1"])})
    end
  end

  test "linear client sends team key in candidate filter" do
    write_workflow_file!(Workflow.workflow_file_path(), linear_tracker(tracker_project_slug: nil, tracker_team: "ACME"))

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]}},
             "team" => %{"key" => %{"eq" => "ACME"}}
           }

    refute Map.has_key?(variables.filter, "project")
    refute Map.has_key?(variables.filter, "labels")
    refute Map.has_key?(variables.filter, "assignee")
  end

  test "linear client sends team id in candidate filter for UUID team" do
    team_id = "a42df4c4-7416-4a08-8fb2-97087043169f"

    write_workflow_file!(
      Workflow.workflow_file_path(),
      linear_tracker(
        tracker_project_slug: nil,
        tracker_team: team_id
      )
    )

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]}},
             "team" => %{"id" => %{"eq" => team_id}}
           }
  end

  test "linear client sends uppercase UUID team as id in candidate filter" do
    team_id = "A42DF4C4-7416-4A08-8FB2-97087043169F"

    write_workflow_file!(
      Workflow.workflow_file_path(),
      linear_tracker(
        tracker_project_slug: nil,
        tracker_team: team_id
      )
    )

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]}},
             "team" => %{"id" => %{"eq" => team_id}}
           }
  end

  test "linear client does not treat loose 36 character team values as ids" do
    team = "------------------------------------"

    write_workflow_file!(Workflow.workflow_file_path(), linear_tracker(tracker_project_slug: nil, tracker_team: team))

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]}},
             "team" => %{"key" => %{"eq" => team}}
           }
  end

  test "linear client sends single and multiple labels with OR semantics" do
    for labels <- [["backend"], ["backend", "infra"]] do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        linear_tracker(
          tracker_project_slug: nil,
          tracker_labels: labels
        )
      )

      variables = capture_candidate_variables!()

      assert variables.filter == %{
               "state" => %{"name" => %{"in" => ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]}},
               "team" => %{"key" => %{"eq" => "Test"}},
               "labels" => %{"some" => %{"name" => %{"in" => labels}}}
             }
    end
  end

  test "linear client omits empty labels from candidate filter" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      linear_tracker(
        tracker_project_slug: nil,
        tracker_team: "ACME",
        tracker_labels: []
      )
    )

    variables = capture_candidate_variables!()

    refute Map.has_key?(variables.filter, "labels")
    refute Enum.any?(variables.filter, fn {_key, value} -> is_nil(value) end)
  end

  test "linear client normalizes blank candidate scope values before building filter" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      linear_tracker(
        tracker_project_slug: " ",
        tracker_team: " ACME ",
        tracker_labels: ["", " backend ", " "]
      )
    )

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]}},
             "team" => %{"key" => %{"eq" => "ACME"}},
             "labels" => %{"some" => %{"name" => %{"in" => ["backend"]}}}
           }

    refute Map.has_key?(variables.filter, "project")
  end

  test "linear client combines configured candidate filter dimensions" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      linear_tracker(
        tracker_team: "ACME",
        tracker_labels: ["backend"],
        tracker_assignee: "user-1"
      )
    )

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]}},
             "project" => %{"slugId" => %{"eq" => "project"}},
             "team" => %{"key" => %{"eq" => "ACME"}},
             "labels" => %{"some" => %{"name" => %{"in" => ["backend"]}}},
             "assignee" => %{"id" => %{"in" => ["user-1"]}}
           }
  end

  test "linear client sends one isolated server-side candidate filter per repo" do
    repo_root = Path.dirname(Workflow.workflow_file_path())

    write_workflow_file!(
      Workflow.workflow_file_path(),
      linear_tracker(
        tracker_project_slug: "legacy-project",
        tracker_team: "LEGACY",
        tracker_labels: ["legacy"],
        tracker_assignee: "legacy-user",
        repos: [
          %{"name" => "web", "path" => repo_root, "workflow" => "WORKFLOW.md", "team" => "ACME", "projects" => ["Project Alpha"], "labels" => ["web"], "assignee" => "user-web"},
          %{"name" => "api", "path" => repo_root, "workflow" => "WORKFLOW.md", "team" => "ACME", "projects" => ["Project Beta"], "labels" => ["api"], "assignee" => "user-api"}
        ]
      )
    )

    graphql_fun = fn query, variables ->
      send(self(), {:candidate_query, query, variables})

      issue =
        case get_in(variables, [:filter, "assignee", "id", "in"]) do
          ["user-web"] -> raw_linear_issue("issue-web", "ACME-WEB", "user-web")
          ["user-api"] -> raw_linear_issue("issue-api", "ACME-API", "user-api")
        end

      {:ok, linear_page_response([issue])}
    end

    assert {:ok, issues} = Client.fetch_candidate_issues_for_test(graphql_fun)
    assert Enum.map(issues, &{&1.identifier, &1.repo_key}) == [{"ACME-API", "api"}, {"ACME-WEB", "web"}]

    assert_receive {:candidate_query, query, web_variables}
    assert_receive {:candidate_query, ^query, api_variables}

    assert web_variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]}},
             "project" => %{
               "or" => [
                 %{"name" => %{"in" => ["Project Alpha"]}},
                 %{"slugId" => %{"in" => ["Project Alpha"]}}
               ]
             },
             "team" => %{"key" => %{"eq" => "ACME"}},
             "labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => "web"}}},
             "assignee" => %{"id" => %{"in" => ["user-web"]}}
           }

    assert api_variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]}},
             "project" => %{
               "or" => [
                 %{"name" => %{"in" => ["Project Beta"]}},
                 %{"slugId" => %{"in" => ["Project Beta"]}}
               ]
             },
             "team" => %{"key" => %{"eq" => "ACME"}},
             "labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => "api"}}},
             "assignee" => %{"id" => %{"in" => ["user-api"]}}
           }

    refute inspect([web_variables.filter, api_variables.filter]) =~ "legacy"
  end

  test "linear client state reconciliation keeps partial repo successes when one repo errors" do
    repo_root = Path.dirname(Workflow.workflow_file_path())

    write_workflow_file!(
      Workflow.workflow_file_path(),
      linear_tracker(
        repos: [
          %{"name" => "web", "path" => repo_root, "workflow" => "WORKFLOW.md", "team" => "ACME", "labels" => ["web"]},
          %{"name" => "api", "path" => repo_root, "workflow" => "WORKFLOW.md", "team" => "ACME", "labels" => ["api"]}
        ]
      )
    )

    graphql_fun = fn query, variables ->
      send(self(), {:state_query, query, variables})

      case get_in(variables, [:filter, "labels", "some", "name", "eqIgnoreCase"]) do
        "web" ->
          issue =
            raw_linear_issue("issue-web", "ACME-WEB")
            |> Map.put("state", %{"name" => "In Progress"})

          {:ok, linear_page_response([issue])}

        "api" ->
          {:error, :linear_unavailable}
      end
    end

    assert {:ok, issues} = Client.fetch_issues_by_states_for_test(["In Progress"], graphql_fun)

    assert Enum.map(issues, &{&1.identifier, &1.repo_key}) == [{"ACME-WEB", "web"}]
    assert_receive {:state_query, query, web_variables}
    assert_receive {:state_query, ^query, api_variables}
    assert get_in(web_variables, [:filter, "labels", "some", "name", "eqIgnoreCase"]) == "web"
    assert get_in(api_variables, [:filter, "labels", "some", "name", "eqIgnoreCase"]) == "api"
  end

  test "linear client repeats candidate filter while paginating" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      linear_tracker(
        tracker_project_slug: nil,
        tracker_team: "ACME",
        tracker_labels: ["backend"]
      )
    )

    graphql_fun = fn query, variables ->
      send(self(), {:candidate_page, query, variables})

      case variables.after do
        nil ->
          {:ok,
           linear_page_response([raw_linear_issue("issue-1", "MT-1")], %{
             "hasNextPage" => true,
             "endCursor" => "cursor-1"
           })}

        "cursor-1" ->
          {:ok, linear_page_response([raw_linear_issue("issue-2", "MT-2")])}
      end
    end

    assert {:ok, issues} = Client.fetch_candidate_issues_for_test(graphql_fun)
    assert Enum.map(issues, & &1.identifier) == ["MT-1", "MT-2"]

    assert_receive {:candidate_page, query, first_variables}
    assert_receive {:candidate_page, ^query, second_variables}

    assert first_variables[:after] == nil
    assert second_variables[:after] == "cursor-1"
    assert first_variables.filter == second_variables.filter
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids
    assert Enum.all?(issues, & &1.assigned_to_worker)

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50}}
    assert query =~ "SymphonyLinearIssuesById"
    assert query =~ ~r/team\s*\{\s*key\s*name\s*\}/
    assert query =~ ~r/project\s*\{\s*id\s*name\s*slugId\s*\}/

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5}}
  end

  test "linear client refresh by id marks reassigned and unassigned issues as not routed to worker" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "user-1")

    raw_issues = [
      raw_linear_issue("issue-1", "MT-1", "user-2"),
      raw_linear_issue("issue-2", "MT-2", nil),
      raw_linear_issue("issue-3", "MT-3", "user-1")
    ]

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})
      {:ok, %{"data" => %{"issues" => %{"nodes" => raw_issues}}}}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(["issue-1", "issue-2", "issue-3"], graphql_fun)

    assert Enum.map(issues, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
    assert Enum.map(issues, & &1.assigned_to_worker) == [false, false, true]

    assert_receive {:fetch_issue_states_page, query, %{ids: ["issue-1", "issue-2", "issue-3"], first: 3}}
    assert query =~ "SymphonyLinearIssuesById"
    assert query =~ "issues(filter: {id: {in: $ids}}"
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "token")

    body = %{
      "errors" => [
        %{
          "message" => "Variable \"$ids\" got invalid value",
          "extensions" => %{"code" => "BAD_USER_INPUT"}
        }
      ]
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400, ^body}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: body
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "linear client asks Linear to pre-sign upload URLs only when a read opts in" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "linear-token", tracker_project_slug: "project")
    parent = self()

    request_fun = fn _payload, headers ->
      send(parent, {:linear_headers, headers})
      {:ok, %{status: 200, body: %{"data" => %{}}}}
    end

    assert {:ok, _body} = Client.graphql("query Viewer { viewer { id } }", %{}, sign_file_urls: true, request_fun: request_fun)
    assert_receive {:linear_headers, signed_headers}
    assert {"public-file-urls-expire-in", "21600"} in signed_headers
    assert {"Authorization", "linear-token"} in signed_headers

    assert {:ok, _body} = Client.graphql("query Viewer { viewer { id } }", %{}, request_fun: request_fun)
    assert_receive {:linear_headers, plain_headers}
    refute List.keymember?(plain_headers, "public-file-urls-expire-in", 0)
  end

  test "linear client redacts configured secrets from graphql request error logs" do
    token = "linear-secret-token"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: token,
      tracker_project_slug: "project"
    )

    reason = {:closed, %{headers: [{"authorization", "Bearer #{token}"}], body: "token=#{token}"}}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_request, ^reason}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers -> {:error, reason} end
                 )
      end)

    assert log =~ "Linear GraphQL request failed"
    refute log =~ token
    assert log =~ "[REDACTED]"
  end

  test "todo issue with an unmet stored dependency is not dispatch-eligible, and no pause holds it" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo"
    }

    depends_on!(issue, %{id: "blocker-1", identifier: "MT-1002", state: "In Progress"})

    # The poll's sweep sets no pause for it; the dependency gate reads the stored dependency.
    terminal_states = Config.settings!().tracker.terminal_states
    assert Orchestrator.sweep_dependencies_for_test(Config.repo_key!(), [issue], terminal_states) == 0
    refute SymphonyElixir.Pauses.paused?({:ticket, Config.repo_key!(), issue.id})
    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo issue whose stored dependency is met remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo"
    }

    depends_on!(issue, %{id: "blocker-2", identifier: "MT-1004", state: "Done"})
    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "breakdown parent waits while a sub-issue is open and is eligible for close-out once all are terminal" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    parent = %Issue{
      id: "parent-1",
      identifier: "MT-1101",
      title: "Groom into sub-tickets",
      state: "In Progress",
      labels: ["breakdown"],
      sub_issues: [
        %{id: "child-1", identifier: "MT-1102", state: "Done"},
        %{id: "child-2", identifier: "MT-1103", state: "Backlog"}
      ]
    }

    refute Orchestrator.should_dispatch_issue_for_test(parent, state)
    unknown_state_child = %{id: "child-3", identifier: "MT-1104", state: nil}
    refute Orchestrator.should_dispatch_issue_for_test(%{parent | sub_issues: [unknown_state_child]}, state)

    closed_out = %{parent | sub_issues: [%{id: "child-1", identifier: "MT-1102", state: "Done"}, %{id: "child-2", identifier: "MT-1103", state: "Cancelled"}]}
    assert Orchestrator.should_dispatch_issue_for_test(closed_out, state)

    # Without the breakdown label, open sub-issues (such as filed follow-ups) do not hold the ticket.
    assert Orchestrator.should_dispatch_issue_for_test(%{parent | labels: ["improvement"]}, state)
    refute Issue.waiting_on_sub_issues?(%{parent | sub_issues: nil}, ["Done"])
  end

  test "dispatch revalidation skips a breakdown parent once it has open sub-issues" do
    stale_issue = %Issue{
      id: "parent-2",
      identifier: "MT-1105",
      title: "Groom into sub-tickets",
      state: "In Progress",
      labels: ["breakdown"]
    }

    refreshed_issue = %{stale_issue | sub_issues: [%{id: "child-4", identifier: "MT-1106", state: "Todo"}]}
    fetcher = fn ["parent-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{identifier: "MT-1105"}} = Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)
  end

  test "dispatch revalidation reads no blocker link: the read right before dispatch pauses nothing" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo"
    }

    fetcher = fn ["blocked-2"] -> {:ok, [stale_issue]} end

    assert {:ok, %Issue{identifier: "MT-1005"}} = Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)
    refute SymphonyElixir.Pauses.paused?({:ticket, Config.repo_key!(), "blocked-2"})
  end

  # The ticket `issue` depends on `on` (`:done`), as Symphony stores it, with a record of each.
  defp depends_on!(%Issue{} = issue, %{id: on_id, identifier: on_identifier, state: on_state}) do
    repo_key = Config.repo_key!()
    :ok = RunStore.put_ticket_state(SymphonyElixir.TicketState.new(repo_key, issue.id, %{issue_identifier: issue.identifier, phase: issue.state}))
    :ok = RunStore.put_ticket_state(SymphonyElixir.TicketState.new(repo_key, on_id, %{issue_identifier: on_identifier, phase: on_state}))
    :ok = RunStore.add_dependency(issue.id, on_id, :done)

    on_exit(fn ->
      RunStore.delete_ticket_state(issue.id)
      RunStore.delete_ticket_state(on_id)
    end)
  end

  defp capture_candidate_variables! do
    graphql_fun = fn query, variables ->
      send(self(), {:candidate_query, query, variables})
      {:ok, linear_page_response([])}
    end

    assert {:ok, []} = Client.fetch_candidate_issues_for_test(graphql_fun)
    assert_receive {:candidate_query, query, variables}
    assert query =~ "SymphonyLinearPoll"

    variables
  end

  defp linear_page_response(nodes, page_info \\ %{"hasNextPage" => false, "endCursor" => nil}) do
    %{
      "data" => %{
        "issues" => %{
          "nodes" => nodes,
          "pageInfo" => page_info
        }
      }
    }
  end

  defp raw_linear_issue(id, identifier, assignee_id \\ nil) do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => identifier,
      "state" => %{"name" => "Todo"},
      "assignee" => assignee_id && %{"id" => assignee_id},
      "labels" => %{"nodes" => []}
    }
  end
end
