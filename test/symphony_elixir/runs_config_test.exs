defmodule SymphonyElixir.RunsConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Runs.Run
  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.RunKind

  @claude %{"command" => "claude --dangerously-skip-permissions", "small_model" => %{"anthropic" => "claude-haiku-4-5", "openrouter" => "acme/small"}}
  @default %{"harness" => "claude", "provider" => "anthropic", "model" => "claude-opus-5-5"}

  defp symphony(extra \\ %{}) do
    Map.merge(
      %{
        "issues" => %{"provider" => "memory"},
        "execution" => %{"harnesses" => %{"claude" => @claude, "codex" => %{"command" => "codex app-server"}}},
        "runs" => %{"default" => @default},
        "repositories" => [%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}]
      },
      extra
    )
  end

  defp settings!(extra \\ %{}, repository_runs \\ nil) do
    {:ok, system} = SystemSchema.parse(symphony(extra))
    config = SystemSchema.to_config_map(system)
    config = if repository_runs, do: Map.put(config, "repository_runs", repository_runs), else: config
    {:ok, settings} = Schema.parse(config)
    settings
  end

  defp error!(extra) do
    assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(symphony(extra))
    message
  end

  describe "Config.run/2" do
    test "every run kind takes what default sets, with the harness's command and small model" do
      settings = settings!()

      for kind <- RunKind.kinds() do
        assert Config.run(settings, kind) == %Run{
                 kind: kind,
                 harness: "claude",
                 command: "claude --dangerously-skip-permissions",
                 provider: "anthropic",
                 model: "claude-opus-5-5",
                 effort: nil,
                 small_model: "claude-haiku-4-5"
               }
      end

      assert Config.run(settings, "landing").kind == :landing
    end

    test "a run kind's entry overrides default field by field, and may bring its own command" do
      settings =
        settings!(%{
          "runs" => %{
            "default" => Map.put(@default, "effort", "medium"),
            "breakdown" => %{"effort" => "xhigh"},
            "ci_fix" => %{"provider" => "openrouter", "model" => " acme/flash "},
            "qa" => %{"harness" => "codex", "provider" => "openai", "model" => "gpt-5.5"},
            "code_review" => %{"command" => "claude --review"}
          }
        })

      assert %Run{model: "claude-opus-5-5", effort: "xhigh"} = Config.run(settings, :breakdown)
      assert %Run{provider: "openrouter", model: "acme/flash", effort: "medium", small_model: "acme/small"} = Config.run(settings, :ci_fix)
      assert %Run{harness: "codex", command: "codex app-server", provider: "openai", small_model: nil} = Config.run(settings, :qa)
      assert %Run{command: "claude --review", harness: "claude"} = Config.run(settings, :code_review)
      assert Config.run_kinds_on(settings, "openrouter") == ["ci_fix"]
      assert Config.run_kinds_on(settings, "openai") == ["qa"]
    end

    test "the routed repository's block comes first, and run_key/3 names the entry that set a field" do
      repository_runs = %{"path" => "repositories[app].runs", "runs" => %{"default" => %{"effort" => "low"}, "landing" => %{"model" => "claude-haiku-4-5"}}}
      settings = settings!(%{"runs" => %{"default" => @default, "landing" => %{"model" => "claude-sonnet-5-5", "effort" => "high"}}}, repository_runs)

      assert Config.repository_runs(settings) == {"repositories[app].runs", repository_runs["runs"]}
      assert %Run{model: "claude-haiku-4-5", effort: "low"} = Config.run(settings, :landing)
      assert Config.run_key(settings, :landing, :model) == "repositories[app].runs.landing.model"
      assert Config.run_key(settings, :landing, :effort) == "repositories[app].runs.default.effort"
      assert Config.run_key(settings, :landing, :harness) == "runs.default.harness"
      assert Config.run_key(settings, :landing, :command) == nil

      assert Config.repository_runs(settings!()) == nil
    end

    test "raises on settings that never loaded" do
      {:ok, settings} = Schema.parse(%{})
      assert_raise ArgumentError, ~r/runs.qa resolves no harness/, fn -> Config.run(settings, :qa) end
    end
  end

  describe "loading symphony.yml" do
    test "nothing is built in: a run kind that resolves no harness, provider or model does not load" do
      assert error!(%{"runs" => %{}}) =~ "runs.implementation resolves no harness; set `harness` there or in runs.default"
      assert error!(%{"runs" => %{"default" => Map.delete(@default, "provider")}}) =~ "runs.qa resolves no provider"
      assert error!(%{"runs" => %{"default" => Map.delete(@default, "model")}}) =~ "runs.landing resolves no model"
    end

    test "a wrong entry, harness or pairing names its key" do
      assert error!(%{"runs" => %{"default" => @default, "close_out" => %{}}}) =~ "runs.close_out is not a run kind"
      assert error!(%{"runs" => %{"default" => Map.put(@default, "runtime", "claude")}}) =~ "runs.default has unknown key `runtime`"
      assert error!(%{"runs" => %{"default" => @default, "qa" => %{"harness" => "codex"}}}) =~ "runs.qa runs the codex harness on anthropic, which it cannot reach"

      assert error!(%{"runs" => %{"default" => @default, "qa" => %{"provider" => "opencode-go"}}}) =~
               "set execution.harnesses.claude.small_model.opencode-go"

      assert error!(%{"execution" => %{"harnesses" => %{"claude" => Map.put(@claude, "command", "claude --model opus")}}}) =~
               "execution.harnesses.claude.command must not pass --model"

      assert error!(%{"execution" => %{"harnesses" => %{}}}) =~ "runs.qa runs the claude harness, which has no command; set execution.harnesses.claude.command"
    end

    test "a repository's block is checked with its own key" do
      repositories = [%{"key" => "web", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}, "runs" => %{"landing" => %{"provider" => "openai"}}}]

      assert error!(%{"repositories" => repositories}) ==
               "repositories[web].runs.landing runs the claude harness on openai, which it cannot reach; claude runs on: anthropic, openrouter, opencode-go"

      bad_key = [%{"key" => "web", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}, "runs" => %{"landing" => %{"effort" => "extreme"}}}]
      assert error!(%{"repositories" => bad_key}) == "repositories[web].runs.landing.effort must be one of: low, medium, high, xhigh, max"
    end

    test "the old agent section and its per-section run settings are not keys any more" do
      assert error!(%{"agent" => %{"runtime" => "claude"}}) == "unknown symphony.yml key `agent`"
      assert error!(%{"code_review" => %{"enabled" => true, "runtime" => "claude"}}) =~ "code_review"
      assert error!(%{"auto_review" => %{"model" => "claude-opus-5-5"}}) =~ "auto_review"
    end

    test "the operator key paths list runs and the harness map as one setting each" do
      paths = SystemSchema.operator_key_paths()

      assert "runs" in paths
      assert "execution.harnesses" in paths
      assert "repositories[].runs" in paths
      assert "execution.permissions.outer_sandbox.kind" in paths
      refute Enum.any?(paths, &String.starts_with?(&1, "agent"))
      refute "code_review.runtime" in paths
    end
  end

  describe "Config.for_run/2" do
    test "the run's harness, command and run sit on execution, with the approval policy its harness defaults to" do
      settings = settings!(%{"runs" => %{"default" => @default, "qa" => %{"harness" => "codex", "provider" => "openai", "model" => "gpt-5.5"}}})

      assert settings.execution.harness == nil
      assert settings.execution.approval_policy == nil

      claude = Config.for_run(settings, Config.run(settings, :implementation))
      assert %{harness: "claude", command: "claude --dangerously-skip-permissions", approval_policy: "never"} = claude.execution
      assert claude.execution.run == Config.run(settings, :implementation)

      codex = Config.for_run(settings, Config.run(settings, :qa))
      assert %{harness: "codex", command: "codex app-server", approval_policy: %{"reject" => %{"rules" => true}}} = codex.execution
    end

    test "an approval policy the operator set is kept" do
      settings = settings!(%{"execution" => %{"harnesses" => %{"claude" => @claude}, "permissions" => %{"approval_policy" => "auto_approve_all"}}})
      assert Config.for_run(settings, Config.run(settings, :qa)).execution.approval_policy == "auto_approve_all"
    end

    test "settings whose execution section does not suit a run kind's harness do not load" do
      codex = %{"default" => %{"harness" => "codex", "provider" => "openai", "model" => "gpt-5.5"}}
      harnesses = %{"claude" => @claude, "codex" => %{"command" => "codex app-server"}}

      error = fn extra ->
        {:ok, system} = SystemSchema.parse(symphony(extra))
        assert {:error, {:invalid_workflow_config, message}} = Schema.parse(SystemSchema.to_config_map(system))
        message
      end

      assert error.(%{"runs" => codex, "execution" => %{"harnesses" => harnesses, "permissions" => %{"approval_policy" => "never"}}}) ==
               ~s(execution.permissions.approval_policy="never" is not supported on the codex harness; use "auto_approve_all" for unattended auto-approval) <>
                 " (runs.implementation runs the codex harness)"

      srt = %{"harnesses" => harnesses, "permissions" => %{"outer_sandbox" => %{"kind" => "srt"}, "network" => %{"mode" => "open"}}}

      assert error.(%{"runs" => codex, "execution" => srt}) =~
               ~s(execution.permissions.outer_sandbox.kind="srt" does not support execution.permissions.network.mode="open")

      assert error.(%{"execution" => srt}) ==
               ~s|execution.permissions.outer_sandbox.kind="srt" is only supported on the codex harness (runs.implementation runs the claude harness)|

      assert error.(%{"execution" => %{"harnesses" => harnesses, "mcp" => %{"inherit" => "all"}}}) =~
               ~s(execution.mcp.inherit="all" is not supported on the claude harness)
    end

    test "raises for a run the settings do not suit" do
      settings = settings!()
      settings = %{settings | execution: %{settings.execution | approval_policy: "never"}}
      run = %Run{kind: :qa, harness: "codex", command: "codex app-server", provider: "openai", model: "gpt-5.5"}

      assert_raise ArgumentError, ~r/approval_policy="never" is not supported on the codex harness/, fn -> Config.for_run(settings, run) end
    end
  end

  describe "Config.validate!/0" do
    test "what execution sets must suit every run kind's harness" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude", agent_command: "claude", agent_mcp: %{inherit: "all"})

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ ~s(execution.mcp.inherit="all" is not supported on the claude harness)
    end

    test "a provider whose key travels in the local env cannot serve an SSH worker" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        agent_command: "claude",
        agent_run_profiles: %{landing: %{provider: "openrouter", model: "acme/chat"}},
        worker_ssh_hosts: ["worker-a"]
      )

      assert Config.validate!() ==
               {:error, {:invalid_workflow_config, "repo default: runs.landing.provider openrouter is not supported with workers.ssh_hosts; OpenRouter runs start on the local host only"}}
    end

    test "a provider that needs no key from Symphony may serve an SSH worker" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex", worker_ssh_hosts: ["worker-a"])
      assert Config.validate!() == :ok
    end
  end
end
