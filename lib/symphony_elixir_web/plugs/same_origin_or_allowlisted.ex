defmodule SymphonyElixirWeb.Plugs.SameOriginOrAllowlisted do
  @moduledoc """
  Rejects non-GET requests unless their Origin is trusted by the dashboard policy.

  With `allow_missing: true`, a request with no Origin passes too: browsers send one on every
  cross-origin POST, so only a non-browser client (curl, the app) sends none.
  """

  @behaviour Plug

  import Plug.Conn

  alias Plug.Conn
  alias SymphonyElixir.HttpServer

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Conn.t(), keyword()) :: Conn.t()
  def call(%Conn{method: "GET"} = conn, _opts), do: conn

  def call(%Conn{} = conn, opts) do
    case get_req_header(conn, "origin") do
      [] ->
        if Keyword.get(opts, :allow_missing, false), do: conn, else: reject(conn)

      [origin] ->
        origin
        |> URI.parse()
        |> HttpServer.allowed_origin?()
        |> maybe_allow(conn)

      _ambiguous ->
        reject(conn)
    end
  end

  defp maybe_allow(true, conn), do: conn
  defp maybe_allow(false, conn), do: reject(conn)

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: %{code: "forbidden_origin", message: "Origin is not allowed"}}))
    |> halt()
  end
end
