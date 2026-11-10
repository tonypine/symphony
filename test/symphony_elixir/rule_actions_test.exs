defmodule SymphonyElixir.RuleActionsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Pauses, RuleActions, TicketEvents}

  @repo "rules"
  @issue_id "rule-ticket"
  @at ~U[2026-11-09 12:00:00.000000Z]
  @rule %{kind: :rule, name: "CI wait"}

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: @issue_id, issue_identifier: "RUL-1", phase: "QA"})
    :ok
  end

  defp rule_actions, do: TicketEvents.query(@issue_id, types: ["rule.action"])

  test "record/6 writes the rule's action with its line, the ticket it filed and the head" do
    long = String.duplicate("x", 600)
    assert :ok = RuleActions.record(@repo, @issue_id, "Self-heal", "filed_ticket", long, filed: "TP-9", head: "abc1234", at: @at)
    assert :ok = RuleActions.record(@repo, @issue_id, "Idle park", "parked", "  ")
    assert :ok = RuleActions.record(@repo, @issue_id, "Loop guard", "paused", nil)

    assert [first, second, third] = rule_actions()
    assert first.at == @at
    assert first.payload == %{rule: "Self-heal", action: "filed_ticket", text: String.duplicate("x", 500), filed: "TP-9", head: "abc1234"}
    assert first.summary.title == "Self-heal filed TP-9"
    assert second.payload == %{rule: "Idle park", action: "parked"}
    assert third.payload == %{rule: "Loop guard", action: "paused"}
  end

  test "record/6 logs a refusal and never fails the rule, and needs a ticket" do
    log = capture_log(fn -> assert :ok = RuleActions.record(@repo, @issue_id, "CI wait", "exploded", "no such action") end)
    assert log =~ "Failed to record rule.action"
    assert rule_actions() == []

    assert :ok = RuleActions.record(nil, @issue_id, "CI wait", "paused", nil)
    assert :ok = RuleActions.record(@repo, nil, "CI wait", "paused", nil)
  end

  test "the PR watcher's rows and kinds" do
    assert RuleActions.watcher_rule("R22") == "PR watcher R22"
    assert RuleActions.watcher_action(:rerun_failed) == "rerun"
    assert RuleActions.watcher_action(:to_rework) == "moved"
    assert RuleActions.watcher_action(:update_branch) == "updated_branch"
    assert RuleActions.watcher_action(:disarm) == "auto_merge"
    assert RuleActions.watcher_action(:decision) == "asked"
    assert RuleActions.watcher_action(:file_fix_ticket) == "other"
    assert RuleActions.watcher_action(:wait) == "other"
  end

  test "a reason a rule sets or lifts records the rule's action with the pause; a question's, Symphony's or a person's records none" do
    ticket = {:ticket, @repo, @issue_id}
    reason = %{kind: :environment, waits_on: %{condition: "ci_wait:abc1234"}, text: "Waiting for CI on abc1234 to finish", releasable: true}
    other = %{kind: :environment, waits_on: %{condition: "other"}, text: "Waiting on something else"}

    {:ok, _pause} = Pauses.set(ticket, reason, set_by: @rule, at: @at)
    {:ok, _pause} = Pauses.set(ticket, other, set_by: %{kind: :rule, name: "Release build watch"}, at: @at)
    {:ok, _pause} = Pauses.clear_reason(ticket, other, by: %{kind: :rule, name: "Release build watch"}, at: @at)
    {:ok, nil} = Pauses.clear_reason(ticket, reason, by: @rule, at: @at)

    assert Enum.map(rule_actions(), &{&1.payload.rule, &1.payload.action, &1.payload.text}) == [
             {"CI wait", "paused", "Waiting for CI on abc1234 to finish"},
             {"Release build watch", "paused", "Waiting on something else"},
             {"Release build watch", "lifted_pause", "Waiting on something else"},
             {"CI wait", "lifted_pause", "Waiting for CI on abc1234 to finish"}
           ]

    {:ok, _pause} = Pauses.set(ticket, reason, set_by: %{kind: :symphony, name: "Symphony"}, at: @at)
    {:ok, nil} = Pauses.clear(ticket, by: %{kind: :person, name: "Director"})
    {:ok, _pause} = Pauses.set(ticket, %{kind: :question, waits_on: %{question_id: "q-1"}}, set_by: @rule, at: @at)
    {:ok, nil} = Pauses.clear(ticket, by: @rule)
    {:ok, _pause} = Pauses.set(ticket, reason, set_by: @rule, at: @at, backfilled: true)
    assert length(rule_actions()) == 4
  end

  test "pause_event/5 reads only a rule's non-question reasons" do
    set_by = %{set_by: @rule, reason: :environment, text: "Waiting for CI"}
    assert {:ok, %{type: "rule.action", payload: %{action: "paused"}}} = RuleActions.pause_event(@repo, @issue_id, "pause.reason_added", set_by, @at)
    assert RuleActions.pause_event(@repo, @issue_id, "pause.set", %{set_by | reason: :question}, @at) == :none
    assert RuleActions.pause_event(@repo, @issue_id, "pause.set", Map.put(set_by, :source, :backfill), @at) == :none
    assert RuleActions.pause_event(@repo, @issue_id, "pause.set", %{set_by | set_by: %{kind: :rule, name: ""}}, @at) == :none

    cleared = %{by: @rule, cleared: [%{reason: :question, text: "Waiting for your answer"}, %{reason: :build, text: "Waiting for v1"}]}

    assert {:ok, %{payload: %{action: "lifted_pause", text: "Waiting for v1"}}} =
             RuleActions.pause_event(@repo, @issue_id, "pause.cleared", cleared, @at)

    question_only = %{cleared | cleared: [%{reason: :question, text: "q"}]}
    assert RuleActions.pause_event(@repo, @issue_id, "pause.cleared", question_only, @at) == :none
    assert RuleActions.pause_event(@repo, @issue_id, "pause.reason_cleared", %{by: @rule, reason: :question, text: "q"}, @at) == :none
    assert RuleActions.pause_event(@repo, @issue_id, "pause.cleared", %{by: %{kind: :person, name: "Director"}, cleared: []}, @at) == :none
  end

  test "Symphony's own pause records its events on its stream, but a writer's change of it carries none" do
    symphony = %{kind: :symphony, name: "Symphony"}
    {:ok, _pause} = Pauses.set(:symphony, Pauses.dispatch_reason("Away"), set_by: %{kind: :person, name: "Director"}, at: @at)
    assert ["pause.set"] = :symphony |> TicketEvents.query_subject() |> Enum.map(& &1.type)

    assert {:ok, %{reasons: [_reason]}, []} =
             Pauses.set_change(:symphony, nil, Pauses.dispatch_reason("Away"), set_by: symphony, at: @at)

    repository_reason = Pauses.repository_reason(nil)

    assert {:ok, %{reasons: [_reason]}, []} =
             Pauses.set_change({:repository, @repo}, nil, repository_reason, set_by: symphony, at: @at)
  end
end
