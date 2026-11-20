defmodule SymphonyElixirWeb.ObservabilityDrainTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  @endpoint SymphonyElixirWeb.Endpoint

  # Answers the snapshot call with the snapshot it was started with, or never answers when it is
  # `:hang`.
  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link({name, snapshot}), do: GenServer.start_link(__MODULE__, snapshot, name: name)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, :hang), do: {:noreply, :hang}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  defp serve(orchestrator) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 100)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp serve_snapshot(snapshot) do
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: SnapshotOrchestrator, start: {SnapshotOrchestrator, :start_link, [{name, snapshot}]}})
    serve(name)
  end

  # An entry `GET /api/v1/state` could fail to present: the drain reads only its step.
  defp run(waiting), do: %{issue_identifier: "TP-1", step: %{waiting: waiting}, unpresentable: make_ref()}

  test "GET /api/v1/drain counts the agent runs, those between turns and whether dispatch is paused" do
    serve_snapshot(%{running: [run(nil), run("pause"), run("answer")], retrying: [], pause: %{paused: true, reason: "build"}})

    assert json_response(get(build_conn(), "/api/v1/drain"), 200) == %{"running" => 3, "between_turns" => 2, "paused" => true}
    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(post(build_conn(), "/api/v1/drain", %{}), 405)
  end

  test "GET /api/v1/drain says dispatch isn't paused when the snapshot has no pause" do
    serve_snapshot(%{running: [], retrying: []})
    assert json_response(get(build_conn(), "/api/v1/drain"), 200) == %{"running" => 0, "between_turns" => 0, "paused" => false}
  end

  test "GET /api/v1/drain answers 503 when the orchestrator doesn't answer in time" do
    serve_snapshot(:hang)
    assert %{"error" => %{"code" => "snapshot_timeout"}} = json_response(get(build_conn(), "/api/v1/drain"), 503)
  end

  test "GET /api/v1/drain answers 503 when no orchestrator runs" do
    serve(Module.concat(__MODULE__, "Missing"))
    assert %{"error" => %{"code" => "snapshot_unavailable"}} = json_response(get(build_conn(), "/api/v1/drain"), 503)
  end
end
