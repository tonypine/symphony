defmodule SymphonyElixir.ReviewQualityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewQuality

  @dates [~D[2026-10-12], ~D[2026-10-13]]

  defp verdict(kind, outcome, at), do: %{kind: kind, head_sha: "abc", outcome: outcome, recorded_at: at}
  defp decision(to, at), do: %{name: "decision returned", details: %{move: "decide", to: to}, at: at}

  defp ticket(repo_key, issue_id, verdicts, signals \\ []) do
    %{repo_key: repo_key, issue_id: issue_id, issue_identifier: String.upcase(issue_id), verdicts: verdicts, signals: signals}
  end

  defp payload(records), do: ReviewQuality.payload(@dates, ticket_states: records, manual_review: &if(&1 == "web", do: "on", else: "off"))

  test "an approval is upheld by a QA pass or a confirmed merge, and overturned by a QA fail or a Rework" do
    records = [
      ticket("app", "a-1", [verdict("code_review", "approve", ~U[2026-10-12 09:00:00Z]), verdict("qa", "pass", ~U[2026-10-12 10:00:00Z])]),
      ticket("app", "a-2", [
        verdict("code_review", "approve", ~U[2026-10-12 09:00:00Z]),
        verdict("qa", "fail", ~U[2026-10-12 11:00:00Z]),
        verdict("code_review", "rework", ~U[2026-10-13 09:00:00Z]),
        verdict("code_review", "approve", ~U[2026-10-13 10:00:00Z]),
        verdict("qa", "skip", ~U[2026-10-13 11:00:00Z])
      ]),
      ticket("web", "w-1", [verdict("code_review", "approve", ~U[2026-10-13 09:00:00Z]), verdict("qa", "pass", ~U[2026-10-13 10:00:00Z])], [
        decision("Rework", ~U[2026-10-13 12:00:00Z])
      ]),
      ticket("web", "w-2", [verdict("code_review", "approve", ~U[2026-10-13 09:00:00Z])], [
        decision("Merging", ~U[2026-10-13 12:00:00Z]),
        %{name: "decision returned", details: %{"to" => "In Progress"}, at: ~U[2026-10-13 12:30:00Z]},
        %{name: "handoff", details: %{}, at: ~U[2026-10-13 08:00:00Z]}
      ]),
      ticket("web", "w-3", [verdict("code_review", "approve", ~U[2026-10-13 09:00:00Z]), verdict("qa", "blocked", ~U[2026-10-13 10:00:00Z])]),
      ticket("app", "a-3", [verdict("code_review", "rework", ~U[2026-10-13 09:00:00Z])]),
      ticket("app", "old", [verdict("code_review", "approve", ~U[2026-10-01 09:00:00Z]), verdict("qa", "fail", ~U[2026-10-01 10:00:00Z])]),
      %{issue_id: nil}
    ]

    review = payload(records)

    assert review.agreement == %{agreed: 3, disagreed: 2, pending: 1, rate: 0.6}

    assert review.by_repo == [
             %{repo_key: "app", manual_review: "off", agreed: 2, disagreed: 1, pending: 0, rate: 0.6667},
             %{repo_key: "web", manual_review: "on", agreed: 1, disagreed: 1, pending: 1, rate: 0.5}
           ]

    assert [
             %{identifier: "W-1", review: "Approved", decision: "Sent to Rework", decided_by: "Director", decided_at: "2026-10-13T12:00:00Z"},
             %{identifier: "A-2", repo_key: "app", decision: "QA failed", decided_by: "QA"}
           ] = review.disagreements

    assert review.qa_first_pass == %{passed: 2, judged: 3, rate: 0.6667}
    assert review.sent_to_rework == %{sent: 3, reviewed: 6, rate: 0.5}
  end

  test "an empty or unreadable ledger reports no rates" do
    for records <- [[], {:error, :down}] do
      assert %{agreement: %{rate: nil}, qa_first_pass: %{rate: nil}, sent_to_rework: %{rate: nil}, by_repo: []} =
               payload(records)
    end
  end

  test "reads the repo's manual review from its settings, off when it has none" do
    records = [ticket("no-such-repo", "x", [verdict("code_review", "approve", ~U[2026-10-13 09:00:00Z])])]
    assert %{by_repo: [%{manual_review: "off"}]} = ReviewQuality.payload(@dates, ticket_states: records)
  end
end
