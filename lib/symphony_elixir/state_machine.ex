defmodule SymphonyElixir.StateMachine do
  @moduledoc """
  The one resolved version of the ticket state machine, per repo.

  A repo's version comes from `repositories[].state_machine` in `symphony.yml` (`legacy` or
  `designed`), defaulting to `legacy`. `version/1` is the single resolver: the transition guard,
  dispatch and prompt assembly each read the same resolved version, rather than branching on the
  setting at their own call sites.

  `active_states/1` is the dispatch half: the states the machine picks work up from for the repo's
  version. `legacy` uses the configured active states unchanged; `designed` adds the designed phase
  states (`code_review`, `qa`, `epic_review`, `ci_fix`), so the designed machine dispatches from its
  new phases. `Plan Review` is a designed phase state too, but no run starts there: it is
  person-owned, the machine only watches it for a person's handoff (`HumanReview.plan_review_states/1`
  and the orchestrator's watching refresh), so it is deliberately not in the dispatch list — an
  issue in it is never picked up.
  """

  @legacy "legacy"
  @designed "designed"
  @versions [@legacy, @designed]
  # The designed phase states dispatch picks work up from.
  @designed_phase_fields [:code_review_state, :qa_state, :epic_review_state, :ci_fix_state]

  @typedoc "The state-machine version a repo runs."
  @type version :: String.t()

  @doc "The known versions, in display order."
  @spec versions() :: [version()]
  def versions, do: @versions

  @doc "The version a repo runs when `state_machine` is unset."
  @spec default_version() :: version()
  def default_version, do: @legacy

  @doc """
  The repo's resolved version: the configured value when it names a known version, else `legacy`.
  Accepts the runtime settings struct or a plain map.
  """
  @spec version(map() | nil) :: version()
  def version(settings) do
    case configured_version(settings) do
      value when value in @versions -> value
      _unset_or_unknown -> @legacy
    end
  end

  @doc "Whether the repo runs the designed machine."
  @spec designed?(map() | nil) :: boolean()
  def designed?(settings), do: version(settings) == @designed

  @doc """
  The states dispatch picks work up from for `settings`'s version: the configured active states,
  plus the designed phase states when the repo is on the designed machine.
  """
  @spec active_states(map()) :: [String.t()]
  def active_states(settings) do
    active_states(version(settings), active_state_names(settings), designed_phase_states(settings))
  end

  @doc "The active states for an explicit version, base list and designed phase list."
  @spec active_states(version(), [String.t()], [String.t()]) :: [String.t()]
  def active_states(version, base, designed_phase) do
    if version == @designed, do: Enum.uniq(base ++ designed_phase), else: base
  end

  @doc """
  The configured designed phase state names dispatch picks work up from, present and non-empty.
  `Plan Review` is not one of them: it is person-owned and never dispatched.

  Accepts the runtime settings struct, whose phase states sit under `tracker`, or a bare tracker
  map, whose fields sit at its top level.
  """
  @spec designed_phase_states(map()) :: [String.t()]
  def designed_phase_states(settings) do
    @designed_phase_fields
    |> Enum.map(&phase_state(settings, &1))
    |> Enum.filter(&present_string?/1)
  end

  defp phase_state(settings, field_name) do
    field(settings, field_name) || field(field(settings, :tracker), field_name)
  end

  defp configured_version(settings) when is_map(settings) do
    value = field(settings, :state_machine) || field(settings, "state_machine")
    if is_binary(value), do: value |> String.trim() |> String.downcase(), else: nil
  end

  defp configured_version(_settings), do: nil

  defp active_state_names(settings) do
    case field(settings, :tracker) || field(settings, "tracker") do
      tracker when is_map(tracker) -> List.wrap(field(tracker, :active_states) || field(tracker, "active_states"))
      _tracker -> []
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end
