defmodule SymphonyElixir.OrchestratorEpicLanesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  @waiting "Waiting on sub-tickets"

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "In Review", "Merging", "Rework", @waiting],
      tracker_terminal_states: ["Done", "Canceled"]
    )

    :ok
  end

  test "a standalone ticket takes the shared slot while the epic's lane waits for its next part" do
    part_1 = %{id: "p1", identifier: "MT-11", state: "In Review"}
    part_2 = %Issue{id: "p2", identifier: "MT-12", title: "Part 2", state: "Todo", blocked_by: [part_1]}
    standalone = %Issue{id: "s1", identifier: "MT-20", title: "Standalone", state: "Todo"}
    other = %Issue{id: "s2", identifier: "MT-21", title: "Other", state: "Todo"}
    epic = epic("e1", "MT-10", [part_1, %{id: "p2", identifier: "MT-12", state: "Todo"}])

    state = Orchestrator.put_epic_lanes_for_test(orchestrator_state(2), [epic, part_2, standalone, other])

    assert [%{identifier: "MT-10"}] = state.epic_lanes.lanes
    assert Orchestrator.should_dispatch_issue_for_test(standalone, state)
    # Part 2 is still blocked by part 1, which is in review.
    refute Orchestrator.should_dispatch_issue_for_test(part_2, state)

    state = run(state, standalone)
    # A second standalone ticket cannot take the reserved lane.
    refute Orchestrator.should_dispatch_issue_for_test(other, state)

    # Part 1 merges; part 2 starts in the lane straight away.
    merged = epic("e1", "MT-10", [%{part_1 | state: "Done"}, %{id: "p2", identifier: "MT-12", state: "Todo"}])
    part_2 = %{part_2 | blocked_by: [%{part_1 | state: "Done"}]}
    state = Orchestrator.put_epic_lanes_for_test(state, [merged, part_2, standalone, other])

    assert Orchestrator.should_dispatch_issue_for_test(part_2, state)
  end

  test "three active epics take every slot of max_total 3 and a fourth epic waits" do
    epics = for n <- 1..4, do: epic("e#{n}", "MT-#{n}0", [%{id: "p#{n}", identifier: "MT-#{n}1", state: "Todo"}])
    parts = for n <- 1..4, do: %Issue{id: "p#{n}", identifier: "MT-#{n}1", title: "Part", state: "Todo"}
    standalone = %Issue{id: "s1", identifier: "MT-90", title: "Standalone", state: "Todo"}

    state = Orchestrator.put_epic_lanes_for_test(orchestrator_state(3), epics ++ parts ++ [standalone])

    assert Enum.map(state.epic_lanes.lanes, & &1.identifier) == ["MT-10", "MT-20", "MT-30"]
    assert [%{identifier: "MT-40"}] = state.epic_lanes.queued
    assert state.epic_lanes.shared == 0
    refute Orchestrator.should_dispatch_issue_for_test(standalone, state)
    refute Orchestrator.should_dispatch_issue_for_test(Enum.at(parts, 3), state)
    assert Orchestrator.should_dispatch_issue_for_test(Enum.at(parts, 0), state)
  end

  test "epic_lanes 1 with max_total 3 leaves two shared slots" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", @waiting],
      tracker_terminal_states: ["Done", "Canceled"],
      max_concurrent_agents: 3,
      epic_lanes: 1
    )

    assert Config.settings!().agent.epic_lanes == 1

    epics = for n <- 1..2, do: epic("e#{n}", "MT-#{n}0", [%{id: "p#{n}", identifier: "MT-#{n}1", state: "Todo"}])
    state = Orchestrator.put_epic_lanes_for_test(%{orchestrator_state(3) | max_concurrent_agents: nil}, epics)

    assert [%{identifier: "MT-10"}] = state.epic_lanes.lanes
    assert state.epic_lanes.shared == 2
  end

  test "epic_lanes must sit between 0 and max_total" do
    for {epic_lanes, max_total} <- [{-1, 3}, {4, 3}] do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: max_total, epic_lanes: epic_lanes)
      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "epic_lanes"
    end

    changeset = Schema.Agent.changeset(%Schema.Agent{}, %{"kind" => "codex", "command" => "codex", "max_concurrent_agents" => 0, "epic_lanes" => -1})
    assert {"must be greater than or equal to %{number}", _} = changeset.errors[:epic_lanes]
  end

  test "the snapshot shows each lane and the shared pool" do
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :Snapshot))
    on_exit(fn -> if Process.alive?(pid), do: stop_process(pid) end)

    part = %Issue{id: "p1", identifier: "MT-11", title: "Part 1", state: "In Progress"}
    epic = epic("e1", "MT-10", [%{id: "p1", identifier: "MT-11", state: "In Progress"}])

    :sys.replace_state(pid, fn state ->
      state
      |> Orchestrator.put_epic_lanes_for_test([epic])
      |> run(part)
    end)

    snapshot = Orchestrator.snapshot(pid, 1_000)

    assert %{lanes: [%{identifier: "MT-10", status: "running", sub_issue: %{identifier: "MT-11", state: "In Progress"}}], shared: %{used: 0}} =
             snapshot.epic_lanes
  end

  defp epic(id, identifier, sub_issues) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Epic #{identifier}",
      state: @waiting,
      labels: ["breakdown"],
      priority: 2,
      sub_issues: Enum.map(sub_issues, &Map.take(&1, [:id, :identifier, :state]))
    }
  end

  defp run(state, %Issue{} = issue) do
    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    %{state | running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)}
  end

  defp orchestrator_state(max_total) do
    %Orchestrator.State{
      max_concurrent_agents: max_total,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
