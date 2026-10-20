defmodule SymphonyElixir.QaAgent.VerdictTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaAgent.Verdict

  describe "from_map/1" do
    test "reads a verdict word in any case, or a synonym" do
      for {word, verdict} <- [
            {"pass", :pass},
            {" PASS ", :pass},
            {"Passed", :pass},
            {"fail", :fail},
            {"FAILED", :fail},
            {"blocked", :blocked},
            {"Block", :blocked}
          ] do
        decoded = %{"verdict" => word, "findings" => ["A defect."], "reason" => "No key."}
        assert {:ok, %{verdict: ^verdict}} = Verdict.from_map(decoded)
      end

      for word <- ["maybe", "", nil, 1] do
        assert Verdict.from_map(%{"verdict" => word}) == {:error, :invalid_verdict}
      end

      assert Verdict.from_map(["pass"]) == {:error, :not_a_json_object}
    end

    test "reads findings as a list, a single object or a single sentence" do
      finding = %{"summary" => "The header is clipped", "viewport" => "1400×900 pt"}

      assert {:ok, %{findings: ["At 1400×900 pt: The header is clipped."]}} = Verdict.from_map(%{"verdict" => "fail", "findings" => finding})
      assert {:ok, %{findings: ["The header is clipped."]}} = Verdict.from_map(%{"verdict" => "fail", "findings" => "The header is clipped."})
      assert {:ok, %{findings: ["The header is clipped."]}} = Verdict.from_map(%{"verdict" => "fail", "findings" => %{"summary" => "The header is clipped"}})

      assert {:ok, %{findings: ["One.", "Step 1: Two! Expected: shown. Actual: hidden?"]}} =
               Verdict.from_map(%{
                 "verdict" => "fail",
                 "findings" => ["One.", " ", %{"step" => "Step 1", "summary" => "Two!", "expected" => "shown", "actual" => "hidden?", "evidence" => []}]
               })

      for findings <- [[%{"step" => "Step 1", "expected" => "shown"}], [3], 3] do
        assert {:error, reason} = Verdict.from_map(%{"verdict" => "fail", "findings" => findings})
        assert reason in [:invalid_finding, :invalid_findings]
      end
    end

    test "reads steps as a list or a single object, with a status in any case" do
      step = %{
        "name" => " Settings pane ",
        "status" => "Failed",
        "details" => " clipped ",
        "evidence" => "qa-evidence/a.png",
        "checklist" => true,
        "gap" => "Clipped pane",
        "defect" => " clip ",
        "blocked_by" => "TP-1"
      }

      assert {:ok, %{verdict: :fail, findings: [], steps: [coerced]}} = Verdict.from_map(%{"verdict" => "fail", "steps" => step})

      assert coerced == %{
               name: "Settings pane",
               status: "fail",
               details: "clipped",
               evidence: ["qa-evidence/a.png"],
               checklist: true,
               gap: "Clipped pane",
               defect: "clip",
               blocked_by: ["TP-1"]
             }

      assert {:ok, %{steps: [%{name: "a", status: "skipped", details: "", evidence: []}]}} =
               Verdict.from_map(%{"verdict" => "pass", "steps" => [%{"name" => "a", "status" => "SKIP"}]})

      for steps <- [[%{"name" => " ", "status" => "pass"}], [%{"name" => "a", "status" => "maybe"}], [%{"status" => "pass"}], "a"] do
        assert Verdict.from_map(%{"verdict" => "pass", "steps" => steps}) == {:error, :invalid_steps}
      end
    end

    test "a blocked verdict carries needs_person, needs_dev_server and covered_by as the parsed JSON did" do
      assert {:ok, result} =
               Verdict.from_map(%{
                 "verdict" => "blocked",
                 "reason" => " The project's server was not running. ",
                 "needs_person" => "TRUE",
                 "needs_dev_server" => true,
                 "covered_by" => " tp-12 "
               })

      assert result == %{
               verdict: :blocked,
               summary: "",
               steps: [],
               findings: [],
               reason: "The project's server was not running.",
               needs_person: true,
               needs_dev_server: true,
               covered_by: "TP-12"
             }

      assert {:ok, result} =
               Verdict.from_map(%{"verdict" => "blocked", "reason" => "x", "needs_person" => false, "needs_dev_server" => "no", "covered_by" => "the tools ticket"})

      refute Map.has_key?(result, :needs_person)
      refute Map.has_key?(result, :needs_dev_server)
      refute Map.has_key?(result, :covered_by)
    end

    test "reads scope none on a pass" do
      assert {:ok, %{scope: :none}} = Verdict.from_map(%{"verdict" => "pass", "scope" => " None "})
      assert {:ok, result} = Verdict.from_map(%{"verdict" => "pass", "scope" => "all"})
      refute Map.has_key?(result, :scope)
    end

    test "a fail needs a finding or a failing step, and a blocked verdict a reason" do
      assert Verdict.from_map(%{"verdict" => "fail"}) == {:error, :missing_fail_findings}
      assert Verdict.from_map(%{"verdict" => "blocked", "reason" => " "}) == {:error, :missing_blocked_reason}
      assert Verdict.from_map(%{"verdict" => "fail", "findings" => {:bad}}) == {:error, :invalid_findings}
    end
  end

  describe "record/2" do
    test "sends a readable verdict to the QA process and refuses one it cannot read" do
      assert {:ok, %{"recorded" => true, "verdict" => "fail"}} = Verdict.record(%{"verdict" => "fail", "findings" => "Broken."}, self())
      assert_received {:qa_verdict, %{verdict: :fail, findings: ["Broken."]}}

      assert Verdict.record(%{"verdict" => "maybe"}, self()) == {:error, {:invalid_qa_verdict, :invalid_verdict}}
      refute_received {:qa_verdict, _result}
    end

    test "is unavailable without a process to record to" do
      assert Verdict.record(%{"verdict" => "pass"}, nil) == {:error, :qa_verdict_unavailable}
    end
  end

  test "the tool spec names the verdict's fields" do
    spec = Verdict.tool_spec()

    assert spec["name"] == Verdict.tool_name()
    assert spec["name"] == "qa_verdict"
    assert spec["inputSchema"]["required"] == ["verdict"]

    assert Enum.sort(Verdict.tool_arguments()) ==
             ~w(covered_by findings needs_dev_server needs_person reason scope steps summary verdict)

    assert Map.keys(spec["inputSchema"]["properties"]["findings"]["items"]["properties"]) |> Enum.sort() ==
             ~w(actual evidence expected step summary viewport)
  end

  test "describe_error/1 says what was wrong in a sentence" do
    for {reason, text} <- [
          {:empty_response, "the answer was empty."},
          {:no_verdict_object, "the answer had no qa_verdict call and no JSON verdict object."},
          {:not_a_json_object, "the verdict must be a JSON object."},
          {:invalid_verdict, "`verdict` must be one of pass, fail or blocked."},
          {:invalid_steps, "each step must be an object with a non-empty `name` and a `status` of pass, fail, blocked or skipped."},
          {:invalid_findings, "`findings` must be a list of findings."},
          {:invalid_finding, "each finding must be a sentence, or an object with a `summary` or the `actual` result."},
          {:missing_fail_findings, "a fail needs at least one finding or failing step."},
          {:missing_blocked_reason, "a blocked verdict needs a non-empty `reason`."},
          {:other, ":other."}
        ] do
      assert Verdict.describe_error(reason) == text
    end
  end
end
