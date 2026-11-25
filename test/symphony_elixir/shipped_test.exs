defmodule SymphonyElixir.ShippedTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Home.RecentlyDone
  alias SymphonyElixir.Shipped
  alias SymphonyElixir.TicketEvents

  setup do
    :ok = RunStore.clear()
  end

  # A ticket's signals are its events: they are written to the store under its id, and the record
  # names the ticket.
  defp ticket_state(repo_key, issue_id, signals) do
    for signal <- signals, do: :ok = put_signal(repo_key, issue_id, signal.name, signal.details, signal.at)
    %{repo_key: repo_key, issue_id: issue_id}
  end

  @now ~U[2026-10-13 12:00:00Z]

  # The host three hours behind UTC, so local days and UTC days differ near midnight.
  defp to_local(%NaiveDateTime{} = utc), do: NaiveDateTime.add(utc, -3 * 3600, :second)

  defp run(issue_id, identifier, started_at, attrs \\ %{}) do
    Map.merge(
      %{issue_id: issue_id, issue_identifier: identifier, title: "#{identifier} title", repo_key: "app", started_at: started_at},
      attrs
    )
  end

  defp payload(params, runs, opts \\ []) do
    runs_started_on = fn date -> Enum.filter(runs, &(DateTime.to_date(&1.started_at) == date)) end
    issue_runs = fn repo_key, issue_id -> Enum.filter(runs, &(&1.repo_key == repo_key and &1.issue_id == issue_id)) end

    Shipped.payload(
      params,
      Keyword.merge(
        [
          now: @now,
          to_local: &to_local/1,
          runs_started_on: runs_started_on,
          issue_runs: issue_runs,
          ticket_states: [],
          initiatives: []
        ],
        opts
      )
    )
  end

  test "lists each ticket merged in the period, newest first, with its initiative, PR and time from Todo to Done" do
    runs = [
      run("i1", "APP-1", ~U[2026-10-12 09:00:00Z], %{pull_request_url: "https://github.com/acme/app/pull/1"}),
      run("i1", "APP-1", ~U[2026-10-13 08:00:00Z], %{
        issue_completed_notified_at: ~U[2026-10-13 10:00:00Z],
        initiative: %{identifier: "APP-100", title: "Gift cards"}
      }),
      run("i2", "APP-2", ~U[2026-10-12 20:00:00Z], %{
        pr_url: "https://github.com/acme/app/pull/2",
        issue_completed_notified_at: ~U[2026-10-13 02:00:00Z]
      }),
      run("i3", "WEB-3", ~U[2026-09-20 08:00:00Z], %{
        repo_key: "web",
        issue_completed_notified_at: ~U[2026-10-11 15:00:00Z]
      }),
      run("i4", "APP-4", ~U[2026-10-05 08:00:00Z], %{issue_completed_notified_at: ~U[2026-10-05 09:00:00Z]}),
      run("i5", "APP-5", ~U[2026-10-13 08:00:00Z]),
      run(nil, nil, ~U[2026-10-13 08:00:00Z], %{issue_completed_notified_at: ~U[2026-10-13 09:00:00Z]})
    ]

    ticket_states = [
      ticket_state("web", "i3", [
        %{name: "claim", details: %{from: "Todo"}, at: ~U[2026-10-10 12:00:00Z]},
        %{name: "claim", details: %{from: "Rework"}, at: ~U[2026-10-11 12:00:00Z]},
        %{name: "handoff", details: %{}, at: ~U[2026-10-09 12:00:00Z]}
      ])
    ]

    initiative = %{
      identifier: "WEB-1",
      title: "Checkout",
      sub_tickets: [%{id: "i3"}]
    }

    assert {:ok, payload} = payload(%{"days" => "3"}, runs, ticket_states: ticket_states, initiatives: [initiative])

    assert %{days: 3, from: "2026-10-11", to: "2026-10-13", total: 3} = payload

    assert payload.shipped_per_day == [
             %{date: "2026-10-11", shipped: 1},
             %{date: "2026-10-12", shipped: 1},
             %{date: "2026-10-13", shipped: 1}
           ]

    assert [app1, app2, web3] = payload.tickets

    assert app1 == %{
             issue_id: "i1",
             identifier: "APP-1",
             title: "APP-1 title",
             repo_key: "app",
             initiative: %{identifier: "APP-100", title: "Gift cards"},
             pr_url: "https://github.com/acme/app/pull/1",
             merged_at: "2026-10-13T10:00:00Z",
             date: "2026-10-13",
             todo_at: "2026-10-12T09:00:00Z",
             todo_to_done_seconds: 25 * 3600
           }

    # Merged at 02:00 UTC, still the 12th on the host.
    assert %{identifier: "APP-2", date: "2026-10-12", initiative: nil, pr_url: "https://github.com/acme/app/pull/2", todo_to_done_seconds: 21_600} =
             app2

    assert %{
             identifier: "WEB-3",
             repo_key: "web",
             initiative: %{identifier: "WEB-1", title: "Checkout"},
             pr_url: nil,
             todo_at: "2026-10-10T12:00:00Z",
             todo_to_done_seconds: 97_200
           } = web3
  end

  test "keeps a ticket's latest completion; a merge with no known start has no time from Todo to Done" do
    runs = [
      run("i1", "APP-1", ~U[2026-10-01 08:00:00Z], %{issue_completed_notified_at: ~U[2026-10-01 09:00:00Z]}),
      run("i1", "APP-1", ~U[2026-10-13 08:00:00Z], %{issue_completed_notified_at: ~U[2026-10-13 11:00:00Z]}),
      %{issue_id: "i9", repo_key: "app", issue_completed_notified_at: ~U[2026-10-13 10:00:00Z], started_at: ~U[2026-10-13 09:00:00Z]}
    ]

    claim = %{name: "claim", details: %{}, at: ~U[2026-10-13 10:30:00Z]}
    claim_after_merge = [ticket_state("app", "i9", [claim])]
    no_runs = fn _repo_key, _issue_id -> {:error, :down} end

    assert {:ok, %{total: 2, tickets: [app1, other]}} =
             payload(%{}, runs, ticket_states: claim_after_merge, issue_runs: no_runs)

    assert %{merged_at: "2026-10-13T11:00:00Z", todo_at: "2026-10-13T08:00:00Z"} = app1
    assert %{identifier: nil, todo_at: "2026-10-13T10:30:00Z", todo_to_done_seconds: 0} = other

    unstarted = %{issue_id: "i8", repo_key: "app", issue_completed_notified_at: ~U[2026-10-13 10:00:00Z], started_at: nil}
    on_today = fn date -> if date == ~D[2026-10-13], do: [unstarted], else: [] end
    starts_unknown = fn _repo_key, _issue_id -> [%{started_at: nil}] end

    assert {:ok, %{tickets: [%{todo_at: nil, todo_to_done_seconds: nil}]}} =
             payload(%{}, [], runs_started_on: on_today, issue_runs: starts_unknown)
  end

  test "defaults to 7 days, rejects a days value outside 1..90 and skips a day whose runs fail to load" do
    assert {:ok, %{days: 7, from: "2026-10-07", tickets: [], total: 0}} = payload(%{}, [])
    assert {:ok, %{days: 90, shipped_per_day: per_day}} = payload(%{"days" => 90}, [])
    assert length(per_day) == 90

    for days <- ["0", "91", "abc", "7d", 3.5] do
      assert payload(%{"days" => days}, []) == {:error, :invalid_days}
    end

    # The options default to none: a bad value is refused before any store is read.
    assert Shipped.payload(%{"days" => "0"}) == {:error, :invalid_days}

    failing = fn _date -> {:error, :down} end
    assert {:ok, %{total: 0}} = payload(%{"days" => "1"}, [], runs_started_on: failing, ticket_states: {:error, :down})
  end

  test "counts the host's own local days when no conversion is given" do
    merged = run("i1", "APP-1", ~U[2026-10-13 09:00:00Z], %{issue_completed_notified_at: @now})
    host_today = SymphonyElixir.ShippedToday.local_date(@now)

    # A ticket merged this instant is merged today wherever the host is.
    now = @now

    assert %{from: ^host_today, today: ^host_today, local_date: local_date, runs: [%{issue_id: "i1", done_at: ^now}]} =
             Shipped.done_runs(1, now: @now, runs_started_on: fn _date -> [merged] end)

    assert local_date.(@now) == host_today
  end

  # The ledger events that say when a ticket was done, written to the store as Symphony writes them.
  defp merged(issue_id, at), do: {:ok, _event} = TicketEvents.record("app", issue_id, "phase.entered", %{to: "Done", from: "Merging", signal: "merge settled"}, at: at)

  test "a ticket's merge time is when its pull request merged, as Recently done gives it, and it counts on that day" do
    # Both merged on the 12th; Symphony noted both completions in the same second on the 13th.
    noted_late = ~U[2026-10-13 11:40:08Z]
    merged("i1", ~U[2026-10-12 14:00:00Z])
    merged("i2", ~U[2026-10-12 18:00:00Z])

    runs = [
      run("i1", "APP-1", ~U[2026-10-12 13:00:00Z], %{issue_completed_notified_at: noted_late}),
      run("i2", "APP-2", ~U[2026-10-12 17:00:00Z], %{issue_completed_notified_at: noted_late})
    ]

    assert {:ok, payload} = payload(%{"days" => "2"}, runs)
    assert [%{identifier: "APP-2", merged_at: "2026-10-12T18:00:00Z", date: "2026-10-12"}, %{identifier: "APP-1", merged_at: "2026-10-12T14:00:00Z", date: "2026-10-12"}] = payload.tickets
    assert payload.shipped_per_day == [%{date: "2026-10-12", shipped: 2}, %{date: "2026-10-13", shipped: 0}]
    assert [%{todo_to_done_seconds: 3600}, %{todo_to_done_seconds: 3600}] = payload.tickets

    runs_started_on = fn date -> Enum.filter(runs, &(DateTime.to_date(&1.started_at) == date)) end
    page = %{range: :week, offset: 0, limit: 50}
    home = RecentlyDone.read([], %{}, page, now: @now, to_local: &to_local/1, runs_started_on: runs_started_on)

    assert Enum.map(home.entries, &{&1.identifier, &1.done_at}) == Enum.map(payload.tickets, &{&1.identifier, &1.merged_at})
  end

  test "done_at/2: the first merge or move into Done of the ledger, else when the completion was noted" do
    noted = %{issue_completed_notified_at: ~U[2026-10-13 11:00:00Z]}
    event = fn type, payload, at -> %TicketEvents.Event{type: type, payload: payload, at: at} end

    events = [
      event.("note", %{text: "Done"}, ~U[2026-10-10 08:00:00Z]),
      event.("phase.entered", %{to: "QA"}, ~U[2026-10-11 08:00:00Z]),
      event.("ticket.moved", %{from: "QA", to: " done "}, ~U[2026-10-12 09:00:00Z]),
      event.("phase.entered", %{to: "Done", signal: "merge settled"}, ~U[2026-10-12 10:00:00Z])
    ]

    assert Shipped.done_at(noted, events) == ~U[2026-10-12 09:00:00Z]
    assert Shipped.done_at(noted, Enum.take(events, 2)) == ~U[2026-10-13 11:00:00Z]

    # A parent that merged and then waited on its sub-tickets was done at the merge.
    waited = [event.("phase.entered", %{to: "Waiting on sub-tickets", signal: "merge settled"}, ~U[2026-10-11 10:00:00Z]) | events]
    assert Shipped.done_at(noted, waited) == ~U[2026-10-11 10:00:00Z]
  end
end
