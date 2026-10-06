defmodule SymphonyElixir.SubIssueWaitTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.{RunKind, RunStore, SubIssueWait}

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
      open = [%{id: "c1", identifier: "MT-2", state: "Todo"}, %{id: "c2", identifier: "MT-3", state: "Backlog"}]
      parent = %Issue{id: "p", identifier: "MT-1", title: "Parent", state: " in progress ", labels: ["breakdown"], sub_issues: open}

      assert SubIssueWait.park?(parent, ["Done"], settings)
      assert SubIssueWait.park?(%{parent | sub_issues: [%{id: "c1", identifier: "MT-2"}]}, ["Done"], settings)
      refute SubIssueWait.park?(%{parent | state: @waiting}, ["Done"], settings)
      refute SubIssueWait.park?(%{parent | state: "Todo"}, ["Done"], settings)
      refute SubIssueWait.park?(%{parent | sub_issues: [%{id: "c1", identifier: "MT-2", state: "Done"}]}, ["Done"], settings)
      refute SubIssueWait.park?(%{parent | labels: []}, ["Done"], settings)
      refute SubIssueWait.park?(%{parent | state: nil}, ["Done"], settings)
      refute SubIssueWait.park?(nil, ["Done"], settings)
    end

    test "an issue that is not a breakdown parent waits on merge while a sub-issue is open, and closes once all are terminal" do
      settings = Config.settings!()
      terminal = ["Done", "Canceled", "Duplicate"]
      open = [%{id: "c1", identifier: "MT-2", state: "Backlog"}, %{id: "c2", identifier: "MT-3", state: "Done"}]
      issue = %Issue{id: "p", identifier: "MT-1", title: "Work", state: "Merging", labels: ["improvement"], sub_issues: open}

      assert SubIssueWait.wait_on_merge?(issue, terminal, settings)
      assert SubIssueWait.wait_on_merge?(%{issue | sub_issues: [%{id: "c1", identifier: "MT-2"}]}, terminal, settings)
      refute SubIssueWait.wait_on_merge?(%{issue | sub_issues: []}, terminal, settings)
      canceled = [%{id: "c1", identifier: "MT-2", state: "Canceled"}]
      refute SubIssueWait.wait_on_merge?(%{issue | sub_issues: canceled}, terminal, settings)
      refute SubIssueWait.wait_on_merge?(%{issue | labels: ["breakdown"]}, terminal, settings)
      refute SubIssueWait.wait_on_merge?(nil, terminal, settings)

      waiting = %{issue | state: @waiting}
      refute SubIssueWait.close?(waiting, terminal, settings)

      for finished <- ["Done", "Canceled", "Duplicate"] do
        assert SubIssueWait.close?(%{waiting | sub_issues: [%{id: "c1", identifier: "MT-2", state: finished}]}, terminal, settings)
      end

      done = %{waiting | sub_issues: [%{id: "c1", identifier: "MT-2", state: "Done"}]}
      refute SubIssueWait.close?(%{done | state: "In Progress"}, terminal, settings)
      refute SubIssueWait.close?(%{done | labels: ["breakdown"]}, terminal, settings)
      refute SubIssueWait.close?(%{done | sub_issues: []}, terminal, settings)
      refute SubIssueWait.close?(nil, terminal, settings)

      # It stays held while it waits: Symphony closes it with no run.
      assert SubIssueWait.held?(done, terminal, settings)
    end

    test "tells a never-approved plan, with every open sub-issue in Backlog, from an approved one" do
      settings = Config.settings!()
      backlog = [%{id: "c1", identifier: "MT-2", state: " backlog "}, %{id: "c2", identifier: "MT-3", state: "Cancelled"}]
      parent = %Issue{id: "p", identifier: "MT-1", title: "Parent", state: "In Progress", labels: ["breakdown"], sub_issues: backlog}
      terminal = ["Done", "Cancelled"]

      assert Issue.unapproved_plan?(parent, terminal)
      refute Issue.waiting_on_sub_issues?(parent, terminal)
      refute SubIssueWait.park?(parent, terminal, settings)
      refute Issue.close_out_ready?(parent, terminal)

      # A sub-issue already promoted or done means a person approved the plan.
      for approved <- [%{id: "c4", identifier: "MT-5", state: "In Progress"}, %{id: "c4", identifier: "MT-5", state: "Done"}] do
        parent = %{parent | sub_issues: [approved | backlog]}
        refute Issue.unapproved_plan?(parent, terminal)
        assert Issue.waiting_on_sub_issues?(parent, terminal)
        assert SubIssueWait.park?(parent, terminal, settings)
      end

      refute Issue.unapproved_plan?(%{parent | sub_issues: []}, terminal)
      refute Issue.unapproved_plan?(%{parent | sub_issues: [%{id: "c2", identifier: "MT-3", state: "Cancelled"}]}, terminal)
      refute Issue.unapproved_plan?(%{parent | labels: ["feature"]}, terminal)
      refute Issue.unapproved_plan?(%{parent | sub_issues: nil}, terminal)
      refute Issue.unapproved_plan?(nil, terminal)
      refute Issue.close_out_ready?(%{parent | sub_issues: nil}, terminal)
      refute Issue.waiting_on_sub_issues?(%{parent | sub_issues: nil}, terminal)
      refute Issue.waiting_on_sub_issues?(nil, terminal)

      # The waiting state still holds it: only a person moves a parent there.
      assert SubIssueWait.held?(%{parent | state: @waiting}, terminal, settings)
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
      open = [%{id: "child-1", identifier: "MT-1302", state: "Todo"}]
      parent = %Issue{id: "parent-park", identifier: "MT-1301", title: "Parent", state: "In Progress", labels: ["breakdown"], sub_issues: open}
      running = %{parent | id: "parent-running", identifier: "MT-1303"}
      claimed = %{parent | id: "parent-claimed", identifier: "MT-1304"}
      plain = %Issue{id: "plain", identifier: "MT-1305", title: "Work", state: "In Progress", sub_issues: open}

      state = %{state | running: %{"parent-running" => %{}}, claimed: MapSet.new(["parent-claimed"])}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [parent, running, claimed, plain])

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
      # Recorded as Symphony's own move, so a review never reads it as a person's approval.
      assert %DateTime{} = RunStore.get_own_state_move("parent-park")

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

    test "leaves a parent its breakdown run moved to In Review there, with its sub-tickets in Backlog" do
      state = orchestrator_state()
      backlog = [%{id: "child-1", identifier: "MOT-14", state: "Backlog"}, %{id: "child-2", identifier: "MOT-5", state: "Backlog"}]
      cached = %Issue{id: "parent-review", identifier: "MOT-4", title: "Parent", state: "In Progress", labels: ["breakdown"], sub_issues: backlog}
      in_review = %{cached | state: "In Review"}

      # The run has ended and released its claim, but the poll cache still shows the parent In Progress.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [in_review])

      state = Orchestrator.park_breakdown_parents_for_test([cached], state)
      assert state.parked_parents == MapSet.new()
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert RunStore.get_own_state_move("parent-review") == nil

      # A parent gone from the fresh read is not moved either.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      assert Orchestrator.park_breakdown_parents_for_test([cached], state).parked_parents == MapSet.new()

      # The next poll sees it In Review: it waits for a human's review, and nothing is promoted.
      reviewed = Orchestrator.review_breakdown_parents_for_test([in_review], state)
      assert reviewed.breakdown_reviews == %{}
      refute_received {:memory_tracker_breakdown_history, _issue_id}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "parks nothing when the fresh read fails, and tries again on the next poll" do
      state = orchestrator_state()
      open = [%{id: "child-1", identifier: "MT-1602", state: "Todo"}]
      parent = %Issue{id: "parent-retry", identifier: "MT-1601", title: "Parent", state: "In Progress", labels: ["breakdown"], sub_issues: open}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [parent])
      Application.put_env(:symphony_elixir, :memory_tracker_fetch_issue_states_result, {:error, :timeout})

      log = capture_log(fn -> assert Orchestrator.park_breakdown_parents_for_test([parent], state).parked_parents == MapSet.new() end)
      assert log =~ "Failed to refresh breakdown parents before parking"
      assert log =~ ":timeout"
      refute_received {:memory_tracker_state_update, _issue_id, _state}

      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_issue_states_result)
      assert Orchestrator.park_breakdown_parents_for_test([parent], state).parked_parents == MapSet.new(["parent-retry"])
      assert_received {:memory_tracker_state_update, "parent-retry", @waiting}
    end

    test "keeps today's In Progress behaviour when the state is missing" do
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states, ["Todo", "In Progress", "Done"])
      capture_log(fn -> assert :disabled = SubIssueWait.check_tracker_state(Config.settings!(), []) end)

      state = orchestrator_state()
      open = [%{id: "child-1", identifier: "MT-1402", state: "Todo"}]
      parent = %Issue{id: "parent-old", identifier: "MT-1401", title: "Parent", state: "In Progress", labels: ["breakdown"], sub_issues: open}

      assert Orchestrator.park_breakdown_parents_for_test([parent], state).parked_parents == MapSet.new()
      refute_received {:memory_tracker_state_update, _issue_id, _state}

      refute Orchestrator.should_dispatch_issue_for_test(parent, state)
      closed_out = %{parent | sub_issues: [%{id: "child-1", identifier: "MT-1402", state: "Done"}]}
      assert Orchestrator.should_dispatch_issue_for_test(closed_out, state)
    end

    test "resumes a never-approved plan stopped midway instead of parking it" do
      state = orchestrator_state()
      # MOT-30: the run filed 7 of 9 sub-tickets, hit Linear's usage limit, and a person moved it back.
      backlog = for n <- 31..37, do: %{id: "child-#{n}", identifier: "MOT-#{n}", state: "Backlog"}
      parent = %Issue{id: "parent-resume", identifier: "MOT-30", title: "Plan the MVP", state: "In Progress", labels: ["breakdown", "expedite"], sub_issues: backlog}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [parent])

      assert Orchestrator.park_breakdown_parents_for_test([parent], state).parked_parents == MapSet.new()
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert RunStore.get_own_state_move("parent-resume") == nil

      assert Orchestrator.should_dispatch_issue_for_test(parent, state)
      assert Orchestrator.should_dispatch_issue_for_test(%{parent | state: "Todo"}, state)
      assert Orchestrator.dispatch_revalidated_issue_for_test(parent, true)
      assert RunKind.classify(parent) == :breakdown

      # Nothing approved it, so nothing is promoted either.
      reviewed = Orchestrator.review_breakdown_parents_for_test([parent], state)
      assert reviewed.breakdown_reviews == %{}
      refute_received {:memory_tracker_state_update, _issue_id, _state}

      # Once a person approved the plan, the same parent waits for its sub-tickets.
      approved = %{parent | sub_issues: Enum.map(backlog, &%{&1 | state: "Todo"})}
      refute Orchestrator.should_dispatch_issue_for_test(approved, state)
      refute Orchestrator.should_dispatch_issue_for_test(%{approved | state: @waiting}, state)
    end

    test "moves an issue waiting on its sub-tickets after its PR merged to Done once each one is finished" do
      state = orchestrator_state()

      sub_issues = [
        %{id: "child-1", identifier: "MT-1702", state: "Done"},
        %{id: "child-2", identifier: "MT-1703", state: "Canceled"},
        %{id: "child-3", identifier: "MT-1704", state: "Duplicate"}
      ]

      waiting = %Issue{id: "waiting", identifier: "MT-1701", title: "Work", state: @waiting, labels: ["improvement"], sub_issues: sub_issues}
      running = %{waiting | id: "waiting-running", identifier: "MT-1705"}
      claimed = %{waiting | id: "waiting-claimed", identifier: "MT-1706"}
      breakdown = %{waiting | id: "waiting-breakdown", identifier: "MT-1707", labels: ["breakdown"]}
      state = %{state | running: %{"waiting-running" => %{}}, claimed: MapSet.new(["waiting-claimed"])}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [waiting, running, claimed, breakdown])

      refute Orchestrator.should_dispatch_issue_for_test(waiting, state)

      log =
        capture_log([level: :info], fn ->
          candidates = [waiting, running, claimed, breakdown, nil]
          assert ^state = Orchestrator.close_finished_parents_for_test(candidates, state)
        end)

      assert_received {:memory_tracker_state_update, "waiting", "Done"}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert_received {:memory_tracker_comment, "waiting", body}
      assert body == "Every sub-ticket is finished, so this ticket is Done:\n\n- MT-1702: Done\n- MT-1703: Canceled\n- MT-1704: Duplicate"
      assert log =~ "Moved issue to Done: every sub-issue is finished issue_id=waiting issue_identifier=MT-1701"

      # A sub-ticket filed since the cached poll keeps it waiting; one gone from the fresh read is left too.
      filed = %{waiting | sub_issues: sub_issues ++ [%{id: "child-4", identifier: "MT-1708", state: "Backlog"}]}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [filed])
      Orchestrator.close_finished_parents_for_test([waiting], state)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Orchestrator.close_finished_parents_for_test([waiting], state)
      refute_received {:memory_tracker_state_update, _issue_id, _state}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [waiting])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :boom})

      log = capture_log(fn -> Orchestrator.close_finished_parents_for_test([waiting], state) end)
      assert_received {:memory_tracker_state_update, "waiting", "Done"}
      assert log =~ "Failed to comment on an issue waiting on its sub-issues: issue_id=waiting issue_identifier=MT-1701 reason=:boom"

      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :linear_down})
      log = capture_log(fn -> Orchestrator.close_finished_parents_for_test([waiting], state) end)
      assert log =~ "Failed to move an issue whose sub-issues are finished to Done; retrying next poll: issue_id=waiting"
      assert log =~ ":linear_down"

      Application.put_env(:symphony_elixir, :memory_tracker_fetch_issue_states_result, {:error, :timeout})
      log = capture_log(fn -> Orchestrator.close_finished_parents_for_test([waiting], state) end)
      assert log =~ "Failed to refresh issues waiting on sub-issues before closing them; retrying next poll reason=:timeout"
      refute_received {:memory_tracker_state_update, _issue_id, _state}
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
