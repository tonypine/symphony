defmodule SymphonyElixir.Setup.ConfigLines do
  @moduledoc """
  Finds the line of `symphony.yml` that sets a key, so a Setup problem can say where it is.

  A dotted path of map keys (`auto_review.enabled`) is followed through the block indentation of the
  file. A path through a list item (`repositories[app].state_machine`) or a key written in flow
  style (`{enabled: true}`) has no line: the problem then names the key alone.
  """

  @doc "The 1-based line that sets `path` in `content`, or nil."
  @spec line(String.t(), String.t()) :: pos_integer() | nil
  def line(content, path) when is_binary(content) and is_binary(path) do
    segments = String.split(path, ".")

    if Enum.any?(segments, &String.contains?(&1, ["[", "]"])),
      do: nil,
      else: content |> String.split(~r/\R/) |> Enum.with_index(1) |> find(segments, -1, nil)
  end

  defp find(_lines, [], _parent_indent, line), do: line

  defp find(lines, [key | rest], parent_indent, _line) do
    children = lines |> Enum.reject(&ignored?/1) |> Enum.take_while(fn {text, _number} -> indent(text) > parent_indent end)

    with [{first, _number} | _rest] <- children,
         child_indent = indent(first),
         [{text, number} | below] <- Enum.drop_while(children, &(not sets?(&1, key, child_indent))) do
      find(below, rest, indent(text), number)
    else
      [] -> nil
    end
  end

  defp sets?({text, _number}, key, indent),
    do: indent(text) == indent and String.starts_with?(String.trim_leading(text), [key <> ":", ~s("#{key}":), "'#{key}':"])

  defp ignored?({text, _number}), do: String.trim(text) == "" or String.starts_with?(String.trim_leading(text), "#")

  defp indent(text), do: String.length(text) - String.length(String.trim_leading(text, " "))
end
