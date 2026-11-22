defmodule SymphonyElixir.Config.Cache do
  @moduledoc """
  Caches parsed `symphony.yml` and repo `WORKFLOW.md` files.

  A reload that fails keeps the last known good value: a file that no longer reads or parses, a
  `WORKFLOW.md` its schema rejects, or a `symphony.yml` `SymphonyElixir.Config.parse_system/1`
  rejects (an unknown or removed key, an invalid value). The entry is then stale: `status/0` says
  since when and why, and the rejected file is not read again until it changes.

  A cached file whose edit changes what the cache holds emits `[:symphony, :config, :cache, :reloaded]`
  once the entry is refreshed, so `SymphonyElixir.Setup` checks the new config: a new good value, a
  newly rejected or missing file, or a different rejected file. It does not matter how the edit was
  found: a file event, or the stat check on a config read when the directory has no watcher. A
  dropped entry (`invalidate/1`) emits it too, since the next read loads the file again.

  A read never starts a file watcher. The running app names the folders a settings change arrives
  in when it starts the cache (`start_link/1`'s `:watch`): one watcher per folder, never a
  repository root (TP-1603). A file whose folder is too large to watch is named in `:watch_files`
  instead: the cache checks that one file's stamp every `:config_poll_interval_ms` (a second by
  default) and reloads it on a change, without a read. A file anywhere else is still checked by its
  stamp on each read.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Workflow}

  @index_key {__MODULE__, :index}
  # Bumped by every `clear/0` and `invalidate/1`: a load that began before one doesn't cache what it read.
  @generation_key {__MODULE__, :generation}
  @stale_option [stale: true]
  @telemetry_stale_event [:symphony, :config, :cache, :stale]
  @telemetry_reloaded_event [:symphony, :config, :cache, :reloaded]

  defmodule Entry do
    @moduledoc false

    # `instructions` is the instruction directory a workflow's playbook line expanded and
    # its `Workflow.instructions_stamp/1` before the load, or nil. `failed_stamp` is the stamp of
    # the file a stale entry rejected, so it is not read again until it changes; `stale_since` is
    # when the entry went stale.
    defstruct [
      :kind,
      :path,
      :stamp,
      :instructions,
      :value,
      :last_error,
      :updated_at,
      :failed_stamp,
      :stale_since,
      stale?: false
    ]
  end

  @type cache_kind :: :symphony | :workflow
  @type cache_result(value) :: {:ok, value} | {:ok, value, stale: true} | {:error, term()}

  @type status_entry :: %{
          kind: cache_kind(),
          path: Path.t(),
          stale?: boolean(),
          last_error: term() | nil,
          updated_at: integer() | nil,
          stale_since: integer() | nil
        }

  @doc """
  Starts the cache. `:watch` lists the folders to start a file watcher on, one each, and
  `:watch_files` the files whose stamp it checks on a timer instead; `:name` defaults to the module
  (nil for an unnamed instance). Each folder it refuses is logged with the reason.
  """
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

  @doc "The event each reload of a cached file emits, with the reloaded `path` in its metadata."
  @spec reloaded_event() :: [atom()]
  def reloaded_event, do: @telemetry_reloaded_event

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
              updated_at: entry.updated_at,
              stale_since: entry.stale_since
            }
          ]

        _ ->
          []
      end
    end)
  end

  @doc """
  Drops the cached workflow or `symphony.yml` for `path` so the next read loads it from disk, even
  when the rewrite kept the same mtime and size.
  """
  @spec invalidate(Path.t()) :: :ok
  def invalidate(path) when is_binary(path) do
    path = Path.expand(path)
    stale = for kind <- [:workflow, :symphony], do: cache_key(kind, path)
    keys = :persistent_term.get(@index_key, MapSet.new())
    bump_generation()
    Enum.each(stale, &:persistent_term.erase/1)
    :persistent_term.put(@index_key, MapSet.difference(keys, MapSet.new(stale)))
    if Enum.any?(stale, &MapSet.member?(keys, &1)), do: reloaded(path)
    :ok
  end

  @doc """
  Starts a file watcher on `dir` unless one runs there: `:ok`, or why it could not. A folder that
  holds a git checkout (`.git`) is refused: a repository root is far too many files to watch.
  """
  @spec watch(GenServer.server(), Path.t()) :: :ok | {:error, term()}
  def watch(server \\ __MODULE__, dir) when is_binary(dir) do
    GenServer.call(server, {:watch, Path.expand(dir)})
  end

  @doc "The files the cache checks by their stamp on a timer, sorted."
  @spec watched_files(GenServer.server()) :: [Path.t()]
  def watched_files(server \\ __MODULE__) do
    GenServer.call(server, :watched_files)
  end

  @doc "The folders the cache runs a file watcher on, sorted."
  @spec watched_dirs(GenServer.server()) :: [Path.t()]
  def watched_dirs(server \\ __MODULE__) do
    GenServer.call(server, :watched_dirs)
  end

  @spec clear() :: :ok
  def clear do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :clear)
      _ -> do_clear()
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    files = opts |> Keyword.get(:watch_files, []) |> Enum.map(&Path.expand/1) |> Enum.uniq() |> Enum.sort()
    state = opts |> Keyword.get(:watch, []) |> Enum.reduce(%{watchers: %{}, files: files}, &boot_watch/2)

    Enum.each(files, &Logger.info("Checking config file=#{&1} by its stamp every #{poll_interval_ms()}ms; its folder is too large to watch"))
    schedule_poll(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    do_clear()
    {:reply, :ok, state}
  end

  def handle_call({:watch, dir}, _from, state) do
    {reply, state} = watch_dir(state, dir)
    {:reply, reply, state}
  end

  def handle_call(:watched_files, _from, state) do
    {:reply, state.files, state}
  end

  def handle_call(:watched_dirs, _from, state) do
    {:reply, state.watchers |> Map.keys() |> Enum.sort(), state}
  end

  @impl true
  def handle_info({:file_event, watcher, {path, events}}, state) when is_binary(path) and is_list(events) do
    if reload_event?(events), do: reload_path(Path.expand(path), watched_dir(state, watcher))

    {:noreply, state}
  end

  def handle_info({:file_event, watcher, :stop}, state) do
    {:noreply, drop_watcher(state, watcher, :stop)}
  end

  def handle_info(:poll, state) do
    Enum.each(state.files, &poll_file/1)
    schedule_poll(state)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    {:noreply, drop_watcher(state, pid, {:exit, reason})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The watchers stop with the cache, so none outlives the app or a test's instance.
  @impl true
  def terminate(_reason, state) do
    Enum.each(state.watchers, fn {_dir, watcher} -> stop_watcher(watcher) end)
  end

  defp cached(kind, path) do
    generation = generation()
    path = Path.expand(path)
    key = cache_key(kind, path)

    case :persistent_term.get(key, nil) do
      %Entry{} = entry -> refresh_entry(entry, loader_for(kind), generation)
      nil -> load_entry(kind, path, loader_for(kind), generation)
    end
  end

  defp loader_for(:symphony), do: &load_symphony/1
  defp loader_for(:workflow), do: &load_workflow/1

  defp refresh_entry(%Entry{} = entry, loader, generation) do
    case current_stamp(entry.path) do
      {:ok, stamp} ->
        if current?(entry, stamp) and instructions_current?(entry.instructions),
          do: entry_result(entry),
          else: load_entry(entry.kind, entry.path, loader, generation, entry, stamp)

      {:error, reason} ->
        stale_entry(entry, {:missing_file, reason}, nil)
    end
  end

  defp load_entry(kind, path, loader, generation, previous \\ nil, known_stamp \\ nil) do
    with {:ok, stamp} <- stamp_for(path, known_stamp),
         {:ok, value, instructions} <- loader.(path) do
      entry = %Entry{
        kind: kind,
        path: path,
        stamp: stamp,
        instructions: instructions,
        value: value,
        updated_at: System.system_time(:millisecond)
      }

      # Not over a `clear/0` or an `invalidate/1` that ran while the file was read: the file this
      # load read may be the one they dropped, and the next read would serve it (TP-1546).
      if generation() == generation, do: put_entry(entry)
      if previous, do: reloaded(path)
      {:ok, value}
    else
      {:error, reason} ->
        case previous do
          %Entry{} = entry -> stale_entry(entry, reason, known_stamp)
          nil -> {:error, normalize_missing_reason(kind, path, reason)}
        end
    end
  end

  # A stale entry is current for the file it rejected; the good file's stamp coming back reloads it.
  defp current?(%Entry{stale?: true} = entry, stamp), do: stamp == entry.failed_stamp
  defp current?(%Entry{} = entry, stamp), do: stamp == entry.stamp

  defp stamp_for(_path, stamp) when is_tuple(stamp), do: {:ok, stamp}
  defp stamp_for(path, _stamp), do: current_stamp(path)

  defp instructions_current?(nil), do: true
  defp instructions_current?({dir, stamp}), do: Workflow.instructions_stamp(dir) == stamp

  defp stale_entry(%Entry{} = entry, reason, failed_stamp) do
    now = System.system_time(:millisecond)

    stale = %{
      entry
      | stale?: true,
        last_error: reason,
        failed_stamp: failed_stamp,
        stale_since: if(entry.stale?, do: entry.stale_since, else: now),
        updated_at: now
    }

    # Only over the entry this reload started from. A `clear/0`, an `invalidate/1` or a newer entry
    # that landed while the file was read wins: a read that began before them must not put the
    # replaced value back, or the next read would serve it as the last known good config.
    if :persistent_term.get(cache_key(entry.kind, entry.path), nil) == entry, do: put_entry(stale)

    Logger.warning("Failed to reload config path=#{entry.path} reason=#{inspect(reason)}; keeping last known good value")

    :telemetry.execute(
      @telemetry_stale_event,
      %{count: 1},
      %{kind: entry.kind, path: entry.path, reason: reason}
    )

    # A file that stays missing is checked again on every read; only the change is a reload.
    if not entry.stale? or entry.failed_stamp != failed_stamp, do: reloaded(entry.path)
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

  # A file event refreshes the entries that read `path`; the refresh emits the reload when it finds one.
  # The backend may name the file by its resolved path (`/private/tmp` for `/tmp` on macOS), so a
  # file of the same name in the folder the event's watcher was given matches too.
  defp reload_path(path, dir) do
    generation = generation()

    :persistent_term.get(@index_key, MapSet.new())
    |> Enum.map(&:persistent_term.get(&1, nil))
    |> Enum.filter(&(match?(%Entry{}, &1) and event_path?(&1.path, path, dir)))
    |> Enum.each(&refresh_entry(&1, loader_for(&1.kind), generation))
  end

  # A polled file is refreshed only when its stamp moved, or when it went missing: a file that stays
  # missing is not reported again on every tick.
  defp poll_file(path) do
    generation = generation()
    stamp = current_stamp(path)

    for kind <- [:symphony, :workflow],
        %Entry{} = entry <- [:persistent_term.get(cache_key(kind, path), nil)],
        changed?(entry, stamp),
        do: refresh_entry(entry, loader_for(kind), generation)
  end

  defp changed?(%Entry{} = entry, {:ok, stamp}), do: not (current?(entry, stamp) and instructions_current?(entry.instructions))
  defp changed?(%Entry{stale?: stale?}, {:error, _reason}), do: not stale?

  defp schedule_poll(%{files: []}), do: :ok
  defp schedule_poll(_state), do: Process.send_after(self(), :poll, poll_interval_ms())

  defp poll_interval_ms, do: Application.get_env(:symphony_elixir, :config_poll_interval_ms, 1_000)

  defp event_path?(path, path, _dir), do: true
  defp event_path?(entry_path, path, dir), do: Path.dirname(entry_path) == dir and Path.basename(entry_path) == Path.basename(path)

  defp watched_dir(state, watcher) do
    Enum.find_value(state.watchers, fn {dir, pid} -> if pid == watcher, do: dir end)
  end

  defp generation, do: :persistent_term.get(@generation_key, 0)
  defp bump_generation, do: :persistent_term.put(@generation_key, generation() + 1)

  defp reloaded(path), do: :telemetry.execute(@telemetry_reloaded_event, %{count: 1}, %{path: path})

  defp cache_key(kind, path), do: {__MODULE__, kind, path}

  defp current_stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, {stat.mtime, stat.size, stat.type}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A `symphony.yml` replaces the running config only when it validates.
  defp load_symphony(path) do
    with {:ok, content} <- read_file(path),
         {:ok, value} <- Workflow.parse_symphony(content),
         {:ok, _system_config} <- Config.parse_system(value),
         do: {:ok, value, nil}
  end

  # The workflow's stamp covers the instruction files its playbook line expands, so an
  # edit to one reloads it like an edit to the workflow file.
  defp load_workflow(path) do
    with {:ok, content} <- read_file(path) do
      dir = Workflow.instructions_path(path, content)
      instructions = if dir, do: {dir, Workflow.instructions_stamp(dir)}

      with {:ok, workflow} <- Workflow.parse_repo_workflow(content, Workflow.instructions_on_disk(Path.dirname(path))),
           do: {:ok, workflow, instructions}
    end
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

  # The boot log lists every folder: watched, or refused and why.
  defp boot_watch(dir, state) do
    dir = Path.expand(dir)

    case watch_dir(state, dir) do
      {:ok, state} ->
        Logger.info("Watching config directory=#{dir}")
        state

      {{:error, reason}, state} ->
        Logger.warning("Not watching config directory=#{dir} reason=#{inspect(reason)}; reads check its files by their stamp")
        state
    end
  end

  defp watch_dir(state, dir) do
    cond do
      Map.has_key?(state.watchers, dir) -> {:ok, state}
      not File.dir?(dir) -> {{:error, :enoent}, state}
      File.exists?(Path.join(dir, ".git")) -> {{:error, :repository_root}, state}
      true -> start_dir_watcher(state, dir)
    end
  end

  defp start_dir_watcher(state, dir) do
    case start_watcher(dir) do
      {:ok, watcher} ->
        {:ok, %{state | watchers: Map.put(state.watchers, dir, watcher)}}

      {:error, reason} ->
        Logger.warning("Failed to watch config directory=#{dir} reason=#{inspect(reason)}; reads check its files by their stamp")
        {{:error, reason}, state}

      :ignore ->
        Logger.warning("Config watcher unavailable for directory=#{dir}; reads check its files by their stamp")
        {{:error, :unavailable}, state}
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
        Logger.warning("Config watcher #{inspect(reason_tag)} dir=#{dir}; reads check its files by their stamp until restart")

        %{state | watchers: Map.delete(state.watchers, dir)}

      nil ->
        state
    end
  end

  defp stop_watcher(pid) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
  end

  # Every entry, not only the indexed ones: two reads that load different files at once each put
  # the index back from the copy they read, so one key can drop out of it, and an entry the index
  # no longer names would outlive every clear (TP-1545).
  defp do_clear do
    bump_generation()

    for {{__MODULE__, kind, _path} = key, _entry} when kind in [:symphony, :workflow] <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    :persistent_term.erase(@index_key)
    :ok
  end

  defp reload_event?(events) do
    Enum.any?(events, &(&1 in [:modified, :renamed, :created, :removed, :deleted]))
  end
end
