defmodule SymphonyElixir.LeftoverProcessesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.LeftoverProcesses
  alias SymphonyElixir.LeftoverProcesses.Table

  @root "/workspaces/.qa/symphony/TP-1-0123456789ab"

  defp entry(pid, attrs) do
    Map.merge(%{pid: pid, start_time: "Sat Oct  3 08:00:00 2026", command: "sleep 600", cwd: "/"}, Map.new(attrs))
  end

  # A table that returns each list in `tables` once, then repeats the last one.
  defp table(tables) do
    {:ok, agent} = Agent.start_link(fn -> tables end)

    fn ->
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)
    end
  end

  defp recording_signal do
    test_pid = self()
    fn pid, signal -> send(test_pid, {:signal, pid, signal}) end
  end

  describe "stop_under/2" do
    test "stops processes running in or started from the worktree, and logs each one" do
      in_worktree = entry(11, cwd: @root <> "/sub")
      started_from = entry(12, cwd: "/private/tmp/qa283", command: "/usr/bin/escript #{@root}/bin/symphony run")
      option_value = entry(13, command: "node server.js --root=#{@root}")
      unrelated = entry(14, cwd: "/tmp", command: "sleep 600")
      sibling = entry(15, cwd: @root <> "-other", command: "#{@root}-other/bin/symphony")
      ours = entry(16, cwd: @root)
      no_cwd = entry(17, cwd: nil)

      processes = [in_worktree, started_from, option_value, unrelated, sibling, ours, no_cwd]

      log =
        capture_log(fn ->
          stopped =
            LeftoverProcesses.stop_under([@root],
              table: table([{:ok, processes}, {:ok, []}]),
              signal: recording_signal(),
              own_pid: 16,
              log_context: "issue_identifier=TP-1"
            )

          assert Enum.map(stopped, & &1.pid) == [11, 12, 13]
        end)

      for pid <- [11, 12, 13], do: assert_received({:signal, ^pid, "TERM"})
      refute_received {:signal, _pid, _signal}
      assert log =~ "Stopping leftover process issue_identifier=TP-1 pid=11 cwd=#{@root}/sub cpu_time=unknown"
      assert log =~ "pid=12 cwd=/private/tmp/qa283"
    end

    test "stops a detached Gradle daemon whose registry is in the workspace" do
      daemon_command = "/opt/jdk/bin/java -cp /Users/me/.gradle/wrapper/dists/gradle-9.8.0/lib/gradle-daemon-main-9.8.0.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 9.8.0"
      ours = entry(21, ppid: 1, cwd: @root <> "/.gradle-daemons/9.8.0", command: daemon_command)
      shared = entry(22, ppid: 1, cwd: "/Users/me/.gradle/daemon/9.8.0", command: daemon_command)

      capture_log(fn ->
        stopped =
          LeftoverProcesses.stop_under([@root],
            table: table([{:ok, [ours, shared]}, {:ok, []}]),
            signal: recording_signal(),
            own_pid: 99
          )

        assert Enum.map(stopped, & &1.pid) == [21]
      end)

      assert_received {:signal, 21, "TERM"}
      refute_received {:signal, _pid, _signal}
    end

    test "spares Symphony and the processes it still runs, and logs CPU time" do
      symphony = entry(50, ppid: 1, cwd: @root)
      git = entry(51, ppid: 50, cwd: @root, command: "git -C #{@root} status")
      git_helper = entry(52, ppid: 51, cwd: @root, command: "git-remote-https origin")
      detached = entry(53, ppid: 1, cwd: @root, cpu_time: "165:01.23", command: "yes")

      log =
        capture_log(fn ->
          stopped =
            LeftoverProcesses.stop_under([@root],
              table: table([{:ok, [symphony, git, git_helper, detached]}, {:ok, []}]),
              signal: recording_signal(),
              own_pid: 50
            )

          assert Enum.map(stopped, & &1.pid) == [53]
        end)

      assert_received {:signal, 53, "TERM"}
      refute_received {:signal, _pid, _signal}
      assert log =~ "Stopping leftover process pid=53 cwd=#{@root} cpu_time=165:01.23 command=\"yes\""
    end

    test "sends SIGKILL after the grace period only to the same processes" do
      stubborn = entry(21, cwd: @root)
      reused = entry(22, cwd: @root)
      reused_now = %{reused | start_time: "Sat Oct  3 09:00:00 2026"}

      log =
        capture_log(fn ->
          LeftoverProcesses.stop_under([@root],
            table: table([{:ok, [stubborn, reused]}, {:ok, [stubborn, reused_now]}]),
            signal: recording_signal(),
            grace_ms: 150
          )
        end)

      assert_received {:signal, 21, "TERM"}
      assert_received {:signal, 22, "TERM"}
      assert_received {:signal, 21, "KILL"}
      refute_received {:signal, 22, "KILL"}
      assert log =~ "Leftover process ignored SIGTERM; sending SIGKILL pid=21"
    end

    test "does not send SIGKILL when the table can't be read again" do
      LeftoverProcesses.stop_under([@root],
        table: table([{:ok, [entry(31, cwd: @root)]}, {:error, :denied}]),
        signal: recording_signal(),
        grace_ms: 0
      )

      assert_received {:signal, 31, "TERM"}
      refute_received {:signal, 31, "KILL"}
    end

    test "logs and signals nothing when the process table can't be read" do
      log =
        capture_log(fn ->
          assert [] =
                   LeftoverProcesses.stop_under([@root], table: fn -> {:error, :denied} end, signal: recording_signal())
        end)

      assert log =~ "Could not read the process table to stop leftover processes"
      assert log =~ ":denied"
      refute_received {:signal, _pid, _signal}
    end

    test "matches the worktree through symlinks and keeps a root it can't resolve" do
      base = Path.join(System.tmp_dir!(), "leftover-#{System.unique_integer([:positive])}")
      real = Path.join(base, "real")
      File.mkdir_p!(real)
      File.ln_s!(real, Path.join(base, "link"))
      File.write!(Path.join(base, "file"), "")
      on_exit(fn -> File.rm_rf(base) end)

      {:ok, canonical} = SymphonyElixir.PathSafety.canonicalize(real)

      stopped =
        LeftoverProcesses.stop_under([Path.join(base, "link"), Path.join(base, "file/sub")],
          table: table([{:ok, [entry(41, cwd: canonical), entry(42, cwd: Path.join(base, "file/sub"))]}, {:ok, []}]),
          signal: recording_signal()
        )

      assert Enum.map(stopped, & &1.pid) == [41, 42]
    end

    test "reads the configured process table and signals real pids by default" do
      # The test helper configures an empty process table.
      assert [] = LeftoverProcesses.stop_under([@root])

      port = Port.open({:spawn_executable, System.find_executable("sleep")}, [:exit_status, args: ["600"]])
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      [_stopped] =
        LeftoverProcesses.stop_under([@root],
          table: table([{:ok, [entry(os_pid, cwd: @root)]}, {:ok, []}]),
          own_pid: 1
        )

      assert_receive {^port, {:exit_status, status}}, 5_000
      assert status != 0
    end
  end

  describe "Table" do
    test "parses ps output with its five-word start time" do
      output = """
          1     0 Sat Oct  3 07:00:00 2026   0:12.50 /sbin/launchd
       3726     1 Sat Oct  3 08:15:02 2026 165:01.23 /usr/bin/escript /w/.qa/TP-283/bin/symphony run --port 4000
      junk
      """

      assert Table.parse_ps(output) == [
               %{pid: 1, ppid: 0, start_time: "Sat Oct 3 07:00:00 2026", cpu_time: "0:12.50", command: "/sbin/launchd"},
               %{
                 pid: 3726,
                 ppid: 1,
                 start_time: "Sat Oct 3 08:15:02 2026",
                 cpu_time: "165:01.23",
                 command: "/usr/bin/escript /w/.qa/TP-283/bin/symphony run --port 4000"
               }
             ]
    end

    test "parses lsof cwd output" do
      output = "p1\nfcwd\nn/\np3726\nfcwd\nn/private/tmp/qa283\npbad\nn/ignored\n"
      assert Table.parse_lsof(output) == %{1 => "/", 3726 => "/private/tmp/qa283"}
    end

    test "reports a ps failure" do
      assert {:error, {:ps_failed, 1, "operation not permitted"}} = Table.read(fn _ps, _args, _opts -> {"operation not permitted\n", 1} end)
      assert {:error, "boom"} = Table.read(fn _ps, _args, _opts -> raise "boom" end)
    end
  end
end
