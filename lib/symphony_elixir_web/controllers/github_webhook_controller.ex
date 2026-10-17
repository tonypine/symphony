defmodule SymphonyElixirWeb.GitHubWebhookController do
  @moduledoc """
  Receives GitHub webhook deliveries (through a relay) and hands them to the PR and CI watcher
  (`SymphonyElixir.PrWatch.Ingest`).

  The `X-Hub-Signature-256` HMAC is the only authentication, so the route sits outside the
  same-origin and bearer-token pipelines. A rejected delivery is logged by delivery id, event and
  reason only, never with its payload or the secret.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.GitHub.{Webhook, WebhookSetup}
  alias SymphonyElixir.PrWatch.Ingest
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

    payload = payload(conn)

    case Webhook.verify(raw_body(conn), header(conn, "x-hub-signature-256"), Webhook.secret(webhooks)) do
      :ok ->
        repo_url = Webhook.repository_url(payload)
        WebhookSetup.delivered(repo_url, Endpoint.config(:github_updates) || [])
        deliver(conn, Webhook.parse(event, payload, webhooks.events), repo_url)

      {:error, reason} ->
        Logger.warning("Rejected GitHub webhook delivery=#{log_value(header(conn, "x-github-delivery"))} event=#{log_value(event)} reason=#{reason}")
        _ = Ingest.reject(reason, Webhook.repository_url(payload), ingest_opts())
        error_response(conn, 401, "invalid_signature", "The webhook signature did not verify")
    end
  end

  defp deliver(conn, delivery, repo_url) do
    case Ingest.deliver(delivery, repo_url, ingest_opts()) do
      :ok -> conn |> put_status(202) |> json(%{status: delivery_status(delivery)})
      :unavailable -> error_response(conn, 503, "pr_watch_unavailable", "The PR watcher is not running")
    end
  end

  defp delivery_status(:ping), do: "catching_up"
  defp delivery_status(:ignored), do: "ignored"
  defp delivery_status(_delivery), do: "accepted"

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

  # The watchers to hand deliveries to: every running one, unless the endpoint names them (tests).
  defp ingest_opts do
    case Endpoint.config(:pr_watchers) do
      watchers when is_list(watchers) -> [watchers: watchers]
      nil -> []
    end
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
