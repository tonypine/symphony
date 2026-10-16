defmodule SymphonyElixir.PrDecision.Apply do
  @moduledoc """
  Carries out the action `SymphonyElixir.PrDecision.decide/1` chose for a ticket: the PR and CI
  watcher's only writer (`docs/pr-ci-decisions.md`). Linear moves go through
  `SymphonyElixir.TransitionGuard`, holds through `SymphonyElixir.NeedsDecisionHold` and the
  self-heal lane (`SymphonyElixir.SelfHeal`), and GitHub calls through `SymphonyElixir.AutoMerge`
  and `SymphonyElixir.GitHub.PullRequest`.

  An action is applied once per head and rule in a stay in the phase: the stay's `applied` ledger
  holds what was done, so a repeated tick or a duplicate trigger never repeats a move, a rerun, an
  update-branch or a fix-ticket filing. An action that fails is not recorded, so the next tick
  decides again from fresh facts.

  The actions:

    * `wait`, `dispatch` – nothing to do here: a wait is recorded with its reason, and the
      orchestrator dispatches a ticket whose decision is `dispatch` (or `land_agent`).
    * `rerun_failed` – reruns the failed jobs of the head's failed workflow runs, once per head.
    * `ci_fix` – sends the ticket to CI Fix for a red head or a conflict, recording its origin, and
      spends one red or conflict attempt (`SymphonyElixir.PrWatch.Attempts`). In `Merging` auto-merge
      goes off first. In CI Fix itself the ticket stays and the next run takes the fix; the run sent
      when it entered the lane spends no second attempt. A red head's fix context lists the earlier
      fix runs' failures (check, first error line, head), so the run knows what was tried.
    * `return_to_origin` – a green, conflict-free CI Fix ticket goes back where it came from, with
      the approval it carried.
    * `to_code_review` (a person pushed in `Merging`, D4) and `to_rework` (a conflict back after
      the conflict fix runs with nobody competing, D16) – auto-merge goes off, then the move, with
      the reason posted on the ticket.
    * `update_branch`, `merge_now`, `arm`, `disarm` – the GitHub calls of a landing.
    * `land_agent` – says on the ticket that a landing agent takes the PR over; the orchestrator
      dispatches it.
    * `close_out` – a merged `Merging` PR moves its ticket to Done, or to the waiting state when its
      sub-issues are open.
    * `file_fix_ticket` – the red backstop (10 fix runs, or 3 in a row on the same failure): auto-merge
      off, then the self-heal lane files or reuses the fix ticket for the failing check and holds the
      ticket on it (D15 (c)). The outcome it hands the lane carries the same signature the streak
      compares (`SymphonyElixir.PrWatch.Attempts.cause/1`), and each fix run's failure and the red
      count as evidence.
    * `wait_for_competitors` – a recorded wait for the PRs ahead in the landing order (TP-967); in
      `Merging` auto-merge goes off.
    * `decision` – a Needs Decision hold with its request, the ticket left in its phase: a required
      check that never reported (R17: proceed without it for this PR, rerun, or fix the workflow in
      Rework; the answer is read back by `SymphonyElixir.PrWatch.Repo`, `unreported_answer/1`), and
      a PR whose only red check is one a person must clear (R18: add the waiver label, or drop the
      change in Rework). Answering the Rework option moves the ticket there.

  Rows other tickets build (a missing PR, a changed base, a closed PR, review comments, competing
  PRs) are recorded as the decision without an action, and so are the CI rows with
  `pull_requests.checks` off and the landing rows with auto-merge off. A check red on the base too
  (R23) is a wait on CI: nothing to do until the base goes green.
  """

  import Kernel, except: [apply: 2]

  require Logger

  alias SymphonyElixir.{
    AuditLog,
    AutoMerge,
    CiFix,
    CiPoller,
    MergeConfirmation,
    NeedsDecisionHold,
    Notifications,
    PrDecision,
    RunStore,
    SelfHeal,
    SubIssueWait,
    TicketPullRequest,
    TicketSignals,
    TicketState,
    Tracker,
    TransitionGuard
  }

  alias SymphonyElixir.GitHub.FailedLog
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrDecision.{Action, Facts}
  alias SymphonyElixir.PrWatch.Attempts

  @rework_state "Rework"
  @merging_state "Merging"

  # Rows a later ticket applies; until then their decision is only recorded.
  @recorded_only ["R6", "R7", "R8", "R13", "R15"]
  # The CI rows (`pull_requests.checks`).
  @ci_rules ["R17", "R19", "R20", "R21", "R22"]
  # The landing rows, and a conflict in `Merging` (`pull_requests.auto_merge`).
  @landing_rules ["R3", "R28", "R29", "R30", "R31"]
  @conflict_rules ["R14", "R14a", "R15a"]
  # Kinds with nothing to apply.
  @no_op [:wait, :dispatch]
  # R17's options, and what each answer does to the head's wait (`unreported_answer/1`).
  @proceed "Proceed without it for this PR"
  @rerun "Rerun the checks"
  @fix_in_rework "Fix the workflow in Rework"

  @typedoc "One action done in the stay: the head and rule it was for, its kind and when."
  @type entry :: %{head_sha: String.t() | nil, rule: String.t(), kind: Action.kind(), at: DateTime.t()}

  @typedoc """
  What the ticket's fix runs read: the red head's failure (`ci_failure`) and the conflict
  (`pr_conflict`), each as the CI Fix run's prompt renders it.
  """
  @type fix :: %{ci_failure: map() | nil, pr_conflict: map() | nil}

  @typedoc """
  What applying needs: the repo and its settings, the ticket as Linear read it, the watcher's read
  of its PR (nil without one), the facts decided on, the attempts, this stay's ledger, the fix
  context, the clock, the ticket's recorded decisions (`decisions`, optional: R17 counts the earlier
  answers to its question), and the injectable `opts` (`:tracker`, `:github`, `:run_store`,
  `:self_heal`, `:fixer`, `:gh_runner`).
  """
  @type ctx :: %{
          repo_key: String.t(),
          settings: map(),
          issue: Issue.t(),
          read: map() | nil,
          facts: Facts.t(),
          attempts: Attempts.t(),
          applied: [entry()],
          fix: fix(),
          now: DateTime.t(),
          opts: keyword()
        }

  @typedoc """
  What applying did: the action as recorded (a filed fix ticket names itself in the reason), the
  attempts, the ledger and the fix context to keep, and the outcome: `:applied`, `:recorded` (nothing
  to do, already done, or a row this ticket doesn't apply), or `{:error, reason}`, which keeps the
  attempts, ledger and fix context the tick began with. `moved_to` is the phase a move put the ticket
  in, which starts a new stay even when the next read already finds it back where it was.
  """
  @type result :: %{
          action: Action.t(),
          attempts: Attempts.t(),
          applied: [entry()],
          fix: fix(),
          moved_to: Facts.phase() | nil,
          outcome: :applied | :recorded | {:error, term()}
        }

  @doc "Applies `action` (see the moduledoc) and returns what to record."
  @spec apply(Action.t(), ctx()) :: result()
  def apply(%Action{} = action, ctx) do
    cond do
      not owned?(action, ctx) -> recorded(action, ctx)
      action.kind in @no_op -> recorded(action, ctx)
      already_sent?(action, ctx) -> recorded(%{action | reason: "The CI Fix run already sent for this head takes the fix"}, ctx)
      applied?(ctx, action.rule) -> recorded(action, ctx)
      true -> action |> perform(ctx) |> finish(action, ctx)
    end
  end

  @doc "Whether `rule` was applied to `head` in the stay the ledger covers."
  @spec applied?([entry()] | ctx(), String.t(), String.t() | nil) :: boolean()
  def applied?(ledger, rule, head) when is_list(ledger), do: Enum.any?(ledger, &(&1.rule == rule and &1.head_sha == head))

  defp applied?(ctx, rule), do: applied?(ctx.applied, rule, head(ctx))

  # In CI Fix, the run the ticket entered the lane for takes that fix: no second attempt is spent.
  defp already_sent?(%Action{kind: :ci_fix, args: %{cause: cause}}, %{facts: %{phase: :ci_fix}} = ctx), do: Attempts.sent?(ctx.attempts, head(ctx), cause)
  defp already_sent?(_action, _ctx), do: false

  defp owned?(%Action{rule: rule}, _ctx) when rule in @recorded_only, do: false
  defp owned?(%Action{rule: "R2"}, ctx), do: ctx.facts.phase == :merging
  defp owned?(%Action{rule: "R18"}, %{facts: %{phase: :merging}} = ctx), do: AutoMerge.enabled?(ctx.settings)
  defp owned?(%Action{rule: "R18"}, ctx), do: ci_enabled?(ctx.settings)
  defp owned?(%Action{rule: rule}, ctx) when rule in @ci_rules, do: ci_enabled?(ctx.settings)
  defp owned?(%Action{rule: rule}, ctx) when rule in @landing_rules, do: AutoMerge.enabled?(ctx.settings)
  defp owned?(%Action{rule: rule}, %{facts: %{phase: :merging}} = ctx) when rule in @conflict_rules, do: AutoMerge.enabled?(ctx.settings)
  defp owned?(_action, _ctx), do: true

  defp ci_enabled?(settings), do: settings.ci.enabled == true

  defp recorded(action, ctx), do: %{action: action, attempts: ctx.attempts, applied: ctx.applied, fix: ctx.fix, moved_to: nil, outcome: :recorded}

  defp finish({:ok, changes}, action, ctx) do
    entry = %{head_sha: head(ctx), rule: action.rule, kind: action.kind, at: ctx.now}

    %{
      action: Map.get(changes, :action, action),
      attempts: Map.get(changes, :attempts, ctx.attempts),
      applied: ctx.applied ++ [entry],
      fix: Map.get(changes, :fix, ctx.fix),
      moved_to: Map.get(changes, :moved_to),
      outcome: :applied
    }
  end

  defp finish({:error, reason}, action, ctx) do
    Logger.warning(
      "PR watch could not apply #{action.rule} #{action.kind} issue_id=#{ctx.issue.id} issue_identifier=#{ctx.issue.identifier} " <>
        "pr_url=#{pr_url(ctx)} reason=#{inspect(reason)}"
    )

    %{recorded(action, ctx) | outcome: {:error, reason}}
  end

  # The actions.

  defp perform(%Action{kind: :rerun_failed} = action, ctx) do
    run_ids = ctx |> failed_checks() |> run_ids()

    with :ok <- rerun(run_ids, ctx) do
      checks = ctx |> failed_checks() |> Enum.map(& &1.name)
      Logger.info("PR watch reran the failed checks of #{label(ctx)} rule=#{action.rule} pr_url=#{pr_url(ctx)} head_sha=#{head(ctx)} run_ids=#{Enum.join(run_ids, ",")}")
      attempts = if action.rule == "R22", do: Attempts.rerun(ctx.attempts, head(ctx), checks), else: ctx.attempts
      {:ok, %{attempts: attempts}}
    end
  end

  defp perform(%Action{kind: :ci_fix, args: %{cause: cause, origin: origin}} = action, ctx) do
    with {:ok, changes} <- send_fix(origin, cause, ctx) do
      record_fix_dispatch(action, cause, origin, ctx)
      {:ok, changes}
    end
  end

  defp perform(%Action{kind: :return_to_origin, args: %{origin: origin}}, ctx) do
    origin_state = state_name(origin, ctx.settings)

    with :ok <- move(:ci_fix_mechanical, %{target: origin_state}, ctx) do
      CiFix.carry_verdict(ctx.repo_key, ctx.issue.id, origin_state, head(ctx), ctx.settings)
      _ = CiFix.record_origin(ctx.repo_key, ctx.issue.id, nil, store_opts(ctx))
      CiFix.record_verdict(ctx.repo_key, ctx.issue.id, "mechanical", %{to: origin_state, carried: true, head: head(ctx), reason: "green_and_conflict_free"})
      TicketSignals.record(ctx.repo_key, ctx.issue.id, "ci fix return", %{to: origin_state, kind: :ci_fix, head: head(ctx), move: true})
      {:ok, %{moved_to: origin}}
    end
  end

  defp perform(%Action{kind: :to_code_review} = action, ctx) do
    with :ok <- disarm_if_armed(ctx, :person_push),
         :ok <- move(:person_push, %{}, ctx) do
      comment(ctx, "#{action.reason}: Symphony moved this ticket back to #{ctx.settings.tracker.code_review_state} so the new head is reviewed again.")
      TicketSignals.record(ctx.repo_key, ctx.issue.id, "review verdict", %{outcome: "person_push", to: ctx.settings.tracker.code_review_state})
      {:ok, %{moved_to: :code_review}}
    end
  end

  defp perform(%Action{kind: :to_rework} = action, ctx) do
    with :ok <- disarm_if_armed(ctx, :conflict),
         :ok <- move(:conflict_rework, %{}, ctx) do
      comment(ctx, "Symphony moved this ticket to #{@rework_state}: #{action.reason}. A rework run resolves the conflict on the same pull request.")
      TicketSignals.record(ctx.repo_key, ctx.issue.id, "review verdict", %{outcome: "conflict", to: @rework_state, reason: action.reason})
      {:ok, %{moved_to: :rework}}
    end
  end

  defp perform(%Action{kind: :update_branch}, ctx) do
    case AutoMerge.update_branch(ctx.read, github_opts(ctx)) do
      :ok -> {:ok, %{attempts: Attempts.updated_from(ctx.attempts, head(ctx))}}
      # GitHub couldn't merge the base branch in: the next read shows the PR conflicting.
      {:error, :conflict} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform(%Action{kind: :merge_now}, ctx) do
    with :ok <- AutoMerge.merge(ctx.read, github_opts(ctx)) do
      Logger.info("PR watch squash-merged #{label(ctx)} pr_url=#{pr_url(ctx)} head_sha=#{head(ctx)}")
      {:ok, %{}}
    end
  end

  defp perform(%Action{kind: :arm}, ctx) do
    case AutoMerge.arm(ctx.read, github_opts(ctx)) do
      :ok ->
        Logger.info("PR watch turned GitHub auto-merge on for #{label(ctx)} pr_url=#{pr_url(ctx)} head_sha=#{head(ctx)}")
        {:ok, %{}}

      # The head moved under the call: the next tick reads the new head and decides again.
      {:error, :head_moved} = error ->
        error

      # GitHub refuses auto-merge here (the PR can already merge, no branch protection, the repo
      # doesn't allow it): the PR lands by `merge_now` once it is green, or by a landing agent once
      # branch protection held it past the merge wait.
      {:error, reason} ->
        Logger.info("PR watch: GitHub refused auto-merge for #{label(ctx)}; it lands without it pr_url=#{pr_url(ctx)} reason=#{inspect(reason)}")
        {:ok, %{}}
    end
  end

  defp perform(%Action{kind: :disarm}, ctx) do
    with :ok <- disarm(ctx, :left_merging) do
      state = ctx.issue.state
      comment(ctx, AutoMerge.exit_comment(pr_url(ctx), state))
      {:ok, %{}}
    end
  end

  defp perform(%Action{kind: :land_agent} = action, ctx) do
    comment(ctx, AutoMerge.fallback_comment(pr_url(ctx), action.reason))
    {:ok, %{}}
  end

  defp perform(%Action{kind: :close_out}, ctx) do
    with :ok <- close_out(ctx) do
      TicketPullRequest.mark_finished(ctx.repo_key, pr_url(ctx), "merged")
      {:ok, %{}}
    end
  end

  defp perform(%Action{kind: :file_fix_ticket} = action, ctx) do
    with :ok <- disarm_if_armed(ctx, :ci_failure) do
      heal(action, ctx)
    end
  end

  defp perform(%Action{kind: :wait_for_competitors}, ctx) do
    with :ok <- disarm_in_merging(ctx, :conflict), do: {:ok, %{}}
  end

  defp perform(%Action{kind: :decision, rule: "R17"}, ctx) do
    request = unreported_request(ctx)

    with :ok <- ask(request, "required_check_missing", ctx) do
      prior = Enum.count(Map.get(ctx, :decisions, []), &same_title?(&1, request.title))
      {:ok, %{attempts: Attempts.asked(ctx.attempts, head(ctx), request.title, prior)}}
    end
  end

  defp perform(%Action{kind: :decision}, ctx) do
    with :ok <- disarm_if_armed(ctx, :protected_paths),
         :ok <- ask(protected_paths_request(ctx), "protected_paths", ctx) do
      {:ok, %{}}
    end
  end

  defp send_fix(origin, cause, ctx) do
    with {:ok, fix} <- fix_context(cause, ctx),
         :ok <- disarm_in_merging(ctx, cause),
         :ok <- enter_ci_fix(origin, ctx) do
      attempts = cause |> spend(fix, ctx) |> Attempts.sent(head(ctx), cause)
      {:ok, %{attempts: attempts, fix: fix, moved_to: :ci_fix}}
    end
  end

  # Rerunning a head whose failed checks carry no run id has nothing to call; the rerun counts as
  # done, so the next red read takes the head to CI Fix.
  defp rerun([], _ctx), do: :ok

  defp rerun(run_ids, ctx) do
    github = Keyword.get(ctx.opts, :github, SymphonyElixir.GitHub.PullRequest)

    Enum.reduce_while(run_ids, :ok, fn run_id, :ok ->
      case github.rerun_failed(run_id, gh_opts(ctx)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:rerun_failed, run_id, reason}}}
      end
    end)
  end

  # What the CI Fix run reads: the failed checks with their log for a red head, the conflict for a
  # conflicting one. The read already carries the log when it read it this tick.
  defp fix_context(:red, ctx) do
    with {:ok, %{excerpt: excerpt, error: error}} <- failed_log(ctx) do
      failure = %{
        commit_sha: head(ctx),
        head_ref_name: read_field(ctx, :head_ref),
        is_cross_repository: false,
        head_repository: nil,
        failed_checks: failed_checks(ctx),
        log_excerpt: excerpt,
        first_error: error,
        earlier_failures: ctx.attempts.fix_failures,
        approved: ctx.facts.phase == :merging or ctx.facts.origin == :merging
      }

      {:ok, %{ctx.fix | ci_failure: failure}}
    end
  end

  defp fix_context(:conflict, ctx) do
    attempt = ctx.attempts.conflict + 1

    conflict = %{
      pr_url: pr_url(ctx),
      pr_title: read_field(ctx, :pr_title),
      pr_number: ctx.facts.pr_number,
      head_ref: read_field(ctx, :head_ref),
      head_sha: head(ctx),
      base_ref: read_field(ctx, :base_ref),
      base_sha: read_field(ctx, :base_sha),
      mergeable: "CONFLICTING",
      merge_state_status: "DIRTY",
      conflict_key: "#{head(ctx)}|#{read_field(ctx, :base_sha) || read_field(ctx, :base_ref)}",
      observed_at: ctx.now,
      retry_count: attempt,
      max_retries: PrDecision.max_conflict_attempts(),
      approved: ctx.facts.phase == :merging or ctx.facts.origin == :merging
    }

    {:ok, %{ctx.fix | pr_conflict: conflict}}
  end

  defp failed_log(ctx) do
    case read_field(ctx, :failed_log) do
      %{excerpt: _excerpt, error: _error} = log -> {:ok, log}
      _none -> FailedLog.read(run_ids(failed_checks(ctx)), ctx.settings.ci.log_excerpt_lines, github_opts(ctx))
    end
  end

  # The red run's failure is the head's signature the streak reads (`read.failure`), so the next head
  # compares like with like; without one, the log the run reads.
  defp spend(:red, %{ci_failure: failure}, ctx) do
    Attempts.spend(ctx.attempts, :red, head_failure(ctx) || %{check: ctx.facts.failing_check || "a check", error: failure.first_error, head_sha: head(ctx)})
  end

  defp spend(:conflict, _fix, ctx), do: Attempts.spend(ctx.attempts, :conflict)

  # From a watched phase the ticket enters the lane, its origin recorded first so the repair has
  # somewhere to return; already in CI Fix, it stays and the next run takes the fix.
  defp enter_ci_fix(_origin, %{facts: %{phase: :ci_fix}}), do: :ok

  defp enter_ci_fix(origin, ctx) do
    {:ok, signal, origin_state} = CiFix.entry(state_name(origin, ctx.settings), ctx.settings)

    case CiFix.record_origin(ctx.repo_key, ctx.issue.id, origin_state, store_opts(ctx)) do
      :ok -> move(signal, %{}, ctx)
      {:error, reason} -> {:error, {:ci_fix_origin_failed, reason}}
    end
  end

  defp record_fix_dispatch(action, cause, origin, ctx) do
    target = CiFix.state(ctx.settings)
    origin_state = state_name(origin, ctx.settings)
    CiFix.record_verdict(ctx.repo_key, ctx.issue.id, "mechanical", %{to: target, origin: origin_state, reason: fix_reason(cause)})
    Logger.info("PR watch sent #{label(ctx)} to #{target}: #{action.reason} rule=#{action.rule} pr_url=#{pr_url(ctx)} head_sha=#{head(ctx)}")

    if cause == :red do
      Notifications.emit_event(:ci_failed, %{
        issue_id: ctx.issue.id,
        issue_identifier: ctx.issue.identifier,
        issue_url: ctx.issue.url,
        pr_url: pr_url(ctx),
        pr_title: read_field(ctx, :pr_title),
        state: target,
        reason: "CI failed; dispatching agent",
        metadata: %{source: "pr_watch", commit_sha: head(ctx), retry_count: ctx.attempts.red + 1, failed_checks: Enum.map(failed_checks(ctx), &Map.take(&1, [:name, :run_id, :conclusion]))}
      })
    end
  end

  defp fix_reason(:red), do: "ci_failure"
  defp fix_reason(:conflict), do: "merge_conflict"

  # The red backstop (D15 (c)): the self-heal lane files or reuses one fix ticket for the failing
  # check in the repo whose CI fails, links it as a blocker and holds the ticket on it. The same
  # failure after a fix landed is the lane's own escalation to a person.
  defp heal(action, ctx) do
    check = Map.get(action.args, :check) || ctx.facts.failing_check || "a check"
    self_heal = Keyword.get(ctx.opts, :self_heal, SelfHeal)
    outcome = backstop_outcome(check, ctx)

    case self_heal.heal(ctx.issue, heal_opts(ctx, outcome)) do
      :filed ->
        identifier = fix_ticket(ctx)
        reason = "CI keeps failing: waiting on #{identifier || "a fix ticket"}, a fix ticket for the `#{check}` check"
        args = Map.put(action.args, :fix_ticket, identifier)
        {:ok, %{attempts: Attempts.filed(ctx.attempts, identifier), action: %{action | reason: reason, args: args}}}

      :escalated ->
        {:ok, %{action: %{action | reason: "CI keeps failing on the `#{check}` check after its fix ticket landed: a person decides", owner: :person}}}

      :retry ->
        {:ok, %{attempts: Attempts.restart_red(ctx.attempts)}}

      :held ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The outcome the red backstop hands the self-heal lane for `check`: its cause is the head's failure
  (`SymphonyElixir.PrWatch.Attempts.cause/1`), so the lane's signature is the streak's, and its
  evidence names each fix run's failing check, first error line and head, and the red count.
  """
  @spec backstop_outcome(String.t(), ctx()) :: map()
  def backstop_outcome(check, ctx) do
    error = (head_failure(ctx) || List.last(ctx.facts.fix_failures) || %{error: ""}).error
    runs = "#{ctx.facts.red_attempts} of #{ctx.facts.max_red_attempts} CI Fix runs"
    streak = if ctx.facts.same_failure_streak > 1, do: ", the last #{ctx.facts.same_failure_streak} in a row with the same failure", else: ""

    %{
      cause: Attempts.cause(%{check: check, error: error}),
      reason: "CI keeps failing: the `#{check}` check is still red on #{pr_name(ctx)} after #{runs}#{streak}",
      findings: Enum.map(ctx.facts.fix_failures, &finding/1),
      pr_url: pr_url(ctx),
      head_sha: head(ctx)
    }
  end

  defp finding(%{head_sha: head} = failure) when is_binary(head), do: "#{failure.check} at #{String.slice(head, 0, 7)}: #{failure.error}"
  defp finding(failure), do: "#{failure.check}: #{failure.error}"

  # The current head's failure, as the read gave it.
  defp head_failure(ctx) do
    head = head(ctx)

    case read_field(ctx, :failure) do
      %{head_sha: ^head} = failure when is_binary(head) -> failure
      _none -> nil
    end
  end

  defp heal_opts(ctx, outcome) do
    [outcome: outcome, attempts: ctx.facts.red_attempts, repo_key: ctx.repo_key]
    |> Keyword.merge(Keyword.take(ctx.opts, [:tracker, :fixer, :symphony_repo_key, :terminal_states]))
    |> Keyword.put(:store, store(ctx))
  end

  defp fix_ticket(ctx) do
    case store(ctx).get_ticket_state(ctx.repo_key, ctx.issue.id) do
      %{} = record -> record |> TicketState.self_heal() |> then(&(&1 && &1.fix_ticket))
      _none -> nil
    end
  end

  defp close_out(ctx) do
    if SubIssueWait.wait_on_merge?(ctx.issue, ctx.settings.tracker.terminal_states, ctx.settings) do
      SubIssueWait.wait_on_merge(ctx.issue, ctx.settings, tracker(ctx))
    else
      with :ok <- move(:landing_done, %{}, ctx) do
        TicketSignals.record(ctx.repo_key, ctx.issue.id, "merge settled", %{to: "Done"})
      end
    end
  end

  # Auto-merge.

  defp disarm_in_merging(%{facts: %{phase: :merging}} = ctx, why), do: disarm_if_armed(ctx, why)
  defp disarm_in_merging(_ctx, _why), do: :ok

  defp disarm_if_armed(%{facts: %{auto_merge: :armed}} = ctx, why) do
    with :ok <- disarm(ctx, why) do
      comment(ctx, disarm_comment(why, ctx))
    end
  end

  defp disarm_if_armed(_ctx, _why), do: :ok

  defp disarm(ctx, why) do
    case AutoMerge.disarm(ctx.read, github_opts(ctx)) do
      :ok ->
        Logger.info("PR watch turned GitHub auto-merge off for #{label(ctx)} reason=#{why} pr_url=#{pr_url(ctx)} head_sha=#{head(ctx)}")
        audit_disarm(ctx, why)

      {:error, reason} ->
        {:error, {:disable_auto_merge_failed, reason}}
    end
  end

  defp audit_disarm(ctx, why) do
    %{
      event_type: "auto_merge_disabled",
      repo_key: ctx.repo_key,
      issue_id: ctx.issue.id,
      issue_identifier: ctx.issue.identifier,
      pr_url: pr_url(ctx),
      head_sha: head(ctx),
      reason: Atom.to_string(why),
      detail: "GitHub auto-merge turned off by the PR watcher (#{why})"
    }
    |> AuditLog.record()
    |> log_audit_failure(ctx)
  end

  defp log_audit_failure(:ok, _ctx), do: :ok

  defp log_audit_failure({:error, reason}, ctx) do
    Logger.warning("Failed to record auto_merge_disabled audit event issue_id=#{ctx.issue.id}: #{inspect(reason)}")
    :ok
  end

  defp disarm_comment(:conflict, ctx), do: AutoMerge.conflict_comment(pr_url(ctx))
  defp disarm_comment(:person_push, ctx), do: AutoMerge.person_push_comment(pr_url(ctx))
  defp disarm_comment(_why, ctx), do: AutoMerge.ci_fix_comment(pr_url(ctx))

  # A decision pauses the ticket in its phase on a Needs Decision hold; the option that moves it to
  # Rework does so once answered (`SymphonyElixir.NeedsDecisionHold`).
  defp ask(request, reason, ctx) do
    held = %{id: ctx.issue.id, state: ctx.issue.state, repo_key: ctx.repo_key}

    with :ok <- NeedsDecisionHold.pause(held, request, [tracker: tracker(ctx)] ++ store_opts(ctx), @rework_state) do
      TicketSignals.record(ctx.repo_key, ctx.issue.id, "decision requested", %{to: ctx.issue.state, reason: reason})
    end
  end

  defp protected_paths_request(ctx) do
    label = label(ctx)
    pr = Request.pull_request(pr_url(ctx)) || "its pull request"
    state = ctx.issue.state

    %{
      title: "Protected files changed on #{label}",
      question:
        "The pull request of #{label} changes files that agents may only change with a person's permission, and that is the only failing check. " <>
          "How should it continue?",
      why:
        "Symphony's check for changes to those files failed on #{pr}, and only a person can clear it. " <>
          "Adding the #{CiPoller.waiver_label()} label to the pull request runs the check again, and it passes.",
      if_unanswered: "#{label} stays in #{state} and #{pr} isn't merged.",
      options: [
        %{
          label: "Add the waiver label",
          effect: "you add the #{CiPoller.waiver_label()} label to #{pr}; the check runs again and passes, and the ticket continues in #{state}",
          recommended: false
        },
        %{label: "Drop the change in Rework", effect: "the ticket moves to Rework, where a run takes the change to those files out of the pull request", recommended: true}
      ],
      recommendation_reason: "No one allowed the change, so taking it out is the safe default."
    }
  end

  defp unreported_request(ctx) do
    label = label(ctx)
    pr = Request.pull_request(pr_url(ctx)) || "its pull request"
    state = ctx.issue.state
    checks = Enum.join(ctx.facts.missing_checks, ", ")
    minutes = div(ctx.settings.ci.merging_wait_timeout_ms, 60_000)

    %{
      title: "Check #{checks} never reported on #{label}",
      question: "The base branch requires the #{checks} check, but it never reported on #{pr} of #{label} within #{minutes} minutes. How should #{label} continue?",
      why:
        "No workflow reported the #{checks} check on the pull request's latest changes. " <>
          "The check may have been renamed in the branch rules, or its workflow may not run on this pull request. " <>
          "Symphony doesn't skip a required check without a person's say.",
      if_unanswered: "#{label} stays in #{state} and keeps waiting for the check.",
      options: [
        %{
          label: @proceed,
          effect: "#{label} continues in #{state} on its current changes without the check; a new push waits for it again",
          tradeoffs: [%{kind: "good", text: "the work goes on today"}, %{kind: "risk", text: "the change is not checked by #{checks}"}]
        },
        %{label: @rerun, effect: "Symphony runs the checks of #{pr} again and waits for the check once more", recommended: true},
        %{label: @fix_in_rework, effect: "the ticket moves to Rework, where a run changes the workflow so it reports the check"}
      ],
      recommendation_reason: "A rerun costs nothing and shows whether the check was only lost."
    }
  end

  @doc """
  What a person's answer to R17 picks, read from the recorded answer text (an option's number or
  label, as `SymphonyElixir.MergeConfirmation.picked_option/2` reads it): `:proceed`, `:rerun`,
  `:rework`, or `:other` for an answer that picks none.
  """
  @spec unreported_answer(String.t() | nil) :: :proceed | :rerun | :rework | :other
  def unreported_answer(answer) do
    case MergeConfirmation.picked_option([@proceed, @rerun, @fix_in_rework], List.wrap(answer)) do
      1 -> :proceed
      2 -> :rerun
      3 -> :rework
      nil -> :other
    end
  end

  @doc "Whether a recorded decision answers a question with `title`, ignoring case, spacing and Linear's escapes."
  @spec same_title?(map(), String.t()) :: boolean()
  def same_title?(%{title: recorded}, title) when is_binary(recorded), do: comparable(recorded) == comparable(title)
  def same_title?(_decision, _title), do: false

  defp comparable(text), do: text |> String.replace("\\", "") |> String.replace(~r/\s+/, " ") |> String.trim() |> String.downcase()

  # Linear.

  defp move(signal, extra, ctx) do
    guard_ctx = Map.merge(%{repo_key: ctx.repo_key, settings: ctx.settings}, extra)

    case TransitionGuard.perform(ctx.issue.id, signal, guard_ctx, tracker: tracker(ctx)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:move_failed, signal, reason}}
    end
  end

  defp comment(ctx, body) do
    case tracker(ctx).create_comment(ctx.issue.id, body) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("PR watch could not comment on #{label(ctx)}: #{inspect(reason)}")
    end

    :ok
  end

  # Helpers.

  defp state_name(:code_review, settings), do: settings.tracker.code_review_state
  defp state_name(:qa, settings), do: settings.tracker.qa_state
  defp state_name(:rework, _settings), do: @rework_state
  defp state_name(:merging, _settings), do: @merging_state

  defp failed_checks(ctx), do: read_field(ctx, :failed_checks) || []

  defp run_ids(checks), do: checks |> Enum.map(&Map.get(&1, :run_id)) |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

  defp read_field(ctx, field), do: Map.get(ctx.read || %{}, field)

  defp head(ctx), do: read_field(ctx, :head_sha)
  defp pr_url(ctx), do: read_field(ctx, :pr_url)
  defp pr_name(ctx), do: Request.pull_request(pr_url(ctx)) || "its pull request"

  defp label(%{issue: %Issue{} = issue}), do: issue.identifier || issue.id

  defp tracker(ctx), do: Keyword.get(ctx.opts, :tracker, Tracker)
  defp store(ctx), do: Keyword.get(ctx.opts, :run_store, RunStore)
  defp store_opts(ctx), do: [run_store: store(ctx), store: store(ctx)]

  defp github_opts(ctx), do: Keyword.take(ctx.opts, [:github]) ++ gh_opts(ctx)

  defp gh_opts(ctx), do: Keyword.take(ctx.opts, [:gh_runner]) ++ repo_opt(pr_url(ctx))

  # `gh run` needs the repository when it doesn't run in a clone of it.
  defp repo_opt(pr_url) when is_binary(pr_url) do
    case URI.parse(pr_url) do
      %URI{host: "github.com", path: "/" <> path} -> [repo: path |> String.split("/") |> Enum.take(2) |> Enum.join("/")]
      %URI{host: host, path: "/" <> path} when is_binary(host) -> [repo: Enum.join([host | path |> String.split("/") |> Enum.take(2)], "/")]
      _other -> []
    end
  end

  defp repo_opt(_pr_url), do: []
end
