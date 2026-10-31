defmodule SymphonyElixir.Hold do
  @moduledoc """
  The machine-owned holds that pause a ticket in its phase without moving it.

  A hold is persisted in the ticket-state record (`SymphonyElixir.TicketState`, written through
  `SymphonyElixir.RunStore`) and surfaced as a machine-owned Linear label — the label is only the
  projection; the store is the truth. `SymphonyElixir.MachineLabels` refuses these names on the
  generic `Tracker.add_issue_label/2` and `Tracker.remove_issue_label/2` paths, so agents and
  people can never write one: only `set/5` and `clear/4` here do, through
  `Tracker.set_machine_label/2` and `Tracker.clear_machine_label/2`. Dispatch consults `held?/4`
  (the store), never the board.

  The store is written first and the label second: a label write that fails leaves the hold in
  force and is reported, rather than losing the pause. A label write that fails is marked on the
  record (`pending_projection`), and the reconciler writes the label again from the store.

  While the pause projector owns the labels (`SymphonyElixir.Pauses.Projector.owns?/0`), a hold
  writes none of its own: each set, clear and re-projection applies the projector, which renders
  them from the ticket's pause, questions and holds.

  Each hold write that lands in the store is also recorded in the ticket's event stream
  (`SymphonyElixir.TicketEvents`), best-effort. A Blocked hold is `hold.set` and `hold.cleared`. A
  Needs Decision hold is the projection of its decision, never a hold event. One that carries the
  Question it projects (`decision.question_id`, as `SymphonyElixir.DecisionRequest.ask/4` sets it)
  records nothing: the Question's own `question.*` events are the request and its end. One without
  (a request read back from Linear) records `decision.requested` when set (unless that request is
  already open), and `decision.withdrawn` when cleared, unless the caller passes `answered: true`
  because the answer's `decision.recorded` (`SymphonyElixir.Decisions`) ends the request.

  A hold of a kind the ticket didn't have, and a clear of one it had, are announced as a change of
  the record's `holds` (`SymphonyElixirWeb.ObservabilityPubSub.broadcast_ticket_record_changed/3`).

  A Blocked hold set beside a question Symphony asked names it (`waits_on.question_id`, as the
  dispatch-loop guard and the quiet handoff set it, `SymphonyElixir.DispatchLoop`), and a Needs
  Decision hold names the Question it projects (`decision.question_id`): the hold is set after the
  question and cleared with it, so `clear/4` ends that question first when it is still open
  (`SymphonyElixir.Questions`).
  """

  require Logger

  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.{Questions, RunStore, TicketSignals, TicketState, Tracker}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @kind_labels %{blocked: "Blocked", needs_decision: "Needs Decision"}
  @kinds [:blocked, :needs_decision]
  @dispatch_loop_type "dispatch_loop"
  @ci_wait_type "ci_wait"
  @operator_stop_type "operator_stop"
  @idle_park_type "idle_park"
  @unblockable_types ["access", @dispatch_loop_type, @ci_wait_type, @operator_stop_type, @idle_park_type]
  @symphony %{kind: :symphony, name: "Symphony"}

  @typedoc "The holds the design defines."
  @type kind :: :blocked | :needs_decision

  @doc "The known hold kinds, in display order."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The machine label a hold of `kind` is projected as, or nil for an unknown kind."
  @spec label(kind() | term()) :: String.t() | nil
  def label(kind), do: Map.get(@kind_labels, kind)

  @doc "The hold kind a machine label names, or nil."
  @spec kind_for_label(String.t() | nil) :: kind() | nil
  def kind_for_label(name) when is_binary(name) do
    normalized = normalize(name)
    Enum.find(@kinds, &(normalize(@kind_labels[&1]) == normalized))
  end

  def kind_for_label(_name), do: nil

  @doc "The hold of `kind` on the ticket's record (the store truth), or nil."
  @spec get(String.t() | nil, String.t() | nil, kind(), keyword()) :: TicketState.hold() | nil
  def get(repo_key, issue_id, kind, opts \\ []) do
    repo_key
    |> record(issue_id, opts)
    |> TicketState.get_hold(kind)
  end

  @doc "Whether a hold of `kind` is set on the ticket's record (the store truth)."
  @spec held?(String.t() | nil, String.t() | nil, kind(), keyword()) :: boolean()
  def held?(repo_key, issue_id, kind, opts \\ []), do: get(repo_key, issue_id, kind, opts) != nil

  @doc """
  Whether the ticket carries a hold of any kind, read from the store in one go. Every hold pauses
  the flow the same way, whatever set it, so a dispatch gate asks this rather than naming a kind.
  """
  @spec held_any?(String.t() | nil, String.t() | nil, keyword()) :: boolean()
  def held_any?(repo_key, issue_id, opts \\ []), do: held_kinds(repo_key, issue_id, opts) != []

  @doc "The kinds of hold the ticket carries, in display order, read from the store in one go."
  @spec held_kinds(String.t() | nil, String.t() | nil, keyword()) :: [kind()]
  def held_kinds(repo_key, issue_id, opts \\ []) do
    record = record(repo_key, issue_id, opts)
    Enum.filter(@kinds, &TicketState.hold?(record, &1))
  end

  @doc """
  The ids of the repo's tickets that carry a hold of any kind, read from the store in one go. The
  Inbox reads these tickets whether or not the board shows their label: the label is only the
  projection, so a missing one must not keep a hold's answer from being read.
  """
  @spec held_issue_ids(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def held_issue_ids(repo_key, opts \\ []) do
    case Keyword.get(opts, :store, RunStore).list_ticket_states(repo_key) do
      records when is_list(records) ->
        {:ok, for(%{issue_id: issue_id, holds: [_ | _]} <- Enum.map(records, &TicketState.normalize/1), is_binary(issue_id), do: issue_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether a hold waits on a person's `Unblock` (see `SymphonyElixir.DirectorMoves`): one waiting on
  an access grant a person hands over — what an agent's block report records — one the
  dispatch-loop guard set (`SymphonyElixir.DispatchLoop`), one an epic review's wait for CI set
  once it reached its limit (`SymphonyElixir.CiWait`), one an operator's stop set beside the
  ticket's pause (`SymphonyElixir.OperatorStop`), one an idle run's park set
  (`SymphonyElixir.IdlePark`), or one set beside a question Symphony asked
  (`waits_on.question_id`, a quiet handoff's): that question is open while the hold stands, since
  the hold is cleared with it. A dependency or fix-ticket hold clears on its own when what it waits
  on goes terminal; these never clear without a person (a stop's also clears when the ticket leaves
  the workflow or moves on the board). Unblock also lifts a stop whose pause reason stands beside
  another kind of hold (`SymphonyElixir.OperatorStop.held?/2`).
  """
  @spec unblockable?(TicketState.hold() | term()) :: boolean()
  def unblockable?(%{waits_on: %{type: type}}) when type in @unblockable_types, do: true
  def unblockable?(%{waits_on: %{question_id: question_id}}) when is_binary(question_id), do: true
  def unblockable?(_hold), do: false

  @doc "Whether a hold is the one the dispatch-loop guard set (`SymphonyElixir.DispatchLoop`)."
  @spec dispatch_loop?(TicketState.hold() | term()) :: boolean()
  def dispatch_loop?(%{waits_on: %{type: @dispatch_loop_type}}), do: true
  def dispatch_loop?(_hold), do: false

  @doc """
  Sets the hold of `kind` on `issue_id`: the store record first, then its event, then the machine
  label. Returns `{:error, reason}` only when the store write failed (the hold did not land); a
  failed label write is reported and does not undo the hold.
  """
  @spec set(String.t() | nil, String.t() | nil, kind(), map(), keyword()) :: :ok | {:error, term()}
  def set(repo_key, issue_id, kind, attrs \\ %{}, opts \\ []) do
    if label(kind) do
      store = Keyword.get(opts, :store, RunStore)

      with :ok <- require_repo_key(repo_key, issue_id),
           previous = stored_hold(store, repo_key, issue_id, kind),
           :ok <- store.set_ticket_hold(repo_key, issue_id, kind, attrs) do
        announce(repo_key, issue_id, is_nil(previous))
        record_set(repo_key, issue_id, kind, attrs)
        project(opts, repo_key, issue_id, kind, :set)
      end
    else
      {:error, {:unknown_hold_kind, kind}}
    end
  end

  @doc """
  Clears the hold of `kind` from `issue_id`: the store record first, then its event when a hold was
  there, then the machine label. The ticket continues in place. `opts[:answered]` says a person's
  answer ends the Needs Decision hold, so its clear records no withdrawal. Returns
  `{:error, reason}` only when a store write failed.

  A hold that names a question still open (`waits_on.question_id`, or a Needs Decision hold's
  `decision.question_id`) ends it before the store's hold is cleared: `opts[:question]` as
  `{:answer, text, by}` answers it (`Questions.answer/4`, `text` an option's label or the answer in
  a person's words); without it an `answered: true` clear leaves it to the answer's writer, and any
  other clear withdraws it, since what it asked no longer waits.
  """
  @spec clear(String.t() | nil, String.t() | nil, kind(), keyword()) :: :ok | {:error, term()}
  def clear(repo_key, issue_id, kind, opts \\ []) do
    if label(kind) do
      store = Keyword.get(opts, :store, RunStore)

      with :ok <- require_repo_key(repo_key, issue_id),
           previous = stored_hold(store, repo_key, issue_id, kind),
           :ok <- end_question(repo_key, issue_id, previous, Keyword.get(opts, :question), Keyword.get(opts, :answered) == true),
           :ok <- store.clear_ticket_hold(repo_key, issue_id, kind) do
        announce(repo_key, issue_id, previous != nil)
        record_clear(repo_key, issue_id, previous, Keyword.get(opts, :answered) == true)
        project(opts, repo_key, issue_id, kind, :clear)
      end
    else
      {:error, {:unknown_hold_kind, kind}}
    end
  end

  @doc """
  Re-projects the machine label of a hold already in the store, without writing the store. A store
  hold whose label write failed (the failure is swallowed by `set/5`) or whose label a person removed
  by hand is invisible on the board; this re-asserts the projection from the store truth so the hold
  becomes visible again. Returns `{:error, {:no_hold, kind}}` when the store has no such hold.
  """
  @spec reproject(String.t() | nil, String.t() | nil, kind(), keyword()) :: :ok | {:error, term()}
  def reproject(repo_key, issue_id, kind, opts \\ []) do
    if label(kind) do
      case get(repo_key, issue_id, kind, opts) do
        nil -> {:error, {:no_hold, kind}}
        _hold -> project(Keyword.put(opts, :force, true), repo_key, issue_id, kind, :set)
      end
    else
      {:error, {:unknown_hold_kind, kind}}
    end
  end

  # A label write that fails is marked on the record, so the reconciler projects the hold again
  # (`TicketSignals.mark_projection/4`). While the pause projector owns the labels it writes them,
  # and marks its own projection when a write fails; the hold stands either way. A drift repair
  # passes `force` and the labels Linear shows (`labels:`), so the projector compares with those.
  defp project(opts, repo_key, issue_id, kind, action) do
    tracker = Keyword.get(opts, :tracker, Tracker)

    if Projector.owns?() do
      _ = Projector.project_now({:ticket, repo_key, issue_id}, Keyword.take(opts, [:tracker, :store, :force, :labels]))
      :ok
    else
      project_label(tracker, repo_key, issue_id, kind, action)
    end
  end

  defp project_label(tracker, repo_key, issue_id, kind, action) do
    name = label(kind)

    result =
      case action do
        :set -> tracker.set_machine_label(issue_id, name)
        :clear -> tracker.clear_machine_label(issue_id, name)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to #{action} the machine label #{inspect(name)} on issue_id=#{issue_id}: #{inspect(reason)}")
        TicketSignals.mark_projection(repo_key, issue_id, {:hold_label, kind}, reason)
    end
  end

  # A Blocked hold set again with the reason and wait it already has is the same fact, so it records
  # no second `hold.set`.
  defp record_set(repo_key, issue_id, :blocked, attrs) do
    hold = %{} |> TicketState.normalize() |> TicketState.set_hold(:blocked, attrs) |> TicketState.get_hold(:blocked)
    payload = Map.reject(%{kind: "blocked", reason: hold.reason, waits_on: hold.waits_on}, fn {_key, value} -> is_nil(value) end)

    if open_blocked(repo_key, issue_id) == payload,
      do: :ok,
      else: TicketSignals.record_event(repo_key, issue_id, "hold.set", payload)
  end

  # A Needs Decision hold that carries its Question records nothing: `question.asked` is the request.
  defp record_set(_repo_key, _issue_id, :needs_decision, %{decision: %{question_id: id}}) when is_binary(id), do: :ok

  # Any other Needs Decision hold is its decision: the request, unless the same one (title and
  # question) is still open, as when the Inbox's reconciliation or a retry sets the hold again.
  defp record_set(repo_key, issue_id, :needs_decision, attrs) do
    decision = decision(attrs)
    title = text(decision[:title])
    question = text(decision[:question]) || title || text(attrs[:reason])

    cond do
      is_nil(question) ->
        :ok

      same_question?(TicketSignals.open_decision(repo_key, issue_id, title, question), question) ->
        :ok

      true ->
        options = if is_list(decision[:options]) and decision[:options] != [], do: decision[:options]

        TicketSignals.record_event(repo_key, issue_id, "decision.requested", %{
          question: question,
          title: title,
          why: decision[:why],
          options: options,
          confirm: decision[:confirm]
        })
    end
  end

  defp record_clear(_repo_key, _issue_id, nil, _answered?), do: :ok
  defp record_clear(repo_key, issue_id, %{kind: :blocked}, _answered?), do: TicketSignals.record_event(repo_key, issue_id, "hold.cleared", %{kind: "blocked"})
  defp record_clear(_repo_key, _issue_id, %{kind: :needs_decision}, true = _answered?), do: :ok
  # The Question's own `question.answered` or `question.withdrawn` ends the request it projects.
  defp record_clear(_repo_key, _issue_id, %{kind: :needs_decision, decision: %{question_id: id}}, _answered?) when is_binary(id), do: :ok

  # A request that ends with no answer: the tool's withdrawal, a request gone from Linear, one that
  # could not be posted.
  defp record_clear(repo_key, issue_id, %{kind: :needs_decision} = hold, false = _answered?) do
    decision = decision(hold)
    question = text(decision[:question])
    title = text(decision[:title]) || question || text(hold.reason) || "Decision request"
    request = TicketSignals.open_decision(repo_key, issue_id, text(decision[:title]), question)

    TicketSignals.record_event(repo_key, issue_id, "decision.withdrawn", %{title: title, question: question, request: request && request.id})
  end

  # The question a hold was set beside, or the one it projects, ends with it; one already answered or
  # withdrawn ends nothing. An answered clear with no answer given leaves it to the answer's writer.
  defp end_question(repo_key, issue_id, hold, question, answered?) do
    case {held_question(hold), question, answered?} do
      {nil, _question, _answered?} -> :ok
      {id, {:answer, text, by}, _answered?} -> ended(Questions.answer({:ticket, repo_key, issue_id}, id, text, by: by))
      {_id, nil, true} -> :ok
      {id, nil, false} -> ended(Questions.withdraw({:ticket, repo_key, issue_id}, id, "Symphony lifted the pause it was asked with.", by: @symphony, cause: "hold_cleared"))
    end
  end

  defp held_question(%{waits_on: %{question_id: id}}) when is_binary(id), do: id
  defp held_question(%{kind: :needs_decision, decision: %{question_id: id}}) when is_binary(id), do: id
  defp held_question(_hold), do: nil

  defp ended({:ok, _question}), do: :ok
  defp ended({:error, {:question_not_open, _state}}), do: :ok
  defp ended({:error, :question_not_found}), do: :ok
  defp ended({:error, reason}), do: {:error, reason}

  # A hold that appeared or went is a change of the record's holds, which the PR watcher re-decides
  # the ticket on; a hold set again over itself changes nothing it reads.
  defp announce(repo_key, issue_id, true), do: ObservabilityPubSub.broadcast_ticket_record_changed(repo_key, issue_id, [:holds])
  defp announce(_repo_key, _issue_id, false), do: :ok

  # The store's hold before a write, read without a warning: a read that fails records no event.
  defp stored_hold(store, repo_key, issue_id, kind) do
    case store.get_ticket_state(repo_key, issue_id) do
      {:error, _reason} -> nil
      record -> TicketState.get_hold(record, kind)
    end
  end

  # The payload of the ticket's newest Blocked hold event when it is a `hold.set` (the hold it
  # records is still on), else nil.
  defp open_blocked(repo_key, issue_id) do
    events = RunStore.list_ticket_events(repo_key, issue_id, types: ["hold.set", "hold.cleared"])
    if is_list(events), do: open_payload(List.last(events))
  end

  defp open_payload(%{type: "hold.set", payload: payload}), do: payload
  defp open_payload(_cleared_or_none), do: nil

  defp same_question?(%{payload: payload}, question), do: TicketSignals.same_text?(payload[:question], question)
  defp same_question?(nil, _question), do: false

  defp decision(attrs) do
    case Map.get(attrs, :decision) do
      decision when is_map(decision) -> decision
      _none -> %{}
    end
  end

  defp text(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp text(_value), do: nil

  defp record(_repo_key, nil, _opts), do: TicketState.normalize(nil)

  defp record(repo_key, issue_id, opts) when is_binary(repo_key) and is_binary(issue_id) do
    store = Keyword.get(opts, :store, RunStore)

    case store.get_ticket_state(repo_key, issue_id) do
      {:error, reason} ->
        Logger.warning("Failed to read the ticket state for issue_id=#{issue_id}: #{inspect(reason)}")
        TicketState.normalize(nil)

      record ->
        TicketState.normalize(record)
    end
  end

  # A ticket read with no repo key would look like one with no hold, so say so instead of hiding it.
  defp record(repo_key, issue_id, _opts) when is_binary(issue_id) and repo_key in [nil, ""] do
    Logger.error("Read the holds of issue_id=#{issue_id} with no repo key; resolve the issue's repo before reading its holds")
    TicketState.normalize(nil)
  end

  defp record(_repo_key, _issue_id, _opts), do: TicketState.normalize(nil)

  # A hold written with no repo key would land nowhere the readers look, so it is refused loudly.
  defp require_repo_key(repo_key, _issue_id) when is_binary(repo_key) and repo_key != "", do: :ok

  defp require_repo_key(_repo_key, issue_id) do
    Logger.error("Refused a hold write on issue_id=#{issue_id} with no repo key; resolve the issue's repo first")
    {:error, :missing_repo_key}
  end

  defp normalize(value), do: value |> String.trim() |> String.downcase()
end
