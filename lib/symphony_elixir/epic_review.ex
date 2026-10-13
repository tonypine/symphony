defmodule SymphonyElixir.EpicReview do
  @moduledoc """
  The `Epic Review` run: the automatic close of the designed machine's epic path.

  `docs/design/state-machine.md`: an epic parent waits in `Waiting on sub-tickets` while its
  sub-tickets are worked, and enters `Epic Review` by itself once every one of them is terminal.
  The poll loop does that move: the waiting state is active, so the moment the parent's children
  are terminal it is dispatched like any other ticket, with `SymphonyElixir.RunKind` classifying it
  `:epic_review`. This module turns that dispatch into the review. The tick is the recovery sweep
  as well: a run that already moved the parent into `Epic Review` and stopped is started again from
  there, and a start that finds the commit under review already decided replays that verdict rather
  than reviewing the same commit twice — and rather than filing its follow-ups a second time.

  The review is machine-owned, like the `QA` state's (`SymphonyElixir.QaVerification`): the machine runs the deterministic pre-checks,
  the agent pass and the verdict, and the agent never moves the ticket. It cannot: an agent has no
  tool that files a child in `Todo` (the Linear tool files in `Backlog`, where a follow-up would
  freeze the epic unnoticed), none that enters the waiting state, and none that records a verdict.

  What runs, in order:

    1. The **deterministic pre-checks** (`checks/2`) on the issue the dispatch read: every
       sub-issue terminal, and the epic's own comments, pull requests and checklist rows listed for
       the review to account for. The dispatch candidate can be stale, so the artifact check is
       made again here; an open child leaves the parent where it is, held by that child, and the
       tick starts the review again once the child lands (`:not_ready`).
    2. The **entry move** into the configured `Epic Review` state (`:epic_review_enter`), skipped
       when the parent is already there.
    3. The **agent pass**: `SymphonyElixir.QaAgent` in its epic-review mode, journey-driven, in a
       throwaway worktree at the head of the base branch — the epic's intent against what actually
       shipped on the default branch, with every checklist row reported.
    4. The **verdict**, through the one writer `SymphonyElixir.TransitionGuard`:
         * `pass` -> `Done` (`:epic_review_pass`);
         * `fail` (gaps) -> each failing step, or without failing steps each finding, is filed as a
           sub-issue in `Todo` inside the epic, and the parent returns to the waiting state
           (`:epic_review_gaps`), where the follow-up holds it until it lands. The review runs
           again when it does, so the epic closes itself once it is whole; the loop ends at the
           first pass.
         * `blocked` (tooling, environment, an answer that did not resolve the checklist, gaps none
           of which could be filed, or a run dispatched to a remote worker, where the designed flow
           does not run the QA agent) -> retried boundedly on the same commit, then handed to the
           self-heal lane (`SymphonyElixir.SelfHeal`), which classifies the block by its cause,
           files or reuses the fix ticket and holds the parent on it — no check and no decision for
           a person. A block only a person can clear keeps the access hold a person lifts.
    5. The **report**: one `## Symphony QA Report` on the epic, carrying the pre-checks, the steps,
       the tickets filed and the reason, so the epic's history says what the review checked and why
       it ended where it did.

  A legacy repo never reaches this module: `run/3` returns `:skip` for anything but a designed
  repo's epic parent, so the close-out run and the `Final verification:` flow are untouched.

  Every effect is injectable: `opts[:qa_agent]`, `opts[:tracker]`, `opts[:git]`,
  `opts[:linear_client]`, `opts[:store]` and `opts[:fixer]` default to the real ones and are fakes
  in tests.
  """

  require Logger

  alias SymphonyElixir.{
    AgentTools,
    Config,
    Handoff,
    QaVerification,
    SelfHeal,
    StateMachine,
    SubIssueWait,
    TicketSignals,
    TransitionGuard,
    Verification,
    Workspace
  }

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Linear.{Issue, TransientRetry}
  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.QaAgent.{Report, Selection}
  alias SymphonyElixir.Repo.Fetcher

  @verdict_kind "epic_review"
  # The state a follow-up the review files lands in. Never `Backlog`: a `Backlog` child does not
  # hold its parent, so a person would have to promote it and the epic would sit unnoticed.
  @gap_state "Todo"
  # The pre-checks that report what the review has to account for, after `:artifacts`.
  @evidence_checks [:artifacts, :comments, :pull_requests, :checklist]
  @label_prefix "qa:"
  @max_blocked_attempts 2
  @title_limit 120
  @details_limit 4_000
  # A list item (`- [ ] …`, `* …`, `1. …`) in the epic's description: a checklist row.
  @list_row ~r/^\s*(?:[-*+]|\d+[.)])\s+\S/m
  @unchecked_statuses ["skipped", "blocked"]
  @named_rows_limit 5
  # Longer than the review a lost verdict would redo, so a rate limit that outlasts the default
  # five-minute wait does not throw the verdict away.
  @verdict_move_max_wait_ms 30 * 60_000

  @typedoc "One deterministic pre-check: what it found and whether the review must account for it."
  @type check :: %{name: atom(), status: :ok | :attention, detail: String.t()}

  @doc """
  Runs the epic review for `issue` in its `workspace` when it applies, applies the outcome and
  returns `:ok`. Returns `:skip` when the ticket belongs to another run (the executor run, or
  another state's own), and `{:error, reason}` when the parent or the commit under review could not
  be read or the ticket could not be moved. A run that hit the provider's usage limit comes back as
  `{:error, {:usage_limited, info}}`, so the orchestrator holds it and starts it again once the
  limit resets.

  Options: `:settings` (required), `:repo_key`, `:run_id`, `:run_profile` (the dispatch's profile
  for this run kind), `:worker_host`, `:on_message`, `:linear_retry_opts`, and `:tracker`,
  `:qa_agent`, `:git`, `:linear_client`, `:store`, `:fixer`, `:symphony_repo_key` for tests.
  """
  @spec run(Issue.t(), Path.t(), keyword()) :: :skip | :ok | {:error, term()}
  def run(%Issue{} = issue, workspace, opts) when is_binary(workspace) do
    settings = Keyword.fetch!(opts, :settings)

    if epic_review_run?(issue, settings) do
      review(issue, workspace, opts, settings)
    else
      :skip
    end
  end

  def run(_issue, _workspace, _opts), do: :skip

  @doc """
  Whether `issue` is the ticket this module reviews: a designed repo's epic parent. That is a
  `breakdown` parent in the configured `Epic Review` state (the run that moved it there stopped),
  or one whose sub-issues are all terminal — the state the poll dispatches it from the moment its
  plan's children land. A parent in `Rework` is planning again, not closing out, and one with no
  sub-issues (or children still open) belongs to the executor run.
  """
  @spec epic_review_run?(Issue.t(), map()) :: boolean()
  def epic_review_run?(%Issue{} = issue, settings) do
    StateMachine.designed?(settings) and Issue.breakdown?(issue) and not Issue.replanning?(issue) and
      (in_state?(issue, state(settings)) or Issue.close_out_ready?(issue, terminal_states(settings)))
  end

  def epic_review_run?(_issue, _settings), do: false

  @doc "The configured `Epic Review` state name, or nil when the repo configures none."
  @spec state(map()) :: String.t() | nil
  def state(settings) do
    case Map.get(settings, :tracker) do
      %{epic_review_state: state} when is_binary(state) -> state
      _tracker -> nil
    end
  end

  @doc """
  The deterministic pre-checks the review runs before the agent pass.

  `{:ok, checks}` lists what the review must account for: every sub-issue terminal, the epic's own
  comments, the pull requests recorded on it, and the rows of its acceptance criteria and user
  walkthrough. A check whose status is `:attention` is not a failure — it is evidence the review
  has to answer, and it is recorded in the report.

  `{:not_ready, reason}` says the epic is not reviewable yet: a sub-issue is still open (a stale
  dispatch candidate). The parent is left where it is, so the tick starts the review again when the
  child really lands.
  """
  @spec checks(Issue.t(), map()) :: {:ok, [check()]} | {:not_ready, String.t()}
  def checks(%Issue{} = issue, settings) do
    case Issue.open_sub_issues(issue, terminal_states(settings)) do
      [] -> {:ok, Enum.map(@evidence_checks, &check(&1, issue))}
      open -> {:not_ready, "sub-issues still open: #{Enum.map_join(open, ", ", &sub_issue_label/1)}"}
    end
  end

  @doc "The state a follow-up the review files lands in: `Todo`, never `Backlog`."
  @spec follow_up_state() :: String.t()
  def follow_up_state, do: @gap_state

  defp review(issue, workspace, opts, settings) do
    case checks(issue, settings) do
      {:ok, checks} ->
        with :ok <- enter(issue, opts, settings) do
          review_epic(issue, workspace, opts, settings, checks)
        end

      {:not_ready, reason} ->
        not_ready(issue, reason)
    end
  end

  # A stale dispatch candidate: a sub-issue is open again, so the epic is not reviewable. Nothing is
  # moved and no verdict is recorded, and the open child holds the parent
  # (`SymphonyElixir.SubIssueWait` holds a parent whose started children are open), so the tick
  # starts the review again once the child lands.
  defp not_ready(issue, reason) do
    Logger.info("Not reviewing epic #{issue_label(issue)}: #{reason}")
    :ok
  end

  defp review_epic(issue, workspace, opts, settings, checks) do
    branch = Config.base_branch(repo_key(issue, opts))
    base_ref = "origin/" <> branch

    outcome =
      case Keyword.get(opts, :worker_host) do
        host when is_binary(host) ->
          blocked_outcome({:remote_worker_unsupported, host}, %{ref: base_ref, checks: checks})

        _local ->
          case base_commit(workspace, branch, git(opts)) do
            {:ok, sha} ->
              run_agent(issue, workspace, %{sha: sha, base_ref: base_ref}, settings, opts, checks)

            {:error, reason} ->
              blocked_outcome(reason, %{ref: base_ref, checks: checks, reason: unreachable_reason(base_ref, reason)})
          end
      end

    case outcome do
      %{usage_limit: info} ->
        Logger.info("Epic review for #{issue_label(issue)} hit the usage limit; the epic keeps its state and runs again once the hold lifts")

        {:error, {:usage_limited, info}}

      outcome ->
        apply_outcome(issue, outcome, settings, opts)
    end
  end

  # A block carries both the human-readable reason the report shows and the raw cause, which is what
  # the self-heal lane classifies the block by: a dev-server or worker-host block belongs to the repo
  # or host it happened on, not to Symphony. `attrs` wins on `:reason` for a block whose reason is
  # its own (an unreadable base branch), not the agent's.
  defp blocked_outcome(cause, attrs) do
    %{verdict: :blocked, sha: nil, cause: cause, reason: QaAgent.blocked_reason(cause)}
    |> Map.merge(attrs)
  end

  defp unreachable_reason(base_ref, reason), do: "could not read the head of #{base_ref}: #{inspect(reason)}"

  # The commit the review judges is the base branch head: the merged result of the epic's
  # sub-tickets, which is what the epic's intent is checked against. It is fetched into the
  # workspace that hosts the run.
  defp base_commit(workspace, branch, git) do
    with {_output, 0} <- Fetcher.fetch(workspace, fn -> git.(["fetch", "--quiet", "origin", branch], workspace) end),
         {sha, 0} <- git.(["rev-parse", "--verify", "refs/remotes/origin/#{branch}^{commit}"], workspace) do
      {:ok, String.trim(sha)}
    else
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  end

  # The parent enters `Epic Review` before the agent pass, so the board shows the review underway
  # while it runs. The edge's origin is the waiting state; a parent already in `Epic Review` is a
  # recovery run and is not moved again.
  defp enter(issue, opts, settings) do
    if in_state?(issue, state(settings)) do
      :ok
    else
      move(issue, settings, opts, :epic_review_enter, %{reason: "every sub-issue is terminal"})
    end
  end

  defp run_agent(issue, workspace, context, settings, opts, checks) do
    started_at = System.monotonic_time(:second)

    case carried_outcome(issue, settings, opts, context.sha) do
      %{} = outcome ->
        Map.merge(outcome, %{ref: context.base_ref, checks: checks, runtime_seconds: System.monotonic_time(:second) - started_at})

      nil ->
        playbooks = playbooks(issue, settings)
        job = agent_job(issue, workspace, context, settings, opts, playbooks)
        runtime = fn -> System.monotonic_time(:second) - started_at end

        case Keyword.get(opts, :qa_agent, QaAgent).run(job, settings, agent_opts(opts)) do
          {:ok, %{result: result, tokens: tokens}} ->
            result
            |> run_outcome(tokens, playbooks, checks)
            |> Map.merge(%{sha: context.sha, ref: context.base_ref, runtime_seconds: runtime.()})

          {:error, reason, tokens} ->
            reason
            |> error_outcome(tokens, checks)
            |> Map.merge(%{
              sha: context.sha,
              ref: context.base_ref,
              playbooks: playbook_kinds(playbooks),
              runtime_seconds: runtime.()
            })
        end
    end
  end

  defp agent_job(issue, workspace, %{sha: sha, base_ref: base_ref}, settings, opts, playbooks) do
    %{
      issue: issue,
      # The QA agent's epic-review mode: the epic itself is the issue under test, at the head of the
      # base branch, with its checklist rows as required steps.
      epic_review: true,
      base_ref: base_ref,
      sha: sha,
      workspace_path: workspace,
      repo_key: repo_key(issue, opts),
      run_id: Keyword.get(opts, :run_id) || "epic-review-#{issue.identifier}-#{String.slice(sha, 0, 12)}",
      playbooks: playbooks,
      token_limit: settings.agent.max_tokens_per_issue,
      run_profile: Keyword.get(opts, :run_profile),
      journey: QaVerification.journey(issue, "the epic")
    }
  end

  defp agent_opts(opts), do: Keyword.take(opts, [:git, :linear_client, :on_message])

  # A verdict already recorded for the commit under review is this epic's verdict: the run that
  # earned it moved the parent on, or stopped between the verdict and the move and the tick started
  # the review again. Reviewing the same commit twice would spend an agent run, could answer
  # differently on unchanged code, and — for a `fail` — would file its follow-ups a second time, so
  # the verdict is carried instead.
  #
  # A `fail` is carried only while the parent is still in `Epic Review`: the run that recorded it is
  # the one whose move did not land, and its follow-ups are already in `Todo`. Back in the waiting
  # state that run is over — its move landed — so a parent that reaches the review again carries a
  # change (a follow-up cancelled, the epic's children terminal once more) that deserves a fresh
  # judgement.
  defp carried_outcome(issue, settings, opts, sha) do
    case verdict_for_commit(issue, opts, sha) do
      %{outcome: "pass"} ->
        carried_outcome_for(issue, :pass, sha)

      %{outcome: "fail"} ->
        if in_state?(issue, state(settings)), do: carried_outcome_for(issue, :fail, sha)

      _other ->
        nil
    end
  end

  defp carried_outcome_for(issue, verdict, sha) do
    Logger.info("Epic review carried the earlier #{verdict} for #{issue_label(issue)} commit=#{sha}; not reviewing again")

    %{
      verdict: verdict,
      carried: true,
      summary: carried_summary(verdict),
      steps: [],
      findings: [],
      reason: nil,
      needs_person: false,
      sha: sha
    }
  end

  defp carried_summary(:pass), do: "carried forward: this commit's epic review already passed"
  defp carried_summary(:fail), do: "carried forward: this commit's gaps were already filed as follow-ups"

  defp apply_outcome(issue, outcome, settings, opts) do
    case check_checklist(outcome, issue) do
      %{verdict: :pass} = outcome -> pass(issue, outcome, settings, opts)
      %{verdict: :fail} = outcome -> gaps(issue, outcome, settings, opts)
      %{verdict: :blocked} = outcome -> blocked(issue, outcome, settings, opts)
      %{verdict: verdict} -> {:error, {:epic_review_unknown_verdict, verdict}}
    end
  end

  defp pass(issue, outcome, settings, opts) do
    # A carried pass is the one already recorded for this commit: recording it again would leave
    # two verdicts for one review.
    unless carried?(outcome), do: record_verdict(issue, opts, outcome.sha, "pass")
    publish_report(issue, outcome, "Done", [], opts)
    Logger.info("Epic review passed for #{issue_label(issue)} commit=#{outcome.sha}")

    move(issue, settings, opts, :epic_review_pass, %{reason: verdict_reason(outcome, "every checklist row verified")})
  end

  # The gaps the review found become sub-issues of the epic in `Todo`, and the parent goes back to
  # the waiting state, where they hold it until they land: the epic reviews itself again then, so
  # the flow closes at the first pass. A set of gaps none of which could be filed is not a fail —
  # the epic would wait on nothing and the review would start again at once on the same gaps — so it
  # is a block, and the self-heal lane takes it.
  defp gaps(issue, outcome, settings, opts) do
    if carried?(outcome) do
      # The run that recorded this commit's fail filed its follow-ups and could not move the parent.
      # Filing them again would duplicate them, so the recovery run only retries the move.
      Logger.info("Epic review carried the earlier gaps for #{issue_label(issue)} commit=#{outcome.sha}; not filing them again")
      publish_report(issue, outcome, waiting_state(settings), [], opts)

      move(issue, settings, opts, :epic_review_gaps, %{reason: verdict_reason(outcome, "the review found gaps"), carried: true})
    else
      file_gaps(issue, outcome, settings, opts)
    end
  end

  defp file_gaps(issue, outcome, settings, opts) do
    case create_gaps(issue, outcome, opts) do
      [] ->
        blocked(issue, %{outcome | verdict: :blocked, reason: unfiled_reason(outcome)}, settings, opts)

      filed ->
        record_verdict(issue, opts, outcome.sha, "fail")
        publish_report(issue, outcome, waiting_state(settings), filed, opts)
        Logger.warning("Epic review found gaps for #{issue_label(issue)} commit=#{outcome.sha}: #{length(filed)} follow-up(s) filed")

        move(issue, settings, opts, :epic_review_gaps, %{reason: verdict_reason(outcome, "the review found gaps"), filed: length(filed)})
    end
  end

  defp carried?(outcome), do: Map.get(outcome, :carried, false)

  defp unfiled_reason(outcome) do
    "the epic review found gaps but could not file any follow-up for them: " <> verdict_reason(outcome, "no gap was named")
  end

  # A blocked run is retried boundedly on the same commit: a transient environment or tooling
  # failure says nothing about the epic. Once the attempts are used up the block goes to the
  # self-heal lane, which files or reuses the fix ticket for the broken component, holds the epic on
  # it, and resumes the review by itself when the fix lands — or, for a block only a person can
  # clear, takes the access hold a person lifts. Either way the epic pauses in `Epic Review` rather
  # than stopping silently.
  defp blocked(issue, outcome, settings, opts) do
    record_verdict(issue, opts, outcome.sha, "blocked")
    attempts = blocked_attempts(issue, opts, outcome.sha)
    retry? = retry_blocked?(attempts, outcome)
    publish_report(issue, outcome, blocked_target(settings, retry?), [], opts)

    if retry? do
      Logger.warning("Epic review blocked for #{issue_label(issue)} commit=#{outcome.sha} (attempt #{attempts}/#{@max_blocked_attempts}); retrying")

      :ok
    else
      self_heal(issue, opts, attempts, outcome)
    end
  end

  defp self_heal(issue, opts, attempts, outcome) do
    heal_opts =
      [outcome: outcome, attempts: attempts, repo_key: repo_key(issue, opts)] ++
        Keyword.take(opts, [:store, :tracker, :fixer, :symphony_repo_key])

    case SelfHeal.heal(issue, heal_opts) do
      {:error, reason} -> {:error, {:epic_review_self_heal_failed, reason}}
      _action -> :ok
    end
  end

  defp retry_blocked?(attempts, outcome), do: attempts < @max_blocked_attempts and not needs_person?(outcome)

  defp blocked_target(settings, true), do: "#{state(settings) || "Epic Review"} (blocked, retrying)"
  defp blocked_target(settings, false), do: "#{state(settings) || "Epic Review"} (blocked)"

  defp blocked_attempts(issue, opts, sha) do
    issue
    |> verdicts(opts)
    |> Enum.count(&(&1.head_sha == sha and &1.outcome == "blocked"))
  end

  defp needs_person?(%{needs_person: true}), do: true
  defp needs_person?(_outcome), do: false

  # Each gap the review found becomes one follow-up sub-issue of the epic, in `Todo`: the failing
  # steps when there are any, else the findings. They are filed through the machine-side child
  # creator (`SymphonyElixir.AgentTools.Linear.create_subissue_in_state/4`), the one the executor's
  # `linear_create_subissue` tool is built on, so a follow-up is scoped exactly like any other
  # sub-ticket of the epic — same team, project, assignee and parent — and never lands in
  # `Backlog`, where it would not hold the epic.
  defp create_gaps(issue, outcome, opts) do
    {:ok, registry} = CommentRegistry.start_link()
    context = %{issue: issue, comment_registry: registry}

    try do
      outcome
      |> gap_tickets(issue)
      |> Enum.flat_map(fn {title, description} ->
        attrs = %{"title" => title, "description" => description}
        create = fn -> AgentTools.Linear.create_subissue_in_state(context, @gap_state, attrs, linear_opts(opts)) end

        case with_linear_retry(create, "filing an epic review follow-up for #{issue.identifier}", opts) do
          {:ok, response} ->
            [%{identifier: get_in(response, ["data", "issueCreate", "issue", "identifier"]), title: title}]

          {:error, reason} ->
            Logger.warning("Failed to file an epic review follow-up for #{issue.identifier}: #{inspect(reason)}")
            []
        end
      end)
    after
      Agent.stop(registry)
    end
  end

  defp gap_tickets(outcome, issue) do
    case Enum.filter(Map.get(outcome, :steps, []), &(&1.status == "fail")) do
      [] -> Enum.map(Map.get(outcome, :findings, []), &finding_ticket(&1, outcome, issue))
      failed -> Enum.map(failed, &step_ticket(&1, outcome, issue))
    end
  end

  defp step_ticket(step, outcome, issue) do
    body = """
    #{ticket_intro(outcome, issue)}

    ## Failing step

    #{step.name}

    ```text
    #{fence_safe(step.details)}
    ```

    ## Evidence

    #{evidence_list(step.evidence)}

    ## Acceptance criteria

    - [ ] The step "#{step.name}" behaves as #{issue.identifier} describes on the default branch.
    - [ ] The epic's review passes this step when it runs #{issue.identifier} again.
    """

    {title("Epic review fails: " <> step.name), body}
  end

  defp finding_ticket(finding, outcome, issue) do
    body = """
    #{ticket_intro(outcome, issue)}

    ## Finding

    #{finding}

    ## Evidence

    #{outcome |> Map.get(:steps, []) |> Enum.flat_map(& &1.evidence) |> evidence_list()}

    ## Acceptance criteria

    - [ ] The finding above is fixed on the default branch.
    - [ ] The epic's review passes when it runs #{issue.identifier} again.
    """

    {title("Epic review finding: " <> first_line(finding)), body}
  end

  defp ticket_intro(outcome, issue) do
    "The epic review of #{issue.identifier}#{url_suffix(issue)} failed on commit " <>
      "`#{short_sha(outcome.sha)}` (head of `#{outcome.ref}`). The full report is on #{issue.identifier}."
  end

  defp url_suffix(%Issue{url: url}) when is_binary(url), do: " (#{url})"
  defp url_suffix(_issue), do: ""

  # A follow-up is only ever filed from an outcome the agent answered, and every one of those carries
  # the sha the review read from the base branch.
  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)

  # The checklist is the epic's own definition of done, so a `pass` that reports none of its rows,
  # or skipped most of them, verified nothing (the rule TP-545 set for the final verification). It
  # is not a pass but a block: retried boundedly, then handed to the self-heal lane, which takes it
  # to a person when only a person can clear it.
  # A carried pass has no steps of its own: the checklist was resolved by the review that earned
  # it, and re-judging an empty answer would block an epic that is already done.
  defp check_checklist(%{carried: true} = outcome, _issue), do: outcome

  defp check_checklist(%{verdict: :pass} = outcome, issue) do
    rows = outcome |> Map.get(:steps, []) |> Enum.filter(&Map.get(&1, :checklist, false))
    unchecked = Enum.filter(rows, &(&1.status in @unchecked_statuses))

    cond do
      not checklist?(issue) -> outcome
      rows == [] -> unchecked_checklist(outcome, "The epic review answered pass without a verdict on any row of #{issue.identifier}'s checklist")
      length(unchecked) * 2 > length(rows) -> unchecked_checklist(outcome, skipped_rows_reason(issue, rows, unchecked))
      true -> outcome
    end
  end

  defp check_checklist(outcome, _issue), do: outcome

  defp unchecked_checklist(outcome, reason) do
    reason =
      reason <>
        ". The epic review passes only once its checklist rows are checked: check them, or run the epic " <>
        "review again."

    Map.merge(outcome, %{verdict: :blocked, reason: reason})
  end

  defp skipped_rows_reason(issue, rows, unchecked) do
    {named, rest} = Enum.split(unchecked, @named_rows_limit)
    more = if rest == [], do: "", else: " and #{length(rest)} more"

    "The epic review answered pass but did not check #{length(unchecked)} of the #{length(rows)} rows of " <>
      "#{issue.identifier}'s checklist: #{Enum.map_join(named, "; ", & &1.name)}#{more}"
  end

  # Every move goes through the one writer. The entry move's origin is the waiting state, the pass
  # and gaps moves' is `Epic Review`; the table in `SymphonyElixir.TransitionGuard` defines those
  # edges and is tested directly.
  defp move(issue, settings, opts, signal, extra) do
    ctx = Map.merge(%{settings: settings}, extra)
    target = TransitionGuard.target(signal, ctx)
    move = fn -> TransitionGuard.perform(issue.id, signal, ctx, tracker_opts(opts)) end

    case with_linear_retry(move, "moving #{issue.identifier} to #{target} after its epic review", verdict_move_opts(opts)) do
      :ok ->
        record_move_signal(issue, opts, signal, Map.put(extra, :target, target))
        :ok

      {:error, reason} ->
        {:error, {:epic_review_move_failed, signal, reason}}
    end
  end

  defp tracker_opts(opts) do
    case Keyword.get(opts, :tracker) do
      nil -> []
      tracker -> [tracker: tracker]
    end
  end

  defp record_verdict(issue, opts, sha, outcome) do
    TicketSignals.record_verdict(repo_key(issue, opts), issue.id, @verdict_kind, sha, outcome)
  end

  defp record_move_signal(issue, opts, signal, extra) do
    details =
      extra
      |> Map.take([:target, :reason, :carried, :filed])
      |> Map.put(:signal, to_string(signal))

    TicketSignals.record(repo_key(issue, opts), issue.id, @verdict_kind, details)
  end

  # The newest verdict bound to the commit under review, or nil. A `pass` bound to it is carried
  # (`carried_outcome/4`); a `blocked` one counts toward the bounded retry.
  defp verdict_for_commit(issue, opts, sha) do
    issue
    |> verdicts(opts)
    |> Enum.find(&(&1.head_sha == sha))
  end

  defp verdicts(issue, opts), do: Handoff.verdicts(repo_key(issue, opts), issue.id, @verdict_kind)

  defp publish_report(issue, outcome, target_state, filed, opts) do
    report =
      outcome
      |> Map.merge(%{target_state: target_state, target_issue: issue.identifier, filed: filed})
      |> Report.render()

    case Report.publish(issue, report, Keyword.take(opts, [:linear_client, :settings])) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to publish the epic review report for #{issue_label(issue)}: #{inspect(reason)}")
    end
  end

  defp run_outcome(result, tokens, playbooks, checks) do
    %{
      verdict: result.verdict,
      summary: result.summary,
      steps: Map.get(result, :steps, []),
      findings: Map.get(result, :findings, []),
      reason: Map.get(result, :reason),
      needs_person: Map.get(result, :needs_person, false),
      tokens: tokens,
      playbooks: playbook_kinds(playbooks),
      checks: checks
    }
  end

  # An agent that could not run at all: a usage limit holds the ticket and starts it again once the
  # limit resets, anything else is a block (retried boundedly, then self-healed, which classifies the
  # block by its cause — `SymphonyElixir.SelfHeal`).
  defp error_outcome(reason, tokens, checks) do
    case QaAgent.usage_limit(reason) do
      %{} = info ->
        %{usage_limit: info}

      nil ->
        %{verdict: :blocked, cause: reason, reason: QaAgent.blocked_reason(reason), tokens: tokens, checks: checks}
    end
  end

  defp playbooks(issue, settings) do
    playbooks = Selection.playbooks(settings.auto_review, dev_server?: Verification.dev_server_configured?(settings))
    labels = labels(issue)

    case Enum.filter(playbooks, &((@label_prefix <> &1.kind) in labels)) do
      [] -> playbooks
      labelled -> labelled
    end
  end

  defp labels(issue), do: issue |> Issue.label_names() |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

  defp playbook_kinds(playbooks), do: Enum.map(playbooks, & &1.kind)

  defp check(:artifacts, %Issue{sub_issues: sub_issues}) do
    count = length(List.wrap(sub_issues))

    %{name: :artifacts, status: :ok, detail: "all #{count} sub-issue(s) terminal"}
  end

  defp check(:comments, %Issue{} = issue) do
    comments = List.wrap(issue.comments)

    case comments do
      [] -> %{name: :comments, status: :ok, detail: "no comment on the epic to account for"}
      _comments -> %{name: :comments, status: :attention, detail: "#{length(comments)} comment(s) to account for, the newest from #{comment_author(List.last(comments))}"}
    end
  end

  defp check(:pull_requests, issue) do
    urls = pull_request_urls(issue)

    case urls do
      [] -> %{name: :pull_requests, status: :ok, detail: "no pull request of the epic's own: its sub-tickets carry theirs"}
      urls -> %{name: :pull_requests, status: :attention, detail: "#{length(urls)} pull request(s) recorded on the epic: #{Enum.join(urls, ", ")}"}
    end
  end

  defp check(:checklist, %Issue{} = issue) do
    case checklist_rows(issue) do
      0 -> %{name: :checklist, status: :attention, detail: "no checklist row in the epic's description: the review derives them from it"}
      count -> %{name: :checklist, status: :ok, detail: "#{count} checklist row(s) for the review to resolve"}
    end
  end

  defp comment_author(%{author: author}) when is_binary(author) and author != "", do: author
  defp comment_author(_comment), do: "unknown"

  defp pull_request_urls(issue) do
    [Map.get(issue, :pull_request_url) | List.wrap(Map.get(issue, :pr_urls))]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp checklist_rows(%Issue{} = issue), do: count_rows(issue.description)

  defp count_rows(description) when is_binary(description), do: length(Regex.scan(@list_row, description))
  defp count_rows(_description), do: 0

  defp checklist?(%Issue{} = issue), do: checklist_rows(issue) > 0

  defp terminal_states(settings) do
    case Map.get(settings, :tracker) do
      %{terminal_states: states} when is_list(states) -> states
      _tracker -> []
    end
  end

  defp waiting_state(settings), do: SubIssueWait.state(settings)

  defp in_state?(%Issue{state: state}, expected) when is_binary(state) and is_binary(expected),
    do: normalize_state(state) == normalize_state(expected)

  defp in_state?(_issue, _expected), do: false

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()

  defp sub_issue_label(sub_issue), do: Map.get(sub_issue, :identifier) || Map.get(sub_issue, :id)

  defp verdict_reason(%{findings: [first | _]}, _default) when is_binary(first), do: first
  defp verdict_reason(%{reason: reason}, _default) when is_binary(reason) and reason != "", do: reason
  defp verdict_reason(_outcome, default), do: default

  defp evidence_list([]), do: "The review recorded no evidence for this; see the step details."
  defp evidence_list(links), do: Enum.map_join(links, "\n", &("- " <> &1))

  defp fence_safe(text) do
    text = text |> to_string() |> String.replace("```", "'''")

    if byte_size(text) > @details_limit, do: binary_part(text, 0, @details_limit) <> "\n[... truncated ...]", else: text
  end

  defp first_line(text), do: text |> to_string() |> String.split("\n", parts: 2) |> hd()

  defp title(text), do: text |> String.slice(0, @title_limit) |> String.trim()

  defp git(opts), do: Keyword.get(opts, :git, &default_git/2)

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)

  defp linear_opts(opts), do: Keyword.take(opts, [:linear_client])

  # A caller's own `:max_wait_ms` still wins.
  defp verdict_move_opts(opts) do
    Keyword.update(
      opts,
      :linear_retry_opts,
      [max_wait_ms: @verdict_move_max_wait_ms],
      &Keyword.put_new(&1, :max_wait_ms, @verdict_move_max_wait_ms)
    )
  end

  defp with_linear_retry(fun, label, opts) do
    TransientRetry.run(fun, opts |> Keyword.get(:linear_retry_opts, []) |> Keyword.put(:label, label))
  end

  defp repo_key(issue, opts), do: Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)

  defp issue_label(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_label(%Issue{id: id}), do: inspect(id)
end
