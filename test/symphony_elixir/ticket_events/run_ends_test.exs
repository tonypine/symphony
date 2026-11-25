defmodule SymphonyElixir.TicketEvents.RunEndsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Conductor.Facts
  alias SymphonyElixir.{Lifecycle, TicketEvents}
  alias SymphonyElixir.TicketEvents.RunEnds

  @repo_key "repo-a"
  @issue_id "issue-run-ends"
  @other_issue "issue-run-ends-other"
  @at ~U[2026-11-12 09:38:40.000000Z]

  setup do
    :ok = RunStore.clear()
  end

  describe "open/2" do
    test "names the runs started and never ended, each ended at its own last step, else the ticket's next run start, else its start" do
      events = [
        event(@issue_id, 0, "run.started", started("run-1", "implementation", 1)),
        event(@issue_id, 20, "step.completed", step("run-1")),
        event(@issue_id, 22, "run.started", started("run-2", "implementation", 2)),
        event(@issue_id, 25, "run.ended", %{run_id: "run-2", exit: "handoff"}),
        event(@issue_id, 30, "run.started", started("run-3", "rework", 1)),
        event(@issue_id, 33, "step.completed", step("run-3"))
      ]

      assert [{%{payload: %{run_id: "run-1"}}, run_1_end}, {%{payload: %{run_id: "run-3"}}, run_3_end}] = RunEnds.open(events)
      assert run_1_end == minutes(20)
      assert run_3_end == minutes(33)

      only_started = [event(@issue_id, 40, "run.started", started("run-4", "code_review", 1))]
      assert [{%{payload: %{run_id: "run-4"}}, run_4_end}] = RunEnds.open(only_started)
      assert run_4_end == minutes(40)
      assert "step.completed" in RunEnds.activity_types()
    end

    test "a Conductor turn started while the run worked never gives the run's end: its own last activity does" do
      events = [
        event(@issue_id, 0, "run.started", started("run-1", "implementation", 1)),
        event(@issue_id, 5, "step.completed", step("run-1")),
        event(@issue_id, 11, "run.started", started("conductor-1", "conductor", 1)),
        event(@issue_id, 12, "run.ended", %{run_id: "conductor-1", exit: "answered"}),
        event(@issue_id, 20, "run.started", started("run-2", "rework", 1)),
        event(@issue_id, 24, "run.started", started("conductor-2", "conductor", 2)),
        event(@issue_id, 25, "run.ended", %{run_id: "conductor-2", exit: "answered"}),
        event(@issue_id, 40, "run.started", started("run-3", "qa", 1))
      ]

      # Its last step, else the last agent event its row in the run list kept, whichever is later; a
      # run with neither ends at the next run's start that is not a Conductor turn.
      assert ends(RunEnds.open(events)) == [{"run-1", 5}, {"run-2", 40}, {"run-3", 40}]
      assert ends(RunEnds.open(events, %{"run-1" => %{tokens: 10, last_event_at: minutes(16)}})) == [{"run-1", 16}, {"run-2", 40}, {"run-3", 40}]
      # A kept time before the run's last step, or before its start, never moves the end back.
      kept = %{"run-1" => %{last_event_at: minutes(3)}, "run-2" => %{last_event_at: minutes(1)}}
      assert ends(RunEnds.open(events, kept)) == [{"run-1", 5}, {"run-2", 40}, {"run-3", 40}]
    end
  end

  describe "an app update's shutdown" do
    test "a run held between turns keeps, after the next boot, the tokens Symphony last held for it and its real end" do
      # Implementation run 1 worked from minute 0, reported its tokens as it went and its last agent
      # event at minute 16, then waited between turns for the update. A Conductor turn looked in at
      # minute 11 meanwhile and spent 40 tokens.
      :ok =
        RunStore.put_run(%{
          repo_key: @repo_key,
          run_id: "run-1",
          issue_id: @issue_id,
          status: "running",
          started_at: minutes(0),
          tokens: %{input_tokens: 24_220_000, output_tokens: 80_000, total_tokens: 24_300_000},
          last_event_at: minutes(16)
        })

      record!(@issue_id, 0, "run.started", started("run-1", "implementation", 1))
      record!(@issue_id, 5, "step.started", step("run-1"))
      record!(@issue_id, 11, "run.started", started("conductor-1", "conductor", 1))
      record!(@issue_id, 12, "run.ended", %{run_id: "conductor-1", run_kind: "conductor", exit: "answered", tokens: 40, counted: false})

      # The shutdown takes it; the boot closes its row in the run list, then its record.
      assert {:ok, 1} = RunStore.interrupt_running_runs(@repo_key, RunStore.restart_error())
      capture_log(fn -> assert RunEnds.close_unended() == 1 end)

      assert [ended] = TicketEvents.query(@issue_id, types: ["run.ended"], run_id: "run-1")
      assert ended.at == minutes(16)
      assert %{run_id: "run-1", tokens: 24_300_000, duration_ms: 960_000, counted: false, exit: "ended; no end was recorded"} = ended.payload

      # The ticket's budget and the ticket page's total count it, with the Conductor's turn.
      events = TicketEvents.query(@issue_id, limit: :all)
      record = %{repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "TP-1648"}
      facts_opts = [events: events, token_cap: 50_000_000, diff_stat: fn _record -> [] end]
      assert %{budget: %{tokens_used: 24_300_040}} = Facts.build(record, nil, facts_opts)

      phase_names = %{code_review: "Code Review", qa: "QA", ci_fix: "CI Fix"}
      facts = %{now: minutes(30), terminal_states: ["Done"], token_cap: 50_000_000, phase_names: phase_names}
      assert %{lifecycle: %{tokens: %{total: 24_300_040, conductor_tokens: 40}}} = Lifecycle.compute(events, facts)

      # The next boot finds nothing left to close.
      assert RunEnds.close_unended() == 0
    end

    test "a run with no row in the run list keeps today's close, with no tokens" do
      record!(@issue_id, 0, "run.started", started("run-1", "implementation", 1))
      record!(@issue_id, 4, "step.completed", step("run-1"))

      unreadable = fn _repo_key, _issue_id -> {:error, :unavailable} end
      capture_log(fn -> assert RunEnds.close_unended(runs: unreadable) == 1 end)

      assert [%{at: at, payload: payload}] = TicketEvents.query(@issue_id, types: ["run.ended"])
      assert at == minutes(4)
      refute Map.has_key?(payload, :tokens)
    end
  end

  describe "kept/3" do
    test "reads each run's kept tokens and last agent event, nil where the row has none" do
      rows = [
        %{run_id: "run-1", tokens: %{total_tokens: 1_200}, last_event_at: minutes(3)},
        %{run_id: "run-2", tokens: %{"total_tokens" => 7}, last_event_at: DateTime.to_iso8601(minutes(4))},
        %{run_id: "run-3", tokens: %{total_tokens: -1}, last_event_at: "not a time"},
        %{run_id: "run-4", tokens: nil, last_event_at: 12},
        %{run_id: nil}
      ]

      assert RunEnds.kept(@repo_key, @issue_id, fn @repo_key, @issue_id -> rows end) == %{
               "run-1" => %{tokens: 1_200, last_event_at: minutes(3)},
               "run-2" => %{tokens: 7, last_event_at: minutes(4)},
               "run-3" => %{tokens: nil, last_event_at: nil},
               "run-4" => %{tokens: nil, last_event_at: nil}
             }

      assert RunEnds.kept(@repo_key, @issue_id, fn _repo_key, _issue_id -> {:error, :unavailable} end) == %{}
      assert RunEnds.kept(nil, @issue_id) == %{}
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

  test "end_payload/3 never reads a negative duration, and carries the tokens the run's row kept" do
    started = event(@issue_id, 10, "run.started", started("run-1", "qa", 1))
    assert %{duration_ms: 0, exit: "ended; no end was recorded"} = payload = RunEnds.end_payload(started, @at)
    refute Map.has_key?(payload, :tokens)
    assert %{tokens: 500} = RunEnds.end_payload(started, @at, %{tokens: 500, last_event_at: nil})
    refute Map.has_key?(RunEnds.end_payload(started, @at, %{tokens: nil, last_event_at: nil}), :tokens)
    assert RunEnds.unrecorded_exit() == "ended; no end was recorded"
  end

  defp started(run_id, run_kind, run_number), do: %{run_id: run_id, run_kind: run_kind, run_number: run_number}

  defp step(run_id), do: %{run_id: run_id, step_id: "code", title: "Write the code", mode: "delegated", outcome: "passed"}

  defp minutes(minute), do: DateTime.add(@at, minute * 60)

  defp ends(open), do: Enum.map(open, fn {started, ended_at} -> {started.payload.run_id, DateTime.diff(ended_at, @at, :minute)} end)

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
