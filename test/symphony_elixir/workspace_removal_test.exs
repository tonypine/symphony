defmodule SymphonyElixir.WorkspaceRemovalTest do
  # Removing a workspace is an allow list (TP-1648): one place decides every removal, and a reason
  # outside the list is refused with nothing removed and nothing recorded.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketEvents, WorkspaceRemoval}

  defmodule FakeWorkspace do
    def remove_issue_workspaces_checked(issue) do
      send(self(), {:remove_issue_workspaces, issue.identifier})
      :ok
    end

    def remove(path, worker_host) do
      send(self(), {:remove_path, path, worker_host})
      {:ok, [path]}
    end
  end

  @refused [:stop, :cleanup, :reclaim, true, false, nil, "terminal"]

  setup do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-workspace-removal-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(workspace_root) end)
    %{workspace_root: workspace_root}
  end

  test "the allow list holds the ticket's end, Start over and the age collector's two sweeps" do
    assert WorkspaceRemoval.reasons() == [:terminal, :restart, :age_gc, :orphan]
    assert Enum.all?(WorkspaceRemoval.reasons(), &(WorkspaceRemoval.check(&1) == :ok))

    # The former stop reason, a boolean a caller might pass and any other value are refused.
    for reason <- @refused do
      assert {:error, {:removal_not_allowed, ^reason}} = WorkspaceRemoval.check(reason)
    end
  end

  test "a refused reason removes nothing and records nothing", %{workspace_root: root} do
    workspace = Path.join([root, "default", "MT-KEEP"])
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "uncommitted.txt"), "keep me\n")
    issue = %{id: "issue-keep", identifier: "MT-KEEP", repo_key: "default"}
    missing_server = Module.concat(__MODULE__, MissingServer)

    log =
      capture_log(fn ->
        for reason <- @refused do
          assert {:error, {:removal_not_allowed, ^reason}} = WorkspaceRemoval.remove(issue, nil, reason, missing_server)
          assert {:error, {:removal_not_allowed, ^reason}} = WorkspaceRemoval.remove_now(issue, reason, FakeWorkspace)

          assert {:error, {:removal_not_allowed, ^reason}} =
                   WorkspaceRemoval.remove_path(workspace, nil, reason, FakeWorkspace)
        end
      end)

    assert log =~ "Refused to remove the workspace of MT-KEEP: :stop is not a removal reason; keeping it"
    assert File.read!(Path.join(workspace, "uncommitted.txt")) == "keep me\n"
    refute_received {:remove_issue_workspaces, _identifier}
    refute_received {:remove_path, _path, _worker_host}
    assert TicketEvents.query("issue-keep", types: ["workspace.removed"]) == []
  end

  test "an allowed reason removes the workspace and records why on the ticket", %{workspace_root: root} do
    workspace = Path.join([root, "default", "MT-DONE"])
    File.mkdir_p!(workspace)
    issue = %{id: "issue-done", identifier: "MT-DONE", repo_key: "default", state: "Done"}

    # Without the cleanup server the removal runs inline, so it is done when the call returns.
    assert :ok = WorkspaceRemoval.remove(issue, nil, :terminal, Module.concat(__MODULE__, MissingServer))
    refute File.exists?(workspace)
    assert [%{payload: %{reason: "terminal"}}] = TicketEvents.query("issue-done", types: ["workspace.removed"])

    assert :ok = WorkspaceRemoval.remove_now(issue, :restart, FakeWorkspace)
    assert_received {:remove_issue_workspaces, "MT-DONE"}

    assert {:ok, [^workspace]} = WorkspaceRemoval.remove_path(workspace, "worker-01", :terminal, FakeWorkspace)
    assert_received {:remove_path, ^workspace, "worker-01"}
  end

  test "a workspace's ticket is ended, missing, open or unknown, and only the first two are removable" do
    issues = %{
      "MT-DONE" => {:ok, %{state: " done "}},
      "MT-OPEN" => {:ok, %{state: "In Progress"}},
      "MT-NO-STATE" => {:ok, %{state: nil}},
      "MT-GONE" => {:error, :issue_not_found},
      "MT-DOWN" => {:error, :linear_unavailable}
    }

    fetch = fn
      "MT-RAISE" -> raise "tracker down"
      identifier -> Map.fetch!(issues, identifier)
    end

    opts = [fetch: fetch, terminal_states: ["Done", "Canceled"]]

    assert WorkspaceRemoval.ticket_status("MT-DONE", opts) == :ended
    assert WorkspaceRemoval.ticket_status("MT-OPEN", opts) == :open
    assert WorkspaceRemoval.ticket_status("MT-NO-STATE", opts) == :open
    assert WorkspaceRemoval.ticket_status("MT-GONE", opts) == :missing
    assert WorkspaceRemoval.ticket_status("MT-DOWN", opts) == :unknown

    log = capture_log(fn -> assert WorkspaceRemoval.ticket_status("MT-RAISE", opts) == :unknown end)
    assert log =~ "Couldn't read the ticket of workspace MT-RAISE: tracker down; keeping the workspace"

    assert WorkspaceRemoval.removable_ticket?("MT-DONE", opts)
    assert WorkspaceRemoval.removable_ticket?("MT-GONE", opts)
    refute WorkspaceRemoval.removable_ticket?("MT-OPEN", opts)
    refute WorkspaceRemoval.removable_ticket?("MT-DOWN", opts)
  end

  test "without options the ticket is read from the tracker against the workflow's terminal states" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%Issue{id: "issue-canceled", identifier: "MT-CANCELED", state: "Canceled"}])
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

    assert WorkspaceRemoval.ticket_status("MT-CANCELED") == :ended
    assert WorkspaceRemoval.ticket_status("MT-NOWHERE") == :missing
    assert WorkspaceRemoval.removable_ticket?("MT-CANCELED")
  end

  test "ended_state? compares trimmed and case-insensitively, and a missing state never ended" do
    assert WorkspaceRemoval.ended_state?("CANCELED ", ["Done", "Canceled"])
    refute WorkspaceRemoval.ended_state?("Merging", ["Done", "Canceled"])
    refute WorkspaceRemoval.ended_state?(nil, ["Done"])
  end
end
