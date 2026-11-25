defmodule SymphonyElixir.PhaseSteps.Transcript do
  @moduledoc """
  A run's steps in words: what the agent said, each tool it called with its arguments summarised
  and each result summarised, as lines of one shape (`t:line/0`).

  Two sources give the lines. Once a turn ends, `read_session/3` reads what it added to its session's
  transcript (`SymphonyElixir.Artifacts.Transcript`), the one place that holds a tool's arguments, and
  the step runner keeps a step's lines as a `transcript` artifact on its `step.completed`
  (`SymphonyElixir.PhaseSteps`). While a run is live, `run_now/3` reads the step it is on from the
  ledger and that step's lines from the session stream the orchestrator buffers, where a Claude tool
  call carries its input as the fields `tool_fields/1` gives; the transcript window's data source
  stays its own.

  What the agent said is a note, kept whole: never cut, its line breaks kept, so the app renders its
  Markdown. A tool call names its tool (`tool`) and the file it names (`file`) as fields of its line,
  so the app counts and names what a step did from data, never from the line's text. A result keeps
  its first lines, so a failure shows what came back.

  A line is rendered from one transcript entry at a time and a slice is cut only at a whole entry, so
  a session's slices concatenated are the lines of the whole session. A user's prompt, the agent's
  thinking and an entry of any other type are no lines.
  """

  alias SymphonyElixir.Artifacts.Transcript, as: SessionFile
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketEvents.Event

  @args_chars 300
  @result_chars 500
  # The input fields that say what a tool call does, in the order they are tried.
  @summary_keys ~w(command file_path path pattern query url description prompt)
  # The input fields that name the file a call reads, writes or edits, in the order they are tried.
  @file_keys ~w(file_path notebook_path path)

  @typedoc """
  One line: its `kind` (`say`, `tool` or `result`), its `text` and when it happened (`at`, absent when
  the source gave no time). A tool call also names its tool (`tool`) and, when its input names one,
  its file (`file`). A result also says how long its tool took (`duration_ms`, read from the
  transcript) and `failed: true` when the tool failed.
  """
  @type line :: %{
          required(:kind) => String.t(),
          required(:text) => String.t(),
          optional(:at) => String.t(),
          optional(:tool) => String.t(),
          optional(:file) => String.t(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:failed) => true
        }

  @typedoc "How far each session's transcript was read, in bytes, by session id."
  @type offsets :: %{optional(String.t()) => non_neg_integer()}

  @typedoc "The step a live run is on: from its `step.started`, with when it started."
  @type current_step :: %{id: String.t(), title: String.t() | nil, mode: String.t() | nil, started_at: String.t()}

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
    {say_lines(text, at), open_tools}
  end

  defp block_lines("assistant", %{"type" => "tool_use", "name" => name, "input" => input} = block, open_tools, at) do
    {[tool_line(name, tool_fields(input), at)], Map.put(open_tools, Map.get(block, "id"), at)}
  end

  defp block_lines("user", %{"type" => "tool_result"} = block, open_tools, at) do
    {started, open_tools} = Map.pop(open_tools, Map.get(block, "tool_use_id"))

    line =
      "result"
      |> line(block |> Map.get("content") |> result_text() |> result_summary(), at)
      |> put_present(:duration_ms, elapsed_ms(started, at))
      |> put_present(:failed, if(Map.get(block, "is_error") == true, do: true))

    {[line], open_tools}
  end

  defp block_lines(_type, _block, open_tools, _at), do: {[], open_tools}

  defp line(kind, text, at), do: put_present(%{kind: kind, text: text}, :at, at)

  # A note, whole: trimmed, its line breaks kept; one that says nothing is no line.
  defp say_lines(text, at) when is_binary(text) do
    case String.trim(text) do
      "" -> []
      said -> [line("say", said, at)]
    end
  end

  defp say_lines(_text, _at), do: []

  defp tool_line(name, fields, at) do
    summary = Map.get(fields, :summary, "")
    text = if summary == "", do: name, else: name <> ": " <> summary

    "tool" |> line(text, at) |> Map.put(:tool, name) |> put_present(:file, Map.get(fields, :file))
  end

  @doc """
  What a tool call's `input` says as the fields of its line: what it does in short (`summary`, from
  the first of its command, file, path, pattern, query, url, description or prompt, else the input
  itself) and the file it reads, writes or edits (`file`, absent when it names none).
  """
  @spec tool_fields(term()) :: %{required(:summary) => String.t(), optional(:file) => String.t()}
  def tool_fields(input) when is_map(input) do
    put_present(%{summary: summary(input, @args_chars)}, :file, first_text(input, @file_keys))
  end

  def tool_fields(input), do: %{summary: summary(input, @args_chars)}

  defp put_present(line, _key, nil), do: line
  defp put_present(line, key, value), do: Map.put(line, key, value)

  defp summary(input, max) when is_map(input) do
    input |> tool_summary() |> summary(max)
  end

  defp summary(text, max) when is_binary(text), do: text |> String.replace(~r/\s+/, " ") |> bound(max)
  defp summary(_other, _max), do: ""

  defp tool_summary(input), do: first_text(input, @summary_keys) || Jason.encode!(input)

  defp first_text(input, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(input, key) do
        value when is_binary(value) and value != "" -> value
        _absent -> nil
      end
    end)
  end

  # What came back, its first lines kept as they are: blank lines dropped, each line's end trimmed.
  defp result_summary(text) when is_binary(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> bound(@result_chars)
  end

  defp result_summary(_other), do: ""

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
  and did not complete (`current_step`, nil when none is open) and the run's lines in `stream`, the
  run's buffered session updates (`recent_lines`, every line the buffer still holds, so the app
  counts the actions since the newest note and shows that note whole). With a step open they are
  that step's lines; with none open, the lines since the run's last step completed, or the whole
  stream's for a run that walks no steps (a QA or Code Review run).
  """
  @spec run_now(String.t() | nil, String.t() | nil, [map()]) ::
          %{current_step: current_step() | nil, recent_lines: [line()]}
  def run_now(issue_id, run_id, stream) when is_list(stream) do
    case last_step_event(issue_id, run_id) do
      %Event{type: "step.started", at: at, payload: payload} ->
        step = %{id: payload.step_id, title: Map.get(payload, :title), mode: Map.get(payload, :mode), started_at: DateTime.to_iso8601(at)}
        %{current_step: step, recent_lines: recent_lines(stream, at)}

      %Event{at: at} ->
        %{current_step: nil, recent_lines: recent_lines(stream, at)}

      nil ->
        %{current_step: nil, recent_lines: recent_lines(stream, nil)}
    end
  end

  defp last_step_event(issue_id, run_id) when is_binary(issue_id) and is_binary(run_id) do
    case RunStore.list_ticket_events(issue_id, types: ["step.started", "step.completed"], run_id: run_id) do
      [_ | _] = events -> List.last(events)
      _no_step -> nil
    end
  end

  defp last_step_event(_issue_id, _run_id), do: nil

  defp recent_lines(stream, since), do: Enum.flat_map(stream, &stream_line(&1, since))

  defp stream_line(%{timestamp: %DateTime{} = at} = update, since) do
    if since && DateTime.compare(at, since) == :lt, do: [], else: stream_lines(update, DateTime.to_iso8601(at))
  end

  defp stream_line(_update, _since), do: []

  defp stream_lines(%{event: :agent_text, payload: %{params: %{msg: %{content: text}}}}, at), do: say_lines(text, at)

  defp stream_lines(%{event: :tool_use, payload: %{params: %{tool: name} = params}}, at) when is_binary(name),
    do: [tool_line(name, Map.take(params, [:summary, :file]), at)]

  defp stream_lines(%{event: :tool_result, payload: %{params: %{text: text} = params}}, at) do
    failed = if Map.get(params, :failed) == true, do: true
    [put_present(line("result", result_summary(text), at), :failed, failed)]
  end

  defp stream_lines(_update, _at), do: []
end
