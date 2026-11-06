defmodule SymphonyElixir.PrWatch.SnapshotTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.PrWatch.Snapshot

  @read %{pr_number: 42, pr_url: "https://github.com/acme/app/pull/42", pr_title: "A PR", pr: :open, head_sha: "abc123", base_ref: "main", mergeable: :behind}

  defp run_check(name, status, conclusion, opts \\ []) do
    %{
      "name" => name,
      "status" => status,
      "conclusion" => conclusion,
      "detailsUrl" => "https://github.com/acme/app/actions/runs/#{Keyword.get(opts, :run, 100)}/job/#{Keyword.get(opts, :job, 1)}",
      "workflowName" => Keyword.get(opts, :workflow, "ci"),
      "startedAt" => Keyword.get(opts, :started_at),
      "completedAt" => Keyword.get(opts, :completed_at)
    }
  end

  defp checks(rollup, required \\ nil), do: Snapshot.build(@read, %{}, PullRequest.normalize_checks(rollup), required).checks

  describe "build/4" do
    test "says the PR as the watcher read it" do
      pull = %{"reviewDecision" => "APPROVED", "changedFiles" => 9, "additions" => 486, "deletions" => 52}

      assert %{
               number: 42,
               url: "https://github.com/acme/app/pull/42",
               title: "A PR",
               state: "open",
               draft: false,
               head_sha: "abc123",
               base: "main",
               mergeable: "behind",
               review_decision: "APPROVED",
               files_changed: 9,
               additions: 486,
               deletions: 52,
               checks: []
             } == Snapshot.build(@read, pull, [], nil)
    end

    test "a draft is an open PR, and a merged or closed one says so" do
      assert %{state: "open", draft: true} = Snapshot.build(%{@read | pr: :draft}, %{}, [], nil)
      assert %{state: "merged", draft: false} = Snapshot.build(%{@read | pr: :merged}, %{}, [], nil)
      assert %{state: "closed", draft: false} = Snapshot.build(%{@read | pr: :closed}, %{}, [], nil)
    end

    test "each check says its state in the read's closed vocabulary" do
      states =
        [
          run_check("passed", "COMPLETED", "SUCCESS"),
          run_check("neutral", "COMPLETED", "NEUTRAL"),
          run_check("skipped", "COMPLETED", "SKIPPED"),
          run_check("failed", "COMPLETED", "FAILURE"),
          run_check("timed out", "COMPLETED", "TIMED_OUT"),
          run_check("no machine", "COMPLETED", "CANCELLED"),
          run_check("running", "IN_PROGRESS", nil),
          run_check("queued", "QUEUED", nil)
        ]
        |> checks()
        |> Map.new(&{&1.name, &1.state})

      assert states == %{
               "passed" => "passed",
               "neutral" => "passed",
               "skipped" => "skipped",
               "failed" => "failed",
               "timed out" => "failed",
               "no machine" => "cancelled_no_machine",
               "running" => "running",
               "queued" => "waiting"
             }
    end

    test "a check says when it started, and how long it took once it finished" do
      started_at = "2026-11-06T10:00:00Z"

      assert [
               %{name: "done", started_at: ~U[2026-11-06 10:00:00Z], duration_ms: 90_000, url: "https://github.com/acme/app/actions/runs/100/job/1"},
               %{name: "running", started_at: ~U[2026-11-06 10:00:00Z], duration_ms: nil},
               %{name: "queued", started_at: nil, duration_ms: nil}
             ] =
               checks([
                 run_check("done", "COMPLETED", "SUCCESS", started_at: started_at, completed_at: "2026-11-06T10:01:30Z"),
                 run_check("running", "IN_PROGRESS", nil, started_at: started_at),
                 # `gh pr view` writes the zero time for a check that hasn't started.
                 run_check("queued", "QUEUED", nil, started_at: "0001-01-01T00:00:00Z")
               ])
    end

    test "a status from outside GitHub Actions has no workflow, and started when it was created" do
      status = %{"context" => "deploy", "state" => "PENDING", "targetUrl" => "https://ci.example/1", "createdAt" => "2026-11-06T10:00:00Z"}

      assert [%{workflow: nil, name: "deploy", state: "waiting", started_at: ~U[2026-11-06 10:00:00Z], url: "https://ci.example/1"}] = checks([status])
    end

    test "says whether the base requires a check, and nothing when it isn't known" do
      rollup = [run_check("build", "COMPLETED", "SUCCESS"), run_check("lint", "COMPLETED", "SUCCESS")]

      assert [%{name: "build", required: true}, %{name: "lint", required: false}] = checks(rollup, ["build"])
      assert [%{required: nil}, %{required: nil}] = checks(rollup)
    end

    test "a check that two runs of its workflow kept is listed once, from the newest run, in GitHub's order" do
      # Every run of the workflow cancelled keeps its checks through the watcher's dedupe.
      rollup = [
        run_check("build", "COMPLETED", "CANCELLED", run: 100, job: 1),
        run_check("other", "COMPLETED", "SUCCESS", workflow: "other", run: 150, job: 5),
        run_check("build", "IN_PROGRESS", nil, run: 200, job: 2),
        run_check("build", "COMPLETED", "SUCCESS", workflow: "other", run: 150, job: 6)
      ]

      assert [
               %{workflow: "ci", name: "build", state: "running", url: "https://github.com/acme/app/actions/runs/200/job/2"},
               %{workflow: "other", name: "other"},
               %{workflow: "other", name: "build", state: "passed"}
             ] = checks(rollup)
    end
  end
end
