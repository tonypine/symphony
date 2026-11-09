defmodule SymphonyElixir.TicketEvents.Notable do
  @moduledoc """
  The rule set that marks an event notable: what the Journal (`SymphonyElixir.TicketEvents.Journal`,
  `GET /api/v1/events?notable=true`) lists as the day's story. An event is notable when one rule of
  `rules/0` holds for it; each rule is one clause of `holds?/3`:

    * `:verdict` - a review, QA, CI Fix, plan or epic verdict (`verdict.recorded`);
    * `:phase_move` - the ticket entered a phase (`phase.entered`), or a person moved or cancelled it
      (`ticket.moved`, `ticket.cancelled`);
    * `:question` - a question asked or answered (`question.asked`, `question.answered`, and the
      legacy `decision.requested`, `decision.recorded`);
    * `:long_pause` - a ticket's pause (`pause.set`) that lasted, or has lasted so far, at least
      `pause_threshold_ms/0` before its `pause.cleared`: a pause cleared within it is noise;
    * `:rule_action` - a rule acted on the ticket (`rule.action`, `SymphonyElixir.RuleActions`);
    * `:ticket_filed` - a fix ticket self-heal filed (a `rule.action` that `filed_ticket`) or a ticket
      split off from this one (`ticket.filed`);
    * `:shipped_or_cancelled` - the ticket entered Done or Canceled, or a person cancelled it;
    * `:release_installed` - Symphony's own pause lost an update's `build` reason: the build it
      waited on runs (`pause.reason_cleared`, `pause.cleared` on Symphony's stream);
    * `:factory_paused` - Symphony's own pause was set or cleared (`pause.set`, `pause.cleared` on
      Symphony's stream): the factory paused or resumed;
    * `:situation` - the ticket's situation (`situation.changed`) became one a person reads first:
      waiting on you, retrying or blocked by a ticket.

  A rule reads the event and its context (`t:context/0`): the events of its stream, oldest first,
  and the time the read is made, so a pause still going counts the time it has lasted.
  """

  alias SymphonyElixir.TicketEvents.Event

  @pause_threshold_ms 15 * 60_000
  @rules [
    :verdict,
    :phase_move,
    :question,
    :long_pause,
    :rule_action,
    :ticket_filed,
    :shipped_or_cancelled,
    :release_installed,
    :factory_paused,
    :situation
  ]
  @symphony_stream "symphony"
  @shipped_phases ["done", "canceled", "cancelled"]
  @situations ["waiting_on_you", "retrying", "blocked_by_ticket"]

  @type rule ::
          :verdict
          | :phase_move
          | :question
          | :long_pause
          | :rule_action
          | :ticket_filed
          | :shipped_or_cancelled
          | :release_installed
          | :factory_paused
          | :situation

  @typedoc "What a rule reads besides the event: its stream's events, oldest first, and the time of the read."
  @type context :: %{events: [Event.t()], now: DateTime.t()}

  @doc "Every rule, in the order the moduledoc lists them."
  @spec rules() :: [rule()]
  def rules, do: @rules

  @doc "How long a ticket's pause must last to be notable: #{div(@pause_threshold_ms, 60_000)} minutes."
  @spec pause_threshold_ms() :: pos_integer()
  def pause_threshold_ms, do: @pause_threshold_ms

  @doc "Whether `event` is notable: one rule of `rules/0` holds for it in `context`."
  @spec notable?(Event.t(), context()) :: boolean()
  def notable?(%Event{} = event, context), do: Enum.any?(@rules, &holds?(&1, event, context))

  @doc "Whether the rule `rule` holds for `event` in `context` (see the moduledoc)."
  @spec holds?(rule(), Event.t(), context()) :: boolean()
  def holds?(:verdict, %Event{type: type}, _context), do: type == "verdict.recorded"
  def holds?(:phase_move, %Event{type: type} = event, _context), do: ticket?(event) and type in ["phase.entered", "ticket.moved", "ticket.cancelled"]
  def holds?(:question, %Event{type: type}, _context), do: type in ["question.asked", "question.answered", "decision.requested", "decision.recorded"]
  def holds?(:long_pause, %Event{type: "pause.set"} = event, context), do: ticket?(event) and lasted_ms(event, context) >= @pause_threshold_ms
  def holds?(:rule_action, %Event{type: type}, _context), do: type == "rule.action"
  def holds?(:ticket_filed, %Event{type: "ticket.filed"}, _context), do: true
  def holds?(:ticket_filed, %Event{type: "rule.action", payload: payload}, _context), do: field(payload, :action) == "filed_ticket"
  def holds?(:shipped_or_cancelled, %Event{type: "ticket.cancelled"}, _context), do: true

  def holds?(:shipped_or_cancelled, %Event{type: "phase.entered", payload: payload} = event, _context),
    do: ticket?(event) and String.downcase(field(payload, :to) || "") in @shipped_phases

  def holds?(:release_installed, %Event{type: "pause.reason_cleared", payload: payload} = event, _context), do: symphony?(event) and field(payload, :reason) == "build"

  def holds?(:release_installed, %Event{type: "pause.cleared", payload: payload} = event, _context),
    do: symphony?(event) and Enum.any?(List.wrap(Map.get(payload, :cleared)), &(field(&1, :reason) == "build"))

  def holds?(:factory_paused, %Event{type: type} = event, _context), do: symphony?(event) and type in ["pause.set", "pause.cleared"]
  def holds?(:situation, %Event{type: "situation.changed", payload: payload}, _context), do: field(payload, :to) in @situations
  def holds?(_rule, _event, _context), do: false

  # How long the pause `event` set lasted: until the first `pause.cleared` after it on its stream,
  # else until the read.
  defp lasted_ms(%Event{at: %DateTime{} = at} = event, %{events: events, now: now}) do
    ended =
      events
      |> Enum.drop_while(&(&1.id != event.id))
      |> Enum.find(&(&1.type == "pause.cleared"))
      |> case do
        %Event{at: %DateTime{} = cleared_at} -> cleared_at
        _still_paused -> now
      end

    DateTime.diff(ended, at, :millisecond)
  end

  defp lasted_ms(_event, _context), do: 0

  defp ticket?(%Event{issue_id: issue_id}), do: issue_id != @symphony_stream
  defp symphony?(%Event{issue_id: issue_id}), do: issue_id == @symphony_stream

  defp field(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_atom(value) and not is_nil(value) and not is_boolean(value) -> Atom.to_string(value)
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp field(_map, _key), do: nil
end
