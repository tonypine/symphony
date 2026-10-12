defmodule SymphonyElixir.MergeConfirmationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Handoff, Hold, MergeConfirmation, RunStore, TicketSignals, Workflow}
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Linear.Issue

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

  defmodule FailingStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :boom}
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :boom}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
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

  defp stored_hold, do: Hold.get(@repo_key, @issue_id, :needs_decision)

  describe "request/2 and attrs/1" do
    test "the request names the merge, carries the summary and offers confirming or redirecting" do
      summary = MergeConfirmation.summary(issue(), opts(), parts(%{pr: "https://github.com/acme/web/pull/7"}))
      request = MergeConfirmation.request(issue(), summary)

      assert request.title == "Merge TP-825"
      assert request.question == "Merge TP-825 into its base branch?"
      assert request.est_minutes == 1

      assert request.why ==
               "Recommendation: QA passed on 12 files · Code Review: the reviewer approved · QA: all checks green · " <>
                 "PR: https://github.com/acme/web/pull/7"

      assert [merge, rework] = request.options
      assert %{label: "Merge", recommended: true} = merge
      assert merge.effect =~ "Merging"
      assert %{label: "Send to Rework", recommended: false} = rework
      assert rework.effect =~ "Rework"
      assert rework.effect =~ "https://github.com/acme/web/pull/7"
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
      assert request.question == "Merge \"issue-1\" into its base branch?"
      assert request.why =~ "Recommendation: :awaiting"
    end

    test "the attrs are the decision payload plus the move confirming performs" do
      request = MergeConfirmation.request(issue(), parts())
      attrs = MergeConfirmation.attrs(request)

      assert attrs.reason == "Merge TP-825 into its base branch?"
      assert attrs.clearing_condition == "when the decision is recorded"
      assert attrs.decision.question == "Merge TP-825 into its base branch?"
      assert attrs.decision.confirm == "Merging"
      assert [%{label: "Merge", recommended: true}, %{label: "Send to Rework", recommended: false}] = attrs.decision.options
    end

    test "confirm_target/1 resolves the carried move, and nil for a hold that carries none" do
      hold = %{kind: :needs_decision, decision: %{confirm: "Merging"}}
      assert MergeConfirmation.confirm_target(hold) == "Merging"

      assert MergeConfirmation.confirm_target(%{kind: :needs_decision, decision: %{title: "Ordinary"}}) == nil
      assert MergeConfirmation.confirm_target(%{kind: :needs_decision}) == nil
      assert MergeConfirmation.confirm_target(nil) == nil
    end

    test "the attrs unknown to a decision are kept through the store round trip" do
      attrs = MergeConfirmation.attrs(MergeConfirmation.request(issue(), parts()))
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, attrs)

      # The Inbox sweep compares only the title and question, so a rewritten request keeps the move.
      assert MergeConfirmation.confirm_target(stored_hold()) == "Merging"
    end
  end

  describe "summary/3" do
    test "fills the reviewer's own reason and the ticket's PR in from the ticket" do
      :ok =
        TicketSignals.record(@repo_key, @issue_id, "code_review", %{
          verdict: "approve",
          review_reason: "it is a one-line docs fix"
        })

      summary = MergeConfirmation.summary(issue(%{pr_urls: ["https://github.com/acme/web/pull/7"]}), opts(), parts(%{review: nil}))
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

    test "an issue carrying no PR list falls back to the caller's PR" do
      summary = MergeConfirmation.summary(issue(%{pr_urls: nil}), opts(pr_url: "https://example.test/9"), parts())
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
    test "posts the decision request and sets the hold that confirming continues from" do
      log = capture_log(fn -> assert MergeConfirmation.pause(issue(), opts(), MergeConfirmation.summary(issue(), opts(), parts())) == :ok end)

      assert_received {:comment, @issue_id, body}
      assert body =~ "## Decision needed:"
      assert body =~ "Merge TP-825 into its base branch?"
      assert body =~ "Recommendation: QA passed on 12 files"
      # The ticket is told it keeps its phase, as a hold's request does.
      assert body =~ "the ticket stays in QA until the decision is recorded"

      assert %{reason: "Merge TP-825 into its base branch?"} = stored_hold()
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert MergeConfirmation.confirm_target(stored_hold()) == "Merging"
      assert log =~ "manual review is on, so the step into Merging waits"
    end

    test "round-trips through Request.parse, as Linear reads its own comment back" do
      request = MergeConfirmation.request(issue(), parts())
      parsed = request |> Request.render_hold("QA") |> Request.parse(DateTime.utc_now())

      assert parsed.title == "Merge TP-825"
      assert parsed.question == "Merge TP-825 into its base branch?"
      assert length(parsed.options) == 2
      assert Enum.any?(parsed.options, &(&1 =~ "Merge"))
    end

    test "a failed comment is reported and leaves no hold behind" do
      Application.put_env(:symphony_elixir, :merge_confirmation_comment_result, {:error, :rate_limited})

      assert {:error, {:merge_confirmation_request_failed, :rate_limited}} =
               MergeConfirmation.pause(issue(), opts(), parts())

      refute Hold.held_any?(@repo_key, @issue_id)
    end

    test "a failed hold write is reported" do
      assert {:error, {:merge_confirmation_hold_failed, :boom}} =
               MergeConfirmation.pause(issue(), opts(store: FailingStore), parts())

      assert_received {:comment, @issue_id, _body}
    end
  end
end
