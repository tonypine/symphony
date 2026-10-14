defmodule SymphonyElixir.TicketPullRequestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TicketPullRequest

  @repo_key "repo-a"
  @pr "https://github.com/acme/repo/pull/1"
  @next_pr "https://github.com/acme/repo/pull/2"
  @attachment_pr "https://github.com/acme/repo/pull/9"

  setup do
    :ok = RunStore.clear()
  end

  test "records the PR Symphony opened as the ticket's open PR" do
    assert :ok = TicketPullRequest.record_created(@repo_key, "issue-1", " #{@pr} ", "auto/ACME-1")

    assert %{
             repo_key: @repo_key,
             issue_id: "issue-1",
             pr_url: @pr,
             branch: "auto/ACME-1",
             state: "open",
             source: "created",
             recorded_at: %DateTime{} = recorded_at,
             updated_at: recorded_at
           } = TicketPullRequest.get(@repo_key, "issue-1")

    assert TicketPullRequest.current_url(issue("issue-1")) == @pr
    assert TicketPullRequest.current_urls(issue("issue-1")) == [@pr]
  end

  test "a new PR replaces the record of a closed one" do
    assert :ok = TicketPullRequest.record_created(@repo_key, "issue-1", @pr, "auto/ACME-1")
    assert :ok = TicketPullRequest.mark_finished(@repo_key, @pr, "closed")
    assert TicketPullRequest.current_url(issue("issue-1")) == nil

    assert :ok = TicketPullRequest.record_created(@repo_key, "issue-1", @next_pr, "auto/ACME-1-v2")

    assert %{pr_url: @next_pr, branch: "auto/ACME-1-v2", state: "open"} = TicketPullRequest.get(@repo_key, "issue-1")
    assert TicketPullRequest.current_url(issue("issue-1")) == @next_pr
  end

  test "a finished PR is not the ticket's in-flight PR, and a finish for another PR changes nothing" do
    assert :ok = TicketPullRequest.record_created(@repo_key, "issue-1", @pr, nil)
    assert :ok = TicketPullRequest.record_created(@repo_key, "issue-2", @next_pr, nil)

    assert :ok = TicketPullRequest.mark_finished(@repo_key, @pr, "merged")

    assert %{state: "merged", branch: nil} = TicketPullRequest.get(@repo_key, "issue-1")
    assert %{state: "open"} = TicketPullRequest.get(@repo_key, "issue-2")
    assert TicketPullRequest.current_url(issue("issue-1")) == nil
    assert TicketPullRequest.current_urls(issue("issue-1")) == []

    # Seen again, or seen closed in another repo: nothing changes.
    assert :ok = TicketPullRequest.mark_finished(@repo_key, @pr, "merged")
    assert :ok = TicketPullRequest.mark_finished("repo-b", @next_pr, "closed")
    assert %{state: "open"} = TicketPullRequest.get(@repo_key, "issue-2")

    assert [%{issue_id: "issue-1"}, %{issue_id: "issue-2"}] =
             @repo_key |> TicketPullRequest.list() |> Enum.sort_by(& &1.issue_id)
  end

  test "a PR run's issue answers its own PR" do
    pr_run = %Issue{id: "pr:#{@repo_key}:7", repo_key: @repo_key, run_kind: :pr, pull_request_url: @pr, pr_urls: [@pr]}

    assert TicketPullRequest.current_url(pr_run) == @pr
    assert TicketPullRequest.current_urls(pr_run) == [@pr]
    assert TicketPullRequest.current_urls(%{pr_run | pull_request_url: nil}) == []
  end

  test "a ticket with no record falls back to its attachment-derived PR" do
    assert TicketPullRequest.current_url(issue("issue-1")) == @attachment_pr
    assert TicketPullRequest.current_urls(issue("issue-1")) == [@attachment_pr, @pr]

    single = %Issue{id: "issue-1", repo_key: @repo_key, pull_request_url: @attachment_pr}
    assert TicketPullRequest.current_urls(single) == [@attachment_pr]
    assert TicketPullRequest.current_urls(%{single | pull_request_url: nil}) == []

    no_repo = %{issue("issue-1") | repo_key: nil}
    assert TicketPullRequest.current_url(no_repo) == @attachment_pr

    # A store that cannot be read falls back too.
    assert TicketPullRequest.current_url(%{issue("issue-1") | repo_key: "  "}) == @attachment_pr
  end

  test "refuses a record without a PR URL or with an unknown source" do
    assert {:error, :invalid_pr_url} = TicketPullRequest.put(@repo_key, "issue-1", %{pr_url: " "})
    assert {:error, :invalid_source} = TicketPullRequest.put(@repo_key, "issue-1", %{pr_url: @pr, source: "guess"})
    assert {:error, :invalid_ticket_pull_request_record} = TicketPullRequest.put(nil, "issue-1", %{pr_url: @pr})

    assert :ok = TicketPullRequest.put(@repo_key, "issue-1", %{pr_url: @pr, source: "backfill"})
    assert %{source: "backfill", state: "open"} = TicketPullRequest.get(@repo_key, "issue-1")
  end

  test "no-ops without a repo key, an issue id, a URL or a finished state" do
    assert :ok = TicketPullRequest.record_created(nil, "issue-1", @pr, nil)
    assert :ok = TicketPullRequest.record_created(@repo_key, nil, @pr, nil)
    assert TicketPullRequest.get(@repo_key, "issue-1") == nil

    assert :ok = TicketPullRequest.record_created(@repo_key, "issue-1", @pr, nil)
    assert :ok = TicketPullRequest.mark_finished(nil, @pr, "closed")
    assert :ok = TicketPullRequest.mark_finished(@repo_key, nil, "closed")
    assert :ok = TicketPullRequest.mark_finished(@repo_key, @pr, "open")
    assert %{state: "open"} = TicketPullRequest.get(@repo_key, "issue-1")
  end

  test "logs and swallows a store failure" do
    log =
      capture_log(fn ->
        assert :ok = TicketPullRequest.record_created("  ", "issue-1", @pr, nil)
        assert :ok = TicketPullRequest.mark_finished("  ", @pr, "closed")
      end)

    assert log =~ "Failed to record the pull request"
    assert log =~ "Failed to mark the pull request #{@pr} closed"
  end

  defp issue(issue_id) do
    %Issue{id: issue_id, repo_key: @repo_key, pull_request_url: @attachment_pr, pr_urls: [@attachment_pr, @pr]}
  end
end
