defmodule SymphonyElixir.DescriptionLockTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DescriptionLock

  test "one write of an issue's description at a time; and another issue's does not wait" do
    test = self()

    holder =
      Task.async(fn ->
        DescriptionLock.locked("issue-lock-1", fn ->
          send(test, :held)

          receive do
            :release -> :first
          end
        end)
      end)

    assert_receive :held
    waiting = Task.async(fn -> DescriptionLock.locked("issue-lock-1", fn -> :second end) end)
    assert Task.yield(waiting, 100) == nil
    assert DescriptionLock.locked("issue-lock-2", fn -> :other end) == :other

    send(holder.pid, :release)
    assert Task.await(holder) == :first
    assert Task.await(waiting) == :second
  end
end
