defmodule SymphonyElixir.StartNow do
  @moduledoc """
  Start now: whether a ticket's run may be started at once (`POST /api/v1/control/start`,
  `SymphonyElixir.Orchestrator.start_issue/3`), and why not. One answer for the endpoint and the
  ticket payloads: the endpoint refuses with `check/1`'s reason, and each ticket of the state
  payload and each ticket payload carries `start: {allowed, reason}` (`payload/1`) computed from
  the same facts, so the Director's Start now button is never clickable into a refusal — its
  tooltip shows the reason instead.

  The refusals, in the order they answer with: a ticket in Backlog ("move it first"), a closed
  ticket, one whose plan waits on a person (`Plan Review`), one waiting on its sub-tickets,
  Symphony's pause, the repository's pause, an open Question, and a run already working on the
  ticket. A pause answers with the line the passes that skip candidates already name it by
  (`SymphonyElixir.Pauses.dispatch_skip_reason/1`, `repository_skip_reason/1`).
  """

  alias SymphonyElixir.{Config, Orchestrator}

  @typedoc """
  The facts a start is judged on: the ticket's phase, the lines of the pauses that stop it (nil
  when each has none), whether a Question is waiting for an answer, and whether a run is already
  working on the ticket.
  """
  @type facts :: %{
          phase: String.t() | nil,
          symphony_pause: String.t() | nil,
          repository_pause: String.t() | nil,
          open_question?: boolean(),
          running?: boolean()
        }

  @doc """
  Whether the ticket may be started at once: `:ok`, or the refusal's reason in the words the
  endpoint answers with and the tooltip shows.
  """
  @spec check(facts()) :: :ok | {:error, String.t()}
  def check(%{} = facts) do
    case phase_refusal(Map.get(facts, :phase), Config.settings!()) do
      {:error, reason} -> {:error, reason}
      :ok -> fact_refusal(facts)
    end
  end

  # Where the ticket stands: a phase a start cannot answer for. `nil` is a ticket the payload
  # found no record of; the rest refuse in the phase's own words.
  defp phase_refusal(nil, _settings), do: {:error, "the ticket is not one Symphony tracks"}

  defp phase_refusal(phase, %Config.Schema{} = settings) do
    normalized = normalize(phase)
    tracker = settings.tracker

    cond do
      normalized == "backlog" -> {:error, "the ticket is in Backlog; move it first"}
      MapSet.member?(Orchestrator.terminal_state_set(settings), normalized) -> {:error, "the ticket is #{phase}; only an open ticket can be started"}
      same_phase?(normalized, tracker.plan_review_state) -> {:error, "the ticket's plan waits on a person"}
      same_phase?(normalized, tracker.waiting_on_sub_issues_state) -> {:error, "the ticket waits on its sub-tickets"}
      true -> :ok
    end
  end

  # What holds the ticket itself: the pauses, then the Question, then a run already on it.
  defp fact_refusal(%{symphony_pause: pause}) when is_binary(pause), do: {:error, pause}
  defp fact_refusal(%{repository_pause: pause}) when is_binary(pause), do: {:error, pause}
  defp fact_refusal(%{open_question?: true}), do: {:error, "a Question is waiting for an answer"}
  defp fact_refusal(%{running?: true}), do: {:error, "a run is already working on the ticket"}
  defp fact_refusal(_facts), do: :ok

  @doc """
  The `start` field each ticket of the state payload and each ticket payload carry: whether Start
  now is allowed and, when it is not, `check/1`'s reason.
  """
  @spec payload(facts()) :: %{allowed: boolean(), reason: String.t() | nil}
  def payload(%{} = facts) do
    case check(facts) do
      :ok -> %{allowed: true, reason: nil}
      {:error, reason} -> %{allowed: false, reason: reason}
    end
  end

  # `nil` (a phase the payload found no record of) never equals a name, so only binaries are
  # normalized; `phase_refusal(nil, ...)` answers for a missing phase before the names are
  # compared.
  defp normalize(phase), do: is_binary(phase) and phase |> String.trim() |> String.downcase()

  # `nil` (a phase the payload found no record of) never equals a name, so the names are compared
  # as binaries only; `phase_refusal(nil, ...)` answers for a missing phase before here.
  defp same_phase?(normalized, name), do: is_binary(name) and normalize(name) == normalized
end
