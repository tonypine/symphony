defmodule SymphonyElixir.PhaseStepsTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Artifacts, DecisionRequest, PhaseSteps, Questions, TicketEvents, TicketState}
  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.Config.Schema.Phases.Step
  alias SymphonyElixir.PhaseSteps.Findings

  @repo_key "default"
  @issue_id "issue-steps"
  @changed %{changed: ["lib/symphony_elixir/foo.ex"], existing: ["lib/symphony_elixir/foo.ex"], tests: ["test/symphony_elixir/foo_test.exs"]}
  @unchanged %{changed: [], existing: [], tests: []}
  @clean Map.merge(@changed, %{head: "1111111122222222", clean: true})

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

  # Runs `command` in a shell whose `mix` only writes down its arguments, one call a line.
  defp run_with_fake_mix(ctx, command, env) do
    bin = Path.join(ctx.workspace, "bin")
    log = Path.join(ctx.workspace, "mix.log")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "mix"), "#!/bin/sh\necho \"$*\" >> \"#{log}\"\n")
    File.chmod!(Path.join(bin, "mix"), 0o755)
    File.rm(log)

    assert {_output, 0} = System.cmd("sh", ["-c", command], env: Map.put(env, "PATH", bin <> ":" <> System.get_env("PATH")), cd: ctx.workspace)
    log |> File.read!() |> String.split("\n", trim: true)
  end

  defp passing, do: %{"make build" => [{:ok, {"built\n", 0}}], "make test" => [{:ok, {"", 0}}]}

  # A walk of the default list from `build` by a run of its own, as a restarted run walks it.
  defp walk_again(ctx, changes, results \\ passing()) do
    steps = steps()
    PhaseSteps.run_machine_steps(steps, step(steps, "build"), context(ctx, results, %{run_id: "run-again-#{System.unique_integer([:positive])}", changes: changes}))
  end

  # The commands the runner ran so far, in order, each with its environment.
  defp ran_commands(ran) do
    receive do
      {:ran, command, env, _timeout} -> ran_commands([{command, env} | ran])
    after
      0 -> Enum.reverse(ran)
    end
  end

  defp events(type), do: @issue_id |> TicketEvents.query(types: [type], limit: 200) |> Enum.sort_by(& &1.seq)

  defp run_record(run_id, attrs) do
    Map.merge(
      %{run_id: run_id, repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "TP-77", state: "In Progress", status: "running", session_id: "sess-gone"},
      attrs
    )
  end

  # The run `run_id`, as Symphony's start ends a run still running when it stopped.
  defp interrupted_run!(run_id, attrs \\ %{}) do
    :ok = RunStore.put_run(run_record(run_id, attrs))
    {:ok, _count} = RunStore.interrupt_running_runs(@repo_key, RunStore.restart_error())
    :ok
  end

  defp record_step!(context, type, payload) do
    {:ok, _event} = TicketEvents.record(@repo_key, @issue_id, type, payload, run_id: context.run_id)
    :ok
  end

  describe "one machine step at a time" do
    test "runs a walk's own command in this process, records the step and leaves the next step to the caller", ctx do
      [step] = steps([%{"id" => "launch", "mode" => "machine", "command" => "symphony:own_launch", "timeout_ms" => 5_000}])
      builtins = %{"symphony:own_launch" => fn %{issue_id: @issue_id} -> {:ok, {"launched 42", 0}} end}

      assert PhaseSteps.run_machine_step(step, context(ctx, %{}, %{builtins: builtins, steps: [step]})) == :passed
      refute_received {:ran, _command, _env, _timeout}
      assert [%{payload: %{step_id: "launch", outcome: "passed"}}] = events("step.completed")

      failing = %{"symphony:own_launch" => fn _context -> {:ok, {"not healthy", 1}} end}
      failing_context = context(ctx, %{}, %{builtins: failing, steps: [step]})
      assert {:failed, output} = PhaseSteps.run_machine_step(step, failing_context, 1)
      assert output =~ "not healthy"
    end

    test "an agent step's start carries what its turn runs with", ctx do
      [step] = steps([%{"id" => "look", "mode" => "orchestrated", "prompt" => "Look."}])
      :ok = PhaseSteps.record_turn_started(step, context(ctx, %{}), %{model: "claude-small", session: "fresh", prompt_ref: "phases.qa.playbooks.macos_app.steps.look"})
      assert [%{payload: %{step_id: "look", model: "claude-small", session: "fresh"}}] = events("step.started")
    end
  end

  describe "the step list" do
    test "a run walks its list only when a step of it is a machine step" do
      assert [%Step{id: "code"} | _rest] = implementation = PhaseSteps.steps(:implementation)
      assert PhaseSteps.walk?(implementation)
      assert PhaseSteps.steps(:implementation, {:error, {:missing_symphony_file, "symphony.yml", :enoent}}) == implementation
      assert PhaseSteps.steps(:implementation, {:error, :unreadable}) == []
      assert PhaseSteps.steps(:code_review) == []
      assert PhaseSteps.steps(:not_a_run_kind) == []
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
      assert {head, 0} = git.(["rev-parse", "HEAD"])
      assert changes.head == String.trim(head)
      refute changes.clean
      assert PhaseSteps.holds?("elixir_changed", changes)
      assert PhaseSteps.holds?("macos_changed", changes)
      assert PhaseSteps.holds?("always", @unchanged)

      assert PhaseSteps.step_env(changes) == %{
               "SYMPHONY_CHANGED_ELIXIR_FILES" => "lib/app/kept.ex",
               "SYMPHONY_CHANGED_TEST_FILES" => "test/app/kept_test.exs",
               "SYMPHONY_CHANGED_SWIFT_TEST_FILTER" => "DirectorAppTests"
             }

      git.(["add", "."])
      git.(["commit", "-q", "-m", "work"])
      assert %{clean: true} = PhaseSteps.changes(%{workspace: ctx.workspace, base_branch: "main"})
    end

    test "a lock-file change holds the build's condition, not the lint's and tests', and gives credo no generated file" do
      changes = %{changed: ["mix.lock"], existing: ["mix.lock", "lib/a.ex"], tests: []}

      assert PhaseSteps.holds?("elixir_changed", changes)
      refute PhaseSteps.holds?("elixir_source_changed", changes)
      assert PhaseSteps.holds?("elixir_source_changed", %{changes | changed: ["mix.exs"]})
      assert %{"SYMPHONY_CHANGED_ELIXIR_FILES" => "lib/a.ex"} = PhaseSteps.step_env(changes)
      assert %{"SYMPHONY_CHANGED_ELIXIR_FILES" => ""} = PhaseSteps.step_env(%{changes | existing: ["mix.lock"]})
    end

    test "the changes carry the workspace's workflow files as YAML reads them, and leave out one it can't", ctx do
      System.cmd("git", ["-C", ctx.workspace, "init", "-q", "-b", "main"], stderr_to_stdout: true)
      dir = Path.join(ctx.workspace, ".github/workflows")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "gate.yml"), "jobs:\n  gate:\n    needs: [lint]\n    steps:\n      - run: echo done\n")
      File.write!(Path.join(dir, "list.yaml"), "- not a workflow\n")
      File.write!(Path.join(dir, "broken.yml"), "jobs: [unclosed\n")

      changes = PhaseSteps.changes(%{workspace: ctx.workspace, base_branch: "main"})

      assert changes.workflows == [%{"jobs" => %{"gate" => %{"needs" => ["lint"], "steps" => [%{"run" => "echo done"}]}}}]
      assert Enum.sort(changes.changed) == [".github/workflows/broken.yml", ".github/workflows/gate.yml", ".github/workflows/list.yaml"]

      runner = fn _command, _env, _ms -> {:ok, {"Y\t%%%\n", 0}} end
      refute Map.has_key?(PhaseSteps.changes(%{workspace: ctx.workspace, runner: runner}), :workflows)
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

    test "the default checks give credo only the files the step names, and run no test file when none is selected", ctx do
      steps = PhaseSteps.steps(:implementation)
      [checks] = step(steps, "checks").command
      tests = Enum.find(step(steps, "tests").command, &(&1.when == "elixir_source_changed"))

      assert run_with_fake_mix(ctx, checks.run, %{"SYMPHONY_CHANGED_ELIXIR_FILES" => ""}) == ["format --check-formatted", "specs.check"]

      assert run_with_fake_mix(ctx, checks.run, %{"SYMPHONY_CHANGED_ELIXIR_FILES" => "lib/a.ex lib/b.ex"}) ==
               ["format --check-formatted", "specs.check", "credo --strict lib/a.ex lib/b.ex"]

      assert run_with_fake_mix(ctx, tests.run, %{"SYMPHONY_CHANGED_TEST_FILES" => ""}) == ["cover.changed"]
      assert run_with_fake_mix(ctx, tests.run, %{"SYMPHONY_CHANGED_TEST_FILES" => "test/a_test.exs"}) == ["test test/a_test.exs", "cover.changed"]
    end

    test "a change the default list selects nothing for skips its lint and tests with a plain reason, and a lock change only compiles", ctx do
      steps = PhaseSteps.steps(:implementation)
      ok = {:ok, {"", 0}}
      results = for step <- steps, step.mode == "machine", command <- step.command, into: %{}, do: {command.run, [ok]}

      walk = fn changed ->
        RunStore.clear()
        changes = %{changed: changed, existing: changed, tests: ["test/a_test.exs"]}
        context = context(ctx, results, %{run_id: "run-#{System.unique_integer([:positive])}", changes: changes})
        assert {:turn, %Step{id: "handoff"}, nil} = PhaseSteps.run_machine_steps(steps, step(steps, "build"), context)
        ran = ran_commands([])
        ends = for %{payload: payload} <- events("step.completed"), into: %{}, do: {payload.step_id, {payload.outcome, Map.get(payload, :reason)}}
        {Enum.map(ran, &elem(&1, 0)), ends, Enum.map(ran, &elem(&1, 1))}
      end

      nothing = "no Elixir source or test file changed"

      assert {["mix compile --warnings-as-errors"], ends, _env} = walk.(["mix.lock"])
      assert %{"build" => {"passed", nil}, "checks" => {"skipped", ^nothing}, "tests" => {"skipped", reason}} = ends
      assert reason == nothing <> " and nothing in the Mac app changed"

      for changed <- [["README.md"], [".github/workflows/ci.yml"]] do
        assert {[], %{"build" => {"skipped", _}, "checks" => {"skipped", ^nothing}, "tests" => {"skipped", _}}, _env} = walk.(changed)
      end

      [checks] = step(steps, "checks").command
      tests = Enum.find(step(steps, "tests").command, &(&1.when == "elixir_source_changed"))

      assert {[_compile, checks_run, tests_run], _ends, [_, _, env]} = walk.(["lib/a.ex"])
      assert {checks_run, tests_run} == {checks.run, tests.run}
      assert %{"SYMPHONY_CHANGED_TEST_FILES" => "test/a_test.exs"} = env

      assert {[_compile, _checks, _tests], _ends, [_, _, %{"SYMPHONY_CHANGED_TEST_FILES" => "test/b_test.exs"}]} = walk.(["test/b_test.exs"])
      assert {[_compile, _checks, _tests], _ends, [_, _, %{"SYMPHONY_CHANGED_TEST_FILES" => ""}]} = walk.(["lib/no_test.ex"])
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

  describe "the plan's checks step (symphony:checks)" do
    @guard [
      %{"id" => "code", "title" => "Write the code", "mode" => "delegated"},
      %{"id" => "plan_checks", "title" => "The plan's checks", "mode" => "machine", "command" => "symphony:checks", "on_fail" => "code", "timeout_ms" => 60_000},
      %{"id" => "handoff", "title" => "Hand off", "mode" => "delegated"}
    ]

    @guarded_plan %{
      reason: "Grooming",
      by: "grooming",
      shape: "single",
      layers: ["engine"],
      summary: "The guard holds the handoff.",
      text: "Refuse the handoff while a check is open.",
      checks: [
        %{id: "c1", kind: "outcome", statement: "The guard fails.", proof: "test"},
        %{id: "c2", kind: "qa", statement: "The page shows it.", proof: "qa", action: "Open it", expect: "It shows"},
        %{id: "c3", kind: "evidence", statement: "The design is attached.", proof: "attached"}
      ],
      size: %{tokens: 100_000, runs: 1}
    }

    defp run_guard(ctx) do
      steps = steps(@guard)
      PhaseSteps.run_machine_steps(steps, step(steps, "plan_checks"), context(ctx, %{}))
    end

    test "passes at once for a ticket with no plan, without a shell or giving up the slot", ctx do
      steps = steps(@guard)
      assert PhaseSteps.checks_command() == "symphony:checks"

      assert {:turn, %Step{id: "handoff"}, nil} = run_guard(ctx)

      refute_received {:ran, _command, _env, _timeout}
      refute_received {:notice, _notice}
      refute PhaseSteps.runs_anything?(steps, step(steps, "plan_checks"), @changed)
      assert [%{payload: %{step_id: "plan_checks", outcome: "passed"}}] = TicketEvents.query(@issue_id, types: ["step.completed"])
    end

    test "fails back to the code step, naming the open checks a test or an attachment proves", ctx do
      {:ok, _plan} = SymphonyElixir.TicketPlan.write(@repo_key, @issue_id, @guarded_plan)

      assert {:turn, %Step{id: "code"}, %{step: %Step{id: "plan_checks"}, output: output}} = run_guard(ctx)

      assert output =~ "The plan has 2 open check(s) that a test or an attachment proves, so the ticket is not handed off yet:"
      assert output =~ "- [c1] The guard fails. (proof: test)"
      assert output =~ "- [c3] The design is attached. (proof: attached)"
      refute output =~ "[c2]"
      assert output =~ "is waived by the Conductor after coding"
      refute_received {:ran, _command, _env, _timeout}

      # The failure is a failed machine step of the run, which is what wakes the Conductor's watch
      # (`step_failed`, and `step_failed_twice` when the run meets it again).
      assert [%{run_id: "run-steps", payload: %{step_id: "plan_checks", outcome: "failed", returns_to: "code"}} = failed] = events("step.completed")
      watch = %SymphonyElixir.Config.Schema.Conductor.Watch{}
      run = %{run_id: "run-steps", total_tokens: 0}
      assert {"step_failed", seen} = SymphonyElixir.Conductor.Watch.trigger([failed], run, watch, MapSet.new())
      assert {:turn, %Step{id: "code"}, _again} = run_guard(ctx)
      assert {"step_failed_twice", _seen} = SymphonyElixir.Conductor.Watch.trigger(events("step.completed"), run, watch, seen)
    end

    test "the second run in a row that meets open checks pauses on a question to the person", ctx do
      {:ok, _plan} = SymphonyElixir.TicketPlan.write(@repo_key, @issue_id, @guarded_plan)
      steps = steps(@guard)

      for run_id <- ["run-a", "run-b"] do
        {:ok, _started} = TicketEvents.record(@repo_key, @issue_id, "run.started", %{run_id: run_id, run_kind: "implementation"}, run_id: run_id)
      end

      first = context(ctx, %{}, %{run_id: "run-a"})
      assert {:turn, %Step{id: "code"}, _failed} = PhaseSteps.run_machine_steps(steps, step(steps, "plan_checks"), first)

      assert {:paused, %Step{id: "plan_checks"}, question_id} =
               PhaseSteps.run_machine_steps(steps, step(steps, "plan_checks"), context(ctx, %{}, %{run_id: "run-b"}))

      assert [%{id: ^question_id, title: "TP-77: checks of its plan are still not proved", options: options}] = Questions.open({:ticket, @repo_key, @issue_id})
      assert [%{label: "Send it back for the checks"}, %{label: "Waive them and pass it on", move: move}, _cancel] = options
      assert %{to: "Code Review", waive: [%{check_id: "c1"}, %{check_id: "c3"}]} = move
    end

    test "passes once each of them is proved or waived, whatever QA still owes", ctx do
      {:ok, _plan} = SymphonyElixir.TicketPlan.write(@repo_key, @issue_id, @guarded_plan)
      proof = %{check_id: "c1", by: "test", test: "test/guard_test.exs"}
      {:ok, _proved} = SymphonyElixir.TicketChecks.prove(@repo_key, @issue_id, proof, actor: {:agent, "run-steps", "implementation"})
      {:ok, _waived} = SymphonyElixir.TicketChecks.waive(@repo_key, @issue_id, "c3", "Nothing can be attached.")

      assert {:turn, %Step{id: "handoff"}, nil} = run_guard(ctx)
    end

    test "a check marked after the merge never fails it: the step passes once the other checks are proved", ctx do
      merged = %{id: "c4", kind: "outcome", statement: "The release run on main is green.", proof: "test", after_merge: true}
      {:ok, _plan} = SymphonyElixir.TicketPlan.write(@repo_key, @issue_id, %{@guarded_plan | checks: @guarded_plan.checks ++ [merged]})

      assert {:turn, %Step{id: "code"}, %{output: output}} = run_guard(ctx)
      refute output =~ "[c4]"

      proof = %{check_id: "c1", by: "test", test: "test/guard_test.exs"}
      {:ok, _proved} = SymphonyElixir.TicketChecks.prove(@repo_key, @issue_id, proof, actor: {:agent, "run-steps", "implementation"})
      attached = %{check_id: "c3", by: "attached", evidence: "evt-1"}
      {:ok, _proved} = SymphonyElixir.TicketChecks.prove(@repo_key, @issue_id, attached, actor: {:agent, "run-steps", "implementation"})

      assert {:turn, %Step{id: "handoff"}, nil} = run_guard(ctx)
      assert [%{id: "c4", state: :open}] = Enum.filter(SymphonyElixir.TicketChecks.open(@issue_id), &SymphonyElixir.TicketChecks.after_merge?/1)
    end
  end

  describe "the findings step of a rework" do
    defp fail_qa!(run_id, class, description, extra \\ %{}, opts \\ []) do
      payload = Map.merge(%{class: class, severity: "major", description: description}, extra)
      {:ok, event} = TicketEvents.record(@repo_key, @issue_id, "finding.recorded", payload, [actor: {:agent, run_id, "qa"}, run_id: run_id] ++ opts)
      event
    end

    defp resolve!(finding) do
      payload = %{finding_id: finding.id, how: "Fixed it", head: "abc1234"}
      {:ok, event} = TicketEvents.record(@repo_key, @issue_id, "finding.resolved", payload, actor: {:agent, "rework-1", "rework"}, run_id: "rework-1")
      event
    end

    defp run_findings(ctx) do
      steps = Phases.default_steps(:rework)
      PhaseSteps.run_machine_steps(steps, step(steps, "findings"), context(ctx, %{}))
    end

    defp read_findings do
      answered = Questions.answered({:ticket, @repo_key, @issue_id})
      @issue_id |> RunStore.list_ticket_events([]) |> Findings.read(answered)
    end

    test "with nothing repeated it passes on to the code step without a shell or giving up the slot", ctx do
      fail_qa!("qa-1", "clipped", "The table is clipped")
      steps = Phases.default_steps(:rework)

      assert {:turn, %Step{id: "code"}, nil} = run_findings(ctx)

      refute_received {:ran, _command, _env, _timeout}
      refute_received {:notice, _notice}
      refute PhaseSteps.runs_anything?(steps, step(steps, "findings"), @changed)
      assert PhaseSteps.runs_anything?(steps, step(steps, "build"), @changed)

      assert [%{payload: %{step_id: "findings", outcome: "passed"}, artifacts: [_output]}] = events("step.completed")
    end

    test "it writes the open findings by class, each with where it stands", _ctx do
      assert read_findings().output == "No open findings.\n"

      clipped = fail_qa!("qa-1", "clipped", "The table is clipped", %{viewport: "1440×900", step: "3"})
      fail_qa!("qa-1", "clipped", "The header is clipped")
      fail_qa!("qa-1", "state missing", "No empty state")
      resolve!(clipped)

      assert read_findings().output ==
               """
               Open findings by class (3):

               clipped (2):
               - resolved, awaiting QA, at 1440×900, step 3: The table is clipped
               - open: The header is clipped

               state missing (1):
               - open: No empty state
               """
    end

    test "the same class failed in two QA runs pauses on a Question with both findings, before any code", ctx do
      fail_qa!("qa-1", "clipped", "The table is clipped at the right edge.")
      fail_qa!("qa-2", "clipped", "The header is clipped at `lib/app.ex`")

      assert {:paused, %Step{id: "findings"}, question_id} = run_findings(ctx)

      refute_received {:ran, _command, _env, _timeout}
      assert [%{payload: %{outcome: "paused", question_id: ^question_id}, artifacts: [_output]}] = events("step.completed")

      assert [%{id: ^question_id, step: "findings", asked_by: %{kind: :symphony}} = question] = Questions.open({:ticket, @repo_key, @issue_id})
      assert question.title == "TP-77: QA failed twice on clipped"
      assert question.why =~ "QA found this first: The table is clipped at the right edge. Then it found this: The header is clipped at a file."
      assert [%{label: "Try another approach", recommended?: true}, %{label: "Keep this approach"}] = question.options
      assert [%{kind: :question}] = @issue_id |> RunStore.get_ticket_state() |> TicketState.pause_reasons() |> Enum.map(&Map.take(&1, [:kind]))
    end

    test "the Question meets the writing standard, and says every class that came back" do
      fail_qa!("qa-1", "clipped", "One")
      fail_qa!("qa-2", "clipped", "Two")
      fail_qa!("qa-1", "truncated", "Three")
      fail_qa!("qa-3", "truncated", "Four")

      assert %{repeats: [_clipped, _truncated] = repeats} = read_findings()
      request = Findings.question("TP-77", repeats)

      assert DecisionRequest.check(request) == :ok
      assert request.title == "TP-77: QA failed twice on clipped and truncated"
    end

    test "it only lists the last two failures of a class" do
      fail_qa!("qa-1", "clipped", "One")
      fail_qa!("qa-2", "clipped", "Two")
      fail_qa!("qa-3", "clipped", "Three")

      assert %{repeats: [%{label: "clipped", first: first, last: last}]} = read_findings()
      assert %{payload: %{description: "Two"}} = first
      assert %{payload: %{description: "Three"}} = last
    end

    test "two findings of one QA run, and two classes, are not the same failure twice" do
      fail_qa!("qa-1", "clipped", "One")
      fail_qa!("qa-1", "clipped", "Two")
      fail_qa!("qa-2", "truncated", "Three")

      assert read_findings().repeats == []
    end

    test "an unclassified finding repeats only on the same step and viewport" do
      fail_qa!("qa-1", "unclassified", "No step named")
      fail_qa!("qa-2", "unclassified", "No step named either")
      fail_qa!("qa-1", "unclassified", "One step", %{step: "3", viewport: "1440×900"})
      fail_qa!("qa-2", "unclassified", "Same step elsewhere", %{step: "3", viewport: "2560×1440"})
      assert read_findings().repeats == []

      fail_qa!("qa-3", "unclassified", "Same step again", %{step: " 3 ", viewport: "1440×900"})

      assert %{repeats: [repeat]} = read_findings()
      assert repeat.label == "step 3 at 1440×900"
      assert Findings.question("TP-77", [repeat]).title == "TP-77: QA failed twice on step 3 at 1440×900"
    end

    test "two unclassified failures that came back say which step each is" do
      fail_qa!("qa-1", "unclassified", "One", %{step: "3"})
      fail_qa!("qa-2", "unclassified", "Two", %{step: "3"})
      fail_qa!("qa-1", "unclassified", "Three", %{step: "5", viewport: "1440×900"})
      fail_qa!("qa-2", "unclassified", "Four", %{step: "5", viewport: "1440×900"})

      assert %{repeats: [_step_three, _step_five] = repeats} = read_findings()
      request = Findings.question("TP-77", repeats)

      assert DecisionRequest.check(request) == :ok
      assert request.title == "TP-77: QA failed twice on step 3 and step 5 at 1440×900"
      assert request.question =~ "twice on step 3 and step 5 at 1440×900."
      assert request.why =~ "On step 3, QA found this first: One. Then it found this: Two."
      assert request.why =~ "On step 5 at 1440×900, QA found this first: Three. Then it found this: Four."
    end

    test "two steps whose names read the same in plain words are said once" do
      fail_qa!("qa-1", "unclassified", "One", %{step: "lib/a.ex"})
      fail_qa!("qa-2", "unclassified", "Two", %{step: "lib/a.ex"})
      fail_qa!("qa-1", "unclassified", "Three", %{step: "lib/b.ex"})
      fail_qa!("qa-2", "unclassified", "Four", %{step: "lib/b.ex"})

      assert %{repeats: [_first, _second] = repeats} = read_findings()
      assert Findings.question("TP-77", repeats).title == "TP-77: QA failed twice on step a file"
    end

    test "a ledger it can't read fails the step and says so, rather than reporting no findings", ctx do
      steps = Phases.default_steps(:rework)
      context = context(ctx, %{}, %{issue_id: :not_a_ticket})

      log =
        capture_log(fn ->
          assert {:turn, %Step{id: "code"}, %{step: %Step{id: "findings"}, output: output}} =
                   PhaseSteps.run_machine_steps(steps, step(steps, "findings"), context)

          assert output =~ "(could not run: :invalid_issue_id)"
          refute output =~ "No open findings"
        end)

      assert log =~ "could not record step.completed"
      assert Questions.open({:ticket, @repo_key, @issue_id}) == []
    end

    test "a finding QA reopened counts as failing again", _ctx do
      finding = fail_qa!("qa-1", "unclassified", "The table is clipped", %{step: "3"})
      resolution = resolve!(finding)
      fail_qa!("qa-2", "unclassified", "The table is still clipped", %{step: "3"}, supersedes: resolution.id)

      assert %{repeats: [%{first: %{id: first}, last: %{payload: %{description: "The table is still clipped"}}}]} = read_findings()
      assert first == finding.id
      assert read_findings().output =~ "- reopened, step 3: The table is clipped"
    end

    test "a repeat whose last finding is fixed asks nothing", _ctx do
      fail_qa!("qa-1", "clipped", "One")
      last = fail_qa!("qa-2", "clipped", "Two")
      resolve!(last)

      assert read_findings().repeats == []
    end

    test "an answered Question is not asked again, until QA fails the class once more", ctx do
      ticket = {:ticket, @repo_key, @issue_id}
      fail_qa!("qa-1", "clipped", "One")
      fail_qa!("qa-2", "clipped", "Two")

      assert {:paused, _step, question_id} = run_findings(ctx)
      {:ok, _answered} = Questions.answer(ticket, question_id, "1")

      assert {:turn, %Step{id: "code"}, nil} = run_findings(ctx)

      fail_qa!("qa-3", "clipped", "Three")
      assert {:paused, _step, next_question} = run_findings(ctx)
      assert next_question != question_id
    end

    test "every answer goes to the agent step: an option or the person's own words" do
      options = [%{label: "Try another approach"}, %{label: "Keep this approach"}]

      assert PhaseSteps.machine_resume(%{answer: %{option: 1}, options: options}) == :words
      assert PhaseSteps.machine_resume(%{answer: %{option: 2}, options: options}) == :words
      assert PhaseSteps.machine_resume(%{answer: %{option: nil, text: "Use tabs"}, options: options}) == :words
    end
  end

  describe "a machine step that passed before" do
    test "is not run again on the same clean head: it is skipped naming the pass and the walk goes on", ctx do
      assert {:turn, %Step{id: "handoff"}, nil} = walk_again(ctx, @clean)
      assert [%{head_sha: "1111111122222222"}, %{head_sha: "1111111122222222"}] = events("step.completed")
      assert_received {:ran, "make build", _env, _timeout}
      assert_received {:ran, "make test", _env, _timeout}

      assert {:turn, %Step{id: "handoff"}, nil} = walk_again(ctx, @clean)
      refute_received {:ran, _command, _env, _timeout}

      assert [_build, _tests, %{payload: build}, %{payload: tests}] = events("step.completed")
      assert %{step_id: "build", outcome: "skipped", reason: "passed on 11111111 at " <> _} = build
      assert build.reason =~ "UTC, with nothing changed since"
      assert %{step_id: "tests", outcome: "skipped"} = tests

      # A skip ran nothing, so the pass before it still stands for a third run.
      assert {:turn, %Step{id: "handoff"}, nil} = walk_again(ctx, @clean)
      refute_received {:ran, _command, _env, _timeout}
    end

    test "runs again on another head, with uncommitted changes, after a failure on that head, or with other commands", ctx do
      assert {:turn, _handoff, nil} = walk_again(ctx, @clean)
      assert_received {:ran, "make build", _env, _timeout}

      assert {:turn, _handoff, nil} = walk_again(ctx, %{@clean | head: "3333333344444444"})
      assert_received {:ran, "make build", _env, _timeout}

      # A pass from a dirty workspace carries no head, so nothing reuses it.
      assert {:turn, _handoff, nil} = walk_again(ctx, %{@clean | clean: false})
      assert_received {:ran, "make build", _env, _timeout}
      assert %{head_sha: nil} = "step.completed" |> events() |> Enum.filter(&(&1.payload.step_id == "build")) |> List.last()

      assert {:turn, %Step{id: "code"}, _carry} = walk_again(ctx, @clean, %{"make build" => [{:ok, {"boom\n", 1}}]})
      assert_received {:ran, "make build", _env, _timeout}
      assert {:turn, _handoff, nil} = walk_again(ctx, @clean)
      assert_received {:ran, "make build", _env, _timeout}

      other = steps([%{"id" => "code", "mode" => "delegated"}, %{"id" => "build", "title" => "Build", "mode" => "machine", "command" => "make all", "on_fail" => "code"}])
      context = context(ctx, %{"make all" => [{:ok, {"", 0}}]}, %{run_id: "run-other", changes: @clean})
      assert {:end, nil} = PhaseSteps.run_machine_steps(other, step(other, "build"), context)
      assert_received {:ran, "make all", _env, _timeout}
    end

    test "Symphony's own commands always run: they read the ticket, not the head", ctx do
      [step] = steps([%{"id" => "launch", "mode" => "machine", "command" => "symphony:own_launch", "timeout_ms" => 5_000}])
      parent = self()

      builtins = %{
        "symphony:own_launch" => fn _context ->
          send(parent, :launched)
          {:ok, {"launched", 0}}
        end
      }

      context = context(ctx, %{}, %{builtins: builtins, steps: [step], changes: @clean})

      assert PhaseSteps.run_machine_step(step, context) == :passed
      assert PhaseSteps.run_machine_step(step, %{context | run_id: "run-later"}) == :passed
      assert_received :launched
      assert_received :launched
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
      assert payload.reason == "`make build` exited 2: error: undefined function foo/0"
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
      assert [%{payload: %{outcome: "failed", returns_to: "end", returns_to_title: "the end of the run"} = payload}] = events("step.completed")
      assert payload.reason == "`lint` could not run: :enoent"
    end

    test "a failed step's reason names the command that ended it, how it ended and the last line it printed" do
      assert PhaseSteps.failure_reason("$ make a\nok\n$ make test\n\e[31m4 failures\e[0m\n\n(exit status 2)\n") == "`make test` exited 2: 4 failures"
      assert PhaseSteps.failure_reason("$ make test\nslow\n(stopped: no result before the step's timeout)\n") == "`make test` stopped: no result before the step's timeout: slow"
      assert PhaseSteps.failure_reason("$ make test\n(exit status 1)\n") == "`make test` exited 1"
      assert PhaseSteps.failure_reason("$ make test\nboom\n") == "`make test`: boom"
      assert PhaseSteps.failure_reason("qa_build_failed: no app\n") == "qa_build_failed: no app"
      assert PhaseSteps.failure_reason("(exit status 3)\n") == "exited 3"
      assert PhaseSteps.failure_reason("") == "none"
      assert String.length(PhaseSteps.failure_reason("$ " <> String.duplicate("x", 200) <> "\n" <> String.duplicate("y", 400))) == 300
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
      assert first.payload.reason == "`make test` stopped: no result before the step's timeout: still waiting on `Port.open`"
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

    # c7 (TP-1590): a run Symphony's restart interrupted goes on from where it stopped, and no step that ended runs again.
    test "after a restart mid-run, the next run goes on at the step that run stopped at", ctx do
      steps = steps()
      gone = context(ctx, %{}, %{run_id: "run-gone"})
      assert PhaseSteps.restart_point(steps, gone) == nil
      {:ok, _note} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "Not a step."})
      assert PhaseSteps.restart_point(steps, gone) == nil

      # Stopped mid-turn: the same step, in the interrupted turn's session.
      :ok = PhaseSteps.record_turn_started(step(steps, "code"), gone)
      assert PhaseSteps.restart_point(steps, gone) == nil, "the run is not known to be interrupted yet"
      interrupted_run!("run-gone")
      assert %{step: %Step{id: "code"}, carry: nil, session_id: "sess-gone", mid_step: true} = PhaseSteps.restart_point(steps, gone)

      # Between steps (the code passed, the run waited for the pause to lift): the next step, no session.
      :ok = PhaseSteps.record_turn_passed(step(steps, "code"), gone, 5)
      assert %{step: %Step{id: "build"}, carry: nil, session_id: nil, mid_step: false} = PhaseSteps.restart_point(steps, gone)

      # A machine step stopped mid-run runs again.
      record_step!(gone, "step.started", %{step_id: "tests", title: "Tests", mode: "machine"})
      assert %{step: %Step{id: "tests"}, session_id: nil, mid_step: true} = PhaseSteps.restart_point(steps, gone)

      record_step!(gone, "step.completed", %{step_id: "tests", title: "Tests", mode: "machine", outcome: "skipped", reason: "nothing changed"})
      assert %{step: %Step{id: "handoff"}} = PhaseSteps.restart_point(steps, gone)

      # Past the last step there is nothing to go on with, and a paused step is the answer's to resume.
      :ok = PhaseSteps.record_turn_passed(step(steps, "handoff"), gone, 5)
      assert PhaseSteps.restart_point(steps, gone) == nil
      :ok = PhaseSteps.record_turn_completed(step(steps, "handoff"), gone, %{outcome: "paused", question_id: "q-1"}, 5)
      assert PhaseSteps.restart_point(steps, gone) == nil
    end

    test "after a restart, a failed machine step's run goes on at the step it fails to, with its kept output", ctx do
      steps = steps()
      gone = context(ctx, %{"make build" => [{:ok, {"error: boom\n", 1}}]}, %{run_id: "run-gone"})
      interrupted_run!("run-gone")

      assert {:turn, %Step{id: "code"}, _carry} = PhaseSteps.run_machine_steps(steps, step(steps, "build"), gone)
      assert %{step: %Step{id: "code"}, carry: %{step: %Step{id: "build"}, output: output}, mid_step: false} = PhaseSteps.restart_point(steps, gone)
      assert output =~ "error: boom"

      # An output that is gone carries nothing, and a failed agent step goes on at the step it returns to.
      record_step!(gone, "step.completed", %{step_id: "tests", title: "Tests", mode: "machine", outcome: "failed", returns_to: "code"})
      assert %{step: %Step{id: "code"}, carry: %{step: %Step{id: "tests"}, output: ""}} = PhaseSteps.restart_point(steps, gone)
      :ok = PhaseSteps.record_turn_completed(step(steps, "handoff"), gone, %{outcome: "failed", returns_to: "code"}, 5)
      assert %{step: %Step{id: "code"}, carry: nil, session_id: nil} = PhaseSteps.restart_point(steps, gone)
      :ok = PhaseSteps.record_turn_completed(step(steps, "handoff"), gone, %{outcome: "failed", returns_to: "gone"}, 5)
      assert PhaseSteps.restart_point(steps, gone) == nil, "a step the list lacks"
    end

    test "after a restart, nothing is resumed from a run it didn't interrupt, another phase or before a move", ctx do
      steps = steps()
      gone = context(ctx, %{}, %{run_id: "run-gone"})
      :ok = PhaseSteps.record_turn_started(step(steps, "code"), gone)

      # A run that failed on its own starts over.
      :ok = RunStore.put_run(run_record("run-gone", %{status: "failure", error: "agent exited"}))
      assert PhaseSteps.restart_point(steps, gone) == nil

      # One the restart interrupted in another phase.
      interrupted_run!("run-gone", %{state: "Rework"})
      assert PhaseSteps.restart_point(steps, gone) == nil

      interrupted_run!("run-gone")
      assert %{step: %Step{id: "code"}} = PhaseSteps.restart_point(steps, gone)
      # A list without the step goes on nowhere.
      assert PhaseSteps.restart_point(Enum.reject(steps, &(&1.id == "code")), gone) == nil

      # A move of the ticket since the step: the new phase's run starts from its first step.
      {:ok, _moved} = TicketEvents.record(@repo_key, @issue_id, "phase.entered", %{to: "In Progress", from: "Rework"})
      assert PhaseSteps.restart_point(steps, gone) == nil
    end

    test "a restarted turn's prompt says the run goes on after Symphony's restart" do
      [code | _rest] = steps()
      assert PhaseSteps.prompt_section(code, nil, %{restarted: :mid_step}) =~ "while this step's turn was under way"
      assert PhaseSteps.prompt_section(code, nil, %{restarted: :between_steps}) =~ "between this run's steps"
      refute PhaseSteps.prompt_section(code, nil) =~ "Symphony restarted"
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

    test "Symphony records a step's end it saw, filling the title of the step it returns to", ctx do
      steps = steps()
      context = Map.put(context(ctx, %{}), :steps, steps)

      :ok = PhaseSteps.record_turn_completed(step(steps, "handoff"), context, %{outcome: "failed", returns_to: "code"}, 7)
      :ok = PhaseSteps.record_turn_completed(step(steps, "handoff"), Map.delete(context, :steps), %{outcome: "failed", returns_to: "handoff"}, 7)

      assert [first, second] = events("step.completed")
      assert %{returns_to: "code", returns_to_title: "Write the code", duration_ms: 7} = first.payload
      assert %{returns_to_title: "handoff"} = second.payload
      assert events("note") == []
    end
  end

  describe "an agent step's transcript" do
    @lines [%{kind: "say", text: "Reading the module."}, %{kind: "tool", text: "Bash: cat lib/app.ex"}, %{kind: "result", text: "ok", duration_ms: 4}]

    defp transcript_of(artifact_id) do
      assert {:ok, %{kind: "transcript", label: "Write the code transcript"}} = Artifacts.get(artifact_id)
      {:ok, path} = Artifacts.path(artifact_id)
      path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1, keys: :atoms))
    end

    test "Symphony's record of a step's end carries the step's lines, and a turn that said nothing carries none", ctx do
      code = step(steps(), "code")
      :ok = PhaseSteps.record_turn_passed(code, context(ctx, %{}, %{transcript_lines: @lines}), 10)
      :ok = PhaseSteps.record_turn_passed(code, context(ctx, %{}, %{transcript_lines: []}), 10)

      assert [%{artifacts: [artifact_id]}, %{artifacts: []}] = events("step.completed")
      assert transcript_of(artifact_id) == @lines
    end

    test "the end the agent recorded mid-turn gets the lines once the turn is over", ctx do
      code = step(steps(), "code")
      since = DateTime.utc_now()
      context = context(ctx, %{}, %{transcript_lines: @lines})

      # No end recorded yet, or no lines: the ledger stays as it is.
      assert :ok = PhaseSteps.keep_agent_transcript(code, context, since)
      record_agent!("code", %{outcome: "passed"})
      assert :ok = PhaseSteps.keep_agent_transcript(code, Map.put(context, :transcript_lines, []), since)
      assert [%{artifacts: []}] = events("step.completed")

      assert :ok = PhaseSteps.keep_agent_transcript(code, context, since)
      assert [%{payload: %{step_id: "code", outcome: "passed"}, artifacts: [artifact_id]}] = events("step.completed")
      assert transcript_of(artifact_id) == @lines
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
