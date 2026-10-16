defmodule SymphonyElixir.QaPreCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaPreCheck
  alias SymphonyElixir.Walkthrough

  @pr_url "https://github.com/acme/repo/pull/1040"
  @run_url "https://github.com/acme/repo/actions/runs/555/job/1"

  # A real checkout, so the named test is looked up the way a QA pass looks it up.
  setup do
    dir = Path.join(System.tmp_dir!(), "qa-pre-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "test/symphony_elixir"))
    File.mkdir_p!(Path.join(dir, ".github/workflows"))
    File.write!(Path.join(dir, "test/symphony_elixir/check_test.exs"), ~s(test "reports pass when the check passed" do\nend\n))
    File.write!(Path.join(dir, "test/symphony_elixir/other_test.exs"), ~s(test "only in the other file" do\nend\n# Walkthrough.steps\n))
    File.write!(Path.join(dir, ".github/workflows/macos-e2e.yml"), "jobs:\n  e2e:\n    name: update, restart and rollback\n")
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

  defp steps(text), do: Walkthrough.steps(text)

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
    QaPreCheck.run(steps(text), @pr_url, context.head, context.workspace, [gh_runner: gh] ++ opts)
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

    test "a test name, a scenario name or a bare file name is found in the checkout", context do
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
      """

      assert {:pass, results} = run(text, context, gh(context.head, checks))
      assert Enum.map(results, & &1.status) == List.duplicate(:pass, 7)
      assert List.last(results).detail == "`make-all` passed on `#{String.slice(context.head, 0, 12)}`"
    end

    test "a named test that is not in the checkout fails without reading CI", context do
      text = """
      1. One. Proved by: `make-all` › the QA pre-check's test file
      2. Two. Proved by: `make-all` › `test/symphony_elixir/missing_test.exs`
      3. Three. Proved by: `make-all` › `test/symphony_elixir/check_test.exs` › "only in the other file"
      """

      assert {:fail, results} = run(text, context, unused_gh())

      assert Enum.map(results, & &1.detail) == [
               "`the QA pre-check's test file` is not in the checkout",
               "`test/symphony_elixir/missing_test.exs` is not in the checkout",
               "`only in the other file` is not in the checkout"
             ]

      assert [first | _rest] = QaPreCheck.findings(results)
      assert first =~ "Step 1 (Proved by: `make-all` › the QA pre-check's test file): `the QA pre-check's test file` is not in the checkout."
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

      assert {:pass, [%{url: @run_url}]} = run("1. One. Proved by: `protected paths`", context, gh(context.head, checks))
      assert {:fail, [%{detail: detail}]} = run("1. One. Proved by: `protected-paths / protected paths`", context, gh(context.head, checks))
      assert detail =~ "did not run"
    end

    test "a check that never ran on the head fails the step", context do
      text = "1. One. Proved by: `macos-e2e` › update, restart and rollback"

      assert {:fail, [result]} = run(text, context, gh(context.head, [check("make-all", "COMPLETED", "SUCCESS")]))
      assert result.detail == "`macos-e2e` did not run on `#{String.slice(context.head, 0, 12)}`"
      assert result.url == nil
      assert QaPreCheck.linked(result) == result.detail
    end

    test "a check that only reported skipped did not run its test", context do
      text = "1. One. Proved by: `macos-e2e`"
      checks = [check("e2e", "COMPLETED", "SKIPPED", %{"workflowName" => "macos-e2e"})]

      assert {:fail, [result]} = run(text, context, gh(context.head, checks))
      assert result.detail == "`macos-e2e` was skipped on `#{String.slice(context.head, 0, 12)}`, so its test did not run"
    end

    test "a check still running is pending, and the worst step decides", context do
      pending = "1. One. Proved by: `macos-e2e`\n2. Two. Proved by: `make-all`\n"
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
      assert result.detail == "`check_test.exs` is not in the checkout"
    end
  end
end
