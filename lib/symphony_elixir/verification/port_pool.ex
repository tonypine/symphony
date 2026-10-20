defmodule SymphonyElixir.Verification.PortPool do
  @moduledoc false

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, RunStore}

  @default_reconcile_interval_ms 5_000

  defstruct [
    :run_store,
    :repo_key,
    :process_alive?,
    :port_free?,
    :reconcile_interval_ms,
    :timer_ref,
    allocations_by_run: %{},
    allocations_by_port: %{}
  ]

  @type allocation :: %{
          run_id: String.t(),
          repo_key: String.t(),
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          port: pos_integer(),
          status: String.t(),
          allocated_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec ensure_started(keyword()) :: :ok | {:error, term()}
  def ensure_started(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.whereis(name) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        case start_link(opts) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec allocate(map(), keyword()) :: {:ok, allocation()} | {:error, term()}
  def allocate(attrs, opts \\ []) when is_map(attrs) do
    name = Keyword.get(opts, :name, __MODULE__)

    with :ok <- ensure_started(opts) do
      GenServer.call(name, {:allocate, attrs}, :infinity)
    end
  end

  @spec release(String.t(), String.t(), keyword()) :: :ok
  def release(run_id, reason \\ "released", opts \\ []) when is_binary(run_id) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.whereis(name) do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:release, run_id, reason}, :infinity)

      _ ->
        :ok
    end
  end

  @spec record_dev_server_started(String.t(), map(), keyword()) :: :ok
  def record_dev_server_started(run_id, metadata, opts \\ []) when is_binary(run_id) and is_map(metadata) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.whereis(name) do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:record_dev_server_started, run_id, metadata}, :infinity)

      _ ->
        :ok
    end
  end

  @spec reconcile(keyword()) :: :ok | {:error, term()}
  def reconcile(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.whereis(name) do
      pid when is_pid(pid) -> GenServer.call(pid, :reconcile, :infinity)
      _ -> {:error, :not_started}
    end
  end

  @spec active_allocations(keyword()) :: [allocation()]
  def active_allocations(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.whereis(name) do
      pid when is_pid(pid) -> GenServer.call(pid, :active_allocations, :infinity)
      _ -> []
    end
  end

  @spec os_pid_alive?(integer()) :: boolean()
  def os_pid_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  def os_pid_alive?(_pid), do: false

  @doc """
  Whether nothing listens on `port` on 127.0.0.1: a listen with the loopback bridge's options
  succeeds there (`SymphonyElixir.Verification.LoopbackBridge`).
  """
  @spec port_free?(pos_integer()) :: boolean()
  def port_free?(port) when is_integer(port) do
    case :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      run_store: Keyword.get(opts, :run_store, RunStore),
      repo_key: Keyword.get(opts, :repo_key, Config.repo_key!()),
      process_alive?: Keyword.get(opts, :process_alive?, &__MODULE__.os_pid_alive?/1),
      port_free?: Keyword.get(opts, :port_free?, &__MODULE__.port_free?/1),
      reconcile_interval_ms: Keyword.get(opts, :reconcile_interval_ms, @default_reconcile_interval_ms)
    }

    state = reconcile_persisted_allocations(state)
    {:ok, schedule_reconcile(state)}
  end

  @impl true
  def handle_call({:allocate, attrs}, _from, state) do
    with {:ok, port_range} <- fetch_port_range(attrs),
         {:ok, run_id} <- fetch_run_id(attrs) do
      case Map.get(state.allocations_by_run, run_id) do
        %{port: _port} = allocation ->
          {:reply, {:ok, allocation}, state}

        _ ->
          allocate_free_port(state, attrs, run_id, port_range)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, run_id, reason}, _from, state) do
    {:reply, :ok, release_allocation(state, run_id, reason)}
  end

  def handle_call({:record_dev_server_started, run_id, metadata}, _from, state) do
    now = DateTime.utc_now()

    attrs =
      metadata
      |> Map.take([:dev_server_os_pid, :dev_server_pgid])
      |> Map.merge(%{status: "dev_server_started", updated_at: now})

    state =
      case Map.get(state.allocations_by_run, run_id) do
        nil ->
          persist_allocation_update(state, run_id, attrs)
          state

        allocation ->
          updated = Map.merge(allocation, attrs)
          persist_allocation_update(state, run_id, attrs)
          put_allocation(state, updated)
      end

    {:reply, :ok, state}
  end

  def handle_call(:reconcile, _from, state) do
    {:reply, :ok, reconcile_persisted_allocations(state)}
  end

  def handle_call(:active_allocations, _from, state) do
    allocations =
      state.allocations_by_run
      |> Map.values()
      |> Enum.sort_by(&Map.get(&1, :port))

    {:reply, allocations, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    {:noreply, state |> Map.put(:timer_ref, nil) |> reconcile_persisted_allocations() |> schedule_reconcile()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp allocate_free_port(state, attrs, run_id, port_range) do
    case first_free_port(state, port_range) do
      nil ->
        Logger.warning("Verification port range exhausted range=#{inspect(port_range)}; dispatch will wait")
        {:reply, {:error, :exhausted}, state}

      port ->
        now = DateTime.utc_now()

        allocation = %{
          run_id: run_id,
          repo_key: Map.get(attrs, :repo_key) || state.repo_key,
          issue_id: Map.get(attrs, :issue_id),
          issue_identifier: Map.get(attrs, :issue_identifier),
          worker_host: Map.get(attrs, :worker_host),
          port: port,
          status: "allocated",
          allocated_at: now,
          updated_at: now
        }

        case state.run_store.put_verification_allocation(allocation) do
          :ok ->
            {:reply, {:ok, allocation}, put_allocation(state, allocation)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  # A port another process already listens on (Symphony's own API, say) is skipped: the dev
  # server's loopback bridge could not listen there.
  defp first_free_port(state, [first, last]) do
    Enum.find(first..last, fn port -> not Map.has_key?(state.allocations_by_port, port) and state.port_free?.(port) end)
  end

  defp fetch_run_id(%{run_id: run_id}) when is_binary(run_id) and run_id != "", do: {:ok, run_id}
  defp fetch_run_id(_attrs), do: {:error, :invalid_run_id}

  defp fetch_port_range(%{port_range: [first, last] = range})
       when is_integer(first) and is_integer(last) and first in 1..65_535 and last in 1..65_535 and first <= last,
       do: {:ok, range}

  defp fetch_port_range(_attrs), do: {:error, :invalid_port_range}

  defp reconcile_persisted_allocations(state) do
    case state.run_store.list_all_verification_allocations() do
      allocations when is_list(allocations) ->
        Enum.reduce(allocations, empty_allocations(state), &reconcile_allocation/2)

      {:error, reason} ->
        Logger.warning("Failed to reconcile verification port allocations: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_allocation(allocation, state) do
    cond do
      not active_allocation?(allocation) ->
        state

      stale_allocation?(state, allocation) ->
        release_persisted_allocation(state, allocation, "restart reconciliation verified process gone")
        state

      true ->
        put_allocation(state, allocation)
    end
  end

  defp stale_allocation?(state, allocation) do
    case Map.get(allocation, :dev_server_os_pid) || Map.get(allocation, :dev_server_pgid) do
      pid when is_integer(pid) and pid > 0 -> not state.process_alive?.(pid)
      _pid -> true
    end
  end

  defp active_allocation?(allocation) when is_map(allocation) do
    is_nil(Map.get(allocation, :released_at)) and Map.get(allocation, :status) != "released"
  end

  defp active_allocation?(_allocation), do: false

  defp empty_allocations(state) do
    %{state | allocations_by_run: %{}, allocations_by_port: %{}}
  end

  defp put_allocation(state, %{run_id: run_id, port: port} = allocation) do
    %{
      state
      | allocations_by_run: Map.put(state.allocations_by_run, run_id, allocation),
        allocations_by_port: Map.put(state.allocations_by_port, port, run_id)
    }
  end

  defp release_allocation(state, run_id, reason) do
    case Map.get(state.allocations_by_run, run_id) do
      nil ->
        state

      %{port: port} = allocation ->
        release_persisted_allocation(state, allocation, reason)

        %{
          state
          | allocations_by_run: Map.delete(state.allocations_by_run, run_id),
            allocations_by_port: Map.delete(state.allocations_by_port, port)
        }
    end
  end

  defp release_persisted_allocation(state, %{run_id: run_id} = allocation, reason) do
    now = DateTime.utc_now()

    attrs = %{
      repo_key: Map.get(allocation, :repo_key) || state.repo_key,
      status: "released",
      released_at: now,
      release_reason: reason,
      updated_at: now
    }

    persist_allocation_update(state, run_id, attrs)
  end

  defp persist_allocation_update(state, run_id, attrs) do
    repo_key = Map.get(attrs, :repo_key) || state.repo_key

    case state.run_store.update_verification_allocation(repo_key, run_id, attrs) do
      :ok -> :ok
      {:error, :verification_allocation_not_found} -> :ok
      {:error, reason} -> Logger.warning("Failed to update verification allocation run_id=#{run_id}: #{inspect(reason)}")
    end
  end

  defp schedule_reconcile(%{reconcile_interval_ms: interval_ms} = state)
       when is_integer(interval_ms) and interval_ms > 0 do
    %{state | timer_ref: Process.send_after(self(), :reconcile, interval_ms)}
  end

  defp schedule_reconcile(state), do: state
end
