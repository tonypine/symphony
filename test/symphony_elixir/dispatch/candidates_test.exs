defmodule SymphonyElixir.Dispatch.CandidatesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.Dispatch.Candidates
  alias SymphonyElixir.EpicLanes
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.{TicketObservation, TicketState}

  @waiting "Waiting on sub-tickets"
  @active_states ["Todo", "In Progress", "Merging", "Rework", @waiting]
  @observed_at ~U[2026-10-29 12:00:00Z]

  setup do
    workflow!()
    :ok
  end

  # Each fixture is polled through the cache path, which also observes it into the record
  # (TP-1214). The record path must give the same candidates, in the same dispatch order, and the
  # dispatch gate must decide each rebuilt issue as it decides the polled one.
  describe "the record path matches the cache path" do
    test "on the blocked-by gate" do
      issues = [
        issue("blocked", "MT-1", "Todo", blocked_by: [blocker("MT-90", "Merging")]),
        issue("in-review", "MT-2", "Todo", blocked_by: [blocker("MT-91", "In Review")]),
        issue("unblocked", "MT-3", "Todo", blocked_by: [blocker("MT-92", "Done"), blocker("MT-93", "Canceled")]),
        issue("unknown-blocker", "MT-4", "Todo", blocked_by: [%{id: "b", identifier: "MT-94", state: nil}]),
        issue("under-way", "MT-5", "In Progress", blocked_by: [blocker("MT-95", "Todo")])
      ]

      {cache, record} = assert_same_candidates!(issues)

      assert gate(cache) == %{"MT-1" => false, "MT-2" => false, "MT-3" => true, "MT-4" => false, "MT-5" => true}
      assert gate(record) == gate(cache)
    end

    test "on the priority filter" do
      workflow!(tickets: %{priorities: ["urgent", "high"]})

      issues =
        for {priority, n} <- Enum.with_index([1, 2, 3, 4, 0, nil], 1) do
          issue("p#{n}", "MT-#{n}", "Todo", priority: priority)
        end

      {cache, record} = assert_same_candidates!(issues)

      assert gate(cache) == %{"MT-1" => true, "MT-2" => true, "MT-3" => false, "MT-4" => false, "MT-5" => false, "MT-6" => false}
      assert gate(record) == gate(cache)

      # A retry waiting for a slot is let through, on either path.
      waiting = %{orchestrator_state() | slot_waiting: %{"p4" => %{attempt: 1}}}
      assert gate(record, waiting) == gate(cache, waiting)
      assert gate(record, waiting)["MT-4"]
    end

    test "on a forced ticket" do
      workflow!(tickets: %{priorities: ["urgent"]})

      issues = [
        issue("forced", "MT-1", "Todo", priority: 4, labels: ["expedite"]),
        issue("low", "MT-2", "Todo", priority: 4),
        issue("urgent", "MT-3", "Rework", priority: 1)
      ]

      {cache, record} = assert_same_candidates!(issues)

      assert gate(cache) == %{"MT-1" => true, "MT-2" => false, "MT-3" => true}
      assert gate(record) == gate(cache)
    end

    test "on an epic and its lanes' parts" do
      part_1 = issue("part-1", "MT-11", "In Progress", priority: 2)
      part_2 = issue("part-2", "MT-12", "Todo", blocked_by: [%{id: "part-1", identifier: "MT-11", state: "In Progress"}])
      part_3 = issue("part-3", "MT-31", "Todo")

      # Two epics of the same priority: MT-30 is the older, so it takes the one lane.
      epic = issue("epic", "MT-10", @waiting, labels: ["plan"], sub_issues: [link(part_1), link(part_2)], created_at: ~U[2026-10-02 09:00:00Z])
      older = issue("older-epic", "MT-30", @waiting, labels: ["plan"], sub_issues: [link(part_3)], created_at: ~U[2026-10-01 09:00:00Z])

      issues = [epic, part_1, part_2, older, part_3, issue("merging", "MT-20", "Merging"), issue("standalone", "MT-21", "Todo", priority: 1)]

      {cache, record} = assert_same_candidates!(issues)

      assert gate(record) == gate(cache)
      assert %{"MT-10" => false, "MT-30" => false, "MT-12" => false} = gate(cache)

      # Each parent waits on its sub-tickets on both paths.
      for issues <- [cache, record], parent <- ["MT-10", "MT-30"] do
        assert issues |> Enum.find(&(&1.identifier == parent)) |> Issue.waiting_on_sub_issues?(terminal_states())
      end

      for {epic_lanes, expected} <- [{nil, {["MT-30", "MT-10"], []}}, {1, {["MT-30"], ["MT-10"]}}] do
        plan = EpicLanes.plan(record, 10, epic_lanes, terminal_states())
        assert plan == EpicLanes.plan(cache, 10, epic_lanes, terminal_states())
        assert {identifiers(plan.lanes), identifiers(plan.queued)} == expected
        assert plan.yielded == []
      end
    end

    test "on the dispatch order of tickets that differ only by age" do
      # MT-99 is the older, so it runs first, though its identifier sorts after MT-100's.
      issues = [
        issue("newer", "MT-100", "Todo", created_at: ~U[2026-10-02 09:00:00Z]),
        issue("older", "MT-99", "Todo", created_at: ~U[2026-10-01 09:00:00Z]),
        issue("oldest-rework", "MT-98", "Rework", created_at: ~U[2026-09-30 09:00:00Z])
      ]

      {cache, record} = assert_same_candidates!(issues)

      assert dispatch_order(cache) == ["MT-98", "MT-99", "MT-100"]
      assert dispatch_order(record) == dispatch_order(cache)
      assert Enum.map(record, & &1.created_at) == Enum.map(cache, & &1.created_at)
    end

    test "on a route whose assignee is not the tracker's, once a webhook reassigns its tickets" do
      workflow!(tracker_assignee: "tracker-worker")
      route = %{name: repo_key(), assignee: "route-worker"}
      [mt_1, mt_2, mt_3] = issues = for n <- 1..3, do: issue("t#{n}", "MT-#{n}", "Todo", assignee_id: "route-worker")

      {cache, _record} = assert_same_candidates!(issues, route)
      assert identifiers(cache) == ["MT-1", "MT-2", "MT-3"]

      # A webhook gives MT-2 to the tracker's assignee and unassigns MT-3. The next poll asks Linear for
      # the route's assignee only, so neither comes back, and the record leaves both out.
      later = ~U[2026-10-29 10:00:00Z]
      reassigned = [mt_1, %{mt_2 | assignee_id: "tracker-worker", updated_at: later}, %{mt_3 | assignee_id: nil, updated_at: later}]

      for issue <- tl(reassigned) do
        assert {:ok, :updated} = TicketObservation.observe(repo_key(), issue, source: :webhook)
      end

      cache = poll!(reassigned, route)
      records = RunStore.list_ticket_states(repo_key())

      assert identifiers(cache) == ["MT-1"]
      assert %{candidates: record, excluded: %{unassigned: 2}} = from_records(records, route: route)
      assert identifiers(record) == identifiers(cache)

      # Without its route, the tracker's assignee would name the worker.
      assert %{candidates: [%Issue{identifier: "MT-2"}]} = from_records(records)
    end
  end

  describe "the records left out" do
    test "are counted under the reason that leaves each out, and never read from the store" do
      records = [
        observed(issue("candidate", "MT-1", "Todo")),
        "removed" |> issue("MT-2", "Todo") |> observed() |> TicketState.mark_removed(@observed_at),
        TicketState.new(repo_key(), "unobserved", %{issue_identifier: "MT-3", phase: "Todo", title: "Held only"}),
        observed(issue("untitled", "MT-4", "Todo", title: nil)),
        observed(issue("done", "MT-5", "Done")),
        observed(issue("backlog", "MT-6", "Backlog")),
        observed(issue("plan-review", "MT-7", "Plan Review"))
      ]

      # The records were never written: the function reads only what it is given.
      assert RunStore.list_ticket_states(repo_key()) == []

      assert %{candidates: [%Issue{identifier: "MT-1"}], excluded: excluded} = from_records(records)
      assert excluded == %{removed: 1, unobserved: 1, incomplete: 1, unassigned: 0, terminal: 1, inactive: 2}
      assert Enum.sum(Map.values(excluded)) + 1 == length(records)
    end

    test "a record without linear_updated_at is never a candidate, whatever else it holds" do
      record = %{observed(issue("todo", "MT-1", "Todo")) | linear_updated_at: nil}

      assert %{candidates: [], excluded: %{unobserved: 1}} = from_records([record])
    end
  end

  describe "the worker's assignee" do
    test "with no assignee configured, any assignee or none is the worker's" do
      records = [observed(issue("a", "MT-1", "Todo", assignee_id: "someone")), observed(issue("b", "MT-2", "Todo", assignee_id: nil))]

      assert %{candidates: [_, _], excluded: %{unassigned: 0}} = from_records(records)

      blank = settings_with_assignee("  ")
      assert %{candidates: [_, _]} = Candidates.from_records(repo_key(), records, blank)
    end

    test "a configured id keeps the tickets assigned to it" do
      records = [observed(issue("mine", "MT-1", "Todo", assignee_id: "worker")), observed(issue("theirs", "MT-2", "Todo", assignee_id: "someone"))]
      settings = settings_with_assignee("worker")

      assert %{candidates: [%Issue{identifier: "MT-1", assigned_to_worker: true}], excluded: %{unassigned: 1}} =
               Candidates.from_records(repo_key(), records, settings)
    end

    test "`me` needs the caller's resolved id, and without it no record counts as assigned" do
      records = [observed(issue("mine", "MT-1", "Todo", assignee_id: "viewer")), observed(issue("none", "MT-2", "Todo", assignee_id: nil))]
      settings = settings_with_assignee("me")

      assert %{candidates: [], excluded: %{unassigned: 2}} = Candidates.from_records(repo_key(), records, settings)

      assert %{candidates: [%Issue{identifier: "MT-1"}], excluded: %{unassigned: 1}} =
               Candidates.from_records(repo_key(), records, settings, assignee_ids: ["viewer"])

      assert %{candidates: [_, _]} = Candidates.from_records(repo_key(), records, settings, assignee_ids: nil)
    end

    test "a route's assignee names the worker before the tracker's, and a route without one leaves it to the tracker's" do
      records = [observed(issue("route", "MT-1", "Todo", assignee_id: "route-worker")), observed(issue("tracker", "MT-2", "Todo", assignee_id: "tracker-worker"))]
      settings = settings_with_assignee("tracker-worker")
      from_route = &Candidates.from_records(repo_key(), records, settings, route: &1)
      route = fn assignee -> %SystemSchema.Repo{name: repo_key(), assignee: assignee} end

      assert %{candidates: [%Issue{identifier: "MT-1"}], excluded: %{unassigned: 1}} = from_route.(route.("route-worker"))
      assert %{candidates: [%Issue{identifier: "MT-2"}]} = from_route.(route.(nil))
      assert %{candidates: [%Issue{identifier: "MT-2"}]} = from_route.(%{name: repo_key()})

      # A route's `me` needs the caller's resolved id, as the tracker's does.
      assert %{candidates: [], excluded: %{unassigned: 2}} = from_route.(route.("me"))
    end

    test "`states` names the states a candidate's state must be one of, in place of the active states" do
      records = [observed(issue("todo", "MT-1", "Todo")), observed(issue("backlog", "MT-2", " backlog ")), observed(issue("done", "MT-3", "Done"))]
      settings = Config.settings!()

      assert %{candidates: [%Issue{identifier: "MT-1"}], excluded: %{inactive: 1, terminal: 1}} =
               Candidates.from_records(repo_key(), records, settings)

      assert %{candidates: [%Issue{identifier: "MT-2"}], excluded: %{inactive: 1, terminal: 1}} =
               Candidates.from_records(repo_key(), records, settings, states: ["In Progress", "Backlog"])
    end
  end

  describe "issue_from_record/1" do
    test "rebuilds what the record observed: its open blockers and sub-issues with their ids and states, its parent and age" do
      parent = %{identifier: "MT-1", title: "Epic", done: 1, total: 2, children: ["completed", "started"]}

      polled =
        issue("rebuilt", "MT-7", "Rework",
          labels: ["backend"],
          priority: 2,
          assignee_id: "user-1",
          blocked_by: [blocker("MT-6", "Todo"), blocker("MT-5", "Done")],
          sub_issues: [%{id: "sub", identifier: "MT-8", state: "Backlog"}],
          parent: parent,
          created_at: ~U[2026-10-01 09:00:00Z]
        )

      assert %Issue{
               id: "rebuilt",
               identifier: "MT-7",
               title: "Ticket MT-7",
               state: "Rework",
               labels: ["backend"],
               priority: 2,
               assignee_id: "user-1",
               blocked_by: [%{id: "id-MT-6", identifier: "MT-6", state: "Todo"}],
               sub_issues: [%{id: "sub", identifier: "MT-8", state: "Backlog"}],
               parent: ^parent,
               url: "https://example.org/issues/MT-7",
               repo_key: repo_key,
               created_at: ~U[2026-10-01 09:00:00Z],
               updated_at: ~U[2026-10-29 09:00:00Z]
             } = Candidates.issue_from_record(observed(polled))

      assert repo_key == repo_key()
      assert Issue.blocked?(%{Candidates.issue_from_record(observed(polled)) | state: "Todo"}, ["Done"])
    end

    test "a blocker a record kept by identifier alone has no known state, so it still blocks" do
      record = %{observed(issue("legacy", "MT-7", "Todo")) | blockers: ["MT-6"]}

      rebuilt = Candidates.issue_from_record(record)

      assert rebuilt.blocked_by == [%{id: nil, identifier: "MT-6", state: nil}]
      assert Issue.blocked?(rebuilt, ["Done"])
    end
  end

  defp assert_same_candidates!(issues, route \\ %{name: repo_key()}) do
    cache = poll!(issues, route)

    records = RunStore.list_ticket_states(repo_key())
    assert length(records) == length(issues)

    assert %{candidates: record, excluded: excluded} = from_records(records, route: route)
    assert Enum.all?(Map.values(excluded), &(&1 == 0))

    assert identifiers(record) == identifiers(cache)
    assert dispatch_order(record) == dispatch_order(cache)
    assert Enum.map(record, &{&1.identifier, &1.state, &1.priority}) == Enum.map(cache, &{&1.identifier, &1.state, &1.priority})

    {cache, record}
  end

  # The cache path's poll of `route`, from a Linear that answers the route's filter as Linear does: it
  # returns only the tickets assigned to the worker the filter names.
  defp poll!(issues, route) do
    assert {:ok, filter} = Client.repo_scope_filter(route)
    assignee_ids = get_in(filter, ["assignee", "id", "in"])
    linear = fn _repo -> {:ok, Enum.filter(issues, &(is_nil(assignee_ids) or &1.assignee_id in assignee_ids))} end

    state = %Orchestrator.State{poll_interval_ms: 100}
    assert {:ok, buckets, _state} = Orchestrator.poll_candidate_issue_buckets_for_test(state, [route], linear, 0)

    buckets.dispatchable
  end

  defp from_records(records, opts \\ []), do: Candidates.from_records(repo_key(), records, Config.settings!(), opts)

  defp gate(issues, state \\ orchestrator_state()) do
    Map.new(issues, &{&1.identifier, Orchestrator.should_dispatch_issue_for_test(&1, state)})
  end

  defp identifiers(issues), do: Enum.map(issues, & &1.identifier)

  defp dispatch_order(issues), do: issues |> Orchestrator.sort_issues_for_dispatch_for_test() |> identifiers()

  # What the poll writes into a ticket's record (`TicketObservation.observe/3`): the open blockers only.
  defp observed(%Issue{} = issue) do
    open = Issue.open_blockers(issue, Config.settings!().tracker.terminal_states)

    {record, :changed} =
      repo_key()
      |> TicketState.new(issue.id)
      |> TicketState.observe(%{issue | blocked_by: open}, @observed_at, :poll)

    record
  end

  defp settings_with_assignee(assignee) do
    settings = Config.settings!()
    %{settings | tracker: %{settings.tracker | assignee: assignee}}
  end

  defp repo_key, do: Config.repo_key!()

  defp issue(id, identifier, state, attrs \\ []) do
    struct!(
      %Issue{
        id: id,
        identifier: identifier,
        title: "Ticket #{identifier}",
        state: state,
        priority: 3,
        labels: [],
        assigned_to_worker: true,
        url: "https://example.org/issues/#{identifier}",
        updated_at: ~U[2026-10-29 09:00:00Z]
      },
      attrs
    )
  end

  defp blocker(identifier, state), do: %{id: "id-" <> identifier, identifier: identifier, state: state}

  defp link(%Issue{} = issue), do: Map.take(issue, [:id, :identifier, :state])

  defp terminal_states, do: Config.settings!().tracker.terminal_states

  defp workflow!(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [tracker_kind: "memory", tracker_active_states: @active_states, tracker_terminal_states: ["Done", "Canceled", "Duplicate"]],
        overrides
      )
    )
  end

  defp orchestrator_state do
    %Orchestrator.State{
      repo_key: repo_key(),
      max_concurrent_agents: 10,
      running: %{},
      claimed: MapSet.new(),
      slot_waiting: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
