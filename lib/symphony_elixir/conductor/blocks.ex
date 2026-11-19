defmodule SymphonyElixir.Conductor.Blocks do
  @moduledoc """
  The message blocks of a Conductor update. The Conductor only picks a block and points at facts
  (`SymphonyElixir.Conductor.Answer` reads the picks); Symphony resolves each pick from the ticket's
  own records when it records `conductor.update`, so the app draws data Symphony wrote and never a
  number or a state the model wrote. A block that cannot be resolved is dropped, with a log line,
  and never fails the turn.

  The resolved shapes (all keys present unless marked optional):

    * `steps`: `run_id`, `run_kind`, `steps` (`step_id`, `title`, `outcome` of `passed`, `failed` or
      `skipped`, `duration_ms`, `returns_to`; the newest 8);
    * `evidence`: `items` (`event_id`, `artifact_id`, `caption`; 1 to 4);
    * `budget`: `tokens_used`, `tokens_cap` (left out when no cap is set), `parts` (`kind`, `runs`,
      `tokens` by run kind, largest first, at most 5);
    * `path`: `stops` (`phase`, `state` of `done`, `failed`, `current` or `upcoming`, `times`,
      `run_number`), `loops`, `elapsed_ms`;
    * `attempts`: `run_id`, `step_id`, `title`, `tries` (`at`, `outcome`, `duration_ms`, `line`; the
      newest 5), `same_line`;
    * `compare`: `expected` and `actual`, each `%{text}` or `%{event_id, artifact_id}`;
    * `findings`: `items` (`id`, `title`, `state` of `open` or `resolved`, `severity`; at most 8, open
      first), `open`, `resolved`;
    * `epic`: `identifier`, `title`, `rows` (`identifier`, `title`, `state`, `current`);
    * `question` (added by Symphony when the answer asked the person): `decision_id`, `title`,
      `question`, `options` (`label`, `recommended`).
  """

  require Logger

  alias SymphonyElixir.{Artifacts, RunStore, TicketEvents, TicketState}
  alias SymphonyElixir.Conductor.Facts
  alias SymphonyElixir.TicketEvents.Event

  @steps_max 8
  @tries_max 5
  @items_max 4
  @findings_max 8
  @parts_max 5
  @caption_max 80
  @title_max 100
  @line_max 200
  @step_outcomes ["passed", "failed", "skipped"]
  @normal_path ["In Progress", "Code Review", "QA", "Merging", "Done"]
  @terminal ["Done", "Canceled", "Cancelled"]
  @error_line ~r/error|fail|exception|panic|undefined|cannot|not found|refused/i

  @typedoc "What `resolve/3` reads: the ticket's `record`, its `events` (oldest first), the facts' `budget` and the run a block without a `run_id` is about."
  @type context :: %{
          record: map(),
          events: [Event.t()],
          budget: map(),
          default_run_id: String.t() | nil,
          now: DateTime.t()
        }

  @doc """
  Resolves the `picks` (`Answer`'s `blocks`) against `context`, in the Conductor's order. A pick that
  cannot be resolved is left out and logged.
  """
  @spec resolve([map()], context()) :: [map()]
  def resolve(picks, context) when is_list(picks) do
    Enum.flat_map(picks, fn pick ->
      case resolve_one(pick, context) do
        {:ok, block} ->
          [block]

        {:error, why} ->
          Logger.warning("Conductor dropped a #{pick.type} block issue_id=#{context.record.issue_id}: #{why}")
          []
      end
    end)
  end

  defp resolve_one(%{type: "steps"} = pick, context), do: steps(Map.get(pick, :run_id) || context.default_run_id, context)
  defp resolve_one(%{type: "evidence", refs: refs}, context), do: evidence(refs, context.events)
  defp resolve_one(%{type: "budget"}, context), do: budget(context)
  defp resolve_one(%{type: "path"}, context), do: path(context)
  defp resolve_one(%{type: "attempts", step_id: step_id} = pick, context), do: attempts(Map.get(pick, :run_id) || context.default_run_id, step_id, context.events)
  defp resolve_one(%{type: "compare", expected: expected, actual: actual}, context), do: compare(expected, actual, context.events)
  defp resolve_one(%{type: "findings"}, context), do: findings(context.events)
  defp resolve_one(%{type: "epic"}, context), do: epic(context.record)

  @doc """
  The `question` block for the request the answer's `ask_person` made: the open `question.asked`
  event with its title, the newest one when several carry it. Nil when none is found.
  """
  @spec question([Event.t()], map()) :: map() | nil
  def question(events, %{title: title}) do
    case events |> Enum.filter(&(&1.type == "question.asked" and field(&1, :title) == title)) |> List.last() do
      nil ->
        nil

      %Event{} = asked ->
        options = for %{} = option <- List.wrap(field(asked, :options)), is_binary(label(option)), do: %{label: label(option), recommended: recommended?(option)}
        question = field(asked, :question)
        %{type: "question", decision_id: field(asked, :question_id), title: title, question: question, options: options}
    end
  end

  # `Questions` keeps the flag as `recommended?`.
  defp recommended?(option), do: Enum.any?([:recommended?, :recommended, "recommended?", "recommended"], &(Map.get(option, &1) == true))

  defp label(option), do: Map.get(option, :label, Map.get(option, "label"))

  # Steps.

  defp steps(nil, _context), do: {:error, "no run to show"}

  defp steps(run_id, %{events: events}) do
    steps =
      for %Event{type: "step.completed", run_id: ^run_id} = step <- events, field(step, :outcome) in @step_outcomes do
        %{step_id: field(step, :step_id), title: field(step, :title), outcome: field(step, :outcome)}
        |> put_present(:duration_ms, field(step, :duration_ms))
        |> put_present(:returns_to, field(step, :returns_to))
      end

    case Enum.take(steps, -@steps_max) do
      [] -> {:error, "run #{run_id} has no steps"}
      steps -> {:ok, %{type: "steps", run_id: run_id, run_kind: run_kind(events, run_id), steps: steps}}
    end
  end

  defp run_kind(events, run_id) do
    Enum.find_value(events, fn
      %Event{type: "run.started"} = started -> if field(started, :run_id) == run_id, do: field(started, :run_kind)
      _event -> nil
    end)
  end

  # Evidence.

  defp evidence(refs, events) do
    items = for ref <- refs, %Event{id: ^ref} = event <- events, item = evidence_item(event), do: item

    case Enum.take(items, @items_max) do
      [] -> {:error, "none of the refs carries a screenshot"}
      items -> {:ok, %{type: "evidence", items: items}}
    end
  end

  defp evidence_item(%Event{} = event) do
    case screenshot(event) do
      nil -> nil
      artifact_id -> put_present(%{event_id: event.id, artifact_id: artifact_id}, :caption, caption(event))
    end
  end

  # The artifact the app loads a screenshot from: the first screenshot among the event's artifacts.
  defp screenshot(%Event{artifacts: artifacts}) do
    Enum.find(artifacts, fn id ->
      match?({:ok, %{kind: "screenshot"}}, Artifacts.get(id))
    end)
  end

  defp caption(event), do: Facts.cut(field(event, :caption) || field(event, :description), @caption_max)

  # Compare.

  defp compare(expected, actual, events) do
    with {:ok, expected} <- side(expected, events),
         {:ok, actual} <- side(actual, events) do
      {:ok, %{type: "compare", expected: expected, actual: actual}}
    end
  end

  defp side(%{text: text}, _events), do: {:ok, %{text: text}}

  defp side(%{ref: ref}, events) do
    with %Event{} = event <- Enum.find(events, &(&1.id == ref)),
         artifact_id when is_binary(artifact_id) <- screenshot(event) do
      {:ok, %{event_id: event.id, artifact_id: artifact_id}}
    else
      _none -> {:error, "#{ref} is not an event with a screenshot"}
    end
  end

  # Budget.

  defp budget(%{events: events, budget: budget}) do
    ended = Enum.filter(events, &(&1.type == "run.ended"))

    parts =
      ended
      |> Enum.group_by(&(field(&1, :run_kind) || "other"))
      |> Enum.map(fn {kind, runs} -> %{kind: kind, runs: length(runs), tokens: runs |> Enum.map(&(Facts.tokens(field(&1, :tokens)) || 0)) |> Enum.sum()} end)
      |> Enum.sort_by(&{-&1.tokens, &1.kind})
      |> Enum.take(@parts_max)

    if parts == [] do
      {:error, "no run has ended"}
    else
      {:ok, put_present(%{type: "budget", tokens_used: budget.tokens_used, parts: parts}, :tokens_cap, budget.tokens_cap)}
    end
  end

  # Path.

  defp path(%{events: events, record: record, now: now}) do
    entered = for %Event{type: "phase.entered"} = event <- events, is_binary(field(event, :to)), do: {field(event, :to), event}

    case entered do
      [] ->
        {:error, "the ticket entered no phase"}

      [{_phase, first} | _rest] ->
        folded = fold(entered)
        stops = stops(folded, events)
        {:ok, %{type: "path", stops: stops, loops: loops(folded), elapsed_ms: elapsed(first, events, record, now)}}
    end
  end

  # Consecutive repeats of one phase, with how many times it was entered.
  defp fold(entered) do
    entered
    |> Enum.chunk_by(fn {phase, _event} -> phase end)
    |> Enum.map(fn [{phase, _event} | _rest] = chunk -> %{phase: phase, times: length(chunk)} end)
  end

  defp stops(folded, events) do
    last = length(folded) - 1

    met =
      folded
      |> Enum.with_index()
      |> Enum.map(fn {%{phase: phase, times: times}, index} ->
        next = folded |> Enum.at(index + 1) |> then(&(&1 && &1.phase))
        stop = %{phase: phase, state: stop_state(phase, next, index == last), times: times}
        put_present(stop, :run_number, run_number(events, phase))
      end)

    met ++ upcoming(folded, met)
  end

  defp stop_state(phase, _next, true = _last?) when phase in @terminal, do: "done"
  defp stop_state(_phase, _next, true = _last?), do: "current"
  defp stop_state(phase, "Rework", false = _last?) when phase != "Rework", do: "failed"
  defp stop_state(_phase, _next, false = _last?), do: "done"

  defp run_number(events, phase) do
    events
    |> Enum.filter(&(&1.type == "run.started" and field(&1, :state) == phase))
    |> Enum.map(&field(&1, :run_number))
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  # The phases still ahead on the normal path to merge, after the ticket's newest phase on it.
  defp upcoming(folded, met) do
    if Enum.any?(met, &(&1.phase in @terminal)) do
      []
    else
      position = folded |> Enum.map(&path_position(&1.phase)) |> Enum.reject(&is_nil/1) |> List.last()
      ahead = if position, do: Enum.drop(@normal_path, position + 1), else: []
      Enum.map(ahead, &%{phase: &1, state: "upcoming", times: 0})
    end
  end

  defp path_position("Rework"), do: 0
  defp path_position(phase), do: Enum.find_index(@normal_path, &(&1 == phase))

  defp loops(folded), do: folded |> Enum.filter(&(&1.phase == "Rework")) |> Enum.map(& &1.times) |> Enum.sum()

  defp elapsed(%Event{at: started}, events, record, now) do
    until = if record.phase in @terminal, do: events |> List.last() |> Map.get(:at) || now, else: now
    max(DateTime.diff(until, started, :millisecond), 0)
  end

  # Attempts.

  defp attempts(nil, _step_id, _events), do: {:error, "no run to show"}

  defp attempts(run_id, step_id, events) do
    tries = for %Event{type: "step.completed", run_id: ^run_id} = step <- events, field(step, :step_id) == step_id, do: step

    case Enum.take(tries, -@tries_max) do
      [] ->
        {:error, "run #{run_id} has no attempts of #{step_id}"}

      tries ->
        tries = Enum.map(tries, &try_of/1)
        failed = for %{outcome: "failed", line: line} <- tries, do: line
        same_line = length(failed) >= 2 and Enum.all?(failed, &(&1 != nil and &1 == hd(failed)))
        title = tries |> List.last() |> Map.fetch!(:title)
        {:ok, %{type: "attempts", run_id: run_id, step_id: step_id, title: title, tries: Enum.map(tries, &Map.delete(&1, :title)), same_line: same_line}}
    end
  end

  defp try_of(step) do
    %{at: iso8601(step.at), outcome: field(step, :outcome), title: field(step, :title)}
    |> put_present(:duration_ms, field(step, :duration_ms))
    |> put_present(:line, output_line(step))
  end

  # The last error-looking line of the try's output, else its last non-empty line.
  defp output_line(%Event{artifacts: artifacts}) do
    Enum.find_value(artifacts, fn id ->
      with {:ok, %{kind: "step_output"}} <- Artifacts.get(id),
           {:ok, path} <- Artifacts.path(id),
           {:ok, text} <- File.read(path) do
        lines = text |> String.replace_invalid() |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        line = lines |> Enum.filter(&Regex.match?(@error_line, &1)) |> List.last() || List.last(lines)
        line && String.slice(line, 0, @line_max)
      else
        _unreadable -> nil
      end
    end)
  end

  # Findings.

  defp findings(events) do
    all = TicketEvents.findings(events)

    items =
      all
      |> Enum.map(fn %{finding: finding, state: state} ->
        %{id: finding.id, title: first_sentence(field(finding, :description)), state: finding_state(state)}
        |> put_present(:severity, field(finding, :severity))
      end)
      |> Enum.sort_by(&(&1.state != "open"))

    case items do
      [] ->
        {:error, "the ticket has no findings"}

      items ->
        open = Enum.count(items, &(&1.state == "open"))
        {:ok, %{type: "findings", items: Enum.take(items, @findings_max), open: open, resolved: length(items) - open}}
    end
  end

  defp finding_state(state) when state in [:open, :reopened], do: "open"
  defp finding_state(_resolved), do: "resolved"

  defp first_sentence(text) do
    sentence = text |> String.trim() |> String.split(~r/(?<=[.!?])\s/, parts: 2) |> hd() |> String.replace(~r/\s+/, " ")
    if String.length(sentence) > @title_max, do: String.slice(sentence, 0, @title_max - 1) <> "…", else: sentence
  end

  # Epic.

  defp epic(%{parent: %{identifier: identifier} = parent} = record) do
    rows =
      for(%{} = stored <- List.wrap(RunStore.list_all_ticket_states()), do: TicketState.normalize(stored))
      |> Enum.filter(&(match?(%{identifier: ^identifier}, &1.parent) or &1.issue_id == record.issue_id))
      |> Enum.uniq_by(& &1.issue_id)
      |> Enum.sort_by(& &1.issue_identifier)
      |> Enum.map(&%{identifier: &1.issue_identifier, title: &1.title, state: &1.phase, current: &1.issue_id == record.issue_id})

    rows = if Enum.any?(rows, & &1.current), do: rows, else: rows ++ [%{identifier: record.issue_identifier, title: record.title, state: record.phase, current: true}]
    {:ok, %{type: "epic", identifier: identifier, title: parent.title || identifier, rows: rows}}
  end

  defp epic(_record), do: {:error, "the ticket has no epic"}

  # Helpers.

  defp field(%Event{payload: payload}, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
