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

  An answer that picks an option unlocking agent-protected paths (`SymphonyElixir.PathUnlock`)
  records them in a hidden line under its entry, `<!-- symphony:unlocks WORKFLOW.md -->`, which
  `PathUnlock.grants/1` reads back.

  An entry carries the id of the request comment it answers, so writing the same answer again
  changes nothing. The id is read from its marker wherever it stands in the section, since Linear
  rewrites the markdown it stores (`*` bullets, escapes, blank lines). New entries go at the end of
  the section; every byte outside it, and the entries already in it, stay as they are, so a person's
  text is never rewritten. A section that holds an id more than once is rewritten once, each
  decision kept at its first place and numbered again.

  The ticket's store record (`SymphonyElixir.TicketState`'s `decisions`, kept by
  `SymphonyElixir.RunStore`) is the source of truth, and the section is its projection: every write
  goes to the store first, then the section is projected into the description.
  A ticket whose store record holds no decision yet while its description has a section is
  backfilled from the section, once.

  A decision is recorded when the Director answers it: the Director's Decide writes its picks
  (`SymphonyElixir.DirectorMoves`) through `record/3`. Nothing reads a Linear comment for a
  decision: a reply under a request, or a plain comment opening with `Decision:` or `Ruling:`,
  answers nothing. A ruling recorded before (keyed `ruling-<comment id>`) stays on the record, and a
  later entry with the same answer is skipped. The agents' comment tools still refuse a body that
  reads as a ruling (`ruling?/1`, `SymphonyElixir.AgentTools.Linear`), so no agent writes one.
  `stored/2` reads a ticket's decisions from the store, and `prompt_section/1` renders them for the
  implementation, reviewer and QA prompts, with no Linear read.

  A decision records no event of its own: the answer is its Question's `question.answered`
  (`SymphonyElixir.Questions`). The `decision.*` events a ticket recorded before stay in its history
  (`SymphonyElixir.TicketEvents.Types`).

  While the pause projector owns the section (`SymphonyElixir.Pauses.Projector.owns?/0`), `record/3`
  only writes the store, and the projector renders the section from the record
  (`render_from_questions/1`), as it renders the labels from the pause and the questions.
  """

  require Logger

  alias SymphonyElixir.{Config, IssueSummary, PathUnlock, PromptSafety, RunStore, TicketState, Tracker}
  alias SymphonyElixir.Pauses.Projector

  @start_marker "<!-- symphony:decisions:start -->"
  @end_marker "<!-- symphony:decisions:end -->"
  @heading "### Decisions"
  @intro "_Symphony records a person's answer to each decision request here. Reviews, QA and later runs follow them._"
  # Linear stores a list item written `- ` as `* `.
  @entry_pattern ~r/^[-*+] \*\*(D\d+)\*\* · (\S+) · (.*?) <!-- symphony:decision:(\S+) -->\s*$/
  @field_pattern ~r/^\s+[-*+] \*\*(Question|Answer|Scope):\*\* (.*)$/
  @key_pattern ~r/<!-- symphony:decision:(\S+) -->/
  @unlocks_pattern ~r/^\s*<!--\s*symphony:unlocks\s+(.*?)\s*-->\s*$/
  @identifier_pattern ~r/\b[A-Z][A-Z0-9]*-\d+\b/
  @defer_pattern ~r/\bdefer\w*\b/i
  @out_of_scope_pattern ~r/\b(defer\w*|out of scope|not in scope|leave (it|them|that) (out|for))\b/i
  @in_scope_pattern ~r/\bin scope\b/i
  # A negation up to two words before a phrase: `do not defer`, `no need to defer`.
  @negation_pattern ~r/\b(not|never|no|cannot|\w+n['’]t)\s+(\w+\s+){0,2}$/iu
  @answer_max_length 600
  # A plain comment a person opens with `Decision:` or `Ruling:`, bold or not.
  @ruling_pattern ~r/\A\s*(?:\*\*|__)?(?:decision|ruling)\s*(?:\*\*|__)?\s*:\s*(?:\*\*|__)?\s*(\S.*)\z/isu
  @ruling_prefix "ruling-"
  @prompt_limit 10_000

  @typedoc """
  One recorded decision. `key` is the id of the request comment it answers; `unlocks`, when the
  answer picked an option that unlocks protected paths, names them.
  """
  @type entry :: %{
          optional(:unlocks) => [String.t()],
          key: String.t(),
          date: Date.t(),
          title: String.t(),
          question: String.t(),
          answer: String.t(),
          scope: String.t()
        }

  @typedoc "A recorded decision read back from the section or the store, with its `D<n>` label."
  @type recorded :: %{
          optional(:unlocks) => [String.t()],
          id: String.t(),
          key: String.t(),
          date: Date.t() | String.t(),
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
  it cannot close the section early. The scope is read from the answer (`scope/1`). `unlocks` are
  the protected paths the picked option unlocks; only paths on the protected list are kept.
  """
  @spec entry(String.t(), Date.t(), String.t() | nil, String.t() | nil, String.t(), [String.t()]) :: entry()
  def entry(key, %Date{} = date, title, question, answer, unlocks \\ []) do
    answer = answer |> one_line() |> String.slice(0, @answer_max_length)
    title = one_line(title || question || "")

    %{key: key, date: date, title: title, question: one_line(question || title), answer: answer, scope: scope(answer)}
    |> put_unlocks(PathUnlock.protected(unlocks))
  end

  defp put_unlocks(entry, []), do: entry
  defp put_unlocks(entry, unlocks), do: Map.put(entry, :unlocks, unlocks)

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
  already recorded and the section holds each once. A start marker without an end marker is
  refused, since the section's end can't be told from a person's text.
  """
  @spec put(String.t() | nil, [entry()]) :: {:ok, String.t()} | {:error, :decisions_block_unterminated}
  def put(description, entries) when is_list(entries) do
    description = description || ""

    case split(description) do
      :none -> {:ok, insert(description, entries)}
      {:unterminated, _before} -> {:error, :decisions_block_unterminated}
      {:block, before, block, rest} -> {:ok, replace(description, before, block, extend(block, entries), rest)}
    end
  end

  defp insert(description, entries) do
    case missing(entries, []) do
      [] -> description
      new -> place(description, section(new))
    end
  end

  defp replace(description, _before, block, block, _rest), do: description
  defp replace(_description, before, _block, extended, rest), do: IssueSummary.drop_empty_heading(before) <> extended <> rest

  defp extend(block, entries) do
    keys = keys(block)
    new = missing(entries, keys, parse_entries(block))

    cond do
      repeated?(keys) ->
        section(Enum.uniq_by(parse_entries(block), & &1.key) ++ new)

      new == [] ->
        block

      true ->
        inner = String.trim_trailing(String.replace_suffix(block, @end_marker, ""))
        inner <> "\n" <> render_entries(new, length(keys) + 1) <> "\n\n" <> @end_marker
    end
  end

  defp section(entries), do: Enum.join([@start_marker, @heading, "", @intro, "", render_entries(entries, 1), "", @end_marker], "\n")

  # The ids of the requests the section records, as often as it holds them.
  defp keys(block), do: @key_pattern |> Regex.scan(block, capture: :all_but_first) |> List.flatten()

  defp repeated?(keys), do: length(keys) != length(Enum.uniq(keys))

  # The entries whose request has no entry yet, each once. A ruling is also left out when the
  # section, or a ruling before it, already records its answer.
  defp missing(entries, keys, recorded \\ []) do
    keys = MapSet.new(keys)
    answers = MapSet.new(recorded, &normalize(&1.answer))

    entries
    |> Enum.reject(&MapSet.member?(keys, &1.key))
    |> Enum.uniq_by(& &1.key)
    |> Enum.reject(&(ruling_key?(&1.key) and MapSet.member?(answers, normalize(&1.answer))))
    |> Enum.uniq_by(&if(ruling_key?(&1.key), do: {:ruling, normalize(&1.answer)}, else: {:request, &1.key}))
  end

  defp ruling_key?(key), do: String.starts_with?(key, @ruling_prefix)

  # Before the summary block, which stays the description's last part, or at the end. The empty
  # heading Linear may have made of the summary's marker line goes.
  defp place(description, section) do
    case :binary.split(description, IssueSummary.start_marker()) do
      [before, after_start] ->
        place(IssueSummary.drop_empty_heading(before), section) <> "\n\n" <> IssueSummary.start_marker() <> after_start

      [_none] ->
        String.trim_trailing(description) <> separator(description) <> section
    end
  end

  defp separator(text), do: if(String.trim(text) == "", do: "", else: "\n\n")

  defp render_entries(entries, first) do
    entries
    |> Enum.with_index(first)
    |> Enum.map_join("\n", fn {entry, index} ->
      Enum.join(
        [
          "- **D#{index}** · #{date_text(entry.date)} · #{entry.title} <!-- symphony:decision:#{entry.key} -->",
          "  - **Question:** #{entry.question}",
          "  - **Answer:** #{entry.answer}",
          "  - **Scope:** #{entry.scope}"
          | unlocks_line(Map.get(entry, :unlocks, []))
        ],
        "\n"
      )
    end)
  end

  # Hidden from the Director: the paths the picked option unlocks.
  defp unlocks_line([]), do: []
  defp unlocks_line(unlocks), do: ["  <!-- symphony:unlocks #{Enum.join(unlocks, " ")} -->"]

  defp date_text(%Date{} = date), do: Date.to_iso8601(date)
  defp date_text(date), do: date

  @doc """
  The entries the Decisions section of `record` (a ticket's store record) shows, as `put/2` writes
  them: a person's answer to each of its questions, keyed by the request comment it answers, then
  the rulings, in the order they were recorded. Each answer is the decision its question's answer
  recorded, with the request's id that keys the entry: a question carries no request id, so an
  answer is rendered once its decision is recorded, never under a second key. A question answered
  with no decision recorded (an answer a rule or an Unblock gave) shows no entry, as before the
  projector, and a decision whose answer the Director took back keeps its entry, which the section
  never drops. So the section rendered from the record is byte for byte the one `record/3` writes.
  """
  @spec render_from_questions(map()) :: [entry()]
  def render_from_questions(record) do
    record
    |> TicketState.decisions()
    |> Enum.uniq_by(& &1.key)
  end

  @doc "The decisions recorded in `description`, in order and each once, with its `D<n>` label."
  @spec recorded(String.t() | nil) :: [recorded()]
  def recorded(description) when is_binary(description) do
    case split(description) do
      {:block, _before, block, _rest} -> block |> parse_entries() |> Enum.uniq_by(& &1.key)
      _none -> []
    end
  end

  def recorded(_description), do: []

  defp parse_entries(block) do
    block
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case {Regex.run(@entry_pattern, line), Regex.run(@field_pattern, line), acc} do
        {[_line, id, date, title, key], _field, acc} ->
          [%{id: id, key: key, date: date, title: title, question: "", answer: "", scope: ""} | acc]

        {nil, [_line, field, value], [entry | rest]} ->
          [Map.put(entry, field_key(field), value) | rest]

        {nil, nil, [entry | rest]} ->
          [parse_unlocks(entry, line) | rest]

        _other ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp parse_unlocks(entry, line) do
    case Regex.run(@unlocks_pattern, line) do
      [_line, paths] -> put_unlocks(entry, paths |> String.split() |> PathUnlock.protected())
      nil -> entry
    end
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

  # Linear escapes markdown in the text it stores, so a backslash counts for nothing.
  defp normalize(text), do: text |> String.replace("\\", "") |> one_line() |> String.downcase()

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
  The recorded decisions as a prompt reads them (`stored/2`): a heading and the decisions wrapped as
  untrusted Linear text, or an empty string when there are none.
  """
  @spec prompt_section([recorded()]) :: String.t()
  def prompt_section(decisions) when is_list(decisions) do
    case decisions do
      [] ->
        ""

      decisions ->
        text = Enum.map_join(decisions, "\n", &"#{&1.id}: #{&1.question} Answer: #{&1.answer} Scope: #{&1.scope}.")

        """
        Recorded decisions (a person's answers to this ticket's decision requests and the rulings they gave in comments; they are part of its scope):
        #{PromptSafety.linear_block(text, "linear_issue_decisions", @prompt_limit)}
        """
    end
  end

  @doc """
  Whether `body` is a person's ruling: a comment that opens with `Decision:` or `Ruling:` (any
  case, bold or not) and says something after it.
  """
  @spec ruling?(String.t() | term()) :: boolean()
  def ruling?(body) when is_binary(body), do: Regex.match?(@ruling_pattern, body)
  def ruling?(_body), do: false

  @doc """
  The decisions recorded on `issue` (a map with its `:id`, `:description` and `:repo_key`), read
  from its store record in the order they were recorded and labelled `D1`, `D2`… A record that holds
  none while the description has a section is backfilled from it first. When the store can't be
  read, the description's section is what is returned. `opts[:repo_key]` overrides the issue's repo.
  """
  @spec stored(map(), keyword()) :: [recorded()]
  def stored(issue, opts \\ []) when is_map(issue) do
    description = Map.get(issue, :description) || ""

    with issue_id when is_binary(issue_id) <- Map.get(issue, :id),
         {:ok, repo_key} <- repo_key(issue_repo_key(opts, issue)),
         {:ok, decisions} <- store_decisions(repo_key, issue_id, [], description, opts) do
      label(decisions)
    else
      _unavailable -> label(backfill(description))
    end
  end

  defp issue_repo_key(opts, issue), do: Keyword.put(opts, :repo_key, Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key))

  defp label(decisions), do: decisions |> Enum.with_index(1) |> Enum.map(fn {decision, index} -> Map.put(decision, :id, "D#{index}") end)

  @doc """
  Records `entries` on the issue: the ones its store record lacks go into it, then the record is
  projected into the description's section, read through the tracker right before the write so a
  person's edit since the last read survives. Nothing is written to the description when its section
  already shows every recorded decision, each once. `opts[:repo_key]` names the ticket's repo (else
  the configured one), `opts[:tracker]` overrides the tracker and `opts[:description]` is a
  description already read, checked before any Linear read.
  """
  @spec record(String.t(), [entry()], keyword()) :: :ok | {:error, term()}
  def record(issue_id, entries, opts) when is_binary(issue_id) and is_list(entries) do
    write = if Projector.owns?(), do: &store_and_project/3, else: &project_decisions/3

    case logged(issue_id, write.(issue_id, entries, opts)) do
      {:ok, _written} -> :ok
      error -> error
    end
  end

  defp logged(issue_id, {:error, reason} = error) do
    Logger.warning("Failed to record decisions on issue_id=#{issue_id}: #{inspect(reason)}")
    error
  end

  defp logged(_issue_id, result), do: result

  # The store first, then the description.
  defp project_decisions(issue_id, entries, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    read? = Keyword.has_key?(opts, :description)

    with {:ok, repo_key} <- repo_key(opts),
         {:ok, description} <- description(tracker, issue_id, opts),
         {:ok, decisions} <- store_decisions(repo_key, issue_id, entries, description, opts) do
      project(tracker, issue_id, description, decisions, not read?)
    end
  end

  # The store only; the projector writes the section from the record. A projection Linear refuses
  # is pending on the record, which the reconciler applies again, so the decision is recorded.
  defp store_and_project(issue_id, entries, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)

    with {:ok, repo_key} <- repo_key(opts),
         {:ok, description} <- description(tracker, issue_id, opts),
         {:ok, _decisions} <- store_decisions(repo_key, issue_id, entries, description, opts) do
      _ = Projector.project_now({:ticket, repo_key, issue_id}, Keyword.take(opts, [:tracker, :store]))
      {:ok, :stored}
    end
  end

  defp repo_key(opts) do
    case Keyword.get(opts, :repo_key) || Config.repo_key_or_nil() do
      repo_key when is_binary(repo_key) and repo_key != "" -> {:ok, repo_key}
      _none -> {:error, :missing_repo_key}
    end
  end

  defp description(tracker, issue_id, opts) do
    case Keyword.fetch(opts, :description) do
      {:ok, description} -> {:ok, description || ""}
      :error -> fresh_description(tracker, issue_id)
    end
  end

  defp fresh_description(tracker, issue_id) do
    with {:ok, description} <- tracker.fetch_issue_description(issue_id), do: {:ok, description || ""}
  end

  # The record's decisions once `entries` are in it. A record that holds none takes the ones
  # `description` records first; the store is written only when that adds a decision.
  defp store_decisions(repo_key, issue_id, entries, description, opts) do
    store = Keyword.get(opts, :store, RunStore)
    backfill = backfill(description)

    with {:ok, stored} <- read_decisions(store, repo_key, issue_id) do
      known = if stored == [], do: backfill, else: stored

      case missing(entries, Enum.map(known, & &1.key), known) do
        [] when known == stored -> {:ok, stored}
        new -> write_decisions(store, repo_key, issue_id, new, backfill)
      end
    end
  end

  defp write_decisions(store, repo_key, issue_id, new, backfill) do
    store.record_ticket_decisions(repo_key, issue_id, new, backfill)
  end

  defp read_decisions(store, repo_key, issue_id) do
    case store.get_ticket_state(repo_key, issue_id) do
      {:error, _reason} = error -> error
      record -> {:ok, TicketState.decisions(record)}
    end
  end

  # The decisions a description's section records, as entries the store keeps.
  defp backfill(description) do
    for decision <- recorded(description) do
      decision |> Map.delete(:id) |> Map.update!(:date, &parse_date/1)
    end
  end

  defp parse_date(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> date
      {:error, _invalid} -> text
    end
  end

  # Projects the record's decisions into `description`. A description read earlier is checked
  # first and read again before any write, so a person's edit since that read survives.
  defp project(tracker, issue_id, description, decisions, fresh?) do
    case put(description, decisions) do
      {:ok, ^description} ->
        {:ok, :unchanged}

      {:ok, updated} when fresh? ->
        with :ok <- tracker.update_issue_description(issue_id, updated), do: {:ok, :written}

      {:ok, _stale} ->
        with {:ok, fresh} <- fresh_description(tracker, issue_id),
             do: project(tracker, issue_id, fresh, decisions, true)

      {:error, _reason} = error ->
        error
    end
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

  defp one_line(text) when is_binary(text) do
    text
    |> String.replace(["<!--", "-->"], "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.trim_leading("#")
    |> String.trim()
  end
end
