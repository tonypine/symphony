defmodule SymphonyElixir.StatusDashboard.Renderer do
  @moduledoc """
  Pure formatting and rendering helpers for `SymphonyElixir.StatusDashboard`.

  No GenServer state lives here — every function is a pure transformation used
  by the dashboard GenServer (and by the test suite) to turn an orchestrator
  snapshot into the terminal UI string. Functions remain organised by
  responsibility: top-level frame composition, table sections, sample/TPS
  math, and the codex-message humanizers used by the running-row label.
  """

  alias SymphonyElixir.Codex.MessageHumanizer
  alias SymphonyElixir.{Config, Format, HttpServer, RunKind, URLUtils, UsageLimit}

  @throughput_window_ms 5_000
  @throughput_graph_window_ms 10 * 60 * 1000
  @throughput_graph_columns 24
  @sparkline_blocks ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
  @running_id_width 8
  @running_stage_width 14
  @running_pid_width 8
  @running_age_width 12
  @running_tokens_width 10
  @running_session_width 14
  @running_event_default_width 44
  @running_event_min_width 12
  @running_row_chrome_width 10
  @watching_id_width 8
  @watching_state_width 14
  @watching_age_width 12
  @watching_url_min_width 24
  @watching_row_chrome_width 11
  @default_terminal_columns 115
  @recent_runs_limit 5
  @recent_id_width 8
  @recent_status_width 16
  @recent_tokens_width 10

  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_blue IO.ANSI.blue()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_dim IO.ANSI.faint()
  @ansi_green IO.ANSI.green()
  @ansi_red IO.ANSI.red()
  @ansi_orange IO.ANSI.yellow()
  @ansi_yellow IO.ANSI.yellow()
  @ansi_magenta IO.ANSI.magenta()
  @ansi_gray IO.ANSI.light_black()

  ## Public API

  @spec format_snapshot_content(term(), number()) :: String.t()
  def format_snapshot_content(snapshot_data, tps),
    do: format_snapshot_content(snapshot_data, tps, nil)

  @spec format_snapshot_content(term(), number(), integer() | nil) :: String.t()
  def format_snapshot_content(snapshot_data, tps, terminal_columns_override) do
    case snapshot_data do
      {:ok, %{running: running, retrying: retrying, codex_totals: codex_totals} = snapshot} ->
        watching = Map.get(snapshot, :watching, [])
        awaiting_clarification = Map.get(snapshot, :awaiting_clarification, [])
        skipped = Map.get(snapshot, :skipped, [])
        rate_limits = Map.get(snapshot, :rate_limits)
        workspace_lifecycle = Map.get(snapshot, :workspace_lifecycle)
        scope_link_lines = format_scope_link_lines()
        refresh_line = format_refresh_line(Map.get(snapshot, :polling))
        workspace_lifecycle_lines = format_workspace_lifecycle_lines(workspace_lifecycle)

        codex_uncached_input_tokens = codex_totals_uncached_input_tokens(codex_totals)
        codex_cached_input_tokens = codex_totals_token(codex_totals, :cached_input_tokens)
        codex_cache_creation_input_tokens = codex_totals_token(codex_totals, :cache_creation_input_tokens)
        codex_output_tokens = codex_totals_token(codex_totals, :output_tokens)
        codex_seconds_running = Map.get(codex_totals, :seconds_running, 0)
        agent_count = length(running)
        max_agents = Config.settings!().agent.max_concurrent_agents
        running_event_width = running_event_width(terminal_columns_override)
        running_rows = format_running_rows(running, running_event_width)
        running_to_watching_spacer = if(running == [], do: [], else: ["│"])
        watching_url_width = watching_url_width(terminal_columns_override)
        watching_rows = format_watching_rows(watching, watching_url_width)
        {follow_up_checks, backoff_retries} = split_retry_rows_by_delay_type(retrying)
        follow_up_section = format_follow_up_section(follow_up_checks, watching)
        backoff_leading_spacer = backoff_leading_spacer(watching, follow_up_checks)
        backoff_rows = format_retry_rows(backoff_retries)
        backoff_to_awaiting_spacer = if(backoff_retries == [], do: [], else: ["│"])
        awaiting_rows = format_awaiting_clarification_rows(awaiting_clarification, watching_url_width)
        awaiting_to_skipped_spacer = if(awaiting_clarification == [], do: [], else: ["│"])
        skipped_rows = format_skipped_rows(skipped)
        recent_run_rows = format_recent_run_rows(Map.get(snapshot, :run_history, []))

        dispatch_state =
          snapshot
          |> Map.get(:dispatch_state, %{active?: true, blockers: []})
          |> normalize_dispatch_state()

        snapshot_status_lines = format_snapshot_status_lines(snapshot)
        dispatch_lines = format_dispatch_lines(dispatch_state) ++ format_usage_limit_lines(Map.get(snapshot, :usage_limits, []))

        ([
           colorize("╭─ SYMPHONY STATUS", @ansi_bold)
         ] ++
           snapshot_status_lines ++
           dispatch_lines ++
           [
             colorize("│ Agents: ", @ansi_bold) <>
               colorize("#{agent_count}", @ansi_green) <>
               colorize("/", @ansi_gray) <>
               colorize("#{max_agents}", @ansi_gray),
             colorize("│ Throughput: ", @ansi_bold) <> colorize("#{format_tps(tps)} tps", @ansi_cyan),
             colorize("│ Runtime: ", @ansi_bold) <>
               colorize(format_runtime_seconds(codex_seconds_running), @ansi_magenta),
             colorize("│ Tokens: ", @ansi_bold) <>
               colorize("new #{format_count(codex_uncached_input_tokens)}", @ansi_yellow) <>
               colorize(" | ", @ansi_gray) <>
               colorize("cached #{format_count(codex_cached_input_tokens)}", @ansi_yellow) <>
               colorize(" | ", @ansi_gray) <>
               colorize("created #{format_count(codex_cache_creation_input_tokens)}", @ansi_yellow) <>
               colorize(" | ", @ansi_gray) <>
               colorize("out #{format_count(codex_output_tokens)}", @ansi_yellow),
             colorize("│ Rate Limits: ", @ansi_bold) <> format_rate_limits(rate_limits),
             workspace_lifecycle_lines,
             scope_link_lines,
             refresh_line,
             colorize("├─ Running", @ansi_bold),
             "│",
             running_table_header_row(running_event_width),
             running_table_separator_row(running_event_width)
           ] ++
           running_rows ++
           running_to_watching_spacer ++
           [colorize("├─ Watching", @ansi_bold), "│"] ++
           watching_rows ++
           follow_up_section ++
           backoff_leading_spacer ++
           [colorize("├─ Backoff queue", @ansi_bold), "│"] ++
           backoff_rows ++
           backoff_to_awaiting_spacer ++
           [colorize("├─ Awaiting clarification", @ansi_bold), "│"] ++
           awaiting_rows ++
           awaiting_to_skipped_spacer ++
           [colorize("├─ Skipped (quality gate)", @ansi_bold), "│"] ++
           skipped_rows ++
           ["│", colorize("├─ Recent runs", @ansi_bold), "│"] ++
           recent_run_rows ++
           [closing_border()])
        |> List.flatten()
        |> Enum.join("\n")

      :error ->
        [
          colorize("╭─ SYMPHONY STATUS", @ansi_bold),
          colorize("│ Orchestrator snapshot unavailable", @ansi_red),
          colorize("│ Throughput: ", @ansi_bold) <> colorize("#{format_tps(tps)} tps", @ansi_cyan),
          format_scope_link_lines(),
          format_refresh_line(nil),
          closing_border()
        ]
        |> List.flatten()
        |> Enum.join("\n")

      :pending ->
        [
          colorize("╭─ SYMPHONY STATUS", @ansi_bold),
          colorize("│ Snapshot: ", @ansi_bold) <>
            colorize("starting", @ansi_yellow) <>
            colorize(" (waiting for orchestrator)", @ansi_gray),
          colorize("│ Throughput: ", @ansi_bold) <> colorize("#{format_tps(tps)} tps", @ansi_cyan),
          format_scope_link_lines(),
          format_refresh_line(nil),
          closing_border()
        ]
        |> List.flatten()
        |> Enum.join("\n")
    end
  end

  @spec offline_status_content() :: String.t()
  def offline_status_content do
    [
      colorize("╭─ SYMPHONY STATUS", @ansi_bold),
      colorize("│ app_status=offline", @ansi_red),
      closing_border()
    ]
    |> Enum.join("\n")
  end

  @spec format_running_summary(map(), integer()) :: String.t()
  # credo:disable-for-next-line
  def format_running_summary(running_entry, running_event_width) do
    issue = format_cell(running_entry.identifier || "unknown", @running_id_width)
    state = running_entry.state || "unknown"
    state_display = format_cell(to_string(state), @running_stage_width)
    session = running_entry.session_id |> compact_session_id() |> format_cell(@running_session_width)
    pid = format_cell(running_entry.codex_app_server_pid || "n/a", @running_pid_width)
    total_tokens = running_entry.codex_total_tokens || 0
    runtime_seconds = running_entry.runtime_seconds || 0
    turn_count = Map.get(running_entry, :turn_count, 0)
    age = format_cell(format_runtime_and_turns(runtime_seconds, turn_count), @running_age_width)
    event = running_entry.last_codex_event || "none"
    event_label = format_cell(summarize_message(running_entry.last_codex_message), running_event_width)

    tokens = format_count(total_tokens) |> format_cell(@running_tokens_width, :right)

    status_color =
      case event do
        :none -> @ansi_red
        "codex/event/token_count" -> @ansi_yellow
        "codex/event/task_started" -> @ansi_green
        "turn_completed" -> @ansi_magenta
        _ -> @ansi_blue
      end

    [
      "│ ",
      status_dot(status_color),
      " ",
      colorize(issue, @ansi_cyan),
      " ",
      colorize(state_display, status_color),
      " ",
      colorize(pid, @ansi_yellow),
      " ",
      colorize(age, @ansi_magenta),
      " ",
      colorize(tokens, @ansi_yellow),
      " ",
      colorize(session, @ansi_cyan),
      " ",
      colorize(event_label, status_color)
    ]
    |> Enum.join("")
  end

  @spec rolling_tps([{integer(), integer()}], integer(), integer()) :: float()
  def rolling_tps(samples, now_ms, current_tokens) do
    samples = [{now_ms, current_tokens} | samples]
    samples = prune_samples(samples, now_ms)

    case samples do
      [] ->
        0.0

      [_one] ->
        0.0

      _ ->
        first = List.last(samples)
        {start_ms, start_tokens} = first
        elapsed_ms = now_ms - start_ms
        delta_tokens = max(0, current_tokens - start_tokens)

        if elapsed_ms <= 0 do
          0.0
        else
          delta_tokens / (elapsed_ms / 1000.0)
        end
    end
  end

  @spec throttled_tps(integer() | nil, float() | nil, integer(), [{integer(), integer()}], integer()) ::
          {integer(), float()}
  def throttled_tps(last_second, last_value, now_ms, token_samples, current_tokens) do
    second = div(now_ms, 1000)

    if is_integer(last_second) and last_second == second and is_number(last_value) do
      {second, last_value}
    else
      {second, rolling_tps(token_samples, now_ms, current_tokens)}
    end
  end

  @spec tps_graph([{integer(), integer()}], integer(), integer()) :: String.t()
  def tps_graph(samples, now_ms, current_tokens) do
    bucket_ms = div(@throughput_graph_window_ms, @throughput_graph_columns)
    active_bucket_start = div(now_ms, bucket_ms) * bucket_ms
    graph_window_start = active_bucket_start - (@throughput_graph_columns - 1) * bucket_ms

    rates =
      [{now_ms, current_tokens} | samples]
      |> prune_graph_samples(now_ms)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{start_ms, start_tokens}, {end_ms, end_tokens}] ->
        elapsed_ms = end_ms - start_ms
        delta_tokens = max(0, end_tokens - start_tokens)
        tps = if elapsed_ms <= 0, do: 0.0, else: delta_tokens / (elapsed_ms / 1000.0)
        {end_ms, tps}
      end)

    bucketed_tps =
      0..(@throughput_graph_columns - 1)
      |> Enum.map(fn bucket_idx ->
        bucket_start = graph_window_start + bucket_idx * bucket_ms
        bucket_end = bucket_start + bucket_ms
        last_bucket? = bucket_idx == @throughput_graph_columns - 1

        values =
          rates
          |> Enum.filter(fn {timestamp, _tps} ->
            in_bucket?(timestamp, bucket_start, bucket_end, last_bucket?)
          end)
          |> Enum.map(fn {_timestamp, tps} -> tps end)

        if values == [] do
          0.0
        else
          Enum.sum(values) / length(values)
        end
      end)

    max_tps = Enum.max(bucketed_tps, fn -> 0.0 end)

    bucketed_tps
    |> Enum.map_join(fn value ->
      index =
        if max_tps <= 0 do
          0
        else
          round(value / max_tps * (length(@sparkline_blocks) - 1))
        end

      Enum.at(@sparkline_blocks, index, "▁")
    end)
  end

  @spec format_timestamp(DateTime.t()) :: String.t()
  def format_timestamp(datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  @spec prune_samples([{integer(), integer()}], integer()) :: [{integer(), integer()}]
  def prune_samples(samples, now_ms) do
    min_timestamp = now_ms - @throughput_window_ms
    Enum.filter(samples, fn {timestamp, _} -> timestamp >= min_timestamp end)
  end

  @spec prune_graph_samples([{integer(), integer()}], integer()) :: [{integer(), integer()}]
  def prune_graph_samples(samples, now_ms) do
    min_timestamp = now_ms - max(@throughput_window_ms, @throughput_graph_window_ms)
    Enum.filter(samples, fn {timestamp, _} -> timestamp >= min_timestamp end)
  end

  @spec update_token_samples([{integer(), integer()}], integer(), integer()) ::
          [{integer(), integer()}]
  def update_token_samples(samples, now_ms, total_tokens) do
    prune_graph_samples([{now_ms, total_tokens} | samples], now_ms)
  end

  @spec snapshot_total_tokens(term()) :: integer()
  def snapshot_total_tokens({:ok, %{codex_totals: codex_totals}}) when is_map(codex_totals) do
    Map.get(codex_totals, :total_tokens, 0)
  end

  def snapshot_total_tokens(_snapshot_data), do: 0

  @spec running_event_width(integer() | nil) :: pos_integer()
  def running_event_width(terminal_columns) do
    terminal_columns = terminal_columns || terminal_columns()

    max(
      @running_event_min_width,
      terminal_columns - fixed_running_width() - @running_row_chrome_width
    )
  end

  @spec watching_url_width(integer() | nil) :: pos_integer()
  def watching_url_width(terminal_columns) do
    terminal_columns = terminal_columns || terminal_columns()

    max(
      @watching_url_min_width,
      terminal_columns -
        @watching_id_width -
        @watching_state_width -
        @watching_age_width -
        @watching_row_chrome_width
    )
  end

  ## Private helpers

  defp format_scope_link_lines do
    repo_line = colorize("│ Repos: ", @ansi_bold) <> format_repo_scope()

    case dashboard_url() do
      url when is_binary(url) ->
        [repo_line, colorize("│ Dashboard: ", @ansi_bold) <> colorize(url, @ansi_cyan)]

      _ ->
        [repo_line]
    end
  end

  defp format_repo_scope do
    case Config.repos() do
      {:ok, repos} ->
        repos
        |> Enum.map(&Map.get(&1, :name))
        |> Enum.reject(&(not is_binary(&1) or String.trim(&1) == ""))
        |> format_repo_names()

      {:error, _reason} ->
        colorize("n/a", @ansi_gray)
    end
  end

  defp format_repo_names([]), do: colorize("n/a", @ansi_gray)
  defp format_repo_names([name]), do: colorize(name, @ansi_cyan)

  defp format_repo_names(names) do
    visible_names = Enum.take(names, 4)
    hidden_count = max(length(names) - length(visible_names), 0)

    suffix =
      case hidden_count do
        0 -> ""
        count -> ", +#{count}"
      end

    colorize(Enum.join(visible_names, ", ") <> suffix, @ansi_cyan)
  end

  defp format_refresh_line(polling) do
    colorize("│ Next refresh: ", @ansi_bold) <> format_refresh_status(polling) <> format_linear_budget(polling)
  end

  defp format_refresh_status(%{linear: %{rate_limited_for_ms: pause_ms} = linear}) when is_integer(pause_ms) and pause_ms > 0 do
    colorize("Linear rate-limited; probing in #{div(pause_ms + 999, 1000)}s#{format_window_reset(linear)}", @ansi_yellow)
  end

  defp format_refresh_status(%{checking?: true}), do: colorize("checking now…", @ansi_cyan)

  defp format_refresh_status(%{next_poll_in_ms: due_in_ms}) when is_integer(due_in_ms) do
    due_in_ms = max(due_in_ms, 0)
    seconds = div(due_in_ms + 999, 1000)
    colorize("#{seconds}s", @ansi_cyan)
  end

  defp format_refresh_status(_), do: colorize("n/a", @ansi_gray)

  defp format_linear_budget(%{linear: %{requests_last_poll: requests} = linear}) when is_integer(requests) do
    remaining =
      case linear do
        %{requests_remaining: left, requests_limit: limit} when is_integer(left) and is_integer(limit) ->
          ", #{left}/#{limit} left this hour"

        _ ->
          ""
      end

    slowed =
      case linear do
        %{poll_interval_multiplier: multiplier} when is_integer(multiplier) and multiplier > 1 -> ", polling slowed #{multiplier}x"
        _ -> ""
      end

    colorize(" (Linear: #{requests} req last poll#{remaining}#{slowed})", @ansi_gray)
  end

  defp format_linear_budget(_polling), do: ""

  # Linear's window is a rolling hour; its reset is when the whole budget is back.
  defp format_window_reset(%{window_resets_in_ms: reset_in_ms}) when is_integer(reset_in_ms) and reset_in_ms > 0 do
    " (full budget in #{div(reset_in_ms + 59_999, 60_000)}m)"
  end

  defp format_window_reset(_linear), do: ""

  defp format_workspace_lifecycle_lines(%{quota_configured: true} = lifecycle) do
    paused? = Map.get(lifecycle, :quota_paused) == true
    status = if(paused?, do: "paused", else: "ok")
    color = if(paused?, do: @ansi_red, else: @ansi_green)
    free_bytes = format_bytes(Map.get(lifecycle, :free_bytes))
    min_free_bytes = format_bytes(Map.get(lifecycle, :min_free_bytes))

    lines = [
      colorize("│ Workspace: ", @ansi_bold) <>
        colorize(status, color) <>
        colorize(" free #{free_bytes} / min #{min_free_bytes}", @ansi_gray)
    ]

    case Map.get(lifecycle, :quota_reason) do
      reason when paused? and is_binary(reason) and reason != "" ->
        lines ++ [colorize("│ Workspace reason: ", @ansi_bold) <> colorize(reason, @ansi_red)]

      _ ->
        lines
    end
  end

  defp format_workspace_lifecycle_lines(_lifecycle), do: []

  defp format_snapshot_status_lines(%{snapshot_stale?: true} = snapshot) do
    age = format_staleness_age(Map.get(snapshot, :staleness_ms))

    details =
      [
        format_missed_refreshes(Map.get(snapshot, :consecutive_misses)),
        format_mailbox_depth(Map.get(snapshot, :orchestrator_mailbox_len))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    suffix =
      case {age, details} do
        {nil, ""} -> " (orchestrator refresh missed)"
        {age, ""} -> " #{age}"
        {nil, details} -> " (#{details})"
        {age, details} -> " #{age} (#{details})"
      end

    [
      colorize("│ Snapshot: ", @ansi_bold) <>
        colorize("stale", @ansi_yellow) <>
        colorize(suffix, @ansi_gray)
    ]
  end

  defp format_snapshot_status_lines(_snapshot), do: []

  defp format_staleness_age(age_ms) when is_integer(age_ms) and age_ms >= 0 do
    format_runtime_seconds(div(age_ms, 1_000))
  end

  defp format_staleness_age(_age_ms), do: nil

  defp format_missed_refreshes(misses) when is_integer(misses) and misses > 0 do
    suffix = if misses == 1, do: "missed refresh", else: "missed refreshes"
    "#{misses} #{suffix}"
  end

  defp format_missed_refreshes(_misses), do: nil

  defp format_mailbox_depth(mailbox_len) when is_integer(mailbox_len) and mailbox_len >= 0 do
    "orchestrator mailbox #{mailbox_len}"
  end

  defp format_mailbox_depth(_mailbox_len), do: nil

  defp dashboard_url do
    URLUtils.dashboard_url(Config.settings!().server.host, Config.server_port(), HttpServer.bound_port())
  end

  defp format_running_rows(running, running_event_width) do
    if running == [] do
      [
        "│  " <> colorize("No active agents", @ansi_gray),
        "│"
      ]
    else
      running
      |> Enum.sort_by(& &1.identifier)
      |> Enum.flat_map(&[format_running_summary(&1, running_event_width) | format_running_profile_lines(&1)])
    end
  end

  defp format_running_profile_lines(running_entry) do
    [
      {"", Map.get(running_entry, :run_profile)},
      {"reviewer: ", Map.get(running_entry, :reviewer_run_profile)}
    ]
    |> Enum.flat_map(fn {prefix, profile} ->
      case RunKind.label(profile) do
        nil -> []
        label -> ["│     " <> colorize(prefix <> label, @ansi_gray)]
      end
    end)
  end

  defp format_recent_run_rows([]), do: ["│  " <> colorize("No runs yet", @ansi_gray)]

  defp format_recent_run_rows(runs) when is_list(runs) do
    runs
    |> Enum.take(@recent_runs_limit)
    |> Enum.map(&format_recent_run_row/1)
  end

  defp format_recent_run_row(run) do
    label = Map.get(run, :issue_identifier) || Map.get(run, :issue_id) || "unknown"
    status = Map.get(run, :status) || "unknown"
    total_tokens = Map.get(Map.get(run, :tokens) || %{}, :total_tokens, 0)
    reviewer = run |> Map.get(:reviewer_profile) |> RunKind.label()

    "│  ◦ " <>
      colorize(format_cell(label, @recent_id_width), @ansi_cyan) <>
      " " <>
      format_cell(status, @recent_status_width) <>
      " " <>
      colorize(format_cell(format_count(total_tokens), @recent_tokens_width, :right), @ansi_yellow) <>
      " " <>
      colorize(RunKind.label(run) || "profile n/a", @ansi_gray) <>
      if(reviewer, do: colorize(" (reviewer: #{reviewer})", @ansi_gray), else: "")
  end

  defp normalize_dispatch_state(%{blockers: blockers} = dispatch_state) when is_list(blockers) do
    blockers = Enum.reject(blockers, &workspace_dirty_blocker?/1)

    %{
      active?: Map.get(dispatch_state, :active?) == true or blockers == [],
      blockers: blockers
    }
  end

  defp normalize_dispatch_state(_), do: %{active?: true, blockers: []}

  defp workspace_dirty_blocker?(%{kind: :workspace_dirty}), do: true
  defp workspace_dirty_blocker?(_), do: false

  defp format_dispatch_lines(%{active?: true}) do
    [colorize("│ Dispatch: ", @ansi_bold) <> colorize("active", @ansi_green)]
  end

  defp format_dispatch_lines(%{active?: false, blockers: blockers}) when is_list(blockers) do
    count = length(blockers)
    suffix = if count == 1, do: "blocker", else: "blockers"

    header =
      colorize("│ Dispatch: ", @ansi_bold) <>
        colorize("paused", @ansi_red) <>
        colorize(" — #{count} #{suffix}", @ansi_gray)

    blocker_lines =
      Enum.map(blockers, fn blocker ->
        colorize("│   ✗ ", @ansi_red) <> colorize(format_blocker_line(blocker), @ansi_yellow)
      end)

    [header | blocker_lines]
  end

  defp format_blocker_line(%{kind: :manual, reason: reason}) do
    case reason do
      reason when is_binary(reason) and reason != "" -> "manually paused: #{reason}"
      _ -> "manually paused"
    end
  end

  defp format_blocker_line(%{kind: :budget, used: used, limit: limit, resets_on: resets_on}) do
    base = "daily budget exhausted: #{format_count(used)} / #{format_count(limit)}"

    case resets_on do
      %Date{} = date -> base <> " (resets #{Date.to_iso8601(date)})"
      _ -> base
    end
  end

  defp format_blocker_line(%{kind: :missing_api_key, provider: provider}) do
    "missing #{provider} API key"
  end

  defp format_blocker_line(%{
         kind: :config_invalid,
         message: message,
         since: since,
         consecutive_failures: consecutive_failures
       }) do
    "config invalid: #{message} " <>
      "(#{format_count(consecutive_failures)} consecutive failures since #{format_time_of_day(since)})"
  end

  defp format_blocker_line(%{
         kind: :tracker_unavailable,
         tracker: tracker,
         reason: reason,
         since: since,
         consecutive_failures: consecutive_failures
       }) do
    "#{format_tracker_name(tracker)} tracker unavailable: #{format_tracker_unavailable_reason(reason)} " <>
      "(#{format_count(consecutive_failures)} consecutive failures since #{format_time_of_day(since)})"
  end

  defp format_blocker_line(%{kind: :usage_limit, resume_at: resume_at} = blocker) do
    state = if UsageLimit.headroom?(blocker), do: "headroom: holding new runs", else: "reached"
    "#{UsageLimit.limit_label(blocker)} #{state} (resumes #{DateTime.to_iso8601(resume_at)})"
  end

  defp format_blocker_line(%{kind: kind}), do: "blocked: #{kind}"

  defp format_usage_limit_lines(usage_limits) do
    now = DateTime.utc_now()
    Enum.map(usage_limits, &(colorize("│ ", @ansi_bold) <> colorize(UsageLimit.banner(&1, now), @ansi_yellow)))
  end

  defp format_tracker_name(:linear), do: "linear"
  defp format_tracker_name("linear"), do: "linear"
  defp format_tracker_name(:memory), do: "memory"
  defp format_tracker_name("memory"), do: "memory"
  defp format_tracker_name(tracker) when is_atom(tracker), do: Atom.to_string(tracker)
  defp format_tracker_name(tracker) when is_binary(tracker), do: tracker
  defp format_tracker_name(_tracker), do: "unknown"

  defp format_tracker_unavailable_reason(:missing_linear_api_token), do: "invalid or missing API key"
  defp format_tracker_unavailable_reason(:linear_api_request), do: "Linear API request failed"
  defp format_tracker_unavailable_reason(_reason), do: "unknown tracker failure"

  defp format_time_of_day(%DateTime{} = since) do
    since
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
  end

  defp format_time_of_day(_since), do: "unknown time"

  defp format_watching_rows(watching, watching_url_width) do
    url_header = if Enum.any?(watching, &watching_pull_request_url/1), do: "PR / LINEAR URL", else: "LINEAR URL"

    base_rows = [
      watching_table_header_row(watching_url_width, url_header),
      watching_table_separator_row(watching_url_width)
    ]

    if watching == [] do
      base_rows ++
        [
          "│  " <> colorize("No watched issues", @ansi_gray),
          "│"
        ]
    else
      base_rows ++
        (watching
         |> Enum.sort_by(&watching_sort_key/1)
         |> Enum.map(&format_watching_summary(&1, watching_url_width)))
    end
  end

  defp watching_sort_key(entry) do
    {
      map_value(entry, [:seconds_since_last_run, "seconds_since_last_run"]) || 0,
      map_value(entry, [:identifier, "identifier"]) || map_value(entry, [:issue_id, "issue_id"]) || ""
    }
  end

  defp format_watching_summary(watching_entry, watching_url_width) do
    issue_id = map_value(watching_entry, [:issue_id, "issue_id"]) || "unknown"
    identifier = map_value(watching_entry, [:identifier, "identifier"]) || issue_id
    state = map_value(watching_entry, [:state, "state"]) || "unknown"
    seconds_since_last_run = map_value(watching_entry, [:seconds_since_last_run, "seconds_since_last_run"])
    url = watching_urls(watching_entry)

    [
      "│ ",
      colorize("◌", @ansi_blue),
      " ",
      colorize(format_cell(identifier, @watching_id_width), @ansi_cyan),
      " ",
      colorize(format_cell(state, @watching_state_width), @ansi_yellow),
      " ",
      colorize(format_cell(format_ago(seconds_since_last_run), @watching_age_width), @ansi_magenta),
      " ",
      colorize(format_cell(url, watching_url_width), @ansi_cyan)
    ]
    |> Enum.join("")
  end

  defp watching_table_header_row(watching_url_width, url_header) do
    header =
      [
        format_cell("ID", @watching_id_width),
        format_cell("STATE", @watching_state_width),
        format_cell("LAST RUN", @watching_age_width),
        format_cell(url_header, watching_url_width)
      ]
      |> Enum.join(" ")

    "│   " <> colorize(header, @ansi_gray)
  end

  defp watching_pull_request_url(watching_entry) do
    watching_entry
    |> map_value([:pull_request_url, "pull_request_url", :pr_url, "pr_url"])
    |> URLUtils.present_url()
  end

  defp watching_linear_url(watching_entry) do
    watching_entry
    |> map_value([:url, "url"])
    |> URLUtils.present_url()
  end

  defp watching_urls(watching_entry) do
    watching_entry
    |> watching_url_values()
    |> case do
      [] -> "n/a"
      urls -> Enum.join(urls, " | ")
    end
  end

  defp watching_url_values(watching_entry) do
    [watching_pull_request_url(watching_entry), watching_linear_url(watching_entry)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp watching_table_separator_row(watching_url_width) do
    separator_width =
      @watching_id_width +
        @watching_state_width +
        @watching_age_width +
        watching_url_width + 3

    "│   " <> colorize(String.duplicate("─", separator_width), @ansi_gray)
  end

  defp format_ago(seconds) when is_integer(seconds) and seconds >= 0 do
    cond do
      seconds < 60 ->
        "#{seconds}s ago"

      seconds < 3_600 ->
        "#{div(seconds, 60)}m ago"

      seconds < 86_400 ->
        "#{div(seconds, 3_600)}h ago"

      true ->
        "#{div(seconds, 86_400)}d ago"
    end
  end

  defp format_ago(_seconds), do: "n/a"

  defp split_retry_rows_by_delay_type(retrying) when is_list(retrying) do
    Enum.split_with(retrying, &continuation_retry?/1)
  end

  defp split_retry_rows_by_delay_type(_retrying), do: {[], []}

  defp continuation_retry?(retry_entry) do
    map_value(retry_entry, [:delay_type, "delay_type"]) in [:continuation, "continuation"]
  end

  defp format_follow_up_section([], _watching), do: []

  defp format_follow_up_section(follow_up_checks, watching) do
    leading_spacer = if(watching == [], do: [], else: ["│"])

    leading_spacer ++
      [colorize("├─ Follow-up checks", @ansi_bold), "│"] ++
      format_follow_up_rows(follow_up_checks)
  end

  defp backoff_leading_spacer(_watching, [_check | _checks]), do: ["│"]
  defp backoff_leading_spacer([_watching | _watching_rest], []), do: ["│"]
  defp backoff_leading_spacer(_watching, _checks), do: []

  defp format_follow_up_rows(follow_up_checks) do
    follow_up_checks
    |> Enum.sort_by(&retry_due_in_ms/1)
    |> Enum.map(&format_follow_up_summary/1)
  end

  defp format_follow_up_summary(retry_entry) do
    issue_id = map_value(retry_entry, [:issue_id, "issue_id"]) || "unknown"
    identifier = map_value(retry_entry, [:identifier, "identifier"]) || issue_id
    due_in_ms = retry_due_in_ms(retry_entry)

    "│  #{colorize("↻", @ansi_orange)} " <>
      colorize("#{identifier}", @ansi_cyan) <>
      " " <>
      colorize("state check", @ansi_yellow) <>
      colorize(" in ", @ansi_dim) <>
      colorize(next_in_words(due_in_ms), @ansi_cyan)
  end

  defp format_retry_rows(retrying) do
    if retrying == [] do
      ["│  " <> colorize("No queued retries", @ansi_gray)]
    else
      retrying
      |> Enum.sort_by(&retry_due_in_ms/1)
      |> Enum.map(&format_retry_summary/1)
    end
  end

  defp retry_due_in_ms(retry_entry) do
    case map_value(retry_entry, [:due_in_ms, "due_in_ms"]) do
      due_in_ms when is_integer(due_in_ms) -> due_in_ms
      _ -> 0
    end
  end

  defp format_retry_summary(retry_entry) do
    issue_id = retry_entry.issue_id || "unknown"
    identifier = retry_entry.identifier || issue_id
    attempt = retry_entry.attempt || 0
    due_in_ms = retry_entry.due_in_ms || 0
    error = format_retry_error(retry_entry.error)

    "│  #{colorize("↻", @ansi_orange)} " <>
      colorize("#{identifier}", @ansi_red) <>
      " " <>
      colorize("attempt=#{attempt}", @ansi_yellow) <>
      colorize(" in ", @ansi_dim) <>
      colorize(next_in_words(due_in_ms), @ansi_cyan) <>
      error
  end

  defp next_in_words(due_in_ms) when is_integer(due_in_ms) do
    secs = div(due_in_ms, 1000)
    millis = rem(due_in_ms, 1000)
    "#{secs}.#{String.pad_leading(to_string(millis), 3, "0")}s"
  end

  defp next_in_words(_), do: "n/a"

  defp format_retry_error(error) when is_binary(error) do
    sanitized =
      error
      |> String.replace("\\r\\n", " ")
      |> String.replace("\\r", " ")
      |> String.replace("\\n", " ")
      |> String.replace("\r\n", " ")
      |> String.replace("\r", " ")
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if sanitized == "" do
      ""
    else
      " " <> colorize("error=#{truncate(sanitized, 96)}", @ansi_dim)
    end
  end

  defp format_retry_error(_), do: ""

  defp format_skipped_rows(skipped) when is_list(skipped) do
    if skipped == [] do
      ["│  " <> colorize("No issues skipped this session", @ansi_gray)]
    else
      skipped
      |> Enum.sort_by(&skipped_sort_key/1)
      |> Enum.map(&format_skipped_row/1)
    end
  end

  defp format_skipped_rows(_skipped), do: format_skipped_rows([])

  defp format_awaiting_clarification_rows(awaiting, url_width) when is_list(awaiting) do
    if awaiting == [] do
      ["│  " <> colorize("No issues awaiting clarification", @ansi_gray)]
    else
      awaiting
      |> Enum.sort_by(&skipped_sort_key/1)
      |> Enum.map(&format_awaiting_clarification_row(&1, url_width))
    end
  end

  defp format_awaiting_clarification_rows(_awaiting, url_width), do: format_awaiting_clarification_rows([], url_width)

  defp format_awaiting_clarification_row(entry, url_width) do
    label = entry.identifier || entry.issue_id || "unknown"
    round_count = Map.get(entry, :rounds_asked, 0)
    url = entry.url || ""
    url_part = if url == "", do: "", else: " " <> colorize(truncate(url, url_width), @ansi_dim)

    "│  ? " <>
      colorize(label, @ansi_cyan) <>
      " " <>
      colorize("round=#{round_count}", @ansi_yellow) <>
      url_part
  end

  defp skipped_sort_key(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp skipped_sort_key(%{issue_id: issue_id}), do: issue_id || ""
  defp skipped_sort_key(_entry), do: ""

  defp format_skipped_row(entry) do
    label = entry.identifier || entry.issue_id || "unknown"
    score_part = format_skipped_score(entry)
    reason_part = format_skipped_reason(entry)

    "│  #{colorize("✗", @ansi_red)} " <>
      colorize(label, @ansi_red) <>
      score_part <>
      reason_part
  end

  defp format_skipped_score(%{kind: :scored, score: score}) when is_integer(score) do
    " " <> colorize("score=#{score}", @ansi_yellow)
  end

  defp format_skipped_score(%{kind: :error, error: error}) when not is_nil(error) do
    " " <> colorize("error", @ansi_red)
  end

  defp format_skipped_score(_entry), do: ""

  defp format_skipped_reason(%{reason: reason}) when is_binary(reason) and reason != "" do
    " " <> colorize(truncate(reason, 96), @ansi_dim)
  end

  defp format_skipped_reason(_entry), do: ""

  defp format_runtime_seconds(seconds) when is_integer(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_runtime_seconds(seconds) when is_binary(seconds), do: seconds
  defp format_runtime_seconds(_), do: "0m 0s"

  defp format_runtime_and_turns(seconds, turn_count) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(seconds)} / #{turn_count}"
  end

  defp format_runtime_and_turns(seconds, _turn_count), do: format_runtime_seconds(seconds)

  defp format_bytes(nil), do: "n/a"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MiB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KiB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_bytes), do: "n/a"

  defp format_count(value), do: Format.format_count(value)

  defp running_table_header_row(running_event_width) do
    header =
      [
        format_cell("ID", @running_id_width),
        format_cell("STAGE", @running_stage_width),
        format_cell("PID", @running_pid_width),
        format_cell("AGE / TURN", @running_age_width),
        format_cell("TOKENS", @running_tokens_width),
        format_cell("SESSION", @running_session_width),
        format_cell("EVENT", running_event_width)
      ]
      |> Enum.join(" ")

    "│   " <> colorize(header, @ansi_gray)
  end

  defp running_table_separator_row(running_event_width) do
    separator_width =
      @running_id_width +
        @running_stage_width +
        @running_pid_width +
        @running_age_width +
        @running_tokens_width +
        @running_session_width +
        running_event_width + 6

    "│   " <> colorize(String.duplicate("─", separator_width), @ansi_gray)
  end

  defp fixed_running_width do
    @running_id_width +
      @running_stage_width +
      @running_pid_width +
      @running_age_width +
      @running_tokens_width +
      @running_session_width
  end

  defp terminal_columns do
    case :io.columns() do
      {:ok, columns} when is_integer(columns) and columns > 0 ->
        columns

      _ ->
        terminal_columns_from_env()
    end
  end

  defp terminal_columns_from_env do
    case System.get_env("COLUMNS") do
      nil ->
        fixed_running_width() + @running_row_chrome_width + @running_event_default_width

      value ->
        case Integer.parse(String.trim(value)) do
          {columns, ""} when columns > 0 -> columns
          _ -> @default_terminal_columns
        end
    end
  end

  defp format_cell(value, width, align \\ :left) do
    value =
      value
      |> to_string()
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> truncate_plain(width)

    case align do
      :right -> String.pad_leading(value, width)
      _ -> String.pad_trailing(value, width)
    end
  end

  defp truncate_plain(value, width) do
    if byte_size(value) <= width do
      value
    else
      String.slice(value, 0, width - 3) <> "..."
    end
  end

  defp compact_session_id(nil), do: "n/a"
  defp compact_session_id(session_id) when not is_binary(session_id), do: "n/a"

  defp compact_session_id(session_id) do
    if String.length(session_id) > 10 do
      String.slice(session_id, 0, 4) <> "..." <> String.slice(session_id, -6, 6)
    else
      session_id
    end
  end

  defp format_tps(value) when is_number(value) do
    value
    |> trunc()
    |> Format.format_count()
  end

  defp in_bucket?(timestamp, bucket_start, bucket_end, true),
    do: timestamp >= bucket_start and timestamp <= bucket_end

  defp in_bucket?(timestamp, bucket_start, bucket_end, false),
    do: timestamp >= bucket_start and timestamp < bucket_end

  defp format_rate_limits(nil), do: colorize("unavailable", @ansi_gray)

  defp format_rate_limits(rate_limits) when is_map(rate_limits) do
    limit_id =
      map_value(rate_limits, ["limit_id", :limit_id, "limit_name", :limit_name]) ||
        "unknown"

    primary = format_rate_limit_bucket(map_value(rate_limits, ["primary", :primary]))
    secondary = format_rate_limit_bucket(map_value(rate_limits, ["secondary", :secondary]))
    credits = format_rate_limit_credits(map_value(rate_limits, ["credits", :credits]))

    colorize(to_string(limit_id), @ansi_yellow) <>
      colorize(" | ", @ansi_gray) <>
      colorize("primary #{primary}", @ansi_cyan) <>
      colorize(" | ", @ansi_gray) <>
      colorize("secondary #{secondary}", @ansi_cyan) <>
      colorize(" | ", @ansi_gray) <>
      colorize(credits, @ansi_green)
  end

  defp format_rate_limits(other) do
    other
    |> inspect(limit: 10)
    |> truncate(80)
    |> colorize(@ansi_gray)
  end

  defp format_rate_limit_bucket(nil), do: "n/a"

  defp format_rate_limit_bucket(bucket) when is_map(bucket) do
    remaining = map_value(bucket, ["remaining", :remaining])
    limit = map_value(bucket, ["limit", :limit])

    reset_value =
      map_value(bucket, [
        "reset_in_seconds",
        :reset_in_seconds,
        "resetInSeconds",
        :resetInSeconds,
        "reset_at",
        :reset_at,
        "resetAt",
        :resetAt,
        "resets_at",
        :resets_at,
        "resetsAt",
        :resetsAt
      ])

    base =
      cond do
        integer_like?(remaining) and integer_like?(limit) ->
          "#{format_count(remaining)}/#{format_count(limit)}"

        integer_like?(remaining) ->
          "remaining #{format_count(remaining)}"

        integer_like?(limit) ->
          "limit #{format_count(limit)}"

        map_size(bucket) == 0 ->
          "n/a"

        true ->
          bucket |> inspect(limit: 6) |> truncate(40)
      end

    if is_nil(reset_value) do
      base
    else
      "#{base} reset #{format_reset_value(reset_value)}"
    end
  end

  defp format_rate_limit_bucket(other), do: to_string(other)

  defp format_rate_limit_credits(nil), do: "credits n/a"

  defp format_rate_limit_credits(credits) when is_map(credits) do
    unlimited = map_value(credits, ["unlimited", :unlimited]) == true
    has_credits = map_value(credits, ["has_credits", :has_credits]) == true
    balance = map_value(credits, ["balance", :balance])

    cond do
      unlimited ->
        "credits unlimited"

      has_credits and is_number(balance) ->
        "credits #{format_number(balance)}"

      has_credits ->
        "credits available"

      true ->
        "credits none"
    end
  end

  defp format_rate_limit_credits(other), do: "credits #{to_string(other)}"

  defp format_reset_value(value) when is_integer(value), do: "#{format_count(value)}s"
  defp format_reset_value(value) when is_binary(value), do: value
  defp format_reset_value(value), do: to_string(value)

  defp format_number(value) when is_integer(value), do: format_count(value)

  defp format_number(value) when is_float(value) do
    value
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
  end

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_value(_map, _keys), do: nil

  defp integer_like?(value) when is_integer(value), do: true
  defp integer_like?(_value), do: false

  defp status_dot(color_code) do
    colorize("●", color_code)
  end

  defp codex_totals_uncached_input_tokens(codex_totals) when is_map(codex_totals) do
    case codex_totals_token(codex_totals, :uncached_input_tokens, nil) do
      value when is_integer(value) ->
        value

      _ ->
        input_tokens = codex_totals_token(codex_totals, :input_tokens)
        cached_input_tokens = codex_totals_token(codex_totals, :cached_input_tokens)
        max(input_tokens - cached_input_tokens, 0)
    end
  end

  defp codex_totals_uncached_input_tokens(_codex_totals), do: 0

  defp codex_totals_token(codex_totals, key, default \\ 0) when is_map(codex_totals) and is_atom(key) do
    string_key = Atom.to_string(key)

    case Map.get(codex_totals, key, Map.get(codex_totals, string_key, default)) do
      value when is_integer(value) and value >= 0 -> value
      _value -> default
    end
  end

  defp closing_border, do: "╰─"

  defp colorize(value, code) do
    "#{code}#{value}#{@ansi_reset}"
  end

  defp summarize_message(message), do: MessageHumanizer.humanize(message)

  defp truncate(value, max), do: Format.truncate(value, max)
end
