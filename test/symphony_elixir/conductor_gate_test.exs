defmodule SymphonyElixir.ConductorGateTest do
  # c9 (TP-1590): Symphony is never stopped for an update or a restart while a Conductor turn is mid-run.
  use ExUnit.Case, async: true

  alias SymphonyElixir.ConductorGate

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})
    gate = start_supervised!({ConductorGate, name: :"gate-#{System.unique_integer([:positive])}", clock: fn -> Agent.get(clock, & &1) end})
    %{gate: gate, clock: clock}
  end

  defp at(%{clock: clock}, ms), do: Agent.update(clock, fn _now -> ms end)

  # A Conductor turn in a process of its own, which ends when told.
  defp turn(gate) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:entered, self(), ConductorGate.enter(gate)})

        receive do
          :end -> ConductorGate.leave(gate)
        end

        send(test, {:left, self()})
      end)

    assert_receive {:entered, ^pid, entered}
    {pid, entered}
  end

  defp end_turn(pid) do
    send(pid, :end)
    assert_receive {:left, ^pid}
  end

  test "with no Conductor turn running the handover is given at once, and no turn starts after it", %{gate: gate} do
    assert ConductorGate.handover(gate) == :ok
    assert ConductorGate.enter(gate) == :closed
    assert ConductorGate.run(gate, fn -> flunk("no turn runs") end) == :closed
    assert ConductorGate.status(gate) == %{running: 0, closed: true}
  end

  test "the handover waits for a turn mid-run, and is given the moment it ends", %{gate: gate} do
    {pid, :ok} = turn(gate)
    assert ConductorGate.status(gate) == %{running: 1, closed: false}
    assert ConductorGate.handover(gate) == {:wait, 1}

    # Turns still start while the wait is short.
    assert ConductorGate.run(gate, fn -> :answered end) == {:ok, :answered}

    end_turn(pid)
    assert ConductorGate.handover(gate) == :ok
    assert ConductorGate.enter(gate) == :closed
  end

  test "a turn whose process ends without leaving no longer holds the handover", %{gate: gate} do
    {pid, :ok} = turn(gate)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert ConductorGate.handover(gate) == :ok
  end

  test "turns that overlap without a gap: after the fixed wait no new one starts, so the handover comes", ctx do
    {first, :ok} = turn(ctx.gate)
    assert ConductorGate.handover(ctx.gate) == {:wait, 1}

    at(ctx, ConductorGate.wait_ms() - 1)
    {second, :ok} = turn(ctx.gate)
    end_turn(first)
    assert ConductorGate.handover(ctx.gate) == {:wait, 1}

    at(ctx, ConductorGate.wait_ms())
    assert {_third, :closed} = turn(ctx.gate)
    end_turn(second)
    assert ConductorGate.handover(ctx.gate) == :ok
  end

  test "a turn already inside enters again from within and counts once", %{gate: gate} do
    assert ConductorGate.run(gate, fn ->
             assert ConductorGate.handover(gate) == {:wait, 1}
             assert ConductorGate.run(gate, fn -> ConductorGate.status(gate) end) == {:ok, %{running: 1, closed: false}}
             ConductorGate.status(gate).running
           end) == {:ok, 1}

    assert ConductorGate.handover(gate) == :ok
  end

  test "a leave from a process that never entered changes nothing", %{gate: gate} do
    assert ConductorGate.leave(gate) == :ok
    assert ConductorGate.status(gate) == %{running: 0, closed: false}
  end

  test "Resume opens the gate again, and so does a stop that never came", ctx do
    assert ConductorGate.handover(ctx.gate) == :ok
    assert ConductorGate.reopen(ctx.gate) == :ok
    assert ConductorGate.enter(ctx.gate) == :ok
    assert ConductorGate.leave(ctx.gate) == :ok

    assert ConductorGate.handover(ctx.gate) == :ok
    at(ctx, ConductorGate.closed_ms() - 1)
    assert ConductorGate.enter(ctx.gate) == :closed
    at(ctx, ConductorGate.closed_ms())
    assert ConductorGate.enter(ctx.gate) == :ok
  end

  test "a wait no one asks about any more is dropped, so turns start freely again", ctx do
    {pid, :ok} = turn(ctx.gate)
    assert ConductorGate.handover(ctx.gate) == {:wait, 1}

    at(ctx, ConductorGate.ask_ms())
    assert ConductorGate.handover(ctx.gate) == {:wait, 1}, "an ask renews the wait"
    at(ctx, ConductorGate.ask_ms() * 2 + ConductorGate.wait_ms())
    assert ConductorGate.run(ctx.gate, fn -> :answered end) == {:ok, :answered}
    end_turn(pid)
  end

  test "a gate that is not running lets every turn through and gives the handover" do
    gate = :"no-gate-#{System.unique_integer([:positive])}"
    assert ConductorGate.enter(gate) == :ok
    assert ConductorGate.run(gate, fn -> :answered end) == {:ok, :answered}
    assert ConductorGate.handover(gate) == :ok
    assert ConductorGate.reopen(gate) == :ok
    assert ConductorGate.status(gate) == %{running: 0, closed: false}
  end

  test "the numbers are fixed" do
    assert ConductorGate.wait_ms() == 120_000
    assert ConductorGate.closed_ms() == 300_000
    assert ConductorGate.ask_ms() == 60_000
  end
end
