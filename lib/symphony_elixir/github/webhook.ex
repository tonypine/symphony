defmodule SymphonyElixir.GitHub.Webhook do
  @moduledoc """
  Verifies and reads GitHub webhook deliveries for the PR and CI watcher.

  Symphony listens on 127.0.0.1, so deliveries reach it through a relay (smee.io, a Cloudflare
  tunnel or `gh webhook forward`). A delivery patches the facts the watcher keeps and asks it to
  read the PR now (`SymphonyElixir.PrWatch.Ingest`); only that read decides what happens, so
  webhooks and polling share one state machine.
  """

  alias SymphonyElixir.{Config, Paths, Secret}
  alias SymphonyElixir.Config.Schema.GitHub.Webhooks

  @signature_prefix "sha256="

  @type ci_event :: %{
          event: String.t(),
          action: String.t() | nil,
          head_sha: String.t() | nil,
          conclusion: String.t() | nil,
          completed_at: DateTime.t() | nil,
          pr_urls: [String.t()],
          merged: boolean(),
          base_ref: String.t() | nil
        }

  @typedoc "A push to a branch of `repo_url`: the branch and the commit it now points at."
  @type push :: %{repo_url: String.t(), ref: String.t(), head_sha: String.t() | nil}

  @typedoc "A release published on `repo` (`owner/name`): its tag and when it was published."
  @type release :: %{repo: String.t(), tag: String.t(), published_at: DateTime.t() | nil, prerelease: boolean()}

  @type delivery :: {:ci, ci_event()} | {:push, push()} | {:release, release()} | :ping | :ignored

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
  closed (`merged: true` when it closed by merging, which moves its base branch, `base_ref`),
  `{:push, push}` when a branch moved, `{:release, release}` when a release was published, `:ping`
  when GitHub (re)connected the hook, and `:ignored` for anything else, including event types left
  out of `github.webhooks.events`.
  """
  @spec parse(String.t() | nil, term(), [String.t()]) :: delivery()
  def parse("ping", _payload, _events), do: :ping

  def parse(event, %{} = payload, events) when is_binary(event) do
    if event in events, do: parse_event(event, payload), else: :ignored
  end

  def parse(_event, _payload, _events), do: :ignored

  defp parse_event(event, %{"action" => "completed"} = payload) when event in ["check_suite", "check_run", "workflow_run"] do
    case Map.get(payload, event) do
      %{} = subject ->
        ci_event(
          event,
          "completed",
          Map.get(subject, "head_sha"),
          Map.get(subject, "conclusion"),
          completed_at(subject),
          pr_urls(payload, Map.get(subject, "pull_requests"))
        )

      _other ->
        :ignored
    end
  end

  defp parse_event("pull_request", %{"action" => action, "pull_request" => %{} = pull_request})
       when action in ["synchronize", "closed", "reopened"] do
    head_sha = get_in(pull_request, ["head", "sha"])

    with {:ci, event} <- ci_event("pull_request", action, head_sha, nil, nil, string_list([Map.get(pull_request, "html_url")])) do
      {:ci, %{event | merged: action == "closed" and Map.get(pull_request, "merged") == true, base_ref: string(get_in(pull_request, ["base", "ref"]))}}
    end
  end

  # A branch that moved; a deleted branch or a tag names no base a PR could be on.
  defp parse_event("push", %{"ref" => "refs/heads/" <> branch, "repository" => %{"html_url" => repo_url}} = payload)
       when is_binary(repo_url) and branch != "" do
    if Map.get(payload, "deleted") == true, do: :ignored, else: {:push, %{repo_url: repo_url, ref: branch, head_sha: string(Map.get(payload, "after"))}}
  end

  defp parse_event("release", %{"action" => "published", "release" => %{"tag_name" => tag} = release, "repository" => %{"full_name" => repo}})
       when is_binary(tag) and tag != "" and is_binary(repo) do
    if Map.get(release, "draft") == true do
      :ignored
    else
      {:release, %{repo: repo, tag: tag, published_at: parse_datetime(Map.get(release, "published_at")), prerelease: Map.get(release, "prerelease") == true}}
    end
  end

  defp parse_event(_event, _payload), do: :ignored

  defp ci_event(_event, _action, head_sha, _conclusion, _completed_at, []) when not is_binary(head_sha), do: :ignored

  defp ci_event(event, action, head_sha, conclusion, completed_at, pr_urls) do
    {:ci,
     %{
       event: event,
       action: action,
       head_sha: if(is_binary(head_sha), do: head_sha),
       conclusion: normalize_id(conclusion),
       completed_at: completed_at,
       pr_urls: pr_urls,
       merged: false,
       base_ref: nil
     }}
  end

  defp completed_at(subject) do
    parse_datetime(Map.get(subject, "completed_at") || Map.get(subject, "updated_at"))
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_id(_value), do: nil

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

  @doc """
  The `repository.html_url` a delivery's payload names, or nil. Read before the signature is
  checked too, only to count a rejected delivery against its repository's health.
  """
  @spec repository_url(term()) :: String.t() | nil
  def repository_url(%{"repository" => %{"html_url" => url}}) when is_binary(url) and url != "", do: url
  def repository_url(_payload), do: nil

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil
end
