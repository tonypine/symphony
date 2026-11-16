defmodule SymphonyElixir.PrWatch.ConflictFixReplayTest do
  @moduledoc """
  TP-1518: TP-1508's history replayed against the watcher. The ticket sat in QA while dispatch was
  paused; its PR began to conflict with main; it moved to CI Fix with no run; dispatch resumed and
  the first read had GitHub's mergeability `unknown`, then `dirty` again. The watcher never sends it
  back to QA on that, the conflict fix stays pending until a CI Fix run ends, the counter reads runs
  that ended, and the orchestrator may start the fix run all along. A fix run a restart cut short
  starts again on the same head, as an attempt that did not count.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrWatch
  alias SymphonyElixir.PrWatchParity, as: Parity
  alias SymphonyElixirWeb.ObservabilityPubSub

  @interval_ms 30_000

  setup do
    start_supervised!(Parity)
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    write_workflow_file!(Workflow.workflow_file_path(), pr_review_mode: "polling", ci: %{enabled: true, log_excerpt_lines: 20})
    :ok
  end

  defp tick!(pid, changes) do
    Parity.change!(changes)
    Parity.advance!(@interval_ms)
    Parity.tick!(pid)
  end

  defp decision, do: Parity.watch("1").decision
  defp attempts, do: Parity.watch("1").attempts
  defp ci_fix_gate, do: PrWatch.dispatch_reason(%Issue{id: Parity.issue_id("1"), state: Parity.state("1"), repo_key: "default"}, Config.settings!())

  test "paused in QA, conflict found, moved to CI Fix with no run, resumed on an unknown reading, then dirty: R25 never applies, the fix stays due" do
    Parity.tickets!(%{tickets: [{"1", "QA", []}]})
    pid = Parity.start!()
    Parity.tick!(pid)
    assert %{rule: "R27"} = decision()

    # The PR conflicts with main: the watcher sends the ticket to CI Fix for conflict fix run 1 of 3.
    tick!(pid, [{"1", mergeable: :dirty}])
    assert Parity.state("1") == "CI Fix"
    assert %{rule: "R14", kind: :ci_fix, outcome: :applied, reason: "PR #1 conflicts with main: conflict fix run 1 of 3"} = decision()
    assert %{conflict: 0, pending: %{cause: :conflict, head_sha: "head-1-1"}} = attempts()

    # Dispatch is paused, so no run starts. The next reads keep the decision as it is, its run due.
    :ok = ObservabilityPubSub.subscribe_ticket_records()
    tick!(pid, [])
    assert %{rule: "R14", kind: :ci_fix, outcome: :recorded, reason: "PR #1 conflicts with main: conflict fix run 1 of 3"} = decision()
    assert ci_fix_gate() == nil
    # The watcher tells the orchestrator again while the run is due and none started.
    assert_receive {:ticket_record, "default", "issue-1", :changed, [:pr_watch]}

    # Dispatch resumes: GitHub's first read after the long pause has not computed the mergeability.
    tick!(pid, [{"1", mergeable: :unknown, ci: :green}])
    assert Parity.state("1") == "CI Fix"
    assert %{rule: "R16", kind: :wait, owner: :github} = decision()
    # The pending fix still lets the CI Fix run start.
    assert ci_fix_gate() == nil
    refute Enum.any?(Parity.watch("1").actions, &(&1.rule == "R25"))

    # Then the conflict again, on the same head: the same decision, still run 1 of 3.
    tick!(pid, [{"1", mergeable: :dirty}])
    assert Parity.state("1") == "CI Fix"
    assert %{rule: "R14", kind: :ci_fix, reason: "PR #1 conflicts with main: conflict fix run 1 of 3"} = decision()
    assert %{conflict: 0, pending: %{head_sha: "head-1-1"}} = attempts()

    # A restart cuts its fix run short: started, never ended. The next read starts it again on the
    # same head, an attempt that did not count.
    Parity.record_fix_run!("1", ended: false)
    tick!(pid, [])
    assert %{rule: "R14", reason: "PR #1 conflicts with main: conflict fix run 1 of 3"} = decision()
    assert %{conflict: 0, pending: %{}} = attempts()
    assert ci_fix_gate() == nil

    # So does a run a usage limit ended uncounted.
    Parity.record_fix_run!("1", counted: false)
    tick!(pid, [])
    assert %{conflict: 0, pending: %{}} = attempts()

    # The fix run resolves the conflict and pushes: once it ended, its count is spent, and the green,
    # conflict-free head goes back to QA with its approvals.
    Parity.change!([{"1", head_sha: "head-1-2", mergeable: :clean, ci: :pending}])
    Parity.record_fix_run!("1")
    tick!(pid, [])
    assert %{conflict: 1, pending: nil} = attempts()
    assert Parity.state("1") == "CI Fix"

    tick!(pid, [{"1", ci: :green}])
    assert %{rule: "R25", kind: :return_to_origin} = decision()
    assert Parity.state("1") == "QA"

    # The whole way, nothing applied R25 on the conflicting head.
    refute Enum.any?(Parity.watch("1").actions, &(&1.rule == "R25" and &1.head_sha == "head-1-1"))
    ExUnit.Callbacks.stop_supervised!({SymphonyElixir.PrWatch.Repo, "default"})
  end

  test "a ticket sent back to QA before its conflict fix ran is sent to CI Fix again on the same head" do
    Parity.tickets!(%{tickets: [{"1", "QA", [mergeable: :dirty]}]})
    pid = Parity.start!()
    Parity.tick!(pid)
    assert Parity.state("1") == "CI Fix"

    # Something moves it back to QA on the same head, its fix never run: R14 is applied again, not only recorded.
    Parity.move!("1", "QA")
    tick!(pid, [])
    assert %{rule: "R14", outcome: :applied, reason: "PR #1 conflicts with main: conflict fix run 1 of 3"} = decision()
    assert Parity.state("1") == "CI Fix"
    ExUnit.Callbacks.stop_supervised!({SymphonyElixir.PrWatch.Repo, "default"})
  end
end
