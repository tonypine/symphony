defmodule SymphonyElixir.BlockedHoldDispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Hold, RunStore, Workflow}
  alias SymphonyElixir.Linear.Issue

  @repo_key "designed"
  @issue_id "issue-1"
  @terminal ["Done", "Canceled"]
  @active_states ["Todo", "In Progress", "In Review", "Merging", "Rework"]

  setup do
    designed_workflow()

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    :ok = RunStore.clear()
    :ok
  end

  describe "the poll sweep and the dispatch gate" do
    test "a designed repo's blocked Todo ticket is paused until its blocker is terminal" do
      open = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      assert Orchestrator.sweep_blocked_holds_for_test(@repo_key, [open], @terminal) == 1
      assert Hold.held?(@repo_key, @issue_id, :blocked)
      assert labels() == ["Blocked"]

      refute Orchestrator.should_dispatch_issue_for_test(open, orchestrator_state())

      unblocked = %{open | blocked_by: [blocker("TP-1", "Done")]}

      assert Orchestrator.sweep_blocked_holds_for_test(@repo_key, [unblocked], @terminal) == 1
      refute Hold.held?(@repo_key, @issue_id, :blocked)
      assert labels() == []
      assert Orchestrator.should_dispatch_issue_for_test(unblocked, orchestrator_state())
    end

    test "a store hold pauses dispatch on its own, with no open blocker on the board" do
      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "an agent reported a block"})
      issue = issue()

      refute Issue.blocked?(issue, @terminal)
      refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())

      # The sweep only clears a hold a dependency lifts; this one waits on its own signal and stays.
      assert Orchestrator.sweep_blocked_holds_for_test(@repo_key, [issue], @terminal) == 0
      refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
    end

    test "a legacy repo is untouched by the sweep and dispatches as before" do
      legacy_workflow()

      open = issue(%{blocked_by: [blocker("TP-1", "Done")]})

      assert Orchestrator.sweep_blocked_holds_for_test(@repo_key, [open], @terminal) == 0
      assert Orchestrator.should_dispatch_issue_for_test(open, orchestrator_state())
    end
  end

  defp designed_workflow do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: @active_states,
      tracker_terminal_states: @terminal,
      repos: [[key: @repo_key, workflow: Workflow.workflow_file_path(), team: "Test"]]
    )
  end

  defp legacy_workflow do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: @active_states,
      tracker_terminal_states: @terminal,
      repos: [[key: @repo_key, workflow: Workflow.workflow_file_path(), team: "Test"]]
    )
  end

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{id: @issue_id, identifier: "TP-817", title: "T", state: "Todo", repo_key: @repo_key, labels: []},
      attrs
    )
  end

  defp blocker(identifier, state), do: %{id: "blocker-" <> identifier, identifier: identifier, state: state}

  defp labels do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == @issue_id))
    |> Map.fetch!(:labels)
  end

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
