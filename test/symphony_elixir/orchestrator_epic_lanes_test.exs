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

  test "an epic whose next part waits on a review yields its lane, and takes it back once the part can run" do
    part_1 = %{id: "p1", identifier: "MT-11", state: "In Review"}
    part_2 = %Issue{id: "p2", identifier: "MT-12", title: "Part 2", state: "Todo", blocked_by: [part_1]}
    standalone = %Issue{id: "s1", identifier: "MT-20", title: "Standalone", state: "Todo"}
    other = %Issue{id: "s2", identifier: "MT-21", title: "Other", state: "Todo"}
    epic = epic("e1", "MT-10", [part_1, part_2])

    state = Orchestrator.put_epic_lanes_for_test(orchestrator_state(2), [epic, part_2, standalone, other])

    assert state.epic_lanes.lanes == []
    assert state.epic_lanes.shared == 2
    assert Orchestrator.should_dispatch_issue_for_test(standalone, state)
    # Part 2 is still blocked by part 1, which is in review.
    refute Orchestrator.should_dispatch_issue_for_test(part_2, state)

    state = run(state, standalone)
    # The slot the lane would have held goes to a second standalone ticket.
    assert Orchestrator.should_dispatch_issue_for_test(other, state)

    reason = "Nothing on its path can run: MT-11 (In Review), MT-12 (Todo, blocked by MT-11)"

    assert %{lanes: [lane], shared: %{slots: 2, used: 1}} = snapshot_of(state).epic_lanes
    assert %{identifier: "MT-10", status: "yielded", reason: ^reason, sub_issue: sub_issue} = lane

    assert %{identifier: "MT-11", state: "In Review"} = sub_issue

    # Review sends part 1 back to Todo: at the next poll the epic has its lane again, so part 1
    # starts there while the shared slot left is taken.
    part_1 = %Issue{id: "p1", identifier: "MT-11", title: "Part 1", state: "Todo"}
    part_2 = %{part_2 | blocked_by: [Map.take(part_1, [:id, :identifier, :state])]}
    candidates = [epic("e1", "MT-10", [part_1, part_2]), part_1, part_2, standalone, other]
    state = Orchestrator.put_epic_lanes_for_test(state, candidates)

    assert [%{identifier: "MT-10"}] = state.epic_lanes.lanes
    assert state.epic_lanes.yielded == []
    assert Orchestrator.should_dispatch_issue_for_test(part_1, state)
    refute Orchestrator.should_dispatch_issue_for_test(other, state)
  end

  test "the epic's lane runs the blocker of its next part, a ticket outside the epic, while the shared slot is busy" do
    # The final verification waits on a fix filed under another parent, as TP-272 waited on TP-323.
    blocker = %Issue{id: "b1", identifier: "MT-30", title: "Fix", state: "Todo"}
    other_parent = %Issue{id: "o1", identifier: "MT-29", title: "Other parent", state: "In Progress", sub_issues: [Map.take(blocker, [:id, :identifier, :state])]}
    final = %Issue{id: "p2", identifier: "MT-12", title: "Final verification", state: "Todo", blocked_by: [%{id: "b1", identifier: "MT-30", state: "Todo"}]}
    standalone = %Issue{id: "s1", identifier: "MT-20", title: "Standalone", state: "Todo"}
    epic = epic("e1", "MT-10", [%{id: "p1", identifier: "MT-11", state: "Done"}, final])

    state =
      orchestrator_state(2)
      |> Orchestrator.put_epic_lanes_for_test([epic, final, blocker, other_parent, standalone])
      |> run(standalone)

    refute Orchestrator.should_dispatch_issue_for_test(final, state)
    assert Orchestrator.should_dispatch_issue_for_test(blocker, state)

    state = run(state, blocker)
    # Dispatched once: running, it is not offered again, and it fills the lane.
    refute Orchestrator.should_dispatch_issue_for_test(blocker, state)

    assert %{lanes: [%{status: "running", sub_issue: %{identifier: "MT-30", via: via}}], shared: %{used: 1}} =
             snapshot_of(state).epic_lanes

    assert via == %{relation: "blocks", identifier: "MT-12"}
  end

  test "a grandchild of the epic runs in its lane when the shared slot is busy" do
    grandchild = %Issue{id: "g1", identifier: "MT-13", title: "Grandchild", state: "Todo"}
    part = %Issue{id: "p1", identifier: "MT-11", title: "Part", state: "In Progress", sub_issues: [%{id: "g1", identifier: "MT-13", state: "Todo"}]}
    standalone = %Issue{id: "s1", identifier: "MT-20", title: "Standalone", state: "Todo"}
    epic = epic("e1", "MT-10", [part])

    state =
      orchestrator_state(2)
      |> Orchestrator.put_epic_lanes_for_test([epic, part, grandchild, standalone])
      |> run(standalone)

    assert Orchestrator.should_dispatch_issue_for_test(grandchild, state)
  end

  test "a blocker shared by two epics runs once and holds one lane" do
    blocker = %Issue{id: "b1", identifier: "MT-30", title: "Shared fix", state: "Todo"}
    blocked_by = [%{id: "b1", identifier: "MT-30", state: "Todo"}]
    part_1 = %Issue{id: "p1", identifier: "MT-11", title: "Part", state: "Todo", blocked_by: blocked_by}
    part_2 = %Issue{id: "q1", identifier: "MT-21", title: "Part", state: "Todo", blocked_by: blocked_by}
    sibling = %Issue{id: "q2", identifier: "MT-22", title: "Sibling", state: "Todo"}
    candidates = [epic("e1", "MT-10", [part_1]), epic("e2", "MT-20", [part_2, sibling]), part_1, part_2, sibling, blocker]

    state = orchestrator_state(2) |> Orchestrator.put_epic_lanes_for_test(candidates) |> run(blocker)

    refute Orchestrator.should_dispatch_issue_for_test(blocker, state)
    # The other epic's lane is still free for its own work.
    assert Orchestrator.should_dispatch_issue_for_test(sibling, state)
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

  defp snapshot_of(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
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
