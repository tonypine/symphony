defmodule SymphonyElixir.CodeReview do
  @moduledoc """
  The `Code Review` state's reviewer run.

  A designed repo's `Code Review` ticket is dispatched by the poll loop like any other active
  ticket; this module turns that dispatch into a review instead of an executor run. It reuses the
  pre-push reviewer's machinery (`SymphonyElixir.ReviewAgent`), so a Code Review verdict is
  grounded in the same read-only, diff-based judgment the pre-push reviewer already makes.

  The run is only ever started on a green head (the orchestrator gates dispatch on the ticket's
  recorded CI state). Its verdict is recorded bound to the head SHA it judged, then performed
  through the one writer, `SymphonyElixir.TransitionGuard`:

    * `approve` -> `QA`, or straight to `Merging` when the QA state's skip rule applies
    * `request_changes` -> `Rework`
    * `block` -> the escalation state, through the request machinery

  An approve carries the QA run/skip decision: `SymphonyElixir.QaPolicy` decides it deterministically
  from the changed paths (docs-only/internal-only diffs skip QA), the decision and its reason are
  recorded in the verdict's signal, and the guard row it picks does the move — `:code_review_approve`
  into the configured QA state, `:code_review_approve_skip` into `Merging`.

  An inconclusive review retries boundedly on the same head, then escalates the same way. A legacy
  repo never reaches this module: `run/3` returns `:skip` for anything but a designed repo's
  `Code Review` ticket, so the executor path is untouched.

  A repo with the reviewer turned off (`review_agent.enabled: false`) has no reviewer to run, and
  `SymphonyElixir.ReviewAgent` answers a disabled reviewer with a fabricated approval. A Code Review
  ticket is never approved on that: dispatch is gated on the setting (the orchestrator parks the
  ticket with a `code_review_reviewer_disabled` signal recorded), and `run/3` itself refuses to
  review without a reviewer, recording the same signal and leaving the ticket where it is.
  """

  require Logger

  alias SymphonyElixir.{
    Config,
    Handoff,
    QaPolicy,
    ReviewAgent,
    StateMachine,
    TicketSignals,
    TransitionGuard,
    WorkspaceHead
  }

  alias SymphonyElixir.Linear.Issue

  @verdict_kind "code_review"
  @reviewer_disabled_signal "code_review_reviewer_disabled"
  @max_inconclusive_retries 2

  @doc """
  Runs the reviewer for `issue` when it is a designed repo's `Code Review` ticket, else `:skip` so
  the caller falls through to the executor run. `opts[:review_agent]` and `opts[:tracker]` override
  the reviewer and the tracker (tests, a fake).
  """
  @spec run(Issue.t(), Path.t(), keyword()) :: :skip | :ok | {:error, term()}
  def run(%Issue{} = issue, workspace, opts) when is_binary(workspace) do
    settings = Keyword.fetch!(opts, :settings)

    if reviewer_run?(issue, settings) do
      review(issue, workspace, opts, settings)
    else
      :skip
    end
  end

  def run(_issue, _workspace, _opts), do: :skip

  @doc """
  Whether `issue` is the ticket this module reviews: a designed repo's configured Code Review
  state. Every other ticket belongs to the executor run.
  """
  @spec reviewer_run?(Issue.t(), map()) :: boolean()
  def reviewer_run?(%Issue{state: state}, settings) when is_binary(state) do
    StateMachine.designed?(settings) and
      normalize_state(state) == normalize_state(settings.tracker.code_review_state)
  end

  def reviewer_run?(_issue, _settings), do: false

  @doc """
  Re-binds this module's carrying verdict — an `approve` — to `head`, so a mechanical CI Fix that
  pushed a new commit leaves the approval valid on the head the ticket now has instead of
  invalidating it (`SymphonyElixir.CiFix`). The ticket's newest `code_review` verdict must be the
  approve: a newer `request_changes` or block is the verdict, and nothing is carried.

  Best-effort, like every ledger write, and a no-op when the approve already binds to `head` or
  there is no head to bind it to.
  """
  @spec carry_verdict(String.t() | nil, String.t() | nil, String.t() | nil) :: :ok
  def carry_verdict(repo_key, issue_id, head) do
    case latest_verdict(repo_key, issue_id) do
      %{outcome: "approve", head_sha: judged} when is_binary(head) and judged != head ->
        TicketSignals.record_verdict(repo_key, issue_id, @verdict_kind, head, "approve")
        :ok

      _no_carry ->
        :ok
    end
  end

  defp review(issue, workspace, opts, settings) do
    case carried_approval(issue, workspace, opts) do
      {:ok, head} ->
        carry(issue, workspace, opts, settings, head)

      :none ->
        if ReviewAgent.enabled?(settings.review_agent) do
          do_review(issue, workspace, opts, settings)
        else
          park(issue, opts)
        end
    end
  end

  # An approve already valid on this head is the ticket's verdict, so no second review runs. That is
  # how a mechanical CI Fix's return is carried forward: the lane re-binds the approval it carries to
  # whatever head the repair left (`SymphonyElixir.CiFix.carry_verdict/5`), and this module applies it
  # again instead of dispatching the reviewer. An unreadable head carries nothing, so the ordinary
  # review runs.
  defp carried_approval(issue, workspace, opts) do
    head = workspace_head(workspace, opts)

    case verdict_for_head(repo_key(issue, opts), issue.id, head) do
      %{outcome: "approve"} -> {:ok, head}
      _none -> :none
    end
  end

  defp carry(issue, workspace, opts, settings, head) do
    Logger.info("Code Review carried the earlier approve for #{issue_label(issue)} head=#{head}; not reviewing again")

    approve(issue, workspace, opts, settings, %{carried: true})
  end

  defp do_review(issue, workspace, opts, settings) do
    case evaluate(issue, workspace, opts, settings) do
      {:ok, %{verdict: verdict} = result} ->
        apply_verdict(issue, workspace, opts, settings, verdict, result)

      {:error, {:review_agent_inconclusive, reason}} ->
        inconclusive(issue, workspace, opts, settings, reason)

      {:error, {:review_agent_blocked, payload}} ->
        blocked(issue, workspace, opts, settings, payload)

      {:error, reason} ->
        {:error, {:code_review_failed, reason}}
    end
  end

  # A reviewer that is turned off judges nothing: `ReviewAgent.evaluate/4` answers it with a
  # fabricated approval, so running one would record a verdict no reviewer made and move the ticket
  # on. The run leaves the ticket exactly where it is and records why, once. Dispatch is gated on the
  # same setting (the orchestrator parks the ticket), so this is the belt to that gate: no path
  # through this module can approve a ticket without a real review.
  defp park(issue, opts) do
    unless reviewer_disabled_recorded?(issue, opts) do
      TicketSignals.record(repo_key(issue, opts), issue.id, @reviewer_disabled_signal, %{})
    end

    Logger.warning("Not reviewing #{issue_label(issue)}: review_agent.enabled is false for its repo")

    :ok
  end

  defp reviewer_disabled_recorded?(issue, opts) do
    repo_key(issue, opts)
    |> Handoff.signals(issue.id)
    |> Enum.any?(&(&1.name == @reviewer_disabled_signal))
  end

  # The same read-only reviewer the pre-push pass uses, pointed at the PR head this run is checked
  # out on. The base branch comes from the repo's config, exactly as the pre-push pass resolves it.
  defp evaluate(issue, workspace, opts, settings) do
    review_opts =
      opts
      |> Keyword.take([:repo_key, :run_id, :reviewer_run_profile, :linear_comment_registry, :agent_tmp_dir])
      |> Keyword.put(:worker_host, Keyword.get(opts, :worker_host))
      |> maybe_put_base_branch(opts)

    Keyword.get(opts, :review_agent, ReviewAgent).evaluate(issue, workspace, settings, review_opts)
  end

  defp maybe_put_base_branch(review_opts, opts) do
    case base_branch(Keyword.get(opts, :repo_key)) do
      nil -> review_opts
      base_branch -> Keyword.put(review_opts, :base_branch, base_branch)
    end
  end

  defp base_branch(repo_key) do
    case Config.repo_base_branch(repo_key) do
      {:ok, base_branch} -> base_branch
      {:error, _reason} -> nil
    end
  end

  defp apply_verdict(issue, workspace, opts, settings, verdict, result) do
    head = workspace_head(workspace, opts)
    record_verdict(issue, opts, head, to_string(verdict))
    Logger.info("Code Review verdict for #{issue_label(issue)} head=#{head || "unknown"} verdict=#{inspect(verdict)}")

    case verdict do
      :approve -> approve(issue, workspace, opts, settings)
      :request_changes -> move(issue, opts, settings, :code_review_rework, %{})
      # The real reviewer exits a block through `blocked/5` (an error result), never this clause; an
      # overridden reviewer that returns a `:block` verdict map escalates the same way.
      :block -> escalate(issue, opts, settings, verdict_reason(result))
      other -> {:error, {:code_review_unknown_verdict, other}}
    end
  end

  # An approve carries the QA run/skip decision. The deterministic rule (docs-only/internal-only
  # diffs) skips QA and lands the ticket in `Merging`; everything else hands it to the QA state. The
  # decision and its reason are recorded with the verdict, so a skip is auditable wherever the
  # verdict is read. `extra` marks a verdict carried forward from an earlier review, which is
  # recorded so the audit trail shows no reviewer ran a second time.
  defp approve(issue, workspace, opts, settings, extra \\ %{}) do
    policy = Keyword.get(opts, :qa_policy, QaPolicy)

    case policy.decide(issue, settings, workspace: workspace, repo_key: repo_key(issue, opts)) do
      {:run, _playbooks, reason} ->
        Logger.info("Code Review approved #{issue_label(issue)}; QA runs: #{reason}")
        move(issue, opts, settings, :code_review_approve, Map.merge(%{qa_decision: "run", reason: reason}, extra))

      {:skip, reason} ->
        Logger.info("Code Review approved #{issue_label(issue)}; QA skipped: #{reason}")
        move(issue, opts, settings, :code_review_approve_skip, Map.merge(%{qa_decision: "skip", reason: reason}, extra))
    end
  end

  # An inconclusive review is not a verdict: the reviewer could not ground one on the head. It
  # retries boundedly on the same head, and escalates to a person once it has run out of attempts.
  defp inconclusive(issue, workspace, opts, settings, reason) do
    head = workspace_head(workspace, opts)
    retries = inconclusive_retries(issue, opts, head)

    if retries < @max_inconclusive_retries do
      record_verdict(issue, opts, head, "inconclusive")

      Logger.warning("Code Review for #{issue_label(issue)} head=#{head || "unknown"} was inconclusive (attempt #{retries + 1}/#{@max_inconclusive_retries}); retrying")

      {:error, {:code_review_inconclusive, reason}}
    else
      record_verdict(issue, opts, head, "inconclusive_escalated")
      escalate(issue, opts, settings, "inconclusive after #{retries} retries: #{inspect(reason)}")
    end
  end

  # `ReviewAgent`'s own block exit: it returns `{:error, {:review_agent_blocked, payload}}` rather
  # than a `{:ok, %{verdict: :block}}` map, so a real block never reaches `apply_verdict/6`'s
  # `:block` clause. It records the verdict against the judged head and escalates exactly the same
  # way, through the escalation edge.
  defp blocked(issue, workspace, opts, settings, payload) do
    head = workspace_head(workspace, opts)
    record_verdict(issue, opts, head, "block")
    Logger.warning("Code Review blocked for #{issue_label(issue)} head=#{head || "unknown"} verdict=block")

    escalate(issue, opts, settings, verdict_reason(payload))
  end

  defp inconclusive_retries(issue, opts, head) do
    issue
    |> verdicts(opts)
    |> Enum.count(&(&1.head_sha == head and &1.outcome == "inconclusive"))
  end

  defp escalate(issue, opts, settings, reason) do
    Logger.warning("Escalating Code Review for #{issue_label(issue)} to a person: #{reason}")

    move(issue, opts, settings, :code_review_escalate, %{
      target: escalation_state(settings),
      reason: reason
    })
  end

  defp escalation_state(settings), do: settings.ci.escalation_state

  # Every move goes through the one writer. `run/3` only ever gets here for a ticket already in the
  # configured Code Review state (`reviewer_run?/2`), which is the origin of each of these edges in
  # the designed table; the table itself is what defines them, and is tested directly.
  defp move(issue, opts, settings, signal, extra) do
    ctx = Map.merge(%{settings: settings}, extra)
    target = TransitionGuard.target(signal, ctx)

    case TransitionGuard.perform(issue.id, signal, ctx, tracker_opts(opts)) do
      :ok ->
        record_move_signal(issue, opts, signal, Map.put(extra, :target, target))
        :ok

      {:error, reason} ->
        {:error, {:code_review_move_failed, signal, reason}}
    end
  end

  defp tracker_opts(opts) do
    case Keyword.get(opts, :tracker) do
      nil -> []
      tracker -> [tracker: tracker]
    end
  end

  defp record_verdict(issue, opts, head, outcome) do
    TicketSignals.record_verdict(repo_key(issue, opts), issue.id, @verdict_kind, head, outcome)
  end

  defp record_move_signal(issue, opts, signal, extra) do
    details =
      extra
      |> Map.take([:target, :reason, :qa_decision, :carried])
      |> Map.put(:signal, to_string(signal))

    TicketSignals.record(repo_key(issue, opts), issue.id, @verdict_kind, details)
  end

  # The ticket's newest `code_review` verdict, whatever head it judged: `carry_verdict/3` reads it to
  # re-bind a carrying approve, and requires it to be the approve — a newer request-changes or block
  # is the verdict and nothing is carried.
  defp latest_verdict(repo_key, issue_id), do: List.first(Handoff.verdicts(repo_key, issue_id, @verdict_kind))

  # The newest verdict bound to `head`, or nil. An unreadable head (`nil`) matches nothing: a verdict
  # then binds to no commit rather than to the wrong one.
  defp verdict_for_head(_repo_key, _issue_id, nil), do: nil

  defp verdict_for_head(repo_key, issue_id, head) do
    repo_key
    |> Handoff.verdicts(issue_id, @verdict_kind)
    |> Enum.find(&(&1.head_sha == head))
  end

  defp verdicts(issue, opts), do: Handoff.verdicts(repo_key(issue, opts), issue.id, @verdict_kind)

  defp repo_key(issue, opts), do: Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)

  # The head the verdict binds to, read the same way the agent runner reads it: a local workspace's
  # `HEAD`, or nil when it cannot be read (an SSH worker, a missing checkout, no commits). A verdict
  # then binds to nothing rather than to the wrong commit.
  defp workspace_head(workspace, opts), do: WorkspaceHead.read(workspace, Keyword.get(opts, :worker_host))

  defp verdict_reason(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp verdict_reason(%{comments: [comment | _]}) when is_binary(comment), do: comment
  defp verdict_reason(_result), do: "reviewer blocked the change"

  defp issue_label(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_label(%Issue{id: id}), do: inspect(id)

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
end
