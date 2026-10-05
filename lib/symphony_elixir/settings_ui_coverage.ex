defmodule SymphonyElixir.SettingsUICoverage do
  @moduledoc """
  Checks that every `symphony.yml` setting has a control in the macOS app, or an exemption a
  person approved.

  The app lists the keys it edits in `SettingsUIManifest.keyPaths`
  (`macos/Sources/SymphonyBarCore/SettingsUIManifest.swift`); `config/settings_ui_exempt.yml`
  lists the keys that have no control, each with a reason. That file is write-protected for
  agents, so an agent can't exempt the setting it adds. `mix settings.ui_coverage` runs the check
  in CI, and the acceptance gate's `:settings_ui` rule escalates a PR that changes the config
  schema without the manifest.

  A key is a dotted path from `SymphonyElixir.Config.SystemSchema.operator_key_paths/0`. An
  exemption names a key, or a prefix such as `watchdog.*` that covers every key under it,
  including ones added later.
  """

  @manifest_path "macos/Sources/SymphonyBarCore/SettingsUIManifest.swift"
  @exempt_path "config/settings_ui_exempt.yml"
  @schema_paths ["lib/symphony_elixir/config/schema.ex", "lib/symphony_elixir/config/system_schema.ex"]

  @type exemption :: %{keys: [String.t()], reason: String.t(), ticket: String.t() | nil}

  @type report :: %{
          uncovered: [String.t()],
          unknown_manifest_keys: [String.t()],
          unused_exemptions: [String.t()],
          redundant_exemptions: [String.t()]
        }

  @doc "The app's manifest, relative to the repository root."
  @spec manifest_path() :: String.t()
  def manifest_path, do: @manifest_path

  @doc "The exemption file, relative to the repository root."
  @spec exempt_path() :: String.t()
  def exempt_path, do: @exempt_path

  @doc "The files that declare the `symphony.yml` settings, relative to the repository root."
  @spec schema_paths() :: [String.t()]
  def schema_paths, do: @schema_paths

  @doc """
  The key paths in the `keyPaths` list of the manifest's Swift source: its string literals, one
  per line.
  """
  @spec parse_manifest(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def parse_manifest(source) when is_binary(source) do
    case Regex.run(~r/static let keyPaths: \[String\] = \[(.*?)\n\s*\]/s, source) do
      [_match, body] -> {:ok, Regex.scan(~r/^\s*"([^"]+)",?\s*$/m, body, capture: :all_but_first) |> List.flatten()}
      nil -> {:error, "#{@manifest_path} has no `static let keyPaths: [String] = [...]` list"}
    end
  end

  @doc """
  The entries of the exemption file: each has a `key` (a key path or `prefix.*`) or a `keys`
  list of them, a non-empty `reason`, and an optional `ticket`.
  """
  @spec parse_exemptions(String.t()) :: {:ok, [exemption()]} | {:error, String.t()}
  def parse_exemptions(yaml) when is_binary(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{"exemptions" => entries}} when is_list(entries) ->
        entries |> Enum.with_index(1) |> Enum.map(&parse_exemption/1) |> collect()

      {:ok, _other} ->
        {:error, "#{@exempt_path} must hold an `exemptions:` list"}

      {:error, error} ->
        {:error, "#{@exempt_path} is not valid YAML: #{Exception.message(error)}"}
    end
  end

  defp parse_exemption({%{"reason" => reason} = entry, index}) when is_binary(reason) do
    keys = entry_keys(entry)
    ticket = Map.get(entry, "ticket")

    cond do
      String.trim(reason) == "" -> {:error, "exemption #{index} has an empty `reason`"}
      keys == :error -> {:error, "exemption #{index} needs a `key` or a `keys` list of key paths"}
      not (is_nil(ticket) or is_binary(ticket)) -> {:error, "exemption #{index} has a `ticket` that is not a string"}
      true -> {:ok, %{keys: keys, reason: reason, ticket: ticket}}
    end
  end

  defp parse_exemption({_entry, index}), do: {:error, "exemption #{index} needs a `reason`"}

  defp entry_keys(%{"key" => key} = entry) when is_binary(key) and not is_map_key(entry, "keys"), do: [key]

  defp entry_keys(%{"keys" => [_ | _] = keys} = entry) when not is_map_key(entry, "key") do
    if Enum.all?(keys, &is_binary/1), do: keys, else: :error
  end

  defp entry_keys(_entry), do: :error

  defp collect(results) do
    case Enum.find(results, &match?({:error, _message}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, exemption} -> exemption end)}
      {:error, message} -> {:error, "#{@exempt_path}: #{message}"}
    end
  end

  @doc """
  Compares the settings `keys` with the `manifest` key paths and the `exemptions`:

    * `uncovered` - keys neither in the manifest nor exempt;
    * `unknown_manifest_keys` - manifest entries that are not settings;
    * `unused_exemptions` - exemption keys and prefixes that match no setting;
    * `redundant_exemptions` - exempt keys that are in the manifest too.
  """
  @spec check([String.t()], [String.t()], [exemption()]) :: report()
  def check(keys, manifest, exemptions) do
    patterns = Enum.flat_map(exemptions, & &1.keys)
    exempt? = fn key -> Enum.any?(patterns, &exempts?(&1, key)) end

    %{
      uncovered: Enum.reject(keys, &(&1 in manifest or exempt?.(&1))),
      unknown_manifest_keys: manifest -- keys,
      unused_exemptions: Enum.reject(patterns, fn pattern -> Enum.any?(keys, &exempts?(pattern, &1)) end),
      redundant_exemptions: Enum.filter(manifest, &(&1 in keys and exempt?.(&1)))
    }
  end

  @doc "Whether the exemption `pattern` (a key path, or `prefix.*`) covers `key`."
  @spec exempts?(String.t(), String.t()) :: boolean()
  def exempts?(pattern, key) do
    case String.split_at(pattern, -2) do
      {prefix, ".*"} -> String.starts_with?(key, prefix <> ".")
      _exact -> pattern == key
    end
  end
end
