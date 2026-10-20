defmodule SymphonyElixir.ReviewAgent.Verdict do
  @moduledoc """
  The reviewer's verdict contract: the `review_verdict` tool the reviewer calls with its verdict,
  and the coercion that reads a verdict map, whether it came as the tool's input or as JSON
  scraped from the reviewer's final message (`SymphonyElixir.ReviewAgent.parse_response/1`).

  The coercion is lenient where a slip has only one reading: a verdict word in another case or a
  synonym (`Approved`, `changes_requested`, `request-changes`, `blocked`), and a line range given
  as one line (`12`, `"12"`), a span (`"12-15"`), a reversed pair (`[15, 12]`) or an object
  (`{"start": 12, "end": 15}`).
  """

  @tool_name "review_verdict"

  @verdict_words %{
    "approve" => :approve,
    "approved" => :approve,
    "request_changes" => :request_changes,
    "request_change" => :request_changes,
    "changes_requested" => :request_changes,
    "block" => :block,
    "blocked" => :block
  }

  @line_span ~r/\A\s*L?(\d+)\s*(?:(?:-|–|:|\.\.)\s*L?(\d+))?\s*\z/i

  @finding_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["summary", "file", "line_range", "quoted_snippet", "suggested_fix"],
    "properties" => %{
      "summary" => %{"type" => "string", "description" => "A concise, actionable summary of the problem."},
      "file" => %{"type" => "string", "description" => "The file's path from the repository root, e.g. lib/app/thing.ex."},
      "line_range" => %{
        "type" => "array",
        "items" => %{"type" => "integer", "minimum" => 1},
        "minItems" => 2,
        "maxItems" => 2,
        "description" => "[start, end]: the 1-based lines the quoted snippet sits on, start no later than end."
      },
      "quoted_snippet" => %{"type" => "string", "description" => "The exact line or lines at line_range, copied from the diff or the file."},
      "suggested_fix" => %{"type" => "string", "description" => "A concrete fix."},
      "decision" => %{"type" => "string", "description" => "The ticket's recorded decision the finding is about, as D<n>, only when it is about one."}
    }
  }

  @tool_spec %{
    "name" => @tool_name,
    "description" =>
      "Record your review verdict. Call it once the review is done, then end your turn. " <>
        "A verdict the tool refuses comes back with the reason: fix it and call the tool again. A later call replaces an earlier one.",
    "inputSchema" => %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["verdict"],
      "properties" => %{
        "verdict" => %{"type" => "string", "enum" => ["approve", "request_changes", "block"]},
        "findings" => %{"type" => "array", "items" => @finding_schema, "description" => "Each problem, with the evidence that proves it."},
        "comments" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Notes that are not findings."},
        "reason" => %{"type" => "string", "description" => "Why the change is blocked; required for block."}
      }
    }
  }

  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc "The `review_verdict` tool's spec, as the agent's tool list carries it."
  @spec tool_spec() :: map()
  def tool_spec, do: @tool_spec

  @doc "The tool's argument names."
  @spec tool_arguments() :: [String.t()]
  def tool_arguments, do: Map.keys(@tool_spec["inputSchema"]["properties"])

  @doc """
  The `review_verdict` tool's call: reads `args` as a verdict and sends it to `sink`, the reviewer
  process (`{:review_verdict, result}`), which takes the last one a turn recorded. A verdict it
  cannot read comes back as the error, so the model fixes it in the same turn.
  """
  @spec record(map(), pid() | nil) :: {:ok, map()} | {:error, term()}
  def record(args, sink) when is_pid(sink) do
    case from_map(args) do
      {:ok, result} ->
        send(sink, {:review_verdict, result})

        {:ok,
         %{
           "recorded" => true,
           "verdict" => Atom.to_string(result.verdict),
           "next" => "Symphony recorded the verdict. End your turn now."
         }}

      {:error, reason} ->
        {:error, {:invalid_review_verdict, reason}}
    end
  end

  def record(_args, _sink), do: {:error, :review_verdict_unavailable}

  @doc "Reads a decoded verdict object into the reviewer's result."
  @spec from_map(term()) :: {:ok, map()} | {:error, term()}
  def from_map(decoded) when is_map(decoded) do
    with {:ok, verdict} <- coerce_verdict(Map.get(decoded, "verdict")),
         {:ok, comments} <- coerce_comments(Map.get(decoded, "comments")),
         {:ok, findings} <- coerce_findings(Map.get(decoded, "findings")),
         {:ok, reason} <- coerce_reason(Map.get(decoded, "reason"), verdict),
         result = %{verdict: verdict, comments: comments, findings: findings, reason: reason},
         {:ok, result} <- validate_result(result) do
      {:ok, compact_result(result)}
    end
  end

  def from_map(_decoded), do: {:error, :not_a_json_object}

  @doc "What was wrong with a verdict, in a sentence the model can act on."
  @spec describe_error(term()) :: String.t()
  def describe_error(:empty_response), do: "the reply was empty."
  def describe_error(:no_json_object), do: "the reply had no review_verdict call and no JSON object."
  def describe_error(:not_a_json_object), do: "the verdict must be a JSON object."
  def describe_error({:invalid_json, %Jason.DecodeError{} = error}), do: "the JSON object did not parse (#{Exception.message(error)})."
  def describe_error(:invalid_verdict), do: "`verdict` must be one of approve, request_changes or block."
  def describe_error(:invalid_comments), do: "`comments` must be a list of strings."
  def describe_error(:invalid_findings), do: "`findings` must be a list of objects."
  def describe_error(:invalid_finding), do: "each finding must be an object."
  def describe_error(:invalid_finding_summary), do: "each finding needs a non-empty `summary`."
  def describe_error(:invalid_finding_file), do: "each finding needs a non-empty `file`."
  def describe_error(:invalid_finding_quoted_snippet), do: "each finding needs a non-empty `quoted_snippet`."
  def describe_error(:invalid_finding_suggested_fix), do: "each finding needs a non-empty `suggested_fix`."
  def describe_error(:invalid_finding_line_range), do: "each finding's `line_range` must be [start, end] with positive line numbers."
  def describe_error(:missing_block_reason), do: "a block needs a non-empty `reason`."
  def describe_error(:missing_request_changes_comments), do: "request_changes needs at least one finding or comment."
  def describe_error(reason), do: "#{inspect(reason)}."

  defp coerce_verdict(verdict) when is_binary(verdict) do
    word =
      verdict
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[\s-]+/, "_")

    case Map.fetch(@verdict_words, word) do
      {:ok, verdict} -> {:ok, verdict}
      :error -> {:error, :invalid_verdict}
    end
  end

  defp coerce_verdict(_verdict), do: {:error, :invalid_verdict}

  defp coerce_comments(nil), do: {:ok, []}

  defp coerce_comments(comments) when is_list(comments) do
    {:ok,
     comments
     |> Enum.filter(&is_binary/1)
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))}
  end

  defp coerce_comments(_comments), do: {:error, :invalid_comments}

  defp coerce_findings(nil), do: {:ok, []}

  defp coerce_findings(findings) when is_list(findings) do
    findings
    |> Enum.map(&coerce_finding/1)
    |> collect_coerced_findings([])
  end

  defp coerce_findings(_findings), do: {:error, :invalid_findings}

  defp collect_coerced_findings([], acc), do: {:ok, Enum.reverse(acc)}
  defp collect_coerced_findings([{:ok, finding} | rest], acc), do: collect_coerced_findings(rest, [finding | acc])
  defp collect_coerced_findings([{:error, reason} | _rest], _acc), do: {:error, reason}

  defp coerce_finding(finding) when is_map(finding) do
    with {:ok, summary} <- required_string(Map.get(finding, "summary"), :invalid_finding_summary),
         {:ok, file} <- required_string(Map.get(finding, "file"), :invalid_finding_file),
         {:ok, line_range} <- coerce_line_range(Map.get(finding, "line_range")),
         {:ok, quoted_snippet} <- required_string(Map.get(finding, "quoted_snippet"), :invalid_finding_quoted_snippet),
         {:ok, suggested_fix} <- required_string(Map.get(finding, "suggested_fix"), :invalid_finding_suggested_fix) do
      {:ok,
       maybe_put_decision(
         %{
           summary: summary,
           file: file,
           line_range: line_range,
           quoted_snippet: quoted_snippet,
           suggested_fix: suggested_fix
         },
         Map.get(finding, "decision")
       )}
    end
  end

  defp coerce_finding(_finding), do: {:error, :invalid_finding}

  # The recorded decision a finding is about (`ReviewAgent.honour_decisions/3`), as `D<n>`.
  defp maybe_put_decision(finding, decision) when is_binary(decision) do
    case String.trim(decision) |> String.upcase() do
      "" -> finding
      decision -> Map.put(finding, :decision, decision)
    end
  end

  defp maybe_put_decision(finding, _decision), do: finding

  defp required_string(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_string(_value, error), do: {:error, error}

  # One line (`12`, `"12"`, `[12]`), a span (`[12, 15]`, `"12-15"`, `{"start": 12, "end": 15}`),
  # and a reversed pair, which is put in order.
  defp coerce_line_range(%{"start" => start_line} = range), do: coerce_line_pair(start_line, Map.get(range, "end", start_line))
  defp coerce_line_range([start_line, end_line]), do: coerce_line_pair(start_line, end_line)
  defp coerce_line_range([line]), do: coerce_line_pair(line, line)
  defp coerce_line_range(line) when is_integer(line), do: coerce_line_pair(line, line)

  defp coerce_line_range(text) when is_binary(text) do
    case Regex.run(@line_span, text) do
      [_match, start_line] -> coerce_line_pair(start_line, start_line)
      [_match, start_line, end_line] -> coerce_line_pair(start_line, end_line)
      nil -> {:error, :invalid_finding_line_range}
    end
  end

  defp coerce_line_range(_line_range), do: {:error, :invalid_finding_line_range}

  defp coerce_line_pair(start_line, end_line) do
    with {:ok, start_line} <- coerce_positive_integer(start_line),
         {:ok, end_line} <- coerce_positive_integer(end_line) do
      {:ok, {min(start_line, end_line), max(start_line, end_line)}}
    else
      _other -> {:error, :invalid_finding_line_range}
    end
  end

  defp coerce_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp coerce_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, :invalid_positive_integer}
    end
  end

  defp coerce_positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp coerce_reason(reason, :block) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :missing_block_reason}
      trimmed -> {:ok, trimmed}
    end
  end

  defp coerce_reason(_reason, :block), do: {:error, :missing_block_reason}
  defp coerce_reason(reason, _verdict) when is_binary(reason), do: {:ok, String.trim(reason)}
  defp coerce_reason(_reason, _verdict), do: {:ok, nil}

  defp validate_result(%{verdict: :request_changes, comments: [], findings: []}), do: {:error, :missing_request_changes_comments}
  defp validate_result(result), do: {:ok, result}

  defp compact_result(%{reason: nil} = result), do: Map.delete(result, :reason)
  defp compact_result(result), do: result
end
