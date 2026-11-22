defmodule SymphonyElixirWeb.DispatchOrderReadTest do
  # The dispatch order read through the API: three tickets wait, and the read names the one that
  # starts next and why the other two wait.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  @endpoint SymphonyElixirWeb.Endpoint
  @repo "default"

  # Answers with the snapshot a test gives it.
  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, :unavailable}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
    def handle_call({:put, snapshot}, _from, _snapshot), do: {:reply, :ok, snapshot}
  end

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Done", "Canceled"],
      max_concurrent_agents: 1
    )

    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: SnapshotOrchestrator, start: {SnapshotOrchestrator, :start_link, [orchestrator]}})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    %{orchestrator: orchestrator}
  end

  test "with three tickets waiting, the read names the one that starts next and why the other two wait", %{orchestrator: orchestrator} do
    first = ticket("a", "MT-A", 2)
    second = ticket("b", "MT-B", 3)
    blocked = ticket("c", "MT-C", 3, [%{id: "id-MT-9", identifier: "MT-9", state: "In Progress"}])
    issues = [blocked, second, first]
    Orchestrator.sweep_dependencies_for_test(@repo, issues, Config.settings!().tracker.terminal_states)

    state = Orchestrator.put_dispatch_order_for_test(orchestrator_state(), issues)
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    :ok = GenServer.call(orchestrator, {:put, snapshot})

    read = build_conn() |> get("/api/v1/dispatch/order") |> json_response(200)

    assert %{"next" => "MT-A", "generated_at" => _at, "computed_at" => computed_at, "slots" => %{"work_free" => 1, "concurrency" => %{"max_total" => 1}}} = read
    assert is_binary(computed_at)

    assert [
             %{"identifier" => "MT-A", "position" => 1, "starts_now" => true, "reason" => "next: a slot is free", "slot" => "shared"},
             %{"identifier" => "MT-B", "position" => 2, "starts_now" => false, "reason" => "2nd: behind MT-A", "wait" => "work slots full"}
           ] = read["queue"]

    tickets = Enum.flat_map(read["groups"], & &1["tickets"])
    assert tickets |> Enum.map(& &1["identifier"]) |> Enum.sort() == ["MT-A", "MT-B", "MT-C"]
    assert %{"outcome" => "held", "reason" => "Waiting for MT-9 to finish", "position" => nil} = Enum.find(tickets, &(&1["identifier"] == "MT-C"))
    assert Enum.find(read["groups"], &(&1["kind"] == "blocked_by_ticket"))["tickets"] |> Enum.map(& &1["identifier"]) == ["MT-C"]
    assert Enum.all?(tickets, &is_binary(&1["situation"]["kind"]))

    # The state carries the same read as `order`.
    assert %{"order" => %{"next" => "MT-A", "queue" => [_first, _second]}} = build_conn() |> get("/api/v1/state") |> json_response(200)
  end

  test "the queue lists the tickets in line in the stored order, not by priority or age", %{orchestrator: orchestrator} do
    # MT-Z joined the queue first; MT-Y, urgent and older, joined after it.
    joined_first = ticket("z", "MT-Z", 4)
    urgent_older = %{ticket("y", "MT-Y", 1) | created_at: ~U[2025-01-01 00:00:00Z]}

    state = Orchestrator.put_dispatch_order_for_test(orchestrator_state(), [urgent_older, joined_first])
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    :ok = GenServer.call(orchestrator, {:put, snapshot})

    read = build_conn() |> get("/api/v1/dispatch/order") |> json_response(200)

    assert %{"next" => "MT-Z"} = read
    assert [%{"identifier" => "MT-Z", "position" => 1, "starts_now" => true}, %{"identifier" => "MT-Y", "position" => 2, "starts_now" => false}] = read["queue"]
  end

  test "TP-1615: the dispatch order and Home name the ticket that holds the slot and the free ones, and mark it alone in progress", %{orchestrator: orchestrator} do
    # MT-H holds the one slot with no run (it waits for CI, say); MT-A waits behind it.
    held = %{ticket("h", "MT-H", 3) | state: "In Progress"}
    :ok = RunStore.update_ticket_state("h", %{phase: "In Progress"})
    waiting = ticket("a", "MT-A", 2)
    holder = %{identifier: "MT-H", state: "In Progress", repo_key: @repo, since: ~U[2026-11-22 07:00:00Z]}

    state = Orchestrator.put_dispatch_order_for_test(%{orchestrator_state() | slot_holders: %{"h" => holder}}, [held, waiting])
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    :ok = GenServer.call(orchestrator, {:put, snapshot})

    order = build_conn() |> get("/api/v1/dispatch/order") |> json_response(200)

    assert %{"total" => 1, "used" => 1, "free" => 0, "holders" => [%{"identifier" => "MT-H", "state" => "In Progress", "running" => false}]} = order["slots"]
    assert [%{"identifier" => "MT-H", "in_progress" => true, "starts_now" => true}, %{"identifier" => "MT-A", "in_progress" => false, "wait" => "work slots full"}] = order["queue"]

    home = build_conn() |> get("/api/v1/home") |> json_response(200)

    assert %{"free" => 0, "holders" => [%{"identifier" => "MT-H"}]} = home["slots"]
    assert [%{"identifier" => "MT-H", "in_progress" => true}] = home["in_progress"]
    assert [%{"identifier" => "MT-A", "in_progress" => false}] = home["queue"]["roots"]
  end

  test "an unreadable orchestrator reads as an error", %{orchestrator: _orchestrator} do
    assert %{"error" => %{"code" => "snapshot_unavailable"}} = build_conn() |> get("/api/v1/dispatch/order") |> json_response(200)
  end

  defp ticket(id, identifier, priority, blockers \\ []) do
    :ok =
      RunStore.put_ticket_state(%{
        repo_key: @repo,
        issue_id: id,
        issue_identifier: identifier,
        title: "Ticket #{identifier}",
        phase: "Todo",
        linear_updated_at: DateTime.utc_now()
      })

    %Issue{
      id: id,
      identifier: identifier,
      title: "Ticket #{identifier}",
      state: "Todo",
      priority: priority,
      repo_key: @repo,
      blocked_by: blockers,
      url: "https://example.org/issues/#{identifier}"
    }
  end

  defp orchestrator_state do
    %Orchestrator.State{
      repo_key: @repo,
      max_concurrent_agents: 1,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
