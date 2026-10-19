defmodule SymphonyElixir.QaDriverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AgentEnv, Paths, PathSafety, QaDriver}
  alias SymphonyElixir.QaDriver.Host

  @app "macos/build/Demo.app"
  @helper "/fake/symphony-qa-driver"
  @appearance_library "/fake/symphony-qa-appearance.dylib"
  # The `IOPlatformUUID`s of the Symphony Mac and of the QA VM.
  @symphony_mac "1A2B3C4D-0000-1111-2222-333344445555"
  @qa_vm "99999999-8888-7777-6666-555544443333"

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

  # A fake QA VM. Its run directory is a real temporary directory, so what the
  # driver copies there (the shipped worktree, bundles, fixtures, checkouts,
  # captures) can be read back: the build writes the bundle, the bundle script
  # copies it into `builds/`, plutil names its executable, the helper answers
  # from `helper_replies` (through `cmd`, so tests see every helper call as a
  # `{:cmd, @helper, args, opts}` message), and its screenshot command writes
  # the file it is given. `ioreg` names another machine than this one.
  defp host(overrides \\ %{}) do
    test = self()
    replies = replies(overrides)

    cmd = fn
      "/usr/sbin/ioreg", _args, _opts ->
        Map.get(overrides, :ioreg, ioreg(@qa_vm))

      executable, args, opts ->
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
      helper: Map.get(overrides, :helper, fn _dir -> {:ok, @helper} end),
      appearance_library:
        Map.get(overrides, :appearance_library, fn _dir ->
          send(test, :appearance_library)
          {:ok, @appearance_library}
        end),
      read: &take_file/1,
      prepare: fn _operator_home, _canary -> {:ok, run_dir!()} end,
      ship: &unpack/2,
      put: &put_copy/3,
      tunnel: fn _ports -> open_tunnel() end,
      cleanup: fn dir -> File.rm_rf!(dir) && :ok end
    }
  end

  defp run_dir! do
    dir = Path.join(System.tmp_dir!(), "qa-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "app-root"))
    File.mkdir_p!(Path.join(dir, "builds"))
    {:ok, dir} = PathSafety.canonicalize(dir)
    dir
  end

  # As `Remote.read/2`: a regular file, removed once read.
  defp take_file(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      File.rm!(path)
      {:ok, bytes}
    else
      _other -> {:error, :unreadable}
    end
  end

  # As `Remote.ship/3`: the tar unpacked into a fresh directory. A faked
  # `git archive` writes no tar, which ships an empty tree.
  defp unpack(tar, dest) do
    File.rm_rf!(dest)
    File.mkdir_p!(dest)
    if File.exists?(tar), do: :ok = :erl_tar.extract(String.to_charlist(tar), cwd: String.to_charlist(dest))
    :ok
  end

  defp put_copy(local, dir, name) do
    dest = Path.join([dir, "files", name])
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(local, dest)
    {:ok, dest}
  end

  # Stands in for the tunnel's SSH session: it prints a line as `ssh` may, then
  # runs until its stdin closes, or exits when the test writes a line to it.
  defp open_tunnel, do: {:ok, Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", "exec 2>/dev/null; echo warning; read line; exit 3"]])}

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
        "ax-set-value" => {~s({"ok":true,"element":{"path":"0.2","role":"AXTextField"}}), 0},
        "ax-select" => {~s({"ok":true,"selected":true,"element":{"path":"0.3.1","role":"AXRow","selected":true}}), 0},
        "click" => {~s({"ok":true,"clicked":{"x":120,"y":200},"clicks":1,"element":{"path":"0.4","role":"AXButton"}}), 0},
        "key" => {~s({"ok":true,"key":"return","modifiers":[],"window":{"role":"AXWindow"},"focused":{"role":"AXOutline"}}), 0}
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

  defp default_cmd("/bin/mv", ["-f", from, to], _opts, _replies) do
    case File.rename(from, to) do
      :ok -> {:ok, {"", 0}}
      {:error, _reason} -> {:ok, {"mv: No such file or directory\n", 1}}
    end
  end

  defp default_cmd("/bin/rm", ["-f", path], _opts, _replies) do
    File.rm(path)
    {:ok, {"", 0}}
  end

  # The scripts that work in the run directory (the fake gh, a checkout, the
  # status-menu request) run for real; the bundle copy and the release pair's
  # clone are played, since they need macOS tools or a real git bundle.
  defp default_cmd("/bin/sh", ["-c", script, "sh", _dir | rest] = args, opts, _replies) do
    cond do
      script =~ "symphony-qa-app:" -> copy_built_bundle(args)
      script =~ "symphony-qa-pair-src:" -> clone_pair_source(rest, args)
      true -> Host.cmd("/bin/sh", args, opts)
    end
  end

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

  defp copy_built_bundle(["-c", _script, "sh", build_dir, app, dest]) do
    bundle = Path.join(build_dir, app)

    if File.dir?(bundle) do
      File.mkdir_p!(dest)
      File.cp_r!(bundle, Path.join(dest, Path.basename(app)))
      {:ok, {"symphony-qa-app:#{dest}/#{Path.basename(app)}/Contents/MacOS/#{Path.basename(app, ".app")}\n", 0}}
    else
      {:ok, {"#{app} is not a directory; run qa_build and check its output\n", 1}}
    end
  end

  # The fake `git bundle` (`clean_git/2`) holds the worktree's path; the clone copies it.
  defp clone_pair_source([dest], ["-c", _script, "sh", bundle_dir, dest]) do
    worktree = File.read!(Path.join(bundle_dir, "head.bundle"))
    File.rm_rf!(dest)
    File.cp_r!(worktree, dest)
    File.rm_rf!(bundle_dir)
    {:ok, {"symphony-qa-pair-src:#{dest}\n", 0}}
  end

  # Runs the app here as the QA host would, with this environment plus the launch's.
  defp launch_here(executable, opts) do
    env = for {name, value} <- opts[:env], do: {String.to_charlist(name), String.to_charlist(value)}
    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, :stderr_to_stdout, cd: opts[:cd], env: env, args: opts[:args]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    {:ok, port, pid}
  end

  defp ioreg(uuid), do: {:ok, {~s(+-o Mac  <class IOPlatformExpertDevice>\n    {\n      "IOPlatformUUID" = "#{uuid}"\n    }\n), 0}}

  defp write_bundle(worktree, contents \\ "binary-v1") do
    macos = Path.join([worktree, @app, "Contents", "MacOS"])
    File.mkdir_p!(macos)
    File.write!(Path.join([worktree, @app, "Contents", "Info.plist"]), "<plist/>")
    File.write!(Path.join(macos, "Demo"), contents)
    {:ok, {"Build complete!\n", 0}}
  end

  # A clean worktree. Its `git bundle` is a file naming the worktree, which the
  # release pair's fake clone copies.
  defp clean_git(["bundle", "create", bundle | _rest], cwd) do
    File.write!(bundle, cwd)
    {"", 0}
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
          worker_host: "qa@qa-vm",
          host: Keyword.get(opts, :host, host()),
          local_uuid: fn -> {:ok, @symphony_mac} end,
          git: Keyword.get(opts, :git, &clean_git/2)
        ] ++ Keyword.take(opts, [:start_stub, :status_menu_poll, :release_pair_timeout_ms, :relaunch_poll_ms, :feed_poll])
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

  defp env(launch_opts, name) do
    case List.keyfind(launch_opts[:env], name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  describe "tools" do
    test "hands out three free host ports and forwards them from the QA host", %{worktree: worktree} do
      driver = start_driver(worktree)
      assert {:ok, [_one, _two, _three] = ports} = QaDriver.host_ports(driver)
      assert length(Enum.uniq(ports)) == 3
      assert %{tunnel: tunnel} = :sys.get_state(driver)
      assert is_port(tunnel)
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

      %{scratch_dir: scratch_dir, host_dir: host_dir} = GenServer.call(driver, :config)
      assert_received {:cmd, "/bin/sh", ["-c", "make app"], build_opts}
      assert build_opts[:cd] == Path.join(host_dir, "src")
      assert build_opts[:timeout_ms] == 900_000
      refute Keyword.has_key?(build_opts, :env)

      {:ok, state_root} = PathSafety.canonicalize(Paths.state_root())
      assert String.starts_with?(scratch_dir, Path.join(state_root, "qa-driver/runs") <> "/")
      assert File.stat!(scratch_dir).mode |> Bitwise.band(0o777) == 0o700

      assert_received {:launched, executable, launch_opts, _port, ^pid}
      assert String.starts_with?(executable, Path.join(host_dir, "builds") <> "/")
      assert String.ends_with?(executable, "/Demo.app/Contents/MacOS/Demo")
      qa_root = launch_opts[:cd]
      assert qa_root == Path.join(host_dir, "app-root")
      assert env(launch_opts, "SYMPHONY_BAR_QA_ROOT") == qa_root

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
      refute File.exists?(host_dir)
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
      opts = [worker_host: "qa@qa-vm", host: host(), local_uuid: fn -> {:ok, @symphony_mac} end]
      {:ok, driver} = QaDriver.start_link([worktree: worktree, playbook: playbook] ++ opts)

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

      # The QA host's build gets `remote_env` added to its login environment.
      cmd = fn
        "/bin/sh", ["-c", _build] = args, opts ->
          env = for {name, value} <- opts[:remote_env], do: {String.to_charlist(name), String.to_charlist(value)}
          Host.cmd("/bin/sh", args, cd: opts[:cd], env: env, timeout_ms: opts[:timeout_ms])

        executable, args, opts ->
          default_cmd(executable, args, opts, replies(%{}))
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

      # Something writes ignored outputs into the worktree while the build runs on the QA host.
      build = fn
        "/bin/sh", ["-c", "make app"], opts ->
          write_bundle(worktree)
          write_bundle(opts[:cd])

        executable, args, opts ->
          default_cmd(executable, args, opts, %{})
      end

      # Planted before the first build: the worktree is fresh, so nothing ignored may exist.
      planted = Path.join(worktree, "macos/.build/checkouts/dep/Sources/Dep.swift")
      File.mkdir_p!(Path.dirname(planted))
      File.write!(planted, "evil()")
      File.mkdir_p!(Path.join(worktree, "qa-evidence"))
      File.write!(Path.join(worktree, "qa-evidence/a.png"), "png")
      driver = start_driver(worktree, git: git, host: host(%{cmd: build}))
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
      fresh = start_driver(worktree, git: git, host: host(%{cmd: build}))
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
  end

  describe "qa_launch_app" do
    test "launches the run directory's copy of what the last build produced", %{worktree: worktree} do
      driver = start_driver(worktree)
      assert error_code(QaDriver.call_tool(driver, "qa_launch_app", %{})) == "qa_not_built"

      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      %{host_dir: host_dir} = GenServer.call(driver, :config)
      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert {:ok, %{"pid" => _pid}} = result
      assert_received {:launched, executable, _opts, _port, _pid}
      assert String.starts_with?(executable, Path.join(host_dir, "builds") <> "/")
      assert File.read!(executable) == "binary-v1"
    end

    test "starts one OpenRouter stub for the pass and points every app at it", %{worktree: worktree} do
      {driver, _pid} = launched_app(worktree)
      assert_received {:launched, _executable, launch_opts, _port, _pid}
      %{stub: %{port: stub_port}} = :sys.get_state(driver)
      # The app's SSH session forwards a loopback port on the QA host back to the stub.
      assert [{"127.0.0.1:" <> remote_port, "127.0.0.1:" <> local_port}] = launch_opts[:reverse_forwards]
      assert local_port == Integer.to_string(stub_port)
      assert env(launch_opts, "SYMPHONY_QA_OPENROUTER_URL") == "http://127.0.0.1:#{remote_port}/api"
      assert Req.get!("http://127.0.0.1:#{stub_port}/api/v1/models", retry: false).status == 200

      {_result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert_received {:launched, _executable, second_opts, _port, _pid}
      assert [{_remote, "127.0.0.1:" <> ^local_port}] = second_opts[:reverse_forwards]

      # A stub that died is started again for the next launch.
      %{stub: %{pid: stub}} = :sys.get_state(driver)
      ref = Process.monitor(stub)
      Process.exit(stub, :kill)
      assert_receive {:DOWN, ^ref, :process, ^stub, :killed}
      wait_until(fn -> :sys.get_state(driver).stub == nil end)

      {_result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert_received {:launched, _executable, third_opts, _port, _pid}
      assert [{_remote, restarted_stub}] = third_opts[:reverse_forwards]
      assert Req.get!("http://#{restarted_stub}/api/v1/models", retry: false).status == 200

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

  describe "qa_launch_app api_fixtures" do
    @fixtures "macos/Tests/Fixtures/director-app/running"

    defp write_fixtures(worktree, files \\ %{"api/v1/overview.json" => ~s({"running":2}), "api/v1/issues.json" => "[]"}) do
      for {relative, contents} <- files do
        path = Path.join([worktree, @fixtures, relative])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, contents)
      end

      Path.join(worktree, @fixtures)
    end

    defp fixtures_env(launch_opts) do
      case Enum.find(launch_opts[:env], fn {name, _value} -> to_string(name) == "SYMPHONY_BAR_QA_API_FIXTURES" end) do
        {_name, dir} -> to_string(dir)
        nil -> nil
      end
    end

    test "launches the app on a private copy of the directory", %{worktree: worktree} do
      write_fixtures(worktree)
      driver = start_driver(worktree)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      %{host_dir: host_dir} = GenServer.call(driver, :config)

      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => @fixtures}) end)
      assert {:ok, %{"pid" => _pid, "api_fixtures" => copy}} = result
      assert_received {:launched, _executable, launch_opts, _port, _pid}
      assert fixtures_env(launch_opts) == copy
      assert String.starts_with?(copy, host_dir <> "/api-fixtures-")
      assert File.read!(Path.join(copy, "api/v1/overview.json")) == ~s({"running":2})
      assert File.read!(Path.join(copy, "api/v1/issues.json")) == "[]"

      # Each launch gets its own copy; one without the argument gets none.
      {{:ok, %{"api_fixtures" => second}}, _log} =
        with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => @fixtures <> "/"}) end)

      assert second != copy
      {{:ok, payload}, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => nil}) end)
      refute Map.has_key?(payload, "api_fixtures")
      assert_received {:launched, _executable, _opts, _port, _pid}
      assert_received {:launched, _executable, no_fixtures, _port, _pid}
      assert fixtures_env(no_fixtures) == nil
    end

    test "copies an empty directory", %{worktree: worktree} do
      File.mkdir_p!(Path.join(worktree, @fixtures))
      driver = start_driver(worktree)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {{:ok, %{"api_fixtures" => copy}}, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => @fixtures}) end)
      assert File.ls!(copy) == []
    end

    test "refuses bad arguments and directories outside the checkout", %{root: root, worktree: worktree} do
      driver = start_driver(worktree)
      outside = Path.join(root, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.json"), "{}")

      for value <- [7, "", "a\0b", outside, String.duplicate("a", 4_097)] do
        assert {:error, {:qa_tool, "invalid_arguments", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => value})
        assert message =~ "`api_fixtures`"
      end

      File.mkdir_p!(Path.join(worktree, "fixtures"))
      File.ln_s!(outside, Path.join(worktree, "fixtures/escape"))

      for value <- ["../outside", "fixtures/escape", "fixtures/../../outside", "."] do
        assert {:error, {:qa_tool, "qa_launch_app_refused", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => value})
        assert message =~ "resolves outside the PR checkout"
      end

      File.write!(Path.join(worktree, "fixtures/file.json"), "{}")
      assert {:error, {:qa_tool, "qa_launch_app_refused", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => "fixtures/file.json"})
      assert message =~ "fixtures/file.json is not a directory"

      File.mkdir_p!(Path.join(worktree, ".git/refs"))

      for value <- [".git", ".git/refs"] do
        assert {:error, {:qa_tool, "qa_launch_app_refused", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => value})
        assert message =~ "is in the checkout's .git directory"
      end

      assert {:error, {:qa_tool, "qa_launch_app_refused", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => "fixtures/missing"})
      assert message =~ "fixtures/missing could not be read: :enoent"
      refute_received {:launched, _executable, _opts, _port, _pid}
    end

    test "refuses symlinks, special files, hard links and unreadable entries inside the directory", %{root: root, worktree: worktree} do
      driver = start_driver(worktree)
      outside = Path.join(root, "outside.json")
      File.write!(outside, "{}")

      refusal = fn prepare ->
        File.rm_rf!(Path.join(worktree, @fixtures))
        dir = write_fixtures(worktree)
        prepare.(dir)
        assert {:error, {:qa_tool, "qa_launch_app_refused", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => @fixtures})
        message
      end

      assert refusal.(&File.ln_s!(outside, Path.join(&1, "api/v1/linked.json"))) =~ "#{@fixtures}/api/v1/linked.json is a symlink"
      assert refusal.(&File.ln_s!("issues.json", Path.join(&1, "api/v1/inner.json"))) =~ "api/v1/inner.json is a symlink"

      fifo = fn dir -> {_output, 0} = System.cmd("mkfifo", [Path.join(dir, "api/pipe")]) end
      assert refusal.(fifo) =~ "#{@fixtures}/api/pipe is not a regular file"

      hard_link = fn dir -> File.ln!(Path.join(dir, "api/v1/issues.json"), Path.join(root, "elsewhere.json")) end
      assert refusal.(hard_link) =~ "api/v1/issues.json has other hard links"

      unreadable = fn dir -> File.chmod!(Path.join(dir, "api/v1/issues.json"), 0o000) end
      assert refusal.(unreadable) =~ "api/v1/issues.json could not be read: :eacces"

      # Listable but not searchable: its entries cannot be stat'ed.
      unsearchable = fn dir -> File.chmod!(Path.join(dir, "api/v1"), 0o600) end
      assert refusal.(unsearchable) =~ "api/v1/issues.json could not be read: :eacces"
      File.chmod!(Path.join(worktree, @fixtures <> "/api/v1"), 0o700)

      unlistable = fn dir -> File.chmod!(Path.join(dir, "api/v1"), 0o000) end
      assert refusal.(unlistable) =~ "#{@fixtures}/api/v1 could not be listed: :eacces"
      File.chmod!(Path.join(worktree, @fixtures <> "/api/v1"), 0o700)
      refute_received {:launched, _executable, _opts, _port, _pid}
    end

    test "refuses a directory over 5 MB or 1000 files", %{worktree: worktree} do
      driver = start_driver(worktree)
      chunk = :binary.copy("x", 2_500_000)
      write_fixtures(worktree, %{"a.json" => chunk, "b.json" => chunk})
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {{:ok, %{"api_fixtures" => copy}}, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => @fixtures}) end)
      assert File.stat!(Path.join(copy, "b.json")).size == 2_500_000

      write_fixtures(worktree, %{"c.json" => "1"})
      assert {:error, {:qa_tool, "qa_launch_app_refused", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => @fixtures})
      assert message =~ "#{@fixtures} holds over 5000000 bytes"

      File.rm_rf!(Path.join(worktree, @fixtures))
      write_fixtures(worktree, Map.new(1..1_001, &{"f#{&1}.json", ""}))
      assert {:error, {:qa_tool, "qa_launch_app_refused", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => @fixtures})
      assert message =~ "#{@fixtures} holds more than 1000 files"
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
            {"qa_ax_set_value", %{"path" => "0", "value" => "v"}},
            {"qa_ax_select", %{"path" => "0"}},
            {"qa_click", %{"path" => "0"}},
            {"qa_key", %{"key" => "return"}}
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

      unavailable = host(%{helper: fn _dir -> {:error, :swiftc_not_found} end})
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

    test "selects a table row, clicks an element and presses keys through the helper", %{worktree: worktree} do
      {driver, pid} = launched_app(worktree)
      pid_arg = Integer.to_string(pid)

      assert {:ok, %{"selected" => true, "element" => %{"role" => "AXRow"}}} =
               QaDriver.call_tool(driver, "qa_ax_select", %{"pid" => pid, "path" => "0.3.1"})

      assert_received {:cmd, @helper, ["ax-select", ^pid_arg, "0.3.1"], _opts}

      assert {:ok, %{"clicked" => %{"x" => 120}}} = QaDriver.call_tool(driver, "qa_click", %{"pid" => pid, "path" => "0.4"})
      assert_received {:cmd, @helper, ["click", ^pid_arg, "0.4", "1"], _opts}

      assert {:ok, %{"ok" => true}} = QaDriver.call_tool(driver, "qa_click", %{"pid" => pid, "path" => "0.3.1", "clicks" => 2})
      assert_received {:cmd, @helper, ["click", ^pid_arg, "0.3.1", "2"], _opts}

      assert {:ok, %{"focused" => %{"role" => "AXOutline"}}} = QaDriver.call_tool(driver, "qa_key", %{"pid" => pid, "key" => "return"})
      assert_received {:cmd, @helper, ["key", ^pid_arg, "return", ""], _opts}

      assert {:ok, _reply} = QaDriver.call_tool(driver, "qa_key", %{"pid" => pid, "key" => "[", "modifiers" => ["command"]})
      assert_received {:cmd, @helper, ["key", ^pid_arg, "[", "command"], _opts}

      assert {:ok, _reply} = QaDriver.call_tool(driver, "qa_key", %{"pid" => pid, "key" => "\\", "modifiers" => ["shift", "option", "control"]})
      assert_received {:cmd, @helper, ["key", ^pid_arg, "\\", "shift,option,control"], _opts}
    end

    test "validates select, click and key arguments before calling the helper", %{worktree: worktree} do
      {driver, pid} = launched_app(worktree)

      for args <- [%{}, %{"path" => "0..1"}, %{"path" => 3}] do
        assert error_code(QaDriver.call_tool(driver, "qa_ax_select", Map.put(args, "pid", pid))) == "invalid_arguments"
        assert error_code(QaDriver.call_tool(driver, "qa_click", Map.put(args, "pid", pid))) == "invalid_arguments"
      end

      for clicks <- [0, 3, "2"] do
        assert error_code(QaDriver.call_tool(driver, "qa_click", %{"pid" => pid, "path" => "0", "clicks" => clicks})) == "invalid_arguments"
      end

      for key <- [nil, "", "A", "F1", "cmd+q", "ab", 36] do
        assert {:error, {:qa_tool, "invalid_arguments", message}} = QaDriver.call_tool(driver, "qa_key", %{"pid" => pid, "key" => key})
        assert message =~ "`key` must be one of return, enter"
      end

      for modifiers <- ["command", ["cmd"], ["shift", "shift"], [1]] do
        assert {:error, {:qa_tool, "invalid_arguments", message}} =
                 QaDriver.call_tool(driver, "qa_key", %{"pid" => pid, "key" => "q", "modifiers" => modifiers})

        assert message =~ "`modifiers`"
      end

      for command <- ["ax-select", "click", "key"], do: refute_received({:cmd, @helper, [^command | _rest], _opts})
    end

    test "passes the helper's row, click and key errors on to the agent", %{worktree: worktree} do
      replies = %{
        "ax-select" => {~s({"error":{"code":"not_a_row","message":"The element at 0.1 is not a table or outline row."}}), 1},
        "click" => {~s({"error":{"code":"covered","message":"Another app's window covers the element at 0.4"}}), 1},
        "key" => {~s({"error":{"code":"no_window","message":"The app has no focused window to send the key to."}}), 1}
      }

      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: replies}))

      assert {:error, {:qa_tool, "qa_not_a_row", _message}} = QaDriver.call_tool(driver, "qa_ax_select", %{"pid" => pid, "path" => "0.1"})
      assert {:error, {:qa_tool, "qa_covered", _message}} = QaDriver.call_tool(driver, "qa_click", %{"pid" => pid, "path" => "0.4"})
      assert {:error, {:qa_tool, "qa_no_window", _message}} = QaDriver.call_tool(driver, "qa_key", %{"pid" => pid, "key" => "escape"})
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

  describe "qa_api_requests" do
    defp api_requests(driver), do: QaDriver.call_tool(driver, "qa_api_requests", %{})

    test "returns the requests the app logged under its QA root and takes the log away", %{worktree: worktree} do
      {driver, _pid} = launched_app(worktree)
      %{qa_root: qa_root} = GenServer.call(driver, :config)

      # No log yet: the app answered no POST.
      assert api_requests(driver) == {:ok, %{"requests" => [], "dropped" => 0}}

      File.mkdir_p!(qa_root)
      log = Path.join(qa_root, "api-requests.jsonl")
      File.write!(log, ~s({"body":{"id":"TP-1"},"method":"POST","path":"/api/v1/refresh"}\nnot json\n))

      assert api_requests(driver) ==
               {:ok, %{"requests" => [%{"body" => %{"id" => "TP-1"}, "method" => "POST", "path" => "/api/v1/refresh"}, "not json"], "dropped" => 0}}

      refute File.exists?(log)
      %{host_dir: host_dir} = GenServer.call(driver, :config)
      assert Path.wildcard(Path.join(host_dir, "api-requests-*.jsonl")) == []
      assert api_requests(driver) == {:ok, %{"requests" => [], "dropped" => 0}}

      File.write!(log, Enum.map_join(1..502, &~s({"n":#{&1}}\n)))
      assert {:ok, %{"requests" => [%{"n" => 3} | _rest] = requests, "dropped" => 2}} = api_requests(driver)
      assert length(requests) == 500
    end

    test "reports a log that cannot be read", %{worktree: worktree} do
      driver = start_driver(worktree, host: Map.put(host(), :read, fn _path -> {:error, :unreadable} end))
      %{qa_root: qa_root} = GenServer.call(driver, :config)
      File.mkdir_p!(qa_root)
      File.write!(Path.join(qa_root, "api-requests.jsonl"), "{}\n")

      assert {:error, {:qa_tool, "qa_api_requests_failed", message}} = api_requests(driver)
      assert message =~ "api-requests.jsonl could not be read"
      %{host_dir: host_dir} = GenServer.call(driver, :config)
      assert Path.wildcard(Path.join(host_dir, "api-requests-*.jsonl")) == []
    end

    test "reports a log that cannot be taken aside", %{worktree: worktree} do
      denied = fn
        "/bin/mv", _args, _opts -> {:ok, {"mv: Permission denied\n", 1}}
        exe, args, opts -> default_cmd(exe, args, opts, %{})
      end

      driver = start_driver(worktree, host: host(%{cmd: denied}))
      assert {:error, {:qa_tool, "qa_api_requests_failed", message}} = api_requests(driver)
      assert message =~ "could not be taken: mv: Permission denied"

      down = start_driver(worktree, host: host(%{cmd: fn _exe, _args, _opts -> {:error, :closed} end}))
      assert {:error, {:qa_tool, "qa_api_requests_failed", message}} = api_requests(down)
      assert message =~ "could not be taken: :closed"
    end
  end

  describe "qa_put_file" do
    defp put_file(driver, args), do: QaDriver.call_tool(driver, "qa_put_file", args)

    defp write_fixture!(path, contents \\ "repos: []\n") do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
      path
    end

    test "copies a fixture in qa-evidence or $TMPDIR into the run directory's files/", %{root: root, worktree: worktree} do
      tmp_real = Path.join(root, "tmp-real")
      File.mkdir_p!(tmp_real)
      tmp_link = Path.join(root, "tmp-link")
      File.ln_s!(tmp_real, tmp_link)
      driver = start_driver(worktree, tmp_dir: tmp_link)
      %{host_dir: host_dir} = GenServer.call(driver, :config)

      fixture = write_fixture!(Path.join(worktree, "qa-evidence/qa-config/symphony.yml"))
      copy = Path.join(host_dir, "files/symphony.yml")
      assert {:ok, %{"path" => ^copy, "bytes" => 10}} = put_file(driver, %{"local_path" => "qa-evidence/qa-config/symphony.yml"})
      assert File.read!(copy) == "repos: []\n"
      other = Path.join(host_dir, "files/other.yml")
      assert {:ok, %{"path" => ^other}} = put_file(driver, %{"local_path" => fixture, "remote_name" => "other.yml"})

      write_fixture!(Path.join(tmp_real, "qa/WORKFLOW.md"), "")
      expected = Path.join(host_dir, "files/WORKFLOW.md")
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

      driver = start_driver(worktree, tmp_dir: root, host: host(%{cmd: build, launch: &launch_here/2}))
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

      %{host_dir: host_dir} = GenServer.call(driver, :config)
      assert File.stat!(Path.join(host_dir, "bin/gh")).mode |> Bitwise.band(0o777) == 0o700
    end

    test "puts a checkout of a bundle and opens the folder picker in it", %{root: root, worktree: worktree} do
      driver = start_driver(worktree, tmp_dir: root)
      bundle = bundle!(root, %{"package.json" => "{}\n"})

      assert {:ok, %{"path" => path, "remote_url" => "https://github.com/acme/widgets.git"}} =
               put_checkout(driver, %{"local_path" => bundle, "remote_url" => "https://github.com/acme/widgets"})

      %{scratch_dir: scratch_dir, host_dir: host_dir} = GenServer.call(driver, :config)
      assert path == Path.join(host_dir, "checkouts/widgets")
      assert File.read!(Path.join(path, "package.json")) == "{}\n"
      assert {"https://github.com/acme/widgets.git\n", 0} = System.cmd("git", ["-C", path, "remote", "get-url", "origin"])
      assert {"origin/main\n", 0} = System.cmd("git", ["-C", path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
      assert File.ls!(scratch_dir) |> Enum.filter(&String.ends_with?(&1, ".bundle")) == []
      assert File.ls!(Path.join(host_dir, "files")) == []

      assert {:ok, %{"path" => other}} =
               put_checkout(driver, %{"local_path" => bundle, "remote_url" => "https://github.com/acme/widgets.git", "remote_name" => "with-workflow"})

      assert other == Path.join(host_dir, "checkouts/with-workflow")

      assert {:error, {:qa_tool, "qa_put_checkout_failed", message}} =
               put_checkout(driver, %{"local_path" => bundle, "remote_url" => "https://github.com/acme/widgets"})

      assert message =~ "already exists; pass another remote_name"

      {:ok, [gh_port, linear_port, feed_port | _rest]} = QaDriver.host_ports(driver)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})

      args = %{
        "gh_stub_port" => gh_port,
        "linear_stub_port" => linear_port,
        "open_panel_dir" => path,
        "update_feed_port" => feed_port,
        "update_check_interval_seconds" => 30
      }

      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", args) end)
      assert {:ok, %{"pid" => _pid}} = result
      assert_received {:launched, _executable, launch_opts, _port, _pid}
      env = Map.new(launch_opts[:env])
      assert env["SYMPHONY_BAR_GH"] == Path.join(host_dir, "bin/gh")
      assert env["SYMPHONY_QA_GH_URL"] == "http://localhost:#{gh_port}"
      assert env["SYMPHONY_QA_LINEAR_URL"] == "http://localhost:#{linear_port}/graphql"
      assert env["SYMPHONY_BAR_QA_OPEN_PANEL_DIR"] == path
      assert env["SYMPHONY_BAR_UPDATE_URL"] == "http://localhost:#{feed_port}/releases/latest"
      assert env["SYMPHONY_BAR_UPDATE_CHECK_INTERVAL"] == "30"

      # Without stand-in arguments the app gets none of them.
      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert {:ok, %{"pid" => _pid}} = result
      assert_received {:launched, _executable, launch_opts, _port, _pid}

      stand_in_names = ~w(SYMPHONY_BAR_GH SYMPHONY_QA_LINEAR_URL SYMPHONY_BAR_QA_OPEN_PANEL_DIR SYMPHONY_BAR_UPDATE_URL SYMPHONY_BAR_UPDATE_CHECK_INTERVAL)

      refute Enum.any?(launch_opts[:env], fn {name, _value} -> name in stand_in_names end)
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
            {%{"update_feed_port" => unused}, "`update_feed_port` must be one of QA_HOST_PORTS"},
            {%{"update_feed_port" => "#{port}"}, "`update_feed_port` must be one of QA_HOST_PORTS"},
            {%{"update_check_interval_seconds" => 0}, "`update_check_interval_seconds` must be a positive whole number of seconds"},
            {%{"update_check_interval_seconds" => -30}, "`update_check_interval_seconds` must be a positive whole number"},
            {%{"update_check_interval_seconds" => 1.5}, "`update_check_interval_seconds` must be a positive whole number"},
            {%{"update_check_interval_seconds" => "30"}, "`update_check_interval_seconds` must be a positive whole number"},
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

  describe "qa_launch_app appearance" do
    test "launches the app light or dark, and follows the host without it", %{worktree: worktree} do
      driver = start_driver(worktree)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})

      for {args, expected, app_args, library} <- [
            {%{"appearance" => "dark"}, "dark", [], @appearance_library},
            {%{"appearance" => "light"}, "light", ["-NSRequiresAquaSystemAppearance", "YES"], @appearance_library},
            {%{}, nil, [], nil}
          ] do
        {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", args) end)
        assert {:ok, %{"pid" => pid}} = result
        assert_received {:launched, _executable, launch_opts, _port, ^pid}
        env = Map.new(launch_opts[:env])
        assert env["SYMPHONY_BAR_QA_APPEARANCE"] == expected
        # The library sets any AppKit app's appearance from SYMPHONY_BAR_QA_APPEARANCE.
        assert env["DYLD_INSERT_LIBRARIES"] == library
        if library, do: assert_received(:appearance_library), else: refute_received(:appearance_library)
        assert launch_opts[:args] == app_args
        assert {:ok, _quit} = QaDriver.call_tool(driver, "qa_quit_app", %{"pid" => pid})
      end
    end

    test "reports an appearance library it cannot build and launches nothing", %{worktree: worktree} do
      failed = fn _dir -> {:error, {:appearance_build_failed, 1, "clang: command not found"}} end
      driver = start_driver(worktree, host: host(%{appearance_library: failed}))
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})

      assert {:error, {:qa_tool, "qa_appearance_unavailable", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{"appearance" => "dark"})
      assert message =~ "draws the app dark"
      assert message =~ "clang: command not found"
      assert message =~ "verdict `blocked`"
      refute_received {:launched, _executable, _opts, _port, _pid}
    end

    test "refuses any other appearance", %{worktree: worktree} do
      driver = start_driver(worktree)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})

      for appearance <- ["Dark", "sepia", "", 1, ["dark"]] do
        assert {:error, {:qa_tool, "invalid_arguments", "`appearance` must be `light` or `dark`."}} =
                 QaDriver.call_tool(driver, "qa_launch_app", %{"appearance" => appearance})
      end

      refute_received {:launched, _executable, _opts, _port, _pid}
    end
  end

  describe "qa_open_status_menu" do
    @menu %{id: 21, title: "", layer: 101, onscreen: true, frame: %{x: 1200, y: 24, w: 260, h: 480}}
    @status_item %{id: 12, title: "", layer: 25, onscreen: true, frame: %{x: 1230, y: 0, w: 24, h: 24}}

    defp windows_reply(windows), do: {:ok, {Jason.encode!(%{windows: windows}), 0}}

    # An app that takes the request the driver writes and opens its menu: the
    # window list shows the menu once the request was taken.
    defp opening_app_cmd(test) do
      fn
        "/bin/sh", ["-c", script, "sh", root, pid], opts when is_binary(pid) ->
          Process.put(:status_menu_request, Path.join([root, "status-menu", "open-" <> pid]))
          default_cmd("/bin/sh", ["-c", script, "sh", root, pid], opts, %{})

        @helper, ["windows", _pid], _opts ->
          request = Process.get(:status_menu_request)

          cond do
            Process.get(:menu_open) ->
              windows_reply([@status_item, @menu])

            request && File.exists?(request) ->
              File.rm!(request)
              send(test, {:request_taken, request})
              Process.put(:menu_open, true)
              windows_reply([@status_item])

            true ->
              windows_reply([@status_item])
          end

        executable, args, opts ->
          default_cmd(executable, args, opts, %{})
      end
    end

    test "asks the app through a request file and returns the menu's window", %{worktree: worktree} do
      {driver, pid} = launched_app(worktree, host: host(%{cmd: opening_app_cmd(self())}), status_menu_poll: {5, 1})
      %{qa_root: qa_root} = GenServer.call(driver, :config)

      assert {:ok, %{"pid" => ^pid, "window_id" => 21, "frame" => %{"x" => 1200, "y" => 24, "w" => 260, "h" => 480}, "note" => note}} =
               QaDriver.call_tool(driver, "qa_open_status_menu", %{"pid" => pid})

      assert note =~ "qa_screenshot"
      assert note =~ "escape"
      expected = Path.join([qa_root, "status-menu", "open-#{pid}"])
      assert_received {:request_taken, ^expected}

      # A menu already open is returned at once.
      assert {:ok, %{"window_id" => 21}} = QaDriver.call_tool(driver, "qa_open_status_menu", %{"pid" => pid})
    end

    test "takes the request back when the menu never opens", %{worktree: worktree} do
      replies = %{"windows" => {Jason.encode!(%{windows: [@status_item, %{@menu | onscreen: false}]}), 0}}
      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: replies}), status_menu_poll: {2, 50})
      %{qa_root: qa_root} = GenServer.call(driver, :config)
      request = Path.join([qa_root, "status-menu", "open-#{pid}"])

      assert {:error, {:qa_tool, "qa_status_menu_not_opened", message}} = QaDriver.call_tool(driver, "qa_open_status_menu", %{"pid" => pid})
      assert message =~ "did not open its status-bar menu within 0.1 s of the request"
      assert message =~ "qa_check_app"

      pid_text = Integer.to_string(pid)
      assert_received {:cmd, "/bin/sh", ["-c", _script, "sh", ^qa_root, ^pid_text], _opts}
      for _attempt <- 1..2, do: assert_received({:cmd, @helper, ["windows", ^pid_text], _opts})
      refute_received {:cmd, @helper, ["windows", _pid], _opts}
      assert_received {:cmd, "/bin/rm", ["-f", ^request], _opts}
      refute File.exists?(request)
    end

    test "fails when the request can't be written or the window list can't be read", %{worktree: worktree} do
      cmd = fn
        "/bin/sh", ["-c", _script, "sh", _root, pid], _opts when is_binary(pid) -> {:ok, {"mkdir: denied\n", 1}}
        executable, args, opts -> default_cmd(executable, args, opts, %{})
      end

      {driver, pid} = launched_app(worktree, host: host(%{cmd: cmd}))
      assert {:error, {:qa_tool, "qa_status_menu_failed", message}} = QaDriver.call_tool(driver, "qa_open_status_menu", %{"pid" => pid})
      assert message =~ "mkdir: denied"
      refute_received {:cmd, @helper, ["windows", _pid], _opts}

      for {reply, code} <- [{{:error, :eacces}, "qa_helper_failed"}, {{"{}", 0}, "qa_helper_failed"}, {{"not json", 0}, "qa_helper_failed"}] do
        {driver, pid} = launched_app(worktree, host: host(%{helper_replies: %{"windows" => reply}}))
        assert error_code(QaDriver.call_tool(driver, "qa_open_status_menu", %{"pid" => pid})) == code
        assert_received {:cmd, "/bin/rm", ["-f", request], _opts}
        assert request =~ "status-menu/open-#{pid}"
      end
    end

    test "only opens the menu of an app the pass launched and that still runs", %{worktree: worktree} do
      {driver, pid} = launched_app(worktree)

      assert error_code(QaDriver.call_tool(driver, "qa_open_status_menu", %{"pid" => pid + 1})) == "qa_pid_not_launched"
      assert error_code(QaDriver.call_tool(driver, "qa_open_status_menu", %{})) == "invalid_arguments"
      assert {:ok, _quit} = QaDriver.call_tool(driver, "qa_quit_app", %{"pid" => pid})
      assert error_code(QaDriver.call_tool(driver, "qa_open_status_menu", %{"pid" => pid})) == "qa_pid_not_launched"
      refute_received {:cmd, "/bin/sh", ["-c", _script, "sh", _root, _pid], _opts}
    end
  end

  describe "worker_host" do
    @run_dir "/Users/qa/.symphony-qa/runs/run.abc123"

    # A stubbed QA host: the build and bundle script answer without touching the
    # local disk, and `read` returns the capture.
    defp remote_host(overrides \\ %{}) do
      test = self()
      bundle = Map.get(overrides, :bundle, fn dest -> {:ok, {"symphony-qa-app:#{dest}/Demo.app/Contents/MacOS/Demo\n", 0}} end)

      intercept = Map.get(overrides, :intercept, fn _executable, _args, _opts -> :pass end)

      host_cmd = fn
        "/bin/sh", ["-c", "make app"], _opts -> {:ok, {"Build complete!\n", 0}}
        "/bin/sh", ["-c", _script, "sh", _build_dir, @app, dest], _opts -> bundle.(dest)
        "/bin/sh", ["-c", _script, "sh", @run_dir, _bundle, name, _url], _opts -> {:ok, {"symphony-qa-checkout:#{@run_dir}/checkouts/#{name}\n", 0}}
        "/bin/sh", ["-c", _script, "sh", @run_dir, _fake_gh], _opts -> {:ok, {"symphony-qa-gh:#{@run_dir}/bin/gh\n", 0}}
        @helper, ["screenshot" | _args], _opts -> {:ok, {~s({"ok":true}), 0}}
        executable, args, opts -> default_cmd(executable, args, opts, replies(Map.take(overrides, [:helper_replies])))
      end

      cmd = fn executable, args, opts ->
        case intercept.(executable, args, opts) do
          :pass -> host_cmd.(executable, args, opts)
          result -> result
        end
      end

      Map.merge(host(Map.merge(%{cmd: cmd}, Map.take(overrides, [:ioreg]))), %{
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
        appearance_library: fn dir -> send(test, {:appearance_library, dir}) && {:ok, dir <> "/appearance/symphony-qa-appearance.dylib"} end,
        tunnel: fn ports -> send(test, {:tunnel, ports}) && Map.get(overrides, :tunnel, &open_tunnel/0).() end,
        cleanup: fn dir -> send(test, {:cleanup, dir}) && :ok end
      })
    end

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
            local_uuid: fn -> {:ok, @symphony_mac} end,
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

    test "builds the appearance library in the run directory and injects it", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host())
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})

      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{"appearance" => "dark"}) end)
      assert {:ok, %{"pid" => _pid}} = result
      assert_received {:appearance_library, @run_dir}
      assert_received {:launched, _executable, launch_opts, _port, _pid}
      assert {"SYMPHONY_BAR_QA_APPEARANCE", "dark"} in launch_opts[:env]
      assert {"DYLD_INSERT_LIBRARIES", @run_dir <> "/appearance/symphony-qa-appearance.dylib"} in launch_opts[:env]
      assert launch_opts[:args] == []
      QaDriver.stop(driver)
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

    test "runs nothing without a QA host, and says to set up the QA VM", %{worktree: worktree} do
      {{:ok, driver}, log} =
        with_log(fn ->
          playbook = %{build: "make app", app: @app}
          QaDriver.start_link(worktree: worktree, playbook: playbook, host: remote_host(), git: &clean_git/2)
        end)

      assert log =~ "QA driver has no worker_host"

      for tool <- ["qa_build", "qa_launch_app", "qa_build_release_pair", "qa_put_file", "qa_screenshot"] do
        assert {:error, {:qa_tool, "qa_worker_missing", message}} = QaDriver.call_tool(driver, tool, %{})
        assert message =~ "No QA VM is set up: `auto_review.worker_host` is unset"
        assert message =~ "never builds or runs a PR's macOS app on its own host"
        assert message =~ "answer with verdict `blocked`"
        assert message =~ "docs/configuration.md#running-qa-in-a-qa-vm"
      end

      assert {:ok, [_one, _two, _three]} = QaDriver.host_ports(driver)
      QaDriver.stop(driver)
      refute_received {:prepare, _home, _canary, _mode}
      refute_received {:tunnel, _ports}
      refute_received {:cmd, _executable, _args, _opts}
      refute_received {:cleanup, _dir}
    end

    test "refuses a QA host that is this Mac before preparing it, and one it can't tell apart", %{worktree: worktree} do
      # Under any name: the hardware matches, whatever case ioreg prints it in.
      driver = remote_driver(worktree, remote_host(%{ioreg: ioreg(String.downcase(@symphony_mac))}))

      for tool <- ["qa_build", "qa_launch_app", "qa_build_release_pair"] do
        assert {:error, {:qa_tool, "qa_worker_same_machine", message}} = QaDriver.call_tool(driver, tool, %{})
        assert message =~ "The QA host qa@qa-vm is this Mac (the same IOPlatformUUID): QA must run in a VM, never on the Symphony host"
        assert message =~ "answer with verdict `blocked`"
        assert message =~ "docs/configuration.md#running-qa-in-a-qa-vm"
      end

      QaDriver.stop(driver)
      refute_received {:prepare, _home, _canary, _mode}
      refute_received {:tunnel, _ports}
      refute_received {:cmd, "/bin/sh", ["-c", "make app"], _opts}
      refute_received {:cleanup, _dir}

      driver = remote_driver(worktree, remote_host(%{ioreg: {:error, :timeout}}))
      assert {:error, {:qa_tool, "qa_worker_unreachable", message}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert message =~ "The QA host qa@qa-vm could not be checked: the hardware UUID of the QA host could not be read: ioreg could not run: :timeout."
      refute_received {:prepare, _home, _canary, _mode}
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

    test "copies the API fixtures into the run directory and points the app at them", %{worktree: worktree} do
      test = self()

      ship = fn tar, dest ->
        if String.contains?(dest, "/api-fixtures-") do
          send(test, {:shipped_fixtures, tar, dest, :erl_tar.extract(String.to_charlist(tar), [:memory])})
        end

        :ok
      end

      dir = Path.join(worktree, "macos/Tests/Fixtures/director-app/running/api/v1")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "overview.json"), ~s({"running":2}))

      driver = remote_driver(worktree, Map.put(remote_host(), :ship, ship))
      %{scratch_dir: scratch_dir} = GenServer.call(driver, :config)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})

      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{"api_fixtures" => "macos/Tests/Fixtures/director-app/running"}) end)
      assert {:ok, %{"pid" => pid, "api_fixtures" => copy}} = result
      assert_received {:shipped_fixtures, tar, ^copy, {:ok, [{~c"api/v1/overview.json", ~s({"running":2})}]}}
      assert String.starts_with?(copy, @run_dir <> "/api-fixtures-")
      assert String.starts_with?(tar, scratch_dir <> "/")
      refute File.exists?(tar)
      assert_received {:launched, _executable, launch_opts, _port, ^pid}
      assert [{"SYMPHONY_BAR_QA_ROOT", _root}, {"SYMPHONY_QA_OPENROUTER_URL", _url}, {"SYMPHONY_BAR_QA_API_FIXTURES", ^copy}] = launch_opts[:env]

      failing =
        remote_driver(
          worktree,
          Map.put(remote_host(), :ship, fn tar, dest -> if String.contains?(dest, "/api-fixtures-"), do: send(test, {:failed_tar, tar}) && {:error, "exit 1: disk full"}, else: :ok end)
        )

      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(failing, "qa_build", %{})
      assert {:error, {:qa_tool, "qa_launch_failed", message}} = QaDriver.call_tool(failing, "qa_launch_app", %{"api_fixtures" => "macos/Tests/Fixtures/director-app/running"})
      assert message =~ "api_fixtures directory could not be copied to the QA host: exit 1: disk full"
      assert_received {:failed_tar, failed_tar}
      refute File.exists?(failed_tar)
      refute_received {:launched, _executable, _opts, _port, _pid}
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
      {:ok, [gh_port, linear_port, feed_port | _rest]} = QaDriver.host_ports(driver)

      args = %{
        "gh_stub_port" => gh_port,
        "linear_stub_port" => linear_port,
        "open_panel_dir" => path,
        "update_feed_port" => feed_port,
        "update_check_interval_seconds" => 30
      }

      {{:ok, %{"pid" => _pid}}, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", args) end)
      assert_received {:launched, _executable, launch_opts, _port, _pid}

      assert [
               {"SYMPHONY_BAR_QA_ROOT", _qa_root},
               {"SYMPHONY_QA_OPENROUTER_URL", _stub_url},
               {"SYMPHONY_BAR_GH", @run_dir <> "/bin/gh"},
               {"SYMPHONY_QA_GH_URL", gh_url},
               {"SYMPHONY_QA_LINEAR_URL", linear_url},
               {"SYMPHONY_BAR_QA_OPEN_PANEL_DIR", ^path},
               {"SYMPHONY_BAR_UPDATE_URL", feed_url},
               {"SYMPHONY_BAR_UPDATE_CHECK_INTERVAL", "30"}
             ] = launch_opts[:env]

      assert gh_url == "http://localhost:#{gh_port}"
      assert linear_url == "http://localhost:#{linear_port}/graphql"
      assert feed_url == "http://localhost:#{feed_port}/releases/latest"

      driver = remote_driver(worktree, remote_host(%{put: {:error, "exit 1: disk full"}}))

      assert {:error, {:qa_tool, "qa_put_checkout_failed", message}} =
               QaDriver.call_tool(driver, "qa_put_checkout", %{"local_path" => bundle, "remote_url" => "https://github.com/acme/widgets"})

      assert message =~ "The bundle could not be copied to the QA host: exit 1: disk full"
    end

    # The release pair's commands on the QA host, which answer without touching the local disk.
    defp remote_pair(executable, args, _opts) do
      case {executable, args} do
        {"/bin/sh", ["-c", "make -C macos release-pair" <> _rest, "sh", _out]} -> {:ok, {"release pair built\n", 0}}
        {"/bin/sh", ["-c", script, "sh" | rest]} -> remote_pair_script(script, rest)
        {"/bin/sh", [_script, "--use"]} -> {:ok, {"symphony-qa-signing-identity:#{String.duplicate("AB", 20)}\nsymphony-qa-signing-keychain:/Users/qa/k.keychain-db\n", 0}}
        {"/bin/cat", [_manifest]} -> {:ok, {~s({"n":{"build":90001},"n1":{"build":90002}}), 0}}
        {"/usr/bin/curl", _args} -> {:ok, {"publish\n", 0}}
        {"/bin/ps", _args} -> {:ok, {"", 0}}
        _other -> :pass
      end
    end

    defp remote_pair_script(script, rest) do
      cond do
        script =~ "symphony-qa-pair-src" -> {:ok, {"symphony-qa-pair-src:#{List.last(rest)}\n", 0}}
        script =~ "symphony-qa-feed-server" -> {:ok, {"symphony-qa-feed-server:#{List.last(rest)}/stubs/update_feed.py\n", 0}}
        script =~ "symphony-qa-pair-app" -> {:ok, {"symphony-qa-pair-app:#{List.last(rest)}/Symphony.app\n", 0}}
        script =~ "symphony-qa-relaunch-script" -> {:ok, {"symphony-qa-relaunch-script:#{hd(rest)}/bin/relaunch\n", 0}}
        true -> :pass
      end
    end

    defp bundle_fails(["bundle" | _args], _cwd), do: {"fatal: bad revision HEAD\n", 128}
    defp bundle_fails(args, cwd), do: clean_git(args, cwd)

    defp bundling_git(test) do
      fn
        ["bundle", "create", bundle, "HEAD", "--tags"], _cwd ->
          File.write!(bundle, "git bundle")
          send(test, {:bundled, bundle})
          {"", 0}

        args, cwd ->
          clean_git(args, cwd)
      end
    end

    test "builds the pair from a bundle of HEAD on the QA host and serves its feed there", %{worktree: worktree} do
      test = self()
      host = remote_host(%{intercept: &remote_pair/3})

      host =
        Map.put(host, :ship, fn tar, dest ->
          {:ok, files} = :erl_tar.extract(String.to_charlist(tar), [:memory])
          send(test, {:ship, files, dest})
          :ok
        end)

      driver = remote_driver(worktree, host, bundling_git(test))
      %{scratch_dir: scratch_dir} = GenServer.call(driver, :config)
      src = @run_dir <> "/pair-src"

      assert {:ok, %{"exit_status" => 0, "manifest" => %{"n" => %{"build" => 90_001}}}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
      assert_received {:bundled, bundle}
      assert bundle == Path.join(scratch_dir, "pair-bundle/head.bundle")
      refute File.exists?(bundle)
      assert_received {:ship, [{~c"head.bundle", "git bundle"}], dest}
      assert dest == @run_dir <> "/pair-bundle"
      assert_received {:cmd, "/bin/sh", ["-c", _clone, "sh", ^dest, ^src], _opts}
      script = src <> "/scripts/qa/install-test-signing-identity.sh"
      assert_received {:cmd, "/bin/sh", [^script, "--use"], identity_opts}
      assert identity_opts[:cd] == src
      assert_received {:cmd, "/bin/sh", ["-c", _copy, "sh", ^src, feed_dir], _opts}
      assert feed_dir == @run_dir <> "/update-feed"
      assert_received {:cmd, "/bin/sh", ["-c", "make -C macos release-pair" <> _rest, "sh", out], build_opts}
      assert out == @run_dir <> "/release-pair"
      assert build_opts[:cd] == src
      assert {"SYMPHONY_E2E_SIGNING_IDENTITY", String.duplicate("AB", 20)} in build_opts[:remote_env]
      assert {"SYMPHONY_E2E_KEYCHAIN", "/Users/qa/k.keychain-db"} in build_opts[:remote_env]

      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{"release_pair" => true}) end)
      assert {:ok, %{"pid" => pid, "bundle" => bundle}} = result
      assert String.starts_with?(bundle, @run_dir <> "/pair-launches/")
      assert_received {:launched, "/usr/bin/python3", feed_opts, _port, _feed_pid}
      assert feed_opts[:env] == []
      assert [_script, "--dir", @run_dir <> "/release-pair/feed", "--port", port | _rest] = feed_opts[:args]
      assert String.to_integer(port) in 20_000..59_999
      assert_received {:launched, executable, launch_opts, _port, ^pid}
      assert executable == bundle <> "/Contents/MacOS/Demo"
      assert {"SYMPHONY_BAR_UPDATE_URL", "http://127.0.0.1:#{port}/releases/latest"} in launch_opts[:env]
      assert {"SYMPHONY_UPDATE_OPEN", @run_dir <> "/bin/relaunch"} in launch_opts[:env]
      assert {"SYMPHONY_BAR_QA_ROOT", @run_dir <> "/app-root"} in launch_opts[:env]

      QaDriver.stop(driver)
      assert_received {:cmd, "/bin/ps", _args, _opts}
      assert_received {:cleanup, @run_dir}
    end

    test "reports a checkout it can't bundle, copy or clone on the QA host", %{worktree: worktree} do
      test = self()

      for {git, overrides, text} <- [
            {&bundle_fails/2, %{}, "git bundle failed (exit 128)"},
            {fn _args, _cwd -> {"", 0} end, %{}, "could not be packed for the QA host"},
            {bundling_git(test), %{ship: {:error, "exit 1: disk full"}}, "could not be copied to the QA host: exit 1: disk full"},
            {bundling_git(test), %{clone: {:ok, {"fatal: bad bundle\n", 128}}}, "git could not clone the checkout on the QA host: exit 128: fatal: bad bundle"},
            {bundling_git(test), %{clone: {:ok, {"cloned\n", 0}}}, "checkout on the QA host was not confirmed"}
          ] do
        clone = Map.get(overrides, :clone)

        intercept = fn
          "/bin/sh", ["-c", script, "sh" | _rest] = args, opts ->
            if clone && script =~ "symphony-qa-pair-src", do: clone, else: remote_pair("/bin/sh", args, opts)

          executable, args, opts ->
            remote_pair(executable, args, opts)
        end

        driver = remote_driver(worktree, remote_host(Map.merge(%{intercept: intercept}, Map.take(overrides, [:ship]))), git)
        assert {:error, {:qa_tool, code, message}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
        assert code in ["qa_git_failed", "qa_release_pair_failed"]
        assert message =~ text
        refute_received {:cmd, "/bin/sh", [_script, "--use"], _opts}
        QaDriver.stop(driver)
      end
    end

    test "reports a capture it cannot copy back", %{worktree: worktree} do
      driver = remote_driver(worktree, remote_host(%{read: {:error, :unreadable}}))
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {{:ok, %{"pid" => pid}}, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert error_code(QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "settings"})) == "qa_screenshot_failed"
    end
  end

  describe "release pair" do
    @sha "0123456789ABCDEF0123456789ABCDEF01234567"
    @keychain "/Users/qa/Library/Keychains/symphony-qa-signing.keychain-db"
    @identity_output "symphony-qa-signing-identity:#{@sha}\nsymphony-qa-signing-keychain:#{@keychain}\n"
    @manifest %{
      "commit" => "abc",
      "signing_identity" => @sha,
      "n" => %{"version" => "0.0.1.90001", "build" => 90_001, "app" => "N/Symphony.app"},
      "n1" => %{"version" => "0.0.1.90002", "build" => 90_002, "tag" => "v0.0.1.90002-release-pair", "feed" => "feed"}
    }

    setup %{worktree: worktree} do
      stubs = Path.join(worktree, "test/support/stubs")
      File.mkdir_p!(stubs)
      for file <- ~w(__init__.py _server.py update_feed.py), do: File.write!(Path.join(stubs, file), "# #{file}\n")
      {:ok, mode} = Agent.start_link(fn -> "publish" end)
      %{feed_mode: mode}
    end

    # What `make -C macos release-pair` lays out under its RELEASE_PAIR_OUT.
    defp write_pair(out, manifest \\ Jason.encode!(@manifest)) do
      macos = Path.join(out, "N/Symphony.app/Contents/MacOS")
      File.mkdir_p!(macos)
      File.write!(Path.join(out, "N/Symphony.app/Contents/Info.plist"), "<plist/>")
      File.write!(Path.join(macos, "Demo"), "release-n")
      File.mkdir_p!(Path.join(out, "feed"))
      File.write!(Path.join(out, "feed/version.json"), ~s({"version":"0.0.1.90002","build":90002}))
      File.write!(Path.join(out, "manifest.json"), manifest)
      {:ok, {"release pair in #{out}\n", 0}}
    end

    # The pair's commands: the identity check, the build, the feed (its mode
    # lives in the `mode` agent), the bundle's versions and the process list.
    # The driver's own scripts run for real. `intercept` answers first unless it
    # returns `:pass`.
    defp pair_cmd(mode, opts) do
      pair = %{
        identity: Keyword.get(opts, :identity, {:ok, {@identity_output, 0}}),
        build: Keyword.get(opts, :build, &write_pair/1),
        ps: Keyword.get(opts, :ps, {:ok, {"", 0}}),
        mode: mode
      }

      intercept = Keyword.get(opts, :intercept, fn _executable, _args, _opts -> :pass end)

      fn executable, args, cmd_opts ->
        case intercept.(executable, args, cmd_opts) do
          :pass -> pair_default(executable, args, cmd_opts, pair)
          result -> result
        end
      end
    end

    defp pair_default("/bin/sh", [_script, "--use"], _opts, pair), do: pair.identity
    defp pair_default("/bin/sh", ["-c", "make -C macos release-pair" <> _rest, "sh", out], _opts, pair), do: pair.build.(out)
    defp pair_default("/usr/bin/curl", args, _opts, pair), do: feed_reply(pair.mode, args)

    # `ditto` is macOS-only; the copy of N runs for real with `cp -R` so the tests run on Linux CI.
    defp pair_default("/bin/sh", ["-c", script | args], opts, _pair) do
      if script =~ "ditto ",
        do: Host.cmd("/bin/sh", ["-c", String.replace(script, "ditto ", "cp -R ") | args], opts),
        else: default_cmd("/bin/sh", ["-c", script | args], opts, replies(%{}))
    end

    defp pair_default("/bin/ps", _args, _opts, pair), do: pair.ps
    defp pair_default("/bin/kill", _args, _opts, _pair), do: {:ok, {"", 0}}
    defp pair_default(executable, args, opts, _pair) when executable in ["/bin/cat", "/usr/bin/tail"], do: Host.cmd(executable, args, opts)
    defp pair_default("/usr/bin/plutil", ["-extract", "CFBundleShortVersionString" | _rest], _opts, _pair), do: {:ok, {"0.0.1.90002\n", 0}}
    defp pair_default("/usr/bin/plutil", ["-extract", "CFBundleVersion" | _rest], _opts, _pair), do: {:ok, {"90002\n", 0}}
    defp pair_default(executable, args, opts, _pair), do: default_cmd(executable, args, opts, replies(%{}))

    # A POST sets the mode it sends; both answer the current mode.
    defp feed_reply(mode, args) do
      case Enum.drop_while(args, &(&1 != "--data")) do
        ["--data", value | _rest] -> Agent.update(mode, fn _old -> value end)
        [] -> :ok
      end

      {:ok, {Agent.get(mode, & &1) <> "\n", 0}}
    end

    defp pair_driver(worktree, mode, cmd_opts \\ [], driver_opts \\ []) do
      host = host(Map.merge(%{cmd: pair_cmd(mode, cmd_opts)}, Keyword.get(driver_opts, :host, %{})))
      start_driver(worktree, [host: host] ++ Keyword.take(driver_opts, [:git, :release_pair_timeout_ms, :relaunch_poll_ms, :feed_poll]))
    end

    defp built_pair(worktree, mode, cmd_opts \\ [], driver_opts \\ []) do
      driver = pair_driver(worktree, mode, cmd_opts, driver_opts)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
      driver
    end

    defp launch_pair(driver, args \\ %{}) do
      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", Map.put(args, "release_pair", true)) end)
      result
    end

    defp env_value(launch_opts, name) do
      Enum.find_value(launch_opts[:env], fn
        {key, value} when is_binary(value) and key == name -> value
        {key, value} when is_list(value) -> if to_string(key) == name, do: to_string(value)
        _other -> nil
      end)
    end

    # What the app's update helper does once it installed an update: run the
    # relaunch stand-in it was given with the bundle to start.
    defp ask_relaunch(launch_opts, bundle) do
      relaunch = env_value(launch_opts, "SYMPHONY_UPDATE_OPEN")
      {"", 0} = System.cmd("/bin/sh", [relaunch, bundle], env: [{"SYMPHONY_BAR_QA_ROOT", env_value(launch_opts, "SYMPHONY_BAR_QA_ROOT")}])
    end

    test "builds the pair with the QA signing identity where the app runs and returns its manifest", %{worktree: worktree, feed_mode: mode} do
      driver = pair_driver(worktree, mode)
      %{host_dir: host_dir} = GenServer.call(driver, :config)
      source = Path.join(host_dir, "pair-src")

      assert {:ok, %{"exit_status" => 0, "manifest" => @manifest, "output" => output, "note" => note}} =
               QaDriver.call_tool(driver, "qa_build_release_pair", %{})

      assert output =~ "release pair in #{host_dir}/release-pair"
      assert note =~ "release_pair: true"
      script = Path.join(source, "scripts/qa/install-test-signing-identity.sh")
      assert_received {:cmd, "/bin/sh", [^script, "--use"], identity_opts}
      assert identity_opts[:cd] == source
      assert_received {:cmd, "/bin/sh", ["-c", "make -C macos release-pair" <> _rest, "sh", out], build_opts}
      assert out == Path.join(host_dir, "release-pair")
      assert build_opts[:cd] == source
      assert build_opts[:timeout_ms] == 1_800_000
      assert env_value(build_opts, "SYMPHONY_E2E_SIGNING_IDENTITY") == @sha
      assert env_value(build_opts, "SYMPHONY_E2E_KEYCHAIN") == @keychain
      refute env_value(build_opts, "SYMPHONY_E2E_TRUST_CERT")
      assert File.read!(Path.join(host_dir, "update-feed/stubs/update_feed.py")) == "# update_feed.py\n"
      assert %{pair: %{manifest: @manifest}} = :sys.get_state(driver)

      # The plain build still builds and launches beside the pair.
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {result, _log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert {:ok, %{"pid" => _pid}} = result
    end

    test "refuses to build without a trusted QA signing identity", %{worktree: worktree, feed_mode: mode} do
      for {reply, code, text} <- [
            {{:ok, {"install-test-signing-identity: not installed: there is no keychain\n", 3}}, "qa_signing_identity_missing", "no QA signing identity"},
            {{:ok, {"install-test-signing-identity: not trusted\n", 4}}, "qa_signing_identity_untrusted", "not trusted for code signing"},
            {{:ok, {"symphony-qa-signing-identity:nope\n", 0}}, "qa_signing_identity_check_failed", "printed no identity"},
            {{:ok, {"sh: no such file\n", 127}}, "qa_signing_identity_check_failed", "exit 127"},
            {{:error, :timeout}, "qa_signing_identity_check_failed", ":timeout"}
          ] do
        driver = pair_driver(worktree, mode, identity: reply)
        assert {:error, {:qa_tool, ^code, message}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
        assert message =~ text
        assert message =~ "answer with verdict `blocked`"
        assert message =~ "scripts/qa/install-test-signing-identity.sh once on the QA host"
        refute_received {:cmd, "/bin/sh", ["-c", "make -C macos release-pair" <> _rest, "sh", _out], _opts}
        assert error_code(launch_pair(driver)) == "qa_release_pair_not_built"
        QaDriver.stop(driver)
      end

      driver = pair_driver(worktree, mode, identity: {:ok, {String.duplicate("x", 600) <> "\n", 3}})
      assert {:error, {:qa_tool, "qa_signing_identity_missing", message}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
      assert message =~ "identity: …" <> String.duplicate("x", 499)
    end

    test "reports a failing build, a timeout and a missing manifest, and forgets the pair", %{worktree: worktree, feed_mode: mode} do
      driver = pair_driver(worktree, mode, build: fn _out -> {:ok, {"error: make release failed\n", 2}} end)
      assert {:ok, %{"exit_status" => 2, "output" => "error: make release failed\n"} = result} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
      refute Map.has_key?(result, "manifest")
      assert error_code(launch_pair(driver)) == "qa_release_pair_not_built"

      driver = pair_driver(worktree, mode, [build: fn _out -> {:error, :timeout} end], release_pair_timeout_ms: 5_000)
      assert {:error, {:qa_tool, "qa_release_pair_timeout", message}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
      assert message =~ "within 5000 ms"
      assert error_code(launch_pair(driver)) == "qa_release_pair_not_built"

      driver = pair_driver(worktree, mode, build: fn _out -> {:error, :enoent} end)
      assert {:error, {:qa_tool, "qa_release_pair_failed", message}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
      assert message =~ "could not start: :enoent"

      for manifest <- ["not json", ~s({"n":{}})] do
        driver = pair_driver(worktree, mode, build: &write_pair(&1, manifest))
        assert {:error, {:qa_tool, "qa_release_pair_failed", message}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
        assert message =~ "manifest.json could not be read"
        assert error_code(launch_pair(driver)) == "qa_release_pair_not_built"
      end

      driver = pair_driver(worktree, mode, build: fn _out -> {:ok, {"built nothing\n", 0}} end)
      assert {:error, {:qa_tool, "qa_release_pair_failed", message}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
      assert message =~ "manifest.json could not be read: exit 1"
    end

    test "refuses a modified worktree and a checkout without the update feed's code", %{worktree: worktree, feed_mode: mode} do
      dirty = pair_driver(worktree, mode, [], git: fn _args, _cwd -> {" M macos/Sources/App.swift\0", 0} end)
      assert {:error, {:qa_tool, "qa_worktree_modified", message}} = QaDriver.call_tool(dirty, "qa_build_release_pair", %{})
      assert message =~ "macos/Sources/App.swift"
      refute_received {:cmd, "/bin/sh", [_script, "--use"], _opts}

      unconfirmed = fn
        "/bin/sh", ["-c", script, "sh" | _rest], _opts -> if script =~ "symphony-qa-feed-server", do: {:ok, {"", 0}}, else: :pass
        _executable, _args, _opts -> :pass
      end

      driver = pair_driver(worktree, mode, intercept: unconfirmed)
      assert {:error, {:qa_tool, "qa_release_pair_failed", message}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
      assert message =~ "update feed's code could not be copied"

      File.rm!(Path.join(worktree, "test/support/stubs/_server.py"))
      driver = pair_driver(worktree, mode)
      assert {:error, {:qa_tool, "qa_release_pair_failed", message}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
      assert message =~ "_server.py is not a regular file"
      refute_received {:cmd, "/bin/sh", ["-c", "make -C macos release-pair" <> _rest, "sh", _out], _opts}
    end

    test "launches N from a fresh copy beside the pair's feed and drives the app its update helper relaunches", %{worktree: worktree, feed_mode: mode} do
      driver = built_pair(worktree, mode, [], relaunch_poll_ms: 10)
      %{scratch_dir: scratch_dir, host_dir: host_dir, qa_root: qa_root} = GenServer.call(driver, :config)

      assert {:ok, %{"pid" => pid, "qa_mode" => true, "release_pair" => true, "bundle" => bundle, "note" => note}} =
               launch_pair(driver, %{"update_check_interval_seconds" => 5, "appearance" => "dark"})

      assert note =~ "qa_relaunched_app"
      assert String.starts_with?(bundle, Path.join(host_dir, "pair-launches") <> "/")
      assert File.read!(Path.join(bundle, "Contents/MacOS/Demo")) == "release-n"

      assert_received {:launched, "/usr/bin/python3", feed_opts, _feed_port, feed_pid}
      assert feed_opts[:cd] == Path.join(host_dir, "update-feed")
      assert [script, "--dir", feed_dir, "--port", port, "--log", log] = feed_opts[:args]
      assert script == Path.join(host_dir, "update-feed/stubs/update_feed.py")
      assert feed_dir == Path.join(host_dir, "release-pair/feed")
      assert log == Path.join(host_dir, "update-feed/feed.log")
      assert_received {:cmd, "/usr/bin/curl", ["-sS", "-f", "--max-time", "1", ready_url], _opts}
      assert ready_url == "http://127.0.0.1:#{port}/_feed/mode"

      assert_received {:launched, executable, launch_opts, _port, ^pid}
      assert executable == Path.join(bundle, "Contents/MacOS/Demo")
      assert env_value(launch_opts, "SYMPHONY_BAR_QA_ROOT") == qa_root
      assert env_value(launch_opts, "SYMPHONY_BAR_UPDATE_URL") == "http://127.0.0.1:#{port}/releases/latest"
      assert env_value(launch_opts, "SYMPHONY_BAR_UPDATE_CHECK_INTERVAL") == "5"
      assert env_value(launch_opts, "SYMPHONY_BAR_QA_APPEARANCE") == "dark"
      assert env_value(launch_opts, "SYMPHONY_UPDATE_OPEN") == Path.join(host_dir, "bin/relaunch")

      # A second launch gets its own copy of N and the same feed.
      assert {:ok, %{"pid" => second, "bundle" => other_bundle}} = launch_pair(driver)
      assert other_bundle != bundle
      refute_received {:launched, "/usr/bin/python3", _opts, _port, _pid}
      assert {:ok, %{"quit" => true}} = QaDriver.call_tool(driver, "qa_quit_app", %{"pid" => second})

      # N installed N+1 in its copy and asks for it to start again.
      ask_relaunch(launch_opts, bundle)

      assert {:ok, %{"pid" => relaunched, "qa_mode" => true, "bundle" => ^bundle, "version" => "0.0.1.90002", "build" => "90002", "note" => note}} =
               QaDriver.call_tool(driver, "qa_relaunched_app", %{"wait_seconds" => 5})

      assert note =~ "rolled back to"
      assert_received {:launched, ^executable, relaunch_opts, _port, ^relaunched}
      assert env_value(relaunch_opts, "SYMPHONY_BAR_UPDATE_URL") == "http://127.0.0.1:#{port}/releases/latest"
      assert env_value(relaunch_opts, "SYMPHONY_BAR_QA_APPEARANCE") == "dark"

      assert {:ok, %{"files" => [%{"path" => "qa-evidence/after-update.png"}]}} =
               QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => relaunched, "name" => "after-update"})

      # Nothing more to start; a request for a bundle no launch made is refused.
      assert {:error, {:qa_tool, "qa_no_relaunch", message}} = QaDriver.call_tool(driver, "qa_relaunched_app", %{"wait_seconds" => 1})
      assert message =~ "within 1 s"
      ask_relaunch(launch_opts, "/Applications/Symphony.app")
      assert {:error, {:qa_tool, "qa_relaunch_unknown", message}} = QaDriver.call_tool(driver, "qa_relaunched_app", %{})
      assert message =~ "/Applications/Symphony.app"

      # The feed: its mode, switched, and the app's requests without the driver's own.
      File.write!(log, [
        ~s({"method":"GET","path":"/releases/latest","status":200}\n),
        ~s({"method":"GET","path":"/_feed/mode","status":200}\n),
        "not json\n",
        ~s({"method":"GET","path":"/Symphony-0.0.1.90002.zip","status":200}\n)
      ])

      assert {:ok, %{"mode" => "publish", "url" => url, "requests" => [%{"path" => "/releases/latest"}, %{"path" => "/Symphony-0.0.1.90002.zip"}]}} =
               QaDriver.call_tool(driver, "qa_update_feed", %{})

      assert url == "http://127.0.0.1:#{port}/releases/latest"
      assert {:ok, %{"mode" => "none"}} = QaDriver.call_tool(driver, "qa_update_feed", %{"mode" => "none"})
      assert_received {:cmd, "/usr/bin/curl", ["-sS", "-f", "--max-time", "5", "-X", "POST", "--data", "none", _url], _opts}

      # Stopping the pass stops the feed and anything left under its directory.
      QaDriver.stop(driver)
      assert_received {:killed, ^feed_pid}
      assert_received {:killed, ^relaunched}
      assert_received {:cmd, "/bin/ps", ["-axww", "-o", "pid=,command="], _opts}
      refute File.exists?(host_dir)
      refute File.exists?(scratch_dir)
    end

    test "stops what a pass left under its directory", %{worktree: worktree, feed_mode: mode} do
      ps = fn host_dir ->
        {:ok,
         {"  123 /usr/bin/python3 #{host_dir}/update-feed/stubs/update_feed.py\n 456 /bin/sh #{host_dir}/app-root/updates/update-helper.sh 1 a b c\n 789 /Applications/Symphony.app/Contents/MacOS/SymphonyBar\n",
          0}}
      end

      {:ok, holder} = Agent.start_link(fn -> nil end)

      intercept = fn
        "/bin/ps", _args, _opts -> ps.(Agent.get(holder, & &1))
        _executable, _args, _opts -> :pass
      end

      driver = built_pair(worktree, mode, intercept: intercept)
      %{host_dir: host_dir} = GenServer.call(driver, :config)
      Agent.update(holder, fn _old -> host_dir end)
      assert {:ok, %{"pid" => _pid}} = launch_pair(driver)

      QaDriver.stop(driver)
      assert_received {:cmd, "/bin/ps", _args, _opts}
      assert_received {:cmd, "/bin/kill", ["-TERM", "123", "456"], _opts}

      # A pass that launched no pair leaves the process list alone.
      driver = built_pair(worktree, mode)
      QaDriver.stop(driver)
      refute_received {:cmd, "/bin/ps", _args, _opts}

      # A process list it can't read stops nothing.
      driver = built_pair(worktree, mode, ps: {:error, :timeout})
      assert {:ok, %{"pid" => _pid}} = launch_pair(driver)
      QaDriver.stop(driver)
      assert_received {:cmd, "/bin/ps", _args, _opts}
      refute_received {:cmd, "/bin/kill", _args, _opts}
    end

    test "refuses release-pair arguments it can't honour", %{worktree: worktree, feed_mode: mode} do
      driver = pair_driver(worktree, mode)
      assert {:error, {:qa_tool, "invalid_arguments", message}} = QaDriver.call_tool(driver, "qa_launch_app", %{"release_pair" => "yes"})
      assert message =~ "`release_pair` must be true or false"
      assert error_code(launch_pair(driver)) == "qa_release_pair_not_built"
      assert error_code(QaDriver.call_tool(driver, "qa_relaunched_app", %{})) == "qa_release_pair_not_launched"
      assert error_code(QaDriver.call_tool(driver, "qa_update_feed", %{})) == "qa_update_feed_not_running"

      {:ok, [port | _ports]} = QaDriver.host_ports(driver)
      assert {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build_release_pair", %{})
      assert {:error, {:qa_tool, "invalid_arguments", message}} = launch_pair(driver, %{"update_feed_port" => port})
      assert message =~ "serves the pair's own feed"
      assert error_code(launch_pair(driver, %{"gh_stub_port" => 1})) == "invalid_arguments"
      refute_received {:launched, _executable, _opts, _port, _pid}

      assert {:ok, %{"pid" => _pid}} = launch_pair(driver)
      assert error_code(QaDriver.call_tool(driver, "qa_relaunched_app", %{"wait_seconds" => 0})) == "invalid_arguments"
      assert error_code(QaDriver.call_tool(driver, "qa_relaunched_app", %{"wait_seconds" => 301})) == "invalid_arguments"

      for bad <- ["off", 5] do
        assert {:error, {:qa_tool, "invalid_arguments", message}} = QaDriver.call_tool(driver, "qa_update_feed", %{"mode" => bad})
        assert message =~ "publish, none, forbidden"
      end

      # `release_pair: false` is the plain launch.
      assert error_code(QaDriver.call_tool(driver, "qa_launch_app", %{"release_pair" => false})) == "qa_not_built"
    end

    test "retries a feed that exits or never answers, and fails the launch when it can't start", %{worktree: worktree, feed_mode: mode} do
      test = self()
      {:ok, starts} = Agent.start_link(fn -> [:exits, :cat] end)

      launch = fn
        "/usr/bin/python3", opts ->
          send(test, {:feed_start, opts[:args]})

          case Agent.get_and_update(starts, fn [next | rest] -> {next, rest ++ [:cat]} end) do
            :exits ->
              port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", "echo 'OSError: [Errno 48] Address already in use'; exit 2"]])
              # The exit reaches the driver before the readiness check.
              receive do
                {^port, {:exit_status, _status}} = exited -> send(self(), exited)
              end

              {:ok, port, 90_001}

            :cat ->
              {:ok, Port.open({:spawn, "cat"}, [:binary, :exit_status]), 90_002}
          end

        executable, opts ->
          port = Port.open({:spawn, "cat"}, [:binary])
          pid = System.unique_integer([:positive]) + 100_000
          send(test, {:launched, executable, opts, port, pid})
          {:ok, port, pid}
      end

      driver = built_pair(worktree, mode, [], host: %{launch: launch})
      assert {:ok, %{"pid" => _pid}} = launch_pair(driver)
      assert_received {:feed_start, [_script, "--dir", _dir, "--port", _first | _rest]}
      assert_received {:feed_start, [_script, "--dir", _dir, "--port", _second | _rest]}
      assert_received {:killed, 90_001}
      assert %{feed: %{os_pid: 90_002}} = :sys.get_state(driver)

      # A feed that exits later is started again by the next launch.
      %{feed: %{port: feed_port}} = :sys.get_state(driver)

      log =
        capture_log(fn ->
          send(driver, {feed_port, {:exit_status, 0}})
          wait_until(fn -> :sys.get_state(driver).feed == nil end)
        end)

      assert log =~ "update feed exited status=0"
      assert error_code(QaDriver.call_tool(driver, "qa_update_feed", %{})) == "qa_update_feed_not_running"
      assert {:ok, %{"pid" => _pid}} = launch_pair(driver)
      assert_received {:feed_start, _args}

      # A feed that never answers.
      silent = fn
        "/usr/bin/curl", _args, _opts -> {:ok, {"curl: (7) Failed to connect", 7}}
        _executable, _args, _opts -> :pass
      end

      driver = built_pair(worktree, mode, [intercept: silent], feed_poll: {2, 1})
      assert {:error, {:qa_tool, "qa_update_feed_failed", message}} = launch_pair(driver)
      assert message =~ "never answered on port"
      assert message =~ "Failed to connect"

      for _attempt <- 1..3, do: assert_received({:launched, "/usr/bin/python3", _opts, _port, _pid})
      refute_received {:launched, "/usr/bin/python3", _opts, _port, _pid}

      unlaunchable = fn
        "/usr/bin/python3", _opts -> {:error, :enoent}
        executable, opts -> launch.(executable, opts)
      end

      driver = built_pair(worktree, mode, [], host: %{launch: unlaunchable})
      assert {:error, {:qa_tool, "qa_update_feed_failed", message}} = launch_pair(driver)
      assert message =~ "could not start: :enoent"
    end

    test "refuses a release N whose CFBundleExecutable it can't read or use", %{worktree: worktree, feed_mode: mode} do
      for reply <- [{:ok, {"../Demo\n", 0}}, {:ok, {"\n", 0}}, {:ok, {"..", 0}}, {:ok, {"", 1}}, {:error, :timeout}] do
        plutil = fn
          "/usr/bin/plutil", ["-extract", "CFBundleExecutable" | _rest], _opts -> reply
          _executable, _args, _opts -> :pass
        end

        driver = built_pair(worktree, mode, intercept: plutil)
        assert {:error, {:qa_tool, "qa_app_missing", message}} = launch_pair(driver)
        assert message =~ "CFBundleExecutable"
        refute_received {:launched, _executable, _opts, _port, _pid}
        QaDriver.stop(driver)
      end
    end

    test "reports a copy, relaunch stand-in, request or feed call that fails", %{worktree: worktree, feed_mode: mode} do
      driver = built_pair(worktree, mode)
      %{host_dir: host_dir} = GenServer.call(driver, :config)
      File.rm_rf!(Path.join(host_dir, "release-pair/N"))
      assert {:error, {:qa_tool, "qa_launch_failed", message}} = launch_pair(driver)
      assert message =~ "holds no N/Symphony.app"

      driver = built_pair(worktree, mode)
      %{host_dir: host_dir} = GenServer.call(driver, :config)
      File.write!(Path.join(host_dir, "bin"), "")
      assert {:error, {:qa_tool, "qa_launch_failed", message}} = launch_pair(driver)
      assert message =~ "relaunch stand-in could not be installed"

      unconfirmed = fn
        "/bin/sh", ["-c", script, "sh" | _rest], _opts -> if script =~ "symphony-qa-pair-app", do: {:ok, {"copied\n", 0}}, else: :pass
        _executable, _args, _opts -> :pass
      end

      driver = built_pair(worktree, mode, intercept: unconfirmed)
      assert {:error, {:qa_tool, "qa_launch_failed", message}} = launch_pair(driver)
      assert message =~ "copy of release N was not confirmed"

      unreadable = fn
        "/bin/sh", ["-c", script, "sh" | _rest], _opts -> if script =~ "symphony-qa-relaunch:", do: {:error, :timeout}, else: :pass
        "/usr/bin/tail", _args, _opts -> {:ok, {"tail: feed.log: Permission denied\n", 1}}
        _executable, _args, _opts -> :pass
      end

      driver = built_pair(worktree, mode, intercept: unreadable)
      assert {:ok, %{"pid" => _pid}} = launch_pair(driver)
      assert {:error, {:qa_tool, "qa_relaunch_failed", message}} = QaDriver.call_tool(driver, "qa_relaunched_app", %{})
      assert message =~ ":timeout"
      assert {:error, {:qa_tool, "qa_update_feed_failed", message}} = QaDriver.call_tool(driver, "qa_update_feed", %{})
      assert message =~ "request log could not be read: tail: feed.log: Permission denied"

      down = fn
        "/usr/bin/curl", ["-sS", "-f", "--max-time", "5", "-X" | _rest], _opts -> {:ok, {"curl: (22) The requested URL returned error: 400", 22}}
        "/usr/bin/tail", _args, _opts -> {:error, :timeout}
        "/usr/bin/plutil", ["-extract", "CFBundleVersion" | _rest], _opts -> {:error, :timeout}
        _executable, _args, _opts -> :pass
      end

      driver = built_pair(worktree, mode, [intercept: down], relaunch_poll_ms: 10)
      assert {:ok, %{"pid" => pid, "bundle" => bundle}} = launch_pair(driver)
      assert_received {:launched, _executable, launch_opts, _port, ^pid}
      assert {:error, {:qa_tool, "qa_update_feed_failed", message}} = QaDriver.call_tool(driver, "qa_update_feed", %{"mode" => "forbidden"})
      assert message =~ "did not answer: exit 22"
      assert {:error, {:qa_tool, "qa_update_feed_failed", message}} = QaDriver.call_tool(driver, "qa_update_feed", %{})
      assert message =~ "request log could not be read: :timeout"
      ask_relaunch(launch_opts, bundle)
      assert {:ok, %{"version" => "0.0.1.90002", "build" => nil}} = QaDriver.call_tool(driver, "qa_relaunched_app", %{})

      # A feed that has answered nothing has no log yet.
      driver = built_pair(worktree, mode)
      assert {:ok, %{"pid" => _pid}} = launch_pair(driver)
      assert {:ok, %{"mode" => "publish", "requests" => []}} = QaDriver.call_tool(driver, "qa_update_feed", %{})
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

    test "embeds the helper's source, and the appearance library's source and its build script" do
      assert Host.helper_source() =~ "SYMPHONY_QA_SSH"

      {source, build} = Host.appearance_source()
      assert source =~ "SYMPHONY_BAR_QA_APPEARANCE"
      assert source =~ "NSAppearanceNameDarkAqua"
      assert build =~ "clang -dynamiclib"
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
      assert QaDriver.launched_app?(start_driver(worktree)) == false
      {driver, pid} = launched_app(worktree, host: host(%{helper_replies: %{"ax-resize" => reply}}))
      assert QaDriver.wide_pass(driver) == nil
      assert QaDriver.launched_app?(driver)

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
      assert QaDriver.launched_app?(driver)
      QaDriver.stop(driver)
      assert QaDriver.wide_pass(driver) == nil
      assert QaDriver.wide_pass(nil) == nil
      assert QaDriver.launched_app?(driver) == false
      assert QaDriver.launched_app?(nil) == false
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
      assert crashed == ~s[New crash report (page "Decide", window 1400×900 pt) in ~/Library/Logs/DiagnosticReports on the QA host: Demo-2026-10-06-120000.ips.]

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

      {driver, pid} = launched_app(worktree, host: host(%{helper: fn _dir -> {:error, :swiftc_not_found} end}))
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
