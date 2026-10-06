defmodule SymphonyElixir.RunStore.RunIndex do
  @moduledoc """
  An ETS index of the run store's runs, newest `started_at` first, so the bounded reads
  (`RunStore.list_runs/2` and `RunStore.list_all_runs/1` with a limit) look up only the runs they
  return instead of scanning and sorting the whole table. The orchestrator reads its run history
  twice a second, so that read must not grow with the store.

  It also versions the runs of each `kind`: `memoize/3` keeps a value derived from the runs of one
  kind (the acceptance gate's verdicts) until a run of that kind is written.

  `RunStore` owns the table: it builds it from Mnesia when it starts and updates it after each run
  write commits. Until it is built, or without the table, `take/2` answers `:unavailable` and the
  reads fall back to the scan.
  """

  @table :symphony_run_store_run_index
  @ready_key :ready
  # Everything but the version counters and the ready mark.
  @reset_spec [{{{:version, :_}, :_}, [], [false]}, {{@ready_key, :_}, [], [false]}, {:_, [], [true]}]

  @doc "Creates the empty index table in the calling process, or empties the existing one."
  @spec create() :: :ok
  def create do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:ordered_set, :public, :named_table, read_concurrency: true, write_concurrency: true])
      _table -> :ets.delete_all_objects(@table)
    end

    :ok
  end

  @doc "Indexes the `{repo_key, run_id, record}` entries read from Mnesia and marks the index ready."
  @spec build([{String.t(), String.t(), map()}]) :: :ok
  def build(entries) do
    with_table(:ok, fn ->
      Enum.each(entries, fn {repo_key, run_id, record} -> index(repo_key, run_id, record) end)
      :ets.insert(@table, {@ready_key, true})
      :ok
    end)
  end

  @doc "Indexes a run after its write committed, and bumps the version of its `kind`."
  @spec put(String.t(), String.t(), map()) :: :ok
  def put(repo_key, run_id, record) do
    with_table(:ok, fn ->
      index(repo_key, run_id, record)
      bump({:version, Map.get(record, :kind)})
      :ok
    end)
  end

  @doc "Invalidates every memoized value, after a write that may have changed runs of any kind."
  @spec touch() :: :ok
  def touch do
    with_table(:ok, fn ->
      bump({:version, :all})
      :ok
    end)
  end

  @doc "Drops every indexed run and memoized value, after the run store was cleared."
  @spec reset() :: :ok
  def reset do
    with_table(:ok, fn ->
      :ets.select_delete(@table, @reset_spec)
      touch()
    end)
  end

  @doc """
  The `{repo_key, run_id}` of the `limit` newest runs of `repo_key`, or of every repository with
  `:all`; `:unavailable` while the index isn't built.
  """
  @spec take(String.t() | :all, non_neg_integer()) :: {:ok, [{String.t(), String.t()}]} | :unavailable
  def take(scope, limit) when is_integer(limit) and limit >= 0 do
    with_table(:unavailable, fn ->
      if ready?(), do: {:ok, select(scope, limit)}, else: :unavailable
    end)
  end

  @doc """
  The value `fun` derives from the runs of `kind`, computed again only after a run of that kind
  was written. `fun` returns `{:ok, value}` to keep the value or anything else to keep nothing.
  """
  @spec memoize(term(), term(), (-> {:ok, term()} | term())) :: {:ok, term()} | term()
  def memoize(key, kind, fun) when is_function(fun, 0) do
    case with_table(:unavailable, fn -> version(kind) end) do
      :unavailable -> fun.()
      version -> memoized(key, version, fun)
    end
  end

  defp memoized(key, version, fun) do
    case with_table([], fn -> :ets.lookup(@table, {:memo, key}) end) do
      [{_key, ^version, value}] ->
        {:ok, value}

      _stale_or_missing ->
        fun.() |> keep(key, version)
    end
  end

  defp keep({:ok, value}, key, version) do
    with_table(true, fn -> :ets.insert(@table, {{:memo, key}, version, value}) end)
    {:ok, value}
  end

  defp keep(other, _key, _version), do: other

  defp version(kind) do
    if ready?(), do: {counter({:version, :all}), counter({:version, kind})}, else: :unavailable
  end

  defp ready?, do: :ets.member(@table, @ready_key)

  # RunStore owns the table, so it is gone while RunStore restarts.
  defp with_table(default, fun) do
    fun.()
  rescue
    ArgumentError -> default
  end

  # A run whose `started_at` changed has its old entries replaced.
  defp index(repo_key, run_id, record) do
    rank = rank(Map.get(record, :started_at))

    case :ets.lookup(@table, {:run, repo_key, run_id}) do
      [{_key, ^rank}] ->
        :ok

      previous ->
        Enum.each(previous, fn {_key, old_rank} ->
          :ets.delete(@table, {:repo, repo_key, old_rank, run_id})
          :ets.delete(@table, {:all, old_rank, repo_key, run_id})
        end)

        :ets.insert(@table, [{{:run, repo_key, run_id}, rank}, {{:repo, repo_key, rank, run_id}}, {{:all, rank, repo_key, run_id}}])
    end
  end

  # Ascending keys in the ordered set are the newest runs first; a run without a start sorts last.
  defp rank(%DateTime{} = started_at), do: -DateTime.to_unix(started_at, :microsecond)
  defp rank(_started_at), do: 0

  defp select(_scope, 0), do: []

  defp select(:all, limit) do
    @table
    |> :ets.select([{{{:all, :_, :"$1", :"$2"}}, [], [{{:"$1", :"$2"}}]}], limit)
    |> selected()
  end

  defp select(repo_key, limit) do
    @table
    |> :ets.select([{{{:repo, repo_key, :_, :"$1"}}, [], [{{repo_key, :"$1"}}]}], limit)
    |> selected()
  end

  defp selected({keys, _continuation}), do: keys
  defp selected(:"$end_of_table"), do: []

  defp counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  defp bump(key), do: :ets.update_counter(@table, key, 1, {key, 0})
end
