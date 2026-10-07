defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Mix.Tasks.Symphony.Audit
  alias SymphonyElixir.AcceptanceGate
  alias SymphonyElixir.AcceptanceGate.Runner, as: GateRunner
  alias SymphonyElixir.{AuditLog, StrayProcesses}
  alias SymphonyElixir.Linear.{Adapter, Client, Usage}
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixirWeb.ObservabilityPubSub

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_candidate_issues_for_repo(repo) do
      send(self(), {:fetch_candidate_issues_for_repo_called, repo})
      {:ok, [repo]}
    end

    def fetch_issue_by_identifier(identifier) do
      send(self(), {:fetch_issue_by_identifier_called, identifier})
      {:ok, %SymphonyElixir.Linear.Issue{id: "issue-1", identifier: identifier}}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def fetch_issue_enrichment(issue) do
      send(self(), {:fetch_issue_enrichment_called, issue})
      {:ok, %{issue | comments: [%{author: "Reviewer", body: "Existing context", created_at: ~U[2026-05-05 01:00:00Z]}]}}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule ConflictGateContext do
    def build(_issue, _record, _sha, _settings, _opts), do: {:conflict, ["README.md"]}
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      if owner = Keyword.get(state, :owner), do: send(owner, :request_refresh_called)

      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  defmodule BlockingSnapshotOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def block_next_snapshot(pid), do: GenServer.call(pid, :block_next_snapshot)

    def release_snapshot(pid) when is_pid(pid) do
      send(pid, :release_snapshot)
      :ok
    end

    def init(opts) do
      {:ok,
       %{
         owner: Keyword.fetch!(opts, :owner),
         snapshot: Keyword.fetch!(opts, :snapshot),
         block_next_snapshot?: false
       }}
    end

    def handle_call(:block_next_snapshot, _from, state) do
      {:reply, :ok, %{state | block_next_snapshot?: true}}
    end

    def handle_call(:snapshot, _from, %{block_next_snapshot?: true} = state) do
      send(state.owner, :snapshot_blocked)

      receive do
        :release_snapshot -> :ok
      after
        1_000 -> :ok
      end

      {:reply, state.snapshot, %{state | block_next_snapshot?: false}}
    end

    def handle_call(:snapshot, _from, state) do
      {:reply, state.snapshot, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = terminate_workflow_store()
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert :ok = restart_workflow_store()
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = terminate_workflow_store()

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"

    Process.exit(manual_pid, :normal)

    restart_result =
      case workflow_store_supervisor() do
        nil -> WorkflowStore.start_link()
        supervisor -> Supervisor.restart_child(supervisor, workflow_store_child_id())
      end

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, ^issue} = SymphonyElixir.Tracker.fetch_issue_by_identifier("MT-1")
    assert {:error, :issue_not_found} = SymphonyElixir.Tracker.fetch_issue_by_identifier("MT-404")
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert {:ok, ^issue} = SymphonyElixir.Tracker.enrich_issue(issue)
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "memory tracker repo fetch ignores unrouted issues" do
    routed_issue = %Issue{
      id: "issue-routed",
      identifier: "ACME-ROUTED",
      state: "Todo",
      team: %{key: "ACME"},
      labels: ["web"]
    }

    unrouted_issue = %Issue{id: "issue-unrouted", identifier: "ACME-UNROUTED", state: "Todo"}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [routed_issue, unrouted_issue])

    assert {:ok, [^routed_issue]} =
             Memory.fetch_candidate_issues_for_repo(%{name: "web", team: "ACME", labels: ["web"]})
  end

  test "memory tracker reads its issues from issues_file when none are set" do
    Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    symphony_dir = Path.dirname(Workflow.symphony_file_path())
    issues_file = Path.join(symphony_dir, "issues.json")

    File.write!(
      issues_file,
      Jason.encode!([
        %{
          "id" => "issue-file-1",
          "identifier" => "E2E-1",
          "state" => "Todo",
          "title" => "Stub run",
          "description" => "From the file",
          "labels" => ["e2e", 7]
        },
        %{"id" => "issue-file-2", "identifier" => "E2E-2", "state" => "Done"},
        %{"id" => "missing-state", "identifier" => "E2E-3"},
        "not an issue"
      ])
    )

    # Relative to the folder holding symphony.yml.
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_memory_issues_file: "issues.json")
    assert Config.settings!().tracker.memory_issues_file == issues_file

    assert {:ok, [first, second]} = Memory.fetch_candidate_issues()

    assert %Issue{
             id: "issue-file-1",
             identifier: "E2E-1",
             state: "Todo",
             title: "Stub run",
             description: "From the file",
             labels: ["e2e"]
           } = first

    assert %Issue{id: "issue-file-2", identifier: "E2E-2", state: "Done", title: nil, labels: []} = second

    # Read on every fetch, so a test can change the issues while Symphony runs.
    File.write!(issues_file, Jason.encode!([%{"id" => "issue-file-1", "identifier" => "E2E-1", "state" => "Done"}]))
    assert {:ok, [%Issue{state: "Done"}]} = Memory.fetch_issues_by_states(["Done"])

    log =
      capture_log(fn ->
        File.write!(issues_file, ~s({"id": "not-a-list"}))
        assert {:ok, []} = Memory.fetch_candidate_issues()
        File.rm!(issues_file)
        assert {:ok, []} = Memory.fetch_candidate_issues()
      end)

    assert log =~ "Memory tracker could not read issues_file=#{issues_file}"
    assert log =~ ":enoent"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert {:ok, []} = Memory.fetch_candidate_issues()

    File.write!(Workflow.symphony_file_path(), "issues: [\n")
    Cache.clear()
    assert {:ok, []} = Memory.fetch_candidate_issues()
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    repo = %{name: "web", team: "ACME"}
    assert {:ok, [^repo]} = Adapter.fetch_candidate_issues_for_repo(repo)
    assert_receive {:fetch_candidate_issues_for_repo_called, ^repo}

    assert {:ok, %Issue{identifier: "ACME-1"}} = Adapter.fetch_issue_by_identifier("ACME-1")
    assert_receive {:fetch_issue_by_identifier_called, "ACME-1"}

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    issue = %Issue{id: "issue-1", identifier: "MT-1"}
    assert {:ok, enriched_issue} = Adapter.enrich_issue(issue)
    assert enriched_issue.comments == [%{author: "Reviewer", body: "Existing context", created_at: ~U[2026-05-05 01:00:00Z]}]
    assert_receive {:fetch_issue_enrichment_called, ^issue}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api shows a run waiting on Linear" do
    wait_until = ~U[2026-10-04 12:30:00Z]
    snapshot = update_in(static_snapshot().running, fn [running] -> [Map.put(running, :linear_wait_until, wait_until)] end)
    orchestrator_name = Module.concat(__MODULE__, :LinearWaitApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"running" => [%{"last_message" => "waiting for Linear", "linear_wait_until" => "2026-10-04T12:30:00Z"}]} =
             json_response(get(build_conn(), "/api/v1/state"), 200)

    assert %{"running" => %{"last_message" => "waiting for Linear", "linear_wait_until" => "2026-10-04T12:30:00Z"}} =
             json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
  end

  test "phoenix observability api shows a run waiting on a Symphony tool call" do
    pending_tool = %{name: "github_sync_base", started_at: ~U[2026-10-04 12:30:00.123Z], age_ms: 125_000}
    snapshot = update_in(static_snapshot().running, fn [running] -> [Map.put(running, :pending_tool, pending_tool)] end)
    orchestrator_name = Module.concat(__MODULE__, :PendingToolApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)
    expected = %{"name" => "github_sync_base", "started_at" => "2026-10-04T12:30:00Z", "age_ms" => 125_000}

    assert %{"running" => [%{"last_message" => "waiting on github_sync_base for 2m", "pending_tool" => ^expected}]} =
             json_response(get(build_conn(), "/api/v1/state"), 200)

    assert %{"running" => %{"last_message" => "waiting on github_sync_base for 2m", "pending_tool" => ^expected}} =
             json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    put_build(sha: "D3D301B0123456789ABCDEF0123456789ABCDEF0", repo: "https://github.com/acme/symphony", number: "168")
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    :ok =
      RunStore.put_run(%{
        repo_key: "default",
        run_id: "gate-MT-WATCH",
        kind: "acceptance_gate",
        issue_id: "issue-watch",
        issue_identifier: "MT-WATCH",
        pr_url: "https://github.com/example/repo/pull/123",
        head_sha: "abc1234def",
        mode: "shadow",
        verdict: "escalate",
        agent_verdict: "approve",
        reasons: [%{rule: "size", detail: "1600 changed lines outside docs and tests"}],
        criteria: %{met: 2, unmet: 0, unclear: 1},
        tokens: %{total_tokens: 5_000},
        started_at: ~U[2026-10-03 05:50:00Z],
        judged_at: ~U[2026-10-03 06:00:00Z]
      })

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)
    assert is_integer(state_payload["uptime_seconds"]) and state_payload["uptime_seconds"] >= 0

    gate_verdict = %{
      "repo_key" => "default",
      "issue_id" => "issue-watch",
      "issue_identifier" => "MT-WATCH",
      "pr_url" => "https://github.com/example/repo/pull/123",
      "head_sha" => "abc1234def",
      "mode" => "shadow",
      "verdict" => "escalate",
      "agent_verdict" => "approve",
      "reasons" => [%{"rule" => "size", "detail" => "1600 changed lines outside docs and tests"}],
      "criteria" => %{"met" => 2, "unmet" => 0, "unclear" => 1},
      "judged_at" => "2026-10-03T06:00:00Z",
      "run_id" => "gate-MT-WATCH",
      "human_decision" => nil,
      "human_decided_at" => nil
    }

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "build" => %{"version" => "0.0.1.168", "sha" => "d3d301b0123456789abcdef0123456789abcdef0"},
             "uptime_seconds" => state_payload["uptime_seconds"],
             "repos" => ["default"],
             "counts" => %{"running" => 1, "watching" => 1, "human_review" => 0, "conflicts" => 0, "retrying" => 1, "claimed" => 2, "forced" => 2},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "repo_key" => "default",
                 "issue_identifier" => "MT-HTTP",
                 "title" => nil,
                 "state" => "In Progress",
                 "url" => "https://linear.app/example/issue/MT-HTTP",
                 "run_kind" => nil,
                 "run_profile" => nil,
                 "reviewer_profile" => nil,
                 "pull_request_url" => nil,
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "transcript_path" => nil,
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "linear_wait_until" => nil,
                 "pending_tool" => nil,
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "forced" => false,
                 "tokens" => %{
                   "input_tokens" => 4,
                   "uncached_input_tokens" => 4,
                   "cached_input_tokens" => 0,
                   "cache_creation_input_tokens" => 0,
                   "output_tokens" => 8,
                   "total_tokens" => 12
                 }
               }
             ],
             "watching" => [
               %{
                 "issue_id" => "issue-watch",
                 "repo_key" => "default",
                 "issue_identifier" => "MT-WATCH",
                 "title" => nil,
                 "state" => "In Review",
                 "url" => "https://linear.app/example/issue/MT-WATCH",
                 "pull_request_url" => "https://github.com/example/repo/pull/123",
                 "last_ran_at" => state_payload["watching"] |> List.first() |> Map.fetch!("last_ran_at"),
                 "seconds_since_last_run" => 3_600
               }
             ],
             "human_review" => [],
             "conflicts" => [],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "repo_key" => "default",
                 "issue_identifier" => "MT-RETRY",
                 "title" => nil,
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "forced" => false
               }
             ],
             "awaiting_clarification" => [],
             "skipped" => [],
             "run_history" => [
               %{
                 "run_id" => "run-http",
                 "kind" => "agent",
                 "run_kind" => nil,
                 "model" => nil,
                 "effort" => nil,
                 "profile_label" => nil,
                 "reviewer_profile" => nil,
                 "repo_key" => "default",
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "title" => "HTTP snapshot",
                 "state" => "In Progress",
                 "status" => "success",
                 "attempt" => 1,
                 "started_at" => state_payload["run_history"] |> List.first() |> Map.fetch!("started_at"),
                 "ended_at" => state_payload["run_history"] |> List.first() |> Map.fetch!("ended_at"),
                 "error" => nil,
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "transcript_path" => nil,
                 "turn_count" => 7,
                 "runtime_seconds" => 42,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "uncached_input_tokens" => 4,
               "cached_input_tokens" => 0,
               "cache_creation_input_tokens" => 0,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "pause" => %{
               "paused" => false,
               "reason" => nil,
               "paused_at" => nil
             },
             "usage_limits" => [],
             "stray_processes" => [],
             "budget" => %{
               "per_issue_limit" => 500,
               "daily_limit" => 1_000,
               "daily_used" => 400,
               "daily_remaining" => 600,
               "daily_paused" => false
             },
             "dispatch_state" => %{
               "active?" => true,
               "blockers" => []
             },
             "pollers" => %{
               "ci" => "unavailable",
               "pr_review" => "unavailable"
             },
             "epic_lanes" => %{
               "max_total" => 2,
               "lanes" => [
                 %{
                   "issue_id" => "epic-http",
                   "identifier" => "MT-EPIC",
                   "title" => "Epic",
                   "url" => "https://linear.test/MT-EPIC",
                   "status" => "waiting",
                   "sub_issue" => %{"issue_id" => "part-http", "identifier" => "MT-PART", "state" => "In Review"}
                 }
               ],
               "queued_epics" => [],
               "shared" => %{"slots" => 1, "used" => 1}
             },
             "finishing" => %{
               "slots" => 2,
               "used" => 1,
               "running" => [%{"issue_id" => "land-http", "identifier" => "MT-LAND", "state" => "Merging"}]
             },
             "qa" => %{
               "running" => [%{"issue_id" => "qa-forced-http", "identifier" => "MT-QA-F", "sha" => "abc1234def", "forced" => true}],
               "queued" => [%{"issue_id" => "qa-queued-http", "identifier" => "MT-QA-Q", "forced" => false}]
             },
             "acceptance_gate" => %{
               "running" => [],
               "queued" => [],
               "recent" => [gate_verdict],
               "agreement" => %{
                 "default" => %{
                   "judged" => 0,
                   "agreed" => 0,
                   "agreement_rate" => nil,
                   "unsafe_approvals" => 0,
                   "false_reworks" => 0,
                   "escalations" => 0,
                   "escalations_merged_unchanged" => 0,
                   "tokens" => %{"median" => nil, "p90" => nil},
                   "ready_to_enforce" => false,
                   "unmet_condition" => "at least 20 judged tickets (0 so far)"
                 }
               }
             },
             "auto_merge" => [
               %{
                 "issue_id" => "merge-http",
                 "issue_identifier" => "MT-MERGE",
                 "pull_request_url" => "https://github.com/acme/repo/pull/9",
                 "state" => "enabled",
                 "head_sha" => "abc1234def",
                 "status" => "auto-merge on, waiting for CI on `abc1234`",
                 "updated_at" => "2026-10-03T06:00:00Z"
               }
             ],
             "slot_waiting" => [
               %{
                 "issue_id" => "wait-http",
                 "issue_identifier" => "MT-WAIT",
                 "title" => "Waiting",
                 "state" => "Todo",
                 "reason" => "a Merging or Auto Review issue is waiting for a slot",
                 "attempt" => nil,
                 "since" => "2026-10-03T06:00:00Z",
                 "forced" => false
               }
             ],
             "blocked" => [
               %{
                 "issue_id" => "verify-http",
                 "issue_identifier" => "MT-VERIFY",
                 "title" => "Final verification: Export",
                 "state" => "Todo",
                 "kind" => "blockers",
                 "reason" => nil,
                 "blocked_by" => [
                   %{"issue_identifier" => "MT-GAP", "state" => "In Progress"},
                   %{"issue_identifier" => nil, "state" => nil}
                 ],
                 "summary" => "MT-VERIFY waiting on MT-GAP (In Progress), an unknown issue (unknown state)"
               },
               %{
                 "issue_id" => "update-http",
                 "issue_identifier" => "MT-UPDATE",
                 "title" => "Final verification: Pause",
                 "state" => "Todo",
                 "kind" => "app_update",
                 "reason" => "waiting for an app update: MT-FIX merged in `9f54098`, running `d3d301b`",
                 "blocked_by" => [%{"issue_identifier" => "MT-FIX", "state" => "merged in 9f54098"}],
                 "summary" => "MT-UPDATE waiting for an app update: MT-FIX merged in `9f54098`, running `d3d301b`"
               }
             ],
             "app_update" => %{"unblocks" => 1, "issue_identifiers" => ["MT-UPDATE"]},
             "forced" => [
               %{
                 "issue_id" => "forced-http",
                 "issue_identifier" => "MT-FORCED",
                 "title" => "Fix the release",
                 "state" => "In Review",
                 "forced_since" => "2026-10-03T05:00:00Z",
                 "forced_for_seconds" => 3_600,
                 "stale" => false,
                 "position" => 1,
                 "waiting_on_human" => true,
                 "sub_issue" => nil,
                 "phase" => "waiting_for_human",
                 "running" => false,
                 "waiting_on" => "human",
                 "blockers" => [],
                 "summary" => "waiting for a human"
               },
               %{
                 "issue_id" => "forced-parent-http",
                 "issue_identifier" => "MT-EPIC",
                 "title" => "Export",
                 "state" => "Waiting on sub-tickets",
                 "forced_since" => "2026-10-03T06:00:00Z",
                 "forced_for_seconds" => 300_000,
                 "stale" => true,
                 "position" => 2,
                 "waiting_on_human" => false,
                 "sub_issue" => %{"issue_id" => "part-http", "issue_identifier" => "MT-PART", "state" => "Todo"},
                 "phase" => "implementation",
                 "running" => false,
                 "waiting_on" => "blocker",
                 "blockers" => ["MT-GAP"],
                 "summary" => "implementation · waiting on blocker MT-GAP"
               }
             ],
             "concurrency" => %{"max_total" => 10, "finishing_max" => 2, "forced_max" => 1},
             "claimed" => ["issue-http", "retry-http"],
             "rate_limits" => %{"primary" => %{"remaining" => 11}},
             "linear_usage" => %{"window_ms" => 3_600_000, "total" => 0, "callers" => [], "queries" => []},
             "orchestrator" => %{
               "message_queue_len" => 0,
               "snapshot_age_ms" => nil,
               "snapshot_build_ms" => nil,
               "snapshot_parts_ms" => %{}
             }
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "repo_key" => "default",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "repo_key" => "default",
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "transcript_path" => nil,
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "linear_wait_until" => nil,
               "pending_tool" => nil,
               "last_event_at" => nil,
               "tokens" => %{
                 "input_tokens" => 4,
                 "uncached_input_tokens" => 4,
                 "cached_input_tokens" => 0,
                 "cache_creation_input_tokens" => 0,
                 "output_tokens" => 8,
                 "total_tokens" => 12
               }
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "acceptance_gate" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-WATCH")
    watching_payload = json_response(conn, 200)

    assert watching_payload == %{
             "issue_identifier" => "MT-WATCH",
             "repo_key" => "default",
             "issue_id" => "issue-watch",
             "status" => "watching",
             "workspace" => nil,
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => nil,
             "retry" => nil,
             "watching" => %{
               "repo_key" => "default",
               "state" => "In Review",
               "url" => "https://linear.app/example/issue/MT-WATCH",
               "pull_request_url" => "https://github.com/example/repo/pull/123",
               "last_ran_at" => state_payload["watching"] |> List.first() |> Map.fetch!("last_ran_at"),
               "seconds_since_last_run" => 3_600
             },
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "acceptance_gate" => gate_verdict,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1:4000")
      |> post("/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api returns transcript JSON for running and retrying issues" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-transcript-api-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)

    on_exit(fn ->
      File.rm_rf(test_root)
    end)

    running_transcript_path = Path.join(test_root, "running-transcript.jsonl")

    File.write!(running_transcript_path, """
    {"event":"session_started","payload":{"session_id":"thread-http"}}
    {"event":"notification","payload":{"params":{"delta":"from file"}}}
    """)

    buffered_event = %{
      event: :notification,
      payload: %{"params" => %{"delta" => "from buffer"}},
      timestamp: DateTime.utc_now()
    }

    retry_event = %{
      event: :turn_ended_with_error,
      reason: "agent exited: port_exit 1",
      timestamp: DateTime.utc_now()
    }

    snapshot =
      static_snapshot()
      |> update_in([:running], fn [running] ->
        [
          running
          |> Map.put(:transcript_path, running_transcript_path)
          |> Map.put(:transcript_buffer, [buffered_event]),
          running
          |> Map.put(:repo_key, "other")
          |> Map.put(:issue_id, "issue-other-retry")
          |> Map.put(:identifier, "MT-RETRY")
          |> Map.put(:session_id, "thread-other")
          |> Map.put(:transcript_buffer, [])
        ]
      end)
      |> update_in([:retrying], fn [retry] ->
        [
          retry
          |> Map.put(:session_id, "thread-retry")
          |> Map.put(:transcript_buffer, [retry_event])
        ]
      end)

    orchestrator_name = Module.concat(__MODULE__, :TranscriptApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    running_payload =
      build_conn()
      |> get("/api/v1/repos/default/issues/MT-HTTP/transcript")
      |> json_response(200)

    assert running_payload["issue_identifier"] == "MT-HTTP"
    assert running_payload["session_id"] == "thread-http"
    assert Enum.map(running_payload["events"], & &1["event"]) == ["session_started", "notification", "notification"]
    assert List.last(running_payload["events"])["payload"]["params"]["delta"] == "from buffer"

    retry_payload =
      build_conn()
      |> get("/api/v1/issues/MT-RETRY/transcript")
      |> json_response(200)

    assert retry_payload["issue_identifier"] == "MT-RETRY"
    assert retry_payload["state"] == "retrying"
    assert [%{"event" => "turn_ended_with_error"}] = retry_payload["events"]

    assert json_response(get(build_conn(), "/api/v1/repos/default/issues/MT-MISSING/transcript"), 404) == %{
             "error" => %{"code" => "transcript_not_found", "message" => "Transcript not found"}
           }
  end

  test "phoenix observability api rejects cross-origin refresh before orchestration" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :CrossOriginRefreshOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        owner: self(),
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    missing_origin_conn = post(build_conn(), "/api/v1/refresh", %{})

    assert json_response(missing_origin_conn, 403) == %{
             "error" => %{"code" => "forbidden_origin", "message" => "Origin is not allowed"}
           }

    refute_received :request_refresh_called

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "https://evil.example")
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> post("/api/v1/refresh", "")

    assert json_response(conn, 403) == %{
             "error" => %{"code" => "forbidden_origin", "message" => "Origin is not allowed"}
           }

    refute_received :request_refresh_called

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state_payload["counts"] == %{"running" => 1, "watching" => 1, "human_review" => 0, "conflicts" => 0, "retrying" => 1, "claimed" => 2, "forced" => 2}
  end

  test "phoenix observability api allows configured origins to refresh" do
    allowed_origins = System.get_env("SYMPHONY_DASHBOARD_ALLOWED_ORIGINS")

    on_exit(fn ->
      case allowed_origins do
        nil -> System.delete_env("SYMPHONY_DASHBOARD_ALLOWED_ORIGINS")
        value -> System.put_env("SYMPHONY_DASHBOARD_ALLOWED_ORIGINS", value)
      end
    end)

    System.put_env("SYMPHONY_DASHBOARD_ALLOWED_ORIGINS", "https://dashboard.internal")

    orchestrator_name = Module.concat(__MODULE__, :AllowedOriginRefreshOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        owner: self(),
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "https://dashboard.internal")
      |> post("/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll"]} =
             json_response(conn, 202)

    assert_received :request_refresh_called
  end

  test "phoenix observability api exposes filtered quality runs and session reports" do
    now = DateTime.utc_now()
    yesterday = DateTime.add(now, -1, :day)

    assert :ok =
             RunStore.put_eval_log(%{
               repo_key: "default",
               eval_id: "eval-api-1",
               run_id: "run-api-1",
               issue_id: "issue-api-1",
               issue_identifier: "ACME-API-1",
               issue_labels: ["bug"],
               outcome: "pr_opened",
               status: "success",
               agent_kind: "codex",
               tokens: %{input_tokens: 20, output_tokens: 10, total_tokens: 30},
               duration_seconds: 45,
               tests_run: true,
               workspace_path: "/tmp/workspaces/ACME-API-1",
               session_id: "session-api-1",
               logged_at: now,
               date: DateTime.to_date(now)
             })

    assert :ok =
             RunStore.put_eval_log(%{
               repo_key: "default",
               eval_id: "eval-api-2",
               run_id: "run-api-2",
               issue_id: "issue-api-2",
               issue_identifier: "ACME-API-2",
               issue_labels: ["feature"],
               outcome: "error",
               status: "failure",
               error: "boom",
               agent_kind: "claude",
               tokens: %{input_tokens: 5, output_tokens: 5, total_tokens: 10},
               duration_seconds: 5,
               tests_run: false,
               session_id: "session-api-2",
               logged_at: yesterday,
               date: DateTime.to_date(yesterday)
             })

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :QualityApiOrchestrator), snapshot_timeout_ms: 5)

    payload =
      build_conn()
      |> get("/api/v1/runs?outcome=pr_opened&agent=codex&date_from=#{Date.to_iso8601(DateTime.to_date(now))}")
      |> json_response(200)

    assert payload["count"] == 1
    assert [%{"issue_identifier" => "ACME-API-1", "outcome" => "pr_opened", "agent_kind" => "codex"}] = payload["runs"]

    export_conn = get(build_conn(), "/api/v1/runs?export=json")

    assert Plug.Conn.get_resp_header(export_conn, "content-disposition") == [
             ~s(attachment; filename="symphony-quality-runs.json")
           ]

    assert json_response(export_conn, 200)["count"] == 2

    report =
      build_conn()
      |> get("/api/v1/runs/session-api-1/report")
      |> json_response(200)

    assert report["session_id"] == "session-api-1"
    assert report["metrics"]["pr_opened_rate"] == 1.0
    assert [%{"run_id" => "run-api-1"}] = report["runs"]
  end

  test "audit api streams filtered NDJSON and paginates by cursor" do
    audit_dir = use_audit_dir!()

    for sequence <- 1..30 do
      assert :ok =
               AuditLog.record(
                 %{
                   repo_key: "default",
                   issue_id: "issue-audit",
                   issue_identifier: "ACME-AUDIT",
                   run_id: "run-audit",
                   timestamp: ~U[2026-05-07 12:00:00Z],
                   event_type: "tool_call",
                   sequence: sequence
                 },
                 dir: audit_dir
               )
    end

    assert :ok =
             AuditLog.record(
               %{
                 repo_key: "default",
                 issue_id: "issue-other",
                 issue_identifier: "ACME-OTHER",
                 timestamp: ~U[2026-05-07 12:00:00Z],
                 event_type: "file_change"
               },
               dir: audit_dir
             )

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :AuditApiOrchestrator), snapshot_timeout_ms: 5)

    conn = get(build_conn(), "/api/v1/audit?issue=ACME-AUDIT&type=tool_call&from=2026-05-07&to=2026-05-07&limit=25")
    lines = conn.resp_body |> String.split("\n", trim: true)

    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/x-ndjson; charset=utf-8"]
    assert length(lines) == 25
    assert [%{"issue_identifier" => "ACME-AUDIT", "sequence" => 1} | _] = Enum.map(lines, &Jason.decode!/1)
    assert [cursor] = Plug.Conn.get_resp_header(conn, "x-next-cursor")

    next_conn =
      get(
        build_conn(),
        "/api/v1/audit?issue=ACME-AUDIT&type=tool_call&from=2026-05-07&to=2026-05-07&cursor=#{URI.encode_www_form(cursor)}"
      )

    assert next_conn.resp_body |> String.split("\n", trim: true) |> length() == 5

    last_page_conn = get(build_conn(), "/api/v1/audit?issue=ACME-AUDIT&from=2026-05-07&to=2026-05-07&limit=40")
    assert Plug.Conn.get_resp_header(last_page_conn, "x-next-cursor") == []

    invalid_limit_conn = get(build_conn(), "/api/v1/audit?issue=ACME-AUDIT&from=2026-05-07&to=2026-05-07&limit=bad")
    assert json_response(invalid_limit_conn, 400)["error"]["code"] == "invalid_audit_filter"
  end

  test "audit api export matches mix symphony.audit output for the same filters" do
    audit_dir = use_audit_dir!()
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(previous_shell) end)

    assert :ok =
             AuditLog.record(
               %{
                 repo_key: "default",
                 issue_id: "issue-cli",
                 issue_identifier: "ACME-CLI",
                 run_id: "run-cli",
                 timestamp: ~U[2026-05-07 12:00:00Z],
                 event_type: "tool_call"
               },
               dir: audit_dir
             )

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :AuditExportOrchestrator), snapshot_timeout_ms: 5)

    download_conn = get(build_conn(), "/api/v1/audit?issue=issue-cli&from=2026-05-07&to=2026-05-07&download=1")

    assert Plug.Conn.get_resp_header(download_conn, "content-disposition") ==
             [~s(attachment; filename="symphony-audit.ndjson")]

    no_download_conn = get(build_conn(), "/api/v1/audit?issue=issue-cli&from=2026-05-07&to=2026-05-07")
    assert Plug.Conn.get_resp_header(no_download_conn, "content-disposition") == []

    Audit.run(["issue-cli", "--from", "2026-05-07", "--to", "2026-05-07"])

    assert_receive {:mix_shell, :info, [cli_line]}
    assert download_conn.resp_body == cli_line <> "\n"
  end

  test "state api serves the terminal dashboard frame for symphony dashboard" do
    dashboard = Module.concat(__MODULE__, :TerminalFrameDashboard)
    start_supervised!({SymphonyElixir.StatusDashboard, name: dashboard, enabled: false})
    start_test_endpoint(status_dashboard: dashboard, snapshot_timeout_ms: 5)

    conn = get(build_conn(), "/api/v1/state?format=terminal&columns=140")
    assert response(conn, 200) =~ "SYMPHONY STATUS"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

    # A width that isn't a positive number falls back to the default width.
    assert response(get(build_conn(), "/api/v1/state?format=terminal&columns=wide"), 200) =~ "SYMPHONY STATUS"
    assert response(get(build_conn(), "/api/v1/state?format=terminal&columns[]=1"), 200) =~ "SYMPHONY STATUS"
    assert response(get(build_conn(), "/api/v1/state?format=terminal"), 200) =~ "SYMPHONY STATUS"
  end

  test "state api caps the terminal frame width" do
    dashboard = Module.concat(__MODULE__, :WidthEchoDashboard)

    echo_width = fn _snapshot, _tps, columns -> "columns=#{inspect(columns)}" end
    start_supervised!({SymphonyElixir.StatusDashboard, name: dashboard, enabled: false, format_fun: echo_width})

    start_test_endpoint(status_dashboard: dashboard, snapshot_timeout_ms: 5)

    assert response(get(build_conn(), "/api/v1/state?format=terminal&columns=1000000000"), 200) == "columns=1000"
    assert response(get(build_conn(), "/api/v1/state?format=terminal&columns=140"), 200) == "columns=140"
  end

  test "state api answers 503 for the terminal frame when rendering it fails" do
    dashboard = Module.concat(__MODULE__, :RaisingFrameDashboard)

    raise_bad = fn _snapshot, _tps, _columns -> raise ArgumentError, "bad snapshot" end
    pid = start_supervised!({SymphonyElixir.StatusDashboard, name: dashboard, enabled: false, format_fun: raise_bad})

    start_test_endpoint(status_dashboard: dashboard, snapshot_timeout_ms: 5)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert json_response(get(build_conn(), "/api/v1/state?format=terminal"), 503) ==
                 %{"error" => %{"code" => "dashboard_unavailable", "message" => "Terminal dashboard is unavailable"}}
      end)

    assert log =~ "Failed rendering status dashboard frame: bad snapshot"
    assert Process.alive?(pid)
    assert GenServer.whereis(dashboard) == pid
  end

  test "state api answers 503 for the terminal frame when no dashboard runs" do
    start_test_endpoint(status_dashboard: Module.concat(__MODULE__, :MissingDashboard), snapshot_timeout_ms: 5)

    assert json_response(get(build_conn(), "/api/v1/state?format=terminal"), 503) ==
             %{"error" => %{"code" => "dashboard_unavailable", "message" => "Terminal dashboard is unavailable"}}
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/runs", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/audit", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/repos/default/issues/MT-1/transcript", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    unavailable_refresh_conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1:4000")
      |> post("/api/v1/refresh", %{})

    assert json_response(unavailable_refresh_conn, 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    assert html =~ ~r|/dashboard\.css\?v=[a-f0-9]{16}|
    assert html =~ ~r|/vendor/phoenix_html/phoenix_html\.js\?v=[a-f0-9]{16}|
    assert html =~ ~r|/vendor/phoenix/phoenix\.js\?v=[a-f0-9]{16}|
    assert html =~ ~r|/vendor/phoenix_live_view/phoenix_live_view\.js\?v=[a-f0-9]{16}|
    assert html =~ ~s(phx-track-static)
    assert html =~ "installRestartAwareReconnect"
    assert html =~ "liveSocket.getSocket().connect()"
    refute html =~ "TranscriptFilter"
    refute html =~ "this.activeFilters = this.initialFilters()"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css_conn = get(build_conn(), "/dashboard.css")
    dashboard_css = response(dashboard_css_conn, 200)

    assert Plug.Conn.get_resp_header(dashboard_css_conn, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]

    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ "minmax(150px, 1fr)"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ ".transcript-list[data-filter-active=\"true\"] .transcript-event"

    for {filter, class} <- [
          {"agent-text", "agent-text"},
          {"tool-call", "tool-call"},
          {"tool-result", "tool-result"},
          {"session", "session"},
          {"error", "error"},
          {"event", "event"},
          {"reviewer", "reviewer"}
        ] do
      assert dashboard_css =~
               ".transcript-list[data-filter-#{filter}=\"true\"] .transcript-event-#{class}"
    end

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "the state api and the dashboard list tickets waiting in Human Review" do
    human_review = %{
      issue_id: "issue-human",
      repo_key: "default",
      identifier: "MT-HUMAN",
      state: "Human Review",
      url: "https://linear.app/example/issue/MT-HUMAN",
      last_ran_at: DateTime.add(DateTime.utc_now(), -60, :second),
      seconds_since_last_run: 60
    }

    snapshot = Map.update!(static_snapshot(), :watching, &(&1 ++ [human_review]))
    orchestrator_name = Module.concat(__MODULE__, :HumanReviewOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll"]}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert %{"watching" => 2, "human_review" => 1} = state_payload["counts"]
    assert [%{"issue_identifier" => "MT-HUMAN", "state" => "Human Review", "url" => "https://linear.app/example/issue/MT-HUMAN"}] = state_payload["human_review"]

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Human Review"
    assert html =~ "needs you"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "Dispatch active"
    assert html =~ "Pause All"
    assert html =~ ~s(class="secondary pause-dispatch-button")
    assert html =~ ~s(href="/quality")
    assert html =~ "MT-HTTP"
    assert html =~ "MT-WATCH"
    assert html =~ "MT-RETRY"
    assert_repo_chip(html, "default")
    assert html =~ "Conflict"
    assert html =~ "No repo conflicts"
    assert html =~ "https://linear.app/example/issue/MT-WATCH"
    assert html =~ "https://linear.app/example/issue/MT-HTTP"
    assert html =~ "https://github.com/example/repo/pull/123"
    assert html =~ ~s(href="https://linear.app/example/issue/MT-HTTP" target="_blank")
    assert html =~ ~s(href="https://linear.app/example/issue/MT-WATCH" target="_blank")
    assert html =~ ~s(href="https://github.com/example/repo/pull/123" target="_blank")
    refute html =~ "Linear ↗"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    refute html =~ "<th>Self-review</th>"
    assert Regex.scan(~r/<th>Links<\/th>/, html) |> length() == 2
    assert html =~ "<th>Control</th>"
    assert html =~ "Stop"
    assert html =~ ~s(<td class="links-cell">)
    assert html =~ ~s(<div class="link-actions">)
    assert html =~ "thread-h…"
    assert html =~ "Agent update"
    assert html =~ "Budget: 488 left"
    assert html =~ "/repos/default/issues/MT-HTTP/transcript"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"
    assert html =~ "Awaiting clarification"
    assert html =~ "No issues awaiting clarification"
    assert html =~ "Skipped (quality gate)"
    assert html =~ "No issues skipped this session"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          repo_key: "default",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    assert :ok = ObservabilityPubSub.broadcast_update("github.com/acme/other")

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview shows whether GitHub webhooks are active and where CI results came from" do
    ci_status = fn webhooks ->
      %{status: :running, consecutive_failures: 0, current_backoff_ms: nil, poll_interval_ms: 60_000}
      |> Map.put(:webhooks, webhooks)
    end

    active = %{
      enabled: true,
      relay: "smee",
      last_event_at: DateTime.add(DateTime.utc_now(), -90, :second),
      events_received: 12,
      rejected: 1,
      results_via_webhook: 3,
      results_via_poll: 2
    }

    cases = [
      {:WebhooksActiveOrchestrator, %{ci: ci_status.(active), pr_review: :unavailable}, ["Active through smee", "1m ago", "12 (1 rejected)", "3 via relay, 2 by polling"]},
      {:WebhooksQuietOrchestrator, %{ci: ci_status.(%{active | last_event_at: nil}), pr_review: :unavailable}, ["none yet"]},
      {:WebhooksOffOrchestrator, %{ci: ci_status.(%{active | enabled: false}), pr_review: :unavailable}, ["Off. CI results arrive by polling only."]},
      {:WebhooksNoPollerOrchestrator, %{ci: :unavailable, pr_review: :unavailable}, ["The CI poller is not running."]}
    ]

    for {name, pollers, expected} <- cases do
      orchestrator_name = Module.concat(__MODULE__, name)
      {:ok, pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: Map.put(static_snapshot(), :pollers, pollers))
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "GitHub webhooks"
      Enum.each(expected, &assert(html =~ &1))

      stop_supervised!(SymphonyElixirWeb.Endpoint)
      GenServer.stop(pid)
    end
  end

  test "dashboard liveview uses neutral agent update header for Claude config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      agent_command: "claude",
      agent_approval_policy: nil
    )

    orchestrator_name = Module.concat(__MODULE__, :ClaudeDashboardOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Agent update"
    refute html =~ "Claude update"
    refute html =~ "Codex update"
  end

  test "dashboard liveview shows the run kind, model and effort of running and recent runs" do
    orchestrator_name = Module.concat(__MODULE__, :RunProfileDashboardOrchestrator)
    snapshot = static_snapshot()
    [running] = snapshot.running
    [history] = snapshot.run_history

    snapshot = %{
      snapshot
      | running: [
          Map.merge(running, %{
            run_profile: %{kind: :implementation, model: "claude-opus-5-5", effort: "high"},
            reviewer_run_profile: %{kind: :pre_push_review, model: nil, effort: "medium"}
          })
        ],
        run_history: [
          Map.merge(history, %{
            run_id: "qa-run",
            issue_identifier: "MT-QA",
            kind: "qa",
            status: "qa_pass",
            run_kind: "qa",
            model: "claude-haiku-4-5",
            effort: "low"
          }),
          Map.merge(history, %{
            run_kind: "implementation",
            model: "claude-opus-5-5",
            effort: nil,
            reviewer_profile: %{run_kind: "pre_push_review", model: "claude-sonnet-5-5", effort: "medium"}
          }),
          Map.merge(history, %{run_id: "api-run", repo_key: "api", issue_identifier: "MT-API-RUN", tokens: nil})
        ]
    }

    {:ok, _orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "implementation · claude-opus-5-5 · high"
    assert html =~ "Reviewer: pre_push_review · default · medium"
    assert html =~ "Recent runs"
    assert html =~ "MT-QA"
    assert html =~ "claude-haiku-4-5 · low"
    assert html =~ "claude-opus-5-5 · default"
    assert html =~ "Reviewer: claude-sonnet-5-5 · medium"
    assert html =~ "MT-API-RUN"

    {:ok, _view, html} = live(build_conn(), "/?repo=default")

    assert html =~ "MT-QA"
    refute html =~ "MT-API-RUN"
  end

  test "dashboard liveview shows the acceptance gate's passes, verdicts and each repo's agreement" do
    orchestrator_name = Module.concat(__MODULE__, :AcceptanceGateDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Auto Review"
    assert html =~ "Acceptance gate: 0 running, 0 queued."
    assert html =~ "The acceptance gate has not judged a ticket yet."

    test_pid = self()

    run_fun = fn _job, _opts ->
      send(test_pid, {:gate_pass, self()})

      receive do
        :finish -> :ok
      end
    end

    start_supervised!({GateRunner, run_fun: run_fun})
    issue = %{id: "issue-gate", identifier: "MT-GATE"}
    gate_job = %{issue: issue, record: %{repo_key: "default", workspace_path: "/tmp/ws"}, sha: "abc1234", settings: Config.settings!()}
    assert :started = GateRunner.request(gate_job, [])
    assert_receive {:gate_pass, pass_pid}
    on_exit(fn -> send(pass_pid, :finish) end)

    gate_run = fn repo_key, identifier, verdict, attrs ->
      Map.merge(
        %{
          repo_key: repo_key,
          run_id: "gate-#{identifier}",
          kind: "acceptance_gate",
          issue_id: "issue-#{identifier}",
          issue_identifier: identifier,
          head_sha: "abc1234",
          mode: "shadow",
          verdict: verdict,
          agent_verdict: verdict,
          reasons: [],
          criteria: %{met: 1, unmet: 0, unclear: 0},
          tokens: %{total_tokens: 1_000},
          started_at: ~U[2026-10-03 05:00:00Z],
          judged_at: ~U[2026-10-03 05:00:00Z]
        },
        attrs
      )
    end

    decided = %{human_decision: "approve", human_decided_at: ~U[2026-10-03 07:00:00Z], unchanged: true}

    runs =
      [
        gate_run.("default", "MT-ESC", "escalate", %{
          agent_verdict: "approve",
          reasons: [%{rule: "size", detail: "1600 changed lines"}],
          criteria: %{met: 2, unmet: 0, unclear: 1},
          judged_at: ~U[2026-10-03 06:00:00Z]
        }),
        gate_run.("web", "MT-WEB", "approve", %{judged_at: ~U[2026-10-03 05:30:00Z]}),
        gate_run.("api", "MT-API", "rework", decided)
      ] ++ for(n <- 1..20, do: gate_run.("default", "MT-OK-#{n}", "approve", Map.put(decided, :judged_at, ~U[2026-10-03 05:00:00Z] |> DateTime.add(n))))

    Enum.each(runs, &(:ok = RunStore.put_run(&1)))

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Acceptance gate: 1 running (MT-GATE), 0 queued."
    assert html =~ "MT-ESC: escalate (agent: approve) · 2 met, 0 unmet, 1 unclear · reasons: size · shadow · human: waiting"
    assert html =~ "MT-WEB: approve · 1 met, 0 unmet, 0 unclear · shadow · human: waiting"
    assert html =~ "MT-OK-20: approve · 1 met, 0 unmet, 0 unclear · shadow · human: approve"

    assert html =~
             "default: 20 judged, 20 agreed (100%), 0 unsafe approvals, 0 false reworks, 0 escalations (0 merged unchanged), " <>
               "gate tokens median 1000, p90 1000 · ready to enforce"

    assert html =~
             "api: 1 judged, 0 agreed (0%), 0 unsafe approvals, 1 false reworks, 0 escalations (0 merged unchanged), " <>
               "gate tokens median 1000, p90 1000 · not ready to enforce: at least 20 judged tickets (1 so far)"

    assert html =~ "web: 0 judged, 0 agreed (n/a), 0 unsafe approvals, 0 false reworks, 0 escalations (0 merged unchanged), gate tokens median n/a, p90 n/a"
  end

  test "state api and dashboard list a gate run the acceptance gate stored among the recent runs" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    audit_dir = Path.join(System.tmp_dir!(), "gate-run-history-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(audit_dir) end)

    issue = %Issue{id: "issue-gate-run", identifier: "MT-GATE-RUN", title: "Gate run", description: "", state: "Auto Review", labels: []}
    record = %{repo_key: "default", issue_id: issue.id, pr_url: "https://github.com/example/repo/pull/7", workspace_path: "/tmp/ws"}
    job = %{issue: issue, record: record, sha: "abc1234def", settings: Config.settings!(), qa: %{verdict: :pass}}

    assert {:ok, %{verdict: "rework"}} = AcceptanceGate.judge(job, context: ConflictGateContext, dir: audit_dir)
    assert [gate_run] = RunStore.list_runs("default", :all)
    refute Map.has_key?(gate_run, :attempt)

    orchestrator_name = Module.concat(__MODULE__, :GateRunHistoryOrchestrator)
    snapshot = %{static_snapshot() | run_history: [gate_run]}
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    state_payload = build_conn() |> get("/api/v1/state") |> json_response(200)

    assert [%{"kind" => "acceptance_gate", "issue_identifier" => "MT-GATE-RUN", "status" => "gate_rework", "attempt" => nil}] =
             state_payload["run_history"]

    assert [%{"issue_identifier" => "MT-GATE-RUN", "verdict" => "rework"}] = state_payload["acceptance_gate"]["recent"]

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "MT-GATE-RUN: rework"
  end

  test "state api and dashboard show Linear requests per caller for the last hour" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "token")
    request_fun = fn _payload, _headers -> {:ok, %{status: 200, headers: %{}, body: %{"data" => %{}}}} end
    linear_call = fn -> {:ok, _body} = Client.graphql("query { viewer { id } }", %{}, request_fun: request_fun) end

    named_call = fn ->
      {:ok, _body} = Client.graphql("query SymphonyUsageApiProbe { viewer { id } }", %{}, request_fun: request_fun)
    end

    Usage.with_caller({:agent, "MT-USAGE-API"}, fn -> Enum.each(1..3, fn _ -> named_call.() end) end)
    Usage.with_caller(:ci_poller, linear_call)

    usage = Usage.snapshot()
    orchestrator_name = Module.concat(__MODULE__, :LinearUsageOrchestrator)
    snapshot = Map.put(static_snapshot(), :polling, %{linear: %{usage: usage}})
    {:ok, _orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"window_ms" => 3_600_000, "total" => total, "callers" => callers, "queries" => queries} =
             build_conn() |> get("/api/v1/state") |> json_response(200) |> Map.fetch!("linear_usage")

    assert total == usage.total and total >= 4
    assert %{"query" => "SymphonyUsageApiProbe", "requests" => 3} in queries
    assert Enum.any?(queries, &match?(%{"query" => "unnamed", "requests" => requests} when requests >= 1, &1))
    assert %{"caller" => "agent:MT-USAGE-API", "requests" => 3} in callers
    assert Enum.any?(callers, &match?(%{"caller" => "ci_poller", "requests" => requests} when requests >= 1, &1))

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Linear requests"
    assert html =~ "agent:MT-USAGE-API"
    refute html =~ "No Linear requests in the last hour."
  end

  test "dashboard liveview shows an empty Linear requests section" do
    orchestrator_name = Module.concat(__MODULE__, :NoLinearUsageOrchestrator)
    {:ok, _orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "No Linear requests in the last hour."
  end

  test "dashboard liveview shows an empty recent runs section" do
    orchestrator_name = Module.concat(__MODULE__, :NoRunsDashboardOrchestrator)
    snapshot = %{static_snapshot() | run_history: []}
    {:ok, _orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "No runs yet."
  end

  test "dashboard liveview narrows rows from repo query string" do
    orchestrator_name = Module.concat(__MODULE__, :FilteredDashboardOrchestrator)
    snapshot = multi_repo_snapshot()

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/?repo=api")

    assert html =~ ~s(<option value="api" selected)
    refute html =~ ~s(<option value="conflict")
    assert html =~ "MT-API"
    assert html =~ "MT-API-WATCH"
    assert html =~ "MT-CONFLICT"
    assert_repo_chip(html, "api")
    refute html =~ "MT-HTTP"
    refute html =~ "MT-WEB-RETRY"

    {:ok, _view, html} = live(build_conn(), "/?repo=conflict")

    assert html =~ ~s(<option value="" selected)
    refute html =~ ~s(<option value="conflict")
    assert html =~ "MT-API"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-CONFLICT"
    assert html =~ "MT-WEB-RETRY"
  end

  test "dashboard repo filter remains responsive while refresh snapshot is pending" do
    orchestrator_name = Module.concat(__MODULE__, :AsyncRepoFilterDashboardOrchestrator)

    {:ok, orchestrator_pid} =
      BlockingSnapshotOrchestrator.start_link(
        name: orchestrator_name,
        owner: self(),
        snapshot: multi_repo_snapshot()
      )

    on_exit(fn -> BlockingSnapshotOrchestrator.release_snapshot(orchestrator_pid) end)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000)

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "MT-API"
    assert html =~ "MT-HTTP"
    assert :ok = BlockingSnapshotOrchestrator.block_next_snapshot(orchestrator_pid)

    assert :ok = ObservabilityPubSub.broadcast_update("api")
    assert_receive :snapshot_blocked

    html = render_change(view, "filter-repo", %{"repo" => "api"})

    assert html =~ ~s(<option value="api" selected)
    assert html =~ "MT-API"
    assert html =~ "MT-API-WATCH"
    assert html =~ "MT-CONFLICT"
    assert html =~ "Updating..."
    refute html =~ "MT-HTTP"
    refute html =~ "MT-WEB-RETRY"

    :ok = BlockingSnapshotOrchestrator.release_snapshot(orchestrator_pid)

    html = render_async(view, 500)
    refute html =~ "Updating..."
  end

  test "dashboard liveview allows an actual repo named conflict" do
    orchestrator_name = Module.concat(__MODULE__, :ConflictRepoDashboardOrchestrator)

    snapshot =
      multi_repo_snapshot()
      |> Map.update!(:running, fn rows ->
        [
          %{
            issue_id: "issue-conflict-repo",
            repo_key: "conflict",
            identifier: "MT-CONFLICT-REPO",
            state: "In Progress",
            url: "https://linear.app/example/issue/MT-CONFLICT-REPO",
            session_id: "thread-conflict-repo",
            turn_count: 1,
            codex_app_server_pid: nil,
            last_codex_message: "conflict repo update",
            last_codex_timestamp: nil,
            last_codex_event: :notification,
            codex_input_tokens: 1,
            codex_output_tokens: 2,
            codex_total_tokens: 3,
            started_at: DateTime.utc_now()
          }
          | rows
        ]
      end)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/?repo=conflict")

    assert html =~ ~s(<option value="conflict" selected)
    assert html =~ "MT-CONFLICT-REPO"
    assert_repo_chip(html, "conflict")
    refute html =~ "MT-API"
    refute html =~ conflict_repo_chip_pattern("api")
  end

  test "observability state payload exposes conflict row data shape" do
    orchestrator_name = Module.concat(__MODULE__, :ConflictStateOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: multi_repo_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = get(build_conn(), "/api/v1/state") |> json_response(200)

    assert payload["repos"] == ["api", "default", "web"]

    assert [
             %{
               "issue_id" => "issue-conflict",
               "issue_identifier" => "MT-CONFLICT",
               "state" => "Conflict",
               "linear_state" => "Todo",
               "repo_keys" => ["api", "web"]
             }
           ] = payload["conflicts"]
  end

  test "dashboard liveview renders empty retry and quality gate sections" do
    orchestrator_name = Module.concat(__MODULE__, :EmptyQueuesDashboardOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:retrying, [])
      |> Map.put(:awaiting_clarification, [])
      |> Map.put(:skipped, [])

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Retry queue"
    assert html =~ "No queued retries"
    assert html =~ "Awaiting clarification"
    assert html =~ "No issues awaiting clarification"
    assert html =~ "Skipped (quality gate)"
    assert html =~ "No issues skipped this session"
  end

  test "dashboard liveview renders quality gate issue sections" do
    orchestrator_name = Module.concat(__MODULE__, :QualityGateSectionsDashboardOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:awaiting_clarification, [
        %{
          kind: :clarification,
          issue_id: "issue-await",
          repo_key: "api",
          identifier: "MT-AWAIT",
          url: "https://example.org/MT-AWAIT",
          score: 5,
          reason: "needs acceptance criteria",
          rounds_asked: 2,
          updated_at: ~U[2026-05-05 03:00:00Z]
        }
      ])
      |> Map.put(:skipped, [
        %{
          kind: :scored,
          issue_id: "issue-skip",
          repo_key: "web",
          identifier: "MT-SKIP",
          url: "https://example.org/MT-SKIP",
          score: 3,
          reason: "vague description",
          updated_at: ~U[2026-05-05 04:00:00Z]
        },
        %{
          kind: :error,
          issue_id: "issue-error",
          repo_key: "api",
          identifier: "MT-ERR",
          url: "https://example.org/MT-ERR",
          error: :llm_timeout,
          updated_at: ~U[2026-05-05 05:00:00Z]
        }
      ])

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "MT-AWAIT"
    assert_repo_chip(html, "api")
    assert html =~ "needs acceptance criteria"
    assert html =~ "https://example.org/MT-AWAIT"
    assert html =~ "2026-05-05T03:00:00Z"
    assert html =~ "MT-SKIP"
    assert_repo_chip(html, "web")
    assert html =~ "Scored"
    assert html =~ "vague description"
    assert html =~ "MT-ERR"
    assert html =~ "Error"
    assert html =~ ":llm_timeout"
  end

  test "dashboard liveview renders persisted pause reason and timestamp" do
    orchestrator_name = Module.concat(__MODULE__, :PausedDashboardOrchestrator)
    paused_at = ~U[2026-05-06 08:30:00Z]
    snapshot = Map.put(static_snapshot(), :pause, %{paused: true, reason: "deploy window", paused_at: paused_at})

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Dispatch paused"
    assert html =~ "deploy window"
    assert html =~ "2026-05-06T08:30:00Z"
    assert html =~ "Resume All"
  end

  test "dashboard liveview renders each epic lane and the shared pool" do
    orchestrator_name = Module.concat(__MODULE__, :EpicLanesDashboardOrchestrator)

    lanes = [
      lane("e1", "MT-E1", "running", %{issue_id: "p1", identifier: "MT-P1", state: "In Progress", via: nil}),
      lane("e2", "MT-E2", "waiting", %{issue_id: "p2", identifier: "MT-P2", state: "In Review"}),
      lane("e5", "MT-E5", "running", %{issue_id: "b5", identifier: "MT-B5", state: "In Progress", via: %{relation: "blocks", identifier: "MT-P5"}}),
      lane("e6", "MT-E6", "running", %{issue_id: "g6", identifier: "MT-G6", state: "Todo", via: %{relation: "sub_ticket_of", identifier: "MT-P6"}}),
      %{issue_id: "e3", identifier: "MT-E3", title: "Epic three", url: nil, status: "waiting", sub_issue: nil},
      %{
        issue_id: "e7",
        identifier: "MT-E7",
        title: "Epic seven",
        url: nil,
        status: "yielded",
        reason: "Nothing on its path can run: MT-P7 (In Review)",
        sub_issue: %{issue_id: "p7", identifier: "MT-P7", state: "In Review"}
      }
    ]

    snapshot =
      Map.put(static_snapshot(), :epic_lanes, %{
        max_total: 4,
        lanes: lanes,
        queued_epics: [%{issue_id: "e4", identifier: "MT-E4", title: "Epic four", url: nil}],
        shared: %{slots: 1, used: 1}
      })

    {:ok, _orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Agent lanes"
    assert html =~ "MT-P1 (In Progress)"
    refute html =~ "MT-P1 (In Progress),"
    assert html =~ "MT-B5 (In Progress), blocks MT-P5"
    assert html =~ "MT-G6 (Todo), sub-ticket of MT-P6"
    assert html =~ "Waiting on MT-P2 (In Review)"
    assert html =~ "Waiting for its next sub-ticket"
    assert html =~ "Idle, reserved"
    assert html =~ "Yielded"
    assert html =~ "Nothing on its path can run: MT-P7 (In Review)"
    assert html =~ "Waiting for a lane: MT-E4"
    refute html =~ "No active epics"

    assert html =~ "Finishing runs"
    assert html =~ "Landing: MT-LAND"
    assert html =~ "MT-MERGE: auto-merge on, waiting for CI on `abc1234`"
    assert html =~ "MT-WAIT"
    assert html =~ "a Merging or Auto Review issue is waiting for a slot"
    refute html =~ "Nothing is waiting to start."
    assert html =~ "Waiting on blockers"
    assert html =~ "MT-VERIFY waiting on MT-GAP (In Progress)"
    assert html =~ "MT-UPDATE waiting for an app update: MT-FIX merged in `9f54098`, running `d3d301b`"
  end

  test "dashboard liveview lists forced tickets above the running sessions and marks forced rows" do
    orchestrator_name = Module.concat(__MODULE__, :ForcedDashboardOrchestrator)
    mark_forced = fn rows -> Enum.map(rows, &Map.put(&1, :forced, true)) end

    snapshot =
      static_snapshot()
      |> Map.update!(:running, mark_forced)
      |> Map.update!(:retrying, mark_forced)
      |> Map.update!(:slot_waiting, mark_forced)

    {:ok, _orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert [_before, after_forced] = String.split(html, ~r/<h2 class="section-title">\s*Forced\s*<\/h2>/, parts: 2)
    assert [forced_section, _rest] = String.split(after_forced, "Running sessions", parts: 2)
    assert forced_section =~ "MT-FORCED"
    assert forced_section =~ "waiting for a human"
    assert forced_section =~ "1h 0m"
    assert forced_section =~ "now MT-PART (Todo)"
    assert forced_section =~ "blocker MT-GAP"
    assert forced_section =~ "3d 11h"
    assert forced_section =~ "Stale"
    assert html =~ ~r/<p class="metric-label">\s*Forced\s*<\/p>\s*<p class="metric-value numeric">\s*2\/1\s*<\/p>/
    # The forced section's two rows, and the forced running, retry and waiting-to-start rows.
    assert length(String.split(html, ~s(class="forced-marker"))) - 1 == 5
  end

  test "dashboard liveview leaves the forced section out with no forced tickets" do
    orchestrator_name = Module.concat(__MODULE__, :UnforcedDashboardOrchestrator)
    snapshot = Map.drop(static_snapshot(), [:forced, :concurrency])
    {:ok, _orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    refute html =~ ~r/<h2 class="section-title">\s*Forced\s*<\/h2>/
    refute html =~ "forced-marker"
    assert html =~ ~r/<p class="metric-label">\s*Forced\s*<\/p>\s*<p class="metric-value numeric">\s*0\/1\s*<\/p>/
  end

  test "dashboard liveview shows every slot as shared with no active epics" do
    empty_name = Module.concat(__MODULE__, :NoEpicLanesDashboardOrchestrator)
    snapshot = Map.drop(static_snapshot(), [:epic_lanes, :finishing, :slot_waiting, :blocked])
    {:ok, _pid} = StaticOrchestrator.start_link(name: empty_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: empty_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "No active epics; every slot is shared."
    refute html =~ "Waiting for a lane"
    assert html =~ "Nothing is waiting to start."
    refute html =~ "Waiting on blockers"
    refute html =~ "Landing:"
  end

  test "dashboard liveview renders operational dispatch_state blocker chips" do
    orchestrator_name = Module.concat(__MODULE__, :BlockerChipsDashboardOrchestrator)

    snapshot =
      Map.put(static_snapshot(), :dispatch_state, %{
        active?: false,
        blockers: [
          %{
            kind: :budget,
            used: 88_402_765,
            limit: 5_000_000,
            day_started_on: ~D[2026-05-08],
            resets_on: ~D[2026-05-09]
          },
          %{
            kind: :workspace_dirty,
            repo: "/Users/chihsuan/Projects/symphony",
            dirty_summary: "M WORKFLOW.md"
          },
          %{
            kind: :config_invalid,
            message: "Invalid WORKFLOW.md config: notifications.channels entries with kind: slack require webhook_url",
            since: ~U[2026-05-08 13:48:09Z],
            consecutive_failures: 3
          },
          %{
            kind: :tracker_unavailable,
            tracker: :linear,
            reason: :linear_api_request,
            since: ~U[2026-05-08 13:48:09Z],
            consecutive_failures: 3
          }
        ]
      })

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Dispatch paused"
    assert html =~ "Daily token budget exhausted"
    assert html =~ "88.4M / 5M"
    assert html =~ "resets 2026-05-09"
    assert html =~ "ops-control-blocker-budget"
    assert html =~ "Config invalid"
    assert html =~ "Invalid WORKFLOW.md config: notifications.channels entries with kind: slack require webhook_url"
    assert html =~ "ops-control-blocker-config_invalid"
    assert html =~ "Linear tracker unavailable"
    assert html =~ "Linear API request failed"
    assert html =~ "3 consecutive failures"
    assert html =~ "2026-05-08T13:48:09Z"
    assert html =~ "ops-control-blocker-tracker_unavailable"
    refute html =~ "Primary worktree has uncommitted changes"
    refute html =~ "ops-control-blocker-workspace_dirty"
  end

  test "dashboard liveview shows a usage-limit banner with today's time or another day's date" do
    orchestrator_name = Module.concat(__MODULE__, :UsageLimitDashboardOrchestrator)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    later = DateTime.add(now, 3 * 86_400)

    snapshot =
      static_snapshot()
      |> Map.put(:usage_limits, [
        usage_limit_entry(%{window: "five_hour", resume_at: now}),
        usage_limit_entry(%{scope: "opus", window: "seven_day_opus", resume_at: later}),
        usage_limit_entry(%{
          window: "seven_day",
          phase: :headroom,
          reason: "claude_usage_headroom",
          utilization: 0.92,
          resets_at: now,
          resume_at: now
        })
      ])
      |> Map.put(:dispatch_state, %{
        active?: false,
        blockers: [
          %{kind: :usage_limit, provider: "anthropic", scope: :all, window: "five_hour", resets_at: nil, resume_at: now, phase: :paused},
          %{kind: :usage_limit, provider: "anthropic", scope: :all, window: "seven_day", resets_at: now, resume_at: now, phase: :headroom}
        ]
      })

    {:ok, _orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "usage-limit-banner"
    assert html =~ ~r/Paused: Claude 5-hour limit, resumes ~\d{2}:\d{2}\s*</
    assert html =~ ~r/Paused: Claude weekly Opus limit, resumes ~[A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}\s*</
    assert html =~ "Dispatch paused"
    assert html =~ "Claude 5-hour limit reached"
    assert html =~ ~r/Holding new runs: Claude at 92%, resets ~\d{2}:\d{2}\s*</
    assert html =~ "Claude weekly limit headroom: holding new runs"
    assert html =~ "resumes at #{DateTime.to_iso8601(now)}"
    assert html =~ "ops-control-blocker-usage_limit"
  end

  test "dashboard liveview warns about stray processes until they are gone" do
    orchestrator_name = Module.concat(__MODULE__, :StrayProcessDashboardOrchestrator)
    stray_name = Module.concat(__MODULE__, :StrayProcesses)
    idle = Path.join([Path.expand(Config.settings!().workspace.root), "default", "MT-IDLE"])
    yes = %{pid: 4242, ppid: 1, start_time: "Sun Oct  4 08:00:00 2026", cpu_time: "10:01.00", command: "yes", cwd: idle}
    spin = %{yes | pid: 4243, cpu_time: "20:00.00", command: "#{idle}/bin/spin", cwd: nil}
    {:ok, table} = Agent.start_link(fn -> {:ok, [yes, spin]} end)

    start_supervised!(
      {StrayProcesses, name: stray_name, own_pid: 999_999, claude_tmp_dir: "/nonexistent", tmp_dirs: [], running_workspaces: fn -> {:ok, []} end, table: fn -> Agent.get(table, & &1) end}
    )

    capture_log(fn -> assert [_, _] = StrayProcesses.check(stray_name) end)
    {:ok, _orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, stray_processes: stray_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "Processes using CPU with no run attached"
    assert html =~ "pid 4242"
    assert html =~ ~s(<code class="stray-process-command">yes</code>)
    assert html =~ "in #{idle}"
    assert html =~ "10m 1s CPU"
    assert html =~ "pid 4243"
    assert html =~ "in an unknown folder"
    assert html =~ "20m 0s CPU"

    assert json_response(get(build_conn(), "/api/v1/state"), 200)["stray_processes"] == [
             %{"pid" => 4243, "command" => "#{idle}/bin/spin", "cwd" => nil, "cpu_time" => "20:00.00", "cpu_seconds" => 1_200},
             %{"pid" => 4242, "command" => "yes", "cwd" => idle, "cpu_time" => "10:01.00", "cpu_seconds" => 601}
           ]

    Agent.update(table, fn _entries -> {:ok, []} end)
    capture_log(fn -> assert [] = StrayProcesses.check(stray_name) end)

    refute render_async(view, 500) =~ "stray-process-banner"
  end

  test "state API lists usage-limit holds and the usage_limit dispatch blocker" do
    orchestrator_name = Module.concat(__MODULE__, :UsageLimitApiOrchestrator)
    # Days ahead, so the banner always carries the date whatever day the test runs.
    resume_at = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

    snapshot =
      static_snapshot()
      |> Map.put(:usage_limits, [usage_limit_entry(%{resume_at: resume_at, source: nil, utilization: nil})])
      |> Map.put(:dispatch_state, %{
        active?: false,
        blockers: [
          %{
            kind: :usage_limit,
            provider: "anthropic",
            scope: :all,
            reason: "claude_usage_limit",
            window: "five_hour",
            resets_at: ~U[2026-10-03 14:03:00Z],
            resume_at: resume_at,
            phase: :paused
          }
        ]
      })

    {:ok, _orchestrator_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert [%{"banner" => banner} = usage_limit] = payload["usage_limits"]
    # The menu bar shows the banner as the dashboards do, in Symphony's local time.
    assert banner =~ ~r/^Paused: Claude 5-hour limit, resumes ~[A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}$/

    assert [Map.delete(usage_limit, "banner")] == [
             %{
               "provider" => "anthropic",
               "scope" => "all",
               "reason" => "claude_usage_limit",
               "window" => "five_hour",
               "phase" => "paused",
               "since" => "2026-10-03T09:05:00Z",
               "resets_at" => "2026-10-03T14:03:00Z",
               "resume_at" => DateTime.to_iso8601(resume_at),
               "source" => nil,
               "error" => nil,
               "utilization" => nil,
               "issue_identifier" => "MT-HELD"
             }
           ]

    assert payload["dispatch_state"] == %{
             "active?" => false,
             "blockers" => [
               %{
                 "kind" => "usage_limit",
                 "provider" => "anthropic",
                 "scope" => "all",
                 "reason" => "claude_usage_limit",
                 "window" => "five_hour",
                 "phase" => "paused",
                 "resets_at" => "2026-10-03T14:03:00Z",
                 "resume_at" => DateTime.to_iso8601(resume_at)
               }
             ]
           }

    assert payload["pause"] == %{"paused" => false, "reason" => nil, "paused_at" => nil}
  end

  test "dashboard liveview ignores stale workspace dirty dispatch blockers" do
    orchestrator_name = Module.concat(__MODULE__, :WorkspaceDirtyDashboardOrchestrator)

    snapshot =
      Map.put(static_snapshot(), :dispatch_state, %{
        active?: false,
        blockers: [
          %{
            kind: :workspace_dirty,
            repo: "/Users/chihsuan/Projects/symphony",
            dirty_summary: "M WORKFLOW.md"
          }
        ]
      })

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Dispatch active"
    refute html =~ "Dispatch paused"
    refute html =~ "Primary worktree has uncommitted changes"
    refute html =~ "usage-limit-banner"
  end

  test "dashboard liveview disarms armed pause control after timeout" do
    Application.put_env(:symphony_elixir, :dashboard_control_confirm_timeout_ms, 5)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :dashboard_control_confirm_timeout_ms)
    end)

    orchestrator_name = Module.concat(__MODULE__, :DisarmDashboardOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    assert view
           |> element("button", "Pause All")
           |> render_click() =~ "Confirm Pause"

    assert_eventually(fn ->
      html = render(view)
      String.contains?(html, "Pause All") and not String.contains?(html, "Confirm Pause")
    end)
  end

  test "quality liveview renders metrics, recent eval logs, and filters" do
    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_eval_log(%{
               repo_key: "default",
               eval_id: "eval-live-1",
               run_id: "run-live-1",
               issue_id: "issue-live-1",
               issue_identifier: "ACME-LIVE-1",
               issue_labels: ["bug"],
               outcome: "pr_opened",
               status: "stopped",
               error: "agent stopped by orchestrator",
               error_kind: "failure",
               agent_kind: "codex",
               tokens: %{input_tokens: 30, output_tokens: 20, total_tokens: 50},
               duration_seconds: 90,
               tests_run: true,
               session_id: "session-live-1",
               logged_at: now,
               date: DateTime.to_date(now)
             })

    assert :ok =
             RunStore.put_eval_log(%{
               repo_key: "default",
               eval_id: "eval-live-2",
               run_id: "run-live-2",
               issue_id: "issue-live-2",
               issue_identifier: "ACME-LIVE-2",
               issue_labels: ["feature"],
               outcome: "error",
               status: "failure",
               agent_kind: "claude",
               tokens: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
               duration_seconds: 30,
               tests_run: false,
               logged_at: now,
               date: DateTime.to_date(now)
             })

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :QualityLiveOrchestrator), snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/quality?agent=codex&outcome=pr_opened")

    assert html =~ "Quality Dashboard"
    assert html =~ "PR-opened rate"
    assert html =~ "Avg tokens"
    assert html =~ "Tests-run rate"
    assert html =~ "Error rate"
    assert html =~ "ACME-LIVE-1"
    refute html =~ "ACME-LIVE-2"
    assert html =~ "Status"
    assert html =~ "Stopped"
    assert html =~ "agent stopped by orchestrator"
    refute html =~ "failure"
    assert html =~ ~s(name="agent")
    assert html =~ ~s(name="outcome")
    assert html =~ ~s(href="/")
    assert html =~ "/api/v1/runs?export=json"
  end

  test "audit liveview renders empty state" do
    use_audit_dir!()
    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :AuditEmptyLiveOrchestrator), snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/audit")

    assert html =~ "Audit Timeline"
    assert html =~ "No audit events match the current filters."
    assert html =~ ~s(action="/audit")
    assert html =~ ~s(href="/")
  end

  test "audit liveview filters timeline, expands records, verifies chain, and links export" do
    audit_dir = use_audit_dir!()

    assert :ok =
             AuditLog.record(
               %{
                 repo_key: "default",
                 issue_id: "issue-live-audit",
                 issue_identifier: "ACME-AUDIT-LIVE",
                 run_id: "run-live-audit",
                 timestamp: ~U[2026-05-07 12:00:00Z],
                 event_type: "tool_call",
                 payload: %{safe: "visible"}
               },
               dir: audit_dir
             )

    assert :ok =
             AuditLog.record(
               %{
                 repo_key: "default",
                 issue_id: "issue-live-other",
                 issue_identifier: "ACME-AUDIT-OTHER",
                 timestamp: ~U[2026-05-07 12:00:00Z],
                 event_type: "file_change"
               },
               dir: audit_dir
             )

    assert :ok =
             AuditLog.record(
               %{
                 repo_key: "default",
                 issue_id: "issue-live-short",
                 issue_identifier: "ACME-AUDIT-SHORT",
                 run_id: "short",
                 timestamp: ~U[2026-05-07 12:00:00Z],
                 event_type: "tool_call"
               },
               dir: audit_dir
             )

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :AuditLiveOrchestrator), snapshot_timeout_ms: 5)

    {:ok, view, html} =
      live(build_conn(), "/audit?issue=ACME-AUDIT-LIVE&type=tool_call&from=2026-05-07&to=2026-05-07")

    assert html =~ "ACME-AUDIT-LIVE"
    assert html =~ "tool_call"
    assert html =~ "Full record"
    assert html =~ ~s(&quot;safe&quot;: &quot;visible&quot;)
    assert html =~ "/api/v1/audit?"
    refute html =~ "ACME-AUDIT-OTHER"

    assert render_click(view, "verify-chain") =~ "Chain verified for 2026-05-07."

    path = Path.join(audit_dir, "2026-05-07.ndjson")
    [first_line, second_line | rest] = path |> File.read!() |> String.split("\n", trim: true)
    tampered_second = second_line |> Jason.decode!() |> Map.put("previous_hash", "tampered") |> Jason.encode!()
    File.write!(path, Enum.join([first_line, tampered_second | rest], "\n") <> "\n")

    assert render_click(view, "verify-chain") =~ "Chain break at"

    {:ok, _all_view, all_html} = live(build_conn(), "/audit?from=2026-05-07&to=2026-05-07")
    assert all_html =~ "short"
    assert all_html =~ ">n/a</td>"

    {:ok, _since_view, since_html} = live(build_conn(), "/audit?since_last_poll=1")
    assert since_html =~ "since="
    refute since_html =~ "since_last_poll=1"

    {:ok, _error_view, error_html} = live(build_conn(), "/audit?from=bad-date")
    assert error_html =~ "invalid_audit_filter"
  end

  test "audit liveview clears verify result on filter change" do
    audit_dir = use_audit_dir!()

    assert :ok =
             AuditLog.record(
               %{
                 repo_key: "default",
                 issue_id: "issue-verify-clear",
                 issue_identifier: "ACME-VERIFY-CLEAR",
                 timestamp: ~U[2026-05-07 12:00:00Z],
                 event_type: "tool_call"
               },
               dir: audit_dir
             )

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :AuditClearOrchestrator), snapshot_timeout_ms: 5)

    {:ok, view, _html} = live(build_conn(), "/audit?from=2026-05-07&to=2026-05-07")
    assert render_click(view, "verify-chain") =~ "Chain verified for 2026-05-07."

    {:ok, _next_view, next_html} =
      live(build_conn(), "/audit?from=2026-05-07&to=2026-05-07&issue=ACME-VERIFY-CLEAR")

    refute next_html =~ "Chain verified for"
  end

  test "learnings liveview renders records and filters by repo and tag" do
    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_learnings(
               [
                 %{
                   repo_key: "default",
                   id: "learning-live-1",
                   host: "github.com",
                   owner: "example",
                   repo: "repo",
                   rule: "Prefer existing dashboard helpers.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Prefer the existing helper.",
                   evidence_issue_identifier: "ACME-LIVE-1",
                   evidence_issue_url: "https://linear.app/example/issue/ACME-LIVE-1",
                   evidence_pr_number: 12,
                   evidence_run_id: "run-live-1",
                   created_at: now
                 },
                 %{
                   repo_key: "default",
                   id: "learning-live-3",
                   repo: "github.com/example/repo",
                   rule: "Do not reconstruct Linear links without canonical issue URLs.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Avoid workspace-specific Linear URL assumptions.",
                   evidence_issue_identifier: "ACME-LIVE-3",
                   evidence_issue_url: nil,
                   evidence_pr_number: 14,
                   evidence_run_id: "run-live-3",
                   created_at: DateTime.add(now, -30, :second)
                 },
                 %{
                   repo_key: "default",
                   id: "learning-live-2",
                   repo: "github.com/other/repo",
                   rule: "Keep unrelated records filterable.",
                   tags: ["docs", "workflow-config"],
                   evidence_quote: "Update docs too.",
                   evidence_issue_identifier: "ACME-LIVE-2",
                   evidence_issue_url: "https://linear.example.test/acme/ACME-LIVE-2",
                   evidence_pr_number: 13,
                   evidence_run_id: "run-live-2",
                   created_at: DateTime.add(now, -60, :second)
                 }
               ],
               500
             )

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :LearningsLiveOrchestrator), snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/learnings?repo=github.com/example/repo&tag=dashboard")

    assert html =~ "Learnings"
    assert html =~ "Prefer existing dashboard helpers."
    assert html =~ "Prefer the existing helper."
    assert html =~ "Do not reconstruct Linear links without canonical issue URLs."
    assert html =~ "github.com/example/repo"
    assert html =~ ~s(href="https://github.com/example/repo/pull/12" target="_blank")
    assert html =~ ~s(href="https://linear.app/example/issue/ACME-LIVE-1" target="_blank")
    refute html =~ "https://linear.app/example/issue/ACME-LIVE-3"
    assert html =~ ~s(name="repo")
    assert html =~ ~s(name="tag")
    assert html =~ ~s(href="/quality")
    refute html =~ "Keep unrelated records filterable."
  end

  test "learnings liveview hides untrusted PR and Linear evidence links" do
    write_workflow_file!(Workflow.workflow_file_path(), github: %{enterprise_hosts: ["github.example.com"]})

    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_learnings(
               [
                 %{
                   repo_key: "default",
                   id: "learning-live-trusted",
                   host: "github.com",
                   owner: "example",
                   repo: "repo",
                   rule: "Keep trusted GitHub PRs linked.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Trusted PR.",
                   evidence_issue_identifier: "ACME-LIVE-TRUSTED",
                   evidence_issue_url: "https://linear.app/example/issue/ACME-LIVE-TRUSTED",
                   evidence_pr_number: 123,
                   evidence_run_id: "run-live-trusted",
                   created_at: now
                 },
                 %{
                   repo_key: "default",
                   id: "learning-live-ghe",
                   host: "github.example.com",
                   owner: "enterprise",
                   repo: "service",
                   rule: "Keep configured GitHub Enterprise PRs linked.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Trusted GHE PR.",
                   evidence_issue_identifier: "ACME-LIVE-GHE",
                   evidence_issue_url: "https://linear.app/example/issue/ACME-LIVE-GHE",
                   evidence_pr_number: 456,
                   evidence_run_id: "run-live-ghe",
                   created_at: DateTime.add(now, -15, :second)
                 },
                 %{
                   repo_key: "default",
                   id: "learning-live-attacker",
                   host: "login-github.attacker.tld",
                   owner: "foo",
                   repo: "bar",
                   rule: "Do not link attacker PR hosts.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Attacker PR.",
                   evidence_issue_identifier: "ACME-LIVE-ATTACKER",
                   evidence_issue_url: "https://linear.attacker.tld/example/issue/ACME-LIVE-ATTACKER",
                   evidence_pr_number: 9,
                   evidence_run_id: "run-live-attacker",
                   created_at: DateTime.add(now, -30, :second)
                 },
                 %{
                   repo_key: "default",
                   id: "learning-live-linear-scheme",
                   host: "github.com",
                   owner: "example",
                   repo: "other",
                   rule: "Do not link non-HTTPS Linear URLs.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Unsafe Linear scheme.",
                   evidence_issue_identifier: "ACME-LIVE-SCHEME",
                   evidence_issue_url: "http://linear.app/example/issue/ACME-LIVE-SCHEME",
                   evidence_pr_number: 124,
                   evidence_run_id: "run-live-linear-scheme",
                   created_at: DateTime.add(now, -60, :second)
                 },
                 %{
                   repo_key: "default",
                   id: "learning-live-linear-userinfo",
                   host: "github.com",
                   owner: "example",
                   repo: "info",
                   rule: "Do not link Linear URLs with userinfo.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Userinfo Linear URL.",
                   evidence_issue_identifier: "ACME-LIVE-USERINFO",
                   evidence_issue_url: "https://attacker.tld@linear.app/example/issue/ACME-LIVE-USERINFO",
                   evidence_pr_number: 125,
                   evidence_run_id: "run-live-linear-userinfo",
                   created_at: DateTime.add(now, -90, :second)
                 }
               ],
               500
             )

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :LearningsLiveSecurityOrchestrator), snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/learnings?tag=dashboard")

    assert html =~ "Keep trusted GitHub PRs linked."
    assert html =~ ~s(href="https://github.com/example/repo/pull/123" target="_blank")
    assert html =~ ~s(href="https://linear.app/example/issue/ACME-LIVE-TRUSTED" target="_blank")

    assert html =~ "Keep configured GitHub Enterprise PRs linked."
    assert html =~ ~s(href="https://github.example.com/enterprise/service/pull/456" target="_blank")

    assert html =~ "Do not link attacker PR hosts."
    assert html =~ "login-github.attacker.tld/foo/bar"
    refute html =~ "https://login-github.attacker.tld/foo/bar/pull/9"
    refute html =~ "https://linear.attacker.tld/example/issue/ACME-LIVE-ATTACKER"

    assert html =~ "Do not link non-HTTPS Linear URLs."
    assert html =~ ~s(href="https://github.com/example/other/pull/124" target="_blank")
    refute html =~ "http://linear.app/example/issue/ACME-LIVE-SCHEME"

    assert html =~ "Do not link Linear URLs with userinfo."
    assert html =~ ~s(href="https://github.com/example/info/pull/125" target="_blank")
    refute html =~ "attacker.tld@linear.app/example/issue/ACME-LIVE-USERINFO"
  end

  test "dashboard liveview omits watching PR link when pull request URL is unavailable" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardNoPrOrchestrator)

    snapshot =
      update_in(static_snapshot().watching, fn [watching] ->
        [
          Map.put(watching, :pull_request_url, ""),
          %{watching | issue_id: "issue-watch-nil", identifier: "MT-WATCH-NIL", pull_request_url: nil},
          watching
          |> Map.merge(%{issue_id: "issue-watch-missing", identifier: "MT-WATCH-MISSING"})
          |> Map.delete(:pull_request_url)
        ]
      end)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "MT-WATCH"
    assert html =~ "MT-WATCH-NIL"
    assert html =~ "MT-WATCH-MISSING"
    refute html =~ ">PR</a>"
    refute html =~ ~s(href="" target="_blank")
  end

  test "dashboard liveview tolerates snapshots with partial codex totals" do
    orchestrator_name = Module.concat(__MODULE__, :PartialTotalsDashboardOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:codex_totals, %{"input_tokens" => 12, "cached_input_tokens" => 8, "output_tokens" => 5, "total_tokens" => 17})

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload["codex_totals"] == %{
             "input_tokens" => 12,
             "uncached_input_tokens" => 4,
             "cached_input_tokens" => 8,
             "cache_creation_input_tokens" => 0,
             "output_tokens" => 5,
             "total_tokens" => 17,
             "seconds_running" => 0
           }

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "Runtime"
  end

  test "transcript liveview replays buffered events and appends pubsub events" do
    orchestrator_name = Module.concat(__MODULE__, :TranscriptOrchestrator)

    buffered_agent_event = %{
      event: :agent_text,
      payload: %{
        method: "agent_message_delta",
        params: %{msg: %{content: "buffered Claude hello"}}
      },
      timestamp: DateTime.utc_now()
    }

    buffered_agent_continuation_event = %{
      event: :agent_text,
      payload: %{
        method: "agent_message_delta",
        params: %{msg: %{content: " again"}}
      },
      timestamp: DateTime.utc_now()
    }

    buffered_completed_agent_event = %{
      event: :notification,
      payload: %{
        "method" => "item/completed",
        "params" => %{
          "item" => %{
            "type" => "agentMessage",
            "text" => "buffered Codex complete"
          }
        }
      },
      timestamp: DateTime.utc_now()
    }

    buffered_tool_call_event = %{
      event: :notification,
      payload: %{
        "method" => "item/tool/call",
        "params" => %{
          "name" => "linear_graphql",
          "arguments" => %{"query" => "query Viewer { viewer { id } }"}
        }
      },
      timestamp: DateTime.utc_now()
    }

    buffered_tool_result_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"outputDelta" => "buffered command output"}
      },
      timestamp: DateTime.utc_now()
    }

    buffered_progress_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"outputDelta" => "."}
      },
      timestamp: DateTime.utc_now()
    }

    buffered_progress_continuation_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"outputDelta" => "...."}
      },
      timestamp: DateTime.utc_now()
    }

    snapshot =
      update_in(static_snapshot().running, fn [running] ->
        [
          running
          |> Map.put(:transcript_buffer, [
            buffered_agent_event,
            buffered_agent_continuation_event,
            buffered_completed_agent_event,
            buffered_tool_call_event,
            buffered_progress_event,
            buffered_progress_continuation_event,
            buffered_tool_result_event
          ])
          |> Map.put(:transcript_buffer_size, 7)
        ]
      end)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/repos/default/issues/MT-HTTP/transcript")
    assert html =~ "Live Transcript"
    assert html =~ "MT-HTTP"
    assert html =~ ~s(data-transcript-filter="all")
    assert html =~ ~s(data-transcript-filter="agent-text")
    assert html =~ ~s(data-transcript-filter="tool-call")
    assert html =~ ~s(data-transcript-filter="tool-result")
    assert html =~ ~s(data-transcript-filter="session")
    assert html =~ ~s(data-transcript-filter="error")
    assert html =~ ~s(data-transcript-filter="event")
    assert html =~ ~s(data-transcript-filter="reviewer")
    assert html =~ ~s(data-transcript-events)
    assert html =~ ~s(data-filter-active="true")
    assert html =~ ~s(data-filter-agent-text="true")
    assert html =~ ~s(data-filter-error="true")
    assert_filter_pressed(html, "all", false)
    assert_filter_pressed(html, "agent-text", true)
    assert_filter_pressed(html, "error", true)
    assert html =~ ~s(phx-click="toggle_filter")
    # Completed item/agentMessage replaces the in-flight merged-delta entry rather than
    # appending a second one — without this guard reviewer messages would render twice.
    assert html =~ "buffered Codex complete"
    refute html =~ "buffered Claude hello again"
    assert length(Regex.scan(~r/transcript-event-agent-text/, html)) == 1
    assert html =~ "Tool call"
    assert html =~ "linear_graphql"
    assert html =~ "transcript-event-tool-call"
    assert html =~ "Tool result"
    assert html =~ "command output streaming: 5 progress dots"
    assert html =~ "buffered command output"
    assert html =~ "transcript-event-tool-result"

    live_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/requestApproval",
        "params" => %{"msg" => %{"command" => "mix test"}}
      },
      timestamp: DateTime.utc_now()
    }

    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", "issue-http", live_event)

    assert_eventually(fn ->
      live_html = render(view)

      live_html =~ "mix test" and live_html =~ "transcript-event-tool-call"
    end)

    live_progress_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"outputDelta" => "."}
      },
      timestamp: DateTime.utc_now()
    }

    live_progress_continuation_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"outputDelta" => "."}
      },
      timestamp: DateTime.utc_now()
    }

    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", "issue-http", live_progress_event)
    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", "issue-http", live_progress_continuation_event)

    assert_eventually(fn ->
      render(view) =~ "command output streaming: 2 progress dots"
    end)
  end

  test "transcript liveview renders reviewer phase chips and reviewer filter state" do
    orchestrator_name = Module.concat(__MODULE__, :ReviewerTranscriptOrchestrator)

    executor_event = %{
      event: :agent_text,
      agent_phase: :executor,
      payload: %{
        method: "agent_message_delta",
        params: %{msg: %{content: "executor text"}}
      },
      timestamp: DateTime.utc_now()
    }

    reviewer_event = %{
      event: :agent_text,
      agent_phase: :reviewer,
      payload: %{
        method: "agent_message_delta",
        params: %{msg: %{content: "reviewer text"}}
      },
      timestamp: DateTime.utc_now()
    }

    snapshot =
      update_in(static_snapshot().running, fn [running] ->
        [
          running
          |> Map.put(:review_agent_enabled, true)
          |> Map.put(:reviewer_input_tokens, 3)
          |> Map.put(:reviewer_output_tokens, 2)
          |> Map.put(:reviewer_total_tokens, 5)
          |> Map.put(:codex_input_tokens, 13)
          |> Map.put(:codex_output_tokens, 7)
          |> Map.put(:codex_total_tokens, 20)
          |> Map.put(:transcript_buffer, [executor_event, reviewer_event])
          |> Map.put(:transcript_buffer_size, 2)
        ]
      end)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/repos/default/issues/MT-HTTP/transcript?filters=reviewer")

    assert html =~ "executor text"
    assert html =~ "reviewer text"
    assert html =~ "transcript-event-reviewer"
    assert html =~ "transcript-event-phase"
    assert html =~ ">Reviewer</span>"
    assert html =~ "Executor Tokens"
    assert html =~ "Reviewer Tokens"
    assert html =~ "Total Tokens"
    assert html =~ ~r/>\s*15\s*<span class="muted">total/
    assert html =~ ~r/>\s*5\s*<span class="muted">total/
    assert html =~ ~r/>\s*20\s*<span class="muted">combined/
    assert_filter_pressed(html, "reviewer", true)
    assert_filter_attribute(html, "reviewer")
    refute_filter_attribute(html, "agent-text")
  end

  test "transcript liveview renders review-agent verdict events" do
    orchestrator_name = Module.concat(__MODULE__, :ReviewerVerdictTranscriptOrchestrator)

    verdict_event = %{
      event: :review_agent_verdict,
      agent_phase: :reviewer,
      payload: %{
        verdict: :request_changes,
        round: 2,
        max_iterations: 1,
        reason: "Tighten the regression coverage.",
        comments: ["Tighten the regression coverage.", "Keep the UI filter stable."],
        tokens: %{input_tokens: 8, cached_input_tokens: 3, uncached_input_tokens: 5, output_tokens: 4, total_tokens: 12}
      },
      timestamp: DateTime.utc_now()
    }

    snapshot =
      update_in(static_snapshot().running, fn [running] ->
        [
          running
          |> Map.put(:review_agent_enabled, true)
          |> Map.put(:transcript_buffer, [verdict_event])
          |> Map.put(:transcript_buffer_size, 1)
        ]
      end)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/repos/default/issues/MT-HTTP/transcript?filters=event,reviewer")

    assert html =~ "Reviewer verdict: request changes"
    assert html =~ "review 2 of 2"
    assert html =~ "reason: Tighten the regression coverage."
    assert html =~ "comments: 2"
    assert html =~ "tokens in=8 out=4 total=12"
    assert html =~ "transcript-event-verdict-request-changes"
    assert html =~ "request changes"
    assert html =~ "Tighten the regression coverage."
  end

  test "transcript liveview restores default filter state without query params" do
    orchestrator_name = Module.concat(__MODULE__, :DefaultTranscriptFilterOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/repos/default/issues/MT-HTTP/transcript")

    assert_filter_pressed(html, "all", false)
    assert_filter_pressed(html, "agent-text", true)
    assert_filter_pressed(html, "tool-call", false)
    assert_filter_pressed(html, "tool-result", false)
    assert_filter_pressed(html, "session", false)
    assert_filter_pressed(html, "error", true)
    assert_filter_pressed(html, "event", false)
    assert_filter_pressed(html, "reviewer", false)
    assert_filter_attribute(html, "agent-text")
    assert_filter_attribute(html, "error")
    refute_filter_attribute(html, "event")
  end

  test "transcript liveview restores explicit filters from query params" do
    orchestrator_name = Module.concat(__MODULE__, :ExplicitTranscriptFilterOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/repos/default/issues/MT-HTTP/transcript?filters=event,tool-call")

    assert_filter_pressed(html, "all", false)
    assert_filter_pressed(html, "agent-text", false)
    assert_filter_pressed(html, "tool-call", true)
    assert_filter_pressed(html, "tool-result", false)
    assert_filter_pressed(html, "session", false)
    assert_filter_pressed(html, "error", false)
    assert_filter_pressed(html, "event", true)
    assert_filter_pressed(html, "reviewer", false)
    assert_filter_attribute(html, "tool-call")
    assert_filter_attribute(html, "event")
    refute_filter_attribute(html, "agent-text")
    refute_filter_attribute(html, "error")
  end

  test "transcript liveview clears filters for all or empty query values" do
    orchestrator_name = Module.concat(__MODULE__, :ClearedTranscriptFilterOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    for suffix <- ["all", ""] do
      {:ok, _view, html} = live(build_conn(), "/repos/default/issues/MT-HTTP/transcript?filters=#{suffix}")

      assert_filter_pressed(html, "all", true)
      assert_filter_pressed(html, "agent-text", false)
      assert_filter_pressed(html, "tool-call", false)
      assert_filter_pressed(html, "tool-result", false)
      assert_filter_pressed(html, "session", false)
      assert_filter_pressed(html, "error", false)
      assert_filter_pressed(html, "event", false)
      assert_filter_pressed(html, "reviewer", false)
      refute html =~ ~s(data-filter-active="true")
      refute_filter_attribute(html, "agent-text")
      refute_filter_attribute(html, "error")
      refute_filter_attribute(html, "event")
    end
  end

  test "transcript liveview drops unknown filter query values" do
    orchestrator_name = Module.concat(__MODULE__, :UnknownTranscriptFilterOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/repos/default/issues/MT-HTTP/transcript?filters=garbage,error")

    assert_filter_pressed(html, "all", false)
    assert_filter_pressed(html, "agent-text", false)
    assert_filter_pressed(html, "error", true)
    assert_filter_pressed(html, "event", false)
    assert_filter_pressed(html, "reviewer", false)
    assert_filter_attribute(html, "error")
    refute_filter_attribute(html, "agent-text")
    refute_filter_attribute(html, "event")
  end

  test "transcript liveview toggles filters and patches the URL" do
    orchestrator_name = Module.concat(__MODULE__, :ToggleTranscriptFilterOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/repos/default/issues/MT-HTTP/transcript")

    view
    |> element(~s(button[data-transcript-filter="event"]))
    |> render_click()

    assert_patch(view, "/repos/default/issues/MT-HTTP/transcript?filters=agent-text%2Cerror%2Cevent")

    html = render(view)
    assert_filter_pressed(html, "agent-text", true)
    assert_filter_pressed(html, "error", true)
    assert_filter_pressed(html, "event", true)
    assert_filter_attribute(html, "agent-text")
    assert_filter_attribute(html, "error")
    assert_filter_attribute(html, "event")
  end

  test "transcript liveview replays watched issue buffered events" do
    orchestrator_name = Module.concat(__MODULE__, :WatchingTranscriptOrchestrator)

    watched_event = %{
      event: :notification,
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "watched hello"}
      },
      timestamp: DateTime.utc_now()
    }

    watched_at = DateTime.utc_now()

    snapshot =
      static_snapshot()
      |> Map.put(:running, [])
      |> update_in([:watching], fn [watching] ->
        [
          watching
          |> Map.put(:session_id, "thread-watch-turn-1")
          |> Map.put(:started_at, DateTime.add(watched_at, -300, :second))
          |> Map.put(:last_event_at, watched_at)
          |> Map.put(:turn_count, 4)
          |> Map.put(:tokens, %{
            input_tokens: 21,
            cached_input_tokens: 5,
            uncached_input_tokens: 16,
            output_tokens: 13,
            total_tokens: 34
          })
          |> Map.put(:transcript_buffer, [watched_event])
          |> Map.put(:transcript_buffer_size, 1)
        ]
      end)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/repos/default/issues/MT-WATCH/transcript")
    assert html =~ "Live Transcript"
    assert html =~ "MT-WATCH"
    assert html =~ "In Review"
    assert html =~ "thread-watch-turn-1"
    assert html =~ "watched hello"
    assert html =~ "34"
    assert html =~ "buffered and live events for this issue"
  end

  test "transcript liveview routes encoded non-default repo keys" do
    orchestrator_name = Module.concat(__MODULE__, :EncodedRepoTranscriptOrchestrator)
    repo_key = "github.com/acme/repo"

    snapshot =
      update_in(static_snapshot().running, fn [running] ->
        [Map.put(running, :repo_key, repo_key)]
      end)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    encoded_repo_key = URI.encode_www_form(repo_key)
    {:ok, view, html} = live(build_conn(), "/repos/#{encoded_repo_key}/issues/MT-HTTP/transcript")

    assert html =~ "Live Transcript"
    assert html =~ "MT-HTTP"

    ignored_event = %{
      event: :notification,
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "wrong repo event"}
      },
      timestamp: DateTime.utc_now()
    }

    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", "issue-http", ignored_event)
    Process.sleep(50)
    refute render(view) =~ "wrong repo event"

    matching_event = %{
      event: :notification,
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "encoded route event"}
      },
      timestamp: DateTime.utc_now()
    }

    assert :ok = ObservabilityPubSub.broadcast_transcript_event(repo_key, "issue-http", matching_event)

    assert_eventually(fn ->
      render(view) =~ "encoded route event"
    end)
  end

  test "transcript liveview renders an error state for missing issues" do
    orchestrator_name = Module.concat(__MODULE__, :MissingTranscriptOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/repos/default/issues/MT-MISSING/transcript")
    assert html =~ "Transcript unavailable"
    assert html =~ "No running issue matched this identifier."
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server starts on an ephemeral port by default" do
    orchestrator_name = Module.concat(__MODULE__, :DefaultPortOrchestrator)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: static_snapshot()})
    start_supervised!({HttpServer, [orchestrator: orchestrator_name, snapshot_timeout_ms: 50]})

    port = wait_for_bound_port()
    assert is_integer(port)
    assert port > 0
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    orchestrator_opts = [
      name: orchestrator_name,
      owner: self(),
      snapshot: snapshot,
      refresh: refresh
    ]

    start_supervised!({StaticOrchestrator, orchestrator_opts})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "watching" => 1, "human_review" => 0, "conflicts" => 0, "retrying" => 1, "claimed" => 2, "forced" => 2}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    cross_origin_refresh =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"origin", "https://evil.example"}, {"content-type", "text/plain"}],
        body: ""
      )

    assert cross_origin_refresh.status == 403
    assert cross_origin_refresh.body["error"]["code"] == "forbidden_origin"
    refute_received :request_refresh_called

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"origin", "http://127.0.0.1:#{port}"}, {"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true
    assert_received :request_refresh_called

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp use_audit_dir! do
    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-audit-web-#{System.unique_integer([:positive])}"
      )

    audit_dir = Path.join(test_root, "audit")
    Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)

    on_exit(fn ->
      if previous_audit_dir do
        Application.put_env(:symphony_elixir, :audit_log_dir, previous_audit_dir)
      else
        Application.delete_env(:symphony_elixir, :audit_log_dir)
      end

      File.rm_rf(test_root)
    end)

    audit_dir
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp assert_repo_chip(html, repo) do
    assert html =~ repo_chip_pattern(repo)
    assert html =~ ~s(<span class="repo-chip-text">#{repo}</span>)
  end

  defp repo_chip_pattern(repo) do
    escaped_repo = Regex.escape(repo)

    ~r/<span(?=[^>]*class="[^"]*\brepo-chip\b[^"]*")(?=[^>]*title="#{escaped_repo}")(?=[^>]*aria-label="Repository #{escaped_repo}")/
  end

  defp conflict_repo_chip_pattern(repo) do
    escaped_repo = Regex.escape(repo)

    ~r/<span(?=[^>]*class="[^"]*\brepo-chip-conflict\b[^"]*")(?=[^>]*title="#{escaped_repo}")(?=[^>]*aria-label="Repository #{escaped_repo}")/
  end

  defp assert_filter_pressed(html, filter, pressed?) do
    escaped_filter = Regex.escape(filter)

    assert html =~ ~r/<button(?=[^>]*data-transcript-filter="#{escaped_filter}")(?=[^>]*aria-pressed="#{pressed?}")/
  end

  defp assert_filter_attribute(html, filter), do: assert(html =~ ~s(data-filter-#{filter}="true"))

  defp refute_filter_attribute(html, filter), do: refute(html =~ ~s(data-filter-#{filter}="true"))

  defp lane(issue_id, identifier, status, sub_issue) do
    %{issue_id: issue_id, identifier: identifier, title: "Epic #{identifier}", url: "https://linear.test/#{identifier}", status: status, sub_issue: sub_issue}
  end

  defp usage_limit_entry(attrs) do
    Map.merge(
      %{
        provider: "anthropic",
        scope: :all,
        reason: "claude_usage_limit",
        window: "five_hour",
        phase: :paused,
        since: ~U[2026-10-03 09:05:00Z],
        resets_at: ~U[2026-10-03 14:03:00Z],
        resume_at: ~U[2026-10-03 14:05:00Z],
        source: :rate_limit_event,
        utilization: 1.0,
        issue_identifier: "MT-HELD"
      },
      attrs
    )
  end

  defp put_build(build) do
    previous = Application.fetch_env(:symphony_elixir, :build)
    Application.put_env(:symphony_elixir, :build, build)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :build, value)
        :error -> Application.delete_env(:symphony_elixir, :build)
      end
    end)
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          repo_key: "default",
          identifier: "MT-HTTP",
          state: "In Progress",
          url: "https://linear.app/example/issue/MT-HTTP",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      watching: [
        %{
          issue_id: "issue-watch",
          repo_key: "default",
          identifier: "MT-WATCH",
          state: "In Review",
          url: "https://linear.app/example/issue/MT-WATCH",
          pull_request_url: "https://github.com/example/repo/pull/123",
          last_ran_at: DateTime.add(DateTime.utc_now(), -3_600, :second),
          seconds_since_last_run: 3_600
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          repo_key: "default",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      run_history: [
        %{
          run_id: "run-http",
          repo_key: "default",
          issue_id: "issue-http",
          issue_identifier: "MT-HTTP",
          title: "HTTP snapshot",
          state: "In Progress",
          status: "success",
          attempt: 1,
          started_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now(),
          error: nil,
          worker_host: nil,
          workspace_path: nil,
          session_id: "thread-http",
          transcript_path: nil,
          turn_count: 7,
          runtime_seconds: 42,
          tokens: %{input_tokens: 4, output_tokens: 8, total_tokens: 12}
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      budget: %{
        per_issue_limit: 500,
        daily_limit: 1_000,
        daily_used: 400,
        daily_remaining: 600,
        daily_paused: false
      },
      epic_lanes: %{
        max_total: 2,
        lanes: [
          %{
            issue_id: "epic-http",
            identifier: "MT-EPIC",
            title: "Epic",
            url: "https://linear.test/MT-EPIC",
            status: "waiting",
            sub_issue: %{issue_id: "part-http", identifier: "MT-PART", state: "In Review"}
          }
        ],
        queued_epics: [],
        shared: %{slots: 1, used: 1}
      },
      finishing: %{slots: 2, used: 1, running: [%{issue_id: "land-http", identifier: "MT-LAND", state: "Merging"}]},
      qa: %{
        running: [%{issue_id: "qa-forced-http", identifier: "MT-QA-F", sha: "abc1234def", forced: true}],
        queued: [%{issue_id: "qa-queued-http", identifier: "MT-QA-Q", forced: false}]
      },
      auto_merge: [
        %{
          issue_id: "merge-http",
          issue_identifier: "MT-MERGE",
          pr_url: "https://github.com/acme/repo/pull/9",
          state: "enabled",
          head_sha: "abc1234def",
          status: "auto-merge on, waiting for CI on `abc1234`",
          updated_at: ~U[2026-10-03 06:00:00Z]
        }
      ],
      claimed: ["issue-http", "retry-http"],
      slot_waiting: [
        %{
          issue_id: "wait-http",
          identifier: "MT-WAIT",
          title: "Waiting",
          state: "Todo",
          reason: "a Merging or Auto Review issue is waiting for a slot",
          attempt: nil,
          since: ~U[2026-10-03 06:00:00Z]
        }
      ],
      blocked: [
        %{
          issue_id: "verify-http",
          identifier: "MT-VERIFY",
          title: "Final verification: Export",
          state: "Todo",
          blockers: [%{identifier: "MT-GAP", state: "In Progress"}, %{identifier: nil, state: nil}]
        },
        %{
          issue_id: "update-http",
          identifier: "MT-UPDATE",
          title: "Final verification: Pause",
          state: "Todo",
          kind: :app_update,
          reason: "waiting for an app update: MT-FIX merged in `9f54098`, running `d3d301b`",
          blockers: [%{identifier: "MT-FIX", state: "merged in 9f54098"}]
        }
      ],
      forced: [
        %{
          issue_id: "forced-http",
          identifier: "MT-FORCED",
          title: "Fix the release",
          state: "In Review",
          forced_since: ~U[2026-10-03 05:00:00.123456Z],
          forced_for_seconds: 3_600,
          stale: false,
          position: 1,
          waiting_on_human: true,
          sub_issue: nil,
          phase: :waiting_for_human,
          running: false,
          waiting_on: :human,
          blockers: []
        },
        %{
          issue_id: "forced-parent-http",
          identifier: "MT-EPIC",
          title: "Export",
          state: "Waiting on sub-tickets",
          forced_since: ~U[2026-10-03 06:00:00Z],
          forced_for_seconds: 300_000,
          stale: true,
          position: 2,
          waiting_on_human: false,
          sub_issue: %{issue_id: "part-http", identifier: "MT-PART", state: "Todo"},
          phase: :implementation,
          running: false,
          waiting_on: :blocker,
          blockers: ["MT-GAP"]
        }
      ],
      concurrency: %{max_total: 10, finishing_max: 2, forced_max: 1},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp multi_repo_snapshot do
    now = DateTime.utc_now()

    static_snapshot()
    |> Map.put(:running, [
      %{
        issue_id: "issue-http",
        repo_key: "default",
        identifier: "MT-HTTP",
        state: "In Progress",
        url: "https://linear.app/example/issue/MT-HTTP",
        session_id: "thread-default",
        turn_count: 1,
        codex_app_server_pid: nil,
        last_codex_message: "default update",
        last_codex_timestamp: nil,
        last_codex_event: :notification,
        codex_input_tokens: 1,
        codex_output_tokens: 2,
        codex_total_tokens: 3,
        started_at: now
      },
      %{
        issue_id: "issue-api",
        repo_key: "api",
        identifier: "MT-API",
        state: "In Progress",
        url: "https://linear.app/example/issue/MT-API",
        session_id: "thread-api",
        turn_count: 2,
        codex_app_server_pid: nil,
        last_codex_message: "api update",
        last_codex_timestamp: nil,
        last_codex_event: :notification,
        codex_input_tokens: 5,
        codex_output_tokens: 7,
        codex_total_tokens: 12,
        started_at: now
      }
    ])
    |> Map.put(:watching, [
      %{
        issue_id: "issue-api-watch",
        repo_key: "api",
        identifier: "MT-API-WATCH",
        state: "In Review",
        url: "https://linear.app/example/issue/MT-API-WATCH",
        pull_request_url: nil,
        last_ran_at: DateTime.add(now, -600, :second),
        seconds_since_last_run: 600
      }
    ])
    |> Map.put(:retrying, [
      %{
        issue_id: "issue-web-retry",
        repo_key: "web",
        identifier: "MT-WEB-RETRY",
        attempt: 3,
        due_in_ms: 5_000,
        error: "rate limited"
      }
    ])
    |> Map.put(:conflicts, [
      %{
        issue_id: "issue-conflict",
        identifier: "MT-CONFLICT",
        state: "Conflict",
        linear_state: "Todo",
        url: "https://linear.app/example/issue/MT-CONFLICT",
        repo_keys: ["api", "web"]
      }
    ])
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      restart_workflow_store()
    end
  end

  defp terminate_workflow_store do
    case workflow_store_supervisor() do
      nil ->
        stop_unsupervised_workflow_store()

      supervisor ->
        case Supervisor.terminate_child(supervisor, workflow_store_child_id()) do
          :ok -> :ok
          {:error, :not_found} -> stop_unsupervised_workflow_store()
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp restart_workflow_store do
    case workflow_store_supervisor() do
      nil ->
        case WorkflowStore.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      supervisor ->
        case Supervisor.restart_child(supervisor, workflow_store_child_id()) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp stop_unsupervised_workflow_store do
    if pid = Process.whereis(WorkflowStore) do
      GenServer.stop(pid)
    end

    :ok
  end

  defp workflow_store_supervisor do
    case workflow_store_repo_name() do
      nil -> nil
      repo_name -> SymphonyElixir.Repo.Supervisor.supervisor_name(repo_name)
    end
    |> fallback_workflow_store_supervisor()
  end

  defp workflow_store_child_id do
    {WorkflowStore, workflow_store_repo_name() || supervised_repo_name()}
  end

  defp workflow_store_repo_name do
    ["default", "symphony", Application.get_env(:symphony_elixir, :primary_repo_name)]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(fn repo_name ->
      if Process.whereis(SymphonyElixir.Repo.Registry) do
        repo_name
        |> SymphonyElixir.Repo.Supervisor.supervisor_name()
        |> GenServer.whereis()
        |> is_pid()
      else
        false
      end
    end)
  end

  defp fallback_workflow_store_supervisor(nil) do
    case supervised_repo_child() do
      {_repo_name, repo_pid} -> repo_pid
      nil -> nil
    end
  end

  defp fallback_workflow_store_supervisor(supervisor), do: supervisor

  defp supervised_repo_name do
    case supervised_repo_child() do
      {repo_name, _repo_pid} -> repo_name
      nil -> nil
    end
  end

  defp supervised_repo_child do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {{SymphonyElixir.Repo.Supervisor, repo_name}, repo_pid, :supervisor, _modules}
          when is_pid(repo_pid) ->
            {repo_name, repo_pid}

          _child ->
            nil
        end)

      _pid ->
        nil
    end
  end
end
