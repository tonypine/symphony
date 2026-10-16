defmodule SymphonyElixir.CiWait do
  @moduledoc """
  The bound on an epic review's wait for CI on the commit it reviews, and on a QA pass's wait for the
  named checks its walkthrough steps rely on.

  An epic review that finds a workflow run on its commit still going ends with `{:ci_pending, info}`
  (`SymphonyElixir.EpicReview`), and so does a QA pass whose pre-check finds a named check still
  running on the PR head (`SymphonyElixir.QaVerification`); the orchestrator starts it again a minute
  later. Those runs
  are not dispatch-loop runs (`SymphonyElixir.DispatchLoop`): nothing went wrong, CI is still
  running. The wait is bounded here instead, per commit, in the ticket's store record: the first
  wait on a commit records a `ci_wait_started` signal, and once the wait has lasted `limit_ms/0`
  (an hour) the ticket is put on a `Blocked` hold whose reason (`hold_attrs/3`) names the commit,
  the time waited and the workflows still running. A person lifts it with `Unblock`;
  the hold's own `ci_wait` signal makes the next wait on that commit start again from zero. A wait
  on another commit starts from zero too.
  """

  alias SymphonyElixir.TicketState

  @hold_type "ci_wait"
  @start_signal "ci_wait_started"
  @limit_ms 60 * 60_000

  @typedoc """
  What the run found: the commit and its workflow runs still going, and optionally which run waits
  (`run`, "the epic review" when absent).
  """
  @type info :: %{required(:sha) => String.t(), required(:runs) => [map()], optional(:run) => String.t()}

  @doc "The `waits_on` type of a CI-wait hold, and the name of the signal recorded when it is set."
  @spec hold_type() :: String.t()
  def hold_type, do: @hold_type

  @doc "The signal recorded when a wait on a commit starts."
  @spec start_signal() :: String.t()
  def start_signal, do: @start_signal

  @doc "How long the review waits for CI on one commit before the ticket is held."
  @spec limit_ms() :: pos_integer()
  def limit_ms, do: @limit_ms

  @doc """
  When the wait for CI on `sha` started, read from the ticket's `signals` (newest first), or nil
  when no wait on `sha` is underway: none was recorded, the newest was on another commit, or a CI-wait
  hold was set after it.
  """
  @spec since([TicketState.signal()], String.t()) :: DateTime.t() | nil
  def since(signals, sha) when is_list(signals) do
    case Enum.find(signals, &(&1.name in [@start_signal, @hold_type])) do
      %{name: @start_signal, details: %{sha: ^sha}, at: %DateTime{} = at} -> at
      _other -> nil
    end
  end

  @doc "Whether a wait that started at `since` has reached the limit at `now`."
  @spec over?(DateTime.t(), DateTime.t()) :: boolean()
  def over?(%DateTime{} = since, %DateTime{} = now), do: DateTime.diff(now, since, :millisecond) >= @limit_ms

  @doc """
  The `Blocked` hold a wait past the limit sets: a reason naming the commit, when the wait started,
  how long it lasted and the workflows still running, lifted by a person's `Unblock`.
  """
  @spec hold_attrs(info(), DateTime.t(), DateTime.t()) :: map()
  def hold_attrs(%{sha: sha, runs: runs} = info, %DateTime{} = since, %DateTime{} = now) do
    %{
      reason:
        "#{@hold_type}: CI on #{String.slice(sha, 0, 12)} was still running after #{minutes(since, now)} " <>
          "(waiting since #{Calendar.strftime(since, "%H:%M UTC")}), so Symphony stopped starting #{Map.get(info, :run, "the epic review")}. " <>
          "Still running: #{Enum.map_join(runs, ", ", &run_label/1)}",
      clearing_condition: "when a person unblocks it",
      waits_on: %{type: @hold_type, keys: [sha]}
    }
  end

  defp minutes(since, now) do
    case div(DateTime.diff(now, since, :second), 60) do
      1 -> "1 minute"
      count -> "#{count} minutes"
    end
  end

  defp run_label(run) do
    name = Map.get(run, :workflow_name) || "a workflow"

    case Map.get(run, :url) || Map.get(run, :id) do
      nil -> name
      link -> "#{name} (#{link})"
    end
  end
end
