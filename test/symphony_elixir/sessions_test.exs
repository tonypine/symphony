defmodule SymphonyElixir.SessionsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Sessions

  test "lists the agent runs with their kind" do
    started_at = ~U[2026-10-12 19:00:00Z]

    running = [
      %{issue_id: "a", identifier: "TP-1", repo_key: "symphony", started_at: started_at, run_profile: %{kind: :code_review}},
      %{issue_id: "b", identifier: "TP-2", run_kind: :pr, started_at: started_at},
      %{issue_id: "c", identifier: "TP-3", started_at: started_at}
    ]

    assert Sessions.list(running) == [
             %{kind: "code_review", issue_id: "a", issue_identifier: "TP-1", repo_key: "symphony", started_at: started_at},
             %{kind: "pr", issue_id: "b", issue_identifier: "TP-2", repo_key: nil, started_at: started_at},
             %{kind: "agent", issue_id: "c", issue_identifier: "TP-3", repo_key: nil, started_at: started_at}
           ]

    assert Sessions.list([]) == []
  end
end
