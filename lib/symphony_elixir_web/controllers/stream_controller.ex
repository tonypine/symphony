defmodule SymphonyElixirWeb.StreamController do
  @moduledoc """
  The live channel: a server-sent events stream that tells a client the moment an event is written
  to a ticket's history (`SymphonyElixir.TicketEvents.record/5`), so the Director's app reads only
  what is new instead of polling:

      GET /api/v1/stream?repo_key=&issue_identifier=

  answers `text/event-stream` and stays open. Each notice is one message, `event: ticket`, its
  `id:` the event's id and its `data:` the notice as JSON (`repo_key`, `issue_id`,
  `issue_identifier`, `event_id`, `type`, `at`). A `: keep-alive` comment line every 15 seconds lets
  the client notice a dead connection and keeps an idle one open. `repo_key` and `issue_identifier`
  each keep only the notices that carry them; without them every ticket's notices come. When the
  client goes away a write fails, and the response ends and leaves no subscriber behind. Like the
  other reads of `/api/v1`, it needs no token.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.ObservabilityPubSub

  @keep_alive_ms 15_000

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    filter = %{repo_key: blank_to_nil(params["repo_key"]), issue_identifier: blank_to_nil(params["issue_identifier"])}
    :ok = ObservabilityPubSub.subscribe_ticket_events()
    interval = keep_alive_ms()

    conn
    |> put_resp_content_type("text/event-stream", nil)
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
    |> stream(filter, interval, schedule_keep_alive(interval))
  end

  @doc "How often an open stream sends its keep-alive line, in milliseconds: 15 seconds unless configured (tests)."
  @spec keep_alive_ms() :: pos_integer()
  def keep_alive_ms, do: Application.get_env(:symphony_elixir, :stream_keep_alive_ms, @keep_alive_ms)

  defp stream(conn, filter, interval, timer) do
    receive do
      {:ticket_event, notice} ->
        if matches?(notice, filter),
          do: write(conn, message(notice), filter, interval, timer),
          else: stream(conn, filter, interval, timer)

      {__MODULE__, :keep_alive} ->
        write(conn, ": keep-alive\n\n", filter, interval, schedule_keep_alive(interval))
    end
  end

  defp write(conn, data, filter, interval, timer) do
    case chunk(conn, data) do
      {:ok, conn} ->
        stream(conn, filter, interval, timer)

      {:error, _reason} ->
        Process.cancel_timer(timer)
        ObservabilityPubSub.unsubscribe_ticket_events()
        conn
    end
  end

  defp schedule_keep_alive(interval), do: Process.send_after(self(), {__MODULE__, :keep_alive}, interval)

  defp matches?(notice, filter) do
    Enum.all?(filter, fn {key, wanted} -> is_nil(wanted) or Map.get(notice, key) == wanted end)
  end

  defp message(notice), do: "event: ticket\nid: #{notice.event_id}\ndata: #{Jason.encode!(notice)}\n\n"

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
