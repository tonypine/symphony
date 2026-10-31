defmodule SymphonyElixir.DecisionMoveTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DecisionMove, RunStore, Workflow}

  @repo_key "repo-move"
  @issue_id "issue-move"

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    :ok = RunStore.clear()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_state_result)
    end)

    :ok
  end

  defp question(options), do: %{options: options}

  defp rework, do: DecisionMove.option(%{label: "Send it back to Rework", effect: "Symphony moves it to Rework"}, %{to: "Rework"})

  test "picked/2 reads the move of the one option the answers pick, by label or number" do
    options = [%{label: "Run QA again", effect: "QA runs once more"}, rework()]

    assert DecisionMove.picked(question(options), ["Send it back to Rework"]) == %{to: "Rework"}
    assert DecisionMove.picked(question(options), ["2"]) == %{to: "Rework"}
    assert DecisionMove.picked(question(options), ["Run QA again"]) == nil
    assert DecisionMove.picked(question(options), ["something else"]) == nil
    # Options read back from Linear as lines, and no question, carry no move.
    assert DecisionMove.picked(question(["**Send it back to Rework**: Symphony moves it"]), ["1"]) == nil
    assert DecisionMove.picked(nil, ["1"]) == nil
  end

  test "perform/4 records the verdict, then moves through the guard with the record written first" do
    move = %{to: "Merging", verdict: %{kind: "qa", outcome: "skip", head_sha: "abc123", reason: "skipped by decision"}}

    assert {:ok, "Merging"} = DecisionMove.perform(@repo_key, @issue_id, move)
    assert_received {:memory_tracker_state_update, @issue_id, "Merging"}

    record = RunStore.get_ticket_state(@repo_key, @issue_id)
    assert record.phase == "Merging"
    assert [%{kind: "qa", outcome: "skip", head_sha: "abc123", details: %{reason: "skipped by decision"}}] = record.verdicts
  end

  test "perform/4 answers the guard's refusal, and tries Canceled's other spelling only for a missing state" do
    missing = {:error, :state_not_found}
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [missing, missing])
    assert {:error, :state_not_found} = DecisionMove.perform(@repo_key, @issue_id, %{to: "Cancelled"})

    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :rate_limited}])
    capture_log(fn -> assert {:error, :rate_limited} = DecisionMove.perform(@repo_key, @issue_id, %{to: "Canceled"}) end)
    refute_received {:memory_tracker_state_update, @issue_id, _state}
  end
end
