defmodule SymphonyElixir.PersonWait do
  @moduledoc """
  Whether an issue waits on a person, for the CI and PR review pollers: a red head or a merge
  conflict starts no fix run for such an issue, since a fix run can't do what the person must.

  An issue waits on a person when it sits outside `tracker.active_states` with a label that asks for
  one (`needs-human`, a `legacy_request_labels/1` label, or an `auto_review.acceptance_gate.escalate`
  label other than `plan` and `breakdown`, which every plan carries), or outside every state the
  pollers move issues on from (`Backlog`, a terminal state), where it waits for a person to promote
  it. Labels and states compare case-insensitively.

  The `human-action` label that used to mark an open request is retired: a config that still sets
  `human_actions.label`, or lists `human-action` in the `escalate.labels`, loads with a deprecation
  warning, and an issue carrying that label counts as one with an open request
  (`legacy_request_labels/1`).
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.StateMachine

  @merging_state "Merging"
  # Asks for a person whatever the `escalate.labels` say (see `parked?/2`).
  @needs_human_label "needs-human"
  # The retired label that marked an open human-action request (see `legacy_request_labels/1`).
  @legacy_request_label "human-action"

  @doc """
  True when `issue` sits outside `tracker.active_states` with a label that asks for a person. The
  pollers leave such an issue where it is until the label goes or it moves to an active state.
  """
  @spec parked?(Issue.t(), Schema.t()) :: boolean()
  def parked?(%Issue{state: issue_state, labels: labels}, %Schema{} = settings) do
    wanted = MapSet.new(person_labels(settings), &normalize/1)

    not active_state?(issue_state, settings) and
      Enum.any?(labels || [], &(is_binary(&1) and MapSet.member?(wanted, normalize(&1))))
  end

  @doc """
  `parked?/2` for the CI and PR review pollers, which also leave an issue where it is when it sits
  outside every state they move issues on from: the machine's active states and `Merging`, plus any
  `:watched_states` a poller adds (`Rework`, say, whose red head routes to the CI Fix lane). Such an
  issue (`Backlog`, a terminal state) waits for a person to promote it, so a red head or a merge
  conflict starts no fix run and spends no retry.
  """
  @spec held?(Issue.t(), Schema.t(), keyword()) :: boolean()
  def held?(%Issue{state: issue_state} = issue, %Schema{} = settings, opts) do
    if poller_state?(issue_state, settings, opts), do: parked?(issue, settings), else: true
  end

  defp poller_state?(issue_state, settings, opts) when is_binary(issue_state) do
    states = StateMachine.active_states(settings) ++ [@merging_state | List.wrap(Keyword.get(opts, :watched_states))]
    Enum.any?(states, &(is_binary(&1) and normalize(&1) == normalize(issue_state)))
  end

  defp poller_state?(_issue_state, _settings, _opts), do: false

  @doc """
  The labels that still mark an open human-action request, from a config that predates the Needs
  Decision hold: `human_actions.label` when it is set, and `human-action` when the gate's
  `escalate.labels` list it. Both are deprecated (`SymphonyElixir.Config.SystemSchema` warns when
  it loads them); an issue carrying one counts as an issue with an open request. Lower case.
  """
  @spec legacy_request_labels(Schema.t()) :: [String.t()]
  def legacy_request_labels(%Schema{} = settings) do
    configured = settings.human_actions.label
    escalated? = Enum.any?(settings.auto_review.acceptance_gate.escalate.labels, &(normalize(&1) == @legacy_request_label))

    [configured, if(escalated?, do: @legacy_request_label)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize/1)
    |> Enum.uniq()
  end

  @doc "The retired label that marked an open human-action request."
  @spec legacy_request_label() :: String.t()
  def legacy_request_label, do: @legacy_request_label

  defp active_state?(issue_state, settings) when is_binary(issue_state),
    do: Enum.any?(settings.tracker.active_states, &(normalize(&1) == normalize(issue_state)))

  defp active_state?(_issue_state, _settings), do: false

  defp person_labels(settings) do
    [@needs_human_label | legacy_request_labels(settings) ++ settings.auto_review.acceptance_gate.escalate.labels]
    |> Enum.reject(&Issue.breakdown_label?/1)
  end

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
