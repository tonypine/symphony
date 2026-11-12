defmodule SymphonyElixir.RunStore do
  @moduledoc """
  Durable store for orchestrator run history, retry queue entries, and totals.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Paths, Pauses, TicketMerge, TicketState}
  alias SymphonyElixir.RunStore.RunIndex
  alias SymphonyElixir.TicketEvents.Event

  @runs_table :symphony_run_store_runs
  @retry_table :symphony_run_store_retries
  @totals_table :symphony_run_store_totals
  @pr_review_table :symphony_run_store_pr_reviews
  @ci_check_table :symphony_run_store_ci_checks
  # A ticket's one record, keyed by its id alone: issue id -> the record, with its repository as a
  # field routing writes (`ticket_index_marker/0`). The (repository, ticket) table the releases
  # before kept is deleted by this release's first start (`contract_ticket_key/0`).
  @ticket_index_table :symphony_run_store_ticket_index
  @ticket_index_marker "ticket_index_v2"
  @pair_table :symphony_run_store_ticket_states
  @merge_marker "records_merged_v1"
  @pair_key_dropped_marker "ticket_pair_key_dropped_v1"
  @ticket_events_table :symphony_run_store_ticket_events
  @artifacts_table :symphony_run_store_artifacts
  @ticket_pull_request_table :symphony_run_store_ticket_pull_requests
  @verification_allocation_table :symphony_run_store_verification_allocations
  @eval_logs_table :symphony_run_store_eval_logs
  @pause_table :symphony_run_store_pause
  @learnings_table :symphony_run_store_learnings
  # The saved views of the Tickets page, by id (`SymphonyElixir.Views`).
  @views_table :symphony_run_store_views
  @eval_log_attributes [:key, :repo_key, :eval_id, :outcome, :agent_kind, :issue_label, :date, :record]
  @eval_log_indexes [:repo_key, :outcome, :agent_kind, :issue_label, :date]
  @learning_attributes [:key, :repo_key, :created_at, :record]
  @learning_indexes [:repo_key, :created_at]
  @ticket_event_attributes [:key, :repo_key, :issue_id, :run_id, :type, :seq, :record]
  @ticket_event_indexes [:repo_key, :run_id, :type]
  @tables [
    {@runs_table, [:key, :repo_key, :run_id, :record], [index: [:repo_key]]},
    {@retry_table, [:key, :repo_key, :issue_id, :record], [index: [:repo_key]]},
    {@totals_table, [:key, :record], []},
    {@pr_review_table, [:key, :repo_key, :issue_id, :record], [index: [:repo_key]]},
    {@ci_check_table, [:key, :repo_key, :issue_id, :record], [index: [:repo_key]]},
    {@ticket_index_table, [:issue_id, :repo_key, :record], []},
    {@ticket_pull_request_table, [:key, :repo_key, :issue_id, :record], [index: [:repo_key]]},
    {@verification_allocation_table, [:key, :repo_key, :run_id, :record], [index: [:repo_key]]},
    {@pause_table, [:key, :record], []},
    {@eval_logs_table, @eval_log_attributes, [type: :bag, index: @eval_log_indexes]},
    {@learnings_table, @learning_attributes, [index: @learning_indexes]},
    {@ticket_events_table, @ticket_event_attributes, [type: :bag, index: @ticket_event_indexes]},
    {@artifacts_table, [:key, :repo_key, :issue_id, :record], [index: [:repo_key]]},
    {@views_table, [:id, :record], []}
  ]
  @data_tables Enum.map(@tables, fn {table, _attributes, _opts} -> table end)
  @codex_totals_key :codex_totals
  # The operator pause's old row: moved onto Symphony's pause at start (`move_legacy_pause/0`),
  # never written. The move marks the pauses' backfill step for it done
  # (`SymphonyElixir.Pauses.Backfill`).
  @pause_key :dispatch_pause
  @pause_backfill_marker "pause_backfill_symphony_v1"
  @director %{kind: :person, name: "Director"}
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
  # A store written before the transcript cap can take far longer than a few seconds to load, and
  # its rows are trimmed only once it has loaded.
  @table_load_timeout_ms 120_000
  @table_load_progress_ms 10_000

  @typedoc "What a pause update's function returns: a pause to write (nil clears it), or nothing to write."
  @type pause_update ::
          {:write, map() | nil, term()}
          | {:write, map() | nil, [Event.t()], term()}
          | {:ok, term()}
          | {:error, term()}

  @typedoc """
  What a ticket's pause update's function returns: a pause to write (nil clears it) with the events
  to append to the ticket in the same transaction, or nothing to write.
  """
  @type ticket_pause_update :: {:write, map() | nil, [Event.t()], term()} | {:ok, term()} | {:error, term()}

  @typedoc """
  What a ticket's question update's function returns: a question to put on the record and the pause
  to write with it, with the events to append in the same transaction, or nothing to write.
  """
  @type ticket_question_update :: {:write, map(), map() | nil, [Event.t()], term()} | {:ok, term()} | {:error, term()}

  defmodule State do
    @moduledoc false

    defstruct [:dir]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # The store's name is registered before `init/1` has created its tables, so a caller that finds
  # the store still starting waits for it (`handle_call(:ready, ...)` answers once `init/1` is
  # done); a store that finished starting is marked ready, and is not asked again.
  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        await_ready(pid)

      _ ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          # Another caller started it a moment ago: its `init/1` may still be running.
          {:error, {:already_started, pid}} -> await_ready(pid)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp await_ready(pid) do
    if pid == self() or :persistent_term.get({__MODULE__, :ready}, nil) == pid do
      :ok
    else
      try do
        GenServer.call(pid, :ready, :infinity)
      catch
        :exit, _reason -> ensure_started()
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

  @spec put_ticket_state(map()) :: :ok | {:error, term()}
  def put_ticket_state(%{repo_key: repo_key, issue_id: issue_id} = record) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      normalized =
        record
        |> normalize_record()
        |> Map.put(:repo_key, repo_key)
        |> TicketState.normalize()

      durable_transaction(fn ->
        write_ticket_record(repo_key, issue_id, normalized)
        :ok
      end)
    end
  end

  def put_ticket_state(%{issue_id: issue_id}) when is_binary(issue_id), do: {:error, :missing_repo_key}

  def put_ticket_state(_record), do: {:error, :invalid_ticket_state_record}

  @doc "The ticket `issue_id`'s one record, or nil; its repository is the record's `repo_key`."
  @spec get_ticket_state(String.t()) :: map() | nil | {:error, term()}
  def get_ticket_state(issue_id) when is_binary(issue_id) do
    with :ok <- ensure_started() do
      transaction(fn -> read_ticket_record(nil, issue_id) end)
    end
  end

  def get_ticket_state(_issue_id), do: {:error, :invalid_issue_id}

  @doc """
  Merges `attrs` into the ticket `issue_id`'s record; `{:error, :ticket_state_not_found}` when it
  has none. A `repo_key` in `attrs` is the route observation writes: the same record moves to it.
  """
  @spec update_ticket_state(String.t(), map()) :: :ok | {:error, term()}
  def update_ticket_state(issue_id, attrs) when is_binary(issue_id) and is_map(attrs) do
    with :ok <- valid_route(attrs),
         :ok <- ensure_started() do
      update_ticket_state_record(issue_id, attrs)
      |> unwrap_nested_error()
    end
  end

  def update_ticket_state(_issue_id, _attrs), do: {:error, :invalid_ticket_state_record}

  @doc "Deletes the ticket `issue_id`'s record."
  @spec delete_ticket_state(String.t()) :: :ok | {:error, term()}
  def delete_ticket_state(issue_id) when is_binary(issue_id) do
    with :ok <- ensure_started() do
      durable_transaction(fn -> delete_ticket_record(issue_id) end)
    end
  end

  def delete_ticket_state(_issue_id), do: {:error, :invalid_issue_id}

  @spec list_ticket_states() :: [map()] | {:error, term()}
  def list_ticket_states, do: list_ticket_states(Config.repo_key!())

  @spec list_ticket_states(String.t()) :: [map()] | {:error, term()}
  def list_ticket_states(repo_key) when is_binary(repo_key) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn ->
        repo_key
        |> listed_ticket_records()
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :updated_at)), :desc)
      end)
    end
  end

  @spec list_all_ticket_states() :: [map()] | {:error, term()}
  def list_all_ticket_states do
    with :ok <- ensure_started() do
      transaction(fn ->
        :all
        |> listed_ticket_records()
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :updated_at)), :desc)
      end)
    end
  end

  @doc """
  Appends `event` (`SymphonyElixir.TicketEvents.Event`) to its ticket's event stream in one durable
  transaction, and returns the event as stored. The transaction holds the ticket record's write
  lock, so concurrent appends to one ticket are serialized: the event's `seq` is one past the
  highest the ticket has used, and the record's `event_seq` takes it (the record is created when
  none exists). An event with no `phase` takes the record's. An event whose idempotency key an
  event of the ticket already holds is not written: that event is returned instead.
  """
  @spec append_ticket_event(Event.t()) :: {:ok, Event.t()} | {:error, term()}
  def append_ticket_event(%Event{} = event) do
    case append_ticket_events([event]) do
      {:ok, [stored]} -> {:ok, stored}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Appends one ticket's `events`, in order, in one durable transaction (as `append_ticket_event/1`
  each), and returns them as stored. Events of more than one ticket are refused.
  """
  @spec append_ticket_events([Event.t()]) :: {:ok, [Event.t()]} | {:error, term()}
  def append_ticket_events([]), do: {:ok, []}

  def append_ticket_events([%Event{repo_key: repo_key, issue_id: issue_id} | _] = events) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- one_ticket(events, repo_key, issue_id),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_ticket_events(repo_key, issue_id, events) end)
    end
  end

  def append_ticket_events(_events), do: {:error, :invalid_ticket_event}

  @doc """
  Adds fields to the payloads of the ticket's stored events, in one durable transaction: `upgrades`
  maps an event's `seq` to the fields to add. A format upgrade of events an earlier release wrote
  (`SymphonyElixir.TicketEvents.Backfill`), and with `attach_ticket_event_artifacts/3` the only write
  that touches a stored event: everything
  else about each event stays, and a `seq` the ticket does not hold is ignored.
  """
  @spec upgrade_ticket_events(String.t(), %{optional(non_neg_integer()) => map()}) :: :ok | {:error, term()}
  def upgrade_ticket_events(_issue_id, upgrades) when map_size(upgrades) == 0, do: :ok

  def upgrade_ticket_events(issue_id, upgrades) when is_binary(issue_id) and is_map(upgrades) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        @ticket_events_table
        |> :mnesia.read(issue_id, :write)
        |> Enum.each(&upgrade_ticket_event_row(&1, upgrades))
      end)
    end
  end

  @doc """
  Adds `artifact_ids` to the artifacts of the ticket's stored event `seq`, in one durable transaction:
  files that exist only after the event was written (`SymphonyElixir.TicketEvents.attach_artifacts/2`).
  Everything else about the event stays, an id it already holds is not added twice, and a `seq` the
  ticket does not hold is ignored.
  """
  @spec attach_ticket_event_artifacts(String.t(), non_neg_integer(), [String.t()]) :: :ok | {:error, term()}
  def attach_ticket_event_artifacts(issue_id, seq, artifact_ids) when is_binary(issue_id) and is_integer(seq) and is_list(artifact_ids) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        @ticket_events_table
        |> :mnesia.read(issue_id, :write)
        |> Enum.filter(&(elem(&1, 6) == seq))
        |> Enum.each(&attach_ticket_event_row(&1, artifact_ids))
      end)
    end
  end

  @doc """
  The events of the ticket `issue_id`, oldest first by `at`, then `seq`. `opts`: `types:` (the
  types to keep) and `run_id:` (the run to keep).
  """
  @spec list_ticket_events(String.t(), keyword()) :: [Event.t()] | {:error, term()}
  def list_ticket_events(issue_id, opts) when is_binary(issue_id) and is_list(opts) do
    with :ok <- ensure_started() do
      transaction(fn -> issue_id |> read_ticket_events() |> filter_ticket_events(opts) end)
    end
  end

  def list_ticket_events(_issue_id, _opts), do: {:error, :invalid_issue_id}

  @doc """
  The events of every ticket, and of Symphony's own stream (`list_subject_events/2`), in no
  particular order: the Journal's read across tickets (`SymphonyElixir.TicketEvents.Journal`). A
  repository's own stream is left out. `opts`: `types:`, as `list_ticket_events/2` takes them.
  """
  @spec list_all_ticket_events(keyword()) :: [Event.t()] | {:error, term()}
  def list_all_ticket_events(opts \\ []) when is_list(opts) do
    with :ok <- ensure_started() do
      transaction(fn ->
        :mnesia.foldl(&journal_event_row/2, [], @ticket_events_table)
        |> filter_ticket_events(opts)
      end)
    end
  end

  @doc """
  Writes the artifact row (`SymphonyElixir.Artifacts`) keyed by its `id`, replacing the one the id
  held. The row's `repo_key` and `issue_id` are the artifact's: its first ingest's ticket.
  """
  @spec put_artifact(map()) :: :ok | {:error, term()}
  def put_artifact(%{id: id, issue_id: issue_id} = artifact) when is_binary(id) and is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(Map.get(artifact, :repo_key)),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_artifact(%{artifact | repo_key: repo_key}) end)
    end
  end

  def put_artifact(_artifact), do: {:error, :invalid_artifact}

  @doc "The artifact row keyed by `id`, or nil."
  @spec get_artifact(String.t()) :: map() | nil | {:error, term()}
  def get_artifact(id) when is_binary(id) do
    with :ok <- ensure_started() do
      transaction(fn -> read_artifact(id, :read) end)
    end
  end

  @doc """
  Runs `fun` on the artifact row keyed by `id` (nil when there is none) in one durable transaction
  that holds the row's write lock, so concurrent updates of one id are serialized. `{:ok, artifact}`
  writes the artifact and returns it; `{:error, reason}` writes nothing and is returned. `fun` may run
  more than once when the transaction restarts, so its side effects must be idempotent.
  """
  @spec update_artifact(String.t(), (map() | nil -> {:ok, map()} | {:error, term()})) :: {:ok, map()} | {:error, term()}
  def update_artifact(id, fun) when is_binary(id) and is_function(fun, 1) do
    with :ok <- ensure_started() do
      durable_transaction(fn -> write_updated_artifact(id, fun) end)
    end
  end

  @doc """
  The artifact rows, oldest `captured_at` first. `opts`: `repo_key:` and `issue_id:` keep the rows a
  ticket of that repo (and of that issue) ingested, whether or not it was the first; `expired:` keeps
  the rows whose `expired` is that boolean.
  """
  @spec list_artifacts(keyword()) :: [map()] | {:error, term()}
  def list_artifacts(opts) when is_list(opts) do
    with :ok <- ensure_started() do
      transaction(fn ->
        all_artifact_records()
        |> Enum.filter(&artifact_matches?(&1, opts))
        |> Enum.sort_by(&{datetime_sort_key(Map.get(&1, :captured_at)), &1.id})
      end)
    end
  end

  @doc """
  Writes the ticket's pull request record (`SymphonyElixir.TicketPullRequest`), replacing the one
  the ticket held.
  """
  @spec put_ticket_pull_request(map()) :: :ok | {:error, term()}
  def put_ticket_pull_request(%{repo_key: repo_key, issue_id: issue_id} = record) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      normalized = record |> normalize_record() |> Map.put(:repo_key, repo_key)

      durable_transaction(fn ->
        :mnesia.write({@ticket_pull_request_table, scoped_key(repo_key, issue_id), repo_key, issue_id, normalized})
        :ok
      end)
    end
  end

  def put_ticket_pull_request(_record), do: {:error, :invalid_ticket_pull_request_record}

  @doc """
  Writes the ticket's pull request record only when the ticket has none, in one durable
  transaction: `{:ok, :inserted}`, or `{:ok, :exists}` leaving the record it holds as it is.
  """
  @spec insert_ticket_pull_request(map()) :: {:ok, :inserted | :exists} | {:error, term()}
  def insert_ticket_pull_request(%{repo_key: repo_key, issue_id: issue_id} = record) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      normalized = record |> normalize_record() |> Map.put(:repo_key, repo_key)

      durable_transaction(fn -> insert_new_ticket_pull_request(repo_key, issue_id, normalized) end)
    end
  end

  def insert_ticket_pull_request(_record), do: {:error, :invalid_ticket_pull_request_record}

  @spec get_ticket_pull_request(String.t(), String.t()) :: map() | nil | {:error, term()}
  def get_ticket_pull_request(repo_key, issue_id) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn -> read_ticket_pull_request(repo_key, issue_id) end)
    end
  end

  def get_ticket_pull_request(_repo_key, _issue_id), do: {:error, :invalid_issue_id}

  @spec list_ticket_pull_requests(String.t()) :: [map()] | {:error, term()}
  def list_ticket_pull_requests(repo_key) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      transaction(fn ->
        @ticket_pull_request_table
        |> scoped_records(repo_key)
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :updated_at)), :desc)
      end)
    end
  end

  @doc """
  Sets `state` on every pull request record of `repo_key` whose PR is `pr_url`, in one durable
  transaction, and returns how many it changed. A record already in `state` is left as it is.
  """
  @spec finish_ticket_pull_request(String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def finish_ticket_pull_request(repo_key, pr_url, state, %DateTime{} = at) when is_binary(pr_url) and is_binary(state) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_finished_pull_requests(repo_key, pr_url, state, at) end)
    end
  end

  def finish_ticket_pull_request(_repo_key, _pr_url, _state, _at), do: {:error, :invalid_ticket_pull_request_record}

  @doc """
  Writes the PR and CI watcher's fact record (`TicketState.put_pr_watch/3`) on the ticket's record,
  creating the record when none exists (a ticket moved by hand has none) and stamping its identifier
  when the record has none. Nil clears it. The read-modify-write runs in one durable transaction,
  so it never drops what another writer put on the record.
  """
  @spec put_ticket_pr_watch(String.t(), String.t(), String.t() | nil, map() | nil) :: :ok | {:error, term()}
  def put_ticket_pr_watch(repo_key, issue_id, issue_identifier, pr_watch) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_ticket_pr_watch(repo_key, issue_id, issue_identifier, pr_watch) end)
      |> unwrap_nested_error()
    end
  end

  def put_ticket_pr_watch(_repo_key, _issue_id, _issue_identifier, _pr_watch), do: {:error, :invalid_issue_id}

  @doc """
  Marks a projection of the ticket's record to Linear as failed (`TicketState.mark_projection/4`).
  A record the store does not have has nothing to project, so it is a no-op. The read-modify-write
  runs in one durable transaction, so a mark written meanwhile is never overwritten.
  """
  @spec mark_ticket_projection(String.t(), String.t(), TicketState.projection_name(), term()) :: :ok | {:error, term()}
  def mark_ticket_projection(repo_key, issue_id, projection, error) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      mark = &TicketState.mark_projection(&1, projection, error)
      durable_transaction(fn -> write_ticket_projection(repo_key, issue_id, mark) end)
    end
  end

  @doc """
  Drops `mark`, a mark of the ticket's record projected again (`TicketState.clear_projection/2`): a
  newer mark of the same projection stays. The read-modify-write runs in one durable transaction.
  """
  @spec clear_ticket_projection(String.t(), String.t(), TicketState.projection()) :: :ok | {:error, term()}
  def clear_ticket_projection(repo_key, issue_id, mark) when is_binary(issue_id) and is_map(mark) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      clear = &TicketState.clear_projection(&1, mark)
      durable_transaction(fn -> write_ticket_projection(repo_key, issue_id, clear) end)
    end
  end

  @doc """
  Writes the ticket's self-heal bookkeeping (the broken component, the repo that owns the fix, the
  failure signature, the fix ticket and the retry count) into the ticket's record, creating the
  record when none exists. The read-modify-write runs in one durable transaction.
  """
  @spec record_ticket_self_heal(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def record_ticket_self_heal(repo_key, issue_id, attrs) when is_binary(issue_id) and is_map(attrs) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_ticket_self_heal(repo_key, issue_id, attrs) end)
      |> unwrap_nested_error()
    end
  end

  def record_ticket_self_heal(_repo_key, _issue_id, _attrs), do: {:error, :invalid_issue_id}

  @doc """
  Appends the decisions in `entries` the ticket's record does not hold yet
  (`TicketState.put_decisions/4`), and returns the record's whole list. A record that holds no
  decision yet takes the `backfill` ones first. A record is created only when a decision is added.
  The read-modify-write runs in one durable transaction, so two writers never record a decision
  twice.
  """
  @spec record_ticket_decisions(String.t(), String.t(), [map()], [map()]) ::
          {:ok, [TicketState.decision()]} | {:error, term()}
  def record_ticket_decisions(repo_key, issue_id, entries, backfill)
      when is_binary(issue_id) and is_list(entries) and is_list(backfill) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_ticket_decisions(repo_key, issue_id, entries, backfill) end)
      |> unwrap_nested_error()
    end
  end

  def record_ticket_decisions(_repo_key, _issue_id, _entries, _backfill), do: {:error, :invalid_issue_id}

  @doc """
  Marks the path-unlock grants in `ids` as used by `run_id` in the ticket's record
  (`TicketState.claim_path_unlocks/4`), creating the record when none exists, and returns the ones
  no run had used. The read-modify-write runs in one durable transaction, so two runs never both
  claim a grant.
  """
  @spec claim_path_unlocks(String.t(), String.t(), [String.t()], String.t() | nil) ::
          {:ok, [String.t()]} | {:error, term()}
  def claim_path_unlocks(repo_key, issue_id, ids, run_id) when is_binary(issue_id) and is_list(ids) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_path_unlock_claim(repo_key, issue_id, ids, run_id) end)
      |> unwrap_nested_error()
    end
  end

  def claim_path_unlocks(_repo_key, _issue_id, _ids, _run_id), do: {:error, :invalid_issue_id}

  @doc """
  Drops the stale fix-ticket pointer from the ticket's self-heal bookkeeping, keeping the broken
  component, the failure signature and the retry count, so a block that recurs after the fix landed
  is compared against the last failure instead of judged as a first one. A record the store does not
  have yet has nothing to drop, so it is a no-op.
  """
  @spec clear_ticket_fix_ticket(String.t(), String.t()) :: :ok | {:error, term()}
  def clear_ticket_fix_ticket(repo_key, issue_id) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_clear_ticket_fix_ticket(repo_key, issue_id) end)
      |> unwrap_nested_error()
    end
  end

  def clear_ticket_fix_ticket(_repo_key, _issue_id), do: {:error, :invalid_issue_id}

  @doc """
  Writes the CI state (`running` / `green` / `red`) of one PR head into the ticket's record, with
  last-write-wins ordering by `at`. The read-modify-write runs in one durable transaction.
  Returns `{:ok, :changed}` when the head's state changed (`:unchanged` when it repeated,
  `:stale` when an older write arrived after a newer one), so the caller projects the CI label only
  on `:changed`.
  """
  @spec record_ci_state(String.t(), String.t(), String.t() | nil, String.t(), DateTime.t()) ::
          {:ok, :changed | :unchanged | :stale} | {:error, term()}
  def record_ci_state(repo_key, issue_id, head_sha, status, at)
      when is_binary(issue_id) and is_binary(status) and is_struct(at, DateTime) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_ci_state(repo_key, issue_id, head_sha, status, at) end)
      |> unwrap_nested_error()
    end
  end

  def record_ci_state(_repo_key, _issue_id, _head_sha, _status, _at), do: {:error, :invalid_ci_state}

  @doc """
  Records the phase a ticket's CI Fix stay came from, creating the record when none exists. A
  `nil` origin clears it (the mechanical repair has returned the ticket). The read-modify-write
  runs in one durable transaction.
  """
  @spec set_ci_fix_origin(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def set_ci_fix_origin(repo_key, issue_id, origin) when is_binary(issue_id) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_ci_fix_origin(repo_key, issue_id, origin) end)
      |> unwrap_nested_error()
    end
  end

  def set_ci_fix_origin(_repo_key, _issue_id, _origin), do: {:error, :invalid_issue_id}

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

  @doc """
  Deprecated, kept for one release: the Director's Pause and Resume of all dispatch are reasons of
  Symphony's pause (`SymphonyElixir.Pauses`, subject `:symphony`). `true` sets the reason
  `reason` gives (`Pauses.dispatch_reason/1`); `false` clears the Director's and an update's.
  """
  @spec set_paused(boolean(), String.t() | nil) :: :ok | {:error, term()}
  def set_paused(true, reason) do
    with {:ok, _pause} <- Pauses.set(:symphony, Pauses.dispatch_reason(reason), set_by: @director), do: :ok
  end

  def set_paused(false, _reason) do
    with {:ok, _pause} <- Pauses.clear_reasons(:symphony, &(&1.kind in [:person, :build]), by: @director), do: :ok
  end

  def set_paused(_paused, _reason), do: {:error, :invalid_pause_state}

  @doc """
  Deprecated, kept for one release: Symphony's pause as the operator pause read before
  (`Pauses.dispatch_status/1`).
  """
  @spec get_paused() :: map() | {:error, term()}
  def get_paused do
    with {:ok, pause} <- Pauses.get(:symphony), do: Pauses.dispatch_status(pause)
  end

  @doc """
  Moves the operator pause's old row, which the releases before Symphony's pause wrote, onto
  Symphony's pause, whatever the pauses' backfill did: a paused row sets its reason
  (`Pauses.dispatch_reason/1`, the Director's, at the row's time), so an `updating to v…` row
  waits on that build. Then the row is deleted and the backfill's step for it marked done, so
  neither reads it again. A start that stops before the delete finds the row and sets the same
  reason again.
  """
  @spec move_legacy_pause() :: :ok | {:error, term()}
  def move_legacy_pause do
    with :ok <- ensure_started(),
         %{} = row <- transaction(fn -> read_pause_record() end),
         {:ok, _pause} <- set_legacy_pause(row) do
      durable_transaction(&delete_legacy_pause/0)
    end
  end

  defp set_legacy_pause(%{paused: true} = row) do
    Pauses.set(:symphony, Pauses.dispatch_reason(row.reason), set_by: @director, at: row.paused_at || DateTime.utc_now())
  end

  defp set_legacy_pause(_row), do: {:ok, nil}

  defp delete_legacy_pause do
    :mnesia.delete({@pause_table, @pause_key})
    if is_nil(read_marker(@pause_backfill_marker)), do: :mnesia.write({@totals_table, {:marker, @pause_backfill_marker}, DateTime.utc_now()})
    :ok
  end

  @doc """
  Runs `fun` on the pause of `repo_key`'s ticket `issue_id` (`SymphonyElixir.Pauses`, its only
  writer), nil when it has none, in one durable transaction that holds the record's write lock, so
  concurrent pause writes to one ticket are serialized and none is lost.
  `{:write, pause, events, result}` writes `pause` (nil clears it) with `updated_at` `at`, creating
  the record when none exists, appends `events` to the ticket in the same transaction (as
  `append_ticket_events/1` does), and returns `{:ok, result, stored}` with the events as stored: a
  pause never changes without its events, and the events of two writers follow the order their
  changes were written in. `{:ok, result}` writes nothing and returns `{:ok, result, []}`;
  `{:error, reason}` writes nothing and is returned. `fun` may run more than once when the
  transaction restarts, so it must have no side effects.
  """
  @spec update_ticket_pause(String.t(), String.t(), DateTime.t(), (map() | nil -> ticket_pause_update())) ::
          {:ok, term(), [Event.t()]} | {:error, term()}
  def update_ticket_pause(repo_key, issue_id, at, fun) when is_binary(issue_id) and is_function(fun, 1) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_ticket_pause(repo_key, issue_id, at, fun) end)
    end
  end

  def update_ticket_pause(_repo_key, _issue_id, _at, _fun), do: {:error, :invalid_issue_id}

  @doc """
  Runs `fun` on the questions and the pause of `repo_key`'s ticket `issue_id`
  (`SymphonyElixir.Questions`, the questions' only writer) in one durable transaction that holds the
  record's write lock, as `update_ticket_pause/4` does for a pause alone:
  `{:write, question, pause, events, result}` puts `question` on the record
  (`SymphonyElixir.TicketState.put_question/2`) and writes `pause` (nil clears it) with `updated_at`
  `at`, appends `events` in the same transaction and returns `{:ok, result, stored}`, so a question
  and the pause it holds never disagree; `{:ok, result}` writes nothing and returns
  `{:ok, result, []}`; `{:error, reason}` writes nothing and is returned. `fun` may run more than
  once, so it must have no side effects.
  """
  @spec update_ticket_question(
          String.t(),
          String.t(),
          DateTime.t(),
          ([map()], map() | nil -> ticket_question_update())
        ) :: {:ok, term(), [Event.t()]} | {:error, term()}
  def update_ticket_question(repo_key, issue_id, at, fun) when is_binary(issue_id) and is_function(fun, 2) do
    with {:ok, repo_key} <- normalize_repo_key(repo_key),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_ticket_question(repo_key, issue_id, at, fun) end)
    end
  end

  def update_ticket_question(_repo_key, _issue_id, _at, _fun), do: {:error, :invalid_issue_id}

  @doc """
  Runs `fun` on the questions and the pause of `subject`, a repository (`{:repository, repo_key}`)
  or Symphony itself (`:symphony`), in one durable transaction that holds the subject's write locks,
  as `update_ticket_question/4` does for a ticket: `{:write, question, pause, events, result}` puts
  `question` among the subject's questions (by its id), writes `pause` (nil removes it), appends
  `events` to the subject's own event stream (`list_subject_events/2`) and returns
  `{:ok, result, stored}`; `{:ok, result}` writes nothing and returns `{:ok, result, []}`;
  `{:error, reason}` writes nothing and is returned. The questions are kept in the pause table under
  `{:questions, subject}`, next to the subject's pause; no ticket record is made. `fun` may run
  more than once, so it must have no side effects.
  """
  @spec update_subject_question(term(), ([map()], map() | nil -> ticket_question_update())) ::
          {:ok, term(), [Event.t()]} | {:error, term()}
  def update_subject_question(subject, fun) when is_function(fun, 2) do
    with :ok <- valid_pause_subject(subject),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_subject_question(subject, fun) end)
    end
  end

  @doc "The questions of `subject` (see `update_subject_question/2`) as stored, in the order they were asked."
  @spec get_subject_questions(term()) :: [map()] | {:error, term()}
  def get_subject_questions(subject) do
    with :ok <- valid_pause_subject(subject),
         :ok <- ensure_started() do
      transaction(fn -> read_subject_questions(subject) end)
    end
  end

  @doc "Every subject that holds questions (see `update_subject_question/2`), with its questions as stored."
  @spec list_subject_questions() :: [{term(), [map()]}] | {:error, term()}
  def list_subject_questions do
    with :ok <- ensure_started() do
      transaction(fn -> :mnesia.foldl(&subject_questions_row/2, [], @pause_table) |> Enum.sort_by(&subject_sort_key(elem(&1, 0))) end)
    end
  end

  @doc """
  The events of `subject`'s own stream (see `update_subject_question/2`), oldest first by `at`, then
  `seq`. `opts`: `types:` and `run_id:`, as `list_ticket_events/3` takes them.
  """
  @spec list_subject_events(term(), keyword()) :: [Event.t()] | {:error, term()}
  def list_subject_events(subject, opts) when is_list(opts) do
    with :ok <- valid_pause_subject(subject),
         :ok <- ensure_started() do
      transaction(fn -> subject |> read_subject_events() |> filter_ticket_events(opts) end)
    end
  end

  @doc """
  Appends `event` to the reports ledger (`SymphonyElixir.Reports`), a stream of its own that no
  ticket, no subject's questions and the Journal's read across tickets never hold, in one durable
  transaction, and returns it as stored with the ledger's next `seq`. An event whose idempotency key
  the ledger already holds is not written: that event is returned instead.
  """
  @spec append_report_event(Event.t()) :: {:ok, Event.t()} | {:error, term()}
  def append_report_event(%Event{} = event) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        [stored] = write_subject_events(:reports, [event])
        {:ok, stored}
      end)
    end
  end

  @doc "The events of the reports ledger (`append_report_event/1`), oldest first by `at`, then `seq`."
  @spec list_report_events() :: [Event.t()] | {:error, term()}
  def list_report_events do
    with :ok <- ensure_started() do
      transaction(fn -> read_subject_events(:reports) end)
    end
  end

  @doc """
  Runs `fun` on the pause of `subject` (see `get_subject_pause/1`) in one durable transaction that
  holds its row's write lock, as `update_ticket_pause/4` does for a ticket: `{:write, pause, result}`
  writes `pause` (nil removes it) and returns `{:ok, result}`; `{:write, pause, events, result}` also
  appends `events` to the subject's own event stream (`list_subject_events/2`); `{:ok, result}` and
  `{:error, reason}` write nothing and are returned.
  """
  @spec update_subject_pause(term(), (map() | nil -> pause_update())) :: {:ok, term()} | {:error, term()}
  def update_subject_pause(subject, fun) when is_function(fun, 1) do
    with :ok <- valid_pause_subject(subject),
         :ok <- ensure_started() do
      durable_transaction(fn -> write_subject_pause(subject, fun) end)
    end
  end

  @doc """
  The pause of a subject that is not a ticket (`SymphonyElixir.Pauses`): a repository
  (`{:repository, repo_key}`) or Symphony itself (`:symphony`), or nil when it has none. It is kept
  in the pause table under `{:subject, subject}`, next to the operator pause, which keeps its key.
  """
  @spec get_subject_pause(term()) :: map() | nil | {:error, term()}
  def get_subject_pause(subject) do
    with :ok <- valid_pause_subject(subject),
         :ok <- ensure_started() do
      transaction(fn -> read_subject_pause(subject) end)
    end
  end

  @doc "Replaces the pause of `subject` (see `get_subject_pause/1`)."
  @spec put_subject_pause(term(), map()) :: :ok | {:error, term()}
  def put_subject_pause(subject, pause) when is_map(pause) do
    with :ok <- valid_pause_subject(subject),
         :ok <- ensure_started() do
      durable_transaction(fn -> :mnesia.write({@pause_table, {:subject, subject}, pause}) end)
    end
  end

  def put_subject_pause(_subject, _pause), do: {:error, :invalid_pause}

  @doc "Removes the pause of `subject` (see `get_subject_pause/1`); one it has none of is `:ok`."
  @spec delete_subject_pause(term()) :: :ok | {:error, term()}
  def delete_subject_pause(subject) do
    with :ok <- valid_pause_subject(subject),
         :ok <- ensure_started() do
      durable_transaction(fn -> :mnesia.delete({@pause_table, {:subject, subject}}) end)
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

  @doc "Writes a saved view (`SymphonyElixir.Views`) under its id, replacing the one it had."
  @spec put_view(map()) :: :ok | {:error, term()}
  def put_view(%{id: id} = view) when is_binary(id) do
    with :ok <- ensure_started() do
      durable_transaction(fn -> :mnesia.write({@views_table, id, view}) end)
    end
  end

  def put_view(_view), do: {:error, :invalid_view}

  @doc "The saved view with `id`, or nil."
  @spec get_view(String.t()) :: map() | nil | {:error, term()}
  def get_view(id) when is_binary(id) do
    with :ok <- ensure_started() do
      transaction(fn -> read_view(id) end)
    end
  end

  defp read_view(id) do
    case :mnesia.read(@views_table, id) do
      [{@views_table, ^id, view}] -> view
      [] -> nil
    end
  end

  @doc "Every saved view, in no order."
  @spec list_views() :: [map()] | {:error, term()}
  def list_views do
    with :ok <- ensure_started() do
      transaction(fn -> :mnesia.foldl(fn {@views_table, _id, view}, acc -> [view | acc] end, [], @views_table) end)
    end
  end

  @doc "Deletes the saved view with `id`: `{:error, :not_found}` when there is none."
  @spec delete_view(String.t()) :: :ok | {:error, term()}
  def delete_view(id) when is_binary(id) do
    with :ok <- ensure_started() do
      durable_transaction(fn -> delete_view_row(id) end)
    end
  end

  defp delete_view_row(id) do
    case :mnesia.read(@views_table, id) do
      [] -> {:error, :not_found}
      [_view] -> :mnesia.delete({@views_table, id})
    end
  end

  @doc """
  Keeps what Symphony knows of GitHub's updates under `key`: a repository's delivery health
  (`{:health, repo_key}`) or the app repository's newest release (`{:release, "owner/name"}`),
  so a restart keeps them (`SymphonyElixir.PrWatch.Ingest`).
  """
  @spec put_github_updates(term(), map()) :: :ok | {:error, term()}
  def put_github_updates(key, value) when is_map(value) do
    with :ok <- ensure_started() do
      durable_transaction(fn -> :mnesia.write({@totals_table, {:github_updates, key}, value}) end)
    end
  end

  def put_github_updates(_key, _value), do: {:error, :invalid_github_updates}

  @doc "What `put_github_updates/2` kept under `key`, or nil."
  @spec get_github_updates(term()) :: map() | nil | {:error, term()}
  def get_github_updates(key) do
    with :ok <- ensure_started() do
      transaction(fn -> read_github_updates(key) end)
    end
  end

  defp read_github_updates(key) do
    case :mnesia.read(@totals_table, {:github_updates, key}) do
      [{@totals_table, _key, value}] when is_map(value) -> value
      _none -> nil
    end
  end

  @doc """
  Marks the one-time job `name` (such as `ticket_events_backfill_v1`) done at `at`, so a restart
  does not run it again.
  """
  @spec put_marker(String.t(), DateTime.t()) :: :ok | {:error, term()}
  def put_marker(name, %DateTime{} = at) when is_binary(name) do
    with :ok <- ensure_started() do
      durable_transaction(fn -> :mnesia.write({@totals_table, {:marker, name}, at}) end)
    end
  end

  @doc "When `put_marker/2` marked the one-time job `name` done, or nil."
  @spec get_marker(String.t()) :: DateTime.t() | nil | {:error, term()}
  def get_marker(name) when is_binary(name) do
    with :ok <- ensure_started() do
      transaction(fn -> read_marker(name) end)
    end
  end

  @doc """
  The marker (`get_marker/1`) of the by-ticket key's version: set once a start of this release
  found every ticket's one record under its id alone (`contract_ticket_key/0`).
  """
  @spec ticket_index_marker() :: String.t()
  def ticket_index_marker, do: @ticket_index_marker

  @doc """
  The marker (`get_marker/1`) the merge of each ticket's duplicate records set, with its report
  beside it (`get_report/1`, `records.merged`).
  """
  @spec records_merged_marker() :: String.t()
  def records_merged_marker, do: @merge_marker

  @doc """
  Marks the one-time job `name` done at `at` (`put_marker/2`) and keeps its `report` beside the
  marker (`get_report/1`), in one durable transaction: a job whose marker is set has its report.
  """
  @spec put_marker_with_report(String.t(), DateTime.t(), map()) :: :ok | {:error, term()}
  def put_marker_with_report(name, %DateTime{} = at, report) when is_binary(name) and is_map(report) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.write({@totals_table, {:marker, name}, at})
        :mnesia.write({@totals_table, {:report, name}, report})
      end)
    end
  end

  @doc "The report `put_marker_with_report/3` kept for the one-time job `name`, or nil."
  @spec get_report(String.t()) :: map() | nil | {:error, term()}
  def get_report(name) when is_binary(name) do
    with :ok <- ensure_started() do
      transaction(fn -> read_report(name) end)
    end
  end

  @doc """
  The one-time step that moves a ticket's record off the (repository, ticket) key for good
  (`ticket_index_marker/0`), run by every start before the store answers, from whichever release
  wrote the store. A store with no (repository, ticket) table (a new one, or one this step already
  ran on) has nothing to move. Otherwise, in one durable transaction:

    * a ticket whose only record is on the old key is written to the by-ticket index;
    * a ticket with records under several repositories is merged into its one record
      (`SymphonyElixir.TicketMerge`), its events renumbered from 1 and its artifacts listed under
      it. A store with the merge's marker (`records_merged_v1`) already folded the tickets its index
      names, so what those left on the old key is not read again;
    * a store without that marker gets it, with the merge's report beside it (`records.merged`);
    * the other ticket events move onto the ticket's id (the record's repository's copy of an event
      first, each event once by id, a straggler numbered after the last).

  Then the old table is deleted and the step's own marker (`ticket_pair_key_dropped_v1`) set.
  Interrupted, the next start runs it again: every write is the same.
  """
  @spec contract_ticket_key() :: :ok | {:error, term()}
  def contract_ticket_key do
    result = if @pair_table in :mnesia.system_info(:tables), do: drop_pair_key(), else: :ok
    with :ok <- result, do: mark_ticket_index()
  end

  defp drop_pair_key do
    with :ok <- load_pair_table(),
         :ok <- unwrap_nested_error(durable_transaction(&move_off_pair_key/0)) do
      # A failed delete stops the start with Mnesia's reason; the next start runs the step again.
      {:atomic, :ok} = :mnesia.delete_table(@pair_table)
      durable_transaction(fn -> :mnesia.write({@totals_table, {:marker, @pair_key_dropped_marker}, DateTime.utc_now()}) end)
    end
  end

  defp load_pair_table do
    wait_fun = Application.get_env(:symphony_elixir, :run_store_wait_for_tables, &:mnesia.wait_for_tables/2)

    case wait_fun.([@pair_table], @table_load_timeout_ms) do
      :ok -> :ok
      {:timeout, tables} -> {:error, {:mnesia_table_timeout, tables}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp move_off_pair_key do
    now = DateTime.utc_now()
    merge_ran? = read_marker(@merge_marker) != nil
    indexed = Map.new(:mnesia.match_object({@ticket_index_table, :_, :_, :_}), fn {_table, issue_id, repo_key, _record} -> {issue_id, repo_key} end)
    tickets = :mnesia.match_object({@pair_table, :_, :_, :_, :_}) |> Enum.group_by(&elem(&1, 3)) |> Enum.sort()

    merges = Enum.flat_map(tickets, fn {issue_id, rows} -> move_ticket(issue_id, rows, Map.get(indexed, issue_id), merge_ran?, now) end)
    rekey_ticket_events()
    if not merge_ran?, do: put_merge_report(TicketMerge.report(merges, length(tickets), now), now)
    :ok
  end

  defp move_ticket(issue_id, [{_table, _key, repo_key, issue_id, record}], nil, _merge_ran?, _now) do
    write_ticket_record(repo_key, issue_id, record |> TicketState.normalize() |> Map.put(:repo_key, repo_key))
    []
  end

  defp move_ticket(_issue_id, [_one], _indexed_repo_key, _merge_ran?, _now), do: []
  defp move_ticket(_issue_id, _rows, indexed_repo_key, true, _now) when is_binary(indexed_repo_key), do: []
  defp move_ticket(issue_id, rows, indexed_repo_key, _merge_ran?, now), do: [{issue_id, merge_ticket(issue_id, rows, indexed_repo_key, now)}]

  defp merge_ticket(issue_id, rows, indexed_repo_key, now) do
    entries =
      for {_table, _key, repo_key, ^issue_id, record} <- Enum.sort_by(rows, &elem(&1, 2)) do
        %{
          repo_key: repo_key,
          record: TicketState.normalize(record),
          events: pair_key_events(repo_key, issue_id),
          indexed: repo_key == indexed_repo_key
        }
      end

    merge = TicketMerge.merge(issue_id, entries, now)
    Enum.each(entries, &:mnesia.delete({@ticket_events_table, {&1.repo_key, issue_id}}))

    events = for {event, seq} <- Enum.with_index(merge.events, 1), do: %{event | repo_key: merge.repo_key, issue_id: issue_id, seq: seq}
    Enum.each(events, &write_ticket_event_row/1)
    write_ticket_record(merge.repo_key, issue_id, %{merge.record | event_seq: length(events)})
    events |> Enum.flat_map(& &1.artifacts) |> Enum.uniq() |> Enum.each(&list_artifact_ticket(&1, merge.repo_key, issue_id))
    merge
  end

  defp pair_key_events(repo_key, issue_id) do
    @ticket_events_table
    |> :mnesia.read({repo_key, issue_id})
    |> Enum.map(&Event.normalize(elem(&1, 7)))
    |> Enum.sort_by(&{datetime_sort_key(&1.at), &1.seq})
  end

  defp list_artifact_ticket(id, repo_key, issue_id) do
    case read_artifact(id, :write) do
      %{} = artifact ->
        ticket = %{repo_key: repo_key, issue_id: issue_id}
        write_artifact(Map.update(artifact, :tickets, [ticket], &Enum.uniq(&1 ++ [ticket])))

      nil ->
        :ok
    end
  end

  defp put_merge_report(report, now) do
    :mnesia.write({@totals_table, {:marker, @merge_marker}, now})
    :mnesia.write({@totals_table, {:report, @merge_marker}, report})
  end

  # Every event row still keyed by (repository, ticket) moves onto its ticket's id.
  defp rekey_ticket_events do
    {@ticket_events_table, {:_, :_}, :_, :_, :_, :_, :_, :_}
    |> :mnesia.match_object()
    |> Enum.group_by(fn row -> elem(row, 3) end)
    |> Enum.each(fn {issue_id, rows} -> rekey_ticket(issue_id, rows) end)
  end

  defp rekey_ticket(issue_id, rows) do
    record = read_ticket_record(nil, issue_id, :write)
    Enum.each(rows, &:mnesia.delete_object/1)

    {own, others} = Enum.split_with(rows, fn row -> record != nil and elem(row, 2) == record.repo_key end)
    own = Enum.map(own, &Event.normalize(elem(&1, 7)))
    own_keys = MapSet.new(own, &event_key/1)
    strays = others |> Enum.map(&Event.normalize(elem(&1, 7))) |> Enum.uniq_by(&event_key/1) |> Enum.reject(&MapSet.member?(own_keys, event_key(&1)))
    Enum.each(own, &write_ticket_event_row/1)
    renumber_strays(record, issue_id, own, strays)
  end

  # A ticket with no record keeps its events as they are; a record's straggler events (another
  # repository's key held them, the merge did not) are numbered after its last.
  defp renumber_strays(nil, _issue_id, _own, strays), do: Enum.each(strays, &write_ticket_event_row/1)
  defp renumber_strays(_record, _issue_id, _own, []), do: :ok

  defp renumber_strays(record, issue_id, own, strays) do
    record = TicketState.normalize(record)
    last = own |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end) |> max(record.event_seq)

    {events, last} =
      strays
      |> Enum.sort_by(&{datetime_sort_key(&1.at), &1.seq})
      |> Enum.map_reduce(last, fn event, seq -> {%{event | seq: seq + 1, repo_key: record.repo_key}, seq + 1} end)

    Enum.each(events, &write_ticket_event_row/1)
    write_ticket_record(record.repo_key, issue_id, %{record | event_seq: last})
  end

  # An event is the same event under any repository by its id; one without an id by what it says.
  defp event_key(%Event{id: id}) when is_binary(id), do: id
  defp event_key(%Event{} = event), do: {event.type, event.at, event.idempotency, event.run_id, event.payload}

  defp mark_ticket_index do
    durable_transaction(fn ->
      if is_nil(read_marker(@ticket_index_marker)), do: :mnesia.write({@totals_table, {:marker, @ticket_index_marker}, DateTime.utc_now()})
      :ok
    end)
  end

  defp read_marker(name) do
    case :mnesia.read(@totals_table, {:marker, name}) do
      [{@totals_table, _key, %DateTime{} = at}] -> at
      _none -> nil
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

        case contract_ticket_key() do
          :ok ->
            :persistent_term.put({__MODULE__, :ready}, self())
            {:ok, %State{dir: dir}}

          {:error, reason} ->
            {:stop, reason}
        end

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

  # An index is added to an existing table only once its disc copy has loaded: Mnesia answers an
  # earlier add with `{:no_exists, table}`, which kept a store from the previous release from booting
  # (TP-1347).
  defp ensure_tables do
    with :ok <- Enum.reduce_while(@tables, :ok, &ensure_table/2),
         :ok <- wait_for_tables() do
      Enum.reduce_while(@tables, :ok, fn {table, _attributes, opts}, :ok ->
        table
        |> ensure_table_indexes(Keyword.get(opts, :index, []))
        |> continue_or_halt()
      end)
    end
  end

  defp ensure_table({table, attributes, opts}, :ok) do
    if table in :mnesia.system_info(:tables) do
      table
      |> ensure_table_attributes(attributes)
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
    |> log_missing_indexes(table, current_indexes, indexes, attributes)
    |> Enum.reduce_while(:ok, fn index, :ok ->
      table
      |> ensure_table_index(index, attributes)
      |> continue_or_halt()
    end)
  end

  defp log_missing_indexes([], _table, _current_indexes, _indexes, _attributes), do: []

  defp log_missing_indexes(missing, table, current_indexes, indexes, attributes) do
    current = Enum.map(current_indexes, &Enum.at(attributes, &1 - 2))

    Logger.warning("RunStore table definition differs table=#{inspect(table)} indexes=#{inspect(current)} expected=#{inspect(indexes)}; adding #{inspect(missing)}")

    missing
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
    wait_fun = Application.get_env(:symphony_elixir, :run_store_wait_for_tables, &:mnesia.wait_for_tables/2)
    wait_for_tables(wait_fun, 0)
  end

  defp wait_for_tables(wait_fun, waited_ms) do
    step_ms = min(@table_load_progress_ms, @table_load_timeout_ms - waited_ms)

    case wait_fun.(@data_tables, step_ms) do
      :ok -> :ok
      {:timeout, tables} -> table_load_timed_out(wait_fun, tables, waited_ms + step_ms)
      {:error, reason} -> {:error, reason}
    end
  end

  defp table_load_timed_out(_wait_fun, tables, waited_ms) when waited_ms >= @table_load_timeout_ms do
    Logger.error("RunStore gave up loading tables after #{div(waited_ms, 1_000)} s: #{inspect(tables)}")
    {:error, {:mnesia_table_timeout, tables, %{waited_ms: waited_ms}}}
  end

  defp table_load_timed_out(wait_fun, tables, waited_ms) do
    Logger.info("RunStore still loading tables after #{div(waited_ms, 1_000)} s: #{inspect(tables)}")
    wait_for_tables(wait_fun, waited_ms)
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

        result =
          try do
            :mnesia.change_config(:dc_dump_limit, @rewrite_dc_dump_limit)
            Enum.reduce_while(1..2, :ok, fn _pass, :ok -> trim_pass(over_cap) end)
          after
            :mnesia.change_config(:dc_dump_limit, limit)
          end

        case result do
          :ok ->
            Logger.info("RunStore trimmed the stored transcript buffers of #{length(over_cap)} run(s) to #{@stored_transcript_events} events")

          # Startup goes on with the index trimmed; the next start trims the rows again.
          {:error, reason} ->
            Logger.warning("RunStore failed to trim stored transcript buffers: #{inspect(reason)}")
        end
    end
  end

  defp trim_pass(over_cap) do
    with :ok <- transaction(fn -> Enum.each(over_cap, &trim_stored_transcript/1) end),
         :dumped <- :mnesia.dump_log() do
      {:cont, :ok}
    else
      {:error, reason} -> {:halt, {:error, reason}}
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

  # The ticket's one record, read by its id: the by-ticket key is the record's only key. A record
  # whose repository is not the caller's `repo_key` (the ticket moved) is returned as it is, and the
  # difference logged; the caller never opens a second record. nil `repo_key`: no route to check.
  defp read_ticket_record(repo_key, issue_id, lock \\ :read) do
    case :mnesia.read(@ticket_index_table, issue_id, lock) do
      [{@ticket_index_table, ^issue_id, record_repo_key, record}] ->
        if repo_key && record_repo_key != repo_key, do: log_repository_mismatch(issue_id, record_repo_key, repo_key)
        record

      [] ->
        nil
    end
  end

  # The ticket's record, or a new one routed to `repo_key` when it has none yet.
  defp read_or_new_ticket_record(repo_key, issue_id, lock \\ :read) do
    case read_ticket_record(repo_key, issue_id, lock) do
      nil -> TicketState.new(repo_key, issue_id)
      record -> TicketState.normalize(record)
    end
  end

  # Writes the record under its ticket in the caller's transaction. Its repository is its own field
  # (`repo_key`, routed by observation), else `repo_key` for a new record; a ticket pause names the
  # record's repository, so a re-routed record carries its pause with it.
  defp write_ticket_record(repo_key, issue_id, record) do
    record_repo_key = Map.get(record, :repo_key) || repo_key
    record = record |> Map.put(:repo_key, record_repo_key) |> reroute_pause(record_repo_key, issue_id)
    :mnesia.write({@ticket_index_table, issue_id, record_repo_key, record})
    :ok
  end

  defp reroute_pause(%{pause: %{subject: {:ticket, repo_key, _id}}} = record, repo_key, _issue_id), do: record
  defp reroute_pause(%{pause: %{subject: {:ticket, _other, _id}} = pause} = record, repo_key, issue_id), do: %{record | pause: %{pause | subject: {:ticket, repo_key, issue_id}}}
  defp reroute_pause(record, _repo_key, _issue_id), do: record

  defp delete_ticket_record(issue_id) do
    :mnesia.delete({@ticket_index_table, issue_id})
  end

  # Once per caller's repository for each change of the record's, not once per read.
  defp log_repository_mismatch(issue_id, record_repo_key, repo_key) do
    key = {__MODULE__, :ticket_repository_mismatch, issue_id}

    logged =
      case :persistent_term.get(key, nil) do
        {^record_repo_key, callers} -> callers
        _other -> MapSet.new()
      end

    unless MapSet.member?(logged, repo_key) do
      :persistent_term.put(key, {record_repo_key, MapSet.put(logged, repo_key)})

      Logger.warning("Ticket record read under another repository issue_id=#{issue_id} record_repo_key=#{record_repo_key} repo_key=#{repo_key}; using the ticket's one record")
    end
  end

  # A route an update writes is a repository key like any other.
  defp valid_route(attrs) do
    case Map.fetch(normalize_record(attrs), :repo_key) do
      {:ok, repo_key} -> with {:ok, _repo_key} <- normalize_repo_key(repo_key), do: :ok
      :error -> :ok
    end
  end

  # `attrs` may carry `repo_key`: the route observation writes, which re-routes the one record.
  defp update_ticket_state_record(issue_id, attrs) do
    durable_transaction(fn ->
      case read_ticket_record(nil, issue_id) do
        nil ->
          {:error, :ticket_state_not_found}

        record ->
          route = attrs |> normalize_record() |> Map.get(:repo_key)

          updated =
            record
            |> Map.merge(normalize_update(attrs, [:key, :repo_key, :issue_id]))
            |> Map.put(:repo_key, route || Map.get(record, :repo_key))
            |> TicketState.normalize()

          write_ticket_record(nil, issue_id, updated)
          :ok
      end
    end)
  end

  defp one_ticket(events, repo_key, issue_id) do
    if Enum.all?(events, &match?(%Event{issue_id: ^issue_id}, &1)) and
         Enum.all?(events, &(normalize_repo_key(&1.repo_key) == {:ok, repo_key})) do
      :ok
    else
      {:error, :mixed_ticket_events}
    end
  end

  defp write_ticket_events(repo_key, issue_id, events) do
    record = read_or_new_ticket_record(repo_key, issue_id, :write)
    repo_key = record.repo_key

    stored = read_ticket_events(issue_id)
    last_seq = stored |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end) |> max(record.event_seq)

    {appended, _stored, last_seq} =
      Enum.reduce(events, {[], stored, last_seq}, fn event, {appended, stored, last_seq} ->
        case find_idempotent(stored, event.idempotency) do
          %Event{} = existing ->
            {[existing | appended], stored, last_seq}

          nil ->
            event = %{event | repo_key: repo_key, issue_id: issue_id, seq: last_seq + 1, phase: event.phase || record.phase}
            write_ticket_event_row(event)
            {[event | appended], [event | stored], event.seq}
        end
      end)

    if last_seq != record.event_seq do
      write_ticket_record(repo_key, issue_id, %{record | event_seq: last_seq})
    end

    {:ok, Enum.reverse(appended)}
  end

  defp find_idempotent(_stored, nil), do: nil
  defp find_idempotent(stored, key), do: Enum.find(stored, &(&1.idempotency == key))

  defp write_artifact(%{id: id, repo_key: repo_key, issue_id: issue_id} = artifact) do
    :mnesia.write({@artifacts_table, id, repo_key, issue_id, Map.new(artifact)})
  end

  defp write_updated_artifact(id, fun) do
    with {:ok, artifact} <- fun.(read_artifact(id, :write)),
         {:ok, repo_key} <- normalize_repo_key(Map.get(artifact, :repo_key)),
         artifact = Map.merge(artifact, %{id: id, repo_key: repo_key}),
         :ok <- write_artifact(artifact) do
      {:ok, artifact}
    end
  end

  defp all_artifact_records do
    :mnesia.match_object({@artifacts_table, :_, :_, :_, :_})
    |> Enum.map(fn {@artifacts_table, _key, _repo_key, _issue_id, record} -> record end)
  end

  defp read_artifact(id, lock) do
    case :mnesia.read(@artifacts_table, id, lock) do
      [{@artifacts_table, ^id, _repo_key, _issue_id, record}] -> record
      [] -> nil
    end
  end

  defp artifact_matches?(artifact, opts) do
    {expired, opts} = Keyword.pop(opts, :expired)
    ticket = opts |> Keyword.take([:repo_key, :issue_id]) |> Map.new()

    (is_nil(expired) or Map.get(artifact, :expired, false) == expired) and
      (ticket == %{} or Enum.any?(Map.get(artifact, :tickets, []), &(Map.take(&1, Map.keys(ticket)) == ticket)))
  end

  defp write_ticket_event_row(%Event{} = event) do
    :mnesia.write({@ticket_events_table, event.issue_id, event.repo_key, event.issue_id, event.run_id, event.type, event.seq, Event.to_record(event)})
  end

  defp upgrade_ticket_event_row({@ticket_events_table, _key, _repo_key, _issue_id, _run_id, _type, seq, record} = row, upgrades) do
    case upgrades do
      %{^seq => fields} ->
        :mnesia.delete_object(row)
        event = Event.normalize(record)
        write_ticket_event_row(%{event | payload: Map.merge(event.payload, fields)})

      _other ->
        :ok
    end
  end

  defp attach_ticket_event_row({@ticket_events_table, _key, _repo_key, _issue_id, _run_id, _type, _seq, record} = row, artifact_ids) do
    :mnesia.delete_object(row)
    event = Event.normalize(record)
    write_ticket_event_row(%{event | artifacts: Enum.uniq(event.artifacts ++ artifact_ids)})
  end

  defp read_ticket_events(issue_id) do
    @ticket_events_table
    |> :mnesia.read(issue_id)
    |> Enum.map(fn {@ticket_events_table, _key, _repo_key, _issue_id, _run_id, _type, _seq, record} -> Event.normalize(record) end)
    |> Enum.sort_by(&{datetime_sort_key(&1.at), &1.seq})
  end

  defp journal_event_row({@ticket_events_table, key, _repo_key, _issue_id, _run_id, _type, _seq, record}, acc)
       when is_binary(key) or key == {:subject, :symphony},
       do: [Event.normalize(record) | acc]

  defp journal_event_row(_row, acc), do: acc

  defp filter_ticket_events(events, opts) do
    types = Keyword.get(opts, :types)
    run_id = Keyword.get(opts, :run_id)

    Enum.filter(events, fn event ->
      (is_nil(types) or event.type in List.wrap(types)) and (is_nil(run_id) or event.run_id == run_id)
    end)
  end

  defp read_ticket_pull_request(repo_key, issue_id) do
    case :mnesia.read(@ticket_pull_request_table, scoped_key(repo_key, issue_id)) do
      [{@ticket_pull_request_table, _key, ^repo_key, ^issue_id, record}] -> record
      [] -> nil
    end
  end

  defp insert_new_ticket_pull_request(repo_key, issue_id, record) do
    case read_ticket_pull_request(repo_key, issue_id) do
      nil ->
        :mnesia.write({@ticket_pull_request_table, scoped_key(repo_key, issue_id), repo_key, issue_id, record})
        {:ok, :inserted}

      _record ->
        {:ok, :exists}
    end
  end

  defp write_finished_pull_requests(repo_key, pr_url, state, at) do
    changed =
      :mnesia.match_object({@ticket_pull_request_table, :_, repo_key, :_, :_})
      |> Enum.filter(fn {_table, _key, _repo_key, _issue_id, record} -> Map.get(record, :pr_url) == pr_url and Map.get(record, :state) != state end)
      |> Enum.map(fn {table, key, ^repo_key, issue_id, record} ->
        :mnesia.write({table, key, repo_key, issue_id, Map.merge(record, %{state: state, updated_at: at})})
      end)

    {:ok, length(changed)}
  end

  defp write_ticket_pr_watch(repo_key, issue_id, issue_identifier, pr_watch) do
    record = read_or_new_ticket_record(repo_key, issue_id)

    record = if is_nil(record.issue_identifier), do: %{record | issue_identifier: issue_identifier}, else: record
    write_ticket_record(repo_key, issue_id, TicketState.put_pr_watch(record, pr_watch))
    :ok
  end

  defp write_path_unlock_claim(repo_key, issue_id, ids, run_id) do
    record = read_ticket_record(repo_key, issue_id) || TicketState.new(repo_key, issue_id)

    case TicketState.claim_path_unlocks(record, ids, run_id) do
      {_record, []} ->
        {:ok, []}

      {updated, claimed} ->
        write_ticket_record(repo_key, issue_id, updated)
        {:ok, claimed}
    end
  end

  defp write_ticket_projection(repo_key, issue_id, change) do
    case read_ticket_record(repo_key, issue_id, :write) do
      nil ->
        :ok

      record ->
        write_ticket_record(repo_key, issue_id, change.(record))
        :ok
    end
  end

  defp write_ticket_self_heal(repo_key, issue_id, attrs) do
    record = read_ticket_record(repo_key, issue_id) || TicketState.new(repo_key, issue_id)

    updated = TicketState.put_self_heal(record, attrs)
    write_ticket_record(repo_key, issue_id, updated)
    :ok
  end

  defp write_ticket_decisions(repo_key, issue_id, entries, backfill) do
    record = read_or_new_ticket_record(repo_key, issue_id)

    case TicketState.put_decisions(record, entries, backfill) do
      ^record ->
        {:ok, record.decisions}

      updated ->
        write_ticket_record(repo_key, issue_id, updated)
        {:ok, updated.decisions}
    end
  end

  defp write_clear_ticket_fix_ticket(repo_key, issue_id) do
    case read_ticket_record(repo_key, issue_id) do
      nil ->
        :ok

      record ->
        updated = TicketState.clear_fix_ticket(record)
        write_ticket_record(repo_key, issue_id, updated)
        :ok
    end
  end

  defp write_ci_fix_origin(repo_key, issue_id, origin) do
    record = read_ticket_record(repo_key, issue_id) || TicketState.new(repo_key, issue_id)

    updated = TicketState.put_ci_fix_origin(record, origin)
    write_ticket_record(repo_key, issue_id, updated)
    :ok
  end

  defp write_ci_state(repo_key, issue_id, head_sha, status, at) do
    record = read_ticket_record(repo_key, issue_id) || TicketState.new(repo_key, issue_id)

    case TicketState.put_ci_state(record, head_sha, status, at) do
      {_record, :stale} ->
        {:ok, :stale}

      {updated, outcome} ->
        write_ticket_record(repo_key, issue_id, updated)
        {:ok, outcome}
    end
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

  defp valid_pause_subject(:symphony), do: :ok
  defp valid_pause_subject({:repository, repo_key}) when is_binary(repo_key) and repo_key != "", do: :ok
  defp valid_pause_subject(_subject), do: {:error, :invalid_subject}

  defp read_subject_pause(subject, lock \\ :read) do
    case :mnesia.read(@pause_table, {:subject, subject}, lock) do
      [{@pause_table, {:subject, ^subject}, pause}] when is_map(pause) -> pause
      _none -> nil
    end
  end

  defp write_subject_pause(subject, fun) do
    case fun.(read_subject_pause(subject, :write)) do
      {:write, nil, result} ->
        :mnesia.delete({@pause_table, {:subject, subject}})
        {:ok, result}

      {:write, pause, result} ->
        :mnesia.write({@pause_table, {:subject, subject}, pause})
        {:ok, result}

      {:write, pause, events, result} ->
        write_subject_pause_row(subject, pause)
        _stored = write_subject_events(subject, events)
        {:ok, result}

      unchanged ->
        unchanged
    end
  end

  defp subject_questions_row({@pause_table, {:questions, subject}, questions}, acc) when is_list(questions), do: [{subject, questions} | acc]
  defp subject_questions_row(_row, acc), do: acc

  defp subject_sort_key(:symphony), do: {0, ""}
  defp subject_sort_key({:repository, repo_key}), do: {1, repo_key}

  defp read_subject_questions(subject, lock \\ :read) do
    case :mnesia.read(@pause_table, {:questions, subject}, lock) do
      [{@pause_table, {:questions, ^subject}, questions}] when is_list(questions) -> questions
      _none -> []
    end
  end

  defp write_subject_question(subject, fun) do
    questions = read_subject_questions(subject, :write)

    case fun.(questions, read_subject_pause(subject, :write)) do
      {:write, question, pause, events, result} ->
        :mnesia.write({@pause_table, {:questions, subject}, put_subject_question(questions, question)})
        write_subject_pause_row(subject, pause)
        {:ok, result, write_subject_events(subject, events)}

      {:ok, result} ->
        {:ok, result, []}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_subject_question(questions, %{id: id} = question) do
    if Enum.any?(questions, &(&1.id == id)), do: Enum.map(questions, &if(&1.id == id, do: question, else: &1)), else: questions ++ [question]
  end

  defp write_subject_pause_row(subject, nil), do: :mnesia.delete({@pause_table, {:subject, subject}})
  defp write_subject_pause_row(subject, pause), do: :mnesia.write({@pause_table, {:subject, subject}, pause})

  # A subject's events, under its own key: the next `seq` of its stream, and an idempotency key the
  # stream already holds returns the event it holds.
  defp write_subject_events(subject, events) do
    stored = read_subject_events(subject)
    last_seq = stored |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)

    {appended, _stored, _last_seq} =
      Enum.reduce(events, {[], stored, last_seq}, fn event, {appended, stored, last_seq} ->
        case find_idempotent(stored, event.idempotency) do
          %Event{} = existing ->
            {[existing | appended], stored, last_seq}

          nil ->
            event = %{event | seq: last_seq + 1}
            :mnesia.write({@ticket_events_table, {:subject, subject}, event.repo_key, event.issue_id, event.run_id, event.type, event.seq, Event.to_record(event)})
            {[event | appended], [event | stored], event.seq}
        end
      end)

    Enum.reverse(appended)
  end

  defp read_subject_events(subject) do
    @ticket_events_table
    |> :mnesia.read({:subject, subject})
    |> Enum.map(fn {@ticket_events_table, _key, _repo_key, _issue_id, _run_id, _type, _seq, record} -> Event.normalize(record) end)
    |> Enum.sort_by(&{datetime_sort_key(&1.at), &1.seq})
  end

  defp write_ticket_pause(repo_key, issue_id, at, fun) do
    record = read_or_new_ticket_record(repo_key, issue_id, :write)

    case fun.(record.pause) do
      {:write, pause, events, result} ->
        write_ticket_record(repo_key, issue_id, TicketState.put_pause(record, pause, at))
        {:ok, stored} = write_ticket_events(repo_key, issue_id, events)
        {:ok, result, stored}

      {:ok, result} ->
        {:ok, result, []}

      {:error, _reason} = error ->
        error
    end
  end

  defp write_ticket_question(repo_key, issue_id, at, fun) do
    record = read_or_new_ticket_record(repo_key, issue_id, :write)

    case fun.(record.questions, record.pause) do
      {:write, question, pause, events, result} ->
        record = record |> TicketState.put_question(question) |> TicketState.put_pause(pause, at)
        write_ticket_record(repo_key, issue_id, record)
        {:ok, stored} = write_ticket_events(repo_key, issue_id, events)
        {:ok, result, stored}

      {:ok, result} ->
        {:ok, result, []}

      {:error, _reason} = error ->
        error
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

  # The ticket records whose repository is `repo_key` (or of every repository, `:all`): one per
  # ticket, under the repository its record names.
  defp listed_ticket_records(repo_key) do
    pattern = {@ticket_index_table, :_, if(repo_key == :all, do: :_, else: repo_key), :_}
    for {_table, _issue_id, _repo, record} <- :mnesia.match_object(pattern), do: record
  end

  defp read_report(name) do
    case :mnesia.read(@totals_table, {:report, name}) do
      [{@totals_table, _key, report}] when is_map(report) -> report
      _none -> nil
    end
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

  # The retired Auto Review QA runs used their own `qa_running` status; a restart still interrupts
  # one left over from before the retirement.
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
  def handle_call(:ready, _from, state), do: {:reply, :ok, state}

  @impl true
  def terminate(reason, %State{dir: dir}) do
    if reason not in [:normal, :shutdown] do
      Logger.warning("RunStore stopped unexpectedly dir=#{dir} reason=#{inspect(reason)}")
    end

    :ok
  end
end
