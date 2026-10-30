defmodule SymphonyElixir.NeedsDecisionHold do
  @moduledoc """
  The Needs Decision hold: a ticket pauses in its phase with the question recorded, and continues in
  place once the decision is made.

  A decision request (`SymphonyElixir.HumanActions.Request`), whoever asks it, is raised through
  the one writer, `SymphonyElixir.DecisionRequest`, and never moves the ticket: the ticket keeps its
  phase, gains the `Needs Decision` machine label, and the hold carries the decision payload — the
  question, its options and what clears it. The Inbox loop runs `sweep/3`
  over the tickets it read, reconciling each one's store hold against the requests Linear still
  reads as open (`sync/3` does one ticket).

  A request stops being open when the person answers it — a reply under it, or the Director's
  Decide in the Inbox — or when the run withdraws it. An answer is written into the Decisions
  section of the ticket's description on the read that sees it (`SymphonyElixir.Decisions`), so
  the reviewer and later runs honour it. The hold then clears and the ticket continues
  from where it stopped; a merge confirmation's hold carries the move its confirmation performs, so
  answering that one continues into `Merging` (`SymphonyElixir.MergeConfirmation`), and a reply that
  picks an option carrying its own move makes that move (`SymphonyElixir.DecisionMove`). The move
  is made before the hold clears.

  A hold whose request comment could not be posted (`SymphonyElixir.DecisionRequest.ask/4` marked it
  pending) has no request on Linear yet: the sweep posts it (`DecisionRequest.repost/5`) instead of
  reading the missing request as withdrawn, so the question stays open and the Inbox lists it on the
  next read.

  The hold carries one request, the newest open; an older request asked as a Question stays open
  beside it. When the newer one is answered the hold is set back to the older one, carrying its
  Question (`DecisionRequest.project/4`), and an answer a person gives the older request meanwhile
  answers its Question on the read that sees it.
  """

  require Logger

  alias SymphonyElixir.{Config, DecisionMove, DecisionRequest, Decisions, Handoff, Hold}
  alias SymphonyElixir.HumanActions.{Collector, Request}
  alias SymphonyElixir.{MergeConfirmation, Questions, RunStore, TicketSignals, TicketState}

  @director %{kind: :person, name: "Director"}

  @typedoc "What the ticket's open decision requests call for: set the hold, clear it, or leave it."
  @type action :: {:set, map()} | :clear | :none

  @doc """
  The action the ticket's open decision requests call for, given the Needs Decision hold it already
  has (or nil): `{:set, attrs}` when a request is open and the hold does not already carry it,
  `:clear` when the hold's request is answered or withdrawn, else `:none`.
  """
  @spec desired(Request.t() | nil, map() | nil) :: action()
  def desired(nil, %{kind: :needs_decision}), do: :clear
  def desired(nil, _current_hold), do: :none

  def desired(%{} = request, current_hold) do
    if same_decision?(current_hold, request), do: :none, else: {:set, attrs(request)}
  end

  @doc """
  The hold payload a decision request records: the question as the reason, the options with the
  protected paths each unlocks (`SymphonyElixir.PathUnlock`), and when the decision is recorded as
  what clears it. The request is a parsed one
  (`SymphonyElixir.HumanActions.Request`) or the tool's own request before Linear reads it back,
  which has no `created_at` yet.
  """
  @spec attrs(Request.t() | map()) :: map()
  def attrs(request) do
    %{
      reason: request.question || request.title,
      clearing_condition: "when the decision is recorded",
      decision: %{
        title: request.title,
        question: request.question,
        why: request.why,
        options: request.options,
        unlocks: Request.option_unlocks(request),
        asked_at: Map.get(request, :created_at)
      }
    }
  end

  @doc """
  Reconciles the Needs Decision hold of one ticket against the decision requests Linear still reads
  as open on it. `opts[:settings]` is the repo's resolved settings (the Inbox passes the one it
  resolved for the route); without it the repo is resolved through `Config.settings_for_repo/1`.
  Returns `:skipped` when the repo can't be resolved, else the action taken (`:set`, `:clear` or
  `:none`).
  """
  @spec sync(String.t() | term(), map() | term(), keyword()) :: :skipped | :set | :clear | :none
  def sync(repo_key, node, opts \\ []) do
    with repo_key when is_binary(repo_key) <- repo_key,
         settings when is_map(settings) <- settings(repo_key, opts) do
      sync_ticket(repo_key, node, settings, opts)
    else
      _skipped -> :skipped
    end
  end

  @doc """
  Runs `sync/3` over the ticket nodes a repo route read and returns how many holds it changed. A
  hand-added `Needs Decision` label with no store record is reported and cleared, so the board
  matches the store.
  """
  @spec sweep(String.t() | term(), [map()] | term(), keyword()) :: non_neg_integer()
  def sweep(repo_key, nodes, opts \\ []) do
    if is_list(nodes), do: Enum.count(nodes, &(sync(repo_key, &1, opts) in [:set, :clear])), else: 0
  end

  defp sync_ticket(repo_key, %{"id" => issue_id} = node, settings, opts) when is_binary(issue_id) do
    node = as_recorded(repo_key, node)
    repair_drift(repo_key, issue_id, node, opts)
    # The answers go into the ticket's scope on the read that sees them, whatever the hold does.
    _ = Decisions.sync(node, opts |> Keyword.take([:tracker]) |> Keyword.put(:repo_key, repo_key))
    current = Hold.get(repo_key, issue_id, :needs_decision, opts)
    answer_unheld_questions(repo_key, issue_id, node, current)
    newest = Collector.newest_request(node, settings)

    case pending_comment(desired(newest, current), repo_key, issue_id, current, node, opts) do
      :posted ->
        :none

      {:set, attrs} ->
        answer_replaced(repo_key, issue_id, current, replies(node, current))
        apply_set(repo_key, issue_id, attrs, opts)

      :clear ->
        apply_clear(repo_key, issue_id, current, node, opts)

      :none ->
        :none
    end
  end

  defp sync_ticket(_repo_key, _node, _settings, _opts), do: :none

  @doc """
  The ticket node as Linear read it, with its requests as the ticket's record holds their Questions
  (`SymphonyElixir.Questions`; a request names its Question in a hidden line,
  `SymphonyElixir.DecisionRequest.question_id/1`): a request whose Question is answered or withdrawn
  with no reply under it yet is left out, since the Director's answer is written to the Question
  first and its reply follows (`SymphonyElixir.DirectorMoves`); and the replies under a request whose
  Question the Director reopened (`Questions.reopen/3`) count only from the reopen on. A request with
  no Question, or one the record does not hold, reads as Linear has it.
  """
  @spec as_recorded(String.t() | nil, map()) :: map()
  def as_recorded(repo_key, %{"id" => issue_id} = node) when is_binary(repo_key) and is_binary(issue_id) do
    questions = recorded_questions(repo_key, issue_id)
    comments = node |> get_in(["comments", "nodes"]) |> List.wrap()

    if questions == %{} or not is_list(get_in(node, ["comments", "nodes"])) do
      node
    else
      put_in(node, ["comments", "nodes"], recorded_comments(comments, questions))
    end
  end

  def as_recorded(_repo_key, node), do: node

  defp recorded_questions(repo_key, issue_id) do
    case RunStore.get_ticket_state(repo_key, issue_id) do
      %{} = record -> record |> TicketState.normalize() |> Map.fetch!(:questions) |> Map.new(&{&1.id, &1})
      _none -> %{}
    end
  end

  defp recorded_comments(comments, questions) do
    under = Enum.group_by(comments, &get_in(&1, ["parent", "id"]))

    requests =
      for %{"id" => id, "body" => body} <- comments, %{} = question <- [Map.get(questions, DecisionRequest.question_id(body))], into: %{} do
        {id, question}
      end

    Enum.reject(comments, fn comment ->
      case {Map.get(requests, comment["id"]), Map.get(requests, get_in(comment, ["parent", "id"]))} do
        {%{state: state}, _parent} when state != :open -> Map.get(under, comment["id"], []) == []
        {_request, %{state: :open} = question} -> before_reopen?(comment, question)
        _other -> false
      end
    end)
  end

  defp before_reopen?(comment, %{reopened_at: %DateTime{} = reopened_at}) do
    case DateTime.from_iso8601(comment["createdAt"] || "") do
      {:ok, at, _offset} -> DateTime.compare(at, reopened_at) == :lt
      _unknown -> true
    end
  end

  defp before_reopen?(_comment, _question), do: false

  # The hold carries one question, the newest asked; an older one stays open while its request does.
  # A person who answers that older request meanwhile answers its Question: the newest answer under a
  # request with its title, given after it was asked. The held question ends with the hold's clear.
  defp answer_unheld_questions(repo_key, issue_id, node, current) do
    ticket = {:ticket, repo_key, issue_id}
    held = get_in(current || %{}, [:decision, :question_id])
    answers = Collector.answered_requests(node)

    for %{id: id} = question <- Questions.open(ticket), id != held, %{answer: answer} <- Enum.take(Enum.filter(answers, &answers?(&1, question)), 1) do
      Questions.answer(ticket, id, answer, by: @director)
    end
  end

  defp answers?(%{title: title, at: %DateTime{} = at}, question),
    do: Request.normalize_title(title) == Request.normalize_title(question.title) and DateTime.compare(at, question.asked_at) != :lt

  defp answers?(_answer, _question), do: false

  # A hold whose request is not what Linear reads as open may carry a comment whose post failed: that
  # one is posted now, and the hold is left as it is until the next read sees the request.
  defp pending_comment(:none, _repo_key, _issue_id, _current, _node, _opts), do: :none

  defp pending_comment(action, repo_key, issue_id, current, node, opts) do
    case DecisionRequest.repost(repo_key, issue_id, current, get_in(node, ["state", "name"]), Keyword.take(opts, [:tracker])) do
      :none -> action
      _posted_or_pending -> :posted
    end
  end

  # A hold moving on from a request a person answered, to an older one still open, ends the Question
  # it carried with that answer, as clearing it would.
  defp answer_replaced(repo_key, issue_id, %{decision: %{question_id: id}}, [_ | _] = replies) when is_binary(id),
    do: Questions.answer({:ticket, repo_key, issue_id}, id, String.trim(List.last(replies)), by: @director)

  defp answer_replaced(_repo_key, _issue_id, _current, _replies), do: :ok

  defp apply_set(repo_key, issue_id, attrs, opts) do
    case DecisionRequest.project(repo_key, issue_id, attrs, opts) do
      :ok -> :set
      {:error, reason} -> log_failure("set", issue_id, reason)
    end
  end

  # Clearing the hold is what "the decision is recorded" does. A confirmation hold carries the move
  # its confirmation performs (`SymphonyElixir.MergeConfirmation`), so a reply under the request
  # that picks that option continues there, one that picks `Send to Rework` goes to `Rework`, and
  # any other reply is a change request sent to `In Progress` (`MergeConfirmation.reply_target/2`).
  # An ordinary decision moves the ticket when the reply picks an option carrying a move
  # (`SymphonyElixir.DecisionMove`), else continues in place, so the next poll dispatches it. The
  # move goes before the clear, so the record holds the new phase before the hold lets a dispatch
  # through. A request a reply answered ends with its answer (`Decisions.sync/2` recorded it first);
  # one gone with no answer (withdrawn, deleted) ends as a withdrawal.
  defp apply_clear(repo_key, issue_id, current, node, opts) do
    replies = replies(node, current)

    if moved_since_request?(current, node),
      do: Logger.info("Leaving issue_id=#{issue_id} where a person moved it after its decision request"),
      else: resume(repo_key, issue_id, current, replies, opts)

    case Hold.clear(repo_key, issue_id, :needs_decision, opts |> Keyword.put(:answered, replies != []) |> answer(replies)) do
      :ok ->
        clear_quiet_handoff_hold(repo_key, issue_id, opts)
        :clear

      {:error, reason} ->
        log_failure("clear", issue_id, reason)
    end
  end

  # Runs that went quiet while the ticket waited on its question are what a `handoff_missing` Blocked
  # hold counts (`SymphonyElixir.Orchestrator`), so the answer lifts that hold too: the ticket
  # resumes with no second hold to clear. A Blocked hold on anything else stays.
  defp clear_quiet_handoff_hold(repo_key, issue_id, opts) do
    blocked = Hold.get(repo_key, issue_id, :blocked, opts)

    if get_in(blocked, [:waits_on, :type]) == Handoff.missing_signal(),
      do: log_clear_result(Hold.clear(repo_key, issue_id, :blocked, opts), issue_id),
      else: :ok
  end

  defp log_clear_result(:ok, issue_id), do: Logger.info("Cleared the #{Handoff.missing_signal()} Blocked hold on issue_id=#{issue_id} with its decision")

  defp log_clear_result({:error, reason}, issue_id),
    do: Logger.warning("Failed to clear the #{Handoff.missing_signal()} Blocked hold on issue_id=#{issue_id}: #{inspect(reason)}")

  defp resume(repo_key, issue_id, current, replies, opts) do
    case MergeConfirmation.reply_target(current, replies) do
      nil -> option_move(repo_key, issue_id, DecisionMove.picked(current, replies), opts)
      target -> continue(repo_key, issue_id, "confirm", %{to: target}, opts)
    end
  end

  defp option_move(_repo_key, _issue_id, nil, _opts), do: :ok
  defp option_move(repo_key, issue_id, move, opts), do: continue(repo_key, issue_id, "decide", move, opts)

  # Whether the ticket left the state it waited in since the request was posted: a person's move
  # wins over the answer's. A hold that recorded no state, or a node read without one, can't tell.
  defp moved_since_request?(current, node) do
    waiting = get_in(current, [:decision, :state])
    now = get_in(node, ["state", "name"])
    is_binary(waiting) and is_binary(now) and String.downcase(String.trim(waiting)) != String.downcase(String.trim(now))
  end

  defp continue(repo_key, issue_id, name, move, opts) do
    case DecisionMove.perform(repo_key, issue_id, move, Keyword.take(opts, [:tracker])) do
      {:ok, target} ->
        TicketSignals.record(repo_key, issue_id, "decision returned", %{move: name, to: target})
        :ok

      {:error, reason} ->
        Logger.warning("Failed to continue issue_id=#{issue_id} to #{move.to} after its decision: #{inspect(reason)}")
        :ok
    end
  end

  # The store is the truth for a hold, so the board is repaired to match it in both directions: a
  # `Needs Decision` label with no store hold is a hand-added label, reported and cleared, and a
  # store hold whose label is missing is re-projected, so a hold that pauses dispatch is never
  # silently invisible. While the pause projector owns the labels, the repair has it compare with the
  # labels this read shows rather than what it last applied.
  defp repair_drift(repo_key, issue_id, node, opts) do
    repair = Keyword.merge(opts, force: true, labels: labels(node))

    case Hold.report_drift(repo_key, issue_id, labels(node), Keyword.merge(opts, identifier: node["identifier"], url: node["url"])) do
      {:stray_label, :needs_decision} -> clear_label(repo_key, issue_id, repair)
      {:missing_label, :needs_decision} -> reproject_label(repo_key, issue_id, repair)
      _ok_or_other_kind -> :ok
    end
  end

  defp clear_label(repo_key, issue_id, opts) do
    _ = Hold.clear(repo_key, issue_id, :needs_decision, opts)
    :ok
  end

  defp reproject_label(repo_key, issue_id, opts) do
    _ = Hold.reproject(repo_key, issue_id, :needs_decision, opts)
    :ok
  end

  defp log_failure(action, issue_id, reason) do
    Logger.warning("Failed to #{action} the Needs Decision hold on issue_id=#{issue_id}: #{inspect(reason)}")
    :none
  end

  defp same_decision?(%{kind: :needs_decision, decision: %{} = decision}, request) do
    decision[:title] == request.title and decision[:question] == request.question
  end

  defp same_decision?(_current_hold, _request), do: false

  # The bodies of the replies under the requests carrying the hold's question: the answer a person
  # gave, which names the option they picked. A withdrawal is the run's, not an answer.
  defp replies(node, current) do
    title = get_in(current, [:decision, :title])
    comments = node |> get_in(["comments", "nodes"]) |> List.wrap()
    request_ids = for %{"id" => id, "body" => body} <- comments, match?(%{title: ^title}, Request.parse(body, nil)), into: MapSet.new(), do: id

    for %{"parent" => %{"id" => parent_id}, "body" => body} <- comments,
        MapSet.member?(request_ids, parent_id),
        is_binary(body),
        not Request.withdrawal?(body),
        do: body
  end

  # A reply that answered the request answers the Question the hold projects, in the person's words.
  defp answer(opts, []), do: opts
  defp answer(opts, replies), do: Keyword.put(opts, :question, {:answer, String.trim(List.last(replies)), @director})

  defp labels(node), do: node |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(& &1["name"])

  # The repo's resolved settings: the caller's once-per-route value when it passed one, else
  # resolved from the ticket's repo key.
  defp settings(repo_key, opts) do
    case Keyword.fetch(opts, :settings) do
      {:ok, settings} -> settings
      :error -> settings_for_repo(repo_key)
    end
  end

  defp settings_for_repo(repo_key) when is_binary(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> settings
      {:error, _reason} -> nil
    end
  end
end
