defmodule SymphonyElixir.Config.Cache do
  @moduledoc """
  Caches parsed `symphony.yml` and repo `WORKFLOW.md` files.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Workflow

  @index_key {__MODULE__, :index}
  @watched_dirs_key {__MODULE__, :watched_dirs}
  @stale_option [stale: true]
  @telemetry_stale_event [:symphony, :config, :cache, :stale]

  defmodule Entry do
    @moduledoc false

    defstruct [:kind, :path, :stamp, :value, :last_error, :updated_at, stale?: false]
  end

  @type cache_kind :: :symphony | :workflow
  @type cache_result(value) :: {:ok, value} | {:ok, value, stale: true} | {:error, term()}

  @type status_entry :: %{
          kind: cache_kind(),
          path: Path.t(),
          stale?: boolean(),
          last_error: term() | nil,
          updated_at: integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get() :: cache_result(map())
  def get do
    get_symphony(Workflow.symphony_file_path())
  end

  @spec get_symphony(Path.t()) :: cache_result(map())
  def get_symphony(path) when is_binary(path) do
    cached(:symphony, path)
  end

  @spec get_workflow(Path.t()) :: cache_result(Workflow.loaded_workflow())
  def get_workflow(path) when is_binary(path) do
    cached(:workflow, path)
  end

  @doc """
  Returns the current cached entries with their staleness state. Intended for
  introspection (dashboards, `/health` endpoints, tests) — callers should not
  reach into `Entry` directly.
  """
  @spec status() :: [status_entry()]
  def status do
    keys = :persistent_term.get(@index_key, MapSet.new())

    Enum.flat_map(keys, fn key ->
      case :persistent_term.get(key, nil) do
        %Entry{} = entry ->
          [
            %{
              kind: entry.kind,
              path: entry.path,
              stale?: entry.stale?,
              last_error: entry.last_error,
              updated_at: entry.updated_at
            }
          ]

        _ ->
          []
      end
    end)
  end

  @doc """
  Drops the cached workflow for `path` so the next read loads it from disk, even
  when the rewrite kept the same mtime and size.
  """
  @spec invalidate(Path.t()) :: :ok
  def invalidate(path) when is_binary(path) do
    key = cache_key(:workflow, Path.expand(path))
    :persistent_term.erase(key)
    keys = :persistent_term.get(@index_key, MapSet.new())
    :persistent_term.put(@index_key, MapSet.delete(keys, key))
    :ok
  end

  @spec clear() :: :ok
  def clear do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :clear)
      _ -> do_clear()
    end
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{watchers: %{}}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    Enum.each(state.watchers, fn {_dir, watcher} -> safe_stop_watcher(watcher) end)
    do_clear()
    {:reply, :ok, %{state | watchers: %{}}}
  end

  @impl true
  def handle_cast({:watch, path}, state) do
    {:noreply, watch_path(state, path)}
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, events}}, state) when is_binary(path) and is_list(events) do
    if reload_event?(events) do
      path
      |> Path.expand()
      |> reload_path()
    end

    {:noreply, state}
  end

  def handle_info({:file_event, watcher, :stop}, state) do
    {:noreply, drop_watcher(state, watcher, :stop)}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    {:noreply, drop_watcher(state, pid, {:exit, reason})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp cached(kind, path) do
    path = Path.expand(path)
    key = cache_key(kind, path)
    ensure_watch(path)

    case :persistent_term.get(key, nil) do
      %Entry{} = entry -> refresh_entry(entry, loader_for(kind))
      nil -> load_entry(kind, path, loader_for(kind))
    end
  end

  defp loader_for(:symphony), do: &load_symphony/1
  defp loader_for(:workflow), do: &load_workflow/1

  defp refresh_entry(%Entry{} = entry, loader) do
    case current_stamp(entry.path) do
      {:ok, stamp} when stamp == entry.stamp ->
        entry_result(entry)

      {:ok, stamp} ->
        load_entry(entry.kind, entry.path, loader, entry, stamp)

      {:error, reason} ->
        stale_entry(entry, {:missing_file, reason})
    end
  end

  defp load_entry(kind, path, loader, previous \\ nil, known_stamp \\ nil) do
    with {:ok, stamp} <- stamp_for(path, known_stamp),
         {:ok, value} <- loader.(path) do
      entry = %Entry{
        kind: kind,
        path: path,
        stamp: stamp,
        value: value,
        updated_at: System.system_time(:millisecond)
      }

      put_entry(entry)
      {:ok, value}
    else
      {:error, reason} ->
        case previous do
          %Entry{} = entry -> stale_entry(entry, reason)
          nil -> {:error, normalize_missing_reason(kind, path, reason)}
        end
    end
  end

  defp stamp_for(_path, stamp) when is_tuple(stamp), do: {:ok, stamp}
  defp stamp_for(path, _stamp), do: current_stamp(path)

  defp stale_entry(%Entry{} = entry, reason) do
    stale = %{
      entry
      | stale?: true,
        last_error: reason,
        updated_at: System.system_time(:millisecond)
    }

    put_entry(stale)

    Logger.warning("Failed to reload config path=#{entry.path} reason=#{inspect(reason)}; keeping last known good value")

    :telemetry.execute(
      @telemetry_stale_event,
      %{count: 1},
      %{kind: entry.kind, path: entry.path, reason: reason}
    )

    {:ok, stale.value, @stale_option}
  end

  defp entry_result(%Entry{stale?: true, value: value}), do: {:ok, value, @stale_option}
  defp entry_result(%Entry{value: value}), do: {:ok, value}

  defp put_entry(%Entry{} = entry) do
    key = cache_key(entry.kind, entry.path)
    :persistent_term.put(key, entry)
    add_to_index(key)
    :ok
  end

  defp add_to_index(key) do
    keys = :persistent_term.get(@index_key, MapSet.new())
    :persistent_term.put(@index_key, MapSet.put(keys, key))
  end

  defp reload_path(path) do
    keys = :persistent_term.get(@index_key, MapSet.new())

    Enum.each(keys, fn key ->
      case :persistent_term.get(key, nil) do
        %Entry{path: ^path, kind: :symphony} = entry -> refresh_entry(entry, &load_symphony/1)
        %Entry{path: ^path, kind: :workflow} = entry -> refresh_entry(entry, &load_workflow/1)
        _entry -> :ok
      end
    end)
  end

  defp cache_key(kind, path), do: {__MODULE__, kind, path}

  defp current_stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, {stat.mtime, stat.size, stat.type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_symphony(path) do
    with {:ok, content} <- read_file(path),
         do: Workflow.parse_symphony(content)
  end

  defp load_workflow(path) do
    with {:ok, content} <- read_file(path),
         do: Workflow.parse_repo_workflow(content, Workflow.instructions_on_disk(Path.dirname(path)))
  end

  defp read_file(path) do
    case Application.get_env(:symphony_elixir, :config_cache_file_reader) do
      reader when is_function(reader, 1) -> reader.(path)
      _reader -> File.read(path)
    end
  end

  defp normalize_missing_reason(:symphony, path, reason),
    do: normalize_missing_reason(reason, {:missing_symphony_file, path, reason})

  defp normalize_missing_reason(:workflow, path, reason),
    do: normalize_missing_reason(reason, {:missing_workflow_file, path, reason})

  defp normalize_missing_reason(reason, missing_reason) when reason in [:enoent, :enotdir, :eacces],
    do: missing_reason

  defp normalize_missing_reason(reason, _missing_reason), do: reason

  defp ensure_watch(path) do
    if watch_enabled?() and not already_watched?(path) do
      cast_watch(path)
    end

    :ok
  end

  defp watch_enabled?, do: Application.get_env(:symphony_elixir, :config_cache_watch, true)

  defp already_watched?(path) do
    dir_already_watched?(Path.dirname(path))
  end

  defp dir_already_watched?(dir) do
    set = :persistent_term.get(@watched_dirs_key, MapSet.new())
    MapSet.member?(set, dir)
  end

  defp cast_watch(path) do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:watch, path})
      _pid -> :ok
    end
  end

  defp watch_path(state, path) do
    dir = Path.dirname(path)

    cond do
      Map.has_key?(state.watchers, dir) ->
        # Make sure the persistent_term mirror reflects state in case clear/0
        # ran without restarting the GenServer.
        mark_dir_watched(dir)
        state

      dir_already_watched?(dir) ->
        # Stat-only fallback was recorded for this dir by an earlier cast.
        # Subsequent casts queued before that completed would otherwise
        # re-enter start_watcher and flood the logs with bootstrap failures.
        state

      File.dir?(dir) ->
        case start_watcher(dir) do
          {:ok, watcher} ->
            mark_dir_watched(dir)
            %{state | watchers: Map.put(state.watchers, dir, watcher)}

          {:error, reason} ->
            Logger.warning("Failed to watch config directory=#{dir} reason=#{inspect(reason)}; falling back to stat-based polling for this dir until node restart")

            mark_dir_stat_only(dir)
            state

          :ignore ->
            Logger.warning("Config watcher unavailable for directory=#{dir}; falling back to stat-based polling for this dir until node restart")

            mark_dir_stat_only(dir)
            state
        end

      true ->
        state
    end
  end

  defp start_watcher(dir) do
    case Application.get_env(:symphony_elixir, :config_cache_watcher) do
      watcher when is_function(watcher, 1) ->
        watcher.(dir)

      _watcher ->
        start_file_system_watcher(dir)
    end
  end

  defp start_file_system_watcher(dir) do
    if Code.ensure_loaded?(FileSystem), do: start_loaded_file_system_watcher(dir), else: :ignore
  end

  defp start_loaded_file_system_watcher(dir) do
    case FileSystem.start_link(dirs: [dir]) do
      {:ok, watcher} ->
        :ok = FileSystem.subscribe(watcher)
        {:ok, watcher}

      {:error, reason} ->
        {:error, reason}

      :ignore ->
        :ignore
    end
  end

  defp drop_watcher(state, watcher_pid, reason_tag) do
    case Enum.find(state.watchers, fn {_dir, pid} -> pid == watcher_pid end) do
      {dir, _pid} ->
        Logger.warning("Config watcher #{inspect(reason_tag)} dir=#{dir}; auto-reload disabled for this dir until next access")

        unmark_dir_watched(dir)
        %{state | watchers: Map.delete(state.watchers, dir)}

      nil ->
        state
    end
  end

  defp mark_dir_watched(dir) do
    set = :persistent_term.get(@watched_dirs_key, MapSet.new())
    :persistent_term.put(@watched_dirs_key, MapSet.put(set, dir))
  end

  defp mark_dir_stat_only(dir) do
    # Track stat-only fallback dirs in the same persistent_term set used for live watchers so
    # cast_watch/1 short-circuits instead of retrying FileSystem.start_link on every config read
    # and flooding logs during active agent sessions.
    #
    # NOTE: this is sticky for the BEAM lifetime. unmark_dir_watched/1 only runs from
    # drop_watcher/3 when a live watcher pid exits — stat-only entries have no pid in
    # state.watchers, so they never get cleared. A transient watcher backend failure therefore
    # pins that dir to stat-based polling until the node restarts. Stat polling still gives us
    # eventual consistency, but if a future requirement demands in-process recovery, move
    # stat-only entries into a separate persistent_term key with an explicit retry path.
    mark_dir_watched(dir)
  end

  defp unmark_dir_watched(dir) do
    set = :persistent_term.get(@watched_dirs_key, MapSet.new())
    :persistent_term.put(@watched_dirs_key, MapSet.delete(set, dir))
  end

  defp safe_stop_watcher(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    :ok
  end

  defp safe_stop_watcher(_), do: :ok

  defp do_clear do
    # Two-pass clear so a concurrent put_entry between snapshot and final erase
    # doesn't leak an orphan entry that would survive future clears.
    clear_index_keys()
    clear_index_keys()
    :persistent_term.erase(@watched_dirs_key)
    :ok
  end

  defp clear_index_keys do
    keys = :persistent_term.get(@index_key, MapSet.new())
    Enum.each(keys, &:persistent_term.erase/1)
    :persistent_term.erase(@index_key)
  end

  defp reload_event?(events) do
    Enum.any?(events, &(&1 in [:modified, :renamed, :created, :removed, :deleted]))
  end
end
