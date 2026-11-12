defmodule SymphonyElixirWeb.TicketDecisionsController do
  @moduledoc """
  The decisions recorded on a ticket Symphony tracks, for its page in the Mac app (TP-1357):

      GET /api/v1/tickets/:issue_identifier/decisions

  answers `{"issue_identifier", "decisions"}` from the ticket's record
  (`SymphonyElixir.DirectorRulings.decisions/2`): each decision a person recorded on it, a Decide
  answer or a ruling, in the order recorded, with its `id` (`D1`, `D2`…), `date`, `title`,
  `question`, `answer` and `scope`. A ticket Symphony doesn't track is 404. Like the other reads of
  `/api/v1`, it needs no token; recording a ruling is `POST /api/v1/control/decision`.

  The answer carries an `ETag`; a read whose `If-None-Match` names it gets `304` with no body
  while the decisions are unchanged (`SymphonyElixirWeb.ConditionalJSON`, TP-1492).
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.DirectorRulings
  alias SymphonyElixirWeb.ConditionalJSON

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, %{"issue_identifier" => identifier}) do
    case DirectorRulings.decisions(identifier, Map.get(conn.assigns, :director_rulings, [])) do
      {:ok, payload} ->
        ConditionalJSON.json(conn, payload)

      {:error, {:conflict, message}} ->
        conn |> put_status(404) |> json(%{error: %{code: "ticket_not_found", message: message}})
    end
  end
end
