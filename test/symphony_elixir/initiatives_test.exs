defmodule SymphonyElixir.InitiativesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Initiatives
  alias SymphonyElixir.Initiatives.Initiative
  alias SymphonyElixir.TicketEvents.Event
  alias SymphonyElixir.TicketState

  @now ~U[2026-10-12 12:00:00Z]

  defp settings, do: %Schema{}

  # A ticket record, as the run store holds it.
  defp record(identifier, phase, attrs \\ %{}) do
    TicketState.new(
      "billing",
      "id-" <> identifier,
      Map.merge(
        %{
          issue_identifier: identifier,
          title: "Title of " <> identifier,
          url: "https://linear.app/acme/issue/" <> identifier,
          created_at: ~U[2026-10-01 10:00:00Z],
          phase: phase
        },
        attrs
      )
    )
  end

  defp link(identifier, state), do: %{id: "id-" <> identifier, identifier: identifier, state: state}

  defp context(settings \\ settings(), started_at \\ nil), do: %{settings: settings, now: @now, started_at: started_at}

  # The initiative of the parent `identifier` in `phase` over the sub-ticket `records` and `links`.
  defp initiative(identifier, phase, records, links \\ [], attrs \\ %{}, settings \\ settings()) do
    Initiative.from_record(record(identifier, phase, Map.merge(%{title: "Plan " <> identifier}, attrs)), %{records: records, links: links}, context(settings))
  end

  # The stored dependencies `live/2` reads (`:dependencies`): by sub-ticket id, each `{identifier, phase}`
  # it depends on (`:done`), with a record in that phase (none for a nil phase).
  defp stored(by_id) do
    fn id -> for {identifier, phase} <- Map.get(by_id, id, []), do: stored_entry(identifier, phase) end
  end

  defp stored_entry(identifier, phase) do
    record = if phase, do: %{issue_id: "id-" <> identifier, issue_identifier: identifier, phase: phase, phase_at: ~U[2026-10-06 09:00:00Z]}
    {%{issue_id: "id-" <> identifier, identifier: nil, kind: :done}, record}
  end

  defp live(initiative, settings, dependencies, opts \\ []) do
    Initiative.live(initiative, %{
      running: MapSet.new(Keyword.get(opts, :running, [])),
      you: MapSet.new(Keyword.get(opts, :you, [])),
      settings: settings,
      dependencies: stored(dependencies)
    })
  end

  describe "from_record/3" do
    test "groups a split parent as active, in review or done recently, and skips the rest" do
      review = %Schema{tracker: %{kind: "memory", plan_review_state: "Plan Review"}}

      assert %{group: "active"} = initiative("BIL-1", "Waiting on sub-tickets", [])
      assert %{group: "in_review"} = initiative("BIL-2", "Plan Review", [], [], %{}, review)
      assert %{group: "in_review"} = initiative("BIL-3", "Epic Review", [])
      assert %{group: "done", completed_at: "2026-10-08T00:00:00Z"} = initiative("BIL-4", "Done", [], [], %{phase_at: ~U[2026-10-08 00:00:00Z]})

      assert initiative("BIL-5", "Done", [], [], %{phase_at: ~U[2026-09-01 00:00:00Z]}) == nil
      assert initiative("BIL-7", "Done", []) == nil
      assert initiative("BIL-8", "Canceled", []) == nil
      assert initiative("BIL-9", "Backlog", []) == nil
      assert initiative("BIL-10", "Triage", []) == nil
      assert Initiative.from_record(%{issue_identifier: "BIL-11"}, %{records: [], links: []}, context()) == nil
      assert %{group: "active", state: nil, completed_at: nil} = initiative("BIL-12", nil, [])

      # The repo's own terminal states say what is done.
      shipped = %Schema{tracker: %{terminal_states: ["Shipped"]}}
      assert %{group: "done"} = initiative("BIL-13", "Shipped", [], [], %{phase_at: ~U[2026-10-08 00:00:00Z]}, shipped)
      assert %{group: "active"} = initiative("BIL-14", "Done", [], [], %{phase_at: ~U[2026-10-08 00:00:00Z]}, shipped)
    end

    test "keeps when Symphony split the parent and when each sub-ticket landed, from the records" do
      records = [record("BIL-2", "Done", %{phase_at: ~U[2026-10-06 09:00:00Z]}), record("BIL-3", "Todo")]
      parent = record("BIL-1", "In Progress", %{title: "Plan BIL-1"})

      assert %{started_at: "2026-10-02T08:00:00Z", completed_at: nil, repo_key: "billing", incomplete: false, sub_tickets: sub_tickets} =
               Initiative.from_record(parent, %{records: records, links: []}, context(settings(), ~U[2026-10-02 08:00:00.123Z]))

      assert Enum.map(sub_tickets, &{&1.identifier, &1.state_type, &1.created_at, &1.completed_at}) == [
               {"BIL-2", "completed", "2026-10-01T10:00:00Z", "2026-10-06T09:00:00Z"},
               {"BIL-3", "started", "2026-10-01T10:00:00Z", nil}
             ]
    end

    test "orders the sub-tickets by creation, the records' and the links' Symphony holds no record of" do
      records = [
        record("BIL-4", "Todo", %{created_at: ~U[2026-10-01 09:00:00Z]}),
        record("BIL-3", "Todo", %{created_at: ~U[2026-10-02 09:00:00Z]}),
        record("BIL-2", "Done", %{created_at: ~U[2026-10-03 09:00:00Z]})
      ]

      initiative = initiative("BIL-1", "In Progress", records, [link("BIL-5", "Backlog")])

      assert Enum.map(initiative.sub_tickets, &{&1.identifier, &1.state_type}) ==
               [{"BIL-5", "backlog"}, {"BIL-4", "started"}, {"BIL-3", "started"}, {"BIL-2", "completed"}]

      assert %{title: nil, url: nil, created_at: nil, completed_at: nil} = hd(initiative.sub_tickets)
      assert Enum.all?(initiative.sub_tickets, &(&1.blocked_by == []))
    end
  end

  describe "read/1" do
    # Each ticket's split events, by issue id.
    defp events(by_id), do: fn issue_id -> Map.get(by_id, issue_id, []) end

    defp filed(identifier, at \\ ~U[2026-10-02 08:00:00Z], kind \\ :split_off) do
      %Event{type: "ticket.filed", at: at, payload: %{identifier: identifier, kind: Atom.to_string(kind)}}
    end

    defp split_plan(at), do: %Event{type: "plan.written", at: at, payload: %{version: 1, shape: "split"}}

    defp read(records, by_id, opts \\ []) do
      Initiatives.read(Keyword.merge([records: records, events: events(by_id), settings: fn "billing" -> settings() end, now: @now], opts))
    end

    test "lists a parent Symphony split that carries no plan label, and not one that only carries the label (c1, c2)" do
      records = [
        # Split by Symphony, no label: its sub-tickets name it, or it lists them.
        record("BIL-1", "Waiting on sub-tickets", %{labels: [], sub_issues: [link("BIL-2", "Todo")]}),
        record("BIL-2", "Todo"),
        # Split by its plan, the sub-ticket naming its parent on its own record.
        record("BIL-5", "Waiting on sub-tickets"),
        record("BIL-6", "In Progress", %{parent: %{identifier: "BIL-5", title: "Plan BIL-5"}}),
        # The label, sub-tickets, and no split on its record: not listed.
        record("BIL-3", "Waiting on sub-tickets", %{labels: ["plan"], sub_issues: [link("BIL-4", "Todo")]}),
        record("BIL-7", "Waiting on sub-tickets", %{labels: ["breakdown"], sub_issues: [link("BIL-8", "Todo")]}),
        # Split, but no sub-ticket yet: nothing to follow.
        record("BIL-9", "Todo", %{labels: []})
      ]

      by_id = %{
        "id-BIL-1" => [filed("BIL-2", ~U[2026-10-03 08:00:00Z]), filed("BIL-2b", ~U[2026-10-02 08:00:00Z])],
        "id-BIL-3" => [filed("BIL-4", ~U[2026-10-02 08:00:00Z], :follow_up), %Event{type: "plan.written", at: @now, payload: %{shape: "single"}}],
        "id-BIL-5" => [split_plan(~U[2026-10-04 08:00:00Z])],
        "id-BIL-9" => [filed("BIL-10")]
      }

      assert [bil_1, bil_5] = read(records, by_id)

      assert %{identifier: "BIL-1", started_at: "2026-10-02T08:00:00Z", sub_tickets: [%{identifier: "BIL-2"}]} = bil_1
      assert %{identifier: "BIL-5", started_at: "2026-10-04T08:00:00Z", sub_tickets: [%{identifier: "BIL-6"}]} = bil_5
    end

    test "takes each parent's sub-tickets from its record's links: a done one stays and counts as done, a cancelled one is left out (c3)" do
      records = [
        record("BIL-1", "Waiting on sub-tickets", %{
          sub_issues: [link("BIL-2", "Done"), link("BIL-3", "Todo"), link("BIL-4", "Canceled"), link("BIL-5", "Done"), link("BIL-6", "Duplicate")]
        }),
        record("BIL-2", "Done", %{phase_at: ~U[2026-10-06 09:00:00Z]}),
        record("BIL-3", "Todo"),
        record("BIL-4", "Canceled")
      ]

      # A split event with no time still counts as a split.
      assert [initiative] = read(records, %{"id-BIL-1" => [%Event{type: "ticket.filed", payload: %{"kind" => "split_off"}}]})
      assert initiative.started_at == nil

      assert Enum.map(initiative.sub_tickets, &{&1.identifier, &1.state_type}) == [{"BIL-5", "completed"}, {"BIL-2", "completed"}, {"BIL-3", "started"}]

      live = Initiative.live(initiative, %{running: MapSet.new(), you: MapSet.new(), settings: settings(), dependencies: fn _id -> [] end})
      assert %{"done" => 2, "queued" => 1, "total" => 3} = live.counts
    end

    test "reads a repo's settings from the configuration by default" do
      records = [record("BIL-1", "Plan Review", %{sub_issues: [link("BIL-2", "Todo")]}), %{record("BIL-3", "Todo", %{sub_issues: [link("BIL-4", "Todo")]}) | repo_key: nil}]
      by_id = %{"id-BIL-1" => [filed("BIL-2")], "id-BIL-3" => [filed("BIL-4")]}

      assert [%{identifier: "BIL-1"}, %{identifier: "BIL-3"}] = Initiatives.read(records: records, events: events(by_id), now: @now)
      assert is_list(Initiatives.read(records: []))
    end
  end

  describe "parent_of/2" do
    test "names the parent that has the ticket among its sub-tickets" do
      plan = initiative("BIL-1", "In Progress", [record("BIL-2", "Done"), record("BIL-3", "Todo")])
      initiatives = [initiative("BIL-9", "In Progress", []), plan]

      assert Initiatives.parent_of("id-BIL-2", initiatives) == %{identifier: "BIL-1", title: "Plan BIL-1"}
      assert Initiatives.parent_of("id-BIL-3", initiatives) == %{identifier: "BIL-1", title: "Plan BIL-1"}
      assert Initiatives.parent_of("id-BIL-4", initiatives) == nil
      assert Initiatives.parent_of("id-BIL-unknown-#{System.unique_integer([:positive])}") == nil
    end
  end

  describe "live/2" do
    test "says what each sub-ticket waits on and counts the stages, from the stored dependencies" do
      children = [
        record("BIL-2", "Done", %{phase_at: ~U[2026-10-06 09:00:00Z]}),
        record("BIL-3", "In Progress"),
        record("BIL-4", "QA"),
        record("BIL-5", "Todo"),
        record("BIL-6", "Code Review"),
        record("BIL-7", "Todo"),
        record("BIL-8", "Backlog"),
        record("BIL-10", "Todo"),
        record("BIL-11", "Plan Review")
      ]

      settings = %Schema{tracker: %{kind: "memory", plan_review_state: "Plan Review"}}

      initiative = initiative("BIL-1", "In Progress", children, [], %{}, settings)
      dependencies = %{"id-BIL-5" => [{"BIL-4", "QA"}, {"BIL-2", "Done"}], "id-BIL-10" => [{"BIL-4", "QA"}]}
      live = live(initiative, settings, dependencies, running: ["id-BIL-3"], you: ["id-BIL-4"])

      waits = Map.new(live.sub_tickets, &{&1.identifier, &1.waits_on})

      assert waits == %{
               "BIL-2" => "done",
               "BIL-3" => "working",
               "BIL-4" => "you",
               "BIL-5" => "blocker",
               "BIL-6" => "ci",
               "BIL-7" => "slot",
               "BIL-8" => "you",
               "BIL-10" => "blocker",
               "BIL-11" => "you"
             }

      bil_5 = Enum.find(live.sub_tickets, &(&1.identifier == "BIL-5"))
      assert bil_5.waiting_for == ["BIL-4"]

      assert bil_5.blocked_by == [
               %{identifier: "BIL-4", state: "QA", open: true, completed_at: nil},
               %{identifier: "BIL-2", state: "Done", open: false, completed_at: "2026-10-06T09:00:00Z"}
             ]

      assert live.counts == %{"done" => 1, "working" => 2, "you" => 3, "queued" => 1, "blocked" => 2, "total" => 9}
      assert Initiative.stages() == ~w(done working you queued blocked)
    end

    test "orders the sub-tickets by their stored dependencies, then creation; a cycle breaks by creation" do
      children = [
        record("BIL-4", "Todo", %{created_at: ~U[2026-10-01 09:00:00Z]}),
        record("BIL-3", "Todo", %{created_at: ~U[2026-10-02 09:00:00Z]}),
        record("BIL-2", "Done", %{created_at: ~U[2026-10-03 09:00:00Z]}),
        record("BIL-6", "Todo", %{created_at: ~U[2026-10-04 09:00:00Z]}),
        record("BIL-7", "Todo", %{created_at: ~U[2026-10-05 09:00:00Z]}),
        record("BIL-5", "Todo", %{created_at: nil, title: nil})
      ]

      initiative = initiative("BIL-1", "In Progress", children)

      # BIL-4 depends on BIL-3, and on a ticket Symphony holds no record of; BIL-6 and BIL-7 on each other.
      dependencies = %{"id-BIL-4" => [{"BIL-3", "Todo"}, {"OUT-1", nil}], "id-BIL-6" => [{"BIL-7", "Todo"}], "id-BIL-7" => [{"BIL-6", "Todo"}]}
      live = live(initiative, settings(), dependencies)

      assert Enum.map(live.sub_tickets, & &1.identifier) == ["BIL-5", "BIL-3", "BIL-4", "BIL-2", "BIL-6", "BIL-7"]
      bil_4 = Enum.find(live.sub_tickets, &(&1.identifier == "BIL-4"))

      assert [%{identifier: "BIL-3", open: true}, %{identifier: nil, state: nil, open: true, completed_at: nil}] =
               bil_4.blocked_by

      assert bil_4.waiting_for == ["BIL-3", nil]
    end
  end

  describe "list/4" do
    test "lists the initiatives with what runs and what waits on the Director" do
      records = [record("BIL-1", "In Progress", %{sub_issues: [link("BIL-2", "Todo"), link("BIL-3", "Todo")]}), record("BIL-2", "Todo"), record("BIL-3", "Todo")]
      opts = [records: records, events: fn id -> if id == "id-BIL-1", do: [%Event{type: "ticket.filed", at: @now, payload: %{kind: "split_off"}}], else: [] end, now: @now]
      settings_fun = fn "billing" -> settings() end

      snapshot = %{running: [%{issue_id: "id-BIL-2"}]}
      assert [%{counts: %{"working" => 1, "queued" => 1}}] = Initiatives.list(snapshot, opts, {:test, make_ref()}, settings_fun)

      # A run paused on a Question is not working: it waits for the answer.
      paused = %{running: [%{issue_id: "id-BIL-2", step: %{waiting: "answer"}}]}
      assert [%{counts: %{"working" => 0}}] = Initiatives.list(paused, opts, {:test, make_ref()}, settings_fun)

      assert [%{counts: %{"working" => 0}}] = Initiatives.list(%{}, opts, {:test, make_ref()})
      assert Initiatives.list(%{}, records: []) == []
    end
  end
end
