defmodule SymphonyElixir.TicketProjection do
  @moduledoc """
  What Linear shows of a groomed ticket: its description is written by Symphony, from the ticket's
  record, and no run reads it.

  The text (`render/1`) is `## Ask` (every `ask.recorded`, word for word, oldest first), `## Plan`
  (the current plan's `summary`, written for a person) and `## Checks` (one line per check of the
  plan: where it stands, its id and its statement). `put/2` sets it in a description in place of
  everything but Symphony's own blocks (the summary block, `SymphonyElixir.IssueSummary`, and the
  Decisions section, `SymphonyElixir.Decisions`), which stay as they are, below it. A ticket that
  holds no ask has no projection: the text is never written in place of words Symphony does not
  hold.

  Before the first projection of a ticket the projector reads what the description holds now: words
  a person typed there since the ask was recorded (`unrecorded_ask/2`) are recorded as a further
  ask, and only then is the description written. After that first projection an edit a person
  makes in Linear is never dropped in silence: a text that is none of Symphony's own (`edited/2`)
  goes to the ticket's Conductor as a message (`SymphonyElixir.Conductor.DescriptionEdit`), which
  answers it on the ticket, and the next projection writes the description again.

  The one writer is `SymphonyElixir.Pauses.Projector`, in the pass that also writes the Decisions
  section: it writes when the text changed. `changed/2` runs that pass, and is called each time a
  plan version, an ask, a proof or a waiver is recorded (`SymphonyElixir.TicketPlan`,
  `SymphonyElixir.TicketChecks`). A ticket with no plan has no projection, and its description is
  left to the person.
  """

  alias SymphonyElixir.{Decisions, IssueSummary, TicketChecks, TicketPlan, Walkthrough}
  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.TicketEvents.Event

  @types ["ask.recorded", "plan.written", "check.proved", "check.waived"]

  @doc "The types of the events the projection is rendered from."
  @spec event_types() :: [String.t()]
  def event_types, do: @types

  @doc """
  The description's text for the ticket whose `events` these are (oldest first); nil for a ticket
  with no plan, and for one that holds no ask: the text stands in place of what the person wrote,
  so it is never written without it.
  """
  @spec render([Event.t()]) :: String.t() | nil
  def render(events) when is_list(events) do
    case {TicketPlan.current(events), asks(events)} do
      {nil, _asks} -> nil
      {_plan, []} -> nil
      {plan, asks} -> "## Ask\n\n#{Enum.join(asks, "\n\n")}\n\n## Plan\n\n#{one_line(plan.summary)}\n\n## Checks\n\n#{checks(events)}"
    end
  end

  defp asks(events), do: for(%{text: text} <- TicketPlan.ask(events), is_binary(text), do: String.trim(text))

  @doc """
  What a person wrote in the `description` Linear holds that the ticket's `events` do not: its
  text without Symphony's own blocks (`person_text/1`), when it is none of the asks recorded. Nil
  when the record holds it already, or the description holds no words of a person. The projector
  records it as a further ask before it writes the ticket's first projection, which would
  otherwise destroy what a person typed while Grooming ran.
  """
  @spec unrecorded_ask(String.t() | nil, [Event.t()]) :: String.t() | nil
  def unrecorded_ask(description, events) when is_list(events) do
    text = person_text(description)
    if text == "" or text in asks(events), do: nil, else: text
  end

  @doc """
  What a person wrote in a groomed ticket's `description` that Symphony did not write: its text
  without Symphony's own blocks (`person_text/1`), when it is none of the projections Symphony
  rendered from the ticket's `events` as they grew (`render/1` of each of their prefixes, so a
  description a newer plan has not reached yet is still Symphony's), none of the asks recorded,
  and no description edit already sent as a message. Nil otherwise, and for a ticket with no
  projection. The text is compared whole, never diffed.
  """
  @spec edited(String.t() | nil, [Event.t()]) :: String.t() | nil
  def edited(description, events) when is_list(events) do
    text = person_text(description)
    known? = text == "" or render(events) == nil or text in asks(events) or text in edits(events)
    if known? or MapSet.member?(rendered(events), text), do: nil, else: text
  end

  # Every projection the ticket's events rendered as they grew, trimmed.
  defp rendered(events) do
    projected = Enum.filter(events, &(&1.type in @types))
    for n <- 1..length(projected)//1, text = render(Enum.take(projected, n)), is_binary(text), into: MapSet.new(), do: String.trim(text)
  end

  # The description edits already given to the Conductor as messages.
  defp edits(events) do
    for %Event{type: "message.sent", payload: payload} <- events, payload_source(payload) == "linear_description", do: String.trim(payload_text(payload))
  end

  defp payload_source(payload), do: Map.get(payload, :source, Map.get(payload, "source"))
  defp payload_text(payload), do: to_string(Map.get(payload, :text, Map.get(payload, "text")))

  defp checks(events), do: Enum.map_join(TicketChecks.list(events), "\n", &"- [#{&1.state}] #{&1.id}: #{one_line(&1.statement)}")

  defp one_line(text), do: text |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()

  @doc """
  What a person wrote in `description`: its text without Symphony's own blocks (the summary block,
  the Decisions section and the walkthrough's `Proved by:` blocks), trimmed. Empty for none.
  """
  @spec person_text(String.t() | nil) :: String.t()
  def person_text(description) when is_binary(description) do
    description |> IssueSummary.strip() |> Decisions.strip() |> Walkthrough.put_proofs([]) |> String.trim()
  end

  def person_text(_description), do: ""

  @doc """
  `description` with `text` in place of everything but Symphony's own blocks, which follow it in
  the order they stood in.
  """
  @spec put(String.t() | nil, String.t()) :: String.t()
  def put(description, text) when is_binary(text) do
    description = description || ""
    summary = block(description, IssueSummary.start_marker(), IssueSummary.end_marker())
    decisions = block(description, Decisions.start_marker(), Decisions.end_marker())
    blocks = Enum.reject([summary, decisions], &is_nil/1)
    Enum.join([text | blocks |> Enum.sort() |> Enum.map(&elem(&1, 1))], "\n\n")
  end

  # A block with where it starts, or nil when the description holds none (or one never closed).
  defp block(description, open, close) do
    with [before, rest] <- String.split(description, open, parts: 2),
         [inner, _after] <- String.split(rest, close, parts: 2) do
      {String.length(before), open <> inner <> close}
    else
      _none -> nil
    end
  end

  @doc """
  Projects the ticket `issue_id` of `repo_key` again, now that something the projection shows
  changed. Best effort: a write Linear refuses is left pending by the projector, which the
  reconciler applies again. Always `:ok`.
  """
  @spec changed(String.t() | nil, String.t()) :: :ok
  def changed(repo_key, issue_id) when is_binary(repo_key) and is_binary(issue_id) do
    _ = Projector.project_now({:ticket, repo_key, issue_id})
    :ok
  end

  def changed(_repo_key, _issue_id), do: :ok
end
