defmodule SymphonyElixir.TicketEvents.Summary do
  @moduledoc """
  Renders the `summary` (`%{title, detail}`) of a ticket event (`SymphonyElixir.TicketEvents.Event`)
  from its type and payload. Symphony writes it, never an agent, and readers show it as is.

  The title says what happened, to what, in at most 120 characters. The detail is one line of at
  most 200 characters, cut with an ellipsis: the payload's free text, which an agent may have
  written (a finding's description, a decision's question and answer, a step's title, a note), goes
  there and never in the title. A QA finding's title is the exception the wording asks for: its
  class, viewport and step, which the catalog bounds, say what QA found where.

  Numbers come from the payload only (`run_number`, `attempt`, `class_count`, `duration_ms`,
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
  @step_verbs %{"step.started" => "started", "step.completed" => "completed", "step.skipped" => "skipped"}

  @doc """
  The summary of `event` (an `Event` or a stored record `Event.normalize/1` reads): its title and its
  detail, or nil when the payload has nothing to add.
  """
  @spec render(Event.t() | map()) :: t()
  def render(%Event{type: type, payload: payload} = event) when is_binary(type) do
    case summary(type, map_or_empty(payload), event) do
      {title, detail} -> %{title: bound(title, @title_max), detail: detail |> join() |> bound(@detail_max)}
      :unknown -> %{title: type, detail: nil}
    end
  end

  def render(%Event{}), do: %{title: "unknown event", detail: nil}
  def render(record) when is_map(record), do: record |> Event.normalize() |> render()

  defp summary("phase.entered", payload, _event) do
    title = Enum.join(["Entered", text(payload, :to) || "a phase"] ++ prefixed("from", text(payload, :from)), " ")
    {title, [text(payload, :reason) | prefixed("via", text(payload, :via))]}
  end

  defp summary("hold.set", payload, _event), do: {"Blocked hold set", [text(payload, :reason)]}
  defp summary("hold.cleared", payload, _event), do: {"Blocked hold cleared", prefixed("by", text(payload, :by))}

  defp summary("run.started", payload, _event) do
    {"#{run_name(payload)} started", prefixed("in", text(payload, :state)) ++ prefixed("at", short_sha(text(payload, :head)))}
  end

  defp summary("run.ended", payload, _event) do
    title = "#{run_name(payload)} ended" <> suffix(": ", text(payload, :exit))
    transcript = if text(payload, :transcript), do: "transcript"
    {title, [duration(count(payload, :duration_ms)), tokens(field(payload, :tokens)), transcript]}
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
    title = person_action(text(payload, :action), text(payload, :to) || text(payload, :move))
    {title, prefixed("from", text(payload, :from))}
  end

  defp summary(type, payload, _event) when is_map_key(@step_verbs, type), do: {"Step #{@step_verbs[type]}", [text(payload, :title)]}

  defp summary("evidence", payload, _event) do
    {"Evidence recorded" <> suffix(" with ", plural(length(strings(field(payload, :artifacts))), "file")), [text(payload, :caption)]}
  end

  defp summary("finding.recorded", payload, _event) do
    title = "QA found #{finding_class(text(payload, :class))}" <> suffix(" at ", text(payload, :viewport)) <> suffix(": ", text(payload, :step))

    case present([class_count(count(payload, :class_count)), plural(length(strings(field(payload, :evidence))), "screenshot")]) do
      [] -> {title, [text(payload, :description)]}
      counts -> {title, counts}
    end
  end

  defp summary("finding.resolved", payload, _event), do: {"Finding marked resolved", [text(payload, :how)]}

  defp summary("checklist.answered", payload, _event) do
    {"Checklist item answered", [Enum.join(present([text(payload, :item), text(payload, :answer)]), ": ")]}
  end

  defp summary("drift.detected", payload, _event) do
    {"Moved to #{linear_phase(payload)} in Linear by hand", ["Symphony's record holds #{record_phase(payload)}"]}
  end

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

  defp summary("note", payload, _event), do: {"Note added", [text(payload, :text)]}
  defp summary(_type, _payload, _event), do: :unknown

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

  defp run_name(payload) do
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
  defp person_action(action, _to), do: "The Director acted" <> suffix(": ", action)

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

  defp short_sha(nil), do: nil
  defp short_sha(sha), do: String.slice(sha, 0, 7)

  defp prefixed(_word, nil), do: []
  defp prefixed(word, value), do: ["#{word} #{value}"]

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
