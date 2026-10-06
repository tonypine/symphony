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

  defp worker_error!(agent, extra) do
    {:ok, system} = SystemSchema.parse(Map.merge(symphony(agent), extra))
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(SystemSchema.to_config_map(system))
    message
  end

  describe "Config.run_profile/2" do
    test "returns nil model and effort and the anthropic provider for every kind when nothing is set" do
      settings = settings!(%{})

      for kind <- RunKind.kinds() do
        assert Config.run_profile(settings, kind) == %{model: nil, effort: nil, provider: "anthropic"}
      end
    end

    test "falls back to agent.model and agent.effort" do
      settings = settings!(%{"model" => "claude-sonnet-5-5", "effort" => "medium"})

      assert Config.run_profile(settings, :implementation) == %{model: "claude-sonnet-5-5", effort: "medium", provider: "anthropic"}
      assert Config.run_profile(settings, "landing") == %{model: "claude-sonnet-5-5", effort: "medium", provider: "anthropic"}
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

      assert Config.run_profile(settings, :breakdown) == %{model: "claude-opus-5-5", effort: "xhigh", provider: "anthropic"}
      assert Config.run_profile(settings, :landing) == %{model: "claude-sonnet-5-5", effort: "low", provider: "anthropic"}
      assert Config.run_profile(settings, :ci_fix) == %{model: "claude-haiku-4-5", effort: "medium", provider: "anthropic"}
      assert Config.run_profile(settings, :implementation) == %{model: "claude-sonnet-5-5", effort: "medium", provider: "anthropic"}
    end

    test "a profile without agent defaults leaves the other field nil" do
      settings = settings!(%{"run_profiles" => %{"qa" => %{"effort" => "max"}}})

      assert Config.run_profile(settings, :qa) == %{model: nil, effort: "max", provider: "anthropic"}
      assert Config.run_profile(settings, :rework) == %{model: nil, effort: nil, provider: "anthropic"}
    end
  end

  describe "agent.small_model" do
    test "is nil by default and trimmed when set" do
      assert settings!(%{}).agent.small_model == nil
      assert settings!(%{"small_model" => " anthropic/claude-haiku-4.5 "}).agent.small_model == "anthropic/claude-haiku-4.5"
    end

    test "rejects a blank or non-string value" do
      assert error!(%{"small_model" => " "}) =~ "agent.small_model must not be blank"
      assert error!(%{"small_model" => ["x"]}) =~ "agent.small_model is invalid"
    end
  end

  describe "provider" do
    test "resolves profile, then agent.provider, then anthropic" do
      settings =
        settings!(%{
          "model" => "anthropic/claude-sonnet-5.5",
          "provider" => "openrouter",
          "run_profiles" => %{
            "landing" => %{"provider" => "anthropic", "model" => "claude-haiku-4-5"},
            "qa" => %{"effort" => "low"}
          }
        })

      assert settings.agent.provider == "openrouter"
      assert Config.run_profile(settings, :landing) == %{model: "claude-haiku-4-5", effort: nil, provider: "anthropic"}
      assert Config.run_profile(settings, :qa) == %{model: "anthropic/claude-sonnet-5.5", effort: "low", provider: "openrouter"}
      assert Config.run_profile(settings, :implementation).provider == "openrouter"
    end

    test "a profile can pick openrouter with its own model" do
      settings = settings!(%{"run_profiles" => %{"landing" => %{"provider" => "openrouter", "model" => "anthropic/claude-haiku-4.5"}}})

      assert Config.run_profile(settings, :landing) == %{model: "anthropic/claude-haiku-4.5", effort: nil, provider: "openrouter"}
      assert Config.run_profile(settings, :implementation) == %{model: nil, effort: nil, provider: "anthropic"}
    end

    test "agent.provider openrouter is fine when every run resolves a model" do
      profiles = Map.new(RunKind.names(), &{&1, %{"model" => "openai/gpt-5"}})
      settings = settings!(%{"provider" => "openrouter", "run_profiles" => profiles})

      assert Config.run_profile(settings, :qa).provider == "openrouter"
    end

    test "with no provider set anywhere, resolved model and effort match the previous resolution" do
      settings =
        settings!(%{
          "model" => "claude-sonnet-5-5",
          "effort" => "medium",
          "run_profiles" => %{"breakdown" => %{"model" => "claude-opus-5-5", "effort" => "xhigh"}, "landing" => %{"effort" => "low"}}
        })

      for kind <- RunKind.kinds() do
        profile = Config.run_profile(settings, kind)
        run_profile = Map.get(settings.agent.run_profiles, Atom.to_string(kind), %{})

        assert Map.delete(profile, :provider) == %{
                 model: Map.get(run_profile, "model", settings.agent.model),
                 effort: Map.get(run_profile, "effort", settings.agent.effort)
               }

        assert profile.provider == "anthropic"
      end

      refute Enum.any?(Map.values(settings.agent.run_profiles), &Map.has_key?(&1, "provider"))
    end

    test "unknown provider names the key" do
      assert error!(%{"provider" => "bedrock"}) =~ "agent.provider must be one of: anthropic, openrouter"

      assert error!(%{"run_profiles" => %{"qa" => %{"provider" => "bedrock"}}}) =~
               "agent.run_profiles.qa.provider must be one of: anthropic, openrouter"
    end

    test "openrouter without a resolved model names the key" do
      message = error!(%{"provider" => "openrouter", "run_profiles" => %{"qa" => %{"model" => "openai/gpt-5"}}})

      assert message =~ "agent.provider openrouter needs an OpenRouter model id; set agent.model or agent.run_profiles.<kind>.model"
      assert message =~ "(missing for: implementation, breakdown,"
      refute message =~ "qa"

      assert error!(%{"run_profiles" => %{"landing" => %{"provider" => "openrouter"}}}) =~
               "agent.run_profiles.landing.provider openrouter needs an OpenRouter model id; set agent.run_profiles.landing.model or agent.model"
    end

    test "openrouter on SSH workers names the key" do
      workers = %{"workers" => %{"ssh_hosts" => ["worker-01"]}}

      assert worker_error!(%{"provider" => "openrouter", "model" => "anthropic/claude-haiku-4.5"}, workers) ==
               "agent.provider openrouter is not supported with workers.ssh_hosts; OpenRouter runs start on the local host only"

      profiles = %{"implementation" => %{"provider" => "anthropic"}, "ci_fix" => %{"provider" => "openrouter", "model" => "x/y"}}

      assert worker_error!(%{"run_profiles" => profiles}, workers) =~
               "agent.run_profiles.ci_fix.provider openrouter is not supported with workers.ssh_hosts"
    end

    test "SSH workers are fine when no run uses openrouter" do
      symphony = Map.put(symphony(%{"run_profiles" => %{"qa" => %{"provider" => "anthropic"}}}), "workers", %{"ssh_hosts" => ["worker-01"]})
      {:ok, system} = SystemSchema.parse(symphony)

      assert {:ok, _settings} = Schema.parse(SystemSchema.to_config_map(system))
    end

    test "openrouter with a non-claude runtime names the key" do
      codex = %{"runtime" => "codex", "command" => "codex app-server"}

      assert error!(Map.merge(codex, %{"provider" => "openrouter", "model" => "openai/gpt-5"})) =~
               "agent.provider openrouter is only supported with agent.runtime: claude"

      message = error!(Map.merge(codex, %{"run_profiles" => %{"landing" => %{"provider" => "openrouter", "model" => "openai/gpt-5"}}}))

      assert message =~ "agent.run_profiles.landing.provider openrouter is only supported with agent.runtime: claude"
      refute message =~ "agent.provider "
    end

    test "anthropic is accepted with a codex runtime" do
      settings = settings!(%{"runtime" => "codex", "command" => "codex app-server", "provider" => "anthropic"})

      assert Config.run_profile(settings, :qa).provider == "anthropic"
    end
  end

  test "config without the new keys loads unchanged" do
    settings = settings!(%{})

    assert settings.agent.model == nil
    assert settings.agent.effort == nil
    assert settings.agent.provider == nil
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
      assert error!(%{"run_profiles" => %{"qa" => "fast"}}) =~ "agent.run_profiles.qa must be an object with model, effort and/or provider"
    end

    test "unknown profile key" do
      message = error!(%{"run_profiles" => %{"qa" => %{"temperature" => 1}}})

      assert message =~ "agent.run_profiles.qa has unknown key `temperature`; expected model, effort or provider"
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
