defmodule SymphonyElixir.Notifications.Event do
  @moduledoc false

  alias SymphonyElixir.{Config, HttpServer, URLUtils}
  alias SymphonyElixir.Linear.Issue

  @known_events [
    "pr_opened",
    "awaiting_review",
    "run_failed",
    "run_stuck",
    "issue_completed",
    "budget_exceeded",
    "dependency_pending_approval",
    "reviewer_commented",
    "rework_pushed",
    "ci_failed",
    "ci_escalated",
    "qa_passed",
    "qa_failed",
    "usage_limit_paused",
    "usage_limit_headroom",
    "usage_limit_resumed",
    "forced_waiting"
  ]
  @max_string_value_length 1024

  defstruct [
    :event,
    :repo_key,
    :issue_id,
    :issue_identifier,
    :issue_title,
    :issue_url,
    :pr_url,
    :pr_title,
    :state,
    :reason,
    :run_id,
    :session_id,
    :attempt,
    :transcript_url,
    :timestamp,
    tokens: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          event: String.t(),
          repo_key: String.t() | nil,
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          issue_title: String.t() | nil,
          issue_url: String.t() | nil,
          pr_url: String.t() | nil,
          pr_title: String.t() | nil,
          state: String.t() | nil,
          reason: String.t() | nil,
          run_id: String.t() | nil,
          session_id: String.t() | nil,
          attempt: integer() | nil,
          transcript_url: String.t() | nil,
          timestamp: DateTime.t(),
          tokens: map(),
          metadata: map()
        }

  @spec known_events() :: [String.t()]
  def known_events, do: @known_events

  @spec new(atom() | String.t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(event, attrs \\ %{}) do
    event_name = normalize_event(event)

    if event_name in @known_events do
      attrs = attrs_map(attrs)
      identifier = string_value(attrs, [:issue_identifier, "issue_identifier"])
      repo_key = string_value(attrs, [:repo_key, "repo_key"]) || default_repo_key()

      event =
        %__MODULE__{
          event: event_name,
          repo_key: repo_key,
          issue_id: string_value(attrs, [:issue_id, "issue_id"]),
          issue_identifier: identifier,
          issue_title: string_value(attrs, [:issue_title, "issue_title"]),
          issue_url: string_value(attrs, [:issue_url, "issue_url"]),
          pr_url: string_value(attrs, [:pr_url, "pr_url"]) || URLUtils.pull_request_url(attrs),
          pr_title: string_value(attrs, [:pr_title, "pr_title"]),
          state: string_value(attrs, [:state, "state"]),
          reason: inspected_string_value(attrs, [:reason, "reason"]),
          run_id: string_value(attrs, [:run_id, "run_id"]),
          session_id: string_value(attrs, [:session_id, "session_id"]),
          attempt: integer_value(attrs, [:attempt, "attempt"]),
          transcript_url: string_value(attrs, [:transcript_url, "transcript_url"]) || transcript_url(repo_key, identifier),
          timestamp: timestamp_value(attrs),
          tokens: map_value(attrs, [:tokens, "tokens"]) || %{},
          metadata: map_value(attrs, [:metadata, "metadata"]) || %{}
        }

      {:ok, event}
    else
      {:error, {:unknown_notification_event, event}}
    end
  end

  @spec from_issue(atom() | String.t(), term()) :: {:ok, t()} | {:error, term()}
  def from_issue(event, issue), do: from_issue(event, issue, %{})

  @spec from_issue(atom() | String.t(), term(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def from_issue(event, %Issue{} = issue, attrs) do
    attrs =
      %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_title: issue.title,
        issue_url: URLUtils.present_url(issue.url),
        pr_url: URLUtils.pull_request_url(issue),
        state: issue.state
      }
      |> Map.merge(attrs_map(attrs))

    new(event, attrs)
  end

  def from_issue(event, _issue, attrs), do: new(event, attrs)

  @spec known_event?(atom() | String.t()) :: boolean()
  def known_event?(event), do: normalize_event(event) in @known_events

  defp normalize_event(event) when is_atom(event) do
    event
    |> Atom.to_string()
    |> normalize_event()
  end

  defp normalize_event(event) when is_binary(event) do
    event
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_event(event), do: to_string(event)

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(_attrs), do: %{}

  defp string_value(attrs, keys) when is_list(keys) do
    Enum.find_value(keys, &string_value(attrs, &1))
  end

  defp string_value(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) do
      nil ->
        nil

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_atom(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        nil
    end
  end

  defp inspected_string_value(attrs, keys) when is_list(keys) do
    Enum.find_value(keys, &inspected_string_value(attrs, &1))
  end

  defp inspected_string_value(attrs, key) when is_map(attrs) do
    case string_value(attrs, key) do
      nil ->
        attrs
        |> Map.get(key)
        |> inspected_fallback()

      value ->
        String.slice(value, 0, @max_string_value_length)
    end
  end

  defp inspected_fallback(nil), do: nil
  defp inspected_fallback(value) when is_binary(value), do: trim_string(value)

  defp inspected_fallback(value) do
    value
    |> inspect(limit: 50, printable_limit: @max_string_value_length)
    |> trim_string()
  end

  defp trim_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @max_string_value_length)
    end
  end

  defp integer_value(attrs, keys) when is_list(keys) do
    Enum.find_value(keys, &integer_value(attrs, &1))
  end

  defp integer_value(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp map_value(attrs, keys) when is_list(keys) do
    Enum.find_value(keys, &map_value(attrs, &1))
  end

  defp map_value(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp timestamp_value(attrs) do
    case Map.get(attrs, :timestamp) || Map.get(attrs, "timestamp") do
      %DateTime{} = timestamp -> timestamp
      _ -> DateTime.utc_now()
    end
  end

  defp transcript_url(repo_key, identifier) when is_binary(repo_key) and is_binary(identifier) do
    settings = Config.settings!()
    URLUtils.transcript_url(repo_key, identifier, settings.server.host, Config.server_port(), HttpServer.bound_port())
  rescue
    _error -> nil
  end

  defp transcript_url(_repo_key, _identifier), do: nil

  defp default_repo_key, do: Config.repo_key_or_nil()
end
