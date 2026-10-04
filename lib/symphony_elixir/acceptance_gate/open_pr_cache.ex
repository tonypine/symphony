defmodule SymphonyElixir.AcceptanceGate.OpenPrCache do
  @moduledoc """
  Remembers the GitHub answer listing a repository's open PRs, for the acceptance gate's context
  (`SymphonyElixir.AcceptanceGate.Context`), so a gate built again on the same heads doesn't ask
  GitHub again.

  Entries live in a public ETS table owned by this server, named after it, so a lookup never
  waits on a process. The table holds at most 256 entries: inserting into a full table empties
  it first. Without the server (some tests), nothing is cached and every fetch asks again.
  """

  use GenServer

  @max_entries 256

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @impl true
  def init(table) do
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc """
  The value cached under `key` in `table`, or the result of `fun`, cached when it is `{:ok, value}`.
  An error is returned as it is and not cached.
  """
  @spec fetch(atom(), term(), (-> {:ok, value} | {:error, term()})) :: {:ok, value} | {:error, term()}
        when value: term()
  def fetch(table, key, fun) when is_atom(table) and is_function(fun, 0) do
    case lookup(table, key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        with {:ok, value} <- fun.() do
          insert(table, key, value)
          {:ok, value}
        end
    end
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp insert(table, key, value) do
    if :ets.info(table, :size) >= @max_entries, do: :ets.delete_all_objects(table)
    :ets.insert(table, {key, value})
  rescue
    ArgumentError -> false
  end
end
