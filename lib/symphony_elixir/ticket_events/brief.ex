defmodule SymphonyElixir.TicketEvents.Brief do
  @moduledoc """
  The summary of a ticket's history that every agent prompt carries (`SymphonyElixir.PromptBuilder`,
  behind `ledger.prompt_brief_enabled`): the ticket's record and every event of its stream
  (`SymphonyElixir.TicketEvents`), as text.

  Its sections, in order:

    * **Phase and holds**, from the ticket's record.
    * **Decisions**: every request (a `decision.requested`, or a Question's `question.asked`) with
      its answer or withdrawal, every open request, and every ruling a person recorded without a
      request.
    * **Open findings**: every finding no unsuperseded resolution names, grouped by class with a
      count, each with its viewport, its commit (the event's, else its run's), when it was last
      seen (its event, or a later event that reopened it) and its whole description.
    * **Notes**: every note, in full, with who wrote it; a person's is the Director's.
    * **Runs**: one line per run (kind, number, result or state, commit, when), with the latest
      run's events in full under it. An earlier run's steps are summed up in its line.
    * **Other events**: every event outside a run, one line each from its summary, newest first.
      Findings, notes and the decision events Decisions shows are not repeated there; a withdrawal
      or a later answer naming no request it shows is.

  Nothing is left out to fit a size: the size the prompt builder checks
  (`ledger.prompt_brief_max_tokens`) is a guard against something absurd, not a budget. The text
  depends only on the record and the events, never on the clock, so the same ledger renders the
  same bytes.
  """

  alias SymphonyElixir.{RunStore, TicketState}
  alias SymphonyElixir.TicketEvents.{Event, Summary}

  @type t :: %{
          text: String.t(),
          tokens: non_neg_integer(),
          decisions: non_neg_integer(),
          open_findings: non_neg_integer(),
          notes: non_neg_integer(),
          runs: non_neg_integer()
        }

  # The types a section renders, which Other events doesn't repeat. A decision event is left out of
  # it only when Decisions renders it: a withdrawal or a second answer naming no request it shows is
  # one of the other events.
  @section_types ["note", "finding.recorded", "finding.resolved"]
  @run_types ["run.started", "run.ended"]
  # The payload fields that hold an event's whole free text, which a summary's detail cuts.
  @full_fields %{
    "note" => [:text],
    "finding.recorded" => [:severity, :description],
    "finding.resolved" => [:how],
    "checklist.answered" => [:item, :answer],
    "evidence" => [:caption],
    "decision.requested" => [:title, :question],
    "decision.recorded" => [:answer],
    "question.asked" => [:title, :question],
    "question.answered" => [:answer],
    "step.started" => [:title],
    "step.completed" => [:title],
    "step.skipped" => [:title]
  }
  @kind_names %{"qa" => "QA", "ci_fix" => "CI Fix", "pre_push_review" => "Pre-push Review"}

  @doc """
  The summary of `repo_key`'s ticket `issue_id`: its record and every event it holds, read from
  `SymphonyElixir.RunStore` (never one capped page of `SymphonyElixir.TicketEvents.query/3`), built
  by `build/2`.
  """
  @spec render(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def render(repo_key, issue_id) do
    with state when not is_tuple(state) <- RunStore.get_ticket_state(repo_key, issue_id),
         events when is_list(events) <- RunStore.list_ticket_events(repo_key, issue_id, []) do
      {:ok, build(state, events)}
    end
  end

  @doc """
  The summary of a ticket from its record (nil when it has none) and its events, in any order: its
  text, the text's size in tokens (bytes / 4), and how many decisions, open findings, notes and runs
  it holds.
  """
  @spec build(map() | nil, [Event.t() | map()]) :: t()
  def build(ticket_state, events) do
    events = events |> Enum.map(&Event.normalize/1) |> Enum.sort_by(&{sort_time(&1.at), &1.seq || 0})
    state = TicketState.normalize(ticket_state)
    runs = runs(events)
    decisions = decisions(events)
    findings = open_findings(events, runs)
    notes = Enum.filter(events, &(&1.type == "note"))

    text =
      [
        phase_section(state),
        decisions_section(decisions),
        findings_section(findings),
        notes_section(notes),
        runs_section(runs),
        other_section(events, decisions)
      ]
      |> Enum.join("\n\n")

    %{
      text: text,
      tokens: div(byte_size(text), 4),
      decisions: length(decisions),
      open_findings: length(findings),
      notes: length(notes),
      runs: length(runs)
    }
  end

  # Phase and holds

  defp phase_section(state), do: Enum.join(["Phase and holds:", "- Phase: #{state.phase || "unknown"}" | hold_lines(state.holds)], "\n")

  defp hold_lines([]), do: ["- Holds: none"]

  defp hold_lines(holds) do
    Enum.map(holds, fn hold ->
      reason = hold.reason || "no reason recorded"
      clearing = hold.clearing_condition || "no clearing condition recorded"
      "- Hold: #{hold.kind} (#{reason}; clears when #{clearing})" <> suffix(", since ", time(hold.set_at))
    end)
  end

  # Decisions: each request with the event that ended it (nil while open), and each ruling, in the
  # order they were made.

  # A Question's request is its `question.asked`, ended by the Question's own answer or withdrawal
  # (naming its `question_id`) or by a `decision.recorded` naming the event, whichever came first.
  defp decisions(events) do
    requests = events |> Enum.filter(&(&1.type in ["decision.requested", "question.asked"])) |> MapSet.new(& &1.id)

    questions =
      for %Event{type: "question.asked", id: id} = event <- events, text(event, :question_id), into: %{} do
        {text(event, :question_id), id}
      end

    ends =
      events
      |> Enum.flat_map(&ended_request(&1, requests, questions))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.flat_map(events, fn
      %Event{type: type, id: id} = event when type in ["decision.requested", "question.asked"] -> [{:request, event, ends |> Map.get(id, []) |> List.first()}]
      %Event{type: "decision.recorded"} = event -> if MapSet.member?(requests, text(event, :request)), do: [], else: [{:ruling, event}]
      _event -> []
    end)
  end

  # The request an event ends, by the request event's id.
  defp ended_request(%Event{type: type} = event, requests, _questions) when type in ["decision.recorded", "decision.withdrawn"] do
    if MapSet.member?(requests, text(event, :request)), do: [{text(event, :request), event}], else: []
  end

  defp ended_request(%Event{type: type} = event, _requests, questions) when type in ["question.answered", "question.withdrawn"] do
    case Map.get(questions, text(event, :question_id)) do
      nil -> []
      request -> [{request, event}]
    end
  end

  defp ended_request(_event, _requests, _questions), do: []

  defp decisions_section(decisions), do: section("Decisions", decisions, &decision_lines/1)

  defp decision_lines({:request, event, ended}) do
    asked = "- Asked #{time(event.at)} by #{actor(event.actor)}: " <> Enum.join(present([text(event, :title), text(event, :question)]), ": ")
    why = if text(event, :why), do: ["  Why: " <> text(event, :why)], else: []
    options = Enum.map(options(event), &("  Option: " <> &1))
    [asked | why ++ options ++ [decision_end(ended)]]
  end

  defp decision_lines({:ruling, event}) do
    about = Enum.join(present([text(event, :title), text(event, :question)]), ": ")
    ["- Ruled #{time(event.at)} by #{actor(event.actor)}" <> suffix(" on ", blank_to_nil(about)) <> ": " <> (text(event, :answer) || "")]
  end

  defp decision_end(nil), do: "  Open: it waits on the Director's answer."
  defp decision_end(%Event{type: type} = event) when type in ["decision.withdrawn", "question.withdrawn"], do: "  Withdrawn #{time(event.at)} by #{actor(event.actor)}."
  defp decision_end(event), do: "  Answered #{time(event.at)} by #{actor(event.actor)}: " <> (text(event, :answer) || "")

  defp options(event) do
    event.payload
    |> field(:options)
    |> List.wrap()
    |> Enum.flat_map(fn
      option when is_binary(option) -> [option]
      %{} = option -> [Enum.join(present([text_of(option, :label), text_of(option, :effect)]), ": ")]
      _option -> []
    end)
    |> present()
  end

  # Open findings

  defp open_findings(events, runs) do
    superseded = events |> Enum.map(& &1.supersedes) |> MapSet.new()
    resolutions = Enum.filter(events, &(&1.type == "finding.resolved"))
    resolved = for event <- resolutions, not MapSet.member?(superseded, event.id), into: MapSet.new(), do: text(event, :finding_id)
    commits = Map.new(runs, &{&1.id, &1.commit})

    events
    |> Enum.filter(&(&1.type == "finding.recorded" and not MapSet.member?(resolved, &1.id)))
    |> Enum.map(fn finding ->
      reopened_by = for event <- resolutions, text(event, :finding_id) == finding.id, into: MapSet.new(), do: event.id
      seen = events |> Enum.filter(&MapSet.member?(reopened_by, &1.supersedes)) |> Enum.map(& &1.at)
      %{event: finding, commit: finding.head_sha || Map.get(commits, finding.run_id), last_seen: List.last([finding.at | seen])}
    end)
  end

  defp findings_section(findings) do
    groups =
      findings
      |> Enum.group_by(&finding_class/1)
      |> Enum.sort_by(fn {class, group} -> {-length(group), class} end)

    case groups do
      [] -> "Open findings (0):\n- none"
      groups -> Enum.join(["Open findings (#{length(findings)}):" | Enum.flat_map(groups, &finding_group/1)], "\n")
    end
  end

  defp finding_group({class, findings}), do: ["- #{class} (#{length(findings)}):" | Enum.map(findings, &finding_line/1)]

  defp finding_line(%{event: event, commit: commit, last_seen: last_seen}) do
    facts =
      present([
        text(event, :severity),
        prefixed("at ", text(event, :viewport)),
        prefixed("step ", text(event, :step)),
        prefixed("commit ", short_sha(commit)),
        prefixed("last seen ", time(last_seen))
      ])

    indent("  - " <> Enum.join(facts, ", ") <> ": " <> (text(event, :description) || "") <> files(evidence(event)), "    ")
  end

  defp finding_class(%{event: event}) do
    case text(event, :class) do
      nil -> "unclassified"
      class -> class
    end
  end

  defp evidence(event) do
    case field(event.payload, :evidence) do
      value when is_binary(value) -> [value]
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _value -> []
    end
  end

  # Notes

  defp notes_section(notes) do
    section("Notes", notes, fn note -> [indent("- #{time(note.at)}, #{actor(note.actor)}: " <> (text(note, :text) || ""), "  ")] end)
  end

  # Runs: the events that carry a run id, grouped by it in the order the runs began.

  defp runs(events) do
    in_runs = Enum.filter(events, & &1.run_id)
    by_id = Enum.group_by(in_runs, & &1.run_id)
    in_runs |> Enum.map(& &1.run_id) |> Enum.uniq() |> Enum.map(&run(&1, Map.fetch!(by_id, &1)))
  end

  defp run(id, [first | _rest] = events) do
    started = Enum.find(events, &(&1.type == "run.started"))
    ended = events |> Enum.filter(&(&1.type == "run.ended")) |> List.last()
    payloads = Enum.map(present([started, ended]), & &1.payload)

    %{
      id: id,
      kind: Enum.find_value(payloads, &text_of(&1, :run_kind)) || agent_kind(events),
      number: Enum.find_value(payloads, &count(&1, :run_number)),
      state: started && text(started, :state),
      exit: ended && text(ended, :exit),
      commit: (started && text(started, :head)) || (ended && text(ended, :head)),
      at: first.at,
      events: Enum.reject(events, &(&1.type in @run_types))
    }
  end

  defp agent_kind(events), do: Enum.find_value(events, &Map.get(&1.actor, :run_kind))

  defp runs_section([]), do: "Runs (0):\n- none"

  defp runs_section(runs) do
    {earlier, [latest]} = Enum.split(runs, -1)
    lines = Enum.map(earlier, &run_line(&1, false)) ++ [run_line(latest, true) | latest_events(latest.events)]
    Enum.join(["Runs (#{length(runs)}):" | lines], "\n")
  end

  defp run_line(run, latest?) do
    name = (kind_name(run.kind) || "Agent") <> " run" <> suffix(" ", run.number && Integer.to_string(run.number))
    result = run_result(run, latest?)
    facts = present([result, prefixed("at ", short_sha(run.commit)), prefixed("started ", time(run.at))])
    "- " <> name <> if(latest?, do: " (latest)", else: "") <> ": " <> Enum.join(facts, ", ")
  end

  defp run_result(%{exit: exit}, _latest?) when is_binary(exit), do: "ended: #{exit}"
  defp run_result(%{state: state}, true), do: "running" <> suffix(" in ", state)
  defp run_result(%{state: state}, false), do: Enum.join(present([prefixed("in ", state), "no end recorded"]), ", ")

  defp latest_events([]), do: ["  - no steps recorded"]
  defp latest_events(events), do: Enum.map(events, &indent("  - #{time(&1.at)} " <> full_line(&1), "    "))

  # Other events

  defp other_section(events, decisions) do
    shown = for decision <- decisions, %Event{id: id} <- Tuple.to_list(decision), into: MapSet.new(), do: id
    other = events |> Enum.filter(&(is_nil(&1.run_id) and &1.type not in @section_types and not MapSet.member?(shown, &1.id))) |> Enum.reverse()
    section("Other events, newest first", other, fn event -> ["- #{time(event.at)} " <> summary_line(event)] end)
  end

  # An event's title with its whole free text: what the latest run's events show.
  defp full_line(event), do: summary(event).title <> suffix(": ", blank_to_nil(full_detail(event))) <> files(event.artifacts)

  defp full_detail(event) do
    case Map.fetch(@full_fields, event.type) do
      {:ok, fields} -> fields |> Enum.map(&text(event, &1)) |> present() |> Enum.join(": ")
      :error -> summary(event).detail
    end
  end

  defp summary_line(event) do
    %{title: title, detail: detail} = summary(event)
    title <> suffix(": ", detail) <> files(event.artifacts)
  end

  defp summary(%Event{summary: %{title: _title} = summary}), do: summary
  defp summary(event), do: Summary.render(event)

  # Text helpers

  defp section(name, [], _lines), do: "#{name} (0):\n- none"
  defp section(name, items, lines), do: Enum.join(["#{name} (#{length(items)}):" | Enum.flat_map(items, lines)], "\n")

  # The control API's one shared token names its person "the Director" (a note, a decision from the app).
  defp actor(%{kind: :person, name: "the Director"}), do: "the Director"
  defp actor(%{kind: :person, name: name}), do: "the Director (#{name})"
  defp actor(%{kind: :agent, run_kind: kind}), do: "an agent (#{kind_name(kind)} run)"
  defp actor(_actor), do: "Symphony"

  defp kind_name(nil), do: nil

  defp kind_name(kind) do
    Map.get_lazy(@kind_names, kind, fn -> kind |> String.split("_", trim: true) |> Enum.map_join(" ", &String.capitalize/1) end)
  end

  defp files([]), do: ""
  defp files(ids), do: " (files: #{Enum.join(ids, ", ")})"

  # A multi-line text keeps its lines, each continuation indented under its bullet.
  defp indent(line, prefix), do: line |> String.split(~r/\r?\n/) |> Enum.join("\n" <> prefix)

  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp time(_at), do: nil

  defp sort_time(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp sort_time(_at), do: 0

  defp short_sha(nil), do: nil
  defp short_sha(sha), do: String.slice(sha, 0, 7)

  defp prefixed(_word, nil), do: nil
  defp prefixed(word, value), do: word <> value

  defp suffix(_separator, nil), do: ""
  defp suffix(separator, value), do: separator <> value

  defp present(values), do: Enum.reject(values, &(is_nil(&1) or &1 == ""))

  defp text(%Event{payload: payload}, key), do: text_of(payload, key)

  # A payload validated on write has atom keys; a legacy record or an option may have strings.
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp text_of(map, key) do
    case field(map, key) do
      value when is_binary(value) -> blank_to_nil(value)
      _value -> nil
    end
  end

  defp count(map, key) do
    case field(map, key) do
      value when is_integer(value) and value >= 0 -> value
      _value -> nil
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
