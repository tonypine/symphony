defmodule SymphonyElixir.ClaudeCode.McpConfig do
  @moduledoc false

  alias SymphonyElixir.AgentMcp
  alias SymphonyElixir.Config.Schema

  @spec inherited_servers(Schema.t(), Path.t()) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def inherited_servers(%Schema{} = settings, host_claude_json_path) when is_binary(host_claude_json_path) do
    case agent_mcp(settings) do
      %Schema.Execution.Mcp{inherit: "allowlist"} = mcp ->
        do_inherited_servers(mcp, host_claude_json_path)

      _mcp ->
        {:ok, %{}}
    end
  end

  def inherited_servers(_settings, _host_claude_json_path), do: {:ok, %{}}

  defp do_inherited_servers(mcp, host_claude_json_path) do
    with {:ok, contents} <- read_host_config(host_claude_json_path),
         {:ok, decoded} <- decode_host_config(contents, host_claude_json_path),
         {:ok, raw_servers} <- extract_mcp_servers(decoded, host_claude_json_path) do
      allowed_names = MapSet.new(mcp.allowed_servers || [])

      raw_servers
      |> Enum.filter(fn {name, _server} -> name != "symphony" and MapSet.member?(allowed_names, name) end)
      |> normalize_inherited_servers(host_claude_json_path)
    end
  end

  defp read_host_config(host_claude_json_path) do
    case File.read(host_claude_json_path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:ok, :missing}
      {:error, reason} -> {:error, {:claude_mcp_inheritance_read_failed, host_claude_json_path, reason}}
    end
  end

  defp decode_host_config(:missing, _host_claude_json_path), do: {:ok, :missing}

  defp decode_host_config(contents, host_claude_json_path) do
    case Jason.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:claude_mcp_inheritance_decode_failed, host_claude_json_path, reason}}
    end
  end

  defp extract_mcp_servers(:missing, _host_claude_json_path), do: {:ok, %{}}

  defp extract_mcp_servers(%{} = decoded, host_claude_json_path) do
    case Map.fetch(decoded, "mcpServers") do
      {:ok, servers} when is_map(servers) ->
        {:ok, servers}

      {:ok, _servers} ->
        {:error, {:claude_mcp_inheritance_invalid_config, host_claude_json_path, :invalid_mcp_servers}}

      :error ->
        {:error, {:claude_mcp_inheritance_invalid_config, host_claude_json_path, :missing_mcp_servers}}
    end
  end

  defp extract_mcp_servers(_decoded, host_claude_json_path) do
    {:error, {:claude_mcp_inheritance_invalid_config, host_claude_json_path, :invalid_root}}
  end

  defp normalize_inherited_servers(raw_servers, host_claude_json_path) do
    Enum.reduce_while(raw_servers, {:ok, %{}}, fn
      {name, %{} = server}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, name, AgentMcp.normalize_claude_server_config(server))}}

      {name, _server}, {:ok, _acc} ->
        {:halt, {:error, {:claude_mcp_inheritance_invalid_server, host_claude_json_path, name, :invalid_server}}}
    end)
  end

  defp agent_mcp(%Schema{execution: %{mcp: %Schema.Execution.Mcp{} = mcp}}), do: mcp
  defp agent_mcp(_settings), do: %Schema.Execution.Mcp{}
end
