defmodule SymphonyElixir.StateMachine do
  @moduledoc """
  The dispatch half of the ticket state machine (`docs/design/state-machine.md`): the states the
  machine picks work up from.

  There is one machine. The `legacy` version and the per-repo `repositories[].state_machine` switch
  are gone with the `In Review` and `Human Review` states; a config that still sets the key loads
  with a deprecation warning (`SymphonyElixir.Config.SystemSchema`).

  `active_states/1` is the configured active states plus the phase states (`code_review`, `qa`,
  `epic_review`, `ci_fix`). `Plan Review` is a phase state too, but no run starts there: it is
  person-owned, the machine only watches it for a person's handoff (`SymphonyElixir.PlanReview`
  and the orchestrator's watching refresh), so it is deliberately not in the dispatch list — an
  issue in it is never picked up.
  """

  # The phase states dispatch picks work up from.
  @phase_fields [:code_review_state, :qa_state, :epic_review_state, :ci_fix_state]

  # The machine's phases in board order: a fixed name or the tracker field that names it. A
  # configured state the order doesn't place goes after CI Fix when it is active and last when it
  # is closed, in the order the config lists it.
  @board [
    "Backlog",
    "Todo",
    "In Progress",
    :code_review_state,
    :qa_state,
    "Merging",
    "Rework",
    :plan_review_state,
    :epic_review_state,
    :waiting_on_sub_issues_state,
    :ci_fix_state,
    "Done",
    "Canceled",
    "Cancelled"
  ]
  @open_rank Enum.find_index(@board, &(&1 == :ci_fix_state)) + 0.5
  @closed_rank length(@board)

  @typedoc "A phase of the machine: its name as the workflow names it and whether entering it dispatches a run."
  @type phase :: %{name: String.t(), dispatches: boolean()}

  @doc """
  The states dispatch picks work up from for `settings`: the configured active states plus the
  phase states, never `Plan Review`, even when the active states name it.
  """
  @spec active_states(map() | nil) :: [String.t()]
  def active_states(settings) do
    tracker_active_states(field(settings, :tracker) || field(settings, "tracker") || %{}, settings)
  end

  @doc """
  The states dispatch picks work up from for bare tracker settings: the tracker's active states
  plus its phase states, never its `Plan Review` state, even when the active states name it.
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
  @spec phase_states(map() | nil) :: [String.t()]
  def phase_states(settings) do
    @phase_fields
    |> Enum.map(&phase_state(settings, &1))
    |> Enum.filter(&present_string?/1)
  end

  defp phase_state(settings, field_name) do
    field(settings, field_name) || field(field(settings, :tracker), field_name)
  end

  @doc """
  Every phase of the machine for `settings`, once each and in board order: `Backlog`, the active
  states, the phase states (Code Review, QA, Plan Review, Epic Review, CI Fix), the waiting state
  and the closed states, each by the name the workflow gives it. `dispatches` is true for a phase
  dispatch picks work up from (`active_states/1`), except the waiting state, where a plan parent
  waits on its sub-tickets and no run starts (`SymphonyElixir.SubIssueWait.held?/3`).
  """
  @spec phases(map()) :: [phase()]
  def phases(settings) do
    tracker = field(settings, :tracker)
    waiting = phase_state(settings, :waiting_on_sub_issues_state)
    plan_review = phase_state(settings, :plan_review_state)
    active = settings |> active_states() |> MapSet.new(&normalize/1)
    closed = tracker |> field(:terminal_states) |> List.wrap()
    named = [plan_review, waiting] ++ phase_states(settings)

    (["Backlog" | List.wrap(field(tracker, :active_states))] ++ named ++ closed)
    |> Enum.filter(&present_string?/1)
    |> Enum.uniq_by(&normalize/1)
    |> Enum.with_index()
    |> Enum.sort_by(fn {name, index} -> {board_rank(name, settings, closed), index} end)
    |> Enum.map(fn {name, _index} ->
      %{name: name, dispatches: MapSet.member?(active, normalize(name)) and not same?(name, waiting)}
    end)
  end

  defp board_rank(name, settings, closed) do
    case Enum.find_index(@board, &same?(name, board_name(&1, settings))) do
      nil -> if Enum.any?(closed, &same?(name, &1)), do: @closed_rank, else: @open_rank
      rank -> rank
    end
  end

  defp board_name(field_name, settings) when is_atom(field_name), do: phase_state(settings, field_name)
  defp board_name(name, _settings), do: name

  defp same?(name, other), do: is_binary(other) and normalize(name) == normalize(other)

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end
