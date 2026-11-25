defmodule SymphonyElixir.DecisionMove do
  @moduledoc """
  The move a decision's option makes once a person picks it.

  A question Symphony asks may offer an option whose answer is a move: QA's "Send it back to
  Rework" and "Merge without a QA result", a closed pull request's "Cancel". The option carries
  that move as data (`option/2`), so a pick never asks the person to also drag the ticket by hand,
  which under `dispatch.source: record` is drift moved back anyway. The Question keeps the move on
  its option (`SymphonyElixir.Questions`). When the person answers with the Inbox's Decide
  (`SymphonyElixir.DirectorMoves`), the picked option's move (`picked/2`) is performed through the
  guard (`perform/4`).

  A move may carry a verdict recorded before it, bound to the head the question was asked on: a
  merge without a QA result records the `qa` verdict `skip` with the reason `skipped by decision`.
  It may also carry a finding recorded before it, as the run that asked's (`finding`, the
  Conductor's "Send it to Rework" option): the rework run reads it as it reads QA's findings. And
  it may carry waivers (`waive`): checks of the ticket's plan recorded as waived before the move,
  each with its reason (`SymphonyElixir.ChecksHold`'s "Waive them and pass it on").

  A move back to Code Review from Rework with the pull request as it is (`handoff`, an option's
  "back to review unchanged": the Conductor's `back_to_review` action, a run's question option with
  `back_to_review`) leaves the ticket as a finished rework leaves it: the handoff for the head is
  emitted first (the head the question was asked on, else the head the Rework started from), and once
  the move is made the stored rework base is forgotten, so the next dispatch is Code Review's on that
  head and no rework run starts.
  """

  require Logger

  alias SymphonyElixir.{Handoff, MergeConfirmation, RunStore, TicketChecks, TicketSignals, TransitionGuard}

  @canceled_spellings ["Canceled", "Cancelled"]

  @typedoc "A verdict a move records first: its kind, outcome, the head it judges and why."
  @type verdict :: %{kind: String.t(), outcome: String.t(), head_sha: String.t() | nil, reason: String.t()}

  @typedoc "A finding a move records first: what must change, and the run (its id and kind) it is recorded as."
  @type finding :: %{description: String.t(), run_id: String.t(), run_kind: String.t()}

  @typedoc "A check of the ticket's plan a move waives first, and why."
  @type waiver :: %{check_id: String.t(), reason: String.t()}

  @typedoc "A handoff a move emits first: the head the pull request returns to review on, nil for the Rework's base."
  @type handoff :: %{head: String.t() | nil}

  @typedoc "The state a picked option moves the ticket to, and the verdict, the finding, the waivers and the handoff it records first, if any."
  @type t :: %{
          required(:to) => String.t(),
          optional(:verdict) => verdict(),
          optional(:finding) => finding(),
          optional(:waive) => [waiver()],
          optional(:handoff) => handoff()
        }

  @doc """
  The move back to Code Review with the pull request as it is, from Rework: to `code_review_state`,
  with the handoff for `head` (nil for the head the Rework started from). `{:error, why}` outside
  `rework_state`, as Rework is refused from Rework.
  """
  @spec back_to_review(String.t() | nil, String.t(), String.t(), String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def back_to_review(state, rework_state, code_review_state, head) do
    if state == rework_state,
      do: {:ok, %{to: code_review_state, handoff: %{head: head}}},
      else: {:error, "sends the pull request back to review unchanged, but the ticket is in #{state}, not #{rework_state}"}
  end

  @doc "`option` carrying `move`: picking it makes the move."
  @spec option(map(), t()) :: map()
  def option(%{} = option, %{to: to} = move) when is_binary(to), do: Map.put(option, :move, move)

  @doc """
  The move of the one option `answers` pick among the question's options (by number or label, as
  `SymphonyElixir.MergeConfirmation.picked_option/2` reads a pick), or nil when the answers pick
  none, several, or an option that moves nothing.
  """
  @spec picked(map() | nil, [String.t()]) :: t() | nil
  def picked(question, answers) when is_list(answers) do
    options = question |> options() |> List.wrap()

    case MergeConfirmation.picked_option(Enum.map(options, &label/1), answers) do
      nil -> nil
      number -> options |> Enum.at(number - 1) |> move()
    end
  end

  @doc """
  Records the move's finding, verdict and waivers, then moves the ticket `issue_id` of `repo_key` to the move's state
  through the guard (`SymphonyElixir.TransitionGuard.perform/4`, which writes the record first). A
  move to Canceled tries the team's other spelling when the first is not one of its states.
  Answers `{:ok, state}` with the state it moved to, or the guard's error. `opts[:issue_identifier]`
  names the ticket in a refusal's log, and `opts[:tracker]` overrides the tracker.
  """
  @spec perform(String.t() | nil, String.t(), t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def perform(repo_key, issue_id, %{to: to} = move, opts \\ []) do
    record_finding(repo_key, issue_id, Map.get(move, :finding))
    record_verdict(repo_key, issue_id, Map.get(move, :verdict))
    record_waivers(repo_key, issue_id, Map.get(move, :waive))
    handoff = Map.get(move, :handoff)
    emit_handoff(repo_key, issue_id, handoff)
    ctx = %{repo_key: repo_key, issue_identifier: Keyword.get(opts, :issue_identifier)}

    spellings(to)
    |> Enum.reduce_while({:error, :state_not_found}, fn state, _result ->
      case TransitionGuard.perform(issue_id, :director_move, Map.put(ctx, :target, state), Keyword.take(opts, [:tracker])) do
        :ok -> {:halt, {:ok, state}}
        {:error, :state_not_found} = error -> {:cont, error}
        error -> {:halt, error}
      end
    end)
    |> tap(&forget_rework_base(&1, repo_key, issue_id, handoff))
  end

  # The head the question was asked on, else the one the Rework started from; a handoff with no
  # head counts for any head (`Handoff.emitted?/3`), as a tool hook's that could not read one.
  defp emit_handoff(repo_key, issue_id, %{} = handoff) when is_binary(repo_key) do
    head = Map.get(handoff, :head) || rework_base(repo_key, issue_id)
    Handoff.emit(repo_key, issue_id, %{head: head, source: "decision"})
  end

  defp emit_handoff(_repo_key, _issue_id, _none), do: :ok

  defp rework_base(repo_key, issue_id) do
    case RunStore.get_rework_base(repo_key, issue_id) do
      head when is_binary(head) -> head
      _none -> nil
    end
  end

  defp forget_rework_base({:ok, _state}, repo_key, issue_id, %{}) when is_binary(repo_key), do: RunStore.delete_rework_base(repo_key, issue_id)
  defp forget_rework_base(_result, _repo_key, _issue_id, _handoff), do: :ok

  defp record_verdict(repo_key, issue_id, %{kind: kind, outcome: outcome} = verdict),
    do: TicketSignals.record_verdict(repo_key, issue_id, kind, Map.get(verdict, :head_sha), outcome, %{reason: Map.get(verdict, :reason)})

  defp record_verdict(_repo_key, _issue_id, _none), do: :ok

  # Unclassified and unrated until the findings model classifies it, and naming no step, as the
  # Conductor's route to Rework records its finding.
  defp record_finding(repo_key, issue_id, %{description: description, run_id: run_id, run_kind: run_kind}) when is_binary(repo_key) do
    payload = %{class: "unclassified", severity: "unrated", description: String.slice(description, 0, 2_000)}
    TicketSignals.record_event(repo_key, issue_id, "finding.recorded", payload, actor: {:agent, run_id, run_kind}, idempotency: "finding:#{run_id}:decision")
  end

  defp record_finding(_repo_key, _issue_id, _none), do: :ok

  # A check the plan no longer holds is skipped: the move still stands. The move is the person's
  # pick, so it may waive an outcome too.
  defp record_waivers(repo_key, issue_id, [_ | _] = waivers) do
    for %{check_id: check_id, reason: reason} <- waivers do
      with {:error, why} <- TicketChecks.waive(repo_key, issue_id, check_id, reason, by: :person),
           do: Logger.warning("Could not waive check #{check_id} on issue_id=#{issue_id} repo_key=#{repo_key}: #{inspect(why)}")
    end
  end

  defp record_waivers(_repo_key, _issue_id, _none), do: :ok

  defp spellings(to), do: if(to in @canceled_spellings, do: [to | @canceled_spellings -- [to]], else: [to])

  defp options(%{options: options}), do: options
  defp options(_question), do: nil

  defp label(%{label: label}) when is_binary(label), do: label
  defp label(_option), do: ""

  defp move(%{move: %{to: to} = move}) when is_binary(to), do: move
  defp move(_option), do: nil
end
