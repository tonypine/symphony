defmodule SymphonyElixir.RunStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.RunStore.RunIndex
  alias SymphonyElixir.TicketState

  @repo_key "repo-a"
  @other_repo_key "repo-b"

  setup do
    :ok = RunStore.clear()
  end

  test "rejects partitioned write shims without an explicit repo_key" do
    assert {:error, :missing_repo_key} = RunStore.put_run(%{run_id: "run-missing-repo"})
    assert {:error, :missing_repo_key} = RunStore.update_run("run-missing-repo", %{status: "success"})
    assert {:error, :missing_repo_key} = RunStore.interrupt_running_runs("orchestrator restarted")

    assert {:error, :missing_repo_key} = RunStore.put_retry(%{issue_id: "issue-missing-repo"})
    assert {:error, :missing_repo_key} = RunStore.delete_retry("issue-missing-repo")

    assert {:error, :missing_repo_key} = RunStore.put_pr_review(%{issue_id: "issue-missing-repo"})
    assert {:error, :missing_repo_key} = RunStore.update_pr_review("issue-missing-repo", %{status: "complete"})
    assert {:error, :missing_repo_key} = RunStore.delete_pr_review("issue-missing-repo")

    assert {:error, :missing_repo_key} = RunStore.put_ci_check(%{issue_id: "issue-missing-repo"})
    assert {:error, :missing_repo_key} = RunStore.update_ci_check("issue-missing-repo", %{status: "green"})
    assert {:error, :missing_repo_key} = RunStore.delete_ci_check("issue-missing-repo")

    assert {:error, :missing_repo_key} =
             RunStore.put_verification_allocation(%{run_id: "run-missing-repo", port: 4010})

    assert {:error, :missing_repo_key} =
             RunStore.update_verification_allocation("run-missing-repo", %{status: "released"})

    assert {:error, :missing_repo_key} = RunStore.delete_verification_allocation("run-missing-repo")
    assert {:error, :missing_repo_key} = RunStore.put_eval_log(%{eval_id: "eval-missing-repo"})

    assert {:error, :missing_repo_key} =
             RunStore.put_learnings([%{id: "learning-missing-repo", repo: "github.com/example/repo", created_at: DateTime.utc_now()}])
  end

  test "configures Mnesia core dumps under the run store directory" do
    expected_core_dir = Path.join(Path.expand(RunStore.store_dir()), "core_dumps")

    assert File.dir?(expected_core_dir)
    assert :mnesia.system_info(:core_dir) |> to_string() |> Path.expand() == expected_core_dir
  end

  test "fails startup with an explicit schema mismatch for legacy Mnesia tables" do
    original_run_store_dir = Application.fetch_env!(:symphony_elixir, :run_store_dir)
    legacy_dir = Path.join(System.tmp_dir!(), "symphony-legacy-run-store-#{System.unique_integer([:positive])}")
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      :ok = Application.stop(:symphony_elixir)
      stop_run_store_for_test()
      stop_mnesia_for_test()
      create_legacy_run_store_dir!(legacy_dir)

      log =
        capture_log(fn ->
          assert {:error, {:run_store_schema_mismatch, :symphony_run_store_runs, details}} =
                   RunStore.start_link(dir: legacy_dir)

          assert details.actual_attributes == [:run_id, :record]
          assert details.expected_attributes == [:key, :repo_key, :run_id, :record]
          assert details.run_store_dir == Path.expand(legacy_dir)
          assert details.runbook =~ "wipe"
        end)

      assert log =~ "RunStore Mnesia schema mismatch"
      assert log =~ "wipe"

      receive do
        {:EXIT, _pid, {:run_store_schema_mismatch, :symphony_run_store_runs, _details}} -> :ok
      after
        0 -> :ok
      end
    after
      stop_run_store_for_test()
      stop_mnesia_for_test()
      File.rm_rf(legacy_dir)
      Application.put_env(:symphony_elixir, :run_store_dir, original_run_store_dir)

      # This test swaps Mnesia to a legacy directory. Restore the application
      # before the next module setup calls RunStore.clear/0, otherwise setup can
      # hit the stopped or wrong Mnesia log and fail with :no_such_log.
      ensure_symphony_started!()
      Process.flag(:trap_exit, trap_exit?)
    end
  end

  test "persists run records, retry queue entries, and codex totals" do
    started_at = DateTime.utc_now()
    due_at = DateTime.add(started_at, 60_000, :millisecond)

    assert :ok =
             RunStore.put_run(%{
               repo_key: @repo_key,
               run_id: "run-1",
               issue_id: "issue-1",
               issue_identifier: "ACME-1",
               title: "Persist me",
               state: "In Progress",
               status: "running",
               attempt: 2,
               started_at: started_at,
               ended_at: nil,
               error: nil,
               worker_host: "worker-a",
               workspace_path: "/tmp/workspaces/ACME-1",
               session_id: "thread-1-turn-1",
               transcript_path: "/tmp/transcript.jsonl",
               tokens: %{input_tokens: 10, output_tokens: 4, total_tokens: 14},
               runtime_seconds: 0
             })

    assert :ok =
             RunStore.update_run(@repo_key, "run-1", %{
               status: "success",
               ended_at: DateTime.add(started_at, 10, :second),
               runtime_seconds: 10
             })

    assert [
             %{
               run_id: "run-1",
               repo_key: @repo_key,
               issue_id: "issue-1",
               status: "success",
               attempt: 2,
               session_id: "thread-1-turn-1",
               transcript_path: "/tmp/transcript.jsonl",
               runtime_seconds: 10
             }
           ] = RunStore.list_runs(@repo_key)

    assert :ok =
             RunStore.put_retry(%{
               repo_key: @repo_key,
               issue_id: "issue-1",
               issue_identifier: "ACME-1",
               identifier: "ACME-1",
               attempt: 3,
               due_at: due_at,
               error: "agent exited: :boom",
               worker_host: "worker-a",
               workspace_path: "/tmp/workspaces/ACME-1"
             })

    assert [
             %{
               issue_id: "issue-1",
               repo_key: @repo_key,
               identifier: "ACME-1",
               attempt: 3,
               due_at: ^due_at,
               error: "agent exited: :boom"
             }
           ] = RunStore.list_retries(@repo_key)

    assert :ok = RunStore.delete_retry(@repo_key, "issue-1")
    assert [] = RunStore.list_retries(@repo_key)

    assert :ok =
             RunStore.put_pr_review(%{
               repo_key: @repo_key,
               issue_id: "issue-1",
               issue_identifier: "ACME-1",
               pr_url: "https://github.com/example/repo/pull/1",
               workspace_path: "/tmp/workspaces/ACME-1",
               status: "watching",
               updated_at: started_at
             })

    assert :ok =
             RunStore.update_pr_review(@repo_key, "issue-1", %{
               status: "cooling_down",
               last_activity_at: due_at,
               last_addressed_comment_id: "comment-1"
             })

    assert [
             %{
               issue_id: "issue-1",
               repo_key: @repo_key,
               pr_url: "https://github.com/example/repo/pull/1",
               workspace_path: "/tmp/workspaces/ACME-1",
               status: "cooling_down",
               last_activity_at: ^due_at,
               last_addressed_comment_id: "comment-1"
             }
           ] = RunStore.list_pr_reviews(@repo_key)

    assert :ok = RunStore.delete_pr_review(@repo_key, "issue-1")
    assert [] = RunStore.list_pr_reviews(@repo_key)

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: "issue-1",
               issue_identifier: "ACME-1",
               pr_url: "https://github.com/example/repo/pull/1",
               commit_sha: "abc123",
               status: "dispatch_requested",
               ci_retry_count: 1,
               updated_at: started_at
             })

    assert :ok =
             RunStore.update_ci_check(@repo_key, "issue-1", %{
               status: "green",
               ci_retry_count: 0,
               updated_at: due_at
             })

    assert [
             %{
               issue_id: "issue-1",
               repo_key: @repo_key,
               pr_url: "https://github.com/example/repo/pull/1",
               commit_sha: "abc123",
               status: "green",
               ci_retry_count: 0,
               updated_at: ^due_at
             }
           ] = RunStore.list_ci_checks(@repo_key)

    assert :ok = RunStore.delete_ci_check(@repo_key, "issue-1")
    assert [] = RunStore.list_ci_checks(@repo_key)

    assert :ok =
             RunStore.put_verification_allocation(%{
               repo_key: @repo_key,
               run_id: "run-1",
               issue_id: "issue-1",
               issue_identifier: "ACME-1",
               port: 4010,
               status: "allocated",
               allocated_at: started_at,
               updated_at: started_at
             })

    assert :ok =
             RunStore.update_verification_allocation(@repo_key, "run-1", %{
               status: "dev_server_started",
               dev_server_os_pid: 12_345,
               dev_server_pgid: 12_345,
               updated_at: due_at
             })

    assert [
             %{
               run_id: "run-1",
               repo_key: @repo_key,
               issue_id: "issue-1",
               issue_identifier: "ACME-1",
               port: 4010,
               status: "dev_server_started",
               dev_server_os_pid: 12_345,
               updated_at: ^due_at
             }
           ] = RunStore.list_verification_allocations(@repo_key)

    assert :ok = RunStore.delete_verification_allocation(@repo_key, "run-1")
    assert [] = RunStore.list_verification_allocations(@repo_key)

    totals = %{input_tokens: 10, output_tokens: 4, total_tokens: 14, seconds_running: 10}
    assert :ok = RunStore.put_codex_totals(totals)
    assert totals == RunStore.get_codex_totals()

    quality_gate_cache = %{
      "issue-1" => %{
        updated_at: started_at,
        comment_signature: "comments",
        score: 5,
        reason: "needs answer",
        passed?: false,
        awaiting_clarification?: true,
        questions: ["What should pass?", "Which module?", "What is out of scope?"],
        rounds_asked: 1,
        comment_posted?: true,
        identifier: "ACME-1",
        title: "Persist me",
        state: "Todo",
        url: "https://example.org/ACME-1",
        scored_at: started_at
      }
    }

    assert :ok = RunStore.put_quality_gate_cache(quality_gate_cache)
    assert quality_gate_cache == RunStore.get_quality_gate_cache()
  end

  test "persists dispatch pause state across run store restart" do
    assert %{paused: false, reason: nil, paused_at: nil} = RunStore.get_paused()

    assert :ok = RunStore.set_paused(true, "overnight deploy")

    assert %{paused: true, reason: "overnight deploy", paused_at: %DateTime{} = paused_at} =
             RunStore.get_paused()

    restart_run_store()

    assert %{paused: true, reason: "overnight deploy", paused_at: ^paused_at} =
             RunStore.get_paused()

    assert :ok = RunStore.set_paused(true, "ignored because already paused")

    assert %{paused: true, reason: "overnight deploy", paused_at: ^paused_at} =
             RunStore.get_paused()

    assert :ok = RunStore.set_paused(false, nil)
    assert %{paused: false, reason: nil, paused_at: nil} = RunStore.get_paused()

    restart_run_store()
  end

  test "persists Symphony's own state moves across run store restart" do
    moved_at = ~U[2026-10-04 00:23:15Z]

    assert RunStore.get_own_state_move("issue-own") == nil
    assert :ok = RunStore.put_own_state_move("issue-own", moved_at)
    assert :ok = RunStore.put_own_state_move("issue-own", DateTime.add(moved_at, 60))

    restart_run_store()

    assert RunStore.get_own_state_move("issue-own") == DateTime.add(moved_at, 60)
    assert RunStore.get_own_state_move("issue-other") == nil
    assert {:error, :invalid_own_state_move} = RunStore.put_own_state_move("issue-own", "2026-10-04")
    assert {:error, :invalid_own_state_move} = RunStore.put_own_state_move(nil, moved_at)
    assert {:error, :invalid_issue_id} = RunStore.get_own_state_move(nil)

    restart_run_store()
  end

  test "persists the issues a merge moved to the waiting state across run store restart" do
    refute RunStore.merged_wait?("issue-merged")
    assert :ok = RunStore.put_merged_wait("issue-merged")
    assert :ok = RunStore.put_merged_wait("issue-merged")

    restart_run_store()

    assert RunStore.merged_wait?("issue-merged")
    refute RunStore.merged_wait?("issue-other")
    assert :ok = RunStore.delete_merged_wait("issue-merged")
    refute RunStore.merged_wait?("issue-merged")
    assert {:error, :invalid_issue_id} = RunStore.put_merged_wait(nil)
    assert {:error, :invalid_issue_id} = RunStore.merged_wait?(nil)
    assert {:error, :invalid_issue_id} = RunStore.delete_merged_wait(nil)

    restart_run_store()
  end

  test "persists per-ticket state records across run store restart" do
    at = ~U[2026-10-04 00:23:15Z]
    record = TicketState.new(@repo_key, "issue-1", %{issue_identifier: "ACME-1", phase: "In Progress"})

    assert RunStore.get_ticket_state(@repo_key, "issue-1") == nil
    assert :ok = RunStore.put_ticket_state(record)

    assert %{phase: "In Progress", issue_identifier: "ACME-1"} = RunStore.get_ticket_state(@repo_key, "issue-1")

    assert :ok = RunStore.update_ticket_state(@repo_key, "issue-1", %{phase: "Merging", updated_at: at})
    assert %{phase: "Merging", updated_at: ^at} = RunStore.get_ticket_state(@repo_key, "issue-1")

    assert {:error, :ticket_state_not_found} = RunStore.update_ticket_state(@repo_key, "issue-missing", %{phase: "Todo"})

    assert :ok = RunStore.record_ticket_signal(@repo_key, "issue-1", "handoff", %{to: "Code Review"})
    assert :ok = RunStore.record_ticket_signal(@repo_key, "issue-2", "blocked", %{reason: "tooling"})
    assert :ok = RunStore.record_ticket_verdict(@repo_key, "issue-1", "qa", "abc123", "pass", %{model: "claude-opus"})

    assert [%{name: "handoff", details: %{to: "Code Review"}}] = RunStore.get_ticket_state(@repo_key, "issue-1").signals
    assert [%{name: "blocked"}] = RunStore.get_ticket_state(@repo_key, "issue-2").signals
    assert [%{kind: "qa", head_sha: "abc123", outcome: "pass"}] = RunStore.get_ticket_state(@repo_key, "issue-1").verdicts

    assert :ok = RunStore.put_ticket_state(TicketState.new(@other_repo_key, "issue-1", %{phase: "Done"}))

    restart_run_store()

    assert %{phase: "Merging"} = RunStore.get_ticket_state(@repo_key, "issue-1")
    assert [%{name: "handoff"}] = RunStore.get_ticket_state(@repo_key, "issue-1").signals

    assert [%{kind: "qa", head_sha: "abc123", outcome: "pass", details: %{model: "claude-opus"}}] =
             RunStore.get_ticket_state(@repo_key, "issue-1").verdicts

    assert %{phase: "Done"} = RunStore.get_ticket_state(@other_repo_key, "issue-1")

    assert Enum.sort(Enum.map(RunStore.list_ticket_states(@repo_key), & &1.issue_id)) == ["issue-1", "issue-2"]
    assert Enum.sort(Enum.map(RunStore.list_all_ticket_states(), & &1.issue_id)) == ["issue-1", "issue-1", "issue-2"]

    assert :ok = RunStore.delete_ticket_state(@repo_key, "issue-1")
    assert RunStore.get_ticket_state(@repo_key, "issue-1") == nil

    restart_run_store()
  end

  test "writes the watcher's fact record on a ticket's record, creating it, across a restart" do
    facts = Facts.new(phase: :code_review, ci: :green)
    watch = %{facts: facts, pr_url: "https://github.com/acme/app/pull/1", head_sha: "abc"}

    # A ticket moved by hand has no record yet: one is created, with its identifier.
    assert :ok = RunStore.put_ticket_pr_watch(@repo_key, "issue-1", "ACME-1", watch)

    assert %{issue_identifier: "ACME-1", pr_watch: %{facts: ^facts, head_sha: "abc", source: :poll}} =
             RunStore.get_ticket_state(@repo_key, "issue-1")

    # An existing record keeps what else it holds and its identifier.
    assert :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-2", %{issue_identifier: "ACME-2", phase: "QA"}))
    assert :ok = RunStore.put_ticket_pr_watch(@repo_key, "issue-2", "OTHER", watch)
    assert %{issue_identifier: "ACME-2", phase: "QA", pr_watch: %{facts: ^facts}} = RunStore.get_ticket_state(@repo_key, "issue-2")

    restart_run_store()

    assert %{pr_watch: %{facts: ^facts, pr_url: "https://github.com/acme/app/pull/1"}} = RunStore.get_ticket_state(@repo_key, "issue-1")

    assert :ok = RunStore.put_ticket_pr_watch(@repo_key, "issue-1", "ACME-1", nil)
    assert %{issue_identifier: "ACME-1", pr_watch: nil} = RunStore.get_ticket_state(@repo_key, "issue-1")

    assert {:error, :invalid_issue_id} = RunStore.put_ticket_pr_watch(@repo_key, nil, nil, watch)
    assert {:error, :invalid_repo_key} = RunStore.put_ticket_pr_watch(nil, "issue-1", nil, watch)
  end

  test "persists ticket pull request records across run store restart" do
    at = ~U[2026-10-14 21:00:00Z]
    url = "https://github.com/acme/repo/pull/1"
    record = %{repo_key: @repo_key, issue_id: "issue-1", pr_url: url, branch: "auto/ACME-1", state: "open", updated_at: at}

    assert RunStore.get_ticket_pull_request(@repo_key, "issue-1") == nil
    assert :ok = RunStore.put_ticket_pull_request(record)
    assert :ok = RunStore.put_ticket_pull_request(%{record | repo_key: @other_repo_key})

    restart_run_store()

    assert %{pr_url: ^url, state: "open", branch: "auto/ACME-1"} = RunStore.get_ticket_pull_request(@repo_key, "issue-1")
    assert [%{issue_id: "issue-1", repo_key: @repo_key}] = RunStore.list_ticket_pull_requests(@repo_key)

    later = DateTime.add(at, 60, :second)
    assert {:ok, 1} = RunStore.finish_ticket_pull_request(@repo_key, url, "merged", later)
    assert {:ok, 0} = RunStore.finish_ticket_pull_request(@repo_key, url, "merged", later)
    assert %{state: "merged", updated_at: ^later} = RunStore.get_ticket_pull_request(@repo_key, "issue-1")
    assert %{state: "open"} = RunStore.get_ticket_pull_request(@other_repo_key, "issue-1")

    assert {:error, :invalid_ticket_pull_request_record} = RunStore.put_ticket_pull_request(%{issue_id: "issue-1"})
    assert {:error, :invalid_issue_id} = RunStore.get_ticket_pull_request(@repo_key, nil)
    assert {:error, :invalid_repo_key} = RunStore.list_ticket_pull_requests(nil)

    assert {:error, :invalid_ticket_pull_request_record} =
             RunStore.finish_ticket_pull_request(@repo_key, nil, "merged", later)
  end

  test "inserts a ticket pull request record only when the ticket has none" do
    first = %{repo_key: @repo_key, issue_id: "issue-1", pr_url: "https://github.com/acme/repo/pull/1", state: "open", source: "backfill"}
    second = %{first | pr_url: "https://github.com/acme/repo/pull/2"}

    assert {:ok, :inserted} = RunStore.insert_ticket_pull_request(first)
    assert {:ok, :exists} = RunStore.insert_ticket_pull_request(second)
    assert %{pr_url: "https://github.com/acme/repo/pull/1", repo_key: @repo_key} = RunStore.get_ticket_pull_request(@repo_key, "issue-1")

    assert {:error, :invalid_ticket_pull_request_record} = RunStore.insert_ticket_pull_request(%{issue_id: "issue-1"})
    assert {:error, :invalid_repo_key} = RunStore.insert_ticket_pull_request(%{first | repo_key: nil})
  end

  test "records CI state per head, newest write wins, and refuses bad arguments" do
    at = ~U[2026-10-04 00:23:15Z]
    later = DateTime.add(at, 60, :second)

    assert {:ok, :changed} = RunStore.record_ci_state(@repo_key, "issue-1", "abc", "running", at)
    assert %{ci_states: [%{head_sha: "abc", status: "running"}]} = RunStore.get_ticket_state(@repo_key, "issue-1")

    assert {:ok, :unchanged} = RunStore.record_ci_state(@repo_key, "issue-1", "abc", "running", later)
    assert {:ok, :changed} = RunStore.record_ci_state(@repo_key, "issue-1", "abc", "green", later)
    assert {:ok, :stale} = RunStore.record_ci_state(@repo_key, "issue-1", "abc", "red", at)
    assert %{ci_states: [%{head_sha: "abc", status: "green"}]} = RunStore.get_ticket_state(@repo_key, "issue-1")

    restart_run_store()
    assert %{ci_states: [%{head_sha: "abc", status: "green"}]} = RunStore.get_ticket_state(@repo_key, "issue-1")

    assert {:ok, :changed} = RunStore.record_ci_state(@other_repo_key, "issue-1", nil, "red", at)
    assert %{ci_states: [%{head_sha: nil, status: "red"}]} = RunStore.get_ticket_state(@other_repo_key, "issue-1")

    assert {:error, :invalid_ci_state} = RunStore.record_ci_state(@repo_key, nil, "abc", "running", at)
    assert {:error, :invalid_ci_state} = RunStore.record_ci_state(@repo_key, "issue-1", "abc", nil, at)
    assert {:error, :invalid_ci_state} = RunStore.record_ci_state(@repo_key, "issue-1", "abc", "running", nil)
    assert {:error, :invalid_repo_key} = RunStore.record_ci_state(nil, "issue-1", "abc", "running", at)
  end

  test "rejects ticket state writes without a repo_key or issue_id" do
    assert {:error, :missing_repo_key} = RunStore.put_ticket_state(%{issue_id: "issue-1"})
    assert {:error, :invalid_ticket_state_record} = RunStore.put_ticket_state(%{})
    assert {:error, :missing_repo_key} = RunStore.update_ticket_state("issue-1", %{phase: "Todo"})
    assert {:error, :invalid_ticket_state_record} = RunStore.update_ticket_state(@repo_key, nil, %{phase: "Todo"})
    assert {:error, :missing_repo_key} = RunStore.delete_ticket_state("issue-1")
    assert {:error, :invalid_issue_id} = RunStore.delete_ticket_state(@repo_key, nil)
    assert {:error, :invalid_issue_id} = RunStore.get_ticket_state(@repo_key, nil)
    assert {:error, :invalid_issue_id} = RunStore.record_ticket_signal(@repo_key, nil, "handoff", %{})
    assert {:error, :invalid_issue_id} = RunStore.record_ticket_verdict(@repo_key, nil, "qa", nil, "pass")
  end

  test "sets and clears a ticket hold, creating the record when the issue has none" do
    assert RunStore.get_ticket_state(@repo_key, "issue-1") == nil

    assert :ok = RunStore.set_ticket_hold(@repo_key, "issue-1", :blocked, %{reason: "waiting on TP-1"})

    assert %{holds: [%{kind: :blocked, reason: "waiting on TP-1", waits_on: nil}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")

    assert :ok = RunStore.set_ticket_hold(@repo_key, "issue-1", :blocked, %{reason: "waiting on TP-2"})
    assert %{holds: [%{kind: :blocked, reason: "waiting on TP-2"}]} = RunStore.get_ticket_state(@repo_key, "issue-1")

    restart_run_store()
    assert %{holds: [%{kind: :blocked, reason: "waiting on TP-2"}]} = RunStore.get_ticket_state(@repo_key, "issue-1")

    assert :ok = RunStore.clear_ticket_hold(@repo_key, "issue-1", :blocked)
    assert %{holds: []} = RunStore.get_ticket_state(@repo_key, "issue-1")

    # An issue with no record has no hold to clear, and clearing one does not create the record.
    assert :ok = RunStore.clear_ticket_hold(@repo_key, "issue-missing", :blocked)
    assert RunStore.get_ticket_state(@repo_key, "issue-missing") == nil
  end

  test "rejects ticket hold writes without a repo_key or issue_id" do
    assert {:error, :invalid_issue_id} = RunStore.set_ticket_hold(@repo_key, nil, :blocked, %{})
    assert {:error, :invalid_issue_id} = RunStore.clear_ticket_hold(@repo_key, nil, :blocked)
    assert {:error, :invalid_repo_key} = RunStore.set_ticket_hold(nil, "issue-1", :blocked, %{})
    assert {:error, :invalid_repo_key} = RunStore.clear_ticket_hold(nil, "issue-1", :blocked)
  end

  test "marks a failed projection on a ticket's record and clears that mark only, across a restart" do
    :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1"))

    assert :ok = RunStore.mark_ticket_projection(@repo_key, "issue-1", :phase, :linear_down)
    assert :ok = RunStore.mark_ticket_projection(@repo_key, "issue-1", {:hold_label, :blocked}, :linear_down)
    restart_run_store()

    assert %{pending_projection: [%{type: :hold_label} = label_mark, %{type: :phase} = projected]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")

    # A newer mark of the projection, written after the reconciler read the older one, stays.
    assert :ok = RunStore.mark_ticket_projection(@repo_key, "issue-1", :phase, :still_down)
    assert :ok = RunStore.clear_ticket_projection(@repo_key, "issue-1", projected)
    assert [%{type: :phase, error: ":still_down"}, ^label_mark] = RunStore.get_ticket_state(@repo_key, "issue-1").pending_projection

    # An issue with no record has nothing to project: neither write creates the record.
    assert :ok = RunStore.mark_ticket_projection(@repo_key, "issue-missing", :phase, :linear_down)
    assert :ok = RunStore.clear_ticket_projection(@repo_key, "issue-missing", projected)
    assert RunStore.get_ticket_state(@repo_key, "issue-missing") == nil

    assert {:error, :invalid_repo_key} = RunStore.mark_ticket_projection(nil, "issue-1", :phase, :linear_down)
    assert {:error, :invalid_repo_key} = RunStore.clear_ticket_projection(nil, "issue-1", projected)
  end

  test "records a ticket's dispatched runs and how they ended, and a lifted hold ends the count" do
    assert :ok = RunStore.record_ticket_dispatch(@repo_key, "issue-1", %{kind: :rework, run_id: "run-1", state: "Rework", head: "a"})
    assert :ok = RunStore.record_ticket_dispatch_outcome(@repo_key, "issue-1", "run-1", %{exit: "ended normally", head: "a"})

    assert %{dispatches: [%{kind: "rework", run_id: "run-1", state: "Rework", head: "a", outcome: %{exit: "ended normally", head: "a"}}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")

    restart_run_store()
    assert %{dispatches: [%{run_id: "run-1"}]} = RunStore.get_ticket_state(@repo_key, "issue-1")

    assert :ok = RunStore.set_ticket_hold(@repo_key, "issue-1", :blocked, %{reason: "dispatch_loop"})
    assert :ok = RunStore.clear_ticket_hold(@repo_key, "issue-1", :blocked)
    assert %{dispatches: []} = RunStore.get_ticket_state(@repo_key, "issue-1")

    # An issue with no record lists no run, and recording an end does not create the record.
    assert :ok = RunStore.record_ticket_dispatch_outcome(@repo_key, "issue-missing", "run-1", %{exit: "ended normally"})
    assert RunStore.get_ticket_state(@repo_key, "issue-missing") == nil

    assert {:error, :invalid_issue_id} = RunStore.record_ticket_dispatch(@repo_key, nil, %{})
    assert {:error, :invalid_issue_id} = RunStore.record_ticket_dispatch_outcome(@repo_key, nil, "run-1", %{})
    assert {:error, :invalid_repo_key} = RunStore.record_ticket_dispatch(nil, "issue-1", %{})
    assert {:error, :invalid_repo_key} = RunStore.record_ticket_dispatch_outcome(nil, "issue-1", "run-1", %{})
  end

  test "claims a path-unlock grant for one run only, across a restart" do
    assert {:ok, ["grant-1"]} = RunStore.claim_path_unlocks(@repo_key, "issue-1", ["grant-1"], "run-1")
    assert %{path_unlocks: [%{id: "grant-1", run_id: "run-1"}]} = RunStore.get_ticket_state(@repo_key, "issue-1")

    restart_run_store()
    assert {:ok, []} = RunStore.claim_path_unlocks(@repo_key, "issue-1", ["grant-1"], "run-2")
    assert {:ok, ["grant-2"]} = RunStore.claim_path_unlocks(@repo_key, "issue-1", ["grant-1", "grant-2"], "run-2")

    # Another ticket's record is its own.
    assert {:ok, ["grant-1"]} = RunStore.claim_path_unlocks(@repo_key, "issue-2", ["grant-1"], "run-3")

    assert {:error, :invalid_issue_id} = RunStore.claim_path_unlocks(@repo_key, nil, ["grant-1"], "run-1")
    assert {:error, :invalid_repo_key} = RunStore.claim_path_unlocks(nil, "issue-1", ["grant-1"], "run-1")
  end

  test "records a ticket's decisions once, across a restart, and creates no record for nothing" do
    decision = %{key: "comment-1", date: ~D[2026-10-13], title: "Keep it", question: "Keep it?", answer: "Yes", scope: "As answered"}

    assert {:ok, []} = RunStore.record_ticket_decisions(@repo_key, "issue-1", [], [])
    assert RunStore.get_ticket_state(@repo_key, "issue-1") == nil

    old = %{decision | key: "old"}
    assert {:ok, [%{key: "comment-1"}]} = RunStore.record_ticket_decisions(@repo_key, "issue-1", [decision], [])
    restart_run_store()

    assert {:ok, [%{key: "comment-1"}, %{key: "comment-2"}]} =
             RunStore.record_ticket_decisions(@repo_key, "issue-1", [decision, %{decision | key: "comment-2"}], [old])

    assert %{decisions: [%{key: "comment-1", date: ~D[2026-10-13]}, %{key: "comment-2"}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")

    # A record that holds no decision takes the backfill first.
    assert {:ok, [%{key: "old"}, %{key: "comment-1"}]} = RunStore.record_ticket_decisions(@repo_key, "issue-2", [decision], [old])

    assert {:error, :invalid_issue_id} = RunStore.record_ticket_decisions(@repo_key, nil, [decision], [])
    assert {:error, :invalid_repo_key} = RunStore.record_ticket_decisions(nil, "issue-1", [decision], [])
  end

  test "interrupt_running_runs marks stale running records as failures" do
    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_run(%{
               repo_key: @repo_key,
               run_id: "run-stale",
               issue_id: "issue-stale",
               issue_identifier: "ACME-2",
               status: "running",
               attempt: 1,
               started_at: now
             })

    assert {:ok, 1} = RunStore.interrupt_running_runs(@repo_key, "orchestrator restarted before worker exit")

    assert [
             %{
               run_id: "run-stale",
               repo_key: @repo_key,
               status: "failure",
               error: "orchestrator restarted before worker exit",
               ended_at: %DateTime{}
             }
           ] = RunStore.list_runs(@repo_key)
  end

  test "interrupt_running_runs also interrupts Auto Review QA runs" do
    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_run(%{
               repo_key: @repo_key,
               run_id: "qa-stale",
               kind: "qa",
               issue_id: "issue-qa",
               issue_identifier: "ACME-3",
               status: "qa_running",
               attempt: 1,
               started_at: now
             })

    assert {:ok, 1} = RunStore.interrupt_running_runs(@repo_key, "orchestrator restarted before worker exit")
    assert [%{run_id: "qa-stale", kind: "qa", status: "failure"}] = RunStore.list_runs(@repo_key)
  end

  test "interrupt_running_runs skips malformed running records" do
    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_run(%{
               repo_key: @repo_key,
               run_id: "run-valid",
               issue_id: "issue-valid",
               issue_identifier: "ACME-3",
               status: "running",
               attempt: 1,
               started_at: now
             })

    assert {:atomic, :ok} =
             :mnesia.transaction(fn ->
               :mnesia.write({:symphony_run_store_runs, {@repo_key, "malformed"}, @repo_key, "malformed", %{status: "running"}})
               :ok
             end)

    log =
      capture_log(fn ->
        assert {:ok, 1} = RunStore.interrupt_running_runs(@repo_key, "orchestrator restarted before worker exit")
      end)

    assert log =~ "Skipping malformed running run store record"

    assert [
             %{run_id: "run-valid", status: "failure"},
             %{status: "running"}
           ] = Enum.sort_by(RunStore.list_runs(@repo_key, :all), &Map.get(&1, :run_id, "zzz"))
  end

  describe "the run index" do
    test "bounded reads return the newest runs from the index, without scanning the table" do
      put_indexed_runs(@repo_key, ["a-1", "a-2", "a-3"], 0)
      put_indexed_runs(@other_repo_key, ["b-1", "b-2"], 10)
      assert :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "a-unstarted", status: "running"})

      assert run_ids(RunStore.list_runs(@repo_key, 2)) == ["a-3", "a-2"]
      assert run_ids(RunStore.list_runs(@repo_key, 10)) == ["a-3", "a-2", "a-1", "a-unstarted"]
      assert RunStore.list_runs(@repo_key, 0) == []
      assert run_ids(RunStore.list_all_runs(3)) == ["b-2", "b-1", "a-3"]
      assert RunStore.list_runs("missing-repo", 5) == []

      # Written behind RunStore's back, so only a scan of the table can find it.
      assert {:atomic, :ok} =
               :mnesia.transaction(fn ->
                 :mnesia.write({:symphony_run_store_runs, {@repo_key, "a-raw"}, @repo_key, "a-raw", %{run_id: "a-raw", started_at: started_at(99)}})
               end)

      assert run_ids(RunStore.list_runs(@repo_key, 2)) == ["a-3", "a-2"]
      assert ["a-raw" | _rest] = run_ids(RunStore.list_runs(@repo_key, :all))
    end

    test "a bounded read costs the same however many runs the store holds" do
      put_indexed_runs(@repo_key, Enum.map(1..20, &"small-#{&1}"), 0)
      small = reductions(fn -> RunStore.list_runs(@repo_key, 10) end)

      put_indexed_runs(@repo_key, Enum.map(1..400, &"large-#{&1}"), 100)
      large = reductions(fn -> RunStore.list_runs(@repo_key, 10) end)
      scan = reductions(fn -> RunStore.list_runs(@repo_key, :all) end)

      assert length(RunStore.list_runs(@repo_key, 10)) == 10
      assert large < small * 2, "list_runs/2 took #{large} reductions over 420 runs, #{small} over 20"
      assert scan > large * 5
    end

    test "reads the runs of one issue from the index, newest first" do
      put_indexed_runs(@repo_key, ["a-1", "a-2"], 0)
      assert :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "a-3", issue_id: "issue-a-1", started_at: started_at(5)})
      assert :ok = RunStore.put_run(%{repo_key: @other_repo_key, run_id: "b-1", issue_id: "issue-a-1", started_at: started_at(6)})
      assert :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "no-issue", started_at: started_at(7)})

      assert run_ids(RunStore.list_issue_runs(@repo_key, "issue-a-1")) == ["a-3", "a-1"]
      assert run_ids(RunStore.list_issue_runs(@other_repo_key, "issue-a-1")) == ["b-1"]
      assert RunStore.list_issue_runs(@repo_key, "missing-issue") == []

      # A run moved to another issue or start is found only under its new ones.
      assert :ok = RunStore.update_run(@repo_key, "a-3", %{issue_id: "issue-a-2", started_at: started_at(-1)})
      assert run_ids(RunStore.list_issue_runs(@repo_key, "issue-a-1")) == ["a-1"]
      assert run_ids(RunStore.list_issue_runs(@repo_key, "issue-a-2")) == ["a-2", "a-3"]

      # Emptied as when RunStore starts, before the index is built: the read scans the repository.
      assert :ok = RunIndex.create()
      assert RunIndex.take_issue(@repo_key, "issue-a-2") == :unavailable
      assert run_ids(RunStore.list_issue_runs(@repo_key, "issue-a-2")) == ["a-2", "a-3"]

      restart_run_store()
      assert {:ok, [{@repo_key, "a-2"}, {@repo_key, "a-3"}]} = RunIndex.take_issue(@repo_key, "issue-a-2")
    end

    test "reading one issue's runs costs the same however many runs the store holds" do
      put_indexed_runs(@repo_key, Enum.map(1..20, &"small-#{&1}"), 0)
      small = reductions(fn -> RunStore.list_issue_runs(@repo_key, "issue-small-1") end)

      put_indexed_runs(@repo_key, Enum.map(1..400, &"large-#{&1}"), 100)
      large = reductions(fn -> RunStore.list_issue_runs(@repo_key, "issue-small-1") end)

      assert run_ids(RunStore.list_issue_runs(@repo_key, "issue-small-1")) == ["small-1"]
      assert large < small * 2, "list_issue_runs/2 took #{large} reductions over 420 runs, #{small} over 20"
    end

    test "reads the runs with a status, the runs started on a day and a repository's workspace identifiers from the index" do
      day = ~D[2026-10-05]
      day_start = DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC")

      put_run(@repo_key, "a-1", issue_identifier: "MT-1", status: "budget_exhausted", started_at: day_start)
      put_run(@repo_key, "a-2", issue_identifier: "MT-1", status: "success", started_at: started_at(0))
      put_run(@repo_key, "a-3", workspace_path: "/workspaces/repo-a/MT-2", status: "running", started_at: started_at(-86_400))
      put_run(@repo_key, "a-4", issue_identifier: "MT-1" <> <<0>>, started_at: DateTime.add(day_start, 1, :day))
      put_run(@repo_key, "a-5", issue_identifier: nil, workspace_path: "/workspaces/repo-a/MT-0")
      put_run(@repo_key, "a-6", issue_identifier: 42)
      put_run(@other_repo_key, "b-1", issue_identifier: "MT-9", status: "budget_exhausted", started_at: started_at(5))

      assert run_ids(RunStore.list_runs_with_status("budget_exhausted")) |> Enum.sort() == ["a-1", "b-1"]
      assert run_ids(RunStore.list_runs_with_status("running")) == ["a-3"]
      assert RunStore.list_runs_with_status("missing") == []
      assert run_ids(RunStore.list_runs_started_on(day)) == ["b-1", "a-2", "a-1"]
      assert run_ids(RunStore.list_runs_started_on(Date.add(day, 1))) == ["a-4"]
      assert RunStore.list_runs_started_on(Date.add(day, 2)) == []
      assert RunStore.list_run_identifiers(@repo_key) == ["MT-0", "MT-1", "MT-1" <> <<0>>, "MT-2"]
      assert RunStore.list_run_identifiers(@other_repo_key) == ["MT-9"]
      assert RunStore.list_run_identifiers("missing-repo") == []
      assert {:error, :invalid_repo_key} = RunStore.list_run_identifiers(" ")

      # A run that changed status, start or workspace is found only under its new ones.
      update = %{status: "success", started_at: started_at(-86_399), issue_identifier: "MT-3"}
      assert :ok = RunStore.update_run(@repo_key, "a-1", update)
      assert {:ok, 1} = RunStore.interrupt_running_runs(@repo_key, "restarted")
      assert run_ids(RunStore.list_runs_with_status("budget_exhausted")) == ["b-1"]
      assert RunStore.list_runs_with_status("running") == []
      assert run_ids(RunStore.list_runs_with_status("failure")) == ["a-3"]
      assert run_ids(RunStore.list_runs_started_on(day)) == ["b-1", "a-2"]
      assert run_ids(RunStore.list_runs_started_on(Date.add(day, -1))) == ["a-1", "a-3"]
      assert RunStore.list_run_identifiers(@repo_key) == ["MT-0", "MT-1", "MT-1" <> <<0>>, "MT-2", "MT-3"]

      # Emptied as when RunStore starts, before the index is built: the reads scan the table.
      assert :ok = RunIndex.create()
      assert RunIndex.take_status("failure") == :unavailable
      assert RunIndex.take_started(day_start, DateTime.add(day_start, 1, :day)) == :unavailable
      assert RunIndex.take_identifiers(@repo_key) == :unavailable
      assert run_ids(RunStore.list_runs_with_status("budget_exhausted")) == ["b-1"]
      assert run_ids(RunStore.list_runs_started_on(day)) == ["b-1", "a-2"]
      assert run_ids(RunStore.list_runs_started_on(Date.add(day, -1))) == ["a-1", "a-3"]
      assert RunStore.list_run_identifiers(@repo_key) == ["MT-0", "MT-1", "MT-1" <> <<0>>, "MT-2", "MT-3"]
      assert RunStore.list_run_identifiers("missing-repo") == []

      restart_run_store()
      assert {:ok, [{@repo_key, "a-3"}]} = RunIndex.take_status("failure")
      assert RunStore.list_run_identifiers(@repo_key) == ["MT-0", "MT-1", "MT-1" <> <<0>>, "MT-2", "MT-3"]
    end

    test "the startup reads cost the same however many runs the store holds" do
      day = ~D[2026-10-05]
      put_startup_runs(@repo_key, "small", 20, 0)
      small = startup_read_reductions(day)

      # Older runs, on other days, with other statuses, for the same issues.
      put_startup_runs(@repo_key, "large", 400, 86_400)
      large = startup_read_reductions(day)
      scan = reductions(fn -> RunStore.list_all_runs(:all) end)

      assert length(RunStore.list_runs_started_on(day)) == 20
      assert length(RunStore.list_runs_with_status("budget_exhausted")) == 2
      assert RunStore.list_run_identifiers(@repo_key) == Enum.map(0..4, &"MT-#{&1}")

      for {read, cost} <- large do
        assert cost < small[read] * 2, "#{read} took #{cost} reductions over 420 runs, #{small[read]} over 20"
        assert scan > cost * 5, "#{read} took #{cost} reductions over 420 runs, a scan #{scan}"
      end
    end

    test "an update moves a run whose start changed and keeps the record current" do
      put_indexed_runs(@repo_key, ["a-1", "a-2"], 0)

      assert :ok = RunStore.update_run(@repo_key, "a-1", %{started_at: started_at(50), status: "success"})
      assert [%{run_id: "a-1", status: "success"}, %{run_id: "a-2"}] = RunStore.list_runs(@repo_key, 5)

      assert :ok = RunStore.update_run(@repo_key, "a-2", %{status: "failure"})
      assert [%{run_id: "a-1"}, %{run_id: "a-2", status: "failure"}] = RunStore.list_runs(@repo_key, 5)
      assert {:error, :run_not_found} = RunStore.update_run(@repo_key, "missing", %{status: "failure"})

      assert :ok = RunStore.clear()
      assert RunStore.list_runs(@repo_key, 5) == []
      assert RunStore.list_all_runs(5) == []
    end

    test "memoizes a value per run kind until a run of that kind is written" do
      test_pid = self()

      derive = fn ->
        send(test_pid, :derived)
        {:ok, @repo_key |> RunStore.list_runs(:all) |> Enum.filter(&(&1[:kind] == "acceptance_gate")) |> run_ids()}
      end

      assert {:ok, []} = RunStore.memoize_runs(:gate_ids, "acceptance_gate", derive)
      assert_received :derived

      assert :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "agent-1", kind: "agent", started_at: started_at(1)})
      assert {:ok, []} = RunStore.memoize_runs(:gate_ids, "acceptance_gate", derive)
      refute_received :derived

      assert :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "gate-1", kind: "acceptance_gate", status: "running", started_at: started_at(2)})
      assert {:ok, ["gate-1"]} = RunStore.memoize_runs(:gate_ids, "acceptance_gate", derive)
      assert_received :derived

      assert :ok = RunStore.update_run(@repo_key, "gate-1", %{verdict: "approve"})
      assert {:ok, ["gate-1"]} = RunStore.memoize_runs(:gate_ids, "acceptance_gate", derive)
      assert_received :derived

      assert {:ok, 1} = RunStore.interrupt_running_runs(@repo_key, "restarted")
      assert {:ok, ["gate-1"]} = RunStore.memoize_runs(:gate_ids, "acceptance_gate", derive)
      assert_received :derived

      assert :ok = RunStore.clear()
      assert {:error, :unreadable} = RunStore.memoize_runs(:gate_ids, "acceptance_gate", fn -> {:error, :unreadable} end)
      assert {:ok, []} = RunStore.memoize_runs(:gate_ids, "acceptance_gate", derive)
      assert_received :derived
    end

    test "falls back to scanning without a built index, and rebuilds it when RunStore starts" do
      put_indexed_runs(@repo_key, ["a-1", "a-2"], 0)
      test_pid = self()
      derive = fn -> send(test_pid, :derived) && {:ok, :value} end

      # Emptied as when RunStore starts, before the index is built.
      assert :ok = RunIndex.create()
      assert RunIndex.take(@repo_key, 1) == :unavailable
      assert run_ids(RunStore.list_runs(@repo_key, 1)) == ["a-2"]
      assert run_ids(RunStore.list_all_runs(1)) == ["a-2"]
      assert {:ok, :value} = RunStore.memoize_runs(:fallback, "agent", derive)
      assert {:ok, :value} = RunStore.memoize_runs(:fallback, "agent", derive)
      assert_received :derived
      assert_received :derived

      # Gone, as while RunStore restarts.
      :ets.delete(:symphony_run_store_run_index)
      assert :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "a-3", started_at: started_at(3)})
      assert :ok = RunIndex.touch()
      assert :ok = RunIndex.reset()
      assert :ok = RunIndex.build([])
      assert RunIndex.take(:all, 1) == :unavailable
      assert run_ids(RunStore.list_runs(@repo_key, 1)) == ["a-3"]
      assert {:ok, :value} = RunStore.memoize_runs(:fallback, "agent", derive)
      assert_received :derived

      restart_run_store()

      assert {:ok, [{@repo_key, "a-3"}, {@repo_key, "a-2"}]} = RunIndex.take(@repo_key, 2)
      assert run_ids(RunStore.list_runs(@repo_key, 5)) == ["a-3", "a-2", "a-1"]
      assert {:ok, :value} = RunStore.memoize_runs(:fallback, "agent", derive)
      assert {:ok, :value} = RunStore.memoize_runs(:fallback, "agent", derive)
      assert_received :derived
      refute_received :derived
    end
  end

  defp put_indexed_runs(repo_key, run_ids, offset) do
    run_ids
    |> Enum.with_index(offset)
    |> Enum.each(fn {run_id, second} ->
      record = %{repo_key: repo_key, run_id: run_id, issue_id: "issue-#{run_id}", status: "success", started_at: started_at(second)}
      assert :ok = RunStore.put_run(record)
    end)
  end

  # `count` runs of five issues, `offset` seconds before noon on 2026-10-05; the first two are
  # budget-exhausted.
  defp put_startup_runs(repo_key, prefix, count, offset) do
    Enum.each(0..(count - 1), fn index ->
      status = if index < 2 and offset == 0, do: "budget_exhausted", else: "success"
      put_run(repo_key, "#{prefix}-#{index}", issue_identifier: "MT-#{rem(index, 5)}", status: status, started_at: started_at(-offset - index))
    end)
  end

  defp put_run(repo_key, run_id, attrs) do
    assert :ok = attrs |> Map.new() |> Map.merge(%{repo_key: repo_key, run_id: run_id}) |> RunStore.put_run()
  end

  defp startup_read_reductions(day) do
    %{
      started_on: reductions(fn -> RunStore.list_runs_started_on(day) end),
      with_status: reductions(fn -> RunStore.list_runs_with_status("budget_exhausted") end),
      identifiers: reductions(fn -> RunStore.list_run_identifiers(@repo_key) end)
    }
  end

  defp started_at(second), do: DateTime.add(~U[2026-10-05 12:00:00.000000Z], second, :second)

  defp run_ids(runs), do: Enum.map(runs, & &1.run_id)

  defp reductions(fun) do
    fun.()
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, later} = Process.info(self(), :reductions)
    later - before
  end

  test "persists eval logs with indexed filter fields" do
    now = DateTime.utc_now()
    yesterday = DateTime.add(now, -1, :day)

    assert :ok =
             RunStore.put_eval_log(%{
               repo_key: @repo_key,
               eval_id: "eval-1",
               run_id: "run-1",
               issue_identifier: "ACME-1",
               issue_labels: ["bug", "backend"],
               outcome: "pr_opened",
               agent_kind: "codex",
               tokens: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
               tests_run: true,
               duration_seconds: 12,
               workspace_path: "/tmp/workspaces/ACME-1",
               session_id: "session-1",
               logged_at: now,
               date: DateTime.to_date(now)
             })

    assert :ok =
             RunStore.put_eval_log(%{
               repo_key: @repo_key,
               eval_id: "eval-2",
               run_id: "run-2",
               issue_identifier: "ACME-2",
               issue_labels: ["feature"],
               outcome: "error",
               agent_kind: "claude",
               tokens: %{input_tokens: 3, output_tokens: 2, total_tokens: 5},
               tests_run: false,
               duration_seconds: 4,
               logged_at: yesterday,
               date: DateTime.to_date(yesterday)
             })

    assert [%{eval_id: "eval-1", repo_key: @repo_key}] = RunStore.list_eval_logs(@repo_key, outcome: "pr_opened", limit: :all)
    assert [%{eval_id: "eval-2"}] = RunStore.list_eval_logs(@repo_key, agent_kind: "claude", limit: :all)
    assert [%{eval_id: "eval-1"}] = RunStore.list_eval_logs(@repo_key, issue_label: "backend", limit: :all)
    assert [%{eval_id: "eval-1"}] = RunStore.list_eval_logs(@repo_key, date_from: DateTime.to_date(now), limit: :all)

    attributes = :mnesia.table_info(:symphony_run_store_eval_logs, :attributes)
    indexes = :mnesia.table_info(:symphony_run_store_eval_logs, :index)

    for indexed_field <- [:outcome, :agent_kind, :issue_label, :date] do
      assert attribute_position(attributes, indexed_field) in indexes
    end
  end

  test "persists learnings and prunes oldest records per repo" do
    now = DateTime.utc_now()

    records =
      for index <- 1..3 do
        %{
          id: "learning-#{index}",
          repo_key: "github.com/example/repo",
          repo: "github.com/example/repo",
          rule: "Prefer the established helper #{index}.",
          tags: ["review-feedback", "repo-patterns"],
          evidence_quote: "Use the helper.",
          evidence_issue_identifier: "ACME-#{index}",
          evidence_issue_url: "https://linear.example.test/acme/ACME-#{index}",
          evidence_pr_number: index,
          evidence_run_id: "run-#{index}",
          created_at: DateTime.add(now, index, :second)
        }
      end

    assert :ok = RunStore.put_learnings(records, 2)

    assert [
             %{id: "learning-3", evidence_pr_number: 3},
             %{id: "learning-2", evidence_pr_number: 2}
           ] = RunStore.list_learnings("github.com/example/repo")

    assert [%{id: "learning-3"}] = RunStore.list_learnings("github.com/example/repo", tag: "review-feedback", limit: 1)
    assert [] = RunStore.list_learnings("github.com/other/repo")

    restart_run_store()

    assert [
             %{id: "learning-3"},
             %{id: "learning-2"}
           ] = RunStore.list_learnings("github.com/example/repo")

    restart_run_store()
  end

  describe "the stored transcript buffer" do
    test "a run's row keeps only the newest 20 events" do
      assert :ok =
               RunStore.put_run(%{
                 repo_key: @repo_key,
                 run_id: "run-tx",
                 status: "running",
                 transcript_buffer: events(1..200),
                 transcript_buffer_size: 200
               })

      assert %{transcript_buffer: kept, transcript_buffer_size: 20} = stored_run("run-tx")
      assert kept == events(181..200)

      update = %{status: "success", transcript_buffer: events(1..20), transcript_buffer_size: 20}
      assert :ok = RunStore.update_run(@repo_key, "run-tx", update)
      assert %{status: "success", transcript_buffer: kept, transcript_buffer_size: 20} = stored_run("run-tx")
      assert kept == events(1..20)

      assert :ok = RunStore.update_run(@repo_key, "run-tx", %{transcript_buffer: events(1..21), transcript_buffer_size: 21})
      assert stored_run("run-tx").transcript_buffer == events(2..21)

      assert :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "run-no-tx", status: "running"})
      refute Map.has_key?(stored_run("run-no-tx"), :transcript_buffer)
    end

    test "rows written before the cap are trimmed once when the store starts, and the table's files shrink" do
      events = Enum.map(1..200, &%{event: :notification, payload: %{"delta" => String.duplicate("x", 500)}, n: &1})

      # Written behind RunStore's back, as rows stored before the cap were.
      assert {:atomic, :ok} =
               :mnesia.transaction(fn ->
                 for n <- 1..20 do
                   run_id = "legacy-#{n}"

                   record = %{
                     repo_key: @repo_key,
                     run_id: run_id,
                     status: "success",
                     started_at: started_at(n),
                     transcript_buffer: events,
                     transcript_buffer_size: 200
                   }

                   :mnesia.write({:symphony_run_store_runs, {@repo_key, run_id}, @repo_key, run_id, record})
                 end

                 :ok
               end)

      :ok = :mnesia.sync_log()
      :dumped = :mnesia.dump_log()
      before = runs_table_disc_size()
      restart_run_store()

      assert %{transcript_buffer: kept, transcript_buffer_size: 20, status: "success"} = stored_run("legacy-1")
      assert kept == Enum.take(events, -20)
      assert [%{transcript_buffer_size: 20} | _rest] = RunStore.list_runs(@repo_key, 1)
      assert before > 2_000_000
      # A tenth of the events, in the rewritten file and at most once more in the log.
      assert runs_table_disc_size() < before / 3

      # Nothing is left to trim: the next start rewrites nothing.
      restart_run_store()
      assert stored_run("legacy-20").transcript_buffer == Enum.take(events, -20)
    end

    test "a trim that fails leaves the rows for the next start and logs a warning" do
      record = %{repo_key: @repo_key, run_id: "legacy", status: "success", transcript_buffer: events(1..200)}
      row = {:symphony_run_store_runs, {@repo_key, "legacy"}, @repo_key, "legacy", Map.put(record, :transcript_buffer_size, 200)}
      assert {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write(row) end)
      assert {:atomic, :ok} = :mnesia.change_table_access_mode(:symphony_run_store_runs, :read_only)

      log =
        try do
          capture_log(fn -> restart_run_store() end)
        after
          {:atomic, :ok} = :mnesia.change_table_access_mode(:symphony_run_store_runs, :read_write)
        end

      assert log =~ "RunStore failed to trim stored transcript buffers:"
      refute log =~ "RunStore trimmed"
      assert stored_run("legacy").transcript_buffer_size == 200

      restart_run_store()
      assert stored_run("legacy").transcript_buffer == events(181..200)
    end
  end

  describe "loading the tables at startup" do
    test "a table load slower than 5 s no longer fails startup, and its progress is logged every 10 s" do
      :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "loaded-late", status: "success"})
      test_pid = self()
      calls = :counters.new(1, [])

      # The first three waits time out, as a large table still loading would: 30 s in all.
      wait = fn tables, timeout_ms ->
        send(test_pid, {:waited, timeout_ms})
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) <= 3, do: {:timeout, tables}, else: :mnesia.wait_for_tables(tables, timeout_ms)
      end

      log = with_table_wait(wait, fn -> capture_log([level: :info], fn -> restart_run_store() end) end)

      for _wait <- 1..4, do: assert_received({:waited, 10_000})
      assert log =~ "RunStore still loading tables after 10 s"
      assert log =~ "RunStore still loading tables after 30 s"
      refute log =~ "after 40 s"
      assert stored_run("loaded-late").status == "success"
    end

    test "a table load that never finishes fails startup after 120 s, and says how long it waited" do
      test_pid = self()

      wait = fn tables, timeout_ms ->
        send(test_pid, {:waited, timeout_ms})
        {:timeout, tables}
      end

      log =
        with_run_store_stopped(fn ->
          with_table_wait(wait, fn ->
            capture_log(fn ->
              assert {:error, {:mnesia_table_timeout, [_table | _tables], %{waited_ms: 120_000}}} =
                       GenServer.start(RunStore, [], name: RunStore)
            end)
          end)
        end)

      for _wait <- 1..12, do: assert_received({:waited, 10_000})
      refute_received {:waited, _timeout_ms}
      assert log =~ "RunStore still loading tables after 110 s"
      assert log =~ "RunStore gave up loading tables after 120 s"
    end
  end

  test "scopes durable records by repo_key when identifiers collide" do
    now = DateTime.utc_now()

    assert :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "run-shared", issue_id: "issue-shared", status: "running", started_at: now})
    assert :ok = RunStore.put_run(%{repo_key: @other_repo_key, run_id: "run-shared", issue_id: "issue-shared", status: "queued", started_at: now})
    assert :ok = RunStore.update_run(@repo_key, "run-shared", %{status: "success"})

    assert [%{repo_key: @repo_key, status: "success"}] = RunStore.list_runs(@repo_key)
    assert [%{repo_key: @other_repo_key, status: "queued"}] = RunStore.list_runs(@other_repo_key)

    retry = %{issue_id: "issue-shared", issue_identifier: "ACME-1", identifier: "ACME-1", attempt: 1, due_at: now}
    assert :ok = RunStore.put_retry(Map.put(retry, :repo_key, @repo_key))
    assert :ok = RunStore.put_retry(retry |> Map.put(:repo_key, @other_repo_key) |> Map.put(:attempt, 2))

    assert [
             %{repo_key: @repo_key, attempt: 1},
             %{repo_key: @other_repo_key, attempt: 2}
           ] = RunStore.list_retries(:all) |> Enum.sort_by(& &1.repo_key)

    assert :ok = RunStore.delete_retry(@repo_key, "issue-shared")

    assert [] = RunStore.list_retries(@repo_key)
    assert [%{repo_key: @other_repo_key, attempt: 2}] = RunStore.list_retries(@other_repo_key)

    pr_review = %{issue_id: "issue-shared", pr_url: "https://example.test/pr/1", status: "watching", updated_at: now}
    assert :ok = RunStore.put_pr_review(Map.put(pr_review, :repo_key, @repo_key))
    assert :ok = RunStore.put_pr_review(pr_review |> Map.put(:repo_key, @other_repo_key) |> Map.put(:status, "cooling_down"))
    assert :ok = RunStore.update_pr_review(@repo_key, "issue-shared", %{status: "complete"})

    assert [%{repo_key: @repo_key, status: "complete"}] = RunStore.list_pr_reviews(@repo_key)
    assert [%{repo_key: @other_repo_key, status: "cooling_down"}] = RunStore.list_pr_reviews(@other_repo_key)

    ci_check = %{issue_id: "issue-shared", pr_url: "https://example.test/pr/1", commit_sha: "abc", status: "pending", updated_at: now}
    assert :ok = RunStore.put_ci_check(Map.put(ci_check, :repo_key, @repo_key))
    assert :ok = RunStore.put_ci_check(ci_check |> Map.put(:repo_key, @other_repo_key) |> Map.put(:status, "green"))
    assert :ok = RunStore.delete_ci_check(@repo_key, "issue-shared")

    assert [] = RunStore.list_ci_checks(@repo_key)
    assert [%{repo_key: @other_repo_key, status: "green"}] = RunStore.list_ci_checks(@other_repo_key)

    allocation = %{
      run_id: "run-shared",
      issue_id: "issue-shared",
      port: 4010,
      status: "allocated",
      allocated_at: now,
      updated_at: now
    }

    assert :ok = RunStore.put_verification_allocation(Map.put(allocation, :repo_key, @repo_key))

    other_allocation =
      allocation
      |> Map.put(:repo_key, @other_repo_key)
      |> Map.put(:port, 4011)

    assert :ok = RunStore.put_verification_allocation(other_allocation)

    assert :ok = RunStore.update_verification_allocation(@repo_key, "run-shared", %{status: "released"})

    assert [%{repo_key: @repo_key, status: "released", port: 4010}] =
             RunStore.list_verification_allocations(@repo_key)

    assert [%{repo_key: @other_repo_key, status: "allocated", port: 4011}] =
             RunStore.list_verification_allocations(@other_repo_key)

    assert [
             %{repo_key: @repo_key, status: "released", port: 4010},
             %{repo_key: @other_repo_key, status: "allocated", port: 4011}
           ] = RunStore.list_all_verification_allocations() |> Enum.sort_by(& &1.port)

    eval_log = %{
      eval_id: "eval-shared",
      run_id: "run-shared",
      outcome: "success",
      agent_kind: "codex",
      logged_at: now,
      date: DateTime.to_date(now)
    }

    assert :ok = RunStore.put_eval_log(Map.put(eval_log, :repo_key, @repo_key))

    other_eval_log =
      eval_log
      |> Map.put(:repo_key, @other_repo_key)
      |> Map.put(:outcome, "error")

    assert :ok = RunStore.put_eval_log(other_eval_log)

    assert [%{repo_key: @repo_key, outcome: "success"}] = RunStore.list_eval_logs(@repo_key, limit: :all)
    assert [%{repo_key: @other_repo_key, outcome: "error"}] = RunStore.list_eval_logs(@other_repo_key, limit: :all)

    learnings = [
      %{repo_key: @repo_key, id: "learning-shared", rule: "Repo A rule.", created_at: now},
      %{repo_key: @other_repo_key, id: "learning-shared", rule: "Repo B rule.", created_at: now}
    ]

    assert :ok = RunStore.put_learnings(learnings, 10)

    assert [%{repo_key: @repo_key, rule: "Repo A rule."}] = RunStore.list_learnings(@repo_key)
    assert [%{repo_key: @other_repo_key, rule: "Repo B rule."}] = RunStore.list_learnings(@other_repo_key)
  end

  test "list_all_runs aggregates runs across every repo partition" do
    earlier = DateTime.utc_now() |> DateTime.add(-60, :second)
    later = DateTime.utc_now()

    assert :ok =
             RunStore.put_run(%{
               repo_key: @repo_key,
               run_id: "run-a",
               issue_id: "issue-a",
               status: "success",
               started_at: earlier
             })

    assert :ok =
             RunStore.put_run(%{
               repo_key: @other_repo_key,
               run_id: "run-b",
               issue_id: "issue-b",
               status: "success",
               started_at: later
             })

    assert [
             %{repo_key: @other_repo_key, run_id: "run-b"},
             %{repo_key: @repo_key, run_id: "run-a"}
           ] = RunStore.list_all_runs(:all)

    assert [%{run_id: "run-b"}] = RunStore.list_all_runs(1)
    assert [%{run_id: "run-b"}, %{run_id: "run-a"}] = RunStore.list_all_runs()
  end

  defp attribute_position(attributes, field) do
    Enum.find_index(attributes, &(&1 == field)) + 2
  end

  # Returns once the new RunStore built its run index, and leaves it unlinked from the test.
  # Stopping a supervised RunStore behind the supervisor's back raced the supervisor's own restart:
  # the test could read the index while it was still being built, or own a RunStore that died after
  # the test and was restarted, emptying the index, during the next one. Each of those restarts also
  # counted toward the supervisor's limit of 3 in 5 seconds, and a few such tests in a row shut the
  # whole supervisor down, so `terminate_child/2` exited with `shutdown`. A restart through
  # `terminate_child/2` and `restart_child/2` counts toward nothing.
  defp restart_run_store do
    case Supervisor.terminate_child(SymphonyElixir.Supervisor, RunStore) do
      :ok ->
        {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, RunStore)
        :ok

      # Without the orchestrator runtime nothing supervises it: `RunStore.ensure_started/0` starts it.
      {:error, :not_found} ->
        if pid = Process.whereis(RunStore), do: GenServer.stop(pid)
        {:ok, _pid} = GenServer.start(RunStore, [], name: RunStore)
        :ok
    end
  end

  # Stops RunStore for `fun` and starts it again afterwards, supervised or not.
  defp with_run_store_stopped(fun) do
    supervised? = Supervisor.terminate_child(SymphonyElixir.Supervisor, RunStore) == :ok
    pid = Process.whereis(RunStore)
    if not supervised? and pid, do: GenServer.stop(pid)

    try do
      fun.()
    after
      if supervised? do
        {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, RunStore)
      else
        {:ok, _pid} = GenServer.start(RunStore, [], name: RunStore)
      end
    end
  end

  defp with_table_wait(wait, fun) do
    Application.put_env(:symphony_elixir, :run_store_wait_for_tables, wait)

    try do
      fun.()
    after
      Application.delete_env(:symphony_elixir, :run_store_wait_for_tables)
    end
  end

  defp events(range), do: Enum.map(range, &%{event: :notification, n: &1})

  defp stored_run(run_id) do
    {:atomic, [{_table, _key, _repo_key, ^run_id, record}]} =
      :mnesia.transaction(fn -> :mnesia.read(:symphony_run_store_runs, {@repo_key, run_id}) end)

    record
  end

  # The table file and its log: the rows sit in either, depending on when Mnesia last dumped its log.
  defp runs_table_disc_size do
    ["symphony_run_store_runs.DCD", "symphony_run_store_runs.DCL"]
    |> Enum.map(&Path.join(RunStore.store_dir(), &1))
    |> Enum.map(fn path ->
      case File.stat(path) do
        {:ok, %{size: size}} -> size
        {:error, :enoent} -> 0
      end
    end)
    |> Enum.sum()
  end

  defp create_legacy_run_store_dir!(dir) do
    expanded_dir = Path.expand(dir)
    File.rm_rf!(expanded_dir)
    File.mkdir_p!(expanded_dir)
    Application.put_env(:mnesia, :dir, String.to_charlist(expanded_dir))
    :ok = :mnesia.create_schema([node()])
    :ok = :mnesia.start()

    assert {:atomic, :ok} =
             :mnesia.create_table(
               :symphony_run_store_runs,
               attributes: [:run_id, :record],
               disc_copies: [node()]
             )

    stop_mnesia_for_test()
  end

  defp stop_mnesia_for_test do
    case :mnesia.stop() do
      :stopped -> :ok
      :ok -> :ok
      {:error, {:not_started, :mnesia}} -> :ok
    end
  end

  defp stop_run_store_for_test do
    case Process.whereis(RunStore) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        GenServer.stop(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> :ok
        end

      _pid ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
