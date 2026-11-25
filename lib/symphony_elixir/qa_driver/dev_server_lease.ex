defmodule SymphonyElixir.QaDriver.DevServerLease do
  @moduledoc """
  One QA-host dev server per worker host and port at a time (TP-1125).

  A `macos_app` pass whose project server runs beside it (`verification.dev_server.runs` is
  `every_qa_pass`, or `live_qa_pass` on a live pass) runs that server on the QA host on the
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

  The same manager keeps the QA VM's desktop (TP-1554): a key `{worker_host, :desktop}` is held by
  every `macos_app` pass's driver for the whole pass (`SymphonyElixir.QaDriver.take_vm/2`) and by
  the Window tests step of a run (`SymphonyElixir.PhaseSteps.WindowTests`) while its scripts drive
  windows there, so the two never use the VM's windows, mouse and keyboard at the same time. Its
  holder says what it holds the VM for (`use`), and `waiting/2` and `holder/2` name it.

  A driver that already holds the lease gets it again. Without the manager (it is not running),
  or when it goes down while a pass waits, the pass goes ahead: the dev server's own port check
  (`SymphonyElixir.QaDriver.DevServer`) still refuses a port another server holds.
  """

  use GenServer

  require Logger

  @heartbeat_ms 30_000

  @typedoc "The QA host and the port its dev server listens on, or `:desktop` for the QA VM's windows."
  @type key :: {String.t(), pos_integer() | :desktop}

  @typedoc """
  Who takes the lease: the process that holds it (the QA driver, or the run of a Window tests
  step), the ticket it is for and, optionally, what it holds it for (`use`, `"QA pass"` by default).
  """
  @type holder :: %{
          required(:pid) => pid(),
          required(:issue_id) => String.t() | nil,
          required(:ticket) => String.t() | nil,
          optional(:use) => String.t()
        }

  @typedoc """
  A pass waiting for a lease: the key and the ticket that holds it; for the desktop, also what that
  ticket holds it for (`held_for`).
  """
  @type wait :: %{
          required(:worker_host) => String.t(),
          required(:port) => pos_integer() | :desktop,
          required(:held_by) => String.t() | nil,
          optional(:held_for) => String.t()
        }

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

  @doc "Who holds the lease on `key` now, else nil."
  @spec holder(GenServer.server(), key()) :: holder() | nil
  def holder(server \\ __MODULE__, key) do
    case GenServer.whereis(server) do
      nil -> nil
      pid -> GenServer.call(pid, {:holder, key})
    end
  end

  @doc "What the holder of a lease holds it for: its `use`, a QA pass when it names none."
  @spec use_of(holder() | nil) :: String.t()
  def use_of(%{use: use}) when is_binary(use), do: use
  def use_of(_holder), do: "QA pass"

  @doc "Why a pass that waits for a lease is passed over: the orchestrator's dispatch reason."
  @spec reason(wait()) :: String.t()
  def reason(%{worker_host: worker_host, port: :desktop, held_by: held_by} = wait) do
    "waiting for the QA VM: #{worker_host} is in use by #{held_by || "another ticket"}'s #{Map.get(wait, :held_for, "QA pass")}"
  end

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
        if Enum.any?(waiters, &(&1.holder.issue_id == issue_id)), do: wait(worker_host, port, state.leases[key].holder)
      end)

    {:reply, wait, state}
  end

  def handle_call({:holder, key}, _from, state) do
    {:reply, with(%{holder: holder} <- Map.get(state.leases, key), do: holder), state}
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

  defp wait(worker_host, :desktop, holder), do: %{worker_host: worker_host, port: :desktop, held_by: holder.ticket, held_for: use_of(holder)}
  defp wait(worker_host, port, holder), do: %{worker_host: worker_host, port: port, held_by: holder.ticket}

  defp grant(state, key, lease), do: %{state | leases: Map.put(state.leases, key, lease)}

  defp describe({worker_host, :desktop}), do: "worker_host=#{worker_host} lease=desktop"
  defp describe({worker_host, port}), do: "worker_host=#{worker_host} port=#{port}"
end
