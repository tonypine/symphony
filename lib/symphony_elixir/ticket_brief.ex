defmodule SymphonyElixir.TicketBrief do
  @moduledoc """
  A ticket's brief (fact 25 of `docs/design/director-ticket-page.md`): what the ticket does and why,
  in a person's words, and its walkthrough as the steps a person takes.

  An implementation, rework or review-feedback run writes it through `ticket_record` as a
  `brief.written` event (`SymphonyElixir.TicketEvents.Types`): at its first delegated step, and
  again at its handoff when the work changed what the ticket does. The newest `brief.written` is the
  ticket's brief; an earlier one stays in the history. Linear's description is left as it is.

  The ticket read carries it as `brief` (`read/1`), and the summary of the ticket's history that
  every run's prompt carries opens with it (`SymphonyElixir.TicketEvents.Brief`).
  """

  alias SymphonyElixir.TicketEvents.Event

  @type t :: %{
          id: String.t() | nil,
          text: String.t() | nil,
          walkthrough: String.t() | nil,
          at: String.t() | nil,
          by: %{kind: String.t(), run_kind: String.t() | nil, run_id: String.t() | nil}
        }

  @doc """
  The newest `brief.written` among `events` (oldest first, as `SymphonyElixir.TicketEvents.query/2`
  reads them), nil when no run wrote one.
  """
  @spec current([Event.t()]) :: Event.t() | nil
  def current(events), do: events |> Enum.filter(&match?(%Event{type: "brief.written"}, &1)) |> List.last()

  @doc """
  The ticket's brief among `events` as the ticket read carries it: its `text`, its `walkthrough`,
  when it was written (`at`, ISO 8601) and who wrote it (`by`: the actor's kind, and the run's kind
  and id). Nil when no run wrote one.
  """
  @spec read([Event.t()]) :: t() | nil
  def read(events) do
    case current(events) do
      nil ->
        nil

      %Event{} = brief ->
        %{
          id: brief.id,
          text: Map.get(brief.payload, :text),
          walkthrough: Map.get(brief.payload, :walkthrough),
          at: iso8601(brief.at),
          by: %{
            kind: Atom.to_string(brief.actor.kind),
            run_kind: Map.get(brief.actor, :run_kind),
            run_id: Map.get(brief.actor, :run_id) || brief.run_id
          }
        }
    end
  end

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(_at), do: nil
end
