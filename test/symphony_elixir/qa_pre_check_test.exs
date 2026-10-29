defmodule SymphonyElixir.QaPreCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaPreCheck
  alias SymphonyElixir.Walkthrough

  @pr_url "https://github.com/acme/repo/pull/1040"
  @tried "tried as a describe plus a test name, a test name and a describe name"
  @run_url "https://github.com/acme/repo/actions/runs/555/job/1"

  # Laid out as TP-1217's and TP-1273's test files are: a test inside a describe, its name on its own line.
  @director_moves_test """
  defmodule SymphonyElixir.DirectorMovesTest do
    describe "the Director's moves" do
      test "an approved plan's record is in the waiting state at once, and stays there when Linear refuses the move", %{opts: opts} do
        opts
      end
    end
  end
  """

  @orchestrator_status_test """
  defmodule SymphonyElixir.OrchestratorStatusTest do
    describe "the stall check and the no-progress watchdog" do
      setup do
        :ok
      end

      test "log an unobserved run once, whatever its kind, and never restart it" do
      end

      test "says \\"stalled\\" in the log" do
      end
    end

    test "outside any describe" do
    end

    test "a name that goes on
    over two lines" do
    end
  end
  """

  # A real checkout, so the named test is looked up the way a QA pass looks it up.
  setup do
    dir = Path.join(System.tmp_dir!(), "qa-pre-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "test/symphony_elixir"))
    File.mkdir_p!(Path.join(dir, ".github/workflows"))
    File.write!(Path.join(dir, "test/symphony_elixir/check_test.exs"), ~s(test "reports pass when the check passed" do\nend\ntest "handles a/b input" do\nend\n))
    File.write!(Path.join(dir, "test/symphony_elixir/other_test.exs"), ~s(test "only in the other file" do\nend\n# Walkthrough.steps\n))
    File.write!(Path.join(dir, ".github/workflows/macos-e2e.yml"), "jobs:\n  e2e:\n    name: update, restart and rollback\n")
    File.write!(Path.join(dir, "README.md"), "symphony_elixir names are listed here\n")
    File.write!(Path.join(dir, "test/symphony_elixir/director_moves_test.exs"), @director_moves_test)
    File.write!(Path.join(dir, "test/symphony_elixir/orchestrator_status_test.exs"), @orchestrator_status_test)
    # Tests whose own names open with a tracked file, as `docs/playbook.md matches …` does in this repo.
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "docs/x.md"), "# Partials\n")
    File.write!(Path.join(dir, "symphony.yml"), "repos: []\n")

    File.write!(
      Path.join(dir, "test/symphony_elixir/playbook_catalog_test.exs"),
      ~s(test "docs/x.md matches the partials" do\nend\ntest "symphony.yml is required before children are built" do\nend\n)
    )

    git!(dir, ["init", "-q"])
    git!(dir, ["add", "."])
    git!(dir, ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "-m", "first"])
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, workspace: dir, head: dir |> git!(["rev-parse", "HEAD"]) |> String.trim()}
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end

  defp steps(text), do: Walkthrough.steps(text, "make-all")

  # Answers `gh pr view` with the head `head` and its `checks`, and the head's workflow runs with none.
  defp gh(head, checks) do
    recipient = self()

    fn
      ["pr", "view", @pr_url, "--json", _fields], _opts ->
        send(recipient, :gh_pr_view)
        {Jason.encode!(%{"url" => @pr_url, "headRefOid" => head, "statusCheckRollup" => checks}), 0}

      ["api" | _endpoint], _opts ->
        {Jason.encode!(%{"workflow_runs" => []}), 0}
    end
  end

  defp unused_gh do
    fn args, _opts -> flunk("gh should not run: #{inspect(args)}") end
  end

  defp check(name, status, conclusion, attrs \\ %{}) do
    Map.merge(%{"name" => name, "workflowName" => name, "status" => status, "conclusion" => conclusion, "detailsUrl" => @run_url}, attrs)
  end

  defp run(text, context, gh, opts \\ []) do
    QaPreCheck.run(steps(text), @pr_url, context.head, context.workspace, Keyword.merge([gh_runner: gh, proof_check: "make-all"], opts))
  end

  describe "run/5" do
    test "a walkthrough without a named-test step is :none and reads nothing", context do
      assert QaPreCheck.run(steps("1. Open it. Proved by: QA\n2. Close it."), @pr_url, context.head, context.workspace, gh_runner: unused_gh()) == :none
      assert QaPreCheck.run([], @pr_url, context.head, context.workspace) == :none
    end

    test "a passed check whose test is in the checkout is pass, with the check run's link", context do
      text = "1. Run it → it works. Proved by: `make-all` › `test/symphony_elixir/check_test.exs`"

      assert {:pass, [result]} = run(text, context, gh(context.head, [check("make-all", "COMPLETED", "SUCCESS")]))
      assert result.status == :pass
      assert result.url == @run_url
      assert result.detail == "`make-all` passed on `#{String.slice(context.head, 0, 12)}` and `test/symphony_elixir/check_test.exs` is in the checkout"

      assert [%{name: "step 1 (Proved by: `make-all` › test/symphony_elixir/check_test.exs)", status: :pass, detail: detail}] =
               QaPreCheck.report_checks([result])

      assert detail == result.detail <> " (#{@run_url})"
      assert QaPreCheck.findings([result]) == []
    end

    test "a test name, a scenario name, a name with a slash or a bare file name is found in the checkout", context do
      checks = [
        check("make-all", "COMPLETED", "SUCCESS"),
        check("update, restart and rollback", "COMPLETED", "SUCCESS", %{"workflowName" => "macos-e2e"})
      ]

      text = """
      1. One. Proved by: `make-all` › "reports pass when the check passed"
      2. Two. Proved by: `macos-e2e` › update, restart and rollback
      3. Three. Proved by: `make-all` › `check_test.exs:2`
      4. Four. Proved by: `make-all` › `test/symphony_elixir/check_test.exs` › "reports pass when the check passed"
      5. Five. Proved by: `make-all` › Walkthrough.steps
      6. Six. Proved by: `macos-e2e / update, restart and rollback` › `.github/workflows`
      7. Seven. Proved by: `make-all`
      8. Eight. Proved by: `make-all` › `test/symphony_elixir/check_test.exs` › "handles a/b input"
      """

      assert {:pass, results} = run(text, context, gh(context.head, checks))
      assert Enum.map(results, & &1.status) == List.duplicate(:pass, 8)
      assert Enum.at(results, 6).detail == "`make-all` passed on `#{String.slice(context.head, 0, 12)}`"
    end

    test "a test named as an implementer copies it, file and name or describe and name, is found", context do
      checks = [check("make-all", "COMPLETED", "SUCCESS")]
      full = "the stall check and the no-progress watchdog log an unobserved run once, whatever its kind, and never restart it"
      moves = "test/symphony_elixir/director_moves_test.exs"
      status = "test/symphony_elixir/orchestrator_status_test.exs"
      approved = "an approved plan's record is in the waiting state at once, and stays there when Linear refuses the move"

      text = """
      1. TP-1217. Proved by: make-all › #{moves}: #{approved}
      2. TP-1273. Proved by: make-all › #{full}
      3. A full name alone. Proved by: `#{full}`
      4. File and full name. Proved by: `#{status}: #{full}`
      5. File, line and name. Proved by: `#{moves}:3: "#{approved}"`
      6. File, a space and name. Proved by: `#{moves} #{approved}`
      7. A bare file name and a describe. Proved by: `orchestrator_status_test.exs the stall check and the no-progress watchdog`
      8. Copied from a failure. Proved by: `test #{full} (SymphonyElixir.OrchestratorStatusTest)`
      9. Copied from --trace. Proved by: `test #{full} (2.1ms) [L#7]`
      10. An escaped quote. Proved by: `the stall check and the no-progress watchdog says "stalled" in the log`
      11. A test outside a describe. Proved by: `#{status}: outside any describe`
      12. A file and a scenario folder. Proved by: `make-all` › `.github/workflows macos-e2e.yml`
      13. A name opening with a folder's bare name. Proved by: `symphony_elixir names are listed here`
      14. A name opening with a tracked file. Proved by: `docs/x.md matches the partials`
      15. A name opening with a tracked bare file name. Proved by: make-all › symphony.yml is required before children are built
      16. A file and a name opening with a file. Proved by: `test/symphony_elixir/playbook_catalog_test.exs: docs/x.md matches the partials`
      """

      assert {:pass, results} = run(text, context, gh(context.head, checks))
      assert Enum.map(results, &{&1.step.number, &1.status}) == Enum.map(1..16, &{&1, :pass})
    end

    test "a test named nowhere fails, naming the file it narrowed to and the forms it tried", context do
      status = "test/symphony_elixir/orchestrator_status_test.exs"

      text = """
      1. The full name in another file. Proved by: `test/symphony_elixir/check_test.exs: the stall check and the no-progress watchdog log an unobserved run once, whatever its kind, and never restart it`
      2. A test outside the describe is not in it. Proved by: `#{status}: the stall check and the no-progress watchdog outside any describe`
      3. A name over two lines. Proved by: `#{status}: a name that goes on over two lines`
      4. A missing file and a name. Proved by: `test/symphony_elixir/missing_test.exs: does it`
      5. A name that opens like a path stays whole. Proved by: `Walkthrough.steps parses it`
      6. A name opening with a file, found neither in it nor anywhere. Proved by: `docs/x.md is nowhere`
      """

      assert {:fail, results} = run(text, context, unused_gh())

      assert Enum.map(results, & &1.detail) == [
               "`the stall check and the no-progress watchdog log an unobserved run once, whatever its kind, and never restart it` " <>
                 "is not in `test/symphony_elixir/check_test.exs` (#{@tried})",
               "`the stall check and the no-progress watchdog outside any describe` is not in `#{status}` (#{@tried})",
               "`a name that goes on over two lines` is not in `#{status}` (#{@tried})",
               "`test/symphony_elixir/missing_test.exs` is not in the checkout",
               "`Walkthrough.steps parses it` is not in the checkout (#{@tried})",
               "`is nowhere` is not in `docs/x.md` (#{@tried})"
             ]
    end

    test "a named test that is not in the checkout fails without reading CI", context do
      text = """
      1. One. Proved by: `make-all` › the QA pre-check's test file
      2. Two. Proved by: `make-all` › `test/symphony_elixir/missing_test.exs`
      3. Three. Proved by: `make-all` › `test/symphony_elixir/check_test.exs` › "only in the other file"
      """

      assert {:fail, results} = run(text, context, unused_gh())

      assert Enum.map(results, & &1.detail) == [
               "`the QA pre-check's test file` is not in the checkout (#{@tried})",
               "`test/symphony_elixir/missing_test.exs` is not in the checkout",
               "`only in the other file` is not in `test/symphony_elixir/check_test.exs` (#{@tried})"
             ]

      assert [first | _rest] = QaPreCheck.findings(results)

      assert first =~
               "Step 1 (Proved by: `make-all` › the QA pre-check's test file): `the QA pre-check's test file` is not in the checkout (#{@tried})."

      assert first =~ "The ticket's proof is part of its work"
    end

    test "a check that failed fails the step, linked", context do
      text = "1. One. Proved by: `make-all` › `check_test.exs`"
      checks = [check("make-all", "COMPLETED", "FAILURE")]

      assert {:fail, [result]} = run(text, context, gh(context.head, checks))
      assert result.detail == "`make-all` failed on `#{String.slice(context.head, 0, 12)}`"
      assert [finding] = QaPreCheck.findings([result])
      assert finding =~ "(#{@run_url})"
    end

    test "a status context with no workflow is named by its context", context do
      checks = [%{"context" => "protected paths", "state" => "SUCCESS", "targetUrl" => @run_url}]

      assert {:pass, [%{url: @run_url}]} = run("1. One. Proved by: `protected paths` ›", context, gh(context.head, checks))
      assert {:fail, [%{detail: detail}]} = run("1. One. Proved by: `protected-paths / protected paths` ›", context, gh(context.head, checks))
      assert detail =~ "is not a check run or workflow on"
    end

    test "the proof check that never ran on the head fails the step", context do
      text = "1. One. Proved by: `check_test.exs`"

      assert {:fail, [result]} = run(text, context, gh(context.head, [check("lint", "COMPLETED", "SUCCESS")]))
      assert result.detail == "`make-all` did not run on `#{String.slice(context.head, 0, 12)}`"
      assert result.url == nil
      assert QaPreCheck.linked(result) == result.detail
    end

    test "a test alone is run by the proof check", context do
      text = "1. One. Proved by: `test/symphony_elixir/check_test.exs`"

      assert {:pass, [result]} = run(text, context, gh(context.head, [check("make-all", "COMPLETED", "SUCCESS")]))
      assert result.detail == "`make-all` passed on `#{String.slice(context.head, 0, 12)}` and `test/symphony_elixir/check_test.exs` is in the checkout"
    end

    test "a check that is neither the proof check nor on the head fails naming the proof check", context do
      short = String.slice(context.head, 0, 12)
      checks = [check("make-all", "COMPLETED", "SUCCESS")]

      assert {:fail, [result]} = run("1. One. Proved by: `ci` › `test/symphony_elixir/check_test.exs`", context, gh(context.head, checks))

      assert result.detail ==
               "`ci` is not a check run or workflow on `#{short}`: this repo's proof check is `make-all` (`proof_check` in WORKFLOW.md)"

      assert [finding] = QaPreCheck.findings([result])
      assert finding =~ "this repo's proof check is `make-all`"

      # The check is diagnosed even when the named test is missing too, so CI is read for it.
      assert {:fail, [missing]} = run("1. One. Proved by: ci › test/x_test.exs", context, gh(context.head, checks))
      assert_received :gh_pr_view

      assert missing.detail ==
               "`test/x_test.exs` is not in the checkout, and `ci` is not a check run or workflow on `#{short}`: " <>
                 "this repo's proof check is `make-all` (`proof_check` in WORKFLOW.md)"

      # Another check that ran on the head is that check's proof.
      macos = [check("update, restart and rollback", "COMPLETED", "SUCCESS", %{"workflowName" => "macos-e2e"})]
      assert {:pass, _results} = run("1. One. Proved by: `macos-e2e` › update, restart and rollback", context, gh(context.head, macos))

      assert {:fail, [%{detail: "`missing_test.exs` is not in the checkout (#{@tried})"}]} =
               run("1. One. Proved by: `macos-e2e` › missing_test.exs", context, gh(context.head, macos))
    end

    test "without a proof check a check that never ran is named as before", context do
      text = "1. One. Proved by: `macos-e2e` › update, restart and rollback"

      assert {:fail, [result]} = run(text, context, gh(context.head, [check("make-all", "COMPLETED", "SUCCESS")]), proof_check: nil)
      assert result.detail == "`macos-e2e` did not run on `#{String.slice(context.head, 0, 12)}`"

      assert {:fail, [%{detail: "`missing_test.exs` is not in the checkout (#{@tried})"}]} =
               run("1. One. Proved by: `macos-e2e` › missing_test.exs", context, unused_gh(), proof_check: nil)
    end

    test "a check that only reported skipped did not run its test", context do
      text = "1. One. Proved by: `macos-e2e` ›"
      checks = [check("e2e", "COMPLETED", "SKIPPED", %{"workflowName" => "macos-e2e"})]

      assert {:fail, [result]} = run(text, context, gh(context.head, checks))
      assert result.detail == "`macos-e2e` was skipped on `#{String.slice(context.head, 0, 12)}`, so its test did not run"
    end

    test "a check still running is pending, and the worst step decides", context do
      pending = "1. One. Proved by: `macos-e2e` ›\n2. Two. Proved by: `make-all`\n"
      checks = [check("macos-e2e", "IN_PROGRESS", nil), check("make-all", "COMPLETED", "SUCCESS")]

      assert {:pending, [running, passed]} = run(pending, context, gh(context.head, checks))
      assert running.status == :pending
      assert running.detail == "`macos-e2e` is still running on `#{String.slice(context.head, 0, 12)}`"
      assert passed.status == :pass

      failing = pending <> "3. Three. Proved by: `make-all` › nowhere to be found\n"
      assert {:fail, [_running, _passed, %{status: :fail}]} = run(failing, context, gh(context.head, checks))
    end

    test "a step whose check failed beside a passing run of it fails", context do
      checks = [check("make-all", "COMPLETED", "SUCCESS"), check("lint", "COMPLETED", "FAILURE", %{"workflowName" => "make-all"})]

      assert {:fail, [%{detail: detail}]} = run("1. One. Proved by: `make-all`", context, gh(context.head, checks))
      assert detail =~ "`make-all` failed"
    end

    test "checks read for another commit, or not read at all, are an error", context do
      text = "1. One. Proved by: `make-all`"

      assert {:error, {:pr_head_moved, "0000"}} = run(text, context, gh("0000", [check("make-all", "COMPLETED", "SUCCESS")]))
      assert_received :gh_pr_view

      refused = fn _args, _opts -> {"HTTP 502", 1} end
      assert {:error, {:gh_failed, _args, 1, "HTTP 502"}} = run(text, context, refused)
    end

    test "a checkout git cannot list has no named test in it", context do
      git = fn _args, _workspace -> {"fatal: not a git repository", 128} end

      assert {:fail, [result]} = run("1. One. Proved by: `make-all` › `check_test.exs`", context, unused_gh(), git: git)
      assert result.detail == "`check_test.exs` is not in the checkout (#{@tried})"
    end
  end
end
