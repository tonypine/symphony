defmodule SymphonyElixir.MergeConfirmationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Handoff, MergeConfirmation, Questions, RunStore, TicketPullRequest, TicketSignals}
  alias SymphonyElixir.HumanActions.{PlainWords, Request}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow

  @repo_key "repo-a"
  @issue_id "issue-1"

  # Records the request comment the pause posts, as the tracker's create_comment does.
  defmodule CommentTracker do
    def create_comment(issue_id, body) do
      send(recipient(), {:comment, issue_id, body})
      Application.get_env(:symphony_elixir, :merge_confirmation_comment_result, :ok)
    end

    defp recipient, do: Application.fetch_env!(:symphony_elixir, :merge_confirmation_test_recipient)
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :merge_confirmation_test_recipient, self())
    Application.delete_env(:symphony_elixir, :merge_confirmation_comment_result)
    :ok = RunStore.clear()
    on_exit(fn -> Application.delete_env(:symphony_elixir, :merge_confirmation_test_recipient) end)
    :ok
  end

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{id: @issue_id, identifier: "TP-825", title: "T", state: "QA", repo_key: @repo_key},
      attrs
    )
  end

  defp opts(extra \\ []), do: Keyword.merge([tracker: CommentTracker, repo_key: @repo_key], extra)

  defp parts(extra \\ %{}) do
    Map.merge(%{recommendation: "QA passed on 12 files", review: "the reviewer approved", qa: "all checks green"}, extra)
  end

  defp deciding, do: Questions.deciding({:ticket, @repo_key, @issue_id})

  describe "request/2 and confirm_target/1" do
    test "the request names the merge, carries the summary and offers confirming or redirecting" do
      summary = MergeConfirmation.summary(issue(), opts(), parts(%{pr: "https://github.com/acme/web/pull/7"}))
      request = MergeConfirmation.request(issue(), summary)

      assert request.title == "Merge TP-825"
      assert request.question == "Merge TP-825 (T) into its base branch?"
      assert request.if_unanswered == "TP-825 waits in QA and is not merged."
      refute Map.has_key?(request, :est_minutes)

      assert request.why ==
               "Recommendation: QA passed on 12 files · Code Review: the reviewer approved · QA: all checks green · PR #7"

      assert [merge, rework] = request.options
      assert %{label: "Merge", recommended: true} = merge
      assert merge.effect =~ "Merging"
      assert %{label: "Send to Rework", recommended: false} = rework
      assert rework.effect =~ "Rework"
      assert rework.effect =~ "a run changes PR #7"
      assert PlainWords.findings(request) == []
      assert PlainWords.tokens(Request.render_hold(request, "QA")) == []
    end

    test "a summary part it has none of is left out, and a long one is collapsed and truncated" do
      summary = MergeConfirmation.summary(issue(), opts(), parts(%{recommendation: "  QA   passed \n on 12 files  "}))
      request = MergeConfirmation.request(issue(), summary)

      assert request.why == "Recommendation: QA passed on 12 files · Code Review: the reviewer approved · QA: all checks green"
      assert MergeConfirmation.request(issue(), %{recommendation: nil, review: nil, qa: nil, pr: nil}).why == ""

      long = String.duplicate("x", 500)
      why = MergeConfirmation.request(issue(), %{recommendation: long, review: nil, qa: nil, pr: nil}).why
      assert String.length(why) == String.length("Recommendation: ") + 240
      assert why =~ "..."
    end

    test "an issue with no identifier is labelled by its id, and a part that is not a string is inspected" do
      request = MergeConfirmation.request(issue(%{identifier: nil}), parts(%{recommendation: :awaiting}))

      assert request.title == "Merge \"issue-1\""
      assert request.question == "Merge \"issue-1\" (T) into its base branch?"
      assert request.why =~ "Recommendation: :awaiting"

      bare = MergeConfirmation.request(issue(%{title: nil, state: nil}), parts(%{pr: "https://gitlab.example.com/acme/web/-/merge_requests/7"}))
      assert bare.question == "Merge TP-825 into its base branch?"
      assert bare.if_unanswered == "TP-825 waits and is not merged."
      refute bare.why =~ "PR"
    end

    test "confirm_target/1 resolves the move a question carries, and nil for one that carries none" do
      assert MergeConfirmation.confirm_target(%{confirm: "Merging"}) == "Merging"

      assert MergeConfirmation.confirm_target(%{title: "Ordinary", confirm: nil}) == nil
      assert MergeConfirmation.confirm_target(%{title: "Ordinary"}) == nil
      assert MergeConfirmation.confirm_target(nil) == nil
    end
  end

  describe "summary/3" do
    test "fills the reviewer's own reason and the ticket's PR in from the ticket" do
      :ok =
        TicketSignals.record(@repo_key, @issue_id, "code_review", %{
          verdict: "approve",
          review_reason: "it is a one-line docs fix"
        })

      :ok = TicketPullRequest.record_created(@repo_key, @issue_id, "https://github.com/acme/web/pull/7", "auto/TP-825")
      summary = MergeConfirmation.summary(issue(), opts(), parts(%{review: nil}))
      assert summary.review == "it is a one-line docs fix"
      assert summary.pr == "https://github.com/acme/web/pull/7"
    end

    test "the caller's review and pr win, and a signal without a reason is not one" do
      :ok = TicketSignals.record(@repo_key, @issue_id, "code_review", %{verdict: "approve"})

      summary = MergeConfirmation.summary(issue(), opts(pr_url: "https://example.test/9"), parts(%{review: "mine"}))
      assert summary.review == "mine"
      assert summary.pr == "https://example.test/9"

      assert MergeConfirmation.summary(issue(), opts(), parts(%{review: nil})).review == nil
      assert MergeConfirmation.summary(issue(), opts(), parts(%{review: nil})).pr == nil
    end

    test "links the PR Symphony recorded for the ticket; a finished one links nothing" do
      pr_url = "https://github.com/acme/web/pull/8"
      :ok = TicketPullRequest.record_created(@repo_key, @issue_id, pr_url, "auto/TP-825")

      assert MergeConfirmation.summary(issue(), opts(), parts()).pr == pr_url
      # A ticket read without its repo is looked up under the caller's.
      assert MergeConfirmation.summary(issue(%{repo_key: nil}), opts(), parts()).pr == pr_url

      for state <- ["closed", "merged"] do
        :ok = TicketPullRequest.record_created(@repo_key, @issue_id, pr_url, "auto/TP-825")
        :ok = TicketPullRequest.mark_finished(@repo_key, pr_url, state)
        assert MergeConfirmation.summary(issue(), opts(), parts()).pr == nil
      end
    end

    test "a ticket with no recorded PR falls back to the caller's PR" do
      summary = MergeConfirmation.summary(issue(), opts(pr_url: "https://example.test/9"), parts())
      assert summary.pr == "https://example.test/9"
    end

    test "reads the reviewer's reason from the newest signal" do
      :ok = TicketSignals.record(@repo_key, @issue_id, "code_review", %{verdict: "rework", reason: "older"})
      :ok = TicketSignals.record(@repo_key, @issue_id, "code_review", %{verdict: "approve", reason: "newer"})

      assert MergeConfirmation.summary(issue(), opts(), parts(%{review: nil})).review == "newer"
      assert Handoff.signals(@repo_key, @issue_id) |> hd() |> Map.fetch!(:name) == "code_review"
    end
  end

  describe "pause/3" do
    test "posts the decision request and asks the question that confirming continues from" do
      log = capture_log(fn -> assert MergeConfirmation.pause(issue(), opts(), MergeConfirmation.summary(issue(), opts(), parts())) == :ok end)

      assert_received {:comment, @issue_id, body}
      assert body =~ "## Decision needed:"
      assert body =~ "Merge TP-825 (T) into its base branch?"
      assert body =~ "Recommendation: QA passed on 12 files"
      # The ticket is told it keeps its phase, as a hold's request does.
      assert body =~ "the ticket stays in QA until the decision is recorded"

      assert %{question: "Merge TP-825 (T) into its base branch?", request: true} = deciding()
      assert MergeConfirmation.confirm_target(deciding()) == "Merging"
      assert log =~ "manual review is on, so the step into Merging waits"
      # The question is asked through the Question service: one open Question with what was asked.
      assert [%{id: id, title: "Merge TP-825", question: "Merge TP-825 (T) into its base branch?", confirm: "Merging", options: [_merge, _rework]}] =
               Questions.open({:ticket, @repo_key, @issue_id})

      assert %{id: ^id} = deciding()
      assert [{"question.asked", %{title: "Merge TP-825", confirm: "Merging"}}, {"pause.set", %{reason: "question"}}] = ticket_events(@repo_key, @issue_id)
    end

    test "round-trips through Request.parse, as Linear reads its own comment back" do
      request = MergeConfirmation.request(issue(), parts())
      parsed = request |> Request.render_hold("QA") |> Request.parse(DateTime.utc_now())

      assert parsed.title == "Merge TP-825"
      assert parsed.question == "Merge TP-825 (T) into its base branch?"
      assert length(parsed.options) == 2
      assert Enum.any?(parsed.options, &(&1 =~ "Merge"))
    end

    test "a failed comment is reported and leaves the question asked, its comment waiting for the Inbox" do
      Application.put_env(:symphony_elixir, :merge_confirmation_comment_result, {:error, :rate_limited})

      capture_log(fn ->
        assert {:error, {:merge_confirmation_request_failed, :rate_limited}} =
                 MergeConfirmation.pause(issue(), opts(), parts())
      end)

      assert [%{id: id}] = Questions.open({:ticket, @repo_key, @issue_id})
      assert %{id: ^id} = deciding()
    end

    test "a question that can't be asked is reported, and nothing is posted, so a retry posts the request once" do
      capture_log(fn ->
        assert {:error, {:merge_confirmation_hold_failed, :missing_repo_key}} =
                 MergeConfirmation.pause(issue(%{repo_key: nil}), [tracker: CommentTracker], parts())
      end)

      refute_received {:comment, @issue_id, _body}
    end
  end

  describe "picked/2" do
    # The options as Linear's comment reads them back: rendered lines, not the tool's maps.
    defp ci_hold do
      %{
        confirm: "Rework",
        options: [
          "**Send to Rework** (recommended): the ticket moves to Rework, where a run makes the fix",
          "**Leave it**: the ticket stays in its phase with red CI",
          "a hand-written line",
          :unreadable,
          %{"label" => nil, "effect" => nil}
        ]
      }
    end

    defp merge_hold do
      %{
        confirm: "Merging",
        options: [
          %{label: "Merge", effect: "the ticket moves to Merging"},
          %{label: "Send to Rework", effect: "the ticket moves to Rework"}
        ]
      }
    end

    test "an answer picks the option its number or label opens with" do
      assert MergeConfirmation.picked(ci_hold(), ["send to rework please"]) == {:ok, "Rework"}
      assert MergeConfirmation.picked(ci_hold(), ["Option 2"]) == {:ok, nil}
      assert MergeConfirmation.picked(ci_hold(), ["Leave it for now", "2"]) == {:ok, nil}
    end

    test "picked_option names the one option among labels an answer picks, by number or label" do
      labels = ["Proceed without it for this PR", "Rerun the checks", "Fix the workflow in Rework"]
      assert MergeConfirmation.picked_option(labels, ["**Rerun the checks**"]) == 2
      assert MergeConfirmation.picked_option(labels, ["option 3"]) == 3
      assert MergeConfirmation.picked_option(labels, ["1", "proceed without it for this PR."]) == 1
      assert MergeConfirmation.picked_option(labels, ["1", "2"]) == nil
      assert MergeConfirmation.picked_option(labels, ["rerun them all"]) == nil
      assert MergeConfirmation.picked_option(labels, []) == nil
    end

    test "nothing is picked by free text, a longer word, conflicting answers or no hold" do
      assert MergeConfirmation.picked(ci_hold(), ["Neither: leave it alone", nil]) == :none
      assert MergeConfirmation.picked(ci_hold(), ["12 is the count"]) == :none
      assert MergeConfirmation.picked(ci_hold(), ["1", "2"]) == :none
      assert MergeConfirmation.picked(nil, ["1"]) == :none
    end

    test "a confirmation question's own option continues into its move" do
      assert MergeConfirmation.picked(merge_hold(), ["Merge."]) == {:ok, "Merging"}
      assert MergeConfirmation.picked(merge_hold(), ["Send to Rework"]) == {:ok, "Rework"}
      assert MergeConfirmation.picked(merge_hold(), ["Merge conflicts remain, fix first"]) == :none
    end
  end
end
