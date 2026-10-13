defmodule SymphonyElixir.Inbox.References do
  @moduledoc """
  What the tickets and pull requests an Inbox item mentions are (`references`), and where the
  item's own ticket sits (`context`), resolved on the Inbox's poll (`SymphonyElixir.Inbox`) so a
  GET makes no Linear or GitHub request.

  `resolve/3` reads, once per poll for every item together:

  1. GitHub, for each pull request mentioned (`SymphonyElixir.Inbox.Mentions`): a bare `#448` or
     `PR #448` is a pull request of the item's repo. Each read is kept for two minutes across
     polls, so a pull request mentioned on every poll is not read on every poll;
  2. Linear, in one query (`SymphonyInboxReferences`): the items' own tickets with their parent and
     its sub-tickets, their pull request attachments and their relations, and every ticket
     mentioned, plus the ticket each mentioned pull request belongs to;
  3. GitHub again, for the pull requests attached to those tickets that step 1 did not read.

  A mention becomes a `ticket`, a `pull_request`, or `missing` when Symphony can't read it (another
  workspace, deleted, no access, Linear or GitHub down), with the best guess at its URL. A failed
  read never fails the item: its mentions come back `missing` and its context empty.

  A ticket reference's `waiting_on` depends on what runs, so `live/2` fills it at GET time from the
  orchestrator snapshot, in the ticket page's words (`you`, `a blocker: TP-1`, `CI`, `a review`,
  `its sub-tickets`, `a slot`; nil while it runs or once it is done).
  """

  require Logger

  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.{Decisions, Handoff, IssueSummary, PlanReview}
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.HumanActions.Collector
  alias SymphonyElixir.Inbox.Mentions
  alias SymphonyElixir.Repo.Status, as: RepoStatus

  @own_first 40
  @mentioned_first 50
  @children_first 30
  @relations_first 10
  @attachments_first 10
  @pull_requests_max 30
  @pull_request_ttl_ms 120_000
  @earlier_decisions 3
  @review_outcomes ["approve", "request_changes", "block"]
  @terminal_types ["completed", "canceled"]
  @identifier ~r/^([A-Z][A-Z0-9]*)-(\d+)$/
  @leading_identifier ~r/(?<![\w-])([A-Z][A-Z0-9]*-\d+)(?![\w-])/
  @pull_request_url ~r{/pull/(\d+)(?:[/?#]|$)}
  @attached_pull_request ~r{^https://[^/\s]+/[^/\s]+/[^/\s]+/pull/\d+(?:[/?#]|$)}
  @linear_issue_url ~r{^(https://linear\.app/[^/]+/issue/)}

  @query """
  query SymphonyInboxReferences($own: IssueFilter!, $ownFirst: Int!, $mentioned: IssueFilter!, $mentionedFirst: Int!, $withMentioned: Boolean!, $childrenFirst: Int!, $relationsFirst: Int!, $attachmentsFirst: Int!) {
    own: issues(filter: $own, first: $ownFirst) {
      nodes {
        id
        identifier
        parent {
          identifier
          title
          children(first: $childrenFirst) { nodes { createdAt state { type } } }
        }
        attachments(first: $attachmentsFirst) { nodes { url } }
        relations(first: $relationsFirst) { nodes { type relatedIssue { identifier title state { name } } } }
        inverseRelations(first: $relationsFirst) { nodes { type issue { identifier title state { name } } } }
      }
    }
    mentioned: issues(filter: $mentioned, first: $mentionedFirst) @include(if: $withMentioned) {
      nodes {
        id
        identifier
        title
        description
        url
        state { name type }
        parent { identifier title }
        attachments(first: $attachmentsFirst) { nodes { url } }
        inverseRelations(first: $relationsFirst) { nodes { type issue { identifier state { type } } } }
      }
    }
  }
  """

  @typedoc "The pull requests read from GitHub, by URL, with when (monotonic ms) each was read."
  @type cache :: %{String.t() => {integer(), {:ok, PullRequest.summary()} | {:error, term()}}}

  @typedoc "What runs and what waits on the Director at GET time, by issue id."
  @type live :: %{running: MapSet.t(String.t()), you: MapSet.t(String.t())}

  @doc false
  @spec query() :: {String.t(), map()}
  def query do
    {@query,
     %{
       ownFirst: @own_first,
       mentionedFirst: @mentioned_first,
       childrenFirst: @children_first,
       relationsFirst: @relations_first,
       attachmentsFirst: @attachments_first
     }}
  end

  @doc """
  `items` with their `references` and `context`. `nodes` are the items' issue nodes as the Inbox
  read them, by issue id (an item without one, a clarify item, has no earlier decisions). Options:

  - `:linear_client`: `(query, variables, opts) -> {:ok, body} | {:error, reason}`;
  - `:pull_request`: `(url) -> {:ok, PullRequest.summary()} | {:error, reason}`;
  - `:github_repos`: each repo key's GitHub repository (`owner/repo`, or `host/owner/repo`);
  - `:verdicts`: `(repo_key, issue_id) -> [verdict]`, the ticket's Code Review verdicts;
  - `:cache` and `:now_ms`: the last poll's pull request reads and the monotonic time now.

  Returns the items and the pull request reads to keep for the next poll.
  """
  @spec resolve([map()], %{String.t() => map()}, keyword()) :: {[map()], cache()}
  def resolve([], _nodes, _opts), do: {[], %{}}

  def resolve(items, nodes, opts) when is_list(items) and is_map(nodes) do
    ctx = %{
      opts: opts,
      github_repos: Keyword.get(opts, :github_repos, %{}),
      repo_keys: Map.new(items, &{&1.identifier, &1.repo_key}),
      mentions: Map.new(items, &{&1.issue_id, mentions(&1)})
    }

    mentioned_urls =
      for item <- items,
          {_text, {:pull_request, number}} <- ctx.mentions[item.issue_id],
          url = pull_request_url(ctx, item.repo_key, number),
          url != nil,
          do: url

    fetched = fetch_pull_requests(mentioned_urls, %{}, opts)
    pull_request_tickets = for {_at, {:ok, pr}} <- Map.values(fetched), ticket = pull_request_ticket(pr), ticket != nil, do: ticket
    ticket_mentions = for item <- items, {_text, {:ticket, identifier}} <- ctx.mentions[item.issue_id], do: identifier
    read = read_linear(items, ticket_mentions ++ pull_request_tickets, opts)

    attached = for node <- Map.values(read.own) ++ Map.values(read.mentioned), url = attached_pull_request(node), url != nil, do: url
    fetched = fetch_pull_requests(attached, fetched, opts)
    ctx = Map.merge(ctx, %{read: read, pull_requests: Map.new(fetched, fn {url, {_at, result}} -> {url, result} end)})

    items =
      Enum.map(items, fn item ->
        context = context(item, Map.get(nodes, item.issue_id), ctx)
        Map.merge(item, %{references: references(item, ctx), context: context})
      end)

    {items, fetched}
  end

  defp mentions(item), do: item |> Mentions.texts() |> Mentions.scan() |> Enum.map(&{&1, Mentions.classify(&1)})

  @doc "The GitHub repository of each repo, by repo key: a configured repo's own, else none."
  @spec github_repos([term()]) :: %{String.t() => String.t()}
  def github_repos(repos) do
    for %SystemSchema.Repo{name: name} = repo <- repos,
        slug = RepoStatus.github_repo(repo),
        slug != nil,
        into: %{},
        do: {name, slug}
  end

  @doc "`item` with each ticket reference's `waiting_on` filled from what runs and waits now (`live`)."
  @spec live(map(), live()) :: map()
  def live(item, live) do
    case Map.fetch(item, :references) do
      {:ok, references} -> %{item | references: Map.new(references, fn {text, reference} -> {text, live_reference(reference, live)} end)}
      :error -> item
    end
  end

  defp live_reference(%{facts: facts} = reference, live), do: reference |> Map.delete(:facts) |> Map.put(:waiting_on, waiting_on(facts, live))
  defp live_reference(reference, _live), do: reference

  defp waiting_on(%{state_type: type}, _live) when type in @terminal_types, do: nil

  defp waiting_on(facts, live) do
    cond do
      MapSet.member?(live.running, facts.issue_id) -> nil
      waits_on_you?(facts, live) -> "you"
      facts.open_blockers != [] -> "a blocker: " <> Enum.join(facts.open_blockers, ", ")
      true -> state_wait(normalize(facts.state))
    end
  end

  defp waits_on_you?(facts, live),
    do: MapSet.member?(live.you, facts.issue_id) or facts.state_type in ["backlog", "triage"] or PlanReview.in_state?(facts.state)

  defp state_wait(state) when state in ["merging", "ci fix"], do: "CI"
  defp state_wait(state) when state in ["code review", "qa", "epic review"], do: "a review"
  defp state_wait("waiting on sub-tickets"), do: "its sub-tickets"
  defp state_wait(_state), do: "a slot"

  # Mentions

  defp references(item, ctx) do
    Map.new(ctx.mentions[item.issue_id], fn {text, mention} -> {text, reference(mention, item, ctx)} end)
  end

  defp reference({:ticket, identifier}, item, ctx) do
    case Map.fetch(ctx.read.mentioned, identifier) do
      {:ok, node} -> ticket_reference(node, item, ctx)
      :error -> missing(linear_url_guess(item.url, identifier))
    end
  end

  defp reference({:pull_request, number}, item, ctx) do
    url = pull_request_url(ctx, item.repo_key, number)

    case Map.get(ctx.pull_requests, url) do
      {:ok, pr} -> pull_request_reference(pr, url, item.repo_key, ctx)
      _missing -> missing(url)
    end
  end

  defp missing(url), do: %{kind: "missing", url: url}

  defp linear_url_guess(item_url, identifier) when is_binary(item_url) do
    case Regex.run(@linear_issue_url, item_url) do
      [_, prefix] -> prefix <> identifier
      nil -> nil
    end
  end

  defp linear_url_guess(_item_url, _identifier), do: nil

  defp ticket_reference(node, item, ctx) do
    %{
      kind: "ticket",
      identifier: node["identifier"],
      title: node["title"],
      repo_key: ticket_repo_key(node["identifier"], item, ctx),
      state: get_in(node, ["state", "name"]),
      summary: ticket_summary(node["description"]),
      url: node["url"],
      parent: parent_reference(node["parent"]),
      pull_request: attached_pull_request_reference(node, ctx),
      waiting_on: nil,
      facts: %{
        issue_id: node["id"],
        state: get_in(node, ["state", "name"]),
        state_type: get_in(node, ["state", "type"]),
        open_blockers: open_blockers(node)
      }
    }
  end

  # A ticket in the Inbox is in its own repo; another ticket of the mentioning item's team is taken
  # to be in the item's repo; any other ticket's repo isn't known.
  defp ticket_repo_key(identifier, item, ctx) do
    case Map.fetch(ctx.repo_keys, identifier) do
      {:ok, repo_key} -> repo_key
      :error -> if team(identifier) == team(item.identifier), do: item.repo_key
    end
  end

  defp team(identifier) when is_binary(identifier) do
    case Regex.run(@identifier, identifier) do
      [_, team, _number] -> team
      nil -> nil
    end
  end

  defp team(_identifier), do: nil

  @doc """
  The one-line summary of a ticket: its Symphony summary's status line when it has one, else its
  description's first sentence, as plain text of at most 160 characters.
  """
  @spec ticket_summary(String.t() | nil) :: String.t() | nil
  def ticket_summary(description) do
    Mentions.summary(IssueSummary.status(description)) ||
      description |> IssueSummary.strip() |> Decisions.strip() |> Mentions.summary()
  end

  defp parent_reference(%{"identifier" => identifier} = parent), do: %{identifier: identifier, title: parent["title"]}
  defp parent_reference(_parent), do: nil

  defp attached_pull_request_reference(node, ctx) do
    case attached_pull_request(node) do
      nil -> nil
      url -> %{number: pull_request_number(url), url: url, checks: checks(ctx, url)}
    end
  end

  defp checks(ctx, url) do
    case Map.get(ctx.pull_requests, url) do
      {:ok, pr} -> pr.checks
      _unread -> nil
    end
  end

  defp open_blockers(node) do
    for %{"type" => "blocks", "issue" => %{"identifier" => identifier} = issue} <- relation_nodes(node, "inverseRelations"),
        get_in(issue, ["state", "type"]) not in @terminal_types,
        do: identifier
  end

  defp pull_request_reference(pr, url, repo_key, ctx) do
    ticket = pull_request_ticket(pr)
    verdicts = ticket_verdicts(repo_key, issue_id_of(ticket, ctx), ctx)

    %{
      kind: "pull_request",
      number: pr.number,
      repo_key: repo_key,
      url: pr.url || url,
      title: pr.title,
      summary: pull_request_summary(pr.body),
      review_state: review_state(pr, verdicts),
      review_rounds: rounds(verdicts, @review_outcomes),
      files: pr.changed_files,
      additions: pr.additions,
      deletions: pr.deletions,
      checks: pr.checks,
      ticket: ticket
    }
  end

  defp issue_id_of(nil, _ctx), do: nil

  defp issue_id_of(identifier, ctx) do
    node = Map.get(ctx.read.mentioned, identifier) || Enum.find(Map.values(ctx.read.own), &(&1["identifier"] == identifier))
    node && node["id"]
  end

  defp ticket_verdicts(repo_key, issue_id, ctx) when is_binary(repo_key) and is_binary(issue_id) do
    Keyword.get(ctx.opts, :verdicts, &Handoff.verdicts(&1, &2, "code_review")).(repo_key, issue_id)
  end

  defp ticket_verdicts(_repo_key, _issue_id, _ctx), do: []

  # GitHub's review decision when a person reviewed on GitHub, else Symphony's newest Code Review
  # verdict.
  defp review_state(%{state: "MERGED"}, _verdicts), do: "merged"
  defp review_state(%{state: "CLOSED"}, _verdicts), do: "closed"
  defp review_state(%{review_decision: "CHANGES_REQUESTED"}, _verdicts), do: "changes_requested"
  defp review_state(%{review_decision: "APPROVED"}, _verdicts), do: "approved"

  defp review_state(_pr, verdicts) do
    case Enum.find(verdicts, &(&1.outcome in ["approve", "request_changes"])) do
      %{outcome: "approve"} -> "approved"
      %{outcome: "request_changes"} -> "changes_requested"
      nil -> "open"
    end
  end

  # A review round is a head the reviewer judged; a second pass on the same head is the same round.
  defp rounds(verdicts, outcomes), do: verdicts |> Enum.filter(&(&1.outcome in outcomes)) |> Enum.uniq_by(& &1.head_sha) |> length()

  @doc """
  The one-line summary of a pull request: the first sentence of its body's `## This PR` section
  (after the `Nothing changes on screen.` opener, when more follows), else of its body.
  """
  @spec pull_request_summary(String.t() | nil) :: String.t() | nil
  def pull_request_summary(body) when is_binary(body) do
    case Regex.run(~r/^##\s+This PR\s*$(.*?)(?=^##\s|\z)/ms, body) do
      [_, section] -> section |> String.replace(~r/\A\s*Nothing changes on screen\.\s*(?=\S)/, "") |> Mentions.summary()
      nil -> Mentions.summary(body)
    end
  end

  def pull_request_summary(_body), do: nil

  defp pull_request_ticket(%{title: title, head_ref_name: branch}) do
    Enum.find_value([title, branch], fn
      text when is_binary(text) ->
        case Regex.run(@leading_identifier, text) do
          [_, identifier] -> identifier
          nil -> nil
        end

      _none ->
        nil
    end)
  end

  defp pull_request_url(ctx, repo_key, number) do
    case Map.get(ctx.github_repos, repo_key) do
      nil -> nil
      slug -> slug |> String.split("/") |> github_url(number)
    end
  end

  defp github_url([owner, repo], number), do: "https://github.com/#{owner}/#{repo}/pull/#{number}"
  defp github_url([host, owner, repo], number), do: "https://#{host}/#{owner}/#{repo}/pull/#{number}"
  defp github_url(_parts, _number), do: nil

  defp pull_request_number(url) do
    [_, number] = Regex.run(@pull_request_url, url)
    String.to_integer(number)
  end

  # The ticket's newest pull request: the attached GitHub pull request with the highest number.
  defp attached_pull_request(node) do
    node
    |> get_in(["attachments", "nodes"])
    |> List.wrap()
    |> Enum.map(& &1["url"])
    |> Enum.filter(&(is_binary(&1) and &1 =~ @attached_pull_request))
    |> Enum.max_by(&pull_request_number/1, fn -> nil end)
  end

  # Context

  defp context(item, node, ctx) do
    own = Map.get(ctx.read.own, item.issue_id)

    %{
      parent: own && parent_context(own["parent"]),
      pull_request: own && own_pull_request(attached_pull_request(own), item, ctx),
      blocked_by: related(own, "inverseRelations", "issue", ["blocks"]),
      blocks: related(own, "relations", "relatedIssue", ["blocks"]),
      related: Enum.uniq_by(related(own, "relations", "relatedIssue", ["related"]) ++ related(own, "inverseRelations", "issue", ["related"]), & &1.identifier),
      earlier_decisions: earlier_decisions(node)
    }
  end

  # The parent's sub-tickets in landing order (their creation order), canceled ones left out.
  defp parent_context(%{"identifier" => identifier} = parent) do
    children =
      parent
      |> get_in(["children", "nodes"])
      |> List.wrap()
      |> Enum.reject(&(get_in(&1, ["state", "type"]) == "canceled"))
      |> Enum.sort_by(&(&1["createdAt"] || ""))
      |> Enum.map(&get_in(&1, ["state", "type"]))

    %{identifier: identifier, title: parent["title"], done: Enum.count(children, &(&1 == "completed")), total: length(children), children: children}
  end

  defp parent_context(_parent), do: nil

  defp own_pull_request(nil, _item, _ctx), do: nil

  defp own_pull_request(url, item, ctx) do
    %{
      number: pull_request_number(url),
      url: url,
      checks: checks(ctx, url),
      sent_back: item.repo_key |> ticket_verdicts(item.issue_id, ctx) |> rounds(["request_changes"])
    }
  end

  defp related(nil, _connection, _field, _types), do: []

  defp related(node, connection, field, types) do
    for %{"type" => type, ^field => %{"identifier" => identifier} = issue} <- relation_nodes(node, connection), type in types do
      %{identifier: identifier, title: issue["title"], state: get_in(issue, ["state", "name"])}
    end
  end

  defp relation_nodes(node, connection), do: node |> get_in([connection, "nodes"]) |> List.wrap()

  defp earlier_decisions(%{} = node) do
    node
    |> Collector.answered_requests()
    |> Enum.take(@earlier_decisions)
    |> Enum.map(&%{&1 | at: &1.at && &1.at |> DateTime.truncate(:second) |> DateTime.to_iso8601()})
  end

  defp earlier_decisions(_node), do: []

  # Reads

  defp read_linear(items, identifiers, opts) do
    own_ids = items |> Enum.map(& &1.issue_id) |> Enum.uniq() |> Enum.take(@own_first)

    mentioned =
      for identifier <- Enum.uniq(identifiers), [_, team, number] <- [Regex.run(@identifier, identifier)], do: {team, String.to_integer(number)}

    mentioned = Enum.take(mentioned, @mentioned_first)
    {query, limits} = query()

    variables =
      Map.merge(limits, %{
        own: %{"id" => %{"in" => own_ids}},
        ownFirst: length(own_ids),
        mentioned: %{"or" => Enum.map(mentioned, fn {team, number} -> %{"team" => %{"key" => %{"eq" => team}}, "number" => %{"eq" => number}} end)},
        mentionedFirst: max(length(mentioned), 1),
        withMentioned: mentioned != []
      })

    case Keyword.fetch!(opts, :linear_client).(query, variables, []) do
      {:ok, %{"data" => %{} = data}} ->
        %{
          own: data |> nodes("own") |> Map.new(&{&1["id"], &1}),
          mentioned: data |> nodes("mentioned") |> Map.new(&{&1["identifier"], &1})
        }

      other ->
        Logger.warning("Inbox: could not read the tickets the Inbox mentions from Linear: #{inspect(other)}")
        %{own: %{}, mentioned: %{}}
    end
  end

  defp nodes(data, root) do
    for %{"id" => id, "identifier" => identifier} = node when is_binary(id) and is_binary(identifier) <- List.wrap(get_in(data, [root, "nodes"])), do: node
  end

  # Each pull request is read at most once per poll, and at most `@pull_requests_max` of them; a
  # read younger than `@pull_request_ttl_ms` is reused.
  defp fetch_pull_requests(urls, fetched, opts) do
    cache = Keyword.get(opts, :cache, %{})
    now = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    fetch = Keyword.get(opts, :pull_request, &PullRequest.fetch_summary(&1, []))

    urls
    |> Enum.uniq()
    |> Enum.reduce(fetched, fn url, acc ->
      cond do
        Map.has_key?(acc, url) or map_size(acc) >= @pull_requests_max -> acc
        fresh?(Map.get(cache, url), now) -> Map.put(acc, url, Map.fetch!(cache, url))
        true -> Map.put(acc, url, {now, fetch_pull_request(fetch, url)})
      end
    end)
  end

  defp fresh?({at, _result}, now), do: now - at < @pull_request_ttl_ms
  defp fresh?(nil, _now), do: false

  defp fetch_pull_request(fetch, url) do
    case fetch.(url) do
      {:ok, pr} ->
        {:ok, pr}

      {:error, reason} = error ->
        Logger.warning("Inbox: could not read #{url} from GitHub: #{inspect(reason)}")
        error
    end
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: nil
end
