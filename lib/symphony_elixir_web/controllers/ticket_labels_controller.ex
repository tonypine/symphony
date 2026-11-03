defmodule SymphonyElixirWeb.TicketLabelsController do
  @moduledoc """
  The label toggles of a ticket Symphony tracks, for its page in the Mac app (TP-1356):

      GET /api/v1/tickets/:issue_identifier/labels

  answers `{"issue_identifier", "labels"}` from the ticket's record
  (`SymphonyElixir.DirectorLabels.labels/2`): each label a person adds for Symphony to read, with
  its `title`, its one-line `effect` and whether it is `on`. A ticket Symphony doesn't track is 404.
  Like the other reads of `/api/v1`, it needs no token; the change is `POST /api/v1/control/label`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.DirectorLabels

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, %{"issue_identifier" => identifier}) do
    case DirectorLabels.labels(identifier, Map.get(conn.assigns, :director_labels, [])) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, {:conflict, message}} ->
        conn |> put_status(404) |> json(%{error: %{code: "ticket_not_found", message: message}})
    end
  end
end
