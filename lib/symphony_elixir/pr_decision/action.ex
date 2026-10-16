defmodule SymphonyElixir.PrDecision.Action do
  @moduledoc """
  What the PR and CI watcher does for a ticket, as `SymphonyElixir.PrDecision.decide/1` returns it:
  the rule that chose it, the kind of action, its arguments and the reason recorded on the ticket.

  An action that leaves the ticket waiting (`wait`, `wait_for_competitors`, `file_fix_ticket`,
  `decision`) names who the wait is on (`owner`) and what ends it (`clears_when`). The constructors
  refuse one without both, so no ticket can wait without a reason anybody can act on.
  """

  @kinds [
    :wait,
    :rerun_failed,
    :ci_fix,
    :return_to_origin,
    :dispatch,
    :to_code_review,
    :to_in_progress,
    :to_rework,
    :update_branch,
    :merge_now,
    :arm,
    :disarm,
    :land_agent,
    :close_out,
    :decision,
    :file_fix_ticket,
    :wait_for_competitors
  ]
  @waiting_kinds [:wait, :wait_for_competitors, :file_fix_ticket, :decision]
  @owners [:agent, :ci, :github, :person, :symphony]

  @type kind ::
          :wait
          | :rerun_failed
          | :ci_fix
          | :return_to_origin
          | :dispatch
          | :to_code_review
          | :to_in_progress
          | :to_rework
          | :update_branch
          | :merge_now
          | :arm
          | :disarm
          | :land_agent
          | :close_out
          | :decision
          | :file_fix_ticket
          | :wait_for_competitors

  @typedoc "Who a wait is on: the agent's run, CI, GitHub, a person, or Symphony itself."
  @type owner :: :agent | :ci | :github | :person | :symphony

  @type t :: %__MODULE__{
          rule: String.t(),
          kind: kind(),
          args: map(),
          reason: String.t(),
          owner: owner() | nil,
          clears_when: String.t() | nil
        }

  @enforce_keys [:rule, :kind, :reason]
  defstruct rule: nil, kind: nil, args: %{}, reason: nil, owner: nil, clears_when: nil

  @doc "Every kind of action."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The kinds that leave the ticket waiting, so they name an owner and a clearing condition."
  @spec waiting_kinds() :: [kind()]
  def waiting_kinds, do: @waiting_kinds

  @doc "Every owner a wait can name."
  @spec owners() :: [owner()]
  def owners, do: @owners

  @doc "Whether `action` leaves the ticket waiting."
  @spec waiting?(t()) :: boolean()
  def waiting?(%__MODULE__{kind: kind}), do: kind in @waiting_kinds

  @doc """
  Builds an action from `fields` (`args`, `reason`, `owner`, `clears_when`). Refuses an unknown
  kind, a missing reason, and a waiting kind without an owner or a clearing condition.
  """
  @spec new(String.t(), kind(), keyword()) :: {:ok, t()} | {:error, atom()}
  def new(rule, kind, fields) when is_binary(rule) and is_list(fields) do
    action = %__MODULE__{
      rule: rule,
      kind: kind,
      args: Keyword.get(fields, :args, %{}),
      reason: Keyword.get(fields, :reason),
      owner: Keyword.get(fields, :owner),
      clears_when: Keyword.get(fields, :clears_when)
    }

    cond do
      kind not in @kinds -> {:error, :unknown_kind}
      not filled?(action.reason) -> {:error, :reason_required}
      waiting?(action) and not (action.owner in @owners and filled?(action.clears_when)) -> {:error, :wait_needs_owner_and_clears_when}
      true -> {:ok, action}
    end
  end

  @doc "Like `new/3`, raising `ArgumentError` when it refuses."
  @spec new!(String.t(), kind(), keyword()) :: t()
  def new!(rule, kind, fields) do
    case new(rule, kind, fields) do
      {:ok, action} -> action
      {:error, error} -> raise ArgumentError, "#{rule}: cannot build a #{inspect(kind)} action (#{error})"
    end
  end

  defp filled?(text), do: is_binary(text) and String.trim(text) != ""
end
