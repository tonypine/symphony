defmodule SymphonyElixir.AgentProcesses do
  @moduledoc """
  Makes sure agent OS processes don't outlive their port or Symphony.

  Erlang starts each port's OS process in its own session, so the port's OS
  pid is also its process group id. Closing a port,
  or the port's owner dying, only closes the agent's pipes: an agent that
  ignores EOF keeps running, re-parented to launchd or init.

  This server monitors every tracked port. When a port closes, it sends SIGTERM
  to the port's process group, and SIGKILL after a grace period. When Symphony
  stops (SIGTERM, `System.stop/1`) it does the same for every group it still
  tracks and waits for them to exit. It starts before the agent runners' task
  supervisor, so it stops after them.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.ProcessTree

  @default_grace_ms 3_000
  @poll_interval_ms 100

  @type os_pid :: pos_integer()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: grace_ms + 2_000
    }
  end

  @doc """
  Tracks the OS process group of an agent port. A no-op when the port has
  already closed or the server isn't running.
  """
  @spec track(port(), GenServer.server()) :: :ok
  def track(port, server \\ __MODULE__) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        GenServer.cast(server, {:track, port, os_pid})

      _closed ->
        :ok
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms),
       running: %{},
       stopping: MapSet.new()
     }}
  end

  @impl true
  def handle_cast({:track, port, os_pid}, state) do
    ref = Port.monitor(port)
    {:noreply, %{state | running: Map.put(state.running, ref, os_pid)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :port, _port, _reason}, state) do
    {os_pid, running} = Map.pop(state.running, ref)
    signal_group(os_pid, "TERM")
    Process.send_after(self(), {:kill_group, os_pid}, state.grace_ms)
    {:noreply, %{state | running: running, stopping: MapSet.put(state.stopping, os_pid)}}
  end

  def handle_info({:kill_group, os_pid}, state) do
    signal_group(os_pid, "KILL")
    {:noreply, %{state | stopping: MapSet.delete(state.stopping, os_pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    running = Map.values(state.running)

    Enum.each(running, fn os_pid ->
      ProcessTree.terminate_descendants(os_pid)
      signal_group(os_pid, "TERM")
    end)

    groups = running ++ MapSet.to_list(state.stopping)
    deadline = System.monotonic_time(:millisecond) + state.grace_ms

    case await_groups_exit(groups, deadline) do
      [] ->
        :ok

      survivors ->
        Logger.warning("Agent process groups ignored SIGTERM on shutdown; sending SIGKILL pgids=#{inspect(survivors)}")
        Enum.each(survivors, &signal_group(&1, "KILL"))
    end

    :ok
  end

  defp await_groups_exit(groups, deadline) do
    case Enum.filter(groups, &group_alive?/1) do
      [] ->
        []

      alive ->
        if System.monotonic_time(:millisecond) >= deadline do
          alive
        else
          Process.sleep(@poll_interval_ms)
          await_groups_exit(alive, deadline)
        end
    end
  end

  defp group_alive?(os_pid), do: match?({_output, 0}, signal_group(os_pid, "0"))

  defp signal_group(os_pid, signal) do
    System.cmd(System.find_executable("kill") || "/bin/kill", ["-#{signal}", "--", "-#{os_pid}"], stderr_to_stdout: true)
  end
end
