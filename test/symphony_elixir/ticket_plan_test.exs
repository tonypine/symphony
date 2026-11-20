defmodule SymphonyElixir.TicketPlanTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketEvents, TicketPlan}

  @repo_key "plan-repo"
  @issue_id "plan-issue"
  @base ~U[2026-11-20 09:00:00.000000Z]

  @check %{id: "c1", kind: "outcome", statement: "The page shows the plan.", proof: "test"}
  @plan %{
    reason: "Grooming",
    by: "grooming",
    shape: "single",
    layers: ["screen"],
    summary: "The ticket page shows the plan.",
    text: "Read the plan from the ledger and draw it.",
    checks: [@check],
    size: %{tokens: 200_000, runs: 2}
  }

  setup do
    :ok = RunStore.clear()
    :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "PLN-2"})
    :ok
  end

  defp at(minutes), do: DateTime.add(@base, minutes * 60)

  describe "the plan" do
    test "a ticket with no plan is not groomed and has none" do
      {:ok, _ask} = TicketPlan.record_ask(@repo_key, @issue_id, "Show the plan.")

      refute TicketPlan.groomed?(@issue_id)
      assert TicketPlan.current(@issue_id) == nil
      assert TicketPlan.versions(@issue_id) == []
      refute TicketPlan.groomed?("no-such-issue")
      refute TicketPlan.groomed?([])
    end

    test "each write is the next version, whatever version the plan names, and the newest is the plan" do
      assert {:ok, first} = TicketPlan.write(@repo_key, @issue_id, Map.put(@plan, :version, 7), at: at(0))
      assert first.type == "plan.written" and first.actor == %{kind: :machine}
      assert first.payload.version == 1

      changed = %{@plan | reason: "A sub-ticket ended.", by: "recalibration", summary: "Two parts."} |> Map.put("version", 1)
      assert {:ok, second} = TicketPlan.write(@repo_key, @issue_id, changed, at: at(1))
      assert second.payload.version == 2

      assert TicketPlan.groomed?(@issue_id)
      assert [%{version: 1, reason: "Grooming"}, %{version: 2, reason: "A sub-ticket ended."}] = TicketPlan.versions(@issue_id)

      current = TicketPlan.current(@issue_id)
      assert current == second.payload |> Map.merge(%{event_id: second.id, at: at(1)})
      assert current.checks == [@check]
      assert current.size == %{tokens: 200_000, runs: 2}

      # The same reads from events a caller already holds.
      events = RunStore.list_ticket_events(@issue_id, [])
      assert TicketPlan.current(events) == current
      assert TicketPlan.groomed?(events)
    end

    test "a plan given with string keys, as a turn's answer has them, is stored with atom keys" do
      answer = %{
        "reason" => "Grooming",
        "by" => "grooming",
        "shape" => "split",
        "layers" => ["api", "engine"],
        "summary" => "Two parts.",
        "text" => "Build the model, then the view.",
        "checks" => [%{"id" => "c1", "kind" => "qa", "statement" => "The panel folds.", "proof" => "qa", "state" => "A groomed ticket", "action" => "Fold it", "expect" => "One line"}],
        "size" => %{"tokens" => 1, "runs" => 1},
        "sub_tickets" => [%{"key" => "s1", "title" => "The model", "ask" => "Build it."}, %{"key" => "s2", "title" => "The view", "ask" => "Draw it.", "after" => ["s1"]}]
      }

      assert {:ok, _event} = TicketPlan.write(@repo_key, @issue_id, answer)

      assert %{version: 1, shape: "split", checks: [check], sub_tickets: sub_tickets} = TicketPlan.current(@issue_id)
      assert [%{key: "s1"}, %{key: "s2", after: ["s1"]}] = sub_tickets
      assert %{id: "c1", state: "A groomed ticket"} = check
    end

    test "a plan the schema refuses, or one that does not hold together, writes nothing" do
      assert {:error, {:invalid_payload, [:summary]}} = TicketPlan.write(@repo_key, @issue_id, Map.delete(@plan, :summary))

      qa = %{id: "c2", kind: "qa", statement: "The panel folds.", proof: "qa"}

      sub_tickets = [
        %{key: "s1", title: "The model", ask: "Build it.", after: ["s1"]},
        %{key: "s1", title: "The view", ask: "Draw it.", after: ["s9"]}
      ]

      incoherent = @plan |> Map.put(:checks, [@check, @check, qa]) |> Map.put(:sub_tickets, sub_tickets)

      assert {:error, {:invalid_plan, reasons}} = TicketPlan.write(@repo_key, @issue_id, incoherent)

      assert reasons == [
               "check id c1 is used twice",
               "QA check c2 has no action",
               "QA check c2 has no expect",
               "sub-ticket key s1 is used twice",
               "sub-ticket s1 waits after s1",
               "sub-ticket s1 waits after s9"
             ]

      refute TicketPlan.groomed?(@issue_id)
    end

    test "a signal the machinery recorded with a plan is not part of the plan" do
      payload = @plan |> Map.merge(%{version: 1, signal: "groomed", signal_details: %{turn: 1}})
      {:ok, _event} = TicketEvents.record(@repo_key, @issue_id, "plan.written", payload)

      plan = TicketPlan.current(@issue_id)
      refute Map.has_key?(plan, :signal) or Map.has_key?(plan, :signal_details)
    end
  end

  describe "the ask" do
    test "every ask, oldest first, with where it came from" do
      {:ok, first} = TicketPlan.record_ask(@repo_key, @issue_id, "Show the plan.", at: at(0))
      from_message = [source: "message", from: "evt-9", actor: {:person, "the Director"}, at: at(1)]
      {:ok, second} = TicketPlan.record_ask(@repo_key, @issue_id, "And its checks.", from_message)
      {:ok, third} = TicketPlan.record_ask(@repo_key, @issue_id, "Only the model.", source: "parent", from: "PLN-1", at: at(2))

      assert second.actor == %{kind: :person, name: "the Director"}

      assert TicketPlan.ask(@issue_id) == [
               %{text: "Show the plan.", source: "linear", from: nil, at: at(0), event_id: first.id},
               %{text: "And its checks.", source: "message", from: "evt-9", at: at(1), event_id: second.id},
               %{text: "Only the model.", source: "parent", from: "PLN-1", at: at(2), event_id: third.id}
             ]

      assert TicketPlan.ask("no-such-issue") == []
      assert {:error, {:invalid_payload, [:text]}} = TicketPlan.record_ask(@repo_key, @issue_id, " ")
      assert {:error, {:invalid_payload, [:source]}} = TicketPlan.record_ask(@repo_key, @issue_id, "x", source: "comment")
    end
  end

  describe "notes and the parent" do
    test "the notes a run tagged, oldest first; a note with no tag is not one" do
      agent = {:agent, "run-1", "implementation"}
      {:ok, _plain} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "Chose the table."}, actor: agent, at: at(0))
      {:ok, found} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "The export has no test.", tag: "discovery"}, actor: agent, at: at(1))
      {:ok, fault} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "The base build is red.", tag: "base_fault"}, actor: agent, at: at(2))

      assert TicketPlan.notes(@issue_id) == [
               %{text: "The export has no test.", tag: "discovery", at: at(1), event_id: found.id},
               %{text: "The base build is red.", tag: "base_fault", at: at(2), event_id: fault.id}
             ]
    end

    test "the parent is the ticket the record names, when Symphony holds its record" do
      assert TicketPlan.parent_id(@issue_id) == nil
      assert TicketPlan.parent_id("no-such-issue") == nil

      child = %{repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "PLN-2", parent: %{identifier: "PLN-1"}}
      :ok = RunStore.put_ticket_state(child)
      assert TicketPlan.parent_id(@issue_id) == nil

      :ok = RunStore.put_ticket_state(%{repo_key: "other-repo", issue_id: "plan-parent", issue_identifier: "PLN-1"})
      assert TicketPlan.parent_id(@issue_id) == "plan-parent"
    end
  end
end
