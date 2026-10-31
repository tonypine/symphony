defmodule SymphonyElixir.Pauses.ProjectorTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Decisions, DirectorMoves, Pauses, Questions, TicketState, Workflow}
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses.Projector

  @repo_key "repo-a"
  @issue_id "issue-1"
  @ticket {:ticket, @repo_key, @issue_id}
  @at ~U[2026-10-30 04:00:00Z]
  @description "Ship the release notes.\n\n## Acceptance criteria\n\n* Notes ship."

  @request %{
    title: "Ship TP-12 before the release",
    question: "Should TP-12 ship today, before the release goes out?",
    why: "TP-12 is ready. The release goes out tomorrow.",
    if_unanswered: "TP-12 waits and does not ship.",
    recommendation_reason: "Shipping today gives the release a day of use.",
    options: [
      %{label: "Ship today", effect: "TP-12 merges today.", recommended: true},
      %{label: "Wait for the release", effect: "TP-12 merges with the release."}
    ]
  }

  defmodule RaisingTracker do
    def set_machine_label(_issue_id, _name), do: raise("Linear is down")
    def clear_machine_label(_issue_id, _name), do: raise("Linear is down")
    def fetch_issue_description(_issue_id), do: raise("Linear is down")
    def fetch_plan_comments(_issue_id), do: raise("Linear is down")
  end

  defmodule FailingStore do
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :boom}
  end

  # Reads the record, refuses to write what was projected.
  defmodule UnwritableStore do
    def get_ticket_state(repo_key, issue_id), do: SymphonyElixir.RunStore.get_ticket_state(repo_key, issue_id)
    def update_ticket_state(_repo_key, _issue_id, _attrs), do: {:error, :boom}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :pause_projector, true)
    :ok = RunStore.clear()

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :pause_projector, false)

      for key <- [
            :memory_tracker_recipient,
            :memory_tracker_add_issue_label_result,
            :memory_tracker_remove_issue_label_result,
            :memory_tracker_update_issue_description_result,
            :memory_tracker_create_comment_result,
            :memory_tracker_plan_comments
          ],
          do: Application.delete_env(:symphony_elixir, key)
    end)

    :ok
  end

  describe "desired/1" do
    test "Needs Decision while a question is open, Blocked while any other reason but an update's wait pauses it" do
      assert %{labels: [], entries: [], section: nil} = Projector.desired(%{})

      assert Projector.desired(record(pause([reason(:ticket, %{identifier: "TP-12"})]))).labels == ["Blocked"]
      assert Projector.desired(record(pause([reason(:person, %{action: "unblock"})]))).labels == ["Blocked"]
      assert Projector.desired(record(pause([reason(:environment, %{condition: "self_heal:qa"})]))).labels == ["Blocked"]
      assert Projector.desired(record(pause([reason(:build, %{pull_request: 448})]))).labels == []

      {:ok, question} = Questions.ask(@ticket, @request, at: @at)
      paused = pause([reason(:question, %{question_id: "q-1"}), reason(:ticket, %{identifier: "TP-12"})])
      assert Projector.desired(record(paused, [question])).labels == ["Blocked", "Needs Decision"]
      assert Projector.desired(record(pause([reason(:question, %{question_id: "q-1"})]), [question])).labels == ["Needs Decision"]
      assert Projector.desired(record(nil, [%{question | state: :answered}])).labels == []
    end

    test "the holds a record kept from before they were retired show no label; an open question shows Needs Decision alone" do
      access = %{kind: :blocked, reason: "needs the deploy key", waits_on: %{type: "access", keys: []}}
      assert Projector.desired(%{holds: [access]}).labels == []
      assert Projector.desired(%{holds: [%{kind: :needs_decision, decision: %{title: "Old"}}]}).labels == []

      {:ok, question} = Questions.ask(@ticket, @request, at: @at)
      beside = %{kind: :blocked, reason: "loop", waits_on: %{type: "dispatch_loop", keys: [], question_id: question.id}}
      assert Projector.desired(Map.put(record(pause([reason(:question, %{question_id: question.id})]), [question]), :holds, [beside])).labels == ["Needs Decision"]
    end

    test "the section's entries are the record's decisions, hashed; the same decisions hash the same" do
      decision = Decisions.entry("comment-1", ~D[2026-10-13], "Keep the legacy partials", "Remove them here?", "Defer to TP-891.")
      desired = Projector.desired(%{decisions: [decision]})

      assert [%{key: "comment-1", scope: "Deferred to TP-891"}] = desired.entries
      assert desired.section =~ ~r/\A[0-9a-f]{16}\z/
      assert Projector.desired(%{decisions: [decision]}).section == desired.section
      refute Projector.desired(%{decisions: [%{decision | answer: "Do it here."}]}).section == desired.section
    end
  end

  describe "each write projects the labels that differ" do
    test "a question and a dependency, the answer, then the dependency clearing write exactly the label calls that differ" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}

      {:ok, question} = Questions.ask(@ticket, @request, at: @at)
      assert_received {:memory_tracker_label_added, @issue_id, "Needs Decision"}
      assert Projector.desired(stored()).labels == ["Blocked", "Needs Decision"]
      assert stored().projected == %{labels: ["Blocked", "Needs Decision"], section: nil, comments: %{}}

      {:ok, _answered} = Questions.answer(@ticket, question.id, "Ship today")
      assert_received {:memory_tracker_label_removed, @issue_id, "Needs Decision"}
      assert Projector.desired(stored()).labels == ["Blocked"]

      {:ok, nil} = Pauses.clear_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      assert_received {:memory_tracker_label_removed, @issue_id, "Blocked"}
      assert stored().projected.labels == []

      refute_received {:memory_tracker_label_added, _issue_id, _name}
      refute_received {:memory_tracker_label_removed, _issue_id, _name}
      assert labels() == []
    end

    test "a second apply of the same record writes nothing, and a reason that changes no label writes none" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}

      assert Projector.apply(stored()) == :ok
      {:ok, _pause} = Pauses.add_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-13"))
      refute_received {:memory_tracker_label_added, _issue_id, _name}
    end

    test "an update's wait shows no label" do
      {:ok, _pause} = Pauses.set(@ticket, %{kind: :build, waits_on: %{pull_request: 448}})
      refute_received {:memory_tracker_label_added, _issue_id, _name}
      assert stored().projected == %{labels: [], section: nil, comments: %{}}
    end

    test "a record never projected compares with the labels Linear was last seen with" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, @issue_id, %{labels: ["blocked", "bug"]}))

      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      refute_received {:memory_tracker_label_added, _issue_id, _name}
      assert stored().projected == %{labels: ["Blocked"], section: nil, comments: %{}}
    end

    test "force compares with the labels Linear was last seen with, so a label removed by hand comes back" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}

      assert Projector.apply(stored()) == :ok
      refute_received {:memory_tracker_label_added, _issue_id, _name}

      assert Projector.project_now(@ticket, force: true) == :ok
      assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}
    end

    test "a repair compares with the labels it read in Linear, so a label added by hand goes, and one the record wants stays" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, @issue_id, %{labels: [], projected: %{labels: []}}))
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue() | labels: ["Blocked", "Needs Decision"]}])

      # Compared with what it last applied, nothing differs.
      assert Projector.project_now(@ticket) == :ok
      refute_received {:memory_tracker_label_removed, _issue_id, _name}

      {:ok, _question} = Questions.ask(@ticket, @request, at: @at)
      flush_label_messages()
      assert Projector.project_now(@ticket, force: true, labels: ["Blocked", "Needs Decision", "bug"]) == :ok
      assert_received {:memory_tracker_label_removed, @issue_id, "Blocked"}
      refute_received {:memory_tracker_label_added, _issue_id, _name}
      refute_received {:memory_tracker_label_removed, _issue_id, _name}
      assert stored().projected.labels == ["Needs Decision"]
    end

    test "a repair clears a machine label on a ticket Symphony keeps no record of" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue() | labels: ["Blocked"]}])

      assert Projector.project_now(@ticket, force: true, labels: ["Blocked"]) == :ok
      assert_received {:memory_tracker_label_removed, @issue_id, "Blocked"}
      assert labels() == []
    end
  end

  describe "the Decisions section" do
    test "a recorded decision is written into the description once, as the decision store wrote it" do
      entry = Decisions.entry("comment-1", ~D[2026-10-13], "Keep the legacy partials", "Remove them here?", "Defer to TP-891.")
      {:ok, expected} = Decisions.put(@description, [entry])

      assert Decisions.record(@issue_id, [entry], repo_key: @repo_key) == :ok
      assert_received {:memory_tracker_description_update, @issue_id, ^expected}
      assert %{section: section} = stored().projected
      assert section == Projector.desired(stored()).section

      assert Decisions.record(@issue_id, [entry], repo_key: @repo_key) == :ok
      assert Projector.apply(stored()) == :ok
      refute_received {:memory_tracker_description_update, _issue_id, _description}
    end

    test "a section already in the description is not written again" do
      entry = Decisions.entry("comment-1", ~D[2026-10-13], "Keep the legacy partials", "Remove them here?", "Defer to TP-891.")
      {:ok, written} = Decisions.put(@description, [entry])
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue() | description: written}])

      assert Decisions.record(@issue_id, [entry], repo_key: @repo_key, description: written) == :ok
      refute_received {:memory_tracker_description_update, _issue_id, _description}
      assert stored().projected.section == Projector.desired(stored()).section
    end
  end

  describe "a write Linear refuses" do
    test "leaves the record right and the projection pending, and the next apply writes it" do
      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, [{:error, :linear_down}])

      log = capture_log(fn -> {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12")) end)
      assert log =~ "Failed to project the pause"
      assert [%{kind: :ticket}] = stored().pause.reasons
      assert [%{type: :pause, error: ":linear_down"}] = stored().pending_projection
      assert stored().projected == %{labels: [], section: nil, comments: %{}}

      assert Projector.project_now(@ticket) == :ok
      assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}
      assert stored().projected.labels == ["Blocked"]
    end

    test "a label cleared while Linear refuses stays applied until it is cleared" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      Application.put_env(:symphony_elixir, :memory_tracker_remove_issue_label_result, [{:error, :linear_down}])

      capture_log(fn -> {:ok, nil} = Pauses.clear_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-12")) end)
      assert stored().projected.labels == ["Blocked"]
      assert [%{type: :pause}] = stored().pending_projection
    end

    test "a description Linear can't read, write or hold a section in is pending" do
      entry = Decisions.entry("comment-1", ~D[2026-10-13], "Keep the legacy partials", "Remove them here?", "Defer to TP-891.")
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, @issue_id, %{decisions: [entry]}))

      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_description_result, [{:error, :linear_down}])
      capture_log(fn -> assert Projector.apply(stored()) == {:error, :linear_down} end)
      assert stored().projected.section == nil

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue() | description: "<!-- symphony:decisions:start -->\nunterminated"}])
      capture_log(fn -> assert Projector.apply(stored()) == {:error, :decisions_block_unterminated} end)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      capture_log(fn -> assert Projector.apply(stored()) == {:error, :issue_not_found} end)
      assert [%{type: :pause, error: ":issue_not_found"}] = stored().pending_projection
    end

    test "a tracker that raises is a write that failed" do
      {:ok, _pause} = Pauses.set(@ticket, %{kind: :build, waits_on: %{pull_request: 448}})
      {:ok, _pause} = Pauses.add_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      :ok = RunStore.update_ticket_state(@repo_key, @issue_id, %{projected: nil, decisions: [Decisions.entry("c-1", ~D[2026-10-13], "T", "Q?", "A.")]})

      capture_log(fn -> assert {:error, {:error, %RuntimeError{}}} = Projector.apply(stored(), tracker: RaisingTracker) end)
      assert stored().projected == %{labels: [], section: nil, comments: %{}}
    end

    test "a projection the store can't record is logged" do
      {:ok, _pause} = Pauses.set(@ticket, %{kind: :build, waits_on: %{pull_request: 448}})
      {:ok, _pause} = Pauses.add_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      :ok = RunStore.update_ticket_state(@repo_key, @issue_id, %{projected: nil})

      log = capture_log(fn -> assert Projector.apply(stored(), store: UnwritableStore) == :ok end)
      assert log =~ "Failed to record the pause projection"
    end
  end

  describe "the request comment and its reply" do
    test "a request is posted once, byte for byte as the request it was asked with, and a second projection writes nothing" do
      {:ok, question} = Questions.ask(@ticket, request_with_tradeoffs(), request: true, asked_in: "Rework", at: @at)

      expected = Request.render_hold(request_with_tradeoffs(), "Rework") <> "\n\n<!-- symphony:question #{question.id} -->"
      assert_received {:memory_tracker_comment, @issue_id, ^expected}
      assert_received {:memory_tracker_plan_comments, @issue_id}
      assert stored().projected.comments == %{question.id => %{comment: nil, reply: nil}}
      assert [%{question_id: id, comment: ^expected, stamp: nil, reply: nil}] = Projector.desired(stored()).comments
      assert id == question.id

      assert Projector.apply(stored()) == :ok
      assert Projector.project_now(@ticket) == :ok
      refute_received {:memory_tracker_comment, _issue_id, _body}
      refute_received {:memory_tracker_plan_comments, _issue_id}
    end

    test "a question no request comment shows posts nothing" do
      {:ok, _question} = Questions.ask(@ticket, @request, at: @at)

      refute_received {:memory_tracker_comment, _issue_id, _body}
      refute_received {:memory_tracker_plan_comments, _issue_id}
      assert Projector.desired(stored()).comments == []
    end

    test "the Director's answer is replied once under the request, byte for byte as the Director's Decide replies" do
      {:ok, question} = ask_posted()

      {:ok, _answered} = Questions.answer(@ticket, question.id, "Ship today")
      expected = DirectorMoves.decide_comment([%{question: question.question, answer: "Ship today"}])
      assert_received {:memory_tracker_reply, @issue_id, "c-1", ^expected}
      assert %{comment: "c-1", reply: "answered:" <> _at} = stored().projected.comments[question.id]

      assert Projector.apply(stored()) == :ok
      refute_received {:memory_tracker_reply, _issue_id, _parent, _body}
      refute_received {:memory_tracker_comment, _issue_id, _body}
    end

    test "a withdrawal is replied with its reason, as the withdrawal tool replies" do
      {:ok, question} = ask_posted()

      {:ok, _withdrawn} = Questions.withdraw(@ticket, question.id, "  Not needed any more.  ")
      expected = Request.render_withdrawal("Not needed any more.")
      assert_received {:memory_tracker_reply, @issue_id, "c-1", ^expected}
      assert expected == "## Action withdrawn\n\nNot needed any more."
    end

    test "a person's reply in Linear is the answer, and an answer no person gave posts no reply" do
      {:ok, question} = ask_posted()
      comments!([request_comment("c-1", question), %{id: "r-1", body: "Ship today", parent_id: "c-1", created_at: @at}])

      {:ok, _answered} = Questions.answer(@ticket, question.id, "Ship today")
      refute_received {:memory_tracker_reply, _issue_id, _parent, _body}
      assert %{comment: "c-1", reply: "answered:" <> _at} = stored().projected.comments[question.id]

      {:ok, other} = Questions.ask(@ticket, %{@request | title: "Another call"}, request: true, at: @at)
      comments!([request_comment("c-2", other)])
      {:ok, _answered} = Questions.answer(@ticket, other.id, "Ship today", by: %{kind: :symphony, name: "Symphony"})
      refute_received {:memory_tracker_reply, _issue_id, _parent, _body}
      assert %{comment: "c-2", reply: "answered:" <> _at} = stored().projected.comments[other.id]
    end

    test "an answer taken back and given again is replied again; a reply before the reopen does not count" do
      {:ok, question} = ask_posted()
      {:ok, _answered} = Questions.answer(@ticket, question.id, "Ship today", at: @at)
      assert_received {:memory_tracker_reply, @issue_id, "c-1", _body}

      {:ok, _reopened} = Questions.reopen(@ticket, question.id, at: DateTime.add(@at, 60))
      comments!([request_comment("c-1", question), %{id: "r-1", body: "Decision", parent_id: "c-1", created_at: DateTime.add(@at, 1)}])
      {:ok, _answered} = Questions.answer(@ticket, question.id, "Wait for the release", at: DateTime.add(@at, 120))

      expected = DirectorMoves.decide_comment([%{question: question.question, answer: "Wait for the release"}])
      assert_received {:memory_tracker_reply, @issue_id, "c-1", ^expected}
    end

    test "a request already on Linear is found by its hidden line, or by its title when it carries none, and not posted again" do
      {:ok, question} = ask_unprojected(@request)

      comments!([
        %{id: "other", body: "A note", parent_id: nil, created_at: @at},
        %{id: "c-old", body: Request.render_hold(@request, "In Progress"), parent_id: nil, created_at: @at}
      ])

      assert Projector.project_now(@ticket) == :ok
      refute_received {:memory_tracker_comment, _issue_id, _body}
      assert stored().projected.comments == %{question.id => %{comment: "c-old", reply: nil}}
    end

    test "a question asked before it said whether a request shows it is one an old record's Needs Decision hold carried, or one projected" do
      {:ok, question} = ask_unprojected(@request)
      legacy = Map.delete(question, :request)
      hold = %{kind: :needs_decision, reason: "decision", decision: %{title: @request.title, question_id: question.id}}

      assert Projector.desired(%{questions: [legacy]}).comments == []
      assert [%{question_id: id}] = Projector.desired(%{questions: [legacy], holds: [hold]}).comments
      assert id == question.id
      projected = %{comments: %{id => %{}}}
      assert [%{question_id: ^id}] = Projector.desired(%{questions: [legacy], projected: projected}).comments
    end

    test "a record whose comments were never projected counts the questions already ended as replied" do
      {:ok, question} = ask_unprojected(@request)
      {:ok, _answered} = Questions.answer(@ticket, question.id, "Ship today")
      :ok = RunStore.update_ticket_state(@repo_key, @issue_id, %{projected: %{labels: [], section: nil}})

      assert Projector.project_now(@ticket) == :ok
      refute_received {:memory_tracker_plan_comments, _issue_id}
      refute_received {:memory_tracker_reply, _issue_id, _parent, _body}
      assert %{reply: "answered:" <> _at, comment: nil} = stored().projected.comments[question.id]
    end

    test "a question that ended with its request never on Linear posts no reply" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :linear_down}])
      {:ok, question} = capture_log_result(fn -> Questions.ask(@ticket, @request, request: true, at: @at) end)
      assert stored().projected.comments == %{}

      {:ok, _answered} = Questions.answer(@ticket, question.id, "Ship today")
      refute_received {:memory_tracker_reply, _issue_id, _parent, _body}
      refute_received {:memory_tracker_comment, @issue_id, "Decision from the Director:" <> _rest}
      assert %{comment: nil, reply: "answered:" <> _at} = stored().projected.comments[question.id]
    end

    test "a request it posted that Linear no longer lists takes the reply under the id it read, else as a comment" do
      {:ok, question} = ask_unprojected(@request)
      comments!([%{id: "c-old", body: Request.render_question(question), parent_id: nil, created_at: nil}])
      assert Projector.project_now(@ticket) == :ok
      comments!([])
      {:ok, _answered} = Questions.answer(@ticket, question.id, "Ship today")
      assert_received {:memory_tracker_reply, @issue_id, "c-old", _body}

      {:ok, other} = Questions.ask(@ticket, %{@request | title: "Another call"}, request: true, at: @at)
      assert_received {:memory_tracker_comment, @issue_id, _request}
      {:ok, _answered} = Questions.answer(@ticket, other.id, "Ship today")
      assert_received {:memory_tracker_comment, @issue_id, "Decision from the Director:" <> _rest}
      assert %{comment: nil, reply: "answered:" <> _at} = stored().projected.comments[other.id]
    end

    test "a post Linear refuses leaves the Question right and the projection pending; the next apply posts it once" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :linear_down}])

      {:ok, question} = capture_log_result(fn -> Questions.ask(@ticket, @request, request: true, at: @at) end)
      refute_received {:memory_tracker_comment, _issue_id, _body}
      assert [%{state: :open}] = stored().questions
      assert [%{type: :pause, error: ":linear_down"}] = stored().pending_projection
      refute Projector.commented?(@ticket, question.id)

      assert Projector.project_now(@ticket) == :ok
      assert_received {:memory_tracker_comment, @issue_id, _body}
      assert Projector.commented?(@ticket, question.id)
    end

    test "a reply Linear refuses is pending and posted by the next apply; a comment read Linear refuses is pending" do
      {:ok, question} = ask_posted()
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :linear_down}])

      capture_log(fn -> {:ok, _answered} = Questions.answer(@ticket, question.id, "Ship today") end)
      refute_received {:memory_tracker_reply, _issue_id, _parent, _body}
      assert %{state: :answered} = Questions.find(@ticket, question.id)
      assert %{comment: nil, reply: nil} = stored().projected.comments[question.id]
      assert [%{type: :pause}] = stored().pending_projection

      Application.put_env(:symphony_elixir, :memory_tracker_plan_comments, {:error, :linear_down})
      capture_log(fn -> assert Projector.project_now(@ticket) == {:error, :linear_down} end)

      comments!([request_comment("c-1", question)])
      assert Projector.project_now(@ticket) == :ok
      assert_received {:memory_tracker_reply, @issue_id, "c-1", _body}
      assert Projector.apply(stored(), tracker: RaisingTracker) == :ok
    end

    test "commented?/3 is false for a ticket with no record or a store that can't be read" do
      refute Projector.commented?(@ticket, "q-1")
      refute Projector.commented?(@ticket, "q-1", store: FailingStore)
    end
  end

  describe "project_now/2" do
    test "projects nothing for a ticket with no record, returns a store that can't be read, and writes nothing while it is off" do
      assert Projector.project_now(@ticket) == :ok
      assert Projector.project_now(@ticket, store: FailingStore) == {:error, :boom}

      Application.put_env(:symphony_elixir, :pause_projector, false)
      refute Projector.owns?()
      assert Projector.project_now(@ticket, store: FailingStore) == :ok
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      refute_received {:memory_tracker_label_added, _issue_id, _name}
    end

    test "names the labels it writes" do
      assert Projector.labels() == ["Blocked", "Needs Decision"]
      assert Projector.question_label() == "Needs Decision"
      assert Projector.owns?()
    end
  end

  defp request_with_tradeoffs do
    put_in(@request, [:options], [
      %{label: "Ship today", effect: "TP-12 merges today.", recommended: true, tradeoffs: [%{kind: "good", text: "A day of use."}, %{kind: "risk", text: "A late bug."}]},
      %{label: "Wait for the release", effect: "TP-12 merges with the release.", tradeoffs: [%{kind: "cost", text: "A day lost."}]}
    ])
    |> Map.put(:unblocks, "the release notes")
  end

  # A request asked and posted, with Linear listing it as comment c-1.
  defp ask_posted do
    {:ok, question} = Questions.ask(@ticket, @request, request: true, at: @at)
    assert_received {:memory_tracker_comment, @issue_id, _body}
    comments!([request_comment("c-1", question)])
    {:ok, question}
  end

  # A request question asked while the projector did not own the comments.
  defp ask_unprojected(request) do
    Application.put_env(:symphony_elixir, :pause_projector, false)
    asked = Questions.ask(@ticket, request, request: true, at: @at)
    Application.put_env(:symphony_elixir, :pause_projector, true)
    asked
  end

  defp request_comment(id, question), do: %{id: id, body: Request.render_question(question), parent_id: nil, created_at: question.asked_at}

  defp comments!(comments) do
    linear = %{state_changes: [], comments: comments}
    Application.put_env(:symphony_elixir, :memory_tracker_plan_comments, %{@issue_id => linear})
  end

  defp capture_log_result(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  defp issue, do: %Issue{id: @issue_id, identifier: "TP-817", title: "T", state: "In Progress", labels: [], description: @description}

  defp flush_label_messages do
    receive do
      {:memory_tracker_label_added, _issue_id, _name} -> flush_label_messages()
      {:memory_tracker_label_removed, _issue_id, _name} -> flush_label_messages()
    after
      0 -> :ok
    end
  end

  defp stored, do: TicketState.normalize(RunStore.get_ticket_state(@repo_key, @issue_id))

  defp labels do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == @issue_id))
    |> Map.fetch!(:labels)
  end

  defp record(pause, questions \\ []), do: %{pause: pause, questions: questions}

  defp pause(reasons), do: %{subject: @ticket, reasons: reasons}

  defp reason(kind, waits_on), do: %{kind: kind, waits_on: waits_on}
end
