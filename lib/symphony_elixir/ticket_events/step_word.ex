defmodule SymphonyElixir.TicketEvents.StepWord do
  @moduledoc """
  The one word a step's `step.completed` is drawn with: the ticket page's step list, the Conductor's
  `steps` and `attempts` blocks and the Conductor's facts all read it from here.

  A stepped QA pass's check step (a walk, a design check, a recheck) records two
  facts: `outcome`, whether the step ran to an answer Symphony takes, and `result.status`, what the
  step judged. A step that ran to an answer is drawn with its judgement, so a check that judged
  `fail` reads `failed` and one that judged `blocked` reads `blocked`; "the step ran" is not what a
  reader is shown. A walk that judged several walkthrough steps in one session records `results`, one
  per step: it reads `failed` when one of them failed, else `blocked` when one was blocked, else
  `passed` when every one passed. Any other step (a machine step, a step without a result, one that ended
  `failed`, `paused` or `skipped`) keeps its outcome. It reads the payload as recorded, so events
  written before the word existed draw the same way without a migration.
  """

  @judged %{"pass" => "passed", "fail" => "failed", "blocked" => "blocked"}

  @doc "The word `payload` (a `step.completed`'s, atom or string keys) is drawn with, or nil when it has no outcome."
  @spec word(map()) :: String.t() | nil
  def word(payload) when is_map(payload) do
    case {field(payload, :outcome), status(field(payload, :result)) || worst(field(payload, :results))} do
      {"passed", status} when is_map_key(@judged, status) -> Map.fetch!(@judged, status)
      {outcome, _status} -> outcome
    end
  end

  defp status(%{} = result), do: field(result, :status)
  defp status(_none), do: nil

  # A grouped walk's word: its worst judgement.
  defp worst([_ | _] = results) do
    statuses = Enum.map(results, &status/1)
    Enum.find(["fail", "blocked"], &(&1 in statuses)) || if(Enum.all?(statuses, &(&1 == "pass")), do: "pass")
  end

  defp worst(_none), do: nil

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
