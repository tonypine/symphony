defmodule SymphonyElixir.TicketPullRequest.BackfillTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.TicketPullRequest.Backfill

  @repo_key "repo-a"
  @other_repo_key "repo-b"

  setup do
    :ok = RunStore.clear()
  end

  test "seeds a backfill record from a CI check, a PR review or a handoff signal" do
    :ok = RunStore.put_ci_check(%{repo_key: @repo_key, issue_id: "issue-ci", pr_url: pr(1), branch: "auto/ACME-1"})
    :ok = RunStore.put_pr_review(%{repo_key: @repo_key, issue_id: "issue-review", pr_url: pr(2)})
    :ok = RunStore.record_ticket_signal(@repo_key, "issue-handoff", "handoff", %{pr_url: pr(3), branch: "auto/ACME-3", head: "abc"})

    log = capture_log(fn -> assert %{seeded: 3, kept: 0} = Backfill.run([@repo_key]) end)

    assert log =~ "Backfilled 3 ticket pull request record(s) from stored PR URLs"
    assert %{pr_url: "https://github.com/acme/repo/pull/1", branch: "auto/ACME-1", state: "open", source: "backfill"} = TicketPullRequest.get(@repo_key, "issue-ci")
    assert %{pr_url: "https://github.com/acme/repo/pull/2", branch: nil, source: "backfill"} = TicketPullRequest.get(@repo_key, "issue-review")
    assert %{pr_url: "https://github.com/acme/repo/pull/3", branch: "auto/ACME-3", source: "backfill"} = TicketPullRequest.get(@repo_key, "issue-handoff")
  end

  test "leaves an existing record alone and is idempotent" do
    :ok = TicketPullRequest.put(@repo_key, "issue-1", %{pr_url: pr(9), source: "created"})
    :ok = TicketPullRequest.mark_finished(@repo_key, pr(9), "merged")
    :ok = RunStore.put_ci_check(%{repo_key: @repo_key, issue_id: "issue-1", pr_url: pr(1)})
    :ok = RunStore.put_ci_check(%{repo_key: @repo_key, issue_id: "issue-2", pr_url: pr(2)})

    assert %{seeded: 1, kept: 1} = Backfill.run_repo(@repo_key)
    assert %{seeded: 0, kept: 2} = Backfill.run_repo(@repo_key)

    assert %{pr_url: "https://github.com/acme/repo/pull/9", state: "merged", source: "created"} = TicketPullRequest.get(@repo_key, "issue-1")
    assert %{pr_url: "https://github.com/acme/repo/pull/2", source: "backfill"} = TicketPullRequest.get(@repo_key, "issue-2")
  end

  test "prefers the CI check, then the PR review, then the newest handoff signal naming a PR" do
    :ok = RunStore.put_ci_check(%{repo_key: @repo_key, issue_id: "issue-1", pr_url: pr(1)})
    :ok = RunStore.put_pr_review(%{repo_key: @repo_key, issue_id: "issue-1", pr_url: pr(11)})
    :ok = RunStore.put_pr_review(%{repo_key: @repo_key, issue_id: "issue-2", pr_url: pr(2)})
    :ok = RunStore.record_ticket_signal(@repo_key, "issue-2", "handoff", %{pr_url: pr(12)})
    :ok = RunStore.record_ticket_signal(@repo_key, "issue-3", "handoff", %{pr_url: pr(30)})
    :ok = RunStore.record_ticket_signal(@repo_key, "issue-3", "handoff", %{pr_url: pr(3)})
    :ok = RunStore.record_ticket_signal(@repo_key, "issue-3", "handoff", %{to: "Merging", move: true})
    :ok = RunStore.record_ticket_signal(@repo_key, "issue-3", "claim", %{pr_url: pr(31)})

    assert %{seeded: 3} = Backfill.run_repo(@repo_key)

    assert %{pr_url: "https://github.com/acme/repo/pull/1"} = TicketPullRequest.get(@repo_key, "issue-1")
    assert %{pr_url: "https://github.com/acme/repo/pull/2"} = TicketPullRequest.get(@repo_key, "issue-2")
    assert %{pr_url: "https://github.com/acme/repo/pull/3"} = TicketPullRequest.get(@repo_key, "issue-3")
  end

  test "skips a PR the auto-merge lane landed, a ledger with no PR and another repo's records" do
    :ok = RunStore.put_pr_review(%{repo_key: @repo_key, issue_id: "issue-1", pr_url: pr(1), auto_merge: %{state: "merged"}})
    :ok = RunStore.put_pr_review(%{repo_key: @repo_key, issue_id: "issue-2", pr_url: nil})
    :ok = RunStore.record_ticket_signal(@repo_key, "issue-3", "claim", %{from: "Todo"})
    :ok = RunStore.put_ci_check(%{repo_key: @other_repo_key, issue_id: "issue-4", pr_url: pr(4)})

    assert %{seeded: 0, kept: 0} = Backfill.run([@repo_key])
    assert TicketPullRequest.list(@repo_key) == []
    assert TicketPullRequest.get(@other_repo_key, "issue-4") == nil
  end

  test "logs a store it cannot read and a PR URL it cannot record" do
    :ok = RunStore.put_ci_check(%{repo_key: @repo_key, issue_id: "issue-1", pr_url: "  "})

    log =
      capture_log(fn ->
        assert %{seeded: 0, kept: 0} = Backfill.run(["  ", @repo_key])
      end)

    assert log =~ "Failed to backfill ticket pull request records repo_key=  : :invalid_repo_key"
    assert log =~ ~s(Failed to backfill the pull request "  " of issue_id=issue-1: :invalid_pr_url)
    refute log =~ "Backfilled"
  end

  defp pr(number), do: "https://github.com/acme/repo/pull/#{number}"
end
