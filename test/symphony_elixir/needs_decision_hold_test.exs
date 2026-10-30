defmodule SymphonyElixir.NeedsDecisionHoldTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  alias SymphonyElixir.{
    DecisionMove,
    DecisionRequest,
    Hold,
    MergeConfirmation,
    NeedsDecisionHold,
    Questions,
    RunStore,
    Workflow
  }

  alias SymphonyElixir.HumanActions.{Collector, Request}
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-a"
  @issue_id "issue-1"
  @comment_id "comment-1"

  defmodule FailingStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :boom}
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :boom}
  end

  # Reads succeed (through the real store) but writes fail, so a clear can be driven into its
  # failure path without losing the hold the read needs.
  defmodule ReadOnlyStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :boom}
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
    def get_ticket_state(repo_key, issue_id), do: RunStore.get_ticket_state(repo_key, issue_id)
  end

  # Everything goes through the real store but clearing a Blocked hold, so the decision's own clear
  # lands and the `handoff_missing` hold it lifts too is driven into its failure path.
  defmodule BlockedClearFailsStore do
    def set_ticket_hold(repo_key, issue_id, kind, attrs), do: RunStore.set_ticket_hold(repo_key, issue_id, kind, attrs)
    def clear_ticket_hold(_repo_key, _issue_id, :blocked), do: {:error, :boom}
    def clear_ticket_hold(repo_key, issue_id, kind), do: RunStore.clear_ticket_hold(repo_key, issue_id, kind)
    def get_ticket_state(repo_key, issue_id), do: RunStore.get_ticket_state(repo_key, issue_id)
  end

  # The labels project fine; only the move a confirmation performs fails, so a clear reaches the
  # continue and is driven into its failure path.
  defmodule FailingMoveTracker do
    def set_machine_label(_issue_id, _name), do: :ok
    def clear_machine_label(_issue_id, _name), do: :ok
    def update_issue_state(_issue_id, _state), do: {:error, :rate_limited}
    def fetch_issue_description(_issue_id), do: {:ok, nil}
    def update_issue_description(_issue_id, _description), do: :ok
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    :ok = RunStore.clear()
    :ok
  end

  defp designed_settings do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    settings
  end

  defp issue(attrs \\ %{}) do
    struct!(%Issue{id: @issue_id, identifier: "TP-818", title: "T", state: "In Progress", repo_key: @repo_key}, attrs)
  end

  # The request as the tool builds it from the agent's attrs: what `Request.render_hold/2` renders.
  defp request(attrs \\ %{}) do
    Map.merge(
      %{
        title: "Add the release signing secrets",
        question: "Add the signing secrets, or ship unsigned builds?",
        why: "Every Release run on main fails without them.",
        unblocks: "the Release workflow on main",
        if_unanswered: "Every Release run on main keeps failing.",
        options: [%{label: "Add the secrets", effect: "Releases are signed again.", recommended: true}, %{label: "Ship unsigned", effect: "The agent drops the signing step."}],
        recommendation_reason: "Signing is a one-time setup.",
        steps: [],
        created_at: nil
      },
      attrs
    )
  end

  # The request as Linear reads it back: the comment parsed, its options as rendered lines.
  defp parsed_request(attrs \\ %{}) do
    request() |> Request.render_hold("In Progress") |> Request.parse(DateTime.utc_now()) |> Map.merge(attrs)
  end

  defp request_comment(id \\ @comment_id, body \\ nil, created_at \\ "2026-10-04T10:00:00.000Z") do
    %{"id" => id, "body" => body || Request.render_hold(request(), "In Progress"), "createdAt" => created_at}
  end

  defp reply(comment_id \\ @comment_id, body \\ "Close as duplicate") do
    %{"id" => "reply-1", "body" => body, "parent" => %{"id" => comment_id}}
  end

  defp ticket_node(attrs) do
    Map.merge(
      %{
        "id" => @issue_id,
        "labels" => %{"nodes" => []},
        "comments" => %{"nodes" => []},
        "history" => %{"nodes" => []}
      },
      attrs
    )
  end

  defp with_labels(labels), do: ticket_node(%{"labels" => %{"nodes" => Enum.map(labels, &%{"name" => &1})}})

  defp labels do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == @issue_id))
    |> Map.fetch!(:labels)
  end

  defp stored_hold do
    RunStore.get_ticket_state(@repo_key, @issue_id) |> SymphonyElixir.TicketState.get_hold(:needs_decision)
  end

  describe "desired/2" do
    test "an open request with no hold wants the hold set with the decision recorded" do
      assert {:set, attrs} = NeedsDecisionHold.desired(parsed_request(), nil)
      assert attrs.reason == "Add the signing secrets, or ship unsigned builds?"
      assert attrs.clearing_condition == "when the decision is recorded"
      assert attrs.decision.question == "Add the signing secrets, or ship unsigned builds?"
      assert attrs.decision.title == "Add the release signing secrets"
      assert attrs.decision.why == "Every Release run on main fails without them."
      assert attrs.decision.options == ["**Add the secrets** (recommended): Releases are signed again.", "**Ship unsigned**: The agent drops the signing step."]
    end

    test "a request with no question records its title as the reason" do
      assert {:set, %{reason: "Add the release signing secrets"}} = NeedsDecisionHold.desired(parsed_request(%{question: nil}), nil)
    end

    test "a hold that already carries the request wants nothing" do
      {:set, attrs} = NeedsDecisionHold.desired(parsed_request(), nil)

      assert NeedsDecisionHold.desired(parsed_request(), %{kind: :needs_decision, decision: attrs.decision}) == :none
    end

    test "a hold carrying a different request is replaced" do
      {:set, attrs} = NeedsDecisionHold.desired(parsed_request(), nil)
      other = parsed_request(%{title: "Something else", question: "Something else?"})

      assert {:set, %{decision: %{title: "Something else"}}} =
               NeedsDecisionHold.desired(other, %{kind: :needs_decision, decision: attrs.decision})
    end

    test "no open request clears the hold it left behind and leaves other holds alone" do
      assert NeedsDecisionHold.desired(nil, %{kind: :needs_decision}) == :clear
      assert NeedsDecisionHold.desired(nil, %{kind: :blocked}) == :none
      assert NeedsDecisionHold.desired(nil, nil) == :none
    end
  end

  describe "sync/3" do
    test "sets the Needs Decision hold on a designed repo and projects the label" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})

      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set
      assert %{reason: "Add the signing secrets, or ship unsigned builds?"} = stored_hold()
      assert stored_hold().decision.title == "Add the release signing secrets"
      assert labels() == ["Needs Decision"]

      assert [{"decision.requested", %{title: "Add the release signing secrets", question: "Add the signing secrets, or ship unsigned builds?"}}] =
               ticket_events(@repo_key, @issue_id)
    end

    test "clears the hold once the person answers, leaving the ticket in place" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})
      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :clear
      assert stored_hold() == nil
      assert labels() == []

      # The request, then the answer naming it: no hold event, and no withdrawal.
      assert [%{type: "decision.requested", id: request_id}, %{type: "decision.recorded", payload: %{answer: "Close as duplicate", key: @comment_id, request: request_id}}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, [])

      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :none
      assert length(ticket_events(@repo_key, @issue_id)) == 2
    end

    test "answering a merge confirmation's hold continues the ticket into Merging" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      merge_request = MergeConfirmation.request(issue(), %{recommendation: "ready to merge", review: nil, qa: nil, pr: nil})
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, MergeConfirmation.attrs(merge_request))

      node =
        ticket_node(%{
          "comments" => %{"nodes" => [request_comment(@comment_id, Request.render_hold(merge_request, "In Progress")), reply(@comment_id, "1")]}
        })

      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :clear
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert stored_hold() == nil
      assert labels() == []
    end

    test "a reply naming Send to Rework moves the ticket to Rework through the guard, and one naming Merge to Merging" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      merge_request = MergeConfirmation.request(issue(), %{recommendation: "ready to merge", review: nil, qa: nil, pr: nil})
      body = Request.render_hold(merge_request, "In Progress")

      for {answer, state} <- [{"send to rework, the tests are thin", "Rework"}, {"Merge", "Merging"}] do
        :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, MergeConfirmation.attrs(merge_request))
        withdrawn = %{"id" => "other", "body" => Request.render_withdrawal("Send to Rework is moot"), "parent" => %{"id" => @comment_id}}
        unrelated = %{"id" => "loose", "body" => "Send to Rework", "parent" => %{"id" => "elsewhere"}}
        comments = [request_comment(@comment_id, body), unrelated, withdrawn, reply(@comment_id, answer)]
        node = ticket_node(%{"comments" => %{"nodes" => comments}})

        assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :clear
        assert_received {:memory_tracker_state_update, @issue_id, ^state}
        assert stored_hold() == nil
      end
    end

    test "a Code Review escalation continues to QA only on a reply that picks it" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      escalation =
        request(%{
          title: "Code Review escalated TP-818",
          question: "How should TP-818 continue after Code Review escalated it?",
          options: [
            %{label: "Continue to QA", effect: "the ticket moves to QA and its QA run starts", recommended: true},
            %{label: "Send to Rework", effect: "the ticket moves to Rework with these reasons", recommended: false}
          ]
        })

      body = Request.render_hold(escalation, "Code Review")

      for {answer, state} <- [
            {"1", "QA"},
            {"Option 1, go ahead", "QA"},
            {"**Continue to QA**", "QA"},
            {"Send to Rework", "Rework"},
            {"2. the tests are thin", "Rework"},
            {"**Neither option**: one change on the same PR, then continue to QA", "In Progress"},
            {"Can you check the reviewer's reason first?", "In Progress"}
          ] do
        :ok = DecisionRequest.ask(issue(%{state: "Code Review"}), escalation, [tracker: SymphonyElixir.Tracker.Memory], "QA")
        comments = [request_comment(@comment_id, body), reply(@comment_id, answer)]
        node = ticket_node(%{"state" => %{"name" => "Code Review"}, "comments" => %{"nodes" => comments}})

        assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :clear
        assert_received {:memory_tracker_state_update, @issue_id, ^state}, "#{answer} should move to #{state}"
        assert stored_hold() == nil
      end
    end

    test "a reply that picks an option carrying its own move makes that move, and one that picks none moves nothing" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      skip = %{kind: "qa", outcome: "skip", head_sha: "abc123", reason: "skipped by decision"}

      qa_request =
        request(%{
          title: "QA could not finish its check of TP-818",
          question: "QA could not prove any step of TP-818 here. How should it continue?",
          options: [
            %{label: "Run QA again", effect: "QA runs once more on the same change"},
            DecisionMove.option(%{label: "Send it back to Rework", effect: "Symphony moves TP-818 to Rework"}, %{to: "Rework"}),
            DecisionMove.option(%{label: "Merge without a QA result", effect: "Symphony moves TP-818 to Merging", recommended: true}, %{to: "Merging", verdict: skip})
          ]
        })

      body = Request.render_hold(qa_request, "QA")

      for {answer, state} <- [{"Send it back to Rework", "Rework"}, {"3", "Merging"}, {"Run QA again", nil}, {"Let me look first", nil}] do
        :ok = DecisionRequest.ask(issue(%{state: "QA"}), qa_request, tracker: SymphonyElixir.Tracker.Memory)
        assert %{decision: %{state: "QA"}} = stored_hold()
        comments = [request_comment(@comment_id, body), reply(@comment_id, answer)]
        node = ticket_node(%{"state" => %{"name" => "QA"}, "comments" => %{"nodes" => comments}})

        assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :clear
        assert stored_hold() == nil

        if state,
          do: assert_received({:memory_tracker_state_update, @issue_id, ^state}, "#{answer} should move to #{state}"),
          else: refute_received({:memory_tracker_state_update, @issue_id, _state}, "#{answer} should move nothing")
      end

      record = RunStore.get_ticket_state(@repo_key, @issue_id)
      assert [%{kind: "qa", outcome: "skip", head_sha: "abc123"}] = record.verdicts
      assert %{name: "decision returned", details: %{move: "decide", to: "Merging"}} = Enum.find(record.signals, &(&1.details[:to] == "Merging"))
    end

    test "a ticket a person moved after the request stays where they put it" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      :ok = DecisionRequest.ask(issue(%{state: "Code Review"}), request(), [tracker: SymphonyElixir.Tracker.Memory], "QA")
      node = ticket_node(%{"state" => %{"name" => "In Progress"}, "comments" => %{"nodes" => [request_comment(), reply(@comment_id, "1")]}})

      log = capture_log(fn -> assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :clear end)

      assert log =~ "where a person moved it after its decision request"
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert stored_hold() == nil
    end

    test "a confirmation whose move fails reports it and leaves the ticket where it is" do
      merge_request = MergeConfirmation.request(issue(), %{recommendation: "ready to merge", review: nil, qa: nil, pr: nil})
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, MergeConfirmation.attrs(merge_request))

      node =
        ticket_node(%{
          "comments" => %{"nodes" => [request_comment(@comment_id, Request.render_hold(merge_request, "In Progress")), reply(@comment_id, "Merge")]}
        })

      log =
        capture_log(fn ->
          assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings(), tracker: FailingMoveTracker) == :clear
        end)

      assert log =~ "Failed to continue issue_id=#{@issue_id} to Merging after its decision"
      assert stored_hold() == nil
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "the read that sees the answer writes it into the description's Decisions section" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set
      assert {:ok, nil} = SymphonyElixir.Tracker.fetch_issue_description(@issue_id)

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply(@comment_id, "Ship unsigned")]}})
      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :clear

      assert {:ok, description} = SymphonyElixir.Tracker.fetch_issue_description(@issue_id)

      assert [%{id: "D1", key: @comment_id, title: "Add the release signing secrets", question: "Add the signing secrets, or ship unsigned builds?"} = decision] =
               SymphonyElixir.Decisions.recorded(description)

      assert decision.answer =~ "Ship unsigned (option: **Ship unsigned**: The agent drops the signing step.)"
    end

    test "an ordinary decision's hold continues in place, moving nothing" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})
      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :clear
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "answering it also lifts the handoff_missing Blocked hold its quiet runs left, so the ticket resumes" do
      quiet = %{reason: "handoff_missing: 2 runs went quiet", waits_on: %{type: "handoff_missing", keys: ["sha-1"]}}
      :ok = Hold.set(@repo_key, @issue_id, :blocked, quiet)
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})
      assert capture_log(fn -> assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :clear end) =~ "Cleared the handoff_missing Blocked hold"
      refute Hold.held_any?(@repo_key, @issue_id)
      assert labels() == []
    end

    test "answering it leaves a Blocked hold on anything else in place" do
      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waits on TP-1", waits_on: %{type: "dependency", keys: ["TP-1"]}})
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      :set = NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings())

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})
      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :clear
      assert stored_hold() == nil
      assert Hold.held?(@repo_key, @issue_id, :blocked)
    end

    test "a handoff_missing hold that can't be cleared is logged, and the decision still clears" do
      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "handoff_missing", waits_on: %{type: "handoff_missing", keys: []}})
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      :set = NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings())

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})

      log =
        capture_log(fn ->
          assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings(), store: BlockedClearFailsStore) == :clear
        end)

      assert log =~ "Failed to clear the handoff_missing Blocked hold"
      assert stored_hold() == nil
    end

    test "a reply that answers a request asked through the writer answers its Question in the person's words" do
      assert :ok = DecisionRequest.ask(issue(), request(), [])
      [%{id: id}] = Questions.open({:ticket, @repo_key, @issue_id})

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply(@comment_id, "Ship unsigned\n")]}})
      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :clear
      assert stored_hold() == nil
      assert %{state: :answered, answer: %{text: "Ship unsigned", option: 2, by: %{kind: :person}}} = Questions.find({:ticket, @repo_key, @issue_id}, id)
    end

    test "a hold whose comment could not be posted is posted by the sweep, never read as withdrawn" do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result) end)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      down = {:error, :linear_down}
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [down, down, :ok])
      capture_log(fn -> assert {:error, {:decision_request_failed, :linear_down}} = DecisionRequest.ask(issue(), request(), []) end)
      [%{id: id}] = Questions.open({:ticket, @repo_key, @issue_id})

      # Linear reads no request on the ticket: the sweep tries the comment again, and keeps the hold.
      node = ticket_node(%{"state" => %{"name" => "In Progress"}})
      capture_log(fn -> assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :none end)
      refute_received {:memory_tracker_comment, @issue_id, _body}
      assert %{decision: %{question_id: ^id}} = stored_hold()

      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :none
      assert_received {:memory_tracker_comment, @issue_id, body}
      assert body =~ "## Decision needed: Add the release signing secrets"
      assert body =~ "<!-- symphony:question #{id} -->"
      assert %{decision: %{question_id: ^id}} = stored_hold()
      assert [%{id: ^id}] = Questions.open({:ticket, @repo_key, @issue_id})

      # Posted, a request still missing from Linear is one a person removed: it ends as a withdrawal.
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :clear
      assert %{state: :withdrawn} = Questions.find({:ticket, @repo_key, @issue_id}, id)
    end

    test "clears the hold when the run withdraws the request" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set

      withdrawn = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply(@comment_id, Request.render_withdrawal("no longer needed"))]}})
      assert NeedsDecisionHold.sync(@repo_key, withdrawn, settings: designed_settings()) == :clear
      assert stored_hold() == nil

      assert [%{type: "decision.requested", id: request_id}, %{type: "decision.withdrawn", payload: %{title: "Add the release signing secrets", request: request_id}}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, [])
    end

    test "a request gone from Linear with no answer ends as a withdrawal naming it" do
      :set = NeedsDecisionHold.sync(@repo_key, ticket_node(%{"comments" => %{"nodes" => [request_comment()]}}), settings: designed_settings())

      assert NeedsDecisionHold.sync(@repo_key, ticket_node(%{}), settings: designed_settings()) == :clear

      assert [%{type: "decision.requested", id: request_id}, %{type: "decision.withdrawn", payload: %{request: request_id}}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, [])
    end

    test "reads the newest open request, and another still open leaves the hold in place" do
      older = request_comment(@comment_id, Request.render_hold(request(%{title: "Older", question: "Older?"}), "In Progress"), "2026-10-04T09:00:00.000Z")
      newer = request_comment("comment-2", Request.render_hold(request(%{title: "Newer", question: "Newer?"}), "In Progress"), "2026-10-04T11:00:00.000Z")
      both = ticket_node(%{"comments" => %{"nodes" => [older, newer]}})

      assert NeedsDecisionHold.sync(@repo_key, both, settings: designed_settings()) == :set
      assert stored_hold().decision.title == "Newer"

      # The newest is answered but the older one still waits, so the hold is rewritten for it.
      answered = ticket_node(%{"comments" => %{"nodes" => [older, newer, reply("comment-2")]}})
      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :set
      assert stored_hold().decision.title == "Older"

      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :none
    end

    test "a hold that moved on to a newer question comes back to the older one carrying its Question" do
      older_request = request(%{title: "Older", question: "Older?"})
      newer_request = request(%{title: "Newer", question: "Newer?"})
      assert :ok = DecisionRequest.ask(issue(), older_request, [])
      assert :ok = DecisionRequest.ask(issue(), newer_request, [])
      ticket = {:ticket, @repo_key, @issue_id}
      assert [%{id: older_id, title: "Older"}, %{id: newer_id, title: "Newer"}] = Questions.open(ticket)
      assert stored_hold().decision.question_id == newer_id

      older = request_comment(@comment_id, Request.render_hold(older_request, "In Progress"), "2026-10-04T09:00:00.000Z")
      newer = request_comment("comment-2", Request.render_hold(newer_request, "In Progress"), "2026-10-04T11:00:00.000Z")
      answered_newer = %{"id" => "reply-2", "body" => "Add the secrets", "parent" => %{"id" => "comment-2"}}

      # The newer is answered: its Question ends with the reply, and the hold goes back to the older
      # one carrying its Question, so no second request is recorded for it.
      node = ticket_node(%{"comments" => %{"nodes" => [older, newer, answered_newer]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set
      assert %{state: :answered, answer: %{text: "Add the secrets"}} = Questions.find(ticket, newer_id)
      assert %{title: "Older", question_id: ^older_id} = stored_hold().decision
      assert [%{id: ^older_id}] = Questions.open(ticket)
      refute Enum.any?(RunStore.list_ticket_events(@repo_key, @issue_id, []), &(&1.type == "decision.requested"))

      # The older is answered next: its hold clears and its Question ends with that answer.
      answered_older = %{"id" => "reply-1", "body" => "Ship unsigned", "parent" => %{"id" => @comment_id}}
      node = ticket_node(%{"comments" => %{"nodes" => [older, newer, answered_newer, answered_older]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :clear
      assert stored_hold() == nil
      assert %{state: :answered, answer: %{text: "Ship unsigned"}} = Questions.find(ticket, older_id)
      assert Questions.open(ticket) == []
    end

    test "an older question answered while a newer one holds ends with that answer, and the newer keeps the hold" do
      older_request = request(%{title: "Older", question: "Older?"})
      newer_request = request(%{title: "Newer", question: "Newer?"})
      assert :ok = DecisionRequest.ask(issue(), older_request, [])
      assert :ok = DecisionRequest.ask(issue(), newer_request, [])
      ticket = {:ticket, @repo_key, @issue_id}
      assert [%{id: older_id}, %{id: newer_id}] = Questions.open(ticket)

      later = DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
      older = request_comment(@comment_id, Request.render_hold(older_request, "In Progress"), "2026-10-04T09:00:00.000Z")
      newer = request_comment("comment-2", Request.render_hold(newer_request, "In Progress"), "2026-10-04T11:00:00.000Z")
      answered_older = %{"id" => "reply-1", "body" => "Ship unsigned", "parent" => %{"id" => @comment_id}, "createdAt" => later}

      node = ticket_node(%{"comments" => %{"nodes" => [older, newer, answered_older]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :none
      assert %{state: :answered, answer: %{text: "Ship unsigned"}} = Questions.find(ticket, older_id)
      assert [%{id: ^newer_id}] = Questions.open(ticket)
      assert stored_hold().decision.question_id == newer_id
    end

    test "an answer given before an older question was asked again does not answer the new one" do
      older_request = request(%{title: "Older", question: "Older?"})
      assert :ok = DecisionRequest.ask(issue(), older_request, [])
      assert :ok = DecisionRequest.ask(issue(), request(%{title: "Newer", question: "Newer?"}), [])
      ticket = {:ticket, @repo_key, @issue_id}
      assert [%{id: older_id}, _newer] = Questions.open(ticket)

      earlier = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
      older = request_comment(@comment_id, Request.render_hold(older_request, "In Progress"), "2026-10-04T09:00:00.000Z")
      answered_before = %{"id" => "reply-1", "body" => "Ship unsigned", "parent" => %{"id" => @comment_id}, "createdAt" => earlier}

      node = ticket_node(%{"comments" => %{"nodes" => [older, answered_before]}})
      capture_log(fn -> NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) end)
      assert %{state: :open} = Questions.find(ticket, older_id)
    end

    test "does nothing when the request has not changed" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      :set = NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings())

      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :none
      assert [{"decision.requested", _payload}] = ticket_events(@repo_key, @issue_id)
    end

    test "resolves the repo's settings from its key when the caller passes none" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [[key: @repo_key, workflow: Workflow.workflow_file_path(), team: "Test"]]
      )

      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.sync(@repo_key, node) == :set
      assert stored_hold() != nil
    end

    test "skips when no settings can be resolved or the node is not one" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})

      assert NeedsDecisionHold.sync(nil, node) == :skipped
      assert NeedsDecisionHold.sync("missing-repo", node) == :skipped
      assert NeedsDecisionHold.sync(:not_a_repo_key, node, settings: designed_settings()) == :skipped
      assert NeedsDecisionHold.sync(@repo_key, %{"id" => nil}, settings: designed_settings()) == :none
      assert NeedsDecisionHold.sync(@repo_key, :not_a_node, settings: designed_settings()) == :none
    end

    test "reports and clears a hand-added Needs Decision label with no store hold" do
      node = with_labels(["Needs Decision"])

      log = capture_log(fn -> assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :none end)

      assert log =~ "with no store hold"
      assert labels() == []
      assert stored_hold() == nil
      assert ticket_events(@repo_key, @issue_id) == []
    end

    test "re-projects a store hold whose Needs Decision label is missing" do
      :ok =
        RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, %{
          reason: "Add the signing secrets, or ship unsigned builds?",
          clearing_condition: "when the decision is recorded",
          decision: %{title: "Add the release signing secrets", question: "Add the signing secrets, or ship unsigned builds?"}
        })

      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert labels() == []

      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :none
      assert labels() == ["Needs Decision"]
      assert stored_hold() != nil
    end

    test "an answer posted while the label was missing is recorded and clears the hold" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue(%{labels: []})])

      # The read that sees the answer finds the ticket without its label.
      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply(@comment_id, "Ship unsigned")]}})

      capture_log(fn -> assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :clear end)

      assert stored_hold() == nil
      assert labels() == []
      assert {:ok, description} = SymphonyElixir.Tracker.fetch_issue_description(@issue_id)
      assert [%{id: "D1", key: @comment_id} = decision] = SymphonyElixir.Decisions.recorded(description)
      assert decision.answer =~ "Ship unsigned"
    end

    test "a store failure on set is logged and reports no change" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})

      log =
        capture_log(fn ->
          assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings(), store: FailingStore) == :none
        end)

      assert log =~ "Failed to set the Needs Decision hold"
    end

    test "a failed clear is logged and reports no change" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      :set = NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings())

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})

      log =
        capture_log(fn ->
          assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings(), store: ReadOnlyStore) == :none
        end)

      assert log =~ "Failed to clear the Needs Decision hold"
    end
  end

  describe "as_recorded/2 (TP-1240)" do
    # The request a Question was asked with, as Linear holds it: its hidden line names the Question.
    defp asked_comment(id, created_at \\ "2026-10-04T10:00:00.000Z") do
      request_comment(@comment_id, Request.render_hold(request(), "In Progress") <> "\n\n<!-- symphony:question #{id} -->", created_at)
    end

    test "a request whose Question the Director answered reads closed before Linear shows the reply" do
      assert :ok = DecisionRequest.ask(issue(), request(), [])
      ticket = {:ticket, @repo_key, @issue_id}
      [%{id: id}] = Questions.open(ticket)
      node = ticket_node(%{"comments" => %{"nodes" => [asked_comment(id), %{"id" => "note", "body" => "A note"}]}})

      # Open on the record, it reads as Linear has it, replies and all.
      assert NeedsDecisionHold.as_recorded(@repo_key, node) == node
      replied_open = ticket_node(%{"comments" => %{"nodes" => [asked_comment(id), reply(@comment_id, "Ship unsigned")]}})
      assert NeedsDecisionHold.as_recorded(@repo_key, replied_open) == replied_open

      {:ok, _answered} = Questions.answer(ticket, id, "Ship unsigned")
      :ok = Hold.clear(@repo_key, @issue_id, :needs_decision, answered: true)
      assert %{"comments" => %{"nodes" => [%{"id" => "note"}]}} = NeedsDecisionHold.as_recorded(@repo_key, node)

      # The read sets no hold again for it, and once the reply is on Linear it reads as Linear has it.
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :none
      assert stored_hold() == nil
      replied = ticket_node(%{"comments" => %{"nodes" => [asked_comment(id), reply(@comment_id, "Ship unsigned")]}})
      assert NeedsDecisionHold.as_recorded(@repo_key, replied) == replied
    end

    test "replies under a request whose Question the Director reopened count only from the reopen on" do
      assert :ok = DecisionRequest.ask(issue(), request(), [])
      ticket = {:ticket, @repo_key, @issue_id}
      [%{id: id}] = Questions.open(ticket)
      {:ok, _answered} = Questions.answer(ticket, id, "Ship unsigned", at: ~U[2026-10-04 10:05:00Z])
      {:ok, _reopened} = Questions.reopen(ticket, id, at: ~U[2026-10-04 10:05:08Z])

      before = Map.put(reply(@comment_id, "Ship unsigned"), "createdAt", "2026-10-04T10:05:01.000Z")
      undated = %{"id" => "reply-2", "body" => "Hmm", "parent" => %{"id" => @comment_id}}
      later = %{"id" => "reply-3", "body" => "Add the secrets", "parent" => %{"id" => @comment_id}, "createdAt" => "2026-10-04T10:06:00.000Z"}
      node = ticket_node(%{"comments" => %{"nodes" => [asked_comment(id), before, undated]}})

      assert %{"comments" => %{"nodes" => [%{"id" => @comment_id}]}} = NeedsDecisionHold.as_recorded(@repo_key, node)
      # The hold stays: the request reads open, carrying its Question.
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :none
      assert %{decision: %{question_id: ^id}} = stored_hold()

      # A reply after the reopen answers it again.
      answered = ticket_node(%{"comments" => %{"nodes" => [asked_comment(id), before, later]}})
      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :clear
      assert %{state: :answered, answer: %{text: "Add the secrets"}} = Questions.find(ticket, id)
    end

    test "a ticket with no record, no questions or no comments reads as Linear has it" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.as_recorded(@repo_key, node) == node
      assert NeedsDecisionHold.as_recorded(nil, node) == node

      assert :ok = DecisionRequest.ask(issue(), request(), [])
      unread = Map.delete(node, "comments")
      assert NeedsDecisionHold.as_recorded(@repo_key, unread) == unread
    end
  end

  describe "sweep/3" do
    test "counts the holds it set and cleared over the tickets a route read" do
      open = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      other = ticket_node(%{"id" => "issue-2"})

      assert NeedsDecisionHold.sweep(@repo_key, [open, other], settings: designed_settings()) == 1

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})
      assert NeedsDecisionHold.sweep(@repo_key, [answered, other], settings: designed_settings()) == 1
    end

    test "counts nothing without a list" do
      open = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})

      assert NeedsDecisionHold.sweep(@repo_key, :not_a_list, settings: designed_settings()) == 0
      # Without the caller's settings the repo is resolved from the key.
      assert NeedsDecisionHold.sweep(@repo_key, [open]) == 0
    end
  end

  describe "the Hold read path and the collector's request read" do
    test "get/4 reads the decision the hold carries" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      :set = NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings())

      assert %{decision: %{title: "Add the release signing secrets"}} = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert Hold.held_any?(@repo_key, @issue_id)
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
      refute Hold.held?(@repo_key, @issue_id, :blocked)
    end

    test "newest_open_request/2 hands back the comment id a reply answers" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})

      assert {@comment_id, %{title: "Add the release signing secrets"}} = Collector.newest_open_request(node, designed_settings())
      assert %{title: "Add the release signing secrets"} = Collector.newest_request(node, designed_settings())

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})
      assert Collector.newest_open_request(answered, designed_settings()) == nil
      assert Collector.newest_request(answered, designed_settings()) == nil
    end
  end
end
