defmodule SymphonyElixir.OrchestratorFinishingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.QaRunner

  @active_states ["Todo", "In Progress", "Merging", "Rework", "Auto Review", "Waiting on sub-tickets"]
  @hold_reason "a Merging or Auto Review issue is waiting for a slot"

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-finishing-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-finishing","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-finishing","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      File.rm_rf(test_root)
    end)

    ctx = %{test_root: test_root, fake_claude: fake_claude}
    write_finishing_workflow!(ctx)
    ctx
  end

  test "a ticket moved to Merging lands at once while both work slots run implementation work", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2)
    landing = issue("land-1", "MT-LAND", "Merging")
    tracked([landing])

    state =
      orchestrator_state(2)
      |> run(issue("impl-1", "MT-1", "In Progress"), :implementation)
      |> run(issue("impl-2", "MT-2", "In Progress"), :implementation)

    refute Orchestrator.should_dispatch_issue_for_test(issue("todo-1", "MT-3", "Todo"), state)

    log = capture_log(fn -> send(self(), {:state, Orchestrator.dispatch_chosen_issues_for_test([landing], state)}) end)
    assert_received {:state, state}

    assert %{run_profile: %{kind: :landing}} = state.running["land-1"]
    assert log =~ ~r/Dispatching issue to agent: issue_id=land-1 .* slot=finishing/
    assert state.slot_waiting == %{}

    assert %{finishing: %{slots: 2, used: 1, running: [%{identifier: "MT-LAND", state: "Merging"}]}} = snapshot_of(state)
  end

  test "with finishing_max 1 a second Merging ticket waits and no Todo starts until it does", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2, finishing_max: 1)
    second_landing = issue("land-2", "MT-LAND-2", "Merging")
    todo = issue("todo-1", "MT-TODO", "Todo", priority: 1)
    tracked([second_landing, todo])

    state = run(orchestrator_state(2), issue("land-1", "MT-LAND-1", "Merging"), :landing)

    state = Orchestrator.dispatch_chosen_issues_for_test([todo, second_landing, :not_an_issue], state)

    assert Map.keys(state.running) == ["land-1"]
    assert %{reason: "finishing slots full", state: "Merging"} = state.slot_waiting["land-2"]
    assert %{reason: @hold_reason, state: "Todo"} = state.slot_waiting["todo-1"]

    assert [%{issue_id: "land-2", reason: "finishing slots full"}, %{issue_id: "todo-1", reason: @hold_reason}] =
             state |> snapshot_of() |> Map.fetch!(:slot_waiting) |> Enum.sort_by(& &1.issue_id)

    # The landing run ends: the second landing starts, and only then the Todo ticket.
    state = %{state | running: Map.delete(state.running, "land-1")}

    log =
      capture_log(fn ->
        send(self(), {:state, Orchestrator.dispatch_chosen_issues_for_test([todo, second_landing], state)})
      end)

    assert_received {:state, state}

    assert Enum.sort(Map.keys(state.running)) == ["land-2", "todo-1"]
    assert state.slot_waiting == %{}
    assert dispatch_order(log) == ["land-2", "todo-1"]
  end

  test "a Merging ticket held for CI neither lands nor waits for a slot, and a Todo still starts", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2)
    held = issue("land-1", "MT-HELD", "Merging")
    todo = issue("todo-1", "MT-TODO", "Todo")
    tracked([held, todo])

    hold = %{
      identifier: "MT-HELD",
      title: "Ticket MT-HELD",
      repo_key: nil,
      pull_request_url: "https://github.com/acme/repo/pull/1",
      commit_sha: "abc123",
      since: DateTime.utc_now()
    }

    state = %{orchestrator_state(2) | merging_ci_waits: %{"land-1" => hold}}

    refute Orchestrator.should_dispatch_issue_for_test(held, state)

    state = Orchestrator.dispatch_chosen_issues_for_test([held, todo], state)

    assert Map.keys(state.running) == ["todo-1"]
    assert state.slot_waiting == %{}

    assert [%{issue_id: "land-1", state: "Merging", reason: "waiting for CI on abc123", attempt: nil}] =
             state |> snapshot_of() |> Map.fetch!(:slot_waiting)
  end

  test "with GitHub auto-merge on, a Merging ticket with a PR takes no slot and no agent", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2, pr_review_mode: "polling")
    landing = issue("land-1", "MT-LAND", "Merging", pr_urls: ["https://github.com/acme/repo/pull/1"])
    todo = issue("todo-1", "MT-TODO", "Todo")
    tracked([landing, todo])

    refute Orchestrator.should_dispatch_issue_for_test(landing, orchestrator_state(2))
    refute Orchestrator.dispatch_revalidated_issue_for_test(landing, false)
    refute Orchestrator.dispatch_revalidated_issue_for_test(landing, true)

    state = Orchestrator.dispatch_chosen_issues_for_test([landing, todo], orchestrator_state(2))

    assert Map.keys(state.running) == ["todo-1"]
    assert state.slot_waiting == %{}

    :ok =
      RunStore.put_pr_review(%{
        repo_key: "default",
        issue_id: "land-1",
        issue_identifier: "MT-LAND",
        pr_url: "https://github.com/acme/repo/pull/1",
        auto_merge: %{state: "enabled", head_sha: "abc1234def", updated_at: ~U[2026-10-03 12:00:00Z]}
      })

    assert [%{issue_identifier: "MT-LAND", state: "enabled", status: "auto-merge on, waiting for CI on `abc1234`"}] =
             snapshot_of(state).auto_merge

    # The PR poller fell back (auto-merge couldn't be enabled): the landing agent runs.
    :ok = RunStore.update_pr_review("default", "land-1", %{auto_merge: %{state: "fallback", reason: "not allowed"}})

    state = Orchestrator.dispatch_chosen_issues_for_test([landing], %{state | running: %{}})
    assert %{run_profile: %{kind: :landing}} = state.running["land-1"]
  end

  test "with GitHub auto-merge on, a Merging ticket without a PR still gets the landing agent", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2, pr_review_mode: "polling")
    landing = issue("land-1", "MT-LAND", "Merging")
    tracked([landing])

    assert Orchestrator.should_dispatch_issue_for_test(landing, orchestrator_state(2))
  end

  test "a resume of Medium priority goes before an Urgent Todo when a slot frees", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 1)
    resume = issue("resume-1", "MT-RESUME", "In Progress", priority: 3)
    urgent = issue("todo-1", "MT-URGENT", "Todo", priority: 1)
    tracked([resume, urgent])

    state = Orchestrator.dispatch_chosen_issues_for_test([urgent, resume], orchestrator_state(1))

    assert Map.keys(state.running) == ["resume-1"]
    assert %{reason: "work slots full"} = state.slot_waiting["todo-1"]
  end

  test "candidates sort by stage before priority and age" do
    issues = [
      issue("todo", "MT-1", "Todo", priority: 1),
      issue("progress", "MT-2", "In Progress", priority: 4),
      issue("rework", "MT-3", "Rework", priority: 4),
      issue("review", "MT-4", "Auto Review", priority: 4),
      issue("merging", "MT-5", "Merging", priority: 4),
      issue("merging-urgent", "MT-6", "Merging", priority: 1)
    ]

    assert issues |> Orchestrator.sort_issues_for_dispatch_for_test() |> Enum.map(& &1.id) ==
             ["merging-urgent", "merging", "review", "rework", "progress", "todo"]
  end

  test "a retry waiting for a slot keeps attempt 1 and starts on the first poll after a slot frees", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 1)
    waiting = issue("wait-1", "MT-WAIT", "In Progress")
    tracked([waiting])
    full = run(%{orchestrator_state(1) | claimed: MapSet.new(["wait-1"])}, issue("impl-1", "MT-1", "In Progress"), :implementation)
    metadata = %{identifier: "MT-WAIT", repo_key: "default"}

    {:noreply, state} = Orchestrator.handle_retry_issue_for_test(full, "wait-1", 1, metadata, fn ["wait-1"] -> {:ok, [waiting]} end)

    assert %{attempt: 1, reason: "no available orchestrator slots"} = state.slot_waiting["wait-1"]
    assert state.retry_attempts == %{}
    refute MapSet.member?(state.claimed, "wait-1")

    # Polls while the slot is still taken leave it waiting, attempt unchanged.
    state = Orchestrator.dispatch_chosen_issues_for_test([waiting], state)
    assert %{attempt: 1, reason: "work slots full"} = state.slot_waiting["wait-1"]
    assert state.retry_attempts == %{}

    state = Orchestrator.dispatch_chosen_issues_for_test([waiting], %{state | running: %{}})

    assert %{retry_attempt: 1} = state.running["wait-1"]
    assert state.slot_waiting == %{}
  end

  test "a retry deferred behind a dispatch readiness task waits for a slot without backoff", ctx do
    write_finishing_workflow!(ctx, poll_interval_ms: 600_000)
    tracked([issue("wait-1", "MT-WAIT", "In Progress")])
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :Readiness))
    on_exit(fn -> if Process.alive?(pid), do: stop_process(pid) end)

    token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | dispatch_readiness_tasks: %{make_ref() => %{kind: :poll, issues: []}},
          retry_attempts: %{"wait-1" => %{attempt: 3, retry_token: token, identifier: "MT-WAIT", repo_key: "default"}},
          claimed: MapSet.new(["wait-1"])
      }
    end)

    send(pid, {:retry_issue, "wait-1", token})
    state = :sys.get_state(pid)

    assert %{attempt: 3, reason: "dispatch readiness task already in flight"} = state.slot_waiting["wait-1"]
    assert state.retry_attempts == %{}
    refute MapSet.member?(state.claimed, "wait-1")
  end

  test "a standalone ticket in Merging lands when epic lanes take every work slot" do
    epics = for n <- 1..2, do: epic("e#{n}", "MT-#{n}0", [%{id: "p#{n}", identifier: "MT-#{n}1", state: "In Progress"}])
    landing = issue("land-1", "MT-LAND", "Merging")
    todo = issue("todo-1", "MT-TODO", "Todo")

    state = Orchestrator.put_epic_lanes_for_test(orchestrator_state(2), epics ++ [landing, todo])

    assert state.epic_lanes.shared == 0
    refute Orchestrator.should_dispatch_issue_for_test(todo, state)
    assert Orchestrator.should_dispatch_issue_for_test(landing, state)
  end

  test "an epic's lane starts its next part before a higher-priority grandchild", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2, epic_lanes: 1)
    part = issue("c1", "MT-C1", "Todo", priority: 3)
    parent = issue("p2", "MT-P2", "In Progress", sub_issues: [%{id: "g1", identifier: "MT-G1", state: "Todo"}])
    grandchild = issue("g1", "MT-G1", "Todo", priority: 1)
    standalone = issue("s1", "MT-S1", "Todo", priority: 2)
    epic = epic("e1", "MT-E1", [%{id: "c1", identifier: "MT-C1", state: "Todo"}, %{id: "p2", identifier: "MT-P2", state: "In Progress"}])
    tracked([part, grandchild, standalone])

    state = Orchestrator.put_epic_lanes_for_test(orchestrator_state(2), [epic, part, parent, grandchild, standalone])
    candidates = [grandchild, standalone, part]
    log = capture_log(fn -> send(self(), {:state, Orchestrator.dispatch_chosen_issues_for_test(candidates, state)}) end)
    assert_received {:state, state}

    assert dispatch_order(log) == ["c1", "s1"]
    assert log =~ ~r/issue_id=c1 .* slot=lane:MT-E1/
    assert %{reason: "work slots full"} = state.slot_waiting["g1"]
  end

  test "landing runs leave the work slots and lane snapshot to implementation work" do
    state =
      orchestrator_state(1)
      |> run(issue("land-1", "MT-LAND", "Merging"), :landing)
      |> Orchestrator.put_epic_lanes_for_test([])

    assert Orchestrator.should_dispatch_issue_for_test(issue("todo-1", "MT-TODO", "Todo"), state)
    assert %{epic_lanes: %{shared: %{used: 0}}, finishing: %{used: 1}} = snapshot_of(state)
  end

  test "a queued QA pass holds Todo work back but not resumes", ctx do
    write_finishing_workflow!(ctx)
    test_pid = self()

    start_supervised!(
      {QaRunner,
       run_fun: fn job, _opts ->
         send(test_pid, {:qa_started, job.issue.id})
         Process.sleep(:infinity)
       end}
    )

    settings = Config.settings!()
    job = %{issue: %{id: "review-1"}, record: %{}, sha: "abc", settings: put_in(settings.auto_review.max_concurrent, 1)}
    assert :started = QaRunner.request(job)
    assert :busy = QaRunner.request(%{job | issue: %{id: "review-2"}})
    assert QaRunner.queued() == ["review-2"]

    todo = issue("todo-1", "MT-TODO", "Todo", priority: 1)
    resume = issue("resume-1", "MT-RESUME", "In Progress")
    tracked([todo, resume])

    state = Orchestrator.dispatch_chosen_issues_for_test([todo, resume], orchestrator_state(3))

    assert Map.keys(state.running) == ["resume-1"]
    assert %{reason: @hold_reason} = state.slot_waiting["todo-1"]
  end

  test "finishing_max must be at least 1", ctx do
    write_finishing_workflow!(ctx, finishing_max: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "finishing_max"

    write_finishing_workflow!(ctx)
    assert Config.settings!().agent.finishing_max == 2

    changeset = Schema.Agent.changeset(%Schema.Agent{}, %{"kind" => "codex", "command" => "codex", "finishing_max" => 0})
    assert {"must be greater than %{number}", _} = changeset.errors[:finishing_max]
  end

  describe "a run ending while issues wait for a slot" do
    test "runs dispatch right away", ctx do
      {pid, ref} = start_with_waiting_run(ctx, poll_check_in_progress: false)

      send(pid, {:DOWN, ref, :process, self(), :normal})
      state = :sys.get_state(pid)

      assert is_integer(state.next_poll_due_at_ms)
      assert state.next_poll_due_at_ms <= System.monotonic_time(:millisecond) + 100
    end

    test "joins a poll already in progress", ctx do
      {pid, ref} = start_with_waiting_run(ctx, poll_check_in_progress: true)

      send(pid, {:DOWN, ref, :process, self(), :normal})
      state = :sys.get_state(pid)

      assert state.next_poll_due_at_ms == nil
    end
  end

  defp start_with_waiting_run(ctx, poll_check_in_progress: in_progress?) do
    write_finishing_workflow!(ctx, poll_interval_ms: 600_000)
    tracked([])
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "Down#{System.unique_integer([:positive])}"))
    on_exit(fn -> if Process.alive?(pid), do: stop_process(pid) end)

    ref = make_ref()
    running = issue("land-1", "MT-LAND", "Merging")
    waiting = %{identifier: "MT-WAIT", state: "Merging", reason: "finishing slots full", since: DateTime.utc_now()}

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        (run(state, running, :landing)
         |> put_in([Access.key(:running), "land-1", :ref], ref))
        | slot_waiting: %{"wait-1" => waiting},
          poll_check_in_progress: in_progress?,
          next_poll_due_at_ms: nil,
          tick_timer_ref: nil,
          tick_token: nil
      }
    end)

    {pid, ref}
  end

  defp write_finishing_workflow!(ctx, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          tracker_active_states: @active_states,
          tracker_terminal_states: ["Done", "Canceled"],
          workspace_root: Path.join(ctx.test_root, "workspaces"),
          agent_kind: "claude",
          agent_command: ctx.fake_claude,
          max_turns: 1,
          quality_gate: %{enabled: false}
        ],
        overrides
      )
    )
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp dispatch_order(log) do
    ~r/Dispatching issue to agent: issue_id=(\S+)/
    |> Regex.scan(log, capture: :all_but_first)
    |> List.flatten()
  end

  defp snapshot_of(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
  end

  defp issue(id, identifier, state, attrs \\ []) do
    struct!(
      %Issue{
        id: id,
        identifier: identifier,
        title: "Ticket #{identifier}",
        description: "Finish it",
        state: state,
        priority: 3,
        team: %{key: "Test"},
        labels: [],
        url: "https://example.org/issues/#{identifier}"
      },
      attrs
    )
  end

  defp epic(id, identifier, sub_issues) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Epic #{identifier}",
      state: "Waiting on sub-tickets",
      labels: ["breakdown"],
      priority: 2,
      sub_issues: sub_issues
    }
  end

  defp run(state, %Issue{} = issue, kind) do
    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      run_profile: %{kind: kind, model: nil, effort: nil, provider: "anthropic"},
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    %{state | running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)}
  end

  defp orchestrator_state(max_total) do
    %Orchestrator.State{
      repo_key: "default",
      max_concurrent_agents: max_total,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
