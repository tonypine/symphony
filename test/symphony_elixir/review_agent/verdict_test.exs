defmodule SymphonyElixir.ReviewAgent.VerdictTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewAgent.Verdict

  defp finding(overrides) do
    Map.merge(
      %{
        "summary" => "Handle the empty list.",
        "file" => "lib/app.ex",
        "line_range" => [3, 4],
        "quoted_snippet" => "def run([]), do: :ok",
        "suggested_fix" => "Return an error."
      },
      overrides
    )
  end

  defp line_range(range) do
    assert {:ok, %{findings: [%{line_range: line_range}]}} =
             Verdict.from_map(%{"verdict" => "request_changes", "findings" => [finding(%{"line_range" => range})]})

    line_range
  end

  describe "from_map/1" do
    test "reads a verdict word in another case, with spaces or dashes, or a synonym" do
      for {word, verdict} <- [
            {"approve", :approve},
            {"Approved", :approve},
            {" APPROVE ", :approve},
            {"request_changes", :request_changes},
            {"request-changes", :request_changes},
            {"Request Changes", :request_changes},
            {"changes_requested", :request_changes},
            {"request_change", :request_changes},
            {"blocked", :block},
            {"Block", :block}
          ] do
        decoded = %{"verdict" => word, "comments" => ["note"], "reason" => "Unsafe."}
        assert {:ok, %{verdict: ^verdict}} = Verdict.from_map(decoded), "#{inspect(word)} should read as #{verdict}"
      end
    end

    test "refuses a verdict word with no single reading" do
      for word <- ["maybe", "", "lgtm", nil, 1] do
        assert {:error, :invalid_verdict} = Verdict.from_map(%{"verdict" => word})
      end
    end

    test "reads a line range given as one line, a span, a reversed pair or an object" do
      assert line_range([3, 4]) == {3, 4}
      assert line_range([15, 12]) == {12, 15}
      assert line_range([7]) == {7, 7}
      assert line_range(12) == {12, 12}
      assert line_range("12") == {12, 12}
      assert line_range("12-15") == {12, 15}
      assert line_range("L12-L15") == {12, 15}
      assert line_range("15 - 12") == {12, 15}
      assert line_range("12:15") == {12, 15}
      assert line_range(["12", "15"]) == {12, 15}
      assert line_range(%{"start" => 12, "end" => 15}) == {12, 15}
      assert line_range(%{"start" => "9"}) == {9, 9}
    end

    test "refuses a line range with no positive line in it" do
      refused = [nil, 0, -3, "", "twelve", "12-", "12a", [0, 3], ["x", 3], ["0", 3], [1, 2, 3], [], %{"end" => 4}, %{"start" => 1.5}, 2.0]

      for range <- refused do
        assert {:error, :invalid_finding_line_range} =
                 Verdict.from_map(%{"verdict" => "request_changes", "findings" => [finding(%{"line_range" => range})]}),
               "#{inspect(range)} should be refused"
      end
    end

    test "keeps a finding's recorded decision, upcased, and drops a blank one" do
      assert {:ok, %{findings: [%{decision: "D2"}]}} =
               Verdict.from_map(%{"verdict" => "request_changes", "findings" => [finding(%{"decision" => " d2 "})]})

      assert {:ok, %{findings: [kept]}} =
               Verdict.from_map(%{"verdict" => "request_changes", "findings" => [finding(%{"decision" => "  "})]})

      refute Map.has_key?(kept, :decision)
    end

    test "trims comments and drops the blank and non-string ones" do
      assert {:ok, %{verdict: :approve, comments: ["Nit."], findings: []} = result} =
               Verdict.from_map(%{"verdict" => "approve", "comments" => [" Nit. ", "", 3]})

      refute Map.has_key?(result, :reason)
    end

    test "keeps a trimmed reason on any verdict and requires one for block" do
      assert {:ok, %{reason: "Fine."}} = Verdict.from_map(%{"verdict" => "approve", "reason" => " Fine. "})
      assert {:ok, %{verdict: :block, reason: "Unsafe."}} = Verdict.from_map(%{"verdict" => "block", "reason" => " Unsafe. "})
      assert {:error, :missing_block_reason} = Verdict.from_map(%{"verdict" => "block", "reason" => "  "})
      assert {:error, :missing_block_reason} = Verdict.from_map(%{"verdict" => "block"})
    end

    test "refuses malformed comments, findings and finding fields" do
      assert {:error, :not_a_json_object} = Verdict.from_map(["approve"])
      assert {:error, :invalid_comments} = Verdict.from_map(%{"verdict" => "approve", "comments" => "note"})
      assert {:error, :invalid_findings} = Verdict.from_map(%{"verdict" => "approve", "findings" => %{}})
      assert {:error, :invalid_finding} = Verdict.from_map(%{"verdict" => "approve", "findings" => ["text"]})
      assert {:error, :missing_request_changes_comments} = Verdict.from_map(%{"verdict" => "request_changes"})

      for {field, error} <- [
            {"summary", :invalid_finding_summary},
            {"file", :invalid_finding_file},
            {"quoted_snippet", :invalid_finding_quoted_snippet},
            {"suggested_fix", :invalid_finding_suggested_fix}
          ] do
        assert {:error, ^error} = Verdict.from_map(%{"verdict" => "request_changes", "findings" => [finding(%{field => " "})]})
        assert {:error, ^error} = Verdict.from_map(%{"verdict" => "request_changes", "findings" => [finding(%{field => 7})]})
      end
    end
  end

  describe "record/2" do
    test "sends a readable verdict to the reviewer process and tells the model to end its turn" do
      assert {:ok, %{"recorded" => true, "verdict" => "request_changes", "next" => next}} =
               Verdict.record(%{"verdict" => "Request-Changes", "findings" => [finding(%{"line_range" => "3-4"})]}, self())

      assert next =~ "End your turn"
      assert_received {:review_verdict, %{verdict: :request_changes, findings: [%{line_range: {3, 4}}]}}
    end

    test "returns the parser's error for a verdict it cannot read, and records nothing" do
      assert {:error, {:invalid_review_verdict, :invalid_verdict}} = Verdict.record(%{"verdict" => "maybe"}, self())
      refute_received {:review_verdict, _result}
    end

    test "is unavailable without a reviewer process to record to" do
      assert {:error, :review_verdict_unavailable} = Verdict.record(%{"verdict" => "approve"}, nil)
    end
  end

  test "the tool spec is the contract: a verdict enum and evidence-backed findings" do
    spec = Verdict.tool_spec()

    assert spec["name"] == Verdict.tool_name()
    assert spec["name"] == "review_verdict"
    assert get_in(spec, ["inputSchema", "properties", "verdict", "enum"]) == ["approve", "request_changes", "block"]
    assert get_in(spec, ["inputSchema", "required"]) == ["verdict"]

    finding_schema = get_in(spec, ["inputSchema", "properties", "findings", "items"])
    assert finding_schema["required"] == ["summary", "file", "line_range", "quoted_snippet", "suggested_fix"]
    assert get_in(finding_schema, ["properties", "line_range", "minItems"]) == 2
    assert Enum.sort(Verdict.tool_arguments()) == ["comments", "findings", "reason", "verdict"]
  end

  test "describe_error/1 names what to fix for every parser error" do
    {:error, decode_error} = Jason.decode("{")

    for {reason, text} <- [
          {:empty_response, "the reply was empty."},
          {:no_json_object, "the reply had no review_verdict call and no JSON object."},
          {:not_a_json_object, "the verdict must be a JSON object."},
          {:invalid_verdict, "`verdict` must be one of approve, request_changes or block."},
          {:invalid_comments, "`comments` must be a list of strings."},
          {:invalid_findings, "`findings` must be a list of objects."},
          {:invalid_finding, "each finding must be an object."},
          {:invalid_finding_summary, "each finding needs a non-empty `summary`."},
          {:invalid_finding_file, "each finding needs a non-empty `file`."},
          {:invalid_finding_quoted_snippet, "each finding needs a non-empty `quoted_snippet`."},
          {:invalid_finding_suggested_fix, "each finding needs a non-empty `suggested_fix`."},
          {:invalid_finding_line_range, "each finding's `line_range` must be [start, end] with positive line numbers."},
          {:missing_block_reason, "a block needs a non-empty `reason`."},
          {:missing_request_changes_comments, "request_changes needs at least one finding or comment."},
          {:something_else, ":something_else."}
        ] do
      assert Verdict.describe_error(reason) == text
    end

    assert Verdict.describe_error({:invalid_json, decode_error}) =~ "the JSON object did not parse ("
  end
end
