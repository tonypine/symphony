defmodule SymphonyElixir.Linear.AdapterProvisioningTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Adapter

  # Answers the provisioning queries and the create mutations by the operation name in the query,
  # so a test can script each one.
  defmodule FakeClient do
    # Ordered: the longer create-issue operation names come before `SymphonyCreateIssue`, which
    # they also contain.
    @operations [
      {"SymphonyTeams", :teams},
      {"SymphonyWorkflowStatesByName", :workflow_states_by_name},
      {"SymphonyAllWorkflowStates", :workflow_states},
      {"SymphonyAllLabels", :labels},
      {"SymphonyCreateWorkflowState", :create_workflow_state},
      {"SymphonyCreateLabel", :create_label},
      {"SymphonyCreateIssueScope", :create_issue_scope},
      {"SymphonyCreateIssueRelation", :create_issue_relation},
      {"SymphonyCreateIssue", :create_issue},
      {"SymphonyIssueId", :issue_id}
    ]

    def graphql(query, variables) do
      case Enum.find(@operations, fn {operation, _key} -> String.contains?(query, operation) end) do
        {_operation, :create_workflow_state} -> create_workflow_state(query, variables)
        {_operation, :create_issue} -> create_issue(variables)
        {_operation, key} -> result(key, default(key))
        nil -> flunk("unexpected query: #{query}")
      end
    end

    defp create_issue(variables) do
      send(self(), {:create_issue_variables, variables})
      result(:create_issue, default(:create_issue))
    end

    # Answers like Linear: a state created without a color is refused with the 400 Linear sends.
    defp create_workflow_state(query, variables) do
      send(self(), {:create_workflow_state_variables, variables})

      if String.contains?(query, "color: $color") and is_binary(variables[:color]) and variables[:color] != "" do
        result(:create_workflow_state, default(:create_workflow_state))
      else
        {:error, {:linear_api_status, 400, missing_color_body()}}
      end
    end

    defp missing_color_body do
      %{
        "errors" => [
          %{
            "message" => "Variable \"$input\" got invalid value; Field \"WorkflowStateCreateInput.color\" of required type \"String!\" was not provided."
          }
        ]
      }
    end

    defp default(:teams), do: %{"data" => %{"teams" => %{"nodes" => []}}}
    defp default(:workflow_states_by_name), do: %{"data" => %{"workflowStates" => %{"nodes" => []}}}
    defp default(:workflow_states), do: %{"data" => %{"workflowStates" => %{"nodes" => []}}}
    defp default(:labels), do: %{"data" => %{"issueLabels" => %{"nodes" => []}}}
    defp default(:create_workflow_state), do: created_state()
    defp default(:create_label), do: created_label()
    defp default(:create_issue_scope), do: team_scope()
    defp default(:create_issue_relation), do: %{"data" => %{"issueRelationCreate" => %{"success" => true}}}
    defp default(:create_issue), do: created_issue()
    defp default(:issue_id), do: %{"data" => %{"issue" => %{"id" => "blocker-id"}}}

    defp team_scope do
      %{
        "data" => %{
          "team" => %{
            "id" => "t1",
            "states" => %{"nodes" => [%{"id" => "s-todo", "name" => "Todo"}]},
            "projects" => %{"nodes" => [%{"id" => "p1", "name" => "Fix Project"}]}
          }
        }
      }
    end

    defp created_issue do
      %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "i1", "identifier" => "TP-900", "url" => "https://linear.app/acme/issue/TP-900"}
          }
        }
      }
    end

    defp created_state do
      %{"data" => %{"workflowStateCreate" => %{"success" => true, "workflowState" => %{"id" => "s9", "name" => "QA", "team" => %{"id" => "t1", "key" => "TP"}}}}}
    end

    defp created_label do
      %{"data" => %{"issueLabelCreate" => %{"success" => true, "issueLabel" => %{"id" => "l9", "name" => "Blocked", "team" => %{"id" => "t1", "key" => "TP"}}}}}
    end

    def fetch_issues_by_states_with_failures(_states) do
      Process.get({__MODULE__, :issues_with_failures}, {:ok, [], []})
    end

    defp result(key, default), do: Process.get({__MODULE__, key}, {:ok, default})
  end

  @team %{"id" => "t1", "key" => "TP"}
  @teams_response %{"data" => %{"teams" => %{"nodes" => [%{"id" => "t1", "key" => "TP"}]}}}

  setup do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeClient)

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :linear_client_module, previous)
      else
        Application.delete_env(:symphony_elixir, :linear_client_module)
      end
    end)

    :ok
  end

  defp put(key, value), do: Process.put({FakeClient, key}, value)

  defp scope_response(opts \\ []) do
    projects = Keyword.get(opts, :projects, [%{"id" => "p1", "name" => "Fix Project"}])

    %{
      "data" => %{
        "team" => %{
          "id" => "t1",
          "states" => %{"nodes" => [%{"id" => "s-todo", "name" => "Todo"}]},
          "projects" => %{"nodes" => projects}
        }
      }
    }
  end

  describe "workflow_state_exists?/2" do
    defp put_states(nodes), do: put(:workflow_states_by_name, {:ok, %{"data" => %{"workflowStates" => %{"nodes" => nodes}}}})

    test "checks the state exists in every team, by key or id" do
      put_states([%{"team" => %{"id" => "team-uuid", "key" => "TP"}}, %{"team" => %{"id" => "other", "key" => "ENG"}}])

      assert {:ok, true} = Adapter.workflow_state_exists?("QA", ["tp", "OTHER"])
      assert {:ok, true} = Adapter.workflow_state_exists?("QA", [])
      assert {:ok, false} = Adapter.workflow_state_exists?("QA", ["TP", "OPS"])
    end

    test "reports a missing state when no team has it" do
      put_states([])
      assert {:ok, false} = Adapter.workflow_state_exists?("QA", [])
    end

    test "treats a state without a team as not matching any team" do
      put_states([%{"id" => "state-1"}])
      assert {:ok, false} = Adapter.workflow_state_exists?("QA", ["TP"])
    end

    test "returns client errors and malformed responses as errors" do
      put(:workflow_states_by_name, {:error, :unauthorized})
      assert {:error, :unauthorized} = Adapter.workflow_state_exists?("QA", [])

      put(:workflow_states_by_name, {:ok, %{"errors" => [%{"message" => "bad"}]}})
      assert {:error, :workflow_states_unavailable} = Adapter.workflow_state_exists?("QA", [])
    end
  end

  describe "workflow_states/0" do
    test "reads every state with the team it belongs to" do
      put(
        :workflow_states,
        {:ok,
         %{
           "data" => %{
             "workflowStates" => %{
               "nodes" => [
                 %{"id" => "s1", "name" => "QA", "team" => @team},
                 %{"id" => "s2", "name" => "Backlog", "team" => nil}
               ]
             }
           }
         }}
      )

      assert {:ok, [qa, backlog]} = Adapter.workflow_states()
      assert qa == %{id: "s1", name: "QA", team_id: "t1", team_key: "TP"}
      assert backlog == %{id: "s2", name: "Backlog", team_id: nil, team_key: nil}
    end

    test "reports a tracker error and an unusable response" do
      put(:workflow_states, {:error, :timeout})
      assert {:error, :timeout} = Adapter.workflow_states()

      put(:workflow_states, {:ok, %{"data" => %{}}})
      assert {:error, :workflow_states_unavailable} = Adapter.workflow_states()
    end
  end

  describe "labels/0" do
    test "reads every label with its team, workspace-wide ones included" do
      put(
        :labels,
        {:ok,
         %{
           "data" => %{
             "issueLabels" => %{
               "nodes" => [
                 %{"id" => "l1", "name" => "Blocked", "team" => @team},
                 %{"id" => "l2", "name" => "Needs Decision", "team" => nil}
               ]
             }
           }
         }}
      )

      assert {:ok, [blocked, decision]} = Adapter.labels()
      assert blocked == %{id: "l1", name: "Blocked", team_id: "t1", team_key: "TP"}
      assert decision == %{id: "l2", name: "Needs Decision", team_id: nil, team_key: nil}
    end

    test "reports a tracker error and an unusable response" do
      put(:labels, {:error, :timeout})
      assert {:error, :timeout} = Adapter.labels()

      put(:labels, {:ok, %{"data" => %{}}})
      assert {:error, :labels_unavailable} = Adapter.labels()
    end
  end

  describe "create_workflow_state/3" do
    test "resolves the team key to its id and returns the created state" do
      put(:teams, {:ok, @teams_response})

      assert {:ok, state} = Adapter.create_workflow_state("QA", "TP", "#e5b53b")
      assert state == %{id: "s9", name: "QA", team_id: "t1", team_key: "TP"}
    end

    test "resolves a team given by id" do
      put(:teams, {:ok, @teams_response})

      assert {:ok, %{id: "s9"}} = Adapter.create_workflow_state("QA", "t1", "#e5b53b")
    end

    test "reports an unknown team, a failed mutation and an unusable response" do
      put(:teams, {:ok, %{"data" => %{"teams" => %{"nodes" => []}}}})
      assert {:error, {:team_not_found, "TP"}} = Adapter.create_workflow_state("QA", "TP", "#e5b53b")

      put(:teams, {:error, :down})
      assert {:error, :down} = Adapter.create_workflow_state("QA", "TP", "#e5b53b")

      put(:teams, {:ok, %{"data" => %{}}})
      assert {:error, :teams_unavailable} = Adapter.create_workflow_state("QA", "TP", "#e5b53b")

      put(:teams, {:ok, @teams_response})
      put(:create_workflow_state, {:ok, %{"data" => %{"workflowStateCreate" => %{"success" => false}}}})
      assert {:error, :workflow_state_create_failed} = Adapter.create_workflow_state("QA", "TP", "#e5b53b")

      put(:create_workflow_state, {:ok, %{"data" => %{}}})
      assert {:error, :workflow_state_create_failed} = Adapter.create_workflow_state("QA", "TP", "#e5b53b")

      # A success with no state object back is still a failure.
      put(:create_workflow_state, {:ok, %{"data" => %{"workflowStateCreate" => %{"success" => true, "workflowState" => nil}}}})
      assert {:error, :workflow_state_create_failed} = Adapter.create_workflow_state("QA", "TP", "#e5b53b")

      put(:create_workflow_state, {:error, :nope})
      assert {:error, :nope} = Adapter.create_workflow_state("QA", "TP", "#e5b53b")
    end
  end

  describe "StateProvisioning through the adapter" do
    alias SymphonyElixir.{Config, StateProvisioning}

    import ExUnit.CaptureLog

    defp state_node(name), do: %{"id" => "s-#{name}", "name" => name, "team" => @team}

    test "the create mutation sends a non-empty color for every machine state" do
      put(:teams, {:ok, @teams_response})
      settings = Config.settings!()

      assert log = capture_log(fn -> assert :ok = StateProvisioning.provision(settings, ["TP"], tracker: Adapter) end)

      sent =
        for {_key, name} <- StateProvisioning.machine_states(settings) do
          assert_received {:create_workflow_state_variables, %{name: ^name, teamId: "t1", color: color}}
          assert is_binary(color) and String.trim(color) != ""
          name
        end

      assert length(sent) == 5
      assert log =~ "10 created, 0 already present, 0 failed"
    end

    test "creates a missing CI Fix in a team that lacks it, against a Linear that requires the color" do
      put(:teams, {:ok, @teams_response})
      present = ["Code Review", "QA", "Plan Review", "Epic Review"]
      put(:workflow_states, {:ok, %{"data" => %{"workflowStates" => %{"nodes" => Enum.map(present, &state_node/1)}}}})

      labels = Enum.map(StateProvisioning.labels(), &%{"id" => "l-#{&1}", "name" => &1, "team" => @team})
      put(:labels, {:ok, %{"data" => %{"issueLabels" => %{"nodes" => labels}}}})

      settings = Config.settings!()

      assert log = capture_log(fn -> assert :ok = StateProvisioning.provision(settings, ["TP"], tracker: Adapter) end)

      assert_received {:create_workflow_state_variables, %{name: "CI Fix", teamId: "t1", color: "#" <> _hex}}
      refute_received {:create_workflow_state_variables, _variables}
      assert log =~ "Created Linear workflow state \"CI Fix\" in team \"TP\""
      assert log =~ "State provisioning: 1 created, 9 already present, 0 failed"
    end
  end

  describe "create_label/2" do
    test "resolves the team and returns the created label" do
      put(:teams, {:ok, @teams_response})

      assert {:ok, label} = Adapter.create_label("Blocked", "TP")
      assert label == %{id: "l9", name: "Blocked", team_id: "t1", team_key: "TP"}
    end

    test "reports a failed mutation and an unusable response" do
      put(:teams, {:ok, @teams_response})
      put(:create_label, {:ok, %{"data" => %{"issueLabelCreate" => %{"success" => false}}}})
      assert {:error, :label_create_failed} = Adapter.create_label("Blocked", "TP")

      put(:create_label, {:ok, %{"data" => %{}}})
      assert {:error, :label_create_failed} = Adapter.create_label("Blocked", "TP")

      # A success with no label object back is still a failure.
      put(:create_label, {:ok, %{"data" => %{"issueLabelCreate" => %{"success" => true, "issueLabel" => nil}}}})
      assert {:error, :label_create_failed} = Adapter.create_label("Blocked", "TP")

      put(:create_label, {:error, :nope})
      assert {:error, :nope} = Adapter.create_label("Blocked", "TP")
    end
  end

  describe "create_issue/1" do
    test "resolves the team, its Todo state and its project, and returns the created issue" do
      put(:teams, {:ok, @teams_response})

      assert {:ok, %{id: "i1", identifier: "TP-900", url: "https://linear.app/acme/issue/TP-900"}} =
               Adapter.create_issue(%{title: "Self-heal: repair the qa_environment block", description: "the evidence", priority: 2, team: "TP", project: "Fix Project"})
    end

    test "assigns the issue to the given user" do
      put(:teams, {:ok, @teams_response})

      assert {:ok, %{identifier: "TP-900"}} = Adapter.create_issue(%{title: "A fix ticket", team: "TP", assignee_id: "user-1"})
      assert_received {:create_issue_variables, %{input: %{"assigneeId" => "user-1"}}}
    end

    test "defaults to Todo, and drops a priority, project or assignee that is not given" do
      put(:teams, {:ok, @teams_response})

      assert {:ok, %{identifier: "TP-900"}} = Adapter.create_issue(%{title: "A fix ticket", team: "TP", assignee_id: " "})
      assert_received {:create_issue_variables, %{input: input}}
      assert input == %{"teamId" => "t1", "stateId" => "s-todo", "title" => "A fix ticket", "description" => ""}

      assert {:error, :invalid_issue_title} = Adapter.create_issue(%{title: "  ", team: "TP"})
      assert {:error, :invalid_issue_description} = Adapter.create_issue(%{title: "A fix ticket", description: nil, team: "TP"})
      assert {:error, :invalid_issue_priority} = Adapter.create_issue(%{title: "A fix ticket", priority: 9, team: "TP"})
      assert {:error, :invalid_issue_team} = Adapter.create_issue(%{title: "A fix ticket", team: ""})
      assert {:error, :invalid_issue_state} = Adapter.create_issue(%{title: "A fix ticket", team: "TP", state: "  "})
      assert {:error, :invalid_issue_create} = Adapter.create_issue("not a map")
    end

    test "reports an unknown team or state, and a mutation that did not succeed" do
      put(:teams, {:ok, @teams_response})
      put(:create_issue_scope, {:ok, %{"data" => %{"team" => %{"id" => "t1", "states" => %{"nodes" => []}, "projects" => %{"nodes" => []}}}}})
      assert {:error, {:state_not_found, "Todo"}} = Adapter.create_issue(%{title: "A fix ticket", team: "TP"})

      put(:create_issue_scope, {:ok, scope_response()})

      put(:create_issue_scope, {:ok, scope_response(projects: [])})
      assert {:error, {:project_not_found, "Fix Project"}} = Adapter.create_issue(%{title: "A fix ticket", team: "TP", project: "Fix Project"})

      put(:create_issue_scope, {:ok, scope_response()})
      put(:create_issue, {:ok, %{"data" => %{"issueCreate" => %{"success" => false}}}})
      assert {:error, :issue_create_failed} = Adapter.create_issue(%{title: "A fix ticket", team: "TP"})

      put(:create_issue, {:ok, %{"data" => %{}}})
      assert {:error, :issue_create_failed} = Adapter.create_issue(%{title: "A fix ticket", team: "TP"})

      put(:create_issue, {:error, :rate_limited})
      assert {:error, :rate_limited} = Adapter.create_issue(%{title: "A fix ticket", team: "TP"})
    end

    test "reports a team whose scope could not be read" do
      put(:teams, {:ok, @teams_response})
      put(:create_issue_scope, {:ok, %{"data" => %{"team" => nil}}})
      assert {:error, :team_not_found} = Adapter.create_issue(%{title: "A fix ticket", team: "TP"})

      put(:create_issue_scope, {:error, :rate_limited})
      assert {:error, :rate_limited} = Adapter.create_issue(%{title: "A fix ticket", team: "TP"})
    end
  end

  describe "add_blocked_by/2" do
    test "resolves the blocker's id and records that it blocks the affected issue" do
      assert :ok = Adapter.add_blocked_by("TP-900", "affected-id")
    end

    test "reports a relation that did not succeed, an unknown blocker and invalid arguments" do
      put(:create_issue_relation, {:ok, %{"data" => %{"issueRelationCreate" => %{"success" => false}}}})
      assert {:error, :issue_relation_failed} = Adapter.add_blocked_by("TP-900", "affected-id")

      put(:create_issue_relation, {:error, :rate_limited})
      assert {:error, :rate_limited} = Adapter.add_blocked_by("TP-900", "affected-id")

      put(:issue_id, {:error, :rate_limited})
      assert {:error, :rate_limited} = Adapter.add_blocked_by("TP-900", "affected-id")

      put(:issue_id, {:ok, %{"data" => %{"issue" => nil}}})
      assert {:error, {:issue_not_found, "TP-900"}} = Adapter.add_blocked_by("TP-900", "affected-id")

      assert {:error, :invalid_blocked_by} = Adapter.add_blocked_by(nil, "affected-id")
      assert {:error, :invalid_blocked_by} = Adapter.add_blocked_by("TP-900", nil)
    end
  end

  describe "fetch_issues_by_states_with_failures/1" do
    test "hands the client's issues and per-repo failures straight back" do
      put(:issues_with_failures, {:ok, [%{id: "issue-1"}], [{"repo-x", :boom}]})

      assert {:ok, [%{id: "issue-1"}], [{"repo-x", :boom}]} =
               Adapter.fetch_issues_by_states_with_failures(["Todo"])
    end
  end
end
