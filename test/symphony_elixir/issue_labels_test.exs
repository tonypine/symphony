defmodule SymphonyElixir.IssueLabelsTest do
  # Adding and removing a label on a ticket, through the Linear adapter and the memory tracker
  # (director labels, grooming and self-heal edit labels this way).
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  defmodule FakeLinearClient do
    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})
      [result | rest] = Process.get({__MODULE__, :graphql_results})
      Process.put({__MODULE__, :graphql_results}, rest)
      result
    end
  end

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-issue-labels-#{System.unique_integer([:positive])}")
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:symphony_elixir, :linear_client_module, previous_client),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)

      File.rm_rf(test_root)
    end)

    %{test_root: test_root}
  end

  describe "Linear adapter labels" do
    setup do
      Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
      :ok
    end

    test "adds the team label, else the workspace label, and only when the issue lacks it" do
      labels = [label("workspace-label", nil), label("other-team-label", "team-2"), label("team-label", "team-1")]

      script([lookup([], labels), {:ok, %{"data" => %{"issueAddLabel" => %{"success" => true}}}}])
      assert :ok = Adapter.add_issue_label("issue-1", "Reviewed")
      assert_received {:graphql_called, lookup_query, %{issueId: "issue-1", labelName: "Reviewed"}}
      assert lookup_query =~ "eqIgnoreCase"
      assert_received {:graphql_called, add_query, %{issueId: "issue-1", labelId: "team-label"}}
      assert add_query =~ "issueAddLabel"

      script([lookup([], [label("workspace-label", nil)]), {:ok, %{"data" => %{"issueAddLabel" => %{"success" => true}}}}])
      assert :ok = Adapter.add_issue_label("issue-1", "reviewed")
      assert_received {:graphql_called, _lookup, _variables}
      assert_received {:graphql_called, _add, %{labelId: "workspace-label"}}

      script([lookup(["on-issue"], labels)])
      assert :ok = Adapter.add_issue_label("issue-1", "reviewed")
      assert_received {:graphql_called, _lookup, _variables}
      refute_received {:graphql_called, _add, _variables}

      script([lookup([], [label("other-team-label", "team-2")])])
      assert {:error, {:label_not_found, "reviewed"}} = Adapter.add_issue_label("issue-1", "reviewed")

      script([lookup([], labels), {:ok, %{"data" => %{"issueAddLabel" => %{"success" => false}}}}])
      assert {:error, :issue_label_update_failed} = Adapter.add_issue_label("issue-1", "reviewed")

      script([lookup([], labels), {:error, :boom}])
      assert {:error, :boom} = Adapter.add_issue_label("issue-1", "reviewed")

      script([{:error, {:linear_rate_limited, 1}}])
      assert {:error, {:linear_rate_limited, 1}} = Adapter.add_issue_label("issue-1", "reviewed")

      script([{:ok, %{"errors" => [%{"message" => "Entity not found: Issue"}], "data" => nil}}])
      assert {:error, :issue_label_lookup_failed} = Adapter.add_issue_label("issue-1", "reviewed")
    end

    test "removes every matching label on the issue and stops at the first failure" do
      removed = {:ok, %{"data" => %{"issueRemoveLabel" => %{"success" => true}}}}

      script([lookup(["label-a", "label-b"], []), removed, removed])
      assert :ok = Adapter.remove_issue_label("issue-1", "reviewed")
      assert_received {:graphql_called, _lookup, _variables}
      assert_received {:graphql_called, remove_query, %{issueId: "issue-1", labelId: "label-a"}}
      assert remove_query =~ "issueRemoveLabel"
      assert_received {:graphql_called, _remove, %{labelId: "label-b"}}

      script([lookup([], [])])
      assert :ok = Adapter.remove_issue_label("issue-1", "reviewed")
      assert_received {:graphql_called, _lookup, _variables}
      refute_received {:graphql_called, _remove, _variables}

      script([lookup(["label-a", "label-b"], []), {:ok, %{"data" => %{}}}])
      assert {:error, :issue_label_update_failed} = Adapter.remove_issue_label("issue-1", "reviewed")

      script([{:error, :boom}])
      assert {:error, :boom} = Adapter.remove_issue_label("issue-1", "reviewed")
    end
  end

  describe "memory tracker labels" do
    test "edits the configured issues and reports scripted failures" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      tracked([issue("id-1", "MT-1", "Todo", ["Reviewed"]), issue("id-2", "MT-2", "Todo", [])])

      assert :ok = Memory.add_issue_label("id-1", "reviewed")
      assert labels("id-1") == ["Reviewed"]
      assert :ok = Memory.add_issue_label("id-2", "reviewed")
      assert labels("id-2") == ["reviewed"]
      assert_received {:memory_tracker_label_added, "id-2", "reviewed"}

      assert :ok = Memory.remove_issue_label("id-1", "REVIEWED")
      assert labels("id-1") == []
      assert_received {:memory_tracker_label_removed, "id-1", "REVIEWED"}

      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, [{:error, :boom}])
      assert {:error, :boom} = Memory.add_issue_label("id-1", "reviewed")
      assert labels("id-1") == []
      assert :ok = Memory.add_issue_label("id-1", "reviewed")
      assert labels("id-1") == ["reviewed"]
    end

    test "edits the issues file", %{test_root: test_root} do
      issues_file = Path.join(test_root, "issues.json")
      File.mkdir_p!(test_root)

      File.write!(
        issues_file,
        Jason.encode!([
          %{"id" => "id-1", "identifier" => "MT-1", "state" => "Todo", "labels" => ["bug", 7]},
          %{"id" => "id-2", "identifier" => "MT-2", "state" => "Todo"}
        ])
      )

      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      write_workflow_file!(Workflow.workflow_file_path(), tracker_memory_issues_file: issues_file)

      assert :ok = Memory.add_issue_label("id-1", "reviewed")
      assert {:ok, %Issue{labels: ["bug", "reviewed"]}} = Memory.fetch_issue_by_identifier("MT-1")
      assert {:ok, %Issue{labels: []}} = Memory.fetch_issue_by_identifier("MT-2")

      assert :ok = Memory.remove_issue_label("id-1", "Reviewed")
      assert {:ok, %Issue{labels: ["bug"]}} = Memory.fetch_issue_by_identifier("MT-1")

      # Without an issues file there is nothing to edit.
      write_workflow_file!(Workflow.workflow_file_path())
      assert :ok = Memory.add_issue_label("id-1", "reviewed")
    end
  end

  defp script(results), do: Process.put({FakeLinearClient, :graphql_results}, results)

  defp lookup(on_issue, labels) do
    {:ok,
     %{
       "data" => %{
         "issue" => %{"team" => %{"id" => "team-1"}, "labels" => %{"nodes" => Enum.map(on_issue, &%{"id" => &1})}},
         "issueLabels" => %{"nodes" => labels}
       }
     }}
  end

  defp label(id, nil), do: %{"id" => id, "team" => nil}
  defp label(id, team_id), do: %{"id" => id, "team" => %{"id" => team_id}}

  # The ticket's labels, without the `Blocked` hold the dependency gate projects on a Todo ticket
  # with an open blocker.
  defp labels(issue_id) do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == issue_id))
    |> Map.fetch!(:labels)
    |> Enum.reject(&(&1 == "Blocked"))
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp issue(id, identifier, state, labels) do
    %Issue{id: id, identifier: identifier, title: "Ticket #{identifier}", state: state, labels: labels, team: %{key: "Test"}}
  end
end
