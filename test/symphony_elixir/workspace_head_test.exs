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
