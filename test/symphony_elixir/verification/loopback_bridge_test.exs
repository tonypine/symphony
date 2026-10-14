defmodule SymphonyElixir.Verification.LoopbackBridgeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Verification.LoopbackBridge

  setup do
    root = Path.join(System.tmp_dir!(), "loopback-bridge-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, socket: Path.join(root, "serve.sock"), port: free_port()}
  end

  @tag :unix_socket
  test "copies a loopback connection to the unix socket and back", %{socket: socket, port: port} do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, socket}])
    # `:temporary`, so the test supervisor does not restart the bridge after the stop below and
    # re-listen on the port, which would make the `econnrefused` assertion race the restart.
    bridge = start_supervised!({LoopbackBridge, port: port, socket: socket}, restart: :temporary)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listen, 5_000)

    :ok = :gen_tcp.send(client, "GET / HTTP/1.1\r\n\r\n")
    assert {:ok, "GET / HTTP/1.1\r\n\r\n"} = :gen_tcp.recv(server, 0, 5_000)
    :ok = :gen_tcp.send(server, "HTTP/1.1 200 OK\r\n\r\n")
    assert {:ok, "HTTP/1.1 200 OK\r\n\r\n"} = :gen_tcp.recv(client, 0, 5_000)

    # The dev server closing its side closes the client's.
    :gen_tcp.close(server)
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 5_000)

    # Stopping the bridge closes the connections it still carries.
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    {:ok, _server} = :gen_tcp.accept(listen, 5_000)
    :ok = LoopbackBridge.stop(bridge)
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 5_000)
    assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [])
  end

  test "closes a connection while nothing listens on the socket", %{socket: socket, port: port} do
    start_supervised!({LoopbackBridge, port: port, socket: socket})

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 5_000)
  end

  test "listens on 127.0.0.1 only", %{socket: socket, port: port} do
    test = self()

    listen = fn listen_port, options ->
      send(test, {:listen, listen_port, options})
      :gen_tcp.listen(listen_port, options)
    end

    start_supervised!({LoopbackBridge, port: port, socket: socket, listen: listen})

    assert_receive {:listen, ^port, options}
    assert {:ip, {127, 0, 0, 1}} in options
  end

  test "fails to start when it can't listen on the port", %{socket: socket, port: port} do
    Process.flag(:trap_exit, true)

    listen = fn _port, _options -> {:error, :eaddrinuse} end
    assert {:error, :eaddrinuse} = LoopbackBridge.start_link(port: port, socket: socket, listen: listen)
  end

  test "goes down when it can't accept, so its dev server stops", %{socket: socket, port: port} do
    Process.flag(:trap_exit, true)

    {:ok, bridge} = LoopbackBridge.start_link(port: port, socket: socket, accept: fn _listen -> {:error, :emfile} end)

    assert_receive {:EXIT, ^bridge, {:loopback_bridge_accept_failed, :emfile}}
  end

  test "stopping a bridge that is gone, or none, is fine" do
    {:ok, pid} = Agent.start(fn -> nil end)
    Agent.stop(pid)

    assert :ok = LoopbackBridge.stop(pid)
    assert :ok = LoopbackBridge.stop(nil)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
