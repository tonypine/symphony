defmodule SymphonyElixirWeb.ControlApiController do
  @moduledoc """
  HTTP control plane for the Symphony daemon: pause, resume, stop and PR
  dispatch. Used by `bin/symphony pr` and the `mix symphony.*` tasks via
  `SymphonyElixir.ControlClient`. A stop that ends a run writes a `run_stopped`
  audit record and a `person.action` event (`stop`) on the ticket.

  `start` (`SymphonyElixir.Orchestrator.start_issue/3`) starts a ticket's run at once, ahead of
  the dispatch queue and outside its order: it takes `issue_identifier` and an optional `note`,
  answers 200 with the run it started (`run_id`; its session id arrives with the run) or 409 with
  the reason it was refused (Symphony paused, the repository paused, an open Question, a run
  already working on it, Backlog's "move it first") — the same reason each ticket payload's
  `start` field shows.

  `resume` clears the Director's pause and an update's. A pause held only by reasons Resume can't
  clear (a usage limit's) answers 409 `nothing_to_resume`, naming them in `reasons`, and lifts
  nothing. With `kind` it lifts that one reason and keeps every other (whoever set a reason lifts
  that reason): `kind: "build"` with `version` the update's pause for that version, which the menu
  bar app lifts once its update installed, was rolled back or failed to launch, and which calls
  off the update ready for that version (`update_ready`); `kind: "person"`
  the Director's. Dispatch stays paused while another reason remains, and a reason the pause
  doesn't hold changes nothing: the answer is the pause as it now stands. A `build` without
  `version`, or another kind, is 422 `invalid_resume`. With `condition` (a usage limit's, as its reason's `waits_on.condition` names it:
  `usage_limit:anthropic:all`) `resume` is Try Now (`SymphonyElixir.Orchestrator.try_usage_limit_now/2`):
  the paused hold starts its canary at once, and the answer is Symphony's pause with the hold as it
  now stands (`usage_limit`, null once it cleared). No hold on `condition` is 404
  `usage_limit_not_found`; a headroom hold, which the provider never refused, is 409
  `usage_limit_headroom`.

  `update_ready` (with `version`, a release's version) tells Symphony the menu bar app has that
  update downloaded and verified (`SymphonyElixir.Orchestrator.update_ready/2`): dispatch goes on,
  and Symphony pauses on the update's `build` reason itself at the moment it picks
  (`SymphonyElixir.UpdateWindow`). A newer version replaces the one ready. It answers 200 with the
  update as the state payload's `update_window` gives it, and 422 `invalid_update` without a
  version or with one that isn't a release's.

  `handover` is the menu bar app's ask, once dispatch is paused and no agent run is active, whether
  it may stop Symphony for an update or a restart (`SymphonyElixir.ConductorGate`): 200 with
  `handover: true` when no Conductor turn is running, and from then on none starts until Symphony
  is up again; 409 `conductor_running` with `handover: false` and `conductor_runs` while some are,
  and the app asks again at its next poll.

  `repos/:repo_key/pause` (with an optional `reason`) and `repos/:repo_key/resume` pause and resume
  dispatch for one configured repository (`SymphonyElixir.Orchestrator.pause_repository/3`): each
  answers 200 with the repository and its pause (null once resumed), writes a `repository_paused`
  or `repository_resumed` audit record, and answers 404 for a repository Symphony isn't configured
  with.

  `providers/:provider/pause` and `providers/:provider/resume` pause and resume new runs on one
  provider (`SymphonyElixir.Orchestrator.pause_provider/2`), with no reason: a new run takes its
  first fallback on another provider, one with none waits, and a run working goes on. Each answers
  200 with the provider and its pause (null once resumed), writes a `provider_paused` or
  `provider_resumed` audit record, and answers 404 `provider_not_found`, naming it, for a provider
  no harness reaches.

  The Director's moves from the Mac app's Inbox (`approve_plan`, `rework`, `restart`, `decisions`,
  `changes`, `backlog`, `cancel`, `move`, `unblock`, `decide` and `undo`) are made by
  `SymphonyElixir.DirectorMoves`:
  each takes `issue_identifier`, answers 409 when the ticket's state doesn't allow the move, 502
  `move_incomplete` when Linear took one of the move's two writes and refused the other, 502
  `restart_incomplete` when the reset behind `restart` stopped partway, and 200 with the states it
  moved between. `decide` answers a decision request: it takes the `picks`, the `question_id` they
  answer (the Inbox row's) or the `request_comment_id` of its request (still accepted, resolved to
  its question), and the optional `move` the decision directs. `decisions` takes a plan's `picks`,
  each with the `question_id` or the `request_comment_id` of the question it answers. Each pick of
  either is a `question` and its `answer` (an option's label), with an optional `text`: the person's
  own words. A pick with `text` answers in those words, as the Inbox's "Answer in my own words…"
  does: the Question is answered with them and the decision on the ticket shows them. An `answer`
  naming one of the Question's options stays the pick: the option decides what the answer does
  ("Run it again" runs the ticket again), and the words go with it. A decide on a Question already
  answered answers 200 with `already_decided: true` and the recorded `answer` and `option`, and
  changes nothing. A pick whose `answer` is the own-words option ("In my own words", "Answer in my own words…")
  without `text` is 422 and answers nothing. `move` takes
  `to`, any phase the repo's workflow names, and an optional `note`: a ticket of a configured
  repository Symphony has no record of yet is read from Linear and recorded first. It answers 409
  when the ticket is in no configured repository, that read fails, or `to` is not a phase of the
  repo, and 200 with `moved: false` when the ticket is already there.

  `message` writes the Director's message to a ticket (`SymphonyElixir.Messages`), and `note` is
  an alias of it, kept for callers that still post there: it takes
  `repo_key`, `issue_identifier` and `text`, resolves the ticket as the events feed does
  (`SymphonyElixirWeb.TicketEventsController`), records a `message.sent` event by the Director and a
  `director_note` audit record, and answers 200 with the event as the feed shows it. Each message is
  its own event; none replaces another, and sending one never starts, stops or reorders a run. Text
  that is blank or longer than the `message.sent` type allows is 400 and writes nothing; a ticket
  Symphony has no record of is 404. Unlike a stop's event, the message is the request: the answer
  says whether it was written.

  On a groomed ticket, while the Conductor and its `message` junction are on, the message goes to
  the ticket's Conductor (`SymphonyElixir.Conductor.Message`): its turn starts at once, in a task of
  its own, after the answer is sent, and its reply arrives later as a `conductor.update` event whose
  `parent` is the message (or Symphony's own short reply when the turn failed). No run is given the
  message there. On any other ticket the next run reads it, as before.

  `looked` marks that the person looked at a ticket now (`SymphonyElixir.Marks`): it takes
  `issue_identifier` and an optional `repo_key`, writes the mark on the ticket's record (a view mark,
  so no ledger event) and answers 200 with `issue_identifier`, `looked_at` and `new_since_looked`,
  which is 0 from then on until a newer event. A ticket with no record is 404 and a request without
  `issue_identifier` is 422.

  `blocker` adds or removes a blocker from the ticket page (`SymphonyElixir.DirectorBlockers`): a
  stored dependency of the ticket on the blocker, with no Linear link. It takes `issue_identifier`,
  `blocker` (the ticket that blocks it) and `action` (`add` or `remove`), and answers 200 with the
  ticket's blockers after the change, 409 with the reason the app shows when the change is refused
  (a ticket blocking itself, a cycle, a ticket Symphony doesn't track, a finished blocker, a
  blocker already there or not there), 422 for a missing or unknown parameter and 502, with why,
  when the store refuses the write.

  `priority` sets a ticket's Linear priority from the ticket page (`SymphonyElixir.DirectorPriority`):
  it takes `issue_identifier` and `priority` (`none`, `urgent`, `high`, `medium` or `low`, or
  Linear's number), and answers 200 with the ticket's priority after the move, 409 with the reason
  the app shows when the move is refused (a ticket Symphony doesn't track, the priority it already
  has), 422 for a missing parameter or a priority that isn't one of Linear's, and 502, with why,
  when the tracker refuses the write.

  `queue/move` moves a ticket to another place in the dispatch queue (`SymphonyElixir.DirectorQueue`),
  inside its scope (the top-level tickets, or its parent's sub-tickets): it takes `issue_identifier`
  and one of `position` (`top` or `end`), `after` or `before` (a ticket of the same scope), and
  answers 200 with the ticket, its `scope` and the scope's tickets in their new `order`. Every read
  of the queue made after the answer shows the new order, and the open streams get an
  `event: queue` notice (`change: order`). 409 with the reason the app shows when the move is
  refused (the ticket holds no place in the queue, the neighbour is the ticket itself or in another
  scope, the queue changed under the move), 422 for a missing or unknown parameter or a ticket
  Symphony doesn't track, 502, with why, when the store refuses the write.

  `slots` sets how many tickets hold a slot at once: it takes `count`, a whole number from 1 to 6,
  writes it to `execution.concurrency.max_total` in `symphony.yml` by editing that one line, applies
  it at once (a raised count fills the new slots in the same moment; a lowered one stops no run, and
  a freed slot is not given again while the tickets in progress reach the count), and answers 200
  with `count` and the `slots` the reads now show. The open streams get an `event: queue` notice
  (`change: slots`). 422 for a count outside 1 to 6, with the file left as it is, and 502, with why,
  when the file can't be changed one line at a time.

  `label` turns one of the labels a person adds for Symphony to read on or off from the ticket page
  (`SymphonyElixir.DirectorLabels`): it takes `issue_identifier`, `label` and `action` (`add` or
  `remove`), and answers 200 with the ticket's label toggles after the change, 409 with the reason
  the app shows when the change is refused (a label Symphony doesn't read, a machine label, a
  ticket Symphony doesn't track, a label already on or off), 422 for a missing or
  unknown parameter and 502, with why, when the tracker refuses the write.

  `decision` records the Director's ruling on a ticket from its page, a decision no Question asked
  for (`SymphonyElixir.DirectorRulings`): it takes `issue_identifier` and `text`, and answers 200
  with the ticket's decisions after it, 400 `invalid_decision` for a blank text or one longer than a
  decision holds, 409 with the reason the app shows when it is refused (a ticket Symphony doesn't
  track, a decision with the same text already recorded), 422 for a missing `issue_identifier` and
  502, with why, when the tracker or the store refuses the write.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.{AuditLog, DirectorBlockers, DirectorLabels, DirectorMoves, DirectorPriority, DirectorQueue, DirectorRulings}
  alias SymphonyElixir.Conductor.Message, as: ConductorMessage
  alias SymphonyElixir.{ConductorGate, Marks, Messages, Orchestrator, TicketMoves, TicketSignals, UpdateWindow}
  alias SymphonyElixir.TicketEvents.Types
  alias SymphonyElixirWeb.{Endpoint, Presenter, TicketEventsController}

  # The control API authenticates one shared token, so a person's action is the Director's.
  @director {:person, "the Director"}
  @note_preview_chars 500
  # The `run.started_by_person` event's `note` line is bounded; a longer note is refused here.
  @start_note_max_chars 500

  @spec pause(Conn.t(), map()) :: Conn.t()
  def pause(conn, params) do
    reason = string_param(params["reason"])
    respond(conn, Orchestrator.pause_dispatch(orchestrator(conn), reason))
  end

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, params) do
    case {string_param(params["condition"]), string_param(params["kind"]), string_param(params["version"])} do
      {nil, nil, _version} ->
        respond_resume(conn, Orchestrator.resume_dispatch(orchestrator(conn)))

      {nil, "build", nil} ->
        error_response(conn, 422, "invalid_resume", "Lifting an update's pause needs the version it waits on")

      {nil, "build", version} ->
        respond(conn, Orchestrator.resume_dispatch(orchestrator(conn), {:build, version}))

      {nil, "person", _version} ->
        respond(conn, Orchestrator.resume_dispatch(orchestrator(conn), :person))

      {nil, kind, _version} ->
        error_response(conn, 422, "invalid_resume", "Resume lifts a pause of kind build or person, not #{kind}")

      {condition, _kind, _version} ->
        respond_resume(conn, Orchestrator.try_usage_limit_now(orchestrator(conn), condition))
    end
  end

  defp respond_resume(conn, {:error, {:nothing_to_resume, reasons}}) do
    texts = reasons |> Enum.map(& &1.text) |> Enum.reject(&(&1 in [nil, ""]))
    waits = if texts == [], do: "", else: " It waits on " <> Enum.join(texts, "; ") <> "."
    try_now = if Enum.any?(reasons, &usage_limit_reason?/1), do: " Try Now checks a usage limit before its reset.", else: ""

    conn
    |> put_status(409)
    |> json(%{
      error: %{
        code: "nothing_to_resume",
        message: "Nothing to resume: no pause of yours or an update's holds Symphony." <> waits <> try_now,
        reasons: reasons
      }
    })
  end

  defp respond_resume(conn, {:error, {:usage_limit_not_found, condition}}),
    do: error_response(conn, 404, "usage_limit_not_found", "No usage limit holds Symphony on #{condition}")

  defp respond_resume(conn, {:error, {:usage_limit_headroom, condition}}),
    do: error_response(conn, 409, "usage_limit_headroom", "The hold on #{condition} keeps headroom; the provider never refused a run, so there is nothing to try")

  defp respond_resume(conn, result), do: respond(conn, result)

  defp usage_limit_reason?(%{waits_on: %{condition: "usage_limit:" <> _key}}), do: true
  defp usage_limit_reason?(_reason), do: false

  @spec update_ready(Conn.t(), map()) :: Conn.t()
  def update_ready(conn, params) do
    case string_param(params["version"]) do
      version when is_binary(version) ->
        if UpdateWindow.version?(version),
          do: respond(conn, Orchestrator.update_ready(orchestrator(conn), version)),
          else: error_response(conn, 422, "invalid_update", "An update names the release's version, such as 0.0.1.42, not #{version}")

      nil ->
        error_response(conn, 422, "invalid_update", "An update names the version it installs")
    end
  end

  @spec handover(Conn.t(), map()) :: Conn.t()
  def handover(conn, _params) do
    case ConductorGate.handover(Map.get(conn.assigns, :conductor_gate, ConductorGate)) do
      :ok ->
        json(conn, %{handover: true, conductor_runs: 0})

      {:wait, count} ->
        runs = if count == 1, do: "1 Conductor run is", else: "#{count} Conductor runs are"

        conn
        |> put_status(409)
        |> json(%{handover: false, conductor_runs: count, error: %{code: "conductor_running", message: "#{runs} still running"}})
    end
  end

  @spec pause_repository(Conn.t(), map()) :: Conn.t()
  def pause_repository(conn, %{"repo_key" => repo_key} = params) do
    reason = string_param(params["reason"])
    result = Orchestrator.pause_repository(orchestrator(conn), repo_key, reason)
    record_repository_action(conn, "repository_paused", result, %{reason: reason})
    respond_repository(conn, repo_key, result)
  end

  @spec resume_repository(Conn.t(), map()) :: Conn.t()
  def resume_repository(conn, %{"repo_key" => repo_key}) do
    result = Orchestrator.resume_repository(orchestrator(conn), repo_key)
    record_repository_action(conn, "repository_resumed", result, %{})
    respond_repository(conn, repo_key, result)
  end

  @spec pause_provider(Conn.t(), map()) :: Conn.t()
  def pause_provider(conn, %{"provider" => provider}) do
    result = Orchestrator.pause_provider(orchestrator(conn), provider)
    record_provider_action(conn, "provider_paused", result)
    respond_provider(conn, result)
  end

  @spec resume_provider(Conn.t(), map()) :: Conn.t()
  def resume_provider(conn, %{"provider" => provider}) do
    result = Orchestrator.resume_provider(orchestrator(conn), provider)
    record_provider_action(conn, "provider_resumed", result)
    respond_provider(conn, result)
  end

  @spec stop(Conn.t(), map()) :: Conn.t()
  def stop(conn, %{"issue_identifier" => identifier}) when is_binary(identifier) and identifier != "" do
    result = Orchestrator.stop_running(orchestrator(conn), identifier)
    record_stop(conn, result)
    respond(conn, result)
  end

  def stop(conn, _params) do
    error_response(conn, 422, "invalid_request", "issue_identifier is required")
  end

  @spec dispatch_pr(Conn.t(), map()) :: Conn.t()
  def dispatch_pr(conn, %{"target" => target} = params) when is_binary(target) and target != "" do
    opts =
      case string_param(params["intent"]) do
        nil -> []
        intent -> [intent: intent]
      end

    respond(conn, Orchestrator.dispatch_pr(orchestrator(conn), target, opts))
  end

  def dispatch_pr(conn, _params) do
    error_response(conn, 422, "invalid_request", "target is required")
  end

  # Start now: the run for the ticket's current phase starts in this call, not queued. The
  # `note` rides its `run.started_by_person` event, whose `note` line is bounded; the refusals
  # answer 409 with the reason the ticket payload's `start` field also shows.
  @spec start(Conn.t(), map()) :: Conn.t()
  def start(conn, params) do
    with {:ok, identifier} <- required_param(params["issue_identifier"], "issue_identifier"),
         {:ok, note} <- start_note(params["note"]) do
      respond_start(conn, identifier, Orchestrator.start_issue(orchestrator(conn), identifier, note))
    else
      {:error, {:invalid_request, message}} -> error_response(conn, 422, "invalid_request", message)
    end
  end

  @spec approve_plan(Conn.t(), map()) :: Conn.t()
  def approve_plan(conn, params), do: director_move(conn, :approve_plan, params, %{})

  @spec rework(Conn.t(), map()) :: Conn.t()
  def rework(conn, params), do: director_move(conn, :rework, params, %{reason: string_param(params["reason"])})

  @spec restart(Conn.t(), map()) :: Conn.t()
  def restart(conn, params), do: director_move(conn, :restart, params, %{reason: string_param(params["reason"])})

  @spec decisions(Conn.t(), map()) :: Conn.t()
  def decisions(conn, params) do
    with {:ok, picks} <- own_words_picks(conn, params["picks"]), do: director_move(conn, :decisions, params, %{picks: picks})
  end

  @spec changes(Conn.t(), map()) :: Conn.t()
  def changes(conn, params), do: director_move(conn, :changes, params, %{reason: string_param(params["reason"])})

  @spec backlog(Conn.t(), map()) :: Conn.t()
  def backlog(conn, params), do: director_move(conn, :backlog, params, %{note: string_param(params["note"])})

  @spec cancel(Conn.t(), map()) :: Conn.t()
  def cancel(conn, params), do: director_move(conn, :cancel, params, %{note: string_param(params["note"])})

  @spec move(Conn.t(), map()) :: Conn.t()
  def move(conn, params), do: director_move(conn, :move, params, %{to: string_param(params["to"]), note: string_param(params["note"])})

  @spec unblock(Conn.t(), map()) :: Conn.t()
  def unblock(conn, params), do: director_move(conn, :unblock, params, %{})

  # A Decide with no ticket answers a Question on Symphony itself or a repository by its id alone
  # (`DirectorMoves.decide_subject/2`).
  @spec decide(Conn.t(), map()) :: Conn.t()
  def decide(conn, params) do
    with {:ok, picks} <- own_words_picks(conn, params["picks"]) do
      input = %{
        picks: picks,
        question_id: string_param(params["question_id"]),
        request_comment_id: string_param(params["request_comment_id"]),
        move: string_param(params["move"])
      }

      case {string_param(params["issue_identifier"]), input.question_id} do
        {nil, question_id} when is_binary(question_id) -> respond_subject_decide(conn, question_id, DirectorMoves.decide_subject(input, Map.get(conn.assigns, :director_moves, [])))
        _ticket -> director_move(conn, :decide, params, input)
      end
    end
  end

  # The picks with each one's own words as its answer; an own-words pick without them is refused.
  defp own_words_picks(conn, params_picks) do
    picks = picks(params_picks)

    if Enum.any?(picks || [], &Map.get(&1, :own_words_missing)),
      do: error_response(conn, 422, "invalid_request", "text is required: an answer in your own words carries the words in the pick's text"),
      else: {:ok, picks}
  end

  defp respond_subject_decide(conn, question_id, {:error, :question_not_found}),
    do: error_response(conn, 404, "question_not_found", "No open question #{question_id} on Symphony or a repository")

  defp respond_subject_decide(conn, question_id, result), do: respond_move(conn, question_id, result)

  @spec undo(Conn.t(), map()) :: Conn.t()
  def undo(conn, params) do
    case string_param(params["issue_identifier"]) do
      nil -> error_response(conn, 422, "invalid_request", "issue_identifier is required")
      identifier -> respond_move(conn, identifier, DirectorMoves.undo(identifier, director_opts(conn)))
    end
  end

  @spec note(Conn.t(), map()) :: Conn.t()
  def note(conn, params) do
    with {:ok, repo_key, identifier} <- note_ticket(params),
         {:ok, text} <- note_text(params["text"]),
         {:ok, record} <- TicketEventsController.ticket(repo_key, identifier),
         # A store error raises, as a read of the feed does: the answer is never a 200 for a note not written.
         {:ok, event} <- Messages.send_message(record.repo_key, record.issue_id, text) do
      record_note(conn, record, event)
      ConductorMessage.start(record, event, Map.get(conn.assigns, :conductor_message, []))
      json(conn, %{event: hd(Presenter.ticket_events_json(record.repo_key, record.issue_id, [event]))})
    else
      {:error, :missing_ticket} -> error_response(conn, 422, "invalid_request", "repo_key and issue_identifier are required")
      {:error, {:invalid_note, message}} -> error_response(conn, 400, "invalid_note", message)
      {:error, :not_found} -> error_response(conn, 404, "ticket_not_found", TicketMoves.no_ticket_reason(params["issue_identifier"], params["repo_key"]))
    end
  end

  @spec message(Conn.t(), map()) :: Conn.t()
  def message(conn, params), do: note(conn, params)

  @spec looked(Conn.t(), map()) :: Conn.t()
  def looked(conn, params) do
    with {:ok, identifier} <- required_param(params["issue_identifier"], "issue_identifier"),
         {:ok, %{record: record, looked_at: looked_at}} <- Marks.look(identifier, string_param(params["repo_key"]), Map.get(conn.assigns, :marks, [])) do
      looked_at = DateTime.to_iso8601(looked_at)
      json(conn, %{issue_identifier: record.issue_identifier, looked_at: looked_at, new_since_looked: 0})
    else
      {:error, {:invalid_request, message}} ->
        error_response(conn, 422, "invalid_request", message)

      {:error, :not_found} ->
        reason = TicketMoves.no_ticket_reason(params["issue_identifier"], params["repo_key"])
        error_response(conn, 404, "ticket_not_found", reason)

      {:error, reason} ->
        error_response(conn, 502, "store_error", inspect(reason))
    end
  end

  @spec blocker(Conn.t(), map()) :: Conn.t()
  def blocker(conn, params) do
    with {:ok, identifier} <- required_param(params["issue_identifier"], "issue_identifier"),
         {:ok, blocker} <- required_param(params["blocker"], "blocker"),
         {:ok, action} <- blocker_action(params["action"]) do
      opts = [orchestrator: orchestrator(conn), audit_log: Map.get(conn.assigns, :audit_log, [])] ++ Map.get(conn.assigns, :director_blockers, [])

      case DirectorBlockers.change(action, identifier, blocker, opts) do
        {:error, {:store, message}} -> error_response(conn, 502, "store_error", message)
        result -> respond_move(conn, identifier, result)
      end
    else
      {:error, {:invalid_request, message}} -> error_response(conn, 422, "invalid_request", message)
    end
  end

  @spec priority(Conn.t(), map()) :: Conn.t()
  def priority(conn, params) do
    with {:ok, identifier} <- required_param(params["issue_identifier"], "issue_identifier"),
         {:ok, priority} <- priority_param(params["priority"]) do
      opts = [orchestrator: orchestrator(conn), audit_log: Map.get(conn.assigns, :audit_log, [])] ++ Map.get(conn.assigns, :director_priority, [])

      case DirectorPriority.set(identifier, priority, opts) do
        {:error, {:linear, message}} -> error_response(conn, 502, "linear_error", message)
        result -> respond_move(conn, identifier, result)
      end
    else
      {:error, {:invalid_request, message}} -> error_response(conn, 422, "invalid_request", message)
    end
  end

  @spec queue_move(Conn.t(), map()) :: Conn.t()
  def queue_move(conn, params) do
    with {:ok, identifier} <- required_param(params["issue_identifier"], "issue_identifier"),
         {:ok, target} <- queue_target(params) do
      case DirectorQueue.move(identifier, target, [orchestrator: orchestrator(conn)] ++ Map.get(conn.assigns, :director_queue, [])) do
        {:error, {:invalid, message}} -> error_response(conn, 422, "invalid_request", message)
        result -> respond_move(conn, identifier, result)
      end
    else
      {:error, {:invalid_request, message}} -> error_response(conn, 422, "invalid_request", message)
    end
  end

  @spec slots(Conn.t(), map()) :: Conn.t()
  def slots(conn, params) do
    case DirectorQueue.set_slots(params["count"], [orchestrator: orchestrator(conn)] ++ Map.get(conn.assigns, :director_queue, [])) do
      {:ok, payload} -> json(conn, payload)
      {:error, {:invalid, message}} -> error_response(conn, 422, "invalid_request", message)
      {:error, {:config, message}} -> error_response(conn, 502, "config_error", message)
    end
  end

  # Exactly one of `position` (top or end), `after` and `before`.
  defp queue_target(params) do
    case {string_param(params["position"]), string_param(params["after"]), string_param(params["before"])} do
      {"top", nil, nil} -> {:ok, :top}
      {"end", nil, nil} -> {:ok, :end}
      {nil, after_ticket, nil} when is_binary(after_ticket) -> {:ok, {:after, after_ticket}}
      {nil, nil, before_ticket} when is_binary(before_ticket) -> {:ok, {:before, before_ticket}}
      _other -> {:error, {:invalid_request, "name one place: position (top or end), after or before"}}
    end
  end

  @spec label(Conn.t(), map()) :: Conn.t()
  def label(conn, params) do
    with {:ok, identifier} <- required_param(params["issue_identifier"], "issue_identifier"),
         {:ok, label} <- required_param(params["label"], "label"),
         {:ok, action} <- blocker_action(params["action"]) do
      opts = [orchestrator: orchestrator(conn), audit_log: Map.get(conn.assigns, :audit_log, [])] ++ Map.get(conn.assigns, :director_labels, [])

      case DirectorLabels.set(identifier, label, action, opts) do
        {:error, {:linear, message}} -> error_response(conn, 502, "linear_error", message)
        result -> respond_move(conn, identifier, result)
      end
    else
      {:error, {:invalid_request, message}} -> error_response(conn, 422, "invalid_request", message)
    end
  end

  @spec decision(Conn.t(), map()) :: Conn.t()
  def decision(conn, params) do
    case required_param(params["issue_identifier"], "issue_identifier") do
      {:ok, identifier} ->
        opts = [orchestrator: orchestrator(conn), audit_log: Map.get(conn.assigns, :audit_log, [])] ++ Map.get(conn.assigns, :director_rulings, [])

        case DirectorRulings.record(identifier, params["text"], opts) do
          {:error, {:invalid, message}} -> error_response(conn, 400, "invalid_decision", message)
          {:error, {:linear, message}} -> error_response(conn, 502, "linear_error", message)
          result -> respond_move(conn, identifier, result)
        end

      {:error, {:invalid_request, message}} ->
        error_response(conn, 422, "invalid_request", message)
    end
  end

  defp priority_param(priority) when is_integer(priority), do: {:ok, priority}
  defp priority_param(priority), do: required_param(priority, "priority")

  defp blocker_action(action) do
    case string_param(action) do
      "add" -> {:ok, :add}
      "remove" -> {:ok, :remove}
      _other -> {:error, {:invalid_request, "action must be add or remove"}}
    end
  end

  # The Mac app's ticket timeline says "Stopped by you" from this record.
  defp record_stop(conn, {:ok, %{stopped: true} = payload}) do
    %{
      event_type: "run_stopped",
      repo_key: Map.get(payload, :repo_key),
      issue_id: Map.get(payload, :issue_id),
      issue_identifier: Map.get(payload, :issue_identifier),
      session_id: Map.get(payload, :session_id)
    }
    |> AuditLog.record(Map.get(conn.assigns, :audit_log, []))
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record run_stopped audit event: issue_identifier=#{payload[:issue_identifier]} reason=#{inspect(reason)}")
    end

    record_stop_action(Map.get(payload, :repo_key), Map.get(payload, :issue_id))
  end

  defp record_stop(_conn, _result), do: :ok

  # The stop is also the Director's action on the ticket's events, best effort. The control API
  # authenticates one shared token, so the actor is the Director, not a named person.
  defp record_stop_action(repo_key, issue_id) when is_binary(repo_key) and is_binary(issue_id),
    do: TicketSignals.record_event(repo_key, issue_id, "person.action", %{action: "stop"}, actor: @director)

  defp record_stop_action(_repo_key, _issue_id), do: :ok

  # The audit record of a repository's pause or resume, as of the Director's other actions; best
  # effort, since the pause itself is written.
  defp record_repository_action(conn, event_type, {:ok, %{repo_key: repo_key}}, attrs) do
    %{event_type: event_type, repo_key: repo_key}
    |> Map.merge(attrs)
    |> AuditLog.record(Map.get(conn.assigns, :audit_log, []))
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record #{event_type} audit event: repo_key=#{repo_key} reason=#{inspect(reason)}")
    end
  end

  defp record_repository_action(_conn, _event_type, _result, _attrs), do: :ok

  defp respond_repository(conn, _repo_key, {:ok, status}), do: json(conn, %{repository: Presenter.repository_payload(status)})

  defp respond_repository(conn, repo_key, {:error, :repository_not_found}),
    do: error_response(conn, 404, "repository_not_found", "Symphony has no repository #{repo_key}")

  defp respond_repository(conn, _repo_key, result), do: respond(conn, result)

  defp record_provider_action(conn, event_type, {:ok, %{provider: provider}}) do
    case AuditLog.record(%{event_type: event_type, provider: provider}, Map.get(conn.assigns, :audit_log, [])) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record #{event_type} audit event: provider=#{provider} reason=#{inspect(reason)}")
    end
  end

  defp record_provider_action(_conn, _event_type, _result), do: :ok

  defp respond_provider(conn, {:ok, status}), do: json(conn, %{provider: Presenter.provider_payload(status)})

  defp respond_provider(conn, {:error, {:provider_not_found, provider}}),
    do: error_response(conn, 404, "provider_not_found", "Symphony knows no provider #{provider}")

  defp respond_provider(conn, result), do: respond(conn, result)

  defp note_ticket(params) do
    case {string_param(params["repo_key"]), string_param(params["issue_identifier"])} do
      {repo_key, identifier} when is_binary(repo_key) and is_binary(identifier) -> {:ok, repo_key, identifier}
      _missing -> {:error, :missing_ticket}
    end
  end

  # The bound is the `message.sent` type's, so the answer refuses what the event's schema would.
  defp note_text(text) do
    {:string, max} = Types.catalog()["message.sent"].required[:text]
    text = string_param(text)

    cond do
      is_nil(text) -> {:error, {:invalid_note, "A note needs text"}}
      String.length(text) > max -> {:error, {:invalid_note, "A note holds at most #{delimit(max)} characters; this one has #{delimit(String.length(text))}"}}
      true -> {:ok, text}
    end
  end

  defp delimit(number), do: Regex.replace(~r/\B(?=(\d{3})+(?!\d))/, Integer.to_string(number), ",")

  # The audit record of the note, as `director_move` is of the Director's other actions; best
  # effort, since the note itself is written.
  defp record_note(conn, record, event) do
    %{
      event_type: "director_note",
      repo_key: record.repo_key,
      issue_id: record.issue_id,
      issue_identifier: record.issue_identifier,
      event_id: event.id,
      text: String.slice(event.payload.text, 0, @note_preview_chars)
    }
    |> AuditLog.record(Map.get(conn.assigns, :audit_log, []))
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record director_note audit event: issue_identifier=#{record.issue_identifier} reason=#{inspect(reason)}")
    end
  end

  defp director_move(conn, move, params, input) do
    case string_param(params["issue_identifier"]) do
      nil -> error_response(conn, 422, "invalid_request", "issue_identifier is required")
      identifier -> respond_move(conn, identifier, DirectorMoves.move(move, identifier, input, director_opts(conn)))
    end
  end

  # A plan's pick also names the Question it answers or the request comment it goes under. A pick's
  # `text` is the person's own words: they are the answer, as the Inbox's write-in sends them, so
  # the Question service records them as the answer and the decision on the ticket shows them.
  # Words given with an option's label (not the own-words option) keep that label as the pick's
  # `option`: the option decides what the answer does ("Run it again" runs it), never the words.
  defp picks(picks) when is_list(picks) do
    for pick <- picks do
      answer = string_param(pick_field(pick, "answer"))
      text = string_param(pick_field(pick, "text"))

      %{question: string_param(pick_field(pick, "question")), answer: text || answer}
      |> put_present(:option, if(text && answer && not own_words_option?(answer), do: answer))
      |> put_present(:question_id, string_param(pick_field(pick, "question_id")))
      |> put_present(:request_comment_id, string_param(pick_field(pick, "request_comment_id")))
      |> put_present(:own_words_missing, if(is_nil(text) and own_words_option?(answer), do: true))
    end
  end

  defp picks(_picks), do: nil

  # The own-words option, as the Inbox labels it ("Answer in my own words…") or a person names it
  # ("In my own words").
  defp own_words_option?(answer) when is_binary(answer) do
    label = answer |> String.trim() |> String.trim_trailing("…") |> String.trim_trailing("...") |> String.downcase()
    label in ["in my own words", "answer in my own words"]
  end

  defp own_words_option?(_answer), do: false

  defp put_present(pick, _key, nil), do: pick
  defp put_present(pick, key, value), do: Map.put(pick, key, value)

  defp pick_field(pick, key) when is_map(pick), do: pick[key]
  defp pick_field(_pick, _key), do: nil

  defp director_opts(conn), do: [orchestrator: orchestrator(conn)] ++ Map.get(conn.assigns, :director_moves, [])

  defp respond_move(conn, _identifier, {:ok, payload}), do: json(conn, payload)
  defp respond_move(conn, _identifier, {:error, {:invalid, message}}), do: error_response(conn, 422, "invalid_request", message)
  defp respond_move(conn, _identifier, {:error, {:conflict, message}}), do: error_response(conn, 409, "move_not_allowed", message)

  defp respond_move(conn, _identifier, {:error, {:partial, message}}), do: error_response(conn, 502, "move_incomplete", message)
  defp respond_move(conn, _identifier, {:error, {:restart, message}}), do: error_response(conn, 502, "restart_incomplete", message)
  defp respond_move(conn, _identifier, {:error, {:store, message}}), do: error_response(conn, 502, "store_error", message)

  defp respond_move(conn, identifier, {:error, :issue_not_found}),
    do: error_response(conn, 404, "issue_not_found", "#{identifier} was not found in Linear")

  defp respond_move(conn, _identifier, {:error, {:linear, reason}}), do: respond_linear_error(conn, reason)

  # A Linear request a move or a start needed and Linear refused: 502, with why.
  defp respond_linear_error(conn, {:linear_rate_limited, retry_ms}) do
    until = retry_ms |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    error_response(conn, 502, "linear_error", "Linear is rate-limiting Symphony until #{until}; try again then")
  end

  defp respond_linear_error(conn, reason),
    do: error_response(conn, 502, "linear_error", "Linear request failed: #{inspect(reason)}")

  # A present, trimmed parameter, else the request error naming it.
  defp required_param(value, name) do
    case string_param(value) do
      nil -> {:error, {:invalid_request, "#{name} is required"}}
      param -> {:ok, param}
    end
  end

  # Start now's optional note, bounded by the `run.started_by_person` event's `note` line.
  defp start_note(note) do
    case string_param(note) do
      nil ->
        {:ok, nil}

      text ->
        if String.length(text) > @start_note_max_chars,
          do: {:error, {:invalid_request, "note holds at most #{@start_note_max_chars} characters; this one has #{String.length(text)}"}},
          else: {:ok, text}
    end
  end

  # The start's own answers: 409 with the reason it was refused, 502 when the run could not be
  # started, and the Linear mappings for a ticket Linear can't give or won't move.
  defp respond_start(conn, _identifier, {:ok, payload}), do: json(conn, payload)

  defp respond_start(conn, _identifier, {:error, {:start_refused, reason}}),
    do: error_response(conn, 409, "start_not_allowed", reason)

  defp respond_start(conn, _identifier, {:error, {:start_failed, message}}),
    do: error_response(conn, 502, "start_failed", message)

  defp respond_start(conn, _identifier, {:error, :invalid_issue_id}),
    do: error_response(conn, 422, "invalid_request", "invalid_issue_id")

  defp respond_start(conn, identifier, {:error, :issue_not_found}),
    do: error_response(conn, 404, "issue_not_found", "#{identifier} was not found in Linear")

  defp respond_start(conn, _identifier, {:error, {:linear, reason}}),
    do: respond_linear_error(conn, {:linear, reason})

  defp respond_start(conn, _identifier, :unavailable),
    do: error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

  defp respond_start(conn, _identifier, {:error, reason}) do
    Logger.error("control_api start unexpected orchestrator error: #{inspect(reason)}")
    error_response(conn, 500, "orchestrator_error", "Unexpected orchestrator error")
  end

  defp respond(conn, {:ok, payload}) when is_map(payload), do: json(conn, payload)

  defp respond(conn, :unavailable),
    do: error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

  defp respond(conn, {:error, reason}) when reason in [:invalid_issue_id, :invalid_pr_target],
    do: error_response(conn, 422, "invalid_request", Atom.to_string(reason))

  defp respond(conn, {:error, {:provider_paused, provider}}),
    do: error_response(conn, 409, "provider_paused", "You paused #{SymphonyElixir.AgentProviders.display_name(provider)}; resume it to start a run on it")

  defp respond(conn, {:error, reason}) do
    Logger.error("control_api unexpected orchestrator error: #{inspect(reason)}")
    error_response(conn, 500, "orchestrator_error", "Unexpected orchestrator error")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator(conn) do
    Map.get(conn.assigns, :orchestrator) || Endpoint.config(:orchestrator) || Orchestrator
  end

  defp string_param(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_param(_), do: nil
end
