defmodule SymphonyElixir.QaAndroid.EmulatorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.QaAndroid.Emulator

  @avd "Pixel_Test"
  @adb_prefix ["-P", "15037", "-s", "emulator-5600"]
  @adb_env [{~c"ANDROID_ADB_SERVER_PORT", ~c"15037"}]

  setup do
    root = Path.join(System.tmp_dir!(), "qa-android-emulator-#{System.unique_integer([:positive])}")
    sdk = Path.join(root, "sdk")
    File.mkdir_p!(Path.join(sdk, "emulator"))
    File.mkdir_p!(Path.join(sdk, "platform-tools"))
    File.write!(Path.join([sdk, "emulator", "emulator"]), "")
    File.write!(Path.join([sdk, "platform-tools", "adb"]), "")
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, sdk: sdk, pid_file: Path.join([root, "state", "qa-android", "emulator-processes.json"])}
  end

  defp android(sdk, attrs \\ []) do
    Map.merge(%{avd: @avd, sdk_root: sdk, boot_timeout_ms: 1_000, idle_timeout_ms: 60_000}, Map.new(attrs))
  end

  defp start_emulator(ctx, opts \\ []) do
    test = self()
    responder = Keyword.get(opts, :responder, &respond/2)
    table = Keyword.get(opts, :table, fn -> {:ok, []} end)

    defaults = [
      name: nil,
      android: fn -> android(ctx.sdk) end,
      cmd: fn executable, args, cmd_opts ->
        send(test, {:cmd, executable, args, cmd_opts})
        responder.(Path.basename(executable), args)
      end,
      launch: fn executable, args, env ->
        port = make_ref()
        send(test, {:launch, executable, args, env, port})
        {:ok, port, 4242}
      end,
      table: table,
      signal: fn pid, signal -> send(test, {:signal, pid, signal}) end,
      clock: fn -> 0 end,
      sleep: fn _ms -> :ok end,
      send_after: fn pid, message, ms ->
        send(test, {:timer, pid, message, ms})
        make_ref()
      end,
      grace_ms: 0,
      pid_file: ctx.pid_file
    ]

    start_supervised!({Emulator, Keyword.merge(defaults, Keyword.drop(opts, [:responder, :id]))}, id: Keyword.get_lazy(opts, :id, &make_ref/0))
  end

  defp respond("emulator", ["-list-avds"]), do: {:ok, {"INFO | something\n#{@avd}\nOther_AVD\n", 0}}
  defp respond("adb", [_, _, _, _, "shell", "getprop", "sys.boot_completed"]), do: {:ok, {"1\n", 0}}
  defp respond("adb", _args), do: {:ok, {"", 0}}

  # Blocks the boot check until the test sends `{:reply, result}` to the process it reports.
  defp blocking_getprop do
    test = self()

    fn
      "adb", [_, _, _, _, "shell" | _] ->
        send(test, {:getprop, self()})

        receive do
          {:reply, result} -> result
        end

      executable, args ->
        respond(executable, args)
    end
  end

  # A process that takes the emulator, reports the result, then checks it back in
  # on `:checkin` or exits on `:crash`.
  defp spawn_holder(server, opts \\ []) do
    test = self()

    spawn(fn ->
      result = Emulator.checkout(server, opts)
      send(test, {:checkout, self(), result})

      receive do
        :checkin -> send(test, {:checkin, self(), Emulator.checkin(server, elem(result, 1))})
        :crash -> exit(:crash)
      end
    end)
  end

  defp await_state(server, fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.(:sys.get_state(server)) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("emulator manager state never matched: #{inspect(:sys.get_state(server))}")

      true ->
        Process.sleep(5)
        await_state(server, fun, deadline)
    end
  end

  defp entry(pid, ppid, start_time, command) do
    %{pid: pid, ppid: ppid, start_time: start_time, cpu_time: "0:01.00", command: command, cwd: nil}
  end

  defp emulator_processes do
    [
      entry(4242, 1, "Sun Oct  4 10:00:00 2026", "/sdk/emulator/emulator -avd #{@avd} -port 5600"),
      entry(4243, 4242, "Sun Oct  4 10:00:01 2026", "/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd #{@avd}"),
      entry(4250, 1, "Sun Oct  4 09:59:59 2026", "adb -L tcp:15037 fork-server server --reply-fd 4"),
      entry(4260, 1, "Sun Oct  4 08:00:00 2026", "adb -L tcp:5037 fork-server server --reply-fd 4"),
      entry(999, 1, "Sun Oct  4 08:00:00 2026", "/Applications/Android Studio.app/Contents/MacOS/studio")
    ]
  end

  defp stopped_signals do
    receive do
      {:signal, pid, signal} -> [{pid, signal} | stopped_signals()]
    after
      0 -> []
    end
  end

  defp launches do
    receive do
      {:launch, _executable, _args, _env, _port} -> 1 + launches()
    after
      0 -> 0
    end
  end

  defp adb_commands do
    receive do
      {:cmd, executable, args, opts} ->
        if Path.basename(executable) == "adb", do: [{args, opts} | adb_commands()], else: adb_commands()
    after
      0 -> []
    end
  end

  describe "leases" do
    test "two concurrent leases share one emulator; the second waits for the first", ctx do
      server = start_emulator(ctx)

      first = spawn_holder(server)
      assert_receive {:checkout, ^first, {:ok, lease}}
      assert lease.serial == "emulator-5600"
      assert lease.adb_server_port == 15_037
      assert lease.adb == Path.join([ctx.sdk, "platform-tools", "adb"])

      second = spawn_holder(server, wait_ms: 5_000)
      assert_receive {:timer, ^server, {:wait_timeout, _token}, 5_000}
      refute_received {:checkout, ^second, _result}

      send(first, :checkin)
      assert_receive {:checkin, ^first, :ok}
      assert_receive {:checkout, ^second, {:ok, second_lease}}
      assert second_lease.serial == lease.serial
      assert second_lease.lease != lease.lease
      assert launches() == 1
    end

    test "a holder that checks out again keeps its lease", ctx do
      server = start_emulator(ctx)

      assert {:ok, lease} = Emulator.checkout(server)
      assert {:ok, ^lease} = Emulator.checkout(server)
      assert launches() == 1
    end

    test "a waiter gets a clear error when its wait runs out, and a stale timeout is ignored", ctx do
      server = start_emulator(ctx)
      assert {:ok, _lease} = Emulator.checkout(server)

      waiter = Task.async(fn -> Emulator.checkout(server, wait_ms: 100) end)
      assert_receive {:timer, ^server, {:wait_timeout, _token} = timeout, 100}
      send(server, timeout)

      assert Task.await(waiter) == {:error, {:lease_timeout, 100}}
      assert Emulator.error_message({:lease_timeout, 100}) =~ "only one emulator runs at a time"

      send(server, timeout)
      assert :sys.get_state(server).waiters == []
    end

    test "a waiter that exits leaves the queue", ctx do
      server = start_emulator(ctx)
      holder = spawn_holder(server)
      assert_receive {:checkout, ^holder, {:ok, _lease}}

      waiter = spawn(fn -> Emulator.checkout(server) end)
      assert_receive {:timer, ^server, {:wait_timeout, _token}, 1_800_000}
      Process.exit(waiter, :kill)
      # The manager drops the waiter on its :DOWN, which nothing orders before the holder's checkin.
      await_state(server, &(&1.waiters == []))

      send(holder, :checkin)
      assert_receive {:checkin, ^holder, :ok}
      assert :sys.get_state(server).holder == nil
    end

    test "checking in a lease that is not held changes nothing", ctx do
      server = start_emulator(ctx)
      assert {:ok, lease} = Emulator.checkout(server)

      assert :ok = Emulator.checkin(server, %{lease: make_ref()})
      assert :sys.get_state(server).holder.lease == lease.lease

      assert :ok = Emulator.checkin(server, lease)
      assert :ok = Emulator.checkin(server, lease)
    end

    test "checkout and checkin without a running manager" do
      assert Emulator.checkout(:no_such_qa_android_emulator) == {:error, :emulator_unavailable}
      assert Emulator.checkin(:no_such_qa_android_emulator, %{lease: make_ref()}) == :ok
      # Symphony's own manager, when it runs, ignores a lease it never gave.
      assert Emulator.checkin(%{lease: make_ref()}) == :ok
      assert Emulator.error_message(:emulator_unavailable) =~ "not running"
    end
  end

  describe "start" do
    test "boots the AVD headless and read-only, isolated on a private adb server", ctx do
      server = start_emulator(ctx)
      assert {:ok, lease} = Emulator.checkout(server)

      emulator = Path.join([ctx.sdk, "emulator", "emulator"])
      sdk_root = String.to_charlist(ctx.sdk)
      assert_received {:cmd, ^emulator, ["-list-avds"], list_opts}
      assert list_opts[:env] == [{~c"ANDROID_ADB_SERVER_PORT", ~c"15037"}, {~c"ANDROID_HOME", sdk_root}, {~c"ANDROID_SDK_ROOT", sdk_root}]

      assert_received {:launch, ^emulator, args, env, _port}
      assert args == ~w(-avd Pixel_Test -port 5600 -no-window -no-audio -no-boot-anim -read-only -no-snapshot-save)
      assert env == list_opts[:env]

      assert :ok = Emulator.checkin(server, lease)
      assert_receive {:timer, ^server, {:idle_timeout, _token} = idle, 60_000}
      send(server, idle)
      :sys.get_state(server)

      commands = adb_commands()
      assert Enum.map(commands, fn {args, _opts} -> Enum.drop(args, 4) end) == [["start-server"], ~w(shell getprop sys.boot_completed), ~w(emu kill), ["kill-server"]]

      for {args, opts} <- commands do
        assert Enum.take(args, 4) == @adb_prefix
        assert opts[:env] == @adb_env
      end

      assert Emulator.adb_command(lease, ["install", "app.apk"]) == {lease.adb, @adb_prefix ++ ["install", "app.apk"], @adb_env}
    end

    test "uses the configured ports", ctx do
      server = start_emulator(ctx, console_port: 5570, adb_server_port: 25_037)
      assert {:ok, %{serial: "emulator-5570", adb_server_port: 25_037}} = Emulator.checkout(server)
      assert_received {:launch, _emulator, ["-avd", @avd, "-port", "5570" | _flags], _env, _port}
      assert [{["-P", "25037", "-s", "emulator-5570", "start-server"], _opts} | _rest] = adb_commands()
    end

    test "an unset AVD, a missing SDK tool and a missing AVD are distinct errors", ctx do
      capture_log(fn ->
        unset = start_emulator(ctx, android: fn -> android(ctx.sdk, avd: nil) end)
        assert Emulator.checkout(unset) == {:error, :avd_not_configured}

        no_sdk = start_emulator(ctx, android: fn -> android(Path.join(ctx.root, "none")) end)
        missing_emulator = Path.join([ctx.root, "none", "emulator", "emulator"])
        assert Emulator.checkout(no_sdk) == {:error, {:sdk_missing, missing_emulator}}

        File.rm!(Path.join([ctx.sdk, "platform-tools", "adb"]))
        no_adb = start_emulator(ctx)
        assert Emulator.checkout(no_adb) == {:error, {:sdk_missing, Path.join([ctx.sdk, "platform-tools", "adb"])}}
      end)

      refute_received {:launch, _executable, _args, _env, _port}

      assert Emulator.error_message(:avd_not_configured) =~ "auto_review.android.avd is not set"
      assert Emulator.error_message({:sdk_missing, "/sdk/platform-tools/adb"}) =~ "/sdk/platform-tools/adb is missing"
    end

    test "an AVD the emulator does not list is a missing AVD", ctx do
      server = start_emulator(ctx, responder: fn "emulator", ["-list-avds"] -> {:ok, {"Other_AVD\n", 0}} end)

      log = capture_log(fn -> assert Emulator.checkout(server) == {:error, {:avd_missing, @avd}} end)
      assert log =~ "Android emulator unavailable qa_android_emulator reason={:avd_missing, \"Pixel_Test\"}"
      assert Emulator.error_message({:avd_missing, @avd}) =~ "The AVD Pixel_Test does not exist"
    end

    test "a failing emulator or adb start is a start failure", ctx do
      list_fails = start_emulator(ctx, responder: fn "emulator", ["-list-avds"] -> {:ok, {"crash\n", 1}} end)

      adb_fails =
        start_emulator(ctx,
          responder: fn
            "adb", _args -> {:error, :timeout}
            executable, args -> respond(executable, args)
          end
        )

      capture_log(fn ->
        assert Emulator.checkout(list_fails) == {:error, {:start_failed, "emulator -list-avds failed: exit status 1: crash"}}
        assert {:error, {:start_failed, "adb start-server failed: :timeout"} = reason} = Emulator.checkout(adb_fails)
        assert Emulator.error_message(reason) == "The emulator could not start: adb start-server failed: :timeout"
      end)

      refute_received {:launch, _executable, _args, _env, _port}
    end

    test "a launch failure stops Symphony's adb server", ctx do
      server = start_emulator(ctx, launch: fn _executable, _args, _env -> {:error, "eacces"} end)

      capture_log(fn ->
        assert Emulator.checkout(server) == {:error, {:start_failed, "the emulator could not be launched: \"eacces\""}}
      end)

      assert Enum.map(adb_commands(), fn {args, _opts} -> Enum.drop(args, 4) end) == [["start-server"], ["kill-server"]]
      assert stopped_signals() == []
    end

    test "a boot timeout stops the emulator", ctx do
      clock = :counters.new(1, [])

      server =
        start_emulator(ctx,
          clock: fn ->
            :counters.add(clock, 1, 600)
            :counters.get(clock, 1)
          end,
          responder: fn
            "adb", [_, _, _, _, "shell" | _] -> {:ok, {"0\n", 0}}
            executable, args -> respond(executable, args)
          end
        )

      capture_log(fn -> assert Emulator.checkout(server) == {:error, {:boot_timeout, 1_000}} end)

      assert Enum.map(adb_commands(), fn {args, _opts} -> Enum.drop(args, 4) end) ==
               [["start-server"]] ++ List.duplicate(~w(shell getprop sys.boot_completed), 2) ++ [~w(emu kill), ["kill-server"]]

      assert stopped_signals() == [{4242, "KILL"}]
      assert :sys.get_state(server).status == :down
      assert Emulator.error_message({:boot_timeout, 1_000}) =~ "within 1000 ms"
    end

    test "an adb error while booting is not booted yet", ctx do
      calls = :counters.new(1, [])

      server =
        start_emulator(ctx,
          responder: fn
            "adb", [_, _, _, _, "shell" | _] ->
              :counters.add(calls, 1, 1)
              if :counters.get(calls, 1) == 1, do: {:ok, {"error: device offline", 1}}, else: {:ok, {"1", 0}}

            executable, args ->
              respond(executable, args)
          end
        )

      assert {:ok, _lease} = Emulator.checkout(server)
      assert :counters.get(calls, 1) == 2
    end

    test "a failed boot answers the holder; the next waiter boots a new emulator", ctx do
      server = start_emulator(ctx, responder: blocking_getprop())

      first = spawn_holder(server)
      assert_receive {:getprop, booter}
      second = spawn_holder(server)
      assert_receive {:timer, ^server, {:wait_timeout, _token}, _ms}

      capture_log(fn ->
        assert_receive {:launch, _executable, _args, _env, port}
        send(server, {port, {:data, String.duplicate("x", 5_000)}})
        send(server, {port, {:exit_status, 1}})
        assert_receive {:checkout, ^first, {:error, {:emulator_exited, 1}}}
      end)

      refute Process.alive?(booter)
      assert_receive {:launch, _executable, _args, _env, _port}
      assert_receive {:getprop, booter}
      send(booter, {:reply, {:ok, {"1", 0}}})
      assert_receive {:checkout, ^second, {:ok, _lease}}
      assert Emulator.error_message({:emulator_exited, 1}) =~ "exited with status 1"
    end

    test "a crashed boot check is a start failure", ctx do
      server =
        start_emulator(ctx,
          responder: fn
            "adb", [_, _, _, _, "shell" | _] -> raise "adb vanished"
            executable, args -> respond(executable, args)
          end
        )

      capture_log(fn ->
        assert {:error, {:start_failed, "the boot check crashed: " <> reason}} = Emulator.checkout(server)
        assert reason =~ "adb vanished"
      end)

      assert :sys.get_state(server).status == :down
    end

    test "a waiter promoted while the emulator boots gets it once it is up", ctx do
      server = start_emulator(ctx, responder: blocking_getprop())

      first = spawn_holder(server)
      assert_receive {:getprop, booter}
      second = spawn_holder(server)
      assert_receive {:timer, ^server, {:wait_timeout, _token}, _ms}

      capture_log(fn ->
        Process.exit(first, :kill)
        :sys.get_state(server)
      end)

      send(booter, {:reply, {:ok, {"1", 0}}})
      assert_receive {:checkout, ^second, {:ok, _lease}}
      assert launches() == 1
    end

    test "an emulator that boots after its holder exited waits idle", ctx do
      server = start_emulator(ctx, responder: blocking_getprop())

      holder = spawn_holder(server)
      assert_receive {:getprop, booter}
      capture_log(fn -> Process.exit(holder, :kill) end)
      assert_receive {:timer, ^server, {:idle_timeout, _token} = idle, 60_000}

      # The boot check has sent its result once it exits.
      booter_monitor = Process.monitor(booter)
      send(booter, {:reply, {:ok, {"1", 0}}})
      assert_receive {:DOWN, ^booter_monitor, :process, ^booter, :normal}
      assert %{status: :up, holder: nil} = :sys.get_state(server)

      capture_log(fn -> send(server, idle) end)
      assert %{status: :down} = :sys.get_state(server)
    end
  end

  describe "stop" do
    test "stops the emulator after the idle timeout, and not while it is leased again", ctx do
      server = start_emulator(ctx, table: fn -> {:ok, emulator_processes()} end)
      assert {:ok, lease} = Emulator.checkout(server)
      assert :ok = Emulator.checkin(server, lease)
      assert_receive {:timer, ^server, {:idle_timeout, _token} = stale, 60_000}

      assert {:ok, lease} = Emulator.checkout(server)
      send(server, stale)
      assert %{status: :up} = :sys.get_state(server)

      assert :ok = Emulator.checkin(server, lease)
      assert_receive {:timer, ^server, {:idle_timeout, _token} = idle, 60_000}

      log = capture_log(fn -> send(server, idle) && :sys.get_state(server) end)
      assert log =~ "Stopping the idle Android emulator"
      assert Enum.sort(stopped_signals()) == [{4242, "KILL"}, {4242, "TERM"}, {4243, "KILL"}, {4243, "TERM"}, {4250, "KILL"}, {4250, "TERM"}]
      refute File.exists?(ctx.pid_file)
      assert %{status: :down, processes: []} = :sys.get_state(server)

      assert {:ok, _lease} = Emulator.checkout(server)
      assert launches() == 2
    end

    test "stops the emulator after a lease holder crashes and the idle timeout passes", ctx do
      server = start_emulator(ctx)
      holder = spawn_holder(server)
      assert_receive {:checkout, ^holder, {:ok, _lease}}

      capture_log(fn ->
        send(holder, :crash)
        assert_receive {:timer, ^server, {:idle_timeout, _token} = idle, 60_000}
        send(server, idle)
        assert %{status: :down, holder: nil} = :sys.get_state(server)
      end)

      assert [_start_server, _getprop, {["-P", "15037", "-s", "emulator-5600", "emu", "kill"], _opts}, _kill_server] = adb_commands()
      assert stopped_signals() == [{4242, "KILL"}]
    end

    test "stops the emulator when Symphony's supervisor stops the manager", ctx do
      server = start_emulator(ctx, table: fn -> {:ok, emulator_processes()} end, id: :emulator)
      assert {:ok, _lease} = Emulator.checkout(server)

      capture_log(fn -> stop_supervised!(:emulator) end)

      assert [_start_server, _getprop, {emu_kill, _}, {kill_server, _}] = adb_commands()
      assert Enum.drop(emu_kill, 4) == ~w(emu kill)
      assert Enum.drop(kill_server, 4) == ["kill-server"]
      assert {4242, "TERM"} in stopped_signals()
      refute File.exists?(ctx.pid_file)
    end

    test "stops nothing when no emulator ever started", ctx do
      start_emulator(ctx, id: :emulator)
      stop_supervised!(:emulator)
      assert adb_commands() == []
      assert stopped_signals() == []
    end

    test "marks a crashed emulator down; its holder's next checkout boots a new one", ctx do
      server = start_emulator(ctx)
      assert {:ok, _lease} = Emulator.checkout(server)
      assert_received {:launch, _executable, _args, _env, port}

      log = capture_log(fn -> send(server, {port, {:exit_status, 139}}) && :sys.get_state(server) end)
      assert log =~ "Android emulator exited qa_android_emulator status=139"
      assert %{status: :down, holder: %{}} = :sys.get_state(server)
      assert [_start_server, _getprop, {kill_server, _opts}] = adb_commands()
      assert Enum.drop(kill_server, 4) == ["kill-server"]

      assert {:ok, _lease} = Emulator.checkout(server)
      assert launches() == 1
    end

    test "a checkin that hands a crashed emulator to a waiter returns before the new boot", ctx do
      test = self()
      {:ok, avd_lists} = Agent.start_link(fn -> 0 end)

      # The second `-list-avds`, the waiter's preflight, blocks until the test answers.
      responder = fn
        "emulator", ["-list-avds"] = args ->
          if Agent.get_and_update(avd_lists, &{&1, &1 + 1}) > 0 do
            send(test, {:preflight, self()})

            receive do
              :continue -> respond("emulator", args)
            end
          else
            respond("emulator", args)
          end

        executable, args ->
          respond(executable, args)
      end

      server = start_emulator(ctx, responder: responder)
      holder = spawn_holder(server)
      assert_receive {:checkout, ^holder, {:ok, _lease}}
      assert_received {:launch, _executable, _args, _env, port}
      waiter = spawn_holder(server)
      assert_receive {:timer, ^server, {:wait_timeout, _token}, _wait_ms}

      capture_log(fn -> send(server, {port, {:exit_status, 139}}) && :sys.get_state(server) end)
      send(holder, :checkin)
      assert_receive {:preflight, preflight}
      assert_receive {:checkin, ^holder, :ok}
      refute_received {:checkout, ^waiter, _result}

      send(preflight, :continue)
      assert_receive {:checkout, ^waiter, {:ok, _lease}}
      assert launches() == 1
    end

    test "ignores messages from a port it no longer runs", ctx do
      server = start_emulator(ctx)
      send(server, {make_ref(), {:exit_status, 0}})
      send(server, :unexpected)
      assert %{status: :down} = :sys.get_state(server)
    end
  end

  describe "process records" do
    test "records the emulator, its children and Symphony's adb server", ctx do
      server = start_emulator(ctx, table: fn -> {:ok, emulator_processes()} end)
      assert {:ok, _lease} = Emulator.checkout(server)

      assert ctx.pid_file |> File.read!() |> Jason.decode!() |> Enum.map(& &1["pid"]) == [4242, 4243, 4250]
      assert %{"start_time" => "Sun Oct  4 10:00:00 2026", "command" => "/sdk/emulator/emulator" <> _} = ctx.pid_file |> File.read!() |> Jason.decode!() |> hd()
    end

    test "stops exactly the recorded processes a crashed Symphony left running", ctx do
      File.mkdir_p!(Path.dirname(ctx.pid_file))

      File.write!(
        ctx.pid_file,
        Jason.encode!([
          %{pid: 4242, start_time: "Sun Oct  4 10:00:00 2026", command: "/sdk/emulator/emulator"},
          %{pid: 4243, start_time: "Sun Oct  4 10:00:01 2026"},
          %{pid: 4250, start_time: "Sat Oct  3 07:00:00 2026", command: "adb -L tcp:15037 fork-server server"},
          %{pid: 7777, start_time: "Sun Oct  4 10:00:00 2026", command: "gone"},
          %{pid: "bad", start_time: 1}
        ])
      )

      log =
        capture_log(fn ->
          server = start_emulator(ctx, table: fn -> {:ok, emulator_processes()} end)
          :sys.get_state(server)
        end)

      assert log =~ "Stopping Android emulator processes a previous Symphony left running qa_android_emulator pids=4242,4243,4250,7777"
      assert Enum.sort(stopped_signals()) == [{4242, "KILL"}, {4242, "TERM"}, {4243, "KILL"}, {4243, "TERM"}]
      refute File.exists?(ctx.pid_file)
    end

    test "an unreadable record stops nothing", ctx do
      File.mkdir_p!(Path.dirname(ctx.pid_file))

      for content <- ["not json", ~s({"pid": 4242})] do
        File.write!(ctx.pid_file, content)
        server = start_emulator(ctx, table: fn -> {:ok, emulator_processes()} end, id: :emulator)
        :sys.get_state(server)
        refute File.exists?(ctx.pid_file)
        stop_supervised!(:emulator)
      end

      assert stopped_signals() == []
    end

    test "boots without records when the process table can't be read or the record can't be written", ctx do
      File.write!(Path.join(ctx.root, "state"), "a file, not a folder")
      server = start_emulator(ctx, table: fn -> {:error, :denied} end)

      log = capture_log(fn -> assert {:ok, _lease} = Emulator.checkout(server) end)
      assert log =~ "Could not read the process table to record the Android emulator qa_android_emulator: :denied"
      assert :sys.get_state(server).processes == []

      blocked = start_emulator(ctx, table: fn -> {:ok, emulator_processes()} end)
      log = capture_log(fn -> assert {:ok, _lease} = Emulator.checkout(blocked) end)
      assert log =~ "Could not record the Android emulator processes qa_android_emulator path=#{ctx.pid_file}"
    end
  end

  describe "defaults" do
    test "reads auto_review.android from the config", ctx do
      defaults = start_supervised!({Emulator, name: nil, pid_file: ctx.pid_file}, id: :defaults)
      capture_log(fn -> assert Emulator.checkout(defaults) == {:error, :avd_not_configured} end)
    end

    test "launch/3 reports an executable it cannot start" do
      assert {:error, message} = Emulator.launch("/nonexistent/emulator", [], [])
      assert is_binary(message)
    end

    test "runs a fake SDK with the real runner, launcher and signal, and stops what it launched", ctx do
      write_script!(Path.join([ctx.sdk, "emulator", "emulator"]), """
      #!/bin/sh
      if [ "$1" = "-list-avds" ]; then echo #{@avd}; exit 0; fi
      exec sleep 600
      """)

      write_script!(Path.join([ctx.sdk, "platform-tools", "adb"]), """
      #!/bin/sh
      echo "$*" >> "#{ctx.root}/adb.log"
      case "$*" in *sys.boot_completed*) echo 1 ;; esac
      """)

      server = start_supervised!({Emulator, name: nil, android: fn -> android(ctx.sdk) end, grace_ms: 0}, id: :fake_sdk)
      assert {:ok, lease} = Emulator.checkout(server)
      %{emulator: %{os_pid: os_pid}} = :sys.get_state(server)

      capture_log(fn -> stop_supervised!(:fake_sdk) end)

      assert gone?(os_pid, 50)

      assert File.read!(Path.join(ctx.root, "adb.log")) ==
               Enum.map_join([["start-server"], ~w(shell getprop sys.boot_completed), ~w(emu kill), ["kill-server"]], fn args ->
                 Enum.join(Emulator.adb_command(lease, args) |> elem(1), " ") <> "\n"
               end)
    end
  end

  # The port's helper reaps the killed process soon after, until then it is a zombie.
  defp gone?(_os_pid, 0), do: false

  defp gone?(os_pid, tries) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} ->
        Process.sleep(100)
        gone?(os_pid, tries - 1)

      _gone ->
        true
    end
  end

  defp write_script!(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end
end
