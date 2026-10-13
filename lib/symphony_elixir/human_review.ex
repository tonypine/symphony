defmodule SymphonyElixir.HumanReview do
  @moduledoc """
  Where a ticket waits on a person.

  A plan parent's handoff waits in the epic path's `Plan Review` state (`issues.states.plan_review`,
  `plan_review_states/1`), which is a person's to move on. Every other wait on a person is a hold
  that keeps the ticket in its phase (`SymphonyElixir.Hold`): there is no review queue to park a
  ticket in. The retired `In Review` and `Human Review` states only drain
  (`SymphonyElixir.RetiredStates`).

  The `human-action` label that used to say a person must act is retired: a config that still sets
  `human_actions.label`, or lists `human-action` in the `escalate.labels`, loads with a deprecation
  warning, and an issue carrying that label counts as one with an open request
  (`legacy_request_labels/1`).
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.StateMachine

  @merging_state "Merging"
  # Asks for a person whatever the `escalate.labels` say (see `parked_for_person?/2`).
  @needs_human_label "needs-human"
  # The retired label that marked an open human-action request (see `legacy_request_labels/1`).
  @legacy_request_label "human-action"

  @doc """
  The states a plan parent's handoff leaves it waiting for a person in: the configured
  `Plan Review` state, or none when it is turned off in config.
  """
  @spec plan_review_states(Schema.t() | term()) :: [String.t()]
  def plan_review_states(settings), do: settings |> plan_review_state() |> List.wrap()

  @doc "True when `state_name` is one of `plan_review_states/1`."
  @spec plan_review_state?(String.t() | nil, Schema.t() | term()) :: boolean()
  def plan_review_state?(state_name, settings) when is_binary(state_name),
    do: Enum.any?(plan_review_states(settings), &(normalize(&1) == normalize(state_name)))

  def plan_review_state?(_state_name, _settings), do: false

  @doc "`plan_review_state?/2` against the current settings, false when they can't be read."
  @spec plan_review_state?(String.t() | nil) :: boolean()
  def plan_review_state?(state_name) do
    case Config.settings() do
      {:ok, settings} -> plan_review_state?(state_name, settings)
      {:error, _reason} -> false
    end
  end

  @doc "The configured `Plan Review` state; nil when it is turned off in config."
  @spec plan_review_state(Schema.t() | term()) :: String.t() | nil
  def plan_review_state(%Schema{tracker: %{plan_review_state: state}}) when is_binary(state), do: state
  def plan_review_state(_settings), do: nil

  @doc """
  True when an issue waits on a person: it sits outside `tracker.active_states` with a label that
  asks for one (`needs-human`, a `legacy_request_labels/1` label, or an
  `auto_review.acceptance_gate.escalate` label other than `plan` and `breakdown`, which every plan
  carries). Labels and states compare case-insensitively.

  A fix run (CI or merge conflict) can't do what the person must, so the pollers leave such an
  issue where it is until the label goes or it moves to an active state.
  """
  @spec parked_for_person?(Issue.t(), Schema.t()) :: boolean()
  def parked_for_person?(%Issue{state: issue_state, labels: labels}, %Schema{} = settings) do
    wanted = MapSet.new(person_labels(settings), &normalize/1)

    not active_state?(issue_state, settings) and
      Enum.any?(labels || [], &(is_binary(&1) and MapSet.member?(wanted, normalize(&1))))
  end

  @doc """
  `parked_for_person?/2` for the CI and PR review pollers, which also leave an issue where it is
  when it sits outside every state they move issues on from: the machine's active states and
  `Merging`, plus any `:watched_states` a poller adds (`Rework`, say, whose red head routes to the
  CI Fix lane). Such an issue (`Backlog`, a terminal state, a retired review state) waits for a
  person to move it, so a red head or a merge conflict starts no fix run and spends no retry.
  """
  @spec held_for_person?(Issue.t(), Schema.t(), keyword()) :: boolean()
  def held_for_person?(%Issue{state: issue_state} = issue, %Schema{} = settings, opts) do
    not poller_state?(issue_state, settings, opts) or parked_for_person?(issue, settings)
  end

  defp poller_state?(issue_state, settings, opts) when is_binary(issue_state) do
    states = default_poller_states(settings) ++ List.wrap(Keyword.get(opts, :watched_states))
    Enum.any?(states, &(is_binary(&1) and normalize(&1) == normalize(issue_state)))
  end

  defp poller_state?(_issue_state, _settings, _opts), do: false

  # The states an issue is not waiting on a person in, whatever a caller adds: the machine's active
  # states — not `tracker.active_states`, so the phase states (`Code Review`, `QA`) count even
  # though the config lists only the base states — and `Merging`. A retired review state is not
  # one: a ticket left there needs moving by hand (`SymphonyElixir.RetiredStates`).
  defp default_poller_states(settings), do: StateMachine.active_states(settings) ++ [@merging_state]

  @doc """
  The labels that still mark an open human-action request, from a config that predates the hold:
  `human_actions.label` when it is set, and `human-action` when the gate's `escalate.labels` list
  it. Both are deprecated (`SymphonyElixir.Config.SystemSchema` warns when it loads them); an issue
  carrying one counts as an issue with an open request. Lower case.
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
