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
    * the ways to have a process started outside the sandbox: Apple Events, LaunchServices
      (`open`), launchd jobs (`launchctl submit`), and running `open`, `osascript` and
      `launchctl` at all.

  Seatbelt matches the real path of a file, so the checkout, the temp folders and the home
  folder are given with their links resolved, and a denied path outside the home folder also
  with its real path (`/var/root` is `/private/var/root`). Off macOS there is no Seatbelt, and the dev
  server does not start.
  """

  alias SymphonyElixir.{AgentCaches, AgentSandboxConfig, PathSafety}
  alias SymphonyElixir.Codex.McpConfig

  @sandbox_exec "/usr/bin/sandbox-exec"
  @dev_write_paths ~w(/dev/null /dev/zero /dev/tty /dev/stdout /dev/stderr /dev/dtracehelper /dev/autofs_nowait)
  @dev_write_subpaths ~w(/dev/fd)
  @dns_socket "/private/var/run/mDNSResponder"
  # launchd starts what these ask for as the operator, outside the sandbox.
  @launch_services ~w(com.apple.coreservices.launchservicesd com.apple.coreservices.appleevents)
  @launch_services_prefixes ~w(com.apple.lsd.)
  @launcher_executables ~w(/usr/bin/open /usr/bin/osascript /bin/launchctl)

  @doc """
  The argv that runs `start_cmd` with `sh -lc` inside the sandbox, writable in `workspace`
  and `tmp_dir`. Options: `:os_type` (default `:os.type()`), `:executable` (default
  `/usr/bin/sandbox-exec`) and `:getconf` (for the item replacement folder).
  """
  @spec command(String.t(), Path.t(), Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def command(start_cmd, workspace, tmp_dir, opts) when is_binary(start_cmd) do
    executable = Keyword.get(opts, :executable, @sandbox_exec)

    case Keyword.get_lazy(opts, :os_type, &:os.type/0) do
      {:unix, :darwin} = os_type ->
        if File.regular?(executable) do
          write_paths = [workspace, tmp_dir] ++ AgentCaches.write_paths() ++ item_replacement_paths(os_type, opts)
          profile = profile(workspace, write_paths, protected_paths(workspace))
          {:ok, [executable, "-p", profile, "/bin/sh", "-lc", start_cmd]}
        else
          {:error, {:dev_server_sandbox_unavailable, {:not_found, executable}}}
        end

      os_type ->
        {:error, {:dev_server_sandbox_unavailable, os_type}}
    end
  end

  defp item_replacement_paths(os_type, opts),
    do: AgentSandboxConfig.item_replacement_write_paths(os_type: os_type, getconf: Keyword.get(opts, :getconf, "getconf"))

  defp protected_paths(workspace),
    do: AgentSandboxConfig.workspace_protected_paths() ++ [".git" | AgentSandboxConfig.workspace_link_targets(workspace)]

  @doc """
  The Seatbelt profile: writable in `write_paths` but the `protected_paths` of `workspace`
  (relative to it), unreadable in the agent's denied read paths under `home`, with
  loopback-only network and no way to have launchd start a process outside it.
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
