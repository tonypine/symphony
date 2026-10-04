defmodule SymphonyElixir.QaAndroid.DriverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Paths, PathSafety}
  alias SymphonyElixir.QaAndroid.Driver

  @apk "app/build/outputs/apk/debug/app-debug.apk"
  @app_id "com.example.app"
  @adb "/sdk/platform-tools/adb"
  @adb_prefix ["-P", "15037", "-s", "emulator-5600"]
  @build "./gradlew :app:assembleDebug"
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "image">>
  @dump File.read!(Path.expand("../../fixtures/qa_android/uiautomator_dump.txt", __DIR__))
  @dump_args ["exec-out", "uiautomator", "dump", "/dev/tty"]
  @display_args ["shell", "dumpsys", "window", "displays"]

  setup do
    File.mkdir_p!(System.tmp_dir!())
    {:ok, tmp} = PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "qa-android-driver-test-#{System.unique_integer([:positive])}")
    worktree = Path.join(root, "worktree")
    File.mkdir_p!(Path.join(worktree, Path.dirname(@apk)))
    File.write!(Path.join(worktree, @apk), "apk-bytes")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, worktree: worktree}
  end

  # A fake emulator: the device's third-party packages (ID to code path) live in
  # an Agent, starting with `initial`, and the APK installs `apk_package` at a
  # new code path. Every adb call reaches the test as `{:adb, args, opts}`, and
  # every command as `{:cmd, executable, args}`. `replies` overrides a command
  # (keyed as in `command/1`) with a result, a `fn args -> result end` or a
  # `fn args, packages -> result end`.
  defp device(replies \\ %{}, apk_package \\ @app_id, initial \\ %{}) do
    test = self()
    {:ok, packages} = Agent.start_link(fn -> initial end)

    fn executable, args, opts ->
      send(test, {:cmd, executable, args})
      {@adb_prefix, adb_args} = Enum.split(args, 4)
      send(test, {:adb, adb_args, opts})

      case Map.fetch(replies, command(adb_args)) do
        {:ok, reply} when is_function(reply, 1) -> reply.(adb_args)
        {:ok, reply} when is_function(reply, 2) -> reply.(adb_args, packages)
        {:ok, reply} -> reply
        :error -> default_reply(adb_args, packages, apk_package)
      end
    end
  end

  defp command(["uninstall" | _rest]), do: :uninstall
  defp command(["install" | _rest]), do: :install
  defp command(["shell", "pm", "list" | _rest]), do: :pm_list
  defp command(["shell", "cmd", "package", "resolve-activity" | _rest]), do: :resolve
  defp command(["shell", "am", "start" | _rest]), do: :am_start
  defp command(["shell", "am", "force-stop" | _rest]), do: :force_stop
  defp command(["shell", "pidof" | _rest]), do: :pidof
  defp command(["shell", "dumpsys", "window" | _rest]), do: :display
  defp command(["shell", "dumpsys" | _rest]), do: :dumpsys
  defp command(["shell", "input" | _rest]), do: :input
  defp command(["shell", "settings" | _rest]), do: :settings
  defp command(["shell", "cmd", "uimode" | _rest]), do: :uimode
  defp command(["shell", "cmd", "window", "user-rotation" | _rest]), do: :user_rotation
  defp command(["exec-out", "uiautomator" | _rest]), do: :ui_dump
  defp command(["exec-out" | _rest]), do: :screencap
  defp command(["logcat" | _rest]), do: :logcat

  defp default_reply(["uninstall", id], packages, _apk_package) do
    Agent.update(packages, &Map.delete(&1, id))
    {:ok, {"Success\n", 0}}
  end

  defp default_reply(["install", "-r", path], packages, apk_package) do
    "apk-bytes" = File.read!(path)
    Agent.update(packages, &Map.put(&1, apk_package, code_path(apk_package)))
    {:ok, {"Performing Streamed Install\nSuccess\n", 0}}
  end

  defp default_reply(["shell", "pm", "list", "packages", "-3", "-f"], packages, _apk_package) do
    {:ok, {packages |> Agent.get(& &1) |> Enum.map_join(fn {id, path} -> "package:#{path}=#{id}\n" end), 0}}
  end

  defp default_reply(["shell", "cmd", "package", "resolve-activity" | _rest], _packages, _apk_package),
    do: {:ok, {"priority=0 preferredOrder=0\n#{@app_id}/.MainActivity\n", 0}}

  defp default_reply(["shell", "am", "start" | _rest], _packages, _apk_package),
    do: {:ok, {"Starting: Intent { cmp=#{@app_id}/.MainActivity }\nStatus: ok\nLaunchState: COLD\n", 0}}

  defp default_reply(["shell", "pidof", _id], _packages, _apk_package), do: {:ok, {"4242\n", 0}}

  defp default_reply(["shell", "dumpsys", "window", "displays"], _packages, _apk_package),
    do: {:ok, {"Display: mDisplayId=0\n  init=1080x2400 420dpi base=1080x2400 420dpi cur=1080x2400 app=1080x2337 rng=1080x1017-2337x2337\n", 0}}

  defp default_reply(["shell", "dumpsys" | _rest], _packages, _apk_package),
    do: {:ok, {"  mResumedActivity: ActivityRecord{1f u0 #{@app_id}/.MainActivity t7}\n", 0}}

  defp default_reply(["exec-out", "screencap", "-p"], _packages, _apk_package), do: {:ok, {@png, 0}}
  defp default_reply(["exec-out", "uiautomator", "dump", "/dev/tty"], _packages, _apk_package), do: {:ok, {@dump, 0}}
  defp default_reply(["logcat" | _rest], _packages, _apk_package), do: {:ok, {"E AndroidRuntime: FATAL EXCEPTION: main\n", 0}}
  defp default_reply(_args, _packages, _apk_package), do: {:ok, {"", 0}}

  defp code_path(id), do: "/data/app/~~#{System.unique_integer([:positive])}==/#{id}-1/base.apk"

  # Replies with each of `replies` in turn, then as the device does; `:device`
  # replies as the device does.
  defp replies_in_turn(replies) do
    {:ok, pending} = Agent.start_link(fn -> replies end)

    fn args, packages ->
      case Agent.get_and_update(pending, &Enum.split(&1, 1)) do
        [reply] when reply != :device -> reply
        _device -> default_reply(args, packages, @app_id)
      end
    end
  end

  defp lease, do: %{lease: make_ref(), serial: "emulator-5600", adb: @adb, adb_server_port: 15_037}

  defp clean_git(_args, _cwd), do: {"", 0}

  # `nil` drops an option, so the driver uses its default.
  defp driver_opts(worktree, opts \\ []) do
    test = self()
    playbook = Map.merge(%{kind: "android_app", build: @build, apk_path: @apk, application_ids: [@app_id]}, Keyword.get(opts, :playbook, %{}))

    [
      worktree: worktree,
      playbook: playbook,
      git: &clean_git/2,
      cmd: device(),
      checkout: fn ->
        lease = lease()
        send(test, {:checked_out, lease})
        {:ok, lease}
      end,
      checkin: fn lease -> send(test, {:checked_in, lease}) && :ok end,
      sleep: fn ms -> send(test, {:slept, ms}) end
    ]
    |> Keyword.merge(Keyword.drop(opts, [:playbook]))
    |> Enum.reject(fn {_key, value} -> value == nil end)
  end

  defp start_driver(worktree, opts \\ []) do
    {:ok, driver} = Driver.start_link(driver_opts(worktree, opts))
    on_exit(fn -> Driver.stop(driver) end)
    driver
  end

  defp call(driver, tool, args \\ %{}) do
    {result, _log} = with_log(fn -> Driver.call_tool(driver, tool, args) end)
    result
  end

  defp installed_driver(worktree, opts \\ []) do
    driver = start_driver(worktree, opts)
    assert {:ok, %{"installed" => [@app_id]}} = call(driver, "qa_android_install")
    driver
  end

  defp error_code({:error, {:qa_tool, code, _message}}), do: code

  defp adb_calls do
    receive do
      {:adb, args, _opts} -> [args | adb_calls()]
    after
      0 -> []
    end
  end

  describe "tools" do
    test "lists the qa_android tools and needs a driver" do
      assert Driver.tools() ==
               ~w(qa_android_install qa_android_launch qa_android_stop qa_android_screenshot qa_android_ui_tree qa_android_tap qa_android_type qa_android_key qa_android_rotate qa_android_dark_mode qa_android_font_scale)

      assert error_code(Driver.call_tool(nil, "qa_android_install", %{})) == "qa_android_driver_unavailable"
      assert {:error, {:qa_tool, _code, message}} = Driver.call_tool(nil, "qa_android_install", %{})
      assert message =~ "Do not start an emulator or adb yourself"
      assert message =~ ~s(`blocked` with "no Android QA playbook configured for this repo")
      assert Driver.stop(nil) == :ok
    end

    test "installs, launches, stops and captures through adb only, then cleans up", %{worktree: worktree} do
      driver = installed_driver(worktree)
      assert_received {:checked_out, lease}

      %{scratch_dir: scratch_dir} = GenServer.call(driver, :config)
      {:ok, state_root} = PathSafety.canonicalize(Paths.state_root())
      assert String.starts_with?(scratch_dir, Path.join(state_root, "qa-android/runs") <> "/")
      assert File.stat!(scratch_dir).mode |> Bitwise.band(0o777) == 0o700

      # The device's packages are listed once as the baseline, the configured app
      # is wiped before the install, and the install runs from a private copy.
      list = ["shell", "pm", "list", "packages", "-3", "-f"]
      assert [^list, ^list, ["uninstall", @app_id], ["install", "-r", copy], ^list] = adb_calls()

      assert String.starts_with?(copy, scratch_dir <> "/")
      refute File.exists?(copy)

      assert {:ok, %{"application_id" => @app_id, "activity" => "com.example.app/.MainActivity", "pid" => 4242}} =
               call(driver, "qa_android_launch", %{"application_id" => @app_id})

      assert [
               ["shell", "cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", @app_id],
               ["shell", "am", "start", "-W", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", "-n", "com.example.app/.MainActivity"],
               ["shell", "pidof", @app_id],
               ["shell", "dumpsys", "activity", "activities"]
             ] = adb_calls()

      assert {:ok, %{"application_id" => @app_id, "stopped" => true}} = call(driver, "qa_android_stop", %{"application_id" => @app_id})
      assert_received {:adb, ["shell", "am", "force-stop", @app_id], _opts}

      assert {:ok, %{"path" => "qa-evidence/home.png"}} = call(driver, "qa_android_screenshot", %{"name" => "home.png"})
      assert File.read!(Path.join(worktree, "qa-evidence/home.png")) == @png
      assert_received {:adb, ["exec-out", "screencap", "-p"], screencap_opts}
      assert screencap_opts[:env] == [{~c"ANDROID_ADB_SERVER_PORT", ~c"15037"}]

      assert Driver.stop(driver) == :ok
      assert_received {:adb, ["uninstall", @app_id], _opts}
      assert_received {:checked_in, ^lease}
      refute File.exists?(scratch_dir)

      # The host never runs the build, Gradle or anything else from the repository.
      commands = collect_commands()
      assert commands != []
      assert Enum.all?(commands, fn {executable, args} -> executable == @adb and Enum.take(args, 4) == @adb_prefix end)
      refute Enum.any?(commands, fn {_executable, args} -> Enum.any?(args, &(&1 =~ "gradle")) end)
    end

    test "cleans up when the QA pass crashes", %{worktree: worktree} do
      test = self()
      opts = driver_opts(worktree)

      owner =
        spawn(fn ->
          {:ok, driver} = Driver.start_link(opts)
          {:ok, _result} = Driver.call_tool(driver, "qa_android_install", %{})
          send(test, {:driver, driver, GenServer.call(driver, :config).scratch_dir})
          Process.sleep(:infinity)
        end)

      assert_receive {:driver, driver, scratch_dir}, 5_000
      assert_receive {:checked_out, lease}
      monitor = Process.monitor(driver)

      capture_log(fn ->
        Process.exit(owner, :boom)
        assert_receive {:DOWN, ^monitor, :process, ^driver, :boom}, 5_000
      end)

      assert_received {:checked_in, ^lease}
      assert ["uninstall", @app_id] in adb_calls()
      refute File.exists?(scratch_dir)
    end

    test "an emulator that cannot run makes every tool ask for blocked", %{worktree: worktree} do
      driver = start_driver(worktree, checkout: fn -> {:error, {:boot_timeout, 180_000}} end)

      for {tool, args} <- [{"qa_android_install", %{}}, {"qa_android_launch", %{"application_id" => @app_id}}, {"qa_android_screenshot", %{"name" => "a"}}] do
        assert {:error, {:qa_tool, "qa_android_unavailable", message}} = call(driver, tool, args)
        assert message =~ "did not finish booting within 180000 ms"
        assert message =~ "verdict `blocked`"
      end

      assert Driver.stop(driver) == :ok
      refute_received {:checked_in, _lease}
      assert adb_calls() == []

      # Without the emulator manager running, the default checkout fails the same way.
      default = start_driver(worktree, checkout: nil)
      assert error_code(call(default, "qa_android_stop", %{"application_id" => @app_id})) == "qa_android_unavailable"

      # A stopped driver reports that, and stopping it again is harmless.
      Driver.stop(default)
      assert error_code(Driver.call_tool(default, "qa_android_stop", %{"application_id" => @app_id})) == "qa_android_driver_unavailable"
      assert Driver.stop(default) == :ok
    end

    # The driver traps exits, so every adb port it opens sends an `:EXIT` when it closes.
    test "ignores the exit of a closed adb port", %{worktree: worktree} do
      driver = start_driver(worktree)
      port = Port.open({:spawn_executable, System.find_executable("true")}, [])
      Port.close(port)

      log =
        capture_log(fn ->
          send(driver, {:EXIT, port, :normal})
          assert %{lease: %{}} = GenServer.call(driver, :config)
        end)

      refute log =~ "received unexpected message"
      assert Process.alive?(driver)

      # Any other message is still logged, and the driver stays up.
      log =
        capture_log(fn ->
          send(driver, :unexpected)
          assert %{lease: %{}} = GenServer.call(driver, :config)
        end)

      assert log =~ "Android QA driver received unexpected message=:unexpected"
      assert Process.alive?(driver)
    end
  end

  describe "qa_android_install" do
    test "refuses edits to tracked files but not evidence or gitignored build outputs", %{worktree: worktree} do
      git = fn args, _cwd ->
        send(self(), {:git, args})
        {" M app/src/main/java/App.kt\0 M qa-evidence/notes.md\0", 0}
      end

      driver = start_driver(worktree, git: git)
      assert {:error, {:qa_tool, "qa_worktree_modified", message}} = call(driver, "qa_android_install")
      assert message =~ "app/src/main/java/App.kt"
      refute message =~ "notes.md"
      assert_received {:git, ["status", "--porcelain=v1", "-z", "--untracked-files=no"]}
      refute Enum.any?(adb_calls(), &match?(["install" | _rest], &1))

      evidence_only = start_driver(worktree, git: fn _args, _cwd -> {" M qa-evidence/notes.md\0", 0} end)
      assert {:ok, _result} = call(evidence_only, "qa_android_install")

      broken = start_driver(worktree, git: fn _args, _cwd -> {String.duplicate("x", 600), 128} end)
      assert {:error, {:qa_tool, "qa_git_failed", message}} = call(broken, "qa_android_install")
      assert message =~ "…"
    end

    test "uses the real git status of the worktree by default", %{worktree: worktree} do
      {_output, 0} = System.cmd("git", ["init", "--quiet", worktree])
      File.write!(Path.join(worktree, ".gitignore"), "app/build/\nqa-evidence/\n")
      {_output, 0} = System.cmd("git", ["-C", worktree, "add", ".gitignore"])
      identity = ["-c", "user.name=QA", "-c", "user.email=qa@example.com"]
      {_output, 0} = System.cmd("git", ["-C", worktree | identity] ++ ["commit", "--quiet", "-m", "init"])

      driver = start_driver(worktree, git: nil)
      assert {:ok, _result} = call(driver, "qa_android_install")

      File.write!(Path.join(worktree, ".gitignore"), "")
      assert error_code(call(driver, "qa_android_install")) == "qa_worktree_modified"
    end

    test "rejects an APK path outside the worktree, a directory, a symlink, a missing and an oversized file", %{root: root, worktree: worktree} do
      outside = Path.join(root, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "app.apk"), "apk-bytes")
      File.ln_s!(outside, Path.join(worktree, "linked"))
      File.ln_s!(Path.join(worktree, @apk), Path.join(worktree, "app/alias.apk"))
      File.write!(Path.join(worktree, "README"), "")

      for {apk_path, code} <- [
            {"../outside/app.apk", "qa_apk_outside_worktree"},
            {"linked/app.apk", "qa_apk_outside_worktree"},
            {"README/app.apk", "qa_apk_outside_worktree"},
            {"app/build", "qa_apk_missing"},
            {"app/alias.apk", "qa_apk_unsafe"},
            {"app/missing.apk", "qa_apk_missing"}
          ] do
        driver = start_driver(worktree, playbook: %{apk_path: apk_path})
        assert {:error, {:qa_tool, ^code, message}} = call(driver, "qa_android_install")
        assert message =~ apk_path
      end

      oversized = start_driver(worktree, max_apk_bytes: 4)
      assert {:error, {:qa_tool, "qa_apk_too_large", message}} = call(oversized, "qa_android_install")
      assert message =~ "9 bytes"
      refute Enum.any?(adb_calls(), &match?(["install" | _rest], &1))

      # A file cut under the cap after its path was checked: only the size the
      # cap was checked on is copied.
      test = self()

      truncate = fn path ->
        File.write!(path, "apk")
        :file.open(path, [:read, :raw, :binary])
      end

      install = fn ["install", "-r", copy] -> send(test, {:copied, File.read!(copy)}) && {:ok, {"Success\n", 0}} end
      truncated = start_driver(worktree, max_apk_bytes: 5, open: truncate, cmd: device(%{install: install}))
      assert error_code(call(truncated, "qa_android_install")) == "qa_apk_package_not_configured"
      assert_received {:copied, "apk"}
    end

    test "refuses an APK that changes while it is opened or copied", %{root: root, worktree: worktree} do
      other = Path.join(root, "other.apk")
      File.write!(other, "other-bytes")

      opens = [
        {fn _path -> :file.open(other, [:read, :raw, :binary]) end, "qa_apk_unsafe", "changed while Symphony opened it"},
        {fn _path -> {:error, :eacces} end, "qa_apk_missing", "could not be opened (:eacces)"},
        {fn path ->
           {:ok, fd} = :file.open(path, [:read, :raw])
           :ok = :file.close(fd)
           {:ok, fd}
         end, "qa_apk_missing", "could not be read (:einval)"},
        {fn path -> :file.open(path, [:append, :raw, :binary]) end, "qa_apk_missing", "could not be copied (:ebadf)"},
        {fn path ->
           {:ok, fd} = :file.open(path, [:read, :raw, :binary])
           {:ok, _position} = :file.position(fd, :eof)
           {:ok, fd}
         end, "qa_apk_missing", "could not be copied (:truncated)"}
      ]

      for {open, code, text} <- opens do
        driver = start_driver(worktree, open: open)
        assert {:error, {:qa_tool, ^code, message}} = call(driver, "qa_android_install")
        assert message =~ text
        assert File.ls!(GenServer.call(driver, :config).scratch_dir) == []
      end
    end

    test "refuses and uninstalls a package that is not configured", %{worktree: worktree} do
      driver = start_driver(worktree, cmd: device(%{}, "com.evil.app"))
      assert {:error, {:qa_tool, "qa_apk_package_not_configured", message}} = call(driver, "qa_android_install")
      assert message =~ "com.evil.app"
      assert ["uninstall", "com.evil.app"] in adb_calls()
      assert error_code(call(driver, "qa_android_launch", %{"application_id" => @app_id})) == "qa_android_not_installed"

      # An install that adds nothing is refused too.
      nothing = start_driver(worktree, cmd: device(%{install: {:ok, {"Success\n", 0}}}))
      assert {:error, {:qa_tool, "qa_apk_package_not_configured", message}} = call(nothing, "qa_android_install")
      assert message =~ "installed none of the configured application_ids (com.example.app)"
    end

    test "refuses and uninstalls a package the install replaced, but leaves the others alone", %{worktree: worktree} do
      initial = %{"com.other.app" => code_path("com.other.app"), "com.keep.app" => code_path("com.keep.app"), @app_id => code_path(@app_id)}
      driver = start_driver(worktree, cmd: device(%{}, "com.other.app", initial))
      assert {:error, {:qa_tool, "qa_apk_package_not_configured", message}} = call(driver, "qa_android_install")
      assert message =~ "The APK installed com.other.app,"
      calls = adb_calls()
      assert ["uninstall", "com.other.app"] in calls
      refute ["uninstall", "com.keep.app"] in calls

      # A configured app that was on the device before counts as installed again.
      configured = start_driver(worktree, cmd: device(%{}, @app_id, initial))
      assert {:ok, %{"installed" => [@app_id]}} = call(configured, "qa_android_install")
      assert {:ok, %{"installed" => [@app_id]}} = call(configured, "qa_android_install")
      Driver.stop(configured)
      refute Enum.any?(adb_calls(), &match?(["uninstall", id] when id != @app_id, &1))
    end

    test "uninstalls what an install that failed still installed", %{worktree: worktree} do
      timed_out = fn args, packages ->
        default_reply(args, packages, "com.evil.app")
        {:error, :timeout}
      end

      driver = start_driver(worktree, cmd: device(%{install: timed_out}))
      assert {:error, {:qa_tool, "qa_android_install_failed", message}} = call(driver, "qa_android_install")
      assert message =~ ":timeout"
      assert ["uninstall", "com.evil.app"] in adb_calls()

      # The listing after the install failed: the next listing finds the package.
      offline = {:ok, {"error: device offline", 1}}
      driver = start_driver(worktree, cmd: device(%{pm_list: replies_in_turn([:device, :device, offline])}, "com.evil.app"))
      assert error_code(call(driver, "qa_android_install")) == "qa_android_adb_failed"
      assert ["uninstall", "com.evil.app"] in adb_calls()

      # The device could not list them again either: the driver uninstalls the
      # package when it stops.
      pm_list = replies_in_turn([:device, :device, offline, offline])
      driver = start_driver(worktree, cmd: device(%{pm_list: pm_list}, "com.evil.app"))
      assert error_code(call(driver, "qa_android_install")) == "qa_android_adb_failed"
      refute ["uninstall", "com.evil.app"] in adb_calls()
      Driver.stop(driver)
      assert ["uninstall", "com.evil.app"] in adb_calls()
    end

    test "reports install and adb failures", %{worktree: worktree} do
      long = String.duplicate("x", 2_100)

      for {reply, text} <- [
            {{:ok, {"Failure [INSTALL_FAILED_INVALID_APK]\n", 1}}, "INSTALL_FAILED_INVALID_APK"},
            {{:ok, {"Performing Streamed Install\n", 0}}, "Performing Streamed Install"},
            {{:ok, {long, 1}}, "…"},
            {{:error, :timeout}, ":timeout"}
          ] do
        driver = start_driver(worktree, cmd: device(%{install: reply}))
        assert {:error, {:qa_tool, "qa_android_install_failed", message}} = call(driver, "qa_android_install")
        assert message =~ text
      end

      for {reply, text} <- [{{:ok, {"error: device offline", 1}}, "exit status 1: error: device offline"}, {{:error, :enoent}, ":enoent"}] do
        driver = start_driver(worktree, cmd: device(%{pm_list: reply}))
        assert {:error, {:qa_tool, "qa_android_adb_failed", message}} = call(driver, "qa_android_install")
        assert message =~ "adb shell pm list packages -3 -f failed: #{text}"
      end
    end
  end

  describe "qa_android_launch and qa_android_stop" do
    test "accept only a configured application ID", %{worktree: worktree} do
      driver = start_driver(worktree, playbook: %{application_ids: [@app_id, "bad; reboot", 7]})

      for tool <- ["qa_android_launch", "qa_android_stop"] do
        assert {:error, {:qa_tool, "qa_android_app_not_configured", message}} = call(driver, tool, %{"application_id" => "com.other.app"})
        assert message =~ "(com.example.app)"
        assert error_code(call(driver, tool, %{"application_id" => "bad; reboot"})) == "qa_android_app_not_configured"
        assert error_code(call(driver, tool, %{})) == "invalid_arguments"
      end

      assert {:error, {:qa_tool, "qa_android_not_installed", _message}} = call(driver, "qa_android_launch", %{"application_id" => @app_id})
      refute Enum.any?(adb_calls(), &match?(["shell", "am" | _rest], &1))
    end

    test "reports a missing launcher activity and a failed start", %{worktree: worktree} do
      driver = installed_driver(worktree, cmd: device(%{resolve: {:ok, {"No activity found\n", 0}}}))
      assert {:error, {:qa_tool, "qa_android_no_launcher", message}} = call(driver, "qa_android_launch", %{"application_id" => @app_id})
      assert message =~ "No activity found"

      driver = installed_driver(worktree, cmd: device(%{am_start: {:ok, {"Error: Activity class {com.example.app/.Main} does not exist.\n", 0}}}))
      assert {:error, {:qa_tool, "qa_android_launch_failed", message}} = call(driver, "qa_android_launch", %{"application_id" => @app_id})
      assert message =~ "does not exist"

      driver = installed_driver(worktree, cmd: device(%{am_start: {:ok, {"Security exception", 255}}}))
      assert error_code(call(driver, "qa_android_launch", %{"application_id" => @app_id})) == "qa_android_adb_failed"
    end

    test "reports an app that exits with its logcat", %{worktree: worktree} do
      # It died before its pid was seen: the crash buffer has it.
      driver = installed_driver(worktree, cmd: device(%{pidof: {:ok, {"", 1}}}))
      assert {:error, {:qa_tool, "qa_app_exited", message}} = call(driver, "qa_android_launch", %{"application_id" => @app_id})
      assert message =~ "FATAL EXCEPTION"
      assert ["logcat", "-d", "-t", "200", "-b", "crash"] in adb_calls()

      # It started, then died: its own log has it.
      {:ok, pidofs} = Agent.start_link(fn -> [{:ok, {"4242\n", 0}}, {:ok, {"not-a-pid\n", 0}}] end)
      pidof = fn _args -> Agent.get_and_update(pidofs, fn [reply | rest] -> {reply, rest} end) end
      replies = %{pidof: pidof, dumpsys: {:ok, {"  mResumedActivity: ActivityRecord{1f u0 com.android.launcher/.Home t1}\n", 0}}, logcat: {:error, :timeout}}
      driver = installed_driver(worktree, cmd: device(replies))
      assert {:error, {:qa_tool, "qa_app_exited", message}} = call(driver, "qa_android_launch", %{"application_id" => @app_id})
      assert message =~ "(logcat could not be read)"
      assert ["logcat", "-d", "-t", "200", "--pid=4242"] in adb_calls()
      assert_received {:slept, 500}
    end

    test "gives up on an activity that never comes to the foreground", %{worktree: worktree} do
      driver = installed_driver(worktree, cmd: device(%{dumpsys: {:error, :timeout}}))
      assert {:error, {:qa_tool, "qa_android_not_resumed", message}} = call(driver, "qa_android_launch", %{"application_id" => @app_id})
      assert message =~ "within 10000 ms"
      assert Enum.count(adb_calls(), &match?(["shell", "pidof", _id], &1)) == 20
    end

    test "stop reports adb failures", %{worktree: worktree} do
      driver = start_driver(worktree, cmd: device(%{force_stop: {:error, :timeout}}))
      assert {:error, {:qa_tool, "qa_android_adb_failed", message}} = call(driver, "qa_android_stop", %{"application_id" => @app_id})
      assert message =~ "adb shell am force-stop com.example.app failed: :timeout"
    end
  end

  describe "qa_android_screenshot" do
    test "never overwrites a file or follows a symlink", %{root: root, worktree: worktree} do
      driver = start_driver(worktree)
      assert {:ok, %{"path" => "qa-evidence/home.png"}} = call(driver, "qa_android_screenshot", %{"name" => "home"})
      assert {:error, {:qa_tool, "qa_screenshot_exists", _message}} = call(driver, "qa_android_screenshot", %{"name" => "home"})

      target = Path.join(root, "target.png")
      File.ln_s!(target, Path.join(worktree, "qa-evidence/linked.png"))
      assert error_code(call(driver, "qa_android_screenshot", %{"name" => "linked"})) == "qa_screenshot_exists"
      refute File.exists?(target)

      assert error_code(call(driver, "qa_android_screenshot", %{"name" => "../escape"})) == "invalid_arguments"
      assert error_code(call(driver, "qa_android_screenshot", %{})) == "invalid_arguments"
    end

    test "refuses an unsafe evidence folder and a capture that is not a PNG", %{root: root, worktree: worktree} do
      File.ln_s!(root, Path.join(worktree, "qa-evidence"))
      driver = start_driver(worktree)
      assert error_code(call(driver, "qa_android_screenshot", %{"name" => "a"})) == "qa_evidence_unsafe"
      File.rm!(Path.join(worktree, "qa-evidence"))

      for {reply, text} <- [{{:ok, {"error: device offline", 1}}, "did not return a PNG: error: device offline"}, {{:error, :timeout}, "screencap failed: :timeout"}] do
        driver = start_driver(worktree, cmd: device(%{screencap: reply}))
        assert {:error, {:qa_tool, "qa_screenshot_failed", message}} = call(driver, "qa_android_screenshot", %{"name" => "a"})
        assert message =~ text
      end

      refute File.exists?(Path.join(worktree, "qa-evidence/a.png"))
    end

    test "caps screenshots per pass", %{worktree: worktree} do
      driver = start_driver(worktree)

      for index <- 1..50 do
        assert {:ok, _result} = call(driver, "qa_android_screenshot", %{"name" => "step-#{index}"})
      end

      assert error_code(call(driver, "qa_android_screenshot", %{"name" => "step-51"})) == "qa_too_many_screenshots"
    end
  end

  describe "screen tools" do
    test "act only once a configured app is installed in this pass", %{worktree: worktree} do
      driver = start_driver(worktree)

      for {tool, args} <- [
            {"qa_android_ui_tree", %{}},
            {"qa_android_tap", %{"x" => 1, "y" => 1}},
            {"qa_android_type", %{"text" => "a"}},
            {"qa_android_key", %{"key" => "back"}},
            {"qa_android_rotate", %{"orientation" => "landscape"}},
            {"qa_android_dark_mode", %{"mode" => "on"}},
            {"qa_android_font_scale", %{"scale" => 1.3}}
          ] do
        assert {:error, {:qa_tool, "qa_android_not_installed", message}} = call(driver, tool, args)
        assert message =~ "Run qa_android_install first"
      end

      assert adb_calls() == []

      # An APK that installed nothing configured leaves them unavailable too.
      nothing = installed_nothing(worktree)
      assert error_code(call(nothing, "qa_android_ui_tree")) == "qa_android_not_installed"
    end
  end

  describe "qa_android_ui_tree" do
    test "parses a uiautomator dump read through exec-out into flat nodes", %{worktree: worktree} do
      driver = installed_driver(worktree)
      adb_calls()

      assert {:ok, tree} = call(driver, "qa_android_ui_tree")
      assert_received {:adb, @dump_args, opts}
      assert opts[:output_limit] == 2_000_001
      assert adb_calls() == []

      assert %{"foreground_package" => @app_id, "node_count" => 14, "truncated" => false, "nodes" => nodes} = tree
      refute Map.has_key?(tree, "note")
      refute Map.has_key?(tree, "foreground_warning")

      assert Enum.map(nodes, & &1["path"]) ==
               ~w(0 0.0 0.0.0 0.0.0.0 0.0.0.0.0 0.0.0.0.1 0.0.0.0.2 0.0.0.0.3 0.0.0.0.4 0.0.0.0.5 0.0.0.0.5.0 0.0.0.0.5.1 0.0.0.0.5.2 0.0.0.0.6)

      by_path = Map.new(nodes, &{&1["path"], &1})

      assert by_path["0.0.0.0.1"] == %{
               "path" => "0.0.0.0.1",
               "class" => "android.widget.EditText",
               "text" => "ana@example.com",
               "resource-id" => "com.example.app:id/email",
               "bounds" => %{"left" => 42, "top" => 252, "right" => 1038, "bottom" => 378},
               "clickable" => true,
               "focused" => true,
               "enabled" => true,
               "checked" => false,
               "scrollable" => false
             }

      assert by_path["0"] |> Map.take(["text", "content-desc", "resource-id"]) == %{}
      assert by_path["0.0.0.0.0"]["text"] == "Sign in to Orders & Billing"
      assert by_path["0.0.0.0.3"]["checked"]
      assert by_path["0.0.0.0.5"]["scrollable"]
      assert by_path["0.0.0.0.5.2"]["text"] == "Order #3"
      assert %{"content-desc" => "Help \"FAQ\"\nand support", "enabled" => false} = by_path["0.0.0.0.6"]
    end

    test "filters by text, resource ID and class", %{worktree: worktree} do
      driver = installed_driver(worktree)

      for {args, paths} <- [
            {%{"text" => "sign in"}, ["0.0.0.0.0", "0.0.0.0.4"]},
            {%{"text" => "faq"}, ["0.0.0.0.6"]},
            {%{"resource_id" => "email"}, ["0.0.0.0.1"]},
            {%{"resource_id" => "com.example.app:id/order_title"}, ["0.0.0.0.5.0", "0.0.0.0.5.1", "0.0.0.0.5.2"]},
            {%{"class" => "Button"}, ["0.0.0.0.4"]},
            {%{"class" => "android.widget.ImageButton"}, ["0.0.0.0.6"]},
            {%{"class" => "EditText", "resource_id" => "password"}, ["0.0.0.0.2"]},
            {%{"text" => "order", "resource_id" => "title"}, ["0.0.0.0.0"]},
            {%{"text" => "nothing like this"}, []}
          ] do
        assert {:ok, %{"nodes" => nodes, "node_count" => 14, "truncated" => false}} = call(driver, "qa_android_ui_tree", args)
        assert Enum.map(nodes, & &1["path"]) == paths, inspect(args)
      end

      bad = [%{"text" => ""}, %{"class" => 7}, %{"resource_id" => String.duplicate("a", 201)}, %{"max_depth" => 0}, %{"max_nodes" => 1001}]

      for args <- [%{"max_depth" => "3"} | bad] do
        assert error_code(call(driver, "qa_android_ui_tree", args)) == "invalid_arguments"
      end
    end

    test "caps depth, nodes and bytes and says what it left out", %{worktree: worktree} do
      driver = installed_driver(worktree)

      assert {:ok, %{"nodes" => nodes, "truncated" => true, "note" => note}} = call(driver, "qa_android_ui_tree", %{"max_depth" => 3})
      assert Enum.map(nodes, & &1["path"]) == ~w(0 0.0 0.0.0)
      assert note =~ "Not every node is shown: 11 nodes deeper than max_depth 3."

      assert {:ok, %{"nodes" => nodes, "truncated" => true, "note" => note}} = call(driver, "qa_android_ui_tree", %{"max_depth" => 5, "max_nodes" => 2})
      assert length(nodes) == 2
      assert note =~ "3 nodes deeper than max_depth 5; 9 more nodes after max_nodes 2."

      # Long texts: the JSON stays under 100 KB.
      rows = Enum.map_join(0..999, fn index -> row(index, String.duplicate("x", 300)) end)
      big = installed_driver(worktree, cmd: device(%{ui_dump: {:ok, {hierarchy(rows), 0}}}))
      assert {:ok, %{"nodes" => nodes, "truncated" => true, "note" => note}} = call(big, "qa_android_ui_tree", %{"max_nodes" => 1000})
      assert byte_size(Jason.encode!(nodes)) <= 100_000
      assert note =~ "#{1000 - length(nodes)} more nodes over the 100000-byte limit"
    end

    test "warns when a configured app is not in the foreground", %{worktree: worktree} do
      launcher = String.replace(@dump, ~s(package="com.example.app"), ~s(package="com.android.launcher3"))
      driver = installed_driver(worktree, cmd: device(%{ui_dump: {:ok, {launcher, 0}}}))
      assert {:ok, %{"foreground_package" => "com.android.launcher3", "foreground_warning" => warning}} = call(driver, "qa_android_ui_tree")
      assert warning =~ "com.android.launcher3 is in the foreground, not one of the configured application_ids (com.example.app)"
      assert warning =~ "qa_android_launch"

      empty = installed_driver(worktree, cmd: device(%{ui_dump: {:ok, {hierarchy(""), 0}}}))
      assert {:ok, %{"foreground_package" => nil, "nodes" => [], "foreground_warning" => "Nothing is in the foreground" <> _rest}} = call(empty, "qa_android_ui_tree")
    end

    test "reports a dump that failed, has no hierarchy or is too large", %{worktree: worktree} do
      for {reply, text} <- [
            {{:ok, {"ERROR: could not get idle state.\n", 0}}, "returned no UI hierarchy: ERROR: could not get idle state."},
            {{:ok, {"error: device offline", 1}}, "exit status 1: error: device offline"},
            {{:error, :timeout}, "uiautomator dump failed: :timeout"},
            {{:ok, {String.duplicate("x", 2_000_001), 0}}, "over 2000000 bytes"}
          ] do
        driver = installed_driver(worktree, cmd: device(%{ui_dump: reply}))
        assert {:error, {:qa_tool, "qa_android_ui_tree_failed", message}} = call(driver, "qa_android_ui_tree")
        assert message =~ text
      end
    end
  end

  describe "qa_android_tap" do
    test "taps the centre of a node from the last tree or a point on the display", %{worktree: worktree} do
      driver = installed_driver(worktree)
      assert {:ok, _tree} = call(driver, "qa_android_ui_tree")
      adb_calls()

      assert {:ok, %{"x" => 540, "y" => 819}} = call(driver, "qa_android_tap", %{"path" => "0.0.0.0.4"})
      assert adb_calls() == [@display_args, ["shell", "input", "tap", "540", "819"]]

      assert {:ok, %{"x" => 0, "y" => 2399}} = call(driver, "qa_android_tap", %{"x" => 0, "y" => 2399})
      assert ["shell", "input", "tap", "0", "2399"] in adb_calls()

      # In landscape the display is wider than it is tall.
      landscape = {:ok, {"  init=1080x2400 420dpi cur=2400x1080 app=2400x1017\n", 0}}
      rotated = installed_driver(worktree, cmd: device(%{display: landscape}))
      assert {:ok, %{"x" => 2000}} = call(rotated, "qa_android_tap", %{"x" => 2000, "y" => 500})
    end

    test "rejects off-screen points, unknown paths and bad arguments", %{worktree: worktree} do
      driver = installed_driver(worktree)
      assert {:error, {:qa_tool, "qa_android_unknown_path", message}} = call(driver, "qa_android_tap", %{"path" => "0.0.0.0.4"})
      assert message =~ "not a node path in the last qa_android_ui_tree result"

      # Only the nodes the last tree returned count.
      assert {:ok, _tree} = call(driver, "qa_android_ui_tree", %{"resource_id" => "email"})
      assert error_code(call(driver, "qa_android_tap", %{"path" => "0.0.0.0.4"})) == "qa_android_unknown_path"
      assert {:ok, _result} = call(driver, "qa_android_tap", %{"path" => "0.0.0.0.1"})

      for {x, y} <- [{1080, 10}, {10, 2400}, {-1, 10}, {10, -5}, {99_999, 99_999}] do
        assert {:error, {:qa_tool, "qa_android_tap_off_screen", message}} = call(driver, "qa_android_tap", %{"x" => x, "y" => y})
        assert message =~ "(#{x}, #{y}) is outside the 1080x2400 display."
      end

      for args <- [%{}, %{"x" => 1}, %{"x" => 1.5, "y" => 2}, %{"path" => "0", "x" => 1, "y" => 1}, %{"path" => 0}] do
        assert {:error, {:qa_tool, "invalid_arguments", message}} = call(driver, "qa_android_tap", args)
        assert message =~ "either `path`"
      end

      refute Enum.any?(adb_calls(), &match?(["shell", "input", "tap", x, _y] when x != "540", &1))
    end

    test "refuses a node without area or off the display", %{worktree: worktree} do
      rows = row(0, "empty", "[0,0][0,0]") <> row(1, "unbounded", nil) <> row(2, "below", "[0,2500][1080,2700]")
      driver = installed_driver(worktree, cmd: device(%{ui_dump: {:ok, {hierarchy(rows), 0}}}))
      assert {:ok, _tree} = call(driver, "qa_android_ui_tree")

      assert {:error, {:qa_tool, "qa_android_tap_off_screen", "Node 0 has no area on screen to tap."}} = call(driver, "qa_android_tap", %{"path" => "0"})
      assert {:error, {:qa_tool, "qa_android_tap_off_screen", "Node 1 has no area on screen to tap."}} = call(driver, "qa_android_tap", %{"path" => "1"})
      assert {:error, {:qa_tool, "qa_android_tap_off_screen", message}} = call(driver, "qa_android_tap", %{"path" => "2"})
      assert message =~ "The centre of node 2 is outside the 1080x2400 display."
      refute Enum.any?(adb_calls(), &match?(["shell", "input" | _rest], &1))
    end

    test "reports a display size it cannot read and a failed tap", %{worktree: worktree} do
      for reply <- [{:ok, {"WINDOW MANAGER DISPLAY CONTENTS\n", 0}}, {:error, :timeout}] do
        driver = installed_driver(worktree, cmd: device(%{display: reply}))
        assert {:error, {:qa_tool, "qa_android_adb_failed", message}} = call(driver, "qa_android_tap", %{"x" => 1, "y" => 1})
        assert message =~ "dumpsys window displays"
      end

      driver = installed_driver(worktree, cmd: device(%{input: {:ok, {"error: closed", 1}}}))
      assert {:error, {:qa_tool, "qa_android_adb_failed", message}} = call(driver, "qa_android_tap", %{"x" => 1, "y" => 1})
      assert message =~ "adb shell input tap 1 1 failed"
    end
  end

  describe "qa_android_type" do
    test "shell metacharacters reach the device as literal text", %{worktree: worktree, root: root} do
      canary = Path.join(root, "canary")

      text =
        "a;b && reboot | cat > /x `id` $(touch #{canary}) ${HOME} 'single' \"double\" \\back !bang #hash ~ * ? [x] (y) {z} < & 100%s sure %%s 50%\nnext line\n"

      driver = installed_driver(worktree)
      adb_calls()
      assert {:ok, %{"typed" => typed}} = call(driver, "qa_android_type", %{"text" => text})
      assert typed == String.length(text)

      commands = adb_calls()

      assert commands == [
               ["shell", "input", "text", "'a;b && reboot | cat > /x `id` $(touch #{canary}) ${HOME} '\\''single'\\'' \"double\" \\back !bang #hash ~ * ? [x] (y) {z} < & 100%'"],
               ["shell", "input", "text", "'s sure %%'"],
               ["shell", "input", "text", "'s 50%'"],
               ["shell", "input", "keyevent", "KEYCODE_ENTER"],
               ["shell", "input", "text", "'next line'"],
               ["shell", "input", "keyevent", "KEYCODE_ENTER"]
             ]

      # The device's shell reads `input text <argument>`: a POSIX shell gives
      # `input` each chunk back verbatim and runs nothing, and `input text`
      # turns no literal `%s` into a space.
      assert Enum.map_join(commands, &device_types/1) == text
      refute File.exists?(canary)
    end

    test "rejects text adb cannot type, empty and long text", %{worktree: worktree} do
      driver = installed_driver(worktree)
      adb_calls()

      for text <- ["café", "emoji 😀", "tab\there", "bell\a", "cr\r\n"] do
        assert {:error, {:qa_tool, "qa_android_text_unsupported", message}} = call(driver, "qa_android_type", %{"text" => text})
        assert message =~ "printable ASCII and newlines only"
      end

      assert {:error, {:qa_tool, "invalid_arguments", message}} = call(driver, "qa_android_type", %{"text" => String.duplicate("a", 501)})
      assert message =~ "over 500 characters"
      assert {:ok, _result} = call(driver, "qa_android_type", %{"text" => String.duplicate("a", 500)})

      for args <- [%{}, %{"text" => ""}, %{"text" => 5}] do
        assert {:error, {:qa_tool, "invalid_arguments", "`text` must be a non-empty string."}} = call(driver, "qa_android_type", args)
      end

      assert adb_calls() == [["shell", "input", "text", "'#{String.duplicate("a", 500)}'"]]
    end

    test "presses Enter for a newline and stops at the first failure", %{worktree: worktree} do
      driver = installed_driver(worktree)
      adb_calls()
      assert {:ok, %{"typed" => 1}} = call(driver, "qa_android_type", %{"text" => "\n"})
      assert adb_calls() == [["shell", "input", "keyevent", "KEYCODE_ENTER"]]

      failing = installed_driver(worktree, cmd: device(%{input: {:error, :timeout}}))
      adb_calls()
      assert error_code(call(failing, "qa_android_type", %{"text" => "one\ntwo"})) == "qa_android_adb_failed"
      assert adb_calls() == [["shell", "input", "text", "'one'"]]
    end
  end

  describe "qa_android_key" do
    test "presses only allowlisted keys", %{worktree: worktree} do
      driver = installed_driver(worktree)
      adb_calls()

      for {key, keycode} <- [
            {"back", "KEYCODE_BACK"},
            {"enter", "KEYCODE_ENTER"},
            {"ime_action", "KEYCODE_NUMPAD_ENTER"},
            {"tab", "KEYCODE_TAB"},
            {"del", "KEYCODE_DEL"},
            {"dpad_up", "KEYCODE_DPAD_UP"},
            {"dpad_down", "KEYCODE_DPAD_DOWN"},
            {"dpad_left", "KEYCODE_DPAD_LEFT"},
            {"dpad_right", "KEYCODE_DPAD_RIGHT"},
            {"escape", "KEYCODE_ESCAPE"}
          ] do
        assert {:ok, %{"key" => ^key, "keycode" => ^keycode}} = call(driver, "qa_android_key", %{"key" => key})
        assert adb_calls() == [["shell", "input", "keyevent", keycode]]
      end

      for args <- [%{"key" => "home"}, %{"key" => "KEYCODE_POWER"}, %{"key" => "26"}, %{"key" => "back; reboot"}, %{}] do
        assert {:error, {:qa_tool, "invalid_arguments", message}} = call(driver, "qa_android_key", args)
        assert message == "`key` must be one of back, enter, ime_action, tab, del, dpad_up, dpad_down, dpad_left, dpad_right, escape."
      end

      assert adb_calls() == []

      failing = installed_driver(worktree, cmd: device(%{input: {:error, :timeout}}))
      assert error_code(call(failing, "qa_android_key", %{"key" => "back"})) == "qa_android_adb_failed"
    end
  end

  describe "qa_android_rotate, qa_android_dark_mode and qa_android_font_scale" do
    test "change the setting and reset what the pass changed when it ends", %{worktree: worktree} do
      driver = installed_driver(worktree, cmd: rotating_device())
      adb_calls()

      assert {:ok, %{"orientation" => "landscape", "display" => "2400x1080"}} = call(driver, "qa_android_rotate", %{"orientation" => "landscape"})
      assert {:ok, %{"orientation" => "portrait", "display" => "1080x2400"}} = call(driver, "qa_android_rotate", %{"orientation" => "portrait"})
      assert {:ok, %{"dark_mode" => "on"}} = call(driver, "qa_android_dark_mode", %{"mode" => "on"})
      assert {:ok, %{"font_scale" => 1.3}} = call(driver, "qa_android_font_scale", %{"scale" => 1.3})
      assert {:ok, %{"font_scale" => 2.0}} = call(driver, "qa_android_font_scale", %{"scale" => 2})

      assert adb_calls() == [
               ["shell", "cmd", "window", "user-rotation", "lock", "1"],
               @display_args,
               ["shell", "cmd", "window", "user-rotation", "lock", "0"],
               @display_args,
               ["shell", "cmd", "uimode", "night", "yes"],
               ["shell", "settings", "put", "system", "font_scale", "1.3"],
               ["shell", "settings", "put", "system", "font_scale", "2.0"]
             ]

      refute_received {:slept, _ms}
      assert Driver.stop(driver) == :ok

      assert [
               ["shell", "cmd", "window", "user-rotation", "lock", "0"],
               ["shell", "cmd", "uimode", "night", "no"],
               ["shell", "settings", "put", "system", "font_scale", "1.0"],
               ["shell", "pm", "list", "packages", "-3", "-f"],
               ["uninstall", @app_id]
             ] = adb_calls()
    end

    test "rotate waits for the display to turn and fails when it does not", %{worktree: worktree} do
      turning = replies_in_turn([display("1080x2400"), display("1080x2400"), display("2400x1080")])
      slow = installed_driver(worktree, cmd: device(%{display: turning}))
      adb_calls()
      assert {:ok, %{"display" => "2400x1080"}} = call(slow, "qa_android_rotate", %{"orientation" => "landscape"})
      assert adb_calls() == [["shell", "cmd", "window", "user-rotation", "lock", "1"], @display_args, @display_args, @display_args]
      assert_received {:slept, 500}
      assert_received {:slept, 500}
      refute_received {:slept, _ms}

      # The default display stays portrait, as an emulator that ignores the lock does.
      stuck = installed_driver(worktree)
      adb_calls()
      assert {:error, {:qa_tool, "qa_android_rotate_failed", message}} = call(stuck, "qa_android_rotate", %{"orientation" => "landscape"})
      assert message =~ "The display is still 1080x2400, not landscape, 5000 ms after the rotation."
      assert message =~ "android:screenOrientation"
      assert message =~ "mark the landscape checks `blocked`"
      assert [["shell", "cmd", "window", "user-rotation", "lock", "1"] | reads] = adb_calls()
      assert reads == List.duplicate(@display_args, 10)

      for _attempt <- 1..9, do: assert_received({:slept, 500})
      refute_received {:slept, _ms}

      # It still resets the rotation it tried to change.
      Driver.stop(stuck)
      assert ["shell", "cmd", "window", "user-rotation", "lock", "0"] in adb_calls()

      unreadable = installed_driver(worktree, cmd: device(%{display: {:ok, {"Permission denial", 255}}}))
      assert {:error, {:qa_tool, "qa_android_adb_failed", message}} = call(unreadable, "qa_android_rotate", %{"orientation" => "landscape"})
      assert message =~ "dumpsys window displays"
    end

    test "rotate falls back to the settings when the window manager has no user-rotation", %{worktree: worktree} do
      unknown = {:ok, {"Unknown command: user-rotation\n", 255}}
      driver = installed_driver(worktree, cmd: device(%{user_rotation: unknown, display: display("2400x1080")}))
      adb_calls()

      assert {:ok, %{"orientation" => "landscape"}} = call(driver, "qa_android_rotate", %{"orientation" => "landscape"})

      assert adb_calls() == [
               ["shell", "cmd", "window", "user-rotation", "lock", "1"],
               ["shell", "settings", "put", "system", "accelerometer_rotation", "0"],
               ["shell", "settings", "put", "system", "user_rotation", "1"],
               @display_args
             ]

      Driver.stop(driver)

      assert [
               ["shell", "cmd", "window", "user-rotation", "lock", "0"],
               ["shell", "settings", "put", "system", "accelerometer_rotation", "0"],
               ["shell", "settings", "put", "system", "user_rotation", "0"] | _uninstall
             ] = adb_calls()
    end

    test "reset only the settings the pass changed, even when the change failed", %{worktree: worktree} do
      driver = installed_driver(worktree)
      assert {:ok, %{"dark_mode" => "off"}} = call(driver, "qa_android_dark_mode", %{"mode" => "off"})
      Driver.stop(driver)
      calls = adb_calls()
      assert ["shell", "cmd", "uimode", "night", "no"] in calls
      refute Enum.any?(calls, &match?(["shell", "settings" | _rest], &1))
      refute Enum.any?(calls, &match?(["shell", "cmd", "window" | _rest], &1))

      failing =
        installed_driver(worktree, cmd: device(%{user_rotation: {:ok, {"Security exception", 255}}, settings: {:ok, {"Security exception", 255}}}))

      assert {:error, {:qa_tool, "qa_android_adb_failed", message}} = call(failing, "qa_android_rotate", %{"orientation" => "landscape"})
      assert message == "adb shell cmd window user-rotation lock 1 failed: exit status 255: Security exception"
      assert error_code(call(failing, "qa_android_font_scale", %{"scale" => 0.85})) == "qa_android_adb_failed"
      adb_calls()
      Driver.stop(failing)
      calls = adb_calls()
      assert ["shell", "cmd", "window", "user-rotation", "lock", "0"] in calls
      assert ["shell", "settings", "put", "system", "font_scale", "1.0"] in calls
      refute ["shell", "cmd", "uimode", "night", "no"] in calls

      no_user_rotation = %{user_rotation: {:ok, {"Unknown command: user-rotation", 255}}, settings: {:ok, {"Security exception", 255}}}
      fallback_fails = installed_driver(worktree, cmd: device(no_user_rotation))
      assert {:error, {:qa_tool, "qa_android_adb_failed", message}} = call(fallback_fails, "qa_android_rotate", %{"orientation" => "landscape"})
      assert message =~ "adb shell settings put system accelerometer_rotation 0 failed"

      unreachable = installed_driver(worktree, cmd: device(%{user_rotation: {:error, :timeout}}))
      assert {:error, {:qa_tool, "qa_android_adb_failed", message}} = call(unreachable, "qa_android_rotate", %{"orientation" => "portrait"})
      assert message == "adb shell cmd window user-rotation lock 0 failed: :timeout"

      untouched = installed_driver(worktree)
      adb_calls()
      Driver.stop(untouched)
      refute Enum.any?(adb_calls(), &match?(["shell", setting | _rest] when setting in ["settings", "cmd"], &1))
    end

    test "refuse values outside their allowlists", %{worktree: worktree} do
      driver = installed_driver(worktree)
      adb_calls()

      for scale <- [1.25, 3, 0, "1.3", nil] do
        assert {:error, {:qa_tool, "invalid_arguments", message}} = call(driver, "qa_android_font_scale", %{"scale" => scale})
        assert message == "`scale` must be one of 0.85, 1.0, 1.15, 1.3, 1.5, 1.8, 2.0."
      end

      assert {:error, {:qa_tool, "invalid_arguments", "`orientation` must be one of portrait, landscape."}} =
               call(driver, "qa_android_rotate", %{"orientation" => "reverse_landscape"})

      assert {:error, {:qa_tool, "invalid_arguments", "`mode` must be one of on, off."}} = call(driver, "qa_android_dark_mode", %{"mode" => "auto"})

      Driver.stop(driver)
      refute Enum.any?(adb_calls(), &match?(["shell", setting | _rest] when setting in ["settings", "cmd"], &1))
    end
  end

  defp display(size), do: {:ok, {"Display: mDisplayId=0\n  init=1080x2400 420dpi base=1080x2400 420dpi cur=#{size} app=#{size}\n", 0}}

  # A display that turns as the rotation is locked: 1 is landscape.
  defp rotating_device do
    {:ok, rotation} = Agent.start_link(fn -> "0" end)

    device(%{
      user_rotation: fn ["shell", "cmd", "window", "user-rotation", "lock", value] ->
        Agent.update(rotation, fn _rotation -> value end)
        {:ok, {"", 0}}
      end,
      display: fn _args -> display(if Agent.get(rotation, & &1) == "1", do: "2400x1080", else: "1080x2400") end
    })
  end

  defp installed_nothing(worktree) do
    driver = start_driver(worktree, cmd: device(%{install: {:ok, {"Success\n", 0}}}))
    assert error_code(call(driver, "qa_android_install")) == "qa_apk_package_not_configured"
    driver
  end

  defp hierarchy(nodes), do: ~s(<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">#{nodes}</hierarchy>UI hierchary dumped to: /dev/tty\n)

  defp row(index, text, bounds \\ "[0,0][1080,200]") do
    bounds = if bounds, do: ~s( bounds="#{bounds}"), else: ""
    ~s(<node index="#{index}" text="#{text}" class="android.widget.TextView" package="#{@app_id}" clickable="true"#{bounds} />)
  end

  # What the device types for one adb command: its shell parses the command
  # line (`printf %s` stands in for `input text`), then `input text` turns `%s`
  # into a space, as Android's InputShellCommand does.
  defp device_types(["shell", "input", "keyevent", "KEYCODE_ENTER"]), do: "\n"

  defp device_types(["shell", "input", "text", argument]) do
    {parsed, 0} = System.cmd("sh", ["-c", "printf %s " <> argument])
    String.replace(parsed, "%s", " ")
  end

  defp collect_commands do
    receive do
      {:cmd, executable, args} -> [{executable, args} | collect_commands()]
    after
      0 -> []
    end
  end
end
