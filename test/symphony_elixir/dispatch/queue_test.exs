defmodule SymphonyElixir.Dispatch.QueueTest do
  # The dispatch queue: each open ticket's place is stored on its record as a fractional sort key,
  # top-level tickets in one queue and each parent's sub-tickets among themselves inside its place.
  # A new ticket joins at the end of its scope, a change of priority moves no ticket, a move writes
  # one key (a crowded spot rebalances only the tickets around it), the keys survive a restart, and
  # the first starts of the releases that stored the queue and its keys place the tickets already
  # there in the order the pass computed before, then turn those places into keys.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.{Queue, SortKey}
  alias SymphonyElixir.{TicketObservation, TicketState}

  @repo "repo-queue"
  @other_repo "repo-queue-b"

  setup do
    :ok = RunStore.clear()
    # A cleared store has no placement markers: the start that placed it is the one before the clear.
    :ok = RunStore.place_queue()
    :ok = RunStore.key_queue()
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
      places = %{"a" => ["a4"], "b" => ["aA"]}

      issues = [:not_an_issue, unplaced_ageless, unplaced_new, placed_second, unplaced_old, placed_first]

      assert issues |> Queue.order(places) |> Enum.map(&id/1) == ["a", "b", "c", "d", "e", :not_an_issue]
      # A store that could not be read gives no places.
      assert issues |> Queue.order({:error, :aborted}) |> Enum.map(&id/1) == ["b", "c", "d", "a", "e", :not_an_issue]
    end

    test "a parent's sub-tickets come right after it, in their own key order, before the next top-level ticket" do
      places = %{"epic" => ["a1"], "sub-b" => ["a1", "a0"], "sub-a" => ["a1", "Zz"], "deep" => ["a1", "a0", "a5"], "first" => ["a0"], "next" => ["a2"]}
      issues = Enum.map(["next", "deep", "sub-b", "epic", "first", "sub-a"], &issue(&1, String.upcase(&1)))

      assert issues |> Queue.order(places) |> Enum.map(&id/1) == ["first", "epic", "sub-a", "sub-b", "deep", "next"]
    end
  end

  describe "places/1" do
    test "rebuilt from the open tickets, their parent and their key alone; a done sub-ticket holds no place" do
      records = [
        keyed("epic", "a1"),
        keyed("first", "a0"),
        keyed("next", "a2"),
        keyed("sub-2", "a0", "EPIC"),
        keyed("sub-1", "Zz", "EPIC"),
        keyed("sub-done", nil, "EPIC"),
        keyed("deep", "a0", "SUB-2"),
        keyed("orphan", "a3", "GONE"),
        keyed("loop-a", "a4", "LOOP-B"),
        keyed("loop-b", "a5", "LOOP-A"),
        %{issue_id: nil, sort_key: "a9"}
      ]

      places = Queue.places(records)

      assert places == %{
               "epic" => ["a1"],
               "first" => ["a0"],
               "next" => ["a2"],
               "sub-1" => ["a1", "Zz"],
               "sub-2" => ["a1", "a0"],
               "deep" => ["a1", "a0", "a0"],
               "orphan" => ["a3"],
               "loop-a" => ["a5", "a4"],
               "loop-b" => ["a4", "a5"]
             }

      assert walk(places) == ["first", "epic", "sub-1", "sub-2", "deep", "next", "orphan", "loop-b", "loop-a"]
      assert Queue.scope(Enum.find(records, &(&1.issue_id == "sub-done"))) == "EPIC"
      assert Queue.scope(%{parent: nil}) == nil
    end
  end

  describe "parents/1" do
    test "the record's own parent wins, else the parent whose sub-issues list the ticket" do
      records = [
        Map.put(keyed("epic", "a1"), :sub_issues, [%{id: "never-ran"}, %{id: "ran"}, %{id: nil}]),
        Map.put(keyed("other", "a2"), :sub_issues, nil),
        keyed("ran", "a0", "OTHER"),
        keyed("never-ran", "a1"),
        %{issue_id: "no-identifier", sub_issues: [%{id: "lost"}]}
      ]

      assert Queue.parents(records) == %{"never-ran" => "EPIC", "ran" => "OTHER"}
    end
  end

  describe "TP-1633: broken_dependency/2" do
    test "names the first dependency a move turns upside down, never one already upside down" do
      record = fn id, key, depends_on, parent ->
        %{
          issue_id: id,
          issue_identifier: "MT-#{id}",
          sort_key: key,
          parent: parent && %{identifier: "MT-#{parent}"},
          depends_on: depends_on
        }
      end

      on = fn id -> [%{issue_id: id, identifier: "MT-#{id}", kind: :done}] end

      records = [
        record.("a", "a0", [], nil),
        record.("b", "a1", on.("a"), nil),
        record.("c", "a2", on.("d"), nil),
        record.("d", "a3", [], nil)
      ]

      # c already sits above d, which it depends on: a move that keeps it there is not refused.
      assert Queue.broken_dependency(records, records) == nil

      moved_b_up = Enum.map(records, &if(&1.issue_id == "b", do: %{&1 | sort_key: "Zz"}, else: &1))
      assert Queue.broken_dependency(records, moved_b_up) == {"b", "a"}

      # A sub-ticket depending on a ticket of another scope is compared where they meet: its parent.
      subs = [record.("p", "a0", [], nil), record.("s", "a0", on.("x"), "p"), record.("x", "a1", [], nil)]
      parent_up = Enum.map(subs, &if(&1.issue_id == "x", do: %{&1 | sort_key: "Zz"}, else: &1))
      assert Queue.broken_dependency(parent_up, subs) == {"s", "x"}
      # A record without a dependency list breaks nothing.
      assert Queue.broken_dependency([%{issue_id: "z", sort_key: "a0"}], [%{issue_id: "z", sort_key: "a0"}]) == nil
    end
  end

  describe "insertion/2" do
    test "one key between the two neighbours, at the top or at the end" do
      siblings = [{"a", "a0"}, {"b", "a1"}, {"c", "a2"}]

      assert Queue.insertion(siblings, 1) == [{:placed, "a0V"}]
      assert Queue.insertion(siblings, 0) == [{:placed, "Zz"}]
      assert Queue.insertion(siblings, 3) == [{:placed, "a3"}]
      assert Queue.insertion(siblings, 9) == [{:placed, "a3"}]
      assert Queue.insertion([], 0) == [{:placed, "a0"}]
      assert Queue.max_key_length() == 12
    end

    test "a key that would pass the length limit rewrites a window around the spot, doubling while it is too crowded" do
      mids = for digit <- String.graphemes("123456789ABCDEFGH"), do: "a00000000001" <> digit
      keys = ["Zu", "Zv", "Zw", "Zx", "Zy", "Zz", "a00000000001"] ++ mids ++ ["a00000000002" | ~w(a1 a2 a3 a4 a5 a6 a7 a8 a9 aA aB aC aD aE aF)]
      siblings = keys |> Enum.with_index() |> Enum.map(fn {key, index} -> {"t#{index}", key} end)
      assert Enum.sort(keys) == keys

      rewritten = Queue.insertion(siblings, 15)

      # Four on each side, then eight, are still too crowded; sixteen on each side fit.
      assert Enum.map(rewritten, &elem(&1, 0)) == Enum.map(0..14, &"t#{&1}") ++ [:placed] ++ Enum.map(15..30, &"t#{&1}")
      new_keys = Enum.map(rewritten, &elem(&1, 1))
      assert Enum.sort(new_keys) == new_keys
      assert Enum.all?(new_keys, &(byte_size(&1) <= Queue.max_key_length()))
      assert List.last(new_keys) < "a7"

      # A scope too crowded everywhere is rewritten whole, with no bound.
      assert Queue.insertion([{"x", "a0"}, {"y", "a00000000001"}], 1) == [{"x", "a0"}, {:placed, "a1"}, {"y", "a2"}]
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
    test "every open ticket holds a sort key, a new ticket joins at the end, and the keys survive a restart" do
      put!(@repo, "a", "MT-A", "Todo")
      put!(@other_repo, "b", "MT-B", "In Progress")
      put!(@repo, "done", "MT-D", "Done")
      put!(@repo, "c", "MT-C", "Backlog")

      assert places() == %{"a" => ["a0"], "b" => ["a1"], "c" => ["a2"]}
      assert %{sort_key: nil} = stored = RunStore.get_ticket_state("done")
      # No integer place is stored on any record.
      refute Map.has_key?(stored, :queue_position)
      refute Map.has_key?(raw("a"), :queue_position)
      assert raw("a").sort_key == "a0"

      # A write of the record without a key keeps the stored one.
      :ok = RunStore.put_ticket_state(TicketState.new(@repo, "a", %{issue_identifier: "MT-A", phase: "In Progress"}))
      assert places() == %{"a" => ["a0"], "b" => ["a1"], "c" => ["a2"]}

      restart_run_store()
      assert places() == %{"a" => ["a0"], "b" => ["a1"], "c" => ["a2"]}

      put!(@repo, "new", "MT-N", "Todo")
      assert places() == %{"a" => ["a0"], "b" => ["a1"], "c" => ["a2"], "new" => ["a3"]}
    end

    test "a ticket that reaches a terminal state leaves the queue, and joins at the end when reopened" do
      put!(@repo, "a", "MT-A", "Todo")
      put!(@repo, "b", "MT-B", "Todo")

      :ok = RunStore.update_ticket_state("a", %{phase: "Done"})
      assert places() == %{"b" => ["a1"]}

      :ok = RunStore.update_ticket_state("a", %{phase: "Todo"})
      assert places() == %{"a" => ["a2"], "b" => ["a1"]}

      :ok = RunStore.update_ticket_state("b", %{removed_at: DateTime.utc_now()})
      assert places() == %{"a" => ["a2"]}
    end

    test "a change of priority moves no ticket, and a read's new tickets join oldest first" do
      repo_key = Config.repo_key!()
      now = DateTime.utc_now()

      newer = issue("newer", "MT-1", repo_key: repo_key, created_at: ~U[2026-02-01 00:00:00Z], priority: 1, updated_at: now)
      older = issue("older", "MT-2", repo_key: repo_key, created_at: ~U[2026-01-01 00:00:00Z], priority: 4, updated_at: now)
      assert %{errors: 0} = TicketObservation.observe_all(repo_key, [newer, older], [])
      assert places() == %{"older" => ["a0"], "newer" => ["a1"]}

      later = DateTime.add(now, 60, :second)
      assert {:ok, :updated} = TicketObservation.observe(repo_key, %{older | priority: 1, updated_at: later})
      assert {:ok, :updated} = TicketObservation.observe(repo_key, %{newer | priority: 4, updated_at: later})

      assert %{priority: 1, sort_key: "a0"} = RunStore.get_ticket_state("older")
      assert %{priority: 4, sort_key: "a1"} = RunStore.get_ticket_state("newer")
    end

    test "an epic's sub-tickets are ordered among themselves inside its place, and a done one keeps its parent" do
      put!(@repo, "first", "MT-1", "Todo")
      put!(@repo, "epic", "MT-E", "Waiting on sub-tickets")
      put!(@repo, "sub-1", "MT-S1", "Todo", "MT-E")
      put!(@repo, "next", "MT-2", "Todo")
      put!(@repo, "sub-2", "MT-S2", "Todo", "MT-E")
      put!(@repo, "sub-3", "MT-S3", "In Progress", "MT-E")

      assert walk(places()) == ["first", "epic", "sub-1", "sub-2", "sub-3", "next"]
      # The sub-tickets' keys are their own scope's: they start again from the first key.
      assert %{"sub-1" => ["a1", "a0"], "sub-2" => ["a1", "a1"], "next" => ["a2"]} = places()

      :ok = RunStore.update_ticket_state("sub-1", %{phase: "Done"})
      assert %{sort_key: nil, parent: %{identifier: "MT-E"}} = RunStore.get_ticket_state("sub-1")
      assert walk(places()) == ["first", "epic", "sub-2", "sub-3", "next"]

      # Reopened, it joins at the end of its siblings.
      :ok = RunStore.update_ticket_state("sub-1", %{phase: "Todo"})
      assert walk(places()) == ["first", "epic", "sub-2", "sub-3", "sub-1", "next"]

      # A ticket given a parent later joins at the end of that parent's sub-tickets.
      :ok = RunStore.update_ticket_state("next", %{parent: %{identifier: "MT-E"}})
      assert walk(places()) == ["first", "epic", "sub-2", "sub-3", "sub-1", "next"]
      assert places()["next"] == ["a1", "a4"]

      # The epic done, its open sub-tickets are ordered at the top level by their own keys.
      :ok = RunStore.update_ticket_state("epic", %{phase: "Done"})
      assert walk(places()) == ["first", "sub-2", "sub-3", "sub-1", "next"]
    end

    test "a move puts a ticket between two neighbours, at the top or at the end, and writes that ticket's record only" do
      for {id, n} <- [{"a", 1}, {"b", 2}, {"c", 3}, {"d", 4}], do: put!(@repo, id, "MT-#{n}", "Todo")
      put!(@repo, "epic", "MT-E", "Todo")
      for {id, n} <- [{"s1", 1}, {"s2", 2}, {"s3", 3}], do: put!(@repo, id, "MT-S#{n}", "Todo", "MT-E")
      assert walk(places()) == ["a", "b", "c", "d", "epic", "s1", "s2", "s3"]

      before = raws()
      assert :ok = RunStore.move_in_queue("d", {:between, "a", "b"})
      assert walk(places()) == ["a", "d", "b", "c", "epic", "s1", "s2", "s3"]
      assert only_changed(before) == ["d"]
      assert raw("d").sort_key == "a0V"

      before = raws()
      assert :ok = RunStore.move_in_queue("c", :top)
      assert walk(places()) == ["c", "a", "d", "b", "epic", "s1", "s2", "s3"]
      assert only_changed(before) == ["c"]

      before = raws()
      assert :ok = RunStore.move_in_queue("a", :end)
      assert walk(places()) == ["c", "d", "b", "epic", "s1", "s2", "s3", "a"]
      assert only_changed(before) == ["a"]

      # Among its siblings, inside the parent's place.
      before = raws()
      assert :ok = RunStore.move_in_queue("s3", {:between, nil, "s1"})
      assert :ok = RunStore.move_in_queue("s1", {:between, "s2", nil})
      assert walk(places()) == ["c", "d", "b", "epic", "s3", "s2", "s1", "a"]
      assert only_changed(before) == ["s1", "s3"]

      # Moving the epic carries its sub-tickets with it.
      assert :ok = RunStore.move_in_queue("epic", {:between, "c", "d"})
      assert walk(places()) == ["c", "epic", "s3", "s2", "s1", "d", "b", "a"]

      before = raws()
      assert {:error, :not_neighbours} = RunStore.move_in_queue("s2", {:between, "c", "d"})
      assert {:error, :not_neighbours} = RunStore.move_in_queue("b", {:between, "c", "a"})
      assert {:error, :not_neighbours} = RunStore.move_in_queue("b", {:between, "missing", "a"})
      assert {:error, :not_neighbours} = RunStore.move_in_queue("b", {:between, nil, "d"})
      assert {:error, :not_in_queue} = RunStore.move_in_queue("missing", :top)
      :ok = RunStore.update_ticket_state("b", %{phase: "Done"})
      assert {:error, :not_in_queue} = RunStore.move_in_queue("b", :top)
      assert only_changed(before) == ["b"]
    end

    test "a move into a crowded spot rewrites only the tickets around it, evenly spaced and in the same order" do
      keys = ~w(Zv Zw Zx Zy Zz a0 a00000000001 a1 a2 a3 a4 a5 a6)
      for {key, index} <- Enum.with_index(keys), do: put!(@repo, "t#{index}", "MT-#{index}", "Todo", nil, key)
      put!(@repo, "mover", "MT-M", "Todo", nil, "a7")

      before = raws()
      assert :ok = RunStore.move_in_queue("mover", {:between, "t5", "t6"})

      assert walk(places()) == ~w(t0 t1 t2 t3 t4 t5 mover t6 t7 t8 t9 t10 t11 t12)
      # Four tickets on each side of the spot are rewritten; the rest keep their keys.
      assert only_changed(before) == Enum.sort(~w(mover t2 t3 t4 t5 t6 t7 t8 t9))
      assert Enum.map(~w(t0 t1 t10 t11 t12), &raw(&1).sort_key) == ~w(Zv Zw a4 a5 a6)
      assert {:ok, Enum.map(~w(t2 t3 t4 t5 mover t6 t7 t8 t9), &raw(&1).sort_key)} == SortKey.n_keys_between("Zw", "a4", 9)
    end

    test "a ticket joining after a key too long to follow rebalances the tickets before it" do
      put!(@repo, "t0", "MT-0", "Todo", nil, "a0")
      put!(@repo, "t1", "MT-1", "Todo", nil, String.duplicate("z", 27) <> "V")

      put!(@repo, "new", "MT-N", "Todo")

      assert walk(places()) == ~w(t0 t1 new)
      assert Enum.map(~w(t0 t1 new), &raw(&1).sort_key) == ~w(a0 a1 a2)
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

      placed = %{"merging" => ["a0"], "progress" => ["a1"], "todo-ran" => ["a2"], "todo-urgent" => ["a3"], "backlog-urgent" => ["a4"], "todo-low" => ["a5"]}
      assert places() == placed
      refute Map.get(RunStore.get_ticket_state("done"), :sort_key)
      refute Map.has_key?(raw("done"), :queue_position)

      # Its markers set, a later start leaves every key as it is, even one changed since.
      :ok = RunStore.update_ticket_state("todo-low", %{priority: 1})
      restart_run_store()
      assert places() == placed

      put!(@repo, "new", "MT-NEW", "Todo")
      assert places()["new"] == ["a6"]
    end

    test "the first start of the sort keys turns the stored places into keys in the same order, sub-tickets among their siblings" do
      with_positions!([
        {record("third", "Todo", 1, nil), 7},
        {record("first", "In Progress", 4, nil), 2},
        {record("epic", "Waiting on sub-tickets", 4, nil), 5},
        {record("sub-late", "Todo", 4, nil, "EPIC"), 9},
        {record("sub-early", "Todo", 4, nil, "EPIC"), 3},
        {record("sub-unplaced", "Todo", 4, ~U[2026-01-01 00:00:00Z], "EPIC"), nil},
        {record("sub-done", "Done", 4, nil, "EPIC"), 4},
        {record("unplaced", "Todo", 4, ~U[2026-01-01 00:00:00Z]), nil},
        {record("unplaced-ageless", "Todo", 4, nil), nil}
      ])

      restart_run_store()

      assert walk(places()) == ["first", "epic", "sub-early", "sub-late", "sub-unplaced", "third", "unplaced-ageless", "unplaced"]

      assert places() == %{
               "first" => ["a0"],
               "epic" => ["a1"],
               "sub-early" => ["a1", "a0"],
               "sub-late" => ["a1", "a1"],
               "sub-unplaced" => ["a1", "a2"],
               "third" => ["a2"],
               "unplaced-ageless" => ["a3"],
               "unplaced" => ["a4"]
             }

      assert %{sort_key: nil, parent: %{identifier: "EPIC"}} = RunStore.get_ticket_state("sub-done")
      assert Enum.all?(raws(), fn {_id, record} -> not Map.has_key?(record, :queue_position) end)
      assert :mnesia.dirty_read(:symphony_run_store_totals, :queue_tail) == []

      # A later start changes no key.
      keys = raws()
      restart_run_store()
      assert raws() == keys
    end
  end

  defp places, do: RunStore.queue_places()

  # The ticket ids in the order their places sort in.
  defp walk(places), do: places |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

  defp put!(repo_key, issue_id, identifier, phase, parent \\ nil, key \\ nil) do
    attrs = %{issue_identifier: identifier, phase: phase, parent: parent && %{identifier: parent}, sort_key: key}
    :ok = RunStore.put_ticket_state(TicketState.new(repo_key, issue_id, attrs))
  end

  defp keyed(issue_id, key, parent \\ nil) do
    TicketState.new(@repo, issue_id, %{issue_identifier: String.upcase(issue_id), phase: "Todo", sort_key: key, parent: parent && %{identifier: parent}})
  end

  # Every ticket's record as the store keeps it.
  defp raws do
    :symphony_run_store_ticket_index
    |> :mnesia.dirty_match_object({:symphony_run_store_ticket_index, :_, :_, :_})
    |> Map.new(fn {_table, id, _repo, record} -> {id, record} end)
  end

  defp raw(issue_id), do: Map.fetch!(raws(), issue_id)

  # The ids of the records written since `before`, sorted.
  defp only_changed(before) do
    after_move = raws()
    after_move |> Map.keys() |> Enum.reject(&(Map.get(before, &1) == Map.get(after_move, &1))) |> Enum.sort()
  end

  # The records as a release before the queue kept them: no place, and no placement marker.
  defp before_the_queue!(records) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        for record <- records do
          :mnesia.write({:symphony_run_store_ticket_index, record.issue_id, record.repo_key, Map.delete(record, :sort_key)})
        end

        :mnesia.delete({:symphony_run_store_totals, {:marker, "queue_placed_v1"}})
        :mnesia.delete({:symphony_run_store_totals, {:marker, "queue_keys_v1"}})
      end)
  end

  # The records as the release that stored integer places kept them: each one's place (nil for
  # none), no key, the highest place given, and no sort keys' marker.
  defp with_positions!(records) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        for {record, position} <- records do
          stored = record |> Map.delete(:sort_key) |> Map.put(:queue_position, position)
          :mnesia.write({:symphony_run_store_ticket_index, record.issue_id, record.repo_key, stored})
        end

        :mnesia.write({:symphony_run_store_totals, :queue_tail, 9})
        :mnesia.delete({:symphony_run_store_totals, {:marker, "queue_keys_v1"}})
      end)
  end

  defp record(issue_id, phase, priority, created_at, parent \\ nil) do
    TicketState.new(@repo, issue_id, %{
      issue_identifier: String.upcase(issue_id),
      phase: phase,
      priority: priority,
      created_at: created_at,
      parent: parent && %{identifier: parent}
    })
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
