defmodule SymphonyElixir.DispatchStateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DispatchState

  describe "compute/3" do
    test "returns active when nothing is blocking" do
      state = base_state()
      config = base_config()
      env = %{}

      assert %{active?: true, blockers: []} = DispatchState.compute(state, config, env)
    end

    test "usage-limit hold pauses dispatch only when it covers every run profile in use" do
      hold = %{
        provider: "anthropic",
        scope: :all,
        window: "five_hour",
        resets_at: ~U[2026-10-03 14:03:00Z],
        resume_at: ~U[2026-10-03 14:05:00Z],
        phase: :paused,
        reason: "claude_usage_limit",
        utilization: 1.0
      }

      state = Map.put(base_state(), :usage_limits, [hold])

      blocker = %{
        kind: :usage_limit,
        provider: "anthropic",
        scope: :all,
        window: "five_hour",
        resets_at: ~U[2026-10-03 14:03:00Z],
        resume_at: ~U[2026-10-03 14:05:00Z],
        phase: :paused
      }

      anthropic_only = base_config(%{run_profiles: [%{provider: "anthropic", model: "claude-opus-4"}, %{provider: "anthropic", model: nil}]})
      assert %{active?: false, blockers: [^blocker]} = DispatchState.compute(state, anthropic_only, full_env())

      mixed = base_config(%{run_profiles: [%{provider: "anthropic", model: nil}, %{provider: "openrouter", model: "z-ai/glm-4.6"}]})
      assert %{active?: true, blockers: [^blocker]} = DispatchState.compute(state, mixed, full_env())

      # An Opus-only hold leaves Sonnet runs dispatching.
      opus_hold = %{hold | scope: "opus", window: "seven_day_opus"}
      models = base_config(%{run_profiles: [%{provider: "anthropic", model: "claude-opus-4"}, %{provider: "anthropic", model: "claude-sonnet-4"}]})

      assert %{active?: true, blockers: [%{kind: :usage_limit, scope: "opus"}]} =
               DispatchState.compute(%{state | usage_limits: [opus_hold]}, models, full_env())

      assert %{active?: false} = DispatchState.compute(%{state | usage_limits: [opus_hold, hold]}, models, full_env())

      # Listed after the other blockers.
      paused = Map.put(state, :pause, %{paused: true, reason: nil, paused_at: nil})

      assert %{active?: false, blockers: [%{kind: :manual}, ^blocker]} =
               DispatchState.compute(paused, mixed, full_env())
    end

    test "manual pause blocker carries reason and timestamp" do
      paused_at = ~U[2026-05-08 10:00:00Z]

      state =
        base_state()
        |> Map.put(:pause, %{paused: true, reason: "investigating", paused_at: paused_at})

      result = DispatchState.compute(state, base_config(), full_env())

      assert result.active? == false
      assert [%{kind: :manual, reason: "investigating", since: ^paused_at}] = result.blockers
    end

    test "budget exhaustion blocker includes used/limit/reset" do
      state =
        base_state()
        |> Map.put(:budget_daily_used, 6_000_000)
        |> Map.put(:budget_day_started_on, ~D[2026-05-08])

      result = DispatchState.compute(state, base_config(), full_env())

      assert result.active? == false

      assert [
               %{
                 kind: :budget,
                 used: 6_000_000,
                 limit: 5_000_000,
                 day_started_on: ~D[2026-05-08],
                 resets_on: ~D[2026-05-09]
               }
             ] = result.blockers
    end

    test "workspace dirty state does not block dispatch" do
      state =
        base_state()
        |> Map.put(:workspace_dirty, %{repo: "/path/repo", summary: "M WORKFLOW.md"})

      result = DispatchState.compute(state, base_config(), full_env())

      assert result.active? == true
      assert result.blockers == []
    end

    test "disabled feature providers do not require api keys" do
      result = DispatchState.compute(base_state(), base_config(), %{})

      assert result.active? == true
      assert result.blockers == []
    end

    test "enabled anthropic quality gate requires anthropic api key" do
      config = base_config(%{quality_gate: feature_config(true, :anthropic)})

      result = DispatchState.compute(base_state(), config, %{"ANTHROPIC_API_KEY" => ""})

      assert [%{kind: :missing_api_key, provider: :anthropic}] = result.blockers
    end

    test "enabled openai quality gate requires openai api key" do
      config = base_config(%{quality_gate: feature_config(true, :openai)})

      result = DispatchState.compute(base_state(), config, %{"ANTHROPIC_API_KEY" => "sk-test"})

      assert [%{kind: :missing_api_key, provider: :openai}] = result.blockers
    end

    test "enabled features can require multiple provider api keys" do
      config =
        base_config(%{
          quality_gate: feature_config(true, :anthropic),
          learnings: feature_config(true, :openai)
        })

      result = DispatchState.compute(base_state(), config, %{})

      assert [
               %{kind: :missing_api_key, provider: :anthropic},
               %{kind: :missing_api_key, provider: :openai}
             ] = result.blockers
    end

    test "present provider api keys satisfy enabled feature checks" do
      config =
        base_config(%{
          quality_gate: feature_config(true, :anthropic),
          learnings: feature_config(true, :openai)
        })

      result = DispatchState.compute(base_state(), config, full_env())

      assert result.active? == true
      assert result.blockers == []
    end

    test "missing api key blockers are de-duped by provider" do
      config =
        base_config(%{
          quality_gate: feature_config(true, "openai"),
          learnings: feature_config(true, "openai")
        })

      result = DispatchState.compute(base_state(), config, %{})

      assert [%{kind: :missing_api_key, provider: :openai}] = result.blockers
    end

    test "missing feature sections and unsupported providers do not require api keys" do
      config = %{
        daily_limit: 5_000_000,
        quality_gate: feature_config(true, :unsupported)
      }

      result = DispatchState.compute(base_state(), config, %{})

      assert result.active? == true
      assert result.blockers == []
    end

    test "linear tracker without api key emits missing_api_key blocker" do
      config =
        base_config(%{tracker_kind: "linear", tracker_api_key_present?: false})

      result = DispatchState.compute(base_state(), config, full_env())

      assert result.active? == false
      assert [%{kind: :missing_api_key, provider: :linear}] = result.blockers
    end

    test "linear tracker with api key present does not block" do
      config =
        base_config(%{tracker_kind: "linear", tracker_api_key_present?: true})

      result = DispatchState.compute(base_state(), config, full_env())

      assert result.active? == true
      assert result.blockers == []
    end

    test "non-linear tracker without api key does not block" do
      config =
        base_config(%{tracker_kind: "memory", tracker_api_key_present?: false})

      result = DispatchState.compute(base_state(), config, full_env())

      assert result.active? == true
      assert result.blockers == []
    end

    test "tracker health stays active below unavailable threshold" do
      state =
        base_state()
        |> Map.put(:tracker_health, %{
          tracker: :linear,
          reason: :missing_linear_api_token,
          since: ~U[2026-05-08 10:00:00Z],
          consecutive_failures: 2
        })

      result = DispatchState.compute(state, base_config(), full_env())

      assert result.active? == true
      assert result.blockers == []
    end

    test "tracker health emits unavailable blocker at threshold" do
      since = ~U[2026-05-08 10:00:00Z]

      state =
        base_state()
        |> Map.put(:tracker_health, %{
          tracker: :linear,
          reason: :missing_linear_api_token,
          since: since,
          consecutive_failures: 3
        })

      result = DispatchState.compute(state, base_config(), full_env())

      assert result.active? == false

      assert [
               %{
                 kind: :tracker_unavailable,
                 tracker: :linear,
                 reason: :missing_linear_api_token,
                 since: ^since,
                 consecutive_failures: 3
               }
             ] = result.blockers
    end

    test "tracker unavailable reason maps known request failures and unknown values" do
      state =
        base_state()
        |> Map.put(:tracker_health, %{
          tracker: "linear",
          reason: {:linear_api_request, :timeout},
          since: ~U[2026-05-08 10:00:00Z],
          consecutive_failures: 3
        })

      assert [%{reason: :linear_api_request}] =
               DispatchState.compute(state, base_config(), full_env()).blockers

      message = "notifications.channels entries with kind: slack require webhook_url"
      invalid_message = "Invalid WORKFLOW.md config: #{message}"
      state = put_in(state, [:tracker_health, :reason], {:invalid_workflow_config, message})

      assert [%{kind: :config_invalid, message: ^invalid_message}] =
               DispatchState.compute(state, base_config(), full_env()).blockers

      state = put_in(state, [:tracker_health, :reason], :missing_linear_scoping_filter)

      assert [%{kind: :config_invalid, message: "Linear scoping filter missing in WORKFLOW.md"}] =
               DispatchState.compute(state, base_config(), full_env()).blockers

      state = put_in(state, [:tracker_health, :reason], :rate_limited)

      assert [%{reason: :unknown}] =
               DispatchState.compute(state, base_config(), full_env()).blockers
    end

    test "tracker health config failures become config invalid blockers" do
      for {reason, expected_message} <- [
            {{:invalid_workflow_config, "WORKFLOW.md: agent.runtime is required"}, "Invalid WORKFLOW.md config: agent.runtime is required"},
            {{:invalid_workflow_config, "symphony.yml: repositories is invalid"}, "Invalid symphony.yml config: repositories is invalid"},
            {:missing_tracker_kind, "Tracker kind missing in WORKFLOW.md"},
            {{:unsupported_tracker_kind, "jira"}, ~s(Unsupported tracker kind in WORKFLOW.md: "jira")},
            {{:unsupported_agent_kind, "shell"}, ~s(Unsupported agent runtime in WORKFLOW.md: "shell")},
            {{:missing_workflow_file, "/tmp/missing/WORKFLOW.md", :enoent}, "Missing WORKFLOW.md at /tmp/missing/WORKFLOW.md: :enoent"},
            {:workflow_front_matter_not_a_map, "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"},
            {{:workflow_parse_error, {:unexpected_token, "["}}, ~s(Failed to parse WORKFLOW.md: {:unexpected_token, "["})},
            {{:config_invalid, "Existing normalized message"}, "Existing normalized message"}
          ] do
        state =
          base_state()
          |> Map.put(:tracker_health, %{
            tracker: "linear",
            reason: reason,
            since: ~U[2026-05-08 10:00:00Z],
            consecutive_failures: 3
          })

        assert [%{kind: :config_invalid, message: ^expected_message}] =
                 DispatchState.compute(state, base_config(), full_env()).blockers
      end
    end

    test "tracker unavailable supports custom thresholds and tracker normalization" do
      base_health = %{
        reason: :missing_linear_api_token,
        since: ~U[2026-05-08 10:00:00Z],
        consecutive_failures: 2
      }

      config = base_config(%{tracker_unavailable_threshold: 2})

      assert [%{tracker: :memory}] =
               base_state()
               |> Map.put(:tracker_health, Map.put(base_health, :tracker, :memory))
               |> DispatchState.compute(config, full_env())
               |> Map.fetch!(:blockers)

      assert [%{tracker: :memory}] =
               base_state()
               |> Map.put(:tracker_health, Map.put(base_health, :tracker, "memory"))
               |> DispatchState.compute(config, full_env())
               |> Map.fetch!(:blockers)

      assert [%{tracker: :github}] =
               base_state()
               |> Map.put(:tracker_health, Map.put(base_health, :tracker, :github))
               |> DispatchState.compute(config, full_env())
               |> Map.fetch!(:blockers)

      assert [%{tracker: :unknown}] =
               base_state()
               |> Map.put(:tracker_health, Map.put(base_health, :tracker, 123))
               |> DispatchState.compute(config, full_env())
               |> Map.fetch!(:blockers)
    end

    test "all blockers stack" do
      state =
        base_state()
        |> Map.put(:pause, %{paused: true, reason: "stop", paused_at: ~U[2026-05-08 10:00:00Z]})
        |> Map.put(:budget_daily_used, 10_000_000)
        |> Map.put(:budget_day_started_on, ~D[2026-05-08])
        |> Map.put(:workspace_dirty, %{repo: "/r", summary: "M f"})
        |> Map.put(:tracker_health, %{
          tracker: :linear,
          reason: :linear_api_request,
          since: ~U[2026-05-08 10:05:00Z],
          consecutive_failures: 3
        })

      config =
        base_config(%{
          quality_gate: feature_config(true, :anthropic),
          tracker_kind: "linear",
          tracker_api_key_present?: false
        })

      result = DispatchState.compute(state, config, %{"ANTHROPIC_API_KEY" => ""})

      kinds = Enum.map(result.blockers, & &1.kind)
      assert :manual in kinds
      assert :budget in kinds
      assert :missing_api_key in kinds
      assert :tracker_unavailable in kinds
      assert result.active? == false
    end
  end

  defp base_state do
    %{
      pause: %{paused: false, reason: nil, paused_at: nil},
      budget_daily_used: 0,
      budget_day_started_on: ~D[2026-05-08],
      workspace_dirty: nil
    }
  end

  defp base_config(overrides \\ %{}) do
    %{
      daily_limit: 5_000_000,
      quality_gate: feature_config(false, :anthropic),
      learnings: feature_config(false, :anthropic)
    }
    |> Map.merge(overrides)
  end

  defp feature_config(enabled, provider), do: %{enabled: enabled, provider: provider}

  defp full_env, do: %{"ANTHROPIC_API_KEY" => "sk-test", "OPENAI_API_KEY" => "sk-test"}
end
