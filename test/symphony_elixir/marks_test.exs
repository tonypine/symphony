defmodule SymphonyElixir.MarksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  describe "note/1" do
    test "is the newest note a person left, with the first run that read it", %{ticket: ticket} do
      assert Marks.note(events(ticket)) == nil

      record!(ticket, "note", %{text: "an agent's note"}, at: at(1), actor: {:agent, "run-0", "implementation"})
      assert Marks.note(events(ticket)) == nil

      first = record!(ticket, "note", %{text: "Keep the button."}, at: at(2), actor: {:person, "the Director"})

      assert Marks.note(events(ticket)) == %{id: first.id, text: "Keep the button.", at: DateTime.to_iso8601(at(2)), by: "the Director", read_by: nil}

      :ok = Marks.record_note_read(ticket.repo_key, ticket.issue_id, "run-1")
      :ok = Marks.record_note_read(ticket.repo_key, ticket.issue_id, "run-2")

      assert %{id: id, read_by: %{run_id: "run-1", at: read_at}} = Marks.note(events(ticket))
      assert id == first.id
      assert is_binary(read_at)
      assert ticket |> events() |> Enum.count(&(&1.type == "note.read")) == 1

      # A newer note replaces it, unread until the next run.
      second = record!(ticket, "note", %{text: "Use the new copy."}, at: at(10), actor: {:person, "the Director"})
      assert %{id: id, text: "Use the new copy.", read_by: nil} = Marks.note(events(ticket))
      assert id == second.id

      :ok = Marks.record_note_read(ticket.repo_key, ticket.issue_id, "run-3")
      assert %{read_by: %{run_id: "run-3"}} = Marks.note(events(ticket))
    end

    test "a ticket with no note records no read", %{ticket: ticket} do
      assert Marks.record_note_read(ticket.repo_key, ticket.issue_id, "run-1") == :ok
      assert events(ticket) == []
    end

    test "a read the store refuses is logged, and the prompt goes on", %{ticket: ticket} do
      record!(ticket, "note", %{text: "Keep the button."}, at: at(1), actor: {:person, "the Director"})

      log = capture_log(fn -> assert Marks.record_note_read(ticket.repo_key, ticket.issue_id, " ") == :ok end)

      assert log =~ "Could not record the note's read issue_id=#{ticket.issue_id}"
      assert Marks.note(events(ticket)).read_by == nil
    end
  end

  test "person/0 is the Director" do
    assert Marks.person() == "the Director"
  end
end
