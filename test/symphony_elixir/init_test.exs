defmodule SymphonyElixir.InitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.Init

  test "writes only symphony.yml and validates through the system schema" do
    root = tmp_dir()

    assert {:ok, message} = Init.run([], cwd: root)

    symphony_path = Path.join(root, "symphony.yml")
    assert message == "Wrote #{symphony_path}"
    assert File.regular?(symphony_path)
    refute File.exists?(Path.join(root, "WORKFLOW.md"))

    assert {:ok, decoded} = YamlElixir.read_from_string(File.read!(symphony_path))
    assert {:ok, %SystemSchema{}} = SystemSchema.parse(decoded)
  end

  test "refuses to overwrite an existing symphony.yml and includes a diff" do
    root = tmp_dir()
    symphony_path = Path.join(root, "symphony.yml")
    File.write!(symphony_path, "repos: []\n")

    assert {:error, message} = Init.run([], cwd: root)

    assert File.read!(symphony_path) == "repos: []\n"
    assert message =~ "#{symphony_path} already exists"
    assert message =~ "Use `symphony init --force`"
    assert message =~ "Diff:"
    assert message =~ "--- symphony.yml"
    assert message =~ "+++ symphony.yml (generated)"
    assert message =~ "-repos: []"
    assert message =~ "+issues:"
  end

  test "force overwrites an existing symphony.yml" do
    root = tmp_dir()
    symphony_path = Path.join(root, "symphony.yml")
    File.write!(symphony_path, "repos: []\n")

    assert {:ok, "Wrote " <> _path} = Init.run(["--force"], cwd: root)
    assert File.read!(symphony_path) == Init.scaffold()
  end

  test "rejects unknown switches with the offending flag in the message" do
    assert {:error, message} = Init.run(["--language", "elixir"], cwd: tmp_dir())
    assert message =~ "Unknown option --language"
    assert message =~ "Usage: symphony init [--force]"
  end

  test "rejects stray positional arguments with the offending value in the message" do
    assert {:error, message} = Init.run(["extra"], cwd: tmp_dir())
    assert message =~ "Unexpected argument extra"
    assert message =~ "Usage: symphony init [--force]"
  end

  test "returns a write error when the target directory does not exist" do
    missing_root =
      Path.join(System.tmp_dir!(), "symphony-init-missing-#{System.unique_integer([:positive])}")

    refute File.exists?(missing_root)

    assert {:error, message} = Init.run([], cwd: missing_root)
    assert message =~ "Failed to write #{Path.join(missing_root, "symphony.yml")}"
  end

  test "agent skill paths resolve to the same shared SKILL.md content" do
    canonical = Path.expand("../../.agents/skills/symphony-init-workflow/SKILL.md", __DIR__)
    codex = Path.expand("../../.codex/skills/symphony-init-workflow/SKILL.md", __DIR__)
    claude = Path.expand("../../.claude/skills/symphony-init-workflow/SKILL.md", __DIR__)

    contents = File.read!(canonical)
    assert File.read!(codex) == contents
    assert File.read!(claude) == contents
  end

  test "shared workflow skill has valid front matter and resolves through agent skill links" do
    skill_path = Path.expand("../../.agents/skills/symphony-init-workflow/SKILL.md", __DIR__)
    codex_skill_path = Path.expand("../../.codex/skills/symphony-init-workflow/SKILL.md", __DIR__)
    claude_skill_path = Path.expand("../../.claude/skills/symphony-init-workflow/SKILL.md", __DIR__)

    assert File.regular?(skill_path)
    assert File.exists?(codex_skill_path)
    assert File.exists?(claude_skill_path)

    assert {:ok, {front_matter, _body}} =
             skill_path
             |> File.read!()
             |> SymphonyElixir.Workflow.parse_document()

    assert front_matter["name"] == "symphony-init-workflow"
    assert is_binary(front_matter["description"])
    assert String.trim(front_matter["description"]) != ""
  end

  defp tmp_dir do
    root = Path.join(System.tmp_dir!(), "symphony-init-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end
