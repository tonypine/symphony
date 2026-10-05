defmodule SymphonyElixir.ClaudeCode.AppServer do
  @moduledoc false

  @behaviour SymphonyElixir.AgentBehaviour

  require Logger
  alias SymphonyElixir.AgentCaches
  alias SymphonyElixir.{AgentEnv, AgentMcp, AgentSandboxConfig, Config, DependencyGate, McpServer, PathSafety, SSH}
  alias SymphonyElixir.{AgentPriority, AgentProcesses}
  alias SymphonyElixir.ClaudeCode.McpConfig
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Agent
  alias SymphonyElixir.GitHub.Hosts
  alias SymphonyElixir.OpenRouter.Models, as: OpenRouterModels
  alias SymphonyElixir.ProjectGuidePrompt
  alias SymphonyElixir.Secret
  alias SymphonyElixir.SharedSkills
  alias SymphonyElixir.UsageLimit

  @openrouter_base_url "https://openrouter.ai/api"
  @agent_runtime_env AgentEnv.runtime_marker_name()
  @agent_runtime_env_value AgentEnv.runtime_marker_value()
  @settings_dir_prefix "symphony-claude-settings-"
  @port_line_bytes 1_048_576
  @approval_handoff_markers [
    "Reviewer agent approved the committed diff.",
    "Review-agent gate status:"
  ]
  @handoff_required_mcp_server "symphony"
  @missing_required_mcp_tools_code "missing_required_mcp_tools"
  @mcp_log_files_scanned 5
  @diagnostic_output_line_count 5
  @diagnostic_output_line_max_bytes 4_096
  # Grace window after a terminal `result`/`turn_completed`/`turn_failed` event
  # during which the loop keeps reading late bookkeeping output while the
  # Claude CLI shuts down. If the OS process never exits (e.g. a lingering tool
  # subprocess keeps it alive) we finalize the turn from the captured result
  # once the grace expires so the caller is not stuck waiting for the port
  # `exit_status`.
  @post_completion_grace_default_ms 1_500
  @denied_commands ["Bash(gh:*)", "Bash(ghe:*)", "Bash(git push:*)", "Bash(git remote add:*)", "Bash(git remote set-url:*)"]
  @file_edit_tools ["Edit", "Write", "NotebookEdit"]

  @type session :: %{
          workspace: Path.t(),
          metadata: map(),
          worker_host: String.t() | nil,
          settings_path: Path.t(),
          mcp_config_path: Path.t(),
          plugin_dir: Path.t(),
          mcp_session: McpServer.session() | nil,
          mcp_remote_socket_path: Path.t() | nil,
          mcp_remote_shim_path: Path.t() | nil,
          run_profile: SymphonyElixir.RunKind.profile() | nil,
          extra_env: %{optional(String.t()) => String.t()}
        }

  # --- AgentBehaviour callbacks ---

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    settings = settings_from_opts(opts)
    run_profile = Keyword.get(opts, :run_profile)

    with :ok <- check_provider(run_profile, worker_host),
         {:ok, run_profile} <- check_model_capabilities(run_profile, settings),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host, settings),
         {:ok, mcp_session, remote_socket_path, remote_shim_path} <-
           start_mcp_session(expanded_workspace, worker_host, opts),
         {:ok, session} <-
           create_session(
             expanded_workspace,
             worker_host,
             settings,
             mcp_session,
             {remote_socket_path, remote_shim_path},
             Keyword.get(opts, :read_only, false)
           ) do
      # Every turn of the session starts Claude with the profile chosen at dispatch, and with
      # the caller's `:extra_env` (a QA pass's own `CLAUDE_CODE_TMPDIR`) on the local host.
      {:ok, Map.merge(session, %{run_profile: run_profile, extra_env: Keyword.get(opts, :extra_env, %{})})}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{workspace: workspace, worker_host: worker_host} = session, prompt, issue, opts) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    settings = settings_from_opts(opts)
    command = settings.agent.command
    turn_timeout_ms = settings.agent.turn_timeout_ms
    command_timeout_ms = settings.agent.command_timeout_ms

    required_mcp_server = required_mcp_server_for_prompt(prompt)

    # Claude writes MCP server logs on the host it runs on.
    mcp_log_workspace = if is_nil(worker_host), do: workspace

    read_opts = [required_mcp_server: required_mcp_server, issue: issue, mcp_log_workspace: mcp_log_workspace]
    # `claude -p` starts a new conversation each turn unless told which one to resume.
    session =
      session
      |> Map.put(:resume_session_id, Keyword.get(opts, :resume_session_id))
      |> Map.put(:run_id, Keyword.get(opts, :run_id))

    with {:ok, prompt} <- ProjectGuidePrompt.append_to_prompt(prompt, workspace, settings, :claude),
         {:ok, port, prompt_cleanup_paths} <- start_port(workspace, command, prompt, worker_host, session) do
      try do
        read_port_output(port, on_message, turn_timeout_ms, command_timeout_ms, read_opts)
      after
        safe_close_port(port)
        remove_local_prompt_files(prompt_cleanup_paths)
      end
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{worker_host: nil} = session) do
    remove_local_runtime_files(runtime_file_paths(session))
    McpServer.stop_session(Map.get(session, :mcp_session))
  end

  def stop_session(%{worker_host: worker_host} = session) when is_binary(worker_host) do
    remove_remote_runtime_files(
      worker_host,
      runtime_file_paths(session),
      Map.get(session, :mcp_remote_socket_path),
      Map.get(session, :mcp_remote_shim_path)
    )

    McpServer.stop_session(Map.get(session, :mcp_session))
  end

  def stop_session(_session), do: :ok

  # --- Sandbox settings ---

  @doc false
  @spec build_sandbox_settings(Agent.NetworkAccess.t(), [String.t()], [String.t()], [String.t()]) :: map()
  def build_sandbox_settings(%Agent.NetworkAccess{mode: mode} = network_access, allow_read_paths \\ [], allow_write_paths \\ [], deny_write_paths \\ []) do
    base =
      %{
        "sandbox" => %{
          "enabled" => true,
          "failIfUnavailable" => true,
          "allowUnsandboxedCommands" => false,
          "filesystem" => AgentSandboxConfig.claude_filesystem_settings(allow_read_paths, allow_write_paths, deny_write_paths)
        }
      }

    # `allowLocalBinding: true` permits bind/listen on 127.0.0.0/8 only.
    # Mix 1.19+ `Mix.Sync.PubSub` opens an ephemeral loopback socket on every
    # mix subcommand; outbound allowlist and credential deny-reads are unaffected.
    case mode do
      "block" ->
        put_in(base, ["sandbox", "network"], %{
          "allowedDomains" => [],
          "allowManagedDomainsOnly" => true,
          "allowLocalBinding" => true
        })

      "allowlist" ->
        effective_domains = effective_allowed_domains(network_access)

        put_in(base, ["sandbox", "network"], %{
          "allowedDomains" => effective_domains,
          "allowManagedDomainsOnly" => true,
          "allowLocalBinding" => true
        })

      "open" ->
        put_in(base, ["sandbox", "network"], %{
          "allowLocalBinding" => true
        })
    end
  end

  # The `settings.json` a Claude session starts with: the sandbox, and the permission rules that
  # deny pushing, the `gh` CLI and the file tools on the write-protected paths the sandbox keeps
  # from the shell. A read-only session (`read_only: true` in `start_session/2`, the acceptance
  # gate) also gets no file-editing tool and can't write its working directory from the shell.
  @doc false
  @spec build_claude_settings(Agent.NetworkAccess.t(), [String.t()], [String.t()], [String.t()], boolean()) :: map()
  def build_claude_settings(network_access, allow_read_paths, allow_write_paths, deny_write_paths \\ [], read_only? \\ false) do
    settings =
      network_access
      |> build_sandbox_settings(allow_read_paths, allow_write_paths, deny_write_paths)
      |> Map.put("permissions", %{"deny" => @denied_commands ++ AgentSandboxConfig.claude_edit_deny_rules(deny_write_paths)})

    if read_only? do
      settings
      |> update_in(["permissions", "deny"], &(&1 ++ @file_edit_tools))
      |> update_in(["sandbox", "filesystem", "denyWrite"], &(&1 ++ ["."]))
    else
      settings
    end
  end

  defp build_mcp_config(mcp_session, socket_path, shim_path, settings) do
    declared_servers =
      settings
      |> AgentMcp.declared_servers("claude")
      |> Map.new(fn {name, server} -> {name, AgentMcp.claude_server_config(server)} end)

    with {:ok, inherited_servers} <- McpConfig.inherited_servers(settings, host_claude_json_path()) do
      {:ok,
       %{
         "mcpServers" =>
           %{
             "symphony" => AgentMcp.symphony_claude_config(mcp_session, socket_path, shim_path)
           }
           |> Map.merge(inherited_servers)
           |> Map.merge(declared_servers)
       }}
    end
  end

  # --- Event parsing ---

  @typep parsed_event ::
           {:session_started, String.t()}
           | {:tool_use, String.t()}
           | {:tool_result, String.t()}
           | {:agent_text, String.t()}
           | {:notification, String.t()}
           | {:turn_completed, map()}
           | {:token_usage_delta, map()}
           | {:turn_failed, String.t()}
           | {:rate_limited, %{retry_after_seconds: nil | non_neg_integer(), message: String.t()}, String.t()}
           | {:usage_limited, usage_limit_info()}
           | {:usage_window, String.t(), usage_window()}
           | {:rate_limit_info, map()}
           | {:malformed, String.t()}

  @typedoc "A Claude usage-limit hit: a plan window (five-hour or weekly) is used up."
  @type usage_limit_info :: %{
          provider: String.t(),
          window: String.t() | nil,
          scope: String.t() | :all,
          resets_at: DateTime.t() | nil,
          utilization: number() | nil,
          overage: String.t() | boolean() | nil,
          source: :rate_limit_event | :result_text
        }

  @typedoc "The latest reset time and utilization Claude reported for one usage window."
  @type usage_window :: %{
          window: String.t(),
          status: String.t(),
          resets_at: DateTime.t() | nil,
          utilization: number() | nil
        }

  @doc false
  @spec parse_event(String.t()) :: parsed_event | {:multi, [parsed_event]}
  def parse_event(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, event} -> parse_decoded_event(event, line)
      {:error, _reason} -> {:malformed, line}
    end
  end

  # Claude emits many `system` events (init, compact notices, hook output, …).
  # Only `init` marks session start; mapping the rest to :session_started
  # floods the transcript with duplicate "session started" entries.
  defp parse_decoded_event(%{"type" => "system", "subtype" => "init", "session_id" => session_id}, _line),
    do: {:session_started, session_id}

  defp parse_decoded_event(%{"type" => "system", "subtype" => subtype}, _line) when is_binary(subtype),
    do: {:notification, "system #{subtype}"}

  defp parse_decoded_event(%{"type" => "system"}, _line), do: {:notification, "system event"}

  defp parse_decoded_event(%{"type" => "assistant", "message" => message}, _line) do
    events = extract_assistant_events(message) ++ extract_assistant_usage_events(message)

    case events do
      [] -> {:notification, "assistant message"}
      [event] -> event
      events -> {:multi, events}
    end
  end

  defp parse_decoded_event(%{"type" => "user", "message" => message}, _line) do
    case extract_tool_result_events(message) do
      [] -> {:notification, "tool_result"}
      [event] -> event
      events -> {:multi, events}
    end
  end

  defp parse_decoded_event(%{"type" => "tool_use", "name" => name}, _line), do: {:tool_use, name}

  defp parse_decoded_event(%{"type" => "rate_limit_event", "rate_limit_info" => info}, _line),
    do: classify_rate_limit_event(info)

  defp parse_decoded_event(%{"type" => "result", "is_error" => true} = event, line) do
    case usage_limit_from_result(event) do
      {:ok, info} -> {:usage_limited, info}
      :error -> parse_result_event(event, line)
    end
  end

  defp parse_decoded_event(%{"type" => "result"} = event, line), do: parse_result_event(event, line)

  defp parse_decoded_event(_event, line), do: {:malformed, line}

  defp parse_result_event(%{"subtype" => "success"} = event, _line),
    do: {:turn_completed, extract_turn_result(event)}

  defp parse_result_event(%{"subtype" => "error"} = event, _line) do
    event
    |> Map.get("error", "unknown error")
    |> classify_error_event()
  end

  defp parse_result_event(_event, line), do: {:malformed, line}

  @allowed_rate_limit_statuses ["allowed", "allowed_warning"]
  @usage_windows ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

  @rate_limit_pattern ~r/rate[\s_-]?limit|429|too many requests/i
  @retry_after_pattern ~r/retry[\s_-]?after[^\d]{0,8}(\d+)|(\d+)\s*seconds?/i

  defp classify_error_event(reason) when is_binary(reason) do
    if Regex.match?(@rate_limit_pattern, reason) do
      info = %{retry_after_seconds: extract_retry_after(reason), message: reason}
      {:rate_limited, info, reason}
    else
      {:turn_failed, reason}
    end
  end

  defp classify_error_event(reason), do: {:turn_failed, reason}

  @doc false
  @spec event_to_update(any()) :: map() | nil
  def event_to_update({:session_started, session_id}) when is_binary(session_id) do
    %{
      event: :session_started,
      timestamp: DateTime.utc_now(),
      session_id: session_id,
      payload: %{session_id: session_id}
    }
  end

  def event_to_update({:notification, message}) when is_binary(message) do
    %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: message
    }
  end

  def event_to_update({:agent_text, text}) when is_binary(text) do
    %{
      event: :agent_text,
      timestamp: DateTime.utc_now(),
      payload: %{
        method: "agent_message_delta",
        params: %{msg: %{content: text}}
      }
    }
  end

  def event_to_update({:tool_use, name}) when is_binary(name) do
    %{
      event: :tool_use,
      timestamp: DateTime.utc_now(),
      payload: %{
        method: "item/tool/call",
        params: %{tool: name}
      }
    }
  end

  def event_to_update({:tool_result, text}) when is_binary(text) do
    %{
      event: :tool_result,
      timestamp: DateTime.utc_now(),
      payload: %{
        method: "item/tool/result",
        params: %{text: text}
      }
    }
  end

  def event_to_update({:turn_completed, result}) when is_map(result) do
    %{
      event: :turn_completed,
      timestamp: DateTime.utc_now(),
      usage: result,
      payload: %{
        method: "turn/completed",
        usage: result
      }
    }
  end

  def event_to_update({:token_usage, cumulative}) when is_map(cumulative) do
    %{
      event: :token_count,
      timestamp: DateTime.utc_now(),
      usage: cumulative,
      payload: %{
        method: "token_count",
        usage: cumulative
      }
    }
  end

  def event_to_update({:turn_failed, reason}) when is_binary(reason) do
    %{
      event: :turn_failed,
      timestamp: DateTime.utc_now(),
      reason: reason,
      payload: %{
        method: "turn/failed",
        params: %{error: %{message: reason}}
      }
    }
  end

  def event_to_update({:usage_limited, info}) when is_map(info) do
    %{
      event: :usage_limited,
      timestamp: DateTime.utc_now(),
      usage_limit: info,
      message: usage_limit_message(info)
    }
  end

  # Stays a notification on the dashboard; `usage_windows` lets the orchestrator
  # time a later rejection that arrives without a reset time.
  def event_to_update({:usage_window, message, windows}) when is_binary(message) and is_map(windows) do
    %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: message,
      usage_windows: windows
    }
  end

  def event_to_update({:rate_limited, info}) when is_map(info) do
    %{
      event: :rate_limited,
      timestamp: DateTime.utc_now(),
      rate_limits: build_throttle_rate_limits(info),
      message: Map.get(info, :message)
    }
  end

  def event_to_update(_), do: nil

  defp build_throttle_rate_limits(info) do
    primary =
      case Map.get(info, :retry_after_seconds) do
        nil -> %{remaining: 0}
        seconds when is_integer(seconds) -> %{remaining: 0, reset_in_seconds: seconds}
      end

    %{limit_id: "claude-throttled", primary: primary}
  end

  defp extract_retry_after(reason) do
    case Regex.run(@retry_after_pattern, reason, capture: :all_but_first) do
      nil ->
        nil

      captures ->
        captures
        |> Enum.find(&(is_binary(&1) and &1 != ""))
        |> case do
          nil -> nil
          digits -> String.to_integer(digits)
        end
    end
  end

  # --- Private helpers ---

  defp settings_from_opts(opts) do
    case Keyword.get(opts, :settings) do
      %Schema{} = settings -> settings
      _settings -> Config.settings!()
    end
  end

  defp create_session(workspace, worker_host, settings, mcp_session, {remote_socket_path, remote_shim_path}, read_only?) do
    case write_claude_runtime_files(
           workspace,
           worker_host,
           settings,
           mcp_session,
           {remote_socket_path, remote_shim_path},
           read_only?
         ) do
      {:ok, runtime_files} ->
        {:ok,
         %{
           workspace: workspace,
           metadata: %{},
           worker_host: worker_host,
           settings_path: runtime_files.settings_path,
           mcp_config_path: runtime_files.mcp_config_path,
           plugin_dir: runtime_files.plugin_dir,
           mcp_session: mcp_session,
           mcp_remote_socket_path: remote_socket_path,
           mcp_remote_shim_path: remote_shim_path
         }}

      {:error, reason} ->
        cleanup_remote_shim(worker_host, remote_shim_path)
        McpServer.stop_session(mcp_session)
        {:error, reason}
    end
  end

  defp validate_workspace_cwd(workspace, nil, settings) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(settings.workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host, _settings)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_mcp_session(workspace, worker_host, opts) do
    issue = Keyword.get(opts, :issue)

    context = %{
      issue: issue,
      issue_id: Keyword.get(opts, :issue_id),
      workspace: workspace,
      command_security: command_security_context(workspace, worker_host),
      comment_registry: Keyword.get(opts, :linear_comment_registry),
      tool_scope: Keyword.get(opts, :tool_scope),
      tool_opts: tool_opts(opts),
      dependency_gate: DependencyGate.build(workspace, issue, Keyword.get(opts, :settings), opts)
    }

    mcp_opts =
      [
        run_id: Keyword.get(opts, :run_id),
        server: Keyword.get(opts, :mcp_server, McpServer),
        shim_path: Keyword.get(opts, :mcp_shim_path),
        worker_host: worker_host
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case McpServer.start_session(context, mcp_opts) do
      {:ok, mcp_session} ->
        case install_remote_shim(mcp_session, worker_host) do
          {:ok, remote_shim_path} ->
            {:ok, mcp_session, Map.get(mcp_session, :remote_socket_path), remote_shim_path}

          {:error, reason} ->
            McpServer.stop_session(mcp_session)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tool_opts(opts) do
    opts
    |> Keyword.take([:linear_client, :upload_client, :gh_runner, :git_runner, :settings, :tool_scope, :qa_driver, :qa_android_driver])
  end

  defp install_remote_shim(_mcp_session, nil), do: {:ok, nil}

  defp install_remote_shim(%{id: id, shim_path: local_shim_path}, worker_host)
       when is_binary(worker_host) do
    remote_path = remote_shim_path(id)

    case File.read(local_shim_path) do
      {:ok, contents} ->
        command = remote_install_shim_command(remote_path, contents)

        case ssh_module().run(worker_host, command, stderr_to_stdout: true) do
          {:ok, {_output, 0}} ->
            {:ok, remote_path}

          {:ok, {output, status}} ->
            {:error, {:claude_mcp_shim_install_failed, worker_host, status, output}}

          {:error, reason} ->
            {:error, {:claude_mcp_shim_install_failed, worker_host, reason}}
        end

      {:error, reason} ->
        {:error, {:claude_mcp_shim_install_failed, :local_read, local_shim_path, reason}}
    end
  end

  defp remote_shim_path(id) when is_binary(id) do
    Path.join("/tmp", "symphony-mcp-shim-#{id}")
  end

  defp remote_install_shim_command(remote_path, contents) do
    [
      "mkdir -p #{shell_escape(Path.dirname(remote_path))}",
      "printf %s #{shell_escape(contents)} > #{shell_escape(remote_path)}",
      "chmod 0700 #{shell_escape(remote_path)}"
    ]
    |> Enum.join(" && ")
  end

  defp cleanup_remote_shim(nil, _path), do: :ok
  defp cleanup_remote_shim(_worker_host, nil), do: :ok

  defp cleanup_remote_shim(worker_host, path) when is_binary(worker_host) and is_binary(path) do
    case ssh_module().run(worker_host, "rm -f #{shell_escape(path)}", stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      _ -> :ok
    end
  end

  defp write_claude_runtime_files(workspace, worker_host, settings, mcp_session, {socket_path, remote_shim_path}, read_only?) do
    network_access = settings.agent.network_access
    allow_read_paths = workspace_sandbox_allow_read_paths(settings)
    allow_write_paths = workspace_sandbox_allow_write_paths(settings) ++ host_allow_write_paths(worker_host)
    effective_shim_path = effective_shim_path(mcp_session, remote_shim_path)
    effective_socket_path = socket_path || mcp_session.socket_path

    deny_write_paths = host_deny_write_paths(settings, workspace, worker_host)

    settings_json =
      build_claude_settings(network_access, allow_read_paths, allow_write_paths, deny_write_paths, read_only?)

    settings_dir = claude_settings_dir(worker_host, mcp_session)
    settings_path = Path.join(settings_dir, "settings.json")
    mcp_config_path = Path.join(settings_dir, "mcp_config.json")
    plugin_dir = Path.join(settings_dir, "plugin")

    with {:ok, mcp_config_json} <- build_mcp_config(mcp_session, effective_socket_path, effective_shim_path, settings),
         json_runtime_files = [
           {settings_path, settings_json},
           {mcp_config_path, mcp_config_json}
         ],
         {:ok, encoded_json_files} <- encode_runtime_files(json_runtime_files),
         # SKILL.md bodies are markdown, not JSON, so they bypass the JSON encoder and are written
         # verbatim alongside the encoded settings files.
         runtime_files = encoded_json_files ++ SharedSkills.claude_plugin_files(plugin_dir),
         :ok <- write_runtime_files(settings_dir, runtime_files, worker_host) do
      {:ok, %{settings_path: settings_path, mcp_config_path: mcp_config_path, plugin_dir: plugin_dir}}
    end
  end

  defp host_claude_json_path do
    home = System.get_env("HOME") || System.user_home!()
    Path.join(home, ".claude.json")
  end

  defp workspace_sandbox_allow_read_paths(%Schema{workspace: %{sandbox: %{allow_read_paths: paths}}}) when is_list(paths),
    do: paths

  defp workspace_sandbox_allow_read_paths(_settings), do: []

  defp workspace_sandbox_allow_write_paths(%Schema{workspace: %{sandbox: %{allow_write_paths: paths}}}) when is_list(paths),
    do: paths

  defp workspace_sandbox_allow_write_paths(_settings), do: []

  # The item replacement directory lives under the per-user temp dir of the host Claude runs on,
  # which this host can't look up for an SSH worker. A local agent also keeps its Hex,
  # `elixir_make` and PLT caches in Symphony's folder (see `SymphonyElixir.AgentCaches`); an SSH
  # worker keeps its own.
  defp host_allow_write_paths(nil) do
    opts = Application.get_env(:symphony_elixir, :claude_item_replacement_opts, [])
    AgentSandboxConfig.item_replacement_write_paths(opts) ++ AgentCaches.write_paths()
  end

  defp host_allow_write_paths(_worker_host), do: []

  # The real files behind symlinked skills (`.ai/skills/pull -> ../../priv/skills/pull`), and the
  # config, hooks and attributes in the workspace's git dirs: Claude Code lets a worktree's
  # session write the shared repo's `.git` and protects only part of it. An SSH worker's
  # workspace isn't on this host, so it keeps the plain deny list.
  defp host_deny_write_paths(settings, workspace, nil) when is_binary(workspace) do
    link_targets = for path <- AgentSandboxConfig.workspace_link_targets(workspace), do: "./" <> path
    git_dirs = settings |> Schema.runtime_workspace_write_roots(workspace) |> Enum.filter(&File.dir?/1)

    link_targets ++ AgentSandboxConfig.git_metadata_deny_write_paths(git_dirs)
  end

  defp host_deny_write_paths(_settings, _workspace, _worker_host), do: []

  defp claude_settings_dir(nil, %{id: id}) when is_binary(id) do
    Path.join(System.tmp_dir!(), "#{@settings_dir_prefix}#{id}")
  end

  defp claude_settings_dir(worker_host, %{id: id}) when is_binary(worker_host) and is_binary(id) do
    Path.join("/tmp", "#{@settings_dir_prefix}#{id}")
  end

  defp effective_shim_path(_mcp_session, remote_shim_path) when is_binary(remote_shim_path),
    do: remote_shim_path

  defp effective_shim_path(%{shim_path: shim_path}, _remote), do: shim_path

  defp encode_settings_json(sandbox_json) do
    encoder = Application.get_env(:symphony_elixir, :claude_settings_json_encoder, &Jason.encode/2)

    case encoder.(sandbox_json, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:claude_settings_encode_failed, reason}}
    end
  end

  defp encode_runtime_files(runtime_files) do
    runtime_files
    |> Enum.reduce_while({:ok, []}, fn {path, contents}, {:ok, encoded} ->
      case encode_settings_json(contents) do
        {:ok, json} -> {:cont, {:ok, [{path, json} | encoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_runtime_files(settings_dir, encoded_runtime_files, nil) do
    with :ok <- mkdir_claude_dir(settings_dir) do
      write_local_runtime_files(encoded_runtime_files)
    end
  end

  defp write_runtime_files(settings_dir, encoded_runtime_files, worker_host) when is_binary(worker_host) do
    command = remote_write_runtime_files_command(settings_dir, encoded_runtime_files)

    case ssh_module().run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        {:error, {:claude_settings_write_failed, :remote, worker_host, status, output}}

      {:error, reason} ->
        {:error, {:claude_settings_write_failed, :remote, worker_host, reason}}
    end
  end

  defp mkdir_claude_dir(settings_dir) do
    case File.mkdir(settings_dir) do
      :ok ->
        case File.chmod(settings_dir, 0o700) do
          :ok -> :ok
          {:error, reason} -> {:error, {:claude_settings_write_failed, :chmod, settings_dir, reason}}
        end

      {:error, reason} ->
        {:error, {:claude_settings_write_failed, :mkdir, settings_dir, reason}}
    end
  end

  defp write_local_runtime_files(encoded_runtime_files) do
    Enum.reduce_while(encoded_runtime_files, :ok, fn {path, json}, :ok ->
      case write_local_runtime_file(path, json) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_local_runtime_file(settings_path, contents) do
    # Binary write (not File.open + IO.write) so UTF-8 SKILL.md bodies are written verbatim rather
    # than transcoded to latin1. `:exclusive` keeps the create-only guarantee for the runtime files.
    with :ok <- File.mkdir_p(Path.dirname(settings_path)),
         :ok <- File.write(settings_path, contents, [:exclusive]) do
      case File.chmod(settings_path, 0o600) do
        :ok -> :ok
        {:error, reason} -> {:error, {:claude_settings_write_failed, :chmod, settings_path, reason}}
      end
    else
      {:error, reason} ->
        {:error, {:claude_settings_write_failed, :write, settings_path, reason}}
    end
  end

  defp start_port(workspace, command, prompt, nil, session) do
    with {:ok, provider_env} <- provider_env(Map.get(session, :run_profile)),
         {:ok, {executable, command_args}} <- local_command(workspace, command),
         {:ok, prompt_path} <- write_local_prompt_file(workspace, prompt) do
      base_args = command_args ++ claude_settings_args(session)
      args = base_args ++ claude_stream_json_args(base_args) ++ run_profile_args(session) ++ resume_args(session)

      case open_local_prompt_port(executable, args, prompt_path, workspace, Map.merge(Map.get(session, :extra_env, %{}), provider_env)) do
        {:ok, port, priority} ->
          :ok = AgentProcesses.track(port, workspace: workspace)
          :ok = AgentPriority.log_started(port, command, Map.get(session, :run_id), priority)
          {:ok, port, [prompt_path]}

        {:error, reason} ->
          remove_local_prompt_files([prompt_path])
          {:error, reason}
      end
    end
  end

  defp start_port(workspace, command, prompt, worker_host, session) do
    with {:ok, command_words} <- command_words(command),
         {:ok, prompt_path} <- write_local_prompt_file(workspace, prompt) do
      reverse_forwards = mcp_reverse_forwards(session)

      case ssh_module().start_port(
             worker_host,
             remote_launch_command(workspace, command_words, session),
             line: @port_line_bytes,
             env: AgentEnv.build(),
             reverse_forwards: reverse_forwards,
             stdin_path: prompt_path
           ) do
        {:ok, port} ->
          :ok = AgentProcesses.track(port, workspace: workspace)
          {:ok, port, [prompt_path]}

        {:error, reason} ->
          remove_local_prompt_files([prompt_path])
          {:error, reason}
      end
    end
  end

  defp open_local_prompt_port(executable, args, prompt_path, workspace, env) do
    case System.find_executable("sh") do
      nil ->
        {:error, :shell_not_found}

      shell ->
        # `Port.open/2` unsets a variable whose value is empty, so the shell sets those itself.
        empty_exports = for {name, ""} <- env, do: "export #{name}=; "

        shell_args =
          [
            "-c",
            Enum.join(empty_exports) <> "prompt_file=$1; shift; exec \"$@\" < \"$prompt_file\"",
            "symphony-claude-prompt",
            prompt_path,
            executable
            | args
          ]

        {port_executable, port_args, priority} = AgentPriority.command(shell, Enum.map(shell_args, &String.to_charlist/1))

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

        {:ok, port, priority}
    end
  rescue
    exception ->
      {:error, {:agent_command_start_failed, Exception.message(exception)}}
  end

  defp local_command(workspace, command) do
    with {:ok, [program | args]} <- command_words(command),
         {:ok, executable} <- executable_path(workspace, program) do
      {:ok, {executable, args}}
    end
  end

  defp command_words(command) when is_binary(command) do
    case String.trim(command) do
      "" ->
        {:error, :empty_agent_command}

      trimmed ->
        try do
          {:ok, OptionParser.split(trimmed)}
        rescue
          exception ->
            {:error, {:invalid_agent_command, Exception.message(exception)}}
        end
    end
  end

  defp executable_path(workspace, program) do
    cond do
      String.contains?(program, "/") ->
        path =
          case Path.type(program) do
            :absolute -> program
            _relative -> Path.expand(program, workspace)
          end

        if File.exists?(path), do: {:ok, path}, else: {:error, {:agent_command_not_found, program}}

      executable = System.find_executable(program) ->
        {:ok, executable}

      true ->
        {:error, {:agent_command_not_found, program}}
    end
  end

  defp remote_write_runtime_files_command(settings_dir, encoded_runtime_files) do
    write_commands =
      Enum.flat_map(encoded_runtime_files, fn {path, json} ->
        [
          "mkdir -p #{shell_escape(Path.dirname(path))}",
          "printf %s #{shell_escape(json)} > #{shell_escape(path)}",
          "chmod 0600 #{shell_escape(path)}"
        ]
      end)

    [
      "umask 077",
      "mkdir #{shell_escape(settings_dir)}",
      "chmod 0700 #{shell_escape(settings_dir)}"
      | write_commands
    ]
    |> Enum.join(" && ")
  end

  defp remote_remove_runtime_files_command(file_paths, socket_path, shim_path) do
    runtime_dirs =
      file_paths
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()

    file_paths
    |> Enum.map(fn path -> "rm -f #{shell_escape(path)}" end)
    |> Kernel.++([
      remote_path_cleanup_command(socket_path),
      remote_path_cleanup_command(shim_path)
    ])
    # `rm -rf` (not `rmdir`) so the nested `plugin/` skills tree is removed with the settings dir.
    |> Kernel.++(Enum.map(runtime_dirs, fn dir -> "rm -rf #{shell_escape(dir)} 2>/dev/null || true" end))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_path_cleanup_command(path) when is_binary(path) and path != "" do
    "rm -f #{shell_escape(path)}"
  end

  defp remote_path_cleanup_command(_path), do: nil

  defp claude_settings_args(%{settings_path: settings_path, mcp_config_path: mcp_config_path, plugin_dir: plugin_dir})
       when is_binary(settings_path) and is_binary(mcp_config_path) and is_binary(plugin_dir) do
    [
      "--setting-sources",
      "",
      "--settings",
      settings_path,
      "--mcp-config",
      mcp_config_path,
      "--strict-mcp-config",
      # Session-only plugin carrying the Symphony shared skills (commit/pull/linear); discovered
      # without writing SKILL.md files into the workspace worktree.
      "--plugin-dir",
      plugin_dir
    ]
  end

  defp claude_settings_args(_session), do: []

  defp claude_stream_json_args(args) do
    verbose_args = if "--verbose" in args, do: [], else: ["--verbose"]
    verbose_args ++ ["--output-format", "stream-json", "--print"]
  end

  # OpenRouter runs only start locally: the key is passed through the subprocess env, which an
  # SSH worker does not get. Config rejects `openrouter` with `workers.ssh_hosts`; this guards
  # direct callers.
  defp check_provider(%{provider: "openrouter"}, worker_host) when is_binary(worker_host) do
    {:error, {:openrouter_remote_worker_unsupported, worker_host}}
  end

  defp check_provider(profile, _worker_host) do
    with {:ok, _env} <- provider_env(profile), do: :ok
  end

  # Symphony runs need tool use, so an OpenRouter model whose catalog entry lacks `tools` fails
  # the run before `claude` starts. `--effort` is dropped for a model without `reasoning`. When
  # the catalog cannot be read, or does not list the model, the run starts anyway: an OpenRouter
  # outage must not block work, and `symphony check` already rejects unknown ids.
  defp check_model_capabilities(%{provider: "openrouter", model: model} = profile, settings) when is_binary(model) do
    kind = Map.get(profile, :kind)

    case OpenRouterModels.lookup(model) do
      {:ok, %{tools: false}} ->
        Logger.error(
          "OpenRouter run cannot start: model #{model} does not support tools run_kind=#{kind}; " <>
            "set #{Config.run_profile_key(settings, kind, :model)} to a model that lists tools"
        )

        {:error, {:openrouter_model_unsupported, model, kind, :tools}}

      {:ok, %{reasoning: false}} ->
        {:ok, drop_unsupported_effort(profile)}

      {:ok, _capabilities} ->
        {:ok, profile}

      {:error, :unknown_model} ->
        Logger.warning("OpenRouter does not list model #{model}; starting anyway run_kind=#{kind}")
        {:ok, profile}

      {:error, {:unavailable, reason}} ->
        Logger.warning("Could not check OpenRouter model #{model}: #{OpenRouterModels.format_reason(reason)}; starting anyway run_kind=#{kind}")
        {:ok, profile}
    end
  end

  defp check_model_capabilities(profile, _settings), do: {:ok, profile}

  defp drop_unsupported_effort(%{model: model, effort: effort} = profile) when is_binary(effort) do
    warned_key = {__MODULE__, :effort_dropped, model}

    unless :persistent_term.get(warned_key, false) do
      :persistent_term.put(warned_key, true)
      Logger.warning("OpenRouter model #{model} does not support reasoning; starting its runs without --effort #{effort}")
    end

    %{profile | effort: nil}
  end

  defp drop_unsupported_effort(profile), do: profile

  # The env that points `claude` at the run's provider, read at each launch so the key never
  # sits in the session. Anthropic runs add nothing. Every model id `claude` can pick on its own
  # (subagents, the small fast model for background calls, the alias defaults) points at the
  # profile's model, since OpenRouter does not know Anthropic's own ids.
  defp provider_env(%{provider: "openrouter"} = profile) do
    case Config.openrouter_api_key() do
      nil ->
        kind = Map.get(profile, :kind)
        Logger.error("OpenRouter run cannot start: #{Config.openrouter_api_key_env()} is not set run_kind=#{kind}")
        {:error, {:missing_provider_env, Config.openrouter_api_key_env(), kind}}

      api_key ->
        model = Map.get(profile, :model)

        {:ok,
         %{
           "ANTHROPIC_BASE_URL" => @openrouter_base_url,
           "ANTHROPIC_AUTH_TOKEN" => Secret.unwrap(api_key),
           "ANTHROPIC_API_KEY" => "",
           "CLAUDE_CODE_SUBAGENT_MODEL" => model,
           "ANTHROPIC_DEFAULT_HAIKU_MODEL" => model,
           "ANTHROPIC_DEFAULT_SONNET_MODEL" => model,
           "ANTHROPIC_DEFAULT_OPUS_MODEL" => model,
           "ANTHROPIC_SMALL_FAST_MODEL" => model
         }}
    end
  end

  defp provider_env(_profile), do: {:ok, %{}}

  defp run_profile_args(%{run_profile: %{} = profile}) do
    flag_args("--model", Map.get(profile, :model)) ++ flag_args("--effort", Map.get(profile, :effort))
  end

  defp run_profile_args(_session), do: []

  defp resume_args(session), do: flag_args("--resume", Map.get(session, :resume_session_id))

  defp flag_args(_flag, nil), do: []
  defp flag_args(flag, value), do: [flag, value]

  defp remote_launch_command(workspace, command_words, session) do
    command =
      (command_words ++ claude_settings_args(session))
      |> then(&(&1 ++ claude_stream_json_args(&1) ++ run_profile_args(session) ++ resume_args(session)))
      |> Enum.map_join(" ", &shell_escape/1)

    [
      "umask 077",
      "prompt_dir=$(mktemp -d \"${TMPDIR:-/tmp}/symphony-claude-prompt.XXXXXX\")",
      "prompt_file=\"$prompt_dir/prompt\"",
      "cleanup_prompt() { status=$?; rm -f \"$prompt_file\"; rmdir \"$prompt_dir\" 2>/dev/null || true; exit \"$status\"; }",
      "trap cleanup_prompt EXIT INT TERM",
      "cat > \"$prompt_file\"",
      "chmod 0600 \"$prompt_file\"",
      "cd #{shell_escape(workspace)}",
      "#{@agent_runtime_env}=#{@agent_runtime_env_value} #{command} < \"$prompt_file\""
    ]
    |> Enum.join(" && ")
  end

  defp write_local_prompt_file(workspace, prompt) when is_binary(prompt) do
    with {:ok, temp_root} <- prompt_temp_root(workspace),
         {:ok, prompt_dir} <- create_prompt_dir(temp_root),
         prompt_path <- Path.join(prompt_dir, "prompt"),
         :ok <- File.write(prompt_path, prompt, [:write, :exclusive]),
         :ok <- File.chmod(prompt_path, 0o600) do
      {:ok, prompt_path}
    else
      {:error, reason} -> {:error, {:claude_prompt_write_failed, reason}}
    end
  end

  defp create_prompt_dir(temp_root, attempts_remaining \\ 10)

  defp create_prompt_dir(_temp_root, 0), do: {:error, :eexist}

  defp create_prompt_dir(temp_root, attempts_remaining) do
    prompt_dir =
      Path.join(
        temp_root,
        "symphony-claude-prompt-#{System.unique_integer([:positive, :monotonic])}-#{random_suffix()}"
      )

    case File.mkdir(prompt_dir) do
      :ok ->
        case File.chmod(prompt_dir, 0o700) do
          :ok ->
            {:ok, prompt_dir}

          {:error, reason} ->
            # Without 0700 the dir is world-traversable under default umask;
            # remove it so chmod failure doesn't leave a permissive directory.
            _ = File.rmdir(prompt_dir)
            {:error, {:chmod, reason}}
        end

      {:error, :eexist} ->
        create_prompt_dir(temp_root, attempts_remaining - 1)

      {:error, reason} ->
        {:error, {:mkdir, reason}}
    end
  end

  defp random_suffix do
    4
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp prompt_temp_root(workspace) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_temp_root} <- PathSafety.canonicalize(System.tmp_dir!()) do
      if inside_path?(canonical_temp_root, canonical_workspace) do
        {:error, :prompt_temp_root_inside_workspace}
      else
        {:ok, canonical_temp_root}
      end
    end
  end

  defp inside_path?(path, parent) do
    path == parent or String.starts_with?(path, parent <> "/")
  end

  defp runtime_file_paths(session) do
    session
    |> Map.take([:settings_path, :mcp_config_path])
    |> Map.values()
    |> Enum.filter(&is_binary/1)
  end

  defp remove_local_runtime_files(file_paths) when is_list(file_paths) do
    Enum.each(file_paths, fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> Logger.warning("Claude settings cleanup failed path=#{path} reason=#{inspect(reason)}")
      end
    end)

    # `File.rm_rf` (not `rmdir`) so the nested `plugin/` skills tree is removed along with the
    # per-session settings dir. Only Symphony-owned settings dirs are removed, so a path that
    # sits directly in a shared dir such as TMPDIR never takes its siblings with it.
    file_paths
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
    |> Enum.filter(&String.starts_with?(Path.basename(&1), @settings_dir_prefix))
    |> Enum.each(fn dir -> _ = File.rm_rf(dir) end)

    :ok
  end

  defp remove_local_prompt_files(file_paths) when is_list(file_paths) do
    Enum.each(file_paths, fn path ->
      _ = File.rm(path)
      _ = File.rmdir(Path.dirname(path))
    end)

    :ok
  end

  defp remove_remote_runtime_files(worker_host, file_paths, socket_path, shim_path) do
    command = remote_remove_runtime_files_command(file_paths, socket_path, shim_path)

    case ssh_module().run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning("Claude settings cleanup failed worker_host=#{worker_host} paths=#{inspect(file_paths)} status=#{status} output=#{inspect(output)}")

      {:error, reason} ->
        Logger.warning("Claude settings cleanup failed worker_host=#{worker_host} paths=#{inspect(file_paths)} reason=#{inspect(reason)}")
    end

    :ok
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp mcp_reverse_forwards(%{mcp_session: %{socket_path: local_socket}, mcp_remote_socket_path: remote_socket})
       when is_binary(local_socket) and is_binary(remote_socket) do
    [{remote_socket, local_socket}]
  end

  defp mcp_reverse_forwards(_session), do: []

  defp command_security_context(workspace, worker_host) do
    origin_url = discover_origin_url(workspace, worker_host)

    %{
      origin_url: origin_url,
      origin_repo: github_repo_from_url(origin_url),
      origin_gh_repo: github_gh_repo_from_url(origin_url),
      workspace: workspace,
      worker_host: worker_host
    }
  end

  defp discover_origin_url(workspace, nil) when is_binary(workspace) do
    with git when is_binary(git) <- System.find_executable("git"),
         {output, 0} <-
           SymphonyElixir.Workspace.safe_git(git, ["-C", workspace, "remote", "get-url", "origin"]) do
      output |> String.trim() |> blank_to_nil()
    else
      _result -> nil
    end
  end

  defp discover_origin_url(_workspace, worker_host) when is_binary(worker_host), do: nil

  defp github_repo_from_url(url) when is_binary(url) do
    case github_repo_parts_from_url(url) do
      {_host, owner, repo} -> "#{owner}/#{repo}"
      nil -> nil
    end
  end

  defp github_repo_from_url(_url), do: nil

  defp github_gh_repo_from_url(url) when is_binary(url) do
    case github_repo_parts_from_url(url) do
      {"github.com", owner, repo} -> "#{owner}/#{repo}"
      {host, owner, repo} when is_binary(host) -> "#{host}/#{owner}/#{repo}"
      nil -> nil
    end
  end

  defp github_gh_repo_from_url(_url), do: nil

  defp github_repo_parts_from_url(url) when is_binary(url) do
    Enum.find_value(
      [
        ~r{^https?://([^/]+)/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$},
        ~r{^ssh://[^@]+@([^/]+)/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$},
        ~r{^(?:[^@]+@)?([^/:]+):([^/\s]+)/([^/\s]+?)(?:\.git)?/?$},
        ~r{^([^/\s:]*github[^/\s:]*)/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$}
      ],
      fn regex ->
        case Regex.run(regex, url) do
          [_full, host, owner, repo] -> canonical_github_repo_parts(host, owner, repo)
          _ -> nil
        end
      end
    )
  end

  defp canonical_github_repo_parts(host, owner, repo) do
    case Hosts.canonical_github_host(host) do
      {:ok, canonical_host} -> {canonical_host, owner, repo}
      :error -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
  end

  defp ssh_module do
    Application.get_env(:symphony_elixir, :claude_code_ssh_module, SSH)
  end

  defp read_port_output(port, on_message, turn_timeout_ms, command_timeout_ms, opts) do
    now = System.monotonic_time(:millisecond)

    acc = %{
      session_id: nil,
      input_tokens: 0,
      output_tokens: 0,
      turn_failed: nil,
      turn_completed: false,
      diagnostic_output_lines: [],
      required_mcp_server: Keyword.get(opts, :required_mcp_server),
      mcp_servers_checked: false,
      mcp_log_workspace: Keyword.get(opts, :mcp_log_workspace),
      issue: Keyword.get(opts, :issue),
      usage_limited: nil,
      usage_windows: %{}
    }

    loop_state = %{
      turn_deadline: now + turn_timeout_ms,
      command_deadline: nil,
      command_timeout_ms: command_timeout_ms,
      active_tool_uses: 0,
      pending_line: "",
      post_completion_deadline: nil
    }

    read_loop(port, on_message, acc, loop_state)
  end

  defp read_loop(port, on_message, acc, loop_state) do
    timeout = compute_read_timeout(loop_state)

    receive do
      {^port, {:data, {:eol, line}}} ->
        handle_eol_line(port, on_message, acc, loop_state, line)

      {^port, {:data, {:noeol, partial}}} ->
        read_loop(port, on_message, acc, %{loop_state | pending_line: loop_state.pending_line <> partial})

      {^port, {:exit_status, 0}} ->
        finalize_read_result(acc)

      {^port, {:exit_status, status}} ->
        handle_nonzero_exit(acc, loop_state, status)
    after
      timeout ->
        handle_read_loop_timeout(acc, loop_state)
    end
  end

  defp compute_read_timeout(%{turn_deadline: turn_deadline, command_deadline: command_deadline, post_completion_deadline: post_completion_deadline}) do
    now = System.monotonic_time(:millisecond)

    [
      max(1, turn_deadline - now),
      command_deadline && max(1, command_deadline - now),
      post_completion_deadline && max(1, post_completion_deadline - now)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.min()
  end

  defp handle_eol_line(port, on_message, acc, loop_state, line) do
    full_line = loop_state.pending_line <> line
    event = parse_event(full_line)

    tracked_loop_state = update_command_tracking(loop_state, event)

    new_acc =
      event
      |> apply_event(on_message, acc)
      |> then(&check_symphony_mcp_server(full_line, on_message, &1))

    new_loop_state = %{
      tracked_loop_state
      | pending_line: "",
        post_completion_deadline: maybe_start_post_completion_grace(new_acc, loop_state.post_completion_deadline)
    }

    read_loop(port, on_message, new_acc, new_loop_state)
  end

  defp handle_nonzero_exit(acc, loop_state, status) do
    if terminal_event_observed?(acc) do
      Logger.info("Claude terminal result before non-zero exit status=#{status} session_id=#{inspect(Map.get(acc, :session_id))}")

      finalize_read_result(acc)
    else
      case diagnostic_output_text(acc, loop_state) do
        nil -> {:error, {:exit_status, status}}
        output -> {:error, {:exit_status, status, %{stderr: output}}}
      end
    end
  end

  defp handle_read_loop_timeout(acc, %{turn_deadline: turn_deadline, post_completion_deadline: post_completion_deadline}) do
    now = System.monotonic_time(:millisecond)

    cond do
      post_completion_deadline != nil and now >= post_completion_deadline ->
        Logger.warning("Claude turn_completed_without_process_exit: finalizing turn after grace period session_id=#{inspect(Map.get(acc, :session_id))}")

        finalize_read_result(acc)

      now >= turn_deadline ->
        {:error, :turn_timeout}

      true ->
        {:error, :command_timeout}
    end
  end

  defp maybe_start_post_completion_grace(acc, nil) do
    if terminal_event_observed?(acc) do
      System.monotonic_time(:millisecond) + post_completion_grace_ms()
    else
      nil
    end
  end

  defp maybe_start_post_completion_grace(_acc, deadline), do: deadline

  defp terminal_event_observed?(acc) do
    Map.get(acc, :turn_completed, false) or is_binary(Map.get(acc, :turn_failed))
  end

  defp post_completion_grace_ms do
    case Application.get_env(:symphony_elixir, :claude_post_completion_grace_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @post_completion_grace_default_ms
    end
  end

  defp finalize_read_result(%{usage_limited: %{} = info}), do: {:error, {:usage_limited, info}}

  defp finalize_read_result(%{turn_failed: reason}) when is_binary(reason) do
    {:error, {:turn_failed, reason}}
  end

  defp finalize_read_result(%{turn_completed: false}) do
    {:error, :no_result_event}
  end

  defp finalize_read_result(acc) do
    {:ok,
     acc
     |> Map.delete(:turn_failed)
     |> Map.delete(:turn_completed)
     |> Map.delete(:diagnostic_output_lines)
     |> Map.delete(:required_mcp_server)
     |> Map.delete(:mcp_servers_checked)
     |> Map.delete(:mcp_log_workspace)
     |> Map.delete(:issue)
     |> Map.delete(:usage_limited)
     |> Map.delete(:usage_windows)}
  end

  defp required_mcp_server_for_prompt(prompt) when is_binary(prompt) do
    if Enum.any?(@approval_handoff_markers, &String.contains?(prompt, &1)) do
      @handoff_required_mcp_server
    else
      nil
    end
  end

  defp required_mcp_server_for_prompt(_prompt), do: nil

  defp check_symphony_mcp_server(line, on_message, %{mcp_servers_checked: false} = acc) do
    # Only `init` lists the session's MCP servers; other `system` events (hooks,
    # status) can arrive first and must not be read as "no servers".
    case Jason.decode(line) do
      {:ok, %{"type" => "system", "subtype" => "init"} = event} ->
        acc = %{acc | mcp_servers_checked: true}

        if mcp_server_available?(event, @handoff_required_mcp_server) do
          acc
        else
          log_symphony_mcp_start_failure(event, acc)
          maybe_fail_missing_required_mcp_server(event, on_message, acc)
        end

      _not_system_event ->
        acc
    end
  end

  defp check_symphony_mcp_server(_line, _on_message, acc), do: acc

  # A turn that doesn't need the Symphony tools goes on without them; the
  # error log above still records why the server didn't start.
  defp maybe_fail_missing_required_mcp_server(event, on_message, %{required_mcp_server: required_mcp_server} = acc)
       when is_binary(required_mcp_server) do
    reason = missing_required_mcp_server_reason(required_mcp_server, event)
    on_message.({:turn_failed, reason})
    %{acc | turn_failed: reason}
  end

  defp maybe_fail_missing_required_mcp_server(_event, _on_message, acc), do: acc

  defp log_symphony_mcp_start_failure(event, acc) do
    session_id = Map.get(event, "session_id")

    Logger.error(
      "Claude Symphony MCP server failed to start #{issue_log_context(acc.issue)} session_id=#{inspect(session_id)} " <>
        "advertised_mcp_servers=#{inspect(advertised_mcp_servers(event))} " <>
        "stderr=#{inspect(symphony_mcp_stderr(acc.mcp_log_workspace, session_id))}"
    )
  end

  # Claude logs each MCP server connection, with the server's stderr, under its
  # cache dir in a folder named after the session's cwd, one file per start.
  defp symphony_mcp_stderr(workspace, session_id) when is_binary(workspace) and is_binary(session_id) do
    log_dir =
      Path.join([
        claude_cache_root(),
        String.replace(workspace, ~r/[^A-Za-z0-9]/, "-"),
        "mcp-logs-#{@handoff_required_mcp_server}"
      ])

    errors =
      case File.ls(log_dir) do
        {:ok, files} ->
          files
          |> Enum.sort(:desc)
          |> Enum.take(@mcp_log_files_scanned)
          |> Enum.flat_map(&mcp_log_errors(Path.join(log_dir, &1), session_id))

        {:error, _reason} ->
          []
      end

    case Enum.uniq(errors) do
      [] -> "unavailable"
      errors -> Enum.join(errors, "\n")
    end
  end

  defp symphony_mcp_stderr(_workspace, _session_id), do: "unavailable"

  defp mcp_log_errors(path, session_id) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&mcp_log_line_error(&1, session_id))

      {:error, _reason} ->
        []
    end
  end

  defp mcp_log_line_error(line, session_id) do
    case Jason.decode(line) do
      {:ok, %{"sessionId" => ^session_id, "error" => error}} when is_binary(error) -> [error]
      _other -> []
    end
  end

  defp claude_cache_root do
    Application.get_env(:symphony_elixir, :claude_cache_root) ||
      default_claude_cache_root(:os.type(), System.get_env("XDG_CACHE_HOME"))
  end

  @doc false
  @spec default_claude_cache_root({atom(), atom()}, String.t() | nil) :: Path.t()
  def default_claude_cache_root({:unix, :darwin}, _xdg_cache_home) do
    Path.join([System.user_home!(), "Library", "Caches", "claude-cli-nodejs"])
  end

  def default_claude_cache_root(_os_type, xdg_cache_home) when is_binary(xdg_cache_home) and xdg_cache_home != "" do
    Path.join(xdg_cache_home, "claude-cli-nodejs")
  end

  def default_claude_cache_root(_os_type, _xdg_cache_home) do
    Path.join([System.user_home!(), ".cache", "claude-cli-nodejs"])
  end

  defp mcp_server_available?(%{"mcp_servers" => servers}, required_server) do
    servers
    |> mcp_server_entries()
    |> Enum.any?(&mcp_server_entry_available?(&1, required_server))
  end

  defp mcp_server_available?(_event, _required_server), do: false

  defp mcp_server_entries(servers) when is_list(servers), do: servers
  defp mcp_server_entries(servers) when is_map(servers), do: Map.to_list(servers)
  defp mcp_server_entries(_servers), do: []

  defp mcp_server_entry_available?(server, required_server) when is_binary(server),
    do: server == required_server

  defp mcp_server_entry_available?({name, status}, required_server) when is_binary(name) do
    name == required_server and mcp_server_status_available?(status)
  end

  defp mcp_server_entry_available?(%{} = server, required_server) do
    server_name = mcp_server_entry_name(server)
    server_name == required_server and mcp_server_status_available?(server)
  end

  defp mcp_server_entry_available?(_server, _required_server), do: false

  defp mcp_server_entry_name(server) when is_map(server) do
    Map.get(server, "name") ||
      Map.get(server, :name) ||
      Map.get(server, "id") ||
      Map.get(server, :id) ||
      Map.get(server, "server") ||
      Map.get(server, :server)
  end

  defp mcp_server_status_available?(%{} = server) do
    server
    |> Map.get("status", Map.get(server, :status))
    |> mcp_server_status_available?()
  end

  defp mcp_server_status_available?(status) when is_binary(status) do
    normalized_status =
      status
      |> String.trim()
      |> String.downcase()

    normalized_status not in ["failed", "error", "disabled", "disconnected", "unavailable"]
  end

  defp mcp_server_status_available?(_status), do: true

  defp missing_required_mcp_server_reason(required_server, event) do
    "#{@missing_required_mcp_tools_code}: required Symphony MCP server is not available " <>
      "in this Claude session. Missing MCP server: #{required_server}. " <>
      "Advertised MCP servers: #{advertised_mcp_servers(event)}."
  end

  defp advertised_mcp_servers(%{"mcp_servers" => servers}) do
    case mcp_server_entries(servers) do
      [] -> "none"
      entries -> Enum.map_join(entries, ", ", &format_mcp_server_entry/1)
    end
  end

  defp advertised_mcp_servers(_event), do: "none"

  defp format_mcp_server_entry(server) when is_binary(server), do: server
  defp format_mcp_server_entry({name, status}), do: "#{name}=#{inspect(status)}"

  defp format_mcp_server_entry(%{} = server) do
    name = mcp_server_entry_name(server) || inspect(server)
    status = Map.get(server, "status", Map.get(server, :status))

    if is_nil(status) do
      to_string(name)
    else
      "#{name}=#{status}"
    end
  end

  defp format_mcp_server_entry(server), do: inspect(server)

  defp update_command_tracking(%{command_timeout_ms: timeout_ms} = loop_state, _event)
       when timeout_ms <= 0 do
    %{loop_state | active_tool_uses: 0, command_deadline: nil}
  end

  defp update_command_tracking(loop_state, event) do
    now = System.monotonic_time(:millisecond)

    {active_tool_uses, command_deadline} =
      apply_command_tracking_event(
        event,
        loop_state.active_tool_uses,
        loop_state.command_deadline,
        loop_state.command_timeout_ms,
        now
      )

    %{loop_state | active_tool_uses: active_tool_uses, command_deadline: command_deadline}
  end

  defp apply_command_tracking_event({:multi, events}, active_tool_uses, command_deadline, timeout_ms, now)
       when is_list(events) do
    Enum.reduce(events, {active_tool_uses, command_deadline}, fn event, {active, deadline} ->
      apply_command_tracking_event(event, active, deadline, timeout_ms, now)
    end)
  end

  defp apply_command_tracking_event({:tool_use, _}, active_tool_uses, _command_deadline, timeout_ms, now) do
    {active_tool_uses + 1, now + timeout_ms}
  end

  defp apply_command_tracking_event({:tool_result, _}, active_tool_uses, command_deadline, _timeout_ms, _now) do
    active_tool_uses = max(active_tool_uses - 1, 0)
    command_deadline = if active_tool_uses == 0, do: nil, else: command_deadline

    {active_tool_uses, command_deadline}
  end

  defp apply_command_tracking_event({:turn_completed, _}, _active_tool_uses, _command_deadline, _timeout_ms, _now),
    do: {0, nil}

  defp apply_command_tracking_event({:turn_failed, _}, _active_tool_uses, _command_deadline, _timeout_ms, _now),
    do: {0, nil}

  defp apply_command_tracking_event({:usage_limited, _info}, _active_tool_uses, _command_deadline, _timeout_ms, _now),
    do: {0, nil}

  defp apply_command_tracking_event(
         {:rate_limited, _info, _reason},
         _active_tool_uses,
         _command_deadline,
         _timeout_ms,
         _now
       ),
       do: {0, nil}

  defp apply_command_tracking_event(_event, active_tool_uses, command_deadline, _timeout_ms, _now),
    do: {active_tool_uses, command_deadline}

  defp apply_event({:multi, events}, on_message, acc) when is_list(events) do
    Enum.reduce(events, acc, fn child, acc -> apply_event(child, on_message, acc) end)
  end

  defp apply_event({:session_started, session_id}, on_message, acc) do
    on_message.({:session_started, session_id})
    %{acc | session_id: session_id}
  end

  defp apply_event({:turn_completed, result}, on_message, acc) do
    on_message.({:turn_completed, result})
    acc |> Map.merge(result) |> Map.put(:turn_completed, true)
  end

  defp apply_event({:token_usage_delta, delta}, on_message, acc) do
    uncached_input =
      Map.get(acc, :uncached_input_tokens, Map.get(acc, :input_tokens, 0)) +
        Map.get(delta, :uncached_input_tokens, Map.get(delta, :input_tokens, 0))

    output = Map.get(acc, :output_tokens, 0) + Map.get(delta, :output_tokens, 0)
    cached = Map.get(acc, :cached_input_tokens, 0) + Map.get(delta, :cached_input_tokens, 0)

    cache_creation =
      Map.get(acc, :cache_creation_input_tokens, 0) + Map.get(delta, :cache_creation_input_tokens, 0)

    cumulative = %{
      input_tokens: uncached_input + cached + cache_creation,
      uncached_input_tokens: uncached_input,
      cached_input_tokens: cached,
      cache_creation_input_tokens: cache_creation,
      output_tokens: output,
      total_tokens: uncached_input + cached + cache_creation + output
    }

    on_message.({:token_usage, cumulative})

    acc
    |> Map.put(:input_tokens, uncached_input + cached + cache_creation)
    |> Map.put(:uncached_input_tokens, uncached_input)
    |> Map.put(:output_tokens, output)
    |> Map.put(:cached_input_tokens, cached)
    |> Map.put(:cache_creation_input_tokens, cache_creation)
  end

  defp apply_event({:turn_failed, reason}, on_message, acc) do
    on_message.({:turn_failed, reason})
    %{acc | turn_failed: reason}
  end

  defp apply_event({:rate_limited, info, reason}, on_message, acc) do
    on_message.({:rate_limited, info})
    on_message.({:turn_failed, reason})
    %{acc | turn_failed: reason}
  end

  # A rejection from the `rate_limit_event` wins over the result text that follows it:
  # only the event carries the window and the epoch reset time.
  defp apply_event({:usage_limited, info}, on_message, acc) do
    info =
      case acc.usage_limited do
        %{source: :rate_limit_event} = earlier -> earlier
        _none_or_fallback -> info
      end

    reason = usage_limit_message(info)
    on_message.({:usage_limited, info})
    on_message.({:turn_failed, reason})
    %{acc | usage_limited: info, turn_failed: reason}
  end

  defp apply_event({:usage_window, message, %{window: window} = usage_window}, on_message, acc) do
    windows = Map.put(acc.usage_windows, window, Map.take(usage_window, [:status, :resets_at, :utilization]))
    on_message.({:usage_window, message, windows})
    %{acc | usage_windows: windows}
  end

  defp apply_event({:rate_limit_info, info}, _on_message, acc) do
    Logger.warning("Claude rate_limit_event not allowed #{issue_log_context(acc.issue)} session_id=#{inspect(acc.session_id)} rate_limit_info=#{inspect(info)}")

    acc
  end

  defp apply_event({:malformed, raw}, _on_message, acc) do
    Logger.debug("ClaudeCode unparseable line: #{inspect(raw)}")
    record_diagnostic_output(acc, raw)
  end

  defp apply_event({kind, _payload} = event, on_message, acc)
       when kind in [:tool_use, :tool_result, :notification, :agent_text] do
    on_message.(event)
    acc
  end

  defp record_diagnostic_output(acc, raw) when is_binary(raw) do
    line = normalize_diagnostic_output_line(raw)

    if line == "" do
      acc
    else
      lines =
        acc
        |> Map.get(:diagnostic_output_lines, [])
        |> Kernel.++([line])
        |> Enum.take(-@diagnostic_output_line_count)

      Map.put(acc, :diagnostic_output_lines, lines)
    end
  end

  defp diagnostic_output_text(acc, loop_state) do
    pending_line = normalize_diagnostic_output_line(Map.get(loop_state, :pending_line, ""))

    lines =
      acc
      |> Map.get(:diagnostic_output_lines, [])
      |> maybe_append_pending_diagnostic_line(pending_line)
      |> Enum.take(-@diagnostic_output_line_count)

    case Enum.join(lines, "\n") do
      "" -> nil
      text -> text
    end
  end

  defp maybe_append_pending_diagnostic_line(lines, ""), do: lines
  defp maybe_append_pending_diagnostic_line(lines, pending_line), do: lines ++ [pending_line]

  defp normalize_diagnostic_output_line(raw) when is_binary(raw) do
    raw
    |> strip_ansi()
    |> String.trim()
    |> truncate_diagnostic_output_line()
  end

  defp truncate_diagnostic_output_line(line) when byte_size(line) <= @diagnostic_output_line_max_bytes, do: line

  defp truncate_diagnostic_output_line(line) do
    truncated = binary_part(line, 0, @diagnostic_output_line_max_bytes)

    if String.valid?(truncated) do
      truncated
    else
      truncate_valid_utf8_prefix(line, @diagnostic_output_line_max_bytes - 1)
    end
  end

  defp truncate_valid_utf8_prefix(_line, byte_count) when byte_count <= 0, do: ""

  defp truncate_valid_utf8_prefix(line, byte_count) do
    truncated = binary_part(line, 0, byte_count)

    if String.valid?(truncated) do
      truncated
    else
      truncate_valid_utf8_prefix(line, byte_count - 1)
    end
  end

  defp strip_ansi(text) when is_binary(text), do: String.replace(text, ~r/\x1b\[[0-9;]*m/, "")

  @doc false
  @spec safe_close_port(port()) :: :ok
  def safe_close_port(port) do
    terminate_port_descendants(port)
    Port.close(port)
    :ok
  rescue
    # Killing descendants can make the CLI exit, and the port can close at
    # any moment after a turn timeout. A closed port is a finished turn.
    ArgumentError -> :ok
  end

  # Send SIGKILL to descendants of the port's OS process before closing the
  # port. Port.close only signals the immediate child, so tool subprocesses
  # spawned by Claude (e.g. a long-running bash loop) would otherwise be
  # reparented to init and keep running.
  defp terminate_port_descendants(port) do
    with {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 <-
           safe_port_info(port, :os_pid) do
      os_pid
      |> collect_descendant_pids([])
      |> Enum.uniq()
      |> Enum.each(&kill_pid/1)
    end

    :ok
  rescue
    exception ->
      Logger.debug("Claude port descendant cleanup raised: #{Exception.message(exception)}")
      :ok
  end

  defp safe_port_info(port, key) do
    Port.info(port, key)
  rescue
    _ -> nil
  end

  defp collect_descendant_pids(pid, acc) when is_integer(pid) and pid > 0 do
    case pgrep_children(pid) do
      [] ->
        acc

      children ->
        Enum.reduce(children, acc, fn child_pid, acc ->
          collect_descendant_pids(child_pid, [child_pid | acc])
        end)
    end
  end

  defp collect_descendant_pids(_pid, acc), do: acc

  defp pgrep_children(pid) when is_integer(pid) do
    case System.find_executable("pgrep") do
      nil -> []
      pgrep -> run_pgrep_children(pgrep, pid)
    end
  rescue
    _ -> []
  end

  defp run_pgrep_children(pgrep, pid) do
    case System.cmd(pgrep, ["-P", to_string(pid)], stderr_to_stdout: true) do
      {output, status} when status in [0, 1] -> parse_pgrep_output(output)
      _ -> []
    end
  end

  defp parse_pgrep_output(output) do
    output
    |> String.split(["\n", " ", "\t"], trim: true)
    |> Enum.flat_map(&parse_pgrep_pid_token/1)
  end

  defp parse_pgrep_pid_token(token) do
    case Integer.parse(token) do
      {child_pid, ""} when child_pid > 0 -> [child_pid]
      _ -> []
    end
  end

  defp kill_pid(pid) when is_integer(pid) and pid > 0 do
    _ = System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp effective_allowed_domains(%Agent.NetworkAccess{
         allowed_domains: extra,
         denied_domains: denied
       }) do
    denied_set = MapSet.new(denied)

    (Schema.claude_built_in_network_allowed_domains() ++ extra)
    |> Enum.reject(&MapSet.member?(denied_set, &1))
    |> Enum.uniq()
  end

  defp extract_assistant_events(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, &assistant_block_event/1)
  end

  defp extract_assistant_events(_), do: []

  defp extract_assistant_usage_events(%{"usage" => usage}) when is_map(usage) do
    uncached_input = token_count(usage, "input_tokens", 0)
    output = token_count(usage, "output_tokens", 0)
    cached = token_count(usage, "cache_read_input_tokens", 0)
    cache_creation = token_count(usage, "cache_creation_input_tokens", 0)

    if uncached_input + output + cached + cache_creation > 0 do
      [
        {:token_usage_delta,
         %{
           input_tokens: uncached_input + cached + cache_creation,
           uncached_input_tokens: uncached_input,
           cached_input_tokens: cached,
           cache_creation_input_tokens: cache_creation,
           output_tokens: output
         }}
      ]
    else
      []
    end
  end

  defp extract_assistant_usage_events(_), do: []

  defp assistant_block_event(%{"type" => "text", "text" => text}) when is_binary(text),
    do: [{:agent_text, text}]

  defp assistant_block_event(%{"type" => "tool_use", "name" => name}) when is_binary(name),
    do: [{:tool_use, name}]

  defp assistant_block_event(_), do: []

  defp extract_tool_result_events(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, &tool_result_block_event/1)
  end

  defp extract_tool_result_events(_), do: []

  defp tool_result_block_event(%{"type" => "tool_result"} = block) do
    case tool_result_text(block) do
      nil -> []
      text -> [{:tool_result, text}]
    end
  end

  defp tool_result_block_event(_), do: []

  defp tool_result_text(%{"content" => content}) when is_binary(content), do: content

  defp tool_result_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(&tool_result_chunk/1)
    |> case do
      [] -> nil
      chunks -> Enum.join(chunks, "\n")
    end
  end

  defp tool_result_text(_), do: nil

  defp tool_result_chunk(%{"type" => "text", "text" => text}) when is_binary(text), do: [text]

  defp tool_result_chunk(%{"type" => "tool_reference", "tool_name" => name}) when is_binary(name),
    do: [name]

  defp tool_result_chunk(_), do: []

  defp classify_rate_limit_event(info) when is_map(info) do
    rate_limit_type = Map.get(info, "rateLimitType", "rate_limit")
    status = Map.get(info, "status", "unknown")
    utilization = Map.get(info, "utilization")

    message =
      case utilization do
        u when is_number(u) ->
          percent = round(u * 100)
          "rate_limit #{rate_limit_type} #{status} (#{percent}% utilization)"

        _ ->
          "rate_limit #{rate_limit_type} #{status}"
      end

    cond do
      status in @allowed_rate_limit_statuses and rate_limit_type in @usage_windows ->
        {:usage_window, message, %{window: rate_limit_type, status: status, resets_at: epoch_to_datetime(Map.get(info, "resetsAt")), utilization: number_or_nil(utilization)}}

      status in @allowed_rate_limit_statuses ->
        {:notification, message}

      rate_limit_type in @usage_windows and not using_overage?(info) ->
        usage_limit = usage_limit_from_rate_limit_info(info, rate_limit_type, utilization)
        {:multi, [{:rate_limit_info, info}, {:usage_limited, usage_limit}]}

      true ->
        {:multi, [{:rate_limit_info, info}, {:rate_limited, %{retry_after_seconds: nil, message: message}, message}]}
    end
  end

  defp classify_rate_limit_event(_), do: {:notification, "rate_limit event"}

  defp usage_limit_from_rate_limit_info(info, window, utilization) do
    %{
      provider: "anthropic",
      window: window,
      scope: UsageLimit.scope_for_window(window),
      resets_at: epoch_to_datetime(Map.get(info, "resetsAt")),
      utilization: number_or_nil(utilization),
      overage: Map.get(info, "overageStatus"),
      source: :rate_limit_event
    }
  end

  # With overage on, Claude keeps serving the request on extra usage, so the
  # window being spent is not a stop.
  defp using_overage?(info), do: Map.get(info, "isUsingOverage") == true or Map.get(info, "overageStatus") == "allowed"

  defp epoch_to_datetime(seconds) when is_integer(seconds) and seconds > 0 do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp epoch_to_datetime(_seconds), do: nil

  defp number_or_nil(value) when is_number(value), do: value
  defp number_or_nil(_value), do: nil

  # Older CLIs end the run with `Claude AI usage limit reached|<epoch>`; newer ones
  # with `You've hit your limit · resets 3pm (Europe/Paris)`.
  @usage_limit_epoch_pattern ~r/usage limit reached(?:\|(\d+))?/i
  @usage_limit_text_pattern ~r/hit your\b[^·\n]*?\blimit(?:\s*·\s*resets\s+(.+?)\s*\(([^)]+)\))?/iu

  defp usage_limit_from_result(event) do
    text = Enum.find(["result", "error"], &is_binary(Map.get(event, &1)))
    text = text && Map.get(event, text)

    cond do
      not is_binary(text) ->
        :error

      captures = Regex.run(@usage_limit_epoch_pattern, text, capture: :all_but_first) ->
        {:ok, result_usage_limit(epoch_capture_to_datetime(captures))}

      captures = Regex.run(@usage_limit_text_pattern, text, capture: :all_but_first) ->
        {:ok, result_usage_limit(reset_text_to_datetime(captures, DateTime.utc_now()))}

      true ->
        :error
    end
  end

  defp result_usage_limit(resets_at) do
    %{
      provider: "anthropic",
      window: nil,
      scope: :all,
      resets_at: resets_at,
      utilization: nil,
      overage: nil,
      source: :result_text
    }
  end

  defp epoch_capture_to_datetime([epoch]), do: epoch_to_datetime(String.to_integer(epoch))
  defp epoch_capture_to_datetime(_captures), do: nil

  # Symphony has no time zone database, so only UTC-like zones resolve to an
  # exact time; other zones leave the reset time unknown.
  defp reset_text_to_datetime([time_text, zone], now) do
    with {:ok, offset_seconds} <- utc_offset_seconds(String.trim(zone)),
         {:ok, date, time} <- parse_reset_wall_time(String.trim(time_text), DateTime.add(now, offset_seconds)) do
      next_reset(date, time, offset_seconds, now)
    else
      _unresolved -> nil
    end
  end

  defp reset_text_to_datetime(_captures, _now), do: nil

  defp utc_offset_seconds(zone) do
    case Regex.run(~r/^(?:UTC|GMT|Etc\/UTC|Etc\/GMT|Z)(?:\s*([+-])(\d{1,2})(?::?(\d{2}))?)?$/i, zone) do
      [_zone] -> {:ok, 0}
      [_zone, sign, hours] -> {:ok, signed_offset(sign, hours, "0")}
      [_zone, sign, hours, minutes] -> {:ok, signed_offset(sign, hours, minutes)}
      nil -> :error
    end
  end

  defp signed_offset(sign, hours, minutes) do
    seconds = String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60
    if sign == "-", do: -seconds, else: seconds
  end

  @reset_time_pattern ~r/^(?:([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/i

  defp parse_reset_wall_time(text, local_now) do
    # `Regex.run/3` drops trailing groups that did not match.
    case Regex.run(@reset_time_pattern, text, capture: :all_but_first) do
      [_month, _day, _hour | _rest] = captures ->
        [month, day, hour, minute, meridiem] = captures ++ List.duplicate("", 5 - length(captures))

        with {:ok, time} <- reset_time(hour, minute, meridiem),
             {:ok, date} <- reset_date(month, day, DateTime.to_date(local_now)) do
          {:ok, date, time}
        end

      nil ->
        :error
    end
  end

  defp reset_time(hour, minute, meridiem) do
    hour = String.to_integer(hour)
    minute = if minute == "", do: 0, else: String.to_integer(minute)

    hour =
      case String.downcase(meridiem) do
        "am" when hour == 12 -> 0
        "pm" when hour < 12 -> hour + 12
        _ -> hour
      end

    Time.new(hour, minute, 0)
  end

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  defp reset_date("", _day, today), do: {:ok, {:next, today}}

  defp reset_date(month, day, today) do
    case Enum.find_index(@months, &(&1 == String.downcase(month))) do
      nil -> :error
      index -> with {:ok, date} <- Date.new(today.year, index + 1, String.to_integer(day)), do: {:ok, {:on, date}}
    end
  end

  # A bare time is its next occurrence; a dated time that is already past is next year's.
  defp next_reset({:next, today}, time, offset_seconds, now) do
    candidate = wall_time_to_utc(today, time, offset_seconds)

    if DateTime.compare(candidate, now) == :gt,
      do: candidate,
      else: wall_time_to_utc(Date.add(today, 1), time, offset_seconds)
  end

  defp next_reset({:on, date}, time, offset_seconds, now) do
    candidate = wall_time_to_utc(date, time, offset_seconds)

    if DateTime.compare(candidate, now) == :gt,
      do: candidate,
      else: wall_time_to_utc(%{date | year: date.year + 1}, time, offset_seconds)
  end

  defp wall_time_to_utc(date, time, offset_seconds) do
    date
    |> DateTime.new!(time)
    |> DateTime.add(-offset_seconds)
  end

  defp usage_limit_message(%{window: window, resets_at: resets_at}) do
    reset = if resets_at, do: " resets_at=#{DateTime.to_iso8601(resets_at)}", else: ""
    "usage_limited #{window || "unknown"}#{reset}"
  end

  defp issue_log_context(issue) when is_map(issue),
    do: "issue_id=#{inspect(Map.get(issue, :id))} issue_identifier=#{inspect(Map.get(issue, :identifier))}"

  defp issue_log_context(_issue), do: "issue_id=nil issue_identifier=nil"

  defp extract_turn_result(event) do
    usage = Map.get(event, "usage", %{})
    uncached_input_tokens = token_count(usage, "input_tokens", 0)
    output_tokens = token_count(usage, "output_tokens", 0)
    cached_input_tokens = token_count(usage, "cache_read_input_tokens", 0)
    cache_creation_input_tokens = token_count(usage, "cache_creation_input_tokens", 0)

    %{
      input_tokens: uncached_input_tokens + cached_input_tokens + cache_creation_input_tokens,
      uncached_input_tokens: uncached_input_tokens,
      cached_input_tokens: cached_input_tokens,
      cache_creation_input_tokens: cache_creation_input_tokens,
      output_tokens: output_tokens,
      total_tokens:
        token_count(usage, "total_tokens", nil) ||
          uncached_input_tokens + cached_input_tokens + cache_creation_input_tokens + output_tokens
    }
  end

  defp token_count(usage, key, default) when is_map(usage) and is_binary(key) do
    case Map.get(usage, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp token_count(_usage, _key, default), do: default
end
