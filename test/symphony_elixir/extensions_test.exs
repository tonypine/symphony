defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias Mix.Tasks.Symphony.Audit
  alias SymphonyElixir.{AuditLog, RetiredStates, StrayProcesses, TicketState}
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Linear.{Adapter, Client, Usage}
  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.Tracker.Memory

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

  test "phoenix observability api lists the watched issues with the facts read of their PRs" do
    facts = Facts.new(phase: :code_review, ci: :green, pr_number: 9, ahead: [%{issue_identifier: "MT-2", pr_number: 2, files: ["SPEC.md"]}])
    read_at = ~U[2026-10-16 12:00:00.500Z]

    watch = %{
      facts: facts,
      pr_url: "https://github.com/acme/repo/pull/9",
      head_sha: "abc123",
      read_at: read_at,
      rate_limit: %{remaining: 4000, limit: 5000, reset_at: ~U[2026-10-16 13:00:00Z]}
    }

    silent = %{since: ~U[2026-10-16 11:59:00Z], ticks: 2, bound: nil, reason: "R26 decided `dispatch`, but no run started and no wait is recorded"}

    :ok =
      RunStore.put_ticket_pr_watch(
        "default",
        "watched-2",
        "MT-WATCH-2",
        Map.merge(watch, %{
          facts: %{facts | github: :rate_limited},
          github: {:rate_limited, ~U[2026-10-16 12:10:00Z]},
          rate_limit: nil,
          silent: silent,
          decision: %{rule: "R4", kind: :wait, reason: "CI keeps failing", waits_on: %{type: "fix_ticket", keys: ["MT-FIX"]}}
        })
      )

    competitor = %{
      issue_id: "i2",
      issue_identifier: "MT-2",
      pr_number: 2,
      pr_url: "https://github.com/acme/repo/pull/2",
      title: "Two",
      files: ["SPEC.md"],
      head_sha: "h2",
      progress_at: read_at,
      linked: true,
      step_behind: false,
      released: false
    }

    :ok = RunStore.put_ticket_pr_watch("default", "watched-1", "MT-WATCH-1", Map.put(watch, :links, [competitor, %{competitor | pr_number: 3, released: true}]))
    :ok = RunStore.put_ticket_state(TicketState.new("default", "unwatched", %{issue_identifier: "MT-OTHER", phase: "Todo"}))

    orchestrator_name = Module.concat(__MODULE__, :WatchedIssuesApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"issues" => [first, second], "silent_waits" => silent_waits, "rate_limit" => rate_limit} = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert silent_waits == [
             %{
               "issue_id" => "watched-2",
               "identifier" => "MT-WATCH-2",
               "repo_key" => "default",
               "phase" => "code_review",
               "pr_url" => "https://github.com/acme/repo/pull/9",
               "since" => "2026-10-16T11:59:00Z",
               "rule" => "R4",
               "bound" => nil,
               "reason" => "R26 decided `dispatch`, but no run started and no wait is recorded"
             }
           ]

    assert rate_limit == %{"remaining" => 4000, "limit" => 5000, "reset" => "2026-10-16T13:00:00Z"}

    assert %{
             "issue_id" => "watched-1",
             "identifier" => "MT-WATCH-1",
             "repo_key" => "default",
             "watch" => %{
               "facts" => %{
                 "phase" => "code_review",
                 "ci" => "green",
                 "pr" => "open",
                 "pr_number" => 9,
                 "pr_url" => "https://github.com/acme/repo/pull/9",
                 "head_sha" => "abc123",
                 "source" => "poll",
                 "read_at" => "2026-10-16T12:00:00Z",
                 "github" => "ok",
                 "github_reset_at" => nil,
                 "rate_limit" => %{"remaining" => 4000, "reset_at" => "2026-10-16T13:00:00Z"},
                 "ahead" => [%{"issue_identifier" => "MT-2", "pr_number" => 2, "files" => ["SPEC.md"]}],
                 "competing" => []
               },
               "decision" => nil,
               "applied" => [],
               "links" => [%{"issue_identifier" => "MT-2", "linked" => true}, %{"released" => true}],
               "waits_on" => [%{"identifier" => "MT-2", "kind" => "competitor", "pr_url" => "https://github.com/acme/repo/pull/2", "shared_files" => 1, "files" => ["SPEC.md"]}]
             }
           } = first

    assert %{
             "identifier" => "MT-WATCH-2",
             "watch" => %{
               "facts" => %{"github" => "rate_limited", "github_reset_at" => "2026-10-16T12:10:00Z", "rate_limit" => nil},
               "waits_on" => [%{"identifier" => "MT-FIX", "kind" => "fix_ticket"}]
             }
           } = second

    assert %{"phase" => "code_review", "head" => "abc123", "source" => "poll", "summary" => "PR #9 open · CI green · mergeability unknown"} = first["watch"]

    # The ticket page reads the same block.
    assert %{"issue_identifier" => "MT-WATCH-2", "watch" => %{"silent" => %{"ticks" => 2}, "phase" => "code_review"}} =
             json_response(get(build_conn(), "/api/v1/MT-WATCH-2"), 200)
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

    # A named inbox this test never starts, so the payload's inbox state is the same on every
    # run: an unstarted inbox reads as read (`Inbox.read?/1`), independent of the app's Inbox poller.
    # A Setup with no checks, so the payload doesn't depend on what earlier tests left behind.
    setup_name = Module.concat(__MODULE__, :ObservabilityApiSetup)
    start_supervised!({SymphonyElixir.Setup, name: setup_name, checks: [], linear_api_key?: false, now: fn -> ~U[2026-10-19 09:00:00Z] end})
    assert %{checked_at: "2026-10-19T09:00:00Z"} = SymphonyElixir.Setup.refresh(setup_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      inbox: Module.concat(__MODULE__, :ObservabilityApiInbox),
      setup: setup_name
    )

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)
    assert is_integer(state_payload["uptime_seconds"]) and state_payload["uptime_seconds"] >= 0

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "build" => %{"version" => "0.0.1.168", "sha" => "d3d301b0123456789abcdef0123456789abcdef0"},
             "uptime_seconds" => state_payload["uptime_seconds"],
             "repos" => ["default"],
             "counts" => %{
               "running" => 1,
               "watching" => 1,
               "conflicts" => 0,
               "retrying" => 1,
               "claimed" => 2,
               "forced" => 2,
               "shipped_today" => 1,
               "waiting_on_you" => 0,
               "review_inconclusive" => %{"invalid_verdict" => 1}
             },
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
             "sessions" => [
               %{
                 "kind" => "agent",
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "repo_key" => "default",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at")
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
             "waiting_on_you" => [],
             "inbox_read" => true,
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
             "drain_report" => state_payload["drain_report"],
             "setup" => %{"problems" => [], "not_checked" => [], "checked_at" => "2026-10-19T09:00:00Z", "linear_checked_at" => nil},
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
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12},
                 "review_inconclusive_cause" => "invalid_verdict"
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
             "landing_waits" => [
               %{
                 "issue_id" => "follow-http",
                 "issue_identifier" => "MT-FOLLOW",
                 "pull_request_url" => "https://github.com/acme/repo/pull/10",
                 "state" => "QA",
                 "waits_for" => %{
                   "issue_id" => "merge-http",
                   "issue_identifier" => "MT-MERGE",
                   "pull_request_url" => "https://github.com/acme/repo/pull/9",
                   "state" => "Merging"
                 },
                 "shared_files" => 2,
                 "files" => ["lib/a.ex", "lib/b.ex"],
                 "reason" => "waits for MT-MERGE to land (shares 2 files)",
                 "since" => "2026-10-03T06:00:00Z"
               }
             ],
             "red_bases" => [],
             "issues" => [],
             "silent_waits" => [],
             "rate_limit" => nil,
             "slot_waiting" => [
               %{
                 "issue_id" => "wait-http",
                 "issue_identifier" => "MT-WAIT",
                 "repo_key" => "default",
                 "title" => "Waiting",
                 "state" => "Todo",
                 "reason" => "a Merging issue is waiting for a slot",
                 "attempt" => nil,
                 "since" => "2026-10-03T06:00:00Z",
                 "forced" => false
               }
             ],
             "dispatch_skipped" => [
               %{
                 "issue_id" => "skip-http",
                 "issue_identifier" => "MT-SKIP",
                 "repo_key" => "default",
                 "title" => "Skipped",
                 "state" => "Todo",
                 "reason" => "priority medium is not in tickets.priorities (urgent, high)",
                 "since" => "2026-10-03T06:00:00Z"
               }
             ],
             "shipped_today" => [
               %{
                 "issue_id" => "shipped-http",
                 "issue_identifier" => "MT-SHIPPED",
                 "title" => "Shipped",
                 "repo_key" => "default",
                 "completed_at" => "2026-10-03T07:00:00Z"
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
             "app_update" => %{"unblocks" => 1, "issue_identifiers" => ["MT-UPDATE"], "latest_release" => nil},
             "forced" => [
               %{
                 "issue_id" => "forced-http",
                 "issue_identifier" => "MT-FORCED",
                 "title" => "Fix the release",
                 "repo_key" => "web",
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
                 "repo_key" => nil,
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
             "tracked" => %{},
             "verdicts" => [],
             "watch" => nil
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
             "tracked" => %{},
             "verdicts" => [],
             "watch" => nil
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
    assert state_payload["counts"]["shipped_today"] == 1
    assert state_payload["counts"]["forced"] == 2
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

  test "phoenix observability api serves a ticket waiting for a slot or passed over by a dispatch gate" do
    orchestrator_name = Module.concat(__MODULE__, :WaitingIssueApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot(), refresh: :unavailable)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{
             "status" => "dispatch_skipped",
             "issue_id" => "skip-http",
             "repo_key" => "default",
             "running" => nil,
             "retry" => nil,
             "dispatch_skipped" => %{
               "state" => "Todo",
               "reason" => "priority medium is not in tickets.priorities (urgent, high)",
               "since" => "2026-10-03T06:00:00Z"
             },
             "verdicts" => [],
             "watch" => nil
           } = skipped = json_response(get(build_conn(), "/api/v1/MT-SKIP"), 200)

    refute Map.has_key?(skipped, "slot_waiting")

    assert %{
             "status" => "slot_waiting",
             "issue_id" => "wait-http",
             "slot_waiting" => %{
               "state" => "Todo",
               "reason" => "a Merging issue is waiting for a slot",
               "since" => "2026-10-03T06:00:00Z"
             }
           } = json_response(get(build_conn(), "/api/v1/MT-WAIT"), 200)

    assert json_response(get(build_conn(), "/api/v1/MT-MISSING"), 404)["error"]["code"] == "issue_not_found"
  end

  test "phoenix observability api serves a ticket's code review and qa verdicts, newest first" do
    reviewed = ~U[2026-10-12 09:00:00Z]
    passed = ~U[2026-10-12 10:00:00Z]

    record =
      "default"
      |> TicketState.new("issue-http", %{issue_identifier: "MT-HTTP"})
      |> TicketState.record_verdict("code_review", "abc123", "approve", reviewed)
      |> TicketState.record_verdict("ci_fix", "abc123", "mechanical", reviewed)
      |> TicketState.record_verdict("qa", "abc123", "fail", passed)

    gone =
      "default"
      |> TicketState.new("issue-gone", %{issue_identifier: "MT-GONE"})
      |> TicketState.record_verdict("code_review", nil, "rework", reviewed)

    retry = TicketState.new("other", "retry-elsewhere", %{issue_identifier: "MT-RETRY"})
    retry = TicketState.record_verdict(retry, "qa", "def456", "pass", passed)

    for ticket <- [record, gone, retry], do: assert(:ok = RunStore.put_ticket_state(ticket))

    on_exit(fn ->
      RunStore.delete_ticket_state("default", "issue-http")
      RunStore.delete_ticket_state("default", "issue-gone")
      RunStore.delete_ticket_state("other", "retry-elsewhere")
    end)

    snapshot = Map.update!(static_snapshot(), :retrying, fn entries -> Enum.map(entries, &Map.delete(&1, :repo_key)) end)
    orchestrator_name = Module.concat(__MODULE__, :VerdictsApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot, refresh: :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"verdicts" => verdicts} = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)

    assert verdicts == [
             %{"kind" => "qa", "outcome" => "fail", "head_sha" => "abc123", "recorded_at" => "2026-10-12T10:00:00Z"},
             %{"kind" => "code_review", "outcome" => "approve", "head_sha" => "abc123", "recorded_at" => "2026-10-12T09:00:00Z"}
           ]

    assert %{"status" => "retrying", "verdicts" => [%{"kind" => "qa", "outcome" => "pass"}]} =
             json_response(get(build_conn(), "/api/v1/MT-RETRY"), 200)

    assert %{"verdicts" => []} = json_response(get(build_conn(), "/api/v1/MT-WATCH"), 200)

    assert %{
             "status" => "untracked",
             "repo_key" => "default",
             "issue_id" => "issue-gone",
             "running" => nil,
             "verdicts" => [%{"kind" => "code_review", "outcome" => "rework", "head_sha" => nil}]
           } = json_response(get(build_conn(), "/api/v1/MT-GONE"), 200)

    assert json_response(get(build_conn(), "/api/v1/MT-MISSING"), 404)["error"]["code"] == "issue_not_found"
  end

  test "phoenix observability api serves a tracked ticket's connected tickets, an untracked one none" do
    connected = %{
      parent: %{identifier: "MT-EPIC", title: "Ship the peek", done: 1, total: 3, children: ["completed", "started", "unstarted"]},
      sub_tickets: [%{identifier: "MT-SUB", title: nil, state: "Todo"}],
      blocked_by: [%{identifier: "MT-BLOCKER", title: nil, state: "In Progress"}],
      blocks: [%{identifier: "MT-NEXT", title: "Downstream", state: "Todo"}],
      related: [%{identifier: "MT-REL", title: "Context", state: "Done"}]
    }

    gone = TicketState.new("default", "issue-gone", %{issue_identifier: "MT-GONE"})
    assert :ok = RunStore.put_ticket_state(gone)
    on_exit(fn -> RunStore.delete_ticket_state("default", "issue-gone") end)

    snapshot =
      static_snapshot()
      |> Map.update!(:watching, fn entries -> Enum.map(entries, &Map.put(&1, :connected, connected)) end)
      |> Map.update!(:slot_waiting, fn entries -> Enum.map(entries, &Map.put(&1, :connected, %{connected | parent: nil})) end)

    orchestrator_name = Module.concat(__MODULE__, :ConnectedApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot, refresh: :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"status" => "watching", "connected" => watched} = json_response(get(build_conn(), "/api/v1/MT-WATCH"), 200)

    assert watched == %{
             "parent" => %{
               "identifier" => "MT-EPIC",
               "title" => "Ship the peek",
               "done" => 1,
               "total" => 3,
               "children" => ["completed", "started", "unstarted"]
             },
             "sub_tickets" => [%{"identifier" => "MT-SUB", "title" => nil, "state" => "Todo"}],
             "blocked_by" => [%{"identifier" => "MT-BLOCKER", "title" => nil, "state" => "In Progress"}],
             "blocks" => [%{"identifier" => "MT-NEXT", "title" => "Downstream", "state" => "Todo"}],
             "related" => [%{"identifier" => "MT-REL", "title" => "Context", "state" => "Done"}]
           }

    assert %{"status" => "slot_waiting", "connected" => %{"parent" => nil, "blocked_by" => [%{"identifier" => "MT-BLOCKER"}]}} =
             json_response(get(build_conn(), "/api/v1/MT-WAIT"), 200)

    refute Map.has_key?(json_response(get(build_conn(), "/api/v1/MT-RETRY"), 200), "connected")
    assert %{"status" => "untracked"} = untracked = json_response(get(build_conn(), "/api/v1/MT-GONE"), 200)
    refute Map.has_key?(untracked, "connected")
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

    # The web dashboard is gone: its pages answer the API's 404.
    for path <- ["/", "/audit", "/quality", "/learnings", "/repos/default/issues/MT-1/transcript", "/issues/MT-1/transcript", "/dashboard.css"] do
      assert json_response(get(build_conn(), path), 404) ==
               %{"error" => %{"code" => "not_found", "message" => "Route not found"}}
    end

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

  test "the inbox api lists what waits on you from Symphony's cache, without a Linear request" do
    test_pid = self()
    inbox = {:test, make_ref()}

    plan = %{
      "id" => "issue-MT-PLAN",
      "identifier" => "MT-PLAN",
      "title" => "Plan the export",
      "url" => "https://linear.app/example/issue/MT-PLAN",
      "state" => %{"name" => "Plan Review"},
      "labels" => %{"nodes" => [%{"name" => "plan"}]},
      "children" => %{"nodes" => []},
      "comments" => %{"nodes" => []},
      "history" => %{"nodes" => [%{"createdAt" => "2026-10-01T10:00:00Z", "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => "Plan Review"}}]}
    }

    linear_client = fn query, _variables, _opts ->
      send(test_pid, {:linear, query})

      if query =~ "SymphonyInboxList",
        do: {:ok, %{"data" => %{"issues" => %{"nodes" => [%{"id" => "issue-MT-PLAN", "updatedAt" => "2026-10-01T10:00:00Z"}]}}}},
        else: {:ok, %{"data" => %{"issues" => %{"nodes" => [plan]}}}}
    end

    SymphonyElixir.Inbox.run_once(%{
      opts: [
        name: inbox,
        repos: fn -> {:ok, [%{name: "default"}]} end,
        settings_fun: fn _repo -> Config.settings!() end,
        scope_filter: fn _repo -> {:ok, %{}} end,
        linear_client: linear_client
      ],
      nodes: %{},
      timer: nil
    })

    assert_received {:linear, _list_query}
    assert_received {:linear, _detail_query}
    assert_received {:linear, _references_query}

    held = %{
      kind: :clarification,
      issue_id: "issue-MT-HELD",
      repo_key: "default",
      identifier: "MT-HELD",
      title: "Vague",
      state: "Todo",
      url: "https://linear.app/example/issue/MT-HELD",
      score: 3,
      reason: "No acceptance criteria.",
      rounds_asked: 1,
      max_rounds: 2,
      pass_threshold: 6,
      questions: ["What should it do?"],
      scored_at: ~U[2026-10-01 09:00:00Z]
    }

    orchestrator_name = Module.concat(__MODULE__, :InboxOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: Map.put(static_snapshot(), :awaiting_clarification, [held]))
    start_test_endpoint(orchestrator: orchestrator_name, inbox: inbox, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/inbox"), 200)
    state = json_response(get(build_conn(), "/api/v1/state"), 200)
    refute_received {:linear, _query}

    assert %{
             "counts" => %{"total" => 2, "pr" => 0, "clarify" => 1, "plan" => 1, "action" => 0},
             "items" => [
               %{
                 "identifier" => "MT-HELD",
                 "kind" => "clarify",
                 "ask" => "Answer the quality gate's questions",
                 "waiting_since" => "2026-10-01T09:00:00Z",
                 "review" => %{"held" => true, "score" => 3, "round" => 1, "max_rounds" => 2, "questions" => ["What should it do?"]}
               },
               %{
                 "issue_id" => "issue-MT-PLAN",
                 "identifier" => "MT-PLAN",
                 "title" => "Plan the export",
                 "repo_key" => "default",
                 "kind" => "plan",
                 "state" => "Plan Review",
                 "ask" => "Approve the plan",
                 "waiting_since" => "2026-10-01T10:00:00Z",
                 "waiting_seconds" => waiting_seconds,
                 "url" => "https://linear.app/example/issue/MT-PLAN",
                 "review" => %{"brief" => nil, "sub_tickets" => []}
               }
             ]
           } = payload

    assert waiting_seconds > 0
    assert state["counts"]["waiting_on_you"] == 2
    assert state["inbox_read"]
    assert Enum.map(state["waiting_on_you"], & &1["kind"]) == ["clarify", "plan"]

    assert json_response(post(build_conn(), "/api/v1/inbox", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}
  end

  test "the initiatives api lists plan tickets from Symphony's cache, without a Linear request" do
    test_pid = self()
    initiatives = {:test, make_ref()}
    inbox = {:test, make_ref()}

    child = fn identifier, state, type, extra ->
      Map.merge(
        %{
          "id" => "issue-" <> identifier,
          "identifier" => identifier,
          "title" => "Part " <> identifier,
          "url" => "https://linear.app/example/issue/" <> identifier,
          "createdAt" => "2026-10-01T10:00:00Z",
          "state" => %{"name" => state, "type" => type},
          "inverseRelations" => %{"nodes" => []}
        },
        extra
      )
    end

    blocked_by = fn identifier ->
      %{"inverseRelations" => %{"nodes" => [%{"type" => "blocks", "issue" => %{"identifier" => identifier, "state" => %{"name" => "Plan Review", "type" => "started"}}}]}}
    end

    plan = fn identifier, state, type, children, extra ->
      Map.merge(
        %{
          "id" => "issue-" <> identifier,
          "identifier" => identifier,
          "title" => "Plan " <> identifier,
          "url" => "https://linear.app/example/issue/" <> identifier,
          "completedAt" => nil,
          "state" => %{"name" => state, "type" => type},
          "children" => %{"nodes" => children}
        },
        extra
      )
    end

    nodes = [
      plan.("MT-DONE", "Done", "completed", [], %{"completedAt" => DateTime.utc_now() |> DateTime.to_iso8601()}),
      plan.("MT-REVIEW", "Plan Review", "started", [], %{}),
      plan.(
        "MT-PLAN",
        "Waiting on sub-tickets",
        "started",
        [
          child.("MT-3", "Todo", "unstarted", Map.merge(%{"createdAt" => "2026-10-01T09:00:00Z"}, blocked_by.("MT-2"))),
          child.("MT-2", "Plan Review", "started", %{}),
          child.("MT-HTTP", "In Progress", "started", %{"id" => "issue-http"})
        ],
        %{}
      ),
      plan.("MT-QUEUED", "Waiting on sub-tickets", "started", [], %{})
    ]

    linear_client = fn query, _variables, _opts ->
      send(test_pid, {:linear, query})
      {:ok, %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}}}
    end

    SymphonyElixir.Initiatives.run_once(%{
      opts: [
        name: initiatives,
        repos: fn -> {:ok, [%{name: "default"}]} end,
        settings_fun: fn _repo -> Config.settings!() end,
        scope_filter: fn _repo -> {:ok, %{}} end,
        linear_client: linear_client
      ],
      timer: nil
    })

    assert_received {:linear, _query}

    lanes = %{
      max_total: 2,
      lanes: [%{issue_id: "issue-MT-PLAN", identifier: "MT-PLAN", status: "running", sub_issue: %{identifier: "MT-HTTP"}}],
      queued_epics: [%{issue_id: "issue-MT-QUEUED", identifier: "MT-QUEUED"}],
      shared: %{slots: 1, used: 0}
    }

    orchestrator_name = Module.concat(__MODULE__, :InitiativesOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: Map.put(static_snapshot(), :epic_lanes, lanes))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      initiatives: initiatives,
      inbox: inbox,
      snapshot_timeout_ms: 50
    )

    payload = json_response(get(build_conn(), "/api/v1/initiatives"), 200)
    refute_received {:linear, _query}

    assert %{"read" => true, "counts" => %{"active" => 2, "in_review" => 1, "done" => 1}, "initiatives" => listed} = payload
    assert Enum.map(listed, & &1["identifier"]) == ["MT-PLAN", "MT-QUEUED", "MT-REVIEW", "MT-DONE"]

    assert %{
             "issue_id" => "issue-MT-PLAN",
             "title" => "Plan MT-PLAN",
             "state" => "Waiting on sub-tickets",
             "repo_key" => "default",
             "url" => "https://linear.app/example/issue/MT-PLAN",
             "group" => "active",
             "counts" => %{"done" => 0, "working" => 1, "you" => 1, "queued" => 0, "blocked" => 1, "total" => 3},
             "slot" => %{"status" => "running", "identifier" => "MT-HTTP", "reason" => nil},
             "sub_tickets" => [
               %{"identifier" => "MT-2", "waits_on" => "you", "blocked_by" => [], "waiting_for" => []},
               %{"identifier" => "MT-3", "waits_on" => "blocker", "blocked_by" => ["MT-2"], "waiting_for" => ["MT-2"]},
               %{"identifier" => "MT-HTTP", "waits_on" => "working"}
             ]
           } = hd(listed)

    assert %{"slot" => %{"status" => "queued", "position" => 1}} = Enum.at(listed, 1)
    refute Map.has_key?(hd(listed), "final_verification")
    assert %{"slot" => nil} = Enum.at(listed, 2)

    assert json_response(post(build_conn(), "/api/v1/initiatives", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    no_lanes = Module.concat(__MODULE__, :InitiativesNoLanesOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: no_lanes, snapshot: Map.delete(static_snapshot(), :epic_lanes))

    assert %{initiatives: [%{slot: nil} | _rest]} =
             SymphonyElixirWeb.Presenter.initiatives_payload(no_lanes, 50, initiatives, inbox)

    assert %{error: %{code: "snapshot_unavailable"}} =
             SymphonyElixirWeb.Presenter.initiatives_payload(Module.concat(__MODULE__, :NoInitiatives), 50, initiatives)

    timeout_orchestrator = Module.concat(__MODULE__, :InitiativesTimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    assert %{error: %{code: "snapshot_timeout"}} = SymphonyElixirWeb.Presenter.initiatives_payload(timeout_orchestrator, 1, initiatives)
  end

  test "the inbox api returns a decision's what-waits, trade-offs and why recommended, and no time estimate" do
    inbox = {:test, make_ref()}

    body =
      Request.render_hold(
        %{
          title: "Leave the old text to TP-891",
          question: "Should TP-892 (Retire two old review steps) leave the old text to TP-891?",
          why: "Code Review sent PR #448 back a second time.",
          if_unanswered: "TP-892 stays in Rework.",
          options: [
            %{label: "Leave it to TP-891", effect: "TP-892 goes back to Code Review.", recommended: true, tradeoffs: [%{kind: "good", text: "TP-892 can merge today."}]},
            %{label: "Remove it now", effect: "The next run deletes the old text."}
          ],
          recommendation_reason: "It is one line of text."
        },
        "Rework"
      )

    action = %{
      "id" => "issue-TP-892",
      "identifier" => "TP-892",
      "title" => "Retire two old review steps",
      "url" => "https://linear.app/example/issue/TP-892",
      "state" => %{"name" => "Rework"},
      "labels" => %{"nodes" => [%{"name" => "Needs Decision"}]},
      "children" => %{"nodes" => []},
      "comments" => %{"nodes" => [%{"id" => "comment-1", "body" => body, "createdAt" => "2026-10-01T10:00:00Z"}]},
      "history" => %{"nodes" => []}
    }

    linear_client = fn query, _variables, _opts ->
      if query =~ "SymphonyInboxList",
        do: {:ok, %{"data" => %{"issues" => %{"nodes" => [%{"id" => "issue-TP-892", "updatedAt" => "2026-10-01T10:00:00Z"}]}}}},
        else: {:ok, %{"data" => %{"issues" => %{"nodes" => [action]}}}}
    end

    SymphonyElixir.Inbox.run_once(%{
      opts: [
        name: inbox,
        repos: fn -> {:ok, [%{name: "default"}]} end,
        settings_fun: fn _repo -> Config.settings!() end,
        scope_filter: fn _repo -> {:ok, %{}} end,
        linear_client: linear_client
      ],
      nodes: %{},
      timer: nil
    })

    orchestrator_name = Module.concat(__MODULE__, :InboxDecisionOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, inbox: inbox, snapshot_timeout_ms: 50)

    assert %{"items" => [%{"identifier" => "TP-892", "kind" => "action", "review" => review}]} = json_response(get(build_conn(), "/api/v1/inbox"), 200)

    assert %{
             "if_unanswered" => "TP-892 stays in Rework.",
             "recommendation_reason" => "It is one line of text.",
             "options" => [
               %{"label" => "Leave it to TP-891", "recommended" => true, "tradeoffs" => [%{"kind" => "good", "text" => "TP-892 can merge today."}]},
               %{"label" => "Remove it now", "recommended" => false, "tradeoffs" => []}
             ]
           } = review

    refute Map.has_key?(review, "est_minutes")
  end

  # TP-892 waits on a decision that mentions TP-891 and #448; TP-923 is its parent, a plan in review
  # whose brief mentions TP-947; TP-894 waits on its merge confirmation (#450); TP-900 is blocked
  # and TP-901 held by the quality gate, both mentioning TP-891.
  defp inbox_mentions_fixture(opts) do
    {inbox, orchestrator_name} = inbox_mentions_poll(opts)
    start_test_endpoint(orchestrator: orchestrator_name, inbox: inbox, snapshot_timeout_ms: 50)
    json_response(get(build_conn(), "/api/v1/inbox"), 200)
  end

  defp inbox_mentions_poll(opts) do
    request =
      Request.render_hold(
        %{
          title: "Leave the old review text to TP-891",
          question: "Should TP-892 leave the old review text to TP-891?",
          why: "Code Review sent PR #448 back a second time over text TP-891 removes anyway.",
          if_unanswered: "TP-892 stays in Rework.",
          options: [
            %{label: "Leave it to TP-891", effect: "TP-892 goes back to Code Review.", recommended: true},
            %{label: "Remove it now", effect: "The next run deletes the old text."}
          ],
          recommendation_reason: "TP-891 removes it within the week."
        },
        "Rework"
      )

    node = fn identifier, attrs ->
      Map.merge(
        %{
          "id" => "issue-" <> identifier,
          "identifier" => identifier,
          "title" => "Title of " <> identifier,
          "url" => "https://linear.app/example/issue/" <> identifier,
          "state" => %{"name" => "In Progress"},
          "labels" => %{"nodes" => []},
          "children" => %{"nodes" => []},
          "comments" => %{"nodes" => []},
          "history" => %{"nodes" => []}
        },
        attrs
      )
    end

    action =
      node.("TP-892", %{
        "state" => %{"name" => "Rework"},
        "labels" => %{"nodes" => [%{"name" => "Needs Decision"}]},
        "comments" => %{
          "nodes" => [
            %{"id" => "earlier", "body" => String.replace(request, "Leave the old review text to TP-891", "Keep the old step"), "createdAt" => "2026-10-13T05:00:00Z"},
            %{"id" => "answer", "body" => "Keep it", "createdAt" => "2026-10-13T05:48:00Z", "parent" => %{"id" => "earlier"}},
            %{"id" => "request", "body" => request, "createdAt" => "2026-10-13T09:00:00Z"}
          ]
        }
      })

    merge =
      node.("TP-894", %{
        "state" => %{"name" => "QA"},
        "labels" => %{"nodes" => [%{"name" => "Needs Decision"}]},
        "comments" => %{"nodes" => [%{"id" => "merge", "body" => String.replace(request, "PR #448", "PR #450"), "createdAt" => "2026-10-13T08:00:00Z"}]}
      })

    plan =
      node.("TP-923", %{
        "state" => %{"name" => "Plan Review"},
        "labels" => %{"nodes" => [%{"name" => "plan"}]},
        "comments" => %{
          "nodes" => [%{"id" => "brief", "body" => "## Review brief\n\n**What to review:** the plan.\n\n- TP-947: decisions in your words.\n", "createdAt" => "2026-10-13T07:00:00Z"}]
        }
      })

    blocked = node.("TP-900", %{"labels" => %{"nodes" => [%{"name" => "Blocked"}]}})
    nodes = [action, merge, plan, blocked]

    children = for type <- ~w(completed completed completed completed started unstarted backlog), do: %{"createdAt" => "2026-10-12T00:00:00Z", "state" => %{"type" => type}}

    own_892 = %{
      "id" => "issue-TP-892",
      "identifier" => "TP-892",
      "parent" => %{"identifier" => "TP-923", "title" => "Improve decision handling", "children" => %{"nodes" => children}},
      "attachments" => %{"nodes" => [%{"url" => "https://github.com/example/app/pull/448"}]},
      "relations" => %{"nodes" => [%{"type" => "related", "relatedIssue" => %{"identifier" => "TP-891", "title" => "Remove the retired review states", "state" => %{"name" => "In Progress"}}}]},
      "inverseRelations" => %{"nodes" => []}
    }

    ticket = fn identifier, title, state, type ->
      %{
        "id" => "issue-" <> identifier,
        "identifier" => identifier,
        "title" => title,
        "description" => "Remove the review states nobody uses. The [old flows](https://example.com) go too.",
        "url" => "https://linear.app/example/issue/" <> identifier,
        "state" => %{"name" => state, "type" => type},
        "parent" => %{"identifier" => "TP-923", "title" => "Improve decision handling"},
        "attachments" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    mentioned =
      [
        ticket.("TP-891", "Remove the retired review states", "In Progress", "started"),
        ticket.("TP-892", "Retire two old review steps", "Rework", "started"),
        ticket.("TP-947", "Write decisions in your words", "Done", "completed")
      ]
      |> Enum.reject(&(&1["identifier"] in Keyword.get(opts, :unreadable, [])))

    test_pid = self()

    linear_client = fn query, variables, _opts ->
      cond do
        query =~ "SymphonyInboxList" ->
          {:ok, %{"data" => %{"issues" => %{"nodes" => Enum.map(nodes, &%{"id" => &1["id"], "updatedAt" => "2026-10-13T09:00:00Z"})}}}}

        query =~ "SymphonyInboxIssues" ->
          {:ok, %{"data" => %{"issues" => %{"nodes" => Enum.filter(nodes, &(&1["id"] in variables.filter["id"]["in"]))}}}}

        query =~ "SymphonyInboxReferences" ->
          send(test_pid, :references_query)
          {:ok, %{"data" => %{"own" => %{"nodes" => [own_892]}, "mentioned" => %{"nodes" => mentioned}}}}
      end
    end

    pull_request = fn url ->
      if url in Keyword.get(opts, :unreadable, []) do
        {:error, {:gh_failed, ["pr", "view"], 1, "HTTP 502"}}
      else
        number = url |> String.split("/") |> List.last() |> String.to_integer()

        {:ok,
         %{
           number: number,
           url: url,
           title: "TP-892 Remove the Final verification and Supervisor check flows",
           body: "## This PR\n\nThe two retired review steps are gone. Nothing else changes.",
           state: "OPEN",
           review_decision: nil,
           changed_files: 14,
           additions: 120,
           deletions: 610,
           head_ref_name: "auto/TP-892",
           checks: "passed"
         }}
      end
    end

    merge_hold =
      SymphonyElixir.MergeConfirmation.attrs(SymphonyElixir.MergeConfirmation.request(%SymphonyElixir.Linear.Issue{identifier: "TP-894"}, %{recommendation: "merge", review: nil, qa: "pass", pr: nil}))

    blocked_hold = %{
      kind: :blocked,
      reason: "Waits on TP-891's fix to the review states",
      clearing_condition: "when a person unblocks it",
      waits_on: %{type: "access", keys: []},
      decision: nil,
      set_at: ~U[2026-10-13 06:00:00Z]
    }

    held = %{
      kind: :clarification,
      issue_id: "issue-TP-901",
      repo_key: "default",
      identifier: "TP-901",
      title: "Vague",
      state: "Todo",
      url: "https://linear.app/example/issue/TP-901",
      score: 3,
      reason: "Like TP-891, it has no acceptance criteria.",
      questions: [],
      scored_at: ~U[2026-10-13 04:00:00Z]
    }

    inbox = {:test, make_ref()}

    SymphonyElixir.Inbox.run_once(%{
      opts: [
        name: inbox,
        repos: fn -> {:ok, [%{name: "default"}]} end,
        settings_fun: fn _repo -> Config.settings!() end,
        scope_filter: fn _repo -> {:ok, %{}} end,
        linear_client: linear_client,
        snapshot: fn -> %{awaiting_clarification: [held]} end,
        github_repos: %{"default" => "example/app"},
        pull_request: pull_request,
        verdicts: fn
          "default", "issue-TP-892" -> [%{head_sha: "b", outcome: "request_changes"}, %{head_sha: "a", outcome: "request_changes"}]
          _repo_key, _issue_id -> []
        end,
        hold: fn
          _repo_key, "issue-TP-894" -> merge_hold
          _repo_key, "issue-TP-900" -> blocked_hold
          _repo_key, _issue_id -> nil
        end
      ],
      nodes: %{},
      timer: nil
    })

    assert_received :references_query
    refute_received :references_query

    orchestrator_name = Module.concat(__MODULE__, "InboxMentions#{System.unique_integer([:positive])}")
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: Map.put(static_snapshot(), :awaiting_clarification, [held]))
    {inbox, orchestrator_name}
  end

  defp inbox_item(payload, identifier), do: Enum.find(payload["items"], &(&1["identifier"] == identifier))

  test "the inbox api returns what each item mentions and where its ticket sits, for every kind" do
    payload = inbox_mentions_fixture([])

    assert Enum.map(payload["items"], &{&1["identifier"], &1["kind"]}) |> Enum.sort() ==
             [{"TP-892", "action"}, {"TP-894", "action"}, {"TP-900", "blocked"}, {"TP-901", "clarify"}, {"TP-923", "plan"}]

    for item <- payload["items"] do
      assert is_map(item["references"]), item["identifier"]
      assert %{"parent" => _, "pull_request" => _, "blocked_by" => _, "blocks" => _, "related" => _, "earlier_decisions" => _} = item["context"]
    end

    # 1. The decision's mentions: a ticket with its title, state and summary, and a pull request with
    # its review state, size and checks.
    action = inbox_item(payload, "TP-892")

    assert %{
             "kind" => "ticket",
             "identifier" => "TP-891",
             "title" => "Remove the retired review states",
             "repo_key" => "default",
             "state" => "In Progress",
             "summary" => "Remove the review states nobody uses.",
             "url" => "https://linear.app/example/issue/TP-891",
             "parent" => %{"identifier" => "TP-923", "title" => "Improve decision handling"},
             "pull_request" => nil,
             "waiting_on" => "a slot"
           } = action["references"]["TP-891"]

    refute Map.has_key?(action["references"]["TP-891"], "facts")

    assert %{
             "kind" => "pull_request",
             "number" => 448,
             "repo_key" => "default",
             "url" => "https://github.com/example/app/pull/448",
             "title" => "TP-892 Remove the Final verification and Supervisor check flows",
             "summary" => "The two retired review steps are gone.",
             "review_state" => "changes_requested",
             "review_rounds" => 2,
             "files" => 14,
             "additions" => 120,
             "deletions" => 610,
             "checks" => "passed",
             "ticket" => "TP-892"
           } = action["references"]["PR #448"]

    assert action["references"]["TP-892"]["waiting_on"] == "you"

    # 3. Where TP-892 sits: 4 of its parent's 7 sub-tickets done, its pull request sent back twice,
    # TP-891 connected, and the decision answered at 05:48.
    assert action["context"] == %{
             "parent" => %{
               "identifier" => "TP-923",
               "title" => "Improve decision handling",
               "done" => 4,
               "total" => 7,
               "children" => ~w(completed completed completed completed started unstarted backlog)
             },
             "pull_request" => %{"number" => 448, "url" => "https://github.com/example/app/pull/448", "checks" => "passed", "sent_back" => 2},
             "blocked_by" => [],
             "blocks" => [],
             "related" => [%{"identifier" => "TP-891", "title" => "Remove the retired review states", "state" => "In Progress"}],
             "earlier_decisions" => [%{"at" => "2026-10-13T05:48:00Z", "title" => "Keep the old step", "answer" => "Keep it"}]
           }

    # A pull request waiting on its merge confirmation, a plan, a blocked ticket and a held one.
    merge = inbox_item(payload, "TP-894")
    assert merge["review"]["confirm"] == "Merging"
    assert %{"kind" => "pull_request", "number" => 450} = merge["references"]["PR #450"]

    assert %{"TP-947" => %{"kind" => "ticket", "state" => "Done", "waiting_on" => nil}} = inbox_item(payload, "TP-923")["references"]
    assert %{"TP-891" => %{"kind" => "ticket"}} = inbox_item(payload, "TP-900")["references"]
    assert %{"TP-891" => %{"kind" => "ticket"}} = inbox_item(payload, "TP-901")["references"]
  end

  test "the inbox api returns a mention it can't read as missing and leaves the rest of the item as it was" do
    {inbox, orchestrator_name} = inbox_mentions_poll([])
    readable = orchestrator_name |> SymphonyElixirWeb.Presenter.inbox_payload(50, inbox) |> Jason.encode!() |> Jason.decode!()
    # 2. Linear can't read TP-891, and GitHub can't read #448.
    payload = inbox_mentions_fixture(unreadable: ["TP-891", "https://github.com/example/app/pull/448"])

    action = inbox_item(payload, "TP-892")
    assert action["references"]["TP-891"] == %{"kind" => "missing", "url" => "https://linear.app/example/issue/TP-891"}
    assert action["references"]["PR #448"] == %{"kind" => "missing", "url" => "https://github.com/example/app/pull/448"}

    # The context's pull request is #448 too: its checks are unknown, the rest of it stays.
    before = inbox_item(readable, "TP-892")
    assert action["context"]["pull_request"] == %{before["context"]["pull_request"] | "checks" => nil}
    before = put_in(before, ["context", "pull_request", "checks"], nil)
    assert Map.drop(action, ["references", "waiting_seconds"]) == Map.drop(before, ["references", "waiting_seconds"])
    assert Map.drop(action["references"], ["TP-891", "PR #448"]) == Map.drop(before["references"], ["TP-891", "PR #448"])
  end

  test "the inbox api says when the snapshot is unavailable or late, and lists an action's request time" do
    inbox = {:test, make_ref()}

    :persistent_term.put({SymphonyElixir.Inbox, :items, inbox}, [
      %{
        issue_id: "issue-MT-ACT",
        identifier: "MT-ACT",
        title: "Signing",
        repo_key: "default",
        kind: :action,
        state: "Human Review",
        ask: "Add the signing secret",
        waiting_since: nil,
        url: nil,
        review: %{title: "Add the signing secret", steps: ["Add it"], requested_at: ~U[2026-10-01 08:00:00.123Z]}
      }
    ])

    orchestrator_name = Module.concat(__MODULE__, :InboxActionOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

    assert %{items: [%{waiting_seconds: nil, review: %{requested_at: "2026-10-01T08:00:00Z"}}]} =
             SymphonyElixirWeb.Presenter.inbox_payload(orchestrator_name, 50, inbox)

    assert %{error: %{code: "snapshot_unavailable"}} = SymphonyElixirWeb.Presenter.inbox_payload(Module.concat(__MODULE__, :NoInbox), 50, inbox)

    timeout_orchestrator = Module.concat(__MODULE__, :InboxTimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    assert %{error: %{code: "snapshot_timeout"}} = SymphonyElixirWeb.Presenter.inbox_payload(timeout_orchestrator, 1, inbox)
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

  defmodule DrainTracker do
    def fetch_issues_by_states(_states), do: {:ok, Process.get(:drain_issues, [])}
    def fetch_issue_states_by_ids(_ids), do: {:ok, [%{id: "issue-gone", state: "Plan Review"}]}
  end

  test "the state api shows the drain report: stragglers with their wait, and where the gone ones landed" do
    on_exit(&RetiredStates.reset_for_test/0)
    RetiredStates.reset_for_test()

    Process.put(:drain_issues, [%{id: "issue-gone", identifier: "MT-GONE", state: "Human Review", labels: ["plan"]}])
    capture_log(fn -> RetiredStates.report(tracker: DrainTracker, now_ms: 0) end)

    Process.put(:drain_issues, [
      %{id: "issue-drain", identifier: "MT-DRAIN", title: "Old", url: "https://linear.app/example/issue/MT-DRAIN", state: "In Review", labels: []},
      %{id: "issue-nourl", identifier: nil, state: "Human Review", labels: []}
    ])

    capture_log(fn -> RetiredStates.report(tracker: DrainTracker, now_ms: 1) end)

    orchestrator_name = Module.concat(__MODULE__, :DrainOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{
             "stragglers" => [
               %{"issue_identifier" => "MT-DRAIN", "state" => "In Review", "wait" => "supervisor_check", "waits_on" => "a supervisor check of its PR"},
               %{"issue_identifier" => "issue-nourl", "wait" => "open_decision", "url" => nil}
             ],
             "landed" => [%{"issue_identifier" => "MT-GONE", "from" => "Human Review", "to" => "Plan Review"}]
           } = json_response(get(build_conn(), "/api/v1/state"), 200)["drain_report"]
  end

  test "the state api lists what waits on you, oldest first, without tickets that left review" do
    now = DateTime.utc_now()

    entry = fn identifier, kind, hours_ago, ask ->
      %{
        issue_id: "issue-" <> identifier,
        identifier: identifier,
        title: "Title of " <> identifier,
        repo_key: "default",
        url: "https://linear.app/example/issue/" <> identifier,
        state: "Plan Review",
        kind: kind,
        waiting_since: hours_ago && DateTime.add(now, -hours_ago * 3_600, :second),
        ask: ask,
        review: %{}
      }
    end

    inbox = {:test, make_ref()}

    :persistent_term.put({SymphonyElixir.Inbox, :items, inbox}, [
      entry.("MT-PR", :action, 1, "The retry fix"),
      entry.("MT-UNKNOWN", :blocked, nil, nil),
      entry.("MT-PLAN", :plan, 3, "The split into four sub-tickets"),
      entry.("MT-ACTION", :action, 2, nil),
      entry.("MT-APPROVED", :plan, 4, "Approved already"),
      entry.("MT-HTTP", :pr, 5, "Running again")
    ])

    approved = %{
      issue_id: "issue-MT-APPROVED",
      repo_key: "default",
      identifier: "MT-APPROVED",
      state: "Waiting on sub-tickets",
      url: nil,
      last_ran_at: nil,
      seconds_since_last_run: nil
    }

    in_review = %{approved | issue_id: "issue-MT-PR", identifier: "MT-PR", state: "Plan Review"}
    snapshot = static_snapshot()
    snapshot = %{snapshot | watching: snapshot.watching ++ [approved, in_review], running: Enum.map(snapshot.running, &%{&1 | issue_id: "issue-MT-HTTP"})}
    orchestrator_name = Module.concat(__MODULE__, :WaitingOnYouOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll"]}
      )

    start_test_endpoint(orchestrator: orchestrator_name, inbox: inbox, snapshot_timeout_ms: 50)

    waiting = json_response(get(build_conn(), "/api/v1/state"), 200)["waiting_on_you"]
    assert Enum.map(waiting, & &1["issue_identifier"]) == ["MT-PLAN", "MT-ACTION", "MT-PR", "MT-UNKNOWN"]

    assert [
             %{
               "issue_id" => "issue-MT-PLAN",
               "title" => "Title of MT-PLAN",
               "url" => "https://linear.app/example/issue/MT-PLAN",
               "state" => "Plan Review",
               "kind" => "plan",
               "headline" => "The split into four sub-tickets",
               "waiting_since" => waiting_since,
               "waiting_seconds" => waiting_seconds
             },
             %{"kind" => "action", "headline" => nil},
             %{"kind" => "action", "state" => "Plan Review", "headline" => "The retry fix"},
             %{"kind" => "blocked", "waiting_since" => nil, "waiting_seconds" => nil}
           ] = waiting

    assert is_binary(waiting_since)
    assert waiting_seconds in 10_799..10_860
  end

  test "the state api shows each repository's GitHub webhook delivery health" do
    webhooks = %{
      enabled: true,
      relay: "smee",
      last_event_at: DateTime.add(DateTime.utc_now(), -90, :second),
      events_received: 12,
      rejected: 1,
      results_via_webhook: 3,
      results_via_poll: 2,
      repos: %{
        "default" => %{
          healthy: false,
          silent: false,
          last_delivery_at: ~U[2026-10-16 11:58:00Z],
          signature_failures_24h: 1,
          missed: 2,
          missed_at: ~U[2026-10-16 11:59:00Z]
        }
      }
    }

    ci = %{status: :running, consecutive_failures: 0, current_backoff_ms: nil, poll_interval_ms: 60_000}
    ci = Map.put(ci, :webhooks, webhooks)
    orchestrator_name = Module.concat(__MODULE__, :WebhooksActiveOrchestrator)
    snapshot = Map.put(static_snapshot(), :pollers, %{ci: ci, pr_review: :unavailable})
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"pollers" => %{"ci" => %{"webhooks" => %{"repos" => %{"default" => health}}}}} = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert health == %{
             "healthy" => false,
             "silent" => false,
             "last_delivery_at" => "2026-10-16T11:58:00Z",
             "signature_failures_24h" => 1,
             "missed" => 2,
             "missed_at" => "2026-10-16T11:59:00Z"
           }
  end

  test "state api shows Linear requests per caller for the last hour" do
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

  test "state api lists stray processes until they are gone" do
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

    assert json_response(get(build_conn(), "/api/v1/state"), 200)["stray_processes"] == [
             %{"pid" => 4243, "command" => "#{idle}/bin/spin", "cwd" => nil, "cpu_time" => "20:00.00", "cpu_seconds" => 1_200},
             %{"pid" => 4242, "command" => "yes", "cwd" => idle, "cpu_time" => "10:01.00", "cpu_seconds" => 601}
           ]

    Agent.update(table, fn _entries -> {:ok, []} end)
    capture_log(fn -> assert [] = StrayProcesses.check(stray_name) end)

    assert json_response(get(build_conn(), "/api/v1/state"), 200)["stray_processes"] == []
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

  test "state api tolerates snapshots with partial codex totals" do
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
  end

  test "http server starts on an ephemeral port by default" do
    orchestrator_name = Module.concat(__MODULE__, :DefaultPortOrchestrator)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: static_snapshot()})
    start_supervised!({HttpServer, [orchestrator: orchestrator_name, snapshot_timeout_ms: 50]})

    port = wait_for_bound_port()
    assert is_integer(port)
    assert port > 0
  end

  test "http server serves the API, has no web page, accepts form posts, and rejects invalid hosts" do
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

    assert response.body["counts"] == %{
             "running" => 1,
             "watching" => 1,
             "conflicts" => 0,
             "retrying" => 1,
             "claimed" => 2,
             "forced" => 2,
             "shipped_today" => 1,
             "waiting_on_you" => 0,
             "review_inconclusive" => %{"invalid_verdict" => 1}
           }

    root = Req.get!("http://127.0.0.1:#{port}/")
    assert root.status == 404
    assert root.body["error"]["code"] == "not_found"

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
          tokens: %{input_tokens: 4, output_tokens: 8, total_tokens: 12},
          review_inconclusive_cause: "invalid_verdict"
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
      landing_waits: [
        %{
          issue_id: "follow-http",
          issue_identifier: "MT-FOLLOW",
          pr_url: "https://github.com/acme/repo/pull/10",
          state: "QA",
          waits_for: %{issue_id: "merge-http", issue_identifier: "MT-MERGE", pr_url: "https://github.com/acme/repo/pull/9", state: "Merging"},
          shared_files: 2,
          files: ["lib/a.ex", "lib/b.ex"],
          reason: "waits for MT-MERGE to land (shares 2 files)",
          since: ~U[2026-10-03 06:00:00Z]
        }
      ],
      claimed: ["issue-http", "retry-http"],
      slot_waiting: [
        %{
          issue_id: "wait-http",
          identifier: "MT-WAIT",
          title: "Waiting",
          state: "Todo",
          reason: "a Merging issue is waiting for a slot",
          attempt: nil,
          since: ~U[2026-10-03 06:00:00Z],
          repo_key: "default"
        }
      ],
      dispatch_skipped: [
        %{
          issue_id: "skip-http",
          identifier: "MT-SKIP",
          title: "Skipped",
          state: "Todo",
          repo_key: "default",
          reason: "priority medium is not in tickets.priorities (urgent, high)",
          since: ~U[2026-10-03 06:00:00Z]
        }
      ],
      shipped_today: [
        %{
          issue_id: "shipped-http",
          identifier: "MT-SHIPPED",
          title: "Shipped",
          repo_key: "default",
          completed_at: ~U[2026-10-03 07:00:00Z]
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
          repo_key: "web",
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
