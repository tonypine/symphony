defmodule SymphonyElixir.ForcedStatusTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ForcedStatus

  describe "describe/1" do
    test "a running agent gives its run kind as the phase and waits on nothing" do
      kinds = [:implementation, :rework, :review_feedback, :ci_fix, :landing, :breakdown, :close_out]

      for kind <- [:final_verification | kinds] do
        assert %{phase: ^kind, running: true, waiting_on: nil, blockers: []} =
                 ForcedStatus.describe(%{running_kind: kind, blockers: ["MT-1"]})
      end

      assert %{phase: :auto_review, running: true} = ForcedStatus.describe(%{running_kind: :qa})
      assert %{phase: :implementation, running: true} = ForcedStatus.describe(%{running_kind: :pre_push_review})
    end

    test "a running QA pass is Auto Review, and a queued one waits on a slot" do
      assert %{phase: :auto_review, running: true, waiting_on: nil} =
               ForcedStatus.describe(%{qa: :running, state: "Auto Review"})

      assert %{phase: :auto_review, running: false, waiting_on: :slot} =
               ForcedStatus.describe(%{qa: :queued, state: "Auto Review", auto_review_state: "Auto Review"})

      assert %{phase: :auto_review, waiting_on: nil} =
               ForcedStatus.describe(%{state: " auto review ", auto_review_state: "Auto Review"})
    end

    test "human gates: In Review and Human Review wait on a human, Backlog and Triage on the backlog" do
      assert %{phase: :waiting_for_human, waiting_on: :human} =
               ForcedStatus.describe(%{state: "In Review", kind: :implementation})

      assert %{phase: :waiting_for_human, waiting_on: :human} =
               ForcedStatus.describe(%{state: " human review", human_review_state: "Human Review", auto_review_state: "Auto Review"})

      # With the state turned off, a ticket in a state of that name is not held for a human.
      assert %{phase: :implementation, waiting_on: nil} =
               ForcedStatus.describe(%{state: "Human Review", human_review_state: nil, kind: :implementation})

      assert %{phase: :breakdown, waiting_on: :backlog} = ForcedStatus.describe(%{state: "Backlog", kind: :breakdown})

      assert %{phase: :implementation, waiting_on: :backlog} =
               ForcedStatus.describe(%{state: "Triage", kind: :implementation})
    end

    test "a Merging ticket held for CI is waiting on CI; one GitHub auto-merges is landing, waiting on CI" do
      assert %{phase: :waiting_on_ci, waiting_on: :ci} =
               ForcedStatus.describe(%{state: "Merging", kind: :landing, merging_ci_wait?: true})

      assert %{phase: :landing, waiting_on: :ci} =
               ForcedStatus.describe(%{state: "Merging", kind: :landing, auto_merge?: true})
    end

    test "otherwise the next run's kind, waiting on blockers, the Pause, a usage limit or a slot, in that order" do
      base = %{state: "Todo", kind: :implementation, auto_review_state: "Auto Review"}

      assert %{phase: :implementation, waiting_on: :blocker, blockers: ["MT-1"]} =
               ForcedStatus.describe(Map.merge(base, %{blockers: ["MT-1"], paused?: true, usage_limit?: true, slot_waiting?: true}))

      assert %{waiting_on: :paused, blockers: []} = ForcedStatus.describe(Map.merge(base, %{paused?: true, usage_limit?: true}))
      assert %{waiting_on: :usage_limit} = ForcedStatus.describe(Map.merge(base, %{usage_limit?: true, slot_waiting?: true}))
      assert %{waiting_on: :slot} = ForcedStatus.describe(Map.merge(base, %{slot_waiting?: true}))
      assert %{phase: :ci_fix, waiting_on: nil} = ForcedStatus.describe(%{base | kind: :ci_fix})
      assert %{phase: :review_feedback} = ForcedStatus.describe(%{state: nil, kind: :review_feedback})
      assert %{phase: :implementation, running: false} = ForcedStatus.describe(%{})
    end
  end

  test "forced_for_seconds and stale?" do
    assert ForcedStatus.forced_for_seconds(~U[2026-10-01 00:00:00Z], ~U[2026-10-04 00:00:01Z]) == 259_201
    assert ForcedStatus.forced_for_seconds(~U[2026-10-04 00:00:01Z], ~U[2026-10-04 00:00:00Z]) == 0

    refute ForcedStatus.stale?(259_199, 72)
    assert ForcedStatus.stale?(259_200, 72)
  end

  test "labels and the one-line summary" do
    assert ForcedStatus.phase_label(:review_feedback) == "review feedback"
    assert ForcedStatus.phase_label("waiting_for_human") == "waiting for a human"
    assert ForcedStatus.phase_label(:close_out) == "close-out"
    assert ForcedStatus.phase_label(:breakdown) == "plan"
    assert ForcedStatus.phase_label(nil) == "unknown"

    assert ForcedStatus.waiting_label(%{running: true, waiting_on: :slot}) == "running"
    assert ForcedStatus.waiting_label(%{waiting_on: :blocker, blockers: ["MT-1", "MT-2"]}) == "blocker MT-1, MT-2"
    assert ForcedStatus.waiting_label(%{waiting_on: "blocker"}) == "blocker unknown"
    assert ForcedStatus.waiting_label(%{waiting_on: "usage_limit"}) == "usage limit"
    assert ForcedStatus.waiting_label(%{waiting_on: :ci}) == "CI"
    assert ForcedStatus.waiting_label(%{waiting_on: nil}) == "-"

    assert ForcedStatus.summary(%{phase: :implementation, running: true}) == "implementation · running"
    assert ForcedStatus.summary(%{phase: :implementation, waiting_on: :blocker, blockers: ["TP-1"]}) == "implementation · waiting on blocker TP-1"
    assert ForcedStatus.summary(%{phase: "waiting_for_human", waiting_on: "human"}) == "waiting for a human"
    assert ForcedStatus.summary(%{phase: :waiting_on_ci, waiting_on: :ci}) == "waiting on CI"
    assert ForcedStatus.summary(%{phase: :landing, waiting_on: :ci}) == "landing · waiting on CI"
    assert ForcedStatus.summary(%{phase: :ci_fix, waiting_on: nil}) == "CI fix"
  end

  test "duration_label" do
    assert ForcedStatus.duration_label(-5) == "0s"
    assert ForcedStatus.duration_label(45) == "45s"
    assert ForcedStatus.duration_label(720) == "12m"
    assert ForcedStatus.duration_label(11_100) == "3h 5m"
    assert ForcedStatus.duration_label(187_200) == "2d 4h"
    assert ForcedStatus.duration_label(nil) == "n/a"
  end
end
