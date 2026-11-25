defmodule SymphonyElixir.TicketEvents.TypesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TicketEvents.Types

  @types ~w(
    phase.entered hold.set hold.cleared run.started run.started_by_person run.ended attempt.pushed verdict.recorded
    decision.requested decision.withdrawn decision.recorded person.action
    step.started step.completed evidence finding.recorded finding.resolved finding.confirmed checklist.answered
    ticket.cancelled ticket.moved drift.detected drift.reverted drift.revert_failed
    pause.set pause.reason_added pause.reason_cleared pause.cleared
    question.asked question.answered question.withdrawn question.reopened question.not_asked park.backfilled workspace.synced workspace.rebuilt workspace.removed situation.changed rule.action ticket.filed ticket.filed_from note.read brief.written report.published note
    message.sent message.read
    conductor.update conductor.instructions conductor.steer conductor.intervention
    ask.recorded plan.written check.proved check.waived
  )

  describe "catalog/0" do
    test "a rule action names one of the actions a rule may take" do
      assert "paused" in Types.rule_actions()
      assert "lifted_pause" in Types.rule_actions()
    end

    test "has every type, each with a schema, a writer list, run kinds and an idempotency rule" do
      catalog = Types.catalog()

      assert catalog |> Map.keys() |> Enum.sort() == Enum.sort(@types)

      for {type, entry} <- catalog do
        assert entry.writers != [] and Enum.all?(entry.writers, &(&1 in [:machine, :agent, :person])), type
        assert entry.required != [], type
        assert is_list(entry.optional), type
        assert entry.run_kinds == :any or is_list(entry.run_kinds), type
        assert entry.idempotency == :writer or match?({:fields, [_ | _]}, entry.idempotency), type
      end
    end

    test "every type a machine or a person writes, and a note, takes the signal it records and the signal's details" do
      for {type, entry} <- Types.catalog(), entry.writers != [:agent] do
        assert Keyword.has_key?(entry.optional, :signal), type
        assert entry.optional[:signal_details] == :map, type
      end

      assert Types.validate("note", %{text: "Waiting for CI (ci_wait)", signal: "ci_wait", signal_details: %{sha: "abc"}}, :machine, nil) ==
               {:ok, %{text: "Waiting for CI (ci_wait)", signal: "ci_wait", signal_details: %{sha: "abc"}}}
    end

    test "a verdict carries the details it was given" do
      assert Types.validate("verdict.recorded", %{kind: "qa", outcome: "blocked", details: %{reason: "no emulator"}}, :machine, nil) ==
               {:ok, %{kind: "qa", outcome: "blocked", details: %{reason: "no emulator"}}}

      assert Types.validate("verdict.recorded", %{kind: "qa", outcome: "blocked", details: "no emulator"}, :machine, nil) ==
               {:error, {:invalid_payload, [:details]}}
    end

    test "an agent never records a signal: only the machinery's events carry one" do
      assert Types.validate("note", %{text: "x", signal: "ci_rerun"}, :agent, "implementation") == {:error, {:invalid_payload, [:signal]}}

      assert Types.validate("note", %{"text" => "x", "signal" => "ci_rerun", "signal_details" => %{}}, :agent, "implementation") ==
               {:error, {:invalid_payload, [:signal, :signal_details]}}
    end

    test "a note's status is the machinery's: Symphony records it, an agent never does, and a tool's caller never sees it" do
      assert {:ok, %{text: "Waiting for CI", status: true}} = Types.validate("note", %{text: "Waiting for CI", status: true}, :machine, nil)
      assert Types.validate("note", %{text: "x", status: true}, :agent, "implementation") == {:error, {:invalid_payload, [:status]}}
      refute "status" in Enum.map(Types.schema("note").optional, & &1.name)
    end

    test "the retired holds' and decision requests' types are legacy: still in the catalog, so history reads them" do
      assert Types.legacy_types() == ["hold.set", "hold.cleared", "decision.requested", "decision.recorded", "decision.withdrawn"]

      for type <- Types.legacy_types() do
        assert Types.legacy?(type)
        assert Map.has_key?(Types.catalog(), type)
      end

      refute Types.legacy?("pause.set")
      refute Types.legacy?("question.asked")
      refute Types.legacy?(nil)
    end

    test "the agent run kinds are the run kind names" do
      assert "implementation" in Types.agent_run_kinds()
      assert "qa" in Types.agent_run_kinds()
    end
  end

  describe "validate/4" do
    test "rejects an unknown type" do
      assert Types.validate("nope", %{}, :machine, nil) == {:error, {:unknown_type, "nope"}}
      assert Types.validate(:note, %{text: "x"}, :machine, nil) == {:error, {:unknown_type, :note}}
    end

    test "names every missing required field" do
      assert Types.validate("verdict.recorded", %{}, :machine, nil) == {:error, {:invalid_payload, [:kind, :outcome]}}
      assert Types.validate("run.started", %{run_id: "  "}, :machine, nil) == {:error, {:invalid_payload, [:run_id, :run_kind]}}
    end

    test "a run a person started is the Director's, with their note bounded" do
      assert {:ok, %{by: "the Director", note: "unblock this one", run_id: "run-1"}} =
               Types.validate("run.started_by_person", %{by: "the Director", note: "unblock this one", run_id: "run-1"}, :person, nil)

      assert Types.validate("run.started_by_person", %{note: "no by"}, :person, nil) == {:error, {:invalid_payload, [:by]}}

      assert {:error, {:invalid_payload, [:note]}} =
               Types.validate("run.started_by_person", %{by: "the Director", note: String.duplicate("a", 501)}, :person, nil)

      assert {:error, {:not_allowed, reason}} = Types.validate("run.started_by_person", %{by: "the Director"}, :machine, nil)
      assert reason =~ "person"
    end

    test "a note of 4,001 characters from an agent is rejected naming text" do
      assert Types.validate("note", %{text: String.duplicate("a", 4_001)}, :agent, "implementation") ==
               {:error, {:invalid_payload, [:text]}}

      text = String.duplicate("a", 4_000)
      assert Types.validate("note", %{text: text}, :agent, "implementation") == {:ok, %{text: text}}
    end

    test "a decision is never a hold kind or a person's action" do
      assert Types.validate("hold.set", %{kind: "needs_decision"}, :machine, nil) == {:error, {:invalid_payload, [:kind]}}
      assert Types.validate("hold.cleared", %{kind: :needs_decision}, :machine, nil) == {:error, {:invalid_payload, [:kind]}}
      assert Types.validate("person.action", %{action: "decide"}, :person, nil) == {:error, {:invalid_payload, [:action]}}

      assert Types.validate("hold.set", %{kind: :blocked, reason: "waits on TP-1"}, :machine, nil) ==
               {:ok, %{kind: "blocked", reason: "waits on TP-1"}}

      assert {:ok, %{action: "unblock"}} = Types.validate("person.action", %{action: :unblock}, :person, nil)
    end

    test "a new force is no person's action: forcing is gone (TP-1611)" do
      assert Types.validate("person.action", %{action: "force"}, :person, nil) == {:error, {:invalid_payload, [:action]}}
    end

    test "rejects an agent outside the type's writers or run kinds" do
      assert {:error, {:not_allowed, reason}} =
               Types.validate("finding.recorded", finding(), :agent, "implementation")

      assert reason =~ "qa"

      for run_kind <- Types.agent_run_kinds() do
        assert {:error, {:not_allowed, _reason}} =
                 Types.validate("verdict.recorded", %{kind: "qa", outcome: "pass"}, :agent, run_kind)
      end

      assert {:ok, _payload} = Types.validate("finding.recorded", finding(), :agent, :qa)
    end

    test "accepts a decision request from an agent of any run kind" do
      for run_kind <- Types.agent_run_kinds() do
        assert {:ok, %{question: "Ship it?"}} = Types.validate("decision.requested", %{question: "Ship it?"}, :agent, run_kind)
      end
    end

    test "drift is the machine's: both phases, and the error of a failed move back" do
      phases = %{record_phase: "Code Review", linear_phase: "Done"}

      for type <- ~w(drift.detected drift.reverted drift.revert_failed) do
        assert Types.validate(type, phases, :machine, nil) == {:ok, phases}, type
        assert {:error, {:invalid_payload, [:linear_phase]}} = Types.validate(type, %{record_phase: "Code Review"}, :machine, nil)
        assert {:error, {:not_allowed, _reason}} = Types.validate(type, phases, :agent, "implementation")
        assert {:error, {:not_allowed, _reason}} = Types.validate(type, phases, :person, nil)
      end

      assert Types.validate("drift.revert_failed", Map.put(phases, :error, ":timeout"), :machine, nil) == {:ok, Map.put(phases, :error, ":timeout")}
      assert {:error, {:invalid_payload, [:error]}} = Types.validate("drift.reverted", Map.put(phases, :error, ":timeout"), :machine, nil)
    end

    test "a park brought up to date is the machine's: what it was given, the question, the branch and the phase it left" do
      payload = %{added: ["question", "push"], question_id: "q-1", branch: "auto/TP-1248", from: "In Progress"}

      assert Types.validate("park.backfilled", payload, :machine, nil) == {:ok, payload}
      assert {:error, {:invalid_payload, [:added]}} = Types.validate("park.backfilled", %{from: "In Progress"}, :machine, nil)
      assert {:error, {:not_allowed, _reason}} = Types.validate("park.backfilled", payload, :person, nil)
    end

    test "a workspace rebuild is the machine's: why, the heads compared and the one chosen" do
      payload = %{reason: "reclaim", branch: "auto/TP-1", winner: "pull_request", head: "b2", pr_head: "b2", branch_head: "a1", recorded_head: "c3"}

      assert Types.validate("workspace.rebuilt", payload, :machine, nil) == {:ok, payload}
      assert {:error, {:invalid_payload, [:reason]}} = Types.validate("workspace.rebuilt", %{payload | reason: "whim"}, :machine, nil)
      assert {:error, {:not_allowed, _reason}} = Types.validate("workspace.rebuilt", payload, :agent, "rework")
    end

    test "a workspace sync is the machine's: the heads compared, the winner and what was done" do
      payload = %{workspace_head: "a1", pr_head: "b2", recorded_head: "c3", winner: "recorded", action: "reset_and_pushed", head: "c3", run_kind: "qa"}

      assert Types.validate("workspace.synced", payload, :machine, nil) == {:ok, payload}
      assert {:error, {:invalid_payload, [:winner]}} = Types.validate("workspace.synced", %{payload | winner: "somebody"}, :machine, nil)
      assert {:error, {:not_allowed, _reason}} = Types.validate("workspace.synced", payload, :agent, "qa")
    end

    test "a cancel is the person's: the phases, the note, the stop and the pull requests it closed" do
      payload = %{from: "Backlog", to: "Canceled", note: "superseded", run_stopped: true, pull_requests_closed: ["https://github.com/o/r/pull/1"]}

      assert Types.validate("ticket.cancelled", payload, :person, nil) == {:ok, payload}
      assert {:error, {:invalid_payload, [:to]}} = Types.validate("ticket.cancelled", %{from: "Backlog"}, :person, nil)
      assert {:error, {:not_allowed, _reason}} = Types.validate("ticket.cancelled", payload, :machine, nil)
    end

    test "a free move is the person's: the phases, the note and the stop" do
      payload = %{from: "Backlog", to: "In Progress", note: "Its work is committed", run_stopped: false}

      assert Types.validate("ticket.moved", payload, :person, nil) == {:ok, payload}
      assert {:error, {:invalid_payload, [:to]}} = Types.validate("ticket.moved", %{from: "Backlog"}, :person, nil)
      assert {:error, {:not_allowed, _reason}} = Types.validate("ticket.moved", payload, :machine, nil)
    end

    test "a pause is the machine's: a reason event names its kind, its line and what it waits on" do
      reason = %{reason: :ticket, text: "Waiting for TP-1194 to finish", waits_on: %{identifier: "TP-1194"}}

      for type <- ~w(pause.set pause.reason_added pause.reason_cleared) do
        assert Types.validate(type, reason, :machine, nil) == {:ok, %{reason | reason: "ticket"}}, type
        assert {:error, {:invalid_payload, [:reason]}} = Types.validate(type, %{reason | reason: :hold}, :machine, nil)
        long = %{reason | text: String.duplicate("a", 301)}
        assert {:error, {:invalid_payload, [:text]}} = Types.validate(type, long, :machine, nil)
        assert {:error, {:not_allowed, _reason}} = Types.validate(type, reason, :agent, "implementation")
        assert {:error, {:not_allowed, _reason}} = Types.validate(type, reason, :person, nil)
      end

      set_by = %{kind: :person, name: "Tony"}
      assert {:ok, %{set_by: ^set_by, releasable: true}} = Types.validate("pause.set", Map.merge(reason, %{set_by: set_by, releasable: true}), :machine, nil)
      assert {:ok, %{by: ^set_by}} = Types.validate("pause.reason_cleared", Map.put(reason, :by, set_by), :machine, nil)
      assert {:error, {:invalid_payload, [:releasable]}} = Types.validate("pause.reason_cleared", Map.put(reason, :releasable, true), :machine, nil)

      cleared = [%{reason: :question, text: "Waiting for your answer", waits_on: %{question_id: "q-1"}}]
      payload = %{cleared: cleared, by: set_by}
      assert Types.validate("pause.cleared", payload, :machine, nil) == {:ok, payload}
      assert {:error, {:invalid_payload, [:cleared]}} = Types.validate("pause.cleared", %{}, :machine, nil)
      assert {:error, {:not_allowed, _reason}} = Types.validate("pause.cleared", %{cleared: cleared}, :person, nil)
    end

    test "a question is the machine's: asked, answered or withdrawn, each naming the question" do
      asked = %{question_id: "q-1", title: "Ship it", question: "Should it ship today?", options: [%{label: "Ship"}], asked_by: %{kind: :run, name: "Implementation run 1"}}
      tony = %{kind: :person, name: "Tony"}
      answered = %{question_id: "q-1", answer: "2", option: "Wait", option_number: 2, scope: :ticket, by: tony}
      withdrawn = %{question_id: "q-1", reason: "The ticket was cancelled", title: "Ship it"}

      assert Types.validate("question.asked", asked, :machine, nil) == {:ok, asked}
      assert Types.validate("question.answered", answered, :machine, nil) == {:ok, %{answered | scope: "ticket"}}
      assert Types.validate("question.withdrawn", withdrawn, :machine, nil) == {:ok, withdrawn}

      long = %{asked | title: String.duplicate("a", 121)}
      assert {:error, {:invalid_payload, [:title]}} = Types.validate("question.asked", long, :machine, nil)
      assert {:error, {:invalid_payload, [:scope]}} = Types.validate("question.answered", %{answered | scope: :forever}, :machine, nil)
      assert {:error, {:invalid_payload, [:reason]}} = Types.validate("question.withdrawn", Map.delete(withdrawn, :reason), :machine, nil)

      for {type, payload} <- [{"question.asked", asked}, {"question.answered", answered}, {"question.withdrawn", withdrawn}] do
        assert {:error, {:not_allowed, _reason}} = Types.validate(type, payload, :agent, "implementation")
        assert {:error, {:not_allowed, _reason}} = Types.validate(type, payload, :person, nil)
        assert Types.idempotency_key(type, payload, nil) == "#{type}:q-1"
      end
    end

    test "rejects an agent with an unknown run kind, and a machine or person outside the writers" do
      assert {:error, {:not_allowed, reason}} = Types.validate("note", %{text: "x"}, :agent, "nope")
      assert reason =~ "nope"
      assert {:error, {:not_allowed, _}} = Types.validate("note", %{text: "x"}, :agent, nil)
      assert {:error, {:not_allowed, _}} = Types.validate("step.started", step(), :person, nil)
      assert {:error, {:not_allowed, _}} = Types.validate("verdict.recorded", %{kind: "qa", outcome: "pass"}, :person, nil)
      assert {:error, {:not_allowed, reason}} = Types.validate("note", %{text: "x"}, :robot, nil)
      assert reason =~ ":robot"
    end

    test "takes string keys, stores enums as strings and drops nil optional fields" do
      payload = %{"kind" => :qa, "outcome" => "pass", "head" => nil, "signal" => "qa verdict"}

      assert Types.validate("verdict.recorded", payload, :machine, nil) ==
               {:ok, %{kind: "qa", outcome: "pass", signal: "qa verdict"}}
    end

    test "rejects a field the type does not name, and a payload that is not a map" do
      assert Types.validate("note", %{"text" => "x", "extra" => 1, nope: 2}, :machine, nil) ==
               {:error, {:invalid_payload, [:nope, "extra"]}}

      assert Types.validate("note", %{{:tuple} => 1, text: "x"}, :machine, nil) == {:error, {:invalid_payload, [{:tuple}]}}
      assert Types.validate("note", "text", :machine, nil) == {:error, {:invalid_payload, [:payload]}}
    end

    test "checks every field spec" do
      step = fn type, attrs -> Types.validate(type, Map.merge(step(), attrs), :agent, "qa") end
      machine = fn type, payload -> Types.validate(type, payload, :machine, nil) end
      resolved = fn evidence -> Types.validate("finding.resolved", %{finding_id: "f", how: "fixed", evidence: evidence}, :agent, "rework") end

      assert {:ok, %{step_id: "code"}} = step.("step.started", %{})
      assert {:error, {:invalid_payload, [:step_id]}} = step.("step.started", %{step_id: nil})
      assert {:error, {:invalid_payload, [:mode]}} = step.("step.started", %{mode: "manual"})
      assert {:error, {:invalid_payload, [:title]}} = step.("step.started", %{title: String.duplicate("t", 201)})

      ended = %{run_id: "run-1", exit: "success", run_number: 2, duration_ms: 10, tokens: %{total: 5}, counted: true}
      assert {:ok, ^ended} = machine.("run.ended", ended)
      assert {:ok, %{tokens: 7}} = machine.("run.ended", %{ended | tokens: 7})
      # A run's transcript is named by its artifact id.
      transcript = String.duplicate("ab", 32)
      assert {:ok, %{transcript: ^transcript}} = machine.("run.ended", Map.put(ended, :transcript, transcript))
      assert {:error, {:invalid_payload, [:transcript]}} = machine.("run.ended", Map.put(ended, :transcript, " "))

      assert {:error, {:invalid_payload, [:run_number, :duration_ms, :tokens, :counted]}} =
               machine.("run.ended", %{ended | run_number: -1, duration_ms: "1", tokens: "lots", counted: "yes"})

      assert {:ok, %{evidence: ["e1", "e2"]}} = resolved.(["e1", "e2"])
      assert {:ok, %{evidence: "e1"}} = resolved.("e1")
      assert {:error, {:invalid_payload, [:evidence]}} = resolved.(["e1", ""])

      evidence = fn payload -> Types.validate("evidence", payload, :agent, "qa") end
      # Files are the event's artifacts, never a payload field (TP-1680).
      assert {:error, {:invalid_payload, [:artifacts]}} = evidence.(%{caption: "Before", artifacts: ["a1"]})
      assert {:error, {:invalid_payload, [:caption]}} = evidence.(%{caption: String.duplicate("c", 501)})

      assert {:ok, %{step: "Step 2", result: %{status: "fail", actual: "Empty"}, environment: "live", links: ["https://ci.test/run/1"]}} =
               evidence.(%{caption: "Step 2: fail", step: "Step 2", result: %{status: "fail", actual: "Empty"}, environment: "live", links: ["https://ci.test/run/1"]})

      # A step's answer is its `result`: the loose `status` and `details` are not taken any more.
      loose = %{caption: "Step 2: fail", step: "Step 2", status: "fail", details: "Empty"}
      assert {:error, {:invalid_payload, [:details, :status]}} = evidence.(loose)

      assert {:error, {:invalid_payload, [:environment]}} = evidence.(%{caption: "Step 2", environment: "staging"})

      assert {:ok, %{waits_on: %{type: "dependency"}}} = machine.("hold.set", %{kind: "blocked", waits_on: %{type: "dependency"}})
      assert {:error, {:invalid_payload, [:waits_on]}} = machine.("hold.set", %{kind: "blocked", waits_on: "TP-1"})

      assert {:ok, %{options: [%{label: "A"}]}} = machine.("decision.requested", %{question: "Q?", options: [%{label: "A"}]})
      assert {:error, {:invalid_payload, [:options]}} = machine.("decision.requested", %{question: "Q?", options: "A"})
    end
  end

  describe "idempotency_key/3" do
    test "takes the writer's key, else derives one from the type's rule" do
      assert Types.idempotency_key("verdict.recorded", %{}, "verdict:qa:abc") == "verdict:qa:abc"
      assert Types.idempotency_key("run.started", %{run_id: "run-1"}, " ") == "run.started:run-1"
      assert Types.idempotency_key("run.started_by_person", %{by: "the Director", run_id: "run-1"}, nil) == "run.started_by_person:run-1"
      assert Types.idempotency_key("run.ended", %{run_id: "run-1"}, nil) == "run.ended:run-1"
      assert Types.idempotency_key("decision.recorded", %{key: "c1"}, nil) == "decision.recorded:c1"
      assert Types.idempotency_key("decision.recorded", %{answer: "yes"}, nil) == nil
      assert Types.idempotency_key("note", %{text: "x"}, nil) == nil
      assert Types.idempotency_key("nope", %{}, 42) == nil
    end
  end

  describe "agent_types/1" do
    test "a QA run and a Conductor turn also record findings, the runs that write the code a brief; every other run kind the same agent types; nothing else is an agent's" do
      every = ~w(check.proved checklist.answered evidence finding.resolved note step.completed step.started)
      briefing = ~w(implementation rework review_feedback)

      assert Types.agent_types("qa") == Enum.sort(["finding.recorded" | every])
      assert Types.agent_types(:qa) == Types.agent_types("qa")
      assert Types.agent_types("conductor") == Types.agent_types("qa")

      with_brief = Enum.sort(["brief.written" | every])
      for run_kind <- briefing, do: assert(Types.agent_types(run_kind) == with_brief, run_kind)

      for run_kind <- Types.agent_run_kinds() -- ["qa", "conductor" | briefing],
          do: assert(Types.agent_types(run_kind) == every, run_kind)

      assert Types.agent_types("supervisor") == []
      assert Types.agent_types(nil) == []
    end
  end

  describe "a Conductor turn's move (TP-1656)" do
    test "is a ticket.moved Symphony records for the turn: no other agent records one, and no run's tool offers it" do
      assert {:ok, %{from: "Rework", to: "QA", note: "Nothing is left to code."}} =
               Types.validate("ticket.moved", %{from: "Rework", to: "QA", note: "Nothing is left to code."}, :agent, "conductor")

      assert {:error, {:not_allowed, _why}} = Types.validate("ticket.moved", %{from: "Rework", to: "QA"}, :agent, "rework")
      assert {:ok, _payload} = Types.validate("ticket.moved", %{from: "Rework", to: "QA"}, :person, nil)
      refute "ticket.moved" in Types.agent_types("conductor")
    end
  end

  describe "schema/1" do
    test "describes each field a tool's caller may send, leaving out the machinery's signal" do
      assert %{type: "list", max_items: 30} = Enum.find(Types.schema("plan.written").required, &(&1.name == "checks"))
      assert %{type: "list", max_items: 12} = Enum.find(Types.schema("plan.written").optional, &(&1.name == "sub_tickets"))
      modes = ~w(machine orchestrated delegated)

      assert %{required: [%{name: "step_id", max: 200}, %{name: "title", max: 200}, %{name: "mode", type: "enum", values: ^modes}]} = Types.schema("step.started")
      assert %{optional: [command, prompt_ref | turn]} = Types.schema("step.started")
      assert Enum.map(turn, & &1.name) == ~w(model effort session model_ignored model_ignored_reason)
      assert command.required_when == %{field: "mode", equals: "machine"}
      assert prompt_ref.required_when == %{field: "mode", equals: "orchestrated"}

      assert %{optional: [%{name: "returns_to", required_when: %{field: "outcome", equals: "failed"}}, returns_to_title | _]} = Types.schema("step.completed")
      refute Map.has_key?(returns_to_title, :required_when)

      assert %{
               optional: [
                 %{name: "proof", type: "map", fields: proof},
                 %{name: "measures", type: "list", max_items: 20, item: %{type: "map", fields: measure}} | step_fields
               ]
             } = Types.schema("evidence")

      assert measure == [
               %{name: "name", type: "string", max: 200},
               %{name: "value", type: "number"},
               %{name: "unit", type: "string", max: 40},
               %{name: "expected", type: "number", optional: true}
             ]

      assert Enum.map(step_fields, & &1.name) == ~w(step result environment links)
      refute Enum.any?(Types.schema("evidence").optional, &(&1.name == "artifacts"))
      assert %{type: "enum", values: ~w(fixture live)} = Enum.find(step_fields, &(&1.name == "environment"))

      assert proof == [%{name: "step", type: "non_neg_integer"}, %{name: "test", type: "string", max: 500}]
      assert %{optional: [_head, %{name: "evidence", type: "any_of", of: [%{type: "string"}, %{type: "list"}]}]} = Types.schema("finding.resolved")
      refute Enum.any?(Types.schema("phase.entered").optional, &(&1.name in ["signal", "signal_details"]))
      assert Types.schema("note").optional == [%{name: "tag", type: "enum", values: ["discovery", "base_fault"]}]
      assert Types.schema("brief.written").required == [%{name: "text", type: "string", max: 1_200, forbids: "`"}, %{name: "walkthrough", type: "string", max: 4_000, forbids: "`"}]
      assert Types.schema("nope") == nil
    end
  end

  describe "brief.written" do
    test "is prose a person reads: bounded, and without a backtick" do
      brief = %{text: "Each ticket says in plain words what it delivers.", walkthrough: "Open a ticket a run just finished and read what it delivers."}

      assert {:ok, ^brief} = Types.validate("brief.written", brief, :agent, "implementation")
      assert {:ok, _brief} = Types.validate("brief.written", %{brief | text: String.duplicate("a", 1_200)}, :agent, "rework")
      long_text = %{brief | text: String.duplicate("a", 1_201)}
      long_walkthrough = %{brief | walkthrough: String.duplicate("a", 4_001)}
      assert {:error, {:invalid_payload, [:text]}} = Types.validate("brief.written", long_text, :agent, "implementation")
      assert {:error, {:invalid_payload, [:walkthrough]}} = Types.validate("brief.written", long_walkthrough, :agent, "implementation")
      assert {:error, {:invalid_payload, [:text]}} = Types.validate("brief.written", %{brief | text: "Adds `TicketBrief.read/1`."}, :agent, "implementation")
      assert {:error, {:invalid_payload, [:walkthrough]}} = Types.validate("brief.written", %{brief | walkthrough: "Call `GET /api/v1/x`."}, :agent, "review_feedback")
      assert {:error, {:invalid_payload, [:walkthrough]}} = Types.validate("brief.written", Map.delete(brief, :walkthrough), :agent, "implementation")
    end

    test "is written by the runs that write the code, never by a reviewer, QA, the machine or a person" do
      brief = %{text: "What it does.", walkthrough: "What a person does."}

      for run_kind <- ~w(code_review qa ci_fix landing breakdown epic_review) do
        assert {:error, {:not_allowed, _reason}} = Types.validate("brief.written", brief, :agent, run_kind)
      end

      assert {:error, {:not_allowed, _reason}} = Types.validate("brief.written", brief, :machine, nil)
      assert {:error, {:not_allowed, _reason}} = Types.validate("brief.written", brief, :person, nil)
    end
  end

  describe "a groomed ticket's shapes" do
    @check %{id: "c1", kind: "outcome", statement: "The page shows the plan.", proof: "test"}
    @plan %{
      version: 1,
      reason: "Grooming",
      by: "grooming",
      shape: "single",
      layers: ["screen", "api"],
      summary: "The ticket page shows the plan.",
      text: "Read the plan from the ledger and draw it.",
      checks: [@check],
      size: %{tokens: 200_000, runs: 2}
    }

    test "an ask is the machine's or a person's, word for word, from Linear, a message or the parent" do
      assert {:ok, %{text: "Show the plan.", source: "linear"}} = Types.validate("ask.recorded", %{text: "Show the plan.", source: :linear}, :machine, nil)
      assert {:ok, %{source: "message", from: "evt-1"}} = Types.validate("ask.recorded", %{text: "Keep it.", source: "message", from: "evt-1"}, :person, nil)
      longest = %{text: String.duplicate("a", 100_000), source: "parent", from: "TP-1"}
      assert {:ok, _ask} = Types.validate("ask.recorded", longest, :machine, nil)
      assert {:error, {:invalid_payload, [:text]}} = Types.validate("ask.recorded", %{longest | text: longest.text <> "a"}, :machine, nil)
      assert {:error, {:invalid_payload, [:source]}} = Types.validate("ask.recorded", %{text: "x", source: "comment"}, :machine, nil)
      assert {:error, {:not_allowed, _why}} = Types.validate("ask.recorded", %{text: "x", source: "linear"}, :agent, "implementation")
    end

    test "a plan is the machine's: its version, reason, shape, layers, summary, text, checks and size" do
      assert {:ok, plan} = Types.validate("plan.written", @plan, :machine, nil)
      assert plan == @plan

      # A plan may name no layer, the newer names, and `engine`, the name plans already recorded hold.
      for layers <- [[], ["logic", "tests"], ["engine"]] do
        assert {:ok, %{layers: ^layers}} = Types.validate("plan.written", %{@plan | layers: layers}, :machine, nil)
      end

      qa = %{"id" => "c2", "kind" => "qa", "statement" => "The panel folds.", "proof" => "design", "state" => "A groomed ticket", "action" => "Fold it", "expect" => "One line"}
      wide = Map.merge(qa, %{"size" => "wide", "story" => "plan-panel/folded"})

      assert {:ok, %{checks: [%{id: "c2", kind: "qa", size: "wide", story: "plan-panel/folded", action: "Fold it"}]}} =
               Types.validate("plan.written", %{@plan | checks: [wide]}, :machine, nil)

      # Where a QA check is walked and on what state, stored as data; a check from before them still reads.
      placed =
        Map.merge(qa, %{
          "setting" => %{
            "source" => "fixture",
            "fixture" => "macos/Tests/Fixtures/director-app",
            "page" => "Tickets",
            "window" => %{"width" => 2560, "height" => 1440},
            "appearance" => "dark"
          },
          "walked_on" => [%{"path" => "priv/qa_seed/symphony/seed.json", "holds" => "added"}]
        })

      assert {:ok, %{checks: [%{setting: setting, walked_on: walked_on}]}} =
               Types.validate("plan.written", %{@plan | checks: [placed]}, :machine, nil)

      assert %{source: "fixture", window: %{width: 2560, height: 1440}, appearance: "dark"} = setting
      assert walked_on == [%{path: "priv/qa_seed/symphony/seed.json", holds: "added"}]

      assert {:ok, %{checks: [old]}} = Types.validate("plan.written", %{@plan | checks: [qa]}, :machine, nil)
      refute Map.has_key?(old, :setting) or Map.has_key?(old, :walked_on)

      for bad <- [
            put_in(placed, ["setting", "source"], "staging"),
            put_in(placed, ["setting", "appearance"], "sepia"),
            Map.update!(placed, "setting", &Map.delete(&1, "page")),
            Map.put(placed, "walked_on", [%{"path" => "priv/qa_seed", "holds" => "maybe"}])
          ] do
        assert {:error, {:invalid_payload, _fields}} = Types.validate("plan.written", %{@plan | checks: [bad]}, :machine, nil)
      end

      sub_ticket = %{key: "s1", title: "The model", ask: "Build the model.", after: [], repo: "symphony", identifier: "TP-2"}
      split = @plan |> Map.merge(%{shape: "split", by: "recalibration"}) |> Map.put(:sub_tickets, [sub_ticket, %{key: "s2", title: "The view", ask: "Draw it.", after: ["s1"]}])
      assert {:ok, %{sub_tickets: [^sub_ticket, %{key: "s2", after: ["s1"]}]}} = Types.validate("plan.written", split, :machine, nil)

      for {field, value} <- [
            version: -1,
            reason: String.duplicate("a", 1_001),
            by: "person",
            shape: "tree",
            layers: ["screen", "database"],
            summary: String.duplicate("a", 601),
            text: String.duplicate("a", 12_001),
            checks: [Map.put(@check, :proof, "trust")],
            checks: [Map.put(@check, :statement, String.duplicate("a", 601))],
            checks: [Map.delete(@check, :id)],
            checks: [Map.put(@check, :owner, "qa")],
            size: %{tokens: 1},
            sub_tickets: [%{key: "s1", title: String.duplicate("a", 121), ask: "x"}]
          ] do
        assert {:error, {:invalid_payload, [^field]}} = Types.validate("plan.written", Map.put(@plan, field, value), :machine, nil), "#{field}"
      end

      assert {:error, {:invalid_payload, [:size]}} = Types.validate("plan.written", Map.delete(@plan, :size), :machine, nil)
      assert {:error, {:not_allowed, _why}} = Types.validate("plan.written", @plan, :agent, "implementation")
    end

    test "every run kind records a proved check; only the machine waives one" do
      proof = %{"check_id" => "c1", "by" => "test", "test" => "plan_test.exs › shows the plan", "evidence" => "evt-1", "details" => "Green."}

      for run_kind <- Types.agent_run_kinds() do
        assert {:ok, %{check_id: "c1", by: "test", evidence: "evt-1"}} = Types.validate("check.proved", proof, :agent, run_kind), run_kind
      end

      assert {:ok, %{by: "qa"}} = Types.validate("check.proved", %{check_id: "c1", by: :qa}, :machine, nil)
      # TP-1592: a check the pull request's own CI run proves, in the plan and in its proof.
      assert {:ok, %{by: "ci", details: "make-all passed."}} = Types.validate("check.proved", %{check_id: "c1", by: "ci", details: "make-all passed."}, :agent, "landing")
      ci_check = %{id: "c9", kind: "outcome", statement: "make-all passes.", proof: "ci", ci_check: "make-all"}
      assert {:ok, %{checks: [_ | _] = checks}} = Types.validate("plan.written", %{@plan | checks: @plan.checks ++ [ci_check]}, :machine, nil)
      assert %{proof: "ci", ci_check: "make-all"} = List.last(checks)
      assert {:error, {:invalid_payload, [:by]}} = Types.validate("check.proved", %{check_id: "c1", by: "trust"}, :machine, nil)
      long_test = %{check_id: "c1", by: "test", test: String.duplicate("a", 501)}
      assert {:error, {:invalid_payload, [:test]}} = Types.validate("check.proved", long_test, :machine, nil)
      signalled = %{check_id: "c1", by: "test", signal: "x"}
      assert {:error, {:invalid_payload, [:signal]}} = Types.validate("check.proved", signalled, :agent, "qa")

      assert {:ok, %{check_id: "c1", reason: "Nothing can test it."}} = Types.validate("check.waived", %{check_id: "c1", reason: "Nothing can test it."}, :machine, nil)
      assert {:error, {:invalid_payload, [:reason]}} = Types.validate("check.waived", %{check_id: "c1"}, :machine, nil)
      assert {:error, {:not_allowed, _why}} = Types.validate("check.waived", %{check_id: "c1", reason: "x"}, :agent, "implementation")
    end

    test "an intervention names what the Conductor of a ticket did, and why" do
      assert {:ok, %{action: "stopped", by: "TP-1", target: "TP-2"}} =
               Types.validate("conductor.intervention", %{action: "stopped", reason: "The plan changed.", by: "TP-1", target: "TP-2"}, :machine, nil)

      paused = %{action: "paused", reason: "x", by: "TP-1"}
      assert {:error, {:invalid_payload, [:action]}} = Types.validate("conductor.intervention", paused, :machine, nil)
      assert {:error, {:invalid_payload, [:reason, :by]}} = Types.validate("conductor.intervention", %{action: "added"}, :machine, nil)
    end

    test "a note takes a tag an agent writes: a discovery or a fault of the base" do
      assert {:ok, %{text: "The base build is red.", tag: "base_fault"}} = Types.validate("note", %{"text" => "The base build is red.", "tag" => "base_fault"}, :agent, "qa")
      assert {:ok, %{tag: "discovery"}} = Types.validate("note", %{text: "The export has no test.", tag: :discovery}, :machine, nil)
      assert {:error, {:invalid_payload, [:tag]}} = Types.validate("note", %{text: "x", tag: "todo"}, :agent, "implementation")
    end
  end

  describe "the step model" do
    test "a step's mode names how it runs: a machine step its command, an orchestrated one its prompt" do
      machine = fn type, payload -> Types.validate(type, payload, :machine, nil) end
      build = %{step_id: "build", title: "Build", mode: "machine"}

      assert {:ok, %{command: "mix compile"}} = machine.("step.started", Map.put(build, :command, "mix compile"))
      assert {:error, {:invalid_payload, [:command]}} = machine.("step.started", build)
      assert {:ok, %{prompt_ref: "code"}} = machine.("step.started", %{build | mode: :orchestrated} |> Map.put(:prompt_ref, "code"))
      assert {:error, {:invalid_payload, [:prompt_ref]}} = machine.("step.started", %{build | mode: "orchestrated"})
      assert {:error, {:invalid_payload, [:command]}} = machine.("step.started", step() |> Map.put(:command, "mix test"))
      assert {:error, {:invalid_payload, [:prompt_ref]}} = machine.("step.started", Map.merge(build, %{command: "mix compile", prompt_ref: "code"}))
      # A command out of bounds is named once.
      assert {:error, {:invalid_payload, [:command]}} = machine.("step.started", Map.put(build, :command, String.duplicate("c", 2_001)))
      # A mode the catalog refuses leaves its conditional fields unjudged.
      assert {:error, {:invalid_payload, [:mode]}} = machine.("step.started", %{build | mode: "manual"} |> Map.put(:command, "make"))
    end

    test "Symphony records machine and orchestrated steps; an agent only delegated ones" do
      for type <- ["step.started", "step.completed"] do
        assert type in Types.agent_types("implementation")
      end

      assert {:ok, _payload} = Types.validate("step.started", step(), :agent, "implementation")

      assert {:error, {:not_allowed, reason}} =
               Types.validate("step.started", %{step_id: "build", title: "Build", mode: "machine", command: "mix compile"}, :agent, "implementation")

      assert reason =~ "delegated"

      completed = %{step_id: "tests", title: "Tests", mode: "orchestrated", outcome: "passed"}
      assert {:error, {:not_allowed, _reason}} = Types.validate("step.completed", completed, :agent, "rework")
      assert {:ok, _payload} = Types.validate("step.completed", completed, :machine, nil)
    end

    test "a failed step names the step it returns to, a paused one the Question it waits on, a skipped one why" do
      completed = fn attrs -> Types.validate("step.completed", Map.merge(%{step_id: "build", title: "Build", mode: "machine"}, attrs), :machine, nil) end

      assert {:ok, %{outcome: "passed", duration_ms: 120_000}} = completed.(%{outcome: :passed, duration_ms: 120_000})

      assert {:ok, %{returns_to: "code", returns_to_title: "writing the code"}} =
               completed.(%{outcome: "failed", returns_to: "code", returns_to_title: "writing the code", duration_ms: 240_000})

      assert {:error, {:invalid_payload, [:returns_to]}} = completed.(%{outcome: "failed"})
      assert {:ok, %{question_id: "q-1"}} = completed.(%{outcome: "paused", question_id: "q-1"})
      assert {:error, {:invalid_payload, [:question_id]}} = completed.(%{outcome: "paused"})
      assert {:ok, %{reason: "no Elixir changed"}} = completed.(%{outcome: "skipped", reason: "no Elixir changed"})
      assert {:error, {:invalid_payload, [:reason]}} = completed.(%{outcome: "skipped"})

      # Each is refused on any other outcome.
      assert {:error, {:invalid_payload, [:returns_to, :question_id, :reason]}} =
               completed.(%{outcome: "passed", returns_to: "code", question_id: "q-1", reason: "why"})

      assert {:error, {:invalid_payload, [:outcome]}} = completed.(%{outcome: "done"})
      assert {:error, {:invalid_payload, [:outcome]}} = completed.(%{})
    end

    test "a failed step may say why; a passed one may not" do
      completed = fn attrs -> Types.validate("step.completed", Map.merge(%{step_id: "look", title: "Look", mode: "orchestrated"}, attrs), :machine, nil) end

      assert {:ok, %{reason: "gave no answer"}} = completed.(%{outcome: "failed", returns_to: "review", reason: "gave no answer"})
      assert {:ok, %{returns_to: "review"}} = completed.(%{outcome: "failed", returns_to: "review"})
      assert {:ok, %{reason: "why"}} = completed.(%{outcome: "paused", question_id: "q", reason: "why"})
      assert {:error, {:invalid_payload, [:reason]}} = completed.(%{outcome: "passed", reason: "why"})
      assert %{required_when: %{field: "outcome", equals: "skipped"}} = Enum.find(Types.schema("step.completed").optional, &(&1.name == "reason"))
    end

    test "the Window tests step's failing tests ride on its step.completed, bounded (TP-1569)" do
      completed = fn attrs -> Types.validate("step.completed", Map.merge(%{step_id: "window_tests", title: "Window tests", mode: "machine"}, attrs), :machine, nil) end
      failure = %{script: "macos/Tests/a.sh", title: "a test", exit_status: 3, printed: "it broke", base: %{exit_status: 0, printed: "fine"}}
      paused = %{outcome: "paused", question_id: "q", reason: "Failed in the QA VM: the a test"}

      assert {:ok, %{failures: [^failure]}} = completed.(Map.put(paused, :failures, [failure]))
      assert {:ok, %{failures: [%{exit_status: 1}]}} = completed.(Map.put(paused, :failures, [%{script: "s", title: "t", exit_status: 1}]))
      assert {:error, {:invalid_payload, [:failures]}} = completed.(Map.put(paused, :failures, [%{failure | printed: String.duplicate("a", 1_201)}]))
      assert {:error, {:invalid_payload, [:failures]}} = completed.(Map.put(paused, :failures, List.duplicate(failure, 11)))
    end

    test "a QA step's answer rides on its step.completed: result, plan, recheck and verdict_summary" do
      completed = fn attrs -> Types.validate("step.completed", Map.merge(%{step_id: "walk_1", title: "Walk", mode: "orchestrated", outcome: "passed"}, attrs), :machine, nil) end

      result = %{status: "blocked", expected: "Rows", actual: "Empty state"}
      assert {:ok, %{result: ^result}} = completed.(%{result: result})
      assert {:ok, %{result: %{status: "pass"}}} = completed.(%{result: %{"status" => "pass", "expected" => "a", "actual" => "b"}})
      assert {:error, {:invalid_payload, [:result]}} = completed.(%{result: %{result | status: "great"}})
      assert {:error, {:invalid_payload, [:result]}} = completed.(%{result: Map.put(result, :extra, "x")})
      assert {:error, {:invalid_payload, [:result]}} = completed.(%{result: Map.delete(result, :status)})
      assert {:ok, %{result: %{status: "blocked"}}} = completed.(%{result: %{status: "blocked"}})
      too_long = String.duplicate("a", 1_501)
      assert {:error, {:invalid_payload, [:result]}} = completed.(%{result: %{result | actual: too_long}})

      plan = %{checks: [%{title: "Step 1", expect: "Shows"}], skips: [%{title: "Wide pass", why: "nothing on screen"}], summary: "Plan"}
      assert {:ok, %{plan: ^plan}} = completed.(%{plan: plan})
      assert {:ok, %{plan: %{checks: [], skips: []}}} = completed.(%{plan: %{plan | checks: [], skips: []}})
      assert {:error, {:invalid_payload, [:plan]}} = completed.(%{plan: %{plan | checks: [%{title: "x"}]}})
      assert {:error, {:invalid_payload, [:plan]}} = completed.(%{plan: %{plan | checks: ["x"]}})

      recheck = [%{title: "Step 2", do: ["Scroll", "Look"], expect: "Row 9", design: "Screen 3"}, %{title: "Menu", do: [], expect: "Opens"}]
      assert {:ok, %{recheck: ^recheck}} = completed.(%{recheck: recheck})
      assert {:error, {:invalid_payload, [:recheck]}} = completed.(%{recheck: [%{title: "x", do: "Scroll", expect: "y"}]})
      blank_design = [%{title: "x", do: [], expect: "y", design: ""}]
      assert {:error, {:invalid_payload, [:recheck]}} = completed.(%{recheck: blank_design})

      assert {:ok, %{verdict_summary: "All good."}} = completed.(%{verdict_summary: "All good."})
      too_long_summary = String.duplicate("a", 601)
      assert {:error, {:invalid_payload, [:verdict_summary]}} = completed.(%{verdict_summary: too_long_summary})

      assert %{
               type: "map",
               fields: [
                 %{name: "status", type: "enum"},
                 %{name: "expected", max: 1_500, optional: true},
                 %{name: "actual", optional: true},
                 %{name: "measures"}
               ]
             } = Enum.find(Types.schema("step.completed").optional, &(&1.name == "result"))

      assert %{type: "list", item: %{type: "map", fields: [_title, %{name: "do", type: "list"}, _expect, %{name: "design", max: 600}]}} =
               Enum.find(Types.schema("step.completed").optional, &(&1.name == "recheck"))
    end

    test "a step's structured answer is a list of label and value entries on its step.completed" do
      completed = fn attrs -> Types.validate("step.completed", Map.merge(%{step_id: "layout", title: "Layout", mode: "orchestrated", outcome: "passed"}, attrs), :machine, nil) end

      answer = [%{label: "layout", value: "two columns"}, %{"label" => "files", "value" => "a.ex\nb.ex"}]
      assert {:ok, %{answer: [%{label: "layout"}, %{label: "files", value: "a.ex\nb.ex"}]}} = completed.(%{answer: answer})
      assert {:ok, %{answer: []}} = completed.(%{answer: []})
      assert {:error, {:invalid_payload, [:answer]}} = completed.(%{answer: ~s({"layout":"x"})})
      assert {:error, {:invalid_payload, [:answer]}} = completed.(%{answer: [%{label: "layout"}]})
      long_label = [%{label: String.duplicate("l", 61), value: "x"}]
      long_value = [%{label: "l", value: String.duplicate("v", 1_501)}]
      assert {:error, {:invalid_payload, [:answer]}} = completed.(%{answer: long_label})
      assert {:error, {:invalid_payload, [:answer]}} = completed.(%{answer: long_value})
    end

    test "a skip is a step.completed: the type list stays closed" do
      refute Map.has_key?(Types.catalog(), "step.skipped")
      assert Types.validate("step.skipped", step(), :agent, "implementation") == {:error, {:unknown_type, "step.skipped"}}
    end
  end

  describe "an evidence's proof" do
    test "names the walkthrough step and the test, and nothing else" do
      assert {:ok, %{proof: %{step: 2, test: "a_test.exs"}}} =
               Types.validate("evidence", %{"caption" => "c", "proof" => %{"step" => 2, "test" => "a_test.exs"}}, :agent, "rework")

      for proof <- [%{step: 2}, %{step: "two", test: "t"}, %{step: 2, test: "t", extra: 1}, %{step: 2, test: nil}, "step 2"] do
        result = Types.validate("evidence", %{caption: "c", proof: proof}, :agent, "rework")
        assert {:error, {:invalid_payload, [:proof]}} = result, inspect(proof)
      end
    end
  end

  describe "a measured value (TP-1680)" do
    test "has one shape: name, a number value, unit and an optional expected number; any other shape is refused" do
      evidence = fn measures -> Types.validate("evidence", %{caption: "Sizes", measures: measures}, :agent, "qa") end
      width = %{name: "sidebar width", value: 280, unit: "pt", expected: 280}

      assert {:ok, %{measures: [^width, %{name: "load", value: 1.25, unit: "s"}]}} =
               evidence.([width, %{"name" => "load", "value" => 1.25, "unit" => "s"}])

      for wrong <- [
            %{width | value: "280"},
            Map.delete(width, :name),
            Map.delete(width, :unit),
            Map.delete(width, :value),
            %{width | expected: "280 pt"},
            %{width | unit: " "},
            Map.put(width, :tolerance, 2)
          ] do
        assert {:error, {:invalid_payload, [:measures]}} = evidence.([wrong]), inspect(wrong)
      end

      assert {:error, {:invalid_payload, [:measures]}} = evidence.(width)
      assert {:error, {:invalid_payload, [:measures]}} = evidence.(List.duplicate(width, 21))

      assert Types.measure_spec() ==
               {:map, [name: {:string, 200}, value: :number, unit: {:string, 40}, expected: {:optional, :number}]}
    end

    test "a QA step's answer carries its measured values in the same shape, on step.completed and on evidence" do
      measure = %{name: "row height", value: 22, unit: "pt", expected: 24}
      answer = %{status: "fail", expected: "24 pt rows", actual: "22 pt rows", measures: [measure]}
      completed = %{step_id: "walk_1", title: "Walk", mode: "orchestrated", outcome: "passed"}

      assert {:ok, %{result: ^answer}} = Types.validate("step.completed", Map.put(completed, :result, answer), :machine, nil)
      assert {:ok, %{results: [%{step: 2, measures: [^measure]}]}} = Types.validate("step.completed", Map.put(completed, :results, [Map.put(answer, :step, 2)]), :machine, nil)
      assert {:ok, %{result: ^answer}} = Types.validate("evidence", %{caption: "Step 2: fail", step: "Step 2", result: answer}, :agent, "qa")

      bad = %{answer | measures: [%{measure | value: "22"}]}
      assert {:error, {:invalid_payload, [:result]}} = Types.validate("step.completed", Map.put(completed, :result, bad), :machine, nil)
      assert {:error, {:invalid_payload, [:result]}} = Types.validate("evidence", %{caption: "Step 2", result: bad}, :agent, "qa")
      great = %{caption: "Step 2", result: %{answer | status: "great"}}
      assert {:error, {:invalid_payload, [:result]}} = Types.validate("evidence", great, :agent, "qa")
      assert {:map, [status: _, expected: _, actual: _, measures: _]} = Types.step_answer_spec()
    end
  end

  describe "shape/1 (TP-1680)" do
    test "spells every field a run may send in one line, from the catalog, with the named shapes it uses" do
      assert Types.shape("note") == "{text: string(4000), tag?: discovery|base_fault}"
      assert Types.shape("brief.written") == "{text: string(1200) without `, walkthrough: string(4000) without `}"
      assert Types.shape("finding.resolved") == "{finding_id: string, how: string(2000), head?: string, evidence?: string or [string]}"

      assert Types.shape("evidence") ==
               "{caption: string(500), proof?: {step: integer, test: string(500)}, measures?: [measure] (at most 20), step?: string(200), result?: step_answer, environment?: fixture|live, links?: [string]}"

      # An agent records only a delegated step, so a machine or orchestrated step's own fields are left out.
      started = Types.shape("step.started")
      assert started =~ "mode: delegated,"
      refute started =~ "command"
      refute started =~ "prompt_ref"

      completed = Types.shape("step.completed")
      assert completed =~ "returns_to?: string(200) (required when outcome is failed)"
      assert completed =~ "reason?: string(300) (required when outcome is skipped, allowed when failed or paused)"
      assert completed =~ "result?: step_answer,"
      assert completed =~ "[{step: integer, status: pass|fail|blocked|skipped|unprovable|plan_mismatch, expected?: string(1500)"
      assert completed =~ "(at most 30)"

      assert Types.named_shapes() == [
               {"measure", "{name: string(200), value: number, unit: string(40), expected?: number}"},
               {"step_answer", "{status: pass|fail|blocked|skipped|unprovable|plan_mismatch, expected?: string(1500), actual?: string(1500), measures?: [measure] (at most 20)}"}
             ]

      assert Types.shape("nope") == nil
    end

    test "an untyped map or list reads as object and list; an agent's only values are named in the schema" do
      assert Types.shape("decision.requested") =~ "options?: list"
      assert Types.shape("hold.set") =~ "waits_on?: object"
      assert %{name: "mode", agent_values: ["delegated"], values: ~w(machine orchestrated delegated)} = Enum.find(Types.schema("step.started").required, &(&1.name == "mode"))

      assert %{required_when: %{field: "outcome", equals: "skipped"}, allowed_when: ["failed", "paused"]} =
               Enum.find(Types.schema("step.completed").optional, &(&1.name == "reason"))
    end
  end

  defp finding, do: %{class: "unclassified", severity: "high", description: "The button is clipped."}
  defp step, do: %{step_id: "code", title: "Writing the code", mode: "delegated"}
end
