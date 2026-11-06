defmodule SymphonyElixir.Connected.ReadTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Connected
  alias SymphonyElixir.Connected.Read
  alias SymphonyElixir.Initiatives.Initiative
  alias SymphonyElixir.Pauses
  alias SymphonyElixir.Situation
  alias SymphonyElixir.TicketEvents
  alias SymphonyElixir.TicketState

  @repo "default"
  @at ~U[2026-11-05 15:22:30Z]

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    write_workflow_file!(Workflow.workflow_file_path())
    :ok
  end

  defp ticket(id, phase, fields \\ %{}) do
    :ok = RunStore.put_ticket_state(Map.merge(%{repo_key: @repo, issue_id: id, issue_identifier: id, phase: phase}, fields))
  end

  defp record(id), do: id |> RunStore.get_ticket_state() |> TicketState.normalize()

  defp facts(initiatives \\ []) do
    records = RunStore.list_all_ticket_states()
    Read.facts(records, Situation.live_facts(%{running: [], retrying: []}), initiatives)
  end

  defp read(id, tracked \\ nil, initiatives \\ []), do: Read.read(record(id), tracked, facts(initiatives))

  defp wait_on(id, blocker, source \\ :dependency), do: {:ok, _pause} = Pauses.set({:ticket, @repo, id}, Pauses.ticket_reason(source, blocker), at: DateTime.add(@at, -3_600))
  defp clear(id, blocker), do: {:ok, _pause} = Pauses.clear_reason({:ticket, @repo, id}, %{kind: :ticket, waits_on: %{identifier: blocker}}, at: @at)

  describe "the blockers" do
    test "the last reason to clear resolves its blocker, from pause.cleared" do
      ticket("MT-2", "Todo")
      ticket("MT-3", "Done", %{title: "The blocker"})
      wait_on("MT-2", "MT-3")
      clear("MT-2", "MT-3")

      assert read("MT-2").blocked_by == [%{identifier: "MT-3", title: "The blocker", state: "Done", status: "resolved", resolved_at: "2026-11-05T15:22:30Z"}]
    end

    test "a blocker Symphony has no record of reads resolved once its reason cleared" do
      ticket("MT-2", "Todo")
      wait_on("MT-2", "MT-3")
      clear("MT-2", "MT-3")

      assert [%{identifier: "MT-3", title: nil, state: nil, status: "resolved", resolved_at: "2026-11-05T15:22:30Z"}] = read("MT-2").blocked_by
    end

    test "a reason still set reads open even once its blocker landed" do
      ticket("MT-2", "Rework")
      ticket("MT-3", "Done")
      wait_on("MT-2", "MT-3")

      assert [%{identifier: "MT-3", state: "Done", status: "open", resolved_at: nil}] = read("MT-2").blocked_by
    end

    test "a blocker linked again after it resolved reads open" do
      ticket("MT-2", "Todo")
      wait_on("MT-2", "MT-3")
      clear("MT-2", "MT-3")
      {:ok, _pause} = Pauses.set({:ticket, @repo, "MT-2"}, Pauses.ticket_reason(:dependency, "MT-3"), at: DateTime.add(@at, 60))

      assert [%{identifier: "MT-3", status: "open", resolved_at: nil}] = read("MT-2").blocked_by
    end

    test "a blocker unlinked while it is still open leaves the list" do
      ticket("MT-2", "Todo")
      ticket("MT-3", "In Progress")
      wait_on("MT-2", "MT-3")
      clear("MT-2", "MT-3")

      assert read("MT-2").blocked_by == []
    end

    test "a link with no reason is open until its blocker ends, then resolved with no time" do
      ticket("MT-2", "Code Review", %{blockers: [%{id: "a", identifier: "MT-3", state: "Todo"}, %{id: "b", identifier: "MT-4", state: "Done"}]})

      assert [
               %{identifier: "MT-3", state: "Todo", status: "open", resolved_at: nil},
               %{identifier: "MT-4", state: "Done", status: "resolved", resolved_at: nil}
             ] = read("MT-2").blocked_by
    end

    test "a tracked ticket's links count, once, and a fix ticket or a competing pull request is no blocker" do
      ticket("MT-2", "Todo", %{blockers: [%{id: "a", identifier: "MT-3", state: "Todo"}]})
      wait_on("MT-2", "MT-8", :fix_ticket)
      wait_on("MT-2", "MT-9", :landing)
      {:ok, _event} = TicketEvents.record(@repo, "MT-2", "note", %{text: "Nothing to do with a pause"})

      tracked = %{Connected.build(%{}, nil) | blocked_by: [%{identifier: "MT-3", title: "Polled", state: "Todo"}, %{identifier: "MT-4", title: nil, state: nil}]}

      assert [
               %{identifier: "MT-3", title: "Polled", status: "open"},
               %{identifier: "MT-4", state: nil, status: "open"}
             ] = read("MT-2", tracked).blocked_by
    end
  end

  describe "the epic" do
    defp initiative do
      children =
        for {identifier, name, type, created} <- [
              {"MT-3", "Todo", "unstarted", "2026-11-01T10:00:03Z"},
              {"MT-2", "Done", "completed", "2026-11-01T10:00:02Z"},
              {"MT-4", "Canceled", "canceled", "2026-11-01T10:00:04Z"}
            ] do
          %{
            "id" => identifier,
            "identifier" => identifier,
            "title" => "Part " <> identifier,
            "createdAt" => created,
            "state" => %{"name" => name, "type" => type},
            "inverseRelations" => %{"nodes" => []}
          }
        end

      node = %{"id" => "MT-1", "identifier" => "MT-1", "title" => "The plan", "state" => %{"name" => "In Progress", "type" => "started"}, "children" => %{"nodes" => children}}
      Initiative.from_node(node, @repo, %Schema{}, @at)
    end

    test "the Initiatives' plan answers: its chain, with the same count as the page" do
      ticket("MT-3", "Todo")
      plan = initiative()

      epic = read("MT-3", nil, [plan]).epic
      assert %{identifier: "MT-1", title: "The plan", done: 1, total: 2, incomplete: false, tickets: tickets} = epic

      assert tickets == [
               %{identifier: "MT-2", title: "Part MT-2", state: "Done", current: false, situation: nil},
               %{identifier: "MT-3", title: "Part MT-3", state: "Todo", current: true, situation: "waiting_for_slot"}
             ]

      %{counts: counts} = Initiative.live(plan, %{running: MapSet.new(), you: MapSet.new(), settings: %Schema{}})
      assert {counts["done"], counts["total"]} == {1, 2}
    end

    test "a plan the Initiatives don't hold comes from the parent's record, in creation order, without what was canceled" do
      parent = %{identifier: "MT-1", title: "The plan", done: 0, total: 9, children: []}

      states = [{"MT-5", "Todo"}, {"MT-2", "Done"}, {"MT-3", "Todo"}, {"MT-4", "Canceled"}]
      sub_issues = for {identifier, state} <- states, do: %{id: identifier, identifier: identifier, state: state}

      ticket("MT-1", "Waiting on sub-tickets", %{sub_issues: sub_issues})
      ticket("MT-2", "Done", %{parent: parent, created_at: ~U[2026-11-01 10:00:00Z]})
      ticket("MT-3", "In Progress", %{parent: parent, created_at: ~U[2026-11-02 10:00:00Z]})

      assert %{identifier: "MT-1", title: "The plan", done: 1, total: 3, incomplete: false, tickets: tickets} = read("MT-3").epic

      assert [
               %{identifier: "MT-5", state: "Todo", current: false, situation: nil},
               %{identifier: "MT-2", state: "Done", current: false, situation: "done"},
               %{identifier: "MT-3", state: "In Progress", current: true}
             ] = tickets
    end

    test "with no record of the parent, its own count and no chain; with no parent, no epic" do
      parent = %{identifier: "MT-1", title: "The plan", done: 2, total: 5, children: ["completed"]}
      ticket("MT-2", "Todo", %{parent: parent})
      ticket("MT-3", "Todo")

      assert %{parent: %{identifier: "MT-1"}, epic: epic} = read("MT-2")
      assert %{identifier: "MT-1", title: "The plan", done: 2, total: 5, incomplete: false, tickets: []} = epic
      assert %{parent: nil, epic: nil} = read("MT-3")
    end
  end

  describe "the tickets it holds up" do
    test "the links the run read and the records that wait on it, once, each with its situation" do
      ticket("MT-2", "In Progress")
      ticket("MT-3", "Todo", %{title: "Waits", blockers: [%{id: "MT-2", identifier: "MT-2", state: "In Progress"}]})
      ticket("MT-4", "Todo", %{title: "Linked too", blockers: [%{id: "MT-2", identifier: "MT-2", state: "In Progress"}]})
      ticket("MT-5", "Done", %{blockers: [%{id: "MT-2", identifier: "MT-2", state: "In Progress"}]})
      ticket("MT-6", "Todo", %{blockers: [%{id: "MT-2", identifier: "MT-2", state: "Done"}]})
      wait_on("MT-3", "MT-2")

      tracked = %{Connected.build(%{}, nil) | blocks: [%{identifier: "MT-4", title: nil, state: nil}, %{identifier: "MT-7", title: "Unknown", state: "Todo"}]}

      assert read("MT-2", tracked).blocks == [
               %{identifier: "MT-4", title: "Linked too", state: "Todo", situation: "waiting_for_slot"},
               %{identifier: "MT-7", title: "Unknown", state: "Todo", situation: nil},
               %{identifier: "MT-3", title: "Waits", state: "Todo", situation: "blocked_by_ticket"}
             ]
    end

    test "a ticket with no identifier holds nothing up, and a link to no identifier matches nothing" do
      ticket("MT-3", "Todo", %{blockers: [%{id: "a", state: "Todo"}]})

      assert %{blocks: []} = Read.read(%{issue_id: "unnamed", repo_key: @repo}, nil, facts())
    end
  end

  test "read_all reads each ticket in order, sub-tickets and related from the tracked links with what the records know" do
    ticket("MT-2", "Todo", %{sub_issues: [%{id: "MT-3", identifier: "MT-3", state: "Backlog"}]})
    ticket("MT-3", "Todo", %{title: "Known"})

    tracked = %{Connected.build(%{}, nil) | related: [%{identifier: "MT-3", title: nil, state: "Backlog"}, %{identifier: "MT-9", title: "Not known", state: "Done"}]}

    assert [first, second] = Read.read_all([{record("MT-2"), nil}, {record("MT-3"), tracked}], facts())

    assert first.sub_tickets == [%{identifier: "MT-3", title: "Known", state: "Todo"}]
    assert second.related == [%{identifier: "MT-3", title: "Known", state: "Todo"}, %{identifier: "MT-9", title: "Not known", state: "Done"}]
  end

  test "facts takes the cached plans by default" do
    assert %{records: [], initiatives: initiatives} = Read.facts([], Situation.live_facts(%{running: [], retrying: []}))
    assert is_list(initiatives)
  end
end
