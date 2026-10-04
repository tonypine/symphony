defmodule SymphonyElixir.Codex.McpConfigTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias SymphonyElixir.Codex.McpConfig
  alias SymphonyElixir.Config.Schema

  @mcp_session %{
    id: "mcp-test",
    socket_path: "/tmp/symphony-mcp.sock",
    shim_path: "/tmp/symphony-mcp-shim",
    token: "session-token"
  }

  test "inherit none writes only the implicit symphony MCP server" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-none-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    host_codex_home = Path.join(test_root, "host-codex")
    File.mkdir_p!(host_codex_home)

    File.write!(Path.join(host_codex_home, "config.toml"), """
    [mcp_servers.host-secret]
    command = "secret-server"
    """)

    settings = settings!(%{inherit: "none"})

    assert {:ok, config} = build_config(settings, host_codex_home)

    assert config =~ "[mcp_servers.symphony]"
    {erlexec, _args, _env} = SymphonyElixir.McpShimCommand.build("/tmp/symphony-mcp-shim", [])
    assert config =~ "command = #{Jason.encode!(erlexec)}"
    assert config =~ ~s("-extra", "/tmp/symphony-mcp-shim", "--socket", "/tmp/symphony-mcp.sock"])
    assert config =~ ~s(SYMPHONY_MCP_SESSION_TOKEN = "session-token")
    assert config =~ "PATH = "
    assert config =~ ~s(BINDIR = )
    assert config =~ ~s(EMU = "beam")
    refute config =~ "--session"
    refute config =~ "host-secret"
  end

  test "implicit symphony MCP server can target loopback TCP without putting the token in argv" do
    session =
      @mcp_session
      |> Map.put(:transport, :tcp)
      |> Map.put(:socket_path, nil)
      |> Map.put(:tcp_host, "127.0.0.1")
      |> Map.put(:tcp_port, 58_213)

    assert {:ok, config} =
             McpConfig.build_config(settings!(%{inherit: "none"}), session, nil, session.shim_path, host_codex_home: nil)

    assert config =~ ~s("/tmp/symphony-mcp-shim", "--tcp-host", "127.0.0.1", "--tcp-port", "58213"])
    assert config =~ ~s(SYMPHONY_MCP_SESSION_TOKEN = "session-token")
    assert config =~ "PATH = "
    refute config =~ "--socket"
    refute config =~ "--session"
  end

  test "allowlist inheritance copies only matching host MCP blocks" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-allowlist-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    host_codex_home = Path.join(test_root, "host-codex")
    File.mkdir_p!(host_codex_home)

    File.write!(Path.join(host_codex_home, "config.toml"), """
    [mcp_servers.example-server]
    command = "node"
    args = ["/srv/context.js"]
    env = { LOG_LEVEL = "info" }

    [mcp_servers.slack]
    command = "slack-mcp"
    """)

    settings = settings!(%{inherit: "allowlist", allowed_servers: ["example-server"]})

    assert {:ok, config} = build_config(settings, host_codex_home)

    assert config =~ "[mcp_servers.example-server]"
    assert config =~ ~s(command = "node")
    refute config =~ "[mcp_servers.slack]"
    refute config =~ "slack-mcp"
  end

  test "inherit all copies all host MCP blocks except reserved symphony" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-all-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    host_codex_home = Path.join(test_root, "host-codex")
    File.mkdir_p!(host_codex_home)

    File.write!(Path.join(host_codex_home, "config.toml"), """
    [mcp_servers.example-server]
    command = "context"

    [mcp_servers.browser]
    command = "browser"

    [mcp_servers.symphony]
    command = "shadow"
    """)

    settings = settings!(%{inherit: "all"})

    assert {:ok, config} = build_config(settings, host_codex_home)

    assert config =~ "[mcp_servers.example-server]"
    assert config =~ "[mcp_servers.browser]"
    refute config =~ ~s(command = "shadow")
  end

  test "declared Codex server overrides an inherited server with the same name" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-override-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    host_codex_home = Path.join(test_root, "host-codex")
    File.mkdir_p!(host_codex_home)

    File.write!(Path.join(host_codex_home, "config.toml"), """
    [mcp_servers.example-server]
    command = "host-node"
    args = ["/host/context.js"]
    """)

    settings =
      settings!(%{
        inherit: "allowlist",
        allowed_servers: ["example-server"],
        servers: %{
          "example-server" => %{
            transport: "stdio",
            command: "declared-node",
            args: ["/declared/context.js"],
            runtimes: ["codex"]
          }
        }
      })

    assert {:ok, config} = build_config(settings, host_codex_home)

    assert config =~ "[mcp_servers.example-server]"
    assert config =~ ~s(command = "declared-node")
    assert config =~ ~s("/declared/context.js")
    refute config =~ "host-node"
    refute config =~ "/host/context.js"
  end

  test "write_home symlinks auth.json without copying credential contents and copies cloud requirements cache" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-home-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    host_codex_home = Path.join(test_root, "host-codex")
    generated_home = Path.join(test_root, "generated-codex-home")
    File.mkdir_p!(host_codex_home)
    File.write!(Path.join(host_codex_home, "auth.json"), "credential contents are not read")
    File.write!(Path.join(host_codex_home, "cloud-requirements-cache.json"), ~s({"cached":true}))

    assert {:ok, runtime_home} =
             McpConfig.write_home(settings!(%{inherit: "none"}), @mcp_session,
               home_path: generated_home,
               host_codex_home: host_codex_home
             )

    assert runtime_home.home_path == generated_home
    assert runtime_home.host_codex_home == host_codex_home
    assert File.read!(runtime_home.config_path) =~ "[mcp_servers.symphony]"
    assert File.read_link!(Path.join(generated_home, "auth.json")) == Path.join(host_codex_home, "auth.json")

    cache_path = Path.join(generated_home, "cloud-requirements-cache.json")
    assert File.read!(cache_path) == ~s({"cached":true})
    assert {:ok, cache_stat} = File.lstat(cache_path)
    refute cache_stat.type == :symlink

    # Shared skills are materialized under $CODEX_HOME/skills for user-scope discovery.
    for name <- SymphonyElixir.SharedSkills.names() do
      skill_path = Path.join([generated_home, "skills", name, "SKILL.md"])
      assert File.read!(skill_path) =~ "name: #{name}"
      assert band(File.stat!(skill_path).mode, 0o777) == 0o600
    end
  end

  test "write_home cleans up generated home when setup fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-home-error-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    file_parent = Path.join(test_root, "file-parent")
    generated_home = Path.join(file_parent, "generated-codex-home")
    File.mkdir_p!(test_root)
    File.write!(file_parent, "not a directory")

    assert {:error, :enotdir} =
             McpConfig.write_home(settings!(%{inherit: "none"}), @mcp_session,
               home_path: generated_home,
               host_codex_home: Path.join(test_root, "host-codex")
             )

    refute File.exists?(generated_home)
  end

  test "write_home cleans up generated home when cloud requirements cache copy fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-cloud-cache-fail-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    host_codex_home = Path.join(test_root, "host-codex")
    generated_home = Path.join(test_root, "generated-codex-home")
    cache_path = Path.join(host_codex_home, "cloud-requirements-cache.json")

    File.mkdir_p!(cache_path)

    assert {:error, {:codex_cloud_requirements_cache_copy_failed, ^cache_path, :eisdir}} =
             McpConfig.write_home(settings!(%{inherit: "none"}), @mcp_session,
               home_path: generated_home,
               host_codex_home: host_codex_home
             )

    refute File.exists?(generated_home)
  end

  test "write_home skips auth.json symlink when host file is missing" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-auth-missing-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    missing_host_home = Path.join(test_root, "host-codex-without-auth")
    generated_home = Path.join(test_root, "generated-codex-home")
    File.mkdir_p!(missing_host_home)

    assert {:ok, runtime_home} =
             McpConfig.write_home(settings!(%{inherit: "none"}), @mcp_session,
               home_path: generated_home,
               host_codex_home: missing_host_home
             )

    refute File.exists?(Path.join(runtime_home.home_path, "auth.json"))
    refute File.exists?(Path.join(runtime_home.home_path, "cloud-requirements-cache.json"))
    assert File.read!(runtime_home.config_path) =~ "[mcp_servers.symphony]"
  end

  test "sync_cloud_requirements_cache persists refreshed generated cache to host home" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-cloud-cache-sync-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    host_codex_home = Path.join(test_root, "host-codex")
    generated_home = Path.join(test_root, "generated-codex-home")
    File.mkdir_p!(generated_home)

    generated_cache = cloud_requirements_cache("2026-05-21T11:00:00Z", "new")
    File.write!(Path.join(generated_home, "cloud-requirements-cache.json"), generated_cache)

    McpConfig.sync_cloud_requirements_cache(%{
      home_path: generated_home,
      host_codex_home: host_codex_home
    })

    assert File.read!(Path.join(host_codex_home, "cloud-requirements-cache.json")) == generated_cache
  end

  test "sync_cloud_requirements_cache keeps a fresher host cache" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-cloud-cache-stale-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    host_codex_home = Path.join(test_root, "host-codex")
    generated_home = Path.join(test_root, "generated-codex-home")
    File.mkdir_p!(host_codex_home)
    File.mkdir_p!(generated_home)

    host_cache = cloud_requirements_cache("2026-05-21T12:00:00Z", "host")
    generated_cache = cloud_requirements_cache("2026-05-21T11:00:00Z", "generated")
    File.write!(Path.join(host_codex_home, "cloud-requirements-cache.json"), host_cache)
    File.write!(Path.join(generated_home, "cloud-requirements-cache.json"), generated_cache)

    McpConfig.sync_cloud_requirements_cache(%{
      home_path: generated_home,
      host_codex_home: host_codex_home
    })

    assert File.read!(Path.join(host_codex_home, "cloud-requirements-cache.json")) == host_cache
  end

  test "sync_cloud_requirements_cache skips missing and invalid generated caches" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-cloud-cache-invalid-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    host_codex_home = Path.join(test_root, "host-codex")
    generated_home = Path.join(test_root, "generated-codex-home")
    File.mkdir_p!(host_codex_home)
    File.mkdir_p!(generated_home)

    McpConfig.sync_cloud_requirements_cache(%{
      home_path: generated_home,
      host_codex_home: host_codex_home
    })

    refute File.exists?(Path.join(host_codex_home, "cloud-requirements-cache.json"))

    File.write!(Path.join(generated_home, "cloud-requirements-cache.json"), "not json")

    McpConfig.sync_cloud_requirements_cache(%{
      home_path: generated_home,
      host_codex_home: host_codex_home
    })

    refute File.exists?(Path.join(host_codex_home, "cloud-requirements-cache.json"))

    File.write!(Path.join(generated_home, "cloud-requirements-cache.json"), "{}")

    McpConfig.sync_cloud_requirements_cache(%{
      home_path: generated_home,
      host_codex_home: host_codex_home
    })

    refute File.exists?(Path.join(host_codex_home, "cloud-requirements-cache.json"))
  end

  test "sync_cloud_requirements_cache overwrites an invalid host cache" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-cloud-cache-invalid-host-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    host_codex_home = Path.join(test_root, "host-codex")
    generated_home = Path.join(test_root, "generated-codex-home")
    File.mkdir_p!(host_codex_home)
    File.mkdir_p!(generated_home)

    generated_cache = cloud_requirements_cache("2026-05-21T11:00:00Z", "new")
    File.write!(Path.join(generated_home, "cloud-requirements-cache.json"), generated_cache)
    File.write!(Path.join(host_codex_home, "cloud-requirements-cache.json"), "{}")

    McpConfig.sync_cloud_requirements_cache(%{
      home_path: generated_home,
      host_codex_home: host_codex_home
    })

    assert File.read!(Path.join(host_codex_home, "cloud-requirements-cache.json")) == generated_cache
  end

  test "sync_cloud_requirements_cache logs and continues when host cache write fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-cloud-cache-write-fail-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    file_parent = Path.join(test_root, "file-parent")
    host_codex_home = Path.join(file_parent, "host-codex")
    generated_home = Path.join(test_root, "generated-codex-home")
    File.mkdir_p!(generated_home)
    File.write!(file_parent, "not a directory")
    File.write!(Path.join(generated_home, "cloud-requirements-cache.json"), cloud_requirements_cache("2026-05-21T11:00:00Z", "new"))

    assert :ok =
             McpConfig.sync_cloud_requirements_cache(%{
               home_path: generated_home,
               host_codex_home: host_codex_home
             })
  end

  test "build_config supports default host home lookup and fallback settings shape" do
    assert {:ok, config} =
             McpConfig.build_config(%{}, @mcp_session, @mcp_session.socket_path, @mcp_session.shim_path)

    assert config =~ "[mcp_servers.symphony]"
  end

  test "inherited_server_blocks handles missing, unreadable, and invalid inheritance inputs" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-inherit-errors-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    missing_home = Path.join(test_root, "missing")
    assert {:ok, []} = McpConfig.inherited_server_blocks(missing_home, mcp!(%{inherit: "allowlist", allowed_servers: ["a"]}), MapSet.new())

    unreadable_home = Path.join(test_root, "unreadable")
    File.mkdir_p!(Path.join(unreadable_home, "config.toml"))

    assert {:error, {:codex_mcp_inheritance_read_failed, _path, :eisdir}} =
             McpConfig.inherited_server_blocks(unreadable_home, mcp!(%{inherit: "all"}), MapSet.new())

    assert {:ok, []} = McpConfig.inherited_server_blocks(nil, :invalid, MapSet.new())

    invalid_mcp_home = Path.join(test_root, "invalid-mcp")
    File.mkdir_p!(invalid_mcp_home)
    File.write!(Path.join(invalid_mcp_home, "config.toml"), "[mcp_servers.context]\ncommand = \"context\"\n")

    assert {:ok, []} =
             McpConfig.inherited_server_blocks(
               invalid_mcp_home,
               %Schema.Agent.Mcp{inherit: "invalid"},
               MapSet.new()
             )
  end

  test "extract_mcp_server_blocks handles empty, non-MCP, quoted, and invalid quoted tables" do
    assert McpConfig.extract_mcp_server_blocks("") == []
    assert McpConfig.extract_mcp_server_blocks("[tools.example]\ncommand = \"ignored\"\n") == []

    blocks =
      McpConfig.extract_mcp_server_blocks("""
      [mcp_servers."quoted.name"]
      command = "quoted"

      [mcp_servers."bad\\x"]
      command = "fallback"

      [mcp_servers."quote\\"name"]
      command = "escaped"
      """)

    assert {"quoted.name", quoted_block} = List.keyfind(blocks, "quoted.name", 0)
    assert quoted_block =~ ~s(command = "quoted")

    assert {"bad\\x", bad_block} = List.keyfind(blocks, "bad\\x", 0)
    assert bad_block =~ ~s(command = "fallback")

    assert {"quote\"name", escaped_block} = List.keyfind(blocks, "quote\"name", 0)
    assert escaped_block =~ ~s(command = "escaped")
  end

  defp settings!(mcp) do
    {:ok, settings} =
      Schema.parse(%{
        agent: %{
          kind: "codex",
          command: "codex app-server",
          mcp: mcp
        }
      })

    settings
  end

  defp mcp!(mcp) do
    settings!(mcp).agent.mcp
  end

  defp build_config(settings, host_codex_home) do
    McpConfig.build_config(
      settings,
      @mcp_session,
      @mcp_session.socket_path,
      @mcp_session.shim_path,
      host_codex_home: host_codex_home
    )
  end

  defp cloud_requirements_cache(expires_at, signature) do
    Jason.encode!(%{
      "signed_payload" => %{
        "cached_at" => "2026-05-21T10:00:00Z",
        "expires_at" => expires_at,
        "chatgpt_user_id" => "user-test",
        "account_id" => "account-test",
        "contents" => nil
      },
      "signature" => signature
    })
  end
end
