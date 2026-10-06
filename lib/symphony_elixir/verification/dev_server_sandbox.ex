defmodule SymphonyElixir.Verification.DevServerSandbox do
  @moduledoc """
  Wraps the verification dev server's command in macOS Seatbelt (`sandbox-exec`), so the
  checkout's code runs under limits like the agent's instead of as the operator on the host.

  The profile starts from `(allow default)` and takes away:

    * reads of the credential and config stores the agent can't read either
      (`SymphonyElixir.AgentSandboxConfig.deny_read_paths/0`, such as `~/.ssh` and `~/.aws`),
      of the Codex files a Codex agent can't read (`~/.codex/auth.json`, `~/.codex/config.toml`)
      and of every per-run `CODEX_HOME`;
    * writes anywhere but the checkout, the dev server's own temp folder, the agent cache
      folder, the item replacement folder and the `/dev` sinks, and, inside the checkout, the
      paths the agent may not write either (`.git`, `WORKFLOW.md`, its skills, the files their
      links point at);
    * the network, but for listening and connecting on loopback and DNS lookups through
      mDNSResponder. It reaches the dependency hosts through
      `SymphonyElixir.Verification.EgressProxy` on loopback;
    * every mach service but a fixed list, like the agent profiles: the agent's list without
      its window, font, sound, power and LaunchServices services, plus `trustd` for TLS. So no
      window server (no windows or dialogs on the operator's desktop) and no pasteboard;
    * the ways to have a process started outside the sandbox: Apple Events, LaunchServices
      (`open`), launchd jobs (`launchctl submit`), and running `open`, `osascript` and
      `launchctl` at all.

  Seatbelt matches the real path of a file, so the checkout, the temp folders and the home
  folder are given with their links resolved, and a denied path outside the home folder also
  with its real path (`/var/root` is `/private/var/root`).

  Some macOS versions don't keep a listener on loopback: on macOS 15 the rule that lets the
  dev server accept connections on loopback also lets it bind `0.0.0.0` and the LAN address.
  So before the first dev server starts, a process under the profile binds `0.0.0.0`, and unless
  Seatbelt refuses it the dev server does not start (`:dev_server_sandbox_unconfined`). The
  verdict holds until Symphony restarts.

  On Linux the command runs under bubblewrap (`bwrap`) instead, with the same limits built from
  mounts and namespaces (`bwrap_args/4`): the whole filesystem read-only but the same writable
  paths, the denied read paths covered by empty ones, and a network namespace of its own that
  has only loopback. `socat` bridges that loopback to the host's over unix sockets in the dev
  server's temp folder, for its own port and the egress proxy's, as the sandbox runtime does for
  agents on Linux. Without `bwrap` or `socat`, where `bwrap` can't make its namespaces (no
  unprivileged user namespaces, Docker's default seccomp profile), and on any other system, the
  dev server does not start.
  """

  alias SymphonyElixir.{AgentCaches, AgentSandboxConfig, PathSafety}
  alias SymphonyElixir.Codex.McpConfig

  @sandbox_exec "/usr/bin/sandbox-exec"
  @dev_write_paths ~w(/dev/null /dev/zero /dev/tty /dev/stdout /dev/stderr /dev/dtracehelper /dev/autofs_nowait)
  @dev_write_subpaths ~w(/dev/fd)
  @dns_socket "/private/var/run/mDNSResponder"
  # The mach services the Claude Code and SRT agent profiles always allow, as SRT's
  # `generateSandboxProfile` (`dist/sandbox/macos-sandbox-utils.js`, SRT 0.0.78) lists them: its
  # mach-lookup block, then SecurityServer, the keychain daemon, which `mix` needs to read the
  # system's root certificates. The `:srt_profile` test checks this against an SRT install.
  @agent_mach_services ~w(
    com.apple.audio.systemsoundserver
    com.apple.distributed_notifications@Uv3
    com.apple.FontObjectsServer
    com.apple.fonts
    com.apple.logd
    com.apple.lsd.mapdb
    com.apple.PowerManagement.control
    com.apple.system.logger
    com.apple.system.notification_center
    com.apple.system.opendirectoryd.libinfo
    com.apple.system.opendirectoryd.membership
    com.apple.bsd.dirhelper
    com.apple.securityd.xpc
    com.apple.coreservices.launchservicesd
    com.apple.SecurityServer
  )
  # The ones SRT allows only behind an option: `enableWeakerNetworkIsolation` (trustd.agent) and
  # `allowAppleEvents` (the rest).
  @agent_opt_in_mach_services ~w(
    com.apple.trustd.agent
    com.apple.coreservices.appleevents
    com.apple.CoreServices.coreservicesd
    com.apple.coreservices.quarantine-resolver
  )
  # The agent's services the dev server goes without: the window (distributed notifications), font,
  # sound, power and LaunchServices ones.
  @left_out_mach_services ~w(
    com.apple.distributed_notifications@Uv3
    com.apple.FontObjectsServer
    com.apple.fonts
    com.apple.audio.systemsoundserver
    com.apple.PowerManagement.control
    com.apple.lsd.mapdb
    com.apple.coreservices.launchservicesd
  )
  # trustd, for tools that check TLS certificates with Security.framework.
  @added_mach_services ~w(com.apple.trustd com.apple.trustd.agent)
  # The dev server's list, kept in step with the agent's by deriving it.
  @mach_services (@agent_mach_services -- @left_out_mach_services) ++ @added_mach_services
  # launchd starts what these ask for as the operator, outside the sandbox.
  @launch_services ~w(com.apple.coreservices.launchservicesd com.apple.coreservices.appleevents)
  @launch_services_prefixes ~w(com.apple.lsd.)
  @launcher_executables ~w(/usr/bin/open /usr/bin/osascript /bin/launchctl)
  # Binds every address on a free port, and exits non-zero with the reason when it can't.
  @confinement_probe [
    "/usr/bin/perl",
    "-MSocket",
    "-e",
    ~S{socket(my $s, PF_INET, SOCK_STREAM, 0) or die "socket: $!\n"; bind($s, sockaddr_in(0, INADDR_ANY)) or die "bind: $!\n"; print "bound\n"}
  ]

  # A pid namespace that dies with the launcher's child, and no network but loopback. No
  # `--new-session`: the dev server stops by its process group, and it has no terminal to reach.
  @bwrap_namespaces ~w(--die-with-parent --unshare-all)
  # Other runs' temp folders, and the X11, D-Bus and Docker sockets.
  @bwrap_hidden_dirs ~w(/tmp /run)
  @proxy_socket "proxy.sock"
  @serve_socket "serve.sock"

  @doc """
  The argv that runs `start_cmd` with `sh -lc` inside the sandbox, writable in `workspace`
  and `tmp_dir`, and the empty folders the sandbox makes in `workspace` (`bwrap_args/4`), for
  the caller to remove once nothing runs in it. On macOS the profile must first be known to keep
  listeners on loopback on this Mac. Options: `:os_type` (default `:os.type()`); on macOS
  `:executable` (default `/usr/bin/sandbox-exec`), `:getconf` (for the item replacement folder)
  and `:check_confinement` (default `true`; the tests' stand-in for `sandbox-exec`, which drops
  the profile, turns it off); on Linux `:bwrap` and `:socat` (default: found on `PATH`), and the
  dev server's `:port` and the egress proxy's `:proxy_port`, which the bridges carry.
  """
  @spec command(String.t(), Path.t(), Path.t(), keyword()) :: {:ok, [String.t()], [Path.t()]} | {:error, term()}
  def command(start_cmd, workspace, tmp_dir, opts) when is_binary(start_cmd) do
    case Keyword.get_lazy(opts, :os_type, &:os.type/0) do
      {:unix, :darwin} -> seatbelt_command(start_cmd, workspace, tmp_dir, opts)
      {:unix, :linux} -> bwrap_command(start_cmd, workspace, tmp_dir, opts)
      os_type -> {:error, {:dev_server_sandbox_unavailable, os_type}}
    end
  end

  defp seatbelt_command(start_cmd, workspace, tmp_dir, opts) do
    executable = Keyword.get(opts, :executable, @sandbox_exec)

    if File.regular?(executable) do
      sandboxed_command(start_cmd, workspace, tmp_dir, executable, opts)
    else
      {:error, {:dev_server_sandbox_unavailable, {:not_found, executable}}}
    end
  end

  # The host side of the bridges runs outside the sandbox, in the dev server's process group, so
  # stopping the group stops it too. It ends with `bwrap` either way: the shell waits for `bwrap`
  # before a stop signal's trap, then stops and reaps the bridges.
  defp bwrap_command(start_cmd, workspace, tmp_dir, opts) do
    with {:ok, bwrap} <- find_tool(opts, :bwrap),
         {:ok, socat} <- find_tool(opts, :socat),
         :ok <- probe_bwrap(bwrap),
         {:ok, proxy_socket} <- socket_path(tmp_dir, @proxy_socket),
         {:ok, serve_socket} <- socket_path(tmp_dir, @serve_socket) do
      port = Keyword.fetch!(opts, :port)
      proxy_port = Keyword.fetch!(opts, :proxy_port)
      write_paths = [workspace, tmp_dir] ++ AgentCaches.write_paths()
      {args, placeholders} = bwrap_args(workspace, write_paths, protected_paths(workspace))

      sandbox_script =
        Enum.join(
          [
            sh_command([socat, "TCP-LISTEN:#{proxy_port},bind=127.0.0.1,reuseaddr,fork", "UNIX-CONNECT:#{proxy_socket}"]) <> " &",
            sh_command([socat, "UNIX-LISTEN:#{serve_socket},fork,unlink-early", "TCP:127.0.0.1:#{port}"]) <> " &",
            "exec " <> sh_command(["/bin/sh", "-lc", start_cmd])
          ],
          "\n"
        )

      host_script =
        Enum.join(
          [
            sh_command([socat, "UNIX-LISTEN:#{proxy_socket},fork,unlink-early", "TCP:127.0.0.1:#{proxy_port}"]) <> " &",
            "proxy_bridge=$!",
            sh_command([socat, "TCP-LISTEN:#{port},bind=127.0.0.1,reuseaddr,fork", "UNIX-CONNECT:#{serve_socket}"]) <> " &",
            "serve_bridge=$!",
            "trap : HUP INT TERM",
            sh_command([bwrap | args] ++ ["/bin/sh", "-c", sandbox_script]),
            "status=$?",
            "kill $proxy_bridge $serve_bridge 2>/dev/null",
            "wait",
            "exit $status"
          ],
          "\n"
        )

      {:ok, ["/bin/sh", "-c", host_script], placeholders}
    else
      {:error, reason} -> {:error, {:dev_server_sandbox_unavailable, reason}}
    end
  end

  defp find_tool(opts, name) do
    tool = Atom.to_string(name)
    path = Keyword.get_lazy(opts, name, fn -> System.find_executable(tool) end)

    if is_binary(path) and File.regular?(path), do: {:ok, path}, else: {:error, {:not_found, path || tool}}
  end

  # Where unprivileged user namespaces are off, or seccomp refuses them (a Docker container's
  # default profile), `bwrap` fails at once: say so instead of waiting out the health check.
  defp probe_bwrap(bwrap) do
    case System.cmd(bwrap, @bwrap_namespaces ++ ~w(--ro-bind / / --dev /dev --proc /proc /bin/sh -c :), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:bwrap_failed, String.trim(output)}}
    end
  end

  # socat splits an address on `:` and `,`, and a unix socket path holds 107 bytes.
  defp socket_path(tmp_dir, name) do
    path = Path.join(real_path(tmp_dir), name)
    if path =~ ~r"\A[A-Za-z0-9/._-]{1,107}\z", do: {:ok, path}, else: {:error, {:unusable_socket_path, path}}
  end

  defp sandboxed_command(start_cmd, workspace, tmp_dir, executable, opts) do
    write_paths = [workspace, tmp_dir] ++ AgentCaches.write_paths() ++ item_replacement_paths(opts)
    profile = profile(workspace, write_paths, protected_paths(workspace))

    with :ok <- check_confinement(executable, profile, opts) do
      {:ok, [executable, "-p", profile, "/bin/sh", "-lc", start_cmd], []}
    end
  end

  # The macOS version can't change while Symphony runs, so a bind refused or allowed is kept; a
  # probe that couldn't run is tried again next time.
  defp check_confinement(executable, profile, opts) do
    key = {__MODULE__, :confinement, executable}

    cond do
      not Keyword.get(opts, :check_confinement, true) ->
        :ok

      verdict = :persistent_term.get(key, nil) ->
        verdict

      true ->
        case probe_confinement(executable, profile) do
          {:error, {:dev_server_sandbox_unconfined, {:probe_failed, _status, _output}}} = error -> error
          verdict -> tap(verdict, &:persistent_term.put(key, &1))
        end
    end
  end

  # Only Seatbelt refusing the bind proves the confinement: a bind that works, or a probe that
  # can't run, leaves the dev server unstarted. `sandbox-exec` that can't apply the profile also
  # says "Operation not permitted", so the refusal must come from the bind.
  defp probe_confinement(executable, profile) do
    case System.cmd(executable, ["-p", profile | @confinement_probe], stderr_to_stdout: true) do
      {_output, 0} ->
        {:error, {:dev_server_sandbox_unconfined, :non_loopback_bind_allowed}}

      {output, status} ->
        if output =~ "bind: Operation not permitted",
          do: :ok,
          else: {:error, {:dev_server_sandbox_unconfined, {:probe_failed, status, String.trim(output)}}}
    end
  end

  # Foundation stages a sandboxed process's atomic writes in
  # `<DARWIN_USER_TEMP_DIR>/TemporaryItems`, whatever `TMPDIR` says.
  defp item_replacement_paths(opts) do
    case System.cmd(Keyword.get(opts, :getconf, "getconf"), ["DARWIN_USER_TEMP_DIR"], stderr_to_stdout: true) do
      {user_temp_dir, 0} -> [Path.join(String.trim(user_temp_dir), "TemporaryItems")]
      {_output, _status} -> []
    end
  end

  defp protected_paths(workspace),
    do: AgentSandboxConfig.workspace_protected_paths() ++ [".git" | AgentSandboxConfig.workspace_link_targets(workspace)]

  @doc """
  The mach services of the profile and where they come from: the ones the agent profiles always
  allow (`:agent`) and only behind an option (`:agent_opt_in`), the agent's ones the dev server
  leaves out (`:left_out`) and adds (`:added`), and the dev server's own list (`:dev_server`).
  """
  @spec mach_services() :: %{(:agent | :agent_opt_in | :left_out | :added | :dev_server) => [String.t()]}
  def mach_services do
    %{
      agent: @agent_mach_services,
      agent_opt_in: @agent_opt_in_mach_services,
      left_out: @left_out_mach_services,
      added: @added_mach_services,
      dev_server: @mach_services
    }
  end

  @doc """
  The Seatbelt profile: writable in `write_paths` but the `protected_paths` of `workspace`
  (relative to it), unreadable in the agent's denied read paths under `home`, with
  loopback-only network, an allowlist of mach services and no way to have launchd start a
  process outside it.
  """
  @spec profile(Path.t(), [Path.t()], [String.t()], Path.t()) :: String.t()
  def profile(workspace, write_paths, protected_paths, home \\ System.user_home!()) do
    home = real_path(home)
    workspace = real_path(workspace)

    deny_read =
      (AgentSandboxConfig.deny_read_paths() ++ AgentSandboxConfig.codex_runtime_deny_read_paths())
      |> Enum.flat_map(fn
        "~/" <> rest -> [Path.join(home, rest)]
        path -> [path, real_path(path)]
      end)
      |> Enum.uniq()

    writable = write_paths |> Enum.map(&real_path/1) |> Enum.uniq()
    protected = Enum.map(protected_paths, &Path.join(workspace, &1))

    [
      "(version 1)",
      "(allow default)",
      rule("deny file-read*", Enum.map(deny_read, &subpath/1) ++ [prefix(codex_homes_prefix())]),
      "(deny file-write*)",
      rule("allow file-write*", Enum.map(writable ++ @dev_write_subpaths, &subpath/1) ++ Enum.map(@dev_write_paths, &literal/1)),
      rule("deny file-write*", Enum.map(protected, &subpath/1)),
      "(deny network*)",
      ~s{(allow network-bind (local ip "localhost:*"))},
      ~s{(allow network-inbound (local ip "localhost:*"))},
      ~s{(allow network-outbound (remote ip "localhost:*"))},
      rule("allow network-outbound", [literal(@dns_socket)]),
      "(deny mach-lookup)",
      rule("allow mach-lookup", Enum.map(@mach_services, &"(global-name #{sb_string(&1)})")),
      "(deny appleevent-send)",
      "(deny lsopen)",
      "(deny job-creation)",
      rule(
        "deny mach-lookup",
        Enum.map(@launch_services, &"(global-name #{sb_string(&1)})") ++
          Enum.map(@launch_services_prefixes, &"(global-name-prefix #{sb_string(&1)})")
      ),
      rule("deny process-exec", Enum.map(@launcher_executables, &literal/1))
    ]
    |> Enum.join("\n")
  end

  @doc """
  The `bwrap` options before the command, and the placeholder folders they leave in
  `workspace`. Read-only everywhere but `write_paths`, with the `protected_paths` of
  `workspace` (relative to it) read-only again, the agent's denied read paths under `home`
  covered (a folder by an empty one, a file by `/dev/null`), `/tmp`, `/run` and the parent of
  every per-run `CODEX_HOME` empty, and a network namespace with loopback only.

  A protected path that doesn't exist yet can't be mounted over, so its nearest folder inside
  the checkout is made read-only instead (`.claude` for a missing `.claude/settings.json`). When
  that folder is the checkout itself, a missing top-level folder (`.claude`, `.ai`) gets an empty
  read-only placeholder, which `bwrap` creates in the checkout and the caller removes after. A
  missing top-level file (`WORKFLOW.md`, `mise.toml`) is left out: its placeholder would be an
  empty file in the agent's `git status` for the whole run.
  """
  @spec bwrap_args(Path.t(), [Path.t()], [String.t()], Path.t()) :: {[String.t()], [Path.t()]}
  def bwrap_args(workspace, write_paths, protected_paths, home \\ System.user_home!()) do
    workspace = real_path(workspace)
    home = real_path(home)
    hidden_dirs = Enum.uniq(@bwrap_hidden_dirs ++ [real_path(Path.dirname(McpConfig.runtime_home_prefix()))])
    writable = write_paths |> Enum.map(&real_path/1) |> Enum.uniq()

    protections = Enum.map(protected_paths, &protection(workspace, Path.join(workspace, &1)))
    read_only = for {:read_only, path} <- protections, uniq: true, do: path
    placeholders = for {:placeholder, path} <- protections, uniq: true, do: path

    args =
      @bwrap_namespaces ++
        ["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc"] ++
        Enum.flat_map(hidden_dirs, &["--tmpfs", &1]) ++
        Enum.flat_map(writable, &["--bind", &1, &1]) ++
        Enum.flat_map(read_only, &["--ro-bind", &1, &1]) ++
        Enum.flat_map(placeholders, &["--tmpfs", &1, "--remount-ro", &1]) ++
        Enum.flat_map(deny_read_paths(home), &cover/1) ++
        ["--chdir", workspace]

    {args, placeholders}
  end

  defp protection(workspace, path) do
    if File.exists?(path), do: {:read_only, path}, else: missing_protection(workspace, path, true)
  end

  # The nearest folder of a missing protected path that exists: read-only inside the checkout, a
  # placeholder for a missing top-level folder, nothing for a top-level file or a path that a
  # file or a link is in the way of.
  defp missing_protection(workspace, path, protected_path?) do
    parent = Path.dirname(path)

    cond do
      match?({:error, _reason}, File.lstat(parent)) -> missing_protection(workspace, parent, false)
      not File.dir?(parent) -> nil
      parent != workspace -> {:read_only, parent}
      protected_path? -> nil
      true -> {:placeholder, path}
    end
  end

  defp deny_read_paths(home) do
    (AgentSandboxConfig.deny_read_paths() ++ AgentSandboxConfig.codex_runtime_deny_read_paths())
    |> Enum.map(fn
      "~/" <> rest -> real_path(Path.join(home, rest))
      path -> real_path(path)
    end)
    |> Enum.uniq()
  end

  defp cover(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> ["--tmpfs", path]
      {:ok, _file} -> ["--ro-bind", "/dev/null", path]
      {:error, _reason} -> []
    end
  end

  defp sh_command(argv), do: Enum.map_join(argv, " ", &sh_quote/1)

  defp sh_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp rule(action, filters), do: "(#{action}\n  " <> Enum.join(filters, "\n  ") <> ")"

  # A per-run `CODEX_HOME` holds the agent's MCP config and a link to its auth.
  defp codex_homes_prefix do
    prefix = McpConfig.runtime_home_prefix()
    Path.join(real_path(Path.dirname(prefix)), Path.basename(prefix))
  end

  defp subpath(path), do: "(subpath #{sb_string(path)})"
  defp prefix(path), do: "(prefix #{sb_string(path)})"
  defp literal(path), do: "(literal #{sb_string(path)})"

  defp sb_string(value), do: ~s(") <> String.replace(value, ["\\", ~s(")], &("\\" <> &1)) <> ~s(")

  defp real_path(path) do
    case PathSafety.canonicalize(path) do
      {:ok, real_path} -> real_path
      {:error, _reason} -> Path.expand(path)
    end
  end
end
