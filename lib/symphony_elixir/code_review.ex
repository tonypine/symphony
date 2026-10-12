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

    * `approve` -> `Merging` (the QA-skipped policy path)
    * `request_changes` -> `Rework`
    * `block` -> the escalation state, through the request machinery

  An inconclusive review retries boundedly on the same head, then escalates the same way. A legacy
  repo never reaches this module: `run/3` returns `:skip` for anything but a designed repo's
  `Code Review` ticket, so the executor path is untouched.

  A change that matches a risk rule of the repo's `auto_review.acceptance_gate.escalate` block
  (size, sensitive areas, sensitive content) is not approved straight on: the run *deepens* it with
  a second reviewer pass on the same head, records that verdict bound to the head and fires no
  routing edge. The next dispatch performs the deepened verdict. This is the guard's "risk rules
  deepen the review instead of routing anywhere" (`docs/design/state-machine.md`); the person half
  of the same guard (labels, ticket patterns) is not this module's to act on.

  A repo with the reviewer turned off (`review_agent.enabled: false`) has no reviewer to run, and
  `SymphonyElixir.ReviewAgent` answers a disabled reviewer with a fabricated approval. A Code Review
  ticket is never approved on that: dispatch is gated on the setting (the orchestrator parks the
  ticket with a `code_review_reviewer_disabled` signal recorded), and `run/3` itself refuses to
  review without a reviewer, recording the same signal and leaving the ticket where it is.
  """

  require Logger

  alias SymphonyElixir.AcceptanceGate.Escalation
  alias SymphonyElixir.{Config, Handoff, ReviewAgent, StateMachine, TicketSignals, TransitionGuard, WorkspaceHead}
  alias SymphonyElixir.Linear.Issue

  @verdict_kind "code_review"
  @reviewer_disabled_signal "code_review_reviewer_disabled"
  @deepening_signal "code_review_deepened"
  @deepening_applied_signal "code_review_deepening_applied"
  @max_inconclusive_retries 2
  @merging_state "Merging"

  # The design guard's risk rules (`docs/design/state-machine.md`): the diff-based escalation rules
  # (size, sensitive areas, sensitive content) *deepen* the Code Review run. The person rules
  # (`:label`, `:ticket_pattern`, `:dependency`, `:settings_ui`) route or hold and are not this
  # module's to act on; `:busy_file` needs the base branch's commit history and is left to the gate.
  @risk_rules [:path, :diff_pattern, :size]

  # The verdict strings a deepening records, back to the atoms `route_verdict/5` routes on. A string
  # that names no verdict stays what it is, and is refused as an unknown verdict.
  @verdict_atoms %{"approve" => :approve, "request_changes" => :request_changes, "block" => :block}

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

  defp review(issue, workspace, opts, settings) do
    if ReviewAgent.enabled?(settings.review_agent) do
      case pending_deepening(issue, workspace, opts) do
        nil -> do_review(issue, workspace, opts, settings)
        deepening -> apply_deepened(issue, opts, settings, deepening)
      end
    else
      park(issue, opts)
    end
  end

  defp do_review(issue, workspace, opts, settings) do
    case evaluate(issue, workspace, opts, settings) do
      {:ok, %{verdict: :approve} = result} ->
        if risky?(issue, settings, result),
          do: deepen(issue, workspace, opts, settings),
          else: apply_verdict(issue, workspace, opts, settings, :approve, result)

      {:ok, %{verdict: verdict} = result} ->
        apply_verdict(issue, workspace, opts, settings, verdict, result)

      {:error, reason} ->
        handle_review_error(issue, workspace, opts, settings, reason)
    end
  end

  # The reviewer's failure modes, exactly as the verdict path handles them, so the deepened pass
  # fails the same way the first one would.
  defp handle_review_error(issue, workspace, opts, settings, reason) do
    case reason do
      {:review_agent_inconclusive, cause} -> inconclusive(issue, workspace, opts, settings, cause)
      {:review_agent_blocked, payload} -> blocked(issue, workspace, opts, settings, payload)
      other -> {:error, {:code_review_failed, other}}
    end
  end

  # A risky approval is not routed straight on: the run takes a second reviewer pass on the same
  # head, records the deepened verdict bound to that head, and fires no routing edge — it returns
  # without a move. The next dispatch performs the recorded verdict (`pending_deepening/3`).
  defp deepen(issue, workspace, opts, settings) do
    case evaluate(issue, workspace, opts, settings) do
      {:ok, %{verdict: verdict} = result} ->
        head = workspace_head(workspace, opts)
        record_verdict(issue, opts, head, to_string(verdict))
        record_deepening(issue, opts, head, verdict, verdict_reason(result))

        Logger.info("Code Review for #{issue_label(issue)} head=#{head || "unknown"} deepened with a second reviewer pass verdict=#{inspect(verdict)}; not routing")

        :ok

      {:error, reason} ->
        handle_review_error(issue, workspace, opts, settings, reason)
    end
  end

  # A deepening already recorded for the head this run is checked out on is performed rather than
  # re-reviewed: the second pass happened on the previous dispatch, and its verdict was recorded
  # against this head. Routing it is this dispatch's whole job — once, so a move that fails is
  # retried and a move that lands is not replayed (`record_deepening_applied/3`).
  defp apply_deepened(issue, opts, settings, deepening) do
    head = signal_head(deepening)
    verdict = verdict_atom(deepening.details[:verdict])

    Logger.info("Code Review for #{issue_label(issue)} head=#{head || "unknown"} performs its deepened verdict=#{inspect(verdict)}")

    case route_verdict(issue, opts, settings, verdict, deepening.details[:reason]) do
      :ok ->
        record_deepening_applied(issue, opts, head)
        :ok

      error ->
        error
    end
  end

  # The deepening recorded for the head this run is checked out on, if the second pass has not
  # performed it yet. A deepening for another head is a different change's; a performed one is done.
  defp pending_deepening(issue, workspace, opts) do
    head = workspace_head(workspace, opts)
    deepenings = Enum.filter(signals(issue, opts), &(signal_head(&1) == head))

    if Enum.any?(deepenings, &(&1.name == @deepening_applied_signal)) do
      nil
    else
      Enum.find(deepenings, &(&1.name == @deepening_signal))
    end
  end

  # A change the repo's risk rules match is deepened, not approved: the run records the verdict the
  # second pass made against the same head, and the deepening it just took. It fires no routing edge
  # — no move — so the ticket stays in Code Review for the next dispatch to route `pending_deepening/3`.
  defp record_deepening(issue, opts, head, verdict, reason) do
    TicketSignals.record(repo_key(issue, opts), issue.id, @deepening_signal, %{
      head: head,
      verdict: to_string(verdict),
      reason: reason
    })
  end

  defp record_deepening_applied(issue, opts, head) do
    TicketSignals.record(repo_key(issue, opts), issue.id, @deepening_applied_signal, %{head: head})
  end

  # Whether the reviewer's own judgment of `result`'s diff trips a risk rule. The rules are the same
  # `auto_review.acceptance_gate.escalate` block the acceptance gate escalates on, filtered to the
  # diff-based subset the design deepens on: the rest need a person.
  defp risky?(%Issue{} = issue, settings, result) do
    rules = settings.auto_review.acceptance_gate.escalate

    issue
    |> Map.put(:labels, issue.labels || [])
    |> Escalation.check(diff_summary(result), [], rules)
    |> Enum.any?(&(&1.rule in @risk_rules))
  end

  # The reviewer already built the diff it judged (`ReviewAgent.Context`), so the risk check reads it
  # rather than running git again. The inventory's shape is the escalation rules' own `changed_file`.
  defp diff_summary(result) do
    source = Map.get(result, :source) || %{}
    files = source |> Map.get(:changed_file_inventory, []) |> Enum.map(&changed_file/1)

    %{files: files}
  end

  defp changed_file(file) do
    %{
      path: Map.get(file, :path),
      additions: Map.get(file, :additions) || 0,
      deletions: Map.get(file, :deletions) || 0,
      added_lines: added_lines(Map.get(file, :patch) || "")
    }
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
  defp signal_head(%{details: details}), do: Map.get(details, :head) || Map.get(details, "head")

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

    route_verdict(issue, opts, settings, verdict, verdict_reason(result))
  end

  # The routing half of a decided verdict, shared by a verdict this run just made and a deepening a
  # previous run recorded. Every edge goes through the one writer.
  defp route_verdict(issue, opts, settings, verdict, reason) do
    case verdict do
      :approve -> move(issue, opts, settings, :code_review_approve, %{target: @merging_state})
      :request_changes -> move(issue, opts, settings, :code_review_rework, %{})
      # The real reviewer exits a block through `blocked/5` (an error result), never this clause; an
      # overridden reviewer that returns a `:block` verdict map escalates the same way, and so does a
      # deepened block performed on a later dispatch.
      :block -> escalate(issue, opts, settings, reason)
      other -> {:error, {:code_review_unknown_verdict, other}}
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

    case TransitionGuard.perform(issue.id, signal, ctx, tracker_opts(opts)) do
      :ok ->
        record_move_signal(issue, opts, signal, extra)
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
      |> Map.take([:target, :reason])
      |> Map.put(:signal, to_string(signal))

    TicketSignals.record(repo_key(issue, opts), issue.id, @verdict_kind, details)
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
