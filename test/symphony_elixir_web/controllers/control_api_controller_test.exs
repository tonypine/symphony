defmodule SymphonyElixirWeb.ControlApiControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{AuditLog, RunStore}
  alias SymphonyElixir.TicketEvents.Brief
  alias SymphonyElixirWeb.{ControlApiController, Router}

  defmodule StubOrchestrator do
    use GenServer

    def start_link(replies), do: GenServer.start_link(__MODULE__, replies)

    @impl true
    def init(replies), do: {:ok, replies}

    @impl true
    def handle_call(msg, _from, %{calls: calls, replies: [reply | rest]} = state) do
      {:reply, reply, %{state | calls: calls ++ [msg], replies: rest}}
    end

    def handle_call(msg, _from, %{calls: calls, replies: []} = state) do
      {:reply, {:error, :no_canned_reply}, %{state | calls: calls ++ [msg]}}
    end
  end

  defp start_stub(replies) do
    {:ok, pid} = GenServer.start_link(StubOrchestrator, %{calls: [], replies: replies})
    pid
  end

  defp calls(pid), do: :sys.get_state(pid).calls

  defp build_conn(method, path, params \\ %{}) do
    body = if params == %{}, do: "", else: Jason.encode!(params)

    conn(method, path, body)
    |> put_req_header("content-type", "application/json")
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
  end

  defp send_to(conn, action, orchestrator_pid, params) do
    conn
    |> Phoenix.Controller.put_view(SymphonyElixirWeb.ErrorJSON)
    |> Plug.Conn.assign(:orchestrator, orchestrator_pid)
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> then(&apply(ControlApiController, action, [&1, params]))
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  test "POST /control/pause returns the orchestrator payload" do
    pid = start_stub([{:ok, %{paused: true, reason: "deploy window"}}])

    conn =
      build_conn(:post, "/api/v1/control/pause", %{"reason" => "deploy window"})
      |> send_to(:pause, pid, %{"reason" => "deploy window"})

    assert conn.status == 200
    assert json_body(conn) == %{"paused" => true, "reason" => "deploy window"}
    assert calls(pid) == [{:pause_dispatch, "deploy window"}]
  end

  test "POST /control/pause returns Symphony's pause with its reasons, as the menu bar app reads it" do
    update = %{kind: :build, waits_on: %{version: "0.0.1.42"}, text: "updating to v0.0.1.42", set_at: ~U[2026-10-30 12:00:00Z]}
    pause = SymphonyElixir.Pauses.normalize(%{subject: :symphony, reasons: [update]})
    pid = start_stub([{:ok, SymphonyElixir.Pauses.dispatch_status(pause)}])

    conn = send_to(build_conn(:post, "/api/v1/control/pause"), :pause, pid, %{"reason" => "updating to v0.0.1.42"})

    assert json_body(conn) == %{
             "paused" => true,
             "reason" => "updating to v0.0.1.42",
             "paused_at" => "2026-10-30T12:00:00Z",
             "reasons" => [%{"kind" => "build", "text" => "updating to v0.0.1.42", "since" => "2026-10-30T12:00:00Z", "waits_on" => %{"version" => "0.0.1.42"}}]
           }

    assert calls(pid) == [{:pause_dispatch, "updating to v0.0.1.42"}]
  end

  test "POST /control/pause accepts a missing reason" do
    pid = start_stub([{:ok, %{paused: true}}])

    conn = send_to(build_conn(:post, "/api/v1/control/pause"), :pause, pid, %{})

    assert conn.status == 200
    assert calls(pid) == [{:pause_dispatch, nil}]
  end

  test "POST /control/resume calls resume_dispatch" do
    pid = start_stub([{:ok, %{paused: false}}])

    conn = send_to(build_conn(:post, "/api/v1/control/resume"), :resume, pid, %{})

    assert conn.status == 200
    assert calls(pid) == [:resume_dispatch]
  end

  test "POST /control/stop requires issue_identifier" do
    pid = start_stub([])

    conn = send_to(build_conn(:post, "/api/v1/control/stop"), :stop, pid, %{})

    assert conn.status == 422
    assert json_body(conn)["error"]["code"] == "invalid_request"
    assert calls(pid) == []
  end

  test "POST /control/stop forwards the issue identifier" do
    pid = start_stub([{:ok, %{stopped: "ACME-123"}}])

    conn =
      send_to(
        build_conn(:post, "/api/v1/control/stop", %{"issue_identifier" => "ACME-123"}),
        :stop,
        pid,
        %{"issue_identifier" => "ACME-123"}
      )

    assert conn.status == 200
    assert calls(pid) == [{:stop_running, "ACME-123"}]
  end

  describe "POST /control/stop audit record" do
    @describetag :tmp_dir

    defp stop_with_audit(reply, audit_dir) do
      pid = start_stub([reply])

      build_conn(:post, "/api/v1/control/stop", %{"issue_identifier" => "ACME-7"})
      |> Plug.Conn.assign(:audit_log, dir: audit_dir)
      |> send_to(:stop, pid, %{"issue_identifier" => "ACME-7"})
    end

    test "records run_stopped when a run stopped, and the Director's stop on the ticket's events", %{tmp_dir: tmp_dir} do
      issue_id = "issue-#{System.unique_integer([:positive])}"
      reply = {:ok, %{stopped: true, issue_id: issue_id, issue_identifier: "ACME-7", repo_key: "web", session_id: "s-7"}}

      conn = stop_with_audit(reply, tmp_dir)

      assert conn.status == 200
      assert json_body(conn) == %{"stopped" => true, "issue_id" => issue_id, "issue_identifier" => "ACME-7", "repo_key" => "web", "session_id" => "s-7"}
      {:ok, stream} = AuditLog.query(dir: tmp_dir, event_type: "run_stopped")

      assert [%{"issue_id" => ^issue_id, "issue_identifier" => "ACME-7", "repo_key" => "web", "session_id" => "s-7"}] =
               Enum.to_list(stream)

      assert [%{type: "person.action", payload: %{action: "stop"}, actor: %{kind: :person, name: "the Director"}} = event] =
               RunStore.list_ticket_events("web", issue_id, [])

      assert event.summary.title == "The Director stopped the run"
    end

    test "records nothing when no run was stopped", %{tmp_dir: tmp_dir} do
      conn = stop_with_audit({:ok, %{stopped: false, issue_id: "ACME-7"}}, tmp_dir)

      assert conn.status == 200
      {:ok, stream} = AuditLog.query(dir: tmp_dir)
      assert Enum.to_list(stream) == []
      assert RunStore.list_ticket_events("web", "ACME-7", []) == []
    end

    test "still answers when the record can't be written", %{tmp_dir: tmp_dir} do
      blocker = Path.join(tmp_dir, "blocker")
      File.write!(blocker, "")
      issue_id = "issue-#{System.unique_integer([:positive])}"
      reply = {:ok, %{stopped: true, issue_id: issue_id, issue_identifier: "ACME-7", session_id: "s-7"}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = stop_with_audit(reply, Path.join(blocker, "audit"))
          assert conn.status == 200
        end)

      assert log =~ "Failed to record run_stopped audit event: issue_identifier=ACME-7"
    end

    test "still answers, with the audit record, when the event can't be written", %{tmp_dir: tmp_dir} do
      reply = {:ok, %{stopped: true, issue_id: "issue-7", issue_identifier: "ACME-7", repo_key: "  ", session_id: "s-7"}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = stop_with_audit(reply, tmp_dir)
          assert conn.status == 200
        end)

      assert log =~ "Failed to record the person.action event on issue_id=issue-7"
      {:ok, stream} = AuditLog.query(dir: tmp_dir, event_type: "run_stopped")
      assert [%{"issue_id" => "issue-7"}] = Enum.to_list(stream)
    end
  end

  describe "POST /control/note" do
    @describetag :tmp_dir

    setup do
      n = System.unique_integer([:positive])
      ticket = %{repo_key: "notes-#{n}", issue_id: "issue-#{n}", issue_identifier: "SHOP-#{n}"}
      :ok = RunStore.put_ticket_state(ticket)
      %{ticket: ticket}
    end

    defp post_note(params, audit_dir) do
      build_conn(:post, "/api/v1/control/note", params)
      |> Plug.Conn.assign(:audit_log, dir: audit_dir)
      |> send_to(:note, start_stub([]), params)
    end

    defp note_params(ticket, text), do: %{"repo_key" => ticket.repo_key, "issue_identifier" => ticket.issue_identifier, "text" => text}

    defp audit_records(dir) do
      {:ok, stream} = AuditLog.query(dir: dir, event_type: "director_note")
      Enum.to_list(stream)
    end

    test "records the Director's note, answers it as the feed shows it, and the ticket summary lists it under Notes",
         %{ticket: ticket, tmp_dir: tmp_dir} do
      conn = post_note(note_params(ticket, "  Keep the export button where it is.\n"), tmp_dir)

      assert conn.status == 200

      assert %{"event" => %{"id" => event_id, "type" => "note", "actor" => %{"kind" => "person", "name" => "the Director"}} = event} =
               json_body(conn)

      assert event["payload"] == %{"text" => "Keep the export button where it is."}
      assert event["summary"]["detail"] == "Keep the export button where it is."

      assert [%{id: ^event_id, type: "note", actor: %{kind: :person, name: "the Director"}}] =
               RunStore.list_ticket_events(ticket.repo_key, ticket.issue_id, [])

      assert [%{"event_id" => ^event_id, "issue_identifier" => identifier, "repo_key" => repo_key, "text" => "Keep the export button where it is."}] =
               audit_records(tmp_dir)

      assert {identifier, repo_key} == {ticket.issue_identifier, ticket.repo_key}

      # The next agent run starts from the summary, which holds the note in full.
      assert {:ok, %{notes: 1, text: text}} = Brief.render(ticket.repo_key, ticket.issue_id)
      assert text =~ ~r/Notes \(1\):\n- \S+, the Director: Keep the export button where it is\.\n/
    end

    test "refuses empty and over-bound text with 400 and writes nothing", %{ticket: ticket, tmp_dir: tmp_dir} do
      for {text, message} <- [
            {"", "A note needs text"},
            {"   \n ", "A note needs text"},
            {nil, "A note needs text"},
            {42, "A note needs text"},
            {String.duplicate("é", 4_001), "A note holds at most 4,000 characters; this one has 4,001"}
          ] do
        conn = post_note(note_params(ticket, text), tmp_dir)

        assert conn.status == 400
        assert json_body(conn)["error"] == %{"code" => "invalid_note", "message" => message}
      end

      assert RunStore.list_ticket_events(ticket.repo_key, ticket.issue_id, []) == []
      assert audit_records(tmp_dir) == []

      # The bound itself is a note.
      assert post_note(note_params(ticket, String.duplicate("é", 4_000)), tmp_dir).status == 200
    end

    test "an unknown ticket is 404, and a request without the ticket is 422; neither writes", %{ticket: ticket, tmp_dir: tmp_dir} do
      conn = post_note(%{note_params(ticket, "Hello") | "issue_identifier" => "SHOP-0"}, tmp_dir)

      assert conn.status == 404
      assert json_body(conn)["error"] == %{"code" => "ticket_not_found", "message" => "No ticket SHOP-0 in #{ticket.repo_key}"}

      for params <- [%{"text" => "Hello"}, Map.delete(note_params(ticket, "Hello"), "repo_key"), %{note_params(ticket, "Hello") | "issue_identifier" => " "}] do
        conn = post_note(params, tmp_dir)
        assert conn.status == 422
        assert json_body(conn)["error"]["code"] == "invalid_request"
      end

      assert RunStore.list_ticket_events(ticket.repo_key, ticket.issue_id, []) == []
      assert audit_records(tmp_dir) == []
    end

    test "is refused without the control token, like the other control routes", %{ticket: ticket} do
      for path <- ["/api/v1/control/note", "/api/v1/control/stop"] do
        conn =
          conn(:post, path, Jason.encode!(note_params(ticket, "Hello")))
          |> put_req_header("content-type", "application/json")
          |> Router.call(Router.init([]))

        assert conn.status == 401
      end

      assert RunStore.list_ticket_events(ticket.repo_key, ticket.issue_id, []) == []
    end

    test "still answers the written note when its audit record can't be written", %{ticket: ticket, tmp_dir: tmp_dir} do
      blocker = Path.join(tmp_dir, "blocker")
      File.write!(blocker, "")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = post_note(note_params(ticket, "Hello"), Path.join(blocker, "audit"))
          assert conn.status == 200
        end)

      assert log =~ "Failed to record director_note audit event: issue_identifier=#{ticket.issue_identifier}"
      assert [%{type: "note"}] = RunStore.list_ticket_events(ticket.repo_key, ticket.issue_id, [])
    end
  end

  test "POST /control/dispatch_pr forwards target and intent" do
    pid = start_stub([{:ok, %{pull_request_url: "https://example/pr/1"}}])

    conn =
      send_to(
        build_conn(:post, "/api/v1/control/dispatch_pr", %{"target" => "https://example/pr/1", "intent" => "fix conflicts"}),
        :dispatch_pr,
        pid,
        %{"target" => "https://example/pr/1", "intent" => "fix conflicts"}
      )

    assert conn.status == 200
    assert calls(pid) == [{:dispatch_pr, "https://example/pr/1", [intent: "fix conflicts"]}]
  end

  test "POST /control/dispatch_pr omits empty intent" do
    pid = start_stub([{:ok, %{pull_request_url: "https://example/pr/2"}}])

    conn =
      send_to(
        build_conn(:post, "/api/v1/control/dispatch_pr"),
        :dispatch_pr,
        pid,
        %{"target" => "https://example/pr/2", "intent" => ""}
      )

    assert conn.status == 200
    assert calls(pid) == [{:dispatch_pr, "https://example/pr/2", []}]
  end

  test "POST /control/dispatch_pr requires target" do
    pid = start_stub([])

    conn = send_to(build_conn(:post, "/api/v1/control/dispatch_pr"), :dispatch_pr, pid, %{})

    assert conn.status == 422
    assert calls(pid) == []
  end

  test "returns 503 when the orchestrator is unavailable" do
    pid = start_stub([])
    GenServer.stop(pid)

    conn =
      send_to(
        build_conn(:post, "/api/v1/control/resume"),
        :resume,
        pid,
        %{}
      )

    assert conn.status == 503
    assert json_body(conn)["error"]["code"] == "orchestrator_unavailable"
  end

  test "maps :invalid_issue_id from orchestrator to 422" do
    pid = start_stub([{:error, :invalid_issue_id}])

    conn =
      send_to(
        build_conn(:post, "/api/v1/control/stop", %{"issue_identifier" => "?"}),
        :stop,
        pid,
        %{"issue_identifier" => "?"}
      )

    assert conn.status == 422
  end

  test "maps unexpected orchestrator errors to 500" do
    pid = start_stub([{:error, :boom}])

    conn = send_to(build_conn(:post, "/api/v1/control/resume"), :resume, pid, %{})

    assert conn.status == 500
    assert json_body(conn)["error"]["code"] == "orchestrator_error"
  end
end
