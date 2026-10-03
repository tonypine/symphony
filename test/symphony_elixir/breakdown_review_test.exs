defmodule SymphonyElixir.BreakdownReviewTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{BreakdownReview, SubIssueWait}
  alias SymphonyElixir.Linear.Adapter

  @waiting "Waiting on sub-tickets"
  @planned ~U[2026-10-02 09:00:00Z]
  @approved ~U[2026-10-02 10:00:00Z]
  @later ~U[2026-10-02 11:00:00Z]

  defmodule CancelTracker do
    def update_issue_state(issue_id, state) do
      send(self(), {:cancel_attempt, issue_id, state})
      Map.get(Process.get(:cancel_results, %{}), state, :ok)
    end
  end

  defmodule HistoryClient do
    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})
      Process.get(:history_client_result)
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    SubIssueWait.reset_for_test(@waiting)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    :ok
  end

  describe "action/2" do
    test "promotes in the waiting state, replaces in Rework, and needs Backlog sub-issues" do
      settings = Config.settings!()
      parent = parent(@waiting, [sub("c1", "Backlog"), sub("c2", "Todo")])

      assert BreakdownReview.action(parent, settings) == :promote
      assert BreakdownReview.action(%{parent | state: "Rework"}, settings) == :replace
      assert BreakdownReview.action(%{parent | sub_issues: [sub("c2", "Todo")]}, settings) == nil
      assert BreakdownReview.action(%{parent | state: "In Review"}, settings) == nil
      assert BreakdownReview.action(%{parent | labels: ["feature"]}, settings) == nil
      assert BreakdownReview.action(%{parent | sub_issues: nil}, settings) == nil
      assert BreakdownReview.action(nil, settings) == nil

      assert BreakdownReview.backlog_sub_issue_ids(%{parent | sub_issues: [%{id: nil, state: "Backlog"}, sub("c1", " backlog ")]}) ==
               ["c1"]
    end
  end

  describe "sub_issues_to_move/3" do
    test "an approval promotes the sub-issues in Backlog since before it" do
      history =
        history([approval()], [
          history_sub("c1", "Backlog"),
          history_sub("c2", "Backlog", state_changed_at: @planned),
          # Moved back to Backlog after the approval, as a final verification run with gaps does.
          history_sub("c3", "Backlog", state_changed_at: @later),
          # Created after the approval.
          history_sub("c4", "Backlog", created_at: @later),
          history_sub("c5", "Todo"),
          history_sub("c6", "Backlog", created_at: nil),
          history_sub(nil, "Backlog")
        ])

      assert ids(BreakdownReview.sub_issues_to_move(:promote, history, Config.settings!())) == ["c1", "c2"]
    end

    test "only an In Review to waiting-state move is an approval, and only as the latest state change" do
      settings = Config.settings!()
      subs = [history_sub("c1", "Backlog", created_at: ~U[2026-10-01 00:00:00Z])]

      # Symphony parking an In Progress parent approves nothing.
      parked = history([change("In Progress", @waiting, @approved)], subs)
      assert BreakdownReview.sub_issues_to_move(:promote, parked, settings) == []
      assert BreakdownReview.sub_issues_to_move(:promote, history([], subs), settings) == []

      # The latest change wins, whatever order Linear returns them in.
      reviewed_again = [change("In Review", @waiting, @planned), change(@waiting, "In Review", @approved), approval(@later)]
      approved = history(Enum.reverse(reviewed_again), subs)
      assert ids(BreakdownReview.sub_issues_to_move(:promote, approved, settings)) == ["c1"]
      assert BreakdownReview.sub_issues_to_move(:promote, history(Enum.take(reviewed_again, 2), subs), settings) == []

      no_waiting_state = %{settings | tracker: %{settings.tracker | waiting_on_sub_issues_state: nil}}
      assert BreakdownReview.sub_issues_to_move(:promote, history([approval()], subs), no_waiting_state) == []
    end

    test "a rejection replaces the sub-issues in Backlog since before the move to Rework" do
      history =
        history([change("In Review", "Rework", @approved)], [
          history_sub("c1", "Backlog"),
          # Created by the re-plan.
          history_sub("c2", "Backlog", created_at: @later),
          history_sub("c3", "In Progress")
        ])

      assert ids(BreakdownReview.sub_issues_to_move(:replace, history, Config.settings!())) == ["c1"]
      approved = %{history | state_changes: [approval()]}
      assert BreakdownReview.sub_issues_to_move(:replace, approved, Config.settings!()) == []
    end
  end

  describe "move/3" do
    test "promotes to Todo and cancels in whichever canceled state the team has" do
      assert :ok = BreakdownReview.move(:promote, "c1", Tracker.Memory)
      assert_received {:memory_tracker_state_update, "c1", "Todo"}

      assert :ok = BreakdownReview.move(:replace, "c1", CancelTracker)
      assert_received {:cancel_attempt, "c1", "Canceled"}
      refute_received {:cancel_attempt, "c1", "Cancelled"}

      Process.put(:cancel_results, %{"Canceled" => {:error, :state_not_found}})
      assert :ok = BreakdownReview.move(:replace, "c1", CancelTracker)
      assert_received {:cancel_attempt, "c1", "Cancelled"}

      Process.put(:cancel_results, %{"Canceled" => {:error, :state_not_found}, "Cancelled" => {:error, :state_not_found}})
      assert {:error, :state_not_found} = BreakdownReview.move(:replace, "c1", CancelTracker)
      assert_received {:cancel_attempt, "c1", "Cancelled"}

      Process.put(:cancel_results, %{"Canceled" => {:error, :boom}})
      assert {:error, :boom} = BreakdownReview.move(:replace, "c1", CancelTracker)
      refute_received {:cancel_attempt, "c1", "Cancelled"}

      assert BreakdownReview.target(:promote) == "Todo"
      assert BreakdownReview.target(:replace) == "Canceled"
    end
  end

  describe "orchestrator" do
    test "approving the plan moves every Backlog sub-ticket to Todo in one poll and leaves the others alone" do
      parent =
        parent(@waiting, [sub("c1", "Backlog"), sub("c2", "Backlog"), sub("c3", "Todo"), sub("c4", "In Progress"), sub("c5", "Done")])

      put_history("parent", [approval()], [
        history_sub("c1", "Backlog"),
        history_sub("c2", "Backlog"),
        history_sub("c3", "Todo", state_changed_at: @later),
        history_sub("c4", "In Progress", state_changed_at: @later),
        history_sub("c5", "Done", state_changed_at: @later)
      ])

      log = capture_log([level: :info], fn -> send(self(), {:reviewed, review([parent], orchestrator_state())}) end)
      assert_received {:reviewed, state}

      assert_received {:memory_tracker_state_update, "c1", "Todo"}
      assert_received {:memory_tracker_state_update, "c2", "Todo"}
      refute_received {:memory_tracker_state_update, _id, _state}
      assert log =~ "Moved 2 sub-issue(s) of breakdown parent to Todo (MT-c1, MT-c2)"
      assert state.breakdown_reviews == %{"parent" => ["c1", "c2"]}

      # Re-polling the same candidate neither asks Linear again nor promotes again.
      assert_received {:memory_tracker_breakdown_history, "parent"}
      assert review([parent], state) == state
      refute_received {:memory_tracker_breakdown_history, _id}

      # Once the parent needs nothing it is forgotten.
      promoted = %{parent | sub_issues: [sub("c1", "Todo"), sub("c2", "Todo")]}
      assert review([promoted], state).breakdown_reviews == %{}
    end

    test "a sub-ticket moved back to Backlog after the approval stays there" do
      parent = parent(@waiting, [sub("c1", "Backlog"), sub("c2", "Done")])
      put_history("parent", [approval()], [history_sub("c1", "Backlog", state_changed_at: @later), history_sub("c2", "Done")])

      state = review([parent], orchestrator_state())

      assert_received {:memory_tracker_breakdown_history, "parent"}
      refute_received {:memory_tracker_state_update, _id, _state}
      assert state.breakdown_reviews == %{"parent" => ["c1"]}

      # After a restart it is read again, and still left alone.
      assert review([parent], orchestrator_state()).breakdown_reviews == state.breakdown_reviews
      refute_received {:memory_tracker_state_update, _id, _state}
    end

    test "a parent parked from In Progress, running, or in another state is not promoted" do
      parked = parent(@waiting, [sub("c1", "Backlog")])
      put_history("parent", [change("In Progress", @waiting, @approved)], [history_sub("c1", "Backlog")])

      state = review([parked, %{parked | id: "in-review", state: "In Review"}], orchestrator_state())
      refute_received {:memory_tracker_state_update, _id, _state}
      assert_received {:memory_tracker_breakdown_history, "parent"}
      refute_received {:memory_tracker_breakdown_history, "in-review"}
      assert state.breakdown_reviews == %{"parent" => ["c1"]}

      running = %{orchestrator_state() | running: %{"parent" => %{}}}
      assert review([parked], running).breakdown_reviews == %{}
      claimed = %{orchestrator_state() | claimed: MapSet.new(["parent"]), breakdown_reviews: %{"parent" => []}}
      assert review([parked], claimed).breakdown_reviews == %{"parent" => []}
      refute_received {:memory_tracker_breakdown_history, _id}
    end

    test "a failed read or move is retried on the next poll" do
      parent = parent(@waiting, [sub("c1", "Backlog")])
      Application.put_env(:symphony_elixir, :memory_tracker_breakdown_histories, {:error, :timeout})

      log = capture_log(fn -> assert review([parent], orchestrator_state()).breakdown_reviews == %{} end)
      assert log =~ "Failed to read breakdown parent history"
      assert log =~ ":timeout"

      put_history("parent", [approval()], [history_sub("c1", "Backlog")])
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :boom})

      log = capture_log(fn -> assert review([parent], orchestrator_state()).breakdown_reviews == %{} end)
      assert log =~ "Failed to move sub-issue MT-c1 of breakdown parent to Todo"
      refute log =~ "Moved"

      # With no history configured the memory tracker reports no state changes.
      Application.delete_env(:symphony_elixir, :memory_tracker_breakdown_histories)
      assert review([parent], orchestrator_state()).breakdown_reviews == %{"parent" => ["c1"]}
    end

    test "after promotion only the sub-ticket no blocked-by link holds dispatches first" do
      state = orchestrator_state()
      first = %Issue{id: "c1", identifier: "MT-c1", title: "First", state: "Todo", blocked_by: []}
      blocker = %{id: "c1", identifier: "MT-c1", state: "Todo"}
      second = %Issue{id: "c2", identifier: "MT-c2", title: "Second", state: "Todo", blocked_by: [blocker]}
      verification = %Issue{id: "c3", identifier: "MT-c3", title: "Final verification: X", state: "Todo", blocked_by: [blocker, %{blocker | id: "c2"}]}

      assert Orchestrator.should_dispatch_issue_for_test(first, state)
      refute Orchestrator.should_dispatch_issue_for_test(second, state)
      refute Orchestrator.should_dispatch_issue_for_test(verification, state)

      done = %{blocker | state: "Done"}
      assert Orchestrator.should_dispatch_issue_for_test(%{second | blocked_by: [done]}, state)
      still_blocked = %{verification | blocked_by: [done, %{done | id: "c2", state: "In Progress"}]}
      refute Orchestrator.should_dispatch_issue_for_test(still_blocked, state)
    end

    test "rejecting the plan cancels its Backlog sub-tickets before the re-plan dispatches, without touching new ones" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["Todo", "In Progress", "Rework"])

      parent = parent("Rework", [sub("c1", "Backlog"), sub("c2", "Todo"), sub("c3", "Backlog")])

      put_history("parent", [change("In Review", "Rework", @approved)], [
        history_sub("c1", "Backlog"),
        history_sub("c2", "Todo"),
        history_sub("c3", "Backlog", created_at: @later)
      ])

      # Open sub-issues hold a breakdown parent, but not one in Rework; it waits only for the cancel.
      state = orchestrator_state()
      refute Orchestrator.should_dispatch_issue_for_test(parent, state)

      log = capture_log([level: :info], fn -> send(self(), {:reviewed, review([parent], state)}) end)
      assert_received {:reviewed, state}

      assert_received {:memory_tracker_state_update, "c1", "Canceled"}
      refute_received {:memory_tracker_state_update, _id, _state}
      assert log =~ "Moved 1 sub-issue(s) of breakdown parent to Canceled (MT-c1)"
      assert Orchestrator.should_dispatch_issue_for_test(parent, state)

      # The re-plan's own sub-tickets do not hold it either.
      replanned = %{parent | sub_issues: [sub("c1", "Canceled"), sub("c2", "Todo"), sub("c3", "Backlog")]}
      no_backlog = %{replanned | sub_issues: [sub("c1", "Canceled"), sub("c2", "Todo")]}
      assert Orchestrator.should_dispatch_issue_for_test(no_backlog, orchestrator_state())

      Application.put_env(:symphony_elixir, :memory_tracker_breakdown_histories, {:error, :timeout})
      capture_log(fn -> assert review([replanned], orchestrator_state()).breakdown_reviews == %{} end)
      refute Orchestrator.should_dispatch_issue_for_test(replanned, orchestrator_state())
    end

    test "a poll cycle promotes an approved parent's sub-tickets" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %{parent(@waiting, [sub("c1", "Backlog"), sub("c2", "Done")]) | id: "parent-poll", team: %{key: "Test"}}
      ])

      put_history("parent-poll", [approval()], [history_sub("c1", "Backlog"), history_sub("c2", "Done")])

      orchestrator_name = Module.concat(__MODULE__, :ReviewOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      send(pid, :run_poll_cycle)

      assert_receive {:memory_tracker_state_update, "c1", "Todo"}, 2_000
      refute_receive {:memory_tracker_state_update, "c2", _state}, 100
    end
  end

  describe "Linear adapter" do
    setup do
      Application.put_env(:symphony_elixir, :linear_client_module, HistoryClient)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_module) end)
    end

    test "reads the parent's state changes and each sub-issue's latest state change" do
      Process.put(
        :history_client_result,
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "history" => %{
                 "nodes" => [
                   %{"createdAt" => "2026-10-02T10:00:00Z", "fromState" => %{"name" => "In Review"}, "toState" => %{"name" => @waiting}},
                   %{"createdAt" => "2026-10-02T09:30:00Z", "fromState" => nil, "toState" => nil},
                   %{"createdAt" => "not a date", "toState" => %{"name" => "Todo"}}
                 ]
               },
               "children" => %{
                 "nodes" => [
                   %{
                     "id" => "c1",
                     "identifier" => "TP-2",
                     "createdAt" => "2026-10-02T09:00:00Z",
                     "state" => %{"name" => "Backlog"},
                     "history" => %{
                       "nodes" => [
                         %{"createdAt" => "2026-10-02T09:00:00Z", "toState" => %{"name" => "Backlog"}},
                         %{"createdAt" => "2026-10-02T11:00:00Z", "toState" => %{"name" => "Backlog"}},
                         %{"createdAt" => "2026-10-02T12:00:00Z"}
                       ]
                     }
                   },
                   %{"id" => "c2", "identifier" => "TP-3", "createdAt" => nil, "state" => nil}
                 ]
               }
             }
           }
         }}
      )

      assert {:ok, history} = Adapter.fetch_breakdown_history("parent")
      assert_received {:graphql_called, query, %{id: "parent"}}
      assert query =~ "SymphonyBreakdownHistory"

      assert history.state_changes == [%{at: @approved, from: "In Review", to: @waiting}]

      assert history.sub_issues == [
               %{id: "c1", identifier: "TP-2", state: "Backlog", created_at: @planned, state_changed_at: @later},
               %{id: "c2", identifier: "TP-3", state: nil, created_at: nil, state_changed_at: nil}
             ]

      assert {:ok, %{state_changes: [], sub_issues: []}} = Tracker.fetch_breakdown_history("missing")
    end

    test "reports a missing issue and passes client errors through" do
      Process.put(:history_client_result, {:ok, %{"data" => %{"issue" => nil}}})
      assert {:error, :issue_not_found} = Adapter.fetch_breakdown_history("parent")

      Process.put(:history_client_result, {:error, :timeout})
      assert {:error, :timeout} = Adapter.fetch_breakdown_history("parent")
    end
  end

  defp review(issues, state), do: Orchestrator.review_breakdown_parents_for_test(issues, state)

  defp parent(state, sub_issues) do
    %Issue{id: "parent", identifier: "MT-1", title: "Groom into sub-tickets", state: state, labels: ["breakdown"], sub_issues: sub_issues}
  end

  defp sub(id, state), do: %{id: id, identifier: "MT-#{id}", state: state}

  defp history(changes, sub_issues), do: %{state_changes: changes, sub_issues: sub_issues}

  defp history_sub(id, state, opts \\ []) do
    %{
      id: id,
      identifier: "MT-#{id}",
      state: state,
      created_at: Keyword.get(opts, :created_at, @planned),
      state_changed_at: Keyword.get(opts, :state_changed_at)
    }
  end

  defp approval(at \\ @approved), do: change("In Review", @waiting, at)

  defp change(from, to, at), do: %{at: at, from: from, to: to}

  defp put_history(issue_id, changes, sub_issues) do
    histories = %{issue_id => history(changes, sub_issues)}
    Application.put_env(:symphony_elixir, :memory_tracker_breakdown_histories, histories)
  end

  defp ids(sub_issues), do: Enum.map(sub_issues, & &1.id)

  defp orchestrator_state do
    %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
