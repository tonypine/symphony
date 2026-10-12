defmodule SymphonyElixir.QaVerification do
  @moduledoc """
  The `QA` state's verification run.

  A designed repo's `QA` ticket is dispatched by the poll loop like any other active ticket; this
  module turns that dispatch into a QA pass instead of an executor run. It re-homes the QA
  machinery the Auto Review step uses (`SymphonyElixir.QaAgent` and its playbook selection,
  `SymphonyElixir.Verification`'s dev server) into the designed flow's QA state, so a designed repo
  runs exactly the same QA agent, on the change's own worktree, from the user's point of view.

  The run is only ever started on a green head (the orchestrator gates dispatch on the ticket's
  recorded CI state) and its verdict is recorded bound to the head SHA it judged, then performed
  through the one writer, `SymphonyElixir.TransitionGuard`:

    * `pass` -> `Merging`
    * `fail` -> `Rework`, with the report on the ticket for the next run
    * skip (the deterministic docs-only/internal-only rule, `SymphonyElixir.QaPolicy`) -> `Merging`
    * `blocked` (tooling or environment) -> retried boundedly on the same head, then a Blocked hold
      with the reason recorded

  QA is journey-driven: the prompt carries the ticket's user walkthrough and acceptance criteria
  (the epic plan, where one exists, is the parent the QA agent reads with its Linear tools), and the
  agent judges the outcome as a careful engineer testing their own feature, not by executing a
  script. A legacy repo never reaches this module: `run/3` returns `:skip` for anything but a
  designed repo's `QA` ticket, so the Auto Review path is untouched.
  """

  require Logger

  alias SymphonyElixir.{
    Handoff,
    MergeConfirmation,
    QaPolicy,
    SelfHeal,
    StateMachine,
    TicketSignals,
    TransitionGuard,
    WorkspaceHead
  }

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.QaAgent.Report

  @verdict_kind "qa"
  @max_blocked_attempts 2
  @head_unreadable_signal "qa_head_unreadable"
  @walkthrough_heading ~r/^\s*\#{1,6}\s+User walkthrough\s*:?\s*$/i
  @acceptance_heading ~r/^\s*\#{1,6}\s+Acceptance criteria\s*:?\s*$/i
  @any_heading ~r/^\s*\#{1,6}\s+\S/

  @doc """
  Runs the QA agent for `issue` when it is a designed repo's `QA` ticket, else `:skip` so the
  caller falls through to the executor run. `opts[:qa_agent]`, `opts[:qa_policy]` and
  `opts[:tracker]` override the agent, the skip policy and the tracker (tests, a fake).
  """
  @spec run(Issue.t(), Path.t(), keyword()) :: :skip | :ok | {:error, term()}
  def run(%Issue{} = issue, workspace, opts) when is_binary(workspace) do
    settings = Keyword.fetch!(opts, :settings)

    if qa_run?(issue, settings) do
      verify(issue, workspace, opts, settings)
    else
      :skip
    end
  end

  def run(_issue, _workspace, _opts), do: :skip

  @doc """
  Whether `issue` is the ticket this module verifies: a designed repo's configured QA state. Every
  other ticket belongs to the executor run (or another state's own run).
  """
  @spec qa_run?(Issue.t(), map()) :: boolean()
  def qa_run?(%Issue{state: state}, settings) when is_binary(state) do
    StateMachine.designed?(settings) and
      normalize_state(state) == normalize_state(settings.tracker.qa_state)
  end

  def qa_run?(_issue, _settings), do: false

  @doc """
  Re-binds this module's carrying verdict — a `pass` — to `head`, so a mechanical CI Fix that pushed
  a new commit leaves the pass valid on the head the ticket now has instead of invalidating it
  (`SymphonyElixir.CiFix`). The ticket's newest `qa` verdict must be the pass: a newer `fail` or
  `blocked` is the verdict, and nothing is carried.

  Best-effort, like every ledger write, and a no-op when the pass already binds to `head` or there is
  no head to bind it to.
  """
  @spec carry_verdict(String.t() | nil, String.t() | nil, String.t() | nil) :: :ok
  def carry_verdict(repo_key, issue_id, head) do
    case latest_verdict(repo_key, issue_id) do
      %{outcome: "pass", head_sha: judged} when is_binary(head) and judged != head ->
        TicketSignals.record_verdict(repo_key, issue_id, @verdict_kind, head, "pass")
        :ok

      _no_carry ->
        :ok
    end
  end

  @doc """
  The journey context for `issue`: its `## User walkthrough` when it has one, else its acceptance
  criteria, else nothing but the instruction to derive them. The QA prompt renders this, so the run
  knows what to verify from the user's point of view.

  `label` names whose plan the journeys come from in the source phrase: the ticket for the QA
  state's own run (the default), and the epic for the epic review of a designed repo's plan parent
  (`SymphonyElixir.EpicReview`), so the prompt reads right about which issue carries them.
  """
  @spec journey(Issue.t(), String.t()) :: %{source: String.t(), text: String.t() | nil}
  def journey(issue, label \\ "the ticket"), do: journey_for(issue, label)

  defp journey_for(%Issue{description: description}, label) when is_binary(description) do
    cond do
      text = section(description, @walkthrough_heading) ->
        %{source: "#{label}'s `## User walkthrough`", text: text}

      text = section(description, @acceptance_heading) ->
        %{source: "#{label}'s acceptance criteria", text: text}

      true ->
        %{source: "#{label}'s walkthrough and acceptance criteria", text: nil}
    end
  end

  defp journey_for(_issue, label), do: %{source: "#{label}'s walkthrough and acceptance criteria", text: nil}

  defp verify(issue, workspace, opts, settings) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) -> remote_worker_unsupported(issue, opts, settings, host)
      _local -> read_head(issue, workspace, opts, settings)
    end
  end

  # The QA agent runs where the workspace lives, and the designed flow never runs it on an SSH
  # worker. There is no local head to read there either, so the run is blocked with the reason
  # (retried boundedly, then a Blocked hold) rather than parking on an unreadable head forever.
  defp remote_worker_unsupported(issue, opts, settings, host) do
    blocked(issue, opts, settings, nil, blocked_outcome({:remote_worker_unsupported, host}, %{}))
  end

  defp read_head(issue, workspace, opts, settings) do
    case WorkspaceHead.read(workspace, nil) do
      nil -> park_unreadable_head(issue, opts)
      head -> verify_head(issue, workspace, opts, settings, head)
    end
  end

  # A verdict binds to a head SHA; with no head to bind to, the run says so once and leaves the
  # ticket where it is, so the next tick can try again rather than record a verdict on nothing.
  defp park_unreadable_head(issue, opts) do
    unless head_unreadable_recorded?(issue, opts) do
      TicketSignals.record(repo_key(issue, opts), issue.id, @head_unreadable_signal, %{})
    end

    Logger.warning("Not verifying #{issue_label(issue)}: its workspace head could not be read")

    :ok
  end

  defp head_unreadable_recorded?(issue, opts) do
    repo_key(issue, opts)
    |> Handoff.signals(issue.id)
    |> Enum.any?(&(&1.name == @head_unreadable_signal))
  end

  defp verify_head(issue, workspace, opts, settings, head) do
    if carried_pass?(issue, opts, head) do
      carry(issue, opts, settings, head)
    else
      decide(issue, workspace, opts, settings, head)
    end
  end

  defp decide(issue, workspace, opts, settings, head) do
    policy = Keyword.get(opts, :qa_policy, QaPolicy)

    case policy.decide(issue, settings, workspace: workspace, repo_key: repo_key(issue, opts)) do
      {:skip, reason} -> skip(issue, opts, settings, head, reason)
      {:run, playbooks, _reason} -> run_agent(issue, workspace, opts, settings, head, playbooks)
    end
  end

  # A pass already valid on this head is the ticket's verdict, so no second QA run happens. That is
  # how a mechanical CI Fix's return is carried forward: the lane re-binds the pass it carries to
  # whatever head the repair left (`SymphonyElixir.CiFix.carry_verdict/5`), and this module carries
  # the ticket on instead of verifying it again. The run/skip policy is not consulted: the pass
  # already decided the journey, and the report says the pass was carried rather than re-earned.
  defp carried_pass?(issue, opts, head) do
    case verdict_for_head(repo_key(issue, opts), issue.id, head) do
      %{outcome: "pass"} -> true
      _none -> false
    end
  end

  defp carry(issue, opts, settings, head) do
    Logger.info("QA carried the earlier pass for #{issue_label(issue)} head=#{head}; not verifying again")
    publish_report(issue, opts, head, carried_outcome(), "Merging")

    merge_entry(issue, opts, settings, :qa_pass, %{reason: "the earlier QA pass still covers this head", carried: true}, %{
      recommendation: "the earlier QA pass still covers this head; ready to merge",
      qa: "carried forward: QA already passed this change; the repair that followed was mechanical"
    })
  end

  defp carried_outcome do
    %{
      verdict: :pass,
      summary: "carried forward: QA already passed this change; the repair that followed was mechanical and re-bound the pass to the new head",
      steps: [],
      findings: [],
      reason: nil,
      needs_person: false,
      playbooks: []
    }
  end

  # The same hybrid skip rule the Code Review verdict applied, seen from the QA state: a docs-only
  # or internal-only diff lands in `Merging` with the reason recorded, and no agent runs.
  defp skip(issue, opts, settings, head, reason) do
    record_verdict(issue, opts, head, "skip")
    publish_report(issue, opts, head, %{verdict: :skip, reason: reason, steps: [], findings: []}, "Merging")
    Logger.info("Skipping QA for #{issue_label(issue)} head=#{head}: #{reason}")

    merge_entry(issue, opts, settings, :qa_skip, %{reason: reason}, %{
      recommendation: "no QA run applies to this diff; ready to merge",
      qa: "QA skipped: #{reason}"
    })
  end

  defp run_agent(issue, _workspace, opts, settings, head, []) do
    blocked(issue, opts, settings, head, blocked_outcome("no QA playbook applies to this change", %{}))
  end

  defp run_agent(issue, workspace, opts, settings, head, playbooks) do
    job = agent_job(issue, workspace, opts, settings, head, playbooks)

    case Keyword.get(opts, :qa_agent, QaAgent).run(job, settings, opts) do
      {:ok, %{result: result, tokens: tokens}} ->
        outcome = run_outcome(result, tokens, playbooks)
        apply_outcome(issue, opts, settings, head, outcome)

      {:error, reason, tokens} ->
        extra = %{tokens: tokens, playbooks: playbook_kinds(playbooks)}
        blocked(issue, opts, settings, head, blocked_outcome(reason, extra))
    end
  end

  defp apply_outcome(issue, opts, settings, head, %{verdict: :pass} = outcome) do
    pass(issue, opts, settings, head, outcome)
  end

  defp apply_outcome(issue, opts, settings, head, %{verdict: :fail} = outcome) do
    fail(issue, opts, settings, head, outcome)
  end

  defp apply_outcome(issue, opts, settings, head, %{verdict: :blocked} = outcome) do
    blocked(issue, opts, settings, head, outcome)
  end

  defp apply_outcome(_issue, _opts, _settings, _head, %{verdict: verdict}) do
    {:error, {:qa_unknown_verdict, verdict}}
  end

  defp pass(issue, opts, settings, head, outcome) do
    record_verdict(issue, opts, head, "pass")
    publish_report(issue, opts, head, outcome, "Merging")
    Logger.info("QA passed for #{issue_label(issue)} head=#{head}")

    merge_entry(issue, opts, settings, :qa_pass, %{reason: "every journey verified"}, %{
      recommendation: "every journey verified; ready to merge",
      qa: qa_result(outcome)
    })
  end

  defp qa_result(outcome) do
    case Map.get(outcome, :summary) do
      summary when is_binary(summary) and summary != "" -> summary
      _none -> verdict_reason(outcome)
    end
  end

  defp fail(issue, opts, settings, head, outcome) do
    record_verdict(issue, opts, head, "fail")
    publish_report(issue, opts, head, outcome, "Rework")
    Logger.warning("QA failed for #{issue_label(issue)} head=#{head}: #{verdict_reason(outcome)}")

    move(issue, opts, settings, :qa_fail, %{reason: verdict_reason(outcome)})
  end

  # A blocked run is retried boundedly on the same head: a transient environment failure says
  # nothing about the change. Once the attempts are used up the block goes to the self-heal lane
  # (`SymphonyElixir.SelfHeal`), which files or reuses the fix ticket for the broken component,
  # holds the ticket on it, and resumes it by itself when the fix lands — or, for a block only a
  # person can clear, takes the access hold a person lifts. Either way the ticket pauses in QA
  # rather than failing silently.
  defp blocked(issue, opts, _settings, head, outcome) do
    record_verdict(issue, opts, head, "blocked")
    attempts = blocked_attempts(issue, opts, head)
    publish_report(issue, opts, head, outcome, blocked_target(attempts, outcome))

    if retry_blocked?(attempts, outcome) do
      Logger.warning("QA blocked for #{issue_label(issue)} head=#{head} (attempt #{attempts}/#{@max_blocked_attempts}); retrying")
      :ok
    else
      self_heal(issue, opts, attempts, outcome)
    end
  end

  defp self_heal(issue, opts, attempts, outcome) do
    heal_opts = [outcome: outcome, attempts: attempts, repo_key: repo_key(issue, opts)] ++ Keyword.take(opts, [:store, :tracker, :fixer, :symphony_repo_key])

    case SelfHeal.heal(issue, heal_opts) do
      {:error, reason} -> {:error, {:qa_self_heal_failed, reason}}
      _action -> :ok
    end
  end

  defp retry_blocked?(attempts, outcome), do: attempts < @max_blocked_attempts and not needs_person?(outcome)

  defp blocked_target(attempts, outcome) do
    if retry_blocked?(attempts, outcome), do: "QA (blocked, retrying)", else: "QA (blocked)"
  end

  defp blocked_attempts(issue, opts, head) do
    issue
    |> verdicts(opts)
    |> Enum.count(&(&1.head_sha == head and &1.outcome == "blocked"))
  end

  defp needs_person?(%{needs_person: true}), do: true
  defp needs_person?(_outcome), do: false

  defp agent_job(issue, workspace, opts, settings, head, playbooks) do
    %{
      issue: issue,
      sha: head,
      workspace_path: workspace,
      worker_host: Keyword.get(opts, :worker_host),
      repo_key: repo_key(issue, opts),
      run_id: Keyword.get(opts, :run_id) || "qa-#{issue.identifier}-#{String.slice(head, 0, 12)}",
      pr_url: Keyword.get(opts, :pr_url),
      playbooks: playbooks,
      token_limit: settings.agent.max_tokens_per_issue,
      run_profile: Keyword.get(opts, :run_profile),
      journey: journey(issue)
    }
  end

  defp run_outcome(result, tokens, playbooks) do
    %{
      verdict: result.verdict,
      summary: result.summary,
      steps: Map.get(result, :steps, []),
      findings: Map.get(result, :findings, []),
      reason: Map.get(result, :reason),
      needs_person: Map.get(result, :needs_person, false),
      tokens: tokens,
      playbooks: playbook_kinds(playbooks)
    }
  end

  defp blocked_outcome(cause, extra) do
    base = %{
      verdict: :blocked,
      reason: error_reason(cause),
      cause: cause,
      summary: nil,
      steps: [],
      findings: [],
      needs_person: false
    }

    Map.merge(base, extra)
  end

  defp playbook_kinds(playbooks), do: Enum.map(playbooks, & &1.kind)

  defp publish_report(issue, opts, head, outcome, target) do
    report = Report.render(Map.merge(outcome, %{sha: head, target_state: target}))

    case Report.publish(issue, report, Keyword.take(opts, [:linear_client, :settings])) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to publish the QA report for #{issue_label(issue)}: #{inspect(reason)}")
    end
  end

  # The step into `Merging`. With the repo's manual review `on`, the verdict pauses the ticket where
  # it is on a Needs Decision hold carrying the summary and waits for a person's confirmation
  # (`SymphonyElixir.MergeConfirmation`); with it `off` — the default — the verdict moves the ticket
  # as it always did. The gate itself is the guard's edge table, not a check here.
  defp merge_entry(issue, opts, settings, signal, extra, parts) do
    if TransitionGuard.confirmation_required?(signal, %{settings: settings}) do
      confirm_merge(issue, opts, parts)
    else
      move(issue, opts, settings, signal, extra)
    end
  end

  defp confirm_merge(issue, opts, parts) do
    summary = MergeConfirmation.summary(issue, opts, parts)

    case MergeConfirmation.pause(issue, opts, summary) do
      :ok ->
        record_move_signal(issue, opts, :merge_confirmation, %{target: "Merging", reason: parts[:recommendation]})
        :ok

      {:error, reason} ->
        {:error, {:qa_merge_confirmation_failed, reason}}
    end
  end

  # Every move goes through the one writer. `run/3` only ever gets here for a ticket already in the
  # configured QA state (`qa_run?/2`), which is the origin of each of these edges in the designed
  # table; the table itself is what defines them, and is tested directly.
  defp move(issue, opts, settings, signal, extra) do
    ctx = Map.merge(%{settings: settings}, extra)
    target = TransitionGuard.target(signal, ctx)

    case TransitionGuard.perform(issue.id, signal, ctx, tracker_opts(opts)) do
      :ok ->
        record_move_signal(issue, opts, signal, Map.put(extra, :target, target))
        :ok

      {:error, reason} ->
        {:error, {:qa_move_failed, signal, reason}}
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
      |> Map.take([:target, :reason, :carried])
      |> Map.put(:signal, to_string(signal))

    TicketSignals.record(repo_key(issue, opts), issue.id, @verdict_kind, details)
  end

  # The ticket's newest `qa` verdict, whatever head it judged: `carry_verdict/3` reads it to re-bind a
  # carrying pass, and requires it to be the pass — a newer fail or blocked is the verdict and nothing
  # is carried.
  defp latest_verdict(repo_key, issue_id), do: List.first(Handoff.verdicts(repo_key, issue_id, @verdict_kind))

  # The newest verdict bound to `head`, or nil. `head` is the workspace's real head — an unreadable
  # one parks the run before it gets here (`park_unreadable_head/2`) — so it always binds to a commit.
  defp verdict_for_head(repo_key, issue_id, head) do
    repo_key
    |> Handoff.verdicts(issue_id, @verdict_kind)
    |> Enum.find(&(&1.head_sha == head))
  end

  defp verdicts(issue, opts), do: Handoff.verdicts(repo_key(issue, opts), issue.id, @verdict_kind)

  defp verdict_reason(%{findings: [first | _]}) when is_binary(first), do: first
  defp verdict_reason(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp verdict_reason(_outcome), do: "the run could not verify the change"

  defp error_reason(reason) when is_binary(reason), do: reason
  defp error_reason({:remote_worker_unsupported, host}), do: "QA cannot run on the remote worker #{inspect(host)}"
  defp error_reason(reason), do: inspect(reason)

  defp repo_key(issue, opts), do: Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)

  defp issue_label(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_label(%Issue{id: id}), do: inspect(id)

  defp section(description, heading) do
    lines = String.split(description, "\n")

    case Enum.find_index(lines, &Regex.match?(heading, &1)) do
      nil ->
        nil

      index ->
        body =
          lines
          |> Enum.drop(index + 1)
          |> Enum.take_while(&(not Regex.match?(@any_heading, &1)))
          |> Enum.join("\n")
          |> String.trim()

        if body == "", do: nil, else: body
    end
  end

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()
end
