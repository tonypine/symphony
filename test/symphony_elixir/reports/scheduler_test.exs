defmodule SymphonyElixir.Reports.SchedulerTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Reports.Triggers
  alias SymphonyElixir.{Pauses, Reports, TicketEvents}
  alias SymphonyElixir.Reports.Scheduler
  alias SymphonyElixir.TicketEvents.Event

  @repo "fixture"
  @now ~U[2026-11-12 13:00:00Z]

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp agent(value) do
    {:ok, agent} = Agent.start_link(fn -> value end)
    agent
  end

  # A scheduler whose clock, settings, newest report and usage-limit hold the test sets, and whose
  # runs are refs the test ends by sending their result.
  defp start!(opts) do
    test = self()
    clock = agent(Keyword.get(opts, :now, @now))
    settings = agent(Keyword.get(opts, :settings, %Schema.Reports{}))
    latest = agent(Keyword.get(opts, :latest, nil))
    hold = agent(nil)

    launch = fn period, launch_opts ->
      ref = make_ref()
      send(test, {:launched, period, launch_opts, ref})
      {:ok, %{run_id: "report-#{inspect(ref)}"}, %{ref: ref}}
    end

    defaults = [
      name: :"report_scheduler_#{System.unique_integer([:positive])}",
      subscribe: false,
      now: fn -> Agent.get(clock, & &1) end,
      settings: fn -> Agent.get(settings, & &1) end,
      latest_report: fn -> Agent.get(latest, & &1) end,
      holding: fn model -> Agent.get(hold, &(&1 && Map.put(&1, :model, model))) end,
      launch: launch,
      read_event: fn notice -> {:ok, notice.event, Map.get(notice, :events, [notice.event])} end,
      published: fn -> send(test, :published) end
    ]

    opts = Keyword.merge(defaults, Keyword.drop(opts, [:now, :settings, :latest]))
    pid = start_supervised!(Supervisor.child_spec({Scheduler, opts}, id: opts[:name]))
    :sys.get_state(pid)
    %{pid: pid, clock: clock, settings: settings, latest: latest, hold: hold}
  end

  defp set(agent, value), do: Agent.update(agent, fn _old -> value end)

  defp report_ending(to), do: %Event{id: "rep", type: "report.published", at: DateTime.add(to, 5), payload: %{period: %{from: "2026-11-12T06:00:00Z", to: DateTime.to_iso8601(to)}}}

  defp event(type, payload, issue_id \\ "ticket-1", id \\ nil),
    do: %Event{id: id || "ev-#{System.unique_integer([:positive])}", type: type, issue_id: issue_id, repo_key: @repo, at: @now, payload: payload}

  defp notice(%Event{} = event, events \\ nil), do: %{type: event.type, issue_id: event.issue_id, event_id: event.id, event: event, events: events || [event]}

  defp triggers(on), do: struct!(Triggers, Map.new(Triggers.names(), &{&1, &1 in on}))

  defp reports(cadence, on), do: %Schema.Reports{cadence: cadence, triggers: triggers(on)}

  defp sync(%{pid: pid}), do: :sys.get_state(pid)

  describe "the cadence" do
    test "startup checks the schedule once: a boundary passed since the last report runs one covering since it" do
      _scheduler = start!(latest: report_ending(~U[2026-11-12 11:30:00Z]))

      assert_receive {:launched, %{from: ~U[2026-11-12 11:30:00Z], to: @now}, launch_opts, _ref}
      assert launch_opts[:model] == "claude-haiku-5-5"
      assert is_function(launch_opts[:start_task], 1)
    end

    test "fires on the cadence boundary, once per boundary, and wakes at the next full hour" do
      settings = %Schema.Reports{cadence: "hourly"}
      scheduler = start!(settings: settings, latest: report_ending(@now))
      refute_received {:launched, _period, _opts, _ref}

      set(scheduler.clock, ~U[2026-11-12 14:00:00Z])
      send(scheduler.pid, :cadence)
      assert_receive {:launched, %{from: @now, to: ~U[2026-11-12 14:00:00Z]}, _opts, ref}
      send(scheduler.pid, {ref, {:error, :not_published}})
      sync(scheduler)
      refute_received :published

      # The boundary already ran, though no report ended after it.
      set(scheduler.clock, ~U[2026-11-12 14:10:00Z])
      send(scheduler.pid, :cadence)
      state = sync(scheduler)
      refute_received {:launched, _period, _opts, _ref}
      assert Process.read_timer(state.timer) in 2_999_000..3_000_000

      assert Scheduler.boundary("six_hours", ~U[2026-11-12 17:59:59Z]) == ~U[2026-11-12 12:00:00Z]
      assert Scheduler.boundary("daily", ~U[2026-11-12 17:59:59Z]) == ~U[2026-11-12 00:00:00Z]
      assert Scheduler.boundary("none", @now) == nil
      assert Scheduler.interval("hourly") == 3_600
    end

    test "with no report yet a run covers one interval back, and the cadence none runs nothing on its own" do
      _scheduler = start!(settings: %Schema.Reports{cadence: "daily"})
      assert_receive {:launched, %{from: ~U[2026-11-11 13:00:00Z], to: @now}, _opts, _ref}

      scheduler = start!(settings: %Schema.Reports{cadence: "none"})
      refute_received {:launched, _period, _opts, _ref}

      # A trigger with no report yet and no cadence covers six hours.
      send(scheduler.pid, {:ticket_event, notice(event("phase.entered", %{to: "Done", from: "Merging"}))})
      assert_receive {:launched, %{from: ~U[2026-11-12 07:00:00Z], to: @now}, _opts, _ref}
    end
  end

  describe "the triggers" do
    test "each trigger fires on its fixture event, and the others fire nothing" do
      ci_fix = fn id -> event("phase.entered", %{to: "CI Fix", from: "QA"}, "ticket-1", id) end
      loop = Enum.map(1..5, &ci_fix.("ci-#{&1}"))

      assert Scheduler.trigger(event("phase.entered", %{to: "Done", from: "Merging"}), []) == :ticket_shipped
      assert Scheduler.trigger(event("phase.entered", %{"to" => "done", "from" => "Epic Review"}), []) == :epic_closed
      assert Scheduler.trigger(Enum.at(loop, 3), loop) == :ci_fix_loop
      assert Scheduler.trigger(Enum.at(loop, 2), loop) == nil
      assert Scheduler.trigger(Enum.at(loop, 4), loop) == nil
      assert Scheduler.ci_fix_loop_past() == 3
      assert Scheduler.trigger(event("rule.action", %{rule: "self-heal", action: "filed_ticket"}), []) == :self_heal_filed
      assert Scheduler.trigger(event("rule.action", %{rule: "PR watcher R22", action: "moved"}), []) == nil
      assert Scheduler.trigger(event("pause.reason_cleared", %{reason: "build"}, "symphony"), []) == :release_installed
      assert Scheduler.trigger(event("pause.cleared", %{cleared: [%{reason: :build}]}, "symphony"), []) == :release_installed
      assert Scheduler.trigger(event("pause.cleared", %{cleared: [%{reason: :person}]}, "symphony"), []) == nil
      usage_limit = %{reason: :environment, set_by: %{kind: :symphony, name: "Symphony"}}
      assert Scheduler.trigger(event("pause.set", usage_limit, "symphony"), []) == :paused_by_rule
      assert Scheduler.trigger(event("pause.set", %{"reason" => "build", "set_by" => %{"kind" => "rule", "name" => "update hold"}}, "symphony"), []) == :paused_by_rule
      assert Scheduler.trigger(event("pause.set", %{reason: :person, set_by: %{kind: :person, name: "Director"}}, "symphony"), []) == nil
      assert Scheduler.trigger(event("pause.set", %{reason: :environment}, "symphony"), []) == :paused_by_rule
      assert Scheduler.trigger(event("phase.entered", %{to: "QA"}), []) == nil
      assert Scheduler.trigger(event("phase.entered", %{}), []) == nil
      assert Scheduler.trigger(event("pause.set", %{reason: :ticket}), []) == nil
      assert Scheduler.trigger(event("verdict.recorded", %{kind: "qa"}), []) == nil
    end

    test "an enabled trigger starts a report at once; a disabled one or an unknown event starts none" do
      scheduler = start!(settings: reports("none", [:epic_closed]), latest: report_ending(~U[2026-11-12 12:00:00Z]))

      send(scheduler.pid, {:ticket_event, notice(event("phase.entered", %{to: "Done", from: "Merging"}))})
      send(scheduler.pid, {:ticket_event, %{type: "run.started"}})
      send(scheduler.pid, :unrelated)
      sync(scheduler)
      refute_received {:launched, _period, _opts, _ref}

      send(scheduler.pid, {:ticket_event, notice(event("phase.entered", %{to: "Done", from: "Epic Review"}))})
      assert_receive {:launched, %{from: ~U[2026-11-12 12:00:00Z], to: @now}, _opts, ref}
      send(scheduler.pid, {ref, {:ok, :report}})
      assert_receive :published

      # With every trigger off, no event is read at all.
      set(scheduler.settings, %Schema.Reports{cadence: "none", triggers: triggers([])})
      send(scheduler.pid, {:ticket_event, %{type: "phase.entered", unreadable: true}})
      sync(scheduler)
    end

    test "two triggers inside one minute produce one run, and a later one another" do
      scheduler = start!(settings: reports("none", Triggers.names()), latest: report_ending(~U[2026-11-12 12:00:00Z]))
      assert Scheduler.coalesce_ms() == 60_000

      send(scheduler.pid, {:ticket_event, notice(event("phase.entered", %{to: "Done"}))})
      assert_receive {:launched, _period, _opts, ref}
      send(scheduler.pid, {ref, {:ok, :report}})
      assert_receive :published

      set(scheduler.clock, ~U[2026-11-12 13:00:30Z])

      log =
        capture_log([level: :debug], fn ->
          send(scheduler.pid, {:ticket_event, notice(event("rule.action", %{action: "filed_ticket"}))})
          sync(scheduler)
        end)

      assert log =~ "coalesced"
      refute_received {:launched, _period, _opts, _ref}

      set(scheduler.clock, ~U[2026-11-12 13:01:01Z])
      set(scheduler.latest, report_ending(@now))
      send(scheduler.pid, {:ticket_event, notice(event("pause.set", %{set_by: %{kind: :rule}}, "symphony"))})
      assert_receive {:launched, %{from: @now, to: ~U[2026-11-12 13:01:01Z]}, _opts, _ref}
    end
  end

  describe "one run at a time" do
    test "a boundary or a trigger while a run goes waits for it, and starts once it ends" do
      scheduler = start!(settings: reports("hourly", [:ticket_shipped]), latest: report_ending(~U[2026-11-12 12:00:00Z]))
      assert_receive {:launched, _period, _opts, ref}

      set(scheduler.clock, ~U[2026-11-12 14:00:00Z])
      send(scheduler.pid, :cadence)
      send(scheduler.pid, {:ticket_event, notice(event("phase.entered", %{to: "Done"}))})
      sync(scheduler)
      refute_received {:launched, _period, _opts, _ref}

      set(scheduler.latest, report_ending(@now))
      send(scheduler.pid, {ref, {:ok, :report}})
      assert_receive :published
      assert_receive {:launched, %{from: @now, to: ~U[2026-11-12 14:00:00Z]}, _opts, second}
      refute_received {:launched, _period, _opts, _ref}

      # A run that crashes ends like any other.
      log =
        capture_log(fn ->
          send(scheduler.pid, {:DOWN, second, :process, self(), :boom})
          assert %{running: nil, queued: nil} = sync(scheduler)
        end)

      assert log =~ "Report run ended without a report"
    end

    test "a run waits for a usage-limit hold on its model, then starts" do
      scheduler = start!(settings: reports("none", [:ticket_shipped]), latest: report_ending(~U[2026-11-12 12:00:00Z]))
      set(scheduler.hold, %{resume_at: ~U[2026-11-12 13:05:00Z]})

      send(scheduler.pid, {:ticket_event, notice(event("phase.entered", %{to: "Done"}))})
      state = sync(scheduler)
      refute_received {:launched, _period, _opts, _ref}
      assert Process.read_timer(state.hold_timer) in 299_000..300_000

      # Another trigger while it waits starts nothing more.
      set(scheduler.clock, ~U[2026-11-12 13:02:00Z])
      send(scheduler.pid, {:ticket_event, notice(event("phase.entered", %{to: "Done"}))})
      sync(scheduler)
      refute_received {:launched, _period, _opts, _ref}

      set(scheduler.hold, nil)
      set(scheduler.clock, ~U[2026-11-12 13:05:00Z])
      send(scheduler.pid, :hold_over)
      assert_receive {:launched, %{to: ~U[2026-11-12 13:05:00Z]}, [model: "claude-haiku-5-5", start_task: _start], _ref}
    end

    test "a period with nothing to cite, a run that can't start and an empty period start nothing" do
      test = self()

      log =
        capture_log([level: :debug], fn ->
          scheduler = start!(launch: fn _period, _opts -> send(test, :tried) && {:error, :no_events} end)
          assert_receive :tried
          assert %{running: nil} = sync(scheduler)

          no_key = fn _period, _opts -> send(test, :tried) && {:error, :missing_anthropic_api_key} end
          scheduler = start!(launch: no_key)
          assert_receive :tried
          assert %{running: nil} = sync(scheduler)
        end)

      assert log =~ "no notable event since"
      assert log =~ "could not start: :missing_anthropic_api_key"

      scheduler = start!(settings: %Schema.Reports{cadence: "none"}, latest: report_ending(@now))
      send(scheduler.pid, {:ticket_event, notice(event("phase.entered", %{to: "Done"}))})
      assert %{running: nil} = sync(scheduler)
      refute_received {:launched, _period, _opts, _ref}
    end
  end

  describe "with Symphony's own store and settings" do
    test "reads the announced event from its stream, the settings from symphony.yml and the newest report from the ledger" do
      File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "reports:\n  cadence: none\n")
      Cache.clear()
      test = self()

      launch = fn period, _opts ->
        ref = make_ref()
        send(test, {:launched, period, ref})
        {:ok, %{run_id: "report-1"}, %{ref: ref}}
      end

      pid = start_supervised!({Scheduler, name: :report_scheduler_store_test, launch: launch})
      :sys.get_state(pid)
      refute_received {:launched, _period, _ref}

      :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "ticket-1", issue_identifier: "FIX-1", phase: "Merging"})
      {:ok, shipped} = TicketEvents.record(@repo, "ticket-1", "phase.entered", %{to: "Done", from: "Merging"})
      assert_receive {:launched, %{to: to}, ref}, 1_000
      assert DateTime.diff(to, shipped.at, :second) in 0..5
      send(pid, {ref, {:ok, :report}})

      # An event the stream no longer holds, and a notice without a stream, read as nothing.
      send(pid, {:ticket_event, %{type: "phase.entered", issue_id: "ticket-1", event_id: "gone"}})
      send(pid, {:ticket_event, %{type: "phase.entered"}})
      :sys.get_state(pid)
      refute_received {:launched, _period, _ref}

      stop_supervised!(Scheduler)
      period = %{from: "2026-11-12T00:00:00Z", to: DateTime.to_iso8601(DateTime.utc_now())}
      payload = %{run_id: "r", model: "m", period: period, tickets: [], events: [], sentences: ["x"], text: "x"}
      payload = Map.put(payload, :citations, [])
      {:ok, published} = TicketEvents.build(nil, "reports", "report.published", payload, run_id: "r")
      {:ok, _stored} = RunStore.append_report_event(published)
      assert Reports.latest().payload.run_id == "r"

      pid = start_supervised!({Scheduler, name: :report_scheduler_store_test, launch: launch})
      {:ok, _pause} = Pauses.set(:symphony, %{kind: :environment, waits_on: %{condition: "usage_limit:anthropic"}, text: "The usage limit is reached."})
      assert_receive {:launched, %{from: from}, _ref}, 1_000
      assert DateTime.compare(from, DateTime.add(DateTime.utc_now(), -60)) == :gt
      :sys.get_state(pid)
    end

    test "with every default, a startup with nothing to cite writes nothing" do
      pid = start_supervised!({Scheduler, name: :report_scheduler_default_test, subscribe: false})
      assert %{running: nil, queued: nil} = :sys.get_state(pid)
    end

    test "starts with the application unless turned off" do
      Application.put_env(:symphony_elixir, :report_scheduler, true)
      on_exit(fn -> Application.put_env(:symphony_elixir, :report_scheduler, false) end)
      assert Scheduler in SymphonyElixir.Application.child_specs_for_runtime(%{})

      Application.put_env(:symphony_elixir, :report_scheduler, false)
      refute Scheduler in SymphonyElixir.Application.child_specs_for_runtime(%{})
    end
  end
end
