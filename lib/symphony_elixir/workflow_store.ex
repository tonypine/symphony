defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when `WORKFLOW.md` changes.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Workflow

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    # `instructions` is the directory the workflow's playbook line reads, or nil.
    defstruct [:path, :stamp, :instructions, :workflow, :last_error, :follow_app_env?, :path_resolver]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec current(GenServer.server()) :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current(server \\ __MODULE__) do
    case resolve_server(server) do
      pid when is_pid(pid) ->
        GenServer.call(pid, :current)

      _ ->
        Workflow.load()
    end
  end

  @typedoc """
  Whether the store's `WORKFLOW.md` loads: `:valid` when it does, `:missing` when the
  file is not there and `:invalid` when it does not parse. `error` is the reason of
  the last failed load, nil once a load works again. A store keeps serving its last
  good workflow while the file is missing or invalid.
  """
  @type status :: %{path: Path.t() | nil, status: :valid | :missing | :invalid, error: term()}

  @doc """
  Reloads the store's workflow if it changed and reports whether it loads, or
  `:unavailable` when the store is not running.
  """
  @spec status(GenServer.server()) :: {:ok, status()} | :unavailable
  def status(server \\ __MODULE__) do
    case resolve_server(server) do
      pid when is_pid(pid) -> {:ok, GenServer.call(pid, :status)}
      _ -> :unavailable
    end
  end

  @doc "Classifies a workflow load error: nil is `:valid`, a missing file `:missing`, anything else `:invalid`."
  @spec load_status(term()) :: :valid | :missing | :invalid
  def load_status(nil), do: :valid
  def load_status({:missing_workflow_file, _path, _reason}), do: :missing
  def load_status(_reason), do: :invalid

  @spec force_reload(GenServer.server()) :: :ok | {:error, term()}
  def force_reload(server \\ __MODULE__) do
    case resolve_server(server) do
      pid when is_pid(pid) ->
        GenServer.call(pid, :force_reload)

      _ ->
        case Workflow.load() do
          {:ok, _workflow} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def init(opts) do
    path_resolver = Keyword.get(opts, :path_resolver)
    follow_app_env? = not Keyword.has_key?(opts, :path) and is_nil(path_resolver)
    path = if path_resolver, do: path_resolver.(), else: Keyword.get(opts, :path, Workflow.workflow_file_path())
    allow_invalid? = Keyword.get(opts, :allow_invalid?, false)

    case load_state(path) do
      {:ok, state} ->
        schedule_poll()
        {:ok, %{state | follow_app_env?: follow_app_env?, path_resolver: path_resolver}}

      {:error, reason} when allow_invalid? ->
        schedule_poll()
        {:ok, %State{path: path, last_error: reason, follow_app_env?: follow_app_env?, path_resolver: path_resolver}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, reason, %State{workflow: nil} = new_state} ->
        {:reply, {:error, reason}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:status, _from, %State{} = state) do
    new_state =
      case reload_state(state) do
        {:ok, new_state} -> new_state
        {:error, _reason, new_state} -> new_state
      end

    status = %{path: current_path(new_state), status: load_status(new_state.last_error), error: new_state.last_error}
    {:reply, status, new_state}
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    path = current_path(state)

    if path != state.path do
      reload_path(path, state)
    else
      reload_current_path(path, state)
    end
  end

  defp current_path(%State{follow_app_env?: true}), do: Workflow.workflow_file_path()
  defp current_path(%State{path_resolver: resolver}) when is_function(resolver, 0), do: resolver.()
  defp current_path(%State{path: path}), do: path

  defp reload_path(path, state) do
    case load_state(path) do
      {:ok, new_state} ->
        {:ok, %{new_state | follow_app_env?: state.follow_app_env?, path_resolver: state.path_resolver}}

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, %{state | last_error: reason}}
    end
  end

  defp reload_current_path(path, state) do
    case current_stamp(path, state.instructions) do
      {:ok, stamp} when stamp == state.stamp ->
        {:ok, %{state | last_error: nil}}

      {:ok, _stamp} ->
        reload_path(path, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, %{state | last_error: reason}}
    end
  end

  # Stamped before the load, so an edit made during it reloads on the next check.
  defp load_state(path) do
    with {:ok, content} <- read_workflow(path),
         instructions = Workflow.instructions_path(path, content),
         {:ok, stamp} <- current_stamp(path, instructions),
         {:ok, workflow} <- Workflow.load(path) do
      {:ok, %State{path: path, stamp: stamp, instructions: instructions, workflow: workflow}}
    end
  end

  defp read_workflow(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
    end
  end

  # The stamp covers the instruction files the playbook line expands, so an edit to one
  # reloads the workflow like an edit to `WORKFLOW.md`.
  defp current_stamp(path, instructions) when is_binary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content), Workflow.instructions_stamp(instructions)}}
    else
      {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end

  defp resolve_server(server) when is_pid(server), do: server

  defp resolve_server(server) when is_atom(server) do
    Process.whereis(server)
  end

  defp resolve_server({:via, registry, _key} = server) when is_atom(registry) do
    GenServer.whereis(server)
  end

  defp resolve_server(server), do: GenServer.whereis(server)
end
