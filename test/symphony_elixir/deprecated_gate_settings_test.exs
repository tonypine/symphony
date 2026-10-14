defmodule SymphonyElixir.DeprecatedGateSettingsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.DeprecatedGateSettings, as: Settings
  alias SymphonyElixir.Config.Escalate
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

    test "ticket_patterns_builtin: false leaves only the configured ticket patterns" do
      escalate = fn fields -> settings!(gate(%{"escalate" => fields})).auto_review.acceptance_gate.escalate end
      [built_in | _] = built_ins = Escalate.built_in().ticket_patterns

      assert %Escalate{ticket_patterns_builtin: false, ticket_patterns: ["(?i)do not ship"]} =
               escalate.(%{"ticket_patterns_builtin" => false, "ticket_patterns" => [" (?i)do not ship ", ""]})

      assert escalate.(%{"ticket_patterns_builtin" => false}).ticket_patterns == []
      assert escalate.(%{"ticket_patterns_builtin" => false, "ticket_patterns" => [built_in]}).ticket_patterns == [built_in]
      assert escalate.(%{"ticket_patterns_builtin" => false, "ticket_patterns" => built_ins}).ticket_patterns == built_ins

      # The other built-in lists stay.
      assert escalate.(%{"ticket_patterns_builtin" => false}).labels == Escalate.built_in().labels
      assert escalate.(%{"ticket_patterns_builtin" => true, "ticket_patterns" => ["(?i)do not ship"]}).ticket_patterns == Escalate.built_in().ticket_patterns ++ ["(?i)do not ship"]
    end

    test "an invalid ticket_patterns_builtin or ticket_patterns names the key" do
      assert error!(gate(%{"escalate" => %{"ticket_patterns_builtin" => "no"}})) =~ "auto_review.acceptance_gate.escalate.ticket_patterns_builtin is invalid"

      assert error!(gate(%{"escalate" => %{"ticket_patterns_builtin" => false, "ticket_patterns" => "(?i)x"}})) =~
               "auto_review.acceptance_gate.escalate.ticket_patterns is invalid"

      assert error!(gate(%{"escalate" => %{"ticket_patterns_builtin" => false, "ticket_patterns" => ["(unclosed"]}})) =~
               "auto_review.acceptance_gate.escalate.ticket_patterns has an invalid regular expression `(unclosed`"
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
      assert gate.escalate.busy_files == %Escalate.BusyFiles{top: 10, window_days: 14, max_lines: 300}

      for {field, values} <- Escalate.built_in(), do: assert(Map.fetch!(gate.escalate, field) == values)
      assert "needs-human" in gate.escalate.labels
      assert "plan" in gate.escalate.labels
      assert "breakdown" in gate.escalate.labels
      assert gate.escalate.ticket_patterns_builtin
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

    test "can turn the built-in ticket patterns off, keeping the global block's configured ones" do
      write_repos!(
        [
          repo("api", ["api"], %{"escalate" => %{"ticket_patterns_builtin" => false, "ticket_patterns" => ["(?i)api only"]}}),
          repo("web", ["web"], nil)
        ],
        auto_review: %{"acceptance_gate" => %{"escalate" => %{"ticket_patterns" => ["(?i)do not ship"]}}}
      )

      api = Config.settings_for_repo!("api").auto_review.acceptance_gate.escalate
      web = Config.settings_for_repo!("web").auto_review.acceptance_gate.escalate

      assert {api.ticket_patterns_builtin, api.ticket_patterns} == {false, ["(?i)do not ship", "(?i)api only"]}
      assert {web.ticket_patterns_builtin, web.ticket_patterns} == {true, Escalate.built_in().ticket_patterns ++ ["(?i)do not ship"]}
    end

    test "inherit the global switch, or turn the built-in ticket patterns back on" do
      write_repos!(
        [
          repo("api", ["api"], %{"escalate" => %{"ticket_patterns" => ["(?i)api only"]}}),
          repo("web", ["web"], %{"escalate" => %{"ticket_patterns_builtin" => true}})
        ],
        auto_review: %{"acceptance_gate" => %{"escalate" => %{"ticket_patterns_builtin" => false, "ticket_patterns" => ["(?i)do not ship"]}}}
      )

      api = Config.settings_for_repo!("api").auto_review.acceptance_gate.escalate
      web = Config.settings_for_repo!("web").auto_review.acceptance_gate.escalate

      assert {api.ticket_patterns_builtin, api.ticket_patterns} == {false, ["(?i)do not ship", "(?i)api only"]}
      assert {web.ticket_patterns_builtin, web.ticket_patterns} == {true, Escalate.built_in().ticket_patterns ++ ["(?i)do not ship"]}
    end

    test "merge_override/2 drops the global block's built-in ticket patterns only when it still had them" do
      [built_in | _] = Escalate.built_in().ticket_patterns
      off = %{"escalate" => %{"ticket_patterns_builtin" => false, "ticket_patterns" => ["b"]}}

      assert Settings.merge_override(%{"escalate" => %{"ticket_patterns_builtin" => true, "ticket_patterns" => Escalate.built_in().ticket_patterns ++ ["a"]}}, off) ==
               %{"escalate" => %{"ticket_patterns_builtin" => false, "ticket_patterns" => ["a", "b"]}}

      # A global block that already turned them off listed this one itself.
      assert Settings.merge_override(%{"escalate" => %{"ticket_patterns_builtin" => false, "ticket_patterns" => [built_in]}}, off) ==
               %{"escalate" => %{"ticket_patterns_builtin" => false, "ticket_patterns" => [built_in, "b"]}}
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

  describe "deprecation of the retired Auto Review and acceptance gate keys" do
    # The warnings are logged once per distinct config, so each test parses its own config.
    defp parse_log(sections, repo_fields \\ %{}) do
      capture_log(fn -> assert {:ok, _system} = SystemSchema.parse(symphony(sections, repo_fields)) end)
    end

    test "Auto Review's own flow keys load and warn once each, naming what replaced them" do
      log =
        parse_log(%{
          "auto_review" => %{
            "enabled" => true,
            "state" => "Auto Review",
            "max_fix_attempts" => 3,
            "run_on" => "first_pass",
            "max_concurrent" => 2,
            "playbooks" => %{"cli" => %{"enabled" => true}}
          }
        })

      assert log =~ "`auto_review.enabled` is deprecated and has no effect: Auto Review is retired; QA runs in the QA state"
      assert log =~ "`auto_review.state` is deprecated and has no effect: Auto Review is retired; `issues.states.qa` names the QA state"
      assert log =~ "`auto_review.max_fix_attempts` is deprecated"
      assert log =~ "`auto_review.run_on` is deprecated"
      assert log =~ "`auto_review.max_concurrent` is deprecated"
      # The QA settings that moved with the QA state still act and say nothing.
      refute log =~ "`auto_review.playbooks`"

      {{:ok, system}, _log} = with_log(fn -> SystemSchema.parse(symphony(%{"auto_review" => %{"state" => "Auto Review"}})) end)
      refute Map.has_key?(system.auto_review, :state)
    end

    test "the gate agent's settings, its escalate block and inconclusive_limit warn; the block still loads" do
      log =
        parse_log(
          gate(%{
            "runtime" => "codex",
            "max_turns" => 9,
            "escalate" => %{"labels" => ["risky"], "inconclusive_limit" => 4}
          }),
          %{"acceptance_gate" => %{"timeout_ms" => 60_000}}
        )

      assert log =~ "`auto_review.acceptance_gate.runtime` is deprecated and has no effect: the acceptance gate is retired"
      assert log =~ "`auto_review.acceptance_gate.max_turns` is deprecated"
      assert log =~ "`repositories[app].acceptance_gate.timeout_ms` is deprecated"
      assert log =~ "`auto_review.acceptance_gate.escalate` is deprecated and will move"
      assert log =~ "`labels` and `ticket_patterns` pause the ticket on a Needs Decision hold"
      assert log =~ "`auto_review.acceptance_gate.escalate.inconclusive_limit` is deprecated and has no effect"

      assert settings!(gate(%{"escalate" => %{"labels" => ["also-risky"]}})).auto_review.acceptance_gate.escalate.labels ==
               Escalate.built_in().labels ++ ["also-risky"]
    end

    test "agent.run_profiles.acceptance_gate and a repository's still load, warn and are dropped" do
      agent = %{
        "runtime" => "claude",
        "command" => "claude --dangerously-skip-permissions",
        "run_profiles" => %{"acceptance_gate" => %{"model" => "claude-opus-5-5"}, "qa" => %{"effort" => "high"}}
      }

      log =
        capture_log(fn ->
          assert {:ok, system} =
                   SystemSchema.parse(symphony(%{"agent" => agent}, %{"agent" => %{"run_profiles" => %{"acceptance_gate" => %{"effort" => "low"}}}}))

          assert {:ok, settings} = Schema.parse(SystemSchema.to_config_map(system))
          assert settings.agent.run_profiles == %{"qa" => %{"effort" => "high"}}
        end)

      assert log =~ "`agent.run_profiles.acceptance_gate` is deprecated and has no effect"
      assert log =~ "`repositories[app].agent.run_profiles.acceptance_gate` is deprecated and has no effect"
    end

    test "agent.run_profiles.final_verification still loads, warns and is dropped" do
      agent = %{
        "runtime" => "claude",
        "command" => "claude --dangerously-skip-permissions",
        "run_profiles" => %{"final_verification" => %{"model" => "claude-opus-5-5"}, "qa" => %{"effort" => "high"}}
      }

      log =
        capture_log(fn ->
          assert {:ok, system} = SystemSchema.parse(symphony(%{"agent" => agent}, %{}))
          assert {:ok, settings} = Schema.parse(SystemSchema.to_config_map(system))
          assert settings.agent.run_profiles == %{"qa" => %{"effort" => "high"}}
        end)

      assert log =~ "`agent.run_profiles.final_verification` is deprecated and has no effect: `Final verification:` tickets are retired"
    end

    test "pull_requests.checks.escalate_to_state still loads and warns that it does nothing" do
      log = parse_log(%{"pull_requests" => %{"checks" => %{"escalate_to_state" => "Blocked"}}})

      assert log =~ "`pull_requests.checks.escalate_to_state` is deprecated and has no effect"
    end
  end

  describe "deprecation warnings from symphony.yml" do
    @mode_warning "`auto_review.acceptance_gate.mode` is deprecated"

    defp append_symphony_yml!(yaml) do
      path = Workflow.symphony_file_path()
      File.write!(path, File.read!(path) <> yaml)
      Cache.clear()
    end

    defp count(log, fragment), do: length(String.split(log, fragment)) - 1

    test "are logged once per load of symphony.yml, not on every settings read" do
      write_workflow_file!(Workflow.workflow_file_path())
      base = File.read!(Workflow.symphony_file_path())
      yaml = "auto_review:\n  acceptance_gate:\n    mode: shadow\n"

      log =
        capture_log(fn ->
          append_symphony_yml!(yaml)
          for _read <- 1..100, do: Config.settings!()
        end)

      assert count(log, @mode_warning) == 1

      # A reload of a changed file that still sets the key warns once more.
      log =
        capture_log(fn ->
          File.write!(Workflow.symphony_file_path(), base <> String.replace(yaml, "shadow", "enforce"))
          Cache.clear()
          for _read <- 1..100, do: Config.settings!()
        end)

      assert count(log, @mode_warning) == 1
    end

    test "are logged once when many components read the settings at the same time at startup" do
      write_workflow_file!(Workflow.workflow_file_path())

      log =
        capture_log(fn ->
          append_symphony_yml!("auto_review:\n  acceptance_gate:\n    mode: enforce\n")

          # One reader per component that reads settings on boot (a repo each, the gate, the
          # pollers), all parsing the freshly loaded config before any of them has warned.
          1..50
          |> Enum.map(fn _component -> Task.async(fn -> for _read <- 1..20, do: Config.settings!() end) end)
          |> Task.await_many(30_000)
        end)

      assert count(log, @mode_warning) == 1
    end
  end
end
