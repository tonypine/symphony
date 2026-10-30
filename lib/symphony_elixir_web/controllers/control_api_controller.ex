defmodule SymphonyElixirWeb.ControlApiController do
  @moduledoc """
  HTTP control plane for the Symphony daemon: pause, resume, stop, PR
  dispatch, and forcing a ticket. Used by `bin/symphony pr`,
  `bin/symphony force` and the `mix symphony.*` tasks via
  `SymphonyElixir.ControlClient`. A stop that ends a run writes a `run_stopped`
  audit record and a `person.action` event (`stop`) on the ticket.

  `repos/:repo_key/pause` (with an optional `reason`) and `repos/:repo_key/resume` pause and resume
  dispatch for one configured repository (`SymphonyElixir.Orchestrator.pause_repository/3`): each
  answers 200 with the repository and its pause (null once resumed), writes a `repository_paused`
  or `repository_resumed` audit record, and answers 404 for a repository Symphony isn't configured
  with.

  The Director's moves from the Mac app's Inbox (`approve_plan`, `rework`, `restart`, `decisions`,
  `changes`, `backlog`, `cancel`, `unblock`, `decide` and `undo`) are made by
  `SymphonyElixir.DirectorMoves`:
  each takes `issue_identifier`, answers 409 when the ticket's state doesn't allow the move, 502
  `move_incomplete` when Linear took one of the move's two writes and refused the other, 502
  `restart_incomplete` when the reset behind `restart` stopped partway, and 200 with the states it
  moved between. `decide` answers a decision request: it takes the `picks`, the `question_id` they
  answer (the Inbox row's) or the `request_comment_id` of its request (still accepted, resolved to
  its question), and the optional `move` the decision directs. `decisions` takes a plan's `picks`,
  each with the `question_id` or the `request_comment_id` of the question it answers.

  `note` writes the Director's note on a ticket: it takes `repo_key`, `issue_identifier` and
  `text`, resolves the ticket as the events feed does (`SymphonyElixirWeb.TicketEventsController`),
  records a `note` event by the Director and a `director_note` audit record, and answers 200 with
  the event as the feed shows it. Text that is blank or longer than the `note` type allows is 400
  and writes nothing; a ticket Symphony has no record of is 404. Unlike a stop's event, the note is
  the request: the answer says whether it was written.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.{AuditLog, DirectorMoves, Orchestrator, TicketEvents, TicketSignals}
  alias SymphonyElixir.TicketEvents.Types
  alias SymphonyElixirWeb.{Endpoint, Presenter, TicketEventsController}

  # The control API authenticates one shared token, so a person's action is the Director's.
  @director {:person, "the Director"}
  @note_preview_chars 500

  @spec pause(Conn.t(), map()) :: Conn.t()
  def pause(conn, params) do
    reason = string_param(params["reason"])
    respond(conn, Orchestrator.pause_dispatch(orchestrator(conn), reason))
  end

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, _params) do
    respond(conn, Orchestrator.resume_dispatch(orchestrator(conn)))
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

  @spec force(Conn.t(), map()) :: Conn.t()
  def force(conn, params) do
    case string_param(params["identifier"]) do
      nil ->
        error_response(conn, 422, "invalid_request", "identifier is required")

      identifier ->
        result = Orchestrator.force_issue(orchestrator(conn), identifier, params["clear"] in [true, "true"])
        respond_force(conn, identifier, result)
    end
  end

  @spec approve_plan(Conn.t(), map()) :: Conn.t()
  def approve_plan(conn, params), do: director_move(conn, :approve_plan, params, %{})

  @spec rework(Conn.t(), map()) :: Conn.t()
  def rework(conn, params), do: director_move(conn, :rework, params, %{reason: string_param(params["reason"])})

  @spec restart(Conn.t(), map()) :: Conn.t()
  def restart(conn, params), do: director_move(conn, :restart, params, %{reason: string_param(params["reason"])})

  @spec decisions(Conn.t(), map()) :: Conn.t()
  def decisions(conn, params), do: director_move(conn, :decisions, params, %{picks: picks(params["picks"])})

  @spec changes(Conn.t(), map()) :: Conn.t()
  def changes(conn, params), do: director_move(conn, :changes, params, %{reason: string_param(params["reason"])})

  @spec backlog(Conn.t(), map()) :: Conn.t()
  def backlog(conn, params), do: director_move(conn, :backlog, params, %{note: string_param(params["note"])})

  @spec cancel(Conn.t(), map()) :: Conn.t()
  def cancel(conn, params), do: director_move(conn, :cancel, params, %{note: string_param(params["note"])})

  @spec unblock(Conn.t(), map()) :: Conn.t()
  def unblock(conn, params), do: director_move(conn, :unblock, params, %{})

  @spec decide(Conn.t(), map()) :: Conn.t()
  def decide(conn, params) do
    director_move(conn, :decide, params, %{
      picks: picks(params["picks"]),
      question_id: string_param(params["question_id"]),
      request_comment_id: string_param(params["request_comment_id"]),
      move: string_param(params["move"])
    })
  end

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
         {:ok, event} <- TicketEvents.record(record.repo_key, record.issue_id, "note", %{text: text}, actor: @director) do
      record_note(conn, record, event)
      json(conn, %{event: hd(Presenter.ticket_events_json(record.repo_key, record.issue_id, [event]))})
    else
      {:error, :missing_ticket} -> error_response(conn, 422, "invalid_request", "repo_key and issue_identifier are required")
      {:error, {:invalid_note, message}} -> error_response(conn, 400, "invalid_note", message)
      {:error, :not_found} -> error_response(conn, 404, "ticket_not_found", "No ticket #{params["issue_identifier"]} in #{params["repo_key"]}")
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

  defp note_ticket(params) do
    case {string_param(params["repo_key"]), string_param(params["issue_identifier"])} do
      {repo_key, identifier} when is_binary(repo_key) and is_binary(identifier) -> {:ok, repo_key, identifier}
      _missing -> {:error, :missing_ticket}
    end
  end

  # The bound is the `note` type's, so the answer refuses what the event's schema would.
  defp note_text(text) do
    {:string, max} = Types.catalog()["note"].required[:text]
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

  # A plan's pick also names the Question it answers or the request comment it goes under.
  defp picks(picks) when is_list(picks) do
    for pick <- picks do
      %{question: string_param(pick_field(pick, "question")), answer: string_param(pick_field(pick, "answer"))}
      |> put_present(:question_id, string_param(pick_field(pick, "question_id")))
      |> put_present(:request_comment_id, string_param(pick_field(pick, "request_comment_id")))
    end
  end

  defp picks(_picks), do: nil

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

  defp respond_move(conn, identifier, {:error, {:linear, reason}}),
    do: respond_force(conn, identifier, {:error, reason})

  defp respond_force(conn, identifier, {:error, :issue_not_found}),
    do: error_response(conn, 404, "issue_not_found", "#{identifier} was not found in Linear")

  defp respond_force(conn, identifier, {:error, {:issue_terminal, state}}),
    do: error_response(conn, 422, "issue_terminal", "#{identifier} is #{state}; only an open ticket can be forced")

  defp respond_force(conn, _identifier, {:error, {:label_not_found, label}}),
    do: error_response(conn, 422, "label_not_found", "Linear has no #{label} label; create it in Linear, then force again")

  defp respond_force(conn, _identifier, {:error, {:linear_rate_limited, retry_ms}}) do
    until = retry_ms |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    error_response(conn, 502, "linear_error", "Linear is rate-limiting Symphony until #{until}; try again then")
  end

  defp respond_force(conn, _identifier, {:error, reason}),
    do: error_response(conn, 502, "linear_error", "Linear request failed: #{inspect(reason)}")

  defp respond_force(conn, _identifier, result), do: respond(conn, result)

  defp respond(conn, {:ok, payload}) when is_map(payload), do: json(conn, payload)

  defp respond(conn, :unavailable),
    do: error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

  defp respond(conn, {:error, reason}) when reason in [:invalid_issue_id, :invalid_pr_target],
    do: error_response(conn, 422, "invalid_request", Atom.to_string(reason))

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
