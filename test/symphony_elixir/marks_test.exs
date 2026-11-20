defmodule SymphonyElixir.MarksTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Marks, RunStore, TicketEvents, TicketState}
  alias SymphonyElixir.TicketEvents.Event

  @base ~U[2026-11-09 16:00:00.000000Z]

  setup do
    n = System.unique_integer([:positive])
    ticket = %{repo_key: "marks-#{n}", issue_id: "issue-#{n}", issue_identifier: "MRK-#{n}"}
    :ok = RunStore.put_ticket_state(ticket)
    %{ticket: ticket}
  end

  defp at(minutes), do: DateTime.add(@base, minutes * 60)

  defp record!(ticket, type, payload, opts) do
    {:ok, event} = TicketEvents.record(ticket.repo_key, ticket.issue_id, type, payload, opts)
    event
  end

  defp events(ticket), do: TicketEvents.query(ticket.issue_id, limit: :all)

  describe "look/3" do
    test "writes the mark on the record by person, and the count of newer events follows it", %{ticket: ticket} do
      record!(ticket, "note", %{text: "before"}, at: at(1))
      record!(ticket, "note", %{text: "after"}, at: at(3))

      assert Marks.read(RunStore.get_ticket_state(ticket.issue_id), events(ticket)).new_since_looked == 2
      assert Marks.looked_at(RunStore.get_ticket_state(ticket.issue_id)) == nil

      assert {:ok, %{looked_at: looked_at, record: record}} = Marks.look(ticket.issue_identifier, nil, now: at(2))
      assert looked_at == at(2)
      assert record.looked == %{"the Director" => at(2)}

      stored = RunStore.get_ticket_state(ticket.issue_id)
      assert Marks.looked_at(stored) == at(2)
      assert %{looked_at: iso, new_since_looked: 1} = Marks.read(stored, events(ticket))
      assert iso == DateTime.to_iso8601(at(2))

      # The mark moves; another person's mark is kept beside it, and no ledger event records either.
      assert {:ok, _look} = Marks.look(ticket.issue_identifier, ticket.repo_key, now: at(4), person: "Sam")
      assert {:ok, _look} = Marks.look(ticket.issue_identifier, ticket.repo_key, now: at(4))
      stored = RunStore.get_ticket_state(ticket.issue_id)
      assert TicketState.normalize(stored).looked == %{"the Director" => at(4), "Sam" => at(4)}
      assert Marks.read(stored, events(ticket)).new_since_looked == 0
      assert length(events(ticket)) == 2
    end

    test "a ticket with no record, or none in the repository named, is not found", %{ticket: ticket} do
      assert Marks.look("MRK-0", nil) == {:error, :not_found}
      assert Marks.look(ticket.issue_identifier, "elsewhere") == {:error, :not_found}
    end

    test "a record that goes before the write is not found; another refused write answers its error", %{ticket: ticket} do
      vanish = fn issue_id, attrs ->
        :ok = RunStore.delete_ticket_state(issue_id)
        RunStore.update_ticket_state(issue_id, attrs)
      end

      refuse = fn _issue_id, _attrs -> {:error, :disk_full} end

      assert Marks.look(ticket.issue_identifier, ticket.repo_key, write: refuse) == {:error, :disk_full}
      assert Marks.looked_at(RunStore.get_ticket_state(ticket.issue_id)) == nil
      assert Marks.look(ticket.issue_identifier, ticket.repo_key, write: vanish) == {:error, :not_found}
    end
  end

  test "new?/2: later than the mark, every event when never looked, and none without a time" do
    event = %Event{type: "note", at: at(2)}

    assert Marks.new?(event, nil)
    assert Marks.new?(event, at(1))
    refute Marks.new?(event, at(2))
    refute Marks.new?(event, at(3))
    refute Marks.new?(%Event{type: "note", at: nil}, at(1))
  end

  test "a record's mark keeps only people and times" do
    assert TicketState.normalize(%{looked: %{"the Director" => at(1), "Sam" => "yesterday", 7 => at(1)}}).looked == %{"the Director" => at(1)}
    assert TicketState.normalize(%{looked: "now"}).looked == %{}
  end

  describe "read/2's messages" do
    test "counts the messages no run read yet, and serves no note", %{ticket: ticket} do
      read = fn -> Marks.read(RunStore.get_ticket_state(ticket.issue_id), events(ticket)) end
      assert read.() |> Map.keys() |> Enum.sort() == [:looked_at, :new_since_looked, :unread_messages]
      assert %{unread_messages: 0} = read.()

      # Symphony's notes and an agent's are not messages.
      record!(ticket, "note", %{text: "an agent's note"}, at: at(1), actor: {:agent, "run-0", "implementation"})
      record!(ticket, "note", %{text: "QA waits on the PR watcher"}, at: at(1))
      assert %{unread_messages: 0} = read.()

      first = record!(ticket, "message.sent", %{text: "Keep the button."}, at: at(2), actor: {:person, "the Director"})
      second = record!(ticket, "message.sent", %{text: "Use the new copy."}, at: at(3), actor: {:person, "the Director"})

      assert %{unread_messages: 2} = read.()

      record!(ticket, "message.read", %{message_id: second.id, run_id: "run-1"}, run_id: "run-1")
      assert %{unread_messages: 1} = read.()

      record!(ticket, "message.read", %{message_id: first.id, run_id: "run-1"}, run_id: "run-1")
      assert %{unread_messages: 0} = read.()
    end
  end

  test "person/0 is the Director" do
    assert Marks.person() == "the Director"
  end
end
