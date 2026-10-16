defmodule SymphonyElixir.PrWatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{PrWatch, PrWatchSupport, TicketPullRequest}
  alias SymphonyElixir.PrWatch.{Attempts, Repo}

  @repo_key "default"
  @now ~U[2026-10-16 12:00:00Z]

  defmodule FailingStore do
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :store_down}
    def list_ticket_states(_repo_key), do: {:error, :store_down}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", pr_review_mode: "polling")
    :ok
  end

  defp issue(id, state), do: %Issue{id: id, identifier: "TP-#{id}", title: "Ticket", state: state, repo_key: @repo_key}

  describe "dispatch_reason/2" do
    test "a Code Review or QA run starts only on the watcher's decision to dispatch" do
      settings = Config.settings!()

      for state <- ["Code Review", "QA"] do
        clear_run_store!()
        assert PrWatch.dispatch_reason(issue("1", state), settings) == "the PR watcher hasn't read its PR yet"

        PrWatchSupport.put_watch!(@repo_key, "1", decision: nil)
        assert PrWatch.dispatch_reason(issue("1", state), settings) == "the PR watcher hasn't decided on its PR yet"

        PrWatchSupport.put_watch!(@repo_key, "1", decision: %{rule: "R24", kind: :wait, reason: "Checks are running on PR #1's head"})
        assert PrWatch.dispatch_reason(issue("1", state), settings) == "the PR watcher (R24): Checks are running on PR #1's head"

        PrWatchSupport.put_watch!(@repo_key, "1", decision: :dispatch)
        assert PrWatch.dispatch_reason(issue("1", state), settings) == nil
      end

      # Other phases aren't gated by the watcher.
      for state <- ["In Progress", "Rework", "CI Fix", "Todo", nil] do
        assert PrWatch.dispatch_reason(issue("1", state), settings) == nil
      end
    end

    test "a Merging landing agent runs only when the watcher hands the PR to one, with auto-merge on" do
      settings = Config.settings!()
      merging = issue("2", "Merging")

      # No PR yet: the landing agent runs, as before the watcher.
      assert PrWatch.dispatch_reason(merging, settings) == nil

      PrWatchSupport.put_watch!(@repo_key, "2",
        phase: :merging,
        facts: %{pr: :missing},
        decision: %{rule: "R6", kind: :decision, reason: "no PR"}
      )

      assert PrWatch.dispatch_reason(merging, settings) == nil

      :ok = TicketPullRequest.record_created(@repo_key, "3", "https://github.com/acme/app/pull/3", "auto/TP-3")
      assert PrWatch.dispatch_reason(issue("3", "Merging"), settings) == "the PR watcher hasn't read its PR yet"

      PrWatchSupport.put_watch!(@repo_key, "2", phase: :merging, decision: %{rule: "R32", kind: :wait, reason: "auto-merge lands it"})
      assert PrWatch.dispatch_reason(merging, settings) == "the PR watcher (R32): auto-merge lands it"

      PrWatchSupport.put_watch!(@repo_key, "2", phase: :merging, decision: %{rule: "R31", kind: :land_agent, reason: "blocked"})
      assert PrWatch.dispatch_reason(merging, settings) == nil

      # With auto-merge off, the landing agent always lands it.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        pr_review_mode: "polling",
        pr_review_auto_merge: false
      )

      PrWatchSupport.put_watch!(@repo_key, "2", phase: :merging, decision: %{rule: "R32", kind: :wait, reason: "auto-merge lands it"})
      assert PrWatch.dispatch_reason(merging, Config.settings!()) == nil
    end
  end

  test "pending_ci_failure/2, pending_pr_conflict/2 and rerun_pending?/4 read the watcher's record" do
    failure = %{commit_sha: "head-1", failed_checks: [%{name: "specs"}], log_excerpt: "boom", approved: false}
    conflict = %{head_sha: "head-1", base_sha: "base-1", approved: true}
    attempts = %{Attempts.new() | reruns: %{"head-1" => ["specs"]}}
    PrWatchSupport.put_watch!(@repo_key, "4", ci_failure: failure, pr_conflict: conflict, attempts: attempts)

    assert PrWatch.pending_ci_failure("4") == failure
    assert PrWatch.pending_pr_conflict("4", repo_key: @repo_key) == conflict
    assert PrWatch.rerun_pending?("4", "head-1", ["lint"])
    refute PrWatch.rerun_pending?("4", "head-1", ["lint", "specs"])

    assert %{fix: %{ci_failure: ^failure}} = PrWatch.watch("4")
    assert PrWatch.pending_ci_failure("unknown") == nil
    assert PrWatch.pending_pr_conflict(nil) == nil
    refute PrWatch.rerun_pending?("unknown", "head-1", [])
    assert PrWatch.watch("4", run_store: FailingStore) == nil
  end

  test "open_pr_overlap/2 names the other open PRs that share files, and every open PR before the ticket has one" do
    landing = fn files, state, waits_for ->
      %{
        files: files,
        head_sha: "h",
        state: state,
        state_since: @now,
        progress_at: @now,
        waits_for: waits_for,
        waits_since: nil
      }
    end

    wait = %{issue_id: "11", issue_identifier: "TP-11", pr_url: "https://github.com/acme/app/pull/11", state: "QA", shared_files: 1, files: ["lib/b.ex"]}
    PrWatchSupport.put_watch!(@repo_key, "10", identifier: "TP-10", pr_url: "https://github.com/acme/app/pull/10", landing: landing.(["lib/a.ex", "lib/b.ex"], "Rework", wait))
    PrWatchSupport.put_watch!(@repo_key, "11", identifier: "TP-11", pr_url: "https://github.com/acme/app/pull/11", landing: landing.(["lib/b.ex"], "QA", nil))
    PrWatchSupport.put_watch!(@repo_key, "12", identifier: "TP-12", pr_url: "https://github.com/acme/app/pull/12", landing: landing.(["lib/c.ex"], "QA", nil))
    PrWatchSupport.put_watch!(@repo_key, "13", identifier: "TP-13", landing: nil)

    assert %{
             waits_for: ^wait,
             shared: [%{issue_identifier: "TP-11", state: "QA", files: ["lib/b.ex"]}],
             open: []
           } = PrWatch.open_pr_overlap("10")

    # A PR that shares no file has no overlap; a ticket without a PR sees every open one.
    assert PrWatch.open_pr_overlap("12") == nil
    assert %{waits_for: nil, shared: [], open: open} = PrWatch.open_pr_overlap("no-pr-yet")
    assert Enum.map(open, & &1.issue_identifier) |> Enum.sort() == ["TP-10", "TP-11", "TP-12"]

    clear_run_store!()
    PrWatchSupport.put_watch!(@repo_key, "10", landing: landing.(["lib/a.ex"], "QA", nil))
    assert PrWatch.open_pr_overlap("10") == nil
    assert PrWatch.open_pr_overlap("10", run_store: FailingStore) == nil
  end

  test "landing_waits/1 lists the PRs waiting for another, with the watcher's reason; auto_merge_statuses/1 the Merging PRs" do
    wait = %{issue_id: "21", issue_identifier: "TP-21", pr_url: "https://github.com/acme/app/pull/21", state: "QA", shared_files: 2, files: ["a.ex", "b.ex"]}

    landing = %{
      files: ["a.ex", "b.ex"],
      head_sha: "h",
      state: "Merging",
      state_since: @now,
      progress_at: @now,
      waits_for: wait,
      waits_since: @now
    }

    decision = %{rule: "R14a", kind: :wait_for_competitors, reason: "Lands after TP-21: they change the same files (a.ex, b.ex)"}

    PrWatchSupport.put_watch!(@repo_key, "20",
      identifier: "TP-20",
      phase: :merging,
      landing: landing,
      decision: decision,
      facts: %{auto_merge: :armed}
    )

    PrWatchSupport.put_watch!(@repo_key, "22",
      identifier: "TP-22",
      phase: :merging,
      landing: landing,
      decision: %{rule: "R29", kind: :merge_now, reason: "green"}
    )

    PrWatchSupport.put_watch!(@repo_key, "23", identifier: "TP-23", phase: :qa, landing: %{landing | waits_for: nil})

    assert [
             %{
               issue_identifier: "TP-20",
               state: "Merging",
               waits_for: %{issue_identifier: "TP-21", state: "QA"},
               shared_files: 2,
               reason: "Lands after TP-21" <> _,
               since: @now
             },
             %{issue_identifier: "TP-22", reason: "waits for TP-21 to land (shares 2 files)"}
           ] = PrWatch.landing_waits()

    assert [
             %{issue_identifier: "TP-20", state: "armed", status: "Lands after TP-21" <> _, pr_url: "https://github.com/acme/app/pull/1"},
             %{issue_identifier: "TP-22", state: "off", status: "green"}
           ] = PrWatch.auto_merge_statuses(repo_key: @repo_key)

    assert PrWatch.landing_waits(run_store: FailingStore) == []
  end

  test "poll_now/0 asks every running watcher to tick, and is a no-op without one" do
    assert PrWatch.poll_now() == :ok

    {:ok, _owner} = Registry.register(SymphonyElixir.Repo.Registry, {:pr_watch, "poll-now-test"}, nil)
    assert PrWatch.poll_now() == :ok
    assert_receive :tick_now

    assert Repo.poll_now(:no_such_watcher) == :ok
  end
end
