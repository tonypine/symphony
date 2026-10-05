defmodule Mix.Tasks.Settings.UiCoverageTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Settings.UiCoverage
  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.SettingsUICoverage

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("settings.ui_coverage")
    root = Path.join(System.tmp_dir!(), "settings-ui-coverage-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, manifest} = SettingsUICoverage.manifest_path() |> File.read!() |> SettingsUICoverage.parse_manifest()
    %{root: root, manifest: manifest}
  end

  # A repository holding a manifest of `manifest` and an exemption file of `exemptions`, written as
  # JSON, which YAML reads too.
  defp write_root!(root, manifest, exemptions) do
    swift = "enum SettingsUIManifest {\n    static let keyPaths: [String] = [\n" <> Enum.map_join(manifest, &~s(        "#{&1}",\n)) <> "    ]\n}\n"
    write!(root, SettingsUICoverage.manifest_path(), swift)
    write!(root, SettingsUICoverage.exempt_path(), Jason.encode!(%{"exemptions" => exemptions}))
  end

  defp write!(root, path, contents) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp uncovered(manifest), do: SystemSchema.operator_key_paths() -- manifest

  test "prints help, and rejects invalid options" do
    assert capture_io(fn -> UiCoverage.run(["--help"]) end) =~ "mix settings.ui_coverage [--root PATH]"
    assert_raise Mix.Error, ~r/Invalid option/, fn -> UiCoverage.run(["--wat"]) end
  end

  test "passes on this repository's manifest and seeded exemption file" do
    assert capture_io(fn -> UiCoverage.run([]) end) =~ ~r/All \d+ symphony.yml settings have a control in the macOS app or an exemption/
  end

  test "fails naming each setting with no control and no exemption", %{root: root, manifest: manifest} do
    write_root!(root, manifest -- ["agent.concurrency.max_total", "repositories[].route.team"], [%{"keys" => uncovered(manifest), "reason" => "Later."}])

    stderr =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/2 symphony.yml setting\(s\) have no control in the macOS app/, fn -> UiCoverage.run(["--root", root]) end
      end)

    assert stderr =~ "No control in the macOS app and no exemption: agent.concurrency.max_total"
    assert stderr =~ "No control in the macOS app and no exemption: repositories[].route.team"
  end

  test "passes a key covered by an exempt prefix, warning about stale exemptions", %{root: root, manifest: manifest} do
    {watchdog, others} = Enum.split_with(uncovered(manifest), &String.starts_with?(&1, "watchdog."))
    assert watchdog != []

    write_root!(root, manifest, [
      %{"keys" => others, "reason" => "Later."},
      %{"key" => "watchdog.*", "reason" => "Tuning.", "ticket" => "TP-1"},
      %{"keys" => ["gone.setting", "agent.model"], "reason" => "Stale."}
    ])

    output = capture_io(fn -> UiCoverage.run(["--root", root]) end)

    assert output =~ "All "
    assert output =~ "warning: exemption `gone.setting` matches no symphony.yml setting"
    assert output =~ "warning: `agent.model` has a control in the app now"
  end

  test "fails a manifest key that is not a setting", %{root: root, manifest: manifest} do
    write_root!(root, manifest ++ ["agent.widgets"], [%{"keys" => uncovered(manifest), "reason" => "Later."}])

    stderr =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/lists key paths that are not symphony.yml settings/, fn -> UiCoverage.run(["--root", root]) end
      end)

    assert stderr =~ "Not a symphony.yml setting: agent.widgets"
  end

  test "fails a missing or invalid file", %{root: root, manifest: manifest} do
    assert_raise Mix.Error, ~r/Could not read macos\/.*SettingsUIManifest.swift: no such file or directory/, fn -> UiCoverage.run(["--root", root]) end

    write_root!(root, manifest, [])
    write!(root, SettingsUICoverage.exempt_path(), "nope: 1\n")
    assert_raise Mix.Error, ~r/settings_ui_exempt.yml must hold an `exemptions:` list/, fn -> UiCoverage.run(["--root", root]) end
  end
end
