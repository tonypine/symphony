defmodule SymphonyElixirWeb.ObservabilityHistoryTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.RunStore

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    :ok
  end

  test "GET /api/v1/history serves the run records' history" do
    :ok =
      RunStore.put_run(%{
        repo_key: Config.repo_key!(),
        run_id: "history-run-1",
        issue_id: "history-issue-1",
        issue_identifier: "HIS-1",
        status: "success",
        model: "claude-opus-5-5",
        tokens: %{total_tokens: 1_234},
        started_at: DateTime.utc_now()
      })

    body = json_response(get(build_conn(), "/api/v1/history?days=3"), 200)

    assert %{"days" => 3, "tokens_per_day" => [_, _, today], "tickets" => tickets, "merged_per_day" => [_, _, _]} = body
    assert today["providers"]["anthropic"] >= 1_234
    assert Enum.any?(tickets, &(&1["identifier"] == "HIS-1" and &1["total_tokens"] == 1_234))
  end

  test "GET /api/v1/history rejects an invalid days value and other methods" do
    assert %{"error" => %{"code" => "invalid_days"}} = json_response(get(build_conn(), "/api/v1/history?days=500"), 400)
    assert json_response(post(build_conn(), "/api/v1/history", %{}), 405)
  end
end
