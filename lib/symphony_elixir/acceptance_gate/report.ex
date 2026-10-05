defmodule SymphonyElixir.AcceptanceGate.Report do
  @moduledoc """
  Renders and publishes the `## Symphony Acceptance Gate` Linear comment.

  Like the QA report (`SymphonyElixir.QaAgent.Report`), Symphony keeps one gate comment per
  issue and rewrites it for each PR head the gate judges. It shows the mode (and, in `enforce`
  mode, where the verdict moves the issue), the verdict and the agent's own verdict, one row per
  acceptance criterion, the overlaps with other open PRs, the scope findings, the escalation
  reasons (first, for an `escalate` verdict), the follow-ups (listed in `shadow` mode, filed in
  `enforce` mode), and the run's tokens and runtime.
  """

  alias SymphonyElixir.AcceptanceGate.FollowUps
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent.Report, as: QaReport

  @heading "## Symphony Acceptance Gate"
  @cell_limit 300

  @doc "The heading that identifies the gate comment."
  @spec heading() :: String.t()
  def heading, do: @heading

  @doc """
  Renders the comment for a gate run (`SymphonyElixir.AcceptanceGate.run/3`'s result) merged
  with `:decision`, `:sha`, `:mode`, `:runtime_seconds` and `:limit` (the inconclusive limit).
  An enforced verdict adds `:target` (`SymphonyElixir.AcceptanceGate.enforced_target/4`),
  `:fix_attempts`, `:max_fix_attempts` and `:filed_follow_ups` (`FollowUps.file/5`'s results).
  """
  @spec render(map()) :: String.t()
  def render(report) when is_map(report) do
    answer = answer(report.outcome)
    reasons = list_block("Escalation reasons", Enum.map(report.decision.reasons, &"`#{&1.rule}`: #{&1.detail}") ++ Enum.map(Map.get(answer, :escalation_reasons, []), &"agent: #{&1}"))
    escalate? = report.decision.verdict == "escalate"

    [
      @heading,
      "",
      # An escalation opens with why a person has to look.
      if(escalate?, do: reasons),
      mode_line(report),
      "",
      "**Verdict:** #{verdict_label(report)} · **Agent verdict:** #{report.decision.agent_verdict || "none (the agent didn't run)"}",
      head_line(report),
      summary_block(report.outcome, answer),
      criteria_block(rows(report.criteria, answer)),
      overlaps_block(context_overlaps(report), Map.get(answer, :overlaps, [])),
      list_block("Scope", Enum.map(Map.get(answer, :scope, []), &"#{&1.kind}: #{&1.detail}")),
      if(not escalate?, do: reasons),
      follow_ups_block(Map.get(report, :filed_follow_ups), Map.get(answer, :follow_ups, [])),
      "_Symphony rewrites this comment for each PR head the gate judges._"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  @doc """
  The criteria table's rows: one per criterion Symphony listed, with the agent's answer for its
  id (`unclear` when the agent didn't answer it). With no listed criteria, the agent's own.
  """
  @spec rows([map()], map()) :: [%{criterion: String.t(), status: String.t(), evidence: String.t()}]
  def rows([], answer), do: Enum.map(Map.get(answer, :criteria, []), &Map.take(&1, [:criterion, :status, :evidence]))

  def rows(criteria, answer) do
    answers = Map.get(answer, :criteria, [])

    Enum.map(criteria, fn %{id: id, criterion: text} ->
      case Enum.find(answers, &(&1.id == id)) do
        %{status: status, evidence: evidence} -> %{criterion: text, status: status, evidence: evidence}
        nil -> %{criterion: text, status: "unclear", evidence: "not judged by the gate agent"}
      end
    end)
  end

  defp answer({:answer, answer}), do: answer
  defp answer(_outcome), do: %{}

  defp mode_line(%{mode: "shadow"}),
    do: "**Mode:** shadow. This verdict is advisory: Symphony records it, and the issue moves to In Review as before. Nothing merges on its own."

  defp mode_line(%{mode: "enforce", target: %{state: "Merging"}}),
    do: "**Mode:** enforce. Symphony applies this verdict: the issue moves to Merging, and GitHub auto-merge lands the PR once its checks pass."

  defp mode_line(%{mode: "enforce", target: %{state: state, escalated: true}} = report),
    do: "**Mode:** enforce. The fix attempts are used up (#{report.fix_attempts} of #{report.max_fix_attempts}), so this rework goes to a person: the issue moves to #{state}."

  defp mode_line(%{mode: "enforce", target: %{state: state}, decision: %{verdict: "rework"}} = report),
    do: "**Mode:** enforce. Symphony applies this verdict: the issue goes back to #{state} with the unmet criteria (fix attempt #{report.fix_attempts + 1} of #{report.max_fix_attempts})."

  defp mode_line(%{mode: "enforce", target: %{state: state}}), do: "**Mode:** enforce. Symphony applies this verdict: the issue moves to #{state} for a person to decide."

  defp mode_line(%{mode: "enforce", decision: %{verdict: nil}}), do: "**Mode:** enforce."

  defp mode_line(%{mode: "enforce"}),
    do: "**Mode:** enforce, but the gate never moves a `breakdown` parent or a `Final verification:` ticket: this verdict is advisory, and the issue moves to In Review as before."

  defp mode_line(%{mode: mode}), do: "**Mode:** #{mode}. The gate was turned off during this pass: this verdict is advisory, and the issue moves to In Review as before."

  defp verdict_label(%{decision: %{verdict: nil, inconclusive: count}, limit: limit}),
    do: "inconclusive (#{count} of #{limit}); Symphony runs the gate again on the next green CI poll"

  defp verdict_label(%{decision: %{verdict: verdict}}), do: verdict

  defp head_line(report) do
    head =
      case report.context do
        %{base_branch: base, base_sha: base_sha} -> "**PR head:** `#{short(report.sha)}` merged onto `#{base}` (`#{short(base_sha)}`)"
        _none -> "**PR head:** `#{short(report.sha)}`"
      end

    Enum.join([head | meta(report)], " · ")
  end

  defp meta(report) do
    [
      if(report.runtime_seconds > 0, do: "#{div(report.runtime_seconds, 60)}m #{rem(report.runtime_seconds, 60)}s"),
      if(report.tokens.total_tokens > 0, do: "#{report.tokens.total_tokens} tokens"),
      if(report.follow_up_turns > 0, do: "verdict after 1 follow-up")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp summary_block({:inconclusive, reason}, _answer), do: "\nThe gate pass was inconclusive: #{inspect(reason)}\n"
  defp summary_block({:conflict, _files}, _answer), do: "\nThe PR conflicts with current main, so the gate agent didn't run.\n"
  defp summary_block(_outcome, %{summary: summary}) when summary != "", do: "\n" <> summary <> "\n"
  defp summary_block(_outcome, _answer), do: ""

  defp criteria_block([]), do: nil

  defp criteria_block(rows) do
    lines = Enum.map(rows, &"| #{cell(&1.criterion)} | #{&1.status} | #{cell(&1.evidence)} |")
    Enum.join(["### Acceptance criteria", "", "| Criterion | Result | Evidence |", "| --- | --- | --- |" | lines], "\n") <> "\n"
  end

  defp context_overlaps(%{context: %{overlaps: overlaps}}), do: overlaps
  defp context_overlaps(_report), do: []

  defp overlaps_block([], []), do: nil

  defp overlaps_block(overlaps, notes) do
    lines =
      Enum.map(overlaps, fn overlap ->
        functions = Enum.map_join(overlap.functions, ", ", &"`#{&1.name}` (#{&1.path})")
        issue = if overlap.issue_identifier, do: " (#{overlap.issue_identifier})", else: ""
        "#{overlap.pr_url}#{issue}: #{Enum.map_join(overlap.files, ", ", &"`#{&1}`")}#{if functions != "", do: "; functions #{functions}", else: ""}"
      end) ++ Enum.map(notes, &"agent: #{&1.pr_url} #{&1.detail}")

    list_block("Overlaps with open PRs", lines)
  end

  defp follow_ups_block(nil, proposed), do: list_block("Proposed follow-ups (not filed)", Enum.map(proposed, &follow_up_line/1))
  defp follow_ups_block(filed, _proposed), do: list_block("Follow-ups", Enum.map(filed, &filed_line/1))

  defp filed_line(%{status: {:filed, identifier}} = follow_up), do: "filed as #{identifier || "a sub-issue"}: #{follow_up_line(follow_up)}"
  defp filed_line(%{status: :duplicate} = follow_up), do: "already a sub-issue, not filed again: #{follow_up_line(follow_up)}"
  defp filed_line(%{status: :over_cap} = follow_up), do: "not filed (#{FollowUps.max_per_verdict()} per verdict): #{follow_up_line(follow_up)}"
  defp filed_line(%{status: {:failed, reason}} = follow_up), do: "not filed (#{inspect(reason)}): #{follow_up_line(follow_up)}"

  defp follow_up_line(%{title: title, detail: ""}), do: "**#{title}**"
  defp follow_up_line(%{title: title, detail: detail}), do: "**#{title}**: #{detail}"

  defp list_block(_title, []), do: nil
  defp list_block(title, lines), do: Enum.join(["### #{title}", "" | Enum.map(lines, &("- " <> &1))], "\n") <> "\n"

  # A table cell holds one line and no column separator.
  defp cell(text) do
    text = text |> String.replace(~r/\s*\R\s*/, " ") |> String.replace("|", "\\|")
    if String.length(text) > @cell_limit, do: String.slice(text, 0, @cell_limit - 3) <> "...", else: text
  end

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 12)

  @doc "Creates the gate comment, or rewrites the existing one in place on Linear."
  @spec publish(Issue.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def publish(%Issue{} = issue, body, opts \\ []), do: QaReport.publish(issue, body, Keyword.put(opts, :heading, @heading))
end
