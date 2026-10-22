defmodule SymphonyElixir.EpicReview.CiRerunTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.EpicReview.CiRerun
  alias SymphonyElixir.{Handoff, RunStore}

  @repo_key "repo-ci-rerun"
  @issue_id "issue-ci-rerun"
  @sha "feed0011223344556677889900aabbccddeeff00"
  @other_sha "beef0011223344556677889900aabbccddeeff00"
  @runs "https://github.com/acme/app/actions/runs"

  setup do
    RunStore.delete_ticket_state(@repo_key, @issue_id)
    on_exit(fn -> RunStore.delete_ticket_state(@repo_key, @issue_id) end)
    :ok
  end

  defp ci_run(id, conclusion, attrs \\ %{}) do
    Map.merge(%{id: id, workflow_name: "CI", status: "COMPLETED", conclusion: conclusion, url: "#{@runs}/#{id}", created_at: nil}, attrs)
  end

  # `gh` for a run whose one failed job `verify` logs a failed Go test named after the run, and
  # whose rerun answers `rerun_answer`.
  defp gh(rerun_answer \\ {"", 0}) do
    recipient = self()

    fn args, _opts ->
      send(recipient, {:gh, args})

      case args do
        ["run", "rerun" | _rest] ->
          rerun_answer

        ["run", "view", "--job", _job | _rest] ->
          {"verify\tgo test\t2026-10-20T06:30:00.000Z --- FAIL: TestFlaky (0.30s)\n", 0}

        ["run", "view", id | _rest] ->
          job = %{"databaseId" => String.to_integer("9" <> id), "name" => "verify", "conclusion" => "failure", "url" => "#{@runs}/#{id}/job/9#{id}"}
          {Jason.encode!(%{"url" => "#{@runs}/#{id}", "workflowName" => "CI", "jobs" => [job]}), 0}

        ["api", _endpoint] ->
          {"[]", 0}
      end
    end
  end

  defp check(runs, opts \\ [], sha \\ @sha, repo_key \\ @repo_key),
    do: CiRerun.check(repo_key, @issue_id, sha, runs, Keyword.merge([workspace: "/tmp/ws", gh_runner: gh()], opts))

  defp reruns, do: for({:gh, ["run", "rerun" | _rest] = args} <- drain(), do: args)

  defp drain(acc \\ []) do
    receive do
      message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp signals(name), do: Enum.filter(Handoff.signals(@repo_key, @issue_id), &(&1.name == name))

  test "names the signals it records" do
    assert CiRerun.rerun_signal() == "ci_rerun"
    assert CiRerun.flake_signal() == "ci_flake"
  end

  test "a commit with no failed run proceeds without a rerun or a signal" do
    assert {:proceed, nil} = check([ci_run("701", "SUCCESS"), ci_run("702", nil, %{id: nil})])

    assert reruns() == []
    assert Handoff.signals(@repo_key, @issue_id) == []
  end

  test "a rerun it cannot record is not made, so a commit is never rerun twice" do
    log = capture_log(fn -> assert {:proceed, nil} = check([ci_run("701", "FAILURE")], [], @sha, nil) end)

    assert reruns() == []
    assert log =~ "Epic review did not rerun the failed CI on feed00112233: it could not record the rerun"
  end

  test "a rerun gh refuses proceeds naming it, and the commit is not rerun again" do
    runs = [ci_run("701", "FAILURE")]

    {result, log} = with_log(fn -> check(runs, gh_runner: gh({"HTTP 403", 1})) end)

    assert result ==
             {:proceed, %{name: :ci_rerun, status: :attention, detail: "Symphony could not rerun CI (#{@runs}/701) on feed00112233; the review judges the red commit"}}

    assert log =~ "Epic review could not rerun run 701 on feed00112233"
    assert signals("ci_wait_started") == []

    assert {:proceed, %{detail: "CI (#{@runs}/701) is not green after Symphony's rerun"}} = check(runs)
    assert reruns() == [["run", "rerun", "701", "--failed", "-R", "acme/app"]]
    assert signals("ci_flake") == []
  end

  test "a run whose log it cannot read is still rerun, and its flake is named by its id" do
    run = ci_run("701", "FAILURE", %{url: nil, workflow_name: nil})

    log = capture_log(fn -> assert {:wait, [^run]} = check([run]) end)

    assert reruns() == [["run", "rerun", "701", "--failed"]]
    assert log =~ "Epic review could not read the failed jobs of run 701 before rerunning it"
    assert log =~ "Epic review reran the failed CI on feed00112233: run 701 (701)"
    assert [%{details: %{runs: [%{id: "701", jobs: [], tests: []}]}}] = signals("ci_rerun")

    green = %{run | conclusion: "SUCCESS"}
    assert {:proceed, %{detail: "run 701 (701) failed and passed on Symphony's rerun, a flake"}} = check([green])
    assert [%{details: %{sha: @sha, runs: ["701"], workflows: [], jobs: [], tests: []}}] = signals("ci_flake")
  end

  test "a run green on rerun is a flake, recorded once; one gone from the list is not green" do
    failed = [ci_run("701", "FAILURE"), ci_run("702", "TIMED_OUT")]

    assert {:wait, ^failed} = check(failed)
    assert reruns() == [["run", "rerun", "701", "--failed", "-R", "acme/app"], ["run", "rerun", "702", "--failed", "-R", "acme/app"]]
    assert [%{details: %{sha: @sha}}] = signals("ci_wait_started")

    after_rerun = [ci_run("701", "SUCCESS")]

    expected =
      "CI (#{@runs}/701) failed and passed on Symphony's rerun, a flake in verify, TestFlaky; " <>
        "CI (#{@runs}/702) is not green after Symphony's rerun"

    assert {:proceed, %{detail: ^expected}} = check(after_rerun)
    assert {:proceed, %{detail: ^expected}} = check(after_rerun)

    assert [%{details: %{runs: ["#{@runs}/701"], workflows: ["CI"], jobs: ["verify"], tests: ["TestFlaky"]}}] = signals("ci_flake")
    assert reruns() == []
  end

  test "a new commit is rerun again" do
    assert {:wait, _runs} = check([ci_run("701", "FAILURE")])
    assert {:wait, _runs} = check([ci_run("801", "FAILURE")], [], @other_sha)

    assert length(reruns()) == 2
    assert length(signals("ci_rerun")) == 2
  end

  test "a run GitHub cancelled is rerun and waited on, twice per run and commit, and never spends the failed run's rerun" do
    assert CiRerun.cancel_signal() == "ci_cancel_rerun"
    cancelled = [ci_run("701", "CANCELLED", %{workflow_name: "macos"}), ci_run("702", "SUCCESS")]

    log = capture_log(fn -> assert {:wait, [%{id: "701"}]} = check(cancelled) end)
    assert log =~ "Epic review reran the cancelled CI on feed00112233: macos (#{@runs}/701); GitHub cancelled it, which is no failure"
    assert reruns() == [["run", "rerun", "701", "--failed", "-R", "acme/app"]]
    assert [%{details: %{sha: @sha, run: "701", workflow: "macos"}}] = signals("ci_cancel_rerun")
    assert [%{details: %{sha: @sha}}] = signals("ci_wait_started")
    assert signals("ci_rerun") == []

    # Cancelled again: rerun once more; a third time the review goes on, with nothing filed as a failure.
    assert {:wait, _runs} = check(cancelled)
    assert {:proceed, nil} = check(cancelled)
    assert [["run", "rerun", "701" | _rest]] = reruns()
    assert length(signals("ci_cancel_rerun")) == 2
    assert signals("ci_rerun") == []

    # A failed run still gets its one rerun beside a cancelled one past its reruns.
    assert {:wait, [%{id: "703"}]} = check(cancelled ++ [ci_run("703", "FAILURE")])
    assert [["run", "rerun", "703" | _rest]] = reruns()

    # Another commit's cancelled run is rerun afresh.
    assert {:wait, _runs} = check(cancelled, [], @other_sha)
  end

  test "a cancelled run's rerun it cannot record, or gh refuses, is not waited on" do
    cancelled = [ci_run("701", "CANCELLED")]

    log = capture_log(fn -> assert {:proceed, nil} = check(cancelled, [], @sha, nil) end)
    assert log =~ "Epic review did not rerun the cancelled run 701 on feed00112233: it could not record the rerun"
    assert reruns() == []

    log = capture_log(fn -> assert {:proceed, nil} = check(cancelled, gh_runner: gh({"HTTP 403", 1})) end)
    assert log =~ "Epic review could not rerun run 701 on feed00112233"
    assert signals("ci_wait_started") == []
  end

  describe "test_names/1" do
    test "reads ExUnit, Go, XCTest and Swift Testing failures, once each and in order" do
      log = """
        1) test reruns once per head (SymphonyElixir.EpicReviewTest)
      --- FAIL: TestAnAppThatDoesntQuitAbandonsTheInstall (0.30s)
      --- FAIL: TestAnAppThatDoesntQuitAbandonsTheInstall (0.30s)
      Test Case '-[SymphonyBarCoreTests.UpdaterTests testRollback]' failed (0.010 seconds).
      ✘ Test settingsOpen() recorded an issue at SettingsTests.swift:12:5
      ✘ Test "Dark mode" failed after 0.2 seconds.
      """

      assert CiRerun.test_names(log) == [
               "test reruns once per head (SymphonyElixir.EpicReviewTest)",
               "TestAnAppThatDoesntQuitAbandonsTheInstall",
               "SymphonyBarCoreTests.UpdaterTests testRollback",
               "settingsOpen()",
               "\"Dark mode\""
             ]
    end

    test "keeps at most ten names, and a log without a failed test has none" do
      log = Enum.map_join(1..12, "\n", &"--- FAIL: TestCase#{&1} (0.01s)")

      assert length(CiRerun.test_names(log)) == 10
      assert CiRerun.test_names("all green\n") == []
    end
  end
end
