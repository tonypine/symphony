defmodule SymphonyElixir.Config.MigrationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.BuildInfo
  alias SymphonyElixir.Config.Migration

  @backup "symphony.yml.before-v1"

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-migration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.chmod(root, 0o755)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "plan/2" do
    test "renames a block in place, keeps its neighbours and comments, and marks it with the ticket" do
      text = """
      # My settings.
      issues:
        provider: memory

      # The reviewer.
      pre_push_review: # inline
        enabled: true  # stays
        run_on: first_push
        # a note
        model: claude-opus-5-5
        max_iterations: 2

      agent:
        runtime: codex
      """

      assert {:ok, migrated, [note]} = Migration.plan(text, @backup)

      assert note == "v0.0.1.691 renamed `pre_push_review` to `code_review` in your settings"

      assert migrated == """
             # My settings.
             issues:
               provider: memory

             # The reviewer.
             # Symphony: #{note} (TP-1203). The file as it was: #{@backup}.
             code_review: # inline
               enabled: true  # stays
               # a note
               model: claude-opus-5-5

             agent:
               runtime: codex
             """
    end

    test "a run profile keeps its indent, in the agent and in every repository" do
      text = """
      agent:
        run_profiles:
          pre_push_review:
            model: a
          qa:
            model: b
      repositories:
        - key: one
          agent:
            run_profiles:
              pre_push_review:
                model: c
        - key: two
          workflow: WORKFLOW.md
        - key: three
          agent:
            run_profiles:
              code_review:
                model: d
              pre_push_review:
                model: e
      """

      assert {:ok, migrated, notes} = Migration.plan(text, @backup)
      assert {:ok, document} = YamlElixir.read_from_string(migrated)

      assert document["agent"]["run_profiles"] == %{"code_review" => %{"model" => "a"}, "qa" => %{"model" => "b"}}
      assert [one, two, three] = document["repositories"]
      assert one["agent"]["run_profiles"] == %{"code_review" => %{"model" => "c"}}
      assert two == %{"key" => "two", "workflow" => "WORKFLOW.md"}
      assert three["agent"]["run_profiles"] == %{"code_review" => %{"model" => "d"}}, "your new name stays"

      assert "v0.0.1.691 renamed `agent.run_profiles.pre_push_review` to `code_review` in your settings" in notes
      assert "v0.0.1.691 renamed `repositories[].agent.run_profiles.pre_push_review` to `code_review` in your settings" in notes

      assert "v0.0.1.691 renamed `repositories[].agent.run_profiles.pre_push_review` to `code_review`; your `code_review` stays and the old block is gone" in notes

      assert migrated =~ "    # Symphony: v0.0.1.691 renamed `agent.run_profiles.pre_push_review`"
    end

    test "reads a list at its parent's column" do
      text = "repositories:\n- key: one\n  agent:\n    run_profiles:\n      pre_push_review:\n        model: a\n- key: two\n"

      assert {:ok, migrated, [_note]} = Migration.plan(text, @backup)
      assert {:ok, %{"repositories" => [one, two]}} = YamlElixir.read_from_string(migrated)
      assert one["agent"]["run_profiles"] == %{"code_review" => %{"model" => "a"}}
      assert two == %{"key" => "two"}
    end

    test "when both names are set, the new one stays and the old block goes" do
      text = "code_review:\n  enabled: false\npre_push_review:\n  enabled: true\n  model: a\nagent:\n  runtime: codex\n"

      assert {:ok, migrated, [note]} = Migration.plan(text, @backup)

      assert note =~ "your `code_review` stays"
      assert {:ok, document} = YamlElixir.read_from_string(migrated)
      assert document == %{"code_review" => %{"enabled" => false}, "agent" => %{"runtime" => "codex"}}
    end

    test "removes a key that is gone and says why, keeping what follows it" do
      text = "ledger:\n  artifact_retention_days: 30\n\n  # keep this\n  other: 1\n"

      assert {:ok, migrated, [note]} = Migration.plan(text, @backup)

      assert note == "v0.0.1.688 removed `ledger.artifact_retention_days` from your settings: Symphony keeps every screenshot and run transcript now"

      assert migrated == "ledger:\n  # Symphony: #{note} (TP-1201). The file as it was: #{@backup}.\n\n  # keep this\n  other: 1\n"
    end

    test "a block whose only key is removed stays as an empty map, its comment kept" do
      text = "issues:\n  provider: memory\nledger: # retention\n  artifact_retention_days: 30\n"

      assert {:ok, migrated, [note]} = Migration.plan(text, @backup)

      assert migrated ==
               "issues:\n  provider: memory\nledger: {} # retention\n  # Symphony: #{note} (TP-1201). The file as it was: #{@backup}.\n"

      assert {:ok, %{"ledger" => %{}, "issues" => %{"provider" => "memory"}}} = YamlElixir.read_from_string(migrated)
    end

    test "the only-key removal migrates beside a rename" do
      text = "pre_push_review:\n  enabled: true\nledger:\n  artifact_retention_days: 30\n"

      assert {:ok, migrated, [_rename, _removal]} = Migration.plan(text, @backup)
      assert {:ok, %{"code_review" => %{"enabled" => true}, "ledger" => %{}}} = YamlElixir.read_from_string(migrated)
    end

    test "a renamed block whose every key is dropped stays as an empty map" do
      text = "pre_push_review:\n  run_on: first_push\n  max_iterations: 2\n"

      assert {:ok, migrated, [_note]} = Migration.plan(text, @backup)
      assert {:ok, %{"code_review" => %{}}} = YamlElixir.read_from_string(migrated)
    end

    test "a block holding more after its colon is refused, naming the key" do
      assert Migration.plan("ledger: &l\n  artifact_retention_days: 30\n", @backup) ==
               {:error, {:not_migrated, [{"ledger.artifact_retention_days", 2}]}}
    end

    test "leaves a file with nothing to migrate as it is" do
      text = "issues:\n  provider: memory\n# pre_push_review:\nagent:\n  pre_push_review: looks like it but isn't\n"

      assert Migration.plan(text, @backup) == {:ok, text, []}
    end

    test "leaves what isn't a YAML map for the load to report" do
      assert Migration.plan("issues: [\n", @backup) == {:ok, "issues: [\n", []}
      assert Migration.plan("- a\n- b\n", @backup) == {:ok, "- a\n- b\n", []}
    end

    test "refuses a key that isn't on a line of its own, naming it" do
      assert Migration.plan("ledger: {artifact_retention_days: 3}\n", @backup) == {:error, {:not_migrated, [{"ledger.artifact_retention_days", 1}]}}

      assert {:error, {:not_migrated, [{"repositories[].agent.run_profiles.pre_push_review", 1}]}} =
               Migration.plan("repositories:\n  - {key: a, agent: {run_profiles: {pre_push_review: {model: b}}}}\n", @backup)

      assert {:error, {:not_migrated, [{"ledger.artifact_retention_days", nil}]}} =
               Migration.plan("{ledger: {artifact_retention_days: 3}}\n", @backup)
    end

    test "names only the key the rewrite couldn't move, and its line" do
      text = "pre_push_review:\n  enabled: true\nagent:\n  run_profiles: {pre_push_review: {effort: high}, qa: {effort: low}}\n"

      assert {:error, {:not_migrated, [{"agent.run_profiles.pre_push_review", 4}]} = reason} = Migration.plan(text, @backup)

      assert Migration.format_error(reason) ==
               "Lines it can't rewrite: 4 (`agent.run_profiles.pre_push_review`). " <>
                 "Write each of those keys as an indented block, on a line of its own"
    end

    test "a section that isn't a block is left alone" do
      text = "agent: nothing\nrepositories: none\nledger: 3\n"

      assert Migration.plan(text, @backup) == {:ok, text, []}
    end

    test "a rename of a scalar value keeps the value" do
      assert {:ok, migrated, [_note]} = Migration.plan("pre_push_review: 3\n", @backup)
      assert {:ok, %{"code_review" => 3}} = YamlElixir.read_from_string(migrated)
    end
  end

  describe "migrate_file/1" do
    test "rewrites the file, keeps its permissions and leaves it as it was beside it", %{root: root} do
      path = Path.join(root, "symphony.yml")
      content = "pre_push_review:\n  enabled: true\n"
      File.write!(path, content)
      File.chmod!(path, 0o640)

      assert {:ok, [note], backup} = Migration.migrate_file(path)

      assert backup == path <> ".before-v#{BuildInfo.current().version}"
      assert File.read!(backup) == content
      assert File.read!(path) =~ "# Symphony: #{note} (TP-1203). The file as it was: symphony.yml.before-v"
      assert File.read!(path) =~ "\ncode_review:\n  enabled: true\n"
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o640
      assert Enum.sort(File.ls!(root)) == Enum.sort(["symphony.yml", Path.basename(backup)])

      assert Migration.migrate_file(path) == {:ok, [], nil}, "once: a migrated file has nothing left to move"
    end

    test "writes nothing when nothing migrates or the file can't be read", %{root: root} do
      path = Path.join(root, "symphony.yml")

      assert Migration.migrate_file(path) == {:ok, [], nil}

      File.write!(path, "issues: {}\n")
      assert Migration.migrate_file(path) == {:ok, [], nil}
      assert File.ls!(root) == ["symphony.yml"]
    end

    test "says what stopped it and leaves the file", %{root: root} do
      path = Path.join(root, "symphony.yml")
      File.write!(path, "ledger: {artifact_retention_days: 3}\n")
      assert {:error, {:not_migrated, _keys}} = Migration.migrate_file(path)

      content = "pre_push_review:\n  enabled: true\n"
      File.write!(path, content)
      File.chmod!(root, 0o500)

      assert {:error, reason} = Migration.migrate_file(path)
      assert Migration.format_error(reason) =~ "couldn't write the migrated file: "
      assert File.read!(path) == content
    end
  end

  describe "migrated_copy/1" do
    test "writes a hidden sibling and leaves the file alone", %{root: root} do
      path = Path.join(root, "symphony.yml")
      content = "pre_push_review:\n  enabled: true\n"
      File.write!(path, content)

      assert {:ok, copy, [_note]} = Migration.migrated_copy(path)

      assert Path.dirname(copy) == root
      assert String.starts_with?(Path.basename(copy), ".symphony.yml.migrate-")
      assert File.read!(copy) =~ "\ncode_review:\n"
      assert File.read!(path) == content
    end

    test "has nothing to write when nothing migrates", %{root: root} do
      path = Path.join(root, "symphony.yml")
      File.write!(path, "issues: {}\n")

      assert Migration.migrated_copy(path) == {:ok, :unchanged}
    end

    test "says what stopped it", %{root: root} do
      path = Path.join(root, "symphony.yml")
      assert Migration.migrated_copy(path) == {:error, :enoent}

      File.write!(path, "pre_push_review:\n  enabled: true\n")
      File.chmod!(root, 0o500)
      assert {:error, reason} = Migration.migrated_copy(path)
      assert is_atom(reason)
    end
  end

  describe "refused_lines/2" do
    test "names each key the build can't read, with its line in the original", %{root: root} do
      original = Path.join(root, "symphony.yml")
      File.write!(original, "pre_push_review:\n  enabled: true\nissues: {}\ntracker:\n  kind: linear\nnonsense: 1\ndispatch: {max_concurrent: 2}\n")
      checked = Path.join(root, ".copy")
      File.write!(checked, "# a note\ncode_review:\n  enabled: true\nissues: {}\ntracker:\n  kind: linear\nnonsense: 1\ndispatch: {max_concurrent: 2}\n")

      assert Migration.refused_lines(checked, original) ==
               " Lines it can't read: `dispatch.max_concurrent`, 6 (`nonsense`), 4 (`tracker`)."
    end

    test "is empty when there is nothing to name", %{root: root} do
      path = Path.join(root, "symphony.yml")
      missing = Path.join(root, "missing.yml")

      assert Migration.refused_lines(missing, path) == ""

      File.write!(path, "issues: [\n")
      assert Migration.refused_lines(path, path) == ""

      File.write!(path, "issues: {}\n")
      assert Migration.refused_lines(path, missing) == ""
      assert Migration.refused_lines(path, path) == ""
    end
  end

  test "the table is printed for the release's version.json" do
    assert %{"key" => "pre_push_review", "to" => "code_review", "ticket" => "TP-1203", "release" => "0.0.1.691"} =
             Migration.migrations_json() |> Jason.decode!() |> hd()

    removal = Migration.migrations_json() |> Jason.decode!() |> List.last()
    assert %{"key" => "ledger.artifact_retention_days", "to" => nil} = removal
  end
end
