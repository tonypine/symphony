defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.{Pauses, Questions, TicketEvents}

  @issue_id "issue-walk"
  @run_id "run-walk"
  @ticket {:ticket, "default", "issue-walk"}

  defmodule WalkAgent do
    # Coding-agent stand-in: reports each session start and stop and each turn with its prompt, and
    # in each turn does what the test's script says (`:walk_agent_script`, called with the turn's
    # number, prompt and options); by default it records the delegated step the prompt names as
    # passed, as an agent does through `ticket_record`.
    def start_session(_workspace, opts) do
      count = Application.get_env(:symphony_elixir, :walk_agent_sessions, 0) + 1
      Application.put_env(:symphony_elixir, :walk_agent_sessions, count)
      recipient = Application.fetch_env!(:symphony_elixir, :walk_agent_recipient)
      send(recipient, {:session_started, count})
      send(recipient, {:session_unlocks, count, Keyword.get(opts, :unlocked_paths)})
      {:ok, %{session: count}}
    end

    def run_turn(%{session: session}, prompt, _issue, opts) do
      count = Application.get_env(:symphony_elixir, :walk_agent_turns, 0) + 1
      Application.put_env(:symphony_elixir, :walk_agent_turns, count)
      recipient = Application.fetch_env!(:symphony_elixir, :walk_agent_recipient)
      send(recipient, {:turn, count, session, prompt})
      send(recipient, {:turn_resumes, count, Keyword.get(opts, :resume_session_id)})
      script = Application.get_env(:symphony_elixir, :walk_agent_script, &record_step/3)
      script.(count, prompt, opts)
      {:ok, %{session_id: "sess-#{count}"}}
    end

    def record_step(_count, prompt, opts) do
      with [_match, id] <- Regex.run(~r/This turn is the `(\w+)` step/, prompt),
           true <- prompt =~ "End this step by recording `step.completed`" do
        payload = %{step_id: id, title: id, mode: "delegated", outcome: "passed"}
        run_id = Keyword.get(opts, :run_id)
        {:ok, _event} = TicketEvents.record("default", "issue-walk", "step.completed", payload, actor: {:agent, run_id, "implementation"}, run_id: run_id)
      end

      :ok
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
      for key <- [:walk_agent_recipient, :walk_agent_sessions, :walk_agent_turns, :walk_agent_script],
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
  defp start_run(ctx, results, fetcher, extra \\ []) do
    issue = %Issue{id: @issue_id, identifier: "TP-900", title: "Walk the steps", description: "Walk", state: "In Progress"}

    runner = Keyword.get(extra, :runner, step_runner(results))

    Task.async(fn ->
      try do
        AgentRunner.run(
          issue,
          self_or(ctx),
          [
            workspace_path: ctx.workspace,
            agent_module: WalkAgent,
            issue_state_fetcher: fetcher,
            issue_enricher: fn issue -> {:ok, issue} end,
            step_command_runner: runner,
            run_id: @run_id
          ] ++ Keyword.delete(extra, :runner)
        )
      rescue
        error -> {:raised, error}
      end
    end)
  end

  defp self_or(%{orchestrator: pid}), do: pid
  defp self_or(_ctx), do: nil

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
    refute handoff_prompt =~ "step (Build) failed"

    assert :ok = Task.await(task, 10_000)
    assert_receive {:session_stopped, 3}

    completed = for %{type: "step.completed", payload: payload} <- step_events(), do: {payload.step_id, payload.outcome, Map.get(payload, :returns_to)}

    assert completed == [
             {"code", "passed", nil},
             {"build", "failed", "code"},
             {"code", "passed", nil},
             {"build", "passed", nil},
             {"checks", "passed", nil},
             {"tests", "passed", nil},
             {"handoff", "passed", nil}
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
          step_command_runner: nothing_changed,
          run_id: @run_id
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

  test "a test that hangs twice pauses the run on a Question with no session; going on past it resumes the run at once", ctx do
    ctx = Map.put(ctx, :orchestrator, self())
    task = start_run(ctx, [{"mix test", [{:timeout, "hanging"}]}], in_progress_for(5))

    assert_receive {:turn, 1, 1, _prompt}, 5_000
    assert_receive {:run_step, @issue_id, {:answer_wanted, runner, %{id: "tests", mode: "machine"}, question_id}}, 5_000
    assert_received {:session_stopped, 1}
    assert [%{id: ^question_id, step: "tests", state: :open}] = Questions.open(@ticket)
    assert %{payload: %{step_id: "tests", outcome: "paused", question_id: ^question_id}} = step_events() |> List.last()

    {:ok, _answered} = Questions.answer(@ticket, question_id, "Go on past it")
    send(runner, {:run_step_turn, @issue_id})

    assert_receive {:turn, 2, 2, handoff_prompt}, 5_000
    assert handoff_prompt =~ "This turn is the `handoff` step"
    assert :ok = Task.await(task, 10_000)
  end

  test "a hung step run again runs once more, and the person's own words go to the agent step it returns to", ctx do
    ctx = Map.put(ctx, :orchestrator, self())
    task = start_run(ctx, [{"mix test", [{:timeout, "hanging"}, {:timeout, "hanging"}, {:ok, {"ok", 0}}]}], in_progress_for(6))

    assert_receive {:run_step, @issue_id, {:answer_wanted, runner, %{id: "tests"}, question_id}}, 5_000
    {:ok, _answered} = Questions.answer(@ticket, question_id, "Run it again")
    send(runner, {:run_step_turn, @issue_id})

    # The third attempt passes, and the run hands off.
    assert_receive {:run_step, @issue_id, {:turn_wanted, ^runner, %{id: "handoff"}}}, 5_000
    send(runner, {:run_step_turn, @issue_id})
    assert_receive {:turn, 2, 2, _handoff}, 5_000
    assert :ok = Task.await(task, 10_000)

    # Another run: the tests hang twice again, and the person answers in their own words.
    Application.put_env(:symphony_elixir, :walk_agent_turns, 0)
    task = start_run(ctx, [{"mix test", [{:timeout, "hanging"}]}], in_progress_for(6))
    assert_receive {:run_step, @issue_id, {:answer_wanted, runner, %{id: "tests"}, question_id}}, 5_000
    {:ok, _answered} = Questions.answer(@ticket, question_id, "Skip the slow suite and say so in the PR")
    send(runner, {:run_step_turn, @issue_id})

    assert_receive {:turn, 2, _session, code_prompt}, 5_000
    assert code_prompt =~ "This turn is the `code` step"
    assert code_prompt =~ "Answer: Skip the slow suite and say so in the PR"
    Task.shutdown(task, :brutal_kill)
  end

  test "an agent that asks a person pauses its step with no session; the answer resumes the same step in the same run, with the question and the answer", ctx do
    ctx = Map.put(ctx, :orchestrator, self())

    Application.put_env(:symphony_elixir, :walk_agent_script, fn
      1, _prompt, _opts -> {:ok, _question} = Questions.ask(@ticket, layout_request(), asked_by: %{kind: :run, name: "The run"}, request: true)
      count, prompt, opts -> WalkAgent.record_step(count, prompt, opts)
    end)

    task = start_run(ctx, [], in_progress_for(5))

    assert_receive {:turn, 1, 1, _prompt}, 5_000
    assert_receive {:run_step, @issue_id, {:answer_wanted, runner, %{id: "code", mode: "delegated"}, question_id}}, 5_000
    assert_received {:session_stopped, 1}
    assert %{payload: %{step_id: "code", outcome: "paused", question_id: ^question_id}, run_id: @run_id} = List.last(step_events())
    assert Pauses.paused?(@ticket)

    # The orchestrator lets it go once the question is answered.
    {:ok, _answered} = Questions.answer(@ticket, question_id, "2")
    send(runner, {:run_step_turn, @issue_id})

    assert_receive {:session_started, 2}, 5_000
    assert_receive {:turn, 2, 2, resumed}
    assert_receive {:turn_resumes, 2, "sess-1"}
    assert resumed =~ "This turn is the `code` step"
    assert resumed =~ "Question: Which layout should the settings page use: one column or two?"
    assert resumed =~ "Answer: 2"
    assert resumed =~ "Symphony runtime context:"

    # The run goes on: its next steps are under the same run.
    assert_receive {:run_step, @issue_id, {:turn_wanted, ^runner, %{id: "handoff"}}}, 5_000
    send(runner, {:run_step_turn, @issue_id})
    assert_receive {:turn, 3, 3, _handoff}
    assert_receive {:turn_resumes, 3, nil}
    assert :ok = Task.await(task, 10_000)

    assert step_events() |> Enum.map(& &1.run_id) |> Enum.uniq() == [@run_id]
  end

  test "a protected-path request the agent asks mid-step resumes the step in a session that may write the path the answer unlocks", ctx do
    ctx = Map.put(ctx, :orchestrator, self())

    request = %{
      layout_request()
      | title: "Change the workflow settings",
        options: [
          %{label: "Allow this ticket to change the workflow settings file", effect: "The run changes it.", recommended: true, unlocks: ["WORKFLOW.md"]},
          %{label: "Keep it as it is", effect: "The run leaves it."}
        ]
    }

    Application.put_env(:symphony_elixir, :walk_agent_script, fn
      1, _prompt, _opts -> {:ok, _question} = Questions.ask(@ticket, request, asked_by: %{kind: :run, name: "The run"}, request: true)
      count, prompt, opts -> WalkAgent.record_step(count, prompt, opts)
    end)

    task = start_run(ctx, [], in_progress_for(5))

    assert_receive {:session_unlocks, 1, []}, 5_000
    assert_receive {:run_step, @issue_id, {:answer_wanted, runner, %{id: "code"}, question_id}}, 5_000
    {:ok, _answered} = Questions.answer(@ticket, question_id, "1")
    send(runner, {:run_step_turn, @issue_id})

    assert_receive {:session_unlocks, 2, ["WORKFLOW.md"]}, 5_000
    assert_receive {:turn, 2, 2, resumed}
    assert resumed =~ "Protected paths unlocked for this run:"
    assert resumed =~ "`WORKFLOW.md`"
    Task.shutdown(task, :brutal_kill)
  end

  test "a paused step whose question is withdrawn (Cancel), or that has no orchestrator to wait with, ends the run", ctx do
    Application.put_env(:symphony_elixir, :walk_agent_script, fn count, _prompt, _opts ->
      {:ok, _question} = Questions.ask(@ticket, %{layout_request() | title: "Pick the settings layout #{count}"}, asked_by: %{kind: :run, name: "The run"}, request: true)
    end)

    task = start_run(Map.put(ctx, :orchestrator, self()), [], in_progress_for(5))
    assert_receive {:run_step, @issue_id, {:answer_wanted, runner, _step, _question_id}}, 5_000
    send(runner, {:run_step_question_ended, @issue_id})
    assert :ok = Task.await(task, 10_000)

    assert :ok = ctx |> start_run([], in_progress_for(5)) |> Task.await(10_000)
    assert_received {:session_started, 2}
    refute_received {:session_started, 3}
  end

  test "an answer the run can't resume on ends it: the ticket moved on, or something else holds it", ctx do
    ctx = Map.put(ctx, :orchestrator, self())

    Application.put_env(:symphony_elixir, :walk_agent_script, fn count, _prompt, _opts ->
      {:ok, _question} = Questions.ask(@ticket, %{layout_request() | title: "Pick the settings layout #{count}"}, asked_by: %{kind: :run, name: "The run"}, request: true)
    end)

    task = start_run(ctx, [], in_progress_for(5))
    assert_receive {:run_step, @issue_id, {:answer_wanted, runner, _step, question_id}}, 5_000
    {:ok, _answered} = Questions.answer(@ticket, question_id, "1")
    {:ok, _pause} = Pauses.set(@ticket, %{kind: :person, waits_on: %{action: "unblock"}})
    send(runner, {:run_step_turn, @issue_id})
    assert :ok = Task.await(task, 10_000)
    refute_received {:session_started, 2}

    {:ok, _cleared} = Pauses.clear_reason(@ticket, %{kind: :person, waits_on: %{action: "unblock"}})
    :ok = RunStore.put_ticket_state(SymphonyElixir.TicketState.new("default", @issue_id, phase: "Rework"))
    task = start_run(ctx, [], in_progress_for(5))
    assert_receive {:run_step, @issue_id, {:answer_wanted, runner, _step, question_id}}, 5_000
    {:ok, _answered} = Questions.answer(@ticket, question_id, "1")
    send(runner, {:run_step_turn, @issue_id})
    assert :ok = Task.await(task, 10_000)
    refute_received {:session_started, 3}
  end

  describe "a rework run" do
    defp rework_profile do
      AgentRunner.run_profile(%Issue{id: @issue_id, identifier: "TP-900", title: "Walk the steps", state: "Rework"}, Config.settings!())
    end

    defp fail_qa!(run_id, description) do
      payload = %{class: "clipped", severity: "major", description: description}
      {:ok, _event} = TicketEvents.record("default", @issue_id, "finding.recorded", payload, actor: {:agent, run_id, "qa"}, run_id: run_id)
    end

    test "whose QA failed twice on one class pauses before any agent turn, and the answer reaches the code step", ctx do
      ctx = Map.put(ctx, :orchestrator, self())
      fail_qa!("qa-1", "The table is clipped")
      fail_qa!("qa-2", "The header is clipped")

      task = start_run(ctx, [], in_progress_for(5), run_profile: rework_profile())

      assert_receive {:run_step, @issue_id, {:answer_wanted, runner, %{id: "findings"}, question_id}}, 5_000
      refute_received {:session_started, _count}
      refute_received {:turn, _count, _session, _prompt}
      refute_received {:run_step, @issue_id, {:machine, _step}}

      {:ok, _answered} = Questions.answer(@ticket, question_id, "1")
      send(runner, {:run_step_turn, @issue_id})

      assert_receive {:turn, 1, 1, prompt}, 5_000
      assert prompt =~ "This turn is the `code` step"
      assert prompt =~ "Question: QA failed TP-900 twice on clipped."
      Task.shutdown(task, :brutal_kill)
    end

    test "with nothing repeated starts on the code step in its slot", ctx do
      ctx = Map.put(ctx, :orchestrator, self())
      fail_qa!("qa-1", "The table is clipped")

      task = start_run(ctx, [], in_progress_for(5), run_profile: rework_profile())

      assert_receive {:turn, 1, 1, prompt}, 5_000
      assert prompt =~ "This turn is the `code` step"
      refute_received {:run_step, @issue_id, {:machine, %{id: "findings"}}}
      refute_received {:run_step, @issue_id, {:turn_wanted, _runner, %{id: "code"}}}
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "a run that is gone by the answer leaves the next run to resume the step on it", ctx do
    ctx = Map.put(ctx, :orchestrator, self())
    {:ok, question} = Questions.ask(@ticket, layout_request(), asked_by: %{kind: :run, name: "The run"}, request: true)
    payload = %{step_id: "code", title: "Write the code", mode: "delegated", outcome: "paused", question_id: question.id}
    {:ok, _event} = TicketEvents.record("default", @issue_id, "step.completed", payload, run_id: "run-gone")
    {:ok, _answered} = Questions.answer(@ticket, question.id, "1")

    task = start_run(ctx, [], in_progress_for(5))
    assert_receive {:turn, 1, 1, resumed}, 5_000
    assert resumed =~ "This turn is the `code` step"
    assert resumed =~ "Answer: 1"
    assert_receive {:run_step, @issue_id, {:turn_wanted, runner, %{id: "handoff"}}}, 5_000
    send(runner, {:run_step_turn, @issue_id})
    assert :ok = Task.await(task, 10_000)
  end

  test "a delegated step whose agent records no end is retried once with a reminder, then fails back to itself with a note", ctx do
    ctx = Map.put(ctx, :orchestrator, self())
    Application.put_env(:symphony_elixir, :walk_agent_script, fn _count, _prompt, _opts -> :ok end)
    task = start_run(ctx, [], in_progress_for(5))

    assert_receive {:turn, 1, 1, first}, 5_000
    refute first =~ "Reminder"
    assert_receive {:turn, 2, 1, reminder}
    assert reminder =~ "Reminder: the last turn ended without recording `step.completed` for the `code` step."
    assert :ok = Task.await(task, 10_000)
    refute_received {:turn, 3, _session, _prompt}
    refute_received {:run_step, @issue_id, _notice}

    assert [%{payload: %{step_id: "code"}}] = for(%{type: "step.started"} = event <- step_events(), do: event)
    assert [%{payload: failed, actor: %{kind: :machine}}] = step_completed()
    assert %{step_id: "code", outcome: "failed", returns_to: "code", returns_to_title: "Write the code"} = failed

    assert [%{payload: %{text: "The agent ended two turns of the Write the code step without recording how it ended."}}] =
             TicketEvents.query(@issue_id, types: ["note"])
  end

  test "an agent step may fail back to an earlier step, or to one the list lacks, which ends the walk", ctx do
    ctx = Map.put(ctx, :orchestrator, self())

    Application.put_env(:symphony_elixir, :walk_agent_script, fn
      count, prompt, opts when count in [1, 3] -> WalkAgent.record_step(count, prompt, opts)
      2, _prompt, opts -> record_agent!("handoff", %{outcome: "failed", returns_to: "code"}, opts)
      _count, _prompt, opts -> record_agent!("handoff", %{outcome: "failed", returns_to: "nowhere"}, opts)
    end)

    task = start_run(ctx, [], in_progress_for(5), runner: fn _command, _env, _timeout -> {:ok, {"", 0}} end)

    assert_receive {:turn, 2, 1, handoff}, 5_000
    assert handoff =~ "This turn is the `handoff` step"
    assert_receive {:turn, 3, 1, code}
    assert code =~ "This turn is the `code` step"
    assert_receive {:turn, 4, 1, handoff_again}
    assert handoff_again =~ "This turn is the `handoff` step"
    assert_receive {:turn, 5, 1, plain}
    refute plain =~ "Step runner:"
    Task.shutdown(task, :brutal_kill)
  end

  describe "an orchestrated step" do
    setup ctx do
      write_symphony_steps!("""
      phases:
        implementation:
          steps:
            - {id: code, title: Write the code, mode: delegated}
            - {id: layout, title: Pick a layout, mode: orchestrated, prompt: Pick the layout the ticket wants., answer: {layout: string}, on_fail: code}
            - {id: build, mode: machine, command: make build, on_fail: code}
      """)

      ctx
    end

    test "its answer is checked: one that misses is retried once, a good one is a note in the next turns' prompts", ctx do
      ctx = Map.put(ctx, :orchestrator, self())
      # The agent writes its answer in the run's own temp folder, where the prompt says.
      answer = fn opts, text -> opts |> Keyword.fetch!(:agent_tmp_dir) |> Path.join("symphony-step-answer-layout.json") |> File.write!(text) end

      Application.put_env(:symphony_elixir, :walk_agent_script, fn
        2, _prompt, opts -> answer.(opts, ~s({"columns": 2}))
        3, _prompt, opts -> answer.(opts, ~s({"layout": "two columns"}))
        count, prompt, opts -> WalkAgent.record_step(count, prompt, opts)
      end)

      task = start_run(ctx, [], in_progress_for(6), runner: local_runner())

      assert_receive {:turn, 2, 1, first}, 5_000
      assert first =~ "Pick the layout the ticket wants."
      assert first =~ ~r"writing your answer as one JSON object to `/\S+/symphony-step-answer-layout.json`, with the fields `layout` \(string\)"
      assert_receive {:turn, 3, 1, retry}
      assert retry =~ "Your last answer was refused: the answer lacks `layout` (string)."

      # The build fails back to the code step, whose prompt now carries the layout's answer.
      assert_receive {:run_step, @issue_id, {:turn_wanted, runner, %{id: "code"}}}, 5_000
      send(runner, {:run_step_turn, @issue_id})
      assert_receive {:turn, 4, 2, again}
      assert again =~ ~s|`layout` (Pick a layout): {"layout":"two columns"}|
      Task.shutdown(task, :brutal_kill)

      assert [%{payload: %{text: ~s|The Pick a layout step answered: {"layout":"two columns"}|}}] = TicketEvents.query(@issue_id, types: ["note"])
    end

    test "one refused twice fails the step to its on_fail, and the run ends", ctx do
      ctx = Map.put(ctx, :orchestrator, self())
      task = start_run(ctx, [], in_progress_for(6), runner: local_runner())

      assert_receive {:turn, 3, 1, _second_layout}, 5_000
      assert :ok = Task.await(task, 10_000)

      assert [%{payload: code}, %{payload: layout}] = step_completed()
      assert %{step_id: "code", outcome: "passed"} = code
      assert %{step_id: "layout", outcome: "failed", returns_to: "code"} = layout
      assert [%{payload: %{text: "The Pick a layout step's answer was refused twice: no answer was written to " <> _path}}] = TicketEvents.query(@issue_id, types: ["note"])
    end
  end

  # A command runner on this host for the answer file; the build answers from the test.
  defp local_runner do
    fn
      "cat " <> _path = command, _env, _timeout -> command |> String.to_charlist() |> :os.cmd() |> to_string() |> then(&{:ok, {&1, if(&1 =~ "No such file", do: 1, else: 0)}})
      "rm -f " <> _path = command, _env, _timeout -> command |> String.to_charlist() |> :os.cmd() |> then(fn _out -> {:ok, {"", 0}} end)
      "git merge-base" <> _rest = command, env, timeout -> step_runner([]).(command, env, timeout)
      command, env, timeout -> step_runner([{"make build", [{:ok, {"broken", 1}}, {:ok, {"built", 0}}]}]).(command, env, timeout)
    end
  end

  # Sets the implementation step list in `symphony.yml`, replacing one set before.
  defp write_symphony_steps!(yaml) do
    path = Workflow.symphony_file_path()
    [base | _set_before] = String.split(File.read!(path), "\n# steps\n")
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, base <> "\n# steps\n" <> yaml)
    File.touch!(tmp, System.os_time(:second) + 2)
    File.rename!(tmp, path)
    Cache.clear()
    SymphonyElixir.TestSupport.settle_config_cache!([path])
  end

  defp step_completed, do: for(%{type: "step.completed"} = event <- step_events(), do: event)

  defp record_agent!(step_id, fields, opts) do
    payload = Map.merge(%{step_id: step_id, title: step_id, mode: "delegated"}, fields)
    run_id = Keyword.get(opts, :run_id)
    {:ok, _event} = TicketEvents.record("default", @issue_id, "step.completed", payload, actor: {:agent, run_id, "implementation"}, run_id: run_id)
    :ok
  end

  defp layout_request do
    %{
      title: "Pick the settings layout",
      question: "Which layout should the settings page use: one column or two?",
      why: "The ticket shows both layouts. Only you can say which one it wants.",
      if_unanswered: "The ticket stays paused on its code step.",
      recommendation_reason: "One column matches the rest of the app.",
      options: [
        %{label: "One column", effect: "The run builds the page in one column.", recommended: true},
        %{label: "Two columns", effect: "The run builds the page in two columns."}
      ]
    }
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
