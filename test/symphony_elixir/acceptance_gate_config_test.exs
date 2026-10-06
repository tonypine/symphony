defmodule SymphonyElixir.AcceptanceGateConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AcceptanceGate.Settings
  alias SymphonyElixir.AcceptanceGate.Settings.Escalate
  alias SymphonyElixir.Config.{RepoWorkflowSchema, Schema, SystemSchema}

  defp symphony(sections, repo_fields \\ %{}) do
    Map.merge(
      %{
        "issues" => %{"provider" => "memory"},
        "agent" => %{"runtime" => "claude", "command" => "claude --dangerously-skip-permissions"},
        "repositories" => [Map.merge(%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}, repo_fields)]
      },
      sections
    )
  end

  defp gate(fields), do: %{"auto_review" => %{"acceptance_gate" => fields}}

  defp settings!(sections) do
    {:ok, system} = SystemSchema.parse(symphony(sections))
    {:ok, settings} = Schema.parse(SystemSchema.to_config_map(system))
    settings
  end

  defp error!(sections, repo_fields \\ %{}) do
    assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(symphony(sections, repo_fields))
    message
  end

  defp repo(key, labels, acceptance_gate) do
    %{
      "name" => key,
      "path" => Path.dirname(Workflow.workflow_file_path()),
      "workflow" => Path.basename(Workflow.workflow_file_path()),
      "team" => "Test",
      "labels" => labels,
      "acceptance_gate" => acceptance_gate
    }
  end

  defp write_repos!(repos, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge([tracker_kind: "memory", agent_kind: "claude", agent_command: "claude", repos: repos], overrides)
    )
  end

  describe "parsing" do
    test "a global block and a repository override parse" do
      sections =
        gate(%{
          "mode" => "enforce",
          "runtime" => "codex",
          "command" => "codex app-server",
          "model" => "gpt-5",
          "effort" => "high",
          "max_turns" => 8,
          "timeout_ms" => 60_000,
          "max_concurrent" => 3,
          "escalate" => %{
            "labels" => ["risky"],
            "ticket_patterns" => ["(?i)do not ship"],
            "paths" => ["infra/**"],
            "diff_patterns" => ["(?i)\\bgrant\\s+all\\b"],
            "dependencies" => "any",
            "max_changed_lines" => 800,
            "busy_files" => %{"top" => 5, "window_days" => 7, "max_lines" => 100},
            "inconclusive_limit" => 3
          }
        })

      repo_fields = %{"acceptance_gate" => %{"mode" => "shadow", "max_turns" => 4, "escalate" => %{"paths" => ["lib/app/auth.ex"], "busy_files" => %{"max_lines" => 50}}}}

      assert {:ok, system} = SystemSchema.parse(symphony(sections, repo_fields))
      assert %Settings{mode: "enforce", kind: "codex", max_turns: 8, max_concurrent: 3} = gate = system.auto_review.acceptance_gate
      assert %Escalate{dependencies: "any", max_changed_lines: 800, inconclusive_limit: 3} = gate.escalate
      assert gate.escalate.labels == Escalate.built_in().labels ++ ["risky"]
      assert gate.escalate.busy_files.top == 5

      [repo] = system.repos
      assert %{"mode" => "shadow", "max_turns" => 4, "timeout_ms" => 60_000, "kind" => "codex"} = repo.acceptance_gate
      assert repo.acceptance_gate["escalate"]["paths"] == Escalate.built_in().paths ++ ["infra/**", "lib/app/auth.ex"]
      assert repo.acceptance_gate["escalate"]["busy_files"] == %{"top" => 5, "window_days" => 7, "max_lines" => 50}
    end

    test "an unknown mode is rejected, naming the key" do
      assert error!(gate(%{"mode" => "on"})) =~ "auto_review.acceptance_gate.mode must be one of: off, shadow, enforce"

      assert error!(%{}, %{"acceptance_gate" => %{"mode" => "loud"}}) =~
               "repositories[app].acceptance_gate.mode must be one of: off, shadow, enforce"
    end

    test "an unknown key is rejected, naming the key" do
      assert error!(gate(%{"bogus" => 1})) =~ "unknown symphony.yml key `auto_review.acceptance_gate.bogus`"
      assert error!(gate(%{"escalate" => %{"globs" => []}})) =~ "unknown symphony.yml key `auto_review.acceptance_gate.escalate.globs`"

      assert error!(gate(%{"escalate" => %{"busy_files" => %{"days" => 3}}})) =~
               "unknown symphony.yml key `auto_review.acceptance_gate.escalate.busy_files.days`"

      assert error!(gate(%{"kind" => "claude"})) =~ "`auto_review.acceptance_gate.kind` is not valid; use `auto_review.acceptance_gate.runtime`"
      assert error!(%{}, %{"acceptance_gate" => %{"kind" => "claude"}}) =~ "unknown symphony.yml key `repositories[app].acceptance_gate.kind`"
      assert error!(%{}, %{"acceptance_gate" => %{"runtime" => "claude"}}) =~ "unknown symphony.yml key `repositories[app].acceptance_gate.runtime`"
      assert error!(%{}, %{"acceptance_gate" => %{"max_concurrent" => 4}}) =~ "unknown symphony.yml key `repositories[app].acceptance_gate.max_concurrent`"
      assert error!(%{}, %{"acceptance_gate" => %{"escalate" => %{"globs" => []}}}) =~ "unknown symphony.yml key `repositories[app].acceptance_gate.escalate.globs`"
    end

    test "invalid values name the key" do
      assert error!(gate("off")) =~ "`auto_review.acceptance_gate` must be an object"
      assert error!(gate(%{"escalate" => []})) =~ "`auto_review.acceptance_gate.escalate` must be an object"
      assert error!(gate(%{"runtime" => "gpt"})) =~ "auto_review.acceptance_gate.runtime is invalid"
      assert error!(gate(%{"effort" => "extreme"})) =~ "auto_review.acceptance_gate.effort must be one of: low, medium, high, xhigh, max"
      assert error!(gate(%{"max_turns" => 0})) =~ "auto_review.acceptance_gate.max_turns must be greater than 0"
      assert error!(gate(%{"escalate" => %{"dependencies" => "minor"}})) =~ "auto_review.acceptance_gate.escalate.dependencies must be one of: off, major, any"
      assert error!(gate(%{"escalate" => %{"max_changed_lines" => 0}})) =~ "auto_review.acceptance_gate.escalate.max_changed_lines must be a positive integer"
      assert error!(gate(%{"escalate" => %{"busy_files" => %{"top" => "ten"}}})) =~ "auto_review.acceptance_gate.escalate.busy_files.top must be a positive integer"
      assert error!(gate(%{"escalate" => %{"busy_files" => %{"max_lines" => -1}}})) =~ "auto_review.acceptance_gate.escalate.busy_files.max_lines must be a positive integer"

      assert error!(gate(%{"escalate" => %{"ticket_patterns" => ["(unclosed"]}})) =~
               "auto_review.acceptance_gate.escalate.ticket_patterns has an invalid regular expression `(unclosed`: missing closing parenthesis"

      assert error!(%{}, %{"acceptance_gate" => %{"escalate" => %{"diff_patterns" => ["[a-"]}}}) =~
               "repositories[app].acceptance_gate.escalate.diff_patterns has an invalid regular expression `[a-`"

      assert error!(%{}, %{"acceptance_gate" => "shadow"}) =~ "`repositories[app].acceptance_gate` must be an object"
    end

    test "a repository's WORKFLOW.md can't set the gate" do
      assert {:error, {:invalid_repo_workflow_config, message}} = RepoWorkflowSchema.parse(%{"auto_review" => %{"acceptance_gate" => %{"mode" => "off"}}})
      assert message =~ "operator-level key `auto_review.acceptance_gate`"
    end
  end

  describe "defaults" do
    test "with no block the gate is off with the built-in rules" do
      gate = settings!(%{}).auto_review.acceptance_gate

      assert %Settings{mode: "off", kind: nil, model: nil, max_turns: 12, timeout_ms: 900_000, max_concurrent: 2} = gate

      assert %Escalate{dependencies: "major", max_changed_lines: 1500, inconclusive_limit: 2} = gate.escalate
      assert gate.escalate.busy_files == %Settings.BusyFiles{top: 10, window_days: 14, max_lines: 300}

      for {field, values} <- Escalate.built_in(), do: assert(Map.fetch!(gate.escalate, field) == values)
      assert "needs-human" in gate.escalate.labels
      assert "plan" in gate.escalate.labels
      assert "breakdown" in gate.escalate.labels
      assert ".github/workflows/**" in gate.escalate.paths
    end

    test "the effective settings of every repository say off when nothing sets the gate" do
      write_repos!([repo("api", ["api"], nil)])

      assert Config.settings_for_repo!("api").auto_review.acceptance_gate.mode == "off"
      assert Config.settings!().auto_review.acceptance_gate.escalate.paths == Escalate.built_in().paths
    end
  end

  describe "repository overrides" do
    test "add to the built-in and global lists and replace the mode and numbers" do
      write_repos!(
        [
          repo("api", ["api"], %{"mode" => "enforce", "timeout_ms" => 1000, "escalate" => %{"paths" => ["api/billing/**"], "labels" => ["money"], "max_changed_lines" => 200}}),
          repo("web", ["web"], nil)
        ],
        auto_review: %{"acceptance_gate" => %{"mode" => "shadow", "escalate" => %{"paths" => ["infra/**"]}}}
      )

      api = Config.settings_for_repo!("api").auto_review.acceptance_gate
      web = Config.settings_for_repo!("web").auto_review.acceptance_gate

      assert {api.mode, api.timeout_ms, api.escalate.max_changed_lines} == {"enforce", 1000, 200}
      assert api.escalate.paths == Escalate.built_in().paths ++ ["infra/**", "api/billing/**"]
      assert api.escalate.labels == Escalate.built_in().labels ++ ["money"]

      assert {web.mode, web.timeout_ms, web.escalate.max_changed_lines} == {"shadow", 900_000, 1500}
      assert web.escalate.paths == Escalate.built_in().paths ++ ["infra/**"]
    end

    test "can't remove a built-in default" do
      write_repos!(
        [repo("api", ["api"], %{"escalate" => %{"paths" => [], "labels" => [" "], "ticket_patterns" => [], "diff_patterns" => []}})],
        auto_review: %{"acceptance_gate" => %{"escalate" => %{"labels" => []}}}
      )

      escalate = Config.settings_for_repo!("api").auto_review.acceptance_gate.escalate

      for {field, values} <- Escalate.built_in(), do: assert(Map.fetch!(escalate, field) == values)
    end

    test "merge_override/2 adds lists, merges maps and replaces scalars" do
      global = %{"mode" => "off", "escalate" => %{"paths" => ["a"], "busy_files" => %{"top" => 10, "max_lines" => 300}}}
      override = %{"mode" => "shadow", "escalate" => %{"paths" => ["a", "b"], "busy_files" => %{"max_lines" => 50}}}

      assert Settings.merge_override(global, override) == %{
               "mode" => "shadow",
               "escalate" => %{"paths" => ["a", "b"], "busy_files" => %{"top" => 10, "max_lines" => 50}}
             }
    end
  end

  describe "run profile" do
    test "agent.run_profiles.acceptance_gate is accepted and acceptance_gate_profile/1 resolves it" do
      unset = settings!(%{})
      assert Config.acceptance_gate_profile(unset) == %{kind: :acceptance_gate, model: nil, effort: nil, provider: "anthropic"}

      agent = %{
        "runtime" => "claude",
        "command" => "claude --dangerously-skip-permissions",
        "model" => "claude-sonnet-5-5",
        "effort" => "medium",
        "run_profiles" => %{"acceptance_gate" => %{"model" => "claude-opus-5-5"}}
      }

      settings = settings!(%{"agent" => agent})
      assert Config.acceptance_gate_profile(settings) == %{kind: :acceptance_gate, model: "claude-opus-5-5", effort: "medium", provider: "anthropic"}
      assert Config.run_profile_key(settings, :acceptance_gate, :model) == "agent.run_profiles.acceptance_gate.model"

      settings = settings!(Map.merge(%{"agent" => agent}, gate(%{"effort" => "xhigh"})))
      assert Config.acceptance_gate_profile(settings) == %{kind: :acceptance_gate, model: "claude-opus-5-5", effort: "xhigh", provider: "anthropic"}
      assert Config.run_profile_key(settings, :acceptance_gate, :effort) == "auto_review.acceptance_gate.effort"
    end

    test "a repository's agent.run_profiles.acceptance_gate applies below the gate's own fields" do
      write_repos!(
        [Map.put(repo("api", ["api"], nil), "agent", %{"run_profiles" => %{"acceptance_gate" => %{"model" => "claude-haiku-4-5", "effort" => "low"}}})],
        auto_review: %{"acceptance_gate" => %{"effort" => "high"}}
      )

      assert Config.acceptance_gate_profile(Config.settings_for_repo!("api")) ==
               %{kind: :acceptance_gate, model: "claude-haiku-4-5", effort: "high", provider: "anthropic"}
    end
  end
end
