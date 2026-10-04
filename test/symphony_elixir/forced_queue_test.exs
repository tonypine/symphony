defmodule SymphonyElixir.ForcedQueueTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AuditLog, ForcedQueue}
  alias SymphonyElixirWeb.Presenter

  @now ~U[2026-10-04 06:00:00.000000Z]

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-forced-#{System.unique_integer([:positive])}")
    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)
    Application.put_env(:symphony_elixir, :audit_log_dir, Path.join(test_root, "audit"))
    {:ok, clock} = Agent.start_link(fn -> @now end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Canceled"],
      workspace_root: Path.join(test_root, "workspaces")
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_issue_states_result)
      Application.put_env(:symphony_elixir, :audit_log_dir, previous_audit_dir)
      File.rm_rf(test_root)
    end)

    %{clock: clock}
  end

  describe "Issue.forced?/2" do
    test "matches the force label case-insensitively outside terminal states" do
      settings = Config.settings!()

      assert Issue.forced?(issue("a", "MT-1", "In Review", ["bug", " Expedite "]), settings)
      refute Issue.forced?(issue("a", "MT-1", "Done", ["expedite"]), settings)
      refute Issue.forced?(issue("a", "MT-1", " canceled ", ["expedite"]), settings)
      refute Issue.forced?(issue("a", "MT-1", "Todo", ["breakdown", :not_a_label]), settings)
      assert Issue.forced?(%{issue("a", "MT-1", "Todo", ["expedite"]) | state: nil}, settings)
      refute Issue.forced?(%{issue("a", "MT-1", "Todo", []) | labels: nil}, settings)
      refute Issue.forced?(%{labels: ["expedite"]}, settings)
    end

    test "uses the configured force label" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", force_label: "Rush")
      settings = Config.settings!()

      assert Issue.forced?(issue("a", "MT-1", "Todo", ["rush"]), settings)
      refute Issue.forced?(issue("a", "MT-1", "Todo", ["expedite"]), settings)
    end
  end

  describe "config" do
    test "defaults and validation" do
      assert %{force_label: "expedite", forced_max: 1, forced_stale_after_hours: 72} = Config.settings!().agent

      for {key, value} <- [forced_max: 0, forced_stale_after_hours: 0] do
        write_workflow_file!(Workflow.workflow_file_path(), [{:tracker_kind, "memory"}, {key, value}])
        assert {:error, {:invalid_workflow_config, message}} = Config.settings()
        assert message =~ Atom.to_string(key)
      end

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", force_label: "")
      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "force_label"
    end
  end

  describe "reconcile/5 and snapshot/1" do
    test "queues forced issues, keeps them while unobserved, and ends them with a reason" do
      settings = Config.settings!()
      later = DateTime.add(@now, 60)

      {entries, changes} =
        ForcedQueue.reconcile(
          %{},
          [issue("b", "MT-2", "Todo", ["expedite"]), issue("a", "MT-1", "In Review", ["Expedite"]), issue("c", "MT-3", "Todo", []), :not_an_issue],
          [],
          settings,
          @now
        )

      assert [{:start, "a", %{identifier: "MT-1", forced_since: @now}}, {:start, "b", %{identifier: "MT-2"}}] = changes
      assert Map.keys(entries) == ["a", "b"]

      # Already queued: no new change, fields refreshed, forced_since kept.
      {entries, []} = ForcedQueue.reconcile(entries, [issue("a", "MT-1", "Merging", ["expedite"])], [], settings, later)
      assert %{state: "Merging", forced_since: @now} = entries["a"]
      assert %{state: "Todo", forced_since: @now} = entries["b"]

      {entries, [{:start, "d", _d}]} = ForcedQueue.reconcile(entries, [issue("d", "MT-4", "Todo", ["expedite"])], [], settings, @now)
      entries = Map.update!(entries, "d", &%{&1 | forced_since: later})

      assert [
               %{issue_id: "a", identifier: "MT-1", position: 1},
               %{issue_id: "b", identifier: "MT-2", position: 2},
               %{issue_id: "d", identifier: "MT-4", position: 3, forced_since: ^later, title: "Ticket MT-4", state: "Todo"}
             ] = ForcedQueue.snapshot(entries)

      {entries, changes} =
        ForcedQueue.reconcile(
          entries,
          [issue("a", "MT-1", "Done", ["expedite"]), issue("b", "MT-2", "Todo", [])],
          ["d"],
          settings,
          later
        )

      assert [{:end, "a", %{identifier: "MT-1"}, :terminal}, {:end, "b", _b, :label_removed}, {:end, "d", _d, :missing}] =
               changes

      assert entries == %{}
    end

    test "orders same-time entries by identifier, and an entry without identifier first" do
      entries = %{
        "z" => %{identifier: "MT-9", title: nil, state: "Todo", repo_key: nil, forced_since: @now},
        "y" => %{identifier: "MT-1", title: nil, state: "Todo", repo_key: nil, forced_since: @now}
      }

      assert [%{issue_id: "y", position: 1}, %{issue_id: "z", position: 2}] = ForcedQueue.snapshot(entries)
      assert ForcedQueue.snapshot(nil) == []

      stateless = %{issue("y", "MT-1", "Todo", []) | state: nil}
      {_entries, changes} = ForcedQueue.reconcile(entries, [stateless], [], Config.settings!(), @now)
      assert [{:end, "y", _entry, :label_removed}] = changes

      issues = [issue("n", nil, "Todo", ["expedite"]), issue("m", "MT-1", "Todo", ["expedite"])]
      {_entries, changes} = ForcedQueue.reconcile(%{}, issues, [], Config.settings!(), @now)
      assert [{:start, "n", _}, {:start, "m", _}] = changes
    end
  end

  describe "RunStore" do
    test "keeps the queue per repository and deletes it once empty" do
      entries = %{"a" => %{identifier: "MT-1", title: "T", state: "Todo", repo_key: nil, forced_since: @now}}

      assert RunStore.get_forced("app") == %{}
      assert :ok = RunStore.put_forced("app", entries)
      assert RunStore.get_forced("app") == entries
      assert RunStore.get_forced("other") == %{}
      assert :ok = RunStore.put_forced("app", %{})
      assert RunStore.get_forced("app") == %{}

      assert {:error, :invalid_repo_key} = RunStore.put_forced(" ", entries)
      assert {:error, :invalid_repo_key} = RunStore.get_forced(nil)
      assert {:error, :invalid_forced_entries} = RunStore.put_forced("app", [])
    end
  end

  describe "the orchestrator" do
    test "lists a forced ticket in /api/v1/state, audits it, keeps it across a restart and drops it once the label goes", ctx do
      # Linear's poll only returns active states, so the label is first seen on a Todo ticket. An
      # open blocker keeps it from being dispatched.
      blocker = %{id: "blocker-1", identifier: "MT-B1", state: "In Progress"}
      forced = %{issue("forced-1", "MT-F1", "Todo", ["Expedite"]) | blocked_by: [blocker]}
      tracked([forced, issue("plain-1", "MT-P1", "In Review", ["bug"])])

      {pid, name} = start_orchestrator(ctx, :FirstOrchestrator)
      assert %{"forced-1" => %{forced_since: @now}} = :sys.get_state(pid).forced
      assert %{} = RunStore.get_forced(Config.repo_key!())["forced-1"]

      payload = Presenter.state_payload(name, 1_000)

      assert [%{issue_id: "forced-1", issue_identifier: "MT-F1", title: "Ticket MT-F1", state: "Todo", forced_since: "2026-10-04T06:00:00Z", position: 1}] =
               payload.forced

      assert %{max_total: 10, finishing_max: 2, forced_max: 1} = payload.concurrency
      refute Enum.any?(payload.running, &(&1.issue_id == "forced-1"))

      # Once queued it stays listed outside the active states, refreshed by id.
      forced = %{forced | state: "In Review", blocked_by: []}
      tracked([forced])
      send(pid, :run_poll_cycle)
      wait_until(fn -> match?(%{"forced-1" => %{state: "In Review"}}, :sys.get_state(pid).forced) end)

      GenServer.stop(pid)

      # A restart later keeps forced_since and the ticket's place.
      Agent.update(ctx.clock, fn _ -> DateTime.add(@now, 3_600) end)
      {pid, _name} = start_orchestrator(ctx, :RestartedOrchestrator)
      assert %{"forced-1" => %{forced_since: @now, state: "In Review"}} = :sys.get_state(pid).forced

      # Removing the label drops it at the next poll, even while its repo is not due.
      tracked([%{forced | labels: ["bug"]}])
      send(pid, :run_poll_cycle)
      wait_until(fn -> :sys.get_state(pid).forced == %{} end)
      assert RunStore.get_forced(Config.repo_key!()) == %{}

      audit = Presenter.audit_payload(%{"issue" => "MT-F1"}, name, 1_000)
      types = audit |> Map.fetch!(:events) |> Enum.map(& &1.event_type)
      assert "forced_start" in types
      assert "forced_end" in types

      assert {:ok, events} = AuditLog.query(event_type: "forced_end")
      assert [%{"issue_identifier" => "MT-F1", "reason" => "label_removed", "forced_since" => "2026-10-04T06:00:00.000000Z"}] = Enum.to_list(events)
    end

    test "keeps the queue when the refresh fails and ends a ticket Linear no longer returns" do
      state = %Orchestrator.State{repo_key: Config.repo_key!(), clock: fn -> @now end}
      repo_result = {"app", {:ok, [issue("forced-1", "MT-F1", "Todo", ["expedite"])]}}

      state = Orchestrator.apply_forced_poll_result_for_test(state, repo_result, [], {:ok, []})
      assert Map.keys(state.forced) == ["forced-1"]

      log =
        capture_log(fn ->
          kept = Orchestrator.apply_forced_poll_result_for_test(state, :not_due, ["forced-1"], {:error, :timeout})
          send(self(), {:state, kept})
        end)

      assert_received {:state, kept}
      assert kept.forced == state.forced
      assert log =~ "Failed to refresh forced tickets; keeping them queued: :timeout"

      state = Orchestrator.apply_forced_poll_result_for_test(state, :not_due, ["forced-1"], {:ok, []})
      assert state.forced == %{}

      assert {:ok, events} = AuditLog.query(event_type: "forced_end")
      assert [%{"reason" => "missing"}] = Enum.to_list(events)
    end
  end

  defp start_orchestrator(ctx, name) do
    name = Module.concat(__MODULE__, name)
    clock = ctx.clock
    {:ok, pid} = Orchestrator.start_link(name: name, clock: fn -> Agent.get(clock, & &1) end)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    wait_until(fn ->
      state = :sys.get_state(pid)
      poll_idle? = not state.poll_check_in_progress and is_nil(state.repo_poll_task_ref)
      poll_idle? and is_nil(state.startup_workspace_lifecycle_task_ref)
    end)

    {pid, name}
  end

  defp wait_until(fun, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline, do: flunk("condition not met in time")
      Process.sleep(25)
      do_wait_until(fun, deadline)
    end
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp issue(id, identifier, state, labels) do
    %Issue{id: id, identifier: identifier, title: "Ticket #{identifier}", state: state, labels: labels, team: %{key: "Test"}}
  end
end
