defmodule SymphonyElixirWeb.TicketEventsController do
  @moduledoc """
  The read-only feed of a ticket's events (`SymphonyElixir.TicketEvents`), the debug API through
  which the event stream is visible:

      GET /api/v1/repos/:repo_key/tickets/:issue_identifier/events?since=&types=&run_id=&limit=&group=

  answers `{"events": [...], "next_since": iso8601}`: the events oldest first, each with its
  summary and its artifacts (`SymphonyElixirWeb.Presenter.ticket_events_json/3`), and the `at` of
  the last one returned, which the next page passes as `since` (exclusive). A page never ends inside
  a group of events that share one `at`, so paging returns every event once. `types` is a
  comma-separated list of catalog types (`SymphonyElixir.TicketEvents.Types`), `run_id` keeps one
  run's events, and `limit` defaults to 50 and is capped at 200.

  `group=run` answers `{"timeline": [...], "next_since": iso8601}` instead: the same page grouped
  by run and by parent (`SymphonyElixirWeb.Presenter.ticket_timeline_json/4`). Each run's header is
  read from the ticket's whole history, so a page that holds a run's newest events answers the
  run's header as it is now, and a run whose events span two pages shows on each with that page's
  events; a client merges them by `run_id`.

  The identifier resolves through the ticket's record (`SymphonyElixir.TicketState`): a ticket
  with none is 404. An unknown type, a `since` that is not an ISO 8601 timestamp, a `limit` that
  is not a positive integer or a `group` other than `run` is 400. Like the other reads of
  `/api/v1`, it needs no token.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{RunStore, TicketEvents, TicketState}
  alias SymphonyElixir.TicketEvents.Types
  alias SymphonyElixirWeb.Presenter

  # The events a run's header is read from.
  @run_header_types ["run.started", "run.ended", "verdict.recorded"]

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, %{"repo_key" => repo_key, "issue_identifier" => issue_identifier} = params) do
    with {:ok, record} <- ticket(repo_key, issue_identifier),
         {:ok, opts} <- query_opts(params),
         {:ok, group} <- group(params["group"]),
         events when is_list(events) <- TicketEvents.query(record.repo_key, record.issue_id, opts) do
      json(conn, record |> page_json(events, group) |> Map.put(:next_since, next_since(events, opts[:since])))
    else
      # A store error that is neither raises, as any read of a store that failed does.
      {:error, :not_found} -> error_response(conn, 404, "ticket_not_found", "No ticket #{issue_identifier} in #{repo_key}")
      {:error, {:invalid, message}} -> error_response(conn, 400, "invalid_query", message)
    end
  end

  @doc """
  The record of `repo_key`'s ticket `issue_identifier` (`SymphonyElixir.TicketState`), as the feed
  and the control API's note (`SymphonyElixirWeb.ControlApiController.note/2`) resolve it: a ticket
  with no record, or one whose record has no issue id, is `{:error, :not_found}`. A store that can't
  be read lists no record, so its tickets read as unknown.
  """
  @spec ticket(String.t(), String.t()) :: {:ok, TicketState.t()} | {:error, :not_found}
  def ticket(repo_key, issue_identifier) do
    repo_key
    |> RunStore.list_ticket_states()
    |> List.wrap()
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.find(&(&1.issue_identifier == issue_identifier and is_binary(&1.issue_id)))
    |> case do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp query_opts(params) do
    with {:ok, types} <- types(params["types"]),
         {:ok, since} <- since(params["since"]),
         {:ok, limit} <- limit(params["limit"]) do
      {:ok, [types: types, since: since, run_id: blank_to_nil(params["run_id"]), limit: limit] |> Enum.reject(&is_nil(elem(&1, 1)))}
    end
  end

  defp types(value) when value in [nil, ""], do: {:ok, nil}

  defp types(value) when is_binary(value) do
    types = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case Enum.reject(types, &Map.has_key?(Types.catalog(), &1)) do
      [] -> {:ok, types}
      unknown -> {:error, {:invalid, "Unknown event type(s): #{Enum.join(unknown, ", ")}"}}
    end
  end

  defp types(_value), do: {:error, {:invalid, "types must be a comma-separated list"}}

  defp since(value) when value in [nil, ""], do: {:ok, nil}

  defp since(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, since, _offset} -> {:ok, since}
      {:error, _reason} -> {:error, {:invalid, "since must be an ISO 8601 timestamp"}}
    end
  end

  defp since(_value), do: {:error, {:invalid, "since must be an ISO 8601 timestamp"}}

  defp limit(value) when value in [nil, ""], do: {:ok, nil}

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> {:ok, limit}
      _invalid -> {:error, {:invalid, "limit must be a positive integer"}}
    end
  end

  defp limit(_value), do: {:error, {:invalid, "limit must be a positive integer"}}

  defp group(value) when value in [nil, ""], do: {:ok, nil}
  defp group("run"), do: {:ok, :run}
  defp group(_value), do: {:error, {:invalid, "group must be run"}}

  defp page_json(record, events, nil), do: %{events: Presenter.ticket_events_json(record.repo_key, record.issue_id, events)}

  # A store error on the history read raises, as the page's own read does.
  defp page_json(record, events, :run) do
    history = RunStore.list_ticket_events(record.repo_key, record.issue_id, types: @run_header_types)
    %{timeline: Presenter.ticket_timeline_json(record.repo_key, record.issue_id, events, history)}
  end

  defp next_since([], since), do: since && DateTime.to_iso8601(since)
  defp next_since(events, _since), do: events |> List.last() |> Map.fetch!(:at) |> DateTime.to_iso8601()

  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp blank_to_nil(_value), do: nil

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
