defmodule SymphonyElixir.TicketEvents.Summary do
  @moduledoc """
  Renders the `summary` (`%{title, detail}`) of a ticket event (`SymphonyElixir.TicketEvents.Event`)
  from its type and payload. Symphony writes it, never an agent, and readers show it as is.

  The title says what happened, to what, in at most 120 characters. The detail is one line of at
  most 200 characters, cut with an ellipsis: the payload's free text, which an agent may have
  written (a finding's description, a decision's question and answer, a delegated step's title and
  reason, a note), goes there and never in the title. A QA finding's title is the exception the
  wording asks for: its class, viewport and step, which the catalog bounds, say what QA found where.
  A machine or orchestrated step's title and a skip's reason are Symphony's words (its step list),
  so its line says them: "Build failed after 4 min: back to writing the code", "Tests passed in 2
  min", "Paused on your answer", "Checks skipped: no Elixir changed".

  A run's start and end name its model (`model`) first in their detail, as the run's profile
  resolved it. Numbers come from the payload only (`run_number`, `attempt`, `class_count`, `duration_ms`,
  `tokens`). An event of a type the catalog does not name, such as a legacy record, renders its type
  as the title and no detail; a known type with a malformed payload renders what it can, so a reader
  never crashes on a stored event.
  """

  alias SymphonyElixir.TicketEvents.Event

  @title_max 120
  @detail_max 200
  @ellipsis "…"
  @separator " · "
  @first_words 8

  @type t :: %{title: String.t(), detail: String.t() | nil}

  @kind_names %{"qa" => "QA", "ci_fix" => "CI Fix", "pre_push_review" => "Pre-push Review"}
  # The step modes whose title is Symphony's words (the step list's), so a title may say it.
  @symphony_steps ["machine", "orchestrated"]
  @step_types ["step.started", "step.completed"]

  @doc """
  The summary of `event` (an `Event` or a stored record `Event.normalize/1` reads): its title and its
  detail, or nil when the payload has nothing to add.
  """
  @spec render(Event.t() | map()) :: t()
  def render(%Event{type: type, payload: payload} = event) when is_binary(type) do
    case summary(type, map_or_empty(payload), event) do
      {title, detail} -> finish(title, detail)
      :unknown -> %{title: type, detail: nil}
    end
  end

  def render(%Event{}), do: %{title: "unknown event", detail: nil}
  def render(record) when is_map(record), do: record |> Event.normalize() |> render()

  @doc """
  The line of a run's group in the timeline, from the run's `run.started`, `run.ended` and step
  events in the order they were written: once the run ended, its `run.ended`'s summary; while it
  runs, the step it is on ("Implementation run 2 running: Build"), or the Question its newest step
  paused on ("Implementation run 2 paused on your answer"); between steps, its `run.started`'s. Nil
  for a run with neither a start nor an end.
  """
  @spec run_group([Event.t()]) :: t() | nil
  def run_group(events) when is_list(events) do
    started = Enum.find(events, &(&1.type == "run.started"))
    ended = events |> Enum.filter(&(&1.type == "run.ended")) |> List.last()

    cond do
      ended -> render(ended)
      started -> running(started, events |> Enum.filter(&(&1.type in @step_types)) |> List.last())
      true -> nil
    end
  end

  defp running(started, %Event{payload: %{} = step} = last) do
    run = run_name(map_or_empty(started.payload))

    cond do
      last.type == "step.completed" and text(step, :outcome) == "paused" ->
        finish("#{run} paused on your answer", [text(step, :title)])

      last.type == "step.started" ->
        {title, detail} = step_name(step, "#{run} running: ", "#{run} running a step")
        finish(title, detail)

      true ->
        render(started)
    end
  end

  defp running(started, _no_step), do: render(started)

  defp finish(title, detail), do: %{title: bound(title, @title_max), detail: detail |> join() |> bound(@detail_max)}

  defp summary("phase.entered", payload, _event) do
    title = Enum.join(["Entered", text(payload, :to) || "a phase"] ++ prefixed("from", text(payload, :from)), " ")
    {title, [text(payload, :reason) | prefixed("via", text(payload, :via))]}
  end

  defp summary("hold.set", payload, _event), do: {"Blocked hold set", [text(payload, :reason)]}
  defp summary("hold.cleared", payload, _event), do: {"Blocked hold cleared", prefixed("by", text(payload, :by))}

  defp summary("run.started", payload, _event) do
    where = prefixed("in", text(payload, :state)) ++ prefixed("at", short_sha(text(payload, :head)))
    {"#{run_name(payload)} started", [text(payload, :model) | where]}
  end

  # The run a person started at once (`Orchestrator.start_issue/3`), by the Director with their
  # note (`prefixed("by", ...)` would double the by-line the title already carries).
  defp summary("run.started_by_person", payload, _event) do
    {"#{run_name(payload)} started by #{text(payload, :by) || "you"}", [text(payload, :note)]}
  end

  defp summary("run.ended", payload, _event) do
    title = "#{run_name(payload)} ended" <> suffix(": ", text(payload, :exit))
    transcript = if text(payload, :transcript), do: "transcript"
    usage = [duration(count(payload, :duration_ms)), tokens(field(payload, :tokens)), transcript]
    {title, [text(payload, :model) | usage]}
  end

  defp summary("attempt.pushed", payload, _event) do
    title = Enum.join(["Attempt", count(payload, :attempt), "pushed", short_sha(text(payload, :head))] |> Enum.reject(&is_nil/1), " ")
    {title, [text(payload, :intent) || text(payload, :pr_url)]}
  end

  defp summary("verdict.recorded", payload, _event) do
    title = "#{kind_name(text(payload, :kind)) || "Review"} verdict" <> suffix(": ", text(payload, :outcome))
    {title, [text(payload, :reason) | prefixed("on", short_sha(text(payload, :head)))]}
  end

  defp summary("decision.requested", payload, _event) do
    {"Decision needed from the Director", [Enum.join(present([text(payload, :title), text(payload, :question)]), ": ")]}
  end

  defp summary("decision.recorded", payload, _event) do
    title = if text(payload, :request), do: "The Director decided", else: "The Director ruled"
    {title, [text(payload, :answer)]}
  end

  defp summary("decision.withdrawn", payload, _event), do: {"Decision request withdrawn", [text(payload, :title)]}

  defp summary("person.action", payload, _event) do
    subject = text(payload, :blocker) || text(payload, :label) || text(payload, :to) || text(payload, :move)
    title = person_action(text(payload, :action), subject)
    {title, prefixed("from", text(payload, :from))}
  end

  defp summary("step.started", payload, _event) do
    {title, detail} = step_name(payload, "", "Step")
    {title <> " started", detail ++ [text(payload, :command)]}
  end

  defp summary("step.completed", payload, event) do
    output = if Map.get(event, :artifacts, []) != [], do: "output kept"
    {title, detail} = step_outcome(text(payload, :outcome), payload)
    {title, detail ++ [output]}
  end

  # A stored `step.skipped`, from before it was folded into `step.completed`.
  defp summary("step.skipped", payload, _event), do: {"Step skipped", [text(payload, :title)]}

  defp summary("evidence", payload, _event) do
    title = "Evidence recorded" <> suffix(" with ", plural(length(strings(field(payload, :artifacts))), "file"))
    {title <> suffix(", ", environment(text(payload, :environment))), [text(payload, :caption)]}
  end

  defp summary("finding.recorded", payload, event) do
    found = if is_binary(Map.get(event, :supersedes)), do: "QA reopened #{finding_class(text(payload, :class))}", else: "QA found #{finding_class(text(payload, :class))}"
    title = found <> suffix(" at ", text(payload, :viewport)) <> suffix(": ", text(payload, :step))

    case present([class_count(count(payload, :class_count)), plural(length(strings(field(payload, :evidence))), "screenshot")]) do
      [] -> {title, [text(payload, :description)]}
      counts -> {title, counts}
    end
  end

  defp summary("finding.resolved", payload, _event), do: {"Finding marked resolved", [text(payload, :how) | prefixed("on", short_sha(text(payload, :head)))]}
  defp summary("finding.confirmed", payload, _event), do: {"QA confirmed a finding fixed", prefixed("on", short_sha(text(payload, :head)))}

  defp summary("checklist.answered", payload, _event) do
    {"Checklist item answered", [Enum.join(present([text(payload, :item), text(payload, :answer)]), ": ")]}
  end

  defp summary("drift.detected", payload, _event) do
    {"Moved to #{linear_phase(payload)} in Linear by hand", ["Symphony's record holds #{record_phase(payload)}"]}
  end

  defp summary("ticket.cancelled", payload, _event), do: {"Cancelled" <> suffix(" from ", text(payload, :from)), [text(payload, :note)]}

  defp summary("ticket.moved", payload, _event),
    do: {"Moved to #{text(payload, :to)}" <> suffix(" from ", text(payload, :from)), [text(payload, :note)]}

  defp summary("drift.reverted", payload, _event) do
    {"Moved back to #{record_phase(payload)}: it was moved to #{linear_phase(payload)} in Linear by hand", []}
  end

  defp summary("drift.revert_failed", payload, _event) do
    {"Could not move back to #{record_phase(payload)} from #{linear_phase(payload)}", [text(payload, :error), "tried again at the next read of Linear"]}
  end

  defp summary("pause.set", payload, _event), do: {"Paused" <> suffix(": ", waiting(payload)), []}
  defp summary("pause.reason_added", payload, _event), do: {"Also paused" <> suffix(": ", waiting(payload)), []}
  defp summary("pause.reason_cleared", payload, _event), do: {"Pause reason cleared" <> suffix(": ", waiting(payload)), []}

  defp summary("pause.cleared", payload, _event) do
    {"Moving again", for(%{} = reason <- list(field(payload, :cleared)), do: text(reason, :text))}
  end

  defp summary("question.asked", payload, _event), do: {"Asked you" <> suffix(": ", text(payload, :title)), [text(payload, :question)]}

  defp summary("question.answered", payload, _event) do
    {"You answered" <> suffix(": ", text(payload, :option) || first_words(text(payload, :answer))), [text(payload, :title)]}
  end

  defp summary("question.withdrawn", payload, _event), do: {"Question withdrawn" <> suffix(": ", text(payload, :reason)), [text(payload, :title)]}
  defp summary("question.reopened", payload, _event), do: {"You took back your answer" <> suffix(": ", text(payload, :title)), []}
  defp summary("question.not_asked", payload, _event), do: {"Not asked, the run reached its limit of questions" <> suffix(": ", text(payload, :title)), [text(payload, :question)]}

  defp summary("park.backfilled", payload, _event) do
    added = strings(field(payload, :added))
    question = if "question" in added, do: "asked you whether to run it again"
    reason = if "releasable_reason" in added, do: "paused it until you unblock it"
    push = if "push" in added, do: "pushed its work to #{text(payload, :branch) || "its branch"}"
    {"Park brought up to date at start-up", present([question, reason, push])}
  end

  defp summary("workspace.synced", payload, _event) do
    heads =
      [{"workspace", :workspace_head}, {"PR", :pr_head}, {"recorded", :recorded_head}]
      |> Enum.flat_map(fn {label, key} -> if sha = short_sha(text(payload, key)), do: ["#{label} #{sha}"], else: [] end)
      |> Enum.join(", ")

    {synced_title(text(payload, :action), short_sha(text(payload, :head))), present([heads, text(payload, :reason)])}
  end

  defp summary("workspace.rebuilt", payload, _event) do
    heads =
      [{"PR", :pr_head}, {"branch", :branch_head}, {"recorded", :recorded_head}, {"local", :local_head}]
      |> Enum.flat_map(fn {label, key} -> if sha = short_sha(text(payload, key)), do: ["#{label} #{sha}"], else: [] end)
      |> Enum.join(", ")

    title = rebuilt_title(text(payload, :winner), short_sha(text(payload, :head)))
    orphaned = if sha = short_sha(text(payload, :orphaned_head)), do: "Its local branch head #{sha} is kept under refs/symphony/orphaned"
    {title, present([rebuilt_reason(text(payload, :reason)), heads, orphaned])}
  end

  defp summary("workspace.removed", payload, _event), do: {"Workspace removed", [removed_reason(text(payload, :reason))]}

  defp summary("situation.changed", payload, _event), do: {text(payload, :word) || "Situation changed", [text(payload, :cause)]}
  defp summary("rule.action", payload, _event), do: {"#{text(payload, :rule) || "A rule"} #{rule_did(payload)}", [text(payload, :text)]}

  defp summary("ticket.filed", payload, _event) do
    identifier = text(payload, :identifier)

    title =
      case text(payload, :kind) do
        "follow_up" -> "Follow-up #{identifier || "ticket"} filed"
        _split_off -> "Split off #{identifier || "a ticket"}"
      end

    {title, [text(payload, :title)]}
  end

  defp summary("note", payload, _event), do: {"Note added", [text(payload, :text)]}
  defp summary("note.read", payload, _event), do: {"Note read by a run", [text(payload, :run_id)]}
  defp summary("brief.written", payload, _event), do: {"Brief written", [text(payload, :text)]}
  defp summary("report.published", payload, _event), do: {"Report published", [text(payload, :text)]}
  defp summary(_type, _payload, _event), do: :unknown

  # What a rule did, as its line says it: "reran the failed checks", "filed TP-1501".
  @rule_did %{
    "rerun" => "reran the failed checks",
    "paused" => "paused the ticket",
    "parked" => "parked the ticket",
    "lifted_pause" => "lifted a pause",
    "moved" => "moved the ticket",
    "updated_branch" => "updated the branch",
    "auto_merge" => "changed auto-merge",
    "asked" => "asked you"
  }

  defp rule_did(payload) do
    case text(payload, :action) do
      "filed_ticket" -> "filed " <> (text(payload, :filed) || "a fix ticket")
      action -> Map.get(@rule_did, action, "acted")
    end
  end

  # A step's outcome: "Build failed after 4 min: back to writing the code", "Tests passed in 2 min",
  # "Paused on your answer", "Checks skipped: no Elixir changed". A delegated step's title, reason
  # and the step it returns to are the agent's words, so they go in the detail and the title says
  # "Step".
  defp step_outcome("passed", payload) do
    {name, detail} = step_name(payload, "", "Step")
    {name <> " passed" <> suffix(" in ", duration(count(payload, :duration_ms))), detail}
  end

  defp step_outcome("failed", payload) do
    {name, detail} = step_name(payload, "", "Step")
    back = text(payload, :returns_to_title) || prefixed_text("step", text(payload, :returns_to))
    failed = name <> " failed" <> suffix(" after ", duration(count(payload, :duration_ms)))

    # The step it returns to is the agent's words for a delegated step, so it joins the detail.
    if text(payload, :mode) in @symphony_steps,
      do: {failed <> suffix(": back to ", back), detail},
      else: {failed, detail ++ [prefixed_text("back to", back)]}
  end

  defp step_outcome("paused", payload), do: {"Paused on your answer", [text(payload, :title)]}

  defp step_outcome("skipped", payload) do
    case step_name(payload, "", "Step") do
      {name, []} -> {name <> " skipped" <> suffix(": ", text(payload, :reason)), []}
      {name, detail} -> {name <> " skipped", detail ++ [text(payload, :reason)]}
    end
  end

  # A step completed before its outcome was recorded.
  defp step_outcome(_outcome, payload) do
    {name, detail} = step_name(payload, "", "Step")
    {name <> " completed", detail}
  end

  # The step's title in the title when Symphony's step list wrote it (after `prefix`), else
  # `generic` with the title in the detail.
  defp step_name(payload, prefix, generic) do
    case {text(payload, :mode) in @symphony_steps, text(payload, :title)} do
      {true, title} when is_binary(title) -> {prefix <> title, []}
      {_delegated, title} -> {generic, [title]}
    end
  end

  defp prefixed_text(_word, nil), do: nil
  defp prefixed_text(word, value), do: "#{word} #{value}"

  # A reason's line as the rest of a title: "Waiting for your answer" reads "waiting for your
  # answer"; a line opening on a name ("TP-12 has to finish", "GitHub is down") keeps its capitals.
  defp waiting(payload) do
    case text(payload, :text) do
      nil -> nil
      text -> if text =~ ~r/^\p{Lu}\p{Ll}*(\s|$)/u, do: String.downcase(String.first(text)) <> String.slice(text, 1..-1//1), else: text
    end
  end

  # A free-text answer's opening words, for a title: the rest is cut with an ellipsis.
  defp first_words(nil), do: nil

  defp first_words(text) do
    case String.split(text) do
      words when length(words) > @first_words -> Enum.join(Enum.take(words, @first_words), " ") <> @ellipsis
      words -> Enum.join(words, " ")
    end
  end

  @doc "A run as a person reads it, from its event's payload: `Implementation run 2`, `Run` with no kind."
  @spec run_name(map()) :: String.t()
  def run_name(payload) do
    name = kind_name(text(payload, :run_kind))
    run = if name, do: "#{name} run", else: "Run"
    run <> suffix(" ", count(payload, :run_number))
  end

  defp record_phase(payload), do: text(payload, :record_phase) || "its phase"
  defp linear_phase(payload), do: text(payload, :linear_phase) || "another state"

  defp kind_name(nil), do: nil

  defp kind_name(kind) do
    Map.get_lazy(@kind_names, kind, fn ->
      kind |> String.split("_", trim: true) |> Enum.map_join(" ", &String.capitalize/1)
    end)
  end

  defp person_action("stop", _to), do: "The Director stopped the run"
  defp person_action("move", to), do: "The Director moved the ticket" <> suffix(" to ", to)
  defp person_action("force", _to), do: "The Director forced a dispatch"
  defp person_action("unblock", _to), do: "The Director unblocked the ticket"
  defp person_action("restart", _to), do: "The Director restarted the ticket"
  defp person_action("add_blocker", blocker), do: "The Director added " <> (blocker || "a ticket") <> " as a blocker"
  defp person_action("set_priority", to), do: "The Director set the priority to " <> (to || "another priority")
  defp person_action("add_label", label), do: "The Director added " <> label_name(label)
  defp person_action("remove_label", label), do: "The Director removed " <> label_name(label)
  defp person_action("remove_blocker", blocker), do: "The Director removed " <> (blocker || "a ticket") <> " as a blocker"
  defp person_action(action, _to), do: "The Director acted" <> suffix(": ", action)

  defp label_name(nil), do: "a label"
  defp label_name(label), do: "the " <> label <> " label"

  # A finding QA has not classified yet (until the findings model, `unclassified`) is a defect.
  defp finding_class(class) when class in [nil, "unclassified"], do: "a defect"
  defp finding_class(class), do: class

  defp class_count(nil), do: nil
  defp class_count(0), do: nil
  defp class_count(count), do: "#{ordinal(count)} finding of this class on this ticket"

  defp ordinal(n) when rem(n, 100) in 11..13, do: "#{n}th"
  defp ordinal(n) when rem(n, 10) == 1, do: "#{n}st"
  defp ordinal(n) when rem(n, 10) == 2, do: "#{n}nd"
  defp ordinal(n) when rem(n, 10) == 3, do: "#{n}rd"
  defp ordinal(n), do: "#{n}th"

  defp plural(0, _noun), do: nil
  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"

  defp duration(nil), do: nil
  defp duration(ms) when ms < 60_000, do: "#{div(ms, 1_000)} s"

  defp duration(ms) do
    case round(ms / 60_000) do
      minutes when minutes < 60 -> "#{minutes} min"
      minutes -> "#{div(minutes, 60)} h" <> suffix(" ", if(rem(minutes, 60) > 0, do: "#{rem(minutes, 60)} min"))
    end
  end

  defp tokens(tokens) when is_integer(tokens) and tokens >= 0, do: "#{compact(tokens)} tokens"
  defp tokens(%{} = tokens), do: tokens(Map.get(tokens, :total_tokens, Map.get(tokens, "total_tokens")))
  defp tokens(_tokens), do: nil

  defp compact(n) when n >= 1_000_000, do: decimal(n / 1_000_000) <> "M"
  defp compact(n) when n >= 1_000, do: decimal(n / 1_000) <> "K"
  defp compact(n), do: Integer.to_string(n)

  defp decimal(value), do: value |> :erlang.float_to_binary(decimals: 1) |> String.trim_trailing(".0")

  defp synced_title("reset", head), do: "Workspace reset to the PR head" <> suffix(" ", head)
  defp synced_title("pushed", head), do: "Workspace's unpushed head" <> suffix(" ", head) <> " pushed to the PR"
  defp synced_title("reset_and_pushed", head), do: "Workspace reset to a run's unpushed head" <> suffix(" ", head) <> " and pushed"
  defp synced_title("blocked", _head), do: "Workspace not synced: it holds local work"
  defp synced_title("failed", _head), do: "Workspace could not be synced"
  defp synced_title(_none, head), do: "Workspace already on the PR head" <> suffix(" ", head)

  defp rebuilt_title("pull_request", head), do: "Workspace rebuilt on the PR head" <> suffix(" ", head)
  defp rebuilt_title("branch", head), do: "Workspace rebuilt on the branch head" <> suffix(" ", head)
  defp rebuilt_title("recorded", head), do: "Workspace rebuilt on a run's unpushed head" <> suffix(" ", head)
  defp rebuilt_title("local", head), do: "Workspace rebuilt on its local branch head" <> suffix(" ", head)
  defp rebuilt_title(_main, _head), do: "Workspace rebuilt from main: the ticket has no branch yet"

  defp rebuilt_reason("reclaim"), do: "Its old workspace was reclaimed"
  defp rebuilt_reason("stop"), do: "Its workspace was removed when its run was stopped"
  defp rebuilt_reason("terminal"), do: "Its workspace was removed when it reached a terminal state"
  defp rebuilt_reason("cleanup"), do: "Symphony removed its workspace"
  defp rebuilt_reason("host_change"), do: "Its last run was on another host"
  defp rebuilt_reason(_missing), do: "Its workspace folder was missing"

  defp removed_reason("age_gc"), do: "The age GC reclaimed it"
  defp removed_reason("stop"), do: "Its run was stopped"
  defp removed_reason("terminal"), do: "The ticket reached a terminal state"
  defp removed_reason(_cleanup), do: "Symphony cleaned it up"

  defp short_sha(nil), do: nil
  defp short_sha(sha), do: String.slice(sha, 0, 7)

  defp prefixed(_word, nil), do: []
  defp prefixed(word, value), do: ["#{word} #{value}"]

  defp environment("live"), do: "on the live server"
  defp environment("fixture"), do: "on the fixtures"
  defp environment(_environment), do: nil

  defp suffix(_separator, nil), do: ""
  defp suffix(separator, value), do: "#{separator}#{value}"

  defp present(values), do: Enum.reject(values, &(is_nil(&1) or &1 == ""))

  defp join(parts) do
    case present(parts) do
      [] -> nil
      parts -> Enum.join(parts, @separator)
    end
  end

  # One line, at most `max` characters: whitespace runs collapse to one space, and a longer line is
  # cut so it ends with the ellipsis.
  defp bound(nil, _max), do: nil

  defp bound(value, max) do
    line = value |> String.split() |> Enum.join(" ")

    if String.length(line) > max do
      String.trim_trailing(String.slice(line, 0, max - 1)) <> @ellipsis
    else
      line
    end
  end

  # A payload validated on write has atom keys; a legacy record may have kept them as strings.
  defp field(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp text(payload, key) do
    case field(payload, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: String.trim(value)
      _value -> nil
    end
  end

  defp count(payload, key) do
    case field(payload, key) do
      value when is_integer(value) and value >= 0 -> value
      _value -> nil
    end
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp strings(_value), do: []

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_value), do: %{}
end
