defmodule SymphonyElixir.ReviewAgentConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{Schema, SystemSchema}

  @repositories [%{"key" => "default", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}]
  @runs %{"default" => %{"harness" => "codex", "provider" => "openai", "model" => "gpt-test"}}
  @symphony %{
    "execution" => %{"harnesses" => %{"codex" => %{"command" => "codex app-server"}}},
    "runs" => @runs,
    "repositories" => @repositories
  }

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
    test "a pre_push_review section is refused as an unknown key" do
      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(Map.put(@symphony, "pre_push_review", %{"enabled" => true}))

      assert message == "unknown symphony.yml key `pre_push_review`"
    end

    test "pre_push_review is not a run kind" do
      runs = Map.put(@runs, "pre_push_review", %{"model" => "claude-opus-5-5"})

      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(%{@symphony | "runs" => runs})

      assert message ==
               "runs.pre_push_review is not a run kind; expected default or one of: " <>
                 "implementation, breakdown, rework, landing, code_review, epic_review, ci_fix, review_feedback, qa, conductor"
    end

    test "pre_push_review is not a run kind in a repository's runs either" do
      [repository] = @repositories
      repository = Map.put(repository, "runs", %{"pre_push_review" => %{"effort" => "high"}})

      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(%{@symphony | "repositories" => [repository]})

      assert message =~ "repositories[default].runs.pre_push_review is not a run kind; expected default or one of: "
    end

    test "the run kinds still load" do
      runs = Map.put(@runs, "code_review", %{"effort" => "high"})

      assert {:ok, %SystemSchema{}} = SystemSchema.parse(%{@symphony | "runs" => runs})
    end
  end

  describe "code_review config" do
    test "defaults to disabled when section is absent" do
      assert {:ok, %Schema{} = settings} = Config.settings()
      refute Map.has_key?(settings, :self_review)
      refute settings.review_agent.enabled
      assert settings.review_agent == %Schema.ReviewAgent{enabled: false}
      refute Map.has_key?(settings.review_agent, :kind)
      refute Map.has_key?(settings.review_agent, :command)
      refute Map.has_key?(settings.review_agent, :max_iterations)
      refute Map.has_key?(settings.review_agent, :run_on)
    end

    test "accepts an enabled section, with the reviewer's harness and command in runs.code_review" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        agent_command: "claude",
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server --review"}
      )

      assert :ok = Config.validate!()
      assert {:ok, %Schema{review_agent: review_agent} = settings} = Config.settings()
      assert review_agent == %Schema.ReviewAgent{enabled: true}

      assert %{kind: :code_review, harness: "codex", command: "codex app-server --review", provider: "openai", model: "gpt-test"} =
               Config.run(settings, :code_review)
    end

    test "an enabled section with no run entry of its own starts on what runs.default sets" do
      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true}
      )

      assert :ok = Config.validate!()
      settings = Config.settings!()
      assert settings.review_agent.enabled

      assert %{harness: "codex", command: "codex app-server", provider: "openai", model: "gpt-test"} = Config.run(settings, :code_review)
    end

    test "rejects an unsupported harness" do
      runs = Map.put(@runs, "code_review", %{"harness" => "other"})

      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(%{@symphony | "runs" => runs})
      assert message == "runs.code_review.harness must be one of: claude, codex, opencode"
    end

    test "has no run_on or max_iterations: those were the pre-push reviewer's" do
      for key <- ["run_on", "max_iterations"] do
        assert {:error, {:invalid_symphony_config, message}} =
                 SystemSchema.parse(Map.put(@symphony, "code_review", %{"enabled" => true, key => 1}))

        assert message == "unknown symphony.yml key `code_review.#{key}`"
      end
    end

    test "has no runtime, command, model or effort: the reviewer's run is runs.code_review" do
      for key <- ["runtime", "harness", "command", "model", "effort"] do
        assert {:error, {:invalid_symphony_config, message}} =
                 SystemSchema.parse(Map.put(@symphony, "code_review", %{"enabled" => true, key => "claude"}))

        assert message == "unknown symphony.yml key `code_review.#{key}`"
      end
    end

    test "system config normalizes the code_review section" do
      assert {:ok, %SystemSchema{review_agent: review_agent}} =
               SystemSchema.parse(Map.put(@symphony, "code_review", %{"enabled" => true}))

      assert review_agent.enabled
    end
  end
end
