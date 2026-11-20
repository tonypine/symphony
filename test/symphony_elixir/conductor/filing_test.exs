defmodule SymphonyElixir.Conductor.FilingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Conductor.{Facts, Filing}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{TicketEvents, TicketState}

  @settings %Schema.Conductor{enabled: true}

  # The filer the self-heal lane files through: every effect is recorded, and each can fail.
  defmodule Fixer do
    def create(attrs, opts) do
      Process.put(:created, {attrs, Keyword.take(opts, [:priority, :repo_key])})
      Process.get(:create_result, {:ok, %{id: "new-id", identifier: "TP-2000", url: "https://linear.app/t/TP-2000"}})
    end

    def block(issue, ticket, _opts) do
      Process.put(:blocked, {issue.id, ticket.identifier})
      Process.get(:block_result, :ok)
    end

    def relate(issue, ticket, _opts) do
      Process.put(:related, {issue.id, ticket.identifier})
      Process.get(:relate_result, :ok)
    end
  end

  defmodule Tracker do
    def fetch_issue_by_identifier(identifier), do: Process.get({:ticket, identifier}, {:error, :not_found})
  end

  setup do
    n = System.unique_integer([:positive])
    issue_id = "issue-filing-#{n}"
    identifier = "MOT-#{n}"
    state = %{repo_key: "default", issue_id: issue_id, issue_identifier: identifier, phase: "QA", title: "Translate Cycle"}
    :ok = RunStore.put_ticket_state(state)
    issue = %Issue{id: issue_id, identifier: identifier, title: "Translate Cycle", state: "QA", repo_key: "default"}
    %{issue: issue, issue_id: issue_id, identifier: identifier}
  end

  defp route(attrs \\ %{}) do
    Map.merge(
      %{
        to: "ticket",
        relation: "blocks",
        repo: "default",
        title: "The QA build runs the Mac app build on a repo with no Mac app",
        problem: "QA builds the Mac app for every repo, and Cycle has none, so every pass fails before any test.",
        wanted: "QA builds the Mac app only for a repo that has one.",
        acceptance: ["A Cycle QA pass starts its tests."],
        walkthrough: ["In the Director, open a Cycle ticket in QA: its pass runs its steps."],
        evidence: [],
        existing: nil
      },
      attrs
    )
  end

  defp file(ctx, route, settings \\ @settings, opts \\ []) do
    context = %{issue: ctx.issue, repo_key: "default", run_id: "conductor-#{System.unique_integer([:positive])}", events: Facts.events(ctx.issue_id)}
    Filing.file(route, context, settings, [fixer: Fixer, tracker: Tracker, terminal_states: ["Done", "Canceled"]] ++ opts)
  end

  defp events(issue_id, type), do: issue_id |> Facts.events() |> Enum.filter(&(&1.type == type))

  defp pause_reasons(issue_id), do: issue_id |> RunStore.get_ticket_state() |> TicketState.pause_reasons()

  test "a blocking ticket is filed through the self-heal filer, Urgent and labelled, and holds the ticket on it", ctx do
    assert {:ok, filed} = file(ctx, route())
    assert filed == %{identifier: "TP-2000", url: "https://linear.app/t/TP-2000", relation: "blocks", title: route().title, existing: false, repo: "default"}

    {attrs, opts} = Process.get(:created)
    assert Enum.sort(opts) == [priority: 1, repo_key: "default"]
    assert %{scope: "default", labels: ["tech debt"], team: :scope, title: "The QA build runs" <> _rest} = attrs
    assert attrs.description =~ "## Problem\n\nQA builds the Mac app for every repo"
    assert attrs.description =~ "The Conductor filed this ticket from #{ctx.identifier}, which waits for it to be Done and then continues."
    assert attrs.description =~ "## Wanted behaviour\n\nQA builds the Mac app only for a repo that has one."
    assert attrs.description =~ "## Acceptance criteria\n\n- A Cycle QA pass starts its tests."
    assert attrs.description =~ "## User walkthrough\n\n1. In the Director, open a Cycle ticket in QA"
    refute attrs.description =~ "## Evidence"

    assert Process.get(:blocked) == {ctx.issue_id, "TP-2000"}
    assert [%{text: "Waiting for TP-2000 to finish: it fixes what stopped this ticket"}] = pause_reasons(ctx.issue_id)

    assert [%{payload: %{identifier: "TP-2000", kind: "split_off", by: "conductor", repo: "default", existing: false, reason: "QA builds" <> _}}] =
             events(ctx.issue_id, "ticket.filed")

    assert [%{payload: %{from: from, by: "conductor", kind: "split_off"}}] = events("new-id", "ticket.filed_from")
    assert from == ctx.identifier
  end

  test "a follow-up is linked as related and leaves the ticket unpaused", ctx do
    assert {:ok, %{relation: "follow_up"}} = file(ctx, route(%{relation: "follow_up"}))
    assert Process.get(:related) == {ctx.issue_id, "TP-2000"}
    assert Process.get(:blocked) == nil
    assert pause_reasons(ctx.issue_id) == []
    assert elem(Process.get(:created), 0).description =~ "as a follow-up; #{ctx.identifier} goes on without it."

    # A related link that fails is logged; the ticket is filed all the same.
    Process.put(:relate_result, {:error, :rate_limited})
    log = capture_log(fn -> assert {:ok, _filed} = file(ctx, route(%{relation: "follow_up", title: "Another one"})) end)
    assert log =~ "Could not link #{ctx.identifier} to TP-2000 as related: :rate_limited"
  end

  test "the evidence the route names is written from the ticket's events", ctx do
    {:ok, verdict} = TicketEvents.record("default", ctx.issue_id, "verdict.recorded", %{kind: "qa", outcome: "blocked", head: "abc1234", details: %{reason: "no Mac app"}})
    {:ok, note} = TicketEvents.record("default", ctx.issue_id, "note", %{text: "The QA build failed."})

    assert {:ok, _filed} = file(ctx, route(%{evidence: [verdict.id, "unknown-id", note.id]}))
    description = elem(Process.get(:created), 0).description
    assert description =~ "## Evidence from #{ctx.identifier}\n\n- "
    assert description =~ "(event #{verdict.id})"
    assert description =~ "Note added: The QA build failed. (event #{note.id})"
    refute description =~ "unknown-id"
  end

  test "a route naming a repo Symphony does not manage, a bad relation or a missing section is refused", ctx do
    assert {:error, "the ticket route names the repo \"nowhere\", which Symphony does not manage"} = file(ctx, route(%{repo: "nowhere"}))
    assert {:error, "the ticket route names no repo"} = file(ctx, route(%{repo: nil}))
    assert {:error, "the ticket route's relation must be blocks or follow_up"} = file(ctx, route(%{relation: "duplicate"}))
    assert {:error, "the ticket route misses a title"} = file(ctx, route(%{title: nil}))
    assert {:error, "the ticket route misses its wanted behaviour"} = file(ctx, route(%{wanted: nil}))
    assert {:error, "the ticket route misses its walkthrough"} = file(ctx, route(%{walkthrough: []}))
    assert Process.get(:created) == nil
    assert events(ctx.issue_id, "ticket.filed") == []
  end

  test "another repo Symphony manages is allowed", ctx do
    repo = fn
      "symphony" -> {:ok, %{name: "symphony"}}
      _other -> {:error, :unknown}
    end

    assert {:ok, %{repo: "symphony"}} = file(ctx, route(%{repo: "symphony"}), @settings, repo: repo)
    assert %{scope: "symphony"} = elem(Process.get(:created), 0)
  end

  test "the third filing is refused, and the switch turns the route off", ctx do
    assert {:ok, _first} = file(ctx, route(%{title: "First"}))
    assert {:ok, _second} = file(ctx, route(%{title: "Second", relation: "follow_up"}))
    assert {:error, "this ticket already filed 2, its limit (conductor.max_filed_tickets)"} = file(ctx, route(%{title: "Third"}))

    assert %{open: false, left: 0, filed: [%{identifier: "TP-2000", relation: "blocks", title: "First"}, %{relation: "follow_up", title: "Second"}]} =
             Filing.facts(Facts.events(ctx.issue_id), @settings, repos: ["default"])

    assert {:ok, _third} = file(ctx, route(%{title: "Third"}), %{@settings | max_filed_tickets: 3})
    assert {:error, "filing tickets is switched off (conductor.file_tickets)"} = file(ctx, route(), %{@settings | file_tickets: false})
  end

  test "a ticket the Conductor filed files none of its own", ctx do
    {:ok, _event} = TicketEvents.record("default", ctx.issue_id, "ticket.filed_from", %{from: "TP-1", by: "conductor"})

    assert {:error, "this ticket was itself filed by the Conductor (from TP-1), and a ticket it filed files none of its own"} = file(ctx, route())
    assert %{open: false, closed: "this ticket was itself filed" <> _rest, left: 2} = Filing.facts(Facts.events(ctx.issue_id), @settings, repos: [])
  end

  test "an open ticket the route names, or one already filed under the same title, is linked instead of a duplicate", ctx do
    Process.put({:ticket, "TP-1553"}, {:ok, %Issue{id: "tp-1553", identifier: "TP-1553", state: "In Progress", url: "https://linear.app/t/TP-1553"}})

    assert {:ok, %{identifier: "TP-1553", existing: true, url: "https://linear.app/t/TP-1553"}} = file(ctx, route(%{existing: "TP-1553"}))
    assert Process.get(:created) == nil
    assert Process.get(:blocked) == {ctx.issue_id, "TP-1553"}
    assert [%{payload: %{identifier: "TP-1553", existing: true}}] = events(ctx.issue_id, "ticket.filed")
    assert [%{text: "Waiting for TP-1553 to finish" <> _}] = pause_reasons(ctx.issue_id)

    # A link is not a filing: both filings are left.
    assert %{open: true, left: 2} = Filing.facts(Facts.events(ctx.issue_id), @settings, repos: [])

    # The same title again finds the ticket it already linked, still open.
    Process.delete(:blocked)
    assert {:ok, %{identifier: "TP-1553", existing: true}} = file(ctx, route(%{title: "  the QA build runs the Mac app build on a repo with NO Mac app "}))
    assert Process.get(:created) == nil

    # A named ticket that is terminal, unreadable or this one covers nothing: a new one is filed.
    Process.put({:ticket, "TP-1553"}, {:ok, %Issue{id: "tp-1553", identifier: "TP-1553", state: "Done"}})
    Process.put({:ticket, "SELF"}, {:ok, %Issue{id: ctx.issue_id, identifier: "SELF", state: "QA"}})

    for existing <- ["TP-1553", "SELF", "TP-404"] do
      Process.delete(:created)
      settings = %{@settings | max_filed_tickets: 5}

      log =
        capture_log(fn ->
          route = route(%{existing: existing, title: "New #{existing}"})
          assert {:ok, %{identifier: "TP-2000", existing: false}} = file(ctx, route, settings)
        end)

      assert Process.get(:created) != nil
      if existing != "TP-1553", do: assert(log =~ "Conductor cannot link #{existing}")
    end
  end

  test "a filing the tracker refuses is the error, and nothing is recorded", ctx do
    Process.put(:create_result, {:error, :rate_limited})
    assert {:error, "the ticket could not be filed: {:file_ticket_failed, :rate_limited}"} = file(ctx, route())
    assert events(ctx.issue_id, "ticket.filed") == []
  end

  test "a ticket created whose hold cannot be set is still returned, recorded and counted, and says why", ctx do
    hold = fn _repo_key, _issue, _identifier -> {:error, :store_down} end

    log =
      capture_log(fn ->
        assert {:ok, %{identifier: "TP-2000", relation: "blocks", existing: false, unheld: ":store_down"} = filed} = file(ctx, route(), @settings, hold: hold)
        assert Filing.message(filed, "Cycle has no Mac app.") =~ "This ticket could not be held on it (:store_down), so it goes on for now."
      end)

    assert log =~ "could not hold it"
    assert Process.get(:blocked) == {ctx.issue_id, "TP-2000"}
    assert [%{payload: %{identifier: "TP-2000", existing: false}}] = events(ctx.issue_id, "ticket.filed")
    assert [%{payload: %{from: from}}] = events("new-id", "ticket.filed_from")
    assert from == ctx.identifier
    assert pause_reasons(ctx.issue_id) == []

    # The limit counts it, and the same problem again links it instead of filing a duplicate.
    assert %{left: 1, filed: [%{identifier: "TP-2000"}]} = Filing.facts(Facts.events(ctx.issue_id), @settings, repos: [])
    Process.put({:ticket, "TP-2000"}, {:ok, %Issue{id: "new-id", identifier: "TP-2000", state: "Todo"}})
    Process.delete(:created)
    assert {:ok, %{identifier: "TP-2000", existing: true}} = file(ctx, route())
    assert Process.get(:created) == nil
  end

  test "an open ticket already linked as blocking this one under the same title is linked, not filed again", ctx do
    title = route().title
    Process.put({:ticket, "TP-1553"}, {:ok, %Issue{id: "tp-1553", identifier: "TP-1553", title: title, state: "In Progress", url: "https://linear.app/t/TP-1553"}})
    Process.put({:ticket, "TP-1554"}, {:ok, %Issue{id: "tp-1554", identifier: "TP-1554", title: "Something else", state: "Todo"}})

    blockers = [
      %{id: "done", identifier: "TP-1500", state: "Done"},
      %{id: nil, identifier: nil, state: "Todo"},
      %{id: "gone", identifier: "TP-404", state: "Todo"},
      %{id: "tp-1554", identifier: "TP-1554", state: "Todo"},
      %{id: "tp-1553", identifier: "TP-1553", state: nil}
    ]

    # The blockers the issue carries.
    issue = %{ctx.issue | blocked_by: blockers}
    assert {:ok, %{identifier: "TP-1553", existing: true, url: "https://linear.app/t/TP-1553"}} = file(%{ctx | issue: issue}, route())
    assert Process.get(:created) == nil
    assert Process.get(:blocked) == {ctx.issue_id, "TP-1553"}
    assert [%{text: "Waiting for TP-1553 to finish" <> _rest}] = pause_reasons(ctx.issue_id)
    assert [%{payload: %{identifier: "TP-1553", existing: true}}] = events(ctx.issue_id, "ticket.filed")

    # Else the blockers the tracker reads of it.
    Process.put({:ticket, ctx.identifier}, {:ok, %Issue{id: ctx.issue_id, identifier: ctx.identifier, blocked_by: blockers}})
    assert {:ok, %{identifier: "TP-1553", existing: true}} = file(ctx, route(%{relation: "follow_up"}))
    assert Process.get(:related) == {ctx.issue_id, "TP-1553"}
    assert Process.get(:created) == nil

    # A linked ticket under another title covers nothing, and an issue without an identifier reads none.
    assert {:ok, %{identifier: "TP-2000", existing: false}} = file(ctx, route(%{relation: "follow_up", title: "Another problem"}))
    Process.delete(:created)
    issue = %{ctx.issue | identifier: nil}
    settings = %{@settings | max_filed_tickets: 5}
    route = route(%{relation: "follow_up", title: "Yet another"})
    assert {:ok, %{identifier: "TP-2000", existing: false}} = file(%{ctx | issue: issue}, route, settings)
    assert Process.get(:created) != nil
  end

  test "the update's sentence names the ticket, its relation and why" do
    filed = %{identifier: "TP-2000", relation: "blocks", title: "Fix the QA build", existing: false}

    assert Filing.message(filed, "QA builds a Mac app Cycle lacks.") ==
             "I filed `TP-2000` as blocking this ticket: Fix the QA build. QA builds a Mac app Cycle lacks. This ticket waits for it to be Done, then continues where it stopped."

    assert Filing.message(%{filed | relation: "follow_up", existing: true}, nil) ==
             "I linked `TP-2000`, which was already open, as a follow-up: Fix the QA build. This ticket goes on without it."
  end

  test "the facts list the repos a ticket may be filed in" do
    assert %{open: true, closed: nil, filed: [], left: 2, repos: repos} = Filing.facts([], @settings)
    assert "default" in repos
  end

  test "a ticket filed without a title is never taken for the same problem", ctx do
    {:ok, _event} = TicketEvents.record("default", ctx.issue_id, "ticket.filed", %{identifier: "TP-1999", kind: "follow_up", repo: "default", existing: false, by: "conductor"})
    Process.put({:ticket, "TP-1999"}, {:ok, %Issue{id: "tp-1999", identifier: "TP-1999", state: "Todo"}})

    assert {:ok, %{identifier: "TP-2000", existing: false}} = file(ctx, route(%{relation: "follow_up"}))
  end

  test "with no options, the filing reads Symphony's own config and tracker", ctx do
    context = %{issue: ctx.issue, repo_key: "default", run_id: "conductor-defaults", events: Facts.events(ctx.issue_id)}
    assert {:error, _why} = Filing.file(route(%{repo: "no-such-repo"}), context, @settings)
  end
end
