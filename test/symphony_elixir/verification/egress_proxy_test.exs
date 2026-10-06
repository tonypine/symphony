defmodule SymphonyElixir.Verification.EgressProxyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Verification.EgressProxy

  test "tunnels a CONNECT to an allowed host both ways, and closes the tunnel with the client" do
    {upstream_port, upstream} = start_echo_server()
    proxy = start_supervised!({EgressProxy, allowed_domains: ["LocalHost"]})
    client = connect(proxy)

    :ok = :gen_tcp.send(client, "CONNECT localhost:#{upstream_port} HTTP/1.1\r\nHost: localhost\r\n\r\nhello")
    assert recv_exactly(client, byte_size(established())) == established()
    assert recv_exactly(client, 5) == "hello"

    :ok = :gen_tcp.send(client, "again")
    assert recv_exactly(client, 5) == "again"

    :gen_tcp.close(client)
    assert_receive {:upstream_closed, ^upstream}, 1_000
  end

  test "closes the tunnel when the upstream host closes it" do
    {upstream_port, upstream} = start_echo_server()
    proxy = start_supervised!({EgressProxy, allowed_domains: ["localhost"]})
    client = connect(proxy)

    :ok = :gen_tcp.send(client, "CONNECT localhost:#{upstream_port} HTTP/1.1\r\n\r\n")
    assert recv_exactly(client, byte_size(established())) == established()

    send(upstream, :close)
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)
  end

  test "closes an idle tunnel" do
    {upstream_port, _upstream} = start_echo_server()
    proxy = start_supervised!({EgressProxy, allowed_domains: ["localhost"], idle_timeout_ms: 50})
    client = connect(proxy)

    :ok = :gen_tcp.send(client, "CONNECT localhost:#{upstream_port} HTTP/1.1\r\n\r\n")
    assert recv_exactly(client, byte_size(established())) == established()
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)
  end

  test "refuses a host outside the allowlist with a 403" do
    {upstream_port, _upstream} = start_echo_server()
    proxy = start_supervised!({EgressProxy, allowed_domains: ["registry.npmjs.org"], run_id: "run-403"})

    log =
      capture_log(fn ->
        assert request(proxy, "CONNECT localhost:#{upstream_port} HTTP/1.1\r\n\r\n") =~ "HTTP/1.1 403 Forbidden: localhost is not on"
      end)

    assert log =~ "proxy refused host=localhost port=#{upstream_port} run_id=run-403"
  end

  test "refuses any method but CONNECT" do
    proxy = start_supervised!({EgressProxy, allowed_domains: ["example.com"]})

    assert request(proxy, "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n") =~
             "HTTP/1.1 403 Forbidden: only CONNECT"
  end

  test "answers a CONNECT without a port with a 400" do
    proxy = start_supervised!({EgressProxy, allowed_domains: ["example.com"]})

    assert request(proxy, "CONNECT example.com HTTP/1.1\r\n\r\n") =~ "HTTP/1.1 400 Bad Request"
  end

  test "answers with a 502 when the allowed host can't be reached" do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, closed_port} = :inet.port(listen)
    :gen_tcp.close(listen)
    proxy = start_supervised!({EgressProxy, allowed_domains: ["localhost"]})

    assert request(proxy, "CONNECT localhost:#{closed_port} HTTP/1.1\r\n\r\n") =~ "HTTP/1.1 502 Bad Gateway"
  end

  test "drops a client whose request head never ends or is too long" do
    proxy = start_supervised!({EgressProxy, allowed_domains: ["localhost"]})

    client = connect(proxy)
    :ok = :gen_tcp.send(client, "CONNECT " <> String.duplicate("a", 20_000))
    assert {:error, reason} = :gen_tcp.recv(client, 0, 1_000)
    assert reason in [:closed, :econnreset]

    client = connect(proxy)
    :ok = :gen_tcp.send(client, "CONNECT localhost:1 HTTP/1.1\r\n")
    :ok = :gen_tcp.shutdown(client, :write)
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)
  end

  test "stops listening when stopped" do
    {:ok, proxy} = EgressProxy.start_link(allowed_domains: [])
    port = EgressProxy.port(proxy)

    assert :ok = EgressProxy.stop(proxy)
    assert :ok = EgressProxy.stop(proxy)
    assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary])
  end

  test "closes an established tunnel when stopped" do
    {upstream_port, upstream} = start_echo_server()
    {:ok, proxy} = EgressProxy.start_link(allowed_domains: ["localhost"])
    client = connect(proxy)

    :ok = :gen_tcp.send(client, "CONNECT localhost:#{upstream_port} HTTP/1.1\r\n\r\nhello")
    assert recv_exactly(client, byte_size(established())) == established()
    assert recv_exactly(client, 5) == "hello"

    assert :ok = EgressProxy.stop(proxy)
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)
    assert_receive {:upstream_closed, ^upstream}, 1_000
  end

  test "does not start when it can't listen" do
    Process.flag(:trap_exit, true)
    listen = fn 0, _options -> {:error, :emfile} end

    assert {:error, :emfile} = EgressProxy.start_link(allowed_domains: [], listen: listen)
  end

  test "goes down when it can't accept a connection" do
    Process.flag(:trap_exit, true)
    test = self()

    accept = fn _listen ->
      send(test, {:accepting, self()})

      receive do
        :fail -> {:error, :emfile}
      end
    end

    {:ok, proxy} = EgressProxy.start_link(allowed_domains: [], accept: accept)
    assert_receive {:accepting, acceptor}
    send(acceptor, :fail)

    assert_receive {:EXIT, ^proxy, {:egress_proxy_accept_failed, :emfile}}, 1_000
  end

  test "matches hosts by name and by wildcard subdomain" do
    allowed = ["hex.pm", "*.githubusercontent.com"]

    assert EgressProxy.allowed_host?("hex.pm", allowed)
    assert EgressProxy.allowed_host?("HEX.PM.", allowed)
    assert EgressProxy.allowed_host?("raw.githubusercontent.com", allowed)
    refute EgressProxy.allowed_host?("githubusercontent.com", allowed)
    refute EgressProxy.allowed_host?("repo.hex.pm", allowed)
    refute EgressProxy.allowed_host?("evilhex.pm", allowed)
  end

  defp established, do: "HTTP/1.1 200 Connection Established\r\n\r\n"

  defp connect(proxy) do
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", EgressProxy.port(proxy), [:binary, active: false])
    client
  end

  defp request(proxy, head) do
    client = connect(proxy)
    :ok = :gen_tcp.send(client, head)
    response = read_all(client, "")
    :gen_tcp.close(client)
    response
  end

  defp read_all(client, acc) do
    case :gen_tcp.recv(client, 0, 1_000) do
      {:ok, data} -> read_all(client, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp recv_exactly(client, bytes) do
    {:ok, data} = :gen_tcp.recv(client, bytes, 1_000)
    data
  end

  # An echo server on loopback for one connection. It tells the test when the proxy closes
  # its side, and closes it itself on `:close`.
  defp start_echo_server do
    test = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        :ok = :inet.setopts(socket, active: true)
        echo(socket, test)
      end)

    :ok = :gen_tcp.controlling_process(listen, pid)
    {port, pid}
  end

  defp echo(socket, test) do
    receive do
      {:tcp, ^socket, data} ->
        :gen_tcp.send(socket, data)
        echo(socket, test)

      {:tcp_closed, ^socket} ->
        send(test, {:upstream_closed, self()})

      :close ->
        :gen_tcp.close(socket)
    end
  end
end
