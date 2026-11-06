defmodule SymphonyElixir.OrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DirectorMoves, Inbox, Pauses, Questions, TicketState}

  @active_states ["Todo", "In Progress", "Merging", "Rework"]

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-orchestrator-steps-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: @active_states,
      tracker_terminal_states: ["Done", "Canceled"],
      workspace_root: Path.join(test_root, "workspaces"),
      max_concurrent_agents: 1,
      agent_stall_timeout_ms: 1_000,
      watchdog: %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 1_000},
      quality_gate: %{enabled: false}
    )

    on_exit(fn ->
      Pauses.clear(:symphony)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      File.rm_rf(test_root)
    end)

    :ok
  end

  @machine %{id: "build", title: "Build", mode: "machine"}

  defp machine_notice, do: {:machine, Map.merge(@machine, %{started_at: DateTime.utc_now(), deadline: DateTime.add(DateTime.utc_now(), 600, :second)})}
  defp turn_wanted, do: {:turn_wanted, self(), %{id: "code", title: "Write the code", mode: "delegated"}}

  defp step(state, notice, issue_id \\ "walk-1") do
    {:noreply, state} = Orchestrator.handle_info({:run_step, issue_id, notice}, state)
    state
  end

  defp snapshot_of(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
  end

  defp running_of(state, issue_id), do: state |> snapshot_of() |> Map.fetch!(:running) |> Enum.find(&(&1.issue_id == issue_id))

  test "while a machine step runs the ticket is on that step with no session and its slot is free for another ticket" do
    walking = issue("walk-1", "TP-1", "In Progress")
    todo = issue("todo-1", "TP-2", "Todo")
    state = run(orchestrator_state(1), walking, session_id: "sess-1", agent_session: %{session: 1})

    refute Orchestrator.should_dispatch_issue_for_test(todo, state)

    state = step(state, machine_notice())

    assert Orchestrator.should_dispatch_issue_for_test(todo, state)
    assert %{session_id: nil, agent_session: nil, step: %{id: "build", mode: "machine", waiting: nil}} = state.running["walk-1"]
    assert %{session_id: nil, step: snapshot_step} = running_of(state, "walk-1")
    assert %{id: "build", title: "Build", mode: "machine", started_at: %DateTime{}, waiting: nil} = snapshot_step
    assert state.cycle_requested or is_reference(state.tick_timer_ref)
  end

  test "the next agent turn gets a slot at once when one is free, and waits for one when none is" do
    state = orchestrator_state(1) |> run(issue("walk-1", "TP-1", "In Progress")) |> step(machine_notice())

    granted = step(state, turn_wanted())
    assert_received {:run_step_turn, "walk-1"}
    assert %{step: %{id: "code", waiting: nil}} = granted.running["walk-1"]
    refute Orchestrator.should_dispatch_issue_for_test(issue("todo-1", "TP-2", "Todo"), granted)

    # Another ticket took the freed slot: the turn waits for it, and its watchdogs hold off.
    waiting = state |> run(issue("other-1", "TP-3", "In Progress")) |> step(turn_wanted())
    refute_received {:run_step_turn, "walk-1"}
    assert %{step: %{waiting: "slot"}} = running_of(waiting, "walk-1")

    # A forced run takes no slot, so it waits for no one.
    forced = state |> run(issue("other-1", "TP-3", "In Progress")) |> put_in([Access.key(:running), "walk-1", :forced], true) |> step(turn_wanted())
    assert_received {:run_step_turn, "walk-1"}
    assert %{step: %{waiting: nil}} = forced.running["walk-1"]

    # The slot frees: the waiting turn gets it before any dispatch.
    freed = %{waiting | running: Map.delete(waiting.running, "other-1")} |> step(turn_wanted())
    assert_received {:run_step_turn, "walk-1"}
    assert %{step: %{waiting: nil}} = freed.running["walk-1"]
  end

  test "while Symphony is paused a run's next agent turn waits for the pause to lift" do
    {:ok, _pause} = Pauses.set(:symphony, Pauses.dispatch_reason("deploy window"))
    state = orchestrator_state(1) |> run(issue("walk-1", "TP-1", "In Progress")) |> step(machine_notice()) |> step(turn_wanted())

    refute_received {:run_step_turn, "walk-1"}
    assert %{step: %{waiting: "pause"}} = running_of(state, "walk-1")

    {:ok, nil} = Pauses.clear(:symphony)
    state = step(state, turn_wanted())
    assert_received {:run_step_turn, "walk-1"}
    assert %{step: %{waiting: nil}} = state.running["walk-1"]
  end

  describe "an update's pause and a run between turns" do
    setup do
      :ok = RunStore.clear()
      :ok
    end

    defp update_waits(issue_id) do
      for %{type: "note", payload: %{signal: "update_wait"} = payload} <- RunStore.list_ticket_events(issue_id, []), do: payload
    end

    test "the turn waits with no session, and the ticket says what holds it, once per hold" do
      {:ok, _pause} = Pauses.set(:symphony, Pauses.dispatch_reason("updating to v0.0.1.856"))
      state = orchestrator_state(1) |> run(issue("walk-1", "TP-1", "In Progress"), session_id: "sess-1") |> step(machine_notice()) |> step(turn_wanted())

      refute_received {:run_step_turn, "walk-1"}
      assert %{session_id: nil, step: %{waiting: "pause"}} = running_of(state, "walk-1")

      assert [%{text: text, signal_details: %{version: "0.0.1.856", step: "code"}}] = update_waits("walk-1")
      assert text =~ "Its next agent turn waits for the update"

      # Every later cycle holds the same turn: one signal for the hold.
      {:noreply, state} = Orchestrator.handle_info({:ticket_record, "default", "walk-1", :changed, [:pause]}, state)
      assert %{step: %{waiting: "pause"}} = running_of(state, "walk-1")
      assert [_one] = update_waits("walk-1")

      # The update called off, the run goes on.
      {:ok, nil} = Pauses.clear(:symphony)
      {:noreply, state} = Orchestrator.handle_info({:ticket_record, "default", "walk-1", :changed, [:pause]}, state)
      assert_received {:run_step_turn, "walk-1"}
      assert %{step: %{waiting: nil}} = state.running["walk-1"]
    end

    test "a pause of the Director's records no update on the ticket" do
      {:ok, _pause} = Pauses.set(:symphony, Pauses.dispatch_reason("deploy window"))
      state = orchestrator_state(1) |> run(issue("walk-1", "TP-1", "In Progress")) |> step(machine_notice()) |> step(turn_wanted())

      assert %{step: %{waiting: "pause"}} = running_of(state, "walk-1")
      assert update_waits("walk-1") == []
    end
  end

  test "neither watchdog stops a run on a machine step or waiting for its turn" do
    long_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)
    building = {:machine, Map.merge(@machine, %{started_at: long_ago, deadline: DateTime.add(DateTime.utc_now(), 600, :second)})}

    state =
      orchestrator_state(3)
      |> run(issue("walk-1", "TP-1", "In Progress"), last_codex_timestamp: long_ago, last_event_at: long_ago)
      |> run(issue("walk-2", "TP-2", "In Progress"), last_codex_timestamp: long_ago, last_event_at: long_ago)
      |> run(issue("walk-3", "TP-3", "In Progress"), last_event_at: long_ago, session_id: "sess-3")
      |> run(issue("walk-4", "TP-4", "In Progress"), last_event_at: long_ago, session_id: "sess-4")
      |> step(building, "walk-1")
      |> put_in([Access.key(:running), "walk-1", :last_event_at], long_ago)
      |> step(building, "walk-3")
      |> put_in([Access.key(:running), "walk-3", :last_event_at], long_ago)
      |> put_in([Access.key(:running), "walk-2", :step], %{id: "code", title: "Write the code", mode: "delegated", waiting: :slot, waiter: self(), started_at: long_ago})
      |> put_in([Access.key(:running), "walk-4", :step], %{id: "code", title: "Write the code", mode: "delegated", waiting: :pause, waiter: self(), started_at: long_ago})

    state = Orchestrator.run_watchdogs_for_test(state)

    assert Enum.sort(Map.keys(state.running)) == ["walk-1", "walk-2", "walk-3", "walk-4"]
  end

  describe "a step paused on a Question" do
    setup do
      :ok = RunStore.clear()
      :ok
    end

    defp ask!(issue_id, repo_key \\ "default") do
      request = %{
        title: "Pick the settings layout",
        question: "Which layout should the settings page use: one column or two?",
        why: "The ticket shows both layouts. Only you can say which one it wants.",
        if_unanswered: "The ticket stays paused on its code step.",
        recommendation_reason: "One column matches the rest of the app.",
        options: [%{label: "One column", effect: "The run builds one column.", recommended: true}, %{label: "Two columns", effect: "The run builds two."}]
      }

      {:ok, question} = Questions.ask({:ticket, repo_key, issue_id}, request, asked_by: %{kind: :run, name: "The run"}, request: true)
      question
    end

    defp answer_wanted(question), do: {:answer_wanted, self(), %{id: "code", title: "Write the code", mode: "delegated"}, question.id}

    test "holds no session and no slot, shows on its step as paused on the answer, and the answer gives it its turn at once" do
      question = ask!("walk-1")
      state = orchestrator_state(1) |> run(issue("walk-1", "TP-1", "In Progress"), session_id: "sess-1", agent_session: %{session: 1})

      state = step(state, answer_wanted(question))
      refute_received {:run_step_turn, "walk-1"}
      assert Orchestrator.should_dispatch_issue_for_test(issue("todo-1", "TP-2", "Todo"), state)
      assert %{session_id: nil, agent_session: nil} = state.running["walk-1"]
      assert %{session_id: nil, step: %{id: "code", waiting: "answer", question_id: question_id}} = running_of(state, "walk-1")
      assert question_id == question.id

      # The watchdogs hold off: it waits on a person.
      long_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)
      aged = state |> put_in([Access.key(:running), "walk-1", :last_event_at], long_ago) |> Orchestrator.run_watchdogs_for_test()
      assert Map.has_key?(aged.running, "walk-1")

      # A pause change that leaves it open changes nothing; the answer's gives it its turn.
      {:noreply, state} = Orchestrator.handle_info({:ticket_record, "default", "walk-1", :changed, [:pause]}, state)
      refute_received {:run_step_turn, "walk-1"}

      {:ok, _answered} = Questions.answer({:ticket, "default", "walk-1"}, question.id, "Two columns")
      {:noreply, state} = Orchestrator.handle_info({:ticket_record, "default", "walk-1", :changed, [:pause]}, state)
      assert_received {:run_step_turn, "walk-1"}
      assert %{step: %{waiting: nil}} = state.running["walk-1"]
    end

    for {kind, step} <- [{"machine", %{id: "tests", title: "Tests and coverage", mode: "machine"}}, {"agent", %{id: "code", title: "Write the code", mode: "delegated"}}] do
      test "a #{kind} step's Question lists in the Inbox the moment it pauses, as a question with no run does, and answering it there resumes the step" do
        server = :"step_question_inbox_#{System.unique_integer([:positive])}"
        start_supervised!({DirectorMoves, name: server})
        walking = issue("walk-1", "TP-1", "In Progress")
        repo_key = Config.repo_key!()
        ticket = {:ticket, repo_key, "walk-1"}
        inbox = [name: {:test, make_ref()}, github_repos: %{}, pull_request: fn url -> flunk("read #{url} from GitHub") end]

        :ok = RunStore.put_ticket_state(TicketState.new(repo_key, "walk-1", %{issue_identifier: "TP-1", title: "Ticket TP-1", phase: "In Progress"}))
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [walking])
        question = ask!("walk-1", repo_key)
        state = %{orchestrator_state(1) | repo_key: repo_key} |> run(walking)

        # The turn that asked it still runs: the ticket is working.
        assert state |> snapshot_of() |> Inbox.items(inbox) == []

        state = step(state, {:answer_wanted, self(), unquote(Macro.escape(step)), question.id})

        assert [%{kind: :action, identifier: "TP-1", review: %{question_id: question_id}} = row] = state |> snapshot_of() |> Inbox.items(inbox)
        assert question_id == question.id
        assert row == %{running: []} |> Inbox.items(inbox) |> hd()
        assert {:ok, %{reasons: [%{kind: :question}]}} = Pauses.get(ticket)

        pick = [%{question: question.question, answer: "Two columns"}]
        assert {:ok, %{move: "decide"}} = DirectorMoves.move(:decide, "TP-1", %{picks: pick, question_id: question.id}, server: server)
        assert {:ok, nil} = Pauses.get(ticket)

        {:noreply, state} = Orchestrator.handle_info({:ticket_record, repo_key, "walk-1", :changed, [:pause]}, state)
        assert_received {:run_step_turn, "walk-1"}
        assert state |> snapshot_of() |> Inbox.items(inbox) == []
      end
    end

    test "an answer while Symphony is paused waits for the pause to lift, and one already given grants the turn at once" do
      question = ask!("walk-1")
      {:ok, _answered} = Questions.answer({:ticket, "default", "walk-1"}, question.id, "1")
      {:ok, _pause} = Pauses.set(:symphony, Pauses.dispatch_reason("deploy window"))

      state = orchestrator_state(1) |> run(issue("walk-1", "TP-1", "In Progress")) |> step(answer_wanted(question))
      refute_received {:run_step_turn, "walk-1"}
      assert %{step: %{waiting: "pause", question_id: nil}} = running_of(state, "walk-1")

      {:ok, nil} = Pauses.clear(:symphony)
      state = step(state, answer_wanted(question))
      assert_received {:run_step_turn, "walk-1"}
      assert %{step: %{waiting: nil}} = state.running["walk-1"]
    end

    test "a Question withdrawn (Cancel) ends the run, once" do
      question = ask!("walk-1")
      state = orchestrator_state(1) |> run(issue("walk-1", "TP-1", "In Progress")) |> step(answer_wanted(question))

      {:ok, _withdrawn} = Questions.withdraw({:ticket, "default", "walk-1"}, question.id, "The ticket was cancelled.")
      {:noreply, state} = Orchestrator.handle_info({:ticket_record, "default", "walk-1", :changed, [:pause]}, state)
      assert_received {:run_step_question_ended, "walk-1"}
      assert %{step: %{waiting: "ended"}} = running_of(state, "walk-1")

      {:noreply, _state} = Orchestrator.handle_info({:ticket_record, "default", "walk-1", :changed, [:pause]}, state)
      refute_received {:run_step_question_ended, "walk-1"}
      refute_received {:run_step_turn, "walk-1"}
    end
  end

  test "a step notice for a run that already ended changes nothing" do
    state = orchestrator_state(1)
    assert step(state, machine_notice(), "gone") == state
  end

  defp issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "Ticket #{identifier}", description: "Do it", state: state, priority: 3, labels: [], url: "https://example.org/#{identifier}"}
  end

  defp run(state, %Issue{} = issue, attrs \\ []) do
    entry =
      Map.merge(
        %{
          pid: self(),
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          run_profile: %{kind: :implementation, model: nil, effort: nil, provider: "anthropic"},
          session_id: nil,
          turn_count: 1,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          started_at: DateTime.utc_now()
        },
        Map.new(attrs)
      )

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
