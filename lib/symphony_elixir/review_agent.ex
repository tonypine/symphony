defmodule SymphonyElixir.ReviewAgent do
  @moduledoc """
  Runs a configured reviewer agent against the committed diff and parses its verdict.
  """

  require Logger

  alias SymphonyElixir.{AgentLabels, Config, PromptSafety, SSH}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ReviewAgent.Context

  @max_diff_prompt_bytes 120_000
  @self_check_max_iterations 4
  @last_resort_comparison_base "origin/main"
  @agent_message_methods [
    "item/agentMessage/delta",
    "codex/event/agent_message_delta",
    "codex/event/agent_message_content_delta"
  ]

  @type verdict :: :approve | :request_changes | :block
  @type finding :: %{
          required(:summary) => String.t(),
          required(:file) => String.t(),
          required(:line_range) => {pos_integer(), pos_integer()},
          required(:quoted_snippet) => String.t(),
          required(:suggested_fix) => String.t()
        }
  @type result :: %{
          required(:verdict) => verdict(),
          required(:comments) => [String.t()],
          optional(:findings) => [finding()],
          optional(:reason) => String.t(),
          optional(:source) => map()
        }

  @spec enabled?(Schema.ReviewAgent.t() | nil) :: boolean()
  def enabled?(%Schema.ReviewAgent{enabled: true}), do: true
  def enabled?(_config), do: false

  @doc """
  Returns true when the configured `run_on` mode excludes this run from the
  pre-push reviewer. Under `first_push`, follow-up runs on an existing PR are
  skipped: explicit PR dispatches (`prompt_mode: :pr`) and rework runs carrying
  reviewer comments, a CI failure, or a PR conflict in the run options.
  """
  @spec skip_for_run?(Schema.ReviewAgent.t() | map() | nil, keyword()) :: boolean()
  def skip_for_run?(%{run_on: "first_push"}, opts) when is_list(opts) do
    pr_prompt_mode?(opts) or follow_up_context?(opts)
  end

  def skip_for_run?(_config, _opts), do: false

  defp pr_prompt_mode?(opts), do: Keyword.get(opts, :prompt_mode, :issue) in [:pr, "pr"]

  defp follow_up_context?(opts) do
    reviewer_comments = Keyword.get(opts, :reviewer_comments)

    (is_list(reviewer_comments) and reviewer_comments != []) or
      not is_nil(Keyword.get(opts, :ci_failure)) or
      not is_nil(Keyword.get(opts, :pr_conflict))
  end

  @spec evaluate(Issue.t(), Path.t(), Schema.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def evaluate(%Issue{} = issue, workspace, %Schema{} = settings, opts \\ []) when is_binary(workspace) do
    config = settings.review_agent

    with true <- enabled?(config),
         {:ok, source} <- source_material(issue, workspace, settings, opts),
         {:ok, grounded_verdict} <- run_reviewer_agent(issue, workspace, settings, source, opts) do
      finalize_verdict(grounded_verdict, source)
    else
      false -> {:ok, %{verdict: :approve, comments: [], reason: "review_agent disabled"}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse_response(String.t() | nil) :: {:ok, result()} | {:error, term()}
  def parse_response(nil), do: {:error, {:malformed_review_agent_response, :empty_response}}
  def parse_response(""), do: {:error, {:malformed_review_agent_response, :empty_response}}

  def parse_response(text) when is_binary(text) do
    with :ok <- reject_runtime_error_response(text),
         {:ok, json} <- isolate_json_object(text),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, verdict} <- coerce_verdict(Map.get(decoded, "verdict")),
         {:ok, comments} <- coerce_comments(Map.get(decoded, "comments")),
         {:ok, findings} <- coerce_findings(Map.get(decoded, "findings")),
         {:ok, reason} <- coerce_reason(Map.get(decoded, "reason"), verdict),
         {:ok, result} <-
           validate_result(%{verdict: verdict, comments: comments, findings: findings, reason: reason}) do
      {:ok, compact_result(result)}
    else
      {:error, {:review_agent_runtime_error, _raw} = reason} -> {:error, reason}
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:malformed_review_agent_response, {:invalid_json, reason}}}
      {:error, reason} -> {:error, {:malformed_review_agent_response, reason}}
    end
  end

  @doc false
  @spec validate_findings(result(), map()) :: {:ok, result()} | {:error, term()}
  def validate_findings(%{verdict: verdict} = result, source) when verdict in [:block, :request_changes] and is_map(source) do
    findings = Map.get(result, :findings, [])

    findings
    |> Enum.map(&validate_finding(&1, source))
    |> split_valid_findings()
    |> case do
      {[], failures} ->
        payload = %{verdict: verdict, failures: failures, comments: Map.get(result, :comments, [])}
        {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, payload}}}

      {valid_findings, _failures} ->
        {:ok, result |> Map.put(:findings, valid_findings) |> put_grounded_comments()}
    end
  end

  def validate_findings(result, _source), do: {:ok, result}

  defp validate_finding(finding, source) do
    case Context.grounding_evidence(source, finding.file, finding.line_range) do
      {:ok, evidence} -> ground_finding(finding, evidence)
      {:error, reason} -> {:error, %{finding: finding, reason: reason}}
    end
  end

  # The cited range is checked in every evidence source first. Otherwise the quote is
  # looked up in the whole file and the finding moves to the nearest match, so a quote
  # within 10 lines of the cited range wins over one further away.
  defp ground_finding(finding, %{path: path, cited: cited, lines: lines}) do
    cond do
      Enum.any?(cited, &snippet_matches?(finding.quoted_snippet, &1.text)) ->
        {:ok, finding}

      line_range = locate_snippet(finding.quoted_snippet, lines, finding.line_range) ->
        {:ok, %{finding | line_range: line_range}}

      cited == [] ->
        {:error, %{finding: finding, reason: {:line_range_not_found, path, finding.line_range}}}

      true ->
        {:error, %{finding: finding, reason: :quoted_snippet_not_found, evidence: hd(cited)}}
    end
  end

  defp locate_snippet(snippet, numbered_lines, {start_line, end_line}) do
    case snippet |> normalized_snippet_lines() |> Enum.map(&compact_evidence_text/1) do
      [] ->
        nil

      snippet_lines ->
        numbered_lines
        |> searchable_lines()
        |> Enum.chunk_every(length(snippet_lines), 1, :discard)
        |> Enum.filter(&window_matches?(&1, snippet_lines))
        |> Enum.map(fn [{first_line, _text} | _rest] = window -> {first_line, window |> List.last() |> elem(0)} end)
        |> Enum.min_by(&distance_from_range(&1, start_line, end_line), fn -> nil end)
    end
  end

  # Blank lines are skipped. A gap in the numbering (lines no evidence source covers)
  # breaks a match, so a relocated quote never spans lines Symphony has not seen.
  defp searchable_lines(numbered_lines) do
    numbered_lines
    |> Enum.reduce({nil, []}, fn {number, text}, {previous_number, acc} ->
      acc = if is_integer(previous_number) and number != previous_number + 1, do: [:gap | acc], else: acc

      case compact_evidence_text(text) do
        "" -> {number, acc}
        line -> {number, [{number, line} | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp window_matches?(window, snippet_lines) do
    window
    |> Enum.zip(snippet_lines)
    |> Enum.all?(fn
      {{_number, line}, snippet_line} -> String.contains?(line, snippet_line)
      {:gap, _snippet_line} -> false
    end)
  end

  defp distance_from_range({first_line, last_line}, start_line, end_line) do
    Enum.max([0, first_line - end_line, start_line - last_line])
  end

  defp split_valid_findings(results) do
    Enum.reduce(results, {[], []}, fn
      {:ok, finding}, {valid, failures} -> {[finding | valid], failures}
      {:error, failure}, {valid, failures} -> {valid, [failure | failures]}
    end)
    |> then(fn {valid, failures} -> {Enum.reverse(valid), Enum.reverse(failures)} end)
  end

  defp snippet_matches?(snippet, evidence) do
    normalized_snippet = normalize_evidence_text(snippet)
    normalized_evidence = normalize_evidence_text(evidence)
    snippet_lines = normalized_snippet_lines(snippet)
    evidence_lines = normalized_match_lines(evidence)

    normalized_snippet != "" and
      (String.contains?(normalized_evidence, normalized_snippet) or
         compact_evidence_text(normalized_evidence) == compact_evidence_text(normalized_snippet) or
         String.contains?(compact_evidence_text(normalized_evidence), compact_evidence_text(normalized_snippet)) or
         line_subsequence?(snippet_lines, evidence_lines))
  end

  defp normalize_evidence_text(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.trim()
  end

  defp normalized_snippet_lines(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n", trim: false)
    |> Enum.reject(&(reviewer_annotation_header?(&1) or diff_hunk_header?(&1) or diff_file_header?(&1)))
    |> Enum.map(&strip_diff_line_prefix/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalized_match_lines(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n", trim: false)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp reviewer_annotation_header?(line) do
    trimmed = String.trim_leading(line)
    String.starts_with?(trimmed, "#") and Regex.match?(~r/\b\S+:\d+(?:-\d+)?\b/, trimmed)
  end

  defp diff_hunk_header?(line), do: line |> String.trim_leading() |> String.starts_with?("@@")

  defp diff_file_header?(line) do
    trimmed = String.trim_leading(line)

    String.starts_with?(trimmed, "diff --git ") or
      Regex.match?(~r/\Aindex [0-9a-f]{7,64}\.\.[0-9a-f]{7,64}( |\z)/, trimmed) or
      Regex.match?(~r/\A(---|\+\+\+) (a\/|b\/|\/dev\/null)/, trimmed)
  end

  defp strip_diff_line_prefix(line) do
    cond do
      Regex.match?(~r/^\s*\+(?!\+\+)/, line) -> Regex.replace(~r/^(\s*)\+/, line, "\\1", global: false)
      Regex.match?(~r/^\s*-(?!--)/, line) -> Regex.replace(~r/^(\s*)-/, line, "\\1", global: false)
      true -> line
    end
  end

  defp line_subsequence?([], _evidence_lines), do: false
  defp line_subsequence?(_snippet_lines, []), do: false

  defp line_subsequence?(snippet_lines, evidence_lines) do
    do_line_subsequence?(snippet_lines, evidence_lines)
  end

  defp do_line_subsequence?([], _evidence_lines), do: true
  defp do_line_subsequence?(_snippet_lines, []), do: false

  defp do_line_subsequence?([line | remaining_snippet], [line | remaining_evidence]) do
    do_line_subsequence?(remaining_snippet, remaining_evidence)
  end

  defp do_line_subsequence?(snippet_lines, [_line | remaining_evidence]) do
    do_line_subsequence?(snippet_lines, remaining_evidence)
  end

  defp compact_evidence_text(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Advisory notes for findings whose quotes stayed unverifiable: one `[unverified]`
  line per dropped finding, or the reviewer's comments when it gave no findings.
  """
  @spec unverified_notes(map()) :: [String.t()]
  def unverified_notes(%{failures: [_failure | _rest] = failures}) do
    Enum.map(failures, fn %{finding: finding} -> "[unverified] " <> finding_comment(finding) end)
  end

  def unverified_notes(payload) when is_map(payload), do: Map.get(payload, :comments, [])

  defp put_grounded_comments(%{findings: findings} = result) when is_list(findings) do
    Map.put(result, :comments, Enum.map(findings, &finding_comment/1))
  end

  defp finding_comment(%{summary: summary, file: file, line_range: {start_line, end_line}, suggested_fix: suggested_fix}) do
    "#{summary} (#{file}:#{start_line}-#{end_line}) Suggested fix: #{suggested_fix}"
  end

  @spec approval_prompt(result()) :: String.t()
  def approval_prompt(result), do: approval_prompt(result, [])

  @spec approval_prompt(result(), keyword()) :: String.t()
  def approval_prompt(result, opts) do
    """
    Reviewer agent approved the committed diff.
    #{advisory_notes_section(result)}
    Continue the normal workflow push and PR handoff now. Use the validation evidence already
    collected for the reviewed diff. Do not stop at the reviewer-agent gate again unless code
    changes after this approval.

    #{approval_handoff_tool_guidance(Keyword.get(opts, :settings))}
    """
  end

  defp advisory_notes_section(%{advisory_notes: [_note | _rest] = notes}) do
    body =
      notes
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {note, index} -> "#{index}. #{note}" end)

    """

    The reviewer also raised the findings below, but their quoted lines could not be found in
    the diff or the changed files. They are advisory notes: do not change code for them before
    the push. Record any you judge real in the workpad Notes.

    #{body}
    """
  end

  defp advisory_notes_section(_result), do: ""

  @doc false
  @spec approval_handoff_tool_guidance(Schema.t() | map() | nil) :: String.t()
  def approval_handoff_tool_guidance(settings) do
    case configured_agent_kind(settings) do
      "claude" ->
        """
        Use Claude's Symphony MCP GitHub tools for PR handoff:
        - `mcp__symphony__github_get_pull_request`
        - `mcp__symphony__github_push_branch`
        - `mcp__symphony__github_create_pull_request`

        Use Claude's Symphony MCP Linear tools for tracker handoff:
        - attach the PR URL with `mcp__symphony__linear_attach_url` before moving the issue to review
        - update the existing workpad with `mcp__symphony__linear_update_comment`
        - do not use `mcp__symphony__linear_add_comment` for PR, CI, or completion summaries

        Do not search for these with ToolSearch or deferred-tool discovery. If the
        `mcp__symphony__github_*` tools are not visible in this session, stop and report that
        the Symphony MCP GitHub tools are unavailable. If the Linear attachment tool is not
        visible, record the gap in the workpad instead of posting a summary comment. Avoid raw
        `gh` or `git push`; do not use SSH as a fallback.
        """

      _kind ->
        """
        Use Codex's scoped Symphony GitHub tools for PR handoff:
        - `github_get_pull_request`
        - `github_push_branch`
        - `github_create_pull_request`

        Use Codex's scoped Symphony Linear tools for tracker handoff:
        - attach the PR URL with `linear_attach_url` before moving the issue to review
        - update the existing workpad with `linear_update_comment`
        - do not use `linear_add_comment` for PR, CI, or completion summaries

        If these scoped tools are not visible in this session, stop and report that the Symphony
        GitHub tools are unavailable. If the Linear attachment tool is not visible, record the gap
        in the workpad instead of posting a summary comment. Avoid raw `gh` or `git push`; do not
        use SSH as a fallback.
        """
    end
  end

  @spec request_changes_prompt(result()) :: String.t()
  def request_changes_prompt(%{comments: comments}) do
    body =
      comments
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {comment, index} -> "#{index}. #{comment}" end)

    """
    Reviewer agent requested changes.

    Address the review comments below in one additional implementation pass. Keep the same workspace and workpad, then stop before push again so Symphony can rerun reviewer approval.

    #{body}
    """
  end

  @spec block_reason(result()) :: String.t()
  def block_reason(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  def block_reason(%{comments: [comment | _]}) when is_binary(comment), do: comment
  def block_reason(_result), do: "review_agent blocked the run"

  @spec block_payload(result()) :: map()
  def block_payload(result) when is_map(result) do
    %{
      reason: block_reason(result),
      findings: Map.get(result, :findings, []),
      comments: Map.get(result, :comments, [])
    }
  end

  defp finalize_verdict(%{verdict: :block} = verdict, _source) do
    {:error, {:review_agent_blocked, block_payload(verdict)}}
  end

  defp finalize_verdict(verdict, source), do: {:ok, Map.put(verdict, :source, source)}

  defp configured_agent_kind(%Schema{agent: %{kind: kind}}), do: AgentLabels.normalize_kind(kind)
  defp configured_agent_kind(%{agent: %{kind: kind}}), do: AgentLabels.normalize_kind(kind)
  defp configured_agent_kind(%{agent: %{"kind" => kind}}), do: AgentLabels.normalize_kind(kind)
  defp configured_agent_kind(_settings), do: nil

  defp source_material(issue, workspace, _settings, opts) do
    worker_host = Keyword.get(opts, :worker_host)
    comparison_base = comparison_base(workspace, opts, worker_host)
    range_base = merge_base(workspace, comparison_base, worker_host)
    git_range = "#{range_base}..HEAD"
    git_fun = fn args -> git(workspace, args, worker_host) end

    Context.build(issue, workspace, git_range, opts, git_fun)
  end

  defp run_reviewer_agent(issue, workspace, settings, source, opts) do
    config = settings.review_agent

    with {:ok, agent_module} <- resolve_agent_module(opts, config) do
      reviewer_settings = reviewer_settings(settings, config)
      prompt = reviewer_prompt(issue, source, opts)
      message_collector = Keyword.get(opts, :review_agent_message_collector, self())
      on_message = reviewer_on_message(message_collector, Keyword.get(opts, :on_reviewer_message))

      with {:ok, session} <-
             agent_module.start_session(workspace,
               worker_host: Keyword.get(opts, :worker_host),
               settings: reviewer_settings,
               issue: issue,
               repo_key: Keyword.get(opts, :repo_key),
               run_id: Keyword.get(opts, :run_id),
               run_profile: Keyword.get(opts, :reviewer_run_profile) || Config.pre_push_review_profile(settings),
               tool_scope: :read_only,
               linear_comment_registry: Keyword.get(opts, :linear_comment_registry)
             ) do
        try do
          turn_opts =
            reviewer_turn_opts(opts, reviewer_settings, on_message, linear_comment_registry: Keyword.get(opts, :linear_comment_registry))

          with {:ok, verdict} <- run_review_turn(agent_module, session, prompt, issue, message_collector, turn_opts),
               {:ok, checked} <- self_check(agent_module, session, issue, verdict, message_collector, turn_opts) do
            ground_findings(agent_module, session, issue, checked, source, message_collector, turn_opts)
          end
        after
          agent_module.stop_session(session)
        end
      end
    end
  end

  defp reviewer_turn_opts(opts, reviewer_settings, on_message, extra) do
    [
      on_message: on_message,
      settings: reviewer_settings,
      repo_key: Keyword.get(opts, :repo_key),
      run_id: Keyword.get(opts, :run_id),
      tool_scope: :read_only,
      linear_comment_registry: Keyword.get(extra, :linear_comment_registry)
    ]
  end

  defp run_review_turn(agent_module, session, prompt, issue, message_collector, turn_opts) do
    case agent_module.run_turn(session, prompt, issue, turn_opts) do
      {:ok, result} ->
        result
        |> response_payload(message_collector)
        |> pick_review_response()
        |> classify_review_turn_result()

      {:error, reason} ->
        {:error, classify_review_turn_failure(reason)}
    end
  end

  defp classify_review_turn_result({:ok, _result} = ok), do: ok

  defp classify_review_turn_result({:error, {:malformed_review_agent_response, _reason} = reason}) do
    {:error, {:review_agent_inconclusive, reason}}
  end

  defp classify_review_turn_result({:error, reason}), do: {:error, reason}

  defp classify_review_turn_failure(reason) do
    if iteration_limit?(reason) do
      {:review_agent_inconclusive, {:max_iterations, reason}}
    else
      {:review_agent_failed, reason}
    end
  end

  defp self_check(_agent_module, _session, _issue, %{verdict: :approve} = verdict, _message_collector, _turn_opts), do: {:ok, verdict}

  defp self_check(agent_module, session, issue, %{verdict: verdict} = result, message_collector, turn_opts)
       when verdict in [:block, :request_changes] do
    prompt = self_check_prompt(result)
    turn_opts = Keyword.put(turn_opts, :max_iterations, @self_check_max_iterations)

    case run_review_turn(agent_module, session, prompt, issue, message_collector, turn_opts) do
      {:ok, %{verdict: :block} = checked} ->
        if Map.get(checked, :findings, []) == [] do
          {:error, {:review_agent_inconclusive, :self_check_retracted_all_findings}}
        else
          {:ok, checked}
        end

      {:ok, checked} ->
        {:ok, checked}

      {:error, {:review_agent_failed, reason}} ->
        if self_check_iteration_limit?(reason) do
          {:error, {:review_agent_inconclusive, {:self_check_max_iterations, reason}}}
        else
          {:error, {:review_agent_failed, reason}}
        end

      {:error, {:review_agent_inconclusive, {:max_iterations, reason}}} ->
        {:error, {:review_agent_inconclusive, {:self_check_max_iterations, reason}}}

      {:error, {:review_agent_inconclusive, _reason} = reason} ->
        {:error, reason}
    end
  end

  # When no finding can be grounded, the same session gets one turn to re-quote them
  # against the text actually at the cited lines. If that turn fails, the original
  # unverifiable findings stand.
  defp ground_findings(agent_module, session, issue, result, source, message_collector, turn_opts) do
    case validate_findings(result, source) do
      {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, %{failures: [_failure | _rest]} = payload}}} ->
        requote(agent_module, session, issue, {result, payload}, source, message_collector, turn_opts)

      other ->
        other
    end
  end

  defp requote(agent_module, session, issue, {result, payload}, source, message_collector, turn_opts) do
    prompt = requote_prompt(result, payload)
    turn_opts = Keyword.put(turn_opts, :max_iterations, @self_check_max_iterations)

    case run_review_turn(agent_module, session, prompt, issue, message_collector, turn_opts) do
      {:ok, requoted} ->
        validate_findings(requoted, source)

      {:error, reason} ->
        Logger.info("Reviewer agent re-quote turn failed for #{issue.identifier || issue.id} reason=#{inspect(reason)}")
        {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, payload}}}
    end
  end

  defp requote_prompt(result, %{failures: failures}) do
    """
    Symphony could not find the quoted snippet of these findings in the diff or the changed files:

    #{Enum.map_join(failures, "\n\n", &requote_failure/1)}

    For each finding, fix `quoted_snippet` and `line_range` so the snippet is copied exactly from the cited lines, or remove the finding from `findings` if it does not hold. Return the corrected JSON object.

    Previous JSON:
    #{Jason.encode!(review_json(result))}
    """
  end

  defp requote_failure(%{finding: %{file: file, line_range: {start_line, end_line}} = finding} = failure) do
    Enum.join(
      [
        "- #{file}:#{start_line}-#{end_line}: #{finding.summary}",
        "  Quoted snippet:",
        indent_block(finding.quoted_snippet),
        "  Text at the cited lines:",
        indent_block(cited_text(failure))
      ],
      "\n"
    )
  end

  defp cited_text(%{evidence: %{text: text}}), do: text
  defp cited_text(%{reason: {:file_not_in_review_context, _path}}), do: "(file is not in the diff or the review context)"
  defp cited_text(_failure), do: "(no lines at this range in the diff or the changed file)"

  defp indent_block(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  defp self_check_prompt(result) do
    """
    For each finding, paste the exact lines from the diff or file that prove it (use the read-only tools if necessary). If you cannot paste the lines, retract the finding by removing it from `findings`. Return the corrected JSON object.

    Previous JSON:
    #{Jason.encode!(review_json(result))}
    """
  end

  defp review_json(result) do
    result
    |> Map.take([:verdict, :findings, :reason])
    |> Map.update!(:verdict, &Atom.to_string/1)
    |> Map.update(:findings, [], fn findings ->
      Enum.map(findings, fn finding -> %{finding | line_range: Tuple.to_list(finding.line_range)} end)
    end)
    |> maybe_put_comments(result)
  end

  defp maybe_put_comments(json, %{comments: comments}) when is_list(comments) and comments != [], do: Map.put(json, :comments, comments)
  defp maybe_put_comments(json, _result), do: json

  defp self_check_iteration_limit?(reason) do
    iteration_limit?(reason)
  end

  defp iteration_limit?(reason) do
    reason
    |> inspect()
    |> String.downcase()
    |> then(&(String.contains?(&1, "max_iterations") or String.contains?(&1, "maximum iterations")))
  end

  defp reviewer_settings(%Schema{} = settings, %Schema.ReviewAgent{} = config) do
    %{settings | agent: %{settings.agent | kind: config.kind, command: config.command}}
  end

  defp resolve_agent_module(opts, %Schema.ReviewAgent{} = config) do
    case Keyword.get(opts, :review_agent_module) do
      nil -> agent_module(config.kind)
      module when is_atom(module) -> {:ok, module}
    end
  end

  defp agent_module("codex"), do: {:ok, SymphonyElixir.Codex.AppServer}
  defp agent_module("claude"), do: {:ok, SymphonyElixir.ClaudeCode.AppServer}
  defp agent_module(other), do: {:error, {:unsupported_review_agent_kind, other}}

  defp reviewer_prompt(issue, source, opts) do
    workflow_prompt =
      opts
      |> Keyword.get(:repo_key)
      |> Config.workflow_prompt()

    """
    You are the reviewer agent in an executor + reviewer Symphony run.

    Review the executor's committed diff for this Linear issue. You may inspect files and use read-only scoped Linear/GitHub tools, but you must not modify files, write Linear/GitHub data, push, or open a PR.

    Review the diff by reading it. Do not run the test suite, `make all`, coverage or static analysis such as Dialyzer, even when the workflow below asks the executor to: CI runs them after the push.

    Issue:
    #{present_issue(issue)}

    Workflow review criteria:
    #{workflow_prompt}

    Diff context:
    #{truncate(source.diff, @max_diff_prompt_bytes)}

    Discipline:
    - Do not cite a function, file, or line you have not read. Use the read-only tools to verify before citing.
    - Every finding must include `file`, `line_range`, and `quoted_snippet` that you have personally inspected.
    - If a finding cannot be backed by a quoted snippet from the diff or workspace, omit it.
    - If you are uncertain, prefer `approve` or `request_changes` (with concrete diffs) over `block`.
    - Do not fabricate function or module names. If you cannot grep for the symbol you intend to cite, do not cite it.

    Return ONLY one JSON object in this shape:
    {
      "verdict": "approve" | "request_changes" | "block",
      "findings": [
        {
          "summary": "<concise actionable summary>",
          "file": "lib/...",
          "line_range": [1, 2],
          "quoted_snippet": "<exact line or lines from the diff or workspace>",
          "suggested_fix": "<concrete fix>"
        }
      ],
      "reason": "<required for block>"
    }
    """
  end

  defp present_issue(%Issue{} = issue) do
    """
    Identifier: #{issue.identifier}
    Title: #{PromptSafety.linear_issue_title(issue.title)}
    Description:
    #{PromptSafety.linear_issue_body(issue.description)}
    """
  end

  defp reviewer_on_message(collector, forward) do
    fn message ->
      collect_message(collector, message)
      if is_function(forward, 1), do: forward.(message)
      :ok
    end
  end

  defp collect_message(collector, message) when is_pid(collector) do
    send(collector, {:review_agent_message, self(), message})
  end

  defp collect_message(_collector, _message), do: :ok

  @doc false
  # Agent text candidates for a finished turn, most specific first: the turn result,
  # the streamed agent messages, then both joined. Shared with `QaAgent`.
  @spec response_candidates(term(), [term()]) :: [String.t()]
  def response_candidates(result, messages) when is_list(messages) do
    %{primary: primary, messages: message_output, combined: combined} = response_texts(result, messages)

    [primary, message_output, combined]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
  end

  @doc false
  # Balanced `{...}` substrings of `text`, after dropping Markdown code fences. Shared with `QaAgent`.
  @spec json_object_candidates(String.t()) :: [String.t()]
  def json_object_candidates(text) when is_binary(text) do
    text
    |> String.replace(~r/```(?:json)?\s*/i, "")
    |> String.replace("```", "")
    |> extract_objects()
  end

  defp response_payload(result, collector) do
    response_texts(result, drain_collected_messages(collector, []))
  end

  defp response_texts(result, messages) do
    primary = result |> response_text() |> String.trim()
    message_output = messages |> Enum.map_join("", &message_text/1) |> String.trim()

    combined =
      [primary, message_output]
      |> Enum.join("\n")
      |> String.trim()

    %{primary: primary, messages: message_output, combined: combined}
  end

  defp pick_review_response(%{primary: primary, messages: messages, combined: combined}) do
    [primary, messages, combined]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
    |> parse_first_review_response(nil)
  end

  defp parse_first_review_response([], nil), do: parse_response("")
  defp parse_first_review_response([], fallback), do: fallback

  defp parse_first_review_response([text | rest], fallback) do
    case parse_response(text) do
      {:ok, _result} = ok -> ok
      {:error, reason} -> parse_first_review_response(rest, preferred_parse_error(fallback, {:error, reason}))
    end
  end

  defp preferred_parse_error(nil, error), do: error
  defp preferred_parse_error({:error, {:review_agent_runtime_error, _raw}} = fallback, _error), do: fallback
  defp preferred_parse_error(_fallback, {:error, {:review_agent_runtime_error, _raw}} = error), do: error
  defp preferred_parse_error(fallback, _error), do: fallback

  defp drain_collected_messages(collector, acc) when is_pid(collector) do
    receive do
      {:review_agent_message, _pid, message} -> drain_collected_messages(collector, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_collected_messages(_collector, _acc), do: []

  defp response_text(result) when is_map(result) do
    Enum.find_value([:result, "result", :text, "text", :output, "output"], fn key ->
      case Map.get(result, key) do
        value when is_binary(value) -> value
        _value -> nil
      end
    end) || ""
  end

  defp response_text(value) when is_binary(value), do: value
  defp response_text(_value), do: ""

  defp message_text({:agent_text, text}) when is_binary(text), do: text

  defp message_text(%{event: :agent_text, payload: %{params: %{msg: %{content: text}}}}) when is_binary(text), do: text
  defp message_text(%{event: :agent_text, payload: %{"params" => %{"msg" => %{"content" => text}}}}) when is_binary(text), do: text
  defp message_text(%{payload: payload}) when is_map(payload), do: payload_text(payload)
  defp message_text(%{"payload" => payload}) when is_map(payload), do: payload_text(payload)
  defp message_text(message) when is_map(message), do: payload_text(message)
  defp message_text(_message), do: ""

  defp payload_text(%{"method" => method, "params" => params}) when method in @agent_message_methods and is_map(params),
    do: agent_message_params_text(params)

  defp payload_text(%{"result" => text}) when is_binary(text), do: text
  defp payload_text(_payload), do: ""

  defp agent_message_params_text(%{"delta" => text}) when is_binary(text), do: text
  defp agent_message_params_text(%{"msg" => msg}) when is_map(msg), do: agent_message_msg_text(msg)
  defp agent_message_params_text(_params), do: ""

  defp agent_message_msg_text(%{"content" => text}) when is_binary(text), do: text
  defp agent_message_msg_text(%{"payload" => %{"delta" => text}}) when is_binary(text), do: text
  defp agent_message_msg_text(_msg), do: ""

  defp comparison_base(workspace, opts, worker_host) do
    case configured_comparison_base(Keyword.get(opts, :base_branch)) do
      nil -> origin_head_comparison_base(workspace, worker_host)
      base -> base
    end
  end

  defp configured_comparison_base(base_branch) when is_binary(base_branch) do
    case String.trim(base_branch) do
      "" -> nil
      "origin/" <> branch -> normalize_branch_ref(branch)
      "refs/heads/" <> branch -> normalize_branch_ref(branch)
      branch -> normalize_branch_ref(branch)
    end
  end

  defp configured_comparison_base(_base_branch), do: nil

  defp normalize_branch_ref(branch) do
    case String.trim(branch) do
      "" -> nil
      trimmed -> "origin/#{trimmed}"
    end
  end

  defp origin_head_comparison_base(workspace, worker_host) do
    case git(workspace, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], worker_host) do
      {:ok, output} ->
        output |> normalize_origin_head_ref() |> blank_fallback(@last_resort_comparison_base)

      {:error, reason} ->
        Logger.info("ReviewAgent origin/HEAD unresolved, falling back to #{@last_resort_comparison_base} reason=#{inspect(reason)}")

        @last_resort_comparison_base
    end
  end

  defp normalize_origin_head_ref(output) do
    output
    |> String.trim()
    |> String.replace_prefix("refs/remotes/", "")
  end

  defp merge_base(workspace, comparison_base, worker_host) do
    case git(workspace, ["merge-base", comparison_base, "HEAD"], worker_host) do
      {:ok, output} ->
        output |> String.trim() |> blank_fallback(comparison_base)

      {:error, reason} ->
        Logger.info("ReviewAgent merge-base unresolved, falling back to #{comparison_base} reason=#{inspect(reason)}")

        comparison_base
    end
  end

  defp git(workspace, args, nil) do
    case SymphonyElixir.Workspace.safe_git(["-C", workspace | args]) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  end

  defp git(workspace, args, worker_host) when is_binary(worker_host) do
    command =
      (["git", "-C", workspace] ++ args)
      |> Enum.map_join(" ", &shell_escape/1)

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:git_failed, worker_host, args, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_runtime_error_response(text) do
    text
    |> String.trim()
    |> runtime_error_response()
  end

  defp runtime_error_response("{:error," <> _rest = text), do: {:error, {:review_agent_runtime_error, text}}
  defp runtime_error_response(_text), do: :ok

  defp isolate_json_object(text) do
    text
    |> String.replace(~r/```(?:json)?\s*/i, "")
    |> String.replace("```", "")
    |> String.trim()
    |> case do
      "" -> {:error, :empty_response}
      cleaned -> select_review_json_object(cleaned)
    end
  end

  defp select_review_json_object(text) do
    candidates = extract_objects(text)

    cond do
      candidates == [] ->
        {:error, :no_json_object}

      candidate = Enum.find(candidates, &review_json_object?/1) ->
        {:ok, candidate}

      candidate = Enum.find(candidates, &decodable_json_object?/1) ->
        {:ok, candidate}

      true ->
        {:ok, List.first(candidates)}
    end
  end

  defp review_json_object?(candidate) do
    case Jason.decode(candidate) do
      {:ok, %{"verdict" => _verdict}} -> true
      _other -> false
    end
  end

  defp decodable_json_object?(candidate) do
    match?({:ok, _decoded}, Jason.decode(candidate))
  end

  defp extract_objects(text), do: extract_objects(text, 0, [])

  defp extract_objects(text, offset, acc) when offset >= byte_size(text), do: Enum.reverse(acc)

  defp extract_objects(text, offset, acc) do
    remaining = byte_size(text) - offset

    case text |> binary_part(offset, remaining) |> :binary.match("{") do
      :nomatch ->
        Enum.reverse(acc)

      {relative_start, _len} ->
        start = offset + relative_start

        case scan_object(text, start, start, 0, false, false) do
          {candidate, end_index} -> extract_objects(text, end_index + 1, [candidate | acc])
          nil -> extract_objects(text, start + 1, acc)
        end
    end
  end

  defp scan_object(text, _start, index, _depth, _in_string?, _escape?) when index >= byte_size(text), do: nil

  defp scan_object(text, start, index, depth, in_string?, escape?) do
    text
    |> :binary.at(index)
    |> scan_object_byte(text, start, index, depth, in_string?, escape?)
  end

  defp scan_object_byte(?\\, text, start, index, depth, true, escape?),
    do: scan_object(text, start, index + 1, depth, true, !escape?)

  defp scan_object_byte(?", text, start, index, depth, true, true),
    do: scan_object(text, start, index + 1, depth, true, false)

  defp scan_object_byte(?", text, start, index, depth, true, false),
    do: scan_object(text, start, index + 1, depth, false, false)

  defp scan_object_byte(?", text, start, index, depth, false, _escape?),
    do: scan_object(text, start, index + 1, depth, true, false)

  defp scan_object_byte(?{, text, start, index, depth, false, _escape?),
    do: scan_object(text, start, index + 1, depth + 1, false, false)

  defp scan_object_byte(?}, text, start, index, 1, false, _escape?),
    do: {:binary.part(text, start, index - start + 1), index}

  defp scan_object_byte(?}, text, start, index, depth, false, _escape?),
    do: scan_object(text, start, index + 1, depth - 1, false, false)

  defp scan_object_byte(_byte, text, start, index, depth, in_string?, _escape?),
    do: scan_object(text, start, index + 1, depth, in_string?, false)

  defp coerce_verdict(verdict) when verdict in ["approve", "request_changes", "block"] do
    {:ok, String.to_existing_atom(verdict)}
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
       %{
         summary: summary,
         file: file,
         line_range: line_range,
         quoted_snippet: quoted_snippet,
         suggested_fix: suggested_fix
       }}
    end
  end

  defp coerce_finding(_finding), do: {:error, :invalid_finding}

  defp required_string(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_string(_value, error), do: {:error, error}

  defp coerce_line_range([start_line, end_line]) do
    with {:ok, start_line} <- coerce_positive_integer(start_line),
         {:ok, end_line} <- coerce_positive_integer(end_line),
         true <- start_line <= end_line do
      {:ok, {start_line, end_line}}
    else
      _other -> {:error, :invalid_finding_line_range}
    end
  end

  defp coerce_line_range(_line_range), do: {:error, :invalid_finding_line_range}

  defp coerce_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
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

  defp truncate(text, max_bytes) when is_binary(text) and byte_size(text) > max_bytes do
    binary_part(text, 0, max_bytes) <> "\n[... truncated by Symphony review_agent ...]"
  end

  defp truncate(text, _max_bytes), do: text

  defp blank_fallback(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      _ -> value
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
