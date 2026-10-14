defmodule SymphonyElixir.QualityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Quality

  test "builds eval logs with outcome, labels, tokens, duration, and tests_run signal" do
    started_at = ~U[2026-05-05 08:00:00Z]
    ended_at = ~U[2026-05-05 08:01:30Z]

    running_entry = %{
      run_id: "run-quality-1",
      identifier: "ACME-1",
      issue: %Issue{
        id: "issue-1",
        identifier: "ACME-1",
        labels: ["bug"]
      },
      pull_request_url: "https://github.com/example/repo/pull/1",
      session_id: "session-1",
      codex_input_tokens: 10,
      codex_cached_input_tokens: 7,
      codex_output_tokens: 4,
      codex_total_tokens: 14,
      started_at: started_at
    }

    eval =
      Quality.build_eval_log_for_test(running_entry, "success", nil,
        agent_kind: "codex",
        ended_at: ended_at,
        now: ended_at,
        transcript_events: [
          %{payload: %{"params" => %{"msg" => %{"command" => "mix test test/symphony_elixir/run_store_test.exs"}}}}
        ]
      )

    assert eval.outcome == "pr_opened"
    assert eval.agent_kind == "codex"
    assert eval.issue_labels == ["bug"]

    assert eval.tokens == %{
             input_tokens: 10,
             uncached_input_tokens: 3,
             cached_input_tokens: 7,
             cache_creation_input_tokens: 0,
             output_tokens: 4,
             total_tokens: 14
           }

    assert eval.duration_seconds == 90
    assert eval.tests_run == true
    assert eval.error_kind == nil
  end

  test "tests_run is false when transcript exists but no test run command was issued" do
    running_entry = %{
      run_id: "run-quality-2",
      identifier: "ACME-2",
      issue: %Issue{id: "issue-2", identifier: "ACME-2", labels: []},
      started_at: DateTime.utc_now()
    }

    eval =
      Quality.build_eval_log_for_test(running_entry, "success", nil,
        agent_kind: "claude",
        transcript_events: [
          %{payload: %{"params" => %{"msg" => %{"command" => "cat lib/symphony_elixir/run_store.ex"}}}}
        ]
      )

    assert eval.outcome == "no_changes"
    assert eval.tests_run == false

    no_match =
      Quality.build_eval_log_for_test(running_entry, "success", nil,
        agent_kind: "claude",
        transcript_events: [%{"type" => "message"}]
      )

    assert no_match.tests_run == false

    unavailable =
      Quality.build_eval_log_for_test(running_entry, "success", nil,
        agent_kind: "claude",
        transcript_events: nil
      )

    assert unavailable.tests_run == nil
  end

  test "error statuses produce error outcomes with error_kind" do
    timeout_eval =
      Quality.build_eval_log_for_test(
        %{run_id: "run-quality-3", issue: %Issue{id: "i3", identifier: "ACME-3"}, started_at: DateTime.utc_now()},
        "timeout",
        nil,
        agent_kind: "codex",
        transcript_events: nil
      )

    assert timeout_eval.outcome == "error"
    assert timeout_eval.error_kind == "timeout"

    budget_eval =
      Quality.build_eval_log_for_test(
        %{run_id: "run-quality-4", issue: %Issue{id: "i4", identifier: "ACME-4"}, started_at: DateTime.utc_now()},
        "budget_exhausted",
        nil,
        agent_kind: "codex",
        transcript_events: nil
      )

    assert budget_eval.outcome == "error"
    assert budget_eval.error_kind == "budget_exhausted"

    failure_eval =
      Quality.build_eval_log_for_test(
        %{run_id: "run-quality-5", issue: %Issue{id: "i5", identifier: "ACME-5"}, started_at: DateTime.utc_now()},
        "failure",
        "agent exited: :boom",
        agent_kind: "codex",
        transcript_events: nil
      )

    assert failure_eval.outcome == "error"
    assert failure_eval.error_kind == "failure"
    assert failure_eval.error == "agent exited: :boom"
  end

  test "pr_opened outcome wins over error status when pull_request_url is present" do
    eval =
      Quality.build_eval_log_for_test(
        %{
          run_id: "run-quality-6",
          issue: %Issue{id: "i6", identifier: "ACME-6"},
          pull_request_url: "https://github.com/example/repo/pull/99",
          started_at: DateTime.utc_now()
        },
        "failure",
        "post-pr error",
        agent_kind: "codex",
        transcript_events: nil
      )

    assert eval.outcome == "pr_opened"
  end

  test "carries the ticket's PR from Symphony's record, and none once that PR closed" do
    pr_url = "https://github.com/example/repo/pull/1012"
    :ok = SymphonyElixir.TicketPullRequest.record_created("repo-q", "i-recorded", pr_url, "auto/ACME-12")

    entry = %{run_id: "run-quality-12", repo_key: "repo-q", issue: %Issue{id: "i-recorded", identifier: "ACME-12"}, started_at: DateTime.utc_now()}
    eval = Quality.build_eval_log_for_test(entry, "success", nil, agent_kind: "codex", transcript_events: nil)

    assert eval.pull_request_url == pr_url
    assert eval.outcome == "pr_opened"

    :ok = SymphonyElixir.TicketPullRequest.mark_finished("repo-q", pr_url, "closed")
    eval = Quality.build_eval_log_for_test(entry, "success", nil, agent_kind: "codex", transcript_events: nil)

    assert eval.pull_request_url == nil
    assert eval.outcome == "no_changes"
  end

  test "stopped terminal status is not reported as failure error_kind" do
    eval =
      Quality.build_eval_log_for_test(
        %{
          run_id: "run-quality-7",
          issue: %Issue{id: "i7", identifier: "ACME-7"},
          pull_request_url: "https://github.com/example/repo/pull/100",
          started_at: DateTime.utc_now()
        },
        "stopped",
        "agent stopped by orchestrator",
        agent_kind: "codex",
        transcript_events: nil
      )

    assert eval.outcome == "pr_opened"
    assert eval.status == "stopped"
    assert eval.error_kind == "stopped"
  end
end
