defmodule SymphonyElixirWeb.GitHubWebhookController do
  @moduledoc """
  Receives GitHub webhook deliveries (through a relay) and hands them to the CI poller.

  The `X-Hub-Signature-256` HMAC is the only authentication, so the route sits outside the
  same-origin and bearer-token pipelines. A rejected delivery is logged by delivery id, event and
  reason only, never with its payload or the secret.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.CiPoller
  alias SymphonyElixir.GitHub.Webhook
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.Plugs.RawBodyReader

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, _params) do
    webhooks = Webhook.settings()

    if webhooks.enabled do
      handle_delivery(conn, webhooks)
    else
      error_response(conn, 404, "not_found", "GitHub webhooks are off")
    end
  end

  defp handle_delivery(conn, webhooks) do
    event = header(conn, "x-github-event")

    case Webhook.verify(raw_body(conn), header(conn, "x-hub-signature-256"), Webhook.secret(webhooks)) do
      :ok ->
        deliver(conn, Webhook.parse(event, payload(conn), webhooks.events))

      {:error, reason} ->
        Logger.warning("Rejected GitHub webhook delivery=#{log_value(header(conn, "x-github-delivery"))} event=#{log_value(event)} reason=#{reason}")
        _ = CiPoller.webhook_delivery({:rejected, reason}, ci_poller())
        error_response(conn, 401, "invalid_signature", "The webhook signature did not verify")
    end
  end

  defp deliver(conn, delivery) do
    case CiPoller.webhook_delivery(delivery, ci_poller()) do
      :ok -> conn |> put_status(202) |> json(%{status: delivery_status(delivery)})
      :unavailable -> error_response(conn, 503, "ci_poller_unavailable", "The CI poller is not running")
    end
  end

  defp delivery_status({:ci, _event}), do: "accepted"
  defp delivery_status(:ping), do: "catching_up"
  defp delivery_status(:ignored), do: "ignored"

  # Plug.Parsers caches the raw body of the JSON and form deliveries GitHub sends. Any other
  # content type leaves it unread, and an empty body fails the signature check.
  defp raw_body(conn), do: RawBodyReader.raw_body(conn) || ""

  # GitHub sends JSON, or a form with the JSON in `payload` when the hook's content type is
  # `application/x-www-form-urlencoded`.
  defp payload(%Conn{body_params: %{"payload" => payload}}) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  defp payload(%Conn{body_params: %{} = params}), do: params

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp log_value(value) when is_binary(value), do: value |> String.slice(0, 64) |> inspect()
  defp log_value(_value), do: "nil"

  defp ci_poller, do: Endpoint.config(:ci_poller) || CiPoller

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
