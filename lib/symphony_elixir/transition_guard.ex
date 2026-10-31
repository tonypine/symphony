defmodule SymphonyElixir.TransitionGuard do
  @moduledoc """
  The one writer for ticket state moves.

  Every Linear state move routes through this module. The machine's own moves — the orchestrator,
  the PR and CI watcher, the PR review poller, the Code Review, QA and epic review runs, the
  runner, the Director app, the workpad bootstrap, the Linear tool's human-action request and withdrawal, and its sub-issue
  cancel — are performed by `perform/4`, the only caller of `Tracker.update_issue_state/2` besides
  the move back of a hand move under `dispatch.source: record` (`SymphonyElixir.TicketObservation`),
  which puts Linear back to the phase the record already holds. An
  agent's request to set a state (the Linear tool's `update_state`) is validated by
  `resolve_request/2`, which applies the machine's refusals and redirects and returns the same
  `{:error, reason}` tuples as before, so the existing `refused_agent_action` audit path is
  unchanged; the tool writes the record's phase before Linear is asked, as `perform/4` does.

  One state write sits outside this module by design: sub-issue creation's initial state. The
  Linear tool's `issueCreate` sets the state a brand-new issue starts in, which is not a move of an
  existing issue — there is no from-state to guard — so `subissue_input/5` builds it directly. The
  Linear tool's state-scanning test keeps it the only such site.

  `edges/0` is the legal-edge table: one row per named signal, naming the origin states the signal
  may fire from and the target state it moves to. Flow tickets change behavior by editing this
  table, never by moving a ticket somewhere else. There is one table: the `legacy` machine and its
  rows into `In Review` and `Human Review` are gone with those states.

  Targets are either a literal state name, `:requested` (the caller supplies the target it computed
  in `ctx.target`), or one of the machine's config-derived states resolved from `ctx.settings`:
  `:code_review_state`, `:qa_state`, `:epic_review_state`, `:ci_fix_state` and
  `:waiting_on_sub_issues`.

  No move may enter a retired state (`retired_states/0`): `Auto Review`, `In Review` and
  `Human Review` are gone (`docs/design/state-machine.md` §Retired), so `perform/4` and
  `resolve_request/2` refuse them whatever the signal, and no ticket can enter one again. Startup
  fails loud while one still holds a ticket (`SymphonyElixir.RetiredStates`).
  """

  require Logger

  alias SymphonyElixir.{Pauses, PlanReview, Questions, RunStore, SubIssueWait, TicketSignals, Tracker}

  @in_progress_state "In Progress"
  @merging_state "Merging"
  @rework_state "Rework"
  @backlog_state "Backlog"
  @retired_states ["Auto Review", "In Review", "Human Review"]
  @run %{kind: :run, name: "The run"}
  @unblock_option "Unblock and run again"
  @keep_option "Keep it paused"
  # The block report's reason when its question can't be asked: the Director releases it with Unblock.
  @block_report_reason %{kind: :environment, waits_on: %{condition: "block_report"}, text: "The run reported a block", releasable: true}

  @typedoc "A named transition the machine can perform."
  @type signal :: atom()

  @typedoc "What a caller knows that the target and the guards need."
  @type context :: map()

  @typedoc """
  One row of the legal-edge table: the signal, the states it may fire from (`:any` when the machine
  derives the origin itself), and the target it moves to. `confirm: true` marks the rows whose move
  into `Merging` waits for a person when the repo's manual review is `on`
  (`SymphonyElixir.MergeConfirmation`).
  """
  @type edge :: %{
          required(:signal) => signal(),
          required(:from) => [String.t()] | :any,
          required(:to) => String.t() | atom(),
          optional(:confirm) => true
        }

  # `:handoff` is the explicit handoff signal: `In Progress` (or `Rework`) enters `Code Review`
  # only on it, never when a run merely goes quiet. Its target is the repo's configured Code
  # Review state, so a repo that names it differently still lands there.
  #
  # `:restart` is the Director app's full reset: close the pull request, start a fresh branch from
  # main, supersede the workpad, back to `In Progress`. Only a person performs it (the control
  # API's `restart` move), which is why `resolve_request/2` refuses an agent asking for
  # `In Progress` from a post-implementation phase: that request is a restart without the reset.
  #
  # The `:code_review_*` rows are the reviewer run's verdicts. They bind to the head the reviewer
  # judged (`SymphonyElixir.CodeReview` records the verdict against it): approve carries the ticket
  # on to the QA state, or straight to `Merging` when the QA state's skip rule applies (the
  # deterministic docs-only/internal-only diff — the caller picks the row and records the reason); and
  # a rework verdict returns it to `Rework`. An escalation has no row: it is a Needs Decision hold
  # (`SymphonyElixir.DecisionRequest.ask/4`), which pauses the ticket in Code Review and never
  # moves it, and so is CI that could not be fixed, a dependency that needs approval and an agent's
  # decision request.
  #
  # The `:qa_*` rows are the QA run's verdicts (`SymphonyElixir.QaVerification`): pass carries the
  # ticket to `Merging`, fail returns it to `Rework`, and a skip — the same hybrid rule seen from the
  # QA state — carries it to `Merging` without a run.
  #
  # The `:ci_fix_enter_*` rows are the CI Fix lane's entries (`SymphonyElixir.CiFix`): one row per
  # phase whose head can go red or conflict, so each origin is its own legal edge and the caller
  # records that origin on the ticket. `:ci_fix_mechanical` is the return — the target is the origin
  # the caller read back from the ticket, so the lane never has to name a state itself. A red head
  # or a conflict outside those phases takes `:ci_fix_dispatch` or `:review_rework` to `In Progress`.
  #
  # The PR and CI watcher's two moves out of a reviewed phase (`SymphonyElixir.PrDecision.Apply`):
  # `:person_push` sends a `Merging` ticket whose head a person pushed back to the configured Code
  # Review state, since the approval covered the diff before that push (D4); `:conflict_rework`
  # sends a ticket whose conflict with the base branch came back after the conflict fix runs, with
  # no open PR competing for its files, to `Rework`, where a run can change as much as the conflict
  # needs (D16).
  #
  # Its lifecycle moves (TP-944): `:pr_closed` sends a ticket whose PR was closed without merging out
  # of a phase that works on that PR to `Rework`, where the run opens a new one from main (D5);
  # `:pr_merged` closes a ticket whose PR merged outside `Merging`, by a person or anyone else, as
  # `:landing_done` does in `Merging`; `:wait_on_merge` holds either one on its open sub-issues.
  #
  # The lane's other two exits have no row, because they are not machine moves: a repair the fixing
  # agent judges substantive is the agent's own request to set `Rework` (an agent state request is
  # validated by `resolve_request/2`, never performed through this table), and a repair it cannot
  # make without access or a secret is a Needs Decision hold (`SymphonyElixir.Hold`), which never
  # moves the ticket at all. Both are recorded as a `fix verdict`.
  #
  # The `:epic_review_*` rows are the epic path's close (`SymphonyElixir.EpicReview`). An epic
  # parent whose sub-issues are all terminal enters `Epic Review` from the waiting state, and the
  # review's verdict either closes the epic or sends it back: `Done` when the epic's intent holds,
  # and the waiting state when gaps were found, with the gaps filed as follow-ups in `Todo` inside the
  # same epic — never `Backlog`, which would freeze the epic with nobody noticing. The parent's own
  # open follow-up holds it waiting until that follow-up lands, and the review runs again.
  # `:epic_review_enter`'s target is the repo's configured Epic Review state and
  # `:epic_review_gaps`'s the configured waiting state, so a repo that names either differently
  # still lands where the design says.
  #
  # `:plan_revise` sends a plan parent a person commented on back through `Rework` — the epic path's
  # re-plan, which continues in place and hands the plan back to `Plan Review`. The move is the
  # machine's own, recorded with `RunStore.put_own_state_move/2`, so `SymphonyElixir.BreakdownReview`
  # never reads it as a person's rejection of the plan (only a person's move to `Rework` cancels the
  # plan's sub-tickets).
  #
  # `confirm: true` marks the three rows whose move is a *verdict* carrying the ticket into `Merging`:
  # with the repo's manual review `on`, each waits for a person instead
  # (`SymphonyElixir.MergeConfirmation`). The rows that repair a red head (`:ci_fix_mechanical`, whose
  # target is the origin the caller read back) and the rework rows carry no marker, so a repair or a
  # rework never waits on a person in either mode.
  @edges [
    # Claim: the workpad bootstrap moves a Todo ticket to In Progress before its first turn.
    %{signal: :claim, from: ["Todo"], to: "In Progress"},
    # A person commented on a plan under review: the parent goes to Rework to revise it in place.
    %{signal: :plan_revise, from: ["Plan Review"], to: "Rework"},
    # A plan parent whose approved sub-issues are open waits on them (`SubIssueWait.park?/3`).
    %{signal: :plan_approve, from: ["In Progress"], to: :waiting_on_sub_issues},
    # A red head outside the CI Fix lane's phases: dispatch a CI fix run in In Progress.
    %{signal: :ci_fix_dispatch, from: :any, to: "In Progress"},
    # A landing run's PR merged: Done.
    %{signal: :landing_done, from: ["Merging"], to: "Done"},
    # The poller sends an issue back for changes.
    %{signal: :review_rework, from: :any, to: "In Progress"},
    # A green fix run with nothing to push returns the issue to Merging.
    %{signal: :merge_ready, from: ["Rework", "In Progress"], to: "Merging"},
    # An idle run is parked in Backlog.
    %{signal: :idle_park, from: ["In Progress", "Rework"], to: "Backlog"},
    # A Director-app move (a person's decision); the target is the requested state.
    %{signal: :director_move, from: :any, to: :requested},
    # Every sub-issue is terminal: Done.
    %{signal: :sub_issues_done, from: ["Waiting on sub-tickets"], to: "Done"},
    # A PR merged with sub-issues still open: wait on them.
    %{signal: :wait_on_merge, from: ["In Progress", "Code Review", "QA", "Rework", "CI Fix", "Merging"], to: :waiting_on_sub_issues},
    # Plan approval promotes a Backlog sub-ticket to Todo.
    %{signal: :breakdown_promote, from: ["Backlog"], to: "Todo"},
    # Re-planning cancels a Backlog sub-ticket (the caller supplies the canceled state it finds).
    %{signal: :breakdown_cancel, from: ["Backlog"], to: :requested},
    %{signal: :restart, from: :any, to: "In Progress"},
    %{signal: :handoff, from: ["In Progress", "Rework"], to: :code_review_state},
    %{signal: :code_review_approve, from: ["Code Review"], to: :qa_state},
    %{signal: :code_review_approve_skip, from: ["Code Review"], to: "Merging", confirm: true},
    %{signal: :code_review_rework, from: ["Code Review"], to: "Rework"},
    %{signal: :qa_pass, from: ["QA"], to: "Merging", confirm: true},
    %{signal: :qa_skip, from: ["QA"], to: "Merging", confirm: true},
    %{signal: :qa_fail, from: ["QA"], to: "Rework"},
    %{signal: :ci_fix_enter_code_review, from: ["Code Review"], to: :ci_fix_state},
    %{signal: :ci_fix_enter_qa, from: ["QA"], to: :ci_fix_state},
    %{signal: :ci_fix_enter_merging, from: ["Merging"], to: :ci_fix_state},
    %{signal: :ci_fix_enter_rework, from: ["Rework"], to: :ci_fix_state},
    %{signal: :ci_fix_mechanical, from: ["CI Fix"], to: :requested},
    %{signal: :person_push, from: ["Merging"], to: :code_review_state},
    %{signal: :conflict_rework, from: ["Code Review", "QA", "CI Fix", "Merging"], to: "Rework"},
    %{signal: :pr_closed, from: ["Code Review", "QA", "CI Fix", "Merging"], to: "Rework"},
    %{signal: :pr_merged, from: ["In Progress", "Code Review", "QA", "Rework", "CI Fix"], to: "Done"},
    %{signal: :epic_review_enter, from: ["Waiting on sub-tickets"], to: :epic_review_state},
    %{signal: :epic_review_pass, from: ["Epic Review"], to: "Done"},
    %{signal: :epic_review_gaps, from: ["Epic Review"], to: :waiting_on_sub_issues}
  ]

  # States an agent's request may never set, with the refusal it gets. Moving to `Merging` is how a
  # person approves a merge, so an agent may not do it.
  @human_only_states [
    %{name: @merging_state, error: :merging_requires_human_approval}
  ]

  @doc "The states no move may enter: they are retired."
  @spec retired_states() :: [String.t()]
  def retired_states, do: @retired_states

  @doc "Whether `state` names a retired state (`retired_states/0`)."
  @spec retired_state?(String.t() | nil) :: boolean()
  def retired_state?(state), do: Enum.any?(@retired_states, &state_name_matches?(state, &1))

  @doc "The legal-edge table."
  @spec edges() :: [edge()]
  def edges, do: @edges

  @doc "Every signal the table defines."
  @spec signals() :: [signal()]
  def signals, do: Enum.map(@edges, & &1.signal)

  @doc """
  True when `signal` is a known edge and `from` is one of its origins (`:any` accepts any state).
  With `to` given, it must also match the edge's literal target; a config-derived or requested
  target accepts any `to`.
  """
  @spec legal?(signal(), String.t() | nil, String.t() | nil) :: boolean()
  def legal?(signal, from, to \\ nil) do
    case edge(signal) do
      nil -> false
      %{from: froms, to: target} -> origin_allowed?(froms, from) and target_allowed?(target, to)
    end
  end

  @doc """
  True when `signal`'s move must wait for a person's confirmation: the edge is one of the table's
  verdict rows into `Merging` (`confirm: true`), and the repo's manual review setting is `on`
  (`docs/design/state-machine.md` §Attributes). The caller pauses with a Needs Decision hold instead
  of performing the move (`SymphonyElixir.MergeConfirmation`); `off`, the default, moves the ticket.
  """
  @spec confirmation_required?(signal(), context()) :: boolean()
  def confirmation_required?(signal, ctx) do
    case edge(signal) do
      %{confirm: true} -> manual_review_on?(ctx)
      _edge -> false
    end
  end

  defp manual_review_on?(ctx) do
    case Map.get(ctx, :settings) do
      %{manual_review: "on"} -> true
      _settings -> false
    end
  end

  @doc """
  The state `signal` moves to, resolved from `ctx`. `ctx.settings` is required for the
  config-derived targets and `ctx.target` for a requested one.
  """
  @spec target(signal(), context()) :: String.t() | nil
  def target(signal, ctx) do
    edge(signal)
    |> case do
      nil -> raise ArgumentError, "unknown transition signal: #{inspect(signal)}"
      %{to: to} -> resolve(to, ctx)
    end
  end

  @doc """
  Performs the move `signal` names for `issue_id`, resolving its target from `ctx`. This is the one
  caller of `Tracker.update_issue_state/2` for a move (the drift move back and the
  reconciler's projection in `SymphonyElixir.TicketObservation` change no phase); `opts[:tracker]` overrides the tracker
  (tests, a fake).
  A move into a retired state is refused with `{:error, {:retired_state, target}}`, and one whose
  target resolves to no state name (a requested or configured state that is nil or blank) with
  `{:error, {:unresolved_target, signal}}`, before Linear is asked.
  A move into `Merging` asks the PR and CI watcher to read now (`opts[:on_merging]` overrides it), so
  a PR that is already green merges at once instead of on the next timer, by when its head may be
  behind.

  The record is written first: with `ctx.repo_key`, the ticket's record takes the target as its
  phase (`SymphonyElixir.TicketSignals.record_phase/3`) before Linear is asked, so Symphony's record
  never lags Symphony's own move. Linear is its projection: a write Linear refuses leaves the record
  moved, is logged with the ticket's identifier (`ctx.issue_identifier`, else the record's) and the
  target, is marked on the record for the reconciler to project again
  (`SymphonyElixir.TicketSignals.mark_projection/4`), and comes back as the error it was. A target the ticket's team doesn't have
  (`{:error, :state_not_found}`) is no refused projection: the ticket never entered it, so the
  record goes back to the phase it held and nothing is logged, and a caller that tries the team's
  other spelling next (`Canceled`, `Cancelled`) leaves the record in the one the team has. The
  caller records the move's signal after.
  """
  @spec perform(String.t(), signal(), context(), keyword()) :: :ok | {:error, term()}
  def perform(issue_id, signal, ctx \\ %{}, opts \\ []) do
    target = target(signal, ctx)

    cond do
      not is_binary(target) or String.trim(target) == "" ->
        {:error, {:unresolved_target, signal}}

      retired_state?(target) ->
        {:error, {:retired_state, target}}

      true ->
        repo_key = Map.get(ctx, :repo_key)
        before = TicketSignals.recorded_phase(repo_key, issue_id)
        :ok = TicketSignals.record_phase(repo_key, issue_id, target)
        update_state(issue_id, target, ctx, before, opts)
    end
  end

  defp update_state(issue_id, target, ctx, before, opts) do
    case Keyword.get(opts, :tracker, Tracker).update_issue_state(issue_id, target) do
      :ok when target == @merging_state ->
        Keyword.get(opts, :on_merging, &SymphonyElixir.PrWatch.poll_now/0).()
        :ok

      :ok ->
        :ok

      {:error, :state_not_found} = error ->
        :ok = TicketSignals.restore_phase(Map.get(ctx, :repo_key), issue_id, before)
        error

      {:error, reason} = error ->
        Logger.warning(
          "Linear refused the move; the record keeps it issue_id=#{issue_id} issue_identifier=#{identifier(issue_id, ctx)} " <>
            "to=#{target} reason=#{inspect(reason)}"
        )

        :ok = TicketSignals.mark_projection(Map.get(ctx, :repo_key), issue_id, :phase, reason)
        error
    end
  end

  defp identifier(issue_id, ctx) do
    with nil <- Map.get(ctx, :issue_identifier),
         repo_key when is_binary(repo_key) <- Map.get(ctx, :repo_key),
         %{issue_identifier: identifier} <- RunStore.get_ticket_state(repo_key, issue_id) do
      identifier
    else
      identifier when is_binary(identifier) -> identifier
      _unknown -> nil
    end
  end

  @doc """
  Validates an agent's request to set the state `state` (its resolved Linear state map). Applies
  the machine's refusals in order — the retired-state refusal, the Plan Review entry refusal, the
  human-only refusal, the restart refusal, the Code Review entry refusal, the QA entry refusal,
  the Epic Review entry refusal, then the waiting-state refusal — and returns `{:ok, state}` or
  `{:error, reason}` with the tuple the Linear tool's `refused_agent_action` audit path records.

  An agent asking to enter `Code Review` or `QA` by hand is refused: `Code Review` is the handoff
  signal's to enter and `QA` the verdict's, never the tool's. So is an agent asking for
  `In Progress` from a phase past implementation (`Rework`, `Code Review`, `QA` or `Merging`): that
  is a `Restart`, which only a person performs. `Epic Review` is refused the same way: the machine
  enters it once an epic parent's sub-issues are all terminal and its review's verdict leaves it.
  `Plan Review` is the plan handoff's: only a plan parent (`ctx`'s `:plan_parent?`) may name it.

  An agent asking to park its issue in `Backlog` while it is `In Progress` or `Rework` is not a
  move: the guard pauses the ticket in its phase with a recorded reason instead of moving it (the
  Backlog escape hatch is retired), and returns `{:hold, :blocked, attrs}`, the block it reported:
  its `reason`, what clears it and what it waits on. When the issue has open blocked-by blockers
  (`ctx`'s `:open_blockers`), the block waits on them (`dependency`), and
  `SymphonyElixir.Pauses.Dependencies` lifts it on its own once they are all terminal; without one
  it waits on a person's `Unblock` (`access`).

  With `ctx`'s `:ticket` (the issue as `SymphonyElixir.Pauses` names it), the block report pauses
  the ticket through the one writer: one `:ticket` reason per open blocker ("Waiting for TP-12 to
  finish"), set by the run; with no blocker, the question `block_report_question/1` asks
  (`SymphonyElixir.Questions`), named in `waits_on.question_id`, which the Director's Unblock
  answers "#{@unblock_option}". A question that can't be asked pauses the ticket on an
  `:environment` reason the Director may release instead ("The run reported a block"). A pause the
  store refuses is the error; without `:ticket` the guard writes nothing.

  `ctx` carries `:settings`, `:from_state` (the issue's current state), `:plan_parent?` (the
  issue carries the `plan` label, so it is an epic parent), `:open_blockers` (the identifiers of
  the issue's blockers still outside a terminal state), and optionally `:ticket` and
  `:issue_identifier`, which names the ticket in the question.
  """
  @spec resolve_request(map(), context()) ::
          {:ok, map()} | {:hold, :blocked, map()} | {:error, term()}
  def resolve_request(%{"name" => state_name} = state, ctx) do
    settings = Map.fetch!(ctx, :settings)

    case hold_request(state_name, ctx) do
      :not_a_hold ->
        with :ok <- refuse_retired_state(state_name),
             :ok <- refuse_plan_review_entry(state_name, ctx, settings),
             :ok <- refuse_human_only(state),
             :ok <- refuse_restart_state(state, ctx, settings),
             :ok <- refuse_code_review_entry(state, settings),
             :ok <- refuse_qa_entry(state, settings),
             :ok <- refuse_epic_review_entry(state, settings),
             :ok <- refuse_waiting_state(state, settings) do
          {:ok, state}
        end

      held_or_refused ->
        held_or_refused
    end
  end

  # The Backlog escape hatch is retired: an agent asking to park an issue it is working in Backlog
  # has hit a block, so the guard pauses the ticket instead of moving it — the ticket keeps its
  # phase. Every other request is not a hold.
  defp hold_request(state_name, ctx) do
    if state_name_matches?(state_name, @backlog_state) and running_phase?(Map.get(ctx, :from_state)) do
      with {:ok, attrs} <- ctx |> Map.get(:open_blockers, []) |> block_report_attrs() |> pause_block_report(ctx),
           do: {:hold, :blocked, attrs}
    else
      :not_a_hold
    end
  end

  # A run that marked its issue blocked by other tickets waits on them: the pause lifts on its own
  # once they are all terminal, in whatever phase the issue is. With no open blocker, what the run
  # waits on is unknown to the machine, so the pause waits on a person's Unblock.
  defp block_report_attrs([_ | _] = keys) do
    %{
      reason: "the run reported a block: waiting on " <> Enum.join(keys, ", "),
      clearing_condition: "when every blocker is terminal",
      waits_on: %{type: "dependency", keys: keys}
    }
  end

  defp block_report_attrs(_keys) do
    %{
      reason: "the run reported a block",
      clearing_condition: "when a person unblocks it",
      waits_on: %{type: "access", keys: []}
    }
  end

  @doc """
  The question a run's block report asks when it names no blocker, on the ticket `name` (its
  identifier): a `SymphonyElixir.Questions.ask/3` request whose options are "#{@unblock_option}"
  (recommended: the Director answers once what the run needed is in place) and "#{@keep_option}".
  """
  @spec block_report_question(String.t()) :: map()
  def block_report_question(name) do
    title = "The run on #{name} cannot continue on its own"

    %{
      title: title,
      question: "#{title}. Should Symphony unblock it and run it again, or keep it paused?",
      why:
        "The run on #{name} reported that it could not go on, and it named no other ticket it waits on. " <>
          "Only a person can tell when what it needed, such as a secret or an access grant, is in place.",
      if_unanswered: "#{name} stays paused where it is and Symphony starts no run on it.",
      recommendation_reason: "Once what the run needed is in place, a new run picks up where the last one stopped.",
      options: [
        %{label: @unblock_option, effect: "Symphony lifts the pause on #{name} and starts a new run where the last one stopped.", recommended: true},
        %{label: @keep_option, effect: "#{name} stays paused until you decide.", recommended: false}
      ]
    }
  end

  @doc "The label of the block report question's option that unblocks the ticket and runs it again."
  @spec unblock_option() :: String.t()
  def unblock_option, do: @unblock_option

  # The block report's pause: a reason per blocker it waits on, or, with none, the question the
  # attributes then name, else a reason the Director may release. Without the ticket the guard writes
  # nothing.
  defp pause_block_report(%{waits_on: %{type: "dependency", keys: keys}} = attrs, %{ticket: ticket}) do
    keys
    |> Enum.filter(&Pauses.identifier?/1)
    |> Enum.map(&Pauses.set(ticket, Pauses.ticket_reason(:dependency, &1), set_by: @run))
    |> paused(attrs)
  end

  defp pause_block_report(attrs, %{ticket: ticket} = ctx) do
    case Questions.ask(ticket, block_report_question(Map.get(ctx, :issue_identifier) || "this ticket"), asked_by: @run) do
      {:ok, %{id: question_id}} ->
        {:ok, put_in(attrs, [:waits_on, :question_id], question_id)}

      {:error, reason} ->
        Logger.warning("Failed to ask the block report's question for issue_identifier=#{Map.get(ctx, :issue_identifier)}: #{inspect(reason)}")
        paused([Pauses.set(ticket, @block_report_reason, set_by: @run)], attrs)
    end
  end

  defp pause_block_report(attrs, _ctx), do: {:ok, attrs}

  defp paused(writes, attrs) do
    case Enum.find(writes, &match?({:error, _reason}, &1)) do
      nil -> {:ok, attrs}
      error -> error
    end
  end

  defp running_phase?(from) when is_binary(from),
    do: state_name_matches?(from, "In Progress") or state_name_matches?(from, "Rework")

  defp running_phase?(_from), do: false

  defp refuse_retired_state(state_name) do
    if retired_state?(state_name), do: {:error, {:retired_state, state_name}}, else: :ok
  end

  defp refuse_human_only(%{"name" => state_name}) do
    case Enum.find(@human_only_states, &state_name_matches?(state_name, &1.name)) do
      nil -> :ok
      %{error: error} -> {:error, {error, state_name}}
    end
  end

  # Entering `Code Review` is the handoff signal's job, so an agent's request to set the state by
  # hand is refused. The handoff is emitted mechanically by the push and PR tool hooks and performed
  # by the runner, never by an agent asking for the state.
  defp refuse_code_review_entry(%{"name" => state_name}, settings) do
    if state_name_matches?(state_name, settings.tracker.code_review_state),
      do: {:error, {:code_review_requires_handoff_signal, state_name}},
      else: :ok
  end

  # `Plan Review` is the plan handoff: the plan run hands the plan over by naming it. Any other
  # ticket naming `Plan Review` is refused, so the state belongs to the plan handoff, not to the
  # tool.
  defp refuse_plan_review_entry(state_name, ctx, settings) do
    with false <- Map.get(ctx, :plan_parent?, false),
         plan_review when is_binary(plan_review) <- PlanReview.state(settings),
         true <- state_name_matches?(state_name, plan_review) do
      {:error, {:plan_review_requires_handoff_signal, state_name}}
    else
      _keep -> :ok
    end
  end

  # `Restart` is a person's move — the control API closes the pull request, starts a fresh branch
  # from main and supersedes the workpad before it moves the ticket back to `In Progress`. An agent
  # asking for `In Progress` from a post-implementation phase is asking for that restart without its
  # reset, so it is refused; the claim from `Todo` and every move the machine makes itself are
  # unaffected.
  defp refuse_restart_state(%{"name" => state_name}, ctx, settings) do
    if state_name_matches?(state_name, @in_progress_state) and restart_origin?(Map.get(ctx, :from_state), settings),
      do: {:error, {:restart_requires_human_approval, state_name}},
      else: :ok
  end

  # The phases past implementation: work is on a pull request there, so `In Progress` can only mean
  # a fresh start. `Rework` is the rework phase, not a way back to In Progress.
  defp restart_origin?(from, settings) do
    Enum.any?(
      [@rework_state, @merging_state, settings.tracker.code_review_state, settings.tracker.qa_state],
      &state_name_matches?(from, &1)
    )
  end

  # Entering `QA` is the QA verdict's job (a pass, or the Code Review approve that skips it), so an
  # agent's request to set the state by hand is refused the same way the Code Review entry is.
  defp refuse_qa_entry(%{"name" => state_name}, settings) do
    if state_name_matches?(state_name, settings.tracker.qa_state),
      do: {:error, {:qa_requires_verdict, state_name}},
      else: :ok
  end

  # Entering `Epic Review` is the epic path's own move: the machine enters it when a parent has
  # every sub-issue terminal, and the review's verdict leaves it. An agent's request to set the
  # state by hand is refused the same way the Code Review and QA entries are.
  defp refuse_epic_review_entry(%{"name" => state_name}, settings) do
    if state_name_matches?(state_name, settings.tracker.epic_review_state),
      do: {:error, {:epic_review_requires_machine_move, state_name}},
      else: :ok
  end

  # Moving a `breakdown` parent to the waiting state approves its plan and promotes its sub-tickets,
  # so only a human does it.
  defp refuse_waiting_state(%{"name" => state_name}, settings) do
    case SubIssueWait.state(settings) do
      waiting_state when is_binary(waiting_state) ->
        if state_name_matches?(state_name, waiting_state),
          do: {:error, {:waiting_on_sub_issues_state_requires_human_approval, state_name}},
          else: :ok

      nil ->
        :ok
    end
  end

  defp edge(signal), do: Enum.find(@edges, &(&1.signal == signal))

  defp origin_allowed?(:any, _from), do: true
  defp origin_allowed?(froms, from) when is_binary(from), do: Enum.any?(froms, &state_name_matches?(from, &1))
  defp origin_allowed?(_froms, _from), do: false

  defp target_allowed?(_target, nil), do: true
  defp target_allowed?(target, to) when is_binary(target), do: state_name_matches?(target, to)
  defp target_allowed?(_target, _to), do: true

  defp resolve(:requested, ctx), do: Map.fetch!(ctx, :target)
  defp resolve(:code_review_state, ctx), do: settings!(ctx).tracker.code_review_state
  defp resolve(:qa_state, ctx), do: settings!(ctx).tracker.qa_state
  defp resolve(:epic_review_state, ctx), do: settings!(ctx).tracker.epic_review_state
  defp resolve(:ci_fix_state, ctx), do: settings!(ctx).tracker.ci_fix_state
  defp resolve(:waiting_on_sub_issues, ctx), do: SubIssueWait.state(settings!(ctx))
  defp resolve(name, _ctx) when is_binary(name), do: name

  defp settings!(ctx), do: Map.fetch!(ctx, :settings)

  defp state_name_matches?(name, expected) when is_binary(name) and is_binary(expected),
    do: String.downcase(String.trim(name)) == String.downcase(String.trim(expected))

  defp state_name_matches?(_name, _expected), do: false
end
