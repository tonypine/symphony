defmodule SymphonyElixirWeb.Plugs.SameOriginOrAllowlistedTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.Plugs.SameOriginOrAllowlisted

  test "init returns options unchanged" do
    assert SameOriginOrAllowlisted.init(foo: :bar) == [foo: :bar]
  end

  test "allows GET requests without an Origin header" do
    conn =
      :get
      |> Plug.Test.conn("/api/v1/state")
      |> SameOriginOrAllowlisted.call([])

    refute conn.halted
    assert conn.status == nil
  end

  test "rejects non-GET requests without an Origin header" do
    conn =
      :post
      |> Plug.Test.conn("/api/v1/refresh", "")
      |> SameOriginOrAllowlisted.call([])

    assert conn.halted
    assert conn.status == 403

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{"code" => "forbidden_origin", "message" => "Origin is not allowed"}
           }
  end

  test "with allow_missing, lets a non-GET request without an Origin header through, and still checks one with it" do
    conn =
      :post
      |> Plug.Test.conn("/api/v1/issues/TP-1/watch/check", "")
      |> SameOriginOrAllowlisted.call(allow_missing: true)

    refute conn.halted

    conn =
      :post
      |> Plug.Test.conn("/api/v1/issues/TP-1/watch/check", "")
      |> Plug.Conn.put_req_header("origin", "https://evil.example")
      |> SameOriginOrAllowlisted.call(allow_missing: true)

    assert conn.halted
    assert conn.status == 403
  end

  test "rejects non-GET requests with ambiguous Origin headers" do
    conn =
      :post
      |> Plug.Test.conn("/api/v1/refresh", "")
      |> Map.update!(:req_headers, &[{"origin", "http://127.0.0.1:4000"}, {"origin", "https://evil.example"} | &1])
      |> SameOriginOrAllowlisted.call([])

    assert conn.halted
    assert conn.status == 403
  end
end
