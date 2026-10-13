defmodule SymphonyElixirWeb.AuditController do
  @moduledoc """
  NDJSON API for filtered audit events, and the daily hash-chain verification.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.AuditLog

  @ndjson_content_type "application/x-ndjson"
  # The most days one verification request reads; each is a full read of that day's file.
  @max_verify_days 31

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    query_opts = audit_query_opts(params)

    case audit_stream(query_opts, params) do
      {:ok, stream, headers} ->
        conn
        |> put_resp_content_type(@ndjson_content_type)
        |> maybe_put_download_header(params)
        |> put_resp_headers(headers)
        |> stream_ndjson(stream)

      {:error, reason} ->
        error_response(conn, 400, "invalid_audit_filter", inspect(reason))
    end
  end

  @doc """
  The hash-chain verification of each day from `from` to `to` (or the one `date`; today by default):
  `verified`, or the first record that breaks the chain with its line, hash and the record itself.
  """
  @spec verify(Conn.t(), map()) :: Conn.t()
  def verify(conn, params) do
    case verify_range(params) do
      {:ok, from, to} ->
        json(conn, %{
          from: Date.to_iso8601(from),
          to: Date.to_iso8601(to),
          days: from |> Date.range(to) |> Enum.map(&verify_day/1)
        })

      {:error, reason} ->
        error_response(conn, 400, "invalid_audit_filter", inspect(reason))
    end
  end

  defp audit_stream(query_opts, params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, last} <- parse_last(Map.get(params, "last"), limit, Keyword.get(query_opts, :cursor)) do
      page_stream(query_opts, limit, last)
    end
  end

  defp page_stream(query_opts, nil, nil) do
    with {:ok, stream} <- AuditLog.query(query_opts) do
      {:ok, stream, []}
    end
  end

  defp page_stream(query_opts, limit, nil) do
    with {:ok, stream} <- AuditLog.query(Keyword.put(query_opts, :limit, limit + 1)) do
      events = Enum.to_list(stream)
      {page, overflow} = Enum.split(events, limit)
      {:ok, page, cursor_headers(page_next_cursor(page, overflow))}
    end
  end

  # The newest `last` matching events, still oldest first, keeping no more than `last` in memory.
  defp page_stream(query_opts, nil, last) do
    with {:ok, stream} <- AuditLog.query(query_opts) do
      {queue, _size, dropped?} = Enum.reduce(stream, {:queue.new(), 0, false}, &keep_newest(&1, &2, last))
      {:ok, :queue.to_list(queue), if(dropped?, do: [{"x-audit-truncated", "true"}], else: [])}
    end
  end

  defp keep_newest(event, {queue, last, _dropped?}, last), do: {:queue.drop(:queue.in(event, queue)), last, true}
  defp keep_newest(event, {queue, size, dropped?}, _last), do: {:queue.in(event, queue), size + 1, dropped?}

  defp parse_last(nil, _limit, _cursor), do: {:ok, nil}
  defp parse_last(_last, limit, cursor) when not is_nil(limit) or not is_nil(cursor), do: {:error, :last_with_page}

  defp parse_last(last, _limit, _cursor) when is_binary(last) do
    case Integer.parse(last) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_last}
    end
  end

  defp parse_last(_last, _limit, _cursor), do: {:error, :invalid_last}

  defp verify_range(params) do
    with {:ok, from} <- param_date(Map.get(params, "date") || Map.get(params, "from"), Date.utc_today()),
         {:ok, to} <- param_date(if(Map.has_key?(params, "date"), do: nil, else: Map.get(params, "to")), from) do
      cond do
        Date.compare(from, to) == :gt -> {:error, :invalid_date_range}
        Date.diff(to, from) >= @max_verify_days -> {:error, :date_range_too_long}
        true -> {:ok, from, to}
      end
    end
  end

  defp param_date(value, default) when value in [nil, ""], do: {:ok, default}

  defp param_date(value, _default) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp param_date(_value, _default), do: {:error, :invalid_date}

  defp verify_day(date) do
    day = Date.to_iso8601(date)

    case AuditLog.verify_chain(date) do
      :ok ->
        %{date: day, verified: true, broken: nil}

      {:error, {:chain_break, %{line: line, record_hash: record_hash}}} ->
        %{date: day, verified: false, broken: broken(date, line, record_hash, "chain_break")}

      {:error, {:invalid_record, line, _reason}} ->
        %{date: day, verified: false, broken: broken(date, line, nil, "invalid_record")}
    end
  end

  defp broken(date, line, record_hash, reason) do
    %{line: line, record_hash: record_hash, reason: reason, record: AuditLog.record_at(date, line)}
  end

  defp audit_query_opts(params) do
    [
      issue: Map.get(params, "issue"),
      issue_id: Map.get(params, "issue_id"),
      issue_identifier: Map.get(params, "issue_identifier"),
      repo: Map.get(params, "repo"),
      event_type: Map.get(params, "type") || Map.get(params, "event_type"),
      run_id: Map.get(params, "run_id"),
      from: Map.get(params, "from") || Map.get(params, "date_from"),
      to: Map.get(params, "to") || Map.get(params, "date_to"),
      since: Map.get(params, "since"),
      cursor: Map.get(params, "cursor")
    ]
  end

  defp parse_limit(nil), do: {:ok, nil}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_limit}
    end
  end

  defp next_cursor(event) when is_map(event) do
    date = Map.get(event, "date")
    record_hash = Map.get(event, "record_hash")

    if is_binary(date) and is_binary(record_hash), do: "#{date}:#{record_hash}", else: nil
  end

  defp page_next_cursor(_page, []), do: nil
  defp page_next_cursor(page, _overflow), do: page |> List.last() |> next_cursor()

  defp maybe_put_download_header(conn, %{"download" => value}) when value in ["1", "true", "ndjson"] do
    put_resp_header(conn, "content-disposition", ~s(attachment; filename="symphony-audit.ndjson"))
  end

  defp maybe_put_download_header(conn, _params), do: conn

  defp cursor_headers(nil), do: []
  defp cursor_headers(cursor), do: [{"x-next-cursor", cursor}]

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
  end

  defp stream_ndjson(conn, stream) do
    conn = send_chunked(conn, 200)

    Enum.reduce_while(stream, conn, fn event, conn ->
      case chunk(conn, encode_event_line(event)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  defp encode_event_line(event) do
    case Jason.encode(event) do
      {:ok, json} -> json <> "\n"
      {:error, _reason} -> ~s({"error":"unencodable_record"}\n)
    end
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
