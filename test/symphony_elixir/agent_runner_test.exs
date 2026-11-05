defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Questions, TicketEvents}

  @issue_id "issue-walk"

  defmodule WalkAgent do
    # Coding-agent stand-in: reports each session start and stop and each turn with its prompt.
    def start_session(_workspace, _opts) do
      count = Application.get_env(:symphony_elixir, :walk_agent_sessions, 0) + 1
      Application.put_env(:symphony_elixir, :walk_agent_sessions, count)
      send(Application.fetch_env!(:symphony_elixir, :walk_agent_recipient), {:session_started, count})
      {:ok, %{session: count}}
    end

    def run_turn(%{session: session}, prompt, _issue, _opts) do
      count = Application.get_env(:symphony_elixir, :walk_agent_turns, 0) + 1
      Application.put_env(:symphony_elixir, :walk_agent_turns, count)
      send(Application.fetch_env!(:symphony_elixir, :walk_agent_recipient), {:turn, count, session, prompt})
      {:ok, %{session_id: "sess-#{count}"}}
    end

    def stop_session(%{session: session}) do
      send(Application.fetch_env!(:symphony_elixir, :walk_agent_recipient), {:session_stopped, session})
      :ok
    end
  end

  setup do
    :ok = RunStore.clear()
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-walk-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "TP-900")
    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root, max_turns: 6)
    Application.put_env(:symphony_elixir, :walk_agent_recipient, self())

    on_exit(fn ->
      for key <- [:walk_agent_recipient, :walk_agent_sessions, :walk_agent_turns],
          do: Application.delete_env(:symphony_elixir, key)

      File.rm_rf(test_root)
    end)

    %{workspace: workspace}
  end

  # The step commands: the changed-files script reports an Elixir change, and each other command
  # answers from the first of `results` whose pattern it holds (the last answer repeating), else
  # passes; each is told to the test.
  defp step_runner(results) do
    parent = self()

    fn command, _env, _timeout_ms ->
      if command =~ "git merge-base", do: {:ok, {"M\tlib/app.ex\n", 0}}, else: answer(command, results, parent)
    end
  end

  defp answer(command, results, parent) do
    send(parent, {:step_command, command})

    case Enum.find(results, fn {pattern, _answers} -> command =~ pattern end) do
      nil ->
        {:ok, {"", 0}}

      {pattern, answers} ->
        count = Process.get({:walk_answers, pattern}, 0)
        Process.put({:walk_answers, pattern}, count + 1)
        Enum.at(answers, count) || List.last(answers)
    end
  end

  # Runs the issue in a task, as the orchestrator does, with the test as its orchestrator.
  defp start_run(ctx, results, fetcher) do
    issue = %Issue{id: @issue_id, identifier: "TP-900", title: "Walk the steps", description: "Walk", state: "In Progress"}

    runner = step_runner(results)

    Task.async(fn ->
      try do
        AgentRunner.run(issue, self_or(ctx),
          workspace_path: ctx.workspace,
          agent_module: WalkAgent,
          issue_state_fetcher: fetcher,
          issue_enricher: fn issue -> {:ok, issue} end,
          step_command_runner: runner
        )
      rescue
        error -> {:raised, error}
      end
    end)
  end

  defp self_or(%{orchestrator: pid}), do: pid

  defp in_progress_for(fetches) do
    counter = :counters.new(1, [])

    fn [_id] ->
      :counters.add(counter, 1, 1)
      state = if :counters.get(counter, 1) > fetches, do: "Done", else: "In Progress"
      {:ok, [%Issue{id: @issue_id, identifier: "TP-900", title: "Walk the steps", state: state}]}
    end
  end

  defp step_events, do: @issue_id |> TicketEvents.query(types: ["step.started", "step.completed"], limit: 200) |> Enum.sort_by(& &1.seq)

  test "a failed build ends the session, frees the slot, and the next turn's new session writes the code again with the output", ctx do
    ctx = Map.put(ctx, :orchestrator, self())
    task = start_run(ctx, [{"mix compile", [{:ok, {"error: undefined function boom/0", 1}}, {:ok, {"compiled", 0}}]}], in_progress_for(2))

    # The code step: one turn in the first session.
    assert_receive {:session_started, 1}, 5_000
    assert_receive {:turn, 1, 1, first_prompt}
    assert first_prompt =~ "This turn is the `code` step (Write the code)"

    # The build runs with the session stopped, and the orchestrator hears of it.
    assert_receive {:session_stopped, 1}
    assert_receive {:run_step, @issue_id, {:machine, %{id: "build", mode: "machine", deadline: %DateTime{}}}}
    assert_receive {:step_command, "mix compile --warnings-as-errors"}
    refute_received {:session_started, 2}

    # The next agent turn waits for the orchestrator's slot.
    assert_receive {:run_step, @issue_id, {:turn_wanted, runner, %{id: "code", mode: "delegated"}}}
    refute_receive {:session_started, 2}, 100
    send(runner, {:run_step_turn, @issue_id})

    assert_receive {:session_started, 2}
    assert_receive {:turn, 2, 2, retry_prompt}
    assert retry_prompt =~ "This turn is the `code` step"
    assert retry_prompt =~ "The `build` step (Build) failed"
    assert retry_prompt =~ "error: undefined function boom/0"
    assert retry_prompt =~ "Symphony runtime context:"

    # The build passes, then the checks and the tests, and the handoff turn starts.
    assert_receive {:session_stopped, 2}
    assert_receive {:run_step, @issue_id, {:turn_wanted, runner, %{id: "handoff"}}}, 5_000
    send(runner, {:run_step_turn, @issue_id})
    assert_receive {:turn, 3, 3, handoff_prompt}
    assert handoff_prompt =~ "This turn is the `handoff` step"
    refute handoff_prompt =~ "failed"

    assert :ok = Task.await(task, 10_000)
    assert_receive {:session_stopped, 3}

    completed = for %{type: "step.completed", payload: payload} <- step_events(), do: {payload.step_id, payload.outcome, Map.get(payload, :returns_to)}

    assert completed == [
             {"code", "passed", nil},
             {"build", "failed", "code"},
             {"code", "passed", nil},
             {"build", "passed", nil},
             {"checks", "passed", nil},
             {"tests", "passed", nil}
           ]
  end

  test "machine steps with nothing to run leave the session open and the slot held", ctx do
    ctx = Map.put(ctx, :orchestrator, self())
    issue = %Issue{id: @issue_id, identifier: "TP-900", title: "Walk the steps", description: "Walk", state: "In Progress"}
    nothing_changed = fn _command, _env, _timeout -> {:ok, {"", 0}} end

    task =
      Task.async(fn ->
        AgentRunner.run(issue, self_or(ctx),
          workspace_path: ctx.workspace,
          agent_module: WalkAgent,
          issue_state_fetcher: in_progress_for(1),
          issue_enricher: fn issue -> {:ok, issue} end,
          step_command_runner: nothing_changed
        )
      end)

    assert_receive {:turn, 1, 1, _prompt}, 5_000
    assert_receive {:turn, 2, 1, handoff_prompt}
    assert handoff_prompt =~ "This turn is the `handoff` step"
    assert :ok = Task.await(task, 10_000)
    refute_received {:run_step, @issue_id, _notice}
    assert_received {:session_started, 1}
    refute_received {:session_started, 2}

    skipped = for %{type: "step.completed", payload: %{outcome: "skipped"} = payload} <- step_events(), do: payload.step_id
    assert skipped == ["build", "checks", "tests"]
  end

  test "a test that hangs twice pauses the run on a Question and ends it", ctx do
    ctx = Map.put(ctx, :orchestrator, self())
    task = start_run(ctx, [{"mix test", [{:timeout, "hanging"}]}], in_progress_for(5))

    assert_receive {:turn, 1, 1, _prompt}, 5_000
    assert :ok = Task.await(task, 10_000)
    refute_received {:run_step, @issue_id, {:turn_wanted, _runner, _step}}

    assert [%{step: "tests", state: :open}] = Questions.open({:ticket, "default", @issue_id})
    assert %{payload: %{step_id: "tests", outcome: "paused"}} = step_events() |> List.last()
  end

  test "a run whose orchestrator is gone while it waits for a turn fails", ctx do
    {:ok, orchestrator} = Agent.start(fn -> nil end)
    ctx = Map.put(ctx, :orchestrator, orchestrator)
    task = start_run(ctx, [{"mix compile", [{:ok, {"error", 1}}]}], in_progress_for(3))

    assert_receive {:turn, 1, 1, _prompt}, 5_000
    assert_receive {:step_command, "mix compile --warnings-as-errors"}
    Agent.stop(orchestrator)

    assert {:raised, %RuntimeError{message: message}} = Task.await(task, 10_000)
    assert message =~ "orchestrator_down"
  end
end
