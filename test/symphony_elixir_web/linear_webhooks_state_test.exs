defmodule SymphonyElixirWeb.LinearWebhooksStateTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias SymphonyElixir.Linear.Webhook.Deliveries
  alias SymphonyElixir.TicketObservation

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

    Deliveries.reset()
    TicketObservation.reset()

    on_exit(fn ->
      Deliveries.reset()
      TicketObservation.reset()
    end)

    write_workflow_file!(Workflow.workflow_file_path())
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> "linear:\n  webhooks:\n    enabled: true\n    secret: lin_wh_test_secret\n")
    Cache.clear()
    :ok
  end

  test "the linear_webhooks section: the settings, the delivery counts and the webhook-or-poll comparison, with ISO 8601 times" do
    Deliveries.accepted(%{"type" => "Issue", "action" => "update", "data" => %{"identifier" => "TP-7"}}, ~U[2026-10-29 09:00:00Z], :updated)
    Deliveries.rejected(:bad_signature, ~U[2026-10-29 09:01:00Z])

    assert build_conn() |> get("/api/v1/state") |> json_response(200) |> Map.fetch!("linear_webhooks") == %{
             "enabled" => true,
             "secret_configured" => true,
             "total" => 1,
             "rejected" => 1,
             "last_at" => "2026-10-29T09:00:00Z",
             "last_type" => "Issue",
             "last_action" => "update",
             "last_rejected_at" => "2026-10-29T09:01:00Z",
             "last_rejected_reason" => "bad_signature",
             "counts" => [%{"type" => "Issue", "action" => "update", "count" => 1}],
             "rejected_reasons" => [%{"reason" => "bad_signature", "count" => 1}],
             "observations" => %{"updated" => 1, "unchanged" => 0, "stale" => 0, "unrouted" => 0, "removed" => 0, "no_record" => 0, "error" => 0},
             "recent" => [%{"type" => "Issue", "action" => "update", "identifier" => "TP-7", "observation" => "updated", "received_at" => "2026-10-29T09:00:00Z"}],
             "compare" => %{"webhook_first" => 0, "poll_first" => 0, "poll_first_recent" => []}
           }
  end
end
