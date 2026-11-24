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

  describe "the blockers" do
    test "are the stored dependencies: one on a done ticket reads resolved, with when it got there" do
      ticket("MT-2", "Todo")
      ticket("MT-3", "Done", %{title: "The blocker", phase_at: @at})
      :ok = RunStore.add_dependency("MT-2", "MT-3", :done)

      assert read("MT-2").blocked_by == [%{identifier: "MT-3", title: "The blocker", state: "Done", status: "resolved", resolved_at: "2026-11-05T15:22:30Z"}]
    end

    test "one still unmet reads open, of either kind, and a released one on a done ticket reads resolved" do
      ticket("MT-2", "Code Review")
      ticket("MT-3", "Todo")
      ticket("MT-4", "In Progress")
      ticket("MT-5", "Done")
      :ok = RunStore.add_dependency("MT-2", "MT-3", :done)
      :ok = RunStore.add_dependency("MT-2", "MT-4", :released)
      :ok = RunStore.add_dependency("MT-2", "MT-5", :released)

      assert [
               %{identifier: "MT-3", state: "Todo", status: "open", resolved_at: nil},
               %{identifier: "MT-4", state: "In Progress", status: "open", resolved_at: nil},
               %{identifier: "MT-5", state: "Done", status: "resolved"}
             ] = read("MT-2").blocked_by
    end

    test "a dependency removed leaves the list, and one on a ticket Symphony knows no name of is not listed" do
      ticket("MT-2", "Todo")
      ticket("MT-3", "In Progress")
      :ok = RunStore.add_dependency("MT-2", "MT-3", :done)
      :ok = RunStore.add_dependency("MT-2", "ghost", :done)
      assert [%{identifier: "MT-3", status: "open"}] = read("MT-2").blocked_by

      :ok = RunStore.remove_dependency("MT-2", "MT-3")
      assert read("MT-2").blocked_by == []
    end

    test "a Linear blocker link, a pause reason and what the run tracked are no blocker" do
      ticket("MT-2", "Todo", %{blockers: [%{id: "a", identifier: "MT-3", state: "Todo"}]})
      wait_on("MT-2", "MT-7")
      wait_on("MT-2", "MT-8", :fix_ticket)
      wait_on("MT-2", "MT-9", :landing)
      {:ok, _event} = TicketEvents.record(@repo, "MT-2", "note", %{text: "Nothing to do with a pause"})

      tracked = %{Connected.build(%{}, nil) | blocked_by: [%{identifier: "MT-4", title: "Polled", state: "Todo"}]}

      assert read("MT-2", tracked).blocked_by == []
    end
  end

  describe "the epic" do
    defp initiative do
      records =
        for {identifier, phase, created} <- [{"MT-3", "Todo", ~U[2026-11-01 10:00:03Z]}, {"MT-2", "Done", ~U[2026-11-01 10:00:02Z]}] do
          TicketState.normalize(%{
            repo_key: @repo,
            issue_id: identifier,
            issue_identifier: identifier,
            title: "Part " <> identifier,
            phase: phase,
            created_at: created
          })
        end

      parent = TicketState.normalize(%{repo_key: @repo, issue_id: "MT-1", issue_identifier: "MT-1", title: "The plan", phase: "In Progress"})
      Initiative.from_record(parent, %{records: records, links: []}, %{settings: %Schema{}, now: @at, started_at: nil})
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

    test "a parent only the orchestrator holds gives the epic too, from its record when it has one" do
      ticket("MT-1", "Waiting on sub-tickets", %{sub_issues: [%{id: "MT-3", identifier: "MT-3", state: "Todo"}, %{id: "MT-4", identifier: "MT-4", state: "Done"}]})
      ticket("MT-3", "Todo")
      ticket("MT-9", "Todo")

      known = %{Connected.build(%{}, nil) | parent: %{identifier: "MT-1", title: "The plan", done: 0, total: 9, children: []}}
      unknown = %{Connected.build(%{}, nil) | parent: %{identifier: "MT-8", title: "Not recorded", done: 1, total: 3, children: ["completed"]}}

      assert %{parent: %{identifier: "MT-1"}, epic: recorded} = read("MT-3", known)
      assert %{identifier: "MT-1", done: 1, total: 2, tickets: tickets} = recorded
      assert %{identifier: "MT-3", current: true} = Enum.find(tickets, & &1.current)

      assert %{parent: %{identifier: "MT-8"}, epic: own} = read("MT-9", unknown)
      assert %{identifier: "MT-8", done: 1, total: 3, incomplete: false, tickets: []} = own
    end
  end

  describe "the tickets it holds up" do
    test "the links the run read and the records that depend on it, once, each with its situation" do
      ticket("MT-2", "In Progress")
      ticket("MT-3", "Todo", %{title: "Waits"})
      ticket("MT-4", "Todo", %{title: "Linked too"})
      ticket("MT-5", "Done")
      # A blocker link of Linear's an older build kept in the record holds nothing up.
      ticket("MT-6", "Todo", %{blockers: [%{id: "MT-2", identifier: "MT-2", state: "In Progress"}]})
      ticket("MT-8", "Done", %{title: "Ended since the run read it"})
      for id <- ["MT-3", "MT-4", "MT-5"], do: :ok = RunStore.add_dependency(id, "MT-2", :done)
      wait_on("MT-3", "MT-2")

      links = [
        %{identifier: "MT-4", title: nil, state: nil},
        %{identifier: "MT-7", title: "Unknown", state: "Todo"},
        %{identifier: "MT-8", title: nil, state: "Todo"},
        %{identifier: "MT-9", title: "No record, ended", state: "Done"}
      ]

      tracked = %{Connected.build(%{}, nil) | blocks: links}

      assert read("MT-2", tracked).blocks == [
               %{identifier: "MT-4", title: "Linked too", state: "Todo", situation: "waiting_for_slot"},
               %{identifier: "MT-7", title: "Unknown", state: "Todo", situation: nil},
               %{identifier: "MT-3", title: "Waits", state: "Todo", situation: "blocked_by_ticket"}
             ]

      # Once the ticket is done, the dependency on it is met: it holds nothing up.
      :ok = RunStore.update_ticket_state("MT-2", %{phase: "Done"})
      assert read("MT-2").blocks == []
    end

    test "a ticket nothing depends on holds nothing up, and neither does one with no id" do
      ticket("MT-3", "Todo")
      :ok = RunStore.add_dependency("MT-3", "other", :done)

      assert %{blocks: []} = Read.read(%{issue_id: "unnamed", repo_key: @repo}, nil, facts())
      assert %{blocks: []} = Read.read(%{issue_id: nil, repo_key: @repo}, nil, facts())
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

  test "facts takes the plans the Initiatives read over the same records by default" do
    ticket("MT-2", "Todo")
    ticket("MT-1", "Waiting on sub-tickets", %{title: "The plan", sub_issues: [%{id: "MT-2", identifier: "MT-2", state: "Todo"}]})
    {:ok, _event} = TicketEvents.record(@repo, "MT-1", "ticket.filed", %{identifier: "MT-2", kind: "split_off"})

    assert %{initiatives: [%{identifier: "MT-1"}]} = Read.facts(RunStore.list_all_ticket_states(), Situation.live_facts(%{running: [], retrying: []}))
    assert %{records: [], initiatives: []} = Read.facts([], Situation.live_facts(%{running: [], retrying: []}))
  end
end
