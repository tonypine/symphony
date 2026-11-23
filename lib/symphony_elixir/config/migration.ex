defmodule SymphonyElixir.Config.Migration do
  @moduledoc """
  Rewrites the keys of a `symphony.yml` that a release renamed or removed, so an update that changes
  the file's shape needs nothing from the operator. `@migrations` is the table: every key some
  release changed, the sibling it became (or `nil` when it is simply gone), the ticket that changed
  it and the release that first shipped the change. A row with `move_to` moves the key's value to
  another section's key (`execution.providers.anthropic.reserve`): the old line goes, as for a
  removal, and the new key is written where it belongs (`LineEditor`), unless it is already set. A key that moved in a way the table can't say
  stays in `SystemSchema`'s removed keys and is refused.

  A rewrite touches only the lines of the keys it moves, so comments and ordering stay, leaves a
  one-line comment naming the ticket where each key was, and keeps the file as it was beside it.
  The new text is then compared with the table applied to the parsed YAML: a key that isn't on a line
  of its own (`agent: {run_profiles: {...}}`) can't be rewritten, and that is an error naming it and
  the line it sits on, and only the keys the rewrite left in place.

  `symphony start` and `symphony run` migrate the file in place. `symphony check --migrate`, which
  the macOS app runs with a downloaded build before it installs it, checks a migrated copy and
  leaves the file alone.
  """

  alias SymphonyElixir.BuildInfo
  alias SymphonyElixir.Config.{LineEditor, SystemSchema}
  alias SymphonyElixir.Config.Migration.{Lines, RunsMove, RunsRewrite}

  @type error :: {:not_migrated, [{String.t(), pos_integer() | nil}]} | {:runs_not_moved, String.t()} | File.posix()

  @rename_defaults %{drop_children: [], why: nil, move_to: nil}
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
    }),
    Map.merge(@rename_defaults, %{
      key: "execution.usage_limit.headroom_utilization",
      to: nil,
      move_to: "execution.providers.anthropic.reserve",
      ticket: "TP-1535",
      release: "0.0.1.998"
    }),
    Map.merge(@rename_defaults, %{
      key: "execution.concurrency.force_label",
      to: nil,
      ticket: "TP-1611",
      release: "0.0.1.1068",
      why: "a ticket with that label is dispatched like any other now"
    }),
    Map.merge(@rename_defaults, %{
      key: "execution.concurrency.forced_max",
      to: nil,
      ticket: "TP-1611",
      release: "0.0.1.1068",
      why: "Symphony no longer forces tickets ahead of the queue"
    }),
    Map.merge(@rename_defaults, %{
      key: "execution.concurrency.forced_stale_after_hours",
      to: nil,
      ticket: "TP-1611",
      release: "0.0.1.1068",
      why: "Symphony no longer forces tickets ahead of the queue"
    }),
    Map.merge(@rename_defaults, %{
      key: "execution.concurrency.finishing_max",
      to: nil,
      ticket: "TP-1616",
      release: "0.0.1.1072",
      why: "a ticket keeps its slot through Merging, so landing takes no allowance of its own"
    }),
    Map.merge(@rename_defaults, %{
      key: "execution.concurrency.max_by_issue_state",
      to: nil,
      ticket: "TP-1616",
      release: "0.0.1.1072",
      why: "a slot belongs to one ticket until it is done, whatever its state"
    }),
    Map.merge(@rename_defaults, %{
      key: "execution.concurrency.epic_lanes",
      to: nil,
      ticket: "TP-1616",
      release: "0.0.1.1072",
      why: "spare slots go to the sub-tickets of started tickets first, with no lanes reserved"
    })
  ]

  @doc "The table as `symphony config migrations` prints it, for the release's `version.json`."
  @spec migrations_json() :: String.t()
  def migrations_json do
    @migrations
    |> Enum.map(&(&1 |> Map.take([:key, :to, :ticket, :release]) |> Map.put(:to, &1.move_to || &1.to)))
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
      document -> text |> plan_document(document, backup) |> move_runs(backup)
    end
  end

  # After the table's renames, a file that still has the `agent` section has it moved to
  # `execution` and `runs` (`RunsRewrite`).
  defp move_runs({:ok, text, notes}, backup) do
    # The table's stage only returns a text that still reads as a map.
    %{} = document = read_map(text)
    if RunsMove.needed?(document), do: move_runs(text, document, notes, backup), else: {:ok, text, notes}
  end

  defp move_runs({:error, _reason} = error, _backup), do: error

  defp move_runs(text, document, notes, backup) do
    with {:ok, moved, moved_notes} <- RunsRewrite.plan(text, document, backup, BuildInfo.current().version) do
      {:ok, moved, notes ++ moved_notes}
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
      lines = original_text |> String.split("\n") |> Lines.key_entries() |> Map.new(&{&1.path, &1.index + 1})
      " Lines it can't read: " <> Enum.map_join(keys, ", ", &spot(&1, Map.get(lines, &1))) <> "."
    else
      _nothing_to_name -> ""
    end
  end

  @doc "A migration error, in the words `Config error in <path>: ` opens."
  @spec format_error(error()) :: String.t()
  def format_error({:not_migrated, keys}) do
    "Lines it can't rewrite: #{Enum.map_join(keys, ", ", fn {key, line} -> spot(key, line) end)}. " <>
      "Write each of those keys as an indented block, on a line of its own"
  end

  def format_error({:runs_not_moved, message}), do: "The `agent` section moved to `execution` and `runs`, and this file can't be moved as it is: #{message}"

  def format_error(reason), do: "couldn't write the migrated file: #{:file.format_error(reason)}"

  # `12 (`tracker`)`, or the key alone when no line holds it.
  defp spot(key, nil), do: "`#{key}`"
  defp spot(key, line), do: "#{line} (`#{key}`)"

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
    entries = Lines.key_entries(lines)
    matches = for migration <- @migrations, entry <- entries, entry.path == migration.key, do: {migration, entry}

    edits = Enum.flat_map(matches, fn {migration, entry} -> edits(migration, entry, entries, lines, backup) end)
    edits = edits ++ emptied_parents(matches, entries, lines)
    migrated = lines |> Lines.apply_edits(edits) |> Enum.join("\n")
    notes = matches |> Enum.map(fn {migration, entry} -> note(migration, target_set?(migration, entry, entries)) end) |> Enum.uniq()

    case write_moved(migrated, matches, document, entries) do
      {:ok, migrated} -> verify(document, migrated, notes, entries)
      {:error, key} -> {:error, {:not_migrated, [{key, key_line(key, entries)}]}}
    end
  end

  # Each `move_to` row's value written at its new key, once the old line is gone; a key already set
  # stays, and a null value moves nowhere.
  defp write_moved(text, matches, document, entries) do
    Enum.reduce_while(matches, {:ok, text}, fn
      {%{move_to: to} = migration, entry}, {:ok, text} when is_binary(to) ->
        value = get_path(document, path_of(migration.key))

        if is_nil(value) or target_set?(migration, entry, entries) do
          {:cont, {:ok, text}}
        else
          put_moved(text, to, value, migration.key)
        end

      _rename_or_removal, acc ->
        {:cont, acc}
    end)
  end

  defp put_moved(text, to, value, key) do
    case LineEditor.put(text, path_of(to), Jason.encode!(value)) do
      {:ok, text} -> {:cont, {:ok, text}}
      {:error, _reason} -> {:halt, {:error, key}}
    end
  end

  defp verify(document, migrated, notes, entries) do
    expected = Enum.reduce(@migrations, document, &expected(&2, &1))
    migrated_document = read_map(migrated)

    if migrated_document == expected do
      {:ok, migrated, notes}
    else
      {:error, {:not_migrated, blocking(document, migrated_document, entries)}}
    end
  end

  # The keys the rewrite left where they were, each with the line it sits on (or its nearest block's,
  # for a key written inside `{...}`), so the operator edits only those. When every key moved but the
  # text still reads differently (`ledger: &anchor`), each key the table touches is named.
  defp blocking(document, migrated_document, entries) do
    present = for migration <- @migrations, has_key?(document, path_of(migration.key)), do: migration.key
    left = Enum.filter(present, &has_key?(migrated_document, path_of(&1)))
    keys = if left == [], do: present, else: left

    Enum.map(keys, &{&1, key_line(&1, entries)})
  end

  defp key_line(key, entries) do
    segments = path_of(key)

    Enum.find_value(length(segments)..1//-1, fn count ->
      path = segments |> Enum.take(count) |> Enum.join(".")
      # A list item written inside `{...}` has no key line of its own: its list's key has the line.
      paths = [path, String.trim_trailing(path, "[]")]
      Enum.find_value(entries, &(&1.path in paths and &1.index + 1))
    end)
  end

  # The edits of one key, each `{index, lines to remove, lines to insert}`.
  defp edits(migration, entry, entries, lines, backup) do
    comment = comment(migration, entry, entries, backup)

    if migration.to == nil or target_set?(migration, entry, entries) do
      [{entry.index, Lines.block_length(lines, entry), [comment]}]
    else
      renamed = String.replace(Enum.at(lines, entry.index), entry.name <> ":", migration.to <> ":", global: false)
      children = Enum.filter(entries, &(&1.parent == entry.index))
      {dropped, kept} = Enum.split_with(children, &(&1.name in migration.drop_children))
      renamed = if dropped != [] and kept == [], do: empty_map_line(renamed, migration.to), else: renamed

      [{entry.index, 1, [comment, renamed]} | Enum.map(dropped, &{&1.index, Lines.block_length(lines, &1), []})]
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

  defp comment(migration, entry, entries, backup) do
    note = note(migration, target_set?(migration, entry, entries))
    String.duplicate(" ", entry.column) <> "# Symphony: #{note} (#{migration.ticket}). The file as it was: #{backup}."
  end

  defp note(%{move_to: to} = migration, true) when is_binary(to) do
    "v#{migration.release} moved `#{migration.key}` to `#{to}`; your `#{to}` stays and the old key is gone"
  end

  defp note(%{move_to: to} = migration, false) when is_binary(to) do
    "v#{migration.release} moved `#{migration.key}` to `#{to}` in your settings"
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

  defp target_set?(%{move_to: to}, _entry, entries) when is_binary(to), do: Enum.any?(entries, &(&1.path == to))

  defp target_set?(migration, entry, entries) do
    Enum.any?(entries, &(&1.parent == entry.parent and &1.name == migration.to))
  end

  defp read_map(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, %{} = document} -> document
      _not_a_map -> nil
    end
  end

  defp path_of(key), do: String.split(key, ".")

  # The table applied to the parsed YAML, which the rewritten text must equal. A `move_to` row removes
  # the key and sets its value at the new key, unless that is set already or the value is null.
  defp expected(document, %{move_to: to} = migration) when is_binary(to) do
    value = get_path(document, path_of(migration.key))
    removed = migrate_map(document, path_of(migration.key), migration)

    if is_nil(value) or has_key?(removed, path_of(to)), do: removed, else: put_path(removed, path_of(to), value)
  end

  defp expected(document, migration), do: migrate_map(document, path_of(migration.key), migration)

  defp get_path(document, path), do: Enum.reduce(path, document, &if(is_map(&2), do: Map.get(&2, &1)))

  defp put_path(document, [key], value), do: Map.put(document, key, value)

  defp put_path(document, [key | path], value) do
    child = Map.get(document, key)
    Map.put(document, key, put_path(if(is_map(child), do: child, else: %{}), path, value))
  end

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
