defmodule Mix.Tasks.Settings.UiCoverage do
  use Mix.Task

  @shortdoc "Fail when a symphony.yml setting has no control in the macOS app and no exemption"

  @moduledoc """
  Fails when a `symphony.yml` setting is neither in the macOS app's manifest
  (`macos/Sources/SymphonyBarCore/SettingsUIManifest.swift`) nor in
  `config/settings_ui_exempt.yml`, naming each one, or when the manifest lists a key that is not a
  setting. Warns about exemptions that match no setting or cover a key the app now edits.

  A new setting needs a control in the app, listed in the manifest. Only a person can exempt one:
  the exemption file is write-protected for agents.

  Usage:

      mix settings.ui_coverage [--root PATH]

  `--root` is the repository to read the manifest and exemption file from, the current directory
  by default.
  """

  @requirements ["compile"]

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.SettingsUICoverage

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [root: :string, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] -> Mix.shell().info(@moduledoc)
      invalid != [] -> Mix.raise("Invalid option(s): #{inspect(invalid)}")
      true -> check(Keyword.get(opts, :root, "."))
    end
  end

  defp check(root) do
    keys = SystemSchema.operator_key_paths()
    manifest = read!(root, SettingsUICoverage.manifest_path(), &SettingsUICoverage.parse_manifest/1)
    exemptions = read!(root, SettingsUICoverage.exempt_path(), &SettingsUICoverage.parse_exemptions/1)
    report = SettingsUICoverage.check(keys, manifest, exemptions)

    Enum.each(report.unused_exemptions, &Mix.shell().info("warning: exemption `#{&1}` matches no symphony.yml setting; a person can remove it"))
    Enum.each(report.redundant_exemptions, &Mix.shell().info("warning: `#{&1}` has a control in the app now; a person can remove its exemption"))
    Enum.each(report.unknown_manifest_keys, &Mix.shell().error("Not a symphony.yml setting: #{&1}"))
    Enum.each(report.uncovered, &Mix.shell().error("No control in the macOS app and no exemption: #{&1}"))

    cond do
      report.uncovered != [] ->
        Mix.raise(
          "#{length(report.uncovered)} symphony.yml setting(s) have no control in the macOS app. Add the control and list the key in " <>
            "#{SettingsUICoverage.manifest_path()}, or ask a person to exempt it in #{SettingsUICoverage.exempt_path()}."
        )

      report.unknown_manifest_keys != [] ->
        Mix.raise("#{SettingsUICoverage.manifest_path()} lists key paths that are not symphony.yml settings.")

      true ->
        Mix.shell().info("All #{length(keys)} symphony.yml settings have a control in the macOS app or an exemption.")
    end
  end

  defp read!(root, path, parse) do
    with {:ok, contents} <- File.read(Path.join(root, path)),
         {:ok, parsed} <- parse.(contents) do
      parsed
    else
      {:error, message} when is_binary(message) -> Mix.raise(message)
      {:error, reason} -> Mix.raise("Could not read #{path}: #{:file.format_error(reason)}")
    end
  end
end
