defmodule SymphonyElixir.QaDriver.HostStub do
  @moduledoc """
  The HTTP stub a `macos_app` QA pass serves for the app under test, answering
  with the responses the QA agent gives `qa_host_stub`.

  The agent cannot serve the app itself: its sandbox listens on the Symphony
  host's loopback only, and an app on a separate QA host (a bridged VM) cannot
  reach that, nor rely on any host address it was not told. So Symphony serves
  the agent's canned responses on `127.0.0.1`, and `SymphonyElixir.QaDriver`
  forwards the stub into each app's SSH session like the OpenRouter stub and
  gives the agent the URL the app must use.

  Routes come from a JSON file the agent wrote:

      {"routes": [
        {"method": "GET", "path": "/api/postings", "json": [{"id": 1}]},
        {"path": "/api/postings?page=2", "json": []},
        {"path": "/health", "body": "ok", "content_type": "text/plain"}
      ]}

  `method` defaults to `GET` and `status` to 200; `json` is served as
  `application/json`, `body` (a string) as `text/plain` unless `content_type`
  says otherwise. A request gets the first route with its method and path, and
  its query when the route names one; any other request gets a 404. Every request
  is recorded (method, path with query, status, whether a route matched), the
  last #{50} kept, so the agent can show what the app asked for. Routes and
  requests live in an ETS table the driver owns, so loading routes does not need
  a running stub and a restarted stub keeps them.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @max_routes 200
  @max_requests 50
  @route_keys ~w(method path status json body content_type)
  @method ~r/\A[A-Za-z]{1,16}\z/

  @type route :: %{
          method: String.t(),
          path: String.t(),
          query: String.t() | nil,
          status: 200..599,
          body: binary(),
          content_type: String.t()
        }

  @doc "A table for one pass's routes and requests, owned by the caller."
  @spec new() :: :ets.tid()
  def new do
    table = :ets.new(__MODULE__, [:ordered_set, :public])
    :ets.insert(table, {:routes, []})
    table
  end

  @doc "The stub's base URL for an app that reaches it on `port`."
  @spec url(:inet.port_number()) :: String.t()
  def url(port), do: "http://127.0.0.1:#{port}"

  @doc "Starts a stub on `127.0.0.1` serving `table`'s routes, linked to the caller, and returns its port."
  @spec start_link(:ets.tid()) :: {:ok, pid(), :inet.port_number()} | {:error, term()}
  def start_link(table) do
    bandit_opts = [
      plug: {__MODULE__, table: table},
      ip: {127, 0, 0, 1},
      port: 0,
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

  @doc """
  Replaces `table`'s routes with the ones in `json` and returns how many there
  are, or why the file was refused (a sentence that follows the file's name).
  """
  @spec load_routes(:ets.tid(), binary()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def load_routes(table, json) do
    with {:ok, routes} <- decode(json),
         {:ok, routes} <- parse_routes(routes, 1, []) do
      :ets.insert(table, {:routes, routes})
      {:ok, length(routes)}
    end
  end

  @doc "How many routes `table` serves and the requests the stub answered, oldest first."
  @spec status(:ets.tid()) :: %{String.t() => non_neg_integer() | [map()]}
  def status(table) do
    %{
      "routes" => length(:ets.lookup_element(table, :routes, 2)),
      "requests" => :ets.select(table, [{{{:request, :_}, :"$1"}, [], [:"$1"]}])
    }
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{"routes" => routes}} when is_list(routes) and length(routes) <= @max_routes -> {:ok, routes}
      {:ok, %{"routes" => routes}} when is_list(routes) -> {:error, "has #{length(routes)} routes; at most #{@max_routes}."}
      {:ok, _other} -> {:error, ~s(must be a JSON object with a "routes" list.)}
      {:error, error} -> {:error, "is not valid JSON: #{Exception.message(error)}"}
    end
  end

  defp parse_routes([], _index, parsed), do: {:ok, Enum.reverse(parsed)}

  defp parse_routes([route | rest], index, parsed) do
    case parse_route(route) do
      {:ok, route} -> parse_routes(rest, index + 1, [route | parsed])
      {:error, message} -> {:error, "has an invalid route #{index}: #{message}"}
    end
  end

  defp parse_route(%{"path" => "/" <> _rest = target} = route) do
    [path | query] = String.split(target, "?", parts: 2)

    with :ok <- known_keys(route),
         {:ok, method} <- method(Map.get(route, "method", "GET")),
         {:ok, status} <- status_code(Map.get(route, "status", 200)),
         {:ok, body, default_type} <- body(route),
         {:ok, content_type} <- content_type(Map.get(route, "content_type", default_type)) do
      {:ok, %{method: method, path: path, query: List.first(query), status: status, body: body, content_type: content_type}}
    end
  end

  defp parse_route(_route), do: {:error, ~s(it needs a "path" starting with "/".)}

  defp known_keys(route) do
    case Map.keys(route) -- @route_keys do
      [] -> :ok
      unknown -> {:error, "unknown keys #{Enum.join(unknown, ", ")}; use #{Enum.join(@route_keys, ", ")}."}
    end
  end

  defp method(method) when is_binary(method) do
    if Regex.match?(@method, method), do: {:ok, String.upcase(method)}, else: {:error, ~s("method" must be a word such as GET or POST.)}
  end

  defp method(_method), do: {:error, ~s("method" must be a word such as GET or POST.)}

  defp status_code(status) when is_integer(status) and status in 200..599, do: {:ok, status}
  defp status_code(_status), do: {:error, ~s("status" must be an integer from 200 to 599.)}

  defp body(%{"json" => _json, "body" => _body}), do: {:error, ~s(set "json" or "body", not both.)}
  defp body(%{"json" => json}), do: {:ok, Jason.encode!(json), "application/json"}
  defp body(%{"body" => body}) when is_binary(body), do: {:ok, body, "text/plain; charset=utf-8"}
  defp body(%{"body" => _body}), do: {:error, ~s("body" must be a string; serve JSON with "json".)}
  defp body(_route), do: {:ok, "", "text/plain; charset=utf-8"}

  defp content_type(type) when is_binary(type) and type != "" and byte_size(type) <= 200 do
    if String.contains?(type, ["\r", "\n"]), do: content_type_error(), else: {:ok, type}
  end

  defp content_type(_type), do: content_type_error()

  defp content_type_error, do: {:error, ~s("content_type" must be one line of at most 200 bytes.)}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    table = Keyword.fetch!(opts, :table)
    route = Enum.find(:ets.lookup_element(table, :routes, 2), &matches?(&1, conn))
    {status, conn} = respond(conn, route)
    # Record before the response goes out, so a caller that has the response finds the request too.
    record(table, conn, status, route != nil)
    send_resp(conn)
  end

  defp matches?(route, conn) do
    route.method == conn.method and route.path == conn.request_path and route.query in [nil, conn.query_string]
  end

  defp respond(conn, nil) do
    body = Jason.encode!(%{"error" => "No route in the QA host stub for #{conn.method} #{target(conn)}."})
    {404, conn |> put_resp_header("content-type", "application/json") |> resp(404, body)}
  end

  defp respond(conn, route), do: {route.status, conn |> put_resp_header("content-type", route.content_type) |> resp(route.status, route.body)}

  defp record(table, conn, status, matched?) do
    request = %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      "method" => conn.method,
      "path" => target(conn),
      "status" => status,
      "matched" => matched?
    }

    :ets.insert(table, {{:request, System.unique_integer([:monotonic, :positive])}, request})
    trim(table)
    Logger.info("QA host stub: #{conn.method} #{target(conn)} status=#{status}")
  end

  # `:routes` sorts before every `{:request, n}` key, so the request after it is the oldest.
  defp trim(table) do
    if :ets.info(table, :size) > @max_requests + 1 do
      :ets.delete(table, :ets.next(table, :routes))
      trim(table)
    end
  end

  defp target(%{query_string: ""} = conn), do: conn.request_path
  defp target(conn), do: conn.request_path <> "?" <> conn.query_string
end
