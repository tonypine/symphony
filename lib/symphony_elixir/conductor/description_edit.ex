defmodule SymphonyElixir.Conductor.DescriptionEdit do
  @moduledoc """
  A person's edit of a groomed ticket's Linear description, once Symphony wrote it, goes to the
  ticket's Conductor as an addition: there is one way to add to an ask, a message, and an edit of
  the description is taken as one rather than dropped in silence.

  `SymphonyElixir.TicketObservation` calls `observed/4` when a read of the ticket (a webhook
  delivery, a poll) finds its description changed. The edit is the description's text without
  Symphony's own blocks when it is none of Symphony's own texts (`SymphonyElixir.TicketProjection.edited/2`):
  not a projection Symphony rendered, not an ask, not an edit already sent. Symphony's own writes
  (the projection, the summary block, the Decisions section, the proofs) are therefore never taken
  for an edit. The text is recorded whole as a `message.sent` (`source: linear_description`), once
  per text (its idempotency key holds the text's hash), and the Conductor is started for it
  (`SymphonyElixir.Conductor.Message.start/3`): its turn tells what is new and folds it into the
  ask and the plan, or says why not, in its reply on the ticket. Symphony diffs nothing.

  Before the first projection (`projected.described`) the description is still the person's, and
  the projector records what they typed there as a further ask (`TicketProjection.unrecorded_ask/2`).
  """

  require Logger

  alias SymphonyElixir.Conductor.{Facts, Message}
  alias SymphonyElixir.{Messages, TicketProjection}

  @source "linear_description"
  @writer "a person, in the Linear description"

  @doc "Who the message of a description edit names as its writer."
  @spec writer() :: String.t()
  def writer, do: @writer

  @doc """
  Gives the edit `description` holds, when it is a person's (see the module doc), to the Conductor
  of the ticket `record` (held under `repo_key`) as a message. Nothing for a ticket Symphony never
  wrote the description of, and for a description that holds nothing new. Always `:ok`. `opts`:
  `conductor`, `SymphonyElixir.Conductor.Message.start/3`'s options.
  """
  @spec observed(String.t(), map(), String.t() | nil, keyword()) :: :ok
  def observed(repo_key, record, description, opts \\ []) do
    with %{issue_id: issue_id} when is_binary(issue_id) <- record,
         true <- described?(record),
         {:ok, events} <- Facts.read_events(issue_id),
         text when is_binary(text) <- TicketProjection.edited(description, events) do
      send_edit(repo_key, record, text, opts)
    end

    :ok
  end

  defp send_edit(repo_key, %{issue_id: issue_id} = record, text, opts) do
    key = "message.linear_description:" <> Base.encode16(:crypto.hash(:sha256, text), case: :lower)

    case Messages.send_message(repo_key, issue_id, text, by: @writer, source: @source, idempotency: key) do
      {:ok, message} -> Message.start(record, message, Keyword.get(opts, :conductor, []))
      {:error, reason} -> Logger.warning("Could not give a description edit to the Conductor issue_id=#{issue_id} repo_key=#{repo_key}: #{inspect(reason)}")
    end
  end

  defp described?(%{projected: %{described: true}}), do: true
  defp described?(_record), do: false
end
