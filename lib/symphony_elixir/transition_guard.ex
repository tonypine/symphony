defmodule SymphonyElixir.TransitionGuard do
  @moduledoc """
  The one writer for ticket state moves.

  Every Linear state move routes through this module. The machine's own moves — the orchestrator,
  the CI and PR review pollers, the Code Review, QA and epic review runs, the runner, the Director app, the
  workpad bootstrap, the Linear tool's human-action request and withdrawal, and its sub-issue
  cancel — are performed by `perform/4`, the only caller of `Tracker.update_issue_state/2`. An
  agent's request to set a state (the Linear tool's `update_state`) is validated by
  `resolve_request/2`, which applies the machine's refusals and redirects and returns the same
  `{:error, reason}` tuples as before, so the existing `refused_agent_action` audit path is
  unchanged.

  One state write sits outside this module by design: sub-issue creation's initial state. The
  Linear tool's `issueCreate` sets the state a brand-new issue starts in, which is not a move of an
  existing issue — there is no from-state to guard — so `subissue_input/5` builds it directly. The
  Linear tool's state-scanning test keeps it the only such site.

  `edges/0` is the legal-edge table: one row per named signal, naming the origin states the signal
  may fire from and the target state it moves to. It is initialised in parity with the machine as
  it behaves today — the same targets, the same refusals, the same redirects — so this module
  changes nothing observable. Later flow tickets change behavior by editing this table, never by
  moving a ticket somewhere else.

  Targets are either a literal state name, `:requested` (the caller supplies the target it computed
  in `ctx.target`), or one of the machine's config-derived states resolved from `ctx.settings`:
  `:code_review_state`, `:qa_state`, `:epic_review_state`, `:ci_fix_state` and
  `:waiting_on_sub_issues`.

  No move may enter a retired state (`retired_states/0`): `Auto Review` is gone with the acceptance
  gate (`docs/design/state-machine.md` §Retired), so `perform/4` and `resolve_request/2` refuse it
  whatever the signal, and no ticket can enter it again.

  The edge table is selected by the repo's resolved state-machine version (`StateMachine.version/1`),
  taken from `ctx`: the repo's `:settings` when the caller has them, else resolved from
  `ctx[:repo_key]`, so a designed repo never runs the legacy table just because a caller omitted the
  settings. `edges/1` returns the `legacy` table or the `designed` one. The `designed` table is the
  legacy rows plus the redesigned flow's own edges — the explicit `:handoff` into `Code Review` and
  the reviewer run's three verdict edges; flow tickets replace rows in the `designed` table, never
  the legacy one, so a repo left on `legacy` keeps today's behavior exactly.
  """

  alias SymphonyElixir.{Config, HumanReview, StateMachine, SubIssueWait, Tracker}

  @in_review_state "In Review"
  @in_progress_state "In Progress"
  @merging_state "Merging"
  @rework_state "Rework"
  @backlog_state "Backlog"
  @retired_states ["Auto Review"]

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

  @edges [
    # Claim: the workpad bootstrap moves a Todo ticket to In Progress before its first turn.
    %{signal: :claim, from: ["Todo"], to: "In Progress"},
    # A person commented on a plan under review: the parent returns to In Progress to revise it.
    # (The designed table replaces this row: a designed parent is revised through `Rework`.)
    %{signal: :plan_revise, from: ["In Review", "Waiting on sub-tickets"], to: "In Progress"},
    # A person approved the plan: the parent waits on its sub-tickets.
    %{signal: :plan_approve, from: ["In Review"], to: :waiting_on_sub_issues},
    # A run's PR is open and quiet: hand the issue off to the post-PR state.
    %{signal: :post_pr_handoff, from: ["In Progress", "Rework"], to: :requested},
    # A reviewer blocked the run: park the issue in the configured blocked state.
    %{signal: :review_agent_blocked, from: :any, to: :requested},
    # A red head: dispatch a CI fix run in In Progress.
    %{signal: :ci_fix_dispatch, from: :any, to: "In Progress"},
    # CI could not be fixed: escalate to In Review. (The designed table drops this row: a designed
    # repo pauses the ticket on a Needs Decision hold instead of moving it.)
    %{signal: :ci_escalate, from: :any, to: @in_review_state},
    # The PR review poller's target (Done or In Progress).
    %{signal: :pr_review_target, from: :any, to: :requested},
    # A landing run's PR merged: Done.
    %{signal: :landing_done, from: ["Merging"], to: "Done"},
    # The poller sends an issue back for changes.
    %{signal: :review_rework, from: :any, to: "In Progress"},
    # A dependency needs approval: the run waits in In Review.
    %{signal: :dependency_review, from: ["In Progress"], to: "In Review"},
    # A Todo ticket whose dependencies need a person waits in In Review.
    %{signal: :dependency_hold, from: ["Todo"], to: "In Review"},
    # The Linear tool records an `## Action needed:` request: the issue waits in the human review state.
    %{signal: :human_action_request, from: :any, to: :requested},
    # Withdrawing the last open request: the issue goes back to the active state it came from.
    %{signal: :human_action_release, from: :any, to: :requested},
    # A green fix run with nothing to push returns the issue to Merging.
    %{signal: :merge_ready, from: ["Rework", "In Progress"], to: "Merging"},
    # An idle run is parked in Backlog.
    %{signal: :idle_park, from: ["In Progress", "Rework"], to: "Backlog"},
    # A Director-app move (a person's decision); the target is the requested state.
    %{signal: :director_move, from: :any, to: :requested},
    # Every sub-issue is terminal: Done.
    %{signal: :sub_issues_done, from: ["Waiting on sub-tickets"], to: "Done"},
    # A PR merged with sub-issues still open: wait on them.
    %{signal: :wait_on_merge, from: ["Merging"], to: :waiting_on_sub_issues},
    # Plan approval promotes a Backlog sub-ticket to Todo.
    %{signal: :breakdown_promote, from: ["Backlog"], to: "Todo"},
    # Re-planning cancels a Backlog sub-ticket (the caller supplies the canceled state it finds).
    %{signal: :breakdown_cancel, from: ["Backlog"], to: :requested}
  ]

  # The designed machine's edge table: the legacy rows plus the edges the redesigned flow adds, with
  # the rows the redesigned flow replaces taken out. Flow tickets replace rows here — never in
  # `@edges` — so a repo left on `legacy` keeps today's behavior exactly.
  #
  # `:handoff` is the explicit handoff signal: `In Progress` (or `Rework`) enters `Code Review`
  # only on it, never when a run merely goes quiet. Its target is the repo's configured Code
  # Review state, so a repo that names it differently still lands there.
  #
  # `:restart` is the Director app's full reset: close the pull request, start a fresh branch from
  # main, supersede the workpad, back to `In Progress`. Only a person performs it (the control
  # API's `restart` move), which is why `resolve_request/2` refuses an agent asking for
  # `In Progress` from a post-implementation phase on a designed repo: that request is a restart
  # without the reset.
  #
  # The `:code_review_*` rows are the reviewer run's verdicts. They bind to the head the reviewer
  # judged (`SymphonyElixir.CodeReview` records the verdict against it): approve carries the ticket
  # on to the QA state, or straight to `Merging` when the QA state's skip rule applies (the
  # deterministic docs-only/internal-only diff — the caller picks the row and records the reason); and
  # a rework verdict returns it to `Rework`. An escalation has no row: it is a Needs Decision hold
  # (`SymphonyElixir.NeedsDecisionHold.pause/3`), which pauses the ticket in Code Review and never
  # moves it, and so is CI that could not be fixed (`:ci_escalate` is a legacy-only row).
  #
  # The `:qa_*` rows are the QA run's verdicts (`SymphonyElixir.QaVerification`): pass carries the
  # ticket to `Merging`, fail returns it to `Rework`, and a skip — the same hybrid rule seen from the
  # QA state — carries it to `Merging` without a run.
  #
  # The `:ci_fix_enter_*` rows are the CI Fix lane's entries (`SymphonyElixir.CiFix`): one row per
  # phase whose head can go red or conflict, so each origin is its own legal edge and the caller
  # records that origin on the ticket. `:ci_fix_mechanical` is the return — the target is the origin
  # the caller read back from the ticket, so the lane never has to name a state itself.
  #
  # The `:epic_review_*` rows are the epic path's close (`SymphonyElixir.EpicReview`). A designed
  # repo's epic parent whose sub-issues are all terminal enters `Epic Review` from the waiting state,
  # and the review's verdict either closes the epic or sends it back: `Done` when the epic's intent
  # holds, and the waiting state when gaps were found, with the gaps filed as follow-ups in `Todo`
  # inside the same epic — never `Backlog`, which would freeze the epic with nobody noticing. The
  # parent's own open follow-up holds it waiting until that follow-up lands, and the review runs
  # again. `:epic_review_enter`'s target is the repo's configured Epic Review state and
  # `:epic_review_gaps`'s the configured waiting state, so a repo that names either differently
  # still lands where the design says.
  #
  # The lane's other two exits have no row, because they are not machine moves: a repair the fixing
  # agent judges substantive is the agent's own request to set `Rework` (an agent state request is
  # validated by `resolve_request/2`, never performed through this table), and a repair it cannot
  # make without access or a secret is a Needs Decision hold (`SymphonyElixir.Hold`), which never
  # moves the ticket at all. Both are recorded as a `fix verdict`.
  #
  # `:plan_revise` is the one legacy row the redesigned flow replaces: a designed repo's plan parent
  # is revised through `Rework` — the epic path's re-plan, which continues in place and hands the
  # plan back to `Plan Review` — instead of through `In Progress`. The row names the epic path's
  # `Plan Review` literally, the state the guard's redirect puts the parent in whatever the repo
  # calls it (`HumanReview.plan_review_state/1`); the move itself is the machine's own, recorded with
  # `RunStore.put_own_state_move/2`, so `SymphonyElixir.BreakdownReview` never reads it as a person's
  # rejection of the plan (only a person's move to `Rework` cancels the plan's sub-tickets).
  @designed_replaced_edges [
    %{signal: :plan_revise, from: ["Plan Review"], to: "Rework"}
  ]

  @designed_replaced_signals Enum.map(@designed_replaced_edges, & &1.signal)

  # Legacy rows the designed machine has no use for: an escalation pauses the ticket on a Needs
  # Decision hold instead of moving it.
  @designed_dropped_signals [:ci_escalate]

  # `confirm: true` marks the three rows whose move is a *verdict* carrying the ticket into `Merging`:
  # with the repo's manual review `on`, each waits for a person instead
  # (`SymphonyElixir.MergeConfirmation`). The rows that repair a red head (`:ci_fix_mechanical`, whose
  # target is the origin the caller read back) and the rework rows carry no marker, so a repair or a
  # rework never waits on a person in either mode.
  @designed_edges Enum.reject(@edges, &(&1.signal in @designed_replaced_signals or &1.signal in @designed_dropped_signals)) ++
                    @designed_replaced_edges ++
                    [
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
                      %{signal: :epic_review_enter, from: ["Waiting on sub-tickets"], to: :epic_review_state},
                      %{signal: :epic_review_pass, from: ["Epic Review"], to: "Done"},
                      %{signal: :epic_review_gaps, from: ["Epic Review"], to: :waiting_on_sub_issues}
                    ]

  # States an agent's request may never set, with the refusal it gets. Moving to `Merging` is how a
  # person approves a merge, so an agent may not do it.
  @human_only_states [
    %{name: @merging_state, error: :merging_requires_human_approval}
  ]

  @doc "The states no move may enter: they are retired, and only drain."
  @spec retired_states() :: [String.t()]
  def retired_states, do: @retired_states

  @doc "Whether `state` names a retired state (`retired_states/0`)."
  @spec retired_state?(String.t() | nil) :: boolean()
  def retired_state?(state), do: Enum.any?(@retired_states, &state_name_matches?(state, &1))

  @doc "The legal-edge table for the default version."
  @spec edges() :: [edge()]
  def edges, do: edges(StateMachine.default_version())

  @doc "The legal-edge table for `version`."
  @spec edges(StateMachine.version()) :: [edge()]
  def edges(version) do
    if version == "designed", do: @designed_edges, else: @edges
  end

  @doc "Every signal the default table defines."
  @spec signals() :: [signal()]
  def signals, do: signals(StateMachine.default_version())

  @doc "Every signal the table for `version` defines."
  @spec signals(StateMachine.version()) :: [signal()]
  def signals(version), do: Enum.map(edges(version), & &1.signal)

  @doc """
  True when `signal` is a known edge and `from` is one of its origins (`:any` accepts any state).
  With `to` given, it must also match the edge's literal target; a config-derived or requested
  target accepts any `to`. The edge table comes from `version`.
  """
  @spec legal?(signal(), String.t() | nil, String.t() | nil, StateMachine.version()) :: boolean()
  def legal?(signal, from, to \\ nil, version \\ StateMachine.default_version()) do
    case edge(signal, version) do
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
    case edge(signal, version(ctx)) do
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
  config-derived targets and `ctx.target` for a requested one; `ctx.settings` or `ctx.repo_key`
  resolves the repo's state-machine version and so selects the edge table.
  """
  @spec target(signal(), context()) :: String.t()
  def target(signal, ctx) do
    edge(signal, version(ctx))
    |> case do
      nil -> raise ArgumentError, "unknown transition signal: #{inspect(signal)}"
      %{to: to} -> resolve(to, ctx)
    end
  end

  @doc """
  Performs the move `signal` names for `issue_id`, resolving its target from `ctx`. This is the one
  caller of `Tracker.update_issue_state/2`; `opts[:tracker]` overrides the tracker (tests, a fake).
  A move into a retired state is refused with `{:error, {:retired_state, target}}`.
  """
  @spec perform(String.t(), signal(), context(), keyword()) :: :ok | {:error, term()}
  def perform(issue_id, signal, ctx \\ %{}, opts \\ []) do
    target = target(signal, ctx)

    if retired_state?(target),
      do: {:error, {:retired_state, target}},
      else: Keyword.get(opts, :tracker, Tracker).update_issue_state(issue_id, target)
  end

  @doc """
  Validates an agent's request to set the state `state` (its resolved Linear state map). Applies
  the machine's refusals and redirects in the same order as before — the retired-state refusal,
  the Plan Review entry refusal, the plan-review and Human Review redirects, the
  human-only refusal, the restart refusal, the Code Review entry refusal, the QA entry refusal,
  the Epic Review entry refusal, then the waiting-state refusal — and returns `{:ok, state}` (the
  state to set, after any redirect) or `{:error, reason}` with the same tuple the tool returned
  before. On a repo running the designed machine, an agent asking to enter `Code Review` or `QA` by
  hand is refused: `Code Review` is the handoff signal's to enter and `QA` the verdict's, never the
  tool's. So is an agent asking for `In Progress` from a phase past implementation (`Rework`,
  `Code Review`, `QA` or `Merging`): on the designed machine that is a `Restart`, which only a
  person performs. `Epic Review` is refused the same way: the machine enters it once an epic
  parent's sub-issues are all terminal and its review's verdict leaves it.

  A designed repo's plan parent is redirected to its configured `Plan Review` state whatever runs:
  the run hands the plan over by naming `Plan Review` or the review state (see `ctx`'s
  `:plan_parent?`), and an agent naming `Plan Review` for anything but a plan parent is refused —
  the epic path's plan state is the plan handoff's to enter. A legacy repo keeps the `In Review` /
  Human Review handoff exactly as before.

  On a repo running the designed machine, an agent asking to park its issue in `Backlog` while it
  is `In Progress` or `Rework` is not a move: the guard returns `{:hold, :blocked, attrs}`, which
  pauses the ticket in its phase with a recorded reason instead of moving it (the Backlog escape
  hatch is retired there). Every other request, and every legacy repo, returns `{:ok, state}` or
  `{:error, reason}` as before.

  `ctx` carries `:settings`, `:states` (the team's states, for the redirects), `:from_state` (the
  issue's current state), `:plan_parent?` (the issue carries the `plan` label, so it is a designed repo's epic
  parent), and `:needs_person?` (the ticket's own rule says a person reviews it, or the run asked
  for a person).
  """
  @spec resolve_request(map(), context()) ::
          {:ok, map()} | {:hold, :blocked | :needs_decision, map()} | {:error, term()}
  def resolve_request(%{"name" => state_name} = state, ctx) do
    settings = Map.fetch!(ctx, :settings)

    case hold_request(state_name, ctx, settings) do
      {:hold, kind, attrs} ->
        {:hold, kind, attrs}

      :not_a_hold ->
        with :ok <- refuse_retired_state(state_name),
             :ok <- refuse_plan_review_entry(state_name, ctx, settings),
             state = redirect_state(state, ctx, settings),
             :ok <- refuse_human_only(state),
             :ok <- refuse_restart_state(state, ctx, settings),
             :ok <- refuse_code_review_entry(state, settings),
             :ok <- refuse_qa_entry(state, settings),
             :ok <- refuse_epic_review_entry(state, settings),
             :ok <- refuse_waiting_state(state, settings) do
          {:ok, state}
        end
    end
  end

  # On a designed repo the Backlog escape hatch is retired: an agent asking to park an issue it is
  # working in Backlog has hit a block, so the guard turns the request into a Blocked hold instead
  # of a state move — the ticket keeps its phase. Every other request, and every legacy repo, is
  # not a hold.
  defp hold_request(state_name, ctx, settings) do
    if StateMachine.designed?(settings) and state_name_matches?(state_name, @backlog_state) and
         running_phase?(Map.get(ctx, :from_state)) do
      {:hold, :blocked,
       %{
         reason: "the run reported a block",
         clearing_condition: "when the block is resolved; a person clears an access hold",
         waits_on: %{type: "access", keys: []}
       }}
    else
      :not_a_hold
    end
  end

  defp running_phase?(from) when is_binary(from),
    do: state_name_matches?(from, "In Progress") or state_name_matches?(from, "Rework")

  defp running_phase?(_from), do: false

  defp refuse_retired_state(state_name) do
    if retired_state?(state_name), do: {:error, {:retired_state, state_name}}, else: :ok
  end

  # An issue only a person can move on goes to the Human Review state instead of `In Review`, when
  # the state is available: a `breakdown` plan whose ticket says a person reviews it, and the issue
  # of a run that asked a person for something.
  #
  # A designed repo's plan parent goes to its configured `Plan Review` state instead of either: the
  # epic path's plan review is its own state, and no rule about the ticket's text decides it. The
  # plan run still hands over by asking for the review state it has always asked for; the machine
  # owns where the plan lands.
  defp redirect_state(state, ctx, settings) do
    case plan_review_redirect(state, ctx, settings) do
      %{"id" => _} = plan_review -> plan_review
      nil -> human_review_redirect(state, ctx, settings)
    end
  end

  defp plan_review_redirect(%{"name" => state_name}, ctx, settings) do
    with true <- Map.get(ctx, :plan_parent?, false),
         true <- state_name_matches?(state_name, @in_review_state),
         plan_review when is_binary(plan_review) <- HumanReview.plan_review_state(settings),
         %{"id" => _} = state <- Enum.find(Map.get(ctx, :states, []), &state_name_matches?(&1["name"], plan_review)) do
      state
    else
      _keep -> nil
    end
  end

  defp human_review_redirect(state, ctx, settings) do
    with true <- HumanReview.enabled?(settings),
         true <- Map.get(ctx, :needs_person?, false),
         %{"id" => _} = human_review <- Enum.find(Map.get(ctx, :states, []), &state_name_matches?(&1["name"], HumanReview.state(settings))) do
      human_review
    else
      _keep -> state
    end
  end

  defp refuse_human_only(%{"name" => state_name}) do
    case Enum.find(@human_only_states, &state_name_matches?(state_name, &1.name)) do
      nil -> :ok
      %{error: error} -> {:error, {error, state_name}}
    end
  end

  # Entering `Code Review` on a designed repo is the handoff signal's job, so an agent's request to
  # set the state by hand is refused. The handoff is emitted mechanically by the push and PR tool
  # hooks and performed by the runner, never by an agent asking for the state.
  defp refuse_code_review_entry(%{"name" => state_name}, settings) do
    if StateMachine.designed?(settings) and state_name_matches?(state_name, settings.tracker.code_review_state),
      do: {:error, {:code_review_requires_handoff_signal, state_name}},
      else: :ok
  end

  # `Plan Review` is a designed repo's plan handoff: the plan run hands the plan over by naming
  # `Plan Review` (or the review state it used to ask for, which `plan_review_redirect/3` turns into
  # `Plan Review`). Any other ticket naming `Plan Review` is refused, so the state belongs to the plan
  # handoff, not to the tool. The request is judged by the name asked for, before any redirect.
  defp refuse_plan_review_entry(state_name, ctx, settings) do
    with false <- Map.get(ctx, :plan_parent?, false),
         true <- StateMachine.designed?(settings),
         plan_review when is_binary(plan_review) <- HumanReview.plan_review_state(settings),
         true <- state_name_matches?(state_name, plan_review) do
      {:error, {:plan_review_requires_handoff_signal, state_name}}
    else
      _keep -> :ok
    end
  end

  # `Restart` is a person's move — the control API closes the pull request, starts a fresh branch
  # from main and supersedes the workpad before it moves the ticket back to `In Progress`. An agent
  # asking for `In Progress` from a post-implementation phase on a designed repo is asking for that
  # restart without its reset, so it is refused; the claim from `Todo` and every move the machine
  # makes itself are unaffected. A legacy repo has no `Restart`, so nothing is refused there.
  defp refuse_restart_state(%{"name" => state_name}, ctx, settings) do
    if StateMachine.designed?(settings) and state_name_matches?(state_name, @in_progress_state) and
         restart_origin?(Map.get(ctx, :from_state), settings),
       do: {:error, {:restart_requires_human_approval, state_name}},
       else: :ok
  end

  # The phases past implementation: work is on a pull request there, so `In Progress` can only mean
  # a fresh start. `Rework` is the designed machine's rework phase, not a way back to In Progress.
  defp restart_origin?(from, settings) do
    Enum.any?(
      [@rework_state, @merging_state, settings.tracker.code_review_state, settings.tracker.qa_state],
      &state_name_matches?(from, &1)
    )
  end

  # Entering `QA` on a designed repo is the QA verdict's job (a pass, or the Code Review approve that
  # skips it), so an agent's request to set the state by hand is refused the same way the Code Review
  # entry is.
  defp refuse_qa_entry(%{"name" => state_name}, settings) do
    if StateMachine.designed?(settings) and state_name_matches?(state_name, settings.tracker.qa_state),
      do: {:error, {:qa_requires_verdict, state_name}},
      else: :ok
  end

  # Entering `Epic Review` is the epic path's own move: the machine enters it when a designed repo's
  # parent has every sub-issue terminal, and the review's verdict leaves it. An agent's request to
  # set the state by hand is refused the same way the Code Review and QA entries are.
  defp refuse_epic_review_entry(%{"name" => state_name}, settings) do
    if StateMachine.designed?(settings) and state_name_matches?(state_name, settings.tracker.epic_review_state),
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

  defp edge(signal, version), do: Enum.find(edges(version), &(&1.signal == signal))

  # The repo's version: the caller's resolved settings when it passed them, else resolved from the
  # repo key it passed, else the default. Resolving here keeps a designed repo off the legacy table
  # even when a caller only knows its `repo_key`.
  defp version(ctx) do
    case Map.get(ctx, :settings) do
      nil -> ctx |> Map.get(:repo_key) |> version_for_repo()
      settings -> StateMachine.version(settings)
    end
  end

  defp version_for_repo(nil), do: StateMachine.default_version()

  defp version_for_repo(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> StateMachine.version(settings)
      {:error, _reason} -> StateMachine.default_version()
    end
  end

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
