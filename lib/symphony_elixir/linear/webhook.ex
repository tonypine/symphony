defmodule SymphonyElixir.Linear.Webhook do
  @moduledoc """
  Verifies deliveries of Linear's workspace webhook (`linear.webhooks`, `docs/linear-webhooks.md`).

  A delivery is Linear's when its `Linear-Signature` header is the hex HMAC-SHA256 of the raw
  request body with the signing secret, and fresh when the body's `webhookTimestamp` (milliseconds
  since the epoch) is within sixty seconds of now, which keeps a captured delivery from being
  replayed later. Nothing listens for deliveries yet; this module only decides whether one is
  genuine.
  """

  alias SymphonyElixir.{Config, Secret}
  alias SymphonyElixir.Config.Schema.Linear.Webhooks

  @signature_header "linear-signature"
  @max_age_ms 60_000

  @typedoc "Why a delivery was refused."
  @type verify_error :: :missing_secret | :missing_signature | :bad_signature | :stale_timestamp

  @typedoc "Request headers, as Plug's `req_headers` list or a map; names match in any case."
  @type headers :: [{String.t(), String.t()}] | %{optional(String.t()) => String.t()}

  @doc "The `linear.webhooks` settings, or the defaults (off) when the config can't be read."
  @spec settings() :: Webhooks.t()
  def settings, do: Config.linear_webhook_settings()

  @doc "The signing secret `linear.webhooks.secret` resolves to, or nil when it resolves to nothing."
  @spec secret(Webhooks.t()) :: Secret.t() | nil
  def secret(%Webhooks{secret: secret}), do: if(Secret.present?(secret), do: Secret.wrap(secret))

  @doc """
  Checks a delivery: its raw `body`, its request `headers` and, in `opts`, the `secret` (default:
  the configured one) and `now` (a `DateTime`, default: the current time). Checked in order: a
  secret, a signature, the signature, then the timestamp; a body without a readable
  `webhookTimestamp` is stale, since nothing shows it is fresh.
  """
  @spec verify(binary(), headers(), keyword()) :: :ok | {:error, verify_error()}
  def verify(body, headers, opts \\ []) when is_binary(body) do
    secret = Keyword.get_lazy(opts, :secret, fn -> secret(settings()) end)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, secret} <- present_secret(secret),
         {:ok, signature} <- signature(headers),
         :ok <- check_signature(body, signature, secret) do
      check_timestamp(body, now)
    end
  end

  defp present_secret(secret) do
    if Secret.present?(secret), do: {:ok, secret}, else: {:error, :missing_secret}
  end

  defp signature(headers) do
    value =
      Enum.find_value(headers, fn {name, value} ->
        if String.downcase(to_string(name)) == @signature_header, do: value
      end)

    case value && String.trim(value) do
      signature when is_binary(signature) and signature != "" -> {:ok, signature}
      _missing -> {:error, :missing_signature}
    end
  end

  defp check_signature(body, signature, secret) do
    expected = :hmac |> :crypto.mac(:sha256, Secret.unwrap(secret), body) |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)), do: :ok, else: {:error, :bad_signature}
  end

  defp check_timestamp(body, now) do
    with {:ok, %{"webhookTimestamp" => timestamp}} when is_integer(timestamp) <- Jason.decode(body),
         true <- abs(DateTime.to_unix(now, :millisecond) - timestamp) <= @max_age_ms do
      :ok
    else
      _stale -> {:error, :stale_timestamp}
    end
  end
end
