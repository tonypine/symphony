defmodule SymphonyElixir.DirectorMoves do
  @moduledoc """
  The Linear moves the Director makes from the Mac app's Inbox, through the control API
  (`POST /api/v1/control/<move>`, decision DD4 in `docs/design/director-app-screens.md`).

  Each move reads the ticket, refuses one the workflow doesn't allow from its current state
  (`{:error, {:conflict, message}}`, a 409), posts its comment when it has one, makes the Linear
  move, writes a `director_move` audit record and answers with the states it moved between:

  - `:approve_plan`: a plan (label `plan` or `breakdown`) in `Plan Review` moves to the waiting
    state (`Waiting on sub-tickets`). It is a person's move, so Symphony promotes the plan's
    `Backlog` sub-tickets (`SymphonyElixir.BreakdownReview`);
  - `:rework`: a plan in `Plan Review` gets the reason as a comment, then moves to `Rework`, which
    rejects the plan; the full reset is `:restart`;
  - `:restart`: the full reset, and only a person makes it (design doc D7). It closes the ticket's
    pull requests, removes its workspaces — so the next dispatch branches fresh from the configured
    base branch — and supersedes the workpad, then moves the ticket to `In Progress`
    (`SymphonyElixir.Restart`). A dispatch-loop hold is cleared with it, since the loop's attempt is
    the one thrown away, and so is an operator's stop (`SymphonyElixir.OperatorStop`);
  - `:decisions`: a plan in `Plan Review` gets one comment with the picked options, in place, which
    starts Symphony's plan revision run (`SymphonyElixir.PlanComments`);
  - `:backlog`: an open ticket gets the note as a comment when there is one, then moves to `Backlog`;
  - `:unblock`: a ticket waiting on an **access** hold — an agent's block report — on a
    dispatch-loop hold (`SymphonyElixir.DispatchLoop`) or on an operator's stop
    (`SymphonyElixir.OperatorStop`) has the hold cleared by hand and continues
    in place, with no state move. So does one waiting on its competing pull requests (a landing
    hold, `SymphonyElixir.PrWatch.Competitors`): the blocked-by links Symphony added go, and it no
    longer waits on those pull requests. A dependency or fix-ticket hold clears on its own, so it is
    refused;
  - `:decide`: a ticket waiting on a `Needs Decision` hold gets the Director's answer as a reply
    under the request comment, written into the Decisions section of the description
    (`SymphonyElixir.Decisions`), and the hold is cleared so the ticket continues in its phase. The
    optional `:move` names a state the decision directs — `rework` or `done` — and the move goes
    through `SymphonyElixir.TransitionGuard`. A ticket with no such hold is refused.

  The comments are the Director's: none starts like one of Symphony's own, so the plan revision
  trigger counts them as a person's comment.

  When Linear takes the first of a move's two writes and refuses the second, the move answers
  `{:error, {:partial, message}}` saying what was already done, and still writes the audit record of
  what changed (with `failed` naming the write that didn't happen). A rework or backlog comment
  posted without its move is remembered, so sending the move again makes the move without posting
  the comment twice.

  `undo/2` takes back the last move on a ticket within 10 s of it, and only while
  the ticket is still in the state the move put it in, and, for an approved plan, before Symphony
  promoted its sub-tickets. The last move per ticket is kept in this module's Agent, so a restart
  forgets it.
  """

  use Agent

  require Logger

  alias SymphonyElixir.{
    AuditLog,
    BlockedHold,
    BreakdownReview,
    Config,
    Decisions,
    Hold,
    MergeConfirmation,
    OperatorStop,
    Orchestrator,
    PlanReview,
    PrWatch,
    Restart,
    SubIssueWait,
    TicketSignals,
    Tracker,
    TransitionGuard
  }

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Routing.Resolver

  @undo_window_ms 10_000
  @in_progress_state "In Progress"
  @merging_state "Merging"
  @rework_state "Rework"
  @done_state "Done"
  @backlog_state "Backlog"
  @todo_state "Todo"
  @comment_preview_chars 500

  @type move ::
          :approve_plan
          | :rework
          | :restart
          | :decisions
          | :backlog
          | :unblock
          | :decide
  @type pick :: %{question: String.t(), answer: String.t()}
  @type input :: %{
          optional(:reason) => String.t() | nil,
          optional(:note) => String.t() | nil,
          optional(:picks) => [pick()],
          optional(:request_comment_id) => String.t() | nil,
          optional(:move) => String.t() | nil
        }
  @type error ::
          {:invalid, String.t()}
          | {:conflict, String.t()}
          | {:restart, String.t()}
          | {:store, String.t()}
          | :issue_not_found
          | {:linear, term()}
          | {:partial, String.t()}
  @type result :: {:ok, map()} | {:error, error()}

  @moves [:approve_plan, :rework, :restart, :decisions, :backlog, :unblock, :decide]
  @decide_targets %{"rework" => @rework_state, "done" => @done_state, "merging" => @merging_state, "todo" => @todo_state}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The moves `move/4` makes."
  @spec moves() :: [move()]
  def moves, do: @moves

  @doc "How long after a move `undo/2` takes it back, in milliseconds."
  @spec undo_window_ms() :: pos_integer()
  def undo_window_ms, do: @undo_window_ms

  @doc """
  Makes `move` on the ticket `identifier` (its identifier or id). `input` carries the rework
  `:reason` (required), the backlog `:note` (optional), the decisions' `:picks` (required) or the
  decision's `:picks` (required) with the `:request_comment_id` they answer (required) and the
  optional `:move` the decision directs.

  Options: `:server` (the Agent, default this module), `:clock` (monotonic milliseconds, for the undo
  window), `:orchestrator` (asked to poll again after the move, default `SymphonyElixir.Orchestrator`)
  and `:store` (the run store read and written, default `SymphonyElixir.RunStore`).
  """
  @spec move(move(), String.t(), input(), keyword()) :: result()
  def move(move, identifier, input, opts \\ []) when move in @moves and is_binary(identifier) and is_map(input) do
    with :ok <- validate_input(move, input),
         {:ok, issue} <- fetch_issue(identifier) do
      do_move(move, issue, input, opts)
    end
  end

  # Unblock is not a Linear move: it lifts a hold in place, so no state is resolved.
  defp do_move(:unblock, issue, _input, opts), do: unblock(issue, opts)

  # Decide is a decision, not a state: it answers the request and clears the hold, and only moves
  # when the decision directs one.
  defp do_move(:decide, issue, input, opts), do: decide(issue, input, opts)

  defp do_move(move, issue, input, opts) do
    settings = Config.settings!()

    with {:ok, to_state} <- target(move, issue, settings),
         {:ok, comment} <- apply_move(move, issue, to_state, input, opts) do
      finish(move, issue, to_state, comment, opts)
    end
  end

  @doc """
  Takes back the last move on the ticket `identifier`: moves it back to the state it came from,
  within #{div(@undo_window_ms, 1000)} s of the move and only while it is still where the move put
  it. A comment the move posted stays. Takes the options of `move/4`.

  `:restart` is never taken back: it closed the pull request and removed the workspace, so the
  ticket stays in `In Progress`.
  """
  @spec undo(String.t(), keyword()) :: result()
  def undo(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, issue} <- fetch_issue(identifier),
         {:ok, last} <- undoable(issue, opts),
         :ok <- update_state(issue, last.from_state, :undo) do
      Agent.update(server(opts), &Map.delete(&1, issue.id))
      record_audit("undo", issue, issue.state, last.from_state, nil)
      Logger.info("Director undid #{last.move} issue_id=#{issue.id} issue_identifier=#{issue.identifier} state=#{last.from_state}")
      request_refresh(opts)

      {:ok,
       %{
         move: "undo",
         undone: Atom.to_string(last.move),
         issue_id: issue.id,
         issue_identifier: issue.identifier,
         from_state: issue.state,
         to_state: last.from_state
       }}
    end
  end

  @doc "The comment `:decisions` posts: each question with the option picked."
  @spec decisions_comment([pick()]) :: String.t()
  def decisions_comment(picks) when is_list(picks) do
    lines =
      picks
      |> Enum.with_index(1)
      |> Enum.map(fn {%{question: question, answer: answer}, index} -> "#{index}. #{question}\n   **Pick:** #{answer}" end)

    Enum.join(["Decisions on the plan, from the Director:" | lines], "\n\n")
  end

  @doc "The comment `:rework` posts with the Director's reason."
  @spec rework_comment(String.t()) :: String.t()
  def rework_comment(reason) when is_binary(reason), do: "Sent to Rework by the Director:\n\n#{reason}"

  @doc "The comment `:restart` posts: what the full reset did, then the Director's reason."
  @spec restart_comment(String.t(), String.t()) :: String.t()
  def restart_comment(identifier, reason) when is_binary(identifier) and is_binary(reason) do
    "Restarted by the Director: #{identifier} starts again from main — its pull requests are closed, its workspace is gone, " <>
      "and the workpad's prior attempt is superseded.\n\n#{reason}"
  end

  @doc "The comment `:backlog` posts with the Director's note."
  @spec backlog_comment(String.t()) :: String.t()
  def backlog_comment(note) when is_binary(note), do: "Moved to Backlog by the Director:\n\n#{note}"

  @doc "The comment `:unblock` posts: the hold is cleared and the ticket continues in place."
  @spec unblock_comment(String.t()) :: String.t()
  def unblock_comment(identifier) when is_binary(identifier),
    do: "Unblocked by the Director: #{identifier} continues in place."

  @doc "The reply `:decide` posts under the request: each question with the option the Director picked."
  @spec decide_comment([pick()]) :: String.t()
  def decide_comment(picks) when is_list(picks) do
    lines =
      picks
      |> Enum.with_index(1)
      |> Enum.map(fn {%{question: question, answer: answer}, index} -> "#{index}. #{question}\n   **Decision:** #{answer}" end)

    Enum.join(["Decision from the Director:" | lines], "\n\n")
  end

  defp validate_input(:rework, input) do
    if present?(input[:reason]), do: :ok, else: {:error, {:invalid, "reason is required"}}
  end

  defp validate_input(:restart, input) do
    if present?(input[:reason]), do: :ok, else: {:error, {:invalid, "reason is required"}}
  end

  defp validate_input(:decisions, %{picks: [_ | _] = picks}) do
    if Enum.all?(picks, &valid_pick?/1), do: :ok, else: invalid_picks()
  end

  defp validate_input(:decisions, _input), do: invalid_picks()

  defp validate_input(:decide, input) do
    cond do
      not (is_list(input[:picks]) and input[:picks] != [] and Enum.all?(input.picks, &valid_pick?/1)) -> invalid_picks()
      not present?(input[:request_comment_id]) -> {:error, {:invalid, "request_comment_id is required"}}
      not valid_decide_move?(input[:move]) -> {:error, {:invalid, "move must be #{inspect(Map.keys(@decide_targets))} or left out"}}
      true -> :ok
    end
  end

  defp validate_input(_move, _input), do: :ok

  defp invalid_picks, do: {:error, {:invalid, "picks must list each decision's question and answer"}}

  defp valid_decide_move?(nil), do: true
  defp valid_decide_move?(move) when is_binary(move), do: Map.has_key?(@decide_targets, String.downcase(String.trim(move)))
  defp valid_decide_move?(_move), do: false

  defp valid_pick?(%{question: question, answer: answer}), do: present?(question) and present?(answer)
  defp valid_pick?(_pick), do: false

  defp fetch_issue(identifier) do
    case Tracker.fetch_issue_by_identifier(identifier) do
      {:ok, %Issue{} = issue} -> {:ok, with_repo_key(issue)}
      {:error, :issue_not_found} -> {:error, :issue_not_found}
      {:error, reason} -> if not_found?(reason), do: {:error, :issue_not_found}, else: {:error, {:linear, reason}}
    end
  end

  # A fetched issue carries no repo key; its holds, signals and guard moves live under the repo it
  # routes to. The tracker fetch has just read the same config, so it is readable here.
  defp with_repo_key(%Issue{} = issue), do: Resolver.with_repo_key(issue, Config.system!().repos)

  # Linear answers an unknown identifier with an "Entity not found" GraphQL error.
  defp not_found?({:linear_graphql_errors, errors}), do: Enum.any?(List.wrap(errors), &(is_map(&1) and is_binary(&1["message"]) and &1["message"] =~ ~r/not found/i))
  defp not_found?(_reason), do: false

  # The state a move takes the ticket to (nil when it stays), or why the workflow doesn't allow it.
  defp target(:approve_plan, issue, settings) do
    with :ok <- require_plan(issue, "approve_plan"),
         :ok <- require_plan_review(issue, settings) do
      case SubIssueWait.enabled?(settings) && SubIssueWait.state(settings) do
        state when is_binary(state) -> {:ok, state}
        _off -> conflict("the waiting state is turned off, so a plan can't be approved from the app")
      end
    end
  end

  defp target(:rework, issue, settings) do
    with :ok <- require_plan_review(issue, settings), do: {:ok, @rework_state}
  end

  defp target(:restart, %Issue{state: state} = issue, settings) do
    if Enum.any?(settings.tracker.terminal_states, &same_state?(&1, state)),
      do: conflict("#{issue.identifier} is #{state}; only an open ticket can be restarted"),
      else: {:ok, @in_progress_state}
  end

  # The comment goes in place: a person's comment on a plan under review starts its revision run.
  defp target(:decisions, issue, settings) do
    with :ok <- require_plan(issue, "decisions"),
         :ok <- require_plan_review(issue, settings),
         do: {:ok, nil}
  end

  defp target(:backlog, %Issue{state: state} = issue, settings) do
    cond do
      same_state?(state, @backlog_state) -> conflict("#{issue.identifier} is already in Backlog")
      Enum.any?(settings.tracker.terminal_states, &same_state?(&1, state)) -> conflict("#{issue.identifier} is #{state}; only an open ticket moves to Backlog")
      true -> {:ok, @backlog_state}
    end
  end

  defp require_plan(issue, move) do
    if Issue.breakdown?(issue), do: :ok, else: conflict("#{issue.identifier} is not a plan; #{move} is for a plan")
  end

  # The Director answers a plan a person is reviewing: one in `Plan Review`.
  defp require_plan_review(%Issue{state: state} = issue, settings) do
    case PlanReview.state(settings) do
      plan_review when is_binary(plan_review) ->
        if PlanReview.in_state?(state, settings),
          do: :ok,
          else: conflict("#{issue.identifier} is #{state || "in no state"}; the Director answers it only from #{plan_review}")

      nil ->
        conflict("the Plan Review state is turned off, so the Director can't answer #{issue.identifier} from the app")
    end
  end

  defp conflict(message), do: {:error, {:conflict, message}}

  # The comment goes before the move, so the run the move starts reads it.
  defp apply_move(:rework, issue, to_state, %{reason: reason}, opts),
    do: comment_then_move(:rework, issue, rework_comment(String.trim(reason)), to_state, opts)

  # The reset runs before the comment and the move, so a failure stops the move: the Inbox shows
  # what GitHub or Linear refused, and the ticket stays where it is until the person tries again.
  defp apply_move(:restart, issue, to_state, input, opts) do
    case Restart.perform(issue, restart_opts(opts)) do
      :ok ->
        clear_restarted_hold(issue, opts)
        comment_then_move(:restart, issue, restart_comment(issue.identifier, String.trim(input[:reason])), to_state, opts)

      {:error, {:restart, message}} ->
        {:error, {:restart, "#{issue.identifier} was not restarted: #{message}"}}
    end
  end

  defp apply_move(:backlog, issue, to_state, input, opts) do
    if present?(input[:note]),
      do: comment_then_move(:backlog, issue, backlog_comment(String.trim(input.note)), to_state, opts),
      else: comment_then_move(:backlog, issue, nil, to_state, opts)
  end

  defp apply_move(:decisions, issue, nil, %{picks: picks}, _opts) do
    comment = picks |> Enum.map(&%{question: String.trim(&1.question), answer: String.trim(&1.answer)}) |> decisions_comment()

    with :ok <- post_comment(issue, comment), do: {:ok, comment}
  end

  defp apply_move(move, issue, to_state, _input, opts), do: comment_then_move(move, issue, nil, to_state, opts)

  # The attempt a dispatch loop held is the one Restart throws away, so its hold goes with it and the
  # ticket starts again with its count at zero; an operator's stop is lifted by the Restart that
  # starts the ticket over. A clear the store refuses is reported; the restart stands, and Unblock
  # still lifts the hold.
  defp clear_restarted_hold(issue, opts) do
    hold = blocked_hold(issue, opts)

    with true <- Hold.dispatch_loop?(hold) or OperatorStop.hold?(hold),
         {:error, reason} <- Hold.clear(issue.repo_key, issue.id, :blocked, store_opts(opts)) do
      Logger.warning("Restarted #{issue.identifier} but couldn't clear its #{restarted_hold_name(hold)} hold: #{inspect(reason)}")
    end
  end

  defp restarted_hold_name(hold), do: if(Hold.dispatch_loop?(hold), do: "dispatch-loop", else: "operator-stop")

  # Unblock lifts an access or dispatch-loop hold in place: the store hold is cleared through `Hold`
  # (the store first, then the `Blocked` label), so the ticket keeps its phase and the next poll
  # dispatches it again — for a loop, with its count started again. A landing hold first has the PR
  # watcher release its competitors, so the next read doesn't wait on them again. A hold waiting on
  # anything else clears on its own, so it is refused.
  defp unblock(%Issue{} = issue, opts) do
    hold = blocked_hold(issue, opts)

    cond do
      Hold.unblockable?(hold) ->
        clear_access_hold(issue, opts)

      BlockedHold.landing?(hold) ->
        release_competitors(issue, opts)
        clear_access_hold(issue, opts)

      true ->
        access_conflict(issue)
    end
  end

  # A release that fails is reported: the hold still clears, and the watcher unlinks what it can on
  # its next read.
  defp release_competitors(issue, opts) do
    release = Keyword.get(opts, :release_competitors, &PrWatch.release_competitors/3)

    case release.(issue.repo_key, issue.id, store_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Unblocked #{issue.identifier} but couldn't release its competing pull requests: #{inspect(reason)}")
    end
  end

  defp access_conflict(issue), do: {:error, {:conflict, "#{issue.identifier} is not waiting on an access hold"}}

  defp clear_access_hold(issue, opts) do
    comment = unblock_comment(issue.identifier)

    case Hold.clear(issue.repo_key, issue.id, :blocked, store_opts(opts)) do
      :ok ->
        TicketSignals.record(issue.repo_key, issue.id, "unblocked", %{by: "the Director"})
        post_unblock_comment(issue, comment, opts)

      {:error, reason} ->
        {:error, {:store, "couldn't clear the hold on #{issue.identifier}: #{inspect(reason)}"}}
    end
  end

  # The hold is already cleared, so a comment Linear refuses is reported and does not undo it.
  defp post_unblock_comment(issue, comment, opts) do
    case post_comment(issue, comment) do
      :ok ->
        :ok

      {:error, {:linear, reason}} ->
        Logger.warning("Unblocked #{issue.identifier} but Linear refused the comment: #{inspect(reason)}")
        :ok
    end

    finish(:unblock, issue, nil, comment, opts)
  end

  # Decide answers a decision request. The reply under the request comment is what marks it answered
  # in Linear, so the next read no longer finds the request and the hold it set clears; the hold is
  # cleared here too, so the ticket continues at once, and the move the decision directs — when it
  # directs one — goes through the guard after it.
  #
  # A merge confirmation's hold carries the move confirming performs (`SymphonyElixir.MergeConfirmation`),
  # as a Code Review escalation's carries its QA state, so an answer that picks that option moves
  # the ticket exactly as it would with manual review off, and one that picks nothing moves nothing;
  # an explicit `:move` (the Inbox's Send to Rework) directs its own move instead.
  defp decide(%Issue{} = issue, input, opts) do
    case decision_hold(issue, opts) do
      {:ok, hold} -> answer(issue, input, hold, decide_target(input[:move], picked_move(hold, input.picks)), opts)
      :error -> conflict("#{issue.identifier} is not waiting on a decision")
    end
  end

  # The state a decision moves the ticket to: the Director's explicit move, else the one the hold
  # carries (a merge confirmation's `Merging`, a Code Review escalation's QA state), which is
  # already a state name. nil when the decision moves nothing.
  defp decide_target(nil, carried), do: carried
  defp decide_target(move, _carried), do: Map.fetch!(@decide_targets, String.downcase(String.trim(move)))

  # The target is resolved before anything is written: a decision directing a move into a state the
  # repo has not configured is refused while the request is still open and the hold still set,
  # rather than recorded, the hold cleared, and the move left to fail with the ticket in place.
  defp answer(issue, input, hold, to_state, opts) do
    if is_binary(to_state) and String.trim(to_state) == "" do
      {:error, {:invalid, "#{issue.identifier}'s decision moves it to a state not configured for repo #{issue.repo_key}; the hold stays"}}
    else
      picks = Enum.map(input.picks, &%{question: String.trim(&1.question), answer: String.trim(&1.answer)})
      comment = decide_comment(picks)

      case reply_to_request(issue, input.request_comment_id, comment) do
        :ok ->
          record_decision(issue, input.request_comment_id, hold, picks)
          clear_decision_hold(issue, to_state, comment, opts)

        {:error, reason} ->
          {:error, {:linear, reason}}
      end
    end
  end

  # The ticket's open Needs Decision hold; a ticket with no hold has no decision to answer.
  defp decision_hold(%Issue{repo_key: repo_key, id: issue_id}, opts) do
    case Hold.get(repo_key, issue_id, :needs_decision, store_opts(opts)) do
      nil -> :error
      hold -> {:ok, hold}
    end
  end

  # The answer goes into the ticket's scope now, so the run the cleared hold lets through reads it.
  # Best-effort: the decision is already recorded under the request, and the Inbox's next read
  # writes it from there when this write fails (`SymphonyElixir.Decisions.sync/2`).
  defp record_decision(issue, request_comment_id, hold, picks) do
    title = get_in(hold, [:decision, :title])
    question = get_in(hold, [:decision, :question]) || Enum.map_join(picks, " / ", & &1.question)
    entry = Decisions.entry(request_comment_id, Date.utc_today(), title, question, Enum.map_join(picks, " / ", & &1.answer))
    _ = Decisions.record(issue.id, [entry], repo_key: issue.repo_key)
    :ok
  end

  defp picked_move(hold, picks) do
    case MergeConfirmation.confirm_target(hold) && MergeConfirmation.picked(hold, Enum.map(picks, & &1.answer)) do
      {:ok, target} -> target
      _none -> nil
    end
  end

  defp reply_to_request(issue, comment_id, comment) do
    case Tracker.create_reply(issue.id, comment_id, comment) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_decision_hold(issue, to_state, comment, opts) do
    case Hold.clear(issue.repo_key, issue.id, :needs_decision, store_opts(opts)) do
      :ok -> decision_finish(issue, to_state, comment, opts)
      {:error, reason} -> {:error, {:store, "couldn't clear the hold on #{issue.identifier}: #{inspect(reason)}"}}
    end
  end

  defp decision_finish(issue, to_state, comment, opts) when is_binary(to_state) do
    case update_state(issue, to_state, :decide) do
      :ok -> finish(:decide, issue, to_state, comment, opts)
      {:error, {:linear, reason}} -> decision_move_refused(issue, to_state, reason, comment, opts)
    end
  end

  # With nothing to move, the ticket continues in its phase: the decision is recorded and the hold
  # is gone, so the next poll dispatches it again.
  defp decision_finish(issue, nil, comment, opts) do
    TicketSignals.record(issue.repo_key, issue.id, "decision returned", %{move: "decide", from: issue.state, to: issue.state})
    finish(:decide, issue, nil, comment, opts)
  end

  # The decision is recorded in Linear and the hold is already cleared, so a refused move is
  # reported without taking either back: the ticket continues in place, with the decision on it.
  defp decision_move_refused(issue, to_state, reason, comment, opts) do
    record_audit("decide", issue, issue.state, issue.state, comment, %{failed: "move", directed: to_state})
    request_refresh(opts)

    partial(
      "recorded the decision on #{issue.identifier} and cleared the hold, but Linear refused the move to " <>
        "#{to_state} (#{inspect(reason)}); #{issue.identifier} continues in place"
    )
  end

  defp comment_then_move(move, issue, comment, to_state, opts) do
    with :ok <- maybe_post_comment(issue, comment, opts) do
      case update_state(issue, to_state, move) do
        :ok ->
          Agent.update(server(opts), &Map.delete(&1, {:posted, issue.id}))
          {:ok, comment}

        {:error, {:linear, reason}} when is_binary(comment) ->
          commented_without_move(move, issue, comment, to_state, reason, opts)

        error ->
          error
      end
    end
  end

  # A comment posted on this ticket, in this state, by a move whose state change Linear refused
  # is not posted again.
  defp maybe_post_comment(_issue, nil, _opts), do: :ok

  defp maybe_post_comment(issue, comment, opts) do
    if Agent.get(server(opts), &Map.get(&1, {:posted, issue.id})) == {issue.state, comment},
      do: :ok,
      else: post_comment(issue, comment)
  end

  # Linear took the comment and refused the move: the comment is remembered, so sending the move
  # again doesn't post it twice.
  defp commented_without_move(move, issue, comment, to_state, reason, opts) do
    Agent.update(server(opts), &Map.put(&1, {:posted, issue.id}, {issue.state, comment}))
    record_audit(Atom.to_string(move), issue, issue.state, issue.state, comment, %{failed: "move"})

    partial(
      "posted the comment on #{issue.identifier}, but Linear refused the move to #{to_state} (#{inspect(reason)}); " <>
        "send it again to make the move without posting the comment twice"
    )
  end

  defp partial(message), do: {:error, {:partial, message}}

  defp post_comment(issue, comment) do
    case Tracker.create_comment(issue.id, comment) do
      :ok -> :ok
      {:error, reason} -> {:error, {:linear, reason}}
    end
  end

  # The Blocked hold in the store — the truth, whatever the board shows.
  defp blocked_hold(%Issue{repo_key: repo_key, id: issue_id}, opts), do: Hold.get(repo_key, issue_id, :blocked, store_opts(opts))

  defp store_opts(opts), do: Keyword.take(opts, [:store])

  # Restart moves through its own signal, whose target the edge table owns (`In Progress`),
  # rather than a requested one: the ledger then names the move `restart`, as the design doc's
  # signal vocabulary does.
  defp update_state(issue, to_state, :restart) do
    case TransitionGuard.perform(issue.id, :restart, %{repo_key: Map.get(issue, :repo_key), settings: Config.settings!()}) do
      :ok ->
        record_move_signal(issue, :restart, to_state)
        :ok

      {:error, reason} ->
        {:error, {:linear, reason}}
    end
  end

  defp update_state(issue, to_state, move) do
    case TransitionGuard.perform(issue.id, :director_move, %{target: to_state, repo_key: Map.get(issue, :repo_key)}) do
      :ok ->
        record_move_signal(issue, move, to_state)
        :ok

      {:error, reason} ->
        {:error, {:linear, reason}}
    end
  end

  # Best-effort recording of a Director move into the ticket's signals ledger (inert; a store
  # failure never changes the move). Runs only after the move has succeeded.
  defp record_move_signal(issue, move, to_state) do
    TicketSignals.record(issue.repo_key, issue.id, signal_name(move), %{
      move: Atom.to_string(move),
      from: issue.state,
      to: to_state
    })
  end

  defp signal_name(:restart), do: "restart"
  defp signal_name(_move), do: "decision returned"

  defp restart_opts(opts), do: Keyword.take(opts, [:github, :workspace, :settings, :linear_client, :now, :linear_retry_opts])

  defp finish(move, issue, to_state, comment, opts) do
    name = Atom.to_string(move)
    record_audit(name, issue, issue.state, to_state || issue.state, comment)
    Logger.info("Director move #{name} issue_id=#{issue.id} issue_identifier=#{issue.identifier} from=#{issue.state} to=#{to_state || issue.state}")

    if to_state, do: remember_move(move, issue, to_state, opts)
    request_refresh(opts)

    {:ok,
     %{
       move: name,
       issue_id: issue.id,
       issue_identifier: issue.identifier,
       from_state: issue.state,
       to_state: to_state || issue.state,
       moved: to_state != nil,
       commented: comment != nil,
       undo_window_ms: if(to_state && move != :restart, do: @undo_window_ms)
     }}
  end

  defp remember_move(move, issue, to_state, opts) do
    entry = %{move: move, from_state: issue.state, to_state: to_state, at_ms: now_ms(opts), backlog: BreakdownReview.backlog_sub_issue_ids(issue)}
    Agent.update(server(opts), &Map.put(&1, issue.id, entry))
  end

  defp undoable(issue, opts) do
    case Agent.get(server(opts), &Map.get(&1, issue.id)) do
      nil ->
        conflict("there is no move on #{issue.identifier} to undo")

      # A restart closed the pull request, deleted the workspace and superseded the workpad; none
      # of that comes back, so moving the ticket to its previous phase would strand it without its work.
      %{move: :restart} ->
        conflict("#{issue.identifier} was restarted; the pull request is closed and the workspace is gone, so it can't be undone")

      last ->
        cond do
          now_ms(opts) - last.at_ms > @undo_window_ms ->
            conflict("the move on #{issue.identifier} is more than #{div(@undo_window_ms, 1000)} s old; move it in Linear instead")

          not same_state?(issue.state, last.to_state) ->
            conflict("#{issue.identifier} moved on to #{issue.state} since; move it in Linear instead")

          # An approved plan whose sub-tickets Symphony promoted would come back to review approved.
          BreakdownReview.backlog_sub_issue_ids(issue) != last.backlog ->
            conflict("Symphony already promoted the sub-tickets of #{issue.identifier}; move them in Linear instead")

          true ->
            {:ok, last}
        end
    end
  end

  defp record_audit(move, issue, from_state, to_state, comment, extra \\ %{}) do
    %{
      event_type: "director_move",
      move: move,
      repo_key: issue.repo_key,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      from_state: from_state,
      to_state: to_state,
      comment: comment && String.slice(comment, 0, @comment_preview_chars)
    }
    |> Map.merge(extra)
    |> AuditLog.record()
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record director_move audit event: issue_id=#{issue.id} reason=#{inspect(reason)}")
    end
  end

  # The orchestrator polls again at once, so the Inbox and the dashboard follow the move. The move is
  # already made, so the request goes from a task: an orchestrator busy past the call's timeout
  # delays the refresh instead of turning the move's answer into an error.
  defp request_refresh(opts) do
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
    {:ok, _pid} = Task.start(fn -> refresh(orchestrator) end)
    :ok
  end

  defp refresh(orchestrator) do
    Orchestrator.request_refresh(orchestrator)
  catch
    :exit, reason -> Logger.warning("Director move couldn't ask the orchestrator to poll again: #{inspect(reason)}")
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp now_ms(opts), do: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end).()

  defp same_state?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(String.trim(left)) == String.downcase(String.trim(right))

  defp same_state?(_left, _right), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
