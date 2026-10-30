defmodule SymphonyElixir.AgentMcpTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentMcp
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Agent.Mcp.Server

  test "declared_servers and targets_runtime tolerate unsupported inputs" do
    assert AgentMcp.declared_servers(%{}, "codex") == []
    refute AgentMcp.targets_runtime?(:invalid, "codex")
    refute AgentMcp.targets_runtime?(%Server{runtimes: ["codex"]}, "unknown")
  end

  test "Codex TOML rendering handles empty values, nested env maps, and quoted keys" do
    server = %Server{
      transport: "stdio",
      command: "node",
      args: [],
      env: %{
        "enabled" => true,
        "retries" => 2,
        "nested value" => %{"child-key" => "ok"}
      }
    }

    block = AgentMcp.codex_server_toml_block("example.server", server)

    assert block =~ ~s([mcp_servers."example.server"])
    assert block =~ ~s(command = "node")
    refute block =~ "args"
    assert block =~ "enabled = true"
    assert block =~ "retries = 2"
    assert block =~ ~s("nested value" = { child-key = "ok" })
  end

  test "Codex TOML rendering drops nil entries and stringifies fallback values" do
    block =
      AgentMcp.codex_server_toml_block("fallback", %Server{
        transport: "stdio",
        command: nil,
        args: [:not_a_string],
        env: %{"mode" => :atom_value}
      })

    refute block =~ "command"
    assert block =~ ~s(args = ["not_a_string"])
    assert block =~ ~s(mode = "atom_value")
  end

  test "Claude stdio config drops nil and empty values" do
    assert AgentMcp.claude_server_config(%Server{transport: "stdio", command: "node"}) == %{"command" => "node"}
    assert AgentMcp.claude_server_config(%Server{transport: "stdio", command: nil}) == %{}
  end

  test "symphony Claude config rejects malformed :tcp session instead of emitting [\"--socket\", nil]" do
    malformed_tcp_session = %{
      id: "mcp-test",
      transport: :tcp,
      socket_path: nil,
      tcp_host: "127.0.0.1",
      tcp_port: nil,
      token: "session-token"
    }

    assert_raise FunctionClauseError, fn ->
      AgentMcp.symphony_claude_config(malformed_tcp_session, nil, "/tmp/shim")
    end

    assert_raise FunctionClauseError, fn ->
      AgentMcp.symphony_codex_toml_block(malformed_tcp_session, nil, "/tmp/shim")
    end
  end

  test "symphony MCP shim env includes token and runtime PATH" do
    session = %{
      id: "mcp-test",
      transport: :unix,
      socket_path: "/tmp/symphony-mcp.sock",
      token: "session-token"
    }

    config = AgentMcp.symphony_claude_config(session, session.socket_path, "/tmp/shim")
    env = config["env"]

    assert env["SYMPHONY_MCP_SESSION_TOKEN"] == "session-token"
    assert env["PATH"] == System.get_env("PATH")

    block = AgentMcp.symphony_codex_toml_block(session, session.socket_path, "/tmp/shim")
    assert block =~ ~s(SYMPHONY_MCP_SESSION_TOKEN = "session-token")
    assert block =~ "PATH = "
  end

  test "Claude raw server config normalizes transport-specific entries" do
    assert AgentMcp.normalize_claude_server_config(%{
             "command" => "node",
             "args" => [],
             "env" => %{"TOKEN" => "abc"}
           }) == %{"command" => "node", "env" => %{"TOKEN" => "abc"}}

    assert AgentMcp.normalize_claude_server_config(%{
             "type" => "http",
             "url" => "https://mcp.example/http",
             "headers" => %{"Authorization" => "Bearer test"}
           }) == %{
             "type" => "http",
             "url" => "https://mcp.example/http",
             "headers" => %{"Authorization" => "Bearer test"}
           }

    assert AgentMcp.normalize_claude_server_config(%{
             "type" => :custom,
             custom: %{nested_key: "value"},
             empty: []
           }) == %{
             "type" => :custom,
             "custom" => %{"nested_key" => "value"}
           }
  end

  describe "env and headers $VAR expansion" do
    setup do
      System.put_env("SYMPHONY_TEST_MCP_TOKEN", "tok-123")
      System.put_env("SYMPHONY_TEST_MCP_EMPTY", "")
      System.delete_env("SYMPHONY_TEST_MCP_MISSING")

      on_exit(fn ->
        System.delete_env("SYMPHONY_TEST_MCP_TOKEN")
        System.delete_env("SYMPHONY_TEST_MCP_EMPTY")
      end)

      :ok
    end

    test "resolves $VAR references in stdio env and drops empty/keeps missing literally" do
      {:ok, settings} =
        Schema.parse(%{
          agent: %{
            kind: "claude",
            command: "claude",
            mcp: %{
              servers: %{
                "github" => %{
                  transport: "stdio",
                  command: "node",
                  env: %{
                    "GITHUB_TOKEN" => "$SYMPHONY_TEST_MCP_TOKEN",
                    "LITERAL" => "static",
                    "EMPTY_VAR" => "$SYMPHONY_TEST_MCP_EMPTY",
                    "MISSING_VAR" => "$SYMPHONY_TEST_MCP_MISSING",
                    "NOT_A_REF" => "$has space"
                  },
                  runtimes: ["claude"]
                }
              }
            }
          }
        })

      env = settings.agent.mcp.servers["github"].env
      assert env["GITHUB_TOKEN"] == "tok-123"
      assert env["LITERAL"] == "static"
      refute Map.has_key?(env, "EMPTY_VAR")
      assert env["MISSING_VAR"] == "$SYMPHONY_TEST_MCP_MISSING"
      assert env["NOT_A_REF"] == "$has space"
    end

    test "resolves $VAR references in http headers map" do
      {:ok, settings} =
        Schema.parse(%{
          agent: %{
            kind: "claude",
            command: "claude",
            mcp: %{
              servers: %{
                "docs" => %{
                  transport: "http",
                  url: "https://docs.example/mcp",
                  headers: %{
                    "Authorization" => "Bearer $SYMPHONY_TEST_MCP_TOKEN",
                    "X-Token" => "$SYMPHONY_TEST_MCP_TOKEN"
                  },
                  runtimes: ["claude"]
                }
              }
            }
          }
        })

      headers = settings.agent.mcp.servers["docs"].headers
      assert headers["Authorization"] == "Bearer $SYMPHONY_TEST_MCP_TOKEN"
      assert headers["X-Token"] == "tok-123"
    end
  end

  test "declared_servers filters by runtime from parsed settings" do
    {:ok, settings} =
      Schema.parse(%{
        agent: %{
          kind: "codex",
          command: "codex app-server",
          mcp: %{
            servers: %{
              "codex-server" => %{command: "codex", runtimes: ["codex"]},
              "claude-server" => %{command: "claude", runtimes: ["claude"]}
            }
          }
        }
      })

    assert [{"codex-server", %Server{}}] = AgentMcp.declared_servers(settings, "codex")
  end
end

defmodule SymphonyElixir.AgentMcpUnsetPathTest do
  # Not async: it unsets `PATH` while it runs, and every concurrent test that runs a command
  # (`git`, `ssh`) would fail to find it (TP-1297).
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentMcp

  test "symphony MCP shim env omits PATH when host PATH is unset" do
    session = %{
      id: "mcp-test-no-path",
      transport: :unix,
      socket_path: "/tmp/symphony-mcp.sock",
      token: "session-token"
    }

    prior_path = System.get_env("PATH")
    System.delete_env("PATH")

    on_exit(fn ->
      case prior_path do
        nil -> System.delete_env("PATH")
        value -> System.put_env("PATH", value)
      end
    end)

    env = AgentMcp.symphony_claude_config(session, session.socket_path, "/tmp/shim")["env"]

    assert env == %{"SYMPHONY_MCP_SESSION_TOKEN" => "session-token"}
    refute Map.has_key?(env, "PATH")
  end
end
