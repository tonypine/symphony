defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{
    AuditLog,
    BuildInfo,
    Config,
    Orchestrator,
    Quality,
    RunKind,
    StrayProcesses,
    URLUtils,
    UsageLimit
  }

  alias SymphonyElixir.Codex.MessageHumanizer

  @audit_page_size 200
  @audit_event_types ~w(
    file_change
    linear_comment
    linear_state_change
    poller_degraded
    poller_recovered
    pr_opened
    prompt_sent
    refused_agent_action
    token_usage_delta
    tool_call
  )

  @empty_codex_totals %{
    input_tokens: 0,
    uncached_input_tokens: 0,
    cached_input_tokens: 0,
    cache_creation_input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @spec state_payload(GenServer.name(), timeout(), GenServer.server()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms, stray_processes \\ StrayProcesses) do
    now = DateTime.utc_now()
    generated_at = now |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        run_history = Map.get(snapshot, :run_history, [])
        blocked = Map.get(snapshot, :blocked, [])

        %{
          generated_at: generated_at,
          build: Map.take(BuildInfo.current(), [:version, :sha]),
          repos: repo_keys(snapshot),
          counts: %{
            running: length(snapshot.running),
            watching: length(Map.get(snapshot, :watching, [])),
            conflicts: length(Map.get(snapshot, :conflicts, [])),
            retrying: length(snapshot.retrying),
            claimed: length(Map.get(snapshot, :claimed, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          watching: snapshot |> Map.get(:watching, []) |> Enum.map(&watching_entry_payload/1),
          conflicts: snapshot |> Map.get(:conflicts, []) |> Enum.map(&conflict_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          awaiting_clarification:
            snapshot
            |> Map.get(:awaiting_clarification, [])
            |> Enum.map(&awaiting_clarification_entry_payload/1),
          skipped:
            snapshot
            |> Map.get(:skipped, [])
            |> Enum.map(&skipped_entry_payload/1),
          run_history: Enum.map(run_history, &run_history_payload/1),
          codex_totals: normalize_codex_totals(Map.get(snapshot, :codex_totals)),
          pollers: normalize_pollers(Map.get(snapshot, :pollers)),
          pause: normalize_pause(Map.get(snapshot, :pause)),
          usage_limits: snapshot |> Map.get(:usage_limits, []) |> Enum.map(&usage_limit_payload(&1, now)),
          stray_processes: stray_processes |> StrayProcesses.warnings() |> Enum.map(&Map.delete(&1, :start_time)),
          budget: normalize_budget(Map.get(snapshot, :budget)),
          dispatch_state: normalize_dispatch_state(snapshot),
          epic_lanes: normalize_epic_lanes(Map.get(snapshot, :epic_lanes)),
          finishing: normalize_finishing(Map.get(snapshot, :finishing)),
          qa: normalize_qa(Map.get(snapshot, :qa)),
          auto_merge: snapshot |> Map.get(:auto_merge, []) |> Enum.map(&auto_merge_payload/1),
          slot_waiting: snapshot |> Map.get(:slot_waiting, []) |> Enum.map(&slot_waiting_payload/1),
          blocked: Enum.map(blocked, &blocked_payload/1),
          app_update: app_update_payload(blocked),
          forced: snapshot |> Map.get(:forced, []) |> Enum.map(&forced_payload/1),
          concurrency: Map.get(snapshot, :concurrency),
          claimed: Map.get(snapshot, :claimed, []),
          rate_limits: snapshot.rate_limits,
          linear_usage: normalize_linear_usage(get_in(snapshot, [:polling, :linear, :usage]))
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        watching = snapshot |> Map.get(:watching, []) |> Enum.find(&(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(watching) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, watching)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec transcript_payload(String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found | :snapshot_unavailable}
  def transcript_payload(issue_identifier, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) do
    transcript_payload(current_repo_key(), issue_identifier, orchestrator, snapshot_timeout_ms)
  end

  @spec transcript_payload(String.t() | nil, String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found | :snapshot_unavailable}
  def transcript_payload(repo_key, issue_identifier, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        transcript_payload_from_snapshot(snapshot, repo_key, issue_identifier)

      _ ->
        {:error, :snapshot_unavailable}
    end
  end

  @spec audit_payload(map(), GenServer.name(), timeout()) :: map()
  def audit_payload(params, orchestrator, snapshot_timeout_ms) when is_map(params) do
    snapshot_context = audit_snapshot_context(orchestrator, snapshot_timeout_ms)
    filters = audit_filters(params, snapshot_context)

    query_opts = [
      repo: filters.repo,
      issue: filters.issue,
      event_type: filters.event_type,
      run_id: filters.run_id,
      from: filters.date_from,
      to: filters.date_to,
      since: filters.since
    ]

    case AuditLog.query(query_opts) do
      {:ok, stream} ->
        raw_events = stream |> Enum.take(@audit_page_size + 1)
        {page, overflow} = Enum.split(raw_events, @audit_page_size)

        %{
          filters: filters,
          repos: snapshot_context.repos,
          events: Enum.map(page, &audit_event_payload/1),
          event_types: @audit_event_types,
          truncated?: overflow != [],
          error: nil
        }

      {:error, reason} ->
        %{
          filters: filters,
          repos: snapshot_context.repos,
          events: [],
          event_types: @audit_event_types,
          truncated?: false,
          error: %{code: "invalid_audit_filter", message: inspect(reason)}
        }
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec review_agent_verdict_summary(map()) :: String.t() | nil
  def review_agent_verdict_summary(event) when is_map(event) do
    if review_agent_verdict_event?(event) do
      payload = event_payload(event)
      verdict = payload |> map_value(["verdict", :verdict]) |> verdict_text()
      round = map_value(payload, ["round", :round])
      max_iterations = map_value(payload, ["max_iterations", :max_iterations])
      reason = payload |> map_value(["reason", :reason]) |> present_string()
      comments = payload |> map_value(["comments", :comments]) |> normalize_comments()
      tokens = payload |> map_value(["tokens", :tokens]) |> normalize_token_map()

      [
        "Reviewer verdict: #{verdict}",
        review_agent_round_text(round, max_iterations),
        review_agent_reason_text(reason, comments),
        review_agent_comments_text(comments),
        "tokens in=#{tokens.input_tokens} out=#{tokens.output_tokens} total=#{tokens.total_tokens}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" | ")
    end
  end

  def review_agent_verdict_summary(_event), do: nil

  @spec review_agent_verdict(map()) :: String.t() | nil
  def review_agent_verdict(event) when is_map(event) do
    if review_agent_verdict_event?(event) do
      event
      |> event_payload()
      |> map_value(["verdict", :verdict])
      |> verdict_value()
    end
  end

  def review_agent_verdict(_event), do: nil

  @spec review_agent_verdict_event?(map()) :: boolean()
  def review_agent_verdict_event?(event) when is_map(event) do
    map_value(event, ["event", :event]) in [:review_agent_verdict, "review_agent_verdict"]
  end

  def review_agent_verdict_event?(_event), do: false

  defp event_payload(event) when is_map(event), do: map_value(event, ["payload", :payload]) || %{}

  defp review_agent_round_text(round, max_iterations) when is_integer(round) and is_integer(max_iterations) do
    "review #{round} of #{max_iterations + 1}"
  end

  defp review_agent_round_text(_round, _max_iterations), do: nil

  defp review_agent_reason_text(reason, _comments) when is_binary(reason), do: "reason: #{reason}"
  defp review_agent_reason_text(_reason, [comment | _]) when is_binary(comment), do: "reason: #{comment}"
  defp review_agent_reason_text(_reason, _comments), do: nil

  defp review_agent_comments_text([]), do: "comments: 0"
  defp review_agent_comments_text(comments) when is_list(comments), do: "comments: #{length(comments)}"

  defp verdict_text(value) when is_atom(value), do: value |> Atom.to_string() |> String.replace("_", " ")
  defp verdict_text(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp verdict_text(_value), do: "unknown"

  defp verdict_value(value) when is_atom(value), do: Atom.to_string(value)
  defp verdict_value(value) when is_binary(value), do: value
  defp verdict_value(_value), do: nil

  defp normalize_comments(comments) when is_list(comments), do: Enum.filter(comments, &is_binary/1)
  defp normalize_comments(_comments), do: []

  defp normalize_token_map(tokens) when is_map(tokens) do
    input_tokens = integer_map_value(tokens, :input_tokens)
    cached_input_tokens = integer_map_value(tokens, :cached_input_tokens)

    uncached_input_tokens =
      integer_map_value(tokens, :uncached_input_tokens, uncached_input_tokens(input_tokens, cached_input_tokens))

    cache_creation_input_tokens = integer_map_value(tokens, :cache_creation_input_tokens)

    %{
      input_tokens: uncached_input_tokens + cached_input_tokens + cache_creation_input_tokens,
      uncached_input_tokens: uncached_input_tokens,
      cached_input_tokens: cached_input_tokens,
      cache_creation_input_tokens: cache_creation_input_tokens,
      output_tokens: integer_map_value(tokens, :output_tokens),
      total_tokens: integer_map_value(tokens, :total_tokens)
    }
  end

  defp normalize_token_map(_tokens), do: normalize_token_map(%{})

  defp normalize_pollers(pollers) when is_map(pollers) do
    %{
      ci: normalize_poller_status(Map.get(pollers, :ci, Map.get(pollers, "ci"))),
      pr_review: normalize_poller_status(Map.get(pollers, :pr_review, Map.get(pollers, "pr_review")))
    }
  end

  defp normalize_pollers(_pollers), do: %{ci: :unavailable, pr_review: :unavailable}

  # Linear requests per caller and per query over the last hour, busiest first.
  defp normalize_linear_usage(%{window_ms: window_ms, total: total, callers: callers, queries: queries}) do
    %{
      window_ms: window_ms,
      total: total,
      callers: Enum.map(callers, &Map.take(&1, [:caller, :requests])),
      queries: Enum.map(queries, &Map.take(&1, [:query, :requests]))
    }
  end

  defp normalize_linear_usage(_usage), do: %{window_ms: 3_600_000, total: 0, callers: [], queries: []}

  defp normalize_poller_status(%{} = status) do
    %{
      status: Map.get(status, :status, Map.get(status, "status")),
      consecutive_failures: integer_map_value(status, :consecutive_failures),
      current_backoff_ms: integer_or_nil(Map.get(status, :current_backoff_ms, Map.get(status, "current_backoff_ms"))),
      poll_interval_ms: integer_or_nil(Map.get(status, :poll_interval_ms, Map.get(status, "poll_interval_ms"))),
      webhooks: normalize_webhooks(Map.get(status, :webhooks))
    }
  end

  defp normalize_poller_status(:unavailable), do: :unavailable
  defp normalize_poller_status(_status), do: :unavailable

  # GitHub webhook deliveries the CI poller has seen, and how many CI results arrived through
  # them versus through the timed poll.
  defp normalize_webhooks(%{} = webhooks) do
    %{
      enabled: Map.get(webhooks, :enabled) == true,
      relay: Map.get(webhooks, :relay),
      last_event_at: iso8601(Map.get(webhooks, :last_event_at)),
      events_received: integer_map_value(webhooks, :events_received),
      rejected: integer_map_value(webhooks, :rejected),
      results_via_webhook: integer_map_value(webhooks, :results_via_webhook),
      results_via_poll: integer_map_value(webhooks, :results_via_poll)
    }
  end

  defp normalize_webhooks(_webhooks), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp integer_map_value(map, key, default \\ 0) do
    string_key = Atom.to_string(key)

    case Map.get(map, key, Map.get(map, string_key, default)) do
      value when is_integer(value) -> value
      _value -> default
    end
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil

  defp map_value(value, keys) when is_map(value) do
    Enum.find_value(keys, fn key -> Map.get(value, key) end)
  end

  defp map_value(_value, _keys), do: nil

  defp audit_snapshot_context(orchestrator, snapshot_timeout_ms) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          repos: repo_keys(snapshot),
          poll_interval_ms: get_in(snapshot, [:polling, :poll_interval_ms])
        }

      _ ->
        %{repos: [], poll_interval_ms: nil}
    end
  end

  defp audit_filters(params, snapshot_context) do
    today = Date.utc_today() |> Date.to_iso8601()
    date_from = present_param(params, "from") || present_param(params, "date_from") || today
    date_to = present_param(params, "to") || present_param(params, "date_to") || date_from
    since_last_poll? = truthy_param?(Map.get(params, "since_last_poll"))

    %{
      repo: normalize_audit_repo(present_param(params, "repo"), snapshot_context.repos),
      issue: present_param(params, "issue"),
      event_type: present_param(params, "type") || present_param(params, "event_type"),
      run_id: present_param(params, "run_id"),
      date_from: date_from,
      date_to: date_to,
      since_last_poll?: since_last_poll?,
      since: audit_since(since_last_poll?, snapshot_context.poll_interval_ms)
    }
  end

  defp normalize_audit_repo(nil, _repos), do: nil
  defp normalize_audit_repo("all", _repos), do: nil
  defp normalize_audit_repo(repo, []), do: repo
  defp normalize_audit_repo(repo, repos), do: if(repo in repos, do: repo)

  defp audit_since(false, _poll_interval_ms), do: nil

  defp audit_since(true, poll_interval_ms) when is_integer(poll_interval_ms) and poll_interval_ms > 0 do
    DateTime.utc_now()
    |> DateTime.add(-poll_interval_ms, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp audit_since(true, _poll_interval_ms) do
    DateTime.utc_now()
    |> DateTime.add(-60, :second)
    |> DateTime.to_iso8601()
  end

  defp audit_event_payload(event) do
    %{
      timestamp: Map.get(event, "timestamp"),
      event_type: Map.get(event, "event_type"),
      issue: Map.get(event, "issue_identifier") || Map.get(event, "issue_id"),
      issue_id: Map.get(event, "issue_id"),
      issue_identifier: Map.get(event, "issue_identifier"),
      repo_key: Map.get(event, "repo_key"),
      run_id: Map.get(event, "run_id"),
      date: Map.get(event, "date"),
      record_hash: Map.get(event, "record_hash"),
      preview: audit_preview(event),
      record: event,
      record_json: encode_record(event)
    }
  end

  defp audit_preview(event) do
    body =
      Map.drop(event, [
        "timestamp",
        "event_type",
        "issue_id",
        "issue_identifier",
        "repo_key",
        "run_id",
        "date",
        "previous_hash",
        "record_hash"
      ])

    case Jason.encode(body) do
      {:ok, json} -> String.slice(json, 0, 220)
      {:error, _reason} -> "(unencodable record)"
    end
  end

  defp encode_record(event) do
    case Jason.encode(event, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> "(unencodable record)"
    end
  end

  defp present_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp truthy_param?(value), do: value in ["1", "true", "on", true]

  defp issue_payload_body(issue_identifier, running, retry, watching) do
    payload = %{
      repo_key: repo_key_from_entries(running, retry, watching),
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, watching),
      status: issue_status(running, retry, watching),
      workspace: workspace_payload(issue_identifier, running, retry),
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }

    if watching do
      Map.put(payload, :watching, watching_issue_payload(watching))
    else
      payload
    end
  end

  defp issue_id_from_entries(running, retry, watching),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (watching && watching.issue_id)

  defp repo_key_from_entries(running, retry, watching),
    do: (running && Map.get(running, :repo_key)) || (retry && Map.get(retry, :repo_key)) || (watching && Map.get(watching, :repo_key))

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, retry, _watching) do
    cond do
      running -> "running"
      retry -> "retrying"
      true -> "watching"
    end
  end

  defp running_entry_payload(entry) do
    %{
      repo_key: Map.get(entry, :repo_key),
      run_kind: Map.get(entry, :run_kind),
      run_profile: profile_payload(Map.get(entry, :run_profile)),
      reviewer_profile: profile_payload(Map.get(entry, :reviewer_run_profile)),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      url: URLUtils.present_url(Map.get(entry, :url)),
      pull_request_url: URLUtils.pull_request_url(entry),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      transcript_path: Map.get(entry, :transcript_path),
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: running_message(entry),
      linear_wait_until: entry |> Map.get(:linear_wait_until) |> iso8601(),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(Map.get(entry, :last_event_at) || entry.last_codex_timestamp),
      forced: Map.get(entry, :forced, false),
      tokens: %{
        input_tokens: entry_input_tokens(entry),
        uncached_input_tokens: entry_uncached_input_tokens(entry),
        cached_input_tokens: entry_cached_input_tokens(entry),
        cache_creation_input_tokens: entry_cache_creation_input_tokens(entry),
        output_tokens: entry_output_tokens(entry),
        total_tokens: entry_total_tokens(entry)
      }
    }
  end

  defp watching_entry_payload(entry) do
    %{
      repo_key: Map.get(entry, :repo_key),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      url: URLUtils.present_url(Map.get(entry, :url)),
      pull_request_url: URLUtils.pull_request_url(entry),
      last_ran_at: iso8601(entry.last_ran_at),
      seconds_since_last_run: entry.seconds_since_last_run
    }
  end

  defp conflict_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      linear_state: Map.get(entry, :linear_state),
      url: URLUtils.present_url(Map.get(entry, :url)),
      repo_keys: Map.get(entry, :repo_keys, [])
    }
  end

  defp retry_entry_payload(entry) do
    %{
      repo_key: Map.get(entry, :repo_key),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      forced: Map.get(entry, :forced, false)
    }
  end

  defp awaiting_clarification_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      repo_key: Map.get(entry, :repo_key),
      issue_identifier: quality_gate_identifier(entry),
      title: Map.get(entry, :title),
      url: URLUtils.present_url(Map.get(entry, :url)),
      score: Map.get(entry, :score),
      reason: Map.get(entry, :reason),
      rounds_asked: Map.get(entry, :rounds_asked, 0),
      updated_at: iso8601(Map.get(entry, :updated_at))
    }
  end

  defp skipped_entry_payload(entry) do
    %{
      kind: entry |> Map.get(:kind) |> quality_gate_kind(),
      issue_id: Map.get(entry, :issue_id),
      repo_key: Map.get(entry, :repo_key),
      issue_identifier: quality_gate_identifier(entry),
      title: Map.get(entry, :title),
      url: URLUtils.present_url(Map.get(entry, :url)),
      score: Map.get(entry, :score),
      reason: Map.get(entry, :reason),
      error: entry |> Map.get(:error) |> quality_gate_error(),
      updated_at: iso8601(Map.get(entry, :updated_at))
    }
  end

  defp running_issue_payload(running) do
    %{
      repo_key: Map.get(running, :repo_key),
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      transcript_path: Map.get(running, :transcript_path),
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: running_message(running),
      linear_wait_until: running |> Map.get(:linear_wait_until) |> iso8601(),
      last_event_at: iso8601(Map.get(running, :last_event_at) || running.last_codex_timestamp),
      tokens: %{
        input_tokens: entry_input_tokens(running),
        uncached_input_tokens: entry_uncached_input_tokens(running),
        cached_input_tokens: entry_cached_input_tokens(running),
        cache_creation_input_tokens: entry_cache_creation_input_tokens(running),
        output_tokens: entry_output_tokens(running),
        total_tokens: entry_total_tokens(running)
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      repo_key: Map.get(retry, :repo_key),
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp watching_issue_payload(watching) do
    %{
      repo_key: Map.get(watching, :repo_key),
      state: watching.state,
      url: URLUtils.present_url(watching.url),
      pull_request_url: URLUtils.pull_request_url(watching),
      last_ran_at: iso8601(watching.last_ran_at),
      seconds_since_last_run: watching.seconds_since_last_run
    }
  end

  defp run_history_payload(entry) do
    %{
      repo_key: Map.get(entry, :repo_key),
      run_id: entry.run_id,
      kind: Map.get(entry, :kind, "agent"),
      run_kind: Map.get(entry, :run_kind),
      model: Map.get(entry, :model),
      effort: Map.get(entry, :effort),
      profile_label: RunKind.label(entry),
      reviewer_profile: entry |> Map.get(:reviewer_profile) |> profile_payload(),
      issue_id: entry.issue_id,
      issue_identifier: entry.issue_identifier,
      title: Map.get(entry, :title),
      state: Map.get(entry, :state),
      status: entry.status,
      attempt: entry.attempt,
      started_at: iso8601(entry.started_at),
      ended_at: iso8601(Map.get(entry, :ended_at)),
      error: Map.get(entry, :error),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: Map.get(entry, :session_id),
      transcript_path: Map.get(entry, :transcript_path),
      turn_count: Map.get(entry, :turn_count, 0),
      runtime_seconds: Map.get(entry, :runtime_seconds, 0),
      tokens: Map.get(entry, :tokens, %{})
    }
  end

  # Accepts the in-memory profile (`kind`) and the stored run record form (`run_kind`).
  defp profile_payload(nil), do: nil

  defp profile_payload(profile) do
    %{
      kind: to_string(Map.get(profile, :kind) || Map.get(profile, :run_kind)),
      model: Map.get(profile, :model),
      effort: Map.get(profile, :effort),
      label: RunKind.label(profile)
    }
  end

  defp normalize_codex_totals(totals) when is_map(totals) do
    normalized = Map.merge(@empty_codex_totals, totals)
    input_tokens = integer_map_value(totals, :input_tokens)
    cached_input_tokens = integer_map_value(totals, :cached_input_tokens)
    cache_creation_input_tokens = integer_map_value(totals, :cache_creation_input_tokens)

    uncached =
      if Map.has_key?(totals, :uncached_input_tokens) or Map.has_key?(totals, "uncached_input_tokens") do
        integer_map_value(totals, :uncached_input_tokens)
      else
        uncached_input_tokens(input_tokens, cached_input_tokens)
      end

    normalized
    |> Map.put(:input_tokens, uncached + cached_input_tokens + cache_creation_input_tokens)
    |> Map.put(:uncached_input_tokens, uncached)
    |> Map.put(:cached_input_tokens, cached_input_tokens)
    |> Map.put(:cache_creation_input_tokens, cache_creation_input_tokens)
    |> Map.put(:output_tokens, integer_map_value(totals, :output_tokens))
    |> Map.put(:total_tokens, integer_map_value(totals, :total_tokens))
  end

  defp normalize_codex_totals(_totals), do: @empty_codex_totals

  defp repo_keys(snapshot) when is_map(snapshot) do
    [
      snapshot |> Map.get(:running, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:watching, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:retrying, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:awaiting_clarification, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:skipped, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:conflicts, []) |> Enum.flat_map(&(Map.get(&1, :repo_keys, []) || []))
    ]
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_pause(pause) when is_map(pause) do
    %{
      paused: Map.get(pause, :paused, false),
      reason: Map.get(pause, :reason),
      paused_at: iso8601(Map.get(pause, :paused_at))
    }
  end

  defp normalize_pause(_pause) do
    %{paused: false, reason: nil, paused_at: nil}
  end

  defp usage_limit_payload(entry, now) do
    %{
      provider: entry.provider,
      scope: UsageLimit.scope_label(entry.scope),
      reason: Map.get(entry, :reason),
      window: Map.get(entry, :window),
      phase: optional_string(Map.get(entry, :phase)),
      since: iso8601(Map.get(entry, :since)),
      resets_at: iso8601(Map.get(entry, :resets_at)),
      resume_at: iso8601(entry.resume_at),
      source: optional_string(Map.get(entry, :source)),
      utilization: Map.get(entry, :utilization),
      issue_identifier: Map.get(entry, :issue_identifier),
      banner: UsageLimit.banner(entry, now)
    }
  end

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

  defp normalize_budget(budget) when is_map(budget) do
    %{
      per_issue_limit: Map.get(budget, :per_issue_limit),
      daily_limit: Map.get(budget, :daily_limit),
      daily_used: Map.get(budget, :daily_used, 0),
      daily_remaining: Map.get(budget, :daily_remaining),
      daily_paused: Map.get(budget, :daily_paused, false)
    }
  end

  defp normalize_budget(_budget) do
    %{
      per_issue_limit: nil,
      daily_limit: nil,
      daily_used: 0,
      daily_remaining: nil,
      daily_paused: false
    }
  end

  defp normalize_epic_lanes(%{lanes: lanes, queued_epics: queued, shared: shared} = epic_lanes) do
    %{
      max_total: Map.get(epic_lanes, :max_total),
      lanes: lanes,
      queued_epics: queued,
      shared: shared
    }
  end

  defp normalize_epic_lanes(_epic_lanes), do: %{max_total: nil, lanes: [], queued_epics: [], shared: %{slots: nil, used: 0}}

  defp normalize_finishing(%{slots: slots, used: used, running: running}), do: %{slots: slots, used: used, running: running}
  defp normalize_finishing(_finishing), do: %{slots: nil, used: 0, running: []}

  defp normalize_qa(%{running: running, queued: queued}), do: %{running: running, queued: queued}
  defp normalize_qa(_qa), do: %{running: [], queued: []}

  defp auto_merge_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.issue_identifier,
      pull_request_url: entry.pr_url,
      state: entry.state,
      head_sha: entry.head_sha,
      status: entry.status,
      updated_at: iso8601(entry.updated_at)
    }
  end

  defp slot_waiting_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      reason: entry.reason,
      attempt: Map.get(entry, :attempt),
      since: iso8601(Map.get(entry, :since)),
      forced: Map.get(entry, :forced, false)
    }
  end

  defp blocked_payload(entry) do
    blockers = Enum.map(entry.blockers, &%{issue_identifier: &1.identifier, state: &1.state})
    reason = Map.get(entry, :reason)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      kind: entry |> Map.get(:kind, :blockers) |> Atom.to_string(),
      reason: reason,
      blocked_by: blockers,
      summary: blocked_summary(entry.identifier, reason, blockers)
    }
  end

  defp blocked_summary(identifier, reason, _blockers) when is_binary(reason), do: "#{identifier} #{reason}"
  defp blocked_summary(identifier, nil, blockers), do: "#{identifier} waiting on " <> Enum.map_join(blockers, ", ", &blocker_label/1)

  # Tickets an app update would release: each one waits only for the running app to include a fix.
  defp app_update_payload(blocked) do
    identifiers = for %{kind: :app_update, identifier: identifier} <- blocked, do: identifier
    %{unblocks: length(identifiers), issue_identifiers: identifiers}
  end

  defp forced_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: entry.title,
      state: entry.state,
      forced_since: iso8601(entry.forced_since),
      position: entry.position,
      waiting_on_human: Map.get(entry, :waiting_on_human, false),
      sub_issue: forced_sub_issue_payload(Map.get(entry, :sub_issue))
    }
  end

  defp forced_sub_issue_payload(%{issue_id: issue_id} = part),
    do: %{issue_id: issue_id, issue_identifier: Map.get(part, :identifier), state: Map.get(part, :state)}

  defp forced_sub_issue_payload(_no_part), do: nil

  defp blocker_label(%{issue_identifier: identifier, state: state}) do
    "#{identifier || "an unknown issue"} (#{state || "unknown state"})"
  end

  defp normalize_dispatch_state(snapshot) when is_map(snapshot) do
    case Map.get(snapshot, :dispatch_state) do
      %{active?: active?, blockers: blockers} when is_list(blockers) ->
        normalized =
          blockers
          |> Enum.map(&normalize_blocker/1)
          |> Enum.reject(&is_nil/1)

        %{active?: active? == true or normalized == [], blockers: normalized}

      _ ->
        synthesize_dispatch_state(snapshot)
    end
  end

  # Backwards-compat fallback for snapshots that don't carry an explicit
  # dispatch_state (older test fixtures or external callers). Derives manual
  # and budget blockers from the legacy pause/budget fields.
  defp synthesize_dispatch_state(snapshot) do
    pause = Map.get(snapshot, :pause)
    budget = Map.get(snapshot, :budget)

    blockers =
      []
      |> maybe_synth_manual(pause)
      |> maybe_synth_budget(budget)
      |> Enum.reverse()

    %{active?: blockers == [], blockers: blockers}
  end

  defp maybe_synth_manual(blockers, %{paused: true} = pause) do
    [
      %{
        kind: :manual,
        reason: Map.get(pause, :reason),
        since: iso8601(Map.get(pause, :paused_at))
      }
      | blockers
    ]
  end

  defp maybe_synth_manual(blockers, _pause), do: blockers

  defp maybe_synth_budget(blockers, %{daily_paused: true} = budget) do
    [
      %{
        kind: :budget,
        used: Map.get(budget, :daily_used, 0),
        limit: Map.get(budget, :daily_limit, 0),
        day_started_on: nil,
        resets_on: nil
      }
      | blockers
    ]
  end

  defp maybe_synth_budget(blockers, _budget), do: blockers

  defp normalize_blocker(%{kind: :manual} = b) do
    %{
      kind: :manual,
      reason: Map.get(b, :reason),
      since: iso8601(Map.get(b, :since))
    }
  end

  defp normalize_blocker(%{kind: :budget} = b) do
    %{
      kind: :budget,
      used: Map.get(b, :used, 0),
      limit: Map.get(b, :limit, 0),
      day_started_on: Map.get(b, :day_started_on),
      resets_on: Map.get(b, :resets_on)
    }
  end

  defp normalize_blocker(%{kind: :missing_api_key} = b) do
    %{kind: :missing_api_key, provider: Map.get(b, :provider)}
  end

  defp normalize_blocker(%{kind: :config_invalid} = b) do
    %{
      kind: :config_invalid,
      message: Map.get(b, :message),
      since: iso8601(Map.get(b, :since)),
      consecutive_failures: Map.get(b, :consecutive_failures, 0)
    }
  end

  defp normalize_blocker(%{kind: :tracker_unavailable} = b) do
    %{
      kind: :tracker_unavailable,
      tracker: Map.get(b, :tracker),
      reason: Map.get(b, :reason),
      since: iso8601(Map.get(b, :since)),
      consecutive_failures: Map.get(b, :consecutive_failures, 0)
    }
  end

  defp normalize_blocker(%{kind: :usage_limit} = b) do
    %{
      kind: :usage_limit,
      provider: Map.get(b, :provider),
      scope: UsageLimit.scope_label(Map.get(b, :scope, :all)),
      window: Map.get(b, :window),
      phase: optional_string(Map.get(b, :phase)),
      resets_at: iso8601(Map.get(b, :resets_at)),
      resume_at: iso8601(Map.get(b, :resume_at))
    }
  end

  defp normalize_blocker(_), do: nil

  defp quality_gate_identifier(entry) do
    Map.get(entry, :identifier) || Map.get(entry, :issue_id) || "unknown"
  end

  defp quality_gate_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp quality_gate_kind(kind) when is_binary(kind), do: kind
  defp quality_gate_kind(_kind), do: "unknown"

  defp quality_gate_error(nil), do: nil
  defp quality_gate_error(error) when is_binary(error), do: error
  defp quality_gate_error(error), do: inspect(error)

  defp workspace_payload(issue_identifier, running, retry) do
    if running || retry do
      %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      }
    end
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Path.expand(Config.settings!().workspace.root), issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp running_transcript_payload(running, repo_key) do
    tokens = transcript_tokens(running)
    reviewer_tokens = transcript_reviewer_tokens(running)

    %{
      repo_key: Map.get(running, :repo_key) || repo_key,
      issue_id: running.issue_id,
      issue_identifier: running.identifier,
      state: running.state,
      session_id: running.session_id,
      started_at: iso8601(running.started_at),
      last_event_at: iso8601(Map.get(running, :last_event_at) || running.last_codex_timestamp),
      turn_count: Map.get(running, :turn_count, 0),
      tokens: tokens,
      executor_tokens: executor_tokens(tokens, reviewer_tokens),
      reviewer_tokens: reviewer_tokens,
      review_agent_enabled: review_agent_enabled?(running, reviewer_tokens),
      events: transcript_events(running)
    }
  end

  defp watching_transcript_payload(watching, repo_key) do
    tokens = transcript_tokens(watching)
    reviewer_tokens = transcript_reviewer_tokens(watching)

    %{
      repo_key: Map.get(watching, :repo_key) || repo_key,
      issue_id: watching.issue_id,
      issue_identifier: watching.identifier,
      state: watching.state,
      session_id: Map.get(watching, :session_id),
      started_at: iso8601(Map.get(watching, :started_at) || Map.get(watching, :last_ran_at)),
      last_event_at: iso8601(Map.get(watching, :last_event_at) || Map.get(watching, :last_ran_at)),
      turn_count: Map.get(watching, :turn_count, 0),
      tokens: tokens,
      executor_tokens: executor_tokens(tokens, reviewer_tokens),
      reviewer_tokens: reviewer_tokens,
      review_agent_enabled: review_agent_enabled?(watching, reviewer_tokens),
      events: transcript_events(watching)
    }
  end

  defp retry_transcript_payload(retry, repo_key) do
    tokens = transcript_tokens(retry)
    reviewer_tokens = transcript_reviewer_tokens(retry)

    %{
      repo_key: Map.get(retry, :repo_key) || repo_key,
      issue_id: retry.issue_id,
      issue_identifier: retry.identifier,
      state: Map.get(retry, :state, "retrying"),
      session_id: Map.get(retry, :session_id),
      started_at: iso8601(Map.get(retry, :started_at)),
      last_event_at: iso8601(Map.get(retry, :last_event_at) || Map.get(retry, :last_ran_at)),
      turn_count: Map.get(retry, :turn_count, 0),
      tokens: tokens,
      executor_tokens: executor_tokens(tokens, reviewer_tokens),
      reviewer_tokens: reviewer_tokens,
      review_agent_enabled: review_agent_enabled?(retry, reviewer_tokens),
      events: transcript_events(retry)
    }
  end

  defp transcript_tokens(%{tokens: tokens}) when is_map(tokens) do
    input_tokens = Map.get(tokens, :input_tokens, 0)
    cached_input_tokens = Map.get(tokens, :cached_input_tokens, 0)
    cache_creation_input_tokens = Map.get(tokens, :cache_creation_input_tokens, 0)
    uncached_input_tokens = Map.get(tokens, :uncached_input_tokens, uncached_input_tokens(input_tokens, cached_input_tokens))

    %{
      input_tokens: uncached_input_tokens + cached_input_tokens + cache_creation_input_tokens,
      uncached_input_tokens: uncached_input_tokens,
      cached_input_tokens: cached_input_tokens,
      cache_creation_input_tokens: cache_creation_input_tokens,
      output_tokens: Map.get(tokens, :output_tokens, 0),
      total_tokens: Map.get(tokens, :total_tokens, 0)
    }
  end

  defp transcript_tokens(entry) when is_map(entry) do
    %{
      input_tokens: entry_input_tokens(entry),
      uncached_input_tokens: entry_uncached_input_tokens(entry),
      cached_input_tokens: entry_cached_input_tokens(entry),
      cache_creation_input_tokens: entry_cache_creation_input_tokens(entry),
      output_tokens: entry_output_tokens(entry),
      total_tokens: entry_total_tokens(entry)
    }
  end

  defp transcript_reviewer_tokens(%{reviewer_tokens: tokens}) when is_map(tokens), do: normalize_token_map(tokens)

  defp transcript_reviewer_tokens(entry) when is_map(entry) do
    %{
      input_tokens: reviewer_input_tokens(entry),
      uncached_input_tokens: reviewer_uncached_input_tokens(entry),
      cached_input_tokens: Map.get(entry, :reviewer_cached_input_tokens, 0),
      cache_creation_input_tokens: Map.get(entry, :reviewer_cache_creation_input_tokens, 0),
      output_tokens: Map.get(entry, :reviewer_output_tokens, 0),
      total_tokens: Map.get(entry, :reviewer_total_tokens, 0)
    }
  end

  defp executor_tokens(tokens, reviewer_tokens) do
    %{
      input_tokens: subtract_token(tokens, reviewer_tokens, :input_tokens),
      uncached_input_tokens: subtract_token(tokens, reviewer_tokens, :uncached_input_tokens),
      cached_input_tokens: subtract_token(tokens, reviewer_tokens, :cached_input_tokens),
      cache_creation_input_tokens: subtract_token(tokens, reviewer_tokens, :cache_creation_input_tokens),
      output_tokens: subtract_token(tokens, reviewer_tokens, :output_tokens),
      total_tokens: subtract_token(tokens, reviewer_tokens, :total_tokens)
    }
  end

  defp subtract_token(tokens, reviewer_tokens, key) do
    max(Map.get(tokens, key, 0) - Map.get(reviewer_tokens, key, 0), 0)
  end

  defp review_agent_enabled?(entry, reviewer_tokens) do
    Map.get(entry, :review_agent_enabled, false) == true or Map.get(reviewer_tokens, :total_tokens, 0) > 0
  end

  defp transcript_payload_from_snapshot(snapshot, repo_key, issue_identifier) do
    case transcript_entry(snapshot, repo_key, issue_identifier) do
      {:running, running} -> {:ok, running_transcript_payload(running, repo_key)}
      {:watching, watching} -> {:ok, watching_transcript_payload(watching, repo_key)}
      {:retry, retry} -> {:ok, retry_transcript_payload(retry, repo_key)}
      nil -> {:error, :issue_not_found}
    end
  end

  defp transcript_entry(snapshot, repo_key, issue_identifier) do
    [
      {:running, Map.get(snapshot, :running, [])},
      {:watching, Map.get(snapshot, :watching, [])},
      {:retry, Map.get(snapshot, :retrying, [])}
    ]
    |> Enum.find_value(fn {kind, entries} ->
      case Enum.find(entries, &transcript_entry_matches?(&1, repo_key, issue_identifier)) do
        nil -> nil
        entry -> {kind, entry}
      end
    end)
  end

  defp transcript_entry_matches?(entry, repo_key, issue_identifier) do
    repo_key_matches?(entry, repo_key) and Map.get(entry, :identifier) == issue_identifier
  end

  defp transcript_events(entry) do
    Quality.transcript_file_events(Map.get(entry, :transcript_path)) ++ buffered_transcript_events(entry)
  end

  defp buffered_transcript_events(%{transcript_buffer: queue}) do
    cond do
      :queue.is_queue(queue) -> :queue.to_list(queue)
      is_list(queue) -> queue
      true -> []
    end
  end

  defp buffered_transcript_events(_entry), do: []

  defp repo_key_matches?(_entry, nil), do: true
  defp repo_key_matches?(entry, repo_key), do: Map.get(entry, :repo_key) == repo_key

  defp current_repo_key, do: Config.repo_key_or_nil()

  # A run waiting out a Linear rate limit or outage has no new agent message to show.
  defp running_message(%{linear_wait_until: %DateTime{}}), do: "waiting for Linear"
  defp running_message(running), do: summarize_message(running.last_codex_message)

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: MessageHumanizer.humanize(message)

  defp entry_uncached_input_tokens(entry) when is_map(entry) do
    case Map.get(entry, :uncached_input_tokens) do
      value when is_integer(value) -> max(value, 0)
      _ -> uncached_input_tokens(Map.get(entry, :codex_input_tokens, 0), Map.get(entry, :codex_cached_input_tokens, 0))
    end
  end

  defp entry_input_tokens(entry) when is_map(entry) do
    if Map.has_key?(entry, :uncached_input_tokens) do
      entry_uncached_input_tokens(entry) + entry_cached_input_tokens(entry) + entry_cache_creation_input_tokens(entry)
    else
      max(Map.get(entry, :codex_input_tokens, 0), 0)
    end
  end

  defp entry_cached_input_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :cached_input_tokens, Map.get(entry, :codex_cached_input_tokens, 0)), 0)

  defp entry_cache_creation_input_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :cache_creation_input_tokens, Map.get(entry, :codex_cache_creation_input_tokens, 0)), 0)

  defp entry_output_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :output_tokens, Map.get(entry, :codex_output_tokens, 0)), 0)

  defp entry_total_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :total_tokens, Map.get(entry, :codex_total_tokens, 0)), 0)

  defp reviewer_uncached_input_tokens(entry) when is_map(entry) do
    case Map.get(entry, :reviewer_uncached_input_tokens) do
      value when is_integer(value) -> max(value, 0)
      _ -> uncached_input_tokens(Map.get(entry, :reviewer_input_tokens, 0), Map.get(entry, :reviewer_cached_input_tokens, 0))
    end
  end

  defp reviewer_input_tokens(entry) when is_map(entry) do
    if Map.has_key?(entry, :reviewer_uncached_input_tokens) do
      reviewer_uncached_input_tokens(entry) + Map.get(entry, :reviewer_cached_input_tokens, 0) +
        Map.get(entry, :reviewer_cache_creation_input_tokens, 0)
    else
      max(Map.get(entry, :reviewer_input_tokens, 0), 0)
    end
  end

  defp uncached_input_tokens(input_tokens, cached_input_tokens) when is_integer(input_tokens) and is_integer(cached_input_tokens) do
    max(input_tokens - cached_input_tokens, 0)
  end

  defp uncached_input_tokens(_input_tokens, _cached_input_tokens), do: 0

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
