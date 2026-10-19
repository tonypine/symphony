defmodule SymphonyElixir.Routing.PollLog do
  @moduledoc """
  Remembers each repo's last poll of Linear: the issues its route fetched, when, and since when its
  polls have fetched none.

  The orchestrator's poll task records each repo poll that worked, so the Setup routing check reads
  the issues the poll already fetched instead of asking Linear again. An entry keeps the route it
  was polled with: a poll under a changed route starts a new entry, so the issues of the old route
  are never judged against the new one (`last/2` answers nil until the new route polls).

  Entries live in a public ETS table owned by this server, so recording never waits on a process.
  Without the server (some tests), recording is a no-op and every repo has no last poll.
  """

  use GenServer

  alias SymphonyElixir.Linear.Issue

  @table __MODULE__

  @typedoc "The route fields a repo polls with: team, projects, labels and assignee."
  @type route :: {String.t() | nil, [String.t()], [String.t()], String.t() | nil}

  @type entry :: %{
          route: route(),
          issues: [Issue.t()],
          at: DateTime.t(),
          idle_since: DateTime.t() | nil
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
  Records the result of polling `repo` and returns the result unchanged. Only a poll that worked is
  recorded; a failed one leaves the last entry as it was.
  """
  @spec record(map(), result, DateTime.t()) :: result when result: term()
  def record(repo, result, %DateTime{} = at \\ DateTime.utc_now()) do
    with %{name: name} when is_binary(name) <- repo,
         {:ok, issues} when is_list(issues) <- result do
      insert(name, entry(route(repo), Enum.map(issues, &slim/1), at, last_entry(name)))
    end

    result
  end

  @doc "The last poll of `repo`, when it was polled with the route it has now, or nil."
  @spec last(map()) :: entry() | nil
  def last(%{name: name} = repo) when is_binary(name) do
    case last_entry(name) do
      %{route: route} = entry -> if route == route(repo), do: entry
      nil -> nil
    end
  end

  @doc "The route fields of `repo`, as an entry keeps them."
  @spec route(map()) :: route()
  def route(repo) do
    {Map.get(repo, :team), repo |> Map.get(:projects) |> sorted(), repo |> Map.get(:labels) |> sorted(), Map.get(repo, :assignee)}
  end

  defp entry(route, issues, at, previous) do
    idle_since =
      cond do
        issues != [] -> nil
        match?(%{route: ^route, idle_since: %DateTime{}}, previous) -> previous.idle_since
        true -> at
      end

    %{route: route, issues: issues, at: at, idle_since: idle_since}
  end

  # Routing reads only these; the rest (descriptions, comments) would only fill the table.
  defp slim(%Issue{} = issue), do: %{issue | description: nil, comments: [], sub_issues: [], blocked_by: [], rulings: [], linked_issues: []}
  defp slim(issue), do: issue

  defp sorted(nil), do: []
  defp sorted(values), do: values |> List.wrap() |> Enum.sort()

  defp last_entry(name) do
    case :ets.lookup(@table, name) do
      [{^name, entry}] -> entry
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp insert(name, entry) do
    :ets.insert(@table, {name, entry})
  rescue
    ArgumentError -> false
  end
end
