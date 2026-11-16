defmodule SymphonyElixir.PrWatch.StalledRunTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Inbox.Item
  alias SymphonyElixir.{Pauses, TicketState}
  alias SymphonyElixir.PrWatch.StalledRun

  @repo "default"
  @id "issue-1"
  @ticket {:ticket, @repo, @id}
  @at ~U[2026-11-16 19:11:00Z]
  @silent %{since: @at, ticks: 2, bound: nil, reason: "R14 decided `ci_fix`, but no run started and no wait is recorded"}
  @fix %{kind: :ci_fix, rule: "R14", args: %{origin: :qa, cause: :conflict}, reason: "PR #915 conflicts with main: conflict fix run 1 of 3"}

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: @id, issue_identifier: "TP-1508", phase: "CI Fix"})
    :ok
  end

  defp watch(decision, overrides \\ %{}), do: Map.merge(%{decision: decision, silent: @silent, head_sha: "51c0d24"}, overrides)
  defp record, do: @id |> RunStore.get_ticket_state() |> TicketState.normalize()

  test "a decision that needs a run, listed silent, pauses the ticket with a reason the Inbox lists" do
    log = capture_log(fn -> assert StalledRun.hold(@ticket, watch(@fix), at: @at) == :held end)
    assert log =~ "pr_watch.run_not_started"

    assert {:ok, %{reasons: [reason]}} = Pauses.get(@ticket)
    assert %{kind: :environment, releasable: true, waits_on: %{condition: "run_not_started", head: "51c0d24"}, set_at: @at} = reason

    assert reason.text ==
             "No run started: R14 decided a conflict fix run (PR #915 conflicts with main: conflict fix run 1 of 3), and no run started on it for two poll cycles"

    assert StalledRun.reason?(reason)
    assert %{kind: :blocked, ask: "No run started: R14" <> _rest} = Item.from_pause(record(), record().pause)
  end

  test "each run kind says which run" do
    runs = [
      {%{kind: :ci_fix, rule: "R21", args: %{cause: :red}, reason: "The `test` check failed"}, "a CI Fix run (The `test` check failed)"},
      {%{kind: :land_agent, rule: "R31", reason: "Branch protection held it"}, "the landing run (Branch protection held it)"},
      {%{kind: :dispatch, rule: "R27", args: %{phase: :qa}, reason: "The head is green"}, "a run (The head is green)"}
    ]

    for {decision, words} <- runs do
      :ok = RunStore.clear()
      :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: @id, issue_identifier: "TP-1508", phase: "QA"})
      capture_log(fn -> assert StalledRun.hold(@ticket, watch(decision, %{head_sha: nil})) == :held end)
      assert {:ok, %{reasons: [%{text: text, waits_on: waits_on}]}} = Pauses.get(@ticket)
      assert text =~ "decided #{words}"
      refute Map.has_key?(waits_on, :head)
    end
  end

  test "nothing is held while the decision is quiet only, waits, or there is no record" do
    assert StalledRun.hold(@ticket, watch(@fix, %{silent: nil})) == :none
    assert StalledRun.hold(@ticket, watch(@fix, %{silent: %{@silent | ticks: 1}})) == :none
    assert StalledRun.hold(@ticket, watch(%{kind: :wait, rule: "R16", owner: :github, reason: "GitHub computes"})) == :none
    assert StalledRun.hold(@ticket, nil) == :none
    assert {:ok, nil} = Pauses.get(@ticket)
  end

  test "a pause the store refuses holds nothing and is logged" do
    log = capture_log(fn -> assert StalledRun.hold({:ticket, @repo, ""}, watch(@fix)) == :none end)
    assert log =~ "Failed to pause a ticket whose run never started"
  end

  test "a new head on the PR lifts the pause; the same head, or another reason, keeps it" do
    capture_log(fn -> :held = StalledRun.hold(@ticket, watch(@fix)) end)

    assert StalledRun.settle(@ticket, record(), %{head_sha: "51c0d24"}) == :kept
    assert StalledRun.settle(@ticket, record(), %{head_sha: nil}) == :kept
    assert StalledRun.settle(@ticket, nil, %{head_sha: "e3f1a90"}) == :kept

    assert StalledRun.settle(@ticket, record(), %{head_sha: "e3f1a90"}) == :lifted
    assert {:ok, nil} = Pauses.get(@ticket)

    # Another reason on the pause is not this one's to lift.
    {:ok, _pause} = Pauses.set(@ticket, %{kind: :environment, waits_on: %{condition: "usage_limit", head: "51c0d24"}, text: "Usage limit"})
    assert StalledRun.settle(@ticket, record(), %{head_sha: "e3f1a90"}) == :kept
    refute StalledRun.reason?(%{kind: :person, waits_on: %{condition: "run_not_started"}})
    assert StalledRun.run_kinds() == [:dispatch, :ci_fix, :land_agent]
  end
end
