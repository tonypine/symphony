defmodule SymphonyElixirWeb.TicketPriorityController do
  @moduledoc """
  The priority of a ticket Symphony tracks, for its page in the Mac app (TP-1355):

      GET /api/v1/tickets/:issue_identifier/priority

  answers `{"issue_identifier", "priority", "priority_value", "priorities"}` from the ticket's
  record (`SymphonyElixir.DirectorPriority.priority/2`): its Linear priority by name (`none`,
  `urgent`, `high`, `medium` or `low`) and number, and the five names to pick from. A ticket
  Symphony doesn't track is 404. Like the other reads of `/api/v1`, it needs no token; the change is
  `POST /api/v1/control/priority`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.DirectorPriority

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"issue_identifier" => identifier}) do
    case DirectorPriority.priority(identifier, Map.get(conn.assigns, :director_priority, [])) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, {:conflict, message}} ->
        conn |> put_status(404) |> json(%{error: %{code: "ticket_not_found", message: message}})
    end
  end
end
