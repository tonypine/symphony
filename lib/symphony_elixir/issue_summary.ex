defmodule SymphonyElixir.IssueSummary do
  @moduledoc """
  The Symphony-owned summary block at the end of an issue description.

  The block sits between `<!-- symphony:summary:start -->` and `<!-- symphony:summary:end -->` and
  shows where the ticket stands: a one-line status, a link to the review brief, the artifacts and a
  dated changelog, newest first and capped at 20 entries. `put/3` replaces the block, or appends
  it when the description has none, and leaves every byte outside it unchanged, so a person's edits
  to the rest of the description survive. `strip/1` removes it, so a description read as
  requirements never carries Symphony's own summary.
  """

  @start_marker "<!-- symphony:summary:start -->"
  @end_marker "<!-- symphony:summary:end -->"
  @heading "### Symphony summary"
  @changelog_label "**Changelog:**"
  @changelog_cap 20
  @field_max_length 300
  @artifact_cap 20
  @url_pattern ~r{\Ahttps?://[^\s()<>]+\z}

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
  @spec put(String.t() | nil, t(), Date.t()) :: {:ok, String.t()} | {:error, :summary_block_unterminated}
  def put(description, summary, %Date{} = date) do
    description = description || ""
    entry = "- #{Date.to_iso8601(date)}: #{summary.entry}"

    case split(description) do
      :none ->
        {:ok, append(description, render(summary, [entry]))}

      {:unterminated, _before} ->
        {:error, :summary_block_unterminated}

      {:block, before, block, rest} ->
        {:ok, before <> render(summary, Enum.take([entry | changelog(block)], @changelog_cap)) <> rest}
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
        @end_marker
      ],
      "\n"
    )
  end

  defp review_brief_line(nil), do: "None yet."
  defp review_brief_line(url), do: "[Review brief](#{url})"

  defp artifact_lines([]), do: "- None yet."
  defp artifact_lines(artifacts), do: Enum.map_join(artifacts, "\n", &"- [#{&1.label}](#{&1.url})")

  # The entries already in the block: the list items after its changelog label.
  defp changelog(block) do
    case :binary.split(block, @changelog_label) do
      [_block] ->
        []

      [_head, entries] ->
        entries
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "- "))
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
