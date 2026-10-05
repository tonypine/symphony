defmodule SymphonyElixir.UsageLimitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.Agent.UsageLimit, as: UsageLimitConfig
  alias SymphonyElixir.UsageLimit

  @now ~U[2026-10-03 03:46:00Z]
  @config %UsageLimitConfig{auto_pause: true, resume_margin_seconds: 120, unknown_reset_retry_seconds: 900}

  defmodule FailingStore do
    def get_usage_limits, do: {:error, :mnesia_down}
  end

  defp info(attrs \\ %{}) do
    Map.merge(
      %{provider: "anthropic", window: "five_hour", scope: :all, resets_at: ~U[2026-10-03 05:00:00Z], utilization: 1.0, source: :rate_limit_event},
      attrs
    )
  end

  def three_hours_behind(utc), do: NaiveDateTime.add(utc, -3 * 3600)

  defp put(existing, info, opts \\ []) do
    UsageLimit.put(existing, info, Keyword.merge([now: @now, config: @config], opts))
  end

  test "limit labels name the provider and the window" do
    assert UsageLimit.limit_label(%{provider: "anthropic", window: "five_hour"}) == "Claude 5-hour limit"
    assert UsageLimit.limit_label(%{provider: "anthropic", window: "seven_day"}) == "Claude weekly limit"
    assert UsageLimit.limit_label(%{provider: "anthropic", window: "seven_day_opus"}) == "Claude weekly Opus limit"
    assert UsageLimit.limit_label(%{provider: "anthropic", window: "seven_day_sonnet"}) == "Claude weekly Sonnet limit"
    assert UsageLimit.limit_label(%{window: nil}) == "Claude usage limit"
    assert UsageLimit.limit_label(%{provider: "openrouter", window: "daily"}) == "OpenRouter daily limit"
    assert UsageLimit.limit_label(%{provider: "openai", window: "five_hour"}) == "openai 5-hour limit"
  end

  describe "an unreachable model API" do
    defp outage(attrs \\ %{}),
      do: Map.merge(%{provider: "anthropic", window: nil, scope: :all, resets_at: nil, utilization: nil, source: :api_unreachable, error: "ENOTFOUND"}, attrs)

    test "holds the provider for a first probe a minute away, ignoring remembered windows" do
      windows = %{{"anthropic", "five_hour"} => %{resets_at: ~U[2026-10-03 05:00:00Z], utilization: 0.99}}

      entry = put(nil, outage(), windows: windows, issue_identifier: "TP-540")

      assert entry == %{
               provider: "anthropic",
               scope: :all,
               reason: "model_api_unreachable",
               window: nil,
               since: @now,
               resets_at: nil,
               resume_at: DateTime.add(@now, 60),
               source: :api_unreachable,
               phase: :paused,
               canary_issue_id: nil,
               issue_identifier: "TP-540",
               utilization: nil,
               error: "ENOTFOUND",
               retry_seconds: 60
             }

      assert put(nil, Map.delete(outage(), :error)).error == "connection error"
    end

    test "each canary that still can't reach the API doubles the wait, up to the unknown-reset interval" do
      first = put(nil, outage())
      later = DateTime.add(@now, 60)

      second = put(UsageLimit.canary(first, "issue-canary"), outage(), now: later)
      assert %{retry_seconds: 120, since: @now, phase: :paused, canary_issue_id: nil} = second
      assert second.resume_at == DateTime.add(later, 120)

      assert put(UsageLimit.canary(%{second | retry_seconds: 600}, "issue-canary"), outage(), now: later).retry_seconds == 900
      assert put(UsageLimit.canary(%{second | retry_seconds: 900}, "issue-canary"), outage(), now: later).retry_seconds == 900
    end

    test "another run finding the same outage, or a usage limit still in force, leaves the hold as it is" do
      first = put(nil, outage())
      assert put(first, outage(%{error: "ECONNREFUSED"}), now: DateTime.add(@now, 30)) == first

      limited = put(nil, info())
      assert put(limited, outage()) == limited
    end

    test "replaces a usage-limit canary and a headroom hold with a fresh outage hold" do
      limit_canary = nil |> put(info()) |> UsageLimit.canary("issue-canary")
      assert %{reason: "model_api_unreachable", retry_seconds: 60, since: @now} = put(limit_canary, outage(), now: @now)

      headroom = %{put(nil, info()) | phase: :headroom, reason: "claude_usage_headroom"}
      assert %{reason: "model_api_unreachable", phase: :paused, resume_at: resume_at} = put(headroom, outage())
      assert resume_at == DateTime.add(@now, 60)
    end

    test "reads as `Claude API unreachable` in labels, banners, blockers and the snapshot" do
      entry = put(nil, outage())

      assert UsageLimit.api_unreachable?(entry)
      assert UsageLimit.api_unreachable?(outage())
      assert UsageLimit.api_unreachable?(%{reason: "claude_usage_limit", source: "api_unreachable"})
      refute UsageLimit.api_unreachable?(put(nil, info()))

      assert UsageLimit.limit_label(entry) == "Claude API unreachable"
      assert UsageLimit.hold_label(entry) == "Claude API unreachable"
      assert UsageLimit.hold_label(%{provider: "anthropic", window: "five_hour"}) == "Claude 5-hour limit reached"
      assert UsageLimit.hold_label(%{provider: "anthropic", window: "seven_day", phase: "headroom"}) == "Claude weekly limit headroom: holding new runs"

      to_local = [to_local: & &1]
      assert UsageLimit.banner(entry, @now, to_local) == "Paused: Claude API unreachable (ENOTFOUND), retries ~03:47"
      assert UsageLimit.banner(Map.delete(entry, :error), @now, to_local) == "Paused: Claude API unreachable, retries ~03:47"

      assert [%{reason: "model_api_unreachable", error: "ENOTFOUND", source: :api_unreachable}] = UsageLimit.snapshot(%{{"anthropic", :all} => entry}, %{})
    end
  end

  describe "banner" do
    # Local time three hours behind UTC, so the date can differ from the UTC one.
    @to_local [to_local: &__MODULE__.three_hours_behind/1]

    test "shows the local resume time alone when it is today" do
      entry = %{provider: "anthropic", window: "five_hour", resume_at: ~U[2026-10-03 17:05:00Z]}

      assert UsageLimit.banner(entry, ~U[2026-10-03 15:00:00Z], @to_local) == "Paused: Claude 5-hour limit, resumes ~14:05"
    end

    test "adds the local date when the resume is not today" do
      entry = %{provider: "anthropic", window: "seven_day", resume_at: "2026-10-05T12:30:00Z"}

      assert UsageLimit.banner(entry, ~U[2026-10-03 15:00:00Z], @to_local) == "Paused: Claude weekly limit, resumes ~Oct 5 09:30"
    end

    test "compares local dates, not UTC ones" do
      # 01:30 UTC on the 4th is 22:30 on the 3rd locally, the same local day as 15:00 UTC on the 3rd.
      entry = %{provider: "anthropic", window: "five_hour", resume_at: ~U[2026-10-04 01:30:00Z]}

      assert UsageLimit.banner(entry, ~U[2026-10-03 15:00:00Z], @to_local) == "Paused: Claude 5-hour limit, resumes ~22:30"
    end

    test "adds the date when a reset an hour ahead falls after midnight" do
      # The last hour before midnight on a host in UTC, as on CI.
      now = ~U[2026-10-04 23:03:00Z]
      paused = %{provider: "anthropic", window: "five_hour", resume_at: ~U[2026-10-05 00:03:00Z]}
      headroom = %{provider: "anthropic", window: "five_hour", phase: :headroom, utilization: 0.92, resets_at: ~U[2026-10-05 00:03:00Z]}

      assert UsageLimit.banner(paused, now, to_local: & &1) == "Paused: Claude 5-hour limit, resumes ~Oct 5 00:03"
      assert UsageLimit.banner(headroom, now, to_local: & &1) == "Holding new runs: Claude at 92%, resets ~Oct 5 00:03"
    end

    test "uses the host time zone by default and drops an unreadable resume time" do
      now = DateTime.utc_now()

      local =
        now
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()
        |> :calendar.universal_time_to_local_time()
        |> NaiveDateTime.from_erl!()

      expected = local |> NaiveDateTime.to_time() |> Calendar.strftime("%H:%M")

      assert UsageLimit.banner(%{provider: "anthropic", window: "five_hour", resume_at: now}, now) ==
               "Paused: Claude 5-hour limit, resumes ~#{expected}"

      assert UsageLimit.banner(%{provider: "anthropic", window: "five_hour", resume_at: "soon"}, now) == "Paused: Claude 5-hour limit"
      assert UsageLimit.banner(%{provider: "anthropic", window: "five_hour"}, now) == "Paused: Claude 5-hour limit"
    end
  end

  test "snapshot lists holds soonest first with the window's utilization" do
    later = put(nil, info(%{window: "seven_day", resets_at: ~U[2026-10-05 00:00:00Z]}))
    sooner = put(nil, info(), issue_identifier: "TP-248")
    windows = %{{"anthropic", "five_hour"} => %{resets_at: ~U[2026-10-03 05:00:00Z], utilization: 1.0}}

    assert [first, second] = UsageLimit.snapshot(%{{"anthropic", :all} => later, {"anthropic", "x"} => sooner}, windows)

    assert first == %{
             provider: "anthropic",
             scope: :all,
             reason: "claude_usage_limit",
             window: "five_hour",
             phase: :paused,
             since: @now,
             resets_at: ~U[2026-10-03 05:00:00Z],
             resume_at: ~U[2026-10-03 05:02:00Z],
             source: :rate_limit_event,
             issue_identifier: "TP-248",
             utilization: 1.0
           }

    # Without a window seen since (after a restart), the hold's own utilization stands.
    assert %{window: "seven_day", utilization: 1.0} = second
    assert UsageLimit.snapshot(%{}, windows) == []
  end

  test "key defaults to the anthropic provider and the whole plan" do
    assert UsageLimit.key(%{}) == {"anthropic", :all}
    assert UsageLimit.key(%{provider: "openai", scope: "opus"}) == {"openai", "opus"}
  end

  test "a known reset resumes after the margin" do
    entry = put(nil, info(), issue_identifier: "TP-248")

    assert %{
             provider: "anthropic",
             scope: :all,
             reason: "claude_usage_limit",
             window: "five_hour",
             since: @now,
             resets_at: ~U[2026-10-03 05:00:00Z],
             resume_at: ~U[2026-10-03 05:02:00Z],
             source: :rate_limit_event,
             phase: :paused,
             issue_identifier: "TP-248"
           } = entry
  end

  test "a Codex hold is keyed and named for the openai provider" do
    entry = put(nil, info(%{provider: "openai", window: "primary", source: :codex_error}))

    assert %{provider: "openai", scope: :all, reason: "codex_usage_limit", window: "primary"} = entry
    assert UsageLimit.key(entry) == {"openai", :all}
  end

  test "for_agent_kind makes Codex runs openai and leaves other runs alone" do
    profile = %{kind: :implementation, model: nil, effort: nil, provider: "anthropic"}

    assert UsageLimit.for_agent_kind(profile, "codex").provider == "openai"
    assert UsageLimit.for_agent_kind(profile, "claude") == profile
    refute UsageLimit.covers?({"anthropic", :all}, UsageLimit.for_agent_kind(profile, "codex"))
    assert UsageLimit.covers?({"openai", :all}, UsageLimit.for_agent_kind(profile, "codex"))
  end

  test "an unknown reset uses the remembered window, else the retry interval" do
    windows =
      UsageLimit.remember_windows(%{}, %{
        "five_hour" => %{resets_at: ~U[2026-10-03 06:00:00Z], utilization: 0.5},
        "seven_day" => %{resets_at: ~U[2026-10-05 00:00:00Z], utilization: 0.99},
        "stale" => %{resets_at: ~U[2026-10-01 00:00:00Z], utilization: 1.0},
        :ignored => %{resets_at: ~U[2026-10-09 00:00:00Z]}
      })

    refute Map.has_key?(windows, {"anthropic", :ignored})

    # No window named: the window closest to used up with a future reset.
    assert put(nil, info(%{window: nil, resets_at: nil}), windows: windows).resume_at == ~U[2026-10-05 00:02:00Z]
    # A named window uses its own reset time.
    assert put(nil, info(%{resets_at: nil}), windows: windows).resume_at == ~U[2026-10-03 06:02:00Z]
    # Nothing remembered for the window.
    assert put(nil, info(%{window: "seven_day_opus", resets_at: nil}), windows: windows).resume_at == DateTime.add(@now, 900)
    assert put(nil, info(%{resets_at: nil})).resume_at == DateTime.add(@now, 900)
  end

  test "a refresh keeps since, and only a known reset brings the resume time forward" do
    existing = put(nil, info(%{resets_at: ~U[2026-10-03 07:00:00Z]}))
    later = ~U[2026-10-03 04:00:00Z]

    refreshed = put(existing, info(%{resets_at: nil}), now: later)
    assert refreshed.since == @now
    assert refreshed.resume_at == ~U[2026-10-03 07:02:00Z]

    assert put(existing, info(), now: later).resume_at == ~U[2026-10-03 05:02:00Z]

    early = put(nil, info(%{resets_at: ~U[2026-10-03 03:50:00Z]}))
    assert put(early, info(%{resets_at: nil}), now: later).resume_at == DateTime.add(later, 900)
  end

  test "covers a run by provider, and a model scope only its model family" do
    opus = UsageLimit.put(nil, info(%{scope: "opus", window: "seven_day_opus"}), now: @now, config: @config)

    assert UsageLimit.covers?({"anthropic", :all}, %{provider: "anthropic", model: nil})
    assert UsageLimit.covers?({"anthropic", :all}, %{model: "claude-sonnet-5-5"})
    refute UsageLimit.covers?({"anthropic", :all}, %{provider: "openrouter", model: "openai/gpt-5"})
    assert UsageLimit.covers?(opus, %{provider: "anthropic", model: "Claude-Opus-5-5"})
    refute UsageLimit.covers?(opus, %{provider: "anthropic", model: "claude-sonnet-5-5"})
    refute UsageLimit.covers?(opus, %{provider: "anthropic", model: nil})
  end

  test "holding returns the covering hold that resumes last" do
    all = put(nil, info())
    opus = put(nil, info(%{scope: "opus", resets_at: ~U[2026-10-08 00:00:00Z]}))
    limits = %{{"anthropic", :all} => all, {"anthropic", "opus"} => opus}

    assert UsageLimit.holding(limits, %{provider: "anthropic", model: "claude-opus-5-5"}) == opus
    assert UsageLimit.holding(limits, %{provider: "anthropic", model: "claude-sonnet-5-5"}) == all
    assert UsageLimit.holding(limits, %{provider: "openrouter", model: "x"}) == nil
  end

  test "persisted_holding reads the run store and ignores store errors" do
    on_exit(fn -> RunStore.put_usage_limits(%{}) end)
    entry = put(nil, info())
    assert :ok = RunStore.put_usage_limits(%{{"anthropic", :all} => entry})

    assert UsageLimit.persisted_holding(%{provider: "anthropic", model: nil}) == entry
    assert UsageLimit.persisted_holding(%{provider: "anthropic", model: nil}, FailingStore) == nil
  end

  test "remaining_ms and scope_label" do
    entry = put(nil, info())
    assert UsageLimit.remaining_ms(entry, @now) == DateTime.diff(entry.resume_at, @now, :millisecond)
    assert UsageLimit.remaining_ms(entry, ~U[2026-10-04 00:00:00Z]) == 0
    assert UsageLimit.scope_label(:all) == "all"
    assert UsageLimit.scope_label("opus") == "opus"
  end

  describe "agent.usage_limit config" do
    test "defaults to auto pause with a 120s margin and a 900s unknown-reset retry" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      assert %UsageLimitConfig{auto_pause: true, resume_margin_seconds: 120, unknown_reset_retry_seconds: 900} =
               Config.settings!().agent.usage_limit
    end

    test "reads the three keys" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        agent_usage_limit: %{auto_pause: false, resume_margin_seconds: 0, unknown_reset_retry_seconds: 60}
      )

      assert %UsageLimitConfig{auto_pause: false, resume_margin_seconds: 0, unknown_reset_retry_seconds: 60} =
               Config.settings!().agent.usage_limit
    end

    test "headroom_utilization is off by default and takes a share in (0, 1]" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      assert %UsageLimitConfig{headroom_utilization: nil} = Config.settings!().agent.usage_limit

      for value <- [0.9, 1] do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          agent_usage_limit: %{headroom_utilization: value}
        )

        assert Config.settings!().agent.usage_limit.headroom_utilization == value / 1
      end
    end

    test "rejects invalid values and unknown keys" do
      for {usage_limit, key} <- [
            {%{headroom_utilization: 0}, "agent.usage_limit.headroom_utilization"},
            {%{headroom_utilization: 1.5}, "agent.usage_limit.headroom_utilization"},
            {%{headroom_utilization: "high"}, "agent.usage_limit.headroom_utilization"},
            {%{auto_pause: "sometimes"}, "agent.usage_limit.auto_pause"},
            {%{resume_margin_seconds: -1}, "agent.usage_limit.resume_margin_seconds"},
            {%{unknown_reset_retry_seconds: 59}, "agent.usage_limit.unknown_reset_retry_seconds"},
            {%{unknown_reset_retry_seconds: "soon"}, "agent.usage_limit.unknown_reset_retry_seconds"},
            {%{resume_after: 5}, "agent.usage_limit"}
          ] do
        write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_usage_limit: usage_limit)
        assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
        assert message =~ key
      end
    end
  end

  describe "RunStore" do
    test "usage limits round-trip next to the operator pause" do
      on_exit(fn ->
        RunStore.put_usage_limits(%{})
        RunStore.set_paused(false, nil)
      end)

      entry = put(nil, info())
      assert RunStore.get_usage_limits() == %{}
      assert :ok = RunStore.set_paused(true, "maintenance")
      assert :ok = RunStore.put_usage_limits(%{{"anthropic", :all} => entry})
      assert RunStore.get_usage_limits() == %{{"anthropic", :all} => entry}
      assert %{paused: true, reason: "maintenance"} = RunStore.get_paused()

      assert :ok = RunStore.put_usage_limits(%{})
      assert RunStore.get_usage_limits() == %{}
      assert %{paused: true} = RunStore.get_paused()
      assert {:error, :invalid_usage_limits} = RunStore.put_usage_limits(nil)
    end
  end

  test "a canary hold lets only its canary through, and a refresh pauses it again" do
    canary = put(nil, info()) |> UsageLimit.canary("issue-canary")
    profile = %{provider: "anthropic", model: "claude-opus-5-5"}

    assert %{phase: :canary, canary_issue_id: "issue-canary"} = canary
    assert UsageLimit.canary?(canary, "issue-canary")
    refute UsageLimit.canary?(canary, "issue-other")
    refute UsageLimit.canary?(put(nil, info()), nil)

    assert UsageLimit.holding(%{{"anthropic", :all} => canary}, profile, "issue-other") == canary
    assert UsageLimit.holding(%{{"anthropic", :all} => canary}, profile) == canary
    assert UsageLimit.holding(%{{"anthropic", :all} => canary}, profile, "issue-canary") == nil

    later = DateTime.add(@now, 4 * 3600)
    repaused = put(canary, info(%{resets_at: nil, window: nil}), now: later)
    assert %{phase: :paused, canary_issue_id: nil, since: @now, resume_at: resume_at} = repaused
    assert resume_at == DateTime.add(later, 900)

    assert %{phase: :paused, canary_issue_id: nil} = UsageLimit.paused(canary)
  end

  describe "headroom" do
    defp warning(utilization, resets_at \\ ~U[2026-10-03 05:00:00Z]),
      do: %{status: "allowed_warning", utilization: utilization, resets_at: resets_at}

    defp headroom(existing, info), do: UsageLimit.put_headroom(existing, info, now: @now, config: @config, issue_identifier: "TP-330")

    test "crossings are the allowed_warning windows at or above the threshold that reset later" do
      windows = %{
        "five_hour" => warning(0.9),
        "seven_day_opus" => warning(0.95, ~U[2026-10-08 00:00:00Z]),
        "seven_day" => warning(0.89),
        "seven_day_sonnet" => %{warning(0.99) | status: "allowed"},
        "overage" => warning(0.99, @now),
        "other" => warning(nil)
      }

      assert [
               %{provider: "anthropic", window: "five_hour", scope: :all, resets_at: ~U[2026-10-03 05:00:00Z], utilization: 0.9, source: :rate_limit_event},
               %{window: "seven_day_opus", scope: "opus", utilization: 0.95}
             ] = UsageLimit.headroom_crossings(windows, 0.9, @now)

      assert UsageLimit.headroom_crossings(windows, 1.0, @now) == []
    end

    test "a headroom hold lasts until the reset plus the margin, a later window refreshes it and the same window raises its utilization" do
      [info] = UsageLimit.headroom_crossings(%{"five_hour" => warning(0.92)}, 0.9, @now)
      entry = headroom(nil, info)

      assert %{
               reason: "claude_usage_headroom",
               phase: :headroom,
               window: "five_hour",
               since: @now,
               resets_at: ~U[2026-10-03 05:00:00Z],
               resume_at: ~U[2026-10-03 05:02:00Z],
               utilization: 0.92,
               issue_identifier: "TP-330"
             } = entry

      assert headroom(entry, %{info | utilization: 0.97}) == %{entry | utilization: 0.97}
      assert headroom(%{entry | utilization: 0.97}, info) == %{entry | utilization: 0.97}
      assert headroom(entry, %{info | window: "seven_day", utilization: 0.99, resets_at: ~U[2026-10-03 04:00:00Z]}) == entry

      later = headroom(entry, %{info | window: "seven_day", resets_at: ~U[2026-10-05 00:00:00Z]})
      assert %{window: "seven_day", since: @now, resume_at: ~U[2026-10-05 00:02:00Z]} = later
      assert UsageLimit.paused(later) == later
    end

    test "a headroom hold holds new runs but not landing runs or continuations" do
      [info] = UsageLimit.headroom_crossings(%{"five_hour" => warning(0.92)}, 0.9, @now)
      entry = headroom(nil, info)
      limits = %{{"anthropic", :all} => entry}
      paused = put(nil, info())

      assert UsageLimit.headroom?(entry)
      assert UsageLimit.headroom?(%{phase: "headroom"})
      refute UsageLimit.headroom?(paused)

      assert UsageLimit.holding(limits, %{provider: "anthropic", kind: :implementation}) == entry
      assert UsageLimit.holding(limits, %{provider: "anthropic", kind: :landing}) == nil
      assert UsageLimit.holding(limits, %{provider: "anthropic", kind: "landing"}) == nil
      assert UsageLimit.holding(limits, %{provider: "anthropic", kind: :implementation, continuation: true}) == nil
      refute UsageLimit.holds?(entry, %{provider: "openrouter", kind: :implementation})

      assert UsageLimit.holds?(paused, %{provider: "anthropic", kind: :landing})
      assert UsageLimit.holds?(paused, %{provider: "anthropic", continuation: true})
    end

    test "scope_for_window holds the weekly model windows to their model family" do
      assert UsageLimit.scope_for_window("seven_day_opus") == "opus"
      assert UsageLimit.scope_for_window("seven_day_sonnet") == "sonnet"
      assert UsageLimit.scope_for_window("five_hour") == :all
      assert UsageLimit.scope_for_window(nil) == :all
    end

    test "the banner names the utilization and the local reset time" do
      to_local = [to_local: &__MODULE__.three_hours_behind/1]
      hold = %{provider: "anthropic", window: "five_hour", phase: :headroom, utilization: 0.914, resets_at: ~U[2026-10-03 17:05:00Z], resume_at: ~U[2026-10-03 17:07:00Z]}

      assert UsageLimit.banner(hold, ~U[2026-10-03 12:00:00Z], to_local) == "Holding new runs: Claude at 91%, resets ~14:05"

      assert UsageLimit.banner(%{hold | phase: "headroom", resets_at: "2026-10-04T17:05:00Z"}, ~U[2026-10-03 12:00:00Z], to_local) ==
               "Holding new runs: Claude at 91%, resets ~Oct 4 14:05"

      assert UsageLimit.banner(%{provider: "anthropic", window: "five_hour", phase: "headroom"}, @now) == "Holding new runs: Claude 5-hour limit"
    end
  end
end
