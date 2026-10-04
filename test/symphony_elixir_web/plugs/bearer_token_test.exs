defmodule SymphonyElixirWeb.Plugs.BearerTokenTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{ControlToken, Paths}
  alias SymphonyElixirWeb.Plugs.BearerToken

  @token "secret-token-value"

  defmodule FakeToken do
    def value, do: "secret-token-value"
  end

  # The plug caches the default token for the BEAM's lifetime, so an earlier
  # test that sent a request through the router leaves its own token cached.
  setup do
    :persistent_term.erase(BearerToken)
    on_exit(fn -> :persistent_term.erase(BearerToken) end)
    :ok
  end

  defp call(headers) do
    conn = conn(:post, "/api/v1/control/pause")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc ->
        put_req_header(acc, name, value)
      end)

    BearerToken.call(conn, BearerToken.init(token: &FakeToken.value/0))
  end

  test "passes the connection through when the bearer token matches" do
    conn = call([{"authorization", "Bearer #{@token}"}])

    refute conn.halted
    assert conn.status in [nil, 200]
  end

  test "tolerates extra spaces between scheme and token" do
    conn = call([{"authorization", "Bearer    #{@token}"}])
    refute conn.halted
  end

  test "rejects requests without an Authorization header with 401" do
    conn = call([])

    assert conn.halted
    assert conn.status == 401
    assert json_body(conn)["error"]["code"] == "unauthorized"
  end

  test "rejects requests with a non-Bearer scheme with 401" do
    conn = call([{"authorization", "Basic #{Base.encode64("user:pass")}"}])

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects requests carrying the wrong token with 401" do
    conn = call([{"authorization", "Bearer not-the-right-token"}])

    assert conn.halted
    assert conn.status == 401
  end

  test "init defaults the token resolver to SymphonyElixir.ControlToken.current/0" do
    opts = BearerToken.init([])
    assert opts[:token] == (&SymphonyElixir.ControlToken.current/0)
  end

  test "accepts a pre-resolved binary token in opts and uses it directly" do
    conn =
      :post
      |> conn("/api/v1/control/pause")
      |> put_req_header("authorization", "Bearer fixed-token")
      |> BearerToken.call(token: "fixed-token")

    refute conn.halted
  end

  test "caches the default ControlToken.current/0 result for the BEAM lifetime" do
    tmp =
      Path.join(System.tmp_dir!(), "symphony-bearer-cache-test-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:symphony_elixir, :state_root_override)
    Paths.set_state_root(tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      case previous do
        nil -> Application.delete_env(:symphony_elixir, :state_root_override)
        value -> Application.put_env(:symphony_elixir, :state_root_override, value)
      end
    end)

    expected = ControlToken.current()
    opts = BearerToken.init([])

    conn1 =
      :post
      |> conn("/api/v1/control/pause")
      |> put_req_header("authorization", "Bearer #{expected}")
      |> BearerToken.call(opts)

    refute conn1.halted
    assert :persistent_term.get(BearerToken) == expected

    # Wipe the on-disk token; a cached resolution must still let the request through.
    File.rm!(Paths.control_token_file())

    conn2 =
      :post
      |> conn("/api/v1/control/pause")
      |> put_req_header("authorization", "Bearer #{expected}")
      |> BearerToken.call(opts)

    refute conn2.halted
  end

  defp json_body(conn) do
    Jason.decode!(conn.resp_body)
  end
end
