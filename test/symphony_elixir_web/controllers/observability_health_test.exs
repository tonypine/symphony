defmodule SymphonyElixirWeb.ObservabilityHealthTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

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

  # A dev server's health check asks it, giving each request 250 ms: it answers as soon as the
  # endpoint serves, with no orchestrator running.
  test "GET /api/v1/health answers ok without the orchestrator, and refuses other methods" do
    refute GenServer.whereis(Orchestrator)

    assert json_response(get(build_conn(), "/api/v1/health"), 200) == %{"ok" => true}
    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(post(build_conn(), "/api/v1/health", %{}), 405)
  end
end
