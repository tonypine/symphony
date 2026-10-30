defmodule SymphonyElixir.QaDriver.DevServerLeaseTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.QaDriver.DevServerLease

  @key {"qa@qa-vm", 8090}

  setup do
    name = :"dev_server_lease_test_#{System.unique_integer([:positive])}"
    start_supervised!({DevServerLease, name: name})
    %{lease: name}
  end

  # A QA driver stand-in: a process that holds a lease until the test stops it.
  defp owner do
    pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp holder(owner, ticket), do: %{pid: owner, issue_id: "id-" <> ticket, ticket: ticket}

  # Asks for the lease in a task of its own, which reports when it got it.
  defp acquire_async(lease, holder, opts \\ []) do
    test = self()

    Task.async(fn ->
      :ok = DevServerLease.acquire(lease, @key, holder, opts)
      send(test, {:granted, holder.ticket})
    end)
  end

  defp await_waiting(lease, issue_id, tries \\ 250) do
    cond do
      DevServerLease.waiting(lease, issue_id) -> :ok
      tries > 0 -> Process.sleep(10) && await_waiting(lease, issue_id, tries - 1)
      true -> flunk("#{issue_id} never queued")
    end
  end

  defp stop_owner(pid) do
    monitor = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
  end

  test "the first pass takes the lease; the next ones wait in turn and get it as each gives it back", %{lease: lease} do
    first = owner()
    assert DevServerLease.acquire(lease, @key, holder(first, "TP-1")) == :ok
    # The holder's driver asking again gets it again.
    assert DevServerLease.acquire(lease, @key, holder(first, "TP-1")) == :ok
    # Another key is another lease.
    assert DevServerLease.acquire(lease, {"qa@qa-vm", 8091}, holder(owner(), "TP-9")) == :ok

    {second, third} = {owner(), owner()}

    log =
      capture_log(fn ->
        # TP-3 asks only once TP-2 waits, so the queue's order is TP-2 then TP-3.
        second_task = acquire_async(lease, holder(second, "TP-2"))
        await_waiting(lease, "id-TP-2")
        tasks = [second_task, acquire_async(lease, holder(third, "TP-3"))]
        await_waiting(lease, "id-TP-3")
        assert DevServerLease.waiting(lease, "id-TP-3") == %{worker_host: "qa@qa-vm", port: 8090, held_by: "TP-1"}
        assert DevServerLease.waiting(lease, "id-TP-1") == nil
        refute_received {:granted, _ticket}

        assert DevServerLease.release(lease, first) == :ok
        assert_receive {:granted, "TP-2"}
        assert DevServerLease.waiting(lease, "id-TP-3") == %{worker_host: "qa@qa-vm", port: 8090, held_by: "TP-2"}
        refute_received {:granted, "TP-3"}

        # A driver that exits gives the lease back as a release does.
        stop_owner(second)
        assert_receive {:granted, "TP-3"}
        Enum.each(tasks, &Task.await/1)

        assert DevServerLease.release(lease, third) == :ok
      end)

    assert log =~ "QA dev server lease busy: TP-2 waits worker_host=qa@qa-vm port=8090 held_by=TP-1"
    assert log =~ "QA dev server lease passed from TP-1 to TP-2 worker_host=qa@qa-vm port=8090"
    assert log =~ "QA dev server lease passed from TP-2 to TP-3"
    assert log =~ "QA dev server lease released by TP-3 worker_host=qa@qa-vm port=8090"
    assert DevServerLease.acquire(lease, @key, holder(owner(), "TP-4")) == :ok
  end

  test "a waiting pass whose driver exits or releases leaves the queue", %{lease: lease} do
    first = owner()
    assert DevServerLease.acquire(lease, @key, holder(first, "TP-1")) == :ok
    {gone, released, next} = {owner(), owner(), owner()}

    capture_log(fn ->
      _gone = acquire_async(lease, holder(gone, "TP-2"))
      _released = acquire_async(lease, holder(released, "TP-3"))
      task = acquire_async(lease, holder(next, "TP-4"))
      Enum.each(["id-TP-2", "id-TP-3", "id-TP-4"], &await_waiting(lease, &1))

      stop_owner(gone)
      assert DevServerLease.release(lease, released) == :ok
      assert DevServerLease.waiting(lease, "id-TP-2") == nil
      assert DevServerLease.waiting(lease, "id-TP-3") == nil

      assert DevServerLease.release(lease, first) == :ok
      assert_receive {:granted, "TP-4"}
      Task.await(task)
    end)

    refute_received {:granted, "TP-2"}
    refute_received {:granted, "TP-3"}
  end

  test "a waiting pass beats its heartbeat until it gets the lease", %{lease: lease} do
    first = owner()
    assert DevServerLease.acquire(lease, @key, holder(first, "TP-1")) == :ok
    test = self()

    capture_log(fn ->
      task = acquire_async(lease, holder(owner(), "TP-2"), heartbeat: fn -> send(test, :heartbeat) end, heartbeat_ms: 5)
      assert_receive :heartbeat
      assert_receive :heartbeat
      DevServerLease.release(lease, first)
      assert_receive {:granted, "TP-2"}
      Task.await(task)
    end)
  end

  test "without the manager a pass goes ahead, and nothing waits", %{lease: lease} do
    first = owner()
    assert DevServerLease.acquire(lease, @key, holder(first, "TP-1")) == :ok

    log =
      capture_log(fn ->
        task = acquire_async(lease, holder(owner(), "TP-2"), heartbeat_ms: 60_000)
        await_waiting(lease, "id-TP-2")
        # The manager goes down while TP-2 waits: TP-2 starts without a lease.
        stop_supervised!(DevServerLease)
        assert_receive {:granted, "TP-2"}
        Task.await(task)

        assert DevServerLease.acquire(lease, @key, holder(owner(), "TP-3")) == :ok
      end)

    assert log =~ "QA dev server lease manager went down while TP-2 waited worker_host=qa@qa-vm port=8090"
    assert log =~ "QA dev server lease manager is not running; TP-3 starts its server without a lease worker_host=qa@qa-vm port=8090"
    assert DevServerLease.release(lease, first) == :ok
    assert DevServerLease.waiting(lease, "id-TP-2") == nil
  end

  test "reason/1 is the orchestrator's dispatch reason for a waiting pass" do
    assert DevServerLease.reason(%{worker_host: "admin@qa-vm", port: 8090, held_by: "TP-1124"}) ==
             "waiting for the QA host's dev server port: 8090 on admin@qa-vm is held by TP-1124's QA pass"

    assert DevServerLease.reason(%{worker_host: "admin@qa-vm", port: 8090, held_by: nil}) =~ "is held by another ticket's QA pass"
  end
end
