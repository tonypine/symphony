defmodule SymphonyElixir.IdlePark do
  @moduledoc """
  The park of an idle run: the agent runner holds a ticket whose last turns made no new commit and
  no state change in the phase it is in (`SymphonyElixir.AgentRunner`, `hold/6`). It never leaves
  the phase, so the PR and CI watcher keeps watching it (TP-1175).

  A hold is a stop like a dispatch loop's (`SymphonyElixir.DispatchLoop`), so it asks its question
  through the one path (`SymphonyElixir.Questions`, `hold_question_attrs/3`): "Run it again"
  (recommended), "Start it over from main" or "Keep it paused". The answer's option is Unblock,
  Restart or nothing (`SymphonyElixir.DispatchLoop.answer_move/1`). Beside the question the ticket's
  pause holds an `:environment` reason the Director may release (`reason/1`), which says why in plain
  words and what the PR read when the hold was set: the head the park left and its CI. The silent-wait
  report lists it from that reason (`silent_bound/0`), with its age.

  The watcher lifts the hold when that changes (`settle/3`): the PR has a later head than the park
  left, or its checks reported green or red where they had not. The ticket then continues in its
  phase, and a CI Fix ticket whose head went green returns to where it came from.

  A ticket parked before TP-1175 sits in `Backlog`. Unblock moves it back to the phase it was
  parked from (`parked_from/2`), with its workspace and branch as they are, then answers its
  question, which empties the record's counted runs. The record's newest move signal, the park's own
  (`"blocked"` with `reason: "idle_park"`, `signal_reason/0`), says it was parked and the phase it
  left; one that names no phase goes back to `In Progress`. `question_attrs/2` and `ask/4` stay for
  such a ticket, whose start-up backfill (`SymphonyElixir.IdlePark.Backfill`) still asks in those
  words.
  """

  require Logger

  alias SymphonyElixir.{DispatchLoop, Pauses, Questions, TicketState}

  @signal_reason "idle_park"
  @park_state "Backlog"
  @resume_state "In Progress"
  @leave_parked "Leave it parked"
  @idle_turns 2
  @silent_bound "no_progress"
  @setter %{kind: :rule, name: "No-progress pause"}

  @typedoc "The watcher's record of a ticket's PR, as far as a hold reads it."
  @type watch :: %{optional(:head_sha) => String.t() | nil, optional(:facts) => map(), optional(atom()) => term()}

  @doc "How many turns in a row that change nothing park a run: its last #{@idle_turns}."
  @spec idle_turns() :: pos_integer()
  def idle_turns, do: @idle_turns

  @doc "The `reason` of a park's move signal."
  @spec signal_reason() :: String.t()
  def signal_reason, do: @signal_reason

  @doc "The `bound` of a held ticket's entry in the silent-wait report (`SymphonyElixir.PrWatch.silent_waits/1`)."
  @spec silent_bound() :: String.t()
  def silent_bound, do: @silent_bound

  @doc """
  The question a hold asks on the ticket `name` (its identifier), held in `phase` after `turns` idle
  turns: a `SymphonyElixir.Questions.ask/3` request whose options are Unblock
  ("#{DispatchLoop.option_label(:unblock)}", recommended), Restart
  ("#{DispatchLoop.option_label(:restart)}") and nothing ("#{DispatchLoop.option_label(:keep)}").
  """
  @spec hold_question_attrs(String.t(), String.t(), pos_integer()) :: map()
  def hold_question_attrs(name, phase, turns) when is_binary(name) and is_binary(phase) and is_integer(turns) do
    title = "#{name} is paused in #{phase}: its last #{turns} turns changed nothing"

    %{
      title: title,
      question: "#{title}. Should Symphony run it again where it stopped, start it over from main, or keep it paused?",
      why:
        "The last #{turns} turns on #{name} made no new commit, changed no file and moved it nowhere, so another turn would repeat them. " <>
          "Symphony keeps it in #{phase} with its work and goes on watching its pull request; the comment on the ticket says what it committed and pushed.",
      if_unanswered: "#{name} stays paused in #{phase} until its pull request gets a new commit or its checks report.",
      recommendation_reason: "A new run continues from the work so far, with nothing lost.",
      options: [
        %{label: DispatchLoop.option_label(:unblock), effect: "Symphony starts a new run on #{name} where it stopped, with its commits.", recommended: true},
        %{
          label: DispatchLoop.option_label(:restart),
          effect: "Symphony closes the pull request of #{name}, drops its work and starts again from the main branch.",
          recommended: false
        },
        %{label: DispatchLoop.option_label(:keep), effect: "#{name} stays paused in #{phase} until you decide.", recommended: false}
      ]
    }
  end

  @doc """
  Holds the ticket (named `name`) in `phase` after `turns` idle turns: its pause gets the reason
  that says why and what the PR read (`watch`, the watcher's record, nil when it has none), and the
  hold's question (`hold_question_attrs/3`), which the Inbox lists. A question the store refuses is
  logged: the reason, which the Director releases with Unblock, holds the ticket on its own.

  `left_head` is the head the park leaves on the branch, nil when it knows of none. A park can push,
  so the watcher's record may be older than the branch: the reason then keeps `left_head` as its
  `head`, the record's head as its `earlier_head` and no CI, so neither the park's own push nor a
  late read of the older head lifts the hold (`settle/3`).
  """
  @spec hold(Questions.ticket(), String.t(), String.t(), pos_integer(), watch() | nil, String.t() | nil) :: :ok
  def hold({:ticket, _repo_key, _issue_id} = ticket, name, phase, turns, watch, left_head \\ nil) when is_binary(name) and is_binary(phase) and is_integer(turns) do
    text = "No progress: the last #{turns} turns in #{phase} made no new commit and no state change"
    waits_on = watch |> read_at() |> left_on(left_head) |> Map.put(:condition, @signal_reason)
    _ = Pauses.set(ticket, %{kind: :environment, waits_on: waits_on, text: String.slice(text, 0, 300), releasable: true})

    case Questions.ask(ticket, hold_question_attrs(name, phase, turns)) do
      {:ok, _question} -> :ok
      {:error, reason} -> Logger.warning("Failed to ask the hold's question for #{name}: #{inspect(reason)}")
    end

    :ok
  end

  # What the watcher's record reads, as the reason keeps it. No record reads as nothing, so only a
  # head that then reports lifts the hold.
  defp read_at(%{head_sha: head, facts: %{ci: ci}}) when is_binary(head) and is_atom(ci), do: %{head: head, ci: Atom.to_string(ci)}
  defp read_at(_watch), do: %{}

  # The record's CI is of the record's head, so it holds only while that is the head left behind.
  defp left_on(read, nil), do: read
  defp left_on(%{head: left_head} = read, left_head), do: read
  defp left_on(%{head: earlier_head}, left_head), do: %{head: left_head, earlier_head: earlier_head}
  defp left_on(_no_read, left_head), do: %{head: left_head}

  @doc """
  The hold's reason on the ticket's `record`, or nil when it is not held. A reason an older park set
  when its question was refused reads the same; that ticket sits in `Backlog`, which the watcher
  does not read.
  """
  @spec reason(TicketState.t() | map() | nil) :: Pauses.reason() | nil
  def reason(nil), do: nil

  def reason(record) when is_map(record) do
    record |> TicketState.pause_reasons() |> Enum.find(&reason?/1)
  end

  defp reason?(%{kind: :environment, waits_on: %{condition: @signal_reason}}), do: true
  defp reason?(_reason), do: false

  @doc """
  Lifts the ticket's hold, by the rule, when the watcher's new read (`watch`) differs from what it
  read when the hold was set (`reason/1` on the `record` the tick started from): the PR has a new
  head, or its checks reported green or red where they had not. A running check changes nothing:
  the hold stays until it reports. So does a read of the head the park pushed past (`hold/6`), whatever
  its checks say: GitHub can show it for a while after the push (TP-1422). Withdraws the question and
  clears the reason, so the ticket continues in its phase. `:lifted` or `:held`; a record with no hold
  is `:held`.
  """
  @spec settle(Questions.ticket(), TicketState.t() | map() | nil, watch()) :: :lifted | :held
  def settle({:ticket, _repo_key, _issue_id} = ticket, record, watch) when is_map(watch) do
    case reason(record) do
      %{waits_on: waits_on} -> if changed?(waits_on, watch), do: lift(ticket), else: :held
      nil -> :held
    end
  end

  defp changed?(%{earlier_head: head}, %{head_sha: head}), do: false

  defp changed?(waits_on, %{head_sha: head, facts: %{ci: ci}}) when is_binary(head) do
    new_head?(Map.get(waits_on, :head), head) or (ci in [:green, :red] and Map.get(waits_on, :ci) != Atom.to_string(ci))
  end

  defp changed?(_waits_on, _watch), do: false

  defp new_head?(held_on, head), do: is_binary(held_on) and held_on != head

  defp lift(ticket) do
    with %{id: id} <- Questions.held(ticket) do
      Questions.withdraw(ticket, id, "Its pull request changed: it has a new commit, or its checks reported, so another run can make progress.", cause: "hold_cleared")
    end

    _ = Pauses.clear_reasons(ticket, &reason?/1, by: @setter)
    :lifted
  end

  @doc """
  The question a park asks on the ticket `name` (its identifier) in `Backlog`: a `SymphonyElixir.Questions.ask/3`
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
        "The last #{turns} turns on #{name} made no new commit, changed no file and moved it nowhere, so another turn would repeat them. " <>
          "Symphony parked it in #{@park_state} and keeps its work; the park's comment on the ticket says what it committed and pushed.",
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
  Pauses a `ticket` parked in `Backlog` before TP-1175 (named `name`, parked from `from_state` after
  `turns` idle turns) on the park's question (`question_attrs/2`, asked through
  `SymphonyElixir.Questions.ask/3`), which the Inbox lists: `{:asked, question_id}`. One the store
  refuses is logged and pauses the ticket on a reason the Director releases with Unblock instead, as a
  dispatch loop's does: `:reason_set`. The start-up backfill of such a park
  (`SymphonyElixir.IdlePark.Backfill`) calls it.
  """
  @spec ask(Questions.ticket(), String.t(), String.t() | nil, pos_integer()) :: {:asked, String.t()} | :reason_set
  def ask({:ticket, _repo_key, _issue_id} = ticket, name, from_state, turns) when is_binary(name) and is_integer(turns) do
    case Questions.ask(ticket, question_attrs(name, turns)) do
      {:ok, %{id: question_id}} ->
        {:asked, question_id}

      {:error, reason} ->
        Logger.warning("Failed to ask the park's question for #{name}: #{inspect(reason)}")
        text = "#{turns} turns in #{from_state || @resume_state} made no new commit and no state change, so Symphony parked it in #{@park_state}"
        _ = Pauses.set(ticket, %{kind: :environment, waits_on: %{condition: @signal_reason}, text: String.slice(text, 0, 300), releasable: true})
        :reason_set
    end
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
