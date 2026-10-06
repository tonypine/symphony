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
  with its real path (`/var/root` is `/private/var/root`). Off macOS there is no Seatbelt, and the dev
  server does not start.

  Some macOS versions don't keep a listener on loopback: on macOS 15 the rule that lets the
  dev server accept connections on loopback also lets it bind `0.0.0.0` and the LAN address.
  So before the first dev server starts, a process under the profile binds `0.0.0.0`, and unless
  Seatbelt refuses it the dev server does not start (`:dev_server_sandbox_unconfined`). The
  verdict holds until Symphony restarts.
  """

  alias SymphonyElixir.{AgentCaches, AgentSandboxConfig, PathSafety}
  alias SymphonyElixir.Codex.McpConfig

  @sandbox_exec "/usr/bin/sandbox-exec"
  @dev_write_paths ~w(/dev/null /dev/zero /dev/tty /dev/stdout /dev/stderr /dev/dtracehelper /dev/autofs_nowait)
  @dev_write_subpaths ~w(/dev/fd)
  @dns_socket "/private/var/run/mDNSResponder"
  # The mach services the Claude Code and SRT agent profiles allow, without the window, font,
  # sound, power and LaunchServices ones, plus trustd for tools that check TLS certificates with
  # Security.framework. SecurityServer is the keychain daemon: the agent profiles allow it too,
  # and `mix` needs it to read the system's root certificates.
  @mach_services ~w(
    com.apple.system.opendirectoryd.libinfo
    com.apple.system.opendirectoryd.membership
    com.apple.system.notification_center
    com.apple.system.logger
    com.apple.logd
    com.apple.bsd.dirhelper
    com.apple.SecurityServer
    com.apple.securityd.xpc
    com.apple.trustd
    com.apple.trustd.agent
  )
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

  @doc """
  The argv that runs `start_cmd` with `sh -lc` inside the sandbox, writable in `workspace`
  and `tmp_dir`, once the profile is known to keep listeners on loopback on this Mac. Options:
  `:os_type` (default `:os.type()`), `:executable` (default `/usr/bin/sandbox-exec`),
  `:getconf` (for the item replacement folder) and `:check_confinement` (default `true`; the
  tests' stand-in for `sandbox-exec`, which drops the profile, turns it off).
  """
  @spec command(String.t(), Path.t(), Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def command(start_cmd, workspace, tmp_dir, opts) when is_binary(start_cmd) do
    executable = Keyword.get(opts, :executable, @sandbox_exec)

    case Keyword.get_lazy(opts, :os_type, &:os.type/0) do
      {:unix, :darwin} ->
        if File.regular?(executable) do
          sandboxed_command(start_cmd, workspace, tmp_dir, executable, opts)
        else
          {:error, {:dev_server_sandbox_unavailable, {:not_found, executable}}}
        end

      os_type ->
        {:error, {:dev_server_sandbox_unavailable, os_type}}
    end
  end

  defp sandboxed_command(start_cmd, workspace, tmp_dir, executable, opts) do
    write_paths = [workspace, tmp_dir] ++ AgentCaches.write_paths() ++ item_replacement_paths(opts)
    profile = profile(workspace, write_paths, protected_paths(workspace))

    with :ok <- check_confinement(executable, profile, opts) do
      {:ok, [executable, "-p", profile, "/bin/sh", "-lc", start_cmd]}
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
