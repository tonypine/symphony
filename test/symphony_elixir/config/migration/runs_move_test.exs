defmodule SymphonyElixir.Config.Migration.RunsMoveTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Migration
  alias SymphonyElixir.Config.Migration.{RunsMove, RunsRewrite}
  alias SymphonyElixir.Config.SystemSchema

  @backup "symphony.yml.before-v1"
  @repositories [%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "T"}}]

  defp claude(extra \\ %{}), do: Map.merge(%{"runtime" => "claude", "command" => "claude --verbose", "model" => "claude-opus-5-5"}, extra)

  defp moved!(document) do
    assert {:ok, moved} = RunsMove.document(document)
    moved
  end

  describe "needed?/1" do
    test "a file with an agent section, or a repository's agent block, has something to move" do
      assert RunsMove.needed?(%{"agent" => %{"runtime" => "claude"}})
      assert RunsMove.needed?(%{"repositories" => [%{"key" => "a"}, %{"key" => "b", "agent" => %{"model" => "m"}}]})

      refute RunsMove.needed?(%{"execution" => %{}, "repositories" => [%{"key" => "a"}]})
      refute RunsMove.needed?(%{"agent" => "nothing", "repositories" => "none"})
      refute RunsMove.needed?(%{"repositories" => ["a", %{"agent" => "nothing"}]})
    end
  end

  describe "document/1" do
    test "the harness, its command, and what every run starts with" do
      agent = claude(%{"effort" => "medium", "concurrency" => %{"max_total" => 2}})
      moved = moved!(%{"agent" => agent, "repositories" => @repositories, "issues" => %{"provider" => "memory"}})

      assert moved["execution"] == %{
               "harnesses" => %{"claude" => %{"command" => "claude --verbose", "small_model" => %{"anthropic" => "claude-haiku-5-5"}}},
               "concurrency" => %{"max_total" => 2}
             }

      assert moved["runs"] == %{"default" => %{"harness" => "claude", "provider" => "anthropic", "model" => "claude-opus-5-5", "effort" => "medium"}}
      refute Map.has_key?(moved, "agent")
      assert {:ok, _system} = SystemSchema.parse(moved)
    end

    test "a model and an effort the command passed leave it and become the run's" do
      moved = moved!(%{"agent" => %{"runtime" => "claude", "command" => "claude --model claude-opus-4-7 --effort=high --verbose"}})

      assert moved["execution"]["harnesses"]["claude"]["command"] == "claude --verbose"
      assert %{"model" => "claude-opus-4-7", "effort" => "high"} = moved["runs"]["default"]

      codex = ~s(codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server)
      moved = moved!(%{"agent" => %{"runtime" => "codex", "command" => codex}})

      assert moved["execution"]["harnesses"] == %{
               "codex" => %{"command" => "codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=high app-server"}
             }

      assert moved["runs"]["default"] == %{"harness" => "codex", "provider" => "openai", "model" => "gpt-5.5"}
    end

    test "run profiles become run kinds, without the kinds that no longer run" do
      profiles = %{
        "landing" => %{"model" => "claude-sonnet-5-5", "effort" => "low"},
        "close_out" => %{"model" => "x"},
        "final_verification" => %{"model" => "x"},
        "acceptance_gate" => %{"effort" => "low"},
        "pre_push_review" => %{"model" => "x"},
        :qa => %{effort: "high", runtime: "claude"},
        "breakdown" => "xhigh"
      }

      moved = moved!(%{"agent" => claude(%{"run_profiles" => profiles})})

      assert Map.delete(moved["runs"], "default") == %{
               "landing" => %{"model" => "claude-sonnet-5-5", "effort" => "low"},
               "qa" => %{"effort" => "high"},
               "breakdown" => %{}
             }
    end

    test "a claude run on another provider keeps sending background calls where it did" do
      profiles = %{"landing" => %{"provider" => "openrouter", "model" => "acme/chat"}, "ci_fix" => %{"effort" => "low"}}

      own_model = moved!(%{"agent" => claude(%{"run_profiles" => profiles})})
      assert own_model["runs"]["landing"]["small_model"] == "acme/chat"
      refute Map.has_key?(own_model["runs"]["ci_fix"], "small_model")
      refute Map.has_key?(own_model["runs"]["default"], "small_model")

      set = moved!(%{"agent" => claude(%{"run_profiles" => profiles, "small_model" => "acme/small"})})
      assert set["runs"]["landing"]["small_model"] == "acme/small"

      everywhere = moved!(%{"agent" => claude(%{"provider" => "openrouter", "model" => "acme/chat"})})
      assert everywhere["runs"]["default"]["small_model"] == "acme/chat"
      assert everywhere["execution"]["harnesses"] == %{"claude" => %{"command" => "claude --verbose"}}
    end

    test "the reviewer's and the QA agent's own settings become their run kinds" do
      document = %{
        "agent" => claude(%{"run_profiles" => %{"code_review" => %{"effort" => "xhigh"}}}),
        "code_review" => %{"enabled" => true, "runtime" => "claude", "command" => "claude --model claude-opus-4-7 --review"},
        "auto_review" => %{"runtime" => "codex", "command" => "codex app-server", "model" => "gpt-5.5", "max_turns" => 9, "acceptance_gate" => %{"runtime" => "claude"}}
      }

      moved = moved!(document)

      assert moved["runs"]["code_review"] == %{"effort" => "xhigh", "command" => "claude --review", "model" => "claude-opus-4-7"}
      assert moved["runs"]["qa"] == %{"harness" => "codex", "provider" => "openai", "command" => "codex app-server", "model" => "gpt-5.5"}
      assert moved["code_review"] == %{"enabled" => true}
      assert moved["auto_review"] == %{"max_turns" => 9, "acceptance_gate" => %{"runtime" => "claude"}}
    end

    test "a claude reviewer beside a codex default brings Anthropic's small model" do
      document = %{
        "agent" => %{"runtime" => "codex", "command" => "codex app-server", "model" => "gpt-5.5"},
        "code_review" => %{"runtime" => "claude", "command" => "claude", "model" => "claude-opus-5-5"}
      }

      assert moved!(document)["execution"]["harnesses"] == %{
               "codex" => %{"command" => "codex app-server"},
               "claude" => %{"small_model" => %{"anthropic" => "claude-haiku-5-5"}}
             }
    end

    test "the sandbox and the MCP servers name a harness, not a runtime" do
      agent =
        claude(%{
          "permissions" => %{"outer_sandbox" => %{"runtime" => "none", "command" => "srt"}, "network" => %{"mode" => "allowlist"}},
          "mcp" => %{"servers" => %{"docs" => %{"command" => "docs", "runtimes" => ["claude"]}, "plain" => %{"command" => "p"}, "odd" => "x"}}
        })

      execution = moved!(%{"agent" => agent})["execution"]

      assert execution["permissions"] == %{"outer_sandbox" => %{"kind" => "none", "command" => "srt"}, "network" => %{"mode" => "allowlist"}}
      assert execution["mcp"]["servers"] == %{"docs" => %{"command" => "docs", "harnesses" => ["claude"]}, "plain" => %{"command" => "p"}, "odd" => "x"}

      assert moved!(%{"agent" => claude(%{"permissions" => "x", "mcp" => %{"servers" => "none"}})})["execution"]["permissions"] == "x"
    end

    test "a repository's agent block becomes its runs" do
      repositories = [
        %{"key" => "api", "agent" => %{"provider" => "openrouter", "model" => "acme/chat", "run_profiles" => %{"breakdown" => %{"effort" => "xhigh"}, "close_out" => %{}}}},
        %{"key" => "web", "agent" => %{"run_profiles" => %{"qa" => %{"model" => "claude-haiku-5-5"}}}},
        %{"key" => "bare", "agent" => %{}},
        %{"key" => "odd", "agent" => "nothing"},
        %{"key" => "none"},
        "text"
      ]

      assert [api, web, bare, odd, none, "text"] = moved!(%{"agent" => claude(), "repositories" => repositories})["repositories"]

      assert api["runs"] == %{
               "default" => %{"provider" => "openrouter", "model" => "acme/chat", "small_model" => "acme/chat"},
               "breakdown" => %{"effort" => "xhigh"}
             }

      assert web == %{"key" => "web", "runs" => %{"qa" => %{"model" => "claude-haiku-5-5"}}}
      assert bare == %{"key" => "bare"}
      assert odd == %{"key" => "odd"}
      assert none == %{"key" => "none"}
      assert moved!(%{"agent" => claude(), "repositories" => "none"})["repositories"] == "none"
    end

    test "what cannot be moved names the key to set" do
      assert RunsMove.document(%{"agent" => %{"runtime" => "shell", "command" => "sh"}}) ==
               {:error, "`agent.runtime` must be claude or codex to move it to `runs.default.harness`"}

      assert RunsMove.document(%{"agent" => %{"runtime" => "claude"}}) ==
               {:error, "`agent.command` must be set to move it to `execution.harnesses.claude.command`"}

      assert RunsMove.document(%{"agent" => %{"runtime" => "claude", "command" => "claude"}}) ==
               {:error, "no model is set for the runs; set `agent.model`, which becomes `runs.default.model`"}

      assert RunsMove.document(%{"agent" => claude(), "code_review" => %{"runtime" => "shell", "command" => "sh", "model" => "m"}}) ==
               {:error, "`code_review.runtime` must be claude or codex to move it to `runs`"}

      assert RunsMove.document(%{"agent" => claude(), "auto_review" => %{"runtime" => "codex", "command" => "codex app-server"}}) ==
               {:error, "`auto_review` runs codex with no model; set `auto_review.model`"}
    end

    test "names the keys that move" do
      assert RunsMove.run_keys() == ["runtime", "command", "model", "effort", "provider", "small_model", "run_profiles"]
      assert RunsMove.section_run_keys() == ["runtime", "command", "model", "effort"]
      assert RunsMove.split_command(nil, "claude") == {nil, nil, nil}
      assert RunsMove.split_command("--model m", "claude") == {nil, "m", nil}
      assert RunsMove.repository_runs("nothing", %{}, nil) == %{}
    end
  end

  describe "the rewritten file" do
    @old """
    # My settings.
    issues:
      provider: memory

    agent: # who runs
      runtime: claude
      command: claude --dangerously-skip-permissions --verbose
      model: claude-opus-5-5
      effort: medium
      # 20 min until liveness is tracked per step.
      timeouts:
        stall_ms: 1200000
      run_profiles:
        close_out: { model: claude-sonnet-5-5 }
        landing: { model: claude-sonnet-5-5 }
      permissions:
        outer_sandbox:
          runtime: none
      mcp:
        servers:
          docs:
            command: docs
            runtimes: [claude]

    # The reviewer.
    code_review:
      enabled: true
      runtime: claude
      command: claude --dangerously-skip-permissions

    auto_review:
      model: claude-sonnet-5-5
      effort: low
    repositories:
      - key: api
        workflow: WORKFLOW.md
        agent:
          effort: high
          run_profiles:
            qa: { model: claude-haiku-5-5 }
      - key: web
        agent:
          run_profiles:
            close_out: { effort: low }
        workflow: WORKFLOW.md
    """

    test "agent is renamed where it stands, its run keys move, and every other line stays" do
      assert {:ok, migrated, [note]} = Migration.plan(@old, @backup)
      assert note == "v#{SymphonyElixir.BuildInfo.current().version} moved `agent` to `execution` and `runs` in your settings"

      assert migrated == """
             # My settings.
             issues:
               provider: memory

             # Symphony: #{note}. The file as it was: #{@backup}.
             execution: # who runs
               harnesses:
                 claude:
                   command: claude --dangerously-skip-permissions --verbose
                   small_model:
                     anthropic: claude-haiku-5-5
               # 20 min until liveness is tracked per step.
               timeouts:
                 stall_ms: 1200000
               permissions:
                 outer_sandbox:
                   kind: none
               mcp:
                 servers:
                   docs:
                     command: docs
                     harnesses: [claude]

             runs:
               default: { harness: claude, provider: anthropic, model: claude-opus-5-5, effort: medium }
               landing: { model: claude-sonnet-5-5 }
               code_review: { command: claude --dangerously-skip-permissions }
               qa: { model: claude-sonnet-5-5, effort: low }

             # The reviewer.
             code_review:
               enabled: true

             auto_review: {}
             repositories:
               - key: api
                 workflow: WORKFLOW.md
                 runs:
                   default: { effort: high }
                   qa: { model: claude-haiku-5-5 }
               - key: web
                 workflow: WORKFLOW.md
             """

      assert {:ok, document} = YamlElixir.read_from_string(migrated)
      assert Migration.plan(migrated, @backup) == {:ok, migrated, []}
      assert RunsMove.document(elem(YamlElixir.read_from_string(@old), 1)) == {:ok, document}
    end

    test "a value YAML would read as something else is quoted" do
      text = "agent:\n  runtime: claude\n  command: 'claude --flag \"a: b\"'\n  model: '1.5'\n  run_profiles:\n    qa: { model: 'on' }\n"

      assert {:ok, migrated, [_note]} = Migration.plan(text, @backup)
      assert migrated =~ ~s(command: "claude --flag \\"a: b\\"")
      assert migrated =~ ~s(default: { harness: claude, provider: anthropic, model: "1.5" })
      assert migrated =~ ~s(qa: { model: "on" })
    end

    test "a file that cannot be moved says which key to set" do
      assert {:error, {:runs_not_moved, message} = reason} = Migration.plan("agent:\n  runtime: claude\n  command: claude\n", @backup)
      assert message =~ "set `agent.model`"

      assert Migration.format_error(reason) ==
               "The `agent` section moved to `execution` and `runs`, and this file can't be moved as it is: " <> message
    end

    test "an agent section that is not written as a block names its line" do
      text = "issues:\n  provider: memory\nagent: {runtime: claude, command: claude, model: m}\n"
      assert Migration.plan(text, @backup) == {:error, {:not_migrated, [{"agent", 3}]}}

      {:ok, document} = YamlElixir.read_from_string(text)
      assert RunsRewrite.plan(text, document, @backup, "1") == {:error, {:not_migrated, [{"agent", 3}]}}
    end
  end
end
