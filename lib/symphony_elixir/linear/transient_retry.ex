defmodule SymphonyElixir.Linear.TransientRetry do
  @moduledoc """
  Waits out transient Linear errors around a single tracker call.

  A rate limit (`{:linear_rate_limited, until_ms}`), a transport error such as a
  timeout or refused connection, and an HTTP 429 or 5xx answer say nothing about
  the issue: the same call succeeds once Linear is back. `run/2` retries such a
  call, waiting until the rate-limit pause ends or for a short, growing delay,
  within a bounded total wait. Any other error, and the last transient error once
  the wait budget is spent, is returned as it is.
  """

  alias SymphonyElixir.Linear.RateLimit

  @max_wait_ms 300_000
  @base_delay_ms 5_000
  @max_delay_ms 60_000
  @min_rate_limit_wait_ms 1_000

  @type result :: term()

  @doc """
  Whether a tracker error reason is a transient Linear failure worth retrying.
  """
  @spec transient?(term()) :: boolean()
  def transient?({:linear_rate_limited, until_ms}) when is_integer(until_ms), do: true
  def transient?({:linear_api_request, reason}), do: is_exception(reason)
  def transient?({:linear_api_status, status, _body}) when is_integer(status), do: status == 429 or status >= 500
  def transient?(_reason), do: false

  @doc """
  How long to wait before retrying after `reason`: until the rate-limit pause
  ends, otherwise a delay that doubles from 5 s up to 60 s with each attempt.
  """
  @spec delay_ms(term(), integer(), pos_integer()) :: pos_integer()
  def delay_ms({:linear_rate_limited, until_ms}, now_ms, _attempt), do: max(until_ms - now_ms, @min_rate_limit_wait_ms)
  def delay_ms(_reason, _now_ms, attempt), do: min(@base_delay_ms * Integer.pow(2, min(attempt - 1, 4)), @max_delay_ms)

  @doc """
  Calls `fun` and retries it while it returns a transient `{:error, reason}`.

  Options:

    * `:max_wait_ms` - total time to spend waiting (default 5 minutes)
    * `:sleep_fun` - `fn delay_ms -> any end` (default `Process.sleep/1`)
    * `:now_ms_fun` - `fn -> now_ms end` (default `RateLimit.now_ms/0`)
    * `:on_wait` - `fn reason, delay_ms -> any end`, called before each wait
  """
  @spec run((-> result()), keyword()) :: result()
  def run(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    now_ms_fun = Keyword.get(opts, :now_ms_fun, &RateLimit.now_ms/0)
    deadline_ms = now_ms_fun.() + Keyword.get(opts, :max_wait_ms, @max_wait_ms)

    config = %{
      sleep_fun: Keyword.get(opts, :sleep_fun, &Process.sleep/1),
      now_ms_fun: now_ms_fun,
      on_wait: Keyword.get(opts, :on_wait, fn _reason, _delay_ms -> :ok end),
      deadline_ms: deadline_ms
    }

    attempt(fun, config, 1)
  end

  defp attempt(fun, config, attempt) do
    case fun.() do
      {:error, reason} = error ->
        now_ms = config.now_ms_fun.()
        remaining_ms = config.deadline_ms - now_ms

        if transient?(reason) and remaining_ms > 0 do
          delay_ms = min(delay_ms(reason, now_ms, attempt), remaining_ms)
          config.on_wait.(reason, delay_ms)
          config.sleep_fun.(delay_ms)
          attempt(fun, config, attempt + 1)
        else
          error
        end

      result ->
        result
    end
  end
end
