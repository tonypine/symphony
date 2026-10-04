defmodule SymphonyElixir.ManagedCloneTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AgentSandboxConfig, Config, ManagedClone, Paths, Workflow, WorkflowSource, Workspace}
  alias SymphonyElixir.Config.{Cache, Schema, SystemSchema}
  alias SymphonyElixir.Repo.FetchLog

  @git_env [
    {"GIT_AUTHOR_NAME", "Symphony Test"},
    {"GIT_AUTHOR_EMAIL", "symphony@example.com"},
    {"GIT_COMMITTER_NAME", "Symphony Test"},
    {"GIT_COMMITTER_EMAIL", "symphony@example.com"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"}
  ]

  setup do
    original_env =
      Map.new(
        [:symphony_file_path, :state_root_override, :config_cache_watch, :workflow_file_path, :managed_clone_url_base],
        &{&1, Application.get_env(:symphony_elixir, &1)}
      )

    root = Path.join(System.tmp_dir!(), "symphony-managed-clone-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Paths.set_state_root(Path.join(root, "state"))
    Application.put_env(:symphony_elixir, :config_cache_watch, false)
    Application.put_env(:symphony_elixir, :managed_clone_url_base, Path.join(root, "remotes") <> "/")
    Cache.clear()

    on_exit(fn ->
      Cache.clear()

      Enum.each(original_env, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)

      File.rm_rf(root)
    end)

    {:ok, root: root, clones_root: Path.join(root, "clones")}
  end

  describe "config" do
    test "a GitHub source points the repo at Symphony's clone", %{clones_root: clones_root} do
      assert {:ok, %SystemSchema{repos: [repo]}} =
               parse(%{"workspace" => %{"source" => "Acme/Web"}}, %{"clones_root" => clones_root})

      clone = Path.join(clones_root, "acme/web")
      assert repo.path == clone
      assert %{github: "Acme/Web", repo: ^clone, strategy: "worktree"} = repo.workspace
      assert SystemSchema.repo_workflow_path(repo) == Path.join(clone, "WORKFLOW.md")
    end

    test "reads owner/repo from a github.com URL" do
      for url <- [
            "https://github.com/acme/web",
            "https://github.com/acme/web.git",
            "https://www.github.com/acme/web/",
            "git@github.com:acme/web.git",
            "ssh://git@github.com/acme/web.git",
            " acme/web "
          ] do
        assert {:ok, %SystemSchema{repos: [%{workspace: %{github: "acme/web"}}]}} = parse(%{"workspace" => %{"source" => url}})
      end
    end

    test "the clones root defaults to a folder outside the sandbox deny lists" do
      assert {:ok, %SystemSchema{repos: [repo]}} = parse(%{"workspace" => %{"source" => "acme/web"}})

      assert ManagedClone.default_root() == Path.expand("~/.local/share/symphony/repos")
      assert repo.workspace.repo == Path.join(ManagedClone.default_root(), "acme/web")
      assert ManagedClone.clone_url("acme/web") =~ "acme/web.git"

      denied =
        (AgentSandboxConfig.deny_read_paths() ++ AgentSandboxConfig.deny_write_paths())
        |> Enum.reject(&String.starts_with?(&1, "./"))
        |> Enum.map(&Path.expand/1)

      for denied_path <- denied do
        refute repo.workspace.repo == denied_path or String.starts_with?(repo.workspace.repo, denied_path <> "/"),
               "#{repo.workspace.repo} is under the denied path #{denied_path}"
      end
    end

    test "clones over SSH by default" do
      Application.delete_env(:symphony_elixir, :managed_clone_url_base)
      assert ManagedClone.clone_url("acme/web") == "git@github.com:acme/web.git"
    end

    test "rejects a source that is not a GitHub repository" do
      for source <- [
            "acme",
            "acme/web/extra",
            "-acme/web",
            "acme/web.git",
            "acme/..",
            "acme/web name",
            "https://gitlab.com/acme/web",
            "https://github.com/acme/web/tree/main",
            "git@github.com:acme",
            "",
            42,
            nil,
            %{"github" => "acme/web"}
          ] do
        assert {:error, {:invalid_symphony_config, message}} = parse(%{"workspace" => %{"source" => source}})

        assert message =~
                 "`repositories[web].workspace.source` must be a GitHub repository, as `owner/repo` or a github.com URL"
      end

      assert {:error, {:invalid_symphony_config, "unknown symphony.yml key `workspaces.source`"}} =
               parse(%{}, %{"source" => "acme/web"})
    end

    test "rejects a source together with local checkout settings" do
      source = %{"source" => "acme/web"}

      assert {:error, {:invalid_symphony_config, message}} = parse(%{"workspace" => Map.put(source, "repo", "~/code/web")})
      assert message =~ "`repositories[web].workspace.source` and `repositories[web].workspace.repo` cannot both be set"

      assert {:error, {:invalid_symphony_config, message}} = parse(%{"workspace" => Map.put(source, "strategy", "clone")})
      assert message =~ "`repositories[web].workspace.source` needs `strategy: worktree`"

      assert {:ok, _config} = parse(%{"workspace" => Map.put(source, "strategy", "worktree")})

      assert {:error, {:invalid_symphony_config, message}} = parse(%{"workspace" => source, "workflow_source" => "local"})
      assert message =~ "`repositories[web].workflow_source: local` cannot be used with `repositories[web].workspace.source`"

      for workflow <- ["/abs/WORKFLOW.md", "../WORKFLOW.md", "~/WORKFLOW.md"] do
        assert {:error, {:invalid_symphony_config, message}} = parse(%{"workspace" => source, "workflow" => workflow})
        assert message =~ "`repositories[web].workflow` must be a path inside the repository"
      end

      assert {:ok, %SystemSchema{repos: [repo]}} = parse(%{"workspace" => source, "workflow" => "docs/WORKFLOW.md"})
      assert SystemSchema.repo_workflow_path(repo) == Path.join(repo.path, "docs/WORKFLOW.md")

      assert {:error, {:invalid_symphony_config, message}} = parse(%{"workspace" => source, "workflow" => 42})
      assert message =~ "workflow"
    end

    test "names the repo by index when it has no key" do
      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{"repositories" => [%{"workspace" => %{"source" => "acme"}}]})

      assert message =~ "`repositories[0].workspace.source`"
    end

    test "rejects a source with SSH workers" do
      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{
                 "repositories" => [%{"key" => "web", "workspace" => %{"source" => "acme/web"}}],
                 "workers" => %{"ssh_hosts" => ["worker-1"]}
               })

      assert message =~ "`workers.ssh_hosts` cannot be used with repositories that set `workspace.source` (web)"

      assert {:ok, _config} =
               SystemSchema.parse(%{
                 "repositories" => [%{"key" => "web", "workspace" => %{"source" => "acme/web"}}],
                 "workers" => %{"ssh_hosts" => []}
               })
    end
  end

  describe "sync/4" do
    setup %{root: root, clones_root: clones_root} do
      remote = remote!(root, "acme/web", "First prompt")
      {:ok, remote: remote, clone: Path.join(clones_root, "acme/web")}
    end

    test "clones on first use, then fetches", %{root: root, remote: remote, clone: clone} do
      assert ManagedClone.sync("web", "acme/web", clone) == :ok
      assert File.dir?(Path.join(clone, ".git"))
      refute File.exists?(Path.join(clone, "WORKFLOW.md"))
      first = rev!(clone, "origin/main")

      second = push!(root, remote, "Second prompt")

      assert ManagedClone.sync("web", "acme/web", clone, fetch: false) == :ok
      assert rev!(clone, "origin/main") == first

      assert ManagedClone.sync("web", "acme/web", clone) == :ok
      assert rev!(clone, "origin/main") == second
    end

    test "a failed clone leaves nothing behind", %{clone: clone} do
      log =
        capture_log(fn ->
          assert {:error, {:managed_clone_failed, "web", {:clone, {:git_failed, _status, _output}}}} =
                   ManagedClone.sync("web", "acme/missing", clone)
        end)

      assert log =~ "Managed clone clone failed repo=web"
      assert File.ls!(Path.dirname(clone)) == []
    end

    test "a clone folder that cannot be created is a clone failure", %{root: root} do
      File.write!(Path.join(root, "not-a-dir"), "")
      clone = Path.join([root, "not-a-dir", "acme", "web"])

      capture_log(fn ->
        assert {:error, {:managed_clone_failed, "web", {:clone, {:mkdir_failed, _dir, :enotdir}}}} =
                 ManagedClone.sync("web", "acme/web", clone)
      end)
    end

    test "a non-empty folder in the clone's place is a clone failure", %{clone: clone} do
      File.mkdir_p!(Path.join(clone, "stray"))

      capture_log(fn ->
        assert {:error, {:managed_clone_failed, "web", {:clone, {:rename_failed, ^clone, _reason}}}} =
                 ManagedClone.sync("web", "acme/web", clone)
      end)

      assert File.ls!(Path.dirname(clone)) == ["web"]
    end

    test "a failed fetch is reported with the repo key", %{root: root, clone: clone} do
      assert ManagedClone.sync("web", "acme/web", clone) == :ok
      git!(clone, ["remote", "set-url", "origin", Path.join(root, "missing.git")])

      log =
        capture_log(fn ->
          assert {:error, {:managed_clone_failed, "web", {:fetch, {:git_failed, _status, _output}}}} =
                   ManagedClone.sync("web", "acme/web", clone)
        end)

      assert log =~ "Managed clone fetch failed repo=web"
    end

    test "waits for the clone's lock", %{clone: clone} do
      {resource, _requester} = ManagedClone.lock_id(clone)
      assert :global.set_lock({resource, self()}, [node()])

      task = Task.async(fn -> ManagedClone.sync("web", "acme/web", clone) end)

      assert Task.yield(task, 200) == nil
      refute File.exists?(clone)

      :global.del_lock({resource, self()}, [node()])
      assert Task.await(task) == :ok
      assert File.dir?(Path.join(clone, ".git"))
    end

    test "concurrent syncs make one clone", %{clone: clone} do
      results =
        1..4
        |> Enum.map(fn _index -> Task.async(fn -> ManagedClone.sync("web", "acme/web", clone) end) end)
        |> Task.await_many(30_000)

      assert results == [:ok, :ok, :ok, :ok]
      assert File.ls!(Path.dirname(clone)) == ["web"]
      git!(clone, ["fsck", "--no-progress"])
    end
  end

  describe "dispatch" do
    setup %{root: root} do
      remote = remote!(root, "acme/web", "Remote prompt")
      {:ok, remote: remote}
    end

    test "clones on startup and reads the workflow from the fetched ref", %{root: root, clones_root: clones_root} do
      write_symphony!(root)
      {:ok, system_config} = Config.system()

      assert WorkflowSource.refresh_all(system_config) == :ok
      assert File.dir?(Path.join([clones_root, "acme/web", ".git"]))
      assert {:ok, %{prompt: "Remote prompt"}} = Config.workflow_for_repo("web")
      assert Config.validate!() == :ok
    end

    test "creates worktrees and auto branches in the clone, fetching before each dispatch", %{
      root: root,
      remote: remote,
      clones_root: clones_root
    } do
      user_checkout = Path.join(root, "user-checkout")
      git!(root, ["clone", "-q", remote, user_checkout])
      start!(root, workspaces: "  repo: #{user_checkout}\n")
      clone = Path.join(clones_root, "acme/web")

      # A clone removed while Symphony runs is made again on the next dispatch.
      File.rm_rf!(clone)

      assert {:ok, workspace} = Workspace.create_for_issue("TP-1", nil, "web")
      assert workspace == canonical(Path.join([root, "workspaces", "web", "TP-1"]))
      assert git!(workspace, ["rev-parse", "--git-common-dir"]) |> String.trim() |> Path.expand(workspace) == canonical(Path.join(clone, ".git"))
      git!(clone, ["rev-parse", "--verify", "refs/heads/auto/TP-1"])
      assert {:ok, %{prompt: "Remote prompt"}} = Config.workflow_for_repo("web")

      second = push!(root, remote, "Second prompt")

      assert {:ok, workspace} = Workspace.create_for_issue("TP-2", nil, "web")
      assert rev!(workspace, "HEAD") == second
      assert %{result: :ok} = FetchLog.last("web")
      refute rev!(clone, "main") == second
      assert {:ok, %{prompt: "Second prompt"}} = Config.workflow_for_repo("web")

      # The engineer's own checkout is left alone.
      worktrees = user_checkout |> git!(["worktree", "list", "--porcelain"]) |> String.split("\n")
      assert Enum.count(worktrees, &String.starts_with?(&1, "worktree ")) == 1
      refute git!(user_checkout, ["branch", "--list", "auto/*"]) =~ "auto/"
    end

    test "an agent can run git status, commit and push in the worktree", %{root: root, remote: remote} do
      start!(root)
      assert {:ok, workspace} = Workspace.create_for_issue("TP-1", nil, "web")

      settings = Config.settings_for_repo!("web")
      assert canonical(Path.join([root, "clones", "acme/web", ".git"])) in Schema.runtime_workspace_write_roots(settings, workspace)

      assert git!(workspace, ["status", "--porcelain"]) == ""
      File.write!(Path.join(workspace, "change.txt"), "change\n")
      git!(workspace, ["add", "change.txt"])
      git!(workspace, ["commit", "-q", "-m", "change"])
      git!(workspace, ["push", "-q", "origin", "auto/TP-1"])
      assert rev!(remote, "auto/TP-1") == rev!(workspace, "HEAD")
    end

    test "a retried issue keeps the commits on its existing branch", %{root: root, remote: remote, clones_root: clones_root} do
      start!(root)
      clone = Path.join(clones_root, "acme/web")
      assert {:ok, workspace} = Workspace.create_for_issue("TP-1", nil, "web")
      File.write!(Path.join(workspace, "change.txt"), "change\n")
      git!(workspace, ["add", "change.txt"])
      git!(workspace, ["commit", "-q", "-m", "local work"])
      local_work = rev!(workspace, "HEAD")
      git!(clone, ["worktree", "remove", "--force", workspace])
      push!(root, remote, "Second prompt")

      assert {:ok, ^workspace} = Workspace.create_for_issue("TP-1", nil, "web")
      assert rev!(workspace, "HEAD") == local_work
    end

    test "without origin/HEAD a fresh worktree branches off the clone's HEAD", %{root: root, clones_root: clones_root} do
      start!(root, workspace: "      fetch_before_dispatch: false\n")
      clone = Path.join(clones_root, "acme/web")
      git!(clone, ["remote", "set-head", "origin", "--delete"])

      assert {:ok, workspace} = Workspace.create_for_issue("TP-1", nil, "web")
      assert rev!(workspace, "HEAD") == rev!(clone, "main")
    end

    test "a fetch failure is a dispatch error with the repo key and other repos still dispatch", %{
      root: root,
      clones_root: clones_root
    } do
      File.write!(Path.join(root, "APP_WORKFLOW.md"), "App prompt\n")

      start!(root,
        extra_repo: """
          - key: app
            workflow: #{Path.join(root, "APP_WORKFLOW.md")}
            route:
              projects: [app]
        """
      )

      git!(Path.join(clones_root, "acme/web"), ["remote", "set-url", "origin", Path.join(root, "missing.git")])

      log =
        capture_log(fn ->
          assert {:error, {:managed_clone_failed, "web", {:fetch, _reason}}} = Workspace.create_for_issue("TP-1", nil, "web")
        end)

      assert log =~ "repo=web"
      assert %{result: {:error, {:managed_clone_failed, "web", {:fetch, _reason}}}} = FetchLog.last("web")
      assert {:ok, _workspace} = Workspace.create_for_issue("TP-2", nil, "app")
    end
  end

  defp parse(repo, workspaces \\ %{}) do
    SystemSchema.parse(%{
      "repositories" => [Map.merge(%{"key" => "web"}, repo)],
      "workspaces" => workspaces
    })
  end

  defp remote!(root, github, prompt) do
    remote = Path.join([root, "remotes", github <> ".git"])
    seed = Path.join(root, "seed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.dirname(remote))
    git!(root, ["init", "-q", "--bare", "-b", "main", remote])
    git!(root, ["init", "-q", "-b", "main", seed])
    File.write!(Path.join(seed, "WORKFLOW.md"), prompt <> "\n")
    git!(seed, ["add", "WORKFLOW.md"])
    git!(seed, ["commit", "-q", "-m", "workflow"])
    git!(seed, ["push", "-q", remote, "main"])
    remote
  end

  defp push!(root, remote, prompt) do
    other = Path.join(root, "other-#{System.unique_integer([:positive])}")
    git!(root, ["clone", "-q", remote, other])
    File.write!(Path.join(other, "WORKFLOW.md"), prompt <> "\n")
    git!(other, ["commit", "-q", "-am", "update workflow"])
    git!(other, ["push", "-q", "origin", "main"])
    rev!(other, "HEAD")
  end

  defp rev!(dir, ref), do: dir |> git!(["rev-parse", ref]) |> String.trim()

  defp canonical(path) do
    {:ok, canonical} = SymphonyElixir.PathSafety.canonicalize(path)
    canonical
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], env: @git_env, stderr_to_stdout: true)
    output
  end

  # What startup does before the runtime reads any repo's workflow.
  defp start!(root, opts \\ []) do
    write_symphony!(root, opts)
    {:ok, system_config} = Config.system()
    assert WorkflowSource.refresh_all(system_config) == :ok
  end

  defp write_symphony!(root, opts \\ []) do
    path = Path.join(root, "symphony.yml")

    File.write!(path, """
    issues:
      provider: memory
    repositories:
      - key: web
        route:
          projects: [web]
        workspace:
    #{Keyword.get(opts, :workspace, "")}      source: git@github.com:acme/web.git
    #{Keyword.get(opts, :extra_repo, "")}
    workspaces:
      root: #{Path.join(root, "workspaces")}
      clones_root: #{Path.join(root, "clones")}
    #{Keyword.get(opts, :workspaces, "")}
    agent:
      runtime: codex
      command: codex app-server
    """)

    Workflow.set_symphony_file_path(path)
    Cache.clear()
  end
end
