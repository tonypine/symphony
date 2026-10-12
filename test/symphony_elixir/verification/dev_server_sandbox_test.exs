defmodule SymphonyElixir.Verification.DevServerSandboxTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentCaches, AgentSandboxConfig}
  alias SymphonyElixir.Codex.McpConfig
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
      File.mkdir_p!(Path.join(workspace, ".agents/skills"))
      File.ln_s!("../../priv/skills/pull", Path.join(workspace, ".agents/skills/pull"))

      assert {:ok, [^executable, "-p", profile, "/bin/sh", "-lc", "mix phx.server"], []} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir,
                 os_type: {:unix, :darwin},
                 executable: executable,
                 getconf: "false",
                 check_confinement: false
               )

      assert profile =~ ~s{(subpath "#{real(workspace)}")}
      assert profile =~ ~s{(subpath "#{real(tmp_dir)}")}

      for cache_dir <- AgentCaches.write_paths() do
        assert profile =~ ~s{(subpath "#{cache_dir}")}
      end

      for path <- [".git", "WORKFLOW.md", ".agents/skills", "priv/skills/pull"] do
        assert profile =~ ~s{(subpath "#{Path.join(real(workspace), path)}")}
      end
    end

    test "lets the server write Foundation's item replacement folder", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      executable = Path.join(root, "sandbox-exec")
      File.write!(executable, "")
      user_temp_dir = Path.join(root, "user-temp")
      getconf = Path.join(root, "getconf")
      File.write!(getconf, "#!/bin/sh\necho #{user_temp_dir}/\n")
      File.chmod!(getconf, 0o755)

      assert {:ok, [^executable, "-p", profile | _argv], []} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir,
                 os_type: {:unix, :darwin},
                 executable: executable,
                 getconf: getconf,
                 check_confinement: false
               )

      assert profile =~ ~s{(subpath "#{Path.join(real(root), "user-temp/TemporaryItems")}")}
      refute profile =~ ~s{(subpath "#{real(user_temp_dir)}")}
    end

    test "fails off macOS and Linux, where it has no sandbox", %{workspace: workspace, tmp_dir: tmp_dir} do
      assert {:error, {:dev_server_sandbox_unavailable, {:win32, :nt}}} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir, os_type: {:win32, :nt})
    end

    test "checks once that the profile refuses every TCP listener and allows the unix socket before it hands back the command", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      calls = Path.join(root, "probe-calls")
      executable = fake_sandbox_exec(root, "printf '%s\\0' \"$@\" >> '#{calls}'\necho 'perl: warning: Setting locale failed.' >&2\necho confined")

      assert {:ok, [^executable, "-p", profile, "/bin/sh", "-lc", "mix phx.server"], []} =
               command(workspace, tmp_dir, executable)

      assert {:ok, _argv, []} = command(workspace, tmp_dir, executable)

      socket = Path.join(real(tmp_dir), "probe.sock")
      assert ["-p", ^profile, "/usr/bin/perl", "-MSocket", "-MErrno", "-e", probe, ^socket, ""] = calls |> File.read!() |> String.split("\0")
      assert probe =~ "INADDR_ANY, INADDR_LOOPBACK"
      assert probe =~ "PF_UNIX"
    end

    test "doesn't hand back the command when the profile lets a command bind a TCP port, and keeps that verdict", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      calls = Path.join(root, "probe-calls")
      executable = fake_sandbox_exec(root, "echo call >> '#{calls}'\necho 'tcp bound: 0.0.0.0' >&2\nexit 29")

      for _attempt <- 1..2 do
        assert {:error, {:dev_server_sandbox_unconfined, :tcp_bind_allowed}} = command(workspace, tmp_dir, executable)
      end

      assert File.read!(calls) == "call\n"
    end

    test "doesn't hand back the command when the profile refuses the unix socket", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      executable = fake_sandbox_exec(root, "echo 'unix bind: Operation not permitted' >&2\nexit 1")

      assert {:error, {:dev_server_sandbox_unconfined, {:probe_failed, 1, "unix bind: Operation not permitted"}}} =
               command(workspace, tmp_dir, executable)
    end

    test "doesn't take a probe that exits 0 without saying it is confined", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      executable = fake_sandbox_exec(root, "echo bound")

      assert {:error, {:dev_server_sandbox_unconfined, {:probe_failed, 0, "bound"}}} =
               command(workspace, tmp_dir, executable)
    end

    test "doesn't hand back the command when the bind check can't run, and tries it again next time", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      calls = Path.join(root, "probe-calls")
      executable = fake_sandbox_exec(root, "echo call >> '#{calls}'\necho 'perl: not found' >&2\nexit 127")

      for _attempt <- 1..2 do
        assert {:error, {:dev_server_sandbox_unconfined, {:probe_failed, 127, "perl: not found"}}} =
                 command(workspace, tmp_dir, executable)
      end

      assert File.read!(calls) == "call\ncall\n"
    end

    test "doesn't take sandbox-exec failing to apply the profile for a refused bind", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      executable = fake_sandbox_exec(root, "echo 'sandbox-exec: sandbox_apply: Operation not permitted' >&2\nexit 71")

      assert {:error, {:dev_server_sandbox_unconfined, {:probe_failed, 71, "sandbox-exec: sandbox_apply: Operation not permitted"}}} =
               command(workspace, tmp_dir, executable)
    end

    test "fails when sandbox-exec is missing", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      executable = Path.join(root, "missing-sandbox-exec")

      assert {:error, {:dev_server_sandbox_unavailable, {:not_found, ^executable}}} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir, os_type: {:unix, :darwin}, executable: executable)
    end
  end

  describe "build_command/4" do
    test "runs the build command with sh -lc under sandbox-exec and the build profile, with no listener probe", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      # A probe would run this and fail: the build profile allows loopback listeners by design.
      executable = Path.join(root, "sandbox-exec")
      File.write!(executable, "#!/bin/sh\nexit 1\n")
      File.chmod!(executable, 0o755)

      assert {:ok, [^executable, "-p", profile, "/bin/sh", "-lc", "mix build"], []} =
               DevServerSandbox.build_command("mix build", workspace, tmp_dir,
                 os_type: {:unix, :darwin},
                 executable: executable,
                 getconf: "false"
               )

      assert profile =~ ~s{(allow network-bind (local ip "localhost:*"))}
      assert profile =~ ~s{(allow network-inbound (local ip "localhost:*"))}
      assert profile =~ ~s{(subpath "#{Path.join(real(workspace), ".git")}")}
      assert profile =~ "(deny process-exec"
    end

    test "fails off macOS and Linux, and when sandbox-exec is missing", %{root: root, workspace: workspace, tmp_dir: tmp_dir} do
      assert {:error, {:dev_server_sandbox_unavailable, {:win32, :nt}}} =
               DevServerSandbox.build_command("mix build", workspace, tmp_dir, os_type: {:win32, :nt})

      missing = Path.join(root, "missing-sandbox-exec")

      assert {:error, {:dev_server_sandbox_unavailable, {:not_found, ^missing}}} =
               DevServerSandbox.build_command("mix build", workspace, tmp_dir, os_type: {:unix, :darwin}, executable: missing)
    end
  end

  describe "listen_socket/2" do
    test "is a socket in the temp folder on macOS, and none on Linux", %{tmp_dir: tmp_dir} do
      assert {:ok, socket} = DevServerSandbox.listen_socket(tmp_dir, os_type: {:unix, :darwin})
      assert socket == Path.join(real(tmp_dir), "serve.sock")

      assert {:ok, nil} = DevServerSandbox.listen_socket(tmp_dir, os_type: {:unix, :linux})
    end

    test "fails on macOS when the socket path is too long for a unix socket", %{root: root} do
      tmp_dir = Path.join(root, String.duplicate("t", 100))
      File.mkdir_p!(tmp_dir)
      socket = Path.join(real(tmp_dir), "serve.sock")

      assert {:error, {:dev_server_sandbox_unavailable, {:unusable_socket_path, ^socket}}} =
               DevServerSandbox.listen_socket(tmp_dir, os_type: {:unix, :darwin})
    end
  end

  describe "command/4 on Linux" do
    setup %{root: root} do
      bwrap = Path.join(root, "bwrap")
      socat = Path.join(root, "socat")
      record = Path.join(root, "bwrap-argv")

      # Passes the probe (`... /bin/sh -c :`), records any other argv and fails with 7.
      File.write!(bwrap, """
      #!/bin/sh
      for arg; do last=$arg; done
      [ "$last" = ":" ] && exit 0
      printf '%s\\0' "$@" > '#{record}'
      exit 7
      """)

      File.write!(socat, "#!/bin/sh\nexit 0\n")
      Enum.each([bwrap, socat], &File.chmod!(&1, 0o755))
      opts = [os_type: {:unix, :linux}, bwrap: bwrap, socat: socat, port: 4000, proxy_port: 5555]

      {:ok, bwrap: bwrap, socat: socat, record: record, opts: opts}
    end

    test "runs the start command under bwrap, bridged to the host's loopback by socat", ctx do
      %{workspace: workspace, tmp_dir: tmp_dir, bwrap: bwrap, socat: socat, record: record, opts: opts} = ctx
      File.mkdir_p!(Path.join(workspace, ".git"))

      assert {:ok, ["/bin/sh", "-c", script], placeholders} = DevServerSandbox.command("mix phx.server --name 'web'", workspace, tmp_dir, opts)

      protected = AgentSandboxConfig.workspace_protected_paths() ++ [".git"]
      write_paths = [workspace, tmp_dir] ++ AgentCaches.write_paths()
      assert {args, ^placeholders} = DevServerSandbox.bwrap_args(workspace, write_paths, protected)
      assert Enum.map(placeholders, &Path.relative_to(&1, real(workspace))) == [".claude", ".agents", ".codex", "config"]

      proxy_socket = Path.join(real(tmp_dir), "proxy.sock")
      serve_socket = Path.join(real(tmp_dir), "serve.sock")
      assert script =~ "'#{socat}' 'UNIX-LISTEN:#{proxy_socket},fork,unlink-early' 'TCP:127.0.0.1:5555' &\n"
      assert script =~ "'#{socat}' 'TCP-LISTEN:4000,bind=127.0.0.1,reuseaddr,fork' 'UNIX-CONNECT:#{serve_socket}' &\n"
      assert script =~ "\ntrap : HUP INT TERM\n'#{bwrap}' '--die-with-parent' '--unshare-all' "

      assert script =~ "\nkill $proxy_bridge $serve_bridge 2>/dev/null\nwait\nexit $status"

      assert {_output, 7} = System.cmd("/bin/sh", ["-c", script], cd: workspace, stderr_to_stdout: true)

      assert {^args, ["/bin/sh", "-c", sandbox_script, ""]} = record |> File.read!() |> String.split("\0") |> Enum.split(length(args))
      assert ["--bind", real(tmp_dir), real(tmp_dir)] in chunk_options(args)
      assert ["--ro-bind", Path.join(real(workspace), ".git"), Path.join(real(workspace), ".git")] in chunk_options(args)

      assert sandbox_script ==
               Enum.join(
                 [
                   "'#{socat}' 'TCP-LISTEN:5555,bind=127.0.0.1,reuseaddr,fork' 'UNIX-CONNECT:#{proxy_socket}' &",
                   "'#{socat}' 'UNIX-LISTEN:#{serve_socket},fork,unlink-early' 'TCP:127.0.0.1:4000' &",
                   "exec '/bin/sh' '-lc' 'mix phx.server --name '\\''web'\\'''"
                 ],
                 "\n"
               )
    end

    test "runs the build command under bwrap, bridged to the host's loopback for the egress proxy only", ctx do
      %{workspace: workspace, tmp_dir: tmp_dir, socat: socat, record: record, opts: opts} = ctx
      opts = Keyword.delete(opts, :port)

      assert {:ok, ["/bin/sh", "-c", script], _placeholders} = DevServerSandbox.build_command("mix build", workspace, tmp_dir, opts)

      proxy_socket = Path.join(real(tmp_dir), "proxy.sock")
      assert script =~ "'#{socat}' 'UNIX-LISTEN:#{proxy_socket},fork,unlink-early' 'TCP:127.0.0.1:5555' &\n"
      refute script =~ "serve.sock"
      refute script =~ "serve_bridge"
      assert script =~ "\nkill $proxy_bridge 2>/dev/null\nwait\nexit $status"

      assert {_output, 7} = System.cmd("/bin/sh", ["-c", script], cd: workspace, stderr_to_stdout: true)
      assert ["", sandbox_script, "-c", "/bin/sh" | _args] = record |> File.read!() |> String.split("\0") |> Enum.reverse()

      assert sandbox_script ==
               Enum.join(
                 [
                   "'#{socat}' 'TCP-LISTEN:5555,bind=127.0.0.1,reuseaddr,fork' 'UNIX-CONNECT:#{proxy_socket}' &",
                   "exec '/bin/sh' '-lc' 'mix build'"
                 ],
                 "\n"
               )
    end

    test "fails without bwrap or socat", %{root: root, workspace: workspace, tmp_dir: tmp_dir, opts: opts} do
      missing = Path.join(root, "missing")

      assert {:error, {:dev_server_sandbox_unavailable, {:not_found, ^missing}}} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir, Keyword.put(opts, :bwrap, missing))

      assert {:error, {:dev_server_sandbox_unavailable, {:not_found, "bwrap"}}} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir, Keyword.put(opts, :bwrap, nil))

      assert {:error, {:dev_server_sandbox_unavailable, {:not_found, ^missing}}} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir, Keyword.put(opts, :socat, missing))
    end

    test "fails where bwrap can't make its namespaces", %{root: root, workspace: workspace, tmp_dir: tmp_dir, opts: opts} do
      bwrap = Path.join(root, "bwrap-without-userns")
      File.write!(bwrap, "#!/bin/sh\necho 'bwrap: No permissions to create new namespace' >&2\nexit 1\n")
      File.chmod!(bwrap, 0o755)

      assert {:error, {:dev_server_sandbox_unavailable, {:bwrap_failed, "bwrap: No permissions to create new namespace"}}} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir, Keyword.put(opts, :bwrap, bwrap))
    end

    test "fails when socat can't take the temp folder's sockets", %{root: root, workspace: workspace, opts: opts} do
      tmp_dir = Path.join(root, "tmp,odd")
      File.mkdir_p!(tmp_dir)
      socket = Path.join(real(tmp_dir), "proxy.sock")

      assert {:error, {:dev_server_sandbox_unavailable, {:unusable_socket_path, ^socket}}} =
               DevServerSandbox.command("mix phx.server", workspace, tmp_dir, opts)
    end
  end

  describe "bwrap_args/4" do
    test "is read-only but the write paths, with loopback only and the read-deny list covered", %{root: root, workspace: workspace, tmp_dir: tmp_dir, home: home} do
      File.mkdir_p!(Path.join(home, ".ssh"))
      File.write!(Path.join(home, ".netrc"), "machine example.com password secret")
      cache = Path.join(root, "cache")
      File.mkdir_p!(cache)

      assert {args, []} = DevServerSandbox.bwrap_args(workspace, [workspace, tmp_dir, workspace, cache], [], home)
      codex_homes = real(Path.dirname(McpConfig.runtime_home_prefix()))
      [bound_workspace, bound_tmp_dir, bound_cache] = Enum.map([workspace, tmp_dir, cache], &real/1)

      # The `CODEX_HOME`s' folder is `/tmp` itself where `TMPDIR` is unset (Linux CI).
      hidden = Enum.uniq(["/tmp", "/run", codex_homes])

      expected =
        ~w(--die-with-parent --unshare-all --ro-bind / / --dev /dev --proc /proc) ++
          Enum.flat_map(hidden, &["--tmpfs", &1]) ++
          Enum.flat_map([bound_workspace, bound_tmp_dir, bound_cache], &["--bind", &1, &1])

      assert {^expected, rest} = Enum.split(args, length(expected))

      assert ["--chdir", ^bound_workspace] = Enum.take(rest, -2)

      covered = rest |> Enum.drop(-2) |> chunk_options()
      assert ["--tmpfs", Path.join(real(home), ".ssh")] in covered
      assert ["--ro-bind", "/dev/null", Path.join(real(home), ".netrc")] in covered
      refute Enum.any?(covered, &(Path.join(real(home), ".aws") in &1))
    end

    test "keeps the protected paths read-only, and the missing ones from being made", %{root: root, workspace: workspace, tmp_dir: tmp_dir, home: home} do
      for dir <- [".git", ".claude", "deep"], do: File.mkdir_p!(Path.join(workspace, dir))
      File.write!(Path.join(workspace, "mise.toml"), "")
      File.write!(Path.join(workspace, "config"), "")
      File.ln_s!(Path.join(root, "nowhere"), Path.join(workspace, ".codex"))

      protected = [
        ".git",
        "mise.toml",
        ".claude/settings.local.json",
        "deep/a/b",
        ".agents/skills",
        "top/a/b",
        "WORKFLOW.md",
        "config/settings_ui_exempt.yml",
        ".codex/skills"
      ]

      assert {args, placeholders} = DevServerSandbox.bwrap_args(workspace, [workspace, tmp_dir], protected, home)
      ws = real(workspace)
      assert placeholders == [Path.join(ws, ".agents"), Path.join(ws, "top")]

      options = chunk_options(args)
      read_only = for ["--ro-bind", path, path] <- options, String.starts_with?(path, ws <> "/"), do: Path.relative_to(path, ws)
      assert read_only == [".git", "mise.toml", ".claude", "deep"]

      for placeholder <- placeholders do
        assert ["--tmpfs", placeholder] in options
        assert ["--remount-ro", placeholder] in options
      end
    end
  end

  describe "profile/4" do
    test "denies reads of every path the agent can't read, under the given home", %{workspace: workspace, home: home} do
      profile = DevServerSandbox.profile(workspace, [workspace], [], home: home, socket_dir: workspace)
      deny_read = profile |> String.split(~r/\n(?=\()/) |> Enum.find(&String.starts_with?(&1, "(deny file-read*"))

      for path <- AgentSandboxConfig.deny_read_paths() ++ AgentSandboxConfig.codex_runtime_deny_read_paths() do
        expected = String.replace_prefix(path, "~", real(home))
        assert deny_read =~ ~s{(subpath "#{expected}")}
      end

      assert deny_read =~ ~s{(subpath "#{real(home)}/.ssh")}
      assert deny_read =~ ~s{(subpath "#{real(home)}/.codex/auth.json")}
      assert deny_read =~ ~s{(prefix "#{real(System.tmp_dir!())}/symphony-codex-home-")}
    end

    test "allows writes only to the given paths and the /dev sinks, then takes the protected paths back, and no TCP listener", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      write_paths = [workspace, tmp_dir, workspace]
      profile = DevServerSandbox.profile(workspace, write_paths, [".git"], home: home, socket_dir: tmp_dir)

      assert [
               "(version 1)",
               "(allow default)",
               "(deny file-read*" <> _deny_read,
               "(deny file-write*)",
               "(allow file-write*" <> allow_write,
               "(deny file-write*\n  " <> deny_write,
               "(deny network*)",
               "(allow network*\n  " <> allow_sockets,
               ~s{(allow network-outbound (remote ip "localhost:*"))},
               ~s{(allow network-outbound\n  (literal "/private/var/run/mDNSResponder"))},
               "(deny mach-lookup)",
               "(allow mach-lookup\n  " <> allow_mach_lookup,
               "(deny appleevent-send)",
               "(deny lsopen)",
               "(deny job-creation)",
               "(deny mach-lookup\n  " <> deny_mach_lookup,
               "(deny process-exec\n  " <> deny_exec,
               "(deny process-info*)",
               "(allow process-info* (target same-sandbox))",
               "(deny signal)",
               "(allow signal (target same-sandbox))"
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
      assert allow_sockets == ~s{(subpath "#{real(tmp_dir)}"))}

      assert allow_mach_lookup ==
               """
               (global-name "com.apple.logd")
                 (global-name "com.apple.system.logger")
                 (global-name "com.apple.system.notification_center")
                 (global-name "com.apple.system.opendirectoryd.libinfo")
                 (global-name "com.apple.system.opendirectoryd.membership")
                 (global-name "com.apple.bsd.dirhelper")
                 (global-name "com.apple.securityd.xpc")
                 (global-name "com.apple.SecurityServer")
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

      profile = DevServerSandbox.profile(link, [link], [], home: home, socket_dir: link)

      assert profile =~ ~s{(subpath "#{real(root)}/odd \\"quoted\\" \\\\ dir")}
      refute profile =~ "workspace-link"
    end

    test "keeps a path it can't resolve as given", %{root: root, home: home} do
      file = Path.join(root, "file")
      File.write!(file, "")
      workspace = Path.join(file, "workspace")

      assert DevServerSandbox.profile(workspace, [workspace], [], home: home, socket_dir: workspace) =~ ~s{(subpath "#{workspace}")}
    end
  end

  describe "mach_services/0" do
    test "is the agent profiles' list without the ones it leaves out, plus the ones it adds" do
      %{agent: agent, agent_opt_in: opt_in, left_out: left_out, added: added, dev_server: dev_server} =
        DevServerSandbox.mach_services()

      assert left_out -- agent == []
      assert added -- agent == added
      assert dev_server == (agent -- left_out) ++ added
      assert agent -- opt_in == agent
      assert Enum.uniq(agent ++ opt_in) == agent ++ opt_in
      refute Enum.any?(dev_server, &(&1 =~ ~r/windowserver|pasteboard|fonts|lsd|launchservices/i))
    end
  end

  # Checks the record of the agent profiles' mach services against the profile an SRT install
  # generates (`SRT_PACKAGE_DIR`, the `@anthropic-ai/sandbox-runtime` package folder). Claude Code
  # runs SRT's profile too. The `agent-profile` workflow runs it with the latest SRT.
  describe "against SRT's profile" do
    @describetag :srt_profile

    test "the agent profiles allow the recorded mach services" do
      package = System.get_env("SRT_PACKAGE_DIR") || flunk("set SRT_PACKAGE_DIR to the SRT package folder")
      source = File.read!(Path.join(package, "dist/sandbox/macos-sandbox-utils.js"))
      %{agent: agent, agent_opt_in: opt_in} = DevServerSandbox.mach_services()

      # The profile's mach-lookup block, then single rules: SecurityServer always, the rest behind
      # an option.
      [block] = Regex.run(~r/'\(allow mach-lookup',\n(.*?)\n\s*'\)',/s, source, capture: :all_but_first)

      assert global_names(block) ++ ["com.apple.SecurityServer"] == agent
      assert Enum.sort(global_names(source)) == Enum.sort(agent ++ opt_in)
    end
  end

  describe "under Seatbelt" do
    @describetag :seatbelt

    test "a command can't read a credential path but reads and writes the workspace", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      File.mkdir_p!(Path.join(home, ".ssh"))
      File.write!(Path.join(home, ".ssh/id_ed25519"), "secret")
      File.write!(Path.join(home, "notes.txt"), "notes")
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [".git"], home: home, socket_dir: tmp_dir)

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
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [], home: home, socket_dir: tmp_dir)
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
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [], home: home, socket_dir: tmp_dir)
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

    test "a command can't read the environment of a process outside the sandbox, or signal it", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [], home: home, socket_dir: tmp_dir)
      secret = "symphony-secret-#{System.unique_integer([:positive])}"
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"], env: [{~c"SYMPHONY_TEST_SECRET", String.to_charlist(secret)}]])
      {:os_pid, pid} = Port.info(port, :os_pid)
      on_exit(fn -> System.cmd("/bin/kill", ["#{pid}"], stderr_to_stdout: true) end)
      ps = "/bin/ps eww -o command= -p #{pid}"

      # Outside the sandbox `ps` shows it, once `sleep` has replaced the forked child.
      wait_until(fn -> System.cmd("/bin/sh", ["-c", ps], stderr_to_stdout: true) |> elem(0) =~ secret end)

      assert {output, _status} = seatbelt(profile, workspace, ps)
      refute output =~ secret

      assert {output, status} = seatbelt(profile, workspace, "kill -0 #{pid}")
      assert status != 0
      assert output =~ "Operation not permitted"

      # Its own processes it still signals.
      assert {_output, 0} = seatbelt(profile, workspace, "/bin/sleep 5 & kill -0 $! && kill $!")
    end

    test "a command gets no window server and no pasteboard, but still checks TLS certificates", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [], home: home, socket_dir: tmp_dir)
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

    # Seatbelt can't keep a TCP listener on loopback, so the profile allows none: the dev server
    # listens on a unix socket in its temp folder, which Symphony serves on loopback.
    test "a command can open no TCP listener on any address, only a unix socket in its temp folder", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [], home: home, socket_dir: tmp_dir)
      {:ok, interfaces} = :inet.getifaddrs()
      lan = for {_name, options} <- interfaces, {:addr, {first, _, _, _} = address} <- options, first != 127, do: to_string(:inet.ntoa(address))

      for address <- ["0.0.0.0", "127.0.0.1" | lan] do
        python = "import socket; s = socket.socket(); s.bind((\"#{address}\", 0)); s.listen()"
        assert {output, status} = seatbelt(profile, workspace, "python3 -c '#{python}'")
        assert status != 0, "listened on #{address}"
        assert output =~ "Operation not permitted"
      end

      unix_listen = fn path -> "python3 -c 'import socket; s = socket.socket(socket.AF_UNIX); s.bind(\"#{path}\"); s.listen()'" end
      # Short names: macOS's TMPDIR is long, and a socket path holds 103 bytes.
      assert {_output, 0} = seatbelt(profile, workspace, unix_listen.(Path.join(real(tmp_dir), "s.sock")))
      assert {output, status} = seatbelt(profile, workspace, unix_listen.(Path.join(real(workspace), "s.sock")))
      assert status != 0
      assert output =~ "Operation not permitted"

      assert {:ok, ["/usr/bin/sandbox-exec" | _argv], []} = DevServerSandbox.command("true", workspace, tmp_dir, [])
    end

    # Mix's build lock and pub/sub listen on an ephemeral 127.0.0.1 port, as the agent's own
    # sandbox lets them.
    test "a build command can listen on loopback, and still writes only its paths", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      opts = [home: home, socket_dir: tmp_dir, loopback_listeners: true]
      profile = DevServerSandbox.profile(workspace, [workspace, tmp_dir], [], opts)

      python =
        "import socket; s = socket.socket(); s.bind((\"127.0.0.1\", 0)); s.listen(); " <>
          "c = socket.create_connection(s.getsockname()); print(\"accepted\" if s.accept() else \"\")"

      assert {output, 0} = seatbelt(profile, workspace, "python3 -c '#{python}'")
      assert output =~ "accepted"

      assert {output, status} = seatbelt(profile, workspace, "touch #{Path.join(home, "outside")}")
      assert status != 0
      assert output =~ "Operation not permitted"
    end
  end

  describe "under bwrap" do
    @describetag :bwrap

    # Out of `/tmp`, which the sandbox empties, so the home folder's other files stay readable.
    setup do
      root = Path.join(File.cwd!(), "tmp/dev-server-bwrap-#{System.unique_integer([:positive])}")
      workspace = Path.join(root, "workspace")
      tmp_dir = Path.join(root, "tmp")
      home = Path.join(root, "home")
      Enum.each([workspace, tmp_dir, home], &File.mkdir_p!/1)
      on_exit(fn -> File.rm_rf(root) end)

      {:ok, workspace: workspace, tmp_dir: tmp_dir, home: home}
    end

    test "a command can't read a credential path but reads and writes the workspace", %{workspace: workspace, tmp_dir: tmp_dir, home: home} do
      File.mkdir_p!(Path.join(home, ".ssh"))
      File.write!(Path.join(home, ".ssh/id_ed25519"), "secret")
      File.write!(Path.join(home, "notes.txt"), "notes")
      File.mkdir_p!(Path.join(workspace, ".git"))
      File.mkdir_p!(Path.join(workspace, ".claude"))
      protected = [".git", ".claude/settings.local.json", ".agents/skills"]
      {args, _placeholders} = DevServerSandbox.bwrap_args(workspace, [workspace, tmp_dir], protected, home)

      assert {output, status} = bwrap(args, "cat #{home}/.ssh/id_ed25519")
      assert status != 0
      refute output =~ "secret"

      assert {"notes", 0} = bwrap(args, "cat #{home}/notes.txt")
      assert {_output, 0} = bwrap(args, "echo built > build.txt && echo tmp > #{tmp_dir}/tmp.txt")
      assert File.read!(Path.join(workspace, "build.txt")) == "built\n"
      assert File.read!(Path.join(tmp_dir, "tmp.txt")) == "tmp\n"

      for script <- ["echo hook > #{home}/planted.txt", "echo hook > .git/config", "echo '{}' > .claude/settings.local.json", "mkdir -p .agents/skills"] do
        assert {_output, status} = bwrap(args, script)
        assert status != 0, script
      end

      refute File.exists?(Path.join(home, "planted.txt"))
      refute File.exists?(Path.join(workspace, ".git/config"))
      refute File.exists?(Path.join(workspace, ".claude/settings.local.json"))
      refute File.exists?(Path.join(workspace, ".agents/skills"))
    end

    test "a command reaches the network only on its loopback, and the dependency hosts only through the proxy", %{workspace: workspace, tmp_dir: tmp_dir} do
      proxy = start_supervised!({EgressProxy, allowed_domains: ["localhost"]})
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, local_port} = :inet.port(listen)
      proxy_port = EgressProxy.port(proxy)

      # The bridges start beside the command, so the first tries may find nobody listening yet.
      File.write!(Path.join(workspace, "check.py"), """
      import socket, time

      def connect(host):
          for _ in range(100):
              try:
                  s = socket.create_connection(("127.0.0.1", #{proxy_port}), timeout=5)
                  s.sendall(b"CONNECT " + host + b":#{local_port} HTTP/1.1\\r\\n\\r\\n")
                  line = s.recv(200).decode().split("\\r\\n")[0]
                  if line:
                      return line
              except OSError:
                  pass
              time.sleep(0.1)
          return "no proxy"

      try:
          socket.create_connection(("192.0.2.1", 443), timeout=5)
          print("direct: connected")
      except OSError as error:
          print("direct: " + str(error.strerror))
      print(connect(b"localhost"))
      print(connect(b"example.com"))
      """)

      opts = [os_type: {:unix, :linux}, port: free_port(), proxy_port: proxy_port]
      assert {:ok, [shell | args], _placeholders} = DevServerSandbox.command("python3 check.py", workspace, tmp_dir, opts)
      assert {output, 0} = System.cmd(shell, args, cd: workspace, stderr_to_stdout: true)

      assert output =~ "direct: Network is unreachable\n"
      assert output =~ "HTTP/1.1 200 Connection Established\n"
      assert output =~ "HTTP/1.1 403 Forbidden: example.com is not on"

      :gen_tcp.close(listen)
    end
  end

  defp chunk_options(args) do
    Enum.chunk_while(
      args,
      [],
      fn
        "--" <> _option = arg, [] -> {:cont, [arg]}
        "--" <> _option = arg, option -> {:cont, Enum.reverse(option), [arg]}
        arg, option -> {:cont, [arg | option]}
      end,
      &{:cont, Enum.reverse(&1), []}
    )
  end

  defp bwrap(args, script) do
    System.cmd(System.find_executable("bwrap"), args ++ ["/bin/sh", "-c", script], stderr_to_stdout: true)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp fake_sandbox_exec(root, body) do
    executable = Path.join(root, "sandbox-exec")
    File.write!(executable, "#!/bin/sh\n#{body}\n")
    File.chmod!(executable, 0o755)
    executable
  end

  defp command(workspace, tmp_dir, executable) do
    DevServerSandbox.command("mix phx.server", workspace, tmp_dir, os_type: {:unix, :darwin}, executable: executable, getconf: "false")
  end

  defp python_connect(host, port) do
    "python3 -c 'import socket; socket.create_connection((\"#{host}\", #{port}), timeout=5)'"
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(100) && wait_until(fun, attempts - 1)
    end
  end

  defp seatbelt(profile, workspace, script) do
    System.cmd("/usr/bin/sandbox-exec", ["-p", profile, "/bin/sh", "-c", script], cd: workspace, stderr_to_stdout: true)
  end

  defp global_names(source) do
    ~r/\(global-name "([^"]+)"\)/
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
  end

  defp real(path) do
    {:ok, real_path} = SymphonyElixir.PathSafety.canonicalize(path)
    real_path
  end
end
