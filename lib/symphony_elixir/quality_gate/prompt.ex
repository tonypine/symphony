defmodule SymphonyElixir.QualityGate.Prompt do
  @moduledoc """
  Builds the user prompt sent to LLM providers for issue scoping.

  The prompt asks the model to evaluate the issue across clarity, scope,
  ambiguity markers, and sandbox dependency, and to reply with a strict JSON
  payload of the form
  `{"score": <1-10>, "reason": "<one-sentence>", "questions": ["..."]}`.
  """

  alias SymphonyElixir.{Linear.Issue, PromptSafety}

  @system_instructions """
  You evaluate Linear issues for autonomous code-agent readiness.

  Score each issue from 1 (poor candidate) to 10 (excellent candidate) based on:
    - Clarity: well-defined problem and acceptance criteria
    - Scope: bounded surface area for a single PR
    - Ambiguity markers: words like "maybe", "investigate", "explore", open-ended questions
    - Sandbox dependency: needs production credentials, manual UI testing, real browsers, deploys
    - User walkthrough: a user-facing issue (UI, CLI output, anything a user sees or does)
      without a "## User walkthrough" section of numbered steps, each with the expected
      visible result, scores lower

  Reply with ONLY a single JSON object:
    {"score": <integer 1-10>, "reason": "<one short sentence>", "questions": ["<question>", "<question>", "<question>"]}

  The "questions" field is optional. Include it on the same JSON object only when
  the issue is almost ready but needs clarification.

  Clarifying questions must:
    - include 3 to 5 questions
    - be answerable in 1-2 sentences each
    - focus on missing acceptance criteria, ambiguous scope, or unspecified file/module targets

  Do not include any extra prose, code fences, or commentary.
  """

  @spec system_instructions() :: String.t()
  def system_instructions, do: @system_instructions

  @spec user_prompt(Issue.t()) :: String.t()
  def user_prompt(%Issue{} = issue) do
    linear_input_warnings = linear_input_warnings(issue)

    """
    Identifier: #{present(issue.identifier)}
    Title: #{present_linear(issue.title, "(unknown)", &PromptSafety.linear_issue_title/1)}
    Labels: #{format_labels(issue.labels)}
    State: #{present(issue.state)}

    #{format_comments(issue.comments)}

    Description:
    #{present_linear(issue.description, "(no description)", &PromptSafety.linear_issue_body/1)}

    #{PromptSafety.warning_section(linear_input_warnings)}
    """
  end

  defp present(value, fallback \\ "(unknown)")
  defp present(nil, fallback), do: fallback
  defp present("", fallback), do: fallback
  defp present(value, _fallback) when is_binary(value), do: value
  defp present(value, _fallback), do: to_string(value)

  defp present_linear(value, fallback, _renderer) when value in [nil, ""], do: fallback

  defp present_linear(value, _fallback, renderer) when is_binary(value), do: renderer.(value)

  defp present_linear(value, _fallback, renderer), do: value |> to_string() |> renderer.()

  defp format_labels([]), do: "(none)"
  defp format_labels(labels) when is_list(labels), do: Enum.join(labels, ", ")
  defp format_labels(_labels), do: "(none)"

  defp format_comments(comments) when is_list(comments) and comments != [] do
    formatted =
      comments
      |> Enum.map(&format_comment/1)
      |> Enum.reject(&(&1 == ""))

    if formatted == [] do
      ""
    else
      "Recent comments:\n" <> Enum.join(formatted, "\n\n")
    end
  end

  defp format_comments(_comments), do: ""

  defp format_comment(%{body: body} = comment) when is_binary(body) do
    author = present(Map.get(comment, :author), "Unknown")
    created_at = format_comment_datetime(Map.get(comment, :created_at))

    "[#{author} @ #{created_at}]\n#{PromptSafety.linear_issue_comment_body(body)}"
  end

  defp format_comment(_comment), do: ""

  defp linear_input_warnings(%Issue{} = issue) do
    sources =
      [
        {"issue.title", issue.title},
        {"issue.description", issue.description}
      ] ++ issue_comment_warning_sources(issue.comments)

    PromptSafety.warning_fields(sources)
  end

  defp issue_comment_warning_sources(comments) when is_list(comments) do
    comments
    |> Enum.with_index(1)
    |> Enum.map(fn {comment, index} -> {"issue.comments[#{index}].body", comment_body(comment)} end)
  end

  defp issue_comment_warning_sources(_comments), do: []

  defp comment_body(%{body: body}), do: body
  defp comment_body(%{"body" => body}), do: body
  defp comment_body(_comment), do: nil

  defp format_comment_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_comment_datetime(_datetime), do: "unknown time"
end
