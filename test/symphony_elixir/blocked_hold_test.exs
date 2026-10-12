defmodule SymphonyElixir.BlockedHoldTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{BlockedHold, Hold, RunStore, Workflow}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-a"
  @issue_id "issue-1"
  @terminal ["Done", "Canceled"]

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

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    :ok = RunStore.clear()
    :ok
  end

  defp designed_settings do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}, "state_machine" => "designed"})
    settings
  end

  defp legacy_settings do
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
    end

    test "does nothing when the blockers have not changed" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})
      :set = BlockedHold.sync(open_issue, @terminal, settings: designed_settings())

      assert BlockedHold.sync(open_issue, @terminal, settings: designed_settings()) == :none
    end

    test "leaves a legacy repo untouched" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      assert BlockedHold.sync(open_issue, @terminal, settings: legacy_settings()) == :skipped
      assert stored_hold() == nil
      assert labels() == []
    end

    test "resolves the repo's settings from its key when the caller passes none" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [[key: @repo_key, workflow: Workflow.workflow_file_path(), team: "Test", state_machine: "designed"]]
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

    test "reports and clears a hand-added Blocked label with no store hold" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue(%{labels: ["Blocked"]})])
      stray = issue(%{labels: ["Blocked"]})

      log = capture_log(fn -> assert BlockedHold.sync(stray, @terminal, settings: designed_settings()) == :none end)

      assert log =~ "with no store hold"
      assert labels() == []
      assert stored_hold() == nil
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

  describe "sweep/3" do
    test "counts the holds it set and cleared over a repo's issues" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})
      other = %{open_issue | id: "issue-2", blocked_by: []}

      assert BlockedHold.sweep([open_issue, other], @terminal, settings: designed_settings()) == 1

      unblocked = %{open_issue | blocked_by: [blocker("TP-1", "Done")]}
      assert BlockedHold.sweep([unblocked, other], @terminal, settings: designed_settings()) == 1
    end

    test "counts nothing on a legacy repo or without a list" do
      open_issue = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      assert BlockedHold.sweep([open_issue], @terminal, settings: legacy_settings()) == 0
      assert BlockedHold.sweep(:not_a_list, @terminal, settings: designed_settings()) == 0
      # Without the caller's settings the repo is resolved from the issue's key.
      assert BlockedHold.sweep([open_issue], @terminal) == 0
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
