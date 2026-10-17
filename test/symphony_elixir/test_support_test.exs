defmodule SymphonyElixir.TestSupportTest do
  use SymphonyElixir.TestSupport

  describe "stop_leftover_work/0" do
    test "stops a task left under the shared task supervisor" do
      {:ok, pid} = Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn -> Process.sleep(:infinity) end)
      ref = Process.monitor(pid)

      assert :ok = SymphonyElixir.TestSupport.stop_leftover_work()

      assert_received {:DOWN, ^ref, :process, ^pid, _reason}
      assert Task.Supervisor.children(SymphonyElixir.TaskSupervisor) == []
    end

    test "lets a task that ends within the grace period finish" do
      test_pid = self()

      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        Process.sleep(50)
        send(test_pid, :finished)
      end)

      assert :ok = SymphonyElixir.TestSupport.stop_leftover_work()
      assert_received :finished
    end

    test "starts WorkspaceCleanup again empty when a removal is still running" do
      test_root = Path.join(System.tmp_dir!(), "symphony-test-support-cleanup-#{System.unique_integer([:positive])}")
      hook_log = Path.join(test_root, "hooks.log")
      File.mkdir_p!(Path.join([test_root, "workspaces", "default", "S-1"]))
      on_exit(fn -> File.rm_rf(test_root) end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: Path.join(test_root, "workspaces"),
        hook_before_remove: """
        echo remove-started >> #{hook_log}
        sleep 30
        echo remove-finished >> #{hook_log}
        """
      )

      cleanup = Process.whereis(WorkspaceCleanup)
      assert :ok = WorkspaceCleanup.remove(%{id: "issue-1", identifier: "S-1"}, nil)
      assert :ok = WorkspaceCleanup.remove(%{id: "issue-2", identifier: "S-2"}, nil)
      wait_until(fn -> File.exists?(hook_log) end)

      assert :ok = SymphonyElixir.TestSupport.stop_leftover_work()

      restarted = Process.whereis(WorkspaceCleanup)
      assert is_pid(restarted) and restarted != cleanup
      assert %{running: running, queue: []} = :sys.get_state(restarted)
      assert running == %{}
      assert :ok = WorkspaceCleanup.await("S-1")
      assert File.read!(hook_log) == "remove-started\n"
    end

    test "leaves an idle WorkspaceCleanup running" do
      cleanup = Process.whereis(WorkspaceCleanup)
      {:ok, _pid} = Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn -> Process.sleep(:infinity) end)

      assert :ok = SymphonyElixir.TestSupport.stop_leftover_work()
      assert Process.whereis(WorkspaceCleanup) == cleanup
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)
    end
  end
end
