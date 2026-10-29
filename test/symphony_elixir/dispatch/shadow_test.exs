defmodule SymphonyElixir.Dispatch.ShadowTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Dispatch.Shadow

  @now ~U[2026-10-29 17:00:00Z]
  @empty %{cycles_compared: 0, cycles_with_differences: 0, window_cycles: 0, window_differences: 0, recent: []}

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

    test "matches tickets by id, so a renamed identifier is the same ticket" do
      assert Shadow.compare([issue("a", "MT-1")], [issue("a", "MT-9")]) == []
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
