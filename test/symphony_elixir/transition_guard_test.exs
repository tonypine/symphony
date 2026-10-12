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
    settings!(%{"tracker" => %{"kind" => "memory"}, "state_machine" => "designed"} |> Map.merge(extra))
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
        assert is_binary(edge.to) or edge.to in [:requested, :waiting_on_sub_issues, :ci_escalation_state]
      end
    end

    test "every literal target is reachable through target/2" do
      for %{signal: signal, to: to} <- TransitionGuard.edges(), is_binary(to) do
        assert TransitionGuard.target(signal, %{}) == to
      end
    end
  end

  describe "version selection" do
    test "edges/1 returns the legacy table by default and an unknown version falls back to it" do
      assert TransitionGuard.edges() == TransitionGuard.edges("legacy")
      assert TransitionGuard.edges("sideways") == TransitionGuard.edges("legacy")
      assert TransitionGuard.signals("sideways") == TransitionGuard.signals()
    end

    test "the designed table is the legacy table plus the designed flow's own edges" do
      legacy = TransitionGuard.edges("legacy")
      designed = TransitionGuard.edges("designed")

      assert Enum.take(designed, length(legacy)) == legacy

      designed_only = designed -- legacy

      assert Enum.map(designed_only, & &1.signal) == [
               :handoff,
               :code_review_approve,
               :code_review_rework,
               :code_review_escalate
             ]

      assert TransitionGuard.signals("designed") == TransitionGuard.signals() ++ Enum.map(designed_only, & &1.signal)
    end

    test "legal?/4 reads the table for the given version" do
      assert TransitionGuard.legal?(:claim, "Todo", "In Progress", "designed")
      refute TransitionGuard.legal?(:claim, "In Progress", nil, "designed")
    end

    test "target/2 selects the table from ctx.settings' version" do
      designed = settings!(%{"tracker" => %{"kind" => "memory"}, "state_machine" => "designed"})

      assert TransitionGuard.target(:claim, %{settings: designed}) == "In Progress"
      assert TransitionGuard.target(:claim, %{}) == "In Progress"
    end

    test "target/2 resolves the version from ctx.repo_key when no settings are given" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [
          [key: "designed-repo", workflow: Workflow.workflow_file_path(), team: "Test", state_machine: "designed"]
        ]
      )

      # The repo's version is resolved from its key rather than falling back to the default.
      assert TransitionGuard.target(:claim, %{repo_key: "designed-repo"}) == "In Progress"
      # An unknown repo key falls back to the default version.
      assert TransitionGuard.target(:claim, %{repo_key: "missing-repo"}) == "In Progress"
    end
  end

  describe "the designed flow's edges" do
    test "the handoff moves In Progress or Rework to the configured Code Review state" do
      designed = designed_settings()

      assert TransitionGuard.legal?(:handoff, "In Progress", nil, "designed")
      assert TransitionGuard.legal?(:handoff, "Rework", nil, "designed")
      refute TransitionGuard.legal?(:handoff, "Todo", nil, "designed")
      # The edge is designed-only: a legacy repo cannot fire it.
      refute TransitionGuard.legal?(:handoff, "In Progress", nil, "legacy")
      refute TransitionGuard.legal?(:handoff, "In Progress")

      assert TransitionGuard.target(:handoff, %{settings: designed}) == "Code Review"
    end

    test "the handoff target is the repo's configured Code Review state" do
      settings =
        settings!(%{
          "tracker" => %{"kind" => "memory", "code_review_state" => "Peer Review"},
          "state_machine" => "designed"
        })

      assert TransitionGuard.target(:handoff, %{settings: settings}) == "Peer Review"
    end

    test "the reviewer's verdicts are designed edges out of Code Review" do
      assert TransitionGuard.legal?(:code_review_approve, "Code Review", nil, "designed")
      assert TransitionGuard.legal?(:code_review_rework, "Code Review", nil, "designed")
      assert TransitionGuard.legal?(:code_review_escalate, "Code Review", nil, "designed")
      refute TransitionGuard.legal?(:code_review_approve, "In Progress", nil, "designed")

      assert TransitionGuard.target(:code_review_approve, %{settings: designed_settings(), target: "Merging"}) == "Merging"
      assert TransitionGuard.target(:code_review_rework, %{settings: designed_settings()}) == "Rework"
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
      assert TransitionGuard.target(:auto_review_verdict, %{target: "Done"}) == "Done"
    end

    test "resolves the waiting state from settings, and nil when it is turned off" do
      assert TransitionGuard.target(:plan_approve, %{settings: memory_settings()}) == "Waiting on sub-tickets"

      assert TransitionGuard.target(:wait_on_merge, %{settings: memory_settings(%{"waiting_on_sub_issues_state" => nil})}) ==
               nil
    end

    test "resolves the CI escalation state, defaulting to In Review" do
      assert TransitionGuard.target(:ci_escalate, %{settings: memory_settings()}) == "In Review"

      settings = settings!(%{"tracker" => %{"kind" => "memory"}, "ci" => %{"escalation_state" => "Blocked"}})
      assert TransitionGuard.target(:ci_escalate, %{settings: settings}) == "Blocked"
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

    test "returns the tracker's error" do
      Process.put(:transition_guard_tracker_result, {:error, :rate_limited})

      assert {:error, :rate_limited} =
               TransitionGuard.perform("issue-2", :director_move, %{target: "Todo"}, tracker: FakeTracker)

      assert_received {:moved, "issue-2", "Todo"}
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

    test "refuses an agent's move to In Review while Auto Review is on" do
      settings = settings!(%{"tracker" => %{"kind" => "memory"}, "auto_review" => %{"enabled" => true, "state" => "QA"}})

      assert {:error, {:in_review_set_by_auto_review, "In Review", "QA"}} =
               TransitionGuard.resolve_request(state("In Review"), %{settings: settings})
    end

    test "refuses an agent's move to the human review state while Auto Review is on" do
      settings =
        settings!(%{
          "tracker" => %{"kind" => "memory", "human_review_state" => "Human Review"},
          "auto_review" => %{"enabled" => true, "state" => "Auto Review"}
        })

      assert {:error, {:in_review_set_by_auto_review, "Human Review", "Auto Review"}} =
               TransitionGuard.resolve_request(state("Human Review"), %{settings: settings})
    end

    test "allows the handoff states for a PR-less ticket even with Auto Review on" do
      settings = settings!(%{"tracker" => %{"kind" => "memory"}, "auto_review" => %{"enabled" => true, "state" => "QA"}})
      state = state("In Review")

      assert {:ok, ^state} =
               TransitionGuard.resolve_request(state, %{settings: settings, pr_less?: true})
    end

    test "redirects a needs-person ticket to the human review state" do
      settings = settings!(%{"tracker" => %{"kind" => "memory", "human_review_state" => "Human Review"}})
      human = state("Human Review", "human-id")

      assert {:ok, ^human} =
               TransitionGuard.resolve_request(state("In Review"), %{
                 settings: settings,
                 states: [state("In Review"), human],
                 needs_person?: true
               })
    end

    test "keeps the requested state when it needs a person but human review is off" do
      state = state("In Review")

      assert {:ok, ^state} =
               TransitionGuard.resolve_request(state, %{settings: memory_settings(), needs_person?: true})
    end

    test "keeps the requested state when the human review state is not on the team" do
      settings = settings!(%{"tracker" => %{"kind" => "memory", "human_review_state" => "Human Review"}})
      state = state("In Review")

      assert {:ok, ^state} =
               TransitionGuard.resolve_request(state, %{
                 settings: settings,
                 states: [state("In Review")],
                 needs_person?: true
               })
    end

    test "refuses an agent's move to the waiting state" do
      assert {:error, {:waiting_on_sub_issues_state_requires_human_approval, "Waiting on sub-tickets"}} =
               TransitionGuard.resolve_request(state("Waiting on sub-tickets"), %{settings: memory_settings()})
    end

    test "refuses an agent's hand move into Code Review on a designed repo" do
      assert {:error, {:code_review_requires_handoff_signal, "Code Review"}} =
               TransitionGuard.resolve_request(state("Code Review"), %{settings: designed_settings()})
    end

    test "passes the Code Review state through on a legacy repo" do
      state = state("Code Review")

      assert {:ok, ^state} = TransitionGuard.resolve_request(state, %{settings: memory_settings()})
    end

    test "allows the waiting state when it is turned off in config" do
      state = state("Waiting on sub-tickets")
      settings = memory_settings(%{"waiting_on_sub_issues_state" => nil})

      assert {:ok, ^state} = TransitionGuard.resolve_request(state, %{settings: settings})
    end
  end
end
