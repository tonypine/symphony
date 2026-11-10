defmodule SymphonyElixir.Config.Migration do
  @moduledoc """
  Rewrites the keys of a `symphony.yml` that a release renamed or removed, so an update that changes
  the file's shape needs nothing from the operator. `@migrations` is the table: every key some
  release changed, the sibling it became (or `nil` when it is simply gone), the ticket that changed
  it and the release that first shipped the change. A key that moved in a way the table can't say
  stays in `SystemSchema`'s removed keys and is refused.

  A rewrite touches only the lines of the keys it moves, so comments and ordering stay, leaves a
  one-line comment naming the ticket where each key was, and keeps the file as it was beside it.
  The new text is then compared with the table applied to the parsed YAML: a key that isn't on a line
  of its own (`agent: {run_profiles: {...}}`) can't be rewritten, and that is an error naming it.

  `symphony start` and `symphony run` migrate the file in place. `symphony check --migrate`, which
  the macOS app runs with a downloaded build before it installs it, checks a migrated copy and
  leaves the file alone.
  """

  alias SymphonyElixir.BuildInfo
  alias SymphonyElixir.Config.{LineEditor, SystemSchema}

  @type error :: {:not_migrated, [String.t()]} | File.posix()

  @rename_defaults %{drop_children: [], why: nil}
  @migrations [
    Map.merge(@rename_defaults, %{
      key: "pre_push_review",
      to: "code_review",
      ticket: "TP-1203",
      release: "0.0.1.691",
      drop_children: ~w(max_iterations run_on)
    }),
    Map.merge(@rename_defaults, %{
      key: "agent.run_profiles.pre_push_review",
      to: "code_review",
      ticket: "TP-1203",
      release: "0.0.1.691"
    }),
    Map.merge(@rename_defaults, %{
      key: "repositories[].agent.run_profiles.pre_push_review",
      to: "code_review",
      ticket: "TP-1203",
      release: "0.0.1.691"
    }),
    Map.merge(@rename_defaults, %{
      key: "ledger.artifact_retention_days",
      to: nil,
      ticket: "TP-1201",
      release: "0.0.1.688",
      why: "Symphony keeps every screenshot and run transcript now"
    })
  ]

  @key_line ~r/\A( *)((?:- +)?)([A-Za-z0-9_][A-Za-z0-9_\-]*):(?:\s.*)?\z/

  @doc "The table as `symphony config migrations` prints it, for the release's `version.json`."
  @spec migrations_json() :: String.t()
  def migrations_json do
    @migrations
    |> Enum.map(&Map.take(&1, [:key, :to, :ticket, :release]))
    |> Jason.encode!()
  end

  @doc """
  `text` with every key in the table rewritten, and a note per key moved. `backup` is the name the
  comment gives the file as it was. A text that doesn't parse as a YAML map is left for the load to
  report.
  """
  @spec plan(String.t(), String.t()) :: {:ok, String.t(), [String.t()]} | {:error, error()}
  def plan(text, backup) when is_binary(text) and is_binary(backup) do
    case read_map(text) do
      nil -> {:ok, text, []}
      document -> plan_document(text, document, backup)
    end
  end

  @doc """
  Migrates the file at `path` in place, with the file as it was beside it, named for this build:
  `symphony.yml.before-v0.0.1.700`. A file that can't be read has nothing to migrate here; the load
  reports it.
  """
  @spec migrate_file(Path.t()) :: {:ok, [String.t()], Path.t() | nil} | {:error, error()}
  def migrate_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, text} -> migrate_text(path, text)
      {:error, _reason} -> {:ok, [], nil}
    end
  end

  @doc """
  Writes the migrated text to a hidden sibling of `path`, so its relative paths resolve as the
  file's do, and leaves `path` alone. `:unchanged` when nothing migrates.
  """
  @spec migrated_copy(Path.t()) :: {:ok, :unchanged} | {:ok, Path.t(), [String.t()]} | {:error, error()}
  def migrated_copy(path) when is_binary(path) do
    with {:ok, text} <- File.read(path),
         {:ok, migrated, notes} <- plan(text, backup_name(path)) do
      write_copy(path, migrated, notes)
    end
  end

  @doc """
  What the build can't read in the file at `checked`, with the line each key holds in `original`,
  for the operator to edit: `" Lines it can't read: 12 (`tracker`), `foo`."`, empty when there is
  nothing to name.
  """
  @spec refused_lines(Path.t(), Path.t()) :: String.t()
  def refused_lines(checked, original) do
    with {:ok, text} <- File.read(checked),
         %{} = document <- read_map(text),
         {:ok, original_text} <- File.read(original),
         [_ | _] = keys <- SystemSchema.refused_keys(document) do
      lines = original_text |> String.split("\n") |> key_entries() |> Map.new(&{&1.path, &1.index + 1})
      " Lines it can't read: " <> Enum.map_join(keys, ", ", &refused_key(&1, lines)) <> "."
    else
      _nothing_to_name -> ""
    end
  end

  @doc "A migration error, in the words `Config error in <path>: ` opens."
  @spec format_error(error()) :: String.t()
  def format_error({:not_migrated, keys}) do
    "#{Enum.map_join(keys, ", ", &"`#{&1}`")} can't be rewritten because it isn't on a line of its own; " <>
      "write it as an indented block"
  end

  def format_error(reason), do: "couldn't write the migrated file: #{:file.format_error(reason)}"

  defp refused_key(key, lines) do
    case Map.fetch(lines, key) do
      {:ok, line} -> "#{line} (`#{key}`)"
      :error -> "`#{key}`"
    end
  end

  defp migrate_text(path, text) do
    with {:ok, migrated, notes} <- plan(text, backup_name(path)) do
      write_migrated(path, text, migrated, notes)
    end
  end

  defp write_migrated(_path, text, text, _notes), do: {:ok, [], nil}

  defp write_migrated(path, _text, migrated, notes) do
    backup = Path.join(Path.dirname(path), backup_name(path))

    with {:ok, %File.Stat{mode: mode}} <- File.stat(path),
         :ok <- File.cp(path, backup),
         :ok <- LineEditor.replace(path, migrated, mode) do
      {:ok, notes, backup}
    end
  end

  defp write_copy(_path, _migrated, []), do: {:ok, :unchanged}

  defp write_copy(path, migrated, notes) do
    copy = Path.join(Path.dirname(path), ".#{Path.basename(path)}.migrate-#{System.unique_integer([:positive])}")

    case File.write(copy, migrated) do
      :ok -> {:ok, copy, notes}
      {:error, reason} -> {:error, reason}
    end
  end

  defp backup_name(path), do: "#{Path.basename(path)}.before-v#{BuildInfo.current().version}"

  defp plan_document(text, document, backup) do
    lines = String.split(text, "\n")
    entries = key_entries(lines)
    matches = for migration <- @migrations, entry <- entries, entry.path == migration.key, do: {migration, entry}

    edits = Enum.flat_map(matches, fn {migration, entry} -> edits(migration, entry, entries, lines, backup) end)
    edits = edits ++ emptied_parents(matches, entries, lines)
    migrated = lines |> apply_edits(edits) |> Enum.join("\n")
    notes = matches |> Enum.map(fn {migration, entry} -> note(migration, target_set?(migration, entry, entries)) end) |> Enum.uniq()

    verify(document, migrated, notes)
  end

  defp verify(document, migrated, notes) do
    expected = Enum.reduce(@migrations, document, &migrate_map(&2, path_of(&1.key), &1))

    if read_map(migrated) == expected do
      {:ok, migrated, notes}
    else
      {:error, {:not_migrated, for(migration <- @migrations, has_key?(document, path_of(migration.key)), do: migration.key)}}
    end
  end

  # The edits of one key, each `{index, lines to remove, lines to insert}`.
  defp edits(migration, entry, entries, lines, backup) do
    comment = comment(migration, entry, entries, backup)

    if migration.to == nil or target_set?(migration, entry, entries) do
      [{entry.index, block_length(lines, entry), [comment]}]
    else
      renamed = String.replace(Enum.at(lines, entry.index), entry.name <> ":", migration.to <> ":", global: false)
      children = Enum.filter(entries, &(&1.parent == entry.index))
      {dropped, kept} = Enum.split_with(children, &(&1.name in migration.drop_children))
      renamed = if dropped != [] and kept == [], do: empty_map_line(renamed, migration.to), else: renamed

      [{entry.index, 1, [comment, renamed]} | Enum.map(dropped, &{&1.index, block_length(lines, &1), []})]
    end
  end

  # A block whose every key the table removes is left as `{}`, so it still reads as the empty map the
  # table makes of it and not as nothing.
  defp emptied_parents(matches, entries, lines) do
    removed = for {migration, entry} <- matches, migration.to == nil or target_set?(migration, entry, entries), into: MapSet.new(), do: entry.index
    edited = MapSet.new(matches, fn {_migration, entry} -> entry.index end)

    for parent <- entries,
        not MapSet.member?(edited, parent.index),
        children = Enum.filter(entries, &(&1.parent == parent.index)),
        children != [],
        Enum.all?(children, &MapSet.member?(removed, &1.index)) do
      {parent.index, 1, [empty_map_line(Enum.at(lines, parent.index), parent.name)]}
    end
  end

  # `ledger:` or `ledger: # a comment` becomes `ledger: {}`, the comment kept. A line holding more
  # after its colon is left, and the check against the table names the key.
  defp empty_map_line(line, name) do
    case Regex.run(~r/\A(.*?#{Regex.escape(name)}:)((?:\s+#.*)?\s*)\z/, line) do
      [_line, key, rest] -> key <> " {}" <> rest
      nil -> line
    end
  end

  # From the last line up, so each edit's index still holds.
  defp apply_edits(lines, edits) do
    edits
    |> Enum.sort_by(fn {index, _remove, _insert} -> index end, :desc)
    |> Enum.reduce(lines, fn {index, remove, insert}, lines ->
      Enum.take(lines, index) ++ insert ++ Enum.drop(lines, index + remove)
    end)
  end

  defp comment(migration, entry, entries, backup) do
    note = note(migration, target_set?(migration, entry, entries))
    String.duplicate(" ", entry.column) <> "# Symphony: #{note} (#{migration.ticket}). The file as it was: #{backup}."
  end

  defp note(%{to: nil} = migration, _target_set?) do
    "v#{migration.release} removed `#{migration.key}` from your settings: #{migration.why}"
  end

  defp note(migration, true) do
    "v#{migration.release} renamed `#{migration.key}` to `#{migration.to}`; your `#{migration.to}` stays and the old block is gone"
  end

  defp note(migration, false) do
    "v#{migration.release} renamed `#{migration.key}` to `#{migration.to}` in your settings"
  end

  defp target_set?(migration, entry, entries) do
    Enum.any?(entries, &(&1.parent == entry.parent and &1.name == migration.to))
  end

  # A block runs to its last line of content, so a comment or a blank line after it stays.
  defp block_length(lines, entry) do
    lines
    |> Enum.drop(entry.index + 1)
    |> Enum.take_while(&(not content?(&1) or inside_block?(&1, entry.column)))
    |> Enum.reverse()
    |> Enum.drop_while(&(not content?(&1)))
    |> length()
    |> Kernel.+(1)
  end

  defp content?(line) do
    trimmed = String.trim(line)
    trimmed != "" and not String.starts_with?(trimmed, "#")
  end

  defp inside_block?(line, column) do
    indent = String.length(line) - String.length(String.trim_leading(line, " "))
    indent > column or (indent == column and String.starts_with?(String.trim_leading(line, " "), "- "))
  end

  # Every key line, with its dotted path (`repositories[].agent.model`) and the line that opens the
  # block it sits in: a key's, or a list item's, so two items' keys of one name stay apart.
  defp key_entries(lines) do
    root = %{column: -1, path: "", index: -1, item?: false}

    {_stack, entries} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[root], []}, fn {line, index}, {stack, entries} ->
        case Regex.run(@key_line, line) do
          [_line, spaces, dash, name] -> key_entry({String.length(spaces), dash, name}, index, stack, entries)
          nil -> {stack, entries}
        end
      end)

    Enum.reverse(entries)
  end

  defp key_entry({spaces, dash, name}, index, stack, entries) do
    stack = if dash == "", do: stack, else: open_item(stack, spaces, index)
    column = spaces + String.length(dash)
    stack = Enum.drop_while(stack, &(&1.column >= column))
    [parent | _rest] = stack
    path = if parent.path == "", do: name, else: parent.path <> "." <> name
    frame = %{column: column, path: path, index: index, item?: false}

    {[frame | stack], [%{index: index, column: column, name: name, path: path, parent: parent.index} | entries]}
  end

  # A list item sits under the key at the dash's column or left of it.
  defp open_item(stack, spaces, index) do
    [parent | _rest] = stack = Enum.drop_while(stack, &(&1.column > spaces or (&1.item? and &1.column == spaces)))
    [%{column: spaces, path: parent.path <> "[]", index: index, item?: true} | stack]
  end

  defp read_map(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, %{} = document} -> document
      _not_a_map -> nil
    end
  end

  defp path_of(key), do: String.split(key, ".")

  # The table applied to the parsed YAML, which the rewritten text must equal.
  defp migrate_map(document, [key], migration) when is_map(document) do
    case Map.pop(document, key, :missing) do
      {:missing, _document} -> document
      {_value, rest} when migration.to == nil -> rest
      {_value, rest} when is_map_key(rest, migration.to) -> rest
      {value, rest} -> Map.put(rest, migration.to, drop_children(value, migration.drop_children))
    end
  end

  defp migrate_map(document, [key | path], migration) when is_map(document) do
    case list_key(key) do
      {:list, name} ->
        update_existing(document, name, fn items -> migrate_items(items, path, migration) end)

      :plain ->
        update_existing(document, key, &migrate_map(&1, path, migration))
    end
  end

  defp migrate_map(document, _path, _migration), do: document

  defp migrate_items(items, path, migration) when is_list(items), do: Enum.map(items, &migrate_map(&1, path, migration))
  defp migrate_items(value, _path, _migration), do: value

  defp update_existing(document, key, fun) do
    if Map.has_key?(document, key), do: Map.update!(document, key, fun), else: document
  end

  defp drop_children(value, children) when is_map(value), do: Map.drop(value, children)
  defp drop_children(value, _children), do: value

  defp list_key(key) do
    if String.ends_with?(key, "[]"), do: {:list, String.trim_trailing(key, "[]")}, else: :plain
  end

  defp has_key?(document, [key]) when is_map(document), do: Map.has_key?(document, key)

  defp has_key?(document, [key | path]) when is_map(document) do
    case list_key(key) do
      {:list, name} -> document |> Map.get(name) |> List.wrap() |> Enum.any?(&has_key?(&1, path))
      :plain -> has_key?(Map.get(document, key), path)
    end
  end

  defp has_key?(_document, _path), do: false
end
