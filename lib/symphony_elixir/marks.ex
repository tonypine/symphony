defmodule SymphonyElixir.Marks do
  @moduledoc """
  A ticket's marks (facts 6 and 18 of `docs/design/director-ticket-page.md`): when a person last
  looked at it, and how many of the messages written to it no run read yet.

  The look is a view mark, not history: `look/3` writes it on the ticket's record
  (`SymphonyElixir.TicketState`, its `looked` field, by person) and records no ledger event. An
  event is new when it is later than the mark, and every event is new on a ticket the person never
  looked at.

  The messages are what a person wrote to the ticket (`SymphonyElixir.Messages`): the ticket read
  carries how many no run read yet (`unread_messages`). The Mac app release before messages reads
  one `note`: it is served from the newest unread message until the app's ticket page reads the
  messages, and then removed.
  """

  alias SymphonyElixir.{Messages, RunStore, TicketState}
  alias SymphonyElixir.TicketEvents.Event

  @person Messages.person()

  @type note :: %{
          id: String.t(),
          text: String.t() | nil,
          at: String.t() | nil,
          by: String.t() | nil,
          read_by: %{run_id: String.t() | nil, at: String.t() | nil} | nil
        }

  @type read :: %{
          looked_at: String.t() | nil,
          new_since_looked: non_neg_integer(),
          unread_messages: non_neg_integer(),
          note: note() | nil
        }

  @doc "The one person the control API names today."
  @spec person() :: String.t()
  def person, do: @person

  @doc """
  Marks that `person` looked at the ticket `issue_identifier` now (`opts[:now]`), in the repository
  `repo_key` when given, else in whichever repository holds it. A ticket with no record is
  `{:error, :not_found}`, also when the record goes between the read and the write; a store that
  refuses the write answers its error. `opts[:write]` replaces the store's write (tests).
  """
  @spec look(String.t(), String.t() | nil, keyword()) ::
          {:ok, %{record: TicketState.t(), looked_at: DateTime.t()}} | {:error, term()}
  def look(issue_identifier, repo_key, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    person = Keyword.get(opts, :person, @person)
    write = Keyword.get(opts, :write, &RunStore.update_ticket_state/2)

    with {:ok, record} <- find(issue_identifier, repo_key),
         looked = Map.put(record.looked, person, now),
         :ok <- written(write.(record.issue_id, %{looked: looked})) do
      {:ok, %{record: %{record | looked: looked}, looked_at: now}}
    end
  end

  @doc "When `person` last looked at the ticket of `record`, nil when they never did."
  @spec looked_at(map() | nil, String.t()) :: DateTime.t() | nil
  def looked_at(record, person \\ @person), do: record |> TicketState.normalize() |> Map.fetch!(:looked) |> Map.get(person)

  @doc "Whether `event` is new to a person who last looked at `looked_at`: later than it, or never looked."
  @spec new?(Event.t(), DateTime.t() | nil) :: boolean()
  def new?(%Event{}, nil), do: true
  def new?(%Event{at: %DateTime{} = at}, %DateTime{} = looked_at), do: DateTime.compare(at, looked_at) == :gt
  def new?(%Event{}, %DateTime{}), do: false

  @doc """
  The marks of the ticket of `record` holding `events`, as the ticket read carries them: when the
  person last looked (ISO 8601, nil when never), how many events are newer, how many messages no
  run read yet, and the older app's `note` (`note/1`).
  """
  @spec read(map() | nil, [Event.t()]) :: read()
  def read(record, events) do
    looked_at = looked_at(record)
    unread = Messages.unread(events)

    %{
      looked_at: iso8601(looked_at),
      new_since_looked: Enum.count(events, &new?(&1, looked_at)),
      unread_messages: length(unread),
      note: note(events)
    }
  end

  @doc """
  The note the Mac app release before messages reads, from `events`: the newest message no run
  read yet, with its text, when it was written and by whom, and `read_by` nil. Nil when every
  message was read.
  """
  @spec note([Event.t()]) :: note() | nil
  def note(events) do
    case events |> Messages.unread() |> List.last() do
      nil -> nil
      %Event{} = message -> %{id: message.id, text: Map.get(message.payload, :text), at: iso8601(message.at), by: Map.get(message.actor, :name), read_by: nil}
    end
  end

  defp find(issue_identifier, repo_key) do
    RunStore.list_all_ticket_states()
    |> List.wrap()
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.find(&(&1.issue_identifier == issue_identifier and is_binary(&1.issue_id) and (is_nil(repo_key) or &1.repo_key == repo_key)))
    |> case do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  # The record went between the read and the write: the ticket is no longer there.
  defp written({:error, :ticket_state_not_found}), do: {:error, :not_found}
  defp written(result), do: result

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(nil), do: nil
end
