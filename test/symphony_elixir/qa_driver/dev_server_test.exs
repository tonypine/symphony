defmodule SymphonyElixir.QaDriver.DevServerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{PathSafety, Workspace}
  alias SymphonyElixir.QaDriver.{DevServer, Host}

  @dev_server Path.expand("../../support/dev_server.py", __DIR__)
  @late_reaper Path.expand("../../support/late_reaper.py", __DIR__)

  # The QA host is this machine: `cmd` runs each script with the local shell, as the QA user's
  # shell runs it over SSH, and `ship` unpacks the tar where `Remote.ship/3` would.
  setup do
    File.mkdir_p!(System.tmp_dir!())
    {:ok, tmp} = PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "qa-dev-server-test-#{System.unique_integer([:positive])}")
    worktree = Path.join(root, "worktree")
    run_dir = Path.join(root, "run")
    scratch_dir = Path.join(root, "scratch")
    Enum.each([worktree, run_dir, scratch_dir], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(Path.join(worktree, "health"), "ok\n")
    for args <- [~w(init -q), ~w(add health), ~w(-c user.name=QA -c user.email=qa@example.invalid commit -q -m head)], do: {_out, 0} = git(args, worktree)

    config = %{host: local_host(), host_dir: run_dir, git: &git/2, worktree: worktree, scratch_dir: scratch_dir}
    %{config: config, run_dir: run_dir}
  end

  defp git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)

  defp local_host(overrides \\ %{}) do
    Map.merge(
      %{
        cmd: fn executable, args, opts -> Host.cmd(executable, args, opts) end,
        ship: fn tar, dest ->
          File.rm_rf!(dest)
          File.mkdir!(dest)
          {_out, 0} = System.cmd("tar", ["-x", "-f", tar, "-C", dest])
          :ok
        end
      },
      overrides
    )
  end

  defp spec(overrides) do
    port = free_port()

    Map.merge(
      %{
        build_cmd: nil,
        start_cmd: "exec python3 #{@dev_server}",
        health_check_url: "http://127.0.0.1:#{port}/health",
        health_timeout_ms: 10_000,
        stop_signal: "TERM",
        stop_timeout_ms: 2_000,
        port: port,
        url: "http://127.0.0.1:#{port}/",
        ticket: "TP-1"
      },
      overrides
    )
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp alive?(pid), do: match?({_out, 0}, System.cmd("/bin/sh", ["-c", "kill -0 #{pid}"], stderr_to_stdout: true))

  # Whether a member of the process group still answers `kill -0`: macOS skips a zombie there,
  # Linux finds it until its parent reaps it.
  defp group_alive?(pgid), do: match?({_out, 0}, System.cmd("/bin/sh", ["-c", "kill -0 -- -#{pgid}"], stderr_to_stdout: true))

  defp serving?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000) do
      {:ok, socket} -> :gen_tcp.close(socket) == :ok
      {:error, _reason} -> false
    end
  end

  defp server_pid(run_dir), do: run_dir |> Path.join("dev-server/src/pid") |> File.read!() |> String.trim()

  # Waits up to 5 seconds for `start_cmd` to have written its pid.
  defp await_pid(run_dir, tries \\ 250) do
    case File.read(Path.join(run_dir, "dev-server/src/pid")) do
      {:ok, pid} when byte_size(pid) > 1 ->
        :ok

      _not_yet when tries > 0 ->
        Process.sleep(20)
        await_pid(run_dir, tries - 1)

      not_yet ->
        flunk("start_cmd never wrote its pid: #{inspect(not_yet)}")
    end
  end

  # Another server on `port`, outside any pass: it answers every request with 200.
  defp http_listener(port) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])
    acceptor = spawn_link(fn -> answer_200(socket) end)
    :ok = :gen_tcp.controlling_process(socket, acceptor)
    socket
  end

  defp answer_200(socket) do
    with {:ok, client} <- :gen_tcp.accept(socket) do
      _request = :gen_tcp.recv(client, 0, 1_000)
      :gen_tcp.send(client, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
      :gen_tcp.close(client)
      answer_200(socket)
    end
  end

  # Waits up to 5 seconds for `start_cmd` to have exited.
  defp await_exit(run_dir, tries \\ 250) do
    cond do
      File.exists?(Path.join(run_dir, "dev-server/exit-status")) -> :ok
      tries > 0 -> Process.sleep(20) && await_exit(run_dir, tries - 1)
      true -> flunk("start_cmd never exited")
    end
  end

  # The pid `lsof` names as the listener, nil on a host without `lsof`, where the port check
  # still finds the port busy but cannot tell by whom.
  defp listener_pid(pid), do: if(System.find_executable("lsof"), do: pid)

  defp health(url) do
    {output, 0} = System.cmd("curl", ["-s", "--noproxy", "*", "-o", "/dev/null", "-w", "%{http_code}", url])
    output
  end

  test "builds and starts the server in its own copy of the PR head, healthy, then stops it", %{config: config, run_dir: run_dir} do
    spec =
      spec(%{
        build_cmd: "echo building; touch built",
        start_cmd: "test -f built || exit 9; echo $$ > pid; env > env.txt; exec python3 #{@dev_server}"
      })

    assert {:ok, %{pid: pid, port: port, url: url} = server} = DevServer.start(config, spec)
    assert port == spec.port and url == spec.url
    assert health(spec.health_check_url) == "200"

    dir = Path.join(run_dir, "dev-server")
    env = File.read!(Path.join(dir, "src/env.txt"))
    assert env =~ "SYMPHONY_VERIFICATION_PORT=#{port}\n"
    assert env =~ "HOME=#{dir}/home\n"
    assert env =~ "TMPDIR=#{dir}/tmp/\n"
    assert File.read!(Path.join(dir, "ticket")) == "TP-1\n"
    assert File.read!(Path.join(dir, "server.log")) =~ "building"
    # The server is a process group's leader's child: the group goes with the stop.
    assert alive?(server_pid(run_dir))

    assert DevServer.stop(config, server) == :stopped
    refute alive?(server_pid(run_dir))
    refute alive?(pid)
    assert DevServer.stop(config, server) == :gone
  end

  test "a live server's own variables reach its build and start commands, and the app's are kept on the server", %{config: config, run_dir: run_dir} do
    spec =
      spec(%{
        build_cmd: "printf '%s' \"$SYMPHONY_QA_CONTROL_TOKEN\" > build-token",
        start_cmd: "printf '%s' \"$SYMPHONY_QA_CONTROL_TOKEN|$QA_NOTE\" > start-env; exec python3 #{@dev_server}",
        env: [{"SYMPHONY_QA_CONTROL_TOKEN", "tok en"}, {"QA_NOTE", "a=b"}],
        launch_env: [{"SYMPHONY_BAR_CONTROL_URL", "http://127.0.0.1:1"}]
      })

    assert {:ok, server} = DevServer.start(config, spec)
    assert server.launch_env == [{"SYMPHONY_BAR_CONTROL_URL", "http://127.0.0.1:1"}]
    src = Path.join(run_dir, "dev-server/src")
    assert File.read!(Path.join(src, "build-token")) == "tok en"
    assert File.read!(Path.join(src, "start-env")) == "tok en|a=b"
    assert DevServer.stop(config, server) == :stopped

    # Without them, as `verification.dev_server`, the app gets nothing of the server's.
    assert {:ok, server} = DevServer.start(config, spec(%{}))
    assert server.launch_env == []
    assert DevServer.stop(config, server) == :stopped
  end

  # The server's parent sits outside the group and reaps it only a second after the kill, as a
  # slow reaper on a loaded runner does: the stop waits for it, and a zombie no longer serves.
  test "kills the group when it outlives stop_timeout_ms, and returns once the kill has landed", %{config: config} do
    spec = spec(%{start_cmd: "trap '' TERM; exec python3 #{@late_reaper} #{@dev_server}", stop_timeout_ms: 300})

    assert {:ok, server} = DevServer.start(config, spec)
    assert serving?(spec.port)
    assert DevServer.stop(config, server) == :killed
    refute group_alive?(server.pid)
    refute serving?(spec.port)
  end

  test "a failed build_cmd is its exit status and the log's last 20 lines", %{config: config} do
    spec = spec(%{build_cmd: "for i in $(seq 30); do echo line $i; done; exit 3"})

    assert {:error, {:dev_server_build_failed, 3}, log} = DevServer.start(config, spec)
    assert log =~ "line 30"
    refute log =~ "line 10\n"
    assert length(String.split(log, "\n")) == 20
  end

  test "a server that exits before its health check is its exit status", %{config: config} do
    assert {:error, {:dev_server_exit, 4}, "boom"} = DevServer.start(config, spec(%{start_cmd: "echo boom; exit 4"}))
  end

  describe "the pass's own server" do
    test "a port something listens on before the start is busy, with its pid, and no server starts", %{config: config, run_dir: run_dir} do
      spec = spec(%{start_cmd: "echo $$ > pid; exec python3 #{@dev_server}"})
      {:ok, socket} = :gen_tcp.listen(spec.port, ip: {127, 0, 0, 1})
      on_exit(fn -> :gen_tcp.close(socket) end)

      os_pid = String.to_integer(System.pid())
      assert DevServer.start(config, spec) == {:error, {:dev_server_port_busy, spec.port, listener_pid(os_pid), nil}, ""}
      refute File.exists?(Path.join(run_dir, "dev-server/src/pid"))
    end

    test "a port another pass's server still holds names that pass's ticket", %{config: config, run_dir: run_dir} do
      spec = spec(%{start_cmd: "echo $$ > pid; exec python3 #{@dev_server}", ticket: "TP-1124"})
      assert {:ok, server} = DevServer.start(config, spec)
      on_exit(fn -> DevServer.stop(config, server) end)
      holder = run_dir |> server_pid() |> String.to_integer()

      second_run = Path.join(Path.dirname(run_dir), "second-run")
      File.mkdir_p!(second_run)
      {pid, ticket} = if System.find_executable("lsof"), do: {holder, "TP-1124"}, else: {nil, nil}

      assert DevServer.start(%{config | host_dir: second_run}, %{spec | ticket: "TP-1123"}) == {:error, {:dev_server_port_busy, spec.port, pid, ticket}, ""}
      assert DevServer.stop(config, server) == :stopped
    end

    # TP-1123: its server could not bind the port and exited at once, while another server
    # answered 200 there. The port check is answered `free` (that server came after it), and the
    # health check runs once `start_cmd` has exited, so the order is the incident's every time.
    test "a start_cmd that exited is its exit status and log even when something else answers 200", %{config: config, run_dir: run_dir} do
      spec = spec(%{start_cmd: "echo bind: address already in use; exit 4"})
      _listener = http_listener(spec.port)
      assert health(spec.health_check_url) == "200"

      host = fn executable, ["-c", script | _rest] = args, opts ->
        cond do
          String.contains?(script, "lsof -nP") -> {:ok, {"symphony-qa-dev-server-port:free\n", 0}}
          String.contains?(script, "end=") -> await_exit(run_dir) && Host.cmd(executable, args, opts)
          true -> Host.cmd(executable, args, opts)
        end
      end

      config = %{config | host: local_host(%{cmd: host})}
      assert DevServer.start(config, spec) == {:error, {:dev_server_exit, 4}, "bind: address already in use"}
    end

    test "the port check cannot run or answers nothing it knows", %{config: config} do
      for {answer, expected} <- [
            {{:ok, {"symphony-qa-dev-server-port:busy::\n", 0}}, {:dev_server_port_busy, 0, nil, nil}},
            {{:ok, {"symphony-qa-dev-server-port:busy:x1:\n", 0}}, {:dev_server_port_busy, 0, nil, nil}},
            {{:ok, {"huh\n", 0}}, {:dev_server_unreachable, "huh"}},
            {{:ok, {"ssh: broken pipe\n", 255}}, {:dev_server_unreachable, "ssh: broken pipe"}},
            {{:error, :closed}, {:dev_server_unreachable, ":closed"}}
          ] do
        config = %{config | host: local_host(%{cmd: fail_script("lsof -nP", answer)})}
        spec = spec(%{})
        expected = with {:dev_server_port_busy, 0, pid, ticket} <- expected, do: {:dev_server_port_busy, spec.port, pid, ticket}
        assert DevServer.start(config, spec) == {:error, expected, ""}
      end
    end
  end

  test "a health check that never answers 200 times out and stops the server", %{config: config, run_dir: run_dir} do
    spec = spec(%{start_cmd: "echo $$ > pid; echo waiting; exec sleep 30", health_timeout_ms: 1_000})

    assert {:error, :health_timeout, "waiting"} = DevServer.start(config, spec)
    refute alive?(server_pid(run_dir))
  end

  describe "a QA host that cannot be asked" do
    test "the run directory cannot be prepared", %{config: config} do
      for answer <- [{:error, :econnrefused}, {:ok, {"ssh: connect to host qa-vm port 22: Connection refused\n", 255}}, {:ok, {"", 0}}] do
        config = %{config | host: local_host(%{cmd: fn _executable, _args, _opts -> answer end})}
        assert {:error, {:dev_server_unreachable, _message}, ""} = DevServer.start(config, spec(%{}))
      end
    end

    test "the PR head cannot be archived or copied", %{config: config} do
      config_without_git = %{config | git: fn _args, _cwd -> {"fatal: not a git repository\n", 128} end}

      assert {:error, {:dev_server_unreachable, "git archive failed (exit 128): fatal: not a git repository"}, ""} =
               DevServer.start(config_without_git, spec(%{}))

      config_without_ship = %{config | host: local_host(%{ship: fn _tar, _dest -> {:error, "exit 1: disk full"} end})}

      assert {:error, {:dev_server_unreachable, "the PR head could not be copied to the QA host: exit 1: disk full"}, ""} =
               DevServer.start(config_without_ship, spec(%{}))
    end

    test "the build or the start cannot run", %{config: config} do
      for {mode, answer, cause} <- [
            {"build", {:error, :timeout}, {:dev_server_build_failed, :timeout}},
            {"build", {:ok, {"ssh: broken pipe\n", 255}}, {:dev_server_unreachable, "ssh: broken pipe"}},
            {"build", {:error, :closed}, {:dev_server_unreachable, ":closed"}},
            {"start", {:ok, {"no pid here\n", 0}}, {:dev_server_unreachable, "no pid here"}},
            {"start", {:ok, {"ssh: broken pipe\n", 255}}, {:dev_server_unreachable, "ssh: broken pipe"}},
            {"start", {:error, :closed}, {:dev_server_unreachable, ":closed"}}
          ] do
        config = %{config | host: local_host(%{cmd: fail_on(mode, answer)})}
        assert {:error, ^cause, _log} = DevServer.start(config, spec(%{build_cmd: "true"}))
      end
    end

    test "the health check cannot run", %{config: config, run_dir: run_dir} do
      spec = spec(%{start_cmd: "echo $$ > pid; exec sleep 30"})

      # The host is lost once the server runs, so the stop that follows has a server to stop.
      lost_host = fn executable, ["-c", script | _rest] = args, opts ->
        if String.contains?(script, "end=") do
          await_pid(run_dir)
          {:error, :closed}
        else
          Host.cmd(executable, args, opts)
        end
      end

      config = %{config | host: local_host(%{cmd: lost_host})}
      assert {:error, {:dev_server_unreachable, ":closed"}, ""} = DevServer.start(config, spec)
      refute alive?(server_pid(run_dir))
    end

    test "the health check answers with an unknown exit status or nothing it knows", %{config: config} do
      for {answer, expected} <- [
            {{:ok, {"symphony-qa-dev-server-exit:unknown\nkilled\n", 0}}, {:error, {:dev_server_exit, "unknown"}, "killed"}},
            {{:ok, {"ssh: broken pipe\n", 255}}, {:error, {:dev_server_unreachable, "ssh: broken pipe"}, ""}}
          ] do
        config = %{config | host: local_host(%{cmd: fail_script("end=", answer)})}
        assert DevServer.start(config, spec(%{start_cmd: "exec sleep 30"})) == expected
      end
    end

    test "the stop cannot run", %{config: config} do
      assert {:ok, server} = DevServer.start(config, spec(%{}))
      assert DevServer.stop(%{config | host: local_host(%{cmd: fail_script("kill -s", {:error, :closed})})}, server) == {:error, :closed}
      assert DevServer.stop(%{config | host: local_host(%{cmd: fail_script("kill -s", {:ok, {"huh\n", 0}})})}, server) == {:error, "huh"}
      assert DevServer.stop(config, server) == :stopped
    end
  end

  # Answers the run script's `mode` call with `answer` and runs every other script.
  defp fail_on(mode, answer) do
    fn
      "/bin/bash", ["-c", _script, "sh", _dir, _port, ^mode, _command], _opts -> answer
      executable, args, opts -> Host.cmd(executable, args, opts)
    end
  end

  # Answers the script holding `text` with `answer` and runs every other one.
  defp fail_script(text, answer) do
    fn executable, ["-c", script | _rest] = args, opts ->
      if String.contains?(script, text), do: answer, else: Host.cmd(executable, args, opts)
    end
  end
end
