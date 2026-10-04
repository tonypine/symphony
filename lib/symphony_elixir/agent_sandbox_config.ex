defmodule SymphonyElixir.AgentSandboxConfig do
  require Logger

  @moduledoc """
  Shared sandbox defaults for agent runtimes.

  Produces Claude Code `sandbox.filesystem` settings and Codex
  `permissions.workspace_write.*` `--config` overrides from a single deny
  list so both adapters stay in sync. Operator-supplied
  `workspace.sandbox.allow_read_paths` entries are subtracted from the
  shared `denyRead` set for both runtimes. Operator-supplied
  `workspace.sandbox.allow_write_paths` entries are emitted as
  `sandbox.filesystem.allowWrite` for the Claude runtime to broaden the
  default writable set (workspace + `/tmp`).

  Currently covered credential / config stores (read-deny):

    * `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.docker`
    * `~/.config/gh`, `~/.config/op`, `~/.config/gcloud`, `~/.azure`, `~/.kube`
    * `~/.netrc`, `~/.git-credentials`, `~/.npmrc`, `~/.cargo/credentials`
    * `~/.claude/.credentials.json` (Claude Code credentials)
    * `~/.claude/projects`, `~/.claude/file-history` (Claude Code session state)
    * `~/.claude/CLAUDE.md`, `~/.claude/agents`, `~/.claude/commands`, `~/.claude/hooks`
      (operator-authored Claude Code prompts / subagents / hooks)
    * `/etc/sudoers`, `/private/etc/sudoers`, `/var/root` (macOS admin/root state)
    * `~/Library/Application Support`, `~/Library/Keychains`, `~/Library/Preferences` (macOS app data)
    * shell startup files (e.g. `~/.zshrc`, `~/.bash_profile`) and shell/REPL history files

  Codex command sandboxing additionally denies reads of selected runtime
  files under `~/.codex` while leaving the parent Codex process able to
  authenticate before the tool sandbox applies.

  Workflow guardrail files and user persistence paths protected from writes:

    * `WORKFLOW.md`, `symphony.yml`, `symphony.local.yml`
    * `.git`, `mise.toml`, `.tool-versions`
    * project-local `.claude/{settings.json,settings.local.json,CLAUDE.md,agents,commands,hooks}`
      and user-scope `~/.claude/{CLAUDE.md,settings.json,settings.local.json,agents,commands,`
      `hooks,plugins,skills}` plus `~/.mcp.json` (auto-loaded on next Claude Code session;
      writes to these would silently persist prompt-injection across runs)
    * shell startup files, `~/.gitconfig`, and macOS launch agent roots
  """

  @codex_profile "workspace_write"
  @codex_tool_output_token_limit 4096

  @deny_read_paths [
    "/Volumes",
    "~/.ssh",
    "~/.config/gh",
    "~/.claude/.credentials.json",
    "~/.claude/projects",
    "~/.claude/file-history",
    "~/.claude/CLAUDE.md",
    "~/.claude/agents",
    "~/.claude/commands",
    "~/.claude/hooks",
    "/etc/sudoers",
    "/etc/sudoers.d",
    "/private/etc/sudoers",
    "/private/etc/sudoers.d",
    "/var/root",
    "~/.aws",
    "~/.gnupg",
    "~/Library/Application Support",
    "~/Library/Keychains",
    "~/Library/Preferences",
    "~/.docker",
    "~/.netrc",
    "~/.git-credentials",
    "~/.npmrc",
    "~/.cargo/credentials",
    "~/.config/op",
    "~/.config/gcloud",
    "~/.azure",
    "~/.kube",
    "~/.zshrc",
    "~/.zshenv",
    "~/.zprofile",
    "~/.bashrc",
    "~/.bash_profile",
    "~/.profile",
    "~/.bash_history",
    "~/.zsh_history",
    "~/.history",
    "~/.python_history",
    "~/.node_repl_history"
  ]

  @deny_write_paths [
    "./WORKFLOW.md",
    "./symphony.yml",
    "./symphony.local.yml",
    "./.claude/settings.json",
    "./.claude/settings.local.json",
    "./.claude/CLAUDE.md",
    "./.claude/agents",
    "./.claude/commands",
    "./.claude/hooks",
    "./.git",
    "./mise.toml",
    "./.tool-versions",
    "~/.zshrc",
    "~/.zshenv",
    "~/.zprofile",
    "~/.bashrc",
    "~/.bash_profile",
    "~/.profile",
    "~/.gitconfig",
    "~/Library/LaunchAgents",
    "~/Library/LaunchDaemons",
    "~/.claude/CLAUDE.md",
    "~/.claude/settings.json",
    "~/.claude/settings.local.json",
    "~/.claude/agents",
    "~/.claude/commands",
    "~/.claude/hooks",
    "~/.claude/plugins",
    "~/.claude/skills",
    "~/.mcp.json"
  ]

  @srt_codex_runtime_write_paths [
    "~/.codex"
  ]

  @srt_codex_runtime_deny_write_paths [
    "~/.codex/auth.json",
    "~/.codex/config.toml",
    "~/.codex/AGENTS.md"
  ]

  # Codex reads these before tool sandboxing applies. Shell/tool commands should
  # not be able to read them through the workspace_write permission profile.
  @codex_runtime_deny_read_paths [
    "~/.codex/auth.json",
    "~/.codex/config.toml",
    "~/.codex/AGENTS.md",
    "~/.codex/cloud-requirements-cache.json"
  ]

  @doc false
  @spec deny_read_paths() :: [String.t()]
  def deny_read_paths, do: @deny_read_paths

  @doc false
  @spec deny_write_paths() :: [String.t()]
  def deny_write_paths, do: @deny_write_paths

  @doc false
  @spec claude_filesystem_settings([String.t()], [String.t()]) :: map()
  def claude_filesystem_settings(allow_read_paths \\ [], allow_write_paths \\ []) do
    allow_read_paths = normalize_allow_read_paths(allow_read_paths)
    allow_write_paths = allow_write_paths |> normalize_allow_read_paths() |> expand_home_paths()

    base = %{
      "denyRead" => @deny_read_paths |> Enum.reject(&(&1 in allow_read_paths)) |> expand_home_paths(),
      "denyWrite" => expand_home_paths(@deny_write_paths)
    }

    case allow_write_paths do
      [] -> base
      paths -> Map.put(base, "allowWrite", paths)
    end
  end

  @doc """
  Writable paths a sandboxed macOS process needs for Foundation's atomic writes.

  Foundation sees the sandbox and stages every `Data.write(options: .atomic)` in
  the item replacement directory, `<DARWIN_USER_TEMP_DIR>/TemporaryItems`,
  whatever `TMPDIR` says. Without write access there, SwiftPM's build fails
  before compiling anything. Only `TemporaryItems` is granted: the per-user temp
  dir itself also holds Symphony's per-session Claude settings and MCP shim.

  Returns the path and its canonical form (`/var` is a symlink to `/private/var`),
  or `[]` off macOS or when `getconf` fails. Options: `:os_type` (default
  `:os.type()`) and `:getconf` (the `getconf` executable).
  """
  @spec item_replacement_write_paths(keyword()) :: [String.t()]
  def item_replacement_write_paths(opts) do
    case Keyword.get_lazy(opts, :os_type, &:os.type/0) do
      {:unix, :darwin} ->
        case System.cmd(Keyword.get(opts, :getconf, "getconf"), ["DARWIN_USER_TEMP_DIR"], stderr_to_stdout: true) do
          {user_temp_dir, 0} ->
            path = Path.join(String.trim(user_temp_dir), "TemporaryItems")
            [path | canonical_absolute_path_variants(path)]

          {_output, _status} ->
            []
        end

      _os_type ->
        []
    end
  end

  @doc false
  @spec codex_config_overrides(String.t(), [String.t()], [String.t()], [String.t()], keyword()) :: [String.t()]
  def codex_config_overrides(network_mode, allowed_domains, allow_read_paths \\ [], extra_deny_read_paths \\ [], opts \\ []) do
    [
      "tool_output_token_limit=#{@codex_tool_output_token_limit}",
      ~s(default_permissions="#{@codex_profile}"),
      "permissions.#{@codex_profile}.filesystem=#{codex_filesystem_policy(allow_read_paths, extra_deny_read_paths, opts)}",
      "permissions.#{@codex_profile}.network=#{codex_network_policy(network_mode)}",
      "permissions.#{@codex_profile}.network.domains=#{codex_network_domains(network_mode, allowed_domains)}"
    ]
  end

  @doc false
  @spec srt_settings(String.t(), [String.t()], [String.t()]) :: {:ok, map()} | {:error, term()}
  def srt_settings(network_mode, allowed_domains, denied_domains),
    do: srt_settings(network_mode, allowed_domains, denied_domains, [], [])

  @doc false
  @spec srt_settings(String.t(), [String.t()], [String.t()], [String.t()]) :: {:ok, map()} | {:error, term()}
  def srt_settings(network_mode, allowed_domains, denied_domains, allow_read_paths),
    do: srt_settings(network_mode, allowed_domains, denied_domains, allow_read_paths, [])

  @doc false
  @spec srt_settings(String.t(), [String.t()], [String.t()], [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def srt_settings("open", _allowed_domains, _denied_domains, _allow_read_paths, _opts),
    do: {:error, :srt_open_network_unsupported}

  def srt_settings(network_mode, allowed_domains, denied_domains, allow_read_paths, opts) do
    allow_read_paths = normalize_allow_read_paths(allow_read_paths)

    # `allowLocalBinding: true` permits bind/listen on 127.0.0.0/8 only.
    # Mix 1.19+ `Mix.Sync.PubSub` opens an ephemeral loopback socket on every
    # mix subcommand; outbound allowlist and credential deny-reads are unaffected.
    network =
      %{
        "allowedDomains" => srt_allowed_domains(network_mode, allowed_domains),
        "deniedDomains" => normalize_domains(denied_domains),
        "allowLocalBinding" => true
      }
      |> maybe_put_srt_allow_unix_sockets(Keyword.get(opts, :allow_unix_socket_paths, []))

    {:ok,
     %{
       "network" => network,
       "filesystem" => %{
         "denyRead" => @deny_read_paths |> Enum.reject(&(&1 in allow_read_paths)) |> expand_home_paths(),
         "allowRead" => allow_read_paths,
         "allowWrite" => srt_allow_write_paths(Keyword.get(opts, :allow_write_paths, [])),
         "denyWrite" => srt_deny_write_paths(Keyword.get(opts, :deny_write_paths, []))
       },
       "enableWeakerNestedSandbox" => true,
       "enableWeakerNetworkIsolation" => Keyword.get(opts, :enable_weaker_network_isolation, false)
     }}
  end

  defp codex_filesystem_policy(allow_read_paths, extra_deny_read_paths, opts) do
    allow_read_paths = normalize_allow_read_paths(allow_read_paths)
    extra_deny_read_paths = normalize_sandbox_paths(extra_deny_read_paths)
    operator_allow_read_paths = Enum.reject(allow_read_paths, &codex_runtime_read_override_path?/1)

    deny_read_paths =
      @deny_read_paths
      |> Enum.reject(fn path -> path in operator_allow_read_paths end)
      |> Kernel.++(@codex_runtime_deny_read_paths)
      |> Kernel.++(extra_deny_read_paths)
      |> expand_home_paths()

    deny_read_set = MapSet.new(deny_read_paths)

    # Paths that are read-denied already imply no write; emitting them again as
    # "read" here would create a duplicate TOML key whose later value silently
    # downgrades the protection to read-allowed.
    external_write_protect_entries =
      @deny_write_paths
      |> Enum.reject(&project_relative_sandbox_path?/1)
      |> expand_home_paths()
      |> Enum.reject(&MapSet.member?(deny_read_set, &1))
      |> Enum.map(&{&1, "read"})

    deny_read_paths
    |> Enum.map(&{&1, "none"})
    |> Kernel.++(codex_project_entries(Keyword.get(opts, :workspace)))
    |> Kernel.++(external_write_protect_entries)
    |> Kernel.++(Enum.map(operator_allow_read_paths, &{&1, "read"}))
    |> toml_inline_table()
  end

  defp codex_project_entries(workspace) when is_binary(workspace) do
    workspace = String.trim(workspace)

    if codex_workspace_path?(workspace) do
      [{workspace, "write"}] ++
        (@deny_write_paths
         |> Enum.filter(&project_relative_sandbox_path?/1)
         |> Enum.map(fn path ->
           {Path.join(workspace, String.trim_leading(path, "./")), "read"}
         end))
    else
      legacy_codex_project_entries()
    end
  end

  # Fallback for direct unit-level callers that do not have a resolved runtime
  # workspace. AppServer launch paths pass the validated workspace so current
  # Codex versions do not have to rely on this legacy special path.
  defp codex_project_entries(_workspace), do: legacy_codex_project_entries()

  defp codex_workspace_path?("/" <> _rest), do: true
  defp codex_workspace_path?("~/" <> _rest), do: true
  defp codex_workspace_path?(_workspace), do: false

  defp legacy_codex_project_entries do
    [
      {":project_roots",
       [{".", "write"}] ++
         (@deny_write_paths
          |> Enum.filter(&project_relative_sandbox_path?/1)
          |> Enum.map(fn path ->
            {String.trim_leading(path, "./"), "read"}
          end))}
    ]
  end

  defp project_relative_sandbox_path?(path) do
    not (String.starts_with?(path, "~/") or String.starts_with?(path, "/"))
  end

  defp codex_runtime_read_override_path?(path) do
    Enum.any?(@codex_runtime_deny_read_paths, fn denied_path ->
      path == denied_path or String.starts_with?(denied_path, path <> "/")
    end)
  end

  defp normalize_allow_read_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_allow_read_paths(_paths), do: []

  # Defense-in-depth: emit each home-relative deny entry in BOTH tilde form
  # and its `Path.expand`-resolved absolute form, so the deny list still
  # matches if a downstream sandbox layer ever compares against an already-
  # expanded path without re-expanding `~` itself. Non-tilde entries
  # (`./...`, `/...`) are left untouched.
  defp expand_home_paths(paths) do
    paths
    |> Enum.flat_map(fn
      "~/" <> _ = path -> [path, Path.expand(path)]
      other -> [other]
    end)
    |> Enum.uniq()
  end

  defp normalize_domains(domains) when is_list(domains) do
    domains
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_domains(_domains), do: []

  defp srt_allowed_domains("block", _allowed_domains), do: []
  defp srt_allowed_domains(_mode, allowed_domains), do: normalize_domains(allowed_domains)

  defp maybe_put_srt_allow_unix_sockets(network, paths) do
    case paths |> normalize_sandbox_paths() |> Enum.uniq() do
      [] -> network
      paths -> Map.put(network, "allowUnixSockets", paths)
    end
  end

  defp srt_allow_write_paths(extra_paths) do
    ([".", "/tmp", System.tmp_dir!()] ++ @srt_codex_runtime_write_paths ++ normalize_sandbox_paths(extra_paths))
    |> expand_home_paths()
    |> Enum.flat_map(&srt_allow_write_path_variants/1)
    |> Enum.uniq()
  end

  defp srt_allow_write_path_variants(path) do
    path = normalize_srt_allow_write_path(path)

    case path do
      "/" <> _rest -> [path | canonical_absolute_path_variants(path)]
      _path -> [path]
    end
  end

  defp normalize_srt_allow_write_path("."), do: "."
  defp normalize_srt_allow_write_path("./" <> _rest = path), do: path
  defp normalize_srt_allow_write_path("~/" <> _rest = path), do: path
  defp normalize_srt_allow_write_path("/" <> _rest = path), do: path
  defp normalize_srt_allow_write_path(path), do: "./#{path}"

  defp canonical_absolute_path_variants(path) do
    case SymphonyElixir.PathSafety.canonicalize(path) do
      {:ok, canonical_path} when canonical_path != path ->
        [canonical_path]

      {:ok, _canonical_path} ->
        []

      {:error, reason} ->
        Logger.warning("SRT allow-write path canonicalization failed; using original path only path=#{path} reason=#{inspect(reason)}")

        []
    end
  end

  defp srt_deny_write_paths(extra_paths),
    do:
      (@deny_write_paths ++ @srt_codex_runtime_deny_write_paths ++ normalize_sandbox_paths(extra_paths))
      |> expand_home_paths()

  defp normalize_sandbox_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_sandbox_paths(_paths), do: []

  defp codex_network_policy("open"), do: toml_inline_table(enabled: true, mode: "full")
  defp codex_network_policy("block"), do: toml_inline_table(enabled: false)
  defp codex_network_policy(_mode), do: toml_inline_table(enabled: true, mode: "limited")

  defp codex_network_domains("open", _allowed_domains), do: toml_inline_table([])

  defp codex_network_domains("block", _allowed_domains), do: toml_inline_table([])

  defp codex_network_domains(_mode, allowed_domains) do
    allowed_domains
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, "allow"})
    |> toml_inline_table()
  end

  defp toml_inline_table(entries) do
    entries
    |> Enum.map_join(",", fn {key, value} ->
      toml_string(to_string(key)) <> "=" <> toml_value(value)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp toml_value(value) when is_binary(value), do: toml_string(value)
  defp toml_value(value) when is_boolean(value), do: to_string(value)
  defp toml_value(value) when is_list(value), do: toml_inline_table(value)

  defp toml_string(value) when is_binary(value), do: Jason.encode!(value)
end
