defmodule SymphonyElixir.Reports.Anthropic do
  @moduledoc """
  One turn of a report run against the Anthropic Messages API: the conversation so far and the run's
  tools in, the model's content blocks out (`text` and `tool_use`). The model is made to call a tool
  on every turn (`tool_choice: any`), so the run ends by its tools, never by prose. The API key is
  read from `ANTHROPIC_API_KEY`, as the issue gate's and the learnings' are; a test passes
  `request_fun` instead of the network.
  """

  alias SymphonyElixir.Secret

  @endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @max_tokens 4_096
  @timeout_ms 120_000

  @type request :: %{system: String.t(), messages: [map()], tools: [map()], model: String.t()}

  @doc """
  The model's content blocks for `request`, or the error: no key, the request failed, or the API
  answered another status than 200. `opts`: `request_fun` (`(payload, headers, timeout) -> {:ok,
  %{status, body}} | {:error, reason}`) and `api_key`.
  """
  @spec turn(request(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def turn(%{system: system, messages: messages, tools: tools, model: model}, opts \\ []) do
    with {:ok, key} <- api_key(opts) do
      payload = %{
        "model" => model,
        "max_tokens" => @max_tokens,
        "system" => system,
        "messages" => messages,
        "tools" => tools,
        "tool_choice" => %{"type" => "any"}
      }

      headers = [{"x-api-key", Secret.unwrap(key)}, {"anthropic-version", @anthropic_version}, {"content-type", "application/json"}]

      case Keyword.get(opts, :request_fun, &post/3).(payload, headers, @timeout_ms) do
        {:ok, %{status: 200, body: %{"content" => content}}} when is_list(content) -> {:ok, content}
        {:ok, %{status: status, body: body}} -> {:error, {:provider_http_status, status, body}}
        {:error, reason} -> {:error, {:provider_request_failed, reason}}
      end
    end
  end

  defp api_key(opts) do
    case Keyword.get_lazy(opts, :api_key, fn -> System.get_env("ANTHROPIC_API_KEY") end) do
      key when is_binary(key) and key != "" -> {:ok, Secret.wrap(key)}
      _missing -> {:error, :missing_anthropic_api_key}
    end
  end

  defp post(payload, headers, timeout_ms) do
    Req.post(@endpoint, headers: headers, json: payload, receive_timeout: timeout_ms, connect_options: [timeout: timeout_ms])
  end
end
