defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.SystemSchema

  @required_runtime_functions [
    {SymphonyElixir.ProjectGuidePrompt, :append_to_prompt, 4},
    {SymphonyElixir.ProjectGuides, :append_to_prompt, 4}
  ]

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.CLI.maybe_configure_burrito_runtime()
    :ok = SymphonyElixir.LogFile.configure()

    children = child_specs_for_runtime()

    case Supervisor.start_link(
           children,
           strategy: :one_for_one,
           name: SymphonyElixir.Supervisor
         ) do
      {:ok, _pid} = started ->
        started

      {:error, _reason} = error ->
        clear_runtime_bootstrap_env()
        error
    end
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status_for_runtime()
    :ok
  end

  @doc false
  @spec child_specs_for_runtime(map()) :: [Supervisor.child_spec() | module() | {module(), term()}]
  def child_specs_for_runtime(env \\ System.get_env()) when is_map(env) do
    system_config = Config.system!()
    primary_repo = SystemSchema.primary_repo(system_config)

    try do
      validate_runtime_modules!()
      SymphonyElixir.WorkflowSource.refresh_all(system_config)
      validate_runtime_config!()
      Application.put_env(:symphony_elixir, :primary_repo_name, primary_repo.name)
      SymphonyElixir.Workflow.set_workflow_file_path(SymphonyElixir.WorkflowSource.read_path(primary_repo))

      core_children =
        [
          {Phoenix.PubSub, name: SymphonyElixir.PubSub},
          # Before the task supervisor, so it stops after the agent runners and
          # can stop the agent processes they leave behind.
          SymphonyElixir.AgentProcesses,
          {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
          SymphonyElixir.Config.Cache,
          SymphonyElixir.Linear.Usage,
          SymphonyElixir.McpServer,
          {Registry, keys: :unique, name: SymphonyElixir.Repo.Registry},
          repo_supervisor_specs(system_config.repos),
          SymphonyElixir.Notifications.Notifier
        ]
        |> List.flatten()

      if orchestrator_runtime_disabled?(env) do
        core_children
      else
        (core_children ++
           [
             SymphonyElixir.RunStore
           ] ++
           verification_child_specs(system_config) ++
           [
             SymphonyElixir.Orchestrator,
             pr_review_child_spec(system_config),
             qa_runner_child_spec(system_config),
             SymphonyElixir.StrayProcesses,
             ci_child_spec(system_config),
             human_actions_child_spec(system_config),
             SymphonyElixir.HttpServer,
             SymphonyElixir.StatusDashboard
           ])
        |> Enum.reject(&is_nil/1)
      end
    rescue
      exception ->
        clear_runtime_bootstrap_env()
        reraise exception, __STACKTRACE__
    end
  end

  defp repo_supervisor_specs(repos) do
    Enum.map(repos, &SymphonyElixir.Repo.Supervisor.child_spec/1)
  end

  @doc false
  @spec validate_runtime_modules!() :: :ok
  def validate_runtime_modules! do
    validate_runtime_modules!(@required_runtime_functions)
  end

  @doc false
  @spec validate_runtime_modules!([{module(), atom(), non_neg_integer()}]) :: :ok
  def validate_runtime_modules!(requirements) when is_list(requirements) do
    Enum.each(requirements, fn {module, function, arity} ->
      cond do
        not Code.ensure_loaded?(module) ->
          raise ArgumentError, message: "runtime module unavailable: #{inspect(module)}"

        not function_exported?(module, function, arity) ->
          raise ArgumentError, message: "runtime function unavailable: #{inspect(module)}.#{function}/#{arity}"

        true ->
          :ok
      end
    end)

    :ok
  end

  defp validate_runtime_config! do
    case Config.validate_repo_workflows() do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, message: inspect(reason)
    end
  end

  defp verification_child_specs(%SystemSchema{repos: repos}) do
    Enum.find_value(repos, [], fn repo ->
      settings = Config.settings_for_repo!(repo.name)

      if SymphonyElixir.Verification.enabled?(settings) do
        SymphonyElixir.Verification.child_specs_for_runtime(settings)
      end
    end)
  end

  defp pr_review_child_spec(%SystemSchema{repos: repos}) do
    if Enum.any?(repos, &pr_review_enabled_for_repo?/1) do
      SymphonyElixir.PrReviewPoller
    end
  end

  defp pr_review_enabled_for_repo?(repo) do
    Config.settings_for_repo!(repo.name).pr_review.mode == "polling"
  end

  defp ci_child_spec(%SystemSchema{repos: repos}) do
    if Enum.any?(repos, &ci_enabled_for_repo?/1) do
      SymphonyElixir.CiPoller
    end
  end

  defp human_actions_child_spec(%SystemSchema{repos: repos}) do
    if Enum.any?(repos, &SymphonyElixir.HumanActions.enabled?(Config.settings_for_repo!(&1.name))) do
      SymphonyElixir.HumanActions
    end
  end

  defp qa_runner_child_spec(%SystemSchema{repos: repos}) do
    if Enum.any?(repos, &(ci_enabled_for_repo?(&1) and Config.settings_for_repo!(&1.name).auto_review.enabled)) do
      SymphonyElixir.QaRunner
    end
  end

  defp ci_enabled_for_repo?(repo) do
    settings = Config.settings_for_repo!(repo.name)
    settings.pr_review.mode == "polling" and settings.ci.enabled
  end

  defp clear_runtime_bootstrap_env do
    Application.delete_env(:symphony_elixir, :primary_repo_name)
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    :ok
  end

  defp orchestrator_runtime_disabled?(env) do
    truthy_env?(Map.get(env, "SYMPHONY_DISABLE_ORCHESTRATOR")) ||
      (truthy_env?(Map.get(env, "SYMPHONY_AGENT_RUNTIME")) && Map.get(env, "MIX_ENV") != "test")
  end

  defp truthy_env?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "on"]))
  end

  defp truthy_env?(_value), do: false
end
