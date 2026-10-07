defmodule SymphonyElixir.SupervisorCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.SupervisorCheck

  test "finds the block on its own line, alone or inside a review brief" do
    assert SupervisorCheck.heading() == "## Supervisor check"
    assert SupervisorCheck.in_body?("## Supervisor check\n\n**Verify:** no crash on `main`.")
    assert SupervisorCheck.in_body?("## Review brief\n\n...\n\n  ## Supervisor check  \n**How:** the host crash check.")

    refute SupervisorCheck.in_body?("See the `## Supervisor check` below.")
    refute SupervisorCheck.in_body?("## Supervisor checks done")
    refute SupervisorCheck.in_body?(nil)
  end

  test "the run's registry holds a supervisor check while one of its comments has the block" do
    {:ok, registry} = CommentRegistry.start_link()
    refute CommentRegistry.supervisor_check?(registry)

    assert CommentRegistry.record_supervisor_check(registry, "brief-1", true) == :ok
    assert CommentRegistry.record_supervisor_check(registry, "brief-2", true) == :ok
    assert CommentRegistry.supervisor_check?(registry)

    CommentRegistry.record_supervisor_check(registry, "brief-1", false)
    assert CommentRegistry.supervisor_check?(registry)

    CommentRegistry.remove(registry, "brief-2")
    refute CommentRegistry.supervisor_check?(registry)

    assert CommentRegistry.record_supervisor_check(nil, "brief-1", true) == :ok
    assert CommentRegistry.record_supervisor_check(registry, nil, true) == :ok
    refute CommentRegistry.supervisor_check?(registry)
    refute CommentRegistry.supervisor_check?(nil)
  end

  test "the run's registry remembers a PR it opened" do
    {:ok, registry} = CommentRegistry.start_link()
    refute CommentRegistry.pull_request_created?(registry)

    assert CommentRegistry.record_pull_request(registry) == :ok
    assert CommentRegistry.pull_request_created?(registry)

    assert CommentRegistry.record_pull_request(nil) == :ok
    refute CommentRegistry.pull_request_created?(nil)
  end
end
