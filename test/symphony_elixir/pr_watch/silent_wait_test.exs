defmodule SymphonyElixir.PrWatch.SilentWaitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PrWatch.SilentWait

  @now ~U[2026-10-16 12:00:00Z]
  @interval 30_000
  @ci_wait 1_800_000

  defp ctx(attrs \\ %{}), do: Map.merge(%{run: :none, hold: :none, now: @now, interval_ms: @interval, ci_wait_ms: @ci_wait, previous: nil}, Map.new(attrs))

  defp ago(ms), do: DateTime.add(@now, -ms, :millisecond)

  defp watch(decision, attrs \\ %{}), do: Map.merge(%{decision: decision, github: :ok}, Map.new(attrs))

  defp decision(attrs) do
    Map.merge(%{rule: "R26", kind: :dispatch, owner: nil, clears_when: nil, decided_at: @now, since: @now}, Map.new(attrs))
  end

  defp wait(owner, attrs \\ %{}), do: decision(Map.merge(%{rule: "R24", kind: :wait, owner: owner, clears_when: "the checks report"}, Map.new(attrs)))

  test "a ticket with a run or a hold is never silent" do
    assert SilentWait.check(watch(nil), ctx(run: :active)) == nil
    assert SilentWait.check(watch(nil), ctx(hold: :needs_decision)) == nil
    assert SilentWait.check(watch(nil), ctx(hold: :blocked)) == nil
  end

  test "a fresh wait with an owner and a clearing condition is a reason" do
    for owner <- [:agent, :person, :symphony, :ci, :github] do
      assert SilentWait.check(watch(wait(owner)), ctx()) == nil
    end
  end

  test "a ticket with no decision, a stale one, or one that leaves it waiting on nobody is quiet" do
    assert SilentWait.check(nil, ctx()) == %{since: @now, ticks: 1, bound: nil, reason: "the watcher has no decision on it"}
    assert SilentWait.check(watch(nil), ctx()).reason == "the watcher has no decision on it"

    stale = wait(:person, decided_at: ago(2 * @interval))
    assert SilentWait.check(watch(stale), ctx()).reason == "the watcher's last decision (R24) is older than two ticks"
    assert SilentWait.check(watch(%{stale | decided_at: nil}), ctx()).reason == "the watcher's last decision (R24) is older than two ticks"

    # A wait without its owner or clearing condition reads as no wait.
    assert SilentWait.check(watch(wait(:person, clears_when: "")), ctx()).reason =~ "R24 decided `wait`"
    assert SilentWait.check(watch(wait(:nobody)), ctx()).reason =~ "R24 decided `wait`"
    assert SilentWait.check(watch(%{rule: "R0", kind: :dispatch, decided_at: @now}), ctx()).reason =~ "R0 decided `dispatch`"

    assert %{ticks: 1, bound: nil, reason: "R26 decided `dispatch`, but no run started and no wait is recorded"} =
             SilentWait.check(watch(decision(%{})), ctx())
  end

  test "an upkeep GitHub refused on the head makes a waiting ticket quiet, whatever it waits on, until a read has none" do
    update = %{rule: "U1", kind: :update_branch, head_sha: "head-1", error: ":forbidden", at: @now}
    rerun = %{update | rule: "U2", kind: :rerun_failed, error: "{:rerun_failed, \"77\", :gone}"}

    cases = [{update, wait(:symphony, rule: "R28")}, {update, wait(:person, rule: "R18")}, {rerun, wait(:ci, rule: "R19")}]

    for {failure, decision} <- cases do
      first = SilentWait.check(watch(decision, head_sha: "head-1", upkeep_failure: failure), ctx())
      assert %{ticks: 1, bound: nil} = first
      refute SilentWait.listed?(first)

      later = DateTime.add(@now, @interval, :millisecond)
      second = SilentWait.check(watch(%{decision | decided_at: later}, head_sha: "head-1", upkeep_failure: failure), ctx(now: later, previous: first))
      assert %{since: @now, ticks: 2} = second
      assert SilentWait.listed?(second)
    end

    assert SilentWait.check(watch(wait(:symphony), head_sha: "head-1", upkeep_failure: update), ctx()).reason ==
             "U1 `update_branch` failed on the head (:forbidden), and only the next read retries it"

    # A failure on another head, none on the read, a run or a hold, or a flow action applied on the
    # tick: no silence from it.
    assert SilentWait.check(watch(wait(:symphony), head_sha: "head-2", upkeep_failure: update), ctx()) == nil
    assert SilentWait.check(watch(wait(:symphony), head_sha: "head-1", upkeep_failure: nil), ctx()) == nil
    assert SilentWait.check(watch(wait(:symphony), head_sha: "head-1", upkeep_failure: update), ctx(run: :active)) == nil
    assert SilentWait.check(watch(wait(:symphony), head_sha: "head-1", upkeep_failure: update), ctx(hold: :needs_decision)) == nil
    moved = decision(rule: "R16", kind: :to_ci_fix, outcome: :applied)
    assert SilentWait.check(watch(moved, head_sha: "head-1", upkeep_failure: update), ctx()) == nil
  end

  test "a quiet ticket counts its ticks from when it went quiet, and is listed from the second" do
    first = SilentWait.check(watch(decision(%{})), ctx())
    refute SilentWait.listed?(first)

    later = DateTime.add(@now, @interval, :millisecond)
    second = SilentWait.check(watch(decision(decided_at: later)), ctx(now: later, previous: first))
    assert %{since: @now, ticks: 2} = second
    assert SilentWait.listed?(second)

    refute SilentWait.listed?(nil)
  end

  test "a ticket the watcher acted on in this tick is moving, not quiet; an action from an earlier tick is no reason" do
    quiet = SilentWait.check(watch(decision(%{})), ctx())

    # Auto-merge armed one interval after the ticket went quiet: no second quiet tick.
    later = DateTime.add(@now, @interval, :millisecond)
    armed = decision(rule: "R30", kind: :arm, outcome: :applied, decided_at: later)
    assert SilentWait.check(watch(armed), ctx(now: later, previous: quiet)) == nil

    # The same decision read again on a later tick, with nothing applied, is quiet.
    assert %{ticks: 1, reason: "R30 decided `arm`, but no run started and no wait is recorded"} =
             SilentWait.check(watch(armed), ctx(now: DateTime.add(later, 1_000, :millisecond)))

    assert %{ticks: 1} = SilentWait.check(watch(decision(outcome: :recorded)), ctx())
  end

  test "extra polls inside one poll interval add no quiet tick" do
    first = SilentWait.check(watch(decision(%{})), ctx())

    # A Check Now or a webhook poll seconds after the first stays unlisted.
    soon = DateTime.add(@now, 5_000, :millisecond)
    second = SilentWait.check(watch(decision(%{})), ctx(now: soon, previous: first))
    assert %{since: @now, ticks: 1} = second
    refute SilentWait.listed?(second)

    almost = DateTime.add(@now, @interval - 1, :millisecond)
    third = SilentWait.check(watch(decision(%{})), ctx(now: almost, previous: second))
    assert %{since: @now, ticks: 1} = third
    refute SilentWait.listed?(third)

    # A full interval after it went quiet, it is the second quiet tick.
    later = DateTime.add(@now, @interval, :millisecond)
    assert %{since: @now, ticks: 2} = fourth = SilentWait.check(watch(decision(%{})), ctx(now: later, previous: third))
    assert SilentWait.listed?(fourth)
  end

  test "a wait on CI is silent once it outlives ci.merging_wait_timeout_ms" do
    assert SilentWait.check(watch(wait(:ci, since: ago(@ci_wait))), ctx()) == nil

    since = ago(@ci_wait + 1)
    silent = SilentWait.check(watch(wait(:ci, since: since)), ctx())
    assert silent == %{since: since, ticks: 1, bound: "ci.merging_wait_timeout_ms", reason: "R24: CI has been running for more than 30 min"}
    assert SilentWait.listed?(silent)

    # Still past it on the next tick, it keeps counting.
    assert %{since: ^since, ticks: 2} = SilentWait.check(watch(wait(:ci, since: since)), ctx(previous: silent))

    # A decision recorded before it kept `since` counts from when it was decided.
    assert SilentWait.check(watch(wait(:ci) |> Map.delete(:since)), ctx()) == nil
  end

  test "a ticket quiet after a wait past its bound starts a fresh quiet streak" do
    since = ago(@ci_wait + 10 * @interval)
    past_bound = SilentWait.check(watch(wait(:ci, since: since, decided_at: ago(@interval))), ctx(now: ago(@interval)))
    assert %{since: ^since, bound: "ci.merging_wait_timeout_ms"} = past_bound

    # Its wait decision goes stale: quiet from this tick, not from when CI started.
    stale = wait(:ci, since: since, decided_at: ago(2 * @interval))
    assert %{since: @now, ticks: 1, bound: nil} = quiet = SilentWait.check(watch(stale), ctx(previous: past_bound))
    refute SilentWait.listed?(quiet)
  end

  test "a wait on GitHub's rate limit is silent one tick past its reset" do
    rate_limit = wait(:github, rule: "R1", clears_when: "the limit resets")
    assert SilentWait.check(watch(rate_limit, github: {:rate_limited, ago(@interval)}), ctx()) == nil

    reset_at = ago(@interval + 1)

    assert %{bound: "rate_limit_reset", since: ^reset_at, reason: "R1: GitHub's rate limit was due to reset at 2026-10-16T11:59:29Z"} =
             SilentWait.check(watch(rate_limit, github: {:rate_limited, reset_at}), ctx())

    # A wait on GitHub with no reset to pass has no bound.
    assert SilentWait.check(watch(wait(:github, rule: "R16")), ctx()) == nil
    assert SilentWait.check(watch(rate_limit, github: {:rate_limited, nil}), ctx()) == nil
  end
end
