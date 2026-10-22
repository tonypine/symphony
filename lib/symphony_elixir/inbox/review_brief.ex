defmodule SymphonyElixir.Inbox.ReviewBrief do
  @moduledoc """
  Reads a ticket's `## Review brief` comment (the format in `priv/playbook/review_brief.liquid`)
  into the parts the Inbox shows:

  - `headline`: the line after `**What to review:**`;
  - `what_to_review`: the bullets under it, each with its text and the links it holds;
  - `what_changed`: the bullets under `**What changed since the last brief:**`;
  - `moves`: the `Approve:`, `Change:` and `Reject:` lines under `**How to approve / change / reject:**`.

  The brief's `**Decisions needed:**` are not read: a plan's questions are requests raised through
  `SymphonyElixir.DecisionRequest`, which the brief links to and the Inbox lists from the requests
  themselves (`SymphonyElixir.Inbox.Item`).

  A body without the `**What to review:**` line doesn't parse: it comes back as `raw` markdown,
  for the app to show as text.
  """

  @heading "## Review brief"
  @section ~r/^\s*\*\*(.+?):\*\*\s*(.*)$/
  @list_item ~r/^\s*(?:[-*]|\d+[.)])\s+(.*)$/
  @sub_item ~r/^\s+[-*]\s+(.*)$/
  @move_field ~r/^(Approve|Change|Reject):\s*(.*)$/i
  @markdown_link ~r/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/
  @bare_url ~r/(?<![(\[])\bhttps?:\/\/[^\s)>\]]+/

  @type link :: %{label: String.t(), url: String.t()}
  @type parsed :: %{
          format: String.t(),
          headline: String.t() | nil,
          what_to_review: [%{text: String.t(), links: [link()]}],
          what_changed: [String.t()],
          moves: [%{move: String.t(), text: String.t()}]
        }
  @type raw :: %{format: String.t(), markdown: String.t()}

  @doc "True when `body` is a review brief comment."
  @spec brief?(term()) :: boolean()
  def brief?(body) when is_binary(body), do: String.starts_with?(String.trim_leading(body), @heading)
  def brief?(_body), do: false

  @doc "The brief's parts, or `%{format: \"raw\", markdown: body}` when it has no `**What to review:**` line."
  @spec parse(String.t()) :: parsed() | raw()
  def parse(body) when is_binary(body) do
    sections = sections(body)

    case Map.fetch(sections, "what to review") do
      {:ok, {headline, lines}} ->
        %{
          format: "parsed",
          headline: blank_to_nil(headline),
          what_to_review: lines |> items() |> Enum.map(&%{text: plain(&1), links: links(&1)}),
          what_changed: sections |> section_lines("what changed since the last brief") |> items() |> Enum.map(&plain/1),
          moves: sections |> section_lines("how to approve / change / reject") |> moves()
        }

      :error ->
        %{format: "raw", markdown: String.trim(body)}
    end
  end

  # Each `**Name:** rest` line starts a section holding the lines up to the next one.
  defp sections(body) do
    body
    |> String.split(~r/\R/)
    |> Enum.reduce({nil, %{}}, fn line, {current, acc} ->
      case Regex.run(@section, line) do
        [_, name, rest] ->
          key = String.downcase(String.trim(name))
          {key, Map.put_new(acc, key, {String.trim(rest), []})}

        nil when is_nil(current) ->
          {current, acc}

        nil ->
          {current, Map.update!(acc, current, fn {headline, lines} -> {headline, lines ++ [line]} end)}
      end
    end)
    |> elem(1)
  end

  defp section_lines(sections, key) do
    case Map.get(sections, key) do
      {first, lines} -> [first | lines]
      nil -> []
    end
  end

  # Top-level list items, with their continuation lines folded in.
  defp items(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      cond do
        Regex.match?(@list_item, line) and not Regex.match?(@sub_item, line) ->
          [_, text] = Regex.run(@list_item, line)
          [String.trim(text) | acc]

        acc != [] and String.trim(line) != "" ->
          [head | rest] = acc
          [head <> " " <> String.trim(line) | rest]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == "" or none?(&1)))
  end

  defp moves(lines) do
    for item <- items(lines), match = Regex.run(@move_field, item), match != nil do
      [_, move, text] = match
      %{move: String.downcase(move), text: plain(text)}
    end
  end

  @doc "The links in a line of markdown: `[label](url)` ones, then bare URLs."
  @spec links(String.t()) :: [link()]
  def links(text) do
    markdown = for [_, label, url] <- Regex.scan(@markdown_link, text), do: %{label: label, url: url}
    rest = Regex.replace(@markdown_link, text, "")
    bare = for [url] <- Regex.scan(@bare_url, rest), do: %{label: url, url: url}
    markdown ++ bare
  end

  # A line's text with its markdown links turned into their labels and its emphasis dropped.
  defp plain(text) do
    @markdown_link
    |> Regex.replace(text, "\\1")
    |> String.replace(~r/\*\*|__|`/, "")
    |> String.trim()
  end

  defp none?(text), do: String.downcase(String.trim(text)) in ["none.", "none"]

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> if none?(trimmed), do: nil, else: trimmed
    end
  end
end
