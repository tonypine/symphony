defmodule SymphonyElixirWeb.TicketEventsController do
  @moduledoc """
  The read-only feed of a ticket's events (`SymphonyElixir.TicketEvents`), the debug API through
  which the event stream is visible:

      GET /api/v1/repos/:repo_key/tickets/:issue_identifier/events?since=&types=&run_id=&limit=

  answers `{"events": [...], "next_since": iso8601}`: the events oldest first, each with its
  summary, and the `at` of the last one returned, which the next page passes as `since` (exclusive).
  A page never ends inside a group of events that share one `at`, so paging returns every event
  once. `types` is a comma-separated list of catalog types (`SymphonyElixir.TicketEvents.Types`),
  `run_id` keeps one run's events, and `limit` defaults to 50 and is capped at 200.

  The identifier resolves through the ticket's record (`SymphonyElixir.TicketState`): a ticket
  with none is 404. An unknown type, a `since` that is not an ISO 8601 timestamp or a `limit` that
  is not a positive integer is 400. Like the other reads of `/api/v1`, it needs no token.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{RunStore, TicketEvents, TicketState}
  alias SymphonyElixir.TicketEvents.{Event, Types}

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, %{"repo_key" => repo_key, "issue_identifier" => issue_identifier} = params) do
    with {:ok, record} <- ticket(repo_key, issue_identifier),
         {:ok, opts} <- query_opts(params),
         events when is_list(events) <- TicketEvents.query(record.repo_key, record.issue_id, opts) do
      json(conn, %{events: Enum.map(events, &event_json/1), next_since: next_since(events, opts[:since])})
    else
      # A store error that is neither raises, as any read of a store that failed does.
      {:error, :not_found} -> error_response(conn, 404, "ticket_not_found", "No ticket #{issue_identifier} in #{repo_key}")
      {:error, {:invalid, message}} -> error_response(conn, 400, "invalid_query", message)
    end
  end

  # A store that can't be read lists no record, so its tickets read as unknown.
  defp ticket(repo_key, issue_identifier) do
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

  defp next_since([], since), do: since && DateTime.to_iso8601(since)
  defp next_since(events, _since), do: events |> List.last() |> Map.fetch!(:at) |> DateTime.to_iso8601()

  defp event_json(%Event{} = event) do
    %{
      id: event.id,
      seq: event.seq,
      at: event.at && DateTime.to_iso8601(event.at),
      type: event.type,
      phase: event.phase,
      actor: event.actor,
      run_id: event.run_id,
      head_sha: event.head_sha,
      parent: event.parent,
      supersedes: event.supersedes,
      idempotency: event.idempotency,
      payload: event.payload,
      summary: event.summary,
      artifacts: event.artifacts
    }
  end

  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp blank_to_nil(_value), do: nil

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
