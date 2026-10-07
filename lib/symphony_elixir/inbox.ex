defmodule SymphonyElixir.Inbox do
  @moduledoc """
  Everything that waits on the Director, for the Mac app's Inbox (`GET /api/v1/inbox`) and the
  state API's `waiting_on_you`.

  The server reads Linear on Symphony's poll (`polling.interval_ms`) and caches what it read, so a
  GET makes no Linear request:

  1. one light query per repository route lists the issues in its scope that sit in `In Review`
     or the Human Review state (`SymphonyElixir.HumanReview.review_states/1`), each with its
     `updatedAt` and the time its newest comment was last edited;
  2. only the issues whose pair changed since the last read (or that are new) are read in full:
     their comments, state history, labels, attachments and sub-tickets
     (`SymphonyElixir.HumanActions.Collector.read_more_pages/2` reads past the first page);
  3. each becomes an `SymphonyElixir.Inbox.Item`, with what Symphony knows locally about its PR
     (the CI poller's last conclusion, the acceptance gate's latest verdict).

  `items/2` adds the quality gate's holds and skips from the orchestrator snapshot (kind
  `clarify`), drops an issue that is running or that the orchestrator saw leave the review states
  since, and sorts the list oldest first. A failed read keeps the last list.

  The server tags itself `inbox` in `SymphonyElixir.Linear.Usage`.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.AcceptanceGate.Agreement
  alias SymphonyElixir.{CiPoller, Config, HumanReview}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.Collector
  alias SymphonyElixir.Inbox.Item
  alias SymphonyElixir.Linear.{Client, Usage}

  @initial_delay_ms 1_000
  @page_size 50
  @detail_batch 25
  @comment_last 30
  @history_first 50
  @children_first 50
  @attachments_first 10

  @list_query """
  query SymphonyInboxList($filter: IssueFilter!, $first: Int!, $after: String) {
    issues(filter: $filter, first: $first, after: $after) {
      nodes {
        id
        updatedAt
        comments(last: 1, orderBy: updatedAt) { nodes { updatedAt } }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @detail_query """
  query SymphonyInboxIssues($filter: IssueFilter!, $first: Int!, $commentLast: Int!, $historyFirst: Int!, $childrenFirst: Int!, $attachmentsFirst: Int!) {
    issues(filter: $filter, first: $first) {
      nodes {
        id
        identifier
        title
        url
        state { name }
        labels { nodes { name } }
        attachments(first: $attachmentsFirst) { nodes { url } }
        children(first: $childrenFirst) { nodes { identifier title url createdAt state { name } } }
        comments(last: $commentLast, orderBy: createdAt) {
          nodes { id body createdAt parent { id } }
          pageInfo { hasPreviousPage startCursor }
        }
        history(first: $historyFirst) {
          nodes { createdAt fromState { name } toState { name } }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether the Inbox reads Linear for these settings: a Linear tracker."
  @spec enabled?(Schema.t()) :: boolean()
  def enabled?(%Schema{tracker: %{kind: "linear"}}), do: true
  def enabled?(_settings), do: false

  @doc """
  The items the server named `server` last read from Linear, empty before its first read or when it
  does not run. Kept outside the server's process, so a GET never waits on a Linear query.
  """
  @spec cached(GenServer.name()) :: [Item.t()]
  def cached(server \\ __MODULE__), do: :persistent_term.get(cache_key(server), [])

  @doc """
  Whether `cached/1` holds a read from Linear: false while the server named `server` runs but has
  not read Linear yet, true once it has or when no server by that name runs.
  """
  @spec read?(GenServer.name()) :: boolean()
  def read?(server \\ __MODULE__), do: :persistent_term.get(read_key(server), false) or not running?(server)

  defp running?(server) when is_atom(server), do: Process.whereis(server) != nil
  defp running?(_server), do: true

  @doc """
  What waits on the Director now: the cached items and the quality gate's holds and skips in
  `snapshot`, without an issue that is running or that the orchestrator saw leave the review
  states, oldest first (an item with no known wait last).
  """
  @spec items(map(), GenServer.name()) :: [Item.t()]
  def items(snapshot, server) when is_map(snapshot) do
    running_ids = snapshot |> Map.get(:running, []) |> MapSet.new(& &1.issue_id)
    watched_states = snapshot |> Map.get(:watching, []) |> Map.new(&{&1.issue_id, &1.state})

    clarify =
      (Map.get(snapshot, :awaiting_clarification, []) ++ Map.get(snapshot, :skipped, []))
      |> Enum.filter(&is_binary(Map.get(&1, :issue_id)))
      |> Enum.uniq_by(& &1.issue_id)
      |> Enum.map(&Item.from_quality_gate/1)

    server
    |> cached()
    |> Enum.reject(fn item ->
      MapSet.member?(running_ids, item.issue_id) or
        (Map.has_key?(watched_states, item.issue_id) and not HumanReview.review_state?(watched_states[item.issue_id]))
    end)
    |> Enum.map(&%{&1 | state: Map.get(watched_states, &1.issue_id, &1.state)})
    |> Enum.concat(clarify)
    |> Enum.uniq_by(& &1.issue_id)
    |> Enum.sort_by(&{is_nil(&1.waiting_since), sort_key(&1.waiting_since), &1.identifier || ""})
  end

  defp sort_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp sort_key(_at), do: 0

  defp cache_key(server), do: {__MODULE__, :items, server}
  defp read_key(server), do: {__MODULE__, :read, server}

  # Writes only on a change: a persistent term write is global.
  defp put_items(state, items) do
    server = Keyword.get(state.opts, :name, __MODULE__)
    if cached(server) != items, do: :persistent_term.put(cache_key(server), items)
    unless :persistent_term.get(read_key(server), false), do: :persistent_term.put(read_key(server), true)
  end

  @impl true
  def init(opts) do
    Usage.put_caller(:inbox)
    timer = Process.send_after(self(), :tick, Keyword.get(opts, :initial_delay_ms, @initial_delay_ms))
    {:ok, %{opts: opts, nodes: %{}, timer: timer}}
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
    with {:ok, repos} <- repos(state),
         {:ok, listed} <- list_all(repos, state),
         {:ok, nodes} <- read_changed(listed, state) do
      items =
        for {repo, light} <- listed,
            %{node: node} <- [Map.get(nodes, light["id"])],
            item = Item.from_node(node, repo.name, settings(state, repo), lookups(state)),
            item != nil,
            do: item

      put_items(state, items)
      %{state | nodes: nodes}
    else
      {:error, reason} ->
        Logger.warning("Inbox: could not read what waits on you from Linear: #{inspect(reason)}")
        state
    end
  end

  defp list_all(repos, state) do
    Enum.reduce_while(repos, {:ok, []}, fn repo, {:ok, acc} ->
      case list_repo(repo, state) do
        {:ok, nodes} -> {:cont, {:ok, acc ++ Enum.map(nodes, &{repo, &1})}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, listed} -> {:ok, Enum.uniq_by(listed, fn {_repo, node} -> node["id"] end)}
      error -> error
    end
  end

  defp list_repo(repo, state) do
    scope_filter = Keyword.get(state.opts, :scope_filter, &Client.repo_scope_filter/1)

    with {:ok, scope} <- scope_filter.(repo) do
      states = Enum.map(HumanReview.review_states(settings(state, repo)), &%{"state" => %{"name" => %{"eqIgnoreCase" => &1}}})
      list_pages(%{"and" => [scope, %{"or" => states}]}, nil, [], state)
    end
  end

  defp list_pages(filter, after_cursor, acc, state) do
    with {:ok, body} <- graphql(state, @list_query, %{filter: filter, first: @page_size, after: after_cursor}),
         {:ok, nodes, page_info} <- issues_page(body) do
      case page_info do
        %{"hasNextPage" => true, "endCursor" => cursor} when is_binary(cursor) -> list_pages(filter, cursor, [nodes | acc], state)
        _page_info -> {:ok, [nodes | acc] |> Enum.reverse() |> Enum.concat()}
      end
    end
  end

  defp issues_page(%{"data" => %{"issues" => %{"nodes" => nodes} = issues}}) when is_list(nodes), do: {:ok, nodes, issues["pageInfo"]}
  defp issues_page(body), do: {:error, {:inbox_query_failed, body}}

  # An issue is read again only when it or one of its comments changed since the last read.
  defp read_changed(listed, state) do
    cached =
      Map.new(listed, fn {_repo, light} -> {light["id"], Map.get(state.nodes, light["id"])} end)

    changed =
      for {_repo, light} <- listed,
          match?(nil, cached[light["id"]]) or cached[light["id"]].fingerprint != fingerprint(light),
          do: light

    fingerprints = Map.new(changed, &{&1["id"], fingerprint(&1)})

    changed
    |> Enum.map(& &1["id"])
    |> Enum.chunk_every(@detail_batch)
    |> Enum.reduce_while({:ok, Map.reject(cached, fn {_id, entry} -> is_nil(entry) end)}, fn ids, {:ok, acc} ->
      case read_details(ids, state) do
        {:ok, nodes} ->
          {:cont, {:ok, Enum.reduce(nodes, acc, &Map.put(&2, &1["id"], %{fingerprint: fingerprints[&1["id"]], node: &1}))}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp fingerprint(light) do
    comment_at = light |> get_in(["comments", "nodes"]) |> List.wrap() |> Enum.map(& &1["updatedAt"]) |> List.first()
    {light["updatedAt"], comment_at}
  end

  defp read_details(ids, state) do
    variables = %{
      filter: %{"id" => %{"in" => ids}},
      first: length(ids),
      commentLast: @comment_last,
      historyFirst: @history_first,
      childrenFirst: @children_first,
      attachmentsFirst: @attachments_first
    }

    with {:ok, body} <- graphql(state, @detail_query, variables),
         {:ok, nodes, _page_info} <- issues_page(body) do
      Collector.read_more_pages(nodes, linear_client(state))
    end
  end

  defp lookups(state) do
    %{
      ci: Keyword.get(state.opts, :ci, &ci_conclusion/2),
      gate: Keyword.get(state.opts, :gate, &Agreement.latest/2)
    }
  end

  defp ci_conclusion(issue_id, repo_key), do: issue_id |> CiPoller.observed_head(repo_key: repo_key) |> then(&(&1 && &1.conclusion))

  defp repos(state) do
    case Keyword.fetch(state.opts, :repos) do
      {:ok, repos_fun} -> repos_fun.()
      :error -> configured_repos()
    end
  end

  defp configured_repos do
    with {:ok, repos} <- Config.repos() do
      {:ok, Enum.filter(repos, &enabled?(Config.settings_for_repo!(&1.name)))}
    end
  end

  defp settings(state, repo) do
    case Keyword.fetch(state.opts, :settings_fun) do
      {:ok, settings_fun} -> settings_fun.(repo)
      :error -> Config.settings_for_repo!(repo.name)
    end
  end

  defp linear_client(state), do: Keyword.get(state.opts, :linear_client, &Client.graphql/3)

  defp graphql(state, query, variables) do
    case linear_client(state).(query, variables, []) do
      {:ok, %{"errors" => [_ | _] = errors}} -> {:error, {:linear_graphql_errors, errors}}
      result -> result
    end
  end
end
