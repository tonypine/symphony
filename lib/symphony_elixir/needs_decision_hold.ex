defmodule SymphonyElixir.NeedsDecisionHold do
  @moduledoc """
  The Needs Decision hold: a designed repo's ticket pauses in its phase with the question recorded,
  and continues in place once the decision is made.

  On a repo running the designed machine an agent's decision request
  (`SymphonyElixir.HumanActions.Request`) no longer moves the ticket to a review state: the ticket
  keeps its phase, gains the `Needs Decision` machine label, and the hold carries the decision
  payload — the question, its options and what clears it. The Inbox loop runs `sweep/3` over the
  tickets it read, reconciling each one's store hold against the requests Linear still reads as
  open (`sync/3` does one ticket, and is a no-op on a legacy repo).

  A request stops being open when the person answers it — a reply under it, or the Director's
  Decide in the Inbox — or when the run withdraws it. The hold then clears and the ticket continues
  from where it stopped; a merge confirmation's hold carries the move its confirmation performs, so
  answering that one continues into `Merging` (`SymphonyElixir.MergeConfirmation`). Legacy repos are
  untouched: a request still moves the ticket to the Human Review state, and no hold is recorded.
  """

  require Logger

  alias SymphonyElixir.{Config, Hold, MergeConfirmation, StateMachine, TicketSignals, TransitionGuard}
  alias SymphonyElixir.HumanActions.{Collector, Request}

  @typedoc "What the ticket's open decision requests call for: set the hold, clear it, or leave it."
  @type action :: {:set, map()} | :clear | :none

  @doc """
  The action the ticket's open decision requests call for, given the Needs Decision hold it already
  has (or nil): `{:set, attrs}` when a request is open and the hold does not already carry it,
  `:clear` when the hold's request is answered or withdrawn, else `:none`.
  """
  @spec desired(Request.t() | nil, map() | nil) :: action()
  def desired(nil, %{kind: :needs_decision}), do: :clear
  def desired(nil, _current_hold), do: :none

  def desired(%{} = request, current_hold) do
    if same_decision?(current_hold, request), do: :none, else: {:set, attrs(request)}
  end

  @doc """
  The hold payload a decision request records: the question as the reason, the options, and when
  the decision is recorded as what clears it. The request is a parsed one
  (`SymphonyElixir.HumanActions.Request`) or the tool's own request before Linear reads it back,
  which has no `created_at` yet.
  """
  @spec attrs(Request.t() | map()) :: map()
  def attrs(request) do
    %{
      reason: request.question || request.title,
      clearing_condition: "when the decision is recorded",
      decision: %{
        title: request.title,
        question: request.question,
        why: request.why,
        options: request.options,
        asked_at: Map.get(request, :created_at)
      }
    }
  end

  @doc """
  Reconciles the Needs Decision hold of one ticket against the decision requests Linear still reads
  as open on it. `opts[:settings]` is the repo's resolved settings (the Inbox passes the one it
  resolved for the route); without it the repo is resolved through `Config.settings_for_repo/1`.
  Returns `:skipped` on a repo that is not the designed machine, else the action taken (`:set`,
  `:clear` or `:none`).
  """
  @spec sync(String.t() | term(), map() | term(), keyword()) :: :skipped | :set | :clear | :none
  def sync(repo_key, node, opts \\ []) do
    with repo_key when is_binary(repo_key) <- repo_key,
         settings when is_map(settings) <- settings(repo_key, opts),
         true <- StateMachine.designed?(settings) do
      sync_designed(repo_key, node, settings, opts)
    else
      _skipped -> :skipped
    end
  end

  @doc """
  Runs `sync/3` over the ticket nodes a repo route read and returns how many holds it changed. A
  hand-added `Needs Decision` label with no store record is reported and cleared, so the board
  matches the store.
  """
  @spec sweep(String.t() | term(), [map()] | term(), keyword()) :: non_neg_integer()
  def sweep(repo_key, nodes, opts \\ []) do
    if is_list(nodes), do: Enum.count(nodes, &(sync(repo_key, &1, opts) in [:set, :clear])), else: 0
  end

  defp sync_designed(repo_key, %{"id" => issue_id} = node, settings, opts) when is_binary(issue_id) do
    repair_drift(repo_key, issue_id, labels(node), opts)
    current = Hold.get(repo_key, issue_id, :needs_decision, opts)

    case desired(Collector.newest_request(node, settings), current) do
      {:set, attrs} ->
        apply_set(repo_key, issue_id, attrs, opts)

      :clear ->
        apply_clear(repo_key, issue_id, current, opts)

      :none ->
        :none
    end
  end

  defp sync_designed(_repo_key, _node, _settings, _opts), do: :none

  defp apply_set(repo_key, issue_id, attrs, opts) do
    case Hold.set(repo_key, issue_id, :needs_decision, attrs, opts) do
      :ok -> :set
      {:error, reason} -> log_failure("set", issue_id, reason)
    end
  end

  # Clearing the hold is what "the decision is recorded" does. A merge confirmation's hold carries
  # the move its confirmation performs (`SymphonyElixir.MergeConfirmation`), so answering it by a
  # reply under the request continues into `Merging` rather than leaving the ticket waiting in its
  # phase; an ordinary decision carries none and continues in place, so the next poll dispatches it.
  defp apply_clear(repo_key, issue_id, current, opts) do
    case Hold.clear(repo_key, issue_id, :needs_decision, opts) do
      :ok ->
        resume(repo_key, issue_id, current, opts)
        :clear

      {:error, reason} ->
        log_failure("clear", issue_id, reason)
    end
  end

  defp resume(repo_key, issue_id, current, opts) do
    case MergeConfirmation.confirm_target(current) do
      nil -> :ok
      target -> continue(repo_key, issue_id, target, opts)
    end
  end

  defp continue(repo_key, issue_id, target, opts) do
    case TransitionGuard.perform(issue_id, :director_move, %{target: target, repo_key: repo_key}, Keyword.take(opts, [:tracker])) do
      :ok ->
        TicketSignals.record(repo_key, issue_id, "decision returned", %{move: "confirm", to: target})
        :ok

      {:error, reason} ->
        Logger.warning("Failed to continue issue_id=#{issue_id} to #{target} after its decision: #{inspect(reason)}")
        :ok
    end
  end

  # The store is the truth for a hold, so the board is repaired to match it in both directions: a
  # `Needs Decision` label with no store hold is a hand-added label, reported and cleared, and a
  # store hold whose label is missing is re-projected, so a hold that pauses dispatch is never
  # silently invisible.
  defp repair_drift(repo_key, issue_id, labels, opts) do
    case Hold.report_drift(repo_key, issue_id, labels, opts) do
      {:stray_label, :needs_decision} -> clear_label(repo_key, issue_id, opts)
      {:missing_label, :needs_decision} -> reproject_label(repo_key, issue_id, opts)
      _ok_or_other_kind -> :ok
    end
  end

  defp clear_label(repo_key, issue_id, opts) do
    _ = Hold.clear(repo_key, issue_id, :needs_decision, opts)
    :ok
  end

  defp reproject_label(repo_key, issue_id, opts) do
    _ = Hold.reproject(repo_key, issue_id, :needs_decision, opts)
    :ok
  end

  defp log_failure(action, issue_id, reason) do
    Logger.warning("Failed to #{action} the Needs Decision hold on issue_id=#{issue_id}: #{inspect(reason)}")
    :none
  end

  defp same_decision?(%{kind: :needs_decision, decision: %{} = decision}, request) do
    decision[:title] == request.title and decision[:question] == request.question
  end

  defp same_decision?(_current_hold, _request), do: false

  defp labels(node), do: node |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(& &1["name"])

  # The repo's resolved settings: the caller's once-per-route value when it passed one, else
  # resolved from the ticket's repo key.
  defp settings(repo_key, opts) do
    case Keyword.fetch(opts, :settings) do
      {:ok, settings} -> settings
      :error -> settings_for_repo(repo_key)
    end
  end

  defp settings_for_repo(repo_key) when is_binary(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> settings
      {:error, _reason} -> nil
    end
  end
end
