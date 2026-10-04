defmodule SymphonyElixir.Notifications.Formatter do
  @moduledoc false

  alias SymphonyElixir.Notifications.Event

  @pr_url_events [
    "pr_opened",
    "awaiting_review",
    "run_failed",
    "run_stuck",
    "dependency_pending_approval",
    "reviewer_commented",
    "rework_pushed",
    "ci_failed",
    "ci_escalated",
    "qa_passed",
    "qa_failed"
  ]

  # Not about one issue: the headline and text carry the reason (which limit, when it resumes).
  @usage_limit_events ["usage_limit_paused", "usage_limit_headroom", "usage_limit_resumed"]

  @spec webhook_payload(Event.t(), keyword()) :: map()
  def webhook_payload(%Event{} = event, opts \\ []) do
    redact_titles = Keyword.get(opts, :redact_titles, false)

    %{
      "event" => event.event,
      "repo_key" => event.repo_key,
      "issue_id" => event.issue_id,
      "issue_identifier" => event.issue_identifier,
      "issue_url" => event.issue_url,
      "pr_url" => event.pr_url,
      "state_url" => state_url(event),
      "transcript_url" => event.transcript_url,
      "timestamp" => DateTime.to_iso8601(event.timestamp),
      "state" => event.state,
      "reason" => event.reason,
      "run_id" => event.run_id,
      "session_id" => event.session_id,
      "attempt" => event.attempt,
      "tokens" => event.tokens,
      "metadata" => event.metadata
    }
    |> maybe_put_title("issue_title", event.issue_title, redact_titles)
    |> maybe_put_title("pr_title", event.pr_title, redact_titles)
    |> reject_nil_values()
  end

  @spec slack_payload(Event.t(), keyword()) :: map()
  def slack_payload(%Event{} = event, opts \\ []) do
    redact_titles = Keyword.get(opts, :redact_titles, false)
    title = event_title(event.event)

    %{
      "text" => "#{title}: #{text_subject(event)}",
      "attachments" => [
        %{
          "color" => event_color(event.event),
          "blocks" =>
            [
              headline_block(event, title, redact_titles),
              fields_block(event),
              context_block(event)
            ]
            |> Enum.reject(&is_nil/1)
        }
      ]
    }
  end

  @spec state_url(Event.t()) :: String.t() | nil
  def state_url(%Event{event: event_name, pr_url: pr_url, issue_url: issue_url})
      when event_name in @pr_url_events do
    pr_url || issue_url
  end

  def state_url(%Event{issue_url: issue_url}), do: issue_url

  defp maybe_put_title(payload, _key, _title, true), do: payload
  defp maybe_put_title(payload, _key, nil, _redact_titles), do: payload
  defp maybe_put_title(payload, key, title, _redact_titles), do: Map.put(payload, key, title)

  defp reject_nil_values(payload) do
    Map.reject(payload, fn {_key, value} -> is_nil(value) end)
  end

  defp text_subject(%Event{event: event_name, reason: reason}) when event_name in @usage_limit_events, do: reason
  defp text_subject(event), do: event.issue_identifier || event.issue_id || "issue"

  defp headline_block(event, title, redact_titles) do
    title_parts =
      event
      |> headline_parts(title, redact_titles)
      |> Enum.reject(&blank?/1)

    %{
      "type" => "section",
      "text" => %{
        "type" => "mrkdwn",
        "text" => Enum.join(title_parts, " - ")
      }
    }
  end

  defp fields_block(event) do
    fields =
      [
        field("Event", event.event),
        field_mrkdwn("State URL", link_text(state_url(event), "Open")),
        field_mrkdwn("PR", link_text(event.pr_url, "Pull request")),
        field_mrkdwn("Transcript", link_text(event.transcript_url, "Transcript")),
        field("State", event.state),
        field("Reason", event.reason)
      ]
      |> Enum.reject(&is_nil/1)

    if fields == [] do
      nil
    else
      %{"type" => "section", "fields" => fields}
    end
  end

  defp headline_parts(%Event{event: event_name} = event, title, _redact_titles) when event_name in @usage_limit_events do
    ["*#{escape_mrkdwn(title)}*", event.reason && escape_mrkdwn(event.reason)]
  end

  defp headline_parts(event, title, redact_titles) do
    ["*#{escape_mrkdwn(title)}*", issue_link(event), title_text(event.issue_title, redact_titles)]
  end

  defp context_block(event) do
    %{
      "type" => "context",
      "elements" => [
        %{"type" => "mrkdwn", "text" => "sent #{DateTime.to_iso8601(event.timestamp)}"}
      ]
    }
  end

  defp issue_link(%Event{issue_url: issue_url, issue_identifier: identifier, issue_id: issue_id}) do
    label = identifier || issue_id || "issue"
    link_text(issue_url, label) || escape_mrkdwn(label)
  end

  defp title_text(_title, true), do: nil
  defp title_text(nil, _redact_titles), do: nil
  defp title_text(title, _redact_titles), do: escape_mrkdwn(title)

  defp field(_label, value) when value in [nil, ""], do: nil

  defp field(label, value) do
    %{
      "type" => "mrkdwn",
      "text" => "*#{escape_mrkdwn(label)}*\n#{escape_mrkdwn(value)}"
    }
  end

  defp field_mrkdwn(_label, value) when value in [nil, ""], do: nil

  defp field_mrkdwn(label, value) do
    %{
      "type" => "mrkdwn",
      "text" => "*#{escape_mrkdwn(label)}*\n#{value}"
    }
  end

  defp link_text(nil, _label), do: nil
  defp link_text("", _label), do: nil

  defp link_text(url, label) when is_binary(url) do
    "<#{escape_link(url)}|#{escape_mrkdwn(label)}>"
  end

  defp event_title("pr_opened"), do: "PR opened"
  defp event_title("awaiting_review"), do: "Awaiting review"
  defp event_title("run_failed"), do: "Run failed"
  defp event_title("run_stuck"), do: "Run stuck"
  defp event_title("dependency_pending_approval"), do: "Dependency approval needed"
  defp event_title("issue_completed"), do: "Issue completed"
  defp event_title("budget_exceeded"), do: "Budget exceeded"
  defp event_title("ci_failed"), do: "CI failed"
  defp event_title("ci_escalated"), do: "CI escalated"
  defp event_title("qa_passed"), do: "QA passed"
  defp event_title("qa_failed"), do: "QA failed"
  defp event_title("reviewer_commented"), do: "Reviewer commented"
  defp event_title("rework_pushed"), do: "Rework pushed"
  defp event_title("usage_limit_paused"), do: "Usage limit paused"
  defp event_title("usage_limit_headroom"), do: "Usage limit headroom hold"
  defp event_title("usage_limit_resumed"), do: "Usage limit resumed"
  defp event_title(event), do: event

  defp event_color("run_failed"), do: "danger"
  defp event_color("run_stuck"), do: "danger"
  defp event_color("ci_failed"), do: "danger"
  defp event_color("ci_escalated"), do: "warning"
  defp event_color("qa_passed"), do: "good"
  defp event_color("qa_failed"), do: "danger"
  defp event_color("budget_exceeded"), do: "warning"
  defp event_color("dependency_pending_approval"), do: "warning"
  defp event_color("issue_completed"), do: "good"
  defp event_color("usage_limit_paused"), do: "warning"
  defp event_color("usage_limit_headroom"), do: "warning"
  defp event_color("usage_limit_resumed"), do: "good"
  defp event_color(_event), do: "#2f80ed"

  defp blank?(value), do: value in [nil, ""]

  defp escape_mrkdwn(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_mrkdwn(value), do: value |> to_string() |> escape_mrkdwn()

  defp escape_link(value) when is_binary(value) do
    value
    |> String.replace("<", "%3C")
    |> String.replace(">", "%3E")
    |> String.replace("|", "%7C")
  end
end
