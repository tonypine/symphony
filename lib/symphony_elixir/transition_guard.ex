defmodule SymphonyElixir.TransitionGuard do
  @moduledoc """
  The one writer for ticket state moves.

  Every Linear state move routes through this module. The machine's own moves — the orchestrator,
  the CI and PR review pollers, the Auto Review machinery, the runner, the Director app, the
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
  `:code_review_state`, `:waiting_on_sub_issues` and `:ci_escalation_state`.

  The edge table is selected by the repo's resolved state-machine version (`StateMachine.version/1`),
  taken from `ctx`: the repo's `:settings` when the caller has them, else resolved from
  `ctx[:repo_key]`, so a designed repo never runs the legacy table just because a caller omitted the
  settings. `edges/1` returns the `legacy` table or the `designed` one. The `designed` table is the
  legacy rows plus the redesigned flow's own edges — the explicit `:handoff` into `Code Review` and
  the reviewer run's three verdict edges; flow tickets replace rows in the `designed` table, never
  the legacy one, so a repo left on `legacy` keeps today's behavior exactly.
  """

  alias SymphonyElixir.{AutoReview, Config, HumanReview, StateMachine, SubIssueWait, Tracker}

  @in_review_state "In Review"
  @merging_state "Merging"
  @backlog_state "Backlog"

  @typedoc "A named transition the machine can perform."
  @type signal :: atom()

  @typedoc "What a caller knows that the target and the guards need."
  @type context :: map()

  @typedoc """
  One row of the legal-edge table: the signal, the states it may fire from (`:any` when the machine
  derives the origin itself), and the target it moves to.
  """
  @type edge :: %{signal: signal(), from: [String.t()] | :any, to: String.t() | atom()}

  @edges [
    # Claim: the workpad bootstrap moves a Todo ticket to In Progress before its first turn.
    %{signal: :claim, from: ["Todo"], to: "In Progress"},
    # A person commented on a plan under review: the parent returns to In Progress to revise it.
    %{signal: :plan_revise, from: ["In Review", "Waiting on sub-tickets"], to: "In Progress"},
    # A person approved the plan: the parent waits on its sub-tickets.
    %{signal: :plan_approve, from: ["In Review"], to: :waiting_on_sub_issues},
    # A run's PR is open and quiet: hand the issue off to the post-PR state.
    %{signal: :post_pr_handoff, from: ["In Progress", "Rework"], to: :requested},
    # A reviewer blocked the run: park the issue in the configured blocked state.
    %{signal: :review_agent_blocked, from: :any, to: :requested},
    # A red head: dispatch a CI fix run in In Progress.
    %{signal: :ci_fix_dispatch, from: :any, to: "In Progress"},
    # CI could not be fixed: escalate to the configured escalation state.
    %{signal: :ci_escalate, from: :any, to: :ci_escalation_state},
    # The PR review poller's target (the Auto Review state, or Done/In Progress).
    %{signal: :pr_review_target, from: :any, to: :requested},
    # A landing run's PR merged: Done.
    %{signal: :landing_done, from: ["Merging"], to: "Done"},
    # The poller sends an issue back for changes.
    %{signal: :review_rework, from: :any, to: "In Progress"},
    # A QA verdict moves the issue on (pass/fail/escalate); the target is verdict-derived.
    %{signal: :auto_review_verdict, from: ["Auto Review"], to: :requested},
    # The acceptance gate's move (approve/rework/escalate); the target is gate-derived.
    %{signal: :auto_review_gate, from: ["Auto Review"], to: :requested},
    # A conflicting PR with no checks goes to Rework.
    %{signal: :auto_review_rework, from: ["Auto Review"], to: "Rework"},
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
    %{signal: :breakdown_cancel, from: ["Backlog"], to: :requested},
    # A parent walkthrough's verdict moves the verification ticket; the target is verdict-derived.
    %{signal: :parent_walkthrough, from: :any, to: :requested}
  ]

  # The designed machine's edge table: the legacy rows plus the edges the redesigned flow adds.
  # Flow tickets replace rows here — never in `@edges` — so a repo left on `legacy` keeps today's
  # behavior exactly.
  #
  # `:handoff` is the explicit handoff signal: `In Progress` (or `Rework`) enters `Code Review`
  # only on it, never when a run merely goes quiet. Its target is the repo's configured Code
  # Review state, so a repo that names it differently still lands there.
  #
  # The three `:code_review_*` rows are the reviewer run's verdicts. They bind to the head the
  # reviewer judged (`SymphonyElixir.CodeReview` records the verdict against it): approve carries
  # the ticket on to `Merging` (the QA-skipped policy path), a rework verdict returns it to
  # `Rework`, and an escalation asks for a person through the request machinery.
  @designed_edges @edges ++
                    [
                      %{signal: :handoff, from: ["In Progress", "Rework"], to: :code_review_state},
                      %{signal: :code_review_approve, from: ["Code Review"], to: :requested},
                      %{signal: :code_review_rework, from: ["Code Review"], to: "Rework"},
                      %{signal: :code_review_escalate, from: ["Code Review"], to: :requested}
                    ]

  # States an agent's request may never set, with the refusal it gets. Moving to `Merging` is how a
  # person approves a merge, so an agent may not do it.
  @human_only_states [
    %{name: @merging_state, error: :merging_requires_human_approval}
  ]

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
  """
  @spec perform(String.t(), signal(), context(), keyword()) :: :ok | {:error, term()}
  def perform(issue_id, signal, ctx \\ %{}, opts \\ []) do
    Keyword.get(opts, :tracker, Tracker).update_issue_state(issue_id, target(signal, ctx))
  end

  @doc """
  Validates an agent's request to set the state `state` (its resolved Linear state map). Applies
  the machine's refusals and redirects in the same order as before — the Auto Review handoff
  refusal, the Human Review redirect, the human-only refusal, the Code Review entry refusal, then
  the waiting-state refusal — and returns `{:ok, state}` (the state to set, after any redirect) or
  `{:error, reason}` with the same tuple the tool returned before. On a repo running the designed
  machine, an agent asking to enter `Code Review` by hand is refused: the state is the handoff
  signal's to enter, never the tool's.

  On a repo running the designed machine, an agent asking to park its issue in `Backlog` while it
  is `In Progress` or `Rework` is not a move: the guard returns `{:hold, :blocked, attrs}`, which
  pauses the ticket in its phase with a recorded reason instead of moving it (the Backlog escape
  hatch is retired there). Every other request, and every legacy repo, returns `{:ok, state}` or
  `{:error, reason}` as before.

  `ctx` carries `:settings`, `:states` (the team's states, for the redirect), `:from_state` (the
  issue's current state), `:pr_less?` (a plan parent or a `Final verification:` ticket opens no
  PR), and `:needs_person?` (the ticket's own rule says a person reviews it, or the run asked for a
  person).
  """
  @spec resolve_request(map(), context()) ::
          {:ok, map()} | {:hold, :blocked | :needs_decision, map()} | {:error, term()}
  def resolve_request(%{"name" => state_name} = state, ctx) do
    settings = Map.fetch!(ctx, :settings)

    case hold_request(state_name, ctx, settings) do
      {:hold, kind, attrs} ->
        {:hold, kind, attrs}

      :not_a_hold ->
        with :ok <- refuse_handoff_state(state_name, Map.get(ctx, :pr_less?, false), settings),
             state = redirect_state(state, ctx, settings),
             :ok <- refuse_human_only(state),
             :ok <- refuse_code_review_entry(state, settings),
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

  # With Auto Review on, Symphony moves the issue on from the PR being open, so an agent asking for
  # `In Review` or the Human Review state is refused rather than silently redirected. A `breakdown`
  # parent and a `Final verification:` ticket open no PR: their result goes to a person whatever
  # Auto Review says.
  defp refuse_handoff_state(state_name, pr_less?, settings) do
    if AutoReview.enabled?(settings) and not pr_less? and
         (state_name_matches?(state_name, AutoReview.review_state()) or HumanReview.in_state?(state_name, settings)),
       do: {:error, {:in_review_set_by_auto_review, state_name, AutoReview.state(settings)}},
       else: :ok
  end

  # An issue only a person can move on goes to the Human Review state instead of `In Review`, when
  # the state is available: a `breakdown` plan whose ticket says a person reviews it, and the issue
  # of a run that asked a person for something.
  defp redirect_state(state, ctx, settings) do
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
  defp resolve(:waiting_on_sub_issues, ctx), do: SubIssueWait.state(settings!(ctx))
  defp resolve(:ci_escalation_state, ctx), do: settings!(ctx).ci.escalation_state || @in_review_state
  defp resolve(name, _ctx) when is_binary(name), do: name

  defp settings!(ctx), do: Map.fetch!(ctx, :settings)

  defp state_name_matches?(name, expected) when is_binary(name) and is_binary(expected),
    do: String.downcase(String.trim(name)) == String.downcase(String.trim(expected))

  defp state_name_matches?(_name, _expected), do: false
end
