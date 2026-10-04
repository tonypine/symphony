defmodule SymphonyElixir.AgentMcp do
  @moduledoc false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.McpShimCommand

  @runtimes ["claude", "codex"]

  @spec declared_servers(Schema.t(), String.t()) :: [{String.t(), Schema.Agent.Mcp.Server.t()}]
  def declared_servers(%Schema{agent: %{mcp: %{servers: servers}}}, runtime) when runtime in @runtimes and is_map(servers) do
    servers
    |> Enum.filter(fn {_name, server} -> targets_runtime?(server, runtime) end)
    |> Enum.sort_by(fn {name, _server} -> name end)
  end

  def declared_servers(_settings, _runtime), do: []

  @spec targets_runtime?(Schema.Agent.Mcp.Server.t(), String.t()) :: boolean()
  def targets_runtime?(%Schema.Agent.Mcp.Server{runtimes: runtimes}, runtime) when runtime in @runtimes and is_list(runtimes) do
    runtime in runtimes
  end

  def targets_runtime?(_server, _runtime), do: false

  @spec claude_server_config(Schema.Agent.Mcp.Server.t()) :: map()
  def claude_server_config(%Schema.Agent.Mcp.Server{transport: "stdio"} = server) do
    %{
      "command" => server.command,
      "args" => server.args || [],
      "env" => server.env || %{}
    }
    |> normalize_claude_server_config()
  end

  def claude_server_config(%Schema.Agent.Mcp.Server{transport: transport} = server) when transport in ["http", "sse"] do
    %{
      "type" => transport,
      "url" => server.url,
      "headers" => server.headers || %{}
    }
    |> normalize_claude_server_config()
  end

  @spec normalize_claude_server_config(map()) :: map()
  def normalize_claude_server_config(%{} = server) do
    transport =
      server
      |> map_value("type")
      |> normalize_transport()

    case transport do
      "stdio" ->
        %{
          "command" => map_value(server, "command"),
          "args" => map_value(server, "args") || [],
          "env" => map_value(server, "env") || %{}
        }
        |> stringify_nested_map_keys()
        |> drop_empty_values()

      transport when transport in ["http", "sse"] ->
        %{
          "type" => transport,
          "url" => map_value(server, "url"),
          "headers" => map_value(server, "headers") || %{}
        }
        |> stringify_nested_map_keys()
        |> drop_empty_values()

      _transport ->
        server
        |> stringify_nested_map_keys()
        |> drop_empty_values()
    end
  end

  @spec codex_server_toml_block(String.t(), Schema.Agent.Mcp.Server.t()) :: String.t()
  def codex_server_toml_block(name, %Schema.Agent.Mcp.Server{transport: "stdio"} = server) when is_binary(name) do
    entries =
      [
        {"command", server.command},
        {"args", server.args || []},
        {"env", server.env || %{}}
      ]
      |> Enum.reject(fn
        {_key, nil} -> true
        {_key, []} -> true
        {_key, map} when map == %{} -> true
        _entry -> false
      end)

    toml_table(["mcp_servers", name], entries)
  end

  @spec symphony_claude_config(map(), Path.t() | nil, Path.t()) :: map()
  def symphony_claude_config(mcp_session, socket_path, shim_path) do
    {command, args, env} = symphony_shim_command(mcp_session, socket_path, shim_path)

    %{
      "command" => command,
      "args" => args,
      "env" => Map.merge(symphony_shim_env(mcp_session), env),
      "alwaysLoad" => true
    }
  end

  @spec symphony_codex_toml_block(map(), Path.t() | nil, Path.t()) :: String.t()
  def symphony_codex_toml_block(mcp_session, socket_path, shim_path) do
    {command, args, env} = symphony_shim_command(mcp_session, socket_path, shim_path)

    toml_table(
      ["mcp_servers", "symphony"],
      [
        {"command", command},
        {"args", args},
        {"env", Map.merge(symphony_shim_env(mcp_session), env)}
      ]
    )
  end

  # Only the shim on this host can run on this VM's ERTS. A remote worker runs
  # the copy installed there, with that host's own `elixir`.
  defp symphony_shim_command(%{shim_path: shim_path} = mcp_session, socket_path, shim_path) do
    McpShimCommand.build(shim_path, symphony_shim_args(mcp_session, socket_path))
  end

  defp symphony_shim_command(mcp_session, socket_path, shim_path) do
    {shim_path, symphony_shim_args(mcp_session, socket_path), %{}}
  end

  defp symphony_shim_args(%{transport: :tcp, tcp_host: host, tcp_port: port}, _socket_path)
       when is_binary(host) and is_integer(port) do
    ["--tcp-host", host, "--tcp-port", Integer.to_string(port)]
  end

  defp symphony_shim_args(_mcp_session, socket_path) when is_binary(socket_path) do
    ["--socket", socket_path]
  end

  defp symphony_shim_env(%{token: token}) when is_binary(token) do
    %{"SYMPHONY_MCP_SESSION_TOKEN" => token}
    |> maybe_put_runtime_path()
  end

  defp maybe_put_runtime_path(env) do
    # Claude may launch MCP servers with only the configured env. A remote
    # worker's shim runs through `#!/usr/bin/env elixir`, so preserve PATH
    # explicitly for that process.
    case System.get_env("PATH") do
      path when is_binary(path) and path != "" -> Map.put(env, "PATH", path)
      _missing -> env
    end
  end

  @spec toml_table([String.t()], [{String.t(), term()}]) :: String.t()
  def toml_table(path, entries) when is_list(path) and is_list(entries) do
    header = "[" <> Enum.map_join(path, ".", &toml_key/1) <> "]"
    body = Enum.map_join(entries, "\n", fn {key, value} -> "#{toml_key(key)} = #{toml_value(value)}" end)
    header <> "\n" <> body <> "\n"
  end

  defp drop_empty_values(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, []}, acc -> acc
      {_key, value}, acc when value == %{} -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key)
  end

  defp normalize_transport(nil), do: "stdio"
  defp normalize_transport(transport) when is_binary(transport), do: transport
  defp normalize_transport(transport), do: to_string(transport)

  defp stringify_nested_map_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_nested_map_keys(value)} end)
  end

  defp stringify_nested_map_keys(value), do: value

  defp toml_value(value) when is_binary(value), do: Jason.encode!(value)
  defp toml_value(value) when is_boolean(value), do: to_string(value)
  defp toml_value(value) when is_integer(value), do: Integer.to_string(value)

  defp toml_value(value) when is_list(value) do
    "[" <> Enum.map_join(value, ", ", &toml_value/1) <> "]"
  end

  defp toml_value(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _nested} -> to_string(key) end)
      |> Enum.map_join(", ", fn {key, nested} -> "#{toml_key(to_string(key))} = #{toml_value(nested)}" end)

    "{ " <> entries <> " }"
  end

  defp toml_value(value), do: value |> to_string() |> toml_value()

  defp toml_key(key) when is_binary(key) do
    if String.match?(key, ~r/^[A-Za-z0-9_-]+$/) do
      key
    else
      Jason.encode!(key)
    end
  end
end
