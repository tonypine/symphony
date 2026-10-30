defmodule SymphonyElixirWeb.ReconcileStateTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias SymphonyElixir.{TicketObservation, TicketState}

  @endpoint SymphonyElixirWeb.Endpoint
  @phase_at ~U[2026-10-29 09:01:00Z]
  @moved_at ~U[2026-10-29 09:02:00Z]
  @now ~U[2026-10-29 09:05:00Z]

  # Answers `GET /api/v1/state` with an idle snapshot.
  defmodule IdleOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, %{running: [], retrying: [], rate_limits: nil}, state}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: IdleOrchestrator, start: {IdleOrchestrator, :start_link, [orchestrator]}})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    TicketObservation.reset()
    on_exit(&TicketObservation.reset/0)
    :ok
  end

  # The reconcile's follow-up runs under `supervisor`; waits for it to finish.
  defp await_follow_up(supervisor) do
    for pid <- Task.Supervisor.children(supervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    :ok
  end

  defp reconcile_state, do: build_conn() |> get("/api/v1/state") |> json_response(200) |> Map.fetch!("reconcile")

  @idle %{
    "last_run_at" => nil,
    "interval_ms" => 300_000,
    "applied" => 0,
    "reapplied" => 0,
    "unobserved_filled" => 0,
    "detected" => 0,
    "reverted" => 0,
    "revert_failed" => 0,
    "recent" => []
  }

  test "before any drift or reconcile: no counts, nothing recent, and the interval" do
    assert reconcile_state() == @idle
  end

  test "a reconcile run shows when it ran, the interval, and what it applied, re-applied and filled" do
    repo_key = Config.repo_key!()
    write_workflow_file!(Workflow.workflow_file_path())
    File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "linear:\n  reconcile_interval_ms: 120000\n")
    Cache.clear()

    moved = repo_key |> TicketState.new("issue-2") |> TicketState.put_phase("Code Review", @phase_at) |> TicketState.mark_projection(:phase, :boom, @phase_at)
    :ok = RunStore.put_ticket_state(moved)
    :ok = RunStore.put_ticket_state(TicketState.new(repo_key, "issue-3", %{issue_identifier: "ACME-3"}))
    filled = %Issue{id: "issue-3", identifier: "ACME-3", title: "Never observed", state: "Done", updated_at: @moved_at}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [filled])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    supervisor = start_supervised!(Task.Supervisor)
    issue = %Issue{id: "issue-1", identifier: "ACME-1", title: "New in Linear", state: "Todo", updated_at: ~U[2026-10-29 09:00:00Z]}
    assert %{updated: 1} = TicketObservation.reconcile_all(repo_key, [issue], now: @now, task_supervisor: supervisor)
    :ok = await_follow_up(supervisor)
    assert_received {:memory_tracker_state_update, "issue-2", "Code Review"}

    assert reconcile_state() == %{@idle | "last_run_at" => "2026-10-29T09:05:00Z", "interval_ms" => 120_000, "applied" => 1, "reapplied" => 1, "unobserved_filled" => 1}
  end

  test "a hand move moved back counts as detected and reverted, with the ticket and both states" do
    repo_key = Config.repo_key!()
    issue = %Issue{id: "issue-1", identifier: "ACME-1", title: "Owned", state: "In Progress", updated_at: ~U[2026-10-29 09:00:00Z]}
    {:ok, :updated} = TicketObservation.observe(repo_key, issue, now: @now)
    owned = repo_key |> RunStore.get_ticket_state("issue-1") |> TicketState.put_phase("Code Review", @phase_at)
    :ok = RunStore.put_ticket_state(owned)

    :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_events()
    hand_move = %{issue | state: "Done", updated_at: @moved_at}
    {:ok, :updated} = TicketObservation.observe(repo_key, hand_move, now: @now, dispatch_source: "record")
    # The move back runs in a task of its own and counts itself before it records its outcome.
    assert_receive {:ticket_event, %{issue_id: "issue-1", type: "drift.reverted"}}, 2_000

    assert reconcile_state() == %{
             @idle
             | "detected" => 1,
               "reverted" => 1,
               "recent" => [
                 %{
                   "identifier" => "ACME-1",
                   "record_phase" => "Code Review",
                   "linear_phase" => "Done",
                   "outcome" => "reverted",
                   "at" => "2026-10-29T09:05:00Z"
                 }
               ]
           }
  end
end
