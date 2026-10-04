defmodule SymphonyElixir.SharedSkillsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SharedSkills

  test "names/0 lists the repo-agnostic shared skills" do
    assert SharedSkills.names() == ["commit", "pull", "linear"]
  end

  test "plugin_name/0 is stable" do
    assert SharedSkills.plugin_name() == "symphony-shared-skills"
  end

  test "codex_home_files/1 lays skills under <home>/skills/<name>/SKILL.md with embedded contents" do
    files = SharedSkills.codex_home_files("/tmp/codex-home")

    assert Enum.map(files, fn {path, _contents} -> path end) == [
             "/tmp/codex-home/skills/commit/SKILL.md",
             "/tmp/codex-home/skills/pull/SKILL.md",
             "/tmp/codex-home/skills/linear/SKILL.md"
           ]

    for {path, contents} <- files do
      name = path |> Path.dirname() |> Path.basename()
      assert contents =~ "name: #{name}"
      assert byte_size(contents) > 0
    end
  end

  test "the pull skill syncs through github_sync_base and writes no git config" do
    {_path, pull} = "/tmp/codex-home" |> SharedSkills.codex_home_files() |> Enum.find(&String.ends_with?(elem(&1, 0), "/pull/SKILL.md"))

    # The sandbox denies writes to the repo's git config and to `.ai/skills`.
    refute pull =~ ~r/git config\s+\S+\.\S+/
    assert pull =~ "git -c rerere.enabled=true -c rerere.autoupdate=true"
    assert pull =~ "`github_sync_base` tool"
  end

  test "claude_plugin_files/1 includes the manifest and one SKILL.md per skill" do
    files = SharedSkills.claude_plugin_files("/tmp/plugin")

    assert Enum.map(files, fn {path, _contents} -> path end) == [
             "/tmp/plugin/.claude-plugin/plugin.json",
             "/tmp/plugin/skills/commit/SKILL.md",
             "/tmp/plugin/skills/pull/SKILL.md",
             "/tmp/plugin/skills/linear/SKILL.md"
           ]

    {_manifest_path, manifest_json} = hd(files)
    assert {:ok, manifest} = Jason.decode(manifest_json)
    assert manifest["name"] == SharedSkills.plugin_name()
    assert is_binary(manifest["version"])
    assert manifest["description"] =~ "commit"
  end

  test "plugin_manifest_json/0 round-trips to a valid manifest" do
    assert {:ok, manifest} = Jason.decode(SharedSkills.plugin_manifest_json())
    assert Map.keys(manifest) |> Enum.sort() == ["description", "name", "version"]
  end

  describe "write_local_files/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "symphony-shared-skills-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root}
    end

    test "writes each file with parent dirs and 0600 perms", %{root: root} do
      target = Path.join([root, "nested", "deep", "SKILL.md"])
      assert :ok = SharedSkills.write_local_files([{target, "hello"}])
      assert File.read!(target) == "hello"
      assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o600
    end

    test "halts with a tagged error when a write fails", %{root: root} do
      # Pre-create the target path as a directory so File.write fails with :eisdir.
      conflict = Path.join(root, "SKILL.md")
      File.mkdir_p!(conflict)

      assert {:error, {:shared_skill_write_failed, ^conflict, :eisdir}} =
               SharedSkills.write_local_files([{conflict, "data"}])
    end
  end
end
