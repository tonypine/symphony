defmodule SymphonyElixir.TicketEvents.NotableTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TicketEvents.{Event, Notable}

  @now ~U[2026-11-09 18:00:00.000000Z]
  @ticket "ticket-1"

  defp event(type, payload \\ %{}, opts \\ []) do
    %Event{
      id: Keyword.get(opts, :id, "#{type}-#{System.unique_integer([:positive])}"),
      issue_id: Keyword.get(opts, :issue_id, @ticket),
      at: Keyword.get(opts, :at, ~U[2026-11-09 12:00:00.000000Z]),
      type: type,
      payload: payload
    }
  end

  defp context(events \\ []), do: %{events: events, now: @now}
  defp holds?(rule, event, events \\ []), do: Notable.holds?(rule, event, context(events))

  test "the rule set is the list the moduledoc names, and an event no rule holds for is not notable" do
    assert Notable.rules() == [:verdict, :phase_move, :question, :long_pause, :rule_action, :ticket_filed, :shipped_or_cancelled, :release_installed, :factory_paused, :situation]
    assert Notable.pause_threshold_ms() == 15 * 60_000
    refute Notable.notable?(event("run.started", %{run_id: "r", run_kind: "implementation"}), context())
    refute Notable.notable?(event("step.completed"), context())
    assert Notable.notable?(event("verdict.recorded", %{kind: "qa", outcome: "pass"}), context())
  end

  test "verdict: every verdict recorded" do
    assert holds?(:verdict, event("verdict.recorded", %{kind: "code_review", outcome: "approve"}))
    refute holds?(:verdict, event("run.ended"))
  end

  test "phase_move: a phase entered, a person's move or cancel, never on Symphony's own stream" do
    assert holds?(:phase_move, event("phase.entered", %{to: "Code Review"}))
    assert holds?(:phase_move, event("ticket.moved", %{from: "QA", to: "Rework"}))
    assert holds?(:phase_move, event("ticket.cancelled", %{from: "Todo", to: "Canceled"}))
    refute holds?(:phase_move, event("phase.entered", %{to: "Todo"}, issue_id: "symphony"))
    refute holds?(:phase_move, event("drift.detected"))
  end

  test "question: asked or answered, the legacy decisions too, not a withdrawal" do
    for type <- ["question.asked", "question.answered", "decision.requested", "decision.recorded"], do: assert(holds?(:question, event(type)), type)
    refute holds?(:question, event("question.withdrawn"))
  end

  test "long_pause: a ticket's pause that lasted the threshold, or has so far" do
    set = event("pause.set", %{reason: "ticket"}, id: "set", at: ~U[2026-11-09 12:00:00.000000Z])
    short_clear = event("pause.cleared", %{}, id: "clear", at: ~U[2026-11-09 12:05:00.000000Z])
    long_clear = event("pause.cleared", %{}, id: "clear", at: ~U[2026-11-09 12:15:00.000000Z])

    refute holds?(:long_pause, set, [set, short_clear])
    assert holds?(:long_pause, set, [set, long_clear])
    # Still paused: the time it has lasted until the read.
    assert holds?(:long_pause, set, [set])
    refute Notable.holds?(:long_pause, set, %{events: [set], now: ~U[2026-11-09 12:10:00.000000Z]})
    # A clear before the pause is another pause's.
    assert holds?(:long_pause, set, [event("pause.cleared", %{}, at: ~U[2026-11-09 11:00:00.000000Z]), set])
    refute holds?(:long_pause, %{set | at: nil}, [set])
    refute holds?(:long_pause, %{set | issue_id: "symphony"}, [set])
    refute holds?(:long_pause, event("pause.reason_added"), [])
  end

  test "rule_action: every rule.action" do
    assert holds?(:rule_action, event("rule.action", %{rule: "CI wait", action: "paused"}))
    refute holds?(:rule_action, event("pause.set"))
  end

  test "ticket_filed: a split-off or follow-up filed, and a fix ticket self-heal filed" do
    assert holds?(:ticket_filed, event("ticket.filed", %{identifier: "TP-2", kind: "split_off"}))
    assert holds?(:ticket_filed, event("rule.action", %{rule: "Self-heal", action: "filed_ticket"}))
    assert holds?(:ticket_filed, event("rule.action", %{"rule" => "Self-heal", "action" => "filed_ticket"}))
    refute holds?(:ticket_filed, event("rule.action", %{rule: "CI wait", action: "paused"}))
    refute holds?(:ticket_filed, event("rule.action", nil))
  end

  test "shipped_or_cancelled: Done or Canceled entered, or a person's cancel" do
    assert holds?(:shipped_or_cancelled, event("phase.entered", %{to: "Done"}))
    assert holds?(:shipped_or_cancelled, event("phase.entered", %{to: "Canceled"}))
    assert holds?(:shipped_or_cancelled, event("ticket.cancelled", %{from: "Todo", to: "Canceled"}))
    refute holds?(:shipped_or_cancelled, event("phase.entered", %{to: "QA"}))
    refute holds?(:shipped_or_cancelled, event("phase.entered", %{}))
  end

  test "release_installed: Symphony's pause lost an update's build reason" do
    assert holds?(:release_installed, event("pause.reason_cleared", %{reason: "build"}, issue_id: "symphony"))
    assert holds?(:release_installed, event("pause.cleared", %{cleared: [%{reason: :build, text: "updating to v0.0.1.900"}]}, issue_id: "symphony"))
    refute holds?(:release_installed, event("pause.cleared", %{cleared: [%{reason: :person}]}, issue_id: "symphony"))
    refute holds?(:release_installed, event("pause.reason_cleared", %{reason: "build"}))
    refute holds?(:release_installed, event("pause.cleared", %{cleared: [%{reason: :build}]}))
  end

  test "factory_paused: Symphony's own pause set or cleared" do
    assert holds?(:factory_paused, event("pause.set", %{reason: "person"}, issue_id: "symphony"))
    assert holds?(:factory_paused, event("pause.cleared", %{cleared: []}, issue_id: "symphony"))
    refute holds?(:factory_paused, event("pause.reason_added", %{}, issue_id: "symphony"))
    refute holds?(:factory_paused, event("pause.set", %{reason: "person"}))
  end

  test "situation: a situation changed to waiting on you, retrying or blocked" do
    for kind <- ["waiting_on_you", "retrying", "blocked_by_ticket"], do: assert(holds?(:situation, event("situation.changed", %{to: kind})), kind)

    for kind <- ["working", "waiting_for_ci", "done"], do: refute(holds?(:situation, event("situation.changed", %{to: kind})), kind)
    refute holds?(:situation, event("situation.changed", %{to: true}))
  end
end
