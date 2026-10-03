defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Quality, StatusDashboard}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, %{"format" => "terminal"} = params) do
    case StatusDashboard.frame(terminal_columns(params), status_dashboard()) do
      {:ok, frame} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, frame)

      :unavailable ->
        error_response(conn, 503, "dashboard_unavailable", "Terminal dashboard is unavailable")
    end
  end

  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec runs(Conn.t(), map()) :: Conn.t()
  def runs(conn, params) do
    case Quality.runs_payload(params) do
      {:ok, payload} ->
        conn
        |> maybe_put_export_header(params)
        |> json(payload)

      {:error, reason} ->
        error_response(conn, 400, "invalid_runs_filter", inspect(reason))
    end
  end

  @spec quality_report(Conn.t(), map()) :: Conn.t()
  def quality_report(conn, %{"session_id" => session_id} = params) do
    case Quality.session_report(session_id, params) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :session_not_found} ->
        error_response(conn, 404, "session_not_found", "Session not found")

      {:error, reason} ->
        error_response(conn, 400, "invalid_runs_filter", inspect(reason))
    end
  end

  @spec transcript(Conn.t(), map()) :: Conn.t()
  def transcript(conn, %{"identifier" => issue_identifier} = params) do
    transcript_result =
      case Map.fetch(params, "repo_key") do
        {:ok, repo_key} ->
          Presenter.transcript_payload(repo_key, issue_identifier, orchestrator(), snapshot_timeout_ms())

        :error ->
          Presenter.transcript_payload(issue_identifier, orchestrator(), snapshot_timeout_ms())
      end

    case transcript_result do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "transcript_not_found", "Transcript not found")

      {:error, :snapshot_unavailable} ->
        error_response(conn, 503, "snapshot_unavailable", "Snapshot unavailable")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp maybe_put_export_header(conn, %{"export" => "json"}) do
    put_resp_header(conn, "content-disposition", ~s(attachment; filename="symphony-quality-runs.json"))
  end

  defp maybe_put_export_header(conn, _params), do: conn

  defp terminal_columns(%{"columns" => columns}) when is_binary(columns) do
    case Integer.parse(columns) do
      {columns, ""} when columns > 0 -> columns
      _ -> nil
    end
  end

  defp terminal_columns(_params), do: nil

  defp status_dashboard do
    Endpoint.config(:status_dashboard) || StatusDashboard
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
