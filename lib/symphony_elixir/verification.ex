defmodule SymphonyElixir.Verification do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Verification.{DevServer, PortPool}

  @env_var "SYMPHONY_VERIFICATION_PORT"
  @dev_server_supervisor SymphonyElixir.Verification.DevServerSupervisor

  @type qa_dev_server :: %{context: context(), pid: pid(), port: pos_integer(), url: String.t()}
  @type context :: %{
          run_id: String.t(),
          repo_key: String.t(),
          port: pos_integer(),
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil
        }

  @doc false
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc false
  @spec child_specs_for_runtime(Schema.t()) :: [Supervisor.child_spec() | module() | {module(), term()}]
  def child_specs_for_runtime(%Schema{} = settings) do
    if enabled?(settings) do
      [
        PortPool,
        {DynamicSupervisor, strategy: :one_for_one, name: @dev_server_supervisor}
      ]
    else
      []
    end
  end

  @doc false
  @spec enabled?(Schema.t()) :: boolean()
  def enabled?(%Schema{verification: %{enabled: enabled}}), do: enabled == true
  def enabled?(_settings), do: false

  @doc "Whether verification is on and `verification.dev_server.start_cmd` is set."
  @spec dev_server_configured?(Schema.t()) :: boolean()
  def dev_server_configured?(%Schema{verification: %{dev_server: %{start_cmd: command}}} = settings),
    do: enabled?(settings) and is_binary(command) and command != ""

  @doc """
  Allocates a port and starts `verification.dev_server` in `workspace` for a QA pass, after its
  `build_cmd`, waiting for its health check. The port is released again when the server does not
  start. Stop it with `stop_qa_dev_server/1`.
  """
  @spec start_qa_dev_server(Issue.t(), String.t(), Path.t(), keyword()) :: {:ok, qa_dev_server()} | {:error, term()}
  def start_qa_dev_server(%Issue{} = issue, run_id, workspace, opts) when is_binary(run_id) and is_binary(workspace) do
    settings = Keyword.fetch!(opts, :settings)

    case allocate_for_dispatch(issue, run_id, nil, opts) do
      {:ok, %{port: port} = context} ->
        case start_dev_server(context, workspace, settings: settings) do
          {:ok, pid} when is_pid(pid) ->
            {:ok, %{context: context, pid: pid, port: port, url: dev_server_url(port, settings)}}

          other ->
            release(context, "qa dev server did not start")
            {:error, dev_server_error(other)}
        end

      {:ok, nil} ->
        {:error, :dev_server_not_configured}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stops a dev server from `start_qa_dev_server/4` and releases its port."
  @spec stop_qa_dev_server(qa_dev_server()) :: :ok
  def stop_qa_dev_server(%{context: context, pid: pid}) do
    stop_dev_server(pid)
    release(context, "qa pass ended")
  end

  @doc "The dev server's base URL: the health check URL's scheme, host and port."
  @spec dev_server_url(pos_integer(), Schema.t()) :: String.t()
  def dev_server_url(port, %Schema{verification: %{dev_server: %{health_check_url: url}}}) when is_integer(port) do
    uri = URI.parse(interpolate_port(url || "", port))
    "#{uri.scheme || "http"}://#{uri.host || "127.0.0.1"}:#{uri.port || port}/"
  end

  @doc "Replaces `$SYMPHONY_VERIFICATION_PORT` and `${SYMPHONY_VERIFICATION_PORT}` in `value`."
  @spec interpolate_port(String.t(), pos_integer()) :: String.t()
  def interpolate_port(value, port) when is_binary(value) do
    port = to_string(port)

    value
    |> String.replace("${#{@env_var}}", port)
    |> String.replace("$#{@env_var}", port)
  end

  defp dev_server_error({:ok, nil}), do: :dev_server_not_configured
  defp dev_server_error({:error, reason}), do: reason

  @doc false
  @spec allocate_for_dispatch(Issue.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, context() | nil} | {:error, term()}
  def allocate_for_dispatch(%Issue{} = issue, run_id, worker_host, opts \\ []) when is_binary(run_id) do
    settings = Keyword.get(opts, :settings, Config.settings!())

    if enabled?(settings) do
      repo_key = Keyword.get(opts, :repo_key, Config.repo_key!())

      attrs = %{
        run_id: run_id,
        repo_key: repo_key,
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        worker_host: worker_host,
        port_range: settings.verification.port_allocation.range
      }

      case PortPool.allocate(attrs, repo_key: repo_key) do
        {:ok, allocation} -> {:ok, allocation_context(allocation)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  @doc false
  @spec context_for_agent(Issue.t(), keyword()) :: {:ok, context() | nil} | {:error, term()}
  def context_for_agent(%Issue{} = issue, opts \\ []) do
    settings = Keyword.get(opts, :settings, Config.settings!())

    cond do
      not enabled?(settings) ->
        {:ok, nil}

      context = Keyword.get(opts, :verification) ->
        {:ok, normalize_context(context)}

      true ->
        run_id = Keyword.get(opts, :run_id) || standalone_run_id(issue)
        allocate_for_dispatch(issue, run_id, Keyword.get(opts, :worker_host), settings: settings)
    end
  end

  @doc false
  @spec env(context() | nil) :: [{String.t(), String.t()}]
  def env(%{port: port}) when is_integer(port), do: [{@env_var, to_string(port)}]
  def env(_context), do: []

  @doc false
  @spec start_dev_server(context() | nil, Path.t(), keyword()) :: {:ok, pid() | nil} | {:error, term()}
  def start_dev_server(nil, _workspace, _opts), do: {:ok, nil}

  def start_dev_server(%{port: port, run_id: run_id} = context, workspace, opts)
      when is_integer(port) and is_binary(run_id) and is_binary(workspace) do
    settings = Keyword.get(opts, :settings, Config.settings!())
    dev_server = settings.verification.dev_server

    case dev_server.start_cmd do
      command when is_binary(command) and command != "" ->
        child_opts = [
          run_id: run_id,
          port: port,
          workspace: workspace,
          config: dev_server,
          env: env(context),
          allowed_domains: Schema.dev_server_network_allowed_domains(settings),
          owner: self()
        ]

        with :ok <- build_dev_server(dev_server, child_opts), do: start_dev_server_child(child_opts)

      _ ->
        {:ok, nil}
    end
  end

  @doc false
  @spec stop_dev_server(pid() | nil) :: :ok
  def stop_dev_server(pid) when is_pid(pid), do: DevServer.stop(pid)
  def stop_dev_server(_pid), do: :ok

  @doc false
  @spec release(context() | nil, String.t()) :: :ok
  def release(%{run_id: run_id, repo_key: repo_key}, reason) when is_binary(run_id),
    do: PortPool.release(run_id, reason, repo_key: repo_key)

  def release(%{run_id: run_id}, reason) when is_binary(run_id), do: PortPool.release(run_id, reason)
  def release(_context, _reason), do: :ok

  defp allocation_context(allocation) when is_map(allocation) do
    %{
      run_id: Map.fetch!(allocation, :run_id),
      repo_key: Map.fetch!(allocation, :repo_key),
      port: Map.fetch!(allocation, :port),
      issue_id: Map.get(allocation, :issue_id),
      issue_identifier: Map.get(allocation, :issue_identifier)
    }
  end

  defp normalize_context(context) when is_map(context), do: allocation_context(context)

  # `build_cmd` runs in the caller, not under the dev server supervisor, so a long build holds up
  # no other run's dev server.
  defp build_dev_server(%{build_cmd: command}, opts) when is_binary(command) and command != "", do: DevServer.build(opts)
  defp build_dev_server(_dev_server, _opts), do: :ok

  defp start_dev_server_child(opts) do
    case Process.whereis(@dev_server_supervisor) do
      pid when is_pid(pid) ->
        DynamicSupervisor.start_child(pid, {DevServer, opts})
        |> normalize_dev_server_start_result()

      _ ->
        DevServer.start(opts)
    end
  end

  defp normalize_dev_server_start_result({:ok, pid}) when is_pid(pid), do: {:ok, pid}
  defp normalize_dev_server_start_result({:ok, pid, _info}) when is_pid(pid), do: {:ok, pid}
  defp normalize_dev_server_start_result({:error, reason}), do: {:error, unwrap_dev_server_start_error(reason)}
  defp normalize_dev_server_start_result(result), do: result

  defp unwrap_dev_server_start_error({:shutdown, reason}), do: unwrap_dev_server_start_error(reason)
  defp unwrap_dev_server_start_error({:failed_to_start_child, _id, reason}), do: unwrap_dev_server_start_error(reason)
  defp unwrap_dev_server_start_error(reason), do: reason

  defp standalone_run_id(%Issue{id: issue_id}) when is_binary(issue_id) do
    "#{issue_id}-verification-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
  end

  defp standalone_run_id(_issue) do
    "verification-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
  end
end
