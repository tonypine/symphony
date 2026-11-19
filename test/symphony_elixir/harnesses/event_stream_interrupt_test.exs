defmodule SymphonyElixir.Harnesses.EventStreamInterruptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Harnesses.EventStream

  defp port(seconds) do
    Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, {:line, 1024}, args: ["-c", "sleep #{seconds}"]])
  end

  defp read(port, run_id), do: EventStream.read(port, fn _event -> :ok end, 10_000, 0, parse: fn _line -> nil end, run_id: run_id, label: "Test")

  test "the Conductor's interrupt for the turn's run ends the turn with its session, the process stopped" do
    port = port(30)
    send(self(), {:conductor_interrupt, "run-1", System.monotonic_time(:millisecond)})

    assert read(port, "run-1") == {:error, {:conductor_interrupted, nil}}
    assert Port.info(port) == nil
  end

  test "an interrupt that waited past a turn, or names another run, does not end this one" do
    port = port(0.2)
    send(self(), {:conductor_interrupt, "run-1", System.monotonic_time(:millisecond) - 60_000})
    send(self(), {:conductor_interrupt, "run-2", System.monotonic_time(:millisecond)})

    # The process ended on its own, with no result line: the turn was not interrupted.
    assert read(port, "run-1") == {:error, :no_result_event}
    assert_received {:conductor_interrupt, "run-2", _sent_ms}
  end

  test "a turn that names no run is never interrupted" do
    port = port(0.2)
    send(self(), {:conductor_interrupt, nil, System.monotonic_time(:millisecond)})
    assert read(port, nil) == {:error, :no_result_event}
  end
end
