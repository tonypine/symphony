defmodule SymphonyElixir.RunStore do
  @moduledoc """
  Durable store for orchestrator run history, retry queue entries, and totals.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Paths}
  alias SymphonyElixir.RunStore.RunIndex

  @runs_table :symphony_run_store_runs
  @retry_table :symphony_run_store_retries
  @totals_table :symphony_run_store_totals
  @pr_review_table :symphony_run_store_pr_reviews
  @ci_check_table :symphony_run_store_ci_checks
  @verification_allocation_table :symphony_run_store_verification_allocations
  @eval_logs_table :symphony_run_store_eval_logs
  @pause_table :symphony_run_store_pause
  @learnings_table :symphony_run_store_learnings
  @eval_log_attributes [:key, :repo_key, :eval_id, :outcome, :agent_kind, :issue_label, :date, :record]
  @eval_log_indexes [:repo_key, :outcome, :agent_kind, :issue_label, :date]
  @learning_attributes [:key, :repo_key, :created_at, :record]
  @learning_indexes [:repo_key, :created_at]
  @tables [
    {@runs_table, [:key, :repo_key, :run_id, :record], [index: [:repo_key]]},
    {@retry_table, [:key, :repo_key, :issue_id, :record], [index: [:repo_key]]},
    {@totals_table, [:key, :record], []},
    {@pr_review_table, [:key, :repo_key, :issue_id, :record], [index: [:repo_key]]},
    {@ci_check_table, [:key, :repo_key, :issue_id, :record], [index: [:repo_key]]},
    {@verification_allocation_table, [:key, :repo_key, :run_id, :record], [index: [:repo_key]]},
    {@pause_table, [:key, :record], []},
    {@eval_logs_table, @eval_log_attributes, [type: :bag, index: @eval_log_indexes]},
    {@learnings_table, @learning_attributes, [index: @learning_indexes]}
  ]
  @data_tables Enum.map(@tables, fn {table, _attributes, _opts} -> table end)
  @codex_totals_key :codex_totals
  @pause_key :dispatch_pause
  @usage_limits_key :usage_limits
  @unpaused %{paused: false, reason: nil, paused_at: nil}
  @quality_gate_cache_key :quality_gate_cache
  @quality_gate_comment_keys_key :quality_gate_comment_keys
  @mnesia_core_dir "core_dumps"
  # A run's row keeps only the newest events of its transcript buffer. The live run keeps its whole
  # buffer in memory for the dashboard; the row only feeds a finished run's transcript after a
  # restart, and every event it holds is rewritten with the table on each Mnesia log dump.
  @stored_transcript_events 20
  @rewrite_dc_dump_limit 1_000_000_000

  defmodule State do
    @moduledoc false

    defstruct [:dir]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec put_run(map()) :: :ok | {:error, term()}
  def put_run(%{repo_key: repo_key, run_id: run_id} = record) when is_binary(run_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      record = record |> normalize_record() |> Map.put(:repo_key, repo_key) |> bound_transcript_buffer()

      durable_transaction(fn ->
        :mnesia.write({@runs_table, scoped_key(repo_key, run_id), repo_key, run_id, record})
        :ok
      end)
      |> index_run(repo_key, run_id, record)
    end
  end

  def put_run(%{run_id: run_id}) when is_binary(run_id), do: {:error, :missing_repo_key}

  def put_run(_record), do: {:error, :invalid_run_record}

  @spec update_run(String.t(), map()) :: :ok | {:error, term()}
  def update_run(run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    {:error, :missing_repo_key}
  end

  @spec update_run(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_run(repo_key, run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      update_run_record(repo_key, run_id, attrs)
      |> unwrap_nested_error()
    end
  end

  def update_run(_repo_key, _run_id, _attrs), do: {:error, :invalid_run_record}

  @spec list_runs() :: [map()] | {:error, term()}
  def list_runs, do: list_runs(Config.repo_key!(), 50)

  @spec list_runs(String.t() | non_neg_integer() | :all) :: [map()] | {:error, term()}
  def list_runs(limit) when is_integer(limit) or limit == :all, do: list_runs(Config.repo_key!(), limit)

  @spec list_runs(String.t()) :: [map()] | {:error, term()}
  def list_runs(repo_key) when is_binary(repo_key), do: list_runs(repo_key, 50)

  @spec list_runs(String.t(), non_neg_integer() | :all) :: [map()] | {:error, term()}
  def list_runs(repo_key, limit) when is_integer(limit) and limit >= 0 do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      case RunIndex.take(repo_key, limit) do
        {:ok, keys} -> read_runs(keys)
        :unavailable -> repo_key |> list_runs(:all) |> take_runs(limit)
      end
    end
  end

  def list_runs(repo_key, :all) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn ->
        @runs_table
        |> scoped_records(repo_key)
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :started_at)), :desc)
      end)
    end
  end

  @doc """
  Every run of issue `issue_id` in `repo_key`, newest first, read through the run index, so a
  poller that reads the runs of the issues it watches doesn't scan the whole store each cycle.
  """
  @spec list_issue_runs(String.t(), String.t()) :: [map()] | {:error, term()}
  def list_issue_runs(repo_key, issue_id) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      case RunIndex.take_issue(repo_key, issue_id) do
        {:ok, keys} -> read_runs(keys)
        :unavailable -> repo_key |> list_runs(:all) |> filter_runs(&(Map.get(&1, :issue_id) == issue_id))
      end
    end
  end

  @doc """
  Every run, in any repository, started on the UTC `day`, newest first, read through the run index,
  so the orchestrator's start doesn't scan the whole store to total the day's tokens.
  """
  @spec list_runs_started_on(Date.t()) :: [map()] | {:error, term()}
  def list_runs_started_on(%Date{} = day) do
    from = DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC")
    to = DateTime.add(from, 1, :day)

    with :ok <- ensure_started() do
      case RunIndex.take_started(from, to) do
        {:ok, keys} -> read_runs(keys)
        :unavailable -> :all |> list_all_runs() |> filter_runs(&started_between?(Map.get(&1, :started_at), from, to))
      end
    end
  end

  @doc """
  Every run, in any repository, whose `status` is `status`, read through the run index, so the
  orchestrator's start doesn't scan the whole store for the issues that ran out of budget.
  """
  @spec list_runs_with_status(String.t()) :: [map()] | {:error, term()}
  def list_runs_with_status(status) when is_binary(status) do
    with :ok <- ensure_started() do
      case RunIndex.take_status(status) do
        {:ok, keys} -> read_runs(keys)
        :unavailable -> :all |> list_all_runs() |> filter_runs(&(Map.get(&1, :status) == status))
      end
    end
  end

  @doc """
  The workspace identifiers of `repo_key`'s runs, each once, in ascending order, read through the
  run index, so the startup orphan sweep doesn't scan the whole store for the workspaces to keep.
  """
  @spec list_run_identifiers(String.t()) :: [String.t()] | {:error, term()}
  def list_run_identifiers(repo_key) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      case RunIndex.take_identifiers(repo_key) do
        {:ok, identifiers} -> identifiers
        :unavailable -> repo_key |> list_runs(:all) |> run_identifiers()
      end
    end
  end

  @spec list_all_runs() :: [map()] | {:error, term()}
  def list_all_runs, do: list_all_runs(:all)

  @spec list_all_runs(non_neg_integer() | :all) :: [map()] | {:error, term()}
  def list_all_runs(limit) when is_integer(limit) and limit >= 0 do
    with :ok <- ensure_started() do
      case RunIndex.take(:all, limit) do
        {:ok, keys} -> read_runs(keys)
        :unavailable -> :all |> list_all_runs() |> take_runs(limit)
      end
    end
  end

  def list_all_runs(:all) do
    with :ok <- ensure_started() do
      transaction(fn ->
        @runs_table
        |> all_scoped_records()
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :started_at)), :desc)
      end)
    end
  end

  @doc """
  The value `fun` derives from the runs of `kind` (their `:kind` field), kept until a run of that
  kind is written, so a reader polled every second doesn't scan the store each time. `fun` returns
  `{:ok, value}` to keep it; anything else is returned and not kept.
  """
  @spec memoize_runs(term(), String.t(), (-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def memoize_runs(key, kind, fun) when is_function(fun, 0), do: RunIndex.memoize(key, kind, fun)

  @spec interrupt_running_runs(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def interrupt_running_runs(repo_key, error) when is_binary(error) do
    now = DateTime.utc_now()

    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        {:ok, interrupt_running_records(repo_key, error, now)}
      end)
      |> unwrap_nested_error()
      |> index_interrupted_runs()
      |> tap(fn _result -> RunIndex.touch() end)
    end
  end

  def interrupt_running_runs(_repo_key, _error), do: {:error, :invalid_error}

  @spec interrupt_running_runs(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def interrupt_running_runs(error) when is_binary(error), do: {:error, :missing_repo_key}

  @spec put_retry(map()) :: :ok | {:error, term()}
  def put_retry(%{repo_key: repo_key, issue_id: issue_id} = record) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        key = scoped_key(repo_key, issue_id)
        :mnesia.write({@retry_table, key, repo_key, issue_id, record |> normalize_record() |> Map.put(:repo_key, repo_key)})
        :ok
      end)
    end
  end

  def put_retry(%{issue_id: issue_id}) when is_binary(issue_id), do: {:error, :missing_repo_key}

  def put_retry(_record), do: {:error, :invalid_retry_record}

  @spec delete_retry(String.t()) :: :ok | {:error, term()}
  def delete_retry(issue_id) when is_binary(issue_id), do: {:error, :missing_repo_key}

  @spec delete_retry(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_retry(repo_key, issue_id) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.delete({@retry_table, scoped_key(repo_key, issue_id)})
        :ok
      end)
    end
  end

  def delete_retry(_repo_key, _issue_id), do: {:error, :invalid_issue_id}

  @spec list_retries() :: [map()] | {:error, term()}
  def list_retries, do: list_retries(Config.repo_key!())

  @spec list_retries(String.t() | :all) :: [map()] | {:error, term()}
  def list_retries(:all) do
    with :ok <- ensure_started() do
      transaction(fn ->
        @retry_table
        |> all_scoped_records()
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :due_at)), :asc)
      end)
    end
  end

  def list_retries(repo_key) when is_binary(repo_key) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn ->
        @retry_table
        |> scoped_records(repo_key)
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :due_at)), :asc)
      end)
    end
  end

  @spec put_codex_totals(map()) :: :ok | {:error, term()}
  def put_codex_totals(totals) when is_map(totals) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.write({@totals_table, @codex_totals_key, normalize_record(totals)})
        :ok
      end)
    end
  end

  def put_codex_totals(_totals), do: {:error, :invalid_codex_totals}

  @spec get_codex_totals() :: map() | nil | {:error, term()}
  def get_codex_totals do
    with :ok <- ensure_started() do
      transaction(&read_codex_totals/0)
    end
  end

  @spec put_quality_gate_cache(map()) :: :ok | {:error, term()}
  def put_quality_gate_cache(cache) when is_map(cache) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.write({@totals_table, @quality_gate_cache_key, normalize_record(cache)})
        :ok
      end)
    end
  end

  def put_quality_gate_cache(_cache), do: {:error, :invalid_quality_gate_cache}

  @spec get_quality_gate_cache() :: map() | nil | {:error, term()}
  def get_quality_gate_cache do
    with :ok <- ensure_started() do
      transaction(&read_quality_gate_cache/0)
    end
  end

  @spec put_quality_gate_comment_keys(MapSet.t()) :: :ok | {:error, term()}
  def put_quality_gate_comment_keys(%MapSet{} = keys) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.write({@totals_table, @quality_gate_comment_keys_key, keys})
        :ok
      end)
    end
  end

  def put_quality_gate_comment_keys(_keys), do: {:error, :invalid_quality_gate_comment_keys}

  @spec get_quality_gate_comment_keys() :: MapSet.t() | nil | {:error, term()}
  def get_quality_gate_comment_keys do
    with :ok <- ensure_started() do
      transaction(&read_quality_gate_comment_keys/0)
    end
  end

  # The PR head an issue's Rework started from, kept across re-dispatched runs so a run can
  # tell rework an earlier run already pushed from a fresh Rework nobody has worked on yet.
  @spec put_rework_base(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def put_rework_base(repo_key, issue_id, head) when is_binary(issue_id) and is_binary(head) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.write({@totals_table, rework_base_key(repo_key, issue_id), head})
        :ok
      end)
    end
  end

  def put_rework_base(_repo_key, _issue_id, _head), do: {:error, :invalid_rework_base}

  @spec get_rework_base(String.t(), String.t()) :: String.t() | nil | {:error, term()}
  def get_rework_base(repo_key, issue_id) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn -> read_rework_base(repo_key, issue_id) end)
    end
  end

  def get_rework_base(_repo_key, _issue_id), do: {:error, :invalid_issue_id}

  @spec delete_rework_base(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_rework_base(repo_key, issue_id) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.delete({@totals_table, rework_base_key(repo_key, issue_id)})
        :ok
      end)
    end
  end

  def delete_rework_base(_repo_key, _issue_id), do: {:error, :invalid_issue_id}

  # When Symphony itself last moved an issue's state in Linear. Symphony and the person reviewing
  # can share one Linear user, so the issue's history alone cannot tell their moves apart.
  @spec put_own_state_move(String.t(), DateTime.t()) :: :ok | {:error, term()}
  def put_own_state_move(issue_id, %DateTime{} = at) when is_binary(issue_id) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.write({@totals_table, own_state_move_key(issue_id), at})
        :ok
      end)
    end
  end

  def put_own_state_move(_issue_id, _at), do: {:error, :invalid_own_state_move}

  @spec get_own_state_move(String.t()) :: DateTime.t() | nil | {:error, term()}
  def get_own_state_move(issue_id) when is_binary(issue_id) do
    with :ok <- ensure_started() do
      transaction(fn -> read_own_state_move(issue_id) end)
    end
  end

  def get_own_state_move(_issue_id), do: {:error, :invalid_issue_id}

  # An issue Symphony moved to the waiting state because its pull request merged with a sub-issue
  # open. Only such an issue is moved to Done once its sub-issues finish (see `SubIssueWait`).
  @spec put_merged_wait(String.t()) :: :ok | {:error, term()}
  def put_merged_wait(issue_id) when is_binary(issue_id) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.write({@totals_table, merged_wait_key(issue_id), true})
        :ok
      end)
    end
  end

  def put_merged_wait(_issue_id), do: {:error, :invalid_issue_id}

  @spec merged_wait?(String.t()) :: boolean() | {:error, term()}
  def merged_wait?(issue_id) when is_binary(issue_id) do
    with :ok <- ensure_started() do
      transaction(fn -> :mnesia.read(@totals_table, merged_wait_key(issue_id)) != [] end)
    end
  end

  def merged_wait?(_issue_id), do: {:error, :invalid_issue_id}

  @spec delete_merged_wait(String.t()) :: :ok | {:error, term()}
  def delete_merged_wait(issue_id) when is_binary(issue_id) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.delete({@totals_table, merged_wait_key(issue_id)})
        :ok
      end)
    end
  end

  def delete_merged_wait(_issue_id), do: {:error, :invalid_issue_id}

  @doc """
  Replaces the forced-ticket queue (`SymphonyElixir.ForcedQueue` entries keyed by issue id), so a
  restart keeps each ticket's `forced_since` and its place in the queue.
  """
  @spec put_forced(String.t(), map()) :: :ok | {:error, term()}
  def put_forced(repo_key, entries) when is_map(entries) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_forced(repo_key, entries) end)
    end
  end

  def put_forced(_repo_key, _entries), do: {:error, :invalid_forced_entries}

  @spec get_forced(String.t()) :: map() | {:error, term()}
  def get_forced(repo_key) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn -> read_forced(repo_key) end)
    end
  end

  @spec put_pr_review(map()) :: :ok | {:error, term()}
  def put_pr_review(%{repo_key: repo_key, issue_id: issue_id} = record) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        key = scoped_key(repo_key, issue_id)
        :mnesia.write({@pr_review_table, key, repo_key, issue_id, record |> normalize_record() |> Map.put(:repo_key, repo_key)})
        :ok
      end)
    end
  end

  def put_pr_review(%{issue_id: issue_id}) when is_binary(issue_id), do: {:error, :missing_repo_key}

  def put_pr_review(_record), do: {:error, :invalid_pr_review_record}

  @spec update_pr_review(String.t(), map()) :: :ok | {:error, term()}
  def update_pr_review(issue_id, attrs) when is_binary(issue_id) and is_map(attrs) do
    {:error, :missing_repo_key}
  end

  @spec update_pr_review(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_pr_review(repo_key, issue_id, attrs) when is_binary(issue_id) and is_map(attrs) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      update_pr_review_record(repo_key, issue_id, attrs)
      |> unwrap_nested_error()
    end
  end

  def update_pr_review(_repo_key, _issue_id, _attrs), do: {:error, :invalid_pr_review_record}

  @spec delete_pr_review(String.t()) :: :ok | {:error, term()}
  def delete_pr_review(issue_id) when is_binary(issue_id), do: {:error, :missing_repo_key}

  @spec delete_pr_review(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_pr_review(repo_key, issue_id) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.delete({@pr_review_table, scoped_key(repo_key, issue_id)})
        :ok
      end)
    end
  end

  def delete_pr_review(_repo_key, _issue_id), do: {:error, :invalid_issue_id}

  @spec list_pr_reviews() :: [map()] | {:error, term()}
  def list_pr_reviews, do: list_pr_reviews(Config.repo_key!())

  @spec list_pr_reviews(String.t()) :: [map()] | {:error, term()}
  def list_pr_reviews(repo_key) when is_binary(repo_key) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn ->
        @pr_review_table
        |> scoped_records(repo_key)
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :updated_at)), :desc)
      end)
    end
  end

  @spec put_ci_check(map()) :: :ok | {:error, term()}
  def put_ci_check(%{repo_key: repo_key, issue_id: issue_id} = record) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        key = scoped_key(repo_key, issue_id)
        :mnesia.write({@ci_check_table, key, repo_key, issue_id, record |> normalize_record() |> Map.put(:repo_key, repo_key)})
        :ok
      end)
    end
  end

  def put_ci_check(%{issue_id: issue_id}) when is_binary(issue_id), do: {:error, :missing_repo_key}

  def put_ci_check(_record), do: {:error, :invalid_ci_check_record}

  @spec update_ci_check(String.t(), map()) :: :ok | {:error, term()}
  def update_ci_check(issue_id, attrs) when is_binary(issue_id) and is_map(attrs) do
    {:error, :missing_repo_key}
  end

  @spec update_ci_check(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_ci_check(repo_key, issue_id, attrs) when is_binary(issue_id) and is_map(attrs) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      update_ci_check_record(repo_key, issue_id, attrs)
      |> unwrap_nested_error()
    end
  end

  def update_ci_check(_repo_key, _issue_id, _attrs), do: {:error, :invalid_ci_check_record}

  @spec delete_ci_check(String.t()) :: :ok | {:error, term()}
  def delete_ci_check(issue_id) when is_binary(issue_id), do: {:error, :missing_repo_key}

  @spec delete_ci_check(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_ci_check(repo_key, issue_id) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.delete({@ci_check_table, scoped_key(repo_key, issue_id)})
        :ok
      end)
    end
  end

  def delete_ci_check(_repo_key, _issue_id), do: {:error, :invalid_issue_id}

  @spec list_ci_checks() :: [map()] | {:error, term()}
  def list_ci_checks, do: list_ci_checks(Config.repo_key!())

  @spec list_ci_checks(String.t()) :: [map()] | {:error, term()}
  def list_ci_checks(repo_key) when is_binary(repo_key) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn ->
        @ci_check_table
        |> scoped_records(repo_key)
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :updated_at)), :desc)
      end)
    end
  end

  @spec put_verification_allocation(map()) :: :ok | {:error, term()}
  def put_verification_allocation(%{repo_key: repo_key, run_id: run_id, port: port} = record)
      when is_binary(run_id) and is_integer(port) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        key = scoped_key(repo_key, run_id)

        :mnesia.write({
          @verification_allocation_table,
          key,
          repo_key,
          run_id,
          record |> normalize_record() |> Map.put(:repo_key, repo_key)
        })

        :ok
      end)
    end
  end

  def put_verification_allocation(%{run_id: run_id, port: port}) when is_binary(run_id) and is_integer(port),
    do: {:error, :missing_repo_key}

  def put_verification_allocation(_record), do: {:error, :invalid_verification_allocation_record}

  @spec update_verification_allocation(String.t(), map()) :: :ok | {:error, term()}
  def update_verification_allocation(run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    {:error, :missing_repo_key}
  end

  @spec update_verification_allocation(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_verification_allocation(repo_key, run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      update_verification_allocation_record(repo_key, run_id, attrs)
      |> unwrap_nested_error()
    end
  end

  def update_verification_allocation(_repo_key, _run_id, _attrs), do: {:error, :invalid_verification_allocation_record}

  @spec delete_verification_allocation(String.t()) :: :ok | {:error, term()}
  def delete_verification_allocation(run_id) when is_binary(run_id), do: {:error, :missing_repo_key}

  @spec delete_verification_allocation(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_verification_allocation(repo_key, run_id) when is_binary(run_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.delete({@verification_allocation_table, scoped_key(repo_key, run_id)})
        :ok
      end)
    end
  end

  def delete_verification_allocation(_repo_key, _run_id), do: {:error, :invalid_run_id}

  @spec list_verification_allocations() :: [map()] | {:error, term()}
  def list_verification_allocations, do: list_verification_allocations(Config.repo_key!())

  @spec list_verification_allocations(String.t()) :: [map()] | {:error, term()}
  def list_verification_allocations(repo_key) when is_binary(repo_key) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn ->
        @verification_allocation_table
        |> scoped_records(repo_key)
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :allocated_at)), :asc)
      end)
    end
  end

  @spec list_all_verification_allocations() :: [map()] | {:error, term()}
  def list_all_verification_allocations do
    with :ok <- ensure_started() do
      transaction(fn ->
        @verification_allocation_table
        |> all_scoped_records()
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :allocated_at)), :asc)
      end)
    end
  end

  @spec put_eval_log(map()) :: :ok | {:error, term()}
  def put_eval_log(%{repo_key: repo_key, eval_id: eval_id} = record) when is_binary(eval_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn ->
        write_eval_log_records(repo_key, eval_id, normalize_eval_log_record(record, repo_key))
      end)
    end
  end

  def put_eval_log(%{eval_id: eval_id}) when is_binary(eval_id), do: {:error, :missing_repo_key}

  def put_eval_log(_record), do: {:error, :invalid_eval_log_record}

  @spec list_eval_logs() :: [map()] | {:error, term()}
  def list_eval_logs, do: list_eval_logs(Config.repo_key!(), [])

  @spec list_eval_logs(keyword()) :: [map()] | {:error, term()}
  @spec list_eval_logs(String.t()) :: [map()] | {:error, term()}
  def list_eval_logs(opts) when is_list(opts), do: list_eval_logs(Config.repo_key!(), opts)
  def list_eval_logs(repo_key) when is_binary(repo_key), do: list_eval_logs(repo_key, [])

  @spec list_eval_logs(String.t(), keyword()) :: [map()] | {:error, term()}
  def list_eval_logs(repo_key, opts) when is_list(opts) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn ->
        @eval_logs_table
        |> all_eval_log_records(repo_key)
        |> filter_eval_logs(opts)
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :logged_at)), :desc)
        |> limit_eval_logs(Keyword.get(opts, :limit, 50))
      end)
    end
  end

  @spec put_learnings([map()]) :: :ok | {:error, term()}
  def put_learnings(records), do: put_learnings(records, 500)

  @spec put_learnings([map()], pos_integer()) :: :ok | {:error, term()}
  def put_learnings([], _max_total_per_repo), do: :ok

  def put_learnings(records, max_total_per_repo)
      when is_list(records) and is_integer(max_total_per_repo) and max_total_per_repo > 0 do
    with :ok <- ensure_started(),
         {:ok, normalized} <- normalize_learning_records(records) do
      durable_transaction(fn ->
        Enum.each(normalized, &write_learning_record/1)

        normalized
        |> Enum.map(&Map.fetch!(&1, :repo_key))
        |> Enum.uniq()
        |> Enum.each(&prune_learning_records(&1, max_total_per_repo))

        :ok
      end)
    end
  end

  def put_learnings(_records, _max_total_per_repo), do: {:error, :invalid_learning_record}

  @spec list_learnings() :: [map()] | {:error, term()}
  def list_learnings, do: list_learnings(Config.repo_key!(), [])

  @spec list_learnings(keyword()) :: [map()] | {:error, term()}
  @spec list_learnings(String.t()) :: [map()] | {:error, term()}
  def list_learnings(opts) when is_list(opts) do
    repo_key = Keyword.get(opts, :repo_key) || Config.repo_key!()
    list_learnings(repo_key, opts)
  end

  def list_learnings(repo_key) when is_binary(repo_key), do: list_learnings(repo_key, [])

  @spec list_learnings(String.t(), keyword()) :: [map()] | {:error, term()}
  def list_learnings(repo_key, opts) when is_list(opts) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn ->
        @learnings_table
        |> all_learning_records(repo_key)
        |> filter_learnings(opts)
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :created_at)), :desc)
        |> limit_learnings(Keyword.get(opts, :limit, :all))
      end)
    end
  end

  @spec set_paused(boolean(), String.t() | nil) :: :ok | {:error, term()}
  def set_paused(paused, reason) when is_boolean(paused) do
    with :ok <- ensure_started() do
      durable_transaction(fn -> write_pause_state(paused, reason) end)
    end
  end

  def set_paused(_paused, _reason), do: {:error, :invalid_pause_state}

  @spec get_paused() :: map() | {:error, term()}
  def get_paused do
    with :ok <- ensure_started() do
      transaction(fn -> read_pause_record() end)
    end
  end

  @doc """
  Replaces the usage-limit holds, keyed by `{provider, scope}`. They are stored next to the
  operator pause, not inside it, so clearing one never touches the other.
  """
  @spec put_usage_limits(map()) :: :ok | {:error, term()}
  def put_usage_limits(usage_limits) when is_map(usage_limits) do
    with :ok <- ensure_started() do
      durable_transaction(fn -> write_usage_limits(usage_limits) end)
    end
  end

  def put_usage_limits(_usage_limits), do: {:error, :invalid_usage_limits}

  @spec get_usage_limits() :: map() | {:error, term()}
  def get_usage_limits do
    with :ok <- ensure_started() do
      transaction(&read_usage_limits/0)
    end
  end

  @spec clear() :: :ok | {:error, term()}
  def clear do
    with :ok <- ensure_started() do
      @data_tables
      |> Enum.reduce_while(:ok, &clear_table/2)
      |> sync_after_clear()
      |> tap(fn _result -> RunIndex.reset() end)
    end
  end

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, store_dir())
    # Before Mnesia: a run written while the index is built still lands in it.
    :ok = RunIndex.create()

    case setup_mnesia(dir) do
      :ok ->
        build_run_index()
        {:ok, %State{dir: dir}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @spec store_dir() :: Path.t()
  def store_dir do
    Application.get_env(:symphony_elixir, :run_store_dir) ||
      Paths.run_store_dir()
  end

  defp setup_mnesia(dir) when is_binary(dir) do
    expanded_dir = Path.expand(dir)
    core_dir = mnesia_core_dir(expanded_dir)

    case prepare_mnesia_dirs(expanded_dir, core_dir) do
      :ok -> start_and_ensure_mnesia(expanded_dir, core_dir)
      {:error, reason} -> {:error, reason}
    end
  end

  defp setup_mnesia(_dir), do: {:error, :invalid_run_store_dir}

  defp prepare_mnesia_dirs(dir, core_dir) do
    case File.mkdir_p(dir) do
      :ok -> File.mkdir_p(core_dir)
      {:error, reason} -> {:error, reason}
    end
  end

  defp mnesia_core_dir(dir), do: Path.join(dir, @mnesia_core_dir)

  defp start_and_ensure_mnesia(dir, core_dir) do
    case start_mnesia(dir, core_dir) do
      :ok -> ensure_tables()
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_mnesia(dir, core_dir) do
    case load_mnesia() do
      :ok -> start_or_validate_mnesia(dir, core_dir)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_or_validate_mnesia(dir, core_dir) do
    if mnesia_running?() do
      ensure_running_mnesia_dir(dir)
    else
      start_stopped_mnesia(dir, core_dir)
    end
  end

  defp start_stopped_mnesia(dir, core_dir) do
    Application.put_env(:mnesia, :dir, String.to_charlist(dir))
    Application.put_env(:mnesia, :core_dir, String.to_charlist(core_dir))

    case create_schema() do
      :ok -> normalize_mnesia_start(:mnesia.start())
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_mnesia do
    case Application.load(:mnesia) do
      :ok -> :ok
      {:error, {:already_loaded, :mnesia}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mnesia_running? do
    :mnesia.system_info(:is_running) == :yes
  catch
    :exit, _reason -> false
  end

  defp create_schema do
    case :mnesia.create_schema([node()]) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
      {:error, {:already_exists, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_mnesia_start(:ok), do: :ok
  defp normalize_mnesia_start({:error, reason}), do: {:error, reason}

  defp ensure_running_mnesia_dir(expected_dir) do
    running_dir =
      :mnesia.system_info(:directory)
      |> to_string()
      |> Path.expand()

    if running_dir == expected_dir do
      :ok
    else
      {:error, {:mnesia_dir_mismatch, %{expected: expected_dir, running: running_dir}}}
    end
  end

  defp ensure_tables do
    with :ok <- Enum.reduce_while(@tables, :ok, &ensure_table/2) do
      wait_for_tables()
    end
  end

  defp ensure_table({table, attributes, opts}, :ok) do
    if table in :mnesia.system_info(:tables) do
      table
      |> ensure_existing_table(attributes, Keyword.get(opts, :index, []))
      |> continue_or_halt()
    else
      create_opts =
        opts
        |> Keyword.put_new(:type, :set)
        |> normalize_create_table_indexes(attributes)
        |> Keyword.merge(attributes: attributes, disc_copies: [node()])

      case :mnesia.create_table(
             table,
             create_opts
           ) do
        {:atomic, :ok} -> {:cont, :ok}
        {:aborted, {:already_exists, ^table}} -> {:cont, :ok}
        {:aborted, reason} -> {:halt, {:error, reason}}
      end
    end
  end

  defp ensure_existing_table(table, attributes, indexes) do
    with :ok <- ensure_table_attributes(table, attributes) do
      ensure_table_indexes(table, indexes)
    end
  end

  defp continue_or_halt(:ok), do: {:cont, :ok}
  defp continue_or_halt({:error, reason}), do: {:halt, {:error, reason}}

  defp ensure_table_attributes(table, expected_attributes) do
    actual_attributes = :mnesia.table_info(table, :attributes)

    if actual_attributes == expected_attributes do
      :ok
    else
      {:error, run_store_schema_mismatch(table, expected_attributes, actual_attributes)}
    end
  end

  defp ensure_table_indexes(_table, []), do: :ok

  defp ensure_table_indexes(table, indexes) when is_list(indexes) do
    current_indexes = :mnesia.table_info(table, :index)
    attributes = :mnesia.table_info(table, :attributes)

    indexes
    |> Enum.reject(&index_present?(&1, current_indexes, attributes))
    |> Enum.reduce_while(:ok, fn index, :ok ->
      table
      |> ensure_table_index(index, attributes)
      |> continue_or_halt()
    end)
  end

  defp ensure_table_index(table, index, attributes) do
    case attribute_position(index, attributes) do
      nil -> {:error, run_store_schema_mismatch(table, [index], attributes)}
      index_position -> add_table_index(table, index_position)
    end
  end

  defp add_table_index(table, index_position) do
    case :mnesia.add_table_index(table, index_position) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^table, ^index_position}} -> :ok
      {:aborted, {:already_exists, ^index_position}} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp run_store_schema_mismatch(table, expected_attributes, actual_attributes) do
    details = %{
      actual_attributes: actual_attributes,
      expected_attributes: expected_attributes,
      run_store_dir: mnesia_directory(),
      runbook: "Stop Symphony, wipe the configured run_store_dir, and restart with an empty v2 RunStore."
    }

    Logger.error(
      "RunStore Mnesia schema mismatch table=#{inspect(table)} expected=#{inspect(expected_attributes)} actual=#{inspect(actual_attributes)} run_store_dir=#{details.run_store_dir}; #{details.runbook}"
    )

    {:run_store_schema_mismatch, table, details}
  end

  defp mnesia_directory do
    :mnesia.system_info(:directory)
    |> to_string()
    |> Path.expand()
  catch
    :exit, _reason -> store_dir()
  end

  defp normalize_create_table_indexes(opts, attributes) do
    Keyword.update(opts, :index, [], fn indexes ->
      Enum.map(indexes, &attribute_position(&1, attributes))
    end)
  end

  defp index_present?(index, current_indexes, attributes) do
    index in current_indexes or attribute_position(index, attributes) in current_indexes
  end

  defp attribute_position(index, attributes) when is_atom(index) and is_list(attributes) do
    case Enum.find_index(attributes, &(&1 == index)) do
      nil -> nil
      zero_based -> zero_based + 2
    end
  end

  defp attribute_position(index, _attributes), do: index

  defp wait_for_tables do
    case :mnesia.wait_for_tables(@data_tables, 5_000) do
      :ok -> :ok
      {:timeout, tables} -> {:error, {:mnesia_table_timeout, tables}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transaction(fun) when is_function(fun, 0) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp update_run_record(repo_key, run_id, attrs) do
    durable_transaction(fn ->
      key = scoped_key(repo_key, run_id)

      case :mnesia.read(@runs_table, key) do
        [{@runs_table, ^key, ^repo_key, ^run_id, record}] ->
          updated =
            record
            |> Map.merge(normalize_update(attrs, [:key, :repo_key, :run_id]))
            |> Map.put(:repo_key, repo_key)
            |> bound_transcript_buffer()

          :mnesia.write({@runs_table, key, repo_key, run_id, updated})
          {:ok, updated}

        [] ->
          {:error, :run_not_found}
      end
    end)
    |> case do
      {:ok, updated} -> index_run(:ok, repo_key, run_id, updated)
      error -> error
    end
  end

  # Only after the write committed, so the index never names a run Mnesia doesn't hold.
  defp index_run(:ok, repo_key, run_id, record), do: RunIndex.put(repo_key, run_id, record)
  defp index_run(error, _repo_key, _run_id, _record), do: error

  defp build_run_index do
    with entries when is_list(entries) <- transaction(fn -> :mnesia.match_object({@runs_table, :_, :_, :_, :_}) end) do
      trim_stored_transcripts(entries)

      entries
      |> Enum.map(fn {@runs_table, _key, repo_key, run_id, record} -> {repo_key, run_id, bound_transcript_buffer(record)} end)
      |> RunIndex.build()
    end
  end

  defp bound_transcript_buffer(%{transcript_buffer: buffer} = record) when is_list(buffer) do
    if length(buffer) > @stored_transcript_events do
      kept = Enum.take(buffer, -@stored_transcript_events)
      %{record | transcript_buffer: kept} |> Map.put(:transcript_buffer_size, length(kept))
    else
      record
    end
  end

  defp bound_transcript_buffer(record), do: record

  # Rows written before the buffer was bounded hold up to 200 events each. Trimmed once, when the
  # store starts. Each row is read again in the transaction: a run written since the scan is already
  # bounded.
  #
  # Mnesia rewrites a disc_copies table's file from memory at a log dump only when the table has a
  # log file (`.DCL`) a quarter of the file's size (`dc_dump_limit`), which the log of the trimmed rows
  # would take hours of writes to reach. So the limit is raised for these dumps, and the rows written
  # twice: when the table had no log file, the first dump creates it and the second rewrites the file.
  defp trim_stored_transcripts(entries) do
    case Enum.filter(entries, fn {@runs_table, _key, _repo_key, _run_id, record} -> bound_transcript_buffer(record) != record end) do
      [] ->
        :ok

      over_cap ->
        limit = :mnesia.system_info(:dc_dump_limit)

        try do
          :mnesia.change_config(:dc_dump_limit, @rewrite_dc_dump_limit)

          for _pass <- 1..2 do
            transaction(fn -> Enum.each(over_cap, &trim_stored_transcript/1) end)
            :mnesia.dump_log()
          end
        after
          :mnesia.change_config(:dc_dump_limit, limit)
        end

        Logger.info("RunStore trimmed the stored transcript buffers of #{length(over_cap)} run(s) to #{@stored_transcript_events} events")
    end
  end

  defp trim_stored_transcript({@runs_table, key, _repo_key, _run_id, _record}) do
    with [{@runs_table, ^key, repo_key, run_id, record}] <- :mnesia.read(@runs_table, key) do
      :mnesia.write({@runs_table, key, repo_key, run_id, bound_transcript_buffer(record)})
    end
  end

  # Reads the runs the index named, in its order; a run deleted since is left out.
  defp read_runs(keys) do
    transaction(fn -> Enum.flat_map(keys, &read_run/1) end)
  end

  defp read_run({repo_key, run_id}) do
    for {@runs_table, _key, _repo_key, _run_id, record} <- :mnesia.read(@runs_table, scoped_key(repo_key, run_id)), do: record
  end

  defp take_runs(runs, limit) when is_list(runs), do: Enum.take(runs, limit)
  defp take_runs({:error, reason}, _limit), do: {:error, reason}

  defp filter_runs(runs, fun) when is_list(runs), do: Enum.filter(runs, fun)
  defp filter_runs({:error, reason}, _fun), do: {:error, reason}

  defp started_between?(%DateTime{} = started_at, from, to) do
    DateTime.compare(started_at, from) != :lt and DateTime.compare(started_at, to) == :lt
  end

  defp started_between?(_started_at, _from, _to), do: false

  defp run_identifiers(runs) when is_list(runs) do
    runs |> Enum.map(&RunIndex.workspace_identifier/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
  end

  defp run_identifiers({:error, reason}), do: {:error, reason}

  defp update_pr_review_record(repo_key, issue_id, attrs) do
    durable_transaction(fn ->
      key = scoped_key(repo_key, issue_id)

      case :mnesia.read(@pr_review_table, key) do
        [{@pr_review_table, ^key, ^repo_key, ^issue_id, record}] ->
          updated = record |> Map.merge(normalize_update(attrs, [:key, :repo_key, :issue_id])) |> Map.put(:repo_key, repo_key)
          :mnesia.write({@pr_review_table, key, repo_key, issue_id, updated})
          :ok

        [] ->
          {:error, :pr_review_not_found}
      end
    end)
  end

  defp update_ci_check_record(repo_key, issue_id, attrs) do
    durable_transaction(fn ->
      key = scoped_key(repo_key, issue_id)

      case :mnesia.read(@ci_check_table, key) do
        [{@ci_check_table, ^key, ^repo_key, ^issue_id, record}] ->
          updated = record |> Map.merge(normalize_update(attrs, [:key, :repo_key, :issue_id])) |> Map.put(:repo_key, repo_key)
          :mnesia.write({@ci_check_table, key, repo_key, issue_id, updated})
          :ok

        [] ->
          {:error, :ci_check_not_found}
      end
    end)
  end

  defp update_verification_allocation_record(repo_key, run_id, attrs) do
    durable_transaction(fn ->
      key = scoped_key(repo_key, run_id)

      case :mnesia.read(@verification_allocation_table, key) do
        [{@verification_allocation_table, ^key, ^repo_key, ^run_id, record}] ->
          updated = record |> Map.merge(normalize_update(attrs, [:key, :repo_key, :run_id])) |> Map.put(:repo_key, repo_key)
          :mnesia.write({@verification_allocation_table, key, repo_key, run_id, updated})
          :ok

        [] ->
          {:error, :verification_allocation_not_found}
      end
    end)
  end

  defp durable_transaction(fun) when is_function(fun, 0) do
    case transaction(fun) do
      {:error, _reason} = error ->
        error

      result ->
        case sync_mnesia_log() do
          :ok ->
            result

          {:error, reason} ->
            Logger.warning("Run store transaction committed but failed to sync Mnesia log: #{inspect(reason)}")
            result
        end
    end
  end

  defp sync_mnesia_log do
    case :mnesia.sync_log() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_table(table, :ok) do
    case :mnesia.clear_table(table) do
      {:atomic, :ok} -> {:cont, :ok}
      {:aborted, reason} -> {:halt, {:error, reason}}
    end
  end

  defp sync_after_clear(:ok), do: sync_mnesia_log()
  defp sync_after_clear({:error, reason}), do: {:error, reason}

  defp read_codex_totals do
    case :mnesia.read(@totals_table, @codex_totals_key) do
      [{@totals_table, @codex_totals_key, totals}] -> totals
      [] -> nil
    end
  end

  defp write_usage_limits(usage_limits) when map_size(usage_limits) == 0 do
    :mnesia.delete({@pause_table, @usage_limits_key})
    :ok
  end

  defp write_usage_limits(usage_limits) do
    :mnesia.write({@pause_table, @usage_limits_key, usage_limits})
    :ok
  end

  defp read_usage_limits do
    case :mnesia.read(@pause_table, @usage_limits_key) do
      [{@pause_table, @usage_limits_key, usage_limits}] when is_map(usage_limits) -> usage_limits
      _ -> %{}
    end
  end

  defp read_pause_record do
    case :mnesia.read(@pause_table, @pause_key) do
      [{@pause_table, @pause_key, record}] when is_map(record) ->
        Map.merge(@unpaused, record)

      _ ->
        @unpaused
    end
  end

  defp write_pause_state(paused, reason) do
    current = read_pause_record()

    cond do
      paused and Map.get(current, :paused) == true ->
        :ok

      paused ->
        persist_pause_record(reason)

      Map.get(current, :paused) == true ->
        :mnesia.delete({@pause_table, @pause_key})
        :ok

      true ->
        :ok
    end
  end

  defp persist_pause_record(reason) do
    now = DateTime.utc_now()

    :mnesia.write(
      {@pause_table, @pause_key,
       %{
         paused: true,
         reason: normalize_pause_reason(reason),
         paused_at: now,
         updated_at: now
       }}
    )

    :ok
  end

  defp normalize_pause_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_pause_reason(_reason), do: nil

  defp read_quality_gate_cache do
    case :mnesia.read(@totals_table, @quality_gate_cache_key) do
      [{@totals_table, @quality_gate_cache_key, cache}] -> cache
      [] -> nil
    end
  end

  defp read_quality_gate_comment_keys do
    case :mnesia.read(@totals_table, @quality_gate_comment_keys_key) do
      [{@totals_table, @quality_gate_comment_keys_key, %MapSet{} = keys}] -> keys
      _ -> nil
    end
  end

  defp scoped_records(table, repo_key) do
    :mnesia.match_object({table, :_, repo_key, :_, :_})
    |> Enum.map(fn {^table, _key, ^repo_key, _id, record} -> record end)
  end

  defp all_scoped_records(table) do
    :mnesia.match_object({table, :_, :_, :_, :_})
    |> Enum.map(fn {^table, _key, _repo_key, _id, record} -> record end)
  end

  defp all_eval_log_records(table, repo_key) do
    :mnesia.match_object({table, :_, repo_key, :_, :_, :_, :_, :_, :_})
    |> Enum.map(fn {^table, _key, ^repo_key, _eval_id, _outcome, _agent_kind, _issue_label, _date, record} -> record end)
    |> Enum.uniq_by(&Map.get(&1, :eval_id))
  end

  defp all_learning_records(table, repo_key) do
    :mnesia.match_object({table, :_, repo_key, :_, :_})
    |> Enum.map(fn {^table, _key, ^repo_key, _created_at, record} -> record end)
  end

  defp normalize_repo_key(repo_key) when is_binary(repo_key) do
    case String.trim(repo_key) do
      "" -> {:error, :invalid_repo_key}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_repo_key(_repo_key), do: {:error, :invalid_repo_key}

  defp scoped_key(repo_key, id), do: {repo_key, id}

  defp rework_base_key(repo_key, issue_id), do: {:rework_base, repo_key, issue_id}

  defp read_rework_base(repo_key, issue_id) do
    case :mnesia.read(@totals_table, rework_base_key(repo_key, issue_id)) do
      [{@totals_table, _key, head}] when is_binary(head) -> head
      _ -> nil
    end
  end

  defp forced_key(repo_key), do: {:forced, repo_key}

  defp write_forced(repo_key, entries) when map_size(entries) == 0 do
    :mnesia.delete({@totals_table, forced_key(repo_key)})
    :ok
  end

  defp write_forced(repo_key, entries) do
    :mnesia.write({@totals_table, forced_key(repo_key), entries})
    :ok
  end

  defp read_forced(repo_key) do
    case :mnesia.read(@totals_table, forced_key(repo_key)) do
      [{@totals_table, _key, entries}] when is_map(entries) -> entries
      _ -> %{}
    end
  end

  defp own_state_move_key(issue_id), do: {:own_state_move, issue_id}

  defp merged_wait_key(issue_id), do: {:merged_wait, issue_id}

  defp read_own_state_move(issue_id) do
    case :mnesia.read(@totals_table, own_state_move_key(issue_id)) do
      [{@totals_table, _key, %DateTime{} = at}] -> at
      _ -> nil
    end
  end

  defp normalize_update(attrs, immutable_fields) do
    attrs
    |> normalize_record()
    |> Map.drop(immutable_fields)
  end

  defp normalize_record(record) when is_map(record) do
    Map.new(record)
  end

  defp normalize_eval_log_record(record, repo_key) when is_map(record) do
    record
    |> normalize_record()
    |> Map.put(:repo_key, repo_key)
    |> Map.put_new(:issue_labels, [])
    |> Map.update!(:issue_labels, &normalize_issue_labels/1)
    |> Map.put_new(:logged_at, DateTime.utc_now())
    |> Map.put_new_lazy(:date, fn -> eval_log_date(Map.get(record, :logged_at)) end)
    |> Map.update!(:date, &eval_log_date/1)
    |> Map.put_new(:outcome, "unknown")
    |> Map.put_new(:agent_kind, "unknown")
  end

  defp normalize_issue_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_issue_labels(_labels), do: []

  defp eval_log_date(%Date{} = date), do: date
  defp eval_log_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp eval_log_date(_value), do: Date.utc_today()

  defp eval_log_issue_label_index_values(%{issue_labels: labels}) when is_list(labels) and labels != [],
    do: labels

  defp eval_log_issue_label_index_values(_record), do: [nil]

  defp write_eval_log_records(repo_key, eval_id, normalized) do
    key = scoped_key(repo_key, eval_id)
    :mnesia.delete({@eval_logs_table, key})

    normalized
    |> eval_log_issue_label_index_values()
    |> Enum.each(&write_eval_log_record(repo_key, eval_id, normalized, &1))

    :ok
  end

  defp write_eval_log_record(repo_key, eval_id, normalized, issue_label) do
    :mnesia.write({
      @eval_logs_table,
      scoped_key(repo_key, eval_id),
      repo_key,
      eval_id,
      normalized.outcome,
      normalized.agent_kind,
      issue_label,
      normalized.date,
      normalized
    })
  end

  defp normalize_learning_records(records) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case normalize_learning_record(record) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_learning_record(%{id: id, repo_key: repo_key, created_at: %DateTime{} = created_at} = record)
       when is_binary(id) and is_binary(repo_key) do
    trimmed_repo_key = String.trim(repo_key)

    cond do
      String.trim(id) == "" -> {:error, :invalid_learning_id}
      trimmed_repo_key == "" -> {:error, :invalid_learning_repo_key}
      true -> {:ok, record |> normalize_record() |> Map.put(:repo_key, trimmed_repo_key) |> Map.put(:created_at, created_at)}
    end
  end

  defp normalize_learning_record(%{repo: repo}) when is_binary(repo), do: {:error, :missing_repo_key}

  defp normalize_learning_record(_record), do: {:error, :invalid_learning_record}

  defp write_learning_record(%{id: id, repo_key: repo_key, created_at: created_at} = record) do
    :mnesia.write({@learnings_table, scoped_key(repo_key, id), repo_key, created_at, record})
  end

  defp prune_learning_records(repo_key, max_total_per_repo) do
    records =
      @learnings_table
      |> all_learning_records(repo_key)
      |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :created_at)), :asc)

    records
    |> Enum.take(max(0, length(records) - max_total_per_repo))
    |> Enum.each(fn %{id: id} -> :mnesia.delete({@learnings_table, scoped_key(repo_key, id)}) end)

    :ok
  end

  defp filter_learnings(records, opts) do
    repo_key_filter = Keyword.get(opts, :repo_key)
    repo_filter = Keyword.get(opts, :repo)

    Enum.filter(records, fn record ->
      matches_value?(Map.get(record, :repo_key), repo_key_filter) and
        matches_value?(Map.get(record, :repo), repo_filter) and
        matches_learning_tag?(Map.get(record, :tags, []), Keyword.get(opts, :tag))
    end)
  end

  defp matches_learning_tag?(_tags, nil), do: true
  defp matches_learning_tag?(tags, tag) when is_list(tags) and is_binary(tag), do: tag in tags
  defp matches_learning_tag?(_tags, _tag), do: false

  defp limit_learnings(records, :all), do: records

  defp limit_learnings(records, limit) when is_integer(limit) and limit >= 0 do
    Enum.take(records, limit)
  end

  defp limit_learnings(records, _limit), do: records

  defp filter_eval_logs(records, opts) do
    Enum.filter(records, fn record ->
      eval_log_matches?(record, opts)
    end)
  end

  defp eval_log_matches?(record, opts) do
    matches_value?(Map.get(record, :outcome), Keyword.get(opts, :outcome)) and
      matches_value?(Map.get(record, :agent_kind), Keyword.get(opts, :agent_kind)) and
      matches_issue_label?(Map.get(record, :issue_labels, []), Keyword.get(opts, :issue_label)) and
      matches_date_range?(Map.get(record, :date), Keyword.get(opts, :date_from), Keyword.get(opts, :date_to)) and
      matches_value?(Map.get(record, :session_id), Keyword.get(opts, :session_id))
  end

  defp matches_value?(_value, nil), do: true
  defp matches_value?(value, value), do: true
  defp matches_value?(_value, _filter), do: false

  defp matches_issue_label?(_labels, nil), do: true
  defp matches_issue_label?(labels, issue_label) when is_list(labels), do: issue_label in labels
  defp matches_issue_label?(_labels, _issue_label), do: false

  defp matches_date_range?(%Date{} = date, date_from, date_to) do
    after_from? =
      case date_from do
        %Date{} = from -> Date.compare(date, from) in [:gt, :eq]
        _ -> true
      end

    before_to? =
      case date_to do
        %Date{} = to -> Date.compare(date, to) in [:lt, :eq]
        _ -> true
      end

    after_from? and before_to?
  end

  defp matches_date_range?(_date, _date_from, _date_to), do: true

  defp limit_eval_logs(records, :all), do: records

  defp limit_eval_logs(records, limit) when is_integer(limit) and limit >= 0 do
    Enum.take(records, limit)
  end

  defp limit_eval_logs(records, _limit), do: records

  defp interrupt_running_records(repo_key, error, now) do
    @runs_table
    |> scoped_records(repo_key)
    |> Enum.reduce([], &interrupt_running_record(&1, error, now, &2))
  end

  # Only after the writes committed, as `index_run/4`.
  defp index_interrupted_runs({:ok, interrupted}) do
    Enum.each(interrupted, fn {repo_key, run_id, record} -> RunIndex.put(repo_key, run_id, record) end)
    {:ok, length(interrupted)}
  end

  defp index_interrupted_runs(error), do: error

  # Auto Review QA runs use their own `qa_running` status so executor lookups never
  # mistake them for agent runs; a restart interrupts them all the same.
  defp interrupt_running_record(%{status: status} = record, error, now, interrupted) when status in ["running", "qa_running"] do
    write_interrupted_run_record(record, error, now, interrupted)
  end

  defp interrupt_running_record(_record, _error, _now, interrupted), do: interrupted

  defp write_interrupted_run_record(record, error, now, interrupted) do
    case Map.get(record, :run_id) do
      run_id when is_binary(run_id) ->
        updated =
          Map.merge(record, %{
            status: "failure",
            ended_at: now,
            error: error,
            updated_at: now
          })

        repo_key = Map.fetch!(record, :repo_key)
        :mnesia.write({@runs_table, scoped_key(repo_key, run_id), repo_key, run_id, updated})
        [{repo_key, run_id, updated} | interrupted]

      malformed_run_id ->
        Logger.warning("Skipping malformed running run store record during startup recovery run_id=#{inspect(malformed_run_id)}")
        interrupted
    end
  end

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_key(_datetime), do: 0

  defp unwrap_nested_error({:error, reason}), do: {:error, reason}
  defp unwrap_nested_error(other), do: other

  @impl true
  def terminate(reason, %State{dir: dir}) do
    if reason not in [:normal, :shutdown] do
      Logger.warning("RunStore stopped unexpectedly dir=#{dir} reason=#{inspect(reason)}")
    end

    :ok
  end
end
