defmodule SymphonyElixir.PhaseSteps.Transcript do
  @moduledoc """
  A run's steps in words: what the agent said, each tool it called with its arguments summarised
  and each result summarised, as lines of one shape (`t:line/0`).

  Two sources give the lines. Once a turn ends, `read_session/3` reads what it added to its session's
  transcript (`SymphonyElixir.Artifacts.Transcript`), the one place that holds a tool's arguments, and
  the step runner keeps a step's lines as a `transcript` artifact on its `step.completed`
  (`SymphonyElixir.PhaseSteps`). While a run is live, `run_now/3` reads the step it is on from the
  ledger and that step's newest lines from the session stream the orchestrator buffers, where a tool
  call carries only its name; the transcript window's data source stays its own.

  A line is rendered from one transcript entry at a time and a slice is cut only at a whole entry, so
  a session's slices concatenated are the lines of the whole session. A user's prompt, the agent's
  thinking and an entry of any other type are no lines.
  """

  alias SymphonyElixir.Artifacts.Transcript, as: SessionFile
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketEvents.Event

  @recent_lines 20
  @recent_chars 500
  @say_chars 4_000
  @args_chars 300
  @result_chars 500
  # The input fields that say what a tool call does, in the order they are tried.
  @summary_keys ~w(command file_path path pattern query url description prompt)

  @typedoc """
  One line: its `kind` (`say`, `tool` or `result`), its `text` and when it happened (`at`, absent when
  the source gave no time). A result also says how long its tool took (`duration_ms`, read from the
  transcript) and `failed: true` when the tool failed.
  """
  @type line :: %{
          required(:kind) => String.t(),
          required(:text) => String.t(),
          optional(:at) => String.t(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:failed) => true
        }

  @typedoc "How far each session's transcript was read, in bytes, by session id."
  @type offsets :: %{optional(String.t()) => non_neg_integer()}

  @typedoc "The step a live run is on: from its `step.started`, with when it started."
  @type current_step :: %{id: String.t(), title: String.t() | nil, mode: String.t() | nil, started_at: String.t()}

  @doc "How many of the current step's newest lines `run_now/3` gives at most."
  @spec recent_lines_bound() :: pos_integer()
  def recent_lines_bound, do: @recent_lines

  @doc """
  The lines `session_id`'s transcript added since `offsets` (whole entries only, so one still being
  written waits for the next read), and the offsets past them. A session with no transcript Symphony
  reads (Codex's, or an unreadable file) has none, and the offsets stay.
  """
  @spec read_session(Path.t() | nil, String.t() | nil, offsets()) :: {[line()], offsets()}
  def read_session(workspace, session_id, offsets) do
    with {:ok, path} <- SessionFile.locate(:claude, workspace, session_id, nil),
         {:ok, text} <- File.read(path) do
      from = min(Map.get(offsets, session_id, 0), byte_size(text))
      whole = whole_entries(binary_part(text, from, byte_size(text) - from))
      {lines(whole), Map.put(offsets, session_id, from + byte_size(whole))}
    else
      _none -> {[], offsets}
    end
  end

  defp whole_entries(text) do
    case text |> :binary.matches("\n") |> List.last() do
      nil -> ""
      {at, 1} -> binary_part(text, 0, at + 1)
    end
  end

  @doc "The lines of a session transcript's `text`: JSON lines, an entry that says nothing skipped."
  @spec lines(String.t()) :: [line()]
  def lines(text) when is_binary(text) do
    {lines, _open_tools} = text |> String.split("\n", trim: true) |> Enum.flat_map_reduce(%{}, &entry_lines/2)
    lines
  end

  defp entry_lines(raw, open_tools) do
    case Jason.decode(raw) do
      {:ok, %{"type" => type, "message" => %{"content" => blocks}} = entry} when is_list(blocks) ->
        Enum.flat_map_reduce(blocks, open_tools, &block_lines(type, &1, &2, Map.get(entry, "timestamp")))

      _says_nothing ->
        {[], open_tools}
    end
  end

  defp block_lines("assistant", %{"type" => "text", "text" => text}, open_tools, at) do
    case bound(text, @say_chars) do
      "" -> {[], open_tools}
      said -> {[line("say", said, at)], open_tools}
    end
  end

  defp block_lines("assistant", %{"type" => "tool_use", "name" => name, "input" => input} = block, open_tools, at) do
    {[line("tool", name <> ": " <> summary(input, @args_chars), at)], Map.put(open_tools, Map.get(block, "id"), at)}
  end

  defp block_lines("user", %{"type" => "tool_result"} = block, open_tools, at) do
    {started, open_tools} = Map.pop(open_tools, Map.get(block, "tool_use_id"))

    line =
      "result"
      |> line(block |> Map.get("content") |> result_text() |> summary(@result_chars), at)
      |> put_present(:duration_ms, elapsed_ms(started, at))
      |> put_present(:failed, if(Map.get(block, "is_error") == true, do: true))

    {[line], open_tools}
  end

  defp block_lines(_type, _block, open_tools, _at), do: {[], open_tools}

  defp line(kind, text, at), do: put_present(%{kind: kind, text: text}, :at, at)

  defp put_present(line, _key, nil), do: line
  defp put_present(line, key, value), do: Map.put(line, key, value)

  defp summary(input, max) when is_map(input) do
    input |> tool_summary() |> summary(max)
  end

  defp summary(text, max) when is_binary(text), do: text |> String.replace(~r/\s+/, " ") |> bound(max)
  defp summary(_other, _max), do: ""

  defp tool_summary(input) do
    Enum.find_value(@summary_keys, Jason.encode!(input), fn key ->
      case Map.get(input, key) do
        value when is_binary(value) and value != "" -> value
        _absent -> nil
      end
    end)
  end

  defp result_text(content) when is_list(content), do: Enum.map_join(content, " ", &result_part/1)
  defp result_text(content), do: content

  defp result_part(%{"type" => "text", "text" => text}), do: text
  defp result_part(%{"type" => type}), do: "[#{type}]"
  defp result_part(_other), do: ""

  defp elapsed_ms(started, at) when is_binary(started) and is_binary(at) do
    with {:ok, started, _offset} <- DateTime.from_iso8601(started),
         {:ok, at, _offset} <- DateTime.from_iso8601(at) do
      max(DateTime.diff(at, started, :millisecond), 0)
    else
      _no_time -> nil
    end
  end

  defp elapsed_ms(_started, _at), do: nil

  defp bound(text, max) do
    text = String.trim(text)
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  @doc "`lines` as the bytes of a step's artifact: one JSON object a line."
  @spec encode([line()]) :: String.t()
  def encode(lines) when is_list(lines), do: Enum.map_join(lines, &(Jason.encode!(&1) <> "\n"))

  @doc """
  What the ticket read's `running` says of the live run `run_id` of `issue_id`: the step it started
  and did not complete (`current_step`, nil between steps) and that step's newest lines in `stream`,
  the run's buffered session updates (`recent_lines`, at most `recent_lines_bound/0`).
  """
  @spec run_now(String.t() | nil, String.t() | nil, [map()]) :: %{current_step: current_step() | nil, recent_lines: [line()]}
  def run_now(issue_id, run_id, stream) when is_list(stream) do
    case open_step(issue_id, run_id) do
      %Event{at: at, payload: payload} ->
        step = %{id: payload.step_id, title: Map.get(payload, :title), mode: Map.get(payload, :mode), started_at: DateTime.to_iso8601(at)}
        %{current_step: step, recent_lines: stream |> Enum.flat_map(&stream_line(&1, at)) |> Enum.take(-@recent_lines)}

      nil ->
        %{current_step: nil, recent_lines: []}
    end
  end

  defp open_step(issue_id, run_id) when is_binary(issue_id) and is_binary(run_id) do
    with [_ | _] = events <- RunStore.list_ticket_events(issue_id, types: ["step.started", "step.completed"], run_id: run_id),
         %Event{type: "step.started"} = step <- List.last(events) do
      step
    else
      _no_open_step -> nil
    end
  end

  defp open_step(_issue_id, _run_id), do: nil

  defp stream_line(%{timestamp: %DateTime{} = at} = update, since) do
    case {DateTime.compare(at, since), stream_text(update)} do
      {:lt, _text} -> []
      {_at_or_after, nil} -> []
      {_at_or_after, {kind, text}} -> [line(kind, summary(text, @recent_chars), DateTime.to_iso8601(at))]
    end
  end

  defp stream_line(_update, _since), do: []

  defp stream_text(%{event: :agent_text, payload: %{params: %{msg: %{content: text}}}}), do: {"say", text}
  defp stream_text(%{event: :tool_use, payload: %{params: %{tool: name}}}), do: {"tool", name}
  defp stream_text(%{event: :tool_result, payload: %{params: %{text: text}}}), do: {"result", text}
  defp stream_text(_update), do: nil
end
