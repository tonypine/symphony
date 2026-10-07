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

  test "the run's registry remembers a supervisor check, and a run without one records nothing" do
    {:ok, registry} = CommentRegistry.start_link()
    refute CommentRegistry.supervisor_check?(registry)

    assert CommentRegistry.record_supervisor_check(registry) == :ok
    assert CommentRegistry.supervisor_check?(registry)

    assert CommentRegistry.record_supervisor_check(nil) == :ok
    refute CommentRegistry.supervisor_check?(nil)
  end
end
