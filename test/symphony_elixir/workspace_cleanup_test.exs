defmodule SymphonyElixir.WorkspaceCleanupTest do
  use SymphonyElixir.TestSupport

  # Each removal tells the test it started and blocks until the test releases it.
  defp start_cleanup!(opts \\ []) do
    test_pid = self()

    remove_fun = fn issue, worker_host ->
      send(test_pid, {:removing, issue.identifier, worker_host, self()})

      receive do
        :release -> :ok
        :crash -> exit(:boom)
      end
    end

    name = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
    start_supervised!({WorkspaceCleanup, Keyword.merge([name: name, remove_fun: remove_fun], opts)})
    name
  end

  defp await_async(identifier, server) do
    Task.async(fn -> WorkspaceCleanup.await(identifier, server) end)
  end

  test "remove returns at once and await waits until the removal ends" do
    server = start_cleanup!()

    assert :ok = WorkspaceCleanup.remove(%{id: "issue-1", identifier: "MT-1"}, "worker-01", server)
    assert_receive {:removing, "MT-1", "worker-01", removal}

    waiter = await_async("MT-1", server)
    refute Task.yield(waiter, 50)
    assert :ok = WorkspaceCleanup.await("MT-OTHER", server)
    assert :ok = WorkspaceCleanup.await(nil, server)

    send(removal, :release)
    assert :ok = Task.await(waiter)
    assert :ok = WorkspaceCleanup.await("MT-1", server)
  end

  test "removals of one issue run one after the other and a duplicate queued one is dropped" do
    server = start_cleanup!()

    assert :ok = WorkspaceCleanup.remove(%{identifier: "MT-2"}, nil, server)
    assert_receive {:removing, "MT-2", nil, first}

    assert :ok = WorkspaceCleanup.remove(%{identifier: "MT-2"}, nil, server)
    assert :ok = WorkspaceCleanup.remove(%{identifier: "MT-2"}, nil, server)
    refute_receive {:removing, "MT-2", _worker_host, _removal}, 50

    waiter = await_async("MT-2", server)
    send(first, :release)
    assert_receive {:removing, "MT-2", nil, second}
    refute Task.yield(waiter, 50)

    send(second, :release)
    assert :ok = Task.await(waiter)
    refute_receive {:removing, "MT-2", _worker_host, _removal}, 50
  end

  test "removals past the concurrency cap wait for a free slot" do
    server = start_cleanup!(max_concurrent: 1)

    assert :ok = WorkspaceCleanup.remove(%{identifier: "MT-3"}, nil, server)
    assert :ok = WorkspaceCleanup.remove(%{identifier: "MT-4"}, nil, server)
    assert_receive {:removing, "MT-3", nil, first}
    refute_receive {:removing, "MT-4", _worker_host, _removal}, 50

    waiter = await_async("MT-4", server)
    send(first, :release)
    assert_receive {:removing, "MT-4", nil, second}
    refute Task.yield(waiter, 50)

    send(second, :release)
    assert :ok = Task.await(waiter)
  end

  test "a removal that crashes is logged and releases its waiters" do
    server = start_cleanup!()

    assert :ok = WorkspaceCleanup.remove(%{id: "issue-5", identifier: "MT-5"}, nil, server)
    assert_receive {:removing, "MT-5", nil, removal}
    waiter = await_async("MT-5", server)

    log =
      capture_log(fn ->
        send(removal, :crash)
        assert :ok = Task.await(waiter)
      end)

    assert log =~ ~s(Workspace cleanup failed: issue_id="issue-5" issue_identifier=MT-5 worker_host=nil reason=:boom)
  end

  test "a removal whose task cannot start is logged and dropped" do
    server = start_cleanup!(task_supervisor: Module.concat(__MODULE__, MissingTaskSupervisor))

    log =
      capture_log(fn ->
        assert :ok = WorkspaceCleanup.remove(%{identifier: "MT-6"}, "worker-01", server)
        assert :ok = WorkspaceCleanup.await("MT-6", server)
      end)

    assert log =~ ~s(Failed to start workspace cleanup: issue_id=nil issue_identifier=MT-6 worker_host="worker-01" reason={:noproc)
    refute_received {:removing, "MT-6", _worker_host, _removal}
  end

  test "ignores messages it does not track" do
    server = start_cleanup!()

    send(server, :unexpected)
    assert :ok = WorkspaceCleanup.await("MT-7", server)
  end

  test "without the server, remove removes inline and await returns at once" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-workspace-cleanup-inline-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    workspace = Path.join([workspace_root, "default", "MT-8"])
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    missing = Module.concat(__MODULE__, MissingServer)
    assert :ok = WorkspaceCleanup.remove(%{identifier: "MT-8"}, nil, missing)
    refute File.exists?(workspace)
    assert :ok = WorkspaceCleanup.await("MT-8", missing)
  end
end
