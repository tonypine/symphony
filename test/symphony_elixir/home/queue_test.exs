defmodule SymphonyElixir.Home.QueueTest do
  # The Home read's queue rows (`SymphonyElixir.Home.Queue`), from ticket records with stored sort
  # keys: top-level tickets and sub-tickets in the stored order with their numbers, tickets in work
  # left out, a sub-ticket that never ran placed under its parent, pages and a saved filter.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Situation, TicketList, TicketState}
  alias SymphonyElixir.Dispatch.Queue, as: DispatchQueue
  alias SymphonyElixir.Home.Queue

  @all %{offset: 0, limit: 100, matching: nil}

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  test "every open ticket that is not in work, in the stored order, with its number, state, title, what it waits on and its repo" do
    records = [
      record("MT-3", "Todo", "a3", depends_on: [dep("MT-1"), %{dep("MT-9") | kind: :released}, dep("MT-0")]),
      record("MT-1", "Backlog", "a1", repo_key: "shop"),
      record("MT-2", "Todo", "a2"),
      # In work: a slot holder, a ticket a run works on, and a sub-ticket under the holder.
      record("MT-H", "In Progress", "a0", slot_held_since: ~U[2026-11-24 08:00:00Z], slot_number: 1),
      record("MT-HS", "Todo", "a1", parent: %{identifier: "MT-H"}),
      record("MT-R", "Todo", "a4"),
      # Out of the queue: done, or with no place.
      record("MT-0", "Done", nil),
      record("MT-9", "Done", nil),
      record("MT-N", "Todo", nil)
    ]

    in_work = MapSet.new(["id-MT-H", "id-MT-R"])
    read = Queue.read(records, in_work, DispatchQueue.parents(records), live(), @all)

    assert Enum.map(read.rows, &{&1.number, &1.identifier}) == [{"1", "MT-1"}, {"2", "MT-2"}, {"3", "MT-3"}]
    assert %{count: 3, total: 3, offset: 0, limit: 100, next_offset: nil} = read

    [first, _second, third] = read.rows
    assert %{issue_id: "id-MT-1", title: "Ticket MT-1", phase: "Backlog", repo_key: "shop", path: [1], parent: nil, waits_on: [], sub_tickets: nil} = first
    assert %{situation: %{kind: _kind}, waits_on_you: false, move: nil} = first

    # MT-0 is done: met. MT-9 is done but needs a release: met for a build from a checkout, as the
    # readers that show who waits on whom count it (`DependsOn.open/2`).
    assert third.waits_on == [%{issue_id: "id-MT-1", identifier: "MT-1", kind: "done"}]
  end

  test "a sub-ticket sits under its parent and is numbered inside it, at any depth; one that never ran is placed from its parent's sub-issues" do
    records = [
      record("MT-1", "Todo", "a1"),
      # The epic lists MT-5, whose record names no parent: it never ran.
      record("MT-2", "Todo", "a2", sub_issues: [link("MT-5", "Todo"), link("MT-4", "Done"), link("MT-7", "Canceled"), link("MT-8", "Todo")]),
      record("MT-3", "Todo", "a1", parent: %{identifier: "MT-2"}),
      record("MT-5", "Todo", "a2"),
      record("MT-6", "Backlog", "a1", parent: %{identifier: "MT-5"}),
      record("MT-4", "Done", nil, parent: %{identifier: "MT-2"}),
      record("MT-9", "Todo", "a3")
    ]

    rows = Queue.rows(records, MapSet.new(), DispatchQueue.parents(records), live())

    assert Enum.map(rows, &{&1.number, &1.identifier, &1.parent}) == [
             {"1", "MT-1", nil},
             {"2", "MT-2", nil},
             {"2.1", "MT-3", "MT-2"},
             {"2.2", "MT-5", "MT-2"},
             {"2.2.1", "MT-6", "MT-5"},
             {"3", "MT-9", nil}
           ]

    epic = Enum.find(rows, &(&1.identifier == "MT-2"))
    assert epic.path == [2]
    # MT-3, MT-4 (done) and MT-5 by their records, MT-8 by the link: MT-7 is cancelled.
    assert epic.sub_tickets == %{done: 1, total: 4}
    assert Enum.find(rows, &(&1.identifier == "MT-5")).sub_tickets == %{done: 0, total: 1}

    # Without the parent resolved, the stored order alone puts MT-5 at the top level.
    assert DispatchQueue.places(records) |> Map.fetch!("id-MT-5") == ["a2"]
    assert DispatchQueue.places(records, DispatchQueue.parents(records)) |> Map.fetch!("id-MT-5") == ["a2", "a2"]
  end

  test "page after page gives every queued ticket exactly once, in the stored order" do
    records = for n <- 1..7, do: record("MT-#{n}", "Todo", "a#{n}")
    parents = DispatchQueue.parents(records)
    whole = records |> Queue.rows(MapSet.new(), parents, live()) |> Enum.map(& &1.identifier)

    pages =
      Stream.unfold(0, fn
        nil -> nil
        offset -> Queue.read(records, MapSet.new(), parents, live(), %{offset: offset, limit: 3, matching: nil}) |> then(&{&1, &1.next_offset})
      end)
      |> Enum.to_list()

    assert Enum.map(pages, &{&1.offset, &1.next_offset, length(&1.rows)}) == [{0, 3, 3}, {3, 6, 3}, {6, nil, 1}]
    assert pages |> Enum.flat_map(& &1.rows) |> Enum.map(& &1.identifier) == whole
    assert length(whole) == 7
    assert Queue.read(records, MapSet.new(), parents, live(), %{offset: 9, limit: 3, matching: nil}).rows == []
  end

  test "a filter keeps the matching rows with their real numbers, and an epic's row while one of its sub-tickets matches" do
    records = [
      record("MT-1", "Todo", "a1"),
      record("MT-2", "Backlog", "a2"),
      record("MT-3", "Todo", "a1", parent: %{identifier: "MT-2"}),
      record("MT-4", "Backlog", "a2", parent: %{identifier: "MT-2"}),
      record("MT-5", "Backlog", "a3")
    ]

    matching = TicketList.matching([%{column: "phase", value: ["todo"]}], records: records)
    assert matching == MapSet.new(["id-MT-1", "id-MT-3"])

    read = Queue.read(records, MapSet.new(), DispatchQueue.parents(records), live(), %{@all | matching: matching})

    assert Enum.map(read.rows, &{&1.number, &1.identifier}) == [{"1", "MT-1"}, {"2", "MT-2"}, {"2.1", "MT-3"}]
    assert %{count: 3, total: 5} = read
  end

  test "the page a query asks for: defaults, a cap, and a refusal for anything but a whole number" do
    assert Queue.page(%{}) == {:ok, %{offset: 0, limit: Queue.default_limit()}}
    assert Queue.page(%{"offset" => "", "limit" => ""}) == {:ok, %{offset: 0, limit: 100}}
    assert Queue.page(%{"offset" => "40", "limit" => "20"}) == {:ok, %{offset: 40, limit: 20}}
    assert Queue.page(%{"limit" => "100000"}) == {:ok, %{offset: 0, limit: Queue.max_limit()}}
    assert {:error, {:invalid, "offset must be a whole number from 0"}} = Queue.page(%{"offset" => "-1"})
    assert {:error, {:invalid, "limit must be a whole number from 1"}} = Queue.page(%{"limit" => "0"})
    assert {:error, {:invalid, "limit must be a whole number from 1"}} = Queue.page(%{"limit" => "ten"})
  end

  defp record(identifier, phase, sort_key, attrs \\ []) do
    Map.merge(
      %{repo_key: "default", issue_id: "id-#{identifier}", issue_identifier: identifier, title: "Ticket #{identifier}", phase: phase, priority: 1, sort_key: sort_key},
      Map.new(attrs)
    )
    |> TicketState.normalize()
  end

  defp link(identifier, state), do: %{id: "id-#{identifier}", identifier: identifier, state: state}

  defp dep(identifier), do: %{issue_id: "id-#{identifier}", identifier: identifier, kind: :done}

  defp live, do: Situation.live_facts(%{})
end
