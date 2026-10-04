defmodule SymphonyElixir.AutoReview do
  @moduledoc """
  Auto Review sits between the executor opening a PR and the human review.

  When `auto_review.enabled` is true, Symphony moves an issue with an open PR to the
  Auto Review state (default `Auto Review`) instead of `In Review`. The CI poller
  watches that state: red CI goes back to `In Progress` through the usual fix loop,
  and green CI starts a QA pass (`on_green/5`) that runs in the background
  (`SymphonyElixir.QaRunner`, `run_qa/2`):

  - `SymphonyElixir.QaAgent.Selection` decides from the changed paths, labels and
    ticket whether to test and with which playbooks; a skip goes straight to
    `In Review` with a note;
  - `SymphonyElixir.QaAgent` runs the QA agent in a throwaway worktree at the PR head;
  - `pass` and `blocked` go to `In Review` (a `web` pass whose dev server fails its
    health check is `blocked`); `fail` goes back to `In Progress` with the
    findings as continuation context, and to `In Review` once
    `auto_review.max_fix_attempts` is used up;
  - a pass that ends after its issue left Auto Review, its PR merged or closed, or its
    head moved on writes its report but leaves the issue where it is.

  Results are kept per PR head SHA on the CI check record, every pass rewrites the
  `## Symphony QA Report` comment, and each agent run is stored in the run store
  with `kind: "qa"`.

  At startup Symphony checks that the Linear team has the Auto Review state and
  that the CI poller is on. When either is missing, Auto Review is turned off for
  the life of the process and a warning is logged, so issues keep flowing to
  `In Review`.

  GitHub runs no `pull_request` workflows on a PR that conflicts with its base, so a
  conflicting PR with no checks goes to `Rework` with a comment (`on_conflict/4`)
  instead of waiting for CI.
  """

  require Logger

  alias SymphonyElixir.{Config, Notifications, QaAgent, QaRunner, RunStore, Tracker, UsageLimit, Verification}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.{Issue, Usage}
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.QaAgent.{Report, Selection}
  alias SymphonyElixir.Workspace

  @review_state "In Review"
  @active_state "In Progress"
  @rework_state "Rework"

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
  `fail` counts as another failed fix attempt. Otherwise a QA pass is requested from
  the runner (`opts[:qa_runner]`, default `SymphonyElixir.QaRunner`).
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

      Map.get(record, :qa_sha) == sha and is_binary(Map.get(record, :qa_verdict)) ->
        reapply_outcome(issue, record, settings, opts)

      # The next green poll asks again once the provider's usage limit has reset.
      UsageLimit.persisted_holding(qa_usage_profile(settings)) ->
        {:qa_waiting, issue_id, :usage_limited}

      true ->
        request_qa(issue, record, sha, ci_status, settings, opts)
    end
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

      _other ->
        transition(issue, record, String.to_existing_atom(Map.get(record, :qa_verdict)), Map.get(record, :qa_target_state), opts)
    end
  end

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
  def run_qa(%{issue: issue, record: record, sha: sha, settings: settings} = job, opts) do
    Usage.put_caller(:auto_review)

    outcome =
      case select(issue, record, sha, settings, opts) do
        {:skip, reason} -> %{verdict: :skip, reason: reason}
        {:blocked, reason} -> %{verdict: :blocked, reason: reason}
        {:run, playbooks} -> run_agent(job, playbooks, opts)
      end

    case moved_on(issue, record, sha, settings, opts) do
      nil -> apply_outcome(issue, record, sha, outcome, settings, opts)
      reason -> report_unapplied(issue, sha, outcome, reason, opts)
    end
  end

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

  defp select(issue, record, sha, settings, opts) do
    config = settings.auto_review

    if config.run_on == "first_pass" and Map.get(record, :qa_passed) == true do
      {:skip, "QA passed on an earlier push (`run_on: first_pass`)"}
    else
      case changed_paths(record, sha, opts) do
        {:ok, paths} -> Selection.decide(issue, paths, config, dev_server?: Verification.dev_server_configured?(settings))
        {:error, reason} -> {:blocked, "could not list the PR's changed files: #{inspect(reason)}"}
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
        {:error, reason, tokens} -> {%{verdict: :blocked, reason: blocked_reason(reason)}, tokens}
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

  @doc "The `blocked` reason the QA report gives for a `SymphonyElixir.QaAgent.run/3` error."
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
  def blocked_reason(reason), do: "the QA agent could not finish: #{inspect(reason)}"

  # Stores the result for the head SHA, rewrites the QA report, then moves the issue.
  # The record is written first so a run dispatched by the move already sees the
  # QA findings.
  defp apply_outcome(issue, record, sha, outcome, settings, opts) do
    config = settings.auto_review
    result = Map.get(outcome, :result, %{})
    verdict = outcome.verdict
    fix_attempts = Map.get(record, :qa_fix_attempts, 0)
    {target_state, escalated?} = target(verdict, fix_attempts, config.max_fix_attempts)

    attrs =
      %{
        qa_sha: sha,
        qa_verdict: Atom.to_string(verdict),
        qa_target_state: target_state,
        qa_applied: false,
        qa_run_id: Map.get(outcome, :run_id),
        qa_updated_at: DateTime.utc_now()
      }
      |> Map.merge(verdict_attrs(verdict, escalated?, fix_attempts, sha, result))

    update_ci_check(Keyword.get(opts, :run_store, RunStore), record, attrs)

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
    transition(issue, Map.merge(record, attrs), verdict, target_state, opts)
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

  defp target(:fail, fix_attempts, max_fix_attempts) when fix_attempts < max_fix_attempts, do: {@active_state, false}
  defp target(:fail, _fix_attempts, _max_fix_attempts), do: {@review_state, true}
  defp target(_verdict, _fix_attempts, _max_fix_attempts), do: {@review_state, false}

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
