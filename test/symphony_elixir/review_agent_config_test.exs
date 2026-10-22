defmodule SymphonyElixir.ReviewAgentConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{Schema, SystemSchema}

  @repositories [%{"key" => "default", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}]

  describe "removed self_review config" do
    test "workflow config rejects self_review and points to code_review" do
      File.write!(Workflow.workflow_file_path(), """
      ---
      self_review:
        enabled: true
        provider: openai
        model: gpt-5.1-mini
      ---
      Test prompt
      """)

      WorkflowStore.force_reload()

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "self_review"
      assert message =~ "code_review"
    end

    test "system config rejects self_review and points to code_review" do
      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{"self_review" => %{"enabled" => true}, "repositories" => @repositories})

      assert message =~ "self_review"
      assert message =~ "code_review"
    end
  end

  describe "removed pre-push reviewer" do
    test "a pre_push_review section is refused: Code Review owns the review now" do
      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{
                 "pre_push_review" => %{"enabled" => true, "runtime" => "codex", "command" => "codex app-server"},
                 "repositories" => @repositories
               })

      assert message =~ "`pre_push_review` is not valid"
      assert message =~ "Code Review owns the review of the code now"
      assert message =~ "`code_review`"
    end

    test "a pre_push_review run profile is refused with the same reason" do
      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{
                 "agent" => %{"run_profiles" => %{"pre_push_review" => %{"model" => "claude-opus-5-5"}}},
                 "repositories" => @repositories
               })

      assert message =~ "`agent.run_profiles.pre_push_review` is not valid"
      assert message =~ "Code Review owns the review of the code now"
      assert message =~ "`agent.run_profiles.code_review`"
    end

    test "a repository's pre_push_review run profile is refused with the same reason" do
      [repository] = @repositories
      repository = Map.put(repository, "agent", %{"run_profiles" => %{"pre_push_review" => %{"effort" => "high"}}})

      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(%{"repositories" => [repository]})

      assert message =~ "`repositories[default].agent.run_profiles.pre_push_review` is not valid"
      assert message =~ "Code Review owns the review of the code now"
    end

    test "the other run profiles still load" do
      assert {:ok, %SystemSchema{}} =
               SystemSchema.parse(%{
                 "agent" => %{"runtime" => "codex", "command" => "codex app-server", "run_profiles" => %{"code_review" => %{"effort" => "high"}}},
                 "repositories" => @repositories
               })
    end
  end

  describe "code_review config" do
    test "defaults to disabled when section is absent" do
      assert {:ok, %Schema{} = settings} = Config.settings()
      refute Map.has_key?(settings, :self_review)
      refute settings.review_agent.enabled
      assert settings.review_agent.kind == nil
      assert settings.review_agent.command == nil
      refute Map.has_key?(settings.review_agent, :max_iterations)
      refute Map.has_key?(settings.review_agent, :run_on)
    end

    test "accepts an enabled section" do
      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      assert :ok = Config.validate!()
      assert {:ok, %Schema{review_agent: review_agent}} = Config.settings()
      assert review_agent.enabled
      assert review_agent.kind == "codex"
      assert review_agent.command == "codex app-server"
    end

    test "rejects enabled config without kind and command" do
      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "code_review"
      assert message =~ "runtime"
      assert message =~ "command"
    end

    test "rejects an unsupported kind" do
      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "other", command: "other app-server"}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "code_review"
      assert message =~ "runtime"
    end

    test "has no run_on or max_iterations: those were the pre-push reviewer's" do
      for key <- ["run_on", "max_iterations"] do
        assert {:error, {:invalid_symphony_config, message}} =
                 SystemSchema.parse(%{
                   "code_review" => %{"enabled" => true, "runtime" => "codex", "command" => "codex app-server", key => 1},
                   "repositories" => @repositories
                 })

        assert message == "unknown symphony.yml key `code_review.#{key}`"
      end
    end

    test "system config normalizes the code_review section" do
      assert {:ok, %SystemSchema{review_agent: review_agent}} =
               SystemSchema.parse(%{
                 "code_review" => %{
                   "enabled" => true,
                   "runtime" => "claude",
                   "command" => "claude",
                   "model" => "claude-opus-5-5",
                   "effort" => "high"
                 },
                 "repositories" => @repositories
               })

      assert review_agent.enabled
      assert review_agent.kind == "claude"
      assert review_agent.command == "claude"
      assert review_agent.model == "claude-opus-5-5"
      assert review_agent.effort == "high"
    end
  end
end
