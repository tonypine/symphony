defmodule SymphonyElixir.DirectorMoves do
  @moduledoc """
  The Linear moves the Director makes from the Mac app's Inbox, through the control API
  (`POST /api/v1/control/<move>`, decision DD4 in `docs/design/director-app-screens.md`).

  Each move reads the ticket, refuses one the workflow doesn't allow from its current state
  (`{:error, {:conflict, message}}`, a 409), posts its comment when it has one, makes the Linear
  move, writes a `director_move` audit record and answers with the states it moved between:

  - `:approve_plan`: a plan (label `plan` or `breakdown`) in `In Review` or the Human Review state
    moves to the waiting state (`Waiting on sub-tickets`). It is a person's move, so Symphony
    promotes the plan's `Backlog` sub-tickets as it does today (`SymphonyElixir.BreakdownReview`);
  - `:approve_pr`: a pull request in a review state moves to `Merging`;
  - `:rework`: a ticket in a review state gets the reason as a comment, then moves to `Rework`;
  - `:decisions`: a plan in a review state gets one comment with the picked options. A plan in the
    Human Review state first moves to `In Review`, so the comment, posted after the move, starts
    Symphony's plan revision run (`SymphonyElixir.PlanComments`);
  - `:sign_off`: a `Final verification:` ticket in a review state moves to `Done`;
  - `:backlog`: an open ticket gets the note as a comment when there is one, then moves to `Backlog`.

  The comments are the Director's: none starts like one of Symphony's own, so the plan revision
  trigger counts them as a person's comment.

  `undo/2` takes back the last move on a ticket within 10 s of it, and only while
  the ticket is still in the state the move put it in, and, for an approved plan, before Symphony
  promoted its sub-tickets. The last move per ticket is kept in this
  module's Agent, so a restart forgets it.
  """

  use Agent

  require Logger

  alias SymphonyElixir.{AuditLog, BreakdownReview, Config, HumanReview, Orchestrator, RunKind, SubIssueWait, Tracker}
  alias SymphonyElixir.Linear.Issue

  @undo_window_ms 10_000
  @review_state "In Review"
  @merging_state "Merging"
  @rework_state "Rework"
  @done_state "Done"
  @backlog_state "Backlog"
  @comment_preview_chars 500

  @type move :: :approve_plan | :approve_pr | :rework | :decisions | :sign_off | :backlog
  @type pick :: %{question: String.t(), answer: String.t()}
  @type input :: %{
          optional(:reason) => String.t() | nil,
          optional(:note) => String.t() | nil,
          optional(:picks) => [pick()]
        }
  @type error ::
          {:invalid, String.t()}
          | {:conflict, String.t()}
          | :issue_not_found
          | {:linear, term()}
  @type result :: {:ok, map()} | {:error, error()}

  @moves [:approve_plan, :approve_pr, :rework, :decisions, :sign_off, :backlog]

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
  `:reason` (required), the backlog `:note` (optional) or the decisions' `:picks` (required).

  Options: `:server` (the Agent, default this module), `:clock` (monotonic milliseconds, for the undo
  window) and `:orchestrator` (asked to poll again after the move, default `SymphonyElixir.Orchestrator`).
  """
  @spec move(move(), String.t(), input(), keyword()) :: result()
  def move(move, identifier, input, opts \\ []) when move in @moves and is_binary(identifier) and is_map(input) do
    with :ok <- validate_input(move, input),
         {:ok, issue} <- fetch_issue(identifier) do
      settings = Config.settings!()

      with {:ok, to_state} <- target(move, issue, settings),
           {:ok, comment} <- apply_move(move, issue, to_state, input) do
        finish(move, issue, to_state, comment, opts)
      end
    end
  end

  @doc """
  Takes back the last move on the ticket `identifier`: moves it back to the state it came from,
  within #{div(@undo_window_ms, 1000)} s of the move and only while it is still where the move put
  it. A comment the move posted stays. Takes the options of `move/4`.
  """
  @spec undo(String.t(), keyword()) :: result()
  def undo(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, issue} <- fetch_issue(identifier),
         {:ok, last} <- undoable(issue, opts),
         :ok <- update_state(issue, last.from_state) do
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

  @doc "The comment `:backlog` posts with the Director's note."
  @spec backlog_comment(String.t()) :: String.t()
  def backlog_comment(note) when is_binary(note), do: "Moved to Backlog by the Director:\n\n#{note}"

  defp validate_input(:rework, input) do
    if present?(input[:reason]), do: :ok, else: {:error, {:invalid, "reason is required"}}
  end

  defp validate_input(:decisions, %{picks: [_ | _] = picks}) do
    if Enum.all?(picks, &valid_pick?/1), do: :ok, else: invalid_picks()
  end

  defp validate_input(:decisions, _input), do: invalid_picks()
  defp validate_input(_move, _input), do: :ok

  defp invalid_picks, do: {:error, {:invalid, "picks must list each decision's question and answer"}}

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

  defp require_review(%Issue{state: state} = issue, settings) do
    if HumanReview.review_state?(state, settings) do
      :ok
    else
      conflict("#{issue.identifier} is #{state || "in no state"}; the Director answers it only from #{Enum.join(HumanReview.review_states(settings), " or ")}")
    end
  end

  defp conflict(message), do: {:error, {:conflict, message}}

  # The comment goes before the move, so the run the move starts reads it; the decisions comment
  # goes after the move to In Review, so the plan revision trigger counts it.
  defp apply_move(:rework, issue, to_state, %{reason: reason}), do: comment_then_move(issue, rework_comment(String.trim(reason)), to_state)

  defp apply_move(:backlog, issue, to_state, input) do
    if present?(input[:note]),
      do: comment_then_move(issue, backlog_comment(String.trim(input.note)), to_state),
      else: comment_then_move(issue, nil, to_state)
  end

  defp apply_move(:decisions, issue, to_state, %{picks: picks}) do
    comment = picks |> Enum.map(&%{question: String.trim(&1.question), answer: String.trim(&1.answer)}) |> decisions_comment()

    with :ok <- maybe_update_state(issue, to_state),
         :ok <- post_comment(issue, comment),
         do: {:ok, comment}
  end

  defp apply_move(_move, issue, to_state, _input), do: comment_then_move(issue, nil, to_state)

  defp comment_then_move(issue, comment, to_state) do
    with :ok <- maybe_post_comment(issue, comment),
         :ok <- update_state(issue, to_state),
         do: {:ok, comment}
  end

  defp maybe_post_comment(_issue, nil), do: :ok
  defp maybe_post_comment(issue, comment), do: post_comment(issue, comment)

  defp post_comment(issue, comment) do
    case Tracker.create_comment(issue.id, comment) do
      :ok -> :ok
      {:error, reason} -> {:error, {:linear, reason}}
    end
  end

  defp maybe_update_state(_issue, nil), do: :ok
  defp maybe_update_state(issue, to_state), do: update_state(issue, to_state)

  defp update_state(issue, to_state) do
    case Tracker.update_issue_state(issue.id, to_state) do
      :ok -> :ok
      {:error, reason} -> {:error, {:linear, reason}}
    end
  end

  defp finish(move, issue, to_state, comment, opts) do
    name = Atom.to_string(move)
    record_audit(name, issue, issue.state, to_state || issue.state, comment)
    Logger.info("Director move #{name} issue_id=#{issue.id} issue_identifier=#{issue.identifier} from=#{issue.state} to=#{to_state || issue.state}")

    if to_state do
      entry = %{move: move, from_state: issue.state, to_state: to_state, at_ms: now_ms(opts), backlog: BreakdownReview.backlog_sub_issue_ids(issue)}
      Agent.update(server(opts), &Map.put(&1, issue.id, entry))
    end

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
       undo_window_ms: if(to_state, do: @undo_window_ms)
     }}
  end

  defp undoable(issue, opts) do
    case Agent.get(server(opts), &Map.get(&1, issue.id)) do
      nil ->
        conflict("there is no move on #{issue.identifier} to undo")

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

  defp record_audit(move, issue, from_state, to_state, comment) do
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
