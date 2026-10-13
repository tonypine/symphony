defmodule SymphonyElixir.TransitionGuardTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.TransitionGuard

  defmodule FakeTracker do
    def update_issue_state(issue_id, state) do
      send(self(), {:moved, issue_id, state})
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
    settings!(%{"tracker" => %{"kind" => "memory"}} |> Map.merge(extra))
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

        assert is_binary(edge.to) or
                 edge.to in [:requested, :waiting_on_sub_issues, :code_review_state, :qa_state, :ci_fix_state, :epic_review_state]
      end
    end

    test "every literal target is reachable through target/2" do
      for %{signal: signal, to: to} <- TransitionGuard.edges(), is_binary(to) do
        assert TransitionGuard.target(signal, %{}) == to
      end
    end
  end

  describe "the one edge table" do
    test "lists the machine's edges, and no move into a retired or draining state" do
      assert TransitionGuard.edges() == [
               %{signal: :claim, from: ["Todo"], to: "In Progress"},
               %{signal: :plan_revise, from: ["Plan Review"], to: "Rework"},
               %{signal: :plan_approve, from: ["In Progress"], to: :waiting_on_sub_issues},
               %{signal: :ci_fix_dispatch, from: :any, to: "In Progress"},
               %{signal: :pr_review_target, from: :any, to: :requested},
               %{signal: :landing_done, from: ["Merging"], to: "Done"},
               %{signal: :review_rework, from: :any, to: "In Progress"},
               %{signal: :merge_ready, from: ["Rework", "In Progress"], to: "Merging"},
               %{signal: :idle_park, from: ["In Progress", "Rework"], to: "Backlog"},
               %{signal: :director_move, from: :any, to: :requested},
               %{signal: :sub_issues_done, from: ["Waiting on sub-tickets"], to: "Done"},
               %{signal: :wait_on_merge, from: ["Merging"], to: :waiting_on_sub_issues},
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
               %{signal: :epic_review_enter, from: ["Waiting on sub-tickets"], to: :epic_review_state},
               %{signal: :epic_review_pass, from: ["Epic Review"], to: "Done"},
               %{signal: :epic_review_gaps, from: ["Epic Review"], to: :waiting_on_sub_issues}
             ]

      for %{to: to} <- TransitionGuard.edges(), is_binary(to), do: refute(TransitionGuard.retired_state?(to))
    end

    test "names the retired and the draining states, and refuses both" do
      assert TransitionGuard.retired_states() == ["Auto Review"]
      assert TransitionGuard.draining_states() == ["In Review", "Human Review"]

      for state <- ["Auto Review", " in review ", "HUMAN REVIEW"], do: assert(TransitionGuard.retired_state?(state))
      for state <- ["Code Review", "Plan Review", nil], do: refute(TransitionGuard.retired_state?(state))
    end

    test "the plan revise fires from Plan Review and moves through Rework" do
      assert TransitionGuard.target(:plan_revise, %{settings: designed_settings()}) == "Rework"
      assert TransitionGuard.legal?(:plan_revise, "Plan Review", "Rework")
      refute TransitionGuard.legal?(:plan_revise, "In Review")
    end

    test "legal?/3 reads the table" do
      assert TransitionGuard.legal?(:claim, "Todo", "In Progress")
      refute TransitionGuard.legal?(:claim, "In Progress")
    end

    test "target/2 needs no settings for a literal target" do
      assert TransitionGuard.target(:claim, %{settings: designed_settings()}) == "In Progress"
      assert TransitionGuard.target(:claim, %{}) == "In Progress"
      assert TransitionGuard.target(:claim, %{repo_key: "missing-repo"}) == "In Progress"
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

    test "the reviewer's verdicts are edges out of Code Review" do
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

    test "the QA run's verdicts are edges out of QA" do
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
      # Designed-only, like the entry rows.

      for origin <- ["Code Review", "QA", "Merging", "Rework"] do
        assert TransitionGuard.target(:ci_fix_mechanical, %{target: origin, settings: designed}) == origin
      end
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
      assert TransitionGuard.target(:pr_review_target, %{target: "Done"}) == "Done"
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

      for draining <- ["In Review", "Human Review"] do
        assert {:error, {:retired_state, ^draining}} =
                 TransitionGuard.perform("issue-4", :director_move, %{target: draining}, tracker: FakeTracker)
      end

      refute_received {:moved, "issue-4", _state}
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

    test "refuses an agent's move to the retired Auto Review state" do
      assert {:error, {:retired_state, "Auto Review"}} =
               TransitionGuard.resolve_request(state("Auto Review"), %{settings: memory_settings()})

      assert {:error, {:retired_state, "auto review"}} =
               TransitionGuard.resolve_request(state("auto review"), %{settings: designed_settings()})
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

    test "refuses an agent's move into In Review or Human Review, a plan parent's included" do
      # The push hands the work to Code Review, and a plan parent hands over to Plan Review: both
      # review states only drain, from whichever phase the request comes.
      for {name, from, plan_parent?} <- [{"In Review", "In Progress", false}, {"in review", "Rework", false}, {"Human Review", "In Progress", true}] do
        assert {:error, {:retired_state, ^name}} =
                 TransitionGuard.resolve_request(state(name), %{settings: designed_settings(), from_state: from, plan_parent?: plan_parent?})
      end
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
               TransitionGuard.resolve_request(state("In Progress"), %{settings: designed_settings(), from_state: "In Review"})
    end

    test "the restart signal moves a ticket from any state to In Progress" do
      assert :restart in TransitionGuard.signals()
      assert TransitionGuard.target(:restart, %{settings: designed_settings()}) == "In Progress"

      assert TransitionGuard.legal?(:restart, "Merging", "In Progress")
      refute TransitionGuard.legal?(:restart, "Merging", "Rework")
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
    test "an agent's Backlog request while working is a Blocked hold" do
      state = state("Backlog")

      assert {:hold, :blocked, attrs} =
               TransitionGuard.resolve_request(state, %{settings: designed_settings(), from_state: "In Progress"})

      assert attrs.reason =~ "reported a block"
      assert attrs.clearing_condition =~ "access hold"
      assert attrs.waits_on == %{type: "access", keys: []}
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
