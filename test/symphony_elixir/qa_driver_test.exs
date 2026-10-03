defmodule SymphonyElixir.QaDriverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Paths, PathSafety, QaDriver}
  alias SymphonyElixir.QaDriver.Host

  @app "macos/build/Demo.app"
  @helper "/fake/symphony-qa-driver"

  setup do
    File.mkdir_p!(System.tmp_dir!())
    {:ok, tmp} = PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "qa-driver-test-#{System.unique_integer([:positive])}")
    worktree = Path.join(root, "worktree")
    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, worktree: worktree}
  end

  # A fake host: the build writes the bundle, plutil names its executable, the
  # helper answers from `helper_replies`, screencapture writes the file it is given.
  defp host(overrides \\ %{}) do
    test = self()

    replies =
      Map.merge(
        %{
          "permissions" => {~s({"accessibility":true,"screen_recording":true}), 0},
          "windows" =>
            {Jason.encode!(%{
               windows: [
                 %{id: 11, title: "Settings", layer: 0, onscreen: true, frame: %{x: 0, y: 0, w: 548, h: 88}},
                 %{id: 12, title: "", layer: 25, onscreen: true, frame: %{x: 0, y: 0, w: 24, h: 24}},
                 %{id: 13, title: "Hidden", layer: 0, onscreen: false, frame: %{x: 0, y: 0, w: 400, h: 300}}
               ]
             }), 0},
          "ax-tree" => {~s({"root":{"path":"","role":"AXApplication"},"nodes":1,"truncated":false}), 0},
          "ax-press" => {~s({"ok":true,"element":{"path":"0.1","role":"AXButton"}}), 0},
          "ax-set-value" => {~s({"ok":true,"element":{"path":"0.2","role":"AXTextField"}}), 0}
        },
        Map.get(overrides, :helper_replies, %{})
      )

    %{
      cmd: fn executable, args, opts ->
        send(test, {:cmd, executable, args, opts})
        Map.get(overrides, :cmd, &default_cmd(&1, &2, &3, replies)).(executable, args, opts)
      end,
      launch:
        Map.get(overrides, :launch, fn executable, opts ->
          port = Port.open({:spawn, "cat"}, [:binary])
          pid = System.unique_integer([:positive]) + 100_000
          send(test, {:launched, executable, opts, port, pid})
          {:ok, port, pid}
        end),
      kill: fn pid -> send(test, {:killed, pid}) && :ok end,
      helper: Map.get(overrides, :helper, fn -> {:ok, @helper} end)
    }
  end

  defp default_cmd("/bin/sh", ["-c", build], opts, _replies) do
    if build =~ "fail", do: {:ok, {"error: build failed\n", 65}}, else: write_bundle(opts[:cd])
  end

  defp default_cmd("/usr/bin/plutil", _args, _opts, _replies), do: {:ok, {"Demo\n", 0}}

  defp default_cmd(@helper, [command | _rest], _opts, replies) do
    case Map.fetch!(replies, command) do
      {:error, _reason} = error -> error
      result -> {:ok, result}
    end
  end

  defp default_cmd("/usr/sbin/screencapture", args, _opts, _replies) do
    File.write!(List.last(args), "png")
    {:ok, {"", 0}}
  end

  defp write_bundle(worktree, contents \\ "binary-v1") do
    macos = Path.join([worktree, @app, "Contents", "MacOS"])
    File.mkdir_p!(macos)
    File.write!(Path.join([worktree, @app, "Contents", "Info.plist"]), "<plist/>")
    File.write!(Path.join(macos, "Demo"), contents)
    {:ok, {"Build complete!\n", 0}}
  end

  defp clean_git(_args, _cwd), do: {"", 0}

  defp start_driver(worktree, opts \\ []) do
    playbook = Map.merge(%{kind: "macos_app", build: "make app", app: @app}, Keyword.get(opts, :playbook, %{}))

    {:ok, driver} =
      QaDriver.start_link(
        worktree: worktree,
        playbook: playbook,
        host: Keyword.get(opts, :host, host()),
        git: Keyword.get(opts, :git, &clean_git/2)
      )

    on_exit(fn -> QaDriver.stop(driver) end)
    driver
  end

  defp launched_app(worktree, opts \\ []) do
    driver = start_driver(worktree, opts)
    assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
    {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
    assert {:ok, %{"pid" => pid, "qa_mode" => true}} = result
    {driver, pid}
  end

  defp error_code({:error, {:qa_tool, code, _message}}), do: code

  describe "tools" do
    test "lists the qa tools and needs a driver" do
      assert "qa_build" in QaDriver.tools()
      assert "qa_ax_set_value" in QaDriver.tools()
      assert error_code(QaDriver.call_tool(nil, "qa_build", %{})) == "qa_driver_unavailable"
    end

    test "builds, launches in QA mode, drives and quits only the launched app", %{worktree: worktree} do
      {driver, pid} = launched_app(worktree)

      assert_received {:cmd, "/bin/sh", ["-c", "make app"], build_opts}
      assert build_opts[:cd] == worktree
      assert build_opts[:timeout_ms] == 900_000
      refute Enum.any?(build_opts[:env], fn {name, value} -> name == ~c"LINEAR_API_KEY" and value != false end)

      %{scratch_dir: scratch_dir} = GenServer.call(driver, :config)
      {:ok, state_root} = PathSafety.canonicalize(Paths.state_root())
      assert String.starts_with?(scratch_dir, Path.join(state_root, "qa-driver/runs") <> "/")
      assert File.stat!(scratch_dir).mode |> Bitwise.band(0o777) == 0o700

      assert_received {:launched, executable, launch_opts, _port, ^pid}
      assert String.starts_with?(executable, Path.join(scratch_dir, "builds") <> "/")
      assert String.ends_with?(executable, "/Demo.app/Contents/MacOS/Demo")
      qa_root = launch_opts[:cd]
      assert String.starts_with?(qa_root, scratch_dir <> "/")
      assert {~c"SYMPHONY_BAR_QA_ROOT", String.to_charlist(qa_root)} in launch_opts[:env]
      assert File.dir?(qa_root)

      assert {:ok, %{"root" => %{"role" => "AXApplication"}}} =
               QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid, "role" => "AXTextField", "max_depth" => 5, "max_nodes" => 50})

      assert_received {:cmd, @helper, ["ax-tree", pid_arg, "5", "50", "AXTextField", ""], _opts}
      assert pid_arg == Integer.to_string(pid)

      assert {:ok, %{"root" => _root}} = QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid, "text" => ""})
      assert_received {:cmd, @helper, ["ax-tree", _pid, "12", "300", "", ""], _opts}

      assert {:ok, %{"ok" => true}} = QaDriver.call_tool(driver, "qa_ax_press", %{"pid" => pid, "path" => "0.1"})
      assert_received {:cmd, @helper, ["ax-press", _pid, "0.1", "AXPress"], _opts}

      assert {:ok, %{"ok" => true}} = QaDriver.call_tool(driver, "qa_ax_press", %{"pid" => pid, "path" => "0", "action" => "AXRaise"})
      assert_received {:cmd, @helper, ["ax-press", _pid, "0", "AXRaise"], _opts}

      assert {:ok, %{"ok" => true}} = QaDriver.call_tool(driver, "qa_ax_set_value", %{"pid" => pid, "path" => "0.2", "value" => "lin_api_fake"})
      assert_received {:cmd, @helper, ["ax-set-value", _pid, "0.2", "lin_api_fake"], _opts}

      assert {:ok, %{"files" => [%{"path" => "qa-evidence/settings-open.png", "window_id" => 11, "frame" => %{"h" => 88}}]}} =
               QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "settings-open.png"})

      assert File.read!(Path.join(worktree, "qa-evidence/settings-open.png")) == "png"

      assert {:ok, %{"pid" => ^pid, "quit" => true}} = QaDriver.call_tool(driver, "qa_quit_app", %{"pid" => pid})
      assert_received {:killed, ^pid}
      assert error_code(QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid})) == "qa_pid_not_launched"

      QaDriver.stop(driver)
      refute File.exists?(scratch_dir)
      assert error_code(QaDriver.call_tool(driver, "qa_build", %{})) == "qa_driver_unavailable"
    end

    test "uses the configured build timeout and the default git", %{worktree: worktree} do
      {_output, 0} = System.cmd("git", ["init", "--quiet", worktree])
      File.mkdir_p!(Path.join(worktree, "qa-evidence"))
      File.write!(Path.join(worktree, "qa-evidence/old.png"), "png")
      File.write!(Path.join(worktree, ".gitignore"), "macos/build/\nqa-evidence/\n")
      {_output, 0} = System.cmd("git", ["-C", worktree, "add", ".gitignore"])
      identity = ["-c", "user.name=QA", "-c", "user.email=qa@example.com"]
      {_output, 0} = System.cmd("git", ["-C", worktree | identity] ++ ["commit", "--quiet", "-m", "init"])

      playbook = %{build: "make app", app: @app, build_timeout_ms: 5_000}
      {:ok, driver} = QaDriver.start_link(worktree: worktree, playbook: playbook, host: host())

      assert {:ok, %{"exit_status" => 0, "app" => @app}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert_received {:cmd, "/bin/sh", _args, opts}
      assert opts[:timeout_ms] == 5_000

      File.write!(Path.join(worktree, "stray.swift"), "print(1)")
      assert {:error, {:qa_tool, "qa_worktree_modified", message}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert message =~ "stray.swift"
      QaDriver.stop(driver)
    end
  end

  describe "qa_build" do
    test "refuses a modified worktree but ignores qa-evidence", %{worktree: worktree} do
      git = fn _args, _cwd -> {"?? qa-evidence/a.png\0 M macos/Sources/App.swift\0", 0} end
      driver = start_driver(worktree, git: git)

      assert {:error, {:qa_tool, "qa_worktree_modified", message}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert message =~ "macos/Sources/App.swift"
      refute message =~ "a.png"
      refute_received {:cmd, "/bin/sh", _args, _opts}

      evidence_only = start_driver(worktree, git: fn _args, _cwd -> {"?? qa-evidence/a.png\0", 0} end)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(evidence_only, "qa_build", %{})

      broken_git = start_driver(worktree, git: fn _args, _cwd -> {"fatal: not a git repository", 128} end)
      assert error_code(QaDriver.call_tool(broken_git, "qa_build", %{})) == "qa_git_failed"
    end

    test "refuses gitignored files the agent planted or changed", %{worktree: worktree} do
      {_output, 0} = System.cmd("git", ["init", "--quiet", worktree])
      File.write!(Path.join(worktree, ".gitignore"), "macos/build/\nmacos/.build/\nqa-evidence/\n")
      {_output, 0} = System.cmd("git", ["-C", worktree, "add", ".gitignore"])
      identity = ["-c", "user.name=QA", "-c", "user.email=qa@example.com"]
      {_output, 0} = System.cmd("git", ["-C", worktree | identity] ++ ["commit", "--quiet", "-m", "init"])
      git = fn args, cwd -> System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) end

      # Planted before the first build: the worktree is fresh, so nothing ignored may exist.
      planted = Path.join(worktree, "macos/.build/checkouts/dep/Sources/Dep.swift")
      File.mkdir_p!(Path.dirname(planted))
      File.write!(planted, "evil()")
      File.mkdir_p!(Path.join(worktree, "qa-evidence"))
      File.write!(Path.join(worktree, "qa-evidence/a.png"), "png")
      driver = start_driver(worktree, git: git)
      assert {:error, {:qa_tool, "qa_worktree_modified", message}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert message =~ "macos/.build/checkouts/dep/Sources/Dep.swift"
      refute_received {:cmd, "/bin/sh", _args, _opts}
      File.rm_rf!(Path.join(worktree, "macos/.build"))

      # The build's own ignored outputs are fine, and a rebuild accepts them.
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})

      # A file rewritten after the build, even with its size and mtime restored, is refused.
      plist = Path.join(worktree, @app <> "/Contents/Info.plist")
      %File.Stat{mtime: mtime} = File.stat!(plist, time: :posix)
      File.write!(plist, "<plst/>")
      File.touch!(plist, mtime)
      assert {:error, {:qa_tool, "qa_worktree_modified", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{})
      assert message =~ "Info.plist"
      assert error_code(QaDriver.call_tool(driver, "qa_build", %{})) == "qa_worktree_modified"

      # So is a new ignored file.
      File.write!(plist, "<plist/>")
      fresh = start_driver(worktree, git: git)
      File.rm_rf!(Path.join(worktree, "macos/build"))
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(fresh, "qa_build", %{})
      File.mkdir_p!(Path.dirname(planted))
      File.write!(planted, "evil()")
      assert error_code(QaDriver.call_tool(fresh, "qa_launch_app", %{})) == "qa_worktree_modified"
      assert error_code(QaDriver.call_tool(fresh, "qa_build", %{})) == "qa_worktree_modified"
    end

    test "reports a failing build and forgets the previous one", %{worktree: worktree} do
      driver = start_driver(worktree)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})

      failing = start_driver(worktree, playbook: %{build: "make fail"})
      assert {:ok, %{"exit_status" => 65, "output" => "error: build failed\n"}} = QaDriver.call_tool(failing, "qa_build", %{})
      assert error_code(QaDriver.call_tool(failing, "qa_launch_app", %{})) == "qa_not_built"
    end

    test "reports timeouts, start failures and long output", %{worktree: worktree} do
      timeout = start_driver(worktree, host: host(%{cmd: fn _exe, _args, _opts -> {:error, :timeout} end}))
      assert error_code(QaDriver.call_tool(timeout, "qa_build", %{})) == "qa_build_timeout"

      enoent = start_driver(worktree, host: host(%{cmd: fn _exe, _args, _opts -> {:error, :enoent} end}))
      assert error_code(QaDriver.call_tool(enoent, "qa_build", %{})) == "qa_build_failed"

      noisy_build = fn "/bin/sh", _args, _opts -> {:ok, {String.duplicate("x", 9_000), 1}} end
      noisy = start_driver(worktree, host: host(%{cmd: noisy_build}))
      assert {:ok, %{"exit_status" => 1, "output" => "…" <> rest}} = QaDriver.call_tool(noisy, "qa_build", %{})
      assert byte_size(rest) == 8_000
    end

    test "rejects a bundle path outside the QA worktree", %{root: root, worktree: worktree} do
      outside = start_driver(worktree, playbook: %{app: "../elsewhere/Demo.app"})
      assert {:error, {:qa_tool, "qa_bundle_outside_worktree", message}} = QaDriver.call_tool(outside, "qa_build", %{})
      assert message =~ "outside"

      absolute = start_driver(worktree, playbook: %{app: "/Applications/Demo.app"})
      assert error_code(QaDriver.call_tool(absolute, "qa_build", %{})) == "qa_bundle_outside_worktree"

      # A symlink inside the worktree that points out of it is refused too.
      target = Path.join(root, "elsewhere/Demo.app")
      File.mkdir_p!(Path.join(target, "Contents/MacOS"))
      File.rm_rf!(Path.join(worktree, @app))
      File.ln_s!(target, Path.join(worktree, @app))
      symlinked = start_driver(worktree, host: host(%{cmd: fn _exe, _args, _opts -> {:ok, {"", 0}} end}))
      assert error_code(QaDriver.call_tool(symlinked, "qa_build", %{})) == "qa_bundle_outside_worktree"

      File.write!(Path.join(worktree, "file"), "")
      unresolvable = start_driver(worktree, playbook: %{app: "file/Demo.app"})
      assert {:error, {:qa_tool, "qa_bundle_outside_worktree", message}} = QaDriver.call_tool(unresolvable, "qa_build", %{})
      assert message =~ "could not be resolved"
    end

    test "checks the bundle and its executable", %{root: root, worktree: worktree} do
      no_bundle = start_driver(worktree, host: host(%{cmd: fn _exe, _args, _opts -> {:ok, {"", 0}} end}))
      assert error_code(QaDriver.call_tool(no_bundle, "qa_build", %{})) == "qa_app_missing"

      write_bundle(worktree)

      plutil = fn reply ->
        host(%{
          cmd: fn
            "/usr/bin/plutil", _args, _opts -> reply
            _exe, _args, _opts -> {:ok, {"", 0}}
          end
        })
      end

      for reply <- [{:ok, {"../Demo\n", 0}}, {:ok, {"\n", 0}}, {:ok, {"..", 0}}, {:ok, {"", 1}}, {:error, :timeout}] do
        driver = start_driver(worktree, host: plutil.(reply))
        assert error_code(QaDriver.call_tool(driver, "qa_build", %{})) == "qa_app_missing"
      end

      escaping = Path.join(root, "evil")
      File.write!(escaping, "evil")
      File.rm!(Path.join([worktree, @app, "Contents/MacOS/Demo"]))
      File.ln_s!(escaping, Path.join([worktree, @app, "Contents/MacOS/Demo"]))
      driver = start_driver(worktree, host: plutil.({:ok, {"Demo", 0}}))
      assert error_code(QaDriver.call_tool(driver, "qa_build", %{})) == "qa_executable_outside_bundle"

      File.rm!(Path.join([worktree, @app, "Contents/MacOS/Demo"]))
      File.mkdir_p!(Path.join([worktree, @app, "Contents/MacOS/Demo"]))
      driver = start_driver(worktree, host: plutil.({:ok, {"Demo", 0}}))
      assert error_code(QaDriver.call_tool(driver, "qa_build", %{})) == "qa_app_missing"
    end
  end

  describe "qa_launch_app" do
    test "launches a private copy of what the last build produced", %{worktree: worktree} do
      driver = start_driver(worktree)
      assert error_code(QaDriver.call_tool(driver, "qa_launch_app", %{})) == "qa_not_built"

      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      write_bundle(worktree, "agent-written binary")
      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert {:ok, %{"pid" => _pid}} = result
      assert_received {:launched, executable, _opts, _port, _pid}
      refute String.starts_with?(executable, worktree)
      assert File.read!(executable) == "binary-v1"

      # The copy is checked again before every launch.
      File.write!(executable, "tampered")
      assert error_code(QaDriver.call_tool(driver, "qa_launch_app", %{})) == "qa_app_changed"
      refute_received {:launched, _executable, _opts, _port, _pid}
    end

    test "copies in-bundle symlinks and refuses links that leave the bundle", %{worktree: worktree} do
      build_with_link = fn target ->
        fn
          "/bin/sh", _args, opts ->
            write_bundle(opts[:cd])
            framework = Path.join([opts[:cd], @app, "Contents/Frameworks/Dep.framework"])
            File.mkdir_p!(Path.join(framework, "Versions/A"))
            File.write!(Path.join(framework, "Versions/A/Dep"), "dylib")
            link = Path.join(framework, "Dep")
            File.rm(link)
            File.ln_s!(target, link)
            {:ok, {"", 0}}

          executable, args, opts ->
            default_cmd(executable, args, opts, %{})
        end
      end

      driver = start_driver(worktree, host: host(%{cmd: build_with_link.("Versions/A/Dep")}))
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {_result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert_received {:launched, executable, _opts, _port, _pid}
      copied = Path.join(Path.dirname(Path.dirname(executable)), "Frameworks/Dep.framework/Dep")
      assert File.read_link!(copied) == "Versions/A/Dep"
      assert File.read!(copied) == "dylib"

      for target <- [Path.join(worktree, "evil.dylib"), "../../../../../evil.dylib", "Versions/../../Dep"] do
        driver = start_driver(worktree, host: host(%{cmd: build_with_link.(target)}))
        assert {:error, {:qa_tool, "qa_bundle_unsafe", message}} = QaDriver.call_tool(driver, "qa_build", %{})
        assert message =~ "must be relative"
        assert error_code(QaDriver.call_tool(driver, "qa_launch_app", %{})) == "qa_not_built"
      end

      # A refused bundle still becomes the baseline and drops the earlier build,
      # so its outputs do not block the next attempt as agent edits.
      {:ok, target} = Agent.start_link(fn -> "Versions/A/Dep" end)
      retry = fn executable, args, opts -> build_with_link.(Agent.get(target, & &1)).(executable, args, opts) end
      driver = start_driver(worktree, host: host(%{cmd: retry}))
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      Agent.update(target, fn _target -> Path.join(worktree, "evil.dylib") end)
      assert error_code(QaDriver.call_tool(driver, "qa_build", %{})) == "qa_bundle_unsafe"
      assert error_code(QaDriver.call_tool(driver, "qa_launch_app", %{})) == "qa_not_built"
      Agent.update(target, fn _target -> "Versions/A/Dep" end)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
    end

    test "refuses a bundle with special files or entries it cannot read", %{worktree: worktree} do
      resources = Path.join([worktree, @app, "Contents/Resources"])

      build_with = fn prepare ->
        fn
          "/bin/sh", _args, opts ->
            write_bundle(opts[:cd])
            File.rm_rf!(resources)
            File.mkdir_p!(resources)
            prepare.()
            {:ok, {"", 0}}

          executable, args, opts ->
            default_cmd(executable, args, opts, %{})
        end
      end

      fifo = build_with.(fn -> {_output, 0} = System.cmd("mkfifo", [Path.join(resources, "pipe")]) end)
      driver = start_driver(worktree, host: host(%{cmd: fifo}))
      assert {:error, {:qa_tool, "qa_bundle_unsafe", message}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert message =~ "pipe is not a file, directory or symlink"

      # Listable but not searchable: the entries inside cannot be stat'ed.
      unsearchable = build_with.(fn -> File.write!(Path.join(resources, "a"), "a") && File.chmod!(resources, 0o600) end)
      driver = start_driver(worktree, host: host(%{cmd: unsearchable}))
      assert {:error, {:qa_tool, "qa_bundle_unsafe", message}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert message =~ ":eacces"
      File.chmod!(resources, 0o700)
    end

    test "caps running apps and reports launch failures", %{worktree: worktree} do
      driver = start_driver(worktree)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})

      capture_log(fn ->
        for _index <- 1..3, do: assert({:ok, %{"pid" => _pid}} = QaDriver.call_tool(driver, "qa_launch_app", %{}))
      end)

      assert error_code(QaDriver.call_tool(driver, "qa_launch_app", %{})) == "qa_too_many_apps"

      failing = start_driver(worktree, host: host(%{launch: fn _exe, _opts -> {:error, "exec format error"} end}))
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(failing, "qa_build", %{})
      assert error_code(QaDriver.call_tool(failing, "qa_launch_app", %{})) == "qa_launch_failed"
    end
  end

  describe "launched PIDs" do
    test "every PID tool rejects a PID QA did not launch", %{worktree: worktree} do
      {driver, _pid} = launched_app(worktree)
      stranger = System.pid() |> String.to_integer()

      for {tool, args} <- [
            {"qa_quit_app", %{}},
            {"qa_screenshot", %{"name" => "x"}},
            {"qa_ax_tree", %{}},
            {"qa_ax_press", %{"path" => "0"}},
            {"qa_ax_set_value", %{"path" => "0", "value" => "v"}}
          ] do
        assert {:error, {:qa_tool, "qa_pid_not_launched", message}} = QaDriver.call_tool(driver, tool, Map.put(args, "pid", stranger))
        assert message =~ "not launched by qa_launch_app"
        assert error_code(QaDriver.call_tool(driver, tool, Map.put(args, "pid", "1"))) == "invalid_arguments"
      end

      refute_received {:killed, ^stranger}
      refute_received {:cmd, @helper, _args, _opts}
    end

    test "an exited app reports its status and output", %{worktree: worktree} do
      {driver, pid} = launched_app(worktree)
      assert_received {:launched, _executable, _opts, port, ^pid}

      send(driver, {port, {:data, "Fatal error: crashed\n"}})
      send(driver, {port, {:exit_status, 134}})
      send(driver, {Port.open({:spawn, "cat"}, []), {:data, "unknown port"}})
      send(driver, :unrelated)

      assert {:error, {:qa_tool, "qa_app_exited", message}} = QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid})
      assert message =~ "status 134"
      assert message =~ "Fatal error"

      assert {:ok, %{"exit_status" => 134, "output" => "Fatal error: crashed\n"}} = QaDriver.call_tool(driver, "qa_quit_app", %{"pid" => pid})
      refute_received {:killed, ^pid}
    end

    test "stopping the driver quits running apps", %{worktree: worktree} do
      {driver, pid} = launched_app(worktree)
      QaDriver.stop(driver)
      assert_receive {:killed, ^pid}
      assert QaDriver.stop(nil) == :ok
      assert QaDriver.stop(driver) == :ok
    end
  end

  describe "accessibility and screenshots" do
    test "a missing grant asks the agent to answer blocked", %{worktree: worktree} do
      replies = %{
        "permissions" => {~s({"accessibility":true,"screen_recording":false}), 0},
        "ax-tree" => {~s({"error":{"code":"accessibility_permission_missing","message":"no"}}), 1}
      }

      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: replies}))

      assert {:error, {:qa_tool, "qa_permission_missing", message}} = QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x"})
      assert message =~ "Screen Recording"
      assert message =~ "blocked"

      assert {:error, {:qa_tool, "qa_permission_missing", message}} = QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid})
      assert message =~ "Accessibility"
    end

    test "maps helper errors, timeouts and unreadable output", %{worktree: worktree} do
      replies = %{
        "ax-press" => {~s({"error":{"code":"element_not_found","message":"No element at path 0.9"}}), 1},
        "ax-set-value" => {"Segmentation fault", 139},
        "ax-tree" => {"not json", 0},
        "permissions" => {:error, :timeout},
        "windows" => {:error, :eacces}
      }

      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: replies}))

      assert {:error, {:qa_tool, "qa_element_not_found", "No element at path 0.9"}} =
               QaDriver.call_tool(driver, "qa_ax_press", %{"pid" => pid, "path" => "0.9"})

      assert error_code(QaDriver.call_tool(driver, "qa_ax_set_value", %{"pid" => pid, "path" => "0", "value" => "v"})) == "qa_helper_failed"
      assert error_code(QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid})) == "qa_helper_failed"
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x"})) == "qa_helper_timeout"

      unavailable = host(%{helper: fn -> {:error, :swiftc_not_found} end})
      {driver, pid} = launched_app(worktree, host: unavailable)
      assert {:error, {:qa_tool, "qa_helper_unavailable", message}} = QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid})
      assert message =~ "swiftc_not_found"

      windows_fail = host(%{helper_replies: %{"windows" => {:error, :eacces}}})
      {driver, pid} = launched_app(worktree, host: windows_fail)
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x"})) == "qa_helper_failed"
    end

    test "caps the tree size and validates tree, press and value arguments", %{worktree: worktree} do
      big = Jason.encode!(%{root: %{path: "", title: String.duplicate("x", 100_001)}})
      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: %{"ax-tree" => {big, 0}}}))

      assert {:error, {:qa_tool, "qa_ax_tree_too_large", message}} = QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid})
      assert message =~ "Narrow it"

      for args <- [%{"role" => String.duplicate("R", 65)}, %{"text" => 5}, %{"max_depth" => 0}, %{"max_nodes" => 1001}] do
        assert error_code(QaDriver.call_tool(driver, "qa_ax_tree", Map.put(args, "pid", pid))) == "invalid_arguments"
      end

      for args <- [%{}, %{"path" => "0..1"}, %{"path" => "a"}, %{"path" => "0", "action" => "AXDelete"}] do
        assert error_code(QaDriver.call_tool(driver, "qa_ax_press", Map.put(args, "pid", pid))) == "invalid_arguments"
      end

      for value <- [nil, 5, "a\0b", String.duplicate("v", 10_001)] do
        assert error_code(QaDriver.call_tool(driver, "qa_ax_set_value", %{"pid" => pid, "path" => "0", "value" => value})) == "invalid_arguments"
      end
    end

    test "captures each on-screen window or one window id into qa-evidence", %{worktree: worktree} do
      windows = %{
        windows: [
          %{id: 21, title: "Main", layer: 0, onscreen: true, frame: %{x: 0, y: 0, w: 800, h: 600}},
          %{id: 22, title: "Settings", layer: 0, onscreen: true, frame: %{x: 0, y: 0, w: 548, h: 400}},
          %{id: 23, title: "Menu", layer: 101, onscreen: true, frame: %{x: 0, y: 0, w: 200, h: 120}},
          %{id: 24, title: "Bad frame", layer: 0, onscreen: true}
        ]
      }

      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: %{"windows" => {Jason.encode!(windows), 0}}}))

      assert {:ok, %{"files" => [%{"path" => "qa-evidence/step-1.png"}, %{"path" => "qa-evidence/step-2.png", "title" => "Settings"}]}} =
               QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "step"})

      assert {:ok, %{"files" => [%{"path" => "qa-evidence/menu.png", "window_id" => 23}]}} =
               QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "menu", "window_id" => 23})

      assert File.read!(Path.join(worktree, "qa-evidence/menu.png")) == "png"

      # A taken name is never replaced, and a planted symlink is never followed.
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "menu", "window_id" => 23})) == "qa_screenshot_exists"

      outside = Path.join(System.tmp_dir!(), "qa-driver-outside-#{System.unique_integer([:positive])}")
      File.write!(outside, "keep")
      File.ln_s!(outside, Path.join(worktree, "qa-evidence/planted.png"))
      dangling = Path.join(System.tmp_dir!(), "qa-driver-dangling-#{System.unique_integer([:positive])}")
      File.ln_s!(dangling, Path.join(worktree, "qa-evidence/dangling.png"))

      for name <- ["planted", "dangling"] do
        assert {:error, {:qa_tool, "qa_screenshot_exists", message}} =
                 QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => name, "window_id" => 23})

        assert message =~ "new name"
      end

      assert File.read!(outside) == "keep"
      refute File.exists?(dangling)
      File.rm!(outside)

      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x", "window_id" => 99})) == "qa_window_not_found"
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x", "window_id" => 0})) == "invalid_arguments"

      for name <- [nil, "", "../escape", ".hidden", "a/b", String.duplicate("n", 65)] do
        assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => name})) == "invalid_arguments"
      end
    end

    test "refuses unsafe evidence directories, missing windows and failed captures", %{root: root, worktree: worktree} do
      no_windows = host(%{helper_replies: %{"windows" => {~s({"windows":[]}), 0}}})
      {driver, pid} = launched_app(worktree, host: no_windows)
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x"})) == "qa_no_window"

      File.mkdir_p!(Path.join(root, "outside"))
      File.ln_s!(Path.join(root, "outside"), Path.join(worktree, "qa-evidence"))
      {driver, pid} = launched_app(worktree)
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x"})) == "qa_evidence_unsafe"
      assert File.ls!(Path.join(root, "outside")) == []
      File.rm!(Path.join(worktree, "qa-evidence"))

      # Errors, not crashes, when qa-evidence/ cannot be created or written.
      File.chmod!(worktree, 0o500)
      on_exit(fn -> File.chmod(worktree, 0o755) end)
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x"})) == "qa_evidence_unsafe"
      File.chmod!(worktree, 0o755)

      File.mkdir!(Path.join(worktree, "qa-evidence"))
      File.chmod!(Path.join(worktree, "qa-evidence"), 0o500)
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x"})) == "qa_screenshot_failed"
      File.chmod!(Path.join(worktree, "qa-evidence"), 0o755)

      failing_capture =
        host(%{
          cmd: fn
            "/usr/sbin/screencapture", _args, _opts ->
              {:ok, {"could not create image", 1}}

            executable, args, opts ->
              default_cmd(executable, args, opts, %{"permissions" => {~s({"screen_recording":true}), 0}, "windows" => {~s({"windows":[{"id":5,"layer":0,"onscreen":true,"frame":{"w":10,"h":10}}]}), 0}})
          end
        })

      {driver, pid} = launched_app(worktree, host: failing_capture)
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x"})) == "qa_screenshot_failed"
    end

    test "never copies a symlink planted at the screenshot staging path", %{root: root, worktree: worktree} do
      secret = Path.join(root, "secret")
      File.write!(secret, "host secret")

      planting_capture =
        host(%{
          cmd: fn
            "/usr/sbin/screencapture", args, _opts ->
              File.ln_s!(secret, List.last(args))
              {:ok, {"", 0}}

            executable, args, opts ->
              default_cmd(executable, args, opts, %{"permissions" => {~s({"screen_recording":true}), 0}, "windows" => {~s({"windows":[{"id":5,"layer":0,"onscreen":true,"frame":{"w":10,"h":10}}]}), 0}})
          end
        })

      {driver, pid} = launched_app(worktree, host: planting_capture)
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x"})) == "qa_screenshot_failed"
      refute File.exists?(Path.join(worktree, "qa-evidence/x.png"))
      assert File.read!(secret) == "host secret"
    end
  end

  describe "Host" do
    test "runs commands with an output cap and a timeout" do
      assert {:ok, {"hello\n", 0}} = Host.cmd("/bin/echo", ["hello"], timeout_ms: 5_000)
      assert {:ok, {"lo\n", 0}} = Host.cmd("/bin/echo", ["hello"], timeout_ms: 5_000, output_limit: 3)
      assert {:ok, {_output, 3}} = Host.cmd("/bin/sh", ["-c", "exit 3"], cd: System.tmp_dir!(), env: [{~c"QA", ~c"1"}], timeout_ms: 5_000)
      assert {:error, :timeout} = Host.cmd("/bin/sleep", ["5"], timeout_ms: 100)
      assert {:error, _message} = Host.cmd("/nonexistent/qa", [], timeout_ms: 100)
    end

    test "launches and kills a process" do
      assert {:ok, port, pid} = Host.launch("/bin/cat", cd: System.tmp_dir!(), env: [])
      assert is_port(port)
      assert Host.kill(pid) == :ok
      assert_receive {^port, {:exit_status, _status}}, 5_000
      assert {:error, _message} = Host.launch("/nonexistent/qa", cd: System.tmp_dir!(), env: [])
      assert %{cmd: _cmd, launch: _launch, kill: _kill, helper: _helper} = Host.default()
    end
  end
end
