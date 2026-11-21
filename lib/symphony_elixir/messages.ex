defmodule SymphonyElixir.Messages do
  @moduledoc """
  What a person writes to a ticket: each message is a `message.sent` event of the ticket's ledger
  (`SymphonyElixir.TicketEvents`), with its text, who wrote it and when. None replaces or hides
  another.

  A message is given to one run as new. The next run of the ticket, of any kind, gets every message
  no other run was given, oldest first, at the top of its prompt (`prepend_unread/4`, which
  `SymphonyElixir.PromptBuilder`, `SymphonyElixir.ReviewAgent` and the QA passes call), and Symphony
  records a machine `message.read` naming the message and the run (`record_read/4`), keyed by the
  message. A later run reads it in the
  ticket's history (`SymphonyElixir.TicketEvents.Brief`), not as a new instruction. A run is given
  only the messages written before it started, however many prompts it builds, so a message sent
  while it works waits for the next run. Sending never starts, stops or reorders a run.

  A groomed ticket's messages go to its Conductor instead, while the Conductor and its `message`
  junction are on (`SymphonyElixir.Conductor.Message`): the Conductor answers each one and passes
  on what a run needs, so no run is given a person's message there and no `message.read` is
  written (`prepend_unread/4`).

  Symphony's own notes (`note`) are not messages: they keep their type and are never given to a
  run as the person's words.

  Before messages, a person left one note for the next run (a person's `note`, read by a
  `note.read`). `migrate/1` turns each ticket's note into one `message.sent` at the note's time,
  with its `message.read` when a run had read it, once, at startup.
  """

  require Logger

  alias SymphonyElixir.Conductor.Message, as: ConductorMessage
  alias SymphonyElixir.{RunStore, TicketEvents}
  alias SymphonyElixir.TicketEvents.{Event, Summary}

  # The control API authenticates one shared token, so the person is the Director.
  @person "the Director"
  @types ["message.sent", "message.read"]
  @marker "messages_from_notes_v1"
  @migrated "message.migrated:"

  @typedoc "Who read a message: the run's id, its title (`Implementation run 2`) and when."
  @type read :: %{run_id: String.t() | nil, run: String.t(), at: String.t() | nil}

  @doc "The one person the control API names today."
  @spec person() :: String.t()
  def person, do: @person

  @doc "The run store marker the migration of notes sets once it is done."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Records `text` as a message to `repo_key`'s ticket `issue_id`, written by `opts[:by]` (default
  the Director), as `TicketEvents.record/5` answers.
  """
  @spec send_message(String.t(), String.t(), String.t(), keyword()) :: {:ok, Event.t()} | {:error, term()}
  def send_message(repo_key, issue_id, text, opts \\ []),
    do: TicketEvents.record(repo_key, issue_id, "message.sent", %{text: text}, actor: {:person, Keyword.get(opts, :by, @person)})

  @doc "The messages among `events`, oldest first."
  @spec messages([Event.t()]) :: [Event.t()]
  def messages(events), do: Enum.filter(events, &message?/1)

  @doc "The messages among `events` no run was given yet, oldest first."
  @spec unread([Event.t()]) :: [Event.t()]
  def unread(events) do
    read = read_ids(events)
    events |> messages() |> Enum.reject(&Map.has_key?(read, &1.id))
  end

  @doc """
  The messages among `events` the run `run_id` is given as new, oldest first: those no other run
  was given, written before the run started (its `run.started` among `events`). A message written
  while the run works is not injected into it, even when the run builds a prompt again (each step
  of a stepped pass, a retry): it waits for the next run. A run that builds its prompt twice (a
  Codex run sent the compact one, the next step of a pass) is given the same messages each time.
  """
  @spec for_run([Event.t()], String.t() | nil) :: [Event.t()]
  def for_run(events, run_id) do
    read = read_ids(events)
    started = started_at(events, run_id)

    events
    |> messages()
    |> Enum.filter(fn %Event{} = message ->
      case Map.fetch(read, message.id) do
        {:ok, reader} -> reader == run_id
        :error -> written_before?(message, started)
      end
    end)
  end

  @doc """
  The messages among `events` the ticket's history shows the run `run_id`, oldest first: every
  message, less those no run was given yet that were written after the run started. Those wait for
  the next run, so the run in progress never reads them, even as history. With no run (nil), or a
  run with no `run.started` among `events`, every message.
  """
  @spec in_history([Event.t()], String.t() | nil) :: [Event.t()]
  def in_history(events, run_id) do
    read = read_ids(events)
    started = started_at(events, run_id)

    events
    |> messages()
    |> Enum.filter(&(Map.has_key?(read, &1.id) or written_before?(&1, started)))
  end

  # When the run `run_id` started, from its `run.started` among `events`; nil when they hold none.
  defp started_at(events, run_id) do
    Enum.find_value(events, fn
      %Event{type: "run.started", payload: %{run_id: ^run_id}, at: at} -> at
      _event -> nil
    end)
  end

  defp written_before?(%Event{at: %DateTime{} = at}, %DateTime{} = started), do: DateTime.compare(at, started) != :gt
  defp written_before?(_message, _started), do: true

  @doc """
  Records that the run `run_id` was given `messages` of `repo_key`'s ticket `issue_id`, one
  `message.read` each; best effort, since the prompt is already built.
  """
  @spec record_read(String.t(), String.t(), [Event.t()], String.t()) :: :ok
  def record_read(repo_key, issue_id, messages, run_id) do
    for %Event{id: id} <- messages do
      with {:error, reason} <- TicketEvents.record(repo_key, issue_id, "message.read", %{message_id: id, run_id: run_id}, run_id: run_id) do
        Logger.warning("Could not record a message's read issue_id=#{issue_id} run_id=#{run_id}: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc """
  Who read the message `message` among `events` (the ticket's `message.read` and `run.started`
  events, at least): the run, as a person reads it, and when. Nil while no run read it.
  """
  @spec read_by(Event.t(), [Event.t()]) :: read() | nil
  def read_by(%Event{} = message, events) do
    case read_event(message, events) do
      nil -> nil
      %Event{} = read -> %{run_id: Map.get(read.payload, :run_id), run: run_title(Map.get(read.payload, :run_id), events), at: iso8601(read.at)}
    end
  end

  @doc "The `message.read` among `events` that gave `message` to a run, the first one; nil while none did."
  @spec read_event(Event.t(), [Event.t()]) :: Event.t() | nil
  def read_event(%Event{id: id}, events), do: Enum.find(events, &match?(%Event{type: "message.read", payload: %{message_id: ^id}}, &1))

  @doc "A run's title among `events`, from its `run.started`: `Implementation run 2`, else `a run`."
  @spec run_title(String.t() | nil, [Event.t()]) :: String.t()
  def run_title(run_id, events) do
    case is_binary(run_id) && Enum.find(events, &match?(%Event{type: "run.started", run_id: ^run_id}, &1)) do
      %Event{payload: payload} -> Summary.run_name(payload)
      _unknown -> "a run"
    end
  end

  @doc """
  `prompt` with the messages of `repo_key`'s ticket `issue_id` that the run `run_id` is given as new
  (`for_run/2`) at its top, under `prompt_section/1`, and their reads recorded for that run. A
  prompt with no run records no read; a store that can't be read gives no message, so the run still
  starts and they wait for the next. Every run's prompt goes through it: `SymphonyElixir.PromptBuilder`
  for the runs it builds, `SymphonyElixir.ReviewAgent` for Code Review, `SymphonyElixir.QaAgent` and
  `SymphonyElixir.QaAgent.Steps` for QA. On a ticket whose messages the Conductor answers
  (`SymphonyElixir.Conductor.Message.due?/2`) the prompt is left as it is and no read is recorded.
  """
  @spec prepend_unread(String.t(), String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def prepend_unread(prompt, repo_key, issue_id, run_id) when is_binary(repo_key) and is_binary(issue_id) do
    if ConductorMessage.due?(issue_id), do: prompt, else: prepend_for_run(prompt, repo_key, issue_id, run_id)
  end

  def prepend_unread(prompt, _repo_key, _issue_id, _run_id), do: prompt

  defp prepend_for_run(prompt, repo_key, issue_id, run_id) do
    events = issue_id |> RunStore.list_ticket_events(types: ["run.started" | @types]) |> List.wrap() |> Enum.filter(&is_struct(&1, Event))

    case for_run(events, run_id) do
      [] ->
        prompt

      messages ->
        if is_binary(run_id), do: record_read(repo_key, issue_id, messages, run_id)
        prepend(prompt, messages)
    end
  end

  @doc "`prompt` with `messages` at its top under `prompt_section/1`; `prompt` itself when there are none."
  @spec prepend(String.t(), [Event.t()]) :: String.t()
  def prepend(prompt, messages) do
    case prompt_section(messages) do
      nil -> prompt
      section -> section <> "\n\n" <> prompt
    end
  end

  @doc """
  The section at the top of a run's prompt that gives it `messages` (oldest first), or nil when
  there are none: the heading says they come from the person, and each says when it was written.
  The text is the person's own, so it is not wrapped as untrusted input.
  """
  @spec prompt_section([Event.t()]) :: String.t() | nil
  def prompt_section([]), do: nil

  def prompt_section(messages) do
    count = length(messages)
    noun = if count == 1, do: "a message", else: "#{count} messages"

    lines =
      Enum.map(messages, fn %Event{} = message ->
        "### #{writer(message.actor)} wrote, #{time(message.at)}\n\n" <> (Map.get(message.payload, :text) || "")
      end)

    Enum.join(
      [
        "## Messages from the person",
        "",
        "The person steering this ticket wrote #{noun} that no run has read yet, oldest first. " <>
          "They are instructions for this run: read them before anything else, act on them, and " <>
          "say in your first lines how you took them into account. Later runs see them in the ticket's history."
        | Enum.flat_map(lines, &["", &1])
      ],
      "\n"
    )
  end

  @doc "Whether `event` is a message a person wrote."
  @spec message?(Event.t()) :: boolean()
  def message?(%Event{type: "message.sent"}), do: true
  def message?(_event), do: false

  @doc """
  Turns each ticket's note for the next run into a message, once (see the module doc): the newest
  `note` a person wrote on each ticket becomes a `message.sent` at the note's time and by its
  writer, and a `note.read` naming it becomes the message's `message.read` at the read's time. Each
  message is keyed by its note, so a second pass writes nothing. The run store marker
  `#{@marker}` is set once every ticket is done; a ticket whose write fails is retried at the next
  start. `opts[:store]` replaces `SymphonyElixir.RunStore` (tests).
  """
  @spec migrate(keyword()) :: {:ok, non_neg_integer()} | :done | {:error, term()}
  def migrate(opts \\ []) do
    store = Keyword.get(opts, :store, RunStore)

    with nil <- store.get_marker(@marker),
         records when is_list(records) <- store.list_all_ticket_states() do
      migrate_all(store, records)
    else
      %DateTime{} -> :done
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrate_all(store, records) do
    results =
      for %{issue_id: issue_id, repo_key: repo_key} <- records,
          is_binary(issue_id) and is_binary(repo_key),
          do: migrate_ticket(store, repo_key, issue_id)

    case Enum.filter(results, &match?({:error, _reason}, &1)) do
      [] ->
        _ = store.put_marker(@marker, DateTime.utc_now())
        migrated = Enum.count(results, &(&1 == :migrated))
        if migrated > 0, do: Logger.info("Turned #{migrated} ticket note(s) into messages")
        {:ok, migrated}

      [{:error, reason} | _rest] = failed ->
        Logger.warning("Could not turn #{length(failed)} ticket note(s) into messages: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp migrate_ticket(store, repo_key, issue_id) do
    with events when is_list(events) <- store.list_ticket_events(issue_id, types: ["note", "note.read"]),
         %Event{id: note_id} = note <- events |> Enum.filter(&match?(%Event{type: "note", actor: %{kind: :person}}, &1)) |> List.last() do
      migrate_note(repo_key, issue_id, note, Enum.find(events, &match?(%Event{type: "note.read", payload: %{note_id: ^note_id}}, &1)))
    else
      {:error, reason} -> {:error, reason}
      nil -> :none
    end
  end

  defp migrate_note(repo_key, issue_id, note, read) do
    by = Map.get(note.actor, :name) || @person
    opts = [actor: {:person, by}, at: note.at, idempotency: @migrated <> note.id]

    with {:ok, message} <- TicketEvents.record(repo_key, issue_id, "message.sent", %{text: Map.get(note.payload, :text) || ""}, opts),
         :ok <- migrate_read(repo_key, issue_id, message, read) do
      :migrated
    end
  end

  defp migrate_read(_repo_key, _issue_id, _message, nil), do: :ok

  defp migrate_read(repo_key, issue_id, message, %Event{} = read) do
    run_id = Map.get(read.payload, :run_id)

    case TicketEvents.record(repo_key, issue_id, "message.read", %{message_id: message.id, run_id: run_id}, run_id: run_id, at: read.at) do
      {:ok, _read} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The message ids a run was given, each with the first run that was.
  defp read_ids(events) do
    events
    |> Enum.filter(&match?(%Event{type: "message.read"}, &1))
    |> Enum.reverse()
    |> Map.new(&{Map.get(&1.payload, :message_id), Map.get(&1.payload, :run_id)})
  end

  @doc "Who wrote a message, as the prompt and the history say it: `the Director`, else the writer's name."
  @spec writer(map()) :: String.t()
  def writer(%{name: name}) when is_binary(name) and name != "", do: name
  def writer(_actor), do: @person

  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp time(_at), do: "at an unknown time"

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(_at), do: nil
end
