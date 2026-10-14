defmodule SymphonyElixir.ShippedTodayTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ShippedToday

  # The host at UTC−3, like the Director's Mac.
  defp utc_minus_3(%NaiveDateTime{} = utc), do: NaiveDateTime.add(utc, -3, :hour)

  defp completion(issue_id, utc_iso8601) do
    {:ok, completed_at, 0} = DateTime.from_iso8601(utc_iso8601)
    {issue_id, completed_at}
  end

  # 2026-10-06 local: 09:00, and 23:30 (02:30 UTC on 2026-10-07). 2026-10-07 local: 00:30.
  @completions [
    {"morning", "2026-10-06T12:00:00Z"},
    {"late-evening", "2026-10-07T02:30:00Z"},
    {"after-midnight", "2026-10-07T03:30:00Z"}
  ]

  defp completions, do: Enum.map(@completions, fn {id, at} -> completion(id, at) end)

  defp record_live(completions) do
    Enum.reduce(completions, %{}, fn {issue_id, completed_at}, shipped ->
      ShippedToday.record(shipped, entry(issue_id, completed_at), completed_at, &utc_minus_3/1)
    end)
  end

  defp entry(issue_id, completed_at) do
    %{issue_id: issue_id, identifier: issue_id, title: issue_id, repo_key: "repo", completed_at: completed_at}
  end

  defp run(issue_id, completed_at) do
    %{
      issue_id: issue_id,
      issue_identifier: issue_id,
      title: issue_id,
      repo_key: "repo",
      issue_completed_notified_at: completed_at
    }
  end

  defp ids(entries), do: Enum.map(entries, & &1.issue_id)

  test "a completion at 23:30 local, 02:30 UTC the next day, counts toward that local day" do
    {_id, late_evening} = completion("late-evening", "2026-10-07T02:30:00Z")
    {_id, after_midnight} = completion("after-midnight", "2026-10-07T03:30:00Z")

    assert ShippedToday.local_date(late_evening, &utc_minus_3/1) == ~D[2026-10-06]
    assert ShippedToday.local_date(after_midnight, &utc_minus_3/1) == ~D[2026-10-07]

    [morning, late, _after] = completions()
    shipped = record_live([morning, late])

    # Still 23:45 local on 2026-10-06, though the UTC day is already 2026-10-07.
    {:ok, now, 0} = DateTime.from_iso8601("2026-10-07T02:45:00Z")
    assert ids(ShippedToday.today(shipped, now, &utc_minus_3/1)) == ["late-evening", "morning"]
  end

  test "a completion at 00:30 local starts a new day" do
    shipped = record_live(completions())

    assert Map.keys(shipped) == ["after-midnight"]

    {:ok, now, 0} = DateTime.from_iso8601("2026-10-07T03:45:00Z")
    assert ids(ShippedToday.today(shipped, now, &utc_minus_3/1)) == ["after-midnight"]
  end

  test "startup hydration counts the same tickets as the live recording" do
    runs = Enum.map(completions(), fn {issue_id, completed_at} -> run(issue_id, completed_at) end)

    for now_iso8601 <- ["2026-10-07T02:45:00Z", "2026-10-07T03:45:00Z"] do
      {:ok, now, 0} = DateTime.from_iso8601(now_iso8601)
      live = completions() |> Enum.filter(fn {_id, at} -> DateTime.compare(at, now) == :lt end) |> record_live()
      hydrated = ShippedToday.hydrate(runs, now, &utc_minus_3/1)

      assert ShippedToday.today(hydrated, now, &utc_minus_3/1) == ShippedToday.today(live, now, &utc_minus_3/1)
    end
  end

  test "hydration keeps a ticket's newest run and skips runs without a completion or issue" do
    {_id, newer} = completion("t", "2026-10-06T20:00:00Z")
    {_id, older} = completion("t", "2026-10-06T13:00:00Z")
    {:ok, now, 0} = DateTime.from_iso8601("2026-10-06T21:00:00Z")

    runs = [
      run("t", newer),
      run("t", older),
      run("no-completion", nil),
      %{issue_id: nil, issue_completed_notified_at: newer}
    ]

    hydrated = ShippedToday.hydrate(runs, now, &utc_minus_3/1)
    assert %{"t" => %{completed_at: ^newer, identifier: "t", repo_key: "repo"}} = hydrated
    assert map_size(hydrated) == 1
  end

  test "the default zone is the host's" do
    now = DateTime.utc_now()

    expected =
      now
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()
      |> NaiveDateTime.from_erl!()
      |> NaiveDateTime.to_date()

    assert ShippedToday.local_date(now) == expected

    shipped = ShippedToday.record(%{}, entry("now", now), now)
    assert ids(ShippedToday.today(shipped, now)) == ["now"]
    assert ShippedToday.hydrate([run("now", now)], now) |> Map.keys() == ["now"]
  end
end
