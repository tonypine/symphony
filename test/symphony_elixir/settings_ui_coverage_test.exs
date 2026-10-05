defmodule SymphonyElixir.SettingsUICoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.SettingsUICoverage

  defp manifest do
    {:ok, keys} = SettingsUICoverage.manifest_path() |> File.read!() |> SettingsUICoverage.parse_manifest()
    keys
  end

  defp exemptions do
    {:ok, exemptions} = SettingsUICoverage.exempt_path() |> File.read!() |> SettingsUICoverage.parse_exemptions()
    exemptions
  end

  defp exemption(keys, reason \\ "No control yet."), do: %{keys: keys, reason: reason, ticket: nil}

  describe "SystemSchema.operator_key_paths/0" do
    test "lists every leaf setting, with [] for list items and the pass-through sections' schema fields" do
      keys = SystemSchema.operator_key_paths()

      assert keys == Enum.sort(keys)
      assert keys == Enum.uniq(keys)

      for key <- ~w(auto_review.acceptance_gate.mode agent.concurrency.max_total agent.run_profiles issues.linear.scope.team
                    repositories[].route.team repositories[].acceptance_gate.escalate.busy_files.top
                    watchdog.enabled github.webhooks.secret notifications.channels[].kind verification.dev_server.start_cmd) do
        assert key in keys
      end

      for section <- ~w(agent agent.limits repositories repositories[] repositories[].route github.webhooks notifications.channels[]) do
        refute section in keys
      end
    end

    test "the parser accepts every listed key and rejects one that isn't listed" do
      for key <- SystemSchema.operator_key_paths() do
        assert_not_unknown(key, SystemSchema.parse(config_with(key)))
      end

      assert SystemSchema.parse(config_with("agent.limits.max_widgets")) ==
               {:error, {:invalid_symphony_config, "unknown symphony.yml key `agent.limits.max_widgets`"}}
    end
  end

  defp assert_not_unknown(_key, {:ok, _config}), do: :ok
  defp assert_not_unknown(key, {:error, {:invalid_symphony_config, message}}), do: refute(message =~ "unknown symphony.yml key", "#{key}: #{message}")

  # A config that sets `key` to nil, with list items for its `[]` parts.
  defp config_with(key) do
    key
    |> String.split(".")
    |> Enum.reverse()
    |> Enum.reduce(nil, fn segment, value ->
      case String.split(segment, "[]") do
        [name, ""] -> %{name => [value]}
        [name] -> %{name => value}
      end
    end)
  end

  describe "parse_manifest/1" do
    test "reads the string literals of the keyPaths list" do
      source = """
      public enum SettingsUIManifest {
          public static let keyPaths: [String] = [
              "agent.model",
              "repositories[].key"
          ]
      }
      """

      assert SettingsUICoverage.parse_manifest(source) == {:ok, ["agent.model", "repositories[].key"]}
      assert "agent.concurrency.max_total" in manifest()
    end

    test "fails without the list" do
      assert SettingsUICoverage.parse_manifest("enum SettingsUIManifest {}") ==
               {:error, "macos/Sources/SymphonyBarCore/SettingsUIManifest.swift has no `static let keyPaths: [String] = [...]` list"}
    end
  end

  describe "parse_exemptions/1" do
    test "reads keys, key lists, reasons and tickets" do
      yaml = """
      exemptions:
        - key: watchdog.*
          reason: Tuning.
        - keys: [agent.runtime, agent.mcp.inherit]
          reason: Later.
          ticket: TP-1
      """

      assert SettingsUICoverage.parse_exemptions(yaml) ==
               {:ok, [exemption(["watchdog.*"], "Tuning."), %{keys: ["agent.runtime", "agent.mcp.inherit"], reason: "Later.", ticket: "TP-1"}]}

      assert [%{reason: _reason} | _rest] = exemptions()
    end

    test "names the file and the entry that is wrong" do
      for {yaml, message} <- [
            {"exemptions: nope\n", "must hold an `exemptions:` list"},
            {"- key: a\n", "must hold an `exemptions:` list"},
            {"exemptions:\n  - key: a\n", "exemption 1 needs a `reason`"},
            {"exemptions:\n  - key: a\n    reason: ok\n  - key: b\n    reason: ' '\n", "exemption 2 has an empty `reason`"},
            {"exemptions:\n  - reason: ok\n", "exemption 1 needs a `key` or a `keys` list of key paths"},
            {"exemptions:\n  - key: a\n    keys: [b]\n    reason: ok\n", "exemption 1 needs a `key` or a `keys` list"},
            {"exemptions:\n  - keys: []\n    reason: ok\n", "exemption 1 needs a `key` or a `keys` list"},
            {"exemptions:\n  - keys: [a, {b: c}]\n    reason: ok\n", "exemption 1 needs a `key` or a `keys` list"},
            {"exemptions:\n  - key: a\n    reason: ok\n    ticket: [TP-1]\n", "exemption 1 has a `ticket` that is not a string"}
          ] do
        assert {:error, "config/settings_ui_exempt.yml" <> rest} = SettingsUICoverage.parse_exemptions(yaml)
        assert rest =~ message
      end

      assert {:error, "config/settings_ui_exempt.yml is not valid YAML: " <> _detail} = SettingsUICoverage.parse_exemptions("exemptions: [\n")
    end
  end

  describe "check/3" do
    test "every setting on the default branch has a control in the app or an exemption" do
      assert SettingsUICoverage.check(SystemSchema.operator_key_paths(), manifest(), exemptions()) ==
               %{uncovered: [], unknown_manifest_keys: [], unused_exemptions: [], redundant_exemptions: []}
    end

    test "a setting added to the schema without a manifest entry or exemption is uncovered, by name" do
      keys = SystemSchema.operator_key_paths() ++ ["agent.limits.max_widgets", "repositories[].route.widget"]

      assert %{uncovered: ["agent.limits.max_widgets", "repositories[].route.widget"]} = SettingsUICoverage.check(keys, manifest(), exemptions())
    end

    test "an exempt prefix covers every key under it, even new ones" do
      keys = ["watchdog.enabled", "watchdog.new_threshold", "watchdogs.enabled", "agent.model"]

      assert SettingsUICoverage.check(keys, ["agent.model"], [exemption(["watchdog.*"])]) == %{
               uncovered: ["watchdogs.enabled"],
               unknown_manifest_keys: [],
               unused_exemptions: [],
               redundant_exemptions: []
             }
    end

    test "reports manifest keys that aren't settings, and exemptions that match nothing or have a control now" do
      keys = ["agent.model", "agent.effort"]
      report = SettingsUICoverage.check(keys, ["agent.model", "agent.widgets"], [exemption(["agent.*", "gone.*", "gone.key"])])

      assert report.uncovered == []
      assert report.unknown_manifest_keys == ["agent.widgets"]
      assert report.unused_exemptions == ["gone.*", "gone.key"]
      assert report.redundant_exemptions == ["agent.model"]
    end
  end

  test "exempts?/2 matches a key exactly, or a prefix at a dot" do
    assert SettingsUICoverage.exempts?("watchdog.enabled", "watchdog.enabled")
    refute SettingsUICoverage.exempts?("watchdog.enabled", "watchdog.enabled_x")
    assert SettingsUICoverage.exempts?("repositories[].acceptance_gate.*", "repositories[].acceptance_gate.escalate.labels")
    refute SettingsUICoverage.exempts?("watchdog.*", "watchdog")
  end
end
