defmodule SymphonyElixir.Config.Migration.RunsRewrite do
  @moduledoc """
  Rewrites the text of a `symphony.yml` whose `agent` section moves to `execution` and `runs`
  (`SymphonyElixir.Config.Migration.RunsMove` says what the file must read as afterwards).

  `agent:` is renamed to `execution:` where it stands, so every comment and setting under it
  that stays (concurrency, limits, timeouts, prompts, permissions, MCP, usage limits) keeps its
  place. Only the lines of the keys that move are removed: the run keys of `agent`,
  `code_review` and `auto_review`, and each repository's `agent` block. The harness map is
  written under `execution:`, and `runs:` after its block. A comment written on a removed line
  goes with it; the file as it was is kept beside the new one.
  """

  alias SymphonyElixir.Config.Migration.{Lines, RunsMove}
  alias SymphonyElixir.Config.Runs
  alias SymphonyElixir.RunKind

  @entry_order Runs.entry_keys()
  @plain ~r/\A[A-Za-z0-9._\/@=+-][A-Za-z0-9 ._\/@=+-]*\z/
  @ambiguous ~w(true false null yes no on off ~)

  @doc """
  `text` with the `agent` section moved, and the note that says so. `document` is `text`
  parsed, `backup` the name of the file as it was, `version` the build making the move.
  An error names the key to set, or the lines the rewrite could not move.
  """
  @type error :: {:runs_not_moved, String.t()} | {:not_migrated, [{String.t(), pos_integer() | nil}]}

  @spec plan(String.t(), map(), String.t(), String.t()) :: {:ok, String.t(), [String.t()]} | {:error, error()}
  def plan(text, document, backup, version) do
    case RunsMove.document(document) do
      {:ok, moved} -> rewrite(text, moved, backup, version)
      {:error, message} -> {:error, {:runs_not_moved, message}}
    end
  end

  defp rewrite(text, moved, backup, version) do
    lines = String.split(text, "\n")
    entries = Lines.key_entries(lines)
    note = "v#{version} moved `agent` to `execution` and `runs` in your settings"
    comment = "# Symphony: #{note}. The file as it was: #{backup}."

    edits =
      Enum.flat_map(entries, &edit(&1, entries, lines, moved, comment)) ++ emptied_sections(entries, lines)

    migrated = lines |> Lines.apply_edits(edits) |> Enum.join("\n")

    case YamlElixir.read_from_string(migrated) do
      {:ok, ^moved} -> {:ok, migrated, [note]}
      _other -> {:error, {:not_migrated, unmoved(entries)}}
    end
  end

  # The keys a rewrite could not move sit in a form it does not edit (`agent: {runtime: ...}`).
  defp unmoved(entries) do
    for entry <- entries, entry.path in ["agent", "repositories[].agent"], do: {entry.path, entry.index + 1}
  end

  defp edit(%{path: "agent"} = entry, _entries, lines, moved, comment) do
    line = String.replace(Enum.at(lines, entry.index), "agent:", "execution:", global: false)
    harnesses = ["  harnesses:" | harness_lines(moved["execution"]["harnesses"])]

    [
      {entry.index, 1, [comment, line | harnesses]},
      {entry.index + Lines.block_length(lines, entry), 0, ["" | runs_lines(moved["runs"], "")]}
    ]
  end

  defp edit(%{path: "agent.permissions.outer_sandbox.runtime"} = entry, _entries, lines, _moved, _comment),
    do: [rename(entry, lines, "kind")]

  defp edit(%{path: "repositories[].agent"} = entry, entries, lines, moved, _comment) do
    repository = Enum.at(moved["repositories"], repository_index(entry, entries))
    indent = String.duplicate(" ", entry.column)

    replacement =
      case repository["runs"] do
        nil -> []
        runs -> runs_lines(runs, indent)
      end

    [{entry.index, Lines.block_length(lines, entry), replacement}]
  end

  defp edit(%{path: path} = entry, _entries, lines, _moved, _comment) do
    cond do
      moved_key?(path) -> [{entry.index, Lines.block_length(lines, entry), []}]
      Regex.match?(~r/\Aagent\.mcp\.servers\.[^.]+\.runtimes\z/, path) -> [rename(entry, lines, "harnesses")]
      true -> []
    end
  end

  defp moved_key?(path) do
    case String.split(path, ".") do
      ["agent", key] -> key in RunsMove.run_keys()
      [section, key] when section in ["code_review", "auto_review"] -> key in RunsMove.section_run_keys()
      _other -> false
    end
  end

  defp rename(entry, lines, name) do
    {entry.index, 1, [String.replace(Enum.at(lines, entry.index), entry.name <> ":", name <> ":", global: false)]}
  end

  # A repository's place in the list: the list items in file order, by the line that opens each.
  defp repository_index(entry, entries) do
    entries
    |> Enum.filter(&String.starts_with?(&1.path, "repositories[]."))
    |> Enum.reject(&String.contains?(String.replace_prefix(&1.path, "repositories[].", ""), "."))
    |> Enum.map(& &1.parent)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.find_index(&(&1 == entry.parent))
  end

  # A section whose every key moved is left as `{}`, so it still reads as the empty map.
  defp emptied_sections(entries, lines) do
    for section <- entries,
        section.path in ["code_review", "auto_review"],
        children = Enum.filter(entries, &(&1.parent == section.index)),
        children != [],
        Enum.all?(children, &moved_key?(&1.path)) do
      {section.index, 1, [String.trim_trailing(Enum.at(lines, section.index)) <> " {}"]}
    end
  end

  defp harness_lines(harnesses) do
    Enum.flat_map(Enum.sort(harnesses), fn {harness, settings} ->
      command = if settings["command"], do: ["      command: #{scalar(settings["command"])}"], else: []

      small_model =
        case settings["small_model"] do
          nil -> []
          models -> ["      small_model:" | Enum.map(Enum.sort(models), fn {provider, model} -> "        #{provider}: #{scalar(model)}" end)]
        end

      ["    #{harness}:"] ++ command ++ small_model
    end)
  end

  defp runs_lines(runs, indent) do
    names = [Runs.default() | RunKind.names()] |> Enum.filter(&is_map_key(runs, &1))
    ["#{indent}runs:" | Enum.map(names, &"#{indent}  #{&1}: #{flow(runs[&1])}")]
  end

  defp flow(entry) do
    fields = for key <- @entry_order, is_map_key(entry, key), do: "#{key}: #{scalar(entry[key])}"
    "{ " <> Enum.join(fields, ", ") <> " }"
  end

  # A value as YAML reads it back: plain when nothing in it could be read as anything else,
  # else double-quoted.
  defp scalar(value) when is_binary(value) do
    plain? = Regex.match?(@plain, value) and String.downcase(value) not in @ambiguous and Float.parse(value) == :error
    if plain?, do: value, else: Jason.encode!(value)
  end
end
