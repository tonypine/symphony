defmodule SymphonyElixirWeb.ViewsReadTest do
  # Saved views through the API: one client saves a view with the control token, another lists it
  # and reads the tickets it selects.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, post: 2, post: 3, delete: 2, json_response: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{ControlToken, TicketColumns}

  @endpoint SymphonyElixirWeb.Endpoint
  @repo "symphony"
  @epic %{identifier: "TP-1400", title: "Epic 6"}

  # Answers with the snapshot a test gives it; unreadable until then.
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
    write_workflow_file!(Workflow.workflow_file_path(), tracker_terminal_states: ["Done", "Canceled"])

    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: SnapshotOrchestrator, start: {SnapshotOrchestrator, :start_link, [orchestrator]}})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    ticket("t-1401", "TP-1401", "Done", 1)
    ticket("t-1402", "TP-1402", "Plan Review", 2)
    ticket("t-1403", "TP-1403", "Todo", 3)
    ticket("t-1404", "TP-1404", "Backlog", 1)
    ticket("t-1405", "TP-1405", "Todo", 1)
    ticket("t-900", "TP-900", "Todo", 1, %{identifier: "TP-899"})

    snapshot = %{running: [], retrying: [], slot_waiting: [%{issue_id: "t-1405", since: ~U[2026-11-10 03:00:00Z], reason: "No slot is free"}]}
    :ok = GenServer.call(orchestrator, {:put, snapshot})
    %{orchestrator: orchestrator}
  end

  defp ticket(id, identifier, phase, priority, parent \\ @epic) do
    :ok =
      RunStore.put_ticket_state(%{
        repo_key: @repo,
        issue_id: id,
        issue_identifier: identifier,
        title: "Ticket #{identifier}",
        phase: phase,
        priority: priority,
        parent: parent
      })
  end

  # The bearer plug caches the daemon's token for the BEAM's lifetime.
  defp control_token do
    case :persistent_term.get(SymphonyElixirWeb.Plugs.BearerToken, :unresolved) do
      :unresolved -> ControlToken.current()
      token -> token
    end
  end

  defp control(conn), do: conn |> put_req_header("authorization", "Bearer " <> control_token()) |> put_req_header("content-type", "application/json")

  defp save(body), do: build_conn() |> control() |> post("/api/v1/control/view", Jason.encode!(body))

  defp tickets(query), do: build_conn() |> get("/api/v1/tickets?" <> URI.encode_query(query))

  @waiting ~w(waiting_on_you waiting_for_ci waiting_for_build waiting_for_slot)

  test "a view saved through the control API is listed by another client and selects the epic's waiting tickets in its sort" do
    body = %{
      name: "Epic 6, waiting",
      filters: [%{column: "epic", value: "TP-1400"}, %{column: "situation", value: @waiting}],
      columns: ["identifier", "situation", "priority"],
      sort: %{column: "priority", direction: "desc"}
    }

    assert %{"view" => %{"id" => id, "name" => "Epic 6, waiting"} = view} = body |> save() |> json_response(200)

    listed = build_conn() |> get("/api/v1/views") |> json_response(200)
    assert [^view] = listed["views"]
    assert listed["filters"] == TicketColumns.filter_names()
    assert Enum.map(listed["columns"], & &1["name"]) == TicketColumns.names()

    read = tickets(%{view: id}) |> json_response(200)
    assert read["view"] == view
    assert read["count"] == 3
    assert Enum.map(read["columns"], & &1["name"]) == ["identifier", "situation", "priority"]
    refute Map.has_key?(read, "error")

    assert read["tickets"] == [
             %{"issue_id" => "t-1403", "identifier" => "TP-1403", "situation" => "waiting_for_slot", "priority" => 3},
             %{"issue_id" => "t-1402", "identifier" => "TP-1402", "situation" => "waiting_on_you", "priority" => 2},
             %{"issue_id" => "t-1405", "identifier" => "TP-1405", "situation" => "waiting_for_slot", "priority" => 1}
           ]

    # The same selection inline.
    inline = tickets(%{epic: "TP-1400", situation: Enum.join(@waiting, ","), columns: "identifier,situation,priority", sort: "priority", direction: "desc"}) |> json_response(200)
    assert inline["tickets"] == read["tickets"]
    assert inline["view"] == nil

    # Updated by id, then deleted.
    renamed = save(Map.merge(body, %{id: id, name: "Epic 6"})) |> json_response(200)
    assert %{"view" => %{"id" => ^id, "name" => "Epic 6", "created_at" => created_at}} = renamed
    assert created_at == view["created_at"]

    assert %{"deleted" => ^id} = build_conn() |> control() |> delete("/api/v1/control/view/#{id}") |> json_response(200)
    assert %{"views" => []} = build_conn() |> get("/api/v1/views") |> json_response(200)
    assert %{"error" => %{"code" => "view_not_found"}} = build_conn() |> control() |> delete("/api/v1/control/view/#{id}") |> json_response(404)
    assert %{"error" => %{"code" => "view_not_found"}} = tickets(%{view: id}) |> json_response(404)
  end

  test "an unknown column is refused with the catalog's names, and an unknown id is not found" do
    assert %{"error" => %{"code" => "invalid_view", "message" => message}} = save(%{name: "Bad", columns: ["colour"]}) |> json_response(400)
    assert message == "Unknown column(s): colour. The columns are: #{Enum.join(TicketColumns.names(), ", ")}"

    assert %{"error" => %{"code" => "view_not_found", "message" => "No view has the id view-nope"}} =
             save(%{id: "view-nope", name: "Gone"}) |> json_response(404)

    assert %{"error" => %{"code" => "invalid_query", "message" => "Unknown column(s): colour." <> _}} = tickets(%{columns: "colour"}) |> json_response(400)

    assert %{"error" => %{"code" => "invalid_query", "message" => "view and inline filters, columns or sort don't mix"}} =
             tickets(%{view: "view-x", epic: "TP-1400"}) |> json_response(400)
  end

  test "the writes need the control token; other methods on the reads are refused" do
    assert build_conn() |> put_req_header("content-type", "application/json") |> post("/api/v1/control/view", Jason.encode!(%{name: "x"})) |> Map.get(:status) == 401
    assert post(build_conn(), "/api/v1/views").status == 405
    assert post(build_conn(), "/api/v1/tickets").status == 405
  end

  test "an unreadable orchestrator gives the records' situations and an error", %{orchestrator: orchestrator} do
    :ok = GenServer.call(orchestrator, {:put, :unavailable})

    read = tickets(%{epic: "TP-1400", columns: "identifier,situation"}) |> json_response(200)
    assert %{"code" => "snapshot_unavailable"} = read["error"]
    assert %{"issue_id" => "t-1405", "identifier" => "TP-1405", "situation" => "waiting_for_slot"} in read["tickets"]
    assert read["view"] == nil
  end
end
