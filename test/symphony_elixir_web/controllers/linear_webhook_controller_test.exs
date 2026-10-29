defmodule SymphonyElixirWeb.LinearWebhookControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, post: 3, json_response: 2]

  alias SymphonyElixir.Linear.Webhook.Deliveries

  @endpoint SymphonyElixirWeb.Endpoint
  @secret "lin_wh_test_secret"

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
    on_exit(&Deliveries.reset/0)
    configure_webhooks!(true)
    :ok
  end

  test "answers 404 while Linear webhooks are off, and counts nothing" do
    configure_webhooks!(false)
    body = delivery_body(%{"type" => "Issue", "action" => "update", "data" => %{"identifier" => "TP-7"}})

    conn = post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", sign(body)}])
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

    conn = post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", "00"}])
    assert json_response(conn, 404)

    assert %{"enabled" => false, "secret_configured" => true, "total" => 0, "rejected" => 0, "recent" => []} = linear_webhooks_state()
  end

  test "accepts a signed delivery with 202 and shows it in the state: type, action and the ticket's identifier" do
    assert %{"enabled" => true, "secret_configured" => true, "total" => 0, "last_at" => nil} = linear_webhooks_state()

    body = delivery_body(%{"type" => "Issue", "action" => "update", "data" => %{"identifier" => "TP-7", "title" => "Edited"}})
    conn = post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", sign(body)}])

    assert json_response(conn, 202) == %{"status" => "accepted"}

    assert %{
             "total" => 1,
             "rejected" => 0,
             "last_type" => "Issue",
             "last_action" => "update",
             "last_at" => last_at,
             "counts" => [%{"type" => "Issue", "action" => "update", "count" => 1}],
             "recent" => [%{"type" => "Issue", "action" => "update", "identifier" => "TP-7", "received_at" => last_at}]
           } = linear_webhooks_state()

    assert {:ok, _at, 0} = DateTime.from_iso8601(last_at)
  end

  test "accepts a signed delivery without a type or an action, counted as unknown" do
    body = delivery_body(%{"data" => "not a map"})
    conn = post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", sign(body)}])

    assert json_response(conn, 202) == %{"status" => "accepted"}
    assert %{"total" => 1, "recent" => [%{"type" => "unknown", "action" => "unknown", "identifier" => nil}]} = linear_webhooks_state()
  end

  test "rejects a wrong signature with 401, counts it with the reason, and logs neither payload nor secret" do
    body = delivery_body(%{"type" => "Issue", "action" => "update", "data" => %{"title" => "payload-value"}})

    log =
      capture_log(fn ->
        conn = post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", sign(body, "wrong")}])
        assert %{"error" => %{"code" => "invalid_signature"}} = json_response(conn, 401)
      end)

    assert log =~ "Rejected Linear webhook delivery reason=bad_signature"
    refute log =~ "payload-value"
    refute log =~ @secret

    assert %{
             "total" => 0,
             "rejected" => 1,
             "last_rejected_reason" => "bad_signature",
             "last_rejected_at" => at,
             "rejected_reasons" => [%{"reason" => "bad_signature", "count" => 1}],
             "recent" => []
           } = linear_webhooks_state()

    assert is_binary(at)
  end

  test "rejects an unsigned delivery, a stale one, and one in a content type it doesn't read" do
    capture_log(fn ->
      body = delivery_body(%{"type" => "Issue"})
      assert json_response(post_webhook(body, [{"content-type", "application/json"}]), 401)

      stale = Jason.encode!(%{"type" => "Issue", "webhookTimestamp" => System.system_time(:millisecond) - 120_000})
      assert json_response(post_webhook(stale, [{"content-type", "application/json"}, {"linear-signature", sign(stale)}]), 401)

      assert json_response(post_webhook(body, [{"content-type", "text/plain"}, {"linear-signature", sign(body)}]), 401)
    end)

    assert %{"total" => 0, "rejected" => 3, "rejected_reasons" => reasons} = linear_webhooks_state()

    assert Enum.sort_by(reasons, & &1["reason"]) == [
             %{"reason" => "bad_signature", "count" => 1},
             %{"reason" => "missing_signature", "count" => 1},
             %{"reason" => "stale_timestamp", "count" => 1}
           ]
  end

  test "shows the secret as not configured while its variable is unset, and refuses every delivery" do
    write_workflow_file!(Workflow.workflow_file_path())
    append_symphony_yml!("linear:\n  webhooks:\n    enabled: true\n    secret: $SYMPHONY_TEST_UNSET_LINEAR_WEBHOOK_SECRET\n")

    body = delivery_body(%{"type" => "Issue"})
    capture_log(fn -> assert json_response(post_webhook(body, [{"content-type", "application/json"}, {"linear-signature", sign(body)}]), 401) end)

    assert %{"enabled" => true, "secret_configured" => false, "rejected" => 1, "last_rejected_reason" => "missing_secret"} = linear_webhooks_state()
  end

  test "only takes POST" do
    conn = get(build_conn(), "/api/v1/linear/webhook")

    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(conn, 405)
  end

  defp configure_webhooks!(enabled) do
    write_workflow_file!(Workflow.workflow_file_path())
    append_symphony_yml!("linear:\n  webhooks:\n    enabled: #{enabled}\n    secret: #{@secret}\n")
  end

  defp append_symphony_yml!(yaml) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> yaml)
    Cache.clear()
  end

  defp linear_webhooks_state, do: build_conn() |> get("/api/v1/state") |> json_response(200) |> Map.fetch!("linear_webhooks")

  defp delivery_body(fields), do: fields |> Map.put("webhookTimestamp", System.system_time(:millisecond)) |> Jason.encode!()

  defp post_webhook(body, headers) do
    headers
    |> Enum.reduce(build_conn(), fn {name, value}, conn -> Plug.Conn.put_req_header(conn, name, value) end)
    |> post("/api/v1/linear/webhook", body)
  end

  defp sign(body, secret \\ @secret), do: :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)
end
