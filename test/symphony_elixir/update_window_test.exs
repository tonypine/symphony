defmodule SymphonyElixir.UpdateWindowTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.UpdateWindow

  @t0 ~U[2026-11-21 14:00:00Z]

  defp at(minutes), do: DateTime.add(@t0, round(minutes * 60), :second)

  test "the numbers are fixed: 15 minutes of waiting, runs younger than 3 minutes, a hold of 10 minutes" do
    assert UpdateWindow.wait_ms() == 15 * 60_000
    assert UpdateWindow.recent_ms() == 3 * 60_000
    assert UpdateWindow.hold_ms() == 10 * 60_000
  end

  test "an update ready holds dispatch at the first moment no agent run is active, and not before" do
    window = UpdateWindow.arm(nil, "0.0.1.1053", at(0))
    assert {:none, %{phase: :waiting} = window} = UpdateWindow.decide(window, [at(0)], at(1))
    assert {:hold, %{phase: :holding, holding_since: holding_since}} = UpdateWindow.decide(window, [], at(2))
    assert holding_since == at(2)
  end

  test "with runs always active it holds after the wait, but never while a run that began recently is active" do
    window = UpdateWindow.arm(nil, "0.0.1.1053", at(0))

    assert {:none, _window} = UpdateWindow.decide(window, [at(-30)], at(14.9))
    # A run began 2 minutes ago: the hold waits for it to age.
    assert {:none, window} = UpdateWindow.decide(window, [at(-30), at(14)], at(16))
    assert {:hold, %{phase: :holding}} = UpdateWindow.decide(window, [at(-30), at(14)], at(17))
  end

  test "a hold that reaches its limit with runs active is lifted and the wait starts again; with none left the update is called off" do
    {:hold, holding} = UpdateWindow.decide(UpdateWindow.arm(nil, "0.0.1.1053", at(0)), [at(-30)], at(15))

    assert {:none, ^holding} = UpdateWindow.decide(holding, [at(-30)], at(24.9))
    assert {:lift, %{phase: :waiting, wait_from: wait_from, holding_since: nil} = waiting} = UpdateWindow.decide(holding, [at(-30)], at(25))
    assert wait_from == at(25)
    assert {:none, _waiting} = UpdateWindow.decide(waiting, [at(-30)], at(39))
    assert {:hold, _holding} = UpdateWindow.decide(waiting, [at(-30)], at(40))

    assert {:disarm, nil} = UpdateWindow.decide(holding, [], at(25))
  end

  test "a newer version replaces the target and keeps the time waited and the hold; an older or the same one changes nothing" do
    window = UpdateWindow.arm(nil, "0.0.1.1053", at(0))
    newer = UpdateWindow.arm(window, "0.0.1.1054", at(5))
    assert %{version: "0.0.1.1054", ready_at: ready_at, wait_from: wait_from, phase: :waiting} = newer
    assert ready_at == at(0) and wait_from == at(0)
    assert UpdateWindow.arm(newer, "0.0.1.1053", at(6)) == newer
    assert UpdateWindow.arm(newer, "0.0.1.1054", at(6)) == newer

    {:hold, holding} = UpdateWindow.decide(newer, [], at(7))
    assert %{version: "0.0.1.1056", phase: :holding} = UpdateWindow.arm(holding, "0.0.1.1056", at(8))
  end

  test "the Director's Resume during a hold sends the update back to waiting; nothing else changes" do
    {:hold, holding} = UpdateWindow.decide(UpdateWindow.arm(nil, "0.0.1.1053", at(0)), [], at(1))
    assert %{phase: :waiting, wait_from: wait_from} = UpdateWindow.lifted(holding, at(3))
    assert wait_from == at(3)

    waiting = UpdateWindow.arm(nil, "0.0.1.1053", at(0))
    assert UpdateWindow.lifted(waiting, at(3)) == waiting
    assert UpdateWindow.lifted(nil, at(3)) == nil
    assert UpdateWindow.decide(nil, [], at(3)) == {:none, nil}
  end

  test "status reports the update for the state payload, nil when none is ready" do
    assert UpdateWindow.status(nil) == nil

    assert UpdateWindow.status(UpdateWindow.arm(nil, "0.0.1.1053", at(0))) ==
             %{version: "0.0.1.1053", phase: :waiting, ready_at: at(0), holding_since: nil}
  end

  test "version? takes a release's version only" do
    assert UpdateWindow.version?("0.0.1.1053")
    refute UpdateWindow.version?("1053")
    refute UpdateWindow.version?("v0.0.1")
    refute UpdateWindow.version?(nil)
  end
end
