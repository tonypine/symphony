defmodule SymphonyElixir.BlockedHoldTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{BlockedHold, Hold, Pauses, RunStore, TicketState, UpdateHold, Workflow}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Hold.Drift
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-a"
  @issue_id "issue-1"
  @terminal ["Done", "Canceled"]
  @ticket {:ticket, "repo-a", "issue-1"}
  @fix_line "Waiting for TP-900 to finish: it fixes what stopped this ticket"

  defmodule FailingStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :boom}
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :boom}
  end

  # Reads succeed (through the real store) but writes fail, so a clear can be driven into its
  # failure path without losing the hold the read needs.
  defmodule ReadOnlyStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :boom}
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
    def get_ticket_state(repo_key, issue_id), do: RunStore.get_ticket_state(repo_key, issue_id)
  end

  # The hold clears, but the stale fix-ticket pointer it should drop cannot be cleared.
  defmodule UnforgettableStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: :ok
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: :ok
    def get_ticket_state(repo_key, issue_id), do: RunStore.get_ticket_state(repo_key, issue_id)
    def clear_ticket_fix_ticket(_repo_key, _issue_id), do: {:error, :boom}
  end

  # The tracker the fix-ticket hold reads the fix ticket's state from, and projects labels onto.
  defmodule FixTicketTracker do
    def fetch_issue_by_identifier(identifier), do: Process.get({:fix_ticket, identifier}, {:error, :not_found})
    def set_machine_label(_issue_id, _label), do: :ok
    def clear_machine_label(_issue_id, _label), do: :ok
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    :ok = RunStore.clear()
    :ok
  end

  # Symphony's record shows the ticket's PR merged.
  defp record_merged(%Issue{id: issue_id}, pr_url) do
    :ok = SymphonyElixir.TicketPullRequest.record_created(@repo_key, issue_id, pr_url, nil)
    :ok = SymphonyElixir.TicketPullRequest.mark_finished(@repo_key, pr_url, "merged")
  end

  defp designed_settings do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    settings
  end

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{id: @issue_id, identifier: "TP-817", title: "T", state: "Todo", repo_key: @repo_key},
      attrs
    )
  end

  defp blocker(identifier, state) do
    %{id: "blocker-#{identifier}", identifier: identifier, title: "B", state: state}
  end

  defp labels do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == @issue_id))
    |> Map.fetch!(:labels)
  end

  defp stored_hold do
    RunStore.get_ticket_state(@repo_key, @issue_id) |> SymphonyElixir.TicketState.get_hold(:blocked)
  end

  describe "desired/3" do
    test "a Todo ticket with an open blocker wants the dependency hold" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress"), blocker("TP-2", "Done")]})

      assert {:set, attrs} = BlockedHold.desired(open_issue, @terminal, nil)
      assert attrs.waits_on == %{type: "dependency", keys: ["TP-1"]}
      assert attrs.reason == "waiting on TP-1"
      assert attrs.clearing_condition =~ "terminal"
    end

    test "a Todo ticket whose blockers are all terminal wants nothing" do
      assert BlockedHold.desired(issue(%{blocked_by: [blocker("TP-1", "Done")]}), @terminal, nil) == :none
      assert BlockedHold.desired(issue(), @terminal, nil) == :none
    end

    test "only a Todo ticket is held: a running ticket with an open blocker wants nothing" do
      running = issue(%{state: "In Progress", blocked_by: [blocker("TP-1", "Todo")]})
      assert BlockedHold.desired(running, @terminal, nil) == :none
    end

    test "a dependency hold whose blockers are all terminal wants clearing" do
      hold = %{kind: :blocked, waits_on: %{type: "dependency", keys: ["TP-1"]}}

      assert BlockedHold.desired(issue(), @terminal, hold) == :clear
      assert BlockedHold.desired(issue(%{blocked_by: [blocker("TP-1", "Done")]}), @terminal, hold) == :clear
    end

    test "a hold that already names the open blockers wants nothing" do
      hold = %{kind: :blocked, waits_on: %{type: "dependency", keys: ["TP-1"]}}
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      assert BlockedHold.desired(open_issue, @terminal, hold) == :none
    end

    test "a hold on a different blocker is replaced and an access hold does not clear a dependency block" do
      hold = %{kind: :blocked, waits_on: %{type: "dependency", keys: ["TP-2"]}}
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      assert {:set, %{waits_on: %{keys: ["TP-1"]}}} = BlockedHold.desired(open_issue, @terminal, hold)

      access = %{kind: :blocked, waits_on: %{type: "access", keys: []}}
      assert BlockedHold.desired(issue(), @terminal, access) == :none
    end

    test "a non-issue wants nothing" do
      assert BlockedHold.desired(:not_an_issue, @terminal, nil) == :none
    end
  end

  describe "sync/3" do
    test "sets the Blocked hold on a designed repo and projects the label" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      assert BlockedHold.sync(open_issue, @terminal, settings: designed_settings()) == :set
      assert %{reason: "waiting on TP-1", waits_on: %{type: "dependency", keys: ["TP-1"]}} = stored_hold()
      assert labels() == ["Blocked"]
    end

    test "clears the hold once every blocker is terminal, leaving the ticket in place" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})
      assert BlockedHold.sync(open_issue, @terminal, settings: designed_settings()) == :set

      unblocked = issue(%{blocked_by: [blocker("TP-1", "Done")]})
      assert BlockedHold.sync(unblocked, @terminal, settings: designed_settings()) == :clear
      assert stored_hold() == nil
      assert labels() == []

      assert [
               {"hold.set", %{kind: "blocked", waits_on: %{type: "dependency", keys: ["TP-1"]}}},
               {"pause.set", %{reason: "ticket", waits_on: %{identifier: "TP-1"}}},
               {"hold.cleared", %{kind: "blocked"}},
               {"pause.cleared", %{cleared: [%{waits_on: %{identifier: "TP-1"}}]}}
             ] = ticket_events(@repo_key, @issue_id)
    end

    test "does nothing when the blockers have not changed" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})
      :set = BlockedHold.sync(open_issue, @terminal, settings: designed_settings())

      assert BlockedHold.sync(open_issue, @terminal, settings: designed_settings()) == :none
    end

    test "leaves a ticket whose repo can't be resolved untouched" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      assert BlockedHold.sync(open_issue, @terminal, settings: nil) == :skipped
      assert stored_hold() == nil
      assert labels() == []
    end

    test "resolves the repo's settings from its key when the caller passes none" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [[key: @repo_key, workflow: Workflow.workflow_file_path(), team: "Test"]]
      )

      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})
      assert BlockedHold.sync(open_issue, @terminal) == :set
      assert stored_hold() != nil
    end

    test "skips when no settings can be resolved" do
      assert BlockedHold.sync(issue(%{repo_key: nil}), @terminal) == :skipped
      assert BlockedHold.sync(issue(%{repo_key: "missing-repo"}), @terminal) == :skipped
      assert BlockedHold.sync(:not_an_issue, @terminal, settings: designed_settings()) == :skipped
    end

    test "a polled issue with no repo key is held under the repo it was polled for" do
      polled = issue(%{repo_key: nil, blocked_by: [blocker("TP-1", "In Progress")]})

      log =
        capture_log(fn ->
          assert BlockedHold.sync(polled, @terminal, settings: designed_settings(), repo_key: @repo_key) == :set

          # The label it set now matches the store, so the next sweep finds no hand-added label.
          held = %{polled | labels: ["Blocked"]}
          assert BlockedHold.sync(held, @terminal, settings: designed_settings(), repo_key: @repo_key) == :none
        end)

      assert %{waits_on: %{type: "dependency", keys: ["TP-1"]}} = stored_hold()
      refute log =~ "hand-added"
      refute log =~ "repo key"
    end

    test "reports and clears a hand-added Blocked label with no store hold" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue(%{labels: ["Blocked"]})])
      stray = issue(%{labels: ["Blocked"]})

      log = capture_log(fn -> assert BlockedHold.sync(stray, @terminal, settings: designed_settings()) == :none end)

      assert log =~ "with no store hold"
      assert labels() == []
      assert stored_hold() == nil
    end

    test "clears a hand-added Blocked label the pause projector last applied as absent, against the labels Linear shows (TP-1243)" do
      Application.put_env(:symphony_elixir, :pause_projector, true)
      on_exit(fn -> Application.put_env(:symphony_elixir, :pause_projector, false) end)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue(%{labels: ["Blocked"]})])
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, @issue_id, %{labels: [], projected: %{labels: []}}))
      stray = issue(%{labels: ["Blocked"]})

      log = capture_log(fn -> assert BlockedHold.sync(stray, @terminal, settings: designed_settings()) == :none end)

      assert log =~ "with no store hold"
      assert labels() == []
      assert RunStore.get_ticket_state(@repo_key, @issue_id).projected.labels == []
    end

    test "a stray Blocked label the poll can't clear is logged once over several syncs, and recorded for Setup" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue(%{labels: ["Blocked"]})])
      Application.put_env(:symphony_elixir, :memory_tracker_remove_issue_label_result, {:error, :forbidden})
      stray = issue(%{labels: ["Blocked"]})

      log = capture_log(fn -> for _poll <- 1..4, do: BlockedHold.sync(stray, @terminal, settings: designed_settings()) end)

      assert length(String.split(log, "with no store hold")) == 2
      assert labels() == ["Blocked"]
      assert [%{issue_id: @issue_id, identifier: "TP-817", drift: {:stray_label, :blocked}}] = Drift.entries()
    end

    test "re-projects a store hold whose Blocked label is missing" do
      # The hold's label write failed (or a person removed it): the store has the hold, the board
      # does not. The sweep re-asserts the label from the store truth.
      :ok =
        RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, %{
          reason: "waiting on TP-1",
          clearing_condition: "when every blocker is terminal",
          waits_on: %{type: "dependency", keys: ["TP-1"]}
        })

      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})
      assert labels() == []

      assert BlockedHold.sync(open_issue, @terminal, settings: designed_settings()) == :none
      assert labels() == ["Blocked"]
      assert stored_hold() != nil
    end

    test "puts back a missing Needs Decision label within one poll, and the warning stops once it is back" do
      # The label went missing while the store kept the hold: the Inbox lists its tickets by that
      # label, so without it the answer is never read and the hold never clears.
      :ok =
        RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, %{
          reason: "Add the signing secrets?",
          clearing_condition: "when the decision is recorded",
          decision: %{title: "Add the release signing secrets", question: "Add the signing secrets?"}
        })

      log = capture_log(fn -> assert BlockedHold.sync(issue(%{state: "QA"}), @terminal, settings: designed_settings()) == :none end)

      assert log =~ "Store hold :needs_decision on issue_id=#{@issue_id} is missing its machine label"
      assert labels() == ["Needs Decision"]
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert Hold.get(@repo_key, @issue_id, :blocked) == nil

      # The next poll reads the label back and has nothing to warn about.
      log = capture_log(fn -> assert BlockedHold.sync(issue(%{state: "QA", labels: labels()}), @terminal, settings: designed_settings()) == :none end)

      refute log =~ "missing its machine label"
      assert labels() == ["Needs Decision"]
    end

    test "reports and clears a hand-added Needs Decision label with no store hold" do
      # The Inbox reads held tickets from the store, so it never reads this one: the poll clears it.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue(%{labels: ["Needs Decision"]})])

      log = capture_log(fn -> assert BlockedHold.sync(issue(%{labels: ["Needs Decision"]}), @terminal, settings: designed_settings()) == :none end)

      assert log =~ "with no store hold"
      assert labels() == []
      assert Hold.get(@repo_key, @issue_id, :needs_decision) == nil
    end

    test "a store failure is logged and reports no change" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      log =
        capture_log(fn ->
          # A store whose write fails: the hold never lands and the failure is reported.
          assert BlockedHold.sync(open_issue, @terminal, settings: designed_settings(), store: FailingStore) == :none
        end)

      assert log =~ "Failed to set the Blocked hold"
    end

    test "a failed clear is logged and reports no change" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})
      :set = BlockedHold.sync(open_issue, @terminal, settings: designed_settings())

      unblocked = issue(%{blocked_by: [blocker("TP-1", "Done")]})

      log =
        capture_log(fn ->
          assert BlockedHold.sync(unblocked, @terminal, settings: designed_settings(), store: ReadOnlyStore) == :none
        end)

      assert log =~ "Failed to clear the Blocked hold"
    end

    test "a ticket with an unreadable state is not held" do
      open_issue = issue(%{state: nil, blocked_by: [blocker("TP-1", "In Progress")]})
      assert BlockedHold.sync(open_issue, @terminal, settings: designed_settings()) == :none
    end
  end

  defp fix_hold_attrs do
    %{
      reason: "waiting on fix ticket TP-900 for the dev_server block",
      clearing_condition: "when the fix ticket TP-900 is terminal",
      waits_on: %{type: "fix_ticket", keys: ["TP-900"]}
    }
  end

  describe "the pause beside a dependency hold (TP-1234)" do
    test "a Todo ticket blocked by two tickets waits on each; a blocker done clears its reason, the last clears the pause" do
      both = issue(%{blocked_by: [blocker("TP-1", "In Progress"), blocker("TP-2", "Todo")]})
      assert BlockedHold.sync(both, @terminal, settings: designed_settings()) == :set

      assert Pauses.why(@ticket) == ["Waiting for TP-1 to finish", "Waiting for TP-2 to finish"]
      assert {:ok, %{reasons: [%{set_by: setter}, %{set_by: setter}]}} = Pauses.get(@ticket)
      assert setter == BlockedHold.reason_setter(:dependency)
      # The hold beside it is as it always was.
      assert %{reason: "waiting on TP-1, TP-2", waits_on: %{type: "dependency", keys: ["TP-1", "TP-2"]}} = stored_hold()

      one_left = issue(%{blocked_by: [blocker("TP-1", "Done"), blocker("TP-2", "Todo")]})
      assert BlockedHold.sync(one_left, @terminal, settings: designed_settings()) == :set
      assert Pauses.why(@ticket) == ["Waiting for TP-2 to finish"]
      assert %{waits_on: %{keys: ["TP-2"]}} = stored_hold()

      # The same blockers again change nothing and record nothing.
      events = ticket_events(@repo_key, @issue_id)
      assert BlockedHold.sync(one_left, @terminal, settings: designed_settings()) == :none
      assert ticket_events(@repo_key, @issue_id) == events

      done = issue(%{blocked_by: [blocker("TP-1", "Done"), blocker("TP-2", "Done")]})
      assert BlockedHold.sync(done, @terminal, settings: designed_settings()) == :clear
      assert Pauses.get(@ticket) == {:ok, nil}
      assert stored_hold() == nil

      assert ["pause.set", "pause.reason_added", "pause.reason_cleared", "pause.cleared"] =
               for({type, _payload} <- ticket_events(@repo_key, @issue_id, ~w(pause.set pause.reason_added pause.reason_cleared pause.cleared)), do: type)
    end

    test "a hold's pause lacking a reason gets it, a reason a rule set that the hold no longer names goes, and others stay" do
      hold = %{reason: "waiting on TP-2", clearing_condition: "c", waits_on: %{type: "dependency", keys: ["TP-2"]}}
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, hold)
      :ok = set_reason(Pauses.ticket_reason(:fix_ticket, "TP-900"), BlockedHold.reason_setter(:fix_ticket))
      :ok = set_reason(Pauses.ticket_reason(:landing, "TP-7"), %{kind: :rule, name: "Landing"})
      :ok = set_reason(%{kind: :person, waits_on: %{action: "unblock"}}, %{kind: :person, name: "Director"})

      assert BlockedHold.sync(issue(%{blocked_by: [blocker("TP-2", "Todo")]}), @terminal, settings: designed_settings()) == :none

      assert Pauses.why(@ticket) == [
               "Waiting for TP-7 to land: it changes the same files",
               "Waiting for you to unblock it",
               "Waiting for TP-2 to finish"
             ]
    end

    test "a blocker with no identifier is waited on by the hold only" do
      unnamed = issue(%{blocked_by: [%{id: "blocker-x", identifier: nil, state: "Todo"}]})
      assert BlockedHold.sync(unnamed, @terminal, settings: designed_settings()) == :set
      assert %{waits_on: %{keys: ["blocker-x"]}} = stored_hold()
      assert Pauses.get(@ticket) == {:ok, nil}
    end

    test "a reason the rules or a block report set that no hold names any more goes on the next sync; others stay" do
      # Its clear failed when the hold cleared, so the ticket has no hold and a reason left over.
      :ok = set_reason(Pauses.ticket_reason(:dependency, "TP-5"), BlockedHold.reason_setter(:dependency))
      :ok = set_reason(Pauses.ticket_reason(:dependency, "TP-6"), %{kind: :run, name: "The run"})
      :ok = set_reason(Pauses.ticket_reason(:dependency, "TP-8"), %{kind: :person, name: "Director"})

      assert BlockedHold.sync(issue(), @terminal, settings: designed_settings()) == :none
      assert Pauses.why(@ticket) == ["Waiting for TP-8 to finish"]

      # Another writer's hold replaced the fix-ticket one: its reason goes, the landing hold's stays.
      :ok = RunStore.clear()
      :ok = set_reason(Pauses.ticket_reason(:fix_ticket, "TP-900"), BlockedHold.reason_setter(:fix_ticket))
      :ok = set_reason(Pauses.ticket_reason(:landing, "TP-7"), %{kind: :rule, name: "Landing"})
      landing = BlockedHold.landing_attrs([%{issue_identifier: "TP-7", files: ["a.ex"]}])
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, landing)

      assert BlockedHold.sync(issue(), @terminal, settings: designed_settings()) == :none
      assert Pauses.why(@ticket) == ["Waiting for TP-7 to land: it changes the same files"]
      assert BlockedHold.landing?(stored_hold())

      # A ticket nothing paused reads no pause and records nothing.
      :ok = RunStore.clear()
      assert BlockedHold.sync(issue(), @terminal, settings: designed_settings()) == :none
      assert Pauses.get(@ticket) == {:ok, nil}
      assert ticket_events(@repo_key, @issue_id) == []
    end

    test "a run's block report outside Todo: a blocker done clears its reason, the hold stays as it was, the last clears both" do
      hold = %{reason: "the run reported a block: waiting on TP-1, TP-2", clearing_condition: "c", waits_on: %{type: "dependency", keys: ["TP-1", "TP-2"]}}
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, hold)
      for id <- ["TP-1", "TP-2"], do: :ok = set_reason(Pauses.ticket_reason(:dependency, id), %{kind: :run, name: "The run"})
      stored = stored_hold()

      both_open = issue(%{state: "In Progress", blocked_by: [blocker("TP-1", "In Progress"), blocker("TP-2", "Todo")]})
      assert BlockedHold.sync(both_open, @terminal, settings: designed_settings()) == :none
      assert Pauses.why(@ticket) == ["Waiting for TP-1 to finish", "Waiting for TP-2 to finish"]

      for state <- ["In Progress", "Rework"] do
        one_left = issue(%{state: state, blocked_by: [blocker("TP-1", "Done"), blocker("TP-2", "Todo")]})
        assert BlockedHold.sync(one_left, @terminal, settings: designed_settings()) == :none
        assert Pauses.why(@ticket) == ["Waiting for TP-2 to finish"]
        assert stored_hold() == stored
      end

      done = issue(%{state: "Rework", blocked_by: [blocker("TP-1", "Done"), blocker("TP-2", "Done")]})
      assert BlockedHold.sync(done, @terminal, settings: designed_settings(), build: %{sha: nil}) == :clear
      assert Pauses.get(@ticket) == {:ok, nil}
      assert stored_hold() == nil
    end

    test "a hold the store refuses writes no reason" do
      blocked = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      capture_log(fn -> assert BlockedHold.sync(blocked, @terminal, settings: designed_settings(), store: FailingStore) == :none end)

      assert Pauses.get(@ticket) == {:ok, nil}
    end
  end

  defp set_reason(reason, set_by) do
    with {:ok, _pause} <- Pauses.set(@ticket, reason, set_by: set_by), do: :ok
  end

  describe "the landing hold (TP-989)" do
    @tracked %{issue_identifier: "TP-1", pr_number: 1, pr_url: "https://github.com/acme/app/pull/1", files: ["SPEC.md", "a.ex"]}
    @person %{pr_number: 12, pr_url: "https://github.com/acme/app/pull/12", title: "Docs pass", files: ["SPEC.md", "b.md"]}
    @untitled %{pr_number: 13, files: ["SPEC.md"]}

    test "names each competitor, its ticket else its PR, and the files they share" do
      assert BlockedHold.landing_attrs([@tracked, @person, @untitled]) == %{
               reason: "Waiting on TP-1 and PR #12 (Docs pass) and PR #13 to land: they change the same files (SPEC.md, a.ex, b.md)",
               clearing_condition: "when every competing pull request lands or leaves the race",
               waits_on: %{type: "landing", keys: ["TP-1", "https://github.com/acme/app/pull/12", "PR #13"]}
             }

      assert BlockedHold.landing?(BlockedHold.landing_attrs([@tracked]))
      refute BlockedHold.landing?(%{waits_on: %{type: "dependency", keys: []}})
      refute BlockedHold.landing?(nil)
    end

    test "clears once no competitor is left, renames the ones left, and leaves another hold alone" do
      hold = BlockedHold.landing_attrs([@tracked, @person])

      assert BlockedHold.landing_desired(hold, []) == :clear
      assert BlockedHold.landing_desired(hold, [@tracked, @person]) == :none
      assert {:set, %{reason: "Waiting on TP-1 to land: they change the same files (SPEC.md, a.ex)"}} = BlockedHold.landing_desired(hold, [@tracked])
      assert BlockedHold.landing_desired(%{waits_on: %{type: "access", keys: []}}, []) == :none
      assert BlockedHold.landing_desired(nil, [@tracked]) == :none
    end

    test "has one pause reason per competitor beside it, which the Director may release" do
      competitors = [@tracked, @person, @untitled, @tracked, %{files: ["SPEC.md"]}, %{issue_identifier: "not-a-ticket", files: []}]

      assert BlockedHold.landing_reasons(competitors) == [
               %{kind: :ticket, waits_on: %{identifier: "TP-1"}, text: "Waiting for TP-1 to land: it changes the same files", releasable: true},
               %{
                 kind: :environment,
                 waits_on: %{condition: "pull_request:12"},
                 text: "Waiting for PR #12 (Docs pass) to land: it changes the same files",
                 releasable: true
               },
               %{kind: :environment, waits_on: %{condition: "pull_request:13"}, text: "Waiting for PR #13 to land: it changes the same files", releasable: true}
             ]

      long = BlockedHold.landing_reasons([%{@person | title: String.duplicate("x", 400)}])
      assert [%{text: text}] = long
      assert String.length(text) < 300

      assert BlockedHold.reason_setter(:landing) == %{kind: :rule, name: "Competing pull requests"}
    end

    test "tells a landing reason from any other, whoever wrote it" do
      for reason <- BlockedHold.landing_reasons([@tracked, @person]), do: assert(BlockedHold.landing_reason?(reason))

      refute BlockedHold.landing_reason?(Pauses.ticket_reason(:dependency, "TP-1"))
      refute BlockedHold.landing_reason?(%{kind: :environment, waits_on: %{condition: "pull_request:12 and more"}})
      refute BlockedHold.landing_reason?(%{kind: :question, waits_on: %{question_id: "q1"}})
      refute BlockedHold.landing_reason?(nil)
    end

    test "the sweep leaves a landing hold to the PR watcher, in any phase" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, BlockedHold.landing_attrs([@tracked]))

      for state <- ["Todo", "Merging"] do
        assert BlockedHold.sync(issue(state: state, blocked_by: [blocker("TP-1", "Done")]), @terminal, settings: designed_settings()) == :none
        assert BlockedHold.landing?(stored_hold())
      end
    end
  end

  describe "the fix-ticket hold" do
    test "wants the clear only once the fix ticket is terminal" do
      hold = %{waits_on: %{type: "fix_ticket", keys: ["TP-900"]}}

      assert BlockedHold.fix_ticket_desired(hold, "Done", @terminal) == :clear
      assert BlockedHold.fix_ticket_desired(hold, "In Progress", @terminal) == :none
      assert BlockedHold.fix_ticket_desired(hold, nil, @terminal) == :none
      assert BlockedHold.fix_ticket_desired(%{waits_on: %{type: "dependency", keys: ["TP-1"]}}, "Done", @terminal) == :none
      assert BlockedHold.fix_ticket_desired(%{waits_on: %{type: "fix_ticket", keys: []}}, "Done", @terminal) == :none
      assert BlockedHold.fix_ticket_desired(nil, "Done", @terminal) == :none
    end

    test "lifts the hold when the fix ticket goes terminal, keeping the failure signature" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, fix_hold_attrs())

      :ok =
        RunStore.record_ticket_self_heal(@repo_key, @issue_id, %{
          component: "dev_server",
          scope: @repo_key,
          signature: "s",
          fix_ticket: "TP-900",
          attempts: 2
        })

      Process.put({:fix_ticket, "TP-900"}, {:ok, %Issue{id: "fix-id", identifier: "TP-900", state: "Done"}})

      :ok = set_reason(Pauses.ticket_reason(:fix_ticket, "TP-900"), BlockedHold.reason_setter(:fix_ticket))
      assert BlockedHold.sync(issue(), @terminal, settings: designed_settings(), tracker: FixTicketTracker) == :clear

      assert stored_hold() == nil
      assert Pauses.get(@ticket) == {:ok, nil}

      # Only the stale fix-ticket pointer goes: the component, the signature and the retry count
      # stay, so a break that comes back after the repair is compared against this failure.
      assert %{component: "dev_server", signature: "s", fix_ticket: nil, attempts: 2} =
               RunStore.get_ticket_state(@repo_key, @issue_id) |> SymphonyElixir.TicketState.self_heal()

      assert labels() == []
    end

    test "leaves the hold alone while the fix ticket is still open, or its state is unreadable" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, fix_hold_attrs())

      Process.put({:fix_ticket, "TP-900"}, {:ok, %Issue{id: "fix-id", identifier: "TP-900", state: "In Progress"}})

      assert BlockedHold.sync(issue(), @terminal, settings: designed_settings(), tracker: FixTicketTracker) == :none
      assert stored_hold() != nil
      # A hold whose pause lacks its reason gets it on the next sync.
      assert Pauses.why(@ticket) == [@fix_line]

      Process.delete({:fix_ticket, "TP-900"})

      assert BlockedHold.sync(issue(), @terminal, settings: designed_settings(), tracker: FixTicketTracker) == :none
      assert stored_hold() != nil
    end

    test "a fix-ticket hold with no fix ticket named is left alone" do
      :ok =
        RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, %{
          reason: "waiting on a fix ticket",
          clearing_condition: "when it is terminal",
          waits_on: %{type: "fix_ticket", keys: []}
        })

      assert BlockedHold.sync(issue(), @terminal, settings: designed_settings(), tracker: FixTicketTracker) == :none
      assert stored_hold() != nil
    end

    test "a stale fix-ticket pointer that cannot be dropped is logged and the hold still lifts" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, fix_hold_attrs())
      Process.put({:fix_ticket, "TP-900"}, {:ok, %Issue{id: "fix-id", identifier: "TP-900", state: "Done"}})

      log =
        capture_log(fn ->
          assert BlockedHold.sync(issue(), @terminal, settings: designed_settings(), store: UnforgettableStore, tracker: FixTicketTracker) == :clear
        end)

      assert log =~ "Failed to drop the stale fix ticket"
    end
  end

  describe "the fix-ticket hold on a fix to Symphony itself" do
    @build_sha "bbbbbbb0123456789abcdef0123456789abcdef0"
    @next_build_sha "ccccccc0123456789abcdef0123456789abcdef0"
    @merge_sha "aaaaaaa0123456789abcdef0123456789abcdef0"
    @symphony_pr "https://github.com/acme/symphony/pull/12"

    defp build(sha \\ @build_sha), do: %{version: "0.0.1.200", sha: sha, repo: "https://github.com/acme/symphony"}

    defp merged_fix(pr_url \\ @symphony_pr) do
      fix = %Issue{id: "fix-id", identifier: "TP-900", state: "Done", repo_key: @repo_key}
      record_merged(fix, pr_url)
      Process.put({:fix_ticket, "TP-900"}, {:ok, fix})
    end

    # The GitHub lookups `UpdateHold` makes: each call is reported, and the running build includes
    # the merge commit only from `@next_build_sha` on.
    defp lookups do
      test_pid = self()

      [
        merge_commit_sha: fn @symphony_pr ->
          send(test_pid, :merge_commit_sha)
          {:ok, @merge_sha}
        end,
        commit_included?: fn @symphony_pr, @merge_sha, build_sha ->
          send(test_pid, {:commit_included?, build_sha})
          {:ok, build_sha == @next_build_sha}
        end
      ]
    end

    defp sweep_fix_hold(build, cache) do
      opts = [settings: designed_settings(), tracker: FixTicketTracker, build: build, update_hold_cache: cache]
      BlockedHold.sweep([issue(%{state: "QA"})], @terminal, opts ++ lookups())
    end

    test "stays until the running build includes the fix's merge commit, then lifts on its own" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, fix_hold_attrs())
      merged_fix()

      # The fix ticket is Done, but the running app was built before its merge: the hold stays and
      # says it waits for the app update.
      assert {1, cache} = sweep_fix_hold(build(), UpdateHold.empty_cache())
      assert_received :merge_commit_sha
      assert_received {:commit_included?, @build_sha}

      assert %{reason: reason, clearing_condition: condition, waits_on: %{type: "fix_ticket", keys: ["TP-900"]}} = stored_hold()
      assert reason == "waiting for an app update: fix ticket TP-900 merged in `aaaaaaa`, running `bbbbbbb`"
      assert condition == "when the running app includes the fix ticket TP-900's merge"
      # The pause waits on the fix ticket as long as its hold does.
      assert Pauses.why(@ticket) == [@fix_line]

      # The next poll on the same build changes nothing and looks nothing up again.
      assert {0, ^cache} = sweep_fix_hold(build(), cache)
      refute_received :merge_commit_sha
      refute_received {:commit_included?, _sha}
      assert stored_hold().reason == reason

      # The app updates to a build that includes the merge: the hold lifts with no one involved.
      assert {1, _cache} = sweep_fix_hold(build(@next_build_sha), cache)
      assert_received {:commit_included?, @next_build_sha}
      assert stored_hold() == nil
      assert Pauses.get(@ticket) == {:ok, nil}
    end

    test "lifts at once when the build has no sha, a lookup fails, or a skip label opts out" do
      merged_fix()

      for {build, extra, held_labels} <- [
            {build(nil), [], []},
            {build(), [merge_commit_sha: fn _url -> {:error, :rate_limited} end], []},
            {build(), [], [UpdateHold.skip_label()]}
          ] do
        :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, fix_hold_attrs())
        opts = extra ++ [settings: designed_settings(), tracker: FixTicketTracker, build: build] ++ lookups()

        assert BlockedHold.sync(issue(%{state: "QA", labels: held_labels}), @terminal, opts) == :clear
        assert stored_hold() == nil
      end
    end

    test "a fix merged in another repository lifts the hold when it is terminal, as before" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, fix_hold_attrs())
      merged_fix("https://github.com/acme/web-app/pull/5")

      assert {1, _cache} = sweep_fix_hold(build(), UpdateHold.empty_cache())
      refute_received :merge_commit_sha
      assert stored_hold() == nil
    end
  end

  describe "the dependency hold a run's block report set outside Todo" do
    defp block_report_attrs do
      %{
        reason: "the run reported a block: waiting on TP-997",
        clearing_condition: "when every blocker is terminal",
        waits_on: %{type: "dependency", keys: ["TP-997"]}
      }
    end

    defp merged_blocker(pr_url \\ @symphony_pr) do
      blocker = %Issue{id: "blocker-TP-997", identifier: "TP-997", state: "Done", repo_key: @repo_key}
      record_merged(blocker, pr_url)
      Process.put({:fix_ticket, "TP-997"}, {:ok, blocker})
    end

    defp held(state, blocker_state, labels \\ []) do
      issue(%{state: state, labels: labels, blocked_by: [blocker("TP-997", blocker_state)]})
    end

    defp sweep_dependency_hold(issue, build, cache) do
      opts = [settings: designed_settings(), tracker: FixTicketTracker, build: build, update_hold_cache: cache]
      BlockedHold.sweep([issue], @terminal, opts ++ lookups())
    end

    test "stays in the ticket's phase while a blocker is open" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, block_report_attrs())

      for state <- ["In Progress", "Rework"] do
        assert {0, _cache} = sweep_dependency_hold(held(state, "Merging"), build(), UpdateHold.empty_cache())
        assert stored_hold().reason == "the run reported a block: waiting on TP-997"
      end

      refute_received :merge_commit_sha
    end

    test "lifts once every blocker is terminal, with no person's Unblock" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, block_report_attrs())
      merged_blocker("https://github.com/acme/web-app/pull/5")

      assert {1, _cache} = sweep_dependency_hold(held("In Progress", "Done"), build(), UpdateHold.empty_cache())
      refute_received :merge_commit_sha
      assert stored_hold() == nil
    end

    test "waits for the running app to include a blocker that fixed Symphony itself, then lifts" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, block_report_attrs())
      merged_blocker()

      assert {1, cache} = sweep_dependency_hold(held("Rework", "Done"), build(), UpdateHold.empty_cache())
      assert_received :merge_commit_sha
      assert_received {:commit_included?, @build_sha}

      assert %{reason: reason, clearing_condition: condition, waits_on: %{type: "dependency", keys: ["TP-997"]}} = stored_hold()
      assert reason == "waiting for an app update: TP-997 merged in `aaaaaaa`, running `bbbbbbb`"
      assert condition == "when the running app includes the merge of TP-997"
      # The pause waits on the blocker as long as its hold waits for the app update.
      assert Pauses.why(@ticket) == ["Waiting for TP-997 to finish"]

      # The next poll on the same build changes nothing and reads nothing again, not even the
      # blocker: an unreadable blocker would have lifted the hold.
      Process.delete({:fix_ticket, "TP-997"})
      assert {0, ^cache} = sweep_dependency_hold(held("Rework", "Done"), build(), cache)
      refute_received :merge_commit_sha
      refute_received {:commit_included?, _sha}
      assert stored_hold().reason == reason

      assert Pauses.why(@ticket) == ["Waiting for TP-997 to finish"]

      # The app updates to a build that includes the merge: the hold lifts, the ticket stays in Rework.
      assert {1, _cache} = sweep_dependency_hold(held("Rework", "Done"), build(@next_build_sha), cache)
      assert_received {:commit_included?, @next_build_sha}
      assert stored_hold() == nil
      assert Pauses.get(@ticket) == {:ok, nil}
    end

    test "lifts at once when the build has no sha, the blocker can't be read, or a skip label opts out" do
      unnamed = issue(%{state: "In Progress", blocked_by: [%{id: "blocker-x", identifier: nil, state: "Done"}]})

      for {issue, build, readable?} <- [
            {held("In Progress", "Done"), build(nil), true},
            {held("In Progress", "Done"), build(), false},
            {unnamed, build(), true},
            {held("In Progress", "Done", [UpdateHold.skip_label()]), build(), true}
          ] do
        :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, block_report_attrs())
        if readable?, do: merged_blocker(), else: Process.delete({:fix_ticket, "TP-997"})
        opts = [settings: designed_settings(), tracker: FixTicketTracker, build: build] ++ lookups()

        assert BlockedHold.sync(issue, @terminal, opts) == :clear
        assert stored_hold() == nil
      end

      refute_received :merge_commit_sha
    end

    test "a Todo ticket's dependency hold clears at once: its dispatch gate waits for the app update" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, block_report_attrs())
      merged_blocker()

      assert {1, _cache} = sweep_dependency_hold(held("Todo", "Done"), build(), UpdateHold.empty_cache())
      refute_received :merge_commit_sha
      assert stored_hold() == nil
    end
  end

  describe "sweep/3" do
    test "counts the holds it set and cleared over a repo's issues" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})
      other = %{open_issue | id: "issue-2", blocked_by: []}

      assert {1, _cache} = BlockedHold.sweep([open_issue, other], @terminal, settings: designed_settings())

      unblocked = %{open_issue | blocked_by: [blocker("TP-1", "Done")]}
      assert {1, _cache} = BlockedHold.sweep([unblocked, other], @terminal, settings: designed_settings())
    end

    test "counts nothing for a repo it can't resolve or without a list" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      cache = UpdateHold.empty_cache()
      assert BlockedHold.sweep([open_issue], @terminal, settings: nil) == {0, cache}
      assert BlockedHold.sweep(:not_a_list, @terminal, settings: designed_settings()) == {0, cache}
      # Without the caller's settings the repo is resolved from the issue's key.
      assert BlockedHold.sweep([open_issue], @terminal) == {0, cache}
    end
  end

  describe "the Hold read path" do
    test "get/4 reads the dependency hold's wait target" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})
      :set = BlockedHold.sync(open_issue, @terminal, settings: designed_settings())

      assert %{waits_on: %{type: "dependency", keys: ["TP-1"]}} = Hold.get(@repo_key, @issue_id, :blocked)
    end
  end
end
