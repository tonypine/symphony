defmodule SymphonyElixir.CodeReview do
  @moduledoc """
  The `Code Review` state's reviewer run.

  A designed repo's `Code Review` ticket is dispatched by the poll loop like any other active
  ticket; this module turns that dispatch into a review instead of an executor run. It reuses the
  pre-push reviewer's machinery (`SymphonyElixir.ReviewAgent`), so a Code Review verdict is
  grounded in the same read-only, diff-based judgment the pre-push reviewer already makes.

  The run is only ever started on a green head (the orchestrator gates dispatch on the ticket's
  recorded CI state). Its verdict is recorded bound to the head SHA it judged, then performed
  through the one writer, `SymphonyElixir.TransitionGuard`:

    * `approve` -> `Merging` (the QA-skipped policy path)
    * `request_changes` -> `Rework`
    * `block` -> the escalation state, through the request machinery

  An inconclusive review retries boundedly on the same head, then escalates the same way. A legacy
  repo never reaches this module: `run/3` returns `:skip` for anything but a designed repo's
  `Code Review` ticket, so the executor path is untouched.
  """

  require Logger

  alias SymphonyElixir.{Config, Handoff, ReviewAgent, StateMachine, TicketSignals, TransitionGuard, WorkspaceHead}
  alias SymphonyElixir.Linear.Issue

  @verdict_kind "code_review"
  @max_inconclusive_retries 2
  @merging_state "Merging"

  @doc """
  Runs the reviewer for `issue` when it is a designed repo's `Code Review` ticket, else `:skip` so
  the caller falls through to the executor run. `opts[:review_agent]` and `opts[:tracker]` override
  the reviewer and the tracker (tests, a fake).
  """
  @spec run(Issue.t(), Path.t(), keyword()) :: :skip | :ok | {:error, term()}
  def run(%Issue{} = issue, workspace, opts) when is_binary(workspace) do
    settings = Keyword.fetch!(opts, :settings)

    if reviewer_run?(issue, settings) do
      review(issue, workspace, opts, settings)
    else
      :skip
    end
  end

  def run(_issue, _workspace, _opts), do: :skip

  @doc """
  Whether `issue` is the ticket this module reviews: a designed repo's configured Code Review
  state. Every other ticket belongs to the executor run.
  """
  @spec reviewer_run?(Issue.t(), map()) :: boolean()
  def reviewer_run?(%Issue{state: state}, settings) when is_binary(state) do
    StateMachine.designed?(settings) and
      normalize_state(state) == normalize_state(settings.tracker.code_review_state)
  end

  def reviewer_run?(_issue, _settings), do: false

  defp review(issue, workspace, opts, settings) do
    case evaluate(issue, workspace, opts, settings) do
      {:ok, %{verdict: verdict} = result} ->
        apply_verdict(issue, workspace, opts, settings, verdict, result)

      {:error, {:review_agent_inconclusive, reason}} ->
        inconclusive(issue, workspace, opts, settings, reason)

      {:error, reason} ->
        {:error, {:code_review_failed, reason}}
    end
  end

  # The same read-only reviewer the pre-push pass uses, pointed at the PR head this run is checked
  # out on. The base branch comes from the repo's config, exactly as the pre-push pass resolves it.
  defp evaluate(issue, workspace, opts, settings) do
    review_opts =
      opts
      |> Keyword.take([:repo_key, :run_id, :reviewer_run_profile, :linear_comment_registry, :agent_tmp_dir])
      |> Keyword.put(:worker_host, Keyword.get(opts, :worker_host))
      |> maybe_put_base_branch(opts)

    Keyword.get(opts, :review_agent, ReviewAgent).evaluate(issue, workspace, settings, review_opts)
  end

  defp maybe_put_base_branch(review_opts, opts) do
    case base_branch(Keyword.get(opts, :repo_key)) do
      nil -> review_opts
      base_branch -> Keyword.put(review_opts, :base_branch, base_branch)
    end
  end

  defp base_branch(repo_key) do
    case Config.repo_base_branch(repo_key) do
      {:ok, base_branch} -> base_branch
      {:error, _reason} -> nil
    end
  end

  defp apply_verdict(issue, workspace, opts, settings, verdict, result) do
    head = workspace_head(workspace, opts)
    record_verdict(issue, opts, head, to_string(verdict))
    Logger.info("Code Review verdict for #{issue_label(issue)} head=#{head || "unknown"} verdict=#{inspect(verdict)}")

    case verdict do
      :approve -> move(issue, opts, settings, :code_review_approve, %{target: @merging_state})
      :request_changes -> move(issue, opts, settings, :code_review_rework, %{})
      :block -> escalate(issue, opts, settings, verdict_reason(result))
      other -> {:error, {:code_review_unknown_verdict, other}}
    end
  end

  # An inconclusive review is not a verdict: the reviewer could not ground one on the head. It
  # retries boundedly on the same head, and escalates to a person once it has run out of attempts.
  defp inconclusive(issue, workspace, opts, settings, reason) do
    head = workspace_head(workspace, opts)
    retries = inconclusive_retries(issue, opts, head)

    if retries < @max_inconclusive_retries do
      record_verdict(issue, opts, head, "inconclusive")

      Logger.warning("Code Review for #{issue_label(issue)} head=#{head || "unknown"} was inconclusive (attempt #{retries + 1}/#{@max_inconclusive_retries}); retrying")

      {:error, {:code_review_inconclusive, reason}}
    else
      record_verdict(issue, opts, head, "inconclusive_escalated")
      escalate(issue, opts, settings, "inconclusive after #{retries} retries: #{inspect(reason)}")
    end
  end

  defp inconclusive_retries(issue, opts, head) do
    issue
    |> verdicts(opts)
    |> Enum.count(&(&1.head_sha == head and &1.outcome == "inconclusive"))
  end

  defp escalate(issue, opts, settings, reason) do
    Logger.warning("Escalating Code Review for #{issue_label(issue)} to a person: #{reason}")

    move(issue, opts, settings, :code_review_escalate, %{
      target: escalation_state(settings),
      reason: reason
    })
  end

  defp escalation_state(settings), do: settings.ci.escalation_state

  # Every move goes through the one writer. `run/3` only ever gets here for a ticket already in the
  # configured Code Review state (`reviewer_run?/2`), which is the origin of each of these edges in
  # the designed table; the table itself is what defines them, and is tested directly.
  defp move(issue, opts, settings, signal, extra) do
    ctx = Map.merge(%{settings: settings}, extra)

    case TransitionGuard.perform(issue.id, signal, ctx, tracker_opts(opts)) do
      :ok ->
        record_move_signal(issue, opts, signal, extra)
        :ok

      {:error, reason} ->
        {:error, {:code_review_move_failed, signal, reason}}
    end
  end

  defp tracker_opts(opts) do
    case Keyword.get(opts, :tracker) do
      nil -> []
      tracker -> [tracker: tracker]
    end
  end

  defp record_verdict(issue, opts, head, outcome) do
    TicketSignals.record_verdict(repo_key(issue, opts), issue.id, @verdict_kind, head, outcome)
  end

  defp record_move_signal(issue, opts, signal, extra) do
    details =
      extra
      |> Map.take([:target, :reason])
      |> Map.put(:signal, to_string(signal))

    TicketSignals.record(repo_key(issue, opts), issue.id, @verdict_kind, details)
  end

  defp verdicts(issue, opts), do: Handoff.verdicts(repo_key(issue, opts), issue.id, @verdict_kind)

  defp repo_key(issue, opts), do: Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)

  # The head the verdict binds to, read the same way the agent runner reads it: a local workspace's
  # `HEAD`, or nil when it cannot be read (an SSH worker, a missing checkout, no commits). A verdict
  # then binds to nothing rather than to the wrong commit.
  defp workspace_head(workspace, opts), do: WorkspaceHead.read(workspace, Keyword.get(opts, :worker_host))

  defp verdict_reason(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp verdict_reason(%{comments: [comment | _]}) when is_binary(comment), do: comment
  defp verdict_reason(_result), do: "reviewer blocked the change"

  defp issue_label(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_label(%Issue{id: id}), do: inspect(id)

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
end
