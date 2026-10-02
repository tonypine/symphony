defmodule SymphonyElixir.Repo.Supervisor do
  @moduledoc """
  Supervises the repo-local runtime subtree for a configured Symphony repo.
  """

  use Supervisor

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.WorkflowSource
  alias SymphonyElixir.WorkflowStore

  @registry SymphonyElixir.Repo.Registry

  @spec child_spec(SystemSchema.Repo.t() | map()) :: Supervisor.child_spec()
  def child_spec(repo) do
    repo_name = repo_name(repo)

    %{
      id: {__MODULE__, repo_name},
      start: {__MODULE__, :start_link, [repo]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @spec start_link(SystemSchema.Repo.t() | map()) :: Supervisor.on_start()
  def start_link(repo) do
    validate_repo!(repo)
    Supervisor.start_link(__MODULE__, repo, name: supervisor_name(repo_name(repo)))
  end

  @spec current_workflow(String.t()) :: {:ok, SymphonyElixir.Workflow.loaded_workflow()} | {:error, term()}
  def current_workflow(repo_name) when is_binary(repo_name) do
    WorkflowStore.current(workflow_store_name(repo_name))
  end

  @spec reload(String.t()) :: :ok | {:error, term()}
  def reload(repo_name) when is_binary(repo_name) do
    supervisor = supervisor_name(repo_name)

    case GenServer.whereis(supervisor) do
      nil ->
        {:error, :repo_supervisor_not_found}

      _pid ->
        with :ok <- terminate_workflow_store(supervisor, repo_name),
             {:ok, _pid} <- Supervisor.restart_child(supervisor, workflow_store_child_id(repo_name)) do
          :ok
        else
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec supervisor_name(String.t()) :: GenServer.name()
  def supervisor_name(repo_name) when is_binary(repo_name), do: {:via, Registry, {@registry, {:repo_supervisor, repo_name}}}

  @spec workflow_store_name(String.t()) :: GenServer.name()
  def workflow_store_name(repo_name) when is_binary(repo_name) do
    if repo_name == Application.get_env(:symphony_elixir, :primary_repo_name) do
      WorkflowStore
    else
      {:via, Registry, {@registry, {:workflow_store, repo_name}}}
    end
  end

  @impl true
  def init(repo) do
    repo_name = repo_name(repo)

    children = [
      %{
        id: workflow_store_child_id(repo_name),
        start: {WorkflowStore, :start_link, [workflow_store_opts(repo)]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp terminate_workflow_store(supervisor, repo_name) do
    case Supervisor.terminate_child(supervisor, workflow_store_child_id(repo_name)) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp workflow_store_process_name(repo), do: workflow_store_name(repo_name(repo))

  defp workflow_store_opts(repo) do
    opts = [name: workflow_store_process_name(repo), allow_invalid?: true]

    if repo_name(repo) == Application.get_env(:symphony_elixir, :primary_repo_name) do
      opts
    else
      Keyword.put(opts, :path, workflow_read_path(repo))
    end
  end

  defp workflow_read_path(%SystemSchema.Repo{} = repo), do: WorkflowSource.read_path(repo)
  defp workflow_read_path(repo), do: SystemSchema.repo_workflow_path(repo)

  defp workflow_store_child_id(repo_name), do: {WorkflowStore, repo_name}

  defp validate_repo!(repo) do
    _name = repo_name(repo)
    _workflow_path = SystemSchema.repo_workflow_path(repo)
    :ok
  end

  defp repo_name(%SystemSchema.Repo{name: name}), do: name
  defp repo_name(%{name: name}), do: name
  defp repo_name(%{"name" => name}), do: name
end
