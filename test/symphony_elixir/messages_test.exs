defmodule SymphonyElixir.MessagesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Messages, TicketEvents}
  alias SymphonyElixir.TicketEvents.Event

  @repo_key "msg-repo"
  @issue_id "msg-issue"
  @base ~U[2026-11-01 09:00:00.000000Z]

  # The run store, with the failures and the events a test asks for in its process.
  defmodule Store do
    @moduledoc false
    alias SymphonyElixir.RunStore

    def get_marker(name), do: fail(:get_marker) || if(Process.get(:ignore_marker), do: nil, else: RunStore.get_marker(name))
    def put_marker(name, at), do: RunStore.put_marker(name, at)
    def list_all_ticket_states, do: fail(:list_all_ticket_states) || RunStore.list_all_ticket_states()
    def list_ticket_events(issue_id, opts), do: fail(:list_ticket_events) || Process.get(:events) || RunStore.list_ticket_events(issue_id, opts)

    defp fail(name), do: if(name in Process.get(:fail, []), do: {:error, {:failed, name}})
  end

  setup do
    :ok = RunStore.clear()
    :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "MSG-1"})
    :ok
  end

  defp at(minutes), do: DateTime.add(@base, minutes * 60)

  defp record!(type, payload, opts) do
    {:ok, event} = TicketEvents.record(@repo_key, @issue_id, type, payload, opts)
    event
  end

  defp events, do: RunStore.list_ticket_events(@issue_id, [])

  describe "send_message/4 and the reads" do
    test "each message is its own event, given to one run as new and to no other" do
      assert {:ok, first} = Messages.send_message(@repo_key, @issue_id, "Keep the button.")
      assert {:ok, second} = Messages.send_message(@repo_key, @issue_id, "Use the new copy.", by: "Sam")

      assert %{type: "message.sent", actor: %{kind: :person, name: "the Director"}} = first
      assert %{actor: %{name: "Sam"}} = second
      assert events() |> Messages.unread() |> Enum.map(& &1.id) == [first.id, second.id]

      :ok = Messages.record_read(@repo_key, @issue_id, [first, second], "run-1")
      # A second read by the same run, or by another, writes nothing more.
      :ok = Messages.record_read(@repo_key, @issue_id, [first], "run-1")
      :ok = Messages.record_read(@repo_key, @issue_id, [first], "run-2")

      assert Messages.unread(events()) == []
      assert events() |> Messages.for_run("run-1") |> Enum.map(& &1.id) == [first.id, second.id]
      assert Messages.for_run(events(), "run-2") == []
      assert events() |> Enum.count(&(&1.type == "message.read")) == 2
    end

    test "read_by/2 names the run that read a message by its title, and when" do
      record!("run.started", %{run_id: "run-7", run_kind: "code_review", run_number: 2, state: "Code Review"}, run_id: "run-7")
      message = record!("message.sent", %{text: "Look at the dialog."}, actor: {:person, "the Director"}, at: at(1))
      other = record!("message.sent", %{text: "And the footer."}, actor: {:person, "the Director"}, at: at(2))
      read = record!("message.read", %{message_id: message.id, run_id: "run-7"}, run_id: "run-7", at: at(3))

      assert Messages.read_by(message, events()) == %{run_id: "run-7", run: "Code Review run 2", at: DateTime.to_iso8601(read.at)}
      assert Messages.read_by(other, events()) == nil
      assert Messages.run_title("run-unknown", events()) == "a run"
      assert Messages.run_title(nil, events()) == "a run"

      # A read event without a time (a hand-built one) says when as nil.
      untimed = %Event{type: "message.read", payload: %{message_id: other.id, run_id: "run-7"}, at: nil}
      assert %{run: "Code Review run 2", at: nil} = Messages.read_by(other, [untimed | events()])
    end

    test "a read the store refuses is logged, and the prompt goes on" do
      {:ok, message} = Messages.send_message(@repo_key, @issue_id, "Keep the button.")

      log = capture_log(fn -> assert Messages.record_read(@repo_key, @issue_id, [message], " ") == :ok end)

      assert log =~ "Could not record a message's read issue_id=#{@issue_id}"
      assert Messages.unread(events()) == [message]
    end

    test "the prompt's section, and who wrote a message" do
      assert Messages.prompt_section([]) == nil
      assert Messages.person() == "the Director"
      assert Messages.writer(%{kind: :person, name: "Sam"}) == "Sam"
      assert Messages.writer(%{kind: :person}) == "the Director"
      assert Messages.prompt_section([%Event{type: "message.sent", actor: %{kind: :person}, payload: %{}, at: nil}]) =~ "### the Director wrote, at an unknown time\n\n"
      refute Messages.message?(%Event{type: "note"})
    end
  end

  describe "migrate/1" do
    test "turns each ticket's newest note from a person into a message, with its read, once" do
      record!("note", %{text: "An older note."}, actor: {:person, "the Director"}, at: at(1))
      record!("note", %{text: "QA waits on the PR watcher."}, at: at(2))
      note = record!("note", %{text: "Keep the button."}, actor: {:person, "Sam"}, at: at(3))
      record!("note.read", %{note_id: note.id, run_id: "run-1"}, run_id: "run-1", at: at(4))

      :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: "unread-issue", issue_identifier: "MSG-2"})
      {:ok, unread} = TicketEvents.record(@repo_key, "unread-issue", "note", %{text: "Ship it narrow."}, actor: {:person, "the Director"}, at: at(5))
      :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: "quiet-issue", issue_identifier: "MSG-3"})

      assert Messages.migrate(store: Store) == {:ok, 2}

      assert [%Event{actor: %{name: "Sam"}, payload: %{text: "Keep the button."}} = message] = Messages.messages(events())
      assert message.at == note.at
      assert %{run_id: "run-1", at: read_at} = Messages.read_by(message, events())
      assert read_at == DateTime.to_iso8601(at(4))

      assert [%Event{payload: %{text: "Ship it narrow."}} = other] = "unread-issue" |> RunStore.list_ticket_events([]) |> Messages.unread()
      assert other.at == unread.at

      assert %DateTime{} = RunStore.get_marker(Messages.marker())
      assert Messages.migrate(store: Store) == :done
      assert Messages.migrate() == :done
    end

    test "a second pass without the marker writes nothing twice" do
      note = record!("note", %{text: "Keep the button."}, actor: {:person, "the Director"}, at: at(1))
      record!("note.read", %{note_id: note.id, run_id: "run-1"}, run_id: "run-1", at: at(2))

      assert Messages.migrate(store: Store) == {:ok, 1}
      Process.put(:ignore_marker, true)
      assert Messages.migrate(store: Store) == {:ok, 1}

      assert length(Messages.messages(events())) == 1
      assert events() |> Enum.count(&(&1.type == "message.read")) == 1
    end

    test "a store that can't be read leaves the marker unset, for the next start" do
      for failure <- [:get_marker, :list_all_ticket_states, :list_ticket_events] do
        Process.put(:fail, [failure])
        assert Messages.migrate(store: Store) == {:error, {:failed, failure}}
      end

      Process.put(:fail, [])
      assert RunStore.get_marker(Messages.marker()) == nil
    end

    test "a read that can't be written leaves the marker unset" do
      note = record!("note", %{text: "Keep the button."}, actor: {:person, "the Director"}, at: at(1))
      Process.put(:events, [note, %Event{type: "note.read", payload: %{note_id: note.id}, at: at(2)}])

      log = capture_log(fn -> assert {:error, _reason} = Messages.migrate(store: Store) end)

      assert log =~ "Could not turn 1 ticket note(s) into messages"
      assert RunStore.get_marker(Messages.marker()) == nil
    end
  end
end
