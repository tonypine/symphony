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
  (an hour) the ticket is paused (`SymphonyElixir.Pauses`, the one writer) on an `:environment`
  reason (`reason/1`, set by `pause/3`): "Waiting for CI on <commit> to finish", which the Director
  may release with `Unblock`. The log line (`describe/3`) names the commit, the time waited and the
  workflows still running. The wait's own `ci_wait` signal (`signal/0`) makes the next wait on that
  commit start again from zero. A wait on another commit starts from zero too, and so does the wait
  for the epic review's rerun of a red commit (`SymphonyElixir.EpicReview.CiRerun` records a fresh
  start when it reruns). The reason clears (`clear_pause/3`) when the epic review finds no workflow
  run on its commit still going, and on `Unblock`.
  """

  alias SymphonyElixir.{Pauses, TicketState}

  @signal "ci_wait"
  @start_signal "ci_wait_started"
  @limit_ms 60 * 60_000
  @setter %{kind: :rule, name: "CI wait"}
  @condition_prefix "ci_wait:"
  # A live reason's condition, `ci_wait:<commit>`; a backfilled one's is the hold's reason, which
  # starts with `ci_wait: ` (`SymphonyElixir.Pauses.Backfill`).
  @condition ~r/\Aci_wait:[0-9a-f]+\z/

  @typedoc """
  What the run found: the commit and its workflow runs still going, and optionally which run waits
  (`run`, "the epic review" when absent).
  """
  @type info :: %{required(:sha) => String.t(), required(:runs) => [map()], optional(:run) => String.t()}

  @doc "The name of the signal recorded when a wait past the limit pauses the ticket."
  @spec signal() :: String.t()
  def signal, do: @signal

  @doc "The signal recorded when a wait on a commit starts."
  @spec start_signal() :: String.t()
  def start_signal, do: @start_signal

  @doc "How long the review waits for CI on one commit before the ticket is paused."
  @spec limit_ms() :: pos_integer()
  def limit_ms, do: @limit_ms

  @doc """
  When the wait for CI on `sha` started, read from the ticket's `signals` (newest first), or nil
  when no wait on `sha` is underway: none was recorded, the newest was on another commit, or a wait
  past the limit paused the ticket after it.
  """
  @spec since([TicketState.signal()], String.t()) :: DateTime.t() | nil
  def since(signals, sha) when is_list(signals) do
    case Enum.find(signals, &(&1.name in [@start_signal, @signal])) do
      %{name: @start_signal, details: %{sha: ^sha}, at: %DateTime{} = at} -> at
      _other -> nil
    end
  end

  @doc "Whether a wait that started at `since` has reached the limit at `now`."
  @spec over?(DateTime.t(), DateTime.t()) :: boolean()
  def over?(%DateTime{} = since, %DateTime{} = now), do: DateTime.diff(now, since, :millisecond) >= @limit_ms

  @doc """
  What a wait past the limit says in the log: the commit, when the wait started, how long it lasted
  and the workflows still running.
  """
  @spec describe(info(), DateTime.t(), DateTime.t()) :: String.t()
  def describe(%{sha: sha, runs: runs} = info, %DateTime{} = since, %DateTime{} = now) do
    "#{@signal}: CI on #{String.slice(sha, 0, 12)} was still running after #{minutes(since, now)} " <>
      "(waiting since #{Calendar.strftime(since, "%H:%M UTC")}), so Symphony stopped starting #{Map.get(info, :run, "the epic review")}. " <>
      "Still running: #{Enum.map_join(runs, ", ", &run_label/1)}"
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

  @doc """
  The pause reason of a wait for CI on `sha` past the limit: an `:environment` reason the Director
  may release, `Waiting for CI on <first 12 characters of sha> to finish`.
  """
  @spec reason(String.t()) :: Pauses.reason_input()
  def reason(sha) when is_binary(sha) do
    short = String.slice(sha, 0, 12)
    %{kind: :environment, waits_on: %{condition: @condition_prefix <> short}, text: "Waiting for CI on #{short} to finish", releasable: true}
  end

  @doc "Whether a pause reason is a live CI-wait reason (`reason/1`)."
  @spec reason?(Pauses.reason() | term()) :: boolean()
  def reason?(%{kind: :environment, waits_on: %{condition: condition}}) when is_binary(condition), do: condition =~ @condition
  def reason?(_reason), do: false

  @doc "Pauses the ticket on the wait for CI on `sha`, set by the CI-wait rule."
  @spec pause(String.t(), String.t(), String.t()) :: Pauses.result()
  def pause(repo_key, issue_id, sha), do: Pauses.set({:ticket, repo_key, issue_id}, reason(sha), set_by: @setter)

  @doc """
  Clears every CI-wait reason of the ticket's pause, live or backfilled from a CI-wait hold, by `by`
  (default Symphony): CI settled, or the Director unblocked it. Any other reason stays. Best-effort:
  a ticket that can't be read clears nothing.
  """
  @spec clear_pause(String.t() | nil, String.t(), Pauses.set_by() | nil) :: :ok
  def clear_pause(repo_key, issue_id, by \\ nil) do
    if repo_key, do: Pauses.clear_reasons({:ticket, repo_key, issue_id}, &ci_wait_reason?/1, clear_opts(by))
    :ok
  end

  defp clear_opts(nil), do: []
  defp clear_opts(by), do: [by: by]

  defp ci_wait_reason?(%{kind: :environment, waits_on: %{condition: @condition_prefix <> _rest}}), do: true
  defp ci_wait_reason?(_reason), do: false
end
