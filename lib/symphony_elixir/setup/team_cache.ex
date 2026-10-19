defmodule SymphonyElixir.Setup.TeamCache do
  @moduledoc """
  Each Linear team's workflow states and labels, and the workspace's projects and teams, for the
  Setup checks.

  The first read of a team's states (or labels, or of the projects and teams) asks the tracker
  once; later reads, by any check, answer from the cache until it is `ttl_ms` old, so a run costs
  one states request and one labels request per team, and one projects request. `SymphonyElixir.Setup` keeps the cache for the refresh interval and empties it
  on a refresh and after a Setup fix. A failed read is not cached.
  """

  alias SymphonyElixir.Tracker

  defstruct [:table, :ttl_ms, :fetch, :clock]

  @typedoc "A read of one team from the tracker."
  @type read :: (String.t() -> {:ok, list()} | {:error, term()})

  @typedoc "A read of the whole workspace from the tracker."
  @type workspace_read :: (-> {:ok, Tracker.projects_and_teams()} | {:error, term()})

  @type t :: %__MODULE__{
          table: :ets.tid(),
          ttl_ms: non_neg_integer(),
          fetch: %{states: read(), labels: read(), projects_and_teams: workspace_read()},
          clock: (-> integer())
        }

  @doc """
  A new cache, owned by the calling process. Options: `:ttl_ms`, `:tracker` (a module with
  `team_workflow_states/1`, `team_labels/1` and `projects_and_teams/0`, `SymphonyElixir.Tracker`
  by default) and `:clock` (monotonic milliseconds).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)

    %__MODULE__{
      table: :ets.new(__MODULE__, [:set, :public]),
      ttl_ms: Keyword.fetch!(opts, :ttl_ms),
      fetch: %{
        states: &tracker.team_workflow_states/1,
        labels: &tracker.team_labels/1,
        projects_and_teams: &tracker.projects_and_teams/0
      },
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    }
  end

  @doc "The workflow states of `team`."
  @spec states(t(), String.t()) :: {:ok, [Tracker.workflow_state()]} | {:error, term()}
  def states(%__MODULE__{} = cache, team) when is_binary(team), do: read(cache, :states, team)

  @doc "The labels `team` can use."
  @spec labels(t(), String.t()) :: {:ok, [Tracker.label()]} | {:error, term()}
  def labels(%__MODULE__{} = cache, team) when is_binary(team), do: read(cache, :labels, team)

  @doc "The workspace's projects and teams."
  @spec projects_and_teams(t()) :: {:ok, Tracker.projects_and_teams()} | {:error, term()}
  def projects_and_teams(%__MODULE__{} = cache), do: read(cache, :projects_and_teams, :workspace)

  @doc "Forgets every team and the projects, so the next read asks the tracker again."
  @spec invalidate(t()) :: :ok
  def invalidate(%__MODULE__{table: table}) do
    :ets.delete_all_objects(table)
    :ok
  end

  @doc "Deletes the cache's table."
  @spec delete(t()) :: :ok
  def delete(%__MODULE__{table: table}) do
    :ets.delete(table)
    :ok
  end

  defp read(cache, kind, team) do
    now = cache.clock.()

    case :ets.lookup(cache.table, {kind, team}) do
      [{_key, fetched_at, value}] when now - fetched_at < cache.ttl_ms -> {:ok, value}
      _missing_or_expired -> fetch(cache, kind, team, now)
    end
  end

  defp fetch(cache, kind, team, now) do
    with {:ok, value} <- call(cache.fetch[kind], team) do
      :ets.insert(cache.table, {{kind, team}, now, value})
      {:ok, value}
    end
  end

  defp call(read, :workspace), do: read.()
  defp call(read, team), do: read.(team)
end
