defmodule SymphonyElixir.QaVerification do
  @moduledoc """
  The `QA` state's verification run.

  A `QA` ticket is dispatched by the poll loop like any other active ticket; this
  module turns that dispatch into a QA pass instead of an executor run: the QA agent
  (`SymphonyElixir.QaAgent` and its playbook selection, `SymphonyElixir.Verification`'s dev server)
  runs on the change's own worktree, from the user's point of view.

  The run is only ever started on a green head (the orchestrator gates dispatch on the ticket's
  recorded CI state) and its verdict is recorded bound to the head SHA it judged, then performed
  through the one writer, `SymphonyElixir.TransitionGuard`:

    * `pass` -> `Merging`
    * `pass` with `scope: none` (nothing to judge on screen, by the agent's answer or by
      `SymphonyElixir.QaPolicy`) -> `Merging` with the reason in the report, only when the pass built,
      launched and checked the app; otherwise `inconclusive`
    * `fail` -> `Rework`, with the report on the ticket for the next run
    * `inconclusive` (the QA run's own omission, such as a pass that claimed screens but ran no wide
      pass) -> rerun once on the same head, then a Needs Decision hold in `QA`; never the self-heal
      lane, since nothing in the environment is broken
    * skip (the deterministic docs-only/internal-only rule, `SymphonyElixir.QaPolicy`) -> `Merging`
    * no open pull request, or a head that changes nothing -> a Needs Decision hold in `QA`
      (`SymphonyElixir.ClosedPullRequest`), with no verdict recorded: an empty diff means there is
      no change to verify, never a docs-only one
    * `blocked` (tooling or environment) -> retried boundedly on the same head, then the self-heal
      lane when the QA tools raised the block themselves or only a person can clear it, else a Needs
      Decision hold in `QA`: a block nothing names as broken gets no fix ticket
    * a step the pass cannot prove here (`unprovable`: it needs the app on a pass the diff did not
      select the app's playbook for, or the project's own server on a repo whose setup rules a dev
      server out of a pass none of whose playbooks runs it,
      `SymphonyElixir.SelfHeal.dev_server_ruled_out/2`) -> decided by the other steps, the
      pre-checks and CI: a failing step fails, a passing one passes, and with nothing left to prove
      a Needs Decision hold in `QA` at once, recommending a merge without a QA result; a
      `needs_dev_server` block on such a pass makes its blocked steps unprovable instead of filing a
      dev-server repair. A block that names its own cause (a person to ask, the ticket that covers
      it, a QA tool's own failure, the project's server) stays that block
    * a `fail` or a block on a head the PR and CI watcher reads as rejected by CI (red checks, a
      required check that never reported, a conflict with the base branch) -> `blocked` with the
      component `ci`, the ticket left in `QA` for the watcher to route (a rerun, then CI Fix, or a
      conflict fix): a CI or merge state is not a defect of the change, so it never goes to `Rework`
    * a provider usage limit, or a model API the agent could not reach -> no verdict and no report:
      the run comes back as `{:error, {:usage_limited, info}}`, and the orchestrator holds it until
      the limit resets (SPEC §8.4.1)

  First the run brings its workspace to the PR's current head (a reused workspace still holds the
  head of its last run, and branch upkeep may have updated the PR since), resetting it only when it
  holds no local work; a head that moves during the run is synced once more before it blocks.

  Before the agent starts, the QA pre-check (`SymphonyElixir.QaPreCheck`) confirms each walkthrough
  step a named test proves, on the PR head: a passed check whose test is in the checkout reaches the
  agent as confirmed, linked and not walked; a failed check, one that never ran, or a test not in the
  checkout fails the pass to `Rework` without an agent run; a check still running is waited for, then
  reported `blocked` past the wait's limit (`SymphonyElixir.CiWait`). Every result is one line of the
  report's `### Pre-checks`.

  QA is journey-driven: the prompt carries the ticket's user walkthrough and acceptance criteria
  (the epic plan, where one exists, is the parent the QA agent reads with its Linear tools), and the
  agent judges the outcome as a careful engineer testing their own feature, not by executing a
  script. `run/3` returns `:skip` for anything but a `QA` ticket.
  """

  require Logger

  alias SymphonyElixir.{
    CiWait,
    ClosedPullRequest,
    Config,
    DecisionMove,
    DecisionRequest,
    Handoff,
    MergeConfirmation,
    PrWatch,
    QaPolicy,
    QaPreCheck,
    SelfHeal,
    TicketPullRequest,
    TicketSignals,
    TransitionGuard,
    Walkthrough,
    Workspace,
    WorkspaceHead
  }

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.HumanActions.PlainWords
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.QaAgent.Report
  alias SymphonyElixir.Repo.Fetcher

  @verdict_kind "qa"
  @run_kind "qa"
  @max_blocked_attempts 2
  @max_inconclusive_attempts 2
  @head_unreadable_signal "qa_head_unreadable"
  @ci_component "ci"
  @acceptance_heading ~r/^\s*\#{1,6}\s+Acceptance criteria\s*:?\s*$/i
  @any_heading ~r/^\s*\#{1,6}\s+\S/

  @doc """
  Runs the QA agent for `issue` when it is a `QA` ticket, else `:skip` so the
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
  Whether `issue` is the ticket this module verifies: one in the configured QA state. Every
  other ticket belongs to the executor run (or another state's own run).
  """
  @spec qa_run?(Issue.t(), map()) :: boolean()
  def qa_run?(%Issue{state: state}, settings) when is_binary(state) do
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
  The journey context for `issue`: its `## User walkthrough` when it has one, with its steps and the
  proof each names (`SymphonyElixir.Walkthrough`), else its acceptance criteria, else nothing but the
  instruction to derive them. The QA prompt renders this, so the run knows what to verify from the
  user's point of view and which steps a named test proves instead.

  `proof_check` is the repo's `proof_check` (WORKFLOW.md), the check a `Proved by: <test>` step
  names; with none, every step is QA's to walk.

  `label` names whose plan the journeys come from in the source phrase: the ticket for the QA
  state's own run (the default), and the epic for the epic review of a plan parent
  (`SymphonyElixir.EpicReview`), so the prompt reads right about which issue carries them.
  """
  @spec journey(Issue.t(), String.t() | nil, String.t()) :: %{source: String.t(), text: String.t() | nil, steps: [Walkthrough.step()]}
  def journey(issue, proof_check, label \\ "the ticket"), do: journey_for(issue, proof_check, label)

  defp journey_for(%Issue{description: description}, proof_check, label) when is_binary(description) do
    cond do
      text = Walkthrough.section(description) ->
        %{source: "#{label}'s `## User walkthrough`", text: text, steps: Walkthrough.steps(text, proof_check)}

      text = section(description, @acceptance_heading) ->
        %{source: "#{label}'s acceptance criteria", text: text, steps: []}

      true ->
        %{source: "#{label}'s walkthrough and acceptance criteria", text: nil, steps: []}
    end
  end

  defp journey_for(_issue, _proof_check, label), do: %{source: "#{label}'s walkthrough and acceptance criteria", text: nil, steps: []}

  defp verify(issue, workspace, opts, settings) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) -> remote_worker_unsupported(issue, opts, settings, host)
      _local -> read_head(issue, workspace, opts, settings)
    end
  end

  # The QA agent runs where the workspace lives, and the flow never runs it on an SSH
  # worker. There is no local head to read there either, so the run is blocked with the reason
  # (retried boundedly, then a Blocked hold) rather than parking on an unreadable head forever.
  defp remote_worker_unsupported(issue, opts, settings, host) do
    blocked(issue, opts, settings, nil, blocked_outcome({:remote_worker_unsupported, host}, %{}))
  end

  # A reused workspace keeps the head of its last run, and the PR's head moves between runs (branch
  # upkeep merges the base branch in after the approve), so the run first brings the workspace to the
  # PR's current head and only then reads the head its verdict binds to. A workspace with local work
  # is never reset: the run is blocked naming it. A PR head that cannot be fetched leaves the
  # workspace as it is; the pre-check still catches a head that moved.
  defp read_head(issue, workspace, opts, settings) do
    case sync_to_pr_head(issue, workspace, opts) do
      {:error, {:workspace_dirty, _head, _pr_head, _dirt} = dirty} -> dirty_workspace(issue, opts, settings, dirty)
      :ok -> read_synced_head(issue, workspace, opts, settings)
      {:error, reason} -> unsynced(issue, workspace, opts, settings, reason)
    end
  end

  defp unsynced(issue, workspace, opts, settings, reason) do
    unless reason in [:head_unreadable, :no_pull_request] do
      Logger.warning("QA for #{issue_label(issue)} runs on its workspace head: the PR head could not be synced: #{inspect(reason)}")
    end

    read_synced_head(issue, workspace, opts, settings)
  end

  defp read_synced_head(issue, workspace, opts, settings) do
    case WorkspaceHead.read(workspace, nil) do
      nil -> park_unreadable_head(issue, opts)
      head -> verify_head(issue, workspace, opts, settings, head)
    end
  end

  defp dirty_workspace(issue, opts, settings, {:workspace_dirty, head, pr_head, dirt}) do
    reason =
      "the workspace at #{String.slice(head, 0, 12)} is behind the PR head #{String.slice(pr_head, 0, 12)} " <>
        "and was not reset to it, because it has #{Enum.join(dirt, " and ")}"

    blocked(issue, opts, settings, head, blocked_outcome(reason, %{}))
  end

  # Fetches the PR's head (`refs/pull/<number>/head`, which GitHub keeps for every pull request) and
  # resets the workspace to it when the workspace is behind and holds no local work: no uncommitted
  # or untracked file, and no commit that neither the PR head nor a remote branch has.
  defp sync_to_pr_head(issue, workspace, opts) do
    git = Keyword.get(opts, :git, &git/2)

    with {:ok, head} <- local_head(workspace),
         {:ok, number} <- pr_number(issue, opts),
         {:ok, pr_head} <- fetch_pr_head(workspace, number, git) do
      if head == pr_head, do: :ok, else: reset_to_pr_head(workspace, head, pr_head, git)
    end
  end

  defp local_head(workspace) do
    case WorkspaceHead.read(workspace, nil) do
      nil -> {:error, :head_unreadable}
      head -> {:ok, head}
    end
  end

  defp pr_number(issue, opts) do
    with url when is_binary(url) <- TicketPullRequest.current_url(issue, repo_key(issue, opts)),
         {:ok, %{number: number}} <- PullRequest.parse_url(url) do
      {:ok, number}
    else
      _none -> {:error, :no_pull_request}
    end
  end

  defp fetch_pr_head(workspace, number, git) do
    ref = "refs/pull/#{number}/head"

    with {_output, 0} <- Fetcher.fetch(workspace, fn -> git.(["fetch", "--quiet", "origin", ref], workspace) end),
         {sha, 0} <- git.(["rev-parse", "--verify", "-q", "FETCH_HEAD^{commit}"], workspace) do
      {:ok, String.trim(sha)}
    else
      {output, status} -> {:error, {:pr_head_fetch_failed, ref, status, String.trim(output)}}
    end
  end

  defp reset_to_pr_head(workspace, head, pr_head, git) do
    case local_work(workspace, pr_head, git) do
      [] ->
        case git.(["reset", "--hard", "--quiet", pr_head], workspace) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:pr_head_reset_failed, status, String.trim(output)}}
        end

      dirt ->
        {:error, {:workspace_dirty, head, pr_head, dirt}}
    end
  end

  # What a reset would lose, in plain words; a git read that fails counts as local work, so a
  # workspace that cannot be read is never reset.
  defp local_work(workspace, pr_head, git) do
    changes = git_lines(git, ["status", "--porcelain=v1", "--untracked-files=all"], workspace)
    unpushed = git_lines(git, ["rev-list", "HEAD", "--not", pr_head, "--remotes"], workspace)

    Enum.reject(
      [
        work(changes, &"local changes (#{few(Enum.map(&1, fn line -> String.trim(line) end))})"),
        work(unpushed, &"#{length(&1)} unpushed commit(s) (#{few(Enum.map(&1, fn sha -> String.slice(sha, 0, 12) end))})")
      ],
      &is_nil/1
    )
  end

  defp git_lines(git, args, workspace) do
    case git.(args, workspace) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      {output, status} -> {:error, "git #{hd(args)} exited #{status}: #{String.trim(output)}"}
    end
  end

  defp work({:error, unread}, _describe), do: "a state git could not read (#{unread})"
  defp work({:ok, []}, _describe), do: nil
  defp work({:ok, lines}, describe), do: describe.(lines)

  defp few(items) when length(items) > 5, do: Enum.join(Enum.take(items, 5), ", ") <> " and #{length(items) - 5} more"
  defp few(items), do: Enum.join(items, ", ")

  defp git(args, workspace), do: Workspace.safe_git(args, cd: workspace, stderr_to_stdout: true)

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
    case TicketPullRequest.current_url(issue, repo_key(issue, opts)) do
      nil -> hold(issue, opts, head, ClosedPullRequest.missing_cause(issue, repo_key(issue, opts)))
      pr_url -> verify_change(issue, workspace, opts, settings, head, pr_url)
    end
  end

  defp verify_change(issue, workspace, opts, settings, head, pr_url) do
    if carried_pass?(issue, opts, head) do
      carry(issue, opts, settings, head)
    else
      decide(issue, workspace, opts, settings, head, pr_url)
    end
  end

  defp decide(issue, workspace, opts, settings, head, pr_url) do
    policy = Keyword.get(opts, :qa_policy, QaPolicy)

    case policy.decide(issue, settings, workspace: workspace, repo_key: repo_key(issue, opts)) do
      {:skip, reason} -> skip(issue, opts, settings, head, reason)
      {:nothing_to_verify, _reason} -> hold(issue, opts, head, {:no_change, pr_url})
      {:run, playbooks, _reason} -> pre_check(issue, workspace, opts, settings, {head, pr_url}, playbooks)
    end
  end

  # The steps a named test proves are confirmed before the agent starts (`SymphonyElixir.QaPreCheck`):
  # a failed or missing proof fails the pass without an agent run, a check still running waits, and
  # the confirmed steps reach the agent and the report. A walkthrough without one runs as before.
  defp pre_check(issue, workspace, opts, settings, {head, pr_url}, playbooks) do
    pre_check_opts = [proof_check: settings.proof_check] ++ Keyword.take(opts, [:gh_runner, :git])

    case QaPreCheck.run(journey(issue, settings.proof_check).steps, pr_url, head, workspace, pre_check_opts) do
      :none -> run_agent(issue, workspace, opts, settings, head, playbooks, [])
      {:pass, results} -> run_agent(issue, workspace, opts, settings, head, playbooks, results)
      {:fail, results} -> fail(issue, opts, settings, head, pre_check_failed(results))
      {:pending, results} -> wait_for_checks(issue, opts, settings, head, results)
      {:error, {:pr_head_moved, moved_to}} -> head_moved(issue, workspace, opts, settings, head, moved_to)
      {:error, reason} -> pre_check_unreadable(issue, opts, settings, head, reason)
    end
  end

  defp pre_check_unreadable(issue, opts, settings, head, reason) do
    blocked(issue, opts, settings, head, blocked_outcome("the QA pre-check could not read CI on the PR head: #{inspect(reason)}", %{}))
  end

  # The PR's head moved after the workspace was synced (upkeep merged the base branch in, a push
  # landed): the workspace is synced once more and the run starts again from the head it reads, in
  # the same run. Only a head that still differs after that sync blocks the run.
  defp head_moved(issue, workspace, opts, settings, head, moved_to) do
    if Keyword.get(opts, :qa_head_resynced, false) do
      pre_check_unreadable(issue, opts, settings, head, {:pr_head_moved, moved_to})
    else
      Logger.info("QA for #{issue_label(issue)} re-syncs its workspace: the PR head moved from #{String.slice(head, 0, 12)} to #{String.slice(moved_to, 0, 12)}")

      case sync_to_pr_head(issue, workspace, opts) do
        :ok -> read_synced_head(issue, workspace, Keyword.put(opts, :qa_head_resynced, true), settings)
        {:error, {:workspace_dirty, _head, _pr_head, _dirt} = dirty} -> dirty_workspace(issue, opts, settings, dirty)
        {:error, reason} -> pre_check_unreadable(issue, opts, settings, head, {:pr_head_moved, moved_to, reason})
      end
    end
  end

  defp pre_check_failed(results) do
    %{
      verdict: :fail,
      summary: "The QA pre-check found a walkthrough step whose named test did not pass on this head, so no QA agent ran.",
      steps: [],
      findings: QaPreCheck.findings(results),
      checks: QaPreCheck.report_checks(results),
      reason: nil,
      needs_person: false,
      playbooks: []
    }
  end

  # A named check still running is waited for like the epic review waits for CI: the run exits with
  # `{:ci_pending, info}` and the orchestrator starts it again after CI had a minute more, counting
  # the wait on this head (`SymphonyElixir.CiWait`). Past the wait's limit the pass is `blocked`
  # with the reason: retried boundedly, then the self-heal lane.
  defp wait_for_checks(issue, opts, settings, head, results) do
    pending = Enum.filter(results, &(&1.status == :pending))
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case CiWait.since(Handoff.signals(repo_key(issue, opts), issue.id), head) do
      %DateTime{} = since ->
        if CiWait.over?(since, now),
          do: blocked(issue, opts, settings, head, checks_still_running(pending, results, since, now)),
          else: ci_pending(issue, head, pending)

      nil ->
        ci_pending(issue, head, pending)
    end
  end

  defp ci_pending(issue, head, pending) do
    runs = Enum.map(pending, &%{workflow_name: &1.step.proof.check, url: &1.url})
    Logger.info("QA for #{issue_label(issue)} waits for the named checks on #{String.slice(head, 0, 12)}: #{Enum.map_join(runs, ", ", & &1.workflow_name)}")
    {:error, {:ci_pending, %{sha: head, runs: runs, run: "the QA pass"}}}
  end

  defp checks_still_running(pending, results, since, now) do
    minutes = div(DateTime.diff(now, since, :second), 60)
    steps = Enum.map_join(pending, "; ", &"step #{&1.step.number}: #{QaPreCheck.linked(&1)}")

    blocked_outcome("the named checks were still running after #{minutes} minutes of waiting: #{steps}", %{
      checks: QaPreCheck.report_checks(results)
    })
  end

  # With no open pull request the workspace is built from the base branch, and its head is not the
  # ticket's change; an empty diff has nothing to verify either. Neither is a verdict on the change,
  # so none is recorded and the ticket does not move: it pauses in QA on a person's decision.
  defp hold(issue, opts, head, cause) do
    Logger.warning("Not verifying #{issue_label(issue)} head=#{head}: #{inspect(cause)}")

    case ClosedPullRequest.pause(issue, cause, Keyword.put(opts, :repo_key, repo_key(issue, opts))) do
      :ok -> :ok
      {:error, reason} -> {:error, {:qa_hold_failed, reason}}
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

  defp run_agent(issue, _workspace, opts, settings, head, [], proofs) do
    blocked(issue, opts, settings, head, blocked_outcome("no QA playbook applies to this change", %{checks: QaPreCheck.report_checks(proofs)}))
  end

  defp run_agent(issue, workspace, opts, settings, head, playbooks, proofs) do
    job = agent_job(issue, workspace, opts, settings, head, playbooks, proofs)
    checks = QaPreCheck.report_checks(proofs)

    case Keyword.get(opts, :qa_agent, QaAgent).run(job, settings, opts) do
      {:ok, %{result: result, tokens: tokens}} ->
        outcome = result |> run_outcome(tokens, playbooks) |> Map.put(:checks, checks) |> settle_unprovable(job.unprovable)
        apply_outcome(issue, opts, settings, head, outcome)

      {:error, reason, tokens} ->
        agent_error(issue, opts, settings, head, reason, tokens, checks, playbooks)
    end
  end

  # An agent that could not run at all: a usage limit, or a model API it could not reach, holds the
  # run instead of applying a verdict (SPEC §8.4.1). The QA run records no verdict, writes no report
  # and leaves the ticket's state alone; the orchestrator holds it and starts it again once the limit
  # resets. Anything else is a block (retried boundedly, then self-healed, which classifies the
  # block by its cause — `SymphonyElixir.SelfHeal`).
  defp agent_error(issue, opts, settings, head, reason, tokens, checks, playbooks) do
    case QaAgent.usage_limit(reason) do
      %{} = info ->
        Logger.info(
          "QA for #{issue_label(issue)} head=#{head} could not run (provider usage limit or unreachable model API); " <>
            "the ticket keeps its state and the run starts again once the hold lifts"
        )

        {:error, {:usage_limited, info}}

      nil ->
        extra = %{tokens: tokens, playbooks: playbook_kinds(playbooks), checks: checks}
        extra = Map.put(extra, :environments, environments(playbooks))
        blocked(issue, opts, settings, head, blocked_outcome(reason, extra))
    end
  end

  # A step the pass could not prove here (TP-1284): it needs what no playbook of this pass gives —
  # the running app on a pass the diff did not select the app's playbook for, or the project's own
  # server on a repo whose setup rules a dev server out of a pass none of whose playbooks runs it
  # (`SelfHeal.dev_server_ruled_out/2`, read once for the agent's job). Such a step can neither
  # pass nor be repaired, so it decides nothing: on such a pass, a `needs_dev_server` block makes
  # its blocked steps `unprovable` with the repo's reason rather than filing a dev-server repair the
  # repo decided against, and a pass or block whose only open steps are unprovable is decided by
  # the rest. A failing step fails it; a passing step or a passed pre-check passes it, the report
  # naming each unprovable step; with nothing left to prove it stays blocked, marked `unprovable`,
  # and goes straight to a person, who is told merging without a QA result is the way on. Any other
  # blocked step, or a block that names its own cause, keeps the pass blocked as before.
  #
  # Only a pass that offered the status (an unselected playbook or a ruled-out server) settles: on
  # any other pass an `unprovable` step is the agent's own block, so it is `blocked` again and takes
  # the retry, self-heal or person path as before.
  defp settle_unprovable(outcome, %{unselected: [], dev_server_ruled_out: nil}),
    do: %{outcome | steps: Enum.map(outcome.steps, &unoffered_step/1)}

  defp settle_unprovable(outcome, %{dev_server_ruled_out: ruled_out}) do
    outcome |> rule_out_dev_server(ruled_out) |> settle()
  end

  defp unoffered_step(%{status: "unprovable"} = step), do: %{step | status: "blocked"}
  defp unoffered_step(step), do: step

  defp rule_out_dev_server(%{verdict: :blocked, needs_dev_server: true} = outcome, reason) when is_binary(reason) do
    steps =
      if Enum.any?(outcome.steps, &(&1.status == "blocked")),
        do: outcome.steps,
        else: outcome.steps ++ [%{name: "The steps that need the project's own server", status: "blocked", details: outcome.reason || "", evidence: []}]

    %{outcome | needs_dev_server: false, steps: Enum.map(steps, &unprovable_step(&1, reason))}
  end

  defp rule_out_dev_server(outcome, _reason), do: outcome

  defp unprovable_step(%{status: "blocked"} = step, reason),
    do: %{step | status: "unprovable", details: String.trim("#{reason}. #{step.details}")}

  defp unprovable_step(step, _reason), do: step

  defp settle(%{verdict: verdict, steps: steps} = outcome) when verdict in [:pass, :blocked] do
    case Enum.filter(steps, &(&1.status == "unprovable")) do
      [] -> outcome
      unprovable -> settle(outcome, unprovable, Enum.group_by(steps, & &1.status))
    end
  end

  defp settle(outcome), do: outcome

  defp settle(outcome, unprovable, by_status) do
    cond do
      Map.has_key?(by_status, "blocked") or own_block?(outcome) ->
        outcome

      Map.has_key?(by_status, "fail") ->
        %{outcome | verdict: :fail, findings: settled_findings(outcome.findings, by_status["fail"])}

      Map.has_key?(by_status, "pass") or Enum.any?(Map.get(outcome, :checks, []), &(&1.status == :pass)) ->
        %{outcome | verdict: :pass, summary: String.trim("#{outcome.summary} #{unprovable_note(unprovable)}")}

      true ->
        Map.merge(outcome, %{verdict: :blocked, unprovable: true, reason: "QA could prove none of the steps here. #{unprovable_note(unprovable)}"})
    end
  end

  # A block that names its own cause is that block, whatever its steps say: a person to ask (an
  # access case, or a wide pass a small QA screen limited, `QaAgent`), the open ticket that already
  # covers it, a QA tool's own failure, or the project's server a pass that runs it lacked.
  defp own_block?(%{verdict: :blocked} = outcome) do
    needs_person?(outcome) or Map.get(outcome, :needs_dev_server) == true or is_binary(Map.get(outcome, :covered_by)) or
      not is_nil(Map.get(outcome, :cause))
  end

  defp own_block?(_outcome), do: false

  defp settled_findings([], failing), do: Enum.map(failing, &"#{&1.name}: #{&1.details}")
  defp settled_findings(findings, _failing), do: findings

  defp unprovable_note(steps), do: "Unprovable here: " <> Enum.map_join(steps, "; ", &"#{&1.name} (#{&1.details})") <> "."

  defp apply_outcome(issue, opts, settings, head, %{verdict: :pass, scope: :none} = outcome) do
    case missing_app_checks(outcome) do
      [] -> pass(issue, opts, settings, head, outcome)
      missing -> inconclusive(issue, opts, settings, head, Map.merge(outcome, %{verdict: :inconclusive, reason: unproved(missing)}))
    end
  end

  defp apply_outcome(issue, opts, settings, head, %{verdict: :pass} = outcome) do
    healthy(issue, opts)
    pass(issue, opts, settings, head, outcome)
  end

  defp apply_outcome(issue, opts, settings, head, %{verdict: :fail} = outcome) do
    healthy(issue, opts)
    fail(issue, opts, settings, head, outcome)
  end

  defp apply_outcome(issue, opts, settings, head, %{verdict: :blocked} = outcome) do
    blocked(issue, opts, settings, head, outcome)
  end

  defp apply_outcome(issue, opts, settings, head, %{verdict: :inconclusive} = outcome) do
    inconclusive(issue, opts, settings, head, outcome)
  end

  defp apply_outcome(_issue, _opts, _settings, _head, %{verdict: verdict}) do
    {:error, {:qa_unknown_verdict, verdict}}
  end

  # A pass or fail verdict ran on a working QA environment, so the reason an access hold set beside
  # an earlier block clears (`SelfHeal.healthy/3`).
  defp healthy(issue, opts), do: SelfHeal.healthy(repo_key(issue, opts), issue.id)

  defp pass(issue, opts, settings, head, %{scope: :none} = outcome) do
    record_pass_verdict(issue, opts, head, "pass", outcome, %{scope: "none", reason: outcome.reason})
    publish_report(issue, opts, head, outcome, "Merging")
    Logger.info("QA passed for #{issue_label(issue)} head=#{head} with nothing on screen to judge: #{outcome.reason}")

    merge_entry(issue, opts, settings, :qa_pass, %{reason: "the app built, launched and checked healthy; nothing on screen to judge"}, %{
      recommendation: "the app built, launched and checked healthy, and the change has nothing on screen to judge; ready to merge",
      qa: "nothing on screen to judge: #{outcome.reason}"
    })
  end

  defp pass(issue, opts, settings, head, outcome) do
    record_pass_verdict(issue, opts, head, "pass", outcome)
    publish_report(issue, opts, head, outcome, "Merging")
    Logger.info("QA passed for #{issue_label(issue)} head=#{head}")

    merge_entry(issue, opts, settings, :qa_pass, %{reason: "every journey verified"}, %{
      recommendation: "every journey verified; ready to merge",
      qa: qa_result(outcome)
    })
  end

  # A pass with nothing on screen to judge rests on the app starting: the merge stays gated on a
  # build that produced the app, a launch, and a `qa_check_app` that found it healthy
  # (`SymphonyElixir.QaDriver.app_check/1`). A pass with no macOS app to build has none of them.
  defp missing_app_checks(outcome) do
    checks = Map.get(outcome, :app_check) || %{}

    for {key, tool} <- [built: "qa_build", launched: "qa_launch_app", checked: "a healthy qa_check_app"], Map.get(checks, key) != true, do: tool
  end

  defp unproved(missing) do
    "the pass answered `scope: none` (nothing on screen to judge), but #{Enum.join(missing, ", ")} did not run, " <>
      "so it did not prove the app builds and starts"
  end

  # An inconclusive pass is the QA run's own omission, not a fault of its environment: it ran but did
  # not reach a verdict it could ground (a pass that claimed screens but ran no wide pass, a
  # `scope: none` pass that never started the app). Nothing is broken for the self-heal lane to
  # repair, so it never goes there: the pass reruns once on the same head, like an inconclusive Code
  # Review, then asks a person on a Needs Decision hold. A head CI rejects is the PR watcher's first.
  defp inconclusive(issue, opts, settings, head, outcome) do
    case ci_rejection(issue, opts, head) do
      nil -> inconclusive_run(issue, opts, settings, head, outcome)
      rejection -> ci_blocked(issue, opts, settings, head, outcome, rejection)
    end
  end

  defp inconclusive_run(issue, opts, settings, head, outcome) do
    details = blocked_details(opts, settings, outcome)
    record_pass_verdict(issue, opts, head, "inconclusive", outcome, details)
    attempts = count_verdicts(issue, opts, head, "inconclusive")
    rerun? = attempts < @max_inconclusive_attempts
    publish_report(issue, opts, head, outcome, if(rerun?, do: "QA (inconclusive, rerunning)", else: "QA (inconclusive; a person decides)"))

    Logger.warning(
      "QA inconclusive for #{issue_label(issue)} head=#{head} model=#{details.model} playbooks=#{Enum.join(details.playbooks, ",")} " <>
        "(attempt #{attempts}/#{@max_inconclusive_attempts}); #{if rerun?, do: "rerunning", else: "asking a person"}: #{details.reason}"
    )

    if rerun?, do: :ok, else: escalate(issue, opts, settings, head, attempts, details.reason)
  end

  defp qa_result(outcome) do
    case Map.get(outcome, :summary) do
      summary when is_binary(summary) and summary != "" -> summary
      _none -> verdict_reason(outcome)
    end
  end

  # A pass that did not get through on a head CI rejects says nothing about the change, so neither
  # a fail nor a block of the environment is recorded: the head is the PR watcher's to route.
  defp fail(issue, opts, settings, head, outcome) do
    case ci_rejection(issue, opts, head) do
      nil -> fail_to_rework(issue, opts, settings, head, outcome)
      rejection -> ci_blocked(issue, opts, settings, head, outcome, rejection)
    end
  end

  defp fail_to_rework(issue, opts, settings, head, outcome) do
    record_pass_verdict(issue, opts, head, "fail", outcome)
    publish_report(issue, opts, head, outcome, "Rework")
    Logger.warning("QA failed for #{issue_label(issue)} head=#{head}: #{verdict_reason(outcome)}")

    move(issue, opts, settings, :qa_fail, %{reason: verdict_reason(outcome)})
  end

  # A blocked run is retried boundedly on the same head: a transient environment failure says
  # nothing about the change. Once the attempts are used up the block goes to the self-heal lane
  # (`SymphonyElixir.SelfHeal`), which files or reuses the fix ticket for the broken component,
  # holds the ticket on it, and resumes it by itself when the fix lands — or, for a block only a
  # person can clear, takes the access hold a person lifts. Either way the ticket pauses in QA
  # rather than failing silently. The block's reason, whether it needs a person, the model the run
  # used and the playbooks it ran are logged and recorded on the verdict, so a block can be
  # diagnosed after the fact.
  defp blocked(issue, opts, settings, head, outcome) do
    case ci_rejection(issue, opts, head) do
      nil -> blocked_on_environment(issue, opts, settings, head, outcome)
      rejection -> ci_blocked(issue, opts, settings, head, outcome, rejection)
    end
  end

  defp blocked_on_environment(issue, opts, settings, head, outcome) do
    details = blocked_details(opts, settings, outcome)
    record_pass_verdict(issue, opts, head, "blocked", outcome, details)
    attempts = blocked_attempts(issue, opts, head)
    next = blocked_next(attempts, outcome)
    publish_report(issue, opts, head, outcome, blocked_target(attempts, outcome))

    Logger.warning(
      "QA blocked for #{issue_label(issue)} head=#{head} model=#{details.model} needs_person=#{details.needs_person} " <>
        "playbooks=#{Enum.join(details.playbooks, ",")} (attempt #{attempts}/#{@max_blocked_attempts}); " <>
        "#{next_label(next)}: #{details.reason}"
    )

    case next do
      :retry -> :ok
      :self_heal -> self_heal(issue, opts, attempts, outcome)
      :escalate -> escalate(issue, opts, settings, head, attempts, details.reason, unprovable?(outcome))
    end
  end

  defp blocked_next(attempts, outcome) do
    cond do
      retry_blocked?(attempts, outcome) -> :retry
      self_heal_input?(outcome) -> :self_heal
      true -> :escalate
    end
  end

  defp next_label(:retry), do: "retrying"
  defp next_label(:self_heal), do: "self-healing"
  defp next_label(:escalate), do: "asking a person"

  # What the self-heal lane may repair: a block the QA tools raised themselves, which names the
  # broken part of the QA environment, or one only a person can clear (`needs_person`, the access
  # hold). Two structured answers of the QA agent route there too: `covered_by` waits on the open
  # ticket that already tracks the gap and files nothing, and `needs_dev_server` files the project's
  # own dev server setup in its repo (TP-1106). Any other block — the agent's own account of what
  # went wrong, a run that crashed or ran out of tokens, a check that never finished — names nothing
  # broken to fix, so a fix ticket for it would chase a non-problem (TP-1118): it goes to a person.
  defp self_heal_input?(%{unprovable: true}), do: false
  defp self_heal_input?(%{needs_person: true}), do: true
  defp self_heal_input?(%{needs_dev_server: true}), do: true
  defp self_heal_input?(%{covered_by: identifier}) when is_binary(identifier), do: true
  defp self_heal_input?(outcome), do: tool_cause?(Map.get(outcome, :cause))

  defp tool_cause?({:qa_worker, _code}), do: true
  defp tool_cause?({:qa_host_missing_tool, _names}), do: true
  defp tool_cause?({:qa_host_tool_check_failed, _reason}), do: true
  defp tool_cause?({:qa_host_tunnel_failed, _reason}), do: true
  defp tool_cause?({:qa_dev_server_failed, _cause}), do: true
  defp tool_cause?({:qa_dev_server_failed, _cause, _log}), do: true
  defp tool_cause?(_cause), do: false

  # A pass that keeps ending without a verdict and names nothing the machine can repair: the ticket
  # pauses in QA on a person's decision. "Run QA again" clears the hold and QA runs again on the same
  # head; each further run that ends the same way asks again. The other two picks are moves Symphony
  # makes itself (`SymphonyElixir.DecisionMove`): Rework, or the QA pass's target with a `qa`
  # verdict `skip` bound to this head, recorded as skipped by decision.
  #
  # A pass with nothing it could prove here (every open step `unprovable`) asks at once, with the
  # same three options: another run would end the same way, so merging without a QA result is the
  # recommended one.
  defp escalate(issue, opts, settings, head, attempts, reason, unprovable? \\ false) do
    Logger.warning("QA for #{issue_label(issue)} could not reach a verdict after #{attempts} run(s); asking a person: #{reason}")
    hold_opts = opts |> Keyword.take([:tracker, :store]) |> Keyword.put(:repo_key, repo_key(issue, opts))

    case DecisionRequest.ask(issue, escalation_request(issue, settings, head, attempts, reason, unprovable?), hold_opts) do
      :ok -> :ok
      {:error, error} -> {:error, {:qa_escalation_failed, error}}
    end
  end

  defp escalation_request(issue, settings, head, attempts, reason, unprovable?) do
    merging = TransitionGuard.target(:qa_pass, %{settings: settings})
    skip = %{kind: @verdict_kind, outcome: "skip", head_sha: head, reason: "skipped by decision"}

    %{
      title: "QA could not finish its check of #{issue_label(issue)}",
      question: escalation_question(issue, attempts, unprovable?),
      why: escalation_why(reason, unprovable?),
      options: [
        recommend(%{label: "Run QA again", effect: "the ticket continues in QA and QA runs once more on the same change"}, not unprovable?),
        DecisionMove.option(%{label: "Send it back to Rework", effect: "Symphony moves #{issue_label(issue)} to Rework, and its next run reads QA's report"}, %{to: "Rework"}),
        recommend(
          DecisionMove.option(
            %{label: "Merge without a QA result", effect: "Symphony moves #{issue_label(issue)} to #{merging}, and it merges on its review and CI alone"},
            %{to: merging, verdict: skip}
          ),
          unprovable?
        )
      ],
      if_unanswered: "#{issue_label(issue)} stays in #{settings.tracker.qa_state} and goes no further.",
      recommendation_reason: escalation_recommendation(unprovable?)
    }
  end

  defp escalation_question(issue, _attempts, true),
    do: "QA could not prove any step of #{issue_mention(issue)} here, because each one needs something this repo's QA pass does not have. How should it continue?"

  defp escalation_question(issue, attempts, false),
    do: "QA ran #{issue_mention(issue)} #{attempts} times on the same change without a pass or a fail. How should it continue?"

  defp escalation_why(reason, true),
    do: "The run ended with: #{PlainWords.scrub(reason)} No step QA could run failed, and nothing in the QA environment is broken, so the machine files no fix ticket for it."

  defp escalation_why(reason, false),
    do: "The last run ended with: #{PlainWords.scrub(reason)}. No QA tool reported a broken part of the QA environment, so the machine files no fix ticket for it."

  defp escalation_recommendation(true), do: "QA can never prove these steps on this repo, so another run would end the same way; the review and CI already judged the change."
  defp escalation_recommendation(false), do: "A run that ends without a result is often a passing hiccup, and one more run costs little."

  defp recommend(option, true), do: Map.put(option, :recommended, true)
  defp recommend(option, false), do: option

  defp issue_mention(%Issue{identifier: identifier, title: title}) when is_binary(identifier) and is_binary(title), do: "#{identifier} (#{PlainWords.scrub(title)})"
  defp issue_mention(issue), do: issue_label(issue)

  # A head the PR and CI watcher reads as rejected by CI: its checks red, a required check that never
  # reported, or a conflict with the base branch (which runs no workflow at all). A QA pass that did
  # not get through there failed for a CI or merge state, not for the change's behaviour, and those
  # cases are the watcher's own: a rerun, then CI Fix with the failed log (R22, R21), or a conflict
  # fix (R14), each bounded. So the pass is recorded `blocked` with the component `ci`, its report is
  # published, and the ticket stays in QA: the dispatch gate holds QA back on that head, and the
  # watcher's next read routes it. No blocked attempt is spent and no fix ticket is filed. Only the
  # watcher's record of this same head counts; with none, the outcome is applied as it is.
  defp ci_rejection(issue, opts, head) when is_binary(head) do
    case PrWatch.watch(issue.id, repo_key: repo_key(issue, opts)) do
      %{head_sha: ^head, facts: facts} -> rejection(facts)
      _none_or_other_head -> nil
    end
  end

  defp ci_rejection(_issue, _opts, _head), do: nil

  defp rejection(%{mergeable: :dirty}), do: "the PR conflicts with its base branch, so CI cannot run on this head"
  defp rejection(%{ci: :red, failing_check: check}) when is_binary(check), do: "CI is red on this head: #{check} failed"
  defp rejection(%{ci: :red}), do: "CI is red on this head"
  defp rejection(%{ci: :required_missing}), do: "a required check never reported on this head"
  defp rejection(_facts), do: nil

  defp ci_blocked(issue, opts, settings, head, outcome, rejection) do
    outcome = Map.merge(outcome, %{verdict: :blocked, reason: rejection, needs_person: false})
    details = opts |> blocked_details(settings, outcome) |> Map.merge(%{reason: rejection, component: @ci_component})
    record_pass_verdict(issue, opts, head, "blocked", outcome, details)
    publish_report(issue, opts, head, outcome, "QA (blocked on CI; the PR watcher routes the head)")

    Logger.warning("QA blocked on CI for #{issue_label(issue)} head=#{head} model=#{details.model}; handing the head to the PR watcher: #{rejection}")

    :ok
  end

  defp blocked_details(opts, settings, outcome) do
    %{
      reason: verdict_reason(outcome),
      needs_person: needs_person?(outcome),
      model: qa_model(opts, settings),
      playbooks: Enum.map(Map.get(outcome, :playbooks, []), &to_string/1)
    }
  end

  # The model the QA agent ran on: the run's profile, else the QA profile `QaAgent` starts with.
  defp qa_model(opts, settings) do
    profile = Keyword.get(opts, :run_profile) || Config.qa_profile(settings)
    Map.get(profile, :model) || "default"
  end

  defp self_heal(issue, opts, attempts, outcome) do
    heal_opts = [outcome: outcome, attempts: attempts, repo_key: repo_key(issue, opts)] ++ Keyword.take(opts, [:store, :tracker, :fixer, :symphony_repo_key])

    case SelfHeal.heal(issue, heal_opts) do
      {:error, reason} -> {:error, {:qa_self_heal_failed, reason}}
      _action -> :ok
    end
  end

  defp retry_blocked?(attempts, outcome), do: attempts < @max_blocked_attempts and not needs_person?(outcome) and not unprovable?(outcome)

  defp blocked_target(attempts, outcome) do
    if retry_blocked?(attempts, outcome), do: "QA (blocked, retrying)", else: "QA (blocked)"
  end

  # A block on CI is the watcher's, not the environment's, so it spends no attempt.
  defp blocked_attempts(issue, opts, head), do: count_verdicts(issue, opts, head, "blocked")

  defp count_verdicts(issue, opts, head, outcome) do
    issue
    |> verdicts(opts)
    |> Enum.count(&(&1.head_sha == head and &1.outcome == outcome and Map.get(&1.details, :component) != @ci_component))
  end

  defp needs_person?(%{needs_person: true}), do: true
  defp needs_person?(_outcome), do: false

  defp unprovable?(%{unprovable: true}), do: true
  defp unprovable?(_outcome), do: false

  defp agent_job(issue, workspace, opts, settings, head, playbooks, proofs) do
    %{
      issue: issue,
      sha: head,
      workspace_path: workspace,
      worker_host: Keyword.get(opts, :worker_host),
      repo_key: repo_key(issue, opts),
      run_id: qa_run_id(issue, opts, head),
      pr_url: Keyword.get(opts, :pr_url),
      playbooks: playbooks,
      token_limit: settings.agent.max_tokens_per_issue,
      run_profile: Keyword.get(opts, :run_profile),
      journey: journey(issue, settings.proof_check),
      proofs: proofs,
      unprovable: %{
        unselected: QaPolicy.unselected_playbooks(settings, playbooks),
        dev_server_ruled_out: SelfHeal.dev_server_ruled_out(settings, playbooks)
      }
    }
  end

  defp run_outcome(result, tokens, playbooks) do
    %{
      verdict: result.verdict,
      summary: result.summary,
      steps: Map.get(result, :steps, []),
      findings: Map.get(result, :findings, []),
      finding_details: Map.get(result, :finding_details),
      artifacts: Map.get(result, :artifacts),
      reason: Map.get(result, :reason),
      needs_person: Map.get(result, :needs_person, false),
      needs_dev_server: Map.get(result, :needs_dev_server, false),
      covered_by: Map.get(result, :covered_by),
      cause: Map.get(result, :cause),
      scope: Map.get(result, :scope),
      app_check: Map.get(result, :app_check),
      verdict_retries: Map.get(result, :verdict_retries),
      tokens: tokens,
      playbooks: playbook_kinds(playbooks),
      environments: environments(playbooks)
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

  # What the app under test could read on this pass, and why (`QaPolicy` marks it): the report's
  # header says so, so a `qa:live` or `qa:fixture` label shows where it took effect.
  defp environments(playbooks) do
    case Enum.find(playbooks, &is_binary(Map.get(&1, :live_reason))) do
      %{live: true, live_reason: why} -> "fixtures and a live server (#{why})"
      %{live_reason: why} -> "fixtures only (#{why})"
      nil -> nil
    end
  end

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
  # configured QA state (`qa_run?/2`), which is the origin of each of these edges in the table;
  # the table itself is what defines them, and is tested directly.
  defp move(issue, opts, settings, signal, extra) do
    ctx = Map.merge(%{settings: settings, repo_key: repo_key(issue, opts)}, extra)
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

  defp qa_run_id(issue, opts, head), do: Keyword.get(opts, :run_id) || "qa-#{issue.identifier}-#{String.slice(to_string(head), 0, 12)}"

  # A verdict the QA pass reached, after the pass's own events: one `evidence` per step that cites
  # evidence and one for the session's transcript, then, on a `fail`, one `finding.recorded` per
  # finding. The QA run writes them (`agent{run_id, run_kind: "qa"}`), keyed on the run and their
  # position, so handling the same outcome again writes none twice. A write that fails is logged
  # (`TicketSignals.record_event/5`) and changes neither the verdict nor the move.
  defp record_pass_verdict(issue, opts, head, verdict, outcome, details \\ %{}) do
    repo_key = repo_key(issue, opts)

    if is_binary(repo_key) do
      run_id = qa_run_id(issue, opts, head)
      record_evidence(repo_key, issue, run_id, outcome)
      if verdict == "fail", do: record_findings(repo_key, issue, run_id, outcome)
    end

    record_verdict(issue, opts, head, verdict, details)
  end

  defp record_evidence(repo_key, issue, run_id, outcome) do
    artifacts = Map.get(outcome, :artifacts)

    steps =
      for %{evidence: [_ | _] = entries} = step <- Map.get(outcome, :steps, []),
          do: {"#{step.name}: #{step.status}", resolved(artifacts, entries)}

    transcript =
      case artifacts do
        %{transcript: id} when is_binary(id) -> [{"QA session transcript", [id]}]
        _none -> []
      end

    (steps ++ transcript)
    |> Enum.with_index(1)
    |> Enum.each(fn {{caption, ids}, n} ->
      payload = %{caption: cut(caption, 500), artifacts: ids}
      TicketSignals.record_event(repo_key, issue.id, "evidence", payload, pass_event_opts(run_id, "evidence:#{run_id}:#{n}", ids))
    end)
  end

  # Each finding until the findings model classifies them (epic 4): `unclassified` and `unrated`,
  # its line as the description, its step and viewport as given and its evidence as written. Its
  # artifacts are the files its evidence names, or those of the step it names when it cites none.
  defp record_findings(repo_key, issue, run_id, outcome) do
    artifacts = Map.get(outcome, :artifacts)
    steps = Map.get(outcome, :steps, [])

    outcome
    |> finding_details()
    |> Enum.with_index(1)
    |> Enum.each(fn {finding, n} ->
      ids =
        case finding.evidence do
          [] -> resolved(artifacts, step_evidence(steps, finding.step))
          entries -> resolved(artifacts, entries)
        end

      payload = %{
        class: "unclassified",
        severity: "unrated",
        description: cut(finding.line, 2_000),
        step: cut(finding.step, 200),
        viewport: cut(finding.viewport, 100),
        evidence: if(finding.evidence == [], do: nil, else: finding.evidence)
      }

      TicketSignals.record_event(repo_key, issue.id, "finding.recorded", payload, pass_event_opts(run_id, "finding:#{run_id}:#{n}", ids))
    end)
  end

  # The findings the agent gave, else its failing steps, as `QaAgent.failure_findings/1` reads them.
  defp finding_details(%{finding_details: [_ | _] = details}), do: details

  defp finding_details(%{findings: [_ | _] = findings}) do
    for line <- findings, is_binary(line), do: %{line: line, step: nil, viewport: nil, evidence: []}
  end

  defp finding_details(outcome) do
    for %{status: "fail"} = step <- Map.get(outcome, :steps, []),
        do: %{line: String.trim("#{step.name}: #{step.details}"), step: step.name, viewport: nil, evidence: step.evidence}
  end

  defp step_evidence(_steps, nil), do: []

  defp step_evidence(steps, name) do
    name = String.downcase(name)
    Enum.find_value(steps, [], &(String.downcase(&1.name) == name and &1.evidence))
  end

  defp resolved(artifacts, entries) do
    entries |> Enum.map(&QaAgent.evidence_artifact(artifacts, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp pass_event_opts(run_id, key, ids), do: [actor: {:agent, run_id, @run_kind}, idempotency: key, artifacts: ids]

  defp cut(nil, _max), do: nil
  defp cut(text, max), do: String.slice(text, 0, max)

  # The QA run gave the verdict, so its event names that run, as its evidence and findings do.
  defp record_verdict(issue, opts, head, outcome, details \\ %{}) do
    run_opts = [run_id: qa_run_id(issue, opts, head)]
    TicketSignals.record_verdict(repo_key(issue, opts), issue.id, @verdict_kind, head, outcome, details, run_opts)
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
  defp error_reason({:qa_dev_server_failed, _cause, _log} = reason), do: QaAgent.blocked_reason(reason)
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
