defmodule SymphonyElixir.TicketEvents.RunEndsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TicketEvents
  alias SymphonyElixir.TicketEvents.RunEnds

  @repo_key "repo-a"
  @issue_id "issue-run-ends"
  @other_issue "issue-run-ends-other"
  @at ~U[2026-11-12 09:38:40.000000Z]

  setup do
    :ok = RunStore.clear()
  end

  describe "open/1" do
    test "names the runs started and never ended, each ended at the ticket's next run start, else its own last step, else its start" do
      events = [
        event(@issue_id, 0, "run.started", started("run-1", "implementation", 1)),
        event(@issue_id, 20, "step.completed", step("run-1")),
        event(@issue_id, 22, "run.started", started("run-2", "implementation", 2)),
        event(@issue_id, 25, "run.ended", %{run_id: "run-2", exit: "handoff"}),
        event(@issue_id, 30, "run.started", started("run-3", "rework", 1)),
        event(@issue_id, 33, "step.completed", step("run-3"))
      ]

      assert [{%{payload: %{run_id: "run-1"}}, run_1_end}, {%{payload: %{run_id: "run-3"}}, run_3_end}] = RunEnds.open(events)
      assert run_1_end == minutes(22)
      assert run_3_end == minutes(33)

      only_started = [event(@issue_id, 40, "run.started", started("run-4", "code_review", 1))]
      assert [{%{payload: %{run_id: "run-4"}}, run_4_end}] = RunEnds.open(only_started)
      assert run_4_end == minutes(40)
      assert "step.completed" in RunEnds.activity_types()
    end
  end

  describe "close_unended/1" do
    test "the update's quit: a run Symphony held when it quit gets its end, once, at the next run's start or its last step" do
      # Implementation run 1 waited between turns for an update; Symphony quit to install it, and the
      # boot dispatched Implementation run 2. Rework run 5 waited the same way on another ticket, and
      # no run came after it.
      record!(@issue_id, 0, "run.started", Map.merge(started("run-1", "implementation", 1), %{model: "claude-opus-5-5", effort: "high"}))
      record!(@issue_id, 22, "run.started", started("run-2", "implementation", 2))
      record!(@issue_id, 25, "run.ended", %{run_id: "run-2", exit: "handoff", unpushed_head: String.duplicate("a", 40)})
      record!(@other_issue, 5, "run.started", started("run-5", "rework", 5))
      record!(@other_issue, 12, "step.completed", step("run-5"))

      log = capture_log(fn -> assert RunEnds.close_unended() == 2 end)
      assert log =~ "Closed 2 run(s) that ended without a recorded end"

      assert [run_1_end, run_2_end] = TicketEvents.query(@issue_id, types: ["run.ended"])
      assert run_1_end.at == minutes(22)
      assert run_1_end.run_id == "run-1"

      assert %{
               run_id: "run-1",
               run_kind: "implementation",
               run_number: 1,
               model: "claude-opus-5-5",
               effort: "high",
               exit: "ended; no end was recorded",
               duration_ms: 1_320_000,
               counted: false
             } = run_1_end.payload

      assert run_2_end.payload.exit == "handoff"

      assert [%{at: run_5_end, payload: %{run_id: "run-5", exit: "ended; no end was recorded", duration_ms: 420_000}}] =
               TicketEvents.query(@other_issue, types: ["run.ended"])

      assert run_5_end == minutes(12)

      # The next boot finds nothing left to close.
      assert RunEnds.close_unended() == 0
      assert length(TicketEvents.query(@issue_id, types: ["run.ended"])) == 2
    end

    test "a store that can't be read closes none" do
      unreadable = fn _opts -> {:error, :unavailable} end
      log = capture_log(fn -> assert RunEnds.close_unended(read: unreadable) == 0 end)
      assert log =~ "Failed to read the runs that ended without a recorded end"
    end
  end

  describe "close_at_boot/1" do
    test "closes the runs left open unless the setting turns it off" do
      record!(@issue_id, 0, "run.started", started("run-1", "qa", 1))

      assert RunEnds.close_at_boot(enabled: false) == 0
      assert RunEnds.close_at_boot() == 0
      assert TicketEvents.query(@issue_id, types: ["run.ended"]) == []

      capture_log(fn -> assert RunEnds.close_at_boot(enabled: true) == 1 end)
      assert [%{payload: %{run_id: "run-1", exit: "ended; no end was recorded"}}] = TicketEvents.query(@issue_id, types: ["run.ended"])
    end
  end

  test "end_payload/2 never reads a negative duration" do
    started = event(@issue_id, 10, "run.started", started("run-1", "qa", 1))
    assert %{duration_ms: 0, exit: "ended; no end was recorded"} = RunEnds.end_payload(started, @at)
    assert RunEnds.unrecorded_exit() == "ended; no end was recorded"
  end

  defp started(run_id, run_kind, run_number), do: %{run_id: run_id, run_kind: run_kind, run_number: run_number}

  defp step(run_id), do: %{run_id: run_id, step_id: "code", title: "Write the code", mode: "delegated", outcome: "passed"}

  defp minutes(minute), do: DateTime.add(@at, minute * 60)

  defp event(issue_id, minute, type, payload) do
    {payload, opts} = split(type, payload, minute)
    {:ok, event} = TicketEvents.build(@repo_key, issue_id, type, payload, opts)
    event
  end

  defp record!(issue_id, minute, type, payload) do
    {payload, opts} = split(type, payload, minute)
    {:ok, event} = TicketEvents.record(@repo_key, issue_id, type, payload, opts)
    event
  end

  # A step's run id is its agent's, not its payload's.
  defp split("step." <> _rest, payload, minute),
    do: {Map.delete(payload, :run_id), actor: {:agent, payload.run_id, "implementation"}, at: minutes(minute)}

  defp split(_type, payload, minute), do: {payload, run_id: payload.run_id, at: minutes(minute)}
end
