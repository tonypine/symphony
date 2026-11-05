defmodule SymphonyElixir.TicketStateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.PrWatch.Attempts
  alias SymphonyElixir.TicketEvents.Event
  alias SymphonyElixir.TicketState

  @at ~U[2026-01-02 03:04:05Z]

  describe "new/3" do
    test "builds a normalized record with defaults" do
      assert TicketState.new("repo-a", "issue-1") == %{
               repo_key: "repo-a",
               issue_id: "issue-1",
               issue_identifier: nil,
               phase: nil,
               phase_at: nil,
               phase_owner: :external,
               ci_states: [],
               verdicts: [],
               signals: [],
               ci_fix_origin: nil,
               self_heal: nil,
               dispatches: [],
               path_unlocks: [],
               decisions: [],
               pr_watch: nil,
               event_seq: 0,
               title: nil,
               description: nil,
               team: nil,
               project: nil,
               labels: [],
               priority: nil,
               assignee: nil,
               blockers: [],
               sub_issues: [],
               parent: nil,
               url: nil,
               created_at: nil,
               linear_updated_at: nil,
               observed_at: nil,
               observed_from: nil,
               removed_at: nil,
               pending_projection: [],
               not_found_at: nil,
               pause: nil,
               questions: [],
               pause_backfilled_at: nil,
               projected: nil,
               plan_brief: nil,
               plan_brief_error: nil,
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

    test "keeps the protected paths a picked option unlocks, and only text" do
      decisions = [Map.put(@decision, :unlocks, ["WORKFLOW.md", 7]), Map.put(%{@decision | key: "k2"}, :unlocks, [nil]), %{@decision | key: "k3"}]
      record = TicketState.normalize(%{decisions: decisions})

      assert [%{key: "comment-1", unlocks: ["WORKFLOW.md"]}, second, third] = record.decisions
      refute Map.has_key?(second, :unlocks)
      refute Map.has_key?(third, :unlocks)
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
    test "keeps what the pause projector applied, its labels sorted, and its :pause mark (TP-1243)" do
      record = TicketState.normalize(%{projected: %{labels: ["Needs Decision", "Blocked", 3], section: "abc"}})
      assert record.projected == %{labels: ["Blocked", "Needs Decision"], section: "abc", comments: nil}
      assert TicketState.normalize(%{projected: "junk"}).projected == nil

      comments = %{"q-1" => %{comment: "c-1", reply: "answered:2026"}, "q-2" => %{}, "q-3" => "junk", 4 => %{}}

      assert TicketState.normalize(%{projected: %{labels: [], comments: comments}}).projected.comments ==
               %{"q-1" => %{comment: "c-1", reply: "answered:2026"}, "q-2" => %{comment: nil, reply: nil}}

      marked = TicketState.mark_projection(record, :pause, :linear_down, ~U[2026-10-30 04:00:00Z])
      assert [%{type: :pause, error: ":linear_down"} = mark] = marked.pending_projection
      assert TicketState.projection_of(mark) == :pause
      assert TicketState.normalize(marked).pending_projection == marked.pending_projection
    end

    test "fills defaults for a non-map" do
      assert TicketState.normalize(:nonsense) == %{
               repo_key: nil,
               issue_id: nil,
               issue_identifier: nil,
               phase: nil,
               phase_at: nil,
               phase_owner: :external,
               ci_states: [],
               verdicts: [],
               signals: [],
               ci_fix_origin: nil,
               self_heal: nil,
               dispatches: [],
               path_unlocks: [],
               decisions: [],
               pr_watch: nil,
               event_seq: 0,
               title: nil,
               description: nil,
               team: nil,
               project: nil,
               labels: [],
               priority: nil,
               assignee: nil,
               blockers: [],
               sub_issues: [],
               parent: nil,
               url: nil,
               created_at: nil,
               linear_updated_at: nil,
               observed_at: nil,
               observed_from: nil,
               removed_at: nil,
               pending_projection: [],
               not_found_at: nil,
               pause: nil,
               questions: [],
               pause_backfilled_at: nil,
               projected: nil,
               plan_brief: nil,
               plan_brief_error: nil,
               updated_at: nil
             }
    end

    test "drops malformed list entries and keeps the well-formed ones" do
      record =
        TicketState.normalize(%{
          repo_key: "repo-a",
          issue_id: "issue-1",
          phase: "  ",
          verdicts: [%{kind: "review verdict", outcome: "approve"}, %{kind: :atom}, "junk"],
          ci_states: [%{head_sha: "abc", status: "green"}, %{head_sha: 42}, "junk"],
          signals: [%{name: "handoff"}, %{name: :atom}, "junk"],
          updated_at: "not a datetime"
        })

      assert record.phase == nil
      assert [%{kind: "review verdict", outcome: "approve"}] = record.verdicts
      assert [%{head_sha: "abc", status: "green"}] = record.ci_states
      assert [%{name: "handoff", details: %{}, at: nil}] = record.signals
      assert record.updated_at == nil
    end

    test "a record stored before event_seq reads back with event_seq 0 and its other fields unchanged" do
      stored = %{
        repo_key: "repo-a",
        issue_id: "issue-1",
        issue_identifier: "ACME-1",
        phase: "QA",
        signals: [%{name: "handoff", details: %{to: "QA"}, at: @at}],
        verdicts: [%{kind: "qa", head_sha: "abc", outcome: "pass", recorded_at: @at, details: %{}}],
        updated_at: @at
      }

      record = TicketState.normalize(stored)

      assert record.event_seq == 0
      assert Map.delete(record, :event_seq) == Map.delete(TicketState.normalize(Map.put(stored, :event_seq, 9)), :event_seq)
      assert Map.take(record, Map.keys(stored)) == stored
    end

    test "keeps a stored event_seq and reads a malformed one as 0" do
      assert TicketState.normalize(%{event_seq: 12}).event_seq == 12
      assert TicketState.normalize(%{event_seq: -1}).event_seq == 0
      assert TicketState.normalize(%{event_seq: "3"}).event_seq == 0
    end

    test "a record stored before the observation fields reads back with them at their defaults" do
      stored = %{repo_key: "repo-a", issue_id: "issue-1", issue_identifier: "ACME-1", phase: "QA", event_seq: 3, updated_at: @at}

      record = TicketState.normalize(stored)

      assert Map.take(record, [:title, :description, :team, :project, :labels, :priority, :assignee, :blockers, :sub_issues, :parent, :url, :created_at, :linear_updated_at, :observed_at]) == %{
               title: nil,
               description: nil,
               team: nil,
               project: nil,
               labels: [],
               priority: nil,
               assignee: nil,
               blockers: [],
               sub_issues: [],
               parent: nil,
               url: nil,
               created_at: nil,
               linear_updated_at: nil,
               observed_at: nil
             }

      assert Map.take(record, Map.keys(stored)) == stored
    end

    test "reads malformed observation fields as their defaults" do
      record =
        TicketState.normalize(%{
          title: 42,
          description: 42,
          team: "Test",
          project: :x,
          labels: ["bug", 7, "  ", " ui "],
          priority: "high",
          assignee: :someone,
          blockers: :x,
          sub_issues: "ACME-2",
          parent: %{title: "No identifier"},
          url: "",
          created_at: "2026-10-01",
          linear_updated_at: "yesterday",
          observed_at: 1
        })

      assert {record.title, record.labels, record.priority, record.assignee} == {nil, ["bug", "ui"], nil, nil}
      assert {record.description, record.team, record.project} == {nil, nil, nil}
      assert {record.blockers, record.sub_issues, record.parent} == {[], [], nil}
      assert {record.url, record.created_at, record.linear_updated_at, record.observed_at} == {nil, nil, nil, nil}
    end

    test "keeps each link's id, identifier and state, and reads a stored identifier as a link with neither id nor state" do
      record =
        TicketState.normalize(%{
          blockers: ["ACME-5", %{id: "issue-6", identifier: " ACME-6 ", state: "Todo", title: "dropped"}, %{id: nil, identifier: nil}, 7, " "],
          sub_issues: [%{id: "issue-7", identifier: nil, state: ""}, %{state: "Todo"}]
        })

      assert record.blockers == [%{id: nil, identifier: "ACME-5", state: nil}, %{id: "issue-6", identifier: "ACME-6", state: "Todo"}]
      assert record.sub_issues == [%{id: "issue-7", identifier: nil, state: nil}]
    end

    test "keeps a description as written, a team by key and name and a project by id, name and slug id" do
      record =
        TicketState.normalize(%{
          description: "  Why\n\nWhat you get  ",
          team: %{key: " TP ", name: "Tony", id: "dropped"},
          project: %{id: "project-1", name: " Symphony ", slug_id: ""}
        })

      assert record.description == "  Why\n\nWhat you get  "
      assert record.team == %{key: "TP", name: "Tony"}
      assert record.project == %{id: "project-1", name: "Symphony", slug_id: nil}
    end

    test "keeps a parent with an identifier, its counts read as zero when malformed" do
      parent = %{identifier: "ACME-0", title: "Epic", done: 1, total: 2, children: ["completed", "started"]}
      assert TicketState.normalize(%{parent: parent}).parent == parent

      assert TicketState.normalize(%{parent: %{identifier: "ACME-0", done: -1, total: "2", children: :x}}).parent ==
               %{identifier: "ACME-0", title: nil, done: 0, total: 0, children: []}
    end

    test "treats non-list collections as empty" do
      record = TicketState.normalize(%{holds: :x, verdicts: :x, ci_states: :x, signals: :x})
      refute Map.has_key?(record, :holds)
      assert record.verdicts == []
      assert record.ci_states == []
      assert record.signals == []
    end
  end

  describe "pause" do
    @question %{kind: :question, waits_on: %{question_id: "q-1"}, text: "Waiting for your answer", set_at: @at}
    @dependency %{kind: :ticket, waits_on: %{identifier: "TP-12"}, set_at: @at}

    test "put_pause/3 sets the ticket's pause and pause_reasons/1 lists its reasons in order" do
      pause = %{subject: {:ticket, "repo-a", "issue-1"}, reasons: [@question, @dependency]}
      record = TicketState.new("repo-a", "issue-1") |> TicketState.put_pause(pause, @at)

      assert %{set_by: %{kind: :symphony, name: "Symphony"}, since: @at} = record.pause
      assert record.updated_at == @at
      assert Enum.map(TicketState.pause_reasons(record), & &1.kind) == [:question, :ticket]
      assert Enum.map(TicketState.pause_reasons(record), & &1.text) == ["Waiting for your answer", "Waiting for TP-12 to finish"]
    end

    test "nil, a pause with no valid reason or a malformed one clears it; a record without one reads nil" do
      record = TicketState.new("repo-a", "issue-1") |> TicketState.put_pause(%{subject: {:ticket, "repo-a", "issue-1"}, reasons: [@question]})

      assert TicketState.put_pause(record, nil).pause == nil
      assert TicketState.put_pause(record, %{subject: {:ticket, "repo-a", "issue-1"}, reasons: [%{kind: :nope}]}).pause == nil
      assert TicketState.normalize(%{pause: :junk}).pause == nil
      assert TicketState.new("repo-a", "issue-1").pause == nil
      assert TicketState.pause_reasons(%{}) == []
    end
  end

  describe "questions" do
    @open %{id: "q-1", state: :open, title: "Ship it"}
    @answered %{id: "q-2", state: :answered, title: "Wait"}

    test "put_question/2 adds a question after the others, replaces the one with its id, and open_questions/1 keeps the open ones" do
      record = TicketState.new("repo-a", "issue-1") |> TicketState.put_question(@open) |> TicketState.put_question(@answered)

      assert Enum.map(record.questions, & &1.id) == ["q-1", "q-2"]
      assert [%{id: "q-1", state: :open, title: "Ship it"}] = TicketState.open_questions(record)

      record = TicketState.put_question(record, %{@open | state: :withdrawn})
      assert Enum.map(record.questions, &{&1.id, &1.state}) == [{"q-1", :withdrawn}, {"q-2", :answered}]
      assert TicketState.open_questions(record) == []
    end

    test "a malformed question changes nothing; a record without questions reads none" do
      record = TicketState.put_question(TicketState.new("repo-a", "issue-1"), @open)

      assert TicketState.put_question(record, %{id: "q-3", state: :pending}) == record
      assert TicketState.put_question(record, :junk) == record
      assert TicketState.normalize(%{questions: :junk}).questions == []
      stored = [@open, %{@open | title: "Again"}, %{id: 7, state: :open}]
      assert [%{id: "q-1", title: "Ship it"}] = TicketState.normalize(%{questions: stored}).questions
      assert TicketState.open_questions(%{}) == []
    end
  end

  describe "put_phase/4" do
    test "sets the phase and stamps the time, owned by Symphony unless said otherwise" do
      record = TicketState.new("repo-a", "issue-1") |> TicketState.put_phase("Merging", @at)
      assert record.phase == "Merging"
      assert {record.phase_at, record.phase_owner, record.updated_at} == {@at, :symphony, @at}

      assert TicketState.put_phase(record, "Done", @at, :external).phase_owner == :external
    end

    test "a record written before Symphony kept the owner reads as external; a stored owner is kept" do
      assert TicketState.normalize(%{phase: "Code Review"}).phase_owner == :external
      assert TicketState.normalize(%{phase_owner: :unknown}).phase_owner == :external
      assert TicketState.normalize(%{phase_owner: :symphony}).phase_owner == :symphony
      assert TicketState.normalize(%{phase_owner: "symphony"}).phase_owner == :symphony
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

  describe "the holds a record kept from before they were retired" do
    test "are dropped, and a question an old hold carried reads as asked with a request" do
      carried = %{id: "q-1", state: :open, title: "Pick", question: "Which?", request: nil}
      other = %{id: "q-2", state: :open, title: "Other", question: "Which?", request: nil}
      already = %{id: "q-3", state: :open, title: "Known", question: "Which?", request: false}

      record =
        TicketState.normalize(%{
          repo_key: "repo-a",
          issue_id: "issue-1",
          holds: [
            %{kind: :blocked, reason: "waiting"},
            %{decision: %{question_id: "q-1"}},
            %{decision: %{question_id: "q-3"}},
            %{decision: %{question_id: 7}}
          ],
          questions: [carried, other, already]
        })

      refute Map.has_key?(record, :holds)
      assert Enum.map(record.questions, &{&1.id, &1.request}) == [{"q-1", true}, {"q-2", nil}, {"q-3", false}]
    end

    test "a record with no holds, or holds that are not a list, keeps its questions as they are" do
      question = %{id: "q-1", state: :open, title: "Pick", question: "Which?", request: nil}

      for holds <- [nil, :x] do
        assert [%{id: "q-1", request: nil}] = TicketState.normalize(%{holds: holds, questions: [question]}).questions
      end
    end
  end

  describe "record_verdict/5" do
    test "records a verdict bound to its head SHA" do
      record = TicketState.new("repo-a", "issue-1") |> TicketState.record_verdict("review verdict", "abc123", "approve", @at)
      assert [%{kind: "review verdict", head_sha: "abc123", outcome: "approve", recorded_at: @at}] = record.verdicts
    end

    test "keeps the details a verdict carries, and none for a record from before details" do
      details = %{reason: "the sandbox refused the build", model: "claude-opus"}
      record = TicketState.new("repo-a", "issue-1") |> TicketState.record_verdict("qa", "abc123", "blocked", @at, details)
      assert [%{outcome: "blocked", details: ^details}] = record.verdicts

      old = %{TicketState.new("repo-a", "issue-1") | verdicts: [%{kind: "qa", head_sha: "abc123", outcome: "pass", recorded_at: @at}]}
      assert [%{outcome: "pass", details: %{}}] = TicketState.normalize(old).verdicts
      assert [%{details: %{}}] = TicketState.record_verdict(TicketState.new("repo-a", "issue-1"), "qa", "abc123", "pass", @at, nil).verdicts
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

      assert length(record.dispatches) == 50
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

    test "a verdict ends the count the record keeps" do
      record = TicketState.record_dispatch(TicketState.new("repo-a", "issue-1"), %{kind: "implementation", run_id: "run-1"}, @at)
      assert [_run] = record.dispatches

      assert TicketState.record_verdict(record, "code_review", "a", "approve", @at).dispatches == []
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

  describe "pending projections" do
    @at ~U[2026-10-29 09:00:00Z]

    test "a mark replaces the same projection's, keeps the others, and is dropped once projected" do
      record =
        "repo"
        |> TicketState.new("issue-1")
        |> TicketState.mark_projection(:phase, {:error, :boom}, @at)
        |> TicketState.mark_projection(:pause, "label refused", @at)
        |> TicketState.mark_projection(:phase, nil, @at)

      assert record.pending_projection == [
               %{type: :phase, error: nil, at: @at},
               %{type: :pause, error: "label refused", at: @at}
             ]

      assert Enum.map(record.pending_projection, &TicketState.projection_of/1) == [:phase, :pause]
      [phase_mark, label_mark] = record.pending_projection
      cleared = TicketState.clear_projection(record, phase_mark)
      assert cleared.pending_projection == [label_mark]
      assert TicketState.normalize(record) == record
      assert %{pending_projection: [%{type: :phase, at: %DateTime{}}]} = TicketState.mark_projection(%{}, :phase, :boom)
    end

    test "a question's request comment is a mark of its own, by the question's id" do
      record =
        "repo"
        |> TicketState.new("issue-1")
        |> TicketState.mark_projection({:question_comment, "q-1"}, :linear_down, @at)
        |> TicketState.mark_projection({:question_comment, "q-2"}, :linear_down, @at)
        |> TicketState.mark_projection({:question_comment, "q-1"}, :rate_limited, @at)

      assert [%{type: :question_comment, question: "q-1", error: ":rate_limited"}, %{type: :question_comment, question: "q-2"}] =
               record.pending_projection

      assert Enum.map(record.pending_projection, &TicketState.projection_of/1) == [{:question_comment, "q-1"}, {:question_comment, "q-2"}]
      assert TicketState.normalize(record) == record

      # A stored mark that names no question is dropped.
      unnamed = %{pending_projection: [%{type: :question_comment, at: @at}]}
      assert TicketState.normalize(unnamed).pending_projection == []
    end

    test "a Director's answer Linear refused is a mark of its own, by the question and its request comment (TP-1240)" do
      record =
        "repo"
        |> TicketState.new("issue-1")
        |> TicketState.mark_projection({:question_answer, "q-1", "comment-1"}, :linear_down, @at)
        |> TicketState.mark_projection({:question_answer, "q-2", nil}, :linear_down, @at)

      assert [%{type: :question_answer, question: "q-2", comment: nil}, %{question: "q-1", comment: "comment-1"}] =
               record.pending_projection

      names = Enum.map(record.pending_projection, &TicketState.projection_of/1)
      assert names == [{:question_answer, "q-2", nil}, {:question_answer, "q-1", "comment-1"}]
      assert TicketState.normalize(record) == record

      # A stored mark that names no question is dropped.
      unnamed = %{pending_projection: [%{type: :question_answer, comment: "c", at: @at}]}
      assert TicketState.normalize(unnamed).pending_projection == []
    end

    test "a clear drops only the mark it was given: a newer mark of the same projection stays" do
      older = "repo" |> TicketState.new("issue-1") |> TicketState.mark_projection(:phase, :down, @at)
      [projected] = older.pending_projection
      newer = TicketState.mark_projection(older, :phase, :still_down, DateTime.add(@at, 60))

      assert [%{type: :phase, error: ":still_down"}] = TicketState.clear_projection(newer, projected).pending_projection
      assert TicketState.clear_projection(older, projected).pending_projection == []
    end

    test "a not-found stamp reads back as a time, and a record without one reads nil" do
      assert TicketState.normalize(%{not_found_at: @at}).not_found_at == @at
      assert TicketState.normalize(%{}).not_found_at == nil
    end

    test "a stored mark of a retired hold's label reads as a mark of the pause" do
      marks = [%{type: :hold_label, hold: :blocked, error: "down", at: @at}]
      normalized = TicketState.normalize(%{pending_projection: marks})
      assert normalized.pending_projection == [%{type: :pause, error: "down", at: @at}]
    end

    test "a stored mark of no known projection is dropped" do
      marks = [%{type: :phase, error: "  ", at: "yesterday"}, %{type: :other}, "phase"]
      normalized = TicketState.normalize(%{pending_projection: marks})
      assert normalized.pending_projection == [%{type: :phase, error: nil, at: nil}]
      assert TicketState.normalize(%{pending_projection: :phase}).pending_projection == []
    end
  end

  describe "signals_in/1" do
    test "reads the signals the machine and people recorded, newest first, with their details" do
      events = [
        event("phase.entered", %{to: "In Progress", signal: "claim", signal_details: %{from: "Todo", to: "In Progress"}}, at: at(1)),
        event("note", %{text: "agent", signal: "claim"}, actor: %{kind: :agent, run_id: "run-1", run_kind: "implementation"}, at: at(2)),
        event("note", %{text: "no signal"}, at: at(3)),
        event("person.action", %{action: "stop", signal: "stopped", signal_details: %{by: "the Director"}}, actor: %{kind: :person, name: "the Director"}, at: at(4)),
        event("note", %{text: "Waiting for CI (ci_wait_started)", signal: "ci_wait_started", signal_details: %{sha: "abc"}}, at: at(5)),
        event("phase.entered", %{to: "Done", signal: "merge settled", signal_details: %{}}, at: at(6))
      ]

      assert TicketState.signals_in(events) == [
               %{name: "merge settled", details: %{}, at: at(6)},
               %{name: "ci_wait_started", details: %{sha: "abc"}, at: at(5)},
               %{name: "stopped", details: %{by: "the Director"}, at: at(4)},
               %{name: "claim", details: %{from: "Todo", to: "In Progress"}, at: at(1)}
             ]
    end

    test "an event recorded before signals carried their details reads them from its payload" do
      events = [
        event("phase.entered", %{to: "Code Review", via: "handoff", signal: "handoff"}, at: at(1)),
        event("attempt.pushed", %{head: "abc", attempt: 2, signal: "handoff"}, at: at(2)),
        event("phase.entered", %{to: "QA", signal: "code_review"}, at: at(3))
      ]

      assert [
               %{name: "code_review", details: %{to: "QA"}},
               %{name: "handoff", details: %{head: "abc"}},
               %{name: "handoff", details: %{to: "Code Review", via: "handoff", move: true}}
             ] = TicketState.signals_in(events)
    end
  end

  describe "verdicts_in/1" do
    test "reads the machine's verdicts newest first, bound to their heads, with their details" do
      events = [
        event("verdict.recorded", %{kind: "qa", outcome: "blocked", head: "abc", details: %{model: "m", reason: "no emulator"}}, at: at(1)),
        event("verdict.recorded", %{kind: "ci_fix", outcome: "mechanical", signal: "fix verdict"}, at: at(2)),
        event("verdict.recorded", %{kind: "code_review", outcome: "approve", head: "def", reason: "fine"}, at: at(3)),
        event("verdict.recorded", %{kind: "qa", outcome: "pass"}, actor: %{kind: :agent, run_id: "run-1", run_kind: "qa"}, at: at(4)),
        event("note", %{text: "not a verdict"}, at: at(5))
      ]

      assert TicketState.verdicts_in(events) == [
               %{kind: "code_review", head_sha: "def", outcome: "approve", recorded_at: at(3), details: %{}},
               %{kind: "qa", head_sha: "abc", outcome: "blocked", recorded_at: at(1), details: %{model: "m", reason: "no emulator"}}
             ]
    end
  end

  describe "dispatches_in/1" do
    test "lists the runs since the last progress newest first, with how each ended" do
      events = [
        started("run-0", at(0)),
        verdict(at(1)),
        started("run-1", at(2), head: "a"),
        started("run-2", at(3)),
        event("run.ended", %{run_id: "run-1", exit: "ended normally", head: "b", counted: true}, at: at(4)),
        started("run-3", at(5)),
        event("run.ended", %{run_id: "run-3", exit: "usage limit", counted: false}, at: at(6)),
        event("run.ended", %{run_id: "run-9", exit: "ended normally"}, at: at(7)),
        # A verdict a signal records is that signal's: it is no progress here.
        event("verdict.recorded", %{kind: "ci_fix", outcome: "mechanical", signal: "fix verdict"}, at: at(8))
      ]

      assert TicketState.dispatches_in(events) == [
               %{kind: "implementation", run_id: "run-2", state: "In Progress", head: nil, at: at(3), outcome: nil},
               %{kind: "implementation", run_id: "run-1", state: "In Progress", head: "a", at: at(2), outcome: %{exit: "ended normally", head: "b", at: at(4)}}
             ]
    end

    test "a verdict and a lifted pause reason end the count, and the list is bounded" do
      assert TicketState.dispatches_in([started("run-1", at(1)), verdict(at(2))]) == []
      assert TicketState.dispatches_in([started("run-1", at(1)), event("pause.reason_cleared", %{reason: "question"}, at: at(2))]) == []
      assert TicketState.dispatches_in([started("run-1", at(1)), event("pause.cleared", %{cleared: []}, at: at(2))]) == []
      assert [%{run_id: "run-2"}] = TicketState.dispatches_in([started("run-1", at(1)), verdict(at(2)), started("run-2", at(3))])

      # A pause set is no progress, nor is a run's end with no exit.
      events = [started("run-1", at(1)), event("pause.set", %{reason: "question"}, at: at(2)), event("run.ended", %{run_id: "run-1"}, at: at(3))]
      assert [%{run_id: "run-1", kind: "implementation", outcome: %{exit: "", head: nil}}] = TicketState.dispatches_in(events)
      assert [%{kind: ""}] = TicketState.dispatches_in([event("run.started", %{run_id: "run-1"}, at: at(1))])

      runs = for n <- 1..60, do: started("run-#{n}", at(n))
      assert [%{run_id: "run-60"} | _rest] = dispatches = TicketState.dispatches_in(runs)
      assert length(dispatches) == 50
    end
  end

  test "the mutators default their timestamp to now" do
    record = TicketState.new("repo-a", "issue-1")

    assert %DateTime{} = TicketState.put_phase(record, "Todo").updated_at
    assert %DateTime{} = TicketState.record_verdict(record, "review verdict", "sha", "approve").updated_at
    assert %DateTime{} = TicketState.record_ci_state(record, "sha", "green").updated_at
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
            delivered_at: @at,
            read_ci: :red,
            base_ref: "main",
            github: {:rate_limited, @at},
            rate_limit: %{remaining: 12, limit: 5000, reset_at: @at},
            landing: landing,
            stay: :qa,
            decision: %{rule: "R1"},
            applied: [%{rule: "R24"}, :junk],
            attempts: %{red: 2},
            fix: %{ci_failure: %{commit_sha: "abc"}, pr_conflict: :junk},
            links: :junk,
            actions: [%{rule: "R1"}, :junk, %{rule: "R2"}, %{rule: "R3"}, %{rule: "R4"}, %{rule: "R5"}, %{rule: "R6"}],
            silent: %{since: @at, ticks: 2, bound: " ", reason: "quiet", extra: 1},
            protected_files: %{head_sha: "abc", paths: ["WORKFLOW.md", :junk]},
            upkeep_failure: %{rule: "U1", kind: :update_branch, head_sha: "abc", error: ":forbidden", at: @at, extra: 1}
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
               delivered_at: @at,
               read_ci: :red,
               base_ref: "main",
               github: {:rate_limited, @at},
               rate_limit: %{remaining: 12, limit: 5000, reset_at: @at},
               landing: %{
                 state: "QA",
                 head_sha: "abc",
                 state_since: @at,
                 progress_at: @at,
                 files: nil,
                 waits_for: nil,
                 waits_since: nil
               },
               stay: :qa,
               decision: %{rule: "R1"},
               applied: [%{rule: "R24"}],
               attempts: %{Attempts.new() | red: 2},
               fix: %{ci_failure: %{commit_sha: "abc"}, pr_conflict: nil},
               links: [],
               actions: [%{rule: "R1"}, %{rule: "R2"}, %{rule: "R3"}, %{rule: "R4"}, %{rule: "R5"}],
               silent: %{since: @at, ticks: 2, bound: nil, reason: "quiet"},
               protected_files: %{head_sha: "abc", paths: ["WORKFLOW.md"]},
               upkeep_failure: %{rule: "U1", kind: :update_branch, head_sha: "abc", error: ":forbidden", at: @at}
             }

      assert TicketState.normalize(record) == record
      assert TicketState.pr_watch(TicketState.put_pr_watch(record, nil)) == nil
    end

    test "fills the defaults of a sparse record and drops one without facts" do
      facts = Facts.new()

      sparse = TicketState.new("repo-a", "issue-1", %{pr_watch: %{facts: facts, github: :odd, landing: %{state: "QA"}}})

      assert %{
               source: :poll,
               delivered_at: nil,
               read_ci: nil,
               base_ref: nil,
               github: :ok,
               rate_limit: nil,
               landing: nil,
               stay: nil,
               decision: nil,
               applied: [],
               links: [],
               actions: [],
               silent: nil,
               protected_files: nil,
               upkeep_failure: nil
             } =
               TicketState.pr_watch(sparse)

      junk_failure = TicketState.new("repo-a", "issue-1", %{pr_watch: %{facts: facts, upkeep_failure: %{rule: "U1", kind: :update_branch, error: :forbidden}}})
      assert %{upkeep_failure: nil} = TicketState.pr_watch(junk_failure)

      assert %{attempts: attempts, fix: %{ci_failure: nil, pr_conflict: nil}} = TicketState.pr_watch(sparse)
      assert attempts == Attempts.new()
      assert %{stay: nil} = TicketState.pr_watch(TicketState.new("repo-a", "issue-1", %{pr_watch: %{facts: facts, stay: :done}}))

      assert %{github: {:rate_limited, nil}, rate_limit: %{remaining: nil, reset_at: nil}} =
               TicketState.pr_watch(TicketState.new("repo-a", "issue-1", %{pr_watch: %{facts: facts, github: {:rate_limited, "soon"}, rate_limit: %{remaining: -1}}}))

      assert TicketState.pr_watch(TicketState.new("repo-a", "issue-1", %{pr_watch: %{facts: %{phase: :qa}}})) == nil
      assert TicketState.pr_watch(TicketState.new("repo-a", "issue-1", %{pr_watch: :junk})) == nil
      assert %DateTime{} = TicketState.put_pr_watch(TicketState.new("repo-a", "issue-1"), nil).updated_at
    end
  end

  describe "observe/3" do
    @linear_at ~U[2026-10-29 09:00:00Z]
    @observed_at ~U[2026-10-29 09:05:00Z]
    @created_at ~U[2026-10-01 08:00:00Z]
    @team %{key: "ACME", name: "Acme"}
    @project %{id: "project-1", name: "Symphony", slug_id: "symphony-1a2b"}
    @observed_fields ~w(issue_identifier phase title description team project labels priority assignee blockers sub_issues parent url created_at linear_updated_at)a

    defp linear_issue(attrs \\ %{}) do
      struct!(
        %Issue{
          id: "issue-1",
          identifier: "ACME-1",
          title: "Observe every poll",
          description: "## Why\n\nThe record learns from every poll.",
          team: @team,
          project: @project,
          state: "In Progress",
          labels: ["backend", "plan"],
          priority: 1,
          assignee_id: "user-1",
          blocked_by: [%{id: "issue-0", identifier: "ACME-0", state: "Todo"}, %{id: nil, identifier: nil, state: nil}],
          sub_issues: [%{id: "issue-2", identifier: "ACME-2", state: "Todo"}, %{id: "issue-3", identifier: "ACME-3", state: "Done"}],
          url: "https://linear.app/acme/issue/ACME-1",
          created_at: @created_at,
          updated_at: @linear_at
        },
        attrs
      )
    end

    test "a new record takes every field of the issue, with when it was observed" do
      assert {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(), @observed_at)

      assert Map.take(record, @observed_fields ++ [:observed_at, :updated_at]) ==
               %{
                 issue_identifier: "ACME-1",
                 phase: "In Progress",
                 title: "Observe every poll",
                 description: "## Why\n\nThe record learns from every poll.",
                 team: @team,
                 project: @project,
                 labels: ["backend", "plan"],
                 priority: 1,
                 assignee: "user-1",
                 blockers: [%{id: "issue-0", identifier: "ACME-0", state: "Todo"}],
                 sub_issues: [%{id: "issue-2", identifier: "ACME-2", state: "Todo"}, %{id: "issue-3", identifier: "ACME-3", state: "Done"}],
                 parent: nil,
                 url: "https://linear.app/acme/issue/ACME-1",
                 created_at: @created_at,
                 linear_updated_at: @linear_at,
                 observed_at: @observed_at,
                 updated_at: @observed_at
               }
    end

    test "the same issue again changes nothing, and keeps the first observation's time" do
      {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(), @observed_at)

      assert {^record, :unchanged} = TicketState.observe(record, linear_issue(), DateTime.add(@observed_at, 60))
    end

    test "a newer fact overwrites the observed fields and leaves the rest of the record" do
      {record, :changed} =
        "repo-a"
        |> TicketState.new("issue-1")
        |> TicketState.record_verdict("review verdict", "abc", "approve", @at)
        |> TicketState.observe(linear_issue(), @observed_at)

      newer = linear_issue(%{title: "Renamed", state: "Code Review", labels: [], priority: nil, assignee_id: nil, blocked_by: [], updated_at: DateTime.add(@linear_at, 600)})
      later = DateTime.add(@observed_at, 600)

      assert {observed, :changed} = TicketState.observe(record, newer, later)
      assert {observed.title, observed.phase, observed.labels, observed.priority, observed.assignee, observed.blockers} == {"Renamed", "Code Review", [], nil, nil, []}
      assert {observed.linear_updated_at, observed.observed_at, observed.phase_at} == {DateTime.add(@linear_at, 600), later, later}
      assert observed.phase_owner == :external
      assert [%{kind: "review verdict", outcome: "approve"}] = observed.verdicts
    end

    test "a change that keeps the phase keeps when the phase was written" do
      {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(), @observed_at)
      assert record.phase_at == @observed_at

      renamed = linear_issue(%{title: "Renamed", updated_at: DateTime.add(@linear_at, 60)})
      assert {%{title: "Renamed", phase_at: @observed_at}, :changed} = TicketState.observe(record, renamed, DateTime.add(@observed_at, 60))
    end

    test "a change that keeps the phase keeps who wrote it; a missing state keeps Symphony's phase" do
      owned = TicketState.new("repo-a", "issue-1") |> TicketState.put_phase("Code Review", @at)
      renamed = linear_issue(%{title: "Renamed", state: "Code Review"})

      assert {%{phase_owner: :symphony, phase_at: @at}, :changed} = TicketState.observe(owned, renamed, @observed_at)
      without_state = %{renamed | state: nil}
      assert {%{phase: "Code Review", phase_owner: :symphony}, :changed} = TicketState.observe(owned, without_state, @observed_at)
    end

    test "an older fact is dropped and the record returned as it was" do
      {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(), @observed_at)
      older = linear_issue(%{title: "Old title", state: "Todo", updated_at: DateTime.add(@linear_at, -1)})

      assert {^record, :stale} = TicketState.observe(record, older, DateTime.add(@observed_at, 60))
    end

    test "an unknown field, a missing state and a missing updatedAt keep the known values" do
      {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(), @observed_at)
      delivery = linear_issue(%{blocked_by: :unknown, state: nil, identifier: nil, updated_at: nil, title: "Renamed"})

      assert {observed, :changed} = TicketState.observe(record, delivery, DateTime.add(@observed_at, 60))
      assert {observed.blockers, observed.phase, observed.issue_identifier, observed.linear_updated_at} == {record.blockers, "In Progress", "ACME-1", @linear_at}
      assert observed.title == "Renamed"
    end

    test "a sub-issue's new state is a change; unknown sub-issues, a missing parent and a missing creation time keep the known ones" do
      parent = %{identifier: "ACME-0", title: "Epic", done: 0, total: 1, children: ["started"]}
      {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(%{parent: parent}), @observed_at)
      assert record.parent == parent

      moved = linear_issue(%{sub_issues: [%{id: "issue-2", identifier: "ACME-2", state: "In Progress"}], parent: nil, created_at: nil})
      assert {observed, :changed} = TicketState.observe(record, moved, DateTime.add(@observed_at, 60))
      assert {observed.sub_issues, observed.parent, observed.created_at} == {[%{id: "issue-2", identifier: "ACME-2", state: "In Progress"}], parent, @created_at}

      delivery = linear_issue(%{sub_issues: :unknown, parent: nil, created_at: nil})
      assert {^record, :unchanged} = TicketState.observe(record, delivery, DateTime.add(@observed_at, 60))
    end

    test "an edited description is one change; a read's empty description, team or project clears the record's" do
      {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(), @observed_at, :poll)

      edited = linear_issue(%{description: "## Why\n\nEdited.", updated_at: DateTime.add(@linear_at, 60)})
      assert {observed, :changed} = TicketState.observe(record, edited, DateTime.add(@observed_at, 60), :poll)
      assert Map.drop(observed, [:description, :linear_updated_at, :observed_at, :updated_at]) == Map.drop(record, [:description, :linear_updated_at, :observed_at, :updated_at])
      assert observed.description == "## Why\n\nEdited."
      assert {^observed, :unchanged} = TicketState.observe(observed, edited, DateTime.add(@observed_at, 120), :poll)

      for source <- [:poll, :by_id, :watcher, nil] do
        cleared = linear_issue(%{description: nil, team: nil, project: nil})
        assert {%{description: nil, team: nil, project: nil}, :changed} = TicketState.observe(record, cleared, DateTime.add(@observed_at, 60), source)
      end
    end

    test "a webhook delivery that leaves out the description, team or project keeps the record's" do
      {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(), @observed_at, :poll)

      delivery = linear_issue(%{description: nil, team: nil, project: nil})
      assert {^record, :unchanged} = TicketState.observe(record, delivery, DateTime.add(@observed_at, 60), :webhook)

      moved = linear_issue(%{description: nil, team: %{key: "OPS", name: "Ops"}, project: nil})
      assert {observed, :changed} = TicketState.observe(record, moved, DateTime.add(@observed_at, 60), :webhook)
      assert {observed.description, observed.team, observed.project} == {record.description, %{key: "OPS", name: "Ops"}, @project}
    end

    test "a delivery's project, which has no slug id, keeps the slug id a read recorded for the same project" do
      {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(), @observed_at, :poll)

      same = linear_issue(%{project: %{id: "project-1", name: "Symphony"}})
      assert {^record, :unchanged} = TicketState.observe(record, same, DateTime.add(@observed_at, 60), :webhook)

      renamed = linear_issue(%{project: %{id: "project-1", name: "Symphony Engine"}})
      assert {%{project: %{id: "project-1", name: "Symphony Engine", slug_id: "symphony-1a2b"}}, :changed} = TicketState.observe(record, renamed, DateTime.add(@observed_at, 60), :webhook)

      other = linear_issue(%{project: %{id: "project-2", name: "Director"}})
      assert {%{project: %{id: "project-2", name: "Director", slug_id: nil}}, :changed} = TicketState.observe(record, other, DateTime.add(@observed_at, 60), :webhook)

      {unprojected, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(%{project: nil}), @observed_at, :poll)
      assert {%{project: %{id: "project-1", name: "Symphony", slug_id: nil}}, :changed} = TicketState.observe(unprojected, same, DateTime.add(@observed_at, 60), :webhook)
    end

    test "observation/1 is the update that writes the observed fields" do
      {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(), @observed_at)

      assert TicketState.observation(record) == Map.take(record, @observed_fields ++ [:phase_at, :phase_owner, :observed_at, :observed_from, :updated_at])
    end

    test "a change keeps which read brought it; an unchanged read keeps the last one" do
      {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(), @observed_at, :webhook)
      assert record.observed_from == :webhook
      assert TicketState.observation(record).observed_from == :webhook

      assert {^record, :unchanged} = TicketState.observe(record, linear_issue(), DateTime.add(@observed_at, 60), :poll)

      renamed = linear_issue(%{title: "Renamed", updated_at: DateTime.add(@linear_at, 60)})
      assert {%{observed_from: :by_id}, :changed} = TicketState.observe(record, renamed, DateTime.add(@observed_at, 60), :by_id)
      assert {%{observed_from: nil}, :changed} = TicketState.observe(record, renamed, DateTime.add(@observed_at, 60))
    end

    test "reads an unknown source and a malformed removal time as nil" do
      record = TicketState.normalize(%{observed_from: :carrier_pigeon, removed_at: "yesterday"})
      assert {record.observed_from, record.removed_at} == {nil, nil}
      assert TicketState.normalize(%{observed_from: :watcher}).observed_from == :watcher
    end

    test "mark_removed/2 sets when the ticket was removed and leaves the rest" do
      {record, :changed} = TicketState.observe(TicketState.new("repo-a", "issue-1"), linear_issue(), @observed_at, :poll)
      removed = TicketState.mark_removed(record, DateTime.add(@observed_at, 30))

      assert {removed.removed_at, removed.updated_at} == {DateTime.add(@observed_at, 30), DateTime.add(@observed_at, 30)}
      assert Map.drop(removed, [:removed_at, :updated_at]) == Map.drop(record, [:removed_at, :updated_at])
    end
  end

  # An event as the ticket's stream holds it, oldest first by `at` (`SymphonyElixir.TicketEvents`).
  defp event(type, payload, opts) do
    %Event{type: type, payload: payload, actor: Keyword.get(opts, :actor, %{kind: :machine}), at: Keyword.fetch!(opts, :at)}
  end

  defp started(run_id, at, opts \\ []) do
    payload = %{run_id: run_id, run_kind: "implementation", state: "In Progress"}
    payload = if opts[:head], do: Map.put(payload, :head, opts[:head]), else: payload
    event("run.started", payload, at: at)
  end

  defp verdict(at), do: event("verdict.recorded", %{kind: "code_review", outcome: "approve"}, at: at)

  defp at(minute), do: DateTime.add(@at, minute * 60, :second)
end

defmodule SymphonyElixir.TicketStateViewsTest do
  # The views read the ticket's events from the store, so these run one at a time.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Pauses, TicketSignals, TicketState}

  @repo_key "repo-views"
  @issue_id "issue-views"
  @ticket {:ticket, @repo_key, @issue_id}

  describe "the views over a ticket's events" do
    test "read the ticket's stored events, and nothing for a record that names no ticket" do
      :ok = put_signal(@repo_key, @issue_id, "claim", %{from: "Todo", to: "In Progress"})
      :ok = put_verdict(@repo_key, @issue_id, "qa", "abc", "fail", %{reason: "clipped"})
      :ok = put_dispatch(@repo_key, @issue_id, %{kind: :rework, run_id: "run-1", state: "Rework", head: "abc"})

      record = %{issue_id: @issue_id}
      assert [%{name: "claim", details: %{from: "Todo", to: "In Progress"}}] = TicketState.signals(record)
      assert [%{name: "claim"}] = TicketState.recent_signals(record, 1)
      assert TicketState.recent_signals(record, 0) == []
      assert [%{kind: "qa", head_sha: "abc", outcome: "fail", details: %{reason: "clipped"}}] = TicketState.verdicts(record)
      assert [%{kind: "rework", run_id: "run-1", state: "Rework", head: "abc", outcome: nil}] = TicketState.dispatches(record)

      for record <- [%{}, %{issue_id: nil}, TicketState.normalize(nil)] do
        assert TicketState.signals(record) == []
        assert TicketState.recent_signals(record) == []
        assert TicketState.verdicts(record) == []
        assert TicketState.dispatches(record) == []
      end
    end

    test "are not bounded by the record's own lists" do
      for n <- 1..55, do: :ok = put_signal(@repo_key, @issue_id, "ci_rerun", %{sha: "sha-#{n}"})

      assert length(RunStore.get_ticket_state(@issue_id).signals) == 50
      assert length(TicketState.signals(%{issue_id: @issue_id})) == 55
      assert [%{details: %{sha: "sha-55"}} | _rest] = TicketState.recent_signals(%{issue_id: @issue_id})
    end

    test "a ticket that lived through signals, verdicts, runs and pauses reads from each view what its fields hold" do
      # As the live writers record them: the signals and verdicts through `TicketSignals`, each run
      # as the orchestrator records its dispatch and its end, the pauses through `Pauses`.
      :ok = TicketSignals.record(@repo_key, @issue_id, "ci_wait_started", %{sha: "aaa1111"})
      :ok = TicketSignals.record(@repo_key, @issue_id, "merge settled", %{})
      :ok = dispatch("run-1", "In Progress", "aaa1111")
      :ok = ended("run-1", %{exit: "failed (:boom)", head: "aaa1111"})
      :ok = TicketSignals.record(@repo_key, @issue_id, "code_review", %{signal: "merge_confirmation", reason: "ready", head: "aaa1111"})
      :ok = TicketSignals.record_verdict(@repo_key, @issue_id, "code_review", "aaa1111", "approve", %{reason: "fine"})
      :ok = dispatch("run-2", "Code Review", "aaa1111")
      :ok = ended("run-2", %{counted: false})
      :ok = dispatch("run-3", "QA", "aaa1111")
      :ok = TicketSignals.record(@repo_key, @issue_id, "fix verdict", %{outcome: "mechanical", head: "bbb2222"})
      assert_views_equal_fields(1)

      {:ok, _pause} = Pauses.set(@ticket, %{kind: :ticket, waits_on: %{identifier: "TP-1"}})
      {:ok, _pause} = Pauses.set(@ticket, %{kind: :question, waits_on: %{question_id: "q-1"}})
      :ok = ended("run-3", %{exit: "ended normally", head: "bbb2222"})
      :ok = dispatch("run-4", "QA", "bbb2222")
      assert_views_equal_fields(2)

      # A reason lifted is progress: the runs before it are no longer counted.
      {:ok, _pause} = Pauses.clear_reason(@ticket, %{kind: :question, waits_on: %{question_id: "q-1"}})
      assert_views_equal_fields(0)

      :ok = dispatch("run-5", "QA", "bbb2222")
      {:ok, _pause} = Pauses.clear(@ticket)
      assert_views_equal_fields(0)

      :ok = dispatch("run-6", "QA", "bbb2222")
      :ok = TicketSignals.record_verdict(@repo_key, @issue_id, "qa", "bbb2222", "pass")
      assert_views_equal_fields(0)
    end
  end

  describe "the readers" do
    test "no module outside the record and its writers reads the record's signals, verdicts or dispatches" do
      # A field read off a record (`record.signals`, `TicketState.normalize(record).verdicts`), a
      # `Map.fetch!/2` or `Map.get/2` of one, or a match on one.
      reads =
        ~r/(\b(record|ticket_state|state|stored|ticket)|\))\.(signals|verdicts|dispatches)\b(?!\()|Map\.(fetch!?|get)\([^)]*:(signals|verdicts|dispatches)\b|%\{[^}]*\b(signals|verdicts|dispatches): [a-z_]+[,}]/

      # The record, the store that writes it, and the ledger's backfill that converts what it kept.
      owners = ["lib/symphony_elixir/ticket_state.ex", "lib/symphony_elixir/run_store.ex", "lib/symphony_elixir/ticket_events/backfill.ex"]

      offenders =
        for path <- Path.wildcard("lib/**/*.ex"),
            path not in owners,
            {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            Regex.match?(reads, line),
            do: "#{path}:#{number}: #{String.trim(line)}"

      assert offenders == []

      # The pattern finds a reader where there is one.
      assert Regex.match?(reads, "    case CiWait.since(record.signals, sha) do")
      assert Regex.match?(reads, "      record -> record |> TicketState.normalize() |> Map.fetch!(:verdicts)")
      assert Regex.match?(reads, "  defp run_heads(%{dispatches: dispatches}) do")
      refute Regex.match?(reads, "    case CiWait.since(TicketState.signals(record), sha) do")
    end
  end

  defp dispatch(run_id, state, head) do
    dispatch = %{kind: :implementation, run_id: run_id, state: state, head: head}
    :ok = RunStore.record_ticket_dispatch(@repo_key, @issue_id, dispatch)
    payload = %{run_id: run_id, run_kind: "implementation", state: state, head: head}
    TicketSignals.record_event(@repo_key, @issue_id, "run.started", payload, run_id: run_id)
  end

  defp ended(run_id, attrs) do
    :ok = RunStore.record_ticket_dispatch_outcome(@repo_key, @issue_id, run_id, attrs)
    payload = %{run_id: run_id, exit: Map.get(attrs, :exit, "usage limit"), head: Map.get(attrs, :head), counted: Map.get(attrs, :counted, true)}
    TicketSignals.record_event(@repo_key, @issue_id, "run.ended", payload, run_id: run_id)
  end

  # Each view equals the field the record still keeps, but for the times: the field takes its own
  # clock reading, a moment before its event's.
  defp assert_views_equal_fields(dispatches) do
    record = TicketState.normalize(RunStore.get_ticket_state(@issue_id))

    assert untimed(TicketState.signals(record)) == untimed(record.signals)
    assert untimed(TicketState.verdicts(record)) == untimed(record.verdicts)
    assert untimed(TicketState.dispatches(record)) == untimed(record.dispatches)
    assert length(record.dispatches) == dispatches

    pairs = [
      {TicketState.signals(record), record.signals},
      {TicketState.verdicts(record), record.verdicts},
      {TicketState.dispatches(record), record.dispatches}
    ]

    for {view, field} <- pairs,
        {viewed, kept} <- Enum.zip(view, field),
        key <- [:at, :recorded_at],
        Map.has_key?(kept, key) do
      assert abs(DateTime.diff(Map.fetch!(viewed, key), Map.fetch!(kept, key), :millisecond)) < 1_000
    end
  end

  defp untimed(entries) do
    for entry <- entries do
      entry
      |> Map.drop([:at, :recorded_at])
      |> Map.replace_lazy(:outcome, fn
        %{} = outcome -> Map.delete(outcome, :at)
        outcome -> outcome
      end)
    end
  end
end
