defmodule SymphonyElixirWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias Phoenix.Endpoint.RenderErrors

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 2, sent_resp: 1]

  # The endpoint's own error rendering (`render_errors` in the config), as it runs when a
  # controller raises.
  defp crash(conn) do
    opts = :symphony_elixir |> Application.fetch_env!(SymphonyElixirWeb.Endpoint) |> Keyword.fetch!(:render_errors)

    assert_raise RuntimeError, "boom", fn ->
      RenderErrors.__catch__(conn, :error, %RuntimeError{message: "boom"}, [], opts)
    end

    sent_resp(conn)
  end

  test "a request that raises answers a JSON 500, whatever it accepts" do
    for accept <- [nil, "*/*", "text/html", "application/json"] do
      conn = conn(:get, "/api/v1/state")
      conn = if accept, do: put_req_header(conn, "accept", accept), else: conn

      assert {500, headers, body} = crash(conn)
      assert {"content-type", "application/json; charset=utf-8"} in headers
      assert Jason.decode!(body) == %{"error" => %{"code" => "request_failed", "message" => "Internal Server Error"}}
    end
  end
end
