defmodule SymphonyElixir.AgentProcessesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.AgentProcesses

  # A fake agent that ignores stdin EOF and SIGHUP, with a child in its group.
  @eof_ignoring_agent "trap '' HUP; sleep 600 & echo ready; while :; do sleep 1; done"
  # The same, also ignoring SIGTERM, so only SIGKILL stops it.
  @term_ignoring_agent "trap '' HUP TERM; sleep 600 & echo ready; while :; do sleep 1; done"

  test "the application supervises it with a shutdown longer than the grace period" do
    assert is_pid(Process.whereis(AgentProcesses))
    assert %{shutdown: 5_000} = AgentProcesses.child_spec([])
    assert %{shutdown: 2_100} = AgentProcesses.child_spec(grace_ms: 100)
  end

  test "tracking a closed port or a missing server is a no-op" do
    port = open_agent("exit 0")
    Port.close(port)
    assert :ok = AgentProcesses.track(port, server: unique_name())

    port = open_agent(@eof_ignoring_agent)
    os_pid = os_pid(port)
    assert :ok = AgentProcesses.track(port, server: unique_name())
    Port.close(port)
    kill_group(os_pid)
  end

  test "an agent left running after its port closes gets SIGTERM" do
    server = start_server(grace_ms: 5_000)
    port = open_agent(@eof_ignoring_agent)
    os_pid = os_pid(port)
    :ok = AgentProcesses.track(port, server: server)
    sync(server)

    Port.close(port)

    assert eventually_gone?(os_pid, 3_000)
  end

  test "an agent dies with the process that owns its port" do
    server = start_server(grace_ms: 5_000)
    test_pid = self()

    owner =
      spawn(fn ->
        port = open_agent(@eof_ignoring_agent)
        :ok = AgentProcesses.track(port, server: server)
        send(test_pid, {:os_pid, os_pid(port)})
        Process.sleep(:infinity)
      end)

    assert_receive {:os_pid, os_pid}
    sync(server)
    assert group_alive?(os_pid)

    Process.exit(owner, :kill)

    assert eventually_gone?(os_pid, 3_000)
  end

  test "an agent that ignores SIGTERM gets SIGKILL after the grace period" do
    server = start_server(grace_ms: 300)
    port = open_agent(@term_ignoring_agent)
    os_pid = os_pid(port)
    :ok = AgentProcesses.track(port, server: server)
    sync(server)

    Port.close(port)
    Process.sleep(150)
    assert group_alive?(os_pid)

    assert eventually_gone?(os_pid, 3_000)
    assert %{stopping: stopping} = :sys.get_state(server)
    assert MapSet.size(stopping) == 0
  end

  test "stopping the server stops every tracked agent within the grace period" do
    server = start_server(grace_ms: 2_000)
    port = open_agent(@eof_ignoring_agent)
    os_pid = os_pid(port)
    :ok = AgentProcesses.track(port, server: server)
    sync(server)

    {elapsed_us, :ok} = :timer.tc(fn -> GenServer.stop(server, :shutdown) end)

    refute group_alive?(os_pid)
    assert elapsed_us < 2_000_000
    assert_receive {^port, {:exit_status, _status}}
  end

  test "stopping the server sends SIGKILL to agents that ignore SIGTERM" do
    server = start_server(grace_ms: 300)
    port = open_agent(@term_ignoring_agent)
    os_pid = os_pid(port)
    :ok = AgentProcesses.track(port, server: server)

    # A second agent whose port already closed and that is waiting for SIGKILL.
    stopping_port = open_agent(@term_ignoring_agent)
    stopping_os_pid = os_pid(stopping_port)
    :ok = AgentProcesses.track(stopping_port, server: server)
    sync(server)
    Port.close(stopping_port)
    sync(server)

    log = capture_log(fn -> :ok = GenServer.stop(server, :shutdown) end)

    assert log =~ "ignored SIGTERM on shutdown"
    assert eventually_gone?(os_pid, 1_000)
    assert eventually_gone?(stopping_os_pid, 1_000)
    assert_receive {^port, {:exit_status, _status}}
  end

  test "records tracked agents in a ledger until their group is stopped" do
    path = ledger_path()
    server = start_server(grace_ms: 100, ledger_path: path, start_time: fn _pid -> {:ok, "Sat Oct  3 07:50:16 2026"} end)
    port = open_agent(@eof_ignoring_agent)
    os_pid = os_pid(port)
    :ok = AgentProcesses.track(port, server: server, workspace: "/workspaces/repo/TP-1")
    sync(server)

    assert [%{"pgid" => ^os_pid, "start_time" => "Sat Oct  3 07:50:16 2026", "workspace" => "/workspaces/repo/TP-1"}] = read_ledger(path)

    Port.close(port)
    assert eventually_gone?(os_pid, 3_000)
    Process.sleep(200)
    assert read_ledger(path) == []
  end

  test "records no start time when it can't be read" do
    path = ledger_path()
    server = start_server(ledger_path: path, start_time: fn _pid -> {:error, :denied} end)
    port = open_agent(@eof_ignoring_agent)
    os_pid = os_pid(port)
    :ok = AgentProcesses.track(port, server: server)
    sync(server)

    assert [%{"pgid" => ^os_pid, "start_time" => nil, "workspace" => nil}] = read_ledger(path)
    kill_group(os_pid)
  end

  test "a restart stops agents that a killed Symphony left running" do
    path = ledger_path()
    start_time = fn _pid -> {:ok, "Sat Oct  3 07:50:16 2026"} end
    {:ok, crashed} = GenServer.start(AgentProcesses, ledger_path: path, start_time: start_time)
    port = open_agent(@term_ignoring_agent)
    os_pid = os_pid(port)
    :ok = AgentProcesses.track(port, server: crashed, workspace: "/workspaces/repo/TP-1")
    sync(crashed)
    Process.exit(crashed, :kill)
    assert group_alive?(os_pid)

    log =
      capture_log(fn ->
        server = start_server(grace_ms: 200, ledger_path: path, start_time: start_time)
        refute group_alive?(os_pid)
        assert AgentProcesses.dispatch_blocked_reason("TP-1", server) == nil
      end)

    assert log =~ "Stopping agent process groups left running by a previous Symphony pgids=[#{os_pid}]"
    assert read_ledger(path) == []
  end

  test "never signals a process that reused a recorded pid" do
    path = ledger_path()
    port = open_agent(@eof_ignoring_agent)
    os_pid = os_pid(port)
    write_ledger(path, [%{pgid: os_pid, start_time: "Thu Oct  1 09:00:00 2026", workspace: "/workspaces/repo/TP-1"}])

    log =
      capture_log(fn ->
        server = start_server(grace_ms: 100, ledger_path: path, start_time: fn _pid -> {:ok, "Sat Oct  3 07:50:16 2026"} end)
        assert AgentProcesses.dispatch_blocked_reason("TP-1", server) == nil
      end)

    assert log =~ "its pid now belongs to another process pgid=#{os_pid}"
    assert group_alive?(os_pid)
    assert read_ledger(path) == []
    kill_group(os_pid)
  end

  test "groups that are gone are dropped from the ledger" do
    path = ledger_path()
    port = open_agent("echo ready; read line")
    exited_pid = os_pid(port)
    Port.close(port)
    assert eventually_gone?(exited_pid, 3_000)
    write_ledger(path, [%{pgid: exited_pid, start_time: "Sat Oct  3 07:50:16 2026", workspace: "/workspaces/repo/TP-1"}])

    start_server(ledger_path: path, start_time: fn _pid -> flunk("a gone group needs no start time") end)

    assert read_ledger(path) == []
  end

  test "an agent that can't be confirmed stopped blocks its issue until it is gone" do
    for {recorded, start_time_result, reason} <- [
          {"Sat Oct  3 07:50:16 2026", {:error, :denied}, "could not read the start time"},
          {"Sat Oct  3 07:50:16 2026", :not_found, "exited but the group is still running"},
          {nil, {:ok, "Sat Oct  3 07:50:16 2026"}, "no start time was recorded"}
        ] do
      path = ledger_path()
      port = open_agent(@eof_ignoring_agent)
      os_pid = os_pid(port)
      write_ledger(path, [%{pgid: os_pid, start_time: recorded, workspace: "/workspaces/repo/TP-9"}])

      log =
        capture_log(fn ->
          server = start_server(ledger_path: path, start_time: fn _pid -> start_time_result end)

          assert AgentProcesses.dispatch_blocked_reason("TP-9", server) =~ reason
          assert AgentProcesses.dispatch_blocked_reason("TP-8", server) == nil
          assert group_alive?(os_pid)
          assert [%{"pgid" => ^os_pid}] = read_ledger(path)

          kill_group(os_pid)
          assert eventually_gone?(os_pid, 3_000)
          assert AgentProcesses.dispatch_blocked_reason("TP-9", server) == nil
          assert read_ledger(path) == []
        end)

      assert log =~ "Not dispatching issues in workspace=/workspaces/repo/TP-9"
      assert log =~ "dispatch allowed again pgid=#{os_pid}"
    end
  end

  test "an agent that survives SIGKILL blocks its issue" do
    path = ledger_path()
    test_pid = self()
    write_ledger(path, [%{pgid: 4242, start_time: "Sat Oct  3 07:50:16 2026", workspace: "/workspaces/repo/TP-9"}, %{pgid: 4343, workspace: nil}])

    signal = fn pgid, signal ->
      send(test_pid, {:signal, pgid, signal})
      {"", 0}
    end

    log =
      capture_log(fn ->
        server = start_server(grace_ms: 0, ledger_path: path, signal: signal, start_time: fn _pid -> {:ok, "Sat Oct  3 07:50:16 2026"} end)
        assert AgentProcesses.dispatch_blocked_reason("TP-9", server) =~ "still running after SIGKILL"
        assert AgentProcesses.dispatch_blocked_reason(nil, server) == nil
      end)

    assert_received {:signal, 4242, "TERM"}
    assert_received {:signal, 4242, "KILL"}
    assert log =~ "pgid=4242 is still running after SIGKILL"
    assert log =~ "workspace=: an agent left running"
    assert length(read_ledger(path)) == 2
  end

  test "an unreadable ledger is ignored and a failed ledger write is logged" do
    for contents <- ["not json", ~s({"pgid": 4242}), ~s([1, {"pgid": 1}, {"pgid": "4242"}])] do
      path = ledger_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)

      capture_log(fn -> start_server(ledger_path: path) end)
      assert read_ledger(path) == []
    end

    blocker = ledger_path()
    File.mkdir_p!(Path.dirname(blocker))
    File.write!(blocker, "")

    log = capture_log(fn -> start_server(ledger_path: Path.join(blocker, "agent_processes.json")) end)
    assert log =~ "Failed to write agent process ledger"
  end

  test "an issue is not blocked when the server isn't running" do
    assert AgentProcesses.dispatch_blocked_reason("TP-1", unique_name()) == nil
  end

  test "reads a process start time from ps" do
    started = "Sat Oct  3 07:50:16 2026"
    ps = fn _ps, ["-o", "lstart=", "-p", "42"], _opts -> {started <> "\n", 0} end
    assert {:ok, ^started} = AgentProcesses.process_start_time(42, ps)
    assert :not_found = AgentProcesses.process_start_time(42, fn _ps, _args, _opts -> {"", 1} end)
    assert {:error, {:ps_failed, 1, "ps: denied"}} = AgentProcesses.process_start_time(42, fn _ps, _args, _opts -> {"ps: denied\n", 1} end)
    assert {:error, {:ps_failed, 2, "usage"}} = AgentProcesses.process_start_time(42, fn _ps, _args, _opts -> {"usage", 2} end)
    assert {:error, "boom"} = AgentProcesses.process_start_time(42, fn _ps, _args, _opts -> raise "boom" end)

    # Sandboxed test runs may hide other processes from `ps`; either way it's never a crash.
    assert match?({:ok, _started}, AgentProcesses.process_start_time(String.to_integer(System.pid()))) or
             AgentProcesses.process_start_time(String.to_integer(System.pid())) == :not_found
  end

  test "ignores unrelated messages" do
    server = start_server([])
    send(server, :unexpected)
    assert %{running: running} = :sys.get_state(server)
    assert running == %{}
  end

  defp start_server(opts) do
    name = unique_name()
    opts = opts |> Keyword.put(:name, name) |> Keyword.put_new_lazy(:ledger_path, &ledger_path/0)
    start_supervised!({AgentProcesses, opts}, id: name)
    name
  end

  defp ledger_path do
    Path.join(System.tmp_dir!(), "agent_processes_test_#{System.unique_integer([:positive])}/agent_processes.json")
  end

  defp write_ledger(path, entries) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(entries))
  end

  defp read_ledger(path), do: path |> File.read!() |> Jason.decode!()

  defp unique_name, do: :"agent_processes_test_#{System.unique_integer([:positive])}"

  # Casts are asynchronous; a call makes sure the server has handled them.
  defp sync(server), do: :sys.get_state(server)

  # Waits for the agent's "ready", so its traps are set before any signal.
  defp open_agent(script) do
    port =
      Port.open({:spawn_executable, String.to_charlist(System.find_executable("sh"))}, [
        :binary,
        :exit_status,
        args: [~c"-c", String.to_charlist(script)]
      ])

    if script =~ "echo ready", do: assert_receive({^port, {:data, "ready\n"}}, 5_000)
    port
  end

  defp os_pid(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    os_pid
  end

  defp group_alive?(os_pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", "--", "-#{os_pid}"], stderr_to_stdout: true))
  end

  defp kill_group(os_pid), do: System.cmd("kill", ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)

  defp eventually_gone?(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_gone(os_pid, deadline)
  end

  defp wait_gone(os_pid, deadline) do
    cond do
      not group_alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        kill_group(os_pid)
        false

      true ->
        Process.sleep(50)
        wait_gone(os_pid, deadline)
    end
  end
end
