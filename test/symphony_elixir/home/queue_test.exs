defmodule SymphonyElixir.Home.QueueTest do
  # The Home read's queue rows (`SymphonyElixir.Home.Queue`), from ticket records with stored sort
  # keys: top-level tickets and sub-tickets in the stored order with their numbers, tickets in work
  # left out, a sub-ticket that never ran placed under its parent, pages and a saved filter.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.Queue, as: DispatchQueue
  alias SymphonyElixir.Home.Queue
  alias SymphonyElixir.Situation
  alias SymphonyElixir.TicketList
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.TicketState

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
    assert %{issue_id: "id-MT-1", title: "Ticket MT-1", phase: "Backlog", repo_key: "shop", path: [1]} = first
    assert %{parent: nil, waits_on: [], sub_tickets: nil} = first
    assert %{situation: %{kind: _kind}, waits_on_you: false, move: nil} = first

    # MT-0 is done: met. MT-9 is done but needs a release: met for a build from a checkout, as the
    # readers that show who waits on whom count it (`DependsOn.open/2`).
    assert third.waits_on == [%{issue_id: "id-MT-1", identifier: "MT-1", kind: "done"}]

    # Every key a row gave before the dependencies and the done sub-tickets were added is still there.
    old_keys = [
      :issue_id,
      :identifier,
      :title,
      :phase,
      :repo_key,
      :number,
      :path,
      :parent,
      :waits_on,
      :sub_tickets,
      :situation,
      :waits_on_you,
      :move
    ]

    assert Enum.all?(read.rows, &(old_keys -- Map.keys(&1) == []))
    assert Enum.map(third.dependencies, &{&1.identifier, &1.met}) == [{"MT-1", false}, {"MT-9", true}, {"MT-0", true}]
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

  test "a row lists every stored dependency with its kind and whether it is met, and waits on the open ones alone" do
    # One stored dependency per ticket: a met and an unmet one of each kind, and one with no record.
    depends_on = [dep("MT-D"), dep("MT-T"), %{dep("MT-E") | kind: :released}, %{dep("MT-U") | kind: :released}, dep("MT-Z")]

    records = [
      record("MT-1", "Todo", "a1", depends_on: depends_on),
      record("MT-T", "Todo", "a2"),
      record("MT-U", "Todo", "a3"),
      record("MT-D", "Done", nil),
      record("MT-E", "Done", nil)
    ]

    [row | _others] = Queue.rows(records, MapSet.new(), DispatchQueue.parents(records), live())

    # MT-Z has no record: unmet, named by the stored identifier.
    assert row.dependencies == [
             %{issue_id: "id-MT-D", identifier: "MT-D", kind: "done", met: true},
             %{issue_id: "id-MT-T", identifier: "MT-T", kind: "done", met: false},
             %{issue_id: "id-MT-E", identifier: "MT-E", kind: "released", met: true},
             %{issue_id: "id-MT-U", identifier: "MT-U", kind: "released", met: false},
             %{issue_id: "id-MT-Z", identifier: "MT-Z", kind: "done", met: false}
           ]

    assert row.waits_on == [
             %{issue_id: "id-MT-T", identifier: "MT-T", kind: "done"},
             %{issue_id: "id-MT-U", identifier: "MT-U", kind: "released"},
             %{issue_id: "id-MT-Z", identifier: "MT-Z", kind: "done"}
           ]

    # A dependency stored without its identifier is named by its ticket's record.
    records = [record("MT-1", "Todo", "a1", depends_on: [%{issue_id: "id-MT-T", identifier: nil, kind: :done}]), record("MT-T", "Todo", "a2")]
    [row, _other] = Queue.rows(records, MapSet.new(), DispatchQueue.parents(records), live())
    assert row.dependencies == [%{issue_id: "id-MT-T", identifier: "MT-T", kind: "done", met: false}]
  end

  test "an epic's row carries its done sub-tickets in order of completion with their count; its open ones are the rows under it, each naming it" do
    parent = %{identifier: "MT-E"}

    records = [
      record("MT-E", "Todo", "a1", sub_issues: [link("MT-K", "Done"), link("MT-X", "Canceled")]),
      record("MT-2", "Todo", "a2", parent: parent),
      record("MT-1", "Backlog", "a1", parent: parent),
      record("MT-A", "Done", nil, parent: parent, phase_at: ~U[2026-11-24 09:00:00Z]),
      record("MT-B", "Done", nil, parent: parent, phase_at: ~U[2026-11-24 08:00:00Z]),
      record("MT-C", "Canceled", nil, parent: parent),
      record("MT-9", "Todo", "a2")
    ]

    :ok = TicketPullRequest.record_created("default", "id-MT-A", "https://github.com/acme/app/pull/41", "auto/MT-A")
    :ok = TicketPullRequest.mark_finished("default", "https://github.com/acme/app/pull/41", "merged")

    read = Queue.read(records, MapSet.new(), DispatchQueue.parents(records), live(), @all)

    assert Enum.map(read.rows, &{&1.number, &1.identifier, &1.parent}) == [{"1", "MT-E", nil}, {"1.1", "MT-1", "MT-E"}, {"1.2", "MT-2", "MT-E"}, {"2", "MT-9", nil}]
    assert %{count: 4, total: 4} = read

    [epic | _rest] = read.rows
    assert epic.sub_tickets == %{done: 3, total: 5}

    assert epic.done_sub_tickets == [
             %{issue_id: "id-MT-K", identifier: "MT-K", title: nil, pull_request_number: nil, done_at: nil},
             %{issue_id: "id-MT-B", identifier: "MT-B", title: "Ticket MT-B", pull_request_number: nil, done_at: ~U[2026-11-24 08:00:00Z]},
             %{issue_id: "id-MT-A", identifier: "MT-A", title: "Ticket MT-A", pull_request_number: 41, done_at: ~U[2026-11-24 09:00:00Z]}
           ]

    assert Enum.all?(tl(read.rows), &(&1.done_sub_tickets == [] and &1.sub_tickets == nil))
  end

  test "a filter that matches only a sub-ticket gives its epic with that sub-ticket alone; an epic that matches is given with its done sub-tickets" do
    parent = %{identifier: "MT-E"}

    records = [
      record("MT-E", "Todo", "a1"),
      record("MT-1", "Todo", "a1", parent: parent),
      record("MT-2", "Todo", "a2", parent: parent),
      record("MT-D", "Done", nil, parent: parent),
      record("MT-9", "Todo", "a2")
    ]

    parents = DispatchQueue.parents(records)
    read = fn ids -> Queue.read(records, MapSet.new(), parents, live(), %{@all | matching: MapSet.new(ids)}) end

    only_sub = read.(["id-MT-2"])
    assert Enum.map(only_sub.rows, &{&1.number, &1.identifier, &1.parent}) == [{"1", "MT-E", nil}, {"1.2", "MT-2", "MT-E"}]
    assert %{count: 2, total: 4} = only_sub

    only_epic = read.(["id-MT-E"])
    assert [%{identifier: "MT-E", sub_tickets: %{done: 1, total: 3}, done_sub_tickets: [%{identifier: "MT-D"}]}] = only_epic.rows
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
      %{
        repo_key: "default",
        issue_id: "id-#{identifier}",
        issue_identifier: identifier,
        title: "Ticket #{identifier}",
        phase: phase,
        priority: 1,
        sort_key: sort_key
      },
      Map.new(attrs)
    )
    |> TicketState.normalize()
  end

  defp link(identifier, state), do: %{id: "id-#{identifier}", identifier: identifier, state: state}

  defp dep(identifier), do: %{issue_id: "id-#{identifier}", identifier: identifier, kind: :done}

  defp live, do: Situation.live_facts(%{})
end
