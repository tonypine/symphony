defmodule SymphonyElixirWeb.ConditionalJSONTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  alias SymphonyElixir.TicketState
  alias SymphonyElixirWeb.ConditionalJSON

  @endpoint SymphonyElixirWeb.Endpoint

  # Answers `GET /api/v1/:identifier` with an idle snapshot, so the ticket is served from its record.
  defmodule IdleOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, %{running: [], retrying: [], rate_limits: nil}, state}
  end

  defp answer(headers) do
    headers
    |> Enum.reduce(conn(:get, "/api/v1/TP-1"), fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> ConditionalJSON.json(%{phase: "Rework"})
  end

  defp etag(conn), do: conn |> get_resp_header("etag") |> List.first()

  describe "json/2" do
    test "answers the body with its tag, which is the body's" do
      conn = answer([])
      tag = ConditionalJSON.etag(Jason.encode_to_iodata!(%{phase: "Rework"}))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"phase" => "Rework"}
      assert etag(conn) == tag
      assert tag =~ ~r/\A"[0-9a-f]{32}"\z/
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
      assert ConditionalJSON.etag("other") != tag
    end

    test "answers 304 with no body to a request holding the tag, by itself, in a list, weak or as *" do
      tag = etag(answer([]))

      for held <- [tag, ~s("old", #{tag}), "W/" <> tag, "*"] do
        conn = answer([{"if-none-match", held}])
        assert conn.status == 304
        assert conn.resp_body == ""
        assert etag(conn) == tag
      end
    end

    test "answers in full to a request holding another tag" do
      conn = answer([{"if-none-match", ~s("old")}])
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"phase" => "Rework"}
    end
  end

  describe "GET /api/v1/:issue_identifier" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path())
      :ok = RunStore.clear()
      on_exit(fn -> RunStore.clear() end)
      orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
      start_supervised!(%{id: IdleOrchestrator, start: {IdleOrchestrator, :start_link, [orchestrator]}})

      endpoint_config =
        :symphony_elixir
        |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
        |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      start_supervised!({SymphonyElixirWeb.Endpoint, []})
      :ok
    end

    defp put_ticket(phase) do
      repo_key = Config.repo_key!()
      :ok = RunStore.put_ticket_state(TicketState.new(repo_key, "issue-cj", %{issue_identifier: "CJ-1", phase: phase, title: "Export"}))
    end

    test "an unchanged ticket answers 304 with no body; a state move answers in full with a new tag" do
      put_ticket("In Progress")

      first = get(build_conn(), "/api/v1/CJ-1")
      assert first.status == 200
      tag = etag(first)
      assert is_binary(tag)

      unchanged = build_conn() |> put_req_header("if-none-match", tag) |> get("/api/v1/CJ-1")
      assert unchanged.status == 304
      assert unchanged.resp_body == ""

      put_ticket("Code Review")

      moved = build_conn() |> put_req_header("if-none-match", tag) |> get("/api/v1/CJ-1")
      assert moved.status == 200
      assert Jason.decode!(moved.resp_body)["ticket"]["phase"] == "Code Review"
      assert etag(moved) != tag
    end

    test "a ticket Symphony doesn't know answers 404 with no tag" do
      missing = build_conn() |> put_req_header("if-none-match", "*") |> get("/api/v1/CJ-404")
      assert missing.status == 404
      assert get_resp_header(missing, "etag") == []
    end
  end
end
