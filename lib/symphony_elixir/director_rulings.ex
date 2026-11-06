defmodule SymphonyElixir.DirectorRulings do
  @moduledoc """
  The Director's ruling on a ticket no Question asked about, from its page in the Mac app (TP-1357):
  `record/3` records the ruling as one of the ticket's decisions, and `decisions/2` reads them as the
  ticket's Decisions card shows them.

  A ruling is the same decision a Decide answer records (`SymphonyElixir.Decisions.record/3`): it
  goes into the ticket's store record first, then into the Decisions section of its description in
  Linear, and every later run, review and QA pass reads it among the ticket's decisions
  (`Decisions.stored/2`, `Decisions.prompt_section/1`). Its key is `ruling-director-<id>`, so the
  record keeps it as a ruling: a later ruling with the same text is skipped. A ruling a person writes
  in a Linear comment is left as it was.

  The ticket is one Symphony tracks: it has a record (`SymphonyElixir.TicketState`) that is not
  removed, found by identifier or id in every configured repository's records. A ruling is refused
  (`{:error, {:invalid, message}}`) when its text is blank or longer than a decision's answer holds,
  and (`{:error, {:conflict, message}}`, the reason the app shows) when Symphony doesn't track the
  ticket or the ticket already has a decision with the same text. A write the tracker or the store
  refuses is `{:error, {:linear, message}}`, the message saying why in the app's words. A Decisions
  section that lost its end marker refuses nothing: the record holds the ruling, which is what runs,
  reviews and the Decisions card read, and nobody is asked to repair the section (TP-1369).

  Once recorded, at once and without waiting for the next read of Linear: the record's change is
  announced (`SymphonyElixirWeb.ObservabilityPubSub.broadcast_ticket_record_changed/3`), the
  ticket's events get a `decision.recorded` by the Director with no request (the timeline's "The
  Director ruled", the prompt's "Ruled … by the Director"), the audit log a `director_move`
  (`record_decision`), and the orchestrator is asked to poll the ticket's repository.
  """

  require Logger

  alias SymphonyElixir.{AuditLog, Decisions, Orchestrator, RunStore, TicketMoves, TicketSignals, TicketState}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @director {:person, "the Director"}
  @title "Ruling by the Director"
  @question "No question asked: the Director recorded this ruling on the ticket page."
  @max_chars 600

  @type error :: {:invalid, String.t()} | {:conflict, String.t()} | {:linear, String.t()}

  @doc "The most characters a ruling's text holds: a decision's answer bound."
  @spec max_chars() :: pos_integer()
  def max_chars, do: @max_chars

  @doc """
  Records `text` as the Director's ruling on the ticket `identifier` (identifier or id), as the
  moduledoc says. Answers the ticket's decisions after it, each with its `D<n>` label.

  Options: `:tracker` (default `SymphonyElixir.Tracker`), `:store` (default
  `SymphonyElixir.RunStore`), `:orchestrator` (asked to poll again, default
  `SymphonyElixir.Orchestrator`), `:audit_log` (the audit log's options), `:records` (the tracked
  records, default every record in the run store) and `:today` (the ruling's date, default today).
  """
  @spec record(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, error()}
  def record(identifier, text, opts \\ []) when is_binary(identifier) do
    with {:ok, text} <- text(text),
         {:ok, ticket} <- find(records(opts), identifier),
         :ok <- new_ruling(ticket, text, opts),
         entry = Decisions.entry(key(), Keyword.get_lazy(opts, :today, &Date.utc_today/0), @title, @question, text),
         :ok <- write(ticket, entry, opts) do
      :ok = ObservabilityPubSub.broadcast_ticket_record_changed(ticket.repo_key, ticket.issue_id, [:decisions])
      record_action(ticket, entry, opts)
      Orchestrator.request_refresh(Keyword.get(opts, :orchestrator, Orchestrator), ticket.repo_key, due: :now)
      Logger.info("Director recorded a decision issue_identifier=#{ticket.issue_identifier}")

      {:ok, ticket |> json(opts) |> Map.put(:action, "record_decision")}
    end
  end

  @doc """
  The decisions recorded on the ticket `identifier` (identifier or id), in the order they were
  recorded. `{:error, {:conflict, message}}` for a ticket Symphony doesn't track. Options as for
  `record/3`.
  """
  @spec decisions(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def decisions(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, ticket} <- find(records(opts), identifier), do: {:ok, json(ticket, opts)}
  end

  defp text(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:error, {:invalid, "A decision needs text"}}
      String.length(text) > @max_chars -> {:error, {:invalid, "A decision holds at most #{@max_chars} characters; this one has #{String.length(text)}"}}
      true -> {:ok, text}
    end
  end

  defp text(_text), do: {:error, {:invalid, "A decision needs text"}}

  defp records(opts) do
    opts
    |> Keyword.get_lazy(:records, fn -> List.wrap(with({:error, _reason} <- RunStore.list_all_ticket_states(), do: [])) end)
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.filter(&(is_binary(&1.issue_id) and is_binary(&1.repo_key) and is_nil(&1.removed_at)))
  end

  defp find(records, name) do
    name = String.trim(name)

    case Enum.find(records, &(&1.issue_id == name or same_identifier?(&1.issue_identifier, name))) do
      nil -> {:error, {:conflict, TicketMoves.untracked_reason(:ruling, name)}}
      record -> {:ok, record}
    end
  end

  defp same_identifier?(identifier, name) when is_binary(identifier), do: String.upcase(identifier) == String.upcase(name)
  defp same_identifier?(_identifier, _name), do: false

  # A decision with the same text is already recorded: the ruling would add nothing.
  defp new_ruling(ticket, text, opts) do
    case Enum.find(stored(ticket, opts), &(normalize(&1.answer) == normalize(text))) do
      nil -> :ok
      decision -> {:error, {:conflict, "#{ticket.issue_identifier} already has this decision (#{decision.id})."}}
    end
  end

  defp stored(ticket, opts) do
    Decisions.stored(%{id: ticket.issue_id, repo_key: ticket.repo_key, description: nil}, Keyword.take(opts, [:store]))
  end

  defp normalize(text), do: text |> String.replace("\\", "") |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.downcase()

  defp key, do: "ruling-director-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp write(ticket, entry, opts) do
    case Decisions.record(ticket.issue_id, [entry], [repo_key: ticket.repo_key] ++ Keyword.take(opts, [:tracker, :store])) do
      :ok -> :ok
      # The record took the ruling before the section was read, and runs read it from the record.
      {:error, :decisions_block_unterminated} -> :ok
      {:error, reason} -> {:error, {:linear, write_failure(ticket, reason)}}
    end
  end

  # The reason a write failed, in the words the app shows; the raw reason is in the log.
  defp write_failure(ticket, reason) do
    if missing_key?(reason) do
      "Symphony has no Linear API key, so it couldn't record the decision on #{ticket.issue_identifier}."
    else
      "Symphony couldn't record the decision on #{ticket.issue_identifier}, so nothing changed. Try again in a moment."
    end
  end

  defp missing_key?(:missing_linear_api_token), do: true
  defp missing_key?({_kind, :missing_linear_api_token}), do: true
  defp missing_key?(_reason), do: false

  defp record_action(ticket, entry, opts) do
    %{
      event_type: "director_move",
      move: "record_decision",
      repo_key: ticket.repo_key,
      issue_id: ticket.issue_id,
      issue_identifier: ticket.issue_identifier,
      comment: entry.answer
    }
    |> AuditLog.record(Keyword.get(opts, :audit_log, []))
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record director_move audit event: issue_id=#{ticket.issue_id} reason=#{inspect(reason)}")
    end

    payload = %{answer: entry.answer, title: entry.title, key: entry.key}
    TicketSignals.record_event(ticket.repo_key, ticket.issue_id, "decision.recorded", payload, actor: @director)
  end

  defp json(ticket, opts) do
    %{
      issue_identifier: ticket.issue_identifier,
      decisions:
        for decision <- stored(ticket, opts) do
          %{id: decision.id, date: date(decision.date), title: decision.title, question: decision.question, answer: decision.answer, scope: decision.scope}
        end
    }
  end

  defp date(%Date{} = date), do: Date.to_iso8601(date)
  defp date(date), do: date
end
