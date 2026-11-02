defmodule SymphonyElixir.StartIssueTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Linear.Issue, Pauses}

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

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: @active_states,
      tracker_terminal_states: ["Done", "Canceled"],
      workspace_root: Path.join(test_root, "workspaces"),
      agent_kind: "claude",
      agent_command: fake_claude,
      max_turns: 1,
      quality_gate: %{enabled: false}
    )

    %{test_root: test_root}
  end

  describe "the start handler" do
    test "with every slot busy Start starts the run anyway, over the limit, and the queue is untouched" do
      busy = issue("impl-1", "MT-1", "In Progress")
      started = issue("start-1", "MT-S1", "In Progress")
      tracked([busy, started])

      state =
        orchestrator_state(1)
        |> running(busy, :implementation)

      {:reply, {:ok, reply}, next_state} =
        Orchestrator.handle_call({:start_issue, started, "unblock this one"}, {self(), make_ref()}, state)

      assert %{
               started: true,
               issue_id: "start-1",
               issue_identifier: "MT-S1",
               repo_key: @repo,
               run_id: run_id,
               session_id: nil
             } = reply

      # One over the limit: the busy run and the started one, and the queue's slots untouched.
      assert Enum.sort(Map.keys(next_state.running)) == ["impl-1", "start-1"]
      assert next_state.slot_waiting == state.slot_waiting

      # The run a person started is one ledger event next to the machine's own run.started.
      assert [{^run_id, :implementation}] = for(entry <- [next_state.running["start-1"]], do: {entry.run_id, entry.run_profile.kind})

      assert [{"run.started_by_person", %{by: "the Director", note: "unblock this one", run_id: ^run_id}}] =
               ticket_events(@repo, "start-1", "run.started_by_person")

      assert [_run_started] = ticket_events(@repo, "start-1", "run.started")
      assert [] = ticket_events(@repo, "impl-1", "run.started_by_person")
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

    test "a ticket in Backlog is refused with move it first" do
      backlog = issue("backlog-1", "MT-B1", "Backlog")
      tracked([backlog])

      {:reply, reply, next_state} =
        Orchestrator.handle_call({:start_issue, backlog, nil}, {self(), make_ref()}, orchestrator_state(1))

      assert {:error, {:start_refused, "the ticket is in Backlog; move it first"}} = reply
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

      assert {:error, {:start_refused, "a Question is waiting for an answer"}} = reply
      assert next_state.running == %{}
    end

    test "a ticket a run is already working on is refused, starting nothing" do
      busy = issue("busy-1", "MT-B2", "In Progress")
      tracked([busy])

      state =
        orchestrator_state(1)
        |> running(busy, :implementation)

      {:reply, reply, next_state} = Orchestrator.handle_call({:start_issue, busy, nil}, {self(), make_ref()}, state)

      assert {:error, {:start_refused, "a run is already working on the ticket"}} = reply
      assert Map.keys(next_state.running) == ["busy-1"]
    end

    test "a ticket with no repository is refused" do
      nowhere = issue("nowhere-1", "MT-N1", "In Progress")
      tracked([nowhere])

      state = %{orchestrator_state(1) | repo_key: nil}

      {:reply, reply, next_state} = Orchestrator.handle_call({:start_issue, nowhere, nil}, {self(), make_ref()}, state)

      assert {:error, {:start_refused, "the ticket has no repository; it cannot be started"}} = reply
      assert next_state.running == %{}
    end
  end

  describe "Orchestrator.start_issue/3" do
    setup do
      server = start_call_server()
      %{server: server}
    end

    test "refuses a Backlog or closed ticket in the caller, starting nothing", %{server: server} do
      tracked([issue("backlog-1", "MT-B1", "Backlog"), issue("done-1", "MT-D1", "Done")])

      assert {:error, {:start_refused, "the ticket is in Backlog; move it first"}} = Orchestrator.start_issue(server, "MT-B1", nil)
      assert {:error, {:start_refused, "the ticket is Done; only an open ticket can be started"}} = Orchestrator.start_issue(server, "MT-D1", nil)
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

    test "an unknown ticket is not found and a non-string identifier is invalid", %{server: server} do
      tracked([issue("todo-1", "MT-T1", "Todo")])

      assert {:error, :issue_not_found} = Orchestrator.start_issue(server, "MT-404", nil)
      assert {:error, :invalid_issue_id} = Orchestrator.start_issue(server, :not_an_identifier, nil)
      assert :unavailable = Orchestrator.start_issue(Module.concat(__MODULE__, :Missing), "MT-T1", nil)
    end
  end

  # A process that answers the one call the orchestrator's start makes, telling the test what it got.
  defp start_call_server do
    parent = self()

    spawn_link(fn ->
      receive do
        {:"$gen_call", from, {:start_issue, %Issue{} = issue, note}} ->
          GenServer.reply(from, {:ok, %{started: true, issue_id: issue.id, run_id: "run-1", session_id: nil}})
          send(parent, {:start_issue_call, issue, note})
      end
    end)
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp issue(id, identifier, state) do
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
