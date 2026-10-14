defmodule SymphonyElixir.RetiredStateMachineConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{Schema, SystemSchema}

  # The keys of the retired legacy state machine load, say once that they do nothing, and are dropped.
  defp symphony(issues, repo_fields) do
    %{
      "issues" => Map.merge(%{"provider" => "memory"}, issues),
      "agent" => %{"runtime" => "claude", "command" => "claude --dangerously-skip-permissions"},
      "repositories" => [Map.merge(%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}, repo_fields)]
    }
  end

  # The warnings are logged once per distinct config, so each case parses its own config.
  defp parse(issues, repo_fields) do
    log = capture_log(fn -> send(self(), {:parsed, SystemSchema.parse(symphony(issues, repo_fields))}) end)
    assert_received {:parsed, {:ok, system}}
    {system, log}
  end

  test "a repository's state_machine loads with a deprecation warning and is dropped" do
    for version <- ["designed", "legacy"] do
      {system, log} = parse(%{}, %{"state_machine" => version})

      assert log =~ "symphony.yml `repositories[app].state_machine` is deprecated and has no effect: there is one ticket state machine"
      assert log =~ "Remove it"
      refute system |> SystemSchema.to_config_map() |> inspect() =~ "state_machine"
      assert {:ok, %Schema{}} = Schema.parse(SystemSchema.to_config_map(system))
    end
  end

  test "issues.states.human_review loads with a deprecation warning and is dropped" do
    for state <- ["Human Review", nil] do
      {system, log} = parse(%{"states" => %{"human_review" => state}}, %{})

      assert log =~ "symphony.yml `issues.states.human_review` is deprecated and has no effect: the Human Review state"
      assert log =~ "a decision request pauses the ticket on a Needs Decision hold"
      refute system |> SystemSchema.to_config_map() |> inspect() =~ "human_review"
    end
  end

  test "a config without the retired keys loads without their warnings" do
    {_system, log} = parse(%{"states" => %{"active" => ["Todo", "In Progress"]}}, %{"manual_review" => "on"})

    refute log =~ "state_machine"
    refute log =~ "human_review"
  end
end
