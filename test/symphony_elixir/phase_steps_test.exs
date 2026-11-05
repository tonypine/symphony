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
      refute PhaseSteps.prompt_section(step(steps, "code"), nil) =~ "failed"
    end
  end
end
