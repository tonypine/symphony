defmodule SymphonyElixir.Situation.Recorder do
  @moduledoc """
  Writes a ticket's `situation.changed` event (`SymphonyElixir.Situation.sync/3`) when something that
  decides its situation changed, so the event follows the change and never a read.

  What it listens to, with no timer of its own:

    * an event on the ticket's ledger (`ObservabilityPubSub.subscribe_ticket_events/0`), but its own;
    * a change of the ticket's record (`ObservabilityPubSub.subscribe_ticket_records/0`);
    * the PR and CI watcher's read of a new CI state or PR state (`ticket_changed/2`);
    * each snapshot the orchestrator publishes (`snapshot_published/2`), for the runs, retries and
      slot waits it holds in memory: only the tickets whose facts changed are computed again;
    * its own start: every ticket not yet ended is computed once, from the first snapshot.

  Notices that arrive together are computed once: the first one queues a flush behind them. Nothing
  is computed before the first snapshot, since no situation can be told without it.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, RunStore, Situation, TicketState}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Computes the situation of `issue_id` again; nothing happens with no recorder running."
  @spec ticket_changed(String.t(), GenServer.server()) :: :ok
  def ticket_changed(issue_id, server \\ __MODULE__), do: GenServer.cast(server, {:ticket_changed, issue_id})

  @doc """
  Tells the recorder what the orchestrator published. Only the facts situations read cross to its
  process (`Situation.live_facts/2`), and with no recorder running nothing is built.
  """
  @spec snapshot_published(map(), GenServer.server()) :: :ok
  def snapshot_published(snapshot, server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, {:snapshot, Situation.live_facts(snapshot)}), else: :ok
  end

  @impl true
  def init(_opts) do
    :ok = ObservabilityPubSub.subscribe_ticket_events()
    :ok = ObservabilityPubSub.subscribe_ticket_records()
    send(self(), :startup)
    {:ok, %{live: nil, signature: %{}, dirty: MapSet.new(), flush_queued: false}}
  end

  @impl true
  def handle_cast({:ticket_changed, issue_id}, state), do: {:noreply, mark(state, [issue_id])}

  def handle_cast({:snapshot, live}, state) do
    signature = Situation.live_signature(live)
    changed = for id <- Map.keys(Map.merge(state.signature, signature)), Map.get(state.signature, id) != Map.get(signature, id), do: id

    {:noreply, mark(%{state | live: live, signature: signature}, changed)}
  end

  @impl true
  def handle_info(:startup, state) do
    {:noreply, mark(state, for(record <- records(), not ended?(record), do: record.issue_id))}
  end

  def handle_info({:ticket_event, %{type: "situation.changed"}}, state), do: {:noreply, state}
  def handle_info({:ticket_event, %{issue_id: issue_id}}, state), do: {:noreply, mark(state, [issue_id])}
  def handle_info({:ticket_record, _repo_key, issue_id, :changed, _fields}, state), do: {:noreply, mark(state, [issue_id])}

  def handle_info(:flush, state) do
    records = records()
    by_id = Map.new(records, &{&1.issue_id, &1})

    for issue_id <- state.dirty, %{} = record <- [Map.get(by_id, issue_id)] do
      sync(record, state.live, records)
    end

    {:noreply, %{state | dirty: MapSet.new(), flush_queued: false}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp mark(state, issue_ids) do
    state = %{state | dirty: Enum.into(issue_ids, state.dirty)}

    if MapSet.size(state.dirty) > 0 and not state.flush_queued and state.live != nil do
      send(self(), :flush)
      %{state | flush_queued: true}
    else
      state
    end
  end

  defp sync(record, live, records) do
    case Situation.sync(record, live, records) do
      {:error, reason} -> Logger.warning("situation not recorded: issue_id=#{record.issue_id} issue_identifier=#{record.issue_identifier} reason=#{inspect(reason)}")
      _written_or_unchanged -> :ok
    end
  end

  defp records, do: RunStore.list_all_ticket_states() |> List.wrap() |> Enum.map(&TicketState.normalize/1)

  defp ended?(%{phase: phase}) do
    terminal = Config.settings!().tracker.terminal_states
    Enum.any?(terminal, &(String.downcase(&1) == String.downcase(phase || "")))
  end
end
