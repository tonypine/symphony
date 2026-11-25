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

  # Tells the test which call the start made, then answers it as the orchestrator does.
  defmodule RecordingOrchestrator do
    use GenServer

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call(message, _from, test) do
      send(test, {:orchestrator_call, message})

      reply = %{
        started: true,
        issue_id: "start-1",
        issue_identifier: "START-1",
        repo_key: "default",
        run_id: "run-1",
        session_id: nil,
        slot: 1
      }

      {:reply, {:ok, reply}, test}
    end
  end

  setup do
    issues =
      for {id, state} <- [{"start-1", "In Progress"}, {"backlog-1", "Backlog"}] do
        %Issue{id: id, identifier: String.upcase(id), title: id, state: state, url: "https://example.org", repo_key: "default"}
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
    assert json_body(conn)["error"] == %{"code" => "start_not_allowed", "message" => "The ticket is in Backlog; move it to Todo with Move to… first."}

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

  test "TP-1630: the app's request, with only the ticket and a note, starts with no slot named and keeps the answer's fields" do
    conn = post_recorded(%{"issue_identifier" => "START-1", "note" => "go"})

    assert conn.status == 200
    assert_received {:orchestrator_call, {:start_issue, %Issue{id: "start-1"}, "go"}}
    body = json_body(conn)
    assert %{"started" => true, "issue_id" => "start-1", "issue_identifier" => "START-1", "run_id" => "run-1", "session_id" => nil} = body
  end

  test "TP-1630: a named slot, as a number or its digits, goes to the orchestrator; anything else is 422" do
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 2)

    assert post_recorded(%{"issue_identifier" => "START-1", "slot" => 2}).status == 200
    assert_received {:orchestrator_call, {:start_issue, %Issue{id: "start-1"}, nil, 2}}
    assert post_recorded(%{"issue_identifier" => "START-1", "slot" => " 1 "}).status == 200
    assert_received {:orchestrator_call, {:start_issue, %Issue{}, nil, 1}}

    for slot <- [0, 3, "two", 1.5] do
      conn = post_recorded(%{"issue_identifier" => "START-1", "slot" => slot})
      assert conn.status == 422
      assert json_body(conn)["error"]["message"] =~ "is not a slot: use a whole number from 1 to 2."
    end

    refute_received {:orchestrator_call, _message}
  end

  defp post_recorded(params) do
    {:ok, orchestrator} = GenServer.start_link(RecordingOrchestrator, self())
    post_with(params, orchestrator)
  end

  defp post_start(params, replies \\ []) do
    {:ok, orchestrator} = GenServer.start_link(StubOrchestrator, replies)
    post_with(params, orchestrator)
  end

  defp post_with(params, orchestrator) do
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
