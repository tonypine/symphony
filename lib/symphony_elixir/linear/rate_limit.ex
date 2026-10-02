defmodule SymphonyElixir.Linear.RateLimit do
  @moduledoc """
  Process-wide Linear API rate-limit gate.

  Every Linear request goes through `SymphonyElixir.Linear.Client.graphql/3`,
  which asks `check/1` before sending and hands each response to
  `record_response/2`. Once Linear answers `RATELIMITED` (or HTTP 429), all
  Linear traffic pauses until the reset time Linear reports in its
  `x-ratelimit-*-reset` headers, so polling, retries, and agent tools stop
  draining the hourly budget while it is already spent.

  State lives in an `:atomics` array so reads and counter bumps stay cheap on
  the request path.
  """

  @key {__MODULE__, :atomics}
  @requests_index 1
  @paused_until_index 2
  @remaining_index 3
  @limit_index 4
  @slots 4
  @unknown -1
  @default_pause_ms 60_000
  @max_pause_ms 3_600_000
  @reset_buckets ["requests", "complexity"]

  @type status :: %{
          paused_until_ms: integer() | nil,
          requests_total: non_neg_integer(),
          requests_remaining: integer() | nil,
          requests_limit: integer() | nil
        }

  @spec now_ms() :: integer()
  def now_ms, do: System.system_time(:millisecond)

  @spec check(integer()) :: :ok | {:error, {:linear_rate_limited, integer()}}
  def check(now_ms) when is_integer(now_ms) do
    case paused_until(now_ms) do
      nil -> :ok
      reset_ms -> {:error, {:linear_rate_limited, reset_ms}}
    end
  end

  @spec paused_until(integer()) :: integer() | nil
  def paused_until(now_ms \\ now_ms()) when is_integer(now_ms) do
    reset_ms = :atomics.get(ref(), @paused_until_index)
    if reset_ms > now_ms, do: reset_ms, else: nil
  end

  @spec remaining_pause_ms(integer()) :: non_neg_integer()
  def remaining_pause_ms(now_ms \\ now_ms()) when is_integer(now_ms) do
    case paused_until(now_ms) do
      nil -> 0
      reset_ms -> reset_ms - now_ms
    end
  end

  @spec record_request() :: :ok
  def record_request, do: :atomics.add(ref(), @requests_index, 1)

  @spec requests_total() :: non_neg_integer()
  def requests_total, do: :atomics.get(ref(), @requests_index)

  @spec record_response(map(), integer()) :: :ok | {:rate_limited, integer()}
  def record_response(response, now_ms) when is_map(response) and is_integer(now_ms) do
    headers = normalize_headers(Map.get(response, :headers))
    put_header_value(headers, "x-ratelimit-requests-remaining", @remaining_index)
    put_header_value(headers, "x-ratelimit-requests-limit", @limit_index)

    if rate_limited?(response) do
      reset_ms = pause_until(headers, now_ms)
      :atomics.put(ref(), @paused_until_index, reset_ms)
      {:rate_limited, reset_ms}
    else
      :ok
    end
  end

  @spec status(integer()) :: status()
  def status(now_ms \\ now_ms()) when is_integer(now_ms) do
    %{
      paused_until_ms: paused_until(now_ms),
      requests_total: requests_total(),
      requests_remaining: known(:atomics.get(ref(), @remaining_index)),
      requests_limit: known(:atomics.get(ref(), @limit_index))
    }
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    _ = :persistent_term.erase(@key)
    :ok
  end

  defp ref do
    case :persistent_term.get(@key, nil) do
      nil ->
        ref = :atomics.new(@slots, signed: true)
        :atomics.put(ref, @remaining_index, @unknown)
        :atomics.put(ref, @limit_index, @unknown)
        :persistent_term.put(@key, ref)
        ref

      ref ->
        ref
    end
  end

  defp known(@unknown), do: nil
  defp known(value), do: value

  defp rate_limited?(%{status: 429}), do: true
  defp rate_limited?(%{body: %{"errors" => errors}}) when is_list(errors), do: Enum.any?(errors, &rate_limited_error?/1)
  defp rate_limited?(_response), do: false

  defp rate_limited_error?(%{"extensions" => %{"code" => "RATELIMITED"}}), do: true
  defp rate_limited_error?(_error), do: false

  # Prefer the reset of a bucket Linear reports as spent; otherwise wait for
  # the latest reset it reported, and fall back to a fixed pause without headers.
  defp pause_until(headers, now_ms) do
    buckets =
      for bucket <- @reset_buckets,
          reset_ms = header_integer(headers, "x-ratelimit-#{bucket}-reset"),
          is_integer(reset_ms) and reset_ms > now_ms,
          do: {header_integer(headers, "x-ratelimit-#{bucket}-remaining"), reset_ms}

    spent = for {remaining, reset_ms} <- buckets, is_integer(remaining) and remaining <= 0, do: reset_ms

    resets = if spent == [], do: Enum.map(buckets, &elem(&1, 1)), else: spent

    case resets do
      [] -> now_ms + @default_pause_ms
      resets -> min(Enum.max(resets), now_ms + @max_pause_ms)
    end
  end

  defp put_header_value(headers, name, index) do
    case header_integer(headers, name) do
      nil -> :ok
      value -> :atomics.put(ref(), index, value)
    end
  end

  defp normalize_headers(headers) when is_map(headers) or is_list(headers) do
    Map.new(headers, fn {name, value} -> {String.downcase(to_string(name)), header_value(value)} end)
  end

  defp normalize_headers(_headers), do: %{}

  defp header_value([value | _rest]), do: value
  defp header_value(value), do: value

  defp header_integer(headers, name) do
    with value when is_binary(value) <- Map.get(headers, name),
         {integer, ""} <- Integer.parse(String.trim(value)) do
      integer
    else
      _ -> nil
    end
  end
end
