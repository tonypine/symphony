defmodule SymphonyElixir.OutboundGuardTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{OutboundConnectionInTest, OutboundGuard}

  test "is Req's default adapter in the test env" do
    assert Req.default_options()[:adapter] == OutboundGuard
    assert Req.new(url: "https://example.com").adapter == OutboundGuard
  end

  test "a request to a host other than this machine raises, naming the host and the module that made it" do
    error = assert_raise OutboundConnectionInTest, fn -> Req.get("https://example.com/path", retry: false) end

    assert %OutboundConnectionInTest{host: "example.com", caller: __MODULE__} = error

    assert Exception.message(error) ==
             "SymphonyElixir.OutboundGuardTest opened a connection to example.com in a test. Tests reach only 127.0.0.1 and localhost: " <>
               "stub the request (a `plug:` or `adapter:` option, Req.Test, or a stub server on 127.0.0.1)."
  end

  test "the Linear adapter pointed at the public Linear host fails before a connection opens" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_endpoint: "https://api.linear.app/graphql", tracker_api_token: "token")

    error = assert_raise OutboundConnectionInTest, fn -> Client.graphql("query { viewer { id } }") end

    assert %{host: "api.linear.app", caller: SymphonyElixir.Linear.Client} = error
    assert Exception.message(error) =~ "SymphonyElixir.Linear.Client opened a connection to api.linear.app in a test."
  end

  test "a request to this machine goes through Finch" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    for host <- ["127.0.0.1", "localhost"] do
      assert {:error, %Req.TransportError{reason: :econnrefused}} = Req.get("http://#{host}:#{port}/", retry: false)
    end
  end

  test "a stubbed request never reaches it" do
    assert {:ok, %{status: 204}} = Req.get("https://api.linear.app/graphql", plug: &Plug.Conn.send_resp(&1, 204, ""))
  end

  test "local? is true for this machine's names only" do
    for host <- ["127.0.0.1", "localhost", "::1", "[::1]"], do: assert(OutboundGuard.local?(host))
    for host <- ["api.linear.app", "localhost.example.com", "10.0.0.1", nil], do: refute(OutboundGuard.local?(host))
  end
end
