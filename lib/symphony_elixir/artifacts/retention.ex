defmodule SymphonyElixir.Artifacts.Retention do
  @moduledoc """
  Removes the bytes of a finished ticket's artifacts once `ledger.artifact_retention_days` have
  passed, keeping their metadata and the events that name them (`SymphonyElixir.Artifacts.expire/1`).

  It runs every `workspaces.cleanup.interval_ms`. Each run reads the retention again, so a change in
  Settings applies without a restart, and looks only at the artifacts that are not expired and were
  captured longer than the retention ago. It asks the tracker for their tickets' current states
  (`SymphonyElixir.Tracker.fetch_issue_states_by_ids/1`, one request per 50 tickets), and none
  when no artifact is old enough: Symphony's stored phase is refreshed only at startup, so it can't
  say whether a ticket is finished.

  A ticket is finished when the tracker says it is in one of its repository's terminal states and
  its newest ledger event is older than the retention: it has been finished at least that long. An
  artifact is expired only when every ticket in its `tickets` is finished, so a screenshot a finished
  ticket shares with an active one keeps its bytes. A ticket the tracker doesn't return, and every
  ticket of a request that failed, keeps its artifacts, and the run logs why.

  `run/1` is one run; `now:` (a clock), `tracker:` (a module with `fetch_issue_states_by_ids/1`) and
  `artifacts:` (a module with `list/1` and `expire/1`) replace the real ones in tests.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Artifacts, Config, RunStore, Tracker}
  alias SymphonyElixir.Linear.Usage

  @batch_size 50
  @default_interval_ms 3_600_000
  @seconds_per_day 86_400

  @type opt :: {:name, GenServer.name()} | {:now, (-> DateTime.t())} | {:tracker, module()} | {:artifacts, module()}

  @typedoc "The ids a run expired, and the ids of the old enough artifacts it kept."
  @type result :: %{expired: [String.t()], kept: [String.t()]}

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {:ok, schedule(%{opts: opts})}
  end

  @impl true
  def handle_info(:run, state) do
    run(state.opts)
    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "Expires the artifacts whose tickets have all been finished for longer than the retention."
  @spec run([opt()]) :: result()
  def run(opts) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()
    cutoff = DateTime.add(now, -Config.artifact_retention_days() * @seconds_per_day, :second)
    store = Keyword.get(opts, :artifacts, Artifacts)

    case store.list(expired: false) do
      artifacts when is_list(artifacts) ->
        artifacts
        |> Enum.filter(&before?(&1.captured_at, cutoff))
        |> expire_finished(cutoff, Keyword.get(opts, :tracker, Tracker), store)

      {:error, reason} ->
        Logger.warning("Artifact retention skipped: the artifacts could not be listed reason=#{inspect(reason)}")
        %{expired: [], kept: []}
    end
  end

  defp expire_finished([], _cutoff, _tracker, _store), do: %{expired: [], kept: []}

  defp expire_finished(artifacts, cutoff, tracker, store) do
    tickets = artifacts |> Enum.flat_map(& &1.tickets) |> Enum.uniq()
    states = states(tickets, tracker)
    terminal = terminal_states(tickets)
    finished = tickets |> Enum.filter(&finished?(&1, states, terminal, cutoff)) |> MapSet.new()

    {old, kept} = Enum.split_with(artifacts, fn artifact -> Enum.all?(artifact.tickets, &MapSet.member?(finished, &1)) end)

    %{expired: Enum.flat_map(old, &expire(&1, store)), kept: Enum.map(kept, & &1.id)}
  end

  # The tracker's issues by id. A ticket missing from the answer, or from a request that failed, is
  # left out, so it keeps its artifacts.
  defp states(tickets, tracker) do
    Usage.with_caller(:artifact_retention, fn ->
      tickets
      |> Enum.map(& &1.issue_id)
      |> Enum.uniq()
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce(%{}, &Map.merge(&2, fetch_states(&1, tracker)))
    end)
  end

  defp fetch_states(issue_ids, tracker) do
    case tracker.fetch_issue_states_by_ids(issue_ids) do
      {:ok, issues} ->
        found = Map.new(issues, &{&1.id, &1})

        for issue_id <- issue_ids, not Map.has_key?(found, issue_id) do
          Logger.info("Artifact retention keeps the artifacts of issue_id=#{issue_id}: the tracker did not return the ticket")
        end

        found

      {:error, reason} ->
        Logger.warning("Artifact retention keeps the artifacts of issue_ids=#{Enum.join(issue_ids, ",")}: their states could not be read reason=#{inspect(reason)}")

        %{}
    end
  end

  defp terminal_states(tickets) do
    tickets
    |> Enum.map(& &1.repo_key)
    |> Enum.uniq()
    |> Map.new(fn repo_key ->
      case Config.settings_for_repo(repo_key) do
        {:ok, settings} ->
          {repo_key, MapSet.new(settings.tracker.terminal_states, &normalize_state/1)}

        {:error, reason} ->
          Logger.warning("Artifact retention keeps the artifacts of repo_key=#{repo_key}: its settings could not be read reason=#{inspect(reason)}")
          {repo_key, MapSet.new()}
      end
    end)
  end

  defp finished?(%{repo_key: repo_key, issue_id: issue_id}, states, terminal, cutoff) do
    case Map.get(states, issue_id) do
      %{state: state} when is_binary(state) ->
        MapSet.member?(terminal[repo_key], normalize_state(state)) and quiet_since?(repo_key, issue_id, cutoff)

      _missing ->
        false
    end
  end

  # Whether every ledger event of the ticket, so its newest, is older than `cutoff`: a ticket that is
  # terminal now and has recorded nothing since has been finished at least that long. Events that
  # can't be read keep its artifacts.
  defp quiet_since?(repo_key, issue_id, cutoff) do
    events = RunStore.list_ticket_events(repo_key, issue_id, [])
    is_list(events) and Enum.all?(events, &before?(&1.at, cutoff))
  end

  defp expire(%{id: id} = artifact, store) do
    case store.expire(id) do
      {:ok, _artifact} ->
        Logger.info("Artifact retention expired artifact_id=#{id} issue_ids=#{issue_ids(artifact)}")
        [id]

      {:error, reason} ->
        Logger.warning("Artifact retention could not expire artifact_id=#{id} issue_ids=#{issue_ids(artifact)} reason=#{inspect(reason)}")
        []
    end
  end

  defp issue_ids(artifact), do: Enum.map_join(artifact.tickets, ",", & &1.issue_id)

  defp before?(%DateTime{} = at, cutoff), do: DateTime.compare(at, cutoff) == :lt

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()

  defp schedule(state) do
    Process.send_after(self(), :run, interval_ms())
    state
  end

  defp interval_ms do
    case Config.system() do
      {:ok, system_config} -> system_config.workspace.lifecycle.gc_interval_ms
      {:error, _reason} -> @default_interval_ms
    end
  end
end
