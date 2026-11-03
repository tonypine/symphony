defmodule SymphonyElixirWeb.LinearWebhookController do
  @moduledoc """
  Receives the deliveries of Linear's workspace webhook (through a relay), observes an `Issue`
  delivery into the ticket's record (`SymphonyElixir.TicketObservation.observe_delivery/2`) and
  counts each delivery with what that did in `SymphonyElixir.Linear.Webhook.Deliveries`. The
  observation is bounded in time and never changes the answer: an accepted delivery is answered 200
  whatever it did, so Linear never retries one the record could not take. Nothing dispatches from
  the record yet: a delivery that changes a record only asks for a poll of its repo at once, and
  the poll reads Linear. A `Comment` delivery that creates or edits a review brief on a ticket in
  `Plan Review` starts the capture of the plan's brief on its record
  (`SymphonyElixir.PlanBrief.observe_delivery/2`), in a task of its own. An `Issue` delivery that
  changes a parent's sub-issues (a child re-parented, filed, removed or moved to another state:
  `SymphonyElixir.Linear.Webhook.parent_ids/1`) reads those parents again into their records
  (`SymphonyElixir.TicketObservation.observe_parents/2`), in a task of its own too, since Linear
  sends that change to the child only.

  The `Linear-Signature` HMAC is the only authentication, so the route sits outside the
  same-origin and bearer-token pipelines. A rejected delivery is logged by its reason only, never
  with its payload or the secret.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.Linear.Webhook
  alias SymphonyElixir.Linear.Webhook.Deliveries
  alias SymphonyElixir.PlanBrief
  alias SymphonyElixir.TicketObservation
  alias SymphonyElixirWeb.Plugs.RawBodyReader

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, _params) do
    webhooks = Webhook.settings()

    if webhooks.enabled do
      handle_delivery(conn, webhooks)
    else
      error_response(conn, 404, "not_found", "Linear webhooks are off")
    end
  end

  defp handle_delivery(conn, webhooks) do
    # Plug.Parsers caches the raw body of a JSON delivery; any other content type leaves it
    # unread, and an empty body fails the signature check.
    body = RawBodyReader.raw_body(conn) || ""

    case Webhook.verify(body, conn.req_headers, secret: Webhook.secret(webhooks)) do
      :ok ->
        parsed = Webhook.parse(conn.body_params)
        observation = TicketObservation.observe_delivery(parsed, observation_opts())
        PlanBrief.observe_delivery(parsed)
        observe_parents(conn.body_params)
        Deliveries.accepted(conn.body_params, DateTime.utc_now(), observation)
        conn |> put_status(200) |> json(%{status: "accepted"})

      {:error, reason} ->
        Logger.warning("Rejected Linear webhook delivery reason=#{reason}")
        Deliveries.rejected(reason)
        error_response(conn, 401, "invalid_signature", "The webhook signature did not verify")
    end
  end

  defp observe_parents(delivery) do
    case Webhook.parent_ids(delivery) do
      [] -> :ok
      parent_ids -> start_observing_parents(parent_ids)
    end
  end

  defp start_observing_parents(parent_ids) do
    opts = Keyword.drop(observation_opts(), [:timeout_ms, :observe_fun])
    observe = fn -> TicketObservation.observe_parents(parent_ids, opts) end
    {:ok, _pid} = Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, observe)
    :ok
  end

  # Tests set the observation's options (its time bound, or an observation that fails) here.
  defp observation_opts, do: Application.get_env(:symphony_elixir, :linear_webhook_observation_opts, [])

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
