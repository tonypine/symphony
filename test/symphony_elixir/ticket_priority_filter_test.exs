defmodule SymphonyElixir.TicketPriorityFilterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  setup do
    # Every test but the ones that set a filter runs with it off.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_terminal_states: ["Done", "Canceled", "Duplicate"]
    )

    :ok
  end

  defp filter(priorities) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_terminal_states: ["Done", "Canceled", "Duplicate"],
      tickets: %{priorities: priorities}
    )
  end

  describe "the config key" do
    test "an absent or empty list turns the filter off" do
      assert Config.ticket_priority_filter() == nil

      filter([])
      assert Config.ticket_priority_filter() == nil
    end

    test "names, aliases and Linear's numbers all narrow the filter" do
      filter(["urgent", "high"])
      assert Config.ticket_priority_filter() == MapSet.new([1, 2])

      filter([1, 2])
      assert Config.ticket_priority_filter() == MapSet.new([1, 2])

      filter(["No Priority", "MEDIUM", "low"])
      assert Config.ticket_priority_filter() == MapSet.new([0, 3, 4])
    end

    test "a name the config does not know is rejected" do
      filter(["urgent", "whenever"])

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "tickets.priorities"
      assert message =~ "whenever"
    end

    test "an empty list is not the same as nil" do
      filter(nil)
      assert Config.ticket_priority_filter() == nil
    end
  end

  describe "dispatch" do
    test "a ticket outside the allowed priorities is not dispatched, so lanes stay open" do
      filter(["urgent", "high"])
      state = orchestrator_state()

      assert Orchestrator.should_dispatch_issue_for_test(issue("high", 2), state)
      assert Orchestrator.should_dispatch_issue_for_test(issue("urgent", 1), state)
      refute Orchestrator.should_dispatch_issue_for_test(issue("medium", 3), state)
      refute Orchestrator.should_dispatch_issue_for_test(issue("low", 4), state)
      refute Orchestrator.should_dispatch_issue_for_test(issue("none", 0), state)
      # An issue Linear reports with no priority reads as no priority.
      refute Orchestrator.should_dispatch_issue_for_test(issue("unset", nil), state)
    end

    test "the filter does not gate a forced ticket" do
      filter(["urgent"])
      forced = %{issue("forced", 4) | labels: ["expedite"]}

      assert Orchestrator.should_dispatch_issue_for_test(forced, orchestrator_state())
    end

    test "the filter does not gate a retry waiting for a slot" do
      filter(["urgent"])
      low = issue("low", 4)

      waiting = %{orchestrator_state() | slot_waiting: %{low.id => %{attempt: 1}}}
      assert Orchestrator.should_dispatch_issue_for_test(low, waiting)
    end

    test "with the filter off, every priority is dispatched" do
      state = orchestrator_state()

      for {priority, _label} <- [{0, "none"}, {1, "urgent"}, {2, "high"}, {3, "medium"}, {4, "low"}, {nil, "unset"}] do
        assert Orchestrator.should_dispatch_issue_for_test(issue("any", priority), state)
      end
    end

    test "an empty priorities list names no settings and dispatches everything" do
      filter([])
      assert Orchestrator.should_dispatch_issue_for_test(issue("low", 4), orchestrator_state())
    end
  end

  describe "the schema" do
    test "priority names round-trip through their Linear numbers" do
      for name <- Schema.Tickets.priority_names() do
        assert is_integer(Schema.Tickets.priority_number(name))
      end
    end
  end

  defp issue(identifier, priority) do
    %Issue{
      id: "issue-" <> identifier,
      identifier: "MT-" <> String.upcase(identifier),
      title: "Ticket #{identifier}",
      state: "Todo",
      priority: priority,
      team: %{key: "Test"},
      labels: [],
      assigned_to_worker: true,
      url: "https://example.org/issues/#{identifier}"
    }
  end

  defp orchestrator_state do
    %Orchestrator.State{
      repo_key: "default",
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      slot_waiting: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
