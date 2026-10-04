defmodule SymphonyElixir.QaAndroid.UiTree do
  @moduledoc """
  Parses the XML `uiautomator dump` prints into the flat node list of
  `qa_android_ui_tree`, and filters and caps it.

  The app under test sets the text in the dump, so the parser creates no atoms
  and reads only `<node>` elements and their quoted attributes. Each node gets a
  path of child positions from the hierarchy root: `0.2.1` is the second child
  of the third child of the first top-level node.
  """

  @flags ~w(clickable focused enabled checked scrollable)
  @node ~r/<node((?:\s+[\w:.-]+="[^"]*")*)\s*(\/?)>|<\/node>/
  @attribute ~r/([\w:.-]+)="([^"]*)"/
  @bounds ~r/\A\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]\z/
  @entity ~r/&(#x[0-9A-Fa-f]{1,6}|#[0-9]{1,7}|lt|gt|amp|quot|apos);/

  @typedoc "A node's depth (1 for a top-level node), its package and its tool payload."
  @type entry :: {pos_integer(), String.t() | nil, map()}
  @type filters :: %{optional(:text | :resource_id | :class) => String.t() | nil}

  @doc "Parses `uiautomator dump` output into entries in document order, or `:error` without a hierarchy."
  @spec parse(String.t()) :: {:ok, [entry()]} | :error
  def parse(output) do
    case Regex.run(~r/<hierarchy\b[^>]*>(.*)<\/hierarchy>/s, output) do
      [_match, body] -> {:ok, entries(body)}
      nil -> :error
    end
  end

  @doc """
  Keeps the nodes that match every filter, no deeper than `max_depth`, and of
  those at most `max_nodes` whose JSON fits in `max_bytes`. Returns the nodes
  and one note for each cap that left nodes out.
  """
  @spec select([entry()], filters(), pos_integer(), pos_integer(), pos_integer()) :: {[map()], [String.t()]}
  def select(entries, filters, max_depth, max_nodes, max_bytes) do
    {shallow, deep} =
      entries
      |> Enum.filter(fn {_depth, _package, node} -> matches?(node, filters) end)
      |> Enum.split_with(fn {depth, _package, _node} -> depth <= max_depth end)

    {shown, cut, cap} = take(Enum.map(shallow, &elem(&1, 2)), max_nodes, max_bytes, [])

    notes =
      [
        deep != [] && "#{length(deep)} nodes deeper than max_depth #{max_depth}",
        cap == :nodes && "#{cut} more nodes after max_nodes #{max_nodes}",
        cap == :bytes && "#{cut} more nodes over the #{max_bytes}-byte limit"
      ]
      |> Enum.filter(&is_binary/1)

    {shown, notes}
  end

  defp entries(body) do
    {entries, _levels} = @node |> Regex.scan(body) |> Enum.reduce({[], [{[], 0}]}, &token/2)
    Enum.reverse(entries)
  end

  # `levels` holds, for each open element, its path and the position of its
  # next child.
  defp token(["</node>"], {entries, [_closed | [_parent | _rest] = levels]}), do: {entries, levels}
  defp token(["</node>"], acc), do: acc

  defp token([_tag, attributes, closing], {entries, [{parent, index} | levels]}) do
    path = parent ++ [index]
    levels = [{parent, index + 1} | levels]
    levels = if closing == "/", do: levels, else: [{path, 0} | levels]
    {[entry(path, attributes) | entries], levels}
  end

  defp entry(path, attributes) do
    attrs = for [_match, name, value] <- Regex.scan(@attribute, attributes), into: %{}, do: {name, unescape(value)}

    node =
      %{"path" => Enum.join(path, "."), "class" => Map.get(attrs, "class", ""), "bounds" => bounds(attrs["bounds"])}
      |> put_present("text", attrs["text"])
      |> put_present("content-desc", attrs["content-desc"])
      |> put_present("resource-id", attrs["resource-id"])
      |> Map.merge(Map.new(@flags, &{&1, attrs[&1] == "true"}))

    {length(path), attrs["package"], node}
  end

  defp put_present(node, _key, value) when value in [nil, ""], do: node
  defp put_present(node, key, value), do: Map.put(node, key, value)

  defp bounds(value) when is_binary(value) do
    case Regex.run(@bounds, value, capture: :all_but_first) do
      [left, top, right, bottom] ->
        [left, top, right, bottom] = Enum.map([left, top, right, bottom], &String.to_integer/1)
        %{"left" => left, "top" => top, "right" => right, "bottom" => bottom}

      nil ->
        nil
    end
  end

  defp bounds(_value), do: nil

  defp unescape(value) do
    Regex.replace(@entity, value, fn match, entity ->
      case entity do
        "lt" -> "<"
        "gt" -> ">"
        "amp" -> "&"
        "quot" -> "\""
        "apos" -> "'"
        "#x" <> hex -> codepoint(String.to_integer(hex, 16), match)
        "#" <> decimal -> codepoint(String.to_integer(decimal), match)
      end
    end)
  end

  defp codepoint(code, match) do
    case :unicode.characters_to_binary([code]) do
      binary when is_binary(binary) -> binary
      _invalid -> match
    end
  end

  defp matches?(node, filters) do
    text_matches?(node, filters[:text]) and
      suffix_matches?(node["resource-id"], filters[:resource_id], "/") and
      suffix_matches?(node["class"], filters[:class], ".")
  end

  defp text_matches?(_node, nil), do: true

  defp text_matches?(node, text) do
    needle = String.downcase(text)
    Enum.any?([node["text"], node["content-desc"]], &(is_binary(&1) and String.contains?(String.downcase(&1), needle)))
  end

  # `com.example.app:id/login` matches `login`, and `android.widget.Button` matches `Button`.
  defp suffix_matches?(_value, nil, _separator), do: true
  defp suffix_matches?(nil, _filter, _separator), do: false
  defp suffix_matches?(value, filter, separator), do: value == filter or String.ends_with?(value, separator <> filter)

  defp take([], _max_nodes, _budget, shown), do: {Enum.reverse(shown), 0, nil}
  defp take(nodes, 0, _budget, shown), do: {Enum.reverse(shown), length(nodes), :nodes}

  defp take([node | rest] = nodes, max_nodes, budget, shown) do
    size = byte_size(Jason.encode!(node)) + 1

    if size > budget do
      {Enum.reverse(shown), length(nodes), :bytes}
    else
      take(rest, max_nodes - 1, budget - size, [node | shown])
    end
  end
end
