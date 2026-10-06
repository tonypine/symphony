defmodule SymphonyElixir.VerificationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Verification.DevServer, as: DevServerConfig
  alias SymphonyElixir.Verification
  alias SymphonyElixir.Verification.{DevServer, PortPool}

  # Serves its folder on `$SYMPHONY_VERIFICATION_SOCKET` where it has one (macOS, and the tests'
  # stand-in for `sandbox-exec`), else on `127.0.0.1:$SYMPHONY_VERIFICATION_PORT`.
  @dev_server Path.expand("../support/dev_server.py", __DIR__)

  setup do
    stop_verification_port_pool()
    :ok = RunStore.clear()

    on_exit(fn ->
      stop_verification_port_pool()
    end)

    :ok
  end

  test "port pool allocates unique ports and never double allocates when exhausted" do
    {:ok, _pid} = PortPool.start_link(reconcile_interval_ms: nil, process_alive?: fn _pid -> true end)

    attrs = fn run_id ->
      %{
        run_id: run_id,
        issue_id: "issue-#{run_id}",
        issue_identifier: "ACME-#{run_id}",
        port_range: [4110, 4111]
      }
    end

    tasks =
      for run_id <- ["run-1", "run-2"] do
        Task.async(fn -> PortPool.allocate(attrs.(run_id)) end)
      end

    ports =
      tasks
      |> Task.await_many()
      |> Enum.map(fn {:ok, allocation} -> allocation.port end)
      |> Enum.sort()

    assert ports == [4110, 4111]
    assert {:error, :exhausted} = PortPool.allocate(attrs.("run-3"))

    %{run_id: released_run_id} =
      PortPool.active_allocations()
      |> Enum.find(&(&1.port == 4110))

    assert :ok = PortPool.release(released_run_id, "test release")
    assert {:ok, %{port: 4110}} = PortPool.allocate(attrs.("run-3"))
  end

  test "port pool restart reconciliation keeps live allocations and releases stale ones" do
    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_verification_allocation(%{
               repo_key: "default",
               run_id: "live-run",
               issue_id: "issue-live",
               issue_identifier: "ACME-LIVE",
               port: 4120,
               status: "dev_server_started",
               dev_server_os_pid: 111,
               allocated_at: now,
               updated_at: now
             })

    assert :ok =
             RunStore.put_verification_allocation(%{
               repo_key: "api",
               run_id: "api-live-run",
               issue_id: "issue-api-live",
               issue_identifier: "ACME-API-LIVE",
               port: 4122,
               status: "dev_server_started",
               dev_server_os_pid: 333,
               allocated_at: now,
               updated_at: now
             })

    assert :ok =
             RunStore.put_verification_allocation(%{
               repo_key: "default",
               run_id: "stale-run",
               issue_id: "issue-stale",
               issue_identifier: "ACME-STALE",
               port: 4121,
               status: "dev_server_started",
               dev_server_os_pid: 222,
               allocated_at: now,
               updated_at: now
             })

    {:ok, pid} =
      PortPool.start_link(
        reconcile_interval_ms: nil,
        process_alive?: fn
          111 -> true
          333 -> true
          222 -> false
        end
      )

    assert [
             %{run_id: "live-run", port: 4120},
             %{run_id: "api-live-run", port: 4122}
           ] = PortPool.active_allocations()

    assert %{status: "released"} =
             RunStore.list_verification_allocations()
             |> Enum.find(&(&1.run_id == "stale-run"))

    GenServer.stop(pid)

    {:ok, _pid} = PortPool.start_link(reconcile_interval_ms: nil, process_alive?: fn _pid -> false end)
    assert :ok = PortPool.reconcile()
    assert [] = PortPool.active_allocations()
  end

  @tag :unix_socket
  test "dev server starts in workspace cwd, becomes healthy, and stops" do
    port = free_tcp_port()
    workspace = System.tmp_dir!()
    run_id = "dev-server-run"

    {:ok, _pid} = PortPool.start_link(reconcile_interval_ms: nil, process_alive?: fn _pid -> true end)

    assert {:ok, %{port: ^port}} =
             PortPool.allocate(%{
               run_id: run_id,
               issue_id: "issue-dev-server",
               issue_identifier: "ACME-DEV",
               port_range: [port, port]
             })

    config = %DevServerConfig{
      start_cmd: "exec python3 #{@dev_server}",
      health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/",
      health_timeout_ms: 5_000,
      stop_signal: "TERM",
      stop_timeout_ms: 1_000
    }

    assert {:ok, pid} =
             DevServer.start(
               run_id: run_id,
               port: port,
               workspace: workspace,
               config: config,
               env: Verification.env(%{port: port}),
               owner: self()
             )

    assert Process.alive?(pid)
    assert :ok = DevServer.stop(pid)
    refute Process.alive?(pid)

    assert %{status: "dev_server_started", dev_server_os_pid: os_pid} =
             RunStore.list_verification_allocations()
             |> Enum.find(&(&1.run_id == run_id))

    assert is_integer(os_pid)
    refute http_server_responding_after_wait?("http://127.0.0.1:#{port}/")
  end

  test "dev server returns verification_failed when health check times out" do
    port = free_tcp_port()

    # Something is at the socket, so the server did try to listen there.
    config = %DevServerConfig{
      start_cmd: ~s{touch "$SYMPHONY_VERIFICATION_SOCKET"; sleep 5},
      health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/healthz",
      health_timeout_ms: 1_000,
      stop_signal: "TERM",
      stop_timeout_ms: 100
    }

    assert {:error, {:verification_failed, :health_timeout}} =
             DevServer.start(
               run_id: "timeout-run",
               port: port,
               workspace: System.tmp_dir!(),
               config: config,
               env: Verification.env(%{port: port}),
               owner: self()
             )
  end

  test "dev server logs its own output when its health check times out" do
    port = free_tcp_port()

    config = %DevServerConfig{
      start_cmd: ~s{touch "$SYMPHONY_VERIFICATION_SOCKET"; echo dev-server-said-hello; sleep 5},
      health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/healthz",
      health_timeout_ms: 1_000,
      stop_signal: "TERM",
      stop_timeout_ms: 100
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:verification_failed, :health_timeout}} =
                 DevServer.start(
                   run_id: "output-run",
                   port: port,
                   workspace: System.tmp_dir!(),
                   config: config,
                   env: Verification.env(%{port: port}),
                   owner: self()
                 )
      end)

    assert log =~ "Verification dev server output run_id=output-run"
    assert log =~ "dev-server-said-hello"
  end

  test "dev server reports an exit during startup with its output, without waiting out the health check" do
    port = free_tcp_port()

    config = %DevServerConfig{
      start_cmd: "echo dev-server-crashed; exit 3",
      health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/healthz",
      health_timeout_ms: 60_000,
      stop_signal: "TERM",
      stop_timeout_ms: 100
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:verification_failed, {:dev_server_exit, 3}}} =
                 DevServer.start(
                   run_id: "exit-run",
                   port: port,
                   workspace: System.tmp_dir!(),
                   config: config,
                   env: Verification.env(%{port: port}),
                   owner: self()
                 )
      end)

    assert log =~ "Verification dev server output run_id=exit-run"
    assert log =~ "dev-server-crashed"
  end

  test "dev server that never listens on its unix socket says so when its health check times out" do
    port = free_tcp_port()

    config = %DevServerConfig{
      start_cmd: "sleep 1",
      health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/healthz",
      health_timeout_ms: 50,
      stop_signal: "TERM",
      stop_timeout_ms: 100
    }

    assert {:error, {:verification_failed, {:dev_server_not_on_socket, socket}}} =
             DevServer.start(
               run_id: "no-socket-run",
               port: port,
               workspace: System.tmp_dir!(),
               config: config,
               env: Verification.env(%{port: port}),
               owner: self()
             )

    assert Path.basename(socket) == "serve.sock"
    refute File.exists?(Path.dirname(socket))
  end

  test "dev server does not start when its port is taken, as its bridge can't listen there" do
    {:ok, holder} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(holder)

    config = %DevServerConfig{
      start_cmd: "env > #{System.tmp_dir!()}/never-started.txt",
      health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/healthz",
      health_timeout_ms: 50,
      stop_signal: "TERM",
      stop_timeout_ms: 100
    }

    assert {:error, {:verification_failed, {:loopback_bridge_unavailable, :eaddrinuse}}} =
             DevServer.start(
               run_id: "taken-port-run",
               port: port,
               workspace: System.tmp_dir!(),
               config: config,
               env: Verification.env(%{port: port}),
               owner: self()
             )

    refute File.exists?(Path.join(System.tmp_dir!(), "never-started.txt"))
    :gen_tcp.close(holder)
  end

  test "dev server fails fast when process-group isolation is unavailable" do
    port = free_tcp_port()
    shell = System.find_executable("sh") || System.find_executable("bash")
    assert is_binary(shell)

    config = %DevServerConfig{
      start_cmd: "sleep 1",
      health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/healthz",
      health_timeout_ms: 50,
      stop_signal: "TERM",
      stop_timeout_ms: 100
    }

    assert {:error, {:verification_failed, :process_group_unavailable}} =
             DevServer.start(
               run_id: "no-process-group-run",
               port: port,
               workspace: System.tmp_dir!(),
               config: config,
               env: Verification.env(%{port: port}),
               owner: self(),
               launcher: fn -> {:ok, shell, ["-lc", "sleep 1"], [], false} end
             )
  end

  test "dev server reports verification_failed when Python is unavailable" do
    port = free_tcp_port()

    config = %DevServerConfig{
      start_cmd: "sleep 1",
      health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/healthz",
      health_timeout_ms: 50,
      stop_signal: "TERM",
      stop_timeout_ms: 100
    }

    assert {:error, {:verification_failed, :python_not_found}} =
             DevServer.start(
               run_id: "python-not-found-run",
               port: port,
               workspace: System.tmp_dir!(),
               config: config,
               env: Verification.env(%{port: port}),
               owner: self(),
               launcher: fn -> {:error, :python_not_found} end
             )
  end

  describe "dev server sandbox" do
    setup do
      root = Path.join(System.tmp_dir!(), "dev-server-sandbox-#{System.unique_integer([:positive])}")
      workspace = Path.join(root, "workspace")
      File.mkdir_p!(workspace)
      previous_key = System.get_env("LINEAR_API_KEY")
      System.put_env("LINEAR_API_KEY", "lin-dev-server-test-secret")

      on_exit(fn ->
        if previous_key, do: System.put_env("LINEAR_API_KEY", previous_key), else: System.delete_env("LINEAR_API_KEY")
        File.rm_rf(root)
      end)

      config = %DevServerConfig{
        start_cmd: "env > dev-server-env.txt; exec python3 #{@dev_server}",
        health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/",
        health_timeout_ms: 5_000,
        stop_signal: "TERM",
        stop_timeout_ms: 1_000
      }

      %{root: root, workspace: workspace, config: config, port: free_tcp_port()}
    end

    @tag :unix_socket
    test "spawns the start command through sandbox-exec, with the agent's env and the egress proxy, served on its port by the bridge", %{root: root, workspace: workspace, config: config, port: port} do
      record = Path.join(root, "sandbox-exec-argv")
      sandbox_exec = Path.join(root, "sandbox-exec")
      File.write!(sandbox_exec, "#!/bin/sh\nprintf '%s\\0' \"$@\" > '#{record}'\nshift 2\nexec \"$@\"\n")
      File.chmod!(sandbox_exec, 0o755)

      assert {:ok, pid} =
               DevServer.start(
                 run_id: "sandboxed-run",
                 port: port,
                 workspace: workspace,
                 config: config,
                 env: Verification.env(%{port: port}),
                 owner: self(),
                 sandbox: [os_type: {:unix, :darwin}, executable: sandbox_exec, check_confinement: false]
               )

      assert ["-p", profile, "/bin/sh", "-lc", start_cmd, ""] = record |> File.read!() |> String.split("\0")
      assert start_cmd == config.start_cmd
      assert profile =~ "(deny file-read*"
      assert profile =~ ~s{(subpath "#{Path.join(System.user_home!(), ".ssh")}")}
      assert profile =~ "(deny network*)"

      env = File.read!(Path.join(workspace, "dev-server-env.txt"))
      assert env =~ "SYMPHONY_VERIFICATION_PORT=#{port}\n"
      assert [_line, proxy_port] = Regex.run(~r/^HTTPS_PROXY=http:\/\/127\.0\.0\.1:(\d+)$/m, env)
      assert env =~ "NO_PROXY=localhost,127.0.0.1,::1\n"
      assert [_line, tmp_dir] = Regex.run(~r/^TMPDIR=(.+)$/m, env)
      assert File.dir?(tmp_dir)
      assert env =~ "SYMPHONY_VERIFICATION_SOCKET=#{Path.join(real_path(tmp_dir), "serve.sock")}\n"
      refute env =~ "lin-dev-server-test-secret"
      refute env =~ "SYMPHONY_DEV_SERVER_ARGV"

      # The server listens on its unix socket; the bridge serves it on its port.
      assert http_ok?("http://127.0.0.1:#{port}/dev-server-env.txt")

      assert :ok = DevServer.stop(pid)
      refute File.exists?(tmp_dir)
      refute http_ok?("http://127.0.0.1:#{port}/")
      assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", String.to_integer(proxy_port), [])
    end

    @tag :unix_socket
    test "stops when its egress proxy goes down", %{workspace: workspace, config: config, port: port} do
      assert {:ok, pid} =
               DevServer.start(
                 run_id: "proxy-down-run",
                 port: port,
                 workspace: workspace,
                 config: config,
                 env: Verification.env(%{port: port}),
                 owner: self()
               )

      ref = Process.monitor(pid)
      %DevServer{proxy: proxy, tmp_dir: tmp_dir} = :sys.get_state(pid)

      log =
        capture_log(fn ->
          Process.exit(proxy, :kill)
          assert_receive {:DOWN, ^ref, :process, ^pid, {:egress_proxy_down, :killed}}, 5_000
        end)

      assert log =~ "Verification dev server egress proxy exited run_id=proxy-down-run reason=:killed"
      refute File.exists?(tmp_dir)
      refute http_ok?("http://127.0.0.1:#{port}/")
    end

    @tag :unix_socket
    test "stops when its loopback bridge goes down", %{workspace: workspace, config: config, port: port} do
      assert {:ok, pid} =
               DevServer.start(
                 run_id: "bridge-down-run",
                 port: port,
                 workspace: workspace,
                 config: config,
                 env: Verification.env(%{port: port}),
                 owner: self()
               )

      ref = Process.monitor(pid)
      %DevServer{bridge: bridge, tmp_dir: tmp_dir} = :sys.get_state(pid)

      log =
        capture_log(fn ->
          Process.exit(bridge, :kill)
          assert_receive {:DOWN, ^ref, :process, ^pid, {:loopback_bridge_down, :killed}}, 5_000
        end)

      assert log =~ "Verification dev server loopback bridge exited run_id=bridge-down-run reason=:killed"
      refute File.exists?(tmp_dir)
    end

    test "does not start the command when there is no sandbox", %{root: root, workspace: workspace, config: config, port: port} do
      bwrap = Path.join(root, "missing-bwrap")

      assert {:error, {:verification_failed, {:dev_server_sandbox_unavailable, {:not_found, ^bwrap}}}} =
               DevServer.start(
                 run_id: "unsandboxed-run",
                 port: port,
                 workspace: workspace,
                 config: config,
                 env: Verification.env(%{port: port}),
                 sandbox: [os_type: {:unix, :linux}, bwrap: bwrap]
               )

      refute File.exists?(Path.join(workspace, "dev-server-env.txt"))
    end

    test "removes the folders bwrap made in the checkout once it stops", %{root: root, workspace: workspace, config: config, port: port} do
      assert {:ok, pid} =
               DevServer.start(
                 run_id: "placeholder-run",
                 port: port,
                 workspace: workspace,
                 config: config,
                 env: Verification.env(%{port: port}),
                 owner: self(),
                 sandbox: fake_bwrap(root),
                 # Short enough for socat's unix sockets in a nested `TMPDIR`.
                 tmp_bases: [System.tmp_dir!()]
               )

      assert File.dir?(Path.join(workspace, ".claude"))
      assert :ok = DevServer.stop(pid)
      refute File.exists?(Path.join(workspace, ".claude"))
      refute File.exists?(Path.join(workspace, ".ai"))
    end

    # On Linux the server listens on its port, inside its own network namespace: it has no socket.
    test "a server under bwrap that fails its health check times out", %{root: root, workspace: workspace, config: config, port: port} do
      assert {:error, {:verification_failed, :health_timeout}} =
               DevServer.start(
                 run_id: "bwrap-timeout-run",
                 port: port,
                 workspace: workspace,
                 config: %{config | start_cmd: "env > dev-server-env.txt; sleep 5", health_timeout_ms: 1_000},
                 env: Verification.env(%{port: port}),
                 owner: self(),
                 sandbox: fake_bwrap(root),
                 tmp_bases: [System.tmp_dir!()]
               )

      refute File.read!(Path.join(workspace, "dev-server-env.txt")) =~ "SYMPHONY_VERIFICATION_SOCKET"
    end

    @tag :bwrap
    test "serves on its loopback port from inside bwrap", %{workspace: workspace, config: config, port: port} do
      assert {:ok, pid} =
               DevServer.start(
                 run_id: "bwrap-run",
                 port: port,
                 workspace: workspace,
                 config: %{config | health_timeout_ms: 30_000, stop_timeout_ms: 5_000},
                 env: Verification.env(%{port: port}),
                 owner: self(),
                 sandbox: [os_type: {:unix, :linux}]
               )

      # Each request crosses two socat bridges, so it gets longer than `http_ok?/1`'s 100 ms.
      assert {:ok, %{status: 200, body: env}} = Req.get("http://127.0.0.1:#{port}/dev-server-env.txt", receive_timeout: 5_000, retry: false)
      assert env =~ "SYMPHONY_VERIFICATION_PORT=#{port}\n"
      assert File.dir?(Path.join(workspace, ".claude"))

      # Under 5 s: the stop signal ends the sandbox, without the KILL that follows `stop_timeout_ms`.
      assert {stop_us, :ok} = :timer.tc(fn -> DevServer.stop(pid) end)
      assert stop_us < 4_000_000, "stopping took #{div(stop_us, 1_000)} ms"
      refute http_ok?("http://127.0.0.1:#{port}/")
      refute File.exists?(Path.join(workspace, ".claude"))
    end

    test "does not start without a temp folder of its own", %{root: root, workspace: workspace, config: config, port: port} do
      file = Path.join(root, "not-a-dir")
      File.write!(file, "")

      assert {:error, {:verification_failed, :dev_server_tmp_dir_unavailable}} =
               DevServer.start(
                 run_id: "no-tmp-run",
                 port: port,
                 workspace: workspace,
                 config: config,
                 env: Verification.env(%{port: port}),
                 tmp_bases: [file]
               )
    end

    test "does not start without its egress proxy, and removes its temp folder", %{root: root, workspace: workspace, config: config, port: port} do
      log =
        capture_log(fn ->
          assert {:error, {:verification_failed, {:egress_proxy_unavailable, :emfile}}} =
                   DevServer.start(
                     run_id: "no-proxy-run",
                     port: port,
                     workspace: workspace,
                     config: config,
                     env: Verification.env(%{port: port}),
                     tmp_bases: [root],
                     egress_proxy: [listen: fn _port, _options -> {:error, :emfile} end]
                   )
        end)

      assert log =~ "Verification dev server egress proxy unavailable run_id=no-proxy-run reason=:emfile"
      assert File.ls!(root) == ["workspace"]
      refute File.exists?(Path.join(workspace, "dev-server-env.txt"))
    end

    # The server first tries to listen on its port on every address, as a server reachable from
    # the network would, then serves on its unix socket.
    @tag :seatbelt
    test "serves from inside the real sandbox on 127.0.0.1 only", %{workspace: workspace, config: config, port: port} do
      listen_anywhere = ~s{import os, socket; socket.socket().bind(("0.0.0.0", int(os.environ["SYMPHONY_VERIFICATION_PORT"])))}

      assert {:ok, pid} =
               DevServer.start(
                 run_id: "seatbelt-run",
                 port: port,
                 workspace: workspace,
                 config: %{config | start_cmd: "python3 -c '#{listen_anywhere}' > tcp-listen.txt 2>&1; exec python3 #{@dev_server}"},
                 env: Verification.env(%{port: port}),
                 owner: self(),
                 sandbox: []
               )

      assert http_ok?("http://127.0.0.1:#{port}/")
      assert File.read!(Path.join(workspace, "tcp-listen.txt")) =~ "Operation not permitted"

      # Another host on the network connects to this one's own address: nothing listens there.
      assert [_address | _more] = addresses = host_addresses()

      for address <- addresses do
        assert {:error, :econnrefused} = :gen_tcp.connect(address, port, [], 5_000), "#{:inet.ntoa(address)}:#{port} accepted"
      end

      assert :ok = DevServer.stop(pid)
    end

    # Builds this checkout's escript with `mix build` (in `_build/dev` and `bin/`) outside the
    # sandbox before it serves, as an Auto Review `web` pass does, so it can take minutes. The
    # command then runs in a sandbox that allows no TCP listener, and Mix needs one to load deps
    # (see the guard in `scripts/qa-dashboard-server.sh`), so the build can't happen there. A plain
    # `mix test` skips it; `--include qa_dashboard_e2e` or `--only seatbelt` runs it.
    @tag :seatbelt
    @tag :qa_dashboard_e2e
    @tag timeout: 900_000
    test "serves the dashboard with scripts/qa-dashboard-server.sh from inside the real sandbox", %{port: port} do
      build_escript!()

      config = %DevServerConfig{
        start_cmd: "scripts/qa-dashboard-server.sh",
        health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state",
        health_timeout_ms: 600_000,
        stop_signal: "TERM",
        stop_timeout_ms: 5_000
      }

      # The app logs to the rotating disk file (`SymphonyElixir.LogFile` drops the console
      # handler), so on CI a dev server that fails to start leaves no output in the job log.
      # Capture it here and print it on failure, where the diagnosis would otherwise be lost.
      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          DevServer.start(
            run_id: "qa-dashboard-seatbelt-run",
            port: port,
            workspace: File.cwd!(),
            config: config,
            env: Verification.env(%{port: port}),
            owner: self(),
            sandbox: []
          )
        end)

      case result do
        {:ok, pid} ->
          assert http_ok?("http://127.0.0.1:#{port}/")
          assert :ok = DevServer.stop(pid)

        {:error, reason} ->
          IO.puts(:stderr, "qa dashboard dev server failed to start: #{inspect(reason)}\n#{log}")
          flunk("qa dashboard dev server failed to start: #{inspect(reason)}")
      end
    end
  end

  test "a dev server reaches the agent's dependency hosts, without the model providers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_network_access: %{mode: "allowlist", allowed_domains: ["Internal.Example.com"], denied_domains: ["hex.pm"]}
    )

    domains = Schema.dev_server_network_allowed_domains(Config.settings!())
    assert "repo.hex.pm" in domains
    assert "internal.example.com" in domains
    refute "hex.pm" in domains
    refute "api.anthropic.com" in domains
    refute "api.openai.com" in domains

    write_workflow_file!(Workflow.workflow_file_path(), agent_network_access: %{mode: "block", allowed_domains: ["internal.example.com"]})
    assert Schema.dev_server_network_allowed_domains(Config.settings!()) == []
  end

  test "agent runner aborts before first turn when verification health check fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-verification-agent-abort-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_codex = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      port = free_tcp_port()

      File.mkdir_p!(test_root)

      File.write!(fake_codex, """
      #!/bin/sh
      printf 'agent-turn-started\\n' > "#{trace_file}"
      exit 0
      """)

      File.chmod!(fake_codex, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{fake_codex} app-server",
        verification: %{
          enabled: true,
          port_allocation: %{range: [port, port]},
          dev_server: %{
            start_cmd: "sleep 1",
            health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/healthz",
            health_timeout_ms: 50,
            stop_timeout_ms: 100
          }
        }
      )

      issue = %Issue{
        id: "issue-verification-timeout",
        identifier: "ACME-VERIFY",
        title: "Verify before turn",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/verification_failed/, fn ->
        AgentRunner.run(issue, nil)
      end

      refute File.exists?(trace_file)

      assert [%{run_id: run_id, status: "released"}] = RunStore.list_verification_allocations()
      assert String.starts_with?(run_id, "issue-verification-timeout-verification-")
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner releases verification allocation when workspace setup fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-verification-workspace-fail-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(test_root)
      workspace_root = Path.join(test_root, "workspace-root-file")
      File.write!(workspace_root, "not a directory")
      port = free_tcp_port()

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        verification: %{
          enabled: true,
          port_allocation: %{range: [port, port]}
        }
      )

      issue = %Issue{
        id: "issue-verification-workspace-fail",
        identifier: "ACME-VERIFY-WS",
        title: "Release on workspace failure",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace setup failed|enotdir|file exists/i, fn ->
        AgentRunner.run(issue, nil)
      end

      assert [%{run_id: run_id, status: "released", release_reason: "workspace setup failed"}] =
               RunStore.list_verification_allocations()

      assert String.starts_with?(run_id, "issue-verification-workspace-fail-verification-")
    after
      File.rm_rf(test_root)
    end
  end

  describe "QA dev servers" do
    setup do
      issue = %Issue{id: "issue-qa-web", identifier: "ACME-WEB", title: "Dashboard tweak", state: "Auto Review"}
      %{issue: issue, port: free_tcp_port()}
    end

    defp qa_settings(port, dev_server) do
      write_workflow_file!(Workflow.workflow_file_path(),
        verification: %{enabled: true, port_allocation: %{range: [port, port]}, dev_server: dev_server}
      )

      Config.settings!()
    end

    @tag :unix_socket
    test "starts the dev server in the worktree, reports its URL, then stops it and releases the port", %{issue: issue, port: port} do
      settings =
        qa_settings(port, %{
          start_cmd: "exec python3 #{@dev_server}",
          health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/",
          health_timeout_ms: 5_000,
          stop_timeout_ms: 1_000
        })

      assert Verification.dev_server_configured?(settings)

      assert {:ok, %{pid: pid, port: ^port, url: url} = dev_server} =
               Verification.start_qa_dev_server(issue, "qa-web-run", System.tmp_dir!(), settings: settings, repo_key: "default")

      assert url == "http://127.0.0.1:#{port}/"
      assert Process.alive?(pid)
      assert :ok = Verification.stop_qa_dev_server(dev_server)
      refute Process.alive?(pid)
      assert [%{run_id: "qa-web-run", status: "released", release_reason: "qa pass ended"}] = RunStore.list_verification_allocations()
    end

    test "a dev server that fails its health check returns verification_failed and releases the port", %{issue: issue, port: port} do
      settings =
        qa_settings(port, %{
          start_cmd: "sleep 1",
          health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/healthz",
          health_timeout_ms: 50,
          stop_timeout_ms: 100
        })

      assert {:error, {:verification_failed, {:dev_server_not_on_socket, _socket}}} =
               Verification.start_qa_dev_server(issue, "qa-web-unhealthy", System.tmp_dir!(), settings: settings)

      assert [%{run_id: "qa-web-unhealthy", status: "released", release_reason: "qa dev server did not start"}] =
               RunStore.list_verification_allocations()
    end

    test "needs verification on and a start command", %{issue: issue, port: port} do
      no_command = qa_settings(port, %{})
      refute Verification.dev_server_configured?(no_command)

      assert {:error, :dev_server_not_configured} =
               Verification.start_qa_dev_server(issue, "qa-web-no-command", System.tmp_dir!(), settings: no_command)

      assert [%{status: "released"}] = RunStore.list_verification_allocations()

      write_workflow_file!(Workflow.workflow_file_path())
      disabled = Config.settings!()
      refute Verification.dev_server_configured?(disabled)

      assert {:error, :dev_server_not_configured} =
               Verification.start_qa_dev_server(issue, "qa-web-off", System.tmp_dir!(), settings: disabled)
    end

    test "fails when the port pool has no free port", %{issue: issue, port: port} do
      settings = qa_settings(port, %{start_cmd: "sleep 1", health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/"})
      {:ok, _pid} = PortPool.start_link(reconcile_interval_ms: nil, process_alive?: fn _pid -> true end)
      assert {:ok, _allocation} = PortPool.allocate(%{run_id: "holder", port_range: [port, port]})

      assert {:error, :exhausted} = Verification.start_qa_dev_server(issue, "qa-web-busy", System.tmp_dir!(), settings: settings)
    end

    test "builds the base URL from the health check URL" do
      settings = qa_settings(4000, %{start_cmd: "x", health_check_url: "http://localhost:$SYMPHONY_VERIFICATION_PORT/api/v1/state"})
      assert Verification.dev_server_url(4123, settings) == "http://localhost:4123/"

      settings = put_in(settings.verification.dev_server.health_check_url, nil)
      assert Verification.dev_server_url(4123, settings) == "http://127.0.0.1:4123/"
    end
  end

  # Passes the probe, makes the placeholders as bwrap does, then runs the command unsandboxed.
  defp fake_bwrap(root) do
    bwrap = Path.join(root, "bwrap")
    socat = Path.join(root, "socat")

    File.write!(bwrap, """
    #!/bin/sh
    for arg; do last=$arg; done
    [ "$last" = ":" ] && exit 0
    while [ "$1" != /bin/sh ]; do
      [ "$1" = --remount-ro ] && mkdir -p "$2"
      shift
    done
    exec "$@"
    """)

    File.write!(socat, "#!/bin/sh\nexit 0\n")
    Enum.each([bwrap, socat], &File.chmod!(&1, 0o755))
    [os_type: {:unix, :linux}, bwrap: bwrap, socat: socat]
  end

  # The dev server's sandbox allows no TCP listener, and Mix loads deps through one
  # (`Mix.PubSub`, and Mix's build lock), so no Mix task can run inside it. Build the escript the
  # dashboard script serves here, outside the sandbox, as the CI job and an Auto Review `web` pass
  # do before they start the server.
  defp build_escript! do
    {output, status} = System.cmd("mix", ["build"], stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])
    assert status == 0, "mix build failed:\n#{output}"
  end

  defp real_path(path) do
    {:ok, real_path} = SymphonyElixir.PathSafety.canonicalize(path)
    real_path
  end

  defp free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp http_server_responding_after_wait?(url, attempts \\ 50)
  defp http_server_responding_after_wait?(_url, 0), do: true

  defp http_server_responding_after_wait?(url, attempts) do
    if http_ok?(url) do
      Process.sleep(100)
      http_server_responding_after_wait?(url, attempts - 1)
    else
      false
    end
  end

  # This host's own IPv4 addresses but loopback, such as its LAN address.
  defp host_addresses do
    {:ok, interfaces} = :inet.getifaddrs()

    for {_name, options} <- interfaces, {:addr, {first, _, _, _} = address} <- options, first != 127, uniq: true do
      address
    end
  end

  defp http_ok?(url) do
    case Req.get(url, receive_timeout: 100, retry: false) do
      {:ok, %{status: 200}} -> true
      _response -> false
    end
  rescue
    _exception -> false
  end
end
