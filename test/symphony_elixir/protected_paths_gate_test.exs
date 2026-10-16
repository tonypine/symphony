defmodule SymphonyElixir.ProtectedPathsGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Decisions, ProtectedPathsGate}
  alias SymphonyElixir.Linear.Issue

  @issue_id "issue-1049"
  @failed ["protected paths"]

  setup do
    :ok = RunStore.clear()
    repo = Path.join(System.tmp_dir!(), "protected-paths-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)

    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    base = commit!(repo, %{"WORKFLOW.md" => "v1\n", ".agents/skills/push/SKILL.md" => "push v1\n", "lib/app.ex" => "v1\n"})

    %{repo: repo, base: base}
  end

  test "a head with no failed human-only check lands" do
    assert ProtectedPathsGate.check([], pr(nil, "head-1", "base-1"), nil) == :ok
  end

  test "a failed protected paths check holds the landing back when no decision unlocks a path" do
    assert ProtectedPathsGate.check(@failed, pr(nil, "head-1", "base-1"), nil) ==
             {:blocked, "protected paths failed and no decision on the ticket unlocks the protected paths the PR changes"}

    assert {:blocked, _reason} = ProtectedPathsGate.check(@failed, pr(nil, "head-1", "base-1"), issue([]))
  end

  test "it lands once the ticket's decisions unlock every protected path the PR changes", %{repo: repo, base: base} do
    head = commit!(repo, %{"WORKFLOW.md" => "v2\n", "lib/app.ex" => "v2\n"})

    assert ProtectedPathsGate.check(@failed, pr(repo, head, base), issue(["Unlock WORKFLOW.md for ACME-1049"])) == :ok
  end

  test "a protected path no decision unlocks still holds it back", %{repo: repo, base: base} do
    head = commit!(repo, %{"WORKFLOW.md" => "v2\n", ".agents/skills/push/SKILL.md" => "push v2\n"})

    assert ProtectedPathsGate.check(@failed, pr(repo, head, base), issue(["Unlock WORKFLOW.md for ACME-1049"])) ==
             {:blocked, "protected paths failed and no decision on the ticket unlocks .agents/skills/push/SKILL.md"}
  end

  test "a PR whose changes can't be read is held back", %{repo: repo, base: base} do
    grant = issue(["Unlock WORKFLOW.md for ACME-1049"])

    assert ProtectedPathsGate.check(@failed, pr(nil, "head-1", base), grant) ==
             {:blocked, "protected paths failed and the protected paths the PR changes couldn't be read: the ticket has no workspace"}

    assert ProtectedPathsGate.check(@failed, pr(repo, "head-1", nil), grant) ==
             {:blocked, "protected paths failed and the protected paths the PR changes couldn't be read: the PR's base commit is unknown"}

    # The workspace lacks the head and has no `origin` to fetch it from.
    assert {:blocked, "protected paths failed and the protected paths the PR changes couldn't be read: git fetch origin head-1 exited " <> _detail} =
             ProtectedPathsGate.check(@failed, pr(repo, "head-1", base), grant)
  end

  test "a commit the workspace lacks is fetched, and a failed diff holds the landing back", %{repo: repo} do
    grant = issue(["Unlock WORKFLOW.md for ACME-1049"])

    git = fn
      ["cat-file", "-e", "base-1^{commit}"], ^repo -> {"", 0}
      ["cat-file", "-e", "head-1^{commit}"], ^repo -> {"", 1}
      ["fetch", "--quiet", "origin", "head-1"], ^repo -> {"", 0}
      ["ls-tree" | _args], ^repo -> {"", 128}
    end

    assert {:blocked, "protected paths failed and the protected paths the PR changes couldn't be read: git ls-tree -r -z base-1 -- " <> listed} =
             ProtectedPathsGate.check(@failed, pr(repo, "head-1", "base-1"), grant, git: git)

    assert String.ends_with?(listed, " exited 128")
    refute listed =~ "WORKFLOW.md"
  end

  defp pr(workspace, head, base), do: %{workspace_path: workspace, head_sha: head, base_sha: base}

  defp issue(rulings) do
    %Issue{
      id: @issue_id,
      identifier: "ACME-1049",
      state: "Merging",
      rulings: rulings |> Enum.with_index(1) |> Enum.map(fn {answer, index} -> Decisions.entry("ruling-c#{index}", ~D[2026-10-16], nil, nil, answer) end)
    }
  end

  defp commit!(repo, files) do
    Enum.each(files, fn {path, content} ->
      path = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "change"])
    repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    output
  end
end
