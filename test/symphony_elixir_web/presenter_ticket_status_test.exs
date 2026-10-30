defmodule SymphonyElixirWeb.PresenterTicketStatusTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{OperatorStop, Pauses, Questions, TransitionGuard}
  alias SymphonyElixirWeb.Presenter

  @asked ~U[2026-10-30 09:00:00Z]
  @blocked ~U[2026-10-30 10:00:00Z]
  @focus "focusing on Symphony this week"

  # Answers the snapshot it is given.
  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp orchestrator(snapshot) do
    snapshot = Map.merge(%{running: [], retrying: [], rate_limits: nil, repositories: [], dispatch_skipped: []}, snapshot)
    {:ok, pid} = SnapshotOrchestrator.start_link(snapshot)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp skipped(issue_id, identifier, repo_key \\ "default") do
    %{issue_id: issue_id, identifier: identifier, title: identifier, state: "Todo", repo_key: repo_key}
    |> Map.merge(%{reason: "blocked", since: @blocked})
  end

  test "a ticket paused on a question and a dependency reads both reasons in the order they were set; the answer leaves the dependency" do
    ticket = {:ticket, "default", "paused"}
    {:ok, question} = Questions.ask(ticket, TransitionGuard.block_report_question("MT-1"), asked_by: %{kind: :run, name: "Claude", run_id: "run-1"}, at: @asked)
    {:ok, _pause} = Pauses.add_reason(ticket, Pauses.ticket_reason(:dependency, "MT-2"), at: @blocked)
    pid = orchestrator(%{dispatch_skipped: [skipped("paused", "MT-1")]})

    assert {:ok, payload} = Presenter.issue_payload("MT-1", pid, 1_000)

    assert %{since: "2026-10-30T09:00:00Z", releasable: false, reasons: [asked, dependency]} = payload.pause
    assert %{kind: :question, text: "Waiting for your answer: " <> _title, waits_on: %{question_id: id}, set_at: "2026-10-30T09:00:00Z", releasable: false} = asked
    assert id == question.id
    assert %{kind: :ticket, text: "Waiting for MT-2 to finish", waits_on: %{identifier: "MT-2"}, set_at: "2026-10-30T10:00:00Z", releasable: false} = dependency
    assert %{set_by: %{kind: :run, name: "Claude"}} = asked

    assert [%{id: ^id, title: title, asked_by: asker, asked_at: "2026-10-30T09:00:00Z", confirm: nil}] = payload.open_questions
    assert asker == %{kind: :run, name: "Claude", run_id: "run-1"}
    assert title == question.title
    refute payload.repository_paused

    {:ok, _answered} = Questions.answer(ticket, question.id, "1")

    assert {:ok, %{pause: %{reasons: [%{kind: :ticket, text: "Waiting for MT-2 to finish"}], releasable: false}, open_questions: []}} =
             Presenter.issue_payload("MT-1", pid, 1_000)
  end

  test "a stop is the reason the Director may release, and the pause says they may" do
    :ok = OperatorStop.mark("default", "stopped", @blocked)
    {:ok, _pause} = Pauses.add_reason({:ticket, "default", "stopped"}, Pauses.ticket_reason(:dependency, "MT-2"))
    pid = orchestrator(%{dispatch_skipped: [skipped("stopped", "MT-3")]})

    assert {:ok, %{pause: %{releasable: true, reasons: [stop, dependency]}}} = Presenter.issue_payload("MT-3", pid, 1_000)
    assert %{kind: :person, releasable: true} = stop
    assert %{kind: :ticket, releasable: false} = dependency
  end

  test "a moving ticket has no pause and no open question" do
    :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "moving", issue_identifier: "MT-4"})
    pid = orchestrator(%{dispatch_skipped: [skipped("moving", "MT-4"), skipped("unknown", "MT-5")]})

    assert {:ok, %{pause: nil, open_questions: [], repository_paused: false}} = Presenter.issue_payload("MT-4", pid, 1_000)
    assert {:ok, %{pause: nil, open_questions: []}} = Presenter.issue_payload("MT-5", pid, 1_000)
  end

  test "each ticket entry of the state payload carries its pause, its open questions and its repository's pause" do
    on_exit(fn -> Pauses.clear({:repository, "hub"}) end)
    {:ok, hub_pause} = Pauses.set({:repository, "hub"}, Pauses.repository_reason(@focus), set_by: %{kind: :person, name: "Director"})
    {:ok, _pause} = Pauses.set({:ticket, "default", "skipped"}, Pauses.ticket_reason(:dependency, "MT-2"), at: @blocked)
    {:ok, question} = Questions.ask({:ticket, "default", "running"}, TransitionGuard.block_report_question("MT-R"), at: @asked)
    {:ok, _pause} = Pauses.set({:ticket, "hub", "waiting"}, Pauses.ticket_reason(:dependency, "MT-2"))

    running = %{
      issue_id: "running",
      identifier: "MT-R",
      state: "In Progress",
      repo_key: "default",
      session_id: "s-1",
      last_codex_event: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      started_at: @asked
    }

    retrying = %{issue_id: "retrying", identifier: "MT-T", repo_key: "default", attempt: 2, due_in_ms: 1_000, error: nil}
    watching = %{issue_id: "watching", identifier: "MT-W", repo_key: "hub", state: "Code Review", url: nil}
    watching = Map.merge(watching, %{last_ran_at: @asked, seconds_since_last_run: 5})
    slot_waiting = %{issue_id: "waiting", identifier: "HUB-1", repo_key: "hub", state: "Todo", reason: "work slots full", since: @asked}
    # An entry without a repo key finds its record by its id alone.
    skipped = %{skipped("skipped", "MT-S") | repo_key: nil}

    snapshot = %{
      running: [running],
      retrying: [retrying],
      watching: [watching],
      slot_waiting: [slot_waiting],
      dispatch_skipped: [skipped],
      repositories: [%{repo_key: "hub", pause: hub_pause}, %{repo_key: "default", pause: nil}]
    }

    payload = Presenter.state_payload(orchestrator(snapshot), 1_000)

    question_id = question.id
    assert [%{pause: %{reasons: [%{kind: :question}]}} = running_entry] = payload.running
    assert %{open_questions: [%{id: ^question_id}], repository_paused: false} = running_entry
    assert [%{pause: nil, open_questions: [], repository_paused: false}] = payload.retrying
    assert [%{pause: nil, open_questions: [], repository_paused: true}] = payload.watching
    assert [%{pause: %{reasons: [%{text: "Waiting for MT-2 to finish"}]}, repository_paused: true}] = payload.slot_waiting
    assert [%{pause: %{since: "2026-10-30T10:00:00Z", reasons: [%{kind: :ticket}]}} = skipped_entry] = payload.dispatch_skipped
    assert %{open_questions: [], repository_paused: false} = skipped_entry
  end
end
