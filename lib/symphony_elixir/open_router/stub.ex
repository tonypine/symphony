defmodule SymphonyElixir.OpenRouter.Stub do
  @moduledoc """
  A stand-in for the OpenRouter API, so QA tests OpenRouter flows without a real, paid key.

  It listens on `127.0.0.1` only and answers with canned data:

  - `GET /api/v1/key`: the key `sk-or-v1-symphony-qa-stub` is valid (a label and credit),
    any other key or none gets a 401, as OpenRouter answers an unknown key;
  - `GET /api/v1/models`: three models, one with tools and reasoning, one with tools and no
    reasoning, and one without tools;
  - `POST /api/v1/messages` (and `/messages/count_tokens`): with the valid key, a canned
    Anthropic Messages answer that names the model it was asked for, as JSON or as an SSE stream
    when the request asks for one. That is enough to show a `claude` run's env and model id
    reach OpenRouter.

  Each request is logged (method, path, model, whether the key was accepted), never the key.
  The QA driver starts one for each macOS app pass (`SymphonyElixir.QaDriver`), and
  `symphony openrouter-stub` runs one for the `cli` playbook. Symphony and the macOS app use it
  only in QA mode (see `SymphonyElixir.OpenRouter.base_url/1`).
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @valid_key "sk-or-v1-symphony-qa-stub"
  @body_limit 8_000_000

  @key_info %{
    "label" => "Symphony QA stub",
    "usage" => 1.25,
    "limit" => 10.0,
    "limit_remaining" => 8.75,
    "is_free_tier" => false
  }

  @models [
    %{
      "id" => "symphony-qa/reasoning-tools",
      "name" => "QA Stub: Reasoning and tools",
      "context_length" => 200_000,
      "supported_parameters" => ["max_tokens", "temperature", "tools", "tool_choice", "reasoning", "include_reasoning"]
    },
    %{
      "id" => "symphony-qa/tools-only",
      "name" => "QA Stub: Tools, no reasoning",
      "context_length" => 128_000,
      "supported_parameters" => ["max_tokens", "temperature", "tools", "tool_choice"]
    },
    %{
      "id" => "symphony-qa/no-tools",
      "name" => "QA Stub: No tools",
      "context_length" => 32_000,
      "supported_parameters" => ["max_tokens", "temperature"]
    }
  ]

  @type log :: (String.t() -> any())

  @doc "The one key the stub accepts. It is not a secret."
  @spec valid_key() :: String.t()
  def valid_key, do: @valid_key

  @doc "The models `GET /api/v1/models` lists, in OpenRouter's format."
  @spec models() :: [map()]
  def models, do: @models

  @doc "The base URL to export as `SYMPHONY_QA_OPENROUTER_URL` for a stub on `port`."
  @spec url(:inet.port_number()) :: String.t()
  def url(port), do: "http://127.0.0.1:#{port}/api"

  @doc """
  Starts a stub linked to the caller and returns its port. Options: `:port` (default `0`, any
  free port) and `:log` (a function given each request line, default `Logger.info/1`).
  """
  @spec start_link(keyword()) :: {:ok, pid(), :inet.port_number()} | {:error, term()}
  def start_link(opts \\ []) do
    log = Keyword.get(opts, :log, &default_log/1)

    bandit_opts = [
      plug: {__MODULE__, log: log},
      ip: {127, 0, 0, 1},
      port: Keyword.get(opts, :port, 0),
      startup_log: false,
      thousand_island_options: [num_acceptors: 2]
    ]

    with {:ok, pid} <- Bandit.start_link(bandit_opts),
         {:ok, {_ip, port}} <- ThousandIsland.listener_info(pid) do
      {:ok, pid, port}
    end
  end

  @doc "Stops a stub `start_link/1` started."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    ThousandIsland.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :log)

  @impl Plug
  def call(conn, log) do
    accepted? = valid_key?(conn)
    {conn, status, model} = route(conn, conn.method, conn.path_info, accepted?)
    model_note = if model, do: " model=#{model}", else: ""
    log.("OpenRouter stub: #{conn.method} #{conn.request_path}#{model_note} key=#{if accepted?, do: "accepted", else: "rejected"} status=#{status}")
    conn
  end

  defp route(conn, "GET", ["api", "v1", "key"], true), do: {json(conn, 200, %{"data" => @key_info}), 200, nil}
  defp route(conn, "GET", ["api", "v1", "key"], false), do: unauthorized(conn)
  defp route(conn, "GET", ["api", "v1", "models"], _accepted?), do: {json(conn, 200, %{"data" => @models}), 200, nil}
  defp route(conn, "POST", ["api", "v1", "messages" | _rest], false), do: unauthorized(conn)

  defp route(conn, "POST", ["api", "v1", "messages" | rest], true) do
    case read_json(conn) do
      {:ok, conn, request} -> answer_messages(conn, rest, request)
      :error -> {json(conn, 400, error_body(400, "The request body is not a JSON object.")), 400, nil}
    end
  end

  defp route(conn, _method, _path, _accepted?), do: {json(conn, 404, error_body(404, "Not found in the OpenRouter QA stub.")), 404, nil}

  defp answer_messages(conn, ["count_tokens"], request), do: {json(conn, 200, %{"input_tokens" => 1}), 200, model(request)}

  defp answer_messages(conn, [], request) do
    model = model(request)
    text = "The OpenRouter QA stub answered for model #{model}."

    conn =
      if request["stream"] == true do
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_resp(200, stream_body(model, text))
      else
        json(conn, 200, message(model, text))
      end

    {conn, 200, model}
  end

  defp answer_messages(conn, _rest, _request), do: {json(conn, 404, error_body(404, "Not found in the OpenRouter QA stub.")), 404, nil}

  defp model(%{"model" => model}) when is_binary(model), do: model
  defp model(_request), do: "unknown"

  defp message(model, text) do
    %{
      "id" => "msg_symphony_qa_stub",
      "type" => "message",
      "role" => "assistant",
      "model" => model,
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "stop_sequence" => nil,
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }
  end

  defp stream_body(model, text) do
    start = %{message(model, text) | "content" => [], "stop_reason" => nil, "usage" => %{"input_tokens" => 1, "output_tokens" => 0}}

    [
      {"message_start", %{"type" => "message_start", "message" => start}},
      {"content_block_start", %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}}},
      {"content_block_delta", %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => text}}},
      {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}},
      {"message_delta", %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil}, "usage" => %{"output_tokens" => 1}}},
      {"message_stop", %{"type" => "message_stop"}}
    ]
    |> Enum.map_join(fn {event, data} -> "event: #{event}\ndata: #{Jason.encode!(data)}\n\n" end)
  end

  # A body over the limit, or one that can't be read, is a bad request like invalid JSON.
  defp read_json(conn) do
    with {:ok, body, conn} <- read_body(conn, length: @body_limit),
         {:ok, %{} = request} <- Jason.decode(body) do
      {:ok, conn, request}
    else
      _unreadable -> :error
    end
  end

  # OpenRouter takes the key as a bearer token; `claude` sends it that way from
  # `ANTHROPIC_AUTH_TOKEN`, other Anthropic clients as `x-api-key`.
  defp valid_key?(conn) do
    Enum.any?(get_req_header(conn, "authorization"), &(&1 == "Bearer " <> @valid_key)) or
      Enum.any?(get_req_header(conn, "x-api-key"), &(&1 == @valid_key))
  end

  defp unauthorized(conn), do: {json(conn, 401, error_body(401, "No auth credentials found")), 401, nil}

  defp error_body(status, message), do: %{"error" => %{"code" => status, "message" => message}}

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp default_log(line), do: Logger.info(line)
end
