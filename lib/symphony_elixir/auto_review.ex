defmodule SymphonyElixir.AutoReview do
  @moduledoc """
  Auto Review sits between the executor opening a PR and the human review.

  When `auto_review.enabled` is true, Symphony moves an issue with an open PR to the
  Auto Review state (default `Auto Review`) instead of `In Review`. The CI poller
  watches that state: red CI goes back to `In Progress` through the usual fix loop,
  and green CI starts a QA pass (`on_green/5`) that runs in the background
  (`SymphonyElixir.QaRunner`, `run_qa/2`):

  - the repo's `WORKFLOW.md` is re-read from its base branch (`SymphonyElixir.WorkflowSource`),
    so playbooks merged since the last dispatch apply;
  - `SymphonyElixir.QaAgent.Selection` decides from the changed paths, labels and
    ticket whether to test and with which playbooks; a skip goes straight to
    `In Review` with a note;
  - `SymphonyElixir.QaAgent` runs the QA agent in a throwaway worktree at the PR head;
  - `pass` and `blocked` go to `In Review` (a `web` pass whose dev server fails its
    health check is `blocked`), except a `blocked` the QA agent says only a person can clear
    (`needs_person`: a missing secret or key, a check by hand), which goes to the Human Review
    state (`SymphonyElixir.HumanReview`); `fail` goes back to `In Progress` with the
    findings as continuation context, and to `In Review` once
    `auto_review.max_fix_attempts` is used up;
  - a pass whose QA agent runs into the provider's usage limit gets no verdict: the
    issue stays in Auto Review, the orchestrator holds the provider's runs until the
    limit resets (`agent.usage_limit.auto_pause`), and the pass runs again after that. On
    Linear a note on the issue says until when (`SymphonyElixir.AutoReview.HoldNote`): a pass
    held again rewrites it, and the pass that runs deletes it;
  - a `blocked` the QA agent didn't decide itself (it crashed, its dev server or emulator
    didn't start) is not kept for the head once it moved the issue on: an issue moved back
    to Auto Review on the same head gets a fresh pass instead of the old verdict;
  - a pass that ends after its issue left Auto Review, its PR merged or closed, or its
    head moved on writes its report but leaves the issue where it is.

  Results are kept per PR head SHA on the CI check record, every pass rewrites the
  `## Symphony QA Report` comment, and each agent run is stored in the run store
  with `kind: "qa"`.

  When the repository's `auto_review.acceptance_gate.mode` isn't `off`, a QA `pass`, `skip` or
  `blocked` doesn't move the issue straight to `In Review`: it asks
  `SymphonyElixir.AcceptanceGate.Runner` for a gate pass on the PR head (`run_gate/2`, see
  `SymphonyElixir.AcceptanceGate`), and the issue moves on once the gate has a verdict. The
  order is CI, then QA, then the gate, and the gate never runs alongside QA: a green poll while a
  QA pass is in flight for the issue asks for no gate pass, a verdict that arrives while one is in
  flight moves nothing until that pass reports, and a verdict stands only on the QA result it
  followed (a new one on the head asks the gate again). In `shadow` mode the verdict is advisory
  and the issue goes to `In Review` as before; a QA `fail` never reaches the gate. In `enforce`
  mode the verdict moves the issue (`SymphonyElixir.AcceptanceGate.enforced_target/4`): `approve` to
  `Merging`, where GitHub auto-merge lands the PR; `rework` back to `In Progress` with the unmet
  criteria as continuation context, sharing `auto_review.max_fix_attempts` with QA fails (the
  rework past it goes to `In Review`); `escalate` to `In Review`. The mode is read again on every
  poll and when a gate pass ends, so switching it off stops the moves without a restart.

  At startup Symphony checks that the Linear team has the Auto Review state and
  that the CI poller is on. When either is missing, Auto Review is turned off for
  the life of the process and a warning is logged, so issues keep flowing to
  `In Review`.

  GitHub runs no `pull_request` workflows on a PR that conflicts with its base, so a
  conflicting PR with no checks goes to `Rework` with a comment (`on_conflict/4`)
  instead of waiting for CI.
  """

  require Logger

  alias SymphonyElixir.{AcceptanceGate, Config, Notifications, QaAgent, QaRunner, RunStore, Tracker, UsageLimit}
  alias SymphonyElixir.AutoReview.HoldNote
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanReview
  alias SymphonyElixir.Linear.{Issue, Usage}
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.QaAgent.{Report, Selection}
  alias SymphonyElixir.Verification
  alias SymphonyElixir.{WorkflowSource, Workspace}

  @review_state "In Review"
  @active_state "In Progress"
  @rework_state "Rework"
  @merging_state "Merging"

  @doc "Whether Auto Review is configured on and the startup check did not turn it off."
  @spec enabled?(Schema.t() | term()) :: boolean()
  def enabled?(%Schema{auto_review: %{enabled: true, state: state}}) when is_binary(state),
    do: not disabled?(state)

  def enabled?(_settings), do: false

  @doc "The Linear state name Auto Review uses."
  @spec state(Schema.t()) :: String.t()
  def state(%Schema{auto_review: %{state: state}}), do: state

  @doc "The state human review happens in, which Auto Review hands issues to."
  @spec review_state() :: String.t()
  def review_state, do: @review_state

  @doc "The state Symphony moves an issue to once its PR is open."
  @spec post_pr_state(Schema.t()) :: String.t()
  def post_pr_state(settings) do
    if enabled?(settings), do: state(settings), else: @review_state
  end

  @doc "The Linear team keys or ids Symphony is scoped to, from `issues` and `repositories`."
  @spec configured_teams(Schema.t(), [map()]) :: [String.t()]
  def configured_teams(%Schema{} = settings, repos) when is_list(repos) do
    [settings.tracker.team | Enum.map(repos, &Map.get(&1, :team))]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  @doc """
  Checks that the given Linear teams have the Auto Review state. With no teams,
  any team in the workspace having it is enough.

  Returns `:ok` when the state exists, `:disabled` when it is missing or the CI
  poller that moves issues on from it is off (Auto Review is then off until
  restart), `:skipped` when Auto Review is not enabled, and `{:error, reason}` when
  the tracker could not be asked (Auto Review stays on).
  """
  @spec check_tracker_state(Schema.t(), [String.t()], keyword()) :: :ok | :disabled | :skipped | {:error, term()}
  def check_tracker_state(settings, teams, opts \\ []) do
    case settings do
      %Schema{auto_review: %{enabled: true, state: state}} ->
        if ci_polling?(settings) do
          check_tracker_state_exists(state, teams, Keyword.get(opts, :tracker, Tracker))
        else
          disable(state, "it needs `pull_requests.enabled: true` and `pull_requests.checks.enabled: true` to move issues on from #{state}")
        end

      _settings ->
        :skipped
    end
  end

  defp check_tracker_state_exists(state, teams, tracker) do
    case tracker.workflow_state_exists?(state, teams) do
      {:ok, true} ->
        :persistent_term.erase(disabled_key(state))
        :ok

      {:ok, false} ->
        disable(
          state,
          "Linear state #{inspect(state)} is missing#{teams_suffix(teams)}; " <>
            "add it as a started state between In Progress and In Review, then restart Symphony"
        )

      {:error, reason} ->
        Logger.warning("Could not check the Linear state #{inspect(state)} for Auto Review; leaving it on: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp disable(state, reason) do
    Logger.warning("Auto Review disabled: #{reason}")
    :persistent_term.put(disabled_key(state), true)
    :disabled
  end

  # The CI poller is what moves issues out of Auto Review.
  defp ci_polling?(%Schema{ci: %{enabled: ci_enabled}, pr_review: %{mode: mode}}), do: ci_enabled == true and mode == "polling"

  @doc """
  Handles green CI on an issue in Auto Review. `record` is the CI check record with
  the green update applied.

  When the PR head already has a QA result, the stored outcome is applied again: a
  failed move is retried, and an issue back in Auto Review on the same SHA after a
  `fail` counts as another failed fix attempt, while one back after a `blocked` the QA
  agent didn't decide gets a fresh pass. Otherwise a QA pass is requested from the
  runner (`opts[:qa_runner]`, default `SymphonyElixir.QaRunner`).

  With the acceptance gate on, a stored QA `pass`, `skip` or `blocked` applies the gate's
  stored verdict for the SHA, or asks the gate runner (`opts[:gate_runner]`, default
  `SymphonyElixir.AcceptanceGate.Runner`) for a pass when it has none. A judged SHA never
  starts another gate run while its QA result stands.

  While a QA pass is in flight for the issue, the poll does nothing: that pass applies its own
  outcome, so a QA result stored before it never reaches the gate.
  """
  @spec on_green(Issue.t(), map(), map(), Schema.t(), keyword()) :: tuple()
  def on_green(%Issue{} = issue, record, ci_status, %Schema{} = settings, opts) do
    Usage.with_caller(:auto_review, fn -> handle_green(issue, record, ci_status, settings, opts) end)
  end

  defp handle_green(%Issue{id: issue_id} = issue, record, ci_status, settings, opts) do
    sha = Map.get(ci_status, :commit_sha)

    cond do
      not is_binary(sha) or sha == "" ->
        {:qa_waiting, issue_id, :missing_head_sha}

      # The pass in flight reports its own outcome, and asks for the gate itself: a QA result
      # stored before it says nothing about what it will find.
      qa_in_flight(issue_id, opts) ->
        {:qa_running, issue_id}

      rerun_on_return?(record, sha) ->
        rerun_qa(issue, record, ci_status, settings, opts)

      Map.get(record, :qa_sha) == sha and is_binary(Map.get(record, :qa_verdict)) ->
        reapply_outcome(issue, record, settings, opts)

      # The next green poll asks again once the provider's usage limit has reset.
      UsageLimit.persisted_holding(qa_usage_profile(settings)) ->
        {:qa_waiting, issue_id, :usage_limited}

      true ->
        request_qa(issue, record, sha, ci_status, settings, opts)
    end
  end

  # A `blocked` the QA agent didn't decide (it crashed, hit a usage limit with `auto_pause` off, its
  # dev server, emulator or browser didn't start, or git failed) says nothing about the PR. Once it
  # moved the issue on, a return to Auto Review on the same head runs the pass again instead of
  # handing the old verdict to the gate.
  defp rerun_on_return?(record, sha) do
    Map.get(record, :qa_sha) == sha and Map.get(record, :qa_verdict) == "blocked" and
      infra_blocked?(record) and Map.get(record, :qa_applied) == true
  end

  # A record stored before `qa_infra_blocked` existed has no flag: its reason tells, as an error's
  # reason is one of Symphony's own texts and the agent's is its free text.
  defp infra_blocked?(record) do
    case Map.get(record, :qa_infra_blocked) do
      nil -> error_blocked_reason?(Map.get(record, :qa_reason))
      flag -> flag == true
    end
  end

  # The gate's verdict for the head went with the old QA verdict, so it is dropped too: the fresh
  # pass asks the gate again.
  defp rerun_qa(issue, record, ci_status, settings, opts) do
    qa_attrs = Map.new(~w(qa_sha qa_verdict qa_reason qa_target_state qa_applied qa_infra_blocked)a, &{&1, nil})
    attrs = Map.merge(qa_attrs, %{gate_sha: nil, gate_verdict: nil})
    update_ci_check(Keyword.get(opts, :run_store, RunStore), record, attrs)

    Logger.info(
      "QA pass runs again: #{issue.identifier} came back to #{state(settings)} after an infrastructure block " <>
        "issue_id=#{issue.id} sha=#{Map.get(record, :qa_sha)}"
    )

    handle_green(issue, Map.merge(record, attrs), ci_status, settings, opts)
  end

  # The QA agent runs on `auto_review.kind` (else `agent.kind`), so a Codex QA agent waits on the Codex limit.
  defp qa_usage_profile(settings), do: UsageLimit.for_agent_kind(Config.qa_profile(settings), QaAgent.qa_settings(settings).agent.kind)

  defp request_qa(%Issue{id: issue_id} = issue, record, sha, ci_status, settings, opts) do
    job = %{
      issue: issue,
      record: record,
      sha: sha,
      pr_url: Map.get(ci_status, :pr_url) || Map.get(record, :pr_url),
      settings: settings,
      forced: Issue.forced?(issue, settings) or forced_part?(issue_id)
    }

    case Keyword.get(opts, :qa_runner, QaRunner).request(job, Keyword.take(opts, [:tracker, :run_store])) do
      :started -> {:qa_started, issue_id, sha}
      :running -> {:qa_running, issue_id}
      :busy -> {:qa_queued, issue_id}
      {:error, reason} -> {:qa_request_error, issue_id, reason}
    end
  end

  # A forced `breakdown` parent's current sub-ticket is forced without the label. The published
  # snapshot is read from ETS: calling the orchestrator here could deadlock, since it calls the QA
  # runner while it dispatches.
  defp forced_part?(issue_id) do
    case Orchestrator.snapshot_cache_entry() do
      {:ok, %{snapshot: %{forced: forced}}} when is_list(forced) -> Enum.any?(forced, &match?(%{sub_issue: %{issue_id: ^issue_id}}, &1))
      _missing -> false
    end
  end

  defp reapply_outcome(issue, record, settings, opts) do
    case {Map.get(record, :qa_verdict), Map.get(record, :qa_applied)} do
      {"fail", true} ->
        reason = "the issue came back to #{state(settings)} without a new commit"
        last_failure = Map.get(record, :qa_failure) || Map.get(record, :qa_last_failure) || %{}
        returned = "The fix run ended without pushing a commit: #{reason}. The earlier QA findings still apply."
        findings = [returned | List.wrap(Map.get(last_failure, :findings))]
        result = %{verdict: :fail, summary: returned, steps: [], findings: findings}
        outcome = %{verdict: :fail, result: result, reason: reason}
        apply_outcome(issue, record, Map.get(record, :qa_sha), outcome, settings, opts)

      {qa_verdict, _applied} ->
        verdict = String.to_existing_atom(qa_verdict)

        if gate_after_qa?(verdict, settings),
          do: gate_outcome(issue, record, Map.get(record, :qa_sha), settings, opts),
          else: transition(issue, record, verdict, Map.get(record, :qa_target_state), opts)
    end
  end

  # A QA `fail` (also with its fix attempts used up) never reaches the gate.
  defp gate_after_qa?(verdict, settings), do: verdict in [:pass, :skip, :blocked] and AcceptanceGate.enabled?(settings)

  defp gate_outcome(issue, record, sha, settings, opts) do
    if Map.get(record, :gate_sha) == sha and is_binary(Map.get(record, :gate_verdict)) and follows_qa?(record),
      do: apply_gate_verdict(issue, record, settings, opts),
      else: request_gate(issue, record, sha, settings, opts)
  end

  # A gate verdict stands on the QA result it followed (`gate_qa_at`, the result's `qa_updated_at`):
  # once QA reports again on the head, the gate judges again. A record stored before `gate_qa_at`
  # existed has no key, and its verdict stands.
  defp follows_qa?(record), do: Map.get(record, :gate_qa_at, Map.get(record, :qa_updated_at)) == Map.get(record, :qa_updated_at)

  # The head SHA of the QA pass in flight for the issue, else nil. `opts[:qa_running]` stands in for
  # `QaRunner.running/0` in tests.
  defp qa_in_flight(issue_id, opts), do: Map.get(Keyword.get(opts, :qa_running, &QaRunner.running/0).(), issue_id)

  defp request_gate(%Issue{id: issue_id} = issue, record, sha, settings, opts) do
    job = %{
      issue: issue,
      record: record,
      sha: sha,
      settings: settings,
      qa: %{verdict: String.to_existing_atom(Map.get(record, :qa_verdict)), reason: Map.get(record, :qa_reason)},
      forced: Issue.forced?(issue, settings) or forced_part?(issue_id)
    }

    case Keyword.get(opts, :gate_runner, AcceptanceGate.Runner).request(job, Keyword.take(opts, [:tracker, :run_store])) do
      :started -> {:gate_started, issue_id, sha}
      :running -> {:gate_running, issue_id}
      :busy -> {:gate_queued, issue_id}
      :usage_limited -> {:gate_waiting, issue_id, :usage_limited}
      {:error, reason} -> {:gate_request_error, issue_id, reason}
    end
  end

  @doc """
  Runs one acceptance gate pass for a job built by Auto Review and applies its verdict. Runs in a
  `SymphonyElixir.AcceptanceGate.Runner` task. An inconclusive pass below the limit leaves the
  issue in Auto Review, and the next green poll asks for another pass. A verdict that comes after
  the issue left Auto Review, or after its PR merged, closed or moved on, is kept but moves nothing.
  So is one that comes while a QA pass is in flight for the issue, or after the QA result it
  followed was replaced.

  The repository's settings are read again first, so a mode changed since the request applies.
  """
  @spec run_gate(map(), keyword()) :: tuple()
  def run_gate(%{issue: issue, record: record, sha: sha} = job, opts) do
    Usage.put_caller(:auto_review)
    settings = current_settings(Map.get(record, :repo_key), job.settings)

    case Keyword.get(opts, :acceptance_gate, AcceptanceGate).judge(%{job | settings: settings}, opts) do
      {:ok, %{unavailable: %{}}} ->
        {:gate_waiting, issue.id, :model_api_unreachable}

      {:ok, %{verdict: nil}} ->
        {:gate_inconclusive, issue.id, sha}

      {:ok, decision} ->
        record =
          Map.merge(record, %{
            gate_sha: sha,
            gate_verdict: decision.verdict,
            gate_run_id: Map.get(decision, :run_id),
            gate_findings: Map.get(decision, :findings, []),
            gate_target_state: nil,
            gate_applied: false
          })

        case moved_on(issue, record, sha, settings, opts) || qa_moved(issue, job.record, sha, opts) do
          nil -> apply_gate_verdict(issue, record, settings, opts)
          reason -> gate_unapplied(issue, sha, decision.verdict, reason)
        end
    end
  end

  # The gate follows QA and never runs alongside it. A verdict that arrives while a QA pass is in
  # flight for the issue is kept but moves nothing: that pass reports first, and a `fail` sends the
  # issue back to In Progress as usual. A verdict whose QA result was replaced while it ran (QA
  # reported again, or runs again, on the head) moves nothing either, and the next green poll asks
  # the gate again for the new result (`follows_qa?/1`).
  defp qa_moved(issue, record, sha, opts) do
    stored = stored_ci_check(record, opts)

    cond do
      qa_sha = qa_in_flight(issue.id, opts) ->
        "a QA pass is still running on `#{String.slice(qa_sha, 0, 12)}`"

      is_map(stored) and (Map.get(stored, :qa_sha) != sha or Map.get(stored, :qa_updated_at) != Map.get(record, :qa_updated_at)) ->
        "the QA result it followed was replaced since the gate started"

      true ->
        nil
    end
  end

  defp current_settings(repo_key, settings) do
    case Config.settings_for_repo(repo_key) do
      {:ok, current} -> current
      {:error, _reason} -> settings
    end
  end

  defp gate_unapplied(issue, sha, verdict, reason) do
    Logger.info(
      "Acceptance gate outcome not applied: #{reason} issue_id=#{issue.id} issue_identifier=#{issue.identifier} " <>
        "verdict=#{verdict} sha=#{sha}"
    )

    {:auto_review_gate_not_applied, issue.id, verdict, reason}
  end

  defp apply_gate_verdict(issue, record, settings, opts) do
    case AcceptanceGate.enforced_target(issue, record, Map.get(record, :gate_verdict), settings) do
      nil -> advise(issue, record, opts)
      target -> enforce(issue, record, target, opts)
    end
  end

  # An advisory verdict (`shadow`, or a ticket the gate never moves) is only recorded: the issue
  # moves where QA sent it, as it did before the gate.
  defp advise(issue, record, opts) do
    case transition(issue, record, String.to_existing_atom(Map.get(record, :qa_verdict)), Map.get(record, :qa_target_state), opts) do
      {:auto_review_qa, issue_id, _qa_verdict, target_state} -> {:auto_review_gate, issue_id, Map.get(record, :gate_verdict), target_state}
      error -> error
    end
  end

  # The target and what the move needs (the rework findings, the shared fix count) are stored
  # before the move, as for a QA outcome, so a run the move dispatches already sees them. A move
  # that failed is tried again on the next poll without counting another attempt; a rework whose
  # fix run ended without a new commit, back on the same SHA, counts one.
  defp enforce(issue, record, target, opts) do
    if Map.get(record, :gate_applied) == false and is_binary(Map.get(record, :gate_target_state)) do
      gate_transition(issue, record, Map.get(record, :gate_target_state), opts)
    else
      attrs = Map.put(enforce_attrs(record, target), :gate_target_state, target.state)
      update_ci_check(Keyword.get(opts, :run_store, RunStore), record, Map.put(attrs, :gate_applied, false))
      gate_transition(issue, Map.merge(record, attrs), target.state, opts)
    end
  end

  defp enforce_attrs(record, %{state: @active_state}) do
    returned? = Map.get(record, :gate_applied) == true
    previous = if returned?, do: ["The fix run ended without pushing a commit, so the gate's findings below still apply."], else: []
    findings = previous ++ List.wrap(Map.get(record, :gate_findings))
    failure = %{summary: "The acceptance gate sent the PR back.", findings: findings, source: "acceptance_gate"}

    %{
      qa_fix_attempts: AcceptanceGate.fix_attempts(record) + 1,
      qa_failure: Map.put(failure, :commit_sha, Map.get(record, :gate_sha)),
      qa_last_failure: failure
    }
  end

  defp enforce_attrs(_record, %{escalated: true}), do: %{qa_failure: nil}
  # An approve or an escalate ends the fix loop, so the next one starts a fresh count.
  defp enforce_attrs(_record, _target), do: %{qa_fix_attempts: 0, qa_failure: nil}

  defp gate_transition(issue, record, target_state, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    run_store = Keyword.get(opts, :run_store, RunStore)
    verdict = Map.get(record, :gate_verdict)

    with :ok <- mark_moved_by_gate(run_store, record, target_state),
         :ok <- tracker.update_issue_state(issue.id, target_state) do
      update_ci_check(run_store, record, %{qa_applied: true, gate_applied: true})
      Logger.info("Acceptance gate moved #{issue.identifier} to #{target_state} issue_id=#{issue.id} verdict=#{verdict} sha=#{Map.get(record, :gate_sha)}")
      {:auto_review_gate, issue.id, verdict, target_state}
    else
      {:error, {:mark_failed, reason}} ->
        Logger.warning("Acceptance gate left #{issue.identifier} in place: the gate run could not be marked before the move to #{target_state}: #{inspect(reason)}")
        {:state_transition_error, issue.id, :acceptance_gate, reason}

      {:error, reason} ->
        Logger.warning("Failed to move #{issue.identifier} to #{target_state} after the acceptance gate: #{inspect(reason)}")
        {:state_transition_error, issue.id, :acceptance_gate, reason}
    end
  end

  # The gate's own move to Merging or back to In Progress is no human decision: the agreement
  # stats skip the run (see `SymphonyElixir.AcceptanceGate.Agreement`). The mark goes on before
  # the move, so no CI poll ever sees the issue moved and the run unmarked; without it the issue
  # stays put and the next poll tries again. A failed move keeps the mark, since the move may have
  # gone through anyway.
  defp mark_moved_by_gate(run_store, %{gate_run_id: run_id} = record, target_state)
       when is_binary(run_id) and target_state in [@merging_state, @active_state] do
    case run_store.update_run(Map.get(record, :repo_key), run_id, %{moved_by_gate: target_state}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mark_failed, reason}}
    end
  end

  defp mark_moved_by_gate(_run_store, _record, _target_state), do: :ok

  @doc """
  Handles an issue in Auto Review whose PR conflicts with its base and has no checks:
  moves it to `Rework` and comments which branch to merge in. `ci_status` is the CI
  poller's PR fetch.
  """
  @spec on_conflict(Issue.t(), map(), map(), keyword()) :: tuple()
  def on_conflict(%Issue{} = issue, record, ci_status, opts) do
    Usage.with_caller(:auto_review, fn -> send_to_rework(issue, record, ci_status, opts) end)
  end

  defp send_to_rework(issue, record, ci_status, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    base = Map.get(ci_status, :base_ref_name) || base_branch(Map.get(record, :repo_key))

    case tracker.update_issue_state(issue.id, @rework_state) do
      :ok ->
        body =
          "PR conflicts with `#{base}`; merge it and push. GitHub runs no CI on a conflicting PR, " <>
            "so Auto Review moved this issue to #{@rework_state} instead of waiting for checks. " <>
            "Keep the PR and its branch: only the conflict needs fixing."

        case tracker.create_comment(issue.id, body) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Failed to comment on #{issue.identifier} about its conflicting PR: #{inspect(reason)}")
        end

        {:auto_review_conflict, issue.id, @rework_state}

      {:error, reason} ->
        Logger.warning("Failed to move #{issue.identifier} to #{@rework_state} after its PR conflicted: #{inspect(reason)}")
        {:state_transition_error, issue.id, :auto_review_conflict, reason}
    end
  end

  @doc """
  Runs one QA pass for a job built by `on_green/5` and applies its outcome. Runs in
  a `SymphonyElixir.QaRunner` task.
  """
  @spec run_qa(map(), keyword()) :: tuple()
  def run_qa(%{issue: issue, record: record, sha: sha} = job, opts) do
    Usage.put_caller(:auto_review)
    {settings, workflow_refresh} = refresh_settings(Map.get(record, :repo_key), job.settings)
    job = %{job | settings: settings}
    selection = select(issue, record, sha, settings, opts)
    log_selection(issue, sha, selection, settings, workflow_refresh)

    outcome =
      case selection do
        {:skip, reason} -> %{verdict: :skip, reason: reason}
        {:blocked, reason} -> %{verdict: :blocked, reason: reason}
        {:run, playbooks} -> run_agent(job, playbooks, opts)
      end

    case outcome do
      %{verdict: :usage_limited} ->
        hold_pass(issue, record, sha, outcome, opts)

      _verdict ->
        withdraw_hold_note(issue, record, opts)
        apply_or_report(issue, record, sha, outcome, settings, opts)
    end
  end

  defp apply_or_report(issue, record, sha, outcome, settings, opts) do
    case moved_on(issue, record, sha, settings, opts) do
      nil -> apply_outcome(issue, record, sha, outcome, settings, opts)
      reason -> report_unapplied(issue, sha, outcome, reason, opts)
    end
  end

  # A pass that ran into the provider's usage limit, or couldn't reach the model API, says nothing
  # about the PR: it stores no verdict, writes no QA report and leaves the issue in Auto Review.
  # The orchestrator holds the provider's runs until the limit resets (or a probe reaches the
  # API), as for an agent run, and the first green CI poll after that asks for the same pass
  # again (see `handle_green/5`). A note on the issue says until when (`HoldNote`).
  defp hold_pass(issue, record, sha, outcome, opts) do
    hold = Keyword.get(opts, :usage_limit_hold, &Orchestrator.hold_for_usage_limit/2)
    cause = if UsageLimit.api_unreachable?(outcome.usage_limit), do: "could not reach the model API", else: "hit the usage limit"

    case hold.(outcome.usage_limit, issue.identifier) do
      {:ok, %{resume_at: resume_at}} ->
        Logger.info("QA pass #{cause} for #{issue.identifier} sha=#{sha}; no verdict, running it again after #{DateTime.to_iso8601(resume_at)}")
        post_hold_note(issue, record, outcome.usage_limit, resume_at, opts)
        {:qa_usage_limited, issue.id, resume_at}

      other ->
        Logger.warning("QA pass #{cause} for #{issue.identifier} sha=#{sha}; no verdict, but the hold was not recorded: #{inspect(other)}")
        {:qa_usage_limited, issue.id, nil}
    end
  end

  # The CI check record remembers the note, so a pass reads the issue's comments only to delete it.
  defp post_hold_note(issue, record, usage_limit, resume_at, opts) do
    case HoldNote.post(issue, usage_limit, resume_at, hold_note_opts(opts)) do
      :ok -> update_ci_check(Keyword.get(opts, :run_store, RunStore), record, %{qa_hold_note: true})
      :skipped -> :ok
      {:error, reason} -> Logger.warning("Failed to post the QA hold note for #{issue.identifier}: #{inspect(reason)}")
    end
  end

  # The pass ran, so the issue no longer waits on the usage limit. A note that could not be
  # deleted is tried again on the next pass.
  defp withdraw_hold_note(issue, %{qa_hold_note: true} = record, opts) do
    case HoldNote.withdraw(issue, hold_note_opts(opts)) do
      :ok -> update_ci_check(Keyword.get(opts, :run_store, RunStore), record, %{qa_hold_note: false})
      {:error, reason} -> Logger.warning("Failed to remove the QA hold note for #{issue.identifier}: #{inspect(reason)}")
    end
  end

  defp withdraw_hold_note(_issue, _record, _opts), do: :ok

  defp hold_note_opts(opts), do: Keyword.take(opts, [:linear_client, :settings, :now, :to_local])

  # A pass takes minutes and `issue` is from when it was requested: a human may have approved
  # or merged the PR, or a new commit may have been pushed, in the meantime. A state that
  # cannot be read again applies the outcome, as before.
  defp moved_on(issue, record, sha, settings, opts) do
    issue_moved(issue, settings, opts) || pr_moved(record, sha, opts)
  end

  defp issue_moved(issue, settings, opts) do
    case Keyword.get(opts, :tracker, Tracker).fetch_issue_states_by_ids([issue.id]) do
      {:ok, [%Issue{state: current} | _rest]} when is_binary(current) ->
        if normalize_state(current) != normalize_state(state(settings)), do: "the issue moved to #{current}"

      _unknown ->
        nil
    end
  end

  # The CI poller keeps the stored record on the PR's latest state and head.
  defp pr_moved(record, sha, opts) do
    stored = stored_ci_check(record, opts) || %{}
    pr_state = stored |> Map.get(:pr_state) |> to_string() |> String.upcase()
    head = Map.get(stored, :last_observed_sha)

    cond do
      pr_state in ["MERGED", "CLOSED"] -> "the PR is #{String.downcase(pr_state)}"
      is_binary(head) and head != sha -> "the PR head moved to `#{String.slice(head, 0, 12)}`"
      true -> nil
    end
  end

  defp stored_ci_check(record, opts) do
    case Keyword.get(opts, :run_store, RunStore).list_ci_checks(Map.get(record, :repo_key)) do
      checks when is_list(checks) -> Enum.find(checks, &(Map.get(&1, :issue_id) == Map.get(record, :issue_id)))
      {:error, _reason} -> nil
    end
  end

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()

  # The report is still written, but the stored record keeps no verdict for the SHA, so the
  # issue gets a fresh pass if it comes back to Auto Review on it.
  defp report_unapplied(issue, sha, outcome, reason, opts) do
    Logger.info(
      "QA outcome not applied: #{reason} issue_id=#{issue.id} issue_identifier=#{issue.identifier} " <>
        "verdict=#{outcome.verdict} sha=#{sha}"
    )

    publish_report(issue, sha, outcome, %{target_state: "no move (#{reason})"}, opts)
    {:auto_review_qa_not_applied, issue.id, outcome.verdict, reason}
  end

  # The repo's `WORKFLOW.md` snapshot, where its `auto_review.playbooks` come from, is
  # otherwise refreshed only at startup and on dispatch. Fetching and refreshing it here
  # lets a playbook merged since then apply to this pass. The job's settings, read
  # when CI went green, are kept when the repo's workflow can't be read.
  defp refresh_settings(repo_key, settings) do
    with {:ok, repo} <- Config.repo(repo_key),
         result = WorkflowSource.refresh(repo, fetch: settings.workspace.fetch_before_dispatch),
         {:ok, refreshed} <- Config.settings_for_repo(repo_key) do
      {refreshed, result}
    else
      {:error, reason} -> {settings, {:error, reason}}
    end
  end

  defp log_selection(issue, sha, selection, settings, workflow_refresh) do
    {decision, selected} =
      case selection do
        {:run, playbooks} -> {"run", Enum.map(playbooks, & &1.kind)}
        {verdict, reason} -> {"#{verdict} reason=#{inspect(reason)}", []}
      end

    available = Enum.map(Selection.playbooks(settings.auto_review, dev_server?: dev_server?(settings)), & &1.kind)
    untriggered = for kind <- available, kind not in selected, do: {kind, "not triggered"}
    not_selected = untriggered ++ Selection.unavailable(settings.auto_review, dev_server?: dev_server?(settings))

    Logger.info(
      "QA selection issue_id=#{issue.id} issue_identifier=#{issue.identifier} sha=#{sha} decision=#{decision} " <>
        "playbooks=#{Enum.join(selected, ",")} not_selected=#{inspect(Enum.map_join(not_selected, "; ", fn {kind, why} -> "#{kind}: #{why}" end))} " <>
        "workflow_refresh=#{inspect(workflow_refresh)}"
    )
  end

  defp dev_server?(settings), do: Verification.dev_server_configured?(settings)

  defp select(issue, record, sha, settings, opts) do
    config = settings.auto_review

    if config.run_on == "first_pass" and Map.get(record, :qa_passed) == true do
      {:skip, "QA passed on an earlier push (`run_on: first_pass`)"}
    else
      case changed_paths(record, sha, opts) do
        {:ok, paths} -> Selection.decide(issue, paths, config, dev_server?: dev_server?(settings))
        {:error, reason} -> {:blocked, blocked_reason({:changed_files_unlisted, reason})}
      end
    end
  end

  defp changed_paths(record, sha, opts) do
    git = Keyword.get(opts, :git, &default_git/2)
    workspace = Map.get(record, :workspace_path)
    base = "origin/" <> base_branch(Map.get(record, :repo_key))

    with {merge_base, 0} <- git.(["merge-base", base, sha], workspace),
         {output, 0} <- git.(["diff", "--name-only", String.trim(merge_base), sha], workspace) do
      {:ok, output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}
    else
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  end

  @doc "The branch PRs for `repo_key` merge into (`main` when the repository names none)."
  @spec base_branch(String.t() | nil) :: String.t()
  def base_branch(repo_key) do
    case Config.repo_base_branch(repo_key) do
      {:ok, branch} when is_binary(branch) and branch != "" -> branch
      _other -> "main"
    end
  end

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)

  defp run_agent(job, playbooks, opts) do
    %{issue: issue, record: record, sha: sha, settings: settings} = job
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = Map.get(record, :repo_key)
    started_at = DateTime.utc_now()
    run_id = "qa-#{issue.identifier}-#{String.slice(sha, 0, 12)}-#{System.unique_integer([:positive])}"
    kinds = Enum.map(playbooks, & &1.kind)
    run_profile = Config.qa_profile(settings)

    put_run(run_store, %{
      run_id: run_id,
      repo_key: repo_key,
      kind: "qa",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      status: "qa_running",
      run_kind: "qa",
      model: run_profile.model,
      effort: run_profile.effort,
      attempt: Map.get(record, :qa_fix_attempts, 0) + 1,
      started_at: started_at,
      ended_at: nil,
      error: nil,
      worker_host: Map.get(record, :worker_host),
      workspace_path: QaAgent.worktree_path(settings, repo_key, issue.identifier, sha),
      head_sha: sha,
      playbooks: kinds,
      turn_count: 1,
      runtime_seconds: 0,
      tokens: QaAgent.empty_tokens(),
      updated_at: started_at
    })

    agent_job = %{
      issue: issue,
      sha: sha,
      workspace_path: Map.get(record, :workspace_path),
      worker_host: Map.get(record, :worker_host),
      repo_key: repo_key,
      run_id: run_id,
      pr_url: Map.get(job, :pr_url),
      playbooks: playbooks,
      token_limit: settings.agent.max_tokens_per_issue,
      run_profile: run_profile
    }

    {outcome, tokens} =
      case Keyword.get(opts, :qa_agent, QaAgent).run(agent_job, settings, opts) do
        {:ok, %{result: result, tokens: tokens}} -> {%{verdict: result.verdict, result: result}, tokens}
        {:error, reason, tokens} -> {error_outcome(reason, settings), tokens}
      end

    ended_at = DateTime.utc_now()
    runtime_seconds = max(DateTime.diff(ended_at, started_at), 0)

    update_run(run_store, repo_key, run_id, %{
      status: "qa_" <> Atom.to_string(outcome.verdict),
      ended_at: ended_at,
      error: Map.get(outcome, :reason),
      runtime_seconds: runtime_seconds,
      tokens: tokens,
      updated_at: ended_at
    })

    Map.merge(outcome, %{playbooks: kinds, tokens: tokens, runtime_seconds: runtime_seconds, run_id: run_id})
  end

  # With `agent.usage_limit.auto_pause` off, a usage limit is `blocked` like any other error, as
  # an agent run that hits it fails. A model API the agent couldn't reach is held either way: it
  # says nothing about the PR.
  defp error_outcome(reason, settings) do
    case usage_limit(reason) do
      %{} = info ->
        if UsageLimit.api_unreachable?(info) do
          %{verdict: :usage_limited, usage_limit: info, reason: "the QA agent could not reach the model API (#{info.error})"}
        else
          usage_limit_outcome(reason, info, settings)
        end

      nil ->
        %{verdict: :blocked, reason: blocked_reason(reason)}
    end
  end

  defp usage_limit_outcome(reason, info, settings) do
    if settings.agent.usage_limit.auto_pause,
      do: %{verdict: :usage_limited, usage_limit: info, reason: "the QA agent hit the #{UsageLimit.limit_label(info)}"},
      else: %{verdict: :blocked, reason: blocked_reason(reason)}
  end

  @doc """
  The hold info of a `SymphonyElixir.QaAgent.run/3` error caused by a provider usage limit, or by
  a model API the agent couldn't reach (`source: :api_unreachable`), else nil.
  """
  @spec usage_limit(term()) :: map() | nil
  def usage_limit({:qa_agent_failed, reason}), do: usage_limit(reason)
  def usage_limit({:usage_limited, %{} = info}), do: info
  def usage_limit({:model_api_unreachable, %{} = info}), do: info
  def usage_limit(_reason), do: nil

  # How every `blocked` reason `blocked_reason/1` gives starts. The legacy-record test in
  # `auto_review_qa_test.exs` runs every clause of it against this list.
  @error_blocked_reasons [
    "the QA agent reached the per-issue token limit ",
    "QA does not run on remote workers yet ",
    "the dev server ",
    "`npx` (Node.js) is not on Symphony's PATH",
    "`auto_review.playbooks.web.browser_mcp` is invalid: ",
    "the QA agent's answer could not be read: ",
    "the QA agent could not finish: ",
    "could not list the PR's changed files: "
  ]

  defp error_blocked_reason?(reason) when is_binary(reason),
    do: String.starts_with?(reason, @error_blocked_reasons) or String.contains?(reason, "` is not installed on the Symphony host; ")

  defp error_blocked_reason?(_reason), do: false

  @doc """
  The `blocked` reason the QA report gives for a `SymphonyElixir.QaAgent.run/3` error, or for the
  PR's changed files that git could not list (`{:changed_files_unlisted, reason}`).
  """
  @spec blocked_reason(term()) :: String.t()
  def blocked_reason({:qa_token_limit, total, limit}),
    do: "the QA agent reached the per-issue token limit (#{total} of #{limit} tokens)"

  def blocked_reason({:remote_worker_unsupported, host}), do: "QA does not run on remote workers yet (#{host})"

  def blocked_reason({:qa_dev_server_failed, {:verification_failed, :health_timeout}}),
    do: "the dev server failed its health check, so the web playbook could not run"

  def blocked_reason({:qa_dev_server_failed, reason}), do: "the dev server did not start: #{inspect(reason)}"

  def blocked_reason({:qa_browser_mcp_unavailable, :no_npx}),
    do: "`npx` (Node.js) is not on Symphony's PATH, so the web playbook's browser could not start"

  def blocked_reason({:qa_browser_mcp_unavailable, package}),
    do: "`#{package}` is not installed on the Symphony host; run `npx -y #{package} --version` there once"

  def blocked_reason({:qa_browser_mcp_invalid, errors}), do: "`auto_review.playbooks.web.browser_mcp` is invalid: #{errors}"
  def blocked_reason({:malformed_qa_response, reason}), do: "the QA agent's answer could not be read: #{inspect(reason)}"
  def blocked_reason({:changed_files_unlisted, reason}), do: "could not list the PR's changed files: #{inspect(reason)}"
  def blocked_reason(reason), do: "the QA agent could not finish: #{inspect(reason)}"

  # Stores the result for the head SHA, rewrites the QA report, then moves the issue.
  # The record is written first so a run dispatched by the move already sees the
  # QA findings.
  defp apply_outcome(issue, record, sha, outcome, settings, opts) do
    config = settings.auto_review
    result = Map.get(outcome, :result, %{})
    verdict = outcome.verdict
    fix_attempts = Map.get(record, :qa_fix_attempts, 0)
    {target_state, escalated?} = target(verdict, result, fix_attempts, config.max_fix_attempts, settings)

    attrs =
      %{
        qa_sha: sha,
        qa_verdict: Atom.to_string(verdict),
        qa_reason: Map.get(outcome, :reason) || Map.get(result, :reason),
        qa_target_state: target_state,
        qa_applied: false,
        qa_run_id: Map.get(outcome, :run_id),
        qa_updated_at: DateTime.utc_now(),
        # A `blocked` with no agent result is an error, not the QA agent's verdict.
        qa_infra_blocked: verdict == :blocked and not Map.has_key?(outcome, :result)
      }
      |> Map.merge(verdict_attrs(verdict, escalated?, fix_attempts, sha, result))
      |> keep_fix_attempts(issue, settings)

    update_ci_check(Keyword.get(opts, :run_store, RunStore), record, attrs)

    Logger.info("QA outcome issue_id=#{issue.id} issue_identifier=#{issue.identifier} verdict=#{verdict} sha=#{sha} target_state=#{target_state}")

    publish_report(
      issue,
      sha,
      outcome,
      %{
        target_state: target_state,
        escalated: escalated?,
        fix_attempt: if(verdict == :fail and not escalated?, do: fix_attempts + 1),
        max_fix_attempts: config.max_fix_attempts
      },
      opts
    )

    notify(issue, record, verdict, target_state, outcome)

    if gate_after_qa?(verdict, settings),
      do: request_gate(issue, Map.merge(record, attrs), sha, settings, opts),
      else: transition(issue, Map.merge(record, attrs), verdict, target_state, opts)
  end

  defp publish_report(issue, sha, outcome, attrs, opts) do
    report =
      outcome
      |> Map.merge(Map.take(Map.get(outcome, :result, %{}), [:summary, :steps, :findings, :follow_ups]))
      |> Map.merge(Map.put(attrs, :sha, sha))
      |> Report.render()

    case Report.publish(issue, report, Keyword.take(opts, [:linear_client, :settings])) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to publish the QA report for #{issue.identifier}: #{inspect(reason)}")
    end
  end

  defp target(:fail, _result, fix_attempts, max_fix_attempts, _settings) when fix_attempts < max_fix_attempts, do: {@active_state, false}
  defp target(:fail, _result, _fix_attempts, _max_fix_attempts, _settings), do: {@review_state, true}
  defp target(:blocked, %{needs_person: true}, _fix_attempts, _max_fix_attempts, settings), do: {HumanReview.target_state(settings), false}
  defp target(_verdict, _result, _fix_attempts, _max_fix_attempts, _settings), do: {@review_state, false}

  defp verdict_attrs(:pass, _escalated?, _fix_attempts, _sha, _result), do: %{qa_passed: true, qa_fix_attempts: 0, qa_failure: nil}

  defp verdict_attrs(:fail, false, fix_attempts, sha, result) do
    %{
      qa_fix_attempts: fix_attempts + 1,
      qa_failure: %{commit_sha: sha, summary: Map.get(result, :summary, ""), findings: QaAgent.failure_findings(result)},
      # Kept after the fix run clears `qa_failure`, for a return on the same SHA.
      qa_last_failure: %{summary: Map.get(result, :summary, ""), findings: QaAgent.failure_findings(result)}
    }
  end

  defp verdict_attrs(_verdict, _escalated?, _fix_attempts, _sha, _result), do: %{qa_failure: nil}

  # While the gate enforces, a QA pass doesn't end the fix loop: the gate's verdict does, and its
  # reworks share the count with QA fails.
  defp keep_fix_attempts(%{qa_passed: true} = attrs, issue, settings) do
    if AcceptanceGate.enforces?(issue, settings), do: Map.delete(attrs, :qa_fix_attempts), else: attrs
  end

  defp keep_fix_attempts(attrs, _issue, _settings), do: attrs

  defp notify(issue, record, verdict, target_state, outcome) when verdict in [:pass, :fail] do
    Notifications.emit_event(if(verdict == :pass, do: :qa_passed, else: :qa_failed), %{
      repo_key: Map.get(record, :repo_key),
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_title: issue.title,
      issue_url: issue.url,
      pr_url: Map.get(record, :pr_url),
      state: target_state,
      run_id: Map.get(outcome, :run_id),
      reason: if(verdict == :pass, do: "QA passed", else: "QA failed; #{target_state}"),
      tokens: Map.get(outcome, :tokens, %{}),
      metadata: %{source: "auto_review", playbooks: Map.get(outcome, :playbooks, []), runtime_seconds: Map.get(outcome, :runtime_seconds)}
    })
  end

  defp notify(_issue, _record, _verdict, _target_state, _outcome), do: :ok

  defp transition(issue, record, verdict, target_state, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)

    case tracker.update_issue_state(issue.id, target_state) do
      :ok ->
        update_ci_check(Keyword.get(opts, :run_store, RunStore), record, %{qa_applied: true})
        {:auto_review_qa, issue.id, verdict, target_state}

      {:error, reason} ->
        Logger.warning("Failed to move #{issue.identifier} to #{target_state} after QA: #{inspect(reason)}")
        {:state_transition_error, issue.id, :auto_review, reason}
    end
  end

  defp update_ci_check(run_store, record, attrs) do
    case run_store.update_ci_check(Map.get(record, :repo_key), Map.get(record, :issue_id), attrs) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to store the QA result issue_id=#{Map.get(record, :issue_id)}: #{inspect(reason)}")
    end
  end

  defp put_run(run_store, record) do
    case run_store.put_run(record) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to store the QA run run_id=#{record.run_id}: #{inspect(reason)}")
    end
  end

  defp update_run(run_store, repo_key, run_id, attrs) do
    case run_store.update_run(repo_key, run_id, attrs) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to update the QA run run_id=#{run_id}: #{inspect(reason)}")
    end
  end

  @doc false
  @spec reset_for_test(String.t()) :: :ok
  def reset_for_test(state) when is_binary(state) do
    :persistent_term.erase(disabled_key(state))
    :ok
  end

  defp disabled?(state), do: :persistent_term.get(disabled_key(state), false)

  defp disabled_key(state), do: {__MODULE__, :disabled, state}

  defp teams_suffix([]), do: ""
  defp teams_suffix(teams), do: " for team(s) #{Enum.join(teams, ", ")}"
end
