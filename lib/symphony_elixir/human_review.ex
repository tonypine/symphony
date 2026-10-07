defmodule SymphonyElixir.HumanReview do
  @moduledoc """
  The state an issue waits in when only a person can move it on (`issues.states.human_review`,
  default `Human Review`), apart from the supervisor's `In Review` queue.

  Symphony never dispatches an issue in it, and the CI and PR review pollers watch its PR as they
  do in `In Review`. A person's move out of it counts like one out of `In Review`: to `Merging`,
  `Rework`, the waiting state (a plan approval) or `Done`. Symphony puts an issue there instead of
  `In Review` when the next step needs a person:

  - an Auto Review QA verdict `blocked` that the QA agent says needs a person (a missing secret or
    key, a check on a real device), as opposed to a tooling gap the factory can fix;
  - a parent walkthrough (`Final verification:`) whose remaining steps are manual;
  - a plan whose ticket says a human reviews it (`requested_by_ticket?/2`);
  - an issue whose run posted a `linear_request_human_action` request: the tool moves it there,
    and the request stays open until a person moves the issue out or the agent withdraws it;
  - an acceptance gate escalation only a person can clear (see
    `SymphonyElixir.AcceptanceGate.enforced_target/4`).

  It is the one way to say a person needs to act. The `human-action` label that used to say it is
  retired: a config that still sets `human_actions.label`, or lists `human-action` in the gate's
  `escalate.labels`, loads with a deprecation warning, and an issue carrying that label counts as
  one with an open request (`legacy_request_labels/1`).

  At startup Symphony checks that the Linear team has the state. When it is missing, the state is
  turned off for the life of the process and a warning is logged, so those issues go to
  `In Review` as before. `null` in config turns it off too.
  """

  require Logger

  alias SymphonyElixir.AcceptanceGate.Escalation
  alias SymphonyElixir.AgentTools.Linear, as: AgentLinear
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @review_state "In Review"
  @merging_state "Merging"
  # Asks for a person whatever the acceptance gate's `escalate.labels` say (see `parked_for_person?/2`).
  @needs_human_label "needs-human"
  # The retired label that marked an open human-action request (see `legacy_request_labels/1`).
  @legacy_request_label "human-action"
  # A plan ticket whose author says they review it: "I only want to review and validate the
  # artifacts", "we’ll approve the plan", "I need to sign off on the split". The verb's object must
  # be the plan or what it produces, so "we need to review the current importer" doesn't count.
  @plan_review_patterns [
    ~r/\b(?:i|we)(?:\s+(?:only|just|first))?(?:\s+(?:want|need|would like|wish|have)\s+to|\s+will|['’]ll|\s+must)(?:\s+(?:only|just|first))?\s+(?:review|validate|approve|sign off)(?:\s+and\s+(?:review|validate|approve))?(?:\s+on)?\s+(?:(?:the|this|these|each|every|all(?:\s+the)?)\s+)?(?:plan|artifacts?|breakdown|split|sub-?tickets?|sub-?issues?|it|them|this)\b/iu
  ]

  @doc "The configured state name, or nil when it is turned off in config."
  @spec state(Schema.t() | term()) :: String.t() | nil
  def state(%Schema{tracker: %{human_review_state: state}}) when is_binary(state), do: state
  def state(_settings), do: nil

  @doc "Whether the state is configured and the startup check did not turn it off."
  @spec enabled?(Schema.t() | term()) :: boolean()
  def enabled?(settings) do
    case state(settings) do
      nil -> false
      state -> not :persistent_term.get(disabled_key(state), false)
    end
  end

  @doc "The state an issue that needs a person goes to: the configured state, else `In Review`."
  @spec target_state(Schema.t() | term()) :: String.t()
  def target_state(settings) do
    if enabled?(settings), do: state(settings), else: @review_state
  end

  @doc "The states a person reviews in: `In Review`, and the configured state when set."
  @spec review_states(Schema.t() | term()) :: [String.t()]
  def review_states(settings) do
    case state(settings) do
      nil -> [@review_state]
      state -> [@review_state, state]
    end
  end

  @doc "True when `state_name` is one of `review_states/1`."
  @spec review_state?(String.t() | nil, Schema.t() | term()) :: boolean()
  def review_state?(state_name, settings) when is_binary(state_name),
    do: Enum.any?(review_states(settings), &(normalize(&1) == normalize(state_name)))

  def review_state?(_state_name, _settings), do: false

  @doc "`review_state?/2` against the current settings, with only `In Review` when they can't be read."
  @spec review_state?(String.t() | nil) :: boolean()
  def review_state?(state_name) do
    case Config.settings() do
      {:ok, settings} -> review_state?(state_name, settings)
      {:error, _reason} -> review_state?(state_name, nil)
    end
  end

  @doc "True when `issue` (or a state name) sits in the configured state."
  @spec in_state?(Issue.t() | String.t() | term(), Schema.t() | term()) :: boolean()
  def in_state?(%Issue{state: issue_state}, settings), do: in_state?(issue_state, settings)

  def in_state?(state_name, settings) when is_binary(state_name) do
    case state(settings) do
      nil -> false
      state -> normalize(state_name) == normalize(state)
    end
  end

  def in_state?(_issue, _settings), do: false

  @doc "`in_state?/2` against the current settings, false when they can't be read."
  @spec in_state?(String.t() | nil) :: boolean()
  def in_state?(state_name) do
    case Config.settings() do
      {:ok, settings} -> in_state?(state_name, settings)
      {:error, _reason} -> false
    end
  end

  @doc """
  True when the ticket says a person reviews it: an `auto_review.acceptance_gate.escalate` label
  other than `plan` and `breakdown` (every plan has one), a title or description matching one of its
  `ticket_patterns` ("must not auto-approve", "needs human", "human review"), where naming this
  state doesn't count (`Escalation.ticket_reasons/3`), or a description in which its author says
  they review it ("I only want to review and validate the artifacts").
  """
  @spec requested_by_ticket?(Issue.t(), Schema.t()) :: boolean()
  def requested_by_ticket?(%Issue{} = issue, %Schema{} = settings) do
    rules = settings.auto_review.acceptance_gate.escalate
    rules = %{rules | labels: Enum.reject(rules.labels, &Issue.breakdown_label?/1)}

    Escalation.ticket_reasons(%{issue | labels: issue.labels || []}, rules, human_review_state: state(settings)) != [] or
      author_reviews?(issue)
  end

  defp author_reviews?(%Issue{title: title, description: description}) do
    text = Enum.join([title || "", description || ""], "\n")
    Enum.any?(@plan_review_patterns, &Regex.match?(&1, text))
  end

  @doc """
  True when an issue waits on a person: it sits outside `tracker.active_states` and either in this
  state or with a label that asks for one (`needs-human`, a `legacy_request_labels/1` label, or an
  `auto_review.acceptance_gate.escalate` label other than `plan` and `breakdown`, which every plan
  carries). Labels and states compare case-insensitively.

  A fix run (CI or merge conflict) can't do what the person must, so the pollers leave such an
  issue where it is until it leaves this state, the label goes, or it moves to an active state.
  """
  @spec parked_for_person?(Issue.t(), Schema.t()) :: boolean()
  def parked_for_person?(%Issue{state: issue_state, labels: labels}, %Schema{} = settings) do
    wanted = MapSet.new(person_labels(settings), &normalize/1)

    not active_state?(issue_state, settings) and
      (in_state?(issue_state, settings) or Enum.any?(labels || [], &(is_binary(&1) and MapSet.member?(wanted, normalize(&1)))))
  end

  @doc """
  `parked_for_person?/2`, and, while this state is off (`enabled?/1` false), an issue in
  `In Review` with an open `## Action needed:` request: `linear_request_human_action` moves such an
  issue to `In Review` and adds no label, so only the request says a person must act. The requests
  are read from Linear (`SymphonyElixir.AgentTools.Linear.open_human_action_requests/3`, with the
  `:linear_client` option); `{:error, reason}` when that read fails.
  """
  @spec parked_for_person(Issue.t(), Schema.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def parked_for_person(%Issue{} = issue, %Schema{} = settings, opts) do
    cond do
      parked_for_person?(issue, settings) ->
        {:ok, true}

      request_parks_in_review?(issue, settings) ->
        context = %{issue_id: issue.id}

        with {:ok, requests} <- AgentLinear.open_human_action_requests(context, settings, Keyword.take(opts, [:linear_client])) do
          {:ok, requests != []}
        end

      true ->
        {:ok, false}
    end
  end

  @doc """
  `parked_for_person/3` for the CI and PR review pollers, which also leave an issue where it is
  when it sits outside every state they move issues on from: `tracker.active_states`,
  `review_states/1`, the Auto Review state and `Merging`. Such an issue (`Backlog`, a terminal
  state) waits for a person to promote it, so a red head or a merge conflict starts no fix run and
  spends no retry.
  """
  @spec held_for_person(Issue.t(), Schema.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def held_for_person(%Issue{state: issue_state} = issue, %Schema{} = settings, opts) do
    if poller_state?(issue_state, settings),
      do: parked_for_person(issue, settings, opts),
      else: {:ok, true}
  end

  defp poller_state?(issue_state, settings) when is_binary(issue_state) do
    states = settings.tracker.active_states ++ review_states(settings) ++ [settings.auto_review.state, @merging_state]
    Enum.any?(states, &(is_binary(&1) and normalize(&1) == normalize(issue_state)))
  end

  defp poller_state?(_issue_state, _settings), do: false

  defp request_parks_in_review?(%Issue{state: issue_state}, settings) do
    settings.human_actions.enabled and not enabled?(settings) and is_binary(issue_state) and
      normalize(issue_state) == normalize(@review_state) and not active_state?(issue_state, settings)
  end

  @doc """
  The labels that still mark an open human-action request, from a config that predates this state:
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

  @doc """
  Checks that the given Linear teams have the state. With no teams, any team in the workspace
  having it is enough.

  Returns `:ok` when the state exists, `:disabled` when it is missing (issues that need a person
  then go to `In Review` until restart), `:skipped` when no state is configured, and
  `{:error, reason}` when the tracker could not be asked (the state stays on).
  """
  @spec check_tracker_state(Schema.t(), [String.t()], keyword()) :: :ok | :disabled | :skipped | {:error, term()}
  def check_tracker_state(settings, teams, opts \\ []) do
    case state(settings) do
      nil -> :skipped
      state -> check_tracker_state_exists(state, teams, Keyword.get(opts, :tracker, Tracker))
    end
  end

  defp check_tracker_state_exists(state, teams, tracker) do
    case tracker.workflow_state_exists?(state, teams) do
      {:ok, true} ->
        :persistent_term.erase(disabled_key(state))
        :ok

      {:ok, false} ->
        Logger.warning(
          "Human review state disabled: Linear state #{inspect(state)} is missing#{teams_suffix(teams)}; " <>
            "issues that need a person go to #{@review_state}. Add it as a started state after #{@review_state}, then restart Symphony"
        )

        :persistent_term.put(disabled_key(state), true)
        :disabled

      {:error, reason} ->
        Logger.warning("Could not check the Linear state #{inspect(state)} for human review; leaving it on: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  @spec reset_for_test(String.t()) :: :ok
  def reset_for_test(state) when is_binary(state) do
    :persistent_term.erase(disabled_key(state))
    :ok
  end

  defp normalize(state), do: state |> String.trim() |> String.downcase()

  defp disabled_key(state), do: {__MODULE__, :disabled, state}

  defp teams_suffix([]), do: ""
  defp teams_suffix(teams), do: " for team(s) #{Enum.join(teams, ", ")}"
end
