defmodule SymphonyElixir.IssueSummary do
  @moduledoc """
  The Symphony-owned summary block at the end of an issue description.

  The block sits between `<!-- symphony:summary:start -->` and `<!-- symphony:summary:end -->` and
  shows where the ticket stands: a one-line status, a link to the review brief, the artifacts and a
  dated changelog, newest first and capped at 20 entries. `put/3` replaces the block, or appends
  it when the description has none, and leaves every byte outside it unchanged, so a person's edits
  to the rest of the description survive; only an empty heading Linear left right before it goes
  (`drop_empty_heading/1`). `strip/1` removes it, so a description read as
  requirements never carries Symphony's own summary.

  The changelog also carries a line for each push and each verdict on the ticket's history
  (`event_entries/1`, from `attempt.pushed` and `verdict.recorded`): `put/4` and `put_changelog/2`
  merge them into the entries the block holds, each line once, newest day first, so the block reads
  the same whoever wrote the last entry. A line is found again by its text after Linear rewrote
  the list (`*` bullets), so it is never written twice.
  """

  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketEvents.Event

  @start_marker "<!-- symphony:summary:start -->"
  @end_marker "<!-- symphony:summary:end -->"
  @heading "### Symphony summary"
  @changelog_label "**Changelog:**"
  @changelog_cap 20
  @field_max_length 300
  @artifact_cap 20
  @url_pattern ~r{\Ahttps?://[^\s()<>]+\z}
  # Linear stores a list item written `- ` as `* `.
  @list_item ~r/^[-*+] /
  # A heading with nothing in it at the end of a text: what Linear made of a marker line written
  # right above `---` (a setext heading), never a person's text.
  @empty_heading ~r/(^|\n)#+[ \t]*\s*\z/
  @entry_date ~r/^- (\d{4}-\d{2}-\d{2})\b/
  @event_types ["attempt.pushed", "verdict.recorded"]
  @kind_names %{"qa" => "QA", "ci_fix" => "CI Fix", "code_review" => "Code Review", "epic_review" => "Epic Review"}

  @type artifact :: %{label: String.t(), url: String.t()}
  @type t :: %{status: String.t(), review_brief: String.t() | nil, artifacts: [artifact()], entry: String.t()}

  @doc "The marker that opens the block."
  @spec start_marker() :: String.t()
  def start_marker, do: @start_marker

  @doc "The marker that closes the block."
  @spec end_marker() :: String.t()
  def end_marker, do: @end_marker

  @doc "How many changelog entries the block keeps."
  @spec changelog_cap() :: pos_integer()
  def changelog_cap, do: @changelog_cap

  @doc """
  Builds a summary from the tool's arguments: a non-blank `status` and `changelog_entry`, and
  `links` with an optional `review_brief` URL and an optional list of `artifacts`, each a `label`
  and a `url`. URLs must be http(s). Text is folded onto one line and loses comment markers, so it
  cannot close the block early.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    links = Map.get(attrs, "links") || %{}

    with {:ok, status} <- text_field(Map.get(attrs, "status"), :invalid_summary_status),
         {:ok, entry} <- text_field(Map.get(attrs, "changelog_entry"), :invalid_summary_changelog_entry),
         true <- is_map(links) || {:error, :invalid_summary_links},
         {:ok, review_brief} <- review_brief_field(Map.get(links, "review_brief")),
         {:ok, artifacts} <- artifacts_field(Map.get(links, "artifacts") || []) do
      {:ok, %{status: status, review_brief: review_brief, artifacts: artifacts, entry: entry}}
    end
  end

  @doc """
  Writes `summary` into `description`, dated `date`: the block is replaced where it stands, or
  appended after a blank line when the description has none. The new entry goes on top of the
  changelog the block already holds, which keeps its newest #{@changelog_cap} entries. A start
  marker without an end marker is refused, since the block's end can't be told from a person's text.
  """
  @spec put(String.t() | nil, t(), Date.t(), [Event.t()]) :: {:ok, String.t()} | {:error, :summary_block_unterminated}
  def put(description, summary, %Date{} = date, events \\ []) do
    description = description || ""
    entry = "- #{Date.to_iso8601(date)}: #{summary.entry}"
    lines = event_entries(events)

    case split(description) do
      :none ->
        {:ok, append(description, render(summary, merge(lines, [entry])))}

      {:unterminated, _before} ->
        {:error, :summary_block_unterminated}

      {:block, before, block, rest} ->
        {:ok, drop_empty_heading(before) <> render(summary, merge(lines, [entry | changelog(block)])) <> rest}
    end
  end

  @doc """
  Merges the changelog lines of `events` (`event_entries/1`) into the block `description` holds:
  each line the block lacks is added, newest day first, and the block keeps its newest
  #{@changelog_cap} entries. A description with no block, or one the lines leave as it is, comes
  back unchanged, byte for byte; nothing outside the block's changelog is rewritten.
  """
  @spec put_changelog(String.t() | nil, [Event.t()]) :: String.t() | nil
  def put_changelog(description, events) when is_binary(description) do
    with {:block, before, block, rest} <- split(description),
         [head, _entries] <- :binary.split(block, @changelog_label),
         existing = changelog(block),
         merged when merged != existing <- merge(event_entries(events), existing) do
      before <> head <> @changelog_label <> "\n\n" <> Enum.join(merged, "\n") <> "\n\n" <> @end_marker <> rest
    else
      _unchanged -> description
    end
  end

  def put_changelog(description, _events), do: description

  @doc "The events of the ticket `issue_id` its changelog carries a line for, oldest first; none when the store cannot be read."
  @spec history(String.t()) :: [Event.t()]
  def history(issue_id) when is_binary(issue_id), do: issue_id |> RunStore.list_ticket_events(types: @event_types) |> List.wrap() |> Enum.filter(&match?(%Event{}, &1))

  @doc """
  The changelog lines of a ticket's `events`, oldest first: one per `attempt.pushed`
  (`2026-11-05: Attempt 2 pushed (abc1234)`) and one per `verdict.recorded`
  (`2026-11-05: Code Review verdict: approve (abc1234)`), dated by the day the event happened.
  """
  @spec event_entries([Event.t() | map()]) :: [String.t()]
  def event_entries(events) when is_list(events), do: Enum.flat_map(events, &event_entry/1)

  defp event_entry(%{type: type, at: %DateTime{} = at, payload: payload}) when type in @event_types and is_map(payload) do
    ["- #{Date.to_iso8601(DateTime.to_date(at))}: " <> plain(event_text(type, payload))]
  end

  defp event_entry(_event), do: []

  defp event_text("attempt.pushed", payload) do
    attempt = field(payload, :attempt)
    Enum.join(["Attempt", if(is_integer(attempt), do: Integer.to_string(attempt)), "pushed"] |> Enum.reject(&is_nil/1), " ") <> head_suffix(payload)
  end

  defp event_text("verdict.recorded", payload) do
    kind = field(payload, :kind)
    name = if is_binary(kind), do: Map.get_lazy(@kind_names, kind, fn -> kind |> String.split("_", trim: true) |> Enum.map_join(" ", &String.capitalize/1) end), else: "Review"
    outcome = field(payload, :outcome)
    "#{name} verdict" <> if(is_binary(outcome), do: ": " <> outcome, else: "") <> head_suffix(payload)
  end

  defp head_suffix(payload) do
    case field(payload, :head) do
      head when is_binary(head) and head != "" -> " (#{String.slice(head, 0, 7)})"
      _none -> ""
    end
  end

  defp field(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  # Only words, digits and plain punctuation: no markdown Linear would escape, so the line reads the
  # same once Linear stored it.
  defp plain(text), do: text |> String.replace(~r/[^\p{L}\p{N} .,:;()\/-]/u, "") |> one_line()

  # The event lines the entries lack, put with them, newest day first: on one day an event line goes
  # above the entries already there. The newest #{@changelog_cap} stay.
  defp merge(lines, entries) do
    case lines |> Enum.reject(&(&1 in entries)) |> Enum.uniq() |> Enum.reverse() do
      [] -> Enum.take(entries, @changelog_cap)
      missing -> (missing ++ entries) |> Enum.sort_by(&entry_date/1, :desc) |> Enum.take(@changelog_cap)
    end
  end

  defp entry_date(entry) do
    case Regex.run(@entry_date, entry) do
      [_entry, date] -> date
      nil -> ""
    end
  end

  @doc """
  `text` without the empty heading it ends with, if any, and with one blank line left before what
  follows it. Linear reads a Symphony marker written right above `---` as a setext heading and
  stores it as `## <marker>`; this drops that `## ` when the block is written again.
  """
  @spec drop_empty_heading(String.t()) :: String.t()
  def drop_empty_heading(text) when is_binary(text) do
    case Regex.replace(@empty_heading, text, "") do
      ^text -> text
      "" -> ""
      rest -> String.trim_trailing(rest) <> "\n\n"
    end
  end

  @doc """
  The description without the summary block, nil staying nil. The blank lines around the block
  fold into one paragraph break; a start marker without an end marker drops everything after it.
  """
  @spec strip(String.t() | nil) :: String.t() | nil
  def strip(description) when is_binary(description) do
    case split(description) do
      :none -> description
      {:unterminated, before} -> String.trim_trailing(before)
      {:block, before, _block, rest} -> join_stripped(before, rest)
    end
  end

  def strip(description), do: description

  @doc "The block's one-line status (`**Status:** …`), or nil when the description has no block or no status."
  @spec status(String.t() | nil) :: String.t() | nil
  def status(description) when is_binary(description) do
    with {:block, _before, block, _rest} <- split(description),
         [_, status] <- Regex.run(~r/^\s*\*\*Status:\*\*[ \t]*(.+)$/m, block) do
      one_line(status)
    else
      _none -> nil
    end
  end

  def status(_description), do: nil

  # The blank lines around the block fold into one paragraph break.
  defp join_stripped(before, rest) do
    [String.trim_trailing(before), String.trim_leading(rest)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # `block` runs from the start marker through the end marker; `before` and `rest` are the bytes
  # around it, untouched.
  defp split(description) do
    case :binary.split(description, @start_marker) do
      [_description] ->
        :none

      [before, after_start] ->
        case :binary.split(after_start, @end_marker) do
          [_unterminated] -> {:unterminated, before}
          [inner, rest] -> {:block, before, @start_marker <> inner <> @end_marker, rest}
        end
    end
  end

  defp append("", block), do: block

  defp append(description, block), do: description <> separator(description) <> block

  defp separator(description) do
    cond do
      String.ends_with?(description, "\n\n") -> ""
      String.ends_with?(description, "\n") -> "\n"
      true -> "\n\n"
    end
  end

  defp render(summary, entries) do
    Enum.join(
      [
        @start_marker,
        "",
        "---",
        "",
        @heading,
        "",
        "**Status:** " <> summary.status,
        "",
        "**Review brief:** " <> review_brief_line(summary.review_brief),
        "",
        "**Artifacts:**",
        "",
        artifact_lines(summary.artifacts),
        "",
        @changelog_label,
        "",
        Enum.join(entries, "\n"),
        "",
        @end_marker
      ],
      "\n"
    )
  end

  defp review_brief_line(nil), do: "None yet."
  defp review_brief_line(url), do: "[Review brief](#{url})"

  defp artifact_lines([]), do: "- None yet."
  defp artifact_lines(artifacts), do: Enum.map_join(artifacts, "\n", &"- [#{&1.label}](#{&1.url})")

  # The entries already in the block: the list items after its changelog label, written `- `.
  defp changelog(block) do
    case :binary.split(block, @changelog_label) do
      [_block] ->
        []

      [_head, entries] ->
        entries
        |> String.replace_suffix(@end_marker, "")
        |> String.split("\n")
        |> Enum.filter(&Regex.match?(@list_item, &1))
        |> Enum.map(&(@list_item |> Regex.replace(&1, "- ") |> String.trim_trailing()))
    end
  end

  defp text_field(value, error) when is_binary(value) do
    text = one_line(value)
    if text != "" and String.length(text) <= @field_max_length, do: {:ok, text}, else: {:error, error}
  end

  defp text_field(_value, error), do: {:error, error}

  defp one_line(value) do
    value
    |> String.replace(["<!--", "-->"], "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp review_brief_field(nil), do: {:ok, nil}
  defp review_brief_field(url), do: url_field(url)

  defp artifacts_field(artifacts) when is_list(artifacts) and length(artifacts) <= @artifact_cap do
    Enum.reduce_while(Enum.reverse(artifacts), {:ok, []}, fn artifact, {:ok, acc} ->
      case artifact_field(artifact) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp artifacts_field(_artifacts), do: {:error, :invalid_summary_artifacts}

  # Brackets would end the link's label early.
  defp artifact_field(%{"label" => label, "url" => url}) when is_binary(label) do
    with {:ok, label} <- text_field(String.replace(label, ["[", "]"], ""), :invalid_summary_artifacts),
         {:ok, url} <- url_field(url) do
      {:ok, %{label: label, url: url}}
    end
  end

  defp artifact_field(_artifact), do: {:error, :invalid_summary_artifacts}

  defp url_field(url) when is_binary(url) do
    url = String.trim(url)
    if Regex.match?(@url_pattern, url), do: {:ok, url}, else: {:error, {:invalid_summary_url, url}}
  end

  defp url_field(_url), do: {:error, {:invalid_summary_url, nil}}
end
