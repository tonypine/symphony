defmodule SymphonyElixir.TicketBriefTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketBrief, TicketEvents}
  alias SymphonyElixir.TicketEvents.Event
  alias SymphonyElixirWeb.Presenter

  @repo "default"
  @id "brief-ticket"
  @identifier "BRF-1"
  @at ~U[2026-11-10 04:00:00.000000Z]

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
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: @id, issue_identifier: @identifier, phase: "In Progress"})
    :ok
  end

  defp orchestrator do
    snapshot = %{running: [], retrying: [], rate_limits: nil, repositories: [], dispatch_skipped: [], watching: []}
    start_supervised!({SnapshotOrchestrator, snapshot}, id: make_ref())
  end

  defp read, do: Presenter.issue_payload(@identifier, orchestrator(), 1_000) |> elem(1)

  defp write!(minutes, payload, run_id, run_kind) do
    {:ok, event} = TicketEvents.record(@repo, @id, "brief.written", payload, actor: {:agent, run_id, run_kind}, at: DateTime.add(@at, minutes * 60))
    event
  end

  test "a ticket no run briefed has no brief on its read" do
    assert read().brief == nil
    assert TicketBrief.read([]) == nil
  end

  test "the ticket read's brief is the newest one a run wrote, with who wrote it and when" do
    write!(0, %{text: "The first run's words.", walkthrough: "The first run's steps."}, "run-1", "implementation")

    newest =
      write!(30, %{text: "Each ticket says in plain words what it delivers.", walkthrough: "1. Read a ticket a run just finished.\n2. Its brief says what it delivers."}, "run-2", "rework")

    {:ok, _note} = TicketEvents.record(@repo, @id, "note", %{text: "Not a brief."}, actor: {:person, "the Director"}, at: DateTime.add(@at, 40 * 60))

    assert read().brief == %{
             id: newest.id,
             text: "Each ticket says in plain words what it delivers.",
             walkthrough: "1. Read a ticket a run just finished.\n2. Its brief says what it delivers.",
             at: DateTime.to_iso8601(newest.at),
             by: %{kind: "agent", run_kind: "rework", run_id: "run-2"}
           }

    assert %{"brief" => %{"text" => "Each ticket says in plain words what it delivers.", "by" => %{"run_kind" => "rework"}}} = read() |> Jason.encode!() |> Jason.decode!()
  end

  test "a brief the store holds without a time or a run reads with what it has" do
    actor = %{kind: :agent, run_id: nil, run_kind: "implementation"}
    event = %Event{id: "evt-1", type: "brief.written", payload: %{text: "What it does."}, actor: actor, run_id: "run-9"}

    assert TicketBrief.read([event]) == %{id: "evt-1", text: "What it does.", walkthrough: nil, at: nil, by: %{kind: "agent", run_kind: "implementation", run_id: "run-9"}}
    assert TicketBrief.current([%Event{type: "note"}, event]) == event
  end
end
