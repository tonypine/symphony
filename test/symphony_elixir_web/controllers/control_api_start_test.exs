defmodule SymphonyElixirWeb.ControlApiStartTest do
  # `POST /control/start` (TP-1329). Sync and on TestSupport: `start_issue` reads the ticket in
  # the caller from the memory tracker, through the workflow's tracker settings and the
  # `:memory_tracker_issues` app env, which are global and which other tests rewrite.
  use SymphonyElixir.TestSupport

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.ControlApiController

  defmodule StubOrchestrator do
    use GenServer

    @impl true
    def init(replies), do: {:ok, replies}

    @impl true
    def handle_call(_msg, _from, [reply | rest]), do: {:reply, reply, rest}
    def handle_call(_msg, _from, []), do: {:reply, {:error, :no_canned_reply}, []}
  end

  setup do
    issues =
      for {id, state} <- [{"start-1", "In Progress"}, {"backlog-1", "Backlog"}] do
        %Issue{id: id, identifier: String.upcase(id), title: id, state: state, url: "https://example.org"}
      end

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)
    :ok
  end

  test "answers 200 with the run it started, forwarding the note" do
    conn = post_start(%{"issue_identifier" => "START-1", "note" => "unblock this one"}, [{:ok, %{started: true, run_id: "run-1", session_id: nil}}])

    assert conn.status == 200
    assert json_body(conn) == %{"started" => true, "run_id" => "run-1", "session_id" => nil}
  end

  test "maps each refusal and failure to its answer" do
    conn = post_start(%{"issue_identifier" => "BACKLOG-1"}, [])
    assert conn.status == 409
    assert json_body(conn)["error"] == %{"code" => "start_not_allowed", "message" => "the ticket is in Backlog; move it first"}

    assert post_start(%{"issue_identifier" => "START-1"}, [{:error, {:start_failed, "the agent did not start"}}]).status == 502
    assert post_start(%{"issue_identifier" => "TP-404"}, []).status == 404
    assert post_start(%{"issue_identifier" => "START-1"}, [:unavailable]).status == 503
  end

  test "requires issue_identifier and bounds the note" do
    conn = post_start(%{"note" => "no ticket"})
    assert conn.status == 422
    assert json_body(conn)["error"]["code"] == "invalid_request"
    assert json_body(conn)["error"]["message"] =~ "issue_identifier"

    conn = post_start(%{"issue_identifier" => "START-1", "note" => String.duplicate("a", 501)})
    assert conn.status == 422
    assert json_body(conn)["error"]["message"] =~ "note holds at most 500 characters"

    assert post_start(%{"issue_identifier" => "START-1"}, [{:ok, %{started: true}}]).status == 200
  end

  defp post_start(params, replies \\ []) do
    {:ok, orchestrator} = GenServer.start_link(StubOrchestrator, replies)
    body = if params == %{}, do: "", else: Jason.encode!(params)

    conn(:post, "/api/v1/control/start", body)
    |> put_req_header("content-type", "application/json")
    |> Phoenix.Controller.put_view(SymphonyElixirWeb.ErrorJSON)
    |> assign(:orchestrator, orchestrator)
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> ControlApiController.start(params)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)
end
