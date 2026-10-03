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

  A SIGKILL or a crash of the BEAM skips all of that, so every tracked group is
  also written to a ledger file with its leader's start time and workspace. On
  startup, before the orchestrator dispatches anything, groups left in the
  ledger by a previous instance are stopped when their leader's start time still
  matches. A group whose leader pid now belongs to another process is never
  signalled. When a group can't be confirmed stopped, issues in its workspace
  are not dispatched until it is gone.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Paths, ProcessTree, Workspace}

  @default_grace_ms 3_000
  @poll_interval_ms 100
  @ledger_file "agent_processes.json"

  @type os_pid :: pos_integer()
  @type start_time_result :: {:ok, String.t()} | :not_found | {:error, term()}

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
  Tracks the OS process group of an agent port started in `:workspace`. A no-op
  when the port has already closed or the server isn't running.
  """
  @spec track(port(), keyword()) :: :ok
  def track(port, opts) when is_port(port) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        GenServer.cast(server, {:track, port, os_pid, Keyword.get(opts, :workspace)})

      _closed ->
        :ok
    end
  end

  @doc """
  Why the issue must not be dispatched: an agent a previous Symphony left
  running in its workspace could not be confirmed stopped. `nil` when nothing
  blocks it, or when the server isn't running.
  """
  @spec dispatch_blocked_reason(String.t() | nil, GenServer.server()) :: String.t() | nil
  def dispatch_blocked_reason(identifier, server \\ __MODULE__) do
    GenServer.call(server, {:dispatch_blocked_reason, Workspace.safe_identifier(identifier)})
  catch
    :exit, _reason -> nil
  end

  @doc """
  The start time `ps` reports for a process, used to tell a recorded agent from
  a process that later reused its pid.
  """
  @spec process_start_time(integer(), (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})) ::
          start_time_result()
  def process_start_time(os_pid, cmd \\ &System.cmd/3) when is_integer(os_pid) do
    ps = System.find_executable("ps") || "/bin/ps"

    case cmd.(ps, ["-o", "lstart=", "-p", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {output, status} when status in [0, 1] ->
        case String.trim(output) do
          "" -> :not_found
          start_time when status == 0 -> {:ok, start_time}
          output -> {:error, {:ps_failed, status, output}}
        end

      {output, status} ->
        {:error, {:ps_failed, status, String.trim(output)}}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms),
      ledger_path: Keyword.get_lazy(opts, :ledger_path, fn -> Path.join(Paths.state_root(), @ledger_file) end),
      start_time: Keyword.get(opts, :start_time, &process_start_time/1),
      signal: Keyword.get(opts, :signal, &signal_group/2),
      running: %{},
      stopping: MapSet.new(),
      entries: %{},
      blocked: %{}
    }

    {:ok, recover_left_running(state)}
  end

  @impl true
  def handle_cast({:track, port, os_pid, workspace}, state) do
    ref = Port.monitor(port)

    start_time =
      case state.start_time.(os_pid) do
        {:ok, start_time} -> start_time
        _unknown -> nil
      end

    entry = %{pgid: os_pid, start_time: start_time, workspace: workspace}

    state = %{state | running: Map.put(state.running, ref, os_pid), entries: Map.put(state.entries, os_pid, entry)}
    {:noreply, write_ledger(state)}
  end

  @impl true
  def handle_call({:dispatch_blocked_reason, safe_identifier}, _from, state) do
    {blocked, reason} =
      Enum.reduce(state.blocked, {state.blocked, nil}, fn {pgid, entry}, {blocked, reason} ->
        cond do
          workspace_identifier(entry) != safe_identifier ->
            {blocked, reason}

          classify(entry, state) in [:gone, :reused] ->
            Logger.info("Agent process group left by a previous Symphony is gone; dispatch allowed again pgid=#{pgid} workspace=#{entry.workspace}")
            {Map.delete(blocked, pgid), reason}

          true ->
            {blocked, reason || entry.reason}
        end
      end)

    state = if blocked == state.blocked, do: state, else: write_ledger(%{state | blocked: blocked})
    {:reply, reason, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :port, _port, _reason}, state) do
    {os_pid, running} = Map.pop(state.running, ref)
    state.signal.(os_pid, "TERM")
    Process.send_after(self(), {:kill_group, os_pid}, state.grace_ms)
    {:noreply, %{state | running: running, stopping: MapSet.put(state.stopping, os_pid)}}
  end

  def handle_info({:kill_group, os_pid}, state) do
    state.signal.(os_pid, "KILL")

    state = %{state | stopping: MapSet.delete(state.stopping, os_pid), entries: Map.delete(state.entries, os_pid)}
    {:noreply, write_ledger(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    running = Map.values(state.running)

    Enum.each(running, fn os_pid ->
      ProcessTree.terminate_descendants(os_pid)
      state.signal.(os_pid, "TERM")
    end)

    groups = running ++ MapSet.to_list(state.stopping)
    deadline = System.monotonic_time(:millisecond) + state.grace_ms

    case await_groups_exit(groups, deadline, state.signal) do
      [] ->
        :ok

      survivors ->
        Logger.warning("Agent process groups ignored SIGTERM on shutdown; sending SIGKILL pgids=#{inspect(survivors)}")
        Enum.each(survivors, &state.signal.(&1, "KILL"))
    end

    write_ledger(%{state | entries: %{}})
    :ok
  end

  # Startup: stop what a previous instance left running, before anything is dispatched.
  defp recover_left_running(state) do
    classified = Enum.map(read_ledger(state.ledger_path), &{&1, classify(&1, state)})

    Enum.each(classified, fn
      {entry, :reused} ->
        Logger.info("Not signalling agent process group left by a previous Symphony; its pid now belongs to another process pgid=#{entry.pgid} workspace=#{entry.workspace}")

      _other ->
        :ok
    end)

    left_running = for {entry, :same} <- classified, do: entry
    unconfirmed = for {entry, {:unconfirmed, reason}} <- classified, do: Map.put(entry, :reason, reason)

    blocked =
      (unconfirmed ++ stop_left_running(left_running, state))
      |> Enum.map(&log_blocked/1)
      |> Map.new(&{&1.pgid, &1})

    write_ledger(%{state | blocked: blocked})
  end

  defp stop_left_running([], _state), do: []

  defp stop_left_running(entries, state) do
    pgids = Enum.map(entries, & &1.pgid)

    Logger.warning("Stopping agent process groups left running by a previous Symphony pgids=#{inspect(pgids)}")

    Enum.each(pgids, &state.signal.(&1, "TERM"))
    survivors = await_groups_exit(pgids, System.monotonic_time(:millisecond) + state.grace_ms, state.signal)
    Enum.each(survivors, &state.signal.(&1, "KILL"))
    survivors = await_groups_exit(survivors, System.monotonic_time(:millisecond) + state.grace_ms, state.signal)

    for entry <- entries, entry.pgid in survivors do
      Map.put(entry, :reason, "agent process group pgid=#{entry.pgid} is still running after SIGKILL")
    end
  end

  defp log_blocked(entry) do
    Logger.warning("Not dispatching issues in workspace=#{entry.workspace}: an agent left running by a previous Symphony could not be confirmed stopped: #{entry.reason}")

    entry
  end

  defp classify(%{pgid: pgid} = entry, state) do
    if group_alive?(pgid, state.signal), do: classify_alive(entry, state.start_time.(pgid)), else: :gone
  end

  defp classify_alive(%{start_time: start_time}, {:ok, start_time}) when is_binary(start_time), do: :same
  defp classify_alive(%{start_time: recorded}, {:ok, _start_time}) when is_binary(recorded), do: :reused

  defp classify_alive(%{pgid: pgid}, {:ok, _start_time}),
    do: {:unconfirmed, "no start time was recorded for pgid=#{pgid}, so it can't be told from a process that reused its pid"}

  defp classify_alive(%{pgid: pgid}, :not_found),
    do: {:unconfirmed, "the leader of process group pgid=#{pgid} exited but the group is still running"}

  defp classify_alive(%{pgid: pgid}, {:error, reason}),
    do: {:unconfirmed, "could not read the start time of pid=#{pgid}: #{inspect(reason)}"}

  defp workspace_identifier(%{workspace: workspace}) when is_binary(workspace), do: Path.basename(workspace)
  defp workspace_identifier(_entry), do: nil

  defp read_ledger(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, entries} when is_list(entries) <- Jason.decode(contents) do
      Enum.flat_map(entries, &decode_entry/1)
    else
      {:error, :enoent} ->
        []

      other ->
        Logger.warning("Ignoring unreadable agent process ledger path=#{path}: #{inspect(other)}")
        []
    end
  end

  # pgid 1 would make `kill -- -1` signal every process the user owns.
  defp decode_entry(%{"pgid" => pgid} = entry) when is_integer(pgid) and pgid > 1 do
    [%{pgid: pgid, start_time: string_or_nil(entry["start_time"]), workspace: string_or_nil(entry["workspace"])}]
  end

  defp decode_entry(_entry), do: []

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp write_ledger(state) do
    entries =
      (Map.values(state.entries) ++ Map.values(state.blocked))
      |> Enum.map(&Map.take(&1, [:pgid, :start_time, :workspace]))

    tmp_path = state.ledger_path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(state.ledger_path)),
         :ok <- File.write(tmp_path, Jason.encode!(entries)),
         :ok <- File.rename(tmp_path, state.ledger_path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to write agent process ledger path=#{state.ledger_path}: #{inspect(reason)}")
    end

    state
  end

  defp await_groups_exit(groups, deadline, signal) do
    case Enum.filter(groups, &group_alive?(&1, signal)) do
      [] ->
        []

      alive ->
        if System.monotonic_time(:millisecond) >= deadline do
          alive
        else
          Process.sleep(@poll_interval_ms)
          await_groups_exit(alive, deadline, signal)
        end
    end
  end

  defp group_alive?(os_pid, signal), do: match?({_output, 0}, signal.(os_pid, "0"))

  defp signal_group(os_pid, signal) do
    System.cmd(System.find_executable("kill") || "/bin/kill", ["-#{signal}", "--", "-#{os_pid}"], stderr_to_stdout: true)
  end
end
