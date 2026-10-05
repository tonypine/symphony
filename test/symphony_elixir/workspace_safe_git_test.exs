defmodule SymphonyElixir.WorkspaceSafeGitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workspace

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-safe-git-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    {:ok, test_root: test_root}
  end

  test "safe_git applies defensive config overrides and env", %{test_root: test_root} do
    fake_git = Path.join(test_root, "fake-git")
    trace = Path.join(test_root, "trace")

    File.write!(fake_git, """
    #!/bin/sh
    {
      printf 'ARGV:%s\\n' "$*"
      printf 'GIT_CONFIG_GLOBAL:%s\\n' "$GIT_CONFIG_GLOBAL"
      printf 'GIT_CONFIG_SYSTEM:%s\\n' "$GIT_CONFIG_SYSTEM"
      printf 'GIT_OPTIONAL_LOCKS:%s\\n' "$GIT_OPTIONAL_LOCKS"
    } > "#{trace}"
    """)

    File.chmod!(fake_git, 0o755)

    assert {_output, 0} =
             Workspace.safe_git(fake_git, ["status"],
               env: [
                 {"GIT_CONFIG_GLOBAL", "/tmp/hostile-global"},
                 {"GIT_CONFIG_SYSTEM", "/tmp/hostile-system"},
                 {"GIT_OPTIONAL_LOCKS", "1"}
               ]
             )

    output = File.read!(trace)
    assert output =~ "-c core.sshCommand=ssh"
    assert output =~ "-c core.fsmonitor="
    assert output =~ "-c core.hooksPath="
    assert output =~ "-c protocol.ext.allow=never"
    assert output =~ "-c protocol.file.allow=user"
    assert output =~ "-c diff.ignoreSubmodules=dirty"
    assert output =~ "-c submodule.recurse=false"
    assert output =~ "ARGV:"
    assert output =~ " status"
    assert output =~ "GIT_CONFIG_GLOBAL:/dev/null"
    assert output =~ "GIT_CONFIG_SYSTEM:/dev/null"
    assert output =~ "GIT_OPTIONAL_LOCKS:0"
  end

  test "safe_git does not execute repo-local core.fsmonitor", %{test_root: test_root} do
    repo = Path.join(test_root, "repo")
    proof = Path.join(test_root, "SYMPHONY_PWNED")

    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "safe git\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    git!(repo, ["config", "core.fsmonitor", "sh -c 'touch \"#{proof}\"'"])

    File.rm(proof)

    assert {_output, 0} = Workspace.safe_git(["-C", repo, "status", "--short"])
    refute File.exists?(proof)
  end

  test "safe_git does not execute repo-local core.hooksPath hooks", %{test_root: test_root} do
    repo = Path.join(test_root, "repo")
    hooks = Path.join(test_root, "evil-hooks")
    proof = Path.join(test_root, "SYMPHONY_HOOK_PWNED")

    File.mkdir_p!(repo)
    File.mkdir_p!(hooks)

    for hook <- ["post-checkout", "post-commit", "pre-commit"] do
      hook_path = Path.join(hooks, hook)
      File.write!(hook_path, "#!/bin/sh\ntouch \"#{proof}\"\n")
      File.chmod!(hook_path, 0o755)
    end

    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "safe git\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    git!(repo, ["config", "core.hooksPath", hooks])

    File.rm(proof)

    assert {_output, 0} = Workspace.safe_git(["-C", repo, "checkout", "-b", "feature"])
    refute File.exists?(proof)
  end

  test "safe_git refuses to execute ext:: remote helpers", %{test_root: test_root} do
    repo = Path.join(test_root, "repo")
    proof = Path.join(test_root, "SYMPHONY_EXT_PWNED")

    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])

    File.rm(proof)

    hostile = "ext::sh -c 'touch \"#{proof}\" >&2; false'"
    assert {_output, status} = Workspace.safe_git(["-C", repo, "ls-remote", hostile])
    assert status != 0
    refute File.exists?(proof)
  end

  test "safe_git_stdout returns stdout and stderr apart, with the safe overrides", %{test_root: test_root} do
    repo = Path.join(test_root, "repo")
    proof = Path.join(test_root, "SYMPHONY_STDOUT_PWNED")

    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "safe git\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    git!(repo, ["config", "core.fsmonitor", "sh -c 'touch \"#{proof}\"'"])

    File.rm(proof)

    assert {"safe git\n", 0, ""} = Workspace.safe_git_stdout(["-C", repo, "show", "HEAD:README.md"])
    assert {"", status, stderr} = Workspace.safe_git_stdout(["-C", repo, "show", "HEAD:missing.md"])
    assert status != 0
    assert stderr =~ "fatal: path 'missing.md' does not exist in 'HEAD'"

    assert {_stdout, 0, _stderr} = Workspace.safe_git_stdout(["-C", repo, "status", "--short"])
    refute File.exists?(proof)
  end

  test "safe_git runs no filter driver that only a new worktree's include loads", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    included = Path.join(test_root, "worktree-only.cfg")
    proof = Path.join(test_root, "SYMPHONY_INCLUDE_PWNED")

    git!(repo, ["checkout", "-b", "agent"])
    File.write!(Path.join(repo, ".gitattributes"), "notes.txt filter=hidden\n")
    File.write!(Path.join(repo, "notes.txt"), "stored\n")
    git!(repo, ["add", ".gitattributes", "notes.txt"])
    git!(repo, ["commit", "-m", "agent attributes"])
    git!(repo, ["checkout", "main"])

    # The driver applies only in a linked worktree, so the repo's own config shows none.
    File.write!(included, "[filter \"hidden\"]\n\tsmudge = touch '#{proof}'; cat\n")
    git!(repo, ["config", "includeIf.gitdir:**/worktrees/**.path", included])

    worktree = Path.join(test_root, "worktree")
    assert {_output, 0} = Workspace.safe_git(["-C", repo, "worktree", "add", worktree, "agent"])
    assert File.read!(Path.join(worktree, "notes.txt")) == "stored\n"
    refute File.exists?(proof)

    git!(repo, ["worktree", "add", Path.join(test_root, "plain-worktree"), "-b", "plain", "agent"])
    assert File.exists?(proof), "plain git runs the driver, so the setup above is a real attack"
  end

  test "safe_git runs no filter driver from a nested repo's own config", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    nested = init_repo!(Path.join(repo, "nested"))
    proof = Path.join(test_root, "SYMPHONY_NESTED_PWNED")

    File.write!(Path.join(nested, ".gitattributes"), "notes.txt filter=evil\n")
    File.write!(Path.join(nested, "notes.txt"), "stored\n")
    git!(nested, ["add", ".gitattributes", "notes.txt"])
    git!(nested, ["commit", "-m", "nested attributes"])
    git!(repo, ["add", "nested"])
    git!(repo, ["commit", "-m", "nested repo"])
    git!(nested, ["config", "filter.evil.clean", "touch '#{proof}'; cat"])

    # A new mtime makes git read the file back through its clean filter to see whether it changed.
    stale = fn -> File.touch!(Path.join(nested, "notes.txt"), System.os_time(:second) + 60) end
    stale.()

    assert {_output, 0} = Workspace.safe_git(["-C", repo, "status", "--porcelain"])
    # The orphan backup's `add -A` starts from an empty index, like this one.
    index_env = [{"GIT_INDEX_FILE", Path.join(test_root, "backup.index")}]
    assert {_output, 0} = Workspace.safe_git(["-C", repo, "add", "-A"], env: index_env)
    refute File.exists?(proof)

    stale.()
    git!(repo, ["status", "--porcelain"])
    assert File.exists?(proof), "plain git runs the driver, so the setup above is a real attack"
  end

  test "safe_git refuses to run git when a filter driver's name holds `=`", %{test_root: test_root} do
    repo = init_repo!(Path.join(test_root, "repo"))
    git!(repo, ["config", "filter.a=b.smudge", "touch '#{Path.join(test_root, "pwned")}'"])

    assert {message, 128} = Workspace.safe_git(["-C", repo, "status"])
    assert message =~ ~s(filter driver "a=b")
    assert {"", 128, ^message} = Workspace.safe_git_stdout(["-C", repo, "status"])
  end

  defp init_repo!(repo) do
    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "safe git\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    repo
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
