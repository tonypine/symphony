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

  # A fake emulator: the device's third-party packages live in an Agent, and the
  # APK installs `:apk_package`. Every adb call reaches the test as
  # `{:adb, args, opts}`, and every command as `{:cmd, executable, args}`.
  # `replies` overrides a command (keyed as in `command/1`) with a result or a
  # `fn args -> result end`.
  defp device(replies \\ %{}, apk_package \\ @app_id) do
    test = self()
    {:ok, packages} = Agent.start_link(fn -> MapSet.new() end)

    fn executable, args, opts ->
      send(test, {:cmd, executable, args})
      {@adb_prefix, adb_args} = Enum.split(args, 4)
      send(test, {:adb, adb_args, opts})

      case Map.fetch(replies, command(adb_args)) do
        {:ok, reply} when is_function(reply, 1) -> reply.(adb_args)
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
  defp command(["shell", "dumpsys" | _rest]), do: :dumpsys
  defp command(["exec-out" | _rest]), do: :screencap
  defp command(["logcat" | _rest]), do: :logcat

  defp default_reply(["uninstall", id], packages, _apk_package) do
    Agent.update(packages, &MapSet.delete(&1, id))
    {:ok, {"Success\n", 0}}
  end

  defp default_reply(["install", "-r", path], packages, apk_package) do
    "apk-bytes" = File.read!(path)
    Agent.update(packages, &MapSet.put(&1, apk_package))
    {:ok, {"Performing Streamed Install\nSuccess\n", 0}}
  end

  defp default_reply(["shell", "pm", "list", "packages", "-3"], packages, _apk_package) do
    {:ok, {packages |> Agent.get(& &1) |> Enum.map_join(&"package:#{&1}\n"), 0}}
  end

  defp default_reply(["shell", "cmd", "package", "resolve-activity" | _rest], _packages, _apk_package),
    do: {:ok, {"priority=0 preferredOrder=0\n#{@app_id}/.MainActivity\n", 0}}

  defp default_reply(["shell", "am", "start" | _rest], _packages, _apk_package),
    do: {:ok, {"Starting: Intent { cmp=#{@app_id}/.MainActivity }\nStatus: ok\nLaunchState: COLD\n", 0}}

  defp default_reply(["shell", "pidof", _id], _packages, _apk_package), do: {:ok, {"4242\n", 0}}

  defp default_reply(["shell", "dumpsys" | _rest], _packages, _apk_package),
    do: {:ok, {"  mResumedActivity: ActivityRecord{1f u0 #{@app_id}/.MainActivity t7}\n", 0}}

  defp default_reply(["exec-out", "screencap", "-p"], _packages, _apk_package), do: {:ok, {@png, 0}}
  defp default_reply(["logcat" | _rest], _packages, _apk_package), do: {:ok, {"E AndroidRuntime: FATAL EXCEPTION: main\n", 0}}
  defp default_reply(_args, _packages, _apk_package), do: {:ok, {"", 0}}

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
      assert Driver.tools() == ~w(qa_android_install qa_android_launch qa_android_stop qa_android_screenshot)
      assert error_code(Driver.call_tool(nil, "qa_android_install", %{})) == "qa_android_driver_unavailable"
      assert Driver.stop(nil) == :ok
    end

    test "installs, launches, stops and captures through adb only, then cleans up", %{worktree: worktree} do
      driver = installed_driver(worktree)
      assert_received {:checked_out, lease}

      %{scratch_dir: scratch_dir} = GenServer.call(driver, :config)
      {:ok, state_root} = PathSafety.canonicalize(Paths.state_root())
      assert String.starts_with?(scratch_dir, Path.join(state_root, "qa-android/runs") <> "/")
      assert File.stat!(scratch_dir).mode |> Bitwise.band(0o777) == 0o700

      # The configured app is wiped before the install, which runs from a private copy.
      assert [["uninstall", @app_id], ["shell", "pm", "list", "packages", "-3"], ["install", "-r", copy], ["shell", "pm", "list", "packages", "-3"]] =
               adb_calls()

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

      # An install that adds nothing (it replaced a package already there) is refused too.
      preinstalled = start_driver(worktree, cmd: device(%{pm_list: {:ok, {"package:com.other.app\n", 0}}}))
      assert {:error, {:qa_tool, "qa_apk_package_not_configured", message}} = call(preinstalled, "qa_android_install")
      assert message =~ "installed none of the configured application_ids (com.example.app)"
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
        assert message =~ "adb shell pm list packages -3 failed: #{text}"
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

  defp collect_commands do
    receive do
      {:cmd, executable, args} -> [{executable, args} | collect_commands()]
    after
      0 -> []
    end
  end
end
