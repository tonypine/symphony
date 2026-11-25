defmodule SymphonyElixir.Home.SlotsTest do
  # The Home read's slot entries (`SymphonyElixir.Home.Slots`), from ticket records that hold slots
  # with their stored numbers, the ledgers' plans and checks, and the live facts: a holder working by
  # itself, an epic with a sub-ticket running under it one and two levels down, an empty slot, a
  # holder stored before slots had numbers and a count lowered under a number still held.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.Queue
  alias SymphonyElixir.Home.Slots
  alias SymphonyElixir.Situation
  alias SymphonyElixir.TicketChecks
  alias SymphonyElixir.TicketEvents
  alias SymphonyElixir.TicketPlan
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.TicketState

  @repo "default"
  @t0 ~U[2026-11-24 08:00:00.000000Z]

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  test "one entry per slot, in number order, each with its stored number; a slot with no ticket is empty" do
    records = [holder("MT-1", "In Progress", 2, 0), record("MT-2", "Todo")]

    assert [
             %{slot: 1, empty: true, since: nil, epic: nil, ticket: nil},
             %{slot: 2, empty: false, since: since, epic: nil, ticket: %{identifier: "MT-1"}},
             %{slot: 3, empty: true, ticket: nil}
           ] = entries(records, total: 3)

    assert since == at(0)
    assert entries([], total: 0) == []
  end

  test "a holder stored before slots had numbers gets the lowest free one, and a number held above a lowered count is still an entry" do
    records = [holder("MT-1", "In Progress", 3, 0), holder("MT-2", "Code Review", nil, 1), holder("MT-3", "QA", nil, 2)]

    assert [
             %{slot: 1, ticket: %{identifier: "MT-2"}},
             %{slot: 2, ticket: %{identifier: "MT-3"}},
             %{slot: 3, ticket: %{identifier: "MT-1"}}
           ] = entries(records, total: 2)
  end

  test "a filled entry carries the card: status and situation, stages with tokens, tokens against the budget, the plan, the checks and the pull request" do
    working = holder("MT-1", "In Progress", 1, 0)
    {:ok, _moved} = TicketEvents.record(@repo, "id-MT-1", "phase.entered", %{to: "In Progress", from: "Todo"}, at: at(0))
    {:ok, _plan} = TicketPlan.write(@repo, "id-MT-1", plan(), at: at(1))
    {:ok, _proof} = TicketChecks.prove(@repo, "id-MT-1", %{"check_id" => "c1", "by" => "test", "test" => "home_test.exs"}, at: at(2))
    :ok = TicketPullRequest.record_created(@repo, "id-MT-1", "https://github.com/acme/app/pull/7", "auto/MT-1")

    pull_request = fn record ->
      send(self(), {:pull_request, record.issue_identifier})

      %{
        number: 7,
        url: "https://github.com/acme/app/pull/7",
        state: "open",
        draft: false,
        files_changed: 4,
        additions: 120,
        deletions: 8,
        review_state: "in_review",
        checks: [%{workflow: "CI", checks: [%{state: "passed"}, %{state: "running"}]}]
      }
    end

    started = DateTime.utc_now()
    live = live(%{running: [%{issue_id: "id-MT-1", run_kind: "implementation", started_at: started}]})
    runs = [%{issue_id: "id-MT-1", started_at: started, total_tokens: 1_500}]

    assert [%{slot: 1, epic: nil, ticket: card}] =
             Slots.entries([working], live, total: 1, runs: runs, pull_request: pull_request)

    assert_received {:pull_request, "MT-1"}

    assert %{issue_id: "id-MT-1", identifier: "MT-1", title: "Ticket MT-1", repo_key: @repo, phase: "In Progress"} = card
    assert %{working: true, waits_on_you: false, move: nil} = card
    assert card.since == at(0)
    assert card.situation.kind == "working"
    assert card.current_stage == "coding"
    assert [%{id: "coding", name: "Coding", state: "current", tokens: 1_500, runs: 1} | later] = card.stages
    assert Enum.map(later, & &1.id) == ["code_review", "qa", "merging", "done"]
    assert Enum.all?(card.stages, &(Map.keys(&1) |> Enum.sort() == [:id, :name, :runs, :state, :tokens]))
    assert card.tokens == %{used: 1_500, budget: Config.settings!().execution.max_tokens_per_issue}
    assert card.plan == %{summary: "The Home read gives the slots."}
    assert card.checks == %{proved: 1, waived: 0, total: 2, next: %{id: "c2", statement: "The queue reads in pages."}}

    assert card.pull_request == %{
             number: 7,
             url: "https://github.com/acme/app/pull/7",
             state: "open",
             draft: false,
             files_changed: 4,
             additions: 120,
             deletions: 8,
             review_state: "in_review",
             branch: "auto/MT-1",
             ci: "running"
           }
  end

  test "a part the ticket does not have yet is nil, and the CI word follows the head's checks" do
    ticket = holder("MT-1", "Code Review", 1, 0)
    card = fn pull_request -> hd(entries([ticket], total: 1, pull_request: pull_request)).ticket end

    assert %{plan: nil, checks: nil, pull_request: nil, working: false} = hd(entries([ticket], total: 1)).ticket
    assert card.(fn _record -> nil end).pull_request == nil

    ci = fn checks -> card.(fn _record -> %{number: 1, checks: checks} end).pull_request end
    assert %{number: 1, branch: nil, ci: nil} = ci.([])
    assert ci.([%{workflow: "CI", checks: [%{state: "passed"}, %{state: "skipped"}]}]).ci == "passed"
    assert ci.([%{workflow: "CI", checks: [%{state: "running"}, %{state: "failed"}]}]).ci == "failed"
    assert ci.([%{workflow: "CI", checks: [%{state: "cancelled_no_machine"}]}]).ci == "failed"
    assert ci.([%{workflow: "CI", checks: [%{state: "waiting"}]}]).ci == "running"
  end

  test "a ticket that waits on the person says so, with the move that answers it" do
    asking = holder("MT-1", "Plan Review", 1, 0)
    moves = fn _record -> %{answer: %{allowed: false, reason: "no question"}, unblock: %{allowed: true, reason: nil}} end

    assert [%{ticket: %{waits_on_you: true, move: %{name: "unblock", allowed: true}} = card}] =
             entries([asking], total: 1, moves: moves)

    assert card.situation.kind == "waiting_on_you"
  end

  test "an epic's slot shows the sub-ticket worked on under it, one and two levels down, and names the epic; never more filled entries than slots" do
    # Slot 1: the epic MT-E took it, its sub-epic MT-M waits on its own sub-ticket MT-L, which a run
    # works on; MT-M's record names no parent (it never ran), MT-E's record lists it.
    subs = [link("MT-M", "Waiting on sub-tickets"), link("MT-D", "Done"), link("MT-X", "Canceled"), link("MT-U", "Todo")]
    epic = holder("MT-E", "Waiting on sub-tickets", 1, 0, sub_issues: subs)
    mid = holder("MT-M", "Waiting on sub-tickets", 1, 1, sub_issues: [link("MT-L", "In Progress")])
    leaf = holder("MT-L", "In Progress", 1, 2, parent: %{identifier: "MT-M"})
    done = record("MT-D", "Done", parent: %{identifier: "MT-E"})
    # Slot 2: the epic MT-F with one sub-ticket in work, none of them running: the one that joined last.
    other = holder("MT-F", "Waiting on sub-tickets", 2, 3)
    sub = holder("MT-S", "Code Review", 2, 4, parent: %{identifier: "MT-F"})
    records = [epic, mid, leaf, done, other, sub]

    live = live(%{running: [%{issue_id: "id-MT-L", run_kind: "implementation", started_at: DateTime.utc_now()}]})
    assert [first, second] = Slots.entries(records, live, total: 2, parents: Queue.parents(records))

    assert %{slot: 1, since: since, ticket: %{identifier: "MT-L", working: true}, epic: named} = first
    assert %{identifier: "MT-E", title: "Ticket MT-E", repo_key: @repo} = named
    assert since == at(0) and named.since == at(0)
    assert first.ticket.since == at(2)
    # MT-M and MT-D under MT-E, and MT-U its record lists: the cancelled one counts in neither.
    assert {named.done, named.total} == {1, 3}

    assert %{slot: 2, ticket: %{identifier: "MT-S", working: false}, epic: %{identifier: "MT-F", done: 0, total: 1}} = second
  end

  test "an epic's slot lists its done sub-tickets in order of completion and its open ones in their queue order, the card's left out" do
    # MT-E holds slot 1; MT-W works through it. Done: MT-B (merged PR 12, done first), MT-A (PR 9,
    # done later), MT-K known by its link alone. Open: MT-2 and MT-1 by their sort keys, MT-U by its
    # link. MT-X is cancelled.
    subs = [link("MT-K", "Done"), link("MT-U", "Todo"), link("MT-X", "Canceled")]
    epic = holder("MT-E", "Waiting on sub-tickets", 1, 0, sub_issues: subs, sort_key: "a1")
    parent = %{identifier: "MT-E"}
    working = holder("MT-W", "In Progress", 1, 1, parent: parent, sort_key: "a0")
    done_late = record("MT-A", "Done", parent: parent, phase_at: at(30))
    done_early = record("MT-B", "Done", parent: parent, phase_at: at(10))

    second =
      record("MT-2", "Todo",
        parent: parent,
        sort_key: "a2",
        depends_on: [
          %{issue_id: "id-MT-A", identifier: "MT-A", kind: :done},
          %{issue_id: "id-MT-1", identifier: "MT-1", kind: :released}
        ]
      )

    first = record("MT-1", "Backlog", parent: parent, sort_key: "a1", repo_key: "shop")
    cancelled = record("MT-X", "Canceled", parent: parent)

    for {id, number} <- [{"id-MT-A", 9}, {"id-MT-B", 12}] do
      url = "https://github.com/acme/app/pull/#{number}"
      :ok = TicketPullRequest.record_created(@repo, id, url, "auto/#{id}")
      :ok = TicketPullRequest.mark_finished(@repo, url, "merged")
    end

    records = [epic, working, done_late, done_early, second, first, cancelled]
    assert [%{slot: 1, ticket: %{identifier: "MT-W"}, epic: named}] = entries(records, total: 1)

    # What the entry gave before stays as it was.
    assert %{issue_id: "id-MT-E", identifier: "MT-E", title: "Ticket MT-E", repo_key: @repo, done: 3, total: 7} = named
    assert named.since == at(0)

    assert named.done_sub_tickets == [
             %{issue_id: "id-MT-K", identifier: "MT-K", title: nil, pull_request_number: nil, done_at: nil},
             %{issue_id: "id-MT-B", identifier: "MT-B", title: "Ticket MT-B", pull_request_number: 12, done_at: at(10)},
             %{issue_id: "id-MT-A", identifier: "MT-A", title: "Ticket MT-A", pull_request_number: 9, done_at: at(30)}
           ]

    assert named.open_sub_tickets == [
             %{issue_id: "id-MT-1", identifier: "MT-1", title: "Ticket MT-1", phase: "Backlog", repo_key: "shop", parent: "MT-E", dependencies: []},
             %{
               issue_id: "id-MT-2",
               identifier: "MT-2",
               title: "Ticket MT-2",
               phase: "Todo",
               repo_key: @repo,
               parent: "MT-E",
               dependencies: [
                 %{issue_id: "id-MT-A", identifier: "MT-A", kind: "done", met: true},
                 %{issue_id: "id-MT-1", identifier: "MT-1", kind: "released", met: false}
               ]
             },
             %{issue_id: "id-MT-U", identifier: "MT-U", title: nil, phase: "Todo", repo_key: nil, parent: "MT-E", dependencies: []}
           ]
  end

  test "a done sub-ticket with no repo, or whose stored pull request URL names no number, has no pull request number" do
    epic = holder("MT-E", "Waiting on sub-tickets", 1, 0)
    working = holder("MT-W", "In Progress", 1, 1, parent: %{identifier: "MT-E"})
    # MT-D's record names no repo: no stored pull request is looked up for it.
    done =
      TicketState.normalize(%{
        repo_key: nil,
        issue_id: "id-MT-D",
        issue_identifier: "MT-D",
        title: "Ticket MT-D",
        phase: "Done",
        parent: %{identifier: "MT-E"}
      })

    other = record("MT-O", "Done", parent: %{identifier: "MT-E"})
    :ok = TicketPullRequest.record_created(@repo, "id-MT-O", "https://github.com/acme/app/commits/main", nil)

    assert [%{epic: %{done_sub_tickets: [first, second], open_sub_tickets: []}}] =
             entries([epic, working, done, other], total: 1)

    assert %{identifier: "MT-D", pull_request_number: nil} = first
    assert %{identifier: "MT-O", pull_request_number: nil} = second
  end

  defp entries(records, opts) do
    Slots.entries(records, live(), Keyword.put_new(opts, :parents, Queue.parents(records)))
  end

  defp holder(identifier, phase, slot, minutes, attrs \\ []) do
    record(identifier, phase, Keyword.merge([slot_held_since: at(minutes), slot_number: slot], attrs))
  end

  defp record(identifier, phase, attrs \\ []) do
    record =
      Map.merge(
        %{repo_key: @repo, issue_id: "id-#{identifier}", issue_identifier: identifier, title: "Ticket #{identifier}", phase: phase, priority: 1},
        Map.new(attrs)
      )

    :ok = RunStore.put_ticket_state(record)
    TicketState.normalize(record)
  end

  defp link(identifier, state), do: %{id: "id-#{identifier}", identifier: identifier, state: state}

  defp plan do
    %{
      reason: "Grooming",
      by: "grooming",
      shape: "single",
      layers: ["api"],
      summary: "The Home read gives the slots.",
      text: "Read the slots from the records.",
      checks: [
        %{id: "c1", kind: "outcome", statement: "One entry per slot.", proof: "test"},
        %{id: "c2", kind: "outcome", statement: "The queue reads in pages.", proof: "test"}
      ],
      size: %{tokens: 100_000, runs: 1}
    }
  end

  defp at(minutes), do: DateTime.add(@t0, minutes * 60)

  defp live(snapshot \\ %{}), do: Situation.live_facts(snapshot)
end
