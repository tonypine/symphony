defmodule SymphonyElixir.Verification.DevServerSandboxTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentCaches, AgentSandboxConfig}
  alias SymphonyElixir.Verification.{DevServerSandbox, EgressProxy}

  setup do
    root = Path.join(System.tmp_dir!(), "dev-server-sandbox-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    tmp_dir = Path.join(root, "tmp")
    home = Path.join(root, "home")
    Enum.each([workspace, tmp_dir, home], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, workspace: workspace, tmp_dir: tmp_dir, home: home}
  end

  describe "command/4" do
    test "runs the start command with sh -lc under sandbox-exec and the dev server profile", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      executable = Path.join(root, "sandbox-exec")
      File.write!(executable, "")
      File.mkdir_p!(Path.join(workspace, ".ai/skills"))
      File.ln_s!("../../priv/skills/pull", Path.join(workspace, ".ai/skills/pull"))

      assert {:ok, [^executable, "-p", profile, "/bin/sh", "-lc", "mix phx.server"]} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir,
                 os_type: {:unix, :darwin},
                 executable: executable,
                 getconf: "false"
               )

      assert profile =~ ~s{(subpath "#{real(workspace)}")}
      assert profile =~ ~s{(subpath "#{real(tmp_dir)}")}

      for cache_dir <- AgentCaches.write_paths() do
        assert profile =~ ~s{(subpath "#{cache_dir}")}
      end

      for path <- [".git", "WORKFLOW.md", ".ai/skills", "priv/skills/pull"] do
        assert profile =~ ~s{(subpath "#{Path.join(real(workspace), path)}")}
      end
    end

    test "fails off macOS, where there is no Seatbelt", %{workspace: workspace, tmp_dir: tmp_dir} do
      assert {:error, {:dev_server_sandbox_unavailable, {:unix, :linux}}} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir, os_type: {:unix, :linux})
    end

    test "fails when sandbox-exec is missing", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      executable = Path.join(root, "missing-sandbox-exec")

      assert {:error, {:dev_server_sandbox_unavailable, {:not_found, ^executable}}} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir, os_type: {:unix, :darwin}, executable: executable)
    end
  end

  describe "profile/4" do
    test "denies reads of every path the agent can't read, under the given home", %{workspace: workspace, home: home} do
      profile = DevServerSandbox.profile(workspace, [workspace], [], home)
      deny_read = profile |> String.split(~r/\n(?=\()/) |> Enum.find(&String.starts_with?(&1, "(deny file-read*"))

      for path <- AgentSandboxConfig.deny_read_paths() ++ AgentSandboxConfig.codex_runtime_deny_read_paths() do
        expected = String.replace_prefix(path, "~", real(home))
        assert deny_read =~ ~s{(subpath "#{expected}")}
      end

      assert deny_read =~ ~s{(subpath "#{real(home)}/.ssh")}
      assert deny_read =~ ~s{(subpath "#{real(home)}/.codex/auth.json")}
      assert deny_read =~ ~s{(prefix "#{real(System.tmp_dir!())}/symphony-codex-home-")}
    end

    test "allows writes only to the given paths and the /dev sinks, then takes the protected paths back", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir, workspace], [".git"], home)

      assert [
               "(version 1)",
               "(allow default)",
               "(deny file-read*" <> _deny_read,
               "(deny file-write*)",
               "(allow file-write*" <> allow_write,
               "(deny file-write*\n  " <> deny_write,
               "(deny network*)",
               ~s{(allow network-bind (local ip "localhost:*"))},
               ~s{(allow network-inbound (local ip "localhost:*"))},
               ~s{(allow network-outbound (remote ip "localhost:*"))},
               ~s{(allow network-outbound\n  (literal "/private/var/run/mDNSResponder"))},
               "(deny mach-lookup)",
               "(allow mach-lookup\n  " <> allow_mach_lookup,
               "(deny appleevent-send)",
               "(deny lsopen)",
               "(deny job-creation)",
               "(deny mach-lookup\n  " <> deny_mach_lookup,
               "(deny process-exec\n  " <> deny_exec
             ] = String.split(profile, ~r/\n(?=\()/)

      assert allow_write ==
               """

                 (subpath "#{real(workspace)}")
                 (subpath "#{real(tmp_dir)}")
                 (subpath "/dev/fd")
                 (literal "/dev/null")
                 (literal "/dev/zero")
                 (literal "/dev/tty")
                 (literal "/dev/stdout")
                 (literal "/dev/stderr")
                 (literal "/dev/dtracehelper")
                 (literal "/dev/autofs_nowait"))\
               """

      assert deny_write == ~s{(subpath "#{real(workspace)}/.git"))}

      assert allow_mach_lookup ==
               """
               (global-name "com.apple.system.opendirectoryd.libinfo")
                 (global-name "com.apple.system.opendirectoryd.membership")
                 (global-name "com.apple.system.notification_center")
                 (global-name "com.apple.system.logger")
                 (global-name "com.apple.logd")
                 (global-name "com.apple.bsd.dirhelper")
                 (global-name "com.apple.SecurityServer")
                 (global-name "com.apple.securityd.xpc")
                 (global-name "com.apple.trustd")
                 (global-name "com.apple.trustd.agent"))\
               """

      refute allow_mach_lookup =~ "windowserver"
      refute allow_mach_lookup =~ "pasteboard"

      assert deny_mach_lookup ==
               """
               (global-name "com.apple.coreservices.launchservicesd")
                 (global-name "com.apple.coreservices.appleevents")
                 (global-name-prefix "com.apple.lsd."))\
               """

      assert deny_exec == ~s{(literal "/usr/bin/open")\n  (literal "/usr/bin/osascript")\n  (literal "/bin/launchctl"))}
    end

    test "gives paths with their links resolved and quotes them", %{root: root, home: home} do
      workspace = Path.join(root, ~s(odd "quoted" \\ dir))
      File.mkdir_p!(workspace)
      link = Path.join(root, "workspace-link")
      File.ln_s!(workspace, link)

      profile = DevServerSandbox.profile(link, [link], [], home)

      assert profile =~ ~s{(subpath "#{real(root)}/odd \\"quoted\\" \\\\ dir")}
      refute profile =~ "workspace-link"
    end

    test "keeps a path it can't resolve as given", %{root: root, home: home} do
      file = Path.join(root, "file")
      File.write!(file, "")
      workspace = Path.join(file, "workspace")

      assert DevServerSandbox.profile(workspace, [workspace], [], home) =~ ~s{(subpath "#{workspace}")}
    end
  end

  describe "under Seatbelt" do
    @describetag :seatbelt

    test "a command can't read a credential path but reads and writes the workspace", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      File.mkdir_p!(Path.join(home, ".ssh"))
      File.write!(Path.join(home, ".ssh/id_ed25519"), "secret")
      File.write!(Path.join(home, "notes.txt"), "notes")
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [".git"], home)

      assert {output, status} = seatbelt(profile, workspace, "cat #{home}/.ssh/id_ed25519")
      assert status != 0
      assert output =~ "Operation not permitted"
      refute output =~ "secret"

      assert {"notes", 0} = seatbelt(profile, workspace, "cat #{home}/notes.txt")
      assert {_output, 0} = seatbelt(profile, workspace, "echo built > build.txt && echo tmp > #{tmp_dir}/tmp.txt")
      assert File.read!(Path.join(workspace, "build.txt")) == "built\n"

      assert {_output, status} = seatbelt(profile, workspace, "echo hook > #{home}/planted.txt")
      assert status != 0
      refute File.exists?(Path.join(home, "planted.txt"))

      File.mkdir_p!(Path.join(workspace, ".git"))
      assert {_output, status} = seatbelt(profile, workspace, "echo hook > .git/config")
      assert status != 0
      refute File.exists?(Path.join(workspace, ".git/config"))
    end

    test "a command reaches the network only on loopback, and the dependency hosts only through the proxy", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [], home)
      proxy = start_supervised!({EgressProxy, allowed_domains: ["localhost"]})
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, local_port} = :inet.port(listen)

      # 192.0.2.1 is TEST-NET-1: without the sandbox the connect would time out, not fail at once.
      assert {output, status} = seatbelt(profile, workspace, python_connect("192.0.2.1", 443))
      assert status != 0
      assert output =~ "Operation not permitted"

      assert {_output, 0} = seatbelt(profile, workspace, python_connect("127.0.0.1", local_port))

      connect_through_proxy = fn host ->
        python = """
        import socket
        s = socket.create_connection(("127.0.0.1", #{EgressProxy.port(proxy)}), timeout=5)
        s.sendall(b"CONNECT #{host}:#{local_port} HTTP/1.1\\r\\n\\r\\n")
        print(s.recv(100).decode().splitlines()[0])
        """

        seatbelt(profile, workspace, "python3 -c '#{python}'")
      end

      assert {"HTTP/1.1 200 Connection Established\n", 0} = connect_through_proxy.("localhost")
      assert {"HTTP/1.1 403 Forbidden: example.com is not on" <> _rest, 0} = connect_through_proxy.("example.com")

      :gen_tcp.close(listen)
    end

    test "a command can't have launchd start a process outside the sandbox", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [], home)
      marker = Path.join(home, "escaped")
      File.write!(Path.join(workspace, "x.command"), "#!/bin/sh\ntouch #{marker}\n")
      File.chmod!(Path.join(workspace, "x.command"), 0o755)
      label = "symphony.dev-server-sandbox-test.#{System.unique_integer([:positive])}"
      on_exit(fn -> System.cmd("/bin/launchctl", ["remove", label], stderr_to_stdout: true) end)

      open = ~s{open -g -a Terminal ./x.command}
      apple_event = ~s{osascript -e 'tell application "Terminal" to do script "touch #{marker}"'}
      launchd_job = ~s{launchctl submit -l #{label} -- /usr/bin/touch #{marker}}

      # The tools themselves can't run.
      for script <- [open, apple_event, launchd_job] do
        assert {output, status} = seatbelt(profile, workspace, script)
        assert status != 0
        assert output =~ "Operation not permitted"
      end

      # Copies of them can, but LaunchServices, Apple Events and launchd job creation are denied.
      for tool <- ~w(/usr/bin/open /usr/bin/osascript /bin/launchctl) do
        File.cp!(tool, Path.join(tmp_dir, Path.basename(tool)))
      end

      for script <- [open, apple_event, launchd_job] do
        assert {_output, status} = seatbelt(profile, workspace, "PATH=#{tmp_dir}:$PATH; #{script}")
        assert status != 0
      end

      Process.sleep(1_000)
      refute File.exists?(marker)
    end

    test "a command gets no window server and no pasteboard, but still checks TLS certificates", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [], home)
      clipboard = "symphony-clipboard-#{System.unique_integer([:positive])}"
      {previous_clipboard, 0} = System.cmd("/usr/bin/pbpaste", [])
      on_exit(fn -> System.cmd("/bin/sh", ["-c", "printf %s \"$1\" | /usr/bin/pbcopy", "sh", previous_clipboard]) end)
      {_output, 0} = System.cmd("/bin/sh", ["-c", "printf %s \"$1\" | /usr/bin/pbcopy", "sh", clipboard])

      assert {output, _status} = seatbelt(profile, workspace, "/usr/bin/pbpaste")
      refute output =~ clipboard

      lookup = fn service ->
        python = """
        import ctypes
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        port = ctypes.c_uint(0)
        bootstrap = ctypes.c_uint.in_dll(libc, "bootstrap_port").value
        print(libc.bootstrap_look_up(bootstrap, b"#{service}", ctypes.byref(port)))
        """

        seatbelt(profile, workspace, "python3 -c '#{python}'")
      end

      # 1100 is BOOTSTRAP_NOT_PRIVILEGED: the sandbox refused the lookup.
      assert {"1100\n", 0} = lookup.("com.apple.windowserver.active")
      assert {"1100\n", 0} = lookup.("com.apple.pasteboard.1")
      assert {"0\n", 0} = lookup.("com.apple.trustd.agent")

      proxy = start_supervised!({EgressProxy, allowed_domains: ["repo.hex.pm"]})
      curl = "curl -sS -o /dev/null -w %{http_code} --proxy http://127.0.0.1:#{EgressProxy.port(proxy)} https://repo.hex.pm/"

      assert {code, 0} = seatbelt(profile, workspace, curl)
      assert code =~ ~r/^[234]\d\d$/
    end

    test "a command can't listen on a non-loopback address", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [], home)
      python = "import socket; s = socket.socket(); s.bind((\"0.0.0.0\", 0)); s.listen()"

      assert {output, status} = seatbelt(profile, workspace, "python3 -c '#{python}'")
      assert status != 0
      assert output =~ "Operation not permitted"
    end
  end

  defp python_connect(host, port) do
    "python3 -c 'import socket; socket.create_connection((\"#{host}\", #{port}), timeout=5)'"
  end

  defp seatbelt(profile, workspace, script) do
    System.cmd("/usr/bin/sandbox-exec", ["-p", profile, "/bin/sh", "-c", script], cd: workspace, stderr_to_stdout: true)
  end

  defp real(path) do
    {:ok, real_path} = SymphonyElixir.PathSafety.canonicalize(path)
    real_path
  end
end
