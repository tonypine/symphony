defmodule SymphonyElixir.AgentSandboxConfig do
  require Logger

  @moduledoc """
  Shared sandbox defaults for agent runtimes.

  Produces Claude Code `sandbox.filesystem` settings, Claude Code `Edit(<path>)`
  deny rules for its file tools, and Codex `permissions.workspace_write.*`
  `--config` overrides from a single deny list so both adapters stay in sync. Operator-supplied
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
    * project-local skills `.ai/skills`, `.claude/skills`, `.codex/skills` (an agent must not
      rewrite its own instructions; `github_sync_base` merges the base branch's changes to them),
      and for a local workspace the files a symlink in a protected path points at
      (`workspace_link_targets/1`)
    * shell startup files, `~/.gitconfig`, and macOS launch agent roots
    * in each git dir the agent may write (the shared repo's common dir for a worktree), the
      files that change what git runs: `config`, `config.worktree`, `hooks`, `info`,
      `packed-refs`, every worktree's `config(.worktree)` and every submodule's `config`
      (`git_metadata_deny_write_paths/1`)
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
    "./.ai/skills",
    "./.claude/skills",
    "./.codex/skills",
    "./.git",
    "./mise.toml",
    "./.tool-versions",
    # Only a person exempts a symphony.yml setting from having a control in the macOS app.
    "./config/settings_ui_exempt.yml",
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

  # Relative to a git dir. The agent writes objects and refs there to commit, but these change
  # what git runs, the agent's and Symphony's host-side git alike: config (filter drivers,
  # `core.fsmonitor`, `core.hooksPath`), hooks and `info/attributes`.
  @git_metadata_deny_write_entries [
    "config",
    "config.worktree",
    "hooks",
    "info",
    "packed-refs",
    "worktrees/*/config",
    "worktrees/*/config.worktree",
    "modules/**/config"
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
  @spec codex_runtime_deny_read_paths() :: [String.t()]
  def codex_runtime_deny_read_paths, do: @codex_runtime_deny_read_paths

  @doc false
  @spec deny_write_paths() :: [String.t()]
  def deny_write_paths, do: @deny_write_paths

  @doc """
  The write-protected paths inside a workspace, relative to its root, without `.git`.
  """
  @spec workspace_protected_paths() :: [String.t()]
  def workspace_protected_paths do
    for "./" <> path <- @deny_write_paths, path != ".git", do: path
  end

  @doc """
  Workspace paths that a symlink inside a write-protected path points at, relative to the
  workspace root: `priv/skills/pull` for `.ai/skills/pull -> ../../priv/skills/pull`.

  Sandboxes match real paths, so denying `.ai/skills` leaves a linked skill's own files writable.
  Reads the links on disk; returns `[]` when the workspace has none.
  """
  @spec workspace_link_targets(Path.t()) :: [String.t()]
  def workspace_link_targets(workspace) do
    list_links = fn paths -> {:ok, Enum.flat_map(paths, &disk_links(workspace, &1))} end
    {:ok, targets} = link_targets(workspace_protected_paths(), list_links)
    targets
  end

  @doc """
  Follows the symlinks `list_links` finds under `paths`, then under each target in turn, and
  returns the targets. `list_links` returns `{link, target}` pairs, paths relative to the
  workspace root. Targets outside the workspace, the workspace root itself and `.git` are left
  out.
  """
  @spec link_targets([String.t()], ([String.t()] -> {:ok, [{String.t(), String.t()}]} | {:error, term()})) ::
          {:ok, [String.t()]} | {:error, term()}
  def link_targets(paths, list_links), do: follow_links(paths, list_links, MapSet.new(paths), [])

  defp follow_links([], _list_links, _seen, targets), do: {:ok, Enum.reverse(targets)}

  defp follow_links(paths, list_links, seen, targets) do
    with {:ok, links} <- list_links.(paths) do
      new =
        links
        |> Enum.flat_map(fn {link, target} -> resolve_link(link, target) end)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(seen, &1))

      follow_links(new, list_links, MapSet.union(seen, MapSet.new(new)), Enum.reverse(new, targets))
    end
  end

  defp resolve_link(_link, "/" <> _absolute), do: []

  defp resolve_link(link, target) do
    segments = String.split(Path.dirname(link), "/") ++ String.split(target, "/")

    case Enum.reduce_while(segments, [], &resolve_segment/2) do
      :outside -> []
      reversed -> reversed |> Enum.reverse() |> workspace_link_target()
    end
  end

  defp workspace_link_target([]), do: []
  defp workspace_link_target([".git" | _rest]), do: []
  defp workspace_link_target(segments), do: [Path.join(segments)]

  defp resolve_segment(segment, acc) when segment in [".", ""], do: {:cont, acc}
  defp resolve_segment("..", []), do: {:halt, :outside}
  defp resolve_segment("..", [_parent | acc]), do: {:cont, acc}
  defp resolve_segment(segment, acc), do: {:cont, [segment | acc]}

  defp disk_links(workspace, path) do
    full_path = Path.join(workspace, path)

    case File.read_link(full_path) do
      {:ok, target} ->
        [{path, target}]

      {:error, _not_a_link} ->
        case File.ls(full_path) do
          {:ok, entries} -> Enum.flat_map(entries, &disk_links(workspace, Path.join(path, &1)))
          {:error, _not_a_directory} -> []
        end
    end
  end

  @doc """
  The write-protected git metadata under each git dir in `git_dirs`, such as the git dir and
  the shared common dir of a linked worktree. Paths without a `.git` segment are skipped.

  Some entries are globs (`worktrees/*/config`, `modules/**/config`), which the Claude Code and
  SRT sandboxes match; `literal_paths/1` expands them for a runtime that takes literal paths.
  """
  @spec git_metadata_deny_write_paths([Path.t()]) :: [Path.t()]
  def git_metadata_deny_write_paths(git_dirs) do
    for git_dir <- git_dirs,
        is_binary(git_dir),
        ".git" in Path.split(git_dir),
        entry <- @git_metadata_deny_write_entries,
        uniq: true,
        do: Path.join(git_dir, entry)
  end

  @doc """
  Replaces each glob in `paths` with the files on disk it matches now, and keeps the others.
  """
  @spec literal_paths([Path.t()]) :: [Path.t()]
  def literal_paths(paths) do
    Enum.flat_map(paths, fn path ->
      if String.contains?(path, "*"), do: Path.wildcard(path, match_dot: true), else: [path]
    end)
  end

  @doc false
  @spec claude_filesystem_settings([String.t()], [String.t()], [String.t()]) :: map()
  def claude_filesystem_settings(allow_read_paths \\ [], allow_write_paths \\ [], extra_deny_write_paths \\ []) do
    allow_read_paths = normalize_allow_read_paths(allow_read_paths)
    allow_write_paths = allow_write_paths |> normalize_allow_read_paths() |> expand_home_paths()

    base = %{
      "denyRead" => @deny_read_paths |> Enum.reject(&(&1 in allow_read_paths)) |> expand_home_paths(),
      "denyWrite" => expand_home_paths(@deny_write_paths ++ normalize_sandbox_paths(extra_deny_write_paths))
    }

    case allow_write_paths do
      [] -> base
      paths -> Map.put(base, "allowWrite", paths)
    end
  end

  @doc """
  Claude Code `permissions.deny` rules that refuse its file tools on every write-protected path.

  `sandbox.filesystem.denyWrite` binds shell commands only; `Edit`, `Write` and `NotebookEdit`
  run in the Claude process. Claude Code applies an `Edit(<path>)` rule to all three and
  ignores a `Write(<path>)` or `NotebookEdit(<path>)` rule (checked with Claude Code 2.1.289).
  A directory rule covers the files under it. Claude matches a symlink's real path, so the
  link targets in `extra_deny_write_paths` need their own rules. `./` is relative to the
  session's working directory and `~/` to the home directory; an absolute path needs `//`.
  """
  @spec claude_edit_deny_rules([String.t()]) :: [String.t()]
  def claude_edit_deny_rules(extra_deny_write_paths \\ []) do
    (@deny_write_paths ++ normalize_sandbox_paths(extra_deny_write_paths))
    |> Enum.uniq()
    |> Enum.map(&"Edit(#{claude_rule_path(&1)})")
  end

  defp claude_rule_path("/" <> _absolute = path), do: "/" <> path
  defp claude_rule_path(path), do: path

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
      (@deny_write_paths ++ normalize_sandbox_paths(Keyword.get(opts, :deny_write_paths, [])))
      |> Enum.reject(&project_relative_sandbox_path?/1)
      |> expand_home_paths()
      |> Enum.reject(&MapSet.member?(deny_read_set, &1))
      |> Enum.uniq()
      |> Enum.map(&{&1, "read"})

    deny_read_paths
    |> Enum.map(&{&1, "none"})
    |> Kernel.++(codex_project_entries(Keyword.get(opts, :workspace), Keyword.get(opts, :deny_write_paths, [])))
    |> Kernel.++(external_write_protect_entries)
    |> Kernel.++(Enum.map(operator_allow_read_paths, &{&1, "read"}))
    |> toml_inline_table()
  end

  defp codex_project_entries(workspace, extra_deny_write_paths) when is_binary(workspace) do
    workspace = String.trim(workspace)

    if codex_workspace_path?(workspace) do
      [{workspace, "write"}] ++
        ((@deny_write_paths ++ normalize_sandbox_paths(extra_deny_write_paths))
         |> Enum.filter(&project_relative_sandbox_path?/1)
         |> Enum.map(fn path ->
           {Path.join(workspace, String.trim_leading(path, "./")), "read"}
         end)
         |> Enum.uniq())
    else
      legacy_codex_project_entries()
    end
  end

  # Fallback for direct unit-level callers that do not have a resolved runtime
  # workspace. AppServer launch paths pass the validated workspace so current
  # Codex versions do not have to rely on this legacy special path.
  defp codex_project_entries(_workspace, _extra_deny_write_paths), do: legacy_codex_project_entries()

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
