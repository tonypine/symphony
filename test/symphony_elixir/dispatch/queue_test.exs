defmodule SymphonyElixir.Dispatch.QueueTest do
  # The dispatch queue: each open ticket's place is stored on its record, a new ticket joins at the
  # end, a change of priority moves no ticket, the places survive a restart, and the first start of
  # the release that stored the queue places the tickets already there in the order the pass
  # computed before.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.Queue
  alias SymphonyElixir.{TicketObservation, TicketState}

  @repo "repo-queue"
  @other_repo "repo-queue-b"

  setup do
    :ok = RunStore.clear()
    # A cleared store has no placement marker: the start that placed it is the one before the clear.
    :ok = RunStore.place_queue()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  describe "order/2" do
    test "by place, then the tickets with none by age and identifier, then anything that is not an issue" do
      placed_second = issue("b", "MT-1", created_at: ~U[2025-01-01 00:00:00Z], priority: 1)
      placed_first = issue("a", "MT-9", created_at: ~U[2026-06-01 00:00:00Z], priority: 4)
      unplaced_old = issue("c", "MT-7", created_at: ~U[2025-02-01 00:00:00Z])
      unplaced_new = issue("d", "MT-2", created_at: ~U[2026-02-01 00:00:00Z])
      unplaced_ageless = issue("e", "MT-3")
      positions = %{"a" => 4, "b" => 10}

      issues = [:not_an_issue, unplaced_ageless, unplaced_new, placed_second, unplaced_old, placed_first]

      assert issues |> Queue.order(positions) |> Enum.map(&id/1) == ["a", "b", "c", "d", "e", :not_an_issue]
      # A store that could not be read gives no places.
      assert issues |> Queue.order({:error, :aborted}) |> Enum.map(&id/1) == ["b", "c", "d", "a", "e", :not_an_issue]
    end
  end

  describe "placement/2" do
    test "started tickets first, each group by stage, priority, age and identifier" do
      records = [
        record("todo-low", "Todo", 4, ~U[2025-01-01 00:00:00Z]),
        record("todo-urgent", "Todo", 1, ~U[2026-01-01 00:00:00Z]),
        record("backlog-urgent-older", "Backlog", 1, ~U[2025-06-01 00:00:00Z]),
        record("todo-ran", "Todo", 4, nil),
        record("progress", "In Progress", 2, nil),
        record("rework", "Rework", 3, nil),
        record("merging", "Merging", 4, nil),
        record("unknown", nil, nil, nil)
      ]

      assert records |> Queue.placement(MapSet.new(["todo-ran"])) |> Enum.map(& &1.issue_id) ==
               ["merging", "rework", "progress", "unknown", "todo-ran", "backlog-urgent-older", "todo-urgent", "todo-low"]
    end
  end

  describe "the stored queue" do
    test "every open ticket holds its place, a new ticket joins at the end, and the places survive a restart" do
      put!(@repo, "a", "MT-A", "Todo")
      put!(@other_repo, "b", "MT-B", "In Progress")
      put!(@repo, "done", "MT-D", "Done")
      put!(@repo, "c", "MT-C", "Backlog")

      assert places() == %{"a" => 1, "b" => 2, "c" => 3}
      assert %{queue_position: nil} = RunStore.get_ticket_state("done")

      # A write of the record without a place keeps the stored one.
      :ok = RunStore.put_ticket_state(TicketState.new(@repo, "a", %{issue_identifier: "MT-A", phase: "In Progress"}))
      assert places() == %{"a" => 1, "b" => 2, "c" => 3}

      restart_run_store()
      assert places() == %{"a" => 1, "b" => 2, "c" => 3}

      put!(@repo, "new", "MT-N", "Todo")
      assert places() == %{"a" => 1, "b" => 2, "c" => 3, "new" => 4}
    end

    test "a ticket that reaches a terminal state leaves the queue, and joins at the end when reopened" do
      put!(@repo, "a", "MT-A", "Todo")
      put!(@repo, "b", "MT-B", "Todo")

      :ok = RunStore.update_ticket_state("a", %{phase: "Done"})
      assert places() == %{"b" => 2}

      :ok = RunStore.update_ticket_state("a", %{phase: "Todo"})
      assert places() == %{"a" => 3, "b" => 2}

      :ok = RunStore.update_ticket_state("b", %{removed_at: DateTime.utc_now()})
      assert places() == %{"a" => 3}
    end

    test "a change of priority moves no ticket, and a read's new tickets join oldest first" do
      repo_key = Config.repo_key!()
      now = DateTime.utc_now()

      newer = issue("newer", "MT-1", repo_key: repo_key, created_at: ~U[2026-02-01 00:00:00Z], priority: 1, updated_at: now)
      older = issue("older", "MT-2", repo_key: repo_key, created_at: ~U[2026-01-01 00:00:00Z], priority: 4, updated_at: now)
      assert %{errors: 0} = TicketObservation.observe_all(repo_key, [newer, older], [])
      assert places() == %{"older" => 1, "newer" => 2}

      later = DateTime.add(now, 60, :second)
      assert {:ok, :updated} = TicketObservation.observe(repo_key, %{older | priority: 1, updated_at: later})
      assert {:ok, :updated} = TicketObservation.observe(repo_key, %{newer | priority: 4, updated_at: later})

      assert %{priority: 1, queue_position: 1} = RunStore.get_ticket_state("older")
      assert %{priority: 4, queue_position: 2} = RunStore.get_ticket_state("newer")
    end

    test "the first start places the tickets a store kept without places, started ones in front, and a later start keeps them" do
      put_dispatch(@repo, "todo-ran", kind: :implementation)

      before_the_queue!([
        record("todo-low", "Todo", 4, ~U[2025-01-01 00:00:00Z]),
        record("todo-urgent", "Todo", 1, ~U[2026-01-01 00:00:00Z]),
        record("backlog-urgent", "Backlog", 1, ~U[2026-02-01 00:00:00Z]),
        record("todo-ran", "Todo", 4, ~U[2026-03-01 00:00:00Z]),
        record("progress", "In Progress", 2, nil),
        record("merging", "Merging", 4, nil),
        record("done", "Done", 1, nil)
      ])

      assert places() == %{}

      restart_run_store()

      placed = %{"merging" => 1, "progress" => 2, "todo-ran" => 3, "todo-urgent" => 4, "backlog-urgent" => 5, "todo-low" => 6}
      assert places() == placed
      refute Map.get(RunStore.get_ticket_state("done"), :queue_position)

      # Its marker set, a later start leaves every place as it is, even one changed since.
      :ok = RunStore.update_ticket_state("todo-low", %{priority: 1})
      restart_run_store()
      assert places() == placed

      put!(@repo, "new", "MT-NEW", "Todo")
      assert places()["new"] == 7
    end
  end

  defp places, do: RunStore.queue_positions()

  defp put!(repo_key, issue_id, identifier, phase) do
    :ok = RunStore.put_ticket_state(TicketState.new(repo_key, issue_id, %{issue_identifier: identifier, phase: phase}))
  end

  # The records as a release before the queue kept them: no place, and no placement marker.
  defp before_the_queue!(records) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        for record <- records do
          :mnesia.write({:symphony_run_store_ticket_index, record.issue_id, record.repo_key, Map.delete(record, :queue_position)})
        end

        :mnesia.delete({:symphony_run_store_totals, {:marker, "queue_placed_v1"}})
        :mnesia.delete({:symphony_run_store_totals, :queue_tail})
      end)
  end

  defp record(issue_id, phase, priority, created_at) do
    TicketState.new(@repo, issue_id, %{issue_identifier: String.upcase(issue_id), phase: phase, priority: priority, created_at: created_at})
  end

  defp issue(id, identifier, attrs \\ []) do
    struct!(%Issue{id: id, identifier: identifier, title: "Ticket #{identifier}", state: "Todo", labels: []}, attrs)
  end

  defp id(%Issue{id: id}), do: id
  defp id(other), do: other

  defp restart_run_store do
    case Supervisor.terminate_child(SymphonyElixir.Supervisor, RunStore) do
      :ok ->
        {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, RunStore)
        :ok

      # Without the orchestrator runtime nothing supervises it: `RunStore.ensure_started/0` starts it.
      {:error, :not_found} ->
        if pid = Process.whereis(RunStore), do: GenServer.stop(pid)
        {:ok, _pid} = GenServer.start(RunStore, [], name: RunStore)
        :ok
    end
  end
end
