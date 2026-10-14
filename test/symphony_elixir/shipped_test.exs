defmodule SymphonyElixir.ShippedTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Shipped

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
      %{
        repo_key: "web",
        issue_id: "i3",
        signals: [
          %{name: "claim", details: %{from: "Todo"}, at: ~U[2026-10-10 12:00:00Z]},
          %{name: "claim", details: %{from: "Rework"}, at: ~U[2026-10-11 12:00:00Z]},
          %{name: "handoff", details: %{}, at: ~U[2026-10-09 12:00:00Z]}
        ]
      }
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
    claim_after_merge = [%{repo_key: "app", issue_id: "i9", signals: [claim]}]
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

    failing = fn _date -> {:error, :down} end
    assert {:ok, %{total: 0}} = payload(%{"days" => "1"}, [], runs_started_on: failing, ticket_states: {:error, :down})
  end
end
