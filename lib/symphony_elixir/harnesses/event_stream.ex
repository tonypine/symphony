defmodule SymphonyElixir.Harnesses.EventStream do
  @moduledoc """
  Reads one turn of a harness that reports its work as lines on stdout, whatever the harness.

  A launcher gives it the port and a parser that turns each line into an event:

    * `{:session_started, id}`, `{:agent_text, text}`, `{:tool_use, name}`,
      `{:tool_result, text}`, `{:tool_progress, name}`, `{:notification, text}`;
    * `{:token_usage_delta, usage}`, summed into the turn's token counts; a delta that names its
      model message (`:message_id`) counts once per message, as Claude repeats a message's usage
      on the line of each of its content blocks;
    * `{:turn_completed, result}` and `{:turn_failed, reason}`, which end the turn, as do
      `{:usage_limited, info}`, `{:api_unreachable, info}` and `{:rate_limited, info, reason}`;
    * `{:usage_window, message, window}` and `{:rate_limit_info, info}`;
    * `{:background_command_started, id}` and `{:background_command_ended, id}`: a command
      the agent started in the background, and the notice that it ended;
    * `{:multi, events}` for a line that holds several, and `{:malformed, line}` for a line
      that is no event, kept as the process's diagnostic output.

  It keeps the turn's deadlines (the turn's own, and a command's while a tool call is open),
  finishes a turn whose process lingers after its terminal event, and returns the turn's
  result or the reason it has none.

  A terminal event that arrives while a background command of the turn is still running does
  not finish the turn (TP-1570): the agent is waiting on its command, and the harness hands the
  command's result to it in the same process once the command ends. The stream keeps reading,
  sends a `{:tool_progress, "background command"}` heartbeat so the run reads as active, and
  goes on with the conversation when the command ends. The wait has its own bound
  (`background_wait_ms/0`, counted once per turn from the first wait): a command still running
  then is stopped with the process's tree, and the turn ends on what it captured. A turn that
  waited carries `background_wait: %{outcome: :ended | :bound | :exited, waited_ms: ms}`.
  """

  require Logger

  alias SymphonyElixir.Conductor.Steer

  @type event :: tuple()

  @diagnostic_output_line_count 5
  @diagnostic_output_line_max_bytes 4_096
  @post_completion_grace_default_ms 1_500
  @background_wait_default_ms 30 * 60 * 1_000
  @background_heartbeat_default_ms 30_000

  defp background_heartbeat_ms do
    case Application.get_env(:symphony_elixir, :background_heartbeat_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @background_heartbeat_default_ms
    end
  end

  @doc "How long a turn waits on background commands still running after its terminal event."
  @spec background_wait_ms() :: pos_integer()
  def background_wait_ms do
    case Application.get_env(:symphony_elixir, :background_wait_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @background_wait_default_ms
    end
  end

  @doc """
  Reads the port until the turn ends: a terminal event and the process's exit, a timeout, or
  an exit with no terminal event. `on_message` gets every event as it arrives.

  Options: `:parse` (required), the harness's line parser; `:after_line`, a hook given each
  line and the state, which it may change; `:label`, the harness's name in log lines;
  `:issue`, `:provider` and `:mcp_log_workspace`, kept on the state for the events and the
  hook.
  """
  @spec read(port(), (event() -> term()), pos_integer(), integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(port, on_message, turn_timeout_ms, command_timeout_ms, opts) do
    now = System.monotonic_time(:millisecond)

    acc = %{
      session_id: nil,
      input_tokens: 0,
      output_tokens: 0,
      counted_usage: %{},
      turn_failed: nil,
      turn_completed: false,
      diagnostic_output_lines: [],
      mcp_servers_checked: false,
      mcp_log_workspace: Keyword.get(opts, :mcp_log_workspace),
      issue: Keyword.get(opts, :issue),
      usage_limited: nil,
      api_unreachable: nil,
      provider: Keyword.get(opts, :provider, "anthropic"),
      usage_windows: %{},
      label: Keyword.get(opts, :label, "Agent")
    }

    loop_state = %{
      turn_deadline: now + turn_timeout_ms,
      command_deadline: nil,
      command_timeout_ms: command_timeout_ms,
      active_tool_uses: 0,
      pending_line: "",
      post_completion_deadline: nil,
      parse: Keyword.fetch!(opts, :parse),
      after_line: Keyword.get(opts, :after_line, fn _line, acc -> acc end),
      label: Keyword.get(opts, :label, "Agent"),
      run_id: Keyword.get(opts, :run_id),
      turn_timeout_ms: turn_timeout_ms,
      background_commands: MapSet.new(),
      background_wait: nil,
      awaiting_continuation: false
    }

    read_loop(port, on_message, acc, loop_state)
  end

  defp read_loop(port, on_message, acc, loop_state) do
    timeout = compute_read_timeout(loop_state)
    run_id = loop_state.run_id

    receive do
      # The Conductor steered the run now (`SymphonyElixir.Conductor.Steer.interrupt/1`): the turn ends
      # here, its process stopped, and the run resumes its session with the steer. One that waited
      # in the mailbox past a turn is dropped: its steer reaches the next turn instead.
      {:conductor_interrupt, ^run_id, sent_ms} when is_binary(run_id) ->
        if Steer.fresh?(sent_ms),
          do: interrupted(port, acc, loop_state),
          else: read_loop(port, on_message, acc, loop_state)

      {^port, {:data, {:eol, line}}} ->
        handle_eol_line(port, on_message, acc, loop_state, line)

      {^port, {:data, {:noeol, partial}}} ->
        read_loop(port, on_message, acc, %{loop_state | pending_line: loop_state.pending_line <> partial})

      {^port, {:exit_status, 0}} ->
        acc |> exited_while_waiting(loop_state) |> finalize_read_result()

      {^port, {:exit_status, status}} ->
        handle_nonzero_exit(exited_while_waiting(acc, loop_state), loop_state, status)
    after
      timeout ->
        handle_read_loop_timeout(port, on_message, acc, loop_state)
    end
  end

  defp interrupted(port, acc, loop_state) do
    Logger.info("#{loop_state.label} turn interrupted by the Conductor run_id=#{loop_state.run_id} session_id=#{inspect(acc.session_id)}")
    close(port)
    {:error, {:conductor_interrupted, acc.session_id}}
  end

  # While the turn waits on a background command only the wait's bound and its heartbeat count.
  defp compute_read_timeout(%{background_wait: %{waiting: true} = wait}) do
    now = System.monotonic_time(:millisecond)
    max(1, min(wait.deadline, wait.heartbeat_at) - now)
  end

  defp compute_read_timeout(%{turn_deadline: turn_deadline, command_deadline: command_deadline, post_completion_deadline: post_completion_deadline}) do
    now = System.monotonic_time(:millisecond)

    [
      max(1, turn_deadline - now),
      command_deadline && max(1, command_deadline - now),
      post_completion_deadline && max(1, post_completion_deadline - now)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.min()
  end

  defp handle_eol_line(port, on_message, acc, loop_state, line) do
    full_line = loop_state.pending_line <> line
    event = loop_state.parse.(full_line)

    tracked_loop_state =
      loop_state
      |> update_command_tracking(event)
      |> track_background_commands(event)

    new_acc =
      event
      |> apply_event(on_message, acc)
      |> then(&loop_state.after_line.(full_line, &1))

    {new_acc, new_loop_state} =
      %{tracked_loop_state | pending_line: ""}
      |> note_continuation(event)
      |> wait_or_finish(new_acc, on_message)

    read_loop(port, on_message, new_acc, new_loop_state)
  end

  defp track_background_commands(loop_state, {:multi, events}) when is_list(events),
    do: Enum.reduce(events, loop_state, &track_background_commands(&2, &1))

  defp track_background_commands(loop_state, {:background_command_started, id}),
    do: %{loop_state | background_commands: MapSet.put(loop_state.background_commands, id)}

  defp track_background_commands(loop_state, {:background_command_ended, id}),
    do: %{loop_state | background_commands: MapSet.delete(loop_state.background_commands, id)}

  defp track_background_commands(loop_state, _event), do: loop_state

  # A terminal event after a wait is the continuation the command's end started.
  defp note_continuation(%{awaiting_continuation: true} = loop_state, event) do
    if terminal_event?(event), do: %{loop_state | awaiting_continuation: false}, else: loop_state
  end

  defp note_continuation(loop_state, _event), do: loop_state

  @terminal_events [:turn_completed, :turn_failed, :usage_limited, :api_unreachable, :rate_limited]

  defp terminal_event?({:multi, events}) when is_list(events), do: Enum.any?(events, &terminal_event?/1)
  defp terminal_event?(event), do: is_tuple(event) and tuple_size(event) > 0 and elem(event, 0) in @terminal_events

  # After the terminal event: wait while a background command runs, else start the grace window.
  # Once the last command ended the harness goes on with the conversation, so the grace waits for
  # the continuation's own terminal event.
  defp wait_or_finish(loop_state, acc, on_message) do
    waiting? = match?(%{waiting: true}, loop_state.background_wait)
    running? = MapSet.size(loop_state.background_commands) > 0

    cond do
      not terminal_event_observed?(acc) ->
        {acc, loop_state}

      # Only a turn that completed waits: a failed one (a usage limit, an unreachable API) ends now.
      running? and not waiting? and not loop_state.awaiting_continuation and is_nil(acc.turn_failed) ->
        {acc, start_background_wait(loop_state, acc, on_message)}

      waiting? and not running? ->
        {put_background_wait(acc, loop_state, :ended), end_background_wait(loop_state)}

      waiting? or loop_state.awaiting_continuation ->
        {acc, loop_state}

      true ->
        {acc, %{loop_state | post_completion_deadline: maybe_start_post_completion_grace(acc, loop_state.post_completion_deadline)}}
    end
  end

  defp start_background_wait(loop_state, acc, on_message) do
    now = System.monotonic_time(:millisecond)
    # The bound counts from the turn's first wait: a continuation that waits again shares it.
    {started_at, deadline} =
      case loop_state.background_wait do
        %{started_at: started_at, deadline: deadline} -> {started_at, deadline}
        nil -> {now, now + background_wait_ms()}
      end

    Logger.info("#{loop_state.label} turn waits on #{MapSet.size(loop_state.background_commands)} background command(s) session_id=#{inspect(acc.session_id)} bound_ms=#{deadline - now}")

    on_message.({:notification, "Waiting on a background command"})

    %{
      loop_state
      | background_wait: %{waiting: true, started_at: started_at, deadline: deadline, heartbeat_at: now + background_heartbeat_ms()},
        post_completion_deadline: nil
    }
  end

  defp end_background_wait(%{background_wait: wait} = loop_state) do
    now = System.monotonic_time(:millisecond)
    # The continuation is a model turn of its own, with a turn's time to finish.
    %{
      loop_state
      | background_wait: %{wait | waiting: false},
        awaiting_continuation: true,
        post_completion_deadline: nil,
        turn_deadline: max(loop_state.turn_deadline, now + loop_state.turn_timeout_ms)
    }
  end

  defp put_background_wait(acc, %{background_wait: %{started_at: started_at}}, outcome) do
    Map.put(acc, :background_wait, %{outcome: outcome, waited_ms: max(0, System.monotonic_time(:millisecond) - started_at)})
  end

  defp waiting_on_background?(%{background_wait: %{waiting: true}}), do: true
  defp waiting_on_background?(_loop_state), do: false

  defp handle_nonzero_exit(acc, loop_state, status) do
    if terminal_event_observed?(acc) do
      Logger.info("#{loop_state.label} terminal result before non-zero exit status=#{status} session_id=#{inspect(Map.get(acc, :session_id))}")

      finalize_read_result(acc)
    else
      case diagnostic_output_text(acc, loop_state) do
        nil -> {:error, {:exit_status, status}}
        output -> {:error, {:exit_status, status, %{stderr: output}}}
      end
    end
  end

  defp exited_while_waiting(acc, loop_state) do
    if waiting_on_background?(loop_state), do: put_background_wait(acc, loop_state, :exited), else: acc
  end

  defp handle_read_loop_timeout(port, on_message, acc, %{background_wait: %{waiting: true} = wait} = loop_state) do
    now = System.monotonic_time(:millisecond)

    if now >= wait.deadline do
      Logger.warning(
        "#{loop_state.label} background command still running at the wait's bound; stopping it session_id=#{inspect(acc.session_id)} commands=#{inspect(MapSet.to_list(loop_state.background_commands))}"
      )

      close(port)
      acc |> put_background_wait(loop_state, :bound) |> finalize_read_result()
    else
      on_message.({:tool_progress, "background command"})
      read_loop(port, on_message, acc, %{loop_state | background_wait: %{wait | heartbeat_at: now + background_heartbeat_ms()}})
    end
  end

  defp handle_read_loop_timeout(_port, _on_message, acc, loop_state), do: handle_read_loop_timeout(acc, loop_state)

  defp handle_read_loop_timeout(acc, %{turn_deadline: turn_deadline, post_completion_deadline: post_completion_deadline, label: label}) do
    now = System.monotonic_time(:millisecond)

    cond do
      post_completion_deadline != nil and now >= post_completion_deadline ->
        Logger.warning("#{label} turn_completed_without_process_exit: finalizing turn after grace period session_id=#{inspect(Map.get(acc, :session_id))}")

        finalize_read_result(acc)

      now >= turn_deadline ->
        {:error, :turn_timeout}

      true ->
        {:error, :command_timeout}
    end
  end

  defp maybe_start_post_completion_grace(acc, nil) do
    if terminal_event_observed?(acc) do
      System.monotonic_time(:millisecond) + post_completion_grace_ms()
    else
      nil
    end
  end

  defp maybe_start_post_completion_grace(_acc, deadline), do: deadline

  defp terminal_event_observed?(acc) do
    Map.get(acc, :turn_completed, false) or is_binary(Map.get(acc, :turn_failed))
  end

  defp post_completion_grace_ms do
    case Application.get_env(:symphony_elixir, :post_completion_grace_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @post_completion_grace_default_ms
    end
  end

  defp finalize_read_result(%{usage_limited: %{} = info}), do: {:error, {:usage_limited, info}}
  defp finalize_read_result(%{api_unreachable: %{} = info}), do: {:error, {:model_api_unreachable, info}}

  defp finalize_read_result(%{turn_failed: reason}) when is_binary(reason) do
    {:error, {:turn_failed, reason}}
  end

  defp finalize_read_result(%{turn_completed: false}) do
    {:error, :no_result_event}
  end

  defp finalize_read_result(acc) do
    {:ok,
     acc
     |> Map.delete(:turn_failed)
     |> Map.delete(:turn_completed)
     |> Map.delete(:diagnostic_output_lines)
     |> Map.delete(:mcp_servers_checked)
     |> Map.delete(:mcp_log_workspace)
     |> Map.delete(:issue)
     |> Map.delete(:usage_limited)
     |> Map.delete(:api_unreachable)
     |> Map.delete(:provider)
     |> Map.delete(:usage_windows)
     |> Map.delete(:label)
     |> Map.delete(:counted_usage)}
  end

  defp update_command_tracking(%{command_timeout_ms: timeout_ms} = loop_state, _event)
       when timeout_ms <= 0 do
    %{loop_state | active_tool_uses: 0, command_deadline: nil}
  end

  defp update_command_tracking(loop_state, event) do
    now = System.monotonic_time(:millisecond)

    {active_tool_uses, command_deadline} =
      apply_command_tracking_event(
        event,
        loop_state.active_tool_uses,
        loop_state.command_deadline,
        loop_state.command_timeout_ms,
        now
      )

    %{loop_state | active_tool_uses: active_tool_uses, command_deadline: command_deadline}
  end

  defp apply_command_tracking_event({:multi, events}, active_tool_uses, command_deadline, timeout_ms, now)
       when is_list(events) do
    Enum.reduce(events, {active_tool_uses, command_deadline}, fn event, {active, deadline} ->
      apply_command_tracking_event(event, active, deadline, timeout_ms, now)
    end)
  end

  defp apply_command_tracking_event({:tool_use, _}, active_tool_uses, _command_deadline, timeout_ms, now) do
    {active_tool_uses + 1, now + timeout_ms}
  end

  defp apply_command_tracking_event({:tool_result, _}, active_tool_uses, command_deadline, _timeout_ms, _now) do
    active_tool_uses = max(active_tool_uses - 1, 0)
    command_deadline = if active_tool_uses == 0, do: nil, else: command_deadline

    {active_tool_uses, command_deadline}
  end

  defp apply_command_tracking_event({:turn_completed, _}, _active_tool_uses, _command_deadline, _timeout_ms, _now),
    do: {0, nil}

  defp apply_command_tracking_event({:turn_failed, _}, _active_tool_uses, _command_deadline, _timeout_ms, _now),
    do: {0, nil}

  defp apply_command_tracking_event({:usage_limited, _info}, _active_tool_uses, _command_deadline, _timeout_ms, _now),
    do: {0, nil}

  defp apply_command_tracking_event({:api_unreachable, _info}, _active_tool_uses, _command_deadline, _timeout_ms, _now),
    do: {0, nil}

  defp apply_command_tracking_event(
         {:rate_limited, _info, _reason},
         _active_tool_uses,
         _command_deadline,
         _timeout_ms,
         _now
       ),
       do: {0, nil}

  defp apply_command_tracking_event(_event, active_tool_uses, command_deadline, _timeout_ms, _now),
    do: {active_tool_uses, command_deadline}

  defp apply_event({:multi, events}, on_message, acc) when is_list(events) do
    Enum.reduce(events, acc, fn child, acc -> apply_event(child, on_message, acc) end)
  end

  defp apply_event({:session_started, session_id}, on_message, acc) do
    on_message.({:session_started, session_id})
    %{acc | session_id: session_id}
  end

  defp apply_event({:turn_completed, result}, on_message, acc) do
    on_message.({:turn_completed, result})
    acc |> Map.merge(result) |> Map.put(:turn_completed, true)
  end

  defp apply_event({:token_usage_delta, delta}, on_message, acc) do
    {delta, acc} = uncounted_usage(delta, acc)

    uncached_input =
      Map.get(acc, :uncached_input_tokens, Map.get(acc, :input_tokens, 0)) +
        Map.get(delta, :uncached_input_tokens, Map.get(delta, :input_tokens, 0))

    output = Map.get(acc, :output_tokens, 0) + Map.get(delta, :output_tokens, 0)
    cached = Map.get(acc, :cached_input_tokens, 0) + Map.get(delta, :cached_input_tokens, 0)

    cache_creation =
      Map.get(acc, :cache_creation_input_tokens, 0) + Map.get(delta, :cache_creation_input_tokens, 0)

    cumulative = %{
      input_tokens: uncached_input + cached + cache_creation,
      uncached_input_tokens: uncached_input,
      cached_input_tokens: cached,
      cache_creation_input_tokens: cache_creation,
      output_tokens: output,
      total_tokens: uncached_input + cached + cache_creation + output
    }

    on_message.({:token_usage, cumulative})

    acc
    |> Map.put(:input_tokens, uncached_input + cached + cache_creation)
    |> Map.put(:uncached_input_tokens, uncached_input)
    |> Map.put(:output_tokens, output)
    |> Map.put(:cached_input_tokens, cached)
    |> Map.put(:cache_creation_input_tokens, cache_creation)
  end

  defp apply_event({:turn_failed, reason}, on_message, acc) do
    on_message.({:turn_failed, reason})
    %{acc | turn_failed: reason}
  end

  defp apply_event({:rate_limited, info, reason}, on_message, acc) do
    on_message.({:rate_limited, info})
    on_message.({:turn_failed, reason})
    %{acc | turn_failed: reason}
  end

  # A rejection from the `rate_limit_event` wins over the result text that follows it:
  # only the event carries the window and the epoch reset time.
  defp apply_event({:usage_limited, info}, on_message, acc) do
    info =
      case acc.usage_limited do
        %{source: :rate_limit_event} = earlier -> earlier
        _none_or_fallback -> info
      end

    reason = usage_limit_message(info)
    on_message.({:usage_limited, info})
    on_message.({:turn_failed, reason})
    %{acc | usage_limited: info, turn_failed: reason}
  end

  defp apply_event({:api_unreachable, info}, on_message, acc) do
    info = %{info | provider: acc.provider}
    reason = if Map.get(info, :cause) == :sign_in, do: "the agent could not sign in (#{info.error})", else: "model API unreachable (#{info.error})"
    on_message.({:turn_failed, reason})
    %{acc | api_unreachable: info, turn_failed: reason}
  end

  defp apply_event({:usage_window, message, %{window: window} = usage_window}, on_message, acc) do
    windows = Map.put(acc.usage_windows, window, Map.take(usage_window, [:status, :resets_at, :utilization]))
    on_message.({:usage_window, message, windows})
    %{acc | usage_windows: windows}
  end

  defp apply_event({:rate_limit_info, info}, _on_message, acc) do
    Logger.warning("#{acc.label} rate_limit_event not allowed #{issue_log_context(acc.issue)} session_id=#{inspect(acc.session_id)} rate_limit_info=#{inspect(info)}")

    acc
  end

  # Claude Code sends one every few seconds while a tool runs. It is forwarded so a long tool
  # call (a full test suite) counts as activity for the orchestrator's no-progress watchdog.
  defp apply_event({:tool_progress, _tool_name} = event, on_message, acc) do
    on_message.(event)
    acc
  end

  defp apply_event({kind, _id}, _on_message, acc) when kind in [:background_command_started, :background_command_ended], do: acc

  defp apply_event({:malformed, raw}, _on_message, acc) do
    Logger.debug("Unparseable agent output line: #{inspect(raw)}")
    record_diagnostic_output(acc, raw)
  end

  defp apply_event({kind, _payload} = event, on_message, acc)
       when kind in [:tool_use, :tool_result, :notification, :agent_text] do
    on_message.(event)
    acc
  end

  # Claude writes one stream line per content block of a model message (its text, then each tool
  # call), and every line repeats the whole message's usage, so summing the lines counts a message
  # once per block. A delta that names its message adds only what that message's usage grew by
  # since its last line: each message counts once.
  @counted_usage_fields [:uncached_input_tokens, :cached_input_tokens, :cache_creation_input_tokens, :output_tokens]

  defp uncounted_usage(%{message_id: message_id} = delta, acc) when is_binary(message_id) do
    counted = Map.get(acc.counted_usage, message_id, %{})

    usage =
      Map.new(@counted_usage_fields, fn field ->
        {field, max(Map.get(delta, field, 0), Map.get(counted, field, 0))}
      end)

    growth = Map.new(@counted_usage_fields, fn field -> {field, usage[field] - Map.get(counted, field, 0)} end)
    {growth, %{acc | counted_usage: Map.put(acc.counted_usage, message_id, usage)}}
  end

  defp uncounted_usage(delta, acc), do: {delta, acc}

  defp record_diagnostic_output(acc, raw) when is_binary(raw) do
    line = normalize_diagnostic_output_line(raw)

    if line == "" do
      acc
    else
      lines =
        acc
        |> Map.get(:diagnostic_output_lines, [])
        |> Kernel.++([line])
        |> Enum.take(-@diagnostic_output_line_count)

      Map.put(acc, :diagnostic_output_lines, lines)
    end
  end

  defp diagnostic_output_text(acc, loop_state) do
    pending_line = normalize_diagnostic_output_line(Map.get(loop_state, :pending_line, ""))

    lines =
      acc
      |> Map.get(:diagnostic_output_lines, [])
      |> maybe_append_pending_diagnostic_line(pending_line)
      |> Enum.take(-@diagnostic_output_line_count)

    case Enum.join(lines, "\n") do
      "" -> nil
      text -> text
    end
  end

  defp maybe_append_pending_diagnostic_line(lines, ""), do: lines
  defp maybe_append_pending_diagnostic_line(lines, pending_line), do: lines ++ [pending_line]

  defp normalize_diagnostic_output_line(raw) when is_binary(raw) do
    raw
    |> strip_ansi()
    |> String.trim()
    |> truncate_diagnostic_output_line()
  end

  defp truncate_diagnostic_output_line(line) when byte_size(line) <= @diagnostic_output_line_max_bytes, do: line

  defp truncate_diagnostic_output_line(line) do
    truncated = binary_part(line, 0, @diagnostic_output_line_max_bytes)

    if String.valid?(truncated) do
      truncated
    else
      truncate_valid_utf8_prefix(line, @diagnostic_output_line_max_bytes - 1)
    end
  end

  defp truncate_valid_utf8_prefix(_line, byte_count) when byte_count <= 0, do: ""

  defp truncate_valid_utf8_prefix(line, byte_count) do
    truncated = binary_part(line, 0, byte_count)

    if String.valid?(truncated) do
      truncated
    else
      truncate_valid_utf8_prefix(line, byte_count - 1)
    end
  end

  defp strip_ansi(text) when is_binary(text), do: String.replace(text, ~r/\x1b\[[0-9;]*m/, "")

  @doc "Kills the processes the port's command started, then closes the port. A port that already closed is a finished turn."
  @spec close(port()) :: :ok
  def close(port) do
    terminate_port_descendants(port)
    Port.close(port)
    :ok
  rescue
    # Killing descendants can make the CLI exit, and the port can close at
    # any moment after a turn timeout. A closed port is a finished turn.
    ArgumentError -> :ok
  end

  # Send SIGKILL to descendants of the port's OS process before closing the
  # port. Port.close only signals the immediate child, so tool subprocesses
  # spawned by Claude (e.g. a long-running bash loop) would otherwise be
  # reparented to init and keep running.
  defp terminate_port_descendants(port) do
    with {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 <-
           safe_port_info(port, :os_pid) do
      os_pid
      |> collect_descendant_pids([])
      |> Enum.uniq()
      |> Enum.each(&kill_pid/1)
    end

    :ok
  rescue
    exception ->
      Logger.debug("Claude port descendant cleanup raised: #{Exception.message(exception)}")
      :ok
  end

  defp safe_port_info(port, key) do
    Port.info(port, key)
  rescue
    _ -> nil
  end

  defp collect_descendant_pids(pid, acc) when is_integer(pid) and pid > 0 do
    case pgrep_children(pid) do
      [] ->
        acc

      children ->
        Enum.reduce(children, acc, fn child_pid, acc ->
          collect_descendant_pids(child_pid, [child_pid | acc])
        end)
    end
  end

  defp collect_descendant_pids(_pid, acc), do: acc

  defp pgrep_children(pid) when is_integer(pid) do
    case System.find_executable("pgrep") do
      nil -> []
      pgrep -> run_pgrep_children(pgrep, pid)
    end
  rescue
    _ -> []
  end

  defp run_pgrep_children(pgrep, pid) do
    case System.cmd(pgrep, ["-P", to_string(pid)], stderr_to_stdout: true) do
      {output, status} when status in [0, 1] -> parse_pgrep_output(output)
      _ -> []
    end
  end

  defp parse_pgrep_output(output) do
    output
    |> String.split(["\n", " ", "\t"], trim: true)
    |> Enum.flat_map(&parse_pgrep_pid_token/1)
  end

  defp parse_pgrep_pid_token(token) do
    case Integer.parse(token) do
      {child_pid, ""} when child_pid > 0 -> [child_pid]
      _ -> []
    end
  end

  defp kill_pid(pid) when is_integer(pid) and pid > 0 do
    _ = System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  @doc "The line a usage-limit rejection reads as: the window and when it resets."
  @spec usage_limit_message(map()) :: String.t()
  def usage_limit_message(%{window: window, resets_at: resets_at}) do
    reset = if resets_at, do: " resets_at=#{DateTime.to_iso8601(resets_at)}", else: ""
    "usage_limited #{window || "unknown"}#{reset}"
  end

  defp issue_log_context(issue) when is_map(issue),
    do: "issue_id=#{inspect(Map.get(issue, :id))} issue_identifier=#{inspect(Map.get(issue, :identifier))}"

  defp issue_log_context(_issue), do: "issue_id=nil issue_identifier=nil"
end
