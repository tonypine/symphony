defmodule SymphonyElixir.HoldTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchLoop, Hold, Pauses, Questions, RunStore, TicketState, Workflow}
  alias SymphonyElixir.Hold.Drift
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-a"
  @issue_id "issue-1"

  defmodule FailingStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :boom}
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :boom}
    def list_ticket_states(_repo_key), do: {:error, :boom}
  end

  # The record can't be read, but the clear lands.
  defmodule UnreadableStore do
    def clear_ticket_hold(repo_key, issue_id, kind), do: RunStore.clear_ticket_hold(repo_key, issue_id, kind)
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :boom}
  end

  defmodule FailingTracker do
    def set_machine_label(_issue_id, _name), do: {:error, :boom}
    def clear_machine_label(_issue_id, _name), do: {:error, :boom}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    :ok = RunStore.clear()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_add_issue_label_result)
      Application.delete_env(:symphony_elixir, :memory_tracker_remove_issue_label_result)
    end)

    :ok
  end

  describe "kinds and labels" do
    test "labels the two holds and matches them back ignoring case and space" do
      assert Hold.kinds() == [:blocked, :needs_decision]
      assert Hold.label(:blocked) == "Blocked"
      assert Hold.label(:needs_decision) == "Needs Decision"
      assert Hold.label(:other) == nil

      assert Hold.kind_for_label("blocked") == :blocked
      assert Hold.kind_for_label(" NEEDS DECISION ") == :needs_decision
      assert Hold.kind_for_label("bug") == nil
      assert Hold.kind_for_label(nil) == nil
    end
  end

  describe "unblockable?/1 and dispatch_loop?/1" do
    test "an access or dispatch-loop hold waits on a person's Unblock; only the latter is a loop" do
      assert Hold.unblockable?(%{waits_on: %{type: "access", keys: []}})
      assert Hold.unblockable?(%{waits_on: %{type: "dispatch_loop", keys: ["implementation"]}})
      assert Hold.unblockable?(%{waits_on: %{type: "operator_stop", keys: []}})
      refute Hold.unblockable?(%{waits_on: %{type: "dependency", keys: ["TP-1"]}})
      refute Hold.unblockable?(%{reason: "no waits_on"})
      refute Hold.unblockable?(nil)

      # A quiet handoff's hold waits on the question Symphony asked beside it.
      assert Hold.unblockable?(%{waits_on: %{type: "handoff_missing", keys: [], question_id: "q-1"}})
      refute Hold.unblockable?(%{waits_on: %{type: "handoff_missing", keys: []}})

      assert Hold.dispatch_loop?(%{waits_on: %{type: SymphonyElixir.DispatchLoop.hold_type(), keys: []}})
      refute Hold.dispatch_loop?(%{waits_on: %{type: "access", keys: []}})
      refute Hold.dispatch_loop?(nil)
    end
  end

  describe "set/5 and clear/4" do
    test "set writes the store first, then projects the label" do
      assert :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting on TP-1"})

      assert [%{kind: :blocked, reason: "waiting on TP-1"}] =
               RunStore.get_ticket_state(@repo_key, @issue_id) |> Map.fetch!(:holds)

      assert Hold.held?(@repo_key, @issue_id, :blocked)
      assert %{reason: "waiting on TP-1"} = Hold.get(@repo_key, @issue_id, :blocked)
      assert labels() == ["Blocked"]
    end

    test "clear drops the store hold and the label, leaving the ticket in place" do
      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting"})

      assert :ok = Hold.clear(@repo_key, @issue_id, :blocked)
      refute Hold.held?(@repo_key, @issue_id, :blocked)
      assert labels() == []
    end

    test "a hold that appears or goes is announced as a change of the record's holds; one set over itself is not" do
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records()

      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting"})
      assert_received {:ticket_record, @repo_key, @issue_id, :changed, [:holds]}

      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "still waiting"})
      :ok = Hold.clear(@repo_key, @issue_id, :needs_decision)
      refute_received {:ticket_record, _repo_key, _issue_id, :changed, _fields}

      :ok = Hold.clear(@repo_key, @issue_id, :blocked)
      assert_received {:ticket_record, @repo_key, @issue_id, :changed, [:holds]}
    end

    test "refuses a write with no repo key, touching neither the store nor the label" do
      log =
        capture_log(fn ->
          assert Hold.set(nil, @issue_id, :blocked) == {:error, :missing_repo_key}
          assert Hold.clear("", @issue_id, :needs_decision) == {:error, :missing_repo_key}
        end)

      assert log =~ "Refused a hold write on issue_id=#{@issue_id} with no repo key"
      assert labels() == []
    end

    test "refuses a kind it does not know" do
      assert Hold.set(@repo_key, @issue_id, :unknown, %{reason: "x"}) == {:error, {:unknown_hold_kind, :unknown}}
      assert Hold.clear(@repo_key, @issue_id, :unknown) == {:error, {:unknown_hold_kind, :unknown}}
      assert labels() == []
    end

    test "a failed store write fails the set and touches no label" do
      assert Hold.set(@repo_key, @issue_id, :blocked, %{}, store: FailingStore) == {:error, :boom}
      assert Hold.clear(@repo_key, @issue_id, :blocked, store: FailingStore) == {:error, :boom}
      assert labels() == []
    end

    test "a failed label write keeps the hold and is reported" do
      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, {:error, :boom})

      log =
        capture_log(fn ->
          assert :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting"})
        end)

      assert log =~ "Failed to set the machine label"
      assert Hold.held?(@repo_key, @issue_id, :blocked)
      assert labels() == []
      # The reconciler sets it again (`TicketObservation.reconcile_all/3`).
      assert [%{type: :hold_label, hold: :blocked, error: ":boom"}] = pending_projection()
    end

    test "a failed label clear keeps the store clear and is reported" do
      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting"})
      Application.put_env(:symphony_elixir, :memory_tracker_remove_issue_label_result, {:error, :boom})

      log = capture_log(fn -> assert :ok = Hold.clear(@repo_key, @issue_id, :blocked) end)

      assert log =~ "Failed to clear the machine label"
      refute Hold.held?(@repo_key, @issue_id, :blocked)
      assert [%{type: :hold_label, hold: :blocked}] = pending_projection()
    end
  end

  describe "a hold set beside a question" do
    setup do
      ticket = {:ticket, @repo_key, @issue_id}
      {:ok, question} = Questions.ask(ticket, DispatchLoop.question_attrs({:quiet_handoff, 2}, "MOT-1"))
      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "quiet", waits_on: %{type: "handoff_missing", keys: [], question_id: question.id}})
      %{ticket: ticket, question: question}
    end

    test "keeps the question's id and is cleared with it: the answer given, or Symphony's withdrawal", %{ticket: ticket, question: question} do
      assert %{waits_on: %{question_id: id}} = Hold.get(@repo_key, @issue_id, :blocked)
      assert id == question.id

      director = %{kind: :person, name: "Director"}
      assert :ok = Hold.clear(@repo_key, @issue_id, :blocked, question: {:answer, "Run it again", director})
      refute Hold.held?(@repo_key, @issue_id, :blocked)
      assert %{state: :answered, answer: %{option: 1, by: ^director}} = Questions.find(ticket, question.id)
      assert {:ok, nil} = Pauses.get(ticket)

      {:ok, again} = Questions.ask(ticket, DispatchLoop.question_attrs({:quiet_handoff, 3}, "MOT-1"))
      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{waits_on: %{type: "dispatch_loop", keys: [], question_id: again.id}})
      assert :ok = Hold.clear(@repo_key, @issue_id, :blocked)
      assert %{state: :withdrawn, withdrawn: %{reason: "Symphony lifted the pause it was asked with."}} = Questions.find(ticket, again.id)
    end

    test "a question already ended, or gone, ends nothing; one the store refuses keeps the hold", %{ticket: ticket, question: question} do
      {:ok, _withdrawn} = Questions.withdraw(ticket, question.id, "no longer needed")
      assert :ok = Hold.clear(@repo_key, @issue_id, :blocked)
      refute Hold.held?(@repo_key, @issue_id, :blocked)

      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{waits_on: %{type: "handoff_missing", keys: [], question_id: "gone"}})
      assert :ok = Hold.clear(@repo_key, @issue_id, :blocked)

      {:ok, open} = Questions.ask(ticket, DispatchLoop.question_attrs({:quiet_handoff, 4}, "MOT-1"))
      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{waits_on: %{type: "handoff_missing", keys: [], question_id: open.id}})
      assert {:error, {:invalid_actor, :nobody}} = Hold.clear(@repo_key, @issue_id, :blocked, question: {:answer, "Run it again", :nobody})
      assert Hold.held?(@repo_key, @issue_id, :blocked)
      assert %{state: :open} = Questions.find(ticket, open.id)
    end
  end

  describe "a Needs Decision hold that projects a Question" do
    setup do
      ticket = {:ticket, @repo_key, @issue_id}
      {:ok, question} = Questions.ask(ticket, DispatchLoop.question_attrs({:quiet_handoff, 2}, "MOT-1"))
      attrs = %{reason: question.question, decision: %{title: question.title, question: question.question, question_id: question.id}}
      :ok = Hold.set(@repo_key, @issue_id, :needs_decision, attrs)
      %{ticket: ticket, question: question, attrs: attrs}
    end

    test "records no decision event: the Question's own events are the request and its end", %{ticket: ticket, question: question} do
      assert :ok = Hold.clear(@repo_key, @issue_id, :needs_decision)
      assert %{state: :withdrawn} = Questions.find(ticket, question.id)
      assert ticket_events(@repo_key, @issue_id, ["decision.requested", "decision.withdrawn"]) == []
      assert [{"question.asked", _asked}, {"question.withdrawn", _withdrawn}] = ticket_events(@repo_key, @issue_id, ["question.asked", "question.withdrawn"])
    end

    test "an answered clear answers the Question with the answer given", %{ticket: ticket, question: question} do
      director = %{kind: :person, name: "Director"}
      assert :ok = Hold.clear(@repo_key, @issue_id, :needs_decision, answered: true, question: {:answer, "Run it again", director})
      assert %{state: :answered, answer: %{option: 1, text: "Run it again"}} = Questions.find(ticket, question.id)
      assert {:ok, nil} = Pauses.get(ticket)
    end

    test "an answered clear with no answer given leaves the Question to the answer's writer", %{ticket: ticket, question: question} do
      assert :ok = Hold.clear(@repo_key, @issue_id, :needs_decision, answered: true)
      refute Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert %{state: :open} = Questions.find(ticket, question.id)
      assert ticket_events(@repo_key, @issue_id, ["decision.withdrawn"]) == []
    end
  end

  describe "the events a hold write records" do
    @request %{
      reason: "A or B?",
      clearing_condition: "when the decision is recorded",
      decision: %{title: "Pick one", question: "A or B?", why: "Both work.", options: ["**A**: do A", "**B**: do B"], asked_at: nil}
    }

    test "a Blocked hold records one hold.set, and one hold.cleared when it clears" do
      attrs = %{reason: "waiting on TP-1", clearing_condition: "when TP-1 is done", waits_on: %{type: "dependency", keys: ["TP-1"]}}

      assert :ok = Hold.set(@repo_key, @issue_id, :blocked, attrs)
      assert :ok = Hold.set(@repo_key, @issue_id, :blocked, attrs)
      assert [{"hold.set", %{kind: "blocked", reason: "waiting on TP-1", waits_on: %{type: "dependency", keys: ["TP-1"]}}}] = ticket_events(@repo_key, @issue_id)

      assert :ok = Hold.clear(@repo_key, @issue_id, :blocked)
      assert :ok = Hold.clear(@repo_key, @issue_id, :blocked)
      assert [{"hold.set", _set}, {"hold.cleared", %{kind: "blocked"}}] = ticket_events(@repo_key, @issue_id)

      assert :ok = Hold.set(@repo_key, @issue_id, :blocked, attrs)
      assert :ok = Hold.set(@repo_key, @issue_id, :blocked, %{attrs | reason: "waiting on TP-1 and TP-2"})
      assert ["hold.set", "hold.cleared", "hold.set", "hold.set"] = Enum.map(ticket_events(@repo_key, @issue_id), &elem(&1, 0))
    end

    test "a clear with no hold, a failed store write and an unreadable record record nothing" do
      assert :ok = Hold.clear(@repo_key, @issue_id, :blocked)
      assert :ok = Hold.clear(@repo_key, @issue_id, :needs_decision)
      assert {:error, :boom} = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "x"}, store: FailingStore)
      assert {:error, :boom} = Hold.set(@repo_key, @issue_id, :needs_decision, @request, store: FailingStore)

      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, %{reason: "x"})
      assert {:error, :boom} = Hold.clear(@repo_key, @issue_id, :blocked, store: FailingStore)
      assert :ok = Hold.clear(@repo_key, @issue_id, :blocked, store: UnreadableStore)

      assert ticket_events(@repo_key, @issue_id) == []
    end

    test "a Needs Decision hold records its decision.requested, once per request, and never a hold event" do
      assert :ok = Hold.set(@repo_key, @issue_id, :needs_decision, @request)
      assert :ok = Hold.set(@repo_key, @issue_id, :needs_decision, @request)
      assert :ok = Hold.set(@repo_key, @issue_id, :needs_decision, put_in(@request, [:decision, :question], " a  or\nB? "))

      assert [{"decision.requested", %{title: "Pick one", question: "A or B?", why: "Both work.", options: ["**A**: do A", "**B**: do B"]}}] =
               ticket_events(@repo_key, @issue_id)

      confirm = put_in(@request, [:decision, :confirm], "Merging")
      reworded = put_in(confirm, [:decision, :question], "A, B or C?")
      assert :ok = Hold.set(@repo_key, @issue_id, :needs_decision, reworded)
      assert [_first, {"decision.requested", %{question: "A, B or C?", confirm: "Merging"}}] = ticket_events(@repo_key, @issue_id)
    end

    test "a request with no decision payload is asked by its reason, and one with neither records nothing" do
      assert :ok = Hold.set(@repo_key, @issue_id, :needs_decision, %{reason: "Approve the dependency?"})
      assert :ok = Hold.set(@repo_key, "issue-2", :needs_decision, %{})

      assert [{"decision.requested", %{question: "Approve the dependency?"} = payload}] = ticket_events(@repo_key, @issue_id)
      refute Map.has_key?(payload, :title)
      assert ticket_events(@repo_key, "issue-2") == []
    end

    test "a Needs Decision clear is a withdrawal naming the request, unless the caller says it was answered" do
      :ok = Hold.set(@repo_key, @issue_id, :needs_decision, @request)
      [%{id: request_id}] = RunStore.list_ticket_events(@repo_key, @issue_id, [])

      assert :ok = Hold.clear(@repo_key, @issue_id, :needs_decision)

      assert [_requested, {"decision.withdrawn", %{title: "Pick one", question: "A or B?", request: ^request_id}}] =
               ticket_events(@repo_key, @issue_id)

      :ok = Hold.set(@repo_key, "issue-2", :needs_decision, @request)
      assert :ok = Hold.clear(@repo_key, "issue-2", :needs_decision, answered: true)
      assert [{"decision.requested", _payload}] = ticket_events(@repo_key, "issue-2")

      :ok = RunStore.set_ticket_hold(@repo_key, "issue-3", :needs_decision, %{})
      assert :ok = Hold.clear(@repo_key, "issue-3", :needs_decision)
      assert [{"decision.withdrawn", %{title: "Decision request"} = withdrawn}] = ticket_events(@repo_key, "issue-3")
      refute Map.has_key?(withdrawn, :request)
    end
  end

  describe "get/4 and held?/4" do
    test "read nothing without a repo key or an issue id, and say so for a ticket read with no repo key" do
      log =
        capture_log(fn ->
          refute Hold.held?(nil, @issue_id, :blocked)
          assert Hold.get("", @issue_id, :blocked) == nil
        end)

      assert log =~ "Read the holds of issue_id=#{@issue_id} with no repo key"
      refute Hold.held?(@repo_key, nil, :blocked)
      refute Hold.held?(@repo_key, 42, :blocked)
    end

    test "a store read error is reported and treated as no hold" do
      log = capture_log(fn -> refute Hold.held?(@repo_key, @issue_id, :blocked, store: FailingStore) end)
      assert log =~ "Failed to read the ticket state"
    end
  end

  describe "held_issue_ids/2" do
    test "lists the repo's tickets the store holds, whatever the kind, and no other" do
      :ok = RunStore.set_ticket_hold(@repo_key, "decision", :needs_decision, %{reason: "Ship it?"})
      :ok = RunStore.set_ticket_hold(@repo_key, "blocked", :blocked, %{reason: "waiting on TP-1"})
      :ok = RunStore.set_ticket_hold("repo-b", "elsewhere", :blocked, %{reason: "waiting on TP-2"})
      :ok = RunStore.set_ticket_hold(@repo_key, "cleared", :blocked, %{reason: "waiting on TP-3"})
      :ok = RunStore.clear_ticket_hold(@repo_key, "cleared", :blocked)

      assert {:ok, ids} = Hold.held_issue_ids(@repo_key)
      assert Enum.sort(ids) == ["blocked", "decision"]
    end

    test "hands back a store read error" do
      assert Hold.held_issue_ids(@repo_key, store: FailingStore) == {:error, :boom}
    end
  end

  describe "reproject/4" do
    test "re-asserts a store hold's label without touching the store" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, %{reason: "waiting"})
      assert labels() == []

      assert :ok = Hold.reproject(@repo_key, @issue_id, :blocked)
      assert labels() == ["Blocked"]
      assert %{reason: "waiting"} = Hold.get(@repo_key, @issue_id, :blocked)
    end

    test "reports a hold the store does not have and refuses an unknown kind" do
      assert Hold.reproject(@repo_key, @issue_id, :blocked) == {:error, {:no_hold, :blocked}}
      assert Hold.reproject(@repo_key, @issue_id, :unknown) == {:error, {:unknown_hold_kind, :unknown}}
      assert labels() == []
    end

    test "a failed label write is reported and leaves the store hold in place" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, %{reason: "waiting"})
      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, {:error, :boom})

      log = capture_log(fn -> assert :ok = Hold.reproject(@repo_key, @issue_id, :blocked) end)

      assert log =~ "Failed to set the machine label"
      assert Hold.held?(@repo_key, @issue_id, :blocked)
      assert labels() == []
    end
  end

  describe "drift/2" do
    test "is ok when the store and the board agree" do
      held = TicketState.set_hold(TicketState.new(@repo_key, @issue_id), :blocked, %{reason: "waiting"})

      assert Hold.drift(held, ["Blocked", "bug"]) == :ok
      assert Hold.drift(TicketState.new(@repo_key, @issue_id), ["bug"]) == :ok
      assert Hold.drift(TicketState.new(@repo_key, @issue_id), nil) == :ok
      # A label that is not a string is not a hold label.
      assert Hold.drift(TicketState.new(@repo_key, @issue_id), [nil, 5]) == :ok
    end

    test "reports a board label with no store hold as a hand-added label" do
      assert Hold.drift(TicketState.new(@repo_key, @issue_id), ["blocked"]) == {:stray_label, :blocked}
    end

    test "reports a store hold the board is missing" do
      held = TicketState.set_hold(TicketState.new(@repo_key, @issue_id), :needs_decision, %{reason: "pick"})

      assert Hold.drift(held, []) == {:missing_label, :needs_decision}
      assert Hold.drift(held, nil) == {:missing_label, :needs_decision}
    end
  end

  describe "report_drift/4" do
    test "reports a stray label and a missing label, and is quiet when they agree" do
      log =
        capture_log(fn ->
          assert Hold.report_drift(@repo_key, @issue_id, ["Blocked"]) == {:stray_label, :blocked}
        end)

      assert log =~ "with no store hold"

      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting"})

      log = capture_log(fn -> assert Hold.report_drift(@repo_key, @issue_id, []) == {:missing_label, :blocked} end)
      assert log =~ "is missing its machine label"

      assert Hold.report_drift(@repo_key, @issue_id, ["Blocked"]) == :ok
    end

    test "records the drift per ticket and logs it once per change, not on every poll" do
      at = ~U[2026-10-19 21:00:00Z]
      opts = [identifier: "TP-817", url: "https://linear.app/t/issue/TP-817", now: at]

      log =
        capture_log(fn ->
          for _poll <- 1..3, do: assert(Hold.report_drift(@repo_key, @issue_id, ["Blocked"], opts) == {:stray_label, :blocked})
        end)

      assert length(String.split(log, "with no store hold")) == 2

      assert [%{identifier: "TP-817", url: "https://linear.app/t/issue/TP-817", drift: {:stray_label, :blocked}, since: ^at}] =
               Drift.entries()

      # It turns the other way: a change, logged once more.
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, %{reason: "waiting"})
      log = capture_log(fn -> Hold.report_drift(@repo_key, @issue_id, [], opts) end)
      assert log =~ "is missing its machine label"

      # It clears, and is forgotten: the next drift is new again.
      assert Hold.report_drift(@repo_key, @issue_id, ["Blocked"], opts) == :ok
      assert Drift.entries() == []
      :ok = RunStore.clear_ticket_hold(@repo_key, @issue_id, :blocked)
      assert capture_log(fn -> Hold.report_drift(@repo_key, @issue_id, ["Blocked"], opts) end) =~ "with no store hold"
    end

    test "drift read with no repo key is logged every time and not recorded" do
      log = capture_log(fn -> for _poll <- 1..2, do: Hold.report_drift(nil, @issue_id, ["Blocked"]) end)

      assert length(String.split(log, "with no store hold")) == 3
      assert Drift.entries() == []
      assert Hold.report_drift(nil, @issue_id, []) == :ok
    end
  end

  describe "resync/4" do
    test "clears a label with no store hold, sets one a store hold is missing, and forgets the drift" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue() | labels: ["Blocked"]}])
      capture_log(fn -> Hold.report_drift(@repo_key, @issue_id, ["Blocked"]) end)

      assert Hold.resync(@repo_key, @issue_id, :blocked) == :ok
      assert labels() == []
      assert Drift.entries() == []

      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, %{reason: "pick"})
      assert Hold.resync(@repo_key, @issue_id, :needs_decision) == :ok
      assert labels() == ["Needs Decision"]
    end

    test "returns the label write the tracker refuses, and keeps the drift" do
      capture_log(fn -> Hold.report_drift(@repo_key, @issue_id, ["Blocked"]) end)

      assert Hold.resync(@repo_key, @issue_id, :blocked, tracker: FailingTracker) == {:error, :boom}
      assert [%{drift: {:stray_label, :blocked}}] = Drift.entries()
    end

    test "refuses an unknown kind and a ticket with no repo key" do
      assert Hold.resync(@repo_key, @issue_id, :other) == {:error, {:unknown_hold_kind, :other}}
      assert capture_log(fn -> assert Hold.resync(nil, @issue_id, :blocked) == {:error, :missing_repo_key} end) =~ "no repo key"
    end
  end

  defp issue do
    %Issue{id: @issue_id, identifier: "TP-817", title: "T", state: "Todo", labels: []}
  end

  defp pending_projection, do: RunStore.get_ticket_state(@repo_key, @issue_id).pending_projection

  defp labels do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == @issue_id))
    |> Map.fetch!(:labels)
  end
end
