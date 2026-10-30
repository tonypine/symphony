defmodule SymphonyElixir.TicketStateReconcilerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{RunStore, TicketState, TicketStateReconciler}

  @repo_key "repo-a"
  @at ~U[2026-01-02 03:04:05Z]

  setup do
    :ok = RunStore.clear()
  end

  describe "reconcile/3" do
    test "agrees when the stored phase is the Linear state" do
      record = TicketState.new(@repo_key, "issue-1", %{phase: "In Progress"})
      assert {:ok, ^record} = TicketStateReconciler.reconcile(record, "In Progress", @at)
    end

    test "stamps the phase on a record that had none" do
      record = TicketState.new(@repo_key, "issue-1")

      assert {:stamped, reconciled} = TicketStateReconciler.reconcile(record, "Todo", @at)
      assert reconciled.phase == "Todo"
      assert reconciled.updated_at == @at
      assert reconciled.phase_owner == :external
    end

    test "reports drift when the board state differs" do
      record = TicketState.new(@repo_key, "issue-1", %{phase: "In Progress"})

      assert {:drift, reconciled, %{from: "In Progress", to: "Done"}} =
               TicketStateReconciler.reconcile(record, "Done", @at)

      assert reconciled.phase == "Done"
      assert reconciled.phase_owner == :external
    end

    test "under the record source keeps a phase Symphony owns, and adopts one Linear owns" do
      owned = TicketState.put_phase(TicketState.new(@repo_key, "issue-1"), "Code Review", @at)

      assert {:kept, ^owned, %{record_phase: "Code Review", linear_phase: "Done"}} =
               TicketStateReconciler.reconcile(owned, "Done", @at, "record")

      assert {:drift, %{phase: "Done", phase_owner: :external}, _drift} =
               TicketStateReconciler.reconcile(owned, "Done", @at, "poll")

      external = TicketState.new(@repo_key, "issue-1", %{phase: "Todo"})

      assert {:drift, %{phase: "Backlog", phase_owner: :external}, _drift} =
               TicketStateReconciler.reconcile(external, "Backlog", @at, "record")
    end

    test "leaves the record untouched when Linear returns no state" do
      record = TicketState.new(@repo_key, "issue-1", %{phase: "In Progress"})
      assert {:ok, ^record} = TicketStateReconciler.reconcile(record, nil, @at)
    end

    test "normalizes a non-map record" do
      assert {:stamped, reconciled} = TicketStateReconciler.reconcile(:junk, "Todo", @at)
      assert reconciled.phase == "Todo"
    end

    test "defaults the timestamp to now" do
      record = TicketState.new(@repo_key, "issue-1")
      assert {:stamped, reconciled} = TicketStateReconciler.reconcile(record, "Todo")
      assert %DateTime{} = reconciled.updated_at
    end
  end

  describe "reconcile_all/1" do
    test "does nothing when the store is empty" do
      assert TicketStateReconciler.reconcile_all(fetcher: fn _ids -> {:ok, []} end) ==
               %{checked: 0, drifted: 0, missing: 0}
    end

    test "counts records Linear still returns and leaves their phase alone" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1", %{phase: "In Progress"}))
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-2", %{phase: "Todo"}))

      fetcher = fn ids ->
        assert Enum.sort(ids) == ["issue-1", "issue-2"]

        {:ok, [%{id: "issue-1", state: "In Progress"}, %{id: "issue-2", state: "Todo"}]}
      end

      assert TicketStateReconciler.reconcile_all(fetcher: fetcher) == %{checked: 2, drifted: 0, missing: 0}
      assert %{phase: "In Progress"} = RunStore.get_ticket_state(@repo_key, "issue-1")
    end

    test "adopts the board state and persists it when the record has drifted" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1", %{phase: "In Progress"}))

      fetcher = fn _ids -> {:ok, [%{id: "issue-1", state: "Done"}]} end

      log =
        capture_log(fn ->
          assert TicketStateReconciler.reconcile_all(fetcher: fetcher) == %{checked: 1, drifted: 1, missing: 0}
        end)

      assert log =~ "Ticket state drift reconciled issue_id=issue-1"
      assert log =~ "checked=1 drifted=1 missing=0"
      assert %{phase: "Done"} = RunStore.get_ticket_state(@repo_key, "issue-1")
    end

    test "an adopted phase is stored as Linear's, with when it was adopted" do
      :ok = RunStore.put_ticket_state(TicketState.put_phase(TicketState.new(@repo_key, "issue-1"), "Code Review", @at))
      now = DateTime.add(@at, 60)

      fetcher = fn _ids -> {:ok, [%{id: "issue-1", state: "Done"}]} end

      assert TicketStateReconciler.reconcile_all(fetcher: fetcher, now: now, dispatch_source: "poll") ==
               %{checked: 1, drifted: 1, missing: 0}

      assert %{phase: "Done", phase_owner: :external, phase_at: ^now} = RunStore.get_ticket_state(@repo_key, "issue-1")
    end

    test "under the record source keeps a phase Symphony owns and moves the ticket back in Linear, with the drift recorded" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      :ok = RunStore.put_ticket_state(TicketState.put_phase(TicketState.new(@repo_key, "issue-1"), "Code Review", @at))

      # Moved to Done by hand while Symphony was down.
      moved = %Issue{id: "issue-1", identifier: "ACME-1", state: "Done", updated_at: DateTime.add(@at, 60)}

      log =
        capture_log(fn ->
          assert TicketStateReconciler.reconcile_all(fetcher: fn _ids -> {:ok, [moved]} end, dispatch_source: "record") ==
                   %{checked: 1, drifted: 0, missing: 0}
        end)

      assert log =~ "Ticket state kept: Symphony owns the phase issue_id=issue-1"
      assert log =~ ~s(record_phase="Code Review" linear_phase="Done")
      assert_received {:memory_tracker_state_update, "issue-1", "Code Review"}
      assert %{phase: "Code Review", phase_owner: :symphony, phase_at: @at} = RunStore.get_ticket_state(@repo_key, "issue-1")

      phases = %{record_phase: "Code Review", linear_phase: "Done"}
      assert ticket_events(@repo_key, "issue-1") == [{"drift.detected", phases}, {"drift.reverted", phases}]
    end

    test "under the record source a read that is no Linear issue keeps the phase and moves nothing" do
      :ok = RunStore.put_ticket_state(TicketState.put_phase(TicketState.new(@repo_key, "issue-1"), "Code Review", @at))

      fetcher = fn _ids -> {:ok, [%{id: "issue-1", state: "Done"}]} end

      capture_log(fn ->
        assert TicketStateReconciler.reconcile_all(fetcher: fetcher, dispatch_source: "record") ==
                 %{checked: 1, drifted: 0, missing: 0}
      end)

      assert %{phase: "Code Review", phase_owner: :symphony} = RunStore.get_ticket_state(@repo_key, "issue-1")
      assert ticket_events(@repo_key, "issue-1") == []
    end

    test "reads the Linear state from string-keyed issues and skips those without an id" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1", %{phase: "Todo"}))

      fetcher = fn _ids -> {:ok, [%{"id" => "issue-1", "state" => "Todo"}, %{state: "Todo"}, :junk]} end

      assert TicketStateReconciler.reconcile_all(fetcher: fetcher) == %{checked: 1, drifted: 0, missing: 0}
    end

    test "counts a record Linear no longer returns as missing" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-gone", %{phase: "Todo"}))

      assert TicketStateReconciler.reconcile_all(fetcher: fn _ids -> {:ok, []} end) ==
               %{checked: 0, drifted: 0, missing: 1}
    end

    test "keeps the stored phase when Linear returns the ticket without a state" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1", %{phase: "In Progress"}))

      fetcher = fn _ids -> {:ok, [%{id: "issue-1", state: nil}]} end

      assert TicketStateReconciler.reconcile_all(fetcher: fetcher) == %{checked: 1, drifted: 0, missing: 0}
      assert %{phase: "In Progress"} = RunStore.get_ticket_state(@repo_key, "issue-1")
    end

    test "stamps the phase on a record that had none" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1"))

      assert TicketStateReconciler.reconcile_all(fetcher: fn _ids -> {:ok, [%{id: "issue-1", state: "Todo"}]} end, now: @at) ==
               %{checked: 1, drifted: 0, missing: 0}

      assert %{phase: "Todo", updated_at: @at} = RunStore.get_ticket_state(@repo_key, "issue-1")
    end

    test "logs and leaves records alone when the Linear fetch fails" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1", %{phase: "Todo"}))

      log =
        capture_log(fn ->
          assert TicketStateReconciler.reconcile_all(fetcher: fn _ids -> {:error, :boom} end) ==
                   %{checked: 0, drifted: 0, missing: 0}
        end)

      assert log =~ "failed to read Linear states"
      assert %{phase: "Todo"} = RunStore.get_ticket_state(@repo_key, "issue-1")
    end

    test "logs and leaves records alone when the fetcher raises" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1", %{phase: "Todo"}))

      log =
        capture_log(fn ->
          assert TicketStateReconciler.reconcile_all(fetcher: fn _ids -> raise "nope" end) ==
                   %{checked: 0, drifted: 0, missing: 0}
        end)

      assert log =~ "failed to read Linear states"
    end

    test "logs and skips when the store cannot be read" do
      log =
        capture_log(fn ->
          opts = [
            store: SymphonyElixir.TicketStateReconcilerTest.ReadFailingStore,
            fetcher: fn _ids -> {:ok, []} end
          ]

          assert TicketStateReconciler.reconcile_all(opts) ==
                   %{checked: 0, drifted: 0, missing: 0}
        end)

      assert log =~ "Ticket state reconciliation skipped: failed to read the store"
    end

    test "logs a drift it could not persist" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1", %{phase: "In Progress"}))

      log =
        capture_log(fn ->
          assert TicketStateReconciler.reconcile_all(
                   store: SymphonyElixir.TicketStateReconcilerTest.WriteFailingStore,
                   fetcher: fn _ids -> {:ok, [%{id: "issue-1", state: "Done"}]} end
                 ) == %{checked: 1, drifted: 1, missing: 0}
        end)

      assert log =~ "Failed to record ticket state drift for issue-1"
      assert %{phase: "In Progress"} = RunStore.get_ticket_state(@repo_key, "issue-1")
    end

    test "logs a stamped phase it could not persist" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1"))

      log =
        capture_log(fn ->
          assert TicketStateReconciler.reconcile_all(
                   store: SymphonyElixir.TicketStateReconcilerTest.WriteFailingStore,
                   fetcher: fn _ids -> {:ok, [%{id: "issue-1", state: "Todo"}]} end
                 ) == %{checked: 1, drifted: 0, missing: 0}
        end)

      assert log =~ "Failed to record ticket state phase for issue-1"
    end
  end
end

defmodule SymphonyElixir.TicketStateReconcilerTest.ReadFailingStore do
  @moduledoc false
  def list_all_ticket_states, do: {:error, :store_down}
end

defmodule SymphonyElixir.TicketStateReconcilerTest.WriteFailingStore do
  @moduledoc false
  def list_all_ticket_states, do: SymphonyElixir.RunStore.list_all_ticket_states()
  def update_ticket_state(_repo_key, _issue_id, _attrs), do: {:error, :store_down}
end
