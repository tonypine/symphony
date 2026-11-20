defmodule SymphonyElixir.TicketProjection do
  @moduledoc """
  What Linear shows of a groomed ticket: its description is written by Symphony, from the ticket's
  record, and no run reads it.

  The text (`render/1`) is `## Ask` (every `ask.recorded`, word for word, oldest first), `## Plan`
  (the current plan's `summary`, written for a person) and `## Checks` (one line per check of the
  plan: where it stands, its id and its statement). `put/2` sets it in a description in place of
  everything but Symphony's own blocks (the summary block, `SymphonyElixir.IssueSummary`, and the
  Decisions section, `SymphonyElixir.Decisions`), which stay as they are, below it. So what a
  person typed into the description in Linear is overwritten at the next projection: on a groomed
  ticket the ask changes through a message, never through the description.

  The one writer is `SymphonyElixir.Pauses.Projector`, in the pass that also writes the Decisions
  section: it writes when the text changed. `changed/2` runs that pass, and is called each time a
  plan version, an ask, a proof or a waiver is recorded (`SymphonyElixir.TicketPlan`,
  `SymphonyElixir.TicketChecks`). A ticket with no plan has no projection, and its description is
  left to the person.
  """

  alias SymphonyElixir.{Decisions, IssueSummary, TicketChecks, TicketPlan}
  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.TicketEvents.Event

  @types ["ask.recorded", "plan.written", "check.proved", "check.waived"]

  @doc "The types of the events the projection is rendered from."
  @spec event_types() :: [String.t()]
  def event_types, do: @types

  @doc "The description's text for the ticket whose `events` these are (oldest first); nil for a ticket with no plan."
  @spec render([Event.t()]) :: String.t() | nil
  def render(events) when is_list(events) do
    case TicketPlan.current(events) do
      nil -> nil
      plan -> "## Ask\n\n#{asks(events)}\n\n## Plan\n\n#{one_line(plan.summary)}\n\n## Checks\n\n#{checks(events)}"
    end
  end

  defp asks(events) do
    case for(%{text: text} <- TicketPlan.ask(events), is_binary(text), do: String.trim(text)) do
      [] -> "No ask was recorded."
      texts -> Enum.join(texts, "\n\n")
    end
  end

  defp checks(events), do: Enum.map_join(TicketChecks.list(events), "\n", &"- [#{&1.state}] #{&1.id}: #{one_line(&1.statement)}")

  defp one_line(text), do: text |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()

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
