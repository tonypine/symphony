defmodule SymphonyElixir.Tracker.MemoryIssuesFileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Memory

  setup do
    Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    issues_file = Path.join(Path.dirname(Workflow.symphony_file_path()), "issues.json")

    File.write!(
      issues_file,
      Jason.encode!([
        %{"id" => "issue-1", "identifier" => "QA-1", "state" => "Todo", "title" => "Seeded", "labels" => ["qa"]},
        %{"id" => "issue-2", "identifier" => "QA-2", "state" => "Todo"}
      ])
    )

    write_workflow_file!(Workflow.workflow_file_path(), tracker_memory_issues_file: "issues.json")
    %{issues_file: issues_file}
  end

  test "a move, a comment and a reply are written into the issues file, and read back as Linear's issue nodes" do
    assert Memory.update_issue_state("issue-1", "In Progress") == :ok
    assert Memory.create_comment("issue-1", "## Decision needed: Pick one") == :ok
    assert [%{"identifier" => "QA-1", "state" => %{"name" => "In Progress"}} = node, _other] = Memory.issue_nodes(%{name: "all"})
    assert [%{"id" => request_id, "parent" => nil}] = node["comments"]["nodes"]
    assert Memory.create_reply("issue-1", request_id, "Stay paused") == :ok

    # The next read sees the move, as Linear's does.
    assert {:ok, %Issue{state: "In Progress"}} = Memory.fetch_issue_by_identifier("QA-1")

    assert [node, other] = Memory.issue_nodes(%{name: "all"})

    assert %{
             "id" => "issue-1",
             "title" => "Seeded",
             "labels" => %{"nodes" => [%{"name" => "qa"}]},
             "comments" => %{"nodes" => [%{"id" => ^request_id, "body" => "## Decision needed: Pick one"}, reply], "pageInfo" => %{"hasPreviousPage" => false}},
             "history" => %{"nodes" => [%{"fromState" => %{"name" => "Todo"}, "toState" => %{"name" => "In Progress"}, "createdAt" => moved_at}]},
             "updatedAt" => updated_at
           } = node

    assert %{"body" => "Stay paused", "parent" => %{"id" => ^request_id}, "createdAt" => replied_at} = reply
    assert {:ok, _at, 0} = DateTime.from_iso8601(moved_at)
    assert {:ok, _at, 0} = DateTime.from_iso8601(replied_at)
    assert {:ok, _at, 0} = DateTime.from_iso8601(updated_at)

    # The other issue is as the file had it.
    assert %{"id" => "issue-2", "updatedAt" => nil, "comments" => %{"nodes" => []}, "history" => %{"nodes" => []}} = other
  end

  test "with issues set in the environment, a move and a comment only report their event", %{issues_file: issues_file} do
    issue = %Issue{id: "issue-1", identifier: "QA-1", state: "Todo", labels: nil}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    before = File.read!(issues_file)

    assert Memory.update_issue_state("issue-1", "Done") == :ok
    assert Memory.create_comment("issue-1", "Hello") == :ok
    assert_received {:memory_tracker_state_update, "issue-1", "Done"}
    assert_received {:memory_tracker_comment, "issue-1", "Hello"}

    assert File.read!(issues_file) == before
    assert [%{"state" => %{"name" => "Todo"}, "labels" => %{"nodes" => []}, "comments" => %{"nodes" => []}}] = Memory.issue_nodes(%{name: "all"})
  end

  test "a memory tracker with no issues file writes nothing" do
    write_workflow_file!(Workflow.workflow_file_path())
    assert Memory.update_issue_state("issue-1", "Done") == :ok
    assert Memory.issue_nodes(%{name: "all"}) == []
  end

  test "a blocked-by link is written into the issues file and read back with the blocker's state", %{issues_file: issues_file} do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    # Through the tracker boundary, as the Director's move writes it; by id or by identifier.
    assert Tracker.add_blocked_by("issue-2", "issue-1") == :ok
    assert Memory.add_blocked_by("QA-2", "issue-1") == :ok
    assert_received {:memory_tracker_blocked_by_added, "issue-2", "issue-1"}
    assert [%{"blockedBy" => ["issue-2"]}, _other] = Jason.decode!(File.read!(issues_file))
    assert {:ok, %Issue{blocked_by: [%{id: "issue-2", identifier: "QA-2", state: "Todo"}]}} = Memory.fetch_issue_by_identifier("QA-1")

    # The blocker's state is read again each time, so a finished blocker reads as finished.
    assert Memory.update_issue_state("issue-2", "Done") == :ok
    assert {:ok, %Issue{blocked_by: [%{state: "Done"}]}} = Memory.fetch_issue_by_identifier("QA-1")

    assert Tracker.remove_blocked_by("issue-2", "issue-1") == :ok
    assert_received {:memory_tracker_blocked_by_removed, "issue-2", "issue-1"}
    assert {:ok, %Issue{blocked_by: []}} = Memory.fetch_issue_by_identifier("QA-1")

    # An unknown blocker, or a scripted failure, writes nothing.
    assert Memory.add_blocked_by("QA-404", "issue-1") == {:error, {:issue_not_found, "QA-404"}}
    Application.put_env(:symphony_elixir, :memory_tracker_add_blocked_by_result, [{:error, :boom}])
    assert Memory.add_blocked_by("issue-2", "issue-1") == {:error, :boom}
    assert {:ok, %Issue{blocked_by: []}} = Memory.fetch_issue_by_identifier("QA-1")
  after
    Application.delete_env(:symphony_elixir, :memory_tracker_add_blocked_by_result)
  end

  test "with issues set in the environment, a blocked-by link edits the issue's blockers there" do
    issues = [
      %Issue{id: "issue-1", identifier: "QA-1", state: "Todo", blocked_by: [%{id: "issue-3", identifier: "QA-3", state: "Done"}]},
      %Issue{id: "issue-2", identifier: "QA-2", state: "In Progress", blocked_by: :unknown}
    ]

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

    assert Memory.add_blocked_by("QA-2", "issue-1") == :ok
    assert {:ok, %Issue{blocked_by: [%{id: "issue-3", state: "Done"}, added]}} = Memory.fetch_issue_by_identifier("QA-1")
    assert added == %{id: "issue-2", identifier: "QA-2", state: "In Progress"}
    assert Memory.add_blocked_by("QA-2", "issue-1") == :ok
    assert {:ok, %Issue{blocked_by: [_three, _two]}} = Memory.fetch_issue_by_identifier("QA-1")

    assert Memory.remove_blocked_by("issue-2", "issue-1") == :ok
    assert {:ok, %Issue{blocked_by: [%{id: "issue-3"}]}} = Memory.fetch_issue_by_identifier("QA-1")

    # A blocker added to an issue whose blockers were never read.
    assert Memory.add_blocked_by("QA-1", "issue-2") == :ok
    assert {:ok, %Issue{blocked_by: [%{id: "issue-1"}]}} = Memory.fetch_issue_by_identifier("QA-2")
  end
end
