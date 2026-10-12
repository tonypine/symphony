defmodule SymphonyElixir.CiFix do
  @moduledoc """
  The CI Fix lane: the mechanical repair a red head or a merge conflict routes to.

  Every phase carries a CI attribute (`SymphonyElixir.CiState`). When a head goes red — or a PR
  conflicts with its base branch — while the ticket sits in `Code Review`, `QA`, `Merging` or
  `Rework`, a designed repo enters this lane instead of the legacy red → `In Progress` fix loop and
  conflict → `Rework` heuristic. The two pollers detect it
  (`SymphonyElixir.CiPoller`, `SymphonyElixir.PrReviewPoller`), call `entry/2` to pick the edge for
  the state the ticket is in, and call `record_origin/4` before performing that edge through
  `SymphonyElixir.TransitionGuard`. The origin is recorded on the ticket
  (`SymphonyElixir.TicketState`), which is what lets the repair return where it came from.

  The repair run itself is an ordinary executor run, constrained by the repo's `ci_fix` run profile
  and the designed playbook to minimal work: formatting, a flaky rerun, a dependency bump, a
  conflict resolution — no behavior change. `SymphonyElixir.AgentRunner` reads `origin/3` back and
  returns the ticket with `:ci_fix_mechanical`, releasing the auto-merge hold when the origin is
  `Merging`, so the approval an earlier verdict earned still covers the PR.

  A verdict binds to the head it judged and this lane never invalidates one: only `Rework` does. A
  repair that pushed a new commit re-binds the verdict it carries to that head (`carry_verdict/5`),
  so the approval stays valid on the head the ticket now has, and a phase that already holds a valid
  verdict carries the ticket on without a second review (`SymphonyElixir.CodeReview`,
  `SymphonyElixir.QaVerification`). A repair the fixing agent judges substantive is the agent's own
  move to `Rework`; one it cannot make without access or a secret is a Needs Decision hold. Both are
  recorded here as a `fix verdict`.

  Everything here is designed-only. A repo on the `legacy` machine keeps its red → `In Progress`
  loop and its conflict → `Rework` heuristic exactly: `entry/2` answers `:none`, so the pollers fall
  back to the edges they always used.
  """

  alias SymphonyElixir.{
    CodeReview,
    Config,
    QaVerification,
    RunStore,
    StateMachine,
    TicketSignals,
    TicketState,
    TransitionGuard
  }

  alias SymphonyElixir.Linear.Issue

  @default_state "CI Fix"
  @merging_state "Merging"
  @rework_state "Rework"
  @verdict_kind "fix verdict"

  @typedoc "The phase whose CI attribute routed the ticket here."
  @type origin :: String.t()

  @doc "The configured name of the CI Fix state."
  @spec state(map() | nil) :: String.t()
  def state(settings) when is_map(settings) do
    case Map.get(settings, :tracker) do
      tracker when is_map(tracker) -> present(Map.get(tracker, :ci_fix_state)) || @default_state
      _none -> @default_state
    end
  end

  def state(_settings), do: @default_state

  @doc "Whether the repo runs the designed machine, and so has a CI Fix lane at all."
  @spec designed?(map() | nil) :: boolean()
  def designed?(settings), do: StateMachine.designed?(settings)

  @doc """
  Whether `issue` (or the state name itself) is a designed repo's CI Fix ticket. Every other ticket
  — including one on a legacy repo whose workflow happens to name a state the same way — is not.
  """
  @spec in_state?(Issue.t() | String.t() | nil, map() | nil) :: boolean()
  def in_state?(%Issue{state: state}, settings), do: in_state?(state, settings)

  def in_state?(state, settings) when is_binary(state),
    do: designed?(settings) and matches?(state, state(settings))

  def in_state?(_state, _settings), do: false

  @doc """
  The edge that enters the lane from `origin_state`, with the origin to record on the ticket (the
  phase's *configured* name, so a repo that renames `Code Review` or `QA` still returns there).

  `:none` for every state the lane is not entered from — including `In Progress`, whose red heads
  keep the legacy edge — and for every legacy repo.
  """
  @spec entry(String.t() | nil, map() | nil) :: {:ok, TransitionGuard.signal(), origin()} | :none
  def entry(origin_state, settings) when is_binary(origin_state) do
    if designed?(settings), do: do_entry(origin_state, settings), else: :none
  end

  def entry(_origin_state, _settings), do: :none

  defp do_entry(origin_state, settings) do
    tracker = Map.get(settings, :tracker) || %{}

    cond do
      matches?(origin_state, Map.get(tracker, :code_review_state)) ->
        {:ok, :ci_fix_enter_code_review, Map.get(tracker, :code_review_state)}

      matches?(origin_state, Map.get(tracker, :qa_state)) ->
        {:ok, :ci_fix_enter_qa, Map.get(tracker, :qa_state)}

      matches?(origin_state, @merging_state) ->
        {:ok, :ci_fix_enter_merging, @merging_state}

      matches?(origin_state, @rework_state) ->
        {:ok, :ci_fix_enter_rework, @rework_state}

      true ->
        :none
    end
  end

  @doc """
  Records `origin` as the phase the ticket's CI Fix stay came from. Returns an error rather than
  swallowing it: the return depends on the origin, so a caller that cannot record it does not move
  the ticket into the lane and retries on its next pass. A `nil` origin clears it, once the repair
  has returned the ticket.
  """
  @spec record_origin(String.t() | nil, String.t() | nil, origin() | nil, keyword()) ::
          :ok | {:error, term()}
  def record_origin(repo_key, issue_id, origin, opts \\ []) do
    store(opts).set_ci_fix_origin(resolved_repo_key(repo_key), issue_id, origin)
  end

  @doc "The phase the ticket's current CI Fix stay came from, or nil when none is recorded."
  @spec origin(String.t() | nil, String.t() | nil, keyword()) :: origin() | nil
  def origin(repo_key, issue_id, opts \\ []) do
    case store(opts).get_ticket_state(resolved_repo_key(repo_key), issue_id) do
      %{} = record -> TicketState.ci_fix_origin(record)
      _none_or_error -> nil
    end
  end

  @doc """
  The `fix verdict` a move out of the lane means, for the move's caller to record: `substantive`
  when a CI Fix ticket is sent to `Rework` — the repair needs a real change, so the ticket re-enters
  review instead of returning to its origin — and `nil` for every other move, so nothing is recorded.
  The move itself is the agent's ordinary state request; only the verdict is the lane's business.
  """
  @spec verdict_for_move(String.t() | nil, String.t() | nil, map() | nil) :: String.t() | nil
  def verdict_for_move(from_state, to_state, settings) do
    if in_state?(from_state, settings) and matches?(to_state, @rework_state), do: "substantive"
  end

  @doc """
  The `fix verdict` a Needs Decision hold set on `state` means, for the hold's caller to record:
  `cannot_fix` when the ticket asking for a person is in the CI Fix state — the repair needs access
  or a secret, which no run can supply — and `nil` for every other ticket.
  """
  @spec hold_verdict(String.t() | nil, map() | nil) :: String.t() | nil
  def hold_verdict(state, settings) do
    if in_state?(state, settings), do: "cannot_fix"
  end

  @doc "The ledger signal name a fix verdict is recorded under."
  @spec verdict_kind() :: String.t()
  def verdict_kind, do: @verdict_kind

  @doc """
  Re-binds the origin phase's carrying verdict to `head`, so a mechanical repair that pushed a new
  commit leaves the approval valid on the head the ticket now has — the verdict's head binding is
  preserved, not invalidated (`SymphonyElixir.CodeReview.carry_verdict/3`,
  `SymphonyElixir.QaVerification.carry_verdict/3`). Only `Code Review` and `QA` hold verdicts: a
  return to `Merging` carries its approval through auto-merge instead, and a return to `Rework`
  invalidates nothing because `Rework` has no verdict.

  Best-effort, like every ledger write, and a no-op for a phase with no carrying verdict or for a
  legacy repo.
  """
  @spec carry_verdict(String.t() | nil, String.t() | nil, origin() | nil, String.t() | nil, map() | nil) :: :ok
  def carry_verdict(repo_key, issue_id, origin, head, settings) do
    repo_key = resolved_repo_key(repo_key)
    tracker = Map.get(settings, :tracker) || %{}

    cond do
      matches?(origin, Map.get(tracker, :code_review_state)) -> CodeReview.carry_verdict(repo_key, issue_id, head)
      matches?(origin, Map.get(tracker, :qa_state)) -> QaVerification.carry_verdict(repo_key, issue_id, head)
      true -> :ok
    end
  end

  @doc """
  Records a `fix verdict` in the ticket's signals ledger: what the repair turned out to be
  (`mechanical`, `substantive`, `cannot_fix`). Best-effort, like every other ledger write.
  """
  @spec record_verdict(String.t() | nil, String.t() | nil, String.t(), map()) :: :ok
  def record_verdict(repo_key, issue_id, outcome, details \\ %{}) do
    TicketSignals.record(repo_key, issue_id, @verdict_kind, Map.new(details) |> Map.put(:outcome, outcome))
  end

  defp store(opts), do: Keyword.get(opts, :run_store, RunStore)

  defp resolved_repo_key(repo_key) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp resolved_repo_key(_repo_key), do: Config.repo_key_or_nil()

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp matches?(name, expected) when is_binary(name) and is_binary(expected),
    do: String.downcase(String.trim(name)) == String.downcase(String.trim(expected))

  defp matches?(_name, _expected), do: false
end
