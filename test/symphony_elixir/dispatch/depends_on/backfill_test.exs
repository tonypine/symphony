defmodule SymphonyElixir.Dispatch.DependsOn.BackfillTest do
  # TP-1627: at the first start after dependencies are stored, the order Symphony itself recorded for
  # a split's open sub-tickets (the plan's `after`, a sub-ticket filed to do after its ticket) becomes
  # stored dependencies, read from Symphony's events and records only.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.DependsOn
  alias SymphonyElixir.Dispatch.DependsOn.Backfill
  alias SymphonyElixir.{TicketEvents, TicketPlan, TicketState}

  @repo "default"
  @terminal ["Done", "Canceled"]
  @build %{sha: nil, repo: nil}
  @cache %{blockers: %{}, included: %{}}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_terminal_states: @terminal)
    :ok = RunStore.clear()
    # Nothing is read from the tracker: a read of it would find no issue at all.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      RunStore.clear()
    end)

    :ok
  end

  # An epic with five sub-tickets: MT-1 done, MT-2 after MT-1, MT-3 after MT-1 and MT-2, MT-4 (done)
  # after MT-2, MT-6 (no record) after MT-1; MT-5 was filed from a run to do after the epic.
  defp epic! do
    subs =
      for {id, identifier} <- [a: "MT-1", b: "MT-2", c: "MT-3", d: "MT-4", e: "MT-5", g: "MT-6"] do
        %{id: Atom.to_string(id), identifier: identifier, state: "Todo"}
      end

    put!("p", "MT-0", "Waiting on sub-tickets", sub_issues: subs)
    put!("a", "MT-1", "Done")
    put!("b", "MT-2", "Todo")
    put!("c", "MT-3", "Backlog")
    put!("d", "MT-4", "Done")
    put!("e", "MT-5", "Todo")

    entries = [
      %{key: "s1", identifier: "MT-1", title: "One", ask: "One.", after: []},
      %{key: "s2", identifier: "MT-2", title: "Two", ask: "Two.", after: ["s1"]},
      %{key: "s3", identifier: "MT-3", title: "Three", ask: "Three.", after: ["s1", "s2"]},
      %{key: "s4", identifier: "MT-4", title: "Four", ask: "Four.", after: ["s2"]},
      %{key: "s6", identifier: "MT-6", title: "Six", ask: "Six.", after: ["s1"]}
    ]

    {:ok, _event} = TicketPlan.write(@repo, "p", plan(entries))
    {:ok, _event} = TicketEvents.record(@repo, "p", "ticket.filed", %{identifier: "MT-5", kind: "follow_up", by: "conductor", title: "After it"})
    # A follow-up that is no sub-ticket (a plain ticket's related one) depends on nothing.
    {:ok, _event} = TicketEvents.record(@repo, "p", "ticket.filed", %{identifier: "MT-77", kind: "follow_up", by: "conductor", title: "Related"})
    # A parent with sub-tickets and no plan gives none.
    put!("q", "MT-10", "Waiting on sub-tickets", sub_issues: [%{id: "b", identifier: "MT-2", state: "Todo"}])
    :ok
  end

  test "the after Symphony recorded for open sub-tickets becomes stored dependencies, once, with no read of the tracker" do
    epic!()

    assert Backfill.run(terminal_states: @terminal) == 4

    assert depends_on("b") == [{"a", "MT-1", :done}]
    assert depends_on("c") == [{"a", "MT-1", :done}, {"b", "MT-2", :done}]
    assert depends_on("e") == [{"p", "MT-0", :done}]
    # A done sub-ticket gets none.
    assert depends_on("d") == []

    # MT-2's sibling is done: met at once. MT-3 waits on MT-2.
    assert unmet("b") == []
    assert [%{issue_id: "b"}] = unmet("c")

    assert %DateTime{} = RunStore.get_marker(Backfill.marker())
    assert Backfill.run(terminal_states: @terminal) == 0
    assert depends_on("c") == [{"a", "MT-1", :done}, {"b", "MT-2", :done}]
  end

  test "a dependency the store refuses is logged and the others are stored" do
    epic!()
    :ok = RunStore.add_dependency("a", "b", :done)

    log = ExUnit.CaptureLog.capture_log(fn -> assert Backfill.run(terminal_states: @terminal, now: ~U[2026-11-23 12:00:00Z]) == 3 end)

    assert log =~ "Could not store the dependency of issue_id=b on issue_id=a: :dependency_cycle"
    assert depends_on("b") == []
    assert RunStore.get_marker(Backfill.marker()) == ~U[2026-11-23 12:00:00Z]
  end

  test "runs with the settings' terminal states by default" do
    epic!()
    assert Backfill.run() == 4
  end

  defp put!(id, identifier, phase, attrs \\ []) do
    :ok = RunStore.put_ticket_state(TicketState.new(@repo, id, Map.merge(%{issue_identifier: identifier, phase: phase}, Map.new(attrs))))
  end

  defp depends_on(id) do
    id |> RunStore.get_ticket_state() |> TicketState.normalize() |> Map.fetch!(:depends_on) |> Enum.map(&{&1.issue_id, &1.identifier, &1.kind})
  end

  defp unmet(id) do
    dependencies = RunStore.dependencies(id)
    records = for {entry, %{} = record} <- dependencies, into: %{}, do: {entry.issue_id, record}
    DependsOn.unmet(Enum.map(dependencies, &elem(&1, 0)), records, @build, @cache)
  end

  defp plan(sub_tickets) do
    %{
      shape: "split",
      layers: ["api"],
      summary: "Five parts.",
      text: "Approach: in order.",
      checks: [%{id: "c1", kind: "outcome", statement: "It works.", proof: "test"}],
      size: %{tokens: 1, runs: 2},
      sub_tickets: sub_tickets,
      reason: "Sub-tickets created",
      by: "grooming"
    }
  end
end
