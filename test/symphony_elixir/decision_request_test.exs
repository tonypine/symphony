defmodule SymphonyElixir.DecisionRequestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DecisionRequest, Hold, MergeConfirmation, NeedsDecisionHold, RunStore, Workflow}
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-a"
  @issue_id "issue-1"

  defmodule FailingStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :boom}
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :boom}
  end

  defmodule CommentTracker do
    def create_comment(issue_id, body) do
      send(self(), {:commented, issue_id, body})
      Process.get(:ask_comment_result, :ok)
    end

    def set_machine_label(issue_id, name) do
      send(self(), {:labelled, issue_id, name})
      :ok
    end

    def clear_machine_label(_issue_id, _name), do: :ok
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok = RunStore.clear()
    on_exit(fn -> Process.delete(:ask_comment_result) end)
    :ok
  end

  defp issue(attrs \\ %{}) do
    struct!(%Issue{id: @issue_id, identifier: "TP-818", title: "T", state: "In Progress", repo_key: @repo_key}, attrs)
  end

  defp request(attrs \\ %{}) do
    Map.merge(
      %{
        title: "Add the release signing secrets",
        question: "Add the signing secrets, or ship unsigned builds?",
        why: "Every Release run on main fails without them.",
        if_unanswered: "Every Release run on main keeps failing.",
        options: [
          %{label: "Add the secrets", effect: "Releases are signed again.", recommended: true, tradeoffs: [%{kind: "good", text: "No warning on launch."}]},
          %{label: "Ship unsigned", effect: "The agent drops the signing step."}
        ],
        recommendation_reason: "Signing is a one-time setup."
      },
      attrs
    )
  end

  describe "check/1" do
    test "passes a request that meets the standard" do
      assert DecisionRequest.check(request()) == :ok
    end

    test "refuses each part of the standard a request misses, naming the field" do
      option = fn attrs -> Map.merge(%{label: "Keep it", effect: "Nothing changes."}, attrs) end
      four = List.duplicate(%{kind: "good", text: "x"}, 4)
      tradeoffs = "Each option's `tradeoffs` lists at most 3, each with a `kind` (good, cost, risk) and a non-blank `text`."
      options = "`decision.options` must list 2 to 4 options, each with a `label` and an `effect`; with no real choice to make, there is nothing to ask a person."

      for {attrs, message} <- [
            {%{title: nil}, "`title` must say the decision in a few words."},
            {%{title: String.duplicate("a", 121)}, "`title` must be at most 120 characters."},
            {%{question: " "}, "`decision.question` must ask the one question the person answers."},
            {%{why: nil}, "`why` must say what happened and why it needs a person."},
            {%{options: nil}, options},
            {%{options: [option.(%{recommended: true})]}, options},
            {%{options: [option.(%{recommended: true}), "Keep it"]}, "Each of `decision.options` needs a non-blank `label` and `effect`."},
            {%{options: [option.(%{recommended: true}), option.(%{effect: " "})]}, "Each of `decision.options` needs a non-blank `label` and `effect`."},
            {%{options: [option.(%{}), option.(%{})]}, "Exactly one of `decision.options` must be `recommended`."},
            {%{options: [option.(%{recommended: true, tradeoffs: "cheap"}), option.(%{})]}, tradeoffs},
            {%{options: [option.(%{recommended: true, tradeoffs: four}), option.(%{})]}, tradeoffs},
            {%{options: [option.(%{recommended: true, tradeoffs: [%{kind: "nice", text: "x"}]}), option.(%{})]}, tradeoffs},
            {%{options: [option.(%{recommended: true, tradeoffs: ["cheap"]}), option.(%{})]}, tradeoffs},
            {%{if_unanswered: nil}, "`if_unanswered` must say what waits or repeats until someone answers."},
            {%{recommendation_reason: " "}, "`decision.recommendation_reason` must say in one line why the recommended option is the one to pick."}
          ] do
        assert DecisionRequest.check(request(attrs)) == {:error, message}, inspect(attrs)
      end
    end

    test "refuses code and Symphony's internal words, as the agent tool does" do
      assert {:error, message} = DecisionRequest.check(request(%{why: "The PR head 2f5af5ab failed.", if_unanswered: "The hold stays."}))
      assert message =~ "`why` has the internal word \"head\", the commit hash \"2f5af5ab\"; `if_unanswered` has the internal word \"hold\""
    end
  end

  describe "ask/4" do
    test "posts the request, rendered to stay in the phase, and sets the hold with its confirmation" do
      assert :ok = DecisionRequest.ask(issue(%{state: "Code Review"}), request(), [tracker: CommentTracker], "QA")

      assert_received {:commented, @issue_id, body}
      assert body =~ "the ticket stays in Code Review until the decision is recorded"
      assert MergeConfirmation.confirm_target(Hold.get(@repo_key, @issue_id, :needs_decision)) == "QA"
      assert [{"decision.requested", %{title: "Add the release signing secrets", confirm: "QA"}}] = ticket_events(@repo_key, @issue_id)
    end

    test "without a confirmation the ticket continues in place once decided" do
      assert :ok = DecisionRequest.ask(issue(), request(), tracker: CommentTracker)

      assert %{decision: decision} = Hold.get(@repo_key, @issue_id, :needs_decision)
      refute Map.has_key?(decision, :confirm)
    end

    test "refuses a request that misses the standard: nothing is posted and no hold is set" do
      log =
        capture_log(fn ->
          assert {:error, {:invalid_decision_request, "`if_unanswered` must say what waits or repeats until someone answers."}} =
                   DecisionRequest.ask(issue(), request(%{if_unanswered: nil}), tracker: CommentTracker)
        end)

      assert log =~ "Refused a decision request on issue_id=#{@issue_id} that misses the standard"
      refute_received {:commented, _issue_id, _body}
      assert Hold.get(@repo_key, @issue_id, :needs_decision) == nil
      assert ticket_events(@repo_key, @issue_id) == []
    end

    test "a request that can't be posted takes the hold back" do
      Process.put(:ask_comment_result, {:error, :rate_limited})
      assert {:error, {:decision_request_failed, :rate_limited}} = DecisionRequest.ask(issue(), request(), tracker: CommentTracker)
      assert Hold.get(@repo_key, @issue_id, :needs_decision) == nil

      assert [%{type: "decision.requested", id: request_id}, %{type: "decision.withdrawn", payload: %{request: request_id}}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, [])
    end

    test "a hold that can't be set posts nothing, so the retry posts the comment once" do
      assert {:error, {:decision_hold_failed, :boom}} =
               DecisionRequest.ask(issue(), request(), tracker: CommentTracker, store: FailingStore, repo_key: @repo_key)

      refute_received {:commented, _issue_id, _body}

      assert :ok = DecisionRequest.ask(issue(), request(), tracker: CommentTracker)
      assert_received {:commented, @issue_id, _body}
      refute_received {:commented, _issue_id, _body}
      assert Hold.get(@repo_key, @issue_id, :needs_decision)
    end

    test "a custom post answers what it posted, and the label goes through the label tracker" do
      post = fn body ->
        send(self(), {:posted, body})
        {:ok, %{"commentId" => "comment-9"}}
      end

      assert {:ok, %{"commentId" => "comment-9"}} = DecisionRequest.ask(issue(), request(), post: post, label_tracker: CommentTracker)
      assert_received {:posted, "## Decision needed: Add the release signing secrets" <> _rest}
      assert_received {:labelled, @issue_id, "Needs Decision"}
    end
  end

  describe "project/4" do
    test "sets the hold again for a request already posted, without checking it" do
      attrs = NeedsDecisionHold.attrs(request(%{if_unanswered: nil}))

      assert :ok = DecisionRequest.project(@repo_key, @issue_id, attrs, tracker: CommentTracker)
      assert %{decision: %{title: "Add the release signing secrets"}} = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert_received {:labelled, @issue_id, "Needs Decision"}
    end
  end
end
