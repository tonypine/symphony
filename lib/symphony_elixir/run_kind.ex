defmodule SymphonyElixir.RunKind do
  # The kinds `classify/2` never returns: they name the pre-push reviewer run, which Symphony
  # starts itself. The moduledoc interpolates these names, so the documented set cannot drift from
  # the code.
  @reserved_kinds [:pre_push_review]
  @reserved_kind_names Enum.map_join(@reserved_kinds, " and ", fn kind -> "`" <> Atom.to_string(kind) <> "`" end)

  @moduledoc """
  Classifies what kind of agent run Symphony is about to start, so each kind can
  get its own model, effort and provider (`agent.run_profiles.<kind>`).

  Classification is deterministic and uses the signals the orchestrator already
  routes on. The first match wins:

    1. `breakdown`: a `breakdown` parent in `Rework`, whose rejected plan is made again.
    2. `close_out`: a legacy repo's `breakdown` parent whose sub-issues are all terminal.
    3. `epic_review`: a designed repo's `breakdown` parent whose sub-issues are all terminal:
       the epic path's close, which Symphony starts from `Waiting on sub-tickets`.
    4. `breakdown`: any other `breakdown` parent: one without sub-issues yet, one whose
       never-approved plan stopped midway, or one revising its plan from review comments.
    5. `landing`: the issue is in `Merging`.
    6. `rework`: the issue is in `Rework`.
    7. `code_review`: the issue is in the designed machine's configured `code_review_state`:
       the poll-dispatched reviewer run, which judges the PR head and records a verdict. Only a
       repo on the designed machine reaches this: a legacy repo whose Linear workflow happens
       to have a `Code Review` column keeps classifying its runs as it did before.
    8. `qa`: the issue is in the designed machine's configured `qa_state`: the poll-dispatched
       QA run, which exercises the change from the user's point of view and records a verdict.
       Designed-only, like `code_review`.
    9. `epic_review`: the issue is in the designed machine's configured `epic_review_state`:
       the poll-dispatched epic review, which the tick starts again if the run that moved the
       parent there stopped. Designed-only, like the phases above.
    10. `ci_fix`: the issue is in the designed machine's configured `ci_fix_state` (the mechanical
       repair lane a red head or a conflict routes to), or the run continues after a red CI run
       (`:ci_failure` signal).
    11. `review_feedback`: the run continues after PR review comments
       (non-empty `:reviewer_comments` signal).
    12. `implementation`: everything else.

  A ticket's title never names its run kind: `Final verification:` tickets are retired, and the
  epic review closes an epic parent instead.

  Parent tickets come before states because they never open a PR: the workflow sends them to
  the parent-ticket steps whatever their state.

  #{@reserved_kind_names} is never returned by `classify/2`; it names the pre-push reviewer run,
  which Symphony starts itself. The designed machine's configured
  `code_review_state`, `qa_state`, `epic_review_state` and `ci_fix_state` *are* returned, as
  `code_review`, `qa`, `epic_review` and `ci_fix`.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.StateMachine

  @type t ::
          :implementation
          | :breakdown
          | :close_out
          | :rework
          | :landing
          | :code_review
          | :epic_review
          | :ci_fix
          | :review_feedback
          | :pre_push_review
          | :qa

  @typedoc "The provider that serves a run's model."
  @type provider :: String.t()

  @typedoc "A run kind with the model, effort and provider it resolves to; a nil model or effort adds nothing to the agent command."
  @type profile :: %{kind: t(), model: String.t() | nil, effort: String.t() | nil, provider: provider()}

  @kinds [
    :implementation,
    :breakdown,
    :close_out,
    :rework,
    :landing,
    :code_review,
    :epic_review,
    :ci_fix,
    :review_feedback,
    :pre_push_review,
    :qa
  ]

  @landing_state "merging"
  @rework_state "rework"
  @code_review_state "code review"
  @qa_state "qa"
  @epic_review_state "epic review"
  @ci_fix_state "ci fix"
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

  @doc "Every run kind, in documentation order."
  @spec kinds() :: [t()]
  def kinds, do: @kinds

  @doc """
  The kinds `classify/2` never returns; Symphony starts those runs itself. The moduledoc's
  list of never-returned kinds is built from this list.
  """
  @spec reserved_kinds() :: [t()]
  def reserved_kinds, do: @reserved_kinds

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
    * `:settings` - the repo's settings, used to tell a designed repo's configured phase states
      and its epic path from a legacy workflow that happens to name a state the same way.
  """
  @spec classify(Issue.t(), keyword()) :: t()
  def classify(%Issue{} = issue, signals \\ []) do
    terminal_states = Keyword.get(signals, :terminal_states, @default_terminal_states)
    settings = Keyword.get(signals, :settings)

    cond do
      Issue.breakdown?(issue) -> parent_kind(issue, terminal_states, settings)
      in_state?(issue, @landing_state) -> :landing
      in_state?(issue, @rework_state) -> :rework
      (kind = designed_phase_kind(issue, settings)) != nil -> kind
      present?(Keyword.get(signals, :ci_failure)) -> :ci_fix
      present?(Keyword.get(signals, :reviewer_comments)) -> :review_feedback
      true -> :implementation
    end
  end

  # A designed repo closes an epic parent by reviewing the epic, not by a close-out run: the parent's
  # epic review is started from `Waiting on sub-tickets` once every sub-issue is terminal
  # (`SymphonyElixir.EpicReview`). A legacy repo keeps the close-out run exactly as it was.
  defp parent_kind(%Issue{} = issue, terminal_states, settings) do
    cond do
      not Issue.close_out_ready?(issue, terminal_states) -> :breakdown
      Issue.replanning?(issue) -> :breakdown
      StateMachine.designed?(settings) -> :epic_review
      true -> :close_out
    end
  end

  # A designed repo's verdict phases classify to their own run kinds: the repo's configured
  # `code_review_state` is the poll-dispatched reviewer run, its configured `qa_state` the
  # poll-dispatched QA run, its configured `epic_review_state` the poll-dispatched epic review, and
  # its configured `ci_fix_state` the mechanical repair lane a red head or a conflict routes to. The
  # configured name is what the rest of the designed flow routes on (`QaVerification.qa_run?/2`,
  # `EpicReview.epic_review_run?/2`, the transition guard), so a repo that renames a phase state
  # still classifies its runs correctly. All four are designed-only — a legacy repo whose workflow
  # happens to name a state the same way keeps the run kind it had before — so a repo without the
  # phases is not any of them.
  defp designed_phase_kind(issue, settings) do
    if StateMachine.designed?(settings) do
      cond do
        in_state?(issue, phase_state(settings, :code_review_state, @code_review_state)) -> :code_review
        in_state?(issue, phase_state(settings, :qa_state, @qa_state)) -> :qa
        in_state?(issue, phase_state(settings, :epic_review_state, @epic_review_state)) -> :epic_review
        in_state?(issue, phase_state(settings, :ci_fix_state, @ci_fix_state)) -> :ci_fix
        true -> nil
      end
    end
  end

  # The phase state's configured name, falling back to the machine default when settings does not
  # carry it (a caller that only needs the state-machine version, as some tests pass).
  defp phase_state(settings, field, default) do
    case Map.get(settings, :tracker) do
      tracker when is_map(tracker) -> Map.get(tracker, field) || default
      _none -> default
    end
  end

  defp in_state?(%Issue{state: state}, expected) when is_binary(state) and is_binary(expected) do
    normalize_state(state) == normalize_state(expected)
  end

  defp in_state?(_issue, _expected), do: false

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()

  defp present?(nil), do: false
  defp present?([]), do: false
  defp present?(_value), do: true
end
