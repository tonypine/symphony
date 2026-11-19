defmodule SymphonyElixirWeb.TicketFactsController do
  @moduledoc """
  The facts the Conductor reads at a junction of a ticket's life (`SymphonyElixir.Conductor.Facts`):

      GET /api/v1/tickets/:issue_identifier/facts?junction=<name>

  answers the facts document, built only from what Symphony already holds on the ticket (its record
  and its events), shaped for `junction` (`after_coding`, `after_qa_fail`, `after_rework` or
  `before_merge`; optional). The identifier resolves through the ticket's record, by identifier in
  any case or by id: a ticket with none is 404, and a junction that is not one is 400. Like the
  other reads of `/api/v1`, it needs no token.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Conductor.Facts

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"issue_identifier" => identifier} = params) do
    case Facts.read(identifier, params["junction"], Map.get(conn.assigns, :conductor_facts, [])) do
      {:ok, facts} -> json(conn, facts)
      {:error, :not_found} -> error(conn, 404, "ticket_not_found", "Symphony keeps no record of #{identifier}")
      {:error, {:invalid, message}} -> error(conn, 400, "invalid_query", message)
    end
  end

  defp error(conn, status, code, message), do: conn |> put_status(status) |> json(%{error: %{code: code, message: message}})
end
