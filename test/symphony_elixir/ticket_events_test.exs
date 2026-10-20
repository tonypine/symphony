defmodule SymphonyElixir.TicketEventsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TicketEvents
  alias SymphonyElixir.TicketEvents.Event

  @repo_key "repo-a"
  @issue_id "issue-1"
  @at ~U[2026-10-20 10:00:00.000000Z]

  setup do
    :ok = RunStore.clear()
  end

  describe "record/5" do
    test "a second verdict with the same idempotency key returns the first event and writes nothing" do
      payload = %{kind: "qa", outcome: "pass", head: "abc"}

      assert {:ok, first} = TicketEvents.record(@repo_key, @issue_id, "verdict.recorded", payload, idempotency: "verdict:qa:abc")
      assert {:ok, ^first} = TicketEvents.record(@repo_key, @issue_id, "verdict.recorded", payload, idempotency: "verdict:qa:abc")

      assert [^first] = TicketEvents.query(@repo_key, @issue_id)
      assert first.seq == 1
      assert first.idempotency == "verdict:qa:abc"
      assert RunStore.get_ticket_state(@repo_key, @issue_id).event_seq == 1
    end

    test "the same key on another ticket is another event" do
      assert {:ok, %{seq: 1}} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "x"}, idempotency: "k")
      assert {:ok, %{seq: 1, issue_id: "issue-2"}} = TicketEvents.record(@repo_key, "issue-2", "note", %{text: "x"}, idempotency: "k")
    end

    test "a type's rule derives the key when the writer passes none" do
      payload = %{run_id: "run-1", run_kind: "qa"}

      assert {:ok, started} = TicketEvents.record(@repo_key, @issue_id, "run.started", payload)
      assert {:ok, ^started} = TicketEvents.record(@repo_key, @issue_id, "run.started", payload)
      assert started.idempotency == "run.started:run-1"
      assert length(TicketEvents.query(@repo_key, @issue_id)) == 1
    end

    test "builds the event from its options" do
      assert {:ok, event} =
               TicketEvents.record(@repo_key, @issue_id, "evidence", %{"caption" => "After"},
                 actor: {:agent, "run-7", :qa},
                 phase: "QA",
                 head_sha: "abc123",
                 parent: "01PARENT",
                 supersedes: " ",
                 artifacts: ["artifact-1"],
                 at: @at
               )

      assert %Event{
               repo_key: @repo_key,
               issue_id: @issue_id,
               type: "evidence",
               phase: "QA",
               actor: %{kind: :agent, run_id: "run-7", run_kind: "qa"},
               run_id: "run-7",
               head_sha: "abc123",
               parent: "01PARENT",
               supersedes: nil,
               idempotency: nil,
               payload: %{caption: "After"},
               summary: nil,
               artifacts: ["artifact-1"],
               at: @at,
               seq: 1
             } = event

      assert String.length(event.id) == 26
      assert [^event] = RunStore.list_ticket_events(@repo_key, @issue_id, [])
    end

    test "defaults to the machine, now, and the phase the ticket's record holds" do
      :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, phase: "Code Review"})

      assert {:ok, event} = TicketEvents.record(@repo_key, @issue_id, "phase.entered", %{to: "QA", from: "Code Review"}, run_id: "run-2")

      assert event.actor == %{kind: :machine}
      assert event.phase == "Code Review"
      assert event.run_id == "run-2"
      assert DateTime.diff(DateTime.utc_now(), event.at) < 60
      assert %{phase: "Code Review", event_seq: 1} = RunStore.get_ticket_state(@repo_key, @issue_id)
    end

    test "records a person's answer" do
      assert {:ok, %{actor: %{kind: :person, name: "Tony"}}} =
               TicketEvents.record(@repo_key, @issue_id, "decision.recorded", %{answer: "Ship it"}, actor: {:person, "Tony"})

      assert {:ok, %{actor: %{kind: :person, name: "Tony"}}} =
               TicketEvents.record(@repo_key, @issue_id, "person.action", %{action: "stop"}, actor: %{kind: "person", name: "Tony"})
    end

    test "rejects an unknown type, an invalid payload, a writer outside the type's and a bad option" do
      assert {:error, {:unknown_type, "nope"}} = TicketEvents.record(@repo_key, @issue_id, "nope", %{})
      assert {:error, {:invalid_payload, [:kind]}} = TicketEvents.record(@repo_key, @issue_id, "hold.set", %{kind: "needs_decision"})

      assert {:error, {:not_allowed, _reason}} =
               TicketEvents.record(@repo_key, @issue_id, "verdict.recorded", %{kind: "qa", outcome: "pass"}, actor: {:agent, "run-1", "qa"})

      assert {:error, {:invalid_actor, {:agent, "run-1", nil}}} =
               TicketEvents.record(@repo_key, @issue_id, "note", %{text: "x"}, actor: {:agent, "run-1", nil})

      assert {:error, {:invalid_option, :run_id}} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "x"}, run_id: 7)
      assert {:error, {:invalid_option, :artifacts}} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "x"}, artifacts: [""])
      assert {:error, {:invalid_option, :artifacts}} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "x"}, artifacts: "a")
      assert {:error, {:invalid_option, :at}} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "x"}, at: "now")
      assert {:error, :invalid_repo_key} = TicketEvents.record(" ", @issue_id, "note", %{text: "x"})
      assert {:error, :invalid_ticket_event} = TicketEvents.record(@repo_key, nil, "note", %{text: "x"})

      assert TicketEvents.query(@repo_key, @issue_id) == []
    end
  end

  describe "query/3" do
    test "a decision request is open until a decision recorded names it" do
      assert {:ok, request} = TicketEvents.record(@repo_key, @issue_id, "decision.requested", %{question: "Ship it?", title: "Ship"})
      assert {:ok, _note} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "waiting"})

      assert [^request] = TicketEvents.query(@repo_key, @issue_id, open_decisions: true)

      assert {:ok, _ruling} =
               TicketEvents.record(@repo_key, @issue_id, "decision.recorded", %{answer: "No", key: "ruling-c9"}, actor: {:person, "Tony"})

      assert [^request] = TicketEvents.query(@repo_key, @issue_id, open_decisions: true)

      assert {:ok, _answer} =
               TicketEvents.record(@repo_key, @issue_id, "decision.recorded", %{answer: "Yes", key: "c1", request: request.id}, actor: {:person, "Tony"})

      assert TicketEvents.query(@repo_key, @issue_id, open_decisions: true) == []
    end

    test "a withdrawal closes a decision request too" do
      assert {:ok, request} = TicketEvents.record(@repo_key, @issue_id, "decision.requested", %{question: "Q?"}, actor: {:agent, nil, "implementation"})
      assert {:ok, _} = TicketEvents.record(@repo_key, @issue_id, "decision.withdrawn", %{title: "Q", request: request.id})

      assert TicketEvents.query(@repo_key, @issue_id, open_decisions: true) == []
    end

    test "a finding is open until an unsuperseded resolution names it" do
      qa = {:agent, "run-qa", "qa"}
      finding = %{class: "unclassified", severity: "high", description: "Clipped label."}

      assert {:ok, finding} = TicketEvents.record(@repo_key, @issue_id, "finding.recorded", finding, actor: qa)
      assert {:ok, request} = TicketEvents.record(@repo_key, @issue_id, "decision.requested", %{question: "Q?"})
      assert [^finding] = TicketEvents.query(@repo_key, @issue_id, open_findings: true)

      assert {:ok, resolution} =
               TicketEvents.record(@repo_key, @issue_id, "finding.resolved", %{finding_id: finding.id, how: "Widened it"}, actor: {:agent, "run-rw", "rework"})

      assert TicketEvents.query(@repo_key, @issue_id, open_findings: true) == []

      assert {:ok, _reopen} =
               TicketEvents.record(@repo_key, @issue_id, "verdict.recorded", %{kind: "qa", outcome: "fail"}, supersedes: resolution.id)

      assert [^finding] = TicketEvents.query(@repo_key, @issue_id, open_findings: true)
      assert [^finding, ^request] = TicketEvents.query(@repo_key, @issue_id, open_findings: true, open_decisions: true)
      assert [^finding] = TicketEvents.query(@repo_key, @issue_id, open_findings: true, open_decisions: true, limit: 0)
    end

    test "filters by types, run and since (exclusive), oldest first" do
      record_at = fn type, payload, at, opts -> TicketEvents.record(@repo_key, @issue_id, type, payload, [at: at] ++ opts) end

      assert {:ok, second} = record_at.("note", %{text: "second"}, DateTime.add(@at, 2), run_id: "run-1")
      assert {:ok, first} = record_at.("note", %{text: "first"}, @at, [])
      assert {:ok, third} = record_at.("phase.entered", %{to: "QA"}, DateTime.add(@at, 3), run_id: "run-1")

      assert [^first, ^second, ^third] = TicketEvents.query(@repo_key, @issue_id)
      assert [^first, ^second] = TicketEvents.query(@repo_key, @issue_id, types: ["note"])
      assert [^third] = TicketEvents.query(@repo_key, @issue_id, types: "phase.entered")
      assert [^second, ^third] = TicketEvents.query(@repo_key, @issue_id, run_id: "run-1")
      assert [^third] = TicketEvents.query(@repo_key, @issue_id, since: second.at)
    end

    test "pages by limit, never ending a page inside a group that shares one at" do
      later = DateTime.add(@at, 1)

      events =
        for {at, n} <- [{@at, 1}, {later, 2}, {later, 3}, {later, 4}, {DateTime.add(@at, 2), 5}] do
          {:ok, event} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "n#{n}"}, at: at)
          event
        end

      [e1, e2, e3, e4, e5] = events

      assert [^e1, ^e2, ^e3, ^e4] = TicketEvents.query(@repo_key, @issue_id, limit: 2)
      assert [^e5] = TicketEvents.query(@repo_key, @issue_id, limit: 2, since: e4.at)
      assert [^e1] = TicketEvents.query(@repo_key, @issue_id, limit: -3)
      assert ^events = TicketEvents.query(@repo_key, @issue_id, limit: :all)
    end

    test "returns at most 50 by default and 200 at most" do
      for n <- 1..201 do
        assert {:ok, _} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "n#{n}"}, at: DateTime.add(@at, n))
      end

      assert length(TicketEvents.query(@repo_key, @issue_id)) == 50
      assert length(TicketEvents.query(@repo_key, @issue_id, limit: 500)) == 200
    end

    test "passes a store error through" do
      assert TicketEvents.query(@repo_key, nil) == {:error, :invalid_issue_id}
    end
  end

  describe "Event" do
    test "normalize/1 reads a stored record into its expected shape" do
      event =
        Event.normalize(%{
          id: " 01ID ",
          seq: -1,
          at: "yesterday",
          type: "note",
          actor: %{kind: "agent", run_id: " ", run_kind: :qa},
          payload: :junk,
          summary: %{title: "Title", detail: " "},
          artifacts: ["a1", "", 3]
        })

      assert %Event{
               id: "01ID",
               seq: nil,
               at: nil,
               actor: %{kind: :agent, run_id: nil, run_kind: "qa"},
               payload: %{},
               summary: %{title: "Title", detail: nil},
               artifacts: ["a1"]
             } = event

      assert Event.normalize(event) == event

      assert %Event{actor: %{kind: :machine}, summary: nil, artifacts: []} =
               Event.normalize(%{actor: :bad, summary: "x", artifacts: "x"})

      assert %Event{actor: %{kind: :machine}} = Event.normalize(%{actor: %{kind: "machine"}})
    end

    test "normalize_actor/1 reads each actor form" do
      assert Event.normalize_actor(:machine) == %{kind: :machine}
      assert Event.normalize_actor(%{kind: :machine}) == %{kind: :machine}
      assert Event.normalize_actor({:agent, "run-1", "qa"}) == %{kind: :agent, run_id: "run-1", run_kind: "qa"}
      assert Event.normalize_actor(%{kind: :agent, run_kind: " "}) == nil
      assert Event.normalize_actor({:person, " Tony "}) == %{kind: :person, name: "Tony"}
      assert Event.normalize_actor(%{kind: :person, name: ""}) == nil
      assert Event.normalize_actor(%{kind: :robot}) == nil
      assert Event.actor_kind(%{kind: :person, name: "Tony"}) == :person
    end

    test "ulid/1 is 26 Crockford base32 characters that sort by time" do
      earlier = Event.ulid(@at)
      later = Event.ulid(DateTime.add(@at, 1, :millisecond))

      assert earlier =~ ~r/\A[0-9A-HJKMNP-TV-Z]{26}\z/
      assert earlier < later
      assert String.slice(Event.ulid(@at), 0, 10) == String.slice(earlier, 0, 10)
      assert String.starts_with?(Event.ulid(~U[1960-01-01 00:00:00Z]), "0000000000")
    end
  end
end
