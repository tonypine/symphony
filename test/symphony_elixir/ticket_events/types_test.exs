defmodule SymphonyElixir.TicketEvents.TypesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TicketEvents.Types

  @types ~w(
    phase.entered hold.set hold.cleared run.started run.ended attempt.pushed verdict.recorded
    decision.requested decision.withdrawn decision.recorded person.action
    step.started step.completed step.skipped evidence finding.recorded finding.resolved checklist.answered
    note
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
