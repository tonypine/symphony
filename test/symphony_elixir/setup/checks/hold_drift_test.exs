defmodule SymphonyElixir.Setup.Checks.HoldDriftTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hold.Drift
  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.Checks.HoldDrift

  @t0 ~U[2026-10-19 21:00:00Z]

  defp check(now \\ @t0), do: Setup.check(checks: [HoldDrift], now: fn -> now end)

  defp poll(issue_id, drift, ticket \\ %{}), do: Drift.record("app", issue_id, drift, ticket, @t0)

  test "names itself and reads no Linear" do
    assert HoldDrift.id() == "hold_drift"
    assert HoldDrift.title() == "Hold labels that don't match their holds"
    refute HoldDrift.needs_linear?()
  end

  test "drift shows once two checks in a row saw it, naming the ticket with a details line" do
    poll("i1", {:stray_label, :blocked}, %{identifier: "TP-1", url: "https://linear.app/t/issue/TP-1"})
    assert %{problems: []} = check()

    poll("i1", {:stray_label, :blocked})
    assert %{problems: [problem]} = check()

    assert problem.id == "hold_drift:app"
    assert problem.severity == "warning"
    assert problem.category == "labels"
    assert problem.title == "TP-1's hold label doesn't match its hold (app)"
    assert problem.consequence =~ "Re-sync sets the label from the hold Symphony keeps."
    assert problem.repos == ["app"]
    assert problem.tickets == [%{identifier: "TP-1", url: "https://linear.app/t/issue/TP-1"}]
    assert problem.details == [%{label: "TP-1", value: "Blocked label with no hold, since 2026-10-19 21:00 UTC"}]
    assert problem.fix == %{kind: "linear", action: "resync_hold", repo: "app", tickets: ["TP-1"]}
  end

  test "drift no poll has seen for an hour is dropped, and several tickets share one warning" do
    poll("i1", {:stray_label, :blocked}, %{identifier: "TP-1"})
    check()
    assert %{problems: []} = check(~U[2026-10-19 22:01:00Z])

    poll("i2", {:missing_label, :needs_decision})
    poll("i3", {:stray_label, :needs_decision}, %{identifier: "TP-3"})
    check()

    assert %{problems: [problem]} = check()
    assert problem.title == "2 tickets in app have hold labels that don't match their holds"
    assert problem.tickets == [%{identifier: "TP-3", url: nil}, %{identifier: "i2", url: nil}]
    assert %{label: "i2", value: "Needs Decision hold with no label, since 2026-10-19 21:00 UTC"} in problem.details
    assert problem.fix.tickets == ["TP-3", "i2"]
  end

  test "drift a poll sees put right before the second check never shows" do
    poll("i1", {:stray_label, :blocked})
    check()
    poll("i1", :ok)

    assert %{problems: []} = check()
  end
end
