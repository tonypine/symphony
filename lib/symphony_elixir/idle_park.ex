defmodule SymphonyElixir.IdlePark do
  @moduledoc """
  The park of an idle run: the agent runner moves a ticket whose last turns made no new commit and
  no state change to `Backlog` (`SymphonyElixir.AgentRunner`), from `In Progress` or `Rework`.

  A park is a stop like a dispatch loop's (`SymphonyElixir.DispatchLoop`), so it asks its question
  through the one path (`SymphonyElixir.Questions`, `question_attrs/2`): "Run it again" (recommended),
  "Start it over from main" or "Leave it parked". The question pauses the ticket on a `:question`
  reason (`SymphonyElixir.Pauses`), and the answer's option is Unblock, Restart or nothing
  (`SymphonyElixir.DispatchLoop.answer_move/1`).

  Unblock on a parked ticket (`SymphonyElixir.DirectorMoves`) moves it back to the phase it was
  parked from (`parked_from/2`), with its workspace and branch as they are, then answers its
  question, which empties the record's counted runs. The record's newest move signal, the park's own
  (`"blocked"` with `reason: "idle_park"`, `signal_reason/0`), says it was parked and the phase it
  left; one that names no phase goes back to `In Progress`.
  """

  alias SymphonyElixir.{DispatchLoop, TicketState}

  @signal_reason "idle_park"
  @park_state "Backlog"
  @resume_state "In Progress"
  @leave_parked "Leave it parked"

  @doc "The `reason` of a park's move signal."
  @spec signal_reason() :: String.t()
  def signal_reason, do: @signal_reason

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
  `Backlog` because a park put it there — the newest move signal among its record's `signals`
  (newest first) is the park's — else `:none`.
  """
  @spec parked_from(String.t() | nil, [TicketState.signal()]) :: {:ok, String.t()} | :none
  def parked_from(phase, signals) when is_list(signals) do
    if same_state?(phase, @park_state), do: parked_by_signal(signals), else: :none
  end

  defp parked_by_signal(signals) do
    with %{name: "blocked"} = signal <- Enum.find(signals, &(detail(&1, :to) != nil)),
         @signal_reason <- detail(signal, :reason) do
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
