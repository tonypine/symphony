defmodule SymphonyElixir.HoldTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Hold, RunStore, TicketState, Workflow}
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-a"
  @issue_id "issue-1"

  defmodule FailingStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :boom}
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :boom}
  end

  defmodule FailingTracker do
    def set_machine_label(_issue_id, _name), do: {:error, :boom}
    def clear_machine_label(_issue_id, _name), do: {:error, :boom}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    :ok = RunStore.clear()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_add_issue_label_result)
      Application.delete_env(:symphony_elixir, :memory_tracker_remove_issue_label_result)
    end)

    :ok
  end

  describe "kinds and labels" do
    test "labels the two holds and matches them back ignoring case and space" do
      assert Hold.kinds() == [:blocked, :needs_decision]
      assert Hold.label(:blocked) == "Blocked"
      assert Hold.label(:needs_decision) == "Needs Decision"
      assert Hold.label(:other) == nil

      assert Hold.kind_for_label("blocked") == :blocked
      assert Hold.kind_for_label(" NEEDS DECISION ") == :needs_decision
      assert Hold.kind_for_label("bug") == nil
      assert Hold.kind_for_label(nil) == nil
    end
  end

  describe "access_wait?/1" do
    test "is true only for a hold waiting on an access grant" do
      assert Hold.access_wait?(%{waits_on: %{type: "access", keys: []}})
      refute Hold.access_wait?(%{waits_on: %{type: "dependency", keys: ["TP-1"]}})
      refute Hold.access_wait?(%{reason: "no waits_on"})
      refute Hold.access_wait?(nil)
    end
  end

  describe "set/5 and clear/4" do
    test "set writes the store first, then projects the label" do
      assert :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting on TP-1"})

      assert [%{kind: :blocked, reason: "waiting on TP-1"}] =
               RunStore.get_ticket_state(@repo_key, @issue_id) |> Map.fetch!(:holds)

      assert Hold.held?(@repo_key, @issue_id, :blocked)
      assert %{reason: "waiting on TP-1"} = Hold.get(@repo_key, @issue_id, :blocked)
      assert labels() == ["Blocked"]
    end

    test "clear drops the store hold and the label, leaving the ticket in place" do
      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting"})

      assert :ok = Hold.clear(@repo_key, @issue_id, :blocked)
      refute Hold.held?(@repo_key, @issue_id, :blocked)
      assert labels() == []
    end

    test "refuses a write with no repo key, touching neither the store nor the label" do
      log =
        capture_log(fn ->
          assert Hold.set(nil, @issue_id, :blocked) == {:error, :missing_repo_key}
          assert Hold.clear("", @issue_id, :needs_decision) == {:error, :missing_repo_key}
        end)

      assert log =~ "Refused a hold write on issue_id=#{@issue_id} with no repo key"
      assert labels() == []
    end

    test "refuses a kind it does not know" do
      assert Hold.set(@repo_key, @issue_id, :unknown, %{reason: "x"}) == {:error, {:unknown_hold_kind, :unknown}}
      assert Hold.clear(@repo_key, @issue_id, :unknown) == {:error, {:unknown_hold_kind, :unknown}}
      assert labels() == []
    end

    test "a failed store write fails the set and touches no label" do
      assert Hold.set(@repo_key, @issue_id, :blocked, %{}, store: FailingStore) == {:error, :boom}
      assert Hold.clear(@repo_key, @issue_id, :blocked, store: FailingStore) == {:error, :boom}
      assert labels() == []
    end

    test "a failed label write keeps the hold and is reported" do
      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, {:error, :boom})

      log =
        capture_log(fn ->
          assert :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting"})
        end)

      assert log =~ "Failed to set the machine label"
      assert Hold.held?(@repo_key, @issue_id, :blocked)
      assert labels() == []
    end

    test "a failed label clear keeps the store clear and is reported" do
      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting"})
      Application.put_env(:symphony_elixir, :memory_tracker_remove_issue_label_result, {:error, :boom})

      log = capture_log(fn -> assert :ok = Hold.clear(@repo_key, @issue_id, :blocked) end)

      assert log =~ "Failed to clear the machine label"
      refute Hold.held?(@repo_key, @issue_id, :blocked)
    end
  end

  describe "get/4 and held?/4" do
    test "read nothing without a repo key or an issue id, and say so for a ticket read with no repo key" do
      log =
        capture_log(fn ->
          refute Hold.held?(nil, @issue_id, :blocked)
          assert Hold.get("", @issue_id, :blocked) == nil
        end)

      assert log =~ "Read the holds of issue_id=#{@issue_id} with no repo key"
      refute Hold.held?(@repo_key, nil, :blocked)
      refute Hold.held?(@repo_key, 42, :blocked)
    end

    test "a store read error is reported and treated as no hold" do
      log = capture_log(fn -> refute Hold.held?(@repo_key, @issue_id, :blocked, store: FailingStore) end)
      assert log =~ "Failed to read the ticket state"
    end
  end

  describe "reproject/4" do
    test "re-asserts a store hold's label without touching the store" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, %{reason: "waiting"})
      assert labels() == []

      assert :ok = Hold.reproject(@repo_key, @issue_id, :blocked)
      assert labels() == ["Blocked"]
      assert %{reason: "waiting"} = Hold.get(@repo_key, @issue_id, :blocked)
    end

    test "reports a hold the store does not have and refuses an unknown kind" do
      assert Hold.reproject(@repo_key, @issue_id, :blocked) == {:error, {:no_hold, :blocked}}
      assert Hold.reproject(@repo_key, @issue_id, :unknown) == {:error, {:unknown_hold_kind, :unknown}}
      assert labels() == []
    end

    test "a failed label write is reported and leaves the store hold in place" do
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :blocked, %{reason: "waiting"})
      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, {:error, :boom})

      log = capture_log(fn -> assert :ok = Hold.reproject(@repo_key, @issue_id, :blocked) end)

      assert log =~ "Failed to set the machine label"
      assert Hold.held?(@repo_key, @issue_id, :blocked)
      assert labels() == []
    end
  end

  describe "drift/2" do
    test "is ok when the store and the board agree" do
      held = TicketState.set_hold(TicketState.new(@repo_key, @issue_id), :blocked, %{reason: "waiting"})

      assert Hold.drift(held, ["Blocked", "bug"]) == :ok
      assert Hold.drift(TicketState.new(@repo_key, @issue_id), ["bug"]) == :ok
      assert Hold.drift(TicketState.new(@repo_key, @issue_id), nil) == :ok
      # A label that is not a string is not a hold label.
      assert Hold.drift(TicketState.new(@repo_key, @issue_id), [nil, 5]) == :ok
    end

    test "reports a board label with no store hold as a hand-added label" do
      assert Hold.drift(TicketState.new(@repo_key, @issue_id), ["blocked"]) == {:stray_label, :blocked}
    end

    test "reports a store hold the board is missing" do
      held = TicketState.set_hold(TicketState.new(@repo_key, @issue_id), :needs_decision, %{reason: "pick"})

      assert Hold.drift(held, []) == {:missing_label, :needs_decision}
      assert Hold.drift(held, nil) == {:missing_label, :needs_decision}
    end
  end

  describe "report_drift/4" do
    test "reports a stray label and a missing label, and is quiet when they agree" do
      log =
        capture_log(fn ->
          assert Hold.report_drift(@repo_key, @issue_id, ["Blocked"]) == {:stray_label, :blocked}
        end)

      assert log =~ "with no store hold"

      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "waiting"})

      log = capture_log(fn -> assert Hold.report_drift(@repo_key, @issue_id, []) == {:missing_label, :blocked} end)
      assert log =~ "is missing its machine label"

      assert Hold.report_drift(@repo_key, @issue_id, ["Blocked"]) == :ok
    end
  end

  defp issue do
    %Issue{id: @issue_id, identifier: "TP-817", title: "T", state: "Todo", labels: []}
  end

  defp labels do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == @issue_id))
    |> Map.fetch!(:labels)
  end
end
