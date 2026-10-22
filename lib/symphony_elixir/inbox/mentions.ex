defmodule SymphonyElixir.Inbox.Mentions do
  @moduledoc """
  The ticket and pull request mentions in the text an Inbox item shows
  (`SymphonyElixir.Inbox.Item`), and the plain one-sentence summaries the app's popovers show for
  them (`SymphonyElixir.Inbox.References`).

  A mention is kept exactly as it is written, since the app finds it in the text by that string:

  - a ticket identifier, `TP-892` (`[A-Z][A-Z0-9]*-\\d+`);
  - a pull request, `PR #448` or a bare `#448`, both resolved against the item's repo.

  The text scanned is what the app shows of each kind: an action's title, question, why, what waits
  if nobody answers, what it unblocks, its steps, each option's label, effect and trade-offs and why
  the recommended one; a plan's parsed brief (headline, what to review, what changed and moves, or
  the raw markdown of a brief that didn't parse) and each of its questions as an action's; a
  clarify item's findings and questions; a blocked item's reason and what clears it.
  """

  @mention ~r/(?<![\w-])PR\s?#\d+(?![\w-])|(?<![\w&#\/])#\d+(?![\w-])|(?<![\w-])[A-Z][A-Z0-9]*-\d+(?![\w-])/
  @pull_request ~r/^(?:PR\s?)?#(\d+)$/
  @summary_max 160

  @type mention :: {:ticket, String.t()} | {:pull_request, pos_integer()}

  @doc "Every text an item of `kind` shows in `review`, plus its ask, in reading order."
  @spec texts(map()) :: [String.t()]
  def texts(item) when is_map(item) do
    [Map.get(item, :ask) | review_texts(Map.get(item, :kind), Map.get(item, :review) || %{})]
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
  end

  defp review_texts(:action, review), do: request_texts(review)

  defp review_texts(:plan, review), do: [brief_texts(review[:brief]) | Enum.map(review[:decisions] || [], &request_texts/1)]
  defp review_texts(:clarify, review), do: [review[:found], review[:questions]]
  defp review_texts(:blocked, review), do: [review[:reason], review[:clearing_condition]]
  defp review_texts(_kind, _review), do: []

  defp request_texts(review) do
    [
      review[:title],
      review[:question],
      review[:why],
      review[:if_unanswered],
      review[:unblocks],
      review[:steps],
      Enum.map(review[:options] || [], &option_texts/1),
      review[:recommendation_reason]
    ]
  end

  defp option_texts(option), do: [option[:label], option[:effect], Enum.map(option[:tradeoffs] || [], & &1[:text])]

  defp brief_texts(%{format: "parsed"} = brief) do
    [
      brief.headline,
      Enum.map(brief.what_to_review, & &1.text),
      brief.what_changed,
      Enum.map(brief.moves, & &1.text)
    ]
  end

  defp brief_texts(%{markdown: markdown}), do: [markdown]
  defp brief_texts(_brief), do: []

  @doc "The mentions in `texts`, each once, as written, in the order they first appear."
  @spec scan([String.t()]) :: [String.t()]
  def scan(texts) when is_list(texts) do
    texts
    |> Enum.flat_map(&Regex.scan(@mention, &1))
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc "What a mention names: a ticket identifier or a pull request number."
  @spec classify(String.t()) :: mention()
  def classify(mention) when is_binary(mention) do
    case Regex.run(@pull_request, mention) do
      [_, number] -> {:pull_request, String.to_integer(number)}
      nil -> {:ticket, mention}
    end
  end

  @doc """
  The first sentence of `text` as plain text: markdown, links, URLs, HTML comments and headings
  removed, on one line, at most #{@summary_max} characters (cut with `…`). Nil when nothing is left.
  """
  @spec summary(String.t() | nil) :: String.t() | nil
  def summary(text) when is_binary(text) do
    text
    |> plain()
    |> first_sentence()
    |> truncate()
  end

  def summary(_text), do: nil

  @doc "`text` without markdown, links, URLs, HTML comments or headings, on one line."
  @spec plain(String.t()) :: String.t()
  def plain(text) when is_binary(text) do
    text
    |> String.replace(~r/<!--.*?-->/s, " ")
    |> String.replace(~r/```.*?```/s, " ")
    |> String.split(~r/\R/)
    |> Enum.reject(&(&1 =~ ~r/^\s*(#+\s|#+$|[-*_]{3,}\s*$|\|)/))
    |> Enum.join("\n")
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, " ")
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/<?\bhttps?:\/\/[^\s)>\]]+>?/, " ")
    |> String.replace(~r/<\/?[A-Za-z][^>]*>/, "")
    |> String.replace(~r/^\s*(?:>\s*)+/m, "")
    |> String.replace(~r/^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/m, "")
    |> String.replace(~r/(\*\*|__|~~|`|\*|(?<!\w)_|_(?!\w))/, "")
    |> String.replace(~r/[\[\]]/, "")
    |> String.split()
    |> Enum.join(" ")
    |> String.replace(~r/ ([,.;:!?])/, "\\1")
  end

  defp first_sentence(""), do: nil

  defp first_sentence(text) do
    case Regex.run(~r/^.*?[.!?](?=\s|$)/u, text) do
      [sentence] -> sentence
      nil -> text
    end
  end

  defp truncate(nil), do: nil

  defp truncate(text) do
    if String.length(text) > @summary_max,
      do: String.slice(text, 0, @summary_max - 1) |> String.trim_trailing() |> Kernel.<>("…"),
      else: text
  end
end
