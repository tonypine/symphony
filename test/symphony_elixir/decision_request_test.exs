defmodule SymphonyElixir.DecisionRequestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DecisionRequest, MergeConfirmation, Pauses, Questions, RunStore}
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.{TicketState, Workflow}

  @repo_key "repo-a"
  @issue_id "issue-1"
  @ticket {:ticket, @repo_key, @issue_id}

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
    write_workflow_file!(Workflow.workflow_file_path())
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
    test "asks the Question, which pauses the ticket, and posts the comment naming it" do
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
      assert %{id: ^id} = deciding = Questions.deciding(@ticket)
      assert MergeConfirmation.confirm_target(deciding) == "QA"

      # The Question's event is the request: no `decision.requested` beside it.
      assert [{"question.asked", %{title: "Add the release signing secrets", confirm: "QA", question_id: ^id}}, {"pause.set", _pause}] =
               ticket_events(@repo_key, @issue_id)
    end

    test "a different question asked while another is open is a second Question, and both stay open" do
      older = request(%{title: "Older", question: "Older?"})
      assert :ok = DecisionRequest.ask(issue(), older, tracker: CommentTracker)
      assert :ok = DecisionRequest.ask(issue(), request(%{title: "Newer", question: "Newer?"}), tracker: CommentTracker)

      assert [%{id: older_id, title: "Older"}, %{id: newer_id, title: "Newer"}] = Questions.open(@ticket)
      assert_received {:commented, @issue_id, _older_body}
      assert_received {:commented, @issue_id, _newer_body}
      assert %{id: ^newer_id} = Questions.deciding(@ticket)

      # Answering the newer one leaves the older one as the one the ticket waits on.
      assert {:ok, _answered} = Questions.answer(@ticket, newer_id, "Newer it is")
      assert %{id: ^older_id} = Questions.deciding(@ticket)
      assert ["question.asked", "pause.set", "question.asked", "pause.reason_added", "question.answered", "pause.reason_cleared"] = Enum.map(ticket_events(@repo_key, @issue_id), &elem(&1, 0))
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

      assert {:ok, %{"commentId" => "comment-9"}} = DecisionRequest.ask(issue(), request(), post: post)
      assert :ok = DecisionRequest.ask(issue(), request(), post: post)
      assert_received {:posted, _body}
      refute_received {:posted, _body}
    end

    test "a ticket with no repo key is refused before anything is written" do
      log =
        capture_log(fn ->
          assert {:error, {:decision_hold_failed, :missing_repo_key}} = DecisionRequest.ask(issue(%{repo_key: nil}), request(), tracker: CommentTracker)
        end)

      assert log =~ "Refused a decision request on issue_id=#{@issue_id} with no repo key"
      refute_received {:commented, _issue_id, _body}
      assert Questions.open(@ticket) == []
    end

    test "a request the Question service refuses asks nothing and posts nothing" do
      assert {:error, {:decision_hold_failed, {:invalid_subject, {:ticket, @repo_key, " "}}}} =
               DecisionRequest.ask(issue(%{id: " "}), request(), tracker: CommentTracker)

      refute_received {:commented, _issue_id, _body}
      assert Questions.open({:ticket, @repo_key, " "}) == []
    end

    test "without a confirmation the ticket continues in place once decided" do
      assert :ok = DecisionRequest.ask(issue(), request(), tracker: CommentTracker)

      assert %{confirm: nil} = deciding = Questions.deciding(@ticket)
      assert MergeConfirmation.confirm_target(deciding) == nil
    end

    test "refuses a request that misses the standard: nothing is posted and nothing is asked" do
      log =
        capture_log(fn ->
          assert {:error, {:invalid_decision_request, "`if_unanswered` must say what waits or repeats until someone answers."}} =
                   DecisionRequest.ask(issue(), request(%{if_unanswered: nil}), tracker: CommentTracker)
        end)

      assert log =~ "Refused a decision request on issue_id=#{@issue_id} that misses the standard"
      refute_received {:commented, _issue_id, _body}
      assert Questions.open(@ticket) == []
      assert ticket_events(@repo_key, @issue_id) == []
    end

    test "a request that can't be posted takes nothing back: its comment is marked pending" do
      Process.put(:ask_comment_result, {:error, :rate_limited})

      log =
        capture_log(fn ->
          assert {:error, {:decision_request_failed, :rate_limited}} = DecisionRequest.ask(issue(), request(), tracker: CommentTracker)
        end)

      assert log =~ "Failed to post the decision request on issue_id=#{@issue_id}; the question stays open"
      assert [%{id: id}] = Questions.open(@ticket)
      assert [%{type: :question_comment, question: ^id, error: ":rate_limited"}] = pending_projection()
      assert [{"question.asked", _asked}, {"pause.set", _pause}] = ticket_events(@repo_key, @issue_id)

      # Asked again, it is the same question, whose comment is already waiting: nothing is posted.
      Process.delete(:ask_comment_result)
      assert_received {:commented, @issue_id, _body}
      assert :ok = DecisionRequest.ask(issue(), request(), tracker: CommentTracker)
      refute_received {:commented, _issue_id, _body}
    end

    test "a custom post answers what it posted" do
      post = fn body ->
        send(self(), {:posted, body})
        {:ok, %{"commentId" => "comment-9"}}
      end

      assert {:ok, %{"commentId" => "comment-9"}} = DecisionRequest.ask(issue(), request(), post: post)
      assert_received {:posted, "## Decision needed: Add the release signing secrets" <> _rest}
    end
  end

  describe "question_id/1" do
    test "reads the Question a request comment's hidden line names" do
      assert DecisionRequest.question_id("## Decision needed: X\n\n<!-- symphony:question 01QUESTION -->") == "01QUESTION"
      assert DecisionRequest.question_id("## Decision needed: X") == nil
      assert DecisionRequest.question_id(nil) == nil
    end
  end

  describe "while the pause projector owns the request comment (TP-1252)" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue(%{state: "Code Review"})])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :pause_projector, true)

      on_exit(fn ->
        Application.put_env(:symphony_elixir, :pause_projector, false)

        for key <- [:memory_tracker_issues, :memory_tracker_recipient, :memory_tracker_create_comment_result],
            do: Application.delete_env(:symphony_elixir, key)
      end)
    end

    test "asking posts nothing itself: the projector posts the comment once, byte for byte as asking posted it" do
      assert :ok = DecisionRequest.ask(issue(%{state: "Code Review"}), request(), [tracker: CommentTracker], "QA")
      [%{id: id} = question] = Questions.open(@ticket)
      assert %{request: true, asked_in: "Code Review"} = question

      expected = Request.render_hold(request(), "Code Review") <> "\n\n<!-- symphony:question #{id} -->"
      refute_received {:commented, _issue_id, _body}
      assert_received {:memory_tracker_comment, @issue_id, ^expected}
      assert %{id: ^id} = Questions.deciding(@ticket)

      assert :ok = DecisionRequest.ask(issue(%{state: "Code Review"}), request(), [tracker: CommentTracker], "QA")
      refute_received {:memory_tracker_comment, _issue_id, _body}
      refute_received {:commented, _issue_id, _body}
    end

    test "a comment Linear refused stays pending on the record, and the projector posts it once Linear answers" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :linear_down})
      capture_log(fn -> assert :ok = DecisionRequest.ask(issue(), request(), tracker: CommentTracker) end)
      refute_received {:memory_tracker_comment, _issue_id, _body}
      assert [%{type: :pause}] = pending_projection()

      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result)
      assert :ok = Projector.project_now(@ticket)
      assert_received {:memory_tracker_comment, @issue_id, _body}
      assert :ok = Projector.project_now(@ticket)
      refute_received {:memory_tracker_comment, _issue_id, _body}
      refute_received {:commented, _issue_id, _body}
    end
  end

  defp pending_projection, do: TicketState.normalize(RunStore.get_ticket_state(@repo_key, @issue_id)).pending_projection
end
