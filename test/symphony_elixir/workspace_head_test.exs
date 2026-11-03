defmodule SymphonyElixir.WorkspaceHeadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkspaceHead

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-workspace-push-#{System.unique_integer([:positive])}")
    remote = Path.join(root, "remote.git")
    source = Path.join(root, "source")
    workspace = Path.join(root, "TP-1")
    File.mkdir_p!(root)

    git!(root, ["init", "--bare", "-b", "main", remote])
    git!(root, ["clone", remote, source])
    commit!(source, "README.md")
    git!(source, ["push", "origin", "main"])
    git!(root, ["clone", remote, workspace])
    git!(workspace, ["checkout", "-b", "auto/TP-1"])

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, remote: remote, source: source, workspace: workspace}
  end

  test "commits no remote has are pushed to the workspace's branch on origin", %{remote: remote, source: source, workspace: workspace} do
    assert WorkspaceHead.push_unpushed(workspace, nil, source) == :nothing

    commit!(workspace, "fix.txt")
    head = WorkspaceHead.read(workspace, nil)

    assert WorkspaceHead.push_unpushed(workspace, nil, source) == {:pushed, "auto/TP-1"}
    assert {^head <> "\n", 0} = System.cmd("git", ["-C", remote, "rev-parse", "refs/heads/auto/TP-1"])
    assert WorkspaceHead.push_unpushed(workspace, nil, source) == :nothing
  end

  test "an SSH worker's workspace is not read", %{source: source, workspace: workspace} do
    commit!(workspace, "fix.txt")
    assert WorkspaceHead.push_unpushed(workspace, "worker-1", source) == :nothing
  end

  test "a push to any origin but the source repo's is refused", %{root: root, source: source, workspace: workspace} do
    commit!(workspace, "fix.txt")
    other = Path.join(root, "other.git")
    git!(root, ["init", "--bare", other])

    assert WorkspaceHead.push_unpushed(workspace, nil, nil) == {:error, :origin_mismatch}

    git!(workspace, ["remote", "set-url", "--push", "origin", other])
    assert WorkspaceHead.push_unpushed(workspace, nil, source) == {:error, :origin_mismatch}
  end

  test "a detached HEAD or a push the remote refuses is an error", %{remote: remote, source: source, workspace: workspace} do
    commit!(workspace, "fix.txt")
    git!(workspace, ["checkout", "--detach"])
    assert WorkspaceHead.push_unpushed(workspace, nil, source) == {:error, :no_current_branch}

    git!(workspace, ["checkout", "auto/TP-1"])
    File.write!(Path.join([remote, "hooks", "pre-receive"]), "#!/bin/sh\necho refused\nexit 1\n")
    File.chmod!(Path.join([remote, "hooks", "pre-receive"]), 0o755)

    assert {:error, {:push_failed, 1, output}} = WorkspaceHead.push_unpushed(workspace, nil, source)
    assert output =~ "refused"
  end

  describe "a parked workspace's uncommitted changes (TP-1351)" do
    test "are committed on its branch and pushed, so origin shows the branch", %{remote: remote, source: source, workspace: workspace} do
      assert WorkspaceHead.commit_worktree(workspace, nil) == :nothing

      File.write!(Path.join(workspace, "README.md"), "edited")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join([workspace, "lib", "new.ex"]), "new")

      assert {:committed, sha} = WorkspaceHead.commit_worktree(workspace, nil)
      assert sha == WorkspaceHead.read(workspace, nil)
      assert git!(workspace, ["log", "-1", "--format=%s"]) == "WIP: parked by Symphony\n"
      assert git!(workspace, ["status", "--porcelain"]) == ""

      assert WorkspaceHead.push_unpushed(workspace, nil, source) == {:pushed, "auto/TP-1"}
      assert git!(workspace, ["ls-remote", remote, "refs/heads/auto/TP-1"]) =~ sha
    end

    test "keep the workspace's own author, and skip the repo's hooks", %{workspace: workspace} do
      git!(workspace, ["config", "user.name", "Agent"])
      git!(workspace, ["config", "user.email", "agent@example.com"])
      File.write!(Path.join([workspace, ".git", "hooks", "pre-commit"]), "#!/bin/sh\nexit 1\n")
      File.chmod!(Path.join([workspace, ".git", "hooks", "pre-commit"]), 0o755)
      File.write!(Path.join(workspace, "fix.txt"), "fix")

      assert {:committed, _sha} = WorkspaceHead.commit_worktree(workspace, nil)
      assert git!(workspace, ["log", "-1", "--format=%an <%ae>"]) == "Agent <agent@example.com>\n"
    end

    test "are not committed on a detached HEAD, a refused commit or a checkout that is not the workspace's own", %{root: root, workspace: workspace} do
      File.write!(Path.join(workspace, "fix.txt"), "fix")
      git!(workspace, ["checkout", "--detach"])
      assert WorkspaceHead.commit_worktree(workspace, nil) == {:error, :no_current_branch}

      git!(workspace, ["checkout", "auto/TP-1"])
      File.write!(Path.join([workspace, ".git", "index.lock"]), "")
      assert {:error, {:commit_failed, _status, _output}} = WorkspaceHead.commit_worktree(workspace, nil)
      File.rm!(Path.join([workspace, ".git", "index.lock"]))

      inner = Path.join(workspace, "nested")
      File.mkdir_p!(inner)
      File.write!(Path.join(inner, "file.txt"), "inside")
      assert WorkspaceHead.commit_worktree(inner, nil) == :nothing
      assert WorkspaceHead.commit_worktree(Path.join(root, "missing"), nil) == :nothing
      assert WorkspaceHead.commit_worktree(workspace, "worker-1") == :nothing
    end

    test "a broken checkout's status is an error", %{workspace: workspace} do
      File.write!(Path.join([workspace, ".git", "index"]), "not an index")
      assert {:error, {:status_failed, _status, _output}} = WorkspaceHead.commit_worktree(workspace, nil)
    end
  end

  describe "worktree_digest/2" do
    test "is nil on a clean tree and changes with every edit, new file or removal", %{workspace: workspace} do
      assert WorkspaceHead.worktree_digest(workspace, nil) == nil

      File.write!(Path.join(workspace, "new.txt"), "one")
      first = WorkspaceHead.worktree_digest(workspace, nil)
      assert is_binary(first)
      assert WorkspaceHead.worktree_digest(workspace, nil) == first

      File.write!(Path.join(workspace, "new.txt"), "two")
      second = WorkspaceHead.worktree_digest(workspace, nil)
      refute second in [nil, first]

      File.write!(Path.join(workspace, "README.md"), "edited")
      third = WorkspaceHead.worktree_digest(workspace, nil)
      refute third in [nil, first, second]

      File.rm!(Path.join(workspace, "new.txt"))
      refute WorkspaceHead.worktree_digest(workspace, nil) in [nil, first, second, third]
    end

    test "reads an untracked file it can't open by its error", %{workspace: workspace} do
      File.ln_s!("missing-target", Path.join(workspace, "dangling"))
      File.mkdir_p!(Path.join(workspace, "locked"))
      File.write!(Path.join([workspace, "locked", "secret.txt"]), "x")
      File.chmod!(Path.join([workspace, "locked", "secret.txt"]), 0o000)
      on_exit(fn -> File.chmod(Path.join([workspace, "locked", "secret.txt"]), 0o644) end)

      assert is_binary(WorkspaceHead.worktree_digest(workspace, nil))
    end

    test "an SSH worker's workspace or a directory that is not a checkout reads as nil", %{root: root, workspace: workspace} do
      File.write!(Path.join(workspace, "new.txt"), "one")
      assert WorkspaceHead.worktree_digest(workspace, "worker-1") == nil
      assert WorkspaceHead.worktree_digest(root, nil) == nil
    end
  end

  defp commit!(repo, file) do
    File.write!(Path.join(repo, file), file)
    git!(repo, ["add", file])
    git!(repo, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", file])
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
