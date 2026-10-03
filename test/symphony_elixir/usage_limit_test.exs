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

  defp put(existing, info, opts \\ []) do
    UsageLimit.put(existing, info, Keyword.merge([now: @now, config: @config], opts))
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

    test "rejects invalid values and unknown keys" do
      for {usage_limit, key} <- [
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
end
