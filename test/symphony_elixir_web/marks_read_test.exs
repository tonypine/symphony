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

  defp write(text, audit_dir) do
    params = %{"repo_key" => @repo, "issue_identifier" => @identifier, "text" => text}

    conn(:post, "/", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> Phoenix.Controller.put_view(SymphonyElixirWeb.ErrorJSON)
    |> assign(:audit_log, dir: audit_dir)
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> ControlApiController.note(params)
  end

  @tag :tmp_dir
  test "the Director writes twice while a run works; the next run is given both first, and the history says which run read them",
       %{tmp_dir: tmp_dir} do
    record!("phase.entered", %{to: "In Progress", from: "Todo"}, at: at(1))
    issue = %Issue{id: @id, identifier: @identifier, title: "Marks", state: "In Progress"}

    # A run is working: its prompt was built when it started.
    record!("run.started", %{run_id: "run-1", run_kind: "implementation", run_number: 1}, run_id: "run-1", at: at(2))
    refute PromptBuilder.build_prompt(issue, ticket_state: RunStore.get_ticket_state(@id), run_id: "run-1") =~ "Messages from the person"

    # Never looked: everything is new.
    assert %{looked_at: nil, new_since_looked: 2, unread_messages: 0, note: nil} = read()

    # The Director opens the ticket and writes to it twice while the run works.
    assert look(%{"issue_identifier" => @identifier}).status == 200
    assert %{"event" => %{"id" => first_id}} = "Keep the export button." |> write(tmp_dir) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert %{"event" => %{"id" => second_id}} = "And use the new copy." |> write(tmp_dir) |> Map.fetch!(:resp_body) |> Jason.decode!()

    # Both are in the history as written by the person, each unread; the older app's note is the newest.
    assert %{unread_messages: 2, note: %{id: ^second_id, text: "And use the new copy.", by: "the Director", read_by: nil}} = read()
    messages = Enum.filter(feed(), &(&1["type"] == "message.sent"))

    assert Enum.map(messages, &{&1["id"], &1["summary"]["title"], &1["summary"]["detail"], &1["read"], &1["new"]}) == [
             {first_id, "You wrote", "Keep the export button.", nil, true},
             {second_id, "You wrote", "And use the new copy.", nil, true}
           ]

    # The run ends and the next starts: its prompt opens with both, oldest first.
    record!("run.ended", %{run_id: "run-1", exit: "handoff"}, run_id: "run-1")
    record!("run.started", %{run_id: "run-2", run_kind: "implementation", run_number: 2}, run_id: "run-2")
    prompt = PromptBuilder.build_prompt(issue, ticket_state: RunStore.get_ticket_state(@id), run_id: "run-2")
    assert prompt =~ ~r/\A## Messages from the person\n.*Keep the export button\..*And use the new copy\./s

    # Both are marked read by that run.
    assert %{unread_messages: 0, note: nil} = read()

    for message <- Enum.filter(feed(), &(&1["type"] == "message.sent")) do
      assert %{"run_id" => "run-2", "run" => "Implementation run 2", "at" => at} = message["read"]
      assert {:ok, _at, 0} = DateTime.from_iso8601(at)
    end

    [_phase, _run_1, _first, _second, run_2] = timeline()
    assert run_2["events"] |> Enum.map(& &1["type"]) |> Enum.sort() == ["message.read", "message.read", "run.started"]
    assert run_2["events"] |> Enum.filter(&(&1["type"] == "message.read")) |> Enum.map(& &1["payload"]["message_id"]) == [first_id, second_id]

    # Looking again moves the mark past them.
    assert look(%{"issue_identifier" => @identifier, "repo_key" => @repo}).status == 200
    assert %{new_since_looked: 0} = read()
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
