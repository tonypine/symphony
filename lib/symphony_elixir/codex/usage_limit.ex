defmodule SymphonyElixir.Codex.UsageLimit do
  @moduledoc """
  Classifies a Codex usage-limit failure for the per-provider hold (`SymphonyElixir.UsageLimit`).

  The Codex app-server reports a used-up plan window as an error whose `codexErrorInfo` is
  `usageLimitExceeded`: on the `error` notification, on a failed `turn/completed`, or on
  `turn/failed`. Older servers send a `codex/event/error` whose message says the usage limit
  was hit. The rate-limit snapshots (`account/rateLimits/updated`, or `rate_limits` on the
  legacy `token_count` event) carry each window's `used_percent` and `resets_at`; the window
  at 100% or more names the window that ran out and when it resets.

  A throttle the server retries (`willRetry: true`), or any other error, is not a usage limit.

  An error that never got an answer from the model API (a DNS failure, a refused or dropped
  connection, a connect timeout) is an unreachable API (`api_unreachable/1`): its
  `codexErrorInfo` is `httpConnectionFailed` or `responseStreamConnectionFailed`, or its message
  names the transport error, and it carries no HTTP status. An error the API answered (a 429, a
  500) is not.
  """

  @provider "openai"
  @limit_methods ["error", "codex/event/error", "turn/completed", "turn/failed"]
  @limit_error_infos ["usagelimitexceeded", "usage_limit_exceeded"]
  @limit_text ~r/hit your usage limit/i
  @windows ["primary", "secondary"]
  @connection_error_infos ["httpconnectionfailed", "responsestreamconnectionfailed"]
  @transport_text ~r/error sending request|dns error|failed to lookup address|connection refused|connection reset|connection closed before|network is unreachable|connect(?:ion)? timed out|operation timed out|tcp connect error|\b(?:ENOTFOUND|EAI_AGAIN|ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENETUNREACH|EHOSTUNREACH|ENETDOWN)\b/i
  @error_code ~r/\b(E(?:NOTFOUND|AI_AGAIN|CONNREFUSED|CONNRESET|TIMEDOUT|NETUNREACH|HOSTUNREACH|NETDOWN))\b/
  @error_codes [
    {~r/dns error|failed to lookup address/i, "ENOTFOUND"},
    {~r/connection refused/i, "ECONNREFUSED"},
    {~r/connection reset|connection closed before/i, "ECONNRESET"},
    {~r/network is unreachable/i, "ENETUNREACH"},
    {~r/timed out/i, "ETIMEDOUT"}
  ]

  @typedoc "One Codex rate-limit window as last reported."
  @type window :: %{used_percent: number() | nil, resets_at: DateTime.t() | nil}

  @typedoc "The latest Codex rate-limit windows, by name (`primary`, `secondary`)."
  @type snapshot :: %{optional(String.t()) => window()}

  @typedoc "A Codex usage-limit hit, in the shape of the Claude parser's."
  @type info :: %{
          provider: String.t(),
          window: String.t() | nil,
          scope: :all,
          resets_at: DateTime.t() | nil,
          utilization: number() | nil,
          overage: nil,
          source: :codex_error
        }

  @typedoc "A model API Codex could not reach, in the shape of the Claude parser's."
  @type api_unreachable_info :: %{
          provider: String.t(),
          window: nil,
          scope: :all,
          resets_at: nil,
          utilization: nil,
          source: :api_unreachable,
          error: String.t()
        }

  @doc "The rate-limit windows in a Codex message, or nil when it carries none."
  @spec rate_limits(map()) :: snapshot() | nil
  def rate_limits(payload) when is_map(payload) do
    limits = map_at(payload, ["params", "rateLimits"]) || map_at(payload, ["params", "msg", "rate_limits"])

    windows =
      for name <- @windows, %{} = window <- [is_map(limits) && Map.get(limits, name)], into: %{} do
        {name, %{used_percent: number(window, ["usedPercent", "used_percent"]), resets_at: epoch(window, ["resetsAt", "resets_at"])}}
      end

    if map_size(windows) > 0, do: windows
  end

  @doc "Merges the windows of `payload` into `snapshot`; a window not reported keeps its last value."
  @spec remember(snapshot() | nil, map()) :: snapshot() | nil
  def remember(snapshot, payload) when is_map(payload) do
    case rate_limits(payload) do
      nil -> snapshot
      windows -> Map.merge(snapshot || %{}, windows)
    end
  end

  @doc """
  `{:ok, info}` when `payload` ends the turn on the Codex usage limit, timed from the used-up
  window in `snapshot` (the one that resets last when both are); otherwise `:error`.
  """
  @spec usage_limited(map(), snapshot() | nil) :: {:ok, info()} | :error
  def usage_limited(%{"method" => method, "params" => %{} = params}, snapshot) when method in @limit_methods do
    if Map.get(params, "willRetry") != true and limit_error?(error(params)) do
      {:ok, info(snapshot || %{})}
    else
      :error
    end
  end

  def usage_limited(_payload, _snapshot), do: :error

  @doc """
  `{:ok, info}` when `payload` ends the turn because the model API could not be reached, with
  the error code it names (`ENOTFOUND`, `ECONNREFUSED`, …, or `connection error`); otherwise
  `:error`.
  """
  @spec api_unreachable(map()) :: {:ok, api_unreachable_info()} | :error
  def api_unreachable(%{"method" => method, "params" => %{} = params}) when method in @limit_methods do
    with true <- Map.get(params, "willRetry") != true,
         %{} = error <- error(params),
         true <- unreachable_error?(error) do
      {:ok,
       %{
         provider: @provider,
         window: nil,
         scope: :all,
         resets_at: nil,
         utilization: nil,
         source: :api_unreachable,
         error: error_code(Map.get(error, "message"))
       }}
    else
      _reachable -> :error
    end
  end

  def api_unreachable(_payload), do: :error

  defp error(params) do
    Enum.find_value([params["error"], map_at(params, ["turn", "error"]), params["msg"]], &(is_map(&1) && &1))
  end

  defp limit_error?(%{} = error) do
    limit_error_info?(Map.get(error, "codexErrorInfo")) or limit_text?(Map.get(error, "message"))
  end

  defp limit_error?(_error), do: false

  defp limit_error_info?(info) when is_binary(info), do: String.downcase(info) in @limit_error_infos
  defp limit_error_info?(%{} = info), do: Enum.any?(Map.keys(info), &limit_error_info?/1)
  defp limit_error_info?(_info), do: false

  defp limit_text?(message) when is_binary(message), do: Regex.match?(@limit_text, message)
  defp limit_text?(_message), do: false

  defp unreachable_error?(error) do
    info = Map.get(error, "codexErrorInfo")

    is_nil(http_status(info)) and
      (connection_error_info?(info) or transport_text?(Map.get(error, "message")))
  end

  defp connection_error_info?(info) when is_binary(info), do: String.downcase(info) in @connection_error_infos
  defp connection_error_info?(%{} = info), do: Enum.any?(Map.keys(info), &connection_error_info?/1)
  defp connection_error_info?(_info), do: false

  defp http_status(%{} = info), do: Enum.find_value(Map.values(info), &(is_map(&1) && Map.get(&1, "httpStatusCode")))
  defp http_status(_info), do: nil

  defp transport_text?(message) when is_binary(message), do: Regex.match?(@transport_text, message)
  defp transport_text?(_message), do: false

  defp error_code(message) when is_binary(message) do
    case Regex.run(@error_code, message, capture: :all_but_first) do
      [code] -> code
      nil -> Enum.find_value(@error_codes, "connection error", fn {pattern, code} -> Regex.match?(pattern, message) && code end)
    end
  end

  defp error_code(_message), do: "connection error"

  defp info(snapshot) do
    used_up =
      snapshot
      |> Enum.filter(fn {_name, window} -> is_number(window.used_percent) and window.used_percent >= 100 end)
      |> Enum.max_by(fn {_name, window} -> reset_order(window.resets_at) end, fn -> nil end)

    {window, seen} =
      case used_up do
        {name, seen} -> {name, seen}
        nil -> {nil, %{used_percent: nil, resets_at: nil}}
      end

    %{
      provider: @provider,
      window: window,
      scope: :all,
      resets_at: seen.resets_at,
      utilization: seen.used_percent && seen.used_percent / 100,
      overage: nil,
      source: :codex_error
    }
  end

  defp reset_order(%DateTime{} = resets_at), do: DateTime.to_unix(resets_at)
  defp reset_order(nil), do: 0

  defp number(map, keys), do: Enum.find_value(keys, &(is_number(map[&1]) && map[&1]))

  defp epoch(map, keys) do
    with seconds when is_integer(seconds) and seconds > 0 <- Enum.find_value(keys, &(is_integer(map[&1]) && map[&1])),
         {:ok, resets_at} <- DateTime.from_unix(seconds) do
      resets_at
    else
      _missing -> nil
    end
  end

  defp map_at(payload, path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc), do: {:cont, Map.get(acc, key)}, else: {:halt, nil}
    end)
  end
end
