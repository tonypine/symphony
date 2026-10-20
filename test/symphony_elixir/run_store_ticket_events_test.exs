defmodule SymphonyElixir.RunStoreTicketEventsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TicketEvents
  alias SymphonyElixir.TicketEvents.Event

  @repo_key "repo-a"
  @issue_id "issue-1"
  @table :symphony_run_store_ticket_events
  @at ~U[2026-10-20 10:00:00.000000Z]

  setup do
    :ok = RunStore.clear()
  end

  test "the table is a bag keyed by ticket, indexed by repo, run and type" do
    assert :mnesia.table_info(@table, :type) == :bag
    assert :mnesia.table_info(@table, :attributes) == [:key, :repo_key, :issue_id, :run_id, :type, :seq, :record]
    assert :mnesia.table_info(@table, :index) |> Enum.sort() == [3, 5, 6]

    assert {:ok, event} = RunStore.append_ticket_event(event("note", %{text: "x"}, run_id: "run-1"))

    assert [{@table, {@repo_key, @issue_id}, @repo_key, @issue_id, "run-1", "note", 1, record}] =
             :mnesia.dirty_read(@table, {@repo_key, @issue_id})

    assert is_map(record) and not is_struct(record)
    assert Event.normalize(record) == event
  end

  test "100 concurrent writes on one ticket give seq 1..100 with no gap" do
    events =
      1..100
      |> Enum.map(fn n -> Task.async(fn -> TicketEvents.record(@repo_key, @issue_id, "note", %{text: "n#{n}"}) end) end)
      |> Task.await_many(30_000)
      |> Enum.map(fn {:ok, event} -> event end)

    assert events |> Enum.map(& &1.seq) |> Enum.sort() == Enum.to_list(1..100)
    assert RunStore.list_ticket_events(@repo_key, @issue_id, []) |> Enum.map(& &1.seq) |> Enum.sort() == Enum.to_list(1..100)
    assert RunStore.get_ticket_state(@repo_key, @issue_id).event_seq == 100
  end

  test "an event takes the ticket's next seq and leaves the rest of its record as it was" do
    :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, phase: "QA", issue_identifier: "TP-1"})
    :ok = RunStore.record_ticket_signal(@repo_key, @issue_id, "handoff", %{to: "QA"})
    before = RunStore.get_ticket_state(@repo_key, @issue_id)

    assert {:ok, %Event{seq: 1, phase: "QA"}} = RunStore.append_ticket_event(event("note", %{text: "x"}))
    assert {:ok, %Event{seq: 2, phase: "Rework"}} = RunStore.append_ticket_event(event("note", %{text: "y"}, phase: "Rework"))

    assert RunStore.get_ticket_state(@repo_key, @issue_id) == %{before | event_seq: 2}
  end

  test "seq never repeats when a whole-record write left the record's event_seq behind" do
    assert {:ok, %Event{seq: 1}} = RunStore.append_ticket_event(event("note", %{text: "x"}))
    assert {:ok, %Event{seq: 2}} = RunStore.append_ticket_event(event("note", %{text: "y"}))
    :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, event_seq: 1})

    assert {:ok, %Event{seq: 3}} = RunStore.append_ticket_event(event("note", %{text: "z"}))
    assert RunStore.get_ticket_state(@repo_key, @issue_id).event_seq == 3
  end

  test "append_ticket_events/1 writes one ticket's events in one transaction, each idempotency key once" do
    assert {:ok, existing} = RunStore.append_ticket_event(event("note", %{text: "a"}, idempotency: "k1"))

    batch = [
      event("note", %{text: "b"}, idempotency: "k2"),
      event("note", %{text: "a again"}, idempotency: "k1"),
      event("note", %{text: "b again"}, idempotency: "k2"),
      event("note", %{text: "c"})
    ]

    assert {:ok, [b, ^existing, b_again, c]} = RunStore.append_ticket_events(batch)
    assert b_again == b
    assert {b.seq, c.seq} == {2, 3}
    assert length(RunStore.list_ticket_events(@repo_key, @issue_id, [])) == 3
    assert RunStore.get_ticket_state(@repo_key, @issue_id).event_seq == 3

    assert {:ok, [^existing]} = RunStore.append_ticket_events([event("note", %{text: "a"}, idempotency: "k1")])
    assert RunStore.get_ticket_state(@repo_key, @issue_id).event_seq == 3
  end

  test "refuses events of more than one ticket, malformed events and a blank repo key" do
    assert RunStore.append_ticket_events([]) == {:ok, []}

    assert RunStore.append_ticket_events([event("note", %{text: "x"}), %{event("note", %{text: "y"}) | issue_id: "issue-2"}]) ==
             {:error, :mixed_ticket_events}

    assert RunStore.append_ticket_events([event("note", %{text: "x"}), %{event("note", %{text: "y"}) | repo_key: "repo-b"}]) ==
             {:error, :mixed_ticket_events}

    assert RunStore.append_ticket_events([%{text: "x"}]) == {:error, :invalid_ticket_event}
    assert RunStore.append_ticket_event(%{event("note", %{text: "x"}) | repo_key: " "}) == {:error, :invalid_repo_key}
    assert RunStore.list_ticket_events(" ", @issue_id, []) == {:error, :invalid_repo_key}
    assert RunStore.list_ticket_events(@repo_key, @issue_id, []) == []
  end

  test "list_ticket_events/3 sorts by at then seq and filters by types and run" do
    assert {:ok, late} = RunStore.append_ticket_event(event("note", %{text: "late"}, at: DateTime.add(@at, 5), run_id: "run-1"))
    assert {:ok, early} = RunStore.append_ticket_event(event("phase.entered", %{to: "QA"}, at: @at))
    assert {:ok, tie} = RunStore.append_ticket_event(event("note", %{text: "tie"}, at: @at, run_id: "run-1"))

    assert RunStore.list_ticket_events(@repo_key, @issue_id, []) == [early, tie, late]
    assert RunStore.list_ticket_events(@repo_key, @issue_id, types: ["note"]) == [tie, late]
    assert RunStore.list_ticket_events(@repo_key, @issue_id, run_id: "run-1", types: "note") == [tie, late]
    assert RunStore.list_ticket_events(@repo_key, "issue-2", []) == []
  end

  defp event(type, payload, opts \\ []) do
    at = Keyword.get(opts, :at, @at)

    %Event{
      id: Event.ulid(at),
      repo_key: @repo_key,
      issue_id: @issue_id,
      at: at,
      type: type,
      phase: Keyword.get(opts, :phase),
      run_id: Keyword.get(opts, :run_id),
      idempotency: Keyword.get(opts, :idempotency),
      payload: payload
    }
  end
end
