defmodule SymphonyElixir.Opencode.AppServer do
  @moduledoc """
  The launcher for the `opencode` harness: one `opencode run --format json` process per turn,
  its events read by `SymphonyElixir.Harnesses.EventStream`.

  OpenCode has no sandbox of its own, so every turn runs inside Symphony's
  (`SymphonyElixir.Verification.DevServerSandbox.build_command/4`, the agent's confinement):
  it can write the workspace and the session's own folder only, cannot read the host's
  credential stores, and reaches the network only through a loopback proxy
  (`SymphonyElixir.Verification.EgressProxy`) that tunnels to the allowed hosts: the
  provider's, and the ones `execution.permissions.network` allows.

  A session has a home of its own (config, data, state and cache under the session folder),
  so the operator's OpenCode config, sign-ins and MCP servers never reach a run. Its config
  holds Symphony's tools as an MCP server and the MCP servers `execution.mcp` declares for
  this harness. The provider's key comes from Symphony's environment at each launch
  (`SymphonyElixir.Config.provider_api_key/1`) and reaches the process through its env only.

  A turn continues the session of the turn before it with `--session`. Runs start on this
  host only: the key and the sandbox are both local.
  """

  @behaviour SymphonyElixir.AgentBehaviour

  require Logger

  alias SymphonyElixir.{AgentCaches, AgentEnv, AgentMcp, AgentPriority, AgentProcesses, AgentProviders}
  alias SymphonyElixir.{Config, McpServer, PathSafety, ProjectGuidePrompt}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Harnesses.{EventStream, ToolSession}
  alias SymphonyElixir.Verification.{DevServerSandbox, EgressProxy}

  @harness "opencode"
  @port_line_bytes 1_048_576
  # The hosts OpenCode itself needs: its provider endpoints and its model catalog.
  @provider_hosts ["opencode.ai", "*.opencode.ai", "models.dev"]
  @no_proxy "localhost,127.0.0.1,::1"

  @type session :: map()

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    run_profile = Keyword.get(opts, :run_profile)
    settings = opts |> settings_from_opts() |> Config.launch_settings(run_profile, @harness)

    with :ok <- check_local(Keyword.get(opts, :worker_host)),
         {:ok, workspace} <- validate_workspace_cwd(workspace, settings),
         {:ok, mcp_session} <- ToolSession.start(workspace, nil, opts) do
      case prepare(workspace, settings, mcp_session, opts) do
        {:ok, session} ->
          {:ok, Map.merge(session, %{run_profile: run_profile, extra_env: Keyword.get(opts, :extra_env, %{})})}

        {:error, reason} ->
          McpServer.stop_session(mcp_session)
          {:error, reason}
      end
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{workspace: workspace} = session, prompt, issue, opts) do
    on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)
    settings = opts |> settings_from_opts() |> Config.launch_settings(Map.get(session, :run_profile), @harness)
    session = session |> Map.put(:resume_session_id, Keyword.get(opts, :resume_session_id)) |> Map.put(:run_id, Keyword.get(opts, :run_id))
    warn_unapplied_effort(Map.get(session, :run_profile), issue)

    read_opts = [issue: issue, provider: provider(session), parse: &parse_event/1, label: "OpenCode"]

    with {:ok, prompt} <- ProjectGuidePrompt.append_to_prompt(prompt, workspace, settings, :claude),
         {:ok, port} <- start_port(session, settings, prompt) do
      try do
        port
        |> EventStream.read(once_per_turn(on_message), settings.execution.turn_timeout_ms, settings.execution.command_timeout_ms, read_opts)
        |> with_total_tokens()
      after
        EventStream.close(port)
      end
    end
    |> retry_cold_catalog(session, prompt, issue, opts)
  end

  # A session's home starts with no model catalog, and OpenCode answers a session's first turn
  # before it has fetched one: the model reads as unavailable, and nothing has run. The catalog
  # arrives within a second or two, so that first turn is started again, a few times at most. A
  # model that is still unavailable after that is the turn's answer.
  @cold_catalog_retries 3

  defp retry_cold_catalog({:error, {:turn_failed, "provider.no-route" <> _rest}} = error, session, prompt, issue, opts) do
    retries_left = Keyword.get(opts, :cold_catalog_retries, @cold_catalog_retries)

    if retries_left > 0 and is_nil(Keyword.get(opts, :resume_session_id)) do
      Logger.info("OpenCode has no model catalog yet; starting the turn again issue_identifier=#{inspect(Map.get(issue, :identifier))}")
      Process.sleep(Application.get_env(:symphony_elixir, :opencode_cold_catalog_pause_ms, 1_000))
      run_turn(session, prompt, issue, Keyword.put(opts, :cold_catalog_retries, retries_left - 1))
    else
      error
    end
  end

  defp retry_cold_catalog(result, _session, _prompt, _issue, _opts), do: result

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(%{home: home} = session) do
    if proxy = Map.get(session, :proxy), do: EgressProxy.stop(proxy)
    File.rm_rf(home)
    McpServer.stop_session(Map.get(session, :mcp_session))
  end

  def stop_session(_session), do: :ok

  # OpenCode takes an effort as a model variant, which differs by model, so a run's effort is
  # not passed on.
  defp warn_unapplied_effort(%{effort: effort}, issue) when is_binary(effort) do
    Logger.warning("A run's effort is not applied on the opencode harness effort=#{effort} issue_identifier=#{inspect(Map.get(issue, :identifier))}")
  end

  defp warn_unapplied_effort(_run_profile, _issue), do: :ok

  # --- Events ---

  @doc """
  One line of `opencode run --format json` as an event of the turn
  (`SymphonyElixir.Harnesses.EventStream`). A step that ends for any reason but more tool
  calls ends the turn.
  """
  @spec parse_event(String.t()) :: EventStream.event()
  def parse_event(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = event} when is_binary(type) -> decoded_event(type, event, line)
      _not_an_event -> {:malformed, line}
    end
  end

  defp decoded_event("step_start", %{"sessionID" => session_id}, _line) when is_binary(session_id), do: {:session_started, session_id}
  defp decoded_event("text", %{"part" => %{"text" => text}}, _line) when is_binary(text), do: {:agent_text, text}

  defp decoded_event("tool_use", %{"part" => %{"tool" => tool} = part}, _line) when is_binary(tool) do
    {:multi, [{:tool_use, tool}, {:tool_result, tool_output(part)}]}
  end

  defp decoded_event("step_finish", %{"part" => part}, _line) when is_map(part) do
    usage = {:token_usage_delta, token_usage(Map.get(part, "tokens"))}
    if Map.get(part, "reason") == "tool-calls", do: usage, else: {:multi, [usage, {:turn_completed, %{}}]}
  end

  defp decoded_event("error", %{"error" => error}, _line), do: {:turn_failed, error_text(error)}
  defp decoded_event(_type, _event, line), do: {:malformed, line}

  defp tool_output(%{"state" => %{"output" => output}}) when is_binary(output), do: output
  defp tool_output(%{"state" => %{"status" => status}}) when is_binary(status), do: status
  defp tool_output(_part), do: ""

  # Reasoning is output the provider bills, so it counts as output here.
  defp token_usage(%{} = tokens) do
    cache = Map.get(tokens, "cache") || %{}

    %{
      uncached_input_tokens: count(tokens["input"]),
      cached_input_tokens: count(cache["read"]),
      cache_creation_input_tokens: count(cache["write"]),
      output_tokens: count(tokens["output"]) + count(tokens["reasoning"])
    }
  end

  defp token_usage(_tokens), do: %{}

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: 0

  defp error_text(%{"type" => type, "message" => message}) when is_binary(type) and is_binary(message), do: "#{type}: #{message}"
  defp error_text(%{"message" => message}) when is_binary(message), do: message
  defp error_text(error), do: inspect(error)

  # Every step of a turn names the session; the run hears of it once.
  defp once_per_turn(on_message) do
    key = {__MODULE__, :session_started, make_ref()}

    fn
      {:session_started, _session_id} = message ->
        unless Process.put(key, true), do: on_message.(message)

      message ->
        on_message.(message)
    end
  end

  defp with_total_tokens({:ok, result}) do
    {:ok, Map.put(result, :total_tokens, Map.get(result, :input_tokens, 0) + Map.get(result, :output_tokens, 0))}
  end

  defp with_total_tokens(error), do: error

  # --- Session ---

  defp settings_from_opts(opts) do
    case Keyword.get(opts, :settings) do
      %Schema{} = settings -> settings
      _settings -> Config.settings!()
    end
  end

  defp check_local(nil), do: :ok
  defp check_local(worker_host), do: {:error, {:opencode_remote_worker_unsupported, worker_host}}

  defp validate_workspace_cwd(workspace, settings) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(Path.expand(workspace)),
         {:ok, canonical_root} <- PathSafety.canonicalize(Path.expand(settings.workspace.root)) do
      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace, canonical_root <> "/") ->
          {:ok, canonical_workspace}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  # The session's folder, its OpenCode config, and the proxy its turns reach the network through.
  defp prepare(workspace, settings, mcp_session, opts) do
    home = Path.join(Keyword.get(opts, :agent_tmp_dir) || System.tmp_dir!(), "symphony-opencode-#{mcp_session.id}")

    with :ok <- File.mkdir_p(Path.join(home, "config/opencode")),
         config = config(settings, mcp_session, Keyword.get(opts, :run_profile)),
         :ok <- File.write(Path.join(home, "config/opencode/opencode.json"), Jason.encode!(config)),
         {:ok, proxy} <- EgressProxy.start_link(allowed_domains: allowed_domains(settings), run_id: Keyword.get(opts, :run_id)) do
      session = %{workspace: workspace, worker_host: nil, metadata: %{}, home: home, proxy: proxy}
      {:ok, Map.put(session, :mcp_session, mcp_session)}
    else
      {:error, reason} ->
        File.rm_rf(home)
        {:error, {:opencode_session_start_failed, reason}}
    end
  end

  @doc """
  The session's OpenCode config: Symphony's tools, the MCP servers declared for this harness,
  and the run's small model for OpenCode's background calls, as OpenCode names a model.
  """
  @spec config(Schema.t(), map(), map() | nil) :: map()
  def config(%Schema{} = settings, mcp_session, run_profile \\ nil) do
    symphony = AgentMcp.symphony_claude_config(mcp_session, Map.get(mcp_session, :socket_path), Map.get(mcp_session, :shim_path))

    declared =
      settings
      |> AgentMcp.declared_servers(@harness)
      |> Map.new(fn {name, server} -> {name, mcp_server(AgentMcp.claude_server_config(server))} end)

    %{"$schema" => "https://opencode.ai/config.json", "mcp" => %{"servers" => Map.put(declared, "symphony", mcp_server(symphony))}}
    |> Map.merge(small_model(run_profile))
  end

  defp small_model(%{provider: provider, small_model: model}) when is_binary(provider) and is_binary(model),
    do: %{"small_model" => "#{provider}/#{model}"}

  defp small_model(_run_profile), do: %{}

  defp mcp_server(%{"command" => command} = server) do
    %{"type" => "local", "command" => [command | Map.get(server, "args", [])], "environment" => Map.get(server, "env", %{}), "enabled" => true}
  end

  defp mcp_server(%{"url" => url} = server), do: %{"type" => "remote", "url" => url, "headers" => Map.get(server, "headers", %{}), "enabled" => true}

  @doc "The hosts a session's turns may reach: OpenCode's own, Symphony's built-in dependency hosts and the configured ones, less the denied."
  @spec allowed_domains(Schema.t()) :: [String.t()]
  def allowed_domains(%Schema{execution: %{network_access: network}}) do
    denied = MapSet.new(network.denied_domains || [])

    (@provider_hosts ++ Schema.claude_built_in_network_allowed_domains() ++ (network.allowed_domains || []))
    |> Enum.reject(&MapSet.member?(denied, &1))
    |> Enum.uniq()
  end

  # --- Turn ---

  defp start_port(%{workspace: workspace, home: home} = session, settings, prompt) do
    prompt_path = Path.join(home, "prompt-#{System.unique_integer([:positive])}")

    with {:ok, env} <- provider_env(session),
         :ok <- File.write(prompt_path, prompt),
         {:ok, command} <- command(settings.execution.command, session, prompt_path),
         sandbox = sandbox_opts(session),
         {:ok, [executable | args], _dirs} <- DevServerSandbox.build_command(command, workspace, home, sandbox) do
      open_port(executable, args, workspace, Map.merge(session_env(session), env), session, settings.execution.command)
    end
  end

  defp sandbox_opts(%{proxy: proxy, mcp_session: mcp_session}) do
    socket_dirs = for path <- [Map.get(mcp_session, :socket_path)], is_binary(path), do: Path.dirname(path)
    # Tests stand in for the system sandbox, which a CI host may not have.
    [proxy_port: EgressProxy.port(proxy), socket_dirs: socket_dirs] ++ Application.get_env(:symphony_elixir, :opencode_sandbox_opts, [])
  end

  # The run's provider and model as OpenCode names them, the session to continue, and the
  # prompt on stdin: OpenCode waits on an open stdin before it starts.
  defp command(command, session, prompt_path) when is_binary(command) do
    case String.trim(command) do
      "" ->
        {:error, :empty_agent_command}

      command ->
        args = ["run", "--standalone", "--archived", "--auto", "--format", "json"] ++ model_args(session) ++ resume_args(session)
        {:ok, Enum.join([command | Enum.map(args, &shell_escape/1)], " ") <> " < " <> shell_escape(prompt_path)}
    end
  end

  defp command(_command, _session, _prompt_path), do: {:error, :empty_agent_command}

  defp model_args(%{run_profile: %{provider: provider, model: model}}) when is_binary(provider) and is_binary(model), do: ["--model", "#{provider}/#{model}"]
  defp model_args(_session), do: []

  defp resume_args(%{resume_session_id: session_id}) when is_binary(session_id), do: ["--session", session_id]
  defp resume_args(_session), do: []

  defp provider(%{run_profile: %{provider: provider}}) when is_binary(provider), do: provider
  defp provider(_session), do: "opencode-go"

  defp provider_env(session) do
    provider = provider(session)

    env = AgentProviders.api_key_env(provider)

    case Config.provider_api_key(provider) do
      nil ->
        kind = session |> Map.get(:run_profile) |> then(&(&1 && Map.get(&1, :kind)))
        Logger.error("#{AgentProviders.display_name(provider)} run cannot start: #{env} is not set run_kind=#{kind}")
        {:error, {:missing_provider_env, env, kind}}

      key ->
        {:ok, %{env => SymphonyElixir.Secret.unwrap(key)}}
    end
  end

  # OpenCode's four folders in the session's own, its temp folder there too, and HTTP(S)
  # through the egress proxy.
  defp session_env(%{home: home, proxy: proxy} = session) do
    proxy_url = "http://127.0.0.1:#{EgressProxy.port(proxy)}"

    %{
      "XDG_CONFIG_HOME" => Path.join(home, "config"),
      "XDG_DATA_HOME" => Path.join(home, "data"),
      "XDG_STATE_HOME" => Path.join(home, "state"),
      "XDG_CACHE_HOME" => Path.join(home, "cache"),
      "TMPDIR" => home,
      "HTTP_PROXY" => proxy_url,
      "HTTPS_PROXY" => proxy_url,
      "http_proxy" => proxy_url,
      "https_proxy" => proxy_url,
      "NO_PROXY" => @no_proxy,
      "no_proxy" => @no_proxy
    }
    |> Map.merge(Map.get(session, :extra_env, %{}))
  end

  defp open_port(executable, args, workspace, env, session, command) do
    {port_executable, port_args, priority} = AgentPriority.command(executable, Enum.map(args, &String.to_charlist/1))

    port =
      Port.open(
        {:spawn_executable, port_executable},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          line: @port_line_bytes,
          args: port_args,
          cd: String.to_charlist(workspace),
          env: AgentEnv.build_with(AgentCaches.env() |> Map.merge(AgentEnv.gradle_env(workspace)) |> Map.merge(env))
        ]
      )

    :ok = AgentProcesses.track(port, workspace: workspace)
    :ok = AgentPriority.log_started(port, command, Map.get(session, :run_id), priority)
    {:ok, port}
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
