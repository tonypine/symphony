defmodule SymphonyElixir.SessionsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Sessions

  test "lists the agent runs with their kind, then the QA passes, then the acceptance gate passes" do
    started_at = ~U[2026-10-12 19:00:00Z]

    running = [
      %{issue_id: "a", identifier: "TP-1", repo_key: "symphony", started_at: started_at, run_profile: %{kind: :code_review}},
      %{issue_id: "b", identifier: "TP-2", run_kind: :pr, started_at: started_at},
      %{issue_id: "c", identifier: "TP-3", started_at: started_at}
    ]

    qa = [%{issue_id: "d", identifier: "TP-4", repo_key: "symphony", started_at: started_at}]
    gate = [%{issue_id: "e", identifier: "TP-5"}]

    assert Sessions.list(running, qa, gate) == [
             %{kind: "code_review", issue_id: "a", issue_identifier: "TP-1", repo_key: "symphony", started_at: started_at},
             %{kind: "pr", issue_id: "b", issue_identifier: "TP-2", repo_key: nil, started_at: started_at},
             %{kind: "agent", issue_id: "c", issue_identifier: "TP-3", repo_key: nil, started_at: started_at},
             %{kind: "qa_pass", issue_id: "d", issue_identifier: "TP-4", repo_key: "symphony", started_at: started_at},
             %{kind: "acceptance_gate", issue_id: "e", issue_identifier: "TP-5", repo_key: nil, started_at: nil}
           ]

    assert Sessions.list([], [], []) == []
  end

  test "tells passes from agent runs and names each kind" do
    assert Sessions.pass?(%{kind: "qa_pass"})
    assert Sessions.pass?(%{kind: "acceptance_gate"})
    refute Sessions.pass?(%{kind: "qa"})

    assert Sessions.label("qa_pass") == "QA pass"
    assert Sessions.label("acceptance_gate") == "acceptance gate pass"
    assert Sessions.label("qa") == "QA run"
    assert Sessions.label("code_review") == "code review run"
  end
end
