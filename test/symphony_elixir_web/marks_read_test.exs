defmodule SymphonyElixirWeb.MarksReadTest do
  use SymphonyElixir.TestSupport

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.TicketEvents
  alias SymphonyElixirWeb.{ControlApiController, Presenter, Router, TicketEventsController}

  @repo "default"
  @id "marks-ticket"
  @identifier "MRK-1"
  @base ~U[2026-11-09 16:00:00.000000Z]

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
    {:ok, pid} = SnapshotOrchestrator.start_link(snapshot)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp at(minutes), do: DateTime.add(@base, minutes * 60)

  defp record!(type, payload, opts) do
    {:ok, event} = TicketEvents.record(@repo, @id, type, payload, opts)
    event
  end

  defp read, do: Presenter.issue_payload(@identifier, orchestrator(), 1_000) |> elem(1)

  defp call(controller, action, params) do
    conn(:post, "/", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> Phoenix.Controller.put_view(SymphonyElixirWeb.ErrorJSON)
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> then(&apply(controller, action, [&1, params]))
  end

  defp look(params), do: call(ControlApiController, :looked, params)

  defp look_with(params, marks) do
    conn(:post, "/", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> Phoenix.Controller.put_view(SymphonyElixirWeb.ErrorJSON)
    |> assign(:marks, marks)
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> ControlApiController.looked(params)
  end

  defp timeline do
    params = %{"repo_key" => @repo, "issue_identifier" => @identifier, "group" => "run"}

    conn =
      conn(:get, "/")
      |> assign(:orchestrator, orchestrator())
      |> assign(:snapshot_timeout_ms, 1_000)
      |> Phoenix.Controller.put_view(SymphonyElixirWeb.ErrorJSON)
      |> Map.put(:params, params)
      |> TicketEventsController.index(params)

    Jason.decode!(conn.resp_body)["timeline"]
  end

  defp feed do
    conn = call(TicketEventsController, :index, %{"repo_key" => @repo, "issue_identifier" => @identifier})
    Jason.decode!(conn.resp_body)["events"]
  end

  test "the Director opens a ticket, a run reads their note, and coming back the timeline marks what is new and the note names the run" do
    record!("phase.entered", %{to: "In Progress", from: "Todo"}, at: at(1))
    note = record!("note", %{text: "Keep the export button."}, at: at(2), actor: {:person, "the Director"})

    # Never looked: everything is new, and the note waits for a run.
    assert %{looked_at: nil, new_since_looked: 2, note: %{id: note_id, text: "Keep the export button.", by: "the Director", read_by: nil}} = read()
    assert note_id == note.id
    assert Enum.map(feed(), & &1["new"]) == [true, true]

    # The Director opens the ticket.
    conn = look(%{"issue_identifier" => @identifier})
    assert conn.status == 200
    assert %{"issue_identifier" => @identifier, "looked_at" => looked_at, "new_since_looked" => 0} = Jason.decode!(conn.resp_body)
    {:ok, looked, 0} = DateTime.from_iso8601(looked_at)

    assert %{looked_at: ^looked_at, new_since_looked: 0} = read()
    assert Enum.map(feed(), & &1["new"]) == [false, false]

    # A run starts: its prompt carries the note, and the run's events come after the mark.
    assert DateTime.compare(DateTime.utc_now(), looked) == :gt
    record!("run.started", %{run_id: "run-1", run_kind: "implementation", run_number: 1}, run_id: "run-1")
    record = RunStore.get_ticket_state(@id)
    issue = %Issue{id: @id, identifier: @identifier, title: "Marks", state: "In Progress"}
    assert PromptBuilder.build_prompt(issue, ticket_state: record, run_id: "run-1") =~ "Keep the export button."
    record!("run.ended", %{run_id: "run-1", exit: "handoff"}, run_id: "run-1")

    assert %{looked_at: ^looked_at, new_since_looked: 3, note: %{id: ^note_id, read_by: %{run_id: "run-1"}}} = read()

    [phase, note_event, run] = timeline()
    assert {phase["new"], note_event["new"]} == {false, false}
    assert run["events"] |> Enum.map(&{&1["type"], &1["new"]}) |> Enum.sort() == [{"note.read", true}, {"run.ended", true}, {"run.started", true}]

    # Looking again moves the mark past them.
    assert look(%{"issue_identifier" => @identifier, "repo_key" => @repo}).status == 200
    assert %{new_since_looked: 0} = read()
    assert timeline() |> List.last() |> Map.fetch!("events") |> Enum.map(& &1["new"]) == [false, false, false]
  end

  test "an unknown ticket is 404 and a request without one is 422" do
    conn = look(%{"issue_identifier" => "MRK-0"})
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] == %{"code" => "ticket_not_found", "message" => "No ticket MRK-0 in any repository"}

    conn = look(%{"issue_identifier" => @identifier, "repo_key" => "elsewhere"})
    assert conn.status == 404

    conn = look(%{})
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_request"
  end

  test "a record that goes before the write is 404, and a write the store refuses is 502" do
    vanish = fn issue_id, attrs ->
      :ok = RunStore.delete_ticket_state(issue_id)
      RunStore.update_ticket_state(issue_id, attrs)
    end

    conn = look_with(%{"issue_identifier" => @identifier}, write: fn _issue_id, _attrs -> {:error, :disk_full} end)
    assert conn.status == 502
    assert Jason.decode!(conn.resp_body)["error"] == %{"code" => "store_error", "message" => ":disk_full"}

    conn = look_with(%{"issue_identifier" => @identifier}, write: vanish)
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "ticket_not_found"
  end

  test "the route needs the control token" do
    conn =
      conn(:post, "/api/v1/control/looked", Jason.encode!(%{"issue_identifier" => @identifier}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 401
  end
end
