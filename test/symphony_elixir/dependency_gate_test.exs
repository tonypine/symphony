defmodule SymphonyElixir.DependencyGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DependencyAudit
  alias SymphonyElixir.DependencyGate
  alias SymphonyElixir.RunStore

  test "build/3 defaults the audit module and invalid gates allow by default" do
    gate = DependencyGate.build("/tmp/workspace", nil, nil)

    assert gate.audit_module == DependencyAudit
    assert DependencyGate.audit(:not_a_gate) == {:ok, []}

    assert DependencyGate.github_create_pull_request_tool?("github_create_pull_request")
    assert DependencyGate.github_create_pull_request_tool?("github.create_pull_request")
    refute DependencyGate.github_create_pull_request_tool?("github_create_pull_request_comment")
  end

  test "react_to_hold logs a hold that can't be set and continues" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :rate_limited})

    issue = %Issue{
      id: "issue-dependency-gate-failure",
      identifier: "ACME-GATE-FAILURE",
      title: "Dependency gate failure",
      description: "Exercise tracker update failure branch",
      state: "In Progress"
    }

    gate = DependencyGate.build("/tmp/workspace", issue, nil, repo_key: "default")

    assert capture_log(fn ->
             assert :ok = DependencyGate.react_to_hold(gate, [])
           end) =~ "Failed to hold dependency issue issue_id=issue-dependency-gate-failure on a Needs Decision hold"
  end

  test "react_to_hold and react_to_audit_error never move a terminal issue" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "issue-dependency-gate-terminal",
      identifier: "ACME-GATE-TERMINAL",
      title: "Dependency gate terminal",
      state: "In Progress",
      repo_key: "repo-dep-gate"
    }

    RunStore.delete_ticket_state("repo-dep-gate", "issue-dependency-gate-terminal")

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Done"}])
    gate = DependencyGate.build("/tmp/workspace", issue, nil, repo_key: "default")

    assert :ok = DependencyGate.react_to_hold(gate, [])
    assert :ok = DependencyGate.react_to_audit_error(gate, :boom)
    refute_received {:memory_tracker_state_update, "issue-dependency-gate-terminal", _state}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert :ok = DependencyGate.react_to_hold(gate, [])
    assert_received {:memory_tracker_label_added, "issue-dependency-gate-terminal", "Needs Decision"}
    refute_received {:memory_tracker_state_update, "issue-dependency-gate-terminal", _state}

    assert [%{name: "decision requested", details: %{hold: "needs_decision", reason: "dependency_source_requires_approval"}}] =
             RunStore.get_ticket_state("repo-dep-gate", "issue-dependency-gate-terminal").signals
  end

  test "issue_terminal? reads the refreshed state and treats lookup failures as active" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue = %Issue{id: "issue-terminal-check", state: "In Progress"}

    assert DependencyGate.issue_terminal?(issue, fn ["issue-terminal-check"] -> {:ok, [%{issue | state: " done "}]} end)
    refute DependencyGate.issue_terminal?(issue, fn _ids -> {:ok, [issue]} end)
    refute DependencyGate.issue_terminal?(issue, fn _ids -> {:ok, []} end)
    refute DependencyGate.issue_terminal?(issue, fn _ids -> {:error, :rate_limited} end)
    refute DependencyGate.issue_terminal?(nil, fn _ids -> flunk("no lookup without an issue id") end)
  end

  test "workspace_missing? only reports local workspaces that are gone" do
    existing = System.tmp_dir!()
    missing = Path.join(existing, "symphony-missing-#{System.unique_integer([:positive])}")

    refute DependencyGate.workspace_missing?(existing, nil)
    assert DependencyGate.workspace_missing?(missing, nil)
    refute DependencyGate.workspace_missing?(missing, "worker-1")
    refute DependencyGate.workspace_missing?(nil, nil)
  end

  test "react_to_audit_error tolerates missing issue context" do
    gate = DependencyGate.build("/tmp/workspace", nil, nil, repo_key: "default")

    assert :ok = DependencyGate.react_to_audit_error(gate, :boom)
  end
end
