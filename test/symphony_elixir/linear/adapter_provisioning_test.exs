defmodule SymphonyElixir.Linear.AdapterProvisioningTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Adapter

  # Answers the four provisioning queries and two create mutations by the operation name in the
  # query, so a test can script each one.
  defmodule FakeClient do
    def graphql(query, _variables) do
      cond do
        query =~ "SymphonyTeams" -> result(:teams, %{"data" => %{"teams" => %{"nodes" => []}}})
        query =~ "SymphonyAllWorkflowStates" -> result(:workflow_states, %{"data" => %{"workflowStates" => %{"nodes" => []}}})
        query =~ "SymphonyAllLabels" -> result(:labels, %{"data" => %{"issueLabels" => %{"nodes" => []}}})
        query =~ "SymphonyCreateWorkflowState" -> result(:create_workflow_state, created_state())
        query =~ "SymphonyCreateLabel" -> result(:create_label, created_label())
        true -> flunk("unexpected query: #{query}")
      end
    end

    defp created_state do
      %{"data" => %{"workflowStateCreate" => %{"success" => true, "workflowState" => %{"id" => "s9", "name" => "QA", "team" => %{"id" => "t1", "key" => "TP"}}}}}
    end

    defp created_label do
      %{"data" => %{"issueLabelCreate" => %{"success" => true, "issueLabel" => %{"id" => "l9", "name" => "Blocked", "team" => %{"id" => "t1", "key" => "TP"}}}}}
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

  describe "create_workflow_state/2" do
    test "resolves the team key to its id and returns the created state" do
      put(:teams, {:ok, @teams_response})

      assert {:ok, state} = Adapter.create_workflow_state("QA", "TP")
      assert state == %{id: "s9", name: "QA", team_id: "t1", team_key: "TP"}
    end

    test "resolves a team given by id" do
      put(:teams, {:ok, @teams_response})

      assert {:ok, %{id: "s9"}} = Adapter.create_workflow_state("QA", "t1")
    end

    test "reports an unknown team, a failed mutation and an unusable response" do
      put(:teams, {:ok, %{"data" => %{"teams" => %{"nodes" => []}}}})
      assert {:error, {:team_not_found, "TP"}} = Adapter.create_workflow_state("QA", "TP")

      put(:teams, {:error, :down})
      assert {:error, :down} = Adapter.create_workflow_state("QA", "TP")

      put(:teams, {:ok, %{"data" => %{}}})
      assert {:error, :teams_unavailable} = Adapter.create_workflow_state("QA", "TP")

      put(:teams, {:ok, @teams_response})
      put(:create_workflow_state, {:ok, %{"data" => %{"workflowStateCreate" => %{"success" => false}}}})
      assert {:error, :workflow_state_create_failed} = Adapter.create_workflow_state("QA", "TP")

      put(:create_workflow_state, {:ok, %{"data" => %{}}})
      assert {:error, :workflow_state_create_failed} = Adapter.create_workflow_state("QA", "TP")

      # A success with no state object back is still a failure.
      put(:create_workflow_state, {:ok, %{"data" => %{"workflowStateCreate" => %{"success" => true, "workflowState" => nil}}}})
      assert {:error, :workflow_state_create_failed} = Adapter.create_workflow_state("QA", "TP")

      put(:create_workflow_state, {:error, :nope})
      assert {:error, :nope} = Adapter.create_workflow_state("QA", "TP")
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
end
