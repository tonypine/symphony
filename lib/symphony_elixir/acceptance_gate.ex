defmodule SymphonyElixir.AcceptanceGate do
  @moduledoc """
  The acceptance gate: the step in Auto Review, after QA, that decides whether a PR can merge
  without a human. See `docs/acceptance_gate.md`.

  `judge/2` runs one gate pass for a job `SymphonyElixir.AcceptanceGate.Runner` started, and
  records its verdict:

    * `run/3` builds the context (`SymphonyElixir.AcceptanceGate.Context`: the PR merged onto
      current main, busy files, overlapping open PRs), checks the escalation rules
      (`SymphonyElixir.AcceptanceGate.Escalation`), then runs the gate agent read-only in a
      throwaway worktree at the merge result. The session has the `:read_only` tool scope (no
      Linear or GitHub write), a read-only Codex sandbox, and no Claude file-editing tool or
      shell write in its working directory; pushing and the `gh` CLI stay denied. An answer
      without the JSON verdict object gets one follow-up turn in the same session;
    * `decide/4` turns the run into the final verdict: a deterministic escalation reason
      (including `qa_blocked`) forces `escalate` and the agent's verdict is kept as
      `agent_verdict`; a PR that conflicts with current main is `rework`; an inconclusive pass
      leaves no verdict until the `escalate.inconclusive_limit`-th one on the same SHA, which
      escalates with reason `inconclusive`;
    * the verdict is stored per head SHA on the CI check record (`gate_sha`, `gate_verdict`,
      `gate_agent_verdict`, `gate_reasons`, `gate_run_id`), the run in the run store with
      `kind: "acceptance_gate"`, its tokens and the verdict (`verdict`, `agent_verdict`, `reasons`,
      the `criteria` counts, `judged_at`; `SymphonyElixir.AcceptanceGate.Agreement` later adds the
      human's decision), the `## Symphony Acceptance Gate` Linear comment
      is rewritten, and each verdict writes one `acceptance_gate_verdict` audit event.

  In `shadow` mode the verdict is advisory: Auto Review moves the issue to In Review as it did
  before, and the proposed follow-ups are listed, not filed. In `enforce` mode the verdict moves
  the issue (`enforced_target/4`): `approve` to Merging, `rework` back to In Progress, `escalate`
  to In Review; and up to 3 follow-ups are filed as Backlog sub-issues
  (`SymphonyElixir.AcceptanceGate.FollowUps`), skipping a gap an existing ticket covers. The gate
  never moves a `breakdown` parent or a `Final verification:` ticket (`enforces?/2`).
  """

  require Logger

  alias SymphonyElixir.AcceptanceGate.{Context, Escalation, FollowUps, Report}
  alias SymphonyElixir.{AgentTelemetry, AgentTmpDir, AgentTools, AuditLog, Config, LeftoverProcesses, PromptSafety}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanReview
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.Repo.Fetcher
  alias SymphonyElixir.ReviewAgent
  alias SymphonyElixir.RunKind
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.UsageLimit
  alias SymphonyElixir.Workspace

  @verdicts ["approve", "rework", "escalate"]
  @criterion_statuses ["met", "unmet", "unclear"]
  @scope_kinds ["missing", "unrelated"]
  @max_follow_ups 1
  @comment_limit 100
  @workpad_markers ["## Symphony Workpad", "## Codex Workpad", "## Claude Workpad"]
  @bootstrap_criterion "Derived from the Linear issue description and comments."
  @tmp_dir_prefix "symphony-gate-"
  @merging_state "Merging"
  @active_state "In Progress"
  @review_state "In Review"
  @relation_labels %{
    "sub_issue" => "sub-issue",
    "relation" => "blocked by this ticket",
    "inverse_relation" => "blocks this ticket"
  }
  # The tickets the gate never moves: their review stays with a person.
  @guarded_kinds [:breakdown, :close_out, :final_verification]

  @type verdict :: String.t()
  @type reason :: %{rule: String.t(), detail: String.t()}
  @type criterion :: %{id: String.t(), criterion: String.t(), status: String.t(), evidence: String.t()}
  @type answer :: %{
          verdict: verdict(),
          summary: String.t(),
          criteria: [criterion()],
          overlaps: [%{pr_url: String.t(), detail: String.t()}],
          scope: [%{kind: String.t(), detail: String.t()}],
          escalation_reasons: [String.t()],
          follow_ups: [%{title: String.t(), detail: String.t(), acceptance: [String.t()], covered_by: String.t() | nil}]
        }
  @type outcome :: {:answer, answer()} | {:inconclusive, term()} | {:conflict, [String.t()]} | {:unavailable, map()}
  @type run_result :: %{
          outcome: outcome(),
          reasons: [reason()],
          criteria: [%{id: String.t(), criterion: String.t()}],
          context: map() | nil,
          tokens: map(),
          follow_up_turns: non_neg_integer()
        }
  @type decision :: %{
          verdict: verdict() | nil,
          agent_verdict: String.t() | nil,
          reasons: [reason()],
          inconclusive: non_neg_integer()
        }
  @type target :: %{state: String.t(), escalated: boolean()}

  @doc "The gate's mode for the repository `settings` belong to: `off`, `shadow` or `enforce`."
  @spec mode(Schema.t()) :: String.t()
  def mode(%Schema{auto_review: %{acceptance_gate: %{mode: mode}}}), do: mode

  @doc "Whether Auto Review runs the gate after QA."
  @spec enabled?(Schema.t()) :: boolean()
  def enabled?(%Schema{} = settings), do: mode(settings) != "off"

  @doc """
  Whether the gate's verdict moves `issue`: the mode is `enforce`, and the issue isn't a
  `breakdown` parent or a `Final verification:` ticket, whose review stays with a person.
  """
  @spec enforces?(Issue.t(), Schema.t()) :: boolean()
  def enforces?(%Issue{} = issue, %Schema{} = settings), do: mode(settings) == "enforce" and RunKind.classify(issue) not in @guarded_kinds

  @doc """
  Where an enforced `verdict` moves `issue`, or nil when the verdict is advisory (see
  `enforces?/2`) or there is none. `record` is the CI check record:

    * `approve` goes to Merging, where GitHub auto-merge lands the PR;
    * `rework` goes back to In Progress while `qa_fix_attempts` (shared with QA fails) is below
      `auto_review.max_fix_attempts`; past it, it goes where `escalate` goes, with `escalated: true`;
    * `escalate` goes to the state QA picked for human review (`qa_target_state`): In Review, or
      the Human Review state for a QA block only a person can clear.
  """
  @spec enforced_target(Issue.t(), map(), verdict() | nil, Schema.t()) :: target() | nil
  def enforced_target(%Issue{} = issue, record, verdict, %Schema{} = settings) do
    cond do
      verdict not in @verdicts or not enforces?(issue, settings) -> nil
      verdict == "approve" -> %{state: @merging_state, escalated: false}
      verdict == "escalate" -> %{state: human_review_state(record), escalated: false}
      fix_attempts(record) < settings.auto_review.max_fix_attempts -> %{state: @active_state, escalated: false}
      true -> %{state: human_review_state(record), escalated: true}
    end
  end

  @doc "The fix attempts the issue used on its PR: QA fails and enforced gate reworks."
  @spec fix_attempts(map()) :: non_neg_integer()
  def fix_attempts(record), do: Map.get(record, :qa_fix_attempts) || 0

  defp human_review_state(record), do: Map.get(record, :qa_target_state) || @review_state

  @doc """
  The settings a gate session runs with: the gate's runtime, command, turns and timeout, and a
  read-only Codex sandbox.
  """
  @spec gate_settings(Schema.t()) :: Schema.t()
  def gate_settings(%Schema{auto_review: %{acceptance_gate: config}, agent: agent} = settings) do
    %{
      settings
      | agent: %{
          agent
          | kind: config.kind || agent.kind,
            command: config.command || agent.command,
            max_turns: config.max_turns,
            turn_timeout_ms: config.timeout_ms,
            thread_sandbox: "read-only",
            turn_sandbox_policy: %{"type" => "readOnly"}
        }
    }
  end

  @doc "The usage-limit profile a gate run waits on: the gate profile, on the gate agent's provider."
  @spec usage_profile(Schema.t()) :: map()
  def usage_profile(%Schema{} = settings), do: UsageLimit.for_agent_kind(Config.acceptance_gate_profile(settings), gate_settings(settings).agent.kind)

  @doc """
  The options a gate session starts with: the `:read_only` tool scope (only the Linear and
  GitHub read tools), a read-only runtime sandbox, and the pass's own temp folder (`job.tmp_dir`)
  as the agent's `$TMPDIR`, its only writable path.
  """
  @spec session_opts(map(), Schema.t()) :: keyword()
  def session_opts(job, %Schema{} = settings) do
    gate_settings = gate_settings(settings)
    tmp_dir = Map.get(job, :tmp_dir)

    [
      worker_host: nil,
      settings: if(tmp_dir, do: AgentTmpDir.allow_write(gate_settings, tmp_dir), else: gate_settings),
      issue: job.issue,
      repo_key: Map.get(job.record, :repo_key),
      run_id: Map.get(job, :run_id),
      run_profile: Config.acceptance_gate_profile(settings),
      tool_scope: :read_only,
      read_only: true,
      extra_env: AgentTmpDir.env(gate_settings.agent.kind, tmp_dir)
    ]
  end

  @doc "The temp folders a gate pass in `worktree` may use, one under each of `bases` (see `SymphonyElixir.AgentTmpDir`)."
  @spec tmp_dirs(Path.t(), [Path.t()]) :: [Path.t()]
  def tmp_dirs(worktree, bases \\ AgentTmpDir.default_bases()), do: AgentTmpDir.paths(@tmp_dir_prefix, worktree, bases)

  @doc "The throwaway worktree the gate agent reads, at the merge result."
  @spec worktree_path(Schema.t(), String.t() | nil, String.t() | nil, String.t()) :: Path.t()
  def worktree_path(%Schema{} = settings, repo_key, identifier, sha), do: Context.worktree_path(settings, repo_key, identifier, sha) <> "-agent"

  @doc """
  Runs one gate pass for `job` and records its verdict: the CI check record, the run, the
  `## Symphony Acceptance Gate` comment and, for a final verdict, the audit event. Runs in a
  `SymphonyElixir.AcceptanceGate.Runner` task. Returns the decision; its `verdict` is nil after
  an inconclusive pass below the limit.

  A pass whose agent couldn't reach the model API is neither: it records no verdict, counts no
  inconclusive pass and writes no comment. It holds the provider's runs as a usage limit does
  (`opts[:usage_limit_hold]`, default `SymphonyElixir.Orchestrator.hold_for_usage_limit/2`), so
  the next green poll waits, and returns a decision with `unavailable` set to the hold info.

  `job` carries `issue`, `record` (the CI check record), `sha`, `settings` and `qa` (the QA
  verdict and reason it follows).

  The decision also carries the gate `run_id`, the `findings` a `rework` sends back to the
  executor, and the enforced `target` (`enforced_target/4`, nil when the verdict is advisory).
  An enforced verdict files the answer's follow-ups first (`SymphonyElixir.AcceptanceGate.FollowUps`),
  so the comment lists them.
  """
  @spec judge(map(), keyword()) :: {:ok, map()}
  def judge(%{issue: issue, record: record, sha: sha, settings: settings} = job, opts) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = Map.get(record, :repo_key)
    started_at = DateTime.utc_now()
    run_id = "gate-#{issue.identifier}-#{String.slice(sha, 0, 12)}-#{System.unique_integer([:positive])}"
    profile = Config.acceptance_gate_profile(settings)

    put_run(run_store, %{
      run_id: run_id,
      repo_key: repo_key,
      kind: "acceptance_gate",
      run_kind: "acceptance_gate",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      status: "gate_running",
      model: profile.model,
      effort: profile.effort,
      mode: mode(settings),
      started_at: started_at,
      ended_at: nil,
      error: nil,
      worker_host: Map.get(record, :worker_host),
      workspace_path: worktree_path(settings, repo_key, issue.identifier, sha),
      pr_url: Map.get(record, :pr_url),
      head_sha: sha,
      turn_count: 1,
      runtime_seconds: 0,
      tokens: QaAgent.empty_tokens(),
      updated_at: started_at
    })

    job = Map.merge(job, %{run_id: run_id, token_limit: settings.agent.max_tokens_per_issue})
    result = run(job, settings, opts)

    pass = %{
      issue: issue,
      record: record,
      sha: sha,
      settings: settings,
      run_id: run_id,
      started_at: started_at,
      run_store: run_store
    }

    case result.outcome do
      {:unavailable, info} -> hold_unavailable_pass(pass, result, info, opts)
      _outcome -> record_pass(pass, result, opts)
    end
  end

  defp hold_unavailable_pass(%{issue: issue, record: record, sha: sha} = pass, result, info, opts) do
    hold = Keyword.get(opts, :usage_limit_hold, &Orchestrator.hold_for_usage_limit/2)
    held = hold.(info, issue.identifier)

    Logger.warning(
      "Acceptance gate agent could not reach the model API (#{info.error}) for #{issue.identifier} sha=#{sha}; " <>
        "no verdict, the pass runs again once the hold lifts hold=#{inspect(held)}"
    )

    ended_at = DateTime.utc_now()

    update_run(pass.run_store, Map.get(record, :repo_key), pass.run_id, %{
      status: "gate_unavailable",
      ended_at: ended_at,
      error: "model API unreachable (#{info.error})",
      runtime_seconds: max(DateTime.diff(ended_at, pass.started_at), 0),
      tokens: result.tokens,
      updated_at: ended_at
    })

    decision = %{verdict: nil, agent_verdict: nil, reasons: [], inconclusive: 0, unavailable: info}
    {:ok, Map.merge(decision, %{run_id: pass.run_id, findings: [], target: nil})}
  end

  defp record_pass(%{issue: issue, record: record, sha: sha, settings: settings, run_id: run_id, started_at: started_at, run_store: run_store}, result, opts) do
    repo_key = Map.get(record, :repo_key)
    decision = decide(result, record, sha, settings)
    findings = rework_findings(result, decision)
    target = enforced_target(issue, record, decision.verdict, settings)
    follow_ups = if target, do: FollowUps.file(issue, answer_follow_ups(result.outcome), sha, settings, opts)
    ended_at = DateTime.utc_now()
    runtime_seconds = max(DateTime.diff(ended_at, started_at), 0)

    update_run(run_store, repo_key, run_id, %{
      status: "gate_" <> (decision.verdict || "inconclusive"),
      ended_at: ended_at,
      error: inconclusive_error(result.outcome),
      runtime_seconds: runtime_seconds,
      tokens: result.tokens,
      verdict: decision.verdict,
      agent_verdict: decision.agent_verdict,
      reasons: decision.reasons,
      criteria: criteria_counts(result.outcome),
      judged_at: if(decision.verdict, do: ended_at),
      updated_at: ended_at
    })

    update_ci_check(run_store, record, %{
      gate_sha: sha,
      gate_verdict: decision.verdict,
      gate_agent_verdict: decision.agent_verdict,
      gate_reasons: decision.reasons,
      gate_run_id: run_id,
      gate_mode: mode(settings),
      gate_inconclusive: decision.inconclusive,
      gate_findings: findings,
      # A new verdict hasn't moved the issue yet (see `SymphonyElixir.AutoReview`).
      gate_target_state: nil,
      gate_applied: false,
      gate_updated_at: ended_at
    })

    report_fields = %{
      decision: decision,
      sha: sha,
      mode: mode(settings),
      target: target,
      fix_attempts: fix_attempts(record),
      max_fix_attempts: settings.auto_review.max_fix_attempts,
      filed_follow_ups: follow_ups,
      runtime_seconds: runtime_seconds,
      limit: inconclusive_limit(settings)
    }

    report = Report.render(Map.merge(result, report_fields))

    case Report.publish(issue, report, [settings: settings] ++ Keyword.take(opts, [:linear_client])) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to publish the acceptance gate report for #{issue.identifier}: #{inspect(reason)}")
    end

    if decision.verdict, do: audit(issue, record, sha, settings, decision, run_id, result.tokens, opts)

    {:ok, Map.merge(decision, %{run_id: run_id, findings: findings, target: target})}
  end

  defp outcome_answer({:answer, answer}), do: answer
  defp outcome_answer(_outcome), do: %{}

  defp answer_follow_ups(outcome), do: outcome |> outcome_answer() |> Map.get(:follow_ups, [])

  # What a `rework` sends back to the executor: the criteria the agent didn't find met, what the
  # PR is missing, and the reasons (a conflict with current main, where the agent didn't run).
  defp rework_findings(%{outcome: {:answer, answer}, criteria: criteria}, %{verdict: "rework", reasons: reasons}) do
    unmet = for %{status: status} = row <- Report.rows(criteria, answer), status != "met", do: "Criterion #{status}: #{row.criterion} (#{row.evidence})"
    missing = for %{kind: "missing", detail: detail} <- answer.scope, do: "Missing from the PR: #{detail}"
    summary = if answer.summary != "", do: ["Gate summary: #{answer.summary}"], else: []
    unmet ++ missing ++ reason_lines(reasons) ++ summary
  end

  defp rework_findings(_result, %{verdict: "rework", reasons: reasons}), do: reason_lines(reasons)
  defp rework_findings(_result, _decision), do: []

  defp reason_lines(reasons), do: Enum.map(reasons, &"#{&1.rule}: #{&1.detail}")

  defp criteria_counts(outcome) do
    statuses = for {:answer, %{criteria: criteria}} <- [outcome], criterion <- criteria, do: criterion.status
    count = fn status -> Enum.count(statuses, &(&1 == status)) end
    %{met: count.("met"), unmet: count.("unmet"), unclear: count.("unclear")}
  end

  defp inconclusive_error({:inconclusive, reason}), do: inspect(reason)
  defp inconclusive_error(_outcome), do: nil

  defp audit(issue, record, sha, settings, decision, run_id, tokens, opts) do
    event = %{
      event_type: "acceptance_gate_verdict",
      repo_key: Map.get(record, :repo_key),
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      sha: sha,
      mode: mode(settings),
      verdict: decision.verdict,
      agent_verdict: decision.agent_verdict,
      reasons: decision.reasons,
      run_id: run_id,
      tokens: tokens
    }

    case AuditLog.record(event, Keyword.take(opts, [:dir])) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to audit the acceptance gate verdict for #{issue.identifier}: #{inspect(reason)}")
    end
  end

  @doc """
  The final verdict for a gate run on `sha`, given the CI check `record` it started from (for
  the inconclusive passes already counted on that SHA).
  """
  @spec decide(run_result(), map(), String.t(), Schema.t()) :: decision()
  def decide(%{outcome: outcome, reasons: reasons}, record, sha, %Schema{} = settings) do
    limit = inconclusive_limit(settings)

    case outcome do
      {:answer, %{verdict: agent_verdict}} ->
        verdict = if reasons == [], do: agent_verdict, else: "escalate"
        %{verdict: verdict, agent_verdict: agent_verdict, reasons: reasons, inconclusive: 0}

      {:conflict, files} ->
        conflict = %{rule: "conflict", detail: "the PR conflicts with current main in #{Enum.join(files, ", ")}"}
        verdict = if reasons == [], do: "rework", else: "escalate"
        %{verdict: verdict, agent_verdict: nil, reasons: reasons ++ [conflict], inconclusive: 0}

      {:inconclusive, _reason} ->
        count = previous_inconclusive(record, sha) + 1

        cond do
          reasons != [] ->
            %{verdict: "escalate", agent_verdict: "inconclusive", reasons: reasons, inconclusive: count}

          count >= limit ->
            reason = %{rule: "inconclusive", detail: "#{count} inconclusive gate passes on this SHA (inconclusive_limit #{limit})"}
            %{verdict: "escalate", agent_verdict: "inconclusive", reasons: [reason], inconclusive: count}

          true ->
            %{verdict: nil, agent_verdict: "inconclusive", reasons: [], inconclusive: count}
        end
    end
  end

  defp previous_inconclusive(record, sha) do
    if Map.get(record, :gate_sha) == sha, do: Map.get(record, :gate_inconclusive) || 0, else: 0
  end

  defp inconclusive_limit(settings), do: settings.auto_review.acceptance_gate.escalate.inconclusive_limit

  @doc """
  Runs the gate on `job`: builds the context, checks the escalation rules and asks the gate
  agent. Never raises on a runtime failure: a context or agent error is an `:inconclusive`
  outcome, a merge conflict a `:conflict` one (the agent doesn't run).

  Options: `:context` (a module with `build/5`), `:context_opts`, `:git`, `:gate_agent_module`,
  `:linear_client`, `:leftover_processes`.
  """
  @spec run(map(), Schema.t(), keyword()) :: run_result()
  def run(%{issue: issue, record: record, sha: sha} = job, %Schema{} = settings, opts) do
    criteria = criteria(issue, settings, opts)
    qa_reasons = qa_reasons(Map.get(job, :qa))
    base = %{criteria: criteria, context: nil, tokens: QaAgent.empty_tokens(), follow_up_turns: 0}

    case Keyword.get(opts, :context, Context).build(issue, record, sha, settings, Keyword.get(opts, :context_opts, [])) do
      {:ok, context} ->
        reasons = escalation_reasons(issue, context.diff_summary, context.busy_files, settings) ++ qa_reasons
        existing = existing_tickets(issue, settings, opts)
        job = Map.merge(job, %{context: context, criteria: criteria, reasons: reasons, existing_tickets: existing})

        base
        |> Map.merge(%{reasons: reasons, context: context})
        |> Map.merge(ask_agent(job, settings, opts))

      {:conflict, files} ->
        Map.merge(base, %{outcome: {:conflict, files}, reasons: escalation_reasons(issue, %{files: []}, [], settings) ++ qa_reasons})

      {:error, reason} ->
        Logger.warning("Acceptance gate context failed for #{issue.identifier} sha=#{sha}: #{inspect(reason)}")
        Map.merge(base, %{outcome: {:inconclusive, {:context_failed, reason}}, reasons: escalation_reasons(issue, %{files: []}, [], settings) ++ qa_reasons})
    end
  end

  defp escalation_reasons(issue, diff_summary, busy_files, settings) do
    rules = settings.auto_review.acceptance_gate.escalate
    opts = [human_review_state: HumanReview.state(settings)]
    for %{rule: rule, detail: detail} <- Escalation.check(issue, diff_summary, busy_files, rules, opts), do: %{rule: Atom.to_string(rule), detail: detail}
  end

  defp qa_reasons(%{verdict: :blocked} = qa), do: [%{rule: "qa_blocked", detail: "QA was blocked: " <> (Map.get(qa, :reason) || "no reason given")}]
  defp qa_reasons(_qa), do: []

  defp ask_agent(%{record: record} = job, settings, opts) do
    case Map.get(record, :worker_host) do
      host when is_binary(host) ->
        %{outcome: {:inconclusive, {:remote_worker_unsupported, host}}}

      _local ->
        git = Keyword.get(opts, :git, &default_git/2)
        worktree = worktree_path(settings, Map.get(record, :repo_key), job.issue.identifier, job.sha)

        case add_worktree(record.workspace_path, worktree, job.context.merged_sha, git) do
          :ok ->
            tmp_dirs = tmp_dirs(worktree, Keyword.get_lazy(opts, :tmp_bases, &AgentTmpDir.default_bases/0))

            try do
              run_with_tmp_dir(Map.put(job, :worktree, worktree), tmp_dirs, settings, opts)
            after
              stop_leftover_processes(job.issue, [worktree | tmp_dirs], opts)
              Enum.each(tmp_dirs, &File.rm_rf/1)
              remove_worktree(record.workspace_path, worktree, git)
            end

          {:error, reason} ->
            %{outcome: {:inconclusive, reason}}
        end
    end
  end

  defp run_with_tmp_dir(job, tmp_dirs, settings, opts) do
    case AgentTmpDir.create(tmp_dirs) do
      {:ok, tmp_dir} -> run_session(Map.put(job, :tmp_dir, tmp_dir), settings, opts)
      :error -> %{outcome: {:inconclusive, {:gate_tmp_dir_failed, tmp_dirs}}}
    end
  end

  defp run_session(job, settings, opts) do
    case agent_module(opts, gate_settings(settings).agent.kind) do
      {:ok, agent_module} ->
        {:ok, tracker} = Agent.start_link(fn -> %{tokens: QaAgent.empty_tokens(), messages: []} end)

        try do
          session_opts = session_opts(job, settings)
          {outcome, follow_up_turns} = start_and_run(agent_module, job, session_opts, tracker)
          %{outcome: outcome, follow_up_turns: follow_up_turns, tokens: Agent.get(tracker, & &1.tokens)}
        after
          Agent.stop(tracker)
        end

      {:error, reason} ->
        %{outcome: {:inconclusive, reason}}
    end
  end

  defp start_and_run(agent_module, job, session_opts, tracker) do
    case agent_module.start_session(job.worktree, session_opts) do
      {:ok, session} ->
        turn_opts = Keyword.put(session_opts, :on_message, on_message(tracker, Map.get(job, :token_limit), self()))

        try do
          run_turns(agent_module, session, prompt(job), job.issue, turn_opts, tracker, 0)
        catch
          :throw, {:gate_token_limit, total, limit} -> {{:inconclusive, {:gate_token_limit, total, limit}}, 0}
        after
          agent_module.stop_session(session)
        end

      {:error, reason} ->
        {{:inconclusive, {:gate_agent_failed, reason}}, 0}
    end
  end

  defp run_turns(agent_module, session, prompt, issue, turn_opts, tracker, follow_ups) do
    case agent_module.run_turn(session, prompt, issue, turn_opts) do
      {:ok, turn_result} ->
        messages = Agent.get_and_update(tracker, &{Enum.reverse(&1.messages), %{&1 | messages: []}})

        case parse_turn(turn_result, messages) do
          {:ok, answer} ->
            {{:answer, answer}, follow_ups}

          {:error, reason} when follow_ups < @max_follow_ups ->
            Logger.info("Acceptance gate agent answered without a verdict for #{issue.identifier}: #{inspect(reason)}; asking for it")
            turn_opts = Keyword.put(turn_opts, :resume_session_id, session_id(messages) || turn_opts[:resume_session_id])
            run_turns(agent_module, session, follow_up_prompt(), issue, turn_opts, tracker, follow_ups + 1)

          {:error, reason} ->
            {{:inconclusive, reason}, follow_ups}
        end

      {:error, {:model_api_unreachable, info}} ->
        {{:unavailable, info}, follow_ups}

      {:error, reason} ->
        {{:inconclusive, {:gate_agent_failed, reason}}, follow_ups}
    end
  end

  # The Claude runtime starts a new `claude -p` per turn, so the follow-up resumes the
  # conversation by id. Codex keeps its thread and ignores the option.
  defp session_id(messages) do
    Enum.find_value(Enum.reverse(messages), fn
      {:session_started, session_id} when is_binary(session_id) -> session_id
      _message -> nil
    end)
  end

  defp parse_turn(turn_result, messages) do
    turn_result
    |> ReviewAgent.response_candidates(Enum.reverse(messages))
    |> Enum.reduce_while({:error, {:malformed_gate_response, :empty_response}}, fn text, fallback ->
      case parse_response(text) do
        {:ok, _answer} = ok -> {:halt, ok}
        {:error, {:malformed_gate_response, :no_verdict_object}} -> {:cont, fallback}
        {:error, _reason} = error -> {:cont, error}
      end
    end)
  end

  # Records the session's token usage and stops the turn at the per-issue limit. The stop is a
  # throw, so it only fires in the process that runs the turn.
  defp on_message(tracker, token_limit, owner) do
    fn message ->
      usage = AgentTelemetry.extract_token_usage(message)

      tokens =
        Agent.get_and_update(tracker, fn state ->
          tokens = QaAgent.merge_usage(state.tokens, usage)
          {tokens, %{state | tokens: tokens, messages: [message | state.messages]}}
        end)

      if is_integer(token_limit) and tokens.total_tokens >= token_limit and self() == owner do
        throw({:gate_token_limit, tokens.total_tokens, token_limit})
      end

      :ok
    end
  end

  @doc "The follow-up prompt for an answer without a readable verdict object."
  @spec follow_up_prompt() :: String.t()
  def follow_up_prompt do
    """
    Your last answer did not include a valid JSON verdict object, and ending your turn ends the
    session. Return only the JSON object, in the shape from the first message, for what you have
    judged so far. Mark each criterion you could not judge `unclear`.
    """
  end

  @doc "The gate agent's prompt for `job`, with the context, the criteria and the escalation reasons already found."
  @spec prompt(map()) :: String.t()
  def prompt(%{issue: issue, context: context} = job) do
    """
    You are the acceptance gate agent in Symphony's Auto Review step.

    The executor agent opened a PR for this Linear issue, CI is green and QA has run. Decide whether
    the PR does what the ticket asks, judged on the change as it would land: the PR head
    `#{job.sha}` merged onto the current `#{context.base_branch}` (`#{context.base_sha}`). You are in a
    throwaway worktree at that merge result (`#{context.merged_sha}`). You are read-only: do not edit
    files, commit, push, open PRs, move the issue or post comments. Symphony records your verdict.

    Do not review code style or look for bugs: the pre-push reviewer did. A bug counts only when it
    makes an acceptance criterion unmet. Do not run the test suite, coverage or static analysis: CI
    ran them green.

    Issue:
    Identifier: #{issue.identifier}
    Title: #{PromptSafety.linear_issue_title(issue.title || "")}
    Description:
    #{PromptSafety.linear_issue_body(issue.description || "")}

    QA verdict: #{qa_line(Map.get(job, :qa))}

    Acceptance criteria to judge:
    #{criteria_lines(job.criteria)}

    Tickets that already exist around this one (its sub-issues, siblings, parent and blockers):
    #{existing_lines(Map.get(job, :existing_tickets, []))}

    Judge, in this order:
    1. Each acceptance criterion: `met`, `unmet` or `unclear`, with `file:line` evidence from the
       merged diff below or the worktree. Answer every criterion listed above, by its id.
    2. Conflicts and overlaps with the other open PRs in the table below: would landing both break
       either one?
    3. Scope: anything the ticket asks for that the PR is missing, and any change unrelated to it.
    4. Judgment calls a human must make: a product or UX decision, or ambiguous acceptance criteria.
       List each in `escalation_reasons`.

    Verdicts:
    - `approve`: every criterion is met, nothing in scope is missing, and nothing needs a human.
    - `rework`: a criterion is unmet or something the ticket asks for is missing; the executor can fix it.
    - `escalate`: a human must decide (see 4), or you can't tell.

    Put gaps that are real but outside this ticket in `follow_ups`. Symphony lists them, and when
    your verdict is enforced it files up to 3 of them as Backlog sub-issues. Before you add one,
    read the existing tickets listed above: when one of them already covers the gap, set
    `covered_by` to its identifier, and Symphony names that ticket instead of filing a copy. Give
    each new follow-up one or more `acceptance` criteria a reviewer can check once it is fixed:
    what a test or a check shows (for example "a test shows the poller reads only the changed
    runs"), never the title restated. Symphony adds "CI is green" itself, and files no follow-up
    without a checkable criterion.

    #{escalations_section(job.reasons)}Open PRs that change the same files:
    #{overlap_lines(context.overlaps)}

    Busy files on `#{context.base_branch}`: #{busy_line(context.busy_files)}

    Changed files (added/deleted lines):
    #{numstat_lines(context.numstat)}

    Merged diff against `#{context.base_branch}`#{if context.diff_truncated?, do: " (cut at 120 KB; read the rest in the worktree)", else: ""}:
    ```diff
    #{context.diff}
    ```

    Return ONLY one JSON object in this shape:
    {
      "verdict": "approve" | "rework" | "escalate",
      "summary": "<one or two sentences>",
      "criteria": [
        {"id": "<C1>", "criterion": "<the criterion>", "status": "met" | "unmet" | "unclear", "evidence": "<file:line and what it shows>"}
      ],
      "overlaps": [{"pr_url": "<url>", "detail": "<the conflict or overlap>"}],
      "scope": [{"kind": "missing" | "unrelated", "detail": "<what>"}],
      "escalation_reasons": ["<a decision a human must make>"],
      "follow_ups": [
        {"title": "<short title>", "detail": "<the out-of-scope gap>", "acceptance": ["<what a test or a check shows once it is fixed>"], "covered_by": "<identifier of the existing ticket that covers it>" | null}
      ]
    }
    """
  end

  defp qa_line(%{verdict: verdict} = qa) do
    case Map.get(qa, :reason) do
      reason when is_binary(reason) -> "#{verdict} (#{reason})"
      _none -> to_string(verdict)
    end
  end

  defp qa_line(_qa), do: "unknown"

  defp criteria_lines([]), do: "(none found under an Acceptance heading or in the workpad: derive them from the description, ids C1, C2, ...)"
  defp criteria_lines(criteria), do: Enum.map_join(criteria, "\n", &"- #{&1.id}: #{PromptSafety.linear_issue_body(&1.criterion)}")

  # Titles come back from `AgentTools.Linear.get_related_issues/2` already wrapped as untrusted data.
  defp existing_lines([]), do: "(none)"

  defp existing_lines(tickets) do
    Enum.map_join(tickets, "\n", fn ticket ->
      relation = Map.get(@relation_labels, ticket["relation"], ticket["relation"])
      "- #{ticket["identifier"]} (#{relation}, #{ticket["state"]}): #{ticket["title"]}"
    end)
  end

  defp escalations_section([]), do: ""

  defp escalations_section(reasons) do
    "Symphony's escalation rules already send this PR to a human, whatever you answer; judge it all the same:\n" <>
      Enum.map_join(reasons, "\n", &"- #{&1.rule}: #{&1.detail}") <> "\n\n"
  end

  defp overlap_lines([]), do: "(none)"

  defp overlap_lines(overlaps) do
    Enum.map_join(overlaps, "\n", fn overlap ->
      functions = Enum.map_join(overlap.functions, ", ", &"#{&1.path} #{&1.name}")
      "- #{overlap.pr_url} (#{overlap.issue_identifier || "untracked"}): files #{Enum.join(overlap.files, ", ")}#{if functions != "", do: "; functions #{functions}", else: ""}"
    end)
  end

  defp busy_line([]), do: "(none)"
  defp busy_line(files), do: Enum.join(files, ", ")

  defp numstat_lines([]), do: "(none)"
  defp numstat_lines(numstat), do: Enum.map_join(numstat, "\n", &"- #{&1.path} +#{&1.additions} -#{&1.deletions}")

  @doc "Parses the gate agent's answer."
  @spec parse_response(String.t() | nil) :: {:ok, answer()} | {:error, term()}
  def parse_response(text) when is_binary(text) do
    case Enum.find_value(ReviewAgent.json_object_candidates(text), &decode_verdict_object/1) do
      nil -> {:error, {:malformed_gate_response, :no_verdict_object}}
      decoded -> coerce_answer(decoded)
    end
  end

  def parse_response(_text), do: {:error, {:malformed_gate_response, :empty_response}}

  defp decode_verdict_object(candidate) do
    case Jason.decode(candidate) do
      {:ok, %{"verdict" => _verdict} = decoded} -> decoded
      _other -> nil
    end
  end

  defp coerce_answer(decoded) do
    with {:ok, verdict} <- one_of(Map.get(decoded, "verdict"), @verdicts, :invalid_verdict),
         {:ok, criteria} <- list_of(Map.get(decoded, "criteria"), &coerce_criterion/1, :invalid_criteria),
         {:ok, overlaps} <- list_of(Map.get(decoded, "overlaps"), &coerce_overlap/1, :invalid_overlaps),
         {:ok, scope} <- list_of(Map.get(decoded, "scope"), &coerce_scope/1, :invalid_scope),
         {:ok, follow_ups} <- list_of(Map.get(decoded, "follow_ups"), &coerce_follow_up/1, :invalid_follow_ups) do
      {:ok,
       %{
         verdict: verdict,
         summary: trimmed(Map.get(decoded, "summary")) || "",
         criteria: criteria,
         overlaps: overlaps,
         scope: scope,
         escalation_reasons: string_list(Map.get(decoded, "escalation_reasons")),
         follow_ups: follow_ups
       }}
    else
      {:error, reason} -> {:error, {:malformed_gate_response, reason}}
    end
  end

  defp one_of(value, allowed, error), do: if(value in allowed, do: {:ok, value}, else: {:error, error})

  defp list_of(nil, _coerce, _error), do: {:ok, []}

  defp list_of(values, coerce, error) when is_list(values) do
    coerced = Enum.map(values, coerce)
    if Enum.all?(coerced, &is_map/1), do: {:ok, coerced}, else: {:error, error}
  end

  defp list_of(_values, _coerce, error), do: {:error, error}

  defp coerce_criterion(%{"status" => status} = criterion) when status in @criterion_statuses do
    id = trimmed(Map.get(criterion, "id"))
    text = trimmed(Map.get(criterion, "criterion"))
    if id || text, do: %{id: id, criterion: text || "", status: status, evidence: trimmed(Map.get(criterion, "evidence")) || ""}
  end

  defp coerce_criterion(_criterion), do: nil

  defp coerce_overlap(%{"detail" => detail} = overlap) when is_binary(detail), do: %{pr_url: trimmed(Map.get(overlap, "pr_url")) || "", detail: String.trim(detail)}
  defp coerce_overlap(_overlap), do: nil

  defp coerce_scope(%{"kind" => kind, "detail" => detail}) when kind in @scope_kinds and is_binary(detail), do: %{kind: kind, detail: String.trim(detail)}
  defp coerce_scope(_scope), do: nil

  defp coerce_follow_up(%{"title" => title} = follow_up) when is_binary(title) do
    %{
      title: String.trim(title),
      detail: trimmed(Map.get(follow_up, "detail")) || "",
      acceptance: string_list(Map.get(follow_up, "acceptance")),
      covered_by: issue_identifier(Map.get(follow_up, "covered_by"))
    }
  end

  defp coerce_follow_up(_follow_up), do: nil

  defp issue_identifier(value) when is_binary(value) do
    identifier = value |> String.trim() |> String.upcase()
    if Regex.match?(~r/^[A-Z][A-Z0-9]*-\d+$/, identifier), do: identifier
  end

  defp issue_identifier(_value), do: nil

  @doc """
  The acceptance criteria the gate judges, numbered `C1`, `C2`, ...: the checklist items under
  the ticket's `Acceptance` or `Acceptance Criteria` headings, then the workpad's
  `### Acceptance Criteria` items the ticket doesn't already list.
  """
  @spec criteria(Issue.t(), Schema.t(), keyword()) :: [%{id: String.t(), criterion: String.t()}]
  def criteria(%Issue{} = issue, %Schema{} = settings, opts) do
    (checklist(issue.description, ~r/^acceptance( criteria)?:?$/i) ++ workpad_criteria(issue, settings, opts))
    |> Enum.reject(&(&1 == @bootstrap_criterion))
    |> Enum.uniq_by(&normalize/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {criterion, index} -> %{id: "C#{index}", criterion: criterion} end)
  end

  @doc "The checklist items under each heading of `markdown` whose text matches `heading`, up to the next heading."
  @spec checklist(String.t() | nil, Regex.t()) :: [String.t()]
  def checklist(markdown, heading) when is_binary(markdown) do
    {items, _collecting?} =
      markdown
      |> String.split(~r/\R/)
      |> Enum.reduce({[], false}, &checklist_line(&1, &2, heading))

    Enum.reverse(items)
  end

  def checklist(_markdown, _heading), do: []

  # A heading starts or stops collecting; a checklist item under a matching heading is kept.
  defp checklist_line(line, {items, collecting?}, heading) do
    case {Regex.run(~r/^\s{0,3}\#{1,6}\s+(.*?)[\s#]*$/, line), Regex.run(~r/^\s*[-*+]\s+\[[ xX]\]\s+(.+)$/, line)} do
      {[_line, title], _item} -> {items, Regex.match?(heading, title)}
      {nil, [_line, item]} when collecting? -> {[String.trim(item) | items], true}
      _other -> {items, collecting?}
    end
  end

  defp workpad_criteria(issue, %Schema{tracker: %{kind: "linear"}}, opts) do
    case AgentTools.Linear.get_comments(%{issue: issue}, @comment_limit, Keyword.take(opts, [:linear_client])) do
      {:ok, comments} ->
        comments
        |> Enum.map(&comment_body/1)
        |> Enum.find(fn body -> Enum.any?(@workpad_markers, &String.starts_with?(body, &1)) end)
        |> checklist(~r/^acceptance criteria$/i)

      {:error, reason} ->
        Logger.warning("Acceptance gate could not read the workpad for #{issue.identifier}: #{inspect(reason)}")
        []
    end
  end

  defp workpad_criteria(_issue, _settings, _opts), do: []

  # The ticket's family, listed in the prompt so the agent names an existing ticket rather than
  # proposing a copy of it. Reading it is best effort: the filing reads it again, and files nothing
  # when it can't (`SymphonyElixir.AcceptanceGate.FollowUps`).
  defp existing_tickets(issue, %Schema{tracker: %{kind: "linear"}}, opts) do
    case AgentTools.Linear.get_related_issues(%{issue: issue}, Keyword.take(opts, [:linear_client])) do
      {:ok, tickets} ->
        tickets

      {:error, reason} ->
        Logger.warning("Acceptance gate could not read the tickets related to #{issue.identifier}: #{inspect(reason)}")
        []
    end
  end

  defp existing_tickets(_issue, _settings, _opts), do: []

  # Comments come back wrapped in an untrusted-data tag.
  defp comment_body(%{"body" => body}) when is_binary(body) do
    body
    |> String.replace(~r/<\/?linear_[a-z_]+>/, "")
    |> String.trim()
  end

  defp comment_body(_comment), do: ""

  defp normalize(text), do: text |> String.downcase() |> String.replace(~r/[\s`*_]+/, " ") |> String.trim()

  defp agent_module(opts, kind) do
    case Keyword.get(opts, :gate_agent_module) do
      nil -> QaAgent.agent_module(kind)
      module -> {:ok, module}
    end
  end

  defp add_worktree(workspace, worktree, sha, git) do
    remove_worktree(workspace, worktree, git)
    File.mkdir_p!(Path.dirname(worktree))

    case Fetcher.with_lock(workspace, fn -> git.(["worktree", "add", "--detach", worktree, sha], workspace) end) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:gate_worktree_failed, status, String.trim(output)}}
    end
  end

  # The add and the remove run under the per-repo fetch lock: they write the
  # `.git/worktrees` the workspace shares with the source checkout and every
  # other worktree of it.
  defp remove_worktree(workspace, worktree, git) do
    Fetcher.with_lock(workspace, fn -> git.(["worktree", "remove", "--force", worktree], workspace) end)
    File.rm_rf(worktree)
    :ok
  end

  defp stop_leftover_processes(issue, roots, opts) do
    context = "issue_id=#{issue.id} issue_identifier=#{issue.identifier}"
    LeftoverProcesses.stop_under(roots, Keyword.put(Keyword.get(opts, :leftover_processes, []), :log_context, context))
  end

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)

  defp put_run(run_store, record) do
    case run_store.put_run(record) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to store the acceptance gate run run_id=#{record.run_id}: #{inspect(reason)}")
    end
  end

  defp update_run(run_store, repo_key, run_id, attrs) do
    case run_store.update_run(repo_key, run_id, attrs) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to update the acceptance gate run run_id=#{run_id}: #{inspect(reason)}")
    end
  end

  defp update_ci_check(run_store, record, attrs) do
    case run_store.update_ci_check(Map.get(record, :repo_key), Map.get(record, :issue_id), attrs) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to store the acceptance gate verdict issue_id=#{Map.get(record, :issue_id)}: #{inspect(reason)}")
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_value), do: nil

  defp string_list(values) when is_list(values), do: values |> Enum.map(&trimmed/1) |> Enum.reject(&is_nil/1)
  defp string_list(_values), do: []
end
