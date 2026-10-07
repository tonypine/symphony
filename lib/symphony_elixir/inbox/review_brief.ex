defmodule SymphonyElixir.Inbox.ReviewBrief do
  @moduledoc """
  Reads a ticket's `## Review brief` comment (the format in `priv/playbook/review_brief.liquid`)
  into the parts the Inbox shows:

  - `headline`: the line after `**What to review:**`;
  - `what_to_review`: the bullets under it, each with its text and the links it holds;
  - `what_changed`: the bullets under `**What changed since the last brief:**`;
  - `decisions`: each numbered question under `**Decisions needed:**`, with its options, the
    recommendation and the index of the recommended option when it can be told (`None.` is none);
  - `moves`: the `Approve:`, `Change:` and `Reject:` lines under `**How to approve / change / reject:**`;
  - `supervisor_check`: a `## Supervisor check` block below the brief, as markdown.

  A body without the `**What to review:**` line doesn't parse: it comes back as `raw` markdown,
  for the app to show as text.
  """

  @heading "## Review brief"
  @section ~r/^\s*\*\*(.+?):\*\*\s*(.*)$/
  @list_item ~r/^\s*(?:[-*]|\d+[.)])\s+(.*)$/
  @numbered_item ~r/^\s*\d+[.)]\s+(.*)$/
  @sub_item ~r/^\s+[-*]\s+(.*)$/
  @options_field ~r/^Options?:\s*(.*)$/i
  @recommendation_field ~r/^Recommend(?:ation|ed):\s*(.*)$/i
  @move_field ~r/^(Approve|Change|Reject):\s*(.*)$/i
  @markdown_link ~r/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/
  @bare_url ~r/(?<![(\[])\bhttps?:\/\/[^\s)>\]]+/
  @supervisor_check ~r/^##\s+Supervisor check\s*$/m
  @option_letter ~r/^(?:option\s+)?([A-Z])(?:\b|[.):])/i

  @type link :: %{label: String.t(), url: String.t()}
  @type decision :: %{
          question: String.t(),
          options: [String.t()],
          recommendation: String.t() | nil,
          recommended: non_neg_integer() | nil
        }
  @type parsed :: %{
          format: String.t(),
          headline: String.t() | nil,
          what_to_review: [%{text: String.t(), links: [link()]}],
          what_changed: [String.t()],
          decisions: [decision()],
          moves: [%{move: String.t(), text: String.t()}],
          supervisor_check: String.t() | nil
        }
  @type raw :: %{format: String.t(), markdown: String.t()}

  @doc "True when `body` is a review brief comment."
  @spec brief?(term()) :: boolean()
  def brief?(body) when is_binary(body), do: String.starts_with?(String.trim_leading(body), @heading)
  def brief?(_body), do: false

  @doc "The brief's parts, or `%{format: \"raw\", markdown: body}` when it has no `**What to review:**` line."
  @spec parse(String.t()) :: parsed() | raw()
  def parse(body) when is_binary(body) do
    {brief, check} = split_supervisor_check(body)
    sections = sections(brief)

    case Map.fetch(sections, "what to review") do
      {:ok, {headline, lines}} ->
        %{
          format: "parsed",
          headline: blank_to_nil(headline),
          what_to_review: lines |> items() |> Enum.map(&%{text: plain(&1), links: links(&1)}),
          what_changed: sections |> section_lines("what changed since the last brief") |> items() |> Enum.map(&plain/1),
          decisions: sections |> section_lines("decisions needed") |> decisions(),
          moves: sections |> section_lines("how to approve / change / reject") |> moves(),
          supervisor_check: check
        }

      :error ->
        %{format: "raw", markdown: String.trim(body)}
    end
  end

  defp split_supervisor_check(body) do
    case Regex.split(@supervisor_check, body, parts: 2) do
      [brief, check] -> {brief, blank_to_nil("## Supervisor check\n" <> String.trim(check))}
      [brief] -> {brief, nil}
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

  defp decisions(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      cond do
        Regex.match?(@numbered_item, line) and not Regex.match?(@sub_item, line) ->
          [_, question] = Regex.run(@numbered_item, line)
          [%{question: String.trim(question), options: [], recommendation: nil} | acc]

        acc != [] and Regex.match?(@sub_item, line) ->
          [_, field] = Regex.run(@sub_item, line)
          [decision | rest] = acc
          [decision_field(decision, String.trim(field)) | rest]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&Map.put(&1, :recommended, recommended_index(&1.options, &1.recommendation)))
  end

  defp decision_field(decision, field) do
    cond do
      match = Regex.run(@options_field, field) ->
        options = match |> List.last() |> String.split(";") |> Enum.map(&plain/1) |> Enum.reject(&(&1 == ""))
        %{decision | options: decision.options ++ options}

      match = Regex.run(@recommendation_field, field) ->
        %{decision | recommendation: match |> List.last() |> plain() |> blank_to_nil()}

      true ->
        decision
    end
  end

  @doc """
  The index of the option `recommendation` names: an option whose text it starts with or holds
  (the longest such), else the option of the letter it starts with (`A`, `Option B`), else nil.
  """
  @spec recommended_index([String.t()], String.t() | nil) :: non_neg_integer() | nil
  def recommended_index(_options, nil), do: nil
  def recommended_index([], _recommendation), do: nil

  def recommended_index(options, recommendation) do
    wanted = String.downcase(recommendation)

    by_text =
      options
      |> Enum.with_index()
      |> Enum.filter(fn {option, _index} -> names?(wanted, option_key(option)) end)
      |> Enum.max_by(fn {option, _index} -> String.length(option_key(option)) end, fn -> nil end)

    case by_text do
      {_option, index} -> index
      nil -> letter_index(options, recommendation)
    end
  end

  # Whether `text` holds `key` as whole words.
  defp names?(_text, ""), do: false
  defp names?(text, key), do: Regex.match?(~r/(?<![\p{L}\p{N}])#{Regex.escape(key)}(?![\p{L}\p{N}])/u, text)

  # An option's name: the text before its first `:` or ` (`, which is where a description starts.
  defp option_key(option) do
    option |> String.split([":", " (", " — ", " - "], parts: 2) |> hd() |> String.trim() |> String.downcase()
  end

  defp letter_index(options, recommendation) do
    with [_, letter] <- Regex.run(@option_letter, recommendation),
         index = :binary.first(String.upcase(letter)) - ?A,
         true <- index < length(options) do
      index
    else
      _no_letter -> nil
    end
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
