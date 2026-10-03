defmodule SymphonyElixir.OpenRouter.ModelsTest do
  use ExUnit.Case

  alias SymphonyElixir.OpenRouter.Models

  @catalog %{
    "data" => [
      %{"id" => "anthropic/claude-haiku-4.5", "supported_parameters" => ["tools", "reasoning", "max_tokens"], "context_length" => 200_000},
      %{"id" => "acme/chat-only", "supported_parameters" => ["max_tokens"], "context_length" => 8_192},
      %{"id" => "acme/no-params"},
      %{"name" => "missing id"}
    ]
  }

  setup do
    Models.clear_cache()
    on_exit(&Models.clear_cache/0)
  end

  test "reads tools, reasoning and context_length for each model" do
    parent = self()

    request_fun = fn url, opts ->
      send(parent, {:request, url, opts})
      {:ok, %{status: 200, body: @catalog}}
    end

    assert Models.lookup("anthropic/claude-haiku-4.5", request_fun: request_fun) ==
             {:ok, %{tools: true, reasoning: true, context_length: 200_000}}

    assert_received {:request, "https://openrouter.ai/api/v1/models", opts}
    assert opts[:retry] == false

    assert Models.lookup("acme/chat-only", request_fun: request_fun) == {:ok, %{tools: false, reasoning: false, context_length: 8_192}}
    assert Models.lookup("acme/no-params", request_fun: request_fun) == {:ok, %{tools: false, reasoning: false, context_length: nil}}
    assert Models.lookup("acme/missing", request_fun: request_fun) == {:error, :unknown_model}
    assert Models.endpoint() == "https://openrouter.ai/api/v1/models"
  end

  test "caches the catalog until the TTL passes" do
    parent = self()

    request_fun = fn _url, _opts ->
      send(parent, :fetched)
      {:ok, %{status: 200, body: @catalog}}
    end

    assert {:ok, _catalog} = Models.catalog(request_fun: request_fun, now_ms: 0)
    assert {:ok, _catalog} = Models.catalog(request_fun: request_fun, now_ms: :timer.minutes(59))
    assert_received :fetched
    refute_received :fetched

    assert {:ok, _catalog} = Models.catalog(request_fun: request_fun, now_ms: :timer.hours(1))
    assert_received :fetched
  end

  test "does not cache a failed request" do
    assert Models.lookup("acme/chat-only", request_fun: fn _url, _opts -> {:error, %Req.TransportError{reason: :nxdomain}} end) ==
             {:error, {:unavailable, %Req.TransportError{reason: :nxdomain}}}

    assert {:ok, %{tools: false}} = Models.lookup("acme/chat-only", request_fun: fn _url, _opts -> {:ok, %{status: 200, body: @catalog}} end)
  end

  test "reports HTTP errors and unexpected bodies" do
    unavailable = fn _url, _opts -> {:ok, %{status: 503, body: "down"}} end
    assert Models.catalog(request_fun: unavailable) == {:error, {:http_status, 503}}
    assert Models.catalog(request_fun: fn _url, _opts -> {:ok, %{status: 200, body: "<html>"}} end) == {:error, :invalid_body}
  end

  test "uses the configured request function by default" do
    assert Models.catalog() == {:error, :network_disabled_in_tests}
  end

  test "formats failure reasons" do
    assert Models.format_reason({:http_status, 503}) == "HTTP 503"
    assert Models.format_reason(:invalid_body) == "unexpected response body"
    assert Models.format_reason(%Req.TransportError{reason: :nxdomain}) == "non-existing domain"
    assert Models.format_reason(:timeout) == ":timeout"
  end
end
