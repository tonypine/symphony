defmodule SymphonyElixir.StrayProcesses do
  @moduledoc """
  Warns about processes that burn CPU in a workspace with no run attached.

  `SymphonyElixir.LeftoverProcesses` stops what an agent run or a QA pass leaves
  in its folders when it ends. It misses what a remote worker run, an
  interactive Claude session or a process that escapes its folder match leaves
  behind. On every watchdog tick (`watchdog.tick_interval_ms`) this server reads
  the process table and flags each process that:

  - runs in, or names on its command line, a folder under `workspaces.root`, a
    Claude Code temp folder (`/tmp/claude-<uid>`) or a Symphony temp folder
    (`symphony-*` under `$TMPDIR` or `/tmp`),
  - has used more than `watchdog.stray_process_cpu_minutes` of CPU time, and
  - is not in the workspace, temp folder, QA worktree or Claude Code task
    folder of a running agent or QA pass.

  Symphony and the processes it still runs are never flagged. The dashboard
  shows the flagged processes. Each one is logged when it is first flagged and
  again when it is gone. Nothing is signalled.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AcceptanceGate, AgentRunner, Config, LeftoverProcesses, Orchestrator, QaRunner, StatusDashboard}
  alias SymphonyElixir.LeftoverProcesses.Table

  @snapshot_timeout_ms 15_000
  @check_timeout_ms 60_000

  @type warning :: %{
          pid: pos_integer(),
          start_time: String.t(),
          command: String.t(),
          cwd: String.t() | nil,
          cpu_time: String.t(),
          cpu_seconds: non_neg_integer()
        }

  @doc """
  Starts the server. Options: `:name`, `:table` (reads the process table),
  `:running_workspaces` (returns `{:ok, paths}` for the runs in flight),
  `:orchestrator` and `:qa_runner` (where the default `:running_workspaces`
  looks), `:claude_tmp_dir`, `:tmp_dirs` and `:own_pid`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The processes flagged by the latest check, most CPU time first."
  @spec warnings(GenServer.server()) :: [warning()]
  def warnings(server) do
    case GenServer.whereis(server) do
      nil -> []
      pid -> GenServer.call(pid, :warnings)
    end
  end

  @doc "Checks the process table now, or waits for the check in flight, and returns the warnings."
  @spec check(GenServer.server()) :: [warning()]
  def check(server), do: GenServer.call(server, :check, @check_timeout_ms)

  @doc """
  The processes in `entries` under one of the `:watched` folders that have used
  more than `:threshold_seconds` of CPU time, leaving out `:own_pid` and the
  processes it still runs.
  """
  @spec find([LeftoverProcesses.entry()], keyword()) :: [warning()]
  def find(entries, opts) do
    watched = Keyword.fetch!(opts, :watched)
    threshold_seconds = Keyword.fetch!(opts, :threshold_seconds)
    spared = LeftoverProcesses.symphony_pids(entries, Keyword.fetch!(opts, :own_pid))

    entries
    |> Enum.flat_map(fn entry ->
      seconds = Table.cpu_seconds(Map.get(entry, :cpu_time))

      if is_integer(seconds) and seconds > threshold_seconds and not MapSet.member?(spared, entry.pid) and
           LeftoverProcesses.under_roots?(entry, watched) do
        [%{pid: entry.pid, start_time: entry.start_time, command: entry.command, cwd: entry.cwd, cpu_time: entry.cpu_time, cpu_seconds: seconds}]
      else
        []
      end
    end)
    |> Enum.sort_by(&{-&1.cpu_seconds, &1.pid})
  end

  @impl true
  def init(opts) do
    {:ok, schedule_tick(%{opts: opts, warnings: [], scan_ref: nil, waiters: []})}
  end

  @impl true
  def handle_call(:warnings, _from, state), do: {:reply, state.warnings, state}

  def handle_call(:check, from, state) do
    {:noreply, start_scan(%{state | waiters: [from | state.waiters]})}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> schedule_tick() |> start_scan()}

  def handle_info({ref, result}, %{scan_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_scan(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{scan_ref: ref} = state) do
    {:noreply, finish_scan(state, {:error, {:check_crashed, reason}})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_tick(state) do
    Process.send_after(self(), :tick, Config.settings!().watchdog.tick_interval_ms)
    state
  end

  # Reading the process table (`lsof` on macOS) takes a few seconds, so it runs in
  # a task and the dashboard keeps reading the previous warnings meanwhile.
  defp start_scan(%{scan_ref: nil} = state) do
    opts = state.opts
    %Task{ref: ref} = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> scan(opts) end)
    %{state | scan_ref: ref}
  end

  defp start_scan(state), do: state

  defp finish_scan(state, result) do
    warnings =
      case result do
        {:ok, warnings} ->
          log_changes(state.warnings, warnings)
          if warnings != state.warnings, do: StatusDashboard.notify_update()
          warnings

        {:error, reason} ->
          Logger.warning("Could not check for stray processes: #{inspect(reason)}")
          state.warnings
      end

    Enum.each(state.waiters, &GenServer.reply(&1, warnings))
    %{state | warnings: warnings, scan_ref: nil, waiters: []}
  end

  defp scan(opts) do
    settings = Config.settings!()

    case settings.watchdog.stray_process_cpu_minutes do
      nil ->
        {:ok, []}

      minutes ->
        table = Keyword.get_lazy(opts, :table, &LeftoverProcesses.default_table/0)
        running_workspaces = Keyword.get(opts, :running_workspaces, fn -> running_workspaces(opts) end)
        claude_tmp_dir = Keyword.get(opts, :claude_tmp_dir, "/tmp")

        with {:ok, entries} <- table.() do
          entries
          |> find(
            watched: watched_roots(settings.workspace.root, claude_tmp_dir, Keyword.get_lazy(opts, :tmp_dirs, &default_tmp_dirs/0)),
            threshold_seconds: minutes * 60,
            own_pid: Keyword.get_lazy(opts, :own_pid, &LeftoverProcesses.own_pid/0)
          )
          |> without_attached(running_workspaces, claude_tmp_dir)
        end
    end
  end

  # The orchestrator is only asked for its runs when a process is over the threshold.
  defp without_attached([], _running_workspaces, _claude_tmp_dir), do: {:ok, []}

  defp without_attached(candidates, running_workspaces, claude_tmp_dir) do
    with {:ok, workspaces} <- running_workspaces.() do
      attached = attached_roots(workspaces, claude_tmp_dir)
      {:ok, Enum.reject(candidates, &LeftoverProcesses.under_roots?(&1, attached))}
    end
  end

  defp running_workspaces(opts) do
    case Orchestrator.snapshot(Keyword.get(opts, :orchestrator, Orchestrator), @snapshot_timeout_ms) do
      %{running: running} ->
        agent_workspaces = for %{workspace_path: path} <- running, is_binary(path), do: path
        agent_tmp_dirs = Enum.flat_map(agent_workspaces, &AgentRunner.tmp_dirs/1)
        gate_workspaces = AcceptanceGate.Runner.workspaces(Keyword.get(opts, :gate_runner, AcceptanceGate.Runner))
        {:ok, agent_workspaces ++ agent_tmp_dirs ++ QaRunner.workspaces(Keyword.get(opts, :qa_runner, QaRunner)) ++ gate_workspaces}

      unavailable ->
        {:error, {:orchestrator_snapshot, unavailable}}
    end
  end

  defp watched_roots(workspace_root, claude_tmp_dir, tmp_dirs) do
    temp_folders = Enum.flat_map(tmp_dirs, &Path.wildcard(Path.join(&1, "symphony-*")))
    claude_folders = Path.wildcard(Path.join(claude_tmp_dir, "claude-*"))

    [Path.expand(workspace_root) | Enum.filter(claude_folders ++ temp_folders, &File.dir?/1)]
    |> expand_roots()
  end

  defp attached_roots(workspaces, claude_tmp_dir) do
    workspaces
    |> Enum.flat_map(&[&1 | LeftoverProcesses.claude_task_dirs(&1, claude_tmp_dir)])
    |> expand_roots()
  end

  defp expand_roots(roots), do: roots |> Enum.flat_map(&LeftoverProcesses.root_paths/1) |> Enum.uniq()

  defp default_tmp_dirs, do: Enum.uniq([System.tmp_dir!(), "/tmp"])

  defp log_changes(previous, current) do
    previous_keys = MapSet.new(previous, &key/1)
    current_keys = MapSet.new(current, &key/1)

    for warning <- current, not MapSet.member?(previous_keys, key(warning)) do
      Logger.warning("Process using CPU with no run attached pid=#{warning.pid} cwd=#{warning.cwd || "unknown"} cpu_time=#{warning.cpu_time} command=#{inspect(warning.command)}")
    end

    for warning <- previous, not MapSet.member?(current_keys, key(warning)) do
      Logger.info("Process no longer flagged as stray pid=#{warning.pid} command=#{inspect(warning.command)}")
    end
  end

  # A pid reused by a new process has another start time.
  defp key(warning), do: {warning.pid, warning.start_time}
end
