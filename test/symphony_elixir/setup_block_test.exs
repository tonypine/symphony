defmodule SymphonyElixir.SetupBlockTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SetupBlock

  test "a verification failure is a setup block; a failure a retry can change is not" do
    assert SetupBlock.setup_block?({:verification_failed, {:dev_server_build_failed, 127}})
    assert SetupBlock.setup_block?({:verification_failed, :health_timeout})

    refute SetupBlock.setup_block?({:workspace_hook_failed, "after_create", 3, "boom"})
    refute SetupBlock.setup_block?({:workspace_prepare_failed, "worker-01", 255, "ssh: connect refused"})
    refute SetupBlock.setup_block?(:no_ports_available)
  end

  test "the outcome carries the cause for self-heal and the cause in words" do
    cause = {:verification_failed, {:dev_server_build_failed, 127}}

    assert %{cause: ^cause, summary: summary, reason: reason} = SetupBlock.outcome(cause)
    assert summary == "verification.dev_server build failed with exit 127: a command it runs is not on the sandbox PATH"
    assert reason == "the run failed in its own setup, before the agent's first turn: " <> summary
  end

  test "describes each verification cause in words" do
    cases = [
      {{:dev_server_build_failed, 2}, "verification.dev_server build failed with exit 2"},
      {:dev_server_build_timeout, "verification.dev_server build timed out"},
      {:health_timeout, "verification.dev_server did not pass its health check in time"},
      {{:dev_server_exit, 3}, "verification.dev_server exited with status 3 before it was healthy"},
      {{:dev_server_not_on_socket, "/tmp/serve.sock"}, "verification.dev_server never listened on its unix socket /tmp/serve.sock"},
      {{:loopback_bridge_unavailable, :eaddrinuse}, "Symphony could not serve the dev server on its verification port: the port is already in use (eaddrinuse)"},
      {{:loopback_bridge_unavailable, :eacces}, "Symphony could not serve the dev server on its verification port: :eacces"},
      {:python_not_found, "verification.dev_server did not start: :python_not_found"}
    ]

    for {cause, words} <- cases do
      assert SetupBlock.describe({:verification_failed, cause}) == words
    end

    assert SetupBlock.describe(:something_else) == ":something_else"
  end
end
