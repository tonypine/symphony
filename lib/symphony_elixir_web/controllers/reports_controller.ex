defmodule SymphonyElixirWeb.ReportsController do
  @moduledoc """
  Status reports (`SymphonyElixir.Reports`).

      GET /api/v1/reports?since=&until=

  answers `{"reports": [...]}`, newest first by when each was published: its `id`, `at`, `run_id`,
  `model`, `period` (`from`, `to`), the `tickets` and `events` it rests on, its `sentences`, their
  `text`, the `citations` (each sentence's index with the ids of the events it cites) and the
  `question_id` of the Question it raised (null for none). `since` and `until` are exclusive ISO 8601
  times; another value is 400. Like the other reads of `/api/v1`, it needs no token.

      POST /api/v1/control/report {"from": "...", "to": "..."}

  starts a report run on the period (`SymphonyElixir.Reports.start/2`) and answers at once with
  `{"run_id", "model", "from", "to", "events"}`; the report shows in the read once the run publishes
  it. `from` and `to` are times as `symphony report` takes them (`SymphonyElixir.Reports.Period`);
  a missing or unreadable one, or a `from` not before `to`, is 422, and so is a period with no notable
  event, which leaves nothing to cite.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Reports
  alias SymphonyElixir.Reports.Period

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    with {:ok, since} <- time(params["since"], "since"),
         {:ok, until} <- time(params["until"], "until"),
         # A store error raises, as the Journal's read does.
         {:ok, reports} <- Reports.list(since: since, until: until) do
      json(conn, %{reports: Enum.map(reports, &Reports.json/1)})
    else
      {:error, {:invalid, message}} -> error_response(conn, 400, "invalid_query", message)
    end
  end

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    opts = Map.get(conn.assigns, :reports_opts, [])

    with {:ok, period} <- Period.new(params["from"], params["to"]),
         {:ok, started} <- Reports.start(period, opts) do
      json(conn, %{started | from: DateTime.to_iso8601(started.from), to: DateTime.to_iso8601(started.to)})
    else
      {:error, :no_events} -> error_response(conn, 422, "no_events", "No notable event happened in that period, so there is nothing to report.")
      {:error, message} when is_binary(message) -> error_response(conn, 422, "invalid_request", message)
    end
  end

  defp time(value, _name) when value in [nil, ""], do: {:ok, nil}

  defp time(value, name) do
    case is_binary(value) && DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _invalid -> {:error, {:invalid, "#{name} must be an ISO 8601 timestamp"}}
    end
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
