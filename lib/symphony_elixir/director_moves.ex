defmodule SymphonyElixir.DirectorMoves do
  @moduledoc """
  The Linear moves the Director makes from the Mac app's Inbox, through the control API
  (`POST /api/v1/control/<move>`, decision DD4 in `docs/design/director-app-screens.md`).

  Each move reads the ticket, refuses one the workflow doesn't allow from its current state
  (`{:error, {:conflict, message}}`, a 409), posts its comment when it has one, makes the Linear
  move, writes a `director_move` audit record and a `person.action` event on the ticket (a Decide's
  event is its `decision.recorded`), and answers with the states it moved between:

  - `:approve_plan`: a plan (label `plan` or `breakdown`) in `Plan Review` moves to the waiting
    state (`Waiting on sub-tickets`). It is a person's move, so Symphony promotes the plan's
    `Backlog` sub-tickets (`SymphonyElixir.BreakdownReview`);
  - `:rework`: a plan in `Plan Review` gets the reason as a comment, then moves to `Rework`, which
    rejects the plan: Symphony cancels its sub-tickets still in `Backlog` and plans again
    (`SymphonyElixir.BreakdownReview`); the full reset is `:restart`;
  - `:restart`: the full reset, and only a person makes it (design doc D7). It closes the ticket's
    pull requests, removes its workspaces — so the next dispatch branches fresh from the configured
    base branch — and supersedes the workpad, then moves the ticket to `In Progress`
    (`SymphonyElixir.Restart`). A dispatch-loop or quiet-handoff hold is cleared with it, since the
    attempt it held is the one thrown away, with the question Symphony asked beside it answered
    "Start it over from main" (`SymphonyElixir.DispatchLoop`), and so is an operator's stop, its
    pause reason with its hold (`SymphonyElixir.OperatorStop`);
  - `:decisions`: a plan in `Plan Review` gets the Director's answers to its questions, in place:
    each pick naming its `request_comment_id` is replied under that request and written into the
    Decisions section (`SymphonyElixir.Decisions`), and the Needs Decision hold the requests set is
    cleared; a pick without one goes into one comment with the picked options. The move itself then
    starts Symphony's plan revision, on every round: a plan under review moves to `Rework` through the
    `:plan_revise` transition, recorded as Symphony's own move, so the revision run keeps the plan's
    sub-tickets (`SymphonyElixir.PlanComments` sends a comment written in Linear the same way).
    Nothing is approved: the plan comes back to `Plan Review`. An approved plan stays where it is;
  - `:changes`: a plan in `Plan Review` gets the Director's reason as a comment, which starts the same
    revision the same way: the plan is changed and keeps its sub-tickets. `:rework` is the
    rejection that cancels them. Neither `:decisions` nor `:changes` is taken back by `undo/2`;
  - `:backlog`: an open ticket gets the note as a comment when there is one, then moves to `Backlog`;
  - `:unblock`: a ticket waiting on an **access** hold — an agent's block report, whose question is
    answered "Unblock and run again" (`SymphonyElixir.TransitionGuard.block_report_question/1`) — on a
    dispatch-loop or quiet-handoff hold (`SymphonyElixir.DispatchLoop`: the question Symphony asked
    beside it is answered "Run it again", then the hold is cleared) or on an operator's stop
    (`SymphonyElixir.OperatorStop`: its pause reason, then its hold) has the hold cleared by hand
    and continues in place, with no state move. So does one waiting on its competing pull requests (a landing
    hold, `SymphonyElixir.PrWatch.Competitors`): the blocked-by links Symphony added go, and it no
    longer waits on those pull requests. A dependency or fix-ticket hold clears on its own, so it is
    refused;
  - `:decide`: a ticket waiting on a `Needs Decision` hold gets the Director's answer as a reply
    under the request comment, written into the Decisions section of the description
    (`SymphonyElixir.Decisions`), and the hold is cleared so the ticket continues in its phase. The
    optional `:move` names a state the decision directs — `rework` or `done` — and the move goes
    through `SymphonyElixir.TransitionGuard`. A ticket with no such hold is refused.

  `answer_held_question/4` answers the question Symphony asked beside a dispatch-loop or
  quiet-handoff hold, and does what the picked option asks: Unblock, Restart, or nothing.

  The comments are the Director's: none starts like one of Symphony's own, so the plan comment
  poll counts them as a person's comment too.

  Every move's target becomes the phase of the ticket's record
  (`SymphonyElixir.TicketSignals.record_phase/3`) before Linear's state move, so the record never
  lags the Director's move. A move that posts its comment with the move (`:rework`, `:restart`,
  `:backlog`) writes the record before that comment, and `:restart` after its reset; `:decide`
  writes it after its reply, and `:decisions` and `:changes` after their comments.

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
    CiWait,
    Config,
    Decisions,
    DispatchLoop,
    Hold,
    MergeConfirmation,
    OperatorStop,
    Orchestrator,
    PathUnlock,
    PlanComments,
    PlanReview,
    PrWatch,
    Questions,
    Restart,
    RunStore,
    SelfHeal,
    SubIssueWait,
    TicketSignals,
    Tracker,
    TransitionGuard
  }

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Routing.Resolver

  @undo_window_ms 10_000
  # The moves that start a plan's revision. They are not taken back: the app holds them for its own
  # Undo before sending, and moving the plan back to review would leave the answers unapplied.
  @revision_moves [:decisions, :changes]
  @in_progress_state "In Progress"
  @merging_state "Merging"
  @rework_state "Rework"
  @done_state "Done"
  @backlog_state "Backlog"
  @todo_state "Todo"
  @comment_preview_chars 500
  @director {:person, "the Director"}

  @type move ::
          :approve_plan
          | :rework
          | :restart
          | :decisions
          | :changes
          | :backlog
          | :unblock
          | :decide
  @type pick :: %{
          required(:question) => String.t(),
          required(:answer) => String.t(),
          optional(:request_comment_id) => String.t() | nil
        }
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

  @moves [:approve_plan, :rework, :restart, :decisions, :changes, :backlog, :unblock, :decide]
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
         {:ok, comment} <- apply_move(move, issue, to_state, input, opts),
         {:ok, to_state} <- start_revision(move, issue, to_state, comment, settings, opts) do
      finish(move, issue, to_state, comment, opts)
    end
  end

  @doc """
  Answers the question `question_id` asked beside the Blocked hold of the ticket `identifier` (a
  dispatch loop's or a quiet handoff's, `SymphonyElixir.DispatchLoop.question_attrs/2`, or a run's
  block report's, `SymphonyElixir.TransitionGuard.block_report_question/1`) with `answer`, as the
  Director, then does what the answer's option asks (`SymphonyElixir.DispatchLoop.answer_move/1`):
  "Run it again" and "Unblock and run again" are `:unblock`, "Start it over from main" is
  `:restart`, its comment naming the question, and "Keep it paused" or an answer in the Director's
  own words leaves the ticket where it is, held. Takes the options of `move/4`.
  """
  @spec answer_held_question(String.t(), String.t(), String.t(), keyword()) :: result()
  def answer_held_question(identifier, question_id, answer, opts) when is_binary(identifier) and is_binary(question_id) do
    with {:ok, issue} <- fetch_issue(identifier),
         {:ok, question} <- answer_question(issue, question_id, answer) do
      case held_answer_move(question) do
        :unblock -> unblock(issue, opts)
        :restart -> do_move(:restart, issue, %{reason: "You answered \"#{DispatchLoop.option_label(:restart)}\" to: #{question.title}"}, opts)
        :keep -> finish(:decide, issue, nil, nil, opts)
      end
    end
  end

  defp held_answer_move(question) do
    if picked_label(question) == TransitionGuard.unblock_option(),
      do: :unblock,
      else: DispatchLoop.answer_move(question)
  end

  defp picked_label(%{state: :answered, answer: %{option: number}, options: options}) when is_integer(number) do
    with %{label: label} <- Enum.at(options, number - 1), do: label
  end

  defp picked_label(_question), do: nil

  defp answer_question(issue, question_id, answer) do
    case Questions.answer({:ticket, issue.repo_key, issue.id}, question_id, answer, by: OperatorStop.director()) do
      {:ok, question} -> {:ok, question}
      {:error, :question_not_found} -> conflict("#{issue.identifier} has no question #{question_id}")
      {:error, {:question_not_open, state}} -> conflict("#{issue.identifier}'s question #{question_id} is #{state}, not open")
      {:error, reason} -> {:error, {:store, "couldn't answer the question on #{issue.identifier}: #{inspect(reason)}"}}
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
      request_refresh(issue, opts)

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

  @doc "The comment `:changes` posts with the Director's reason: a person's comment on the plan, which revises it."
  @spec changes_comment(String.t()) :: String.t()
  def changes_comment(reason) when is_binary(reason), do: "Changes asked by the Director:\n\n#{reason}"

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

  defp validate_input(:changes, input) do
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

  # The comment goes first, in place; `start_revision/6` then moves a plan under review to its revision.
  defp target(move, issue, settings) when move in [:decisions, :changes] do
    with :ok <- require_plan(issue, Atom.to_string(move)),
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

  # Each answer to one of the plan's requests goes under it, as a Decide's does, and the rest in one
  # comment. The replies and the comment are the Director's, so the plan's revision run starts from
  # them; the answers are in the Decisions section before it reads the ticket.
  defp apply_move(:decisions, issue, nil, %{picks: picks}, opts) do
    picks = Enum.map(picks, &%{question: String.trim(&1.question), answer: String.trim(&1.answer), request_comment_id: Map.get(&1, :request_comment_id)})
    {answers, loose} = Enum.split_with(picks, &present?(&1.request_comment_id))

    with {:ok, replies} <- reply_to_requests(issue, answers),
         {:ok, comment} <- post_loose_picks(issue, loose) do
      record_answers(issue, answers)
      clear_answered_hold(issue, answers, opts)
      {:ok, Enum.join(replies ++ List.wrap(comment), "\n\n")}
    end
  end

  defp apply_move(:changes, issue, nil, %{reason: reason}, _opts) do
    comment = changes_comment(String.trim(reason))
    with :ok <- post_comment(issue, comment), do: {:ok, comment}
  end

  defp apply_move(move, issue, to_state, _input, opts), do: comment_then_move(move, issue, nil, to_state, opts)

  # The answers or the changes are posted, so the move itself starts the plan's revision rather than
  # wait for the comment poll to notice its own comments: the parent goes to `Rework`, as
  # `PlanComments` sends it there for a comment written in Linear. The move is recorded as
  # Symphony's own before it is made, so `BreakdownReview` never reads it as the Director's
  # rejection, which would cancel the plan's sub-tickets. An approved plan is not revised from
  # comments, so it stays in place.
  defp start_revision(move, issue, nil, comment, settings, opts) when move in @revision_moves do
    if PlanComments.action(issue, settings.tracker.terminal_states, settings) == :revise,
      do: revise(move, issue, comment, opts),
      else: {:ok, nil}
  end

  defp start_revision(_move, _issue, to_state, _comment, _settings, _opts), do: {:ok, to_state}

  defp revise(move, issue, comment, opts) do
    store = Keyword.get(opts, :store, RunStore)
    _ = log_own_move_error(store.put_own_state_move(issue.id, DateTime.utc_now()), issue)
    ctx = %{repo_key: issue.repo_key, issue_identifier: issue.identifier}
    to_state = TransitionGuard.target(:plan_revise, ctx)

    case TransitionGuard.perform(issue.id, :plan_revise, ctx) do
      :ok ->
        TicketSignals.record(issue.repo_key, issue.id, "plan verdict", %{outcome: "changes", to: to_state})
        record_move_signal(issue, move, to_state)
        Logger.info("Director move #{move} starts the plan's revision issue_id=#{issue.id} issue_identifier=#{issue.identifier} to=#{to_state}")
        {:ok, to_state}

      {:error, reason} ->
        record_audit(Atom.to_string(move), issue, issue.state, issue.state, comment, %{failed: "revise"})
        request_refresh(issue, opts)

        partial(
          "posted #{sent(move)} on #{issue.identifier}, but Linear refused the move to #{to_state} that starts the plan's revision " <>
            "(#{inspect(reason)}); #{issue.identifier} stays in #{issue.state} with them not yet applied, so don't approve it yet"
        )
    end
  end

  defp sent(:decisions), do: "your answers"
  defp sent(:changes), do: "your changes"

  defp log_own_move_error(:ok, _issue), do: :ok

  defp log_own_move_error({:error, reason}, issue),
    do: Logger.warning("Failed to record Symphony's own move of #{issue.identifier} to revise its plan: #{inspect(reason)}")

  defp reply_to_requests(issue, answers) do
    Enum.reduce_while(answers, {:ok, []}, fn answer, {:ok, replies} ->
      reply = decide_comment([answer])

      case reply_to_request(issue, answer.request_comment_id, reply) do
        :ok -> {:cont, {:ok, replies ++ [reply]}}
        {:error, reason} -> {:halt, {:error, {:linear, reason}}}
      end
    end)
  end

  defp post_loose_picks(_issue, []), do: {:ok, nil}

  defp post_loose_picks(issue, picks) do
    comment = decisions_comment(picks)
    with :ok <- post_comment(issue, comment), do: {:ok, comment}
  end

  # Best-effort, as a Decide's: the answers are under the requests, and the Inbox's next read writes
  # them from there when this write fails (`SymphonyElixir.Decisions.sync/2`).
  defp record_answers(_issue, []), do: :ok

  defp record_answers(issue, answers) do
    entries = for answer <- answers, do: Decisions.entry(answer.request_comment_id, Date.utc_today(), answer.question, answer.question, answer.answer)
    _ = Decisions.record(issue.id, entries, repo_key: issue.repo_key)
    :ok
  end

  # The requests are answered, so the hold they set clears with no withdrawal, and the revision run
  # the replies start is dispatched. A clear the store refuses is reported; the Inbox's next read
  # clears it once it sees the answers.
  defp clear_answered_hold(_issue, [], _opts), do: :ok

  defp clear_answered_hold(issue, answers, opts) do
    case Hold.clear(issue.repo_key, issue.id, :needs_decision, answered_opts(answers, opts)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to clear the Needs Decision hold on #{issue.identifier} after its plan's answers: #{inspect(reason)}")
    end
  end

  # The attempt a dispatch loop or a quiet handoff held is the one Restart throws away, so its hold
  # goes with it, its question answered "Start it over from main", and the ticket starts again with
  # its count at zero; an operator's stop (its pause reason and its hold) is lifted by the Restart
  # that starts the ticket over. A clear the store refuses is reported; the restart stands, and
  # Unblock still lifts it.
  defp clear_restarted_hold(issue, opts) do
    hold = blocked_hold(issue, opts)

    with {:error, reason} <- clear_restarted(issue, hold, opts) do
      Logger.warning("Restarted #{issue.identifier} but couldn't clear its #{restarted_hold_name(hold)} hold: #{inspect(reason)}")
    end
  end

  defp clear_restarted(issue, hold, opts) do
    with :ok <- if(stopped?(issue, hold), do: clear_stop(issue, opts), else: :ok) do
      if Hold.dispatch_loop?(hold) or asked?(hold), do: clear_blocked(issue, :restart, opts), else: :ok
    end
  end

  defp restarted_hold_name(hold) do
    cond do
      Hold.dispatch_loop?(hold) -> "dispatch-loop"
      asked?(hold) -> "quiet-handoff"
      true -> "operator-stop"
    end
  end

  # A Blocked hold set beside a question Symphony asked (`SymphonyElixir.DispatchLoop`). A block
  # report's access hold names its question too, but a restart leaves it, as it always has.
  defp asked?(%{waits_on: %{type: "access"}}), do: false
  defp asked?(hold), do: is_binary(get_in(hold || %{}, [:waits_on, :question_id]))

  # The Blocked hold cleared by `move`, the question set beside it answered with the option `move` is.
  defp clear_blocked(issue, move, opts) do
    question = {:answer, option_label(issue, move, opts), OperatorStop.director()}
    Hold.clear(issue.repo_key, issue.id, :blocked, [question: question] ++ store_opts(opts))
  end

  # Unblock answers a block report's question with its own option, "Unblock and run again"
  # (`TransitionGuard.block_report_question/1`); any other with the dispatch loop's.
  defp option_label(issue, :unblock, opts) do
    with %{waits_on: %{question_id: id}} <- blocked_hold(issue, opts),
         %{options: options} <- Questions.find({:ticket, issue.repo_key, issue.id}, id),
         true <- Enum.any?(options, &(&1.label == TransitionGuard.unblock_option())) do
      TransitionGuard.unblock_option()
    else
      _other -> DispatchLoop.option_label(:unblock)
    end
  end

  defp option_label(_issue, move, _opts), do: DispatchLoop.option_label(move)

  defp stopped?(issue, hold), do: OperatorStop.hold?(hold) or OperatorStop.held?(issue.repo_key, issue.id)

  defp clear_stop(issue, opts), do: OperatorStop.clear_hold(issue.repo_key, issue.id, [by: OperatorStop.director()] ++ store_opts(opts))

  # Unblock lifts an access or dispatch-loop hold in place: the store hold is cleared through `Hold`
  # (the store first, then the `Blocked` label), so the ticket keeps its phase and the next poll
  # dispatches it again — for a loop, with its count started again. A landing hold first has the PR
  # watcher release its competitors, so the next read doesn't wait on them again. An operator's stop
  # is lifted with it: its pause reason first, then its hold, which may be missing when another
  # Blocked hold was there already (that one stays when it clears on its own). A hold waiting on
  # anything else clears on its own, so it is refused.
  defp unblock(%Issue{} = issue, opts) do
    hold = blocked_hold(issue, opts)
    stopped? = stopped?(issue, hold)

    cond do
      Hold.unblockable?(hold) ->
        clear_access_hold(issue, stopped?, opts)

      BlockedHold.landing?(hold) ->
        release_competitors(issue, opts)
        clear_access_hold(issue, stopped?, opts)

      stopped? ->
        lift(issue, fn -> clear_stop(issue, opts) end, opts)

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

  defp clear_access_hold(issue, stopped?, opts), do: lift(issue, fn -> clear_stop_and_hold(issue, stopped?, opts) end, opts)

  # Once the hold is gone, so are the environment reasons a CI wait or self-heal's access hold set
  # beside it (`SymphonyElixir.CiWait`, `SymphonyElixir.SelfHeal`), released by the Director. Those
  # clears are best-effort, as the writers' own are.
  defp clear_stop_and_hold(issue, stopped?, opts) do
    with :ok <- if(stopped?, do: clear_stop(issue, opts), else: :ok),
         :ok <- clear_blocked(issue, :unblock, opts) do
      CiWait.clear_pause(issue.repo_key, issue.id, OperatorStop.director())
      SelfHeal.healthy(issue.repo_key, issue.id, OperatorStop.director())
    end
  end

  defp lift(issue, clear, opts) do
    comment = unblock_comment(issue.identifier)

    case clear.() do
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
          clear_decision_hold(issue, to_state, comment, picks, opts)

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
  # writes it from there when this write fails (`SymphonyElixir.Decisions.sync/2`). A pick of an
  # option that unlocks protected paths records them, read from the hold's decision
  # (`SymphonyElixir.PathUnlock.picked_paths/2`).
  defp record_decision(issue, request_comment_id, hold, picks) do
    decision = Map.get(hold, :decision) || %{}
    title = Map.get(decision, :title)
    question = Map.get(decision, :question) || Enum.map_join(picks, " / ", & &1.question)
    answers = Enum.map(picks, & &1.answer)
    unlocks = PathUnlock.picked_paths(decision, answers)
    entry = Decisions.entry(request_comment_id, Date.utc_today(), title, question, Enum.join(answers, " / "), unlocks)
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

  # The decision is answered, so its clear records no withdrawal: the answer's `decision.recorded`
  # ends the request, and the Question the hold projects is answered.
  defp clear_decision_hold(issue, to_state, comment, picks, opts) do
    case Hold.clear(issue.repo_key, issue.id, :needs_decision, answered_opts(picks, opts)) do
      :ok -> decision_finish(issue, to_state, comment, opts)
      {:error, reason} -> {:error, {:store, "couldn't clear the hold on #{issue.identifier}: #{inspect(reason)}"}}
    end
  end

  # An answered clear: the Question the hold projects is answered with the Director's words
  # (`Hold.clear/4`), so its pause ends with the hold.
  defp answered_opts(answers, opts) do
    text = Enum.map_join(answers, " / ", & &1.answer)
    [answered: true, question: {:answer, text, %{kind: :person, name: "Director"}}] ++ store_opts(opts)
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
    request_refresh(issue, opts)

    partial(
      "recorded the decision on #{issue.identifier} and cleared the hold, but Linear refused the move to " <>
        "#{to_state} (#{inspect(reason)}); #{issue.identifier} continues in place"
    )
  end

  # The record takes the move before Linear's first write, the comment: Linear is its projection, so
  # a write Linear refuses leaves the record moved, is logged and is marked for the reconciler.
  defp comment_then_move(move, issue, comment, to_state, opts) do
    :ok = TicketSignals.record_phase(issue.repo_key, issue.id, to_state)

    case maybe_post_comment(issue, comment, opts) do
      :ok -> move_after_comment(move, issue, comment, to_state, opts)
      error -> projection_refused(issue, to_state, error)
    end
  end

  defp move_after_comment(move, issue, comment, to_state, opts) do
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

  defp projection_refused(issue, to_state, {:error, {:linear, reason}} = error) do
    Logger.warning(
      "Linear refused the Director move's comment; the record keeps the move issue_id=#{issue.id} " <>
        "issue_identifier=#{issue.identifier} to=#{to_state} reason=#{inspect(reason)}"
    )

    :ok = TicketSignals.mark_projection(issue.repo_key, issue.id, :phase, reason)
    error
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
    case TransitionGuard.perform(issue.id, :restart, %{repo_key: issue.repo_key, issue_identifier: issue.identifier, settings: Config.settings!()}) do
      :ok ->
        record_move_signal(issue, :restart, to_state)
        :ok

      {:error, reason} ->
        {:error, {:linear, reason}}
    end
  end

  defp update_state(issue, to_state, move) do
    case TransitionGuard.perform(issue.id, :director_move, %{target: to_state, repo_key: issue.repo_key, issue_identifier: issue.identifier}) do
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

    if to_state && move not in @revision_moves, do: remember_move(move, issue, to_state, opts)
    request_refresh(issue, opts)

    {:ok,
     %{
       move: name,
       issue_id: issue.id,
       issue_identifier: issue.identifier,
       from_state: issue.state,
       to_state: to_state || issue.state,
       moved: to_state != nil,
       commented: comment != nil,
       undo_window_ms: if(to_state && move not in [:restart | @revision_moves], do: @undo_window_ms)
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

    record_person_action(move, issue, from_state, to_state)
  end

  # Each move the audit records is also the Director's action on the ticket's events, best effort.
  # A Decide records none: its answer is the `decision.recorded` that `SymphonyElixir.Decisions`
  # writes. The control API authenticates one shared token, so the actor is the Director.
  defp record_person_action("decide", _issue, _from_state, _to_state), do: :ok

  defp record_person_action(move, %Issue{repo_key: repo_key, id: issue_id}, from_state, to_state) when is_binary(repo_key) do
    payload = if move in ["unblock", "restart"], do: %{action: move}, else: %{action: "move", move: move}
    TicketSignals.record_event(repo_key, issue_id, "person.action", Map.merge(payload, %{from: from_state, to: to_state}), actor: @director)
  end

  defp record_person_action(_move, _issue, _from_state, _to_state), do: :ok

  # The orchestrator polls the ticket's repo at once, so the Inbox and the dashboard follow the move
  # and what it unblocks (an approved plan's first sub-ticket) dispatches on the next cycle. The
  # request is a cast: an orchestrator busy with a poll never holds up the move's answer.
  defp request_refresh(%Issue{repo_key: repo_key}, opts) do
    Orchestrator.request_refresh(Keyword.get(opts, :orchestrator, Orchestrator), repo_key, due: :now)
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp now_ms(opts), do: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end).()

  defp same_state?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(String.trim(left)) == String.downcase(String.trim(right))

  defp same_state?(_left, _right), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
