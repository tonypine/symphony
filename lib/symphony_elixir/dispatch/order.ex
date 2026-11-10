defmodule SymphonyElixir.Dispatch.Order do
  @moduledoc """
  The dispatch order read (`GET /api/v1/dispatch/order`, and `order` on `GET /api/v1/state`): every
  open ticket Symphony works, grouped by the kind of its situation (`SymphonyElixir.Situation`), and
  the dispatch candidates in the order the dispatcher starts them, each with the reason it is or is
  not next.

  The orchestrator walks its candidates at the end of each poll cycle, after the cycle's dispatch
  pass, in the order the pass walks them and through the pass's own gates and slot decision: no copy
  of either lives here. Each walked ticket comes out with an `outcome`:

  - `running`: a run works on it;
  - `held`: a gate keeps it out of the pass (a blocker, a hold, its repository's pause, the priority
    filter, the usage limit, a spent budget...), with the gate's reason and the `rule` behind it;
  - `paused`: its gates are open but the whole pass is paused (Symphony's pause, the workspace quota,
    the daily token budget);
  - `starts`: a pass run now starts it, on the `slot` it names;
  - `waits`: a pass run now leaves it waiting for a slot.

  `place/1` numbers the tickets that are in line (`starts`, `waits`, `paused`) and words each one's
  reason; `read/3` adds the open tickets that are not candidates and groups them all.
  """

  alias SymphonyElixir.{Situation, TicketState}

  @in_line [:starts, :waits, :paused]

  @typedoc "One walked candidate, as the orchestrator keeps it."
  @type entry :: %{
          required(:issue_id) => String.t(),
          required(:identifier) => String.t() | nil,
          required(:outcome) => :running | :held | :paused | :starts | :waits,
          required(:reason) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc "What the orchestrator keeps of the read: when it walked, the walked tickets, the slots."
  @type t :: %{computed_at: DateTime.t(), entries: [entry()], slots: map()}

  @doc """
  `entries` (in the order the pass walks them) with their place in line: `position` (1 for the next
  one, nil for a ticket out of line), `starts_now`, `wait` (why a waiting one waits) and `reason`:

  - the next one: `next: a slot is free`, or `next: ` and why it waits;
  - a later one: `2nd: a slot is free` when a pass run now starts it too, else `2nd: behind TP-n`;
  - a forced one that starts: `forced`;
  - a paused one: the pause's reason;
  - one out of line keeps the reason it came with.
  """
  @spec place([map()]) :: [map()]
  def place(entries) when is_list(entries) do
    {placed, _place} =
      Enum.map_reduce(entries, {0, nil}, fn entry, {position, previous} ->
        if entry.outcome in @in_line do
          position = position + 1
          {in_line(entry, position, previous), {position, entry.identifier}}
        else
          {Map.merge(entry, %{position: nil, starts_now: false, wait: nil}), {position, previous}}
        end
      end)

    placed
  end

  defp in_line(entry, position, previous) do
    Map.merge(entry, %{
      position: position,
      starts_now: entry.outcome == :starts,
      wait: if(entry.outcome == :waits, do: entry.reason),
      reason: reason(entry, position, previous)
    })
  end

  defp reason(%{outcome: :paused, reason: reason}, _position, _previous), do: reason
  defp reason(%{outcome: :starts, forced: true}, _position, _previous), do: "forced"
  defp reason(%{outcome: :starts}, position, _previous), do: "#{ordinal(position)}: a slot is free"
  defp reason(%{outcome: :waits, reason: reason}, 1, _previous), do: "next: #{reason}"
  defp reason(%{outcome: :waits}, position, previous), do: "#{ordinal(position)}: behind #{previous}"

  @doc "A place in line as the reasons say it: `next`, `2nd`, `3rd`, `4th`, `11th`, `21st`..."
  @spec ordinal(pos_integer()) :: String.t()
  def ordinal(1), do: "next"

  def ordinal(position) when is_integer(position) and position > 1 do
    suffix =
      cond do
        rem(position, 100) in 11..13 -> "th"
        rem(position, 10) == 1 -> "st"
        rem(position, 10) == 2 -> "nd"
        rem(position, 10) == 3 -> "rd"
        true -> "th"
      end

    "#{position}#{suffix}"
  end

  @doc """
  The read of `order` (what the orchestrator walked, nil before its first poll cycle) over the ticket
  `records` and the orchestrator's `live` facts (`Situation.live_facts/2`):

  - `next`: the identifier of the ticket first in line, nil when none is;
  - `queue`: the tickets in line, by `position`;
  - `groups`: every open ticket exactly once (a walked candidate, and every record neither removed nor
    in a terminal state), under the kind of its situation, the kinds in the situation's precedence
    and the tickets of a kind by place in line, then identifier;
  - `slots`: the slot and lane facts the walk read.

  A ticket that is not a candidate has `outcome` `not_a_candidate` and its situation's cause as its
  reason.
  """
  @spec read(t() | nil, [map()], Situation.live_facts()) :: map()
  def read(order, records, live) when is_list(records) do
    order = order || %{computed_at: nil, entries: [], slots: nil}
    records = Enum.map(records, &TicketState.normalize/1)
    terminal = MapSet.new(live.terminal_states, &normalize_state/1)
    walked = Map.new(order.entries, &{&1.issue_id, &1})
    by_id = Map.new(records, &{&1.issue_id, &1})

    open_ids =
      for record <- records, open?(record, terminal), not Map.has_key?(walked, record.issue_id), do: record.issue_id

    tickets =
      (Enum.map(order.entries, & &1.issue_id) ++ open_ids)
      |> Enum.map(&ticket(Map.get(walked, &1), Map.get(by_id, &1), &1, live, records))
      |> Enum.sort_by(&{is_nil(&1.position), &1.position || 0, &1.identifier || &1.issue_id})

    queue = Enum.filter(tickets, & &1.position)

    %{
      computed_at: iso8601(order.computed_at),
      next: queue |> List.first() |> then(&(&1 && &1.identifier)),
      slots: order.slots,
      queue: queue,
      groups: groups(tickets)
    }
  end

  defp open?(record, terminal) do
    is_nil(record.removed_at) and is_binary(record.issue_identifier) and is_binary(record.phase) and
      not MapSet.member?(terminal, normalize_state(record.phase))
  end

  defp ticket(entry, record, issue_id, live, records) do
    subject = record || %{issue_id: issue_id, repo_key: entry.repo_key}
    situation = subject |> Situation.read(live, records) |> Situation.payload()
    entry = entry || not_a_candidate(record, situation)

    entry
    |> Map.take([:issue_id, :identifier, :title, :state, :repo_key, :position, :reason, :wait, :slot, :forced, :starts_now])
    |> Map.merge(%{outcome: Atom.to_string(entry.outcome), rule: entry |> Map.get(:rule) |> rule_name(), situation: situation})
  end

  # An open ticket the poll does not offer for dispatch: its record says what it is.
  defp not_a_candidate(record, situation) do
    %{
      issue_id: record.issue_id,
      identifier: record.issue_identifier,
      title: record.title,
      state: record.phase,
      repo_key: record.repo_key,
      outcome: :not_a_candidate,
      reason: situation.cause,
      position: nil,
      starts_now: false,
      wait: nil,
      slot: nil,
      forced: false,
      rule: nil
    }
  end

  defp groups(tickets) do
    by_kind = Enum.group_by(tickets, & &1.situation.kind)

    for kind <- Situation.kinds(), group = Map.get(by_kind, kind), do: %{kind: kind, count: length(group), tickets: group}
  end

  defp rule_name(nil), do: nil
  defp rule_name(rule), do: to_string(rule)

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(nil), do: nil

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()
end
