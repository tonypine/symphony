defmodule SymphonyElixir.TicketSignals do
  @moduledoc """
  Best-effort recording of the machine's transitions into a ticket's signals ledger, and into its
  event stream (`SymphonyElixir.TicketEvents`).

  Every recording here is a side effect next to an already-decided move. A store failure is logged
  and swallowed, so it can never change a transition, a board move or a label. The ledger lives in
  `SymphonyElixir.RunStore` and its shape in `SymphonyElixir.TicketState`.

  Each signal also records the event `event/2` maps it to (dual-write: the signals ledger stays the
  source of truth until readers move over). A signal written next to a hold or a decision request
  maps to none: `SymphonyElixir.Hold` records the `hold.set`, `hold.cleared`, `decision.requested`
  or `decision.withdrawn` for the same change, and `SymphonyElixir.Decisions` the
  `decision.recorded`, so each fact is one event.
  """

  require Logger

  alias SymphonyElixir.{RunStore, TicketEvents}

  @phase_signals ["claim", "ci fix return", "review verdict", "merge settled", "restart", "deprioritized"]
  @mirrored_signals ["decision requested", "unblocked", "dispatch_loop", "ci_wait"]
  @review_signals ["code_review", "qa", "epic_review"]
  # A review's move signal that pauses the ticket on a decision instead of moving it.
  @decision_moves ["merge_confirmation", "code_review_escalate"]
  @kind_phases %{
    "code_review" => "Code Review",
    "qa" => "QA",
    "epic_review" => "Epic Review",
    "ci_fix" => "CI Fix",
    "plan_review" => "Plan Review"
  }
  @notes %{
    "ci_wait_started" => "Waiting for CI",
    "handoff_missing" => "The run ended without its handoff",
    "code_review_carried" => "Code Review carried its approval to a new head",
    "code_review_reviewer_disabled" => "Code Review's reviewer is turned off",
    "code_review_head_not_green" => "Code Review waits for a green head",
    "qa_head_not_green" => "QA waits for a green head",
    "qa_head_unreadable" => "QA could not read the workspace head",
    "ci_rerun" => "Symphony reran the failed CI",
    "ci_flake" => "CI passed on Symphony's rerun, a flake"
  }
  @note_max 4_000

  @typedoc "What a signal maps to: an event's type, payload and `TicketEvents.record/5` options, or none."
  @type mapping :: {String.t(), map(), keyword()} | :mirrored

  @doc """
  Appends `name` with `details` to the ticket's signals ledger, then records the event the signal
  maps to (`event/2`). No-ops when the ticket carries no repo key, so a move made outside a
  configured repo records nothing rather than failing.
  """
  @spec record(String.t() | nil, String.t() | nil, String.t(), map()) :: :ok
  def record(repo_key, issue_id, name, details) when is_binary(repo_key) and is_binary(issue_id) do
    case RunStore.record_ticket_signal(repo_key, issue_id, name, details) do
      :ok -> record_mapped(repo_key, issue_id, event(name, details))
      error -> log_error(error, "record #{name} signal")
    end
  end

  def record(_repo_key, _issue_id, _name, _details), do: :ok

  @doc """
  Records a verdict of `kind` with `outcome`, bound to the `head_sha` it judged and carrying
  `details`, on the ticket's record, then its `verdict.recorded` event, in the kind's phase. No-ops
  when the ticket carries no repo key. Verdicts are never collapsed: two inconclusive verdicts on
  one head are two events, as the reviewer counts them.

  `run_id:` in `opts` names the run that gave the verdict, the id its `run.started` event carries,
  so the event sits inside that run. A verdict no run gave (one carried to a new head) names none.
  `reason:` is the verdict's summary in plain words, which the event carries.
  """
  @spec record_verdict(id, id, String.t(), id, String.t(), map(), keyword()) :: :ok when id: String.t() | nil
  def record_verdict(repo_key, issue_id, kind, head_sha, outcome, details \\ %{}, opts \\ []) do
    if is_binary(repo_key) and is_binary(issue_id) do
      case RunStore.record_ticket_verdict(repo_key, issue_id, kind, head_sha, outcome, details) do
        :ok -> record_mapped(repo_key, issue_id, verdict_event(kind, outcome, head_sha, opts))
        error -> log_error(error, "record #{kind} verdict")
      end
    else
      :ok
    end
  end

  @doc """
  The `verdict.recorded` event `record_verdict/7` records for a verdict of `kind` with `outcome` on
  `head_sha`, in the run `opts`' `run_id:` names, or in none, with `opts`' `reason:` as its summary.
  """
  @spec verdict_event(String.t(), String.t() | nil, String.t() | nil, keyword()) :: mapping()
  def verdict_event(kind, outcome, head_sha, opts \\ []) do
    {type, payload, event_opts} = verdict(kind, outcome, head_sha, nil, Keyword.get(opts, :run_id))
    {type, compact(Map.put(payload, :reason, string(Keyword.get(opts, :reason)))), event_opts}
  end

  @doc """
  The event a signal `name` with `details` maps to: its type, payload and `TicketEvents.record/5`
  options, or `:mirrored` when a hold or decision event records the same change. Every payload a
  signal maps to carries `signal`, the name it mirrors, except a `note`, whose text names it.

    * A phase move (`claim`, `ci fix return`, `review verdict`, `merge settled`, `restart`,
      `deprioritized`, a `handoff` or `decision returned` that moved the ticket, the idle park's
      `blocked`, a review's move after its verdict, a sub-issue's `plan verdict`) is
      `phase.entered`, in the phase it entered.
    * A tool hook's or the runner's `handoff` is `attempt.pushed`, keyed by its head.
    * `fix verdict` and a plan parent's `plan verdict` are `verdict.recorded`.
    * A held `blocked` or `handoff_missing`, `unblocked`, `dispatch_loop`, `ci_wait`,
      `decision requested`, a review's merge confirmation or escalation, and a Decide that moved
      nothing are `:mirrored`.
    * Any other signal is a machine `note` rendered from its name and details.
  """
  @spec event(String.t(), map()) :: mapping()
  def event(name, details) when is_map(details), do: map_signal(name, details)
  def event(name, _details), do: map_signal(name, %{})

  @doc """
  Records an event through `TicketEvents.record/5`, best-effort: a refused or failed write is
  logged and swallowed, so the write it sits next to returns as it would without it. Payload fields
  that are nil or blank are left out.
  """
  @spec record_event(String.t(), String.t(), String.t(), map(), keyword()) :: :ok
  def record_event(repo_key, issue_id, type, payload, opts \\ []) do
    case TicketEvents.record(repo_key, issue_id, type, compact(payload), opts) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to record the #{type} event on issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  The ticket's newest open `decision.requested` event (one no answer or withdrawal names yet) whose
  title, or else question, matches `title` or `question`, ignoring case and spacing; nil when there
  is none or the events can't be read.
  """
  @spec open_decision(String.t(), String.t(), String.t() | nil, String.t() | nil) :: TicketEvents.Event.t() | nil
  def open_decision(repo_key, issue_id, title, question) do
    asked = [title, question] |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1)

    case TicketEvents.query(repo_key, issue_id, open_decisions: true, limit: 200) do
      events when is_list(events) and asked != [] ->
        events
        |> Enum.reverse()
        |> Enum.find(fn event -> Enum.any?([event.payload[:title], event.payload[:question]], &(normalize(&1) in asked)) end)

      _none ->
        nil
    end
  end

  @doc """
  Whether two texts say the same thing, ignoring case and spacing as `open_decision/4` does; a blank
  or missing text matches nothing.
  """
  @spec same_text?(term(), term()) :: boolean()
  def same_text?(left, right), do: normalize(left) != nil and normalize(left) == normalize(right)

  defp map_signal("handoff", details) do
    if value(details, :move) == true, do: phase_entered("handoff", details), else: attempt("handoff", details)
  end

  defp map_signal("blocked", details) do
    if held?(details) or is_nil(text(details, :to)), do: :mirrored, else: phase_entered("blocked", details)
  end

  defp map_signal("handoff_missing" = name, details), do: if(held?(details), do: :mirrored, else: note(name, details))

  defp map_signal(name, details) when name in @review_signals do
    if text(details, :signal) in @decision_moves, do: :mirrored, else: phase_entered(name, details)
  end

  defp map_signal("fix verdict" = name, details), do: verdict("ci_fix", text(details, :outcome), text(details, :head), name)

  defp map_signal("plan verdict" = name, details) do
    if text(details, :sub_issue),
      do: phase_entered(name, details),
      else: verdict("plan_review", text(details, :outcome), nil, name)
  end

  defp map_signal("decision returned" = name, details) do
    if text(details, :move) == "decide" and text(details, :from) == text(details, :to),
      do: :mirrored,
      else: phase_entered(name, details)
  end

  defp map_signal("merge settled" = name, details), do: phase_entered(name, Map.put_new(details, :to, "Done"))
  defp map_signal(name, details) when name in @phase_signals, do: phase_entered(name, details)
  defp map_signal(name, _details) when name in @mirrored_signals, do: :mirrored
  defp map_signal(name, details), do: note(name, details)

  defp phase_entered(name, details) do
    case text(details, :to) || text(details, :target) do
      nil ->
        note(name, details)

      to ->
        reason = if name == "review verdict", do: text(details, :outcome), else: text(details, :reason) || text(details, :outcome)

        via = text(details, :move) || text(details, :signal)
        payload = compact(%{to: to, from: text(details, :from), via: via, reason: reason, signal: name})

        {"phase.entered", payload, compact_opts(phase: to, head_sha: text(details, :head))}
    end
  end

  defp attempt(name, details) do
    case text(details, :head) do
      nil ->
        note(name, details)

      head ->
        payload = compact(%{head: head, pr_url: text(details, :pr_url), signal: name})
        {"attempt.pushed", payload, head_sha: head, idempotency: "attempt.pushed:#{head}"}
    end
  end

  defp verdict(kind, outcome, head, signal, run_id \\ nil) do
    payload = compact(%{kind: kind, outcome: outcome, head: head, signal: signal})
    {"verdict.recorded", payload, compact_opts(phase: Map.get(@kind_phases, kind), head_sha: head, run_id: string(run_id))}
  end

  defp note(name, details) do
    facts =
      details
      |> Enum.flat_map(fn {key, value} -> fact(key, value) end)
      |> Enum.sort()

    text = Enum.join([Map.get(@notes, name, name) | facts], " · ") <> " (#{name})"
    {"note", %{text: String.slice(text, 0, @note_max)}, []}
  end

  defp fact(key, value) when is_binary(value) or is_number(value) or is_boolean(value), do: ["#{key} #{value}"]
  defp fact(key, value) when is_atom(value) and not is_nil(value), do: ["#{key} #{value}"]
  defp fact(_key, _value), do: []

  # A handoff's attempt number counts the ticket's earlier pushes; a second emission for one head is
  # the same event (its key), so the number it would carry is never stored.
  defp record_mapped(repo_key, issue_id, {"attempt.pushed", payload, opts}) do
    record_event(repo_key, issue_id, "attempt.pushed", Map.put(payload, :attempt, attempts(repo_key, issue_id) + 1), opts)
  end

  defp record_mapped(repo_key, issue_id, {type, payload, opts}), do: record_event(repo_key, issue_id, type, payload, opts)
  defp record_mapped(_repo_key, _issue_id, :mirrored), do: :ok

  defp attempts(repo_key, issue_id) do
    events = RunStore.list_ticket_events(repo_key, issue_id, types: ["attempt.pushed"])
    if is_list(events), do: length(events), else: 0
  end

  defp held?(details), do: value(details, :held) == true

  defp value(details, key), do: Map.get(details, key, Map.get(details, Atom.to_string(key)))

  defp text(details, key), do: details |> value(key) |> string()

  defp string(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp string(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp string(_value), do: nil

  defp compact(payload), do: payload |> Enum.reject(fn {_key, value} -> is_nil(value) or blank?(value) end) |> Map.new()
  defp blank?(value), do: is_binary(value) and String.trim(value) == ""
  defp compact_opts(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)

  defp normalize(text) when is_binary(text) do
    case text |> String.split() |> Enum.join(" ") |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize(_text), do: nil

  defp log_error({:error, reason}, action) do
    Logger.warning("Failed to #{action}: #{inspect(reason)}")
    :ok
  end
end
