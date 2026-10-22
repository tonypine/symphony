defmodule SymphonyElixirWeb.StreamControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.TicketEvents
  alias SymphonyElixirWeb.{ControlApiController, ObservabilityPubSub, StreamController}

  @endpoint SymphonyElixirWeb.Endpoint
  @repo_key "repo-a"
  @issue_id "issue-1"
  # A short shutdown timeout: the streams a test leaves open would hold the server's stop.
  @server [plug: @endpoint, scheme: :http, ip: :loopback, port: 0, thousand_island_options: [shutdown_timeout: 10]]

  defmodule StubOrchestrator do
    use GenServer

    def start_link(reply), do: GenServer.start_link(__MODULE__, reply)

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call(_msg, _from, reply), do: {:reply, reply, reply}
  end

  # The stream never ends on its own, so it is read over a real socket from a server on a free port.
  setup do
    :ok = RunStore.clear()
    previous_keep_alive = Application.get_env(:symphony_elixir, :stream_keep_alive_ms)

    on_exit(fn ->
      case previous_keep_alive do
        nil -> Application.delete_env(:symphony_elixir, :stream_keep_alive_ms)
        value -> Application.put_env(:symphony_elixir, :stream_keep_alive_ms, value)
      end
    end)

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    server = start_supervised!({Bandit, @server})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "TP-1"})
    {:ok, port: port}
  end

  test "an event written to a ticket reaches a connected client within a second", %{port: port} do
    client = open!(port)

    {:ok, event} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "live"})
    started = System.monotonic_time(:millisecond)
    buffer = recv_until!(client, "id: #{event.id}\n", 1_000)
    assert System.monotonic_time(:millisecond) - started < 1_000

    assert [notice] = notices(buffer)

    assert notice == %{
             "repo_key" => @repo_key,
             "issue_id" => @issue_id,
             "issue_identifier" => "TP-1",
             "event_id" => event.id,
             "type" => "note",
             "at" => DateTime.to_iso8601(event.at)
           }

    assert buffer =~ "event: ticket\nid: #{event.id}\ndata: {"
  end

  @tag :tmp_dir
  test "the Director's stop of a running ticket sends a notice naming that ticket", %{port: port, tmp_dir: tmp_dir} do
    client = open!(port)
    stopped = %{stopped: true, issue_id: @issue_id, issue_identifier: "TP-1", repo_key: @repo_key, session_id: "s-1"}
    {:ok, orchestrator} = StubOrchestrator.start_link({:ok, stopped})
    params = %{"issue_identifier" => "TP-1"}

    conn =
      build_conn(:post, "/api/v1/control/stop", params)
      |> Phoenix.Controller.put_view(SymphonyElixirWeb.ErrorJSON)
      |> Plug.Conn.assign(:orchestrator, orchestrator)
      |> Plug.Conn.assign(:audit_log, dir: tmp_dir)
      |> Map.merge(%{params: params, body_params: params})
      |> ControlApiController.stop(params)

    assert conn.status == 200
    buffer = recv_until!(client, "\"type\":\"person.action\"", 1_000)
    assert [%{"issue_identifier" => "TP-1", "issue_id" => @issue_id, "type" => "person.action"}] = notices(buffer)
  end

  test "repo_key and issue_identifier keep only that ticket's notices", %{port: port} do
    :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: "issue-2", issue_identifier: "TP-2"})
    :ok = RunStore.put_ticket_state(%{repo_key: "repo-b", issue_id: "issue-b", issue_identifier: "TP-1"})
    filtered = open!(port, "?repo_key=#{@repo_key}&issue_identifier=TP-1")
    everything = open!(port, "?repo_key=%20&issue_identifier=")

    {:ok, other_ticket} = TicketEvents.record(@repo_key, "issue-2", "note", %{text: "other ticket"})
    {:ok, other_repo} = TicketEvents.record("repo-b", "issue-b", "note", %{text: "other repo"})
    {:ok, wanted} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "wanted"})

    # Notices reach the stream in the order they were written, so the earlier ones came first if at all.
    assert [%{"event_id" => event_id}] = filtered |> recv_until!("id: #{wanted.id}\n", 1_000) |> notices()
    assert event_id == wanted.id

    assert everything |> recv_until!("id: #{wanted.id}\n", 1_000) |> notices() |> Enum.map(& &1["event_id"]) ==
             [other_ticket.id, other_repo.id, wanted.id]
  end

  test "an idle stream stays open with a keep-alive line at the interval", %{port: port} do
    assert StreamController.keep_alive_ms() == 15_000
    Application.put_env(:symphony_elixir, :stream_keep_alive_ms, 200)
    client = open!(port)
    opened = System.monotonic_time(:millisecond)

    first = recv_until!(client, ": keep-alive\n\n", 5_000)
    assert System.monotonic_time(:millisecond) - opened >= 150
    second = recv_until!(client, ": keep-alive\n\n", 5_000)
    assert System.monotonic_time(:millisecond) - opened >= 350

    assert notices(first <> second) == []
  end

  test "a client that goes away ends the response and leaves no subscriber", %{port: port} do
    Application.put_env(:symphony_elixir, :stream_keep_alive_ms, 20)
    client = open!(port)
    recv_until!(client, ": keep-alive\n\n", 5_000)

    assert [{stream, _value}] = Registry.lookup(SymphonyElixir.PubSub, ObservabilityPubSub.ticket_events_topic())
    ref = Process.monitor(stream)
    :ok = :gen_tcp.close(client)

    assert_receive {:DOWN, ^ref, :process, ^stream, _reason}, 5_000
    assert Registry.lookup(SymphonyElixir.PubSub, ObservabilityPubSub.ticket_events_topic()) == []
  end

  test "other methods are not allowed" do
    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(post(build_conn(), "/api/v1/stream"), 405)
  end

  # Opens the stream and reads past its response headers.
  defp open!(port, query \\ "") do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET /api/v1/stream#{query} HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: text/event-stream\r\n\r\n")
    headers = recv_until!(socket, "\r\n\r\n", 5_000)
    assert headers =~ "HTTP/1.1 200"
    assert headers =~ ~r/content-type: text\/event-stream\r\n/i
    assert headers =~ ~r/cache-control: no-cache/i
    socket
  end

  defp recv_until!(socket, pattern, timeout), do: recv_until!(socket, pattern, "", System.monotonic_time(:millisecond) + timeout)

  defp recv_until!(socket, pattern, buffer, deadline) do
    if String.contains?(buffer, pattern) do
      buffer
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      case :gen_tcp.recv(socket, 0, remaining) do
        {:ok, data} -> recv_until!(socket, pattern, buffer <> data, deadline)
        {:error, reason} -> flunk("no #{inspect(pattern)} on the stream (#{inspect(reason)}), got: #{inspect(buffer)}")
      end
    end
  end

  defp notices(buffer) do
    ~r/^data: (.*)$/m
    |> Regex.scan(buffer, capture: :all_but_first)
    |> Enum.map(fn [json] -> Jason.decode!(json) end)
  end
end
