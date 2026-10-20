defmodule SymphonyElixir.QaDriver.DevServerLease do
  @moduledoc """
  One QA-host dev server per worker host and port at a time (TP-1125).

  A `macos_app` pass with `dev_server: true` runs the project's server on the QA host on the
  playbook's fixed `dev_server_port`, and the app under test reads its hub URL from its own
  defaults, so two such passes on one `worker_host` would share the port: the second's server
  fails to bind while the first's answers its health check. Before it starts its server (so
  before any `qa_build`), the pass takes a lease on `{worker_host, port}` with `acquire/4` for
  its QA driver (`SymphonyElixir.QaDriver`). The driver gives it back with `release/2` once it
  stopped the server, at the end of the pass, or by exiting.

  A second pass waits in turn, first come first served, and starts when the lease is handed to
  it. The wait is never silent: the queueing and the hand-over are logged with who holds the
  lease, and `waiting/2` tells the orchestrator which running pass waits and for whom, which it
  lists among the passed-over tickets (`reason/1`). While a pass waits, `acquire/4` calls its
  `:heartbeat` every `:heartbeat_ms`, so the orchestrator's first-turn stall check does not stop
  it.

  A driver that already holds the lease gets it again. Without the manager (it is not running),
  or when it goes down while a pass waits, the pass goes ahead: the dev server's own port check
  (`SymphonyElixir.QaDriver.DevServer`) still refuses a port another server holds.
  """

  use GenServer

  require Logger

  @heartbeat_ms 30_000

  @typedoc "The QA host and the port its dev server listens on."
  @type key :: {String.t(), pos_integer()}

  @typedoc "Who takes the lease: the QA driver that runs the server, and the ticket whose pass it is."
  @type holder :: %{pid: pid(), issue_id: String.t() | nil, ticket: String.t() | nil}

  @typedoc "A pass waiting for a lease: the key and the ticket that holds it."
  @type wait :: %{worker_host: String.t(), port: pos_integer(), held_by: String.t() | nil}

  @doc "Starts the lease manager, registered as `:name` (default `#{inspect(__MODULE__)}`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Takes the lease on `key` for `holder.pid`, waiting in the calling process while another holds
  it. Options: `:heartbeat` (a 0-arity function called while waiting) and `:heartbeat_ms`.
  """
  @spec acquire(GenServer.server(), key(), holder(), keyword()) :: :ok
  def acquire(server \\ __MODULE__, key, holder, opts \\ []) do
    case GenServer.whereis(server) do
      nil ->
        Logger.warning("QA dev server lease manager is not running; #{holder.ticket} starts its server without a lease #{describe(key)}")
        :ok

      pid ->
        ref = make_ref()

        case GenServer.call(pid, {:acquire, key, holder, ref}) do
          :ok -> :ok
          :queued -> await(Process.monitor(pid), ref, holder, key, opts)
        end
    end
  end

  @doc "Gives back the leases `owner` holds, or drops its place in a queue; the next waiter gets each lease."
  @spec release(GenServer.server(), pid()) :: :ok
  def release(server, owner) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.call(pid, {:release, owner})
    end
  end

  @doc "The lease the running QA pass of `issue_id` waits for, and who holds it, else nil."
  @spec waiting(GenServer.server(), String.t()) :: wait() | nil
  def waiting(server \\ __MODULE__, issue_id) do
    case GenServer.whereis(server) do
      nil -> nil
      pid -> GenServer.call(pid, {:waiting, issue_id})
    end
  end

  @doc "Why a pass that waits for a lease is passed over: the orchestrator's dispatch reason."
  @spec reason(wait()) :: String.t()
  def reason(%{worker_host: worker_host, port: port, held_by: held_by}) do
    "waiting for the QA host's dev server port: #{port} on #{worker_host} is held by #{held_by || "another ticket"}'s QA pass"
  end

  defp await(monitor, ref, holder, key, opts) do
    receive do
      {:dev_server_lease, ^ref} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, _pid, reason} ->
        Logger.warning("QA dev server lease manager went down while #{holder.ticket} waited #{describe(key)} reason=#{inspect(reason)}; starting without a lease")
        :ok
    after
      Keyword.get(opts, :heartbeat_ms, @heartbeat_ms) ->
        Keyword.get(opts, :heartbeat, fn -> :ok end).()
        await(monitor, ref, holder, key, opts)
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{leases: %{}, waiters: %{}}}

  @impl true
  def handle_call({:acquire, key, %{pid: owner} = holder, ref}, {caller, _tag}, state) do
    entry = %{owner: owner, caller: caller, ref: ref, holder: holder}

    case Map.get(state.leases, key) do
      nil ->
        {:reply, :ok, grant(state, key, Map.put(entry, :monitor, Process.monitor(owner)))}

      %{owner: ^owner} ->
        {:reply, :ok, state}

      lease ->
        Logger.info("QA dev server lease busy: #{holder.ticket} waits #{describe(key)} held_by=#{lease.holder.ticket}")
        waiter = Map.put(entry, :monitor, Process.monitor(owner))
        {:reply, :queued, %{state | waiters: Map.update(state.waiters, key, [waiter], &(&1 ++ [waiter]))}}
    end
  end

  def handle_call({:release, owner}, _from, state), do: {:reply, :ok, drop(state, &(&1.owner == owner))}

  def handle_call({:waiting, issue_id}, _from, state) do
    wait =
      Enum.find_value(state.waiters, fn {{worker_host, port} = key, waiters} ->
        if Enum.any?(waiters, &(&1.holder.issue_id == issue_id)),
          do: %{worker_host: worker_host, port: port, held_by: state.leases[key].holder.ticket}
      end)

    {:reply, wait, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state), do: {:noreply, drop(state, &(&1.monitor == monitor))}

  # Removes the waiters and leases `match?` picks, handing each freed lease to its next waiter.
  defp drop(state, match?) do
    waiters =
      Map.new(state.waiters, fn {key, list} ->
        {gone, kept} = Enum.split_with(list, match?)
        Enum.each(gone, &Process.demonitor(&1.monitor, [:flush]))
        {key, kept}
      end)

    Enum.reduce(state.leases, %{state | waiters: waiters}, fn {key, lease}, acc ->
      if match?.(lease) do
        Process.demonitor(lease.monitor, [:flush])
        next(%{acc | leases: Map.delete(acc.leases, key)}, key, lease.holder)
      else
        acc
      end
    end)
  end

  defp next(state, key, previous) do
    case Map.get(state.waiters, key, []) do
      [] ->
        Logger.info("QA dev server lease released by #{previous.ticket} #{describe(key)}")
        %{state | waiters: Map.delete(state.waiters, key)}

      [waiter | rest] ->
        Logger.info("QA dev server lease passed from #{previous.ticket} to #{waiter.holder.ticket} #{describe(key)}")
        send(waiter.caller, {:dev_server_lease, waiter.ref})
        grant(%{state | waiters: Map.put(state.waiters, key, rest)}, key, waiter)
    end
  end

  defp grant(state, key, lease), do: %{state | leases: Map.put(state.leases, key, lease)}

  defp describe({worker_host, port}), do: "worker_host=#{worker_host} port=#{port}"
end
