defmodule SymphonyElixirWeb.TicketBlockersController do
  @moduledoc """
  The blockers of a ticket Symphony tracks, for its page in the Mac app (TP-1354):

      GET /api/v1/tickets/:issue_identifier/blockers

  answers `{"issue_identifier", "blockers": [...], "candidates": [...]}` from the tickets' records
  (`SymphonyElixir.DirectorBlockers.blockers/2`): each blocker and each open ticket the Director can
  add as one, with its identifier, title and phase (`state`). A ticket Symphony doesn't track is
  404. Like the other reads of `/api/v1`, it needs no token; the change is
  `POST /api/v1/control/blocker`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.DirectorBlockers

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, %{"issue_identifier" => identifier}) do
    case DirectorBlockers.blockers(identifier, Map.get(conn.assigns, :director_blockers, [])) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, {:conflict, message}} ->
        conn |> put_status(404) |> json(%{error: %{code: "ticket_not_found", message: message}})
    end
  end
end
