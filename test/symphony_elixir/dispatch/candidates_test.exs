defmodule SymphonyElixir.Dispatch.CandidatesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.Candidates
  alias SymphonyElixir.TicketState

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
      part_1 = issue("part-1", "MT-11", "Todo", priority: 2)
      part_2 = issue("part-2", "MT-12", "Todo", blocked_by: [blocker("MT-11", "Todo")])

      epic =
        issue("epic", "MT-10", @waiting,
          labels: ["plan"],
          sub_issues: [Map.take(part_1, [:id, :identifier, :state]), Map.take(part_2, [:id, :identifier, :state])]
        )

      issues = [epic, part_1, part_2, issue("merging", "MT-20", "Merging"), issue("standalone", "MT-21", "Todo", priority: 1)]

      {cache, record} = assert_same_candidates!(issues)

      # The record keeps no sub-issues, so only the parts are compared through the gate; the parent's
      # wait on its sub-tickets reads them.
      parts = ["MT-11", "MT-12", "MT-20", "MT-21"]
      assert Map.take(gate(record), parts) == Map.take(gate(cache), parts)
      assert gate(cache)["MT-12"] == false
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
  end

  describe "issue_from_record/1" do
    test "rebuilds what the record observed, its open blockers with no known state" do
      polled =
        issue("rebuilt", "MT-7", "Rework",
          labels: ["backend"],
          priority: 2,
          assignee_id: "user-1",
          blocked_by: [blocker("MT-6", "Todo")]
        )

      assert %Issue{
               id: "rebuilt",
               identifier: "MT-7",
               title: "Ticket MT-7",
               state: "Rework",
               labels: ["backend"],
               priority: 2,
               assignee_id: "user-1",
               blocked_by: [%{id: nil, identifier: "MT-6", state: nil}],
               url: "https://example.org/issues/MT-7",
               repo_key: repo_key,
               updated_at: ~U[2026-10-29 09:00:00Z]
             } = Candidates.issue_from_record(observed(polled))

      assert repo_key == repo_key()
      assert Issue.blocked?(%{Candidates.issue_from_record(observed(polled)) | state: "Todo"}, ["Done"])
    end
  end

  defp assert_same_candidates!(issues) do
    repo_key = repo_key()

    assert {:ok, %{dispatchable: cache}, _state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(
               %Orchestrator.State{poll_interval_ms: 100},
               [%{name: repo_key}],
               fn _repo -> {:ok, issues} end,
               0
             )

    records = RunStore.list_ticket_states(repo_key)
    assert length(records) == length(issues)

    assert %{candidates: record, excluded: excluded} = from_records(records)
    assert Enum.all?(Map.values(excluded), &(&1 == 0))

    assert identifiers(record) == identifiers(cache)
    assert dispatch_order(record) == dispatch_order(cache)
    assert Enum.map(record, &{&1.identifier, &1.state, &1.priority}) == Enum.map(cache, &{&1.identifier, &1.state, &1.priority})

    {cache, record}
  end

  defp from_records(records), do: Candidates.from_records(repo_key(), records, Config.settings!())

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
