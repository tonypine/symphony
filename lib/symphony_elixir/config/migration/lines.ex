defmodule SymphonyElixir.Config.Migration.Lines do
  @moduledoc """
  A `symphony.yml` as lines: where each key sits, how far its block runs, and edits applied to
  the lines. A rewrite built from these touches only the lines it names, so comments and
  ordering stay.
  """

  @typedoc "A key line: its index, column, name, dotted path and the index of the line that opens its block."
  @type entry :: %{
          index: non_neg_integer(),
          column: non_neg_integer(),
          name: String.t(),
          path: String.t(),
          parent: integer()
        }
  @typedoc "An edit: at `index`, remove this many lines and insert these."
  @type edit :: {non_neg_integer(), non_neg_integer(), [String.t()]}

  @key_line ~r/\A( *)((?:- +)?)([A-Za-z0-9_][A-Za-z0-9_\-]*):(?:\s.*)?\z/

  @doc "The lines with every edit applied, from the last line up so each edit's index still holds."
  @spec apply_edits([String.t()], [edit()]) :: [String.t()]
  def apply_edits(lines, edits) do
    edits
    |> Enum.sort_by(fn {index, _remove, _insert} -> index end, :desc)
    |> Enum.reduce(lines, fn {index, remove, insert}, lines ->
      Enum.take(lines, index) ++ insert ++ Enum.drop(lines, index + remove)
    end)
  end

  @doc "How many lines a key's block has: to its last line of content, so a comment or a blank line after it stays."
  @spec block_length([String.t()], entry()) :: pos_integer()
  def block_length(lines, entry) do
    lines
    |> Enum.drop(entry.index + 1)
    |> Enum.take_while(&(not content?(&1) or inside_block?(&1, entry.column)))
    |> Enum.reverse()
    |> Enum.drop_while(&(not content?(&1)))
    |> length()
    |> Kernel.+(1)
  end

  @doc "Whether a line holds a key or a value: not blank and not a comment."
  @spec content?(String.t()) :: boolean()
  def content?(line) do
    trimmed = String.trim(line)
    trimmed != "" and not String.starts_with?(trimmed, "#")
  end

  defp inside_block?(line, column) do
    indent = String.length(line) - String.length(String.trim_leading(line, " "))
    indent > column or (indent == column and String.starts_with?(String.trim_leading(line, " "), "- "))
  end

  # Every key line, with its dotted path (`repositories[].runs.default`) and the line that opens the
  # block it sits in: a key's, or a list item's, so two items' keys of one name stay apart.
  @spec key_entries([String.t()]) :: [entry()]
  def key_entries(lines) do
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
end
