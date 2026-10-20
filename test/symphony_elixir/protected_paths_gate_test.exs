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

  test "it lands once a person picked an option that unlocks every protected path the PR changes", %{repo: repo, base: base} do
    head = commit!(repo, %{"WORKFLOW.md" => "v2\n", "lib/app.ex" => "v2\n"})
    picked = Decisions.entry("comment-1", ~D[2026-10-20], "Change the workflow settings", "Allow it?", "Allow the change", ["WORKFLOW.md"])
    {:ok, description} = Decisions.put("Add the hook.", [picked])

    assert ProtectedPathsGate.check(@failed, pr(repo, head, base), %{issue([]) | description: description}) == :ok
  end

  describe "changed_paths/2" do
    test "names the protected paths the PR changes as the protected list names them", %{repo: repo, base: base} do
      head = commit!(repo, %{"WORKFLOW.md" => "v2\n", ".agents/skills/push/SKILL.md" => "push v2\n", "lib/app.ex" => "v2\n"})
      assert ProtectedPathsGate.changed_paths(pr(repo, head, base)) == {:ok, [".agents/skills", "WORKFLOW.md"]}

      unprotected = commit!(repo, %{"lib/app.ex" => "v3\n"})
      assert ProtectedPathsGate.changed_paths(pr(repo, unprotected, head)) == {:ok, []}
    end

    test "names the protected path whose symlink points at a changed file", %{repo: repo} do
      File.mkdir_p!(Path.join(repo, ".agents/skills"))
      File.mkdir_p!(Path.join(repo, "priv/skills/pull"))
      File.write!(Path.join(repo, "priv/skills/pull/SKILL.md"), "pull v1\n")
      File.ln_s!("../../priv/skills/pull", Path.join(repo, ".agents/skills/pull"))
      linked = commit!(repo, %{})
      head = commit!(repo, %{"priv/skills/pull/SKILL.md" => "pull v2\n"})

      assert ProtectedPathsGate.changed_paths(pr(repo, head, linked)) == {:ok, [".agents/skills"]}
    end

    test "can't be read without a workspace, a base, or a git that answers", %{repo: repo} do
      assert ProtectedPathsGate.changed_paths(pr(nil, "head-1", "base-1")) == {:error, "the ticket has no workspace"}
      assert ProtectedPathsGate.changed_paths(pr(repo, "head-1", nil)) == {:error, "the PR's base commit is unknown"}
      assert {:error, "git fetch origin base-1 exited " <> _detail} = ProtectedPathsGate.changed_paths(pr(repo, "head-1", "base-1"))

      diff_fails = fn
        ["cat-file" | _args], ^repo -> {"", 0}
        ["ls-tree" | _args], ^repo -> {"", 0}
        ["diff" | _args], ^repo -> {"bad revision", 128}
      end

      assert {:error, "git diff --name-only --no-renames base-1...head-1 -- " <> detail} =
               ProtectedPathsGate.changed_paths(pr(repo, "head-1", "base-1"), git: diff_fails)

      assert String.ends_with?(detail, "exited 128: bad revision")

      # A changed file no entry holds sends the read through each entry's symlinks, which fails here.
      links_fail = fn
        ["cat-file" | _args], ^repo -> {"", 0}
        ["ls-tree", "-r", "-z", _revision, "--", _path], ^repo -> {"", 128}
        ["ls-tree" | _args], ^repo -> {"", 0}
        ["diff" | _args], ^repo -> {"priv/skills/pull/SKILL.md\n", 0}
      end

      assert {:error, "git ls-tree -r -z base-1 -- WORKFLOW.md exited 128"} = ProtectedPathsGate.changed_paths(pr(repo, "head-1", "base-1"), git: links_fail)
    end
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
