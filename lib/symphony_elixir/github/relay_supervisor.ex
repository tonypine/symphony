defmodule SymphonyElixir.GitHub.RelaySupervisor do
  @moduledoc """
  Keeps one `SymphonyElixir.GitHub.Relay` per connected repository, by repository key. At start
  it runs `opts[:resume]` once (by default `SymphonyElixir.GitHub.WebhookSetup.resume/0`), which
  starts the relays of the repositories instant GitHub updates connected before the restart.

  Every call answers as if no relay runs while the supervisor itself isn't running.
  """

  use Supervisor

  alias SymphonyElixir.GitHub.{Relay, WebhookSetup}

  @doc "`opts`: `:name`, `:relay_opts` (given to every relay) and `:resume` (a function, or nil)."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    resume = Keyword.get(opts, :resume, &WebhookSetup.resume/0)

    children =
      [
        {Registry, keys: :unique, name: registry(name), meta: [relay_opts: Keyword.get(opts, :relay_opts, [])]},
        {DynamicSupervisor, name: dynamic(name), strategy: :one_for_one}
      ] ++ if(is_function(resume, 0), do: [Supervisor.child_spec({Task, resume}, restart: :temporary)], else: [])

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Starts `repo_key`'s relay for `spec`, in place of the one it runs."
  @spec start(GenServer.server(), Relay.spec()) :: :ok | {:error, term()}
  def start(supervisor, spec) do
    child = fn -> {Relay, relay_opts(supervisor) ++ [spec: spec, name: via(supervisor, spec.repo_key)]} end

    with true <- running?(supervisor) || {:error, :not_running},
         :ok <- stop(supervisor, spec.repo_key),
         {:ok, _pid} <- DynamicSupervisor.start_child(dynamic(supervisor), child.()) do
      :ok
    end
  end

  @doc "Stops `repo_key`'s relay, if it runs."
  @spec stop(GenServer.server(), String.t()) :: :ok
  def stop(supervisor, repo_key) do
    case pid(supervisor, repo_key) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(dynamic(supervisor), pid) |> then(fn _result -> :ok end)
    end
  end

  @doc "Stops every relay."
  @spec stop_all(GenServer.server()) :: :ok
  def stop_all(supervisor), do: Enum.each(repo_keys(supervisor), &stop(supervisor, &1))

  @doc "Restarts `repo_key`'s `gh` at once; `{:error, :not_running}` when it has no relay."
  @spec restart(GenServer.server(), String.t()) :: :ok | {:error, :not_running}
  def restart(supervisor, repo_key) do
    case pid(supervisor, repo_key) do
      nil -> {:error, :not_running}
      pid -> Relay.restart(pid)
    end
  end

  @doc "`repo_key`'s relay status, or nil when it has none or doesn't answer within `timeout`."
  @spec status(GenServer.server(), String.t(), timeout()) :: Relay.status() | nil
  def status(supervisor, repo_key, timeout \\ 1_000) do
    case pid(supervisor, repo_key) do
      nil -> nil
      pid -> Relay.status(pid, timeout)
    end
  catch
    :exit, _reason -> nil
  end

  @doc "The repository keys that have a relay."
  @spec repo_keys(GenServer.server()) :: [String.t()]
  def repo_keys(supervisor) do
    if running?(supervisor), do: supervisor |> registry() |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}]) |> alive_keys(), else: []
  end

  defp pid(supervisor, repo_key) do
    # The registry forgets a stopped relay a moment after it stops.
    with true <- running?(supervisor),
         [{pid, _value}] <- Registry.lookup(registry(supervisor), repo_key),
         true <- Process.alive?(pid) do
      pid
    else
      _none -> nil
    end
  end

  defp alive_keys(entries), do: for({key, pid} <- entries, Process.alive?(pid), do: key) |> Enum.sort()

  defp running?(supervisor), do: is_pid(GenServer.whereis(supervisor))

  defp relay_opts(supervisor) do
    {:ok, opts} = Registry.meta(registry(supervisor), :relay_opts)
    opts
  end

  defp via(supervisor, repo_key), do: {:via, Registry, {registry(supervisor), repo_key}}
  defp registry(supervisor), do: Module.concat(supervisor, Registry)
  defp dynamic(supervisor), do: Module.concat(supervisor, Relays)
end
