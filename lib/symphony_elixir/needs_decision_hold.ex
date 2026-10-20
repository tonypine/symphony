defmodule SymphonyElixir.NeedsDecisionHold do
  @moduledoc """
  The Needs Decision hold: a ticket pauses in its phase with the question recorded, and continues in
  place once the decision is made.

  An agent's decision request (`SymphonyElixir.HumanActions.Request`) never moves the ticket: the
  ticket keeps its phase, gains the `Needs Decision` machine label, and the hold carries the
  decision payload — the question, its options and what clears it. The Inbox loop runs `sweep/3`
  over the tickets it read, reconciling each one's store hold against the requests Linear still
  reads as open (`sync/3` does one ticket).

  A request stops being open when the person answers it — a reply under it, or the Director's
  Decide in the Inbox — or when the run withdraws it. An answer is written into the Decisions
  section of the ticket's description on the read that sees it (`SymphonyElixir.Decisions`), so
  the reviewer and later runs honour it. The hold then clears and the ticket continues
  from where it stopped; a merge confirmation's hold carries the move its confirmation performs, so
  answering that one continues into `Merging` (`SymphonyElixir.MergeConfirmation`).
  """

  require Logger

  alias SymphonyElixir.{Config, Decisions, Handoff, Hold, MergeConfirmation, TicketSignals, TransitionGuard}
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
  Pauses `issue` in its phase on a decision the machine needs: posts `request` as the
  `## Decision needed:` comment (rendered to say the ticket stays where it is) and sets the Needs
  Decision hold carrying it. The hold is set before the comment is posted, so a retry after a
  failure never posts the comment twice. `confirm`, when given, is the state a confirmation continues into, as
  a merge confirmation's does (`SymphonyElixir.MergeConfirmation.confirm_target/1`); without it the
  ticket continues in place once the decision is recorded.

  `issue` needs `:id` and `:state`, and `:repo_key` unless `opts[:repo_key]` names it.
  `opts[:tracker]` and `opts[:store]` override the tracker and the run store (tests, a fake).
  """
  @spec pause(map(), map(), keyword(), String.t() | nil) :: :ok | {:error, term()}
  def pause(%{id: issue_id} = issue, request, opts, confirm \\ nil) do
    tracker = Keyword.get(opts, :tracker, SymphonyElixir.Tracker)
    repo_key = Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)

    hold_opts = Keyword.take(opts, [:store])

    # The hold first: a hold that can't be set posts nothing, so the caller's retry never posts a
    # second `## Decision needed:` comment. A comment that can't be posted takes the hold back.
    with {:hold, :ok} <- {:hold, Hold.set(repo_key, issue_id, :needs_decision, confirming(attrs(request), confirm, Map.get(issue, :state)), hold_opts)},
         {:post, :ok} <- {:post, tracker.create_comment(issue_id, Request.render_hold(request, Map.get(issue, :state)))} do
      :ok
    else
      {:hold, {:error, reason}} ->
        {:error, {:decision_hold_failed, reason}}

      {:post, {:error, reason}} ->
        Hold.clear(repo_key, issue_id, :needs_decision, hold_opts)
        {:error, {:decision_request_failed, reason}}
    end
  end

  # A confirmation also records the state the ticket waits in, so a person's move made after the
  # request wins over the move the answer would perform (`resume/5`).
  defp confirming(attrs, nil, _state), do: attrs
  defp confirming(attrs, confirm, state), do: %{attrs | decision: attrs.decision |> Map.put(:confirm, confirm) |> Map.put(:state, state)}

  @doc """
  Reconciles the Needs Decision hold of one ticket against the decision requests Linear still reads
  as open on it. `opts[:settings]` is the repo's resolved settings (the Inbox passes the one it
  resolved for the route); without it the repo is resolved through `Config.settings_for_repo/1`.
  Returns `:skipped` when the repo can't be resolved, else the action taken (`:set`, `:clear` or
  `:none`).
  """
  @spec sync(String.t() | term(), map() | term(), keyword()) :: :skipped | :set | :clear | :none
  def sync(repo_key, node, opts \\ []) do
    with repo_key when is_binary(repo_key) <- repo_key,
         settings when is_map(settings) <- settings(repo_key, opts) do
      sync_ticket(repo_key, node, settings, opts)
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

  defp sync_ticket(repo_key, %{"id" => issue_id} = node, settings, opts) when is_binary(issue_id) do
    repair_drift(repo_key, issue_id, node, opts)
    # The answers go into the ticket's scope on the read that sees them, whatever the hold does.
    _ = Decisions.sync(node, opts |> Keyword.take([:tracker]) |> Keyword.put(:repo_key, repo_key))
    current = Hold.get(repo_key, issue_id, :needs_decision, opts)

    case desired(Collector.newest_request(node, settings), current) do
      {:set, attrs} ->
        apply_set(repo_key, issue_id, attrs, opts)

      :clear ->
        apply_clear(repo_key, issue_id, current, node, opts)

      :none ->
        :none
    end
  end

  defp sync_ticket(_repo_key, _node, _settings, _opts), do: :none

  defp apply_set(repo_key, issue_id, attrs, opts) do
    case Hold.set(repo_key, issue_id, :needs_decision, attrs, opts) do
      :ok -> :set
      {:error, reason} -> log_failure("set", issue_id, reason)
    end
  end

  # Clearing the hold is what "the decision is recorded" does. A confirmation hold carries the move
  # its confirmation performs (`SymphonyElixir.MergeConfirmation`), so a reply under the request
  # that picks that option continues there, one that picks `Send to Rework` goes to `Rework`, and
  # any other reply is a change request sent to `In Progress` (`MergeConfirmation.reply_target/2`).
  # An ordinary decision carries none and continues in place, so the next poll dispatches it. A
  # request a reply answered ends with its answer (`Decisions.sync/2` recorded it first); one gone
  # with no answer (withdrawn, deleted) ends as a withdrawal.
  defp apply_clear(repo_key, issue_id, current, node, opts) do
    replies = replies(node, current)

    case Hold.clear(repo_key, issue_id, :needs_decision, Keyword.put(opts, :answered, replies != [])) do
      :ok ->
        clear_quiet_handoff_hold(repo_key, issue_id, opts)

        if moved_since_request?(current, node),
          do: Logger.info("Leaving issue_id=#{issue_id} where a person moved it after its decision request"),
          else: resume(repo_key, issue_id, current, replies, opts)

        :clear

      {:error, reason} ->
        log_failure("clear", issue_id, reason)
    end
  end

  # Runs that went quiet while the ticket waited on its question are what a `handoff_missing` Blocked
  # hold counts (`SymphonyElixir.Orchestrator`), so the answer lifts that hold too: the ticket
  # resumes with no second hold to clear. A Blocked hold on anything else stays.
  defp clear_quiet_handoff_hold(repo_key, issue_id, opts) do
    blocked = Hold.get(repo_key, issue_id, :blocked, opts)

    if get_in(blocked, [:waits_on, :type]) == Handoff.missing_signal(),
      do: log_clear_result(Hold.clear(repo_key, issue_id, :blocked, opts), issue_id),
      else: :ok
  end

  defp log_clear_result(:ok, issue_id), do: Logger.info("Cleared the #{Handoff.missing_signal()} Blocked hold on issue_id=#{issue_id} with its decision")

  defp log_clear_result({:error, reason}, issue_id),
    do: Logger.warning("Failed to clear the #{Handoff.missing_signal()} Blocked hold on issue_id=#{issue_id}: #{inspect(reason)}")

  defp resume(repo_key, issue_id, current, replies, opts) do
    case MergeConfirmation.reply_target(current, replies) do
      nil -> :ok
      target -> continue(repo_key, issue_id, target, opts)
    end
  end

  # Whether the ticket left the state it waited in since the request was posted: a person's move
  # wins over the answer's. A hold that recorded no state, or a node read without one, can't tell.
  defp moved_since_request?(current, node) do
    waiting = get_in(current, [:decision, :state])
    now = get_in(node, ["state", "name"])
    is_binary(waiting) and is_binary(now) and String.downcase(String.trim(waiting)) != String.downcase(String.trim(now))
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
  defp repair_drift(repo_key, issue_id, node, opts) do
    case Hold.report_drift(repo_key, issue_id, labels(node), Keyword.merge(opts, identifier: node["identifier"], url: node["url"])) do
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

  # The bodies of the replies under the requests carrying the hold's question: the answer a person
  # gave, which names the option they picked. A withdrawal is the run's, not an answer.
  defp replies(node, current) do
    title = get_in(current, [:decision, :title])
    comments = node |> get_in(["comments", "nodes"]) |> List.wrap()
    request_ids = for %{"id" => id, "body" => body} <- comments, match?(%{title: ^title}, Request.parse(body, nil)), into: MapSet.new(), do: id

    for %{"parent" => %{"id" => parent_id}, "body" => body} <- comments,
        MapSet.member?(request_ids, parent_id),
        is_binary(body),
        not Request.withdrawal?(body),
        do: body
  end

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
