defmodule SymphonyElixirWeb.PauseBackfillStateTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias SymphonyElixir.Pauses.Backfill
  alias SymphonyElixir.{TicketEvents, TicketState}

  @endpoint SymphonyElixirWeb.Endpoint
  @set_at ~U[2026-10-28 09:00:00.000000Z]
  @now ~U[2026-10-30 07:00:00.000000Z]
  @later ~U[2026-10-30 08:00:00.000000Z]

  # Answers `GET /api/v1/state` and `GET /api/v1/:identifier` with an idle snapshot.
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

    Backfill.reset()
    on_exit(fn -> Backfill.reset() end)
    :ok = RunStore.put_marker(TicketEvents.Backfill.marker(), @set_at)
    :ok
  end

  defp state, do: build_conn() |> get("/api/v1/state") |> json_response(200) |> Map.fetch!("pause_backfill")

  # A startup: the ledger's backfill (already done), then this one.
  defp restart(now), do: capture_log(fn -> Backfill.run_after_ledger(ledger: fn _opts -> {:ok, %{tickets: 0, events: 0}} end, now: now) end)

  # A record as one stored before the holds were retired: its holds as they were written, which the
  # record's normalization no longer reads.
  defp put_record(issue_id, identifier, attrs) do
    repo_key = Config.repo_key!()
    {holds, attrs} = Map.pop(attrs, :holds)
    record = repo_key |> TicketState.new(issue_id, Map.put(attrs, :issue_identifier, identifier)) |> Map.put(:holds, holds)
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({:symphony_run_store_ticket_states, {repo_key, issue_id}, repo_key, issue_id, record}) end)
  end

  test "before the backfill ran the state has no summary" do
    assert state() == nil
  end

  test "a restart reports the records read and the pauses and questions created; a second restart creates none" do
    blocked = %{kind: :blocked, reason: "waiting on TP-11", waits_on: %{type: "dependency", keys: ["TP-11"]}, set_at: @set_at}
    put_record("issue-1", "TP-1", %{holds: [blocked]})
    put_record("issue-2", "TP-2", %{decisions: [%{key: "c-1", date: ~D[2026-10-20], title: "Ship it", question: "Should it ship?", answer: "Yes"}]})
    put_record("issue-3", "TP-3", %{holds: [%{blocked | waits_on: %{type: "mystery", keys: []}}]})

    restart(@now)

    assert %{
             "at" => "2026-10-30T07:00:00Z",
             "records_read" => 3,
             "records_converted" => 3,
             "already_converted" => 0,
             "pauses_created" => 1,
             "questions_created" => 1,
             "skipped_count" => 1,
             "skipped" => [%{"issue_id" => "issue-3", "issue_identifier" => "TP-3", "reason" => "a Blocked hold waiting on mystery, which no pause reason covers"}]
           } = state()

    restart(@later)

    assert %{"at" => "2026-10-30T08:00:00Z", "records_read" => 3, "already_converted" => 3, "pauses_created" => 0, "questions_created" => 0} = state()
  end

  test "a backfill that could not run reports why" do
    :ok = RunStore.clear()
    restart(@now)

    assert state() == %{"at" => "2026-10-30T07:00:00Z", "error" => ":ledger_backfill_pending"}
  end

  test "a ticket that had a Blocked hold reads its pause, whose reason says what the hold said" do
    blocked = %{kind: :blocked, reason: "waiting on TP-11", waits_on: %{type: "dependency", keys: ["TP-11"]}, set_at: @set_at}
    put_record("issue-1", "TP-1", %{holds: [blocked]})
    assert %{"pause" => nil} = build_conn() |> get("/api/v1/TP-1") |> json_response(200)

    restart(@now)

    assert %{"pause" => pause} = build_conn() |> get("/api/v1/TP-1") |> json_response(200)

    assert pause == %{
             "since" => "2026-10-28T09:00:00Z",
             "set_by" => %{"kind" => "symphony", "name" => "Symphony"},
             "reasons" => [
               %{
                 "kind" => "ticket",
                 "text" => "Waiting for TP-11 to finish",
                 "waits_on" => %{"identifier" => "TP-11"},
                 "set_by" => %{"kind" => "symphony", "name" => "Symphony"},
                 "set_at" => "2026-10-28T09:00:00Z",
                 "releasable" => false
               }
             ],
             "releasable" => false
           }
  end
end
