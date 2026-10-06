defmodule SymphonyElixir.Verification.EgressProxy do
  @moduledoc """
  A loopback HTTP proxy through which a sandboxed verification dev server reaches its
  dependency hosts, and only them.

  The dev server's sandbox (`SymphonyElixir.Verification.DevServerSandbox`) lets it connect to
  loopback only (on Linux, its own loopback, bridged to this proxy), and its env points
  `HTTPS_PROXY` and `HTTP_PROXY` here, so Hex, npm, git and mise fetch through this proxy. It
  only tunnels `CONNECT host:port` to a host on the allowlist: a name on it, or a subdomain of a
  `*.example.com` entry. Any other host, and any other method (plain HTTP), gets a 403.
  """

  use GenServer
  require Logger

  @head_limit_bytes 16_384
  @head_timeout_ms 10_000
  @connect_timeout_ms 10_000
  @idle_timeout_ms 300_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The loopback port the proxy listens on."
  @spec port(pid()) :: :inet.port_number()
  def port(pid), do: GenServer.call(pid, :port)

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  @doc "Whether `host` is on `allowed_domains`, as a name or under a `*.` entry."
  @spec allowed_host?(String.t(), [String.t()]) :: boolean()
  def allowed_host?(host, allowed_domains) when is_binary(host) do
    host = host |> String.trim_trailing(".") |> String.downcase()

    Enum.any?(allowed_domains, fn
      "*." <> domain -> String.ends_with?(host, "." <> domain)
      domain -> host == domain
    end)
  end

  @impl true
  def init(opts) do
    config = %{
      allowed_domains: opts |> Keyword.get(:allowed_domains, []) |> Enum.map(&String.downcase/1),
      run_id: Keyword.get(opts, :run_id),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @idle_timeout_ms)
    }

    accept = Keyword.get(opts, :accept, &:gen_tcp.accept/1)
    listen = Keyword.get(opts, :listen, &:gen_tcp.listen/2)

    # A listen error (`emfile`) fails the start, so the dev server that owns the proxy can clean up.
    case listen.(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        {:ok, clients} = Task.Supervisor.start_link()
        acceptor = spawn_link(fn -> accept_loop(socket, accept, clients, config) end)
        {:ok, %{listen: socket, port: port, acceptor: acceptor, clients: clients}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  # The tunnels go with the proxy: a client that is still connected, or that left the dev
  # server's process group, loses its tunnel when the dev server stops. The acceptor ends on
  # the closed socket; unlinked, it can't take the proxy down if it loses the race with the
  # stopped supervisor.
  @impl true
  def terminate(_reason, %{listen: listen, acceptor: acceptor, clients: clients}) do
    Process.unlink(acceptor)
    :gen_tcp.close(listen)
    Supervisor.stop(clients)
  end

  # Any accept error but a closed socket (`emfile`, `system_limit`) takes the proxy down, so
  # the dev server that owns it stops instead of serving with no way out.
  defp accept_loop(listen, accept, clients, config) do
    case accept.(listen) do
      {:ok, client} ->
        {:ok, pid} =
          Task.Supervisor.start_child(
            clients,
            fn ->
              receive do
                :serve -> serve(client, config)
              end
            end,
            shutdown: :brutal_kill
          )

        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, :serve)
        accept_loop(listen, accept, clients, config)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:egress_proxy_accept_failed, reason})
    end
  end

  defp serve(client, config) do
    with {:ok, head, rest} <- read_head(client, ""),
         {:ok, host, port} <- connect_target(head, client),
         :ok <- check_allowed(host, port, client, config),
         {:ok, upstream} <- connect_upstream(host, port, client) do
      :ok = :gen_tcp.send(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
      if rest != "", do: :gen_tcp.send(upstream, rest)
      :ok = :inet.setopts(client, active: :once)
      :ok = :inet.setopts(upstream, active: :once)
      relay(client, upstream, config.idle_timeout_ms)
    else
      _refused -> :gen_tcp.close(client)
    end
  end

  defp read_head(client, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_partial] when byte_size(acc) > @head_limit_bytes ->
        :error

      [_partial] ->
        with {:ok, data} <- :gen_tcp.recv(client, 0, @head_timeout_ms), do: read_head(client, acc <> data)
    end
  end

  defp connect_target(head, client) do
    [request_line | _headers] = String.split(head, "\r\n", parts: 2)

    case String.split(request_line, " ") do
      ["CONNECT", target, "HTTP/1." <> _minor] ->
        case URI.parse("//" <> target) do
          %URI{host: host, port: port} when is_binary(host) and host != "" and is_integer(port) and port > 0 ->
            {:ok, host, port}

          _invalid ->
            reply(client, 400, "Bad Request")
        end

      _other ->
        reply(client, 403, "Forbidden: only CONNECT to an allowed host")
    end
  end

  defp check_allowed(host, port, client, config) do
    if allowed_host?(host, config.allowed_domains) do
      :ok
    else
      Logger.warning("Verification dev server proxy refused host=#{host} port=#{port} run_id=#{config.run_id}")
      reply(client, 403, "Forbidden: #{host} is not on the dev server's network allowlist")
    end
  end

  defp connect_upstream(host, port, client) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @connect_timeout_ms) do
      {:ok, upstream} -> {:ok, upstream}
      {:error, reason} -> reply(client, 502, "Bad Gateway: #{inspect(reason)}")
    end
  end

  defp reply(client, status, reason) do
    :gen_tcp.send(client, "HTTP/1.1 #{status} #{reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    {:error, status}
  end

  # A send to a peer that went away fails quietly; its socket then reports `tcp_closed`.
  defp relay(client, upstream, idle_timeout_ms) do
    receive do
      {:tcp, from, data} ->
        :gen_tcp.send(if(from == client, do: upstream, else: client), data)
        :inet.setopts(from, active: :once)
        relay(client, upstream, idle_timeout_ms)

      _closed_or_error ->
        close(client, upstream)
    after
      idle_timeout_ms -> close(client, upstream)
    end
  end

  defp close(client, upstream) do
    :gen_tcp.close(client)
    :gen_tcp.close(upstream)
  end
end
