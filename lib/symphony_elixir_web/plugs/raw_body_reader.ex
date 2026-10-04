defmodule SymphonyElixirWeb.Plugs.RawBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that keeps a copy of the raw body for the GitHub webhook route,
  whose `X-Hub-Signature-256` is an HMAC of the exact bytes GitHub sent.
  """

  alias Plug.Conn

  @webhook_path "/api/v1/github/webhook"

  @spec read_body(Conn.t(), keyword()) :: {:ok | :more, binary(), Conn.t()} | {:error, term()}
  def read_body(%Conn{} = conn, opts) do
    with {status, body, conn} <- Conn.read_body(conn, opts) do
      {status, body, cache(conn, body)}
    end
  end

  @doc "The raw body cached while parsing the request, or nil when it wasn't read."
  @spec raw_body(Conn.t()) :: binary() | nil
  def raw_body(%Conn{private: %{raw_body: chunks}}), do: IO.iodata_to_binary(chunks)
  def raw_body(%Conn{}), do: nil

  defp cache(%Conn{request_path: @webhook_path} = conn, body) do
    Conn.put_private(conn, :raw_body, [Map.get(conn.private, :raw_body, []), body])
  end

  defp cache(conn, _body), do: conn
end
