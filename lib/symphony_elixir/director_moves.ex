defmodule SymphonyElixir.DirectorMoves do
  @moduledoc """
  The Linear moves the Director makes from the Mac app's Inbox, through the control API
  (`POST /api/v1/control/<move>`, decision DD4 in `docs/design/director-app-screens.md`).

  Each move reads the ticket, refuses one the workflow doesn't allow from its current state
  (`{:error, {:conflict, message}}`, a 409, with the reason `SymphonyElixir.TicketMoves` gives the
  ticket read's `moves`), posts its comment when it has one, makes the Linear
  move, writes a `director_move` audit record and a `person.action` event on the ticket (a Decide's
  event is its `decision.recorded`), and answers with the states it moved between:

  - `:approve_plan`: a plan (label `plan` or `breakdown`) in `Plan Review` moves to the waiting
    state (`Waiting on sub-tickets`). It is a person's move, so Symphony promotes the plan's
    `Backlog` sub-tickets (`SymphonyElixir.BreakdownReview`);
  - `:rework`: a plan in `Plan Review` gets the reason as a comment, then moves to `Rework`, which
    rejects the plan: Symphony cancels its sub-tickets still in `Backlog` and plans again
    (`SymphonyElixir.BreakdownReview`); the full reset is `:restart`;
  - `:restart`: the full reset, and only a person makes it (design doc D7). A run the ticket has
    is ended first, as `/control/stop` ends it (`SymphonyElixir.Orchestrator.stop_running/2`: the
    `stop` removal reason, so no pull request is closed by the stop), and the reset waits for its
    agent to exit before it touches the workspace. It closes the ticket's
    pull requests, removes its workspaces — so the next dispatch branches fresh from the configured
    base branch — and supersedes the workpad, then moves the ticket to `In Progress`
    (`SymphonyElixir.Restart`). The question a dispatch loop or a quiet handoff paused the ticket on
    is answered "Start it over from main" (`SymphonyElixir.DispatchLoop`), since the attempt it held
    is the one thrown away, and an operator's stop is released (`SymphonyElixir.Pauses.stop/2`).
    Every other open question nobody needs any more is withdrawn with the reason
    (`SymphonyElixir.Questions.withdraw_lapsed/3`). Its `director_move` audit record and its
    `person.action` event say whether a run was ended (`run_stopped`). A reset that fails after
    the run was ended leaves the ticket stopped, as Stop does, until Restart or Unblock;
  - `:decisions`: a plan in `Plan Review` gets the Director's answers to its questions, in place:
    each pick naming its Question (`question_id`, or the `request_comment_id` whose Inbox row names
    it) answers that Question first (`SymphonyElixir.Questions.answer/4`); each pick naming its
    `request_comment_id` is replied under that request and written into the
    Decisions section (`SymphonyElixir.Decisions`); a pick without one goes into one comment with the picked options. The move itself then
    starts Symphony's plan revision, on every round: a plan under review moves to `Rework` through the
    `:plan_revise` transition, recorded as Symphony's own move, so the revision run keeps the plan's
    sub-tickets (`SymphonyElixir.PlanComments` sends a comment written in Linear the same way).
    Nothing is approved: the plan comes back to `Plan Review`. An approved plan stays where it is;
  - `:changes`: a plan in `Plan Review` gets the Director's reason as a comment, which starts the same
    revision the same way: the plan is changed and keeps its sub-tickets. `:rework` is the
    rejection that cancels them. Neither `:decisions` nor `:changes` is taken back by `undo/2`;
  - `:backlog`: an open ticket gets the note as a comment when there is one, then moves to `Backlog`;
    the questions its run asked are withdrawn with the reason (`SymphonyElixir.Questions.withdraw_lapsed/3`);
  - `:cancel`: an open ticket is dropped for good, a person's decision (principle 6) that a hand
    move to Canceled can't make on a phase Symphony owns, since that is drift moved back. The
    record's phase becomes the team's canceled state first, then Linear follows, through the guard
    (`SymphonyElixir.DecisionMove.perform/4`, which tries `Canceled`, then `Cancelled`). A running
    turn is stopped as `/control/stop` stops it, without the stop's pause; the ticket's open
    pull request is closed with the Director's note as its comment; every open question is withdrawn
    (`SymphonyElixir.Questions.withdraw_lapsed/3`, "The ticket was cancelled."), and every pause
    reason is cleared. The ticket's events get one `ticket.cancelled` with the note, the stop
    and the pull requests closed; its workspace goes on the usual cleanup of a terminal ticket. A
    record cancelled this way is terminal: a later Linear state is no drift on it
    (`SymphonyElixir.TicketObservation`). Undo puts the record and Linear back to the phase before;
    the pull request it closed, the run it stopped and the questions it withdrew stay as they are;
  - `:unblock`: a ticket whose pause has a reason the Director may release (an operator's stop, a
    wait for CI, a broken environment, a block nobody named) or a question Unblock answers
    (`SymphonyElixir.Questions.held/1`: an agent's block report, answered "Unblock and run again",
    `SymphonyElixir.TransitionGuard.block_report_question/1`; a dispatch loop or a quiet handoff,
    answered "Run it again", `SymphonyElixir.DispatchLoop`) has the question answered and those
    reasons released, and continues in place, with no state move. So does one waiting on its
    competing pull requests (`SymphonyElixir.PrWatch.Competitors`): the blocked-by links Symphony
    added go, and it no longer waits on those pull requests. So does a QA ticket held because its
    app's QA build could not run (`SymphonyElixir.QaBuildHold`): that build is asked for again first.
    A ticket an idle run parked in Backlog
    (`SymphonyElixir.IdlePark`) goes back to the phase it was parked from first, with its workspace
    and branch as they are, then its question is answered "Run it again", and it is dispatched at
    once. A wait on a blocker or a fix ticket lifts on its own and stays; a ticket with nothing to
    release is refused;
  - `:decide`: a ticket waiting on a decision request's Question (`SymphonyElixir.Questions.deciding/1`,
    or the open one `question_id` names) has the Director's answer written to that Question first
    (`SymphonyElixir.Questions.answer/4`: `question_id`, the Inbox row's, else the Question the row
    of `request_comment_id` names, else the one it waits on), before any Linear request: the ticket
    is read from its record, so a Decide answers with Linear down. The answer ends the Question's
    pause reason, so the ticket continues in its phase. Then come its projections: a reply under the
    request comment and the answer in the Decisions section of the description
    (`SymphonyElixir.Decisions`). A reply
    Linear refuses is marked pending on the record, and the reconciler posts it and records the
    section once Linear answers (`project_answer/5`). The optional `:move` names a state the
    decision directs — `rework` or `done` — and the move goes through
    `SymphonyElixir.TransitionGuard`. Without one, a pick of an option that carries its own move
    (`SymphonyElixir.DecisionMove`, QA's "Merge without a QA result") makes that move. A ticket
    with no such Question whose pause waits on the Question `question_id` that Unblock answers
    (`SymphonyElixir.Questions.held/1`: a dispatch loop's, a quiet handoff's, a park's, a block
    report's) is answered with the first pick, as `answer_held_question/4` says; any other is
    refused. A pick's `:option` is the option it picked when its `:answer` is the person's own
    words given with it: the option decides what the answer does, the words are its text. A
    Decide naming a Question already answered is a no-op that says so: `already_decided: true`
    with the recorded `answer` and `option`, never a second outcome (a replayed request, a second
    tap).

  - `:move`: the free move. A ticket in a configured repository (one that routes to a repo key)
    goes to `:to`, whoever set its phase. A ticket Symphony has no record of yet (a Backlog ticket
    whose webhook delivery was missed: the poll reads active states only) is read from Linear by id
    first and observed (`SymphonyElixir.TicketObservation.observe/3`, `source: :by_id`), so its
    record exists before the move; a read that fails or doesn't return it refuses the move and
    writes nothing (`:tracker`, default `SymphonyElixir.Tracker`, is the module read). It goes to `:to`, any phase the repo's workflow names
    (`phases/1`), keeping its workspace, branch and pull request: nothing is reset. The record's
    phase is written first, then Linear (`SymphonyElixir.TransitionGuard`), so the phase is
    Symphony's from then on (`phase_owner: :symphony`) and Linear never moves it back; a move Linear
    refuses stands on the record for the reconciler to project, as a Cancel's does. A dispatch
    loop's, a quiet handoff's or a park's pause lifts with it (a person moving the ticket answers
    "it looks stuck": its question is answered "Run it again"); every other pause reason stays. A
    move into `Backlog` or a closed phase stops a running turn as Stop does, without the stop's
    pause. The refresh `finish/6` asks for starts a phase that dispatches at once. The ticket's
    events get one `ticket.moved` with the note. A move to the phase the ticket is in answers
    `moved: false` and writes nothing; one to a phase the repo doesn't name, or of a ticket in no
    configured repository, is refused. Undo puts the record and Linear back to the phase before.

  `answer_held_question/4` answers the question a dispatch loop, a quiet handoff or a block report
  paused the ticket on, and does what the picked option asks: Unblock, Restart, or nothing.

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
  promoted its sub-tickets. A Decide that answered a Question is taken back whether or not it moved
  the ticket: its Question is reopened (`SymphonyElixir.Questions.reopen/3`), pausing the ticket on
  it again. The last move per ticket is kept in this module's Agent, so a restart
  forgets it.
  """

  use Agent

  require Logger

  alias SymphonyElixir.{
    AuditLog,
    BreakdownReview,
    Config,
    DecisionMove,
    Decisions,
    DispatchLoop,
    Handoff,
    IdlePark,
    MergeConfirmation,
    Orchestrator,
    PathUnlock,
    Pauses,
    PlanComments,
    PrWatch,
    QaBuildHold,
    Questions,
    ReleaseBuild,
    Restart,
    RunStore,
    StateMachine,
    SubIssueWait,
    TicketMoves,
    TicketObservation,
    TicketPullRequest,
    TicketSignals,
    TicketState,
    Tracker,
    TransitionGuard
  }

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.PrWatch.Competitors
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
  @canceled_state "Canceled"
  @comment_preview_chars 500
  @director {:person, "the Director"}

  @type move ::
          :approve_plan
          | :rework
          | :restart
          | :decisions
          | :changes
          | :backlog
          | :cancel
          | :unblock
          | :decide
          | :move
  @type pick :: %{
          required(:question) => String.t(),
          required(:answer) => String.t(),
          optional(:option) => String.t() | nil,
          optional(:question_id) => String.t() | nil,
          optional(:request_comment_id) => String.t() | nil
        }
  @type input :: %{
          optional(:reason) => String.t() | nil,
          optional(:note) => String.t() | nil,
          optional(:picks) => [pick()],
          optional(:question_id) => String.t() | nil,
          optional(:request_comment_id) => String.t() | nil,
          optional(:move) => String.t() | nil,
          optional(:to) => String.t() | nil
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

  @moves [:approve_plan, :rework, :restart, :decisions, :changes, :backlog, :cancel, :unblock, :decide, :move]
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
  `:reason` (required), the backlog, cancel or move `:note` (optional), the move's `:to` (required), the decisions' `:picks` (required) or the
  decision's `:picks` (required) with the `:request_comment_id` they answer (required) and the
  optional `:move` the decision directs.

  Options: `:server` (the Agent, default this module), `:clock` (monotonic milliseconds, for the undo
  window), `:orchestrator` (asked to poll again after the move, and to stop a cancelled ticket's run,
  default `SymphonyElixir.Orchestrator`), `:store` (the run store read and written, default
  `SymphonyElixir.RunStore`), `:github` (the pull request module a restart or a cancel closes
  with, default `SymphonyElixir.GitHub.PullRequest`), and Unblock's `:release_competitors` (the PR
  watcher's release of a wait on competing pull requests) and `:release` (the release of the
  ticket's question and the reasons the Director may release).
  """
  @spec move(move(), String.t(), input(), keyword()) :: result()
  def move(move, identifier, input, opts \\ []) when move in @moves and is_binary(identifier) and is_map(input) do
    with :ok <- validate_input(move, input),
         {:ok, issue} <- move_issue(move, identifier) do
      do_move(move, issue, input, opts)
    end
  end

  # A Decide answers the ticket's Question before any Linear request, so it reads the ticket from its
  # record (`SymphonyElixir.TicketState`); a ticket the record doesn't hold is read from Linear.
  defp move_issue(:decide, identifier) do
    case recorded_issue(identifier) do
      %Issue{} = issue -> {:ok, issue}
      nil -> fetch_issue(identifier)
    end
  end

  defp move_issue(_move, identifier), do: fetch_issue(identifier)

  defp recorded_issue(identifier) do
    Enum.find_value(Config.system!().repos, fn repo ->
      with records when is_list(records) <- RunStore.list_ticket_states(repo.name),
           %{} = record <- records |> Enum.map(&TicketState.normalize/1) |> Enum.find(&recorded?(&1, identifier)) do
        %Issue{id: record.issue_id, identifier: record.issue_identifier || record.issue_id, repo_key: repo.name, state: record.phase}
      else
        _none -> nil
      end
    end)
  end

  defp recorded?(record, identifier), do: is_binary(record.issue_id) and identifier in [record.issue_id, record.issue_identifier]

  # Unblock is not a Linear move: it lifts a hold in place, so no state is resolved.
  defp do_move(:unblock, issue, _input, opts), do: unblock(issue, opts, false)

  # Decide is a decision, not a state: it answers the request and clears the hold, and only moves
  # when the decision directs one.
  defp do_move(:decide, issue, input, opts), do: decide(issue, input, opts)

  # Cancel moves through the team's canceled state under either spelling, so its target is the one
  # Linear took.
  defp do_move(:cancel, issue, input, opts), do: cancel(issue, blank_to_nil(input[:note]), opts)

  # Restart ends the ticket's live run first, as Stop does, so the reset never pulls the workspace
  # from under it and the next dispatch starts a fresh run; whether one was ended goes on the
  # move's records.
  defp do_move(:restart, issue, input, opts) do
    with {:ok, to_state} <- target(:restart, issue, Config.settings!()),
         run_stopped? = stop_restarted_run(issue, opts),
         {:ok, comment} <- apply_move(:restart, issue, to_state, Map.put(input, :run_stopped, run_stopped?), opts) do
      finish(:restart, issue, to_state, comment, opts, %{}, %{run_stopped: run_stopped?})
    end
  end

  # The free move names its own target, any phase of the repo.
  defp do_move(:move, issue, input, opts), do: free_move(issue, String.trim(input.to), blank_to_nil(input[:note]), opts)

  defp do_move(move, issue, input, opts) do
    settings = Config.settings!()

    with {:ok, to_state} <- target(move, issue, settings),
         {:ok, comment} <- apply_move(move, issue, to_state, input, opts),
         {:ok, to_state} <- start_revision(move, issue, to_state, comment, settings, opts) do
      finish(move, issue, to_state, comment, opts)
    end
  end

  @doc """
  The Director's Decide on a Question with no ticket: one asked on Symphony itself or on a
  repository (`SymphonyElixir.Questions.open_on_subjects/0`), named by `input`'s `:question_id`.
  The first pick's answer answers it as the Director (`SymphonyElixir.Questions.answer/4`), which
  records `question.answered` on the subject's own stream and lifts its pause reason; then whoever
  asked acts on the answer at once: a release build's question (`step` `release_build:<sha>`) has
  `SymphonyElixir.ReleaseBuild.delivered/2` check that build again, which reruns it when the answer
  says so. No ticket moves and nothing is posted to Linear.

  `opts`: `:release_build` (the module told of a release build's answer, default
  `SymphonyElixir.ReleaseBuild`), `:release_build_opts` (the options it is told with, default
  none) and `:questions` (the Question service the answer is written with, default
  `SymphonyElixir.Questions`). `{:error, :question_not_found}` when no subject has the open Question.
  """
  @spec decide_subject(input(), keyword()) :: {:ok, map()} | {:error, error() | :question_not_found}
  def decide_subject(input, opts \\ []) when is_map(input) do
    with :ok <- validate_input(:decide, input),
         id when is_binary(id) <- blank_to_nil(input[:question_id]) || {:error, {:invalid, "question_id is required"}},
         {:ok, subject, question} <- open_on_subject(id),
         [%{answer: answer} | _picks] = input.picks,
         {:ok, answered} <- answer_subject(subject, question, String.trim(answer), opts) do
      act_on_answer(answered, opts)
      Logger.info("Director move decide subject=#{inspect(subject)} question_id=#{id} option=#{inspect(answered.answer.option)}")
      {:ok, %{move: "decide", subject: subject_name(subject), repo_key: subject_repo_key(subject), question_id: id, option: answered.answer.option, answered: true}}
    end
  end

  defp open_on_subject(id) do
    case Questions.find_open_on_subjects(String.trim(id)) do
      {subject, question} -> {:ok, subject, question}
      nil -> {:error, :question_not_found}
    end
  end

  # Answered by someone else since it was read, or refused by the store: a conflict to read again.
  defp answer_subject(subject, question, answer, opts) do
    case Keyword.get(opts, :questions, Questions).answer(subject, question.id, answer, by: Pauses.director()) do
      {:ok, answered} -> {:ok, answered}
      {:error, reason} -> conflict("Could not answer the question #{question.id}: #{inspect(reason)}")
    end
  end

  defp act_on_answer(%{step: "release_build:" <> sha}, opts),
    do: Keyword.get(opts, :release_build, ReleaseBuild).delivered(sha, Keyword.get(opts, :release_build_opts, []))

  defp act_on_answer(_question, _opts), do: :ok

  defp subject_name(:symphony), do: "symphony"
  defp subject_name({:repository, _repo_key}), do: "repository"

  defp subject_repo_key({:repository, repo_key}), do: repo_key
  defp subject_repo_key(:symphony), do: nil

  @doc """
  Answers the question `question_id` the ticket `identifier` is paused on (a dispatch loop's or a quiet handoff's, `SymphonyElixir.DispatchLoop.question_attrs/2`, or a run's
  block report's, `SymphonyElixir.TransitionGuard.block_report_question/1`) with `answer`, as the
  Director, then does what the answer's option asks (`SymphonyElixir.DispatchLoop.answer_move/1`):
  "Run it again" and "Unblock and run again" are `:unblock`, "Start it over from main" is
  `:restart`, its comment naming the question, and "Keep it paused" or an answer in the Director's
  own words leaves the ticket where it is, held: the answered question no longer pauses it, so a
  reason the Director releases with Unblock does, written with the answer so the ticket is never
  free to dispatch in between ("You kept it paused: …" for the pick, "You answered in your own
  words: …" for words; a loop's goes with a Restart too, as its question would have).
  `opts[:option]` names the option picked when `answer` is the Director's words given with it.
  A question already answered is not answered again: the result says `already_decided: true`
  with the recorded pick. Takes the options of `move/4`.
  """
  @spec answer_held_question(String.t(), String.t(), String.t(), keyword()) :: result()
  def answer_held_question(identifier, question_id, answer, opts) when is_binary(identifier) and is_binary(question_id) do
    with {:ok, issue} <- fetch_issue(identifier), do: answer_and_act(issue, question_id, answer, Keyword.get(opts, :option), opts)
  end

  defp answer_and_act(issue, question_id, answer, option, opts) when is_binary(answer) do
    case answer_question(issue, question_id, answer, option) do
      {:ok, question} -> act_on_held_answer(issue, question, opts)
      {:already_decided, question} -> already_decided(issue, question)
      {:error, _reason} = error -> error
    end
  end

  defp act_on_held_answer(issue, question, opts) do
    case held_answer_move(question) do
      :unblock -> unblock(issue, opts, true)
      :restart -> do_move(:restart, issue, %{reason: "You answered \"#{DispatchLoop.option_label(:restart)}\" to: #{question.title}"}, opts)
      :keep -> finish(:decide, issue, nil, nil, opts)
    end
  end

  # The pause an answer that keeps the ticket held leaves, written with the answer itself
  # (`SymphonyElixir.Questions.answer/4`'s `then_pause`): nil for one that runs it or restarts it.
  defp kept_pause(question) do
    if held_answer_move(question) == :keep, do: kept_reason(question)
  end

  defp kept_reason(question) do
    condition = if loop_question?(question), do: DispatchLoop.hold_type(), else: "block_report"
    %{kind: :environment, waits_on: %{condition: condition}, text: String.slice(kept_text(question), 0, 300), releasable: true}
  end

  # What the Director did, in their words: the option they picked, or that they answered in words.
  defp kept_text(question) do
    case picked_label(question) do
      nil -> "You answered in your own words: #{question.title}"
      label -> if label == DispatchLoop.option_label(:keep), do: "You kept it paused: #{question.title}", else: "You answered \"#{label}\": #{question.title}"
    end
  end

  # A Decide on a Question already answered changes nothing and says what was decided.
  defp already_decided(issue, question) do
    answer = Map.get(question, :answer) || %{}

    {:ok,
     %{
       move: "decide",
       issue_id: issue.id,
       issue_identifier: issue.identifier,
       question_id: question.id,
       already_decided: true,
       answer: Map.get(answer, :text),
       option: picked_label(question),
       moved: false,
       commented: false
     }}
  end

  # A dispatch loop's or a quiet handoff's question, which Restart answers: one with its option.
  defp loop_question?(%{options: options}), do: Enum.any?(options, &(&1.label == DispatchLoop.option_label(:restart)))

  defp held_answer_move(question) do
    if picked_label(question) == TransitionGuard.unblock_option(),
      do: :unblock,
      else: DispatchLoop.answer_move(question)
  end

  defp picked_label(%{state: :answered, answer: %{option: number}, options: options}) when is_integer(number) do
    with %{label: label} <- Enum.at(options, number - 1), do: label
  end

  defp picked_label(_question), do: nil

  defp answer_question(issue, question_id, answer, option) do
    ticket = ticket(issue)

    case Questions.answer(ticket, question_id, answer, by: Pauses.director(), option: option, then_pause: &kept_pause/1) do
      {:ok, question} -> {:ok, question}
      {:error, :question_not_found} -> conflict("#{issue.identifier} has no question #{question_id}")
      {:error, {:question_not_open, :answered}} -> {:already_decided, Questions.find(ticket, question_id)}
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
         :ok <- undo_state(issue, last),
         :ok <- reopen(issue, last) do
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

  # A Decide that moved nothing takes no state back.
  defp undo_state(issue, %{from_state: from_state, to_state: to_state}) do
    if same_state?(from_state, to_state), do: :ok, else: update_state(issue, from_state, :undo)
  end

  # A Decide's answer is taken back with it: the Question is open again, pausing the ticket on it,
  # and its label follows (`SymphonyElixir.Pauses.Projector`). The reply and the
  # Decisions entry stay, as the comment a move posted does, but the answer no longer counts: the
  # Question keeps it as taken back, so the PR watcher's read drops its entry
  # (`SymphonyElixir.Questions.answers/2`). The Inbox lists the Question open again.
  defp reopen(issue, %{question_id: id}) do
    with {:ok, _question} <- reopened(Questions.reopen({:ticket, issue.repo_key, issue.id}, id, by: Pauses.director()), issue), do: :ok
  end

  defp reopen(_issue, _last), do: :ok

  defp reopened({:ok, question}, _issue), do: {:ok, question}
  defp reopened({:error, reason}, issue), do: {:error, {:store, "couldn't reopen the question on #{issue.identifier}: #{inspect(reason)}"}}

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

  @doc "The comment `:cancel` posts on the pull request it closes: the cancel, then the Director's note."
  @spec cancel_pr_comment(String.t(), String.t() | nil) :: String.t()
  def cancel_pr_comment(identifier, nil) when is_binary(identifier), do: "Closed: the Director cancelled #{identifier}."
  def cancel_pr_comment(identifier, note) when is_binary(identifier) and is_binary(note), do: cancel_pr_comment(identifier, nil) <> "\n\n" <> note

  @doc "The comment `:unblock` posts: the hold is cleared and the ticket continues in place."
  @spec unblock_comment(String.t()) :: String.t()
  def unblock_comment(identifier) when is_binary(identifier),
    do: "Unblocked by the Director: #{identifier} continues in place."

  @doc "The reply `:decide` posts under the request: each question with the option the Director picked."
  @spec decide_comment([pick()]) :: String.t()
  def decide_comment(picks) when is_list(picks), do: Request.render_decision(picks)

  defp validate_input(:rework, input) do
    if present?(input[:reason]), do: :ok, else: {:error, {:invalid, "reason is required"}}
  end

  defp validate_input(:changes, input) do
    if present?(input[:reason]), do: :ok, else: {:error, {:invalid, "reason is required"}}
  end

  defp validate_input(:restart, input) do
    if present?(input[:reason]), do: :ok, else: {:error, {:invalid, "reason is required"}}
  end

  defp validate_input(:move, input) do
    if present?(input[:to]), do: :ok, else: {:error, {:invalid, "to is required"}}
  end

  defp validate_input(:decisions, %{picks: [_ | _] = picks}) do
    if Enum.all?(picks, &valid_pick?/1), do: :ok, else: invalid_picks()
  end

  defp validate_input(:decisions, _input), do: invalid_picks()

  defp validate_input(:decide, input) do
    cond do
      not (is_list(input[:picks]) and input[:picks] != [] and Enum.all?(input.picks, &valid_pick?/1)) -> invalid_picks()
      not (present?(input[:question_id]) or present?(input[:request_comment_id])) -> {:error, {:invalid, "question_id or request_comment_id is required"}}
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
    with :ok <- guard(:approve_plan, issue), do: {:ok, SubIssueWait.state(settings)}
  end

  defp target(:rework, issue, _settings) do
    with :ok <- guard(:rework, issue), do: {:ok, @rework_state}
  end

  defp target(:restart, issue, _settings) do
    with :ok <- guard(:restart, issue), do: {:ok, @in_progress_state}
  end

  # The comment goes first, in place; `start_revision/6` then moves a plan under review to its revision.
  defp target(move, issue, _settings) when move in [:decisions, :changes] do
    with :ok <- guard(move, issue), do: {:ok, nil}
  end

  defp target(:backlog, issue, _settings) do
    with :ok <- guard(:backlog, issue), do: {:ok, @backlog_state}
  end

  # The one guard (`SymphonyElixir.TicketMoves`), which the ticket read's `moves` also answers from.
  defp guard(move, issue) do
    case TicketMoves.check(move, TicketMoves.issue_facts(issue)) do
      :ok -> :ok
      {:error, reason} -> conflict(reason)
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
        clear_restarted_hold(issue)
        withdraw_lapsed(issue, :restart, opts)
        comment_then_move(:restart, issue, restart_comment(issue.identifier, String.trim(input[:reason])), to_state, opts)

      {:error, {:restart, message}} ->
        {:error, {:restart, "#{issue.identifier} was not restarted: #{message}" <> stopped_note(input[:run_stopped])}}
    end
  end

  # The move stops the ticket's run, so the questions it asked are withdrawn once the move is made.
  defp apply_move(:backlog, issue, to_state, input, opts) do
    comment = if present?(input[:note]), do: backlog_comment(String.trim(input.note))

    with {:ok, _comment} = moved <- comment_then_move(:backlog, issue, comment, to_state, opts) do
      withdraw_lapsed(issue, :backlog, opts)
      moved
    end
  end

  # Each answer to one of the plan's requests goes under it, as a Decide's does, and the rest in one
  # comment. The replies and the comment are the Director's, so the plan's revision run starts from
  # them; the answers are in the Decisions section before it reads the ticket.
  defp apply_move(:decisions, issue, nil, %{picks: picks}, opts) do
    picks = Enum.map(picks, &decision_pick(issue, &1, opts))

    with {:ok, picks} <- answer_questions(issue, picks),
         {answers, loose} = Enum.split_with(picks, &present?(&1.request_comment_id)),
         {:ok, replies, replied} <- reply_to_requests(issue, answers),
         {:ok, comment} <- post_loose_picks(issue, loose) do
      record_answers(issue, replied)
      {:ok, Enum.join(replies ++ List.wrap(comment), "\n\n")}
    end
  end

  defp apply_move(:changes, issue, nil, %{reason: reason}, _opts) do
    comment = changes_comment(String.trim(reason))
    with :ok <- post_comment(issue, comment), do: {:ok, comment}
  end

  defp apply_move(move, issue, to_state, _input, opts), do: comment_then_move(move, issue, nil, to_state, opts)

  defp stopped_note(true), do: "; its run was ended, so it stays stopped until you restart or unblock it"
  defp stopped_note(_stopped), do: ""

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

  # The replies posted and the answers they carry. A reply Linear refuses to an answer whose
  # Question is answered is marked pending, as a Decide's is, and the reconciler posts it and
  # records its Decisions entry once Linear answers (`project_answer/5`); one to a request with no
  # Question (asked before questions) fails the move, as before.
  # While the pause projector owns the replies, an answer whose Question is answered was replied to
  # by its projection, so nothing is posted for it here.
  defp reply_to_requests(issue, answers) do
    Enum.reduce_while(answers, {:ok, [], []}, fn answer, {:ok, replies, replied} ->
      reply = decide_comment([answer])

      case projected_reply(issue, answer, reply) do
        :ok ->
          {:cont, {:ok, replies ++ [reply], replied ++ [answer]}}

        {:error, reason} when is_binary(answer.question_id) ->
          Logger.warning("Answered a question on #{issue.identifier}; Linear refused the reply, posted once Linear answers: #{inspect(reason)}")
          TicketSignals.mark_projection(issue.repo_key, issue.id, {:question_answer, answer.question_id, answer.request_comment_id}, reason)
          {:cont, {:ok, replies, replied}}

        {:error, reason} ->
          {:halt, {:error, {:linear, reason}}}
      end
    end)
  end

  defp projected_reply(issue, answer, reply) do
    if is_binary(answer.question_id) and Projector.owns?(), do: :ok, else: reply_to_request(issue, answer.request_comment_id, reply)
  end

  # A plan's pick names the request it answers (`request_comment_id`) or its Question
  # (`question_id`), and the Inbox row of either names the other.
  defp decision_pick(issue, pick, _opts) do
    question_id = blank_to_nil(Map.get(pick, :question_id))
    comment_id = blank_to_nil(Map.get(pick, :request_comment_id))

    %{
      question: String.trim(pick.question),
      answer: String.trim(pick.answer),
      option: blank_to_nil(Map.get(pick, :option)),
      question_id: question_id || row_question_id(issue, comment_id),
      request_comment_id: comment_id || (question_id && row_comment_id(issue, question_id))
    }
  end

  # Each pick's Question is answered before any reply: the replies and the Decisions section are its
  # projections. A Question already answered (a second send) is left as it is;
  # a pick whose Question the record doesn't hold names none.
  defp answer_questions(issue, picks) do
    Enum.reduce_while(picks, {:ok, []}, fn
      %{question_id: nil} = pick, {:ok, done} ->
        {:cont, {:ok, done ++ [pick]}}

      pick, {:ok, done} ->
        case answer_decision(issue, pick.question_id, pick.answer, false, pick.option) do
          {:ok, nil} -> {:cont, {:ok, done ++ [%{pick | question_id: nil}]}}
          {:ok, _question} -> {:cont, {:ok, done ++ [pick]}}
          {:error, {:conflict, _message}} -> {:cont, {:ok, done ++ [pick]}}
          error -> {:halt, error}
        end
    end)
  end

  defp post_loose_picks(_issue, []), do: {:ok, nil}

  defp post_loose_picks(issue, picks) do
    comment = decisions_comment(picks)
    with :ok <- post_comment(issue, comment), do: {:ok, comment}
  end

  # Best-effort, as a Decide's: the answers are already on the Questions.
  defp record_answers(_issue, []), do: :ok

  defp record_answers(issue, answers) do
    entries = for answer <- answers, do: Decisions.entry(answer.request_comment_id, Date.utc_today(), answer.question, answer.question, answer.answer)
    _ = Decisions.record(issue.id, entries, repo_key: issue.repo_key)
    :ok
  end

  # The questions the move ends are withdrawn with its reason (`Questions.withdraw_lapsed/3`), their
  # requests answered `## Action withdrawn`.
  defp withdraw_lapsed(issue, lapse, opts) do
    {:ok, _withdrawn} = Questions.withdraw_lapsed({:ticket, issue.repo_key, issue.id}, lapse, Keyword.take(opts, [:store, :inbox]))
    :ok
  end

  # The attempt a dispatch loop or a quiet handoff held is the one Restart throws away, so the
  # question it paused the ticket on is answered "Start it over from main" (a reason set when that
  # question could not be asked goes too), and the ticket starts again with its count at zero; an
  # operator's stop is released by the Restart that starts the ticket over. A block report's question
  # has no such option and stays, as it always has. A write the store refuses is reported; the
  # restart stands, and Unblock still lifts it.
  defp clear_restarted_hold(issue) do
    ticket = ticket(issue)

    ticket |> Pauses.release_stop(by: Pauses.director()) |> log_failed("Restarted #{issue.identifier} but couldn't clear its stop")
    ticket |> answer_held(Questions.held(ticket), DispatchLoop.option_label(:restart)) |> log_failed("Restarted #{issue.identifier} but couldn't answer its question")
    ticket |> Pauses.clear_reasons(&loop_reason?/1, by: Pauses.director()) |> log_failed("Restarted #{issue.identifier} but couldn't clear its pause")
  end

  # The reason a dispatch loop, a quiet handoff or a park paused the ticket on when its question could
  # not be asked (`SymphonyElixir.Orchestrator`, `SymphonyElixir.AgentRunner`).
  defp loop_reason?(%{kind: :environment, waits_on: %{condition: condition}}), do: condition in [DispatchLoop.hold_type(), Handoff.missing_signal(), IdlePark.signal_reason()]
  defp loop_reason?(_reason), do: false

  # The held question answered with its option labelled `label`; one without it, or none, is left.
  # The question was read open just before, so a refused answer is the store's failure.
  defp answer_held(ticket, %{id: id, options: options}, label) do
    if Enum.any?(options, &(&1.label == label)),
      do: with({:ok, _question} <- Questions.answer(ticket, id, label, by: Pauses.director()), do: :ok),
      else: :ok
  end

  defp answer_held(_ticket, nil, _label), do: :ok

  defp ticket(issue), do: {:ticket, issue.repo_key, issue.id}

  defp clear_stop(issue), do: Pauses.release_stop(ticket(issue), by: Pauses.director())

  # The record takes the canceled state first and Linear follows (`DecisionMove.perform/4`); a team
  # with neither spelling leaves the record where it was and refuses the move. A move Linear refuses
  # otherwise stands on the record, marked for the reconciler to project, so the rest of the cancel
  # goes on: the run is stopped, the pull request closed, the questions, holds and pauses cleared.
  defp cancel(issue, note, opts) do
    with :ok <- guard(:cancel, issue),
         {:ok, to_state} <- cancel_in_linear(issue) do
      stopped? = stop_run(issue, opts)
      closed = close_cancelled_pull_requests(issue, note, opts)
      clear_cancelled(issue, to_state, opts)

      TicketSignals.record_event(
        issue.repo_key,
        issue.id,
        "ticket.cancelled",
        %{from: issue.state, to: to_state, note: note, run_stopped: stopped?, pull_requests_closed: closed},
        actor: @director
      )

      finish(:cancel, issue, to_state, nil, opts)
    end
  end

  defp cancel_in_linear(issue) do
    case DecisionMove.perform(issue.repo_key, issue.id, %{to: @canceled_state}, issue_identifier: issue.identifier) do
      {:ok, to_state} ->
        record_move_signal(issue, :cancel, to_state)
        {:ok, to_state}

      {:error, :state_not_found} ->
        conflict("#{issue.identifier}'s team has no Canceled state, so it can't be cancelled")

      {:error, reason} ->
        Logger.warning("Cancelled #{issue.identifier} on its record; Linear refused the move, projected again by the reconciler: #{inspect(reason)}")
        {:ok, @canceled_state}
    end
  end

  # The run is stopped as `/control/stop` stops it, and the stop's pause stays until the reset is
  # done: Restart's `clear_restarted_hold/1` releases it, and a failed reset leaves the ticket
  # stopped rather than dispatched onto a half-reset workspace. True when a run was stopped.
  defp stop_restarted_run(issue, opts),
    do: match?({:ok, %{stopped: true}}, Orchestrator.stop_running(Keyword.get(opts, :orchestrator, Orchestrator), issue.id))

  # The run is stopped as `/control/stop` stops it, then the stop's pause and hold are lifted: the
  # ticket is cancelled, not stopped. The hold the stop writes in a task finds no pause when it lands,
  # so the orchestrator clears it again. True when a run was stopped.
  defp stop_run(issue, opts) do
    case Orchestrator.stop_running(Keyword.get(opts, :orchestrator, Orchestrator), issue.id) do
      {:ok, %{stopped: true}} ->
        _ = clear_stop(issue)
        true

      _nothing_stopped ->
        false
    end
  end

  # Each open pull request of the ticket closes with the Director's note as its comment. A pull
  # request GitHub won't read or close is logged: the ticket is cancelled whatever GitHub says, and
  # the PR watcher sees the PR of a terminal ticket. Returns the pull requests closed.
  defp close_cancelled_pull_requests(issue, note, opts) do
    github = Keyword.get(opts, :github, PullRequest)
    comment = cancel_pr_comment(issue.identifier, note)

    for pr_url <- TicketPullRequest.current_urls(issue),
        close_open_pull_request(github, issue, pr_url, comment) == :ok,
        do: pr_url
  end

  defp close_open_pull_request(github, issue, pr_url, comment) do
    with {:ok, activity} <- github.fetch_activity(pr_url, []),
         true <- same_state?(activity[:state], "OPEN"),
         :ok <- github.close(pr_url, comment: comment) do
      Logger.info("Cancel closed pull request issue_id=#{issue.id} issue_identifier=#{issue.identifier} pr_url=#{pr_url}")
      :ok
    else
      false ->
        :not_open

      {:error, reason} ->
        Logger.warning("Cancelled #{issue.identifier} but couldn't close #{pr_url}: #{inspect(reason)}")
        :error
    end
  end

  # Nothing waits on a cancelled ticket: its open questions are withdrawn with the cancel's reason,
  # then every pause reason left is cleared. Best-effort: a clear the store refuses is logged, and
  # the ticket is terminal whatever it still carries.
  defp clear_cancelled(issue, to_state, opts) do
    withdraw_lapsed(issue, {:terminal, to_state}, opts)
    issue |> ticket() |> Pauses.clear_reasons(fn _reason -> true end, by: Pauses.director()) |> log_failed("Cancelled #{issue.identifier} but couldn't clear its pause")
  end

  @doc """
  The phases a free move (`:move`) may put a ticket in, as the workflow `settings` name them: the
  machine's phases in board order (`SymphonyElixir.StateMachine.phases/1`), each once.
  """
  @spec phases(Schema.t()) :: [String.t()]
  def phases(%Schema{} = settings), do: for(%{name: name} <- StateMachine.phases(settings), do: name)

  # The free move: the target is checked, then the record, then the record and Linear move. The
  # phase the ticket leaves is the record's, not the one Linear shows: the two part when Linear
  # refused a move, and the record is the truth for a ticket Symphony tracks. A move to where the
  # record is answers it without writing anything.
  defp free_move(issue, to, note, opts) do
    settings = Config.settings!()

    with {:ok, to_state} <- repo_phase(issue, to, settings),
         {:ok, phase} <- require_tracked(issue, opts) do
      issue = %{issue | state: phase || issue.state}

      if same_state?(issue.state, to_state),
        do: {:ok, unmoved(issue)},
        else: make_free_move(issue, to_state, note, settings, opts)
    end
  end

  defp repo_phase(issue, to, settings) do
    phases = phases(settings)

    case Enum.find(phases, &same_state?(&1, to)) do
      nil -> conflict("#{to} is not a phase of #{issue.identifier}'s workflow; it names #{Enum.join(phases, ", ")}")
      phase -> {:ok, phase}
    end
  end

  # Any ticket of a configured repository moves, whoever set its phase: the move writes the record
  # first, so the phase it sets is Symphony's (`phase_owner: :symphony`) either way. A ticket in no
  # configured repository is refused. A record answers with its phase; a ticket with none yet is
  # read from Linear by id and observed first, so the move acts from a record like any other.
  defp require_tracked(%Issue{repo_key: nil} = issue, _opts),
    do: conflict(TicketMoves.no_repository_reason(issue.identifier))

  defp require_tracked(issue, opts) do
    case Keyword.get(opts, :store, RunStore).get_ticket_state(issue.id) do
      %{} = record -> {:ok, TicketState.normalize(record).phase}
      _none -> observe_untracked(issue, Keyword.get(opts, :tracker, Tracker))
    end
  end

  # The by-id read carries blockers and sub-issues, as the reconciler's does, so the record it
  # writes is the one a webhook delivery would have, and its phase is the state Linear read.
  defp observe_untracked(issue, tracker) do
    with {:ok, read} <- read_by_id(tracker, issue.id),
         {:ok, _outcome} <- TicketObservation.observe(issue.repo_key, read, source: :by_id) do
      Logger.info("Director move recorded an untracked ticket issue_id=#{issue.id} issue_identifier=#{issue.identifier} repo_key=#{issue.repo_key}")
      {:ok, read.state}
    else
      failure -> conflict("Symphony couldn't read #{issue.identifier} from Linear to record it, so it can't move it: #{untracked_reason(failure)}")
    end
  end

  defp read_by_id(tracker, id) do
    case tracker.fetch_issue_states_by_ids([id]) do
      {:ok, issues} -> Enum.find_value(issues, :not_found, &(match?(%Issue{id: ^id}, &1) and {:ok, &1}))
      {:error, reason} -> {:error, reason}
    end
  end

  defp untracked_reason(:not_found), do: "Linear didn't return it"
  defp untracked_reason({:error, reason}), do: inspect(reason)

  defp unmoved(issue) do
    %{
      move: "move",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      from_state: issue.state,
      to_state: issue.state,
      moved: false,
      commented: false,
      undo_window_ms: nil
    }
  end

  defp make_free_move(issue, to_state, note, settings, opts) do
    with :ok <- free_move_in_linear(issue, to_state) do
      release_loop(issue)
      stopped? = stops_run?(to_state, settings) and stop_run(issue, opts)

      TicketSignals.record_event(issue.repo_key, issue.id, "ticket.moved", %{from: issue.state, to: to_state, note: note, run_stopped: stopped?}, actor: @director)

      finish(:move, issue, to_state, nil, opts)
    end
  end

  # The record takes the phase first (`TransitionGuard.perform/4`); a refused Linear write stands on
  # it, marked for the reconciler. A state the team doesn't have leaves the record where it was.
  defp free_move_in_linear(issue, to_state) do
    case update_state(issue, to_state, :move) do
      :ok ->
        :ok

      {:error, {:linear, :state_not_found}} ->
        conflict("#{issue.identifier}'s team has no #{to_state} state, so it can't move there")

      {:error, {:linear, reason}} ->
        Logger.warning("Moved #{issue.identifier} to #{to_state} on its record; Linear refused the move, projected again by the reconciler: #{inspect(reason)}")
        :ok
    end
  end

  # A person moving the ticket is the answer to a dispatch loop's, a quiet handoff's or a park's
  # "it looks stuck": the question is answered "Run it again", which empties the counted runs, and
  # the reason set when it couldn't be asked goes. A block report's question and every other reason
  # stay. Best-effort: the move stands, and Unblock still lifts what is left.
  defp release_loop(issue) do
    ticket = ticket(issue)

    held = Questions.held(ticket)
    ticket |> answer_held(held, loop_unblock_label(held)) |> log_failed("Moved #{issue.identifier} but couldn't answer its question")
    ticket |> Pauses.clear_reasons(&loop_reason?/1, by: Pauses.director()) |> log_failed("Moved #{issue.identifier} but couldn't clear its pause")
  end

  defp stops_run?(to_state, settings), do: same_state?(to_state, @backlog_state) or Enum.any?(settings.tracker.terminal_states, &same_state?(&1, to_state))

  # A best-effort write that failed is reported with what it was for; the move stands.
  defp log_failed({:error, reason}, what), do: Logger.warning("#{what}: #{inspect(reason)}")
  defp log_failed(_written, _what), do: :ok

  # Unblock lifts the ticket in place: the question it is paused on is answered with its Unblock
  # option, then every reason the Director may release is cleared (`SymphonyElixir.Pauses`, which
  # projects the `Blocked` label), so the ticket keeps its phase and the next poll dispatches it
  # again — for a loop, with its count started again. A wait on competing pull requests first has the
  # PR watcher release its competitors, so the next read doesn't wait on them again. A wait on a
  # blocker or a fix ticket lifts on its own and stays. A ticket with nothing to release is refused,
  # unless the Director has just answered its question (`answered?`). A ticket an idle run parked
  # goes back to its phase first (`resume_parked/4`).
  defp unblock(%Issue{} = issue, opts, answered?) do
    case IdlePark.parked_from(issue.state, ticket_signals(issue, opts)) do
      {:ok, from_state} -> resume_parked(issue, from_state, opts)
      :none -> unblock_in_place(issue, opts, answered?)
    end
  end

  defp unblock_in_place(issue, opts, answered?) do
    ticket = ticket(issue)
    reasons = pause_reasons(ticket)
    held = Questions.held(ticket)
    landing? = Enum.any?(reasons, &Competitors.landing_reason?/1)

    if answered? or TicketMoves.unblockable?(reasons, held != nil) do
      if landing?, do: release_competitors(issue, opts)
      retry_qa_builds(issue, reasons, opts)
      release = Keyword.get(opts, :release, &release/2)
      lift(issue, fn -> release.(ticket, held) end, opts)
    else
      guard(:unblock, issue)
    end
  end

  # A block report's question is answered with its own option, "Unblock and run again"
  # (`TransitionGuard.block_report_question/1`); a dispatch loop's or a quiet handoff's with "Run it
  # again", and a spent token budget's with "Give it another budget" (`SymphonyElixir.TokenBudget`).
  defp unblock_label(%{options: options}) do
    labels = Enum.map(options, & &1.label)
    Enum.find([TransitionGuard.unblock_option() | DispatchLoop.unblock_labels()], &(&1 in labels))
  end

  defp unblock_label(nil), do: nil

  # The Unblock option of a loop's, a park's or a spent budget's question, never a block report's.
  defp loop_unblock_label(%{options: options}), do: Enum.find_value(options, &(&1.label in DispatchLoop.unblock_labels() && &1.label))
  defp loop_unblock_label(nil), do: nil

  defp pause_reasons(ticket) do
    case Pauses.get(ticket) do
      {:ok, %{reasons: reasons}} -> reasons
      _none -> []
    end
  end

  # The held question first: its answer is what the Director picked, then the reasons they release.
  defp release(ticket, held) do
    with :ok <- answer_held(ticket, held, unblock_label(held)),
         {:ok, _pause} <- Pauses.clear_reasons(ticket, & &1.releasable, by: Pauses.director()),
         do: :ok
  end

  # A QA ticket held because its app's build could not run has that build asked for again before
  # the hold goes (`SymphonyElixir.QaBuildHold.lifted/4`), so the dispatch it frees finds it asked for.
  defp retry_qa_builds(%Issue{repo_key: repo_key} = issue, reasons, opts) do
    if is_binary(repo_key) and Enum.any?(reasons, &QaBuildHold.unavailable_head/1),
      do: QaBuildHold.lifted(repo_key, issue, reasons, Keyword.take(opts, [:builder]))
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

  # A ticket an idle run parked (`SymphonyElixir.IdlePark`) goes back to the phase it was parked
  # from, its workspace and branch as they are, before its pause lifts, so no dispatch sees it
  # released in Backlog. Lifting it answers its question "Run it again", which empties the record's
  # counted runs; the refresh `finish/6` asks for dispatches it at once.
  defp resume_parked(issue, from_state, opts) do
    ticket = ticket(issue)
    held = Questions.held(ticket)
    release = Keyword.get(opts, :release, &release/2)

    with :ok <- update_state(issue, from_state, :unblock) do
      lift(issue, fn -> release.(ticket, held) end, resume_comment(issue.identifier, from_state), from_state, opts)
    end
  end

  defp resume_comment(identifier, from_state),
    do: "Unblocked by the Director: #{identifier} goes back to #{from_state} with its workspace and branch as they are."

  defp ticket_signals(issue, opts) do
    case Keyword.get(opts, :store, RunStore).get_ticket_state(issue.id) do
      %{} = record -> TicketState.signals(record)
      _none -> []
    end
  end

  defp lift(issue, clear, opts), do: lift(issue, clear, unblock_comment(issue.identifier), nil, opts)

  defp lift(issue, clear, comment, to_state, opts) do
    case clear.() do
      :ok ->
        TicketSignals.record(issue.repo_key, issue.id, "unblocked", %{by: "the Director"})
        post_unblock_comment(issue, comment, to_state, opts)

      {:error, reason} ->
        {:error, {:store, "couldn't lift the pause on #{issue.identifier}: #{inspect(reason)}"}}
    end
  end

  # The hold is already cleared, so a comment Linear refuses is reported and does not undo it.
  defp post_unblock_comment(issue, comment, to_state, opts) do
    case post_comment(issue, comment) do
      :ok ->
        :ok

      {:error, {:linear, reason}} ->
        Logger.warning("Unblocked #{issue.identifier} but Linear refused the comment: #{inspect(reason)}")
        :ok
    end

    finish(:unblock, issue, to_state, comment, opts)
  end

  # Decide answers a decision request's Question, which ends its pause reason, so the ticket
  # continues at once; the reply under the request comment and the Decisions entry are its
  # projections. The move the decision directs — when it directs one — goes through the guard.
  #
  # A merge confirmation's Question carries the move confirming performs (`SymphonyElixir.MergeConfirmation`),
  # as a Code Review escalation's carries its QA state, so an answer that picks that option moves
  # the ticket exactly as it would with manual review off, and one that picks nothing moves nothing.
  # Any other decision moves the ticket when the picked option carries a move
  # (`SymphonyElixir.DecisionMove`); an explicit `:move` (the Inbox's Send to Rework) directs its
  # own move instead.
  defp decide(%Issue{} = issue, input, opts) do
    case deciding(issue, input) do
      {:held, question} -> decide_held_question(issue, question, input, opts)
      {:already_decided, question} -> already_decided(issue, question)
      %{} = question -> answer(issue, input, question, decide_target(input[:move], picked_move(question, input.picks)), opts)
      {:error, _reason} = error -> error
    end
  end

  # The Question the Director answers: the one `question_id` names, open, whatever asked it and
  # whether or not anything pauses the ticket on it (one Unblock answers, `Questions.held/1`, does
  # what its option asks); else the newest decision request the ticket waits on
  # (`Questions.deciding/1`). An unknown or closed Question is refused, naming which.
  defp deciding(issue, input) do
    ticket = ticket(issue)

    case blank_to_nil(input[:question_id]) do
      nil -> Questions.deciding(ticket) || guard(:answer, issue)
      id -> named_question(issue, ticket, String.trim(id))
    end
  end

  defp named_question(issue, ticket, id) do
    case Questions.find(ticket, id) do
      nil -> conflict("#{issue.identifier} has no question #{id}")
      %{state: :open} = question -> if Questions.held_question?(question), do: {:held, question}, else: question
      %{state: :answered} = question -> {:already_decided, question}
      %{state: state} -> conflict("#{issue.identifier}'s question #{id} is #{state}, not open")
    end
  end

  # The Inbox answers a question Unblock answers (a dispatch loop's, a quiet handoff's, a park's, a
  # block report's) with Decide, as it answers any question: its first pick is the answer, and the
  # option it picked does what `answer_held_question/4` says.
  defp decide_held_question(issue, question, %{picks: [%{answer: answer} = pick | _picks]}, opts),
    do: answer_and_act(issue, question.id, String.trim(answer), blank_to_nil(Map.get(pick, :option)), opts)

  # The move a decision makes: the Director's explicit move, else the one the Question or the picked
  # option carries (a merge confirmation's `Merging`, a Code Review escalation's QA state, QA's
  # merge without a result). nil when the decision moves nothing.
  defp decide_target(nil, carried), do: carried
  defp decide_target(move, _carried), do: %{to: Map.fetch!(@decide_targets, String.downcase(String.trim(move)))}

  # The target is resolved before anything is written: a decision directing a move into a state the
  # repo has not configured is refused while the Question is still open, rather than answered and
  # the move left to fail with the ticket in place.
  #
  # The answer is the Question's first (`SymphonyElixir.Questions.answer/4`), before any Linear
  # request; the reply, the Decisions section and the move are its projections. A reply Linear
  # refuses is marked pending on the record, and the reconciler posts it and records the section
  # once Linear answers (`project_answer/5`).
  defp answer(issue, input, deciding, directed, opts) do
    if match?(%{to: to} when is_binary(to), directed) and String.trim(directed.to) == "" do
      {:error, {:invalid, "#{issue.identifier}'s decision moves it to a state not configured for repo #{issue.repo_key}; the question stays open"}}
    else
      picks = Enum.map(input.picks, &%{question: String.trim(&1.question), answer: String.trim(&1.answer), option: blank_to_nil(Map.get(&1, :option))})

      with {:ok, question} <- answer_deciding(issue, input, deciding, picks) do
        project_decision(linear_issue(issue), input, question, recorded_option(picks, question), directed, opts)
      end
    end
  end

  # While the pause projector owns the replies, the answered Question's reply is its projection,
  # posted when the answer committed (`SymphonyElixir.Pauses.Projector`): nothing is posted here.
  defp project_decision(issue, input, question, picks, directed, opts) do
    if Projector.owns?(),
      do: projected_decision(issue, input, question, picks, directed, opts),
      else: reply_decision(issue, input, question, picks, directed, opts)
  end

  defp projected_decision(issue, input, question, picks, directed, opts) do
    record_decision(issue, request_comment_id(issue, input, question) || question.id, question, picks)
    decision_move(issue, directed, decide_comment(picks), %{question_id: question.id}, opts)
  end

  defp reply_decision(issue, input, question, picks, directed, opts) do
    comment = decide_comment(picks)
    comment_id = request_comment_id(issue, input, question)

    case reply(issue, comment_id, comment) do
      :ok ->
        record_decision(issue, comment_id || question.id, question, picks)
        decision_move(issue, directed, comment, %{question_id: question.id}, opts)

      {:error, reason} ->
        Logger.warning("Answered #{issue.identifier}'s question; Linear refused the reply, posted once Linear answers: #{inspect(reason)}")
        TicketSignals.mark_projection(issue.repo_key, issue.id, {:question_answer, question.id, comment_id}, reason)
        decision_move(issue, directed, nil, %{question_id: question.id}, opts)
    end
  end

  # Linear's read of the ticket, for its state, when Linear answers; the record's otherwise.
  defp linear_issue(issue) do
    case fetch_issue(issue.identifier) do
      {:ok, %Issue{id: id} = fetched} when id == issue.id -> %{fetched | repo_key: issue.repo_key}
      _unread -> issue
    end
  end

  # The Question the request asks, answered with the Director's picks: the one the Inbox row names
  # (`question_id`), else the one the row of the request comment names, else the one the ticket
  # waits on. A Question the record doesn't hold is refused, never answered as nothing.
  defp answer_deciding(issue, input, deciding, picks) do
    id = blank_to_nil(input[:question_id]) || row_question_id(issue, input[:request_comment_id]) || deciding.id
    answer_decision(issue, id, Enum.map_join(picks, " / ", & &1.answer), true, picked_option(input.picks))
  end

  # The reply names the option the answered Question recorded (its label, whether the pick named it
  # by label or number); several picks keep what each named.
  defp recorded_option([pick], question), do: [%{pick | option: Questions.option_label(question) || pick.option}]
  defp recorded_option(picks, _question), do: picks

  # The option one pick names beside its own words; nil for several picks or none named.
  defp picked_option(picks), do: if(match?([_pick], picks), do: blank_to_nil(Map.get(hd(picks), :option)))

  defp answer_decision(issue, id, text, given?, option) do
    case Questions.answer({:ticket, issue.repo_key, issue.id}, id, text, by: Pauses.director(), option: option) do
      {:ok, question} -> {:ok, question}
      {:error, :question_not_found} when given? -> conflict("#{issue.identifier} has no question #{id}")
      {:error, :question_not_found} -> {:ok, nil}
      {:error, {:question_not_open, state}} -> conflict("#{issue.identifier}'s question #{id} is #{state}, not open")
      {:error, reason} -> {:error, {:store, "couldn't answer the question on #{issue.identifier}: #{inspect(reason)}"}}
    end
  end

  # The request comment the reply goes under: the one the Director answered, else the one the Inbox
  # row of the Question lists. nil when neither is known: the reply is then a comment on the ticket.
  defp request_comment_id(issue, input, question) do
    blank_to_nil(input[:request_comment_id]) || row_comment_id(issue, question.id)
  end

  defp reply(issue, nil, comment), do: with({:error, {:linear, reason}} <- post_comment(issue, comment), do: {:error, reason})
  defp reply(issue, comment_id, comment), do: reply_to_request(issue, comment_id, comment)

  # The ticket's request comments, each with the Question it asks, as its record keeps them (the pause
  # projector wrote or found each one): what the Inbox row of the Question names. No Linear read.
  defp row_question_id(_issue, nil), do: nil
  defp row_question_id(issue, comment_id), do: issue |> rows() |> Enum.find_value(&(&1.comment_id == comment_id && &1.question_id))

  defp row_comment_id(issue, question_id), do: issue |> rows() |> Enum.find_value(&(&1.question_id == question_id && &1.comment_id))

  defp rows(issue) do
    case RunStore.get_ticket_state(issue.id) do
      %{projected: %{comments: %{} = comments}} ->
        for {question_id, %{comment: comment_id}} <- comments,
            is_binary(comment_id),
            do: %{comment_id: comment_id, question_id: question_id}

      _none ->
        []
    end
  end

  @doc """
  Projects the answer to the question `question_id` on the ticket `issue_id` that Linear refused when
  the Director gave it (`move/4`'s `:decide`, marked pending as `{:question_answer, id, comment_id}`):
  the reply under the request comment `comment_id` (a comment on the ticket when nil), then the
  answer in the Decisions section. Called by the reconciler
  (`SymphonyElixir.TicketObservation`) once Linear answers. `opts[:tracker]` overrides the tracker.
  Returns `{:error, reason}` when Linear refuses the reply again. While the pause projector owns the
  replies (`SymphonyElixir.Pauses.Projector.owns?/0`), the ticket's projection is applied instead,
  which posts the reply once.
  """
  @spec project_answer(String.t(), String.t(), String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def project_answer(repo_key, issue_id, question_id, comment_id, opts \\ []) do
    if Projector.owns?(),
      do: Projector.project_now({:ticket, repo_key, issue_id}, Keyword.take(opts, [:tracker])),
      else: reply_answer(repo_key, issue_id, question_id, comment_id, opts)
  end

  defp reply_answer(repo_key, issue_id, question_id, comment_id, opts) do
    case Questions.find({:ticket, repo_key, issue_id}, question_id) do
      %{state: :answered, answer: %{text: text}} = question ->
        tracker = Keyword.get(opts, :tracker, Tracker)
        picks = [%{question: question.question, answer: text, option: Questions.option_label(question)}]
        comment = decide_comment(picks)
        issue = %Issue{id: issue_id, repo_key: repo_key}

        with :ok <- projected_reply(tracker, issue_id, comment_id, comment) do
          record_decision(issue, comment_id || question.id, question, picks, tracker: tracker)
        end

      _not_answered ->
        :ok
    end
  end

  defp projected_reply(tracker, issue_id, nil, comment), do: tracker.create_comment(issue_id, comment)
  defp projected_reply(tracker, issue_id, comment_id, comment), do: tracker.create_reply(issue_id, comment_id, comment)

  # The answer goes into the ticket's scope now, so the run the answer lets through reads it.
  # Best-effort: the answer is already on the Question. A pick of an option that unlocks protected
  # paths records them, read from the Question (`SymphonyElixir.PathUnlock.picked_paths/2`).
  defp record_decision(issue, request_comment_id, decision, picks, opts \\ []) do
    title = Map.get(decision, :title)
    question = Map.get(decision, :question) || Enum.map_join(picks, " / ", & &1.question)
    answers = Enum.map(picks, & &1.answer)
    # The option picked beside the person's words unlocks its paths, never the words.
    unlocks = PathUnlock.picked_paths(decision, Enum.map(picks, &(blank_to_nil(Map.get(&1, :option)) || &1.answer)))
    entry = Decisions.entry(request_comment_id, Date.utc_today(), title, question, Enum.join(answers, " / "), unlocks)
    _ = Decisions.record(issue.id, [entry], [repo_key: issue.repo_key] ++ opts)
    :ok
  end

  defp picked_move(question, picks) do
    answers = Enum.map(picks, &(blank_to_nil(Map.get(&1, :option)) || &1.answer))

    case MergeConfirmation.confirm_target(question) && MergeConfirmation.picked(question, answers) do
      {:ok, target} when is_binary(target) -> %{to: target}
      nil -> DecisionMove.picked(question, answers)
      _moves_nothing -> nil
    end
  end

  defp reply_to_request(issue, comment_id, comment) do
    case Tracker.create_reply(issue.id, comment_id, comment) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # With nothing to move, the ticket continues in its phase: the Question is answered, so its pause
  # reason is gone and the next poll dispatches it again.
  defp decision_move(issue, nil, comment, undo, opts) do
    TicketSignals.record(issue.repo_key, issue.id, "decision returned", %{move: "decide", from: issue.state, to: issue.state})
    finish(:decide, issue, nil, comment, opts, undo)
  end

  # The decision is recorded, so a refused move is reported without taking it back: the ticket
  # continues in place, with the decision on it.
  defp decision_move(issue, directed, comment, undo, opts) do
    case DecisionMove.perform(issue.repo_key, issue.id, directed, issue_identifier: issue.identifier) do
      {:ok, to_state} ->
        record_move_signal(issue, :decide, to_state)
        finish(:decide, issue, to_state, comment, opts, undo)

      {:error, reason} ->
        decision_move_refused(issue, directed.to, reason, comment, opts)
    end
  end

  defp decision_move_refused(issue, to_state, reason, comment, opts) do
    record_audit("decide", issue, issue.state, issue.state, comment, %{failed: "move", directed: to_state})
    request_refresh(issue, opts)

    partial(
      "recorded the decision on #{issue.identifier}, but Linear refused the move to " <>
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

  defp restart_opts(opts), do: Keyword.take(opts, [:github, :workspace, :agent_processes, :workspace_cleanup, :settings, :linear_client, :now, :linear_retry_opts])

  # A Decide that answered a Question is remembered whether or not it moved the ticket (`undo`):
  # Undo reopens the Question.
  # `extra` goes on the audit record and the `person.action` event (a restart's `run_stopped`).
  defp finish(move, issue, to_state, comment, opts, undo \\ %{}, extra \\ %{}) do
    name = Atom.to_string(move)
    record_audit(name, issue, issue.state, to_state || issue.state, comment, extra)
    Logger.info("Director move #{name} issue_id=#{issue.id} issue_identifier=#{issue.identifier} from=#{issue.state} to=#{to_state || issue.state}")
    undoable? = undoable_move?(move, to_state, undo)

    if undoable?, do: remember_move(move, issue, to_state || issue.state, undo, opts)
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
       undo_window_ms: if(undoable? and move != :restart, do: @undo_window_ms)
     }}
  end

  # An Unblock is not taken back: a parked ticket it moved back is dispatched at once.
  defp undoable_move?(move, to_state, undo), do: (to_state != nil or undo != %{}) and move not in [:unblock | @revision_moves]

  defp remember_move(move, issue, to_state, undo, opts) do
    entry = %{move: move, from_state: issue.state, to_state: to_state, at_ms: now_ms(opts), backlog: BreakdownReview.backlog_sub_issue_ids(issue)}
    Agent.update(server(opts), &Map.put(&1, issue.id, Map.merge(entry, undo)))
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
            conflict("the move on #{issue.identifier} is more than #{div(@undo_window_ms, 1000)} s old; use Move to… on the ticket page instead")

          not same_state?(issue.state, last.to_state) ->
            conflict("#{issue.identifier} moved on to #{issue.state} since; use Move to… on the ticket page instead")

          # An approved plan whose sub-tickets Symphony promoted would come back to review approved.
          BreakdownReview.backlog_sub_issue_ids(issue) != last.backlog ->
            conflict("Symphony already promoted the sub-tickets of #{issue.identifier}; use Move to… on each sub-ticket's page instead")

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

    record_person_action(move, issue, from_state, to_state, Map.take(extra, [:run_stopped]))
  end

  # Each move the audit records is also the Director's action on the ticket's events, best effort.
  # A Decide records none: its answer is the `decision.recorded` that `SymphonyElixir.Decisions`
  # writes, a Cancel's is its `ticket.cancelled` and a free move's its `ticket.moved`. The control API authenticates one shared
  # token, so the actor is the Director.
  # A restart's also says whether it ended a run (`run_stopped`).
  defp record_person_action(move, _issue, _from_state, _to_state, _details) when move in ["decide", "cancel", "move"], do: :ok

  defp record_person_action(move, %Issue{repo_key: repo_key, id: issue_id}, from_state, to_state, details) when is_binary(repo_key) do
    payload = if move in ["unblock", "restart"], do: %{action: move}, else: %{action: "move", move: move}
    payload = payload |> Map.merge(%{from: from_state, to: to_state}) |> Map.merge(details)
    TicketSignals.record_event(repo_key, issue_id, "person.action", payload, actor: @director)
  end

  defp record_person_action(_move, _issue, _from_state, _to_state, _details), do: :ok

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

  defp blank_to_nil(value), do: if(present?(value), do: String.trim(value))
end
