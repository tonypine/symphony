defmodule SymphonyElixir.IdlePark do
  @moduledoc """
  The park of an idle run: the agent runner moves a ticket whose last turns made no new commit and
  no state change to `Backlog` (`SymphonyElixir.AgentRunner`), from `In Progress` or `Rework`.

  A park is a stop like a dispatch loop's (`SymphonyElixir.DispatchLoop`), so it asks its question
  through the one path (`SymphonyElixir.Questions`, `question_attrs/2`): "Run it again" (recommended),
  "Start it over from main" or "Leave it parked". The question pauses the ticket on a `:question`
  reason, and the `Blocked` hold set beside it (`hold_attrs/2`) names it (`waits_on.question_id`) and
  the phase the ticket was parked from (`waits_on.keys`). The hold and its question are cleared
  together, as a dispatch loop's are: the answer's option is Unblock, Restart or nothing
  (`SymphonyElixir.DispatchLoop.answer_move/1`).

  Unblock on a parked ticket (`SymphonyElixir.DirectorMoves`) moves it back to the phase it was
  parked from (`parked_from/3`), with its workspace and branch as they are, then clears the hold,
  which empties the record's counted runs. A ticket parked before parks asked their question carries
  no hold: its record's newest move signal, the park's own (`"blocked"` with `reason: "idle_park"`),
  says it was parked, and it goes back to `In Progress` unless the signal names its phase.
  """

  alias SymphonyElixir.{DispatchLoop, TicketState}

  @hold_type "idle_park"
  @park_state "Backlog"
  @resume_state "In Progress"
  @leave_parked "Leave it parked"

  @doc "The `waits_on` type of a park's hold."
  @spec hold_type() :: String.t()
  def hold_type, do: @hold_type

  @doc "Whether a hold is the one a park set."
  @spec hold?(TicketState.hold() | term()) :: boolean()
  def hold?(%{waits_on: %{type: @hold_type}}), do: true
  def hold?(_hold), do: false

  @doc """
  The `Blocked` hold a park sets on a ticket parked from `from_state` after `turns` turns: a reason
  naming them, lifted by a person's Unblock or Restart, waiting on the phase it goes back to.
  """
  @spec hold_attrs(String.t(), pos_integer()) :: map()
  def hold_attrs(from_state, turns) when is_binary(from_state) and is_integer(turns) do
    %{
      reason: "#{@hold_type}: #{turns} turns in #{from_state} made no new commit and no state change, so Symphony parked it in #{@park_state}",
      clearing_condition: "when a person unblocks or restarts it",
      waits_on: %{type: @hold_type, keys: [from_state]}
    }
  end

  @doc """
  The question a park asks on the ticket `name` (its identifier): a `SymphonyElixir.Questions.ask/3`
  request whose options are Unblock ("#{DispatchLoop.option_label(:unblock)}", recommended), Restart
  ("#{DispatchLoop.option_label(:restart)}") and nothing ("#{@leave_parked}").
  """
  @spec question_attrs(String.t(), pos_integer()) :: map()
  def question_attrs(name, turns) when is_binary(name) and is_integer(turns) do
    title = "#{name} is parked: its last #{turns} turns changed nothing"

    %{
      title: title,
      question: "#{title}. Should Symphony run it again where it stopped, start it over from main, or leave it parked?",
      why:
        "The last #{turns} turns on #{name} made no new commit and moved it nowhere, so another turn would repeat them. " <>
          "Symphony parked it in #{@park_state} and keeps its work: its commits are on its branch.",
      if_unanswered: "#{name} stays parked in #{@park_state} and Symphony starts no run on it.",
      recommendation_reason: "A new run continues from the parked work, with nothing lost.",
      options: [
        %{
          label: DispatchLoop.option_label(:unblock),
          effect: "Symphony moves #{name} back to where it was and starts a new run on its work, with its commits.",
          recommended: true
        },
        %{
          label: DispatchLoop.option_label(:restart),
          effect: "Symphony closes the pull request of #{name}, drops its work and starts again from the main branch.",
          recommended: false
        },
        %{label: @leave_parked, effect: "#{name} stays parked in #{@park_state} until you decide.", recommended: false}
      ]
    }
  end

  @doc """
  The phase a ticket in `phase` goes back to when a person unblocks it: `{:ok, state}` when it is in
  `Backlog` because a park put it there — its park `hold` names the phase it left, or, with no hold,
  the newest move signal among its record's `signals` (newest first) is the park's — else `:none`.
  """
  @spec parked_from(String.t() | nil, TicketState.hold() | nil, [TicketState.signal()]) :: {:ok, String.t()} | :none
  def parked_from(phase, hold, signals) when is_list(signals) do
    cond do
      not same_state?(phase, @park_state) -> :none
      hold?(hold) -> {:ok, hold |> get_in([:waits_on, :keys]) |> List.wrap() |> Enum.find(@resume_state, &is_binary/1)}
      is_nil(hold) -> parked_by_signal(signals)
      true -> :none
    end
  end

  defp parked_by_signal(signals) do
    with %{name: "blocked"} = signal <- Enum.find(signals, &(detail(&1, :to) != nil)),
         @hold_type <- detail(signal, :reason) do
      {:ok, detail(signal, :from) || @resume_state}
    else
      _other -> :none
    end
  end

  defp detail(%{details: details}, key) when is_map(details), do: Map.get(details, key) || Map.get(details, Atom.to_string(key))
  defp detail(_signal, _key), do: nil

  defp same_state?(left, right) when is_binary(left), do: String.downcase(String.trim(left)) == String.downcase(right)
  defp same_state?(_left, _right), do: false
end
