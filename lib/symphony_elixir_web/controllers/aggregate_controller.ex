defmodule SymphonyElixirWeb.AggregateController do
  @moduledoc """
  One aggregation read for the Insights pages (Quality, Usage and Shipped)
  (`SymphonyElixir.Aggregate`).

      GET /api/v1/aggregate?from=&to=&unit=30m|1h|6h|day|week&repo=&epic=&series=

  answers `{"generated_at", "from", "to", "unit", "repo", "epic", "series": {name: series}}`, each
  series with its `total`, its total `by` key and by ticket (`tickets`) and its `buckets`
  (`start`, `end`, `value`, `by`; a `shipped` bucket also lists its `tickets`). `series` is a
  comma-separated list of `Aggregate.series_names/0` (default: all of them). A `from` or `to` that
  is not an ISO 8601 time or date, a `from` not before `to`, an unknown unit or series, a period over
  366 days or over 5000 buckets is 400 `invalid_query`. Like the other reads of `/api/v1`, it needs
  no token.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Aggregate

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    case Aggregate.read(params) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, {:invalid, message}} ->
        conn
        |> put_status(400)
        |> json(%{error: %{code: "invalid_query", message: message}})
    end
  end
end
