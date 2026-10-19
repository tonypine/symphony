defmodule SymphonyElixir.Hold.Drift do
  @moduledoc """
  The tickets whose hold labels drift from the store, as `SymphonyElixir.Hold.report_drift/4` sees
  them on each poll: a hold label with no store hold, or a store hold missing its label.

  An entry keeps the drift, since when it has lasted, when a poll last saw it, and how many Setup
  checks have seen it. `record/5` says whether the drift changed, so the poll logs it once per change
  rather than on every poll, and a poll that sees the ticket agree forgets it. `observe/1` is the
  Setup check's read: each entry counts one more check, but one no poll has seen for an hour (its
  ticket left the poll) is dropped. The Setup `hold_drift` check lists the drift that lasted two
  checks.

  Entries live in a public ETS table owned by this server, so recording never waits on a process.
  Without the server, recording keeps nothing and every drift is a change.
  """

  use GenServer

  @table __MODULE__
  @stale_after_s 60 * 60

  @typedoc "Which way a ticket drifted, and for which hold."
  @type drift :: {:stray_label | :missing_label, SymphonyElixir.Hold.kind()}

  @type entry :: %{
          repo_key: String.t(),
          issue_id: String.t(),
          identifier: String.t() | nil,
          url: String.t() | nil,
          drift: drift(),
          since: DateTime.t(),
          seen_at: DateTime.t(),
          checks: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Records what a poll saw on one ticket: `:ok` (no drift) forgets it. Returns `:changed` when the
  drift is new or turned the other way, so the caller reports it, else `:unchanged`. `ticket` gives
  the ticket's `identifier` and `url` for Setup to name it; `at` is when the poll saw it.
  """
  @spec record(String.t(), String.t(), drift() | :ok, map(), DateTime.t()) :: :changed | :unchanged
  def record(repo_key, issue_id, drift, ticket \\ %{}, %DateTime{} = at \\ DateTime.utc_now()) do
    case {drift, lookup({repo_key, issue_id})} do
      {:ok, _entry} ->
        forget(repo_key, issue_id)
        :unchanged

      {drift, %{drift: drift} = entry} ->
        insert(%{entry | identifier: ticket[:identifier] || entry.identifier, url: ticket[:url] || entry.url, seen_at: at})
        :unchanged

      {drift, _new_or_turned} ->
        insert(%{
          repo_key: repo_key,
          issue_id: issue_id,
          identifier: ticket[:identifier],
          url: ticket[:url],
          drift: drift,
          since: at,
          seen_at: at,
          checks: 0
        })

        :changed
    end
  end

  @doc """
  The Setup check's read at `now`: each entry counts one more check and is returned, oldest first;
  one no poll has seen for an hour is dropped.
  """
  @spec observe(DateTime.t()) :: [entry()]
  def observe(%DateTime{} = now \\ DateTime.utc_now()) do
    @table
    |> :ets.tab2list()
    |> Enum.flat_map(fn {key, entry} ->
      if DateTime.diff(now, entry.seen_at) > @stale_after_s do
        :ets.delete(@table, key)
        []
      else
        entry = %{entry | checks: entry.checks + 1}
        insert(entry)
        [entry]
      end
    end)
    |> Enum.sort_by(&{DateTime.to_unix(&1.since, :microsecond), &1.identifier || &1.issue_id})
  rescue
    ArgumentError -> []
  end

  @doc "Every ticket's drift, as it stands, without counting a check."
  @spec entries() :: [entry()]
  def entries do
    for {_key, entry} <- :ets.tab2list(@table), do: entry
  rescue
    ArgumentError -> []
  end

  @doc "Forgets the ticket's drift, as a re-sync that put its label right does."
  @spec forget(String.t(), String.t()) :: :ok
  def forget(repo_key, issue_id) do
    :ets.delete(@table, {repo_key, issue_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forgets every ticket's drift."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, entry}] -> entry
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp insert(entry) do
    :ets.insert(@table, {{entry.repo_key, entry.issue_id}, entry})
  rescue
    ArgumentError -> false
  end
end
