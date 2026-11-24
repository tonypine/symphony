defmodule SymphonyElixir.AgentRunnerProgressPrTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.AgentRunnerProgressSupport

  alias SymphonyElixir.Pauses
  alias SymphonyElixir.PrWatch.Attempts
  alias SymphonyElixir.PrWatchSupport
  alias SymphonyElixir.Questions
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.WorkspaceHead

  @pr_url "https://github.com/example/repo/pull/337"
  @now_ms 1_791_000_000_000
  @rate_limited {:error, {:linear_rate_limited, 1_791_000_030_000}}

  setup do
    Application.put_env(:symphony_elixir, :progress_agent_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-rework", checks: []}})
    RunStore.delete_ticket_state("issue-progress")

    on_exit(fn ->
      RunStore.delete_ticket_state("issue-progress")

      for key <- [
            :progress_agent_recipient,
            :progress_agent_turns,
            :progress_pr_head_result,
            :progress_api_unreachable,
            :progress_turn_hook,
            :progress_turn_extra,
            :memory_tracker_update_issue_state_result,
            :memory_tracker_create_comment_result
          ] do
        Application.delete_env(:symphony_elixir, key)
      end
    end)

    :ok
  end

  describe "a CI Fix run with checks running on the head it started on (TP-1175)" do
    test "ends in a wait on CI after its first idle turn: no second turn, no hold, no move" do
      pending = [%{name: "macos-e2e", status: "QUEUED", conclusion: nil, url: "https://ci/1"}, %{name: "specs", status: "COMPLETED", conclusion: "SUCCESS"}]
      :ok = put_pending_ci_failure(approved: false)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: pending}})

      assert {:ci_pending, %{sha: "sha-same", run: "the CI Fix run", runs: [%{workflow_name: "macos-e2e", url: "https://ci/1"}]}} =
               catch_exit(capture_log(fn -> run_issue!("CI Fix", heads: ["sha-same"], max_turns: 5, repos: designed_repos()) end))

      assert turns() == 1
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue" <> _note}
      assert {:ok, nil} = Pauses.get({:ticket, "default", "issue-progress"})
    end

    test "still waits on CI after the watcher clears the failure that dispatched the run" do
      pending = [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil, url: "https://ci/pending"}]
      :ok = put_pending_ci_failure(approved: false)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: pending}})

      Application.put_env(:symphony_elixir, :progress_turn_hook, fn _opts ->
        PrWatchSupport.put_watch!("default", "issue-progress",
          phase: :ci_fix,
          head_sha: "sha-same",
          pr_url: @pr_url,
          facts: %{ci: :pending},
          decision: %{rule: "R24", kind: :wait, owner: :ci, reason: "Checks are running on the PR head"}
        )
      end)

      assert {:ci_pending, %{sha: "sha-same", run: "the CI Fix run", runs: [%{workflow_name: "make-all", url: "https://ci/pending"}]}} =
               catch_exit(capture_log(fn -> run_issue!("CI Fix", heads: ["sha-same"], max_turns: 5, repos: designed_repos()) end))

      assert turns() == 1
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue" <> _note}
      assert {:ok, nil} = Pauses.get({:ticket, "default", "issue-progress"})
      assert Questions.open({:ticket, "default", "issue-progress"}) == []
    end
  end

  describe "a CI Fix run whose work was taking the base branch in (TP-1587)" do
    test "ends in a wait on CI for its head after its first idle turn: no park, no question" do
      test_pid = self()
      :ok = put_pending_ci_failure(approved: false)
      # GitHub lists no check on the merged head yet.
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-merged", checks: []}})

      reader = fn _workspace, nil, start_head, base_ref ->
        send(test_pid, {:base_read, start_head, base_ref}) && true
      end

      pusher = fn _workspace, nil, _source_repo -> send(test_pid, :pushed) && :nothing end

      log =
        capture_log(fn ->
          assert {:ci_pending, %{sha: "sha-merged", run: "the CI Fix run", runs: [%{workflow_name: "CI on the head that took the base branch in", url: nil}]}} =
                   catch_exit(
                     run_issue!("CI Fix",
                       heads: ["sha-start", "sha-merged"],
                       max_turns: 5,
                       repos: designed_repos(),
                       runner_opts: [workspace_base_reader: reader, workspace_pusher: pusher]
                     )
                   )
        end)

      assert turns() == 2
      assert_received {:base_read, "sha-start", "origin/main"}
      assert_received :pushed
      assert log =~ "its work took the base branch in, waiting for CI on its head sha-merged"
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue" <> _note}
      assert {:ok, nil} = Pauses.get({:ticket, "default", "issue-progress"})
      assert Questions.open({:ticket, "default", "issue-progress"}) == []
    end

    test "a run with work of its own, or whose head never moved, idles out as before" do
      :ok = put_pending_ci_failure(approved: false)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-merged", checks: []}})
      reader = fn _workspace, nil, _start_head, _base_ref -> false end

      capture_log(fn ->
        run_issue!("CI Fix",
          heads: ["sha-start", "sha-merged"],
          max_turns: 5,
          repos: designed_repos(),
          runner_opts: [workspace_base_reader: reader]
        )
      end)

      assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue where it is" <> _note}
    end

    test "a head it can't push is left to the idle rules" do
      test_pid = self()
      :ok = put_pending_ci_failure(approved: false)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-merged", checks: []}})
      reader = fn _workspace, nil, _start_head, _base_ref -> true end
      pusher = fn _workspace, nil, _source_repo -> send(test_pid, :push_refused) && {:error, :origin_mismatch} end

      capture_log(fn ->
        run_issue!("CI Fix",
          heads: ["sha-start", "sha-merged"],
          max_turns: 5,
          repos: designed_repos(),
          runner_opts: [workspace_base_reader: reader, workspace_pusher: pusher]
        )
      end)

      assert turns() == 3
      assert_received :push_refused
      assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue where it is" <> _note}
    end
  end

  describe "the ticket's PR from Symphony's record, with none attached in Linear" do
    setup do
      :ok = TicketPullRequest.record_created("default", "issue-progress", @pr_url, "auto/TP-337")
    end

    test "a Rework run moves to Code Review once its commits are the recorded PR's head" do
      run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework", pr_url: nil)

      assert turns() == 1
      assert_received {:pr_head_fetched, @pr_url}
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    end

    test "empty Rework turns wait for CI pending on the recorded PR's head instead of parking" do
      pending = [%{name: "macos-e2e", status: "IN_PROGRESS", conclusion: nil}]
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-pushed", checks: pending}})

      run_issue!("Rework", heads: ["sha-pushed"], max_turns: 4, pr_url: nil)

      assert turns() == 4
      assert_received {:pr_head_fetched, @pr_url}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "the run moves on the recorded PR once its pushed head is the PR head, with no reviewer turn before" do
      pending = [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: pending}})

      log =
        capture_log(fn ->
          run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", max_turns: 6, reviewer: true, pr_url: nil)
        end)

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute log =~ "reviewer"
    end

    test "a closed or merged PR is no in-flight PR" do
      for finished <- ["closed", "merged"] do
        :ok = TicketPullRequest.record_created("default", "issue-progress", @pr_url, "auto/TP-337")
        :ok = TicketPullRequest.mark_finished("default", @pr_url, finished)
        next_run()

        log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 5, pr_url: nil) end)

        assert turns() == 2
        refute_received {:pr_head_fetched, _pr_url}
        refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        assert log =~ "Symphony has no open PR recorded for it, so CI on its head was not checked"
        refute log =~ "at dispatch"
      end
    end

    test "a run whose recorded PR closes mid-run warns that its PR checks will not run" do
      Application.put_env(:symphony_elixir, :progress_turn_hook, fn _opts ->
        :ok = TicketPullRequest.mark_finished("default", @pr_url, "closed")
      end)

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 5, pr_url: nil) end)

      assert log =~
               "issue_id=issue-progress issue_identifier=TP-337 had PR #{@pr_url} at dispatch, " <>
                 "but Symphony's record of its PR now shows no open PR; checks on its PR will not run"

      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end
  end

  describe "the stop after a PR is open" do
    test "waits until the workspace HEAD is the PR head, so a committed fix is pushed first" do
      pr_heads = [{:ok, %{commit_sha: "sha-old", checks: []}}, {:ok, %{commit_sha: "sha-fix", checks: []}}]
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:by_turn, pr_heads})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-old", "sha-fix"], handoff: "sha-fix", max_turns: 4) end)

      assert turns() == 2
      # Once the fix is the PR head, the stop hands it off.
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert log =~ "Not stopping agent run for issue_id=issue-progress issue_identifier=TP-337 after PR opened; workspace HEAD sha-fix is not its PR head sha-old"
      assert log =~ "Stopping agent run for issue_id=issue-progress issue_identifier=TP-337 after PR opened"
    end

    test "still stops after the first turn when the workspace HEAD is the PR head" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-pushed", checks: []}})

      for heads <- [["sha-pushed"], ["sha-old", "sha-pushed"]] do
        next_run()

        log = capture_log(fn -> run_issue!("In Progress", heads: heads, max_turns: 4) end)

        assert turns() == 1
        assert_received {:pr_head_fetched, @pr_url}
        assert log =~ "Stopping agent run for issue_id=issue-progress issue_identifier=TP-337 after PR opened"
        refute log =~ "Not stopping"
      end
    end

    test "stops as before when the workspace HEAD or the PR head is unreadable" do
      for {heads, pr_head_result} <- [
            {[nil], {:ok, %{commit_sha: "sha-old", checks: []}}},
            {["sha-old", "sha-fix"], {:error, :gh_unavailable}},
            {["sha-old", "sha-fix"], {:ok, %{commit_sha: nil, checks: []}}}
          ] do
        Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_head_result)
        next_run()

        run_issue!("In Progress", heads: heads, max_turns: 4)

        assert turns() == 1
      end
    end
  end

  describe "a run on an issue whose PR is already open" do
    @pending_checks [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]
    @green_checks [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    @red_checks [%{name: "make-all", status: "COMPLETED", conclusion: "FAILURE"}]

    setup do
      # The conflict that started the run stays pending until the PR poller sees the PR clean,
      # so the post-PR stop never ends the run.
      :ok = put_pending_conflict()
    end

    test "moves to Code Review as soon as CI runs on the head it pushed, instead of turning until it is parked" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", max_turns: 6) end)

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
      refute log =~ "Parking"
      assert_signal("handoff", %{to: "Code Review", reason: "with CI running on its pushed head", head: "sha-fixed", move: true})
    end

    test "refreshed from Linear, takes its PR from Symphony's record, so CI running on the head it pushed moves it to Code Review" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}})
      fetcher = linear_issue_fetcher()

      log =
        capture_log(fn ->
          run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", max_turns: 6, issue_state_fetcher: fetcher)
        end)

      assert turns() == 1
      assert_received {:pr_head_fetched, @pr_url}
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
    end

    test "with Code Review's reviewer on, pushes and moves to Code Review with no reviewer turn before the push" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", max_turns: 6, reviewer: true) end)

      # The turn that pushed is the last: no reviewer-agent guidance turn follows it.
      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
      refute log =~ "reviewer-agent guidance"
    end

    test "waits a turn for the checks of the head it pushed to show up, then moves to Code Review" do
      no_checks = {:ok, %{commit_sha: "sha-fixed", checks: []}}
      pending = {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}}
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:by_turn, [no_checks, pending]})

      run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", max_turns: 6)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end

    test "without the retired auto_review block moves to Code Review as soon as its pushed head is green" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @green_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", auto_review: nil) end)

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert log =~ "CI is green on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
    end

    test "hands off as CI running, not green, while a rerun of its pushed head's failed jobs is starting" do
      # TP-546: the failed checks leave the rollup until the rerun's new attempt queues them, so
      # only the checks that passed are left.
      passed = [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS", run_id: "987"}]
      run_not_finished = %{commit_sha: "sha-fixed", checks: passed, workflow_runs: [%{id: "987", status: "QUEUED", conclusion: nil}]}

      # The head's workflow run is not finished; then, with that run unread, the PR watcher's record
      # of the rerun it started on this head.
      rerun = %{Attempts.new() | reruns: %{"sha-fixed" => ["dialyzer"]}}

      for {ci_status, attempts} <- [{run_not_finished, nil}, {%{commit_sha: "sha-fixed", checks: passed}, rerun}] do
        if attempts, do: PrWatchSupport.update_watch!("default", "issue-progress", &%{&1 | attempts: attempts})
        Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, ci_status})
        next_run()

        log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", auto_review: nil) end)

        assert turns() == 1
        assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
        assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
        refute log =~ "CI is green"
      end
    end

    test "is still parked when it pushed nothing, its head is red or has no checks, or its head is not the PR head" do
      for {heads, pr_head_result} <- [
            {["sha-same"], {:ok, %{commit_sha: "sha-same", checks: @green_checks}}},
            {["sha-dirty", "sha-fixed"], {:ok, %{commit_sha: "sha-fixed", checks: @red_checks}}},
            {["sha-dirty", "sha-fixed"], {:ok, %{commit_sha: "sha-fixed", checks: []}}},
            {["sha-dirty", "sha-fixed"], {:ok, %{commit_sha: "sha-dirty", checks: @green_checks}}},
            {["sha-dirty", "sha-fixed"], {:ok, %{commit_sha: "sha-dirty", checks: @pending_checks}}},
            {["sha-dirty", "sha-fixed"], {:error, :gh_unavailable}}
          ] do
        Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_head_result)
        next_run()

        run_issue!("In Progress", heads: heads, max_turns: 6)

        assert turns() == if(length(heads) == 1, do: 2, else: 3)
        refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        refute_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      end
    end

    test "keeps turning when its workspace HEAD is unreadable" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: nil, checks: @green_checks}})

      run_issue!("In Progress", heads: [nil], max_turns: 3)

      assert turns() == 3
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "landing on a green pushed head is left to the Merging flow" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @green_checks}})

      run_issue!("Merging", heads: ["sha-dirty", "sha-fixed"], states: ["Merging", "Merging", "Done"], max_turns: 5)

      assert turns() == 3
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end
  end

  describe "a run whose pushed head GitHub has not attached to its PR yet (TP-1422)" do
    # TP-1420: the branch was at the run's fix, the PR still showed the older red head for twelve
    # minutes, and the idle park read that as "no new commit".
    @stale_red {:ok,
                %{
                  commit_sha: "sha-dirty",
                  head_ref_name: "auto/TP-337",
                  base_ref_name: "main",
                  checks: [%{name: "make-all", status: "COMPLETED", conclusion: "FAILURE"}]
                }}
    @picked_up {:ok,
                %{
                  commit_sha: "sha-fixed",
                  head_ref_name: "auto/TP-337",
                  base_ref_name: "main",
                  checks: [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]
                }}

    setup do
      :ok = put_pending_conflict()
    end

    defp branch_at(tip), do: [head_sync: [branch_tip_reader: fn _workspace, nil, "auto/TP-337" -> tip end, wait_ms: 0]]

    test "waits for GitHub instead of parking while the PR head lags the branch it pushed" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, @stale_red)

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], max_turns: 5, runner_opts: branch_at("sha-fixed")) end)

      assert turns() == 5
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      refute log =~ "Parking"
      assert log =~ "Not parking issue_id=issue-progress issue_identifier=TP-337; waiting for GitHub to pick up its pushed head sha-fixed on its PR"

      notes = "issue-progress" |> SymphonyElixir.TicketEvents.query(types: ["note"]) |> Enum.map(& &1.payload.text)

      assert ["Waiting for GitHub to pick up sha-fixe: the branch is at it, but PR #337 still shows sha-dirt"] =
               Enum.filter(notes, &(&1 =~ "GitHub"))
    end

    test "once GitHub picks the head up, hands off with CI running on it, as any pushed head" do
      by_turn = {:by_turn, [@stale_red, @stale_red, @stale_red, @picked_up]}
      Application.put_env(:symphony_elixir, :progress_pr_head_result, by_turn)

      log =
        capture_log(fn ->
          run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", max_turns: 6, runner_opts: branch_at("sha-fixed"))
        end)

      assert turns() == 4
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert log =~ "waiting for GitHub to pick up its pushed head sha-fixed"
      assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
    end

    test "still parks when the branch is not at the run's head either: the PR is right, the head is not pushed" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, @stale_red)

      capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], max_turns: 5, runner_opts: branch_at("sha-dirty")) end)

      assert turns() == 3
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end
  end

  describe "a CI Fix run on the default step list (TP-1555)" do
    @red_test_job %{
      failed_steps: ["Run coverage partition"],
      annotations: ["failure ExUnit failure: 1) test it works (App.ThingTest)\n test/app/thing_test.exs:12"],
      log: ""
    }

    # The workspace's shell: the changed-files script reports a changed module and its test file,
    # the failed test file's run answers `test_result` and is reported to the test, and every
    # other command passes.
    defp failed_check_runner(test_result) do
      parent = self()

      fn command, _env, _timeout_ms ->
        cond do
          command =~ "git merge-base" -> {:ok, {"M\tlib/app/thing.ex\nT\ttest/app/thing_test.exs\n", 0}}
          command == "mix test test/app/thing_test.exs" -> send(parent, {:ran, command}) && test_result
          true -> {:ok, {"", 0}}
        end
      end
    end

    # GitHub's read of the red job, as the CI log tool returns it, reported to the test.
    defp red_job_read do
      parent = self()

      fn repo, {:job, job_id}, opts ->
        send(parent, {:ci_log_read, repo, job_id, Keyword.take(opts, [:failed_only])})
        {:ok, %{jobs: [@red_test_job]}}
      end
    end

    defp run_ci_fix_walk!(test_result) do
      checks = [%{name: "coverage (2/4)", status: "COMPLETED", conclusion: "FAILURE", job_id: 101}]
      :ok = put_pending_ci_failure(approved: false, commit_sha: "sha-red", failed_checks: checks)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-red", checks: []}})

      capture_log(fn ->
        # A pending CI failure makes the In Progress run a CI Fix run.
        run_issue!("In Progress",
          heads: ["sha-red", "sha-fix"],
          max_turns: 6,
          symphony_steps: "",
          runner_opts: [
            step_command_runner: failed_check_runner(test_result),
            failed_check_opts: [read: red_job_read()],
            run_id: "run-progress"
          ]
        )
      end)
    end

    defp step_events(type, step_id) do
      for %{payload: %{step_id: ^step_id}} = event <- SymphonyElixir.TicketEvents.query("issue-progress", types: [type], limit: 200), do: event
    end

    test "the runner gives the step the run's failure and PR: it runs the failed test file, and the hand off starts only after it passes" do
      run_ci_fix_walk!({:ok, {"ok\n", 0}})

      assert_received {:ci_log_read, "example/repo", "101", [failed_only: true]}
      assert_received {:ran, "mix test test/app/thing_test.exs"}
      assert [%{seq: passed_seq, payload: %{outcome: "passed"}}] = step_events("step.completed", "failed_check")
      assert [%{seq: handoff_seq} | _rest] = step_events("step.started", "handoff")
      assert passed_seq < handoff_seq
    end

    test "the runner sends a failed test back to the fix step, and the hand off never starts" do
      run_ci_fix_walk!({:ok, {"1) test it works\nAssertion failed", 2}})

      assert_received {:ran, "mix test test/app/thing_test.exs"}
      assert [%{payload: %{outcome: "failed", returns_to: "fix"}} | _rest] = step_events("step.completed", "failed_check")
      assert step_events("step.started", "handoff") == []
    end
  end

  describe "a CI-fix run that pushes nothing" do
    # TP-656: the red check was a flake (also red on main), and its rerun on the PR head passed.
    @green_checks [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    @red_checks [%{name: "make-all", status: "COMPLETED", conclusion: "FAILURE"}]

    test "on an approved PR goes back to Merging once CI on its head is green" do
      :ok = put_pending_ci_failure(approved: true)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 6) end)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Merging"}
      assert_received {:memory_tracker_comment, "issue-progress", "Symphony moved this issue back to Merging: " <> note}
      assert note =~ "CI on the PR head `sha-same` is green, so the approval still covers the PR and auto-merge turns back on"
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "CI fix run for issue_id=issue-progress issue_identifier=TP-337 pushed nothing and CI on its PR head sha-same is green; moving back to Merging"
      refute log =~ "Parking"
      assert_signal("handoff", %{to: "Merging", kind: :ci_fix, head: "sha-same", move: true})
    end

    test "on a PR that was not approved goes to the post-PR state once CI on its head is green" do
      :ok = put_pending_ci_failure(approved: false)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      for {auto_review, post_pr_state} <- [{%{enabled: true}, "Code Review"}, {nil, "Code Review"}] do
        next_run()

        log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], handoff: "sha-same", max_turns: 6, auto_review: auto_review) end)

        assert turns() == 2
        assert_received {:memory_tracker_state_update, "issue-progress", ^post_pr_state}
        refute_received {:memory_tracker_state_update, "issue-progress", _state}
        refute_received {:memory_tracker_comment, "issue-progress", "Symphony moved" <> _note}

        assert log =~
                 "CI is green on issue_id=issue-progress issue_identifier=TP-337's PR head sha-same after a CI fix run with no new commit; moving to #{post_pr_state}"
      end
    end

    test "on an approved PR goes to the post-PR state when its head is not the commit that failed" do
      # An earlier CI-fix run pushed `sha-same` and ended before it handed the PR off.
      :ok = put_pending_ci_failure(approved: true, commit_sha: "sha-red")
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], handoff: "sha-same", max_turns: 6) end)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", _state}
      refute_received {:memory_tracker_comment, "issue-progress", "Symphony moved" <> _note}

      assert log =~
               "CI is green on issue_id=issue-progress issue_identifier=TP-337's PR head sha-same after a CI fix run with no new commit; moving to Code Review"

      assert_signal("handoff", %{to: "Code Review", reason: "with CI green on its PR head", head: "sha-same", move: true})
    end

    test "waits while CI on its head runs, then goes back to Merging once it is green" do
      :ok = put_pending_ci_failure(approved: true)
      pending = {:ok, %{commit_sha: "sha-same", checks: [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]}}
      green = {:ok, %{commit_sha: "sha-same", checks: @green_checks}}
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:by_turn, [pending, pending, pending, green]})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 6) end)

      assert turns() == 4
      assert_received {:memory_tracker_state_update, "issue-progress", "Merging"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "Not parking issue_id=issue-progress issue_identifier=TP-337; waiting for CI on its pushed head sha-same"
    end

    test "is still parked when the check on its head is still red, has no checks or is not the PR head" do
      :ok = put_pending_ci_failure(approved: true)

      for pr_head_result <- [
            {:ok, %{commit_sha: "sha-same", checks: @red_checks}},
            {:ok, %{commit_sha: "sha-same", checks: []}},
            {:ok, %{commit_sha: "sha-other", checks: @green_checks}}
          ] do
        Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_head_result)
        next_run()

        run_issue!("In Progress", heads: ["sha-same"], max_turns: 6)

        assert turns() == 2
        refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue where it is" <> _note}
        refute_received {:memory_tracker_state_update, "issue-progress", _state}
      end
    end

    test "in Rework after a CI failure moves to Code Review on a green head without a new commit or question" do
      :ok = put_pending_ci_failure(approved: true)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      run_issue!("Rework", heads: ["sha-same"], max_turns: 6)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Merging"}
      refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue" <> _note}
      assert Questions.open({:ticket, "default", "issue-progress"}) == []
      assert {:ok, nil} = Pauses.get({:ticket, "default", "issue-progress"})
      assert_handoff_recorded("sha-same", "pushed_pr_head")
      assert RunStore.get_rework_base("default", "issue-progress") == nil
    end

    test "in Rework after a CI failure moves to Code Review while checks run, without retrying or asking" do
      :ok = put_pending_ci_failure(approved: false)
      pending = [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: pending}})

      run_issue!("Rework", heads: ["sha-same"], max_turns: 6)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue" <> _note}
      assert Questions.open({:ticket, "default", "issue-progress"}) == []
      assert {:ok, nil} = Pauses.get({:ticket, "default", "issue-progress"})
      assert_handoff_recorded("sha-same", "pushed_pr_head")
      assert RunStore.get_rework_base("default", "issue-progress") == nil
    end

    test "in Rework with unresolved reviewer comments keeps the no-progress guard on a green head" do
      :ok = put_pending_ci_failure(approved: false)

      assert :ok =
               RunStore.put_pr_review(%{
                 repo_key: "default",
                 issue_id: "issue-progress",
                 issue_identifier: "TP-337",
                 pr_url: @pr_url,
                 workspace_path: "/tmp",
                 status: "rework_requested",
                 pending_last_addressed_comment_id: "comment-337",
                 pending_reviewer_comments: [%{id: "comment-337", kind: "inline_comment", author: "Reviewer", body: "Rename this."}],
                 updated_at: ~U[2026-10-03 12:00:00Z]
               })

      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      run_issue!("Rework", heads: ["sha-same"], max_turns: 6)

      assert turns() == 2
      refute_received {:memory_tracker_state_update, "issue-progress", "Code Review"}

      assert [%{title: "TP-337 is paused in Rework: its last 2 turns changed nothing"}] =
               Questions.open({:ticket, "default", "issue-progress"})
    end

    test "fails the run when its move back to Merging or to the post-PR state fails" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :linear_down})

      for approved <- [true, false] do
        :ok = put_pending_ci_failure(approved: approved)
        next_run()

        assert_raise RuntimeError, ~r/green_fix_handoff_failed/, fn ->
          run_issue!("In Progress", heads: ["sha-same"], max_turns: 6)
        end
      end
    end
  end

  describe "a CI Fix run that returns to its origin" do
    # The CI Fix lane's return: a mechanical repair that pushed nothing goes back where it came
    # from, rather than to the post-PR state review would judge again.
    @green_checks [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]

    test "a repair on a Code Review ticket returns to Code Review, clearing the recorded origin" do
      :ok = put_pending_ci_failure(approved: true)
      :ok = SymphonyElixir.CiFix.record_origin("default", "issue-progress", "Code Review")
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      log = capture_log(fn -> run_issue!("CI Fix", heads: ["sha-same"], max_turns: 6, repos: designed_repos()) end)

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert SymphonyElixir.CiFix.origin("issue-progress") == nil
      assert_signal("ci fix return", %{to: "Code Review", kind: :ci_fix, head: "sha-same", move: true})
      assert log =~ "CI is green on issue_id=issue-progress issue_identifier=TP-337's PR head sha-same"
      assert log =~ "returning it to its CI Fix origin"
    end

    test "a repair on a Merging ticket returns to Merging, where the PR watcher turns auto-merge on again" do
      :ok = put_pending_ci_failure(approved: true)
      :ok = SymphonyElixir.CiFix.record_origin("default", "issue-progress", "Merging")
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      run_issue!("CI Fix", heads: ["sha-same"], max_turns: 6, repos: designed_repos())

      assert_received {:memory_tracker_state_update, "issue-progress", "Merging"}
      assert SymphonyElixir.CiFix.origin("issue-progress") == nil
    end

    test "a repair that pushed a new head returns to its origin with the approval re-bound to it" do
      :ok = put_pending_ci_failure(approved: true)
      :ok = SymphonyElixir.CiFix.record_origin("default", "issue-progress", "Code Review")
      # The approval the lane carries, bound to the head the red one replaced.
      :ok = put_verdict("default", "issue-progress", "code_review", "sha-same", "approve")
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-new", checks: @green_checks}})

      run_issue!("CI Fix", heads: ["sha-same", "sha-new"], max_turns: 6, repos: designed_repos())

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert SymphonyElixir.CiFix.origin("issue-progress") == nil

      # The approval moved with the ticket: the head it now covers is the repair's, not the red one's.
      assert [%{head_sha: "sha-new", outcome: "approve"} | _] =
               SymphonyElixir.Handoff.verdicts("default", "issue-progress", "code_review")

      assert_signal("ci fix return", %{to: "Code Review", kind: :ci_fix, head: "sha-new", move: true})
    end

    test "a repair that lost its origin goes to the post-PR state rather than guessing" do
      :ok = put_pending_ci_failure(approved: false)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      opts = [heads: ["sha-same"], max_turns: 6, repos: designed_repos(), auto_review: %{enabled: true}]
      log = capture_log(fn -> run_issue!("CI Fix", opts) end)

      # A designed repo's post-PR state is `Code Review`, where the head is judged afresh.
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert log =~ "No CI Fix origin recorded for issue_id=issue-progress issue_identifier=TP-337"
      assert log =~ "moving it to Code Review"
    end
  end

  describe "a merge-conflict run that pushes nothing" do
    # TP-658: the PR no longer conflicts by the time the run looks (the base branch moved on), so
    # there is nothing to resolve.
    @green_checks [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]

    test "on an approved PR goes back to Merging once it is mergeable and green" do
      :ok = put_pending_conflict(approved: true, head_sha: "sha-same")
      put_green_pr_head("MERGEABLE")

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 6) end)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Merging"}
      assert_received {:memory_tracker_comment, "issue-progress", "Symphony moved this issue back to Merging: " <> note}
      assert note =~ "the merge conflict run found nothing to resolve and pushed no commit, the PR no longer conflicts with the base branch"
      assert note =~ "CI on the PR head `sha-same` is green, so the approval still covers the PR and auto-merge turns back on"
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "merge conflict run for issue_id=issue-progress issue_identifier=TP-337 pushed nothing and CI on its PR head sha-same is green; moving back to Merging"
      refute log =~ "Parking"
    end

    test "goes to the post-PR state when the PR was not approved, or its head is not the one that conflicted" do
      for {approved, conflict_head, auto_review, post_pr_state} <- [
            {false, "sha-same", %{enabled: true}, "Code Review"},
            {false, "sha-same", nil, "Code Review"},
            {true, "sha-dirty", %{enabled: true}, "Code Review"}
          ] do
        :ok = put_pending_conflict(approved: approved, head_sha: conflict_head)
        put_green_pr_head("MERGEABLE")
        next_run()

        log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], handoff: "sha-same", max_turns: 6, auto_review: auto_review) end)

        assert turns() == 2
        assert_received {:memory_tracker_state_update, "issue-progress", ^post_pr_state}
        refute_received {:memory_tracker_state_update, "issue-progress", _state}
        refute_received {:memory_tracker_comment, "issue-progress", "Symphony moved" <> _note}

        assert log =~
                 "CI is green on issue_id=issue-progress issue_identifier=TP-337's PR head sha-same after a merge conflict run with no new commit; moving to #{post_pr_state}"
      end
    end

    test "is still parked while the PR conflicts or GitHub has not worked out whether it does, even with a CI failure pending too" do
      for {mergeable, ci_failure?} <- [{"CONFLICTING", false}, {"UNKNOWN", false}, {"CONFLICTING", true}] do
        :ok = put_pending_conflict(approved: true, head_sha: "sha-same")
        if ci_failure?, do: :ok = put_pending_ci_failure(approved: true)
        put_green_pr_head(mergeable)
        next_run()

        run_issue!("In Progress", heads: ["sha-same"], max_turns: 6)

        assert turns() == 2
        refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue where it is" <> _note}
        refute_received {:memory_tracker_state_update, "issue-progress", _state}
      end
    end

    defp put_green_pr_head(mergeable) do
      pr_head = %{commit_sha: "sha-same", mergeable: mergeable, checks: @green_checks}
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, pr_head})
    end
  end

  describe "a fix run that pushed a commit and then waits on CI" do
    # TP-662: a Rework run asked for a CI fix pushed it, then spent its turns waiting on CI. The CI
    # failure that started it stays pending until the run ends, so the rework never reads finished.
    @pending_checks [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]
    @green_checks [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    @red_checks [%{name: "make-all", status: "COMPLETED", conclusion: "FAILURE"}]

    test "in Rework moves to Code Review instead of Backlog while CI on its pushed head runs or once it is green" do
      for {checks, ci} <- [{@pending_checks, "running"}, {@green_checks, "green"}] do
        :ok = put_pending_ci_failure(approved: false)
        Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: checks}})
        next_run()

        log = capture_log(fn -> run_issue!("Rework", heads: ["sha-same", "sha-fixed"], handoff: "sha-fixed", max_turns: 6) end)

        # The turn that pushed, then two turns with no new commit.
        assert turns() == 3
        assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
        refute_received {:memory_tracker_state_update, "issue-progress", _state}
        refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked" <> _note}
        assert RunStore.get_rework_base("default", "issue-progress") == nil
        assert log =~ "CI is #{ci} on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
        refute log =~ "Parking"
      end
    end

    test "in Rework moves on when an earlier run of the rework pushed the head" do
      :ok = put_pending_ci_failure(approved: false)
      :ok = RunStore.put_rework_base("default", "issue-progress", "sha-same")
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @green_checks}})

      run_issue!("Rework", heads: ["sha-fixed"], handoff: "sha-fixed", max_turns: 6)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end

    test "outside Rework moves to Code Review through the pushed-head hand-off on the turn it pushed" do
      :ok = put_pending_ci_failure(approved: true)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}})

      run_issue!("In Progress", heads: ["sha-same", "sha-fixed"], handoff: "sha-fixed", max_turns: 6)

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end

    test "is still parked when its pushed head is red, or when it pushed nothing and CI is red" do
      for {state, heads} <- [{"Rework", ["sha-same", "sha-fixed"]}, {"Rework", ["sha-fixed"]}, {"In Progress", ["sha-fixed"]}] do
        :ok = put_pending_ci_failure(approved: false)
        Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @red_checks}})
        next_run()

        run_issue!(state, heads: heads, max_turns: 6)

        assert turns() == length(heads) + 1
        refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        refute_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      end
    end

    test "fails the run when its move to Code Review fails, keeping the rework base" do
      :ok = put_pending_ci_failure(approved: false)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @green_checks}})
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :linear_down})

      assert_raise RuntimeError, ~r/pushed_head_handoff_failed/, fn ->
        run_issue!("Rework", heads: ["sha-same", "sha-fixed"], max_turns: 6)
      end

      assert RunStore.get_rework_base("default", "issue-progress") == "sha-same"
    end
  end

  test "a turn that adds a commit or follows a state change resets the empty-turn count" do
    run_issue!("In Progress",
      heads: ["sha-1", "sha-1", "sha-2", "sha-2", "sha-2"],
      states: ["In Progress", "In Progress", "In Progress", "Todo", "Done"],
      pr_url: nil,
      max_turns: 5
    )

    assert turns() == 5
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "empty landing turns are left to the Merging CI wait" do
    green = [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: green}})

    run_issue!("Merging", heads: ["sha-same"], states: ["Merging", "Merging", "Done"], max_turns: 5)

    assert turns() == 3
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "a failed state move after a finished rework or a green pushed head, or an idle park's failed note, fails the run" do
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :linear_down})

    assert_raise RuntimeError, ~r/rework_handoff_failed/, fn ->
      run_issue!("Rework", heads: ["sha-old", "sha-rework"])
    end

    next_run()

    # The first comment is the workpad bootstrap's; the second is the park's note.
    Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [:ok, {:error, :linear_down}])

    assert_raise RuntimeError, ~r/idle_park_failed/, fn ->
      run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5)
    end

    next_run()
    :ok = put_pending_conflict()
    green = [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: green}})

    assert_raise RuntimeError, ~r/pushed_head_handoff_failed/, fn ->
      run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"])
    end
  end

  test "a run's agent session tells the orchestrator as each Symphony tool call starts and ends" do
    capture_log(fn ->
      assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework", recipient: self())
    end)

    assert_received {:progress_session_started, session_opts}
    on_tool_call = Keyword.fetch!(session_opts, :on_tool_call)
    call = %{name: "github_sync_base", started_at: DateTime.utc_now(), deadline: nil}
    call_id = make_ref()

    on_tool_call.({:started, call_id, call})
    on_tool_call.({:finished, call_id})

    assert_received {:mcp_tool_call, "issue-progress", {:started, ^call_id, ^call}}
    assert_received {:mcp_tool_call, "issue-progress", {:finished, ^call_id}}
  end

  test "a run without an orchestrator to tell starts its agent session without a tool call notice" do
    capture_log(fn ->
      assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework")
    end)

    assert_received {:progress_session_started, session_opts}
    assert Keyword.fetch!(session_opts, :on_tool_call) == nil
  end

  describe "a Linear rate limit on a run's own Linear call" do
    test "a finished rework waits it out on its post-PR move instead of failing the run" do
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [@rate_limited])

      log =
        capture_log(fn ->
          assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework", recipient: self(), runner_opts: linear_wait_opts())
        end)

      assert turns() == 1
      assert_received {:linear_wait_slept, 30_000}
      # The orchestrator hears of the wait, so its watchdogs hold off until it ends.
      assert_received {:linear_wait, "issue-progress", 30_000}
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert log =~ "Linear call failed while moving issue_id=issue-progress issue_identifier=TP-337 to Code Review after rework"
      refute log =~ "Agent run failed"
    end

    test "a workpad bootstrap tells the orchestrator it is waiting before the first turn" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [@rate_limited])

      capture_log(fn ->
        assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework", recipient: self(), runner_opts: linear_wait_opts())
      end)

      # The orchestrator hears of the wait before any agent event, so its first-turn stall
      # check holds off until it ends.
      {:messages, messages} = Process.info(self(), :messages)
      wait_at = Enum.find_index(messages, &match?({:linear_wait, "issue-progress", 30_000}, &1))
      assert is_integer(wait_at)
      assert wait_at < Enum.find_index(messages, &match?({:progress_turn, 1}, &1))
      assert_received {:linear_wait_slept, 30_000}
      assert_received {:memory_tracker_comment, "issue-progress", "## Symphony Workpad" <> _}
    end

    test "an idle park waits it out on its note instead of failing the run" do
      # The first comment is the workpad bootstrap's; the second is the park note.
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [:ok, @rate_limited])

      log =
        capture_log(fn ->
          assert :ok = run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, runner_opts: linear_wait_opts())
        end)

      assert turns() == 2
      assert_received {:linear_wait_slept, 30_000}
      assert_received {:memory_tracker_comment, "issue-progress", workpad}
      assert workpad =~ "## Symphony Workpad"
      assert_received {:memory_tracker_comment, "issue-progress", note}
      assert note =~ "Symphony parked this issue where it is"
      assert log =~ "Linear call failed while parking issue_id=issue-progress issue_identifier=TP-337 where it is"
      refute log =~ "Agent run failed for"
    end

    test "a note still rate-limited when the wait runs out ends the run as a Linear wait" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [:ok, @rate_limited])
      runner_opts = [linear_retry_opts: [max_wait_ms: 0]]

      capture_log(fn ->
        assert {:linear_unavailable, {:idle_park_failed, {:linear_rate_limited, 1_791_000_030_000}}} =
                 catch_exit(run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, runner_opts: runner_opts))
      end)
    end
  end

  defp linear_wait_opts do
    parent = self()
    [linear_retry_opts: [now_ms_fun: fn -> @now_ms end, sleep_fun: &send(parent, {:linear_wait_slept, &1})]]
  end

  test "the workspace HEAD and its unpushed commits read from a local git checkout only" do
    root = Path.join(System.tmp_dir!(), "symphony-workspace-head-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)

    try do
      System.cmd("git", ["-C", repo, "init", "-b", "main"])
      assert WorkspaceHead.read(repo, nil) == nil

      File.write!(Path.join(repo, "README.md"), "# test")
      System.cmd("git", ["-C", repo, "add", "README.md"])
      System.cmd("git", ["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "initial"])
      {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])

      assert WorkspaceHead.read(repo, nil) == String.trim(sha)
      assert WorkspaceHead.read(repo, "worker-1") == nil
      assert WorkspaceHead.read(Path.join(root, "missing"), nil) == nil

      # With no remote-tracking branch at all, nothing says the commit is unpushed.
      assert WorkspaceHead.unpushed_head(repo, nil) == nil

      System.cmd("git", ["-C", repo, "update-ref", "refs/remotes/origin/main", "HEAD"])
      assert WorkspaceHead.unpushed_head(repo, nil) == nil

      File.write!(Path.join(repo, "fix.txt"), "fix")
      System.cmd("git", ["-C", repo, "add", "fix.txt"])
      System.cmd("git", ["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "fix"])
      {fix_sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])

      assert WorkspaceHead.unpushed_head(repo, nil) == String.trim(fix_sha)
      assert WorkspaceHead.unpushed_head(repo, "worker-1") == nil
      assert WorkspaceHead.unpushed_head(nil, nil) == nil
      assert WorkspaceHead.unpushed_head(Path.join(root, "missing"), nil) == nil

      System.cmd("git", ["-C", repo, "update-ref", "refs/remotes/origin/auto/TP-337", "HEAD"])
      assert WorkspaceHead.unpushed_head(repo, nil) == nil
    after
      File.rm_rf(root)
    end
  end
end
