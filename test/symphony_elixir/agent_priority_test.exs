defmodule SymphonyElixir.AgentPriorityTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.AgentPriority

  test "launches the executable through nice with its arguments unchanged" do
    assert {nice, [~c"-n", ~c"10", ~c"/bin/sh", ~c"-c", ~c"exit 0"], :lowered} =
             AgentPriority.command("/bin/sh", [~c"-c", ~c"exit 0"], fn _nice -> true end)

    assert Path.basename(List.to_string(nice)) == "nice"
    assert AgentPriority.nice_increment() == 10
  end

  test "launches the executable as it is when the OS refuses to lower its priority" do
    test_pid = self()

    lowerable? = fn nice ->
      send(test_pid, {:probed, nice})
      false
    end

    assert {~c"/bin/sh", [~c"-c", ~c"exit 0"], :unchanged} = AgentPriority.command("/bin/sh", [~c"-c", ~c"exit 0"], lowerable?)
    assert_received {:probed, nice}
    assert Path.basename(nice) == "nice"
  end

  @tag :process_table
  @tag :setpriority
  test "the agent and the processes it starts run below Symphony's priority" do
    assert {nice, args, :lowered} =
             AgentPriority.command("/bin/sh", [~c"-c", ~c"ps -o nice= -p $$; sh -c 'ps -o nice= -p $$'"])

    port = Port.open({:spawn_executable, nice}, [:binary, :exit_status, args: args])
    output = collect_output(port, "")

    {symphony, 0} = System.cmd("ps", ["-o", "nice=", "-p", System.pid()])
    assert [agent, child] = output |> String.split() |> Enum.map(&String.to_integer/1)
    assert agent > String.to_integer(String.trim(symphony))
    assert child == agent
  end

  test "logs the pid, command and run id of a started agent" do
    port = Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, :exit_status, args: [~c"-c", ~c"sleep 5"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    log =
      capture_log(fn ->
        assert :ok = AgentPriority.log_started(port, "claude -p", "run-123", :lowered)
        assert :ok = AgentPriority.log_started(port, "codex app-server", nil, :unchanged)
      end)

    Port.close(port)

    assert log =~
             ~s([info] Started agent below Symphony's CPU priority nice_increment=10 pid=#{os_pid} run_id=run-123 command="claude -p")

    assert log =~
             ~s([warning] Started agent at Symphony's CPU priority; the OS refused to lower it pid=#{os_pid} run_id=none command="codex app-server")
  end

  test "logs nothing for an agent whose port already closed" do
    port = Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, args: [~c"-c", ~c"sleep 5"]])
    Port.close(port)

    assert capture_log(fn -> assert :ok = AgentPriority.log_started(port, "claude -p", "run-123", :lowered) end) == ""
  end

  defp collect_output(port, acc) do
    receive do
      {^port, {:data, data}} -> collect_output(port, acc <> data)
      {^port, {:exit_status, 0}} -> acc
    after
      5_000 -> flunk("agent did not exit; output so far: #{inspect(acc)}")
    end
  end
end
