defmodule SymphonyElixir.GitHub.Webhook do
  @moduledoc """
  Verifies and reads GitHub webhook deliveries for the CI poller.

  Symphony listens on 127.0.0.1, so deliveries reach it through a relay (smee.io, a Cloudflare
  tunnel or `gh webhook forward`). A delivery only tells the CI poller which pull request to poll
  now; the poll itself decides what happens, so webhooks and polling share one state machine.
  """

  alias SymphonyElixir.{Config, Paths, Secret}
  alias SymphonyElixir.Config.Schema.GitHub.Webhooks

  @signature_prefix "sha256="

  @type ci_event :: %{
          event: String.t(),
          action: String.t() | nil,
          head_sha: String.t() | nil,
          pr_urls: [String.t()]
        }

  @type delivery :: {:ci, ci_event()} | :ping | :ignored

  @doc "The `github.webhooks` settings, or the defaults (off) when the config can't be read."
  @spec settings() :: Webhooks.t()
  def settings do
    case Config.settings() do
      {:ok, settings} -> settings.github.webhooks
      {:error, _reason} -> %Webhooks{}
    end
  end

  @doc """
  The shared secret: `github.webhooks.secret` (usually `$GITHUB_WEBHOOK_SECRET`), else the
  contents of `<state-root>/github_webhook_secret`, else nil.
  """
  @spec secret(Webhooks.t()) :: Secret.t() | nil
  def secret(%Webhooks{secret: secret}) do
    if Secret.present?(secret), do: Secret.wrap(secret), else: secret_from_file()
  end

  defp secret_from_file do
    case File.read(Paths.github_webhook_secret_file()) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> nil
          value -> Secret.wrap(value)
        end

      {:error, _reason} ->
        nil
    end
  end

  @doc "Checks `X-Hub-Signature-256` against an HMAC-SHA256 of the raw request body."
  @type verify_error :: :no_secret | :missing_signature | :bad_signature

  @spec verify(binary(), String.t() | nil, Secret.t() | nil) :: :ok | {:error, verify_error()}
  def verify(_body, _signature, nil), do: {:error, :no_secret}
  def verify(_body, signature, _secret) when signature in [nil, ""], do: {:error, :missing_signature}

  def verify(body, @signature_prefix <> signature, secret) when is_binary(body) do
    expected = :hmac |> :crypto.mac(:sha256, Secret.unwrap(secret), body) |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)), do: :ok, else: {:error, :bad_signature}
  end

  def verify(_body, _signature, _secret), do: {:error, :bad_signature}

  @doc """
  Reads a delivery: `{:ci, event}` when a check finished or a pull request's head changed or
  closed, `:ping` when GitHub (re)connected the hook, and `:ignored` for anything else,
  including event types left out of `github.webhooks.events`.
  """
  @spec parse(String.t() | nil, term(), [String.t()]) :: delivery()
  def parse("ping", _payload, _events), do: :ping

  def parse(event, %{} = payload, events) when is_binary(event) do
    if event in events, do: parse_event(event, payload), else: :ignored
  end

  def parse(_event, _payload, _events), do: :ignored

  defp parse_event(event, %{"action" => "completed"} = payload) when event in ["check_suite", "check_run", "workflow_run"] do
    case Map.get(payload, event) do
      %{} = subject -> ci_event(event, "completed", Map.get(subject, "head_sha"), pr_urls(payload, Map.get(subject, "pull_requests")))
      _other -> :ignored
    end
  end

  defp parse_event("pull_request", %{"action" => action, "pull_request" => %{} = pull_request})
       when action in ["synchronize", "closed", "reopened"] do
    head_sha = get_in(pull_request, ["head", "sha"])
    ci_event("pull_request", action, head_sha, string_list([Map.get(pull_request, "html_url")]))
  end

  defp parse_event(_event, _payload), do: :ignored

  defp ci_event(_event, _action, head_sha, []) when not is_binary(head_sha), do: :ignored

  defp ci_event(event, action, head_sha, pr_urls) do
    {:ci, %{event: event, action: action, head_sha: if(is_binary(head_sha), do: head_sha), pr_urls: pr_urls}}
  end

  defp pr_urls(%{"repository" => %{"html_url" => repo_url}}, pull_requests) when is_binary(repo_url) and is_list(pull_requests) do
    pull_requests
    |> Enum.map(fn
      %{"number" => number} when is_integer(number) -> "#{repo_url}/pull/#{number}"
      _other -> nil
    end)
    |> string_list()
  end

  defp pr_urls(_payload, _pull_requests), do: []

  defp string_list(values), do: Enum.filter(values, &(is_binary(&1) and &1 != ""))

  @doc "True when the event names this CI record's PR or its last observed head."
  @spec matches_record?(ci_event(), map()) :: boolean()
  def matches_record?(%{pr_urls: pr_urls, head_sha: head_sha}, record) when is_map(record) do
    pr_url = normalize_url(Map.get(record, :pr_url))
    shas = [Map.get(record, :last_observed_sha), Map.get(record, :commit_sha)]

    (is_binary(pr_url) and Enum.any?(pr_urls, &(normalize_url(&1) == pr_url))) or
      (is_binary(head_sha) and head_sha in shas)
  end

  defp normalize_url(url) when is_binary(url), do: url |> String.trim() |> String.trim_trailing("/") |> String.downcase()
  defp normalize_url(_url), do: nil
end
