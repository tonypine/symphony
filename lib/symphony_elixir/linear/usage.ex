defmodule SymphonyElixir.Linear.Usage do
  @moduledoc """
  Counts Linear requests per caller, and per query, over a rolling hour.

  Polling, the CI and PR review pollers, Auto Review, post-PR transitions and
  every agent's Linear tool calls share one API key and its hourly budget.
  `SymphonyElixir.Linear.Client.graphql/3` calls `record/1` for each request it
  sends, with the GraphQL operation name, attributed to the calling process's tag (`put_caller/1`,
  `with_caller/2`). A process without a tag, such as a task, inherits the tag of
  the first process in its `$callers` that has one; anything else counts as
  `other`.

  Counts live in per-minute buckets in a public ETS table owned by this server,
  so recording never waits on a process. Without the server (some tests),
  recording is a no-op and the snapshot is empty.
  """

  use GenServer

  alias SymphonyElixir.Linear.RateLimit

  @table __MODULE__
  @caller_key {__MODULE__, :caller}
  @bucket_ms 60_000
  @window_ms 3_600_000
  @window_buckets div(@window_ms, @bucket_ms)

  @type caller :: atom() | {:agent, String.t() | nil}
  @type snapshot :: %{
          window_ms: pos_integer(),
          total: non_neg_integer(),
          callers: [%{caller: String.t(), requests: pos_integer()}],
          queries: [%{query: String.t(), requests: pos_integer()}]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  @doc "Tags the calling process; its Linear requests count against `caller`."
  @spec put_caller(caller()) :: :ok
  def put_caller(caller) do
    Process.put(@caller_key, caller)
    :ok
  end

  @doc "Runs `fun` with the calling process tagged as `caller`, then restores the previous tag."
  @spec with_caller(caller(), (-> result)) :: result when result: term()
  def with_caller(caller, fun) when is_function(fun, 0) do
    previous = Process.put(@caller_key, caller)

    try do
      fun.()
    after
      restore_caller(previous)
    end
  end

  @doc "The caller the current process's Linear requests count against."
  @spec current_caller() :: caller()
  def current_caller do
    Process.get(@caller_key) || inherited_caller(Process.get(:"$callers", [])) || :other
  end

  @doc "Counts one Linear request for the current caller and the query it sends (`nil` when unnamed)."
  @spec record(String.t() | nil, integer()) :: :ok
  def record(query \\ nil, now_ms \\ RateLimit.now_ms()) when is_integer(now_ms) do
    key = {caller_label(current_caller()), query || "unnamed", div(now_ms, @bucket_ms)}
    :ets.update_counter(@table, key, 1, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Requests per caller and per query over the last hour, busiest first. Drops
  buckets that have left the window.
  """
  @spec snapshot(integer()) :: snapshot()
  def snapshot(now_ms \\ RateLimit.now_ms()) when is_integer(now_ms) do
    oldest_bucket = div(now_ms, @bucket_ms) - @window_buckets + 1
    :ets.select_delete(@table, [{{{:_, :_, :"$1"}, :_}, [{:<, :"$1", oldest_bucket}], [true]}])
    entries = :ets.tab2list(@table)
    callers = totals(entries, :caller, fn {{caller, _query, _bucket}, _count} -> caller end)

    %{
      window_ms: @window_ms,
      total: callers |> Enum.map(& &1.requests) |> Enum.sum(),
      callers: callers,
      queries: totals(entries, :query, fn {{_caller, query, _bucket}, _count} -> query end)
    }
  rescue
    ArgumentError -> %{window_ms: @window_ms, total: 0, callers: [], queries: []}
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The label a caller is shown with: `ci_poller`, `agent:TP-1`, …"
  @spec caller_label(caller()) :: String.t()
  def caller_label({:agent, identifier}) when is_binary(identifier) and identifier != "", do: "agent:" <> identifier
  def caller_label({:agent, _identifier}), do: "agent:unknown"
  def caller_label(caller) when is_atom(caller), do: Atom.to_string(caller)

  defp totals(entries, field, key_fun) do
    entries
    |> Enum.reduce(%{}, fn {_key, count} = entry, acc -> Map.update(acc, key_fun.(entry), count, &(&1 + count)) end)
    |> Enum.map(fn {name, requests} -> %{field => name, requests: requests} end)
    |> Enum.sort_by(&{-&1.requests, Map.fetch!(&1, field)})
  end

  defp restore_caller(nil), do: Process.delete(@caller_key)
  defp restore_caller(previous), do: Process.put(@caller_key, previous)

  # `$callers` holds the local pids that started a task, nearest first.
  defp inherited_caller(callers) do
    Enum.find_value(callers, fn pid ->
      with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
           {@caller_key, caller} <- List.keyfind(dictionary, @caller_key, 0) do
        caller
      else
        _untagged_or_gone -> nil
      end
    end)
  end
end
