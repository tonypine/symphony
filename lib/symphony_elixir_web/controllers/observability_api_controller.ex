defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, History, Inbox, Orchestrator, PullRequestPage, Quality, Shipped, StatusDashboard}
  alias SymphonyElixir.Learnings.Feed
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  # The frame is padded to the requested width inside StatusDashboard; cap it.
  @max_terminal_columns 1_000

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
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms(), stray_processes(), inbox()))
  end

  @spec inbox(Conn.t(), map()) :: Conn.t()
  def inbox(conn, _params) do
    json(conn, Presenter.inbox_payload(orchestrator(), snapshot_timeout_ms(), inbox()))
  end

  @spec initiatives(Conn.t(), map()) :: Conn.t()
  def initiatives(conn, _params) do
    json(conn, Presenter.initiatives_payload(orchestrator(), snapshot_timeout_ms(), initiatives(), inbox()))
  end

  @spec repos(Conn.t(), map()) :: Conn.t()
  def repos(conn, _params) do
    case Presenter.repos_payload(orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        error_response(conn, 503, "config_unavailable", Config.format_error(reason))
    end
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

  @spec pull_request(Conn.t(), map()) :: Conn.t()
  def pull_request(conn, %{"repo_key" => repo_key, "number" => number}) do
    opts = Keyword.merge([live: &live/0], Endpoint.config(:pull_request_page) || [])

    case PullRequestPage.fetch(repo_key, number, opts) do
      {:ok, payload} -> json(conn, payload)
      {:error, :unknown_repo} -> error_response(conn, 404, "unknown_repo", "Unknown repo")
      {:error, :not_found} -> error_response(conn, 404, "not_found", "Pull request not found")
    end
  end

  # What runs and what waits on the Director now, for the page's `waiting_on`; nothing when the
  # snapshot can't be read.
  defp live do
    case Orchestrator.snapshot(orchestrator(), snapshot_timeout_ms()) do
      %{} = snapshot ->
        %{running: snapshot |> Map.get(:running, []) |> MapSet.new(& &1.issue_id), you: snapshot |> Inbox.items(inbox()) |> MapSet.new(& &1.issue_id)}

      _unavailable ->
        %{running: MapSet.new(), you: MapSet.new()}
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

  @spec history(Conn.t(), map()) :: Conn.t()
  def history(conn, params) do
    case History.payload(params) do
      {:ok, payload} -> json(conn, payload)
      {:error, :invalid_days} -> error_response(conn, 400, "invalid_days", "days must be an integer from 1 to 90")
    end
  end

  @spec shipped(Conn.t(), map()) :: Conn.t()
  def shipped(conn, params) do
    case Shipped.payload(params) do
      {:ok, payload} -> json(conn, payload)
      {:error, :invalid_days} -> error_response(conn, 400, "invalid_days", "days must be an integer from 1 to 90")
    end
  end

  @spec learnings(Conn.t(), map()) :: Conn.t()
  def learnings(conn, params), do: json(conn, Feed.payload(params))

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
      {columns, ""} when columns > 0 -> min(columns, @max_terminal_columns)
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

  defp stray_processes do
    Endpoint.config(:stray_processes) || SymphonyElixir.StrayProcesses
  end

  defp inbox do
    Endpoint.config(:inbox) || SymphonyElixir.Inbox
  end

  defp initiatives do
    Endpoint.config(:initiatives) || SymphonyElixir.Initiatives
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
