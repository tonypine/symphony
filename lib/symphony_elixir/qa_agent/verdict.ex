defmodule SymphonyElixir.QaAgent.Verdict do
  @moduledoc """
  The QA agent's verdict contract: the `qa_verdict` tool the QA agent calls as its last act, and
  the coercion that reads a verdict map, whether it came as the tool's input or as JSON scraped
  from the agent's final message (`SymphonyElixir.QaAgent.parse_response/1`, the fallback kept for
  one release).

  The call is the verdict: `record/2` sends it to the QA process the moment it arrives, so a pass
  whose session then ends without a word (an empty final message, a `claude` process that never
  exits) still has it. The coercion is lenient where a slip has only one reading, as the
  reviewer's `SymphonyElixir.ReviewAgent.Verdict` is: a verdict or step status in any case or a
  synonym (`PASS`, `Failed`, `block`), `findings` as a list, a single object or a single sentence,
  `steps` as a list or a single object, and `needs_person`/`needs_dev_server` as `true` or `"true"`.
  A step's `unprovable` status says it needs what no playbook of the pass can give
  (`SymphonyElixir.QaVerification` then decides the pass from the other steps).
  A finding object (`step`, `viewport`, `expected`, `actual`, `evidence`) is rendered to the one
  line the QA report and the rework run read (`findings`); `finding_details` keeps, per finding and
  in the same order, that line with the finding's `step`, `viewport` and `evidence` as given, for
  the ledger's `finding.recorded` events (`SymphonyElixir.QaVerification`).
  """

  @tool_name "qa_verdict"

  @verdict_words %{
    "pass" => :pass,
    "passed" => :pass,
    "fail" => :fail,
    "failed" => :fail,
    "blocked" => :blocked,
    "block" => :blocked
  }

  @step_statuses %{
    "pass" => "pass",
    "passed" => "pass",
    "fail" => "fail",
    "failed" => "fail",
    "blocked" => "blocked",
    "block" => "blocked",
    "skipped" => "skipped",
    "skip" => "skipped",
    "unprovable" => "unprovable"
  }

  @identifier_pattern ~r/\A[A-Za-z][A-Za-z0-9]*-\d+\z/

  @typedoc "A finding's line with the step, viewport and evidence it named (nil and `[]` when none)."
  @type finding_detail :: %{
          line: String.t(),
          step: String.t() | nil,
          viewport: String.t() | nil,
          evidence: [String.t()]
        }

  @evidence_schema %{
    "type" => "array",
    "items" => %{"type" => "string"},
    "description" => "linear_attach_file URLs or qa-evidence/ paths."
  }

  @finding_schema %{
    "type" => "object",
    "properties" => %{
      "summary" => %{"type" => "string", "description" => "The defect in one sentence."},
      "step" => %{"type" => "string", "description" => "The walkthrough step or check it was found on."},
      "viewport" => %{"type" => "string", "description" => "The window or viewport size it shows at, e.g. 1400×900 pt."},
      "expected" => %{"type" => "string", "description" => "What the ticket says should happen."},
      "actual" => %{"type" => "string", "description" => "What happened instead."},
      "evidence" => @evidence_schema
    }
  }

  @step_schema %{
    "type" => "object",
    "required" => ["name", "status"],
    "properties" => %{
      "name" => %{"type" => "string", "description" => "What you checked."},
      "status" => %{
        "type" => "string",
        "enum" => ["pass", "fail", "blocked", "skipped", "unprovable"],
        "description" => "unprovable: the step needs what no playbook of this pass can give (the prompt says when); the reason goes in details."
      },
      "details" => %{"type" => "string", "description" => "The command and the relevant output, or what you saw."},
      "evidence" => @evidence_schema,
      "checklist" => %{"type" => "boolean", "description" => "Epic review: the step is one of the epic's checklist rows."},
      "gap" => %{"type" => "string", "description" => "Epic review: a short label for a failing step."},
      "blocked_by" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Epic review: gap labels or sub-tickets it waits on."},
      "defect" => %{"type" => "string", "description" => "Epic review: a few words naming the defect a failing step rests on."}
    }
  }

  @tool_spec %{
    "name" => @tool_name,
    "description" =>
      "Record your QA verdict. Call it as your last act, once every step you could run has run, then end your turn. " <>
        "A verdict the tool refuses comes back with the reason: fix it and call the tool again. A later call replaces an earlier one.",
    "inputSchema" => %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["verdict"],
      "properties" => %{
        "verdict" => %{"type" => "string", "enum" => ["pass", "fail", "blocked"]},
        "summary" => %{"type" => "string", "description" => "One or two sentences."},
        "steps" => %{"type" => "array", "items" => @step_schema, "description" => "Each step you checked, with its result."},
        "findings" => %{
          "type" => "array",
          "items" => @finding_schema,
          "description" => "Required for fail: one actionable defect per entry, with the step, the viewport, what you expected, what happened and the evidence."
        },
        "reason" => %{"type" => "string", "description" => "Required for blocked: why the change could not be tested."},
        "needs_person" => %{"type" => "boolean", "description" => "Only a person can hand over what the block needs (a secret, an account, a real device)."},
        "needs_dev_server" => %{"type" => "boolean", "description" => "The project's own server or database was not running for the pass."},
        "covered_by" => %{"type" => "string", "description" => "The identifier of an open ticket that already tracks the missing QA tool."},
        "scope" => %{"type" => "string", "enum" => ["none"], "description" => "none: a macOS pass with nothing to judge on screen."}
      }
    }
  }

  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc "The `qa_verdict` tool's spec, as the QA agent's tool list carries it."
  @spec tool_spec() :: map()
  def tool_spec, do: @tool_spec

  @doc "The tool's argument names."
  @spec tool_arguments() :: [String.t()]
  def tool_arguments, do: Map.keys(@tool_spec["inputSchema"]["properties"])

  @doc """
  The `qa_verdict` tool's call: reads `args` as a verdict and sends it to `sink`, the QA process
  (`{:qa_verdict, result}`), which takes the last one the session recorded. A verdict it cannot
  read comes back as the error, so the agent fixes it in the same turn.
  """
  @spec record(map(), pid() | nil) :: {:ok, map()} | {:error, term()}
  def record(args, sink) when is_pid(sink) do
    case from_map(args) do
      {:ok, result} ->
        send(sink, {:qa_verdict, result})

        {:ok,
         %{
           "recorded" => true,
           "verdict" => Atom.to_string(result.verdict),
           "next" => "Symphony recorded the verdict. Stop every process you started, then end your turn."
         }}

      {:error, reason} ->
        {:error, {:invalid_qa_verdict, reason}}
    end
  end

  def record(_args, _sink), do: {:error, :qa_verdict_unavailable}

  @doc "Reads a decoded verdict object into the QA agent's result."
  @spec from_map(term()) :: {:ok, map()} | {:error, term()}
  def from_map(decoded) when is_map(decoded) do
    with {:ok, verdict} <- coerce_verdict(Map.get(decoded, "verdict")),
         {:ok, steps} <- coerce_steps(Map.get(decoded, "steps")),
         {:ok, details} <- coerce_findings(Map.get(decoded, "findings")),
         findings = Enum.map(details, & &1.line),
         reason = trimmed(Map.get(decoded, "reason")),
         :ok <- validate_verdict(verdict, steps, findings, reason) do
      {:ok,
       %{verdict: verdict, summary: trimmed(Map.get(decoded, "summary")) || "", steps: steps, findings: findings, finding_details: details}
       |> put_if(:reason, reason, reason)
       |> put_if(:needs_person, true, flag?(Map.get(decoded, "needs_person")))
       |> put_if(:needs_dev_server, true, flag?(Map.get(decoded, "needs_dev_server")))
       |> put_if(:scope, :none, scope_none?(Map.get(decoded, "scope")))
       |> put_covered_by(Map.get(decoded, "covered_by"))}
    end
  end

  def from_map(_decoded), do: {:error, :not_a_json_object}

  @doc "What was wrong with a verdict, in a sentence the agent can act on."
  @spec describe_error(term()) :: String.t()
  def describe_error(:empty_response), do: "the answer was empty."
  def describe_error(:no_verdict_object), do: "the answer had no qa_verdict call and no JSON verdict object."
  def describe_error(:not_a_json_object), do: "the verdict must be a JSON object."
  def describe_error(:invalid_verdict), do: "`verdict` must be one of pass, fail or blocked."
  def describe_error(:invalid_steps), do: "each step must be an object with a non-empty `name` and a `status` of pass, fail, blocked, skipped or unprovable."
  def describe_error(:invalid_findings), do: "`findings` must be a list of findings."
  def describe_error(:invalid_finding), do: "each finding must be a sentence, or an object with a `summary` or the `actual` result."
  def describe_error(:missing_fail_findings), do: "a fail needs at least one finding or failing step."
  def describe_error(:missing_blocked_reason), do: "a blocked verdict needs a non-empty `reason`."
  def describe_error(reason), do: "#{inspect(reason)}."

  defp coerce_verdict(verdict) do
    case Map.fetch(@verdict_words, word(verdict)) do
      {:ok, verdict} -> {:ok, verdict}
      :error -> {:error, :invalid_verdict}
    end
  end

  defp word(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp word(_value), do: nil

  defp coerce_steps(nil), do: {:ok, []}
  defp coerce_steps(step) when is_map(step), do: coerce_steps([step])

  defp coerce_steps(steps) when is_list(steps) do
    steps
    |> Enum.map(&coerce_step/1)
    |> collect(:invalid_steps)
  end

  defp coerce_steps(_steps), do: {:error, :invalid_steps}

  defp coerce_step(%{"name" => name} = step) when is_binary(name) do
    with name when name != "" <- String.trim(name),
         {:ok, status} <- Map.fetch(@step_statuses, word(Map.get(step, "status"))) do
      coerced =
        %{name: name, status: status, details: trimmed(Map.get(step, "details")) || "", evidence: step |> Map.get("evidence") |> List.wrap() |> string_list()}
        |> put_if(:checklist, true, Map.get(step, "checklist") == true)
        |> put_trimmed(:gap, Map.get(step, "gap"))
        |> put_trimmed(:defect, Map.get(step, "defect"))

      case step |> Map.get("blocked_by") |> List.wrap() |> string_list() do
        [] -> {:ok, coerced}
        blocked_by -> {:ok, Map.put(coerced, :blocked_by, blocked_by)}
      end
    else
      _invalid -> :error
    end
  end

  defp coerce_step(_step), do: :error

  defp coerce_findings(nil), do: {:ok, []}
  defp coerce_findings(finding) when is_map(finding) or is_binary(finding), do: coerce_findings([finding])

  defp coerce_findings(findings) when is_list(findings) do
    findings
    |> Enum.map(&coerce_finding/1)
    |> collect(:invalid_finding)
    |> case do
      {:ok, findings} -> {:ok, Enum.reject(findings, &is_nil(&1.line))}
      error -> error
    end
  end

  defp coerce_findings(_findings), do: {:error, :invalid_findings}

  defp coerce_finding(finding) when is_binary(finding), do: {:ok, %{line: trimmed(finding), step: nil, viewport: nil, evidence: []}}

  defp coerce_finding(finding) when is_map(finding) do
    summary = trimmed(Map.get(finding, "summary"))
    actual = trimmed(Map.get(finding, "actual"))

    if summary || actual do
      {:ok,
       %{
         line: finding_line(finding, summary, actual),
         step: trimmed(Map.get(finding, "step")),
         viewport: trimmed(Map.get(finding, "viewport")),
         evidence: evidence(finding)
       }}
    else
      :error
    end
  end

  defp coerce_finding(_finding), do: :error

  # One line per finding, for the report's `### Findings` and the rework run's prompt:
  # `Step 2 at 1400×900 pt: The header still says Choose a model. Expected: the model's name.
  # Actual: "Choose a model". Evidence: <url>.`
  defp finding_line(finding, summary, actual) do
    location =
      case {trimmed(Map.get(finding, "step")), trimmed(Map.get(finding, "viewport"))} do
        {nil, nil} -> nil
        {step, nil} -> "#{step}:"
        {nil, viewport} -> "At #{viewport}:"
        {step, viewport} -> "#{step} at #{viewport}:"
      end

    [
      location,
      summary && sentence(summary),
      labelled("Expected", trimmed(Map.get(finding, "expected"))),
      labelled("Actual", actual),
      labelled("Evidence", finding |> evidence() |> join_list())
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp evidence(finding), do: finding |> Map.get("evidence") |> List.wrap() |> string_list()

  defp labelled(_label, nil), do: nil
  defp labelled(label, text), do: "#{label}: #{sentence(text)}"

  defp join_list([]), do: nil
  defp join_list(items), do: Enum.join(items, ", ")

  defp sentence(text), do: if(String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> ".")

  defp collect(results, error) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, item}, {:ok, acc} -> {:cont, {:ok, [item | acc]}}
      :error, _acc -> {:halt, {:error, error}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp validate_verdict(:fail, steps, findings, _reason) do
    if findings != [] or Enum.any?(steps, &(&1.status == "fail")), do: :ok, else: {:error, :missing_fail_findings}
  end

  defp validate_verdict(:blocked, _steps, _findings, nil), do: {:error, :missing_blocked_reason}
  defp validate_verdict(_verdict, _steps, _findings, _reason), do: :ok

  defp flag?(true), do: true
  defp flag?(value), do: word(value) == "true"

  defp scope_none?(scope), do: word(scope) == "none"

  # The open ticket the agent says already tracks the missing QA tool; anything that is not a
  # ticket identifier is dropped, so self-heal files its own fix ticket as before.
  defp put_covered_by(result, covered_by) when is_binary(covered_by) do
    identifier = String.trim(covered_by)
    put_if(result, :covered_by, String.upcase(identifier), identifier =~ @identifier_pattern)
  end

  defp put_covered_by(result, _covered_by), do: result

  defp put_if(map, _key, _value, truthy) when truthy in [nil, false], do: map
  defp put_if(map, key, value, _truthy), do: Map.put(map, key, value)

  defp put_trimmed(map, key, value) do
    case trimmed(value) do
      nil -> map
      trimmed -> Map.put(map, key, trimmed)
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_value), do: nil

  defp string_list(values) when is_list(values), do: values |> Enum.map(&trimmed/1) |> Enum.reject(&is_nil/1)
end
