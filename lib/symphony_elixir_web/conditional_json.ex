defmodule SymphonyElixirWeb.ConditionalJSON do
  @moduledoc """
  A JSON answer a client may read again only when it changed (TP-1492): the answer carries an
  `ETag`, a strong validator made of the SHA-256 of its body, and a request whose `If-None-Match`
  names that tag (or `*`) gets `304 Not Modified` with no body. The Director's ticket page sends
  the tag of the answer it shows with each read of the ticket (`GET /api/v1/:issue_identifier`)
  and of its decisions (`GET /api/v1/tickets/:issue_identifier/decisions`), so while nothing
  changes Symphony sends no body and the app decodes nothing. The tag is the body's, so any change
  to the answer (a state move, a label, a new question, an answered decision) gives a new tag and
  the full answer on the same read.
  """

  import Plug.Conn

  alias Plug.Conn

  @doc "Answers `payload` as JSON with its `ETag`, or `304` with no body when the request already holds it."
  @spec json(Conn.t(), term()) :: Conn.t()
  def json(conn, payload) do
    body = Jason.encode_to_iodata!(payload)
    tag = etag(body)
    conn = put_resp_header(conn, "etag", tag)

    if fresh?(conn, tag) do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end

  @doc "The strong validator of `body`: a quoted hex SHA-256, cut to 32 characters."
  @spec etag(iodata()) :: String.t()
  def etag(body) do
    digest = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    ~s("#{digest}")
  end

  # Whether the request's `If-None-Match` names `tag`: `*`, or a list of tags, weak ones (`W/"…"`)
  # compared by their value as RFC 9110 asks of `If-None-Match`.
  defp fresh?(conn, tag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
    |> Enum.any?(&(&1 == "*" or &1 == tag))
  end
end
