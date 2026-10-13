defmodule SymphonyElixir.DirectorMoves do
  @moduledoc """
  The Linear moves the Director makes from the Mac app's Inbox, through the control API
  (`POST /api/v1/control/<move>`, decision DD4 in `docs/design/director-app-screens.md`).

  Each move reads the ticket, refuses one the workflow doesn't allow from its current state
  (`{:error, {:conflict, message}}`, a 409), posts its comment when it has one, makes the Linear
  move, writes a `director_move` audit record and answers with the states it moved between:

  - `:approve_plan`: a plan (label `plan` or `breakdown`) in a review state — `In Review`, the
    Human Review state, or a designed repo's `Plan Review` — moves to the waiting state (`Waiting on sub-tickets`). It is a person's move, so Symphony
    promotes the plan's `Backlog` sub-tickets as it does today (`SymphonyElixir.BreakdownReview`);
  - `:approve_pr`: a pull request in a review state moves to `Merging`;
  - `:rework`: a ticket in a review state (a designed repo's `Plan Review` included) gets the reason as a comment, then moves to `Rework`.
    On a designed repo that continues the existing pull request; the full reset is `:restart`;
  - `:restart`: the full reset, and only a person makes it (design doc D7). A designed repo closes
    the ticket's pull requests, removes its workspaces — so the next dispatch branches fresh from
    the configured base branch — and supersedes the workpad, then moves the ticket to `In Progress`
    (`SymphonyElixir.Restart`). A legacy repo is refused: its `Rework` already closes the pull
    request and starts over, so a second full reset would only be ambiguous;
  - `:decisions`: a plan in a review state (a designed repo's `Plan Review` included) gets one
    comment with the picked options. A plan in the Human Review state first moves to `In Review`,
    so the comment, posted after the move, starts Symphony's plan revision run
    (`SymphonyElixir.PlanComments`); a plan in `In Review` or `Plan Review` gets the comment in place;
  - `:sign_off`: a `Final verification:` ticket in a review state moves to `Done`;
  - `:backlog`: an open ticket gets the note as a comment when there is one, then moves to `Backlog`;
  - `:unblock`: a ticket waiting on an **access** hold — an agent's block report — has the hold
    cleared by hand and continues in place, with no state move. A dependency or fix-ticket hold
    clears on its own, so it is refused;
  - `:decide`: a designed repo's ticket waiting on a `Needs Decision` hold gets the Director's
    answer as a reply under the request comment, and the hold is cleared so the ticket continues in
    its phase. The optional `:move` names a state the decision directs — `rework` or `done` — and
    the move goes through `SymphonyElixir.TransitionGuard`. A ticket with no such hold that a
    request parked in the Human Review state gets the reply too, then moves to `Todo` (or the
    directed state). Any other ticket with no hold is refused.

  The comments are the Director's: none starts like one of Symphony's own, so the plan revision
  trigger counts them as a person's comment.

  When Linear takes the first of a move's two writes and refuses the second, the move answers
  `{:error, {:partial, message}}` saying what was already done, and still writes the audit record of
  what changed (with `failed` naming the write that didn't happen). Decisions moved to `In Review`
  without their comment keep their undo; a rework or backlog comment posted without its move is
  remembered, so sending the move again makes the move without posting the comment twice.

  `undo/2` takes back the last move on a ticket within 10 s of it, and only while
  the ticket is still in the state the move put it in, and, for an approved plan, before Symphony
  promoted its sub-tickets. Undoing `:approve_pr` turns GitHub auto-merge off first, and refuses a
  pull request that already merged. The last move per ticket is kept in this
  module's Agent, so a restart forgets it.
  """

  use Agent

  require Logger

  alias SymphonyElixir.{
    AuditLog,
    BreakdownReview,
    Config,
    Hold,
    HumanReview,
    MergeConfirmation,
    Orchestrator,
    Restart,
    RunKind,
    StateMachine,
    SubIssueWait,
    TicketSignals,
    Tracker,
    TransitionGuard
  }

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrReviewPoller

  @undo_window_ms 10_000
  @review_state "In Review"
  @in_progress_state "In Progress"
  @merging_state "Merging"
  @rework_state "Rework"
  @done_state "Done"
  @backlog_state "Backlog"
  @todo_state "Todo"
  @comment_preview_chars 500

  @type move ::
          :approve_plan
          | :approve_pr
          | :rework
          | :restart
          | :decisions
          | :sign_off
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
          | {:github, String.t()}
          | {:restart, String.t()}
          | {:store, String.t()}
          | :issue_not_found
          | {:linear, term()}
          | {:partial, String.t()}
  @type result :: {:ok, map()} | {:error, error()}

  @moves [:approve_plan, :approve_pr, :rework, :restart, :decisions, :sign_off, :backlog, :unblock, :decide]
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

  # Unblock is not a Linear move: it lifts an access hold in place, so no state is resolved.
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

  Undoing `:approve_pr` reads the pull request first: a merged one can't be taken back (a 409), and
  GitHub auto-merge on it (which Symphony turns on for a `Merging` ticket) is turned off before the
  ticket moves back, so the PR doesn't merge anyway. When GitHub can't be read or refuses, the ticket stays in
  `Merging` and the undo answers `{:error, {:github, message}}`. Option `:github` replaces
  `SymphonyElixir.GitHub.PullRequest`.
  """
  @spec undo(String.t(), keyword()) :: result()
  def undo(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, issue} <- fetch_issue(identifier),
         {:ok, last} <- undoable(issue, opts),
         :ok <- release_pr(last.move, issue, opts),
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

  @doc "The comment `:unblock` posts: the access hold is cleared and the ticket continues in place."
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
      {:ok, %Issue{} = issue} -> {:ok, issue}
      {:error, :issue_not_found} -> {:error, :issue_not_found}
      {:error, reason} -> if not_found?(reason), do: {:error, :issue_not_found}, else: {:error, {:linear, reason}}
    end
  end

  # Linear answers an unknown identifier with an "Entity not found" GraphQL error.
  defp not_found?({:linear_graphql_errors, errors}), do: Enum.any?(List.wrap(errors), &(is_map(&1) and is_binary(&1["message"]) and &1["message"] =~ ~r/not found/i))
  defp not_found?(_reason), do: false

  # The state a move takes the ticket to (nil when it stays), or why the workflow doesn't allow it.
  defp target(:approve_plan, issue, settings) do
    with :ok <- require_kind(issue, :plan, "approve_plan"),
         :ok <- require_review(issue, settings) do
      case SubIssueWait.enabled?(settings) && SubIssueWait.state(settings) do
        state when is_binary(state) -> {:ok, state}
        _off -> conflict("the waiting state is turned off, so a plan can't be approved from the app")
      end
    end
  end

  defp target(:approve_pr, issue, settings) do
    with :ok <- require_kind(issue, :pr, "approve_pr"),
         :ok <- require_review(issue, settings),
         do: {:ok, @merging_state}
  end

  defp target(:rework, issue, settings) do
    with :ok <- require_review(issue, settings), do: {:ok, @rework_state}
  end

  # The full reset (design doc D7) is a designed-repo move: a legacy repo's `Rework` is already
  # the full reset, so offering a second one there would only be ambiguous.
  defp target(:restart, %Issue{state: state} = issue, settings) do
    cond do
      not StateMachine.designed?(settings) ->
        conflict("#{issue.identifier} is on the legacy state machine, where Rework already closes the pull request and starts over")

      Enum.any?(settings.tracker.terminal_states, &same_state?(&1, state)) ->
        conflict("#{issue.identifier} is #{state}; only an open ticket can be restarted")

      true ->
        {:ok, @in_progress_state}
    end
  end

  defp target(:decisions, issue, settings) do
    with :ok <- require_kind(issue, :plan, "decisions"),
         :ok <- require_review(issue, settings) do
      {:ok, if(HumanReview.in_state?(issue, settings), do: @review_state)}
    end
  end

  defp target(:sign_off, issue, settings) do
    with :ok <- require_kind(issue, :final_verification, "sign_off"),
         :ok <- require_review(issue, settings),
         do: {:ok, @done_state}
  end

  defp target(:backlog, %Issue{state: state} = issue, settings) do
    cond do
      same_state?(state, @backlog_state) -> conflict("#{issue.identifier} is already in Backlog")
      Enum.any?(settings.tracker.terminal_states, &same_state?(&1, state)) -> conflict("#{issue.identifier} is #{state}; only an open ticket moves to Backlog")
      true -> {:ok, @backlog_state}
    end
  end

  defp require_kind(issue, kind, move) do
    case kind(issue) do
      ^kind -> :ok
      other -> conflict("#{issue.identifier} is #{kind_phrase(other)}; #{move} is for #{kind_phrase(kind)}")
    end
  end

  defp kind(issue) do
    cond do
      RunKind.classify(issue) == :final_verification -> :final_verification
      Issue.breakdown?(issue) -> :plan
      true -> :pr
    end
  end

  defp kind_phrase(:plan), do: "a plan"
  defp kind_phrase(:pr), do: "a pull request"
  defp kind_phrase(:final_verification), do: "a final verification"

  # The Director answers a ticket a person is reviewing: `In Review` or the human review state, and
  # a designed repo's `Plan Review`, where a plan parent waits for its plan's review.
  defp require_review(%Issue{state: state} = issue, settings) do
    if HumanReview.review_state?(state, settings) or HumanReview.plan_review_state?(state, settings) do
      :ok
    else
      conflict("#{issue.identifier} is #{state || "in no state"}; the Director answers it only from #{Enum.join(answerable_states(settings), " or ")}")
    end
  end

  defp answerable_states(settings), do: Enum.uniq(HumanReview.review_states(settings) ++ HumanReview.plan_review_states(settings))

  defp conflict(message), do: {:error, {:conflict, message}}

  # The comment goes before the move, so the run the move starts reads it; the decisions comment
  # goes after the move to In Review, so the plan revision trigger counts it.
  defp apply_move(:rework, issue, to_state, %{reason: reason}, opts),
    do: comment_then_move(:rework, issue, rework_comment(String.trim(reason)), to_state, opts)

  # The reset runs before the comment and the move, so a failure stops the move: the Inbox shows
  # what GitHub or Linear refused, and the ticket stays where it is until the person tries again.
  defp apply_move(:restart, issue, to_state, input, opts) do
    case Restart.perform(issue, restart_opts(opts)) do
      :ok -> comment_then_move(:restart, issue, restart_comment(issue.identifier, String.trim(input[:reason])), to_state, opts)
      {:error, {:restart, message}} -> {:error, {:restart, "#{issue.identifier} was not restarted: #{message}"}}
    end
  end

  defp apply_move(:backlog, issue, to_state, input, opts) do
    if present?(input[:note]),
      do: comment_then_move(:backlog, issue, backlog_comment(String.trim(input.note)), to_state, opts),
      else: comment_then_move(:backlog, issue, nil, to_state, opts)
  end

  defp apply_move(:decisions, issue, to_state, %{picks: picks}, opts) do
    comment = picks |> Enum.map(&%{question: String.trim(&1.question), answer: String.trim(&1.answer)}) |> decisions_comment()

    with :ok <- maybe_update_state(issue, to_state, :decisions) do
      case post_comment(issue, comment) do
        :ok -> {:ok, comment}
        {:error, {:linear, reason}} when is_binary(to_state) -> moved_without_comment(issue, to_state, reason, opts)
        error -> error
      end
    end
  end

  defp apply_move(move, issue, to_state, _input, opts), do: comment_then_move(move, issue, nil, to_state, opts)

  # Unblock lifts an access hold in place: the store hold is cleared through `Hold` (the store
  # first, then the `Blocked` label), so the ticket keeps its phase and the next poll dispatches it
  # again. A hold waiting on anything else clears on its own, so it is refused.
  defp unblock(%Issue{} = issue, opts) do
    if issue |> access_hold(opts) |> Hold.access_wait?(),
      do: clear_access_hold(issue, opts),
      else: access_conflict(issue)
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
  # so an answer that picks that option moves the ticket exactly as it would with manual review off,
  # and one that picks nothing moves nothing; an explicit `:move` (the Inbox's Send to Rework)
  # directs its own move instead.
  defp decide(%Issue{} = issue, input, opts) do
    case carried_move(issue, input.picks, opts) do
      {:ok, carried} ->
        comment = input.picks |> Enum.map(&%{question: String.trim(&1.question), answer: String.trim(&1.answer)}) |> decide_comment()

        case reply_to_request(issue, input.request_comment_id, comment) do
          :ok -> clear_decision_hold(issue, input, comment, carried, opts)
          {:error, reason} -> {:error, {:linear, reason}}
        end

      :parked ->
        comment = input.picks |> Enum.map(&%{question: String.trim(&1.question), answer: String.trim(&1.answer)}) |> decide_comment()

        case reply_to_request(issue, input.request_comment_id, comment) do
          :ok -> decision_finish(issue, input[:move] || @todo_state, comment, opts)
          {:error, reason} -> {:error, {:linear, reason}}
        end

      :error ->
        conflict("#{issue.identifier} is not waiting on a decision")
    end
  end

  # The move the answers pick from the ticket's open Needs Decision hold, if any. A ticket with no hold has a
  # request to answer only when the request parked it in the Human Review state (a legacy repo, or
  # a request made before the repo moved to the designed machine): `:parked`, and answering it
  # moves the ticket to `Todo`, as the request's review brief says, so the next run carries it out.
  defp carried_move(%Issue{repo_key: repo_key, id: issue_id} = issue, picks, opts) do
    case Hold.get(repo_key, issue_id, :needs_decision, store_opts(opts)) do
      nil -> if HumanReview.in_state?(issue, Config.settings!()), do: :parked, else: :error
      hold -> {:ok, picked_move(hold, picks)}
    end
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

  defp clear_decision_hold(issue, input, comment, carried, opts) do
    case Hold.clear(issue.repo_key, issue.id, :needs_decision, store_opts(opts)) do
      :ok -> decision_finish(issue, input[:move] || carried, comment, opts)
      {:error, reason} -> {:error, {:store, "couldn't clear the hold on #{issue.identifier}: #{inspect(reason)}"}}
    end
  end

  defp decision_finish(issue, move, comment, opts) when is_binary(move) and move != "" do
    to_state = @decide_targets[String.downcase(String.trim(move))]

    case update_state(issue, to_state, :decide) do
      :ok -> finish(:decide, issue, to_state, comment, opts)
      {:error, {:linear, reason}} -> decision_move_refused(issue, to_state, reason, comment, opts)
    end
  end

  # With nothing to move, the ticket continues in its phase: the decision is recorded and the hold
  # is gone, so the next poll dispatches it again.
  defp decision_finish(issue, _move, comment, opts) do
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

  # Decisions moved the plan to In Review, then Linear refused their comment: the move stays, with
  # its audit record and its undo, and sending the decisions again posts the comment.
  defp moved_without_comment(issue, to_state, reason, opts) do
    record_audit("decisions", issue, issue.state, to_state, nil, %{failed: "comment"})
    remember_move(:decisions, issue, to_state, opts)
    request_refresh(opts)

    partial("moved #{issue.identifier} to #{to_state}, but Linear refused the decisions comment (#{inspect(reason)}); send the decisions again")
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

  defp maybe_update_state(_issue, nil, _move), do: :ok
  defp maybe_update_state(issue, to_state, move), do: update_state(issue, to_state, move)

  # The Blocked hold in the store — the truth, whatever the board shows. Only a designed repo ever
  # records one, so a legacy ticket always has none here.
  defp access_hold(%Issue{repo_key: repo_key, id: issue_id}, opts), do: Hold.get(repo_key, issue_id, :blocked, store_opts(opts))

  defp store_opts(opts), do: Keyword.take(opts, [:store])

  # Restart moves through its own signal, whose target the designed edge table owns (`In Progress`),
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

  # An approval's auto-merge would still merge the PR once its checks pass, after the ticket moved back.
  defp release_pr(:approve_pr, %Issue{pr_urls: [pr_url | _]} = issue, opts) when is_binary(pr_url) do
    github = Keyword.get(opts, :github, PullRequest)

    case github.fetch_activity(pr_url, []) do
      {:ok, activity} ->
        cond do
          String.upcase(to_string(activity[:state])) == "MERGED" ->
            conflict("#{issue.identifier} already merged; move it in Linear instead")

          activity[:auto_merge_enabled] == true ->
            turn_off_auto_merge(issue, pr_url, activity[:pr_node_id], github, opts)

          true ->
            :ok
        end

      {:error, reason} ->
        github_error("couldn't read #{pr_url} (#{inspect(reason)}); #{issue.identifier} stays in Merging")
    end
  end

  defp release_pr(_move, _issue, _opts), do: :ok

  defp turn_off_auto_merge(issue, pr_url, node_id, github, opts) do
    case disable_auto_merge(github, pr_url, node_id) do
      :ok ->
        Logger.info("Director undo turned GitHub auto-merge off issue_id=#{issue.id} issue_identifier=#{issue.identifier} pr_url=#{pr_url}")
        # Should Linear refuse the move back, the ticket stays in Merging: the next poll turns auto-merge on again.
        PrReviewPoller.forget_auto_merge(issue.id, poller_opts(issue, opts))

      {:error, reason} ->
        github_error("GitHub refused to turn auto-merge off on #{pr_url} (#{inspect(reason)}); #{issue.identifier} stays in Merging")
    end
  end

  defp disable_auto_merge(github, pr_url, node_id) when is_binary(node_id), do: github.disable_auto_merge(pr_url, node_id, [])
  defp disable_auto_merge(_github, _pr_url, _node_id), do: {:error, :missing_pr_node_id}

  defp poller_opts(%Issue{repo_key: repo_key}, opts) when is_binary(repo_key) and repo_key != "",
    do: [repo_key: repo_key] ++ Keyword.take(opts, [:run_store])

  defp poller_opts(_issue, opts), do: Keyword.take(opts, [:run_store])

  defp github_error(message), do: {:error, {:github, message}}

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

  # The orchestrator polls again at once, so the Inbox and the dashboard follow the move.
  defp request_refresh(opts) do
    opts |> Keyword.get(:orchestrator, Orchestrator) |> Orchestrator.request_refresh()
    :ok
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp now_ms(opts), do: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end).()

  defp same_state?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(String.trim(left)) == String.downcase(String.trim(right))

  defp same_state?(_left, _right), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
