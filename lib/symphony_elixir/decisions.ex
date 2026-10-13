defmodule SymphonyElixir.Decisions do
  @moduledoc """
  The Symphony-owned Decisions section of an issue description: the answers a person gave to the
  ticket's decision requests, written into the ticket's scope so the reviewer, QA and later runs
  honour them instead of raising the same question again.

  The section sits between `<!-- symphony:decisions:start -->` and `<!-- symphony:decisions:end -->`,
  before the summary block (`SymphonyElixir.IssueSummary`) when there is one. Each entry is one
  answered `## Decision needed:` request, numbered `D1`, `D2`… in the order they were recorded, with
  the date, the question, the answer and what it means for scope:

      - **D1** · 2026-10-13 · Keep the legacy prompt partials <!-- symphony:decision:comment-1 -->
        - **Question:** Remove the legacy partials here, or leave them for TP-891?
        - **Answer:** Defer to TP-891: don't make that change here.
        - **Scope:** Deferred to TP-891

  An entry carries the id of the request comment it answers, so writing the same answer again
  changes nothing. New entries go at the end of the section; every byte outside it, and the entries
  already in it, stay as they are, so a person's text is never rewritten.

  A decision is recorded when a person answers it: `sync/2` writes the answered requests of a ticket
  the Inbox read (a reply under the request), and the Director's Decide writes its picks
  (`SymphonyElixir.DirectorMoves`). `prompt_section/1` renders the section for the reviewer and QA
  prompts; the implementation prompt reads it in the description.
  """

  require Logger

  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.{IssueSummary, PromptSafety, Tracker}

  @start_marker "<!-- symphony:decisions:start -->"
  @end_marker "<!-- symphony:decisions:end -->"
  @heading "### Decisions"
  @intro "_Symphony records a person's answer to each decision request here. Reviews, QA and later runs follow them._"
  @entry_pattern ~r/^- \*\*(D\d+)\*\* · (\S+) · (.*?) <!-- symphony:decision:(\S+) -->$/
  @field_pattern ~r/^\s+- \*\*(Question|Answer|Scope):\*\* (.*)$/
  @identifier_pattern ~r/\b[A-Z][A-Z0-9]*-\d+\b/
  @defer_pattern ~r/\bdefer\w*\b/i
  @out_of_scope_pattern ~r/\b(defer\w*|out of scope|not in scope|leave (it|them|that) (out|for))\b/i
  @in_scope_pattern ~r/\bin scope\b/i
  # A negation up to two words before a phrase: `do not defer`, `no need to defer`.
  @negation_pattern ~r/\b(not|never|no|cannot|\w+n['’]t)\s+(\w+\s+){0,2}$/iu
  @answer_max_length 600
  @prompt_limit 10_000

  @typedoc "One recorded decision. `key` is the id of the request comment it answers."
  @type entry :: %{
          key: String.t(),
          date: Date.t(),
          title: String.t(),
          question: String.t(),
          answer: String.t(),
          scope: String.t()
        }

  @typedoc "A recorded decision read back from the section, with its `D<n>` label."
  @type recorded :: %{
          id: String.t(),
          key: String.t(),
          title: String.t(),
          question: String.t(),
          answer: String.t(),
          scope: String.t()
        }

  @doc "The marker that opens the section."
  @spec start_marker() :: String.t()
  def start_marker, do: @start_marker

  @doc "The marker that closes the section."
  @spec end_marker() :: String.t()
  def end_marker, do: @end_marker

  @doc """
  Builds an entry from what a person decided: the request comment's id, the day, the request's
  title and question, and the answer. Text is folded onto one line and loses comment markers, so
  it cannot close the section early. The scope is read from the answer (`scope/1`).
  """
  @spec entry(String.t(), Date.t(), String.t() | nil, String.t() | nil, String.t()) :: entry()
  def entry(key, %Date{} = date, title, question, answer) do
    answer = answer |> one_line() |> String.slice(0, @answer_max_length)
    title = one_line(title || question || "")

    %{key: key, date: date, title: title, question: one_line(question || title), answer: answer, scope: scope(answer)}
  end

  @doc """
  What an answer means for the ticket's scope: `Deferred to TP-x` when it defers the work to a
  named ticket, `Out of scope` when it keeps the work out of this ticket, `In scope` when it says
  so, else `As answered`. A phrase with a negation just before it (`do not defer`) counts for
  nothing, so an answer that rejects a deferral is never recorded as one.
  """
  @spec scope(String.t()) :: String.t()
  def scope(answer) when is_binary(answer) do
    case deferred_to(answer) do
      nil -> unnamed_scope(answer)
      identifier -> "Deferred to #{identifier}"
    end
  end

  defp unnamed_scope(answer) do
    cond do
      affirmed(@out_of_scope_pattern, answer) != [] -> "Out of scope"
      affirmed(@in_scope_pattern, answer) != [] -> "In scope"
      true -> "As answered"
    end
  end

  # The ticket named after the first deferral the answer does not negate.
  defp deferred_to(answer) do
    Enum.find_value(affirmed(@defer_pattern, answer), fn {start, length} ->
      rest = binary_part(answer, start + length, byte_size(answer) - start - length)

      case Regex.run(@identifier_pattern, rest) do
        [identifier] -> identifier
        nil -> nil
      end
    end)
  end

  # Where `pattern` matches `answer` without a negation just before it, as `{start, length}`.
  defp affirmed(pattern, answer) do
    pattern
    |> Regex.scan(answer, return: :index)
    |> Enum.map(&hd/1)
    |> Enum.reject(fn {start, _length} -> Regex.match?(@negation_pattern, binary_part(answer, 0, start)) end)
  end

  @doc """
  Writes `entries` into `description`: the ones whose request is not recorded yet go at the end of
  the section, numbered after the ones already there. A description with no section gets one,
  before the summary block or at the end. Returns the description unchanged when every entry is
  already recorded. A start marker without an end marker is refused, since the section's end can't
  be told from a person's text.
  """
  @spec put(String.t() | nil, [entry()]) :: {:ok, String.t()} | {:error, :decisions_block_unterminated}
  def put(description, entries) when is_list(entries) do
    description = description || ""

    case split(description) do
      :none -> {:ok, insert(description, entries)}
      {:unterminated, _before} -> {:error, :decisions_block_unterminated}
      {:block, before, block, rest} -> {:ok, before <> extend(block, entries) <> rest}
    end
  end

  defp insert(description, entries) do
    case missing(entries, []) do
      [] -> description
      new -> place(description, Enum.join([@start_marker, @heading, "", @intro, "", render_entries(new, 1), @end_marker], "\n"))
    end
  end

  defp extend(block, entries) do
    recorded = parse_entries(block)

    case missing(entries, recorded) do
      [] ->
        block

      new ->
        inner = String.trim_trailing(String.replace_suffix(block, @end_marker, ""))
        inner <> "\n" <> render_entries(new, length(recorded) + 1) <> "\n" <> @end_marker
    end
  end

  # The entries whose request has no entry yet, each once.
  defp missing(entries, recorded) do
    keys = MapSet.new(recorded, & &1.key)
    entries |> Enum.reject(&MapSet.member?(keys, &1.key)) |> Enum.uniq_by(& &1.key)
  end

  # Before the summary block, which stays the description's last part, or at the end.
  defp place(description, section) do
    case :binary.split(description, IssueSummary.start_marker()) do
      [before, after_start] -> place(before, section) <> "\n\n" <> IssueSummary.start_marker() <> after_start
      [_none] -> String.trim_trailing(description) <> separator(description) <> section
    end
  end

  defp separator(text), do: if(String.trim(text) == "", do: "", else: "\n\n")

  defp render_entries(entries, first) do
    entries
    |> Enum.with_index(first)
    |> Enum.map_join("\n", fn {entry, index} ->
      Enum.join(
        [
          "- **D#{index}** · #{Date.to_iso8601(entry.date)} · #{entry.title} <!-- symphony:decision:#{entry.key} -->",
          "  - **Question:** #{entry.question}",
          "  - **Answer:** #{entry.answer}",
          "  - **Scope:** #{entry.scope}"
        ],
        "\n"
      )
    end)
  end

  @doc "The decisions recorded in `description`, in order, each with its `D<n>` label."
  @spec recorded(String.t() | nil) :: [recorded()]
  def recorded(description) when is_binary(description) do
    case split(description) do
      {:block, _before, block, _rest} -> parse_entries(block)
      _none -> []
    end
  end

  def recorded(_description), do: []

  defp parse_entries(block) do
    block
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case {Regex.run(@entry_pattern, line), Regex.run(@field_pattern, line), acc} do
        {[_line, id, _date, title, key], _field, acc} ->
          [%{id: id, key: key, title: title, question: "", answer: "", scope: ""} | acc]

        {nil, [_line, field, value], [entry | rest]} ->
          [Map.put(entry, field_key(field), value) | rest]

        _other ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp field_key("Question"), do: :question
  defp field_key("Answer"), do: :answer
  defp field_key("Scope"), do: :scope

  @doc """
  The recorded decision a new request with this title or question would ask again, if any: a title
  or question that matches one already decided, ignoring case and spacing.
  """
  @spec find([recorded() | entry()], String.t() | nil, String.t() | nil) :: recorded() | entry() | nil
  def find(decisions, title, question) do
    asked = [title, question] |> Enum.filter(&is_binary/1) |> Enum.map(&normalize/1) |> Enum.reject(&(&1 == ""))
    Enum.find(decisions, fn decision -> Enum.any?([decision.title, decision.question], &(normalize(&1) in asked)) end)
  end

  defp normalize(text), do: text |> one_line() |> String.downcase()

  @doc "The description without the Decisions section, nil staying nil."
  @spec strip(String.t() | nil) :: String.t() | nil
  def strip(description) when is_binary(description) do
    case split(description) do
      {:block, before, _block, rest} ->
        [String.trim_trailing(before), String.trim_leading(rest)] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

      _none_or_unterminated ->
        description
    end
  end

  def strip(description), do: description

  @doc """
  The Decisions section as a prompt reads it: a heading and the recorded decisions wrapped as
  untrusted Linear text, or an empty string when the description has none.
  """
  @spec prompt_section(String.t() | nil) :: String.t()
  def prompt_section(description) do
    case recorded(description) do
      [] ->
        ""

      decisions ->
        text = Enum.map_join(decisions, "\n", &"#{&1.id}: #{&1.question} Answer: #{&1.answer} Scope: #{&1.scope}.")

        """
        Recorded decisions (a person's answers to this ticket's decision requests; they are part of its scope):
        #{PromptSafety.linear_block(text, "linear_issue_decisions", @prompt_limit)}
        """
    end
  end

  @doc """
  The decisions a ticket node records in its comments: each `## Decision needed:` request with a
  reply from a person under it, answered by its first reply. A withdrawn request is no decision.
  `node` is a Linear issue node with `comments { nodes { id body createdAt parent { id } } }`.
  """
  @spec answered(map()) :: [entry()]
  def answered(node) when is_map(node) do
    comments = node |> get_in(["comments", "nodes"]) |> List.wrap() |> Enum.filter(&is_map/1)
    replies = Enum.group_by(comments, &get_in(&1, ["parent", "id"]))

    for %{"id" => id, "body" => body} = comment <- comments,
        is_binary(id),
        request = Request.parse(body, nil),
        request != nil,
        under = Enum.sort_by(Map.get(replies, id, []), &(&1["createdAt"] || "")),
        not Enum.any?(under, &Request.withdrawal?(&1["body"])),
        %{"body" => answer} = reply <- Enum.take(Enum.filter(under, &is_binary(&1["body"])), 1),
        do: entry(id, reply_date(reply, comment), request.title, request.question, answer_text(answer, request))
  end

  def answered(_node), do: []

  # The reply, plus the option it picks when it names one but not what it does.
  defp answer_text(reply, request) do
    reply = one_line(reply)

    case Enum.find(request.options, &picked?(&1, reply)) do
      nil -> reply
      option -> if String.contains?(reply, option_effect(option)), do: reply, else: "#{reply} (option: #{one_line(option)})"
    end
  end

  defp picked?(option, reply), do: String.contains?(String.downcase(reply), String.downcase(option_label(option)))

  # A rendered option reads `**Label** (recommended): effect`.
  defp option_label(option), do: option |> String.split(":", parts: 2) |> hd() |> String.replace(["**", "(recommended)"], "") |> String.trim()
  defp option_effect(option), do: option |> String.split(":", parts: 2) |> List.last() |> String.trim()

  defp reply_date(reply, comment) do
    Enum.find_value([reply["createdAt"], comment["createdAt"]], Date.utc_today(), fn
      at when is_binary(at) ->
        case DateTime.from_iso8601(at) do
          {:ok, datetime, _offset} -> DateTime.to_date(datetime)
          _invalid -> nil
        end

      _missing ->
        nil
    end)
  end

  @doc """
  Records the decisions answered on a ticket node (`answered/1`) in its description. The node's own
  description is checked first, so a ticket whose decisions are all recorded costs no Linear call;
  otherwise `record/3` reads the description again and writes what is missing. A failure is logged
  and returned, never raised: the next poll tries again.
  """
  @spec sync(map(), keyword()) :: :ok | {:error, term()}
  def sync(%{"id" => issue_id} = node, opts) when is_binary(issue_id) do
    case missing(answered(node), recorded(node["description"])) do
      [] -> :ok
      entries -> record(issue_id, entries, opts)
    end
  end

  def sync(_node, _opts), do: :ok

  @doc """
  Writes `entries` into the issue's description, read through the tracker right before the write
  so a person's edit since the last read survives. Nothing is written when every entry is already
  recorded. `opts[:tracker]` overrides the tracker.
  """
  @spec record(String.t(), [entry()], keyword()) :: :ok | {:error, term()}
  def record(issue_id, entries, opts \\ []) when is_binary(issue_id) and is_list(entries) do
    tracker = Keyword.get(opts, :tracker, Tracker)

    with {:ok, description} <- tracker.fetch_issue_description(issue_id),
         {:ok, updated} <- put(description, entries),
         :ok <- write(tracker, issue_id, description, updated) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("Failed to record decisions on issue_id=#{issue_id}: #{inspect(reason)}")
        error
    end
  end

  defp write(_tracker, _issue_id, same, same), do: :ok
  defp write(tracker, issue_id, _description, updated), do: tracker.update_issue_description(issue_id, updated)

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

  defp one_line(text) when is_binary(text) do
    text
    |> String.replace(["<!--", "-->"], "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.trim_leading("#")
    |> String.trim()
  end
end
