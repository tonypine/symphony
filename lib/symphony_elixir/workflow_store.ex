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

    defstruct [:path, :stamp, :workflow, :last_error, :follow_app_env?, :path_resolver]
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
        {:error, reason, state}
    end
  end

  defp reload_current_path(path, state) do
    case current_stamp(path) do
      {:ok, stamp} when stamp == state.stamp ->
        {:ok, state}

      {:ok, _stamp} ->
        reload_path(path, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp load_state(path) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, stamp} <- current_stamp(path) do
      {:ok, %State{path: path, stamp: stamp, workflow: workflow}}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_stamp(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    else
      {:error, reason} -> {:error, reason}
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
