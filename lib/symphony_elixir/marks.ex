defmodule SymphonyElixir.Marks do
  @moduledoc """
  A ticket's marks (facts 6 and 18 of `docs/design/director-ticket-page.md`): when a person last
  looked at it, and the note left for the next run with the run that read it.

  The look is a view mark, not history: `look/3` writes it on the ticket's record
  (`SymphonyElixir.TicketState`, its `looked` field, by person) and records no ledger event. An
  event is new when it is later than the mark, and every event is new on a ticket the person never
  looked at.

  The note is the newest `note` event a person wrote; a newer one replaces it. A run reads it when
  the prompt it builds carries the ticket's history summary (`SymphonyElixir.PromptBuilder`), which
  holds every note in full: `record_note_read/3` then records a machine `note.read` naming the note
  and the run, keyed by the note, so the first run to read it is the one kept.
  """

  require Logger

  alias SymphonyElixir.{RunStore, TicketEvents, TicketState}
  alias SymphonyElixir.TicketEvents.Event

  # The control API authenticates one shared token, so the person is the Director.
  @person "the Director"

  @type note :: %{
          id: String.t(),
          text: String.t() | nil,
          at: String.t() | nil,
          by: String.t() | nil,
          read_by: %{run_id: String.t() | nil, at: String.t() | nil} | nil
        }

  @type read :: %{looked_at: String.t() | nil, new_since_looked: non_neg_integer(), note: note() | nil}

  @doc "The one person the control API names today."
  @spec person() :: String.t()
  def person, do: @person

  @doc """
  Marks that `person` looked at the ticket `issue_identifier` now (`opts[:now]`), in the repository
  `repo_key` when given, else in whichever repository holds it. A ticket with no record is
  `{:error, :not_found}`; a store that refuses the write answers its error.
  """
  @spec look(String.t(), String.t() | nil, keyword()) ::
          {:ok, %{record: TicketState.t(), looked_at: DateTime.t()}} | {:error, term()}
  def look(issue_identifier, repo_key, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    person = Keyword.get(opts, :person, @person)

    with {:ok, record} <- find(issue_identifier, repo_key),
         looked = Map.put(record.looked, person, now),
         :ok <- RunStore.update_ticket_state(record.issue_id, %{looked: looked}) do
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
  person last looked (ISO 8601, nil when never), how many events are newer, and the note for the
  next run (`note/1`).
  """
  @spec read(map() | nil, [Event.t()]) :: read()
  def read(record, events) do
    looked_at = looked_at(record)

    %{
      looked_at: iso8601(looked_at),
      new_since_looked: Enum.count(events, &new?(&1, looked_at)),
      note: note(events)
    }
  end

  @doc """
  The note for the next run among `events`: the newest `note` a person wrote, with its text, when it
  was set and by whom, and `read_by`, the first run that read it (its `run_id` and when), nil until
  one did. Nil when no person left a note.
  """
  @spec note([Event.t()]) :: note() | nil
  def note(events) do
    case newest_note(events) do
      nil ->
        nil

      %Event{} = note ->
        %{
          id: note.id,
          text: Map.get(note.payload, :text),
          at: iso8601(note.at),
          by: Map.get(note.actor, :name),
          read_by: events |> first_read(note.id) |> read_by()
        }
    end
  end

  @doc """
  Records that the run `run_id` read the note for the next run of `repo_key`'s ticket `issue_id`,
  when the ticket has one no run read yet; best effort, since the prompt is already built.
  """
  @spec record_note_read(String.t(), String.t(), String.t()) :: :ok
  def record_note_read(repo_key, issue_id, run_id) do
    events = issue_id |> TicketEvents.query(types: ["note", "note.read"], limit: :all) |> List.wrap()

    with %Event{id: note_id} <- newest_note(events),
         nil <- first_read(events, note_id),
         {:error, reason} <- TicketEvents.record(repo_key, issue_id, "note.read", %{note_id: note_id, run_id: run_id}, run_id: run_id) do
      Logger.warning("Could not record the note's read issue_id=#{issue_id} run_id=#{run_id}: #{inspect(reason)}")
    end

    :ok
  end

  defp newest_note(events) do
    events
    |> Enum.filter(&match?(%Event{type: "note", actor: %{kind: :person}}, &1))
    |> List.last()
  end

  defp first_read(events, note_id), do: Enum.find(events, &match?(%Event{type: "note.read", payload: %{note_id: ^note_id}}, &1))

  defp read_by(nil), do: nil
  defp read_by(%Event{} = read), do: %{run_id: Map.get(read.payload, :run_id), at: iso8601(read.at)}

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

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(nil), do: nil
end
