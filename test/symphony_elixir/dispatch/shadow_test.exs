defmodule SymphonyElixir.Dispatch.ShadowTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Dispatch.Shadow

  @now ~U[2026-10-29 17:00:00Z]
  @empty %{
    cycles_compared: 0,
    cycles_with_differences: 0,
    window_cycles: 0,
    window_differences: 0,
    recent: [],
    record_newer: %{count: 0, recent: []}
  }

  setup do
    Shadow.reset()
    on_exit(&Shadow.reset/0)
    :ok
  end

  defp issue(id, identifier, attrs \\ []) do
    struct!(%Issue{id: id, identifier: identifier, title: "Ticket #{identifier}", state: "Todo", priority: 1, repo_key: "web"}, attrs)
  end

  describe "compare/2" do
    test "equal sets have no difference, whatever the order" do
      poll = [issue("a", "MT-1"), issue("b", "MT-2", state: "Rework")]
      assert Shadow.compare(poll, Enum.reverse(poll)) == []
      assert Shadow.compare([], []) == []
    end

    test "names a ticket only one side has, with the side and the state the other lacks" do
      assert Shadow.compare([issue("a", "MT-1"), issue("b", "MT-2")], [issue("b", "MT-2"), issue("c", "MT-3", state: "Rework")]) == [
               %{repo_key: "web", issue_id: "a", identifier: "MT-1", side: :poll, field: :candidate, poll: "Todo", record: nil},
               %{repo_key: "web", issue_id: "c", identifier: "MT-3", side: :record, field: :candidate, poll: nil, record: "Rework"}
             ]
    end

    test "names each field a ticket in both differs on, the state before the priority" do
      assert Shadow.compare([issue("a", "MT-1")], [issue("a", "MT-1", state: "In Progress", priority: 3)]) == [
               %{repo_key: "web", issue_id: "a", identifier: "MT-1", side: :both, field: :state, poll: "Todo", record: "In Progress"},
               %{repo_key: "web", issue_id: "a", identifier: "MT-1", side: :both, field: :priority, poll: 1, record: 3}
             ]

      unset = issue("a", "MT-1", priority: nil)
      assert [%{field: :priority, poll: nil, record: 2}] = Shadow.compare([unset], [issue("a", "MT-1", priority: 2)])
    end

    test "with the record in use, the differences read the same: the poll and record sides are kept" do
      poll = [issue("a", "MT-1"), issue("b", "MT-2", priority: 2)]
      record = [issue("b", "MT-2", priority: 3), issue("c", "MT-3")]

      assert Shadow.compare(record, poll, :record) == Shadow.compare(poll, record)
      assert Shadow.compare(poll, record, :poll) == Shadow.compare(poll, record)

      assert [%{side: :poll, identifier: "MT-1"}, %{side: :both, poll: 2, record: 3}, %{side: :record, identifier: "MT-3"}] =
               Shadow.compare(record, poll, :record)
    end

    test "matches tickets by id, so a renamed identifier is the same ticket" do
      assert Shadow.compare([issue("a", "MT-1")], [issue("a", "MT-9")]) == []
    end
  end

  describe "classify/4" do
    @read_at ~U[2026-10-29 17:50:30Z]

    test "a state the record's phase moved to after the snapshot was read is record_newer, not a difference" do
      # TP-1222: the poll read Rework, then Symphony moved the record to Code Review.
      differences = Shadow.compare([issue("a", "MT-1", state: "Rework")], [issue("a", "MT-1", state: "Code Review")])

      assert Shadow.classify(differences, @read_at, %{"a" => DateTime.add(@read_at, 7)}) == %{differences: [], record_newer: differences}
      assert [%{identifier: "MT-1", side: :both, field: :state, poll: "Rework", record: "Code Review"}] = differences
    end

    test "a record phase written before the snapshot was read, or at the same time, still differs" do
      differences = Shadow.compare([issue("a", "MT-1", state: "Rework")], [issue("a", "MT-1", state: "Code Review")])

      assert %{differences: [%{identifier: "MT-1", field: :state}], record_newer: []} =
               Shadow.classify(differences, @read_at, %{"a" => DateTime.add(@read_at, -60)})

      assert %{differences: [_difference], record_newer: []} = Shadow.classify(differences, @read_at, %{"a" => @read_at})
    end

    test "a move in or out of the active states is record_newer too; a priority difference never is" do
      left = Shadow.compare([issue("a", "MT-1")], [])
      entered = Shadow.compare([], [issue("b", "MT-2", state: "Rework")])
      priority = Shadow.compare([issue("c", "MT-3")], [issue("c", "MT-3", priority: 3)])
      later = DateTime.add(@read_at, 5)

      classified = Shadow.classify(left ++ entered ++ priority, @read_at, %{"a" => later, "b" => later, "c" => later})
      assert [%{identifier: "MT-3", field: :priority}] = classified.differences
      assert [%{identifier: "MT-1"}, %{identifier: "MT-2"}] = classified.record_newer
    end

    test "TP-1281 replayed: a ticket the poll still lists in Merging whose record went Done after the read is record_newer" do
      closed = Shadow.compare([issue("a", "MT-1", state: "Merging")], [])
      assert [%{identifier: "MT-1", side: :poll, field: :candidate, poll: "Merging", record: nil}] = closed

      assert Shadow.classify(closed, @read_at, %{"a" => DateTime.add(@read_at, 4)}) == %{differences: [], record_newer: closed}

      # A record written before the read, or no record at all, still lacks a ticket the poll lists.
      assert Shadow.classify(closed, @read_at, %{"a" => DateTime.add(@read_at, -60)}) == %{differences: closed, record_newer: []}
      assert Shadow.classify(closed, @read_at, %{}) == %{differences: closed, record_newer: []}
    end

    test "a ticket Symphony promoted after the read, which only the record has yet, is record_newer" do
      promoted = Shadow.compare([], [issue("b", "MT-2", state: "Todo")])
      assert [%{identifier: "MT-2", side: :record, field: :candidate}] = promoted

      assert Shadow.classify(promoted, @read_at, %{"b" => DateTime.add(@read_at, 2)}) == %{differences: [], record_newer: promoted}
      assert Shadow.classify(promoted, @read_at, %{"b" => @read_at}) == %{differences: promoted, record_newer: []}
    end

    test "TP-1300 replayed: the cycle Symphony's own move forces reads Linear before the move lands, so the state is record_newer" do
      # Symphony wrote Code Review at T; the forced cycle read Linear at T+1s and still got Rework,
      # last changed at T-60s: Linear had not served the move yet.
      phase_at = ~U[2026-10-30 09:43:22Z]
      read_at = DateTime.add(phase_at, 1)
      differences = Shadow.compare([issue("a", "MT-1", state: "Rework")], [issue("a", "MT-1", state: "Code Review")])
      own_moves = [symphony_phase_at: %{"a" => phase_at}, updated_at: %{"a" => DateTime.add(phase_at, -60)}]

      classified = Shadow.classify(differences, read_at, %{"a" => phase_at}, own_moves)
      assert classified == %{differences: [], record_newer: differences}

      refute capture_log(fn -> Shadow.record(classified, 20, @now) end) =~ "Dispatch shadow difference"

      assert %{window_differences: 0, recent: [], record_newer: %{count: 1}} = Shadow.summary()

      # A close of Symphony's that the read predates: the poll still lists the ticket.
      closed = Shadow.compare([issue("a", "MT-1", state: "Merging")], [])
      assert Shadow.classify(closed, read_at, %{"a" => phase_at}, own_moves) == %{differences: [], record_newer: closed}
    end

    test "a hand move after Symphony's phase write leaves Linear's updatedAt after it, and stays a difference" do
      phase_at = ~U[2026-10-30 09:43:22Z]
      read_at = DateTime.add(phase_at, 120)
      differences = Shadow.compare([issue("a", "MT-1", state: "Rework")], [issue("a", "MT-1", state: "Code Review")])
      written = %{"a" => phase_at}
      moved_by_hand = DateTime.add(phase_at, 60)

      by_hand = [symphony_phase_at: written, updated_at: %{"a" => moved_by_hand}]
      assert Shadow.classify(differences, read_at, written, by_hand) == %{differences: differences, record_newer: []}

      # Linear's updatedAt equal to the phase write is no older than it either.
      assert %{differences: [_difference], record_newer: []} =
               Shadow.classify(differences, read_at, written, symphony_phase_at: written, updated_at: written)
    end

    test "the own-move rule needs a phase Symphony wrote, the snapshot's updatedAt, and a state or presence difference" do
      phase_at = ~U[2026-10-30 09:43:22Z]
      read_at = DateTime.add(phase_at, 1)
      older = DateTime.add(phase_at, -60)
      differences = Shadow.compare([issue("a", "MT-1", state: "Rework")], [issue("a", "MT-1", state: "Code Review")])

      # A phase an observation wrote (not Symphony's), or a ticket whose updatedAt the snapshot lacks.
      written = %{"a" => phase_at}
      unchanged = %{differences: differences, record_newer: []}
      assert Shadow.classify(differences, read_at, written, updated_at: %{"a" => older}) == unchanged
      assert Shadow.classify(differences, read_at, written, symphony_phase_at: written) == unchanged

      # A priority difference is never a phase write's.
      priority = Shadow.compare([issue("c", "MT-3")], [issue("c", "MT-3", priority: 3)])

      assert %{differences: [%{field: :priority}], record_newer: []} =
               Shadow.classify(priority, read_at, %{}, symphony_phase_at: %{"c" => phase_at}, updated_at: %{"c" => older})
    end

    test "with no known read time or phase write time, a difference stays a difference" do
      differences = Shadow.compare([issue("a", "MT-1", state: "Rework")], [issue("a", "MT-1", state: "Code Review")])

      assert %{differences: [_difference], record_newer: []} = Shadow.classify(differences, nil, %{"a" => @read_at})
      assert %{differences: [_difference], record_newer: []} = Shadow.classify(differences, @read_at, %{"a" => nil})
      assert %{differences: [_difference], record_newer: []} = Shadow.classify(differences, @read_at, %{})
    end
  end

  describe "record/3 and summary/0" do
    test "an empty report before any cycle" do
      assert Shadow.summary() == @empty
    end

    test "counts a cycle with equal sets and no difference" do
      assert :ok = Shadow.record([], 20, @now)

      assert Shadow.summary() == %{@empty | cycles_compared: 1, window_cycles: 1}
    end

    test "a ticket only in the poll is one difference naming it and the side, logged once while it lasts" do
      [difference] = Shadow.compare([issue("a", "MT-1")], [])

      log = capture_log(fn -> Shadow.record([difference], 20, @now) end)

      assert log =~
               "Dispatch shadow difference: repo_key=web issue_id=a issue_identifier=MT-1 side=poll field=candidate poll=\"Todo\" record=nil"

      assert %{
               cycles_compared: 1,
               cycles_with_differences: 1,
               window_cycles: 1,
               window_differences: 1,
               recent: [%{identifier: "MT-1", side: :poll, field: :candidate, at: @now}]
             } = Shadow.summary()

      # The next cycle still has it: counted again in the window, not logged or listed again.
      refute capture_log(fn -> Shadow.record([difference], 20, DateTime.add(@now, 30)) end) =~ "Dispatch shadow difference"
      assert %{cycles_with_differences: 2, window_differences: 2, recent: [%{at: @now}]} = Shadow.summary()

      # It clears, then comes back: it appears and is logged again.
      Shadow.record([], 20, DateTime.add(@now, 60))
      assert capture_log(fn -> Shadow.record([difference], 20, DateTime.add(@now, 90)) end) =~ "issue_identifier=MT-1"
      assert %{cycles_compared: 4, cycles_with_differences: 3, recent: [%{at: back}, %{at: @now}]} = Shadow.summary()
      assert back == DateTime.add(@now, 90)
    end

    test "the window keeps the last cycles' differences, and a smaller window drops the older ones" do
      [difference] = Shadow.compare([issue("a", "MT-1")], [])

      capture_log(fn ->
        Shadow.record([difference], 3, @now)
        Shadow.record([difference], 3, @now)
        Shadow.record([], 3, @now)
      end)

      assert %{window_cycles: 3, window_differences: 2} = Shadow.summary()

      Shadow.record([], 3, @now)

      assert %{cycles_compared: 4, cycles_with_differences: 2, window_cycles: 3, window_differences: 1} =
               Shadow.summary()

      Shadow.record([], 1, @now)
      assert %{cycles_compared: 5, window_cycles: 1, window_differences: 0} = Shadow.summary()
    end

    test "keeps the last ten differences that appeared, newest first" do
      differences = for n <- 1..12, do: hd(Shadow.compare([issue("id-#{n}", "MT-#{n}")], []))

      capture_log(fn -> for difference <- differences, do: Shadow.record([difference], 20, @now) end)

      recent = Shadow.summary().recent
      assert Enum.map(recent, & &1.identifier) == for(n <- 12..3//-1, do: "MT-#{n}")
    end

    test "a record_newer is counted once while it lasts, apart from the differences, with the last five identifiers" do
      [newer] = Shadow.compare([issue("a", "MT-1", state: "Rework")], [issue("a", "MT-1", state: "Code Review")])
      cycle = %{differences: [], record_newer: [newer]}

      refute capture_log(fn -> Shadow.record(cycle, 20, @now) end) =~ "Dispatch shadow difference"
      Shadow.record(cycle, 20, @now)

      record_newer = %{count: 1, recent: [%{identifier: "MT-1", side: :both}]}
      assert Shadow.summary() == %{@empty | cycles_compared: 2, window_cycles: 2, record_newer: record_newer}

      # Its repo's next poll reads the move and it clears; a later move of the same ticket counts again.
      Shadow.record([], 20, @now)
      Shadow.record(cycle, 20, @now)
      assert %{record_newer: %{count: 2, recent: [%{identifier: "MT-1"}, %{identifier: "MT-1"}]}} = Shadow.summary()

      # A close that landed between the read and the comparison names its side.
      [closed] = Shadow.compare([issue("b", "MT-2", state: "Merging")], [])
      Shadow.record(%{differences: [], record_newer: [closed]}, 20, @now)
      assert %{record_newer: %{count: 3, recent: [%{identifier: "MT-2", side: :poll} | _older]}} = Shadow.summary()

      for n <- 3..7, do: Shadow.record(%{differences: [], record_newer: [%{newer | issue_id: "id-#{n}", identifier: "MT-#{n}"}]}, 20, @now)
      %{record_newer: %{count: 8, recent: recent}, window_differences: 0} = Shadow.summary()
      assert Enum.map(recent, & &1.identifier) == ["MT-7", "MT-6", "MT-5", "MT-4", "MT-3"]
    end

    test "without its table, recording does nothing and the report is empty" do
      pid = Process.whereis(Shadow)
      ref = Process.monitor(pid)
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Shadow)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, Shadow) end)

      assert Shadow.record([], 20, @now) == :ok
      assert Shadow.reset() == :ok
      assert Shadow.summary() == @empty
    end
  end
end
