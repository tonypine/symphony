defmodule SymphonyElixir.SubIssueWaitTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.{RunKind, RunStore, SubIssueWait}
  alias SymphonyElixir.{TicketObservation, TicketPlan, TicketPullRequest, TicketSignals}

  @waiting "Waiting on sub-tickets"

  defmodule StateTracker do
    def workflow_state_exists?(state_name, teams) do
      send(self(), {:workflow_state_exists?, state_name, teams})
      Process.get(:sub_issue_wait_state_result)
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
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
                   "execution" => %{"harnesses" => %{"codex" => %{"command" => "codex app-server"}}},
                   "runs" => %{"default" => %{"harness" => "codex", "provider" => "openai", "model" => "gpt-test"}},
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

  describe "a groomed ticket and the tickets around it" do
    defp groomed!(issue_id) do
      checks = [%{id: "c1", kind: "outcome", statement: "It works.", proof: "test"}]
      plan = %{reason: "Grooming", by: "grooming", shape: "single", layers: ["engine"], summary: "s", text: "t"}
      {:ok, _event} = TicketPlan.write("default", issue_id, Map.merge(plan, %{checks: checks, size: %{tokens: 1, runs: 1}}))
      :ok
    end

    defp merged!(issue_id) do
      url = "https://github.com/acme/app/pull/#{System.unique_integer([:positive])}"
      :ok = TicketPullRequest.put("default", issue_id, %{pr_url: url})
      :ok = TicketPullRequest.mark_finished("default", url, "merged")
    end

    test "a blocked ticket starts once its groomed blocker's pull request merged, while the blocker is not Done" do
      state = orchestrator_state()
      terminal_states = Config.settings!().tracker.terminal_states
      for id <- ["blocker-groomed", "blocker-plain"], do: :ok = TicketSignals.record_phase("default", id, "Merging")
      groomed!("blocker-groomed")
      blocker = %{id: "blocker-groomed", identifier: "MT-2101", state: "Merging"}
      blocked = %Issue{id: "blocked-by-groomed", identifier: "MT-2102", title: "Next", state: "Todo", blocked_by: [blocker]}

      # Its pull request is still open: it blocks.
      assert Issue.blocked?(blocked, terminal_states)
      assert [%{issue_id: "blocked-by-groomed"}] = Orchestrator.put_blocked_for_test(state, [blocked]).blocked

      merged!("blocker-groomed")
      assert SubIssueWait.merged_blocker?(blocker)
      assert Issue.open_blockers(blocked, terminal_states) == []
      assert Orchestrator.put_blocked_for_test(state, [blocked]).blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(blocked, state)

      # A ticket with no plan keeps today's rule: merged, it still blocks until it is Done.
      merged!("blocker-plain")
      plain = %{id: "blocker-plain", identifier: "MT-2103", state: "Merging"}
      refute SubIssueWait.merged_blocker?(plain)
      assert Issue.blocked?(%{blocked | blocked_by: [plain]}, terminal_states)
    end

    test "MOT-85: a sub-ticket blocked by its own groomed parent dispatches once the parent's pull request merged" do
      state = orchestrator_state()
      :ok = TicketSignals.record_phase("default", "groomed-parent", @waiting)
      groomed!("groomed-parent")
      merged!("groomed-parent")
      parent = %{id: "groomed-parent", identifier: "MT-2201", state: @waiting}
      child = %Issue{id: "child-of-groomed", identifier: "MT-2202", title: "Builds on it", state: "Todo", blocked_by: [parent]}

      # No merge mark is left for it: the record's merged pull request is enough.
      refute RunStore.merged_wait?("groomed-parent")
      assert Orchestrator.put_blocked_for_test(state, [child]).blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(child, state)
    end

    test "a sub-ticket in Backlog holds a groomed ticket whose pull request merged, and so does one that ended" do
      settings = Config.settings!()
      terminal_states = settings.tracker.terminal_states
      backlog = [%{id: "c1", identifier: "MT-2302", state: "Backlog"}]
      plain = %Issue{id: "plain-merged", identifier: "MT-2301", title: "Work", state: "Merging", sub_issues: backlog, repo_key: "default"}
      groomed = %{plain | id: "groomed-merged"}
      groomed!("groomed-merged")

      refute SubIssueWait.wait_on_merge?(plain, terminal_states, settings)
      assert SubIssueWait.wait_on_merge?(groomed, terminal_states, settings)
      assert SubIssueWait.wait_on_merge?(%{groomed | labels: ["plan"]}, terminal_states, settings)
      refute SubIssueWait.wait_on_merge?(%{groomed | sub_issues: []}, terminal_states, settings)
      refute SubIssueWait.wait_on_merge?(%{groomed | sub_issues: :unknown}, terminal_states, settings)
      refute SubIssueWait.wait_on_merge?(%{plain | labels: ["plan"]}, terminal_states, settings)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [groomed])
      assert :ok = SubIssueWait.wait_on_merge(groomed, settings, Tracker.adapter())
      assert_received {:memory_tracker_comment, "groomed-merged", waiting}
      assert waiting =~ "the PR merged with sub-tickets still open (MT-2302)"
      assert waiting =~ "one in Backlog included, the Conductor checks the whole ticket against its plan"

      # Every sub-ticket ended before the merge: it still waits, for the final check.
      ended = %{groomed | id: "groomed-ended", sub_issues: [%{id: "c1", identifier: "MT-2302", state: "Done"}]}
      groomed!("groomed-ended")
      assert SubIssueWait.wait_on_merge?(ended, terminal_states, settings)
      assert :ok = SubIssueWait.wait_on_merge(ended, settings, Tracker.adapter())
      assert_received {:memory_tracker_comment, "groomed-ended", checked}
      assert checked == "#{@waiting}: the PR merged and every sub-ticket has ended. Next, the Conductor checks the whole ticket against its plan, and it moves to Done."
    end
  end

  describe "a groomed ticket whose plan label survived" do
    test "is out of the old plan flow: no breakdown run, no epic review, and it is held in the waiting state" do
      settings = Config.settings!()
      done = [%{id: "c1", identifier: "MT-2", state: "Done"}]
      parent = %Issue{id: "groomed-labelled", identifier: "MT-1", title: "Parent", state: @waiting, labels: ["plan"], sub_issues: done}
      assert RunKind.classify(parent, terminal_states: ["Done"], settings: settings) == :epic_review
      refute SubIssueWait.groomed?(parent)
      refute SubIssueWait.groomed?(nil)

      checks = [%{id: "c1", kind: "outcome", statement: "It works.", proof: "test"}]
      plan = %{reason: "Grooming", by: "grooming", shape: "single", layers: ["engine"], summary: "s", text: "t"}
      plan = Map.merge(plan, %{checks: checks, size: %{tokens: 1, runs: 1}})
      {:ok, _event} = TicketPlan.write("default", "groomed-labelled", plan)

      assert SubIssueWait.groomed?(parent)
      refute SubIssueWait.close_out_ready?(parent, ["Done"], settings)
      assert SubIssueWait.held?(parent, ["Done"], settings)
      assert RunKind.classify(parent, terminal_states: ["Done"], settings: settings) == :implementation
      unsplit = %{parent | state: "Todo", sub_issues: []}
      assert RunKind.classify(unsplit, terminal_states: ["Done"], settings: settings) == :implementation
      assert RunKind.classify(%{parent | id: nil, state: "Todo", sub_issues: []}, settings: settings) == :breakdown
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
      # Every child re-parented away or deleted: the parent waits on nothing and closes out.
      refute SubIssueWait.held?(%{parent | sub_issues: []}, ["Done"], settings)
      assert SubIssueWait.close_out_ready?(%{parent | sub_issues: []}, ["Done"], settings)
      refute Issue.close_out_ready?(%{parent | sub_issues: []}, ["Done"])
      assert RunKind.classify(%{parent | sub_issues: []}, terminal_states: ["Done"], settings: settings) == :epic_review
      # Outside the waiting state a parent with no sub-issues has no plan yet: it gets a plan run.
      refute SubIssueWait.close_out_ready?(%{parent | state: "Todo", sub_issues: []}, ["Done"], settings)
      unplanned = %{parent | state: "Todo", sub_issues: []}
      assert RunKind.classify(unplanned, terminal_states: ["Done"], settings: settings) == :breakdown
      # Sub-issues a read did not carry are not "none left".
      assert SubIssueWait.held?(%{parent | sub_issues: :unknown}, ["Done"], settings)
      refute SubIssueWait.close_out_ready?(nil, ["Done"], settings)
      assert SubIssueWait.held?(%{parent | labels: ["feature"]}, ["Done", "Cancelled"], settings)
      assert SubIssueWait.held?(%{parent | labels: ["feature"], sub_issues: []}, ["Done"], settings)
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

    test "an issue that is not a breakdown parent waits on merge while a started sub-issue is open, and closes once all are terminal or in Backlog" do
      settings = Config.settings!()
      terminal = ["Done", "Canceled", "Duplicate"]
      open = [%{id: "c1", identifier: "MT-2", state: "Todo"}, %{id: "c2", identifier: "MT-3", state: "Done"}]
      issue = %Issue{id: "p", identifier: "MT-1", title: "Work", state: "Merging", labels: ["improvement"], sub_issues: open}

      assert SubIssueWait.wait_on_merge?(issue, terminal, settings)
      in_progress = [%{id: "c1", identifier: "MT-2", state: "In Progress"}]
      assert SubIssueWait.wait_on_merge?(%{issue | sub_issues: in_progress}, terminal, settings)
      assert SubIssueWait.wait_on_merge?(%{issue | sub_issues: [%{id: "c1", identifier: "MT-2"}]}, terminal, settings)
      refute SubIssueWait.wait_on_merge?(%{issue | sub_issues: []}, terminal, settings)
      # A Backlog sub-issue, such as an acceptance gate follow-up, waits for a person and holds nothing.
      backlog = [%{id: "c1", identifier: "MT-2", state: " backlog "}, %{id: "c2", identifier: "MT-3", state: "Done"}]
      refute SubIssueWait.wait_on_merge?(%{issue | sub_issues: backlog}, terminal, settings)
      canceled = [%{id: "c1", identifier: "MT-2", state: "Canceled"}]
      refute SubIssueWait.wait_on_merge?(%{issue | sub_issues: canceled}, terminal, settings)
      refute SubIssueWait.wait_on_merge?(%{issue | labels: ["breakdown"]}, terminal, settings)
      refute SubIssueWait.wait_on_merge?(nil, terminal, settings)

      # Sub-issues are never promoted on merge, whatever their state.
      sub_issues = [%{id: "c1", identifier: "MT-2"}, %{id: "c2", identifier: "MT-3", state: "Backlog"}]
      with_backlog = %{issue | sub_issues: sub_issues, repo_key: "repo-sub-wait"}
      RunStore.delete_ticket_state("p")
      assert :ok = SubIssueWait.wait_on_merge(with_backlog, settings, SymphonyElixir.Tracker.Memory)
      assert_received {:memory_tracker_state_update, "p", @waiting}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert_received {:memory_tracker_comment, "p", _wait_comment}
      assert RunStore.merged_wait?("p")
      assert [%{name: "merge settled", details: %{to: @waiting}}] = ticket_signals("p")
      :ok = RunStore.delete_merged_wait("p")

      waiting = %{issue | state: @waiting}
      refute SubIssueWait.close?(waiting, terminal, settings)

      # Only an issue its PR's merge put in the waiting state closes: one a person moved there waits.
      done = %{waiting | sub_issues: [%{id: "c1", identifier: "MT-2", state: "Done"}]}
      refute SubIssueWait.close?(done, terminal, settings)
      :ok = RunStore.put_merged_wait("p")

      for finished <- ["Done", "Canceled", "Duplicate", "Backlog"] do
        assert SubIssueWait.close?(%{waiting | sub_issues: [%{id: "c1", identifier: "MT-2", state: finished}]}, terminal, settings)
      end

      refute SubIssueWait.close?(%{done | state: "In Progress"}, terminal, settings)
      refute SubIssueWait.close?(%{done | labels: ["breakdown"]}, terminal, settings)
      # Every sub-ticket re-parented to another epic or deleted: nothing is left to wait on.
      assert SubIssueWait.close?(%{done | sub_issues: []}, terminal, settings)
      refute SubIssueWait.close?(%{done | sub_issues: :unknown}, terminal, settings)
      refute SubIssueWait.close?(nil, terminal, settings)
      refute SubIssueWait.close?(%{done | id: nil}, terminal, settings)

      # It stays held while it waits: Symphony closes it with no run.
      assert SubIssueWait.held?(done, terminal, settings)

      # Closing it leaves a Backlog sub-issue there, and says so.
      parked = %{waiting | sub_issues: [%{id: "c1", identifier: "MT-2", state: "Done"}, %{id: "c2", identifier: "MT-3", state: "Backlog"}]}
      # With no repo key there is no record to move: nothing moves and the mark stays (MOT-93).
      assert {:error, :no_repo_key} = SubIssueWait.close(parked, SymphonyElixir.Tracker.Memory)
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert RunStore.merged_wait?("p")
      parked = %{parked | repo_key: "repo-sub-wait"}

      capture_log([level: :info], fn -> assert :ok = SubIssueWait.close(parked, SymphonyElixir.Tracker.Memory) end)
      assert_received {:memory_tracker_state_update, "p", "Done"}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert_received {:memory_tracker_comment, "p", body}

      assert body ==
               "Every sub-ticket is finished, so this ticket is Done:\n\n- MT-2: Done\n- MT-3: Backlog\n\n" <>
                 "Sub-tickets in Backlog stay there until a person moves them to Todo with Move to… in the Director."

      orphan = %{waiting | sub_issues: [], repo_key: "repo-sub-wait"}
      capture_log([level: :info], fn -> assert :ok = SubIssueWait.close(orphan, SymphonyElixir.Tracker.Memory) end)
      assert_received {:memory_tracker_state_update, "p", "Done"}
      assert_received {:memory_tracker_comment, "p", "No sub-ticket is left under this ticket, so it is Done."}
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
      # Every sub-ticket re-parented to another epic: none is left to wait on, so its close-out runs.
      assert Orchestrator.should_dispatch_issue_for_test(%{closed_out | sub_issues: []}, state)
      refute Orchestrator.should_dispatch_issue_for_test(%{closed_out | sub_issues: :unknown}, state)

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
      parent = %Issue{id: "parent-resume", identifier: "MOT-30", title: "Plan the MVP", state: "In Progress", labels: ["breakdown"], sub_issues: backlog}
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

      waiting = %Issue{
        id: "waiting",
        identifier: "MT-1701",
        title: "Work",
        state: @waiting,
        labels: ["improvement"],
        sub_issues: sub_issues,
        repo_key: "default"
      }

      running = %{waiting | id: "waiting-running", identifier: "MT-1705"}
      claimed = %{waiting | id: "waiting-claimed", identifier: "MT-1706"}
      breakdown = %{waiting | id: "waiting-breakdown", identifier: "MT-1707", labels: ["breakdown"]}
      state = %{state | running: %{"waiting-running" => %{}}, claimed: MapSet.new(["waiting-claimed"])}
      moved_by_person = %{waiting | id: "waiting-moved", identifier: "MT-1709"}
      tracked = [waiting, running, claimed, breakdown, moved_by_person]
      Application.put_env(:symphony_elixir, :memory_tracker_issues, tracked)
      merged = ["waiting", "waiting-running", "waiting-claimed", "waiting-breakdown"]
      for issue_id <- merged, do: :ok = RunStore.put_merged_wait(issue_id)

      refute Orchestrator.should_dispatch_issue_for_test(waiting, state)

      log =
        capture_log([level: :info], fn ->
          candidates = [waiting, running, claimed, breakdown, moved_by_person, nil]
          assert ^state = Orchestrator.close_finished_parents_for_test(candidates, state)
        end)

      assert_received {:memory_tracker_state_update, "waiting", "Done"}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert_received {:memory_tracker_comment, "waiting", body}
      assert body == "Every sub-ticket is finished, so this ticket is Done:\n\n- MT-1702: Done\n- MT-1703: Canceled\n- MT-1704: Duplicate"
      assert log =~ "Moved issue to Done: every sub-issue is finished issue_id=waiting issue_identifier=MT-1701"
      refute RunStore.merged_wait?("waiting")
      assert RunStore.merged_wait?("waiting-running")
      :ok = RunStore.put_merged_wait("waiting")

      # A sub-ticket filed since the cached poll keeps it waiting; one gone from the fresh read is left too.
      filed = %{waiting | sub_issues: sub_issues ++ [%{id: "child-4", identifier: "MT-1708", state: "Todo"}]}
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

      :ok = RunStore.put_merged_wait("waiting")
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :linear_down})
      log = capture_log(fn -> Orchestrator.close_finished_parents_for_test([waiting], state) end)
      assert log =~ "Failed to move an issue whose sub-issues are finished to Done; retrying next poll: issue_id=waiting"
      assert log =~ ":linear_down"
      # A failed move keeps the record, so the next poll retries.
      assert RunStore.merged_wait?("waiting")

      Application.put_env(:symphony_elixir, :memory_tracker_fetch_issue_states_result, {:error, :timeout})
      log = capture_log(fn -> Orchestrator.close_finished_parents_for_test([waiting], state) end)
      assert log =~ "Failed to refresh issues waiting on sub-issues before closing them; retrying next poll reason=:timeout"
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "moves an issue waiting after its PR merged to Done once its last sub-ticket is re-parented away" do
      state = orchestrator_state()
      # Its last open child moved to another epic: the fresh read lists no sub-ticket at all.
      waiting = %Issue{id: "orphaned", identifier: "MT-1801", title: "Audit", state: @waiting, labels: ["improvement"], sub_issues: [], repo_key: "default"}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [waiting])
      :ok = RunStore.put_merged_wait("orphaned")

      refute Orchestrator.should_dispatch_issue_for_test(waiting, state)

      capture_log([level: :info], fn -> Orchestrator.close_finished_parents_for_test([waiting], state) end)

      assert_received {:memory_tracker_state_update, "orphaned", "Done"}
      assert_received {:memory_tracker_comment, "orphaned", "No sub-ticket is left under this ticket, so it is Done."}
      refute RunStore.merged_wait?("orphaned")
    end

    test "TP-1565: a close through the read by id moves the record to Done, and the drift check after it moves nothing" do
      repo_key = "default"
      RunStore.delete_ticket_state("by-id")
      sub_issues = [%{id: "child-1", identifier: "MT-2002", state: "Canceled"}]
      # Linear's read by id carries no repo key; the poll's candidate does.
      read_by_id = %Issue{id: "by-id", identifier: "MT-2001", title: "Translate", state: @waiting, labels: ["improvement"], sub_issues: sub_issues}
      candidate = %{read_by_id | repo_key: repo_key}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [read_by_id])
      :ok = TicketSignals.record_phase(repo_key, "by-id", @waiting)
      :ok = RunStore.put_merged_wait("by-id")

      log =
        capture_log([level: :info], fn ->
          Orchestrator.close_finished_parents_for_test([candidate], orchestrator_state())
        end)

      assert_received {:memory_tracker_state_update, "by-id", "Done"}
      refute log =~ "Moving a ticket with no record key"
      assert %{phase: "Done"} = RunStore.get_ticket_state("by-id")
      refute RunStore.merged_wait?("by-id")

      # Linear now says Done, and so does the record: the drift check moves nothing back.
      done = %{candidate | state: "Done", updated_at: DateTime.utc_now()}
      assert {:ok, _outcome} = TicketObservation.observe(repo_key, done)
      refute_received {:memory_tracker_state_update, "by-id", _state}
      refute Enum.any?(TicketObservation.summary().drift.recent, &(&1.identifier == "MT-2001"))
      assert %{phase: "Done"} = RunStore.get_ticket_state("by-id")
    end

    test "TP-1565: a close whose record cannot move keeps the merge's mark, and the next pass closes it" do
      RunStore.delete_ticket_state("no-key")
      sub_issues = [%{id: "child-1", identifier: "MT-2102", state: "Done"}]
      waiting = %Issue{id: "no-key", identifier: "MT-2101", title: "Work", state: @waiting, labels: ["improvement"], sub_issues: sub_issues}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [waiting])
      :ok = RunStore.put_merged_wait("no-key")

      # Neither the candidate nor the read carries a repo key: no record to move, so nothing moves.
      log = capture_log(fn -> Orchestrator.close_finished_parents_for_test([waiting], orchestrator_state()) end)
      assert log =~ "Failed to move an issue whose sub-issues are finished to Done; retrying next poll: issue_id=no-key"
      assert log =~ ":no_repo_key"
      refute_received {:memory_tracker_state_update, "no-key", _state}
      assert RunStore.merged_wait?("no-key")

      capture_log([level: :info], fn ->
        Orchestrator.close_finished_parents_for_test([%{waiting | repo_key: "default"}], orchestrator_state())
      end)

      assert_received {:memory_tracker_state_update, "no-key", "Done"}
      assert %{phase: "Done"} = RunStore.get_ticket_state("no-key")
      refute RunStore.merged_wait?("no-key")
    end

    test "TP-1565: a ticket stranded in the waiting state with no mark closes from its record's merged pull request" do
      repo_key = "default"
      pr_url = "https://github.com/acme/repo/pull/85"
      RunStore.delete_ticket_state("stranded")
      sub_issues = [%{id: "child-1", identifier: "MT-2202", state: "Done"}]
      read_by_id = %Issue{id: "stranded", identifier: "MT-2201", title: "Work", state: @waiting, labels: ["improvement"], sub_issues: sub_issues}
      candidate = %{read_by_id | repo_key: repo_key}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [read_by_id])
      :ok = TicketSignals.record_phase(repo_key, "stranded", @waiting)
      refute RunStore.merged_wait?("stranded")
      settings = Config.settings!()
      terminal = settings.tracker.terminal_states

      # Its pull request still open: a person moved it there, so it waits for them.
      :ok = TicketPullRequest.record_created(repo_key, "stranded", pr_url, "auto/MT-2201")
      refute SubIssueWait.close?(candidate, terminal, settings)
      Orchestrator.close_finished_parents_for_test([candidate], orchestrator_state())
      refute_received {:memory_tracker_state_update, "stranded", _state}

      :ok = TicketPullRequest.mark_finished(repo_key, pr_url, "merged")
      assert SubIssueWait.close?(candidate, terminal, settings)
      # The read by id alone has no repo key, so no record to look the pull request up in.
      refute SubIssueWait.close?(read_by_id, terminal, settings)

      capture_log([level: :info], fn ->
        Orchestrator.close_finished_parents_for_test([candidate], orchestrator_state())
      end)

      assert_received {:memory_tracker_state_update, "stranded", "Done"}
      assert %{phase: "Done"} = RunStore.get_ticket_state("stranded")
    end

    test "MOT-93: a poll cycle closes a merged ticket whose last sub-ticket was cancelled even when it dispatches nothing" do
      waiting = %Issue{
        id: "waiting-poll",
        identifier: "MT-1601",
        title: "Translate",
        state: @waiting,
        team: %{key: "Test"},
        labels: ["improvement"],
        sub_issues: [%{id: "child-1", identifier: "MT-1602", state: "Canceled"}]
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [waiting])
      :ok = RunStore.put_merged_wait("waiting-poll")

      orchestrator_name = Module.concat(__MODULE__, :ClosingOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      # A quality gate pass still in flight defers the dispatch pass, as a busy slot or a gate that
      # skips the ticket keeps it from one; the close does not wait for it.
      :sys.replace_state(pid, &%{&1 | quality_gate_tasks: %{make_ref() => :poll}})
      send(pid, :run_poll_cycle)

      assert_receive {:memory_tracker_state_update, "waiting-poll", "Done"}, 2_000
      assert %{running: running} = :sys.get_state(pid)
      refute Map.has_key?(running, "waiting-poll")
    end

    test "MOT-85: a blocked-by link to a merged ticket waiting on its sub-tickets is met, so its sub-ticket dispatches" do
      state = orchestrator_state()
      parent = %{id: "merged-parent", identifier: "MT-1651", state: @waiting}
      child = %Issue{id: "child-of-merged", identifier: "MT-1652", title: "Follow-up", state: "Todo", blocked_by: [parent]}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [child])
      terminal_states = Config.settings!().tracker.terminal_states

      # Before its merge is recorded (a plan parent waits there with nothing recorded), the link holds.
      refute SubIssueWait.merged_blocker?(parent)
      assert Issue.blocked?(child, terminal_states)
      assert [%{issue_id: "child-of-merged"}] = Orchestrator.put_blocked_for_test(state, [child]).blocked

      :ok = RunStore.put_merged_wait("merged-parent")

      assert SubIssueWait.merged_blocker?(parent)
      assert Issue.open_blockers(child, terminal_states) == []
      refute Issue.blocked?(child, terminal_states)
      assert Orchestrator.put_blocked_for_test(state, [child]).blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(child, state)

      # Once a person moves it out of the waiting state, it blocks again until it is terminal.
      reopened = %{child | blocked_by: [%{parent | state: "In Progress"}]}
      refute SubIssueWait.merged_blocker?(%{parent | state: "In Progress"})
      assert Issue.blocked?(reopened, terminal_states)
      refute SubIssueWait.merged_blocker?(%{id: nil, state: @waiting})
      refute SubIssueWait.merged_blocker?(:not_a_blocker)
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

    test "records a plan verdict signal when a breakdown parent is parked" do
      repo_key = "default"
      RunStore.delete_ticket_state("parent-signal")
      open = [%{id: "child-1", identifier: "MT-1802", state: "Todo"}]

      parent = %Issue{
        id: "parent-signal",
        identifier: "MT-1801",
        title: "Parent",
        state: "In Progress",
        labels: ["breakdown"],
        sub_issues: open,
        repo_key: repo_key
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [parent])
      Orchestrator.park_breakdown_parents_for_test([parent], orchestrator_state())

      assert [%{name: "plan verdict", details: %{outcome: "approve", to: @waiting}}] =
               ticket_signals("parent-signal")
    end

    test "records a merge settled signal when an issue waiting on its sub-tickets is closed" do
      repo_key = "default"
      RunStore.delete_ticket_state("waiting-signal")

      sub_issues = [%{id: "child-1", identifier: "MT-1902", state: "Done"}]

      waiting = %Issue{
        id: "waiting-signal",
        identifier: "MT-1901",
        title: "Work",
        state: @waiting,
        labels: ["improvement"],
        sub_issues: sub_issues,
        repo_key: repo_key
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [waiting])
      :ok = RunStore.put_merged_wait("waiting-signal")

      Orchestrator.close_finished_parents_for_test([waiting], orchestrator_state())

      assert [%{name: "merge settled", details: %{sub_issues: 1}}] =
               ticket_signals("waiting-signal")
    end
  end

  describe "the close of a ticket read by id (no repo key)" do
    setup do
      {:ok, moves} = Task.Supervisor.start_link()
      %{moves: moves}
    end

    # The real adapter's by-id read carries no repo key: the tracker here holds the ticket without one.
    defp waiting_by_id(issue_id, sub_issues) do
      RunStore.delete_ticket_state(issue_id)
      RunStore.delete_merged_wait(issue_id)
      :ok = TicketSignals.record_phase("default", issue_id, @waiting)
      by_id = %Issue{id: issue_id, identifier: "MT-2001", title: "Work", state: @waiting, labels: ["improvement"], sub_issues: sub_issues}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [by_id])
      by_id
    end

    defp observe_on_record(issue, moves) do
      observed = %{issue | updated_at: DateTime.add(DateTime.utc_now(), 60, :second)}
      result = TicketObservation.observe("default", observed, dispatch_source: "record", task_supervisor: moves)

      for pid <- Task.Supervisor.children(moves) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      end

      result
    end

    test "moves the record to Done with Linear, so the drift check finds nothing to move back", %{moves: moves} do
      by_id = waiting_by_id("by-id", [%{id: "child-1", identifier: "MT-2002", state: "Done"}])
      :ok = RunStore.put_merged_wait("by-id")
      candidate = %{by_id | repo_key: "default"}

      log = capture_log(fn -> Orchestrator.close_finished_parents_for_test([candidate], orchestrator_state()) end)

      assert_received {:memory_tracker_state_update, "by-id", "Done"}
      refute log =~ "Moving a ticket with no record key"
      assert %{phase: "Done", phase_owner: :symphony} = RunStore.get_ticket_state("by-id")
      refute RunStore.merged_wait?("by-id")
      assert [%{name: "merge settled"}] = ticket_signals("by-id")

      # Linear now says Done, as the record does: no drift, so nothing moves it back.
      assert {:ok, _outcome} = observe_on_record(%{by_id | state: "Done"}, moves)
      refute_received {:memory_tracker_state_update, "by-id", _state}
      assert %{phase: "Done"} = RunStore.get_ticket_state("by-id")
    end

    # main's rule (TP-1565) holds: the repo key is the issue's own, never looked up in the record.
    test "does not move a ticket read by id until it carries its repo key, and then moves its record" do
      by_id = waiting_by_id("by-id-record", [])
      :ok = RunStore.put_merged_wait("by-id-record")

      assert {:error, :no_repo_key} = SubIssueWait.close(by_id, Tracker.adapter())
      refute_received {:memory_tracker_state_update, "by-id-record", _state}
      assert %{phase: @waiting} = RunStore.get_ticket_state("by-id-record")
      assert RunStore.merged_wait?("by-id-record")

      capture_log([level: :info], fn -> assert :ok = SubIssueWait.close(%{by_id | repo_key: "default"}, Tracker.adapter()) end)
      assert %{phase: "Done"} = RunStore.get_ticket_state("by-id-record")
      refute RunStore.merged_wait?("by-id-record")
    end

    test "keeps the merge mark while the record did not move" do
      RunStore.delete_ticket_state("keyless")
      :ok = RunStore.put_merged_wait("keyless")
      on_exit(fn -> RunStore.delete_merged_wait("keyless") end)
      keyless = %Issue{id: "keyless", identifier: "MT-2003", title: "Work", state: @waiting, sub_issues: []}

      log = capture_log(fn -> assert {:error, :no_repo_key} = SubIssueWait.close(keyless, Tracker.adapter()) end)

      refute log =~ "Moving a ticket with no record key"
      refute_received {:memory_tracker_state_update, "keyless", _state}
      assert RunStore.merged_wait?("keyless")
    end

    test "closes a stranded ticket: waiting, its merge mark gone, its record saying the pull request merged", %{moves: moves} do
      settings = Config.settings!()
      terminal_states = settings.tracker.terminal_states
      by_id = waiting_by_id("stranded", [%{id: "child-1", identifier: "MT-2002", state: "Canceled"}])
      candidate = %{by_id | repo_key: "default"}

      # A person moved it there with its pull request open, or it has none: it waits for them.
      refute SubIssueWait.pr_merged?("stranded")
      refute SubIssueWait.pr_merged?("no-record-at-all")
      refute SubIssueWait.pr_merged?(nil)
      refute SubIssueWait.close?(candidate, terminal_states, settings)
      :ok = TicketPullRequest.put("default", "stranded", %{pr_url: "https://github.com/acme/app/pull/7"})
      refute SubIssueWait.close?(candidate, terminal_states, settings)

      :ok = TicketPullRequest.mark_finished("default", "https://github.com/acme/app/pull/7", "merged")
      assert SubIssueWait.pr_merged?("stranded")
      assert SubIssueWait.close?(candidate, terminal_states, settings)

      Orchestrator.close_finished_parents_for_test([candidate], orchestrator_state())
      assert_received {:memory_tracker_state_update, "stranded", "Done"}
      assert %{phase: "Done"} = RunStore.get_ticket_state("stranded")
      assert {:ok, _outcome} = observe_on_record(%{by_id | state: "Done"}, moves)
      refute_received {:memory_tracker_state_update, "stranded", _state}
    end

    test "reads the merge from the watcher's last read of the pull request" do
      for {issue_id, fields} <- [
            {"merged-snapshot", %{pull_request: %{state: "merged", url: "https://github.com/acme/app/pull/8"}}},
            {"merged-facts", %{pr_watch: %{facts: %SymphonyElixir.PrDecision.Facts{pr: :merged}}}}
          ] do
        RunStore.delete_ticket_state(issue_id)
        :ok = TicketSignals.record_phase("default", issue_id, @waiting)
        refute SubIssueWait.pr_merged?(issue_id)
        :ok = RunStore.update_ticket_state(issue_id, fields)
        assert SubIssueWait.pr_merged?(issue_id)
      end
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
