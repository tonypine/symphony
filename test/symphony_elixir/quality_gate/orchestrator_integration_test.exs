defmodule SymphonyElixir.QualityGate.OrchestratorIntegrationTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  defmodule PassProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(_issue, _settings), do: {:ok, %{score: 9, reason: "passes"}}
  end

  defmodule SkipProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(_issue, _settings), do: {:ok, %{score: 3, reason: "vague"}}
  end

  defmodule ClarificationProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(_issue, _settings) do
      {:ok,
       %{
         score: 5,
         reason: "missing acceptance criteria",
         questions: [
           "What should the agent verify before opening a PR?",
           "Which module should the agent change?",
           "What should stay out of scope?"
         ]
       }}
    end
  end

  defmodule ReplyAwareProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(issue, _settings) do
      answered? =
        Enum.any?(issue.comments, fn
          %{body: body} when is_binary(body) -> String.contains?(body, "Acceptance criteria are clear")
          _comment -> false
        end)

      if answered? do
        {:ok, %{score: 8, reason: "clear now"}}
      else
        {:ok,
         %{
           score: 5,
           reason: "needs answer",
           questions: ["What is done?", "Which module?", "What is out of scope?"]
         }}
      end
    end
  end

  defmodule ErroringProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(_issue, _settings), do: {:error, :stub_boom}
  end

  setup do
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")

    on_exit(fn ->
      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:symphony_elixir, :quality_gate_anthropic_module)
    end)

    :ok
  end

  test "orchestrator skips low-scoring issues, posts a Linear comment, and surfaces them on the snapshot" do
    issue = %Issue{
      id: "issue-skip-1",
      identifier: "MT-SKIP",
      title: "Skip me",
      description: "Investigate something vague",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-SKIP",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, SkipProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "pass"
      }
    )

    name = Module.concat(__MODULE__, :SkipOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)

    assert_receive {:memory_tracker_comment, "issue-skip-1", body}, 500
    assert body =~ "skipped"
    assert body =~ "score 3"
    assert body =~ "threshold 6"

    snapshot = wait_for_skipped(pid, "issue-skip-1")
    assert [%{kind: :scored, issue_id: "issue-skip-1", score: 3, identifier: "MT-SKIP"}] = snapshot.skipped
    assert snapshot.running == []

    # Re-poll: comment is not posted again for unchanged updated_at
    send(pid, :run_poll_cycle)
    refute_receive {:memory_tracker_comment, "issue-skip-1", _}, 200
  end

  test "orchestrator holds mid-band issues, posts clarification, labels, and surfaces awaiting snapshot" do
    issue = %Issue{
      id: "issue-mid-1",
      identifier: "MT-MID",
      title: "Clarify me",
      description: "Almost ready",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-MID",
      labels: [],
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, ClarificationProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        pass_threshold: 6,
        clarification_floor: 4,
        max_clarification_rounds: 2,
        on_error: "pass"
      }
    )

    name = Module.concat(__MODULE__, :ClarificationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)

    assert_receive {:memory_tracker_comment, "issue-mid-1", body}, 500
    assert body =~ "clarification requested"
    assert body =~ "round 1/2"
    assert body =~ "Questions:"
    assert body =~ "1. What should the agent verify before opening a PR?"

    snapshot = wait_for_awaiting_clarification(pid, "issue-mid-1")
    assert snapshot.running == []
    assert snapshot.skipped == []

    assert [%{kind: :clarification, issue_id: "issue-mid-1", identifier: "MT-MID", rounds_asked: 1}] =
             snapshot.awaiting_clarification
  end

  test "orchestrator dispatches clarified issue on the next poll without label mutation" do
    issue = %Issue{
      id: "issue-reply-1",
      identifier: "MT-REPLY",
      title: "Clarify then pass",
      description: "Almost ready",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-REPLY",
      labels: [],
      comments: [],
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, ReplyAwareProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        pass_threshold: 6,
        clarification_floor: 4,
        max_clarification_rounds: 2,
        on_error: "pass"
      }
    )

    name = Module.concat(__MODULE__, :ClarifiedPassOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)

    assert_receive {:memory_tracker_comment, "issue-reply-1", body}, 500
    assert body =~ "clarification requested"

    answered_issue = %{
      issue
      | comments: [
          %{
            author: "Operator",
            body: "Acceptance criteria are clear and the target module is listed.",
            created_at: ~U[2026-05-05 04:00:00Z]
          }
        ]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [answered_issue])

    force_repo_poll_due(pid)
    send(pid, :run_poll_cycle)
    :sys.get_state(pid)

    assert_bootstrap_workpad_comment("issue-reply-1")

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.awaiting_clarification == []
    assert snapshot.skipped == []
  end

  test "orchestrator passes high-scoring issues through unchanged" do
    issue = %Issue{
      id: "issue-pass-1",
      identifier: "MT-PASS",
      title: "Pass me",
      description: "Clear scope and acceptance criteria",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-PASS",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, PassProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "pass"
      }
    )

    name = Module.concat(__MODULE__, :PassOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)

    assert_bootstrap_workpad_comment("issue-pass-1")

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.skipped == []
  end

  test "orchestrator defaults quality gate off when section is absent" do
    issue = %Issue{
      id: "issue-default-off-1",
      identifier: "MT-DEFAULT-OFF",
      title: "Gate defaults off",
      description: "...",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-DEFAULT-OFF",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, SkipProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path())

    name = Module.concat(__MODULE__, :DefaultOffOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)

    assert_bootstrap_workpad_comment("issue-default-off-1")
    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.skipped == []
  end

  test "orchestrator logs active quality gate configuration on startup" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    write_workflow_file!(Workflow.workflow_file_path())

    name = Module.concat(__MODULE__, :StartupLogOrchestrator)

    log =
      capture_log([level: :info], fn ->
        {:ok, pid} = Orchestrator.start_link(name: name)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

    assert log =~ "QualityGate config enabled=false"
    assert log =~ "provider=anthropic"
    assert log =~ "model=claude-haiku-4-5-20251001"
    assert log =~ "threshold=6"
    assert log =~ "on_error=pass"
  end

  test "orchestrator with quality gate explicitly disabled does not score or skip" do
    issue = %Issue{
      id: "issue-off-1",
      identifier: "MT-OFF",
      title: "Gate off",
      description: "...",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-OFF",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, SkipProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{enabled: false}
    )

    name = Module.concat(__MODULE__, :OffOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)

    assert_bootstrap_workpad_comment("issue-off-1")
    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.skipped == []
  end

  test "on_error: skip surfaces the issue with an error reason and posts a comment" do
    issue = %Issue{
      id: "issue-err-1",
      identifier: "MT-ERR",
      title: "Erroring",
      description: "...",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-ERR",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, ErroringProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "skip"
      }
    )

    name = Module.concat(__MODULE__, :ErrorSkipOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)

    assert_receive {:memory_tracker_comment, "issue-err-1", body}, 500
    assert body =~ "LLM call failed"

    snapshot = wait_for_skipped(pid, "issue-err-1")
    assert [%{kind: :error, issue_id: "issue-err-1", error: :stub_boom}] = snapshot.skipped

    Process.sleep(50)
    drain_memory_tracker_comments("issue-err-1")

    send(pid, :run_poll_cycle)
    refute_receive {:memory_tracker_comment, "issue-err-1", _}, 200

    edited_issue = %{issue | updated_at: ~U[2026-05-05 04:00:00Z]}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [edited_issue])

    force_repo_poll_due(pid)
    send(pid, :run_poll_cycle)
    :sys.get_state(pid)
    assert_receive {:memory_tracker_comment, "issue-err-1", edited_body}, 500
    assert edited_body =~ "LLM call failed"
  end

  test "retry dispatch applies the quality gate before requeueing an active issue" do
    issue = %Issue{
      id: "issue-retry-skip-1",
      identifier: "MT-RETRY-SKIP",
      title: "Retry skip me",
      description: "Still vague on retry",
      state: "In Progress",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-RETRY-SKIP",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, SkipProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "pass"
      }
    )

    name = Module.concat(__MODULE__, :RetrySkipOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    retry_token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | claimed: MapSet.put(state.claimed, issue.id),
          retry_attempts: %{
            issue.id => %{
              attempt: 2,
              retry_token: retry_token,
              due_at_ms: System.monotonic_time(:millisecond),
              identifier: issue.identifier,
              error: "agent exited: :boom"
            }
          }
      }
    end)

    send(pid, {:retry_issue, issue.id, retry_token})

    assert_receive {:memory_tracker_comment, "issue-retry-skip-1", body}, 500
    assert body =~ "score 3"

    state =
      wait_for_orchestrator_state(pid, fn state ->
        state.running == %{} and state.retry_attempts == %{} and
          not MapSet.member?(state.claimed, issue.id)
      end)

    assert state.running == %{}
    assert state.retry_attempts == %{}
    refute MapSet.member?(state.claimed, issue.id)

    issue_id = issue.id
    snapshot = GenServer.call(pid, :snapshot)
    assert Enum.any?(snapshot.skipped, &match?(%{issue_id: ^issue_id}, &1))
  end

  test "previously-skipped issues stay on the dashboard when a different issue triggers a retry" do
    earlier_skip = %Issue{
      id: "issue-skip-earlier",
      identifier: "MT-SKIP-EARLIER",
      title: "Skip me first",
      description: "Vague",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-SKIP-EARLIER",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    retry_issue = %Issue{
      id: "issue-retry-skip-other",
      identifier: "MT-RETRY-OTHER",
      title: "Retry me, also vague",
      description: "Vague too",
      state: "In Progress",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-RETRY-OTHER",
      updated_at: ~U[2026-05-05 03:30:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, SkipProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [earlier_skip, retry_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "pass"
      }
    )

    name = Module.concat(__MODULE__, :PersistedSkippedRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    retry_token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | claimed: MapSet.put(state.claimed, retry_issue.id),
          retry_attempts: %{
            retry_issue.id => %{
              attempt: 2,
              retry_token: retry_token,
              due_at_ms: System.monotonic_time(:millisecond),
              identifier: retry_issue.identifier,
              error: "agent exited: :boom"
            }
          }
      }
    end)

    send(pid, :run_poll_cycle)

    assert_receive {:memory_tracker_comment, "issue-skip-earlier", _}, 500
    assert_receive {:memory_tracker_comment, "issue-retry-skip-other", _}, 500
    wait_for_skipped(pid, "issue-skip-earlier")

    send(pid, {:retry_issue, retry_issue.id, retry_token})

    Process.sleep(100)

    snapshot = GenServer.call(pid, :snapshot)

    assert Enum.any?(snapshot.skipped, &match?(%{issue_id: "issue-skip-earlier"}, &1)),
           "expected earlier skipped issue to remain on dashboard; got skipped=#{inspect(snapshot.skipped)}"

    assert Enum.any?(snapshot.skipped, &match?(%{issue_id: "issue-retry-skip-other"}, &1)),
           "expected retry-target skipped issue to remain on dashboard; got skipped=#{inspect(snapshot.skipped)}"
  end

  test "skipped issue leaves the dashboard once it drops out of the candidate filter" do
    skip_issue = %Issue{
      id: "issue-skip-leaves",
      identifier: "MT-LEAVES",
      title: "Skip then leave",
      description: "Vague",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-LEAVES",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, SkipProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [skip_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "pass"
      }
    )

    name = Module.concat(__MODULE__, :SkippedLeavesScopeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)
    assert_receive {:memory_tracker_comment, "issue-skip-leaves", _}, 500
    wait_for_skipped(pid, "issue-skip-leaves")

    # Issue moves out of scope (Done, reassigned, or label change → candidate fetch no longer returns it).
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    force_repo_poll_due(pid)
    send(pid, :run_poll_cycle)
    :sys.get_state(pid)
    Process.sleep(100)

    snapshot = GenServer.call(pid, :snapshot)

    refute Enum.any?(snapshot.skipped, &match?(%{issue_id: "issue-skip-leaves"}, &1)),
           "expected skipped issue to leave the dashboard once out of scope; got skipped=#{inspect(snapshot.skipped)}"
  end

  test "error-mode skip does not re-post the failed-LLM comment after orchestrator restart" do
    issue = %Issue{
      id: "issue-err-restart",
      identifier: "MT-ERR-RESTART",
      title: "Erroring across restart",
      description: "...",
      state: "Todo",
      team: %{key: "Test"},
      url: "https://example.org/issues/MT-ERR-RESTART",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, ErroringProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "skip"
      }
    )

    name_a = Module.concat(__MODULE__, :ErrorRestartOrchestratorA)
    {:ok, pid_a} = Orchestrator.start_link(name: name_a)

    send(pid_a, :run_poll_cycle)
    assert_receive {:memory_tracker_comment, "issue-err-restart", body}, 500
    assert body =~ "LLM call failed"
    _snapshot = wait_for_skipped(pid_a, "issue-err-restart")

    Process.sleep(50)
    drain_memory_tracker_comments("issue-err-restart")

    # Simulate restart: stop A, start B with the same persistence backing.
    GenServer.stop(pid_a)

    name_b = Module.concat(__MODULE__, :ErrorRestartOrchestratorB)
    {:ok, pid_b} = Orchestrator.start_link(name: name_b)
    on_exit(fn -> if Process.alive?(pid_b), do: Process.exit(pid_b, :normal) end)

    send(pid_b, :run_poll_cycle)
    refute_receive {:memory_tracker_comment, "issue-err-restart", _}, 200
  end

  defp wait_for_skipped(pid, issue_id, timeout_ms \\ 1_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_skipped(pid, issue_id, deadline_ms)
  end

  defp wait_for_awaiting_clarification(pid, issue_id, timeout_ms \\ 1_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_awaiting_clarification(pid, issue_id, deadline_ms)
  end

  defp wait_for_orchestrator_state(pid, predicate, timeout_ms \\ 1_000) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
  end

  defp force_repo_poll_due(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | repo_poll_cache: %{}, repo_poll_due_at_ms: %{}}
    end)
  end

  defp do_wait_for_skipped(pid, issue_id, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if Enum.any?(snapshot.skipped, &match?(%{issue_id: ^issue_id}, &1)) do
      snapshot
    else
      if System.monotonic_time(:millisecond) > deadline_ms do
        flunk("Timed out waiting for skipped issue #{issue_id}; snapshot=#{inspect(snapshot)}")
      else
        Process.sleep(10)
        do_wait_for_skipped(pid, issue_id, deadline_ms)
      end
    end
  end

  defp do_wait_for_awaiting_clarification(pid, issue_id, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if Enum.any?(snapshot.awaiting_clarification, &match?(%{issue_id: ^issue_id}, &1)) do
      snapshot
    else
      if System.monotonic_time(:millisecond) > deadline_ms do
        flunk("Timed out waiting for awaiting clarification issue #{issue_id}; snapshot=#{inspect(snapshot)}")
      else
        Process.sleep(10)
        do_wait_for_awaiting_clarification(pid, issue_id, deadline_ms)
      end
    end
  end

  defp do_wait_for_orchestrator_state(pid, predicate, deadline_ms) do
    state = :sys.get_state(pid)

    if predicate.(state) do
      state
    else
      if System.monotonic_time(:millisecond) > deadline_ms do
        flunk("Timed out waiting for orchestrator state: #{inspect(state)}")
      else
        Process.sleep(10)
        do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
      end
    end
  end

  defp drain_memory_tracker_comments(issue_id) do
    receive do
      {:memory_tracker_comment, ^issue_id, _body} -> drain_memory_tracker_comments(issue_id)
    after
      0 -> :ok
    end
  end

  defp assert_bootstrap_workpad_comment(issue_id) do
    assert_receive {:memory_tracker_comment, ^issue_id, body}, 500
    assert body =~ "## Symphony Workpad"
    refute body =~ "skipped"
    refute body =~ "clarification requested"
  end
end
