defmodule SymphonyElixir.Config.LineEditor do
  @moduledoc """
  Sets values at key paths of a `symphony.yml`, such as `["github", "webhooks", "enabled"]`,
  rewriting only the line that holds the key, or inserting it (and the sections above it) when it
  is missing, so comments, ordering and indentation stay as they are. The macOS app edits the file
  the same way (`ConfigSetting` in `SymphonyBarCore`).

  A section above a key that holds an inline value (`webhooks: {enabled: true}`) can't be edited
  one line at a time: `{:error, {:not_a_block, key}}`.
  """

  @default_step 2
  @key_line ~r/\A( *)([A-Za-z0-9_][A-Za-z0-9_\-]*):(.*)\z/
  @comment ~r/\s+#.*\z/

  @type path :: [String.t()]
  @type error :: {:not_a_block, String.t()} | {:unreadable, term()} | {:not_written, String.t()}

  @doc "`text` with the last key of `path` set to `value` (YAML, written as given)."
  @spec put(String.t(), path(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def put(text, [_ | _] = path, value) when is_binary(text) and is_binary(value) do
    lines = String.split(text, "\n")
    {body, trailer} = if List.last(lines) == "", do: {Enum.drop(lines, -1), [""]}, else: {lines, []}

    with {:ok, body} <- put_lines(body, path, value) do
      {:ok, Enum.join(body ++ trailer, "\n")}
    end
  end

  @doc """
  Sets every `{path, value}` in the file at `path` and replaces it with a rename, so the config
  watcher never reads half a file. The new text must still parse as YAML and hold the values; the
  file is left as it is otherwise, or when nothing changes. The file keeps its permissions.
  """
  @spec write(Path.t(), [{path(), String.t()}]) :: :ok | {:error, error() | File.posix()}
  def write(file, changes) when is_binary(file) and is_list(changes) do
    with {:ok, %File.Stat{mode: mode}} <- File.stat(file),
         {:ok, text} <- File.read(file),
         {:ok, updated} <- put_all(text, changes),
         :ok <- verify(updated, changes) do
      if updated == text, do: :ok, else: replace(file, updated, mode)
    end
  end

  defp put_all(text, changes) do
    Enum.reduce_while(changes, {:ok, text}, fn {path, value}, {:ok, text} ->
      case put(text, path, value) do
        {:ok, text} -> {:cont, {:ok, text}}
        error -> {:halt, error}
      end
    end)
  end

  defp verify(text, changes) do
    case YamlElixir.read_from_string(text) do
      {:ok, document} ->
        changes |> Enum.find(fn {path, value} -> not same_value?(document, path, value) end) |> written()

      {:error, reason} ->
        {:error, {:unreadable, reason}}
    end
  end

  defp written(nil), do: :ok
  defp written({path, _value}), do: {:error, {:not_written, Enum.join(path, ".")}}

  # The whole text parsed, so the value alone does too.
  defp same_value?(document, path, value) do
    {:ok, %{"value" => expected}} = YamlElixir.read_from_string("value: " <> value)
    get(document, path) == expected
  end

  defp get(document, path), do: Enum.reduce(path, document, fn key, value -> if is_map(value), do: Map.get(value, key, :missing), else: :missing end)

  defp replace(file, text, mode) do
    temporary = Path.join(Path.dirname(file), ".#{Path.basename(file)}.#{System.unique_integer([:positive])}")

    with :ok <- File.write(temporary, text),
         :ok <- File.chmod(temporary, Bitwise.band(mode, 0o7777)),
         :ok <- File.rename(temporary, file) do
      :ok
    else
      error ->
        _ = File.rm(temporary)
        error
    end
  end

  # Walks `path` down the indented blocks of `lines`, from the whole file.
  defp put_lines(lines, path, value), do: put_in_range(lines, path, value, {0, length(lines)}, nil, @default_step)

  defp put_in_range(lines, [name | rest] = path, value, range, parent, step) do
    case child(lines, name, range) do
      nil ->
        {:ok, insert(lines, path, value, column(lines, range, parent, step), step, parent)}

      {index, indent, rest_of_line} when rest == [] ->
        line = String.duplicate(" ", indent) <> name <> ":" <> replace_value(rest_of_line, value)
        {:ok, List.replace_at(lines, index, line)}

      {index, indent, rest_of_line} ->
        if value_of(rest_of_line) == "",
          do: descend(lines, rest, value, {index, indent}, step),
          else: {:error, {:not_a_block, name}}
    end
  end

  # Into the block under the key at `index`, whose children set the indent step when it has any.
  defp descend(lines, path, value, {index, indent} = parent, step) do
    range = block(lines, index, indent)
    child = child_indent(lines, range)
    put_in_range(lines, path, value, range, parent, if(child, do: child - indent, else: step))
  end

  defp column(lines, range, parent, step) do
    case {child_indent(lines, range), parent} do
      {nil, nil} -> 0
      {nil, {_index, indent}} -> indent + step
      {indent, _parent} -> indent
    end
  end

  defp insert(lines, missing, value, column, step, parent) do
    count = length(missing)

    new =
      missing
      |> Enum.with_index()
      |> Enum.map(fn {name, offset} ->
        line = String.duplicate(" ", column + offset * step) <> name <> ":"
        if offset == count - 1, do: line <> " " <> value, else: line
      end)

    case parent do
      nil -> lines ++ new
      {index, _indent} -> List.insert_at(lines, index + 1, new) |> List.flatten()
    end
  end

  # The key lines directly inside `range` sit at its smallest indent.
  defp child(lines, name, range) do
    case child_indent(lines, range) do
      nil ->
        nil

      indent ->
        Enum.find_value(keys(lines, range), fn
          {index, ^indent, ^name, rest} -> {index, indent, rest}
          _key -> nil
        end)
    end
  end

  defp child_indent(lines, range) do
    lines
    |> keys(range)
    |> Enum.map(fn {_index, indent, _name, _rest} -> indent end)
    |> Enum.min(fn -> nil end)
  end

  defp keys(lines, {from, to}) do
    for index <- from..(to - 1)//1, key = key_line(Enum.at(lines, index)), key != nil do
      {indent, name, rest} = key
      {index, indent, name, rest}
    end
  end

  defp key_line(line) do
    case Regex.run(@key_line, line) do
      [_line, spaces, name, rest] -> {String.length(spaces), name, rest}
      nil -> nil
    end
  end

  # A block runs to the next line, other than a blank or a comment, indented no deeper than its key.
  defp block(lines, index, indent) do
    to =
      lines
      |> Enum.with_index()
      |> Enum.drop(index + 1)
      |> Enum.find_value(length(lines), fn {line, at} -> if content?(line) and indentation(line) <= indent, do: at end)

    {index + 1, to}
  end

  defp content?(line) do
    trimmed = String.trim(line)
    trimmed != "" and not String.starts_with?(trimmed, "#")
  end

  defp indentation(line), do: String.length(line) - String.length(String.trim_leading(line, " "))

  defp value_of(rest), do: rest |> String.replace(@comment, "") |> String.trim()

  # Keeps a trailing comment after the new value.
  defp replace_value(rest, value) do
    case Regex.run(@comment, rest) do
      [comment] -> " " <> value <> comment
      nil -> " " <> value
    end
  end
end
