defmodule SymphonyElixir.OrchestratorDispatchSourceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.Shadow
  alias SymphonyElixir.TicketObservation
  alias SymphonyElixirWeb.ObservabilityPubSub

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

  defp set_source(source) do
    write_workflow_file!(Workflow.workflow_file_path())
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

    test "a record change outside the poll asks for a cycle of its repo at once", ctx do
      set_source("record")
      :ok = ObservabilityPubSub.subscribe_ticket_records()
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [issue(ctx.repo_key, 1)], 0)

      # The poll's own writes are not announced: the cycle that made them dispatches from them.
      issue_id = "#{ctx.repo_key}-1"
      refute_received {:ticket_record, _repo_key, ^issue_id, :changed}

      # The PR and CI watcher reads a priority change: the record announces it.
      changed = issue(ctx.repo_key, 1, priority: 2, updated_at: DateTime.add(@linear_at, 60))
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, changed, source: :watcher)
      assert_receive {:ticket_record, repo_key, ^issue_id, :changed} = message
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

  describe "dispatch.source: poll" do
    test "dispatch reads the poll cache, and a record change waits for the repo's poll", ctx do
      set_source("poll")
      {_buckets, state} = cycle(orchestrator_state(), ctx.repos, [issue(ctx.repo_key, 1), issue(ctx.repo_key, 2)], 0)

      :ok = RunStore.delete_ticket_state(ctx.repo_key, "#{ctx.repo_key}-2")
      {:ok, :updated} = TicketObservation.observe(ctx.repo_key, issue(ctx.repo_key, 3), source: :watcher)

      {%{dispatchable: dispatchable}, state} = capture_cycle(state, ctx.repos, 50)
      assert identifiers(dispatchable) == ["ACME-1", "ACME-2"]

      message = {:ticket_record, ctx.repo_key, "#{ctx.repo_key}-3", :changed}
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

  # A cycle with no repo due, whose shadow differences are logged.
  defp capture_cycle(state, repos, now_ms) do
    {result, _log} = with_log(fn -> cycle(state, repos, [], now_ms) end)
    result
  end
end
