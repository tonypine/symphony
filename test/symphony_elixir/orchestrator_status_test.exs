defmodule SymphonyElixir.OrchestratorStatusTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.AppServer
  alias SymphonyElixir.Codex.MessageHumanizer
  alias SymphonyElixir.StatusDashboard.Renderer
  alias SymphonyElixir.Tracker.Memory, as: MemoryTracker
  alias SymphonyElixirWeb.ObservabilityPubSub

  @snapshot_table :symphony_orchestrator_snapshot
  # The wait_for_* helpers poll until their condition holds, so a passing test never waits
  # this long; it only keeps a slow, loaded host from failing on the deadline.
  @min_wait_ms 5_000

  defmodule StopSessionAgent do
    @spec stop_session(map()) :: :ok
    def stop_session(%{recipient: recipient}) when is_pid(recipient) do
      send(recipient, :agent_stop_session_called)
      :ok
    end

    def stop_session(_session), do: :ok
  end

  defmodule FailingStopSessionAgent do
    @spec stop_session(map()) :: {:error, atom()}
    def stop_session(%{recipient: recipient}) when is_pid(recipient) do
      send(recipient, :failing_stop_session_called)
      {:error, :remote_cleanup_failed}
    end
  end

  defmodule SlowStopSessionAgent do
    @spec stop_session(map()) :: :ok
    def stop_session(%{recipient: recipient}) when is_pid(recipient) do
      send(recipient, {:slow_stop_session_started, self()})

      receive do
        :release_slow_stop_session -> :ok
      after
        60_000 -> :ok
      end
    end
  end

  # Stays in flight until it receives `:release_quality_gate`, so the test, not
  # the clock, decides how long the evaluation runs.
  defmodule SlowQualityGateProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(_issue, _settings) do
      send(Application.fetch_env!(:symphony_elixir, :slow_quality_gate_recipient), {:slow_quality_gate_started, self()})

      receive do
        :release_quality_gate -> {:ok, %{score: 9, reason: "ready"}}
      end
    end
  end

  test "snapshot returns :timeout when snapshot server is unresponsive" do
    server_name = Module.concat(__MODULE__, :UnresponsiveSnapshotServer)
    parent = self()

    pid =
      spawn(fn ->
        Process.register(self(), server_name)
        send(parent, :snapshot_server_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :snapshot_server_ready, 1_000
    assert Orchestrator.snapshot(server_name, 10) == :timeout

    send(pid, :stop)
  end

  test "snapshot stays responsive while repo poll I/O is in flight" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_candidate_sleep_ms, 1)
    assert {:ok, []} = MemoryTracker.fetch_candidate_issues()
    Application.delete_env(:symphony_elixir, :memory_tracker_fetch_candidate_sleep_ms)

    orchestrator_name = Module.concat(__MODULE__, :SlowRepoPollOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_candidate_sleep_ms)

      if Process.alive?(pid) do
        stop_process(pid)
      end

      terminate_task_supervisor_children()
    end)

    wait_for_orchestrator_state(pid, &(is_nil(&1.repo_poll_task_ref) and not &1.poll_check_in_progress), 5_000)
    # Far longer than any snapshot below may take; on_exit stops the poll task.
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_candidate_sleep_ms, 30_000)
    # Make the repo due again, so this poll fetches it whenever the boot poll ran.
    :sys.replace_state(pid, &%{&1 | repo_poll_cache: %{}, repo_poll_due_at_ms: %{}})
    send(pid, :run_poll_cycle)
    wait_for_orchestrator_state(pid, &is_reference(&1.repo_poll_task_ref), 5_000)
    %{repo_poll_task_ref: poll_ref} = get_orchestrator_state(pid)

    assert %{} = Orchestrator.snapshot(pid, 5_000)

    snapshots =
      1..5
      |> Enum.map(fn _ -> Task.async(fn -> Orchestrator.snapshot(pid, 5_000) end) end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.all?(snapshots, &is_map/1)

    # The same poll is still fetching, so no snapshot waited for it.
    assert %{repo_poll_task_ref: ^poll_ref} = get_orchestrator_state(pid)
  end

  test "orchestrator publishes snapshots to ETS on configured cadence" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      observability_snapshot_publish_ms: 25
    )

    orchestrator_name = Module.concat(__MODULE__, :SnapshotPublisherOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    entry =
      wait_for_snapshot_cache(
        pid,
        fn entry ->
          is_map(entry.snapshot) and is_integer(entry.monotonic_ms) and is_integer(entry.system_ms)
        end,
        100
      )

    assert %{
             snapshot: %{
               running: [],
               watching: [],
               conflicts: [],
               retrying: [],
               polling: %{poll_interval_ms: poll_interval_ms}
             },
             monotonic_ms: monotonic_ms,
             system_ms: system_ms
           } = entry

    assert is_integer(poll_interval_ms)
    assert [{:current, snapshot, ^monotonic_ms, ^system_ms}] = :ets.lookup(@snapshot_table, :current)
    assert snapshot == entry.snapshot

    send(pid, :publish_snapshot)

    wait_for_snapshot_cache(
      pid,
      fn next_entry -> next_entry.system_ms > system_ms end,
      100
    )
  end

  test "reports its queue and snapshot timings, and logs the callbacks and snapshot builds that are slow" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      observability_snapshot_publish_ms: 25
    )

    orchestrator_name = Module.concat(__MODULE__, :DiagnosticsOrchestrator)

    assert Orchestrator.diagnostics(orchestrator_name) == %{
             message_queue_len: nil,
             snapshot_age_ms: nil,
             snapshot_build_ms: nil,
             snapshot_parts_ms: %{}
           }

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    wait_for_snapshot_cache(pid, &is_map(&1.snapshot), 100)

    assert %{
             message_queue_len: queue_len,
             snapshot_age_ms: age_ms,
             snapshot_build_ms: build_ms,
             snapshot_parts_ms: %{run_history: run_history_ms, qa: qa_ms, auto_merge: auto_merge_ms}
           } = Orchestrator.diagnostics(pid)

    assert Enum.all?([queue_len, age_ms, build_ms, run_history_ms, qa_ms, auto_merge_ms], &(is_integer(&1) and &1 >= 0))

    assert %{orchestrator: %{snapshot_build_ms: api_build_ms}} =
             SymphonyElixirWeb.Presenter.state_payload(orchestrator_name, 1_000)

    assert is_integer(api_build_ms)

    Application.put_env(:symphony_elixir, :orchestrator_slow_callback_ms, 0)

    log =
      try do
        capture_log(fn ->
          send(pid, :publish_snapshot)
          GenServer.call(pid, :pause_status)
        end)
      after
        Application.delete_env(:symphony_elixir, :orchestrator_slow_callback_ms)
      end

    assert log =~ ~r/Orchestrator slow handle_info duration_ms=\d+ message=:publish_snapshot/
    assert log =~ ~r/Orchestrator slow handle_call duration_ms=\d+ message=:pause_status/
    assert log =~ ~r/Orchestrator snapshot build slow build_ms=\d+ auto_merge_ms=\d+ qa_ms=\d+ run_history_ms=\d+/
  end

  test "a retry's Linear read runs outside the orchestrator, which answers and publishes snapshots while it is in flight" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", observability_snapshot_publish_ms: 25)
    issue = %Issue{id: "issue-slow-linear-retry", identifier: "MT-SLOW-LINEAR", title: "Slow Linear", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :SlowLinearRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_states_sleep_ms)
      if Process.alive?(pid), do: stop_process(pid)
      terminate_task_supervisor_children()
    end)

    wait_for_orchestrator_state(pid, &(is_nil(&1.repo_poll_task_ref) and not &1.poll_check_in_progress), 5_000)
    # Far longer than the test; the read is stopped below.
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_states_sleep_ms, 60_000)
    token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | retry_attempts: %{issue.id => %{attempt: 1, retry_token: token, identifier: issue.identifier, repo_key: Config.repo_key!()}},
          claimed: MapSet.put(state.claimed, issue.id)
      }
    end)

    tasks_before = Task.Supervisor.children(SymphonyElixir.TaskSupervisor)
    send(pid, {:retry_issue, issue.id, token})

    assert %{tracker_tasks: tasks, claimed: claimed} = get_orchestrator_state(pid)
    assert [%{kind: :retry_refresh, issue_ids: ["issue-slow-linear-retry"]}] = Map.values(tasks)
    assert MapSet.member?(claimed, issue.id)

    # While Linear has not answered, the orchestrator answers snapshot calls and keeps publishing.
    assert %{running: []} = GenServer.call(pid, :snapshot, 1_000)
    assert is_map(Orchestrator.snapshot(pid, 1_000))
    %{system_ms: published_ms} = wait_for_snapshot_cache(pid, &is_map(&1.snapshot), 1_000)
    wait_for_snapshot_cache(pid, &(&1.system_ms > published_ms), 1_000)
    assert map_size(get_orchestrator_state(pid).tracker_tasks) == 1

    # A read that dies is a failed refresh: the retry is scheduled again with its claim held.
    [task_pid] = Task.Supervisor.children(SymphonyElixir.TaskSupervisor) -- tasks_before

    log =
      capture_log(fn ->
        Process.exit(task_pid, :kill)
        wait_for_orchestrator_state(pid, &(&1.tracker_tasks == %{}), 1_000)
      end)

    assert log =~ "Async Linear task retry_refresh exited before replying: :killed"
    state = get_orchestrator_state(pid)
    assert %{attempt: 2, error: "retry issue refresh failed: {:task_exit, :killed}"} = state.retry_attempts[issue.id]
    assert MapSet.member?(state.claimed, issue.id)

    # An answer from a task the orchestrator no longer tracks changes nothing.
    send(pid, {make_ref(), {:tracker_task_result, {:ok, [issue]}}})
    assert get_orchestrator_state(pid).retry_attempts == state.retry_attempts
  end

  test "a poll's dispatch revalidation reads Linear in the readiness task, so the orchestrator answers while it is in flight" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      quality_gate: %{enabled: false},
      observability_snapshot_publish_ms: 25
    )

    issue = %Issue{id: "issue-slow-dispatch-refresh", identifier: "MT-SLOW-DISPATCH", title: "Slow dispatch refresh", state: "Todo", team: %{key: "Test"}}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    # Far longer than the test; the read is stopped below.
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_states_sleep_ms, 60_000)

    tasks_before = Task.Supervisor.children(SymphonyElixir.TaskSupervisor)
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :SlowDispatchRefreshOrchestrator))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_states_sleep_ms)
      if Process.alive?(pid), do: stop_process(pid)
      terminate_task_supervisor_children()
    end)

    state = wait_for_orchestrator_state(pid, &(map_size(&1.dispatch_readiness_tasks) == 1), 5_000)
    assert [%{kind: :poll, issues: [%Issue{id: "issue-slow-dispatch-refresh"}]}] = Map.values(state.dispatch_readiness_tasks)

    # While Linear has not answered, the orchestrator answers snapshot calls and keeps publishing.
    assert %{running: []} = GenServer.call(pid, :snapshot, 1_000)
    %{system_ms: published_ms} = wait_for_snapshot_cache(pid, &is_map(&1.snapshot), 1_000)
    wait_for_snapshot_cache(pid, &(&1.system_ms > published_ms), 1_000)
    assert map_size(get_orchestrator_state(pid).dispatch_readiness_tasks) == 1

    [task_pid] =
      (Task.Supervisor.children(SymphonyElixir.TaskSupervisor) -- tasks_before)
      |> Enum.filter(&dispatch_prefetch_task?/1)

    log =
      capture_log(fn ->
        Process.exit(task_pid, :kill)
        wait_for_orchestrator_state(pid, &(&1.dispatch_readiness_tasks == %{}), 1_000)
      end)

    assert log =~ "Skipping dispatch after readiness task failure: :killed"
    assert %{running: running, claimed: claimed} = get_orchestrator_state(pid)
    assert running == %{}
    assert claimed == MapSet.new()
  end

  test "dispatch after a readiness task uses the issues that task read, and reads Linear only for the ones it did not" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", quality_gate: %{enabled: false})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :PrefetchedDispatchOrchestrator))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_states_sleep_ms)
      if Process.alive?(pid), do: stop_process(pid)
    end)

    wait_for_orchestrator_state(pid, &(is_nil(&1.repo_poll_task_ref) and not &1.poll_check_in_progress), 5_000)
    prefetched = %Issue{id: "issue-prefetched", identifier: "MT-PREFETCHED", title: "Prefetched", state: "Todo"}
    unread = %Issue{id: "issue-unread", identifier: "MT-UNREAD", title: "Unread", state: "Todo"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [prefetched, %{unread | state: "Backlog"}])

    send_readiness_result = fn issues, dispatch_refresh ->
      ref = make_ref()
      :sys.replace_state(pid, &%{&1 | dispatch_readiness_tasks: %{ref => %{kind: :poll, issues: issues}}})
      result = %{now_ms: System.monotonic_time(:millisecond), age_gc_result: :skipped, quota: nil}
      send(pid, {ref, {:dispatch_readiness_result, Map.put(result, :dispatch_refresh, dispatch_refresh)}})
      get_orchestrator_state(pid)
    end

    # The task read the issue parked: dispatch skips it without asking Linear, which would hang here.
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_states_sleep_ms, 60_000)

    log =
      capture_log(fn ->
        state = send_readiness_result.([prefetched], %{ids: MapSet.new([prefetched.id]), result: {:ok, [%{prefetched | state: "Backlog"}]}})
        assert state.running == %{}
        assert state.dispatch_refresh == nil
      end)

    assert log =~ ~s(Skipping stale dispatch after issue refresh: issue_id=issue-prefetched issue_identifier=MT-PREFETCHED state="Backlog")

    # A failed read skips the dispatch as a failed refresh does.
    log = capture_log(fn -> send_readiness_result.([prefetched], %{ids: MapSet.new([prefetched.id]), result: {:error, :linear_down}}) end)
    assert log =~ "Skipping dispatch; issue refresh failed for issue_id=issue-prefetched issue_identifier=MT-PREFETCHED: :linear_down"

    # An issue the task did not read is read from Linear at dispatch.
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_states_sleep_ms, 0)
    log = capture_log(fn -> send_readiness_result.([unread], %{ids: MapSet.new([prefetched.id]), result: {:ok, [prefetched]}}) end)
    assert log =~ ~s(Skipping stale dispatch after issue refresh: issue_id=issue-unread issue_identifier=MT-UNREAD state="Backlog")
    assert get_orchestrator_state(pid).running == %{}
  end

  test "an agent's stream of events writes its run's metadata to the run store a bounded number of times" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :orchestrator_running_metadata_persist_ms, 60_000)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :orchestrator_running_metadata_persist_ms) end)

    issue = %Issue{id: "issue-bounded-writes", identifier: "MT-BOUNDED", title: "Bounded writes", state: "In Progress"}
    orchestrator_name = Module.concat(__MODULE__, :BoundedRunWritesOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: stop_process(pid) end)

    {worker_pid, worker_ref} = start_blocked_worker()
    on_exit(fn -> send(worker_pid, :finish) end)
    started_at = DateTime.utc_now()
    run_id = "run-bounded-writes"
    put_running_run!(issue, run_id, started_at)
    put_running_entry(pid, issue, running_entry(issue, worker_pid, worker_ref, run_id, started_at))
    stored = fn -> Enum.find(RunStore.list_runs(:all), &(&1.run_id == run_id)) end
    event = fn name -> {:codex_worker_update, issue.id, %{event: name, payload: %{method: "item/#{name}"}, timestamp: DateTime.utc_now()}} end

    # The first event of the run is written, and so is a new session (it names the run).
    send(pid, event.(:notification))
    get_orchestrator_state(pid)
    assert %{last_event: :notification, session_id: nil} = stored.()

    send(pid, {:codex_worker_update, issue.id, %{event: :session_started, session_id: "thread-bounded", timestamp: DateTime.utc_now()}})
    get_orchestrator_state(pid)
    assert %{last_event: :session_started, session_id: "thread-bounded", turn_count: 1} = written = stored.()

    # A stream of events that change nothing naming the run writes nothing until the interval passes.
    for _ <- 1..25, do: send(pid, event.(:notification))
    get_orchestrator_state(pid)
    assert stored.() == written

    Application.put_env(:symphony_elixir, :orchestrator_running_metadata_persist_ms, 0)
    send(pid, event.(:other_message))
    get_orchestrator_state(pid)
    assert %{last_event: :other_message} = stored.()
  end

  test "codex updates and snapshots stay responsive during quality gate evaluation" do
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")
    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, SlowQualityGateProvider)
    Application.put_env(:symphony_elixir, :slow_quality_gate_recipient, self())

    on_exit(fn ->
      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:symphony_elixir, :quality_gate_anthropic_module)
      Application.delete_env(:symphony_elixir, :slow_quality_gate_recipient)
    end)

    gated_issue = %Issue{
      id: "issue-slow-quality-gate",
      identifier: "MT-SLOW-QG",
      title: "Slow quality gate",
      description: "Wait for scoring",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-SLOW-QG"
    }

    running_issue = %Issue{
      id: "issue-live-during-quality-gate",
      identifier: "MT-LIVE-QG",
      title: "Live during quality gate",
      description: "Keep accepting codex updates",
      state: "In Progress",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-LIVE-QG"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [gated_issue, running_issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 2,
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "pass"
      }
    )

    orchestrator_name = Module.concat(__MODULE__, :SlowQualityGateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    started_at = DateTime.utc_now()

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :shutdown)
      end
    end)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: running_issue.identifier,
      issue: running_issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{running_issue.id => running_entry},
          claimed: MapSet.put(state.claimed, running_issue.id),
          repo_poll_cache: %{},
          repo_poll_due_at_ms: %{}
      }
    end)

    send(pid, :run_poll_cycle)
    assert_receive {:slow_quality_gate_started, gate_pid}, 5_000
    on_exit(fn -> Process.exit(gate_pid, :kill) end)

    now = DateTime.utc_now()
    update = %{event: :session_started, session_id: "thread-during-quality-gate", timestamp: now}
    send(pid, {:codex_worker_update, running_issue.id, update})

    snapshot =
      wait_for_snapshot(
        pid,
        fn
          %{running: [%{session_id: "thread-during-quality-gate"}]} -> true
          _ -> false
        end,
        5_000
      )

    assert [%{issue_id: "issue-live-during-quality-gate"}] = snapshot.running
    assert %{} = Orchestrator.snapshot(pid, 5_000)

    # The gate is still waiting for its release, so the orchestrator applied the
    # update and answered both snapshots without waiting on the evaluation.
    assert {:current_function, {SlowQualityGateProvider, :score, 2}} = Process.info(gate_pid, :current_function)
  end

  test "a slow audit log write for an agent update doesn't delay a concurrent snapshot" do
    issue = %Issue{id: "issue-slow-audit", identifier: "MT-AUDIT", title: "Slow audit", state: "In Progress"}
    test_pid = self()

    # Stays in flight until the test releases it, as a write behind a busy lock or a large day.
    Application.put_env(:symphony_elixir, :audit_log_writer_record_agent_update, fn entry, _update, _delta ->
      send(test_pid, {:audit_write_started, self(), entry})

      receive do
        :release_audit_write -> send(test_pid, :audit_write_done)
      after
        60_000 -> :ok
      end
    end)

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :SlowAuditOrchestrator))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :audit_log_writer_record_agent_update)
      if Process.alive?(pid), do: stop_process(pid)
    end)

    initial_state = get_orchestrator_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      run_id: "run-slow-audit",
      session_id: nil,
      turn_count: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ -> %{initial_state | running: %{issue.id => running_entry}, claimed: MapSet.put(initial_state.claimed, issue.id)} end)

    send(pid, {:codex_worker_update, issue.id, %{event: :session_started, session_id: "thread-slow-audit", timestamp: DateTime.utc_now()}})
    assert_receive {:audit_write_started, writer_pid, audited_entry}, @min_wait_ms
    # The writer got only the fields an audit event names, not the whole running entry.
    assert audited_entry == %{issue: issue, identifier: "MT-AUDIT", run_id: "run-slow-audit", session_id: "thread-slow-audit"}

    assert %{running: [%{issue_id: "issue-slow-audit", session_id: "thread-slow-audit"}]} = Orchestrator.snapshot(pid, 1_000)
    # The write is still waiting for its release, so the snapshot didn't wait on it.
    refute_received :audit_write_done
    send(writer_pid, :release_audit_write)
    assert_receive :audit_write_done, @min_wait_ms
  end

  test "orchestrator snapshot reflects last codex update and session id" do
    issue_id = "issue-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-188",
      title: "Snapshot test",
      description: "Capture codex state",
      state: "In Progress",
      url: "https://example.org/issues/MT-188"
    }

    orchestrator_name = Module.concat(__MODULE__, :SnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }

    state_with_issue =
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))

    :sys.replace_state(pid, fn _ -> state_with_issue end)

    now = DateTime.utc_now()

    session_update = %{
      event: :session_started,
      session_id: "thread-live-turn-live",
      timestamp: now
    }

    notification_update = %{
      event: :notification,
      payload: %{method: "some-event"},
      timestamp: now
    }

    repo_key = Config.repo_key!()

    assert :ok = ObservabilityPubSub.subscribe_transcript()

    send(pid, {:codex_worker_update, issue_id, session_update})
    assert_receive {:transcript_event, session_event}
    assert Map.take(session_event, [:repo_key, :issue_id]) == %{repo_key: repo_key, issue_id: issue_id}

    send(pid, {:codex_worker_update, issue_id, notification_update})
    assert_receive {:transcript_event, notification_event}
    assert Map.take(notification_event, [:repo_key, :issue_id]) == %{repo_key: repo_key, issue_id: issue_id}

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.issue_id == issue_id
    assert snapshot_entry.session_id == "thread-live-turn-live"
    assert snapshot_entry.turn_count == 1
    assert snapshot_entry.last_codex_timestamp == now
    assert snapshot_entry.last_event_at == now

    assert snapshot_entry.last_codex_message == %{
             event: :notification,
             message: %{method: "some-event"},
             timestamp: now
           }

    assert snapshot_entry.transcript_buffer == [session_update, notification_update]
    assert snapshot_entry.transcript_buffer_size == 2
  end

  test "orchestrator broadcasts transcript updates with the running entry repo key" do
    issue_id = "issue-api-transcript"
    repo_key = "api"

    issue = %Issue{
      id: issue_id,
      identifier: "API-188",
      title: "Repo transcript test",
      description: "Route transcript events by repo",
      state: "In Progress",
      url: "https://example.org/issues/API-188"
    }

    orchestrator_name = Module.concat(__MODULE__, :RepoTranscriptOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      repo_key: repo_key,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    assert :ok = ObservabilityPubSub.subscribe_transcript()

    update = %{
      event: :notification,
      payload: %{method: "some-event"},
      timestamp: DateTime.utc_now()
    }

    send(pid, {:codex_worker_update, issue_id, update})
    # The orchestrator broadcasts while it handles the update, so the event is here once it replies.
    :sys.get_state(pid)

    assert_received {:transcript_event, %{issue_id: ^issue_id} = transcript_event}
    assert transcript_event.repo_key == repo_key
  end

  test "orchestrator keeps transcript available when running issue becomes watched" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Canceled"]
    )

    issue_id = "issue-watch-transcript"
    repo_key = "api"
    started_at = DateTime.utc_now() |> DateTime.add(-180, :second)
    event_at = DateTime.add(started_at, 30, :second)

    running_issue = %Issue{
      id: issue_id,
      identifier: "MT-WATCH-TX",
      title: "Watch transcript",
      description: "Keep transcript while issue is watched",
      state: "In Progress",
      url: "https://example.org/issues/MT-WATCH-TX"
    }

    watched_issue = %{running_issue | state: "In Review"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [watched_issue])

    orchestrator_name = Module.concat(__MODULE__, :WatchingTranscriptOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    wait_for_orchestrator_state(pid, &is_nil(&1.repo_poll_task_ref), 1_000)

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          60_000 -> :ok
        end
      end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      if Process.alive?(pid), do: stop_process(pid)
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :shutdown)
    end)

    transcript_event = %{
      event: :notification,
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "watched transcript"}
      },
      timestamp: event_at
    }

    running_entry = %{
      pid: worker_pid,
      ref: nil,
      run_id: "run-watch-transcript",
      repo_key: repo_key,
      identifier: running_issue.identifier,
      issue: running_issue,
      session_id: "thread-watch-transcript-turn-1",
      turn_count: 2,
      transcript_buffer: :queue.from_list([transcript_event]),
      transcript_buffer_size: 1,
      last_codex_message: %{event: :notification},
      last_codex_timestamp: event_at,
      last_codex_event: :notification,
      last_event_at: event_at,
      codex_input_tokens: 9,
      codex_cached_input_tokens: 3,
      codex_output_tokens: 5,
      codex_total_tokens: 14,
      started_at: started_at
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{issue_id => running_entry},
          claimed: MapSet.put(state.claimed, issue_id),
          retry_attempts: %{}
      }
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(
        pid,
        fn
          %{watching: [%{identifier: "MT-WATCH-TX", transcript_buffer: [^transcript_event]}]} -> true
          _ -> false
        end,
        1_000
      )

    assert snapshot.running == []

    assert [
             %{
               issue_id: ^issue_id,
               repo_key: ^repo_key,
               identifier: "MT-WATCH-TX",
               state: "In Review",
               session_id: "thread-watch-transcript-turn-1",
               started_at: ^started_at,
               last_event_at: ^event_at,
               turn_count: 2,
               tokens: %{
                 input_tokens: 9,
                 cached_input_tokens: 3,
                 uncached_input_tokens: 6,
                 output_tokens: 5,
                 total_tokens: 14
               },
               transcript_buffer: [^transcript_event],
               transcript_buffer_size: 1
             }
           ] = snapshot.watching
  end

  test "orchestrator transcript buffer is bounded by observability config" do
    write_workflow_file!(Workflow.workflow_file_path(), observability_transcript_buffer_size: 2)

    issue_id = "issue-bounded-transcript"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-189",
      title: "Bounded transcript test",
      description: "Keep only recent transcript events",
      state: "In Progress",
      url: "https://example.org/issues/MT-189"
    }

    orchestrator_name = Module.concat(__MODULE__, :BoundedTranscriptOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    updates =
      Enum.map(1..4, fn index ->
        %{event: "event-#{index}", payload: %{index: index}, timestamp: DateTime.utc_now()}
      end)

    Enum.each(updates, fn update ->
      send(pid, {:codex_worker_update, issue_id, update})
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert Enum.map(snapshot_entry.transcript_buffer, & &1.event) == ["event-3", "event-4"]
    assert snapshot_entry.transcript_buffer_size == 2
  end

  test "orchestrator transcript buffer can be disabled by observability config" do
    write_workflow_file!(Workflow.workflow_file_path(), observability_transcript_buffer_size: 0)

    issue_id = "issue-disabled-transcript"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-190",
      title: "Disabled transcript test",
      description: "Do not retain transcript events",
      state: "In Progress",
      url: "https://example.org/issues/MT-190"
    }

    orchestrator_name = Module.concat(__MODULE__, :DisabledTranscriptOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    1..4
    |> Enum.map(fn index ->
      %{event: "event-#{index}", payload: %{index: index}, timestamp: DateTime.utc_now()}
    end)
    |> Enum.each(fn update ->
      send(pid, {:codex_worker_update, issue_id, update})
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.transcript_buffer == []
    assert snapshot_entry.transcript_buffer_size == 0
  end

  test "orchestrator snapshot tracks codex thread totals and app-server pid" do
    issue_id = "issue-usage-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-201",
      title: "Usage snapshot test",
      description: "Collect usage stats",
      state: "In Progress",
      url: "https://example.org/issues/MT-201"
    }

    orchestrator_name = Module.concat(__MODULE__, :UsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_cached_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_cached_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-usage-turn-usage",
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "tokenUsage" => %{
               "total" => %{"inputTokens" => 12, "outputTokens" => 4, "totalTokens" => 16}
             }
           }
         },
         timestamp: now,
         codex_app_server_pid: "4242"
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_app_server_pid == "4242"
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16
    assert snapshot_entry.turn_count == 1
    assert is_integer(snapshot_entry.runtime_seconds)

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = get_orchestrator_state(pid)

    assert completed_state.codex_totals.input_tokens == 12
    assert completed_state.codex_totals.output_tokens == 4
    assert completed_state.codex_totals.total_tokens == 16
    assert is_integer(completed_state.codex_totals.seconds_running)
  end

  test "orchestrator snapshot tracks turn completed usage when present" do
    issue_id = "issue-turn-completed-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-202",
      title: "Turn completed usage test",
      description: "Track final turn usage",
      state: "In Progress",
      url: "https://example.org/issues/MT-202"
    }

    orchestrator_name = Module.concat(__MODULE__, :TurnCompletedUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :turn_completed,
         payload: %{
           method: "turn/completed",
           usage: %{"input_tokens" => "12", "output_tokens" => 4, "total_tokens" => 16}
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = get_orchestrator_state(pid)
    assert completed_state.codex_totals.input_tokens == 12
    assert completed_state.codex_totals.output_tokens == 4
    assert completed_state.codex_totals.total_tokens == 16
  end

  test "orchestrator tracks converted Claude turn usage in issue and daily totals" do
    issue_id = "issue-claude-turn-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-CLAUDE",
      title: "Claude turn usage test",
      description: "Track Claude final turn usage",
      state: "In Progress",
      url: "https://example.org/issues/MT-CLAUDE"
    }

    orchestrator_name = Module.concat(__MODULE__, :ClaudeTurnUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_cached_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_cached_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      |> Map.put(:budget_daily_used, 2)
    end)

    usage = %{
      input_tokens: 18,
      uncached_input_tokens: 12,
      cached_input_tokens: 4,
      cache_creation_input_tokens: 2,
      output_tokens: 5,
      total_tokens: 23
    }

    update = AppServer.event_to_update({:turn_completed, usage})

    send(pid, {:codex_worker_update, issue_id, update})

    state = get_orchestrator_state(pid)
    running = Map.fetch!(state.running, issue_id)

    assert running.codex_input_tokens == 18
    assert running.uncached_input_tokens == 12
    assert running.codex_cached_input_tokens == 4
    assert running.cache_creation_input_tokens == 2
    assert running.codex_output_tokens == 5
    assert running.codex_total_tokens == 23
    assert running.last_codex_event == :turn_completed
    assert running.transcript_buffer_size == 1

    assert state.codex_totals.input_tokens == 18
    assert state.codex_totals.uncached_input_tokens == 12
    assert state.codex_totals.cached_input_tokens == 4
    assert state.codex_totals.cache_creation_input_tokens == 2
    assert state.codex_totals.output_tokens == 5
    assert state.codex_totals.total_tokens == 23
    assert state.budget_daily_used == 25

    # The comments the run posted, sent as it ends, stay with the completed run.
    send(pid, {:worker_runtime_info, issue_id, %{comment_ids: ["reply-1"]}})
    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = get_orchestrator_state(pid)

    assert completed_state.completed_run_metadata[issue_id].tokens.total_tokens == 23
    assert completed_state.completed_run_metadata[issue_id].comment_ids == ["reply-1"]
  end

  test "orchestrator accounts reviewer token usage separately while preserving totals" do
    issue_id = "issue-reviewer-token-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-REVIEW-TOKENS",
      title: "Reviewer token usage test",
      description: "Track reviewer usage separately",
      state: "In Progress",
      url: "https://example.org/issues/MT-REVIEW-TOKENS"
    }

    orchestrator_name = Module.concat(__MODULE__, :ReviewerTokenUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_cached_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      reviewer_input_tokens: 0,
      reviewer_cached_input_tokens: 0,
      reviewer_output_tokens: 0,
      reviewer_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_cached_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    reviewer_usage = %{input_tokens: 8, cached_input_tokens: 3, output_tokens: 5, total_tokens: 13}

    update =
      {:turn_completed, reviewer_usage}
      |> AppServer.event_to_update()
      |> Map.put(:agent_phase, :reviewer)

    send(pid, {:codex_worker_update, issue_id, update})

    state = get_orchestrator_state(pid)
    running = Map.fetch!(state.running, issue_id)

    assert running.codex_input_tokens == 8
    assert running.codex_cached_input_tokens == 3
    assert running.codex_output_tokens == 5
    assert running.codex_total_tokens == 13
    assert running.reviewer_input_tokens == 8
    assert running.reviewer_cached_input_tokens == 3
    assert running.reviewer_output_tokens == 5
    assert running.reviewer_total_tokens == 13
    assert state.codex_totals.total_tokens == 13

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = get_orchestrator_state(pid)

    assert completed_state.completed_run_metadata[issue_id].tokens.total_tokens == 13

    assert completed_state.completed_run_metadata[issue_id].reviewer_tokens == %{
             input_tokens: 8,
             uncached_input_tokens: 5,
             cached_input_tokens: 3,
             cache_creation_input_tokens: 0,
             output_tokens: 5,
             total_tokens: 13
           }
  end

  test "orchestrator attaches reviewer token snapshot to review-agent verdict transcript events" do
    issue_id = "issue-reviewer-verdict-tokens"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-REVIEW-VERDICT",
      title: "Reviewer verdict token test",
      description: "Attach reviewer token snapshot",
      state: "In Progress",
      url: "https://example.org/issues/MT-REVIEW-VERDICT"
    }

    orchestrator_name = Module.concat(__MODULE__, :ReviewerVerdictTokenOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      repo_key: "default",
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 11,
      codex_cached_input_tokens: 4,
      codex_output_tokens: 7,
      codex_total_tokens: 18,
      reviewer_input_tokens: 5,
      reviewer_cached_input_tokens: 2,
      reviewer_output_tokens: 3,
      reviewer_total_tokens: 8,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_cached_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    assert :ok = ObservabilityPubSub.subscribe_transcript()

    verdict_update = %{
      event: :review_agent_verdict,
      agent_phase: :reviewer,
      timestamp: DateTime.utc_now(),
      payload: %{
        verdict: :approve,
        round: 1,
        max_iterations: 1,
        reason: nil,
        comments: [],
        tokens: %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, total_tokens: 0}
      }
    }

    send(pid, {:codex_worker_update, issue_id, verdict_update})

    assert_receive {:transcript_event,
                    %{
                      event: :review_agent_verdict,
                      issue_id: ^issue_id,
                      payload: %{
                        tokens: %{
                          input_tokens: 5,
                          uncached_input_tokens: 3,
                          cached_input_tokens: 2,
                          cache_creation_input_tokens: 0,
                          output_tokens: 3,
                          total_tokens: 8
                        }
                      }
                    }}

    state = get_orchestrator_state(pid)
    running = Map.fetch!(state.running, issue_id)
    assert [buffered_event] = running.transcript_buffer |> :queue.to_list()
    assert buffered_event.payload.tokens.total_tokens == 8
  end

  test "orchestrator snapshot tracks codex token-count cumulative usage payloads" do
    issue_id = "issue-token-count-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-220",
      title: "Token count snapshot test",
      description: "Validate token-count style payloads",
      state: "In Progress",
      url: "https://example.org/issues/MT-220"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenCountOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "input_tokens" => "2",
                   "output_tokens" => 2,
                   "total_tokens" => 4
                 }
               }
             }
           }
         },
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "prompt_tokens" => 10,
                   "completion_tokens" => 5,
                   "total_tokens" => 15
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 10
    assert snapshot_entry.codex_output_tokens == 5
    assert snapshot_entry.codex_total_tokens == 15

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = get_orchestrator_state(pid)

    assert completed_state.codex_totals.input_tokens == 10
    assert completed_state.codex_totals.output_tokens == 5
    assert completed_state.codex_totals.total_tokens == 15
  end

  test "orchestrator snapshot tracks codex rate-limit payloads" do
    issue_id = "issue-rate-limit-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-221",
      title: "Rate limit snapshot test",
      description: "Capture codex rate limit state",
      state: "In Progress",
      url: "https://example.org/issues/MT-221"
    }

    orchestrator_name = Module.concat(__MODULE__, :RateLimitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    rate_limits = %{
      "limit_id" => "codex",
      "primary" => %{"remaining" => 90, "limit" => 100},
      "secondary" => nil,
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => nil}
    }

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "rate_limits" => rate_limits
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.rate_limits == rate_limits
  end

  test "orchestrator token accounting prefers total_token_usage over last_token_usage in token_count payloads" do
    issue_id = "issue-token-precedence"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-222",
      title: "Token precedence",
      description: "Prefer per-event deltas",
      state: "In Progress",
      url: "https://example.org/issues/MT-222"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenPrecedenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 2,
                     "output_tokens" => 1,
                     "total_tokens" => 3
                   },
                   "total_token_usage" => %{
                     "input_tokens" => 200,
                     "cached_input_tokens" => 150,
                     "output_tokens" => 100,
                     "total_tokens" => 300
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 200
    assert snapshot_entry.uncached_input_tokens == 50
    assert snapshot_entry.codex_cached_input_tokens == 150
    assert snapshot_entry.cache_creation_input_tokens == 0
    assert snapshot_entry.codex_output_tokens == 100
    assert snapshot_entry.codex_total_tokens == 300
  end

  test "orchestrator token accounting accumulates monotonic thread token usage totals" do
    issue_id = "issue-thread-token-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-223",
      title: "Thread token usage",
      description: "Accumulate absolute thread totals",
      state: "In Progress",
      url: "https://example.org/issues/MT-223"
    }

    orchestrator_name = Module.concat(__MODULE__, :ThreadTokenUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    for usage <- [
          %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11},
          %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
        ] do
      send(
        pid,
        {:codex_worker_update, issue_id,
         %{
           event: :notification,
           payload: %{
             "method" => "thread/tokenUsage/updated",
             "params" => %{"tokenUsage" => %{"total" => usage}}
           },
           timestamp: DateTime.utc_now()
         }}
      )
    end

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 10
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 14
  end

  test "orchestrator converts legacy last-reported input counters before splitting cached input" do
    issue_id = "issue-legacy-token-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-223B",
      title: "Legacy token usage",
      description: "Convert legacy full-input counters into uncached counters",
      state: "In Progress",
      url: "https://example.org/issues/MT-223B"
    }

    orchestrator_name = Module.concat(__MODULE__, :LegacyTokenUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 200,
      codex_cached_input_tokens: 150,
      codex_output_tokens: 100,
      codex_total_tokens: 300,
      codex_last_reported_input_tokens: 200,
      codex_last_reported_cached_input_tokens: 150,
      codex_last_reported_output_tokens: 100,
      codex_last_reported_total_tokens: 300,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "tokenUsage" => %{
               "total" => %{
                 "input_tokens" => 260,
                 "cached_input_tokens" => 190,
                 "output_tokens" => 120,
                 "total_tokens" => 380
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.uncached_input_tokens == 70
    assert snapshot_entry.cached_input_tokens == 190
    assert snapshot_entry.codex_input_tokens == 260
    assert snapshot_entry.codex_output_tokens == 120
    assert snapshot_entry.codex_total_tokens == 380
  end

  test "orchestrator normalizes equivalent codex and claude cache usage into comparable uncached buckets" do
    codex_issue = %Issue{
      id: "issue-codex-token-parity",
      identifier: "MT-CODEX-PARITY",
      title: "Codex token parity",
      description: "Compare Codex token semantics",
      state: "In Progress",
      url: "https://example.org/issues/MT-CODEX-PARITY"
    }

    claude_issue = %Issue{
      id: "issue-claude-token-parity",
      identifier: "MT-CLAUDE-PARITY",
      title: "Claude token parity",
      description: "Compare Claude token semantics",
      state: "In Progress",
      url: "https://example.org/issues/MT-CLAUDE-PARITY"
    }

    orchestrator_name = Module.concat(__MODULE__, :ProviderTokenParityOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    started_at = DateTime.utc_now()

    running = %{
      codex_issue.id => running_entry_for_token_test(codex_issue, started_at),
      claude_issue.id => running_entry_for_token_test(claude_issue, started_at)
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, running)
      |> Map.put(:claimed, MapSet.union(initial_state.claimed, MapSet.new(Map.keys(running))))
    end)

    send(
      pid,
      {:codex_worker_update, codex_issue.id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "payload" => %{
                 "info" => %{
                   "total_token_usage" => %{
                     "input_tokens" => 12_000,
                     "cached_input_tokens" => 10_000,
                     "output_tokens" => 500,
                     "total_tokens" => 12_500
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    send(
      pid,
      {:codex_worker_update, claude_issue.id,
       AppServer.event_to_update(
         {:token_usage,
          %{
            input_tokens: 12_400,
            uncached_input_tokens: 2_000,
            cached_input_tokens: 10_000,
            cache_creation_input_tokens: 400,
            output_tokens: 500,
            total_tokens: 12_900
          }}
       )}
    )

    snapshot = GenServer.call(pid, :snapshot)
    entries_by_identifier = Map.new(snapshot.running, &{&1.identifier, &1})

    assert entries_by_identifier["MT-CODEX-PARITY"].uncached_input_tokens == 2_000
    assert entries_by_identifier["MT-CODEX-PARITY"].cached_input_tokens == 10_000
    assert entries_by_identifier["MT-CODEX-PARITY"].cache_creation_input_tokens == 0
    assert entries_by_identifier["MT-CODEX-PARITY"].output_tokens == 500

    assert entries_by_identifier["MT-CLAUDE-PARITY"].uncached_input_tokens == 2_000
    assert entries_by_identifier["MT-CLAUDE-PARITY"].cached_input_tokens == 10_000
    assert entries_by_identifier["MT-CLAUDE-PARITY"].cache_creation_input_tokens == 400
    assert entries_by_identifier["MT-CLAUDE-PARITY"].output_tokens == 500
  end

  test "legacy Claude usage keeps input tokens as uncached when cache buckets are present" do
    issue_id = "issue-legacy-claude-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-CLAUDE-LEGACY",
      title: "Legacy Claude usage",
      description: "Track Claude legacy cache fields",
      state: "In Progress",
      url: "https://example.org/issues/MT-CLAUDE-LEGACY"
    }

    orchestrator_name = Module.concat(__MODULE__, :LegacyClaudeUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    started_at = DateTime.utc_now()
    running_entry = running_entry_for_token_test(issue, started_at)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       AppServer.event_to_update(
         {:token_usage,
          %{
            input_tokens: 800,
            cache_read_input_tokens: 9_200,
            cache_creation_input_tokens: 400,
            output_tokens: 600,
            total_tokens: 11_000
          }}
       )}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [entry]} = snapshot

    assert entry.uncached_input_tokens == 800
    assert entry.cached_input_tokens == 9_200
    assert entry.cache_creation_input_tokens == 400
    assert entry.output_tokens == 600
  end

  test "orchestrator token accounting ignores last_token_usage without cumulative totals" do
    issue_id = "issue-last-token-ignored"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-224",
      title: "Last token ignored",
      description: "Ignore delta-only token reports",
      state: "In Progress",
      url: "https://example.org/issues/MT-224"
    }

    orchestrator_name = Module.concat(__MODULE__, :LastTokenIgnoredOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 8,
                     "output_tokens" => 3,
                     "total_tokens" => 11
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 0
    assert snapshot_entry.codex_output_tokens == 0
    assert snapshot_entry.codex_total_tokens == 0
  end

  test "orchestrator stops an issue that exhausts its token budget without retrying" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_tokens_per_issue: 10
    )

    issue_id = "issue-budget-exhausted"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-BUDGET",
      title: "Budget exhausted",
      description: "Stop once the token budget is reached",
      state: "In Progress",
      url: "https://example.org/issues/MT-BUDGET"
    }

    orchestrator_name = Module.concat(__MODULE__, :IssueBudgetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    worker_pid =
      spawn(fn ->
        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)

      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    initial_state = get_orchestrator_state(pid)
    run_id = "run-budget-exhausted"
    started_at = DateTime.utc_now()

    running_entry = %{
      repo_key: Config.repo_key!(),
      pid: worker_pid,
      ref: make_ref(),
      run_id: run_id,
      identifier: issue.identifier,
      issue: issue,
      session_id: "thread-budget",
      agent_module: StopSessionAgent,
      agent_session: %{recipient: self()},
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    assert :ok =
             RunStore.put_run(%{
               repo_key: Config.repo_key!(),
               run_id: run_id,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               title: issue.title,
               state: issue.state,
               status: "running",
               attempt: 1,
               started_at: started_at,
               ended_at: nil,
               error: nil,
               worker_host: nil,
               workspace_path: nil,
               session_id: "thread-budget",
               transcript_path: nil,
               codex_app_server_pid: nil,
               turn_count: 0,
               tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
               runtime_seconds: 0,
               last_event: nil,
               last_event_at: nil,
               updated_at: started_at
             })

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    assert :ok = SymphonyElixir.Notifications.subscribe()

    warning =
      capture_log(fn ->
        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :notification,
             payload: %{
               "method" => "thread/tokenUsage/updated",
               "params" => %{
                 "tokenUsage" => %{
                   "total" => %{"inputTokens" => 7, "outputTokens" => 5, "totalTokens" => 12}
                 }
               }
             },
             timestamp: DateTime.utc_now()
           }}
        )

        assert %{running: []} = wait_for_snapshot(pid, &(&1.running == []))
      end)

    assert warning =~ "Issue token budget exhausted"
    assert warning =~ "issue_identifier=MT-BUDGET"

    final_state = get_orchestrator_state(pid)
    assert MapSet.member?(final_state.budget_exhausted, issue_id)
    refute Map.has_key?(final_state.retry_attempts, issue_id)
    refute MapSet.member?(final_state.claimed, issue_id)
    refute Orchestrator.should_dispatch_issue_for_test(issue, final_state)

    run_record = wait_for_run_record(&(&1.run_id == run_id))
    assert run_record.status == "budget_exhausted"
    assert run_record.error =~ "token budget exhausted"

    assert run_record.tokens == %{
             input_tokens: 7,
             uncached_input_tokens: 7,
             cached_input_tokens: 0,
             cache_creation_input_tokens: 0,
             output_tokens: 5,
             total_tokens: 12
           }

    refute Process.alive?(worker_pid)
    assert_receive :agent_stop_session_called

    assert_receive {:notification_event,
                    %SymphonyElixir.Notifications.Event{
                      event: "budget_exceeded",
                      issue_identifier: "MT-BUDGET",
                      metadata: %{scope: "issue", limit: 10}
                    }},
                   500
  end

  test "orchestrator pauses new dispatch when the daily token budget is exhausted" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_tokens_per_day: 10,
      max_concurrent_agents: 1
    )

    issue = %Issue{
      id: "issue-daily-budget",
      identifier: "MT-DAILY",
      title: "Daily budget",
      description: "Do not dispatch once the daily budget is gone",
      state: "Todo",
      url: "https://example.org/issues/MT-DAILY"
    }

    orchestrator_name = Module.concat(__MODULE__, :DailyBudgetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{state | budget_daily_used: 10}
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    warning =
      capture_log(fn ->
        send(pid, :run_poll_cycle)

        assert %{running: [], budget: budget} =
                 wait_for_snapshot(pid, fn snapshot ->
                   snapshot.running == [] and snapshot.budget.daily_paused == true and
                     snapshot.polling.checking? == false
                 end)

        assert budget.daily_used == 10
        assert budget.daily_remaining == 0
      end)

    assert warning =~ "Daily token budget exhausted"
    assert warning =~ "pausing new dispatch"
  end

  test "orchestrator pauses new dispatch when workspace free space is below threshold" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-quota-test-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      max_concurrent_agents: 1,
      workspace_lifecycle: %{
        age_gc_enabled: false,
        min_free_bytes: 9_000_000_000_000_000
      }
    )

    issue = %Issue{
      id: "issue-workspace-quota",
      identifier: "MT-QUOTA",
      title: "Workspace quota",
      description: "Do not dispatch once workspace disk is too low",
      state: "Todo",
      url: "https://example.org/issues/MT-QUOTA"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :WorkspaceQuotaOrchestrator)

    warning =
      capture_log(fn ->
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        try do
          send(pid, :run_poll_cycle)

          snapshot =
            wait_for_snapshot(pid, fn snapshot ->
              snapshot.running == [] and get_in(snapshot, [:workspace_lifecycle, :quota_paused]) == true
            end)

          assert snapshot.workspace_lifecycle.quota_reason =~ "workspace free space below threshold"
          assert snapshot.workspace_lifecycle.min_free_bytes == 9_000_000_000_000_000

          # The startup lifecycle check can mark the quota paused before the poll
          # cycle logs the pause, so wait for the logged flag before reading the log.
          wait_for_orchestrator_state(pid, & &1.workspace_quota_logged, 5_000)

          assert RunStore.list_runs() == []
        after
          if Process.alive?(pid), do: GenServer.stop(pid)
          File.rm_rf(workspace_root)
        end
      end)

    assert warning =~ "Workspace free-space threshold not met"
    assert warning =~ "pausing new dispatch"
  end

  test "orchestrator startup logs and deletes orphan workspaces" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-startup-orphan-test-#{System.unique_integer([:positive])}"
      )

    orphan_workspace = Path.join([workspace_root, "default", "MT-ORPHAN"])
    File.mkdir_p!(orphan_workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      workspace_lifecycle: %{
        age_gc_enabled: false,
        orphan_action: "delete"
      }
    )

    orchestrator_name = Module.concat(__MODULE__, :StartupOrphanSweepOrchestrator)

    log =
      capture_log(fn ->
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        try do
          assert %{running: []} =
                   wait_for_snapshot(
                     pid,
                     fn _snapshot ->
                       not File.exists?(orphan_workspace)
                     end,
                     500
                   )

          wait_for_orchestrator_state(pid, &is_nil(&1.startup_workspace_lifecycle_task_ref), 500)
        after
          if Process.alive?(pid), do: GenServer.stop(pid)
        end
      end)

    assert log =~ "Workspace startup orphan sweep completed"
    assert log =~ "action=delete"
    refute File.exists?(orphan_workspace)
    File.rm_rf(workspace_root)
  end

  test "orchestrator startup age GC reclaims stale crashed-run workspaces" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-startup-age-gc-test-#{System.unique_integer([:positive])}"
      )

    stale_workspace = Path.join([workspace_root, "default", "MT-STALE"])
    File.mkdir_p!(stale_workspace)
    File.touch!(stale_workspace, {{2026, 1, 1}, {0, 0, 0}})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      workspace_lifecycle: %{
        max_age_days: 1,
        orphan_action: "delete"
      }
    )

    :ok =
      RunStore.put_run(%{
        repo_key: Config.repo_key!(),
        run_id: "run-stale-workspace",
        issue_id: "issue-stale-workspace",
        issue_identifier: "MT-STALE",
        status: "failure",
        started_at: DateTime.add(DateTime.utc_now(), -3 * 86_400, :second),
        workspace_path: stale_workspace
      })

    orchestrator_name = Module.concat(__MODULE__, :StartupAgeGcOrchestrator)

    log =
      capture_log(fn ->
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        try do
          assert %{running: []} =
                   wait_for_snapshot(
                     pid,
                     fn _snapshot ->
                       not File.exists?(stale_workspace)
                     end,
                     500
                   )

          wait_for_orchestrator_state(pid, &is_nil(&1.startup_workspace_lifecycle_task_ref), 500)
        after
          if Process.alive?(pid), do: GenServer.stop(pid)
        end
      end)

    assert log =~ "Workspace age GC completed"
    refute File.exists?(stale_workspace)
    File.rm_rf(workspace_root)
  end

  test "orchestrator startup lifecycle cleans every configured repo" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-startup-multi-repo-lifecycle-test-#{System.unique_integer([:positive])}"
      )

    default_orphan_workspace = Path.join([workspace_root, "default", "MT-ORPHAN"])
    api_orphan_workspace = Path.join([workspace_root, "api", "API-ORPHAN"])
    api_stale_workspace = Path.join([workspace_root, "api", "API-STALE"])

    File.mkdir_p!(default_orphan_workspace)
    File.mkdir_p!(api_orphan_workspace)
    File.mkdir_p!(api_stale_workspace)
    File.touch!(api_stale_workspace, System.os_time(:second) - 30 * 86_400)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      workspace_lifecycle: %{
        max_age_days: 1,
        orphan_action: "delete"
      },
      repos: [
        [key: "default", workflow: Workflow.workflow_file_path(), team: "Test"],
        [key: "api", workflow: Workflow.workflow_file_path(), team: "API"]
      ]
    )

    :ok = RunStore.clear()

    :ok =
      RunStore.put_run(%{
        repo_key: "api",
        run_id: "run-api-stale-workspace",
        issue_id: "issue-api-stale-workspace",
        issue_identifier: "API-STALE",
        status: "failure",
        started_at: DateTime.add(DateTime.utc_now(), -3 * 86_400, :second),
        workspace_path: api_stale_workspace
      })

    orchestrator_name = Module.concat(__MODULE__, :StartupMultiRepoLifecycleOrchestrator)

    log =
      capture_log(fn ->
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        try do
          wait_for_snapshot(
            pid,
            fn _snapshot ->
              not File.exists?(default_orphan_workspace) and
                not File.exists?(api_orphan_workspace) and
                not File.exists?(api_stale_workspace)
            end,
            1_000
          )

          wait_for_orchestrator_state(pid, &is_nil(&1.startup_workspace_lifecycle_task_ref), 500)
        after
          if Process.alive?(pid), do: GenServer.stop(pid)
        end
      end)

    assert log =~ "repo_key=api identifier=API-ORPHAN"
    assert log =~ "repo_key=api identifier=API-STALE"
    assert log =~ "reason=age_gc"
    refute File.exists?(default_orphan_workspace)
    refute File.exists?(api_orphan_workspace)
    refute File.exists?(api_stale_workspace)
    File.rm_rf(workspace_root)
  end

  test "periodic workspace age GC continues after one repo scan fails" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-periodic-multi-repo-age-gc-test-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000,
      quality_gate: %{enabled: false},
      workspace_lifecycle: %{
        max_age_days: 1,
        orphan_action: "delete"
      },
      repos: [
        [key: "bad", workflow: Workflow.workflow_file_path(), team: "Bad"],
        [key: "api", workflow: Workflow.workflow_file_path(), team: "API"]
      ]
    )

    issue = %Issue{
      id: "issue-periodic-age-gc",
      identifier: "API-GC",
      title: "Periodic age GC",
      state: "Todo",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :PeriodicMultiRepoAgeGcOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    try do
      wait_for_orchestrator_state(pid, &is_nil(&1.startup_workspace_lifecycle_task_ref), 1_000)
      assert {:ok, _pause} = Orchestrator.pause_dispatch(pid, "periodic age gc test")

      File.mkdir_p!(workspace_root)
      File.write!(Path.join(workspace_root, "bad"), "not a directory")

      api_stale_workspace = Path.join([workspace_root, "api", "API-STALE-PERIODIC"])
      File.mkdir_p!(api_stale_workspace)
      File.touch!(api_stale_workspace, System.os_time(:second) - 30 * 86_400)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | workspace_lifecycle_last_check_at_ms: nil,
            repo_poll_due_at_ms: %{"bad" => 0}
        }
      end)

      log =
        capture_log(fn ->
          # A startup cycle still in flight would skip this one, and with it the age GC.
          wait_for_poll_cycle_idle(pid)
          send(pid, :run_poll_cycle)

          wait_for_snapshot(
            pid,
            fn snapshot ->
              snapshot.polling.checking? == false and not File.exists?(api_stale_workspace)
            end,
            1_000
          )

          wait_for_orchestrator_state(pid, &(&1.dispatch_readiness_tasks == %{}), 500)
        end)

      assert log =~ "Skipping workspace age GC for repo_key=bad"
      refute File.exists?(api_stale_workspace)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(workspace_root)
    end
  end

  test "orchestrator startup age GC protects workspaces active before result applies" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-startup-age-gc-active-test-#{System.unique_integer([:positive])}"
      )

    active_workspace = Path.join([workspace_root, "default", "MT-ACTIVE-STARTUP"])
    File.mkdir_p!(active_workspace)
    # Stale relative to now so the test never depends on the wall clock being at
    # or past a hard-coded date (max_age_days is 1 in this workflow).
    File.touch!(active_workspace, System.os_time(:second) - 30 * 86_400)

    issue = %Issue{
      id: "issue-active-startup-gc",
      identifier: "MT-ACTIVE-STARTUP",
      title: "Active during startup GC",
      state: "Backlog"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      workspace_lifecycle: %{
        max_age_days: 1,
        orphan_action: "delete"
      }
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_candidate_sleep_ms, 300)

    orchestrator_name = Module.concat(__MODULE__, :StartupAgeGcActiveOrchestrator)

    # A stand-in agent, not the test process: if a poll ever stopped the agent, stopping
    # the test process would kill the test.
    worker_pid =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    try do
      wait_for_orchestrator_state(pid, &is_reference(&1.startup_workspace_lifecycle_task_ref), 500)

      :sys.replace_state(pid, fn state ->
        running_entry = %{
          pid: worker_pid,
          ref: nil,
          repo_key: "default",
          identifier: issue.identifier,
          issue: issue,
          workspace_path: active_workspace,
          started_at: DateTime.utc_now(),
          last_codex_timestamp: nil,
          last_codex_message: nil,
          last_codex_event: nil,
          # Freshly dispatched: a poll that reconciles the stale Backlog state keeps the run.
          state_reconcile_grace_until_ms: System.monotonic_time(:millisecond) + 60_000
        }

        %{
          state
          | running: Map.put(state.running, issue.id, running_entry),
            claimed: MapSet.put(state.claimed, issue.id)
        }
      end)

      wait_for_orchestrator_state(pid, &is_nil(&1.startup_workspace_lifecycle_task_ref), 1_000)

      assert File.exists?(active_workspace)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
      if Process.alive?(worker_pid), do: send(worker_pid, :finish)

      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_candidate_sleep_ms)
      File.rm_rf(workspace_root)
    end
  end

  test "orchestrator snapshots include default finite token budgets when omitted" do
    write_workflow_without_token_budget_keys!()

    orchestrator_name = Module.concat(__MODULE__, :DefaultBudgetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.budget.per_issue_limit == 500_000
    assert snapshot.budget.daily_limit == 5_000_000
    assert snapshot.budget.daily_used == 0
    assert snapshot.budget.daily_remaining == 5_000_000
    refute snapshot.budget.daily_paused
  end

  test "orchestrator snapshot exposes dispatch_state with active? and blockers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 1
    )

    orchestrator_name = Module.concat(__MODULE__, :DispatchStateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    snapshot = GenServer.call(pid, :snapshot)

    assert is_map(snapshot.dispatch_state)
    assert is_boolean(snapshot.dispatch_state.active?)
    assert is_list(snapshot.dispatch_state.blockers)

    Enum.each(snapshot.dispatch_state.blockers, fn blocker ->
      assert blocker.kind in [:manual, :budget, :missing_api_key, :tracker_unavailable]
    end)
  end

  test "orchestrator records tracker poll failures and resets on success" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      poll_interval_ms: 5_000
    )

    repos = [%{name: "default"}]
    failure_fetcher = fn _repo -> {:error, {:linear_api_request, :timeout}} end
    success_fetcher = fn _repo -> {:ok, []} end
    state = %Orchestrator.State{poll_interval_ms: 5_000}

    assert {:error, {:linear_api_request, :timeout}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, failure_fetcher, 0)

    assert %{
             tracker: :linear,
             reason: :linear_api_request,
             since: %DateTime{} = since,
             consecutive_failures: 1
           } = state.tracker_health

    assert {:error, {:linear_api_request, :timeout}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, failure_fetcher, 5_000)

    assert %{since: ^since, consecutive_failures: 2} = state.tracker_health

    assert {:ok, %{dispatchable: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, failure_fetcher, 10_000)

    assert %{since: ^since, consecutive_failures: 3} = state.tracker_health

    config_failure_fetcher = fn _repo ->
      {:error, {:invalid_workflow_config, "notifications.channels entries with kind: slack require webhook_url"}}
    end

    assert {:ok, %{dispatchable: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, config_failure_fetcher, 15_000)

    assert %{
             reason: {:invalid_workflow_config, "notifications.channels entries with kind: slack require webhook_url"},
             consecutive_failures: 4
           } = state.tracker_health

    assert {:ok, %{dispatchable: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, success_fetcher, 20_000)

    assert %{tracker: :linear, reason: nil, since: nil, consecutive_failures: 0} = state.tracker_health
  end

  test "review agent repo gate preserves enabled and disabled config without logging errors" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      review_agent: [enabled: true, kind: "codex", command: "codex app-server", max_iterations: 1]
    )

    enabled_log =
      capture_log([level: :error], fn ->
        assert Orchestrator.review_agent_enabled_for_repo_for_test("default")
      end)

    assert enabled_log == ""

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      review_agent: [enabled: false]
    )

    disabled_log =
      capture_log([level: :error], fn ->
        refute Orchestrator.review_agent_enabled_for_repo_for_test("default")
      end)

    assert disabled_log == ""
  end

  test "review agent repo gate logs expected review-agent config failures before returning disabled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      review_agent: [enabled: "sometimes"]
    )

    log =
      capture_log([level: :error], fn ->
        refute Orchestrator.review_agent_enabled_for_repo_for_test("default")
      end)

    assert log =~ "review_agent_config_failed repo_key=default"
    assert log =~ "reason=ArgumentError:"
  end

  test "review agent repo gate lets unexpected config exceptions bubble" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    previous_file_reader = Application.fetch_env(:symphony_elixir, :config_cache_file_reader)

    on_exit(fn ->
      case previous_file_reader do
        {:ok, file_reader} -> Application.put_env(:symphony_elixir, :config_cache_file_reader, file_reader)
        :error -> Application.delete_env(:symphony_elixir, :config_cache_file_reader)
      end

      Cache.clear()
    end)

    Application.put_env(:symphony_elixir, :config_cache_file_reader, fn _path ->
      raise RuntimeError, "config cache exploded"
    end)

    Cache.clear()

    assert_raise RuntimeError, "config cache exploded", fn ->
      Orchestrator.review_agent_enabled_for_repo_for_test("default")
    end
  end

  test "current tracker kind logs expected config failures before returning unknown" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: %{bad: "value"})

    log =
      capture_log([level: :error], fn ->
        assert Orchestrator.current_tracker_kind_for_test() == :unknown
      end)

    assert log =~ "tracker_config_failed"
    assert log =~ "reason=ArgumentError:"
  end

  test "orchestrator snapshot stacks tracker unavailable with other dispatch blockers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: nil,
      max_concurrent_agents: 1,
      max_tokens_per_day: 10
    )

    orchestrator_name = Module.concat(__MODULE__, :TrackerUnavailableDispatchStateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | pause: %{paused: true, reason: "maintenance", paused_at: ~U[2026-05-08 10:00:00Z]},
          budget_daily_used: 10,
          budget_day_started_on: Date.utc_today(),
          tracker_health: %{
            tracker: :linear,
            reason: :missing_linear_api_token,
            since: ~U[2026-05-08 10:05:00Z],
            consecutive_failures: 3
          }
      }
    end)

    snapshot = GenServer.call(pid, :snapshot)
    kinds = Enum.map(snapshot.dispatch_state.blockers, & &1.kind)

    assert snapshot.dispatch_state.active? == false
    assert :manual in kinds
    assert :budget in kinds
    assert :missing_api_key in kinds
    assert :tracker_unavailable in kinds
  end

  test "operator pause is exposed in snapshots and preserves retry queue without dispatching" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 1,
      quality_gate: %{enabled: false}
    )

    issue = %Issue{
      id: "issue-operator-pause",
      identifier: "MT-PAUSE",
      title: "Operator pause",
      description: "Do not dispatch during operator pause",
      state: "Todo",
      url: "https://example.org/issues/MT-PAUSE"
    }

    assert :ok = RunStore.set_paused(true, "deploy window")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :OperatorPauseOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    warning =
      capture_log(fn ->
        send(pid, :run_poll_cycle)

        assert %{running: [], pause: %{paused: true, reason: "deploy window", paused_at: %DateTime{}}} =
                 wait_for_snapshot(pid, fn snapshot ->
                   snapshot.running == [] and snapshot.pause.paused == true and
                     snapshot.polling.checking? == false
                 end)
      end)

    assert warning =~ "Operator dispatch pause active"
    assert RunStore.list_runs() == []

    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond)

    # A readiness or quality gate task still in flight when the retry fires must not
    # hide the pause: the retry reports the pause, not the deferral.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | dispatch_readiness_tasks: Map.put(state.dispatch_readiness_tasks, make_ref(), %{kind: :poll, issues: []}),
          quality_gate_tasks: Map.put(state.quality_gate_tasks, make_ref(), :poll),
          retry_attempts: %{
            issue.id => %{
              attempt: 1,
              timer_ref: nil,
              retry_token: retry_token,
              due_at_ms: due_at_ms,
              identifier: issue.identifier,
              error: "agent exited: :boom",
              worker_host: nil,
              workspace_path: nil
            }
          },
          claimed: MapSet.put(state.claimed, issue.id)
      }
    end)

    send(pid, {:retry_issue, issue.id, retry_token})

    assert %{running: [], retrying: [%{issue_id: "issue-operator-pause", error: "dispatch paused by operator"}]} =
             wait_for_snapshot(
               pid,
               fn
                 %{
                   running: [],
                   retrying: [%{issue_id: "issue-operator-pause", error: "dispatch paused by operator"}]
                 } ->
                   true

                 _snapshot ->
                   false
               end,
               1_000
             )

    assert {:ok, %{paused: false, reason: nil, paused_at: nil}} =
             Orchestrator.resume_dispatch(orchestrator_name)
  end

  test "stop_running stops the tracked session, marks the run stopped, and cleans workspace" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-stop-running-test-#{System.unique_integer([:positive])}"
      )

    marker = Path.join(workspace_root, "before_remove.marker")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_before_remove: "printf stopped > #{marker}"
    )

    issue = %Issue{
      id: "issue-stop-running",
      identifier: "MT-STOP",
      title: "Stop running",
      description: "Terminate one running issue",
      state: "In Progress",
      url: "https://example.org/issues/MT-STOP"
    }

    workspace = Path.join([workspace_root, "default", issue.identifier])
    File.mkdir_p!(workspace)

    orchestrator_name = Module.concat(__MODULE__, :StopRunningOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end

      File.rm_rf(workspace_root)
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    worker_ref = Process.monitor(worker_pid)
    started_at = DateTime.utc_now()
    run_id = "run-stop-running"

    running_entry = %{
      repo_key: Config.repo_key!(),
      pid: worker_pid,
      ref: worker_ref,
      run_id: run_id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: workspace,
      session_id: "thread-stop-turn-stop",
      transcript_path: nil,
      transcript_buffer: :queue.new(),
      transcript_buffer_size: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      agent_module: StopSessionAgent,
      agent_session: %{recipient: self()},
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 1,
      retry_attempt: 0,
      started_at: started_at
    }

    assert :ok =
             RunStore.put_run(%{
               repo_key: Config.repo_key!(),
               run_id: run_id,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               title: issue.title,
               state: issue.state,
               status: "running",
               attempt: 1,
               started_at: started_at,
               workspace_path: workspace,
               session_id: "thread-stop-turn-stop"
             })

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{issue.id => running_entry},
          claimed: MapSet.put(state.claimed, issue.id)
      }
    end)

    assert {:ok,
            %{
              stopped: true,
              issue_id: "issue-stop-running",
              issue_identifier: "MT-STOP",
              session_id: "thread-stop-turn-stop"
            }} = Orchestrator.stop_running(orchestrator_name, issue.identifier)

    assert_receive :agent_stop_session_called
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}

    assert %{running: []} = GenServer.call(pid, :snapshot)
    assert :ok = WorkspaceCleanup.await(issue.identifier)
    assert File.read!(marker) == "stopped"
    refute File.exists?(workspace)

    assert [%{run_id: ^run_id, status: "stopped", error: "agent stopped by operator"}] =
             RunStore.list_runs()

    assert {:ok, %{stopped: false, issue_id: "MT-STOP"}} =
             Orchestrator.stop_running(orchestrator_name, issue.identifier)
  end

  test "stop_running leaves the workspace removal to WorkspaceCleanup and keeps answering while its before_remove hook runs" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-stop-running-slow-remove-#{System.unique_integer([:positive])}")
    hook_log = Path.join(workspace_root, "hook.log")
    release = Path.join(workspace_root, "release")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000,
      hook_before_remove: """
      echo started >> #{hook_log}
      while [ ! -f #{release} ]; do sleep 0.05; done
      echo finished >> #{hook_log}
      """
    )

    slow_issue = %Issue{id: "issue-slow-remove", identifier: "MT-SLOW-REMOVE", title: "Slow remove", state: "In Progress"}
    other_issue = %Issue{id: "issue-other-stop", identifier: "MT-OTHER-STOP", title: "Other", state: "In Progress"}
    workspace = Path.join([workspace_root, "default", slow_issue.identifier])
    File.mkdir_p!(workspace)

    orchestrator_name = Module.concat(__MODULE__, :SlowRemoveOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      File.write(release, "")
      WorkspaceCleanup.await(slow_issue.identifier)

      if Process.alive?(pid) do
        stop_process(pid)
      end

      File.rm_rf(workspace_root)
    end)

    # The startup poll would stop runs the memory tracker does not list.
    wait_for_poll_cycle_idle(pid)
    {slow_worker, slow_ref} = start_blocked_worker()
    {other_worker, other_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            slow_issue.id => running_entry(slow_issue, slow_worker, slow_ref, "run-slow-remove", started_at),
            other_issue.id => running_entry(other_issue, other_worker, other_ref, "run-other-stop", started_at)
          },
          claimed: MapSet.new([slow_issue.id, other_issue.id])
      }
    end)

    assert {:ok, %{stopped: true}} = Orchestrator.stop_running(orchestrator_name, slow_issue.identifier)
    assert_receive {:DOWN, ^slow_ref, :process, ^slow_worker, :shutdown}
    assert wait_for_file_contents(hook_log, "started\n", 5_000)

    # The hook is still blocked: the orchestrator answers and handles another issue meanwhile.
    assert %{running: [%{issue_id: "issue-other-stop"}]} = GenServer.call(pid, :snapshot, 1_000)
    assert {:ok, %{stopped: true}} = Orchestrator.stop_running(orchestrator_name, other_issue.identifier)
    assert_receive {:DOWN, ^other_ref, :process, ^other_worker, :shutdown}
    assert %{running: []} = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert File.read!(hook_log) == "started\n"
    assert File.exists?(workspace)

    File.write!(release, "")
    assert :ok = WorkspaceCleanup.await(slow_issue.identifier)
    assert File.read!(hook_log) == "started\nfinished\n"
    refute File.exists?(workspace)
  end

  test "stop_running returns before slow stop_session cleanup completes" do
    issue = %Issue{
      id: "issue-stop-running-slow-cleanup",
      identifier: "MT-STOP-SLOW",
      title: "Stop running with slow cleanup",
      description: "Do not block the orchestrator on cleanup",
      state: "In Progress",
      url: "https://example.org/issues/MT-STOP-SLOW"
    }

    orchestrator_name = Module.concat(__MODULE__, :StopRunningSlowCleanupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      terminate_task_supervisor_children()

      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-stop-running-slow-cleanup"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        session_id: "thread-stop-turn-slow",
        agent_module: SlowStopSessionAgent,
        agent_session: %{recipient: self()},
        turn_count: 1
      })

    put_running_run!(issue, run_id, started_at, %{session_id: "thread-stop-turn-slow"})
    put_running_entry(pid, issue, running_entry)

    assert {:ok, %{stopped: true}} = Orchestrator.stop_running(orchestrator_name, issue.identifier)

    # The cleanup is still waiting for its release, so stop_running did not wait on it.
    assert_receive {:slow_stop_session_started, cleanup_pid}, 5_000
    assert {:current_function, {SlowStopSessionAgent, :stop_session, 1}} = Process.info(cleanup_pid, :current_function)
    send(cleanup_pid, :release_slow_stop_session)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}, 5_000

    assert [%{run_id: ^run_id, status: "stopped", error: "agent stopped by operator"}] =
             RunStore.list_runs()
  end

  test "terminal running issue stops agent session while removing workspace" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-terminal-cleanup-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{
      id: "issue-terminal-cleanup",
      identifier: "MT-DONE",
      title: "Terminal cleanup",
      description: "Stop session when terminal reconciliation removes workspace",
      state: "In Progress",
      url: "https://example.org/issues/MT-DONE"
    }

    workspace = Path.join([workspace_root, "default", issue.identifier])
    File.mkdir_p!(workspace)

    orchestrator_name = Module.concat(__MODULE__, :TerminalCleanupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      terminate_task_supervisor_children()

      if Process.alive?(pid) do
        stop_process(pid)
      end

      File.rm_rf(workspace_root)
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-terminal-cleanup"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        workspace_path: workspace,
        session_id: "thread-terminal-cleanup",
        agent_module: StopSessionAgent,
        agent_session: %{recipient: self()},
        turn_count: 1
      })

    put_running_run!(issue, run_id, started_at, %{
      workspace_path: workspace,
      session_id: "thread-terminal-cleanup"
    })

    put_running_entry(pid, issue, running_entry)
    terminal_issue = %{issue | state: "Done"}

    :sys.replace_state(pid, fn state ->
      Orchestrator.reconcile_issue_states_for_test([terminal_issue], state)
    end)

    assert_receive :agent_stop_session_called
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}

    assert %{running: []} = GenServer.call(pid, :snapshot)
    refute File.exists?(workspace)
  end

  test "stop_running records stop_session cleanup failures in run history" do
    issue = %Issue{
      id: "issue-stop-running-cleanup-failure",
      identifier: "MT-STOP-FAIL",
      title: "Stop running cleanup failure",
      description: "Record cleanup failures",
      state: "In Progress",
      url: "https://example.org/issues/MT-STOP-FAIL"
    }

    orchestrator_name = Module.concat(__MODULE__, :StopRunningCleanupFailureOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-stop-running-cleanup-failure"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        session_id: "thread-stop-turn-failure",
        agent_module: FailingStopSessionAgent,
        agent_session: %{recipient: self()},
        turn_count: 1
      })

    put_running_run!(issue, run_id, started_at, %{session_id: "thread-stop-turn-failure"})
    put_running_entry(pid, issue, running_entry)

    assert {:ok, %{stopped: true}} = Orchestrator.stop_running(orchestrator_name, issue.identifier)
    assert_receive :failing_stop_session_called
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}

    assert %{status: "stopped", error: error} =
             wait_for_run_record(fn
               %{run_id: ^run_id, error: error} when is_binary(error) ->
                 String.contains?(error, "stop_session cleanup failed")

               _record ->
                 false
             end)

    assert error =~ ":remote_cleanup_failed"
  end

  test "stop_running records stop_session cleanup start failures in run history" do
    issue = %Issue{
      id: "issue-stop-running-cleanup-start-failure",
      identifier: "MT-STOP-START-FAIL",
      title: "Stop running cleanup start failure",
      description: "Record cleanup task start failures",
      state: "In Progress",
      url: "https://example.org/issues/MT-STOP-START-FAIL"
    }

    orchestrator_name = Module.concat(__MODULE__, :StopRunningCleanupStartFailureOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      ensure_symphony_started!()

      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-stop-running-cleanup-start-failure"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        session_id: "thread-stop-turn-start-failure",
        agent_module: StopSessionAgent,
        agent_session: %{recipient: self()},
        turn_count: 1
      })

    put_running_run!(issue, run_id, started_at, %{session_id: "thread-stop-turn-start-failure"})
    put_running_entry(pid, issue, running_entry)

    assert is_pid(Process.whereis(SymphonyElixir.TaskSupervisor))
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)
    refute Process.whereis(SymphonyElixir.TaskSupervisor)

    assert {:ok, %{stopped: true}} = Orchestrator.stop_running(orchestrator_name, issue.identifier)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}
    refute_receive :agent_stop_session_called, 50

    assert %{status: "stopped", error: error} =
             wait_for_run_record(fn
               %{run_id: ^run_id, error: error} when is_binary(error) ->
                 String.contains?(error, "cleanup_task_start_failed")

               _record ->
                 false
             end)

    assert error =~ ":task_supervisor_unavailable"
  end

  test "stop_running succeeds before agent session metadata arrives" do
    issue = %Issue{
      id: "issue-stop-running-no-session-yet",
      identifier: "MT-STOP-RACE",
      title: "Stop running before session arrives",
      description: "Stop during runtime metadata race",
      state: "In Progress",
      url: "https://example.org/issues/MT-STOP-RACE"
    }

    orchestrator_name = Module.concat(__MODULE__, :StopRunningNoSessionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-stop-running-no-session-yet"

    running_entry = running_entry(issue, worker_pid, worker_ref, run_id, started_at)

    put_running_run!(issue, run_id, started_at)
    put_running_entry(pid, issue, running_entry)

    assert {:ok,
            %{
              stopped: true,
              issue_id: "issue-stop-running-no-session-yet",
              issue_identifier: "MT-STOP-RACE",
              session_id: "n/a"
            }} = Orchestrator.stop_running(orchestrator_name, issue.identifier)

    refute_receive :agent_stop_session_called, 50
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}

    assert [%{run_id: ^run_id, status: "stopped", error: "agent stopped by operator"}] =
             RunStore.list_runs()
  end

  test "orchestrator resets daily budget accounting at UTC day boundaries" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_tokens_per_day: 10
    )

    orchestrator_name = Module.concat(__MODULE__, :DailyBudgetResetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    yesterday = Date.add(Date.utc_today(), -1)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | budget_day_started_on: yesterday,
          budget_daily_used: 10,
          budget_daily_paused_logged: true
      }
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.budget.daily_used == 0
    assert snapshot.budget.daily_remaining == 10
    refute snapshot.budget.daily_paused
  end

  test "orchestrator rehydrates budget-exhausted issues across restarts while the limit still applies" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_tokens_per_issue: 10
    )

    issue_id = "issue-budget-hydrate"

    assert :ok =
             put_budget_exhausted_run(%{
               run_id: "run-budget-hydrate",
               issue_id: issue_id,
               issue_identifier: "MT-BUDGET-H",
               total_tokens: 12,
               started_at: DateTime.add(DateTime.utc_now(), -86_400, :second)
             })

    issue = %Issue{
      id: issue_id,
      identifier: "MT-BUDGET-H",
      title: "Budget hydrate",
      description: "Stay blocked after restart",
      state: "Todo",
      url: "https://example.org/issues/MT-BUDGET-H"
    }

    orchestrator_name = Module.concat(__MODULE__, :BudgetHydrateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    state = get_orchestrator_state(pid)

    assert state.budget_daily_used == 0
    assert MapSet.member?(state.budget_exhausted, issue_id)
    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "orchestrator hydrates budget state from runs across every repo partition" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_tokens_per_issue: 10
    )

    primary_repo = Config.repo_key!()
    other_repo = "other-repo-#{System.unique_integer([:positive])}"
    today = Date.utc_today()
    today_at = DateTime.new!(today, ~T[12:00:00.000], "Etc/UTC")
    other_issue_id = "issue-budget-other-repo"

    assert :ok =
             RunStore.put_run(%{
               repo_key: primary_repo,
               run_id: "run-budget-primary",
               issue_id: "issue-budget-primary",
               issue_identifier: "MT-PRIMARY",
               title: "Primary repo run",
               state: "Done",
               status: "success",
               attempt: 1,
               started_at: today_at,
               ended_at: today_at,
               tokens: %{input_tokens: 4, output_tokens: 0, total_tokens: 4}
             })

    assert :ok =
             RunStore.put_run(%{
               repo_key: other_repo,
               run_id: "run-budget-other",
               issue_id: other_issue_id,
               issue_identifier: "MT-OTHER",
               title: "Other repo budget exhausted",
               state: "Todo",
               status: "budget_exhausted",
               attempt: 1,
               started_at: today_at,
               ended_at: today_at,
               error: "token budget exhausted",
               tokens: %{input_tokens: 12, output_tokens: 0, total_tokens: 12}
             })

    orchestrator_name = Module.concat(__MODULE__, :MultiRepoBudgetHydrateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    state = get_orchestrator_state(pid)

    assert state.budget_daily_used == 16
    assert MapSet.member?(state.budget_exhausted, other_issue_id)
  end

  test "orchestrator startup reads budget state and tracked workspaces from the run index of a large store" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-startup-index-test-#{System.unique_integer([:positive])}")
    tracked_workspace = Path.join([workspace_root, "default", "MT-SEED-3"])
    orphan_workspace = Path.join([workspace_root, "default", "MT-ORPHAN"])
    File.mkdir_p!(tracked_workspace)
    File.mkdir_p!(orphan_workspace)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_tokens_per_issue: 10,
      workspace_root: workspace_root,
      workspace_lifecycle: %{age_gc_enabled: false, orphan_action: "delete"}
    )

    repo_key = Config.repo_key!()
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00.000000], "Etc/UTC")

    # 300 runs of 10 issues over the last 10 days; one in 25 ran out of budget, some under the limit.
    Enum.each(0..299, fn index ->
      assert :ok =
               RunStore.put_run(%{
                 repo_key: repo_key,
                 run_id: "run-seed-#{index}",
                 issue_id: "issue-seed-#{rem(index, 10)}",
                 issue_identifier: "MT-SEED-#{rem(index, 10)}",
                 status: if(rem(index, 25) == 0, do: "budget_exhausted", else: "success"),
                 started_at: DateTime.add(midnight, -div(index, 30) * 86_400 + rem(index, 30) * 60, :second),
                 tokens: %{total_tokens: rem(index, 13)}
               })
    end)

    # What the full scan the orchestrator used to make finds.
    runs = RunStore.list_all_runs(:all)
    expected_daily_used = runs |> Enum.filter(&(DateTime.to_date(&1.started_at) == Date.utc_today())) |> Enum.map(& &1.tokens.total_tokens) |> Enum.sum()

    expected_exhausted =
      for %{status: "budget_exhausted", issue_id: issue_id, tokens: %{total_tokens: total}} <- runs, total >= 10, into: MapSet.new(), do: issue_id

    assert expected_daily_used > 0
    assert MapSet.size(expected_exhausted) > 0

    # Written behind RunStore's back, so only a scan of the table can find it.
    raw_run = %{run_id: "run-raw", issue_id: "issue-raw", status: "budget_exhausted", started_at: midnight, tokens: %{total_tokens: 1_000}}
    assert {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({:symphony_run_store_runs, {repo_key, "run-raw"}, repo_key, "run-raw", raw_run}) end)

    orchestrator_name = Module.concat(__MODULE__, :LargeStoreStartupOrchestrator)

    capture_log(fn ->
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      try do
        state = get_orchestrator_state(pid)
        assert state.budget_daily_used == expected_daily_used
        assert state.budget_exhausted == expected_exhausted

        wait_for_orchestrator_state(pid, &is_nil(&1.startup_workspace_lifecycle_task_ref), 2_000)
      after
        if Process.alive?(pid), do: GenServer.stop(pid)
      end
    end)

    assert File.exists?(tracked_workspace)
    refute File.exists?(orphan_workspace)
  end

  test "orchestrator skips persisted budget-exhausted issues when the current limit no longer applies" do
    issue_id = "issue-budget-raised"

    assert :ok =
             put_budget_exhausted_run(%{
               run_id: "run-budget-raised",
               issue_id: issue_id,
               issue_identifier: "MT-BUDGET-R",
               total_tokens: 12,
               started_at: DateTime.utc_now()
             })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_tokens_per_issue: 20
    )

    raised_limit_orchestrator_name = Module.concat(__MODULE__, :BudgetRaisedLimitOrchestrator)
    {:ok, raised_limit_pid} = Orchestrator.start_link(name: raised_limit_orchestrator_name)

    raised_limit_state = :sys.get_state(raised_limit_pid)
    refute MapSet.member?(raised_limit_state.budget_exhausted, issue_id)

    GenServer.stop(raised_limit_pid)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    unset_limit_orchestrator_name = Module.concat(__MODULE__, :BudgetUnsetLimitOrchestrator)
    {:ok, unset_limit_pid} = Orchestrator.start_link(name: unset_limit_orchestrator_name)

    unset_limit_state = :sys.get_state(unset_limit_pid)
    refute MapSet.member?(unset_limit_state.budget_exhausted, issue_id)

    GenServer.stop(unset_limit_pid)
  end

  test "orchestrator snapshot includes retry backoff entries" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    orchestrator_name = Module.concat(__MODULE__, :RetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    retry_entry = %{
      attempt: 2,
      timer_ref: nil,
      due_at_ms: System.monotonic_time(:millisecond) + 5_000,
      identifier: "MT-500",
      error: "agent exited: :boom"
    }

    initial_state = get_orchestrator_state(pid)
    new_state = %{initial_state | retry_attempts: %{"mt-500" => retry_entry}}
    :sys.replace_state(pid, fn _ -> new_state end)

    snapshot = GenServer.call(pid, :snapshot)
    assert is_list(snapshot.retrying)

    assert [
             %{
               issue_id: "mt-500",
               attempt: 2,
               due_in_ms: due_in_ms,
               identifier: "MT-500",
               error: "agent exited: :boom"
             }
           ] = snapshot.retrying

    assert due_in_ms > 0
  end

  test "orchestrator retry error includes local codex stderr from port exits" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-port-exit-stderr",
      identifier: "MT-STDERR",
      title: "Port exit stderr",
      description: "Surface stderr on port exits",
      state: "In Progress",
      url: "https://example.org/issues/MT-STDERR"
    }

    orchestrator_name = Module.concat(__MODULE__, :PortExitStderrOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-port-exit-stderr"

    on_exit(fn ->
      send(worker_pid, :finish)

      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    running_entry = running_entry(issue, worker_pid, worker_ref, run_id, started_at)
    put_running_run!(issue, run_id, started_at)
    put_running_entry(pid, issue, running_entry)

    send(pid, {:DOWN, worker_ref, :process, worker_pid, {:port_exit, 1, %{stderr: "fatal: missing --verbose flag"}}})

    snapshot =
      wait_for_snapshot(pid, fn
        %{retrying: [%{issue_id: "issue-port-exit-stderr"}]} -> true
        _ -> false
      end)

    assert [
             %{
               issue_id: "issue-port-exit-stderr",
               identifier: "MT-STDERR",
               error: "agent exited: port_exit 1; stderr: fatal: missing --verbose flag"
             }
           ] = snapshot.retrying
  end

  test "orchestrator retry error includes claude diagnostic output from exit statuses" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-exit-status-stderr",
      identifier: "MT-CLAUDE-STDERR",
      title: "Claude exit stderr",
      description: "Surface Claude stderr on early exits",
      state: "In Progress",
      url: "https://example.org/issues/MT-CLAUDE-STDERR"
    }

    orchestrator_name = Module.concat(__MODULE__, :ExitStatusStderrOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-exit-status-stderr"

    on_exit(fn ->
      send(worker_pid, :finish)

      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    running_entry = running_entry(issue, worker_pid, worker_ref, run_id, started_at)
    put_running_run!(issue, run_id, started_at)
    put_running_entry(pid, issue, running_entry)

    send(pid, {:DOWN, worker_ref, :process, worker_pid, {:exit_status, 7, %{stderr: "fatal: bad claude flag"}}})

    snapshot =
      wait_for_snapshot(pid, fn
        %{retrying: [%{issue_id: "issue-exit-status-stderr"}]} -> true
        _ -> false
      end)

    assert [
             %{
               issue_id: "issue-exit-status-stderr",
               identifier: "MT-CLAUDE-STDERR",
               error: "agent exited: exit_status 7; stderr: fatal: bad claude flag"
             }
           ] = snapshot.retrying
  end

  test "orchestrator watches completed issues in non-active non-terminal states" do
    issue_id = "issue-watch"
    last_ran_at = DateTime.add(DateTime.utc_now(), -7_200, :second)
    started_at = DateTime.add(last_ran_at, -180, :second)
    issue_url = "https://linear.app/example/issue/MT-WATCH"
    pull_request_url = "https://github.com/example/repo/pull/456"

    transcript_event = %{
      event: :notification,
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "ready for review"}
      },
      timestamp: last_ran_at
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Canceled"]
    )

    waiting_issue = %Issue{
      id: issue_id,
      identifier: "MT-WATCH",
      title: "Waiting for review",
      state: "In Review",
      url: issue_url,
      pull_request_url: pull_request_url
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [waiting_issue])

    orchestrator_name = Module.concat(__MODULE__, :WatchingOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | completed: MapSet.put(state.completed, issue_id),
          completed_run_metadata: %{
            issue_id => %{
              identifier: "MT-WATCH",
              url: issue_url,
              last_ran_at: last_ran_at,
              session_id: "thread-watch-turn-watch",
              started_at: started_at,
              last_event_at: last_ran_at,
              turn_count: 3,
              tokens: %{
                input_tokens: 10,
                cached_input_tokens: 4,
                uncached_input_tokens: 6,
                output_tokens: 7,
                total_tokens: 17
              },
              transcript_buffer: [transcript_event],
              transcript_buffer_size: 1
            }
          },
          running: %{},
          watching: %{},
          retry_attempts: %{}
      }
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(pid, fn
        %{watching: [%{identifier: "MT-WATCH", state: "In Review"}]} -> true
        _ -> false
      end)

    assert snapshot.running == []
    assert snapshot.retrying == []

    assert [
             %{
               issue_id: ^issue_id,
               identifier: "MT-WATCH",
               state: "In Review",
               url: ^issue_url,
               pull_request_url: ^pull_request_url,
               last_ran_at: ^last_ran_at,
               seconds_since_last_run: seconds_since_last_run,
               session_id: "thread-watch-turn-watch",
               started_at: ^started_at,
               last_event_at: ^last_ran_at,
               turn_count: 3,
               tokens: %{
                 input_tokens: 10,
                 cached_input_tokens: 4,
                 uncached_input_tokens: 6,
                 output_tokens: 7,
                 total_tokens: 17
               },
               transcript_buffer: [^transcript_event],
               transcript_buffer_size: 1
             }
           ] = snapshot.watching

    assert seconds_since_last_run >= 7_190

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %{waiting_issue | state: "Done"}
    ])

    send(pid, :run_poll_cycle)

    assert %{watching: []} =
             wait_for_snapshot(pid, fn
               %{watching: []} -> true
               _ -> false
             end)

    final_state = get_orchestrator_state(pid)
    refute MapSet.member?(final_state.completed, issue_id)
    refute Map.has_key?(final_state.completed_run_metadata, issue_id)
  end

  test "orchestrator rehydrates persisted retry queue entries on restart" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok = RunStore.clear()

    due_at = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)

    assert :ok =
             RunStore.put_retry(%{
               repo_key: Config.repo_key!(),
               issue_id: "issue-persisted-retry",
               identifier: "MT-501",
               attempt: 4,
               due_at: due_at,
               error: "agent exited: :boom",
               reason: :stuck,
               elapsed_ms: 12_345,
               worker_host: "worker-a",
               workspace_path: "/tmp/workspaces/MT-501"
             })

    orchestrator_name = Module.concat(__MODULE__, :PersistedRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    snapshot = GenServer.call(pid, :snapshot)

    assert [
             %{
               issue_id: "issue-persisted-retry",
               identifier: "MT-501",
               attempt: 4,
               error: "agent exited: :boom",
               reason: :stuck,
               elapsed_ms: 12_345,
               worker_host: "worker-a",
               workspace_path: "/tmp/workspaces/MT-501",
               due_in_ms: due_in_ms
             }
           ] = snapshot.retrying

    assert due_in_ms > 0

    GenServer.stop(pid)
    {:ok, restarted_pid} = Orchestrator.start_link(name: orchestrator_name)

    restarted_snapshot = GenServer.call(restarted_pid, :snapshot)

    assert [
             %{
               issue_id: "issue-persisted-retry",
               identifier: "MT-501",
               attempt: 4,
               error: "agent exited: :boom",
               reason: :stuck,
               elapsed_ms: 12_345
             }
           ] = restarted_snapshot.retrying

    assert %{
             reason: :stuck,
             elapsed_ms: 12_345
           } = :sys.get_state(restarted_pid).retry_attempts["issue-persisted-retry"]

    GenServer.stop(restarted_pid)
  end

  test "orchestrator rehydrates persisted retry queue entries from every repo partition" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok = RunStore.clear()

    due_at = DateTime.add(DateTime.utc_now(), 60_000, :millisecond)

    assert :ok =
             RunStore.put_retry(%{
               repo_key: "api",
               issue_id: "issue-api-retry",
               identifier: "MT-API-RETRY",
               attempt: 2,
               due_at: due_at,
               error: "agent exited: :boom",
               workspace_path: "/tmp/workspaces/MT-API-RETRY"
             })

    orchestrator_name = Module.concat(__MODULE__, :AllRepoPersistedRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    snapshot = GenServer.call(pid, :snapshot)

    assert [
             %{
               issue_id: "issue-api-retry",
               identifier: "MT-API-RETRY",
               attempt: 2,
               error: "agent exited: :boom",
               workspace_path: "/tmp/workspaces/MT-API-RETRY"
             }
           ] = snapshot.retrying

    assert %{repo_key: "api", attempt: 2} = :sys.get_state(pid).retry_attempts["issue-api-retry"]
    assert MapSet.member?(:sys.get_state(pid).claimed, "issue-api-retry")

    GenServer.stop(pid)
  end

  test "orchestrator rehydrates watching issues from completed run history on restart" do
    issue_id = "issue-watch-restart"
    issue_identifier = "MT-WATCHR"
    issue_url = "https://linear.app/example/issue/MT-WATCHR"
    pull_request_url = "https://github.com/example/repo/pull/789"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Canceled"]
    )

    :ok = RunStore.clear()

    ended_at = DateTime.add(DateTime.utc_now(), -3_600, :second)
    started_at = DateTime.add(ended_at, -120, :second)

    transcript_event = %{
      event: :notification,
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "rehydrated transcript"}
      },
      timestamp: ended_at
    }

    # The run store keeps a row's newest 20 events, and the watching entry shows those.
    earlier_events = Enum.map(1..29, &%{event: :notification, payload: %{"n" => &1}, timestamp: started_at})
    shown_events = Enum.take(earlier_events, -19) ++ [transcript_event]

    assert :ok =
             RunStore.put_run(%{
               repo_key: Config.repo_key!(),
               run_id: "run-watch-restart",
               issue_id: issue_id,
               issue_identifier: issue_identifier,
               title: "Watch on restart",
               state: "In Progress",
               status: "success",
               attempt: 1,
               started_at: started_at,
               ended_at: ended_at,
               error: nil,
               pull_request_url: pull_request_url,
               session_id: "thread-watch-restart-turn-1",
               last_event_at: ended_at,
               turn_count: 4,
               tokens: %{
                 input_tokens: 20,
                 cached_input_tokens: 5,
                 uncached_input_tokens: 15,
                 output_tokens: 8,
                 total_tokens: 28
               },
               transcript_buffer: earlier_events ++ [transcript_event],
               transcript_buffer_size: 30,
               runtime_seconds: 120
             })

    watching_issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Watch on restart",
      state: "In Review",
      url: issue_url
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [watching_issue])
    assert :ok = SymphonyElixir.Notifications.subscribe()

    orchestrator_name = Module.concat(__MODULE__, :WatchRestartOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(pid, fn
        %{watching: [%{identifier: ^issue_identifier}]} -> true
        _ -> false
      end)

    assert [
             %{
               issue_id: ^issue_id,
               identifier: ^issue_identifier,
               state: "In Review",
               url: ^issue_url,
               pull_request_url: ^pull_request_url,
               session_id: "thread-watch-restart-turn-1",
               started_at: ^started_at,
               last_event_at: ^ended_at,
               turn_count: 4,
               tokens: %{
                 input_tokens: 20,
                 cached_input_tokens: 5,
                 uncached_input_tokens: 15,
                 output_tokens: 8,
                 total_tokens: 28
               },
               transcript_buffer: ^shown_events,
               transcript_buffer_size: 20
             }
           ] = snapshot.watching

    assert_receive {:notification_event,
                    %SymphonyElixir.Notifications.Event{
                      event: "awaiting_review",
                      issue_identifier: ^issue_identifier
                    }},
                   500

    run_record = wait_for_run_record(&(&1.run_id == "run-watch-restart"))
    assert %DateTime{} = run_record.awaiting_review_notified_at

    GenServer.stop(pid)
    flush_notification_events()

    restart_name = Module.concat(__MODULE__, :WatchRestartOrchestratorAgain)
    {:ok, restarted_pid} = Orchestrator.start_link(name: restart_name)

    on_exit(fn ->
      if Process.alive?(restarted_pid), do: stop_process(restarted_pid)
    end)

    send(restarted_pid, :run_poll_cycle)

    assert %{watching: [%{identifier: ^issue_identifier}]} =
             wait_for_snapshot(restarted_pid, fn
               %{watching: [%{identifier: ^issue_identifier}]} -> true
               _ -> false
             end)

    refute_receive {:notification_event,
                    %SymphonyElixir.Notifications.Event{
                      event: "awaiting_review",
                      issue_identifier: ^issue_identifier
                    }},
                   100
  end

  test "orchestrator skips synthetic PR runs when hydrating watching issues from run history" do
    issue_id = "issue-watch-real"
    issue_identifier = "MT-WATCH-REAL"
    synthetic_issue_id = "pr:symphony:29"
    ended_at = DateTime.add(DateTime.utc_now(), -600, :second)
    started_at = DateTime.add(ended_at, -120, :second)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Canceled"]
    )

    :ok = RunStore.clear()

    assert :ok =
             RunStore.put_run(%{
               repo_key: Config.repo_key!(),
               run_id: "run-watch-real",
               issue_id: issue_id,
               issue_identifier: issue_identifier,
               title: "Real watched issue",
               state: "In Progress",
               status: "success",
               attempt: 1,
               started_at: started_at,
               ended_at: ended_at,
               error: nil
             })

    assert :ok =
             RunStore.put_run(%{
               repo_key: Config.repo_key!(),
               run_id: "run-pr-synthetic",
               issue_id: synthetic_issue_id,
               issue_identifier: "PR-29",
               title: "Synthetic PR run",
               state: "In Progress",
               status: "success",
               attempt: 1,
               started_at: started_at,
               ended_at: ended_at,
               error: nil,
               pull_request_url: "https://github.com/example/repo/pull/29"
             })

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Real watched issue",
        state: "In Review",
        url: "https://linear.app/example/issue/MT-WATCH-REAL"
      }
    ])

    orchestrator_name = Module.concat(__MODULE__, :WatchHydrateSyntheticPrOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    state = get_orchestrator_state(pid)
    assert Map.has_key?(state.completed_run_metadata, issue_id)
    refute Map.has_key?(state.completed_run_metadata, synthetic_issue_id)

    send(pid, :run_poll_cycle)

    assert %{watching: [%{issue_id: ^issue_id, identifier: ^issue_identifier}]} =
             wait_for_snapshot(pid, fn
               %{watching: [%{issue_id: ^issue_id}]} -> true
               _ -> false
             end)
  end

  test "orchestrator persists terminal notification markers across restarts" do
    issue_id = "issue-terminal-restart"
    issue_identifier = "MT-DONE-R"
    issue_url = "https://linear.app/example/issue/MT-DONE-R"
    pull_request_url = "https://github.com/example/repo/pull/790"
    run_id = "run-terminal-restart"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Canceled"]
    )

    :ok = RunStore.clear()

    ended_at = DateTime.add(DateTime.utc_now(), -3_600, :second)

    assert :ok =
             RunStore.put_run(%{
               repo_key: Config.repo_key!(),
               run_id: run_id,
               issue_id: issue_id,
               issue_identifier: issue_identifier,
               title: "Terminal on restart",
               state: "In Review",
               status: "success",
               attempt: 1,
               started_at: DateTime.add(ended_at, -120, :second),
               ended_at: ended_at,
               error: nil,
               pull_request_url: pull_request_url,
               runtime_seconds: 120
             })

    done_issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Terminal on restart",
      state: "Done",
      url: issue_url
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [done_issue])
    assert :ok = SymphonyElixir.Notifications.subscribe()

    orchestrator_name = Module.concat(__MODULE__, :TerminalRestartOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    send(pid, :run_poll_cycle)

    assert_receive {:notification_event,
                    %SymphonyElixir.Notifications.Event{
                      event: "issue_completed",
                      issue_identifier: ^issue_identifier
                    }},
                   500

    run_record =
      wait_for_run_record(fn run ->
        Map.get(run, :run_id) == run_id and
          match?(%DateTime{}, Map.get(run, :issue_completed_notified_at)) and
          match?(%DateTime{}, Map.get(run, :watch_closed_at))
      end)

    assert %DateTime{} = run_record.issue_completed_notified_at
    assert %DateTime{} = run_record.watch_closed_at

    assert %{shipped_today: [shipped]} = wait_for_snapshot(pid, &match?(%{shipped_today: [_]}, &1))

    assert %{issue_id: ^issue_id, identifier: ^issue_identifier, title: "Terminal on restart", completed_at: %DateTime{}} =
             shipped

    GenServer.stop(pid)
    flush_notification_events()

    restart_name = Module.concat(__MODULE__, :TerminalRestartOrchestratorAgain)
    {:ok, restarted_pid} = Orchestrator.start_link(name: restart_name)

    on_exit(fn ->
      if Process.alive?(restarted_pid), do: stop_process(restarted_pid)
    end)

    # Let the boot poll cycle finish, then run one more to its end. The orchestrator
    # emits notifications while it applies a poll's result, before this returns.
    wait_for_poll_cycle_idle(restarted_pid)
    send(restarted_pid, :run_poll_cycle)
    wait_for_poll_cycle_idle(restarted_pid)

    refute_received {:notification_event,
                     %SymphonyElixir.Notifications.Event{
                       event: "issue_completed",
                       issue_identifier: ^issue_identifier
                     }}

    state = get_orchestrator_state(restarted_pid)
    refute Map.has_key?(state.completed_run_metadata, issue_id)

    # The ticket shipped today still counts after the restart, from its run's marker.
    assert %{shipped_today: [%{issue_id: ^issue_id, identifier: ^issue_identifier, repo_key: repo_key}]} =
             GenServer.call(restarted_pid, :snapshot)

    assert repo_key == Config.repo_key!()
  end

  test "shipped today drops tickets shipped on an earlier UTC day" do
    issue_id = "issue-shipped-rollover"
    issue_identifier = "MT-DONE-ROLL"
    run_id = "run-shipped-rollover"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Canceled"]
    )

    :ok = RunStore.clear()
    ended_at = DateTime.add(DateTime.utc_now(), -60, :second)

    assert :ok =
             RunStore.put_run(%{
               repo_key: Config.repo_key!(),
               run_id: run_id,
               issue_id: issue_id,
               issue_identifier: issue_identifier,
               title: "Shipped after midnight",
               state: "In Review",
               status: "success",
               attempt: 1,
               started_at: DateTime.add(ended_at, -120, :second),
               ended_at: ended_at,
               error: nil,
               pull_request_url: "https://github.com/example/repo/pull/791",
               runtime_seconds: 120
             })

    in_review_issue = %Issue{id: issue_id, identifier: issue_identifier, title: "Shipped after midnight", state: "In Review"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [in_review_issue])
    assert :ok = SymphonyElixir.Notifications.subscribe()

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :ShippedRolloverOrchestrator))

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    wait_for_poll_cycle_idle(pid)

    now = DateTime.utc_now()
    yesterday = DateTime.add(now, -1, :day)

    shipped_entry = fn id, completed_at ->
      %{issue_id: id, identifier: id, title: id, repo_key: nil, completed_at: completed_at}
    end

    :sys.replace_state(pid, fn state ->
      %{state | shipped: %{"yesterday" => shipped_entry.("yesterday", yesterday), "today" => shipped_entry.("today", now)}}
    end)

    assert %{shipped_today: [%{issue_id: "today"}]} = GenServer.call(pid, :snapshot)
    assert Map.has_key?(get_orchestrator_state(pid).shipped, "yesterday")

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{in_review_issue | state: "Done"}])
    send(pid, :run_poll_cycle)

    assert_receive {:notification_event,
                    %SymphonyElixir.Notifications.Event{
                      event: "issue_completed",
                      issue_identifier: ^issue_identifier
                    }},
                   500

    # Recording the next shipped ticket prunes the entry from the earlier day.
    assert get_orchestrator_state(pid).shipped |> Map.keys() |> Enum.sort() == [issue_id, "today"]
  end

  test "orchestrator startup marks interrupted dispatched runs as failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-interrupted-run-recovery-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-interrupted-run",
      identifier: "MT-502",
      title: "Interrupted run",
      description: "Run should survive restart as failed history",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-502"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      hook_before_run: "sleep 5",
      poll_interval_ms: 60_000,
      quality_gate: %{enabled: false}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    :ok = RunStore.clear()

    orchestrator_name = Module.concat(__MODULE__, :InterruptedRunRecoveryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    try do
      send(pid, :run_poll_cycle)

      running_record =
        wait_for_run_record(
          fn
            %{issue_id: "issue-interrupted-run", status: "running"} -> true
            _record -> false
          end,
          2_000
        )

      GenServer.stop(pid)
      terminate_task_supervisor_children()

      {:ok, restarted_pid} = Orchestrator.start_link(name: orchestrator_name)

      recovered_record =
        wait_for_run_record(fn
          %{run_id: run_id, status: "failure", error: "orchestrator restarted before worker exit"}
          when run_id == running_record.run_id ->
            true

          _record ->
            false
        end)

      assert recovered_record.issue_identifier == "MT-502"
      assert %DateTime{} = recovered_record.ended_at

      GenServer.stop(restarted_pid)
    after
      terminate_task_supervisor_children()
      File.rm_rf(test_root)
    end
  end

  test "orchestrator startup marks interrupted runs for every configured repo" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-multi-repo-interrupted-run-recovery-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      poll_interval_ms: 60_000,
      quality_gate: %{enabled: false},
      repos: [
        [key: "default", workflow: Workflow.workflow_file_path(), team: "Test"],
        [key: "api", workflow: Workflow.workflow_file_path(), team: "API"]
      ]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    :ok = RunStore.clear()

    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_run(%{
               repo_key: "default",
               run_id: "run-default-interrupted",
               issue_id: "issue-default-interrupted-run",
               issue_identifier: "MT-502",
               title: "Default interrupted run",
               status: "running",
               started_at: now,
               updated_at: now
             })

    assert :ok =
             RunStore.put_run(%{
               repo_key: "api",
               run_id: "run-api-interrupted",
               issue_id: "issue-api-interrupted-run",
               issue_identifier: "API-502",
               title: "API interrupted run",
               status: "running",
               started_at: now,
               updated_at: now
             })

    orchestrator_name = Module.concat(__MODULE__, :MultiRepoInterruptedRunRecoveryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    try do
      default_recovered_record =
        wait_for_run_record(fn
          %{run_id: "run-default-interrupted", status: "failure", error: "orchestrator restarted before worker exit"} ->
            true

          _record ->
            false
        end)

      assert default_recovered_record.issue_identifier == "MT-502"
      assert %DateTime{} = default_recovered_record.ended_at

      api_recovered_record =
        wait_for_run_record("api", fn
          %{run_id: "run-api-interrupted", status: "failure", error: "orchestrator restarted before worker exit"} ->
            true

          _record ->
            false
        end)

      assert api_recovered_record.issue_identifier == "API-502"
      assert %DateTime{} = api_recovered_record.ended_at

      GenServer.stop(pid)
    after
      terminate_task_supervisor_children()
      File.rm_rf(test_root)
    end
  end

  test "orchestrator snapshot includes poll countdown and checking status" do
    orchestrator_name = Module.concat(__MODULE__, :PollingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    now_ms = System.monotonic_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 30_000,
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: now_ms + 4_000,
          poll_check_in_progress: false
      }
    end)

    snapshot = GenServer.call(pid, :snapshot)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 30_000,
               next_poll_in_ms: due_in_ms
             }
           } = snapshot

    assert is_integer(due_in_ms)
    assert due_in_ms >= 0
    assert due_in_ms <= 4_000

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{polling: %{checking?: true, next_poll_in_ms: nil}} = snapshot
  end

  test "orchestrator triggers an immediate poll cycle shortly after startup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 5_000
    )

    orchestrator_name = Module.concat(__MODULE__, :ImmediateStartupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    assert %{polling: %{checking?: true}} =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: true}} ->
                   true

                 _ ->
                   false
               end,
               500
             )

    assert %{
             polling: %{
               checking?: false,
               next_poll_in_ms: next_poll_in_ms,
               poll_interval_ms: 5_000
             }
           } =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}}
                 when is_integer(due_in_ms) and due_in_ms <= 5_000 ->
                   true

                 _ ->
                   false
               end,
               500
             )

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
  end

  test "orchestrator poll cycle resets next refresh countdown after a check" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    orchestrator_name = Module.concat(__MODULE__, :PollCycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 50,
          poll_check_in_progress: true,
          next_poll_due_at_ms: nil
      }
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(pid, fn
        %{polling: %{checking?: false, poll_interval_ms: 50, next_poll_in_ms: next_poll_in_ms}}
        when is_integer(next_poll_in_ms) and next_poll_in_ms <= 50 ->
          true

        _ ->
          false
      end)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 50,
               next_poll_in_ms: next_poll_in_ms
             }
           } = snapshot

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
    assert next_poll_in_ms <= 50
  end

  test "watchdog restarts stuck workers with retry backoff, cleanup, and notification" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-watchdog-stuck-test-#{System.unique_integer([:positive])}"
      )

    marker = Path.join(workspace_root, "after_run.marker")
    release = Path.join(workspace_root, "after_run.release")

    # The hook runs until the test creates the release file (or on_exit removes the
    # workspace root), so the test, not the clock, decides how long cleanup takes.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      workspace_root: workspace_root,
      agent_stall_timeout_ms: 0,
      hook_after_run: "while [ -d #{workspace_root} ] && [ ! -e #{release} ]; do sleep 0.1; done; printf after >> #{marker}",
      watchdog: %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 1_000}
    )

    issue = %Issue{
      id: "issue-watchdog-stuck",
      identifier: "MT-WATCHDOG",
      title: "Watchdog stuck",
      description: "Restart a stuck worker",
      state: "In Progress",
      url: "https://example.org/issues/MT-WATCHDOG"
    }

    workspace = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(workspace)

    orchestrator_name = Module.concat(__MODULE__, :WatchdogStuckOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      terminate_task_supervisor_children()

      if Process.alive?(pid) do
        stop_process(pid)
      end

      File.rm_rf(workspace_root)
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.add(DateTime.utc_now(), -2, :second)
    last_event_at = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    run_id = "run-watchdog-stuck"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        workspace_path: workspace,
        session_id: "thread-watchdog-turn-stuck",
        last_codex_timestamp: last_event_at,
        last_codex_event: :notification,
        last_event_at: last_event_at,
        agent_module: StopSessionAgent,
        agent_session: %{recipient: self()},
        turn_count: 1,
        retry_attempt: 2
      })

    put_running_run!(issue, run_id, started_at, %{
      workspace_path: workspace,
      session_id: "thread-watchdog-turn-stuck"
    })

    put_running_entry(pid, issue, running_entry)
    assert :ok = SymphonyElixir.Notifications.subscribe()

    send(pid, :watchdog_tick)

    assert_receive :agent_stop_session_called, 5_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}, 5_000

    assert %{running: [], retrying: [%{issue_id: "issue-watchdog-stuck"}]} =
             wait_for_snapshot(
               pid,
               fn snapshot ->
                 snapshot.running == [] and length(snapshot.retrying) == 1
               end,
               5_000
             )

    # The after_run hook is still waiting for its release, so the restart did not wait on it.
    refute File.exists?(marker)
    File.write!(release, "")

    state = get_orchestrator_state(pid)

    assert %{
             attempt: 3,
             identifier: "MT-WATCHDOG",
             error: "stuck for " <> _,
             reason: :stuck,
             elapsed_ms: elapsed_ms
           } = state.retry_attempts[issue.id]

    assert elapsed_ms >= 1_000
    assert wait_for_file_contents(marker, "after", 10_000)

    assert %{status: "timeout", error: "stuck for " <> _} =
             wait_for_run_record(&(&1.run_id == run_id))

    assert_receive {:notification_event,
                    %SymphonyElixir.Notifications.Event{
                      event: "run_stuck",
                      issue_identifier: "MT-WATCHDOG",
                      session_id: "thread-watchdog-turn-stuck",
                      attempt: 3,
                      metadata: %{reason: "stuck", elapsed_ms: event_elapsed_ms}
                    }},
                   500

    assert event_elapsed_ms >= 1_000
  end

  test "watchdog does not restart workers after a recent transcript event" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      agent_stall_timeout_ms: 0,
      watchdog: %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 60_000}
    )

    issue = %Issue{
      id: "issue-watchdog-fresh",
      identifier: "MT-FRESH",
      title: "Watchdog fresh event",
      description: "Keep a progressing worker running",
      state: "In Progress"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :WatchdogFreshOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.add(DateTime.utc_now(), -120, :second)
    old_event_at = DateTime.add(DateTime.utc_now(), -120, :second)
    run_id = "run-watchdog-fresh"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        session_id: "thread-watchdog-turn-fresh",
        last_codex_timestamp: old_event_at,
        last_codex_event: :notification,
        last_event_at: old_event_at
      })

    put_running_entry(pid, issue, running_entry)

    update = %{
      event: :notification,
      payload: %{"method" => "tool/call", "params" => %{"name" => "bash"}},
      timestamp: DateTime.utc_now()
    }

    send(pid, {:codex_worker_update, issue.id, update})
    send(pid, :watchdog_tick)

    # The orchestrator handles both messages before it answers this.
    state = get_orchestrator_state(pid)
    assert Map.has_key?(state.running, issue.id)
    refute Map.has_key?(state.retry_attempts, issue.id)
    assert Process.alive?(worker_pid)

    Process.demonitor(worker_ref, [:flush])
    Process.exit(worker_pid, :shutdown)
  end

  test "watchdog leaves alone a run that only sends Claude Code tool_progress heartbeats past the threshold" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      agent_stall_timeout_ms: 0,
      watchdog: %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 1_000}
    )

    issue = %Issue{
      id: "issue-watchdog-heartbeat",
      identifier: "MT-HEARTBEAT",
      title: "Watchdog heartbeat",
      description: "Keep a run inside a long tool call running",
      state: "In Progress"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :WatchdogHeartbeatOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    # The run's last transcript event, its `tool_use`, is already past the threshold.
    tool_use_at = DateTime.add(DateTime.utc_now(), -2, :second)
    run_id = "run-watchdog-heartbeat"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, tool_use_at, %{
        session_id: "sess-heartbeat",
        last_codex_timestamp: tool_use_at,
        last_codex_event: :tool_use,
        last_codex_message: "Bash",
        last_event_at: tool_use_at
      })

    put_running_entry(pid, issue, running_entry)

    # Heartbeats take the agent runner's path: stream line, parsed event, worker update.
    for elapsed_seconds <- [3, 4] do
      line =
        ~s({"type":"tool_progress","tool_use_id":"toolu_1","tool_name":"Bash","parent_tool_use_id":null,"elapsed_time_seconds":#{elapsed_seconds},"uuid":"u-#{elapsed_seconds}","session_id":"sess-heartbeat"})

      update = line |> AppServer.parse_event() |> AppServer.event_to_update()
      send(pid, {:codex_worker_update, issue.id, update})
      send(pid, {:codex_worker_update, "issue-not-running", update})
      send(pid, :watchdog_tick)

      # The orchestrator handles the messages before it answers this.
      state = get_orchestrator_state(pid)
      assert %{last_event_at: last_event_at} = entry = state.running[issue.id]
      assert DateTime.compare(last_event_at, update.timestamp) == :eq
      assert %{last_codex_event: :tool_use, last_codex_message: "Bash", last_codex_timestamp: ^tool_use_at} = entry
      refute Map.has_key?(state.running, "issue-not-running")
      refute Map.has_key?(state.retry_attempts, issue.id)

      # Only heartbeats arrive for longer than the threshold.
      Process.sleep(600)
    end

    send(pid, :watchdog_tick)
    state = get_orchestrator_state(pid)
    assert DateTime.diff(DateTime.utc_now(), tool_use_at, :millisecond) > 3_000
    assert Map.has_key?(state.running, issue.id)
    refute Map.has_key?(state.retry_attempts, issue.id)
    assert Process.alive?(worker_pid)

    Process.demonitor(worker_ref, [:flush])
    Process.exit(worker_pid, :shutdown)
  end

  test "disabled watchdog tick is a no-op" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      agent_stall_timeout_ms: 0,
      watchdog: %{enabled: false, tick_interval_ms: 60_000, no_progress_threshold_ms: 1}
    )

    issue = %Issue{
      id: "issue-watchdog-disabled",
      identifier: "MT-DISABLED",
      title: "Watchdog disabled",
      description: "Do not restart while disabled",
      state: "In Progress"
    }

    orchestrator_name = Module.concat(__MODULE__, :WatchdogDisabledOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.add(DateTime.utc_now(), -5, :second)
    old_event_at = DateTime.add(DateTime.utc_now(), -5, :second)
    run_id = "run-watchdog-disabled"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        session_id: "thread-watchdog-turn-disabled",
        last_codex_timestamp: old_event_at,
        last_codex_event: :notification,
        last_event_at: old_event_at
      })

    put_running_entry(pid, issue, running_entry)

    send(pid, :watchdog_tick)
    state = get_orchestrator_state(pid)
    assert Map.has_key?(state.running, issue.id)
    refute Map.has_key?(state.retry_attempts, issue.id)
    assert Process.alive?(worker_pid)

    Process.demonitor(worker_ref, [:flush])
    Process.exit(worker_pid, :shutdown)
  end

  test "orchestrator restarts first-turn stalled workers with retry backoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      agent_stall_timeout_ms: 1_000,
      watchdog: %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 1_000}
    )

    issue_id = "issue-stall"
    orchestrator_name = Module.concat(__MODULE__, :StallOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = get_orchestrator_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      repo_key: Config.repo_key!(),
      run_id: "run-stall",
      identifier: "MT-STALL",
      issue: %Issue{id: issue_id, identifier: "MT-STALL", state: "In Progress"},
      session_id: "thread-stall-turn-stall",
      agent_module: StopSessionAgent,
      agent_session: %{recipient: self()},
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      last_event_at: stale_activity_at,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    checked_from_ms = System.monotonic_time(:millisecond)
    state = run_stall_check(pid)
    checked_by_ms = System.monotonic_time(:millisecond)

    refute Process.alive?(worker_pid)
    assert_receive :agent_stop_session_called, 5_000
    refute Map.has_key?(state.running, issue_id)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-STALL",
             error: "stalled for " <> _
           } = state.retry_attempts[issue_id]

    # The first failure retry backs off 10 s from when the stall check ran.
    assert is_integer(due_at_ms)
    assert (due_at_ms - 10_000) in checked_from_ms..checked_by_ms

    send(pid, :watchdog_tick)

    assert %{attempt: 1, error: "stalled for " <> _} = get_orchestrator_state(pid).retry_attempts[issue_id]
  end

  test "a workspace hook holds the first-turn stall check and the watchdog until its own deadline" do
    # A minute on both clocks, so a check that runs late still sees a hook that just ended as recent.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      agent_stall_timeout_ms: 60_000,
      watchdog: %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 60_000}
    )

    issue_id = "issue-hook-stall"
    orchestrator_name = Module.concat(__MODULE__, :HookStallOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    dispatched_at = DateTime.add(DateTime.utc_now(), -120, :second)
    initial_state = get_orchestrator_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: worker_ref,
      repo_key: Config.repo_key!(),
      run_id: "run-hook-stall",
      identifier: "MT-HOOK-STALL",
      issue: %Issue{id: issue_id, identifier: "MT-HOOK-STALL", state: "In Progress"},
      session_id: nil,
      agent_module: StopSessionAgent,
      agent_session: %{recipient: self()},
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      last_event_at: dispatched_at,
      started_at: dispatched_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    reconcile = fn ->
      run_stall_check(pid)
      send(pid, :watchdog_tick)
      get_orchestrator_state(pid)
    end

    # A slow after_create that started well past both clocks ago, with time left on its own timeout.
    hook = %{name: "after_create", deadline: DateTime.add(DateTime.utc_now(), 60, :second)}
    send(pid, {:worker_runtime_info, issue_id, %{workspace_hook: hook}})

    :sys.replace_state(pid, fn state ->
      update_in(state.running[issue_id], &Map.put(&1, :last_event_at, dispatched_at))
    end)

    assert %{workspace_hook: ^hook} = reconcile.().running[issue_id]
    assert Process.alive?(worker_pid)

    # Once it ends, both clocks start over from its end.
    send(pid, {:worker_runtime_info, issue_id, %{workspace_hook: nil}})

    assert %{workspace_hook: nil} = reconcile.().running[issue_id]
    assert Process.alive?(worker_pid)

    # A hook still running well past its own deadline is a stall.
    overdue_hook = %{name: "after_create", deadline: DateTime.add(DateTime.utc_now(), -120, :second)}
    send(pid, {:worker_runtime_info, issue_id, %{workspace_hook: overdue_hook}})
    state = run_stall_check(pid)

    refute Map.has_key?(state.running, issue_id)
    refute Process.alive?(worker_pid)
    assert %{attempt: 1, error: "stalled for " <> _} = state.retry_attempts[issue_id]
  end

  test "the watchdog alone waits out a workspace hook's deadline, whatever the last transcript event" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      agent_stall_timeout_ms: 0,
      watchdog: %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 1_000}
    )

    issue = %Issue{
      id: "issue-watchdog-hook",
      identifier: "MT-WATCHDOG-HOOK",
      title: "Watchdog during a hook",
      description: "Keep a worker running while its hook runs",
      state: "In Progress"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :WatchdogHookOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    old_event_at = DateTime.add(DateTime.utc_now(), -5, :second)

    running_entry =
      running_entry(issue, worker_pid, worker_ref, "run-watchdog-hook", old_event_at, %{
        last_codex_timestamp: old_event_at,
        last_codex_event: :notification,
        last_event_at: old_event_at,
        workspace_hook: %{name: "before_run", deadline: DateTime.add(DateTime.utc_now(), 60, :second)}
      })

    put_running_entry(pid, issue, running_entry)

    send(pid, :watchdog_tick)

    assert Map.has_key?(get_orchestrator_state(pid).running, issue.id)
    assert Process.alive?(worker_pid)

    Process.demonitor(worker_ref, [:flush])
    Process.exit(worker_pid, :shutdown)
  end

  @stall_check_only [agent_stall_timeout_ms: 1_000, watchdog: %{enabled: false}]

  describe "the stall check and the no-progress watchdog" do
    test "do not restart as stalled a run whose workpad bootstrap waits on Linear past the stall timeout" do
      pid = start_linear_wait_orchestrator!(:LinearWaitStallOrchestrator, @stall_check_only)
      issue = linear_wait_issue("issue-linear-wait-bootstrap")
      {worker_pid, worker_ref} = start_blocked_worker()
      stale_at = DateTime.add(DateTime.utc_now(), -5, :second)

      # No agent event yet: the workpad bootstrap is waiting on a rate-limited Linear call.
      put_running_entry(pid, issue, linear_wait_running_entry(issue, worker_pid, worker_ref, stale_at))
      wait_sent_at = DateTime.utc_now()
      send(pid, {:linear_wait, issue.id, 60_000})
      send(pid, {:linear_wait, "issue-not-running", 60_000})
      state = run_stall_check(pid)

      assert %{linear_wait_until: %DateTime{} = wait_until} = state.running[issue.id]
      assert DateTime.diff(wait_until, wait_sent_at, :millisecond) >= 60_000
      refute Map.has_key?(state.running, "issue-not-running")
      refute Map.has_key?(state.retry_attempts, issue.id)
      assert Process.alive?(worker_pid)
      assert %{running: [%{linear_wait_until: ^wait_until}]} = GenServer.call(pid, :snapshot)

      # The stall check stays on for the rest of the run: once the wait ends, the clock runs from there.
      end_linear_wait(pid, issue)
      run_stall_check(pid)

      assert_receive :agent_stop_session_called
      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}
      assert %{error: "stalled for " <> _} = wait_for_retry!(pid, issue)
    end

    test "do not restart as stuck a run waiting on Linear between turns past the no-progress threshold" do
      pid =
        start_linear_wait_orchestrator!(:LinearWaitWatchdogOrchestrator,
          agent_stall_timeout_ms: 1_000,
          watchdog: %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 1_000}
        )

      issue = linear_wait_issue("issue-linear-wait-between-turns")
      {worker_pid, worker_ref} = start_blocked_worker()
      stale_at = DateTime.add(DateTime.utc_now(), -5, :second)

      # The last turn ended long ago; the post-turn refresh is waiting on Linear.
      running_entry =
        linear_wait_running_entry(issue, worker_pid, worker_ref, stale_at, %{
          last_codex_timestamp: stale_at,
          last_codex_event: :turn_completed,
          turn_count: 1
        })

      put_running_entry(pid, issue, running_entry)
      send(pid, {:linear_wait, issue.id, 60_000})
      send(pid, :watchdog_tick)
      state = run_stall_check(pid)

      assert %{linear_wait_until: %DateTime{}} = state.running[issue.id]
      refute Map.has_key?(state.retry_attempts, issue.id)
      assert Process.alive?(worker_pid)

      end_linear_wait(pid, issue)
      send(pid, :watchdog_tick)

      # The retry is scheduled after the restart stops the session and the worker.
      assert %{error: "stuck for " <> _} = wait_for_retry!(pid, issue)
      assert_receive :agent_stop_session_called
      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}
    end

    test "still restart a run with no agent event and no Linear wait" do
      pid = start_linear_wait_orchestrator!(:LinearNoWaitStallOrchestrator, @stall_check_only)
      issue = linear_wait_issue("issue-no-linear-wait-stall")
      {worker_pid, worker_ref} = start_blocked_worker()
      put_running_entry(pid, issue, linear_wait_running_entry(issue, worker_pid, worker_ref, DateTime.add(DateTime.utc_now(), -5, :second)))
      assert %{running: [%{linear_wait_until: nil}]} = GenServer.call(pid, :snapshot)

      run_stall_check(pid)

      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}
      assert %{error: "stalled for " <> _} = wait_for_retry!(pid, issue)

      pid =
        start_linear_wait_orchestrator!(:LinearNoWaitWatchdogOrchestrator,
          agent_stall_timeout_ms: 0,
          watchdog: %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 1_000}
        )

      issue = linear_wait_issue("issue-no-linear-wait-stuck")
      {worker_pid, worker_ref} = start_blocked_worker()
      put_running_entry(pid, issue, linear_wait_running_entry(issue, worker_pid, worker_ref, DateTime.add(DateTime.utc_now(), -5, :second)))

      send(pid, :watchdog_tick)

      assert %{error: "stuck for " <> _} = wait_for_retry!(pid, issue)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}
    end
  end

  @watchdog_only [
    agent_stall_timeout_ms: 0,
    watchdog: %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 1_000}
  ]

  describe "a run waiting on one of Symphony's own tool calls" do
    test "shows the call past a minute and holds the no-progress watchdog until the call's deadline" do
      pid = start_linear_wait_orchestrator!(:ToolCallWatchdogOrchestrator, @watchdog_only)
      issue = linear_wait_issue("issue-tool-call-pending")
      {worker_pid, worker_ref} = start_blocked_worker()
      stale_at = DateTime.add(DateTime.utc_now(), -5, :second)
      attrs = %{last_codex_timestamp: stale_at}
      running_entry = linear_wait_running_entry(issue, worker_pid, worker_ref, stale_at, attrs)
      put_running_entry(pid, issue, running_entry)

      # The agent called `github_sync_base` two minutes ago; its fetch is still running.
      started_at = DateTime.add(DateTime.utc_now(), -120, :second)
      call = %{name: "github_sync_base", started_at: started_at, deadline: DateTime.add(DateTime.utc_now(), 60, :second)}
      send(pid, {:mcp_tool_call, issue.id, {:started, :sync_call, call}})
      send(pid, {:mcp_tool_call, "issue-not-running", {:started, :other_call, call}})
      send(pid, :watchdog_tick)
      state = get_orchestrator_state(pid)

      refute Map.has_key?(state.running, "issue-not-running")
      refute Map.has_key?(state.retry_attempts, issue.id)
      assert Process.alive?(worker_pid)

      assert %{running: [%{pending_tool: %{name: "github_sync_base", started_at: ^started_at, age_ms: age_ms}}]} =
               GenServer.call(pid, :snapshot)

      assert age_ms >= 120_000

      # A call younger than a minute is not shown yet; the call that ended is no longer shown.
      send(pid, {:mcp_tool_call, issue.id, {:started, :list_call, %{call | name: "linear_get_comments", started_at: DateTime.utc_now()}}})
      send(pid, {:mcp_tool_call, issue.id, {:finished, :sync_call}})
      assert %{running: [%{pending_tool: nil}]} = GenServer.call(pid, :snapshot)
      send(pid, {:mcp_tool_call, issue.id, {:finished, :list_call}})

      # The call's end counts as activity.
      assert %{pending_tool_calls: calls, last_event_at: last_event_at} = get_orchestrator_state(pid).running[issue.id]
      assert calls == %{}
      assert DateTime.after?(last_event_at, stale_at)
      assert %{running: [%{pending_tool: nil}]} = GenServer.call(pid, :snapshot)

      Process.demonitor(worker_ref, [:flush])
      Process.exit(worker_pid, :shutdown)
    end

    test "shows the call only past watchdog.pending_tool_report_after_ms" do
      watchdog = Map.put(@watchdog_only[:watchdog], :pending_tool_report_after_ms, 300_000)
      pid = start_linear_wait_orchestrator!(:ToolCallReportAfterOrchestrator, Keyword.put(@watchdog_only, :watchdog, watchdog))

      issue = linear_wait_issue("issue-tool-call-report-after")
      {worker_pid, worker_ref} = start_blocked_worker()
      put_running_entry(pid, issue, linear_wait_running_entry(issue, worker_pid, worker_ref, DateTime.utc_now()))

      # Two minutes is past the default minute but short of the configured five.
      deadline = DateTime.add(DateTime.utc_now(), 600, :second)
      two_minutes_ago = DateTime.add(DateTime.utc_now(), -120, :second)
      young_call = %{name: "linear_get_comments", started_at: two_minutes_ago, deadline: deadline}
      send(pid, {:mcp_tool_call, issue.id, {:started, :young_call, young_call}})
      assert %{running: [%{pending_tool: nil}]} = GenServer.call(pid, :snapshot)

      six_minutes_ago = DateTime.add(DateTime.utc_now(), -360, :second)
      old_call = %{name: "github_sync_base", started_at: six_minutes_ago, deadline: deadline}
      send(pid, {:mcp_tool_call, issue.id, {:started, :old_call, old_call}})

      assert %{running: [%{pending_tool: %{name: "github_sync_base", age_ms: age_ms}}]} = GenServer.call(pid, :snapshot)
      assert age_ms >= 360_000

      Process.demonitor(worker_ref, [:flush])
      Process.exit(worker_pid, :shutdown)
    end

    test "names the pending call when the watchdog restarts a run past the call's deadline" do
      pid = start_linear_wait_orchestrator!(:ToolCallStuckOrchestrator, @watchdog_only)
      issue = linear_wait_issue("issue-tool-call-stuck")
      {worker_pid, worker_ref} = start_blocked_worker()
      now = DateTime.utc_now()
      stale_at = DateTime.add(now, -15, :second)
      attrs = %{last_codex_timestamp: stale_at}
      running_entry = linear_wait_running_entry(issue, worker_pid, worker_ref, stale_at, attrs)
      put_running_entry(pid, issue, running_entry)

      # The call's deadline passed five seconds ago, and a QA tool call (no deadline) holds nothing.
      sync_call = %{name: "github_sync_base", started_at: DateTime.add(now, -605, :second), deadline: DateTime.add(now, -5, :second)}
      qa_call = %{name: "qa_build", started_at: DateTime.add(now, -10, :second), deadline: nil}
      send(pid, {:mcp_tool_call, issue.id, {:started, :sync_call, sync_call}})
      send(pid, {:mcp_tool_call, issue.id, {:started, :qa_call, qa_call}})

      log =
        capture_log(fn ->
          send(pid, :watchdog_tick)
          assert %{error: "stuck for " <> _} = wait_for_retry!(pid, issue)
        end)

      assert log =~ "Agent run stuck: issue_id=issue-tool-call-stuck"
      assert log =~ ~r/elapsed_ms=\d+ pending_tool=github_sync_base pending_tool_age_ms=\d+; restarting with backoff/
      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}
    end
  end

  defp start_linear_wait_orchestrator!(name, workflow_overrides) do
    workflow = [tracker_kind: "memory", tracker_api_token: nil] ++ workflow_overrides
    write_workflow_file!(Workflow.workflow_file_path(), workflow)
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, name))

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    pid
  end

  defp linear_wait_issue(issue_id) do
    issue = %Issue{id: issue_id, identifier: "MT-LINEAR-WAIT", title: "Linear wait", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    issue
  end

  defp linear_wait_running_entry(issue, worker_pid, worker_ref, stale_at, attrs \\ %{}) do
    running_entry(
      issue,
      worker_pid,
      worker_ref,
      "run-" <> issue.id,
      stale_at,
      Map.merge(%{last_event_at: stale_at, agent_module: StopSessionAgent, agent_session: %{recipient: self()}}, attrs)
    )
  end

  # The wait ended two seconds ago, after the run's last activity but past the 1s thresholds.
  defp end_linear_wait(pid, issue) do
    :sys.replace_state(pid, fn state ->
      put_in(state.running[issue.id][:linear_wait_until], DateTime.add(DateTime.utc_now(), -2, :second))
    end)
  end

  defp wait_for_retry!(pid, issue) do
    wait_for_orchestrator_state(pid, &Map.has_key?(&1.retry_attempts, issue.id), 1_000).retry_attempts[issue.id]
  end

  test "status dashboard renders offline marker to terminal" do
    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = StatusDashboard.render_offline_status()
      end)

    assert rendered =~ "app_status=offline"
    refute rendered =~ "Timestamp:"
  end

  test "status dashboard renders repo scope in header" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = Renderer.format_snapshot_content(snapshot_data, 0.0)

    assert rendered =~ "│ Repos:"
    assert rendered =~ "default"
    refute rendered =~ "https://linear.app/project/project/issues"
    refute rendered =~ "Dashboard:"
  end

  test "status dashboard renders dashboard url on its own line when server port is configured" do
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:symphony_elixir, :server_port_override)
      else
        Application.put_env(:symphony_elixir, :server_port_override, previous_port_override)
      end
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 4000)

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = Renderer.format_snapshot_content(snapshot_data, 0.0)

    assert rendered =~ "│ Repos:"
    assert rendered =~ "default"
    assert rendered =~ "│ Dashboard:"
    assert rendered =~ "http://127.0.0.1:4000/"
  end

  test "status dashboard marks aged ETS snapshot data as stale and logs diagnostics once" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      observability_snapshot_publish_ms: 1_000
    )

    {:ok, orchestrator_pid} = Orchestrator.start_link()
    dashboard_name = Module.concat(__MODULE__, :StaleSnapshotDashboard)
    parent = self()

    :ets.insert(
      @snapshot_table,
      {:current,
       %{
         running: [],
         watching: [],
         conflicts: [],
         retrying: [],
         awaiting_clarification: [],
         skipped: [],
         codex_totals: %{
           input_tokens: 120,
           cached_input_tokens: 100,
           output_tokens: 30,
           total_tokens: 150,
           seconds_running: 9
         },
         rate_limits: nil,
         polling: %{next_poll_in_ms: 5_000}
       }, System.monotonic_time(:millisecond) - 5_000, System.system_time(:millisecond) - 5_000}
    )

    {:ok, dashboard_pid} =
      StatusDashboard.start_link(
        name: dashboard_name,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 1,
        render_fun: fn content -> send(parent, {:stale_dashboard_render, content}) end
      )

    on_exit(fn ->
      if Process.alive?(orchestrator_pid) do
        stop_process(orchestrator_pid)
      end

      if Process.alive?(dashboard_pid) do
        stop_process(dashboard_pid)
      end
    end)

    log =
      capture_log(fn ->
        StatusDashboard.notify_update(dashboard_name)

        assert_receive {:stale_dashboard_render, rendered}, 500

        plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

        assert plain =~ "Snapshot: stale 0m 5s (1 missed refresh, orchestrator mailbox "
        assert plain =~ "No active agents"
        assert plain =~ "Tokens: new 20 | cached 100 | created 0 | out 30"
        refute plain =~ "Orchestrator snapshot unavailable"

        StatusDashboard.notify_update(dashboard_name)

        # `symphony dashboard` gets the same view through the control API.
        assert {:ok, frame} = StatusDashboard.frame(140, dashboard_name)
        assert Regex.replace(~r/\e\[[0-9;]*m/, frame, "") =~ "Tokens: new 20 | cached 100 | created 0 | out 30"
      end)

    assert StatusDashboard.frame(140, Module.concat(__MODULE__, :NoSuchDashboard)) == :unavailable
    assert log =~ "snapshot stale"
    assert length(String.split(log, "snapshot stale")) == 2
  end

  test "status dashboard frame keeps the forced tickets from the live snapshot" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", forced_max: 1)

    {:ok, orchestrator_pid} = Orchestrator.start_link()
    dashboard_name = Module.concat(__MODULE__, :ForcedSnapshotDashboard)

    :ets.insert(
      @snapshot_table,
      {:current,
       %{
         running: [],
         watching: [],
         retrying: [],
         forced: [
           %{
             issue_id: "issue-forced",
             identifier: "MT-902",
             title: "Forced",
             state: "Todo",
             position: 1,
             phase: :implementation,
             running: false,
             waiting_on: :blocker,
             blockers: ["MT-901"],
             forced_for_seconds: 300,
             stale: false,
             sub_issue: nil
           }
         ],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{next_poll_in_ms: 5_000}
       }, System.monotonic_time(:millisecond), System.system_time(:millisecond)}
    )

    {:ok, dashboard_pid} =
      StatusDashboard.start_link(name: dashboard_name, enabled: false, refresh_ms: 60_000, render_interval_ms: 1)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: stop_process(orchestrator_pid)
      if Process.alive?(dashboard_pid), do: stop_process(dashboard_pid)
    end)

    assert {:ok, frame} = StatusDashboard.frame(140, dashboard_name)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, frame, "")

    assert plain =~ "forced 1/1"
    assert plain =~ "├─ Forced"
    assert plain =~ ~r/MT-902\s+implementation\s+blocker MT-901/
  end

  test "status dashboard renders startup pending before the first snapshot grace expires" do
    dashboard_name = Module.concat(__MODULE__, :StartupPendingDashboard)
    parent = self()

    {:ok, dashboard_pid} =
      StatusDashboard.start_link(
        name: dashboard_name,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 1,
        render_fun: fn content -> send(parent, {:startup_pending_dashboard_render, content}) end
      )

    on_exit(fn ->
      if Process.alive?(dashboard_pid) do
        stop_process(dashboard_pid)
      end
    end)

    StatusDashboard.notify_update(dashboard_name)

    assert_receive {:startup_pending_dashboard_render, rendered}, 500

    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ "Snapshot: starting (waiting for orchestrator)"
    assert plain =~ "Throughput: 0 tps"
    assert plain =~ "Next refresh: n/a"
    refute plain =~ "Orchestrator snapshot unavailable"
  end

  test "status dashboard renders unavailable after the first snapshot grace expires" do
    dashboard_name = Module.concat(__MODULE__, :StartupUnavailableDashboard)
    parent = self()

    {:ok, dashboard_pid} =
      StatusDashboard.start_link(
        name: dashboard_name,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 1,
        render_fun: fn content -> send(parent, {:startup_unavailable_dashboard_render, content}) end
      )

    on_exit(fn ->
      if Process.alive?(dashboard_pid) do
        stop_process(dashboard_pid)
      end
    end)

    :sys.replace_state(dashboard_pid, fn state ->
      %{state | started_at_ms: System.monotonic_time(:millisecond) - 60_000}
    end)

    StatusDashboard.notify_update(dashboard_name)

    assert_receive {:startup_unavailable_dashboard_render, rendered}, 500

    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ "Orchestrator snapshot unavailable"
    refute plain =~ "Snapshot: starting"
  end

  test "status dashboard still renders unavailable when no successful snapshot exists" do
    rendered = Renderer.format_snapshot_content(:error, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ "Orchestrator snapshot unavailable"
    refute plain =~ "Snapshot: stale"
  end

  test "status dashboard forwards quality gate sections from orchestrator snapshot" do
    orchestrator_pid = ensure_orchestrator_running()
    assert is_pid(orchestrator_pid)

    previous_state = :sys.get_state(orchestrator_pid)

    on_exit(fn ->
      if pid = Process.whereis(Orchestrator) do
        # An unsupervised orchestrator is linked to the test process and can
        # exit after the whereis; then there is no state left to restore.
        try do
          :sys.replace_state(pid, fn state ->
            %{
              state
              | quality_gate_cache: previous_state.quality_gate_cache,
                quality_gate_comment_keys: previous_state.quality_gate_comment_keys,
                quality_gate_skipped_errors: previous_state.quality_gate_skipped_errors
            }
          end)

          send(pid, :publish_snapshot)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    :sys.replace_state(orchestrator_pid, fn state ->
      %{
        state
        | quality_gate_cache: %{
            "issue-skip-terminal" => %{
              updated_at: ~U[2026-05-05 03:00:00Z],
              comment_signature: nil,
              score: 3,
              reason: "too vague for dispatch",
              passed?: false,
              awaiting_clarification?: false,
              questions: [],
              rounds_asked: 0,
              max_rounds: nil,
              pass_threshold: nil,
              max_rounds_reached?: false,
              comment_posted?: true,
              identifier: "MT-SKIP-TERMINAL",
              title: "Skip terminal",
              state: "Todo",
              url: "https://example.org/issues/MT-SKIP-TERMINAL",
              scored_at: ~U[2026-05-05 03:00:00Z]
            },
            "issue-await-terminal" => %{
              updated_at: ~U[2026-05-05 03:10:00Z],
              comment_signature: nil,
              score: 5,
              reason: "needs acceptance criteria",
              passed?: false,
              awaiting_clarification?: true,
              questions: ["What should the agent verify?"],
              rounds_asked: 1,
              max_rounds: 2,
              pass_threshold: 6,
              max_rounds_reached?: false,
              comment_posted?: true,
              identifier: "MT-AWAIT-TERMINAL",
              title: "Await terminal",
              state: "Todo",
              url: "https://example.org/issues/MT-AWAIT-TERMINAL",
              scored_at: ~U[2026-05-05 03:10:00Z]
            }
          },
          quality_gate_comment_keys: MapSet.new(),
          quality_gate_skipped_errors: %{}
      }
    end)

    send(orchestrator_pid, :publish_snapshot)

    wait_for_snapshot_cache(
      orchestrator_pid,
      fn entry ->
        entry.snapshot.awaiting_clarification
        |> Enum.any?(&(&1.identifier == "MT-AWAIT-TERMINAL"))
      end,
      500
    )

    dashboard_name = Module.concat(__MODULE__, :QualityGateDashboard)
    parent = self()

    {:ok, dashboard_pid} =
      StatusDashboard.start_link(
        name: dashboard_name,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 1,
        render_fun: fn content -> send(parent, {:quality_gate_dashboard_render, content}) end
      )

    on_exit(fn ->
      if Process.alive?(dashboard_pid) do
        stop_process(dashboard_pid)
      end
    end)

    StatusDashboard.notify_update(dashboard_name)

    assert_receive {:quality_gate_dashboard_render, rendered}, 500

    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ "MT-AWAIT-TERMINAL"
    assert plain =~ "round=1"
    assert plain =~ "MT-SKIP-TERMINAL"
    assert plain =~ "score=3"
    assert plain =~ "too vague for dispatch"
  end

  test "orchestrator snapshot hides quality gate sections for running issues" do
    orchestrator_pid = ensure_orchestrator_running()
    assert is_pid(orchestrator_pid)

    previous_state = :sys.get_state(orchestrator_pid)

    on_exit(fn ->
      case Process.whereis(Orchestrator) do
        pid when is_pid(pid) ->
          restore_quality_gate_test_state(pid, previous_state)

        nil ->
          :ok
      end
    end)

    running_issue = %Issue{
      id: "issue-running",
      identifier: "MT-RUNNING",
      title: "Running issue",
      state: "Todo",
      url: "https://example.org/issues/MT-RUNNING",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    waiting_issue = %Issue{
      id: "issue-waiting",
      identifier: "MT-WAITING",
      title: "Waiting issue",
      state: "Todo",
      url: "https://example.org/issues/MT-WAITING",
      updated_at: ~U[2026-05-05 03:10:00Z]
    }

    :sys.replace_state(orchestrator_pid, fn state ->
      %{
        state
        | running: %{
            running_issue.id => %{
              identifier: running_issue.identifier,
              issue: running_issue,
              started_at: ~U[2026-05-05 03:30:00Z],
              last_codex_timestamp: nil,
              last_codex_message: nil,
              last_codex_event: nil
            }
          },
          quality_gate_cache: %{
            running_issue.id => %{
              updated_at: running_issue.updated_at,
              comment_signature: nil,
              score: 5,
              reason: "stale awaiting entry",
              passed?: false,
              awaiting_clarification?: true,
              questions: ["Question?"],
              rounds_asked: 1,
              max_rounds: 2,
              pass_threshold: 6,
              comment_posted?: true,
              identifier: running_issue.identifier,
              title: running_issue.title,
              state: running_issue.state,
              url: running_issue.url,
              scored_at: ~U[2026-05-05 03:00:00Z]
            },
            waiting_issue.id => %{
              updated_at: waiting_issue.updated_at,
              comment_signature: nil,
              score: 5,
              reason: "still awaiting",
              passed?: false,
              awaiting_clarification?: true,
              questions: ["Question?"],
              rounds_asked: 1,
              max_rounds: 2,
              pass_threshold: 6,
              comment_posted?: true,
              identifier: waiting_issue.identifier,
              title: waiting_issue.title,
              state: waiting_issue.state,
              url: waiting_issue.url,
              scored_at: ~U[2026-05-05 03:10:00Z]
            }
          },
          quality_gate_skipped_errors: %{
            running_issue.id => %{
              kind: :error,
              issue_id: running_issue.id,
              identifier: running_issue.identifier,
              url: running_issue.url,
              updated_at: running_issue.updated_at,
              reason: "stale error entry",
              error: :stub_boom
            }
          }
      }
    end)

    snapshot = GenServer.call(orchestrator_pid, :snapshot)

    assert Enum.any?(snapshot.running, &match?(%{issue_id: "issue-running"}, &1))
    assert Enum.any?(snapshot.awaiting_clarification, &match?(%{issue_id: "issue-waiting"}, &1))
    refute Enum.any?(snapshot.awaiting_clarification, &match?(%{issue_id: "issue-running"}, &1))
    refute Enum.any?(snapshot.skipped, &match?(%{issue_id: "issue-running"}, &1))
  end

  test "status dashboard renders next refresh countdown and checking marker" do
    waiting_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: false, next_poll_in_ms: 2_000, poll_interval_ms: 30_000}
       }}

    waiting_rendered = Renderer.format_snapshot_content(waiting_snapshot, 0.0)
    assert waiting_rendered =~ "Next refresh:"
    assert waiting_rendered =~ "2s"

    checking_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: true, next_poll_in_ms: nil, poll_interval_ms: 30_000}
       }}

    checking_rendered = Renderer.format_snapshot_content(checking_snapshot, 0.0)
    assert checking_rendered =~ "checking now…"
  end

  test "status dashboard adds spacer lines between empty running, watching, and backoff sections" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = Renderer.format_snapshot_content(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/No active agents\r?\n│\s*\r?\n├─ Watching/
    assert plain =~ ~r/No watched issues\r?\n│\s*\r?\n├─ Backoff queue/
  end

  test "status dashboard shows watching PR and Linear links when available" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         watching: [
           %{
             issue_id: "issue-watch-pr",
             identifier: "MT-PR",
             state: "In Review",
             seconds_since_last_run: 60,
             url: "https://linear.app/example/issue/MT-PR",
             pull_request_url: "https://github.com/example/repo/pull/42"
           }
         ],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = Renderer.format_snapshot_content(snapshot_data, 0.0, 180)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ "PR / LINEAR URL"
    assert plain =~ "https://github.com/example/repo/pull/42"
    assert plain =~ "https://linear.app/example/issue/MT-PR"
  end

  test "status dashboard adds a spacer line before backoff queue when agents are active" do
    snapshot_data =
      {:ok,
       %{
         running: [
           %{
             identifier: "MT-777",
             state: "running",
             session_id: "thread-1234567890",
             codex_app_server_pid: "4242",
             codex_total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_codex_event: "turn_completed",
             last_codex_message: %{
               event: :notification,
               message: %{
                 "method" => "turn/completed",
                 "params" => %{"turn" => %{"status" => "completed"}}
               }
             }
           }
         ],
         retrying: [],
         codex_totals: %{
           input_tokens: 90,
           output_tokens: 12,
           total_tokens: 102,
           seconds_running: 75
         },
         rate_limits: nil
       }}

    rendered = Renderer.format_snapshot_content(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/MT-777.*\r?\n│\s*\r?\n├─ Backoff queue/s
  end

  test "status dashboard renders an unstyled closing corner when the retry queue is empty" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = Renderer.format_snapshot_content(snapshot_data, 0.0)

    assert rendered |> String.split("\n") |> List.last() == "╰─"
  end

  test "status dashboard coalesces rapid updates to one render per interval" do
    dashboard_name = Module.concat(__MODULE__, :RenderDashboard)
    parent = self()
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :not_found} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    {:ok, pid} =
      StatusDashboard.start_link(
        name: dashboard_name,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 16,
        render_fun: fn content ->
          send(parent, {:render, System.monotonic_time(:millisecond), content})
        end
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    StatusDashboard.notify_update(dashboard_name)
    assert_receive {:render, first_render_ms, _content}, 200

    :sys.replace_state(pid, fn state ->
      %{state | last_snapshot_fingerprint: :force_next_change, last_rendered_content: nil}
    end)

    StatusDashboard.notify_update(dashboard_name)
    StatusDashboard.notify_update(dashboard_name)

    assert_receive {:render, second_render_ms, _content}, 200
    assert second_render_ms > first_render_ms
    refute_receive {:render, _third_render_ms, _content}, 60
  end

  test "status dashboard computes rolling 5-second token throughput" do
    assert Renderer.rolling_tps([], 10_000, 0) == 0.0

    assert Renderer.rolling_tps([{9_000, 20}], 10_000, 40) == 20.0

    # sample older than 5s is dropped from the window
    assert Renderer.rolling_tps([{4_900, 10}], 10_000, 90) == 0.0

    tps =
      Renderer.rolling_tps(
        [{9_500, 10}, {9_000, 40}, {8_000, 80}],
        10_000,
        95
      )

    assert tps == 7.5
  end

  test "status dashboard throttles tps updates to once per second" do
    {first_second, first_tps} =
      Renderer.throttled_tps(nil, nil, 10_000, [{9_000, 20}], 40)

    {same_second, same_tps} =
      Renderer.throttled_tps(first_second, first_tps, 10_500, [{9_000, 20}], 200)

    assert same_second == first_second
    assert same_tps == first_tps

    {next_second, next_tps} =
      Renderer.throttled_tps(same_second, same_tps, 11_000, [{10_500, 200}], 260)

    assert next_second == 11
    refute next_tps == same_tps
  end

  test "status dashboard formats timestamps at second precision" do
    dt = ~U[2026-02-15 21:36:38.987654Z]
    assert Renderer.format_timestamp(dt) == "2026-02-15 21:36:38Z"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for steady throughput" do
    now_ms = 600_000
    current_tokens = 6_000

    samples =
      for timestamp <- 575_000..0//-25_000 do
        {timestamp, div(timestamp, 100)}
      end

    assert Renderer.tps_graph(samples, now_ms, current_tokens) ==
             "████████████████████████"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for ramping throughput" do
    now_ms = 600_000

    rates_per_bucket =
      1..24
      |> Enum.map(&(&1 * 2))

    {current_tokens, samples} = graph_samples_from_rates(rates_per_bucket)

    assert Renderer.tps_graph(samples, now_ms, current_tokens) ==
             "▁▂▂▂▃▃▃▃▄▄▄▅▅▅▆▆▆▆▇▇▇██▅"
  end

  test "status dashboard keeps historical TPS bars stable within the active bucket" do
    now_ms = 600_000
    current_tokens = 74_400
    next_current_tokens = current_tokens + 120
    samples = graph_samples_for_stability_test(now_ms)

    graph_at_now = Renderer.tps_graph(samples, now_ms, current_tokens)

    graph_next_second =
      Renderer.tps_graph(samples, now_ms + 1_000, next_current_tokens)

    historical_changes =
      graph_at_now
      |> String.graphemes()
      |> Enum.zip(String.graphemes(graph_next_second))
      |> Enum.take(23)
      |> Enum.count(fn {left, right} -> left != right end)

    assert historical_changes == 0
  end

  test "application configures a rotating file logger handler" do
    assert {:ok, handler_config} = :logger.get_handler_config(:symphony_disk_log)
    assert handler_config.module == :logger_disk_log_h

    disk_config = handler_config.config
    assert disk_config.type == :wrap
    assert is_list(disk_config.file)
    assert disk_config.max_no_bytes > 0
    assert disk_config.max_no_files > 0
  end

  test "status dashboard renders last codex message in EVENT column" do
    row =
      Renderer.format_running_summary(
        %{
          identifier: "MT-233",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 12,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              "method" => "turn/completed",
              "params" => %{"turn" => %{"status" => "completed"}}
            }
          }
        },
        Renderer.running_event_width(nil)
      )

    plain = Regex.replace(~r/\e\[[\\d;]*m/, row, "")

    assert plain =~ "turn completed (completed)"
    assert (String.split(plain, "turn completed (completed)") |> length()) - 1 == 1
    refute plain =~ " notification "
  end

  test "status dashboard strips ANSI and control bytes from last codex message" do
    payload =
      "cmd: " <>
        <<27>> <>
        "[31mRED" <>
        <<27>> <>
        "[0m" <>
        <<0>> <>
        " after\nline"

    row =
      Renderer.format_running_summary(
        %{
          identifier: "MT-898",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 12,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: payload
        },
        Renderer.running_event_width(nil)
      )

    plain = Regex.replace(~r/\e\[[0-9;]*m/, row, "")

    assert plain =~ "cmd: RED after line"
    refute plain =~ <<27>>
    refute plain =~ <<0>>
  end

  test "status dashboard shows a run waiting on Linear in place of its last message" do
    row =
      Renderer.format_running_summary(
        %{
          identifier: "MT-899",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 12,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: "older agent message",
          linear_wait_until: DateTime.add(DateTime.utc_now(), 30, :second)
        },
        Renderer.running_event_width(nil)
      )

    assert row =~ "waiting for Linear"
    refute row =~ "older agent message"
  end

  test "status dashboard shows a run waiting on a Symphony tool call in place of its last message" do
    row =
      Renderer.format_running_summary(
        %{
          identifier: "MT-899",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 12,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: "older agent message",
          pending_tool: %{name: "github_sync_base", started_at: DateTime.utc_now(), age_ms: 185_000}
        },
        Renderer.running_event_width(200)
      )

    assert row =~ "waiting on github_sync_base for 3m"
    refute row =~ "older agent message"
  end

  test "status dashboard expands running row to requested terminal width" do
    terminal_columns = 140

    row =
      Renderer.format_running_summary(
        %{
          identifier: "MT-598",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 123,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              "method" => "turn/completed",
              "params" => %{"turn" => %{"status" => "completed"}}
            }
          }
        },
        Renderer.running_event_width(terminal_columns)
      )

    plain = Regex.replace(~r/\e\[[\d;]*m/, row, "")

    assert String.length(plain) == terminal_columns
    assert plain =~ "turn completed (completed)"
  end

  test "status dashboard humanizes full codex app-server event set" do
    event_cases = [
      {"turn/started", %{"params" => %{"turn" => %{"id" => "turn-1"}}}, "turn started"},
      {"turn/completed", %{"params" => %{"turn" => %{"status" => "completed"}}}, "turn completed"},
      {"turn/diff/updated", %{"params" => %{"diff" => "line1\nline2"}}, "turn diff updated"},
      {"turn/plan/updated", %{"params" => %{"plan" => [%{"step" => "a"}, %{"step" => "b"}]}}, "plan updated"},
      {"thread/tokenUsage/updated",
       %{
         "params" => %{
           "usage" => %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11}
         }
       }, "thread token usage updated"},
      {"item/started",
       %{
         "params" => %{
           "item" => %{
             "id" => "item-1234567890abcdef",
             "type" => "commandExecution",
             "status" => "running"
           }
         }
       }, "item started: command execution"},
      {"item/completed", %{"params" => %{"item" => %{"type" => "fileChange", "status" => "completed"}}}, "item completed: file change"},
      {"item/agentMessage/delta", %{"params" => %{"delta" => "hello"}}, "agent message streaming"},
      {"item/plan/delta", %{"params" => %{"delta" => "step"}}, "plan streaming"},
      {"item/reasoning/summaryTextDelta", %{"params" => %{"summaryText" => "thinking"}}, "reasoning summary streaming"},
      {"item/reasoning/summaryPartAdded", %{"params" => %{"summaryText" => "section"}}, "reasoning summary section added"},
      {"item/reasoning/textDelta", %{"params" => %{"textDelta" => "reason"}}, "reasoning text streaming"},
      {"item/commandExecution/outputDelta", %{"params" => %{"outputDelta" => "ok"}}, "command output streaming"},
      {"item/fileChange/outputDelta", %{"params" => %{"outputDelta" => "changed"}}, "file change output streaming"},
      {"item/commandExecution/requestApproval", %{"params" => %{"parsedCmd" => "git status"}}, "command approval requested (git status)"},
      {"item/fileChange/requestApproval", %{"params" => %{"fileChangeCount" => 2}}, "file change approval requested (2 files)"},
      {"item/tool/call", %{"params" => %{"tool" => "linear_graphql"}}, "dynamic tool call requested (linear_graphql)"},
      {"item/tool/requestUserInput", %{"params" => %{"question" => "Continue?"}}, "tool requires user input: Continue?"}
    ]

    Enum.each(event_cases, fn {method, payload, expected_fragment} ->
      message = Map.put(payload, "method", method)

      humanized =
        MessageHumanizer.humanize(%{event: :notification, message: message})

      assert humanized =~ expected_fragment
    end)
  end

  test "status dashboard humanizes dynamic tool wrapper events" do
    completed = %{
      event: :tool_call_completed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"name" => "linear_graphql"}}
      }
    }

    failed = %{
      event: :tool_call_failed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "linear_graphql"}},
        result: %{
          "output" =>
            Jason.encode!(%{
              "error" => %{
                "body" => %{"errors" => [%{"message" => "Cannot query field \"links\" on type \"Issue\"."}]},
                "message" => "Linear GraphQL request failed with HTTP 400.",
                "status" => 400
              }
            }),
          "success" => false
        }
      }
    }

    unsupported = %{
      event: :unsupported_tool_call,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "unknown_tool"}}
      }
    }

    assert MessageHumanizer.humanize(completed) =~
             "dynamic tool call completed (linear_graphql)"

    assert MessageHumanizer.humanize(failed) =~
             "dynamic tool call failed (linear_graphql)"

    assert MessageHumanizer.humanize(failed) =~
             "Cannot query field"

    assert MessageHumanizer.humanize(unsupported) =~
             "unsupported dynamic tool call rejected (unknown_tool)"
  end

  test "status dashboard unwraps nested codex payload envelopes" do
    wrapped = %{
      event: :notification,
      message: %{
        payload: %{
          "method" => "turn/completed",
          "params" => %{
            "turn" => %{"status" => "completed"},
            "usage" => %{"input_tokens" => "10", "output_tokens" => 2, "total_tokens" => 12}
          }
        },
        raw: "{\"method\":\"turn/completed\"}"
      }
    }

    assert MessageHumanizer.humanize(wrapped) =~ "turn completed"
    assert MessageHumanizer.humanize(wrapped) =~ "new 10"
  end

  test "status dashboard formats legacy Claude input tokens as new tokens with cache buckets" do
    message = %{
      event: :notification,
      message: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{
              "input_tokens" => 800,
              "cache_read_input_tokens" => 9_200,
              "cache_creation_input_tokens" => 400,
              "output_tokens" => 600,
              "total_tokens" => 11_000
            }
          }
        }
      }
    }

    assert MessageHumanizer.humanize(message) ==
             "thread token usage updated (new 800, cached 9,200, created 400, out 600, total 11,000)"
  end

  test "status dashboard formats recovered malformed command completions" do
    message = %{
      event: :command_completed_recovered,
      message: %{
        payload: %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "commandExecution", "status" => "completed"}}
        },
        recovery: :malformed_command_completion
      }
    }

    assert MessageHumanizer.humanize(message) ==
             "command completed (recovered malformed Codex frame)"
  end

  test "status dashboard uses shell command line as exec command status text" do
    message = %{
      event: :notification,
      message: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => "git status --short"}}
      }
    }

    assert MessageHumanizer.humanize(message) == "git status --short"
  end

  test "status dashboard formats auto-approval updates from codex" do
    message = %{
      event: :approval_auto_approved,
      message: %{
        payload: %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{"parsedCmd" => "mix test"}
        },
        decision: "acceptForSession"
      }
    }

    humanized = MessageHumanizer.humanize(message)
    assert humanized =~ "command approval requested"
    assert humanized =~ "auto-approved"
  end

  test "status dashboard formats auto-answered tool input updates from codex" do
    message = %{
      event: :tool_input_auto_answered,
      message: %{
        payload: %{
          "method" => "item/tool/requestUserInput",
          "params" => %{"question" => "Continue?"}
        },
        answer: "This is a non-interactive session. Operator input is unavailable."
      }
    }

    humanized = MessageHumanizer.humanize(message)
    assert humanized =~ "tool requires user input"
    assert humanized =~ "auto-answered"
  end

  test "status dashboard enriches wrapper reasoning and message streaming events with payload context" do
    reasoning_message = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_reasoning",
        "params" => %{
          "msg" => %{
            "payload" => %{"summaryText" => "compare retry paths for Linear polling"}
          }
        }
      }
    }

    message_delta = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_message_delta",
        "params" => %{
          "msg" => %{
            "payload" => %{"delta" => "writing workpad reconciliation update"}
          }
        }
      }
    }

    fallback_reasoning = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_reasoning",
        "params" => %{"msg" => %{"payload" => %{}}}
      }
    }

    assert MessageHumanizer.humanize(reasoning_message) =~
             "reasoning update: compare retry paths for Linear polling"

    assert MessageHumanizer.humanize(message_delta) =~
             "agent message streaming: writing workpad reconciliation update"

    assert MessageHumanizer.humanize(fallback_reasoning) == "reasoning update"
  end

  test "application stop skips offline status in test runtime" do
    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = SymphonyElixir.Application.stop(:normal)
      end)

    assert rendered == ""
  end

  test "normal exit on a PR run does not track Linear watching metadata" do
    issue = %Issue{
      id: "pr:default:320",
      identifier: "PR-320",
      title: "Address review comments",
      state: "In Progress",
      run_kind: :pr,
      repo_key: "default",
      pull_request_url: "https://github.com/example/repo/pull/320",
      pr_urls: ["https://github.com/example/repo/pull/320"]
    }

    orchestrator_name = Module.concat(__MODULE__, :PrRunNormalExitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-pr-normal-exit"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        run_kind: :pr,
        pull_request_url: issue.pull_request_url,
        session_id: "thread-pr-normal"
      })

    put_running_run!(issue, run_id, started_at, %{session_id: "thread-pr-normal"})
    put_running_entry(pid, issue, running_entry)

    send(pid, {:DOWN, worker_ref, :process, worker_pid, :normal})

    completed_state = wait_for_orchestrator_state(pid, &(map_size(&1.running) == 0), 1_000)
    refute Map.has_key?(completed_state.retry_attempts, issue.id)
    refute Map.has_key?(completed_state.completed_run_metadata, issue.id)
    refute MapSet.member?(completed_state.completed, issue.id)

    send(worker_pid, :finish)
  end

  test "abnormal exit on a PR run does not schedule a Linear retry" do
    issue = %Issue{
      id: "pr:default:321",
      identifier: "PR-321",
      title: "Address review comments",
      state: "In Progress",
      run_kind: :pr,
      repo_key: "default",
      pull_request_url: "https://github.com/example/repo/pull/321",
      pr_urls: ["https://github.com/example/repo/pull/321"]
    }

    orchestrator_name = Module.concat(__MODULE__, :PrRunAbnormalExitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-pr-abnormal-exit"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        run_kind: :pr,
        pull_request_url: issue.pull_request_url,
        session_id: "thread-pr-abnormal"
      })

    put_running_run!(issue, run_id, started_at, %{session_id: "thread-pr-abnormal"})
    put_running_entry(pid, issue, running_entry)

    send(pid, {:DOWN, worker_ref, :process, worker_pid, :killed})

    wait_for_orchestrator_state(pid, &(map_size(&1.running) == 0), 1_000)

    completed_state = get_orchestrator_state(pid)
    refute Map.has_key?(completed_state.retry_attempts, issue.id)
    refute Map.has_key?(completed_state.completed_run_metadata, issue.id)
    refute MapSet.member?(completed_state.completed, issue.id)

    send(worker_pid, :finish)
  end

  test "review-agent blocked exit comments, moves to configured escalation state, and does not schedule retry" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      ci: %{escalation_state: "Needs Human"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "issue-review-agent-blocked",
      identifier: "MT-REVIEW-BLOCKED",
      title: "Review agent blocked",
      state: "In Progress"
    }

    orchestrator_name = Module.concat(__MODULE__, :ReviewAgentBlockedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-review-agent-blocked"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        session_id: "thread-review-agent-blocked"
      })

    put_running_run!(issue, run_id, started_at, %{session_id: "thread-review-agent-blocked"})
    put_running_entry(pid, issue, running_entry)

    reason =
      {:review_agent_blocked,
       %{
         reason: "Unsafe to continue.",
         findings: [
           %{
             summary: "Breaks the retry contract.",
             file: "lib/example.ex",
             line_range: {10, 12},
             suggested_fix: "Return a terminal review-agent block."
           }
         ],
         comments: ["Breaks the retry contract."]
       }}

    send(pid, {:DOWN, worker_ref, :process, worker_pid, reason})

    assert_receive {:memory_tracker_comment, "issue-review-agent-blocked", body}, 1_000
    assert body =~ "reviewer agent returned a verified blocking verdict"
    assert body =~ "Reason: Unsafe to continue."
    assert body =~ "Breaks the retry contract. (lib/example.ex:10-12)"
    assert body =~ "Target human-review state: Needs Human."

    assert_receive {:memory_tracker_state_update, "issue-review-agent-blocked", "Needs Human"}, 1_000

    completed_state = wait_for_orchestrator_state(pid, &(map_size(&1.running) == 0 and &1.tracker_tasks == %{}), 1_000)
    refute Map.has_key?(completed_state.retry_attempts, issue.id)
    refute MapSet.member?(completed_state.claimed, issue.id)
    assert %{state: "Needs Human"} = completed_state.watching[issue.id]

    send(worker_pid, :finish)
  end

  test "review-agent blocked exit releases claim when escalation state transition fails" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :state_not_found})

    issue = %Issue{
      id: "issue-review-agent-blocked-transition-fails",
      identifier: "MT-REVIEW-BLOCKED-TRANSITION-FAILS",
      title: "Review agent blocked transition fails",
      state: "In Progress"
    }

    orchestrator_name = Module.concat(__MODULE__, :ReviewAgentBlockedTransitionFailsOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-review-agent-blocked-transition-fails"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        session_id: "thread-review-agent-blocked-transition-fails"
      })

    put_running_run!(issue, run_id, started_at, %{session_id: "thread-review-agent-blocked-transition-fails"})
    put_running_entry(pid, issue, running_entry)

    send(
      pid,
      {:DOWN, worker_ref, :process, worker_pid, {:review_agent_blocked, %{reason: "Unsafe to continue.", findings: [%{summary: "Verified block."}]}}}
    )

    assert_receive {:memory_tracker_comment, "issue-review-agent-blocked-transition-fails", body}, 1_000
    assert body =~ "Target human-review state: In Review."

    completed_state = wait_for_orchestrator_state(pid, &(map_size(&1.running) == 0 and &1.tracker_tasks == %{}), 1_000)
    refute Map.has_key?(completed_state.retry_attempts, issue.id)
    refute MapSet.member?(completed_state.claimed, issue.id)

    send(worker_pid, :finish)
  end

  test "tool failure circuit breaker exit escalates without scheduling retry" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      ci: %{escalation_state: "Needs Human"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "issue-tool-failure-breaker",
      identifier: "MT-TOOL-BREAKER",
      title: "Repeated tool failure",
      state: "In Progress"
    }

    orchestrator_name = Module.concat(__MODULE__, :ToolFailureBreakerOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: stop_process(pid)
    end)

    {worker_pid, worker_ref} = start_blocked_worker()
    started_at = DateTime.utc_now()
    run_id = "run-tool-failure-breaker"

    running_entry =
      running_entry(issue, worker_pid, worker_ref, run_id, started_at, %{
        session_id: "thread-tool-failure-breaker"
      })

    put_running_run!(issue, run_id, started_at, %{session_id: "thread-tool-failure-breaker"})
    put_running_entry(pid, issue, running_entry)

    reason =
      {:tool_failure_circuit_breaker,
       %{
         signature: %{kind: :dynamic_tool, name: "github_get_pull_request", args_hash: "abc123"},
         count: 5,
         threshold: 5
       }}

    send(pid, {:DOWN, worker_ref, :process, worker_pid, reason})

    assert_receive {:memory_tracker_comment, "issue-tool-failure-breaker", body}, 1_000
    assert body =~ "same failing tool execution"
    assert body =~ "kind=dynamic_tool name=\"github_get_pull_request\" args_hash=abc123"
    assert body =~ "Consecutive failures: 5"
    assert body =~ "Configured threshold: 5"
    assert body =~ "Target human-review state: Needs Human."

    assert_receive {:memory_tracker_state_update, "issue-tool-failure-breaker", "Needs Human"}, 1_000

    completed_state = wait_for_orchestrator_state(pid, &(map_size(&1.running) == 0 and &1.tracker_tasks == %{}), 1_000)
    refute Map.has_key?(completed_state.retry_attempts, issue.id)
    refute MapSet.member?(completed_state.claimed, issue.id)
    assert %{state: "Needs Human"} = completed_state.watching[issue.id]

    send(worker_pid, :finish)
  end

  defp put_budget_exhausted_run(attrs) do
    total_tokens = Map.fetch!(attrs, :total_tokens)

    RunStore.put_run(%{
      repo_key: Config.repo_key!(),
      run_id: Map.fetch!(attrs, :run_id),
      issue_id: Map.fetch!(attrs, :issue_id),
      issue_identifier: Map.fetch!(attrs, :issue_identifier),
      title: "Budget exhausted",
      state: "Todo",
      status: "budget_exhausted",
      attempt: 1,
      started_at: Map.fetch!(attrs, :started_at),
      ended_at: DateTime.utc_now(),
      error: "token budget exhausted",
      tokens: %{input_tokens: total_tokens, output_tokens: 0, total_tokens: total_tokens}
    })
  end

  defp start_blocked_worker do
    pid =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    {pid, Process.monitor(pid)}
  end

  defp put_running_run!(%Issue{} = issue, run_id, started_at, attrs \\ %{}) do
    :ok =
      RunStore.put_run(
        Map.merge(
          %{
            run_id: run_id,
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            title: issue.title,
            state: issue.state,
            status: "running",
            repo_key: Config.repo_key!(),
            attempt: 1,
            started_at: started_at
          },
          attrs
        )
      )
  end

  defp running_entry(%Issue{} = issue, worker_pid, worker_ref, run_id, started_at, attrs \\ %{}) do
    Map.merge(
      %{
        pid: worker_pid,
        ref: worker_ref,
        run_id: run_id,
        identifier: issue.identifier,
        issue: issue,
        worker_host: nil,
        workspace_path: nil,
        session_id: nil,
        transcript_path: nil,
        transcript_buffer: :queue.new(),
        transcript_buffer_size: 0,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        turn_count: 0,
        retry_attempt: 0,
        repo_key: Config.repo_key!(),
        started_at: started_at
      },
      attrs
    )
  end

  defp put_running_entry(pid, %Issue{} = issue, running_entry) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{issue.id => running_entry},
          claimed: MapSet.put(state.claimed, issue.id)
      }
    end)
  end

  defp get_orchestrator_state(pid), do: :sys.get_state(pid, 15_000)

  # Runs one poll cycle's first-turn stall check and returns the state right after it.
  # `:tick` sends `:run_poll_cycle` only after a timer, and a cycle skips the check while
  # an earlier cycle's repo poll is in flight, so wait that out and send the message here.
  defp run_stall_check(pid) do
    wait_for_poll_cycle_idle(pid)
    send(pid, :run_poll_cycle)
    get_orchestrator_state(pid)
  end

  # Idle also means no dispatch readiness task: a cycle that reaches dispatch while one is in
  # flight defers its dispatch and skips the workspace age GC that task would run.
  defp wait_for_poll_cycle_idle(pid) do
    wait_for_orchestrator_state(
      pid,
      &(is_nil(&1.repo_poll_task_ref) and not &1.poll_check_in_progress and &1.dispatch_readiness_tasks == %{}),
      5_000
    )
  end

  defp wait_for_orchestrator_state(pid, predicate, timeout_ms) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + max(timeout_ms, @min_wait_ms)
    do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
  end

  defp restore_quality_gate_test_state(pid, previous_state) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: previous_state.running,
          quality_gate_cache: previous_state.quality_gate_cache,
          quality_gate_comment_keys: previous_state.quality_gate_comment_keys,
          quality_gate_skipped_errors: previous_state.quality_gate_skipped_errors
      }
    end)
  catch
    :exit, {:noproc, _reason} -> :ok
  end

  defp do_wait_for_orchestrator_state(pid, predicate, deadline_ms) do
    state = get_orchestrator_state(pid)

    if predicate.(state) do
      state
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator state: #{inspect(state)}")
      else
        Process.sleep(5)
        do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
      end
    end
  end

  defp wait_for_snapshot(pid, predicate, timeout_ms \\ 200) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + max(timeout_ms, @min_wait_ms)
    do_wait_for_snapshot(pid, predicate, deadline_ms)
  end

  defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if predicate.(snapshot) do
      snapshot
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator snapshot state: #{inspect(snapshot)}")
      else
        Process.sleep(5)
        do_wait_for_snapshot(pid, predicate, deadline_ms)
      end
    end
  end

  defp wait_for_snapshot_cache(pid, predicate, timeout_ms) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + max(timeout_ms, @min_wait_ms)
    do_wait_for_snapshot_cache(pid, predicate, deadline_ms)
  end

  defp do_wait_for_snapshot_cache(pid, predicate, deadline_ms) do
    case Orchestrator.snapshot_cache_entry(pid) do
      {:ok, entry} ->
        if predicate.(entry) do
          entry
        else
          retry_wait_for_snapshot_cache(pid, predicate, deadline_ms, entry)
        end

      :missing ->
        retry_wait_for_snapshot_cache(pid, predicate, deadline_ms, :missing)
    end
  end

  defp retry_wait_for_snapshot_cache(pid, predicate, deadline_ms, last_seen) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      flunk("timed out waiting for orchestrator snapshot cache: #{inspect(last_seen)}")
    else
      Process.sleep(5)
      do_wait_for_snapshot_cache(pid, predicate, deadline_ms)
    end
  end

  defp wait_for_run_record(predicate) when is_function(predicate, 1) do
    wait_for_run_record(predicate, 500)
  end

  defp wait_for_run_record(predicate, timeout_ms) when is_function(predicate, 1) and is_integer(timeout_ms) do
    wait_for_run_record(Config.repo_key!(), predicate, timeout_ms)
  end

  defp wait_for_run_record(repo_key, predicate) when is_binary(repo_key) and is_function(predicate, 1) do
    wait_for_run_record(repo_key, predicate, 500)
  end

  defp wait_for_run_record(repo_key, predicate, timeout_ms) when is_binary(repo_key) and is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + max(timeout_ms, @min_wait_ms)
    do_wait_for_run_record(repo_key, predicate, deadline_ms)
  end

  defp running_entry_for_token_test(%Issue{} = issue, %DateTime{} = started_at) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }
  end

  defp do_wait_for_run_record(repo_key, predicate, deadline_ms) do
    record =
      RunStore.list_runs(repo_key, :all)
      |> Enum.find(predicate)

    cond do
      is_map(record) ->
        record

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("timed out waiting for run store record: #{inspect(RunStore.list_runs(repo_key, :all))}")

      true ->
        Process.sleep(5)
        do_wait_for_run_record(repo_key, predicate, deadline_ms)
    end
  end

  defp wait_for_file_contents(path, expected, timeout_ms) when is_binary(path) do
    deadline_ms = System.monotonic_time(:millisecond) + max(timeout_ms, @min_wait_ms)
    do_wait_for_file_contents(path, expected, deadline_ms)
  end

  defp flush_notification_events do
    receive do
      {:notification_event, _event} -> flush_notification_events()
    after
      0 -> :ok
    end
  end

  defp do_wait_for_file_contents(path, expected, deadline_ms) do
    case File.read(path) do
      {:ok, ^expected} ->
        true

      _ ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk("timed out waiting for file #{path} to contain #{inspect(expected)}")
        else
          Process.sleep(5)
          do_wait_for_file_contents(path, expected, deadline_ms)
        end
    end
  end

  defp write_workflow_without_token_budget_keys! do
    File.write!(Workflow.workflow_file_path(), "Prompt\n")

    File.write!(Workflow.symphony_file_path(), """
    issues:
      provider: memory
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: default
        workflow: #{Workflow.workflow_file_path()}
        route:
          team: Test
    """)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp dispatch_prefetch_task?(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stacktrace} -> Enum.any?(stacktrace, &match?({Orchestrator, :prefetch_dispatch_issues, 1, _location}, &1))
      nil -> false
    end
  end

  defp terminate_task_supervisor_children do
    SymphonyElixir.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.each(fn pid ->
      Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid)
    end)
  end

  defp ensure_orchestrator_running do
    case Process.whereis(Orchestrator) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case Supervisor.restart_child(SymphonyElixir.Supervisor, Orchestrator) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
          {:error, :not_found} -> start_unsupervised_orchestrator()
        end
    end
  end

  defp start_unsupervised_orchestrator do
    {:ok, pid} = Orchestrator.start_link()

    ExUnit.Callbacks.on_exit(fn ->
      # The orchestrator is linked to the test process, so it can exit
      # between an alive? check and the stop call; tolerate :noproc.
      try do
        GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    pid
  end

  defp graph_samples_from_rates(rates_per_bucket) do
    bucket_ms = 25_000

    {timestamp, tokens, samples} =
      Enum.reduce(rates_per_bucket, {0, 0, []}, fn rate, {timestamp, tokens, acc} ->
        next_timestamp = timestamp + bucket_ms
        next_tokens = tokens + trunc(rate * bucket_ms / 1000)
        {next_timestamp, next_tokens, [{timestamp, tokens} | acc]}
      end)

    {tokens, [{timestamp, tokens} | samples]}
  end

  defp graph_samples_for_stability_test(now_ms) do
    rates_per_bucket = Enum.map(1..24, &(&1 * 5))
    bucket_ms = 25_000

    rate_for_timestamp = fn timestamp ->
      bucket_idx = min(div(max(timestamp, 0), bucket_ms), 23)
      Enum.at(rates_per_bucket, bucket_idx, 0)
    end

    0..(now_ms - 1_000)//1_000
    |> Enum.reduce({0, []}, fn timestamp, {tokens, acc} ->
      next_tokens = tokens + rate_for_timestamp.(timestamp)
      {next_tokens, [{timestamp, next_tokens} | acc]}
    end)
    |> elem(1)
  end
end
