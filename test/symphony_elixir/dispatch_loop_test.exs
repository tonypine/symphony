defmodule SymphonyElixir.DispatchLoopTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{DecisionRequest, DispatchLoop, TicketState}

  @limits %{runs: 4, window_ms: 600_000, long_runs: 8, long_window_ms: 3_600_000}
  @now ~U[2026-10-13 18:00:00Z]

  defp run(kind, minutes_ago, attrs \\ %{}) do
    Map.merge(
      %{kind: kind, run_id: "run-#{minutes_ago}", state: "In Progress", head: nil, at: DateTime.add(@now, -minutes_ago * 60, :second), outcome: nil},
      attrs
    )
  end

  defp attempt(kind \\ :implementation, attrs \\ %{}), do: Map.merge(%{kind: kind, state: "In Progress", head: nil}, attrs)

  describe "limits/1" do
    test "reads the watchdog settings" do
      watchdog = %{
        dispatch_loop_runs: 3,
        dispatch_loop_window_ms: 1_000,
        dispatch_loop_long_runs: 5,
        dispatch_loop_long_window_ms: 2_000
      }

      assert DispatchLoop.limits(watchdog) == %{runs: 3, window_ms: 1_000, long_runs: 5, long_window_ms: 2_000}
    end
  end

  describe "check/4" do
    test "lets the runs up to the limit through" do
      assert DispatchLoop.check([], attempt(), @limits, @now) == :ok
      assert DispatchLoop.check(Enum.map([1, 2, 3], &run("implementation", &1)), attempt(), @limits, @now) == :ok
    end

    test "a run past the short limit is a loop" do
      runs = Enum.map([1, 2, 3, 4], &run("implementation", &1))

      assert {:loop, %{kind: "implementation", count: 4, window_ms: 600_000, runs: ^runs}} =
               DispatchLoop.check(runs, attempt(), @limits, @now)
    end

    test "runs outside the short window count towards the long one" do
      runs = Enum.map([5, 12, 20, 28, 36, 44, 52, 59], &run("implementation", &1))
      assert {:loop, %{count: 8, window_ms: 3_600_000}} = DispatchLoop.check(runs, attempt(), @limits, @now)
      assert DispatchLoop.check(runs, attempt(), %{@limits | long_runs: 9}, @now) == :ok
      assert DispatchLoop.check(Enum.map([5, 12, 20, 28, 36, 44, 52, 61], &run("implementation", &1)), attempt(), @limits, @now) == :ok
    end

    test "only the attempt's run kind counts" do
      runs = [run("review_feedback", 1), run("implementation", 2), run("review_feedback", 3), run("implementation", 4)]
      assert DispatchLoop.check(runs, attempt(), @limits, @now) == :ok
      assert DispatchLoop.check(runs, attempt("implementation"), %{@limits | runs: 2}, @now) |> elem(0) == :loop
    end

    test "a state change or a new PR head ends the count" do
      runs = [run("implementation", 1), run("implementation", 2), run("implementation", 3, %{state: "Todo"}), run("implementation", 4)]
      assert DispatchLoop.check(runs, attempt(), %{@limits | runs: 3}, @now) == :ok

      pushed = [run("rework", 1, %{head: "b"}), run("rework", 2, %{head: "b"}), run("rework", 3, %{head: "a"})]
      assert DispatchLoop.check(pushed, attempt(:rework, %{head: "b"}), %{@limits | runs: 3}, @now) == :ok
      assert DispatchLoop.check(pushed, attempt(:rework, %{head: "c"}), %{@limits | runs: 1}, @now) == :ok
    end

    test "states compare case-insensitively, and a run with no start time is not counted" do
      runs = [run("implementation", 1, %{state: " in progress "}), run("implementation", 2, %{at: nil})]
      assert {:loop, %{count: 1}} = DispatchLoop.check(runs, attempt(), %{@limits | runs: 1}, @now)

      no_state = [run("implementation", 1, %{state: nil}), run("implementation", 2)]
      assert {:loop, %{count: 1}} = DispatchLoop.check(no_state, attempt(:implementation, %{state: nil}), %{@limits | runs: 1}, @now)
    end
  end

  describe "hold_attrs/2" do
    test "names the run kind, the count, the window and how the last runs ended" do
      runs = [
        run("implementation", 1, %{outcome: %{exit: "ended normally", head: nil, at: @now}}),
        run("implementation", 2, %{head: "aaaaaaa", outcome: %{exit: "failed (boom)", head: "bbbbbbbbbbbb", at: @now}}),
        run("implementation", 3),
        run("implementation", 4)
      ]

      signals = [%{name: "handoff", details: %{}, at: DateTime.add(@now, -90, :second)}, %{name: "handoff", details: %{}, at: nil}]
      attrs = DispatchLoop.hold_attrs(%{kind: "implementation", count: 4, window_ms: 600_000, runs: runs}, signals)

      assert attrs.reason ==
               "dispatch_loop: 4 implementation runs in 10 minutes without a state change, a new PR head or a decision, " <>
                 "so Symphony started no more. Last runs: " <>
                 "started 17:59 UTC, ended normally, no new PR head, no handoff signal; " <>
                 "started 17:58 UTC, failed (boom), pushed bbbbbbb, handoff signal; " <>
                 "started 17:57 UTC, no recorded end, no new PR head, no handoff signal"

      assert attrs.clearing_condition == "when a person unblocks or restarts it"
      assert attrs.waits_on == %{type: "dispatch_loop", keys: ["implementation"]}
      assert DispatchLoop.hold_type() == "dispatch_loop"
    end

    test "words the window in seconds or one minute, and a run with no start time" do
      runs = [run("qa", 0, %{at: nil})]
      assert DispatchLoop.hold_attrs(%{kind: "qa", count: 1, window_ms: 90_000, runs: runs}, []).reason =~ "1 qa run in 90 seconds"
      assert DispatchLoop.hold_attrs(%{kind: "qa", count: 1, window_ms: 60_000, runs: runs}, []).reason =~ "in 1 minute without"
      assert DispatchLoop.hold_attrs(%{kind: "qa", count: 1, window_ms: 60_000, runs: runs}, []).reason =~ "started at an unknown time"
    end
  end

  describe "question_attrs/2 and answer_move/1" do
    test "a loop asks what now, in plain words the writing standard takes" do
      request = DispatchLoop.question_attrs(%{kind: "implementation", count: 4, window_ms: 600_000, runs: []}, "MOT-1")

      assert request.title == "MOT-1 ran 4 times in 10 minutes without finishing"
      assert request.question == "MOT-1 ran 4 times in 10 minutes without finishing. Should Symphony run it again, start it over from main, or keep it paused?"
      assert request.if_unanswered == "MOT-1 stays paused and Symphony starts no run on it."
      assert Enum.map(request.options, &{&1.label, &1.recommended}) == [{"Run it again", true}, {"Start it over from main", false}, {"Keep it paused", false}]
      assert DecisionRequest.check(request) == :ok
    end

    test "a quiet handoff asks the same question about its last runs" do
      request = DispatchLoop.question_attrs({:quiet_handoff, 2}, "MOT-1")

      assert request.title == "MOT-1's last two runs ended without a handoff"
      assert request.why == "The last runs on MOT-1 stopped without handing the work on, so Symphony started no more runs on it."
      assert Enum.map(request.options, & &1.label) == ["Run it again", "Start it over from main", "Keep it paused"]
      assert DecisionRequest.check(request) == :ok
      assert DispatchLoop.question_attrs({:quiet_handoff, 3}, "MOT-1").title == "MOT-1's last 3 runs ended without a handoff"
    end

    test "the answer's option is Unblock, Restart or nothing" do
      options = DispatchLoop.question_attrs({:quiet_handoff, 2}, "MOT-1").options
      answered = fn option -> %{state: :answered, answer: %{option: option}, options: options} end

      assert DispatchLoop.answer_move(answered.(1)) == :unblock
      assert DispatchLoop.answer_move(answered.(2)) == :restart
      assert DispatchLoop.answer_move(answered.(3)) == :keep
      assert DispatchLoop.answer_move(answered.(nil)) == :keep
      assert DispatchLoop.answer_move(%{state: :open, answer: nil, options: options}) == :keep
      assert DispatchLoop.option_label(:unblock) == "Run it again"
      assert DispatchLoop.option_label(:restart) == "Start it over from main"
    end
  end

  # The designed machine's flows, run back to back with seconds between runs, never trip the guard:
  # each phase starts on another state or PR head, and verdicts end the count.
  describe "the designed machine's flows" do
    setup do
      %{record: TicketState.new("symphony", "issue-flow")}
    end

    test "the happy path", %{record: record} do
      steps = [
        {:dispatch, :implementation, "Todo", nil},
        {:dispatch, :implementation, "In Progress", nil},
        {:dispatch, :implementation, "In Progress", nil},
        {:dispatch, :implementation, "In Progress", "a"},
        {:dispatch, :code_review, "Code Review", "a"},
        {:verdict, "code_review", "a", "approve"},
        {:dispatch, :qa, "QA", "a"},
        {:verdict, "qa", "a", "pass"},
        {:dispatch, :landing, "Merging", "a"}
      ]

      assert walk(record, steps) == :ok
    end

    test "the rework path, with a CI Fix and review comments on the way", %{record: record} do
      steps = [
        {:dispatch, :implementation, "In Progress", nil},
        {:dispatch, :implementation, "In Progress", nil},
        {:dispatch, :code_review, "Code Review", "a"},
        {:verdict, "code_review", "a", "rework"},
        {:dispatch, :rework, "Rework", "a"},
        {:dispatch, :rework, "Rework", "a"},
        {:dispatch, :rework, "Rework", "a"},
        {:dispatch, :rework, "Rework", "b"},
        {:dispatch, :ci_fix, "CI Fix", "b"},
        {:dispatch, :ci_fix, "CI Fix", "b"},
        {:dispatch, :code_review, "Code Review", "c"},
        {:verdict, "code_review", "c", "rework"},
        {:dispatch, :rework, "Rework", "c"},
        {:dispatch, :review_feedback, "Rework", "c"},
        {:dispatch, :rework, "Rework", "d"},
        {:dispatch, :code_review, "Code Review", "d"},
        {:verdict, "code_review", "d", "approve"},
        {:dispatch, :qa, "QA", "d"},
        {:verdict, "qa", "d", "fail"},
        {:dispatch, :rework, "Rework", "d"},
        {:dispatch, :rework, "Rework", "e"},
        {:dispatch, :code_review, "Code Review", "e"},
        {:verdict, "code_review", "e", "approve"},
        {:dispatch, :qa, "QA", "e"},
        {:verdict, "qa", "e", "pass"}
      ]

      assert walk(record, steps) == :ok
    end

    test "the same run kind with no progress trips it on the fifth run", %{record: record} do
      steps = List.duplicate({:dispatch, :rework, "Rework", "a"}, 5)
      assert {:loop, 4} = walk(record, steps)
    end

    defp walk(record, steps) do
      steps
      |> Enum.with_index()
      |> Enum.reduce_while(record, fn {step, index}, record ->
        now = DateTime.add(@now, index * 20, :second)

        case step(record, step, now) do
          {:ok, record} -> {:cont, record}
          {:loop, %{count: count}} -> {:halt, {:loop, count}}
        end
      end)
      |> case do
        {:loop, _count} = loop -> loop
        _record -> :ok
      end
    end

    defp step(record, {:dispatch, kind, state, head}, now) do
      case DispatchLoop.check(TicketState.dispatches(record), %{kind: kind, state: state, head: head}, @limits, now) do
        :ok -> {:ok, TicketState.record_dispatch(record, %{kind: kind, run_id: "run-#{now}", state: state, head: head}, now)}
        {:loop, loop} -> {:loop, loop}
      end
    end

    defp step(record, {:verdict, kind, head, outcome}, now), do: {:ok, TicketState.record_verdict(record, kind, head, outcome, now)}
  end
end
