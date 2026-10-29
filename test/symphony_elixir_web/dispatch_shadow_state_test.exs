defmodule SymphonyElixirWeb.DispatchShadowStateTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias SymphonyElixir.Dispatch.Shadow

  @endpoint SymphonyElixirWeb.Endpoint

  # Answers `GET /api/v1/state` with an idle snapshot.
  defmodule IdleOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, %{running: [], retrying: [], rate_limits: nil}, state}
  end

  setup do
    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: IdleOrchestrator, start: {IdleOrchestrator, :start_link, [orchestrator]}})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    Shadow.reset()
    on_exit(&Shadow.reset/0)
    :ok
  end

  defp dispatch_shadow_state, do: build_conn() |> get("/api/v1/state") |> json_response(200) |> Map.fetch!("dispatch_shadow")

  test "before any cycle: the source, the window and an empty report" do
    assert dispatch_shadow_state() == %{
             "source" => "poll",
             "window" => 20,
             "cycles_compared" => 0,
             "cycles_with_differences" => 0,
             "window_cycles" => 0,
             "window_differences" => 0,
             "recent" => [],
             "record_newer" => %{"count" => 0, "recent" => []}
           }
  end

  test "reports source record, names each difference with its ticket, side and field, and counts record_newer apart" do
    File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "dispatch:\n  source: record\n  shadow_window: 5\n")
    Cache.clear()

    issue = %Issue{id: "issue-1", identifier: "ACME-1", title: "Shadowed", state: "Todo", priority: 1, repo_key: "web"}
    moved = %Issue{id: "issue-2", identifier: "ACME-2", title: "Moved", state: "Rework", priority: 1, repo_key: "web"}
    newer = Shadow.compare([moved], [%{moved | state: "Code Review"}])
    Shadow.record(%{differences: [], record_newer: newer}, 5)
    capture_log(fn -> Shadow.record(Shadow.compare([issue], []), 5, ~U[2026-10-29 17:00:00Z]) end)

    assert dispatch_shadow_state() == %{
             "source" => "record",
             "window" => 5,
             "cycles_compared" => 2,
             "cycles_with_differences" => 1,
             "window_cycles" => 2,
             "window_differences" => 1,
             "recent" => [
               %{
                 "repo_key" => "web",
                 "issue_id" => "issue-1",
                 "identifier" => "ACME-1",
                 "side" => "poll",
                 "field" => "candidate",
                 "poll" => "Todo",
                 "record" => nil,
                 "at" => "2026-10-29T17:00:00Z"
               }
             ],
             "record_newer" => %{"count" => 1, "recent" => ["ACME-2"]}
           }
  end
end
