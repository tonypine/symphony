defmodule SymphonyElixir.Inbox do
  @moduledoc """
  Everything that waits on the Director, for the Mac app's Inbox (`GET /api/v1/inbox`) and the
  state API's `waiting_on_you`.

  The server reads Linear on Symphony's poll (`polling.interval_ms`) and caches what it read, so a
  GET makes no Linear request:

  1. one light query per repository route lists the issues in its scope that sit in `Plan Review`
     (`SymphonyElixir.PlanReview`) or that the run store holds (`SymphonyElixir.Hold`, `Blocked`
     or `Needs Decision`, whether or not the board shows the label), each with its `updatedAt` and
     the time its newest comment was last edited;
  2. only the issues whose pair changed since the last read (or that are new) are read in full:
     their description, comments, state history, labels, attachments and sub-tickets
     (`SymphonyElixir.HumanActions.Collector.read_more_pages/2` reads past the first page);
  3. each becomes an `SymphonyElixir.Inbox.Item`, with, for a ticket no request or plan review
     covers, the access or dispatch-loop hold its store record carries;
  4. `SymphonyElixir.Inbox.References` adds what each item's text mentions (`references`) and where
     its ticket sits (`context`), in one more Linear query for every item together and a GitHub read
     per pull request. The quality gate's held and skipped tickets, which `items/2` lists from the
     orchestrator snapshot, are resolved here too and kept by issue id.

  `items/2` adds the quality gate's holds and skips from the orchestrator snapshot (kind
  `clarify`), drops an issue that is running or that the orchestrator saw leave the state the read
  listed it in (`Plan Review` for a plan) since, and sorts the list oldest first. A held ticket is
  kept whatever state the orchestrator reports: the hold is what waits on the Director. A failed
  read keeps the last list.

  Each read also reconciles the read tickets' `Needs Decision` holds
  (`SymphonyElixir.NeedsDecisionHold`): a decision request pauses its ticket in place, and the
  person's answer — or the run's withdrawal — clears the hold so the ticket
  continues, and the answer is written into the description's Decisions section
  (`SymphonyElixir.Decisions`). Those tickets are listed by their store hold wherever in the workflow
  they sit, never by the label, which is only the hold's projection.

  The server tags itself `inbox` in `SymphonyElixir.Linear.Usage`.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, Hold, NeedsDecisionHold, Orchestrator, PlanReview}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.Collector
  alias SymphonyElixir.Inbox.{Item, References}
  alias SymphonyElixir.Linear.{Client, Usage}

  @initial_delay_ms 1_000
  @page_size 50
  @detail_batch 25
  @comment_last 30
  @history_first 50
  @children_first 50
  @attachments_first 10
  @snapshot_timeout_ms 1_000

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
        description
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
  `snapshot`, without an issue that is running or that the orchestrator saw leave `Plan Review`,
  oldest first (an item with no known wait last). A ticket a hold pauses in place is kept
  whatever state the orchestrator saw it in: the hold itself is what waits on the Director.
  """
  @spec items(map(), GenServer.name()) :: [Item.t()]
  def items(snapshot, server) when is_map(snapshot) do
    running_ids = snapshot |> Map.get(:running, []) |> MapSet.new(& &1.issue_id)
    watched_states = snapshot |> Map.get(:watching, []) |> Map.new(&{&1.issue_id, &1.state})

    resolved = :persistent_term.get(clarify_key(server), %{})

    clarify =
      snapshot
      |> clarify_items()
      |> Enum.map(&Map.merge(&1, Map.get(resolved, &1.issue_id, %{})))

    items =
      server
      |> cached()
      |> Enum.reject(&(MapSet.member?(running_ids, &1.issue_id) or left_review?(&1, watched_states)))
      |> Enum.map(&%{&1 | state: Map.get(watched_states, &1.issue_id, &1.state)})
      |> Enum.concat(clarify)
      |> Enum.uniq_by(& &1.issue_id)
      |> Enum.sort_by(&{is_nil(&1.waiting_since), sort_key(&1.waiting_since), &1.identifier || ""})

    live = %{running: running_ids, you: MapSet.new(items, & &1.issue_id)}
    Enum.map(items, &References.live(&1, live))
  end

  defp clarify_items(snapshot) do
    (Map.get(snapshot, :awaiting_clarification, []) ++ Map.get(snapshot, :skipped, []))
    |> Enum.filter(&is_binary(Map.get(&1, :issue_id)))
    |> Enum.uniq_by(& &1.issue_id)
    |> Enum.map(&Item.from_quality_gate/1)
  end

  # Whether the orchestrator saw the ticket leave what the read listed it for: `Plan Review`, or for
  # a plan, which waits in its repo's own plan review state, where the read found it. A hold is what
  # waits on the Director, whatever the state.
  defp left_review?(%{kind: :blocked}, _watched_states), do: false

  defp left_review?(item, watched_states) do
    case Map.fetch(watched_states, item.issue_id) do
      {:ok, state} -> not (PlanReview.in_state?(state) or listed_plan?(item, state))
      :error -> false
    end
  end

  defp listed_plan?(item, state), do: item.kind == :plan and same_state?(state, item.state)

  defp same_state?(state, other) when is_binary(state) and is_binary(other),
    do: String.downcase(String.trim(state)) == String.downcase(String.trim(other))

  defp same_state?(_state, _other), do: false

  defp sort_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp sort_key(_at), do: 0

  defp cache_key(server), do: {__MODULE__, :items, server}
  defp read_key(server), do: {__MODULE__, :read, server}
  defp clarify_key(server), do: {__MODULE__, :clarify, server}

  # Writes only on a change: a persistent term write is global.
  defp put_items(state, items, clarify) do
    server = Keyword.get(state.opts, :name, __MODULE__)
    if cached(server) != items, do: :persistent_term.put(cache_key(server), items)
    if :persistent_term.get(clarify_key(server), %{}) != clarify, do: :persistent_term.put(clarify_key(server), clarify)
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
      sweep_holds(listed, nodes, state)

      items =
        for {repo, light} <- listed,
            %{node: node} <- [Map.get(nodes, light["id"])],
            item = Item.from_node(node, repo.name, settings(state, repo), lookups(state)),
            item != nil,
            do: item

      github_repos = github_repos(repos, state)
      {items, clarify, pull_requests} = resolve_references(items, nodes, github_repos, state)
      put_items(state, items, clarify)
      Map.merge(state, %{nodes: nodes, pull_requests: pull_requests, github_repos: {repos, github_repos}})
    else
      {:error, reason} ->
        Logger.warning("Inbox: could not read what waits on you from Linear: #{inspect(reason)}")
        state
    end
  end

  # What the items mention and where their tickets sit (`References`), in one Linear query for all of
  # them, the quality gate's held and skipped tickets included: those are listed from the
  # orchestrator snapshot at GET time, so theirs are kept by issue id.
  defp resolve_references(items, nodes, github_repos, state) do
    item_ids = MapSet.new(items, & &1.issue_id)
    clarify = state |> snapshot() |> clarify_items() |> Enum.reject(&MapSet.member?(item_ids, &1.issue_id))

    opts =
      Keyword.take(state.opts, [:pull_request, :verdicts, :now_ms]) ++
        [
          linear_client: linear_client(state),
          github_repos: github_repos,
          cache: Map.get(state, :pull_requests, %{})
        ]

    {resolved, pull_requests} = References.resolve(items ++ clarify, Map.new(nodes, fn {id, entry} -> {id, entry.node} end), opts)
    {resolved_items, resolved_clarify} = Enum.split(resolved, length(items))
    {resolved_items, Map.new(resolved_clarify, &{&1.issue_id, Map.take(&1, [:references, :context])}), pull_requests}
  end

  # Reading a local checkout's GitHub repository runs git, so it is read again only when the repos change.
  defp github_repos(repos, state) do
    case {Keyword.fetch(state.opts, :github_repos), Map.get(state, :github_repos)} do
      {{:ok, github_repos}, _cached} -> github_repos
      {:error, {^repos, github_repos}} -> github_repos
      {:error, _stale} -> References.github_repos(repos)
    end
  end

  defp snapshot(state) do
    case Keyword.get(state.opts, :snapshot, fn -> Orchestrator.snapshot(Orchestrator, @snapshot_timeout_ms) end).() do
      %{} = snapshot -> snapshot
      _unavailable -> %{}
    end
  end

  # Decision requests are read here, with their comments and history, so the read that lists them
  # is also the one that reconciles their hold: a request an agent posted sets the `Needs Decision`
  # hold, and one the person answered (or the run withdrew) clears it, so the ticket continues in
  # place. The tickets are swept a repo at a time, so each route resolves its settings once.
  defp sweep_holds(listed, nodes, state) do
    listed
    |> Enum.group_by(&elem(&1, 0), &Map.get(nodes, elem(&1, 1)["id"]))
    |> Enum.each(fn {repo, entries} ->
      repo_nodes = for %{node: %{} = node} <- entries, do: node
      NeedsDecisionHold.sweep(repo.name, repo_nodes, [settings: settings(state, repo)] ++ Keyword.take(state.opts, [:tracker]))
    end)

    :ok
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
    held_issue_ids = Keyword.get(state.opts, :held_issue_ids, &Hold.held_issue_ids/1)

    with {:ok, scope} <- scope_filter.(repo),
         {:ok, held} <- held(held_issue_ids, repo) do
      list_pages(%{"and" => [scope, %{"or" => list_conditions(settings(state, repo), held)}]}, nil, [], state)
    end
  end

  defp held(held_issue_ids, repo) do
    case held_issue_ids.(repo.name) do
      {:ok, ids} -> {:ok, ids}
      {:error, reason} -> {:error, {:hold_store_unreadable, reason}}
    end
  end

  # The plans under review, plus the issues the store holds: a hold pauses a ticket in its phase, so
  # it is listed by its id wherever in the workflow it sits. The store is the truth for a hold and
  # the label only its projection, so a hold whose label went missing is still read, and its answer
  # still clears it. `Item.from_node/4` reads each one's store record and keeps only the holds a
  # person lifts.
  defp list_conditions(settings, held) do
    reviews = for plan_review when is_binary(plan_review) <- [PlanReview.state(settings)], do: %{"state" => %{"name" => %{"eqIgnoreCase" => plan_review}}}
    reviews ++ [%{"id" => %{"in" => held}}]
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

  defp lookups(state), do: %{hold: Keyword.get(state.opts, :hold, &Hold.get(&1, &2, :blocked))}

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
