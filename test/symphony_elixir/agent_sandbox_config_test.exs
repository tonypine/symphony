defmodule SymphonyElixir.AgentSandboxConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentSandboxConfig, PathSafety}
  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.Config.Schema.Workspace.Sandbox

  # Mirror of AgentSandboxConfig.expand_home_paths/1 for asserting against
  # the dual-form (tilde + Path.expand) deny lists emitted by sandbox settings.
  defp expand_home_paths(paths) do
    paths
    |> Enum.flat_map(fn
      "~/" <> _ = path -> [path, Path.expand(path)]
      other -> [other]
    end)
    |> Enum.uniq()
  end

  @persistence_deny_write_paths [
    "~/.zshrc",
    "~/.zshenv",
    "~/.zprofile",
    "~/.bashrc",
    "~/.bash_profile",
    "~/.profile",
    "~/.gitconfig",
    "~/Library/LaunchAgents",
    "~/Library/LaunchDaemons"
  ]

  test "Claude filesystem settings expose the default deny lists" do
    assert AgentSandboxConfig.deny_read_paths() == [
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

    refute "~/.codex" in AgentSandboxConfig.deny_read_paths()
    refute "~/.claude" in AgentSandboxConfig.deny_read_paths()

    assert AgentSandboxConfig.deny_write_paths() == [
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

    for path <- @persistence_deny_write_paths do
      assert path in AgentSandboxConfig.deny_write_paths()
    end

    assert "/Volumes" in AgentSandboxConfig.deny_read_paths()
    assert "~/Library/Keychains" in AgentSandboxConfig.deny_read_paths()
    assert "~/Library/Preferences" in AgentSandboxConfig.deny_read_paths()
    refute "~/.config/gh" in AgentSandboxConfig.deny_write_paths()

    assert AgentSandboxConfig.claude_filesystem_settings() == %{
             "denyRead" => expand_home_paths(AgentSandboxConfig.deny_read_paths()),
             "denyWrite" => expand_home_paths(AgentSandboxConfig.deny_write_paths())
           }
  end

  test "workspace protected paths are the repo-relative deny-write paths without .git" do
    assert AgentSandboxConfig.workspace_protected_paths() == [
             "WORKFLOW.md",
             "symphony.yml",
             "symphony.local.yml",
             ".claude/settings.json",
             ".claude/settings.local.json",
             ".claude/CLAUDE.md",
             ".claude/agents",
             ".claude/commands",
             ".claude/hooks",
             ".ai/skills",
             ".claude/skills",
             ".codex/skills",
             "mise.toml",
             ".tool-versions"
           ]
  end

  test "Claude filesystem settings deny writes to Claude Code persistence files (auto-loaded across sessions)" do
    settings = AgentSandboxConfig.claude_filesystem_settings()

    # User-scope: a poisoned ~/.claude/CLAUDE.md / agents / commands / hooks would be
    # silently re-loaded by every future Claude Code session on the host (cross-session,
    # cross-issue persistence). Both tilde and Path.expand forms are emitted as
    # defense-in-depth.
    for path <- [
          "~/.claude/CLAUDE.md",
          "~/.claude/settings.json",
          "~/.claude/settings.local.json",
          "~/.claude/agents",
          "~/.claude/commands",
          "~/.claude/hooks",
          "~/.claude/plugins",
          "~/.claude/skills",
          "~/.mcp.json"
        ] do
      assert path in settings["denyWrite"], "expected #{path} in claude denyWrite"
      assert Path.expand(path) in settings["denyWrite"], "expected expanded #{path} in claude denyWrite"
    end

    # Workspace-local: project-scoped Claude memory/agents/hooks would persist across
    # turns in the same worktree. Symmetric to the existing ./.claude/settings.json
    # protection.
    for path <- [
          "./.claude/settings.local.json",
          "./.claude/CLAUDE.md",
          "./.claude/agents",
          "./.claude/commands",
          "./.claude/hooks"
        ] do
      assert path in settings["denyWrite"], "expected #{path} in claude denyWrite"
    end
  end

  test "Claude filesystem settings deny reads of operator-authored Claude prompts" do
    settings = AgentSandboxConfig.claude_filesystem_settings()

    # Prevent prompt-injected agent from exfiltrating operator-authored memory /
    # subagent / command / hook definitions. Parent ~/.claude/ stays readable so
    # SDK directory listing still works (asserted elsewhere via refute).
    for path <- [
          "~/.claude/CLAUDE.md",
          "~/.claude/agents",
          "~/.claude/commands",
          "~/.claude/hooks"
        ] do
      assert path in settings["denyRead"], "expected #{path} in claude denyRead"
      assert Path.expand(path) in settings["denyRead"], "expected expanded #{path} in claude denyRead"
    end
  end

  test "Claude filesystem settings include both tilde and absolute forms of home-relative deny paths (defense-in-depth)" do
    settings = AgentSandboxConfig.claude_filesystem_settings()

    expected_ssh_absolute = Path.expand("~/.ssh")
    expected_zshrc_absolute = Path.expand("~/.zshrc")

    # Tilde forms remain (downstream tools that expand `~` continue to work).
    assert "~/.ssh" in settings["denyRead"]
    assert "~/.zshrc" in settings["denyWrite"]

    # Absolute forms also present so the deny list still matches if a downstream
    # path comparison is ever performed against an already-expanded absolute path
    # (regression guard against silent tilde-not-expanded failures).
    assert expected_ssh_absolute in settings["denyRead"]
    assert "~/.zshrc" in settings["denyRead"]
    assert expected_zshrc_absolute in settings["denyRead"]
    assert expected_zshrc_absolute in settings["denyWrite"]
  end

  test "Claude filesystem settings drop operator allow_read_paths from denyRead" do
    settings = AgentSandboxConfig.claude_filesystem_settings(["~/.npmrc", "~/.cargo/credentials", "~/.claude/projects"])

    refute "~/.npmrc" in settings["denyRead"]
    refute "~/.cargo/credentials" in settings["denyRead"]
    refute "~/.claude/projects" in settings["denyRead"]
    assert "~/.ssh" in settings["denyRead"]
    assert "~/.claude/.credentials.json" in settings["denyRead"]
    assert settings["denyWrite"] == expand_home_paths(AgentSandboxConfig.deny_write_paths())
  end

  test "Claude filesystem settings normalize malformed operator allow_read_paths" do
    settings = AgentSandboxConfig.claude_filesystem_settings(["", " ~/.npmrc ", "~/.npmrc", :bad])
    refute "~/.npmrc" in settings["denyRead"]

    defaults = AgentSandboxConfig.claude_filesystem_settings(:bad)
    assert "~/.npmrc" in defaults["denyRead"]
  end

  test "Claude filesystem settings emit allowWrite when operator allow_write_paths supplied" do
    settings = AgentSandboxConfig.claude_filesystem_settings([], ["/private/tmp/symphony-mcp", "/opt/cache"])

    assert settings["allowWrite"] == ["/private/tmp/symphony-mcp", "/opt/cache"]
    assert settings["denyWrite"] == expand_home_paths(AgentSandboxConfig.deny_write_paths())
  end

  test "Claude filesystem settings expand home-relative operator allow_write_paths" do
    settings =
      AgentSandboxConfig.claude_filesystem_settings([], [
        "~/symphony-cache",
        "./local-cache",
        "/opt/cache",
        "relative/cache"
      ])

    assert settings["allowWrite"] == [
             "~/symphony-cache",
             Path.expand("~/symphony-cache"),
             "./local-cache",
             "/opt/cache",
             "relative/cache"
           ]
  end

  test "Claude filesystem settings omit allowWrite when allow_write_paths empty" do
    settings = AgentSandboxConfig.claude_filesystem_settings()

    refute Map.has_key?(settings, "allowWrite")
  end

  test "Claude filesystem settings normalize malformed operator allow_write_paths" do
    settings = AgentSandboxConfig.claude_filesystem_settings([], ["", " /tmp/x ", "/tmp/x", :bad])

    assert settings["allowWrite"] == ["/tmp/x"]

    defaults = AgentSandboxConfig.claude_filesystem_settings([], :bad)
    refute Map.has_key?(defaults, "allowWrite")
  end

  describe "item_replacement_write_paths/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "agent-sandbox-item-replacement-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root}
    end

    test "grants the TemporaryItems dir under the macOS per-user temp dir, in both path forms", %{root: root} do
      real_temp_dir = Path.join(root, "private-T")
      linked_temp_dir = Path.join(root, "T")
      File.mkdir_p!(real_temp_dir)
      File.ln_s!(real_temp_dir, linked_temp_dir)
      getconf = fake_getconf!(root, "echo '#{linked_temp_dir}/'")

      {:ok, canonical_temp_dir} = PathSafety.canonicalize(real_temp_dir)

      assert AgentSandboxConfig.item_replacement_write_paths(os_type: {:unix, :darwin}, getconf: getconf) == [
               Path.join(linked_temp_dir, "TemporaryItems"),
               Path.join(canonical_temp_dir, "TemporaryItems")
             ]
    end

    test "grants nothing when getconf fails", %{root: root} do
      getconf = fake_getconf!(root, "echo 'getconf: no such configuration parameter' >&2; exit 1")

      assert AgentSandboxConfig.item_replacement_write_paths(os_type: {:unix, :darwin}, getconf: getconf) == []
    end

    test "grants nothing off macOS" do
      assert AgentSandboxConfig.item_replacement_write_paths(os_type: {:unix, :linux}) == []
    end
  end

  defp fake_getconf!(root, body) do
    path = Path.join(root, "getconf")
    File.write!(path, "#!/bin/sh\n[ \"$1\" = DARWIN_USER_TEMP_DIR ] || exit 2\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  test "Codex allowlist config denies sensitive reads and protects workflow files from writes" do
    workspace = "/repo/workspace"
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", ["github.com", "api.openai.com"], [], [], workspace: workspace)

    assert ~s(default_permissions="workspace_write") in overrides
    assert "tool_output_token_limit=4096" in overrides
    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    refute filesystem =~ ~s(":project_roots")
    assert filesystem =~ ~s("#{workspace}"="write")
    assert filesystem =~ ~s("#{Path.join(workspace, "WORKFLOW.md")}"="read")
    assert filesystem =~ ~s("#{Path.join(workspace, ".claude/settings.json")}"="read")
    assert filesystem =~ ~s("#{Path.join(workspace, ".git")}"="read")
    # An agent must not rewrite its own skills; `github_sync_base` merges the base branch's changes.
    assert filesystem =~ ~s("#{Path.join(workspace, ".ai/skills")}"="read")
    assert filesystem =~ ~s("#{Path.join(workspace, ".codex/skills")}"="read")
    assert filesystem =~ ~s("/Volumes"="none")
    assert filesystem =~ ~s("~/.ssh"="none")
    assert filesystem =~ ~s("~/.claude/.credentials.json"="none")
    assert filesystem =~ ~s("~/.claude/projects"="none")
    assert filesystem =~ ~s("~/.claude/file-history"="none")
    assert filesystem =~ ~s("~/.netrc"="none")
    assert filesystem =~ ~s("~/.npmrc"="none")
    assert filesystem =~ ~s("/etc/sudoers"="none")
    assert filesystem =~ ~s("/private/etc/sudoers"="none")
    assert filesystem =~ ~s("/var/root"="none")
    assert filesystem =~ ~s("~/Library/Application Support"="none")
    assert filesystem =~ ~s("~/Library/Keychains"="none")
    assert filesystem =~ ~s("~/Library/Preferences"="none")
    assert filesystem =~ ~s("~/.zshrc"="none")
    refute filesystem =~ ~s("~/.zshrc"="read")
    assert filesystem =~ ~s("~/Library/LaunchAgents"="read")
    assert filesystem =~ ~s("~/.codex/auth.json"="none")
    assert filesystem =~ ~s("~/.codex/config.toml"="none")
    assert filesystem =~ ~s("~/.codex/AGENTS.md"="none")
    assert filesystem =~ ~s("~/.codex/cloud-requirements-cache.json"="none")
    refute filesystem =~ "~/.codex/sessions"
    refute filesystem =~ ~s("~/.claude"=)

    assert ~s(permissions.workspace_write.network={"enabled"=true,"mode"="limited"}) in overrides
    assert domains = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.network.domains="))
    assert domains =~ ~s("api.openai.com"="allow")
    assert domains =~ ~s("github.com"="allow")
    refute domains =~ "evil.example.com"
  end

  test "Codex filesystem config emits read-denied paths once with `none`, not as duplicate `read` entries" do
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", [])
    filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))

    # Paths in BOTH @deny_read_paths and @deny_write_paths (e.g. ~/.claude/CLAUDE.md)
    # must serialise to `"path"="none"` only — never also `"path"="read"`, which would
    # be a duplicate TOML key whose later value silently downgrades the protection.
    for path <- [
          "~/.claude/CLAUDE.md",
          "~/.claude/agents",
          "~/.claude/commands",
          "~/.claude/hooks",
          Path.expand("~/.claude/CLAUDE.md"),
          Path.expand("~/.claude/agents")
        ] do
      assert filesystem =~ ~s("#{path}"="none"), "expected #{path} to be none-denied"
      refute filesystem =~ ~s("#{path}"="read"), "expected #{path} NOT to be re-emitted as read"
    end
  end

  test "Codex filesystem config read-denies generated CODEX_HOME auth and config paths" do
    codex_home = Path.join(System.tmp_dir!(), "symphony-codex-home-test")

    overrides =
      AgentSandboxConfig.codex_config_overrides("allowlist", [], [], [
        Path.join(codex_home, "auth.json"),
        Path.join(codex_home, "config.toml"),
        Path.join(codex_home, "cloud-requirements-cache.json")
      ])

    filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))

    assert filesystem =~ ~s("#{Path.join(codex_home, "auth.json")}"="none")
    assert filesystem =~ ~s("#{Path.join(codex_home, "config.toml")}"="none")
    assert filesystem =~ ~s("#{Path.join(codex_home, "cloud-requirements-cache.json")}"="none")
  end

  test "Codex allowlist config emits both tilde and absolute forms of home-relative deny paths (defense-in-depth)" do
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", [])
    filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))

    expected_ssh_absolute = Path.expand("~/.ssh")
    expected_zshrc_absolute = Path.expand("~/.zshrc")

    # Tilde forms still emitted for downstream tools that expand `~`.
    assert filesystem =~ ~s("~/.ssh"="none")
    assert filesystem =~ ~s("~/.zshrc"="none")

    # Absolute forms also emitted as defense-in-depth against any downstream
    # path comparison that does not re-expand `~`.
    assert filesystem =~ ~s("#{expected_ssh_absolute}"="none")
    assert filesystem =~ ~s("#{expected_zshrc_absolute}"="none")
  end

  test "Codex project-root filesystem entries use the runtime workspace for current CLI validation" do
    workspace = "/repo/workspace"
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", [], [], [], workspace: workspace)
    filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))

    refute filesystem =~ ~s(":project_roots")
    assert filesystem =~ ~s("#{workspace}"="write")
    assert filesystem =~ ~s("#{Path.join(workspace, "WORKFLOW.md")}"="read")
    assert filesystem =~ ~s("#{Path.join(workspace, ".git")}"="read")
    refute filesystem =~ ~s("#{Path.join(workspace, ".zshrc")}"="read")
    refute filesystem =~ ~s("#{Path.join(Path.dirname(workspace), "WORKFLOW.md")}"="read")
  end

  test "Codex project-root filesystem entries accept home-relative runtime workspaces" do
    workspace = "~/repo/workspace"
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", [], [], [], workspace: workspace)
    filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))

    refute filesystem =~ ~s(":project_roots")
    assert filesystem =~ ~s("#{workspace}"="write")
    assert filesystem =~ ~s("#{Path.join(workspace, "WORKFLOW.md")}"="read")
  end

  test "Codex project-root filesystem entries fall back for unresolved relative workspaces" do
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", [], [], [], workspace: "relative/workspace")
    filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))

    assert filesystem =~ ~s(":project_roots"={)
    assert filesystem =~ ~s("."="write")
    assert filesystem =~ ~s("WORKFLOW.md"="read")
  end

  test "Codex open mode keeps full network mode without domain narrowing" do
    overrides = AgentSandboxConfig.codex_config_overrides("open", ["github.com"])

    assert ~s(permissions.workspace_write.network={"enabled"=true,"mode"="full"}) in overrides
    assert "permissions.workspace_write.network.domains={}" in overrides
  end

  test "Codex block mode disables network outright instead of relying on empty domains" do
    overrides = AgentSandboxConfig.codex_config_overrides("block", ["github.com"])

    assert ~s(permissions.workspace_write.network={"enabled"=false}) in overrides
    assert "permissions.workspace_write.network.domains={}" in overrides
  end

  test "srt settings render network and filesystem guardrails" do
    assert {:ok, settings} =
             AgentSandboxConfig.srt_settings(
               "allowlist",
               ["GitHub.com", "api.openai.com", "github.com"],
               [" API.GitHub.com "],
               ["~/.npmrc"]
             )

    assert settings["network"] == %{
             "allowedDomains" => ["github.com", "api.openai.com"],
             "deniedDomains" => ["api.github.com"],
             "allowLocalBinding" => true
           }

    assert settings["filesystem"]["allowRead"] == ["~/.npmrc"]
    assert "." in settings["filesystem"]["allowWrite"]
    assert System.tmp_dir!() in settings["filesystem"]["allowWrite"]
    assert "~/.codex" in settings["filesystem"]["allowWrite"]
    assert "/Volumes" in settings["filesystem"]["denyRead"]
    refute "~/.npmrc" in settings["filesystem"]["denyRead"]
    assert "~/.ssh" in settings["filesystem"]["denyRead"]
    assert "~/.claude/.credentials.json" in settings["filesystem"]["denyRead"]
    assert "~/.claude/projects" in settings["filesystem"]["denyRead"]
    assert "~/.claude/file-history" in settings["filesystem"]["denyRead"]
    assert "~/.zshrc" in settings["filesystem"]["denyRead"]
    assert "~/.bash_profile" in settings["filesystem"]["denyRead"]
    assert "/private/etc/sudoers" in settings["filesystem"]["denyRead"]
    assert "/var/root" in settings["filesystem"]["denyRead"]
    refute "~/.codex/auth.json" in settings["filesystem"]["denyRead"]
    refute "~/.codex/config.toml" in settings["filesystem"]["denyRead"]
    refute "~/.codex/AGENTS.md" in settings["filesystem"]["denyRead"]
    assert "./WORKFLOW.md" in settings["filesystem"]["denyWrite"]
    assert "./.git" in settings["filesystem"]["denyWrite"]
    refute "/Volumes" in settings["filesystem"]["denyWrite"]

    for path <- @persistence_deny_write_paths do
      assert path in settings["filesystem"]["denyWrite"]
    end

    assert "~/.codex/auth.json" in settings["filesystem"]["denyWrite"]
    assert "~/.codex/config.toml" in settings["filesystem"]["denyWrite"]
    assert "~/.codex/AGENTS.md" in settings["filesystem"]["denyWrite"]
    refute "~/.codex/skills" in settings["filesystem"]["denyWrite"]
    assert settings["enableWeakerNestedSandbox"] == true
    assert settings["enableWeakerNetworkIsolation"] == false
  end

  test "srt settings include canonical equivalents for absolute write roots" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-srt-canonical-write-root-#{System.unique_integer([:positive])}"
      )

    target = Path.join(test_root, "target")
    link = Path.join(test_root, "link")

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(target)
    :ok = File.ln_s(target, link)

    assert {:ok, canonical_tmp_dir} = PathSafety.canonicalize(System.tmp_dir!())
    assert {:ok, canonical_link} = PathSafety.canonicalize(link)

    assert {:ok, settings} =
             AgentSandboxConfig.srt_settings(
               "allowlist",
               [],
               [],
               [],
               allow_write_paths: [link]
             )

    allow_write = settings["filesystem"]["allowWrite"]

    assert System.tmp_dir!() in allow_write
    assert canonical_tmp_dir in allow_write
    assert link in allow_write
    assert canonical_link in allow_write
  end

  test "srt settings expand home-relative operator allow_write_paths" do
    assert {:ok, settings} =
             AgentSandboxConfig.srt_settings(
               "allowlist",
               [],
               [],
               [],
               allow_write_paths: [
                 "~/symphony-cache",
                 "./local-cache",
                 "/opt/cache",
                 "relative/cache"
               ]
             )

    allow_write = settings["filesystem"]["allowWrite"]

    assert "~/symphony-cache" in allow_write
    assert Path.expand("~/symphony-cache") in allow_write
    assert "./local-cache" in allow_write
    assert "/opt/cache" in allow_write
    assert "./relative/cache" in allow_write
  end

  test "srt settings keep absolute write roots when canonicalization fails" do
    # Force a non-:enoent lstat error by traversing through a regular file as
    # if it were a directory (yields :enotdir on every POSIX kernel). A simply
    # non-existent path won't do: canonicalize treats :enoent as a successful
    # match and returns {:ok, path}.
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-srt-canonicalize-fail-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(test_root)
    blocker = Path.join(test_root, "blocker")
    File.touch!(blocker)
    missing_path = Path.join(blocker, "child")

    assert {:error, _reason} = PathSafety.canonicalize(missing_path)

    assert {:ok, settings} =
             AgentSandboxConfig.srt_settings(
               "allowlist",
               [],
               [],
               [],
               allow_write_paths: [missing_path]
             )

    assert missing_path in settings["filesystem"]["allowWrite"]
  end

  test "srt settings never opt into extra mach services, so the window server stays unreachable" do
    assert {:ok, settings} =
             AgentSandboxConfig.srt_settings("allowlist", ["github.com"], [], ["~/.npmrc"],
               allow_unix_socket_paths: ["/tmp/symphony-mcp/sock"],
               allow_write_paths: ["/opt/cache"]
             )

    refute Map.has_key?(settings["network"], "allowMachLookup")
    refute Map.has_key?(settings, "allowMachLookup")
  end

  test "srt settings emit both tilde and absolute forms of home-relative deny paths (defense-in-depth)" do
    assert {:ok, settings} = AgentSandboxConfig.srt_settings("allowlist", ["github.com"], [])

    expected_ssh_absolute = Path.expand("~/.ssh")
    expected_zshrc_absolute = Path.expand("~/.zshrc")

    # Tilde forms still emitted.
    assert "~/.ssh" in settings["filesystem"]["denyRead"]
    assert "~/.zshrc" in settings["filesystem"]["denyRead"]
    assert "~/.zshrc" in settings["filesystem"]["denyWrite"]

    # Absolute forms also emitted as defense-in-depth.
    assert expected_ssh_absolute in settings["filesystem"]["denyRead"]
    assert expected_zshrc_absolute in settings["filesystem"]["denyRead"]
    assert expected_zshrc_absolute in settings["filesystem"]["denyWrite"]
  end

  test "srt settings accept extra read and write paths for runtime-managed roots" do
    assert {:ok, settings} =
             AgentSandboxConfig.srt_settings(
               "allowlist",
               [],
               [],
               ["~/.ssh/known_hosts"],
               allow_write_paths: ["/repo/.git/worktrees/MT-1", "relative/git"],
               deny_write_paths: ["/repo/.git/hooks"],
               allow_unix_socket_paths: ["/tmp/symphony-mcp-session", " /tmp/symphony-mcp-session ", ""]
             )

    assert settings["network"]["allowUnixSockets"] == ["/tmp/symphony-mcp-session"]
    assert "~/.ssh" in settings["filesystem"]["denyRead"]
    assert "~/.ssh/known_hosts" in settings["filesystem"]["allowRead"]
    assert "/repo/.git/worktrees/MT-1" in settings["filesystem"]["allowWrite"]
    assert "./relative/git" in settings["filesystem"]["allowWrite"]
    assert "/repo/.git/hooks" in settings["filesystem"]["denyWrite"]
  end

  test "srt settings normalize malformed domain and sandbox path inputs" do
    assert {:ok, settings} =
             AgentSandboxConfig.srt_settings(
               "allowlist",
               :bad_allowed_domains,
               :bad_denied_domains,
               :bad_allow_read_paths,
               allow_write_paths: :bad_allow_write_paths,
               deny_write_paths: :bad_deny_write_paths
             )

    assert settings["network"]["allowedDomains"] == []
    assert settings["network"]["deniedDomains"] == []
    assert settings["filesystem"]["allowRead"] == []
    assert "." in settings["filesystem"]["allowWrite"]
    assert "~/.codex" in settings["filesystem"]["allowWrite"]

    assert settings["filesystem"]["denyWrite"] ==
             expand_home_paths(
               AgentSandboxConfig.deny_write_paths() ++
                 ["~/.codex/auth.json", "~/.codex/config.toml", "~/.codex/AGENTS.md"]
             )
  end

  test "srt settings map open and block network modes" do
    assert {:error, :srt_open_network_unsupported} = AgentSandboxConfig.srt_settings("open", ["github.com"], [])
    assert {:ok, %{"network" => %{"allowedDomains" => []}}} = AgentSandboxConfig.srt_settings("block", ["github.com"], [])
  end

  test "srt settings normalize malformed domains and relative temp dirs" do
    relative_tmp = "symphony-relative-tmp-#{System.unique_integer([:positive])}"
    previous_tmpdir = System.get_env("TMPDIR")

    on_exit(fn ->
      restore_env("TMPDIR", previous_tmpdir)
      File.rm_rf(relative_tmp)
    end)

    File.mkdir_p!(relative_tmp)
    System.put_env("TMPDIR", relative_tmp)

    assert {:ok, settings} = AgentSandboxConfig.srt_settings("allowlist", :bad, :bad)
    assert settings["network"]["allowedDomains"] == []
    assert settings["network"]["deniedDomains"] == []
    assert "./#{relative_tmp}" in settings["filesystem"]["allowWrite"]
  end

  test "Codex filesystem config allows operator overrides for default read denies" do
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", [], ["~/.npmrc", "~/.cargo/credentials", "~/.claude/projects"])

    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s("~/.npmrc"="read")
    assert filesystem =~ ~s("~/.cargo/credentials"="read")
    assert filesystem =~ ~s("~/.claude/projects"="read")
    refute filesystem =~ ~s("~/.npmrc"="none")
    refute filesystem =~ ~s("~/.cargo/credentials"="none")
    refute filesystem =~ ~s("~/.claude/projects"="none")
  end

  test "Codex filesystem config does not allow operator overrides for runtime auth reads" do
    overrides =
      AgentSandboxConfig.codex_config_overrides("allowlist", [], [
        "~/.codex",
        "~/.codex/auth.json",
        "~/.codex/config.toml",
        "~/.codex/AGENTS.md",
        "~/.codex/cloud-requirements-cache.json"
      ])

    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s("~/.codex/auth.json"="none")
    assert filesystem =~ ~s("~/.codex/config.toml"="none")
    assert filesystem =~ ~s("~/.codex/AGENTS.md"="none")
    assert filesystem =~ ~s("~/.codex/cloud-requirements-cache.json"="none")
    refute filesystem =~ ~s("~/.codex"="read")
    refute filesystem =~ ~s("~/.codex/auth.json"="read")
    refute filesystem =~ ~s("~/.codex/config.toml"="read")
    refute filesystem =~ ~s("~/.codex/AGENTS.md"="read")
    refute filesystem =~ ~s("~/.codex/cloud-requirements-cache.json"="read")
  end

  test "Codex filesystem config normalizes malformed operator allow_read_paths" do
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", [], ["", " ~/.npmrc ", "~/.npmrc", :bad])

    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s("~/.npmrc"="read")
    refute filesystem =~ ~s("~/.npmrc"="none")

    defaults = AgentSandboxConfig.codex_config_overrides("allowlist", [], :bad)
    assert default_filesystem = Enum.find(defaults, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert default_filesystem =~ ~s("~/.npmrc"="none")
  end

  test "operator workspace sandbox allow_read_paths flows into rendered Codex deny list" do
    assert {:ok, system_config} =
             SystemSchema.parse(%{
               "repositories" => [%{"key" => "default"}],
               "agent" => %{
                 "runtime" => "codex",
                 "command" => "codex app-server",
                 "permissions" => %{
                   "filesystem" => %{
                     "allow_read_paths" => ["~/.npmrc", "~/.claude/projects"]
                   }
                 }
               }
             })

    assert {:ok, settings} = system_config |> SystemSchema.to_config_map() |> Schema.parse()
    assert settings.workspace.sandbox.allow_read_paths == ["~/.npmrc", "~/.claude/projects"]

    overrides =
      AgentSandboxConfig.codex_config_overrides(
        settings.agent.network_access.mode,
        Schema.codex_effective_network_allowed_domains(settings),
        settings.workspace.sandbox.allow_read_paths
      )

    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s("~/.npmrc"="read")
    assert filesystem =~ ~s("~/.claude/projects"="read")
    refute filesystem =~ ~s("~/.npmrc"="none")
    refute filesystem =~ ~s("~/.claude/projects"="none")
    assert filesystem =~ ~s("~/.netrc"="none")
    assert filesystem =~ ~s("~/.claude/.credentials.json"="none")

    claude_settings = AgentSandboxConfig.claude_filesystem_settings(settings.workspace.sandbox.allow_read_paths)
    refute "~/.npmrc" in claude_settings["denyRead"]
    refute "~/.claude/projects" in claude_settings["denyRead"]
    assert "~/.netrc" in claude_settings["denyRead"]
    assert "~/.claude/.credentials.json" in claude_settings["denyRead"]
  end

  test "workspace sandbox allow_read_paths defaults to an empty list" do
    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(%{allow_read_paths: nil})
      |> Ecto.Changeset.apply_changes()

    assert sandbox.allow_read_paths == []
  end

  test "operator workspace sandbox allow_write_paths flows into rendered Claude allowWrite" do
    assert {:ok, system_config} =
             SystemSchema.parse(%{
               "repositories" => [%{"key" => "default"}],
               "agent" => %{
                 "runtime" => "claude",
                 "command" => "claude --dangerously-skip-permissions",
                 "permissions" => %{
                   "filesystem" => %{
                     "allow_write_paths" => ["/private/tmp/symphony-mcp", " /opt/cache "]
                   }
                 }
               }
             })

    assert {:ok, settings} = system_config |> SystemSchema.to_config_map() |> Schema.parse()
    assert settings.workspace.sandbox.allow_write_paths == ["/private/tmp/symphony-mcp", "/opt/cache"]

    claude_settings =
      AgentSandboxConfig.claude_filesystem_settings(
        settings.workspace.sandbox.allow_read_paths,
        settings.workspace.sandbox.allow_write_paths
      )

    assert claude_settings["allowWrite"] == ["/private/tmp/symphony-mcp", "/opt/cache"]
  end

  test "workspace sandbox allow_write_paths defaults to an empty list" do
    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(%{allow_write_paths: nil})
      |> Ecto.Changeset.apply_changes()

    assert sandbox.allow_write_paths == []
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
