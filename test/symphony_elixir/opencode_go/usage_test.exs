defmodule SymphonyElixir.OpencodeGo.UsageTest do
  # Not async: one test sets `OPENCODE_API_KEY` in Symphony's environment.
  use ExUnit.Case, async: false

  alias SymphonyElixir.OpencodeGo.Usage

  @key "sk-go-test-key"
  @answer %{
    "usage" => %{
      "rolling" => %{"status" => "ok", "percent" => 30, "resetsAt" => "2026-11-21T15:00:00.000Z"},
      "weekly" => %{"status" => "rate-limited", "percent" => 100, "resetsAt" => "2026-11-23T00:00:00.000Z"},
      "monthly" => %{"status" => "ok", "percent" => 50, "resetsAt" => "2026-12-01T00:00:00.000Z"}
    }
  }

  defp answering(response) do
    test = self()

    fn url, options ->
      send(test, {:requested, url, options})
      response
    end
  end

  test "reads the 5-hour, weekly and monthly windows with the key as a bearer token, as the docs give them" do
    assert {:ok, windows} = Usage.read(api_key: SymphonyElixir.Secret.wrap(@key), request_fun: answering({:ok, %{status: 200, body: @answer}}))

    assert windows == %{
             "five_hour" => %{status: "allowed", utilization: 0.3, resets_at: ~U[2026-11-21 15:00:00.000Z]},
             "seven_day" => %{status: "rejected", utilization: 1.0, resets_at: ~U[2026-11-23 00:00:00.000Z]},
             "monthly" => %{status: "allowed", utilization: 0.5, resets_at: ~U[2026-12-01 00:00:00.000Z]}
           }

    assert_received {:requested, "https://opencode.ai/inference/go/v1/usage", options}
    assert {"authorization", "Bearer " <> @key} in options[:headers]
    assert options[:retry] == false
  end

  test "reads with the configured key, and says so when none is set" do
    previous = System.get_env("OPENCODE_API_KEY")
    on_exit(fn -> if previous, do: System.put_env("OPENCODE_API_KEY", previous), else: System.delete_env("OPENCODE_API_KEY") end)

    System.delete_env("OPENCODE_API_KEY")
    assert Usage.read(request_fun: answering({:ok, %{status: 200, body: @answer}})) == {:error, :no_key}
    refute_received {:requested, _url, _options}

    System.put_env("OPENCODE_API_KEY", @key)
    assert {:ok, %{"five_hour" => _}} = Usage.read(request_fun: answering({:ok, %{status: 200, body: Jason.encode!(@answer)}}))
    assert_received {:requested, _url, options}
    assert {"authorization", "Bearer " <> @key} in options[:headers]

    # With no request function, the app env's (offline in tests) is used.
    assert Usage.read() == {:error, :network_disabled_in_tests}
  end

  test "a refused key, a server error and an unreachable API are errors, never windows" do
    for {response, error} <- [
          {{:ok, %{status: 401, body: %{"type" => "error"}}}, {:http_status, 401}},
          {{:ok, %{status: 403, body: %{"type" => "error", "error" => %{"type" => "EntitlementError"}}}}, {:http_status, 403}},
          {{:ok, %{status: 500, body: ""}}, {:http_status, 500}},
          {{:error, :econnrefused}, :econnrefused}
        ] do
      assert Usage.read(api_key: @key, request_fun: answering(response)) == {:error, error}
    end

    assert {:error, %RuntimeError{message: "boom"}} = Usage.read(api_key: @key, request_fun: fn _url, _options -> raise "boom" end)
    assert {:error, {:exit, :timeout}} = Usage.read(api_key: @key, request_fun: fn _url, _options -> exit(:timeout) end)
  end

  test "an answer without readable meters is an invalid body; an unreadable meter is left out" do
    for body <- ["not json", ~s(["usage"]), %{"usage" => %{}}, %{"other" => 1}, %{"usage" => %{"weekly" => %{"percent" => "high", "resetsAt" => "soon"}}}] do
      assert Usage.parse(body) == {:error, :invalid_body}, inspect(body)
    end

    assert {:ok, windows} =
             Usage.parse(%{
               "usage" => %{
                 "rolling" => %{"status" => "ok", "percent" => 130, "resetsAt" => "2026-11-21T15:00:00Z"},
                 "weekly" => %{"status" => "ok", "percent" => 40, "resetsAt" => "not a time"}
               }
             })

    assert windows == %{"five_hour" => %{status: "allowed", utilization: 1.0, resets_at: ~U[2026-11-21 15:00:00Z]}}
  end

  test "QA mode reads the stub's usage; anywhere else OpenCode Go's" do
    assert Usage.provider() == "opencode-go"
    assert Usage.url(%{}) == "https://opencode.ai/inference/go/v1/usage"
    assert Usage.url(%{"SYMPHONY_QA_OPENROUTER_URL" => "http://127.0.0.1:4100/api"}) == "https://opencode.ai/inference/go/v1/usage"

    assert Usage.url(%{"SYMPHONY_BAR_QA_ROOT" => "/tmp/qa", "SYMPHONY_QA_OPENROUTER_URL" => "http://127.0.0.1:4100/api/"}) ==
             "http://127.0.0.1:4100/api/opencode-go/v1/usage"

    assert Usage.url(%{"SYMPHONY_BAR_QA_ROOT" => "/tmp/qa", "SYMPHONY_QA_OPENROUTER_URL" => "https://example.com/api"}) ==
             "https://opencode.ai/inference/go/v1/usage"
  end

  test "each failure reads as a short reason" do
    assert Usage.format_reason(:no_key) == "OPENCODE_API_KEY is not set"
    assert Usage.format_reason({:http_status, 401}) == "HTTP 401 (the key is not valid)"
    assert Usage.format_reason({:http_status, 403}) == "HTTP 403 (the key has no OpenCode Go subscription)"
    assert Usage.format_reason({:http_status, 502}) == "HTTP 502"
    assert Usage.format_reason(:invalid_body) == "unexpected response body"
    assert Usage.format_reason(%RuntimeError{message: "boom"}) == "boom"
    assert Usage.format_reason(:econnrefused) == ":econnrefused"
  end
end
