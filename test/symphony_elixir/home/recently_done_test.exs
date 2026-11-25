defmodule SymphonyElixir.Home.RecentlyDoneTest do
  # Recently done from the run records: tickets of two repos done today, earlier in the week and one
  # older than the week, on a host three hours behind UTC so the local day and the UTC day differ;
  # a ticket of an epic and one without; both counts under either range; the pages.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.Queue
  alias SymphonyElixir.Home.RecentlyDone
  alias SymphonyElixir.TicketPullRequest

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  # 09:00 local on 2026-11-24: local midnight is 03:00 UTC, and the week starts on 2026-11-18 local.
  @now ~U[2026-11-24 12:00:00Z]

  defp to_local(%NaiveDateTime{} = utc), do: NaiveDateTime.add(utc, -3 * 3600, :second)

  defp run(issue_id, identifier, repo_key, done_at, attrs \\ %{}) do
    Map.merge(
      %{
        issue_id: issue_id,
        issue_identifier: identifier,
        title: "#{identifier} title",
        repo_key: repo_key,
        started_at: DateTime.add(done_at, -3600, :second),
        issue_completed_notified_at: done_at
      },
      attrs
    )
  end

  defp record(issue_id, identifier, repo_key, attrs \\ %{}) do
    Map.merge(%{issue_id: issue_id, issue_identifier: identifier, repo_key: repo_key, title: "Record #{identifier}", parent: nil, sub_issues: []}, attrs)
  end

  defp runs do
    [
      # Today, in an epic whose record holds its title, with its stored pull request.
      run("i1", "APP-1", "app", ~U[2026-11-24 10:00:00.123456Z]),
      # Today, in an epic Symphony holds no record of: the title the ticket's record keeps.
      run("i7", "APP-7", "app", ~U[2026-11-24 08:00:00Z]),
      # Today at 01:00 local, in the other repo, with no epic; its run keeps its pull request and no title.
      run("i2", "WEB-2", "web", ~U[2026-11-24 04:00:00Z], %{title: nil, pr_url: "https://github.com/acme/web/pull/22"}),
      # 23:00 local the day before: in the week, not today; the plan ticket its run kept; no record.
      run("i3", "APP-3", "app", ~U[2026-11-24 02:00:00Z], %{initiative: %{identifier: "APP-100", title: "Plans"}}),
      # The first day of the week, listed by its epic's record; a pull request URL with no number.
      run("i4", "WEB-4", "web", ~U[2026-11-18 05:00:00Z], %{pr_url: "https://github.com/acme/web/commits"}),
      # 23:00 local on 2026-11-17: older than the week.
      run("i5", "APP-5", "app", ~U[2026-11-18 02:00:00Z]),
      # Not done.
      Map.delete(run("i6", "APP-6", "app", ~U[2026-11-24 09:00:00Z]), :issue_completed_notified_at)
    ]
  end

  defp records do
    [
      record("e1", "APP-E", "app", %{title: "Gift cards"}),
      record("i1", "APP-1", "app", %{parent: %{identifier: "APP-E", title: "Old title"}}),
      record("i7", "APP-7", "app", %{parent: %{identifier: "APP-X", title: "Kept title"}}),
      record("i2", "WEB-2", "web"),
      record("e2", "WEB-E", "web", %{title: "Checkout", sub_issues: [%{id: "i4", identifier: "WEB-4", state: "Done"}]}),
      record("i4", "WEB-4", "web")
    ]
  end

  defp read(page, runs \\ runs()) do
    runs_started_on = fn date -> Enum.filter(runs, &(DateTime.to_date(&1.started_at) == date)) end
    RecentlyDone.read(records(), Queue.parents(records()), page, now: @now, to_local: &to_local/1, runs_started_on: runs_started_on)
  end

  defp page(range, offset \\ 0, limit \\ 50), do: %{range: range, offset: offset, limit: limit}

  test "Today holds the tickets done since local midnight and Week the last 7 days, most recent first, of every repo, with both counts" do
    :ok = TicketPullRequest.record_created("app", "i1", "https://github.com/acme/app/pull/11", "auto/APP-1")

    today = read(page(:today))
    assert Enum.map(today.entries, & &1.identifier) == ["APP-1", "APP-7", "WEB-2"]
    assert %{range: "today", counts: %{today: 3, week: 5}, offset: 0, limit: 50, next_offset: nil} = today

    week = read(page(:week))
    assert Enum.map(week.entries, & &1.identifier) == ["APP-1", "APP-7", "WEB-2", "APP-3", "WEB-4"]
    assert %{range: "week", counts: %{today: 3, week: 5}} = week

    assert [app1, app7, web2, app3, web4] = week.entries

    assert app1 == %{
             issue_id: "i1",
             identifier: "APP-1",
             title: "APP-1 title",
             repo_key: "app",
             done_at: "2026-11-24T10:00:00Z",
             pull_request_number: 11,
             epic: %{identifier: "APP-E", title: "Gift cards"}
           }

    assert %{epic: %{identifier: "APP-X", title: "Kept title"}, pull_request_number: nil} = app7
    assert %{repo_key: "web", title: "Record WEB-2", epic: nil, pull_request_number: 22} = web2
    assert %{title: "APP-3 title", epic: %{identifier: "APP-100", title: "Plans"}} = app3
    assert %{epic: %{identifier: "WEB-E", title: "Checkout"}, pull_request_number: nil, done_at: "2026-11-18T05:00:00Z"} = web4
  end

  test "a range is read in pages, the counts of the whole ranges beside each page" do
    first = read(page(:week, 0, 2))
    assert {Enum.map(first.entries, & &1.identifier), first.next_offset} == {["APP-1", "APP-7"], 2}

    second = read(page(:week, 2, 2))
    assert {Enum.map(second.entries, & &1.identifier), second.next_offset} == {["WEB-2", "APP-3"], 4}
    assert %{offset: 2, limit: 2, counts: %{today: 3, week: 5}} = second

    last = read(page(:week, 4, 2))
    assert {Enum.map(last.entries, & &1.identifier), last.next_offset} == {["WEB-4"], nil}

    today = read(page(:today, 2, 2))
    assert {Enum.map(today.entries, & &1.identifier), today.next_offset} == {["WEB-2"], nil}

    assert %{entries: [], counts: %{today: 0, week: 0}, next_offset: nil} = read(page(:today), [])
  end

  test "the page a query asks for, and a bad range or number" do
    assert RecentlyDone.page(%{}) == {:ok, RecentlyDone.default_page()}
    assert RecentlyDone.default_page() == %{range: :today, offset: 0, limit: 50}
    assert RecentlyDone.page(%{"done_range" => "", "done_offset" => "", "done_limit" => ""}) == {:ok, %{range: :today, offset: 0, limit: 50}}
    assert RecentlyDone.page(%{"done_range" => "week", "done_offset" => "10", "done_limit" => "5"}) == {:ok, %{range: :week, offset: 10, limit: 5}}
    assert RecentlyDone.page(%{"done_range" => "today", "done_limit" => 9_999}) == {:ok, %{range: :today, offset: 0, limit: 500}}

    assert RecentlyDone.page(%{"done_range" => "month"}) == {:error, {:invalid, "done_range must be today or week"}}
    assert RecentlyDone.page(%{"done_offset" => "-1"}) == {:error, {:invalid, "done_offset must be a whole number from 0"}}
    assert RecentlyDone.page(%{"done_limit" => "0"}) == {:error, {:invalid, "done_limit must be a whole number from 1"}}
    assert RecentlyDone.page(%{"done_limit" => "x"}) == {:error, {:invalid, "done_limit must be a whole number from 1"}}
  end
end
