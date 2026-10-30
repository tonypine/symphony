defmodule SymphonyElixir.DispatchLoop do
  @moduledoc """
  The general guard against dispatching one ticket over and over without progress.

  The orchestrator records every run it dispatches in the ticket's store record
  (`SymphonyElixir.TicketState.record_dispatch/3`) with the run kind, the state and the PR head it
  started on, and records how the run ended. Before the next dispatch, `check/4` counts the runs of
  the same kind since the ticket last made progress, in two windows (`watchdog.dispatch_loop_runs`
  within `watchdog.dispatch_loop_window_ms`, 4 in 10 minutes by default, and
  `watchdog.dispatch_loop_long_runs` within `watchdog.dispatch_loop_long_window_ms`, 8 in an hour).
  When the runs already dispatched reach either limit, the next one is not started: the ticket is
  put on a `Blocked` hold whose reason (`hold_attrs/2`) names the run kind, the count, the window
  and how the last runs ended.

  Progress ends the count. A run that started on another state or another PR head is older than the
  last state move or push, so it is not counted; a verdict recorded and a hold cleared (a person
  unblocked the ticket, answered its decision, or what it waited on landed) empty the record's runs
  (`SymphonyElixir.TicketState`). A run stopped by a usage limit or an unreachable model API is
  dropped when it ends, since the orchestrator counts no attempt for it, and so is an epic review
  that found CI still running on its commit: CI takes longer than the window, and that wait has its
  own bound (`SymphonyElixir.CiWait`). Clearing the loop hold
  itself, with `Unblock` or `Restart`, empties them too, so the ticket starts again from zero.

  Before the hold, the guard asks a question (`question_attrs/2`, through `SymphonyElixir.Questions`)
  that pauses the ticket on a `:question` reason: "Run it again", "Start it over from main" or "Keep
  it paused". The hold names the question (`waits_on.question_id`) and is cleared with it, and the
  answer's option is Unblock, Restart or nothing (`answer_move/1`). A quiet handoff, a ticket whose
  last runs ended without a handoff (`SymphonyElixir.Orchestrator`), asks the same question.
  """

  alias SymphonyElixir.TicketState

  @hold_type "dispatch_loop"
  @handoff_signal "handoff"
  # How many of the last runs the hold reason describes.
  @shown_runs 3
  @run_again "Run it again"
  @start_over "Start it over from main"
  @keep_paused "Keep it paused"

  @typedoc "The two limits: `runs` within `window_ms`, and `long_runs` within `long_window_ms`."
  @type limits :: %{
          runs: pos_integer(),
          window_ms: pos_integer(),
          long_runs: pos_integer(),
          long_window_ms: pos_integer()
        }

  @typedoc "The run about to be dispatched: its kind, and the state and PR head it would start on."
  @type attempt :: %{kind: atom() | String.t(), state: String.t() | nil, head: String.t() | nil}

  @typedoc "A loop: `count` runs of `kind` within `window_ms`, the runs themselves newest first."
  @type loop :: %{kind: String.t(), count: pos_integer(), window_ms: pos_integer(), runs: [TicketState.dispatch()]}

  @typedoc "What made Symphony stop starting runs: a loop, or `runs` quiet runs without a handoff."
  @type stop :: loop() | {:quiet_handoff, pos_integer()}

  @doc "The `waits_on` type of a dispatch-loop hold."
  @spec hold_type() :: String.t()
  def hold_type, do: @hold_type

  @doc "The limits the `watchdog` settings set."
  @spec limits(map()) :: limits()
  def limits(watchdog) do
    %{
      runs: watchdog.dispatch_loop_runs,
      window_ms: watchdog.dispatch_loop_window_ms,
      long_runs: watchdog.dispatch_loop_long_runs,
      long_window_ms: watchdog.dispatch_loop_long_window_ms
    }
  end

  @doc """
  Whether dispatching `attempt` now would go past a limit, given the ticket's recorded `dispatches`
  (newest first). Only the runs of the attempt's kind since the last progress count: the newest runs
  that started on the attempt's state and PR head. Returns `:ok`, or `{:loop, loop}` for the first
  window whose limit the runs already reached.
  """
  @spec check([TicketState.dispatch()], attempt(), limits(), DateTime.t()) :: :ok | {:loop, loop()}
  def check(dispatches, attempt, limits, %DateTime{} = now) when is_list(dispatches) do
    kind = kind_name(attempt.kind)

    counted =
      dispatches
      |> Enum.take_while(&same_progress?(&1, attempt))
      |> Enum.filter(&(&1.kind == kind))

    Enum.find_value([{limits.runs, limits.window_ms}, {limits.long_runs, limits.long_window_ms}], :ok, fn {runs, window_ms} ->
      within = Enum.filter(counted, &within?(&1, now, window_ms))
      if length(within) >= runs, do: {:loop, %{kind: kind, count: length(within), window_ms: window_ms, runs: within}}
    end)
  end

  @doc """
  The `Blocked` hold a loop sets: a reason naming the run kind, the count, the window and how the
  last runs ended (their exit, whether they left a new PR head, and whether the handoff signal was
  recorded while they ran, read from the ticket's `signals`), lifted by a person's `Unblock` or
  `Restart`.
  """
  @spec hold_attrs(loop(), [TicketState.signal()]) :: map()
  def hold_attrs(%{kind: kind, count: count, window_ms: window_ms, runs: runs}, signals) do
    shown = runs |> Enum.take(@shown_runs) |> describe_runs(signals)

    %{
      reason:
        "#{@hold_type}: #{plural(count, "#{kind} run")} in #{window(window_ms)} without a state change, a new PR head or a decision, " <>
          "so Symphony started no more. Last runs: #{Enum.join(shown, "; ")}",
      clearing_condition: "when a person unblocks or restarts it",
      waits_on: %{type: @hold_type, keys: [kind]}
    }
  end

  @doc """
  The question Symphony asks when it stops starting runs on the ticket `name` (its identifier): a
  `SymphonyElixir.Questions.ask/3` request whose options are Unblock ("#{@run_again}", the
  recommended one: the hold's reason offers Unblock first), Restart ("#{@start_over}") and nothing
  ("#{@keep_paused}").
  """
  @spec question_attrs(stop(), String.t()) :: map()
  def question_attrs(%{count: count, window_ms: window_ms}, name) do
    request(
      "#{name} ran #{count} times in #{window(window_ms)} without finishing",
      "Symphony started no more runs on #{name}: its last runs changed nothing, with no new state, no new change to its pull request and no decision.",
      name
    )
  end

  def question_attrs({:quiet_handoff, runs}, name) do
    request(
      "#{name}'s last #{number(runs)} runs ended without a handoff",
      "The last runs on #{name} stopped without handing the work on, so Symphony started no more runs on it.",
      name
    )
  end

  @doc """
  What the answer to a `question_attrs/2` question asks for, by the option it picked: `:unblock`
  for "#{@run_again}", `:restart` for "#{@start_over}", and `:keep` for "#{@keep_paused}", a
  free-text answer or a question not answered.
  """
  @spec answer_move(map()) :: :unblock | :restart | :keep
  def answer_move(%{state: :answered, answer: %{option: number}, options: options}) when is_integer(number) do
    case Enum.at(options, number - 1) do
      %{label: @run_again} -> :unblock
      %{label: @start_over} -> :restart
      _other -> :keep
    end
  end

  def answer_move(_question), do: :keep

  @doc "The label of the option a `question_attrs/2` question answers for `move` (`:unblock` or `:restart`)."
  @spec option_label(:unblock | :restart) :: String.t()
  def option_label(:unblock), do: @run_again
  def option_label(:restart), do: @start_over

  defp request(title, why, name) do
    %{
      title: title,
      question: "#{title}. Should Symphony run it again, start it over from main, or keep it paused?",
      why: why,
      if_unanswered: "#{name} stays paused and Symphony starts no run on it.",
      recommendation_reason: "Another run picks up where the last one stopped, with nothing lost.",
      options: [
        %{label: @run_again, effect: "Symphony starts a new run on #{name} where it stopped.", recommended: true},
        %{label: @start_over, effect: "Symphony closes the pull request of #{name} and starts again from the main branch.", recommended: false},
        %{label: @keep_paused, effect: "#{name} stays paused until you decide.", recommended: false}
      ]
    }
  end

  defp number(2), do: "two"
  defp number(count), do: Integer.to_string(count)

  # Each run is described up to the next newer run's start, or now for the newest.
  defp describe_runs(runs, signals) do
    ends = [nil | Enum.map(runs, & &1.at)]
    runs |> Enum.zip(ends) |> Enum.map(fn {run, until} -> describe_run(run, until, signals) end)
  end

  defp describe_run(run, until, signals) do
    Enum.join([started(run.at), ended(run.outcome), pushed(run), handoff(run.at, until, signals)], ", ")
  end

  defp started(%DateTime{} = at), do: "started #{Calendar.strftime(at, "%H:%M UTC")}"
  defp started(_at), do: "started at an unknown time"

  defp ended(%{exit: exit}) when exit != "", do: exit
  defp ended(_outcome), do: "no recorded end"

  defp pushed(%{head: head, outcome: %{head: new_head}}) when is_binary(new_head) and new_head != head,
    do: "pushed #{String.slice(new_head, 0, 7)}"

  defp pushed(_run), do: "no new PR head"

  defp handoff(from, until, signals) do
    if Enum.any?(signals, &(&1.name == @handoff_signal and between?(&1.at, from, until))),
      do: "handoff signal",
      else: "no handoff signal"
  end

  defp between?(%DateTime{} = at, %DateTime{} = from, until) do
    DateTime.compare(at, from) != :lt and (is_nil(until) or DateTime.compare(at, until) == :lt)
  end

  defp between?(_at, _from, _until), do: false

  # A run that started on another state or PR head is older than the last move or push.
  defp same_progress?(run, attempt) do
    normalize(run.state) == normalize(attempt.state) and run.head == attempt.head
  end

  defp within?(%{at: %DateTime{} = at}, now, window_ms), do: DateTime.diff(now, at, :millisecond) < window_ms
  defp within?(_run, _now, _window_ms), do: false

  defp window(ms) when rem(ms, 60_000) == 0, do: plural(div(ms, 60_000), "minute")
  defp window(ms), do: plural(div(ms, 1_000), "second")

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(count, unit), do: "#{count} #{unit}s"

  defp kind_name(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_name(kind) when is_binary(kind), do: kind

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: nil
end
