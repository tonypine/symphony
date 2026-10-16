defmodule SymphonyElixir.Walkthrough do
  @moduledoc """
  Reads a ticket's `## User walkthrough` into steps, each with the one place that proves it
  (ADR 0003, `docs/adr/0003-automated-tests-first-qa-last-resort.md`).

  A step ends with one proof line:

    * `Proved by: <check> › <test>`: a named automated test. `<check>` is the GitHub check run
      (or workflow) that runs it on the PR head; `<test>` the suite, scenario or test file. A
      plain ` > ` works as the separator too, and backticks around either part are dropped.
      `Proved by: <check>` alone names the check without a test.
    * `Proved by: QA`: the QA agent walks the step.

  A step with no `Proved by:` is read as `Proved by: QA`, so tickets written before the rule keep
  working. The QA prompt (`SymphonyElixir.QaAgent`) tells QA to link, not walk, the named-test
  steps.
  """

  @heading ~r/^\s*\#{1,6}\s+User walkthrough\s*:?\s*$/i
  @any_heading ~r/^\s*\#{1,6}\s+\S/
  @step_start ~r/^ {0,3}(\d+)[.)]\s+(.*)$/
  @proved_by ~r/proved by:/i
  @separator ~r/\s*(?:›|\s>\s)\s*/u

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
  """
  @spec steps(String.t() | nil) :: [step()]
  def steps(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], &collect_line/2)
    |> Enum.reverse()
    |> Enum.map(&to_step/1)
  end

  def steps(_text), do: []

  @doc "Whether `step` is proved by a named test, so QA links it instead of walking it."
  @spec named_test?(step()) :: boolean()
  def named_test?(%{proof: %{by: :test}}), do: true
  def named_test?(_step), do: false

  @doc "The proof of `step` written back as its `Proved by:` line."
  @spec proof_line(step()) :: String.t()
  def proof_line(%{proof: %{by: :test, check: check, test: nil}}), do: "Proved by: `#{check}`"
  def proof_line(%{proof: %{by: :test, check: check, test: test}}), do: "Proved by: `#{check}` › #{test}"
  def proof_line(_step), do: "Proved by: QA"

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

  defp to_step({number, lines}) do
    body = lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()

    case split_last(body) do
      {text, spec} -> %{number: number, text: text, proof: proof(spec)}
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

  defp proof(spec) do
    spec = spec |> String.replace(~r/\s+/, " ") |> String.trim() |> String.trim_trailing(".") |> String.trim()

    if spec == "" or Regex.match?(~r/^`?qa\b/i, spec) do
      %{by: :qa}
    else
      case Regex.split(@separator, spec, parts: 2) do
        [check, test] -> %{by: :test, check: unquote_part(check), test: blank_to_nil(unquote_part(test))}
        [check] -> %{by: :test, check: unquote_part(check), test: nil}
      end
    end
  end

  defp unquote_part(part), do: part |> String.replace("`", "") |> String.trim()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
