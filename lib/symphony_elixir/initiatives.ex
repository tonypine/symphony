defmodule SymphonyElixir.Initiatives do
  @moduledoc """
  Each plan the Director approved, followed to done, for the Mac app's Initiatives
  (`GET /api/v1/initiatives`).

  The server reads Linear on Symphony's poll (`polling.interval_ms`) and caches what it read, so a
  GET makes no Linear request: one query per repository route lists the plan tickets in its scope
  (label `plan` or `breakdown`) that are not canceled and not done more than 7 days ago, with their
  sub-tickets, each sub-ticket's state and the tickets it is blocked by. Each becomes an
  `SymphonyElixir.Initiatives.Initiative`. A failed read keeps the last list.

  `list/3` adds, at GET time, what each sub-ticket waits on from the orchestrator snapshot (what
  runs) and the Inbox (what waits on the Director).

  The server tags itself `initiatives` in `SymphonyElixir.Linear.Usage`.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, Inbox}
  alias SymphonyElixir.Initiatives.Initiative
  alias SymphonyElixir.Linear.{Client, Usage}

  @initial_delay_ms 1_500
  @page_size 10
  @children_first 50
  @relations_first 10
  @recent_days 7

  @query """
  query SymphonyInitiatives($filter: IssueFilter!, $first: Int!, $after: String, $childrenFirst: Int!, $relationsFirst: Int!) {
    issues(filter: $filter, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        url
        completedAt
        state { name type }
        children(first: $childrenFirst) {
          nodes {
            id
            identifier
            title
            url
            createdAt
            state { name type }
            inverseRelations(first: $relationsFirst) {
              nodes { type issue { identifier state { name type } } }
              pageInfo { hasNextPage }
            }
          }
          pageInfo { hasNextPage }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The initiatives the server named `server` last read from Linear, empty before its first read or
  when it does not run. Kept outside the server's process, so a GET never waits on a Linear query.
  """
  @spec cached(GenServer.name()) :: [Initiative.t()]
  def cached(server \\ __MODULE__), do: :persistent_term.get(cache_key(server), [])

  @doc """
  The plan ticket (`identifier` and `title`) that has `issue_id` among its sub-tickets in
  `initiatives` (default: the cached ones), or nil when no cached plan has it.
  """
  @spec parent_of(String.t(), [Initiative.t()]) :: %{identifier: String.t() | nil, title: String.t() | nil} | nil
  def parent_of(issue_id, initiatives \\ cached()) when is_binary(issue_id) do
    Enum.find_value(initiatives, fn initiative ->
      if Enum.any?(initiative.sub_tickets, &(&1.id == issue_id)),
        do: %{identifier: initiative.identifier, title: initiative.title}
    end)
  end

  @doc "Whether `cached/1` holds a read from Linear, or no server by that name runs."
  @spec read?(GenServer.name()) :: boolean()
  def read?(server \\ __MODULE__), do: :persistent_term.get(read_key(server), false) or not running?(server)

  defp running?(server) when is_atom(server), do: Process.whereis(server) != nil
  defp running?(_server), do: true

  @doc """
  The cached initiatives, each with what its sub-tickets wait on: `snapshot`'s running tickets, the
  Inbox `inbox` lists, and the human review states of each repo (`settings_fun`).
  """
  @spec list(map(), GenServer.name(), GenServer.name(), (String.t() -> term())) :: [map()]
  def list(snapshot, server \\ __MODULE__, inbox \\ Inbox, settings_fun \\ &repo_settings/1) when is_map(snapshot) do
    running = snapshot |> Map.get(:running, []) |> MapSet.new(& &1.issue_id)
    you = snapshot |> Inbox.items(inbox) |> MapSet.new(& &1.issue_id)

    server
    |> cached()
    |> Enum.map(&Initiative.live(&1, %{running: running, you: you, settings: settings_fun.(&1.repo_key)}))
  end

  defp repo_settings(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> settings
      _error -> nil
    end
  end

  defp cache_key(server), do: {__MODULE__, :initiatives, server}
  defp read_key(server), do: {__MODULE__, :read, server}

  # Writes only on a change: a persistent term write is global.
  defp put_initiatives(state, initiatives) do
    server = Keyword.get(state.opts, :name, __MODULE__)
    if cached(server) != initiatives, do: :persistent_term.put(cache_key(server), initiatives)
    unless :persistent_term.get(read_key(server), false), do: :persistent_term.put(read_key(server), true)
  end

  @impl true
  def init(opts) do
    Usage.put_caller(:initiatives)
    timer = Process.send_after(self(), :tick, Keyword.get(opts, :initial_delay_ms, @initial_delay_ms))
    {:ok, %{opts: opts, timer: timer}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = run_once(state)
    {:noreply, %{state | timer: Process.send_after(self(), :tick, interval_ms(state))}}
  end

  defp interval_ms(state) do
    case Keyword.fetch(state.opts, :interval_ms) do
      {:ok, interval_ms} -> interval_ms
      :error -> Config.settings!().polling.interval_ms
    end
  end

  @doc false
  @spec run_once(map()) :: map()
  def run_once(state) do
    now = Keyword.get(state.opts, :now, &DateTime.utc_now/0).()

    with {:ok, repos} <- repos(state),
         {:ok, read} <- read_all(repos, now, state) do
      initiatives =
        for {repo, node} <- read,
            initiative = Initiative.from_node(node, repo.name, settings(state, repo), now),
            initiative != nil,
            do: initiative

      for %{incomplete: true} = initiative <- initiatives do
        Logger.warning("Initiatives: #{initiative.identifier} has more sub-tickets or blockers than one read returns; its list is incomplete")
      end

      put_initiatives(state, initiatives)
      state
    else
      {:error, reason} ->
        Logger.warning("Initiatives: could not read the plan tickets from Linear: #{inspect(reason)}")
        state
    end
  end

  defp read_all(repos, now, state) do
    Enum.reduce_while(repos, {:ok, []}, fn repo, {:ok, acc} ->
      case read_repo(repo, now, state) do
        {:ok, nodes} -> {:cont, {:ok, acc ++ Enum.map(nodes, &{repo, &1})}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, read} -> {:ok, Enum.uniq_by(read, fn {_repo, node} -> node["id"] end)}
      error -> error
    end
  end

  defp read_repo(repo, now, state) do
    scope_filter = Keyword.get(state.opts, :scope_filter, &Client.repo_scope_filter/1)
    since = now |> DateTime.add(-@recent_days * 86_400, :second) |> DateTime.to_iso8601()

    with {:ok, scope} <- scope_filter.(repo) do
      filter = %{
        "and" => [
          scope,
          %{"or" => Enum.map(~w(plan breakdown), &%{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => &1}}}})},
          %{"or" => [%{"state" => %{"type" => %{"nin" => ["completed", "canceled"]}}}, %{"completedAt" => %{"gte" => since}}]}
        ]
      }

      read_pages(filter, nil, [], state)
    end
  end

  defp read_pages(filter, after_cursor, acc, state) do
    variables = %{
      filter: filter,
      first: @page_size,
      after: after_cursor,
      childrenFirst: @children_first,
      relationsFirst: @relations_first
    }

    with {:ok, body} <- graphql(state, @query, variables),
         {:ok, nodes, page_info} <- issues_page(body) do
      case page_info do
        %{"hasNextPage" => true, "endCursor" => cursor} when is_binary(cursor) -> read_pages(filter, cursor, [nodes | acc], state)
        _page_info -> {:ok, [nodes | acc] |> Enum.reverse() |> Enum.concat()}
      end
    end
  end

  defp issues_page(%{"data" => %{"issues" => %{"nodes" => nodes} = issues}}) when is_list(nodes), do: {:ok, nodes, issues["pageInfo"]}
  defp issues_page(body), do: {:error, {:initiatives_query_failed, body}}

  defp repos(state) do
    case Keyword.fetch(state.opts, :repos) do
      {:ok, repos_fun} -> repos_fun.()
      :error -> configured_repos()
    end
  end

  defp configured_repos do
    with {:ok, repos} <- Config.repos() do
      {:ok, Enum.filter(repos, &Inbox.enabled?(Config.settings_for_repo!(&1.name)))}
    end
  end

  defp settings(state, repo) do
    case Keyword.fetch(state.opts, :settings_fun) do
      {:ok, settings_fun} -> settings_fun.(repo)
      :error -> Config.settings_for_repo!(repo.name)
    end
  end

  defp graphql(state, query, variables) do
    case Keyword.get(state.opts, :linear_client, &Client.graphql/3).(query, variables, []) do
      {:ok, %{"errors" => [_ | _] = errors}} -> {:error, {:linear_graphql_errors, errors}}
      result -> result
    end
  end
end
