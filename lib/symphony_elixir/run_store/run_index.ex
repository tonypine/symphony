defmodule SymphonyElixir.RunStore.RunIndex do
  @moduledoc """
  An ETS index of the run store's runs, newest `started_at` first, so the bounded reads
  (`RunStore.list_runs/2` and `RunStore.list_all_runs/1` with a limit, and
  `RunStore.list_issue_runs/2`) look up only the runs they return instead of scanning and sorting
  the whole table. The orchestrator reads its run history twice a second, and the CI and PR review
  pollers read the runs of each issue they watch every cycle, so those reads must not grow with the
  store. It also finds the runs with a status (`take_status/1`), the runs started in a time range
  (`take_started/2`) and the workspace identifiers of a repository's runs (`take_identifiers/1`),
  which the orchestrator reads when it starts.

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
  The `{repo_key, run_id}` of every run of issue `issue_id` in `repo_key`, newest first;
  `:unavailable` while the index isn't built.
  """
  @spec take_issue(String.t(), String.t()) :: {:ok, [{String.t(), String.t()}]} | :unavailable
  def take_issue(repo_key, issue_id) do
    with_table(:unavailable, fn ->
      if ready?(), do: {:ok, :ets.select(@table, [{{{:issue, repo_key, issue_id, :_, :"$1"}}, [], [{{repo_key, :"$1"}}]}])}, else: :unavailable
    end)
  end

  @doc """
  The `{repo_key, run_id}` of every run, in any repository, whose `status` is `status`; `:unavailable`
  while the index isn't built.
  """
  @spec take_status(String.t()) :: {:ok, [{String.t(), String.t()}]} | :unavailable
  def take_status(status) when is_binary(status) do
    with_table(:unavailable, fn ->
      if ready?(), do: {:ok, :ets.select(@table, [{{{:status, status, :"$1", :"$2"}}, [], [{{:"$1", :"$2"}}]}])}, else: :unavailable
    end)
  end

  @doc """
  The `{repo_key, run_id}` of every run, in any repository, started at or after `from` and before
  `to`, newest first; `:unavailable` while the index isn't built. It visits only those runs.
  """
  @spec take_started(DateTime.t(), DateTime.t()) :: {:ok, [{String.t(), String.t()}]} | :unavailable
  def take_started(%DateTime{} = from, %DateTime{} = to) do
    with_table(:unavailable, fn ->
      # The runs started before `to` rank above it; numbers sort before the binary repo keys, so the
      # walk starts at the first of them.
      if ready?(), do: {:ok, started(:ets.next(@table, {:all, rank(to) + 1, 0, 0}), rank(from))}, else: :unavailable
    end)
  end

  @doc """
  The workspace identifiers of `repo_key`'s runs (see `workspace_identifier/1`), each once, in
  ascending order; `:unavailable` while the index isn't built. It visits one run per identifier.
  """
  @spec take_identifiers(String.t()) :: {:ok, [String.t()]} | :unavailable
  def take_identifiers(repo_key) do
    with_table(:unavailable, fn ->
      if ready?(), do: {:ok, identifiers(:ets.next(@table, {:identifier, repo_key, 0, 0}), repo_key)}, else: :unavailable
    end)
  end

  @doc """
  The identifier of the workspace a run used: its `issue_identifier`, else the last segment of its
  `workspace_path`; `nil` without either.
  """
  @spec workspace_identifier(map()) :: String.t() | nil
  def workspace_identifier(%{issue_identifier: identifier}) when is_binary(identifier), do: identifier
  def workspace_identifier(%{workspace_path: path}) when is_binary(path), do: Path.basename(path)
  def workspace_identifier(_record), do: nil

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

  # A run whose `started_at`, `issue_id`, `status` or workspace identifier changed has its old
  # entries replaced. The new entries go in before the stale ones go, so a concurrent read never
  # finds the run missing from an entry both versions share.
  defp index(repo_key, run_id, record) do
    fields = {rank(Map.get(record, :started_at)), Map.get(record, :issue_id), Map.get(record, :status), workspace_identifier(record)}

    case :ets.lookup(@table, {:run, repo_key, run_id}) do
      [{_key, ^fields}] ->
        :ok

      previous ->
        new_entries = entries(repo_key, run_id, fields)
        :ets.insert(@table, [{{:run, repo_key, run_id}, fields} | Enum.map(new_entries, &{&1})])

        Enum.each(previous, fn {_key, old_fields} ->
          (entries(repo_key, run_id, old_fields) -- new_entries) |> Enum.each(&:ets.delete(@table, &1))
        end)
    end
  end

  defp entries(repo_key, run_id, {rank, issue_id, status, identifier}) do
    for {key, indexed?} <- [
          {{:repo, repo_key, rank, run_id}, true},
          {{:all, rank, repo_key, run_id}, true},
          {{:issue, repo_key, issue_id, rank, run_id}, is_binary(issue_id)},
          {{:status, status, repo_key, run_id}, is_binary(status)},
          {{:identifier, repo_key, identifier, run_id}, is_binary(identifier)}
        ],
        indexed?,
        do: key
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

  defp started({:all, rank, repo_key, run_id} = key, oldest_rank) when rank <= oldest_rank,
    do: [{repo_key, run_id} | started(:ets.next(@table, key), oldest_rank)]

  defp started(_key, _oldest_rank), do: []

  # From one identifier, skip its other runs: `identifier <> <<0>>` sorts after `identifier` and
  # before or at the next one.
  defp identifiers({:identifier, repo_key, identifier, _run_id}, repo_key),
    do: [identifier | identifiers(:ets.next(@table, {:identifier, repo_key, identifier <> <<0>>, 0}), repo_key)]

  defp identifiers(_key, _repo_key), do: []

  defp counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  defp bump(key), do: :ets.update_counter(@table, key, 1, {key, 0})
end
