defmodule SymphonyElixir.AggregateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Aggregate, History, ReviewQuality, TicketEvents}

  @repo "fixture"
  @other_repo "other"
  @now ~U[2026-11-09 20:00:00.000000Z]
  @week %{"from" => "2026-11-03T00:00:00Z", "to" => "2026-11-10T00:00:00Z"}
  @facts %{
    now: @now,
    terminal_states: ["Done", "Canceled"],
    token_cap: nil,
    phase_names: %{code_review: "Code Review", qa: "QA", ci_fix: "CI Fix"}
  }

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)

    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "epic", issue_identifier: "FIX-1", title: "The epic", phase: "Waiting on sub-tickets"})

    for {issue_id, identifier} <- [{"child", "FIX-2"}, {"child-2", "FIX-3"}] do
      :ok =
        RunStore.put_ticket_state(%{
          repo_key: @repo,
          issue_id: issue_id,
          issue_identifier: identifier,
          title: "A sub-ticket",
          phase: "In Progress",
          parent: %{identifier: "FIX-1", title: "The epic"}
        })
    end

    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "loose", issue_identifier: "FIX-9", title: "No epic", phase: "Todo"})
    :ok = RunStore.put_ticket_state(%{repo_key: @other_repo, issue_id: "elsewhere", issue_identifier: "OTH-1", title: "Another repo's", phase: "Todo"})
    :ok
  end

  defp run(issue_id, identifier, started_at, attrs \\ %{}) do
    Map.merge(%{issue_id: issue_id, issue_identifier: identifier, repo_key: @repo, started_at: started_at, status: "success"}, attrs)
  end

  defp runs_started_on(runs), do: fn date -> Enum.filter(runs, &(DateTime.to_date(&1.started_at) == date)) end

  defp read!(params, runs \\ [], opts \\ []) do
    {:ok, payload} = Aggregate.read(params, [now: @now, runs_started_on: runs_started_on(runs), lifecycle_facts: @facts] ++ opts)
    payload
  end

  defp values(series), do: Enum.map(series.buckets, & &1.value)

  # A week on the fixture repo: the epic's two sub-tickets, its own run, a loose ticket and another
  # repo's ticket, with tokens, a merge, verdicts and a finding.
  defp fixture_runs do
    [
      run("child", "FIX-2", ~U[2026-11-04 09:00:00Z], %{model: "claude-opus-5-5", tokens: %{total_tokens: 100}, reviewer_tokens: %{total_tokens: 20}}),
      run("child", "FIX-2", ~U[2026-11-06 09:00:00Z], %{
        provider: "anthropic",
        tokens: %{total_tokens: 300},
        issue_completed_notified_at: ~U[2026-11-06 12:00:00Z]
      }),
      run("child-2", "FIX-3", ~U[2026-11-06 10:00:00Z], %{model: "gpt-5", tokens: %{total_tokens: 50}, status: "failure"}),
      run("epic", "FIX-1", ~U[2026-11-08 08:00:00Z], %{model: "claude", tokens: %{total_tokens: 7}}),
      run("loose", "FIX-9", ~U[2026-11-06 11:00:00Z], %{model: "claude", tokens: %{total_tokens: 1_000}, issue_completed_notified_at: ~U[2026-11-07 12:00:00Z]}),
      run("elsewhere", "OTH-1", ~U[2026-11-04 11:00:00Z], %{repo_key: @other_repo, model: "claude", tokens: %{total_tokens: 4_000}}),
      run(nil, nil, ~U[2026-11-05 07:00:00Z], %{tokens: %{total_tokens: 5}, status: nil}),
      # Merged this week, from a run that started before it.
      run("child-2", "FIX-3", ~U[2026-10-20 09:00:00Z], %{model: "claude", tokens: %{total_tokens: 9}, issue_completed_notified_at: ~U[2026-11-08 12:00:00Z]})
    ]
  end

  defp fixture_events do
    :ok = put_verdict(@repo, "child", "code_review", "abc", "approve", %{}, ~U[2026-11-05 09:00:00Z])
    :ok = put_verdict(@repo, "child", "qa", "abc", "pass", %{}, ~U[2026-11-05 10:00:00Z])
    :ok = put_verdict(@repo, "child-2", "code_review", "def", "rework", %{}, ~U[2026-11-06 09:00:00Z])
    :ok = put_verdict(@repo, "child-2", "code_review", "fed", "approve", %{}, ~U[2026-11-07 09:00:00Z])
    :ok = put_verdict(@other_repo, "elsewhere", "code_review", "aaa", "approve", %{}, ~U[2026-11-07 09:00:00Z])

    {:ok, _finding} =
      TicketEvents.record(@repo, "child", "finding.recorded", %{class: "clipped", severity: "major", description: "Cut off."},
        actor: {:agent, "run-4", "qa"},
        at: ~U[2026-11-05 10:00:00Z]
      )
  end

  describe "buckets" do
    test "a week holds 336 buckets of 30 minutes, 168 of an hour, 28 of six hours, 7 days and 2 weeks" do
      for {unit, count} <- [{"30m", 336}, {"1h", 168}, {"6h", 28}, {"day", 7}, {"week", 2}] do
        payload = read!(Map.put(@week, "unit", unit))
        assert length(payload.series["tokens"].buckets) == count, unit
        assert payload.unit == unit
      end
    end

    test "each unit starts its buckets on its UTC boundary and puts a run in the bucket holding its start" do
      runs = [run("child", "FIX-2", ~U[2026-11-04 09:47:12Z], %{tokens: %{total_tokens: 10}, status: :stopped})]
      assert read!(@week, runs).series["runs"].by == %{"stopped" => 1}

      for {unit, start, finish} <- [
            {"30m", "2026-11-04T09:30:00Z", "2026-11-04T10:00:00Z"},
            {"1h", "2026-11-04T09:00:00Z", "2026-11-04T10:00:00Z"},
            {"6h", "2026-11-04T06:00:00Z", "2026-11-04T12:00:00Z"},
            {"day", "2026-11-04T00:00:00Z", "2026-11-05T00:00:00Z"},
            {"week", "2026-11-02T00:00:00Z", "2026-11-09T00:00:00Z"}
          ] do
        tokens = read!(Map.put(@week, "unit", unit), runs).series["tokens"]
        assert [%{start: ^start, end: ^finish, value: 10}] = Enum.filter(tokens.buckets, &(&1.value > 0)), unit
        assert tokens.total == 10
      end
    end

    test "the period widens to whole buckets: a Tuesday afternoon to Wednesday by week starts on Monday" do
      payload = read!(%{"from" => "2026-11-03T15:00:00+03:00", "to" => "2026-11-04T01:00:00Z", "unit" => "week"})
      assert %{from: "2026-11-02T00:00:00Z", to: "2026-11-09T00:00:00Z"} = payload
    end

    test "dates take in whole days: from a date's midnight through the end of the to date" do
      payload = read!(%{"from" => "2026-11-03", "to" => "2026-11-09"})
      assert %{from: "2026-11-03T00:00:00Z", to: "2026-11-10T00:00:00Z", unit: "day"} = payload
      assert length(payload.series["runs"].buckets) == 7
    end

    test "without a period, the read covers the seven days ending with the bucket holding now" do
      payload = read!(%{})
      assert %{from: "2026-11-03T00:00:00Z", to: "2026-11-10T00:00:00Z", unit: "day", repo: nil, epic: nil} = payload
      assert Map.keys(payload.series) |> Enum.sort() == Enum.sort(Aggregate.series_names())

      assert length(read!(%{"unit" => "30m"}).series["tokens"].buckets) == 336
    end

    test "a day with no data is a bucket at zero, in every series" do
      fixture_events()
      payload = read!(@week, fixture_runs())

      for name <- Aggregate.series_names() do
        assert %{start: "2026-11-03T00:00:00Z", value: 0, by: by} = hd(payload.series[name].buckets), name
        assert by == %{}
      end

      assert %{tickets: []} = hd(payload.series["shipped"].buckets)
    end
  end

  describe "the fixture ledger" do
    test "its day totals equal the Usage page's tokens and merges and the Quality page's approvals" do
      fixture_events()
      runs = fixture_runs()
      payload = read!(@week, runs)

      {:ok, history} =
        History.payload(%{"days" => "7"},
          today: ~D[2026-11-09],
          agent: %{max_tokens_per_day: nil, max_tokens_per_issue: nil},
          runs_started_on: runs_started_on(runs),
          ticket_states: RunStore.list_all_ticket_states()
        )

      tokens = payload.series["tokens"]
      assert values(tokens) == Enum.map(history.tokens_per_day, & &1.total_tokens)
      assert Enum.map(tokens.buckets, & &1.by) == Enum.map(history.tokens_per_day, & &1.providers)

      # Usage counts a merge on the run's start week; the aggregate also finds FIX-3's, whose run
      # started before the period.
      assert values(payload.series["shipped"]) == [0, 0, 0, 1, 1, 1, 0]
      assert Enum.map(history.merged_per_day, & &1.merged) == [0, 0, 0, 1, 1, 0, 0]

      approvals_per_day =
        for date <- Date.range(~D[2026-11-03], ~D[2026-11-09]) do
          %{agreement: %{agreed: agreed, disagreed: disagreed, pending: pending}} = ReviewQuality.payload([date], manual_review: fn _repo -> "off" end)
          agreed + disagreed + pending
        end

      assert Enum.map(payload.series["verdicts"].buckets, &Map.get(&1.by, "code_review:approve", 0)) == approvals_per_day
      assert approvals_per_day == [0, 0, 1, 0, 2, 0, 0]
    end

    test "names each series' keys: providers, run statuses, verdicts, repositories and finding classes" do
      fixture_events()
      payload = read!(@week, fixture_runs())

      assert payload.series["runs"].by == %{"success" => 5, "failure" => 1, "unknown" => 1}
      assert payload.series["verdicts"].by == %{"code_review:approve" => 3, "code_review:rework" => 1, "qa:pass" => 1}
      assert payload.series["verdicts"].tickets == %{"FIX-2" => 2, "FIX-3" => 2, "OTH-1" => 1}
      assert payload.series["shipped"].by == %{@repo => 3}
      assert %{tickets: ["FIX-2"], value: 1} = Enum.at(payload.series["shipped"].buckets, 3)
      assert payload.series["findings"].by == %{"clipped" => 1}
      assert payload.series["findings"].total == 1
    end
  end

  describe "filters" do
    test "tokens by day for one epic add up to the epic's tickets' token totals" do
      runs = fixture_runs()
      payload = read!(Map.merge(@week, %{"epic" => "FIX-1", "series" => "tokens"}), runs)

      assert %{epic: "FIX-1"} = payload
      assert Map.keys(payload.series) == ["tokens"]
      tokens = payload.series["tokens"]

      assert tokens.tickets == %{"FIX-1" => 7, "FIX-2" => 420, "FIX-3" => 50}
      assert tokens.total == 477
      assert tokens.total == tokens.tickets |> Map.values() |> Enum.sum()
      assert values(tokens) == [0, 120, 0, 350, 0, 7, 0]
    end

    test "an epic keeps its own and its sub-tickets' verdicts and findings, and a run whose ticket Symphony has no record of only by its identifier" do
      fixture_events()
      runs = [run("unknown", "FIX-1", ~U[2026-11-04 09:00:00Z], %{tokens: %{total_tokens: 3}}), run("ghost", "GH-1", ~U[2026-11-04 09:00:00Z], %{tokens: %{total_tokens: 4}})]
      payload = read!(Map.put(@week, "epic", "FIX-1"), runs)

      assert payload.series["tokens"].tickets == %{"FIX-1" => 3}
      assert payload.series["verdicts"].tickets == %{"FIX-2" => 2, "FIX-3" => 2}
      assert payload.series["findings"].total == 1
    end

    test "a repository keeps its own runs and tickets" do
      fixture_events()
      payload = read!(Map.put(@week, "repo", @other_repo), fixture_runs())

      assert %{repo: @other_repo} = payload
      assert payload.series["tokens"].tickets == %{"OTH-1" => 4_000}
      assert payload.series["verdicts"].by == %{"code_review:approve" => 1}
      assert payload.series["findings"].total == 0
      assert payload.series["shipped"].total == 0
    end

    test "a blank repo or epic reads as none" do
      assert %{repo: nil, epic: nil} = read!(Map.merge(@week, %{"repo" => " ", "epic" => ""}))
    end
  end

  describe "time by stage" do
    test "splits each stay in a stage across the buckets it overlaps, the current one running to now" do
      at = &DateTime.new!(~D[2026-11-09], Time.new!(&1, &2, 0))

      for {to, from, at} <- [
            {"In Progress", "Todo", at.(8, 30)},
            {"Code Review", "In Progress", at.(10, 0)},
            {"Done", "Code Review", at.(11, 15)}
          ] do
        {:ok, _event} = TicketEvents.record(@repo, "child", "phase.entered", %{to: to, from: from}, at: at)
      end

      {:ok, _event} = TicketEvents.record(@repo, "loose", "phase.entered", %{to: "QA", from: "Code Review"}, at: at.(19, 0))
      {:ok, _event} = TicketEvents.record(@repo, "unrecorded", "phase.entered", %{to: "Merging", from: "QA"}, at: at.(19, 30))

      payload = read!(%{"from" => "2026-11-09T08:00:00Z", "to" => "2026-11-09T21:00:00Z", "unit" => "1h", "series" => "time_by_stage"})
      [eight, nine, ten, eleven | _] = payload.series["time_by_stage"].buckets
      minute = 60_000

      assert eight.by == %{"coding" => 30 * minute}
      assert nine.by == %{"coding" => 60 * minute}
      assert ten.by == %{"code_review" => 60 * minute}
      assert eleven.by == %{"code_review" => 15 * minute}

      # QA and Merging run to now (20:00); the last hour is empty.
      assert Enum.at(payload.series["time_by_stage"].buckets, 11).by == %{"qa" => 60 * minute, "merging" => 30 * minute}
      assert List.last(payload.series["time_by_stage"].buckets).value == 0
      assert payload.series["time_by_stage"].tickets == %{"FIX-2" => 165 * minute, "FIX-9" => 60 * minute}
      assert payload.series["time_by_stage"].by == %{"coding" => 90 * minute, "code_review" => 75 * minute, "qa" => 60 * minute, "merging" => 30 * minute}

      # A stay outside the period counts nowhere; one that starts before it counts from its start.
      day = read!(%{"from" => "2026-11-09T09:00:00Z", "to" => "2026-11-09T10:00:00Z", "unit" => "30m", "series" => "time_by_stage"})
      assert day.series["time_by_stage"].total == 60 * minute
      assert read!(%{"from" => "2026-11-08", "to" => "2026-11-08", "series" => "time_by_stage"}).series["time_by_stage"].total == 0
    end
  end

  test "reads the store when no source is injected" do
    write_workflow_file!(Workflow.workflow_file_path())
    fixture_events()

    assert {:ok, %{series: %{"verdicts" => %{total: 5}, "tokens" => %{total: 0}, "time_by_stage" => %{total: 0}}}} =
             Aggregate.read(@week, now: @now)
  end

  test "refuses a malformed period, unit or series" do
    for {params, message} <- [
          {%{"unit" => "2h"}, "unit must be one of 30m, 1h, 6h, day, week"},
          {%{"series" => "tokens,spend"}, "Unknown series: spend"},
          {%{"series" => 5}, "series must be a comma-separated list"},
          {%{"from" => "yesterday"}, "from must be an ISO 8601 time or date"},
          {%{"to" => 5}, "to must be an ISO 8601 time or date"},
          {%{"from" => "2026-11-09", "to" => "2026-11-08"}, "from must be before to"},
          {%{"from" => "2025-01-01", "to" => "2026-11-09"}, "the period is at most 366 days"},
          {%{"from" => "2026-01-01", "to" => "2026-11-09", "unit" => "30m"}, "the period holds more than 5000 buckets of 30m"}
        ] do
      assert Aggregate.read(params, now: @now) == {:error, {:invalid, message}}
    end

    assert {:ok, %{series: series}} = Aggregate.read(%{"series" => " , "}, now: @now, runs_started_on: fn _date -> {:error, :unreadable} end, lifecycle_facts: @facts)
    assert map_size(series) == 6
    assert Aggregate.units() == ~w(30m 1h 6h day week)
  end
end
