defmodule SymphonyElixir.CoreOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentProcesses

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)
    hook_marker = Path.join(test_root, "before_remove.marker")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        hook_before_remove: "printf ran > #{hook_marker}"
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.add(DateTime.utc_now(), -300, :second)
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      # A move to Backlog keeps the workspace, so the before_remove hook that closes PRs never runs.
      assert :ok = WorkspaceCleanup.await(issue_identifier)
      assert File.exists?(workspace)
      refute File.exists?(hook_marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "freshly dispatched agent ignores stale non-active issue state" do
    issue_id = "issue-fresh-stale-state"
    issue_identifier = "MT-556"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
    )

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: issue_identifier,
          issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
          state_reconcile_grace_until_ms: System.monotonic_time(:millisecond) + 120_000,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      state: "In Review",
      title: "Awaiting review",
      description: "Reviewer comments are being applied",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.watching, issue_id)
    assert Process.alive?(agent_pid)
  end

  test "non-active issue state immediately appears in watching map" do
    issue_id = "issue-watching-handoff"
    issue_identifier = "MT-557"
    issue_url = "https://linear.app/example/issue/MT-557"
    pull_request_url = "https://github.com/example/repo/pull/557"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Cancelled"]
    )

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      repo_key: "default",
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: issue_identifier,
          issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
          started_at: DateTime.add(DateTime.utc_now(), -300, :second)
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      state: "In Review",
      title: "Awaiting review",
      url: issue_url,
      labels: []
    }

    :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue_id, pull_request_url, nil)
    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    assert Map.has_key?(updated_state.watching, issue_id)

    assert %{
             identifier: ^issue_identifier,
             state: "In Review",
             url: ^issue_url,
             pull_request_url: ^pull_request_url
           } = Map.get(updated_state.watching, issue_id)
  end

  test "a run stopped because its ticket left the active states records its run.ended (TP-1336)" do
    issue_id = "issue-stopped-run-ended"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Cancelled"]
    )

    agent_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(agent_pid, :kill) end)

    entry = fn id, kind ->
      %{
        pid: agent_pid,
        ref: nil,
        identifier: "MT-560",
        run_id: "run-#{id}",
        run_kind: kind,
        issue: %Issue{id: id, state: "CI Fix", identifier: "MT-560"},
        started_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }
    end

    started = %{run_id: "run-#{issue_id}", run_kind: "ci_fix", run_number: 1, state: "CI Fix"}
    :ok = SymphonyElixir.TicketSignals.record_event("default", issue_id, "run.started", started, run_id: "run-#{issue_id}")

    state = %Orchestrator.State{
      repo_key: "default",
      running: %{issue_id => entry.(issue_id, :ci_fix), "issue-stopped-review" => entry.("issue-stopped-review", :pr)},
      claimed: MapSet.new([issue_id, "issue-stopped-review"]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    parked = fn id -> %Issue{id: id, identifier: "MT-560", state: "Backlog", title: "Parked", labels: []} end
    updated_state = Orchestrator.reconcile_issue_states_for_test([parked.(issue_id), parked.("issue-stopped-review")], state)

    assert updated_state.running == %{}

    assert [%{payload: %{run_id: "run-issue-stopped-run-ended", run_kind: "ci_fix", exit: "stopped: its ticket moved to Backlog"}}] =
             SymphonyElixir.TicketEvents.query(issue_id) |> Enum.filter(&(&1.type == "run.ended"))

    # A review run records no run.ended, as on its DOWN.
    assert SymphonyElixir.TicketEvents.query("issue-stopped-review") |> Enum.filter(&(&1.type == "run.ended")) == []
  end

  test "seed_watching_for_test populates watching from completed_run_metadata" do
    issue_id = "issue-seed-watch"
    issue_identifier = "MT-558"
    issue_url = "https://linear.app/example/issue/MT-558"
    pull_request_url = "https://github.com/example/repo/pull/558"

    completed_metadata = %{
      issue_id => %{
        identifier: issue_identifier,
        title: "Awaiting review",
        state: "In Review",
        url: issue_url,
        pull_request_url: pull_request_url,
        last_ran_at: DateTime.utc_now(),
        session_id: "session-seed",
        started_at: DateTime.utc_now(),
        last_event_at: DateTime.utc_now(),
        turn_count: 2,
        tokens: %{total_tokens: 100}
      }
    }

    state = %Orchestrator.State{
      repo_key: "default",
      completed_run_metadata: completed_metadata,
      watching: %{},
      retry_attempts: %{}
    }

    seeded = Orchestrator.seed_watching_for_test(state)

    assert Map.has_key?(seeded.watching, issue_id)

    assert %{
             identifier: ^issue_identifier,
             title: "Awaiting review",
             state: "In Review",
             url: ^issue_url,
             pull_request_url: ^pull_request_url
           } = Map.get(seeded.watching, issue_id)
  end

  test "seed_watching_for_test skips entries with no persisted state" do
    issue_id = "issue-no-state"

    state = %Orchestrator.State{
      repo_key: "default",
      completed_run_metadata: %{
        issue_id => %{
          identifier: "MT-559",
          state: nil,
          last_ran_at: DateTime.utc_now()
        }
      },
      watching: %{},
      retry_attempts: %{}
    }

    seeded = Orchestrator.seed_watching_for_test(state)

    refute Map.has_key?(seeded.watching, issue_id)
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join([test_root, "api", issue_identifier])
    hook_marker = Path.join(test_root, "before_remove.marker")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        hook_before_remove: "printf '%s|%s' \"$SYMPHONY_REMOVE_REASON\" \"$SYMPHONY_ISSUE_STATE\" > #{hook_marker}"
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        repo_key: "default",
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            repo_key: "api",
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier, repo_key: "api"},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Canceled",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert :ok = WorkspaceCleanup.await(issue_identifier)
      refute File.exists?(workspace)
      assert File.read!(hook_marker) == "terminal|Canceled"
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state gives a landing agent a grace period before cleanup" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-merging-terminal-grace-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-merging"
    issue_identifier = "MT-560"
    workspace = Path.join([test_root, "api", issue_identifier])

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "Merging"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
      )

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          Process.exit(agent_pid, :kill)
        end
      end)

      state = %Orchestrator.State{
        repo_key: "default",
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            repo_key: "api",
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Merging", identifier: issue_identifier, repo_key: "api"},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{id: issue_id, identifier: issue_identifier, state: "Done", title: "Merged", labels: []}

      graced_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      assert %{terminal_grace_until_ms: grace_until_ms} = graced_state.running[issue_id]
      assert grace_until_ms > System.monotonic_time(:millisecond) + 60_000
      assert MapSet.member?(graced_state.claimed, issue_id)
      assert Process.alive?(agent_pid)
      assert File.exists?(workspace)

      assert Orchestrator.reconcile_issue_states_for_test([issue], graced_state) == graced_state

      expired_state =
        put_in(
          graced_state.running[issue_id].terminal_grace_until_ms,
          System.monotonic_time(:millisecond) - 1
        )

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], expired_state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert :ok = WorkspaceCleanup.await(issue_identifier)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops an agent without an issue snapshot immediately" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-no-snapshot-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-no-snapshot"
    issue_identifier = "MT-561"
    workspace = Path.join([test_root, "api", issue_identifier])

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "Merging"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
      )

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        repo_key: "default",
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            repo_key: "api",
            identifier: issue_identifier,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{id: issue_id, identifier: issue_identifier, state: "Done", title: "Merged", labels: []}

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert :ok = WorkspaceCleanup.await(issue_identifier)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)

      # The poll cycle runs in a task and reconciles when its result comes back, so wait on the
      # state it leaves rather than a fixed sleep.
      state =
        eventually(fn ->
          state = :sys.get_state(pid)
          not Map.has_key?(state.running, issue_id) and state
        end)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile keeps active run on its frozen repo when routing fields change" do
    issue_id = "issue-route-sticky"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          repo_key: "api",
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            repo_key: "api",
            labels: ["backend"],
            project: %{id: "project-api", name: "API"},
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should keep going",
      repo_key: "web",
      labels: ["frontend"],
      project: %{id: "project-web", name: "Web"},
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert Process.alive?(agent_pid)
    assert updated_entry.repo_key == "api"
    assert updated_entry.issue.repo_key == "api"
    assert updated_entry.issue.labels == ["frontend"]
    assert updated_entry.issue.project == %{id: "project-web", name: "Web"}
    assert updated_entry.issue.assigned_to_worker == false

    send(agent_pid, :stop)
  end

  test "persisted run start records the dispatch-time repo_key" do
    issue = %Issue{
      id: "issue-persist-sticky-repo",
      identifier: "MT-562",
      title: "Persist sticky repo",
      state: "In Progress",
      repo_key: "web"
    }

    running_entry = %{
      run_id: "run-persist-sticky-repo",
      repo_key: "api",
      identifier: issue.identifier,
      issue: %{issue | repo_key: "api"},
      started_at: DateTime.utc_now()
    }

    assert :ok = Orchestrator.persist_run_start_for_test(issue, running_entry, nil)

    assert [%{run_id: "run-persist-sticky-repo", repo_key: "api", issue_identifier: "MT-562"}] =
             RunStore.list_runs("api")

    assert [] = RunStore.list_runs("web")
  end

  test "retry keeps the original repo_key when labels now match a different repo" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 1,
      quality_gate: %{enabled: false},
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    issue_id = "issue-label-rerouted"
    metadata = %{repo_key: "api", identifier: "MT-563", worker_host: nil, workspace_path: nil}

    refreshed_issue = %Issue{
      id: issue_id,
      identifier: "MT-563",
      title: "Label rerouted",
      state: "In Progress",
      repo_key: "web",
      labels: ["frontend"],
      assigned_to_worker: true
    }

    state = %Orchestrator.State{
      repo_key: "default",
      max_concurrent_agents: 0,
      running: %{},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, metadata, fn [^issue_id] ->
               {:ok, [refreshed_issue]}
             end)

    # Waiting for a slot keeps the attempt and the sticky repo, outside the backoff queue.
    assert %{
             attempt: 1,
             repo_key: "api",
             identifier: "MT-563",
             reason: "no available orchestrator slots"
           } = updated_state.slot_waiting[issue_id]

    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    assert [] = RunStore.list_retries("api")

    assert [] = RunStore.list_retries("web")
  end

  test "an issue whose workspace may still hold a previous Symphony's agent is not dispatched" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 2,
      quality_gate: %{enabled: false},
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    port =
      Port.open({:spawn_executable, String.to_charlist(System.find_executable("sh"))}, [
        :binary,
        :exit_status,
        args: [~c"-c", ~c"echo ready; exec sleep 600"]
      ])

    assert_receive {^port, {:data, "ready\n"}}, 5_000
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    left_running = %{pgid: os_pid, start_time: nil, workspace: "/workspaces/default/MT-LEFT", reason: "left running"}
    :sys.replace_state(AgentProcesses, &put_in(&1.blocked[os_pid], left_running))

    on_exit(fn ->
      :sys.replace_state(AgentProcesses, &%{&1 | blocked: Map.delete(&1.blocked, os_pid)})
      System.cmd("kill", ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
    end)

    issue_id = "issue-left-running"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-LEFT",
      title: "Left running",
      state: "In Progress",
      assigned_to_worker: true
    }

    state = %Orchestrator.State{
      repo_key: "default",
      max_concurrent_agents: 2,
      running: %{},
      claimed: MapSet.new(),
      budget_exhausted: MapSet.new(),
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(%{issue | id: "issue-other", identifier: "MT-OTHER"}, state)

    metadata = %{repo_key: "default", identifier: "MT-LEFT", worker_host: nil, workspace_path: nil}
    state = %{state | claimed: MapSet.new([issue_id])}

    assert {:noreply, updated_state} =
             Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, metadata, fn [^issue_id] ->
               {:ok, [issue]}
             end)

    assert %{attempt: 1, error: "an agent from a previous Symphony may still be running in the workspace"} =
             updated_state.retry_attempts[issue_id]
  end

  test "retry keeps the original repo_key when the issue no longer matches any repo" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 1,
      quality_gate: %{enabled: false},
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    issue_id = "issue-label-unrouted"
    metadata = %{repo_key: "api", identifier: "MT-564", worker_host: nil, workspace_path: nil}

    refreshed_issue = %Issue{
      id: issue_id,
      identifier: "MT-564",
      title: "Label unrouted",
      state: "In Progress",
      repo_key: nil,
      labels: [],
      assigned_to_worker: true
    }

    state = %Orchestrator.State{
      repo_key: "default",
      max_concurrent_agents: 0,
      running: %{},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, metadata, fn [^issue_id] ->
               {:ok, [refreshed_issue]}
             end)

    # Waiting for a slot keeps the attempt and the sticky repo, outside the backoff queue.
    assert %{
             attempt: 1,
             repo_key: "api",
             identifier: "MT-564",
             reason: "no available orchestrator slots"
           } = updated_state.slot_waiting[issue_id]

    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    assert [] = RunStore.list_retries("api")

    assert [] = RunStore.list_retries("default")
  end

  test "sticky retry dispatch revalidation ignores mutable route fields but not terminal state or assignment" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    active_issue = %Issue{
      id: "issue-sticky-active",
      identifier: "MT-565",
      title: "Sticky active",
      state: "In Progress",
      assigned_to_worker: true
    }

    routing_mismatch_issue = %{active_issue | id: "issue-sticky-rerouted", repo_key: "web", labels: ["frontend"]}
    unassigned_issue = %{active_issue | id: "issue-sticky-unassigned", assigned_to_worker: false}
    terminal_issue = %{routing_mismatch_issue | id: "issue-sticky-terminal", state: "Done"}

    assert Orchestrator.dispatch_revalidated_issue_for_test(active_issue, true)
    assert Orchestrator.dispatch_revalidated_issue_for_test(routing_mismatch_issue, true)
    refute Orchestrator.dispatch_revalidated_issue_for_test(terminal_issue, true)
    refute Orchestrator.dispatch_revalidated_issue_for_test(unassigned_issue, true)
    refute Orchestrator.dispatch_revalidated_issue_for_test(unassigned_issue, false)
  end

  for {label, extra_metadata} <- [{"retry", %{}}, {"continuation", %{continuation: true, delay_type: :continuation}}] do
    test "a #{label} of an issue no longer assigned to the worker is dropped, and reassigning it makes it eligible again" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 2,
        quality_gate: %{enabled: false},
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
      )

      issue_id = "issue-unassigned-#{unquote(label)}"

      unassigned_issue = %Issue{
        id: issue_id,
        identifier: "MT-566",
        title: "Unassigned while its retry was queued",
        state: "In Progress",
        assigned_to_worker: false
      }

      metadata = Map.merge(%{repo_key: "default", identifier: "MT-566", worker_host: nil, workspace_path: nil}, unquote(Macro.escape(extra_metadata)))

      state = %Orchestrator.State{
        repo_key: "default",
        max_concurrent_agents: 2,
        running: %{},
        claimed: MapSet.new([issue_id]),
        budget_exhausted: MapSet.new(),
        retry_attempts: %{},
        watching: %{issue_id => %{identifier: "MT-566"}},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, updated_state} =
                   Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, metadata, fn [^issue_id] ->
                     {:ok, [unassigned_issue]}
                   end)

          send(self(), {:updated_state, updated_state})
        end)

      assert_received {:updated_state, updated_state}
      assert log =~ "Dropping retry of issue_id=#{issue_id} issue_identifier=MT-566: not assigned to this Symphony's worker"

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Map.has_key?(updated_state.retry_attempts, issue_id)
      refute Map.has_key?(updated_state.slot_waiting, issue_id)
      refute Map.has_key?(updated_state.watching, issue_id)
      assert [] = RunStore.list_retries("default")

      refute Orchestrator.should_dispatch_issue_for_test(unassigned_issue, updated_state)
      assert Orchestrator.should_dispatch_issue_for_test(%{unassigned_issue | assigned_to_worker: true}, updated_state)
    end
  end

  test "normal worker exit schedules active-state continuation retry" do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      repo_key: "api",
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress", repo_key: "api"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms, repo_key: "api", delay_type: :continuation} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, 250, 1_100)

    assert [%{issue_id: ^issue_id, repo_key: "api", delay_type: :continuation}] =
             RunStore.list_retries("api")
  end

  test "retry for an active completed PR on a designed repo dispatches the run instead of moving to the global Auto Review" do
    workflow = Workflow.workflow_file_path()

    write_workflow_file!(workflow,
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      pr_review_mode: "polling",
      ci: %{enabled: true},
      auto_review: %{enabled: true},
      repos: [
        [key: "legacy-repo", workflow: workflow, team: "Legacy"],
        [key: "designed-repo", workflow: workflow, team: "Designed"]
      ]
    )

    issue_id = "issue-post-pr-designed"
    retry_token = make_ref()
    last_ran_at = DateTime.utc_now()
    pr_url = "https://github.com/example/repo/pull/880"
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    # The refetch carries no repo key, as `fetch_issue_states_by_ids` returns it.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: issue_id, identifier: "MT-880", title: "Post PR", state: "In Progress", updated_at: DateTime.add(last_ran_at, -10, :second)}
    ])

    :ok = SymphonyElixir.TicketPullRequest.record_created("designed-repo", issue_id, pr_url, nil)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    end)

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :PostPrDesignedOrchestrator))
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    log =
      capture_log(fn ->
        completed = %{identifier: "MT-880", pull_request_url: pr_url, last_ran_at: last_ran_at}
        due_at_ms = System.monotonic_time(:millisecond)
        retry = %{attempt: 1, timer_ref: nil, retry_token: retry_token, due_at_ms: due_at_ms, identifier: "MT-880"}
        retry = Map.put(retry, :repo_key, "designed-repo")

        :sys.replace_state(pid, fn state ->
          %{state | claimed: MapSet.new([issue_id]), completed_run_metadata: %{issue_id => completed}, retry_attempts: %{issue_id => retry}}
        end)

        send(pid, {:retry_issue, issue_id, retry_token})
        moved_or_ran? = &(Map.has_key?(&1.running, issue_id) or Map.has_key?(&1.watching, issue_id))
        # The dispatch prepares the workspace before the run is listed, which takes longer than the
        # default deadline under a loaded cover run; the wait ends as soon as the run is listed.
        state = wait_for_orchestrator_state(pid, moved_or_ran?, 5_000)
        assert %{issue: %Issue{repo_key: "designed-repo"}} = state.running[issue_id]
      end)

    refute log =~ "moving to Auto Review"
    refute_received {:memory_tracker_state_update, ^issue_id, "Auto Review"}
  end

  describe "quiet designed runs on a pushed PR" do
    setup do
      workflow = Workflow.workflow_file_path()

      write_workflow_file!(workflow,
        tracker_active_states: ["Todo", "In Progress", "Rework"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
        pr_review_mode: "polling",
        ci: %{enabled: true},
        repos: [[key: "designed-repo", workflow: workflow, team: "Designed"]]
      )

      issue_id = "issue-quiet-designed"
      pr_url = "https://github.com/example/repo/pull/884"
      last_ran_at = DateTime.utc_now()
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{id: issue_id, identifier: "MT-884", title: "Quiet", state: "In Progress", updated_at: DateTime.add(last_ran_at, -10, :second)}
      ])

      :ok = SymphonyElixir.TicketPullRequest.record_created("designed-repo", issue_id, pr_url, nil)

      RunStore.delete_ticket_state(issue_id)

      on_exit(fn ->
        RunStore.delete_ticket_state(issue_id)
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      end)

      %{issue_id: issue_id, completed: %{identifier: "MT-884", pull_request_url: pr_url, last_ran_at: last_ran_at}}
    end

    defp start_quiet_retry(name, issue_id, completed, quiet_runs) do
      {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, name))
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
      retry_token = make_ref()

      retry = %{
        attempt: 1,
        timer_ref: nil,
        retry_token: retry_token,
        due_at_ms: System.monotonic_time(:millisecond),
        identifier: "MT-884",
        repo_key: "designed-repo",
        delay_type: :continuation
      }

      :sys.replace_state(pid, fn state ->
        %{
          state
          | claimed: MapSet.new([issue_id]),
            completed_run_metadata: %{issue_id => completed},
            retry_attempts: %{issue_id => retry},
            quiet_handoff_runs: quiet_runs
        }
      end)

      send(pid, {:retry_issue, issue_id, retry_token})
      pid
    end

    test "the first quiet run backs off instead of continuing in a second", %{issue_id: issue_id, completed: completed} do
      log =
        capture_log(fn ->
          pid = start_quiet_retry(:QuietFirst, issue_id, completed, %{issue_id => {"sha-older", 1}})
          state = wait_for_orchestrator_state(pid, &match?(%{attempt: 2}, &1.retry_attempts[issue_id]))

          assert %{delay_type: nil, error: "handoff_missing"} = state.retry_attempts[issue_id]
          assert state.quiet_handoff_runs[issue_id] == {nil, 1}
          refute Map.has_key?(state.running, issue_id)
        end)

      assert log =~ "without the handoff signal (1 of 2); backing off"
    end

    test "the capped quiet run on the same head asks what now and is held with handoff_missing, which Unblock lifts", %{issue_id: issue_id, completed: completed} do
      log =
        capture_log(fn ->
          pid = start_quiet_retry(:QuietCapped, issue_id, completed, %{issue_id => {nil, 1}})
          state = wait_for_orchestrator_state(pid, &(not MapSet.member?(&1.claimed, issue_id)))

          refute Map.has_key?(state.running, issue_id)
          refute Map.has_key?(state.retry_attempts, issue_id)
          refute Map.has_key?(state.quiet_handoff_runs, issue_id)
        end)

      ticket = {:ticket, "designed-repo", issue_id}
      assert [%{title: "MT-884's last two runs ended without a handoff", id: question_id}] = SymphonyElixir.Questions.open(ticket)
      assert {:ok, %{reasons: [%{kind: :question, waits_on: %{question_id: ^question_id}}]}} = SymphonyElixir.Pauses.get(ticket)

      record = RunStore.get_ticket_state(issue_id)
      assert log =~ "handoff_missing: 2 runs"
      assert [%{name: "handoff_missing", details: %{held: true, quiet_runs: 2}} | _rest] = ticket_signals(record.issue_id)

      # The question is the one Unblock answers.
      assert %{id: ^question_id} = SymphonyElixir.Questions.held(ticket)
    end

    test "a quiet run waiting on its decision request is not counted or capped, and waits for the decision", %{issue_id: issue_id, completed: completed} do
      request = %{
        title: "Is the drain report empty?",
        question: "Is the drain report empty?",
        why: "Only a person can read it.",
        if_unanswered: "The ticket waits.",
        recommendation_reason: "It is the usual case.",
        options: [%{label: "Yes", effect: "It goes on.", recommended: true}, %{label: "No", effect: "It stops."}]
      }

      ticket = {:ticket, "designed-repo", issue_id}
      {:ok, %{id: question_id}} = SymphonyElixir.Questions.ask(ticket, request, request: true)

      log =
        capture_log(fn ->
          pid = start_quiet_retry(:QuietDecision, issue_id, completed, %{issue_id => {nil, 1}})
          state = wait_for_orchestrator_state(pid, &(not MapSet.member?(&1.claimed, issue_id)))

          refute Map.has_key?(state.running, issue_id)
          refute Map.has_key?(state.retry_attempts, issue_id)
          refute Map.has_key?(state.quiet_handoff_runs, issue_id)
        end)

      refute log =~ "without the handoff signal"
      assert %{id: ^question_id} = SymphonyElixir.Questions.deciding(ticket)
      assert {:ok, %{reasons: [%{kind: :question, waits_on: %{question_id: ^question_id}}]}} = SymphonyElixir.Pauses.get(ticket)
    end

    test "a quiet count is dropped once the issue leaves the active states", %{issue_id: issue_id, completed: completed} do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{id: issue_id, identifier: "MT-884", title: "Quiet", state: "Backlog"}
      ])

      capture_log(fn ->
        pid = start_quiet_retry(:QuietLeft, issue_id, completed, %{issue_id => {nil, 1}})
        state = wait_for_orchestrator_state(pid, &(not MapSet.member?(&1.claimed, issue_id)))

        refute Map.has_key?(state.quiet_handoff_runs, issue_id)
      end)
    end

    test "a quiet run with unpushed commits is dispatched again to push them", %{issue_id: issue_id, completed: completed} do
      repo = Path.join(System.tmp_dir!(), "symphony-quiet-unpushed-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf(repo) end)
      git = &System.cmd("git", ["-C", repo | &1])
      git.(["init", "-b", "main"])
      git.(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--allow-empty", "-m", "one"])
      git.(["update-ref", "refs/remotes/origin/main", "HEAD"])
      git.(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--allow-empty", "-m", "two"])

      capture_log(fn ->
        pid = start_quiet_retry(:QuietUnpushed, issue_id, Map.put(completed, :workspace_path, repo), %{})
        state = wait_for_orchestrator_state(pid, &Map.has_key?(&1.running, issue_id))

        refute Map.has_key?(state.quiet_handoff_runs, issue_id)
      end)
    end
  end

  test "a run that ended without a PR still waits for a slot to continue" do
    issue_id = "issue-no-pr-busy-slots"
    pid = end_run_with_busy_slots(issue_id, :NoPrBusySlotsOrchestrator, nil)

    state = wait_for_orchestrator_state(pid, &Map.has_key?(&1.slot_waiting, issue_id), 2_000)

    assert %{attempt: 1} = state.slot_waiting[issue_id]
    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.watching, issue_id)
    refute_received {:memory_tracker_state_update, ^issue_id, _state}
  end

  defp write_post_pr_auto_review_workflow!(overrides) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      [
        quality_gate: %{enabled: false},
        tracker_active_states: ["Todo", "In Progress", "Rework"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
        pr_review_mode: "polling",
        ci: %{enabled: true},
        auto_review: %{enabled: true}
      ] ++ overrides
    )
  end

  # Ends a run that was dispatched without a PR while another run holds the only slot, then
  # fires its continuation retry. `pr_url` is the PR Symphony's record holds for the ticket, and
  # `run_opts[:workspace_path]` the workspace the run worked in.
  #
  # The orchestrator polls once on startup; the runs and their issues go in only after that poll
  # has passed over an empty tracker, and the next one is a poll interval away. A poll that does
  # come (one a state move requests) finds the busy issue in the tracker and keeps its slot taken.
  # Both runs point at a stand-in worker, not the test process: stopping a run sends `:shutdown`.
  defp end_run_with_busy_slots(issue_id, name, pr_url, run_opts \\ []) do
    write_post_pr_auto_review_workflow!(max_concurrent_agents: 1)
    last_ran_at = DateTime.utc_now()
    dispatched = %Issue{id: issue_id, identifier: "MT-385", title: "Open a PR", state: "In Progress"}
    busy = %Issue{id: "issue-busy-slot", identifier: "MT-BUSY", title: "Busy", state: "In Progress"}

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    end)

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, name))

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    wait_for_orchestrator_state(pid, &(not &1.poll_check_in_progress), 2_000)

    worker = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(worker, :kill) end)

    ref = make_ref()
    # The periodic snapshot reads the last-event fields of every run, so they must be present.
    run = %{
      pid: worker,
      started_at: DateTime.utc_now(),
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil
    }

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{
        issue_id => Map.merge(run, %{ref: ref, identifier: "MT-385", issue: dispatched, workspace_path: run_opts[:workspace_path]}),
        busy.id => Map.merge(run, %{ref: make_ref(), identifier: "MT-BUSY", issue: busy})
      })
      |> Map.put(:claimed, MapSet.new([issue_id, busy.id]))
      |> Map.put(:retry_attempts, %{})
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %{dispatched | updated_at: DateTime.add(last_ran_at, -10, :second)},
      busy
    ])

    if pr_url, do: :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue_id, pr_url, nil)

    send(pid, {:DOWN, ref, :process, worker, :normal})

    %{retry_token: retry_token} =
      pid
      |> wait_for_orchestrator_state(&Map.has_key?(&1.retry_attempts, issue_id))
      |> Map.fetch!(:retry_attempts)
      |> Map.fetch!(issue_id)

    send(pid, {:retry_issue, issue_id, retry_token})
    pid
  end

  test "retry for a Merging issue with a completed PR re-dispatches it instead of moving it back to review" do
    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{enabled: false},
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    issue_id = "issue-merging-waits-for-ci"
    pr_url = "https://github.com/example/repo/pull/232"
    retry_token = make_ref()
    last_ran_at = DateTime.utc_now()

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: issue_id,
        identifier: "MT-232",
        title: "Land after CI",
        state: "Merging",
        updated_at: DateTime.add(last_ran_at, -10, :second)
      }
    ])

    :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue_id, pr_url, nil)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    end)

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :MergingWaitsForCiOrchestrator))

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:max_concurrent_agents, 0)
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:slot_holders, %{issue_id => %{identifier: "MT-232", state: "Merging", repo_key: nil, since: last_ran_at}})
      |> Map.put(:completed_run_metadata, %{issue_id => %{identifier: "MT-232", pull_request_url: pr_url, last_ran_at: last_ran_at}})
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 1,
          timer_ref: nil,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: "MT-232"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, retry_token})

    # The ticket holds its slot from its earlier runs, so its landing run starts even with no slot free.
    state =
      wait_for_orchestrator_state(pid, fn state ->
        Map.has_key?(state.running, issue_id) or match?(%{attempt: 2}, state.retry_attempts[issue_id])
      end)

    refute_received {:memory_tracker_state_update, ^issue_id, _state}
    assert MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.watching, issue_id)

    # The re-dispatched run fails against this test's workspace, and its Task is supervised
    # outside this orchestrator, so it outlives the test. Wait for the run to finish before
    # returning: its "Agent run failed" log would otherwise land in the next test's
    # `capture_log` window and break an unrelated assertion.
    wait_for_orchestrator_state(pid, fn state -> not Map.has_key?(state.running, issue_id) end, 5_000)
  end

  test "a landing run that ends on pending checks is held in Merging instead of continued" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

    issue_id = "issue-merging-ci-hold"
    pr_url = "https://github.com/example/repo/pull/232"
    ref = make_ref()
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :MergingCiHoldOrchestrator))

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    issue = %Issue{id: issue_id, identifier: "MT-232", title: "Land after CI", state: "Merging", repo_key: "api"}
    :ok = SymphonyElixir.TicketPullRequest.record_created("api", issue_id, pr_url, nil)
    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:max_concurrent_agents, 0)
      |> Map.put(:running, %{issue_id => %{pid: self(), ref: ref, repo_key: "api", identifier: "MT-232", issue: issue, started_at: DateTime.utc_now()}})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:merging_ci_wait, "issue-not-running", %{commit_sha: "sha-other", pr_url: pr_url}})
    send(pid, {:merging_ci_wait, issue_id, %{commit_sha: "sha-pending", pr_url: pr_url}})
    send(pid, {:DOWN, ref, :process, self(), :normal})

    state = wait_for_orchestrator_state(pid, &(not Map.has_key?(&1.running, issue_id)))

    refute Map.has_key?(state.retry_attempts, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    assert RunStore.list_retries("api") == []
    assert %{commit_sha: "sha-pending", repo_key: "api", identifier: "MT-232", pull_request_url: ^pr_url} = state.merging_ci_waits[issue_id]
    refute Map.has_key?(state.merging_ci_waits, "issue-not-running")
    refute Orchestrator.should_dispatch_issue_for_test(issue, %{state | max_concurrent_agents: 1})

    assert %{waiting_for_ci: [%{issue_id: ^issue_id, identifier: "MT-232", commit_sha: "sha-pending", seconds_waiting: seconds}]} =
             GenServer.call(pid, :snapshot)

    assert is_integer(seconds)
  end

  test "a held landing issue is dispatched once the CI poller sees its head go green" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    issue_id = "issue-merging-ci-green"
    issue = %Issue{id: issue_id, identifier: "MT-233", title: "Land after CI", state: "Merging", repo_key: "api"}
    state = merging_ci_hold_state(issue_id, "sha-head", DateTime.utc_now())

    # Nothing observed yet, then the poller still sees the head running.
    assert held_after_release?(state, issue)
    put_observed_head!(issue_id, "sha-head", "IN_PROGRESS")
    assert held_after_release?(state, issue)

    # A green result for an older head does not count.
    put_observed_head!(issue_id, "sha-older", "SUCCESS")
    assert held_after_release?(state, issue)

    put_observed_head!(issue_id, "sha-head", "SUCCESS")
    released = Orchestrator.release_merging_ci_waits_for_test(state, [issue])

    assert released.merging_ci_waits == %{}
    assert Orchestrator.should_dispatch_issue_for_test(issue, released)
    # The released issue stays in Merging; nothing moved it back to review.
    assert released.watching == %{}
  end

  test "a held landing issue is dispatched once every check its base branch requires passed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    issue_id = "issue-merging-ci-required"
    issue = %Issue{id: issue_id, identifier: "MT-236", title: "Land after CI", state: "Merging", repo_key: "api"}
    state = merging_ci_hold_state(issue_id, "sha-head", DateTime.utc_now())

    # A check the branch doesn't require still runs; an older head was ready to land.
    put_observed_head!(issue_id, "sha-head", "IN_PROGRESS", "sha-older")
    assert held_after_release?(state, issue)

    put_observed_head!(issue_id, "sha-head", "IN_PROGRESS", "sha-head")
    released = Orchestrator.release_merging_ci_waits_for_test(state, [issue])

    assert released.merging_ci_waits == %{}
    assert Orchestrator.should_dispatch_issue_for_test(issue, released)
  end

  test "a held landing issue whose wait has no head SHA stays held while no head is ready to land" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    issue_id = "issue-merging-ci-no-sha"
    issue = %Issue{id: issue_id, identifier: "MT-237", title: "Land after CI", state: "Merging", repo_key: "api"}
    state = merging_ci_hold_state(issue_id, nil, DateTime.utc_now())

    # No record at all, then a record with no head ready to land.
    assert held_after_release?(state, issue)
    put_observed_head!(issue_id, "sha-head", "IN_PROGRESS")
    assert held_after_release?(state, issue)
  end

  test "a held landing issue with a red head goes through the CI-failure path, not a landing dispatch" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    issue_id = "issue-merging-ci-red"
    issue = %Issue{id: issue_id, identifier: "MT-234", title: "Land after CI", state: "Merging", repo_key: "api"}
    state = merging_ci_hold_state(issue_id, "sha-head", DateTime.utc_now())

    put_observed_head!(issue_id, "sha-head", "FAILURE")
    assert held_after_release?(state, issue)

    # The CI poller's failure dispatch moves the issue to In Progress; the hold lets go and
    # the issue is dispatched as CI-failure rework.
    rework_issue = %{issue | state: "In Progress"}
    released = Orchestrator.release_merging_ci_waits_for_test(state, [rework_issue])

    assert released.merging_ci_waits == %{}
    assert Orchestrator.should_dispatch_issue_for_test(rework_issue, released)

    # An issue that left the candidates altogether (for example escalated to review) also lets go.
    assert Orchestrator.release_merging_ci_waits_for_test(state, []).merging_ci_waits == %{}
  end

  test "a held landing issue is re-dispatched once after the CI wait timeout" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      ci: %{merging_wait_timeout_ms: 60_000}
    )

    assert Config.settings!().ci.merging_wait_timeout_ms == 60_000

    issue_id = "issue-merging-ci-timeout"
    issue = %Issue{id: issue_id, identifier: "MT-235", title: "Land after CI", state: "Merging", repo_key: "api"}
    put_observed_head!(issue_id, "sha-head", "IN_PROGRESS")

    assert held_after_release?(merging_ci_hold_state(issue_id, "sha-head", DateTime.add(DateTime.utc_now(), -59, :second)), issue)

    state = merging_ci_hold_state(issue_id, "sha-head", DateTime.add(DateTime.utc_now(), -61, :second))
    released = Orchestrator.release_merging_ci_waits_for_test(state, [issue])

    assert released.merging_ci_waits == %{}
    assert Orchestrator.should_dispatch_issue_for_test(issue, released)
  end

  defp merging_ci_hold_state(issue_id, commit_sha, since) do
    %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      budget_exhausted: MapSet.new(),
      max_concurrent_agents: 1,
      merging_ci_waits: %{
        issue_id => %{
          identifier: "MT-HOLD",
          title: "Land after CI",
          repo_key: "api",
          pull_request_url: "https://github.com/example/repo/pull/232",
          commit_sha: commit_sha,
          since: since
        }
      }
    }
  end

  defp held_after_release?(state, issue) do
    released = Orchestrator.release_merging_ci_waits_for_test(state, [issue])
    Map.has_key?(released.merging_ci_waits, issue.id) and not Orchestrator.should_dispatch_issue_for_test(issue, released)
  end

  defp put_observed_head!(issue_id, commit_sha, conclusion, landing_ready_sha \\ nil) do
    :ok =
      RunStore.put_ci_check(%{
        repo_key: "api",
        issue_id: issue_id,
        status: "watching",
        last_observed_sha: commit_sha,
        last_observed_conclusion: conclusion,
        landing_ready_sha: landing_ready_sha
      })

    on_exit(fn -> RunStore.delete_ci_check("api", issue_id) end)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      repo_key: "api",
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress", repo_key: "api"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", repo_key: "api", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 39_000, 40_500)
  end

  test "a worker that exits still waiting for Linear keeps its retry attempt and waits for Linear" do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    issue_id = "issue-linear-wait-exit"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :LinearWaitExitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      repo_key: "api",
      identifier: "MT-LINEAR-WAIT",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-LINEAR-WAIT", state: "Todo", repo_key: "api"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    reason = {:linear_unavailable, {:workpad_bootstrap_state_update_failed, {:linear_rate_limited, 1_791_000_030_000}}}
    send(pid, {:DOWN, ref, :process, self(), reason})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 2, due_at_ms: due_at_ms, delay_type: :linear_wait, error: error} = state.retry_attempts[issue_id]
    assert error == "agent exited: waiting for Linear: {:workpad_bootstrap_state_update_failed, {:linear_rate_limited, 1791000030000}}"
    assert_due_in_range(due_at_ms, 4_000, 5_500)
  end

  test "an epic review that exits waiting for CI keeps its retry attempt and starts again after a minute" do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    issue_id = "issue-ci-wait-exit"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CiWaitExitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      repo_key: "api",
      identifier: "MT-CI-WAIT",
      retry_attempt: 3,
      issue: %Issue{id: issue_id, identifier: "MT-CI-WAIT", state: "Epic Review", repo_key: "api"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    runs = [%{workflow_name: "macos", url: "https://github.com/acme/app/actions/runs/1"}, %{workflow_name: nil, url: nil}]
    reason = {:ci_pending, %{sha: "8f89fc0411dcf1f81aa82c0e1dc4cb07032a4793", runs: runs}}

    log =
      capture_log(fn ->
        send(pid, {:DOWN, ref, :process, self(), reason})
        Process.sleep(50)
      end)

    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, delay_type: :ci_wait, error: error} = state.retry_attempts[issue_id]
    assert error == "waiting for CI on 8f89fc0411dc: macos, a workflow still running"
    assert_due_in_range(due_at_ms, 59_000, 60_500)
    assert log =~ "is waiting for CI on 8f89fc0411dc: macos, a workflow still running; retrying after CI"
  end

  test "worker exception exits store concise retry errors" do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    issue_id = "issue-exception-summary"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ExceptionSummaryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      repo_key: "api",
      identifier: "MT-EXCEPTION",
      issue: %Issue{id: issue_id, identifier: "MT-EXCEPTION", state: "In Progress", repo_key: "api"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    message = "Agent run failed: {:codex_stdio_write_failed, \"\e[31mERROR\e[0m\"}"
    reason = {%RuntimeError{message: message}, [{SymphonyElixir.AgentRunner, :run, 3, []}]}

    send(pid, {:DOWN, ref, :process, self(), reason})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{error: error} = state.retry_attempts[issue_id]
    assert error == "agent exited: Agent run failed: {:codex_stdio_write_failed, \"ERROR\"}"
  end

  test "first abnormal worker exit waits before retrying" do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp wait_for_orchestrator_state(pid, predicate, timeout_ms \\ 500)
       when is_pid(pid) and is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
  end

  defp do_wait_for_orchestrator_state(pid, predicate, deadline_ms) do
    state = :sys.get_state(pid)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("timed out waiting for orchestrator state: #{inspect(state)}")

      true ->
        Process.sleep(5)
        do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
