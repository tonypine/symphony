defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.PromptSafety
  alias SymphonyElixir.QaAndroid.Driver, as: QaAndroidDriver

  test "tool_specs advertises scoped Linear tools and not raw GraphQL" do
    tool_names = Enum.map(DynamicTool.tool_specs(), & &1["name"])

    assert "linear_get_current_issue" in tool_names
    assert "linear_update_state" in tool_names
    assert "linear_attach_file" in tool_names
    assert "github_get_pull_request" in tool_names
    assert "github_fetch_origin" in tool_names
    assert "github_sync_base" in tool_names
    assert "github_create_pull_request" in tool_names
    assert "github_reply_to_review_comment" in tool_names
    assert "github_push_branch" in tool_names
    assert "github_merge_pull_request" in tool_names
    assert "github_get_pr_checks" in tool_names
    assert "github_list_pr_comments" in tool_names
    assert "github_list_pr_review_comments" in tool_names
    assert "github_list_pr_reviews" in tool_names
    assert "github_get_failed_run_log" in tool_names
    refute "linear_graphql" in tool_names
    refute "linear_set_assignee" in tool_names
    refute "linear.get_current_issue" in tool_names
    refute "linear.set_assignee" in tool_names
    refute "github.get_pull_request" in tool_names

    assert Enum.all?(tool_names, &Regex.match?(~r/^[a-zA-Z0-9_-]+$/, &1))

    assert Enum.all?(DynamicTool.tool_specs(), fn spec ->
             get_in(spec, ["inputSchema", "additionalProperties"]) == false
           end)

    assert %{
             "inputSchema" => %{
               "properties" => %{
                 "make_public" => %{"type" => "boolean", "default" => false, "description" => make_public_description}
               }
             }
           } = Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "linear_attach_file"))

    assert make_public_description =~ "world-readable"
  end

  test "unsupported raw linear_graphql returns tool_not_found" do
    response = DynamicTool.execute("linear_graphql", %{"query" => "query Viewer { viewer { id } }"})

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "tool_not_found",
               "supportedTools" => supported_tools
             }
           } = Jason.decode!(response["output"])

    refute "linear_graphql" in supported_tools
  end

  test "removed linear_set_assignee tool and legacy alias return tool_not_found" do
    for tool <- ["linear_set_assignee", "linear.set_assignee"] do
      response = DynamicTool.execute(tool, %{"assignee" => "self"})

      assert response["success"] == false

      assert %{
               "error" => %{
                 "code" => "tool_not_found",
                 "supportedTools" => supported_tools
               }
             } = Jason.decode!(response["output"])

      refute "linear_set_assignee" in supported_tools
      refute "linear.set_assignee" in supported_tools
    end
  end

  test "update_state resolves against the current issue team and updates current issue only" do
    test_pid = self()
    issue = %Issue{id: "issue-current", identifier: "ACME-1"}

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "In Progress"},
        issue: issue,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          cond do
            query =~ "SymphonyAgentIssueTeamStates" ->
              {:ok,
               %{
                 "data" => %{
                   "issue" => %{
                     "team" => %{
                       "states" => %{
                         "nodes" => [
                           %{"id" => "state-started", "name" => "In Progress", "type" => "started"}
                         ]
                       }
                     }
                   }
                 }
               }}

            query =~ "SymphonyAgentUpdateIssueState" ->
              {:ok,
               %{
                 "data" => %{
                   "issueUpdate" => %{
                     "success" => true,
                     "issue" => %{"id" => variables.id, "state" => %{"id" => variables.stateId}}
                   }
                 }
               }}
          end
        end
      )

    assert response["success"] == true
    assert_received {:linear_client_called, query, %{id: "issue-current"}, []}
    assert query =~ "SymphonyAgentIssueTeamStates"
    assert_received {:linear_client_called, query, %{id: "issue-current", stateId: "state-started"}, []}
    assert query =~ "SymphonyAgentUpdateIssueState"
  end

  test "update_state returns state_not_found with available states when name is unknown" do
    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "Shipped"},
        issue: %Issue{id: "issue-current"},
        linear_client: fn query, _variables, _opts ->
          true = query =~ "SymphonyAgentIssueTeamStates"

          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "team" => %{
                   "states" => %{
                     "nodes" => [
                       %{"id" => "state-1", "name" => "Todo", "type" => "unstarted"},
                       %{"id" => "state-2", "name" => "In Progress", "type" => "started"},
                       %{"id" => "state-3", "name" => "Done", "type" => "completed"}
                     ]
                   }
                 }
               }
             }
           }}
        end
      )

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "state_not_found",
               "available_states" => ["Todo", "In Progress", "Done"]
             }
           } = Jason.decode!(response["output"])
  end

  test "update_state resolves a UUID state id against the current issue team" do
    test_pid = self()
    state_uuid = "11111111-2222-3333-4444-555555555555"

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => String.upcase(state_uuid)},
        issue: %Issue{id: "issue-current"},
        linear_client: update_state_client(test_pid, [%{"id" => state_uuid, "name" => "In Review", "type" => "started"}])
      )

    assert response["success"] == true
    assert_received {:linear_client_called, query, %{id: "issue-current"}}
    assert query =~ "SymphonyAgentIssueTeamStates"
    assert_received {:linear_client_called, query, %{id: "issue-current", stateId: ^state_uuid}}
    assert query =~ "SymphonyAgentUpdateIssueState"
  end

  test "update_state returns state_not_found for a UUID outside the current issue team" do
    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "11111111-2222-3333-4444-555555555555"},
        issue: %Issue{id: "issue-current"},
        linear_client: update_state_client(self(), [%{"id" => "state-1", "name" => "Todo", "type" => "unstarted"}])
      )

    assert response["success"] == false
    assert %{"error" => %{"code" => "state_not_found", "available_states" => ["Todo"]}} = Jason.decode!(response["output"])
    refute_received {:linear_client_called, _query, %{stateId: _state_id}}
  end

  test "update_state refuses to move the issue to Merging by name or by UUID" do
    merging_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    states = [%{"id" => merging_uuid, "name" => "Merging", "type" => "started"}]

    for state_name_or_id <- ["Merging", " merging ", merging_uuid] do
      response =
        DynamicTool.execute(
          "linear_update_state",
          %{"state_name_or_id" => state_name_or_id},
          issue: %Issue{id: "issue-current"},
          linear_client: update_state_client(self(), states)
        )

      assert response["success"] == false

      assert %{"error" => %{"code" => "merging_requires_human_approval", "message" => message}} =
               Jason.decode!(response["output"])

      assert message =~ "a human has to do it"
      refute_received {:linear_client_called, _query, %{stateId: _state_id}}
    end
  end

  test "update_state refuses In Review while Auto Review is on and allows other states" do
    write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{enabled: true})

    states = [
      %{"id" => "state-review", "name" => "In Review", "type" => "started"},
      %{"id" => "state-progress", "name" => "In Progress", "type" => "started"}
    ]

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "in review"},
        issue: %Issue{id: "issue-current"},
        linear_client: update_state_client(self(), states)
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => "in_review_set_by_auto_review", "message" => message}} =
             Jason.decode!(response["output"])

    assert message =~ "Symphony moves the issue to Auto Review once the PR is open; leave the state as it is."
    refute_received {:linear_client_called, _query, %{stateId: _state_id}}

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "In Progress"},
        issue: %Issue{id: "issue-current"},
        linear_client: update_state_client(self(), states)
      )

    assert response["success"] == true
    assert_received {:linear_client_called, _query, %{stateId: "state-progress"}}
  end

  test "update_state allows In Review when the startup check turned Auto Review off" do
    write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{enabled: true, state: "QA Missing"})
    on_exit(fn -> SymphonyElixir.AutoReview.reset_for_test("QA Missing") end)

    tracker = SymphonyElixir.Tracker.Memory
    assert :disabled = SymphonyElixir.AutoReview.check_tracker_state(Config.settings!(), [], tracker: tracker)

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "In Review"},
        issue: %Issue{id: "issue-current"},
        linear_client: update_state_client(self(), [%{"id" => "state-review", "name" => "In Review", "type" => "started"}])
      )

    assert response["success"] == true
    assert_received {:linear_client_called, _query, %{stateId: "state-review"}}
  end

  test "update_state lets a breakdown parent hand its plan to In Review while Auto Review is on" do
    write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{enabled: true})

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "In Review"},
        issue: %Issue{id: "issue-current"},
        linear_client:
          update_state_client(self(), [%{"id" => "state-review", "name" => "In Review", "type" => "started"}], [
            %{"name" => "Breakdown"}
          ])
      )

    assert response["success"] == true
    assert_received {:linear_client_called, _query, %{stateId: "state-review"}}
  end

  test "update_state lets a final verification hand its result to In Review while Auto Review is on" do
    write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{enabled: true})
    states = [%{"id" => "state-review", "name" => "In Review", "type" => "started"}]
    test_pid = self()

    client = fn query, variables, opts ->
      if query =~ "SymphonyAgentIssueTeamStates" do
        send(test_pid, {:linear_client_called, query, variables})
        {:ok, %{"data" => %{"issue" => Map.put(team_states_issue(states, []), "title", "Final verification: Run profiles")}}}
      else
        update_state_client(test_pid, states).(query, variables, opts)
      end
    end

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "In Review"},
        issue: %Issue{id: "issue-current"},
        linear_client: client
      )

    assert response["success"] == true
    assert_received {:linear_client_called, _query, %{stateId: "state-review"}}
  end

  test "update_state refuses Waiting on sub-tickets: moving a parent there approves its plan" do
    on_exit(fn -> SymphonyElixir.SubIssueWait.reset_for_test("Waiting on sub-tickets") end)

    states = [
      %{"id" => "state-waiting", "name" => "Waiting on sub-tickets", "type" => "started"},
      %{"id" => "state-progress", "name" => "In Progress", "type" => "started"}
    ]

    refuse = fn labels ->
      response =
        DynamicTool.execute(
          "linear_update_state",
          %{"state_name_or_id" => "waiting on sub-tickets"},
          issue: %Issue{id: "issue-current"},
          linear_client: update_state_client(self(), states, labels)
        )

      assert response["success"] == false

      assert %{"error" => %{"code" => "waiting_on_sub_issues_state_requires_human_approval", "message" => message}} =
               Jason.decode!(response["output"])

      assert message =~ "approves its plan and promotes its sub-tickets"
      assert message =~ "move the parent to `In Review` instead"
      refute_received {:linear_client_called, _query, %{stateId: _state_id}}
    end

    for labels <- [nil, [%{"name" => "feature"}, %{}], [%{"name" => "Breakdown"}]], do: refuse.(labels)

    # Also when the startup check turned the state off.
    Application.put_env(:symphony_elixir, :memory_tracker_workflow_states, ["In Progress"])
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_workflow_states) end)

    ExUnit.CaptureLog.capture_log(fn ->
      tracker = SymphonyElixir.Tracker.Memory
      assert :disabled = SymphonyElixir.SubIssueWait.check_tracker_state(Config.settings!(), [], tracker: tracker)
    end)

    refuse.([%{"name" => "breakdown"}])

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "In Progress"},
        issue: %Issue{id: "issue-current"},
        linear_client: update_state_client(self(), states, [%{"name" => "breakdown"}])
      )

    assert response["success"] == true
    assert_received {:linear_client_called, _query, %{stateId: "state-progress"}}
  end

  describe "update_state and Human Review" do
    @review_states [
      %{"id" => "state-backlog", "name" => "Backlog", "type" => "backlog"},
      %{"id" => "state-todo", "name" => "Todo", "type" => "unstarted"},
      %{"id" => "state-review", "name" => "In Review", "type" => "started"},
      %{"id" => "state-human", "name" => "Human Review", "type" => "started"}
    ]

    defp move(target, issue_fields, opts \\ []) do
      test_pid = self()
      {states, opts} = Keyword.pop(opts, :states, @review_states)

      client = fn query, variables, client_opts ->
        if query =~ "SymphonyAgentIssueTeamStates",
          do: {:ok, %{"data" => %{"issue" => Map.merge(team_states_issue(states, []), issue_fields)}}},
          else: update_state_client(test_pid, states).(query, variables, client_opts)
      end

      response =
        DynamicTool.execute("linear_update_state", %{"state_name_or_id" => target}, [issue: %Issue{id: "issue-current"}, linear_client: client] ++ opts)

      assert response["success"] == true
      assert_received {:linear_client_called, _query, %{stateId: state_id}}
      state_id
    end

    test "a breakdown plan whose ticket says a person reviews it goes to Human Review instead of In Review" do
      needs_human = %{"title" => "Split the importer", "labels" => %{"nodes" => [%{"name" => "breakdown"}, %{"name" => "needs-human"}]}}
      must_not = %{"title" => "Split the importer", "description" => "This plan must not auto-approve.", "labels" => %{"nodes" => [%{"name" => "breakdown"}]}}
      plain_plan = %{"title" => "Split the importer", "description" => "Plan it.", "labels" => %{"nodes" => [%{"name" => "breakdown"}]}}
      not_a_plan = %{"title" => "Fix the importer", "labels" => %{"nodes" => [%{"name" => "needs-human"}]}}

      assert move("In Review", needs_human) == "state-human"
      assert move("in review", must_not) == "state-human"
      assert move("In Review", plain_plan) == "state-review"
      assert move("In Review", not_a_plan) == "state-review"

      # Without the state in the team, or with it turned off, the plan goes to In Review as before.
      assert move("In Review", needs_human, states: Enum.drop(@review_states, -1)) == "state-review"
      settings = Config.settings!()
      off = %{settings | tracker: %{settings.tracker | human_review_state: nil}}
      assert move("In Review", needs_human, settings: off) == "state-review"
    end

    test "after a human-action request, the move to Backlog or In Review goes to Human Review" do
      {:ok, registry} = CommentRegistry.start_link()

      assert move("Backlog", %{}, comment_registry: registry) == "state-backlog"

      CommentRegistry.record_human_action_request(registry)
      assert move("Backlog", %{}, comment_registry: registry) == "state-human"
      assert move("In Review", %{}, comment_registry: registry) == "state-human"
      assert move("Todo", %{}, comment_registry: registry) == "state-todo"

      settings = Config.settings!()
      off = %{settings | tracker: %{settings.tracker | human_review_state: nil}}
      assert move("Backlog", %{}, comment_registry: registry, settings: off) == "state-backlog"
    end

    test "with Auto Review off, an agent can move its issue to Human Review itself" do
      assert move("Human Review", %{}) == "state-human"
    end

    test "with Auto Review on, an issue with a PR cannot reach Human Review through the tool" do
      write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{enabled: true})
      {:ok, registry} = CommentRegistry.start_link()
      CommentRegistry.record_human_action_request(registry)
      implementation = %{"title" => "Fix the importer", "labels" => %{"nodes" => []}}
      test_pid = self()

      for target <- ["In Review", "Human Review", "human review"] do
        response =
          DynamicTool.execute(
            "linear_update_state",
            %{"state_name_or_id" => target},
            issue: %Issue{id: "issue-current"},
            comment_registry: registry,
            linear_client: fn query, variables, client_opts ->
              if query =~ "SymphonyAgentIssueTeamStates",
                do: {:ok, %{"data" => %{"issue" => Map.merge(team_states_issue(@review_states, []), implementation)}}},
                else: update_state_client(test_pid, @review_states).(query, variables, client_opts)
            end
          )

        assert response["success"] == false
        assert %{"error" => %{"code" => "in_review_set_by_auto_review"}} = Jason.decode!(response["output"])
        refute_received {:linear_client_called, _query, %{stateId: _state_id}}
      end

      # The move to Backlog after a request has no PR to review, so it still goes to Human Review,
      # and a PR-less breakdown plan can still be moved there.
      assert move("Backlog", implementation, comment_registry: registry) == "state-human"
      assert move("Human Review", %{"labels" => %{"nodes" => [%{"name" => "breakdown"}]}}) == "state-human"
    end
  end

  test "update_state allows Waiting on sub-tickets when the waiting state is turned off in config" do
    settings = Config.settings!()
    settings = %{settings | tracker: %{settings.tracker | waiting_on_sub_issues_state: nil}}

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "Waiting on sub-tickets"},
        issue: %Issue{id: "issue-current"},
        settings: settings,
        linear_client: update_state_client(self(), [%{"id" => "state-waiting", "name" => "Waiting on sub-tickets", "type" => "started"}])
      )

    assert response["success"] == true
    assert_received {:linear_client_called, _query, %{stateId: "state-waiting"}}
  end

  test "add_comment surfaces commentCreate success=false from Linear as a failure" do
    {:ok, registry} = CommentRegistry.start_link()

    response =
      DynamicTool.execute(
        "linear_add_comment",
        %{"body" => "blocked"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"data" => %{"commentCreate" => %{"success" => false, "comment" => nil}}}}
        end
      )

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "linear_mutation_failed",
               "field" => "commentCreate"
             }
           } = Jason.decode!(response["output"])

    refute CommentRegistry.owned?(registry, "any-id")
  end

  describe "replies and linear_update_subissue" do
    test "linear_add_comment replies under a comment, and linear_get_comments shows the thread" do
      {:ok, registry} = CommentRegistry.start_link()
      test_pid = self()

      client = fn query, variables, _opts ->
        send(test_pid, {:linear_client_called, query, variables})

        if query =~ "SymphonyAgentIssueComments" do
          reply = %{"id" => "reply", "body" => "Done", "parent" => %{"id" => "c1"}}
          {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => [reply]}}}}}
        else
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "reply", "body" => variables.body}}}}}
        end
      end

      opts = [issue: %Issue{id: "issue-current"}, comment_registry: registry, linear_client: client]

      assert DynamicTool.execute("linear_add_comment", %{"body" => "Done", "parent_id" => " c1 "}, opts)["success"] == true
      assert_received {:linear_client_called, query, %{issueId: "issue-current", parentId: "c1", body: "Done"}}
      assert query =~ "SymphonyAgentAddReply"
      assert CommentRegistry.owned?(registry, "reply")

      for parent_id <- [" ", 7] do
        response = DynamicTool.execute("linear_add_comment", %{"body" => "Done", "parent_id" => parent_id}, opts)
        assert %{"error" => %{"code" => "invalid_comment_parent"}} = Jason.decode!(response["output"])
      end

      response = DynamicTool.execute("linear_get_comments", %{}, opts)
      assert [%{"id" => "reply", "parent" => %{"id" => "c1"}}] = Jason.decode!(response["output"])
      assert_received {:linear_client_called, query, _variables}
      assert query =~ "parent { id }"
    end

    test "is advertised outside the read-only scope" do
      assert %{"inputSchema" => %{"properties" => properties, "required" => ["identifier"]}} =
               Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "linear_update_subissue"))

      assert Enum.sort(Map.keys(properties)) == ["blocked_by", "cancel_reason", "description", "identifier", "title"]
      refute "linear_update_subissue" in Enum.map(DynamicTool.tool_specs(:read_only), & &1["name"])
    end

    test "edits a Backlog sub-issue and sets its sibling blockers" do
      opts = update_subissue_opts()

      response =
        DynamicTool.execute(
          "linear_update_subissue",
          %{"identifier" => "tp-3", "title" => " History ", "description" => "New scope", "blocked_by" => ["TP-2", "TP-5"]},
          opts
        )

      assert response["success"] == true
      assert %{"identifier" => "TP-3", "updated" => ["description", "title"], "blockedBy" => ["TP-2", "TP-5"]} = Jason.decode!(response["output"])
      assert_received {:linear_client_called, _query, %{id: "issue-3", input: %{"title" => "History", "description" => "New scope"}}}
      # TP-2 already blocks it; TP-5 is added; TP-4 is no longer listed and is removed;
      # OPS-1 is not a sibling and stays.
      assert_received {:linear_client_called, _query, %{input: %{"issueId" => "issue-5", "relatedIssueId" => "issue-3", "type" => "blocks"}}}
      assert_received {:linear_client_called, query, %{id: "rel-4"}}
      assert query =~ "SymphonyAgentDeleteIssueRelation"
      refute_received {:linear_client_called, _query, %{input: %{"issueId" => "issue-2"}}}
      refute_received {:linear_client_called, _query, %{id: "rel-ops"}}

      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-3", "description" => "Only this"}, opts)
      assert %{"identifier" => "TP-3", "updated" => ["description"]} = decoded = Jason.decode!(response["output"])
      refute Map.has_key?(decoded, "blockedBy")

      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-3", "blocked_by" => []}, opts)
      assert %{"updated" => [], "blockedBy" => []} = Jason.decode!(response["output"])
      refute_received {:linear_client_called, _query, %{input: %{"title" => _title}}}
    end

    test "cancels a Backlog sub-issue after posting the reason on it" do
      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-3", "cancel_reason" => "Merged into TP-2"}, update_subissue_opts())

      assert %{"identifier" => "TP-3", "canceled" => true} = Jason.decode!(response["output"])
      assert_received {:linear_client_called, _query, %{issueId: "issue-3", body: "Merged into TP-2"}}
      assert_received {:linear_client_called, _query, %{id: "issue-3", input: %{"stateId" => "state-canceled"}}}

      no_canceled = update_subissue_opts(states: [%{"id" => "state-backlog", "name" => "Backlog"}])
      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-3", "cancel_reason" => "Dropped"}, no_canceled)
      assert %{"error" => %{"code" => "canceled_state_not_found", "states" => ["Backlog"]}} = Jason.decode!(response["output"])
      refute_received {:linear_client_called, _query, %{body: "Dropped"}}

      by_type = update_subissue_opts(states: [%{"id" => "state-wontfix", "name" => "Won't do", "type" => "canceled"}])
      DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-3", "cancel_reason" => "Dropped"}, by_type)
      assert_received {:linear_client_called, _query, %{input: %{"stateId" => "state-wontfix"}}}
    end

    test "never changes a sub-issue a person promoted, or an issue that is not a sub-issue" do
      opts = update_subissue_opts()

      for args <- [%{"identifier" => "TP-4", "title" => "x"}, %{"identifier" => "TP-4", "cancel_reason" => "Dropped"}] do
        response = DynamicTool.execute("linear_update_subissue", args, opts)

        assert %{"error" => %{"code" => "subissue_not_in_backlog", "state" => "In Progress", "message" => message}} = Jason.decode!(response["output"])
        assert message =~ "TP-4 is in In Progress, not Backlog"
      end

      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-6", "title" => "x"}, opts)
      assert %{"error" => %{"code" => "subissue_not_in_backlog", "message" => message}} = Jason.decode!(response["output"])
      assert message =~ "an unknown state"

      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "OPS-1", "title" => "x"}, opts)
      assert %{"error" => %{"code" => "not_a_subissue", "sub_issues" => ["TP-2", "TP-3", "TP-4", "TP-5", "TP-6"]}} = Jason.decode!(response["output"])

      # Only mutations past the scope read would change anything; none ran.
      refute_received {:linear_client_called, _query, %{input: _input}}
      refute_received {:linear_client_called, _query, %{body: _body}}
    end

    test "returns explicit error payloads for invalid input and failed writes" do
      no_linear = [issue: %Issue{id: "issue-current"}, linear_client: fn _query, _variables, _opts -> flunk("Linear should not be called") end]

      for {args, code} <- [
            {%{"title" => "x"}, "invalid_subissue_identifier"},
            {%{"identifier" => " ", "title" => "x"}, "invalid_subissue_identifier"},
            {%{"identifier" => "TP-3"}, "invalid_subissue_update"},
            {%{"identifier" => "TP-3", "title" => " "}, "invalid_subissue_title"},
            {%{"identifier" => "TP-3", "description" => 1}, "invalid_subissue_description"},
            {%{"identifier" => "TP-3", "blocked_by" => "TP-2"}, "invalid_subissue_blocked_by"},
            {%{"identifier" => "TP-3", "cancel_reason" => ""}, "invalid_subissue_cancel_reason"},
            {%{"identifier" => "TP-3", "cancel_reason" => "Dropped", "title" => "x"}, "invalid_subissue_update"}
          ] do
        response = DynamicTool.execute("linear_update_subissue", args, no_linear)
        assert %{"error" => %{"code" => ^code}} = Jason.decode!(response["output"])
      end

      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-3", "state" => "Todo"}, no_linear)
      assert %{"error" => %{"code" => "unexpected_arguments"}} = Jason.decode!(response["output"])

      opts = update_subissue_opts()
      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-3", "blocked_by" => ["TP-3", "OPS-1"]}, opts)

      assert %{"error" => %{"code" => "blocked_by_not_sibling", "unknown" => ["TP-3", "OPS-1"], "message" => message}} = Jason.decode!(response["output"])
      assert message =~ "Nothing was changed."

      failing = update_subissue_opts(fail: "SymphonyAgentCreateIssueRelation")
      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-3", "blocked_by" => ["TP-2", "TP-5"]}, failing)
      assert %{"error" => %{"code" => "blocked_by_relation_failed", "identifier" => "TP-3", "blocker" => "TP-5"}} = Jason.decode!(response["output"])

      failing = update_subissue_opts(fail: "SymphonyAgentDeleteIssueRelation")
      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-3", "blocked_by" => ["TP-2"]}, failing)
      assert %{"error" => %{"code" => "remove_blocked_by_failed"}} = Jason.decode!(response["output"])

      failing = update_subissue_opts(fail: "SymphonyAgentUpdateSubissue")
      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-3", "title" => "x"}, failing)
      assert %{"error" => %{"code" => "linear_mutation_failed", "field" => "issueUpdate"}} = Jason.decode!(response["output"])

      empty = update_subissue_opts(scope: %{"data" => %{"issue" => nil}})
      response = DynamicTool.execute("linear_update_subissue", %{"identifier" => "TP-3", "title" => "x"}, empty)
      assert response["success"] == false
    end
  end

  defp update_subissue_opts(overrides \\ []) do
    test_pid = self()

    states =
      Keyword.get(overrides, :states, [
        %{"id" => "state-backlog", "name" => "Backlog", "type" => "backlog"},
        %{"id" => "state-canceled", "name" => "Canceled", "type" => "canceled"}
      ])

    child = fn id, identifier, state, relations ->
      %{"id" => id, "identifier" => identifier, "state" => state, "inverseRelations" => %{"nodes" => relations}}
    end

    blocker = fn id, type, issue_id, identifier ->
      %{"id" => id, "type" => type, "issue" => %{"id" => issue_id, "identifier" => identifier}}
    end

    scope =
      Keyword.get(overrides, :scope, %{
        "data" => %{
          "issue" => %{
            "id" => "issue-current",
            "team" => %{"states" => %{"nodes" => states}},
            "children" => %{
              "nodes" => [
                child.("issue-2", "TP-2", %{"name" => "Backlog"}, []),
                child.("issue-3", "TP-3", %{"name" => "Backlog"}, [
                  blocker.("rel-2", "blocks", "issue-2", "TP-2"),
                  blocker.("rel-4", "blocks", "issue-4", "TP-4"),
                  blocker.("rel-ops", "blocks", "issue-ops", "OPS-1"),
                  blocker.("rel-dup", "duplicate", "issue-5", "TP-5")
                ]),
                child.("issue-4", "TP-4", %{"name" => "In Progress"}, []),
                child.("issue-5", "TP-5", %{"name" => "Backlog"}, []),
                %{"id" => "issue-6", "identifier" => "TP-6", "state" => nil}
              ]
            }
          }
        }
      })

    fail = Keyword.get(overrides, :fail)

    client = fn query, variables, _opts ->
      send(test_pid, {:linear_client_called, query, variables})

      {field, name} =
        cond do
          query =~ "SymphonyAgentSubissueUpdateScope" -> {nil, nil}
          query =~ "SymphonyAgentUpdateSubissue" -> {"issueUpdate", "SymphonyAgentUpdateSubissue"}
          query =~ "SymphonyAgentDeleteIssueRelation" -> {"issueRelationDelete", "SymphonyAgentDeleteIssueRelation"}
          query =~ "SymphonyAgentCreateIssueRelation" -> {"issueRelationCreate", "SymphonyAgentCreateIssueRelation"}
          query =~ "SymphonyAgentAddComment" -> {"commentCreate", "SymphonyAgentAddComment"}
        end

      if field, do: {:ok, %{"data" => %{field => %{"success" => fail != name}}}}, else: {:ok, scope}
    end

    [issue: %Issue{id: "issue-current"}, linear_client: client]
  end

  describe "linear_create_subissue" do
    test "is advertised with only title, description, priority and blocked_by, and hidden from the read-only scope" do
      assert %{"inputSchema" => %{"properties" => properties, "required" => ["title", "description"]}} =
               Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "linear_create_subissue"))

      assert properties |> Map.keys() |> Enum.sort() == ["blocked_by", "description", "priority", "title"]
      refute "linear_create_subissue" in Enum.map(DynamicTool.tool_specs(:read_only), & &1["name"])

      response =
        DynamicTool.execute("linear_create_subissue", %{"title" => "Slice", "description" => "body"},
          issue: %Issue{id: "issue-current"},
          tool_scope: :read_only,
          linear_client: fn _query, _variables, _opts -> flunk("read-only scope must not create issues") end
        )

      assert %{"error" => %{"code" => "tool_scope_rejected"}} = Jason.decode!(response["output"])
    end

    test "the QA scope reads and attaches evidence but cannot write anything else" do
      qa_tools = Enum.map(DynamicTool.tool_specs(:qa), & &1["name"])

      assert "linear_attach_file" in qa_tools
      assert "linear_get_parent_issue" in qa_tools
      assert "github_get_pr_checks" in qa_tools
      refute Enum.any?(~w(linear_update_state linear_add_comment linear_update_comment linear_create_subissue github_push_branch github_create_pull_request), &(&1 in qa_tools))

      response =
        DynamicTool.execute("linear_update_state", %{"state_name_or_id" => "In Review"},
          issue: %Issue{id: "issue-current"},
          tool_scope: :qa,
          linear_client: fn _query, _variables, _opts -> flunk("QA scope must not move the issue") end
        )

      assert %{"error" => %{"code" => "tool_scope_rejected", "scope" => "qa", "message" => message}} = Jason.decode!(response["output"])
      assert message =~ "JSON verdict"
    end

    test "only the QA scope lists and runs the host-side qa tools" do
      qa_tools = Enum.map(DynamicTool.tool_specs(:qa), & &1["name"])

      for tool <- SymphonyElixir.QaDriver.tools() do
        assert tool in qa_tools
        refute tool in Enum.map(DynamicTool.tool_specs(), & &1["name"])
        refute tool in Enum.map(DynamicTool.tool_specs(:read_only), & &1["name"])
      end

      response = DynamicTool.execute("qa_build", %{}, issue: %Issue{id: "issue-current"})
      assert %{"error" => %{"code" => "tool_scope_rejected", "tool" => "qa_build", "message" => message}} = Jason.decode!(response["output"])
      assert message =~ "only available to the QA agent"

      response = DynamicTool.execute("qa_build", %{}, issue: %Issue{id: "issue-current"}, tool_scope: :qa)
      refute response["success"]
      assert %{"error" => %{"code" => "qa_driver_unavailable"}} = Jason.decode!(response["output"])

      response = DynamicTool.execute("qa_ax_tree", %{"pid" => 1, "depth" => 3}, issue: %Issue{id: "issue-current"}, tool_scope: :qa)
      assert %{"error" => %{"code" => "unexpected_arguments"}} = Jason.decode!(response["output"])

      response = DynamicTool.execute("qa_put_file", %{"local_path" => "qa-evidence/a.yml", "mode" => "0777"}, issue: %Issue{id: "issue-current"}, tool_scope: :qa)
      assert %{"error" => %{"code" => "unexpected_arguments"}} = Jason.decode!(response["output"])
    end

    test "only the QA scope lists and runs the qa_android tools, routed to the Android driver" do
      qa_tools = Enum.map(DynamicTool.tool_specs(:qa), & &1["name"])

      for tool <- QaAndroidDriver.tools() do
        assert tool in qa_tools
        refute tool in Enum.map(DynamicTool.tool_specs(), & &1["name"])
        refute tool in Enum.map(DynamicTool.tool_specs(:read_only), & &1["name"])

        # Executor and reviewer sessions.
        response = DynamicTool.execute(tool, %{}, issue: %Issue{id: "issue-current"})
        assert %{"error" => %{"code" => "tool_scope_rejected", "tool" => ^tool, "message" => message}} = Jason.decode!(response["output"])
        assert message =~ "Android app"

        response = DynamicTool.execute(tool, %{}, issue: %Issue{id: "issue-current"}, tool_scope: :read_only)
        assert %{"error" => %{"code" => "tool_scope_rejected", "tool" => ^tool}} = Jason.decode!(response["output"])
      end

      # The macOS driver is not asked, even when it is there; `apk` reaches the Android driver.
      for args <- [%{}, %{"apk" => "app-catalog/build/outputs/apk/debug/app-catalog-debug.apk"}] do
        response = DynamicTool.execute("qa_android_install", args, issue: %Issue{id: "issue-current"}, tool_scope: :qa, qa_driver: self())
        assert %{"error" => %{"code" => "qa_android_driver_unavailable"}} = Jason.decode!(response["output"])
      end

      response =
        DynamicTool.execute("qa_android_launch", %{"application_id" => "com.example.app", "pid" => 1}, issue: %Issue{id: "issue-current"}, tool_scope: :qa)

      assert %{"error" => %{"code" => "unexpected_arguments"}} = Jason.decode!(response["output"])

      for {tool, args} <- [
            {"qa_android_tap", %{"x" => 1, "y" => 1, "pid" => 1}},
            {"qa_android_type", %{"text" => "a", "shell" => "id"}},
            {"qa_android_install", %{"apk" => "app.apk", "apk_path" => "../outside.apk"}},
            {"qa_android_put_file", %{"local_path" => "qa-evidence/rows.csv", "device_path" => "/data/local/tmp/rows.csv"}}
          ] do
        response = DynamicTool.execute(tool, args, issue: %Issue{id: "issue-current"}, tool_scope: :qa)
        assert %{"error" => %{"code" => "unexpected_arguments"}} = Jason.decode!(response["output"])
      end
    end

    test "rejects smuggled team, project, parent, assignee, state and issue id arguments" do
      {:ok, registry} = CommentRegistry.start_link()

      for {key, code_message} <- [
            {"teamId", "team, project, parent"},
            {"project_id", "team, project, parent"},
            {"parentId", "team, project, parent"},
            {"parent", "team, project, parent"},
            {"assigneeId", "team, project, parent"},
            {"stateId", "team, project, parent"},
            {"issue_id", "issue id arguments are not accepted"}
          ] do
        response =
          DynamicTool.execute(
            "linear_create_subissue",
            %{"title" => "Slice", "description" => "body", key => "smuggled"},
            issue: %Issue{id: "issue-current"},
            comment_registry: registry,
            linear_client: fn _query, _variables, _opts -> flunk("smuggled scope must not reach Linear") end
          )

        assert response["success"] == false
        assert %{"error" => %{"code" => "scope_argument_rejected", "message" => message}} = Jason.decode!(response["output"])
        assert message =~ code_message
      end
    end

    test "creates the sub-issue through the legacy alias and reports the cap past it" do
      {:ok, registry} = CommentRegistry.start_link()

      client = fn query, _variables, _opts ->
        if query =~ "SymphonyAgentSubissueScope" do
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-current",
                 "team" => %{"id" => "team-1", "states" => %{"nodes" => [%{"id" => "state-backlog", "name" => "Backlog"}]}}
               }
             }
           }}
        else
          {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => "issue-new", "identifier" => "TP-1"}}}}}
        end
      end

      opts = [issue: %Issue{id: "issue-current"}, comment_registry: registry, linear_client: client]

      for _ <- 1..10 do
        response = DynamicTool.execute("linear.create_subissue", %{title: "Slice", description: "body", priority: 3}, opts)
        assert response["success"] == true
      end

      response = DynamicTool.execute("linear_create_subissue", %{"title" => "Slice", "description" => "body"}, opts)
      assert %{"error" => %{"code" => "subissue_cap_reached", "cap" => 10}} = Jason.decode!(response["output"])
    end

    test "returns explicit error payloads for invalid input, no registry and no Backlog state" do
      {:ok, registry} = CommentRegistry.start_link()
      no_linear = fn _query, _variables, _opts -> flunk("Linear should not be called") end
      opts = [issue: %Issue{id: "issue-current"}, comment_registry: registry, linear_client: no_linear]

      for {args, code} <- [
            {%{"title" => " ", "description" => "body"}, "invalid_subissue_title"},
            {%{"title" => "Slice", "description" => nil}, "invalid_subissue_description"},
            {%{"title" => "Slice", "description" => "body", "priority" => 9}, "invalid_subissue_priority"},
            {%{"title" => "Slice", "description" => "body", "blocked_by" => "TP-1"}, "invalid_subissue_blocked_by"}
          ] do
        response = DynamicTool.execute("linear_create_subissue", args, opts)
        assert %{"error" => %{"code" => ^code}} = Jason.decode!(response["output"])
      end

      response =
        DynamicTool.execute("linear_create_subissue", %{"title" => "Slice", "description" => "body"}, Keyword.delete(opts, :comment_registry))

      assert %{"error" => %{"code" => "subissue_registry_unavailable"}} = Jason.decode!(response["output"])

      response =
        DynamicTool.execute(
          "linear_create_subissue",
          %{"title" => "Slice", "description" => "body"},
          Keyword.put(opts, :linear_client, fn _query, _variables, _opts ->
            {:ok, %{"data" => %{"issue" => %{"id" => "issue-current", "team" => %{"states" => %{"nodes" => [%{"id" => "s", "name" => "Todo"}]}}}}}}
          end)
        )

      assert %{"error" => %{"code" => "backlog_state_not_found", "available_states" => ["Todo"]}} = Jason.decode!(response["output"])
    end

    test "returns explicit error payloads for blocked_by refusals and failed links" do
      {:ok, registry} = CommentRegistry.start_link()

      client = fn create_result, relation_result ->
        fn query, _variables, _opts ->
          cond do
            query =~ "SymphonyAgentSubissueScope" ->
              {:ok,
               %{
                 "data" => %{
                   "issue" => %{
                     "id" => "issue-current",
                     "team" => %{"id" => "team-1", "states" => %{"nodes" => [%{"id" => "state-backlog", "name" => "Backlog"}]}},
                     "children" => %{"nodes" => [%{"id" => "issue-a", "identifier" => "TP-2"}]}
                   }
                 }
               }}

            query =~ "SymphonyAgentCreateSubissue" ->
              {:ok, %{"data" => %{"issueCreate" => create_result}}}

            true ->
              {:ok, %{"data" => %{"issueRelationCreate" => relation_result}}}
          end
        end
      end

      created = %{"success" => true, "issue" => %{"id" => "issue-new", "identifier" => "TP-3"}}
      opts = [issue: %Issue{id: "issue-current"}, comment_registry: registry, linear_client: client.(created, %{"success" => true})]
      args = %{"title" => "Slice", "description" => "body", "blocked_by" => ["tp-2"]}

      response = DynamicTool.execute("linear_create_subissue", args, opts)
      assert response["success"] == true
      assert %{"data" => %{"issueCreate" => %{"issue" => %{"blockedBy" => ["TP-2"]}}}} = Jason.decode!(response["output"])

      response = DynamicTool.execute("linear_create_subissue", %{args | "blocked_by" => ["TP-2", "OPS-9"]}, opts)

      assert %{"error" => %{"code" => "blocked_by_not_sibling", "unknown" => ["OPS-9"], "sub_issues" => ["TP-2", "TP-3"], "message" => message}} =
               Jason.decode!(response["output"])

      assert message =~ "Not a sub-issue: OPS-9. Nothing was created."

      response = DynamicTool.execute("linear_create_subissue", args, Keyword.put(opts, :linear_client, client.(created, %{"success" => false})))

      assert %{"error" => %{"code" => "blocked_by_relation_failed", "identifier" => "TP-3", "blocker" => "TP-2", "message" => message}} =
               Jason.decode!(response["output"])

      assert message =~ "Created TP-3, but could not mark it blocked by TP-2"

      response = DynamicTool.execute("linear_create_subissue", args, Keyword.put(opts, :linear_client, client.(%{"success" => true}, nil)))
      assert %{"error" => %{"code" => "subissue_not_returned"}} = Jason.decode!(response["output"])
    end
  end

  describe "linear_add_blocked_by" do
    test "is advertised with only blocked_by, hidden from the read-only scope, and links through the legacy alias" do
      assert %{"inputSchema" => %{"properties" => properties, "required" => ["blocked_by"]}} =
               Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "linear_add_blocked_by"))

      assert Map.keys(properties) == ["blocked_by"]
      refute "linear_add_blocked_by" in Enum.map(DynamicTool.tool_specs(:read_only), & &1["name"])

      client = fn query, variables, _opts ->
        if query =~ "SymphonyAgentIssueByIdentifier",
          do: {:ok, %{"data" => %{"issue" => %{"id" => "id-" <> variables.id, "identifier" => variables.id}}}},
          else: {:ok, %{"data" => %{"issueRelationCreate" => %{"success" => true}}}}
      end

      response = DynamicTool.execute("linear.add_blocked_by", %{blocked_by: ["TP-2"]}, issue: %Issue{id: "issue-current"}, linear_client: client)
      assert response["success"] == true
      assert %{"blockedBy" => ["TP-2"]} = Jason.decode!(response["output"])
    end

    test "returns explicit error payloads" do
      issue = %Issue{id: "issue-current"}

      lookup = fn issue_node ->
        fn query, _variables, _opts ->
          if query =~ "SymphonyAgentIssueByIdentifier",
            do: {:ok, %{"data" => %{"issue" => issue_node}}},
            else: {:error, :linear_down}
        end
      end

      for {args, client, code} <- [
            {%{"blocked_by" => []}, lookup.(nil), "invalid_add_blocked_by"},
            {%{"blocked_by" => ["TP-404"]}, lookup.(nil), "blocked_by_not_found"},
            {%{"blocked_by" => ["TP-1"]}, lookup.(%{"id" => "issue-current"}), "blocked_by_self"},
            {%{"blocked_by" => ["TP-2"]}, lookup.(%{"id" => "issue-2"}), "add_blocked_by_failed"}
          ] do
        response = DynamicTool.execute("linear_add_blocked_by", args, issue: issue, linear_client: client)
        assert %{"error" => %{"code" => ^code, "message" => message}} = Jason.decode!(response["output"])
        assert message =~ "linear_add_blocked_by" or message =~ "Could not mark the current issue blocked by TP-2"
      end
    end
  end

  describe "linear_get_related_issues" do
    setup do
      family = %{
        "id" => "issue-fv",
        "inverseRelations" => %{"nodes" => [%{"type" => "blocks", "issue" => %{"id" => "issue-2", "identifier" => "TP-2", "title" => "Slice"}}]},
        "parent" => %{"id" => "issue-1", "identifier" => "TP-1", "title" => "Parent", "children" => %{"nodes" => [%{"id" => "issue-2", "identifier" => "TP-2", "title" => "Slice"}]}}
      }

      client = fn query, variables, _opts ->
        if query =~ "SymphonyAgentRelatedIssues",
          do: {:ok, %{"data" => %{"issue" => family}}},
          else: {:ok, %{"data" => %{"issue" => %{"id" => variables.id, "identifier" => "TP-2", "comments" => %{"nodes" => [%{"id" => "qa", "body" => "QA report"}]}}}}}
      end

      [opts: [issue: %Issue{id: "issue-fv"}, tool_scope: :read_only, linear_client: client]]
    end

    test "lists the family, and reads a sibling's comments in the read-only scope", %{opts: opts} do
      assert %{"inputSchema" => %{"properties" => properties}} = Enum.find(DynamicTool.tool_specs(:read_only), &(&1["name"] == "linear_get_related_issues"))
      assert properties |> Map.keys() |> Enum.sort() == ["comment_limit", "identifier"]
      assert "linear_get_related_issues" in Enum.map(DynamicTool.tool_specs(:qa), & &1["name"])

      response = DynamicTool.execute("linear_get_related_issues", %{}, opts)
      assert Enum.map(Jason.decode!(response["output"]), &{&1["relation"], &1["identifier"]}) == [{"inverse_relation", "TP-2"}, {"parent", "TP-1"}, {"sibling", "TP-2"}]

      response = DynamicTool.execute("linear_get_related_issues", %{"identifier" => "TP-2", "comment_limit" => 10}, opts)
      assert response["success"] == true
      assert %{"relations" => ["blocked_by", "sibling"], "comments" => [%{"id" => "qa", "body" => body}]} = Jason.decode!(response["output"])
      assert body == PromptSafety.linear_issue_comment_body("QA report")
    end

    test "returns explicit error payloads", %{opts: opts} do
      for {args, code} <- [
            {%{"identifier" => "TP-99"}, "issue_outside_family"},
            {%{"comment_limit" => 5}, "invalid_related_issue_identifier"},
            {%{"identifier" => "TP-2", "comment_limit" => 0}, "invalid_limit"}
          ] do
        response = DynamicTool.execute("linear_get_related_issues", args, opts)
        refute response["success"]
        assert %{"error" => %{"code" => ^code}} = Jason.decode!(response["output"])
      end

      response = DynamicTool.execute("linear_get_related_issues", %{"identifier" => "TP-99"}, opts)
      assert %{"error" => %{"message" => message, "related_issues" => ["TP-2", "TP-1"]}} = Jason.decode!(response["output"])
      assert message =~ "TP-99 is not the parent, a sibling, a sub-issue or a blocker"

      response = DynamicTool.execute("linear_get_related_issues", %{"issue_id" => "issue-other"}, opts)
      assert %{"error" => %{"code" => "scope_argument_rejected"}} = Jason.decode!(response["output"])
    end
  end

  describe "linear_create_project_update" do
    test "is advertised with only body and health, and hidden from the read-only scope" do
      assert %{"inputSchema" => %{"properties" => properties, "required" => ["body"]}} =
               Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "linear_create_project_update"))

      assert properties |> Map.keys() |> Enum.sort() == ["body", "health"]
      refute "linear_create_project_update" in Enum.map(DynamicTool.tool_specs(:read_only), & &1["name"])

      response =
        DynamicTool.execute("linear_create_project_update", %{"body" => "Shipped"},
          issue: %Issue{id: "issue-current"},
          tool_scope: :read_only,
          linear_client: fn _query, _variables, _opts -> flunk("read-only scope must not post project updates") end
        )

      assert %{"error" => %{"code" => "tool_scope_rejected"}} = Jason.decode!(response["output"])

      response =
        DynamicTool.execute("linear_create_project_update", %{"body" => "Shipped", "projectId" => "project-other"},
          issue: %Issue{id: "issue-current"},
          linear_client: fn _query, _variables, _opts -> flunk("smuggled project must not reach Linear") end
        )

      assert %{"error" => %{"code" => "unexpected_arguments", "arguments" => ["projectId"]}} = Jason.decode!(response["output"])
    end

    test "posts through the legacy alias and reports the cap past it" do
      {:ok, registry} = CommentRegistry.start_link()

      client = fn query, _variables, _opts ->
        if query =~ "SymphonyAgentProjectUpdateScope",
          do: {:ok, %{"data" => %{"issue" => %{"project" => %{"id" => "project-1"}}}}},
          else: {:ok, %{"data" => %{"projectUpdateCreate" => %{"success" => true, "projectUpdate" => %{"id" => "update-1"}}}}}
      end

      opts = [issue: %Issue{id: "issue-current"}, comment_registry: registry, linear_client: client]

      response = DynamicTool.execute("linear.create_project_update", %{body: "Shipped", health: "onTrack"}, opts)
      assert response["success"] == true

      response = DynamicTool.execute("linear_create_project_update", %{"body" => "Again"}, opts)
      assert %{"error" => %{"code" => "project_update_cap_reached", "cap" => 1}} = Jason.decode!(response["output"])
    end

    test "returns explicit error payloads for invalid input, no registry and no project" do
      {:ok, registry} = CommentRegistry.start_link()
      no_linear = fn _query, _variables, _opts -> flunk("Linear should not be called") end
      opts = [issue: %Issue{id: "issue-current"}, comment_registry: registry, linear_client: no_linear]

      for {args, code} <- [
            {%{"body" => " "}, "invalid_project_update_body"},
            {%{"body" => "Shipped", "health" => "great"}, "invalid_project_update_health"}
          ] do
        response = DynamicTool.execute("linear_create_project_update", args, opts)
        assert %{"error" => %{"code" => ^code}} = Jason.decode!(response["output"])
      end

      response = DynamicTool.execute("linear_create_project_update", %{"body" => "Shipped"}, Keyword.delete(opts, :comment_registry))
      assert %{"error" => %{"code" => "project_update_registry_unavailable"}} = Jason.decode!(response["output"])

      response =
        DynamicTool.execute(
          "linear_create_project_update",
          %{"body" => "Shipped"},
          Keyword.put(opts, :linear_client, fn _query, _variables, _opts -> {:ok, %{"data" => %{"issue" => %{"project" => nil}}}} end)
        )

      assert %{"error" => %{"code" => "issue_has_no_project"}} = Jason.decode!(response["output"])
    end
  end

  describe "linear_request_human_action" do
    @request %{"title" => "Add the release signing secrets", "why" => "Release fails.", "steps" => ["Add the secret."]}

    test "is advertised with its fields and hidden from the read-only scope" do
      assert %{"inputSchema" => %{"properties" => properties, "required" => ["title", "why", "steps"]}} =
               Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "linear_request_human_action"))

      assert properties |> Map.keys() |> Enum.sort() == ["est_minutes", "steps", "title", "unblocks", "why"]
      refute "linear_request_human_action" in Enum.map(DynamicTool.tool_specs(:read_only), & &1["name"])

      response =
        DynamicTool.execute("linear_request_human_action", Map.put(@request, "issue_id", "issue-other"),
          issue: %Issue{id: "issue-current"},
          linear_client: fn _query, _variables, _opts -> flunk("smuggled issue must not reach Linear") end
        )

      assert %{"error" => %{"code" => "scope_argument_rejected"}} = Jason.decode!(response["output"])
    end

    test "records the request and returns explicit error payloads" do
      {:ok, registry} = CommentRegistry.start_link()

      client = fn query, _variables, _opts ->
        cond do
          query =~ "SymphonyAgentHumanActionScope" ->
            {:ok,
             %{
               "data" => %{
                 "issue" => %{"id" => "issue-current", "team" => %{"id" => "team-1"}, "labels" => %{"nodes" => [%{"id" => "l1", "name" => "human-action"}]}},
                 "issueLabels" => %{"nodes" => []}
               }
             }}

          query =~ "SymphonyAgentAddComment" ->
            {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "comment-1"}}}}}
        end
      end

      opts = [issue: %Issue{id: "issue-current", identifier: "MOT-24"}, comment_registry: registry, linear_client: client]

      response = DynamicTool.execute("linear_request_human_action", @request, opts)
      assert response["success"] == true
      assert %{"requested" => true, "commentId" => "comment-1"} = Jason.decode!(response["output"])

      response = DynamicTool.execute("linear_request_human_action", Map.put(@request, "steps", []), opts)
      assert %{"error" => %{"code" => "invalid_human_action", "message" => "linear_request_human_action: `steps`" <> _rest}} = Jason.decode!(response["output"])

      disabled = Config.settings!() |> then(&%{&1 | human_actions: %{&1.human_actions | enabled: false}})
      response = DynamicTool.execute("linear_request_human_action", @request, Keyword.put(opts, :settings, disabled))
      assert %{"error" => %{"code" => "human_actions_disabled", "message" => message}} = Jason.decode!(response["output"])
      assert message =~ "blocker comment"

      for _slot <- 1..5, do: CommentRegistry.reserve_human_action(registry, 5)
      response = DynamicTool.execute("linear_request_human_action", @request, opts)
      assert %{"error" => %{"code" => "human_action_cap_reached", "cap" => 5}} = Jason.decode!(response["output"])
    end

    test "tells the agent to check a CI job's UTC age before asking about it" do
      assert %{"description" => description} = Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "linear_request_human_action"))
      assert description =~ "compute the job's age from the API's UTC timestamps against the current UTC time"
      assert description =~ "under 30 minutes old, wait for the CI poller's re-run"
    end
  end

  describe "linear_withdraw_human_action" do
    test "is advertised with its fields and hidden from the read-only scope" do
      assert %{"inputSchema" => %{"properties" => properties, "required" => ["reason"]}} =
               Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "linear_withdraw_human_action"))

      assert properties |> Map.keys() |> Enum.sort() == ["reason", "title"]
      refute "linear_withdraw_human_action" in Enum.map(DynamicTool.tool_specs(:read_only), & &1["name"])

      response =
        DynamicTool.execute("linear_withdraw_human_action", %{"reason" => "Not needed.", "issue_id" => "issue-other"},
          issue: %Issue{id: "issue-current"},
          linear_client: fn _query, _variables, _opts -> flunk("smuggled issue must not reach Linear") end
        )

      assert %{"error" => %{"code" => "scope_argument_rejected"}} = Jason.decode!(response["output"])
    end

    test "withdraws the request and returns explicit error payloads" do
      request = %{"id" => "comment-1", "body" => "## Action needed: Re-run CI", "createdAt" => "2026-10-04T18:57:00.000Z"}

      client = fn query, _variables, _opts ->
        cond do
          query =~ "SymphonyAgentHumanActionScope" ->
            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "id" => "issue-current",
                   "labels" => %{"nodes" => [%{"id" => "l1", "name" => "human-action"}]},
                   "comments" => %{"nodes" => [request]}
                 }
               }
             }}

          query =~ "SymphonyAgentAddReply" ->
            {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "reply-1"}}}}}

          query =~ "SymphonyAgentRemoveLabel" ->
            {:ok, %{"data" => %{"issueRemoveLabel" => %{"success" => true}}}}
        end
      end

      opts = [issue: %Issue{id: "issue-current", identifier: "MOT-24"}, linear_client: client, refresh_human_actions: fn -> :ok end]

      response = DynamicTool.execute("linear_withdraw_human_action", %{"reason" => "The run had just started."}, opts)
      assert response["success"] == true
      assert %{"withdrawn" => true, "replyCommentIds" => ["reply-1"], "labelRemoved" => true} = Jason.decode!(response["output"])

      response = DynamicTool.execute("linear_withdraw_human_action", %{"reason" => " "}, opts)

      assert %{"error" => %{"code" => "invalid_human_action_withdrawal", "message" => "linear_withdraw_human_action: `reason`" <> _rest}} =
               Jason.decode!(response["output"])
    end
  end

  test "legacy dotted tool aliases are accepted but still reject smuggled issue ids" do
    response =
      DynamicTool.execute(
        "linear.update_state",
        %{"issue_id" => "issue-other", "state_name_or_id" => "Done"},
        issue: %Issue{id: "issue-current"}
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => "scope_argument_rejected"}} =
             Jason.decode!(response["output"])
  end

  test "add_comment records ownership and update_comment allows owned comments" do
    {:ok, registry} = CommentRegistry.start_link()
    test_pid = self()

    add_response =
      DynamicTool.execute(
        "linear_add_comment",
        %{"body" => "first"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{
                 "success" => true,
                 "comment" => %{"id" => "comment-owned", "body" => variables.body, "url" => "https://linear/comment"}
               }
             }
           }}
        end
      )

    assert add_response["success"] == true
    add_comment = get_in(Jason.decode!(add_response["output"]), ["data", "commentCreate", "comment"])
    refute Map.has_key?(add_comment, "body")
    assert add_comment["bodyLength"] == String.length("first")
    assert CommentRegistry.owned?(registry, "comment-owned")

    update_response =
      DynamicTool.execute(
        "linear_update_comment",
        %{"comment_id" => "comment-owned", "body" => "edited"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          {:ok,
           %{
             "data" => %{
               "commentUpdate" => %{
                 "success" => true,
                 "comment" => %{"id" => variables.id, "body" => variables.body}
               }
             }
           }}
        end
      )

    assert update_response["success"] == true
    update_comment = get_in(Jason.decode!(update_response["output"]), ["data", "commentUpdate", "comment"])
    refute Map.has_key?(update_comment, "body")
    assert update_comment["bodyLength"] == String.length("edited")
    assert_received {:linear_client_called, query, %{id: "comment-owned", body: "edited"}, []}
    assert query =~ "SymphonyAgentUpdateComment"
  end

  test "add_comment logs a warning when Linear response omits the expected comment shape" do
    {:ok, registry} = CommentRegistry.start_link()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        response =
          DynamicTool.execute(
            "linear_add_comment",
            %{"body" => "shape-drift"},
            issue: %Issue{id: "issue-current", identifier: "MT-DRIFT"},
            comment_registry: registry,
            linear_client: fn _query, _variables, _opts ->
              # success=true with no `comment` key — a plausible API drift shape that previously
              # passed through compact_comment_mutation_response/2 silently and would leak the
              # full body back into the Codex stream if the body key ever moved.
              {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
            end
          )

        assert response["success"] == true
        decoded = Jason.decode!(response["output"])
        refute get_in(decoded, ["data", "commentCreate", "comment"])
      end)

    assert log =~ "comment-body compaction skipped"
    assert log =~ "commentCreate"
    assert log =~ ~s(issue_identifier="MT-DRIFT")
  end

  test "add_comment tolerates Linear response with data=nil without raising" do
    {:ok, registry} = CommentRegistry.start_link()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        response =
          DynamicTool.execute(
            "linear_add_comment",
            %{"body" => "nil-data"},
            issue: %Issue{id: "issue-current", identifier: "MT-NIL"},
            comment_registry: registry,
            linear_client: fn _query, _variables, _opts ->
              # Linear can return data=nil when check_mutation_success treats a missing
              # `success` field as success — the warning branch must not crash on it.
              {:ok, %{"data" => nil}}
            end
          )

        assert response["success"] == true
      end)

    assert log =~ "comment-body compaction skipped"
    assert log =~ "data_keys=[]"
    assert log =~ ~s(issue_identifier="MT-NIL")
  end

  test "update_comment rejects comments not created in this run" do
    {:ok, registry} = CommentRegistry.start_link()

    response =
      DynamicTool.execute(
        "linear_update_comment",
        %{"comment_id" => "comment-other", "body" => "edited"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called for unowned comments")
        end
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => ":comment_not_owned_by_run"}} =
             Jason.decode!(response["output"])
  end

  test "update_comment refuses a body copied from a truncated read" do
    {:ok, registry} = CommentRegistry.start_link()
    CommentRegistry.record(registry, "comment-owned")

    truncated_read =
      "## Symphony Workpad\n" <>
        String.duplicate("a", 100) <>
        "\n[... truncated by Symphony: linear_issue_comment_body exceeded 5000 characters ...]"

    response =
      DynamicTool.execute(
        "linear_update_comment",
        %{"comment_id" => "comment-owned", "body" => truncated_read},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called for a truncated comment body")
        end
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => "truncated_comment_body", "message" => message}} =
             Jason.decode!(response["output"])

    assert message =~ "linear_get_comments"
  end

  test "attach_file rejects paths outside the workspace before upload" do
    test_root = Path.join(System.tmp_dir!(), "linear-attach-file-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    outside = Path.join(test_root, "outside.txt")

    try do
      File.mkdir_p!(workspace)
      File.write!(outside, "outside")

      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => outside, "title" => "outside"},
          issue: %Issue{id: "issue-current"},
          workspace: workspace,
          linear_client: fn _query, _variables, _opts ->
            flunk("linear client should not be called for outside paths")
          end
        )

      assert response["success"] == false

      assert %{"error" => %{"code" => ":path_outside_workspace"}} =
               Jason.decode!(response["output"])
    after
      File.rm_rf(test_root)
    end
  end

  test "attach_file uploads privately by default" do
    workspace = tmp_workspace!("linear-attach-file-private")
    path = Path.join(workspace, "screenshot.png")
    File.write!(path, "png")
    test_pid = self()

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path, "title" => "Screenshot"},
          successful_attach_file_opts(workspace, test_pid)
        )

      assert response["success"] == true
      assert_received {:file_upload_requested, %{filename: "screenshot.png", size: 3, contentType: "image/png", makePublic: false}}

      assert_received {:file_uploaded, "https://linear-upload.example", [headers: [{"x-upload", "1"}, {"content-type", "image/png"}], body: "png"]}

      assert_received {:attachment_created, %{issueId: "issue-current", url: "https://linear-asset.example/screenshot.png", title: "Screenshot"}}
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file supports explicit public upload opt-in" do
    workspace = tmp_workspace!("linear-attach-file-public")
    path = Path.join(workspace, "screenshot.png")
    File.write!(path, "png")
    test_pid = self()

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path, "title" => "Screenshot", "make_public" => true},
          successful_attach_file_opts(workspace, test_pid)
        )

      assert response["success"] == true
      assert_received {:file_upload_requested, %{filename: "screenshot.png", size: 3, makePublic: true}}
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file rejects public uploads for extensions outside the allowlist" do
    workspace = tmp_workspace!("linear-attach-file-public-extension")

    disallowed_files = [
      {"notes.txt", ".txt"},
      {"data.json", ".json"},
      {"output", ""},
      {"screenshot.png.txt", ".txt"}
    ]

    try do
      Enum.each(disallowed_files, fn {filename, expected_extension} ->
        path = Path.join(workspace, filename)
        File.write!(path, "ordinary proof")

        response =
          DynamicTool.execute(
            "linear_attach_file",
            %{"local_path" => path, "make_public" => true},
            issue: %Issue{id: "issue-current"},
            workspace: workspace,
            linear_client: fn _query, _variables, _opts ->
              flunk("linear client should not be called for denied public extension")
            end,
            upload_client: fn _url, _opts ->
              flunk("disallowed public extensions should not be uploaded")
            end
          )

        assert response["success"] == false

        assert %{
                 "error" => %{
                   "code" => "public_extension_not_allowed",
                   "extension" => ^expected_extension
                 }
               } = Jason.decode!(response["output"])
      end)
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file applies configured public upload extension overrides" do
    workspace = tmp_workspace!("linear-attach-file-public-extension-override")
    path = Path.join(workspace, "diagnostic.log")
    File.write!(path, "ordinary proof")
    test_pid = self()

    settings = %Schema{
      workspace: %Schema.Workspace{
        attachments: %Schema.Workspace.Attachments{public_upload_extensions: [".png", ".log"]}
      }
    }

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path, "make_public" => true},
          successful_attach_file_opts(workspace, test_pid)
          |> Keyword.put(:settings, settings)
        )

      assert response["success"] == true
      assert_received {:file_upload_requested, %{filename: "diagnostic.log", makePublic: true}}
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file private uploads are not constrained by the public size cap" do
    workspace = tmp_workspace!("linear-attach-file-private-size")
    path = Path.join(workspace, "artifact.txt")
    File.write!(path, "123456")
    test_pid = self()

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path},
          successful_attach_file_opts(workspace, test_pid)
          |> Keyword.put(:max_public_upload_bytes, 5)
        )

      assert response["success"] == true
      assert_received {:file_upload_requested, %{filename: "artifact.txt", size: 6, makePublic: false}}
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file rejects public uploads for sensitive basenames before requesting an upload" do
    workspace = tmp_workspace!("linear-attach-file-sensitive")
    path = Path.join(workspace, ".env")
    File.write!(path, "TOKEN=secret")

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path, "make_public" => true},
          issue: %Issue{id: "issue-current"},
          workspace: workspace,
          linear_client: fn _query, _variables, _opts ->
            flunk("linear client should not be called for denied public sensitive upload")
          end
        )

      assert response["success"] == false

      assert %{
               "error" => %{
                 "code" => "public_upload_denied_sensitive_filename",
                 "filename" => ".env"
               }
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file rejects private uploads for sensitive basenames before requesting an upload" do
    workspace = tmp_workspace!("linear-attach-file-private-sensitive")

    sensitive_files = [
      {".env.local", "private_upload_denied_sensitive_filename"},
      {"deploy.pem", "private_upload_denied_sensitive_filename"},
      {"deploy.key", "private_upload_denied_sensitive_filename"}
    ]

    try do
      Enum.each(sensitive_files, fn {filename, expected_code} ->
        path = Path.join(workspace, filename)
        File.write!(path, "ordinary test fixture")

        response =
          DynamicTool.execute(
            "linear_attach_file",
            %{"local_path" => path},
            issue: %Issue{id: "issue-current"},
            workspace: workspace,
            linear_client: fn _query, _variables, _opts ->
              flunk("linear client should not be called for denied private sensitive upload")
            end,
            upload_client: fn _url, _opts ->
              flunk("sensitive private files should not be uploaded")
            end
          )

        assert response["success"] == false

        assert %{
                 "error" => %{
                   "code" => ^expected_code,
                   "filename" => ^filename
                 }
               } = Jason.decode!(response["output"])
      end)
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file enforces the public upload size cap before requesting an upload" do
    workspace = tmp_workspace!("linear-attach-file-size")
    path = Path.join(workspace, "large.png")
    File.write!(path, "123456")

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path, "make_public" => true},
          issue: %Issue{id: "issue-current"},
          workspace: workspace,
          max_public_upload_bytes: 5,
          linear_client: fn _query, _variables, _opts ->
            flunk("linear client should not be called for oversized public upload")
          end
        )

      assert response["success"] == false

      assert %{
               "error" => %{
                 "code" => "file_upload_too_large",
                 "actual_bytes" => 6,
                 "max_bytes" => 5,
                 "make_public" => true
               }
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.create_pull_request uses current branch and configured origin repo" do
    workspace = tmp_workspace!("github-create-pr")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        [
          "pr",
          "create",
          "--repo",
          "acme/symphony",
          "--head",
          "auto/ACME-3051",
          "--title",
          "Add tools",
          "--body",
          "Body",
          "--draft"
        ],
        opts ->
          assert opts[:cd] == workspace
          {"https://github.com/acme/symphony/pull/3051\n", 0}
      end

      response =
        DynamicTool.execute(
          "github_create_pull_request",
          %{"title" => "Add tools", "body" => "Body"},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true

      assert %{
               "url" => "https://github.com/acme/symphony/pull/3051",
               "repo" => "acme/symphony",
               "head" => "auto/ACME-3051"
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.create_pull_request rejects smuggled repo arguments" do
    response =
      DynamicTool.execute(
        "github_create_pull_request",
        %{"title" => "Add tools", "body" => "Body", "repo" => "attacker/repo"},
        workspace: System.tmp_dir!(),
        command_security: %{origin_repo: "acme/symphony"}
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => "scope_argument_rejected", "message" => message}} =
             Jason.decode!(response["output"])

    assert message =~ "configured origin"
  end

  test "github tools reject smuggled branch and remote arguments" do
    for {tool, args} <- [
          {"github_create_pull_request", %{"title" => "Add tools", "body" => "Body", "head" => "owned"}},
          {"github_get_pull_request", %{"branch" => "owned"}},
          {"github_fetch_origin", %{"refspec" => "main:refs/heads/owned"}},
          {"github_sync_base", %{"base" => "owned"}},
          {"github_add_pr_comment", %{"body" => "Looks good", "remote" => "evil"}},
          {"github_reply_to_review_comment", %{"comment_id" => 123, "body" => "Acked.", "repo" => "attacker/repo"}},
          {"github_get_pr_checks", %{"base" => "owned"}},
          {"github_list_pr_comments", %{"repo" => "attacker/repo"}},
          {"github_list_pr_review_comments", %{"repository" => "attacker/repo"}},
          {"github_list_pr_reviews", %{"current_branch" => "owned"}},
          {"github_get_failed_run_log", %{"ref" => "owned"}}
        ] do
      response =
        DynamicTool.execute(
          tool,
          args,
          workspace: System.tmp_dir!(),
          command_security: %{origin_repo: "acme/symphony"}
        )

      assert response["success"] == false
      assert %{"error" => %{"code" => "scope_argument_rejected"}} = Jason.decode!(response["output"])
    end
  end

  test "github.push_branch rejects smuggled refspec arguments" do
    response =
      DynamicTool.execute(
        "github_push_branch",
        %{"refspec" => "main:refs/heads/owned"},
        workspace: System.tmp_dir!(),
        command_security: %{origin_repo: "acme/symphony"}
      )

    assert response["success"] == false
    assert %{"error" => %{"code" => "scope_argument_rejected"}} = Jason.decode!(response["output"])
  end

  test "github.push_branch pushes origin current branch only" do
    workspace = tmp_workspace!("github-push-branch")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}

        ["remote", "get-url", "origin"], opts ->
          assert opts[:cd] == workspace
          {"git@github.com:acme/symphony.git\n", 0}

        ["remote", "get-url", "--push", "--all", "origin"], opts ->
          assert opts[:cd] == workspace
          {"git@github.com:acme/symphony.git\n", 0}

        ["ls-remote" | _rest], _opts ->
          {"", 0}

        ["push", "origin", "auto/ACME-3051"], opts ->
          assert opts[:cd] == workspace
          {"pushed\n", 0}
      end

      response =
        DynamicTool.execute(
          "github_push_branch",
          %{},
          github_tool_opts(workspace, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"remote" => "origin", "branch" => "auto/ACME-3051"} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.push_branch refusals name the push check command and the recorded failures" do
    workspace = tmp_workspace!("github-push-branch-push-check")
    head = String.duplicate("a", 40)
    recorded = String.duplicate("b", 40)

    try do
      git_runner = fn
        ["branch", "--show-current"], _opts -> {"auto/ACME-3051\n", 0}
        ["remote" | _rest], _opts -> {"git@github.com:acme/symphony.git\n", 0}
        ["ls-remote" | _rest], _opts -> {"", 0}
        ["rev-parse", "--verify", "--quiet", _ref], _opts -> {head <> "\n", 0}
        ["diff", "--name-only" | _rest], _opts -> {"lib/app.ex\n", 0}
        ["push" | _rest], _opts -> flunk("the push should be refused")
      end

      settings = %Schema{push_check: %Schema.PushCheck{command: ".githooks/pre-push --head", result_file: "push-check"}}
      opts = github_tool_opts(workspace, git_runner: git_runner, settings: settings)
      push = fn -> "github_push_branch" |> DynamicTool.execute(%{}, opts) |> Map.fetch!("output") |> Jason.decode!() end

      assert %{"error" => %{"code" => "push_check_required", "message" => message, "command" => ".githooks/pre-push --head", "head" => ^head}} =
               push.()

      assert message =~ "There is no `push-check`."
      assert message =~ "run `.githooks/pre-push --head` in your shell"
      assert message =~ "check has not passed for aaaaaaaaaaaa."

      File.write!(Path.join(workspace, "push-check"), "#{recorded} pass\n")
      assert %{"error" => %{"code" => "push_check_required", "message" => message}} = push.()
      assert message =~ "`push-check` holds the result for bbbbbbbbbbbb, not for this commit."

      File.write!(Path.join(workspace, "push-check"), "nonsense\n")
      assert %{"error" => %{"code" => "push_check_required", "message" => message}} = push.()
      assert message =~ "`push-check` is not a push check result."

      File.write!(
        Path.join(workspace, "push-check"),
        "#{head} fail\nmix compile --warnings-as-errors failed. Fix: resolve the warnings or errors above, commit, and push again.\n"
      )

      assert %{"error" => %{"code" => "push_check_failed", "message" => message, "result_file" => "push-check"}} = push.()
      assert message =~ "the repository's push check failed for aaaaaaaaaaaa:\nmix compile --warnings-as-errors failed."
      assert message =~ "Run `.githooks/pre-push --head` in your shell to see each check's output."
    after
      File.rm_rf(workspace)
    end
  end

  test "github_merge_pull_request merges through the scoped GitHub tool" do
    workspace = tmp_workspace!("github-merge-pull-request")

    try do
      response =
        DynamicTool.execute(
          "github_merge_pull_request",
          %{},
          merge_tool_opts(workspace, "Merging", [%{"name" => "mix test", "status" => "COMPLETED", "conclusion" => "SUCCESS"}])
        )

      assert response["success"] == true
      assert %{"merged" => true, "head_sha" => "abc123"} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github_merge_pull_request explains each refusal to the agent" do
    workspace = tmp_workspace!("github-merge-pull-request-refusals")

    try do
      failing_check = %{"name" => "mix test", "status" => "COMPLETED", "conclusion" => "FAILURE"}

      unapproved = DynamicTool.execute("github_merge_pull_request", %{}, merge_tool_opts(workspace, "In Review", []))
      assert %{"error" => %{"code" => "issue_not_in_merging_state", "message" => message}} = Jason.decode!(unapproved["output"])
      assert message =~ ~s("In Review")

      failing = DynamicTool.execute("github_merge_pull_request", %{}, merge_tool_opts(workspace, "Merging", [failing_check]))
      assert %{"error" => %{"code" => "checks_not_passing", "reason" => reason}} = Jason.decode!(failing["output"])
      assert reason =~ "mix test"

      closed = DynamicTool.execute("github_merge_pull_request", %{}, merge_tool_opts(workspace, "Merging", [], "CLOSED"))
      assert %{"error" => %{"code" => "pull_request_not_open", "message" => message}} = Jason.decode!(closed["output"])
      assert message =~ ~s("CLOSED")
    after
      File.rm_rf(workspace)
    end
  end

  test "github.fetch_origin fetches the scoped origin only" do
    workspace = tmp_workspace!("github-fetch-origin")

    try do
      git_runner = fn
        ["remote", "get-url", "origin"], opts ->
          assert opts[:cd] == workspace
          {"git@github.com:acme/symphony.git\n", 0}

        ["fetch", "origin"], opts ->
          assert opts[:cd] == workspace
          {"fetched\n", 0}
      end

      response =
        DynamicTool.execute(
          "github_fetch_origin",
          %{},
          github_tool_opts(workspace, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"remote" => "origin", "output" => "fetched"} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "legacy dotted github aliases are accepted but not advertised" do
    workspace = tmp_workspace!("github-legacy-alias")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}

        ["remote", "get-url", "origin"], opts ->
          assert opts[:cd] == workspace
          {"git@github.com:acme/symphony.git\n", 0}

        ["remote", "get-url", "--push", "--all", "origin"], opts ->
          assert opts[:cd] == workspace
          {"git@github.com:acme/symphony.git\n", 0}

        ["ls-remote" | _rest], _opts ->
          {"", 0}

        ["push", "origin", "auto/ACME-3051"], opts ->
          assert opts[:cd] == workspace
          {"pushed\n", 0}
      end

      response =
        DynamicTool.execute(
          "github.push_branch",
          %{},
          github_tool_opts(workspace, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"remote" => "origin", "branch" => "auto/ACME-3051"} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_pull_request resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-get-pr")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => "https://github.com/acme/symphony/pull/3051",
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}
      end

      response =
        DynamicTool.execute(
          "github_get_pull_request",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true

      assert %{
               "url" => "https://github.com/acme/symphony/pull/3051",
               "headRefName" => "auto/ACME-3051",
               "baseRefName" => "main"
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_pull_request uses captured remote metadata without local workspace access" do
    remote_workspace = "/remote/workspaces/MT-3187"

    gh_runner = fn
      ["pr", "view", "auto/ACME-3187", "--repo", "acme/symphony", "--json", fields], opts ->
        refute Keyword.has_key?(opts, :cd)
        assert fields == "number,state,title,body,url,headRefName,baseRefName"

        {Jason.encode!(%{
           "number" => 3187,
           "state" => "OPEN",
           "title" => "Remote PR",
           "body" => "Body",
           "url" => "https://github.com/acme/symphony/pull/3187",
           "headRefName" => "auto/ACME-3187",
           "baseRefName" => "main"
         }), 0}
    end

    git_runner = fn _args, _opts -> flunk("remote dynamic GitHub tools should not run local git") end

    response =
      DynamicTool.execute(
        "github_get_pull_request",
        %{},
        workspace: remote_workspace,
        command_security: %{
          origin_repo: "acme/symphony",
          origin_url: "git@github.com:acme/symphony.git",
          current_branch: "auto/ACME-3187",
          workspace: remote_workspace,
          worker_host: "worker-01"
        },
        gh_runner: gh_runner,
        git_runner: git_runner
      )

    assert response["success"] == true
    assert %{"url" => "https://github.com/acme/symphony/pull/3187"} = Jason.decode!(response["output"])
  end

  test "github.push_branch returns a clear unsupported error for ssh workers" do
    remote_workspace = "/remote/workspaces/MT-3187"

    response =
      DynamicTool.execute(
        "github_push_branch",
        %{},
        workspace: remote_workspace,
        command_security: %{
          origin_repo: "acme/symphony",
          origin_url: "git@github.com:acme/symphony.git",
          current_branch: "auto/ACME-3187",
          workspace: remote_workspace,
          worker_host: "worker-01"
        }
      )

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "unsupported_for_ssh_worker",
               "message" => message
             }
           } = Jason.decode!(response["output"])

    assert message =~ "github_push_branch is not supported for SSH worker sessions"
  end

  test "github_sync_base reports the merge result and names what it refuses" do
    workspace = tmp_workspace!("github-sync-base")

    try do
      runner = fn scenario ->
        fn
          ["branch", "--show-current"], _opts -> {"auto/ACME-3051\n", 0}
          ["remote", "get-url", "origin"], _opts -> {"git@github.com:acme/symphony.git\n", 0}
          ["fetch", "origin"], _opts -> {"", 0}
          ["ls-remote", "--symref", "origin", "HEAD"], _opts -> {"ref: refs/heads/main\tHEAD\n", 0}
          ["ls-remote" | _rest], _opts -> remote_heads(scenario)
          ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], _opts -> merge_head_status(scenario)
          ["rev-parse", "HEAD"], _opts -> {"abc123\n", 0}
          ["ls-tree" | _rest], _opts -> {"", 0}
          ["diff", "--name-only", "--no-renames" | _rest], _opts -> protected_diff(scenario)
          ["diff", "--name-only", "--diff-filter=U"], _opts -> {"", 0}
          ["-c" | _rest], _opts -> merge_status(scenario)
        end
      end

      sync = fn scenario ->
        response = DynamicTool.execute("github_sync_base", %{}, github_tool_opts(workspace, git_runner: runner.(scenario)))
        {response["success"], Jason.decode!(response["output"])}
      end

      assert {true, %{"status" => "synced", "base" => "origin/main", "head" => "abc123"}} = sync.(:clean)

      assert {false, %{"error" => %{"code" => "base_branch_not_found", "base" => "origin/main", "message" => message}}} =
               sync.(:no_base)

      assert message =~ "The origin remote has no branch for origin/main"

      assert {false, %{"error" => %{"code" => "merge_in_progress", "message" => message}}} = sync.(:merging)
      assert message =~ "git commit --no-edit"

      assert {false, %{"error" => %{"code" => "protected_paths_changed", "files" => [".ai/skills/push/SKILL.md"], "message" => message}}} =
               sync.(:protected)

      assert message =~ "changes write-protected files itself: .ai/skills/push/SKILL.md"
      assert message =~ "linear_create_subissue"

      assert {false, %{"error" => %{"code" => "git_merge_failed", "status" => 2, "output" => "local changes would be overwritten", "message" => message}}} =
               sync.(:refused)

      assert message =~ "left no merge in progress"
    after
      File.rm_rf(workspace)
    end
  end

  test "github.sync_base returns a clear unsupported error for ssh workers" do
    response =
      DynamicTool.execute(
        "github.sync_base",
        %{},
        workspace: "/remote/workspaces/MT-3187",
        command_security: %{origin_repo: "acme/symphony", origin_url: "git@github.com:acme/symphony.git", worker_host: "worker-01"}
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => "unsupported_for_ssh_worker", "message" => message}} = Jason.decode!(response["output"])
    assert message =~ "github_sync_base is not supported for SSH worker sessions"
  end

  test "github.fetch_origin returns a clear unsupported error for ssh workers" do
    remote_workspace = "/remote/workspaces/MT-3187"

    response =
      DynamicTool.execute(
        "github_fetch_origin",
        %{},
        workspace: remote_workspace,
        command_security: %{
          origin_repo: "acme/symphony",
          origin_url: "git@github.com:acme/symphony.git",
          current_branch: "auto/ACME-3187",
          workspace: remote_workspace,
          worker_host: "worker-01"
        }
      )

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "unsupported_for_ssh_worker",
               "message" => message
             }
           } = Jason.decode!(response["output"])

    assert message =~ "github_fetch_origin is not supported for SSH worker sessions"
  end

  test "github.update_pull_request_body resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-update-pr-body")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Old body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "edit", ^pr_url, "--body", "New body"], opts ->
          assert opts[:cd] == workspace
          {"", 0}
      end

      response =
        DynamicTool.execute(
          "github_update_pull_request_body",
          %{"body" => "New body"},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"url" => ^pr_url} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.add_pr_comment resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-add-pr-comment")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "comment", ^pr_url, "--body", "Validation passed\n\n<!-- symphony:agent -->"], opts ->
          assert opts[:cd] == workspace
          {"", 0}
      end

      response =
        DynamicTool.execute(
          "github_add_pr_comment",
          %{"body" => "Validation passed"},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"url" => ^pr_url} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.reply_to_review_comment posts under the named inline thread" do
    workspace = tmp_workspace!("github-reply-review-comment")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], opts ->
          assert opts[:cd] == workspace

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["api", "repos/acme/symphony/pulls/3051/comments/123/replies", "-f", "body=Acked.\n\n<!-- symphony:agent -->"], opts ->
          assert opts[:cd] == workspace
          {Jason.encode!(%{"id" => 4242, "html_url" => "#{pr_url}#discussion_r4242"}), 0}
      end

      response =
        DynamicTool.execute(
          "github_reply_to_review_comment",
          %{"comment_id" => 123, "body" => "Acked."},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true

      assert %{
               "pr_url" => ^pr_url,
               "comment_id" => "123",
               "reply_id" => 4242,
               "url" => reply_url
             } = Jason.decode!(response["output"])

      assert reply_url == "#{pr_url}#discussion_r4242"
    after
      File.rm_rf(workspace)
    end
  end

  test "github.reply_to_review_comment surfaces invalid_comment_id without contacting gh" do
    workspace = tmp_workspace!("github-reply-review-comment-invalid-id")

    try do
      gh_runner = fn _args, _opts -> flunk("gh should not run for invalid comment ids") end
      git_runner = fn _args, _opts -> flunk("git should not run for invalid comment ids") end

      for bad <- ["", "   ", "abc", 0] do
        response =
          DynamicTool.execute(
            "github_reply_to_review_comment",
            %{"comment_id" => bad, "body" => "Acked."},
            github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
          )

        assert response["success"] == false
        assert %{"error" => %{"code" => "invalid_comment_id"}} = Jason.decode!(response["output"])
      end
    after
      File.rm_rf(workspace)
    end
  end

  test "github.reply_to_review_comment surfaces invalid_body without contacting gh" do
    workspace = tmp_workspace!("github-reply-review-comment-invalid-body")

    try do
      gh_runner = fn _args, _opts -> flunk("gh should not run for invalid body") end
      git_runner = fn _args, _opts -> flunk("git should not run for invalid body") end

      response =
        DynamicTool.execute(
          "github_reply_to_review_comment",
          %{"comment_id" => 123, "body" => nil},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == false
      assert %{"error" => %{"code" => "invalid_body"}} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "legacy github.reply_to_review_comment dotted alias dispatches the new tool" do
    workspace = tmp_workspace!("github-reply-review-comment-legacy-alias")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], _opts -> {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["api", "repos/acme/symphony/pulls/3051/comments/123/replies", "-f", "body=Hi\n\n<!-- symphony:agent -->"], _opts ->
          {Jason.encode!(%{"id" => 4242, "html_url" => "#{pr_url}#discussion_r4242"}), 0}
      end

      response =
        DynamicTool.execute(
          "github.reply_to_review_comment",
          %{"comment_id" => 123, "body" => "Hi"},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"reply_id" => 4242} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_pr_checks resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-get-pr-checks")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "view", ^pr_url, "--json", "id,number,state,title,url,headRefName,headRefOid,baseRefName,isCrossRepository,headRepository,mergeable,mergeStateStatus,autoMergeRequest,statusCheckRollup"],
        opts ->
          assert opts[:cd] == workspace

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "url" => pr_url,
             "headRefOid" => "abc123",
             "statusCheckRollup" => [
               %{
                 "__typename" => "CheckRun",
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "SUCCESS",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/1"
               }
             ]
           }), 0}

        ["api", "repos/acme/symphony/actions/runs?head_sha=abc123&per_page=100"], opts ->
          assert opts[:cd] == workspace
          {Jason.encode!(%{"workflow_runs" => [%{"id" => 1, "status" => "completed", "conclusion" => "success"}]}), 0}
      end

      response =
        DynamicTool.execute(
          "github_get_pr_checks",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true

      assert %{
               "pr_url" => ^pr_url,
               "commit_sha" => "abc123",
               "checks" => [%{"name" => "mix test", "conclusion" => "SUCCESS"}],
               "workflow_runs" => [%{"id" => "1", "status" => "COMPLETED"}]
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github feedback read tools resolve the current branch PR server-side" do
    workspace = tmp_workspace!("github-feedback-read-tools")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], opts ->
          assert opts[:cd] == workspace

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["api", "--paginate", "--slurp", "repos/acme/symphony/issues/3051/comments"], opts ->
          assert opts[:cd] == workspace
          {Jason.encode!([[github_issue_comment(pr_url)]]), 0}

        ["api", "--paginate", "--slurp", "repos/acme/symphony/pulls/3051/comments"], opts ->
          assert opts[:cd] == workspace
          {Jason.encode!([[github_review_comment(pr_url)]]), 0}

        ["api", "--paginate", "--slurp", "repos/acme/symphony/pulls/3051/reviews"], opts ->
          assert opts[:cd] == workspace
          {Jason.encode!([[github_review_summary(pr_url)]]), 0}
      end

      comments =
        DynamicTool.execute(
          "github_list_pr_comments",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      review_comments =
        DynamicTool.execute(
          "github_list_pr_review_comments",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      reviews =
        DynamicTool.execute(
          "github_list_pr_reviews",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert comments["success"] == true
      assert %{"comments" => [%{"body" => "Top-level note."}]} = Jason.decode!(comments["output"])

      assert review_comments["success"] == true

      assert %{"comments" => [%{"path" => "lib/example.ex", "position" => 8, "review_id" => "987"}]} =
               Jason.decode!(review_comments["output"])

      assert reviews["success"] == true
      assert %{"reviews" => [%{"state" => "APPROVED", "author" => "reviewer"}]} = Jason.decode!(reviews["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_failed_run_log returns a configured length-clamped excerpt" do
    workspace = tmp_workspace!("github-failed-run-log")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "view", ^pr_url, "--json", "id,number,state,title,url,headRefName,headRefOid,baseRefName,isCrossRepository,headRepository,mergeable,mergeStateStatus,autoMergeRequest,statusCheckRollup"],
        _opts ->
          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "url" => pr_url,
             "headRefOid" => "abc123",
             "statusCheckRollup" => [
               %{
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "FAILURE",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/987/jobs/654"
               }
             ]
           }), 0}

        ["run", "view", "987", "--log-failed"], _opts ->
          {"0123456789abcdef", 0}
      end

      settings = %Schema{github: %Schema.GitHub{failed_run_log_max_bytes: 10}}

      response =
        DynamicTool.execute(
          "github_get_failed_run_log",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner, settings: settings)
        )

      assert response["success"] == true

      assert %{"run_id" => "987", "log" => "0123456789", "truncated" => true, "max_bytes" => 10} =
               Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_failed_run_log surfaces no failed run cleanly" do
    workspace = tmp_workspace!("github-no-failed-run-log")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], _opts -> {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["pr", "view", ^pr_url, "--json", "id,number,state,title,url,headRefName,headRefOid,baseRefName,isCrossRepository,headRepository,mergeable,mergeStateStatus,autoMergeRequest,statusCheckRollup"],
        _opts ->
          {Jason.encode!(%{
             "url" => pr_url,
             "statusCheckRollup" => [
               %{
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "SUCCESS",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/987/jobs/654"
               }
             ]
           }), 0}
      end

      response =
        DynamicTool.execute(
          "github_get_failed_run_log",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == false
      assert %{"error" => %{"code" => "no_failed_github_actions_run"}} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  defp tmp_workspace!(name) do
    workspace = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    workspace
  end

  defp successful_attach_file_opts(workspace, test_pid) do
    [
      issue: %Issue{id: "issue-current"},
      workspace: workspace,
      linear_client: fn query, variables, _opts ->
        cond do
          query =~ "SymphonyAgentFileUpload" ->
            send(test_pid, {:file_upload_requested, variables})

            {:ok,
             %{
               "data" => %{
                 "fileUpload" => %{
                   "success" => true,
                   "uploadFile" => %{
                     "uploadUrl" => "https://linear-upload.example",
                     "assetUrl" => "https://linear-asset.example/#{variables.filename}",
                     "headers" => [%{"key" => "x-upload", "value" => "1"}]
                   }
                 }
               }
             }}

          query =~ "SymphonyAgentAttachFile" ->
            send(test_pid, {:attachment_created, variables})

            {:ok,
             %{
               "data" => %{
                 "attachmentCreate" => %{
                   "success" => true,
                   "attachment" => %{"id" => "attachment-id"}
                 }
               }
             }}
        end
      end,
      upload_client: fn upload_url, opts ->
        send(test_pid, {:file_uploaded, upload_url, opts})
        {:ok, %{status: 200, body: ""}}
      end
    ]
  end

  defp merge_tool_opts(workspace, issue_state_name, status_check_rollup, pr_state \\ "OPEN") do
    pr_url = "https://github.com/acme/symphony/pull/3051"

    git_runner = fn ["branch", "--show-current"], _opts -> {"auto/ACME-3051\n", 0} end

    gh_runner = fn
      ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
        {Jason.encode!(%{"state" => pr_state, "title" => "Add tools", "body" => "Body", "url" => pr_url}), 0}

      ["pr", "view", ^pr_url, "--json", _fields], _opts ->
        {Jason.encode!(%{"state" => pr_state, "url" => pr_url, "headRefOid" => "abc123", "statusCheckRollup" => status_check_rollup}), 0}

      ["pr", "merge", ^pr_url, "--squash", "--match-head-commit", "abc123" | _rest], _opts ->
        {"", 0}
    end

    linear_client = fn _query, _variables, _opts ->
      {:ok, %{"data" => %{"issue" => %{"id" => "issue-3051", "state" => %{"name" => issue_state_name}}}}}
    end

    workspace
    |> github_tool_opts(git_runner: git_runner, gh_runner: gh_runner, linear_client: linear_client)
    |> Keyword.put(:issue_id, "issue-3051")
  end

  defp remote_heads(:no_base), do: {"", 0}
  defp remote_heads(_scenario), do: {"def456\trefs/heads/main\n", 0}

  defp merge_head_status(:merging), do: {"fed789\n", 0}
  defp merge_head_status(_scenario), do: {"", 1}

  defp protected_diff(:protected), do: {".ai/skills/push/SKILL.md\n", 0}
  defp protected_diff(_scenario), do: {"", 0}

  defp merge_status(:refused), do: {"local changes would be overwritten", 2}
  defp merge_status(_scenario), do: {"Already up to date.\n", 0}

  defp github_tool_opts(workspace, opts) do
    opts
    |> Keyword.put(:workspace, workspace)
    |> Keyword.put(:command_security, %{
      origin_repo: "acme/symphony",
      origin_url: "git@github.com:acme/symphony.git",
      workspace: workspace
    })
  end

  defp github_issue_comment(pr_url) do
    %{
      "id" => 11,
      "user" => %{"login" => "maintainer"},
      "body" => "Top-level note.",
      "html_url" => "#{pr_url}#issuecomment-11"
    }
  end

  defp github_review_comment(pr_url) do
    %{
      "id" => 22,
      "user" => %{"login" => "reviewer"},
      "body" => "Inline note.",
      "html_url" => "#{pr_url}#discussion_r22",
      "path" => "lib/example.ex",
      "position" => 8,
      "pull_request_review_id" => 987
    }
  end

  defp github_review_summary(pr_url) do
    %{
      "id" => 987,
      "user" => %{"login" => "reviewer"},
      "body" => "Looks good.",
      "html_url" => "#{pr_url}#pullrequestreview-987",
      "state" => "APPROVED"
    }
  end

  defp team_states_issue(states, nil), do: %{"team" => %{"states" => %{"nodes" => states}}}
  defp team_states_issue(states, labels), do: Map.put(team_states_issue(states, nil), "labels", %{"nodes" => labels})

  defp update_state_client(test_pid, states, labels \\ nil) do
    fn query, variables, _opts ->
      send(test_pid, {:linear_client_called, query, variables})

      if query =~ "SymphonyAgentIssueTeamStates" do
        {:ok, %{"data" => %{"issue" => team_states_issue(states, labels)}}}
      else
        {:ok,
         %{
           "data" => %{
             "issueUpdate" => %{
               "success" => true,
               "issue" => %{"id" => variables.id, "state" => %{"id" => variables.stateId}}
             }
           }
         }}
      end
    end
  end
end
