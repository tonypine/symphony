defmodule SymphonyElixir.RunKind do
  @moduledoc """
  Classifies what kind of agent run Symphony is about to start, so each kind can
  get its own model, effort and provider (`agent.run_profiles.<kind>`).

  Classification is deterministic and uses the signals the orchestrator already
  routes on. The first match wins:

    1. `final_verification`: the title starts with `Final verification:`.
    2. `breakdown`: a `breakdown` parent in `Rework`, whose rejected plan is made again.
    3. `close_out`: a `breakdown` parent whose sub-issues are all terminal.
    4. `breakdown`: any other `breakdown` parent (normally one without sub-issues yet).
    5. `landing`: the issue is in `Merging`.
    6. `rework`: the issue is in `Rework`.
    7. `ci_fix`: the run continues after a red CI run (`:ci_failure` signal).
    8. `review_feedback`: the run continues after PR review comments
       (non-empty `:reviewer_comments` signal).
    9. `implementation`: everything else.

  Parent and final-verification tickets come before states because they never
  open a PR: the workflow sends them to the parent-ticket steps whatever their state.

  `pre_push_review`, `qa` and `acceptance_gate` are never returned by `classify/2`;
  they name the reviewer, QA agent and acceptance gate runs, which Symphony starts
  itself.
  """

  alias SymphonyElixir.Linear.Issue

  @type t ::
          :implementation
          | :breakdown
          | :close_out
          | :final_verification
          | :rework
          | :landing
          | :ci_fix
          | :review_feedback
          | :pre_push_review
          | :qa
          | :acceptance_gate

  @typedoc "The provider that serves a run's model."
  @type provider :: String.t()

  @typedoc "A run kind with the model, effort and provider it resolves to; a nil model or effort adds nothing to the agent command."
  @type profile :: %{kind: t(), model: String.t() | nil, effort: String.t() | nil, provider: provider()}

  @kinds [
    :implementation,
    :breakdown,
    :close_out,
    :final_verification,
    :rework,
    :landing,
    :ci_fix,
    :review_feedback,
    :pre_push_review,
    :qa,
    :acceptance_gate
  ]

  @final_verification_prefix "Final verification:"
  @landing_state "merging"
  @rework_state "rework"
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

  @doc "Every run kind, in documentation order."
  @spec kinds() :: [t()]
  def kinds, do: @kinds

  @doc "Every run kind as the string used for `agent.run_profiles` keys."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@kinds, &Atom.to_string/1)

  @doc """
  A one-line label for a run's profile, as the dashboards show it: `kind · model · effort`.
  A model or effort that resolved to nothing reads `default`. Accepts the in-memory profile
  (`kind`) or a run history record (`run_kind`); returns nil when neither is present.
  """
  @spec label(map() | nil) :: String.t() | nil
  def label(%{} = profile) do
    case Map.get(profile, :kind) || Map.get(profile, :run_kind) do
      nil -> nil
      kind -> Enum.map_join([kind, Map.get(profile, :model), Map.get(profile, :effort)], " · ", &(&1 || "default"))
    end
  end

  def label(nil), do: nil

  @doc """
  Returns the run kind for `issue`.

  Signals:

    * `:terminal_states` - issue states that count as terminal for sub-issues
      (default: the `issues.states.terminal` default).
    * `:ci_failure` - the pending red CI context, or nil.
    * `:reviewer_comments` - the pending PR review comments, or `[]`.
  """
  @spec classify(Issue.t(), keyword()) :: t()
  def classify(%Issue{} = issue, signals \\ []) do
    terminal_states = Keyword.get(signals, :terminal_states, @default_terminal_states)

    cond do
      final_verification?(issue) -> :final_verification
      Issue.breakdown?(issue) -> parent_kind(issue, terminal_states)
      in_state?(issue, @landing_state) -> :landing
      in_state?(issue, @rework_state) -> :rework
      present?(Keyword.get(signals, :ci_failure)) -> :ci_fix
      present?(Keyword.get(signals, :reviewer_comments)) -> :review_feedback
      true -> :implementation
    end
  end

  defp parent_kind(issue, terminal_states) do
    if Issue.close_out_ready?(issue, terminal_states) and not Issue.replanning?(issue), do: :close_out, else: :breakdown
  end

  defp final_verification?(%Issue{title: title}) when is_binary(title) do
    title |> String.trim_leading() |> String.starts_with?(@final_verification_prefix)
  end

  defp final_verification?(_issue), do: false

  defp in_state?(%Issue{state: state}, expected) when is_binary(state) do
    state |> String.trim() |> String.downcase() == expected
  end

  defp in_state?(_issue, _expected), do: false

  defp present?(nil), do: false
  defp present?([]), do: false
  defp present?(_value), do: true
end
