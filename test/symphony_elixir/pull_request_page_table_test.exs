defmodule SymphonyElixir.PullRequestPageTableTest do
  # Stops the application's page server, which owns a named table: not async.
  use ExUnit.Case, async: false

  alias SymphonyElixir.PullRequestPage

  test "serves a page and keeps none while the server that owns its table is stopped" do
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, PullRequestPage)
    on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, PullRequestPage) end)

    test_pid = self()

    opts = [
      github_repos: %{"symphony" => "tonypine/symphony"},
      pull_request: fn url ->
        send(test_pid, {:github, url})
        {:ok, pr()}
      end,
      linear_client: fn _query, _variables, _opts -> {:error, :offline} end,
      ticket_state: fn _repo_key, _issue_id -> nil end,
      pr_reviews: fn _repo_key -> [] end,
      ttl_ms: 60_000
    ]

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{github: "available"}} = PullRequestPage.fetch("symphony", 448, opts)
      assert {:ok, %{github: "available"}} = PullRequestPage.fetch("symphony", 448, opts)
    end)

    assert_received {:github, _url}
    assert_received {:github, _url}
  end

  defp pr do
    %{
      number: 448,
      url: "https://github.com/tonypine/symphony/pull/448",
      title: "A pull request",
      body: "",
      state: "OPEN",
      review_decision: nil,
      changed_files: 0,
      additions: 0,
      deletions: 0,
      head_ref_name: "auto/TP-1",
      checks: "passed",
      check_counts: %{passed: 0, failed: 0, pending: 0},
      created_at: ~U[2026-10-12 09:00:00Z],
      last_pushed_at: nil,
      merged_at: nil,
      files: [],
      commits: []
    }
  end
end
