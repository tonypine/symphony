defmodule SymphonyElixir.HttpServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.{ControlUrl, HttpServer, Paths, TestSupport, Workflow}

  @allow_remote_bind_env "SYMPHONY_ALLOW_REMOTE_BIND"
  @allowed_origins_env "SYMPHONY_DASHBOARD_ALLOWED_ORIGINS"

  setup do
    TestSupport.stop_default_http_server()

    tmp =
      Path.join(System.tmp_dir!(), "symphony-http-server-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    allow_remote_bind = System.get_env(@allow_remote_bind_env)
    allowed_origins = System.get_env(@allowed_origins_env)
    previous_state_override = Application.get_env(:symphony_elixir, :state_root_override)
    previous_symphony_path = Application.get_env(:symphony_elixir, :symphony_file_path)
    Paths.set_state_root(tmp)
    # Earlier suites may clear the configured path, which falls back to the repo's own
    # symphony.yml; pin the runtime fixture so this suite reads a local workflow.
    Workflow.set_symphony_file_path(Path.expand("../fixtures/runtime/symphony.yml", __DIR__))

    on_exit(fn ->
      restore_env(@allow_remote_bind_env, allow_remote_bind)
      restore_env(@allowed_origins_env, allowed_origins)

      case previous_symphony_path do
        nil -> Workflow.clear_symphony_file_path()
        path -> Workflow.set_symphony_file_path(path)
      end

      case previous_state_override do
        nil -> Application.delete_env(:symphony_elixir, :state_root_override)
        value -> Application.put_env(:symphony_elixir, :state_root_override, value)
      end

      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "start_link/1 remote bind guard" do
    test "allows IPv4 loopback binds" do
      start_supervised!({HttpServer, [host: "127.0.0.1", port: 0]})

      assert is_integer(HttpServer.bound_port())
    end

    test "allows IPv6 loopback binds" do
      start_supervised!({HttpServer, [host: "::1", port: 0]})

      assert is_integer(HttpServer.bound_port())
    end

    test "refuses non-loopback binds without an explicit override" do
      System.delete_env(@allow_remote_bind_env)

      assert {:error, message} = HttpServer.start_link(host: "0.0.0.0", port: 0)

      assert message =~ ~s(refusing to bind HTTP server to non-loopback host "0.0.0.0")
      assert message =~ "the dashboard has no built-in auth"
      assert message =~ "SYMPHONY_ALLOW_REMOTE_BIND=1"
      assert HttpServer.bound_port() == nil
    end

    test "allows non-loopback binds with an explicit override" do
      System.put_env(@allow_remote_bind_env, "1")

      start_supervised!({HttpServer, [host: "0.0.0.0", port: 0]})

      assert is_integer(HttpServer.bound_port())
    end

    test "persists the bound control URL for the CLI to discover" do
      start_supervised!({HttpServer, [host: "127.0.0.1", port: 0]})
      port = HttpServer.bound_port()

      assert ControlUrl.read() == "http://127.0.0.1:#{port}"
    end

    test "creates the control token file so the CLI can authenticate immediately" do
      start_supervised!({HttpServer, [host: "127.0.0.1", port: 0]})

      token = SymphonyElixir.ControlToken.read()
      refute is_nil(token)
      assert byte_size(token) > 0
    end

    test "rewrites the IPv4 wildcard host to a loopback URL for local CLI discovery" do
      System.put_env(@allow_remote_bind_env, "1")

      start_supervised!({HttpServer, [host: "0.0.0.0", port: 0]})
      port = HttpServer.bound_port()

      assert ControlUrl.read() == "http://127.0.0.1:#{port}"
    end
  end

  describe "migrate_legacy_secret_key_base/2" do
    test "moves the legacy file when only the old path exists", %{tmp: tmp} do
      old_path = Path.join([tmp, "legacy", "secret_key_base"])
      new_path = Path.join([tmp, "state", "secret_key_base"])
      File.mkdir_p!(Path.dirname(old_path))
      File.write!(old_path, "legacy-key")

      assert :ok = HttpServer.migrate_legacy_secret_key_base(old_path, new_path)
      assert File.read!(new_path) == "legacy-key"
      refute File.exists?(old_path)
    end

    test "does not overwrite the new file when both files exist", %{tmp: tmp} do
      old_path = Path.join([tmp, "legacy", "secret_key_base"])
      new_path = Path.join([tmp, "state", "secret_key_base"])
      File.mkdir_p!(Path.dirname(old_path))
      File.mkdir_p!(Path.dirname(new_path))
      File.write!(old_path, "legacy-key")
      File.write!(new_path, "current-key")

      assert :ok = HttpServer.migrate_legacy_secret_key_base(old_path, new_path)
      assert File.read!(new_path) == "current-key"
      assert File.read!(old_path) == "legacy-key"
    end

    test "is a no-op when the old file is missing", %{tmp: tmp} do
      old_path = Path.join([tmp, "legacy", "secret_key_base"])
      new_path = Path.join([tmp, "state", "secret_key_base"])

      assert :ok = HttpServer.migrate_legacy_secret_key_base(old_path, new_path)
      refute File.exists?(new_path)
    end

    test "is a no-op when old and new paths are equal", %{tmp: tmp} do
      same_path = Path.join([tmp, "shared", "secret_key_base"])
      File.mkdir_p!(Path.dirname(same_path))
      File.write!(same_path, "stable-key")

      assert :ok = HttpServer.migrate_legacy_secret_key_base(same_path, same_path)
      assert File.read!(same_path) == "stable-key"
    end

    test "logs a warning and returns :ok when mkdir_p fails", %{tmp: tmp} do
      old_path = Path.join([tmp, "legacy", "secret_key_base"])
      File.mkdir_p!(Path.dirname(old_path))
      File.write!(old_path, "legacy-key")

      blocking_file = Path.join(tmp, "blocker")
      File.write!(blocking_file, "x")
      new_path = Path.join([blocking_file, "state", "secret_key_base"])

      log =
        capture_log(fn ->
          assert :ok = HttpServer.migrate_legacy_secret_key_base(old_path, new_path)
        end)

      assert log =~ "failed to migrate secret_key_base"
      assert File.read!(old_path) == "legacy-key"
      refute File.exists?(new_path)
    end
  end

  describe "live websocket check_origin enforcement" do
    test "rejects WebSocket upgrades from disallowed origins" do
      start_supervised!({HttpServer, [host: "127.0.0.1", port: 0]})
      port = HttpServer.bound_port()
      assert is_integer(port)

      assert ws_upgrade_status(port, "http://evil.example") in 400..499
      assert ws_upgrade_status(port, "http://127.0.0.1:#{port}") == 101
    end
  end

  describe "allowed_origin?/1" do
    setup do
      System.delete_env(@allowed_origins_env)
      :ok
    end

    test "accepts loopback hostnames regardless of scheme or port" do
      for origin <- ~w(
        http://127.0.0.1
        http://127.0.0.1:4000
        https://localhost:8080
        ws://localhost
        http://[::1]:4001
      ) do
        assert HttpServer.allowed_origin?(URI.parse(origin)),
               "expected #{origin} to be allowed"
      end
    end

    test "rejects arbitrary external origins" do
      for origin <- ~w(
        http://evil.example
        https://attacker.test:8443
        http://127.0.0.1.evil.example
        http://localhost.attacker.test
      ) do
        refute HttpServer.allowed_origin?(URI.parse(origin)),
               "expected #{origin} to be rejected"
      end
    end

    test "rejects URIs with no host" do
      refute HttpServer.allowed_origin?(URI.parse("about:blank"))
      refute HttpServer.allowed_origin?(URI.parse(""))
    end

    test "allows hosts listed in SYMPHONY_DASHBOARD_ALLOWED_ORIGINS" do
      System.put_env(@allowed_origins_env, "https://dashboard.internal, http://ops.test:9000")

      assert HttpServer.allowed_origin?(URI.parse("https://dashboard.internal"))
      assert HttpServer.allowed_origin?(URI.parse("http://ops.test:9000"))
      refute HttpServer.allowed_origin?(URI.parse("https://evil.example"))
    end

    test "accepts bare hostnames in the allowlist env" do
      System.put_env(@allowed_origins_env, "dashboard.internal")

      assert HttpServer.allowed_origin?(URI.parse("https://dashboard.internal:8443"))
    end

    test "still allows loopback when the env allowlist is set" do
      System.put_env(@allowed_origins_env, "https://dashboard.internal")

      assert HttpServer.allowed_origin?(URI.parse("http://127.0.0.1:4000"))
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp ws_upgrade_status(port, origin) do
    key = :crypto.strong_rand_bytes(16) |> Base.encode64()

    request =
      [
        "GET /live/websocket?vsn=2.0.0 HTTP/1.1",
        "Host: 127.0.0.1:#{port}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: #{key}",
        "Sec-WebSocket-Version: 13",
        "Origin: #{origin}",
        "",
        ""
      ]
      |> Enum.join("\r\n")

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2_000)

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    :gen_tcp.close(socket)

    [status_line | _] = String.split(response, "\r\n", parts: 2)
    [_http, code | _] = String.split(status_line, " ", parts: 3)
    String.to_integer(code)
  end
end
