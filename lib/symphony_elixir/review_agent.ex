defmodule SymphonyElixir.ReviewAgent do
  @moduledoc """
  Runs Code Review's reviewer agent (`SymphonyElixir.CodeReview`) against the pull request's diff
  and parses its verdict.
  """

  require Logger

  alias SymphonyElixir.{AgentTmpDir, Config, GitConfigCommands, ProjectGuides, PromptSafety, SSH}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Decisions
  alias SymphonyElixir.EscalationRules
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ReviewAgent.{Context, Verdict}

  @max_diff_prompt_bytes 120_000
  @self_check_max_iterations 4
  @last_resort_comparison_base "origin/main"
  @unplaced_prefix "[could not be placed] "
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
          required(:suggested_fix) => String.t(),
          optional(:decision) => String.t()
        }
  @type result :: %{
          required(:verdict) => verdict(),
          required(:comments) => [String.t()],
          optional(:findings) => [finding()],
          optional(:reason) => String.t(),
          optional(:source) => map(),
          optional(:escalation_reasons) => [EscalationRules.reason()]
        }

  @spec enabled?(Schema.ReviewAgent.t() | nil) :: boolean()
  def enabled?(%Schema.ReviewAgent{enabled: true}), do: true
  def enabled?(_config), do: false

  @doc """
  Runs the reviewer on the committed diff in `workspace` and returns its grounded verdict.

  `opts[:escalation_rules]` is a function of the diff context the reviewer judges
  (`ReviewAgent.Context`) to the escalation rules' reasons (`EscalationRules.check/4`). It runs once
  the diff context is built and before the reviewer starts: the risk rules' findings go in the
  reviewer's instructions, so its one review weighs them, and the reasons come back on the verdict
  as `escalation_reasons`. Without it, the instructions say nothing about rules.

  `opts[:on_message]` is the run's own event hook (`AgentRunner.codex_message_handler/2`): every
  event the reviewer streams reaches it too, so the orchestrator sees the review's session and
  activity as it sees an implementation run's.
  """
  @spec evaluate(Issue.t(), Path.t(), Schema.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def evaluate(%Issue{} = issue, workspace, %Schema{} = settings, opts \\ []) when is_binary(workspace) do
    config = settings.review_agent

    with true <- enabled?(config),
         {:ok, source} <- source_material(issue, workspace, settings, opts),
         reasons = escalation_reasons(source, opts),
         {:ok, grounded_verdict} <- run_reviewer_agent(issue, workspace, settings, source, reasons, opts) do
      finalize_verdict(grounded_verdict, source, reasons)
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
         {:ok, result} <- Verdict.from_map(decoded) do
      {:ok, result}
    else
      {:error, {:review_agent_runtime_error, _raw} = reason} -> {:error, reason}
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:malformed_review_agent_response, {:invalid_json, reason}}}
      {:error, reason} -> {:error, {:malformed_review_agent_response, reason}}
    end
  end

  @doc """
  Grounds a change request's or a block's findings in the reviewed head. A finding whose quote is
  found stays a finding (moved to the lines it quotes). One whose quote cannot be placed is kept as
  an unanchored comment marked as such, and the verdict stands. The verdict is unverifiable
  (`review_agent_unverifiable`) only when it requests changes and none of its findings can be
  placed (or it gave none).
  """
  @spec validate_findings(result(), map()) :: {:ok, result()} | {:error, term()}
  def validate_findings(%{verdict: verdict} = result, source) when verdict in [:block, :request_changes] and is_map(source) do
    findings = Map.get(result, :findings, [])

    findings
    |> Enum.map(&validate_finding(&1, source))
    |> split_valid_findings()
    |> case do
      {[], failures} when verdict == :request_changes ->
        payload = %{verdict: verdict, failures: failures, comments: Map.get(result, :comments, [])}
        {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, payload}}}

      {valid_findings, failures} ->
        {:ok, result |> Map.put(:findings, valid_findings) |> put_grounded_comments(failures)}
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
  Keeps a review from requesting changes against a person's recorded decision
  (`SymphonyElixir.Decisions`): a finding that names a decision recorded on the ticket
  (`"decision": "D1"`, read from its store record) is dropped from the change request. A change
  request left with no other finding approves, with the dropped findings as its comments (decision
  notes). A finding that names no recorded decision stays a finding.
  `opts[:repo_key]` names the ticket's repo.
  """
  @spec honour_decisions(result(), Issue.t(), keyword()) :: result()
  def honour_decisions(result, issue, opts \\ []) do
    case {result, issue} do
      {%{verdict: :request_changes, findings: [_finding | _rest] = findings}, %Issue{}} ->
        decided = issue |> Decisions.stored(opts) |> MapSet.new(& &1.id)
        {decision_findings, kept} = Enum.split_with(findings, &MapSet.member?(decided, Map.get(&1, :decision)))
        honoured(result, Enum.map(decision_findings, &decision_note/1), kept)

      _other ->
        result
    end
  end

  defp honoured(result, [], _kept), do: result
  defp honoured(result, notes, []), do: Map.merge(result, %{verdict: :approve, findings: [], comments: notes})
  defp honoured(result, _notes, kept), do: Map.merge(result, %{findings: kept, comments: Enum.map(kept, &finding_comment/1)})

  defp decision_note(finding), do: "Against decision #{finding.decision}, so a note, not a change request: " <> finding_comment(finding)

  # A grounded verdict's comments are its findings, then the findings that could not be placed. A
  # verdict with no findings at all keeps the reviewer's own comments.
  defp put_grounded_comments(%{findings: []} = result, []), do: result

  defp put_grounded_comments(%{findings: findings} = result, failures) do
    unplaced = Enum.map(failures, fn %{finding: finding} -> @unplaced_prefix <> finding_comment(finding) end)
    Map.put(result, :comments, Enum.map(findings, &finding_comment/1) ++ unplaced)
  end

  defp finding_comment(%{summary: summary, file: file, line_range: {start_line, end_line}, suggested_fix: suggested_fix}) do
    "#{summary} (#{file}:#{start_line}-#{end_line}) Suggested fix: #{suggested_fix}"
  end

  @doc """
  A short label for why a review stayed inconclusive (the cause in
  `{:review_agent_inconclusive, cause}`), such as `invalid_verdict`, `no_json_object` or
  `review_agent_unverifiable`, so inconclusive reviews can be counted per cause.
  """
  @spec inconclusive_cause(term()) :: String.t()
  def inconclusive_cause({:malformed_review_agent_response, {:invalid_json, _error}}), do: "invalid_json"
  def inconclusive_cause({:malformed_review_agent_response, reason}) when is_atom(reason), do: Atom.to_string(reason)
  def inconclusive_cause({cause, _details}) when is_atom(cause), do: Atom.to_string(cause)
  def inconclusive_cause(cause) when is_atom(cause), do: Atom.to_string(cause)
  def inconclusive_cause(_cause), do: "other"

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

  defp finalize_verdict(%{verdict: :block} = verdict, _source, _reasons) do
    {:error, {:review_agent_blocked, block_payload(verdict)}}
  end

  defp finalize_verdict(verdict, source, reasons), do: {:ok, Map.merge(verdict, %{source: source, escalation_reasons: reasons})}

  defp escalation_reasons(source, opts) do
    case Keyword.get(opts, :escalation_rules) do
      check when is_function(check, 1) -> check.(source)
      nil -> []
    end
  end

  defp source_material(issue, workspace, _settings, opts) do
    worker_host = Keyword.get(opts, :worker_host)
    comparison_base = comparison_base(workspace, opts, worker_host)
    range_base = merge_base(workspace, comparison_base, worker_host)
    git_range = "#{range_base}..HEAD"
    git_fun = fn args -> git(workspace, args, worker_host) end

    Context.build(issue, workspace, git_range, opts, git_fun)
  end

  defp run_reviewer_agent(issue, workspace, settings, source, reasons, opts) do
    config = settings.review_agent

    with {:ok, agent_module} <- resolve_agent_module(opts, config) do
      reviewer_settings = reviewer_settings(settings, config)
      decision_opts = [repo_key: Keyword.get(opts, :repo_key)]
      prompt = reviewer_prompt(issue, source, decision_opts, reasons)
      message_collector = Keyword.get(opts, :review_agent_message_collector, self())
      on_message = reviewer_on_message(message_collector, Keyword.get(opts, :on_message))

      with {:ok, session} <-
             agent_module.start_session(workspace,
               worker_host: Keyword.get(opts, :worker_host),
               settings: reviewer_settings,
               issue: issue,
               repo_key: Keyword.get(opts, :repo_key),
               run_id: Keyword.get(opts, :run_id),
               run_profile: Keyword.get(opts, :reviewer_run_profile) || Config.code_review_profile(settings),
               tool_scope: :read_only,
               review_verdict_sink: self(),
               linear_comment_registry: Keyword.get(opts, :linear_comment_registry),
               # The run's temp folder, which its settings already make writable.
               extra_env: AgentTmpDir.env(reviewer_settings.agent.kind, Keyword.get(opts, :agent_tmp_dir))
             ) do
        try do
          turn_opts =
            reviewer_turn_opts(opts, reviewer_settings, on_message, linear_comment_registry: Keyword.get(opts, :linear_comment_registry))

          with {:ok, verdict} <- review_or_nudge(agent_module, session, prompt, issue, message_collector, turn_opts),
               verdict = honour_decisions(verdict, issue, decision_opts),
               {:ok, checked} <- self_check(agent_module, session, issue, verdict, message_collector, turn_opts) do
            checked = honour_decisions(checked, issue, decision_opts)
            ground_findings(agent_module, session, issue, checked, source, message_collector, turn_opts)
          end
        after
          agent_module.stop_session(session)
          # A verdict recorded after the last turn's read must not reach the next review in this process.
          recorded_verdict(nil)
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
      review_verdict_sink: self(),
      linear_comment_registry: Keyword.get(extra, :linear_comment_registry)
    ]
  end

  # The verdict the reviewer recorded with the `review_verdict` tool during the turn wins, even
  # over a turn that then failed; without one, the verdict is read from the turn's text.
  defp run_review_turn(agent_module, session, prompt, issue, message_collector, turn_opts) do
    turn_result = agent_module.run_turn(session, prompt, issue, turn_opts)
    messages = drain_collected_messages(message_collector, [])

    case {recorded_verdict(nil), turn_result} do
      {%{} = verdict, _turn_result} ->
        {:ok, verdict}

      {nil, {:ok, result}} ->
        result
        |> response_texts(messages)
        |> pick_review_response()
        |> classify_review_turn_result()

      {nil, {:error, {:model_api_unreachable, _info} = reason}} ->
        {:error, reason}

      {nil, {:error, reason}} ->
        {:error, classify_review_turn_failure(reason)}
    end
  end

  # The last verdict the turn's `review_verdict` calls recorded (`Verdict.record/2`), or nil.
  defp recorded_verdict(last) do
    receive do
      {:review_verdict, verdict} -> recorded_verdict(verdict)
    after
      0 -> last
    end
  end

  # The repair turn. A long tool-using review, or a follow-up turn (self-check, re-quote), can end
  # without a verdict Symphony can read: prose, or a verdict outside the contract. The same session
  # gets one short turn with the parser's error and the contract before the run counts as
  # inconclusive, so the review it already did is kept.
  defp review_or_nudge(agent_module, session, prompt, issue, message_collector, turn_opts) do
    case run_review_turn(agent_module, session, prompt, issue, message_collector, turn_opts) do
      {:error, {:review_agent_inconclusive, {:malformed_review_agent_response, reason}}} = malformed ->
        nudge_opts = Keyword.put(turn_opts, :max_iterations, @self_check_max_iterations)

        case run_review_turn(agent_module, session, repair_prompt(reason), issue, message_collector, nudge_opts) do
          {:ok, _verdict} = ok -> ok
          {:error, {:model_api_unreachable, _info}} = unreachable -> unreachable
          {:error, _reason} -> malformed
        end

      other ->
        other
    end
  end

  defp repair_prompt(reason) do
    """
    #{ProjectGuides.output_contract_marker()}
    Symphony could not read your verdict: #{Verdict.describe_error(reason)}
    Do not review again. Record the verdict for the review you just did, with any corrections you were asked for: call the `review_verdict` tool once with it, then end your turn. The verdict has this shape:
    #{verdict_shape()}
    If the `review_verdict` tool is not available, your final message must be only this JSON object, with no prose before or after it.
    """
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

    case review_or_nudge(agent_module, session, prompt, issue, message_collector, turn_opts) do
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

      {:error, {:model_api_unreachable, _info}} = unreachable ->
        unreachable
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

    case review_or_nudge(agent_module, session, prompt, issue, message_collector, turn_opts) do
      {:ok, requoted} ->
        validate_findings(requoted, source)

      {:error, {:model_api_unreachable, _info}} = unreachable ->
        unreachable

      {:error, reason} ->
        Logger.info("Reviewer agent re-quote turn failed for #{issue.identifier || issue.id} reason=#{inspect(reason)}")
        {:error, {:review_agent_inconclusive, {:review_agent_unverifiable, payload}}}
    end
  end

  defp requote_prompt(result, %{failures: failures}) do
    """
    Symphony could not find the quoted snippet of these findings in the diff or the files at the reviewed head:

    #{Enum.map_join(failures, "\n\n", &requote_failure/1)}

    For each finding, fix `quoted_snippet` and `line_range` so the snippet is copied exactly from the cited lines, or remove the finding from `findings` if it does not hold.

    Previous JSON:
    #{Jason.encode!(review_json(result))}

    #{follow_up_json_rule()}
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
  defp cited_text(%{reason: {:file_not_in_review_context, _path}}), do: "(file does not exist at the reviewed head)"
  defp cited_text(_failure), do: "(no lines at this range in the diff or the changed file)"

  defp indent_block(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  defp self_check_prompt(result) do
    """
    For each finding, paste the exact lines from the diff or file that prove it (use the read-only tools if necessary). If you cannot paste the lines, retract the finding by removing it from `findings`.

    Previous JSON:
    #{Jason.encode!(review_json(result))}

    #{follow_up_json_rule()}
    """
  end

  # The verdict rule goes last, after the previous JSON, so a reply that explains itself
  # still ends in the verdict.
  defp follow_up_json_rule do
    """
    #{ProjectGuides.output_contract_marker()}
    Call the `review_verdict` tool once with the corrected verdict, in the same shape as the previous JSON, then end your turn. If the `review_verdict` tool is not available, your final message must be only the corrected JSON object, with no prose before or after it.\
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

  # Code Review judges the pull request's diff for bugs and code quality, and against the ticket's
  # acceptance criteria, scope and intent.
  defp reviewer_prompt(issue, source, decision_opts, reasons) do
    """
    You are the reviewer agent in Symphony's Code Review of a pull request.

    Review the pull request's committed diff for this Linear issue. You may inspect files and use read-only scoped Linear/GitHub tools, but you must not modify files, write Linear/GitHub data, push, or open a PR.

    Review the diff by reading it. Do not run the test suite, `make all`, coverage or static analysis such as Dialyzer: CI runs them after the push.

    Issue (context for what the diff is for):
    #{present_issue(issue)}
    #{decisions_rule(issue, decision_opts)}
    Review criteria. Review the code, not the ticket:
    - Correctness: bugs in the changed code, such as wrong conditions, unhandled cases, broken callers, races and resource leaks.
    - Tests: each new branch, error path and edge case the diff adds has a test that exercises it, and changed behaviour has its tests updated.
    - Error handling: errors are handled or returned, not swallowed, and failures leave no half-done state.
    - The repo's code rules: read the repo's agent instructions (`AGENTS.md`, `CLAUDE.md`) for its rules, such as required specs, style and module patterns. Narrow scope is a code rule: flag unrelated refactors, stray debug code and dead code left in the diff.

    #{ticket_judgment()}
    #{rule_findings(reasons)}
    Diff context:
    #{truncate(source.diff, @max_diff_prompt_bytes)}

    Discipline:
    - Do not cite a function, file, or line you have not read. Use the read-only tools to verify before citing.
    - Every finding must include `file`, `line_range`, and `quoted_snippet` that you have personally inspected.
    - If a finding cannot be backed by a quoted snippet from the diff or workspace, omit it.
    - If you are uncertain, prefer `approve` or `request_changes` (with concrete diffs) over `block`.
    - Do not fabricate function or module names. If you cannot grep for the symbol you intend to cite, do not cite it.

    #{ProjectGuides.output_contract_marker()}
    When the review is done, call the `review_verdict` tool once with your verdict, then end your turn. If the tool refuses the verdict, it says why: fix it and call the tool again. The verdict has this shape:
    #{verdict_shape()}
    If the `review_verdict` tool is not available, your final message must be only this JSON object, with no prose before or after it.
    """
  end

  defp verdict_shape do
    """
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
    }\
    """
  end

  defp ticket_judgment do
    "This is the pull request's Code Review, so also judge the change against the ticket: check that the diff meets each of the ticket's acceptance criteria " <>
      "and stays within its scope and intent. Request changes for an unmet criterion or for work outside the ticket, naming the criterion or the out-of-scope change."
  end

  # What the repo's risk rules found in the change, so the one review weighs it. Nothing when none
  # matched.
  defp rule_findings(reasons) do
    case EscalationRules.reviewer_brief(reasons) do
      [] ->
        ""

      lines ->
        """

        What Symphony's risk rules found in this change. They are not findings against it: weigh each one in your single judgement of the change, read the code it points at with that in mind, and say in your verdict's `reason` how it weighed:
        #{Enum.map_join(lines, "\n", &"- #{&1}")}
        """
    end
  end

  defp present_issue(%Issue{} = issue) do
    """
    Identifier: #{issue.identifier}
    Title: #{PromptSafety.linear_issue_title(issue.title)}
    Description:
    #{PromptSafety.linear_issue_body(Decisions.strip(issue.description))}
    """
  end

  # A person's answers to the ticket's decision requests are its scope: the reviewer follows them
  # and Symphony turns a finding that names one into a note (`honour_decisions/3`). They are read
  # from the ticket's store record, not from Linear.
  defp decisions_rule(%Issue{} = issue, decision_opts) do
    case issue |> Decisions.stored(decision_opts) |> Decisions.prompt_section() do
      "" ->
        ""

      section ->
        """
        #{section}
        A finding that contradicts a recorded decision is not a finding: do not request changes for work a decision put out of scope or deferred, or for code that follows what a decision chose. If you think a decision is wrong, say so in `comments` as a note and do not request changes for it. A finding you still report about a decided point must name the decision in `"decision": "D<n>"`; Symphony keeps it as a note, not a change request.
        """
    end
  end

  # The collector serves the verdict text; `forward` is the run's own handler
  # (`AgentRunner.codex_message_handler/2`), which reports the session and its activity to the
  # orchestrator as an implementation run does, so the watchdogs see the reviewer working.
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

  # On a worker, git runs through the script's `symphony_git`, with the same safe config, env and
  # filter driver overrides as host-side git, and `diff`, `log` and `show` get the options of
  # `GitConfigCommands.subcommand_args/1`, so the worker repo's diff drivers don't run either.
  defp git(workspace, args, worker_host) when is_binary(worker_host) do
    command =
      SymphonyElixir.Workspace.remote_safe_git_functions() <>
        "\nsymphony_git " <> Enum.map_join([workspace | GitConfigCommands.subcommand_args(args)], " ", &shell_escape/1)

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
