defmodule SymphonyElixir.AuditLog do
  @moduledoc """
  Append-only audit log for agent side effects.

  Audit entries are stored as daily NDJSON files. Each record carries a
  `previous_hash` and `record_hash` so operators can verify whether a file was
  edited after the fact.
  """

  require Logger

  alias SymphonyElixir.{Config, Paths, Secret}

  @redacted "[REDACTED]"
  @preview_chars 500
  @result_preview_chars 500
  @tail_chunk_bytes 65_536
  @common_secret_envs [
    "LINEAR_API_KEY",
    "LINEAR_ASSIGNEE",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "SLACK_WEBHOOK_URL",
    "WEBHOOK_URL"
  ]

  @type event_attrs :: map()
  @type query_opts :: keyword()
  @type verify_break ::
          :invalid_date
          | {:invalid_record, line :: pos_integer(), reason :: term()}
          | {:chain_break, %{line: pos_integer(), record_hash: String.t() | nil}}

  @spec default_dir(Path.t()) :: Path.t()
  def default_dir(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, "audit")
  end

  @spec audit_dir(keyword() | map()) :: Path.t()
  def audit_dir(opts \\ []) do
    query_value(opts, [:dir, "dir"]) ||
      Application.get_env(:symphony_elixir, :audit_log_dir) ||
      Paths.audit_dir()
  end

  @doc """
  Format a value for Logger output after applying the same configured secret
  redaction used by audit entries.
  """
  @spec redact_for_log(term(), keyword()) :: String.t()
  def redact_for_log(value, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    printable_limit = Keyword.get(opts, :printable_limit, 1_000)

    value
    |> redact_value(configured_secret_values(opts))
    |> inspect(limit: limit, printable_limit: printable_limit)
  end

  @spec set_dir(Path.t()) :: :ok
  def set_dir(dir) when is_binary(dir) do
    Application.put_env(:symphony_elixir, :audit_log_dir, Path.expand(dir))
    :ok
  end

  @spec record(event_attrs(), keyword()) :: :ok | {:error, term()}
  def record(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, event} <- build_event(attrs, opts) do
      append_event(event, opts)
    end
  end

  @spec record_prompt_sent(map(), String.t() | nil, String.t(), keyword()) ::
          :ok | {:error, term()}
  def record_prompt_sent(issue, run_id, prompt, opts \\ [])
      when is_map(issue) and is_binary(prompt) do
    secrets = configured_secret_values(opts)
    preview = prompt |> redact_string(secrets) |> String.slice(0, @preview_chars)

    record(
      %{
        repo_key: repo_key(issue, opts),
        issue_id: issue_id(issue),
        issue_identifier: issue_identifier(issue),
        run_id: run_id,
        event_type: "prompt_sent",
        prompt_hash: sha256(prompt),
        prompt_preview: preview,
        prompt_preview_truncated: String.length(prompt) > @preview_chars,
        turn_number: Keyword.get(opts, :turn_number),
        max_turns: Keyword.get(opts, :max_turns),
        agent: Keyword.get(opts, :agent)
      },
      opts
    )
  end

  @spec record_agent_update(map(), map(), map()) :: :ok | {:error, term()}
  def record_agent_update(running_entry, update, token_delta)
      when is_map(running_entry) and is_map(update) and is_map(token_delta) do
    running_entry
    |> audit_events_from_update(update, token_delta)
    |> record_many()
  end

  @spec record_pr_opened(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def record_pr_opened(running_entry, pr_url, opts \\ [])
      when is_map(running_entry) and is_binary(pr_url) do
    record(
      running_entry
      |> base_event("pr_opened", update_timestamp(Keyword.get(opts, :timestamp)))
      |> Map.merge(%{
        pr: parse_pr_url(pr_url),
        url: pr_url,
        action: "opened"
      }),
      opts
    )
  end

  @spec record_refused_agent_action(map(), event_attrs(), keyword()) :: :ok | {:error, term()}
  def record_refused_agent_action(issue, attrs, opts \\ [])
      when is_map(issue) and is_map(attrs) do
    record(
      attrs
      |> normalize_value()
      |> Map.merge(%{
        repo_key: repo_key(issue, opts),
        issue_id: issue_id(issue),
        issue_identifier: issue_identifier(issue),
        run_id: Keyword.get(opts, :run_id),
        event_type: "refused_agent_action"
      }),
      opts
    )
  end

  @spec record_linear_state_transition(map(), map(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def record_linear_state_transition(previous_issue, refreshed_issue, run_id, opts \\ [])
      when is_map(previous_issue) and is_map(refreshed_issue) do
    from_state = issue_state(previous_issue)
    to_state = issue_state(refreshed_issue)

    if present?(from_state) and present?(to_state) and from_state != to_state do
      record(
        %{
          repo_key: transition_repo_key(previous_issue, refreshed_issue, opts),
          issue_id: issue_id(refreshed_issue) || issue_id(previous_issue),
          issue_identifier: issue_identifier(refreshed_issue) || issue_identifier(previous_issue),
          run_id: run_id,
          event_type: "linear_state_change",
          action: "observed_state_transition",
          from_state: from_state,
          to_state: to_state,
          source: Keyword.get(opts, :source, "issue_refresh")
        },
        opts
      )
    else
      :ok
    end
  end

  @spec list_events(String.t(), Date.t() | String.t(), Date.t() | String.t(), query_opts()) ::
          {:ok, [map()]} | {:error, term()}
  def list_events(issue_id, date_from, date_to, opts \\ []) when is_binary(issue_id) do
    opts =
      opts
      |> Keyword.put(:date_from, date_from)
      |> Keyword.put(:date_to, date_to)
      |> Keyword.put(:issue_id, issue_id)

    with {:ok, events} <- query(opts) do
      {:ok, events |> Enum.to_list() |> Enum.sort_by(&timestamp_sort_key/1)}
    end
  end

  @doc """
  Streams redacted audit events for an inclusive date range and optional filters.

  Accepts either a keyword list or a map; atom and string keys are both honored.

  Options:

    * `:from` / `:date_from` — inclusive start date (`Date` or ISO-8601). Defaults to today.
    * `:to` / `:date_to` — inclusive end date. Defaults to `:from`.
    * `:cursor` — pagination cursor `"YYYY-MM-DD:<record_hash>"` or `{Date.t(), record_hash}`;
      events strictly after the cursor are emitted, positioned by raw file order so
      the cursor remains valid across filter changes.
    * `:since` — ISO-8601 timestamp or `DateTime`; only events at/after it are emitted.
    * `:limit` — positive integer cap on emitted events.
    * `:repo_key` / `:repo`, `:issue`, `:issue_id`, `:issue_identifier`,
      `:event_type` / `:type`, `:run_id` — exact-match filters.
    * `:dir` — audit log directory override.

  Returns `{:ok, Enumerable.t()}` or `{:error, reason}` where `reason` is
  `:invalid_date`, `:invalid_cursor`, `:invalid_since`, `:invalid_limit`, or
  `:invalid_date_range`.
  """
  @spec query(query_opts() | map()) :: {:ok, Enumerable.t()} | {:error, term()}
  def query(opts \\ []) when is_list(opts) or is_map(opts) do
    today = Date.utc_today()

    with {:ok, from_date} <- normalize_date(query_value(opts, [:from, :date_from, "from", "date_from"]) || today),
         {:ok, to_date} <- normalize_date(query_value(opts, [:to, :date_to, "to", "date_to"]) || from_date),
         :ok <- validate_date_range(from_date, to_date),
         {:ok, cursor} <- normalize_cursor(query_value(opts, [:cursor, "cursor"])),
         {:ok, since} <- normalize_timestamp(query_value(opts, [:since, "since"])),
         {:ok, limit} <- normalize_limit(query_value(opts, [:limit, "limit"])) do
      filters = query_filters(opts)
      secrets = configured_secret_values(query_keyword_opts(opts))

      stream =
        from_date
        |> Date.range(to_date)
        |> Stream.flat_map(&stream_events_for_date(&1, opts))
        |> apply_cursor(cursor)
        |> Stream.map(&redact_value(&1, secrets))
        |> Stream.filter(&event_matches_filters?(&1, filters))
        |> Stream.filter(&event_since?(&1, since))
        |> apply_limit(limit)

      {:ok, stream}
    end
  end

  @doc """
  Verifies the hash chain for one daily audit file.

  `day` is a `Date` or ISO-8601 string. Options are forwarded to `audit_dir/1`
  (e.g. `:dir` to override the audit log directory).

  Returns `:ok` when every record's `previous_hash` and `record_hash` match the
  recomputed chain. A non-existent or empty file is also reported as `:ok` —
  there is nothing to verify. On failure, returns one of:

    * `{:error, :invalid_date}` — `day` could not be parsed.
    * `{:error, {:invalid_record, line, reason}}` — a line could not be parsed
      as a JSON object.
    * `{:error, {:chain_break, %{line: pos_integer(), record_hash: String.t() | nil}}}`
      — `previous_hash` or `record_hash` did not match the recomputed chain.
  """
  @spec verify_chain(Date.t() | String.t(), query_opts() | map()) ::
          :ok | {:error, verify_break()}
  def verify_chain(day, opts \\ []) do
    case normalize_date(day) do
      {:ok, date} ->
        opts
        |> audit_dir()
        |> event_path(Date.to_iso8601(date))
        |> read_ndjson_lines()
        |> verify_chain_lines(nil)

      _ ->
        {:error, :invalid_date}
    end
  end

  @spec verify_file(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def verify_file(path) when is_binary(path) do
    path
    |> read_ndjson_lines()
    |> verify_lines(nil, 1, 0)
  end

  defp build_event(attrs, opts) do
    timestamp =
      attrs
      |> Map.get(:timestamp, Map.get(attrs, "timestamp", Keyword.get(opts, :timestamp)))
      |> update_timestamp()

    event_type = attrs |> Map.get(:event_type, Map.get(attrs, "event_type")) |> normalize_event_type()

    if is_nil(event_type) do
      {:error, :missing_event_type}
    else
      event =
        attrs
        |> normalize_value()
        |> put_repo_key(repo_key(attrs, opts))
        |> Map.put_new("timestamp", DateTime.to_iso8601(timestamp))
        |> Map.put("event_type", event_type)
        |> Map.put_new("date", timestamp |> DateTime.to_date() |> Date.to_iso8601())
        |> redact_value(configured_secret_values(opts))

      {:ok, event}
    end
  end

  defp append_event(event, opts) do
    dir = audit_dir(opts)
    path = event_path(dir, Map.fetch!(event, "date"))

    :global.trans({__MODULE__, path}, fn ->
      with :ok <- File.mkdir_p(Path.dirname(path)) do
        previous_hash = last_record_hash(path)

        event_with_chain =
          event
          |> Map.put("previous_hash", previous_hash)
          |> drop_nil_values()

        record_hash = hash_event(event_with_chain)
        encoded_event = Map.put(event_with_chain, "record_hash", record_hash)

        File.write(path, Jason.encode!(encoded_event) <> "\n", [:append])
      end
    end)
  rescue
    exception ->
      {:error, {:audit_log_write_failed, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:audit_log_write_failed, {kind, reason}}}
  end

  defp record_many(events) when is_list(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case record(event) do
        :ok ->
          {:cont, :ok}

        {:error, reason} = error ->
          Logger.warning("Audit log write failed: #{inspect(reason)}")
          {:halt, error}
      end
    end)
  end

  defp audit_events_from_update(running_entry, update, token_delta) do
    timestamp = update_timestamp(Map.get(update, :timestamp) || Map.get(update, "timestamp"))
    payload = update_payload(update)

    []
    |> maybe_add_tool_call_event(running_entry, update, payload, timestamp)
    |> maybe_add_file_change_event(running_entry, payload, timestamp)
    |> maybe_add_token_delta_event(running_entry, token_delta, timestamp)
  end

  defp maybe_add_tool_call_event(events, running_entry, update, payload, timestamp) do
    cond do
      dynamic_tool_event?(update) ->
        tool_event = dynamic_tool_event(running_entry, update, payload, timestamp)
        events ++ tool_event ++ linear_side_effect_events(running_entry, tool_event, update, timestamp)

      command_event?(payload) ->
        events ++ [command_tool_event(running_entry, payload, timestamp)]

      true ->
        events
    end
  end

  defp dynamic_tool_event(running_entry, update, payload, timestamp) do
    params = payload_params(payload)
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)
    result = Map.get(update, :result) || Map.get(update, "result") || %{}

    [
      running_entry
      |> base_event("tool_call", timestamp)
      |> Map.merge(%{
        command: tool_name,
        args: arguments,
        tool_name: tool_name,
        tool_kind: "dynamic",
        status: dynamic_tool_status(update),
        result_success: result_success?(result),
        result_preview: result_preview(result)
      })
    ]
  end

  defp linear_side_effect_events(running_entry, [tool_event], update, timestamp) do
    if Map.get(tool_event, :tool_name) == "linear_graphql" or Map.get(tool_event, "tool_name") == "linear_graphql" do
      result = Map.get(update, :result) || Map.get(update, "result") || %{}

      if result_success?(result) do
        linear_graphql_events(running_entry, Map.get(tool_event, :args) || Map.get(tool_event, "args"), result, timestamp)
      else
        []
      end
    else
      []
    end
  end

  defp linear_side_effect_events(_running_entry, _tool_events, _update, _timestamp), do: []

  defp command_tool_event(running_entry, payload, timestamp) do
    command = command_from_payload(payload)
    args = command_args_from_payload(payload)

    running_entry
    |> base_event("tool_call", timestamp)
    |> Map.merge(%{
      command: command,
      args: args,
      tool_kind: "command",
      method: payload_method(payload),
      cwd: get_in(payload, ["params", "cwd"])
    })
  end

  defp maybe_add_file_change_event(events, running_entry, payload, timestamp) do
    if file_change_event?(payload) do
      events ++ [file_change_event(running_entry, payload, timestamp)]
    else
      events
    end
  end

  defp file_change_event(running_entry, payload, timestamp) do
    params = payload_params(payload)
    diff = Map.get(params, "diff") || Map.get(params, :diff)
    paths = file_change_paths(params, diff)

    running_entry
    |> base_event("file_change", timestamp)
    |> Map.merge(%{
      method: payload_method(payload),
      paths: paths,
      diff_stats: diff_stats(diff, paths),
      file_change_count: Map.get(params, "fileChangeCount") || Map.get(params, :fileChangeCount)
    })
  end

  defp maybe_add_token_delta_event(events, running_entry, token_delta, timestamp) do
    if token_delta?(token_delta) do
      events ++
        [
          running_entry
          |> base_event("token_usage_delta", timestamp)
          |> Map.merge(%{
            token_usage_delta:
              Map.take(token_delta, [
                :input_tokens,
                :uncached_input_tokens,
                :cached_input_tokens,
                :cache_creation_input_tokens,
                :output_tokens,
                :total_tokens
              ]),
            token_usage_reported:
              Map.take(token_delta, [
                :input_reported,
                :uncached_input_reported,
                :cached_input_reported,
                :cache_creation_input_reported,
                :output_reported,
                :total_reported
              ])
          })
        ]
    else
      events
    end
  end

  defp base_event(running_entry, event_type, timestamp) do
    issue = Map.get(running_entry, :issue) || %{}

    %{
      repo_key: Map.get(running_entry, :repo_key) || repo_key_from_issue(issue) || default_repo_key(),
      issue_id: issue_id(issue) || Map.get(running_entry, :issue_id),
      issue_identifier: issue_identifier(issue) || Map.get(running_entry, :identifier),
      run_id: Map.get(running_entry, :run_id),
      session_id: Map.get(running_entry, :session_id),
      event_type: event_type,
      timestamp: timestamp
    }
  end

  defp linear_graphql_events(running_entry, arguments, result, timestamp) do
    query = linear_query(arguments)
    variables = linear_variables(arguments)
    output = result_output(result)

    cond do
      contains_graphql_operation?(query, "commentCreate") ->
        [
          running_entry
          |> base_event("linear_comment", timestamp)
          |> Map.merge(%{
            action: "created",
            linear_issue_id: Map.get(variables, "issueId"),
            comment_id: get_in(output, ["data", "commentCreate", "comment", "id"]),
            comment_url: get_in(output, ["data", "commentCreate", "comment", "url"])
          })
        ]

      contains_graphql_operation?(query, "commentUpdate") ->
        [
          running_entry
          |> base_event("linear_comment", timestamp)
          |> Map.merge(%{
            action: "updated",
            comment_id: Map.get(variables, "id") || get_in(output, ["data", "commentUpdate", "comment", "id"])
          })
        ]

      contains_graphql_operation?(query, "issueUpdate") ->
        [
          running_entry
          |> base_event("linear_state_change", timestamp)
          |> Map.merge(%{
            action: "updated",
            linear_issue_id: Map.get(variables, "id") || Map.get(variables, "issueId"),
            from_state: nil,
            to_state: get_in(output, ["data", "issueUpdate", "issue", "state", "name"]),
            to_state_id: Map.get(variables, "stateId")
          })
        ]

      contains_graphql_operation?(query, "attachmentLinkGitHubPR") ->
        pr_url = Map.get(variables, "url")

        [
          running_entry
          |> base_event("pr_opened", timestamp)
          |> Map.merge(%{
            action: "linked",
            url: pr_url,
            pr: parse_pr_url(pr_url)
          })
        ]

      true ->
        []
    end
  end

  defp dynamic_tool_event?(%{event: event}) when event in [:tool_call_completed, :tool_call_failed, :unsupported_tool_call],
    do: true

  defp dynamic_tool_event?(_update), do: false

  defp dynamic_tool_status(%{event: :tool_call_completed}), do: "completed"
  defp dynamic_tool_status(%{event: :tool_call_failed}), do: "failed"
  defp dynamic_tool_status(%{event: :unsupported_tool_call}), do: "unsupported"
  defp dynamic_tool_status(_update), do: "unknown"

  defp command_event?(payload) do
    payload_method(payload) in [
      "item/commandExecution/requestApproval",
      "execCommandApproval",
      "codex/event/exec_command_begin"
    ] || command_execution_item?(payload)
  end

  defp file_change_event?(payload) do
    payload_method(payload) in [
      "turn/diff/updated",
      "item/fileChange/requestApproval"
    ] || file_change_item?(payload)
  end

  defp command_execution_item?(payload) do
    payload
    |> get_in(["params", "item", "type"])
    |> case do
      "commandExecution" -> true
      "command_execution" -> true
      _ -> false
    end
  end

  defp file_change_item?(payload) do
    payload
    |> get_in(["params", "item", "type"])
    |> case do
      "fileChange" -> true
      "file_change" -> true
      _ -> false
    end
  end

  defp token_delta?(token_delta) when is_map(token_delta) do
    Enum.any?([:input_tokens, :uncached_input_tokens, :cached_input_tokens, :cache_creation_input_tokens, :output_tokens, :total_tokens], fn key ->
      value = Map.get(token_delta, key, 0)
      is_integer(value) and value > 0
    end)
  end

  defp update_payload(update) do
    case Map.get(update, :payload) || Map.get(update, "payload") do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp payload_method(payload) when is_map(payload), do: Map.get(payload, "method") || Map.get(payload, :method)

  defp payload_params(payload) when is_map(payload) do
    case Map.get(payload, "params") || Map.get(payload, :params) do
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        name |> String.trim() |> blank_to_nil()

      _ ->
        nil
    end
  end

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp command_from_payload(payload) do
    [
      ["params", "parsedCmd"],
      ["params", "command"],
      ["params", "cmd"],
      ["params", "argv"],
      ["params", "args"],
      ["params", "item", "command"],
      ["params", "item", "parsedCmd"],
      ["params", "msg", "command"],
      ["params", "msg", "parsed_cmd"],
      ["params", "msg", "payload", "command"],
      ["params", "msg", "payload", "parsed_cmd"]
    ]
    |> Enum.find_value(&get_in(payload, &1))
    |> normalize_command()
  end

  defp command_args_from_payload(payload) do
    [
      ["params", "argv"],
      ["params", "args"],
      ["params", "item", "argv"],
      ["params", "item", "args"],
      ["params", "msg", "argv"],
      ["params", "msg", "args"]
    ]
    |> Enum.find_value(&get_in(payload, &1))
    |> normalize_args()
  end

  defp normalize_command(%{} = command) do
    binary_command = command["parsedCmd"] || command["command"] || command["cmd"]
    args = command["args"] || command["argv"]

    if is_binary(binary_command) and is_list(args) do
      normalize_command([binary_command | args])
    else
      normalize_command(binary_command || args)
    end
  end

  defp normalize_command(command) when is_binary(command) do
    command
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> blank_to_nil()
  end

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1), do: normalize_command(Enum.join(command, " ")), else: nil
  end

  defp normalize_command(_command), do: nil

  defp normalize_args(args) when is_list(args), do: Enum.map(args, &normalize_value/1)
  defp normalize_args(_args), do: []

  defp file_change_paths(params, diff) do
    params
    |> explicit_file_paths()
    |> Kernel.++(paths_from_diff(diff))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp explicit_file_paths(params) when is_map(params) do
    ["files", "paths", "changes"]
    |> Enum.flat_map(fn key -> paths_from_value(Map.get(params, key) || Map.get(params, String.to_atom(key))) end)
  end

  defp paths_from_value(values) when is_list(values), do: Enum.flat_map(values, &paths_from_value/1)
  defp paths_from_value(%{"path" => path}) when is_binary(path), do: [path]
  defp paths_from_value(%{path: path}) when is_binary(path), do: [path]
  defp paths_from_value(path) when is_binary(path), do: [path]
  defp paths_from_value(_value), do: []

  defp paths_from_diff(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      cond do
        String.starts_with?(line, "diff --git ") ->
          line
          |> String.split()
          |> Enum.drop(2)
          |> Enum.map(&strip_diff_prefix/1)

        String.starts_with?(line, "+++ ") or String.starts_with?(line, "--- ") ->
          line
          |> String.split()
          |> Enum.drop(1)
          |> Enum.map(&strip_diff_prefix/1)

        true ->
          []
      end
    end)
    |> Enum.reject(&(&1 in [nil, "/dev/null"]))
    |> Enum.uniq()
  end

  defp paths_from_diff(_diff), do: []

  defp strip_diff_prefix("a/" <> path), do: path
  defp strip_diff_prefix("b/" <> path), do: path
  defp strip_diff_prefix(path), do: path

  defp diff_stats(diff, paths) when is_binary(diff) do
    lines = String.split(diff, "\n")

    %{
      files_changed: length(paths),
      additions: Enum.count(lines, &(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++"))),
      deletions: Enum.count(lines, &(String.starts_with?(&1, "-") and not String.starts_with?(&1, "---")))
    }
  end

  defp diff_stats(_diff, paths), do: %{files_changed: length(paths), additions: nil, deletions: nil}

  defp linear_query(%{"query" => query}) when is_binary(query), do: query
  defp linear_query(%{query: query}) when is_binary(query), do: query
  defp linear_query(query) when is_binary(query), do: query
  defp linear_query(_arguments), do: nil

  defp linear_variables(%{"variables" => variables}) when is_map(variables), do: normalize_value(variables)
  defp linear_variables(%{variables: variables}) when is_map(variables), do: normalize_value(variables)
  defp linear_variables(_arguments), do: %{}

  defp contains_graphql_operation?(query, operation) when is_binary(query) do
    String.contains?(query, operation)
  end

  defp contains_graphql_operation?(_query, _operation), do: false

  defp result_success?(%{"success" => success}) when is_boolean(success), do: success
  defp result_success?(%{success: success}) when is_boolean(success), do: success
  defp result_success?(_result), do: nil

  defp result_preview(result) when is_map(result) do
    result
    |> result_output_text()
    |> String.slice(0, @result_preview_chars)
  end

  defp result_output(%{"output" => output}) when is_binary(output), do: decode_json_or_empty(output)
  defp result_output(%{output: output}) when is_binary(output), do: decode_json_or_empty(output)
  defp result_output(_result), do: %{}

  defp result_output_text(%{"output" => output}) when is_binary(output), do: output
  defp result_output_text(%{output: output}) when is_binary(output), do: output
  defp result_output_text(result) when is_map(result), do: Jason.encode!(normalize_value(result))

  defp decode_json_or_empty(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp parse_pr_url(url) when is_binary(url) do
    case Regex.run(~r{^https?://[^/]+/([^/\s]+)/([^/\s]+)/pull/(\d+)(?:$|[/?#])}, url) do
      [_full, owner, repo, number] ->
        %{
          repo: "#{owner}/#{repo}",
          number: String.to_integer(number),
          url: url
        }

      _ ->
        %{url: url}
    end
  end

  defp parse_pr_url(_url), do: nil

  defp issue_id(%{id: id}) when is_binary(id), do: id
  defp issue_id(%{"id" => id}) when is_binary(id), do: id
  defp issue_id(%{issue_id: id}) when is_binary(id), do: id
  defp issue_id(%{"issue_id" => id}) when is_binary(id), do: id
  defp issue_id(_issue), do: nil

  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(%{"identifier" => identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(%{issue_identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(%{"issue_identifier" => identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: nil

  defp repo_key(issue, opts) when is_list(opts) do
    present_string(Keyword.get(opts, :repo_key)) || repo_key_from_issue(issue) || default_repo_key()
  end

  defp transition_repo_key(previous_issue, refreshed_issue, opts) when is_list(opts) do
    present_string(Keyword.get(opts, :repo_key)) ||
      repo_key_from_issue(refreshed_issue) ||
      repo_key_from_issue(previous_issue) ||
      default_repo_key()
  end

  defp repo_key_from_issue(%{repo_key: repo_key}) when is_binary(repo_key), do: present_string(repo_key)
  defp repo_key_from_issue(%{"repo_key" => repo_key}) when is_binary(repo_key), do: present_string(repo_key)
  defp repo_key_from_issue(_issue), do: nil

  defp issue_state(%{state: state}) when is_binary(state), do: state
  defp issue_state(%{"state" => state}) when is_binary(state), do: state
  defp issue_state(_issue), do: nil

  defp put_repo_key(event, repo_key) when is_map(event) do
    case present_string(Map.get(event, "repo_key")) || present_string(repo_key) do
      nil -> event
      present_repo_key -> Map.put(event, "repo_key", present_repo_key)
    end
  end

  defp default_repo_key, do: Config.repo_key_or_nil()

  defp stream_events_for_date(date, opts) do
    path =
      opts
      |> audit_dir()
      |> event_path(Date.to_iso8601(date))

    if File.exists?(path) do
      path
      |> File.stream!(:line, read_ahead: 64 * 1_024)
      |> Stream.with_index(1)
      |> Stream.flat_map(&decode_streamed_event/1)
    else
      []
    end
  end

  defp decode_streamed_event({line, _line_number}) do
    case line |> String.trim() |> decode_json_line() do
      %{} = event -> [event]
      _ -> []
    end
  end

  defp query_keyword_opts(opts) when is_list(opts), do: opts
  defp query_keyword_opts(opts) when is_map(opts), do: Map.to_list(opts)

  defp query_value(opts, keys) do
    Enum.find_value(keys, fn key ->
      case fetch_query_value(opts, key) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp fetch_query_value(opts, key) when is_list(opts) do
    case List.keyfind(opts, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  defp fetch_query_value(opts, key) when is_map(opts), do: Map.get(opts, key)

  defp query_filters(opts) do
    %{
      repo_key: query_value(opts, [:repo_key, :repo, "repo_key", "repo"]),
      issue: query_value(opts, [:issue, "issue"]),
      issue_id: query_value(opts, [:issue_id, "issue_id"]),
      issue_identifier: query_value(opts, [:issue_identifier, "issue_identifier"]),
      event_type: query_value(opts, [:event_type, :type, "event_type", "type"]),
      run_id: query_value(opts, [:run_id, "run_id"])
    }
  end

  defp event_matches_filters?(event, filters) do
    repo_matches?(event, filters.repo_key) and
      issue_matches?(event, filters) and
      field_matches?(event, "event_type", filters.event_type) and
      field_matches?(event, "run_id", filters.run_id)
  end

  defp repo_matches?(_event, value) when value in [nil, ""], do: true
  defp repo_matches?(event, value), do: Map.get(event, "repo_key") == value

  defp issue_matches?(event, %{issue: issue}) when is_binary(issue) and issue != "" do
    Map.get(event, "issue_id") == issue or Map.get(event, "issue_identifier") == issue
  end

  defp issue_matches?(event, filters) do
    field_matches?(event, "issue_id", filters.issue_id) and
      field_matches?(event, "issue_identifier", filters.issue_identifier)
  end

  defp field_matches?(_event, _field, value) when value in [nil, ""], do: true
  defp field_matches?(event, field, value), do: Map.get(event, field) == value

  defp event_since?(_event, nil), do: true

  defp event_since?(event, %DateTime{} = since) do
    case DateTime.from_iso8601(Map.get(event, "timestamp", "")) do
      {:ok, timestamp, _offset} -> DateTime.compare(timestamp, since) != :lt
      _ -> false
    end
  end

  defp apply_cursor(stream, nil), do: stream

  defp apply_cursor(stream, {%Date{} = date, record_hash}) when is_binary(record_hash) do
    date_string = Date.to_iso8601(date)

    Stream.transform(stream, false, fn event, cursor_seen? ->
      event_date = Map.get(event, "date")

      cond do
        cursor_seen? ->
          {[event], true}

        is_binary(event_date) and event_date > date_string ->
          {[event], true}

        event_date == date_string and Map.get(event, "record_hash") == record_hash ->
          {[], true}

        true ->
          {[], false}
      end
    end)
  end

  defp apply_limit(stream, nil), do: stream
  defp apply_limit(stream, limit) when is_integer(limit), do: Stream.take(stream, limit)

  defp normalize_cursor(nil), do: {:ok, nil}

  defp normalize_cursor({date, record_hash}) when is_binary(record_hash) do
    with {:ok, normalized_date} <- normalize_date(date) do
      {:ok, {normalized_date, record_hash}}
    end
  end

  defp normalize_cursor(cursor) when is_binary(cursor) do
    case String.split(cursor, [":", ","], parts: 2) do
      [date, record_hash] when record_hash != "" -> normalize_cursor({date, record_hash})
      _ -> {:error, :invalid_cursor}
    end
  end

  defp normalize_cursor(_cursor), do: {:error, :invalid_cursor}

  defp normalize_timestamp(nil), do: {:ok, nil}
  defp normalize_timestamp(%DateTime{} = timestamp), do: {:ok, timestamp}

  defp normalize_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      _ -> {:error, :invalid_since}
    end
  end

  defp normalize_timestamp(_timestamp), do: {:error, :invalid_since}

  defp normalize_limit(nil), do: {:ok, nil}
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_limit}
    end
  end

  defp normalize_limit(_limit), do: {:error, :invalid_limit}

  defp read_ndjson_lines(path) do
    if File.exists?(path) do
      path
      |> File.stream!(:line, [])
      |> Stream.with_index(1)
      |> Enum.map(fn {line, line_number} ->
        decoded =
          line
          |> String.trim()
          |> decode_json_line()

        {line_number, decoded}
      end)
    else
      []
    end
  rescue
    exception ->
      [{0, {:error, {:read_failed, Exception.message(exception)}}}]
  end

  defp decode_json_line(""), do: nil

  defp decode_json_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> decoded
      {:error, reason} -> {:error, {:decode_failed, reason}}
    end
  end

  defp verify_lines([], _previous_hash, _line_number, count), do: {:ok, count}

  defp verify_lines([{line_number, {:error, reason}} | _rest], _previous_hash, _next_line_number, _count) do
    {:error, {:invalid_record, line_number, reason}}
  end

  defp verify_lines([{line_number, event} | rest], previous_hash, _next_line_number, count) when is_map(event) do
    stored_hash = Map.get(event, "record_hash")
    stored_previous_hash = Map.get(event, "previous_hash")
    calculated_hash = event |> Map.delete("record_hash") |> hash_event()

    cond do
      stored_previous_hash != previous_hash ->
        {:error, {:chain_mismatch, line_number}}

      stored_hash != calculated_hash ->
        {:error, {:hash_mismatch, line_number}}

      true ->
        verify_lines(rest, stored_hash, line_number + 1, count + 1)
    end
  end

  defp verify_lines([{line_number, _event} | _rest], _previous_hash, _next_line_number, _count) do
    {:error, {:invalid_record, line_number, :not_a_json_object}}
  end

  defp verify_chain_lines([], _previous_hash), do: :ok

  defp verify_chain_lines([{line_number, {:error, reason}} | _rest], _previous_hash) do
    {:error, {:invalid_record, line_number, reason}}
  end

  defp verify_chain_lines([{line_number, event} | rest], previous_hash) when is_map(event) do
    stored_hash = Map.get(event, "record_hash")
    stored_previous_hash = Map.get(event, "previous_hash")
    calculated_hash = event |> Map.delete("record_hash") |> hash_event()

    cond do
      stored_previous_hash != previous_hash ->
        {:error, {:chain_break, %{line: line_number, record_hash: stored_hash}}}

      stored_hash != calculated_hash ->
        {:error, {:chain_break, %{line: line_number, record_hash: stored_hash}}}

      true ->
        verify_chain_lines(rest, stored_hash)
    end
  end

  defp verify_chain_lines([{line_number, _event} | _rest], _previous_hash) do
    {:error, {:invalid_record, line_number, :not_a_json_object}}
  end

  # Reads the day's file backwards from its end, a chunk at a time, so a write costs the same at
  # the end of a busy day as at its start: decoding the whole file took seconds per event once it
  # reached tens of MB, with the `:global` lock held.
  defp last_record_hash(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          {:ok, size} = :file.position(io, :eof)
          tail_record_hash(io, size, "")
        after
          File.close(io)
        end

      {:error, _reason} ->
        nil
    end
  end

  defp tail_record_hash(io, position, partial_line) do
    start = max(position - @tail_chunk_bytes, 0)
    {:ok, chunk} = :file.pread(io, start, position - start)
    [first | complete] = String.split(chunk <> partial_line, "\n")
    lines = if start == 0, do: [first | complete], else: complete

    case lines |> Enum.reverse() |> Enum.find_value(&line_record_hash/1) do
      nil when start > 0 -> tail_record_hash(io, start, first)
      hash -> hash
    end
  end

  defp line_record_hash(line) do
    case line |> String.trim() |> decode_json_line() do
      %{} = event -> Map.get(event, "record_hash")
      _not_event -> nil
    end
  end

  defp normalize_event_type(event_type) when is_atom(event_type), do: Atom.to_string(event_type)

  defp normalize_event_type(event_type) when is_binary(event_type) do
    event_type
    |> String.trim()
    |> blank_to_nil()
  end

  defp normalize_event_type(_event_type), do: nil

  defp normalize_date(%Date{} = date), do: {:ok, date}

  defp normalize_date(date) when is_binary(date) do
    Date.from_iso8601(date)
  end

  defp normalize_date(_date), do: {:error, :invalid_date}

  defp validate_date_range(from_date, to_date) do
    if Date.compare(from_date, to_date) == :gt do
      {:error, :invalid_date_range}
    else
      :ok
    end
  end

  defp update_timestamp(%DateTime{} = timestamp), do: timestamp

  defp update_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> parsed
      _ -> DateTime.utc_now()
    end
  end

  defp update_timestamp(_timestamp), do: DateTime.utc_now()

  defp timestamp_sort_key(event) when is_map(event) do
    case DateTime.from_iso8601(Map.get(event, "timestamp", "")) do
      {:ok, timestamp, _offset} -> DateTime.to_unix(timestamp, :microsecond)
      _ -> 0
    end
  end

  defp event_path(dir, date_string), do: Path.join(dir, "#{date_string}.ndjson")

  defp configured_secret_values(opts) do
    []
    |> Kernel.++(Keyword.get(opts, :secrets, []))
    |> Kernel.++(settings_secret_values())
    |> Kernel.++(env_secret_values())
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 8))
    |> Enum.uniq()
  end

  defp settings_secret_values do
    case Config.settings() do
      {:ok, settings} ->
        [Secret.unwrap(settings.tracker.api_key) | notification_secret_values(settings.notifications)]

      _ ->
        []
    end
  end

  defp notification_secret_values(%{channels: channels}) when is_list(channels) do
    Enum.flat_map(channels, fn channel ->
      [channel |> Map.get(:webhook_url) |> Secret.unwrap(), channel |> Map.get(:url) |> Secret.unwrap()] ++
        (channel |> Map.get(:headers, %{}) |> Map.values() |> Enum.map(&Secret.unwrap/1))
    end)
  end

  defp env_secret_values do
    common_values = Enum.map(@common_secret_envs, &System.get_env/1)

    inferred_values =
      System.get_env()
      |> Enum.flat_map(fn {name, value} ->
        if secret_env_name?(name), do: [value], else: []
      end)

    common_values ++ inferred_values
  end

  defp secret_env_name?(name) when is_binary(name) do
    normalized = String.downcase(name)

    String.contains?(normalized, [
      "api_key",
      "access_token",
      "auth_token",
      "refresh_token",
      "secret",
      "password",
      "webhook_url"
    ])
  end

  defp redact_value(value, secrets), do: redact_value(value, secrets, nil)

  defp redact_value(value, secrets, key) when is_binary(value) and not is_nil(key) do
    if secret_key?(key), do: @redacted, else: redact_string(value, secrets)
  end

  defp redact_value(value, secrets, _key) when is_binary(value), do: redact_string(value, secrets)

  defp redact_value(value, secrets, _key) when is_list(value) do
    Enum.map(value, &redact_value(&1, secrets, nil))
  end

  defp redact_value(value, secrets, _key) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact_value(&1, secrets, nil))
    |> List.to_tuple()
  end

  defp redact_value(%mod{} = value, secrets, _key) do
    fields =
      value
      |> Map.from_struct()
      |> Enum.reduce(%{}, fn {key, nested}, acc ->
        Map.put(acc, key, redact_value(nested, secrets, to_string(key)))
      end)

    struct(mod, fields)
  end

  defp redact_value(value, secrets, _key) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      string_key = to_string(key)
      Map.put(acc, string_key, redact_value(nested, secrets, string_key))
    end)
  end

  defp redact_value(value, _secrets, _key), do: value

  defp redact_string(value, secrets) when is_binary(value) do
    Enum.reduce(secrets, value, fn secret, acc ->
      String.replace(acc, secret, @redacted)
    end)
  end

  defp secret_key?(key) when is_binary(key) do
    normalized = String.downcase(key)

    String.contains?(normalized, [
      "api_key",
      "access_token",
      "auth_token",
      "refresh_token",
      "authorization",
      "password",
      "secret",
      "webhook_url"
    ])
  end

  defp normalize_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_value(%Date{} = date), do: Date.to_iso8601(date)
  defp normalize_value(value) when is_boolean(value) or is_nil(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_value(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, to_string(key), normalize_value(nested))
    end)
  end

  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value) when is_binary(value) or is_number(value), do: value
  defp normalize_value(value), do: inspect(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp hash_event(event) when is_map(event) do
    event
    |> canonical_json()
    |> sha256()
  end

  defp sha256(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(value) when is_map(value) do
    encoded =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(",", fn {key, nested} ->
        Jason.encode!(to_string(key)) <> ":" <> canonical_json(nested)
      end)

    "{" <> encoded <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
