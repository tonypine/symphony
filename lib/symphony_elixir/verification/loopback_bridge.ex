defmodule SymphonyElixir.Verification.LoopbackBridge do
  @moduledoc """
  Serves a sandboxed verification dev server's unix socket on `127.0.0.1:<port>`, from outside
  the sandbox.

  On macOS Seatbelt can't keep a TCP listener on loopback: a rule that lets the dev server listen
  on `localhost` also lets it listen on every address, where another host on the network reaches
  it. So its profile (`SymphonyElixir.Verification.DevServerSandbox`) allows it no TCP listener
  at all, and it listens on a unix socket in its temp folder instead. This bridge listens on the
  dev server's port on `127.0.0.1` only, and copies each connection to and from that socket, as
  `socat` does for the dev server's port on Linux.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec stop(pid() | nil) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  def stop(nil), do: :ok

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    socket = Keyword.fetch!(opts, :socket)
    accept = Keyword.get(opts, :accept, &:gen_tcp.accept/1)
    listen = Keyword.get(opts, :listen, &:gen_tcp.listen/2)

    # A listen error (`eaddrinuse`) fails the start, so the dev server that owns the bridge can clean up.
    case listen.(port, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, listen_socket} ->
        {:ok, clients} = Task.Supervisor.start_link()
        acceptor = spawn_link(fn -> accept_loop(listen_socket, accept, clients, socket) end)
        {:ok, %{listen: listen_socket, acceptor: acceptor, clients: clients}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # The connections go with the bridge, as the egress proxy's tunnels go with it.
  @impl true
  def terminate(_reason, %{listen: listen, acceptor: acceptor, clients: clients}) do
    Process.unlink(acceptor)
    :gen_tcp.close(listen)
    Supervisor.stop(clients)
  end

  # Any accept error but a closed socket (`emfile`, `system_limit`) takes the bridge down, so the
  # dev server that owns it stops instead of running where nobody reaches it.
  defp accept_loop(listen, accept, clients, socket) do
    case accept.(listen) do
      {:ok, client} ->
        {:ok, pid} =
          Task.Supervisor.start_child(
            clients,
            fn ->
              receive do
                :serve -> serve(client, socket)
              end
            end,
            shutdown: :brutal_kill
          )

        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, :serve)
        accept_loop(listen, accept, clients, socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:loopback_bridge_accept_failed, reason})
    end
  end

  # Until the dev server listens on its socket, a connection is closed at once, as a port nobody
  # listens on refuses it.
  defp serve(client, socket) do
    case :gen_tcp.connect({:local, socket}, 0, [:binary, active: :once]) do
      {:ok, upstream} ->
        :ok = :inet.setopts(client, active: :once)
        relay(client, upstream)

      {:error, _reason} ->
        :gen_tcp.close(client)
    end
  end

  # A send to a peer that went away fails quietly; its socket then reports `tcp_closed`.
  defp relay(client, upstream) do
    receive do
      {:tcp, from, data} ->
        :gen_tcp.send(if(from == client, do: upstream, else: client), data)
        :inet.setopts(from, active: :once)
        relay(client, upstream)

      _closed_or_error ->
        :gen_tcp.close(client)
        :gen_tcp.close(upstream)
    end
  end
end
