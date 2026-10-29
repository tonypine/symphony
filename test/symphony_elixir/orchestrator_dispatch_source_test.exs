defmodule SymphonyElixir.OrchestratorDispatchSourceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Dispatch.Shadow
  alias SymphonyElixir.{OperatorStop, QualityGate, SubIssueWait, TicketObservation}
  alias SymphonyElixirWeb.ObservabilityPubSub

  defmodule PassProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(_issue, _settings), do: {:ok, %{score: 9, reason: "clear"}}
  end

  defmodule NoScoreProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(issue, _settings), do: raise("scored #{issue.identifier} again")
  end

  @linear_at ~U[2026-10-29 09:00:00Z]

  setup do
    Shadow.reset()
    on_exit(&Shadow.reset/0)
    repo_key = "source-#{System.unique_integer([:positive])}"
    %{repo_key: repo_key, repos: [%{name: repo_key, team: "ACME", labels: []}]}
  end

  defp issue(repo_key, n, attrs \\ []) do
    struct!(
      %Issue{
        id: "#{repo_key}-#{n}",
        identifier: "ACME-#{n}",
        title: "Ticket #{n}",
        state: "Todo",
        priority: 1,
        assignee_id: "user-2",
        url: "https://linear.app/acme/issue/ACME-#{n}",
        updated_at: @linear_at
      },
      attrs
    )
  end

  defp set_source(source, opts \\ []) do
    write_workflow_file!(Workflow.workflow_file_path(), opts)
    File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "dispatch:\n  source: #{source}\n")
    Cache.clear()
  end

  defp fetcher(issues) do
    fn repo ->
      send(self(), {:polled, repo.name})
      {:ok, issues}
    end
  end

  defp cycle(state, repos, issues, now_ms) do
    assert {:ok, buckets, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher(issues), now_ms)

    {buckets, state}
  end

  defp identifiers(issues), do: Enum.map(issues, & &1.identifier)

  defp orchestrator_state do
    %Orchestrator.State{
      poll_interval_ms: 100,
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  describe "dispatch.source: record" do
    test "a ticket only the record has is dispatched, and one only the poll cache has is not", ctx do
      set_source("record")
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [issue(ctx.repo_key, 1), issue(ctx.repo_key, 2)], 0)
      assert_receive {:polled, _repo}

      # The poll cache keeps ACME-2, whose record is gone; ACME-3 reaches only the record.
      :ok = RunStore.delete_ticket_state(ctx.repo_key, "#{ctx.repo_key}-2")
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, issue(ctx.repo_key, 3), source: :watcher)

      {%{dispatchable: dispatchable}, state} = capture_cycle(state, ctx.repos, 50)
      refute_receive {:polled, _repo}
      assert identifiers(dispatchable) == ["ACME-1", "ACME-3"]

      # The gates run unchanged on the rebuilt issue: Todo, assigned, Urgent and unblocked dispatches.
      only_record = Enum.find(dispatchable, &(&1.identifier == "ACME-3"))
      assert %Issue{state: "Todo", priority: 1, assignee_id: "user-2", blocked_by: [], repo_key: repo_key} = only_record
      assert repo_key == ctx.repo_key
      assert Orchestrator.should_dispatch_issue_for_test(only_record, state)
    end

    test "the shadow still compares both sides every cycle, and finds no difference while they agree", ctx do
      set_source("record")
      issues = [issue(ctx.repo_key, 1), issue(ctx.repo_key, 2, state: "In Progress")]
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, issues, 0)

      state =
        Enum.reduce([50, 100, 150], state, fn now_ms, state ->
          {%{dispatchable: dispatchable}, state} = cycle(state, ctx.repos, issues, now_ms)
          assert identifiers(dispatchable) == ["ACME-1", "ACME-2"]
          state
        end)

      assert %{cycles_compared: 4, cycles_with_differences: 0, window_differences: 0, recent: []} = Shadow.summary()

      # A difference reads as it does with the poll in use: the side that has the ticket, by name.
      :ok = RunStore.delete_ticket_state(ctx.repo_key, "#{ctx.repo_key}-2")
      capture_cycle(state, ctx.repos, 160)
      assert %{recent: [%{identifier: "ACME-2", side: :poll, field: :candidate, poll: "In Progress", record: nil}]} = Shadow.summary()
    end

    test "Issue.blocked? sees the record's blockers", ctx do
      set_source("record")
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [issue(ctx.repo_key, 1)], 0)

      blocker = %{id: "blocker-1", identifier: "ACME-9", state: "In Progress"}
      blocked = issue(ctx.repo_key, 1, blocked_by: [blocker], updated_at: DateTime.add(@linear_at, 60))
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, blocked, source: :webhook)

      {%{dispatchable: [rebuilt]}, state} = capture_cycle(state, ctx.repos, 50)
      assert [%{identifier: "ACME-9"}] = rebuilt.blocked_by
      refute Orchestrator.should_dispatch_issue_for_test(rebuilt, state)
    end

    test "nothing dispatches before every cache is warm, and a repo whose records can't be read gives none", ctx do
      set_source("record")
      cold_key = "#{ctx.repo_key}-cold"
      {:ok, :updated} = TicketObservation.observe(cold_key, issue(cold_key, 4), source: :watcher)
      repos = ctx.repos ++ [%{name: cold_key, team: "ACME", labels: ["api"]}]

      # Only the first repo is due; the second's cache is cold, so after a start nothing dispatches
      # until each repo's first poll has refreshed its records.
      {%{dispatchable: []}, _state} = cycle(orchestrator_state(), repos, [issue(ctx.repo_key, 1)], 0)

      # A blank repo key is one the store refuses: its cache is warm, its records give no candidate.
      blank = [%{name: " ", team: "ACME", labels: []}]
      {{%{dispatchable: []}, state}, _log} = with_log(fn -> cycle(orchestrator_state(), blank, [issue("blank", 5)], 0) end)

      set_source("poll")
      {%{dispatchable: [%{identifier: "ACME-5"}]}, _state} = capture_cycle(state, blank, 50)
    end

    test "a ticket the poll cache also has keeps what only the poll reads, under the record's fields", ctx do
      set_source("record")
      comments = [%{author: "Tony", body: "Also cover the retry", created_at: @linear_at}]

      polled =
        issue(ctx.repo_key, 1,
          description: "Dispatch from the record",
          comments: comments,
          team: %{key: "ACME", name: "Acme"},
          project: %{id: "project-1", name: "Reads"},
          branch_name: "acme-1-dispatch"
        )

      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [polled], 0)

      # A webhook raises its priority: the record has the new priority, the cache the text it read.
      raised = issue(ctx.repo_key, 1, priority: 2, updated_at: DateTime.add(@linear_at, 60))
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, raised, source: :webhook)

      {%{dispatchable: [rebuilt]}, _state} = capture_cycle(state, ctx.repos, 50)

      assert %Issue{priority: 2, description: "Dispatch from the record", comments: ^comments, branch_name: "acme-1-dispatch"} = rebuilt
      assert {rebuilt.team, rebuilt.project} == {polled.team, polled.project}
      # The text comes with the `updatedAt` it was read at, which the quality gate keys a verdict on.
      assert rebuilt.updated_at == @linear_at
    end

    test "a person's new comment on an approved plan is read, from the comments the poll read", ctx do
      waiting = "Waiting on sub-tickets"
      set_source("record", tracker_kind: "memory")
      SubIssueWait.reset_for_test(waiting)
      on_exit(fn -> SubIssueWait.reset_for_test(waiting) end)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      commented_at = ~U[2026-10-29 09:10:00Z]

      parent =
        issue(ctx.repo_key, 1,
          state: waiting,
          labels: ["breakdown"],
          sub_issues: [%{id: "child-1", identifier: "ACME-2", state: "In Progress"}],
          comments: [%{author: "Tony", body: "Can we drop the history screen?", created_at: commented_at}]
        )

      Application.put_env(:symphony_elixir, :memory_tracker_plan_comments, %{
        parent.id => %{
          state_changes: [%{at: @linear_at, from: "Plan Review", to: waiting}],
          comments: [%{id: "c1", body: "Can we drop the history screen?", created_at: commented_at, parent_id: nil, bot?: false}]
        }
      })

      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [parent], 0)
      {%{dispatchable: [rebuilt]}, state} = capture_cycle(state, ctx.repos, 50)
      assert rebuilt.comments == parent.comments

      {state, _log} = with_log(fn -> Orchestrator.act_on_plan_comments_for_test(state, [rebuilt]) end)
      parent_id = parent.id
      assert_received {:memory_tracker_plan_comments, ^parent_id}
      assert_received {:memory_tracker_reply, ^parent_id, "c1", _reply}
      assert state.plan_comment_checks == %{parent_id => commented_at}
    end

    test "with the quality gate on, a verdict on a ticket with comments stays current", ctx do
      set_source("record")
      # The stub providers never call out; the gate only needs a key to be configured.
      System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")
      on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)
      config = %Schema.QualityGate{enabled: true, min_score: 6}
      polled = issue(ctx.repo_key, 1, description: "Dispatch from the record", comments: [%{author: "Tony", body: "Also the retry", created_at: @linear_at}])
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [polled], 0)

      score = fn -> QualityGate.evaluate([polled], config, %{}, provider_module: PassProvider) end
      {%{passed: [_polled], cache: cache}, _log} = with_log(score)
      assert %{passed?: true, comment_signature: signature} = cache[polled.id]
      assert is_binary(signature)

      # The record moves on after the gate scored the text; the text did not change, so neither does the verdict.
      raised = issue(ctx.repo_key, 1, priority: 2, updated_at: DateTime.add(@linear_at, 60))
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, raised, source: :webhook)
      {%{dispatchable: [rebuilt]}, state} = capture_cycle(state, ctx.repos, 50)

      assert Orchestrator.quality_gate_input_for_test(state, [rebuilt]) == [rebuilt]

      assert %{passed: [^rebuilt], cache: ^cache} =
               QualityGate.evaluate([rebuilt], config, cache, provider_module: NoScoreProvider)
    end

    test "with the quality gate on, a ticket only the record has waits for its repo's poll to read its text", ctx do
      set_source("record")
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [issue(ctx.repo_key, 1)], 0)
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, issue(ctx.repo_key, 3), source: :watcher)

      {%{dispatchable: dispatchable}, state} = capture_cycle(state, ctx.repos, 50)
      assert identifiers(dispatchable) == ["ACME-1", "ACME-3"]
      assert identifiers(Orchestrator.quality_gate_input_for_test(state, dispatchable)) == ["ACME-1"]

      # A retry reads its own issue by id, text and all, so the gate scores it.
      only_record = Enum.find(dispatchable, &(&1.identifier == "ACME-3"))
      retry = {:active_retry, only_record, 1, %{}}
      assert Orchestrator.quality_gate_input_for_test(state, [only_record], retry) == [only_record]

      # Once its repo's poll has read it, the gate scores it.
      {{:poll_at, 60}, state} = Orchestrator.force_repo_due_for_test(state, ctx.repo_key, 60)
      {%{dispatchable: polled}, state} = cycle(state, ctx.repos, [issue(ctx.repo_key, 1), issue(ctx.repo_key, 3)], 60)
      assert identifiers(Orchestrator.quality_gate_input_for_test(state, polled)) == ["ACME-1", "ACME-3"]
    end

    test "a record change outside the poll asks for a cycle of its repo at once", ctx do
      set_source("record")
      :ok = ObservabilityPubSub.subscribe_ticket_records()
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [issue(ctx.repo_key, 1)], 0)

      # The poll's own writes are not announced: the cycle that made them dispatches from them.
      issue_id = "#{ctx.repo_key}-1"
      refute_received {:ticket_record, _repo_key, ^issue_id, :changed, _fields}

      # The PR and CI watcher reads a priority change: the record announces it.
      changed = issue(ctx.repo_key, 1, priority: 2, updated_at: DateTime.add(@linear_at, 60))
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, changed, source: :watcher)
      assert_receive {:ticket_record, repo_key, ^issue_id, :changed, [:priority]} = message
      assert repo_key == ctx.repo_key

      state = %{state | poll_check_in_progress: false, next_poll_due_at_ms: nil}
      assert {:noreply, state} = Orchestrator.handle_info(message, state)
      assert MapSet.member?(state.repo_poll_forced, ctx.repo_key)
      assert_receive {:tick, token} when token == state.tick_token

      # The cycle the refresh runs polls the repo and dispatches from the record.
      {%{dispatchable: [%{identifier: "ACME-1", priority: 2}]}, _state} = cycle(state, ctx.repos, [changed], 1)
      assert_receive {:polled, _repo}
    end
  end

  describe "the tick's by-id reads under dispatch.source: record" do
    setup ctx do
      set_source("record", tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      ctx
    end

    test "running, watched, forced and stopped tickets come from their records, with no by-id read", ctx do
      comments = [%{author: "Tony", body: "Mind the retry", created_at: @linear_at}]
      running = issue(ctx.repo_key, 1, state: "In Progress", description: "What the run read", comments: comments)
      watched = issue(ctx.repo_key, 2, state: "Plan Review")
      forced = issue(ctx.repo_key, 3, state: "Plan Review", labels: ["expedite"])
      stopped = issue(ctx.repo_key, 4)
      gone = issue(ctx.repo_key, 5, state: "In Progress")

      observe!(ctx.repo_key, [running, watched, forced, stopped, gone], :poll)
      # A webhook raised the running ticket's priority, and said the forced-away one was removed.
      later = DateTime.add(@linear_at, 60)
      observe!(ctx.repo_key, [%{running | priority: 2, updated_at: later}], :webhook)
      :ok = RunStore.update_ticket_state(ctx.repo_key, gone.id, %{removed_at: later})

      state = %{
        orchestrator_state()
        | running: %{running.id => %{issue: running, identifier: running.identifier}},
          watching: %{watched.id => %{}, "#{ctx.repo_key}-unknown" => %{}},
          forced: %{forced.id => %{}, gone.id => %{}},
          operator_stops: %{stopped.id => OperatorStop.mark(stopped.identifier, ctx.repo_key, DateTime.utc_now())}
      }

      {result, _state} = Orchestrator.run_repo_poll_task_for_test(state, [], 0)
      refute_received {:memory_tracker_fetch_issue_states_by_ids, _ids}

      # The running ticket takes its record's fields over the text its run holds.
      assert {[running_id], {:ok, [refreshed]}} = {result.running_ids, result.running_result}
      assert running_id == running.id
      assert %Issue{state: "In Progress", priority: 2, description: "What the run read", comments: ^comments} = refreshed

      # A ticket no record observed is not judged this tick, as a failed read judges none.
      assert result.watching_ids == [watched.id]
      assert {:ok, [%Issue{state: "Plan Review"}]} = result.watching_result

      # A removed record reads as a ticket Linear no longer returns.
      assert Enum.sort(result.forced_ids) == Enum.sort([forced.id, gone.id])
      assert {:ok, [%Issue{identifier: "ACME-3", state: "Plan Review", labels: ["expedite"]}]} = result.forced_result

      assert result.stopped_ids == [stopped.id]
      assert {:ok, [%Issue{identifier: "ACME-4", state: "Todo"}]} = result.stopped_result
    end

    test "a stop is honoured from the record: the ticket stays skipped while its record stays a candidate", ctx do
      stopped = issue(ctx.repo_key, 1)
      moved = issue(ctx.repo_key, 2)
      observe!(ctx.repo_key, [stopped, moved], :poll)
      observe!(ctx.repo_key, [%{moved | state: "Backlog", updated_at: DateTime.add(@linear_at, 60)}], :webhook)

      marks = Map.new([stopped, moved], &{&1.id, OperatorStop.mark(&1.identifier, ctx.repo_key, DateTime.utc_now())})
      state = %{orchestrator_state() | operator_stops: marks}

      {result, state} = Orchestrator.run_repo_poll_task_for_test(state, [], 0)
      refute_received {:memory_tracker_fetch_issue_states_by_ids, _ids}

      state = Orchestrator.apply_operator_stops_result_for_test(state, result.stopped_ids, result.stopped_result)

      # Still in Todo: the stop is confirmed in that state and keeps the ticket from dispatching.
      assert %{state: "Todo"} = state.operator_stops[stopped.id]
      refute Orchestrator.should_dispatch_issue_for_test(stopped, state)
      # Moved out of the candidates: the stop has done its job and goes.
      refute Map.has_key?(state.operator_stops, moved.id)
    end

    test "records the store can't read keep every ticket as it was, as a failed Linear read does", ctx do
      running = issue(ctx.repo_key, 1, state: "In Progress")
      state = %{orchestrator_state() | running: %{running.id => %{issue: running, identifier: running.identifier}}}

      {result, _state} = Orchestrator.run_repo_poll_task_for_test(state, [], 0, fn -> {:error, :store_down} end)
      assert {[_running_id], {:error, :store_down}} = {result.running_ids, result.running_result}
      refute_received {:memory_tracker_fetch_issue_states_by_ids, _ids}
    end

    test "a plan parent under review is read by id, so the plan-comment reader sees its comments", ctx do
      commented_at = ~U[2026-10-29 09:10:00Z]
      parent = issue(ctx.repo_key, 1, state: "Plan Review", labels: ["plan"])
      read = %{parent | comments: [%{author: "Tony", body: "Split the history screen out", created_at: commented_at}]}
      other = issue(ctx.repo_key, 2, state: "Plan Review")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [read, other])
      no_new_comments = %{parent.id => %{state_changes: [], comments: []}}
      Application.put_env(:symphony_elixir, :memory_tracker_plan_comments, no_new_comments)
      observe!(ctx.repo_key, [parent, other], :poll)
      state = %{orchestrator_state() | watching: %{parent.id => %{}, other.id => %{}}}

      {result, state} = Orchestrator.run_repo_poll_task_for_test(state, [], 0)

      # Only the plan parent is read: its comments are in no poll and no record.
      parent_id = parent.id
      assert_received {:memory_tracker_fetch_issue_states_by_ids, [^parent_id]}
      assert {:ok, watched} = result.watching_result
      assert Enum.find(watched, &(&1.id == parent_id)).comments == read.comments

      state = Orchestrator.act_on_plan_comments_for_test(state, watched)
      assert_received {:memory_tracker_plan_comments, ^parent_id}
      assert state.plan_comment_checks == %{parent_id => commented_at}
    end

    test "a forced or stopped plan parent under review is taken from its record; only a watched one is read by id", ctx do
      forced = issue(ctx.repo_key, 1, state: "Plan Review", labels: ["plan", "expedite"])
      stopped = issue(ctx.repo_key, 2, state: "Plan Review", labels: ["plan"])
      forced_and_watched = issue(ctx.repo_key, 3, state: "Plan Review", labels: ["plan"])
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [forced, stopped, forced_and_watched])
      observe!(ctx.repo_key, [forced, stopped], :poll)

      state = %{
        orchestrator_state()
        | forced: %{forced.id => %{}},
          operator_stops: %{stopped.id => OperatorStop.mark(stopped.identifier, ctx.repo_key, DateTime.utc_now())}
      }

      # Neither is watched, so neither reaches the plan-comment reader: no by-id read.
      {result, _state} = Orchestrator.run_repo_poll_task_for_test(state, [], 0)
      refute_received {:memory_tracker_fetch_issue_states_by_ids, _ids}
      assert {:ok, [%Issue{identifier: "ACME-1", state: "Plan Review"}]} = result.forced_result
      assert {:ok, [%Issue{identifier: "ACME-2", state: "Plan Review"}]} = result.stopped_result

      # A forced parent that is also watched is read once, for the watched group.
      observe!(ctx.repo_key, [forced_and_watched], :poll)
      both_id = forced_and_watched.id
      state = %{state | forced: Map.put(state.forced, both_id, %{}), watching: %{both_id => %{}}}

      {result, _state} = Orchestrator.run_repo_poll_task_for_test(state, [], 0)
      assert_received {:memory_tracker_fetch_issue_states_by_ids, [^both_id]}
      refute_received {:memory_tracker_fetch_issue_states_by_ids, _ids}
      assert {:ok, [%Issue{identifier: "ACME-3"}]} = result.watching_result
      assert {:ok, forced_issues} = result.forced_result
      assert forced_issues |> Enum.map(& &1.identifier) |> Enum.sort() == ["ACME-1", "ACME-3"]
    end

    test "a plan parent whose by-id read fails keeps every watched ticket as it was", ctx do
      parent = issue(ctx.repo_key, 1, state: "Plan Review", labels: ["plan"])
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, parent, source: :poll)
      Application.put_env(:symphony_elixir, :memory_tracker_fetch_issue_states_result, {:error, :linear_down})
      state = %{orchestrator_state() | watching: %{parent.id => %{}}}

      {result, _state} = Orchestrator.run_repo_poll_task_for_test(state, [], 0)
      assert result.watching_result == {:error, :linear_down}
    end
  end

  describe "the revalidation before a start under dispatch.source: record" do
    setup ctx do
      set_source("record", tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      ctx
    end

    test "a candidate whose record still says the same starts with the candidate's text, without a Linear read", ctx do
      polled = issue(ctx.repo_key, 1, description: "Dispatch from the record", comments: [%{author: "Tony", body: "Also the retry", created_at: @linear_at}])
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [polled], 0)
      {%{dispatchable: [candidate]}, _state} = capture_cycle(state, ctx.repos, 50)

      # A webhook raised its priority after the cycle: same phase, newer record, so it starts with it.
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, %{polled | priority: 2, updated_at: DateTime.add(@linear_at, 60)}, source: :webhook)

      assert {:ok, started} = Orchestrator.revalidate_issue_from_record_for_test(candidate, ctx.repo_key)
      assert %Issue{priority: 2, description: "Dispatch from the record", comments: comments, repo_key: repo_key} = started
      assert {comments, repo_key} == {polled.comments, ctx.repo_key}
      refute_received {:memory_tracker_fetch_issue_states_by_ids, _ids}
    end

    test "a candidate whose record moved since the cycle began is not started, with the stale-dispatch skip", ctx do
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [issue(ctx.repo_key, 1)], 0)
      {%{dispatchable: [candidate]}, state} = capture_cycle(state, ctx.repos, 50)

      # Another Symphony's run moved it on: still an active state, but not the phase it was chosen in.
      moved = issue(ctx.repo_key, 1, state: "In Progress", updated_at: DateTime.add(@linear_at, 60))
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, moved, source: :webhook)

      assert {:skip, %Issue{state: "In Progress"}} = Orchestrator.revalidate_issue_from_record_for_test(candidate, ctx.repo_key)

      {state, log} = with_log(fn -> Orchestrator.dispatch_chosen_issues_for_test([candidate], state) end)
      assert log =~ "Skipping stale dispatch after issue refresh: issue_id=#{candidate.id}"
      assert state.running == %{}
      refute_received {:memory_tracker_fetch_issue_states_by_ids, _ids}
    end

    test "a record older than the candidate, or one the filter leaves out, starts nothing", ctx do
      candidate = issue(ctx.repo_key, 1, updated_at: DateTime.add(@linear_at, 60))
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, issue(ctx.repo_key, 1), source: :poll)
      assert {:skip, %Issue{}} = Orchestrator.revalidate_issue_from_record_for_test(candidate, ctx.repo_key)

      # Unassigned now, no record at all, or a repo the store refuses.
      observe!(ctx.repo_key, [issue(ctx.repo_key, 2, assignee_id: nil)], :poll)
      set_source("record", tracker_kind: "memory", tracker_assignee: "user-2")
      revalidate = &Orchestrator.revalidate_issue_from_record_for_test/2
      assert {:skip, :missing} = revalidate.(issue(ctx.repo_key, 2), ctx.repo_key)
      assert {:skip, :missing} = revalidate.(issue(ctx.repo_key, 3), ctx.repo_key)
      assert {:error, _reason} = revalidate.(issue(" ", 4), " ")
    end

    test "the dispatch prefetch reads nothing from Linear, for a poll or a retry", ctx do
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [issue(ctx.repo_key, 1)], 0)
      {%{dispatchable: [candidate]}, state} = capture_cycle(state, ctx.repos, 50)

      assert Orchestrator.dispatch_refresh_ids_for_test(state, [candidate], :poll) == []
      assert Orchestrator.dispatch_refresh_ids_for_test(state, [candidate], {:active_retry, candidate, 1, %{}}) == []

      set_source("poll", tracker_kind: "memory")
      assert Orchestrator.dispatch_refresh_ids_for_test(state, [candidate], :poll) == [candidate.id]
      assert Orchestrator.dispatch_refresh_ids_for_test(state, [candidate], {:active_retry, candidate, 1, %{}}) == [candidate.id]
    end
  end

  describe "dispatch.source: poll" do
    test "dispatch reads the poll cache, and a record change waits for the repo's poll", ctx do
      set_source("poll")
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [issue(ctx.repo_key, 1), issue(ctx.repo_key, 2)], 0)

      :ok = RunStore.delete_ticket_state(ctx.repo_key, "#{ctx.repo_key}-2")
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, issue(ctx.repo_key, 3), source: :watcher)

      {%{dispatchable: dispatchable}, state} = capture_cycle(state, ctx.repos, 50)
      assert identifiers(dispatchable) == ["ACME-1", "ACME-2"]

      message = {:ticket_record, ctx.repo_key, "#{ctx.repo_key}-3", :changed, [:phase]}
      assert {:noreply, ^state} = Orchestrator.handle_info(message, state)
    end

    test "switching the source applies at the next cycle, with no restart", ctx do
      set_source("poll")
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [issue(ctx.repo_key, 1)], 0)
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, issue(ctx.repo_key, 3), source: :watcher)

      {%{dispatchable: from_poll}, state} = capture_cycle(state, ctx.repos, 50)
      assert identifiers(from_poll) == ["ACME-1"]

      set_source("record")
      {%{dispatchable: from_record}, state} = capture_cycle(state, ctx.repos, 60)
      assert identifiers(from_record) == ["ACME-1", "ACME-3"]

      # Back to the poll: the next cycle reads the cache again, and the shadow kept comparing.
      set_source("poll")
      {%{dispatchable: back}, _state} = capture_cycle(state, ctx.repos, 70)
      assert identifiers(back) == ["ACME-1"]
      assert %{cycles_compared: 4} = Shadow.summary()
    end
  end

  defp observe!(repo_key, tickets, source) do
    for ticket <- tickets, do: {:ok, :updated} = TicketObservation.observe(repo_key, ticket, source: source)
  end

  # A cycle with no repo due, whose shadow differences are logged.
  defp capture_cycle(state, repos, now_ms) do
    {result, _log} = with_log(fn -> cycle(state, repos, [], now_ms) end)
    result
  end
end
