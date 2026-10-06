defmodule Mix.Tasks.Symphony.DoneWithOpenSubticketsTest do
  use SymphonyElixir.TestSupport

  alias Mix.Tasks.Symphony.DoneWithOpenSubtickets

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  test "lists every terminal parent with open sub-tickets and writes nothing to the tracker" do
    issues = [
      issue("TP-10", "Done", "Ship the wait", [
        sub_issue("TP-11", "In Progress"),
        sub_issue("TP-12", "Done"),
        sub_issue("TP-13", "Backlog")
      ]),
      issue("TP-9", "Canceled", "Old plan", [%{id: "child-id", identifier: nil, state: nil}]),
      issue("local", "Duplicate", "No number", [sub_issue("TP-40", "Todo")]),
      issue("TP-20", "Done", "All finished", [sub_issue("TP-21", "Done"), sub_issue("TP-22", "Canceled")]),
      issue("TP-30", "In Progress", "Still active", [sub_issue("TP-31", "Todo")]),
      issue("TP-32", "Done", "No children", [])
    ]

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

    DoneWithOpenSubtickets.run(["--config", Workflow.symphony_file_path()])

    assert_received {:mix_shell, :info, [output]}

    assert output == """
           3 parents in a terminal state with open sub-tickets:

           - TP-9 (Canceled): Old plan
             - child-id: unknown
           - TP-10 (Done): Ship the wait
             - TP-11: In Progress
             - TP-13: Backlog
           - local (Duplicate): No number
             - TP-40: Todo\
           """

    refute_received {:memory_tracker_comment, _issue_id, _body}
    refute_received {:memory_tracker_reply, _issue_id, _parent_id, _body}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
    refute_received {:memory_tracker_label_added, _issue_id, _label}
    refute_received {:memory_tracker_label_removed, _issue_id, _label}
    assert Application.get_env(:symphony_elixir, :memory_tracker_issues) == issues
  end

  test "names a single parent and says when there is none" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("TP-1", "Done", "One", [sub_issue("TP-2", "Todo")])])
    DoneWithOpenSubtickets.run([])
    assert_received {:mix_shell, :info, ["1 parent in a terminal state with open sub-tickets:\n\n- TP-1 (Done): One\n  - TP-2: Todo"]}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("TP-1", "Done", "One", [sub_issue("TP-2", "Done")])])
    DoneWithOpenSubtickets.run([])
    assert_received {:mix_shell, :info, ["No parent in a terminal state has open sub-tickets."]}
  end

  test "rejects unknown arguments" do
    for args <- [["extra"], ["--apply"]] do
      assert_raise Mix.Error, ~r/Usage: mix symphony.done_with_open_subtickets/, fn ->
        DoneWithOpenSubtickets.run(args)
      end
    end
  end

  test "stops on a config it cannot load" do
    assert_raise Mix.Error, ~r/symphony.yml/, fn ->
      DoneWithOpenSubtickets.run(["--config", Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}/symphony.yml")])
    end
  end

  test "stops when the tracker read fails" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    assert_raise Mix.Error, ~r/Unable to fetch issues in .*Done: :missing_linear_api_token/, fn ->
      DoneWithOpenSubtickets.run([])
    end
  end

  defp issue(identifier, state, title, sub_issues) do
    %Issue{id: "id-#{identifier}", identifier: identifier, state: state, title: title, sub_issues: sub_issues}
  end

  defp sub_issue(identifier, state), do: %{id: "id-#{identifier}", identifier: identifier, state: state}
end
