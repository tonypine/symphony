defmodule SymphonyElixir.CiWait do
  @moduledoc """
  The bound on an epic review's wait for CI on the commit it reviews, and on a QA pass's wait for the
  named checks its walkthrough steps rely on.

  An epic review that finds a workflow run on its commit still going ends with `{:ci_pending, info}`
  (`SymphonyElixir.EpicReview`), and so does a QA pass whose pre-check finds a named check still
  running on the PR head (`SymphonyElixir.QaVerification`) and a CI Fix run whose idle turn finds
  checks still running on the PR head (`SymphonyElixir.AgentRunner`); the orchestrator starts it
  again a minute later, unless the PR and CI watcher's wait holds a CI Fix run back. Those runs
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

  A paused ticket is not dispatched, so no review runs to find CI settled: the completion of CI on
  the commit lifts the reason itself (`finished/2`, TP-1376). A `workflow_run` or `check_suite`
  delivery that completed on the commit (`SymphonyElixir.PrWatch.Ingest`), or the release-build
  watch's read of a finished run on it (`SymphonyElixir.ReleaseBuild`), whichever comes first, clears
  the reason of every ticket whose pause names that commit, success or failure alike. The cleared
  pause frees the ticket and the orchestrator dispatches it at once, as after `Unblock`: the review
  then judges CI as it always does, a red run through its rerun-then-gap path, and a workflow still
  going on the commit through a fresh wait. A completion on another commit changes nothing.
  """

  require Logger

  alias SymphonyElixir.{Pauses, TicketState}
  alias SymphonyElixir.EpicReview.MainCi

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

  def finished(sha, opts \\ [])

  @doc """
  CI on commit `sha` completed (success or failure): clears the CI-wait reason naming that commit
  from every ticket's pause in the store, by the CI-wait rule, and returns the ids of the tickets it
  lifted. Tickets waiting on another commit, and reasons backfilled from holds (which name no
  commit), stay. An epic's wait before dispatch (`SymphonyElixir.EpicReview.MainCi`) lifts only once
  no workflow run on the commit is still going (`MainCi.settled?/3`). `opts`: `:run_store` (default
  `SymphonyElixir.RunStore`), `:pauses` (default `SymphonyElixir.Pauses`), `:main_ci` (default
  `SymphonyElixir.EpicReview.MainCi`) and those of `MainCi.settled?/3`.
  """
  @spec finished(String.t() | nil, keyword()) :: [String.t()]
  def finished(sha, opts) when is_binary(sha) and sha != "" do
    sha = String.downcase(sha)

    for %{issue_id: issue_id, repo_key: repo_key} = record <- ticket_records(opts),
        is_binary(issue_id) and is_binary(repo_key),
        reasons <- [Enum.filter(TicketState.pause_reasons(record), &names?(&1, sha))],
        reasons != [],
        settled?(reasons, sha, repo_key, opts),
        lifted?(Keyword.get(opts, :pauses, Pauses), repo_key, issue_id, sha) do
      Logger.info("CI on #{String.slice(sha, 0, 12)} finished; lifted the CI wait of issue_id=#{issue_id} issue_identifier=#{record.issue_identifier}")
      issue_id
    end
  end

  def finished(_sha, _opts), do: []

  # An epic waiting before dispatch for CI on the base branch (`SymphonyElixir.EpicReview.MainCi`)
  # waits for every workflow run on the commit, so one run finishing among several lifts nothing
  # while another is still going; the completion of the last one does.
  defp settled?(reasons, sha, repo_key, opts) do
    not Enum.any?(reasons, &main_ci_reason?/1) or Keyword.get(opts, :main_ci, MainCi).settled?(sha, repo_key, opts)
  end

  defp main_ci_reason?(%{waits_on: %{head: head}}), do: is_binary(head)
  defp main_ci_reason?(_reason), do: false

  defp ticket_records(opts) do
    case Keyword.get(opts, :run_store, SymphonyElixir.RunStore).list_all_ticket_states() do
      records when is_list(records) -> Enum.map(records, &TicketState.normalize/1)
      _error -> []
    end
  end

  defp names?(%{kind: :environment, waits_on: %{condition: @condition_prefix <> short = condition}}, sha) when short != "",
    do: condition =~ @condition and String.starts_with?(sha, short)

  defp names?(_reason, _sha), do: false

  defp lifted?(pauses, repo_key, issue_id, sha) do
    case pauses.clear_reasons({:ticket, repo_key, issue_id}, &names?(&1, sha), by: @setter) do
      {:ok, _pause} ->
        true

      {:error, reason} ->
        Logger.warning("CI on #{String.slice(sha, 0, 12)} finished but the CI wait of issue_id=#{issue_id} could not be lifted: #{inspect(reason)}")
        false
    end
  end

  defp clear_opts(nil), do: []
  defp clear_opts(by), do: [by: by]

  defp ci_wait_reason?(%{kind: :environment, waits_on: %{condition: @condition_prefix <> _rest}}), do: true
  defp ci_wait_reason?(_reason), do: false
end
