defmodule SymphonyElixir.Walkthrough do
  @moduledoc """
  Reads a ticket's `## User walkthrough` into steps, each with the one place that proves it
  (ADR 0003, `docs/adr/0003-automated-tests-first-qa-last-resort.md`).

  The person writing the ticket describes the steps in plain words; the implementer, who writes
  the tests, ends a step it covers with a proof line, and the repo names the check that runs them
  (`proof_check` in its WORKFLOW.md):

    * `Proved by: <test>`: a named automated test that the repo's `proof_check` runs on the PR
      head. `<test>` is the suite, scenario or test file, as the code has it.
    * `Proved by: <check> › <test>`: the older form, naming the GitHub check run (or workflow)
      itself, such as a path-filtered `macos-e2e`. A plain ` > ` works as the separator too, and
      backticks around either part are dropped. A bare `Proved by: <proof_check>` names the check
      without a test.
    * `Proved by: QA`: the QA agent walks the step.

  A step with no `Proved by:` is read as `Proved by: QA`. A repo without a `proof_check` has no
  named-test proofs: every step of its walkthroughs is a QA step. The QA pre-check
  (`SymphonyElixir.QaPreCheck`) confirms the named-test steps on the PR head before the QA agent
  starts, and the QA prompt (`SymphonyElixir.QaAgent`) tells QA to link, not walk, them.
  """

  @heading ~r/^\s*\#{1,6}\s+User walkthrough\s*:?\s*$/i
  @any_heading ~r/^\s*\#{1,6}\s+\S/
  @step_start ~r/^ {0,3}(\d+)[.)]\s+(.*)$/
  @proved_by ~r/proved by:/i
  @separator ~r/\s*(?:›|\s>\s)\s*/u
  # `QA` as the whole spec, or followed only by a note: `QA (light mode only)`, `QA: desktop`.
  @qa ~r/^qa(?:$|\s*[(:,;]|\s+[-–—]\s)/iu

  @type proof :: %{by: :test, check: String.t(), test: String.t() | nil} | %{by: :qa}
  @type step :: %{number: pos_integer(), text: String.t(), proof: proof()}

  @doc "The body of the `## User walkthrough` section in `description`, or nil when it has none."
  @spec section(String.t() | nil) :: String.t() | nil
  def section(description) when is_binary(description) do
    lines = String.split(description, "\n")

    with index when is_integer(index) <- Enum.find_index(lines, &Regex.match?(@heading, &1)),
         body when body != "" <- section_body(lines, index) do
      body
    else
      _none -> nil
    end
  end

  def section(_description), do: nil

  @doc """
  The numbered steps of a walkthrough's text, in order, each with its proof. Lines before the
  first step (such as `Nothing changes on screen.`) are not steps; a step runs until the next one.

  `proof_check` is the repo's `proof_check`: the check a `Proved by: <test>` step names. When it is
  nil, every step is a QA step.
  """
  @spec steps(String.t() | nil, String.t() | nil) :: [step()]
  def steps(text, proof_check) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], &collect_line/2)
    |> Enum.reverse()
    |> Enum.map(&to_step(&1, blank_to_nil(String.trim(proof_check || ""))))
  end

  def steps(_text, _proof_check), do: []

  @doc "Whether `step` is proved by a named test, so QA links it instead of walking it."
  @spec named_test?(step()) :: boolean()
  def named_test?(%{proof: %{by: :test}}), do: true
  def named_test?(_step), do: false

  @doc "The proof of `step` written back as its `Proved by:` line."
  @spec proof_line(step()) :: String.t()
  def proof_line(%{proof: %{by: :test, check: check, test: nil}}), do: "Proved by: `#{check}`"
  def proof_line(%{proof: %{by: :test, check: check, test: test}}), do: "Proved by: `#{check}` › #{test}"
  def proof_line(_step), do: "Proved by: QA"

  @doc """
  Writes the implementer's proofs into `description`'s `## User walkthrough`. `proofs` is a list
  of `%{"step" => number, "test" => test}`: each named step ends with ``Proved by: `<test>` `` in
  place of the test proof it had, or with it appended when it had none. Every other byte of the
  description stays as it is.

  A proof names a test only, never a check (the repo's `proof_check` names that), so a test with a
  ` › ` or ` > ` separator is refused. A step whose author wrote `Proved by: QA` keeps it: the author
  asked QA to walk it. A step with no `Proved by:` is the implementer's to cover.
  """
  @spec record_proofs(String.t() | nil, term()) ::
          {:ok, String.t()} | {:error, {:invalid_walkthrough_proof, String.t()}}
  def record_proofs(description, proofs) do
    with {:ok, proofs} <- proof_entries(proofs),
         {:ok, lines} <- walkthrough_lines(description),
         {:ok, lines} <- reduce_ok(proofs, lines, fn {number, test}, lines -> record_proof(lines, number, test) end) do
      {:ok, Enum.join(lines, "\n")}
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

      qa_spec?(test, test) ->
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

  defp walkthrough_lines(description) when is_binary(description) do
    lines = String.split(description, "\n")

    if Enum.any?(lines, &Regex.match?(@heading, &1)),
      do: {:ok, lines},
      else: invalid_proof("the description has no `## User walkthrough` section")
  end

  defp walkthrough_lines(_description), do: invalid_proof("the description has no `## User walkthrough` section")

  # The step's lines are those from its number to the next step or the section's end; its trailing
  # blank lines stay where they are.
  defp record_proof(lines, number, test) do
    heading = Enum.find_index(lines, &Regex.match?(@heading, &1))
    section_end = section_end(lines, heading)

    case step_range(lines, heading + 1, section_end, number) do
      {first, last} ->
        {content, blank} = lines |> Enum.slice(first..last) |> split_trailing_blank()

        with {:ok, body} <- with_proof(Enum.join(content, "\n"), number, test) do
          {:ok, Enum.take(lines, first) ++ String.split(body, "\n") ++ blank ++ Enum.drop(lines, last + 1)}
        end

      nil ->
        invalid_proof("the walkthrough has no step #{number}")
    end
  end

  defp section_end(lines, heading) do
    lines
    |> Enum.drop(heading + 1)
    |> Enum.find_index(&Regex.match?(@any_heading, &1))
    |> case do
      nil -> length(lines) - 1
      offset -> heading + offset
    end
  end

  defp step_range(lines, from, to, number) do
    starts =
      for index <- from..to//1, match = Regex.run(@step_start, Enum.at(lines, index)), do: {index, String.to_integer(Enum.at(match, 1))}

    case Enum.find_index(starts, &(elem(&1, 1) == number)) do
      nil ->
        nil

      position ->
        {first, _number} = Enum.at(starts, position)

        case Enum.at(starts, position + 1) do
          {next, _number} -> {first, next - 1}
          nil -> {first, to}
        end
    end
  end

  defp split_trailing_blank(lines) do
    {blank, content} = lines |> Enum.reverse() |> Enum.split_while(&(String.trim(&1) == ""))
    {Enum.reverse(content), Enum.reverse(blank)}
  end

  # The step's text up to its last `Proved by:`, with the new proof after it; or the text with the
  # proof appended when it has none. An explicit `Proved by: QA` is the author's and is kept.
  defp with_proof(body, number, test) do
    proof = "Proved by: `#{test}`"

    case Regex.scan(@proved_by, body, return: :index) do
      [] ->
        {:ok, body <> " " <> proof}

      matches ->
        [{position, length}] = List.last(matches)
        spec = body |> binary_part(position + length, byte_size(body) - position - length) |> normalize_spec()

        if spec != "" and qa_spec?(unquote_part(spec), spec),
          do: invalid_proof("step #{number} ends with `Proved by: QA`: its author asked QA to walk it, so it keeps that proof"),
          else: {:ok, binary_part(body, 0, position) <> proof}
    end
  end

  defp invalid_proof(message), do: {:error, {:invalid_walkthrough_proof, message}}

  defp section_body(lines, index) do
    lines
    |> Enum.drop(index + 1)
    |> Enum.take_while(&(not Regex.match?(@any_heading, &1)))
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

  defp to_step({number, lines}, proof_check) do
    body = lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()

    case split_last(body) do
      {text, _spec} when is_nil(proof_check) -> %{number: number, text: text, proof: %{by: :qa}}
      {text, spec} -> %{number: number, text: text, proof: proof(spec, proof_check)}
      nil -> %{number: number, text: body, proof: %{by: :qa}}
    end
  end

  # The step's text and the spec after its last `Proved by:`, or nil when the step has none.
  defp split_last(body) do
    case Regex.split(@proved_by, body) do
      [_body] ->
        nil

      parts ->
        {spec, text_parts} = List.pop_at(parts, -1)
        {text_parts |> Enum.join("Proved by:") |> String.trim(), spec}
    end
  end

  defp proof(spec, proof_check) do
    spec = normalize_spec(spec)

    if qa_spec?(unquote_part(spec), spec) do
      %{by: :qa}
    else
      case Regex.split(@separator, spec, parts: 2) do
        [check, test] -> %{by: :test, check: unquote_part(check), test: blank_to_nil(unquote_part(test))}
        [test] -> short_proof(unquote_part(test), proof_check)
      end
    end
  end

  # `Proved by: <test>`: a test the repo's proof check runs. The proof check's own name alone names
  # the check without a test, as `Proved by: <check>` did before the short form.
  defp short_proof(test, proof_check) do
    if String.downcase(test) == String.downcase(proof_check),
      do: %{by: :test, check: proof_check, test: nil},
      else: %{by: :test, check: proof_check, test: test}
  end

  defp normalize_spec(spec), do: spec |> String.replace(~r/\s+/, " ") |> String.trim() |> String.trim_trailing(".") |> String.trim()

  # A spec with a separator names a test even when its check starts with `qa` (`qa-e2e › login`).
  defp qa_spec?("", _spec), do: true
  defp qa_spec?(bare, spec), do: not Regex.match?(@separator, spec) and Regex.match?(@qa, bare)

  defp unquote_part(part), do: part |> String.replace("`", "") |> String.trim()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
