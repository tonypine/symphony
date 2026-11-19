defmodule SymphonyElixir.RunKind do
  @moduledoc """
  Classifies what kind of agent run Symphony is about to start, so each kind can
  start with its own harness, provider, model and effort (`runs.<kind>`, `SymphonyElixir.Config.Runs`).

  Classification is deterministic and uses the signals the orchestrator already
  routes on. The first match wins:

    1. `breakdown`: a `breakdown` parent in `Rework`, whose rejected plan is made again.
    2. `epic_review`: a `breakdown` parent whose sub-issues are all terminal: the epic path's
       close, which Symphony starts from `Waiting on sub-tickets`.
    3. `breakdown`: any other `breakdown` parent: one without sub-issues yet, one whose
       never-approved plan stopped midway, or one revising its plan from review comments.
    4. `landing`: the issue is in `Merging`.
    5. `rework`: the issue is in `Rework`.
    6. `code_review`: the issue is in the configured `code_review_state`: the poll-dispatched
       reviewer run, which judges the PR head and records a verdict.
    7. `qa`: the issue is in the configured `qa_state`: the poll-dispatched QA run, which
       exercises the change from the user's point of view and records a verdict.
    8. `epic_review`: the issue is in the configured `epic_review_state`: the poll-dispatched epic
       review, which the tick starts again if the run that moved the parent there stopped.
    9. `ci_fix`: the issue is in the configured `ci_fix_state` (the mechanical repair lane a red
       head or a conflict routes to), or the run continues after a red CI run (`:ci_failure`
       signal).
    10. `review_feedback`: the run continues after PR review comments
       (non-empty `:reviewer_comments` signal).
    11. `implementation`: everything else.

  `conductor` is never classified: it is the short turn Symphony itself runs at fixed junctions of a
  ticket's life (`SymphonyElixir.Conductor`), before the next run starts. It is a run kind so
  `runs.conductor` picks its harness, provider, model and effort; it takes no step list
  (`phase_kinds/0` leaves it out).

  A ticket's title never names its run kind: `Final verification:` tickets are retired, and the
  epic review closes an epic parent instead.

  Parent tickets come before states because they never open a PR: the workflow sends them to the
  parent-ticket steps whatever their state.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.SubIssueWait

  @type t ::
          :implementation
          | :breakdown
          | :rework
          | :landing
          | :code_review
          | :epic_review
          | :ci_fix
          | :review_feedback
          | :qa
          | :conductor

  @kinds [
    :implementation,
    :breakdown,
    :rework,
    :landing,
    :code_review,
    :epic_review,
    :ci_fix,
    :review_feedback,
    :qa,
    :conductor
  ]

  # The kinds no dispatch classifies to, which take no step list.
  @stepless_kinds [:conductor]

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

  @doc "Every run kind as the string used for `runs:` entries."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@kinds, &Atom.to_string/1)

  @doc "The run kinds a dispatch classifies to, each of which takes a step list under `phases`: every kind but `conductor`."
  @spec phase_kinds() :: [t()]
  def phase_kinds, do: @kinds -- @stepless_kinds

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
    * `:settings` - the repo's settings, whose configured phase state names the issue's state is
      matched against (the machine defaults when absent).
  """
  @spec classify(Issue.t(), keyword()) :: t()
  def classify(%Issue{} = issue, signals \\ []) do
    terminal_states = Keyword.get(signals, :terminal_states, @default_terminal_states)
    settings = Keyword.get(signals, :settings)

    cond do
      Issue.breakdown?(issue) -> parent_kind(issue, terminal_states, settings)
      in_state?(issue, @landing_state) -> :landing
      in_state?(issue, @rework_state) -> :rework
      (kind = phase_kind(issue, settings)) != nil -> kind
      present?(Keyword.get(signals, :ci_failure)) -> :ci_fix
      present?(Keyword.get(signals, :reviewer_comments)) -> :review_feedback
      true -> :implementation
    end
  end

  # An epic parent is closed by reviewing the epic: the parent's epic review is started from
  # `Waiting on sub-tickets` once every sub-issue is terminal, or none is left
  # (`SymphonyElixir.EpicReview`).
  defp parent_kind(%Issue{} = issue, terminal_states, settings) do
    if SubIssueWait.close_out_ready?(issue, terminal_states, settings) and not Issue.replanning?(issue),
      do: :epic_review,
      else: :breakdown
  end

  # The verdict phases classify to their own run kinds: the configured `code_review_state` is the
  # poll-dispatched reviewer run, the configured `qa_state` the poll-dispatched QA run, the
  # configured `epic_review_state` the poll-dispatched epic review, and the configured
  # `ci_fix_state` the mechanical repair lane a red head or a conflict routes to. The configured
  # name is what the rest of the flow routes on (`QaVerification.qa_run?/2`,
  # `EpicReview.epic_review_run?/2`, the transition guard), so a repo that renames a phase state
  # still classifies its runs correctly.
  defp phase_kind(issue, settings) do
    cond do
      in_state?(issue, phase_state(settings, :code_review_state, @code_review_state)) -> :code_review
      in_state?(issue, phase_state(settings, :qa_state, @qa_state)) -> :qa
      in_state?(issue, phase_state(settings, :epic_review_state, @epic_review_state)) -> :epic_review
      in_state?(issue, phase_state(settings, :ci_fix_state, @ci_fix_state)) -> :ci_fix
      true -> nil
    end
  end

  # The phase state's configured name, falling back to the machine default when settings does not
  # carry it.
  defp phase_state(settings, field, default) do
    case settings && Map.get(settings, :tracker) do
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
