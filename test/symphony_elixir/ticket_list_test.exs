defmodule SymphonyElixir.TicketListTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Situation, TicketColumns, TicketList, Views}

  @epic %{identifier: "EP-1", title: "The epic"}
  @waiting ~w(waiting_on_you waiting_for_ci waiting_for_build waiting_for_slot)

  # Each ticket with the situation kind its phase and the live facts below give it: the fixture a
  # selection is checked against by hand.
  @fixture [
    {%{
       issue_id: "ep-1",
       issue_identifier: "EP-1",
       phase: "Waiting on sub-tickets",
       priority: 2,
       sub_issues: [%{id: "ep-2", identifier: "EP-2", state: "Todo"}]
     }, "blocked_by_ticket"},
    {%{issue_id: "ep-2", issue_identifier: "EP-2", phase: "Todo", priority: 2, parent: @epic, labels: ["Bug"]}, "waiting_for_slot"},
    {%{issue_id: "ep-3", issue_identifier: "EP-3", phase: "Plan Review", priority: 1, parent: @epic}, "waiting_on_you"},
    {%{issue_id: "ep-4", issue_identifier: "EP-4", phase: "Backlog", priority: 1, parent: @epic}, "paused_by_rule"},
    {%{issue_id: "ep-5", issue_identifier: "EP-5", phase: "Done", priority: 1, parent: @epic}, "done"},
    {%{issue_id: "ep-10", issue_identifier: "EP-10", phase: "Todo", priority: 3, parent: @epic, labels: ["feature", "bug"]}, "waiting_for_slot"},
    {%{issue_id: "ep-11", issue_identifier: "EP-11", phase: "Todo", parent: @epic}, "waiting_for_slot"},
    {%{issue_id: "other-1", issue_identifier: "OT-1", phase: "Todo", priority: 1, parent: %{identifier: "OT-0"}}, "waiting_for_slot"},
    {%{issue_id: "gone", issue_identifier: "EP-6", phase: "Todo", priority: 1, parent: @epic, removed_at: ~U[2026-11-09 00:00:00Z]}, "waiting_for_slot"},
    {%{issue_id: "lost", issue_identifier: "EP-7", phase: "Todo", priority: 1, parent: @epic, not_found_at: ~U[2026-11-09 00:00:00Z]}, "waiting_for_slot"},
    {%{issue_id: "no-identifier", phase: "Todo", priority: 1, parent: @epic}, "waiting_for_slot"}
  ]

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_terminal_states: ["Done", "Canceled"])
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp records, do: Enum.map(@fixture, fn {record, _kind} -> Map.put(record, :repo_key, "symphony") end)

  defp live do
    Situation.live_facts(%{slot_waiting: [%{issue_id: "ep-10", since: ~U[2026-11-10 03:00:00Z], reason: "No slot is free"}]})
  end

  defp spec!(params) do
    {:ok, spec} = Views.spec(params)
    spec
  end

  defp select(params, records \\ nil), do: TicketList.select(spec!(params), records: records || records(), live: live())

  defp identifiers(rows), do: Enum.map(rows, & &1["identifier"])

  test "a view of an epic's waiting tickets selects what a hand filter of the fixture does, in the sort asked" do
    expected =
      @fixture
      |> Enum.filter(fn {record, kind} ->
        listed? =
          is_map_key(record, :issue_identifier) and not is_map_key(record, :removed_at) and
            not is_map_key(record, :not_found_at)

        in_epic? = Map.get(record, :issue_identifier) == "EP-1" or match?(%{parent: %{identifier: "EP-1"}}, record)
        listed? and in_epic? and kind in @waiting
      end)
      |> Enum.sort_by(fn {record, _kind} -> Map.get(record, :priority) || 99 end)
      |> Enum.map(fn {record, kind} -> %{"issue_id" => record.issue_id, "identifier" => record.issue_identifier, "situation" => kind} end)

    rows =
      select(%{
        "filters" => [%{"column" => "epic", "value" => "EP-1"}, %{"column" => "situation", "value" => @waiting}],
        "columns" => ["identifier", "situation"],
        "sort" => %{"column" => "priority", "direction" => "asc"}
      })

    assert rows == expected
    assert identifiers(rows) == ["EP-3", "EP-2", "EP-10", "EP-11"]
  end

  test "sorts descending with the tickets without a value last, ties by identifier" do
    rows = select(%{"columns" => ["identifier", "priority"], "sort" => %{"column" => "priority", "direction" => "desc"}})
    assert identifiers(rows) == ["EP-10", "EP-1", "EP-2", "EP-3", "EP-4", "EP-5", "OT-1", "EP-11"]
    refute Enum.any?(rows, &Map.has_key?(&1, "situation"))
  end

  test "sorts by identifier number, labels, text and times" do
    assert select(%{"columns" => ["identifier"]}) |> identifiers() == ["EP-1", "EP-2", "EP-3", "EP-4", "EP-5", "EP-10", "EP-11", "OT-1"]

    assert select(%{"columns" => ["identifier", "labels"], "sort" => %{"column" => "labels"}}) |> Enum.take(2) == [
             %{"issue_id" => "ep-2", "identifier" => "EP-2", "labels" => ["Bug"]},
             %{"issue_id" => "ep-10", "identifier" => "EP-10", "labels" => ["feature", "bug"]}
           ]

    timed = [
      %{issue_id: "a", issue_identifier: "ROADMAP", phase: "Todo", updated_at: ~U[2026-11-10 02:00:00Z]},
      %{issue_id: "b", issue_identifier: "EP-1", phase: "Todo", updated_at: ~U[2026-11-10 01:00:00Z]},
      %{issue_id: "c", issue_identifier: "EP-2", phase: nil}
    ]

    assert select(%{"columns" => ["identifier", "updated_at"], "sort" => %{"column" => "updated_at", "direction" => "desc"}}, timed) == [
             %{"issue_id" => "a", "identifier" => "ROADMAP", "updated_at" => "2026-11-10T02:00:00Z"},
             %{"issue_id" => "b", "identifier" => "EP-1", "updated_at" => "2026-11-10T01:00:00Z"},
             %{"issue_id" => "c", "identifier" => "EP-2", "updated_at" => nil}
           ]

    assert select(%{"columns" => ["identifier"], "sort" => %{"column" => "identifier", "direction" => "desc"}}, timed) |> identifiers() == ["ROADMAP", "EP-2", "EP-1"]

    assert select(%{"columns" => ["identifier"], "sort" => %{"column" => "phase"}}, timed) |> identifiers() == ["EP-1", "ROADMAP", "EP-2"]

    assert select(%{"columns" => ["identifier"], "filters" => [%{"column" => "since", "value" => "2026-11-10T01:30:00Z"}]}, timed) |> identifiers() == ["ROADMAP"]
    assert select(%{"columns" => ["identifier"], "filters" => [%{"column" => "phase", "value" => "todo"}]}, timed) |> identifiers() == ["EP-1", "ROADMAP"]
  end

  test "filters by repo, phase, label and priority, in any case where a value is text" do
    assert select(%{"columns" => ["identifier"], "filters" => [%{"column" => "label", "value" => "BUG"}]}) |> identifiers() == ["EP-2", "EP-10"]
    assert select(%{"columns" => ["identifier"], "filters" => [%{"column" => "priority", "value" => [2, 3]}]}) |> identifiers() == ["EP-1", "EP-2", "EP-10"]
    assert select(%{"columns" => ["identifier"], "filters" => [%{"column" => "phase", "value" => ["plan review", "Backlog"]}]}) |> identifiers() == ["EP-3", "EP-4"]
    assert select(%{"columns" => ["identifier"], "filters" => [%{"column" => "repo", "value" => "elsewhere"}]}) == []
    assert select(%{"columns" => ["identifier"], "filters" => [%{"column" => "epic", "value" => "OT-0"}]}) |> identifiers() == ["OT-1"]
  end

  test "every column of a ticket, read from its record and its situation" do
    record = %{
      repo_key: "symphony",
      issue_id: "full",
      issue_identifier: "TP-1410",
      title: "Saved views",
      phase: "Plan Review",
      parent: %{identifier: "TP-1400", title: "Epic 6"},
      labels: ["blocked"],
      priority: 1,
      assignee: "Tony",
      url: "https://linear.app/t/TP-1410",
      created_at: ~U[2026-11-04 23:00:00Z],
      phase_at: ~U[2026-11-10 03:00:00Z],
      updated_at: ~U[2026-11-10 03:30:00Z]
    }

    [row] = TicketList.select(spec!(%{"columns" => TicketColumns.names()}), records: [record])

    assert row == %{
             "issue_id" => "full",
             "identifier" => "TP-1410",
             "title" => "Saved views",
             "repo" => "symphony",
             "epic" => "TP-1400",
             "phase" => "Plan Review",
             "situation" => "waiting_on_you",
             "situation_since" => row["situation_since"],
             "labels" => ["blocked"],
             "priority" => 1,
             "assignee" => "Tony",
             "url" => "https://linear.app/t/TP-1410",
             "created_at" => "2026-11-04T23:00:00Z",
             "phase_at" => "2026-11-10T03:00:00Z",
             "updated_at" => "2026-11-10T03:30:00Z"
           }
  end

  test "reads the store's records when none are given" do
    :ok = RunStore.put_ticket_state(%{repo_key: "symphony", issue_id: "stored", issue_identifier: "ST-1", phase: "Todo"})
    assert [%{"identifier" => "ST-1", "situation" => "waiting_for_slot"}] = TicketList.select(spec!(%{}))
  end
end
