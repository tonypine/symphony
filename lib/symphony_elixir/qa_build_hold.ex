defmodule SymphonyElixir.QaBuildHold do
  @moduledoc """
  Holds a QA ticket's dispatch while the app for its head is being built
  (`SymphonyElixir.QaBuild`), as the review flow holds it while CI runs.

  `resolve/4` runs in the orchestrator's dispatch pass for each ticket in the QA phase that is not
  running, with the head the PR watcher recorded for it. It acts on the build's record alone:

    * `:ready` -> QA dispatches;
    * no record -> the build is asked for and the ticket is held; `:building` -> held. The hold is
      one `:build` reason on the ticket's pause (`waits_on: %{commit: sha}`), set by the rule "QA
      build hold", which a ticket read says as "Waiting for a build" (`SymphonyElixir.Situation`).
      The builder clears it when the build ends, whatever the outcome (`release/3`); the pause's
      change runs a dispatch cycle at once, so nothing waits on a timer;
    * `:failed` -> the ticket goes to `Rework` without an agent, once for a tree, with the build
      command and the end of its output on its QA report
      (`SymphonyElixir.QaVerification.build_failed/4`). It stays held while the move is made. A
      ticket back in QA on a tree it was already sent back for dispatches QA;
    * `:unavailable`, a repository with nothing to build, or no builder -> QA dispatches as it
      does without the pre-build, and the QA driver reports an unusable QA host itself.

  A reason left for another commit (the head moved while it was held) is cleared, and the pass
  clears the hold of a ticket that left QA (`release/3`). The hold only stops dispatch: it is never
  an error and never a retry.
  """

  require Logger

  alias SymphonyElixir.{Config, Pauses, QaBuild, QaVerification}
  alias SymphonyElixir.Linear.Issue

  @setter %{kind: :rule, name: "QA build hold"}

  @doc """
  Brings the hold of `repo_key`'s QA ticket `issue` in line with the build of `head`, and says what
  dispatch does with it: `:dispatch` or `:held`.

  Options: `:builder` (default `SymphonyElixir.QaBuild`), `:rework` (`repo_key, issue, head, record
  -> :ok | {:error, term}`, default `SymphonyElixir.QaVerification.build_failed/4` with the
  repository's settings) and `:start_task` (`fun -> {:ok, pid} | term`, default a
  `SymphonyElixir.TaskSupervisor` task).
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

  defp act(%{status: :failed} = record, repo_key, issue, head, builder, opts) do
    case builder.mark_reworked(repo_key, record.tree, issue.id) do
      :ok ->
        hold(repo_key, issue, head)
        send_back(repo_key, issue, head, record, opts)
        :held

      :already ->
        release(repo_key, issue.id, issue.identifier)
        :dispatch
    end
  end

  defp act(%{status: status}, repo_key, issue, _head, _builder, _opts) when status in [:ready, :unavailable] do
    release(repo_key, issue.id, issue.identifier)
    :dispatch
  end

  # Asked for again while it builds too: after a restart the builder learns who waits from this.
  defp act(_none_or_building, repo_key, issue, head, builder, _opts) do
    hold(repo_key, issue, head)
    builder.request(repo_key, head, %{identifier: issue.identifier, issue_id: issue.id, held: true})
    :held
  end

  # The move writes to Linear, so it runs outside the orchestrator; the hold goes when it is done.
  defp send_back(repo_key, issue, head, record, opts) do
    rework = Keyword.get(opts, :rework, &rework/4)
    start_task = Keyword.get(opts, :start_task, &Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, &1))

    move = fn ->
      result = rework.(repo_key, issue, head, record)

      Logger.warning(
        "QA build failed; moving the ticket to Rework issue_id=#{issue.id} issue_identifier=#{issue.identifier} " <>
          "repo_key=#{repo_key} head_sha=#{head} tree=#{record.tree} outcome=#{inspect(result)}"
      )

      release(repo_key, issue.id, issue.identifier)
    end

    case start_task.(move) do
      {:ok, _pid} ->
        :ok

      failed ->
        Logger.warning("QA build failed, but the move to Rework could not start issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(failed)}")
        release(repo_key, issue.id, issue.identifier)
    end
  end

  defp rework(repo_key, issue, head, record) do
    with {:ok, settings} <- Config.settings_for_repo(repo_key) do
      QaVerification.build_failed(issue, head, record, settings: settings, repo_key: repo_key)
    end
  end

  # One reason, for this head: a reason for another commit goes first.
  defp hold(repo_key, %Issue{id: issue_id} = issue, head) do
    {kept, stale} = repo_key |> reasons(issue_id) |> Enum.split_with(&(&1.waits_on.commit == head))
    Enum.each(stale, &Pauses.clear_reason({:ticket, repo_key, issue_id}, &1, by: @setter))

    if kept == [] do
      reason = %{kind: :build, waits_on: %{commit: head}, text: "Waiting for the QA build of #{String.slice(head, 0, 7)}"}

      case Pauses.set({:ticket, repo_key, issue_id}, reason, set_by: @setter) do
        {:ok, _pause} ->
          Logger.info("Holding QA for its build: issue_id=#{issue_id} issue_identifier=#{issue.identifier} repo_key=#{repo_key} head_sha=#{head}")

        {:error, error} ->
          Logger.warning("Could not hold QA for its build: issue_id=#{issue_id} issue_identifier=#{issue.identifier} reason=#{inspect(error)}")
      end
    end

    :ok
  end

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
  def reason?(_reason), do: false

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
