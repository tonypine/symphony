defmodule SymphonyElixir.StateMachine do
  @moduledoc """
  The dispatch half of the ticket state machine: the states the machine picks work up from.

  Symphony runs one state machine (`docs/design/state-machine.md`). `active_states/1` returns the
  configured active states plus the phase states (`code_review`, `qa`, `epic_review`, `ci_fix`), so
  dispatch picks work up from the phases. `Plan Review` is a phase state too, but no run starts
  there: it is person-owned, the machine only watches it for a person's handoff
  (`HumanReview.plan_review_states/1` and the orchestrator's watching refresh), so it is
  deliberately not in the dispatch list — an issue in it is never picked up.
  """

  # The phase states dispatch picks work up from.
  @phase_fields [:code_review_state, :qa_state, :epic_review_state, :ci_fix_state]

  @doc """
  The states dispatch picks work up from for `settings`: the configured active states plus the
  phase states, never `Plan Review`, even when the active states name it.
  """
  @spec active_states(map()) :: [String.t()]
  def active_states(settings) do
    tracker_active_states(field(settings, :tracker) || field(settings, "tracker") || %{}, settings)
  end

  @doc """
  The states dispatch picks work up from for explicit tracker settings: the tracker's active
  states plus its phase states, never its `Plan Review` state, even when the active states name it.
  """
  @spec tracker_active_states(map()) :: [String.t()]
  def tracker_active_states(tracker) when is_map(tracker), do: tracker_active_states(tracker, tracker)

  defp tracker_active_states(tracker, phase_source) do
    base = List.wrap(field(tracker, :active_states) || field(tracker, "active_states"))
    states = Enum.uniq(base ++ phase_states(phase_source))

    case phase_state(phase_source, :plan_review_state) do
      plan_review when is_binary(plan_review) -> Enum.reject(states, &(normalize(&1) == normalize(plan_review)))
      _plan_review -> states
    end
  end

  defp normalize(state), do: state |> to_string() |> String.trim() |> String.downcase()

  @doc """
  The configured phase state names dispatch picks work up from, present and non-empty.
  `Plan Review` is not one of them: it is person-owned and never dispatched.

  Accepts the runtime settings struct, whose phase states sit under `tracker`, or a bare tracker
  map, whose fields sit at its top level.
  """
  @spec phase_states(map()) :: [String.t()]
  def phase_states(settings) do
    @phase_fields
    |> Enum.map(&phase_state(settings, &1))
    |> Enum.filter(&present_string?/1)
  end

  defp phase_state(settings, field_name) do
    field(settings, field_name) || field(field(settings, :tracker), field_name)
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end
