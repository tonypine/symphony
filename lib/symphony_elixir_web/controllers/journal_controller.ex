defmodule SymphonyElixirWeb.JournalController do
  @moduledoc """
  The events across every ticket, newest first: the Journal's read
  (`SymphonyElixir.TicketEvents.Journal`).

      GET /api/v1/events?since=&until=&repo=&epic=&classes=&notable=&limit=

  answers `{"events": [...], "next_until": iso8601 | null}`: each event in the ticket feed's shape
  (`SymphonyElixirWeb.Presenter.ticket_events_json/3`) with its `ticket` (`repo_key`, `identifier`,
  `title`; null fields for Symphony's own stream), its `class`, whether it is `notable` and who did
  it (`by`: `{kind, name}`, `kind` one of `symphony`, `rule`, `person`, `run`). `next_until` is the
  `at` the next, older page passes as `until` (exclusive); null on the last page.

  `notable` is `true` (the default: the notable events only, `SymphonyElixir.TicketEvents.Notable`)
  or `false` (every event). `classes` is a comma-separated list of `Journal.classes/0`. A `since` or
  `until` that is not ISO 8601, an unknown class, a `notable` that is neither `true` nor `false` or a
  `limit` that is not a positive integer is 400. Like the other reads of `/api/v1`, it needs no token.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.TicketEvents.Journal
  alias SymphonyElixirWeb.Presenter

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    with {:ok, opts} <- query_opts(params),
         {:ok, %{entries: entries, next_until: next_until}} <- Journal.read(opts) do
      json(conn, %{events: Enum.map(entries, &entry_json/1), next_until: next_until && DateTime.to_iso8601(next_until)})
    else
      # A store error raises, as the ticket feed's does.
      {:error, {:invalid, message}} -> error_response(conn, 400, "invalid_query", message)
    end
  end

  defp entry_json(%{event: event} = entry) do
    [json] = Presenter.ticket_events_json(event.repo_key, event.issue_id, [event])
    Map.merge(json, %{ticket: entry.ticket, class: entry.class, notable: entry.notable, by: entry.by})
  end

  defp query_opts(params) do
    with {:ok, since} <- time(params["since"], "since"),
         {:ok, until} <- time(params["until"], "until"),
         {:ok, classes} <- classes(params["classes"]),
         {:ok, notable} <- notable(params["notable"]),
         {:ok, limit} <- limit(params["limit"]) do
      {:ok, [since: since, until: until, repo: blank_to_nil(params["repo"]), epic: blank_to_nil(params["epic"]), classes: classes, notable: notable, limit: limit]}
    end
  end

  defp time(value, _name) when value in [nil, ""], do: {:ok, nil}

  defp time(value, name) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> {:error, {:invalid, "#{name} must be an ISO 8601 timestamp"}}
    end
  end

  defp time(_value, name), do: {:error, {:invalid, "#{name} must be an ISO 8601 timestamp"}}

  defp classes(value) when value in [nil, ""], do: {:ok, nil}

  defp classes(value) when is_binary(value) do
    classes = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case Enum.reject(classes, &(&1 in Journal.classes())) do
      [] -> {:ok, classes}
      unknown -> {:error, {:invalid, "Unknown class(es): #{Enum.join(unknown, ", ")}"}}
    end
  end

  defp classes(_value), do: {:error, {:invalid, "classes must be a comma-separated list"}}

  defp notable(value) when value in [nil, "", "true"], do: {:ok, true}
  defp notable("false"), do: {:ok, false}
  defp notable(_value), do: {:error, {:invalid, "notable must be true or false"}}

  defp limit(value) when value in [nil, ""], do: {:ok, nil}

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> {:ok, limit}
      _invalid -> {:error, {:invalid, "limit must be a positive integer"}}
    end
  end

  defp limit(_value), do: {:error, {:invalid, "limit must be a positive integer"}}

  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp blank_to_nil(_value), do: nil

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
