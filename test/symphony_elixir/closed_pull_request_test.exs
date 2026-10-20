defmodule SymphonyElixir.ClosedPullRequestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClosedPullRequest
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Hold
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketPullRequest

  @repo_key "repo-closed-pull-request"
  @pr_url "https://github.com/acme/repo/pull/512"

  defmodule FailingStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :disk_full}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-closed-pr-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      RunStore.delete_ticket_state(@repo_key, issue_id)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    %{issue_id: issue_id}
  end

  defp settings! do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    settings
  end

  defp issue(issue_id, state, attrs \\ %{}) do
    struct!(%Issue{id: issue_id, identifier: "TP-983", title: "Show an automatic update", state: state, repo_key: @repo_key}, attrs)
  end

  defp close_pull_request(issue_id, url \\ @pr_url, state \\ "closed") do
    :ok = TicketPullRequest.put(@repo_key, issue_id, %{pr_url: url})
    :ok = TicketPullRequest.mark_finished(@repo_key, url, state)
  end

  describe "guard/3" do
    # TP-983 and TP-972: a Backlog move closed their pull requests, and moving them back to QA
    # started a run on the base branch's head.
    test "holds a ticket moved back out of Backlog whose pull request the move closed, before any run", %{issue_id: issue_id} do
      close_pull_request(issue_id)

      assert :held = ClosedPullRequest.guard(issue(issue_id, "QA"), settings!(), [])

      assert_received {:memory_tracker_comment, ^issue_id, request}
      assert request =~ "## Decision needed: Reopen the pull request of TP-983"
      assert request =~ "TP-983 (Show an automatic update) in QA has its pull request PR #512 closed"
      assert request =~ "you reopen PR #512 on GitHub"
      assert request =~ "the ticket stays in QA until the decision is recorded"

      assert %{reason: reason, decision: %{options: options}} = Hold.get(@repo_key, issue_id, :needs_decision)
      assert reason =~ "PR #512 closed"
      assert Enum.map(options, &{&1.label, &1.recommended}) == [{"Reopen", true}, {"Restart", false}, {"Cancel", false}]
      assert [{"decision.requested", %{title: "Reopen the pull request of TP-983"}}] = ticket_events(@repo_key, issue_id)
    end

    test "holds every phase that judges, repairs or lands the existing pull request", %{issue_id: issue_id} do
      close_pull_request(issue_id)

      for state <- ["Code Review", "QA", "CI Fix", " merging "] do
        RunStore.delete_ticket_state(@repo_key, issue_id)
        assert :held = ClosedPullRequest.guard(issue(issue_id, state), settings!(), [])
        assert Hold.held?(@repo_key, issue_id, :needs_decision)
      end
    end

    test "lets a ticket that builds its own change run, Rework too: its run opens a new pull request from main (D5)", %{issue_id: issue_id} do
      close_pull_request(issue_id)

      for state <- ["Todo", "In Progress", "Rework", nil] do
        assert :run = ClosedPullRequest.guard(issue(issue_id, state), settings!(), [])
      end

      assert :run = ClosedPullRequest.guard(%{id: issue_id, state: "QA"}, settings!(), [])
      refute_received {:memory_tracker_comment, _, _}
    end

    test "lets a ticket with an open, merged or no recorded pull request run", %{issue_id: issue_id} do
      assert :run = ClosedPullRequest.guard(issue(issue_id, "QA"), settings!(), [])
      assert :run = ClosedPullRequest.guard(issue(issue_id, "QA", %{repo_key: nil}), settings!(), [])

      :ok = TicketPullRequest.put(@repo_key, issue_id, %{pr_url: @pr_url})
      assert :run = ClosedPullRequest.guard(issue(issue_id, "QA"), settings!(), [])

      close_pull_request(issue_id, @pr_url, "merged")
      assert :run = ClosedPullRequest.guard(issue(issue_id, "Merging"), settings!(), [])

      refute Hold.held?(@repo_key, issue_id, :needs_decision)
    end

    test "reads the record under the lane's repo key when the issue carries none", %{issue_id: issue_id} do
      close_pull_request(issue_id)

      assert :held = ClosedPullRequest.guard(issue(issue_id, "QA", %{repo_key: nil}), settings!(), repo_key: @repo_key)
      assert Hold.held?(@repo_key, issue_id, :needs_decision)
    end

    test "reports a hold that cannot be set", %{issue_id: issue_id} do
      close_pull_request(issue_id)

      assert {:error, {:closed_pull_request_hold_failed, {:decision_hold_failed, :disk_full}}} =
               ClosedPullRequest.guard(issue(issue_id, "QA"), settings!(), store: FailingStore)

      refute_received {:memory_tracker_comment, _, _}
    end
  end

  describe "missing_cause/2" do
    test "names the closed pull request, else no pull request at all", %{issue_id: issue_id} do
      assert :no_pull_request = ClosedPullRequest.missing_cause(issue(issue_id, "QA"), nil)

      close_pull_request(issue_id)
      assert {:closed, @pr_url} = ClosedPullRequest.missing_cause(issue(issue_id, "QA"), nil)
      assert {:closed, @pr_url} = ClosedPullRequest.missing_cause(issue(issue_id, "QA", %{repo_key: nil}), @repo_key)

      close_pull_request(issue_id, @pr_url, "merged")
      assert :no_pull_request = ClosedPullRequest.missing_cause(issue(issue_id, "QA"), nil)
    end
  end

  describe "request/2" do
    test "asks to reopen a missing pull request", %{issue_id: issue_id} do
      request = ClosedPullRequest.request(issue(issue_id, "QA"), :no_pull_request)

      assert request.question =~ "TP-983 (Show an automatic update) in QA has no open pull request"
      assert [%{label: "Reopen", effect: "you reopen its pull request on GitHub" <> _} | _] = request.options
      assert request.if_unanswered == "TP-983 stays in QA and nothing runs on it."
    end

    test "falls back to the ticket's id, and to plain words for a link that names no pull request" do
      bare = %Issue{id: "issue-bare"}

      request = ClosedPullRequest.request(bare, {:closed, "https://example.com/change"})
      assert request.title == ~s(Reopen the pull request of "issue-bare")
      assert [%{effect: "you reopen its pull request on GitHub" <> _} | _] = request.options
      assert request.question =~ ~s("issue-bare" has its pull request closed)
      assert request.if_unanswered == ~s("issue-bare" stays and nothing runs on it.)

      empty = ClosedPullRequest.request(%Issue{id: "issue-bare", identifier: "TP-1", title: "", state: ""}, {:no_change, "https://example.com/change"})
      assert empty.question =~ "TP-1 has a pull request that changes nothing"

      named = ClosedPullRequest.request(%Issue{id: "issue-bare", identifier: "TP-1", title: "", state: ""}, {:no_change, @pr_url})
      assert named.question =~ "TP-1 has a pull request (PR #512) that changes nothing"
    end

    # The empty-change request says what was compared: the pull request's latest commit as GitHub has
    # it, which GitHub also reads as changing nothing, or the branch of a ticket with no pull request.
    test "an empty-change request names the head it compared" do
      issue = %Issue{id: "issue-bare", identifier: "TP-1", title: "", state: ""}

      assert ClosedPullRequest.request(issue, {:no_change, @pr_url}).why =~
               "Symphony compared the latest commit of PR #512, as GitHub has it, with the main branch, and GitHub also shows PR #512 changing no files."

      assert ClosedPullRequest.request(issue, {:no_change, nil}).why =~
               "Symphony compared the latest commit of the ticket's branch with the main branch: it has no commit the main branch lacks."
    end
  end
end
