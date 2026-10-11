defmodule SymphonyElixir.TicketStateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TicketState

  @at ~U[2026-01-02 03:04:05Z]

  describe "new/3" do
    test "builds a normalized record with defaults" do
      assert TicketState.new("repo-a", "issue-1") == %{
               repo_key: "repo-a",
               issue_id: "issue-1",
               issue_identifier: nil,
               phase: nil,
               holds: [],
               ci_states: [],
               verdicts: [],
               signals: [],
               updated_at: nil
             }
    end

    test "applies the given attributes" do
      record =
        TicketState.new("repo-a", "issue-1", %{
          issue_identifier: "ACME-1",
          phase: "In Progress",
          signals: [%{name: "handoff", details: %{to: "Code Review"}, at: @at}]
        })

      assert record.issue_identifier == "ACME-1"
      assert record.phase == "In Progress"
      assert [%{name: "handoff", details: %{to: "Code Review"}, at: @at}] = record.signals
    end
  end

  describe "normalize/1" do
    test "fills defaults for a non-map" do
      assert TicketState.normalize(:nonsense) == %{
               repo_key: nil,
               issue_id: nil,
               issue_identifier: nil,
               phase: nil,
               holds: [],
               ci_states: [],
               verdicts: [],
               signals: [],
               updated_at: nil
             }
    end

    test "drops malformed list entries and keeps the well-formed ones" do
      record =
        TicketState.normalize(%{
          repo_key: "repo-a",
          issue_id: "issue-1",
          phase: "  ",
          holds: [%{kind: :blocked, reason: "waiting"}, %{kind: :nope}, "junk", %{kind: :blocked, reason: "duplicate"}],
          verdicts: [%{kind: "review verdict", outcome: "approve"}, %{kind: :atom}, "junk"],
          ci_states: [%{head_sha: "abc", status: "green"}, %{head_sha: 42}, "junk"],
          signals: [%{name: "handoff"}, %{name: :atom}, "junk"],
          updated_at: "not a datetime"
        })

      assert record.phase == nil
      assert [%{kind: :blocked, reason: "waiting"}] = record.holds
      assert [%{kind: "review verdict", outcome: "approve"}] = record.verdicts
      assert [%{head_sha: "abc", status: "green"}] = record.ci_states
      assert [%{name: "handoff", details: %{}, at: nil}] = record.signals
      assert record.updated_at == nil
    end

    test "treats non-list collections as empty" do
      record = TicketState.normalize(%{holds: :x, verdicts: :x, ci_states: :x, signals: :x})
      assert record.holds == []
      assert record.verdicts == []
      assert record.ci_states == []
      assert record.signals == []
    end
  end

  describe "put_phase/3" do
    test "sets the phase and stamps the time" do
      record = TicketState.new("repo-a", "issue-1") |> TicketState.put_phase("Merging", @at)
      assert record.phase == "Merging"
      assert record.updated_at == @at
    end

    test "clears the phase for a blank or non-binary value" do
      record = TicketState.new("repo-a", "issue-1", %{phase: "Merging"})
      assert TicketState.put_phase(record, "  ", @at).phase == nil
      assert TicketState.put_phase(record, nil, @at).phase == nil
    end
  end

  describe "record_signal/4" do
    test "prepends the newest signal and stamps the time" do
      record =
        TicketState.new("repo-a", "issue-1")
        |> TicketState.record_signal("handoff", %{to: "Code Review"}, @at)
        |> TicketState.record_signal("review verdict", %{outcome: "approve"})

      assert [%{name: "review verdict"}, %{name: "handoff", details: %{to: "Code Review"}, at: @at}] = record.signals
      assert record.updated_at != nil
    end

    test "keeps an unknown signal name and defaults its details" do
      record = TicketState.new("repo-a", "issue-1") |> TicketState.record_signal("something new", nil, @at)
      assert [%{name: "something new", details: %{}, at: @at}] = record.signals
    end

    test "bounds the ledger to the newest signals" do
      record =
        Enum.reduce(1..60, TicketState.new("repo-a", "issue-1"), fn n, record ->
          TicketState.record_signal(record, "handoff", %{n: n}, @at)
        end)

      assert length(record.signals) == 50
      assert hd(record.signals).details == %{n: 60}
    end
  end

  describe "holds" do
    test "sets, replaces and clears a hold" do
      record = TicketState.new("repo-a", "issue-1")
      refute TicketState.hold?(record, :blocked)

      record = TicketState.set_hold(record, :blocked, %{reason: "tooling", clearing_condition: "fix lands"}, @at)
      assert TicketState.hold?(record, :blocked)
      assert [%{kind: :blocked, reason: "tooling", clearing_condition: "fix lands", decision: nil, set_at: @at}] = record.holds

      record = TicketState.set_hold(record, :blocked, %{reason: "again"}, @at)
      assert [%{kind: :blocked, reason: "again"}] = record.holds

      record = TicketState.clear_hold(record, :blocked, @at)
      refute TicketState.hold?(record, :blocked)
      assert record.holds == []
    end

    test "a Needs Decision hold carries its decision payload" do
      record =
        TicketState.set_hold(TicketState.new("repo-a", "issue-1"), :needs_decision, %{
          reason: "pick one",
          decision: %{question: "Which?", options: ["a", "b"]}
        })

      assert [%{kind: :needs_decision, decision: %{question: "Which?"}}] = record.holds
    end

    test "a non-map decision is dropped" do
      record = TicketState.set_hold(TicketState.new("repo-a", "issue-1"), :needs_decision, %{decision: "nope"})
      assert [%{decision: nil}] = record.holds
    end

    test "clearing an unset hold is a no-op" do
      record = TicketState.clear_hold(TicketState.new("repo-a", "issue-1"), :needs_decision, @at)
      assert record.holds == []
    end
  end

  describe "record_verdict/5" do
    test "records a verdict bound to its head SHA" do
      record = TicketState.new("repo-a", "issue-1") |> TicketState.record_verdict("review verdict", "abc123", "approve", @at)
      assert [%{kind: "review verdict", head_sha: "abc123", outcome: "approve", recorded_at: @at}] = record.verdicts
    end

    test "defaults a blank outcome and head SHA" do
      record = TicketState.new("repo-a", "issue-1") |> TicketState.record_verdict("QA verdict", nil, nil, @at)
      assert [%{kind: "QA verdict", head_sha: nil, outcome: ""}] = record.verdicts
    end

    test "bounds the verdicts to the newest" do
      record =
        Enum.reduce(1..60, TicketState.new("repo-a", "issue-1"), fn n, record ->
          TicketState.record_verdict(record, "review verdict", "sha-#{n}", "approve", @at)
        end)

      assert length(record.verdicts) == 50
      assert hd(record.verdicts).head_sha == "sha-60"
    end
  end

  describe "CI states" do
    test "upserts the state of one head, newest first" do
      record = TicketState.new("repo-a", "issue-1")
      assert TicketState.ci_state(record, "abc") == nil

      record = TicketState.record_ci_state(record, "abc", "running", @at)
      assert %{head_sha: "abc", status: "running", updated_at: @at} = TicketState.ci_state(record, "abc")

      record = TicketState.record_ci_state(record, "abc", "green", @at)
      assert [%{head_sha: "abc", status: "green"}] = record.ci_states

      record = TicketState.record_ci_state(record, "def", "red", @at)
      assert [%{head_sha: "def"}, %{head_sha: "abc"}] = record.ci_states
    end

    test "accepts a nil head SHA and defaults a blank status" do
      record = TicketState.new("repo-a", "issue-1") |> TicketState.record_ci_state(nil, nil, @at)
      assert [%{head_sha: nil, status: ""}] = record.ci_states
      assert %{head_sha: nil} = TicketState.ci_state(record, nil)
    end

    test "bounds the CI states to the newest" do
      record =
        Enum.reduce(1..30, TicketState.new("repo-a", "issue-1"), fn n, record ->
          TicketState.record_ci_state(record, "sha-#{n}", "green", @at)
        end)

      assert length(record.ci_states) == 20
      assert hd(record.ci_states).head_sha == "sha-30"
    end
  end

  describe "recent_signals/2" do
    test "returns the newest signals, newest first" do
      record =
        TicketState.new("repo-a", "issue-1")
        |> TicketState.record_signal("handoff", %{}, @at)
        |> TicketState.record_signal("blocked", %{}, @at)
        |> TicketState.record_signal("unblocked", %{}, @at)

      assert ["unblocked", "blocked"] = record |> TicketState.recent_signals(2) |> Enum.map(& &1.name)
      assert length(TicketState.recent_signals(record)) == 3
      assert TicketState.recent_signals(record, 0) == []
    end
  end

  test "the mutators default their timestamp to now" do
    record = TicketState.new("repo-a", "issue-1")

    assert %DateTime{} = TicketState.put_phase(record, "Todo").updated_at
    assert %DateTime{} = TicketState.clear_hold(record, :blocked).updated_at
    assert %DateTime{} = TicketState.record_verdict(record, "review verdict", "sha", "approve").updated_at
    assert %DateTime{} = TicketState.record_ci_state(record, "sha", "green").updated_at
    assert %DateTime{} = TicketState.set_hold(record, :blocked).updated_at
    assert %DateTime{} = TicketState.record_signal(record, "handoff").updated_at
  end

  test "signal_names/0 lists the transition vocabulary" do
    assert "handoff" in TicketState.signal_names()
    assert "plan verdict" in TicketState.signal_names()
  end
end
