defmodule SymphonyElixir.CodeReview do
  @moduledoc """
  The `Code Review` state's reviewer run.

  A `Code Review` ticket is dispatched by the poll loop like any other active
  ticket; this module turns that dispatch into a review instead of an executor run. It reuses the
  pre-push reviewer's machinery (`SymphonyElixir.ReviewAgent`), so a Code Review verdict is
  grounded in the same read-only, diff-based judgment the pre-push reviewer already makes.

  The run is only ever started on a green head (the orchestrator gates dispatch on the ticket's
  recorded CI state). Its verdict is recorded bound to the head SHA it judged, then performed
  through the one writer, `SymphonyElixir.TransitionGuard`:

    * `approve` -> `QA`, or straight to `Merging` when the QA state's skip rule applies
    * `request_changes` -> `Rework`, with the reason and findings posted on the ticket first, so the
      operator reads them and the rework run finds them in its prompt
    * `block` -> a Needs Decision hold: the ticket stays in Code Review and a person decides

  An approve carries the QA run/skip decision: `SymphonyElixir.QaPolicy` decides it deterministically
  from the changed paths (docs-only/internal-only diffs skip QA), the decision and its reason are
  recorded in the verdict's signal, and the guard row it picks does the move — `:code_review_approve`
  into the configured QA state, `:code_review_approve_skip` into `Merging`.

  An inconclusive review retries boundedly on the same head, then escalates the same way. Its cause
  (`ReviewAgent.inconclusive_cause/1`) is recorded on the verdict and on the run, so `/api/v1/state`
  counts inconclusive reviews per cause. `run/3`
  returns `:skip` for anything but a `Code Review` ticket, so the executor path is untouched.

  An escalation never moves the ticket: it posts a `## Decision needed:` request and sets a Needs
  Decision hold (`SymphonyElixir.DecisionRequest.ask/4`), whose confirmation continues into the
  QA state and whose redirect sends the ticket to `Rework`. A head whose escalation a person decided
  is never reviewed again: a dispatch on it performs the continue move into QA instead.

  The repo's escalation rules (`SymphonyElixir.EscalationRules`, the retired acceptance gate's
  deterministic rules) are checked before the reviewer starts, per the design's "escalation rules
  inform the review or ask a person; a review runs once" (`docs/design/state-machine.md`):

    * a risk rule (sensitive paths, sensitive content, a dependency change, the change's size, a
      large change to a busy file) tells the reviewer what it found, in plain words in its
      instructions, so the one review weighs it; the findings open the verdict's summary;
    * on an approval, a person rule (an escalation label, a ticket pattern), and a risk rule
      `escalate.on_match` sets to `ask`, pause the ticket on a Needs Decision hold, with the
      reviewer's approval as the recommendation.

  The reviewer runs once per head. A deepened verdict an earlier version recorded (a second reviewer
  pass, recorded with no move) on a head still waiting to be routed is routed once by the next
  dispatch, without reviewing again.

  A repo with the reviewer turned off (`review_agent.enabled: false`) has no reviewer to run, and
  `SymphonyElixir.ReviewAgent` answers a disabled reviewer with a fabricated approval. A Code Review
  ticket is never approved on that: dispatch is gated on the setting (the orchestrator parks the
  ticket with a `code_review_reviewer_disabled` signal recorded), and `run/3` itself refuses to
  review without a reviewer, recording the same signal and leaving the ticket where it is.
  """

  require Logger

  alias SymphonyElixir.{
    ClosedPullRequest,
    Config,
    DecisionRequest,
    EscalationRules,
    Handoff,
    MergeConfirmation,
    QaPolicy,
    ReviewAgent,
    RunStore,
    TicketPullRequest,
    TicketSignals,
    Tracker,
    TransitionGuard,
    Workspace,
    WorkspaceHead
  }

  alias SymphonyElixir.HumanActions.PlainWords
  alias SymphonyElixir.Linear.Issue

  @verdict_kind "code_review"
  @reviewer_disabled_signal "code_review_reviewer_disabled"
  @carried_signal "code_review_carried"
  # Written by the second reviewer pass this module no longer takes; read only to route a deepened
  # verdict recorded before the upgrade (`pending_deepening/3`).
  @deepening_signal "code_review_deepened"
  @deepening_applied_signal "code_review_deepening_applied"
  @escalate_signal "code_review_escalate"
  @decision_signal "decision returned"
  @findings_heading "## Symphony Code Review"
  @max_inconclusive_retries 2

  # The verdict strings a deepening recorded, back to the atoms `route_verdict/6` routes on. A string
  # that names no verdict stays what it is, and is refused as an unknown verdict.
  @verdict_atoms %{"approve" => :approve, "request_changes" => :request_changes, "block" => :block}

  @doc """
  Runs the reviewer for `issue` when it is a `Code Review` ticket, else `:skip` so
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
  Whether `issue` is the ticket this module reviews: one in the configured Code Review state.
  Every other ticket belongs to the executor run.
  """
  @spec reviewer_run?(Issue.t(), map()) :: boolean()
  def reviewer_run?(%Issue{state: state}, settings) when is_binary(state) do
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
        TicketSignals.record(repo_key, issue_id, @carried_signal, %{head: head})
        :ok

      _no_carry ->
        :ok
    end
  end

  # A dispatch first performs what an earlier one recorded for this head, before it reviews afresh:
  # a deepening an earlier version recorded and never routed is routed (`route_deepened/5`), and a
  # carried approve — a mechanical CI Fix re-bound it to the head the repair left — is applied without
  # a review (`carried_approval/3`). Only when neither holds does the reviewer run.
  defp review(issue, workspace, opts, settings) do
    cond do
      decided_escalation?(issue, workspace, opts, settings) ->
        continue_decided(issue, opts, settings)

      deepening = pending_deepening(issue, workspace, opts) ->
        route_deepened(issue, workspace, opts, settings, deepening)

      true ->
        review_afresh(issue, workspace, opts, settings)
    end
  end

  # A head a person already decided on is not reviewed again. An escalation pauses the ticket on a
  # Needs Decision hold whose answer moves it on (into QA, or to Rework) and clears the hold. A
  # ticket dispatched here on the head it escalated, with no newer Code Review signal and no decision
  # that moved it elsewhere since, is one whose decided move did not land (Linear refused it, or the
  # answer picked neither option): the run performs the escalation's continue move into QA rather than
  # a second review that could reverse the person's decision. That move records its own signal, so it
  # is performed once.
  defp decided_escalation?(issue, workspace, opts, settings) do
    head = workspace_head(workspace, opts)

    is_binary(head) and
      issue
      |> signals(opts)
      |> Enum.find(&(&1.name == @verdict_kind or moved_by_decision?(&1, settings)))
      |> escalation_for_head?(head)
  end

  defp moved_by_decision?(%{name: @decision_signal} = signal, settings),
    do: normalize_state(signal_detail(signal, :to) || "") != normalize_state(settings.tracker.code_review_state)

  defp moved_by_decision?(_signal, _settings), do: false

  defp escalation_for_head?(%{name: @verdict_kind} = signal, head),
    do: signal_detail(signal, :signal) == @escalate_signal and signal_head(signal) == head

  defp escalation_for_head?(_signal, _head), do: false

  defp continue_decided(issue, opts, settings) do
    Logger.info("Code Review for #{issue_label(issue)} continues into QA as its escalation was decided; not reviewing the same head again")

    move(issue, opts, settings, :code_review_approve, %{qa_decision: "run", reason: "a person decided its Code Review escalation", carried: true})
  end

  defp review_afresh(issue, workspace, opts, settings) do
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
  # whatever head the repair left (`SymphonyElixir.CiFix.carry_verdict/5`, which records the carry),
  # and this module applies it again instead of dispatching the reviewer. An unreadable head carries
  # nothing, so the ordinary review runs.
  #
  # The carry has to be the lane's own, marked by `@carried_signal`, and not merely "an approve is
  # bound to this head": a deepening an earlier version recorded also bound its second pass's approve
  # to the head it judged without routing it, and that verdict is the deepening's to route
  # (`pending_deepening/3`), not a lane carry to replay on a later dispatch.
  defp carried_approval(issue, workspace, opts) do
    head = workspace_head(workspace, opts)

    with %{outcome: "approve"} <- verdict_for_head(repo_key(issue, opts), issue.id, head),
         true <- carried_for_head?(issue, opts, head) do
      {:ok, head}
    else
      _none -> :none
    end
  end

  defp carried_for_head?(issue, opts, head) do
    is_binary(head) and Enum.any?(signals(issue, opts), &(&1.name == @carried_signal and signal_head(&1) == head))
  end

  defp carry(issue, workspace, opts, settings, head) do
    Logger.info("Code Review carried the earlier approve for #{issue_label(issue)} head=#{head}; not reviewing again")

    approve(issue, workspace, opts, settings, %{carried: true})
  end

  defp do_review(issue, workspace, opts, settings) do
    case evaluate(issue, workspace, opts, settings) do
      {:ok, %{verdict: :approve} = result} ->
        approved(issue, workspace, opts, settings, result)

      {:ok, %{verdict: verdict} = result} ->
        apply_verdict(issue, workspace, opts, settings, verdict, result)

      {:error, reason} ->
        handle_review_error(issue, workspace, opts, settings, reason)
    end
  end

  # An approval goes on unless a rule asks for a person: a person rule, or a risk rule
  # `escalate.on_match` sets to `ask`. Then the ticket waits on the person, with the approval as the
  # recommendation. The rules were checked before the review (`escalation_check/4`), so their reasons
  # come back with the verdict; the reviewer is never run a second time.
  defp approved(issue, workspace, opts, settings, result) do
    reasons = Map.get(result, :escalation_reasons, [])

    case EscalationRules.asking(reasons, escalate_rules(settings)) do
      [] ->
        apply_verdict(issue, workspace, opts, settings, :approve, result)

      asking ->
        head = workspace_head(workspace, opts)
        record_verdict(issue, opts, head, "approve", %{reason: verdict_summary(result)})
        Logger.info("Code Review for #{issue_label(issue)} matched a rule that asks a person: #{reasons_text(asking)}")
        escalate(issue, opts, settings, head, asking_why(asking, result), :continue)
    end
  end

  # The reviewer's failure modes, exactly as the verdict path handles them.
  defp handle_review_error(issue, workspace, opts, settings, reason) do
    case reason do
      {:review_agent_inconclusive, cause} -> inconclusive(issue, workspace, opts, settings, cause)
      {:review_agent_blocked, payload} -> blocked(issue, workspace, opts, settings, payload)
      other -> {:error, {:code_review_failed, other}}
    end
  end

  # A deepening an earlier version recorded for the head this run is checked out on is routed rather
  # than re-reviewed: its second pass happened on a previous dispatch, and its verdict was recorded
  # against this head. The move records its own `code_review` signal, which leaves the deepening
  # routed (`pending_deepening/3`), so a move that fails is retried and one that lands is not replayed.
  defp route_deepened(issue, workspace, opts, settings, deepening) do
    head = signal_head(deepening)
    verdict = verdict_atom(signal_detail(deepening, :verdict))

    Logger.info("Code Review for #{issue_label(issue)} head=#{head || "unknown"} routes the deepened verdict=#{inspect(verdict)} an earlier version recorded")

    judged = %{reason: signal_detail(deepening, :reason), findings: List.wrap(signal_detail(deepening, :findings))}
    route_verdict(issue, workspace, opts, settings, verdict, judged)
  end

  # A deepening recorded for the head this run is checked out on that nothing has routed yet: no
  # `code_review` move signal and no performed deepening came after it. A deepening for another head
  # is a different change's.
  defp pending_deepening(issue, workspace, opts) do
    head = workspace_head(workspace, opts)

    issue
    |> signals(opts)
    |> Enum.find(&(&1.name in [@deepening_signal, @deepening_applied_signal, @verdict_kind]))
    |> case do
      %{name: @deepening_signal} = deepening when is_binary(head) -> if signal_head(deepening) == head, do: deepening
      _routed_or_none -> nil
    end
  end

  # The escalation rules' check, run by the reviewer once it has built the diff it judges
  # (`ReviewAgent.Context`) and before it starts, so the rules read that diff rather than running it
  # again; the dependency and busy-file rules read the manifests and the base branch's history from
  # the workspace.
  defp escalation_check(%Issue{} = issue, workspace, opts, settings) do
    rules = escalate_rules(settings)

    fn source ->
      {diff, busy_files} = diff_summary(source, workspace, opts, rules)
      EscalationRules.check(issue, diff, busy_files, rules)
    end
  end

  defp escalate_rules(settings), do: settings.auto_review.acceptance_gate.escalate

  defp reasons_text(reasons), do: Enum.map_join(reasons, "; ", &"#{&1.rule}: #{&1.detail}")

  # The inventory's shape is the escalation rules' own `changed_file`. A dependency manifest also
  # carries its content before and after the change, and the busy files are the base branch's most
  # changed paths; both are read from the local workspace, so a run on an SSH worker skips them.
  defp diff_summary(source, workspace, opts, rules) do
    git = git(workspace, opts)
    base = range_base(Map.get(source, :git_range))
    files = source |> Map.get(:changed_file_inventory, []) |> Enum.map(&changed_file(&1, base, git))

    {%{files: files}, busy_files(base, rules.busy_files, git)}
  end

  defp changed_file(file, base, git) do
    path = Map.get(file, :path)

    entry = %{
      path: path,
      additions: Map.get(file, :additions) || 0,
      deletions: Map.get(file, :deletions) || 0,
      added_lines: added_lines(Map.get(file, :patch) || "")
    }

    if EscalationRules.manifest?(path),
      do: Map.merge(entry, %{base: show(git, base, path), head: show(git, "HEAD", path)}),
      else: entry
  end

  defp show(_git, nil, _path), do: nil

  defp show(git, revision, path) do
    case git.(["show", "#{revision}:#{path}"]) do
      {:ok, content} -> content
      :error -> nil
    end
  end

  defp busy_files(nil, _busy, _git), do: []

  defp busy_files(base, %{top: top, window_days: days}, git) do
    case git.(["log", "--since=#{days}.days.ago", "--no-renames", "--name-only", "--format=", base]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {path, commits} -> {-commits, path} end)
        |> Enum.take(top)
        |> Enum.map(&elem(&1, 0))

      :error ->
        []
    end
  end

  defp range_base(range) when is_binary(range) do
    case String.split(range, "..", parts: 2) do
      [base, _head] when base != "" -> base
      _other -> nil
    end
  end

  defp range_base(_range), do: nil

  # Git in the local workspace: `opts[:git]` overrides it (tests). A run on an SSH worker has no
  # local workspace to read.
  defp git(workspace, opts) do
    cond do
      Keyword.has_key?(opts, :git) -> Keyword.fetch!(opts, :git)
      is_binary(Keyword.get(opts, :worker_host)) -> fn _args -> :error end
      true -> &local_git(workspace, &1)
    end
  end

  defp local_git(workspace, args) do
    case Workspace.safe_git(["-C", workspace | args]) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> :error
    end
  end

  # The patch's added lines, without the leading `+`: the `+++` file header adds none.
  defp added_lines(patch) do
    patch
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "+"))
    |> Enum.reject(&String.starts_with?(&1, "+++"))
    |> Enum.map(&String.replace_prefix(&1, "+", ""))
  end

  # Every normalized signal carries a `details` map, but not always with atom keys (a tool hook's
  # emission is normalized from JSON), so both keyings are read, as `Handoff` reads them.
  defp signal_head(signal), do: signal_detail(signal, :head)

  defp signal_detail(%{details: details}, key), do: Map.get(details, key) || Map.get(details, Atom.to_string(key))

  defp signals(issue, opts), do: Handoff.signals(repo_key(issue, opts), issue.id)

  defp verdict_atom(verdict), do: Map.get(@verdict_atoms, verdict, verdict)

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
  # Whatever reviewer judged it, a finding against a person's recorded decision is a note, never a
  # change request (`ReviewAgent.honour_decisions/3`).
  defp evaluate(issue, workspace, opts, settings) do
    review_opts =
      opts
      |> Keyword.take([:repo_key, :run_id, :reviewer_run_profile, :linear_comment_registry, :agent_tmp_dir])
      |> Keyword.put(:worker_host, Keyword.get(opts, :worker_host))
      |> Keyword.put(:review_scope, :code_review)
      |> Keyword.put(:escalation_rules, escalation_check(issue, workspace, opts, settings))
      |> maybe_put_base_branch(opts)

    case Keyword.get(opts, :review_agent, ReviewAgent).evaluate(issue, workspace, settings, review_opts) do
      {:ok, result} -> {:ok, ReviewAgent.honour_decisions(result, issue, repo_key: Keyword.get(opts, :repo_key))}
      error -> error
    end
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
    record_verdict(issue, opts, head, to_string(verdict), %{reason: verdict_summary(result)})
    Logger.info("Code Review verdict for #{issue_label(issue)} head=#{head || "unknown"} verdict=#{inspect(verdict)}")

    judged = %{reason: verdict_reason(result), findings: findings(result)}
    route_verdict(issue, workspace, opts, settings, verdict, judged)
  end

  # The routing half of a decided verdict, shared by a verdict this run just made and a deepening an
  # earlier version recorded. Every edge goes through the one writer.
  defp route_verdict(issue, workspace, opts, settings, verdict, %{reason: reason} = judged) do
    case verdict do
      :approve ->
        approve(issue, workspace, opts, settings, %{review_reason: reason})

      :request_changes ->
        post_findings(issue, opts, workspace_head(workspace, opts), judged)
        move(issue, opts, settings, :code_review_rework, %{reason: reason})

      # The real reviewer exits a block through `blocked/5` (an error result), never this clause; an
      # overridden reviewer that returns a `:block` verdict map escalates the same way, and so does a
      # deepened block an earlier version recorded.
      :block ->
        escalate(issue, opts, settings, workspace_head(workspace, opts), reason, :rework)

      other ->
        {:error, {:code_review_unknown_verdict, other}}
    end
  end

  # A rework verdict's findings go on the ticket before the move, so the operator reads them and the
  # rework run finds them among the ticket's recent comments in its prompt. Best-effort: a comment
  # Linear refuses is logged with the findings, and the verdict still routes.
  defp post_findings(issue, opts, head, judged) do
    case tracker(opts).create_comment(issue.id, findings_comment(head, judged)) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.warning("Failed to post the Code Review findings for #{issue_label(issue)}: #{inspect(error)}; reason=#{inspect(judged.reason)} findings=#{inspect(judged.findings)}")
    end
  end

  defp findings_comment(head, %{reason: reason, findings: findings}) do
    on_head = if is_binary(head), do: " on head `#{String.slice(head, 0, 12)}`", else: ""
    listed = Enum.map(findings, &"- #{&1}")

    Enum.join(
      [
        @findings_heading,
        "Code Review requested changes#{on_head}. The ticket moves to Rework, and the rework run addresses these on the same pull request.",
        "**Reason:** #{reason}" | if(listed == [], do: [], else: ["**Findings:**\n\n" <> Enum.join(listed, "\n")])
      ],
      "\n\n"
    )
  end

  defp findings(result), do: result |> Map.get(:comments) |> List.wrap() |> Enum.filter(&is_binary/1)

  # An approve carries the QA run/skip decision. The deterministic rule (docs-only/internal-only
  # diffs) skips QA and lands the ticket in `Merging`; everything else hands it to the QA state. The
  # decision and its reason are recorded with the verdict, so a skip is auditable wherever the
  # verdict is read. `extra` marks a verdict carried forward from an earlier review, which is
  # recorded so the audit trail shows no reviewer ran a second time, and carries the reviewer's own
  # reason for the merge-confirmation summary.
  defp approve(issue, workspace, opts, settings, extra) do
    policy = Keyword.get(opts, :qa_policy, QaPolicy)

    case policy.decide(issue, settings, workspace: workspace, repo_key: repo_key(issue, opts)) do
      {:run, _playbooks, reason} ->
        Logger.info("Code Review approved #{issue_label(issue)}; QA runs: #{reason}")
        move(issue, opts, settings, :code_review_approve, Map.merge(extra, %{qa_decision: "run", reason: reason}))

      {:skip, reason} ->
        Logger.info("Code Review approved #{issue_label(issue)}; QA skipped: #{reason}")

        skip_qa(issue, opts, settings, extra, reason)

      {:nothing_to_verify, reason} ->
        Logger.warning("Code Review approved #{issue_label(issue)}, but #{reason}; holding it instead of skipping QA")

        hold_empty_change(issue, opts)
    end
  end

  # An empty diff is no change at all — a workspace built from the base branch, or a branch whose
  # work already landed — so it neither skips QA into `Merging` nor goes to QA: the ticket pauses
  # here on a person's decision (`SymphonyElixir.ClosedPullRequest`).
  defp hold_empty_change(issue, opts) do
    pr_url = TicketPullRequest.current_url(issue, repo_key(issue, opts))

    case ClosedPullRequest.pause(issue, {:no_change, pr_url}, hold_opts(issue, opts)) do
      :ok -> :ok
      {:error, error} -> {:error, {:code_review_hold_failed, error}}
    end
  end

  # A skip lands the ticket in `Merging` with no QA run. With the repo's manual review `on` it
  # pauses there on a person instead (`SymphonyElixir.MergeConfirmation`); the summary carries the
  # reviewer's reasons and the skip decision's.
  defp skip_qa(issue, opts, settings, extra, reason) do
    extra = Map.merge(extra, %{qa_decision: "skip", reason: reason})

    if TransitionGuard.confirmation_required?(:code_review_approve_skip, %{settings: settings}) do
      confirm_merge(issue, opts, extra, reason)
    else
      move(issue, opts, settings, :code_review_approve_skip, extra)
    end
  end

  defp confirm_merge(issue, opts, extra, reason) do
    parts = %{
      recommendation: "the reviewer approved and no QA run applies to this diff; ready to merge",
      review: Map.get(extra, :review_reason) || reason,
      qa: "QA skipped: #{reason}"
    }

    case MergeConfirmation.pause(issue, opts, MergeConfirmation.summary(issue, opts, parts)) do
      :ok ->
        # The verdict trail keeps the skip decision the paused move carried.
        record_move_signal(issue, opts, :merge_confirmation, Map.put(extra, :target, "Merging"))
        :ok

      {:error, error} ->
        {:error, {:code_review_merge_confirmation_failed, error}}
    end
  end

  # An inconclusive review is not a verdict: the reviewer could not ground one on the head. It
  # retries boundedly on the same head, and escalates to a person once it has run out of attempts.
  defp inconclusive(issue, workspace, opts, settings, reason) do
    head = workspace_head(workspace, opts)
    retries = inconclusive_retries(issue, opts, head)
    cause = ReviewAgent.inconclusive_cause(reason)
    record_inconclusive_cause(issue, opts, cause)

    if retries < @max_inconclusive_retries do
      record_verdict(issue, opts, head, "inconclusive", %{cause: cause})

      Logger.warning("Code Review for #{issue_label(issue)} head=#{head || "unknown"} was inconclusive cause=#{cause} (attempt #{retries + 1}/#{@max_inconclusive_retries}); retrying")

      {:error, {:code_review_inconclusive, reason}}
    else
      record_verdict(issue, opts, head, "inconclusive_escalated", %{cause: cause})
      Logger.warning("Code Review for #{issue_label(issue)} head=#{head || "unknown"} stayed inconclusive: #{inspect(reason)}")
      escalate(issue, opts, settings, head, "The reviewer could not reach a decision on the change after #{retries} more tries.", :rework)
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

    escalate(issue, opts, settings, head, verdict_reason(payload), :rework)
  end

  defp inconclusive_retries(issue, opts, head) do
    issue
    |> verdicts(opts)
    |> Enum.count(&(&1.head_sha == head and &1.outcome == "inconclusive"))
  end

  # An escalation pauses the ticket where it is on a Needs Decision hold: the person continues it
  # into QA (the hold's confirmation) or sends it to Rework. `recommend` is the option the machine
  # recommends: `:continue` when the reviewer approved, `:rework` when it did not.
  defp escalate(issue, opts, settings, head, reason, recommend) do
    Logger.warning("Escalating Code Review for #{issue_label(issue)} to a person: #{reason}")
    qa_state = settings.tracker.qa_state

    case DecisionRequest.ask(issue, escalation_request(issue, reason, qa_state, recommend), hold_opts(issue, opts), qa_state) do
      :ok ->
        record_move_signal(issue, opts, @escalate_signal, %{reason: reason, head: head})
        :ok

      {:error, error} ->
        {:error, {:code_review_escalation_failed, error}}
    end
  end

  # The reason is the reviewer's or a rule's own words, so its code is said in plain words.
  defp escalation_request(issue, reason, qa_state, recommend) do
    %{
      title: "Code Review escalated #{issue_label(issue)}",
      question: "Code Review could not settle #{issue_mention(issue)} on its own. How should it continue?",
      why: PlainWords.scrub(reason),
      options: [
        %{label: "Continue to #{qa_state}", effect: "the ticket moves to #{qa_state} and its QA run starts", recommended: recommend == :continue},
        %{label: "Send to Rework", effect: "the ticket moves to Rework with these reasons", recommended: recommend == :rework}
      ],
      if_unanswered: "#{issue_label(issue)} stays in Code Review and goes no further.",
      recommendation_reason: escalation_recommendation(recommend)
    }
  end

  defp escalation_recommendation(:continue), do: "The reviewer approved the change; only a rule that asks for a person stopped it."
  defp escalation_recommendation(:rework), do: "The reviewer did not approve the change, so it needs another pass before QA."

  defp hold_opts(issue, opts) do
    opts
    |> Keyword.take([:tracker, :store])
    |> Keyword.put(:repo_key, repo_key(issue, opts))
  end

  # Every move goes through the one writer. `run/3` only ever gets here for a ticket already in the
  # configured Code Review state (`reviewer_run?/2`), which is the origin of each of these edges in
  # the table; the table itself is what defines them, and is tested directly.
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

  defp tracker(opts), do: Keyword.get(opts, :tracker, Tracker)

  defp tracker_opts(opts) do
    case Keyword.get(opts, :tracker) do
      nil -> []
      tracker -> [tracker: tracker]
    end
  end

  # The review run gave the verdict, so its event names that run. A `reason` in `details` is the
  # verdict's summary, which the event carries too.
  defp record_verdict(issue, opts, head, outcome, details \\ %{}) do
    run_opts = [run_id: Keyword.get(opts, :run_id), reason: Map.get(details, :reason)]
    TicketSignals.record_verdict(repo_key(issue, opts), issue.id, @verdict_kind, head, outcome, details, run_opts)
  end

  # The verdict's summary: what the risk rules found, then the reviewer's own reason.
  defp verdict_summary(result) do
    findings = for %{rule: rule, detail: detail} <- Map.get(result, :escalation_reasons, []), rule in EscalationRules.risk_rules(), do: detail

    findings
    |> Enum.concat([Map.get(result, :reason)])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(". ")
  end

  # The run's record carries the cause, so the run history counts inconclusive reviews per cause.
  defp record_inconclusive_cause(issue, opts, cause) do
    case {repo_key(issue, opts), Keyword.get(opts, :run_id)} do
      {repo_key, run_id} when is_binary(repo_key) and is_binary(run_id) ->
        case RunStore.update_run(repo_key, run_id, %{review_inconclusive_cause: cause}) do
          :ok -> :ok
          {:error, error} -> Logger.warning("Failed to record the inconclusive cause on run #{run_id}: #{inspect(error)}")
        end

      _no_run ->
        :ok
    end
  end

  defp record_move_signal(issue, opts, signal, extra) do
    details =
      extra
      |> Map.take([:target, :reason, :qa_decision, :carried, :review_reason, :head])
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

  # The rules that asked for a person on an approved ticket, as the Director reads them: the
  # reviewer's approval and its reasons, then what asks for a person, without the rule's pattern or
  # the label's spelling.
  defp asking_why(reasons, result) do
    approved =
      case Map.get(result, :reason) do
        reason when is_binary(reason) and reason != "" -> "The reviewer approved the change: #{sentence(reason)}"
        _none -> "The reviewer approved the change."
      end

    [approved | Enum.map(reasons, &asking_reason/1)]
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp sentence(text) do
    text = String.trim(text)
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  defp asking_reason(%{rule: :label}), do: "The ticket carries a label that asks for a person to review it before it goes on."
  defp asking_reason(%{rule: :ticket_pattern}), do: "The ticket's own words ask for a person to review it before it goes on."
  defp asking_reason(%{rule: :path}), do: "It touches a sensitive part of the code, such as sign-in, secrets, permissions or the build workflows, and you asked to see those."
  defp asking_reason(%{rule: :diff_pattern}), do: "It adds a line that can delete data, and you asked to see those."
  defp asking_reason(%{rule: :dependency}), do: "It adds a dependency or moves one to a new major version, and you asked to see those."
  defp asking_reason(%{rule: :size, detail: detail}), do: "It is a large change (it #{detail}), and you asked to see those."
  defp asking_reason(%{rule: :busy_file}), do: "It changes many lines of one of the repository's busiest files, and you asked to see those."

  defp verdict_reason(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp verdict_reason(%{comments: [comment | _]}) when is_binary(comment), do: comment
  defp verdict_reason(_result), do: "reviewer blocked the change"

  # A ticket as a question names it the first time: its identifier and its title.
  defp issue_mention(%Issue{title: title} = issue) when is_binary(title) and title != "", do: "#{issue_label(issue)} (#{PlainWords.scrub(title)})"
  defp issue_mention(issue), do: issue_label(issue)

  defp issue_label(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_label(%Issue{id: id}), do: inspect(id)

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
end
