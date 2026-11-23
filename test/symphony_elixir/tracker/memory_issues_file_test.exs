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

  test "an entry's blockers in the issues file are read back with each blocker's state", %{issues_file: issues_file} do
    issues = Jason.decode!(File.read!(issues_file))
    File.write!(issues_file, Jason.encode!(List.update_at(issues, 0, &Map.put(&1, "blockedBy", ["issue-2"]))))

    assert {:ok, %Issue{blocked_by: [%{id: "issue-2", identifier: "QA-2", state: "Todo"}]}} = Memory.fetch_issue_by_identifier("QA-1")

    # The blocker's state is read again each time, so a finished blocker reads as finished.
    assert Memory.update_issue_state("issue-2", "Done") == :ok
    assert {:ok, %Issue{blocked_by: [%{state: "Done"}]}} = Memory.fetch_issue_by_identifier("QA-1")
  end

  test "a priority is written into the issues file and read back as the issue's priority", %{issues_file: issues_file} do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    assert {:ok, %Issue{priority: nil}} = Memory.fetch_issue_by_identifier("QA-1")

    # Through the tracker boundary, as the Director's move writes it.
    assert Tracker.update_issue_priority("issue-1", 4) == :ok
    assert_received {:memory_tracker_priority_updated, "issue-1", 4}
    assert [%{"priority" => 4}, other] = Jason.decode!(File.read!(issues_file))
    refute Map.has_key?(other, "priority")
    assert {:ok, %Issue{priority: 4}} = Memory.fetch_issue_by_identifier("QA-1")

    # A scripted failure writes nothing.
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_priority_result, [{:error, :boom}])
    assert Memory.update_issue_priority("issue-1", 1) == {:error, :boom}
    assert {:ok, %Issue{priority: 4}} = Memory.fetch_issue_by_identifier("QA-1")
  after
    Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_priority_result)
  end

  test "a scripted plan-comments error is answered as it is" do
    Application.put_env(:symphony_elixir, :memory_tracker_plan_comments, {:error, :boom})
    assert Memory.fetch_plan_comments("issue-1") == {:error, :boom}
  after
    Application.delete_env(:symphony_elixir, :memory_tracker_plan_comments)
  end

  test "with issues set in the environment, a priority edits the issue there" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "issue-1", identifier: "QA-1", state: "Todo", priority: 4},
      %Issue{id: "issue-2", identifier: "QA-2", state: "Todo", priority: 3}
    ])

    assert Memory.update_issue_priority("issue-1", 1) == :ok
    assert {:ok, %Issue{priority: 1}} = Memory.fetch_issue_by_identifier("QA-1")
    assert {:ok, %Issue{priority: 3}} = Memory.fetch_issue_by_identifier("QA-2")
  end

  describe "create_issue/1 and add_related/2" do
    setup do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      on_exit(fn ->
        keys = [:memory_tracker_recipient, :memory_tracker_create_issue_result, :memory_tracker_add_related_result]
        for key <- [:memory_tracker_issues | keys], do: Application.delete_env(:symphony_elixir, key)
      end)
    end

    test "an issue created in the issues file is read back, under its parent with the parent's team and project", %{issues_file: issues_file} do
      entries = issues_file |> File.read!() |> Jason.decode!()
      parent = entries |> hd() |> Map.merge(%{"team" => %{"key" => "QA", "name" => "QA"}, "project" => %{"id" => "p1", "name" => "App", "slug_id" => "app"}})
      File.write!(issues_file, Jason.encode!([parent | tl(entries)]))

      attrs = %{title: "A sub-ticket", description: "Build the list.", priority: 1, team: "QA", parent_id: "issue-1"}
      assert {:ok, %{id: "memory-issue-3", identifier: "QA-9003", url: nil} = created} = Tracker.create_issue(attrs)
      assert_received {:memory_tracker_issue_created, "memory-issue-3", ^attrs}

      assert {:ok, %Issue{} = child} = Memory.fetch_issue_by_identifier(created.identifier)
      assert %{title: "A sub-ticket", description: "Build the list.", state: "Todo", priority: 1, team: %{key: "QA"}, project: %{slug_id: "app"}} = child
      assert %{identifier: "QA-1"} = child.parent
      assert {:ok, %Issue{sub_issues: [%{id: "memory-issue-3", identifier: "QA-9003", state: "Todo"}]}} = Memory.fetch_issue_by_identifier("QA-1")

      # One with no parent, or a parent the file does not hold, stands alone.
      assert {:ok, %{identifier: "MEM-9004"}} = Memory.create_issue(%{title: "Alone", state: "Backlog", parent_id: "gone"})
      assert {:ok, %Issue{state: "Backlog", parent: nil, team: nil}} = Memory.fetch_issue_by_identifier("MEM-9004")
    end

    test "an issue created among `:memory_tracker_issues` joins them, and its parent lists it" do
      parent = %Issue{id: "parent", identifier: "MT-1", title: "Parent", state: "Todo", team: %{key: "MT"}, project: %{id: "p1", name: "App"}}
      unread = %Issue{id: "unread", identifier: "MT-2", state: "Todo", sub_issues: :unknown}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [parent, unread])

      assert {:ok, %{id: "memory-issue-3", identifier: "MT-9003"}} =
               Memory.create_issue(%{title: "Child", description: "Do it.", team: "MT", priority: 1, assignee_id: "user-1", parent_id: "parent"})

      assert {:ok, [listing, %Issue{sub_issues: :unknown}, child]} = Memory.fetch_issue_states_by_ids(["parent", "unread", "memory-issue-3"])
      assert listing.sub_issues == [%{id: "memory-issue-3", identifier: "MT-9003", state: "Todo"}]

      assert %Issue{title: "Child", description: "Do it.", state: "Todo", priority: 1, assignee_id: "user-1"} = child
      assert %Issue{team: %{key: "MT"}, project: %{id: "p1"}} = child
      assert child.parent == %{identifier: "MT-1", title: "Parent"}

      assert {:ok, %{identifier: "MEM-9004"}} = Memory.create_issue(%{title: "Alone"})
      assert {:ok, %Issue{parent: nil}} = Memory.fetch_issue_by_identifier("MEM-9004")
    end

    test "a scripted failure creates nothing, and an issue needs a title" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_issue_result, [{:error, :linear_down}])
      assert {:error, :linear_down} = Memory.create_issue(%{title: "Child"})
      assert {:ok, %{id: "memory-issue-3"}} = Memory.create_issue(%{title: "Child"})
      assert {:error, :invalid_issue_create} = Memory.create_issue(%{description: "No title"})
    end

    test "a related link reports its event" do
      assert :ok = Tracker.add_related("QA-2", "issue-1")
      assert_received {:memory_tracker_related_added, "QA-2", "issue-1"}

      Application.put_env(:symphony_elixir, :memory_tracker_add_related_result, {:error, :linear_down})
      assert {:error, :linear_down} = Memory.add_related("QA-2", "issue-1")
    end
  end
end
