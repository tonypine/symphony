defmodule SymphonyElixir.QaDriverRemoteTest do
  # A fake `ssh` on PATH runs each remote command locally, with HOME and PATH
  # pointing at a fake QA host, so the remote scripts run for real.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.{PathSafety, QaDriver}
  alias SymphonyElixir.QaDriver.{Host, Remote}

  @app "macos/build/Demo.app"
  @env ~w(PATH QA_FAKE_HOME QA_FAKE_BIN QA_FAKE_TRACE QA_FAKE_SSH_MODE QA_FAKE_SSH_OUTPUT QA_FAKE_SSH_STATUS QA_FAKE_AUTH_SOCK)

  setup do
    File.mkdir_p!(System.tmp_dir!())
    {:ok, tmp} = PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "qa-remote-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    qa_home = Path.join(root, "qa-home")
    File.mkdir_p!(bin)
    File.mkdir_p!(qa_home)

    saved = Map.new(@env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf(root)
    end)

    install_fakes!(bin)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    System.put_env("QA_FAKE_HOME", qa_home)
    System.put_env("QA_FAKE_BIN", Path.join(root, "qa-bin"))
    System.put_env("QA_FAKE_TRACE", Path.join(root, "ssh.trace"))
    Enum.each(~w(QA_FAKE_SSH_MODE QA_FAKE_SSH_OUTPUT QA_FAKE_SSH_STATUS QA_FAKE_AUTH_SOCK), &System.delete_env/1)

    %{root: root, qa_home: qa_home, ssh_host: "qa@qa-vm-#{System.unique_integer([:positive])}"}
  end

  defp install_fakes!(bin) do
    qa_bin = Path.join(Path.dirname(bin), "qa-bin")
    File.mkdir_p!(qa_bin)

    write_script!(Path.join(bin, "ssh"), """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$QA_FAKE_TRACE"
    case "${QA_FAKE_SSH_MODE:-run}" in
      fail) echo "ssh: connect to host qa-vm port 22: Connection refused"; exit 255 ;;
      output) printf '%s' "$QA_FAKE_SSH_OUTPUT"; exit "${QA_FAKE_SSH_STATUS:-0}" ;;
      hang) exec sleep 5 ;;
    esac
    for last; do :; done
    eval "set -- $last"
    HOME="$QA_FAKE_HOME" XDG_CONFIG_HOME="$QA_FAKE_HOME/.config" SSH_AUTH_SOCK="${QA_FAKE_AUTH_SOCK:-}" PATH="$QA_FAKE_BIN:$PATH" exec sh -c "$3"
    """)

    # QA host tools: swiftc builds a helper that answers like the real one.
    write_script!(Path.join(qa_bin, "swiftc"), """
    #!/bin/sh
    if [ -n "$QA_FAKE_SWIFTC_FAIL" ]; then echo "error: no such module"; exit 1; fi
    out=$3
    cat > "$out" <<'HELPER'
    #!/bin/sh
    case "$1" in
      permissions) echo '{"accessibility":true,"screen_recording":true}' ;;
      windows) echo '{"windows":[{"id":11,"title":"Settings","layer":0,"onscreen":true,"frame":{"x":0,"y":0,"w":548,"h":420}}]}' ;;
      ax-tree) echo '{"root":{"path":"","role":"AXApplication","children":[{"path":"0","role":"AXWindow","title":"Settings"}]},"nodes":2,"truncated":false}' ;;
    esac
    HELPER
    chmod +x "$out"
    """)

    write_script!(Path.join(qa_bin, "plutil"), "#!/bin/sh\nprintf 'Demo\\n'\n")
    write_script!(Path.join(qa_bin, "screencapture"), "#!/bin/sh\nfor last; do :; done\nprintf 'png-from-qa-host' > \"$last\"\n")
  end

  defp write_script!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp trace, do: File.read!(System.get_env("QA_FAKE_TRACE"))

  defp git_worktree!(root) do
    worktree = Path.join(root, "worktree")
    File.mkdir_p!(worktree)
    {_output, 0} = System.cmd("git", ["init", "--quiet", worktree])

    File.write!(Path.join(worktree, "build.sh"), """
    #!/bin/sh
    mkdir -p macos/build/Demo.app/Contents/MacOS
    printf '<plist/>' > macos/build/Demo.app/Contents/Info.plist
    printf '#!/bin/sh\\necho "qa root $SYMPHONY_BAR_QA_ROOT secret ${LINEAR_API_KEY:-none}"\\nexec sleep 30\\n' > macos/build/Demo.app/Contents/MacOS/Demo
    chmod +x macos/build/Demo.app/Contents/MacOS/Demo
    echo "built on $HOME"
    """)

    File.write!(Path.join(worktree, ".gitignore"), "macos/build/\nqa-evidence/\n")
    identity = ["-c", "user.name=QA", "-c", "user.email=qa@example.com"]
    {_output, 0} = System.cmd("git", ["-C", worktree, "add", "."])
    {_output, 0} = System.cmd("git", ["-C", worktree | identity] ++ ["commit", "--quiet", "-m", "init"])
    worktree
  end

  describe "QaDriver with a worker_host" do
    test "builds, launches, reads and captures the app on the QA host", %{root: root, qa_home: qa_home, ssh_host: ssh_host} do
      worktree = git_worktree!(root)

      # screencapture lives in /usr/sbin on macOS; the fake QA host has it on PATH.
      cmd = fn
        "/usr/sbin/screencapture", args, opts -> Remote.cmd(ssh_host, "screencapture", args, opts)
        executable, args, opts -> Remote.cmd(ssh_host, executable, args, opts)
      end

      # The fake QA host runs as this user; point the isolation checks elsewhere.
      prepare = fn _operator_home, _canary -> Remote.prepare(ssh_host, Path.join(root, "operator"), Path.join(root, "no-canary")) end

      {:ok, driver} =
        QaDriver.start_link(
          worktree: worktree,
          worker_host: ssh_host,
          playbook: %{kind: "macos_app", build: "sh build.sh", app: @app},
          host: %{cmd: cmd, prepare: prepare}
        )

      %{host_dir: run_dir, scratch_dir: scratch_dir} = GenServer.call(driver, :config)
      {:ok, qa_home} = PathSafety.canonicalize(qa_home)
      assert String.starts_with?(run_dir, Path.join(qa_home, ".symphony-qa/runs/run."))
      assert File.stat!(run_dir).mode |> Bitwise.band(0o777) == 0o700
      assert trace() =~ "-o BatchMode=yes -o LogLevel=ERROR -T #{ssh_host} bash -lc"

      assert {:ok, %{"exit_status" => 0, "output" => output, "app" => @app}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert output =~ "built on #{qa_home}"
      assert File.regular?(Path.join([run_dir, "src", @app, "Contents/MacOS/Demo"]))
      refute File.exists?(Path.join(worktree, "macos/build"))

      {result, log} = with_log(fn -> QaDriver.call_tool(driver, "qa_launch_app", %{}) end)
      assert {:ok, %{"pid" => pid, "qa_mode" => true}} = result
      assert log =~ "executable=#{run_dir}/builds/"

      assert {:ok, %{"root" => %{"children" => [%{"title" => "Settings"}]}}} = QaDriver.call_tool(driver, "qa_ax_tree", %{"pid" => pid})
      assert File.read!(Path.join(run_dir, "helper/symphony-qa-driver.swift")) == elem(Host.helper_source(), 1)
      refute File.exists?(Path.join(qa_home, ".symphony-qa/helper"))

      assert {:ok, %{"files" => [%{"path" => "qa-evidence/settings.png", "window_id" => 11}]}} =
               QaDriver.call_tool(driver, "qa_screenshot", %{"pid" => pid, "name" => "settings"})

      assert File.read!(Path.join(worktree, "qa-evidence/settings.png")) == "png-from-qa-host"
      refute File.exists?(Path.join(run_dir, "window-11.png"))

      assert {:ok, %{"quit" => true, "output" => app_output}} = QaDriver.call_tool(driver, "qa_quit_app", %{"pid" => pid})
      assert app_output =~ "qa root #{run_dir}/app-root secret none"

      QaDriver.stop(driver)
      refute File.exists?(run_dir)
      refute File.exists?(scratch_dir)
    end

    test "refuses a QA host that runs as the operator", %{root: root, ssh_host: ssh_host} do
      worktree = Path.join(root, "worktree")
      File.mkdir_p!(worktree)

      # The fake QA host runs as this user, so it can read Symphony's canary.
      prepare = fn _operator_home, canary -> Remote.prepare(ssh_host, Path.join(root, "operator"), canary) end

      {{:ok, driver}, log} =
        with_log(fn ->
          QaDriver.start_link(
            worktree: worktree,
            worker_host: ssh_host,
            playbook: %{build: "make", app: @app},
            host: %{prepare: prepare}
          )
        end)

      assert log =~ "QA driver refused worker_host=#{ssh_host}"
      assert {:error, {:qa_tool, "qa_worker_unsafe", message}} = QaDriver.call_tool(driver, "qa_build", %{})
      assert message =~ "can read Symphony's private state, so it runs as the operator"
      assert message =~ "verdict `blocked`"
      QaDriver.stop(driver)
    end
  end

  describe "prepare/3" do
    test "creates a private run directory on a clean QA host", %{root: root, ssh_host: ssh_host} do
      %{prepare: prepare} = Remote.host(ssh_host)
      assert {:ok, dir} = prepare.(Path.join(root, "operator"), Path.join(root, "no-canary"))
      assert File.dir?(Path.join(dir, "app-root"))
      assert File.dir?(Path.join(dir, "builds"))
      assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700

      Remote.cleanup(ssh_host, dir)
      refute File.exists?(dir)
    end

    test "lists every way the QA host could reach credentials", %{root: root, qa_home: qa_home, ssh_host: ssh_host} do
      operator = Path.join(root, "operator")
      File.mkdir_p!(Path.join(operator, ".ssh"))
      File.mkdir_p!(Path.join(operator, ".config/gh"))
      File.write!(Path.join(operator, ".config/gh/hosts.yml"), "token")
      File.mkdir_p!(Path.join(operator, "Library/Keychains"))
      File.write!(Path.join(operator, "Library/Keychains/login.keychain-db"), "")
      canary = Path.join(root, "canary")
      File.write!(canary, "")

      File.mkdir_p!(Path.join(qa_home, ".ssh"))
      File.write!(Path.join(qa_home, ".ssh/id_ed25519"), "key")
      File.write!(Path.join(qa_home, ".ssh/id_ed25519.pub"), "pub")
      File.mkdir_p!(Path.join(qa_home, ".config/gh"))
      File.write!(Path.join(qa_home, ".config/gh/hosts.yml"), "token")
      File.write!(Path.join(qa_home, ".gitconfig"), "[credential]\n\thelper = store\n")
      System.put_env("QA_FAKE_AUTH_SOCK", "/tmp/agent.sock")

      assert {:error, {:unsafe, problems}} = Remote.prepare(ssh_host, operator, canary)

      assert problems ==
               "can open the operator's ~/.ssh; can read the operator's ~/.config/gh/hosts.yml; " <>
                 "can read the operator's login Keychain; can read Symphony's private state, so it runs as the operator; " <>
                 "has a private key ~/.ssh/id_ed25519; has GitHub CLI credentials in ~/.config/gh; " <>
                 "has a global git credential helper; has a forwarded SSH agent"

      refute File.exists?(Path.join(qa_home, ".symphony-qa"))
    end

    test "skips the operator paths when the QA host shares the operator's home path", %{root: root, qa_home: qa_home, ssh_host: ssh_host} do
      File.mkdir_p!(Path.join(qa_home, ".ssh"))
      File.write!(Path.join(qa_home, ".ssh/authorized_keys"), "pub")
      assert {:ok, _dir} = Remote.prepare(ssh_host, qa_home, Path.join(root, "no-canary"))
    end

    test "reports an unreachable or misbehaving host", %{root: root, ssh_host: ssh_host} do
      System.put_env("QA_FAKE_SSH_MODE", "fail")
      assert {:error, {:unreachable, message}} = Remote.prepare(ssh_host, root, root)
      assert message =~ "status 255"
      assert message =~ "Connection refused"

      System.put_env("QA_FAKE_SSH_MODE", "output")
      System.put_env("QA_FAKE_SSH_OUTPUT", "symphony-qa-dir:/etc\n")
      assert {:error, {:unreachable, _message}} = Remote.prepare(ssh_host, root, root)

      System.put_env("QA_FAKE_SSH_OUTPUT", String.duplicate("x", 600) <> "end")
      System.put_env("QA_FAKE_SSH_STATUS", "1")
      assert {:error, {:unreachable, "ssh exited with status 1: …" <> rest}} = Remote.prepare(ssh_host, root, root)
      assert byte_size(rest) == 500
      assert String.ends_with?(rest, "end")

      System.put_env("PATH", Path.join(root, "empty"))
      assert {:error, {:unreachable, ":ssh_not_found"}} = Remote.prepare(ssh_host, root, root)
    end
  end

  describe "host functions" do
    test "cmd runs in a directory with quoted arguments", %{root: root, ssh_host: ssh_host} do
      dir = Path.join(root, "work dir")
      File.mkdir_p!(dir)
      %{cmd: cmd} = Remote.host(ssh_host)

      assert {:ok, {output, 0}} = cmd.("/bin/sh", ["-c", ~s(pwd; printf '%s|' "$@"), "sh", "it's", "a b", "$HOME"], cd: dir, timeout_ms: 5_000)
      assert output =~ "work dir\nit's|a b|$HOME|"

      assert {:ok, {_output, 125}} = cmd.("/bin/true", [], cd: Path.join(root, "missing"), timeout_ms: 5_000)
      assert {:ok, {"ok\n", 0}} = cmd.("/bin/sh", ["-c", "echo ok"], [])
    end

    test "ship unpacks a tar into a fresh directory", %{root: root, ssh_host: ssh_host} do
      source = Path.join(root, "source")
      File.mkdir_p!(Path.join(source, "lib"))
      File.write!(Path.join(source, "lib/app.swift"), "print(1)")
      tar = Path.join(root, "src.tar")
      {_output, 0} = System.cmd("tar", ["-c", "-f", tar, "-C", source, "lib"])
      dest = Path.join(root, "remote-src")
      File.mkdir_p!(dest)
      File.write!(Path.join(dest, "stale"), "old")

      assert :ok = Remote.ship(ssh_host, tar, dest)
      assert File.read!(Path.join(dest, "lib/app.swift")) == "print(1)"
      refute File.exists?(Path.join(dest, "stale"))

      File.write!(tar, "not a tar")
      assert {:error, "exit " <> _rest} = Remote.ship(ssh_host, tar, dest)

      System.put_env("PATH", Path.join(root, "empty"))
      assert {:error, ":ssh_not_found"} = Remote.ship(ssh_host, tar, dest)
    end

    test "helper compiles into each run directory and reports failures", %{root: root, ssh_host: ssh_host} do
      %{prepare: prepare, helper: helper} = Remote.host(ssh_host)
      {:ok, dir} = prepare.(Path.join(root, "operator"), Path.join(root, "no-canary"))
      {:ok, other_dir} = prepare.(Path.join(root, "operator"), Path.join(root, "no-canary"))

      assert {:ok, path} = helper.(dir)
      assert path == Path.join(dir, "helper/symphony-qa-driver")
      assert File.regular?(path)
      assert {:ok, other_path} = Remote.helper(ssh_host, other_dir)
      assert other_path == Path.join(other_dir, "helper/symphony-qa-driver")

      # A build that replaced one pass's helper does not reach another pass.
      File.write!(path, "#!/bin/sh\necho forged\n")
      assert {:ok, ^path} = Remote.helper(ssh_host, dir)
      refute File.read!(other_path) =~ "forged"

      assert {:error, {:not_a_run_dir, "/tmp/elsewhere"}} = Remote.helper(ssh_host, "/tmp/elsewhere")

      System.put_env("QA_FAKE_SWIFTC_FAIL", "1")
      on_exit(fn -> System.delete_env("QA_FAKE_SWIFTC_FAIL") end)
      File.rm!(other_path)
      assert {:error, {:swiftc_failed, 1, output}} = Remote.helper(ssh_host, other_dir)
      assert output =~ "no such module"

      System.put_env("QA_FAKE_SSH_MODE", "output")
      System.put_env("QA_FAKE_SSH_OUTPUT", "nothing useful\n")
      assert {:error, {:swiftc_failed, 0, "nothing useful\n"}} = Remote.helper(ssh_host, dir)

      System.put_env("PATH", "/nonexistent")
      assert {:error, :ssh_not_found} = Remote.helper(ssh_host, dir)
    end

    test "read copies a regular file back and removes it", %{root: root, ssh_host: ssh_host} do
      file = Path.join(root, "shot.png")
      bytes = :crypto.strong_rand_bytes(5_000)
      File.write!(file, bytes)

      assert {:ok, ^bytes} = Remote.read(ssh_host, file)
      refute File.exists?(file)
      assert {:error, :unreadable} = Remote.read(ssh_host, file)

      File.ln_s!(Path.join(root, "qa-home"), file)
      assert {:error, :unreadable} = Remote.read(ssh_host, file)
      refute File.exists?(file)

      System.put_env("PATH", Path.join(root, "empty"))
      assert {:error, :ssh_not_found} = Remote.read(ssh_host, file)
    end

    test "launch returns the app's PID and its output; kill stops it", %{root: root, ssh_host: ssh_host} do
      app = Path.join(root, "app.sh")
      write_script!(app, "#!/bin/sh\necho \"root=$SYMPHONY_BAR_QA_ROOT unset=${DROPPED:-none}\"\nexec sleep 30\n")

      env = [{"SYMPHONY_BAR_QA_ROOT", root}, {~c"DROPPED", false}]
      assert {:ok, port, pid} = Remote.launch(ssh_host, app, cd: root, env: env)
      assert_receive {^port, {:data, data}}, 5_000
      assert data =~ "root=#{root} unset=none"

      assert :ok = Remote.kill(ssh_host, pid)
      assert_receive {^port, {:exit_status, _status}}, 5_000
      assert :ok = Remote.kill(ssh_host, pid)
    end

    test "launch reports a host that exits or never answers", %{root: root, ssh_host: ssh_host} do
      assert {:error, message} = Remote.launch(ssh_host, "/bin/true", cd: Path.join(root, "missing"))
      assert message =~ "status 125"

      System.put_env("QA_FAKE_SSH_MODE", "output")
      System.put_env("QA_FAKE_SSH_OUTPUT", "banner\nsymphony-qa-pid:4242\n")
      assert {:ok, port, 4242} = Remote.launch(ssh_host, "/bin/true", [])
      assert_receive {^port, {:exit_status, 0}}, 5_000

      System.put_env("QA_FAKE_SSH_MODE", "hang")
      assert {:error, :timeout} = Remote.launch(ssh_host, "/bin/true", timeout_ms: 200)

      System.put_env("PATH", Path.join(root, "empty"))
      assert {:error, :ssh_not_found} = Remote.launch(ssh_host, "/bin/true", [])
    end

    test "cleanup removes only run directories", %{root: root, ssh_host: ssh_host} do
      assert :ok = Remote.cleanup(ssh_host, root)
      assert File.dir?(root)
    end
  end
end
