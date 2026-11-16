defmodule SymphonyElixir.StartNow do
  @moduledoc """
  Start now: whether a ticket's run may be started at once (`POST /api/v1/control/start`,
  `SymphonyElixir.Orchestrator.start_issue/3`), and why not. One answer for the endpoint and the
  ticket payloads: the endpoint refuses with `check/1`'s reason, and each ticket of the state
  payload and each ticket payload carries `start: {allowed, reason}`, the `start` of its `moves`
  (`SymphonyElixir.TicketMoves`), computed from the same facts, so the Director's Start now button
  is never clickable into a refusal — its tooltip shows the reason instead.

  The refusals, in the order they answer with: a ticket in Backlog ("move it first"), a closed
  ticket, one whose plan waits on a person (`Plan Review`), one waiting on its sub-tickets,
  Symphony's pause, the repository's pause, an open Question, and a run already working on the
  ticket. A pause answers with the line the passes that skip candidates already name it by
  (`SymphonyElixir.Pauses.dispatch_skip_reason/1`, `repository_skip_reason/1`).

  Start does what the machine decided (`follow/2`): a ticket whose PR watcher decided a CI Fix run
  (a conflict with the base, a red head) gets that run, not its phase's: the watcher reads its PR at
  once and applies the decision, which moves it to CI Fix, and the run started there is the fix. A
  review or QA run never starts on a PR that conflicts with its base.
  """

  alias SymphonyElixir.{CiFix, Config, Orchestrator, PrWatch, TicketMoves}
  alias SymphonyElixir.Linear.Issue

  @not_sent "Its PR needs a CI Fix run first, and Symphony could not send it to CI Fix yet; try again in a moment."

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

  @doc "The refusal of a start of a ticket in no repository, which only the orchestrator's dispatch finds out."
  @spec no_repository_reason() :: String.t()
  def no_repository_reason, do: "The ticket has no repository; it can't be started."

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

  @doc """
  The ticket to start, once the PR watcher's decision on it is followed (see the moduledoc): `issue`
  as it is when the decision is its phase's own run, the ticket read again in CI Fix when the watcher
  decided a fix and applied it on Check Now, or the refusal: a fix the watcher could not apply, or a
  review or QA run on a PR that conflicts with its base. `opts`: `:watch` (the watcher's record of an
  issue id), `:check` (Check Now by identifier), `:fetch` (the issue by identifier), `:settings`.
  """
  @spec follow(Issue.t(), keyword()) :: {:ok, Issue.t()} | {:error, {:start_refused, String.t()}} | {:error, term()}
  def follow(%Issue{} = issue, opts \\ []) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)
    watch = Keyword.get(opts, :watch, &PrWatch.watch/1).(issue.id)

    cond do
      CiFix.in_state?(issue.state, settings) -> {:ok, issue}
      fix_decided?(watch) -> fix_first(issue, settings, opts)
      true -> phase_run(issue, watch, settings)
    end
  end

  defp phase_run(issue, watch, settings) do
    if conflicting_review?(issue.state, watch, settings), do: {:error, {:start_refused, conflict_reason(watch)}}, else: {:ok, issue}
  end

  defp fix_decided?(%{decision: %{kind: :ci_fix}}), do: true
  defp fix_decided?(_watch), do: false

  # The watcher applies its own decision: Check Now reads the PR and moves the ticket to CI Fix. Read
  # again, a ticket the watcher no longer sends there (someone resolved the conflict) starts its phase's
  # run, unless its PR still conflicts.
  defp fix_first(issue, settings, opts) do
    check = Keyword.get(opts, :check, &PrWatch.check/1)
    fetch = Keyword.fetch!(opts, :fetch)

    with {:ok, record} <- check.(issue.identifier),
         {:ok, %Issue{} = moved} <- fetch.(issue.identifier) do
      watch = SymphonyElixir.TicketState.pr_watch(record)

      cond do
        CiFix.in_state?(moved.state, settings) -> {:ok, moved}
        fix_decided?(watch) -> {:error, {:start_refused, @not_sent}}
        true -> phase_run(moved, watch, settings)
      end
    else
      _failed -> {:error, {:start_refused, @not_sent}}
    end
  end

  defp conflicting_review?(state, %{facts: %{mergeable: :dirty}}, settings) when is_binary(state) do
    tracker = settings.tracker
    Enum.any?([tracker.code_review_state, tracker.qa_state], &same_phase?(normalize(state), &1))
  end

  defp conflicting_review?(_state, _watch, _settings), do: false

  defp conflict_reason(%{facts: %{pr_number: number}}) when is_integer(number), do: "PR ##{number} conflicts with its base: a conflict fix runs first, never a review on it."
  defp conflict_reason(_watch), do: "Its PR conflicts with its base: a conflict fix runs first, never a review on it."

  # Where the ticket stands: a phase a start cannot answer for. `nil` is a ticket the payload
  # found no record of; the rest refuse in the phase's own words.
  defp phase_refusal(nil, _settings), do: {:error, "The ticket is not one Symphony tracks."}

  defp phase_refusal(phase, %Config.Schema{} = settings) do
    normalized = normalize(phase)
    tracker = settings.tracker

    cond do
      normalized == "backlog" -> {:error, "The ticket is in Backlog; move it to Todo with Move to… first."}
      MapSet.member?(Orchestrator.terminal_state_set(settings), normalized) -> {:error, TicketMoves.closed_reason(phase)}
      same_phase?(normalized, tracker.plan_review_state) -> {:error, "The ticket's plan waits on a person."}
      same_phase?(normalized, tracker.waiting_on_sub_issues_state) -> {:error, "The ticket waits on its sub-tickets."}
      true -> :ok
    end
  end

  # What holds the ticket itself: the pauses, then the Question, then a run already on it.
  defp fact_refusal(%{symphony_pause: pause}) when is_binary(pause), do: {:error, pause}
  defp fact_refusal(%{repository_pause: pause}) when is_binary(pause), do: {:error, pause}
  defp fact_refusal(%{open_question?: true}), do: {:error, "It waits on your answer first."}
  defp fact_refusal(%{running?: true}), do: {:error, "A run is already working on it."}
  defp fact_refusal(_facts), do: :ok

  # `nil` (a phase the payload found no record of) never equals a name, so only binaries are
  # normalized; `phase_refusal(nil, ...)` answers for a missing phase before the names are
  # compared.
  defp normalize(phase), do: is_binary(phase) and phase |> String.trim() |> String.downcase()

  # `nil` (a phase the payload found no record of) never equals a name, so the names are compared
  # as binaries only; `phase_refusal(nil, ...)` answers for a missing phase before here.
  defp same_phase?(normalized, name), do: is_binary(name) and normalize(name) == normalized
end
