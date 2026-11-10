defmodule SymphonyElixirWeb.ViewsController do
  @moduledoc """
  The saved views of the Tickets page (`SymphonyElixir.Views`), stored on the server so every client
  lists the same ones.

      GET    /api/v1/views                  -> {"views": [view], "columns": [column], "filters": [name]}
      POST   /api/v1/control/view           {id?, name, filters, columns, sort} -> {"view": view}
      DELETE /api/v1/control/view/:id       -> {"deleted": id}

  The read needs no token; the writes need the control token, as every control call. A view that
  names an unknown column, filter, situation or direction, a missing name or malformed filters is
  `400` `invalid_view` with the reason (an unknown name's reason lists the catalog's names); an `id`
  no view has is `404` `view_not_found`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{TicketColumns, Views}

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params) do
    # A store error raises, as the other reads' do.
    {:ok, views} = Views.list()
    json(conn, %{views: Enum.map(views, &Views.payload/1), columns: TicketColumns.columns(), filters: TicketColumns.filter_names()})
  end

  @spec save(Conn.t(), map()) :: Conn.t()
  def save(conn, params) do
    case Views.save(params) do
      {:ok, view} -> json(conn, %{view: Views.payload(view)})
      {:error, {:invalid, message}} -> error_response(conn, 400, "invalid_view", message)
      {:error, :not_found} -> not_found(conn, params["id"])
    end
  end

  @spec delete(Conn.t(), map()) :: Conn.t()
  def delete(conn, %{"id" => id}) do
    case Views.delete(id) do
      :ok -> json(conn, %{deleted: id})
      {:error, :not_found} -> not_found(conn, id)
    end
  end

  defp not_found(conn, id), do: error_response(conn, 404, "view_not_found", "No view has the id #{id}")

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
