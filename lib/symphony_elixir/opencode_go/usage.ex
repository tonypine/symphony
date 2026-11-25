defmodule SymphonyElixir.OpencodeGo.Usage do
  @moduledoc """
  OpenCode Go's usage windows, read from its usage API (TP-1642):
  `GET https://opencode.ai/inference/go/v1/usage` with the Go key (`OPENCODE_API_KEY`) as a bearer
  token. It only reads: Symphony never changes the allowance.

  The answer has one meter per limit, `rolling` (5 hours), `weekly` and `monthly`, each with its
  `status` (`ok`, or `rate-limited` once used up), `percent` (0 to 100) and `resetsAt` (ISO 8601).
  `read/1` turns them into the windows Symphony keeps for Anthropic too
  (`SymphonyElixir.UsageLimit.remember_windows/3`, `headroom_crossings/4`): `five_hour`,
  `seven_day` and `monthly`, each `%{status:, utilization:, resets_at:}` with `utilization` from 0
  to 1 and `status` `allowed` or `rejected`. A meter the answer lacks or can't be read is left out.

  A key that is not set is `{:error, :no_key}`; no valid key is a 401 and a key Go doesn't cover a
  403 (`{:error, {:http_status, status}}`).

  QA reads it from `SymphonyElixir.OpenRouter.Stub` instead (`/api/opencode-go/v1/usage` on the
  stub's URL), only in QA mode (`SymphonyElixir.OpenRouter.qa_base_url/1`). Tests swap the HTTP
  call with the `:opencode_go_usage_request` app env or the `:request_fun` option (a
  `(url, req_options) -> {:ok, response} | {:error, reason}` function).
  """

  alias SymphonyElixir.{Config, OpenRouter, Secret}

  @provider "opencode-go"
  @url "https://opencode.ai/inference/go/v1/usage"
  @timeout_ms 10_000
  @meters [{"rolling", "five_hour"}, {"weekly", "seven_day"}, {"monthly", "monthly"}]

  @type window :: %{status: String.t(), utilization: float(), resets_at: DateTime.t()}
  @type windows :: %{optional(String.t()) => window()}

  @doc "The provider whose usage this reads."
  @spec provider() :: String.t()
  def provider, do: @provider

  @doc "The usage endpoint: the QA stub's in QA mode, else OpenCode Go's."
  @spec url(%{optional(String.t()) => String.t()}) :: String.t()
  def url(env \\ System.get_env()) do
    case OpenRouter.qa_base_url(env) do
      nil -> @url
      base -> base <> "/opencode-go/v1/usage"
    end
  end

  @doc """
  Reads OpenCode Go's usage windows with its key. Options: `:api_key` (default the configured
  key, `SymphonyElixir.Config.provider_api_key/1`), `:request_fun`, `:url`.
  """
  @spec read(keyword()) :: {:ok, windows()} | {:error, term()}
  def read(opts \\ []) do
    case Keyword.get_lazy(opts, :api_key, fn -> Config.provider_api_key(@provider) end) do
      nil ->
        {:error, :no_key}

      key ->
        request_fun = Keyword.get(opts, :request_fun) || Application.get_env(:symphony_elixir, :opencode_go_usage_request, &Req.get/2)

        req_options = [
          headers: [{"authorization", "Bearer " <> Secret.unwrap(key)}],
          receive_timeout: @timeout_ms,
          connect_options: [timeout: @timeout_ms],
          retry: false
        ]

        case safe_request(request_fun, Keyword.get_lazy(opts, :url, &url/0), req_options) do
          {:ok, %{status: 200, body: body}} -> parse(body)
          {:ok, %{status: status}} -> {:error, {:http_status, status}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "The windows in a usage answer (decoded or as JSON text); `{:error, :invalid_body}` when it holds none."
  @spec parse(term()) :: {:ok, windows()} | {:error, :invalid_body}
  def parse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse(decoded)
      {:error, _reason} -> {:error, :invalid_body}
    end
  end

  def parse(%{"usage" => %{} = usage}) do
    windows = for {meter, name} <- @meters, window = window(Map.get(usage, meter)), into: %{}, do: {name, window}
    if windows == %{}, do: {:error, :invalid_body}, else: {:ok, windows}
  end

  def parse(_body), do: {:error, :invalid_body}

  @doc "A short reason for a failed read, for the log."
  @spec format_reason(term()) :: String.t()
  def format_reason(:no_key), do: "#{SymphonyElixir.AgentProviders.api_key_env(@provider)} is not set"
  def format_reason({:http_status, 401}), do: "HTTP 401 (the key is not valid)"
  def format_reason({:http_status, 403}), do: "HTTP 403 (the key has no OpenCode Go subscription)"
  def format_reason({:http_status, status}), do: "HTTP #{status}"
  def format_reason(:invalid_body), do: "unexpected response body"
  def format_reason(%{__exception__: true} = exception), do: Exception.message(exception)
  def format_reason(reason), do: inspect(reason)

  defp window(%{"percent" => percent, "resetsAt" => resets_at} = meter) when is_number(percent) and is_binary(resets_at) do
    case DateTime.from_iso8601(resets_at) do
      {:ok, resets_at, _offset} ->
        %{status: status(Map.get(meter, "status")), utilization: min(max(percent / 100, 0.0), 1.0), resets_at: resets_at}

      {:error, _reason} ->
        nil
    end
  end

  defp window(_meter), do: nil

  # `ok` is still allowed; `rate-limited` (or a status Symphony doesn't know) is not.
  defp status("ok"), do: "allowed"
  defp status(_rate_limited), do: "rejected"

  defp safe_request(request_fun, url, req_options) do
    request_fun.(url, req_options)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
