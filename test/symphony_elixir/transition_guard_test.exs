defmodule SymphonyElixir.TransitionGuardTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{TicketState, TransitionGuard}

  defmodule FakeTracker do
    def update_issue_state(issue_id, state) do
      send(self(), {:moved, issue_id, state})
      Process.get(:transition_guard_tracker_result, :ok)
    end
  end

  # Reads the ticket's record when Linear is asked, so a test sees what the record held by then.
  defmodule RecordReadingTracker do
    def update_issue_state(issue_id, state) do
      send(self(), {:moved, issue_id, state, RunStore.get_ticket_state("repo-guard", issue_id)})
      Process.get(:transition_guard_tracker_result, :ok)
    end
  end

  defp settings!(attrs) do
    assert {:ok, settings} = Schema.parse(attrs)
    settings
  end

  defp memory_settings(extra \\ %{}) do
    settings!(%{"tracker" => Map.merge(%{"kind" => "memory"}, extra)})
  end

  defp state(name, id \\ "state-id"), do: %{"id" => id, "name" => name}

  defp designed_settings(extra \\ %{}) do
    settings!(Map.merge(%{"tracker" => %{"kind" => "memory"}}, extra))
  end

  describe "edges/0 and signals/0" do
    test "every row names a signal, origins and a target, and signals are unique" do
      edges = TransitionGuard.edges()

      assert Enum.any?(edges)
      signals = Enum.map(edges, & &1.signal)

      assert signals == Enum.uniq(signals)
      assert TransitionGuard.signals() == signals

      for edge <- edges do
        assert is_atom(edge.signal)
        assert edge.from == :any or (is_list(edge.from) and edge.from != [])
        assert is_binary(edge.to) or edge.to in [:requested, :waiting_on_sub_issues, :code_review_state, :qa_state, :epic_review_state, :ci_fix_state]
      end
    end

    test "every literal target is reachable through target/2" do
      for %{signal: signal, to: to} <- TransitionGuard.edges(), is_binary(to) do
        assert TransitionGuard.target(signal, %{}) == to
      end
    end
  end

  describe "the edge table" do
    test "is the one machine's table, in order" do
      assert TransitionGuard.edges() == [
               %{signal: :claim, from: ["Todo"], to: "In Progress"},
               %{signal: :plan_revise, from: ["Plan Review"], to: "Rework"},
               %{signal: :plan_approve, from: ["In Progress"], to: :waiting_on_sub_issues},
               %{signal: :ci_fix_dispatch, from: :any, to: "In Progress"},
               %{signal: :landing_done, from: ["Merging"], to: "Done"},
               %{signal: :review_rework, from: :any, to: "In Progress"},
               %{signal: :merge_ready, from: ["Rework", "In Progress"], to: "Merging"},
               %{signal: :idle_park, from: ["In Progress", "Rework"], to: "Backlog"},
               %{signal: :director_move, from: :any, to: :requested},
               %{signal: :sub_issues_done, from: ["Waiting on sub-tickets"], to: "Done"},
               %{signal: :wait_on_merge, from: ["In Progress", "Code Review", "QA", "Rework", "CI Fix", "Merging"], to: :waiting_on_sub_issues},
               %{signal: :breakdown_promote, from: ["Backlog"], to: "Todo"},
               %{signal: :breakdown_cancel, from: ["Backlog"], to: :requested},
               %{signal: :restart, from: :any, to: "In Progress"},
               %{signal: :handoff, from: ["In Progress", "Rework"], to: :code_review_state},
               %{signal: :code_review_approve, from: ["Code Review"], to: :qa_state},
               %{signal: :code_review_approve_skip, from: ["Code Review"], to: "Merging", confirm: true},
               %{signal: :code_review_rework, from: ["Code Review"], to: "Rework"},
               %{signal: :qa_pass, from: ["QA"], to: "Merging", confirm: true},
               %{signal: :qa_skip, from: ["QA"], to: "Merging", confirm: true},
               %{signal: :qa_fail, from: ["QA"], to: "Rework"},
               %{signal: :ci_fix_enter_code_review, from: ["Code Review"], to: :ci_fix_state},
               %{signal: :ci_fix_enter_qa, from: ["QA"], to: :ci_fix_state},
               %{signal: :ci_fix_enter_merging, from: ["Merging"], to: :ci_fix_state},
               %{signal: :ci_fix_enter_rework, from: ["Rework"], to: :ci_fix_state},
               %{signal: :ci_fix_mechanical, from: ["CI Fix"], to: :requested},
               %{signal: :person_push, from: ["Merging"], to: :code_review_state},
               %{signal: :conflict_rework, from: ["Code Review", "QA", "CI Fix", "Merging"], to: "Rework"},
               %{signal: :pr_closed, from: ["Code Review", "QA", "CI Fix", "Merging"], to: "Rework"},
               %{signal: :pr_merged, from: ["In Progress", "Code Review", "QA", "Rework", "CI Fix"], to: "Done"},
               %{signal: :epic_review_enter, from: ["Waiting on sub-tickets"], to: :epic_review_state},
               %{signal: :epic_review_pass, from: ["Epic Review"], to: "Done"},
               %{signal: :epic_review_gaps, from: ["Epic Review"], to: :waiting_on_sub_issues}
             ]
    end

    test "has no row into a retired state: escalations, decisions and dependency approvals are holds, not moves" do
      retired = [
        :ci_escalate,
        :dependency_review,
        :dependency_hold,
        :human_action_request,
        :human_action_release,
        :post_pr_handoff,
        :review_agent_blocked
      ]

      for signal <- retired do
        refute signal in TransitionGuard.signals(), inspect(signal)
      end

      for %{to: to} <- TransitionGuard.edges(), is_binary(to) do
        refute TransitionGuard.retired_state?(to), to
      end
    end

    test "the plan revise fires from Plan Review and moves through Rework" do
      assert TransitionGuard.target(:plan_revise, %{settings: designed_settings()}) == "Rework"
      assert TransitionGuard.legal?(:plan_revise, "Plan Review", "Rework")
      refute TransitionGuard.legal?(:plan_revise, "In Review")
    end
  end

  describe "the flow's edges" do
    test "the handoff moves In Progress or Rework to the configured Code Review state" do
      designed = designed_settings()

      assert TransitionGuard.legal?(:handoff, "In Progress", nil)
      assert TransitionGuard.legal?(:handoff, "Rework", nil)
      refute TransitionGuard.legal?(:handoff, "Todo", nil)

      assert TransitionGuard.target(:handoff, %{settings: designed}) == "Code Review"
    end

    test "the handoff target is the repo's configured Code Review state" do
      settings =
        settings!(%{
          "tracker" => %{"kind" => "memory", "code_review_state" => "Peer Review"}
        })

      assert TransitionGuard.target(:handoff, %{settings: settings}) == "Peer Review"
    end

    test "the reviewer's verdicts are designed edges out of Code Review" do
      designed = designed_settings()

      assert TransitionGuard.legal?(:code_review_approve, "Code Review", nil)
      assert TransitionGuard.legal?(:code_review_approve_skip, "Code Review", nil)
      assert TransitionGuard.legal?(:code_review_rework, "Code Review", nil)
      # An escalation is a Needs Decision hold, never a move: no edge fires it.
      refute TransitionGuard.legal?(:code_review_escalate, "Code Review", nil)
      refute TransitionGuard.legal?(:ci_escalate, "Code Review", nil)
      refute TransitionGuard.legal?(:code_review_approve, "In Progress", nil)

      assert TransitionGuard.target(:code_review_approve, %{settings: designed}) == "QA"
      assert TransitionGuard.target(:code_review_approve_skip, %{settings: designed}) == "Merging"
      assert TransitionGuard.target(:code_review_rework, %{settings: designed}) == "Rework"
    end

    test "an approve enters the repo's configured QA state, or Merging when QA is skipped" do
      settings =
        settings!(%{
          "tracker" => %{"kind" => "memory", "qa_state" => "Verification"}
        })

      assert TransitionGuard.target(:code_review_approve, %{settings: settings}) == "Verification"
      assert TransitionGuard.target(:code_review_approve_skip, %{settings: settings}) == "Merging"
    end

    test "the QA run's verdicts are designed edges out of QA" do
      designed = designed_settings()

      assert TransitionGuard.legal?(:qa_pass, "QA", nil)
      assert TransitionGuard.legal?(:qa_skip, "QA", nil)
      assert TransitionGuard.legal?(:qa_fail, "QA", nil)
      refute TransitionGuard.legal?(:qa_pass, "Merging", nil)
      refute TransitionGuard.legal?(:qa_fail, "Code Review", nil)

      assert TransitionGuard.target(:qa_pass, %{settings: designed}) == "Merging"
      assert TransitionGuard.target(:qa_skip, %{settings: designed}) == "Merging"
      assert TransitionGuard.target(:qa_fail, %{settings: designed}) == "Rework"
    end

    test "the CI Fix lane enters from each phase whose head can go red or conflict" do
      designed = designed_settings()

      assert TransitionGuard.legal?(:ci_fix_enter_code_review, "Code Review", nil)
      assert TransitionGuard.legal?(:ci_fix_enter_qa, "QA", nil)
      assert TransitionGuard.legal?(:ci_fix_enter_merging, "Merging", nil)
      assert TransitionGuard.legal?(:ci_fix_enter_rework, "Rework", nil)

      # Each entry names its own origin, so one phase's red head cannot enter the lane as another's.
      refute TransitionGuard.legal?(:ci_fix_enter_code_review, "QA", nil)
      refute TransitionGuard.legal?(:ci_fix_enter_qa, "Merging", nil)
      refute TransitionGuard.legal?(:ci_fix_enter_rework, "In Progress", nil)

      for signal <- [:ci_fix_enter_code_review, :ci_fix_enter_qa, :ci_fix_enter_merging, :ci_fix_enter_rework] do
        assert TransitionGuard.target(signal, %{settings: designed}) == "CI Fix"
      end
    end

    test "the CI Fix entry target is the repo's configured CI Fix state" do
      settings =
        settings!(%{
          "tracker" => %{"kind" => "memory", "ci_fix_state" => "Repair"}
        })

      assert TransitionGuard.target(:ci_fix_enter_qa, %{settings: settings}) == "Repair"
    end

    test "the mechanical return leaves CI Fix for the origin the caller read back from the ticket" do
      designed = designed_settings()

      assert TransitionGuard.legal?(:ci_fix_mechanical, "CI Fix", nil)
      refute TransitionGuard.legal?(:ci_fix_mechanical, "Merging", nil)

      for origin <- ["Code Review", "QA", "Merging", "Rework"] do
        assert TransitionGuard.target(:ci_fix_mechanical, %{target: origin, settings: designed}) == origin
      end
    end

    test "the PR watcher's moves: a person's push in Merging goes back to Code Review (D4), a conflict that came back goes to Rework (D16)" do
      assert TransitionGuard.legal?(:person_push, "Merging", nil)
      refute TransitionGuard.legal?(:person_push, "QA", nil)
      assert TransitionGuard.target(:person_push, %{settings: designed_settings()}) == "Code Review"
      assert TransitionGuard.target(:person_push, %{settings: settings!(%{"tracker" => %{"kind" => "memory", "code_review_state" => "Peer Review"}})}) == "Peer Review"

      for from <- ["Code Review", "QA", "CI Fix", "Merging"], do: assert(TransitionGuard.legal?(:conflict_rework, from, nil))
      refute TransitionGuard.legal?(:conflict_rework, "Rework", nil)
      assert TransitionGuard.target(:conflict_rework, %{settings: designed_settings()}) == "Rework"
    end

    test "the PR watcher's lifecycle moves: a closed PR goes to Rework (D5), a PR merged outside Merging closes the ticket" do
      for from <- ["Code Review", "QA", "CI Fix", "Merging"], do: assert(TransitionGuard.legal?(:pr_closed, from, "Rework"))
      refute TransitionGuard.legal?(:pr_closed, "Rework", nil)
      refute TransitionGuard.legal?(:pr_closed, "In Progress", nil)

      for from <- ["In Progress", "Code Review", "QA", "Rework", "CI Fix"], do: assert(TransitionGuard.legal?(:pr_merged, from, "Done"))
      refute TransitionGuard.legal?(:pr_merged, "Merging", nil)

      for from <- ["In Progress", "Code Review", "QA", "Rework", "CI Fix", "Merging"], do: assert(TransitionGuard.legal?(:wait_on_merge, from, nil))
      assert TransitionGuard.target(:wait_on_merge, %{settings: designed_settings()}) == "Waiting on sub-tickets"
      assert TransitionGuard.target(:epic_review_enter, %{settings: designed_settings()}) == "Epic Review"
    end
  end

  describe "confirmation_required?/2" do
    test "is true only for the verdicts into Merging, and only with manual review on" do
      on = designed_settings(%{"manual_review" => "on"})
      off = designed_settings(%{"manual_review" => "off"})

      for signal <- [:code_review_approve_skip, :qa_pass, :qa_skip] do
        assert TransitionGuard.confirmation_required?(signal, %{settings: on})
        refute TransitionGuard.confirmation_required?(signal, %{settings: off})
      end
    end

    test "a verdict that does not land in Merging never waits: rework, escalation, approve-to-QA" do
      on = designed_settings(%{"manual_review" => "on"})

      signals = [
        :code_review_approve,
        :code_review_rework,
        :code_review_escalate,
        :qa_fail,
        :handoff,
        :ci_fix_mechanical
      ]

      for signal <- signals do
        refute TransitionGuard.confirmation_required?(signal, %{settings: on})
      end
    end

    test "an unknown signal and no settings are false" do
      refute TransitionGuard.confirmation_required?(:not_a_signal, %{settings: designed_settings(%{"manual_review" => "on"})})
      refute TransitionGuard.confirmation_required?(:qa_pass, %{})
      refute TransitionGuard.confirmation_required?(:qa_pass, %{repo_key: "web"})
    end

    test "an unset or unknown setting is off" do
      for settings <- [designed_settings(), designed_settings(%{"manual_review" => nil})] do
        refute TransitionGuard.confirmation_required?(:qa_pass, %{settings: settings})
      end

      # The runtime schema refuses an unknown value, so the guard only ever sees the two.
      assert {:error, _reason} = Schema.parse(%{"manual_review" => "maybe"})
    end
  end

  describe "legal?/3" do
    test "is false for an unknown signal" do
      refute TransitionGuard.legal?(:not_a_signal, "Todo")
      refute TransitionGuard.legal?(:not_a_signal, "Todo", "Done")
    end

    test "matches an origin case-insensitively and ignoring surrounding space" do
      assert TransitionGuard.legal?(:claim, "Todo")
      assert TransitionGuard.legal?(:claim, " todo ")
      assert TransitionGuard.legal?(:claim, "TODO")
      refute TransitionGuard.legal?(:claim, "In Progress")
    end

    test "an :any origin accepts any state and a missing one" do
      assert TransitionGuard.legal?(:ci_fix_dispatch, "Rework")
      assert TransitionGuard.legal?(:ci_fix_dispatch, nil)
      assert TransitionGuard.legal?(:ci_fix_dispatch, 5)
    end

    test "a missing origin is not legal for an edge with named origins" do
      refute TransitionGuard.legal?(:claim, nil)
    end

    test "checks the literal target only when one is given" do
      assert TransitionGuard.legal?(:claim, "Todo", "In Progress")
      refute TransitionGuard.legal?(:claim, "Todo", "Done")
      # A non-literal `to` (a requested or config-derived target) accepts any given target.
      assert TransitionGuard.legal?(:director_move, "Todo", "Whatever")
      assert TransitionGuard.legal?(:director_move, "Todo", nil)
    end

    test "a non-binary target name does not match a literal" do
      refute TransitionGuard.legal?(:claim, "Todo", 5)
    end
  end

  describe "target/2" do
    test "returns a literal target" do
      assert TransitionGuard.target(:claim, %{}) == "In Progress"
      assert TransitionGuard.target(:merge_ready, %{}) == "Merging"
      assert TransitionGuard.target(:sub_issues_done, %{}) == "Done"
    end

    test "reads a requested target from ctx" do
      assert TransitionGuard.target(:director_move, %{target: "Todo"}) == "Todo"
      assert TransitionGuard.target(:ci_fix_mechanical, %{target: "QA"}) == "QA"
    end

    test "resolves the waiting state from settings, and nil when it is turned off" do
      assert TransitionGuard.target(:plan_approve, %{settings: memory_settings()}) == "Waiting on sub-tickets"

      assert TransitionGuard.target(:wait_on_merge, %{settings: memory_settings(%{"waiting_on_sub_issues_state" => nil})}) ==
               nil
    end

    test "raises for an unknown signal" do
      assert_raise ArgumentError, ~r/unknown transition signal: :not_a_signal/, fn ->
        TransitionGuard.target(:not_a_signal, %{})
      end
    end
  end

  describe "perform/4" do
    test "moves through the given tracker with the resolved target" do
      assert :ok = TransitionGuard.perform("issue-1", :director_move, %{target: "Todo"}, tracker: FakeTracker)
      assert_received {:moved, "issue-1", "Todo"}
    end

    test "asks the PR poller to poll once the issue moved into Merging" do
      test_pid = self()
      opts = [tracker: FakeTracker, on_merging: fn -> send(test_pid, :polled) end]

      assert :ok = TransitionGuard.perform("issue-4", :director_move, %{target: "Merging"}, opts)
      assert_received {:moved, "issue-4", "Merging"}
      assert_received :polled

      assert :ok = TransitionGuard.perform("issue-5", :director_move, %{target: "Todo"}, opts)
      refute_received :polled

      Process.put(:transition_guard_tracker_result, {:error, :rate_limited})
      assert {:error, :rate_limited} = TransitionGuard.perform("issue-6", :director_move, %{target: "Merging"}, opts)
      refute_received :polled
    end

    test "polls the running PR poller by default after a move into Merging" do
      assert :ok = TransitionGuard.perform("issue-7", :director_move, %{target: "Merging"}, tracker: FakeTracker)
      assert_received {:moved, "issue-7", "Merging"}
    end

    test "returns the tracker's error" do
      Process.put(:transition_guard_tracker_result, {:error, :rate_limited})

      assert {:error, :rate_limited} =
               TransitionGuard.perform("issue-2", :director_move, %{target: "Todo"}, tracker: FakeTracker)

      assert_received {:moved, "issue-2", "Todo"}
    end

    test "refuses a move into a retired state without touching the tracker" do
      assert {:error, {:retired_state, "Auto Review"}} =
               TransitionGuard.perform("issue-4", :director_move, %{target: "Auto Review"}, tracker: FakeTracker)

      refute_received {:moved, "issue-4", _state}

      for retired <- ["In Review", "Human Review"] do
        assert {:error, {:retired_state, ^retired}} =
                 TransitionGuard.perform("issue-4", :director_move, %{target: retired}, tracker: FakeTracker)
      end

      refute_received {:moved, "issue-4", _state}
      assert TransitionGuard.retired_states() == ["Auto Review", "In Review", "Human Review"]
      assert TransitionGuard.retired_state?(" auto review ")
      assert TransitionGuard.retired_state?("human review")
      refute TransitionGuard.retired_state?(nil)
    end

    test "refuses a move whose target resolves to no state name without touching the tracker" do
      for target <- [nil, "", "  "] do
        assert {:error, {:unresolved_target, :director_move}} =
                 TransitionGuard.perform("issue-8", :director_move, %{target: target}, tracker: FakeTracker)
      end

      refute_received {:moved, "issue-8", _state}
    end

    test "writes the target as the record's phase before Linear is asked, and leaves what a read of Linear wrote" do
      seen = ~U[2026-10-29 10:00:00Z]
      RunStore.delete_ticket_state("repo-guard", "issue-9")
      :ok = RunStore.put_ticket_state(TicketState.new("repo-guard", "issue-9", %{phase: "Todo", issue_identifier: "MT-9", linear_updated_at: seen}))

      assert :ok = TransitionGuard.perform("issue-9", :claim, %{repo_key: "repo-guard"}, tracker: RecordReadingTracker)

      assert_received {:moved, "issue-9", "In Progress", %{phase: "In Progress"}}
      assert %{phase: "In Progress", issue_identifier: "MT-9", linear_updated_at: ^seen} = RunStore.get_ticket_state("repo-guard", "issue-9")
    end

    test "a move Linear refuses leaves the record moved and logs the identifier and the target" do
      RunStore.delete_ticket_state("repo-guard", "issue-10")
      :ok = RunStore.put_ticket_state(TicketState.new("repo-guard", "issue-10", %{phase: "Code Review", issue_identifier: "MT-10"}))
      Process.put(:transition_guard_tracker_result, {:error, :unauthorized})

      {ctx, opts} = {%{target: "Rework", repo_key: "repo-guard"}, [tracker: RecordReadingTracker]}

      log =
        capture_log(fn ->
          assert {:error, :unauthorized} = TransitionGuard.perform("issue-10", :director_move, ctx, opts)
        end)

      assert_received {:moved, "issue-10", "Rework", %{phase: "Rework"}}
      assert %{phase: "Rework"} = RunStore.get_ticket_state("repo-guard", "issue-10")
      assert log =~ "Linear refused the move; the record keeps it issue_id=issue-10 issue_identifier=MT-10 to=Rework reason=:unauthorized"
      # The reconciler projects it again (`TicketObservation.reconcile_all/3`).
      assert [%{type: :phase, error: ":unauthorized"}] = RunStore.get_ticket_state("repo-guard", "issue-10").pending_projection

      # The caller's identifier is the one logged; a move with no repo key writes no record.
      log =
        capture_log(fn ->
          ctx = %{target: "Rework", issue_identifier: "MT-11"}
          assert {:error, :unauthorized} = TransitionGuard.perform("issue-11", :director_move, ctx, tracker: FakeTracker)
        end)

      assert log =~ "issue_id=issue-11 issue_identifier=MT-11 to=Rework"
      assert RunStore.get_ticket_state("repo-guard", "issue-11") == nil

      log = capture_log(fn -> TransitionGuard.perform("issue-11", :director_move, %{target: "Rework"}, tracker: FakeTracker) end)
      assert log =~ "issue_id=issue-11 issue_identifier= to=Rework"
    end

    test "a target the team doesn't have puts the record back where it was and logs no refused move" do
      RunStore.delete_ticket_state("repo-guard", "issue-12")
      :ok = RunStore.put_ticket_state(TicketState.new("repo-guard", "issue-12", %{phase: "Backlog", issue_identifier: "MT-12"}))
      Process.put(:transition_guard_tracker_result, {:error, :state_not_found})
      {ctx, opts} = {%{target: "Canceled", repo_key: "repo-guard"}, [tracker: RecordReadingTracker]}

      log =
        capture_log(fn ->
          assert {:error, :state_not_found} = TransitionGuard.perform("issue-12", :breakdown_cancel, ctx, opts)
        end)

      # The record is written before Linear is asked, and put back once Linear names no such state.
      assert_received {:moved, "issue-12", "Canceled", %{phase: "Canceled"}}
      assert %{phase: "Backlog", issue_identifier: "MT-12"} = RunStore.get_ticket_state("repo-guard", "issue-12")
      refute log =~ "Linear refused the move"

      # A ticket the record held no phase for goes back to none.
      RunStore.delete_ticket_state("repo-guard", "issue-13")
      assert {:error, :state_not_found} = TransitionGuard.perform("issue-13", :breakdown_cancel, ctx, opts)
      assert_received {:moved, "issue-13", "Canceled", %{phase: "Canceled"}}
      assert %{phase: nil} = RunStore.get_ticket_state("repo-guard", "issue-13")
    end

    test "defaults to the configured tracker" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      assert :ok = TransitionGuard.perform("issue-3", :claim)
      assert_received {:memory_tracker_state_update, "issue-3", "In Progress"}
    end
  end

  describe "resolve_request/2" do
    test "passes an ordinary state through unchanged" do
      state = state("In Progress")

      assert {:ok, ^state} =
               TransitionGuard.resolve_request(state, %{settings: memory_settings()})
    end

    test "refuses an agent's move to Merging" do
      state = state("Merging")

      assert {:error, {:merging_requires_human_approval, "Merging"}} =
               TransitionGuard.resolve_request(state, %{settings: memory_settings()})
    end

    test "refuses an agent's move to a retired state, a plan parent's included" do
      assert {:error, {:retired_state, "Auto Review"}} =
               TransitionGuard.resolve_request(state("Auto Review"), %{settings: memory_settings()})

      assert {:error, {:retired_state, "auto review"}} =
               TransitionGuard.resolve_request(state("auto review"), %{settings: designed_settings()})

      for {name, from} <- [{"In Review", "In Progress"}, {"in review", "Rework"}, {"Human Review", "In Progress"}] do
        assert {:error, {:retired_state, ^name}} =
                 TransitionGuard.resolve_request(state(name), %{settings: designed_settings(), from_state: from})
      end

      assert {:error, {:retired_state, "In Review"}} =
               TransitionGuard.resolve_request(state("In Review"), %{settings: designed_settings(), plan_parent?: true})
    end

    test "refuses a hand move into Plan Review, except a plan parent's handoff" do
      assert {:error, {:plan_review_requires_handoff_signal, "Plan Review"}} =
               TransitionGuard.resolve_request(state("Plan Review"), %{settings: designed_settings()})

      # The refusal matches the name loosely.
      assert {:error, {:plan_review_requires_handoff_signal, "plan review"}} =
               TransitionGuard.resolve_request(state("plan review"), %{settings: designed_settings(), plan_parent?: false})

      # A plan parent naming Plan Review is the plan handoff itself: the request stands.
      assert {:ok, %{"name" => "Plan Review"}} =
               TransitionGuard.resolve_request(state("Plan Review"), %{settings: designed_settings(), plan_parent?: true})

      # A repo that turned the state off has no such state.
      assert {:ok, %{"name" => "Plan Review"}} =
               TransitionGuard.resolve_request(state("Plan Review"), %{
                 settings: designed_settings(%{"tracker" => %{"kind" => "memory", "plan_review_state" => nil}})
               })
    end

    test "refuses an agent's move to the waiting state" do
      assert {:error, {:waiting_on_sub_issues_state_requires_human_approval, "Waiting on sub-tickets"}} =
               TransitionGuard.resolve_request(state("Waiting on sub-tickets"), %{settings: memory_settings()})
    end

    test "refuses an agent's hand move into Code Review" do
      assert {:error, {:code_review_requires_handoff_signal, "Code Review"}} =
               TransitionGuard.resolve_request(state("Code Review"), %{settings: designed_settings()})
    end

    test "refuses an agent's move to In Progress from a phase past implementation" do
      # Every one of these phases has the work on a pull request, so
      # entering In Progress can only mean a Restart, which is a person's move.
      for from <- ["Rework", "Code Review", "QA", "Merging"] do
        assert {:error, {:restart_requires_human_approval, "In Progress"}} =
                 TransitionGuard.resolve_request(state("In Progress"), %{settings: designed_settings(), from_state: from})
      end

      # A casing difference still matches, and the claim from Todo and a phase with no pull
      # request yet are untouched.
      assert {:error, {:restart_requires_human_approval, "in progress"}} =
               TransitionGuard.resolve_request(state("in progress"), %{settings: designed_settings(), from_state: "rework"})

      assert {:ok, %{"name" => "In Progress"}} =
               TransitionGuard.resolve_request(state("In Progress"), %{settings: designed_settings(), from_state: "Todo"})

      assert {:ok, %{"name" => "In Progress"}} =
               TransitionGuard.resolve_request(state("In Progress"), %{settings: designed_settings(), from_state: nil})
    end

    test "the restart signal moves a ticket from any state to In Progress" do
      assert :restart in TransitionGuard.signals()
      assert TransitionGuard.target(:restart, %{settings: designed_settings()}) == "In Progress"

      assert TransitionGuard.legal?(:restart, "Merging", "In Progress")
      refute TransitionGuard.legal?(:restart, "Merging", "Rework")
    end

    test "refuses an agent's hand move into Epic Review" do
      assert {:error, {:epic_review_requires_machine_move, "Epic Review"}} =
               TransitionGuard.resolve_request(state("Epic Review"), %{settings: designed_settings()})
    end

    test "refuses an agent's hand move into QA" do
      assert {:error, {:qa_requires_verdict, "QA"}} =
               TransitionGuard.resolve_request(state("QA"), %{settings: designed_settings()})

      # The refusal names the state's configured name, and matches it loosely.
      assert {:error, {:qa_requires_verdict, "Verification"}} =
               TransitionGuard.resolve_request(state("Verification"), %{
                 settings: settings!(%{"tracker" => %{"kind" => "memory", "qa_state" => "Verification"}})
               })
    end

    test "allows the waiting state when it is turned off in config" do
      state = state("Waiting on sub-tickets")
      settings = memory_settings(%{"waiting_on_sub_issues_state" => nil})

      assert {:ok, ^state} = TransitionGuard.resolve_request(state, %{settings: settings})
    end
  end

  describe "resolve_request/2 and the Blocked hold" do
    test "turns an agent's Backlog request while working into a Blocked hold" do
      state = state("Backlog")

      assert {:hold, :blocked, attrs} =
               TransitionGuard.resolve_request(state, %{settings: designed_settings(), from_state: "In Progress"})

      assert attrs.reason =~ "reported a block"
      assert attrs.clearing_condition =~ "access hold"
      assert attrs.waits_on == %{type: "access", keys: []}
    end

    test "a run that marked its issue blocked by open tickets gets a dependency hold on them" do
      for from <- ["In Progress", "Rework"] do
        assert {:hold, :blocked, attrs} =
                 TransitionGuard.resolve_request(state("Backlog"), %{
                   settings: designed_settings(),
                   from_state: from,
                   open_blockers: ["TP-997", "TP-998"]
                 })

        assert attrs.reason == "the run reported a block: waiting on TP-997, TP-998"
        assert attrs.clearing_condition == "when every blocker is terminal"
        assert attrs.waits_on == %{type: "dependency", keys: ["TP-997", "TP-998"]}
      end
    end

    test "a block report with no open blocker keeps the access hold" do
      assert {:hold, :blocked, %{waits_on: %{type: "access", keys: []}}} =
               TransitionGuard.resolve_request(state("Backlog"), %{
                 settings: designed_settings(),
                 from_state: "In Progress",
                 open_blockers: []
               })
    end

    test "the hold fires from Rework too, matching the phase loosely" do
      for from <- ["Rework", " in progress ", "REWORK"] do
        assert {:hold, :blocked, _attrs} =
                 TransitionGuard.resolve_request(state("Backlog"), %{settings: designed_settings(), from_state: from})
      end
    end

    test "a Backlog request outside a running phase is an ordinary move" do
      state = state("Backlog")

      for from <- ["Todo", "Backlog", nil, 5] do
        assert {:ok, ^state} =
                 TransitionGuard.resolve_request(state, %{settings: designed_settings(), from_state: from})
      end
    end

    test "only a Backlog request is a hold: another state from a running phase is an ordinary move" do
      state = state("Rework")

      assert {:ok, ^state} =
               TransitionGuard.resolve_request(state, %{settings: designed_settings(), from_state: "In Progress"})
    end
  end
end
