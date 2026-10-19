defmodule SymphonyElixir.Hold.DriftTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hold.Drift

  @t0 ~U[2026-10-19 21:00:00Z]
  @t1 ~U[2026-10-19 21:05:00Z]

  test "a new drift is a change, the same one again is not, and the other way is" do
    assert Drift.record("app", "i1", {:stray_label, :blocked}, %{identifier: "TP-1"}, @t0) == :changed
    assert Drift.record("app", "i1", {:stray_label, :blocked}, %{url: "https://linear.app/t/issue/TP-1"}, @t1) == :unchanged

    assert [%{identifier: "TP-1", url: "https://linear.app/t/issue/TP-1", since: @t0, seen_at: @t1, checks: 0}] = Drift.entries()

    assert Drift.record("app", "i1", {:missing_label, :blocked}, %{}, @t1) == :changed
    assert [%{drift: {:missing_label, :blocked}, since: @t1, identifier: nil}] = Drift.entries()

    assert Drift.record("app", "i1", :ok) == :unchanged
    assert Drift.entries() == []
  end

  test "each check counts the drift, and drops the drift no poll has seen for an hour" do
    Drift.record("app", "i1", {:stray_label, :blocked}, %{identifier: "TP-1"}, @t1)
    Drift.record("app", "i2", {:missing_label, :needs_decision}, %{identifier: "TP-2"}, @t0)

    assert [%{identifier: "TP-2", checks: 1}, %{identifier: "TP-1", checks: 1}] = Drift.observe(@t1)
    assert [%{identifier: "TP-2", checks: 2}, %{identifier: "TP-1", checks: 2}] = Drift.observe(@t1)

    # TP-2 was last seen at 21:00, TP-1 at 21:05.
    assert [%{identifier: "TP-1", checks: 3}] = Drift.observe(~U[2026-10-19 22:02:00Z])
    assert [%{identifier: "TP-1"}] = Drift.entries()
    assert Drift.observe(~U[2026-10-19 23:00:00Z]) == []
    assert Drift.entries() == []
  end

  test "forget and clear drop entries" do
    Drift.record("app", "i1", {:stray_label, :blocked})
    Drift.record("app", "i2", {:stray_label, :blocked})

    assert Drift.forget("app", "i1") == :ok
    assert [%{issue_id: "i2"}] = Drift.entries()
    assert Drift.clear() == :ok
    assert Drift.entries() == []
  end

  test "without its table it keeps nothing and every drift is a change" do
    supervisor = Process.whereis(SymphonyElixir.Supervisor)
    :ok = Supervisor.terminate_child(supervisor, Drift)
    on_exit(fn -> Supervisor.restart_child(supervisor, Drift) end)

    assert Drift.record("app", "i1", {:stray_label, :blocked}) == :changed
    assert Drift.record("app", "i1", {:stray_label, :blocked}) == :changed
    assert Drift.entries() == []
    assert Drift.observe(@t0) == []
    assert Drift.forget("app", "i1") == :ok
    assert Drift.clear() == :ok
  end
end
