defmodule SymphonyElixir.OrchestratorForcedTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Notifications, QaRunner, UsageLimit}

  @active_states ["Todo", "In Progress", "Merging", "Rework", "Auto Review", "Waiting on sub-tickets"]
  @waiting "Waiting on sub-tickets"
  @anthropic {"anthropic", :all}

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-forced-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-forced","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-forced","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      File.rm_rf(test_root)
    end)

    ctx = %{test_root: test_root, fake_claude: fake_claude}
    write_forced_workflow!(ctx)
    ctx
  end

  describe "the forced allowance" do
    test "with max_total full a forced Todo starts on it, ahead of the queue, and the running agents are untouched", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 2)
      forced = issue("forced-1", "MT-F1", "Todo", forced: true, priority: 4)
      todo = issue("todo-1", "MT-TODO", "Todo", priority: 1)
      tracked([forced, todo])

      state =
        orchestrator_state(2)
        |> run(issue("impl-1", "MT-1", "In Progress"), :implementation)
        |> run(issue("impl-2", "MT-2", "In Progress"), :implementation)

      refute Orchestrator.should_dispatch_issue_for_test(todo, state)
      assert Orchestrator.should_dispatch_issue_for_test(forced, state)

      {state, log} = dispatch_with_log([todo, forced], state)

      assert Enum.sort(Map.keys(state.running)) == ["forced-1", "impl-1", "impl-2"]
      assert %{forced: true} = state.running["forced-1"]
      assert log =~ ~r/Dispatching issue to agent: issue_id=forced-1 .* slot=forced forced=true/
      assert %{reason: "work slots full"} = state.slot_waiting["todo-1"]

      snapshot = snapshot_of(state)
      assert %{forced: true} = Enum.find(snapshot.running, &(&1.issue_id == "forced-1"))
      assert %{forced: false} = Enum.find(snapshot.running, &(&1.issue_id == "impl-1"))
      assert [%{issue_id: "todo-1", forced: false}] = snapshot.slot_waiting
      assert %{epic_lanes: %{shared: %{used: 2}}, finishing: %{used: 0}} = snapshot
    end

    test "a forced run takes no normal slot, and a normal ticket goes out on a free one as a normal run", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      todo = issue("todo-1", "MT-TODO", "Todo")
      tracked([todo])

      state = run(orchestrator_state(1), issue("forced-1", "MT-F1", "In Progress", forced: true), :implementation, forced: true)

      {state, log} = dispatch_with_log([todo], state)

      assert %{forced: false} = state.running["todo-1"]
      assert log =~ ~r/issue_id=todo-1 .* slot=shared forced=false/
    end

    test "a forced Rework ticket and a forced landing start with their normal slots full", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1, finishing_max: 1, forced_max: 2)
      rework = issue("rework-1", "MT-RW", "Rework", forced: true)
      landing = issue("land-2", "MT-LAND-2", "Merging", forced: true)
      tracked([rework, landing])

      state =
        orchestrator_state(1)
        |> run(issue("impl-1", "MT-1", "In Progress"), :implementation)
        |> run(issue("land-1", "MT-LAND-1", "Merging"), :landing)

      state = Orchestrator.dispatch_chosen_issues_for_test([rework, landing], state)

      assert %{forced: true} = state.running["rework-1"]
      assert %{forced: true, run_profile: %{kind: :landing}} = state.running["land-2"]
      assert state.slot_waiting == %{}
      assert %{finishing: %{used: 1}} = snapshot_of(state)
    end

    test "per-state caps leave a forced ticket alone and do not count its run", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 3, max_concurrent_agents_by_state: %{"Todo" => 1})
      forced = issue("forced-1", "MT-F1", "Todo", forced: true)
      todo = issue("todo-1", "MT-TODO", "Todo")
      tracked([forced, todo])

      state = run(orchestrator_state(3), issue("todo-0", "MT-T0", "Todo"), :implementation)
      state = Orchestrator.dispatch_chosen_issues_for_test([forced, todo], state)

      assert %{forced: true} = state.running["forced-1"]
      assert %{reason: "work slots full"} = state.slot_waiting["todo-1"]

      # The forced Todo run does not use up the Todo cap either.
      state = %{state | running: Map.delete(state.running, "todo-0")}
      state = Orchestrator.dispatch_chosen_issues_for_test([todo], state)
      assert %{forced: false} = state.running["todo-1"]
    end

    test "a forced Todo starts while a finish waits for a slot", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 2, finishing_max: 1)
      second_landing = issue("land-2", "MT-LAND-2", "Merging")
      forced = issue("forced-1", "MT-F1", "Todo", forced: true)
      todo = issue("todo-1", "MT-TODO", "Todo")
      tracked([second_landing, forced, todo])

      state = run(orchestrator_state(2), issue("land-1", "MT-LAND-1", "Merging"), :landing)
      state = Orchestrator.dispatch_chosen_issues_for_test([todo, second_landing, forced], state)

      assert Enum.sort(Map.keys(state.running)) == ["forced-1", "land-1"]
      assert %{reason: "finishing slots full"} = state.slot_waiting["land-2"]
      assert %{reason: "MT-LAND-2 (Merging) is waiting for a finishing slot"} = state.slot_waiting["todo-1"]
    end

    test "a second forced ticket waits as queued #2, is noted once, and starts on the allowance when the first ends", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      :ok = Notifications.subscribe()
      first = issue("forced-1", "MT-F1", "In Progress", forced: true)
      second = issue("forced-2", "MT-F2", "Todo", forced: true)
      tracked([second])

      queue = %{
        "forced-1" => queue_entry(first, ~U[2026-10-04 06:00:00Z]),
        "forced-2" => queue_entry(second, ~U[2026-10-04 07:00:00Z])
      }

      state =
        %{orchestrator_state(1) | forced: queue}
        |> run(first, :implementation, forced: true)
        |> run(issue("impl-1", "MT-1", "In Progress"), :implementation)

      {state, log} = dispatch_with_log([second], state)

      refute Map.has_key?(state.running, "forced-2")
      assert %{reason: "queued #2; forced slot taken by MT-F1"} = state.slot_waiting["forced-2"]
      assert log =~ "Forced ticket waiting: issue_id=forced-2 issue_identifier=MT-F2 forced=true forced_max=1 held_by=MT-F1"
      assert_receive {:notification_event, %Notifications.Event{event: "forced_waiting", issue_identifier: "MT-F2", reason: "queued #2; forced slot taken by MT-F1"}}

      snapshot = snapshot_of(state)
      assert [%{issue_id: "forced-2", forced: true}] = snapshot.slot_waiting
      assert [%{issue_id: "forced-1", position: 1}, %{issue_id: "forced-2", position: 2}] = snapshot.forced

      # The next poll leaves it waiting without a second notice.
      {state, log} = dispatch_with_log([second], state)
      refute log =~ "Forced ticket waiting"
      refute_receive {:notification_event, %Notifications.Event{event: "forced_waiting"}}, 50

      # The first forced run ends: the second takes the allowance though the normal slot is still full.
      state = %{state | running: Map.delete(state.running, "forced-1")}
      state = Orchestrator.dispatch_chosen_issues_for_test([second], state)

      assert %{forced: true} = state.running["forced-2"]
      refute MapSet.member?(state.forced_waiting_noted, "forced-2")
    end

    test "a forced ticket past forced_max takes a free normal slot as a normal run", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      second = issue("forced-2", "MT-F2", "Todo", forced: true)
      todo = issue("todo-1", "MT-TODO", "Todo", priority: 1)
      tracked([second, todo])

      state = run(orchestrator_state(1), issue("forced-1", "MT-F1", "In Progress", forced: true), :implementation, forced: true)

      {state, log} = dispatch_with_log([todo, second], state)

      assert %{forced: false} = state.running["forced-2"]
      assert log =~ "Forced ticket waiting: issue_id=forced-2"
      assert log =~ ~r/issue_id=forced-2 .* slot=shared forced=false/
      assert %{reason: "work slots full"} = state.slot_waiting["todo-1"]
    end

    test "forced tickets go first in forced_since order; one not yet queued follows", ctx do
      write_forced_workflow!(ctx, forced_max: 3)
      older = issue("forced-old", "MT-F1", "Todo", forced: true)
      newer = issue("forced-new", "MT-F2", "Merging", forced: true)
      unqueued = issue("forced-unqueued", "MT-F3", "Merging", forced: true)
      landing = issue("land-1", "MT-LAND", "Merging", priority: 1)
      tracked([older, newer, unqueued, landing])

      queue = %{
        "forced-old" => queue_entry(older, ~U[2026-10-04 06:00:00Z]),
        "forced-new" => queue_entry(newer, ~U[2026-10-04 07:00:00Z])
      }

      state = %{orchestrator_state(10) | forced: queue}
      {_state, log} = dispatch_with_log([landing, unqueued, newer, older], state)

      assert dispatch_order(log) == ["forced-old", "forced-new", "forced-unqueued", "land-1"]
    end
  end

  describe "a forced breakdown parent" do
    test "starts its first sub-ticket on the allowance with every normal slot full, and no second one while it runs", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1, forced_max: 2)
      first = issue("part-1", "MT-P1", "Todo", priority: 2)
      second = issue("part-2", "MT-P2", "Todo", priority: 3)
      parent = parent([first, second])
      candidates = [parent, second, first]
      tracked(candidates)

      state =
        %{orchestrator_state(1) | forced: %{"epic-1" => queue_entry(parent, ~U[2026-10-04 06:00:00Z])}}
        |> run(issue("impl-1", "MT-1", "In Progress"), :implementation)
        |> plan_poll(candidates)

      assert %{"epic-1" => %{issue_id: "part-1", identifier: "MT-P1", state: "Todo"}} = state.forced_parts

      {state, log} = dispatch_with_log(candidates, state)

      assert %{forced: true} = state.running["part-1"]
      assert log =~ ~r/Dispatching issue to agent: issue_id=part-1 .* slot=forced forced=true/
      refute Map.has_key?(state.running, "epic-1")
      assert [%{issue_id: "part-2", reason: "work slots full", forced: false}] = snapshot_of(state).slot_waiting

      # No label is written on a sub-ticket.
      assert Enum.all?(tracked_issues(), &(&1.id == "epic-1" or &1.labels == []))

      # The next poll keeps the running part as the parent's, so the second waits for a normal slot
      # though the forced allowance has room.
      state = plan_poll(state, candidates)
      assert %{"epic-1" => %{issue_id: "part-1"}} = state.forced_parts
      state = Orchestrator.dispatch_chosen_issues_for_test(candidates, state)
      refute Map.has_key?(state.running, "part-2")

      assert [%{issue_id: "epic-1", sub_issue: %{issue_id: "part-1", identifier: "MT-P1"}, waiting_on_human: false}] =
               snapshot_of(state).forced
    end

    test "keeps a sub-ticket in Auto Review as its part, from its link when Auto Review is not active, and forces no other meanwhile", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1, forced_max: 2)
      in_review = issue("part-1", "MT-P1", "Auto Review", priority: 4)
      next = issue("part-2", "MT-P2", "Todo", priority: 1)
      parent = parent([in_review, next])
      candidates = [parent, next, in_review]
      tracked(candidates)

      # Its run opened the PR, so it does not dispatch from Auto Review.
      state =
        %{
          orchestrator_state(1)
          | forced: %{"epic-1" => queue_entry(parent, ~U[2026-10-04 06:00:00Z])},
            completed_run_metadata: %{"part-1" => %{pr_url: "https://github.com/example/repo/pull/7"}}
        }
        |> run(issue("impl-1", "MT-1", "In Progress"), :implementation)
        |> plan_poll(candidates)

      assert %{"epic-1" => %{issue_id: "part-1", identifier: "MT-P1", state: "Auto Review"}} = state.forced_parts

      state = Orchestrator.dispatch_chosen_issues_for_test(candidates, state)
      refute Map.has_key?(state.running, "part-1")
      refute Map.has_key?(state.running, "part-2")
      assert [%{issue_id: "part-2", reason: "work slots full", forced: false}] = snapshot_of(state).slot_waiting
      assert [%{issue_id: "epic-1", sub_issue: %{issue_id: "part-1", state: "Auto Review"}}] = snapshot_of(state).forced

      # Without Auto Review among the active states, its sub-issue link still names it.
      state = plan_poll(state, [parent, next])
      assert %{"epic-1" => %{issue_id: "part-1", identifier: "MT-P1", state: "Auto Review"}} = state.forced_parts
    end

    test "follows blocked-by order between sub-tickets, then forces the Final verification sub-ticket", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      first = issue("part-1", "MT-P1", "Todo", priority: 4)
      second = issue("part-2", "MT-P2", "Todo", priority: 1, blocked_by: [link(first)])
      verify = issue("verify-1", "MT-V", "Todo", title: "Final verification: Export", blocked_by: [link(first), link(second)])
      candidates = [parent([first, second, verify]), first, second, verify]
      tracked(candidates)

      full = run(orchestrator_state(1), issue("impl-1", "MT-1", "In Progress"), :implementation)
      state = full |> plan_poll(candidates) |> then(&Orchestrator.dispatch_chosen_issues_for_test(candidates, &1))

      assert %{forced: true} = state.running["part-1"]
      refute Map.has_key?(state.running, "part-2")

      # The first part lands: the second is unblocked and becomes the parent's part.
      done = %{first | state: "Done"}
      second = %{second | blocked_by: [link(done)]}
      verify = %{verify | blocked_by: [link(done), link(second)]}
      candidates = [parent([done, second, verify]), second, verify]
      tracked(candidates)

      state = %{state | running: Map.delete(state.running, "part-1"), claimed: MapSet.delete(state.claimed, "part-1")}
      state = state |> plan_poll(candidates) |> then(&Orchestrator.dispatch_chosen_issues_for_test(candidates, &1))

      assert %{"epic-1" => %{issue_id: "part-2"}} = state.forced_parts
      assert %{forced: true} = state.running["part-2"]
      refute Map.has_key?(state.running, "verify-1")

      # Once every other sub-ticket is Done, the Final verification sub-ticket is forced the same way.
      second = %{second | state: "Done"}
      verify = %{verify | blocked_by: [link(done), link(second)]}
      candidates = [parent([done, second, verify]), verify]
      tracked(candidates)

      state = %{state | running: Map.delete(state.running, "part-2"), claimed: MapSet.delete(state.claimed, "part-2")}
      state = state |> plan_poll(candidates) |> then(&Orchestrator.dispatch_chosen_issues_for_test(candidates, &1))

      assert %{forced: true} = state.running["verify-1"]
    end

    test "starts its close-out run on the forced allowance once every sub-ticket is terminal", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      parent = parent([issue("part-1", "MT-P1", "Done"), issue("part-2", "MT-P2", "Canceled")])
      tracked([parent])

      state = orchestrator_state(1) |> run(issue("impl-1", "MT-1", "In Progress"), :implementation) |> plan_poll([parent])
      assert state.forced_parts == %{}

      {state, log} = dispatch_with_log([parent], state)

      assert %{forced: true} = state.running["epic-1"]
      assert log =~ ~r/issue_id=epic-1 .* slot=forced forced=true/
    end

    test "in In Review is left there, shown as waiting on a human, and forces none of its Backlog sub-tickets", ctx do
      write_forced_workflow!(ctx)
      backlog = issue("part-1", "MT-P1", "Backlog")
      parent = %{parent([backlog]) | state: "In Review"}
      tracked([parent, backlog])

      state = %{orchestrator_state(10) | forced: %{"epic-1" => queue_entry(parent, ~U[2026-10-04 06:00:00Z])}}
      state = plan_poll(state, [parent, backlog])
      state = Orchestrator.dispatch_chosen_issues_for_test([parent, backlog], state)

      assert state.forced_parts == %{}
      assert state.running == %{}
      assert [%{state: "In Review", labels: ["breakdown", "expedite"]}, %{state: "Backlog", labels: []}] = tracked_issues()
      assert [%{issue_id: "epic-1", waiting_on_human: true, sub_issue: nil}] = snapshot_of(state).forced
    end

    test "queues its sub-ticket in the parent's place when the forced allowance is taken", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      :ok = Notifications.subscribe()
      holder = issue("forced-1", "MT-F1", "In Progress", forced: true)
      part = issue("part-1", "MT-P1", "Todo")
      parent = parent([part])
      candidates = [parent, part]
      tracked(candidates)

      queue = %{
        "forced-1" => queue_entry(holder, ~U[2026-10-04 06:00:00Z]),
        "epic-1" => queue_entry(parent, ~U[2026-10-04 07:00:00Z])
      }

      state =
        %{orchestrator_state(1) | forced: queue}
        |> run(holder, :implementation, forced: true)
        |> run(issue("impl-1", "MT-1", "In Progress"), :implementation)
        |> plan_poll(candidates)

      {state, log} = dispatch_with_log(candidates, state)

      refute Map.has_key?(state.running, "part-1")
      assert %{reason: "queued #2; forced slot taken by MT-F1"} = state.slot_waiting["part-1"]
      assert log =~ "Forced ticket waiting: issue_id=part-1"
      assert_receive {:notification_event, %Notifications.Event{event: "forced_waiting", issue_identifier: "MT-P1"}}
      assert [%{issue_id: "part-1", forced: true}] = snapshot_of(state).slot_waiting

      # The next poll keeps it noted, so it is not announced again.
      state = plan_poll(state, candidates)
      assert MapSet.member?(state.forced_waiting_noted, "part-1")
    end

    test "a part waiting on a retry shows as forced, and keeps its place in a usage limit canary pick", ctx do
      write_forced_workflow!(ctx)
      part = issue("part-1", "MT-P1", "In Progress")
      plain = issue("plain-1", "MT-1", "In Progress", priority: 1)
      parent = parent([part])
      due_at_ms = System.monotonic_time(:millisecond)
      held = fn issue -> %{attempt: 1, identifier: issue.identifier, title: issue.title, repo_key: "default", usage_limit_key: @anthropic, due_at_ms: due_at_ms} end

      state =
        %{
          orchestrator_state(1)
          | usage_limits: %{@anthropic => hold(:paused)},
            retry_attempts: %{"plain-1" => held.(plain), "part-1" => held.(part)},
            claimed: MapSet.new(["plain-1", "part-1"]),
            forced_parts: %{"epic-1" => %{issue_id: "part-1", identifier: "MT-P1", state: "In Progress"}}
        }
        |> plan_poll([parent, part, plain])

      assert %{"epic-1" => %{issue_id: "part-1"}} = state.forced_parts
      retrying = Enum.sort_by(snapshot_of(state).retrying, & &1.issue_id)
      assert [%{issue_id: "part-1", forced: true}, %{issue_id: "plain-1", forced: false}] = retrying

      state = Orchestrator.start_usage_limit_canary_for_test(state, @anthropic, fn _ids -> {:ok, [plain, part]} end)
      assert %{phase: :canary, canary_issue_id: "part-1"} = state.usage_limits[@anthropic]
    end

    test "is not forced through a re-plan's sub-tickets, and forcing a sub-ticket forces only that one", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      forced_part = issue("part-1", "MT-P1", "Todo", forced: true)
      other = issue("part-2", "MT-P2", "Todo")
      plain_parent = %{parent([forced_part, other]) | labels: ["breakdown"]}
      replanning = %{parent([other]) | id: "epic-2", identifier: "MT-EPIC2", state: "Rework"}
      candidates = [plain_parent, replanning, forced_part, other]
      tracked(candidates)

      state = orchestrator_state(1) |> run(issue("impl-1", "MT-1", "In Progress"), :implementation) |> plan_poll([nil | candidates])
      assert state.forced_parts == %{}

      state = Orchestrator.dispatch_chosen_issues_for_test([forced_part, other], state)
      assert %{forced: true} = state.running["part-1"]
      refute Map.has_key?(state.running, "part-2")
    end
  end

  describe "the gates a forced ticket still respects" do
    test "a blocked-by link and a paused usage limit hold it; a headroom hold does not", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      blocked = %{issue("forced-1", "MT-F1", "Todo", forced: true) | blocked_by: [%{id: "b", identifier: "MT-B", state: "In Progress"}]}
      forced = issue("forced-2", "MT-F2", "Todo", forced: true)
      tracked([blocked, forced])

      state = Orchestrator.dispatch_chosen_issues_for_test([blocked], orchestrator_state(1))
      assert state.running == %{}

      paused = %{orchestrator_state(1) | usage_limits: %{@anthropic => hold(:paused)}}
      refute Orchestrator.should_dispatch_issue_for_test(forced, paused)
      headroom = %{paused | usage_limits: %{@anthropic => hold(:headroom)}}
      refute Orchestrator.should_dispatch_issue_for_test(issue("todo-1", "MT-TODO", "Todo"), headroom)

      state = Orchestrator.dispatch_chosen_issues_for_test([forced], headroom)
      assert %{forced: true} = state.running["forced-2"]
    end

    test "on the retry path a forced continuation starts with the slots full, and an operator pause still holds it", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      forced = issue("forced-1", "MT-F1", "In Progress", forced: true)
      tracked([forced])

      full = run(%{orchestrator_state(1) | claimed: MapSet.new(["forced-1"])}, issue("impl-1", "MT-1", "In Progress"), :implementation)
      metadata = %{identifier: "MT-F1", repo_key: "default", continuation: true}
      fetcher = fn ["forced-1"] -> {:ok, [forced]} end

      retry_forced = &Orchestrator.handle_retry_issue_for_test(&1, "forced-1", 1, metadata, fetcher)

      paused = %{full | pause: %{paused: true, reason: "maintenance", paused_at: DateTime.utc_now()}}
      {:noreply, held} = retry_forced.(paused)
      assert %{error: "dispatch paused by operator"} = held.retry_attempts["forced-1"]
      Process.cancel_timer(held.retry_attempts["forced-1"].timer_ref)

      log = capture_log(fn -> send(self(), {:result, retry_forced.(full)}) end)
      assert_received {:result, {:noreply, state}}

      assert %{forced: true, retry_attempt: 1} = state.running["forced-1"]
      assert log =~ ~r/issue_id=forced-1 .* slot=forced forced=true/
    end

    test "a waiting forced retry shows as forced in the snapshot" do
      state = %{
        orchestrator_state(1)
        | forced: %{"forced-1" => queue_entry(issue("forced-1", "MT-F1", "Todo", forced: true), ~U[2026-10-04 06:00:00Z])},
          retry_attempts: %{"forced-1" => %{attempt: 2, due_at_ms: System.monotonic_time(:millisecond), identifier: "MT-F1"}},
          merging_ci_waits: %{
            "land-1" => %{
              identifier: "MT-LAND",
              title: "Land",
              repo_key: nil,
              pull_request_url: nil,
              commit_sha: "abc",
              since: DateTime.utc_now()
            }
          }
      }

      snapshot = snapshot_of(state)
      assert [%{issue_id: "forced-1", forced: true}] = snapshot.retrying
      assert [%{issue_id: "land-1", forced: false}] = snapshot.slot_waiting
    end

    test "a held forced retry is chosen as the usage limit canary", ctx do
      write_forced_workflow!(ctx)
      plain = issue("plain-1", "MT-1", "In Progress", priority: 1)
      forced = issue("forced-1", "MT-2", "Todo", forced: true, priority: 4)

      held = fn issue -> %{attempt: 1, identifier: issue.identifier, title: issue.title, repo_key: "default", usage_limit_key: @anthropic} end

      state = %{
        orchestrator_state(1)
        | usage_limits: %{@anthropic => hold(:paused)},
          retry_attempts: %{"plain-1" => held.(plain), "forced-1" => held.(forced)}
      }

      state = Orchestrator.start_usage_limit_canary_for_test(state, @anthropic, fn _ids -> {:ok, [plain, forced]} end)

      assert %{phase: :canary, canary_issue_id: "forced-1"} = state.usage_limits[@anthropic]
      assert Map.has_key?(state.slot_waiting, "forced-1")
    end
  end

  describe "the forced snapshot" do
    test "a forced Todo started with every slot busy shows implementation · running, then waits for a human in In Review", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      :ok = Notifications.subscribe()
      forced = issue("forced-1", "MT-F1", "Todo", forced: true)
      tracked([forced])

      state = run(orchestrator_state(1), issue("impl-1", "MT-1", "In Progress"), :implementation)
      state = Orchestrator.apply_forced_poll_result_for_test(state, {"default", {:ok, [forced]}}, [], {:ok, []})
      state = Orchestrator.dispatch_chosen_issues_for_test([forced], state)

      snapshot = snapshot_of(state)
      assert [%{issue_id: "forced-1", phase: :implementation, running: true, waiting_on: nil, blockers: [], stale: false}] = snapshot.forced
      assert %{forced: true} = Enum.find(snapshot.running, &(&1.issue_id == "forced-1"))

      # The run opens its PR and the ticket reaches In Review: a human gate, noticed once.
      in_review = %{forced | state: "In Review"}
      state = %{state | running: Map.delete(state.running, "forced-1")}
      state = refresh(state, [in_review])

      assert [%{phase: :waiting_for_human, running: false, waiting_on: :human, waiting_on_human: true}] =
               snapshot_of(state).forced

      assert_receive {:notification_event, %Notifications.Event{event: "forced_human_gate", issue_identifier: "MT-F1", reason: "MT-F1 is waiting for your review"}}
      assert %{human_gate_notified_at: %DateTime{}} = RunStore.get_forced("default")["forced-1"]

      state = refresh(state, [in_review])
      refute_receive {:notification_event, %Notifications.Event{event: "forced_human_gate"}}, 50

      # Sent back for rework, it is noticed again the next time it reaches In Review.
      state = refresh(state, [%{forced | state: "Rework"}])
      assert [%{phase: :rework, waiting_on: nil}] = snapshot_of(state).forced
      refute Map.has_key?(state.forced["forced-1"], :human_gate_notified_at)

      refresh(state, [in_review])
      assert_receive {:notification_event, %Notifications.Event{event: "forced_human_gate", issue_identifier: "MT-F1"}}
    end

    test "says what each waiting forced ticket waits on", ctx do
      write_forced_workflow!(ctx)
      blockers = [%{id: "b", identifier: "MT-X", state: "In Progress"}, %{id: "c", identifier: nil, state: nil}]
      blocked = %{issue("blocked-1", "MT-B1", "Todo", forced: true) | blocked_by: blockers}
      backlog = issue("backlog-1", "MT-BL", "Backlog", forced: true)
      waiting = issue("slot-1", "MT-S1", "Todo", forced: true)
      merging = issue("merge-1", "MT-M1", "Merging", forced: true)
      reviewing = issue("qa-1", "MT-Q1", "Auto Review", forced: true)
      issues = [blocked, backlog, waiting, merging, reviewing]
      tracked(issues)

      queue = issues |> Enum.with_index() |> Map.new(fn {issue, index} -> {issue.id, queue_entry(issue, DateTime.add(~U[2026-10-04 06:00:00Z], index))} end)

      state =
        %{
          orchestrator_state(1)
          | forced: queue,
            slot_waiting: %{
              "slot-1" => %{identifier: "MT-S1", title: "Slot", state: "Todo", reason: "work slots full", attempt: nil, since: DateTime.utc_now()}
            },
            merging_ci_waits: %{
              "merge-1" => %{
                identifier: "MT-M1",
                title: "Land",
                repo_key: nil,
                pull_request_url: nil,
                commit_sha: "abc",
                since: DateTime.utc_now()
              }
            }
        }
        |> refresh(issues)

      assert [
               %{issue_id: "blocked-1", phase: :implementation, waiting_on: :blocker, blockers: ["MT-X", "an unknown issue"]},
               %{issue_id: "backlog-1", phase: :implementation, waiting_on: :backlog, waiting_on_human: true},
               %{issue_id: "slot-1", phase: :implementation, waiting_on: :slot},
               %{issue_id: "merge-1", phase: :waiting_on_ci, waiting_on: :ci},
               %{issue_id: "qa-1", phase: :auto_review, waiting_on: nil}
             ] = snapshot_of(state).forced

      paused = %{state | pause: %{paused: true, reason: "maintenance", paused_at: DateTime.utc_now()}}
      assert %{waiting_on: :paused} = Enum.find(snapshot_of(paused).forced, &(&1.issue_id == "slot-1"))

      held = %{state | usage_limits: %{@anthropic => hold(:paused)}}
      assert %{waiting_on: :usage_limit} = Enum.find(snapshot_of(held).forced, &(&1.issue_id == "slot-1"))

      # Before a poll has seen it (just after a restart), what the queue recorded is used.
      restored = %{orchestrator_state(1) | forced: %{"slot-1" => queue_entry(%{waiting | state: "In Review"}, ~U[2026-10-04 06:00:00Z])}}
      assert [%{phase: :waiting_for_human, waiting_on: :human}] = snapshot_of(restored).forced
    end

    test "a forced parent's phase is its current part's", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      part = issue("part-1", "MT-P1", "Todo")
      parent = parent([part])
      candidates = [parent, part]
      tracked(candidates)

      state = %{orchestrator_state(1) | forced: %{"epic-1" => queue_entry(parent, ~U[2026-10-04 06:00:00Z])}} |> plan_poll(candidates)
      state = Orchestrator.apply_forced_poll_result_for_test(state, {"default", {:ok, candidates}}, ["epic-1"], {:ok, [parent]})
      assert Map.keys(state.forced_issues) |> Enum.sort() == ["epic-1", "part-1"]

      assert [%{issue_id: "epic-1", sub_issue: %{issue_id: "part-1"}, phase: :implementation, running: false, waiting_on: nil}] =
               snapshot_of(state).forced

      state = run(state, part, :review_feedback, forced: true)
      assert [%{phase: :review_feedback, running: true}] = snapshot_of(state).forced
    end
  end

  describe "forced notices" do
    test "a ticket forced past forced_stale_after_hours is marked stale and noticed once", ctx do
      write_forced_workflow!(ctx, forced_stale_after_hours: 72)
      :ok = Notifications.subscribe()
      now = ~U[2026-10-04 06:00:00Z]
      forced = issue("forced-1", "MT-F1", "In Progress", forced: true)
      queue = %{"forced-1" => queue_entry(forced, DateTime.add(now, -71 * 3_600))}
      state = %{orchestrator_state(1) | forced: queue, clock: fn -> now end}

      # Not yet stale; the ticket is not observed by this poll, so the queue's record is used.
      state = Orchestrator.apply_forced_poll_result_for_test(state, :not_due, [], {:ok, []})
      assert [%{stale: false}] = snapshot_of(state).forced
      refute_receive {:notification_event, %Notifications.Event{event: "forced_stale"}}, 50

      state = %{state | clock: fn -> DateTime.add(now, 3_600 + 60) end}

      log =
        capture_log(fn ->
          send(self(), {:state, Orchestrator.apply_forced_poll_result_for_test(state, :not_due, [], {:ok, []})})
        end)

      assert_received {:state, state}
      assert log =~ "Forced ticket stale: issue_id=forced-1 issue_identifier=MT-F1"
      assert_receive {:notification_event, %Notifications.Event{event: "forced_stale", issue_identifier: "MT-F1", reason: "forced for 3d 0h, past forced_stale_after_hours=72"}}
      assert [%{stale: true, forced_for_seconds: 259_260}] = snapshot_of(state).forced
      assert %{stale_notified_at: %DateTime{}} = RunStore.get_forced("default")["forced-1"]

      Orchestrator.apply_forced_poll_result_for_test(state, :not_due, ["forced-1"], {:ok, [forced]})
      refute_receive {:notification_event, %Notifications.Event{event: "forced_stale"}}, 50
    end

    test "a forced parent whose plan reaches In Review is noticed as waiting for review", ctx do
      write_forced_workflow!(ctx)
      :ok = Notifications.subscribe()
      parent = %{parent([issue("part-1", "MT-P1", "Backlog")]) | state: "In Review"}
      state = %{orchestrator_state(1) | forced: %{"epic-1" => queue_entry(%{parent | state: "Todo"}, DateTime.utc_now())}}

      refresh(state, [parent])
      assert_receive {:notification_event, %Notifications.Event{event: "forced_human_gate", issue_identifier: "MT-EPIC", reason: "MT-EPIC's plan is waiting for your review"}}
    end
  end

  describe "Auto Review QA passes" do
    test "a forced QA pass holds the forced allowance, shows as forced, and a forced ticket waits behind it", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      start_supervised!({QaRunner, run_fun: fn _job, _opts -> Process.sleep(:infinity) end, forced_runs_fun: fn -> 0 end})
      settings = Config.settings!()
      settings = %{settings | auto_review: %{settings.auto_review | max_concurrent: 1}}

      qa_job = fn id, identifier, forced? ->
        %{issue: %{id: id, identifier: identifier}, record: %{}, sha: "abc", settings: settings, forced: forced?}
      end

      assert :started = QaRunner.request(qa_job.("qa-1", "MT-QA1", false))
      assert :started = QaRunner.request(qa_job.("qa-forced", "MT-QAF", true))

      forced = issue("forced-1", "MT-F1", "Todo", forced: true)
      tracked([forced])
      state = run(orchestrator_state(1), issue("impl-1", "MT-1", "In Progress"), :implementation)

      {state, log} = dispatch_with_log([forced], state)

      refute Map.has_key?(state.running, "forced-1")
      assert %{reason: "forced slot taken by MT-QAF (QA)"} = state.slot_waiting["forced-1"]
      assert log =~ "Forced ticket waiting: issue_id=forced-1 issue_identifier=MT-F1 forced=true forced_max=1 held_by=MT-QAF (QA)"

      assert %{
               qa: %{
                 running: [%{issue_id: "qa-1", forced: false}, %{issue_id: "qa-forced", identifier: "MT-QAF", sha: "abc", forced: true}],
                 queued: []
               }
             } = snapshot_of(state)

      # In the forced section the running pass is Auto Review, running; a queued one waits on a slot.
      assert :busy = QaRunner.request(qa_job.("qa-2", "MT-QA2", false))
      in_auto_review = fn id, identifier -> queue_entry(issue(id, identifier, "Auto Review"), ~U[2026-10-04 06:00:00Z]) end
      state = %{state | forced: %{"qa-forced" => in_auto_review.("qa-forced", "MT-QAF"), "qa-2" => in_auto_review.("qa-2", "MT-QA2")}}

      assert [
               %{issue_id: "qa-2", phase: :auto_review, running: false, waiting_on: :slot},
               %{issue_id: "qa-forced", phase: :auto_review, running: true}
             ] = Enum.sort_by(snapshot_of(state).forced, & &1.issue_id)
    end

    test "an unreachable QA runner counts no forced passes" do
      dying = spawn(fn -> receive do: (_message -> exit(:boom)) end)
      Process.register(dying, QaRunner)

      assert %{qa: %{running: [], queued: []}} = snapshot_of(orchestrator_state(1))
      refute Process.alive?(dying)
    end

    test "a forced Final verification walkthrough starts on the forced allowance with the slots full", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      verify = issue("verify-1", "MT-V", "Todo", forced: true, title: "Final verification: Export")
      tracked([verify])
      state = run(orchestrator_state(1), issue("impl-1", "MT-1", "In Progress"), :implementation)

      {state, log} = dispatch_with_log([verify], state)

      assert %{forced: true} = state.running["verify-1"]
      assert log =~ ~r/Dispatching issue to agent: issue_id=verify-1 .* slot=forced forced=true/
    end
  end

  describe "a poll" do
    test "runs the dispatch pass for a forced ticket while every normal slot is full", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1, finishing_max: 1, poll_interval_ms: 600_000)
      {pid, _impl, _land} = start_full_orchestrator(ctx, :FullSlots)

      tracked(running_issues() ++ [issue("forced-1", "MT-F1", "Todo", forced: true)])

      log =
        capture_log(fn ->
          send(pid, :run_poll_cycle)
          wait_until(fn -> dispatched?(pid, "forced-1") end)
        end)

      assert log =~ ~r/Dispatching issue to agent: issue_id=forced-1 .* slot=forced forced=true/
    end

    test "dispatches a forced ticket over the daily token budget and keeps the others waiting", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 3, max_tokens_per_day: 10, poll_interval_ms: 600_000)
      {pid, _impl, _land} = start_full_orchestrator(ctx, :DailyBudget)
      waiting = %{identifier: "MT-TODO", title: "Ticket MT-TODO", state: "Todo", reason: "work slots full", attempt: 2, since: DateTime.utc_now()}

      :sys.replace_state(pid, fn state ->
        %{state | budget_daily_used: 50, budget_day_started_on: Date.utc_today(), slot_waiting: %{"todo-1" => waiting}}
      end)

      tracked(running_issues() ++ [issue("forced-1", "MT-F1", "Todo", forced: true), issue("todo-1", "MT-TODO", "Todo")])

      log =
        capture_log(fn ->
          send(pid, :run_poll_cycle)
          wait_until(fn -> dispatched?(pid, "forced-1") end)
        end)

      assert log =~ "Daily token budget exhausted daily_used=50 daily_limit=10; dispatched forced ticket anyway: issue_id=forced-1"
      state = :sys.get_state(pid)
      refute Map.has_key?(state.running, "todo-1")
      assert %{attempt: 2} = state.slot_waiting["todo-1"]
    end
  end

  test "a headroom hold lets a forced ticket's run through" do
    entry = hold(:headroom)
    profile = %{provider: "anthropic", model: "claude-opus-5-5", kind: :implementation}

    assert UsageLimit.holds?(entry, profile)
    refute UsageLimit.holds?(entry, Map.put(profile, :forced, true))
    assert UsageLimit.holds?(hold(:paused), Map.put(profile, :forced, true))
  end

  defp start_full_orchestrator(_ctx, name) do
    tracked([])
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, name))

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    wait_until(fn ->
      state = :sys.get_state(pid)
      poll_idle? = not state.poll_check_in_progress and is_nil(state.repo_poll_task_ref)
      poll_idle? and is_nil(state.startup_workspace_lifecycle_task_ref)
    end)

    [impl, land] = running_issues()

    :sys.replace_state(pid, fn state ->
      state
      |> run(impl, :implementation, pid: spawn_idle())
      |> run(land, :landing, pid: spawn_idle())
      |> Map.put(:repo_poll_due_at_ms, %{})
    end)

    {pid, impl, land}
  end

  defp running_issues, do: [issue("impl-1", "MT-1", "In Progress"), issue("land-1", "MT-LAND", "Merging")]

  defp spawn_idle, do: spawn(fn -> receive do: (:stop -> :ok) end)

  defp dispatched?(pid, issue_id) do
    state = :sys.get_state(pid)
    Map.has_key?(state.running, issue_id) or Map.has_key?(state.retry_attempts, issue_id) or MapSet.member?(state.completed, issue_id)
  end

  defp wait_until(fun, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline, do: flunk("condition not met in time")
      Process.sleep(25)
      do_wait_until(fun, deadline)
    end
  end

  defp hold(phase) do
    now = DateTime.utc_now()

    %{
      provider: "anthropic",
      scope: :all,
      reason: "claude_usage_limit",
      window: "five_hour",
      phase: phase,
      since: now,
      resets_at: DateTime.add(now, 3_600),
      resume_at: DateTime.add(now, 3_600),
      canary_issue_id: nil
    }
  end

  defp parent(sub_issues) do
    issue("epic-1", "MT-EPIC", @waiting, title: "Export", labels: ["breakdown", "expedite"], sub_issues: Enum.map(sub_issues, &link/1))
  end

  defp link(%Issue{} = issue), do: %{id: issue.id, identifier: issue.identifier, state: issue.state}

  # A poll that refreshes the queued forced tickets by id.
  defp refresh(state, issues), do: Orchestrator.apply_forced_poll_result_for_test(state, :not_due, Map.keys(state.forced), {:ok, issues})

  defp plan_poll(state, candidates) do
    state
    |> Orchestrator.put_epic_lanes_for_test(candidates)
    |> Orchestrator.put_forced_parts_for_test(candidates)
  end

  defp queue_entry(%Issue{} = issue, forced_since) do
    %{identifier: issue.identifier, title: issue.title, state: issue.state, repo_key: nil, forced_since: forced_since}
  end

  defp write_forced_workflow!(ctx, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          tracker_active_states: @active_states,
          tracker_terminal_states: ["Done", "Canceled"],
          workspace_root: Path.join(ctx.test_root, "workspaces"),
          agent_kind: "claude",
          agent_command: ctx.fake_claude,
          max_turns: 1,
          quality_gate: %{enabled: false}
        ],
        overrides
      )
    )
  end

  defp dispatch_with_log(issues, state) do
    log = capture_log(fn -> send(self(), {:state, Orchestrator.dispatch_chosen_issues_for_test(issues, state)}) end)
    assert_received {:state, state}
    {state, log}
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
  defp tracked_issues, do: Application.get_env(:symphony_elixir, :memory_tracker_issues)

  defp dispatch_order(log) do
    ~r/Dispatching issue to agent: issue_id=(\S+)/
    |> Regex.scan(log, capture: :all_but_first)
    |> List.flatten()
  end

  defp snapshot_of(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
  end

  defp issue(id, identifier, state, attrs \\ []) do
    {forced?, attrs} = Keyword.pop(attrs, :forced, false)

    struct!(
      %Issue{
        id: id,
        identifier: identifier,
        title: "Ticket #{identifier}",
        description: "Finish it",
        state: state,
        priority: 3,
        team: %{key: "Test"},
        labels: if(forced?, do: ["expedite"], else: []),
        url: "https://example.org/issues/#{identifier}"
      },
      attrs
    )
  end

  defp run(state, %Issue{} = issue, kind, opts \\ []) do
    entry = %{
      pid: Keyword.get(opts, :pid, self()),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      run_profile: %{kind: kind, model: nil, effort: nil, provider: "anthropic"},
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      forced: Keyword.get(opts, :forced, false),
      started_at: DateTime.utc_now()
    }

    %{state | running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)}
  end

  defp orchestrator_state(max_total) do
    %Orchestrator.State{
      repo_key: "default",
      max_concurrent_agents: max_total,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
