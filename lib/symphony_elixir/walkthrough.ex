defmodule SymphonyElixir.Walkthrough do
  @moduledoc """
  A ticket's `## User walkthrough` and the one place that proves each step (ADR 0003,
  `docs/adr/0003-automated-tests-first-qa-last-resort.md`).

  The person writing the ticket describes the steps in plain words. The implementer, who writes the
  tests, records the test that proves a step it covers as an `evidence` event with `proof` (the step
  and the test, `linear_record_walkthrough_proofs`), and the repo names the check that runs them
  (`proof_check` in its WORKFLOW.md). The ticket's history is the only source of a step's proof:
  nothing reads a `Proved by:` line from the description. A step no event proves is walked by QA,
  and so is every step in a repo without a `proof_check`.

  The description shows the proofs as a projection Symphony renders from those events
  (`put_proofs/2`): one `Proved by:` line per proved step, between
  `<!-- symphony:proofs:start -->` and `<!-- symphony:proofs:end -->` at the end of the walkthrough
  section. The section ends at the next heading or at the next line opening with a Symphony marker
  (the summary block or the Decisions section), since what follows that marker is Symphony's. The
  block is found by its markers wherever it stands, since Linear rewrites the markdown it stores,
  and every byte outside it stays as it is; only a block found inside another Symphony block moves,
  to the end of the walkthrough, since that block's next write would erase it. `section/1` reads the
  walkthrough without it.

  A step whose author wrote `Proved by: QA` asked QA to walk it: `check_proofs/2` refuses a proof for
  it. A `Proved by:` inside inline code (between backticks) is a quotation, not that request.
  The QA pre-check (`SymphonyElixir.QaPreCheck`) confirms the proved steps on the PR head before the
  QA agent starts (`proof_steps/2`, from the events alone), and the QA prompt
  (`SymphonyElixir.QaAgent`) tells QA to link, not walk, them.
  """

  alias SymphonyElixir.RunStore

  @heading ~r/^\s*\#{1,6}\s+User walkthrough\s*:?\s*$/i
  @any_heading ~r/^\s*\#{1,6}\s+\S/
  # A line opening with a Symphony marker: the walkthrough never runs past it.
  @symphony_marker ~r/^\s*<!--\s*symphony:/
  # A line opening or closing a Symphony block, with the `## ` Linear may make of a marker line.
  @block_marker ~r/^\s*(?:\#{1,6}\s*)?<!--\s*symphony:\w+:(start|end)\s*-->/m
  @step_start ~r/^ {0,3}(\d+)[.)]\s+(.*)$/
  @proved_by ~r/proved by:/i
  @backticks ~r/`+/
  @separator ~r/\s*(?:›|\s>\s)\s*/u
  # `QA` as the whole spec, or followed only by a note: `QA (light mode only)`, `QA: desktop`.
  @qa ~r/^qa(?:$|\s*[(:,;]|\s+[-–—]\s)/iu
  @proofs_start "<!-- symphony:proofs:start -->"
  @proofs_end "<!-- symphony:proofs:end -->"
  @proofs_intro "_Symphony shows here the test the implementer recorded for each step it proves; QA walks the others._"
  @test_max 300

  @type proof :: %{by: :test, check: String.t(), test: String.t() | nil} | %{by: :qa}
  @type step :: %{number: pos_integer(), text: String.t(), proof: proof()}
  @type recorded :: %{step: pos_integer(), test: String.t()}

  @doc "The marker that opens the projected `Proved by:` block."
  @spec proofs_start_marker() :: String.t()
  def proofs_start_marker, do: @proofs_start

  @doc "The marker that closes the projected `Proved by:` block."
  @spec proofs_end_marker() :: String.t()
  def proofs_end_marker, do: @proofs_end

  @doc """
  The body of the `## User walkthrough` section in `description`, without the projected `Proved by:`
  block, or nil when it has none.
  """
  @spec section(String.t() | nil) :: String.t() | nil
  def section(description) when is_binary(description) do
    lines = description |> strip_proofs() |> String.split("\n")

    with index when is_integer(index) <- Enum.find_index(lines, &Regex.match?(@heading, &1)),
         body when body != "" <- section_body(lines, index) do
      body
    else
      _none -> nil
    end
  end

  def section(_description), do: nil

  @doc """
  The numbered steps of a walkthrough's text, in order, each QA's to walk until a recorded proof
  says otherwise (`with_recorded_proofs/3`). Lines before the first step (such as
  `Nothing changes on screen.`) are not steps; a step runs until the next one. The text is the
  person's, as they wrote it.
  """
  @spec steps(String.t() | nil) :: [step()]
  def steps(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], &collect_line/2)
    |> Enum.reverse()
    |> Enum.map(fn {number, lines} -> %{number: number, text: lines |> Enum.reverse() |> Enum.join("\n") |> String.trim(), proof: %{by: :qa}} end)
  end

  def steps(_text), do: []

  @doc "Whether `step` is proved by a named test, so QA links it instead of walking it."
  @spec named_test?(step()) :: boolean()
  def named_test?(%{proof: %{by: :test}}), do: true
  def named_test?(_step), do: false

  @doc "The proof of `step` as its `Proved by:` line."
  @spec proof_line(step()) :: String.t()
  def proof_line(%{proof: %{by: :test, check: check, test: nil}}), do: "Proved by: `#{check}`"
  def proof_line(%{proof: %{by: :test, check: check, test: test}}), do: "Proved by: `#{check}` › #{test}"
  def proof_line(_step), do: "Proved by: QA"

  @doc """
  Checks the implementer's `proofs` against `description`'s `## User walkthrough` and returns them
  as `%{step: number, test: test}` (the test trimmed): the proofs are recorded as `evidence` events
  on the ticket's history (`SymphonyElixir.AgentTools.Linear.record_walkthrough_proofs/3`), and the
  description stays as it is.

  `proofs` is a non-empty list of `%{"step" => number, "test" => test}`. A proof names a test only,
  never a check (the repo's `proof_check` names that), so a test with a ` › ` or ` > ` separator is
  refused, as is a step the walkthrough does not have and a step whose author wrote
  `Proved by: QA`: the author asked QA to walk it.
  """
  @spec check_proofs(String.t() | nil, term()) ::
          {:ok, [recorded()]} | {:error, {:invalid_walkthrough_proof, String.t()}}
  def check_proofs(description, proofs) do
    with {:ok, entries} <- proof_entries(proofs),
         {:ok, steps} <- walkthrough_steps(description),
         nil <- Enum.find_value(entries, fn {number, _test} -> unprovable(steps, number) end) do
      {:ok, Enum.map(entries, fn {number, test} -> %{step: number, test: test} end)}
    end
  end

  @doc """
  The proofs recorded as `evidence` events with `proof` on the ticket `issue_id`'s history, oldest
  first, so a later proof of a step wins. A store that cannot be read has none.
  """
  @spec recorded_proofs(String.t() | nil) :: [recorded()]
  def recorded_proofs(issue_id) when is_binary(issue_id), do: issue_id |> RunStore.list_ticket_events(types: ["evidence"]) |> List.wrap() |> proofs_of()

  def recorded_proofs(_issue_id), do: []

  @doc "The walkthrough proofs among `events` (`evidence` with `proof`), in their order."
  @spec proofs_of([map()]) :: [recorded()]
  def proofs_of(events) when is_list(events), do: Enum.flat_map(events, &event_proof/1)

  defp event_proof(%{type: "evidence", payload: %{proof: %{step: step, test: test}}}) when is_integer(step) and step > 0 and is_binary(test),
    do: [%{step: step, test: test}]

  defp event_proof(_event), do: []

  @doc """
  `steps` with the proofs `recorded` laid over them: each `%{step: number, test: test}` (oldest
  first, so a later proof of a step wins) makes that step `Proved by: <test>`, run by `proof_check`.
  With no `proof_check` every step stays QA's.
  """
  @spec with_recorded_proofs([step()], [recorded()], String.t() | nil) :: [step()]
  def with_recorded_proofs(steps, recorded, proof_check) do
    case check_name(proof_check) do
      nil ->
        steps

      check ->
        latest = latest(recorded)
        Enum.map(steps, &recorded_proof(&1, Map.get(latest, &1.number), check))
    end
  end

  defp recorded_proof(step, nil, _check), do: step
  defp recorded_proof(step, test, check), do: %{step | proof: %{by: :test, check: check, test: test}}

  @doc """
  The steps the proofs `recorded` prove, from the events alone, ordered by step number: the QA
  pre-check's input, which reads no description text. A step carries its number and its proof, and
  no text. With no `proof_check` there are none.
  """
  @spec proof_steps([recorded()], String.t() | nil) :: [step()]
  def proof_steps(recorded, proof_check) do
    case check_name(proof_check) do
      nil ->
        []

      check ->
        recorded
        |> latest()
        |> Enum.sort()
        |> Enum.map(fn {number, test} -> %{number: number, text: "", proof: %{by: :test, check: check, test: test}} end)
    end
  end

  defp latest(recorded), do: Map.new(recorded, &{&1.step, &1.test})

  defp check_name(proof_check), do: blank_to_nil(String.trim(proof_check || ""))

  @doc """
  Renders the proofs `recorded` into `description` as the `Proved by:` block (see the moduledoc):
  one line per proved step, the latest proof of each, ordered by step number. The block is
  replaced where its markers stand, or placed at the end of the `## User walkthrough` section when
  there is none or when it stands inside another Symphony block; a repeated block is dropped. With
  no proof, or no walkthrough, no block is written and one already there is removed. Every other
  byte stays as it is.
  """
  @spec put_proofs(String.t() | nil, [recorded()]) :: String.t()
  def put_proofs(description, recorded) do
    description = description || ""
    block = proofs_block(recorded)

    case :binary.split(description, @proofs_start) do
      [_none] -> place_proofs(description, block)
      [before, after_start] -> put_found_proofs(description, before, after_start, block)
    end
  end

  # A block inside the summary block or the Decisions section goes to the walkthrough's end, where
  # their next write leaves it alone.
  defp put_found_proofs(description, before, after_start, block) do
    if inside_symphony_block?(before) do
      description |> strip_proofs() |> place_proofs(block)
    else
      replace_proofs(before, after_start, block)
    end
  end

  # Whether the last Symphony block marker in `text` opens a block.
  defp inside_symphony_block?(text), do: @block_marker |> Regex.scan(text, capture: :all_but_first) |> List.last() == ["start"]

  defp proofs_block([]), do: nil

  defp proofs_block(recorded) do
    lines = recorded |> latest() |> Enum.sort() |> Enum.map(fn {number, test} -> "- Step #{number} · Proved by: `#{proof_text(test)}`" end)
    Enum.join([@proofs_start, @proofs_intro, "" | lines] ++ [@proofs_end], "\n")
  end

  defp proof_text(test), do: test |> String.replace(["<!--", "-->", "`"], "") |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, @test_max)

  # The block where the markers stand, any repeated block dropped. A start marker with no end is
  # read as a block running to the end of the walkthrough section's line it is on.
  defp replace_proofs(before, after_start, block) do
    rest =
      case :binary.split(after_start, @proofs_end) do
        [_inner, rest] -> rest
        [unterminated] -> unterminated |> String.split("\n", parts: 2) |> Enum.at(1, "")
      end

    rest = strip_proofs(rest)

    case block do
      nil -> join_around(before, rest)
      block -> before <> block <> rest
    end
  end

  defp join_around(before, rest) do
    case {String.trim_trailing(before), String.trim_leading(rest, "\n")} do
      {"", rest} -> rest
      {before, ""} -> before <> "\n"
      {before, rest} -> before <> "\n\n" <> rest
    end
  end

  defp place_proofs(description, nil), do: description

  defp place_proofs(description, block) do
    lines = String.split(description, "\n")

    case Enum.find_index(lines, &Regex.match?(@heading, &1)) do
      nil ->
        description

      heading ->
        {content, after_section} = Enum.split(lines, section_end(lines, heading) + 1)
        {content, blank} = split_trailing_blank(content)
        tail = if after_section == [], do: blank, else: [""]
        Enum.join(content ++ ["", block] ++ tail ++ after_section, "\n")
    end
  end

  # `text` without every projected block; the blank lines around one fold into one.
  defp strip_proofs(text) do
    case :binary.split(text, @proofs_start) do
      [_none] -> text
      [before, after_start] -> replace_proofs(before, after_start, nil)
    end
  end

  defp proof_entries([_proof | _rest] = proofs) do
    with {:ok, entries} <- reduce_ok(proofs, [], &prepend_entry/2), do: {:ok, Enum.reverse(entries)}
  end

  defp proof_entries(_proofs), do: invalid_proof("`proofs` must be a non-empty list of objects, each with a `step` number and a `test`")

  defp proof_entry(%{"step" => number, "test" => test}) when is_integer(number) and number > 0 and is_binary(test) do
    test = String.trim(test)

    cond do
      test == "" or String.contains?(test, ["`", "\n"]) ->
        invalid_proof("step #{number}: the test must be one non-blank line without backticks")

      Regex.match?(@separator, test) ->
        invalid_proof(
          "step #{number}: name the test only, never a check: `#{test}` holds a ` › ` or ` > ` separator. " <>
            "The repo's `proof_check` in its WORKFLOW.md names the check that runs it"
        )

      qa_spec?(test) ->
        invalid_proof("step #{number}: `#{test}` is not a test. Leave a step no test of this PR covers as it is, for QA")

      true ->
        {:ok, {number, test}}
    end
  end

  defp proof_entry(_proof), do: invalid_proof("each proof needs a positive integer `step` and a string `test`")

  defp prepend_entry(proof, entries) do
    with {:ok, entry} <- proof_entry(proof), do: {:ok, [entry | entries]}
  end

  # Folds `fun` over `list` while it answers `{:ok, acc}`; the first error is the result.
  defp reduce_ok(list, acc, fun) do
    Enum.reduce_while(list, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp walkthrough_steps(description) do
    case section(description) do
      nil -> invalid_proof("the description has no `## User walkthrough` section")
      text -> {:ok, steps(text)}
    end
  end

  # Why the walkthrough's step `number` takes no proof, or nil when it does.
  defp unprovable(steps, number) do
    case Enum.find(steps, &(&1.number == number)) do
      nil -> invalid_proof("the walkthrough has no step #{number}")
      step -> if qa_marked?(step.text), do: invalid_proof("step #{number} ends with `Proved by: QA`: its author asked QA to walk it, so it keeps that proof")
    end
  end

  defp invalid_proof(message), do: {:error, {:invalid_walkthrough_proof, message}}

  # The step's author asked QA to walk it: its last `Proved by:` outside inline code says `QA`.
  defp qa_marked?(text) do
    case last_proved_by(text) do
      nil ->
        false

      {position, length} ->
        text
        |> binary_part(position + length, byte_size(text) - position - length)
        |> normalize_spec()
        |> qa_spec?()
    end
  end

  defp section_end(lines, heading) do
    lines
    |> Enum.drop(heading + 1)
    |> Enum.find_index(&ends_section?/1)
    |> case do
      nil -> length(lines) - 1
      offset -> heading + offset
    end
  end

  defp ends_section?(line), do: Regex.match?(@any_heading, line) or Regex.match?(@symphony_marker, line)

  defp split_trailing_blank(lines) do
    {blank, content} = lines |> Enum.reverse() |> Enum.split_while(&(String.trim(&1) == ""))
    {Enum.reverse(content), Enum.reverse(blank)}
  end

  defp section_body(lines, index) do
    lines
    |> Enum.drop(index + 1)
    |> Enum.take_while(&(not ends_section?(&1)))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp collect_line(line, acc) do
    case {Regex.run(@step_start, line), acc} do
      {[_line, number, rest], acc} -> [{String.to_integer(number), [rest]} | acc]
      {nil, [{number, lines} | acc]} -> [{number, [line | lines]} | acc]
      {nil, []} -> []
    end
  end

  # The byte position and length of the last `Proved by:` in `body` outside inline code, or nil.
  defp last_proved_by(body) do
    spans = code_spans(body)

    @proved_by
    |> Regex.scan(body, return: :index)
    |> Enum.map(fn [match] -> match end)
    |> Enum.reject(fn {position, _length} -> Enum.any?(spans, fn {from, to} -> position >= from and position < to end) end)
    |> List.last()
  end

  # The byte ranges of `body`'s inline code: a run of backticks up to the next run of the same
  # length (CommonMark's code span). A run with no closing run is a literal backtick.
  defp code_spans(body) do
    @backticks
    |> Regex.scan(body, return: :index)
    |> Enum.map(fn [run] -> run end)
    |> pair_runs([])
  end

  defp pair_runs([], spans), do: spans

  defp pair_runs([{from, length} | rest], spans) do
    case Enum.drop_while(rest, fn {_position, run_length} -> run_length != length end) do
      [{to, ^length} | after_span] -> pair_runs(after_span, [{from, to + length} | spans])
      [] -> pair_runs(rest, spans)
    end
  end

  defp normalize_spec(spec), do: spec |> String.replace(~r/\s+/, " ") |> String.replace("`", "") |> String.trim() |> String.trim_trailing(".") |> String.trim()

  # A spec with a separator names a test even when its check starts with `qa` (`qa-e2e › login`).
  defp qa_spec?(spec), do: not Regex.match?(@separator, spec) and Regex.match?(@qa, spec)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
