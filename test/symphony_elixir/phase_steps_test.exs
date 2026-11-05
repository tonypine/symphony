defmodule SymphonyElixir.PhaseStepsTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Artifacts, DecisionRequest, PhaseSteps, Questions, TicketEvents, TicketState}
  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.Config.Schema.Phases.Step

  @repo_key "default"
  @issue_id "issue-steps"
  @changed %{changed: ["lib/symphony_elixir/foo.ex"], existing: ["lib/symphony_elixir/foo.ex"], tests: ["test/symphony_elixir/foo_test.exs"]}
  @unchanged %{changed: [], existing: [], tests: []}

  setup do
    :ok = RunStore.clear()
    workspace = Path.join(System.tmp_dir!(), "symphony-phase-steps-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  defp steps(list \\ default_list()) do
    %Phases.Phase{}
    |> Phases.Phase.changeset(%{"steps" => list})
    |> Ecto.Changeset.apply_action!(:validate)
    |> Map.fetch!(:steps)
  end

  defp default_list do
    [
      %{"id" => "code", "title" => "Write the code", "mode" => "delegated"},
      %{"id" => "build", "title" => "Build", "mode" => "machine", "command" => "make build", "on_fail" => "code", "timeout_ms" => 5_000},
      %{"id" => "tests", "title" => "Tests", "mode" => "machine", "command" => "make test", "on_fail" => "code", "timeout_ms" => 5_000},
      %{"id" => "handoff", "title" => "Hand off", "mode" => "delegated"}
    ]
  end

  defp step(steps, id), do: Enum.find(steps, &(&1.id == id))

  # A command runner that answers each command from `results` (a map of command to a list of
  # results, the last one repeating) and tells the test what it ran and with which environment.
  defp runner(results) do
    parent = self()

    fn command, env, timeout_ms ->
      send(parent, {:ran, command, env, timeout_ms})
      key = {:runs, command}
      count = Process.get(key, 0)
      Process.put(key, count + 1)
      answers = Map.fetch!(results, command)
      Enum.at(answers, count) || List.last(answers)
    end
  end

  defp context(ctx, results, extra \\ %{}) do
    parent = self()

    Map.merge(
      %{
        repo_key: @repo_key,
        issue_id: @issue_id,
        identifier: "TP-77",
        phase: "In Progress",
        run_id: "run-steps",
        workspace: ctx.workspace,
        changes: @changed,
        runner: runner(results),
        on_step: &send(parent, {:notice, &1})
      },
      extra
    )
  end

  defp events(type), do: @issue_id |> TicketEvents.query(types: [type], limit: 200) |> Enum.sort_by(& &1.seq)

  describe "the step list" do
    test "a run walks its list only when a step of it is a machine step" do
      assert [%Step{id: "code"} | _rest] = implementation = PhaseSteps.steps(:implementation)
      assert PhaseSteps.walk?(implementation)
      assert PhaseSteps.steps(:implementation, {:error, {:missing_symphony_file, "symphony.yml", :enoent}}) == implementation
      assert PhaseSteps.steps(:implementation, {:error, :unreadable}) == []
      assert PhaseSteps.steps(:code_review) == []
      assert PhaseSteps.steps(:close_out) == []
      refute PhaseSteps.walk?(steps([%{"id" => "code", "mode" => "delegated"}]))
      refute PhaseSteps.machine?(:not_a_step)
    end

    test "a step that passed goes to the next one, a failed one to its on_fail, and the list ends" do
      steps = steps()

      assert {:ok, %Step{id: "build"}} = PhaseSteps.next(steps, step(steps, "code"), :passed)
      assert {:ok, %Step{id: "code"}} = PhaseSteps.next(steps, step(steps, "tests"), :failed)
      assert :end = PhaseSteps.next(steps, step(steps, "handoff"), :passed)
      assert :end = PhaseSteps.next(steps, step(steps, "handoff"), :failed)
    end
  end

  describe "the changed files" do
    test "a workspace's changes against its base branch, committed or not, and its test files, as a step's conditions and environment read them", ctx do
      git = &System.cmd("git", ["-C", ctx.workspace | &1], stderr_to_stdout: true)
      git.(["init", "-q", "-b", "main"])
      git.(["config", "user.email", "test@example.com"])
      git.(["config", "user.name", "Test"])

      for path <- ["lib/app/gone.ex", "lib/app/kept.ex", "test/app/kept_test.exs", "README.md"] do
        File.mkdir_p!(Path.join(ctx.workspace, Path.dirname(path)))
        File.write!(Path.join(ctx.workspace, path), "x")
      end

      git.(["add", "."])
      git.(["commit", "-q", "-m", "base"])
      File.rm!(Path.join(ctx.workspace, "lib/app/gone.ex"))
      File.write!(Path.join(ctx.workspace, "lib/app/kept.ex"), "changed")
      File.mkdir_p!(Path.join(ctx.workspace, "macos/Sources/DirectorApp"))
      File.write!(Path.join(ctx.workspace, "macos/Sources/DirectorApp/View.swift"), "new")

      changes = PhaseSteps.changes(%{workspace: ctx.workspace, base_branch: "main"})

      assert Enum.sort(changes.changed) == ["lib/app/gone.ex", "lib/app/kept.ex", "macos/Sources/DirectorApp/View.swift"]
      assert Enum.sort(changes.existing) == ["lib/app/kept.ex", "macos/Sources/DirectorApp/View.swift"]
      assert changes.tests == ["test/app/kept_test.exs"]
      assert PhaseSteps.holds?("elixir_changed", changes)
      assert PhaseSteps.holds?("macos_changed", changes)
      assert PhaseSteps.holds?("always", @unchanged)

      assert PhaseSteps.step_env(changes) == %{
               "SYMPHONY_CHANGED_ELIXIR_FILES" => "lib/app/kept.ex",
               "SYMPHONY_CHANGED_TEST_FILES" => "test/app/kept_test.exs",
               "SYMPHONY_CHANGED_SWIFT_TEST_FILTER" => "DirectorAppTests"
             }
    end

    test "the environment names the changed test files and Swift test targets, and every Swift test when none", _ctx do
      changes = %{
        changed: [],
        existing: ["test/a_test.exs", "lib/b.exs", "mix.exs", "macos/Tests/DirectorAppTests/X.swift", "macos/Package.swift"],
        tests: []
      }

      assert %{
               "SYMPHONY_CHANGED_ELIXIR_FILES" => "test/a_test.exs lib/b.exs mix.exs",
               "SYMPHONY_CHANGED_TEST_FILES" => "test/a_test.exs",
               "SYMPHONY_CHANGED_SWIFT_TEST_FILTER" => "DirectorAppTests"
             } = PhaseSteps.step_env(changes)

      assert %{"SYMPHONY_CHANGED_SWIFT_TEST_FILTER" => "."} = PhaseSteps.step_env(@unchanged)
    end

    test "a workspace git can't read changed nothing", ctx do
      log =
        capture_log(fn ->
          failing = fn _command, _env, _timeout -> {:ok, {"fatal", 128}} end
          assert PhaseSteps.changes(%{workspace: ctx.workspace, runner: failing}) == @unchanged
        end)

      assert log =~ "could not read the changed files"
    end
  end

  describe "a machine step" do
    test "one that passes records its start and its end with the output kept, and the run goes on to the next agent step", ctx do
      steps = steps()

      assert {:turn, %Step{id: "handoff"}, nil} =
               PhaseSteps.run_machine_steps(
                 steps,
                 step(steps, "build"),
                 context(ctx, %{"make build" => [{:ok, {"built\n", 0}}], "make test" => [{:ok, {"", 0}}]})
               )

      assert_received {:ran, "make build", %{"SYMPHONY_CHANGED_ELIXIR_FILES" => "lib/symphony_elixir/foo.ex"} = env, timeout_ms}
      assert env["SYMPHONY_CHANGED_TEST_FILES"] == "test/symphony_elixir/foo_test.exs"
      assert timeout_ms <= 5_000
      assert_received {:notice, {:started, %Step{id: "build"}, %DateTime{}}}
      assert_received {:notice, {:finished, %Step{id: "build"}}}

      assert [%{payload: %{step_id: "build", mode: "machine", command: "make build"}}, %{payload: %{step_id: "tests"}}] = events("step.started")

      assert [build, tests] = events("step.completed")
      assert %{payload: %{step_id: "build", outcome: "passed", duration_ms: _}, artifacts: [artifact_id]} = build
      assert %{payload: %{step_id: "tests", outcome: "passed"}, artifacts: [_header_only]} = tests

      assert {:ok, %{kind: "step_output", label: "Build output"}} = Artifacts.get(artifact_id)
      assert {:ok, path} = Artifacts.path(artifact_id)
      assert File.read!(path) == "$ make build\nbuilt\n"
    end

    test "one that fails returns to the step its on_fail names with the output, which the next turn's prompt carries", ctx do
      steps = steps()

      assert {:turn, %Step{id: "code"} = code, %{step: %Step{id: "build"}, output: output} = carry} =
               PhaseSteps.run_machine_steps(steps, step(steps, "build"), context(ctx, %{"make build" => [{:ok, {"error: undefined function foo/0\n", 2}}]}))

      assert output =~ "error: undefined function foo/0"
      assert output =~ "(exit status 2)"
      refute_received {:ran, "make test", _env, _timeout}

      assert [%{payload: payload, summary: summary}] = events("step.completed")
      assert %{step_id: "build", outcome: "failed", returns_to: "code", returns_to_title: "Write the code"} = payload
      assert summary.title =~ "Build failed"
      assert summary.title =~ "back to Write the code"

      prompt = PhaseSteps.prompt_section(code, carry)
      assert prompt =~ "This turn is the `code` step (Write the code)"
      assert prompt =~ "The `build` step (Build) failed"
      assert prompt =~ "error: undefined function foo/0"
      assert prompt =~ "<step_output"
    end

    test "one that can't run fails like one that exits non-zero, and one with no on_fail ends the run", ctx do
      steps = steps([%{"id" => "code", "mode" => "delegated"}, %{"id" => "lint", "title" => "Lint", "mode" => "machine", "command" => "lint"}])

      assert {:end, %{step: %Step{id: "lint"}, output: output}} =
               PhaseSteps.run_machine_steps(steps, step(steps, "lint"), context(ctx, %{"lint" => [{:error, :enoent}]}))

      assert output =~ "could not run: :enoent"
      assert [%{payload: %{outcome: "failed", returns_to: "end", returns_to_title: "the end of the run"}}] = events("step.completed")
    end

    test "the last step passing ends the list", ctx do
      steps = steps([%{"id" => "code", "mode" => "delegated"}, %{"id" => "lint", "title" => "Lint", "mode" => "machine", "command" => "lint"}])

      context = ctx |> context(%{"lint" => [{:ok, {"ok", 0}}]}) |> Map.delete(:on_step)

      assert {:end, nil} = PhaseSteps.run_machine_steps(steps, step(steps, "lint"), context)
    end

    test "a step its when, or every command's, does not match is skipped with the reason, and runs nothing", ctx do
      steps =
        steps([
          %{"id" => "code", "mode" => "delegated"},
          %{"id" => "checks", "title" => "Checks", "mode" => "machine", "when" => "elixir_changed", "command" => "mix format"},
          %{
            "id" => "build",
            "title" => "Build",
            "mode" => "machine",
            "command" => [%{"run" => "swift build", "when" => "macos_changed"}, %{"run" => "mix compile", "when" => "elixir_changed"}]
          },
          %{"id" => "handoff", "mode" => "delegated"}
        ])

      context = context(ctx, %{}, %{changes: @unchanged})
      refute PhaseSteps.runs_anything?(steps, step(steps, "checks"), @unchanged)
      assert PhaseSteps.runs_anything?(steps, step(steps, "checks"), @changed)

      assert {:turn, %Step{id: "handoff"}, nil} = PhaseSteps.run_machine_steps(steps, step(steps, "checks"), context)
      refute_received {:ran, _command, _env, _timeout}
      assert events("step.started") == []

      assert [checks, %{payload: %{reason: reason}}] = events("step.completed")
      assert %{payload: %{step_id: "checks", outcome: "skipped", reason: "no Elixir changed"}} = checks
      assert checks.summary.title == "Checks skipped: no Elixir changed"

      assert reason == "nothing in the Mac app changed and no Elixir changed"
    end

    test "a command that changed files don't call for is left out of the step", ctx do
      steps =
        steps([
          %{"id" => "code", "mode" => "delegated"},
          %{"id" => "build", "mode" => "machine", "command" => [%{"run" => "swift build", "when" => "macos_changed"}, %{"run" => "mix compile", "when" => "elixir_changed"}]}
        ])

      assert {:end, nil} = PhaseSteps.run_machine_steps(steps, step(steps, "build"), context(ctx, %{"mix compile" => [{:ok, {"", 0}}]}))
      assert_received {:ran, "mix compile", _env, _timeout}
      refute_received {:ran, "swift build", _env, _timeout}
    end

    test "one with no result runs again, and with none twice pauses the ticket on a Question in the Inbox with the output and the ways forward", ctx do
      steps = steps()
      hang = {:timeout, "running test/slow_test.exs\nstill waiting on `Port.open`\n"}

      assert {:paused, %Step{id: "tests"}, question_id} =
               PhaseSteps.run_machine_steps(steps, step(steps, "tests"), context(ctx, %{"make test" => [hang]}))

      assert_received {:ran, "make test", _env, _timeout}
      assert_received {:ran, "make test", _env, _timeout}
      refute_received {:ran, "make test", _env, _timeout}

      assert [first, second] = events("step.completed")
      assert %{outcome: "failed", returns_to: "tests", returns_to_title: "Tests"} = first.payload
      assert %{outcome: "paused", question_id: ^question_id} = second.payload
      assert [_artifact] = second.artifacts

      assert [%{id: ^question_id, step: "tests", asked_in: "In Progress", asked_by: %{kind: :symphony, run_id: "run-steps"}} = question] =
               Questions.open({:ticket, @repo_key, @issue_id})

      assert question.title == "TP-77: Tests gave no result 2 times"
      assert question.why =~ "running a file; still waiting on a file"
      assert question.why =~ "a file"
      assert [%{label: "Go on past it", recommended?: true}, %{label: "Run it again"}] = question.options
      assert [%{kind: :question}] = @issue_id |> RunStore.get_ticket_state() |> TicketState.pause_reasons() |> Enum.map(&Map.take(&1, [:kind]))
    end

    test "the Question meets the writing standard, and says so when the output printed nothing", ctx do
      steps = steps()
      request = PhaseSteps.question(step(steps, "tests"), context(ctx, %{}), "")

      assert DecisionRequest.check(request) == :ok
      assert request.why =~ "The last lines it printed: nothing."
      assert PhaseSteps.question(step(steps, "tests"), %{}, "x").title =~ "this ticket"
    end

    test "a Question the store refuses fails the step to its on_fail, so it never runs a third time on its own", ctx do
      steps = steps()

      log =
        capture_log(fn ->
          assert {:turn, %Step{id: "code"}, %{step: %Step{id: "tests"}}} =
                   PhaseSteps.run_machine_steps(
                     steps,
                     step(steps, "tests"),
                     context(ctx, %{"make test" => [{:timeout, ""}]}, %{repo_key: nil})
                   )
        end)

      assert log =~ "could not ask about step tests of TP-77"
      assert log =~ "could not record step.completed"
    end

    test "an output the store refuses is not kept, and a long output keeps its end, from a whole character on", ctx do
      steps = steps([%{"id" => "code", "mode" => "delegated"}, %{"id" => "lint", "title" => "Lint", "mode" => "machine", "command" => "lint"}])
      # An odd number of bytes after the two-byte characters, so both tails start inside one.
      long = String.duplicate("é", 300_000) <> "the end!"

      log =
        capture_log(fn ->
          assert {:end, %{output: output}} =
                   PhaseSteps.run_machine_steps(
                     steps,
                     step(steps, "lint"),
                     context(ctx, %{"lint" => [{:ok, {long, 1}}]}, %{artifact_opts: [max_bytes: 10]})
                   )

          assert String.valid?(output)
          assert byte_size(output) <= 512 * 1024
          assert output =~ "the end"
          assert String.length(PhaseSteps.prompt_section(step(steps, "code"), %{step: step(steps, "lint"), output: output})) < 20_000
        end)

      assert log =~ "could not keep the output of lint"
      assert [%{artifacts: []}] = events("step.completed")
    end

    test "it runs in the workspace with the agent's environment: Symphony's own secrets are removed", ctx do
      System.put_env("LINEAR_API_KEY", "secret-for-step-test")
      on_exit(fn -> System.delete_env("LINEAR_API_KEY") end)

      steps = steps([%{"id" => "code", "mode" => "delegated"}, %{"id" => "env", "mode" => "machine", "command" => "echo key=${LINEAR_API_KEY:-unset} files=$SYMPHONY_CHANGED_ELIXIR_FILES; pwd"}])
      context = context(ctx, %{}) |> Map.delete(:runner)

      assert {:end, nil} = PhaseSteps.run_machine_steps(steps, step(steps, "env"), context)
      assert [%{artifacts: [artifact_id]}] = events("step.completed")
      {:ok, path} = Artifacts.path(artifact_id)
      output = File.read!(path)
      assert output =~ "key=unset files=lib/symphony_elixir/foo.ex"
      assert output =~ Path.basename(ctx.workspace)
    end

    test "the workspace runner stops a command at its timeout", ctx do
      assert {:timeout, _output} = SymphonyElixir.Workspace.run_step_command("sleep 5", ctx.workspace, nil, %{}, 100)
    end
  end

  describe "an agent step" do
    test "Symphony records a delegated step's start and its end as its turn ends, and the turn's prompt names an orchestrated step's prompt", ctx do
      steps = steps([%{"id" => "code", "title" => "Write the code", "mode" => "delegated"}, %{"id" => "triage", "mode" => "orchestrated", "prompt" => "Sort the findings."}])
      context = context(ctx, %{})

      assert :ok = PhaseSteps.record_turn_started(step(steps, "code"), context)
      assert :ok = PhaseSteps.record_turn_passed(step(steps, "code"), context, 1_200)

      assert [%{payload: %{step_id: "code", mode: "delegated"}, actor: %{kind: :machine}}] = events("step.started")
      assert [%{payload: %{step_id: "code", outcome: "passed", duration_ms: 1_200}}] = events("step.completed")

      assert PhaseSteps.prompt_section(step(steps, "triage"), nil) =~ "Sort the findings."
      refute PhaseSteps.prompt_section(step(steps, "code"), nil) =~ "step (Build) failed"
    end

    test "a delegated step's prompt says how to end it, and a retry reminds the agent", _ctx do
      code = step(steps(), "code")
      section = PhaseSteps.prompt_section(code, nil)

      assert section =~ "End this step by recording `step.completed` for it with `ticket_record` (payload `step_id: \"code\"`"
      assert section =~ "ask them with the question tool and end the turn"
      refute section =~ "Reminder"

      assert PhaseSteps.prompt_section(code, nil, %{reminder: true}) =~
               "Reminder: the last turn ended without recording `step.completed` for the `code` step."
    end

    test "the agent's own end of a delegated step, read from the ledger for this run since the step started", ctx do
      code = step(steps(), "code")
      context = context(ctx, %{})
      since = DateTime.utc_now()

      assert PhaseSteps.agent_outcome(code, context, since) == :none

      # Symphony's records, another step's and another run's do not count.
      :ok = PhaseSteps.record_turn_passed(code, context, 10)
      record_agent!("handoff", %{outcome: "passed"})
      record_agent!("code", %{outcome: "passed"}, "run-other")
      assert PhaseSteps.agent_outcome(code, context, since) == :none

      record_agent!("code", %{outcome: "failed", returns_to: "code"})
      assert PhaseSteps.agent_outcome(code, context, since) == {:failed, "code"}

      record_agent!("code", %{outcome: "skipped", reason: "nothing to change"})
      assert PhaseSteps.agent_outcome(code, context, since) == {:skipped, "nothing to change"}

      record_agent!("code", %{outcome: "paused", question_id: "q-1"})
      assert PhaseSteps.agent_outcome(code, context, since) == {:paused, "q-1"}

      record_agent!("code", %{outcome: "passed"})
      assert PhaseSteps.agent_outcome(code, context, since) == {:passed, nil}

      # One recorded before the step started is an earlier attempt's.
      assert PhaseSteps.agent_outcome(code, context, DateTime.add(DateTime.utc_now(), 1, :second)) == :none
      assert PhaseSteps.agent_outcome(code, Map.delete(context, :run_id), since) == {:passed, nil}
    end

    test "a question a run asked since the step started is the one it pauses on", ctx do
      context = context(ctx, %{})
      since = DateTime.utc_now()
      ticket = {:ticket, @repo_key, @issue_id}

      {:ok, _symphony} = Questions.ask(ticket, request("Symphony's own"), asked_by: %{kind: :symphony, name: "Symphony"})
      {:ok, _earlier} = Questions.ask(ticket, request("An earlier one"), asked_by: %{kind: :run, name: "The run"}, at: DateTime.add(since, -60, :second))
      assert PhaseSteps.asked_question(context, since) == nil

      {:ok, asked} = Questions.ask(ticket, request("Pick a layout"), asked_by: %{kind: :run, name: "The run"})
      assert PhaseSteps.asked_question(context, since) == asked.id

      {:ok, _answered} = Questions.answer(ticket, asked.id, "1")
      assert PhaseSteps.asked_question(context, since) == nil
    end

    test "the step the next run resumes at: the last step paused on a Question that is answered now", ctx do
      steps = steps()
      context = context(ctx, %{})
      ticket = {:ticket, @repo_key, @issue_id}

      assert PhaseSteps.resume_point(steps, context) == nil

      {:ok, question} = Questions.ask(ticket, request("Pick a layout"), asked_by: %{kind: :run, name: "The run"})
      :ok = PhaseSteps.record_turn_started(step(steps, "code"), context)
      :ok = PhaseSteps.record_turn_completed(step(steps, "code"), context, %{outcome: "paused", question_id: question.id}, 5)

      # Open: nothing to resume yet.
      assert PhaseSteps.resume_point(steps, context) == nil

      {:ok, _answered} = Questions.answer(ticket, question.id, "1")
      assert {%Step{id: "code"}, %{id: id, state: :answered}} = PhaseSteps.resume_point(steps, context)
      assert id == question.id

      # A list without the step resumes nothing, and neither does a step event after the pause.
      assert PhaseSteps.resume_point(Enum.reject(steps, &(&1.id == "code")), context) == nil
      :ok = PhaseSteps.record_turn_started(step(steps, "code"), context)
      assert PhaseSteps.resume_point(steps, context) == nil
    end

    test "a machine step's answer goes on past it, runs it again, or hands the person's words on" do
      options = [%{label: "Go on past it"}, %{label: "Run it again"}]

      assert PhaseSteps.machine_resume(%{answer: %{option: 1}, options: options}) == :go_on
      assert PhaseSteps.machine_resume(%{answer: %{option: 2}, options: options}) == :again
      assert PhaseSteps.machine_resume(%{answer: %{option: nil, text: "skip the Swift tests"}, options: options}) == :words
    end

    test "a resumed step's prompt carries the question and the answer verbatim, and earlier answers", _ctx do
      code = step(steps(), "code")
      question = %{question: "Which layout: one column or two?", answer: %{text: "Two columns, as in the mock."}}
      layout = %Step{id: "layout", title: "Pick a layout", mode: "orchestrated"}

      section = PhaseSteps.prompt_section(code, nil, %{resume: question, answers: [{layout, %{"columns" => 2}}]})

      assert section =~ "Symphony paused this step on a question, and the person answered it."
      assert section =~ "Question: Which layout: one column or two?"
      assert section =~ "Answer: Two columns, as in the mock."
      assert section =~ ~s|- Earlier steps of this run answered:\n  - `layout` (Pick a layout): {"columns":2}|
    end

    test "Symphony records a step's end it saw, filling the title of the step it returns to, and a note", ctx do
      steps = steps()
      context = Map.put(context(ctx, %{}), :steps, steps)

      :ok = PhaseSteps.record_turn_completed(step(steps, "handoff"), context, %{outcome: "failed", returns_to: "code"}, 7)
      :ok = PhaseSteps.record_turn_completed(step(steps, "handoff"), Map.delete(context, :steps), %{outcome: "failed", returns_to: "handoff"}, 7)
      :ok = PhaseSteps.record_note(context, "The agent ended two turns without recording how the step ended.")

      assert [first, second] = events("step.completed")
      assert %{returns_to: "code", returns_to_title: "Write the code", duration_ms: 7} = first.payload
      assert %{returns_to_title: "handoff"} = second.payload

      assert [%{payload: %{text: "The agent ended two turns without recording how the step ended."}}] = events("note")
    end
  end

  describe "an orchestrated step's answer" do
    defp layout_step do
      [
        %{"id" => "code", "mode" => "delegated"},
        %{"id" => "layout", "title" => "Pick a layout", "mode" => "orchestrated", "prompt" => "Pick one.", "answer" => %{"layout" => "string", "columns" => "number"}}
      ]
      |> steps()
      |> step("layout")
    end

    test "its prompt names the file and the fields, and a refused answer is said on the retry", ctx do
      context = context(ctx, %{}, %{answer_dir: ctx.workspace})
      path = PhaseSteps.answer_path(layout_step(), context)
      assert path == Path.join(ctx.workspace, "symphony-step-answer-layout.json")
      assert PhaseSteps.answer_path(layout_step(), Map.delete(context, :answer_dir)) == Path.join(System.tmp_dir!(), "symphony-step-answer-layout.json")

      section = PhaseSteps.prompt_section(layout_step(), nil, %{answer_path: path})
      assert section =~ "writing your answer as one JSON object to `#{path}`, with the fields `columns` (number), `layout` (string)"
      assert section =~ "Pick one."
      assert PhaseSteps.prompt_section(layout_step(), nil) =~ "to `the answer file`"

      assert PhaseSteps.prompt_section(layout_step(), nil, %{answer_error: "the answer is not JSON"}) =~
               "Your last answer was refused: the answer is not JSON. Write it again"

      # One with no answer says nothing of a file.
      refute PhaseSteps.prompt_section(%Step{id: "triage", title: "Triage", mode: "orchestrated", prompt: "Sort.", answer: %{}}, nil) =~ "JSON"
    end

    test "is read from its file and checked against the step's answer", ctx do
      path = Path.join(ctx.workspace, "symphony-step-answer-layout.json")
      quoted = "'#{path}'"

      read = fn result ->
        context = context(ctx, %{"cat #{quoted}" => [result], "rm -f #{quoted}" => [{:ok, {"", 0}}]}, %{answer_dir: ctx.workspace})
        PhaseSteps.read_answer(layout_step(), context)
      end

      assert read.({:ok, {~s({"layout": "two columns", "columns": 2, "why": "the mock"}), 0}}) ==
               {:ok, %{"layout" => "two columns", "columns" => 2, "why" => "the mock"}}

      assert read.({:ok, {~s({"layout": 2}), 0}}) == {:error, "the answer lacks `columns` (number), `layout` (string)"}
      assert read.({:ok, {"[1, 2]", 0}}) == {:error, "the answer is not a JSON object"}
      assert read.({:ok, {"two columns", 0}}) == {:error, "the answer is not JSON"}
      assert read.({:ok, {"cat: no such file", 1}}) == {:error, "no answer was written to #{path}"}

      context = context(ctx, %{"rm -f #{quoted}" => [{:ok, {"", 0}}]}, %{answer_dir: ctx.workspace})
      assert PhaseSteps.clear_answer(layout_step(), context) == :ok
      assert_received {:ran, "rm -f " <> ^quoted, _env, _timeout}

      assert PhaseSteps.read_answer(%Step{id: "triage", mode: "orchestrated", answer: %{}}, context) == {:ok, %{}}
    end

    test "every type, and an answer over its size" do
      step = %Step{id: "x", mode: "orchestrated", answer: %{"a" => "string", "b" => "number", "c" => "boolean", "d" => "list", "e" => "object"}}

      assert {:ok, _answer} = PhaseSteps.check_answer(step, ~s({"a": "", "b": 1.5, "c": false, "d": [], "e": {}}))
      assert {:error, "the answer lacks `c` (boolean), `d` (list), `e` (object)"} = PhaseSteps.check_answer(step, ~s({"a": "", "b": 1, "c": 1, "d": {}, "e": []}))
      assert {:error, "the answer is over 64 KB"} = PhaseSteps.check_answer(step, String.duplicate(" ", 64 * 1024 + 1))
    end
  end

  defp record_agent!(step_id, fields, run_id \\ "run-steps") do
    payload = Map.merge(%{step_id: step_id, title: step_id, mode: "delegated"}, fields)
    {:ok, _event} = TicketEvents.record(@repo_key, @issue_id, "step.completed", payload, actor: {:agent, run_id, "implementation"}, run_id: run_id)
    :ok
  end

  defp request(title) do
    %{
      title: title,
      question: "#{title}: which of the two should the ticket use?",
      why: "The ticket names both. Only you can say which one it wants.",
      if_unanswered: "The ticket stays paused on this step.",
      recommendation_reason: "The first matches the mock.",
      options: [
        %{label: "The first", effect: "The run builds the first one.", recommended: true},
        %{label: "The second", effect: "The run builds the second one."}
      ]
    }
  end
end
