defmodule Mix.Tasks.ProtectedPaths.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.ProtectedPaths.Check

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("protected_paths.check")
    repo = Path.join(System.tmp_dir!(), "protected-paths-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)

    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])

    # As in Symphony's own repo: `.agents/skills/pull` links to the shipped `priv/skills/pull`.
    commit_files!(repo, %{".agents/skills/push/SKILL.md" => "push v1\n", "priv/skills/pull/SKILL.md" => "pull v1\n", "lib/app.ex" => "app v1\n"}, "initial")
    File.ln_s!("../../priv/skills/pull", Path.join(repo, ".agents/skills/pull"))
    commit_files!(repo, %{}, "link the pull skill")
    git!(repo, ["checkout", "-b", "auto/ACME-495"])

    %{repo: repo}
  end

  test "prints help" do
    output = capture_io(fn -> Check.run(["--help"]) end)
    assert output =~ "mix protected_paths.check --base"
  end

  test "rejects invalid options and a missing --base" do
    assert_raise Mix.Error, ~r/Invalid option/, fn -> Check.run(["--wat"]) end
    assert_raise Mix.Error, ~r/Missing required option --base/, fn -> Check.run([]) end
  end

  test "passes a branch that changes no protected path", %{repo: repo} do
    commit_files!(repo, %{"lib/app.ex" => "app v2\n"}, "agent work")

    output = capture_io(fn -> Check.run(["--base", "main", "--repo", repo]) end)
    assert output =~ "No agent-protected path changed since HEAD forked from main."
  end

  test "fails a branch whose own commits change a skill or WORKFLOW.md", %{repo: repo} do
    commit_files!(repo, %{".agents/skills/push/SKILL.md" => "agent rewrite\n", "WORKFLOW.md" => "agent rewrite\n"}, "rewrite")

    stderr =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/auto\/ACME-495 changes paths the agent sandbox write-protects since it forked from main/, fn ->
          Check.run(["--base", "main", "--head", "auto/ACME-495", "--repo", repo])
        end
      end)

    assert stderr =~ "Changed: .agents/skills/push/SKILL.md"
    assert stderr =~ "Changed: WORKFLOW.md"
  end

  test "fails a branch whose own commits exempt a setting from needing a control in the macOS app", %{repo: repo} do
    commit_files!(repo, %{"config/settings_ui_exempt.yml" => "exemptions:\n  - key: agent.new_setting\n    reason: agent\n"}, "exempt")

    stderr =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, fn -> Check.run(["--base", "main", "--repo", repo]) end
      end)

    assert stderr =~ "Changed: config/settings_ui_exempt.yml"
  end

  test "fails a branch that changes the files behind a symlinked skill", %{repo: repo} do
    commit_files!(repo, %{"priv/skills/pull/SKILL.md" => "agent rewrite\n"}, "rewrite the pull skill")

    stderr =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, fn -> Check.run(["--base", "main", "--repo", repo]) end
      end)

    assert stderr =~ "Changed: priv/skills/pull/SKILL.md"
  end

  test "passes protected changes merged from the base branch", %{repo: repo} do
    commit_files!(repo, %{"lib/app.ex" => "app v2\n"}, "agent work")
    git!(repo, ["checkout", "main"])
    commit_files!(repo, %{".agents/skills/push/SKILL.md" => "push v2\n", "priv/skills/pull/SKILL.md" => "pull v2\n", "WORKFLOW.md" => "v2\n"}, "main work")
    git!(repo, ["checkout", "auto/ACME-495"])
    git!(repo, ["merge", "--no-edit", "main"])

    output = capture_io(fn -> Check.run(["--base", "main", "--repo", repo]) end)
    assert output =~ "No agent-protected path changed"
  end

  test "surfaces a git error", %{repo: repo} do
    assert_raise Mix.Error, ~r/git ls-tree .* failed with 128: fatal: Not a valid object name/, fn ->
      Check.run(["--base", "origin/missing", "--repo", repo])
    end
  end

  defp commit_files!(repo, files, message) do
    for {path, contents} <- files do
      path = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    git!(repo, ["add", "--all"])
    git!(repo, ["commit", "-m", message])
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
