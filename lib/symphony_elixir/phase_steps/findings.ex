defmodule SymphonyElixir.PhaseSteps.Findings do
  @moduledoc """
  What the `findings` step of a rework run reads from the ticket's ledger, before any code is
  written (`SymphonyElixir.PhaseSteps`, the built-in command `Phases.findings_command/0`): the open
  findings by class, kept as the step's output, and the failures that came back.

  A failure came back when QA failed the ticket on the same thing in two QA runs (two findings of
  one run are one failure), its last finding is still open or reopened, and no answered Question of
  this step was asked since. The same thing is a class; for a finding QA left `unclassified`, the
  same step at the same viewport, the match that reopens a finding (`SymphonyElixir.QaVerification`).
  A finding with neither says nothing about the next one.

  `question/2` is what the step pauses on then: both findings and two ways forward. Each answer, an
  option or the person's own words, goes to the agent step the findings step returns to
  (`SymphonyElixir.PhaseSteps.machine_resume/1`).
  """

  alias SymphonyElixir.HumanActions.PlainWords
  alias SymphonyElixir.TicketEvents
  alias SymphonyElixir.TicketEvents.Event

  @unclassified "unclassified"
  @another_way "Try another approach"
  @same_way "Keep this approach"
  @description_chars 400

  @typedoc "A failure that came back: what it is (`label`) and its last two findings, oldest first."
  @type repeat :: %{label: String.t(), first: Event.t(), last: Event.t()}

  @doc """
  Reads a ticket's `events` (oldest first) against the Questions it has answered (`answered`): the
  step's `output` and the failures that came back (`repeats`).
  """
  @spec read([Event.t()], [map()]) :: %{output: String.t(), repeats: [repeat()]}
  def read(events, answered) when is_list(events) and is_list(answered) do
    findings = TicketEvents.findings(events)
    %{output: output(findings), repeats: repeats(events, findings, answered)}
  end

  @doc "Whether `question` is one the findings step asked (`question/2`)."
  @spec asked_here?(map()) :: boolean()
  def asked_here?(%{options: options}), do: Enum.any?(options, &(&1.label in [@another_way, @same_way]))

  @doc "The Question the step pauses on for `repeats`, on the ticket called `name`."
  @spec question(String.t(), [repeat(), ...]) :: map()
  def question(name, [_ | _] = repeats) do
    labels = Enum.map_join(repeats, " and ", &PlainWords.scrub(&1.label))

    %{
      title: String.slice("#{name}: QA failed twice on #{labels}", 0, 120),
      question: "QA failed #{name} twice on #{labels}. Should its next attempt try another approach, or keep this one and fix what QA found?",
      why: Enum.map_join(repeats, " ", &history/1) <> " Symphony does not start a third attempt on its own, so nobody writes code until you answer.",
      if_unanswered: "#{name} stays paused and nobody writes code on it.",
      recommendation_reason: "The same failure twice suggests the approach itself is wrong, so a third try of it is likely to fail again.",
      options: [
        %{
          label: @another_way,
          effect: "The next attempt on #{name} drops the approach it tried and fixes what QA found another way.",
          recommended: true,
          tradeoffs: [%{kind: "cost", text: "It may redo work that QA already accepted."}]
        },
        %{
          label: @same_way,
          effect: "The next attempt on #{name} keeps the approach and fixes only what QA found.",
          recommended: false,
          tradeoffs: [%{kind: "risk", text: "QA may fail it the same way a third time."}]
        }
      ]
    }
  end

  defp history(%{label: label, first: first, last: last}) do
    "On #{PlainWords.scrub(label)}, QA found this first: #{description(first)} Then it found this: #{description(last)}"
  end

  defp description(%Event{payload: payload}) do
    text = payload |> Map.get(:description) |> PlainWords.scrub() |> String.slice(0, @description_chars) |> String.trim_trailing(".")
    text <> "."
  end

  defp output(findings) do
    case Enum.reject(findings, &(&1.state == :confirmed)) do
      [] ->
        "No open findings.\n"

      open ->
        groups = open |> Enum.group_by(&class(&1.finding)) |> Enum.sort_by(fn {name, group} -> {-length(group), name} end)
        Enum.join(["Open findings by class (#{length(open)}):" | Enum.flat_map(groups, &group_lines/1)], "\n") <> "\n"
    end
  end

  defp group_lines({name, group}), do: ["", "#{name} (#{length(group)}):" | Enum.map(group, &finding_line/1)]

  defp finding_line(%{state: state, finding: %Event{payload: payload}}) do
    facts = Enum.reject([state_text(state), prefixed("at ", payload, :viewport), prefixed("step ", payload, :step)], &is_nil/1)
    "- #{Enum.join(facts, ", ")}: #{Map.get(payload, :description)}"
  end

  defp state_text(:open), do: "open"
  defp state_text(:reopened), do: "reopened"
  defp state_text(:resolved), do: "resolved, awaiting QA"

  defp prefixed(prefix, payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) -> prefix <> value
      _none -> nil
    end
  end

  defp class(%Event{payload: payload}), do: Map.get(payload, :class) || @unclassified

  defp repeats(events, findings, answered) do
    standing = standing_ids(findings)
    asked = answered |> Enum.filter(&asked_here?/1) |> Enum.map(& &1.asked_at)

    events
    |> Enum.filter(&(&1.type == "finding.recorded"))
    |> Enum.group_by(&failure_key/1)
    |> Enum.sort_by(fn {key, _failures} -> key end)
    |> Enum.flat_map(fn {key, failures} -> repeat(key, one_per_run(failures), standing, asked) end)
  end

  # The event that last put each open or reopened finding on the ticket: a resolved or confirmed one
  # is not what this rework is about.
  defp standing_ids(findings) do
    for %{state: state} = entry <- findings, state in [:open, :reopened], into: MapSet.new() do
      (entry.reopened_by || entry.finding).id
    end
  end

  defp failure_key(%Event{id: id, payload: payload} = event) do
    case {class(event), match_text(Map.get(payload, :step))} do
      {@unclassified, nil} -> {:finding, id}
      {@unclassified, step} -> {:step, step, match_text(Map.get(payload, :viewport))}
      {class, _step} -> {:class, class}
    end
  end

  defp match_text(text) when is_binary(text), do: text |> String.trim() |> String.downcase()
  defp match_text(_text), do: nil

  defp one_per_run(failures), do: failures |> Enum.reverse() |> Enum.uniq_by(&(&1.run_id || &1.id)) |> Enum.reverse()

  defp repeat(key, failures, standing, asked) when length(failures) >= 2 do
    [first, last] = Enum.take(failures, -2)

    if MapSet.member?(standing, last.id) and not Enum.any?(asked, &(DateTime.compare(&1, last.at) == :gt)),
      do: [%{label: label(key), first: first, last: last}],
      else: []
  end

  defp repeat(_key, _failures, _standing, _asked), do: []

  defp label({:class, class}), do: class
  defp label({:step, _step, _viewport}), do: "the same step"
end
