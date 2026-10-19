defmodule SymphonyElixir.Tracker.MemoryProvisioningTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Tracker.Memory

  @keys [
    :memory_tracker_workflow_states,
    :memory_tracker_workflow_states_list,
    :memory_tracker_labels_list,
    :memory_tracker_create_workflow_state_result,
    :memory_tracker_create_label_result,
    :memory_tracker_recipient
  ]

  setup do
    previous = Map.new(@keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    # Other tests share this global env, so start from nothing rather than whatever they left.
    Enum.each(@keys, &Application.delete_env(:symphony_elixir, &1))
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)
    end)

    :ok
  end

  describe "workflow_state_exists?/2" do
    test "assumes every state exists unless states are configured" do
      assert {:ok, true} = Memory.workflow_state_exists?("QA", [])

      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states, ["qa "])
      assert {:ok, true} = Memory.workflow_state_exists?("QA", ["TP"])
      assert {:ok, false} = Memory.workflow_state_exists?("Merging", ["TP"])
    end

    test "returns a configured error" do
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states, {:error, :down})
      assert {:error, :down} = Memory.workflow_state_exists?("QA", [])
    end
  end

  describe "workflow_states/0 and labels/0" do
    test "are empty until a test seeds or creates them" do
      assert {:ok, []} = Memory.workflow_states()
      assert {:ok, []} = Memory.labels()
    end

    test "return the seeded states and labels, and pass on an error" do
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, [%{name: "QA"}])
      Application.put_env(:symphony_elixir, :memory_tracker_labels_list, [%{name: "Blocked"}])

      assert {:ok, [%{name: "QA"}]} = Memory.workflow_states()
      assert {:ok, [%{name: "Blocked"}]} = Memory.labels()

      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, {:error, :down})
      Application.put_env(:symphony_elixir, :memory_tracker_labels_list, {:error, :down})

      assert {:error, :down} = Memory.workflow_states()
      assert {:error, :down} = Memory.labels()
    end
  end

  describe "create_workflow_state/3" do
    test "adds the state to the list, announces it, and keeps the earlier ones" do
      assert {:ok, state} = Memory.create_workflow_state("QA", "TP", "#e5b53b")
      assert state == %{id: "state:TP:QA", name: "QA", team_id: "TP", team_key: "TP", type: "started", position: nil}
      assert_received {:memory_tracker_created_workflow_state, "QA", "TP"}

      assert {:ok, %{type: "completed", position: 4.5}} = Memory.create_workflow_state("Done", "TP", "#5e6ad2", type: "completed", position: 4.5)

      assert {:ok, _} = Memory.create_workflow_state("CI Fix", "TP", "#eb5757")
      assert {:ok, [%{name: "QA"}, %{name: "Done"}, %{name: "CI Fix"}]} = Memory.workflow_states()
    end

    test "passes on a scripted failure" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_workflow_state_result, {:error, :forbidden})

      assert {:error, :forbidden} = Memory.create_workflow_state("QA", "TP", "#e5b53b")
      refute_received {:memory_tracker_created_workflow_state, _, _}
    end
  end

  describe "team_workflow_states/1 and team_labels/1" do
    test "answer one team's states, and its labels with the workspace's, announcing each request" do
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, [
        %{id: "s1", name: "Todo", team_id: "t1", team_key: "TP"},
        %{id: "s2", name: "Todo", team_id: "t2", team_key: "OPS"}
      ])

      Application.put_env(:symphony_elixir, :memory_tracker_labels_list, [
        %{id: "l1", name: "plan", team_id: nil, team_key: nil},
        %{id: "l2", name: "Blocked", team_id: "t1", team_key: "TP"},
        %{id: "l3", name: "Blocked", team_id: "t2", team_key: "OPS"}
      ])

      assert {:ok, [%{id: "s1"}]} = Memory.team_workflow_states("TP")
      assert {:ok, [%{id: "s2"}]} = Memory.team_workflow_states("t2")
      assert {:ok, [%{id: "l1"}, %{id: "l2"}]} = Memory.team_labels("TP")
      assert_received {:memory_tracker_team_workflow_states, "TP"}
      assert_received {:memory_tracker_team_workflow_states, "t2"}
      assert_received {:memory_tracker_team_labels, "TP"}
    end

    test "pass on a configured error" do
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, {:error, :timeout})
      Application.put_env(:symphony_elixir, :memory_tracker_labels_list, {:error, :timeout})

      assert {:error, :timeout} = Memory.team_workflow_states("TP")
      assert {:error, :timeout} = Memory.team_labels("TP")
    end
  end

  describe "create_label/2" do
    test "adds the label to the list, announces it, and keeps the earlier ones" do
      assert {:ok, label} = Memory.create_label("Blocked", "TP")
      assert label == %{id: "label:TP:Blocked", name: "Blocked", team_id: "TP"}
      assert_received {:memory_tracker_created_label, "Blocked", "TP"}

      assert {:ok, _} = Memory.create_label("CI green", "TP")
      assert {:ok, [%{name: "Blocked"}, %{name: "CI green"}]} = Memory.labels()
    end

    test "passes on a scripted failure" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_label_result, {:error, :forbidden})

      assert {:error, :forbidden} = Memory.create_label("Blocked", "TP")
      refute_received {:memory_tracker_created_label, _, _}
    end
  end
end
