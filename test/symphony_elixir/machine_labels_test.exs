defmodule SymphonyElixir.MachineLabelsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{MachineLabels, Tracker, Workflow}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    :ok
  end

  describe "MachineLabels" do
    test "owns the CI labels and the holds, matching case and surrounding space" do
      assert MachineLabels.ci_labels() == ["CI green", "CI red", "CI running"]

      for name <- ["CI green", "ci green", " CI RED ", "Blocked", "needs decision", "CI running"] do
        assert MachineLabels.owned?(name), "expected #{inspect(name)} to be machine-owned"
      end

      for name <- ["bug", "CI", "protected-paths-approved", nil, 42] do
        refute MachineLabels.owned?(name), "expected #{inspect(name)} not to be machine-owned"
      end
    end
  end

  describe "the Tracker guard" do
    test "generic add and remove refuse a machine-owned name without touching the tracker" do
      assert Tracker.add_issue_label("issue-1", "CI green") == {:error, :machine_owned_label}
      assert Tracker.remove_issue_label("issue-1", "ci running") == {:error, :machine_owned_label}
      assert labels() == []
    end

    test "generic add and remove still pass a label the machine does not own" do
      assert :ok = Tracker.add_issue_label("issue-1", "bug")
      assert labels() == ["bug"]
      assert :ok = Tracker.remove_issue_label("issue-1", "BUG")
      assert labels() == []
    end

    test "set and clear a machine label write it, and refuse a name the machine does not own" do
      assert :ok = Tracker.set_machine_label("issue-1", "CI green")
      assert labels() == ["CI green"]

      assert :ok = Tracker.clear_machine_label("issue-1", "CI green")
      assert labels() == []

      assert Tracker.set_machine_label("issue-1", "bug") == {:error, :not_machine_owned_label}
      assert Tracker.clear_machine_label("issue-1", "bug") == {:error, :not_machine_owned_label}
      assert labels() == []
    end

    test "a tracker failure behind a machine label write is passed through" do
      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, {:error, :boom})
      assert Tracker.set_machine_label("issue-1", "CI red") == {:error, :boom}
    end

    test "clearing a machine label on a tracker that has none is a no-op" do
      assert :ok = Tracker.clear_machine_label("issue-1", "CI running")
      assert labels() == []
    end

    test "the facade passes through a states-with-failures read" do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_failed_repos) end)
      Application.put_env(:symphony_elixir, :memory_tracker_failed_repos, [{"repo-x", :boom}])

      assert {:ok, [_issue], [{"repo-x", :boom}]} = Tracker.fetch_issues_by_states_with_failures(["Todo"])
    end
  end

  defp issue do
    %Issue{id: "issue-1", identifier: "MT-1", title: "T", state: "Todo", labels: []}
  end

  defp labels do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == "issue-1"))
    |> Map.fetch!(:labels)
  end
end
