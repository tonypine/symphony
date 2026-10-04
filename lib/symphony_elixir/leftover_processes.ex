defmodule SymphonyElixir.LeftoverProcesses do
  @moduledoc """
  Stops the processes a run leaves behind in its folder.

  `SymphonyElixir.AgentProcesses` stops an agent's process group, but `nohup`,
  `setsid` and daemonizing all leave that group. When an agent run or a QA pass
  ends, this module finds every process whose working folder, or a path on its
  command line (the executable or a script), is under one of the run's folders,
  and stops it: SIGTERM, then SIGKILL after a grace period to the ones still
  running as the same process (same pid and start time). It logs each process
  it stops with its CPU time. A process outside those folders, Symphony itself,
  or a process Symphony is still running (a `git -C <workspace>` call, a hook)
  is never signalled.
  """

  require Logger

  alias SymphonyElixir.LeftoverProcesses.Table
  alias SymphonyElixir.PathSafety

  @default_grace_ms 3_000
  @poll_interval_ms 100

  @type entry :: %{
          required(:pid) => pos_integer(),
          optional(:ppid) => non_neg_integer(),
          required(:start_time) => String.t(),
          optional(:cpu_time) => String.t(),
          required(:command) => String.t(),
          required(:cwd) => String.t() | nil
        }
  @type table_fun :: (-> {:ok, [entry()]} | {:error, term()})
  @type signal_fun :: (pos_integer(), String.t() -> term())

  @doc """
  Stops the processes under `roots` and returns the ones it signalled.

  Options: `:table` (reads the process table), `:signal` (sends a signal to a
  pid), `:grace_ms`, `:own_pid` and `:log_context`, a `key=value` string added
  to each log line.
  """
  @spec stop_under([Path.t()], keyword()) :: [entry()]
  def stop_under(roots, opts \\ []) when is_list(roots) do
    table = Keyword.get_lazy(opts, :table, &default_table/0)
    signal = Keyword.get(opts, :signal, &signal/2)
    context = log_context(Keyword.get(opts, :log_context))
    roots = roots |> Enum.flat_map(&root_paths/1) |> Enum.uniq()

    case table.() do
      {:ok, entries} ->
        spared = symphony_pids(entries, Keyword.get_lazy(opts, :own_pid, &own_pid/0))
        targets = Enum.filter(entries, &(not MapSet.member?(spared, &1.pid) and under_roots?(&1, roots)))
        stop(targets, table, signal, Keyword.get(opts, :grace_ms, @default_grace_ms), context)
        targets

      {:error, reason} ->
        Logger.warning("Could not read the process table to stop leftover processes#{context} roots=#{inspect(roots)}: #{inspect(reason)}")
        []
    end
  end

  @doc """
  The Claude Code task folders of `workspace` under `tmp_dir`: Claude Code keeps a
  session's background task output under
  `<tmp_dir>/claude-<uid>/<workspace path with every non-alphanumeric as ->/`.
  """
  @spec claude_task_dirs(Path.t(), Path.t()) :: [Path.t()]
  def claude_task_dirs(workspace, tmp_dir) do
    slug = String.replace(workspace, ~r/[^a-zA-Z0-9]/, "-")

    tmp_dir
    |> Path.join("claude-*")
    |> Path.join(slug)
    |> Path.wildcard()
  end

  @doc "Whether the process runs in, or was started from, a folder under one of `roots`."
  @spec under_roots?(entry(), [Path.t()]) :: boolean()
  def under_roots?(%{cwd: cwd, command: command}, roots) do
    Enum.any?(roots, fn root -> path_under?(cwd, root) or command_mentions?(command, root) end)
  end

  defp path_under?(path, root) when is_binary(path), do: path == root or String.starts_with?(path, root <> "/")
  defp path_under?(_path, _root), do: false

  # A path argument starting with `root`, as the executable, a script, an
  # `--opt=path` value, or a shell redirection such as `2>path`.
  defp command_mentions?(command, root) do
    Regex.match?(~r/(^|[\s=:'"<>])#{Regex.escape(root)}($|[\s\/'"])/, command)
  end

  @doc """
  Symphony (`own_pid`) and every process it started and still runs. A process an
  agent detached was re-parented to init when its parent exited, so it isn't one.
  """
  @spec symphony_pids([entry()], pos_integer()) :: MapSet.t(pos_integer())
  def symphony_pids(entries, own_pid) do
    children = Enum.group_by(entries, &Map.get(&1, :ppid), & &1.pid)
    [own_pid] |> with_descendants(children, []) |> MapSet.new()
  end

  defp with_descendants([], _children, pids), do: pids

  defp with_descendants([pid | rest], children, pids) do
    with_descendants(Map.get(children, pid, []) ++ rest, children, [pid | pids])
  end

  defp stop([], _table, _signal, _grace_ms, _context), do: :ok

  defp stop(targets, table, signal, grace_ms, context) do
    Enum.each(targets, fn entry ->
      Logger.info("Stopping leftover process#{context} pid=#{entry.pid} cwd=#{entry.cwd || "unknown"} cpu_time=#{Map.get(entry, :cpu_time) || "unknown"} command=#{inspect(entry.command)}")
      signal.(entry.pid, "TERM")
    end)

    deadline = System.monotonic_time(:millisecond) + grace_ms

    case await_exit(targets, table, deadline) do
      [] ->
        :ok

      survivors ->
        Enum.each(survivors, fn entry ->
          Logger.warning("Leftover process ignored SIGTERM; sending SIGKILL#{context} pid=#{entry.pid} command=#{inspect(entry.command)}")
          signal.(entry.pid, "KILL")
        end)
    end
  end

  defp await_exit(targets, table, deadline) do
    case survivors(targets, table) do
      [] ->
        []

      alive ->
        if System.monotonic_time(:millisecond) >= deadline do
          alive
        else
          Process.sleep(@poll_interval_ms)
          await_exit(alive, table, deadline)
        end
    end
  end

  # The targets still running as the same process: a pid reused by a new process
  # has another start time and is left alone, as is every target when the table
  # can't be read again.
  defp survivors(targets, table) do
    case table.() do
      {:ok, entries} ->
        running = MapSet.new(entries, &{&1.pid, &1.start_time})
        Enum.filter(targets, &MapSet.member?(running, {&1.pid, &1.start_time}))

      {:error, _reason} ->
        []
    end
  end

  @doc """
  The folder as given and with symlinks resolved (`/tmp` is `/private/tmp` on
  macOS), since `lsof` and `/proc` report resolved working folders.
  """
  @spec root_paths(Path.t()) :: [Path.t()]
  def root_paths(root) do
    root = Path.expand(root)

    case PathSafety.canonicalize(root) do
      {:ok, canonical} -> [root, canonical]
      {:error, _reason} -> [root]
    end
  end

  defp log_context(nil), do: ""
  defp log_context(context), do: " " <> context

  @doc "The process table reader, `Table.read/0` unless the app env names another."
  @spec default_table() :: table_fun()
  def default_table, do: Application.get_env(:symphony_elixir, :leftover_process_table, &Table.read/0)

  @doc "This BEAM's OS pid."
  @spec own_pid() :: pos_integer()
  def own_pid, do: String.to_integer(System.pid())

  defp signal(pid, signal) do
    System.cmd(System.find_executable("kill") || "/bin/kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
  end
end
