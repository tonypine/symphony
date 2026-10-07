defmodule SymphonyElixirWeb.ControlApiController do
  @moduledoc """
  HTTP control plane for the Symphony daemon: pause, resume, stop, PR
  dispatch, and forcing a ticket. Used by `bin/symphony pr`,
  `bin/symphony force` and the `mix symphony.*` tasks via
  `SymphonyElixir.ControlClient`.

  The Director's moves from the Mac app's Inbox (`approve_plan`, `approve_pr`, `rework`,
  `decisions`, `sign_off`, `backlog` and `undo`) are made by `SymphonyElixir.DirectorMoves`: each
  takes `issue_identifier`, answers 409 when the ticket's state doesn't allow the move, and 200 with
  the states it moved between.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.{DirectorMoves, Orchestrator}
  alias SymphonyElixirWeb.Endpoint

  @spec pause(Conn.t(), map()) :: Conn.t()
  def pause(conn, params) do
    reason = string_param(params["reason"])
    respond(conn, Orchestrator.pause_dispatch(orchestrator(conn), reason))
  end

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, _params) do
    respond(conn, Orchestrator.resume_dispatch(orchestrator(conn)))
  end

  @spec stop(Conn.t(), map()) :: Conn.t()
  def stop(conn, %{"issue_identifier" => identifier}) when is_binary(identifier) and identifier != "" do
    respond(conn, Orchestrator.stop_running(orchestrator(conn), identifier))
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

  @spec approve_pr(Conn.t(), map()) :: Conn.t()
  def approve_pr(conn, params), do: director_move(conn, :approve_pr, params, %{})

  @spec rework(Conn.t(), map()) :: Conn.t()
  def rework(conn, params), do: director_move(conn, :rework, params, %{reason: string_param(params["reason"])})

  @spec decisions(Conn.t(), map()) :: Conn.t()
  def decisions(conn, params), do: director_move(conn, :decisions, params, %{picks: picks(params["picks"])})

  @spec sign_off(Conn.t(), map()) :: Conn.t()
  def sign_off(conn, params), do: director_move(conn, :sign_off, params, %{})

  @spec backlog(Conn.t(), map()) :: Conn.t()
  def backlog(conn, params), do: director_move(conn, :backlog, params, %{note: string_param(params["note"])})

  @spec undo(Conn.t(), map()) :: Conn.t()
  def undo(conn, params) do
    case string_param(params["issue_identifier"]) do
      nil -> error_response(conn, 422, "invalid_request", "issue_identifier is required")
      identifier -> respond_move(conn, identifier, DirectorMoves.undo(identifier, director_opts(conn)))
    end
  end

  defp director_move(conn, move, params, input) do
    case string_param(params["issue_identifier"]) do
      nil -> error_response(conn, 422, "invalid_request", "issue_identifier is required")
      identifier -> respond_move(conn, identifier, DirectorMoves.move(move, identifier, input, director_opts(conn)))
    end
  end

  defp picks(picks) when is_list(picks) do
    for pick <- picks, do: %{question: string_param(pick_field(pick, "question")), answer: string_param(pick_field(pick, "answer"))}
  end

  defp picks(_picks), do: nil

  defp pick_field(pick, key) when is_map(pick), do: pick[key]
  defp pick_field(_pick, _key), do: nil

  defp director_opts(conn), do: [orchestrator: orchestrator(conn)] ++ Map.get(conn.assigns, :director_moves, [])

  defp respond_move(conn, _identifier, {:ok, payload}), do: json(conn, payload)
  defp respond_move(conn, _identifier, {:error, {:invalid, message}}), do: error_response(conn, 422, "invalid_request", message)
  defp respond_move(conn, _identifier, {:error, {:conflict, message}}), do: error_response(conn, 409, "move_not_allowed", message)

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
