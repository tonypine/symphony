defmodule SymphonyElixir.Pauses.ReviewFocusTest do
  @moduledoc """
  The review-focus scenarios of the Pauses design (TP-1256), end to end through the real writers:
  every question is a Question (`SymphonyElixir.Questions`), the ticket's pause holds its reasons
  (`SymphonyElixir.Pauses`), and the pause projector alone writes the `Blocked` and `Needs Decision`
  labels (`SymphonyElixir.Pauses.Projector`), with no hold beside them.
  """
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{DecisionRequest, DirectorMoves, Pauses, Questions, TicketState, Workflow}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses.{Backfill, Projector}
  alias SymphonyElixir.TicketEvents.Backfill, as: LedgerBackfill
  alias SymphonyElixir.TicketEvents.Brief

  @repo_key "repo-a"
  @issue_id "issue-1"
  @ticket {:ticket, @repo_key, @issue_id}
  @at ~U[2026-10-30 04:00:00Z]

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

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :pause_projector, true)
    :ok = RunStore.clear()

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :pause_projector, false)

      Enum.each([:memory_tracker_recipient, :memory_tracker_add_issue_label_result], &Application.delete_env(:symphony_elixir, &1))
    end)

    :ok
  end

  test "a question plus a dependency: both reasons show, the answer clears the question, the dependency finishing sets it moving, and the labels follow each step" do
    assert :ok = DecisionRequest.ask(issue(), @request, [])
    assert_received {:memory_tracker_label_added, @issue_id, "Needs Decision"}
    assert_received {:memory_tracker_comment, @issue_id, "## Decision needed: Ship TP-12 before the release" <> _rest}

    {:ok, _pause} = Pauses.add_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
    assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}

    # Its page lists both reasons.
    %{id: id} = Questions.deciding(@ticket)
    assert [%{kind: :question, waits_on: %{question_id: ^id}}, %{kind: :ticket}] = reasons()
    assert labels() == ["Blocked", "Needs Decision"]

    # The Director's Decide answers the Question the ticket waits on: only its reason goes.
    assert {:ok, %{moved: false}} = DirectorMoves.move(:decide, "TP-817", %{picks: [%{question: @request.question, answer: "Ship today"}], question_id: id}, decide_opts())
    assert %{state: :answered, answer: %{text: "Ship today"}} = Questions.find(@ticket, id)
    assert [%{kind: :ticket}] = reasons()
    assert_received {:memory_tracker_label_removed, @issue_id, "Needs Decision"}
    assert labels() == ["Blocked"]

    # The dependency finishing lifts the pause: the ticket moves again.
    {:ok, nil} = Pauses.clear_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
    refute Pauses.paused?(@ticket)
    assert_received {:memory_tracker_label_removed, @issue_id, "Blocked"}
    assert labels() == []
  end

  test "the same question asked twice is one Question, one pause reason and one request comment" do
    assert :ok = DecisionRequest.ask(issue(), @request, [])
    assert :ok = DecisionRequest.ask(issue(), %{@request | why: "Asked again in other words."}, [])

    assert [_question] = Questions.open(@ticket)
    assert [%{kind: :question}] = reasons()
    assert_received {:memory_tracker_comment, @issue_id, _body}
    refute_received {:memory_tracker_comment, _issue_id, _body}
    assert_received {:memory_tracker_label_added, @issue_id, "Needs Decision"}
    refute_received {:memory_tracker_label_added, _issue_id, _name}
  end

  test "a stop while a question is open keeps both reasons, and releasing the stop leaves the question waiting" do
    assert :ok = DecisionRequest.ask(issue(), @request, [])
    assert :ok = Pauses.stop(@ticket, @at)

    assert [%{kind: :question}, stop] = reasons()
    assert Pauses.stop_reason?(stop)
    assert labels() == ["Blocked", "Needs Decision"]

    assert :ok = Pauses.release_stop(@ticket, by: Pauses.director())
    assert [%{kind: :question}] = reasons()
    assert %{state: :open} = Questions.deciding(@ticket)
    assert labels() == ["Needs Decision"]
  end

  test "a backfilled ticket: its old holds and decisions become Questions, the holds are dropped, and its history shows every decision with its answer" do
    {:ok, carried} = Questions.ask(@ticket, @request, backfilled: true, id: "q-carried", at: @at)
    assert carried.request == nil

    decision = %{key: "comment-0", date: ~D[2026-10-13], title: "Keep the flag", question: "Keep the flag on?", answer: "Keep it on", scope: "As answered"}
    {:ok, _decisions} = RunStore.record_ticket_decisions(@repo_key, @issue_id, [decision], [])

    # The history backfill records the stored decision as the answer it was.
    assert {:ok, _outcome} = LedgerBackfill.run(now: @at)

    holds = [
      # A hold an old record kept for a request asked before questions: it becomes an open Question.
      %{kind: :needs_decision, reason: "Rotate the token?", decision: %{title: "Rotate the CI token", question: "Rotate the CI token now?", options: ["**Rotate it**: Now."]}, set_at: @at},
      # A hold beside a Question asked live: the Question is the truth, so it writes nothing.
      %{kind: :blocked, reason: "loop", waits_on: %{type: "dispatch_loop", keys: [], question_id: "q-carried"}, set_at: @at}
    ]

    # Written as a record stored before the holds were retired: the store's own write would drop them.
    raw = Map.put(RunStore.get_ticket_state(@repo_key, @issue_id), :holds, holds)
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({:symphony_run_store_ticket_states, {@repo_key, @issue_id}, @repo_key, @issue_id, raw}) end)

    # Read, the record drops its holds; a question a Needs Decision hold carried reads as asked with a request.
    carrying = Map.put(raw, :holds, [%{kind: :needs_decision, decision: %{title: @request.title, question_id: "q-carried"}}])
    assert %{questions: [%{id: "q-carried", request: true}]} = normalized = TicketState.normalize(carrying)
    refute Map.has_key?(normalized, :holds)

    assert {:ok, %{records_converted: 1, questions_created: 2}} = Backfill.run(now: @at)

    questions = TicketState.normalize(RunStore.get_ticket_state(@repo_key, @issue_id)).questions
    assert %{state: :open} = Enum.find(questions, &(&1.title == "Rotate the CI token"))
    assert %{state: :answered, answer: %{text: "Keep it on"}} = Enum.find(questions, &(&1.title == "Keep the flag"))

    assert {:ok, %{text: brief}} = Brief.render(@repo_key, @issue_id)
    assert brief =~ "Phase and pauses:"
    assert brief =~ "Keep the flag"
    assert brief =~ "Keep it on"
  end

  test "Linear down: the question still lands, the record marks its labels pending, and the next projection writes them" do
    Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, {:error, :linear_down})

    capture_log(fn -> assert :ok = DecisionRequest.ask(issue(), @request, []) end)
    assert [%{state: :open}] = Questions.open(@ticket)
    assert [%{kind: :question}] = reasons()
    assert labels() == []
    assert [%{type: :pause} = mark] = stored().pending_projection

    Application.delete_env(:symphony_elixir, :memory_tracker_add_issue_label_result)
    assert :ok = Projector.apply(stored())
    assert_received {:memory_tracker_label_added, @issue_id, "Needs Decision"}
    assert labels() == ["Needs Decision"]

    :ok = SymphonyElixir.TicketSignals.clear_projection(@repo_key, @issue_id, mark)
    assert stored().pending_projection == []
  end

  defp decide_opts do
    server = :"review_focus_moves_#{System.unique_integer([:positive])}"
    start_supervised!({DirectorMoves, name: server})
    audit_dir = Path.join(System.tmp_dir!(), "review-focus-audit-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:symphony_elixir, :audit_log_dir)
    Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :audit_log_dir, previous),
        else: Application.delete_env(:symphony_elixir, :audit_log_dir)

      File.rm_rf(audit_dir)
    end)

    [server: server, clock: fn -> 0 end]
  end

  defp issue, do: %Issue{id: @issue_id, identifier: "TP-817", title: "T", state: "In Progress", labels: [], description: "Ship it.", repo_key: @repo_key}

  defp reasons, do: TicketState.pause_reasons(stored())

  defp stored, do: TicketState.normalize(RunStore.get_ticket_state(@repo_key, @issue_id))

  defp labels do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == @issue_id))
    |> Map.fetch!(:labels)
    |> Enum.sort()
  end
end
