defmodule SymphonyElixir.LifecycleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Lifecycle, TicketEvents}
  alias SymphonyElixir.TicketEvents.Event

  @repo "default"
  @id "issue-1"
  @minute 60_000
  @shipped_at ~U[2026-10-30 21:30:00Z]
  @facts %{
    now: @shipped_at,
    terminal_states: ["Done", "Canceled"],
    token_cap: 8_000_000,
    phase_names: %{code_review: "Code Review", qa: "QA", ci_fix: "CI Fix"}
  }
  @renamed %{code_review: "In Review", qa: "Testing", ci_fix: "Repair"}

  # TP-1244's life, as `docs/design/prototypes/ticket-page/fixtures.js` holds it: its phase moves and
  # its runs, with their times and tokens.
  @tp_1244_moves [
    {"2026-10-29T21:40", "Backlog", "Todo"},
    {"2026-10-30T15:23", "Todo", "In Progress"},
    {"2026-10-30T16:02", "In Progress", "Code Review"},
    {"2026-10-30T16:11", "Code Review", "CI Fix"},
    {"2026-10-30T16:21", "CI Fix", "Code Review"},
    {"2026-10-30T16:38", "Code Review", "Rework"},
    {"2026-10-30T16:58", "Rework", "Code Review"},
    {"2026-10-30T17:12", "Code Review", "QA"},
    {"2026-10-30T17:31", "QA", "Rework"},
    {"2026-10-30T18:33", "Rework", "Code Review"},
    {"2026-10-30T18:46", "Code Review", "QA"},
    {"2026-10-30T19:05", "QA", "Merging"},
    {"2026-10-30T21:05", "Merging", "Done"}
  ]

  @tp_1244_runs [
    {"r1", "implementation", "2026-10-30T15:24", "2026-10-30T16:02", 2_400_000},
    {"r2", "ci_fix", "2026-10-30T16:12", "2026-10-30T16:21", 500_000},
    {"r3", "code_review", "2026-10-30T16:30", "2026-10-30T16:38", 600_000},
    {"r4", "rework", "2026-10-30T16:39", "2026-10-30T16:58", 1_100_000},
    {"r5", "code_review", "2026-10-30T17:06", "2026-10-30T17:12", 400_000},
    {"r6", "qa", "2026-10-30T17:13", "2026-10-30T17:31", 900_000},
    {"r7", "rework", "2026-10-30T17:32", "2026-10-30T17:44", 600_000},
    {"r8", "rework", "2026-10-30T18:21", "2026-10-30T18:33", 700_000},
    {"r9", "code_review", "2026-10-30T18:41", "2026-10-30T18:46", 400_000},
    {"r10", "qa", "2026-10-30T18:47", "2026-10-30T19:05", 1_000_000}
  ]

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp at(text), do: DateTime.from_naive!(NaiveDateTime.from_iso8601!(text <> ":00"), "Etc/UTC")

  defp entered(time, to, from \\ nil) do
    payload = if from, do: %{to: to, from: from}, else: %{to: to}
    %Event{type: "phase.entered", payload: payload, at: at(time)}
  end

  defp started(time, run_id), do: %Event{type: "run.started", payload: %{run_id: run_id, run_kind: "implementation"}, at: at(time)}

  defp ended(time, run_id, fields), do: %Event{type: "run.ended", payload: Map.merge(%{run_id: run_id, exit: "success"}, Map.new(fields)), at: at(time)}

  defp stages(%{lifecycle: %{stages: stages}}), do: Map.new(stages, &{&1.id, &1})

  defp states(result), do: Enum.map(result.lifecycle.stages, & &1.state)

  defp visits(result), do: Enum.map(result.lifecycle.stages, & &1.visits)

  defp moved(moves), do: Enum.map(moves, fn {time, to} -> entered("2026-10-30T" <> time, to) end)

  defp record_tp_1244 do
    for {time, from, to} <- @tp_1244_moves do
      {:ok, _event} = TicketEvents.record(@repo, @id, "phase.entered", %{to: to, from: from}, at: at(time))
    end

    for {run_id, run_kind, start, stop, tokens} <- @tp_1244_runs do
      {:ok, _event} = TicketEvents.record(@repo, @id, "run.started", %{run_id: run_id, run_kind: run_kind}, at: at(start), run_id: run_id)
      duration_ms = DateTime.diff(at(stop), at(start), :millisecond)
      {:ok, _event} = TicketEvents.record(@repo, @id, "run.ended", %{run_id: run_id, exit: "success", duration_ms: duration_ms, tokens: tokens}, at: at(stop), run_id: run_id)
    end
  end

  describe "TP-1244's life" do
    setup do
      record_tp_1244()
      %{result: Lifecycle.read(@id, @shipped_at)}
    end

    test "the lifecycle lists the five stages with their visits, time and tokens", %{result: result} do
      assert result.lifecycle.current == nil

      assert result.lifecycle.stages == [
               %{
                 id: "coding",
                 name: "Coding",
                 state: "passed",
                 visits: 1,
                 time_ms: 39 * @minute,
                 agent_time_ms: 38 * @minute,
                 tokens: 2_400_000
               },
               # Each Code Review, the CI Fix and the two Reworks: 9 + 10 + 17 + 20 + 14 + 62 + 13 min.
               %{
                 id: "code_review",
                 name: "Code Review",
                 state: "passed",
                 visits: 4,
                 time_ms: 145 * @minute,
                 agent_time_ms: 71 * @minute,
                 tokens: 4_300_000
               },
               %{
                 id: "qa",
                 name: "QA",
                 state: "passed",
                 visits: 2,
                 time_ms: 38 * @minute,
                 agent_time_ms: 36 * @minute,
                 tokens: 1_900_000
               },
               %{id: "merging", name: "Merging", state: "passed", visits: 1, time_ms: 120 * @minute, agent_time_ms: 0, tokens: 0},
               %{id: "done", name: "Done", state: "passed", visits: 1, time_ms: 0, agent_time_ms: 0, tokens: 0}
             ]
    end

    test "tokens by stage add up to the ticket's total, the runs' tokens on its timeline", %{result: result} do
      by_stage = result.lifecycle.stages |> Enum.map(& &1.tokens) |> Enum.sum()
      on_timeline = @tp_1244_runs |> Enum.map(&elem(&1, 4)) |> Enum.sum()

      assert result.lifecycle.tokens.total == 8_600_000
      assert by_stage == result.lifecycle.tokens.total
      assert on_timeline == result.lifecycle.tokens.total
    end

    test "the token cap is the configured per-ticket limit", %{result: result} do
      assert result.lifecycle.tokens.cap == Config.settings!().agent.max_tokens_per_issue
    end

    test "the phase path lists the phases in the order entered, with counts and times", %{result: result} do
      assert result.phase_path.current == "Done"

      assert result.phase_path.phases == [
               %{phase: "Todo", count: 1, time_ms: (17 * 60 + 43) * @minute, first_entered_at: "2026-10-29T21:40:00Z"},
               %{phase: "In Progress", count: 1, time_ms: 39 * @minute, first_entered_at: "2026-10-30T15:23:00Z"},
               %{phase: "Code Review", count: 4, time_ms: 53 * @minute, first_entered_at: "2026-10-30T16:02:00Z"},
               %{phase: "CI Fix", count: 1, time_ms: 10 * @minute, first_entered_at: "2026-10-30T16:11:00Z"},
               %{phase: "Rework", count: 2, time_ms: 82 * @minute, first_entered_at: "2026-10-30T16:38:00Z"},
               %{phase: "QA", count: 2, time_ms: 38 * @minute, first_entered_at: "2026-10-30T17:12:00Z"},
               %{phase: "Merging", count: 1, time_ms: 120 * @minute, first_entered_at: "2026-10-30T19:05:00Z"},
               %{phase: "Done", count: 1, time_ms: 0, first_entered_at: "2026-10-30T21:05:00Z"}
             ]
    end

    test "the phase path holds every move with its time", %{result: result} do
      assert result.phase_path.moves == Enum.map(@tp_1244_moves, fn {time, from, to} -> %{from: from, to: to, at: time <> ":00Z"} end)
    end

    test "a read writes nothing" do
      before = TicketEvents.query(@id, limit: :all)
      assert %{lifecycle: _lifecycle} = Lifecycle.read(@id, @shipped_at)
      assert TicketEvents.query(@id, limit: :all) == before
    end
  end

  describe "a stage's state and visits" do
    test "a ticket in Rework reads Code Review as current with visits 2, time running up to now" do
      events = moved([{"10:00", "In Progress"}, {"11:00", "Code Review"}, {"11:30", "Rework"}])

      result = Lifecycle.compute(events, %{@facts | now: at("2026-10-30T12:00")})

      assert result.lifecycle.current == "code_review"
      assert stages(result)["code_review"] |> Map.take([:state, :visits, :time_ms]) == %{state: "current", visits: 2, time_ms: 60 * @minute}
      assert states(result) == ["passed", "current", "not_yet", "not_yet", "not_yet"]
      assert result.phase_path.current == "Rework"
    end

    test "the move back from Rework into Code Review is the same visit" do
      events = moved([{"10:00", "In Progress"}, {"11:00", "Code Review"}, {"11:30", "Rework"}, {"11:45", "Code Review"}])

      assert stages(Lifecycle.compute(events, @facts))["code_review"].visits == 2
    end

    test "QA reads not yet, with its earlier visit, while Rework sent the ticket back from it" do
      events = moved([{"10:00", "In Progress"}, {"11:00", "Code Review"}, {"11:30", "QA"}, {"11:45", "Rework"}])

      result = Lifecycle.compute(events, %{@facts | now: at("2026-10-30T12:00")})

      assert result.lifecycle.current == "code_review"
      assert states(result) == ["passed", "current", "not_yet", "not_yet", "not_yet"]
      assert visits(result) == [1, 2, 1, 0, 0]
      assert stages(result)["qa"].time_ms == 15 * @minute
    end

    test "a stage the ticket went past without entering reads skipped" do
      events = moved([{"10:00", "In Progress"}, {"11:00", "Code Review"}, {"11:30", "Merging"}])

      result = Lifecycle.compute(events, @facts)

      assert result.lifecycle.current == "merging"
      assert states(result) == ["passed", "passed", "skipped", "current", "not_yet"]
    end

    test "CI Fix counts as a visit of the stage it interrupted" do
      events = moved([{"10:00", "In Progress"}, {"11:00", "Code Review"}, {"11:30", "Merging"}, {"11:45", "CI Fix"}])

      result = Lifecycle.compute(events, %{@facts | now: at("2026-10-30T12:00")})

      assert result.lifecycle.current == "merging"
      assert visits(result) == [1, 1, 0, 2, 0]
      assert stages(result)["merging"].time_ms == 30 * @minute
    end

    test "a CI Fix inside a Rework adds one visit, not two" do
      events = moved([{"10:00", "In Progress"}, {"11:00", "Code Review"}, {"11:10", "Rework"}, {"11:20", "CI Fix"}, {"11:30", "Rework"}])

      assert stages(Lifecycle.compute(events, @facts))["code_review"].visits == 3
    end

    test "a CI Fix with no stage before it serves Coding" do
      result = Lifecycle.compute(moved([{"10:00", "Todo"}, {"10:10", "CI Fix"}]), @facts)

      assert result.lifecycle.current == "coding"
      assert visits(result) == [1, 0, 0, 0, 0]
    end

    test "review comments that bring the ticket back to In Progress are a new Coding visit" do
      events = moved([{"10:00", "In Progress"}, {"11:00", "Code Review"}, {"11:30", "In Progress"}])

      result = Lifecycle.compute(events, @facts)

      assert result.lifecycle.current == "coding"
      assert states(result) == ["current", "not_yet", "not_yet", "not_yet", "not_yet"]
      assert visits(result) == [2, 1, 0, 0, 0]
    end

    test "a phase outside the stages holds no stage: nothing is current and its time counts in none" do
      events = moved([{"10:00", "In Progress"}, {"11:00", "Code Review"}, {"11:30", "Canceled"}])

      result = Lifecycle.compute(events, %{@facts | now: at("2026-10-30T12:00")})

      assert result.lifecycle.current == nil
      assert states(result) == ["passed", "passed", "not_yet", "not_yet", "not_yet"]
      assert result.lifecycle.stages |> Enum.map(& &1.time_ms) |> Enum.sum() == 90 * @minute
      assert %{phase: "Canceled", count: 1, time_ms: 0} = List.last(result.phase_path.phases)
    end

    test "a ticket that never entered a stage reads not yet in all five" do
      result = Lifecycle.compute(moved([{"10:00", "Backlog"}, {"10:10", "Todo"}]), %{@facts | now: at("2026-10-30T10:40")})

      assert result.lifecycle.current == nil
      assert states(result) == List.duplicate("not_yet", 5)
      assert [%{phase: "Backlog", time_ms: 600_000}, %{phase: "Todo", time_ms: 1_800_000}] = Enum.map(result.phase_path.phases, &Map.take(&1, [:phase, :time_ms]))
    end

    test "a ticket with no event reads empty" do
      result = Lifecycle.compute([], @facts)

      assert result.lifecycle.tokens == %{total: 0, cap: 8_000_000}
      assert states(result) == List.duplicate("not_yet", 5)
      assert result.phase_path == %{current: nil, phases: [], moves: []}
    end

    test "a second event naming the phase the ticket is in is no move" do
      result = Lifecycle.compute(moved([{"10:00", "In Progress"}, {"10:30", "In Progress"}]), %{@facts | now: at("2026-10-30T11:00")})

      assert [%{count: 1, time_ms: 3_600_000}] = result.phase_path.phases
      assert [%{at: "2026-10-30T10:00:00Z"}] = result.phase_path.moves
      assert stages(result)["coding"].visits == 1
    end

    test "a phase's name is matched whatever its case" do
      assert Lifecycle.compute(moved([{"10:00", " code review"}]), @facts).lifecycle.current == "code_review"
    end

    test "a move says where it came from, or the phase before it" do
      events = [entered("2026-10-30T10:00", "Todo", "Backlog"), entered("2026-10-30T10:10", "In Progress")]

      assert [%{from: "Backlog", to: "Todo"}, %{from: "Todo", to: "In Progress"}] = Lifecycle.compute(events, @facts).phase_path.moves
      assert [%{from: nil}] = Lifecycle.compute([entered("2026-10-30T10:00", "Todo")], @facts).phase_path.moves
    end
  end

  describe "stage spans" do
    test "each stay in a stage, from its move to the next; the current phase runs to now and a terminal or stageless one has none" do
      events = moved([{"09:00", "Todo"}, {"10:00", "In Progress"}, {"11:00", "Code Review"}, {"11:30", "Done"}])

      assert Lifecycle.stage_spans(events, @facts) == [
               %{stage: "coding", from: at("2026-10-30T10:00"), to: at("2026-10-30T11:00")},
               %{stage: "code_review", from: at("2026-10-30T11:00"), to: at("2026-10-30T11:30")}
             ]

      assert [%{stage: "qa", to: @shipped_at}] = Lifecycle.stage_spans(moved([{"21:00", "QA"}]), @facts)
    end

    test "facts come from the settings" do
      write_workflow_file!(Workflow.workflow_file_path())

      assert %{now: @shipped_at, terminal_states: [_ | _], phase_names: %{ci_fix: ci_fix}} = Lifecycle.facts(@shipped_at)
      assert is_binary(ci_fix)
    end
  end

  describe "a repository's own phase names" do
    setup do
      %{facts: %{@facts | now: at("2026-10-30T12:30"), phase_names: @renamed}}
    end

    test "a renamed Code Review, QA and CI Fix keep their stage, visits, time and tokens", %{facts: facts} do
      events = [
        entered("2026-10-30T10:00", "In Progress"),
        entered("2026-10-30T11:00", "In Review"),
        started("2026-10-30T11:05", "r1"),
        ended("2026-10-30T11:20", "r1", tokens: 100),
        entered("2026-10-30T11:30", "Repair"),
        started("2026-10-30T11:31", "r2"),
        ended("2026-10-30T11:40", "r2", tokens: 10),
        entered("2026-10-30T11:45", "In Review"),
        entered("2026-10-30T12:00", "Testing"),
        started("2026-10-30T12:05", "r3"),
        ended("2026-10-30T12:10", "r3", tokens: 1)
      ]

      result = Lifecycle.compute(events, facts)

      assert result.lifecycle.current == "qa"
      assert visits(result) == [1, 2, 1, 0, 0]
      assert %{time_ms: 3_600_000, tokens: 0} = stages(result)["coding"]
      assert %{name: "Code Review", time_ms: 3_600_000, tokens: 110} = stages(result)["code_review"]
      assert %{name: "QA", time_ms: 1_800_000, tokens: 1} = stages(result)["qa"]
    end

    test "a ticket in a renamed CI Fix reads the stage it interrupted as current", %{facts: facts} do
      result = Lifecycle.compute(moved([{"10:00", "In Progress"}, {"11:00", "In Review"}, {"11:30", "Repair"}]), facts)

      assert result.lifecycle.current == "code_review"
      assert %{state: "current", visits: 2, time_ms: 5_400_000} = stages(result)["code_review"]
    end

    test "a name matches whatever its case" do
      facts = %{@facts | phase_names: %{@renamed | code_review: " In Review "}}

      assert Lifecycle.compute(moved([{"10:00", "in review"}]), facts).lifecycle.current == "code_review"
    end

    test "the default names mean nothing once they are renamed", %{facts: facts} do
      result = Lifecycle.compute(moved([{"10:00", "Code Review"}]), facts)

      assert result.lifecycle.current == nil
      assert visits(result) == [0, 0, 0, 0, 0]
    end

    test "a phase turned off with an empty name holds no phase, and Rework still serves Code Review" do
      facts = %{@facts | phase_names: %{code_review: nil, qa: nil, ci_fix: "CI Fix"}}

      assert Lifecycle.compute(moved([{"10:00", "QA"}]), facts).lifecycle.current == nil
      assert Lifecycle.compute(moved([{"10:00", "Rework"}]), facts).lifecycle.current == "code_review"
    end
  end

  describe "a run's tokens and time" do
    test "a run counts in the stage the ticket was in when it started, even after it left" do
      events = [
        entered("2026-10-30T10:00", "In Progress"),
        started("2026-10-30T10:01", "r1"),
        entered("2026-10-30T10:05", "Code Review"),
        ended("2026-10-30T10:09", "r1", tokens: 100, duration_ms: 480_000)
      ]

      result = stages(Lifecycle.compute(events, @facts))

      assert %{tokens: 100, agent_time_ms: 480_000} = result["coding"]
      assert %{tokens: 0, agent_time_ms: 0} = result["code_review"]
    end

    test "a first run that started before its move out of Todo counts in Coding" do
      events = [
        entered("2026-10-30T09:00", "Todo"),
        started("2026-10-30T09:59", "r1"),
        entered("2026-10-30T10:00", "In Progress"),
        ended("2026-10-30T10:10", "r1", tokens: 100)
      ]

      assert %{tokens: 100, agent_time_ms: 660_000} = stages(Lifecycle.compute(events, @facts))["coding"]
    end

    test "a run in no stage at all still adds up to the total, in Coding" do
      events = [entered("2026-10-30T09:00", "Plan Review"), started("2026-10-30T09:10", "r1"), ended("2026-10-30T09:20", "r1", tokens: 100)]

      result = Lifecycle.compute(events, @facts)

      assert stages(result)["coding"].tokens == 100
      assert result.lifecycle.tokens.total == 100
    end

    test "a run whose start the ledger lacks counts at its end, with no time" do
      events = [entered("2026-10-30T10:00", "QA"), ended("2026-10-30T10:10", "r1", tokens: 100)]

      assert %{tokens: 100, agent_time_ms: 0} = stages(Lifecycle.compute(events, @facts))["qa"]
    end

    test "a run still working adds nothing yet" do
      events = [entered("2026-10-30T10:00", "In Progress"), started("2026-10-30T10:01", "r1")]

      result = Lifecycle.compute(events, @facts)

      assert %{tokens: 0, agent_time_ms: 0} = stages(result)["coding"]
      assert result.lifecycle.tokens.total == 0
    end

    test "tokens read as a count, as a map with their total, or as none" do
      events = [
        ended("2026-10-30T10:01", "r1", tokens: %{total_tokens: 1}),
        ended("2026-10-30T10:02", "r2", tokens: %{"total_tokens" => 10}),
        ended("2026-10-30T10:03", "r3", tokens: 100),
        ended("2026-10-30T10:04", "r4", [])
      ]

      assert Lifecycle.compute(events, @facts).lifecycle.tokens.total == 111
    end

    test "other events and a ledger that cannot be read count for nothing" do
      events = [%Event{type: "note", payload: %{text: "x"}, at: at("2026-10-30T10:00")}, {:error, :unavailable}]

      assert Lifecycle.compute(events, @facts).lifecycle.tokens.total == 0
      assert Lifecycle.compute([], @facts) == Lifecycle.compute(events, @facts)
    end
  end
end
