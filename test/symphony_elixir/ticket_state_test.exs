defmodule SymphonyElixir.TicketStateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PrDecision.Facts
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
               ci_fix_origin: nil,
               self_heal: nil,
               dispatches: [],
               path_unlocks: [],
               decisions: [],
               pr_watch: nil,
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

  describe "claim_path_unlocks/4" do
    test "marks each grant used once and returns only the ones no run used" do
      {record, claimed} = TicketState.claim_path_unlocks(TicketState.new("repo-a", "issue-1"), ["g1", "g1", "g2", nil], "run-1", @at)

      assert claimed == ["g1", "g2"]
      assert [%{id: "g1", run_id: "run-1", at: @at}, %{id: "g2", run_id: "run-1", at: @at}] = record.path_unlocks
      assert record.updated_at == @at

      assert {^record, []} = TicketState.claim_path_unlocks(record, ["g1", "g2"], "run-2", @at)

      assert {%{path_unlocks: [_, _, %{id: "g3", run_id: nil}]}, ["g3"]} =
               TicketState.claim_path_unlocks(record, ["g2", "g3"], nil, @at)
    end

    test "drops malformed used grants when normalizing" do
      record = TicketState.normalize(%{path_unlocks: [%{id: "g1", run_id: "run-1", at: @at}, %{id: 7}, :junk]})
      assert record.path_unlocks == [%{id: "g1", run_id: "run-1", at: @at}]
      assert TicketState.normalize(%{path_unlocks: :junk}).path_unlocks == []
    end
  end

  describe "decisions" do
    @decision %{key: "comment-1", date: ~D[2026-10-13], title: "Keep it", question: "Keep it?", answer: "Yes", scope: "As answered"}

    test "appends the decisions the record lacks, each once, in order" do
      entries = [@decision, @decision, %{@decision | key: "comment-2"}]
      record = TicketState.put_decisions(TicketState.new("repo-a", "issue-1"), entries, [], @at)

      assert [%{key: "comment-1"}, %{key: "comment-2"}] = TicketState.decisions(record)
      assert record.updated_at == @at
      assert TicketState.put_decisions(record, [@decision], [], ~U[2026-02-01 00:00:00Z]) == record
    end

    test "takes the backfill first only while the record holds no decision" do
      new = %{@decision | key: "new"}
      backfilled = TicketState.put_decisions(TicketState.new("repo-a", "issue-1"), [new], [@decision], @at)
      assert [%{key: "comment-1"}, %{key: "new"}] = backfilled.decisions

      again = TicketState.put_decisions(backfilled, [], [%{@decision | key: "old"}], @at)
      assert [%{key: "comment-1"}, %{key: "new"}] = again.decisions
    end

    test "drops malformed entries and fills missing text" do
      decisions = [%{key: "k", date: 3, title: nil}, %{key: "", answer: "x"}, %{answer: "x"}, "junk", %{key: "d", date: "someday"}]
      record = TicketState.normalize(%{decisions: decisions})

      assert [%{key: "k", date: "", title: "", question: "", answer: "", scope: ""}, %{key: "d", date: "someday"}] =
               record.decisions

      assert TicketState.normalize(%{decisions: :x}).decisions == []
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
               ci_fix_origin: nil,
               self_heal: nil,
               dispatches: [],
               path_unlocks: [],
               decisions: [],
               pr_watch: nil,
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

    test "a hold records what it waits on, and get_hold/2 reads it back" do
      record =
        TicketState.set_hold(TicketState.new("repo-a", "issue-1"), :blocked, %{
          reason: "waiting on TP-1",
          waits_on: %{type: " dependency ", keys: [" TP-1 ", nil, 5]}
        })

      assert [%{kind: :blocked, waits_on: %{type: "dependency", keys: ["TP-1"]}}] = record.holds
      assert %{kind: :blocked, waits_on: %{type: "dependency", keys: ["TP-1"]}} = TicketState.get_hold(record, :blocked)
      assert TicketState.get_hold(record, :needs_decision) == nil
    end

    test "a malformed waits_on is dropped to nil" do
      blank_type = TicketState.set_hold(TicketState.new("repo-a", "issue-1"), :blocked, %{waits_on: %{type: "  "}})
      assert [%{waits_on: nil}] = blank_type.holds

      not_a_map = TicketState.set_hold(TicketState.new("repo-a", "issue-1"), :blocked, %{waits_on: "nope"})
      assert [%{waits_on: nil}] = not_a_map.holds

      no_keys = TicketState.set_hold(TicketState.new("repo-a", "issue-1"), :blocked, %{waits_on: %{type: "access", keys: "nope"}})
      assert [%{waits_on: %{type: "access", keys: []}}] = no_keys.holds
    end

    test "a stored record keeps its waits_on through normalization" do
      record =
        TicketState.new("repo-a", "issue-1")
        |> TicketState.set_hold(:blocked, %{waits_on: %{type: "fix_ticket", keys: ["TP-900"]}})
        |> TicketState.normalize()

      assert %{waits_on: %{type: "fix_ticket", keys: ["TP-900"]}} = TicketState.get_hold(record, :blocked)
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

  describe "dispatches" do
    test "records a dispatched run newest first, bounded to the newest" do
      record =
        Enum.reduce(1..55, TicketState.new("repo-a", "issue-1"), fn n, record ->
          TicketState.record_dispatch(record, %{kind: :implementation, run_id: "run-#{n}", state: "In Progress", head: " "}, @at)
        end)

      assert length(TicketState.dispatches(record)) == 50
      assert [%{kind: "implementation", run_id: "run-55", state: "In Progress", head: nil, at: @at, outcome: nil} | _rest] = record.dispatches
      assert record.updated_at == @at
      assert [%{kind: "qa"}] = TicketState.record_dispatch(TicketState.new("repo-a", "issue-1"), %{kind: " qa "}).dispatches
      assert [%{kind: ""}] = TicketState.record_dispatch(TicketState.new("repo-a", "issue-1"), %{}).dispatches
    end

    test "records how a run ended, and drops one that counts no attempt" do
      record =
        TicketState.new("repo-a", "issue-1")
        |> TicketState.record_dispatch(%{kind: "rework", run_id: "run-1", head: "a"}, @at)
        |> TicketState.record_dispatch(%{kind: "rework", run_id: "run-2", head: "a"}, @at)

      ended = TicketState.record_dispatch_outcome(record, "run-1", %{exit: "ended normally", head: "b"}, @at)
      assert [%{run_id: "run-2", outcome: nil}, %{run_id: "run-1", outcome: %{exit: "ended normally", head: "b", at: @at}}] = ended.dispatches

      assert [%{run_id: "run-1"}] = TicketState.record_dispatch_outcome(ended, "run-2", %{counted: false}, @at).dispatches
      blank = TicketState.record_dispatch_outcome(ended, "run-2", %{}, @at)
      assert [%{outcome: %{exit: "", head: nil}}, _run] = blank.dispatches
      assert TicketState.record_dispatch_outcome(record, "run-9", %{exit: "x"}, @at) == record
      assert TicketState.record_dispatch_outcome(record, nil, %{exit: "x"}, @at) == record
      assert %DateTime{} = TicketState.record_dispatch_outcome(record, "run-1", %{exit: "x"}).updated_at
    end

    test "a stored record keeps its dispatches through normalization and drops malformed ones" do
      record =
        TicketState.normalize(%{
          dispatches: [
            %{kind: "qa", run_id: "run-1", at: @at, outcome: %{exit: "failed (boom)", head: "a", at: @at}},
            %{kind: "qa", outcome: "junk"},
            %{kind: :atom},
            "junk"
          ]
        })

      assert [%{kind: "qa", outcome: %{exit: "failed (boom)", head: "a", at: @at}}, %{kind: "qa", outcome: nil, at: nil}] =
               record.dispatches

      assert TicketState.normalize(%{dispatches: "junk"}).dispatches == []
      assert TicketState.normalize(%{dispatches: [%{kind: "qa", outcome: %{}}]}).dispatches |> hd() |> Map.fetch!(:outcome) == %{exit: "", head: nil, at: nil}
    end

    test "a hold that lifts and a verdict end the count; clearing no hold keeps it" do
      record = TicketState.record_dispatch(TicketState.new("repo-a", "issue-1"), %{kind: "implementation", run_id: "run-1"}, @at)

      assert [_run] = TicketState.clear_hold(record, :blocked, @at).dispatches
      assert record |> TicketState.set_hold(:blocked, %{reason: "loop"}) |> TicketState.dispatches() |> length() == 1

      for kind <- [:blocked, :needs_decision] do
        lifted = record |> TicketState.set_hold(kind, %{reason: "loop"}) |> TicketState.clear_hold(kind, @at)
        assert TicketState.dispatches(lifted) == []
      end

      assert record |> TicketState.record_verdict("code_review", "a", "approve", @at) |> TicketState.dispatches() == []
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

    test "put_ci_state/4 accepts a newer write, reports an unchanged repeat and drops a stale one" do
      record = TicketState.new("repo-a", "issue-1")
      later = DateTime.add(@at, 60, :second)

      assert {record, :changed} = TicketState.put_ci_state(record, "abc", "running", @at)
      assert %{head_sha: "abc", status: "running", updated_at: @at} = TicketState.current_ci_state(record)

      assert {^record, :unchanged} = TicketState.put_ci_state(record, "abc", "running", @at)
      assert {^record, :unchanged} = TicketState.put_ci_state(record, "abc", "running", later)

      assert {record, :changed} = TicketState.put_ci_state(record, "abc", "green", later)
      assert %{status: "green", updated_at: ^later} = TicketState.current_ci_state(record)

      assert {updated, :stale} = TicketState.put_ci_state(record, "abc", "red", @at)
      assert updated == record
      assert %{status: "green"} = TicketState.current_ci_state(record)
    end

    test "put_ci_state/4 keeps each head's own ordering, and current_ci_state/1 is nil before any write" do
      assert TicketState.current_ci_state(TicketState.new("repo-a", "issue-1")) == nil

      record = TicketState.new("repo-a", "issue-1")
      {record, :changed} = TicketState.put_ci_state(record, "abc", "green", @at)

      later = DateTime.add(@at, 60, :second)
      {record, :changed} = TicketState.put_ci_state(record, "def", "running", later)

      assert %{head_sha: "def"} = TicketState.current_ci_state(record)
      assert [%{head_sha: "def"}, %{head_sha: "abc", status: "green"}] = record.ci_states

      # A stale write for the older head is dropped, leaving the newer head current.
      {record, :stale} = TicketState.put_ci_state(record, "abc", "red", DateTime.add(@at, -60, :second))
      assert %{head_sha: "def"} = TicketState.current_ci_state(record)
    end
  end

  describe "self-heal bookkeeping" do
    test "records the broken component, the owning repo, the signature, the fix ticket and the attempts" do
      record = TicketState.new("repo-a", "issue-1")
      assert TicketState.self_heal(record) == nil

      record =
        TicketState.put_self_heal(
          record,
          %{component: "dev_server", scope: "repo-a", signature: " {:dev_server_exit, 3} ", fix_ticket: "TP-900", attempts: 2},
          @at
        )

      assert TicketState.self_heal(record) == %{
               component: "dev_server",
               scope: "repo-a",
               signature: "{:dev_server_exit, 3}",
               fix_ticket: "TP-900",
               attempts: 2,
               at: @at
             }

      assert record.updated_at == @at
    end

    test "defaults the optional fields and a bad attempt count" do
      record = TicketState.put_self_heal(TicketState.new("repo-a", "issue-1"), %{component: "qa_environment", attempts: -1}, @at)

      assert TicketState.self_heal(record) ==
               %{component: "qa_environment", scope: nil, signature: "", fix_ticket: nil, attempts: 0, at: @at}
    end

    test "a blank component records nothing, and dropping the fix ticket keeps the rest" do
      record = TicketState.put_self_heal(TicketState.new("repo-a", "issue-1"), %{component: "  "}, @at)
      assert TicketState.self_heal(record) == nil
      assert TicketState.clear_fix_ticket(record, @at) |> TicketState.self_heal() == nil

      record =
        TicketState.put_self_heal(
          record,
          %{component: "dev_server", signature: "a failure", fix_ticket: "TP-900", attempts: 2},
          @at
        )

      dropped = TicketState.clear_fix_ticket(record, @at)

      assert TicketState.self_heal(dropped) ==
               %{component: "dev_server", scope: nil, signature: "a failure", fix_ticket: nil, attempts: 2, at: @at}

      assert dropped.updated_at == @at
    end

    test "a non-map bookkeeping value normalizes to nothing" do
      assert TicketState.normalize(%{repo_key: "repo-a", issue_id: "issue-1", self_heal: "junk"}).self_heal == nil
      assert TicketState.normalize(%{repo_key: "repo-a", issue_id: "issue-1", self_heal: %{}}).self_heal == nil
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
    assert %DateTime{} = TicketState.record_dispatch(record, %{kind: "qa"}).updated_at
  end

  describe "put_pr_watch/3" do
    test "keeps the watcher's fact record, normalised, and clears it with nil" do
      facts = Facts.new(phase: :qa, ci: :green)
      landing = %{state: " QA ", head_sha: "abc", state_since: @at, progress_at: @at, extra: 1}

      record =
        TicketState.new("repo-a", "issue-1")
        |> TicketState.put_pr_watch(
          %{
            facts: facts,
            pr_url: "https://github.com/acme/app/pull/1",
            head_sha: "abc",
            source: :webhook,
            read_at: @at,
            github: {:rate_limited, @at},
            rate_limit: %{remaining: 12, reset_at: @at},
            landing: landing,
            decision: %{rule: "R1"},
            applied: [%{rule: "R24"}, :junk],
            links: :junk
          },
          @at
        )

      assert record.updated_at == @at

      assert TicketState.pr_watch(record) == %{
               facts: facts,
               pr_url: "https://github.com/acme/app/pull/1",
               head_sha: "abc",
               source: :webhook,
               read_at: @at,
               github: {:rate_limited, @at},
               rate_limit: %{remaining: 12, reset_at: @at},
               landing: %{state: "QA", head_sha: "abc", state_since: @at, progress_at: @at},
               decision: %{rule: "R1"},
               applied: [%{rule: "R24"}],
               links: []
             }

      assert TicketState.normalize(record) == record
      assert TicketState.pr_watch(TicketState.put_pr_watch(record, nil)) == nil
    end

    test "fills the defaults of a sparse record and drops one without facts" do
      facts = Facts.new()

      sparse = TicketState.new("repo-a", "issue-1", %{pr_watch: %{facts: facts, github: :odd, landing: %{state: "QA"}}})

      assert %{source: :poll, github: :ok, rate_limit: nil, landing: nil, decision: nil, applied: [], links: []} =
               TicketState.pr_watch(sparse)

      assert %{github: {:rate_limited, nil}, rate_limit: %{remaining: nil, reset_at: nil}} =
               TicketState.pr_watch(TicketState.new("repo-a", "issue-1", %{pr_watch: %{facts: facts, github: {:rate_limited, "soon"}, rate_limit: %{remaining: -1}}}))

      assert TicketState.pr_watch(TicketState.new("repo-a", "issue-1", %{pr_watch: %{facts: %{phase: :qa}}})) == nil
      assert TicketState.pr_watch(TicketState.new("repo-a", "issue-1", %{pr_watch: :junk})) == nil
      assert %DateTime{} = TicketState.put_pr_watch(TicketState.new("repo-a", "issue-1"), nil).updated_at
    end
  end
end
