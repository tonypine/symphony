defmodule SymphonyElixirWeb.TicketsController do
  @moduledoc """
  The tickets a saved view selects, or an inline query does (`SymphonyElixir.TicketList`).

      GET /api/v1/tickets?view=<id>
      GET /api/v1/tickets?repo=&epic=&phase=&situation=&label=&priority=&since=&columns=&sort=&direction=

  answers `{"view": view | null, "filters", "columns": [column], "sort", "count", "tickets": [row]}`:
  each row the ticket's `issue_id` and the columns asked for, by name. Inline filters take
  comma-separated values (`SymphonyElixir.Views.query/1`); `view` and inline parameters don't mix.
  An unknown view is `404` `view_not_found`; a malformed query, or `view` with inline parameters,
  is `400` `invalid_query`. The situations come from what the orchestrator holds now: when its
  snapshot can't be read they are the records' alone, and the answer carries an `error`. Like the
  other reads of `/api/v1`, it needs no token.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Orchestrator, Situation, TicketColumns, TicketList, Views}
  alias SymphonyElixirWeb.Endpoint

  @inline ["columns", "sort", "direction" | TicketColumns.filter_names()]

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    with {:ok, view, spec} <- spec(params) do
      {live, error} = live()
      columns = Enum.map(spec.columns, fn name -> Enum.find(TicketColumns.columns(), &(&1.name == name)) end)
      tickets = TicketList.select(spec, live: live)

      payload = %{view: view && Views.payload(view), filters: spec.filters, columns: columns, sort: spec.sort, count: length(tickets), tickets: tickets}
      json(conn, if(error, do: Map.put(payload, :error, error), else: payload))
    else
      {:error, :not_found} -> error_response(conn, 404, "view_not_found", "No view has the id #{params["view"]}")
      {:error, {:invalid, message}} -> error_response(conn, 400, "invalid_query", message)
    end
  end

  defp spec(%{"view" => id} = params) when is_binary(id) and id != "" do
    if Enum.any?(@inline, &(Map.get(params, &1) not in [nil, ""])) do
      {:error, {:invalid, "view and inline filters, columns or sort don't mix"}}
    else
      with {:ok, view} <- Views.get(id), do: {:ok, view, Map.take(view, [:filters, :columns, :sort])}
    end
  end

  defp spec(params), do: with({:ok, spec} <- Views.query(params), do: {:ok, nil, spec})

  defp live do
    case Orchestrator.snapshot(Endpoint.config(:orchestrator) || Orchestrator, Endpoint.config(:snapshot_timeout_ms) || 15_000) do
      %{} = snapshot -> {Situation.live_facts(snapshot), nil}
      failure -> {Situation.live_facts(%{}), %{code: "snapshot_#{failure}", message: "Snapshot #{failure}: the situations are the records' alone"}}
    end
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
