defmodule SymphonyElixir.Repo.FetchLog do
  @moduledoc """
  Remembers each repo's last `git fetch origin` before a dispatch: when it ran and
  whether it worked.

  `SymphonyElixir.Workspace` records the fetch of a repo's worktree source (or the
  clone Symphony keeps of a `workspace.source` repo) and `SymphonyElixir.WorkflowSource`
  the fetch of the checkout its `WORKFLOW.md` is read from. `GET /api/v1/repos`
  reports the last one per repo.

  Entries live in a public ETS table owned by this server, so recording never waits
  on a process. Without the server (some tests), recording is a no-op and every repo
  has no last fetch.
  """

  use GenServer

  @table __MODULE__

  @type entry :: %{at: DateTime.t(), result: :ok | {:error, term()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  @doc "Records a fetch result for `repo_key` and returns the result unchanged."
  @spec record(String.t() | nil, result, DateTime.t()) :: result when result: term()
  def record(repo_key, result, %DateTime{} = at \\ DateTime.utc_now()) do
    if is_binary(repo_key), do: insert(repo_key, %{at: at, result: normalize(result)})
    result
  end

  @doc "The last recorded fetch for `repo_key`, or nil."
  @spec last(String.t()) :: entry() | nil
  def last(repo_key) when is_binary(repo_key) do
    case :ets.lookup(@table, repo_key) do
      [{^repo_key, entry}] -> entry
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp insert(repo_key, entry) do
    :ets.insert(@table, {repo_key, entry})
  rescue
    ArgumentError -> false
  end

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _output}), do: :ok
  defp normalize({:error, reason, output}), do: {:error, {reason, output}}
  defp normalize({:error, reason}), do: {:error, reason}
end
