defmodule SymphonyElixir.Dispatch.SettleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Dispatch.Settle
  alias SymphonyElixir.Linear.Issue

  @now ~U[2026-11-03 12:43:10Z]
  @settle_ms 5_000

  defp issue(created_at), do: %Issue{id: "new", identifier: "TP-1", state: "Todo", created_at: created_at}

  test "a ticket created within the settle waits; an older one, one with no creation, or no settle does not" do
    assert Settle.pending?(Settle.new(), issue(DateTime.add(@now, -1, :second)), @now, @settle_ms)
    # A Linear clock ahead of ours still reads as new.
    assert Settle.pending?(Settle.new(), issue(DateTime.add(@now, 2, :second)), @now, @settle_ms)
    refute Settle.pending?(Settle.new(), issue(DateTime.add(@now, -5, :second)), @now, @settle_ms)
    refute Settle.pending?(Settle.new(), issue(nil), @now, @settle_ms)
    refute Settle.pending?(Settle.new(), issue(@now), @now, 0)
    refute Settle.pending?(Settle.new(), %{id: "new", created_at: @now}, @now, @settle_ms)
  end

  test "the settle ends at the ticket's creation plus the settle, within zero and the settle" do
    assert Settle.delay_ms(issue(DateTime.add(@now, -1, :second)), @now, @settle_ms) == 4_000
    assert Settle.delay_ms(issue(DateTime.add(@now, -9, :second)), @now, @settle_ms) == 0
    assert Settle.delay_ms(issue(DateTime.add(@now, 9, :second)), @now, @settle_ms) == @settle_ms
    assert Settle.delay_ms(issue(nil), @now, @settle_ms) == @settle_ms
  end

  test "a settling ticket stays pending until its settle finishes, once" do
    new = issue(DateTime.add(@now, -1, :second))
    timer = make_ref()
    settle = Settle.start(Settle.new(), new, timer, "symphony")

    assert Settle.settling?(settle, "new")
    assert Settle.pending?(settle, new, @now, @settle_ms)

    assert {:settling, %{timer: ^timer, repo_key: "symphony"}, settled} = Settle.finish(settle, "new")
    refute Settle.settling?(settled, "new")
    refute Settle.pending?(settled, new, @now, @settle_ms)
    assert Settle.finish(settled, "new") == :not_settling
    assert Settle.finish(Settle.new(), "other") == :not_settling
  end

  test "pruning drops a settled ticket once past the settle and keeps a settling one" do
    created_at = DateTime.add(@now, -1, :second)
    settling = Settle.start(Settle.new(), %{issue(created_at) | id: "settling"}, make_ref(), nil)
    {:settling, _entry, both} = Settle.finish(Settle.start(settling, issue(created_at), make_ref(), nil), "new")

    assert Map.keys(Settle.prune(both, @now, @settle_ms)) == ["new", "settling"]
    assert Map.keys(Settle.prune(both, DateTime.add(@now, 10, :second), @settle_ms)) == ["settling"]
  end

  test "a run is starting until its agent session starts" do
    assert Settle.starting?(%{session_id: nil})
    assert Settle.starting?(%{})
    refute Settle.starting?(%{session_id: "thread-1"})
    refute Settle.starting?(nil)
  end
end
