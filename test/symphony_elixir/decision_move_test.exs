defmodule SymphonyElixir.DecisionMoveTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DecisionMove, Handoff, RunStore, Workflow}

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

    record = RunStore.get_ticket_state(@issue_id)
    assert record.phase == "Merging"
    assert [%{kind: "qa", outcome: "skip", head_sha: "abc123", details: %{reason: "skipped by decision"}}] = ticket_verdicts(@issue_id)
  end

  test "perform/4 answers the guard's refusal, and tries Canceled's other spelling only for a missing state" do
    missing = {:error, :state_not_found}
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [missing, missing])
    assert {:error, :state_not_found} = DecisionMove.perform(@repo_key, @issue_id, %{to: "Cancelled"})

    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :rate_limited}])
    capture_log(fn -> assert {:error, :rate_limited} = DecisionMove.perform(@repo_key, @issue_id, %{to: "Canceled"}) end)
    refute_received {:memory_tracker_state_update, @issue_id, _state}
  end

  test "back_to_review/4 moves a ticket in Rework to Code Review with the handoff, and is refused elsewhere" do
    assert DecisionMove.back_to_review("Rework", "Rework", "Code Review", "abc123") == {:ok, %{to: "Code Review", handoff: %{head: "abc123"}}}
    assert {:error, why} = DecisionMove.back_to_review("QA", "Rework", "Code Review", nil)
    assert why =~ "the ticket is in QA, not Rework"
  end

  test "perform/4 with a handoff emits it for the Rework's base, moves to Code Review and forgets the base" do
    :ok = RunStore.put_rework_base(@repo_key, @issue_id, "base123")
    {:ok, move} = DecisionMove.back_to_review("Rework", "Rework", "Code Review", nil)

    assert {:ok, "Code Review"} = DecisionMove.perform(@repo_key, @issue_id, move)
    assert_received {:memory_tracker_state_update, @issue_id, "Code Review"}
    assert Handoff.emitted?(@repo_key, @issue_id, "base123")
    assert RunStore.get_rework_base(@repo_key, @issue_id) == nil
  end

  test "perform/4 with a handoff emits it for the question's head, and keeps the base when the move is refused" do
    :ok = RunStore.put_rework_base(@repo_key, @issue_id, "base123")
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :rate_limited}])

    capture_log(fn ->
      assert {:error, :rate_limited} = DecisionMove.perform(@repo_key, @issue_id, %{to: "Code Review", handoff: %{head: "head456"}})
    end)

    assert Handoff.emitted?(@repo_key, @issue_id, "head456")
    assert RunStore.get_rework_base(@repo_key, @issue_id) == "base123"
  end

  test "perform/4 with a handoff and no stored Rework base emits it for any head" do
    {:ok, move} = DecisionMove.back_to_review("Rework", "Rework", "Code Review", nil)

    assert {:ok, "Code Review"} = DecisionMove.perform(@repo_key, @issue_id, move)
    assert Handoff.emitted?(@repo_key, @issue_id, "any-head")
  end
end
