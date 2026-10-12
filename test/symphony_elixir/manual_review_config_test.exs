defmodule SymphonyElixir.ManualReviewConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{Schema, SystemSchema}

  defp append_symphony_yml!(yaml) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> yaml)
    Cache.clear()
  end

  defp symphony(repo_fields \\ %{}, sections \\ %{}) do
    Map.merge(
      %{
        "issues" => %{"provider" => "memory"},
        "agent" => %{"runtime" => "claude", "command" => "claude --dangerously-skip-permissions"},
        "repositories" => [
          Map.merge(%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}, repo_fields)
        ]
      },
      sections
    )
  end

  defp repo(key, manual_review) do
    %{
      "name" => key,
      "path" => Path.dirname(Workflow.workflow_file_path()),
      "workflow" => Path.basename(Workflow.workflow_file_path()),
      "team" => "Test",
      "labels" => [key],
      "manual_review" => manual_review
    }
  end

  describe "parsing" do
    test "a repository defaults to off when it sets nothing" do
      assert {:ok, system} = SystemSchema.parse(symphony())
      assert hd(system.repos).manual_review == nil
    end

    test "a repository's manual_review parses" do
      assert {:ok, system} = SystemSchema.parse(symphony(%{"manual_review" => "on"}))
      assert hd(system.repos).manual_review == "on"
    end

    test "an unknown value is rejected" do
      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(symphony(%{"manual_review" => "maybe"}))
      assert message =~ "manual_review"
    end

    test "the key is one an operator may set, so the macOS manifest has a control for it" do
      assert "repositories[].manual_review" in SystemSchema.operator_key_paths()
    end
  end

  describe "the runtime setting" do
    test "is off by default, and a repository turns it on" do
      write_workflow_file!(Workflow.workflow_file_path(), repos: [repo("api", "on"), repo("web", nil)])

      assert Config.settings_for_repo!("api").manual_review == "on"
      assert Config.settings_for_repo!("web").manual_review == "off"
    end

    test "accepts the two values and rejects anything else" do
      assert {:ok, %Schema{manual_review: "off"}} = Schema.parse(%{})

      for value <- ~w(on off) do
        assert {:ok, %Schema{manual_review: ^value}} = Schema.parse(%{"manual_review" => value})
      end

      assert {:error, _reason} = Schema.parse(%{"manual_review" => "maybe"})
    end
  end

  describe "the deprecated acceptance gate mode" do
    test "maps to the setting per the design's table" do
      assert SystemSchema.manual_review_for_gate_mode("shadow") == "on"
      assert SystemSchema.manual_review_for_gate_mode("advise") == "on"
      assert SystemSchema.manual_review_for_gate_mode("enforce") == "off"
      assert SystemSchema.manual_review_for_gate_mode("decide") == "off"
      assert SystemSchema.manual_review_for_gate_mode("off") == "off"
      assert SystemSchema.manual_review_for_gate_mode(nil) == "off"
      assert SystemSchema.manual_review_for_gate_mode("sideways") == "off"
      assert SystemSchema.manual_review_for_gate_mode(" SHADOW ") == "on"
    end

    test "is the fallback for a repository that sets no manual_review" do
      write_workflow_file!(Workflow.workflow_file_path(), repos: [repo("api", nil), repo("web", nil)])
      append_symphony_yml!("auto_review:\n  acceptance_gate:\n    mode: shadow\n")

      assert Config.settings_for_repo!("api").manual_review == "on"
      assert Config.settings_for_repo!("web").manual_review == "on"
    end

    test "a repository's own gate mode is the fallback for that repository" do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        repos: [Map.put(repo("api", nil), "acceptance_gate", %{"mode" => "shadow"}), repo("web", nil)]
      )

      assert Config.settings_for_repo!("api").manual_review == "on"
      assert Config.settings_for_repo!("web").manual_review == "off"
    end

    test "the repository's own manual_review wins over the gate mode" do
      write_workflow_file!(Workflow.workflow_file_path(), repos: [Map.put(repo("api", "off"), "acceptance_gate", %{"mode" => "shadow"})])
      append_symphony_yml!("auto_review:\n  acceptance_gate:\n    mode: shadow\n")

      assert Config.settings_for_repo!("api").manual_review == "off"
    end

    test "loads with a deprecation warning once per config, naming the value it maps to" do
      write_workflow_file!(Workflow.workflow_file_path())
      base = File.read!(Workflow.symphony_file_path())

      log =
        capture_log(fn ->
          append_symphony_yml!("auto_review:\n  acceptance_gate:\n    mode: shadow\n")
          for _read <- 1..100, do: Config.settings!()
        end)

      assert count(log, "`auto_review.acceptance_gate.mode` is deprecated") == 1
      assert log =~ "`shadow` maps to `manual_review: on`"

      # A reload of a changed file that still names a mode warns once more.
      log =
        capture_log(fn ->
          File.write!(Workflow.symphony_file_path(), base <> "auto_review:\n  acceptance_gate:\n    mode: enforce\n")
          Cache.clear()
          for _read <- 1..100, do: Config.settings!()
        end)

      assert count(log, "`auto_review.acceptance_gate.mode` is deprecated") == 1
      assert log =~ "`enforce` maps to `manual_review: off`"
    end
  end

  defp count(log, fragment), do: length(String.split(log, fragment)) - 1
end
