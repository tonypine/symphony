defmodule SymphonyElixir.PhaseSteps.FailedCheckTest do
  # The failed-check step of a CI Fix run (TP-1555): what it plans to run again for each check that
  # failed on GitHub, read from the check's own result, and a walk of the CI Fix default list from
  # that step through the step runner, with GitHub's read and the workspace's shell faked.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.{PhaseSteps, Questions, TicketEvents}
  alias SymphonyElixir.PhaseSteps.{FailedCheck, WindowTests}

  @repo_key "default"
  @issue_id "issue-failed-check"
  @pr_url "https://github.com/acme/app/pull/42"
  @head "0123456789abcdef0123456789abcdef01234567"

  @manifest %{
    "tests" => [
      %{"script" => "macos/Tests/qa-scroll-test.py", "title" => "scrolling test", "run" => "python3 -I Tests/qa-scroll-test.py", "covers" => ["priv/qa_driver/**"]},
      %{
        "script" => "macos/Tests/qa-key-test.py",
        "title" => "key test",
        "run" => "python3 -I Tests/qa-key-test.py",
        "covers" => ["priv/qa_driver/**"],
        "off" => "it fails on main there"
      }
    ]
  }

  # A workflow file as YAML reads it, shaped as the repository's make-all: a summary job that
  # waits on the others and runs only shell lines, and jobs that check the repository out.
  @workflow %{
    "name" => "make-all",
    "jobs" => %{
      "lint" => %{"name" => "lint", "steps" => [%{"uses" => "actions/checkout@v5"}, %{"name" => "Run lint", "run" => "mix lint"}]},
      "coverage" => %{"name" => "coverage (${{ matrix.partition }}/4)", "steps" => [%{"uses" => "actions/checkout@v5"}, %{"run" => "mix test"}]},
      "coverage-report" => %{"name" => "coverage report", "needs" => "coverage", "steps" => [%{"uses" => "actions/checkout@v5"}, %{"run" => "mix cover"}]},
      "dialyzer" => %{"steps" => [%{"uses" => "actions/checkout@v5"}, %{"run" => "mix dialyzer"}]},
      "make-all" => %{
        "name" => "make-all",
        "needs" => ["lint", "coverage-report", "dialyzer"],
        "if" => "${{ !cancelled() }}",
        "steps" => [%{"name" => "Summarize gate results", "env" => %{"LINT_RESULT" => "${{ needs.lint.result }}"}, "run" => "echo \"lint: $LINT_RESULT\""}]
      }
    }
  }

  setup do
    :ok = RunStore.clear()
    :ok
  end

  defp entries, do: @manifest |> Jason.encode!() |> WindowTests.parse() |> elem(1)

  defp changes(extra \\ %{}) do
    Map.merge(
      %{
        changed: ["lib/app/thing.ex"],
        existing: ["lib/app/thing.ex", "test/app/new_test.exs"],
        tests: ["test/app/thing_test.exs", "test/app/other_test.exs"],
        window_tests: {:ok, entries()},
        workflows: [%{"on" => "push"}, @workflow]
      },
      extra
    )
  end

  defp job(fields), do: Map.merge(%{failed_steps: [], annotations: [], log: ""}, fields)

  defp failure(checks), do: %{commit_sha: @head, failed_checks: checks, log_excerpt: "", approved: false}

  # GitHub's read of each job, by job id, as the CI log tool returns it.
  defp reads(jobs) do
    test = self()

    fn repo, {:job, job_id}, opts ->
      send(test, {:read, repo, job_id, opts})

      case Map.fetch(jobs, job_id) do
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, job} -> {:ok, %{jobs: [job]}}
        :error -> {:ok, %{jobs: []}}
      end
    end
  end

  # The workspace's shell: each command's answer, and every command it is given reported.
  defp runner(answers) do
    test = self()

    fn command, _env, _timeout_ms ->
      send(test, {:ran, command})
      Map.get(answers, command, {:ok, {"ok\n", 0}})
    end
  end

  defp context(checks, jobs, overrides \\ %{}) do
    Map.merge(
      %{
        repo_key: @repo_key,
        issue_id: @issue_id,
        identifier: "TP-88",
        phase: "CI Fix",
        run_id: "run-failed-check",
        workspace: "/tmp/workspace",
        base_branch: "main",
        changes: changes(),
        ci_failure: failure(checks),
        pr_url: @pr_url,
        runner: runner(Map.get(overrides, :answers, %{})),
        failed_check_opts: [read: reads(jobs)] ++ Map.get(overrides, :opts, [])
      },
      Map.drop(overrides, [:answers, :opts])
    )
  end

  defp walk(context) do
    steps = Phases.default_steps(:ci_fix)
    PhaseSteps.run_machine_steps(steps, Enum.find(steps, &(&1.id == "failed_check")), context)
  end

  defp completed(step_id \\ "failed_check") do
    for %{payload: %{step_id: ^step_id} = payload} = event <- events("step.completed"), do: Map.put(payload, :artifacts, event.artifacts)
  end

  defp events(type), do: @issue_id |> TicketEvents.query(types: [type], limit: 200) |> Enum.sort_by(& &1.seq)

  defp output(%{artifacts: [artifact | _]}) do
    {:ok, path} = SymphonyElixir.Artifacts.path(artifact_id(artifact))
    File.read!(path)
  end

  defp artifact_id(%{id: id}), do: id
  defp artifact_id(id) when is_binary(id), do: id

  defp test_job, do: job(%{failed_steps: ["Run coverage partition"], annotations: ["failure ExUnit failure: 1) test it works (App.ThingTest)\n test/app/thing_test.exs:12"]})

  describe "the plan" do
    test "a check's name is the job's own, without a matrix's part, and the declared checks are CI's" do
      assert FailedCheck.normalize("coverage (2/4)") == "coverage"
      assert FailedCheck.normalize("checks / Mac Checks") == "mac checks"
      # The Mac checks' jobs, one per runner and one on Linux (TP-1591), keep the check's commands.
      for job <- ["checks / mac checks (app)", "checks / mac checks (tests)", "checks / mac checks (scripts)"],
        do: assert(FailedCheck.normalize(job) == "mac checks")
      assert %{why: why} = FailedCheck.ci_only("dialyzer")
      assert why =~ "takes longer than a run's step allows"
      assert FailedCheck.ci_only("checks / mac checks", "Test update, restart and rollback")
      refute FailedCheck.ci_only("mac checks")
      refute FailedCheck.ci_only("lint")

      assert [{:ci_only, "dialyzer", ^why}] = FailedCheck.plan(%{name: "dialyzer"}, {:error, :ci_only}, changes())
    end

    test "a red test job runs its failed test files still in the workspace, from its annotations before its log" do
      log = "test/app/other_test.exs:3: warning: unused\n"
      read = {:ok, job(%{annotations: ["failure 1) test x\n test/app/thing_test.exs:12", "failure test/app/gone_test.exs:4"], log: log})}
      assert [{:tests, ["test/app/thing_test.exs"]}] = FailedCheck.plan(%{name: "coverage (1/4)"}, read, changes())

      read = {:ok, job(%{log: "  1) test y (App.NewTest)\n     test/app/new_test.exs:9\n" <> log})}
      assert [{:tests, ["test/app/new_test.exs", "test/app/other_test.exs"]}] = FailedCheck.plan(%{name: "coverage (2/4)"}, read, changes())

      read = {:ok, job(%{annotations: ["failure test/app/gone_test.exs:4"]})}
      assert [{:unknown, why}] = FailedCheck.plan(%{name: "coverage (3/4)"}, read, changes())
      assert why == "the test files coverage (3/4) failed are no longer in the workspace: test/app/gone_test.exs"
    end

    test "a red coverage report runs the coverage of the modules it names below 100%" do
      annotations = [
        "failure lib/app/thing.ex:12 Coverage App.Thing 95.00%: uncovered lines 12 of lib/app/thing.ex: below 100%",
        "warning lib/app/old.ex:3 Coverage App.Old 90.00%: uncovered lines 3 of lib/app/old.ex: main had it at 100%",
        "failure Process completed with exit code 1."
      ]

      assert [{:coverage, ["lib/app/thing.ex"]}] = FailedCheck.plan(%{name: "coverage report"}, {:ok, job(%{annotations: annotations})}, changes())
    end

    test "any other red job runs the failed steps it knows, its window tests in the QA VM, and names those it can't" do
      steps = [
        "Run tests",
        "Test update, restart and rollback",
        "Test the QA driver's scrolling",
        "Test the QA appearance library",
        "Set up mise tools"
      ]

      assert [
               {:shell, "cd macos && swift test"},
               {:ci_only, "checks / mac checks › Test update, restart and rollback", _why},
               {:window, "macos/Tests/qa-scroll-test.py"},
               {:unknown, "the window tests manifest declares no macos/Tests/qa-appearance-test.sh, which the step Test the QA appearance library of checks / mac checks runs"},
               {:unknown, "Symphony has no way to run the step Set up mise tools of checks / mac checks outside GitHub"}
             ] = FailedCheck.plan(%{name: "checks / mac checks"}, {:ok, job(%{failed_steps: steps})}, changes())

      assert [{:unknown, "the window tests manifest declares no " <> _rest}] =
               FailedCheck.plan(%{name: "mac checks"}, {:ok, job(%{failed_steps: ["Test the QA driver's scrolling"]})}, Map.delete(changes(), :window_tests))

      assert [{:unknown, "GitHub names no failed step of lint"}] = FailedCheck.plan(%{name: "lint"}, {:ok, job(%{})}, changes())
      assert [{:unknown, "Symphony could not read the result of lint on GitHub (:boom)"}] = FailedCheck.plan(%{name: "lint"}, {:error, :boom}, changes())
      assert FailedCheck.step_commands()[{"lint", "Run lint"}] == "mix lint"
    end

    test "a job that waits on others and runs only shell lines only adds them up, read from the workflow files, never from its log" do
      reported = ["lint", "coverage report", "dialyzer"]
      assert FailedCheck.summary("make-all", [@workflow]) == reported
      assert FailedCheck.summary("CI / make-all", [%{"jobs" => []}, @workflow]) == reported

      # Its log is not read: the workflow file decides, whatever GitHub answered.
      assert [{:summary, "make-all", ^reported}] = FailedCheck.plan(%{name: "make-all"}, {:error, :summary}, changes())
      assert [{:summary, "make-all", ^reported}] = FailedCheck.plan(%{name: "make-all"}, {:ok, job(%{failed_steps: ["Summarize gate results"]})}, changes())

      # A job that checks the repository out or runs an action, or waits on nothing, is not one.
      for name <- ["lint", "coverage (1/4)", "coverage report", "dialyzer", "not a job"], do: assert(FailedCheck.summary(name, [@workflow]) == nil)

      shapes = [
        %{"needs" => ["lint"], "steps" => [%{"run" => "echo", "uses" => "actions/x@v1"}]},
        %{"needs" => ["lint"], "steps" => [%{"run" => ["echo"]}]},
        %{"needs" => ["lint"], "steps" => ["echo"]},
        %{"needs" => ["lint"], "steps" => []},
        %{"needs" => ["lint"]},
        %{"needs" => [], "steps" => [%{"run" => "echo"}]},
        %{"needs" => [7], "steps" => [%{"run" => "echo"}]},
        %{"steps" => [%{"run" => "echo"}]},
        %{"needs" => ["lint"], "uses" => "./.github/workflows/gate.yml", "steps" => [%{"run" => "echo"}]}
      ]

      for job <- shapes, do: assert(FailedCheck.summary("gate", [%{"jobs" => %{"gate" => job, "skip" => "junk"}}]) == nil)

      # A job with no name is its id, and one it needs that the file does not hold is named by its id.
      assert FailedCheck.summary("gate", [%{"jobs" => %{"gate" => %{"needs" => "elsewhere", "steps" => [%{"run" => "true"}]}}}]) == ["elsewhere"]
      assert FailedCheck.summary("make-all", []) == nil
      assert FailedCheck.summary("make-all", nil) == nil

      # Without the workflow files the step behaves as before and has no way to run it.
      assert [{:unknown, "Symphony has no way to run the step Summarize gate results of make-all outside GitHub"}] =
               FailedCheck.plan(%{name: "make-all"}, {:ok, job(%{failed_steps: ["Summarize gate results"]})}, Map.delete(changes(), :workflows))
    end

    test "the checks come from the run's failure, with or without GitHub's job, in either key form" do
      assert FailedCheck.failed_checks(%{ci_failure: %{"failed_checks" => [%{"name" => "lint", "job_id" => 77}, %{"name" => nil}, "junk"]}}) ==
               [%{name: "lint", job_id: "77"}]

      assert FailedCheck.failed_checks(%{ci_failure: failure([%{name: "lint", job_id: ""}])}) == [%{name: "lint", job_id: nil}]
      assert FailedCheck.failed_checks(%{ci_failure: nil}) == []
      assert FailedCheck.failed_checks(%{}) == []

      assert FailedCheck.skip_reason(%{ci_failure: nil, pr_conflict: %{mergeable: "CONFLICTING"}}) ==
               "the run was sent for a merge conflict, and no check failed on GitHub for it"

      assert FailedCheck.skip_reason(%{ci_failure: failure([%{name: "lint"}]), pr_conflict: %{mergeable: "CONFLICTING"}}) == nil
      assert FailedCheck.skip_reason(%{ci_failure: nil, pr_conflict: nil}) == nil
      assert FailedCheck.skip_reason(%{ci_failure: nil}) == nil
    end
  end

  describe "a CI Fix run's step" do
    test "a red test job runs those test files again on the run's commit, and the run reaches the hand off only on a pass" do
      context = context([%{name: "coverage (2/4)", job_id: "101"}], %{"101" => test_job()})

      assert {:turn, %{id: "handoff"}, nil} = walk(context)

      assert_received {:read, "acme/app", "101", read_opts}
      assert read_opts == [failed_only: true, cwd: "/tmp/workspace"]
      assert_received {:ran, "mix test test/app/thing_test.exs"}
      assert [%{outcome: "passed", title: "The failed check"} = passed] = completed()
      output = output(passed)
      assert output =~ "What failed on GitHub on 01234567, run again on this run's commit:\n"
      assert output =~ "- coverage (2/4): its failed test files, test/app/thing_test.exs\n"
      assert output =~ "$ mix test test/app/thing_test.exs\nok\n"
      assert output =~ "(every failed check passed on this run's commit)"
      assert [%{outcome: "skipped", reason: "nothing a window test covers changed"}] = completed("window_tests")
    end

    test "a test that still fails returns the run to the fix step with the output, and nothing is pushed" do
      answers = %{"mix test test/app/thing_test.exs" => {:ok, {"1) test it works\nAssertion failed", 2}}}
      context = context([%{name: "coverage (2/4)", job_id: "101"}], %{"101" => test_job()}, %{answers: answers})

      assert {:turn, %{id: "fix"}, %{output: output}} = walk(context)
      assert output =~ "Assertion failed\n(exit status 2)\n"
      assert [%{outcome: "failed", returns_to: "fix", returns_to_title: "Fix the failed check"}] = completed()
      refute Enum.any?(events("step.started"), &(&1.payload.step_id in ["window_tests", "handoff"]))
    end

    test "a check on the only-CI list is not run: the step says it can only be proved by CI, with its name, and the run pushes" do
      context = context([%{name: "dialyzer", job_id: "103"}], %{})

      assert {:turn, %{id: "handoff"}, nil} = walk(context)
      refute_received {:read, _repo, _job, _opts}
      refute_received {:ran, _command}
      assert [%{outcome: "passed"} = passed] = completed()
      assert output(passed) =~ "- dialyzer: can only be proved by CI (its full run of the whole code base takes longer than a run's step allows)\n"
      assert output(passed) =~ "dialyzer can only be proved by CI, so the push goes ahead and CI proves it"
    end

    test "a check that only adds up other jobs counts as proved once the failed ones it reports on pass, and the run pushes without a question" do
      checks = [%{name: "coverage (2/4)", job_id: "101"}, %{name: "make-all", job_id: "102"}, %{name: "dialyzer", job_id: "103"}]
      context = context(checks, %{"101" => test_job(), "102" => job(%{failed_steps: ["Summarize gate results"]})})

      assert {:turn, %{id: "handoff"}, nil} = walk(context)
      assert_received {:read, "acme/app", "101", _opts}
      refute_received {:read, _repo, "102", _opts}
      assert_received {:ran, "mix test test/app/thing_test.exs"}
      assert [%{outcome: "passed"} = passed] = completed()
      output = output(passed)
      assert output =~ "- make-all: only adds up the results of lint, coverage report, dialyzer, so it is proved by them
"

      assert output =~
               "(every failed check Symphony can run passed; make-all only adds up the results of lint, coverage report, dialyzer, so it counts as proved by them; dialyzer can only be proved by CI"

      assert Questions.open({:ticket, @repo_key, @issue_id}) == []

      :ok = RunStore.clear()
      assert {:turn, %{id: "handoff"}, nil} = walk(context([%{name: "make-all", job_id: "102"}], %{}))
      assert [%{outcome: "passed"} = passed] = completed()
      assert output(passed) =~ "(every failed check passed on this run's commit; make-all only adds up the results of"
    end

    test "a check that only adds up other jobs hides none of them: one that fails again goes back to the fix, one it can't run still asks" do
      checks = [%{name: "coverage (2/4)", job_id: "101"}, %{name: "make-all", job_id: "102"}]
      answers = %{"mix test test/app/thing_test.exs" => {:ok, {"Assertion failed", 2}}}

      assert {:turn, %{id: "fix"}, %{output: output}} = walk(context(checks, %{"101" => test_job()}, %{answers: answers}))
      assert output =~ "Assertion failed
(exit status 2)
"
      assert [%{outcome: "failed", returns_to: "fix"}] = completed()

      :ok = RunStore.clear()
      checks = [%{name: "lint"}, %{name: "make-all", job_id: "102"}]
      assert {:paused, %{id: "failed_check"}, question_id} = walk(context(checks, %{}))
      assert [%{outcome: "paused"} = paused] = completed()
      assert output(paused) =~ "(could not run: Symphony could not read the result of lint on GitHub (:no_job))
"
      assert Questions.find({:ticket, @repo_key, @issue_id}, question_id).question =~ "(lint, make-all)"
    end

    test "a run sent for a merge conflict, with no failed check, skips the step" do
      assert {:turn, %{id: "handoff"}, nil} = walk(context([], %{}, %{ci_failure: nil, pr_conflict: %{mergeable: "CONFLICTING"}}))
      assert [%{outcome: "skipped", reason: "the run was sent for a merge conflict, and no check failed on GitHub for it"}] = completed()
    end

    test "a CI Fix run with neither a failed check nor a merge conflict stops on a question before the push" do
      for overrides <- [%{ci_failure: nil}, %{ci_failure: failure([])}] do
        :ok = RunStore.clear()

        assert {:paused, %{id: "failed_check"}, question_id} = walk(context([], %{}, Map.put(overrides, :pr_conflict, nil)))
        refute_received {:read, _repo, _job, _opts}
        refute_received {:ran, _command}
        assert [%{outcome: "paused", question_id: ^question_id} = paused] = completed()
        assert output(paused) =~ "(could not run: Symphony does not know which check failed on GitHub for this run)"
        refute Enum.any?(events("step.started"), &(&1.payload.step_id == "handoff"))

        question = Questions.find({:ticket, @repo_key, @issue_id}, question_id)
        assert question.question =~ "The CI Fix run of TP-88 fixed what failed on GitHub, but Symphony"
      end
    end

    test "a coverage report and failed steps run once each, in order, and a failure stops the rest" do
      checks = [%{name: "coverage report", job_id: "1"}, %{name: "lint", job_id: "2"}, %{name: "lint", job_id: "3"}, %{name: "format", job_id: "4"}]

      jobs = %{
        "1" => job(%{annotations: ["failure lib/app/thing.ex:3 Coverage App.Thing 50.00%: uncovered lines 3"]}),
        "2" => job(%{failed_steps: ["Run lint"]}),
        "3" => job(%{failed_steps: ["Run lint"]}),
        "4" => job(%{failed_steps: ["Check formatting"]})
      }

      answers = %{"mix lint" => {:error, :enoent}}
      shell = fn command, _ms -> runner(answers).(command, %{}, 1) end

      assert {:ok, {output, 1}} = FailedCheck.run(context(checks, jobs), 60_000, shell)
      assert_received {:ran, "mix cover.changed --file lib/app/thing.ex"}
      assert_received {:ran, "mix lint"}
      refute_received {:ran, "mix lint"}
      refute_received {:ran, "mix format --check-formatted"}
      assert output =~ "- coverage report: the modules below 100% coverage, in lib/app/thing.ex\n"
      assert output =~ "- format: its failed step, `mix format --check-formatted`\n"
      assert output =~ "$ mix lint\n(could not run: :enoent)\n"

      timeout = fn _command, _ms -> {:timeout, "still going"} end
      assert {:timeout, output} = FailedCheck.run(context([%{name: "format", job_id: "4"}], jobs), 60_000, timeout)
      assert output =~ "$ mix format --check-formatted\nstill going\n"
    end

    test "a check it has no way to run stops the run on a question before the push; the person may let CI prove it" do
      checks = [%{name: "seatbelt tests", job_id: "9"}, %{name: "lint"}, %{name: "audit", job_id: "8"}]
      jobs = %{"9" => job(%{failed_steps: ["Run the seatbelt tests"]}), "8" => {:error, :gh_down}}

      assert {:paused, %{id: "failed_check"}, question_id} = walk(context(checks, jobs))
      assert [%{outcome: "paused", question_id: ^question_id} = paused] = completed()
      assert output(paused) =~ "(could not run: Symphony has no way to run the step Run the seatbelt tests of seatbelt tests outside GitHub; "
      assert output(paused) =~ "Symphony could not read the result of lint on GitHub (:no_job); "
      assert output(paused) =~ "Symphony could not read the result of audit on GitHub (:gh_down))"
      refute Enum.any?(events("step.started"), &(&1.payload.step_id == "handoff"))

      question = Questions.find({:ticket, @repo_key, @issue_id}, question_id)
      assert question.title == "TP-88: a failed check cannot be run again before the push"
      assert question.question =~ "(seatbelt tests, lint, audit)"
      assert question.why =~ "Only the checks Settings › Phases lists as proved by CI alone are pushed without that."
      assert [%{label: "Go on past it", recommended?: true}, %{label: "Run it again"}, %{label: "Send it back to the code"}] = question.options
      assert PhaseSteps.machine_resume(%{question | answer: %{option: 1, text: "Go on past it"}}) == :go_on
      assert PhaseSteps.machine_resume(%{question | answer: %{option: 2, text: "Run it again"}}) == :again
      assert PhaseSteps.machine_resume(%{question | answer: %{option: 3, text: "Send it back to the code"}}) == :words
    end

    test "without the pull request, or GitHub's job, the check can't be read" do
      overrides = %{pr_url: nil, identifier: nil, ci_failure: %{failed_checks: [%{name: "lint", job_id: "2"}]}}
      context = context([], %{"2" => job(%{failed_steps: ["Run lint"]})}, overrides)
      assert {:ask, output, question} = FailedCheck.run(context, 60_000, fn _command, _ms -> flunk("nothing runs") end)
      assert output =~ "What failed on GitHub, run again on this run's commit:\n"
      assert output =~ "(:no_pull_request)"
      assert question.title =~ "this ticket: "

      context = context([%{name: "lint", job_id: "5"}], %{})
      assert {:ask, output, _question} = FailedCheck.run(context, 60_000, fn _command, _ms -> flunk("nothing runs") end)
      assert output =~ "Symphony could not read the result of lint on GitHub (:no_job)"
    end

    test "a failed window test runs in the QA VM, never on the host, and the VM's result is the step's" do
      checks = [%{name: "checks / mac checks", job_id: "7"}]
      jobs = %{"7" => job(%{failed_steps: ["Test the QA driver's scrolling", "Test the QA driver's key shortcuts"]})}
      test = self()

      vm = fn answer ->
        fn context, on, off, _ms ->
          send(test, {:vm, context.identifier, Enum.map(on, & &1.script), Enum.map(off, & &1.script)})
          answer
        end
      end

      shell = fn _command, _ms -> flunk("a window test never runs on the host") end
      run = fn answer -> FailedCheck.run(context(checks, jobs, %{opts: [window_tests: vm.(answer)]}), 60_000, shell) end

      assert {:ok, {output, 0}} = run.({:ok, {"scrolled", 0}})
      assert_received {:vm, "TP-88", ["macos/Tests/qa-scroll-test.py"], ["macos/Tests/qa-key-test.py"]}
      assert output =~ "its failed window test, macos/Tests/qa-scroll-test.py, in the QA VM"
      assert output =~ "scrolled\n"

      assert {:ok, {output, 1}} = run.({:ok, {"Broken by this change", 1}})
      assert output =~ "Broken by this change\n"
      assert {:timeout, "What failed" <> _rest} = run.({:timeout, "waiting"})
      assert {:ask, output, %{title: "vm"}} = run.({:ask, "(could not run: off)\n", %{title: "vm"}})
      assert output =~ "(could not run: off)\n"

      # The real Window tests step: a test that is off in the QA VM is never run, and the run stops.
      context = context(checks, %{"7" => job(%{failed_steps: ["Test the QA driver's key shortcuts"]})})
      assert {:ask, output, question} = FailedCheck.run(context, 60_000, shell)
      assert output =~ "off in the QA VM"
      assert question.title == "TP-88: a window test this change needs is turned off"
    end
  end
end
