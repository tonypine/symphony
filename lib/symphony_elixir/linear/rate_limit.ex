defmodule SymphonyElixir.Linear.RateLimit do
  @moduledoc """
  Process-wide Linear API rate-limit gate.

  Every Linear request goes through `SymphonyElixir.Linear.Client.graphql/3`,
  which asks `check/1` before sending and hands each response to
  `record_response/3`. Once Linear answers `RATELIMITED` (or HTTP 429), all
  Linear traffic pauses for a short backoff interval (one minute, doubling on
  each consecutive rate limit up to five minutes). When the pause ends, one
  request goes through as a probe: if Linear accepts it, traffic resumes; if it
  is rate-limited again, the next interval starts.

  Linear's limit is a rolling hour, so its `x-ratelimit-*-reset` headers read
  about an hour ahead while the budget is spent even though capacity refills
  within minutes. The reset is kept for display only.

  Below 10% of the hourly limit, `poll_interval_multiplier/0` asks the
  orchestrator to stretch its issue-poll interval so Symphony rarely reaches
  zero in the first place.

  State lives in an `:atomics` array so reads and counter bumps stay cheap on
  the request path.
  """

  @key {__MODULE__, :atomics}
  @requests_index 1
  @paused_until_index 2
  @remaining_index 3
  @limit_index 4
  @backoff_index 5
  @window_reset_index 6
  @slots 6
  @unknown -1
  @initial_backoff_ms 60_000
  @max_backoff_ms 300_000
  # Long enough for a probe request to finish; if the probe never answers
  # (transport error, crash), the next caller probes once the lease runs out.
  @probe_lease_ms 30_000
  @reset_buckets ["requests", "complexity"]

  @type status :: %{
          paused_until_ms: integer() | nil,
          backoff_ms: non_neg_integer(),
          window_reset_ms: integer() | nil,
          requests_total: non_neg_integer(),
          requests_remaining: integer() | nil,
          requests_limit: integer() | nil,
          poll_interval_multiplier: pos_integer()
        }

  @spec now_ms() :: integer()
  def now_ms, do: System.system_time(:millisecond)

  @doc """
  Returns `:ok` when Linear is not rate-limiting us, `:probe` when the caller
  should send the single probe request after a pause, and an error while paused.
  """
  @spec check(integer()) :: :ok | :probe | {:error, {:linear_rate_limited, integer()}}
  def check(now_ms) when is_integer(now_ms) do
    ref = ref()

    case :atomics.get(ref, @paused_until_index) do
      0 ->
        :ok

      paused_until_ms when paused_until_ms > now_ms ->
        {:error, {:linear_rate_limited, paused_until_ms}}

      paused_until_ms ->
        claim_probe(ref, paused_until_ms, now_ms)
    end
  end

  @doc false
  @spec claim_probe_for_test(integer(), integer()) :: :ok | :probe | {:error, {:linear_rate_limited, integer()}}
  def claim_probe_for_test(observed_paused_until_ms, now_ms), do: claim_probe(ref(), observed_paused_until_ms, now_ms)

  @spec paused_until(integer()) :: integer() | nil
  def paused_until(now_ms \\ now_ms()) when is_integer(now_ms) do
    paused_until_ms = :atomics.get(ref(), @paused_until_index)
    if paused_until_ms > now_ms, do: paused_until_ms, else: nil
  end

  @spec remaining_pause_ms(integer()) :: non_neg_integer()
  def remaining_pause_ms(now_ms \\ now_ms()) when is_integer(now_ms) do
    case paused_until(now_ms) do
      nil -> 0
      paused_until_ms -> paused_until_ms - now_ms
    end
  end

  @spec record_request() :: :ok
  def record_request, do: :atomics.add(ref(), @requests_index, 1)

  @spec requests_total() :: non_neg_integer()
  def requests_total, do: :atomics.get(ref(), @requests_index)

  @doc """
  Records a Linear response. `probe?` marks the request `check/1` let through
  after a pause: its outcome decides whether traffic resumes (`:resumed`) or the
  next, longer pause starts.
  """
  @spec record_response(map(), integer(), boolean()) :: :ok | :resumed | {:rate_limited, integer()}
  def record_response(response, now_ms, probe? \\ false)
      when is_map(response) and is_integer(now_ms) and is_boolean(probe?) do
    headers = normalize_headers(Map.get(response, :headers))
    put_header_value(headers, "x-ratelimit-requests-remaining", @remaining_index)
    put_header_value(headers, "x-ratelimit-requests-limit", @limit_index)

    cond do
      rate_limited?(response) -> {:rate_limited, pause(headers, now_ms, probe?)}
      probe? -> resume()
      true -> :ok
    end
  end

  @doc """
  How much to stretch the issue-poll interval: 4x below 5% of the hourly
  limit, 2x below 10%, otherwise 1x (also while the budget is unknown).
  """
  @spec poll_interval_multiplier() :: pos_integer()
  def poll_interval_multiplier do
    ref = ref()
    poll_interval_multiplier(:atomics.get(ref, @remaining_index), :atomics.get(ref, @limit_index))
  end

  @spec status(integer()) :: status()
  def status(now_ms \\ now_ms()) when is_integer(now_ms) do
    ref = ref()

    %{
      paused_until_ms: paused_until(now_ms),
      backoff_ms: :atomics.get(ref, @backoff_index),
      window_reset_ms: known(:atomics.get(ref, @window_reset_index)),
      requests_total: requests_total(),
      requests_remaining: known(:atomics.get(ref, @remaining_index)),
      requests_limit: known(:atomics.get(ref, @limit_index)),
      poll_interval_multiplier: poll_interval_multiplier()
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

        for index <- [@remaining_index, @limit_index, @window_reset_index] do
          :atomics.put(ref, index, @unknown)
        end

        :persistent_term.put(@key, ref)
        ref

      ref ->
        ref
    end
  end

  # Hold back everyone else for the probe's lease; a caller that loses the
  # race re-reads the new value and is refused.
  defp claim_probe(ref, observed_paused_until_ms, now_ms) do
    case :atomics.compare_exchange(ref, @paused_until_index, observed_paused_until_ms, now_ms + @probe_lease_ms) do
      :ok -> :probe
      _changed -> check(now_ms)
    end
  end

  # A probe that is rate-limited again doubles the pause. A first rate limit
  # starts at the initial interval; a straggler that was already in flight
  # when another request triggered the pause keeps the pause as it is.
  defp pause(headers, now_ms, probe?) do
    ref = ref()
    :atomics.put(ref, @window_reset_index, window_reset(headers, now_ms))

    case {probe?, paused_until(now_ms)} do
      {false, paused_until_ms} when is_integer(paused_until_ms) ->
        paused_until_ms

      _ ->
        backoff_ms = next_backoff_ms(:atomics.get(ref, @backoff_index))
        :atomics.put(ref, @backoff_index, backoff_ms)
        :atomics.put(ref, @paused_until_index, now_ms + backoff_ms)
        now_ms + backoff_ms
    end
  end

  defp resume do
    ref = ref()
    :atomics.put(ref, @paused_until_index, 0)
    :atomics.put(ref, @backoff_index, 0)
    :atomics.put(ref, @window_reset_index, @unknown)
    :resumed
  end

  defp next_backoff_ms(0), do: @initial_backoff_ms
  defp next_backoff_ms(backoff_ms), do: min(backoff_ms * 2, @max_backoff_ms)

  defp poll_interval_multiplier(remaining, limit) when remaining >= 0 and limit > 0 do
    cond do
      remaining * 20 < limit -> 4
      remaining * 10 < limit -> 2
      true -> 1
    end
  end

  defp poll_interval_multiplier(_remaining, _limit), do: 1

  defp known(@unknown), do: nil
  defp known(value), do: value

  defp rate_limited?(%{status: 429}), do: true
  defp rate_limited?(%{body: %{"errors" => errors}}) when is_list(errors), do: Enum.any?(errors, &rate_limited_error?/1)
  defp rate_limited?(_response), do: false

  defp rate_limited_error?(%{"extensions" => %{"code" => "RATELIMITED"}}), do: true
  defp rate_limited_error?(_error), do: false

  # For display: when the bucket Linear reports as spent fully resets, else the
  # latest reset it reported.
  defp window_reset(headers, now_ms) do
    buckets =
      for bucket <- @reset_buckets,
          reset_ms = header_integer(headers, "x-ratelimit-#{bucket}-reset"),
          is_integer(reset_ms) and reset_ms > now_ms,
          do: {header_integer(headers, "x-ratelimit-#{bucket}-remaining"), reset_ms}

    spent = for {remaining, reset_ms} <- buckets, is_integer(remaining) and remaining <= 0, do: reset_ms
    resets = if spent == [], do: Enum.map(buckets, &elem(&1, 1)), else: spent

    case resets do
      [] -> @unknown
      resets -> Enum.max(resets)
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
