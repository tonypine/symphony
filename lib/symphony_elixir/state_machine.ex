defmodule SymphonyElixir.StateMachine do
  @moduledoc """
  The one resolved version of the ticket state machine, per repo.

  A repo's version comes from `repositories[].state_machine` in `symphony.yml` (`legacy` or
  `designed`), defaulting to `legacy`. `version/1` is the single resolver: the transition guard,
  dispatch and prompt assembly each read the same resolved version, rather than branching on the
  setting at their own call sites.

  `active_states/1` is the dispatch half: the states the machine picks work up from for the repo's
  version. `legacy` uses the configured active states unchanged; `designed` adds the designed phase
  states (`code_review`, `qa`, `plan_review`, `epic_review`, `ci_fix`), so the designed machine
  dispatches from its new phases. Those additions are inert until a repo is switched: the guard's
  designed edge table is still parity with legacy, so nothing enters those states yet.
  """

  @legacy "legacy"
  @designed "designed"
  @versions [@legacy, @designed]
  @designed_phase_fields [:code_review_state, :qa_state, :plan_review_state, :epic_review_state, :ci_fix_state]

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

  @doc "The configured designed phase state names that are present and non-empty."
  @spec designed_phase_states(map()) :: [String.t()]
  def designed_phase_states(settings) do
    @designed_phase_fields
    |> Enum.map(&field(settings, &1))
    |> Enum.filter(&present_string?/1)
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
