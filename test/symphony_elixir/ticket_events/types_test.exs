defmodule SymphonyElixir.TicketEvents.TypesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TicketEvents.Types

  @types ~w(
    phase.entered hold.set hold.cleared run.started run.ended attempt.pushed verdict.recorded
    decision.requested decision.withdrawn decision.recorded person.action
    step.started step.completed step.skipped evidence finding.recorded finding.resolved checklist.answered
    ticket.cancelled ticket.moved drift.detected drift.reverted drift.revert_failed
    pause.set pause.reason_added pause.reason_cleared pause.cleared
    question.asked question.answered question.withdrawn question.reopened note
  )

  describe "catalog/0" do
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

    test "every type a machine or a person writes takes the legacy signal name it mirrors" do
      for {type, entry} <- Types.catalog(), entry.writers != [:agent], type != "note" do
        assert Keyword.has_key?(entry.optional, :signal), type
      end
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
      assert {:error, {:not_allowed, _}} = Types.validate("step.started", step(), :machine, nil)
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

      assert {:ok, %{step_id: nil}} = step.("step.started", %{step_id: nil})
      assert {:ok, %{step_id: "s1"}} = step.("step.completed", %{step_id: "s1"})
      assert {:error, {:invalid_payload, [:mode]}} = step.("step.skipped", %{mode: "manual"})
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
      assert {:ok, %{artifacts: ["a1"]}} = evidence.(%{caption: "Before", artifacts: ["a1"]})
      assert {:error, {:invalid_payload, [:caption]}} = evidence.(%{caption: String.duplicate("c", 501)})

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
      assert Types.idempotency_key("run.ended", %{run_id: "run-1"}, nil) == "run.ended:run-1"
      assert Types.idempotency_key("decision.recorded", %{key: "c1"}, nil) == "decision.recorded:c1"
      assert Types.idempotency_key("decision.recorded", %{answer: "yes"}, nil) == nil
      assert Types.idempotency_key("note", %{text: "x"}, nil) == nil
      assert Types.idempotency_key("nope", %{}, 42) == nil
    end
  end

  defp finding, do: %{class: "unclassified", severity: "high", description: "The button is clipped."}
  defp step, do: %{title: "Open the app", mode: "orchestrated"}
end
