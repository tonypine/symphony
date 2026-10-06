defmodule SymphonyElixir.McpServer do
  @moduledoc false

  use GenServer

  require Logger

  alias SymphonyElixir.AuditLog
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.DependencyGate

  @server_name "symphony"
  @protocol_version "2025-06-18"
  @auth_header "symphony-session-token"
  @header_separator "\r\n\r\n"
  @managed_socket_prefix "symphony-mcp-"
  @socket_root_probe_prefix ".symphony-mcp-probe-"
  # macOS `sun_path` is 104 bytes including the trailing NUL (Linux allows 108).
  @max_socket_path_bytes 103
  @shim_prefix "symphony-mcp-shim-"
  @orphaned_socket_dir_grace_seconds 5
  # How long one of Symphony's own tools (`linear_*`, `github_*`) may run before the call returns
  # an error. A connection serves one request at a time, so a call that never ends would hold
  # every later call on it, the ones its client gave up on included.
  @default_tool_timeout_ms 600_000

  @type session :: %{
          id: String.t(),
          transport: :unix | :tcp,
          socket_path: Path.t() | nil,
          socket_dir: Path.t() | nil,
          remote_socket_path: Path.t() | nil,
          tcp_host: String.t() | nil,
          tcp_port: pos_integer() | nil,
          token: String.t(),
          shim_path: Path.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec start_session(map(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(context, opts \\ []) when is_map(context) do
    with {:ok, server} <- ensure_server(opts) do
      GenServer.call(server, {:start_session, context, opts})
    end
  end

  @doc false
  @spec remote_socket_path(String.t()) :: Path.t()
  def remote_socket_path(id) when is_binary(id) do
    Path.join("/tmp", "symphony-mcp-#{id}.sock")
  end

  @spec stop_session(session() | nil) :: :ok
  def stop_session(session), do: stop_session(session, [])

  @spec stop_session(session() | nil, keyword()) :: :ok
  def stop_session(nil, _opts), do: :ok

  def stop_session(%{id: id}, opts) when is_binary(id) do
    case server_pid(opts) do
      nil -> :ok
      server -> GenServer.call(server, {:stop_session, id})
    end
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec tool_specs() :: [map()]
  def tool_specs, do: DynamicTool.tool_specs()

  @impl true
  def init(opts) do
    default_socket_root = default_socket_root(opts)
    socket_root = resolved_socket_root(default_socket_root: default_socket_root)
    Logger.info("MCP socket root=#{socket_root}")
    reap_orphaned_socket_dirs(socket_root)

    {:ok, %{sessions: %{}, tokens: %{}, acceptors: %{}, default_socket_root: default_socket_root}}
  end

  @impl true
  def handle_call({:start_session, context, opts}, _from, state) do
    id = token()
    opts = Keyword.put(opts, :default_socket_root, state.default_socket_root)

    case open_and_secure_socket(opts, id) do
      {:ok, socket_dir, socket_path, listen_socket, endpoint} ->
        session_token = token()
        server = self()
        {acceptor_pid, acceptor_ref} = spawn_acceptor(server, listen_socket)
        remote_socket_path = compute_remote_socket_path(id, opts, endpoint)

        session = %{
          context: context,
          transport: endpoint.transport,
          socket_dir: socket_dir,
          socket_path: socket_path,
          listen_socket: listen_socket,
          acceptor: acceptor_pid,
          acceptor_ref: acceptor_ref,
          connections: MapSet.new()
        }

        reply = %{
          id: id,
          transport: endpoint.transport,
          socket_dir: socket_dir,
          socket_path: socket_path,
          remote_socket_path: remote_socket_path,
          tcp_host: Map.get(endpoint, :tcp_host),
          tcp_port: Map.get(endpoint, :tcp_port),
          token: session_token,
          shim_path: shim_path(opts)
        }

        {:reply, {:ok, reply},
         %{
           state
           | sessions: Map.put(state.sessions, id, session),
             tokens: Map.put(state.tokens, session_token, id),
             acceptors: Map.put(state.acceptors, acceptor_ref, id)
         }}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_session, id}, _from, state) do
    {:reply, :ok, cleanup_session(state, id)}
  end

  # The token stays valid for the lifetime of the session, not single-use.
  # Claude legitimately reconnects to the MCP server within a single agent run
  # (e.g., after idle, or for parallel tool calls). `cleanup_session/2` removes
  # the token when the session is explicitly stopped.
  def handle_call({:claim, token}, _from, state) do
    case Map.fetch(state.tokens, token) do
      {:ok, id} ->
        session = Map.fetch!(state.sessions, id)
        {:reply, {:ok, id, session.context, session.transport}, state}

      :error ->
        {:reply, {:error, :invalid_session_token}, state}
    end
  end

  @impl true
  def handle_cast({:connection_started, id, pid}, state) when is_binary(id) and is_pid(pid) do
    case Map.fetch(state.sessions, id) do
      {:ok, session} ->
        Process.monitor(pid)
        session = %{session | connections: MapSet.put(session.connections, pid)}
        {:noreply, %{state | sessions: Map.put(state.sessions, id, session)}}

      # The session was stopped between this connection's claim and this cast
      # (e.g. a review agent's session stopping while its shim reconnects).
      # Crashing here would restart the server and drop every other live
      # session's socket, so close the stale connection instead.
      :error ->
        Process.exit(pid, :shutdown)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.fetch(state.acceptors, ref) do
      {:ok, session_id} ->
        Logger.warning("MCP acceptor process exited session=#{session_id} reason=#{inspect(reason)}; cleaning up")

        state = %{state | acceptors: Map.delete(state.acceptors, ref)}
        {:noreply, cleanup_session(state, session_id)}

      :error ->
        sessions =
          Map.new(state.sessions, fn {id, session} ->
            {id, %{session | connections: MapSet.delete(session.connections, pid)}}
          end)

        {:noreply, %{state | sessions: sessions}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.keys(state.sessions), &cleanup_session(state, &1))
    :ok
  end

  defp ensure_server(opts) do
    case server_pid(opts) do
      nil -> start_link(name: Keyword.get(opts, :server, __MODULE__))
      pid -> {:ok, pid}
    end
  end

  defp server_pid(opts) do
    opts
    |> Keyword.get(:server, __MODULE__)
    |> Process.whereis()
  end

  defp session_socket_paths(opts, id) do
    case Keyword.get(opts, :socket_path) do
      path when is_binary(path) and path != "" ->
        {:ok, Path.dirname(path), path}

      _ ->
        root = resolved_socket_root(opts)

        with {:error, _too_long} <- managed_socket_paths(root, id),
             {:error, path} <- managed_socket_paths(root, short_socket_id(id)) do
          {:error, {:mcp_socket_path_too_long, path}}
        end
    end
  end

  defp managed_socket_paths(root, id) do
    dir = Path.join(root, "#{@managed_socket_prefix}#{id}")
    path = Path.join(dir, "sock")

    if byte_size(path) <= @max_socket_path_bytes, do: {:ok, dir, path}, else: {:error, path}
  end

  # A long root (macOS `/var/folders/...` TMPDIR) leaves no room for the full
  # 43-byte session id, so name the dir after a short hash of it instead.
  defp short_socket_id(id) do
    :sha256
    |> :crypto.hash(id)
    |> binary_part(0, 6)
    |> Base.encode16(case: :lower)
  end

  defp resolved_socket_root(opts) do
    with nil <- opt_socket_root(opts),
         nil <- system_env_socket_root(),
         nil <- app_env_socket_root() do
      Keyword.fetch!(opts, :default_socket_root)
    end
  end

  # Sandboxed agent runs (Claude Code, SRT) deny writes to `/tmp` itself but
  # allow their own TMPDIR, so use the first candidate a dir can be made in.
  defp default_socket_root(opts) do
    candidates = Keyword.get_lazy(opts, :default_socket_roots, fn -> ["/tmp", System.tmp_dir!()] end)
    Enum.find(candidates, List.last(candidates), &writable_dir?/1)
  end

  defp writable_dir?(root) do
    probe = Path.join(root, "#{@socket_root_probe_prefix}#{System.pid()}-#{System.unique_integer([:positive])}")

    case File.mkdir(probe) do
      :ok ->
        _ = File.rmdir(probe)
        true

      {:error, _reason} ->
        false
    end
  end

  defp opt_socket_root(opts) do
    case Keyword.get(opts, :socket_root) do
      root when is_binary(root) and root != "" -> root
      _ -> nil
    end
  end

  defp system_env_socket_root do
    case System.get_env("SYMPHONY_MCP_SOCKET_ROOT") do
      root when is_binary(root) and root != "" -> root
      _ -> nil
    end
  end

  defp app_env_socket_root do
    case Application.get_env(:symphony_elixir, :mcp_socket_root) do
      root when is_binary(root) and root != "" -> root
      _ -> nil
    end
  end

  defp prepare_socket_dir(dir) when is_binary(dir) do
    if managed_socket_dir?(dir) do
      _ = File.rm_rf(dir)

      with :ok <- File.mkdir_p(dir),
           :ok <- File.chmod(dir, 0o700) do
        :ok
      else
        {:error, reason} -> {:error, {:mcp_socket_dir_failed, dir, reason}}
      end
    else
      case File.mkdir_p(dir) do
        :ok -> :ok
        {:error, reason} -> {:error, {:mcp_socket_dir_failed, dir, reason}}
      end
    end
  end

  defp open_and_secure_socket(opts, id) do
    case Keyword.get(opts, :transport, :unix) do
      :tcp -> open_tcp_listen_socket()
      _transport -> open_unix_listen_socket_with_fallback(opts, id)
    end
  end

  defp open_unix_listen_socket_with_fallback(opts, id) do
    case open_unix_listen_socket(opts, id) do
      {:error, {:mcp_socket_open_failed, :eperm} = reason} = error ->
        maybe_fallback_to_tcp(error, reason, opts, id)

      result ->
        result
    end
  end

  defp maybe_fallback_to_tcp(error, reason, opts, id) do
    if managed_socket_session?(opts), do: fallback_to_tcp(reason, opts, id), else: error
  end

  defp fallback_to_tcp(reason, opts, id) do
    cleanup_failed_managed_socket_dir(opts, id)
    Logger.warning("MCP Unix socket bind denied; falling back to loopback TCP transport reason=#{inspect(reason)}")

    case open_tcp_listen_socket() do
      {:ok, _socket_dir, _socket_path, _listen_socket, _endpoint} = result ->
        result

      {:error, tcp_reason} ->
        {:error, {:mcp_socket_tcp_fallback_failed, reason, tcp_reason}}
    end
  end

  defp open_unix_listen_socket(opts, id) do
    with {:ok, socket_dir, socket_path} <- session_socket_paths(opts, id),
         :ok <- prepare_socket_dir(socket_dir),
         {:ok, listen_socket} <- open_listen_socket(socket_path, opts) do
      case File.chmod(socket_path, 0o600) do
        :ok ->
          {:ok, socket_dir, socket_path, listen_socket, %{transport: :unix}}

        {:error, reason} ->
          tear_down_socket(socket_dir, socket_path, listen_socket)
          {:error, {:mcp_socket_chmod_failed, reason}}
      end
    end
  end

  defp open_tcp_listen_socket do
    case :socket.open(:inet, :stream) do
      {:ok, socket} ->
        case bind_tcp_listen_socket(socket) do
          {:ok, port} ->
            {:ok, nil, nil, socket, %{transport: :tcp, tcp_host: "127.0.0.1", tcp_port: port}}

          {:error, reason} ->
            close_socket(socket)
            {:error, {:mcp_tcp_socket_open_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:mcp_tcp_socket_open_failed, reason}}
    end
  end

  defp bind_tcp_listen_socket(socket) do
    with :ok <- :socket.bind(socket, %{family: :inet, addr: {127, 0, 0, 1}, port: 0}),
         :ok <- :socket.listen(socket),
         {:ok, %{port: port}} <- :socket.sockname(socket) do
      {:ok, port}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp open_listen_socket(path) do
    with {:ok, socket} <- :socket.open(:local, :stream),
         :ok <- :socket.bind(socket, %{family: :local, path: path}),
         :ok <- :socket.listen(socket) do
      {:ok, socket}
    else
      {:error, reason} -> {:error, {:mcp_socket_open_failed, reason}}
    end
  end

  defp open_listen_socket(path, opts) do
    case Keyword.get(opts, :unix_socket_open_fun) do
      fun when is_function(fun, 1) -> fun.(path)
      _other -> open_listen_socket(path)
    end
  end

  defp managed_socket_session?(opts) do
    case Keyword.get(opts, :socket_path) do
      path when is_binary(path) and path != "" -> false
      _other -> true
    end
  end

  defp cleanup_failed_managed_socket_dir(opts, id) do
    {:ok, socket_dir, _socket_path} = session_socket_paths(opts, id)
    remove_socket_dir(socket_dir)
  end

  defp tear_down_socket(socket_dir, socket_path, listen_socket) do
    close_socket(listen_socket)
    _ = remove_socket_file(socket_path)
    remove_socket_dir(socket_dir)
  end

  defp remove_socket_file(nil), do: :ok

  defp remove_socket_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:mcp_socket_remove_failed, path, reason}}
    end
  end

  defp remove_socket_dir(dir) when is_binary(dir) do
    if managed_socket_dir?(dir) do
      _ = File.rm_rf(dir)
    end

    :ok
  end

  defp remove_socket_dir(_dir), do: :ok

  defp managed_socket_dir?(dir) do
    String.starts_with?(Path.basename(dir), @managed_socket_prefix)
  end

  # Reap under the effective root so orphans left behind with a configured
  # `SYMPHONY_MCP_SOCKET_ROOT`, `:mcp_socket_root` or a fallback root are
  # cleaned up too.
  defp reap_orphaned_socket_dirs(socket_root) do
    socket_root
    |> Path.join("#{@managed_socket_prefix}*")
    |> Path.wildcard()
    |> Enum.each(&reap_orphaned_socket_dir/1)
  end

  defp reap_orphaned_socket_dir(path) do
    cond do
      String.starts_with?(Path.basename(path), @shim_prefix) ->
        :ok

      File.dir?(path) and orphaned_socket_dir?(path) ->
        _ = File.rm_rf(path)
        :ok

      true ->
        :ok
    end
  end

  defp orphaned_socket_dir?(dir) do
    socket_path = Path.join(dir, "sock")

    case File.lstat(socket_path) do
      {:ok, %{type: :regular}} -> true
      {:ok, _stat} -> socket_liveness(socket_path) == :stale
      {:error, :enoent} -> managed_socket_dir_old_enough?(dir)
      {:error, _reason} -> false
    end
  end

  defp managed_socket_dir_old_enough?(dir) do
    case File.stat(dir, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.system_time(:second) - mtime >= @orphaned_socket_dir_grace_seconds
      {:error, _reason} -> false
    end
  end

  defp socket_liveness(path) do
    case :socket.open(:local, :stream) do
      {:ok, socket} ->
        try do
          case :socket.connect(socket, %{family: :local, path: path}) do
            :ok -> :accepting
            {:error, reason} when reason in [:enoent, :econnrefused, :eprototype, :einval] -> :stale
            {:error, _reason} -> :unknown
          end
        after
          close_socket(socket)
        end

      {:error, _reason} ->
        :unknown
    end
  end

  defp compute_remote_socket_path(_id, _opts, %{transport: :tcp}), do: nil

  defp compute_remote_socket_path(id, opts, _endpoint) do
    case Keyword.get(opts, :worker_host) do
      worker when is_binary(worker) and worker != "" ->
        case Keyword.get(opts, :remote_socket_path) do
          path when is_binary(path) and path != "" -> path
          _ -> remote_socket_path(id)
        end

      _ ->
        nil
    end
  end

  defp spawn_acceptor(server, listen_socket) do
    {:ok, pid} = Task.start(fn -> accept_loop(server, listen_socket) end)
    ref = Process.monitor(pid)
    {pid, ref}
  end

  defp shim_path(opts) do
    case Keyword.get(opts, :shim_path) do
      path when is_binary(path) and path != "" -> path
      _ -> resolved_shim_path()
    end
  end

  # `Application.app_dir/2` returns a path inside the loaded app. In escript
  # mode that path is virtual and the surrounding archive contains only `ebin/`
  # — `priv/` is dropped by `mix escript.build`. Embed the shim contents into
  # this BEAM at compile time via `@external_resource` so the bytes ride along
  # in the escript, and write them out to a stable temp file on first use.
  @shim_relative_path "priv/bin/symphony-mcp-shim"
  @shim_source_path Path.join([__DIR__, "..", "..", @shim_relative_path])
  @external_resource @shim_source_path
  @shim_contents File.read!(@shim_source_path)
  @shim_extract_cache_key {__MODULE__, :extracted_shim_path}

  defp resolved_shim_path do
    app_dir_path = Application.app_dir(:symphony_elixir, @shim_relative_path)

    if File.exists?(app_dir_path) do
      app_dir_path
    else
      ensure_extracted_shim_path()
    end
  end

  defp ensure_extracted_shim_path do
    case :persistent_term.get(@shim_extract_cache_key, nil) do
      path when is_binary(path) ->
        if File.exists?(path), do: path, else: extract_shim_to_disk()

      nil ->
        extract_shim_to_disk()
    end
  end

  defp extract_shim_to_disk do
    vsn = Application.spec(:symphony_elixir, :vsn) |> to_string()
    target = Path.join(System.tmp_dir!(), "symphony-mcp-shim-#{vsn}")

    File.write!(target, @shim_contents)
    File.chmod!(target, 0o755)
    :persistent_term.put(@shim_extract_cache_key, target)
    target
  end

  defp cleanup_session(state, id) do
    case Map.fetch(state.sessions, id) do
      {:ok, session} ->
        Process.demonitor(session.acceptor_ref, [:flush])
        close_socket(session.listen_socket)
        Process.exit(session.acceptor, :shutdown)
        Enum.each(session.connections, &Process.exit(&1, :shutdown))
        _ = remove_socket_file(session.socket_path)
        remove_socket_dir(session.socket_dir)

        tokens =
          state.tokens
          |> Enum.reject(fn {_token, session_id} -> session_id == id end)
          |> Map.new()

        acceptors = Map.delete(state.acceptors, session.acceptor_ref)

        %{state | sessions: Map.delete(state.sessions, id), tokens: tokens, acceptors: acceptors}

      :error ->
        state
    end
  end

  defp close_socket(socket) do
    :socket.close(socket)
  catch
    :error, _reason -> :ok
  end

  defp accept_loop(server, listen_socket) do
    case :socket.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> authenticate_and_serve(server, socket) end)
        accept_loop(server, listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.debug("MCP accept loop stopped: #{inspect(reason)}")
        :ok
    end
  end

  defp authenticate_and_serve(server, socket) do
    authenticate_connection(server, socket)
  rescue
    error ->
      Logger.error("MCP connection crashed #{format_exception_fields(:error, error, __STACKTRACE__)}")
      :ok
  catch
    kind, reason ->
      Logger.error("MCP connection exited #{format_exception_fields(kind, reason, __STACKTRACE__)}")

      :ok
  after
    close_socket(socket)
  end

  defp authenticate_connection(server, socket) do
    with {:ok, token, buffer} <- read_auth(socket, ""),
         {:ok, id, context, transport} <- GenServer.call(server, {:claim, token}) do
      GenServer.cast(server, {:connection_started, id, self()})
      serve(socket, context, buffer, %{session_id: id, transport: transport})
    else
      {:error, reason} ->
        Logger.debug("MCP connection rejected: #{inspect(reason)}")
        :ok
    end
  end

  defp read_auth(socket, buffer) do
    case String.split(buffer, @header_separator, parts: 2) do
      [headers, rest] ->
        parse_auth_headers(headers, rest)

      [_incomplete] ->
        case :socket.recv(socket) do
          {:ok, data} -> read_auth(socket, buffer <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_auth_headers(headers, rest) do
    case header_value(headers, @auth_header) do
      token when is_binary(token) and token != "" -> {:ok, token, rest}
      _ -> {:error, :missing_session_token}
    end
  end

  defp serve(socket, context, buffer, connection_meta) do
    case read_message(socket, buffer) do
      {:ok, payload, rest, message_meta} ->
        request_meta = request_meta(payload, Map.merge(connection_meta, message_meta))

        case safe_handle_payload(payload, context, request_meta, {socket, rest}) do
          {response, rest} ->
            maybe_send_response(response, socket, request_meta, send_fun(context))
            serve(socket, context, rest, connection_meta)

          :closed ->
            :ok
        end

      {:error, {:json_decode_failed, line, rest, reason}} ->
        request_meta = parse_error_meta(line, connection_meta)

        Logger.error(
          "MCP JSON decode failed #{format_request_meta(request_meta)} " <>
            "reason=#{Exception.message(reason)} raw_preview=#{redacted_preview(line)}"
        )

        line
        |> parse_error_response()
        |> maybe_send_response(socket, request_meta, send_fun(context))

        serve(socket, context, rest, connection_meta)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.debug("MCP connection recv stopped #{format_request_meta(connection_meta)} reason=#{inspect(reason)}")
        :ok
    end
  end

  # The per-connection serve loop runs in a bare `spawn/1` (see `accept_loop/2`),
  # so an unhandled exception in `handle_payload/3` would silently kill the
  # connection — the client sees "MCP error -32000: Connection closed" with no
  # trace in the symphony log. Catch and log so the real cause is recoverable
  # and the connection survives.
  #
  # Returns the response with the bytes read past the request (a tool call reads the connection
  # while it runs), or `:closed` when the client closed the connection during a tool call.
  defp safe_handle_payload(payload, context, request_meta, {_socket, buffer} = connection) do
    dispatch_payload(payload, context, request_meta, connection)
  catch
    kind, reason -> {handler_failure(kind, reason, __STACKTRACE__, payload, request_meta), buffer}
  end

  defp dispatch_payload(%{"id" => id, "method" => "tools/call", "params" => params} = payload, context, request_meta, connection) do
    tool = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    case run_tool(tool, arguments, context, request_meta, connection) do
      {{:ok, result}, buffer} ->
        {tool_response(id, Map.get(result, "output", ""), Map.get(result, "success") != true), buffer}

      {{:timeout, timeout_ms}, buffer} ->
        {tool_response(id, tool_timeout_output(tool, timeout_ms), true), buffer}

      {{:raised, kind, reason, stacktrace}, buffer} ->
        {handler_failure(kind, reason, stacktrace, payload, request_meta), buffer}

      # MCP: the receiver of a cancel does not answer the cancelled request.
      {:cancelled, buffer} ->
        {nil, buffer}

      :closed ->
        :closed
    end
  end

  defp dispatch_payload(payload, context, request_meta, {_socket, buffer}) do
    {handle_payload(payload, context, request_meta), buffer}
  end

  defp handler_failure(:error, reason, stacktrace, payload, request_meta) do
    error = Exception.normalize(:error, reason, stacktrace)

    Logger.error(
      "MCP handler crashed #{format_request_meta(request_meta)} " <>
        format_exception_fields(:error, error, stacktrace)
    )

    crash_response(payload, error)
  end

  defp handler_failure(kind, reason, stacktrace, payload, request_meta) do
    Logger.error(
      "MCP handler exited #{format_request_meta(request_meta)} " <>
        format_exception_fields(kind, reason, stacktrace)
    )

    crash_response(payload, {kind, reason})
  end

  defp mcp_tool_name(%{"params" => %{"name" => name}}) when is_binary(name), do: name
  defp mcp_tool_name(_payload), do: nil

  defp crash_response(%{"id" => id}, error) when not is_nil(id) do
    error_response(id, -32_603, "Internal MCP handler error: #{inspect(error)}")
  end

  defp crash_response(_payload, _error), do: nil

  defp read_message(socket, buffer) do
    case parse_message(buffer) do
      {:ok, payload, rest, message_meta} ->
        {:ok, payload, rest, message_meta}

      {:error, _reason} = error ->
        error

      :more ->
        case :socket.recv(socket) do
          {:ok, data} -> read_message(socket, buffer <> data)
          {:error, reason} -> parse_trailing_message(buffer, reason)
        end
    end
  end

  defp parse_trailing_message(buffer, reason) do
    case String.trim(buffer) do
      "" -> {:error, reason}
      json -> parse_line(json, "")
    end
  end

  # MCP stdio transport is newline-delimited JSON, per the MCP spec. The shim
  # forwards each line from Claude's stdin straight to the socket, so we read
  # one line at a time. Skip blank/whitespace-only lines (e.g., a stray `\r`
  # left between messages).
  defp parse_message(buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        parse_line(String.trim(line), rest)

      [_incomplete] ->
        :more
    end
  end

  defp parse_line("", rest), do: parse_message(rest)

  defp parse_line(json, rest) do
    case Jason.decode(json) do
      {:ok, payload} -> {:ok, payload, rest, %{payload_bytes: byte_size(json)}}
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:json_decode_failed, json, rest, reason}}
    end
  end

  defp header_value(headers, header_name) do
    headers
    |> String.split("\r\n", trim: true)
    |> Enum.find_value(&matching_header_value(&1, header_name))
  end

  defp matching_header_value(header, header_name) do
    case String.split(header, ":", parts: 2) do
      [key, value] ->
        if String.downcase(String.trim(key)) == header_name do
          String.trim(value)
        end

      _ ->
        nil
    end
  end

  defp handle_payload(%{"id" => id, "method" => "initialize"} = payload, _context, _request_meta) do
    protocol_version = get_in(payload, ["params", "protocolVersion"]) || @protocol_version

    response(id, %{
      "protocolVersion" => protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => @server_name, "version" => "0.1.0"}
    })
  end

  defp handle_payload(%{"method" => "notifications/" <> _rest}, _context, _request_meta), do: nil

  defp handle_payload(%{"id" => id, "method" => "tools/list"}, context, _request_meta) do
    response(id, %{"tools" => tool_specs_for_context(context)})
  end

  defp handle_payload(%{"id" => id, "method" => method}, _context, _request_meta) do
    error_response(id, -32_601, "Unsupported MCP method: #{method}")
  end

  defp handle_payload(_payload, _context, _request_meta), do: nil

  # The tool runs in a task killed at the timeout (see `tool_timeout_ms/2`), or as soon as its
  # client cancels the call or closes the connection (see `await_tool_task/2`).
  defp run_tool(tool, arguments, context, request_meta, connection) do
    timeout_ms = tool_timeout_ms(tool, context)
    call_id = notify_tool_call_started(context, tool, timeout_ms)

    try do
      run_tool_task(tool, arguments, context, request_meta, timeout_ms, connection)
    after
      notify_tool_call(context, {:finished, call_id})
    end
  end

  # The run's agent shows no activity while it waits on one of Symphony's own tools, so the
  # session's `:on_tool_call` notice tells the orchestrator when a call starts and ends: it shows
  # the call in its snapshot and holds the no-progress watchdog until the call's deadline.
  defp notify_tool_call_started(context, tool, timeout_ms) do
    call_id = make_ref()
    started_at = DateTime.utc_now()
    deadline = if is_integer(timeout_ms), do: DateTime.add(started_at, timeout_ms, :millisecond)

    notify_tool_call(context, {:started, call_id, %{name: tool, started_at: started_at, deadline: deadline}})
    call_id
  end

  defp notify_tool_call(%{on_tool_call: notify}, event) when is_function(notify, 1), do: notify.(event)
  defp notify_tool_call(_context, _event), do: :ok

  defp run_tool_task(tool, arguments, context, request_meta, timeout_ms, {socket, buffer}) do
    task =
      Task.async(fn ->
        try do
          {:ok, execute_tool(tool, arguments, context)}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end
      end)

    call = %{
      task: task,
      socket: socket,
      request_meta: request_meta,
      timeout_ms: timeout_ms,
      deadline: tool_deadline(timeout_ms)
    }

    await_tool_task(call, buffer)
  end

  # A connection serves one request at a time, so while the tool runs nothing else reads the
  # socket: read it here, so a client that gives up on the call frees the connection at once
  # instead of after the call's timeout. A `notifications/cancelled` for the call, or the socket
  # closing, stops the task. Whatever else arrives stays in the buffer for the serve loop, the
  # cancel included, where it is a no-op like any cancel of a call that already finished.
  defp await_tool_task(call, buffer) do
    if cancel_requested?(buffer, call.request_meta.request_id) do
      stop_tool_task(call, "client_cancelled")
      {:cancelled, buffer}
    else
      case :socket.recv(call.socket, 0, :nowait) do
        {:ok, data} ->
          await_tool_task(call, buffer <> data)

        {:select, select_info} ->
          await_tool_event(call, buffer, select_info)

        {:error, _reason} ->
          stop_tool_task(call, "connection_closed")
          :closed
      end
    end
  end

  defp await_tool_event(%{task: %Task{ref: ref} = task, socket: socket} = call, buffer, {:select_info, _tag, handle} = select_info) do
    receive do
      {^ref, outcome} ->
        Task.ignore(task)
        :socket.cancel(socket, select_info)
        {outcome, buffer}

      {:"$socket", ^socket, :select, ^handle} ->
        await_tool_task(call, buffer)
    after
      remaining_ms(call.deadline) ->
        :socket.cancel(socket, select_info)
        {:ok, outcome} = Task.shutdown(task, :brutal_kill) || {:ok, tool_timed_out(call)}
        {outcome, buffer}
    end
  end

  defp tool_timed_out(%{request_meta: request_meta, timeout_ms: timeout_ms}) do
    Logger.error("MCP tool call timed out #{format_request_meta(request_meta)} timeout_ms=#{timeout_ms}; stopped it")
    {:timeout, timeout_ms}
  end

  defp stop_tool_task(%{task: task, request_meta: request_meta}, reason) do
    Task.shutdown(task, :brutal_kill)
    Logger.info("MCP tool call stopped #{format_request_meta(request_meta)} reason=#{reason}")
  end

  # The complete lines read so far hold a `notifications/cancelled` for the request.
  defp cancel_requested?(buffer, request_id) do
    buffer
    |> String.split("\n")
    |> Enum.drop(-1)
    |> Enum.any?(&cancels_request?(&1, request_id))
  end

  defp cancels_request?(line, request_id) do
    match?({:ok, %{"method" => "notifications/cancelled", "params" => %{"requestId" => ^request_id}}}, Jason.decode(line))
  end

  defp tool_deadline(:infinity), do: :infinity
  defp tool_deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp remaining_ms(:infinity), do: :infinity
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # QA tools keep the timeouts their drivers set: a `qa_build` runs as long as its playbook allows.
  defp tool_timeout_ms("qa_" <> _rest, _context), do: :infinity

  defp tool_timeout_ms(_tool, context) do
    Map.get_lazy(context, :mcp_tool_timeout_ms, fn ->
      Application.get_env(:symphony_elixir, :mcp_tool_timeout_ms, @default_tool_timeout_ms)
    end)
  end

  defp tool_timeout_output(tool, timeout_ms) do
    Jason.encode!(
      %{
        "error" => %{
          "code" => "tool_timeout",
          "message" => "#{tool} did not finish within #{timeout_ms} ms, so Symphony stopped it. Calling it again starts it afresh."
        }
      },
      pretty: true
    )
  end

  defp tool_response(id, text, error?) do
    response(id, %{"content" => [%{"type" => "text", "text" => text}], "isError" => error?})
  end

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp maybe_send_response(nil, _socket, _request_meta, _send_fun), do: :ok

  defp maybe_send_response(payload, socket, request_meta, send_fun) do
    body = Jason.encode!(payload)
    data = body <> "\n"

    case send_fun.(socket, data) do
      :ok ->
        :ok

      {:error, reason} ->
        log_send_failure(request_meta, byte_size(data), reason)
        {:error, reason}

      other ->
        log_send_failure(request_meta, byte_size(data), {:unexpected_send_result, other})
        {:error, other}
    end
  rescue
    error ->
      log_send_failure(request_meta, 0, error)
      {:error, error}
  catch
    kind, reason ->
      log_send_failure(request_meta, 0, {kind, reason})
      {:error, reason}
  end

  defp request_meta(payload, base_meta) do
    base_meta
    |> Map.put(:method, payload_field(payload, "method"))
    |> Map.put(:tool, mcp_tool_name(payload))
    |> Map.put(:request_id, payload_field(payload, "id"))
  end

  defp parse_error_meta(line, base_meta) do
    base_meta
    |> Map.put(:method, raw_string_field(line, "method"))
    |> Map.put(:tool, raw_string_field(line, "name"))
    |> Map.put(:request_id, raw_id_field(line))
    |> Map.put(:payload_bytes, byte_size(line))
  end

  defp payload_field(payload, field) when is_map(payload), do: Map.get(payload, field)
  defp payload_field(_payload, _field), do: nil

  defp parse_error_response(line) do
    case raw_id_field(line) do
      nil ->
        nil

      id ->
        error_response(
          id,
          -32_700,
          "MCP JSON parse error; the tool was not run. Check request framing/body and retry with valid newline-delimited JSON."
        )
    end
  end

  defp raw_id_field(line) do
    with [_, raw_value] <- Regex.run(~r/"id"\s*:\s*("(?:\\.|[^"])*"|-?\d+|null)/, line),
         {:ok, id} <- Jason.decode(raw_value),
         false <- is_nil(id) do
      id
    else
      _ -> nil
    end
  end

  defp raw_string_field(line, field) do
    pattern = Regex.compile!(~s/"#{Regex.escape(field)}"\\s*:\\s*("(?:\\\\.|[^"])*")/)

    with [_, raw_value] <- Regex.run(pattern, line),
         {:ok, value} when is_binary(value) <- Jason.decode(raw_value) do
      value
    else
      _ -> nil
    end
  end

  defp format_request_meta(meta) do
    [
      method: Map.get(meta, :method),
      tool: Map.get(meta, :tool),
      request_id: Map.get(meta, :request_id),
      session_id: Map.get(meta, :session_id),
      payload_bytes: Map.get(meta, :payload_bytes),
      transport: Map.get(meta, :transport)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)
  end

  defp format_exception_fields(kind, reason, stacktrace) do
    [
      exception_kind: kind,
      exception: exception_name(kind, reason),
      exception_message: exception_message(kind, reason),
      stacktrace_preview: stacktrace_preview(stacktrace)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)
  end

  defp exception_name(:error, reason) do
    :error
    |> Exception.normalize(reason)
    |> Map.fetch!(:__struct__)
    |> Module.split()
    |> Enum.join(".")
  end

  defp exception_name(kind, _reason), do: inspect(kind)

  defp exception_message(:error, reason) do
    :error
    |> Exception.normalize(reason)
    |> Exception.message()
    |> single_line_preview(500)
  end

  defp exception_message(_kind, reason), do: reason |> inspect() |> single_line_preview(500)

  defp stacktrace_preview(stacktrace) do
    stacktrace
    |> Exception.format_stacktrace()
    |> single_line_preview(1_000)
  end

  defp single_line_preview(value, limit) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, limit)
  end

  defp redacted_preview(line) do
    AuditLog.redact_for_log(line, printable_limit: 240)
  end

  defp send_fun(context) do
    case Map.get(context, :mcp_send_fun) do
      fun when is_function(fun, 2) -> fun
      _other -> &:socket.send/2
    end
  end

  defp log_send_failure(request_meta, response_bytes, reason) do
    Logger.error(
      "MCP response send failed #{format_request_meta(request_meta)} " <>
        "response_bytes=#{response_bytes} reason=#{inspect(reason)}"
    )
  end

  defp tool_opts(context) do
    context
    |> Map.get(:tool_opts, [])
    |> Keyword.merge(
      issue: Map.get(context, :issue),
      issue_id: Map.get(context, :issue_id),
      workspace: Map.get(context, :workspace),
      command_security: Map.get(context, :command_security) || %{},
      comment_registry: Map.get(context, :comment_registry),
      tool_scope: Map.get(context, :tool_scope)
    )
  end

  defp tool_specs_for_context(%{tool_scope: scope}), do: DynamicTool.tool_specs(scope)
  defp tool_specs_for_context(_context), do: tool_specs()

  defp execute_tool(tool, arguments, context) do
    case DependencyGate.evaluate_pr_create_tool(tool, Map.get(context, :dependency_gate)) do
      :allow ->
        DynamicTool.execute(tool, arguments, tool_opts(context))

      {:hold, items, failure} ->
        DependencyGate.react_to_hold(Map.fetch!(context, :dependency_gate), items)
        failure

      {:audit_error, reason, failure} ->
        Logger.error("Dependency audit failed during MCP github_create_pull_request: #{inspect(reason)}")

        DependencyGate.react_to_audit_error(Map.fetch!(context, :dependency_gate), reason)
        failure
    end
  end

  defp token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
