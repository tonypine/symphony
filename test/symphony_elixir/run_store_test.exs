defmodule SymphonyElixir.RunStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunStore.RunIndex

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

    restarted_pid = restart_run_store()

    assert %{paused: true, reason: "overnight deploy", paused_at: ^paused_at} =
             RunStore.get_paused()

    assert :ok = RunStore.set_paused(true, "ignored because already paused")

    assert %{paused: true, reason: "overnight deploy", paused_at: ^paused_at} =
             RunStore.get_paused()

    assert :ok = RunStore.set_paused(false, nil)
    assert %{paused: false, reason: nil, paused_at: nil} = RunStore.get_paused()

    if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid)
    restart_run_store()
  end

  test "persists Symphony's own state moves across run store restart" do
    moved_at = ~U[2026-10-04 00:23:15Z]

    assert RunStore.get_own_state_move("issue-own") == nil
    assert :ok = RunStore.put_own_state_move("issue-own", moved_at)
    assert :ok = RunStore.put_own_state_move("issue-own", DateTime.add(moved_at, 60))

    restarted_pid = restart_run_store()

    assert RunStore.get_own_state_move("issue-own") == DateTime.add(moved_at, 60)
    assert RunStore.get_own_state_move("issue-other") == nil
    assert {:error, :invalid_own_state_move} = RunStore.put_own_state_move("issue-own", "2026-10-04")
    assert {:error, :invalid_own_state_move} = RunStore.put_own_state_move(nil, moved_at)
    assert {:error, :invalid_issue_id} = RunStore.get_own_state_move(nil)

    if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid)
    restart_run_store()
  end

  test "persists the issues a merge moved to the waiting state across run store restart" do
    refute RunStore.merged_wait?("issue-merged")
    assert :ok = RunStore.put_merged_wait("issue-merged")
    assert :ok = RunStore.put_merged_wait("issue-merged")

    restarted_pid = restart_run_store()

    assert RunStore.merged_wait?("issue-merged")
    refute RunStore.merged_wait?("issue-other")
    assert :ok = RunStore.delete_merged_wait("issue-merged")
    refute RunStore.merged_wait?("issue-merged")
    assert {:error, :invalid_issue_id} = RunStore.put_merged_wait(nil)
    assert {:error, :invalid_issue_id} = RunStore.merged_wait?(nil)
    assert {:error, :invalid_issue_id} = RunStore.delete_merged_wait(nil)

    if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid)
    restart_run_store()
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

  defp restart_run_store do
    if pid = Process.whereis(RunStore) do
      GenServer.stop(pid)
    end

    # The supervisor may restart it first and hand back a pid still in init, before the run
    # index is built; a system message is only answered once init returned.
    pid =
      case RunStore.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    _state = :sys.get_state(pid)
    pid
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
