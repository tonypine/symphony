defmodule SymphonyElixirWeb.GitHubWebhookControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, post: 3, json_response: 2]

  @endpoint SymphonyElixirWeb.Endpoint
  @secret "s3cret"

  defmodule ForwardingPoller do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :owner), name: Keyword.fetch!(opts, :name))

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_cast(message, owner) do
      send(owner, {:poller_cast, message})
      {:noreply, owner}
    end
  end

  setup do
    name = Module.concat(__MODULE__, "Poller#{System.unique_integer([:positive])}")
    start_supervised!({ForwardingPoller, name: name, owner: self()})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), ci_poller: name)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    write_workflow_file!(Workflow.workflow_file_path(), github: %{webhooks: %{enabled: true, secret: @secret}})
    :ok
  end

  test "answers 404 while webhooks are off" do
    write_workflow_file!(Workflow.workflow_file_path(), github: %{webhooks: %{enabled: false, secret: @secret}})

    body = Jason.encode!(%{"zen" => "hi"})
    conn = post_webhook(body, [{"content-type", "application/json"}, {"x-github-event", "ping"}, signature(body)])

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    refute_receive {:poller_cast, _message}
  end

  test "hands a signed JSON delivery to the CI poller" do
    body = Jason.encode!(%{"action" => "completed", "check_suite" => %{"head_sha" => "abc123"}})
    conn = post_webhook(body, [{"content-type", "application/json"}, {"x-github-event", "check_suite"}, signature(body)])

    assert json_response(conn, 202) == %{"status" => "accepted"}

    assert_receive {:poller_cast, {:webhook_delivery, {:ci, %{event: "check_suite", action: "completed", head_sha: "abc123", pr_urls: []}}}}
  end

  test "reads the payload of a signed form-encoded delivery" do
    payload = Jason.encode!(%{"action" => "completed", "check_run" => %{"head_sha" => "abc123"}})
    body = URI.encode_query(%{"payload" => payload})
    conn = post_webhook(body, [{"content-type", "application/x-www-form-urlencoded"}, {"x-github-event", "check_run"}, signature(body)])

    assert json_response(conn, 202) == %{"status" => "accepted"}
    assert_receive {:poller_cast, {:webhook_delivery, {:ci, %{event: "check_run", head_sha: "abc123"}}}}

    body = URI.encode_query(%{"payload" => "{not json"})
    conn = post_webhook(body, [{"content-type", "application/x-www-form-urlencoded"}, {"x-github-event", "check_run"}, signature(body)])

    assert json_response(conn, 202) == %{"status" => "ignored"}
    assert_receive {:poller_cast, {:webhook_delivery, :ignored}}
  end

  test "rejects an unsigned delivery, or one in a content type it doesn't read, with 401 and no payload in the log" do
    body = Jason.encode!(%{"secret_field" => "payload-value"})

    log =
      capture_log(fn ->
        conn = post_webhook(body, [{"content-type", "application/json"}])
        assert %{"error" => %{"code" => "invalid_signature"}} = json_response(conn, 401)

        conn = post_webhook(body, [{"content-type", "text/plain"}, {"x-github-event", "ping"}, {"x-github-delivery", "d-2"}, signature(body)])
        assert json_response(conn, 401)
      end)

    assert log =~ "Rejected GitHub webhook delivery=nil event=nil reason=missing_signature"
    assert log =~ ~s(Rejected GitHub webhook delivery="d-2" event="ping" reason=bad_signature)
    refute log =~ "payload-value"
    refute log =~ @secret

    assert_receive {:poller_cast, {:webhook_delivery, {:rejected, :missing_signature}}}
    assert_receive {:poller_cast, {:webhook_delivery, {:rejected, :bad_signature}}}
  end

  test "only takes POST" do
    conn = Phoenix.ConnTest.get(build_conn(), "/api/v1/github/webhook")

    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(conn, 405)
  end

  defp post_webhook(body, headers) do
    headers
    |> Enum.reduce(build_conn(), fn {name, value}, conn -> Plug.Conn.put_req_header(conn, name, value) end)
    |> post("/api/v1/github/webhook", body)
  end

  defp signature(body) do
    {"x-hub-signature-256", "sha256=" <> (:hmac |> :crypto.mac(:sha256, @secret, body) |> Base.encode16(case: :lower))}
  end
end
