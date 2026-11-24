defmodule SymphonyElixir.Learnings.ReflectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Learnings.Reflection

  test "parse_response accepts fenced JSON response envelopes" do
    response = """
    ```json
    {
      "learnings": [
        {
          "rule": "Prefer existing dashboard helpers before adding new formatting paths.",
          "tags": ["dashboard", "repo-patterns"],
          "evidence_quote": "Prefer the existing helper."
        }
      ]
    }
    ```
    """

    assert {:ok,
            [
              %{
                rule: "Prefer existing dashboard helpers before adding new formatting paths.",
                tags: ["dashboard", "repo-patterns"],
                evidence_quote: "Prefer the existing helper."
              }
            ]} = Reflection.parse_response(response, 3)
  end

  test "parse_response accepts a single learning object" do
    response =
      ~s({"rule":"Document workflow config in both examples.","tags":["docs","workflow-config"],"evidence_quote":"Update both docs."})

    assert {:ok,
            [
              %{
                rule: "Document workflow config in both examples.",
                tags: ["docs", "workflow-config"],
                evidence_quote: "Update both docs."
              }
            ]} = Reflection.parse_response(response, 3)
  end

  test "parse_response rejects the wrong tag count" do
    response =
      ~s({"learnings":[{"rule":"Keep rules specific.","tags":["docs"],"evidence_quote":"Needs more tags."}]})

    assert {:error, {:malformed_response, :invalid_tags}} = Reflection.parse_response(response, 3)
  end

  test "parse_response rejects non-kebab-case tags" do
    response =
      ~s({"learnings":[{"rule":"Keep tags normalized.","tags":["Docs","workflow_config"],"evidence_quote":"Use kebab case."}]})

    assert {:error, {:malformed_response, :invalid_tags}} = Reflection.parse_response(response, 3)
  end

  test "parse_response rejects empty evidence quotes" do
    response =
      ~s({"learnings":[{"rule":"Keep evidence auditable.","tags":["review-feedback","repo-patterns"],"evidence_quote":"   "}]})

    assert {:error, {:malformed_response, :invalid_evidence_quote}} = Reflection.parse_response(response, 3)
  end

  test "parse_response rejects missing required keys" do
    response =
      ~s({"learnings":[{"rule":"Keep evidence auditable.","tags":["review-feedback","repo-patterns"]}]})

    assert {:error, {:malformed_response, :invalid_learning_entry}} = Reflection.parse_response(response, 3)
  end
end
