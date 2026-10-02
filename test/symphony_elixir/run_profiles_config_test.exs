defmodule SymphonyElixir.RunProfilesConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.RunKind

  defp symphony(agent) do
    %{
      "issues" => %{"provider" => "memory"},
      "agent" => Map.merge(%{"runtime" => "claude", "command" => "claude --dangerously-skip-permissions"}, agent),
      "repositories" => [%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}]
    }
  end

  defp settings!(agent) do
    {:ok, system} = SystemSchema.parse(symphony(agent))
    {:ok, settings} = Schema.parse(SystemSchema.to_config_map(system))
    settings
  end

  defp error!(agent) do
    assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(symphony(agent))
    message
  end

  describe "Config.run_profile/2" do
    test "returns nil model and effort for every kind when nothing is set" do
      settings = settings!(%{})

      for kind <- RunKind.kinds() do
        assert Config.run_profile(settings, kind) == %{model: nil, effort: nil}
      end
    end

    test "falls back to agent.model and agent.effort" do
      settings = settings!(%{"model" => "claude-sonnet-5-5", "effort" => "medium"})

      assert Config.run_profile(settings, :implementation) == %{model: "claude-sonnet-5-5", effort: "medium"}
      assert Config.run_profile(settings, "landing") == %{model: "claude-sonnet-5-5", effort: "medium"}
    end

    test "a profile field overrides the default, field by field" do
      settings =
        settings!(%{
          "model" => "claude-sonnet-5-5",
          "effort" => "medium",
          "run_profiles" => %{
            "breakdown" => %{"model" => "claude-opus-5-5", "effort" => "xhigh"},
            "landing" => %{"effort" => "low"},
            "ci_fix" => %{"model" => " claude-haiku-4-5 "}
          }
        })

      assert Config.run_profile(settings, :breakdown) == %{model: "claude-opus-5-5", effort: "xhigh"}
      assert Config.run_profile(settings, :landing) == %{model: "claude-sonnet-5-5", effort: "low"}
      assert Config.run_profile(settings, :ci_fix) == %{model: "claude-haiku-4-5", effort: "medium"}
      assert Config.run_profile(settings, :implementation) == %{model: "claude-sonnet-5-5", effort: "medium"}
    end

    test "a profile without agent defaults leaves the other field nil" do
      settings = settings!(%{"run_profiles" => %{"qa" => %{"effort" => "max"}}})

      assert Config.run_profile(settings, :qa) == %{model: nil, effort: "max"}
      assert Config.run_profile(settings, :rework) == %{model: nil, effort: nil}
    end
  end

  test "config without the new keys loads unchanged" do
    settings = settings!(%{})

    assert settings.agent.model == nil
    assert settings.agent.effort == nil
    assert settings.agent.run_profiles == %{}
    assert settings.agent.command == "claude --dangerously-skip-permissions"
  end

  test "accepts --model in agent.command when no new key is set" do
    settings = settings!(%{"command" => "claude --model claude-opus-5-5 --effort high"})

    assert settings.agent.command == "claude --model claude-opus-5-5 --effort high"
  end

  describe "validation errors name the key" do
    test "unknown run kind" do
      message = error!(%{"run_profiles" => %{"bogus" => %{"effort" => "low"}}})

      assert message =~ "agent.run_profiles has unknown run kind `bogus`; expected one of: implementation, breakdown"
    end

    test "unknown effort" do
      assert error!(%{"effort" => "extreme"}) =~ "agent.effort must be one of: low, medium, high, xhigh, max"
    end

    test "unknown effort in a profile" do
      message = error!(%{"run_profiles" => %{"ci_fix" => %{"effort" => "extreme"}}})

      assert message =~ "agent.run_profiles.ci_fix.effort must be one of: low, medium, high, xhigh, max"
    end

    test "blank or non-string model" do
      assert error!(%{"model" => "  "}) =~ "agent.model must not be blank"
      assert error!(%{"run_profiles" => %{"qa" => %{"model" => 5}}}) =~ "agent.run_profiles.qa.model must be a string"
    end

    test "non-object run_profiles or profile" do
      assert error!(%{"run_profiles" => "fast"}) =~ "agent.run_profiles is invalid"
      assert error!(%{"run_profiles" => %{"qa" => "fast"}}) =~ "agent.run_profiles.qa must be an object with model and/or effort"
    end

    test "unknown profile key" do
      message = error!(%{"run_profiles" => %{"qa" => %{"temperature" => 1}}})

      assert message =~ "agent.run_profiles.qa has unknown key `temperature`; expected model or effort"
    end

    test "--effort in agent.command with agent.effort set" do
      message = error!(%{"command" => "claude --effort high", "effort" => "low"})

      assert message =~ "agent.command must not pass --effort when agent.model, agent.effort or agent.run_profiles is set"
      refute message =~ "--model"
    end

    test "--model= in agent.command with run_profiles set" do
      message = error!(%{"command" => "claude --model=claude-opus-5-5", "run_profiles" => %{"qa" => %{"effort" => "low"}}})

      assert message =~ "agent.command must not pass --model when"
    end

    test "--model in agent.command with agent.model set" do
      assert error!(%{"command" => "claude --model x --dangerously-skip-permissions", "model" => "y"}) =~
               "agent.command must not pass --model when"
    end

    test "a flag that only starts with --model is not a conflict" do
      settings = settings!(%{"command" => "claude --model-hint x", "model" => "y"})

      assert settings.agent.model == "y"
    end
  end

  test "the merged workflow schema validates run profiles too" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{"kind" => "claude", "command" => "claude", "run_profiles" => %{"bogus" => %{}}}
             })

    assert message =~ "agent.run_profiles has unknown run kind `bogus`"
  end
end
