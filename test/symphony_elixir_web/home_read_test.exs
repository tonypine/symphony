defmodule SymphonyElixirWeb.HomeReadTest do
  # The Home read through the API: the orchestrator walks two queued tickets, one blocked by the
  # other, behind a ticket in progress; the read is the tree, carries an ETag and answers 304 while
  # nothing changed.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, post: 2, json_response: 2, response: 2]
  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]

  alias SymphonyElixirWeb.Presenter

  @endpoint SymphonyElixirWeb.Endpoint
  @repo "default"

  # Answers with the snapshot a test gives it, after `delay_ms` when it has one.
  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, {:unavailable, 0}}

    @impl true
    def handle_call(:snapshot, _from, {snapshot, delay_ms} = state) do
      Process.sleep(delay_ms)
      {:reply, snapshot, state}
    end

    def handle_call({:put, snapshot, delay_ms}, _from, _state), do: {:reply, :ok, {snapshot, delay_ms}}
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

  test "the read is the queue's tree behind the ticket in progress, and an unchanged read answers 304", %{orchestrator: orchestrator} do
    working = ticket("w", "MT-W", "In Progress")
    first = ticket("a", "MT-A", "Todo", [%{id: "w", identifier: "MT-W", state: "In Progress"}])
    second = ticket("b", "MT-B", "Todo", [%{id: "a", identifier: "MT-A", state: "Todo"}])
    _backlog = ticket("k", "MT-K", "Backlog")
    issues = [working, first, second]

    state = Orchestrator.put_dispatch_order_for_test(orchestrator_state(), issues)
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    :ok = GenServer.call(orchestrator, {:put, snapshot, 0})

    conn = get(build_conn(), "/api/v1/home")
    read = json_response(conn, 200)
    [etag] = get_resp_header(conn, "etag")

    assert [%{"kind" => "ticket", "identifier" => "MT-W", "working" => false, "situation" => %{"kind" => _kind}}] = read["in_progress"]

    assert %{"roots" => [%{"identifier" => "MT-A", "after" => "MT-W", "children" => [%{"identifier" => "MT-B", "also_waits_on" => [], "children" => []}]}]} =
             read["queue"]

    assert read["outside"] == %{"backlog" => 1, "below_priority" => 0, "epic" => 0, "behind" => 0}
    refute Map.has_key?(read, "error")

    again = build_conn() |> put_req_header("if-none-match", etag) |> get("/api/v1/home")
    assert response(again, 304) == ""
    assert get_resp_header(again, "etag") == [etag]

    assert %{"error" => %{"code" => "method_not_allowed"}} = build_conn() |> post("/api/v1/home") |> json_response(405)
  end

  test "an unreadable or slow orchestrator reads the records alone, with an error", %{orchestrator: orchestrator} do
    ticket("w", "MT-W", "In Progress")

    assert %{"error" => %{"code" => "snapshot_unavailable"}, "in_progress" => [%{"identifier" => "MT-W"}], "queue" => %{"roots" => []}} =
             build_conn() |> get("/api/v1/home") |> json_response(200)

    :ok = GenServer.call(orchestrator, {:put, %{running: []}, 200})
    assert %{error: %{code: "snapshot_timeout"}, in_progress: [%{identifier: "MT-W"}]} = Presenter.home_payload(orchestrator, 10)
  end

  defp ticket(id, identifier, state, blockers \\ []) do
    :ok =
      RunStore.put_ticket_state(%{
        repo_key: @repo,
        issue_id: id,
        issue_identifier: identifier,
        title: "Ticket #{identifier}",
        phase: state,
        priority: 2,
        blockers: blockers,
        linear_updated_at: DateTime.utc_now()
      })

    %Issue{
      id: id,
      identifier: identifier,
      title: "Ticket #{identifier}",
      state: state,
      priority: 2,
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
