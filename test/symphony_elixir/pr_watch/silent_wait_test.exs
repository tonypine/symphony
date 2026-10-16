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

  test "a quiet ticket counts its ticks from when it went quiet, and is listed from the second" do
    first = SilentWait.check(watch(decision(%{})), ctx())
    refute SilentWait.listed?(first)

    later = DateTime.add(@now, @interval, :millisecond)
    second = SilentWait.check(watch(decision(decided_at: later)), ctx(now: later, previous: first))
    assert %{since: @now, ticks: 2} = second
    assert SilentWait.listed?(second)

    refute SilentWait.listed?(nil)
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
