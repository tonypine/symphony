defmodule SymphonyElixir.QaDriverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AgentEnv, Paths, PathSafety, QaDriver}
  alias SymphonyElixir.QaDriver.Host

  @app "macos/build/Demo.app"
  @helper "/fake/symphony-qa-driver"

  # Stands in for the QA agent's gh stub: it sends the test each call's form
  # fields and answers `api` calls with the default branch, anything else with a
  # 404.
  defmodule GhStub do
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, test: test) do
      {:ok, body, conn} = read_body(conn)
      fields = body |> URI.query_decoder() |> Enum.to_list()
      args = for {"arg", arg} <- fields, do: arg
      send(test, {:gh_call, :proplists.get_value("argc", fields), args})

      case args do
        ["api" | _rest] -> send_resp(conn, 200, "main\n")
        _other -> send_resp(conn, 404, "gh stub: no answer for #{Enum.join(args, " ")}\n")
      end
    end
  end

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
  # helper app answers from `helper_replies` (through `cmd`, so tests see every
  # helper call as a `{:cmd, @helper, args, opts}` message), and its screenshot
  # command writes the file it is given.
  defp host(overrides \\ %{}) do
    test = self()
    replies = replies(overrides)

    cmd = fn executable, args, opts ->
      send(test, {:cmd, executable, args, opts})
      Map.get(overrides, :cmd, &default_cmd(&1, &2, &3, replies)).(executable, args, opts)
    end

    %{
      cmd: cmd,
      call_helper: cmd,
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

  defp replies(overrides) do
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
  end

  defp default_cmd("/bin/sh", ["-c", build], opts, _replies) do
    if build =~ "fail", do: {:ok, {"error: build failed\n", 65}}, else: write_bundle(opts[:cd])
  end

  defp default_cmd("/usr/bin/plutil", _args, _opts, _replies), do: {:ok, {"Demo\n", 0}}

  # The crash report listing: none unless a test's `crash_reports` replies say so.
  defp default_cmd("/bin/sh", ["-c", _script, "sh", "Demo"], _opts, replies), do: Map.get(replies, "crash_reports", {:ok, {"", 0}})

  # The scripts that work in the driver's own directory (the fake gh, a
  # checkout) run for real.
  defp default_cmd("/bin/sh", ["-c", _script, "sh", _dir | _rest] = args, opts, _replies), do: Host.cmd("/bin/sh", args, opts)

  defp default_cmd(@helper, ["screenshot" | _rest] = args, _opts, _replies) do
    File.write!(List.last(args), "png")
    {:ok, {~s({"ok":true}), 0}}
  end

  defp default_cmd(@helper, [command | _rest], _opts, replies) do
    case Map.fetch!(replies, command) do
      {:error, _reason} = error -> error
      result -> {:ok, result}
    end
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
        [
          worktree: worktree,
          playbook: playbook,
          tmp_dir: Keyword.get(opts, :tmp_dir),
          host: Keyword.get(opts, :host, host()),
          git: Keyword.get(opts, :git, &clean_git/2)
        ] ++ Keyword.take(opts, [:start_stub])
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

  defp stub_url(launch_opts) do
    {_name, url} = Enum.find(launch_opts[:env], fn {name, _value} -> name == ~c"SYMPHONY_QA_OPENROUTER_URL" end)
    to_string(url)
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  describe "tools" do
    test "hands out three free host ports and opens no tunnel for a local app", %{worktree: worktree} do
      driver = start_driver(worktree)
      assert {:ok, [_one, _two, _three] = ports} = QaDriver.host_ports(driver)
      assert length(Enum.uniq(ports)) == 3
      assert %{tunnel: nil} = :sys.get_state(driver)
      assert QaDriver.host_ports(nil) == {:ok, []}
    end

    test "lists the qa tools and needs a driver" do
      assert "qa_build" in QaDriver.tools()
      assert "qa_ax_set_value" in QaDriver.tools()
      assert "qa_put_file" in QaDriver.tools()
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
    test "gives the build the host ports the QA agent gets", %{worktree: worktree} do
      bundle = "mkdir -p #{@app}/Contents/MacOS && touch #{@app}/Contents/Info.plist #{@app}/Contents/MacOS/Demo"

      cmd = fn
        "/bin/sh", ["-c", _build] = args, opts -> Host.cmd("/bin/sh", args, opts)
        executable, args, opts -> default_cmd(executable, args, opts, replies(%{}))
      end

      driver = start_driver(worktree, host: host(%{cmd: cmd}), playbook: %{build: ~s(echo "$QA_HOST_PORTS" && #{bundle})})
      assert {:ok, ports} = QaDriver.host_ports(driver)

      assert {:ok, %{"exit_status" => 0, "output" => output}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert output == Enum.join(ports, ",") <> "\n"
    end

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

    test "accepts the folders the QA agent's launch env creates, with or without Gradle", %{root: root} do
      identity = ["-c", "user.name=QA", "-c", "user.email=qa@example.com"]
      git = fn args, cwd -> System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) end

      for {name, files} <- [plain: [".gitignore"], gradle: [".gitignore", "settings.gradle.kts"]] do
        worktree = Path.join(root, Atom.to_string(name))
        {_output, 0} = System.cmd("git", ["init", "--quiet", worktree])
        Enum.each(files, &File.touch!(Path.join(worktree, &1)))
        File.write!(Path.join(worktree, ".gitignore"), "macos/build/\nqa-evidence/\n")
        {_output, 0} = System.cmd("git", ["-C", worktree, "add" | files])
        {_output, 0} = System.cmd("git", ["-C", worktree | identity] ++ ["commit", "--quiet", "-m", "init"])

        env = AgentEnv.gradle_env(worktree)
        assert Map.has_key?(env, "GRADLE_OPTS") == (name == :gradle)
        assert File.dir?(Path.join(worktree, ".gradle-daemons")) == (name == :gradle)

        driver = start_driver(worktree, git: git)
        assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})

        # A daemon the QA agent started registers there after the build.
        File.mkdir_p!(Path.join(worktree, ".gradle-daemons/9.8.0"))
        File.write!(Path.join(worktree, ".gradle-daemons/9.8.0/registry.bin"), "daemons")
        assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      end

      # A change to a tracked file there still counts.
      git = fn _args, _cwd -> {" M .gradle-daemons/tracked.txt\0?? .gradle-daemons/new.txt\0!! .gradle-daemons/.gitignore\0", 0} end
      driver = start_driver(Path.join(root, "plain"), git: git)
      assert {:error, {:qa_tool, "qa_worktree_modified", message}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert message =~ ".gradle-daemons/tracked.txt"
      refute message =~ "new.txt"
      refute message =~ ".gitignore"
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

      # A timed-out build's partial outputs do not block the next attempt.
      {_output, 0} = System.cmd("git", ["init", "--quiet", worktree])
      File.write!(Path.join(worktree, ".gitignore"), "macos/.build/\nqa-evidence/\n")
      {_output, 0} = System.cmd("git", ["-C", worktree, "add", ".gitignore"])
      identity = ["-c", "user.name=QA", "-c", "user.email=qa@example.com"]
      {_output, 0} = System.cmd("git", ["-C", worktree | identity] ++ ["commit", "--quiet", "-m", "init"])
      git = fn args, cwd -> System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) end
      partial = Path.join(worktree, "macos/.build/partial.o")

      slow_build = fn "/bin/sh", _args, _opts ->
        File.mkdir_p!(Path.dirname(partial))
        File.write!(partial, "obj")
        {:error, :timeout}
      end

      slow = start_driver(worktree, git: git, host: host(%{cmd: slow_build}))
      assert error_code(QaDriver.call_tool(slow, "qa_build", %{})) == "qa_build_timeout"
      assert error_code(QaDriver.call_tool(slow, "qa_build", %{})) == "qa_build_timeout"
      assert error_code(QaDriver.call_tool(slow, "qa_launch_app", %{})) == "qa_not_built"
      File.rm_rf!(Path.join(worktree, "macos/.build"))
      File.rm_rf!(Path.join(worktree, ".git"))
      File.rm!(Path.join(worktree, ".gitignore"))

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
          "/bin/sh", ["-c", _build], opts ->
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

    test "starts one OpenRouter stub for the pass and points every app at it", %{worktree: worktree} do
      {driver, _pid} = launched_app(worktree)
      assert_received {:launched, _executable, launch_opts, _port, _pid}
      assert launch_opts[:reverse_forwards] == []
      url = stub_url(launch_opts)
      assert url =~ ~r{\Ahttp://127\.0\.0\.1:\d+/api\z}
      assert Req.get!(url <> "/v1/models", retry: false).status == 200

      {_result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert_received {:launched, _executable, second_opts, _port, _pid}
      assert stub_url(second_opts) == url

      # A stub that died is started again for the next launch.
      %{stub: %{pid: stub}} = :sys.get_state(driver)
      ref = Process.monitor(stub)
      Process.exit(stub, :kill)
      assert_receive {:DOWN, ^ref, :process, ^stub, :killed}
      wait_until(fn -> :sys.get_state(driver).stub == nil end)

      {_result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert_received {:launched, _executable, third_opts, _port, _pid}
      assert Req.get!(stub_url(third_opts) <> "/v1/models", retry: false).status == 200

      # Stopping the driver stops the stub.
      %{stub: %{pid: restarted}} = :sys.get_state(driver)
      ref = Process.monitor(restarted)
      QaDriver.stop(driver)
      assert_receive {:DOWN, ^ref, :process, ^restarted, _reason}
    end

    test "fails the launch when the OpenRouter stub can't start", %{worktree: worktree} do
      driver = start_driver(worktree, start_stub: fn -> {:error, :eaddrinuse} end)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert {:error, {:qa_tool, "qa_launch_failed", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{})
      assert message =~ "OpenRouter stub"
      assert message =~ ":eaddrinuse"
      refute_received {:launched, _executable, _opts, _port, _pid}
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
      assert message =~ "Mark the app steps you could not check `blocked` with this reason, finish the other playbooks' steps"
      assert message =~ "then answer with verdict `blocked` and this reason"

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
            @helper, ["screenshot" | _rest], _opts ->
              {:ok, {~s({"error":{"code":"screenshot_failed","message":"no image"}}), 1}}

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
            @helper, ["screenshot" | _rest] = args, _opts ->
              File.ln_s!(secret, List.last(args))
              {:ok, {~s({"ok":true}), 0}}

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

  describe "qa_put_file" do
    defp put_file(driver, args), do: QaDriver.call_tool(driver, "qa_put_file", args)

    defp write_fixture!(path, contents \\ "repos: []\n") do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
      path
    end

    test "returns the path of a fixture in qa-evidence or $TMPDIR without copying it", %{root: root, worktree: worktree} do
      tmp_real = Path.join(root, "tmp-real")
      File.mkdir_p!(tmp_real)
      tmp_link = Path.join(root, "tmp-link")
      File.ln_s!(tmp_real, tmp_link)
      driver = start_driver(worktree, tmp_dir: tmp_link)

      fixture = write_fixture!(Path.join(worktree, "qa-evidence/qa-config/symphony.yml"))
      assert {:ok, %{"path" => ^fixture, "bytes" => 10}} = put_file(driver, %{"local_path" => "qa-evidence/qa-config/symphony.yml"})
      assert {:ok, %{"path" => ^fixture}} = put_file(driver, %{"local_path" => fixture, "remote_name" => "other.yml"})

      write_fixture!(Path.join(tmp_real, "qa/WORKFLOW.md"), "")
      expected = Path.join(tmp_real, "qa/WORKFLOW.md")
      assert {:ok, %{"path" => ^expected, "bytes" => 0}} = put_file(driver, %{"local_path" => Path.join(tmp_link, "qa/WORKFLOW.md")})
    end

    test "refuses files outside the worktree and $TMPDIR, links, non-regular and oversized files", %{root: root, worktree: worktree} do
      driver = start_driver(worktree)
      outside = write_fixture!(Path.join(root, "outside/secret.yml"))
      evidence = Path.join(worktree, "qa-evidence")
      fixture = write_fixture!(Path.join(evidence, "symphony.yml"))
      File.ln_s!(outside, Path.join(evidence, "link.yml"))
      File.ln_s!(Path.dirname(outside), Path.join(evidence, "outside-dir"))
      File.ln_s!("loop", Path.join(evidence, "loop"))
      File.ln!(fixture, Path.join(evidence, "hard.yml"))
      write_fixture!(Path.join(evidence, "big.yml"), String.duplicate("x", 1_000_001))
      locked = write_fixture!(Path.join(evidence, "locked.yml"))
      File.chmod!(locked, 0o000)

      for {local_path, expected} <- [
            {outside, "is outside the QA worktree and $TMPDIR"},
            {"../outside/secret.yml", "is outside the QA worktree and $TMPDIR"},
            {"qa-evidence/outside-dir/secret.yml", "is outside the QA worktree and $TMPDIR"},
            {"qa-evidence/link.yml", "is a symlink"},
            {"qa-evidence/loop/x.yml", "could not be read: :eloop"},
            {"qa-evidence/missing.yml", "could not be read: :enoent"},
            {"qa-evidence", "is not a regular file"},
            {"qa-evidence/hard.yml", "has other hard links"},
            {"qa-evidence/big.yml", "is over 1000000 bytes"},
            {"qa-evidence/locked.yml", "could not be read: :eacces"}
          ] do
        assert {:error, {:qa_tool, "qa_put_file_refused", message}} = put_file(driver, %{"local_path" => local_path})
        assert message =~ expected, "#{local_path}: #{message}"
      end
    end

    test "refuses bad arguments", %{worktree: worktree} do
      driver = start_driver(worktree)

      for args <- [%{}, %{"local_path" => ""}, %{"local_path" => 7}, %{"local_path" => "a\0b"}] do
        assert {:error, {:qa_tool, "invalid_arguments", message}} = put_file(driver, args)
        assert message =~ "local_path"
      end

      for args <- [
            %{"local_path" => "qa-evidence/a.yml", "remote_name" => "../a.yml"},
            %{"local_path" => "qa-evidence/a.yml", "remote_name" => ".hidden"},
            %{"local_path" => "qa-evidence/a.yml", "remote_name" => 5},
            %{"local_path" => "qa-evidence/my config.yml"}
          ] do
        assert {:error, {:qa_tool, "invalid_arguments", message}} = put_file(driver, args)
        assert message =~ "remote_name"
      end
    end
  end

  describe "app stand-ins" do
    # A git bundle of a repo with `files`, made the way the playbook says.
    defp bundle!(dir, files) do
      repo = Path.join(dir, "repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      for {name, contents} <- files, do: File.write!(Path.join(repo, name), contents)
      git = fn args -> {_output, 0} = System.cmd("git", ["-c", "user.name=QA", "-c", "user.email=qa@example.com" | args], cd: repo, stderr_to_stdout: true) end
      git.(["init", "--quiet", "--initial-branch=main"])
      git.(["add", "."])
      git.(["commit", "--quiet", "-m", "fixture"])
      bundle = repo <> ".bundle"
      git.(["bundle", "create", bundle, "--all"])
      bundle
    end

    defp put_checkout(driver, args), do: QaDriver.call_tool(driver, "qa_put_checkout", args)

    test "the launched app runs Symphony's fake gh, which hands each call to the agent's gh stub", %{root: root, worktree: worktree} do
      app = """
      #!/bin/sh
      "$SYMPHONY_BAR_GH" api repos/acme/widgets --jq .default_branch; echo "first=$?"
      "$SYMPHONY_BAR_GH" pr create --title 'Add WORKFLOW.md' --body 'two
      lines & = %'; echo "second=$?"
      SYMPHONY_QA_GH_URL= "$SYMPHONY_BAR_GH" auth status; echo "third=$?"
      SYMPHONY_QA_GH_URL=http://127.0.0.1:1 "$SYMPHONY_BAR_GH" auth status; echo "fourth=$?"
      """

      build = fn
        "/bin/sh", ["-c", "make app"], opts ->
          write_bundle(opts[:cd], app)
          File.chmod!(Path.join([opts[:cd], @app, "Contents/MacOS/Demo"]), 0o755)
          {:ok, {"", 0}}

        executable, args, opts ->
          default_cmd(executable, args, opts, %{})
      end

      driver = start_driver(worktree, tmp_dir: root, host: host(%{cmd: build, launch: &Host.launch/2}))
      {:ok, [port | _rest]} = QaDriver.host_ports(driver)
      start_supervised!({Bandit, plug: {GhStub, test: self()}, ip: {127, 0, 0, 1}, port: port, startup_log: false})

      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{"gh_stub_port" => port}) end)
      assert {:ok, %{"pid" => pid}} = result
      wait_until(fn -> :sys.get_state(driver).apps[pid].exit_status != nil end, 1_000)
      assert {:ok, %{"output" => output, "exit_status" => 0}} = QaDriver.call_tool(driver, "qa_quit_app", %{"pid" => pid})

      assert_received {:gh_call, "4", ["api", "repos/acme/widgets", "--jq", ".default_branch"]}
      assert_received {:gh_call, "6", ["pr", "create", "--title", "Add WORKFLOW.md", "--body", "two\nlines & = %"]}
      assert output =~ "main\nfirst=0\n"
      assert output =~ "gh stub: no answer for pr create --title Add WORKFLOW.md --body two\nlines & = %\nsecond=1\n"
      assert output =~ "SYMPHONY_QA_GH_URL is not set\nthird=1\n"
      assert output =~ "couldn't reach the gh stub at http://127.0.0.1:1\nfourth=1\n"

      %{scratch_dir: scratch_dir} = GenServer.call(driver, :config)
      assert File.stat!(Path.join(scratch_dir, "bin/gh")).mode |> Bitwise.band(0o777) == 0o700
    end

    test "puts a checkout of a bundle and opens the folder picker in it", %{root: root, worktree: worktree} do
      driver = start_driver(worktree, tmp_dir: root)
      bundle = bundle!(root, %{"package.json" => "{}\n"})

      assert {:ok, %{"path" => path, "remote_url" => "https://github.com/acme/widgets.git"}} =
               put_checkout(driver, %{"local_path" => bundle, "remote_url" => "https://github.com/acme/widgets"})

      %{scratch_dir: scratch_dir} = GenServer.call(driver, :config)
      assert path == Path.join(scratch_dir, "checkouts/widgets")
      assert File.read!(Path.join(path, "package.json")) == "{}\n"
      assert {"https://github.com/acme/widgets.git\n", 0} = System.cmd("git", ["-C", path, "remote", "get-url", "origin"])
      assert {"origin/main\n", 0} = System.cmd("git", ["-C", path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
      assert File.ls!(scratch_dir) |> Enum.filter(&String.ends_with?(&1, ".bundle")) == []

      assert {:ok, %{"path" => other}} =
               put_checkout(driver, %{"local_path" => bundle, "remote_url" => "https://github.com/acme/widgets.git", "remote_name" => "with-workflow"})

      assert other == Path.join(scratch_dir, "checkouts/with-workflow")

      assert {:error, {:qa_tool, "qa_put_checkout_failed", message}} =
               put_checkout(driver, %{"local_path" => bundle, "remote_url" => "https://github.com/acme/widgets"})

      assert message =~ "already exists; pass another remote_name"

      {:ok, [gh_port, linear_port | _rest]} = QaDriver.host_ports(driver)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      args = %{"gh_stub_port" => gh_port, "linear_stub_port" => linear_port, "open_panel_dir" => path}
      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", args) end)
      assert {:ok, %{"pid" => _pid}} = result
      assert_received {:launched, _executable, launch_opts, _port, _pid}
      env = Map.new(launch_opts[:env])
      assert env[~c"SYMPHONY_BAR_GH"] == String.to_charlist(Path.join(scratch_dir, "bin/gh"))
      assert env[~c"SYMPHONY_QA_GH_URL"] == ~c"http://localhost:#{gh_port}"
      assert env[~c"SYMPHONY_QA_LINEAR_URL"] == ~c"http://localhost:#{linear_port}/graphql"
      assert env[~c"SYMPHONY_BAR_QA_OPEN_PANEL_DIR"] == String.to_charlist(path)

      # Without stand-in arguments the app gets none of them.
      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert {:ok, %{"pid" => _pid}} = result
      assert_received {:launched, _executable, launch_opts, _port, _pid}
      refute Enum.any?(launch_opts[:env], fn {name, _value} -> name in [~c"SYMPHONY_BAR_GH", ~c"SYMPHONY_QA_LINEAR_URL", ~c"SYMPHONY_BAR_QA_OPEN_PANEL_DIR"] end)
    end

    test "refuses stand-in arguments it can't honour", %{worktree: worktree} do
      driver = start_driver(worktree)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {:ok, [port | _rest] = ports} = QaDriver.host_ports(driver)
      unused = Enum.find(40_000..60_000, &(&1 not in ports))

      for {args, expected} <- [
            {%{"gh_stub_port" => unused}, "`gh_stub_port` must be one of QA_HOST_PORTS (#{Enum.join(ports, ", ")})"},
            {%{"gh_stub_port" => "#{port}"}, "`gh_stub_port` must be one of QA_HOST_PORTS"},
            {%{"linear_stub_port" => unused}, "`linear_stub_port` must be one of QA_HOST_PORTS"},
            {%{"open_panel_dir" => "/Users/qa/repo"}, "`open_panel_dir` must be a path qa_put_checkout returned"}
          ] do
        assert {:error, {:qa_tool, "invalid_arguments", message}} = QaDriver.call_tool(driver, "qa_launch_app", args)
        assert message =~ expected
      end

      refute_received {:launched, _executable, _opts, _port, _pid}

      for reply <- [{:ok, {"mkdir: denied\n", 1}}, {:ok, {"", 0}}, {:error, :timeout}] do
        cmd = fn
          "/bin/sh", ["-c", _script, "sh", _dir, "#!/bin/sh" <> _fake], _opts -> reply
          executable, args, opts -> default_cmd(executable, args, opts, %{})
        end

        driver = start_driver(worktree, host: host(%{cmd: cmd}))
        assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
        {:ok, [port | _rest]} = QaDriver.host_ports(driver)
        assert {:error, {:qa_tool, "qa_launch_failed", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{"gh_stub_port" => port})
        assert message =~ "fake gh could not be installed"
      end
    end

    test "refuses a checkout it can't make", %{root: root, worktree: worktree} do
      driver = start_driver(worktree, tmp_dir: root)
      bundle = bundle!(root, %{"README.md" => "hi\n"})
      junk = Path.join(root, "junk.bundle")
      File.write!(junk, "not a bundle")

      for {args, expected} <- [
            {%{"remote_url" => "https://github.com/acme/widgets"}, "`local_path` is required"},
            {%{"local_path" => bundle}, "`remote_url` must be a GitHub repo URL"},
            {%{"local_path" => bundle, "remote_url" => "https://gitlab.com/acme/widgets"}, "`remote_url` must be a GitHub repo URL"},
            {%{"local_path" => bundle, "remote_url" => "https://github.com/acme/widgets/tree/main"}, "`remote_url` must be a GitHub repo URL"},
            {%{"local_path" => bundle, "remote_url" => "https://github.com/acme/widgets", "remote_name" => "../x"}, "`remote_name` must be"}
          ] do
        assert {:error, {:qa_tool, "invalid_arguments", message}} = put_checkout(driver, args)
        assert message =~ expected
      end

      outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}.bundle")
      File.write!(outside, "x")
      on_exit(fn -> File.rm(outside) end)

      assert {:error, {:qa_tool, "qa_put_checkout_refused", message}} =
               put_checkout(driver, %{"local_path" => outside, "remote_url" => "https://github.com/acme/widgets"})

      assert message =~ "is outside the QA worktree and $TMPDIR"

      assert {:error, {:qa_tool, "qa_put_checkout_failed", message}} =
               put_checkout(driver, %{"local_path" => junk, "remote_url" => "https://github.com/acme/widgets"})

      assert message =~ "git could not clone the bundle (exit 1)"
      assert message =~ "git bundle create <file> --all"
      %{scratch_dir: scratch_dir} = GenServer.call(driver, :config)
      refute File.exists?(Path.join(scratch_dir, "checkouts/widgets"))

      for {reply, expected} <- [{{:ok, {"cloned\n", 0}}, "was not confirmed: cloned"}, {{:error, :timeout}, "could not clone the bundle: :timeout"}] do
        cmd = fn
          "/bin/sh", ["-c", _script, "sh", _dir, _bundle, _name, _url], _opts -> reply
          executable, args, opts -> default_cmd(executable, args, opts, %{})
        end

        driver = start_driver(worktree, tmp_dir: root, host: host(%{cmd: cmd}))
        assert {:error, {:qa_tool, "qa_put_checkout_failed", message}} = put_checkout(driver, %{"local_path" => bundle, "remote_url" => "https://github.com/acme/widgets"})
        assert message =~ expected
      end
    end
  end

  describe "worker_host" do
    @run_dir "/Users/qa/.symphony-qa/runs/run.abc123"

    # A stubbed QA host: the build and bundle script answer without touching the
    # local disk, and `read` returns the capture.
    defp remote_host(overrides \\ %{}) do
      test = self()
      bundle = Map.get(overrides, :bundle, fn dest -> {:ok, {"symphony-qa-app:#{dest}/Demo.app/Contents/MacOS/Demo\n", 0}} end)

      cmd = fn
        "/bin/sh", ["-c", "make app"], _opts -> {:ok, {"Build complete!\n", 0}}
        "/bin/sh", ["-c", _script, "sh", _build_dir, @app, dest], _opts -> bundle.(dest)
        "/bin/sh", ["-c", _script, "sh", @run_dir, _bundle, name, _url], _opts -> {:ok, {"symphony-qa-checkout:#{@run_dir}/checkouts/#{name}\n", 0}}
        "/bin/sh", ["-c", _script, "sh", @run_dir, _fake_gh], _opts -> {:ok, {"symphony-qa-gh:#{@run_dir}/bin/gh\n", 0}}
        @helper, ["screenshot" | _args], _opts -> {:ok, {~s({"ok":true}), 0}}
        executable, args, opts -> default_cmd(executable, args, opts, replies(Map.take(overrides, [:helper_replies])))
      end

      Map.merge(host(%{cmd: cmd}), %{
        prepare: fn home, canary ->
          send(test, {:prepare, home, canary, File.stat!(canary).mode})
          Map.get(overrides, :prepare, {:ok, @run_dir})
        end,
        ship: fn tar, dest -> send(test, {:ship, tar, dest}) && Map.get(overrides, :ship, :ok) end,
        read: fn path -> send(test, {:read, path}) && Map.get(overrides, :read, {:ok, "png"}) end,
        put: fn local, dir, name ->
          send(test, {:put, local, File.read!(local), dir, name})
          Map.get(overrides, :put, {:ok, "#{dir}/files/#{name}"})
        end,
        helper: fn dir -> send(test, {:helper, dir}) && {:ok, @helper} end,
        tunnel: fn ports -> send(test, {:tunnel, ports}) && Map.get(overrides, :tunnel, &open_tunnel/0).() end,
        cleanup: fn dir -> send(test, {:cleanup, dir}) && :ok end
      })
    end

    # Stands in for the tunnel's SSH session: it prints a line as `ssh` may, then
    # runs until its stdin closes, or exits when the test writes a line to it.
    defp open_tunnel, do: {:ok, Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", "echo warning; read line; exit 3"]])}

    # Answers each tunnel request with the next of `results`.
    defp tunnel_results(results) do
      {:ok, agent} = Agent.start_link(fn -> results end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      fn -> agent |> Agent.get_and_update(fn [result | rest] -> {result, rest} end) |> tunnel_result() end
    end

    defp tunnel_result(:open), do: open_tunnel()
    defp tunnel_result(error), do: error

    defp remote_git(["archive" | _args], _cwd), do: {"fatal: not a valid object name HEAD\n", 128}
    defp remote_git(args, cwd), do: clean_git(args, cwd)

    defp remote_driver(worktree, host, git \\ &clean_git/2) do
      {{:ok, driver}, _log} =
        with_log(fn ->
          QaDriver.start_link(
            worktree: worktree,
            worker_host: "qa@qa-vm",
            playbook: %{build: "make app", app: @app},
            host: host,
            git: git
          )
        end)

      on_exit(fn -> QaDriver.stop(driver) end)
      driver
    end

    test "builds, launches and captures on the QA host", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host())
      %{scratch_dir: scratch_dir} = GenServer.call(driver, :config)

      assert_received {:prepare, home, canary, mode}
      assert home == System.user_home!()
      assert canary == Path.join(scratch_dir, "canary")
      assert Bitwise.band(mode, 0o777) == 0o600

      assert {:ok, %{"exit_status" => 0, "app" => @app}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert_received {:ship, tar, dest}
      assert tar == Path.join(scratch_dir, "src.tar")
      assert dest == @run_dir <> "/src"
      refute File.exists?(tar)
      assert_received {:cmd, "/bin/sh", ["-c", "make app"], build_opts}
      assert build_opts[:cd] == @run_dir <> "/src"
      assert_received {:tunnel, ports}
      assert build_opts[:remote_env] == [{"QA_HOST_PORTS", Enum.join(ports, ",")}]
      assert_received {:cmd, "/bin/sh", ["-c", _script, "sh", @run_dir <> "/src", @app, bundle_dest], _opts}
      assert String.starts_with?(bundle_dest, @run_dir <> "/builds/")

      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert {:ok, %{"pid" => pid}} = result
      assert_received {:launched, executable, launch_opts, _port, ^pid}
      assert executable == bundle_dest <> "/Demo.app/Contents/MacOS/Demo"
      assert launch_opts[:cd] == @run_dir <> "/app-root"
      # The app's SSH session forwards a loopback port on the QA host back to this pass's stub.
      assert [{"SYMPHONY_BAR_QA_ROOT", qa_root}, {"SYMPHONY_QA_OPENROUTER_URL", stub_url}] = launch_opts[:env]
      assert qa_root == @run_dir <> "/app-root"
      %{stub: %{port: stub_port}} = :sys.get_state(driver)
      assert [{"127.0.0.1:" <> remote_port, local}] = launch_opts[:reverse_forwards]
      assert local == "127.0.0.1:#{stub_port}"
      assert stub_url == "http://127.0.0.1:#{remote_port}/api"
      assert String.to_integer(remote_port) in 20_000..59_999

      assert {:ok, %{"files" => [%{"path" => "qa-evidence/settings.png"}]}} = QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "settings"})
      assert_received {:cmd, @helper, ["screenshot", _pid, "11", capture], _opts}
      assert capture == @run_dir <> "/window-11.png"
      assert_received {:read, ^capture}
      assert File.read!(Path.join(worktree, "qa-evidence/settings.png")) == "png"
      assert_received {:helper, @run_dir}

      assert {:ok, %{"root" => _root}} = QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid})
      refute_received {:helper, _dir}

      QaDriver.stop(driver)
      assert_received {:killed, ^pid}
      assert_received {:cleanup, @run_dir}
      refute File.exists?(scratch_dir)
    end

    test "compiles a fresh helper for each pass", %{worktree: worktree} do
      other_run_dir = "/Users/qa/.symphony-qa/runs/run.def456"

      for run_dir <- [@run_dir, other_run_dir] do
        driver = remote_driver(worktree, remote_host(%{prepare: {:ok, run_dir}}))
        assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
        {{:ok, %{"pid" => pid}}, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)

        assert {:ok, %{"root" => _root}} = QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid})
        assert_received {:helper, ^run_dir}
        QaDriver.stop(driver)
      end
    end

    test "refuses an unsafe or unreachable QA host", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host(%{prepare: {:error, {:unsafe, "has a private key ~/.ssh/id_ed25519"}}}))

      for tool <- ["qa_build", "qa_launch_app", "qa_screenshot"] do
        assert {:error, {:qa_tool, "qa_worker_unsafe", message}} = QaDriver.call_tool(driver, tool, %{})
        assert message =~ "The QA host qa@qa-vm has a private key ~/.ssh/id_ed25519."
      end

      QaDriver.stop(driver)
      refute_received {:cleanup, _dir}

      driver = remote_driver(worktree, remote_host(%{prepare: {:error, {:unreachable, "ssh exited with status 255"}}}))
      assert {:error, {:qa_tool, "qa_worker_unreachable", message}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert message =~ "could not be prepared: ssh exited with status 255"
    end

    test "forwards the host ports from the QA host for the whole pass", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host())
      assert_received {:tunnel, ports}
      assert QaDriver.host_ports(driver) == {:ok, ports}
      assert length(ports) == 3 and length(Enum.uniq(ports)) == 3
      %{tunnel: tunnel} = :sys.get_state(driver)
      assert Port.info(tunnel)

      QaDriver.stop(driver)
      refute Port.info(tunnel)
    end

    test "retries a port the QA host refuses on fresh ports, then reports why the tunnel could not open", %{worktree: worktree} do
      taken = {:error, {:port_taken, "ssh exited with status 255: Error: remote port forwarding failed for listen port 50001"}}
      driver = remote_driver(worktree, remote_host(%{tunnel: tunnel_results([taken, :open])}))
      assert_received {:tunnel, refused}
      assert_received {:tunnel, ports}
      assert refused != ports
      assert QaDriver.host_ports(driver) == {:ok, ports}

      driver = remote_driver(worktree, remote_host(%{tunnel: tunnel_results([taken, taken, taken])}))
      assert {:error, "ssh exited with status 255: Error: remote port forwarding failed" <> _rest} = QaDriver.host_ports(driver)
      for _attempt <- 1..3, do: assert_received({:tunnel, _ports})

      driver = remote_driver(worktree, remote_host(%{tunnel: tunnel_results([{:error, {:failed, "ssh exited with status 255: Connection refused"}}])}))
      assert QaDriver.host_ports(driver) == {:error, "ssh exited with status 255: Connection refused"}
      assert_received {:tunnel, _ports}
      refute_received {:tunnel, _ports}
    end

    test "builds without QA_HOST_PORTS when the tunnel could not open", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host(%{tunnel: tunnel_results([{:error, {:failed, "Connection refused"}}])}))
      assert {:error, "Connection refused"} = QaDriver.host_ports(driver)

      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert_received {:cmd, "/bin/sh", ["-c", "make app"], build_opts}
      assert build_opts[:remote_env] == []
      refute List.keymember?(build_opts[:env], ~c"QA_HOST_PORTS", 0)
    end

    test "opens no tunnel to a QA host it refused", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host(%{prepare: {:error, {:unsafe, "has a forwarded SSH agent"}}}))
      assert {:ok, [_one, _two, _three]} = QaDriver.host_ports(driver)
      refute_received {:tunnel, _ports}
    end

    test "reopens a tunnel that closed at the next launch, and fails the launch when it cannot", %{worktree: worktree} do
      failed = {:error, {:failed, "ssh exited with status 255: Connection refused"}}
      driver = remote_driver(worktree, remote_host(%{tunnel: tunnel_results([:open, :open, failed])}))
      assert_received {:tunnel, ports}
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})

      assert capture_log(fn -> close_tunnel(driver) end) =~ "host-port tunnel closed status=3"
      {{:ok, %{"pid" => _pid}}, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert_received {:tunnel, ^ports}

      capture_log(fn -> close_tunnel(driver) end)
      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert {:error, {:qa_tool, "qa_host_tunnel_failed", message}} = result
      assert message =~ "QA_HOST_PORTS (#{Enum.join(ports, ", ")}) from the QA host closed and could not reopen: ssh exited with status 255: Connection refused."
      assert message =~ "answer with verdict `blocked`"
    end

    test "reports a failed copy to the QA host", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host(), &remote_git/2)
      assert {:error, {:qa_tool, "qa_git_failed", message}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert message =~ "not a valid object name"
      refute_received {:ship, _tar, _dest}

      driver = remote_driver(worktree, remote_host(%{ship: {:error, "exit 2: tar: write error"}}))
      assert {:error, {:qa_tool, "qa_build_failed", message}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert message =~ "could not be copied to the QA host: exit 2: tar: write error"
      refute_received {:cmd, "/bin/sh", ["-c", "make app"], _opts}
    end

    test "reports a bundle the QA host cannot use", %{worktree: worktree} do
      for {reply, expected} <- [
            {{:ok, {"macos/build/Demo.app is not a directory\n", 1}}, "macos/build/Demo.app is not a directory"},
            {{:ok, {"copied\n", 0}}, "copied"},
            {{:error, :timeout}, ":timeout"}
          ] do
        driver = remote_driver(worktree, remote_host(%{bundle: fn _dest -> reply end}))
        assert {:error, {:qa_tool, "qa_app_missing", message}} = QaDriver.call_tool(driver, "qa_build", %{})
        assert message =~ "not a usable .app on the QA host: #{expected}"
        assert error_code(QaDriver.call_tool(driver, "qa_launch_app", %{})) == "qa_not_built"
      end
    end

    test "names the QA host's SSH grant when a permission is missing", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host(%{helper_replies: %{"permissions" => {~s({"accessibility":true,"screen_recording":false}), 0}}}))
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {{:ok, %{"pid" => pid}}, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)

      assert {:error, {:qa_tool, "qa_permission_missing", message}} = QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "x"})
      assert message =~ "SSH on the QA host has no Screen Recording permission"
      assert message =~ "/usr/libexec/sshd-keygen-wrapper on the QA host"
    end

    test "copies a checked fixture into the run directory", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host())
      %{scratch_dir: scratch_dir} = GenServer.call(driver, :config)
      fixture = Path.join(worktree, "qa-evidence/qa-config/symphony.yml")
      File.mkdir_p!(Path.dirname(fixture))
      File.write!(fixture, "repos: []\n")

      assert {:ok, %{"path" => @run_dir <> "/files/symphony.yml", "bytes" => 10}} =
               QaDriver.call_tool(driver, "qa_put_file", %{"local_path" => "qa-evidence/qa-config/symphony.yml"})

      assert_received {:put, local, "repos: []\n", @run_dir, "symphony.yml"}
      assert String.starts_with?(local, scratch_dir <> "/")
      refute File.exists?(local)

      assert {:ok, %{"path" => @run_dir <> "/files/settings.yml"}} =
               QaDriver.call_tool(driver, "qa_put_file", %{"local_path" => fixture, "remote_name" => "settings.yml"})

      assert_received {:put, _local, _bytes, @run_dir, "settings.yml"}

      driver = remote_driver(worktree, remote_host(%{put: {:error, "exit 1: disk full"}}))
      assert {:error, {:qa_tool, "qa_put_file_failed", message}} = QaDriver.call_tool(driver, "qa_put_file", %{"local_path" => fixture})
      assert message =~ "could not be copied to the QA host: exit 1: disk full"
      assert_received {:put, local, _bytes, @run_dir, "symphony.yml"}
      refute File.exists?(local)

      driver = remote_driver(worktree, remote_host(%{prepare: {:error, {:unsafe, "has a forwarded SSH agent"}}}))
      assert error_code(QaDriver.call_tool(driver, "qa_put_file", %{"local_path" => fixture})) == "qa_worker_unsafe"
      refute_received {:put, _local, _bytes, _dir, _name}
    end

    test "puts a checkout and the fake gh on the QA host", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host())
      bundle = Path.join(worktree, "qa-evidence/widgets.bundle")
      File.mkdir_p!(Path.dirname(bundle))
      File.write!(bundle, "bundle bytes")

      assert {:ok, %{"path" => path}} =
               QaDriver.call_tool(driver, "qa_put_checkout", %{"local_path" => "qa-evidence/widgets.bundle", "remote_url" => "https://github.com/acme/widgets"})

      assert path == @run_dir <> "/checkouts/widgets"
      assert_received {:put, local, "bundle bytes", @run_dir, "widgets.bundle"}
      refute File.exists?(local)
      assert_received {:cmd, "/bin/sh", ["-c", _script, "sh", @run_dir, remote_bundle, "widgets", "https://github.com/acme/widgets.git"], _opts}
      assert remote_bundle == @run_dir <> "/files/widgets.bundle"

      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {:ok, [gh_port, linear_port | _rest]} = QaDriver.host_ports(driver)
      args = %{"gh_stub_port" => gh_port, "linear_stub_port" => linear_port, "open_panel_dir" => path}
      {{:ok, %{"pid" => _pid}}, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", args) end)
      assert_received {:launched, _executable, launch_opts, _port, _pid}

      assert [
               {"SYMPHONY_BAR_QA_ROOT", _qa_root},
               {"SYMPHONY_QA_OPENROUTER_URL", _stub_url},
               {"SYMPHONY_BAR_GH", @run_dir <> "/bin/gh"},
               {"SYMPHONY_QA_GH_URL", gh_url},
               {"SYMPHONY_QA_LINEAR_URL", linear_url},
               {"SYMPHONY_BAR_QA_OPEN_PANEL_DIR", ^path}
             ] = launch_opts[:env]

      assert gh_url == "http://localhost:#{gh_port}"
      assert linear_url == "http://localhost:#{linear_port}/graphql"

      driver = remote_driver(worktree, remote_host(%{put: {:error, "exit 1: disk full"}}))

      assert {:error, {:qa_tool, "qa_put_checkout_failed", message}} =
               QaDriver.call_tool(driver, "qa_put_checkout", %{"local_path" => bundle, "remote_url" => "https://github.com/acme/widgets"})

      assert message =~ "The bundle could not be copied to the QA host: exit 1: disk full"
    end

    test "reports a capture it cannot copy back", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host(%{read: {:error, :unreadable}}))
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {{:ok, %{"pid" => pid}}, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "settings"})) == "qa_screenshot_failed"
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
      assert %{cmd: _cmd, launch: _launch, kill: _kill, helper: _helper, call_helper: _call_helper} = Host.default()
    end
  end

  describe "wide pass" do
    defp resized(window, screen, visible) do
      {Jason.encode!(%{ok: true, method: "AXSize", window: window, screen: screen, visible: visible, requested: %{w: 1400, h: 900}}), 0}
    end

    @wide_screen %{w: 1920, h: 1200}
    @wide_visible %{x: 0, y: 25, w: 1920, h: 1105}

    test "resizes the main window or a given one and remembers the size it reached", %{worktree: worktree} do
      reply = resized(%{x: 0, y: 25, w: 1400, h: 900}, @wide_screen, @wide_visible)
      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: %{"ax-resize" => reply}}))
      assert QaDriver.wide_pass(driver) == nil

      assert {:ok, %{"window" => %{"w" => 1400, "h" => 900}, "screen" => %{"w" => 1920}, "limited" => false, "note" => note}} =
               QaDriver.call_tool(driver, "qa_resize_window", %{"pid" => pid})

      assert note == "The window is 1400×900 pt on a 1920×1200 pt screen."
      assert_received {:cmd, @helper, ["ax-resize", pid_arg, "", "1400", "900"], _opts}
      assert pid_arg == Integer.to_string(pid)

      assert QaDriver.wide_pass(driver) ==
               %{window: {1400, 900}, screen: {1920, 1200}, visible: {1920, 1105}, limited: false}

      assert {:ok, %{"limited" => false}} = QaDriver.call_tool(driver, "qa_resize_window", %{"pid" => pid, "path" => "1", "width" => 1600, "height" => 1000})
      assert_received {:cmd, @helper, ["ax-resize", _pid, "1", "1600", "1000"], _opts}

      for args <- [%{"width" => 1200}, %{"height" => 600}, %{"width" => 9000}, %{"path" => "window"}, %{"width" => "1400"}] do
        assert error_code(QaDriver.call_tool(driver, "qa_resize_window", Map.put(args, "pid", pid))) == "invalid_arguments"
      end

      assert error_code(QaDriver.call_tool(driver, "qa_resize_window", %{"pid" => pid + 1})) == "qa_pid_not_launched"

      # The wide pass outlives the app it resized.
      assert {:ok, %{"quit" => true}} = QaDriver.call_tool(driver, "qa_quit_app", %{"pid" => pid})
      assert %{limited: false} = QaDriver.wide_pass(driver)
      QaDriver.stop(driver)
      assert QaDriver.wide_pass(driver) == nil
      assert QaDriver.wide_pass(nil) == nil
    end

    test "says the wide pass is limited on a screen under 1400×900 pt", %{worktree: worktree} do
      reply = resized(%{x: 0, y: 25, w: 1024, h: 675}, %{w: 1024, h: 768}, %{x: 0, y: 25, w: 1024, h: 675})
      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: %{"ax-resize" => reply}}))

      assert {:ok, %{"limited" => true, "note" => note}} = QaDriver.call_tool(driver, "qa_resize_window", %{"pid" => pid})
      assert note =~ "The QA screen is 1024×768 pt with 1024×675 pt usable, under the 1400×900 pt the wide pass needs"
      assert note =~ "mark the Wide pass step `blocked`"
      assert %{limited: true, screen: {1024, 768}, window: {1024, 675}} = QaDriver.wide_pass(driver)
    end

    test "tells an app that keeps its window small from a small screen", %{worktree: worktree} do
      replies = %{
        "ax-resize" => resized(%{x: 0, y: 25, w: 548, h: 420}, @wide_screen, @wide_visible),
        "ax-ping" => {~s({"ok":true,"responding":true,"ms":3}), 0}
      }

      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: replies}))

      assert {:ok, %{"limited" => false, "note" => note}} = QaDriver.call_tool(driver, "qa_resize_window", %{"pid" => pid})
      assert note =~ "The app kept its window at 548×420 pt on a 1920×1200 pt screen"

      assert {:ok, %{"healthy" => true, "window" => %{"w" => 548, "h" => 420}, "page" => "Settings", "problems" => []}} =
               QaDriver.call_tool(driver, "qa_check_app", %{"pid" => pid, "page" => "Settings"})
    end

    test "refuses a resize reply without the window size", %{worktree: worktree} do
      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: %{"ax-resize" => {~s({"ok":true}), 0}}}))

      assert {:error, {:qa_tool, "qa_helper_failed", message}} = QaDriver.call_tool(driver, "qa_resize_window", %{"pid" => pid})
      assert message =~ "no window size"
      assert QaDriver.wide_pass(driver) == nil
    end

    # The QA playbook fixture: a build whose layout crashes once its window is wider than
    # 1200 pt passes at its default size and fails the wide pass, named by page and size.
    test "fails a build that crashes in a window wider than 1200 pt, naming the page and size", %{root: root, worktree: worktree} do
      trigger = Path.join(root, "crash-trigger")
      listing = Path.join(root, "crash-reports")
      File.write!(listing, "Demo-2026-10-01-090000.ips\nOther-2026-10-06-120000.ips\n")

      cmd = fn
        "/bin/sh", ["-c", _script, "sh", "Demo"], _opts ->
          {:ok, {File.read!(listing), 0}}

        @helper, ["ax-resize", _pid, _path, width, height], _opts ->
          if String.to_integer(width) > 1200 do
            File.write!(trigger, "")
            File.write!(listing, "Demo-2026-10-06-120000.ips\n", [:append])
          end

          window = %{x: 0, y: 25, w: String.to_integer(width), h: String.to_integer(height)}
          {:ok, resized(window, @wide_screen, @wide_visible)}

        @helper, ["ax-ping", _pid], _opts ->
          {:ok, {~s({"ok":true,"responding":true,"ms":2}), 0}}

        executable, args, opts ->
          default_cmd(executable, args, opts, replies(%{}))
      end

      # The app runs until the resize trips its layout (10 s at most, so a failed test leaves
      # nothing running), then dies like an uncaught exception.
      launch = fn _executable, _opts ->
        script = ~s{i=0; while [ ! -e "$1" ] && [ $i -lt 500 ]; do sleep 0.02; i=$((i + 1)); done; echo "Decide layout: constraint loop"; exit 134}
        port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", script, "sh", trigger]])
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        {:ok, port, os_pid}
      end

      {driver, pid} = launched_app(worktree, host: host(%{cmd: cmd, launch: launch}))

      # At the default size the build is healthy.
      assert {:ok, %{"healthy" => true, "running" => true, "responding" => true, "crash_reports" => [], "window" => nil}} =
               QaDriver.call_tool(driver, "qa_check_app", %{"pid" => pid, "page" => "Decide"})

      assert {:ok, %{"window" => %{"w" => 1400, "h" => 900}}} = QaDriver.call_tool(driver, "qa_resize_window", %{"pid" => pid})
      wait_until(fn -> match?({:ok, %{"running" => false}}, QaDriver.call_tool(driver, "qa_check_app", %{"pid" => pid})) end)

      assert {:ok, %{"healthy" => false, "running" => false, "responding" => nil, "crash_reports" => reports, "problems" => [exited, crashed]}} =
               QaDriver.call_tool(driver, "qa_check_app", %{"pid" => pid, "page" => "Decide"})

      assert reports == ["Demo-2026-10-06-120000.ips"]
      assert exited =~ ~s[The app exited with status 134 (page "Decide", window 1400×900 pt). Last output: Decide layout: constraint loop]
      assert crashed == ~s[New crash report (page "Decide", window 1400×900 pt) in ~/Library/Logs/DiagnosticReports: Demo-2026-10-06-120000.ips.]

      # The other tools still refuse the exited app.
      assert error_code(QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid})) == "qa_app_exited"
    end

    test "reports a hung app and passes on other helper failures", %{worktree: worktree} do
      not_responding = {~s({"error":{"code":"app_not_responding","message":"no answer"}}), 1}
      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: %{"ax-ping" => not_responding}}))

      assert {:ok, %{"healthy" => false, "running" => true, "responding" => false, "problems" => [problem]}} =
               QaDriver.call_tool(driver, "qa_check_app", %{"pid" => pid, "page" => "Decide"})

      assert problem == ~s[The app did not answer accessibility requests for 10 seconds (page "Decide"): it is hung.]

      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: %{"ax-ping" => {:error, :timeout}}}))
      assert {:ok, %{"responding" => false, "problems" => [hung]}} = QaDriver.call_tool(driver, "qa_check_app", %{"pid" => pid})
      assert hung == "The app did not answer accessibility requests for 10 seconds: it is hung."

      no_grant = {~s({"error":{"code":"accessibility_permission_missing","message":"no"}}), 1}
      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: %{"ax-ping" => no_grant}}))
      assert error_code(QaDriver.call_tool(driver, "qa_check_app", %{"pid" => pid})) == "qa_permission_missing"

      {driver, pid} = launched_app(worktree, host: host(%{helper: fn -> {:error, :swiftc_not_found} end}))
      assert error_code(QaDriver.call_tool(driver, "qa_check_app", %{"pid" => pid})) == "qa_helper_unavailable"

      assert error_code(QaDriver.call_tool(driver, "qa_check_app", %{"pid" => pid + 1})) == "qa_pid_not_launched"
      assert error_code(QaDriver.call_tool(driver, "qa_check_app", %{"pid" => pid, "page" => String.duplicate("p", 201)})) == "invalid_arguments"
      assert error_code(QaDriver.call_tool(driver, "qa_check_app", %{})) == "invalid_arguments"
    end

    test "does not launch when the crash reports cannot be listed", %{worktree: worktree} do
      for {reply, detail} <- [{{:ok, {"ls: Operation not permitted", 1}}, "(exit 1): ls: Operation not permitted"}, {{:error, :timeout}, ":timeout"}] do
        driver = start_driver(worktree, host: host(%{helper_replies: %{"crash_reports" => reply}}))
        assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
        assert {:error, {:qa_tool, "qa_crash_reports_failed", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{})
        assert message =~ detail
        refute_received {:launched, _executable, _opts, _port, _pid}
      end
    end
  end

  defp close_tunnel(driver) do
    %{tunnel: tunnel} = :sys.get_state(driver)
    Port.command(tunnel, "close\n")
    wait_until(fn -> :sys.get_state(driver).tunnel == nil end)
  end
end
