defmodule SymphonyElixir.EpicReview.MainCiTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.EpicReview.MainCi
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{Pauses, RunStore}

  @repo_key "default"
  @issue_id "issue-epic"
  @ticket {:ticket, "default", "issue-epic"}
  @sha "b98572e58594a4f0c3b1e2d3c4b5a69788796a5b"
  @new_sha "c0ffee58594a4f0c3b1e2d3c4b5a69788796a5bb"
  @now ~U[2026-11-12 12:10:00Z]
  @epic %Issue{id: "issue-epic", identifier: "TP-1381", title: "Epic", state: "Epic Review"}

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp run(name, status, created_at \\ "2026-11-12T12:05:00Z") do
    %{
      "databaseId" => System.unique_integer([:positive]),
      "workflowName" => name,
      "status" => status,
      "conclusion" => "",
      "url" => "https://github.com/acme/app/actions/runs/1",
      "createdAt" => created_at
    }
  end

  # `gh` for a base branch at `head` whose commits carry `runs` (a map of commit to its runs).
  defp gh(head, runs) do
    recipient = self()

    fn args, _opts ->
      send(recipient, {:gh, args})

      case args do
        ["api", "repos/acme/app/commits/main", "--jq", ".sha"] -> {head <> "\n", 0}
        ["run", "list", "--commit", sha | _rest] -> {Jason.encode!(Map.get(runs, sha, [])), 0}
      end
    end
  end

  # Reads the repository's GitHub repository from the configuration, as production does: tests read
  # none by default (`:main_ci_opts`).
  defp configured(fun) do
    defaults = Application.get_env(:symphony_elixir, :main_ci_opts)
    Application.put_env(:symphony_elixir, :main_ci_opts, [])

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, :main_ci_opts, defaults)
    end
  end

  defp opts(gh, extra \\ []), do: extra ++ [gh_runner: gh, github_repo: "acme/app", branch: "main", now: @now]

  describe "hold/3: before an epic review is dispatched" do
    test "pauses the epic on the base branch head while workflow runs on it are still going, naming the commit and the workflows" do
      runs = [run("release", "in_progress"), run("macos", "queued"), run("release", "queued"), run("lint", "completed")]

      log =
        capture_log(fn ->
          assert {:waiting, %{sha: @sha, runs: [_, _, _]}} = MainCi.hold(@epic, @repo_key, opts(gh(@sha, %{@sha => runs})))
        end)

      assert log =~ "Epic review for TP-1381 waits for CI on main at b98572e58594: release, macos still running"
      assert Pauses.why(@ticket) == ["Waiting for CI on main at b98572e58594: release, macos still running"]

      assert {:ok, %{reasons: [%{kind: :environment, waits_on: %{condition: "ci_wait:b98572e58594", head: @sha}, set_by: %{kind: :rule, name: "CI wait"}, releasable: true} = reason]}} =
               Pauses.get(@ticket)

      assert SymphonyElixir.CiWait.reason?(reason)
    end

    test "is ready, pausing nothing, once CI on the head finished or only stuck runs are left" do
      stuck = run("macos", "in_progress", "2026-11-12T09:00:00Z")
      assert MainCi.hold(@epic, @repo_key, opts(gh(@sha, %{@sha => [run("release", "completed"), stuck]}))) == :ready
      assert MainCi.hold(@epic, @repo_key, opts(gh(@sha, %{}))) == :ready
      refute Pauses.paused?(@ticket)
    end

    test "does not wait on what it can't read" do
      failing = fn _args, _opts -> {"Not Found", 1} end
      assert MainCi.hold(@epic, @repo_key, opts(failing)) == :ready
      assert MainCi.hold(@epic, @repo_key, opts(failing, github_repo: nil)) == :ready
      configured(fn -> assert MainCi.hold(@epic, "no-such-repo", gh_runner: failing) == :ready end)
      assert MainCi.hold(@epic, nil, opts(failing)) == :ready
      assert MainCi.hold(%Issue{id: nil}, @repo_key, opts(failing)) == :ready
      refute Pauses.paused?(@ticket)
    end

    test "dispatches the epic when the pause can't be written" do
      log = capture_log(fn -> assert MainCi.hold(@epic, @repo_key, opts(gh(@sha, %{@sha => [run("release", "in_progress")]}), pauses: RefusingPauses)) == :ready end)
      assert log =~ "Could not hold the epic review for TP-1381 on CI: :store_down; dispatching it"
    end
  end

  describe "reason/3" do
    test "keeps the line within a pause reason's length" do
      runs = for index <- 1..60, do: %{workflow_name: "workflow-#{index}"}
      assert String.length(MainCi.reason("main", @sha, runs).text) == 300
      assert MainCi.reason("main", @sha, [%{workflow_name: nil}, %{}]).text == "Waiting for CI on main at b98572e58594: a workflow still running"
    end
  end

  describe "pending_runs/2" do
    test "keeps the runs without a COMPLETED status that are not stuck" do
      runs = [%{status: "IN_PROGRESS", created_at: @now}, %{status: "COMPLETED"}, %{status: nil}, %{}, %{status: "QUEUED", created_at: DateTime.add(@now, -MainCi.stuck_seconds() - 1)}]
      assert MainCi.pending_runs(runs, @now) == [%{status: "IN_PROGRESS", created_at: @now}]
    end
  end

  describe "settled?/3" do
    test "is false while a run on the commit is still going, true once none is or the runs can't be read" do
      refute MainCi.settled?(@sha, @repo_key, opts(gh(@sha, %{@sha => [run("release", "in_progress")]})))
      assert MainCi.settled?(@sha, @repo_key, opts(gh(@sha, %{@sha => [run("release", "completed")]})))
      assert MainCi.settled?(@sha, @repo_key, opts(fn _args, _opts -> {"boom", 1} end))
      # The configured repository's GitHub repository, read from its checkout.
      configured(fn -> assert MainCi.settled?(@sha, nil, gh_runner: fn _args, _opts -> {"boom", 1} end) end)
    end
  end

  describe "recheck/1: at boot" do
    test "lifts an epic whose CI finished while Symphony was stopped, and keeps one whose CI is still going" do
      {:ok, _pause} = Pauses.set(@ticket, MainCi.reason("main", @sha, [%{workflow_name: "release"}]), set_by: %{kind: :rule, name: "CI wait"})
      {:ok, _pause} = Pauses.set({:ticket, "default", "issue-other"}, MainCi.reason("main", @new_sha, [%{workflow_name: "release"}]), set_by: %{kind: :rule, name: "CI wait"})
      {:ok, _pause} = Pauses.set({:ticket, "default", "issue-dep"}, Pauses.ticket_reason(:dependency, "TP-9"))

      runs = %{@sha => [run("release", "completed")], @new_sha => [run("release", "in_progress")]}
      assert MainCi.recheck(opts(gh(@sha, runs))) == ["issue-epic"]

      refute Pauses.paused?(@ticket)
      assert Pauses.paused?({:ticket, "default", "issue-other"})
      assert Pauses.paused?({:ticket, "default", "issue-dep"})
    end

    test "checks nothing when the store can't be read" do
      assert MainCi.recheck(run_store: DownStore) == []
    end

    test "runs in a task of its own, and a supervisor that isn't there is logged" do
      assert {:ok, pid} = MainCi.start_recheck(run_store: DownStore)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      log = capture_log(fn -> assert {:error, _reason} = MainCi.start_recheck(supervisor: :no_such_supervisor) end)
      assert log =~ "Failed to start the boot check of the epics waiting for CI"
    end
  end

  defmodule DownStore do
    def list_all_ticket_states, do: {:error, :store_down}
  end

  defmodule RefusingPauses do
    def set(_subject, _reason, _opts), do: {:error, :store_down}
  end
end
