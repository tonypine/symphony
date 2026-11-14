defmodule SymphonyElixir.QaBuildHold do
  @moduledoc """
  Holds a QA ticket's dispatch on the app built for its head (`SymphonyElixir.QaBuild`), as the
  review flow holds it while CI runs: QA runs only on an app Symphony built.

  `resolve/4` runs in the orchestrator's dispatch pass for each ticket in the QA phase that is not
  running, with the head the PR watcher recorded for it. It acts on the build's record alone:

    * `:ready` -> QA dispatches;
    * no record -> the build is asked for and the ticket is held; `:building` -> held. The hold is
      one `:build` reason on the ticket's pause (`waits_on: %{commit: sha}`), set by the rule "QA
      build hold", which a ticket read says as "Waiting for a build" (`SymphonyElixir.Situation`).
      The builder clears it when the build ends, whatever the outcome (`release/3`); the pause's
      change runs a dispatch cycle at once, so nothing waits on a timer;
    * `:failed` -> the ticket goes to `Rework` without an agent, each time it arrives in QA on the
      tree (its files did not change, so the build can't pass), with the build command and the end
      of its output on its QA report (`SymphonyElixir.QaVerification.build_failed/4`). One arrival
      makes one move (`SymphonyElixir.QaBuild.mark_reworked/5`, keyed by when the ticket entered
      QA), and the ticket stays held until it has left QA;
    * `:unavailable` -> the ticket stays held, on an `:environment` reason the Director may release
      (`waits_on: %{condition: "qa_build:<sha>"}`), that reads "The QA build could not run:
      <reason>". Nothing asks for the build again on a timer: a new head does, Symphony's start
      does, and a person who lifts the hold with Unblock does (`lifted/4`, which asks the builder
      again before the reason goes).
    * a repository with nothing to build (no `macos_app` `build` and `app`, or no `worker_host`), or
      no builder -> QA dispatches as it does without the pre-build.

  A reason left for another commit or another outcome (the head moved, the build ended) is
  replaced, and the pass clears the hold of a ticket that left QA (`release/3`). The hold only stops
  dispatch: it is never an error and never a retry.
  """

  require Logger

  alias SymphonyElixir.{Config, Pauses, QaBuild, QaVerification, RunStore}
  alias SymphonyElixir.Linear.Issue

  @setter %{kind: :rule, name: "QA build hold"}
  @condition_prefix "qa_build:"
  @max_text 300

  @doc """
  Brings the hold of `repo_key`'s QA ticket `issue` in line with the build of `head`, and says what
  dispatch does with it: `:dispatch` or `:held`.

  Options: `:builder` (default `SymphonyElixir.QaBuild`), `:rework` (`repo_key, issue, head, record
  -> :ok | {:error, term}`, default `SymphonyElixir.QaVerification.build_failed/4` with the
  repository's settings), `:start_task` (`fun -> {:ok, pid} | term`, default a
  `SymphonyElixir.TaskSupervisor` task) and `:arrival` (`issue_id -> term`, when the ticket entered
  its phase, default the `phase_at` of its record).
  """
  @spec resolve(String.t(), Issue.t(), String.t() | nil, keyword()) :: :dispatch | :held
  def resolve(repo_key, %Issue{id: issue_id} = issue, head, opts \\ []) when is_binary(repo_key) and is_binary(issue_id) do
    builder = Keyword.get(opts, :builder, QaBuild)

    if is_binary(head) and is_binary(issue.identifier) and builder.builds?(repo_key) do
      act(builder.lookup(repo_key, head), repo_key, issue, head, builder, opts)
    else
      release(repo_key, issue_id, issue.identifier)
      :dispatch
    end
  end

  defp act(%{status: :ready}, repo_key, issue, _head, _builder, _opts) do
    release(repo_key, issue.id, issue.identifier)
    :dispatch
  end

  defp act(%{status: :failed} = record, repo_key, issue, head, builder, opts) do
    arrival = Keyword.get(opts, :arrival, &arrival/1).(issue.id)
    hold(repo_key, issue, head, failed_reason(head))
    if builder.mark_reworked(repo_key, record.tree, issue.id, arrival) == :ok, do: send_back(repo_key, issue, head, record, opts)
    :held
  end

  defp act(%{status: :unavailable} = record, repo_key, issue, head, _builder, _opts) do
    hold(repo_key, issue, head, unavailable_reason(head, record.reason))
    :held
  end

  # Asked for again while it builds too: after a restart the builder learns who waits from this.
  defp act(_none_or_building, repo_key, issue, head, builder, _opts) do
    hold(repo_key, issue, head, building_reason(head))
    builder.request(repo_key, head, %{identifier: issue.identifier, issue_id: issue.id, held: true})
    :held
  end

  defp building_reason(head), do: %{kind: :build, waits_on: %{commit: head}, text: "Waiting for the QA build of #{short(head)}"}

  defp failed_reason(head),
    do: %{kind: :build, waits_on: %{commit: head}, text: "The app does not build on #{short(head)}: it goes back to Rework"}

  defp unavailable_reason(head, reason) do
    text = String.slice("The QA build could not run: #{reason}", 0, @max_text)
    %{kind: :environment, waits_on: %{condition: @condition_prefix <> head}, text: text, releasable: true}
  end

  defp short(head), do: String.slice(head, 0, 7)

  defp arrival(issue_id) do
    case RunStore.get_ticket_state(issue_id) do
      %{phase_at: phase_at} -> phase_at
      _none -> nil
    end
  end

  # The move writes to Linear, so it runs outside the orchestrator. The hold stays until the ticket
  # has left QA.
  defp send_back(repo_key, issue, head, record, opts) do
    rework = Keyword.get(opts, :rework, &rework/4)
    start_task = Keyword.get(opts, :start_task, &Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, &1))

    move = fn ->
      result = rework.(repo_key, issue, head, record)

      Logger.warning(
        "QA build failed; moving the ticket to Rework issue_id=#{issue.id} issue_identifier=#{issue.identifier} " <>
          "repo_key=#{repo_key} head_sha=#{head} tree=#{record.tree} outcome=#{inspect(result)}"
      )
    end

    with failed when not is_tuple(failed) or elem(failed, 0) != :ok <- start_task.(move) do
      Logger.warning("QA build failed, but the move to Rework could not start issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(failed)}")
    end
  end

  defp rework(repo_key, issue, head, record) do
    with {:ok, settings} <- Config.settings_for_repo(repo_key) do
      QaVerification.build_failed(issue, head, record, settings: settings, repo_key: repo_key)
    end
  end

  # One reason, the one `wanted` names: any other this hold set goes first.
  defp hold(repo_key, %Issue{id: issue_id} = issue, head, wanted) do
    {kept, stale} = repo_key |> reasons(issue_id) |> Enum.split_with(&same?(&1, wanted))
    Enum.each(stale, &Pauses.clear_reason({:ticket, repo_key, issue_id}, &1, by: @setter))

    if kept == [] do
      case Pauses.set({:ticket, repo_key, issue_id}, wanted, set_by: @setter) do
        {:ok, _pause} ->
          Logger.info("Holding QA for its build: issue_id=#{issue_id} issue_identifier=#{issue.identifier} repo_key=#{repo_key} head_sha=#{head} reason=#{inspect(wanted.text)}")

        {:error, error} ->
          Logger.warning("Could not hold QA for its build: issue_id=#{issue_id} issue_identifier=#{issue.identifier} reason=#{inspect(error)}")
      end
    end

    :ok
  end

  defp same?(reason, wanted), do: reason.kind == wanted.kind and reason.waits_on == wanted.waits_on and reason.text == wanted.text

  @doc """
  The Director's Unblock of `repo_key`'s ticket `issue` is about to release `reasons`: each one this
  hold set because the build could not run asks the builder for that build again first
  (`SymphonyElixir.QaBuild.retry/4`), so the dispatch pass the release starts finds it asked for.
  Options: `:builder`.
  """
  @spec lifted(String.t() | nil, map(), [Pauses.reason()], keyword()) :: :ok
  def lifted(repo_key, %{id: issue_id, identifier: identifier}, reasons, opts) when is_binary(repo_key) do
    builder = Keyword.get(opts, :builder, QaBuild)
    for head <- Enum.map(reasons, &unavailable_head/1), is_binary(head), do: builder.retry(repo_key, head, %{identifier: identifier, issue_id: issue_id})
    :ok
  end

  @doc "The commit an `:unavailable` hold of this module waits on, or nil for any other reason."
  @spec unavailable_head(Pauses.reason() | term()) :: String.t() | nil
  def unavailable_head(%{kind: :environment, waits_on: %{condition: @condition_prefix <> head}, set_by: @setter}), do: head
  def unavailable_head(_reason), do: nil

  @doc "Clears every reason this hold set on the pause of `repo_key`'s ticket `issue_id`."
  @spec release(String.t() | nil, String.t() | nil, String.t() | nil) :: :ok
  def release(repo_key, issue_id, identifier) do
    case reasons(repo_key, issue_id) do
      [] ->
        :ok

      held ->
        Enum.each(held, &Pauses.clear_reason({:ticket, repo_key, issue_id}, &1, by: @setter))
        Logger.info("Released from the QA build hold: issue_id=#{issue_id} issue_identifier=#{identifier} repo_key=#{repo_key}")
    end
  end

  @doc "Whether a pause reason is one this hold set."
  @spec reason?(Pauses.reason() | term()) :: boolean()
  def reason?(%{kind: :build, waits_on: %{commit: commit}, set_by: @setter}) when is_binary(commit), do: true
  def reason?(reason), do: unavailable_head(reason) != nil

  @doc "The reasons this hold set on the pause of `repo_key`'s ticket `issue_id`."
  @spec reasons(String.t() | nil, String.t() | nil) :: [Pauses.reason()]
  def reasons(repo_key, issue_id) when is_binary(repo_key) and is_binary(issue_id) do
    case Pauses.get({:ticket, repo_key, issue_id}) do
      {:ok, %{reasons: reasons}} -> Enum.filter(reasons, &reason?/1)
      _none -> []
    end
  end

  def reasons(_repo_key, _issue_id), do: []

  @doc "The lines of `reasons` (`reasons/2`), as a person reads them."
  @spec lines([Pauses.reason()]) :: [String.t()]
  def lines(reasons), do: Enum.map(reasons, & &1.text)
end
