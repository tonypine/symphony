defmodule SymphonyElixirWeb.ControlApiControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.AuditLog
  alias SymphonyElixirWeb.ControlApiController

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

    test "records run_stopped when a run stopped", %{tmp_dir: tmp_dir} do
      reply = {:ok, %{stopped: true, issue_id: "issue-7", issue_identifier: "ACME-7", repo_key: "web", session_id: "s-7"}}

      conn = stop_with_audit(reply, tmp_dir)

      assert conn.status == 200
      {:ok, stream} = AuditLog.query(dir: tmp_dir, event_type: "run_stopped")

      assert [%{"issue_id" => "issue-7", "issue_identifier" => "ACME-7", "repo_key" => "web", "session_id" => "s-7"}] =
               Enum.to_list(stream)
    end

    test "records nothing when no run was stopped", %{tmp_dir: tmp_dir} do
      conn = stop_with_audit({:ok, %{stopped: false, issue_id: "ACME-7"}}, tmp_dir)

      assert conn.status == 200
      {:ok, stream} = AuditLog.query(dir: tmp_dir)
      assert Enum.to_list(stream) == []
    end

    test "still answers when the record can't be written", %{tmp_dir: tmp_dir} do
      blocker = Path.join(tmp_dir, "blocker")
      File.write!(blocker, "")
      reply = {:ok, %{stopped: true, issue_id: "issue-7", issue_identifier: "ACME-7", session_id: "s-7"}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = stop_with_audit(reply, Path.join(blocker, "audit"))
          assert conn.status == 200
        end)

      assert log =~ "Failed to record run_stopped audit event: issue_identifier=ACME-7"
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
