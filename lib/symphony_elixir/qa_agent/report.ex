defmodule SymphonyElixir.QaAgent.Report do
  @moduledoc """
  Renders and publishes the `## Symphony QA Report` Linear comment.

  Symphony keeps one QA report per issue and rewrites it on every QA pass. This is
  the documented exception to the single-workpad rule: the report is written by
  Symphony, never by an agent, so it cannot collide with the workpad.
  """

  require Logger

  alias SymphonyElixir.{AgentTools, Config, Tracker}
  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Linear.Issue

  @heading "## Symphony QA Report"
  @details_limit 2_000
  @comment_limit 100

  @doc "The heading that identifies the QA report comment."
  @spec heading() :: String.t()
  def heading, do: @heading

  @doc """
  Renders the report for a QA outcome. `outcome` carries `:verdict` (`:pass`,
  `:fail`, `:blocked` or `:skip`), `:sha`, `:target_state`, and optionally
  `:summary`, `:steps`, `:findings`, `:reason`, `:playbooks`, `:tokens`,
  `:runtime_seconds`, `:follow_ups`, `:escalated` and `:fix_attempt`/`:max_fix_attempts`.

  A parent walkthrough also passes `:ref` (the branch the commit heads, in place of a PR),
  `:target_issue` (the identifier of the verification ticket `:target_state` applies to) and
  `:filed` (the tickets filed for failing steps, as `%{identifier, title}`).
  """
  @spec render(map()) :: String.t()
  def render(outcome) when is_map(outcome) do
    [
      @heading,
      "",
      "**Verdict:** #{verdict_label(outcome)} → #{target_label(outcome)}",
      "#{head_label(outcome)}#{meta_suffix(outcome)}",
      summary_block(outcome),
      steps_block(Map.get(outcome, :steps, [])),
      findings_block(Map.get(outcome, :findings, [])),
      filed_block(Map.get(outcome, :filed, [])),
      "_Symphony rewrites this comment on every QA pass._"
    ]
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp verdict_label(%{verdict: :fail, escalated: true}), do: "fail (fix attempts used up; handing over to a human)"

  defp verdict_label(%{verdict: :fail, fix_attempt: attempt, max_fix_attempts: max}) when is_integer(attempt) and is_integer(max),
    do: "fail (fix attempt #{attempt} of #{max})"

  defp verdict_label(%{verdict: :skip}), do: "skipped"
  defp verdict_label(%{verdict: verdict}), do: Atom.to_string(verdict)

  defp target_label(%{target_issue: identifier, target_state: state}) when is_binary(identifier), do: "#{identifier} #{state}"
  defp target_label(outcome), do: outcome.target_state

  defp head_label(%{ref: ref} = outcome) when is_binary(ref), do: "**Commit:** `#{short_sha(outcome)}` (head of `#{ref}`)"
  defp head_label(outcome), do: "**PR head:** `#{short_sha(outcome)}`"

  defp short_sha(outcome), do: String.slice(outcome.sha || "", 0, 12)

  defp meta_suffix(outcome) do
    [
      playbooks_meta(Map.get(outcome, :playbooks, [])),
      runtime_meta(Map.get(outcome, :runtime_seconds)),
      tokens_meta(Map.get(outcome, :tokens)),
      follow_ups_meta(Map.get(outcome, :follow_ups))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(&(" · " <> &1))
  end

  defp playbooks_meta([]), do: nil
  defp playbooks_meta(kinds), do: "playbooks: " <> Enum.join(kinds, ", ")

  defp runtime_meta(seconds) when is_integer(seconds) and seconds > 0, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp runtime_meta(_seconds), do: nil

  defp tokens_meta(%{total_tokens: total}) when is_integer(total) and total > 0, do: "#{total} tokens"
  defp tokens_meta(_tokens), do: nil

  defp follow_ups_meta(1), do: "verdict after 1 follow-up"
  defp follow_ups_meta(count) when is_integer(count) and count > 1, do: "verdict after #{count} follow-ups"
  defp follow_ups_meta(_count), do: nil

  defp summary_block(outcome) do
    text =
      case outcome do
        %{verdict: verdict, reason: reason} when verdict in [:skip, :blocked] and is_binary(reason) -> "Reason: " <> reason
        _outcome -> Map.get(outcome, :summary)
      end

    if is_binary(text) and String.trim(text) != "", do: "\n" <> String.trim(text) <> "\n", else: ""
  end

  defp steps_block([]), do: nil

  defp steps_block(steps) do
    lines = Enum.map(steps, &step_lines/1)
    Enum.join(["### Steps", "" | lines], "\n") <> "\n"
  end

  defp step_lines(step) do
    evidence =
      case step.evidence do
        [] -> ""
        links -> " (evidence: " <> Enum.join(links, ", ") <> ")"
      end

    head = "- **#{step.status}** #{step.name}#{evidence}"

    case String.trim(step.details) do
      "" -> head
      details -> head <> "\n\n  ```text\n" <> indent(truncate(details)) <> "\n  ```\n"
    end
  end

  defp findings_block([]), do: nil
  defp findings_block(findings), do: Enum.join(["### Findings", "" | Enum.map(findings, &("- " <> &1))], "\n") <> "\n"

  defp filed_block([]), do: nil

  defp filed_block(filed) do
    Enum.join(["### Filed tickets", "" | Enum.map(filed, &"- #{&1.identifier} #{&1.title}")], "\n") <> "\n"
  end

  defp truncate(text) when byte_size(text) > @details_limit, do: binary_part(text, 0, @details_limit) <> "\n[... truncated ...]"
  defp truncate(text), do: text

  defp indent(text), do: text |> String.replace("```", "'''") |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  @doc """
  Creates the QA report comment, or rewrites the existing one in place on Linear.
  Other trackers get a new comment.
  """
  @spec publish(Issue.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def publish(%Issue{id: issue_id} = issue, body, opts \\ []) when is_binary(issue_id) and is_binary(body) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)

    if settings.tracker.kind == "linear",
      do: publish_linear(issue, body, Keyword.take(opts, [:linear_client, :settings])),
      else: Tracker.create_comment(issue_id, body)
  end

  defp publish_linear(issue, body, opts) do
    {:ok, registry} = CommentRegistry.start_link()

    try do
      context = %{issue: issue, comment_registry: registry}

      with {:ok, comments} <- AgentTools.Linear.get_comments(context, @comment_limit, opts) do
        case Enum.find(comments, &report_comment?/1) do
          %{"id" => comment_id} ->
            CommentRegistry.record(registry, comment_id)
            ok(AgentTools.Linear.update_comment(context, comment_id, body, opts))

          nil ->
            ok(AgentTools.Linear.add_comment(context, body, opts))
        end
      end
    after
      Agent.stop(registry)
    end
  end

  defp ok({:ok, _response}), do: :ok
  defp ok({:error, reason}), do: {:error, reason}

  defp report_comment?(%{"id" => id, "body" => body}) when is_binary(id) and is_binary(body) do
    body
    |> String.trim()
    |> String.replace_prefix("<linear_issue_comment_body>", "")
    |> String.trim_leading()
    |> String.starts_with?(@heading)
  end

  defp report_comment?(_comment), do: false
end
