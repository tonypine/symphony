defmodule SymphonyElixir.DecisionRequestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DecisionRequest, Hold, MergeConfirmation, NeedsDecisionHold, Pauses, Questions, RunStore}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{TicketState, Workflow}

  @repo_key "repo-a"
  @issue_id "issue-1"
  @ticket {:ticket, @repo_key, @issue_id}

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
    test "asks the Question first, then sets the hold carrying it and posts the comment naming it" do
      assert :ok = DecisionRequest.ask(issue(%{state: "Code Review"}), request(), [tracker: CommentTracker], "QA")

      assert [question] = Questions.open(@ticket)

      assert %{
               id: id,
               title: "Add the release signing secrets",
               question: "Add the signing secrets, or ship unsigned builds?",
               confirm: "QA",
               asked_by: %{kind: :symphony},
               options: [%{label: "Add the secrets", recommended?: true, good: ["No warning on launch."]}, %{label: "Ship unsigned"}]
             } = question

      assert {:ok, %{reasons: [%{kind: :question, waits_on: %{question_id: ^id}}]}} = Pauses.get(@ticket)

      assert_received {:commented, @issue_id, body}
      assert body =~ "the ticket stays in Code Review until the decision is recorded"
      assert String.ends_with?(body, "\n\n<!-- symphony:question #{id} -->")
      assert %{decision: %{question_id: ^id}} = hold = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert MergeConfirmation.confirm_target(hold) == "QA"

      # The Question's event is the request: no `decision.requested` beside it.
      assert [{"question.asked", %{title: "Add the release signing secrets", confirm: "QA", question_id: ^id}}, {"pause.set", _pause}] =
               ticket_events(@repo_key, @issue_id)
    end

    test "names who asks" do
      assert :ok = DecisionRequest.ask(issue(), request(), tracker: CommentTracker, asked_by: %{kind: :run, name: "The run"})
      assert [%{asked_by: %{kind: :run, name: "The run"}}] = Questions.open(@ticket)
    end

    test "the same question asked again is one Question and one comment" do
      assert :ok = DecisionRequest.ask(issue(), request(), tracker: CommentTracker)
      assert_received {:commented, @issue_id, _body}

      assert :ok = DecisionRequest.ask(issue(), request(), tracker: CommentTracker)
      refute_received {:commented, _issue_id, _body}
      assert [_question] = Questions.open(@ticket)
      assert [{"question.asked", _asked}, {"pause.set", _pause}] = ticket_events(@repo_key, @issue_id)
    end

    test "a custom post asked the same question again answers :ok and posts nothing" do
      post = fn body ->
        send(self(), {:posted, body})
        {:ok, %{"commentId" => "comment-9"}}
      end

      assert {:ok, %{"commentId" => "comment-9"}} = DecisionRequest.ask(issue(), request(), post: post, label_tracker: CommentTracker)
      assert :ok = DecisionRequest.ask(issue(), request(), post: post, label_tracker: CommentTracker)
      assert_received {:posted, _body}
      refute_received {:posted, _body}
    end

    test "a ticket with no repo key is refused before anything is written" do
      log =
        capture_log(fn ->
          assert {:error, {:decision_hold_failed, :missing_repo_key}} = DecisionRequest.ask(issue(%{repo_key: nil}), request(), tracker: CommentTracker)
        end)

      assert log =~ "Refused a hold write on issue_id=#{@issue_id} with no repo key"
      refute_received {:commented, _issue_id, _body}
      assert Questions.open(@ticket) == []
    end

    test "a request the Question service refuses sets no hold and posts nothing" do
      assert {:error, {:decision_hold_failed, {:invalid_subject, {:ticket, @repo_key, " "}}}} =
               DecisionRequest.ask(issue(%{id: " "}), request(), tracker: CommentTracker)

      refute_received {:commented, _issue_id, _body}
      assert Hold.get(@repo_key, " ", :needs_decision) == nil
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

    test "a request that can't be posted takes nothing back: its comment waits for the Inbox's sweep" do
      Process.put(:ask_comment_result, {:error, :rate_limited})

      log =
        capture_log(fn ->
          assert {:error, {:decision_request_failed, :rate_limited}} = DecisionRequest.ask(issue(), request(), tracker: CommentTracker)
        end)

      assert log =~ "Failed to post the decision request on issue_id=#{@issue_id}; the question stays open and the Inbox posts it"
      assert [%{id: id}] = Questions.open(@ticket)
      assert %{decision: %{question_id: ^id}} = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert [%{type: :question_comment, question: ^id, error: ":rate_limited"}] = pending_projection()
      assert [{"question.asked", _asked}, {"pause.set", _pause}] = ticket_events(@repo_key, @issue_id)

      # Asked again, it is the same question, whose comment is already waiting: nothing is posted.
      Process.delete(:ask_comment_result)
      assert_received {:commented, @issue_id, _body}
      assert :ok = DecisionRequest.ask(issue(), request(), tracker: CommentTracker)
      refute_received {:commented, _issue_id, _body}
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

  describe "repost/5" do
    test "posts a comment whose post failed, rendered from the Question as it was asked, and drops its mark" do
      Process.put(:ask_comment_result, {:error, :linear_down})
      capture_log(fn -> DecisionRequest.ask(issue(%{state: "Code Review"}), request(), tracker: CommentTracker) end)
      assert_received {:commented, @issue_id, asked_body}
      hold = Hold.get(@repo_key, @issue_id, :needs_decision)

      # Linear is still down.
      log = capture_log(fn -> assert :pending = DecisionRequest.repost(@repo_key, @issue_id, hold, "Code Review", tracker: CommentTracker) end)
      assert log =~ "Failed again to post the decision request on issue_id=#{@issue_id}: :linear_down"
      assert_received {:commented, @issue_id, ^asked_body}
      assert [_mark] = pending_projection()

      Process.delete(:ask_comment_result)
      assert :posted = DecisionRequest.repost(@repo_key, @issue_id, hold, "Code Review", tracker: CommentTracker)
      assert_received {:commented, @issue_id, ^asked_body}
      assert pending_projection() == []

      assert :none = DecisionRequest.repost(@repo_key, @issue_id, hold, "Code Review", tracker: CommentTracker)
      refute_received {:commented, _issue_id, _body}
    end

    test "a question no longer open has nothing to post: its mark is dropped" do
      Process.put(:ask_comment_result, {:error, :linear_down})
      capture_log(fn -> DecisionRequest.ask(issue(), request(), tracker: CommentTracker) end)
      assert_received {:commented, @issue_id, _body}
      hold = Hold.get(@repo_key, @issue_id, :needs_decision)
      [%{id: id}] = Questions.open(@ticket)
      {:ok, _withdrawn} = Questions.withdraw(@ticket, id, "Not needed any more.")

      assert :none = DecisionRequest.repost(@repo_key, @issue_id, hold, "In Progress", tracker: CommentTracker)
      refute_received {:commented, _issue_id, _body}
      assert pending_projection() == []
    end

    test "a hold that carries no question, or no pending comment, posts nothing" do
      assert :none = DecisionRequest.repost(@repo_key, @issue_id, nil, "In Progress", tracker: CommentTracker)
      assert :none = DecisionRequest.repost(@repo_key, @issue_id, %{decision: %{title: "Old"}}, "In Progress", tracker: CommentTracker)
      assert :none = DecisionRequest.repost(@repo_key, @issue_id, %{decision: %{question_id: "q-1"}}, "In Progress", tracker: CommentTracker)

      assert :ok = DecisionRequest.ask(issue(), request(), tracker: CommentTracker)
      assert :none = DecisionRequest.repost(@repo_key, @issue_id, Hold.get(@repo_key, @issue_id, :needs_decision), "In Progress", tracker: CommentTracker)
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

  defp pending_projection, do: TicketState.normalize(RunStore.get_ticket_state(@repo_key, @issue_id)).pending_projection
end
