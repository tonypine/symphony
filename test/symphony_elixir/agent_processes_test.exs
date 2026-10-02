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
    assert :ok = AgentProcesses.track(port, unique_name())

    port = open_agent(@eof_ignoring_agent)
    os_pid = os_pid(port)
    assert :ok = AgentProcesses.track(port, unique_name())
    Port.close(port)
    kill_group(os_pid)
  end

  test "an agent left running after its port closes gets SIGTERM" do
    server = start_server(grace_ms: 5_000)
    port = open_agent(@eof_ignoring_agent)
    os_pid = os_pid(port)
    :ok = AgentProcesses.track(port, server)
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
        :ok = AgentProcesses.track(port, server)
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
    :ok = AgentProcesses.track(port, server)
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
    :ok = AgentProcesses.track(port, server)
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
    :ok = AgentProcesses.track(port, server)

    # A second agent whose port already closed and that is waiting for SIGKILL.
    stopping_port = open_agent(@term_ignoring_agent)
    stopping_os_pid = os_pid(stopping_port)
    :ok = AgentProcesses.track(stopping_port, server)
    sync(server)
    Port.close(stopping_port)
    sync(server)

    log = capture_log(fn -> :ok = GenServer.stop(server, :shutdown) end)

    assert log =~ "ignored SIGTERM on shutdown"
    assert eventually_gone?(os_pid, 1_000)
    assert eventually_gone?(stopping_os_pid, 1_000)
    assert_receive {^port, {:exit_status, _status}}
  end

  test "ignores unrelated messages" do
    server = start_server([])
    send(server, :unexpected)
    assert %{running: running} = :sys.get_state(server)
    assert running == %{}
  end

  defp start_server(opts) do
    name = unique_name()
    start_supervised!({AgentProcesses, Keyword.put(opts, :name, name)})
    name
  end

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
