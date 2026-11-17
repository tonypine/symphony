defmodule SymphonyElixir.ClaudeCode.McpConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClaudeCode.McpConfig
  alias SymphonyElixir.Config.Schema

  test "allowlist inheritance copies matching host MCP servers and skips absent entries" do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-mcp-allowlist-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    claude_json_path = Path.join(test_root, ".claude.json")
    File.mkdir_p!(test_root)

    File.write!(
      claude_json_path,
      Jason.encode!(%{
        "mcpServers" => %{
          "filesystem" => %{"command" => "node", "args" => ["/srv/filesystem.js"]},
          "github" => %{"type" => "http", "url" => "https://mcp.example/github"},
          "slack" => %{"command" => "slack-mcp"},
          "symphony" => %{"command" => "shadow"}
        }
      })
    )

    settings = settings!(%{inherit: "allowlist", allowed_servers: ["filesystem", "github", "missing", "symphony"]})

    assert {:ok,
            %{
              "filesystem" => %{"command" => "node", "args" => ["/srv/filesystem.js"]},
              "github" => %{"type" => "http", "url" => "https://mcp.example/github"}
            }} = McpConfig.inherited_servers(settings, claude_json_path)
  end

  test "missing host Claude config returns no inherited servers" do
    missing_path = Path.join(System.tmp_dir!(), "missing-claude-#{System.unique_integer([:positive])}.json")
    settings = settings!(%{inherit: "allowlist", allowed_servers: ["filesystem"]})

    assert {:ok, %{}} = McpConfig.inherited_servers(settings, missing_path)
  end

  test "invalid settings return no inherited servers without reading host config" do
    missing_path = Path.join(System.tmp_dir!(), "missing-claude-#{System.unique_integer([:positive])}.json")

    assert {:ok, %{}} = McpConfig.inherited_servers(%{}, missing_path)
    assert {:ok, %{}} = McpConfig.inherited_servers(%Schema{execution: %{}}, missing_path)
  end

  test "host Claude config read failures return structured errors" do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-mcp-read-error-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    File.mkdir_p!(test_root)
    settings = settings!(%{inherit: "allowlist", allowed_servers: ["filesystem"]})

    assert {:error, {:claude_mcp_inheritance_read_failed, ^test_root, _reason}} =
             McpConfig.inherited_servers(settings, test_root)
  end

  test "inherit none does not read host Claude config" do
    missing_path = Path.join(System.tmp_dir!(), "missing-claude-#{System.unique_integer([:positive])}.json")
    settings = settings!(%{inherit: "none"})

    assert {:ok, %{}} = McpConfig.inherited_servers(settings, missing_path)
  end

  test "malformed and wrongly shaped host Claude configs return structured errors" do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-mcp-errors-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    File.mkdir_p!(test_root)
    settings = settings!(%{inherit: "allowlist", allowed_servers: ["filesystem"]})

    malformed_path = Path.join(test_root, "malformed.json")
    File.write!(malformed_path, "{")

    assert {:error, {:claude_mcp_inheritance_decode_failed, ^malformed_path, %Jason.DecodeError{}}} =
             McpConfig.inherited_servers(settings, malformed_path)

    missing_key_path = Path.join(test_root, "missing-key.json")
    File.write!(missing_key_path, Jason.encode!(%{}))

    assert {:error, {:claude_mcp_inheritance_invalid_config, ^missing_key_path, :missing_mcp_servers}} =
             McpConfig.inherited_servers(settings, missing_key_path)

    wrong_shape_path = Path.join(test_root, "wrong-shape.json")
    File.write!(wrong_shape_path, Jason.encode!(%{"mcpServers" => []}))

    assert {:error, {:claude_mcp_inheritance_invalid_config, ^wrong_shape_path, :invalid_mcp_servers}} =
             McpConfig.inherited_servers(settings, wrong_shape_path)

    invalid_root_path = Path.join(test_root, "invalid-root.json")
    File.write!(invalid_root_path, Jason.encode!([]))

    assert {:error, {:claude_mcp_inheritance_invalid_config, ^invalid_root_path, :invalid_root}} =
             McpConfig.inherited_servers(settings, invalid_root_path)

    invalid_server_path = Path.join(test_root, "invalid-server.json")
    File.write!(invalid_server_path, Jason.encode!(%{"mcpServers" => %{"filesystem" => []}}))

    assert {:error, {:claude_mcp_inheritance_invalid_server, ^invalid_server_path, "filesystem", :invalid_server}} =
             McpConfig.inherited_servers(settings, invalid_server_path)
  end

  defp settings!(mcp) do
    {:ok, settings} =
      Schema.parse(%{
        execution: %{mcp: mcp}
      })

    settings
  end
end
