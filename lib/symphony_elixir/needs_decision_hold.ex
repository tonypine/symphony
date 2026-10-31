defmodule SymphonyElixir.NeedsDecisionHold do
  @moduledoc """
  The Needs Decision hold: a ticket pauses in its phase with the question recorded, and continues in
  place once the decision is made.

  A decision request (`SymphonyElixir.HumanActions.Request`), whoever asks it, is raised through
  the one writer, `SymphonyElixir.DecisionRequest`, and never moves the ticket: the ticket keeps its
  phase, gains the `Needs Decision` machine label, and the hold carries the decision payload — the
  question, its options and what clears it (`attrs/1`).

  The request is answered by the Director (`SymphonyElixir.DirectorMoves`, which answers its
  Question, `SymphonyElixir.Questions`) or withdrawn by the run; either clears the hold and the
  ticket continues from where it stopped. Nothing reads a Linear comment to know a request was
  answered: a reply, or a comment opening with `Decision:`, answers nothing.
  """

  alias SymphonyElixir.HumanActions.Request

  @typedoc "What the ticket's open decision requests call for: set the hold, clear it, or leave it."
  @type action :: {:set, map()} | :clear | :none

  @doc """
  The action the ticket's open decision requests call for, given the Needs Decision hold it already
  has (or nil): `{:set, attrs}` when a request is open and the hold does not already carry it,
  `:clear` when the hold's request is answered or withdrawn, else `:none`.
  """
  @spec desired(Request.t() | nil, map() | nil) :: action()
  def desired(nil, %{kind: :needs_decision}), do: :clear
  def desired(nil, _current_hold), do: :none

  def desired(%{} = request, current_hold) do
    if same_decision?(current_hold, request), do: :none, else: {:set, attrs(request)}
  end

  @doc """
  The hold payload a decision request records: the question as the reason, the options with the
  protected paths each unlocks (`SymphonyElixir.PathUnlock`), and when the decision is recorded as
  what clears it. The request is a parsed one
  (`SymphonyElixir.HumanActions.Request`) or the tool's own request before Linear reads it back,
  which has no `created_at` yet.
  """
  @spec attrs(Request.t() | map()) :: map()
  def attrs(request) do
    %{
      reason: request.question || request.title,
      clearing_condition: "when the decision is recorded",
      decision: %{
        title: request.title,
        question: request.question,
        why: request.why,
        options: request.options,
        unlocks: Request.option_unlocks(request),
        asked_at: Map.get(request, :created_at)
      }
    }
  end

  defp same_decision?(%{kind: :needs_decision, decision: %{} = decision}, request) do
    decision[:title] == request.title and decision[:question] == request.question
  end

  defp same_decision?(_current_hold, _request), do: false
end
