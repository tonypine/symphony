defmodule SymphonyElixir.OpenRouter.StubTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.OpenRouter.Stub

  setup do
    test = self()
    {:ok, pid, port} = Stub.start_link(log: &send(test, {:stub_log, &1}))
    on_exit(fn -> Stub.stop(pid) end)
    %{url: Stub.url(port), pid: pid}
  end

  defp request(method, url, opts \\ []) do
    Req.request!([method: method, url: url, retry: false, decode_body: false] ++ opts)
  end

  defp valid_key, do: [auth: {:bearer, Stub.valid_key()}]

  test "answers the key check for the one valid key and rejects any other", %{url: url} do
    assert Stub.valid_key() == "sk-or-v1-symphony-qa-stub"
    assert url =~ ~r{\Ahttp://127\.0\.0\.1:\d+/api\z}

    response = request(:get, url <> "/v1/key", valid_key())
    assert response.status == 200
    assert %{"data" => %{"label" => "Symphony QA stub", "usage" => 1.25, "limit" => 10.0, "limit_remaining" => 8.75, "is_free_tier" => false}} = Jason.decode!(response.body)
    assert_received {:stub_log, "OpenRouter stub: GET /api/v1/key key=accepted status=200"}

    for opts <- [[auth: {:bearer, "sk-or-v1-made-up"}], []] do
      response = request(:get, url <> "/v1/key", opts)
      assert response.status == 401
      assert %{"error" => %{"code" => 401}} = Jason.decode!(response.body)
    end

    assert_received {:stub_log, "OpenRouter stub: GET /api/v1/key key=rejected status=401"}
  end

  test "lists a model with tools and reasoning, one with tools only and one without tools", %{url: url} do
    response = request(:get, url <> "/v1/models")
    assert response.status == 200
    assert %{"data" => models} = Jason.decode!(response.body)
    assert models == Stub.models()

    capabilities = Map.new(models, &{&1["id"], {"tools" in &1["supported_parameters"], "reasoning" in &1["supported_parameters"]}})

    assert capabilities == %{
             "symphony-qa/reasoning-tools" => {true, true},
             "symphony-qa/tools-only" => {true, false},
             "symphony-qa/no-tools" => {false, false}
           }
  end

  test "answers an Anthropic messages call with the model it was asked for", %{url: url} do
    body = %{"model" => "symphony-qa/tools-only", "max_tokens" => 10, "messages" => [%{"role" => "user", "content" => "hi"}]}

    response = request(:post, url <> "/v1/messages", [json: body] ++ valid_key())
    assert response.status == 200
    assert %{"type" => "message", "model" => "symphony-qa/tools-only", "content" => [%{"text" => text}]} = Jason.decode!(response.body)
    assert text =~ "symphony-qa/tools-only"
    assert_received {:stub_log, "OpenRouter stub: POST /api/v1/messages model=symphony-qa/tools-only key=accepted status=200"}

    stream = request(:post, url <> "/v1/messages", json: Map.put(body, "stream", true), headers: [{"x-api-key", Stub.valid_key()}])
    assert stream.status == 200
    assert hd(Req.Response.get_header(stream, "content-type")) =~ "text/event-stream"

    events = for "data: " <> data <- String.split(stream.body, "\n"), do: Jason.decode!(data)
    assert Enum.map(events, & &1["type"]) == ~w(message_start content_block_start content_block_delta content_block_stop message_delta message_stop)
    assert hd(events)["message"]["model"] == "symphony-qa/tools-only"

    count = request(:post, url <> "/v1/messages/count_tokens", [json: %{}] ++ valid_key())
    assert count.status == 200
    assert Jason.decode!(count.body) == %{"input_tokens" => 1}
    assert_received {:stub_log, "OpenRouter stub: POST /api/v1/messages/count_tokens model=unknown key=accepted status=200"}
  end

  test "rejects a messages call without the valid key, a bad body and unknown paths", %{url: url} do
    assert request(:post, url <> "/v1/messages", json: %{"model" => "x"}).status == 401
    assert request(:post, url <> "/v1/messages", [body: "not json"] ++ valid_key()).status == 400
    assert request(:post, url <> "/v1/messages", [body: "[1]"] ++ valid_key()).status == 400
    assert request(:post, url <> "/v1/messages/batches", [json: %{}] ++ valid_key()).status == 404
    assert request(:get, url <> "/v1/credits", valid_key()).status == 404
    assert request(:get, String.replace(url, "/api", "/")).status == 404
    assert_received {:stub_log, "OpenRouter stub: GET /api/v1/credits key=accepted status=404"}
  end

  test "logs through Logger by default and stops", %{pid: pid} do
    assert :ok = Stub.stop(pid)
    assert :ok = Stub.stop(pid)

    {:ok, default, port} = Stub.start_link()

    log =
      capture_log(fn ->
        assert request(:get, Stub.url(port) <> "/v1/models").status == 200
      end)

    assert log =~ "OpenRouter stub: GET /api/v1/models key=rejected status=200"
    Stub.stop(default)
  end
end
