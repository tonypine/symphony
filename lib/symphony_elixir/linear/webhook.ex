defmodule SymphonyElixir.Linear.Webhook do
  @moduledoc """
  Verifies deliveries of Linear's workspace webhook (`linear.webhooks`, `docs/linear-webhooks.md`).

  A delivery is Linear's when its `Linear-Signature` header is the hex HMAC-SHA256 of the raw
  request body with the signing secret, and fresh when the body's `webhookTimestamp` (milliseconds
  since the epoch) is within sixty seconds of now, which keeps a captured delivery from being
  replayed later. `SymphonyElixirWeb.LinearWebhookController` checks each delivery with it.

  `parse/1` reads a verified delivery into Symphony's terms: an `Issue` delivery becomes the same
  `Linear.Issue` the poll builds for that ticket (`Linear.IssueNormalizer`), a `Comment` delivery the
  comment and its issue's id. Nothing acts on what it returns yet.
  """

  alias SymphonyElixir.{Config, Secret}
  alias SymphonyElixir.Config.Schema.Linear.Webhooks
  alias SymphonyElixir.Linear.{Issue, IssueNormalizer}

  @signature_header "linear-signature"
  @max_age_ms 60_000

  @typedoc "Why a delivery was refused."
  @type verify_error :: :missing_secret | :missing_signature | :bad_signature | :stale_timestamp

  @typedoc "Request headers, as Plug's `req_headers` list or a map; names match in any case."
  @type headers :: [{String.t(), String.t()}] | %{optional(String.t()) => String.t()}

  @typedoc "What Linear did to the entity a delivery is about."
  @type action :: :create | :update | :remove

  @typedoc """
  What a delivery says happened: an issue created or updated (with its `updatedAt`), an issue
  removed, a comment created, updated or removed on an issue, or something Symphony doesn't read.
  """
  @type parsed ::
          {:issue, :create | :update, Issue.t(), DateTime.t()}
          | {:issue_removed, String.t(), String.t() | nil}
          | {:comment, action(), String.t(), IssueNormalizer.comment()}
          | :ignored
          | {:error, :malformed}

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

  @doc """
  Reads a verified delivery, as its raw body or already decoded: `Issue` create and update give
  `{:issue, action, issue, updated_at}`, `Issue` remove `{:issue_removed, id, identifier}`,
  `Comment` `{:comment, action, issue_id, comment}`, and any other type, or an action Symphony
  doesn't know, `:ignored`. A body that isn't JSON, or an `Issue` or `Comment` without the ids and
  `updatedAt` those need, is `{:error, :malformed}`.
  """
  @spec parse(binary() | map()) :: parsed()
  def parse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = delivery} -> parse(delivery)
      _not_an_object -> {:error, :malformed}
    end
  end

  def parse(%{"type" => type, "action" => action, "data" => %{} = data}) when is_binary(type) and is_binary(action) do
    case {type, action(action)} do
      {_type, nil} -> :ignored
      {"Issue", action} -> parse_issue(action, data)
      {"Comment", action} -> parse_comment(action, data)
      _other_type -> :ignored
    end
  end

  def parse(%{"type" => type}) when is_binary(type) and type not in ["Issue", "Comment"], do: :ignored
  def parse(_delivery), do: {:error, :malformed}

  defp action("create"), do: :create
  defp action("update"), do: :update
  defp action("remove"), do: :remove
  defp action(_action), do: nil

  defp parse_issue(:remove, data) do
    case data do
      %{"id" => id} when is_binary(id) and id != "" -> {:issue_removed, id, string(data["identifier"])}
      _no_id -> {:error, :malformed}
    end
  end

  defp parse_issue(action, data) do
    case IssueNormalizer.from_webhook_data(data) do
      %Issue{id: id, identifier: identifier, updated_at: %DateTime{} = updated_at} = issue
      when is_binary(id) and id != "" and is_binary(identifier) and identifier != "" ->
        {:issue, action, issue, updated_at}

      _incomplete ->
        {:error, :malformed}
    end
  end

  defp parse_comment(action, data) do
    with issue_id when is_binary(issue_id) <- comment_issue_id(data),
         %{} = comment <- IssueNormalizer.comment_from_webhook_data(data) do
      {:comment, action, issue_id, comment}
    else
      _incomplete -> {:error, :malformed}
    end
  end

  defp comment_issue_id(%{"issueId" => id}) when is_binary(id) and id != "", do: id
  defp comment_issue_id(%{"issue" => %{"id" => id}}) when is_binary(id) and id != "", do: id
  defp comment_issue_id(_data), do: nil

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil
end
