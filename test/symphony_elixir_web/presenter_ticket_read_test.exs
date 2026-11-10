defmodule SymphonyElixirWeb.PresenterTicketReadTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketColumns, TicketState}
  alias SymphonyElixirWeb.Presenter

  @started ~U[2026-11-10 04:00:00Z]

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

  defp orchestrator(snapshot \\ %{}) do
    {:ok, pid} = SnapshotOrchestrator.start_link(Map.merge(%{running: [], retrying: [], rate_limits: nil, repositories: [], dispatch_skipped: [], watching: []}, snapshot))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  test "reading a ticket gives its title, its record's phase, its priority and its labels, as the ticket list's columns do" do
    record = %{
      repo_key: "default",
      issue_id: "qa-105",
      issue_identifier: "QA-105",
      phase: "Rework",
      title: "Undo a Director move within ten seconds",
      priority: 1,
      labels: ["qa:live", "director"]
    }

    :ok = RunStore.put_ticket_state(record)

    assert {:ok, payload} = Presenter.issue_payload("QA-105", orchestrator(), 1_000)

    assert payload.ticket == %{title: "Undo a Director move within ten seconds", phase: "Rework", priority: 1, labels: ["qa:live", "director"]}
    assert payload.phase_path.current == nil

    columns = record |> TicketState.normalize() |> TicketColumns.values()
    assert payload.ticket == %{title: columns["title"], phase: columns["phase"], priority: columns["priority"], labels: columns["labels"]}
  end

  test "a running ticket Symphony holds no record of yet reads an empty ticket" do
    entry = %{
      issue_id: "fresh",
      identifier: "MT-2",
      repo_key: "default",
      state: "In Progress",
      run_kind: "implementation",
      session_id: "s",
      started_at: @started,
      last_codex_event: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil
    }

    assert {:ok, payload} = Presenter.issue_payload("MT-2", orchestrator(%{running: [entry]}), 1_000)
    assert payload.ticket == %{title: nil, phase: nil, priority: nil, labels: []}
  end
end
