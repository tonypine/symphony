defmodule SymphonyElixir.PrWatch.ParityTest do
  @moduledoc """
  Webhooks change how soon the PR and CI watcher acts, never what it does (TP-948): each incident
  TP-941 replays, run once by polling only and once by GitHub's deliveries and their confirm reads
  (`SymphonyElixir.PrWatchParity`), makes the same calls to Linear and GitHub in the same order.
  """

  use SymphonyElixir.TestSupport

  import SymphonyElixir.PrWatchParity,
    only: [check_failed: 2, check_passed: 2, synchronize: 2, merged: 1, push: 0, red: 0]

  alias SymphonyElixir.PrWatchParity, as: Parity

  setup do
    start_supervised!(Parity)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 20}
    )

    :ok
  end

  # The incidents of TP-941's switch, as GitHub and the runs played them.
  @fixtures %{
    "TP-920/TP-892: a red head in Code Review reruns once, goes to CI Fix, and is reviewed once back green" => %{
      tickets: [{"1", "Code Review", []}],
      steps: [
        {:github, [synchronize("1", "head-1-2")], [{"1", head_sha: "head-1-2", ci: :pending}]},
        {:github, [check_failed("1", "head-1-2")], [{"1", red()}]},
        {:github, [check_failed("1", "head-1-2")], []},
        {:move, "1", "Code Review"},
        {:github, [synchronize("1", "head-1-3")], [{"1", head_sha: "head-1-3", ci: :pending, failing_check: nil, failed_checks: []}]},
        {:github, [check_passed("1", "head-1-3")], [{"1", ci: :green}]}
      ]
    },
    "TP-896: a red, armed Merging PR has auto-merge turned off and goes to CI Fix; back on a new head it is armed and lands" => %{
      tickets: [{"1", "Merging", ci: :pending, mergeable: :blocked, auto_merge: :armed}],
      steps: [
        {:github, [check_failed("1", "head-1-1")], [{"1", red()}]},
        {:github, [check_failed("1", "head-1-1")], []},
        {:move, "1", "Merging"},
        {:github, [synchronize("1", "head-1-2")], [{"1", head_sha: "head-1-2", ci: :pending, failing_check: nil, failed_checks: []}]},
        {:github, [merged("1")], [{"1", pr: :merged}]}
      ]
    },
    "TP-921/TP-891: a push to main makes a Merging PR conflict: auto-merge off and CI Fix, once" => %{
      tickets: [{"1", "Merging", ci: :pending, mergeable: :blocked, auto_merge: :armed}, {"2", "QA", []}],
      steps: [
        {:github, [push()], [{"1", mergeable: :dirty}]},
        {:github, [push()], []}
      ]
    },
    "BEHIND after a push to main gets one update-branch per head" => %{
      tickets: [{"1", "Merging", ci: :pending, mergeable: :blocked, auto_merge: :armed}],
      steps: [
        {:github, [push()], [{"1", mergeable: :behind}]},
        {:github, [synchronize("1", "head-1-2")], [{"1", head_sha: "head-1-2", mergeable: :blocked}]}
      ]
    },
    "CLEAN and green merges now, once" => %{
      tickets: [{"1", "Merging", ci: :pending, mergeable: :blocked}],
      steps: [
        {:github, [check_passed("1", "head-1-1")], [{"1", ci: :green, mergeable: :clean}]},
        {:github, [check_passed("1", "head-1-1")], []}
      ]
    }
  }

  for {name, fixture} <- @fixtures do
    @fixture fixture
    test "poll-only and delivery-driven runs act the same: #{name}" do
      polled = Parity.run(@fixture, :poll)
      Parity.reset!()
      delivered = Parity.run(@fixture, :webhook)

      assert polled.actions != []
      assert delivered.actions == polled.actions
      # Each step reached the watcher within one confirm read (plus 1 s per PR re-read after a push),
      # and within one poll interval without deliveries.
      assert Enum.all?(delivered.elapsed_ms, &(&1 < 5_000))
      assert Enum.all?(polled.elapsed_ms, &(&1 == 30_000))
    end
  end

  test "a check_run failure delivery moves a Code Review ticket to CI Fix within one confirm read; with deliveries off, within one poll interval" do
    fixture = %{
      tickets: [{"1", "Code Review", red()}],
      steps: [{:github, [check_failed("1", "head-1-1")], []}]
    }

    # The watcher's first read of the red head reruns its failed check (R22); the rerun failed too.
    delivered = Parity.run(fixture, :webhook)
    assert Parity.state("1") == "CI Fix"
    assert %{source: :webhook, decision: %{rule: "R21"}} = Parity.watch("1")
    assert delivered.elapsed_ms == [3_000]
    assert [{:rerun, "77"} | _rest] = delivered.actions
    assert {:move, {"issue-1", "CI Fix"}} in delivered.actions

    Parity.reset!()
    polled = Parity.run(fixture, :poll)
    assert Parity.state("1") == "CI Fix"
    assert %{source: :poll} = Parity.watch("1")
    assert polled.elapsed_ms == [30_000]
    assert polled.actions == delivered.actions
  end

  test "a push to main re-reads every watched PR on main, 1 s apart, and a newly DIRTY one goes to CI Fix" do
    fixture = %{
      tickets: [{"1", "Code Review", []}, {"2", "QA", []}, {"3", "Code Review", base_ref: "release"}],
      steps: [{:github, [push()], [{"2", mergeable: :dirty}]}]
    }

    delivered = Parity.run(fixture, :webhook)

    assert delivered.elapsed_ms == [2_000]
    assert Parity.state("2") == "CI Fix"
    assert Parity.state("1") == "Code Review"
    assert %{source: :webhook, facts: %{mergeable: :clean}} = Parity.watch("1")
    # A PR on another base was not touched by the push.
    assert %{source: :poll} = Parity.watch("3")

    Parity.reset!()
    assert Parity.run(fixture, :poll).actions == delivered.actions
  end
end
