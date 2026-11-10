defmodule SymphonyElixir.RuleActions do
  @moduledoc """
  The ledger's record of what Symphony's rules did on a ticket: one `rule.action` event
  (`SymphonyElixir.TicketEvents.Types`) each time a rule acts on it, with the rule's name and what it
  did, so the Journal (`SymphonyElixir.TicketEvents.Journal`) and the ticket's timeline say which
  rule acted rather than "Symphony".

  The writers:

    * the PR and CI watcher (`SymphonyElixir.PrDecision.Apply`): each action it applied, named by
      its row (`watcher_rule/1`, "PR watcher R22") and its kind (`watcher_action/1`). Its red
      backstop records only a question to a person: a fix ticket it hands the self-heal lane is
      recorded once, by the lane;
    * a pause reason a rule set or lifted (`SymphonyElixir.Pauses`, in the pause's own transaction,
      `pause_event/4`): the CI wait, the release-build watch, the blocked-by links, self-heal's fix
      ticket, the update and instructions holds and every other setter of kind `:rule`. A question's
      reason is left out: its `question.asked` already says who asked;
    * the dispatch-loop guard (`SymphonyElixir.Orchestrator`), the idle park
      (`SymphonyElixir.AgentRunner`) and self-heal's new fix ticket (`SymphonyElixir.SelfHeal`).

  Recording is best-effort like the ticket's signals: a store failure is logged and never stops the
  rule. The audit records the rules write stay as they are.
  """

  require Logger

  alias SymphonyElixir.TicketEvents
  alias SymphonyElixir.TicketEvents.Event

  @max_text 500
  @watcher_actions %{
    rerun_failed: "rerun",
    ci_fix: "moved",
    return_to_origin: "moved",
    to_code_review: "moved",
    to_in_progress: "moved",
    to_rework: "moved",
    close_out: "moved",
    update_branch: "updated_branch",
    merge_now: "auto_merge",
    arm: "auto_merge",
    disarm: "auto_merge",
    decision: "asked"
  }

  @typedoc "What the rule did: one of `SymphonyElixir.TicketEvents.Types.rule_actions/0`."
  @type action :: String.t()

  @typedoc "`record/5`'s options: the ticket it `filed`, the `head` it acted on, and `at`."
  @type opt :: {:filed, String.t() | nil} | {:head, String.t() | nil} | {:at, DateTime.t()}

  @doc """
  Records that the rule `rule` did `action` on `repo_key`'s ticket `issue_id`, with `text`, its line
  in plain words (cut to #{@max_text} characters). Best-effort: `:ok` always, a refusal logged.
  """
  @spec record(String.t() | nil, String.t() | nil, String.t(), action(), String.t() | nil, [opt()]) :: :ok
  def record(repo_key, issue_id, rule, action, text, opts \\ []) do
    if is_binary(repo_key) and is_binary(issue_id),
      do: do_record(repo_key, issue_id, rule, action, text, opts),
      else: :ok
  end

  defp do_record(repo_key, issue_id, rule, action, text, opts) do
    record_opts = if at = Keyword.get(opts, :at), do: [at: at], else: []

    case TicketEvents.record(repo_key, issue_id, "rule.action", payload(rule, action, text, opts), record_opts) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to record rule.action rule=#{inspect(rule)} action=#{action} issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  end

  @doc "The name a PR watcher row's action is recorded under: `PR watcher R22`."
  @spec watcher_rule(String.t()) :: String.t()
  def watcher_rule(rule) when is_binary(rule), do: "PR watcher " <> rule

  @doc "What a PR watcher action of `kind` did, as `rule.action` says it; `other` for a kind with no word of its own."
  @spec watcher_action(atom()) :: action()
  def watcher_action(kind), do: Map.get(@watcher_actions, kind, "other")

  @doc """
  The `rule.action` a pause change records next to its `type` event with `payload`
  (`SymphonyElixir.Pauses`) at `at`: built, not written, for the pause's own transaction. A reason set
  (`pause.set`, `pause.reason_added`) by a `:rule` setter is `paused`, one a `:rule` cleared
  (`pause.reason_cleared`, `pause.cleared`) is `lifted_pause`; a question's reason, a backfilled one,
  and any other setter record nothing (`:none`).
  """
  @spec pause_event(String.t() | nil, String.t(), String.t(), map(), DateTime.t() | nil) :: {:ok, Event.t()} | :none
  def pause_event(repo_key, issue_id, type, payload, at) do
    case pause_action(type, payload) do
      {rule, action, text} ->
        case TicketEvents.build(repo_key, issue_id, "rule.action", payload(rule, action, text, []), at: at) do
          {:ok, event} -> {:ok, event}
          {:error, _reason} -> :none
        end

      nil ->
        :none
    end
  end

  defp pause_action(type, %{source: :backfill}) when type in ["pause.set", "pause.reason_added"], do: nil

  defp pause_action(type, %{set_by: %{kind: :rule, name: rule}, reason: kind} = payload) when type in ["pause.set", "pause.reason_added"] and kind != :question,
    do: {rule, "paused", Map.get(payload, :text)}

  defp pause_action("pause.reason_cleared", %{by: %{kind: :rule, name: rule}, reason: kind} = payload) when kind != :question,
    do: {rule, "lifted_pause", Map.get(payload, :text)}

  defp pause_action("pause.cleared", %{by: %{kind: :rule, name: rule}, cleared: cleared}) do
    case Enum.reject(cleared, &(&1.reason == :question)) do
      [] -> nil
      reasons -> {rule, "lifted_pause", Enum.map_join(reasons, "; ", & &1.text)}
    end
  end

  defp pause_action(_type, _payload), do: nil

  defp payload(rule, action, text, opts) do
    %{rule: String.slice(to_string(rule), 0, 200), action: action, text: cut(text), filed: Keyword.get(opts, :filed), head: Keyword.get(opts, :head)}
  end

  defp cut(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: String.slice(text, 0, @max_text))
  defp cut(_text), do: nil
end
