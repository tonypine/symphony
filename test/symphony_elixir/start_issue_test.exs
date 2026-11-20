defmodule SymphonyElixir.StartIssueTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Linear.Issue, Pauses, RunStore, Workspace}

  @active_states ["Todo", "In Progress", "Code Review", "Rework"]
  @repo "default"

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-start-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-start","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-start","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_state_result)
      File.rm_rf(test_root)
    end)

    workflow_opts = [
      tracker_active_states: @active_states,
      tracker_terminal_states: ["Done", "Canceled"],
      workspace_root: Path.join(test_root, "workspaces"),
      agent_kind: "claude",
      agent_command: fake_claude,
      max_turns: 1,
      quality_gate: %{enabled: false}
    ]

    write_workflow_file!(Workflow.workflow_file_path(), workflow_opts)

    %{test_root: test_root, workflow_opts: workflow_opts}
  end

  describe "the start handler" do
    test "with every slot busy and three tickets queued ahead, Start starts a fourth at once; the three keep their order" do
      busy = [issue("impl-1", "MT-1", "In Progress"), issue("impl-2", "MT-2", "In Progress")]
      queued = [issue("queued-1", "MT-Q1", "In Progress"), issue("queued-2", "MT-Q2", "In Progress"), issue("queued-3", "MT-Q3", "In Progress")]
      started = issue("start-1", "MT-S1", "In Progress")
      tracked(busy ++ queued ++ [started])

      # Every slot busy: the dispatch pass queues the three, in order, for a slot.
      state = Enum.reduce(busy, orchestrator_state(2), &running(&2, &1, :implementation))
      queued_state = Orchestrator.dispatch_chosen_issues_for_test(queued, state)

      assert Enum.sort(Map.keys(queued_state.running)) == ["impl-1", "impl-2"]
      assert Enum.sort(Map.keys(queued_state.slot_waiting)) == ["queued-1", "queued-2", "queued-3"]
      assert Enum.all?(Map.values(queued_state.slot_waiting), &(&1.reason == "work slots full"))

      {:reply, {:ok, reply}, next_state} =
        Orchestrator.handle_call({:start_issue, started, "unblock this one"}, {self(), make_ref()}, queued_state)

      assert %{
               started: true,
               issue_id: "start-1",
               issue_identifier: "MT-S1",
               repo_key: @repo,
               run_id: run_id,
               session_id: nil
             } = reply

      # One over the limit: the two busy runs and the started one; the three queued tickets still wait, untouched.
      assert Enum.sort(Map.keys(next_state.running)) == ["impl-1", "impl-2", "start-1"]
      assert next_state.slot_waiting == queued_state.slot_waiting

      # The run a person started is one ledger event next to the machine's own run.started.
      assert [{^run_id, :implementation}] = for(entry <- [next_state.running["start-1"]], do: {entry.run_id, entry.run_profile.kind})

      assert [{"run.started_by_person", %{by: "the Director", note: "unblock this one", run_id: ^run_id}}] =
               ticket_events(@repo, "start-1", "run.started_by_person")

      assert [_run_started] = ticket_events(@repo, "start-1", "run.started")
      assert [] = ticket_events(@repo, "impl-1", "run.started_by_person")

      # The busy runs end: with the started run holding one of the two slots, the next pass has one slot
      # fewer and gives it to the first ticket in the queue.
      freed = %{next_state | running: Map.take(next_state.running, ["start-1"])}
      after_first = Orchestrator.dispatch_chosen_issues_for_test(queued, freed)

      assert Enum.sort(Map.keys(after_first.running)) == ["queued-1", "start-1"]
      assert Enum.sort(Map.keys(after_first.slot_waiting)) == ["queued-2", "queued-3"]

      # The started run ends: the next slot goes to the second, then the third.
      after_second =
        Orchestrator.dispatch_chosen_issues_for_test(tl(queued), %{after_first | running: Map.take(after_first.running, ["queued-1"])})

      assert Enum.sort(Map.keys(after_second.running)) == ["queued-1", "queued-2"]
      assert Map.keys(after_second.slot_waiting) == ["queued-3"]
    end

    test "Start on a Code Review ticket runs the reviewer, with no note" do
      started = issue("review-1", "MT-R1", "Code Review")
      tracked([started])

      {:reply, {:ok, reply}, next_state} =
        Orchestrator.handle_call({:start_issue, started, nil}, {self(), make_ref()}, orchestrator_state(1))

      assert %{started: true, run_id: run_id} = reply
      assert next_state.running["review-1"].run_profile.kind == :code_review

      assert [{"run.started_by_person", person_started}] = ticket_events(@repo, "review-1", "run.started_by_person")
      assert %{by: "the Director", run_id: ^run_id} = person_started
      refute Map.has_key?(person_started, :note)
    end

    test "TP-1518: Start on a ticket in CI Fix, its conflict fix pending, starts a ci_fix run" do
      started = issue("fix-1", "MT-F1", "CI Fix")
      tracked([started])

      {:reply, {:ok, %{started: true}}, next_state} =
        Orchestrator.handle_call({:start_issue, started, nil}, {self(), make_ref()}, orchestrator_state(1))

      assert next_state.running["fix-1"].run_profile.kind == :ci_fix
    end

    test "a ticket in Backlog is refused with move it first" do
      backlog = issue("backlog-1", "MT-B1", "Backlog")
      tracked([backlog])

      {:reply, reply, next_state} =
        Orchestrator.handle_call({:start_issue, backlog, nil}, {self(), make_ref()}, orchestrator_state(1))

      assert {:error, {:start_refused, "The ticket is in Backlog; move it to Todo with Move to… first."}} = reply
      assert next_state.running == %{}
      assert [] = ticket_events(@repo, "backlog-1", "run.started_by_person")
    end

    test "a ticket whose repository is paused is refused, starting nothing" do
      {:ok, _pause} = Pauses.set({:repository, @repo}, Pauses.repository_reason("flaky CI"))
      paused = issue("repo-1", "MT-P1", "In Progress")
      tracked([paused])

      {:reply, reply, next_state} =
        Orchestrator.handle_call({:start_issue, paused, nil}, {self(), make_ref()}, orchestrator_state(1))

      assert {:error, {:start_refused, reason}} = reply
      assert reason =~ "the repository is paused by you"
      assert next_state.running == %{}
    end

    test "a ticket with an open Question is refused, starting nothing" do
      question = issue("q-1", "MT-Q1", "In Progress")
      {:ok, _pause} = Pauses.set({:ticket, @repo, "q-1"}, %{kind: :question, text: "Which reading?", waits_on: %{question_id: "q-1"}})
      tracked([question])

      {:reply, reply, next_state} =
        Orchestrator.handle_call({:start_issue, question, nil}, {self(), make_ref()}, orchestrator_state(1))

      assert {:error, {:start_refused, "It waits on your answer first."}} = reply
      assert next_state.running == %{}
    end

    test "a ticket a run is already working on is refused, starting nothing" do
      busy = issue("busy-1", "MT-B2", "In Progress")
      tracked([busy])

      state =
        orchestrator_state(1)
        |> running(busy, :implementation)

      {:reply, reply, next_state} = Orchestrator.handle_call({:start_issue, busy, nil}, {self(), make_ref()}, state)

      assert {:error, {:start_refused, "A run is already working on it."}} = reply
      assert Map.keys(next_state.running) == ["busy-1"]
    end

    test "a ticket with no repository is refused, even with a primary repository to fall back on" do
      nowhere = bare_issue("nowhere-1", "MT-N1", "In Progress")
      tracked([nowhere])

      for state <- [orchestrator_state(1), %{orchestrator_state(1) | repo_key: nil}] do
        {:reply, reply, next_state} =
          Orchestrator.handle_call({:start_issue, nowhere, nil}, {self(), make_ref()}, state)

        assert {:error, {:start_refused, "The ticket has no repository; it can't be started."}} = reply
        assert next_state.running == %{}
      end
    end

    test "TP-1566: a ticket of a second repository, its repository only on its record, runs in that repository's workspace", %{
      test_root: test_root,
      workflow_opts: workflow_opts
    } do
      workflow = Workflow.workflow_file_path()
      repos = [[key: @repo, workflow: workflow, team: "Test"], [key: "cycle", workflow: workflow, team: "Cycle"]]
      write_workflow_file!(workflow, Keyword.put(workflow_opts, :repos, repos))

      # A read by identifier carries no repo key; the record holds the ticket's repository.
      started = bare_issue("cycle-1", "MOT-104", "In Progress")
      :ok = RunStore.put_ticket_state(%{repo_key: "cycle", issue_id: "cycle-1", issue_identifier: "MOT-104", phase: "In Progress"})

      {:reply, {:ok, reply}, next_state} =
        Orchestrator.handle_call({:start_issue, started, nil}, {self(), make_ref()}, orchestrator_state(1))

      assert %{started: true, repo_key: "cycle"} = reply
      assert %{repo_key: "cycle", issue: %Issue{repo_key: "cycle"} = run_issue} = next_state.running["cycle-1"]
      {:ok, cycle_workspace} = SymphonyElixir.PathSafety.canonicalize(Path.join([test_root, "workspaces", "cycle", "MOT-104"]))
      assert {:ok, ^cycle_workspace} = Workspace.local_path_for_issue(run_issue)
      assert [_started_by_person] = ticket_events("cycle", "cycle-1", "run.started_by_person")
    end

    test "TP-1566: the queue and a retry dispatch a ticket with no repo key in its record's repository", %{workflow_opts: workflow_opts} do
      workflow = Workflow.workflow_file_path()
      repos = [[key: @repo, workflow: workflow, team: "Test"], [key: "cycle", workflow: workflow, team: "Cycle"]]
      write_workflow_file!(workflow, Keyword.put(workflow_opts, :repos, repos))

      queued = bare_issue("cycle-1", "MOT-104", "In Progress")
      retried = bare_issue("cycle-2", "MOT-105", "In Progress")
      tracked([queued, retried])

      for {issue_id, identifier} <- [{"cycle-1", "MOT-104"}, {"cycle-2", "MOT-105"}] do
        :ok = RunStore.put_ticket_state(%{repo_key: "cycle", issue_id: issue_id, issue_identifier: identifier, phase: "In Progress"})
      end

      dispatched = Orchestrator.dispatch_chosen_issues_for_test([queued], orchestrator_state(2))
      assert %{repo_key: "cycle", issue: %Issue{repo_key: "cycle"}} = dispatched.running["cycle-1"]

      {:noreply, after_retry} =
        Orchestrator.handle_retry_issue_for_test(
          orchestrator_state(2),
          "cycle-2",
          1,
          %{identifier: "MOT-105"},
          fn _ids -> {:ok, [retried]} end
        )

      assert %{repo_key: "cycle", issue: %Issue{repo_key: "cycle"}} = after_retry.running["cycle-2"]
    end

    test "a spawn that fails answers that a retry is scheduled and keeps that retry in the state" do
      started = issue("spawn-1", "MT-P1", "In Progress")
      tracked([started])

      # A task supervisor that takes no child: the spawn fails as Task.Supervisor's own refusal.
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)
      start_supervised!({Task.Supervisor, name: SymphonyElixir.TaskSupervisor, max_children: 0})

      call = {:start_issue, started, nil}
      start = fn -> Orchestrator.handle_call(call, {self(), make_ref()}, orchestrator_state(1)) end
      {{:reply, reply, next_state}, _log} = with_log(start)

      assert {:error, {:start_failed, message}} = reply
      assert message == "the agent did not start; it is scheduled to retry as a normal candidate"
      assert next_state.running == %{}
      assert %{timer_ref: timer_ref} = next_state.retry_attempts["spawn-1"]
      assert is_reference(timer_ref)
      Process.cancel_timer(timer_ref)
      assert [] = ticket_events(@repo, "spawn-1", "run.started_by_person")
    end
  end

  describe "Orchestrator.start_issue/3" do
    setup do
      server = start_call_server()
      %{server: server}
    end

    test "refuses a Backlog or closed ticket in the caller, starting nothing", %{server: server} do
      tracked([issue("backlog-1", "MT-B1", "Backlog"), issue("done-1", "MT-D1", "Done")])

      assert {:error, {:start_refused, "The ticket is in Backlog; move it to Todo with Move to… first."}} = Orchestrator.start_issue(server, "MT-B1", nil)
      assert {:error, {:start_refused, "The ticket is done."}} = Orchestrator.start_issue(server, "MT-D1", nil)
      assert [] = ticket_events(@repo, "backlog-1", "run.started_by_person")
      assert [] = ticket_events(@repo, "done-1", "run.started_by_person")
    end

    test "refuses while Symphony is paused, without claiming a Todo ticket", %{server: server} do
      {:ok, _pause} = Pauses.set(:symphony, Pauses.dispatch_reason("deploy window"))
      tracked([issue("todo-1", "MT-T1", "Todo")])

      assert {:error, {:start_refused, "dispatch is paused by the operator: deploy window"}} = Orchestrator.start_issue(server, "MT-T1", nil)
      refute_received {:start_issue_call, _issue, _note}
    end

    test "claims a Todo ticket to In Progress and hands it, with its note, to the orchestrator", %{server: server} do
      tracked([issue("todo-1", "MT-T1", "Todo")])

      assert {:ok, %{started: true, run_id: "run-1"}} = Orchestrator.start_issue(server, "MT-T1", "green light")
      assert_received {:start_issue_call, %Issue{state: "In Progress", id: "todo-1"}, "green light"}
    end

    test "answers with the claim's failure when Linear refuses the move", %{server: server} do
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :boom})
      tracked([issue("todo-1", "MT-T1", "Todo")])

      assert {:error, {:start_claim, :boom}} = Orchestrator.start_issue(server, "MT-T1", nil)
      refute_received {:start_issue_call, _issue, _note}
    end

    test "TP-1518: Start on a QA ticket whose PR needs a conflict fix asks the watcher to send it to CI Fix, and never starts QA on the conflict", %{server: server} do
      tracked([issue("qa-1", "MT-Q1", "QA"), issue("qa-2", "MT-Q2", "QA")])
      fix = %{rule: "R14", kind: :ci_fix, args: %{origin: :qa, cause: :conflict}, reason: "PR #1 conflicts with main: conflict fix run 1 of 3"}
      dirty = %{mergeable: :dirty}
      SymphonyElixir.PrWatchSupport.put_watch!(@repo, "qa-1", phase: :qa, identifier: "MT-Q1", facts: dirty, decision: fix)

      # No watcher runs here to apply it: the start is refused, and nothing reaches the orchestrator.
      assert {:error, {:start_refused, "Its PR needs a CI Fix run first, and Symphony could not send it to CI Fix yet; try again in a moment."}} =
               Orchestrator.start_issue(server, "MT-Q1", nil)

      wait = %{rule: "R14a", kind: :wait_for_competitors, owner: :symphony, reason: "Lands after TP-9"}
      SymphonyElixir.PrWatchSupport.put_watch!(@repo, "qa-2", phase: :qa, identifier: "MT-Q2", facts: dirty, decision: wait)

      assert {:error, {:start_refused, "PR #1 conflicts with its base: a conflict fix runs first, never a review on it."}} = Orchestrator.start_issue(server, "MT-Q2", nil)
      refute_received {:start_issue_call, _issue, _note}
    end

    test "TP-1566: a ticket read by identifier takes its record's repository to the orchestrator", %{server: server} do
      tracked([bare_issue("cycle-1", "MOT-104", "In Progress")])
      :ok = RunStore.put_ticket_state(%{repo_key: "cycle", issue_id: "cycle-1", issue_identifier: "MOT-104", phase: "In Progress"})

      assert {:ok, %{started: true}} = Orchestrator.start_issue(server, "MOT-104", nil)
      assert_received {:start_issue_call, %Issue{id: "cycle-1", repo_key: "cycle"}, nil}
    end

    test "TP-1566: a ticket with no repository on its record is refused in the caller, and nothing starts", %{server: server} do
      tracked([bare_issue("nowhere-1", "MT-N1", "Todo")])

      assert {:error, {:start_refused, "The ticket has no repository; it can't be started."}} = Orchestrator.start_issue(server, "MT-N1", nil)
      refute_received {:start_issue_call, _issue, _note}
    end

    test "TP-1566: a ticket with no repository gets the Start refusals first, as the ticket read does", %{server: server} do
      tracked([bare_issue("nowhere-1", "MT-N1", "Backlog"), bare_issue("nowhere-2", "MT-N2", "Todo")])

      assert {:error, {:start_refused, "The ticket is in Backlog; move it to Todo with Move to… first."}} = Orchestrator.start_issue(server, "MT-N1", nil)

      {:ok, _pause} = Pauses.set(:symphony, Pauses.dispatch_reason("deploy window"))
      assert {:error, {:start_refused, "dispatch is paused by the operator: deploy window"}} = Orchestrator.start_issue(server, "MT-N2", nil)
      refute_received {:start_issue_call, _issue, _note}
    end

    test "an unknown ticket is not found and a non-string identifier is invalid", %{server: server} do
      tracked([issue("todo-1", "MT-T1", "Todo")])

      assert {:error, :issue_not_found} = Orchestrator.start_issue(server, "MT-404", nil)
      assert {:error, :invalid_issue_id} = Orchestrator.start_issue(server, :not_an_identifier, nil)
      assert :unavailable = Orchestrator.start_issue(Module.concat(__MODULE__, :Missing), "MT-T1", nil)
    end
  end

  # A process that answers the one call the orchestrator's start makes, telling the test what it got.
  # It tells the test before it replies: messages between two processes keep their order, so the
  # report is in the test's mailbox by the time the call returns (TP-1547).
  defp start_call_server do
    parent = self()

    spawn_link(fn ->
      receive do
        {:"$gen_call", from, {:start_issue, %Issue{} = issue, note}} ->
          send(parent, {:start_issue_call, issue, note})
          GenServer.reply(from, {:ok, %{started: true, issue_id: issue.id, run_id: "run-1", session_id: nil}})
      end
    end)
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp issue(id, identifier, state), do: %{bare_issue(id, identifier, state) | repo_key: @repo}

  # As Linear reads it by identifier: no repo key.
  defp bare_issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "Ticket #{identifier}", state: state, team: %{key: "Test"}, url: "https://example.org/issues/#{identifier}"}
  end

  defp running(state, %Issue{} = issue, kind) do
    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      run_profile: %{kind: kind, model: nil, effort: nil, provider: "anthropic"},
      session_id: nil,
      started_at: DateTime.utc_now()
    }

    %{state | running: Map.put(state.running, issue.id, entry)}
  end

  defp orchestrator_state(max_total) do
    %Orchestrator.State{
      repo_key: @repo,
      max_concurrent_agents: max_total,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
