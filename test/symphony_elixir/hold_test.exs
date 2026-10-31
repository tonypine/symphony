defmodule SymphonyElixir.HoldTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchLoop, Hold, Pauses, Questions, RunStore, TicketState, Workflow}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses.Projector

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
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    :ok = RunStore.clear()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_add_issue_label_result)
      Application.delete_env(:symphony_elixir, :memory_tracker_remove_issue_label_result)
    end)

    :ok
  end

  describe "kinds and labels" do
    test "labels the Needs Decision hold and matches it back ignoring case and space; the Blocked hold is retired" do
      assert Hold.kinds() == [:needs_decision]
      assert Hold.label(:needs_decision) == "Needs Decision"
      assert Hold.label(:blocked) == nil
      assert Hold.label(:other) == nil

      assert Hold.kind_for_label("blocked") == nil
      assert Hold.kind_for_label(" NEEDS DECISION ") == :needs_decision
      assert Hold.kind_for_label("bug") == nil
      assert Hold.kind_for_label(nil) == nil

      assert Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting on TP-1"}) == {:error, {:unknown_hold_kind, :blocked}}
      assert Hold.clear(@repo_key, @issue_id, :blocked) == {:error, {:unknown_hold_kind, :blocked}}
    end
  end

  describe "set/5 and clear/4" do
    test "set writes the store first, then projects the label" do
      assert :ok = Hold.set(@repo_key, @issue_id, :needs_decision, %{reason: "waiting on TP-1"})

      assert [%{kind: :needs_decision, reason: "waiting on TP-1"}] =
               RunStore.get_ticket_state(@repo_key, @issue_id) |> Map.fetch!(:holds)

      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert %{reason: "waiting on TP-1"} = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert labels() == ["Needs Decision"]
    end

    test "clear drops the store hold and the label, leaving the ticket in place" do
      :ok = Hold.set(@repo_key, @issue_id, :needs_decision, %{reason: "waiting"})

      assert :ok = Hold.clear(@repo_key, @issue_id, :needs_decision)
      refute Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert labels() == []
    end

    test "a hold that appears or goes is announced as a change of the record's holds; one set over itself is not" do
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records()

      :ok = Hold.set(@repo_key, @issue_id, :needs_decision, %{reason: "waiting"})
      assert_received {:ticket_record, @repo_key, @issue_id, :changed, [:holds]}

      :ok = Hold.set(@repo_key, @issue_id, :needs_decision, %{reason: "still waiting"})
      refute_received {:ticket_record, _repo_key, _issue_id, :changed, _fields}

      :ok = Hold.clear(@repo_key, @issue_id, :needs_decision)
      assert_received {:ticket_record, @repo_key, @issue_id, :changed, [:holds]}
    end

    test "refuses a write with no repo key, touching neither the store nor the label" do
      log =
        capture_log(fn ->
          assert Hold.set(nil, @issue_id, :needs_decision) == {:error, :missing_repo_key}
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
      assert Hold.set(@repo_key, @issue_id, :needs_decision, %{}, store: FailingStore) == {:error, :boom}
      assert Hold.clear(@repo_key, @issue_id, :needs_decision, store: FailingStore) == {:error, :boom}
      assert labels() == []
    end

    test "a failed label write keeps the hold and is reported" do
      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, {:error, :boom})

      log =
        capture_log(fn ->
          assert :ok = Hold.set(@repo_key, @issue_id, :needs_decision, %{reason: "waiting"})
        end)

      assert log =~ "Failed to set the machine label"
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert labels() == []
      # The reconciler sets it again (`TicketObservation.reconcile_all/3`).
      assert [%{type: :hold_label, hold: :needs_decision, error: ":boom"}] = pending_projection()
    end

    test "a failed label clear keeps the store clear and is reported" do
      :ok = Hold.set(@repo_key, @issue_id, :needs_decision, %{reason: "waiting"})
      Application.put_env(:symphony_elixir, :memory_tracker_remove_issue_label_result, {:error, :boom})

      log = capture_log(fn -> assert :ok = Hold.clear(@repo_key, @issue_id, :needs_decision) end)

      assert log =~ "Failed to clear the machine label"
      refute Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert [%{type: :hold_label, hold: :needs_decision}] = pending_projection()
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

    test "a clear with no hold, a failed store write and an unreadable record record nothing" do
      assert :ok = Hold.clear(@repo_key, @issue_id, :needs_decision)
      assert {:error, :boom} = Hold.set(@repo_key, @issue_id, :needs_decision, @request, store: FailingStore)

      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, %{reason: "x"})
      assert {:error, :boom} = Hold.clear(@repo_key, @issue_id, :needs_decision, store: FailingStore)
      assert :ok = Hold.clear(@repo_key, @issue_id, :needs_decision, store: UnreadableStore)

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
          refute Hold.held?(nil, @issue_id, :needs_decision)
          assert Hold.get("", @issue_id, :needs_decision) == nil
        end)

      assert log =~ "Read the holds of issue_id=#{@issue_id} with no repo key"
      refute Hold.held?(@repo_key, nil, :needs_decision)
      refute Hold.held?(@repo_key, 42, :needs_decision)
    end

    test "a store read error is reported and treated as no hold" do
      log = capture_log(fn -> refute Hold.held?(@repo_key, @issue_id, :needs_decision, store: FailingStore) end)
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
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, %{reason: "waiting"})
      assert labels() == []

      assert :ok = Hold.reproject(@repo_key, @issue_id, :needs_decision)
      assert labels() == ["Needs Decision"]
      assert %{reason: "waiting"} = Hold.get(@repo_key, @issue_id, :needs_decision)
    end

    test "reports a hold the store does not have and refuses an unknown kind" do
      assert Hold.reproject(@repo_key, @issue_id, :needs_decision) == {:error, {:no_hold, :needs_decision}}
      assert Hold.reproject(@repo_key, @issue_id, :unknown) == {:error, {:unknown_hold_kind, :unknown}}
      assert labels() == []
    end

    test "a failed label write is reported and leaves the store hold in place" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, %{reason: "waiting"})
      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, {:error, :boom})

      log = capture_log(fn -> assert :ok = Hold.reproject(@repo_key, @issue_id, :needs_decision) end)

      assert log =~ "Failed to set the machine label"
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert labels() == []
    end
  end

  describe "while the pause projector owns the labels (TP-1243)" do
    setup do
      Application.put_env(:symphony_elixir, :pause_projector, true)
      on_exit(fn -> Application.put_env(:symphony_elixir, :pause_projector, false) end)
    end

    test "a Needs Decision hold gets its label from the projector, and its clear takes it off" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      assert :ok = Hold.set(@repo_key, @issue_id, :needs_decision)
      assert_received {:memory_tracker_label_added, @issue_id, "Needs Decision"}
      assert labels() == ["Needs Decision"]

      # A re-projection asserts the label again against what Linear was last seen with.
      assert :ok = Hold.reproject(@repo_key, @issue_id, :needs_decision)
      assert_received {:memory_tracker_label_added, @issue_id, "Needs Decision"}

      assert :ok = Hold.clear(@repo_key, @issue_id, :needs_decision)
      assert labels() == []
      assert pending_projection() == []
      refute_received {:memory_tracker_label_added, _issue_id, _name}
    end

    test "a Blocked hold a record kept from before its retirement shows no label: the pause alone says Blocked" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue() | labels: ["Blocked"]}])
      hold = %{kind: :blocked, reason: "needs the deploy key", waits_on: %{type: "access", keys: []}}
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, @issue_id, %{labels: ["Blocked"], holds: [hold]}))

      assert Projector.project_now({:ticket, @repo_key, @issue_id}, labels: ["Blocked"], force: true) == :ok
      assert labels() == []
      assert_received {:memory_tracker_label_removed, @issue_id, "Blocked"}

      {:ok, _pause} = Pauses.set({:ticket, @repo_key, @issue_id}, %{kind: :environment, waits_on: %{condition: "access"}, text: "needs the deploy key"})
      assert labels() == ["Blocked"]
    end

    test "a label write Linear refuses keeps the hold and marks the projection pending" do
      assert :ok = Hold.set(@repo_key, @issue_id, :needs_decision, %{reason: "waiting on TP-1"}, tracker: FailingTracker)
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert [%{type: :pause}] = pending_projection()
      assert labels() == []
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
