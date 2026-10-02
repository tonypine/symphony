defmodule SymphonyElixir.SubIssueWaitTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.SubIssueWait

  @waiting "Waiting on sub-tickets"

  defmodule StateTracker do
    def workflow_state_exists?(state_name, teams) do
      send(self(), {:workflow_state_exists?, state_name, teams})
      Process.get(:sub_issue_wait_state_result)
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    SubIssueWait.reset_for_test(@waiting)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      SubIssueWait.reset_for_test(@waiting)
      Application.delete_env(:symphony_elixir, :memory_tracker_workflow_states)
    end)

    :ok
  end

  describe "issues.states.waiting_on_sub_issues config" do
    test "defaults to Waiting on sub-tickets and counts as an active state" do
      settings = Config.settings!()

      assert settings.tracker.waiting_on_sub_issues_state == @waiting
      assert settings.tracker.active_states == ["Todo", "In Progress", @waiting]
      assert SubIssueWait.state(settings) == @waiting
      assert SubIssueWait.enabled?(settings)
    end

    test "is not listed twice when the active states already name it" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Todo", "In Progress", " waiting on sub-tickets"]
      )

      assert Config.settings!().tracker.active_states == ["Todo", "In Progress", " waiting on sub-tickets"]
    end

    test "can be renamed or turned off with null or a blank string" do
      repositories = [%{"key" => "default", "workflow" => "WORKFLOW.md"}]

      for {value, expected_state, expected_active} <- [
            {"Parked", "Parked", ["Todo", "In Progress", "Parked"]},
            {nil, nil, ["Todo", "In Progress"]},
            {" ", nil, ["Todo", "In Progress"]}
          ] do
        assert {:ok, system_config} =
                 SystemSchema.parse(%{
                   "issues" => %{"provider" => "memory", "states" => %{"waiting_on_sub_issues" => value}},
                   "repositories" => repositories
                 })

        tracker = SystemSchema.to_config_map(system_config)["tracker"]
        assert {:ok, %Schema{tracker: parsed}} = Schema.parse(%{"tracker" => tracker})
        assert parsed.waiting_on_sub_issues_state == expected_state
        assert parsed.active_states == expected_active
      end

      assert {:ok, %Schema{} = settings} = Schema.parse(%{"tracker" => %{"kind" => "memory", "waiting_on_sub_issues_state" => nil}})
      assert SubIssueWait.state(settings) == nil
      refute SubIssueWait.enabled?(settings)
      assert :skipped = SubIssueWait.check_tracker_state(settings, ["TP"], tracker: StateTracker)
      refute_received {:workflow_state_exists?, _state, _teams}
      refute SubIssueWait.in_state?(%Issue{state: @waiting}, settings)
    end

    test "rejects unknown issues.states keys" do
      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{
                 "issues" => %{"states" => %{"waiting" => "x"}},
                 "repositories" => [%{"key" => "default", "workflow" => "WORKFLOW.md"}]
               })

      assert message =~ "issues.states"
    end
  end

  describe "check_tracker_state/3" do
    test "keeps the state on when Linear has it" do
      Process.put(:sub_issue_wait_state_result, {:ok, true})
      settings = Config.settings!()

      assert :ok = SubIssueWait.check_tracker_state(settings, ["TP"], tracker: StateTracker)
      assert_received {:workflow_state_exists?, @waiting, ["TP"]}
      assert SubIssueWait.enabled?(settings)
    end

    test "turns the state off with a warning when Linear is missing it, until a later check finds it" do
      settings = Config.settings!()
      Process.put(:sub_issue_wait_state_result, {:ok, false})

      log = capture_log(fn -> assert :disabled = check(settings, ["TP", "ENG"]) end)

      assert log =~ ~s[Waiting on sub-issues state disabled: Linear state "Waiting on sub-tickets" is missing for team(s) TP, ENG]
      assert log =~ "breakdown parents stay In Progress"
      refute SubIssueWait.enabled?(settings)

      log = capture_log(fn -> assert :disabled = check(settings, []) end)
      assert log =~ ~s(Linear state "Waiting on sub-tickets" is missing; breakdown parents)

      Process.put(:sub_issue_wait_state_result, {:ok, true})
      assert :ok = SubIssueWait.check_tracker_state(settings, [], tracker: StateTracker)
      assert SubIssueWait.enabled?(settings)
    end

    test "leaves the state on when the tracker cannot be asked" do
      Process.put(:sub_issue_wait_state_result, {:error, :timeout})
      settings = Config.settings!()

      log = capture_log(fn -> assert {:error, :timeout} = check(settings, []) end)

      assert log =~ "leaving it on"
      assert SubIssueWait.enabled?(settings)
    end

    test "uses the configured tracker by default" do
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states, ["Todo", "In Progress"])

      capture_log(fn -> assert :disabled = SubIssueWait.check_tracker_state(Config.settings!(), []) end)
      refute SubIssueWait.enabled?(Config.settings!())
    end
  end

  describe "held?/3, park?/3 and the Issue helpers" do
    test "holds everything in the waiting state except a breakdown parent ready for close-out" do
      settings = Config.settings!()
      done = [%{id: "c1", identifier: "MT-2", state: "Done"}, %{id: "c2", identifier: "MT-3", state: "Cancelled"}]
      parent = %Issue{id: "p", identifier: "MT-1", title: "Parent", state: @waiting, labels: ["Breakdown"], sub_issues: done}

      refute SubIssueWait.held?(parent, ["Done", "Cancelled"], settings)
      assert Issue.close_out_ready?(parent, ["Done", "Cancelled"])

      assert SubIssueWait.held?(%{parent | sub_issues: [%{id: "c3", identifier: "MT-4", state: "Todo"}]}, ["Done"], settings)
      assert SubIssueWait.held?(%{parent | sub_issues: []}, ["Done"], settings)
      assert SubIssueWait.held?(%{parent | labels: ["feature"]}, ["Done", "Cancelled"], settings)
      refute SubIssueWait.held?(%{parent | state: "In Progress", sub_issues: []}, ["Done"], settings)
      refute SubIssueWait.held?(%{parent | state: nil}, ["Done"], settings)
      refute SubIssueWait.held?(nil, ["Done"], settings)

      refute Issue.close_out_ready?(%{parent | labels: nil}, ["Done"])
      refute Issue.breakdown?(%{parent | labels: nil})
      refute Issue.breakdown?(nil)
      refute Issue.breakdown_label?(nil)
      refute Issue.waiting_on_sub_issues?(%{parent | labels: [nil]}, ["Done"])
    end

    test "parks a breakdown parent In Progress with open sub-issues while the state is on" do
      settings = Config.settings!()
      open = [%{id: "c1", identifier: "MT-2", state: "Backlog"}]
      parent = %Issue{id: "p", identifier: "MT-1", title: "Parent", state: " in progress ", labels: ["breakdown"], sub_issues: open}

      assert SubIssueWait.park?(parent, ["Done"], settings)
      refute SubIssueWait.park?(%{parent | state: @waiting}, ["Done"], settings)
      refute SubIssueWait.park?(%{parent | state: "Todo"}, ["Done"], settings)
      refute SubIssueWait.park?(%{parent | sub_issues: [%{id: "c1", identifier: "MT-2", state: "Done"}]}, ["Done"], settings)
      refute SubIssueWait.park?(%{parent | labels: []}, ["Done"], settings)
      refute SubIssueWait.park?(%{parent | state: nil}, ["Done"], settings)
      refute SubIssueWait.park?(nil, ["Done"], settings)
    end
  end

  describe "orchestrator" do
    test "holds a breakdown parent in the waiting state until every sub-ticket is terminal, then dispatches the close-out run" do
      state = orchestrator_state()

      parent = %Issue{
        id: "parent-wait",
        identifier: "MT-1201",
        title: "Groom into sub-tickets",
        state: @waiting,
        labels: ["breakdown"],
        sub_issues: [
          %{id: "child-1", identifier: "MT-1202", state: "Done"},
          %{id: "child-2", identifier: "MT-1203", state: "In Progress"}
        ]
      }

      refute Orchestrator.should_dispatch_issue_for_test(parent, state)

      closed_out = %{parent | sub_issues: [%{id: "child-1", identifier: "MT-1202", state: "Done"}, %{id: "child-2", identifier: "MT-1203", state: "Done"}]}
      assert Orchestrator.should_dispatch_issue_for_test(closed_out, state)

      # Anything else a human puts in the waiting state is left alone.
      refute Orchestrator.should_dispatch_issue_for_test(%{closed_out | labels: ["feature"]}, state)
      refute Orchestrator.should_dispatch_issue_for_test(%{closed_out | sub_issues: []}, state)

      fetcher = fn ["parent-wait"] -> {:ok, [parent]} end
      stale = %{parent | state: "In Progress", sub_issues: []}
      assert {:skip, %Issue{}} = Orchestrator.revalidate_issue_for_dispatch_for_test(stale, fetcher)
      refute Orchestrator.dispatch_revalidated_issue_for_test(parent, true)
      assert Orchestrator.dispatch_revalidated_issue_for_test(closed_out, true)
    end

    test "moves a breakdown parent found In Progress with open sub-issues to the waiting state" do
      state = orchestrator_state()
      open = [%{id: "child-1", identifier: "MT-1302", state: "Backlog"}]
      parent = %Issue{id: "parent-park", identifier: "MT-1301", title: "Parent", state: "In Progress", labels: ["breakdown"], sub_issues: open}
      running = %{parent | id: "parent-running", identifier: "MT-1303"}
      claimed = %{parent | id: "parent-claimed", identifier: "MT-1304"}
      plain = %Issue{id: "plain", identifier: "MT-1305", title: "Work", state: "In Progress", sub_issues: open}

      state = %{state | running: %{"parent-running" => %{}}, claimed: MapSet.new(["parent-claimed"])}

      log =
        capture_log([level: :info], fn ->
          state = Orchestrator.park_breakdown_parents_for_test([parent, running, claimed, plain, nil], state)
          send(self(), {:parked_state, state})
        end)

      assert_received {:parked_state, parked_state}
      assert_received {:memory_tracker_state_update, "parent-park", @waiting}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert log =~ "Moved breakdown parent to Waiting on sub-tickets while its sub-issues are open"
      assert parked_state.parked_parents == MapSet.new(["parent-park"])

      # The cached candidate still shows it In Progress until the next repo fetch; it is not moved again.
      assert ^parked_state = Orchestrator.park_breakdown_parents_for_test([parent], parked_state)
      refute_received {:memory_tracker_state_update, _issue_id, _state}

      # Once the cache shows it parked it is forgotten, so a parent moved back by hand is parked again.
      cleared = Orchestrator.park_breakdown_parents_for_test([%{parent | state: @waiting}], parked_state)
      assert cleared.parked_parents == MapSet.new()
      assert Orchestrator.park_breakdown_parents_for_test([parent], cleared).parked_parents == MapSet.new(["parent-park"])
      assert_received {:memory_tracker_state_update, "parent-park", @waiting}

      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :boom})

      log =
        capture_log(fn ->
          assert Orchestrator.park_breakdown_parents_for_test([parent], state).parked_parents == MapSet.new()
        end)

      assert log =~ "Failed to move breakdown parent to Waiting on sub-tickets"
      assert log =~ ":boom"
    end

    test "keeps today's In Progress behaviour when the state is missing" do
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states, ["Todo", "In Progress", "Done"])
      capture_log(fn -> assert :disabled = SubIssueWait.check_tracker_state(Config.settings!(), []) end)

      state = orchestrator_state()
      open = [%{id: "child-1", identifier: "MT-1402", state: "Backlog"}]
      parent = %Issue{id: "parent-old", identifier: "MT-1401", title: "Parent", state: "In Progress", labels: ["breakdown"], sub_issues: open}

      assert Orchestrator.park_breakdown_parents_for_test([parent], state).parked_parents == MapSet.new()
      refute_received {:memory_tracker_state_update, _issue_id, _state}

      refute Orchestrator.should_dispatch_issue_for_test(parent, state)
      closed_out = %{parent | sub_issues: [%{id: "child-1", identifier: "MT-1402", state: "Done"}]}
      assert Orchestrator.should_dispatch_issue_for_test(closed_out, state)
    end

    test "a poll cycle parks a breakdown parent In Progress and does not dispatch it" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{
          id: "parent-poll",
          identifier: "MT-1501",
          title: "Groom into sub-tickets",
          state: "In Progress",
          team: %{key: "Test"},
          labels: ["breakdown"],
          sub_issues: [%{id: "child-1", identifier: "MT-1502", state: "Todo"}]
        }
      ])

      orchestrator_name = Module.concat(__MODULE__, :ParkingOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      send(pid, :run_poll_cycle)

      assert_receive {:memory_tracker_state_update, "parent-poll", @waiting}, 2_000
      assert %{running: running} = :sys.get_state(pid)
      refute Map.has_key?(running, "parent-poll")
    end
  end

  defp check(settings, teams), do: SubIssueWait.check_tracker_state(settings, teams, tracker: StateTracker)

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
