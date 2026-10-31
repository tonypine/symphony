defmodule SymphonyElixir.Inbox.References do
  @moduledoc """
  What the tickets and pull requests an Inbox row mentions are (`references`), and where the row's
  own ticket sits (`context`), resolved on each read of the Inbox (`SymphonyElixir.Inbox`) from the
  tickets' records: no Linear request.

  `resolve/3` reads, for every row together:

  1. the tickets' records, for each ticket mentioned (`SymphonyElixir.Inbox.Mentions`) and the row's
     own ticket: its title, phase, summary, parent, blockers, the answers it was given and its pull
     request (`pr_watch`);
  2. GitHub, for each pull request mentioned (a bare `#448` or `PR #448` is a pull request of the
     row's repo) and for the pull request of each ticket the row names. A row's reads are kept,
     keyed by its Question (by its kind and ticket for a row without one), and GitHub is read again
     only when the row changed since; a failed read is tried again after two minutes.

  A mention becomes a `ticket`, a `pull_request`, or `missing` when Symphony holds no record of it
  (another workspace, a ticket Symphony never saw) or GitHub can't read it, with the best guess at
  its URL. A failed read never fails the row: its mentions come back `missing`.

  A ticket reference's `waiting_on` depends on what runs, so `live/2` fills it at read time from the
  orchestrator snapshot, in the ticket page's words (`you`, `a blocker: TP-1`, `CI`, `a review`,
  `its sub-tickets`, `a slot`; nil while it runs or once it is done).
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.{Decisions, Handoff, IssueSummary, PlanReview, TicketState}
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Inbox.Mentions
  alias SymphonyElixir.Repo.Status, as: RepoStatus

  @pull_requests_max 30
  @retry_ms 120_000
  @earlier_decisions 3
  @review_outcomes ["approve", "request_changes", "block"]
  @terminal_types ["completed", "canceled"]
  @backlog_types ["backlog", "triage"]
  @leading_identifier ~r/(?<![\w-])([A-Z][A-Z0-9]*-\d+)(?![\w-])/
  @pull_request_url ~r{/pull/(\d+)(?:[/?#]|$)}
  @linear_issue_url ~r{^(https://linear\.app/[^/]+/issue/)}

  @typedoc "A pull request read from GitHub, with when (monotonic ms) it was read."
  @type read :: {integer(), {:ok, PullRequest.summary()} | {:error, term()}}

  @typedoc "What runs and what waits on the Director at read time, by issue id."
  @type live :: %{running: MapSet.t(String.t()), you: MapSet.t(String.t())}

  @doc """
  `items` with their `references` and `context`, from `records` (the tickets' records) and GitHub.
  Options:

  - `:name`: the Inbox whose rows' reads are kept (default `SymphonyElixir.Inbox`);
  - `:pull_request`: `(url) -> {:ok, PullRequest.summary()} | {:error, reason}`;
  - `:github_repos`: each repo key's GitHub repository (`owner/repo`, or `host/owner/repo`);
  - `:verdicts`: `(repo_key, issue_id) -> [verdict]`, the ticket's Code Review verdicts;
  - `:settings_fun`: a repo key's settings, for its terminal states;
  - `:now_ms`: the monotonic time now.
  """
  @spec resolve([map()], [map()], keyword()) :: [map()]
  def resolve(items, records, opts) when is_list(items) and is_list(records) do
    records = Enum.map(records, &TicketState.normalize/1)
    name = Keyword.get(opts, :name, SymphonyElixir.Inbox)

    ctx = %{
      opts: opts,
      now: Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end),
      github_repos: Keyword.get_lazy(opts, :github_repos, &configured_github_repos/0),
      by_id: Map.new(records, &{&1.issue_id, &1}),
      by_identifier: records |> Enum.filter(&is_binary(&1.issue_identifier)) |> Map.new(&{&1.issue_identifier, &1}),
      records: records
    }

    cache = :persistent_term.get(cache_key(name), %{})

    {items, rows} =
      Enum.map_reduce(items, %{}, fn item, rows ->
        mentions = mentions(item)
        key = row_key(item)
        {pull_requests, entry} = row_reads(item, mentions, Map.get(cache, key), ctx)
        row_ctx = Map.put(ctx, :pull_requests, Map.new(pull_requests, fn {url, {_at, result}} -> {url, result} end))
        context = context(item, Map.get(ctx.by_id, item.issue_id), row_ctx)
        {Map.merge(item, %{references: references(item, mentions, row_ctx), context: context}), Map.put(rows, key, entry)}
      end)

    # A persistent term write is global: written only when a row's reads changed.
    if rows != cache, do: :persistent_term.put(cache_key(name), rows)
    items
  end

  defp cache_key(name), do: {__MODULE__, :rows, name}

  # A row is known by its Question, or by its kind and ticket when it has none.
  defp row_key(%{review: %{question_id: id}}) when is_binary(id), do: {:question, id}
  defp row_key(item), do: {item.kind, item.issue_id}

  # The row's GitHub reads: the kept ones while the row and the pull requests it names are the same
  # and none failed more than `@retry_ms` ago, else read again.
  defp row_reads(item, mentions, cached, ctx) do
    fingerprint = :erlang.phash2({Map.delete(item, :waiting_since), own_urls(item, mentions, ctx)})

    case cached do
      {^fingerprint, pull_requests} ->
        if Enum.all?(Map.values(pull_requests), &kept?(&1, ctx.now)) do
          {pull_requests, cached}
        else
          read_row(item, mentions, fingerprint, ctx)
        end

      _changed ->
        read_row(item, mentions, fingerprint, ctx)
    end
  end

  defp kept?({_at, {:ok, _pr}}, _now), do: true
  defp kept?({at, {:error, _reason}}, now), do: now - at < @retry_ms

  defp read_row(item, mentions, fingerprint, ctx) do
    mentioned =
      for {_text, {:pull_request, number}} <- mentions,
          url = pull_request_url(ctx, item.repo_key, number),
          url != nil,
          do: url

    fetched = fetch_pull_requests(mentioned, %{}, ctx)
    pull_request_tickets = for {_at, {:ok, pr}} <- Map.values(fetched), ticket = pull_request_ticket(pr), ticket != nil, do: ticket
    tickets = for identifier <- pull_request_tickets, record = Map.get(ctx.by_identifier, identifier), record != nil, url = record_pull_request(record), url != nil, do: url
    fetched = fetch_pull_requests(own_urls(item, mentions, ctx) ++ tickets, fetched, ctx)
    {fetched, {fingerprint, fetched}}
  end

  # The pull requests of the row's own ticket and of the tickets it mentions, as their records hold them.
  defp own_urls(item, mentions, ctx) do
    identifiers = for {_text, {:ticket, identifier}} <- mentions, do: identifier

    [Map.get(ctx.by_id, item.issue_id) | Enum.map(identifiers, &Map.get(ctx.by_identifier, &1))]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&record_pull_request/1)
    |> Enum.reject(&is_nil/1)
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

  # Reading a local checkout's GitHub repository runs git, so it is read again only when the
  # configured repos change.
  defp configured_github_repos do
    case Config.repos() do
      {:ok, repos} ->
        case :persistent_term.get({__MODULE__, :github_repos}, nil) do
          {^repos, github_repos} ->
            github_repos

          _stale ->
            github_repos = github_repos(repos)
            :persistent_term.put({__MODULE__, :github_repos}, {repos, github_repos})
            github_repos
        end

      {:error, _reason} ->
        %{}
    end
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

  @typedoc "What `waiting_on/2` reads of a ticket (`facts/1`)."
  @type facts :: %{
          issue_id: String.t() | nil,
          state: String.t() | nil,
          state_type: String.t() | nil,
          open_blockers: [String.t()]
        }

  @doc """
  What `waiting_on/2` needs of a ticket's Linear node (`id`, `state { name type }` and its
  `inverseRelations` with each issue's `identifier` and `state { type }`).
  """
  @spec facts(map()) :: facts()
  def facts(node) when is_map(node) do
    %{
      issue_id: node["id"],
      state: get_in(node, ["state", "name"]),
      state_type: get_in(node, ["state", "type"]),
      open_blockers: open_blockers(node)
    }
  end

  @doc """
  What a ticket waits on, in the ticket page's words (`you`, `a blocker: TP-1`, `CI`, `a review`,
  `its sub-tickets`, `a slot`), from its `facts/1` and what runs and waits on the Director now;
  nil while it runs or once it is done.
  """
  @spec waiting_on(facts(), live()) :: String.t() | nil
  def waiting_on(%{state_type: type}, _live) when type in @terminal_types, do: nil

  def waiting_on(facts, live) do
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

  defp references(item, mentions, ctx) do
    Map.new(mentions, fn {text, mention} -> {text, reference(mention, item, ctx)} end)
  end

  defp reference({:ticket, identifier}, item, ctx) do
    case Map.fetch(ctx.by_identifier, identifier) do
      {:ok, record} -> ticket_reference(record, ctx)
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

  defp ticket_reference(record, ctx) do
    %{
      kind: "ticket",
      identifier: record.issue_identifier,
      title: record.title,
      repo_key: record.repo_key,
      state: record.phase,
      summary: ticket_summary(record.description),
      url: record.url,
      parent: parent_reference(record.parent),
      pull_request: record_pull_request_reference(record, ctx),
      waiting_on: nil,
      facts: record_facts(record, ctx)
    }
  end

  # What `waiting_on/2` reads of a ticket's record: its phase, read as a terminal state, a backlog
  # one or a started one, and its blockers not in a terminal state.
  defp record_facts(record, ctx) do
    %{
      issue_id: record.issue_id,
      state: record.phase,
      state_type: state_type(record.phase, record.repo_key, ctx),
      open_blockers: open_record_blockers(record, ctx)
    }
  end

  defp open_record_blockers(record, ctx) do
    for %{identifier: identifier, state: state} <- record.blockers,
        is_binary(identifier),
        not terminal?(state, record.repo_key, ctx),
        do: identifier
  end

  defp state_type(phase, repo_key, ctx) do
    cond do
      terminal?(phase, repo_key, ctx) -> "completed"
      normalize(phase) in @backlog_types -> normalize(phase)
      true -> "started"
    end
  end

  defp terminal?(state, repo_key, ctx) when is_binary(state) do
    normalize(state) in Enum.map(terminal_states(repo_key, ctx), &normalize/1)
  end

  defp terminal?(_state, _repo_key, _ctx), do: false

  defp terminal_states(repo_key, ctx), do: Keyword.get(ctx.opts, :settings_fun, &Config.settings_for_repo!/1).(repo_key).tracker.terminal_states

  @doc """
  The one-line summary of a ticket: its Symphony summary's status line when it has one, else its
  description's first sentence, as plain text of at most 160 characters.
  """
  @spec ticket_summary(String.t() | nil) :: String.t() | nil
  def ticket_summary(description) do
    Mentions.summary(IssueSummary.status(description)) ||
      description |> IssueSummary.strip() |> Decisions.strip() |> Mentions.summary()
  end

  defp parent_reference(%{identifier: identifier} = parent), do: %{identifier: identifier, title: Map.get(parent, :title)}
  defp parent_reference(_parent), do: nil

  defp record_pull_request_reference(record, ctx) do
    case record_pull_request(record) do
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
    for %{"type" => "blocks", "issue" => %{"identifier" => identifier} = issue} <- node |> get_in(["inverseRelations", "nodes"]) |> List.wrap(),
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
    case Map.get(ctx.by_identifier, identifier) do
      %{issue_id: issue_id} -> issue_id
      nil -> nil
    end
  end

  defp ticket_verdicts(repo_key, issue_id, ctx) when is_binary(repo_key) and is_binary(issue_id) do
    Keyword.get(ctx.opts, :verdicts, &Handoff.verdicts(&1, &2, "code_review")).(repo_key, issue_id)
  end

  defp ticket_verdicts(_repo_key, _issue_id, _ctx), do: []

  @doc """
  A pull request's review state: `merged` or `closed`, else GitHub's review decision when a person
  reviewed on GitHub, else Symphony's newest Code Review verdict (`verdicts` newest first), else
  `open`.
  """
  @spec review_state(map(), [map()]) :: String.t()
  def review_state(%{state: "MERGED"}, _verdicts), do: "merged"
  def review_state(%{state: "CLOSED"}, _verdicts), do: "closed"
  def review_state(%{review_decision: "CHANGES_REQUESTED"}, _verdicts), do: "changes_requested"
  def review_state(%{review_decision: "APPROVED"}, _verdicts), do: "approved"

  def review_state(_pr, verdicts) do
    case Enum.find(verdicts, &(&1.outcome in ["approve", "request_changes"])) do
      %{outcome: "approve"} -> "approved"
      %{outcome: "request_changes"} -> "changes_requested"
      nil -> "open"
    end
  end

  @doc "How many heads `verdicts` judged with one of `outcomes`: a second pass on the same head is the same round."
  @spec rounds([map()], [String.t()]) :: non_neg_integer()
  def rounds(verdicts, outcomes), do: verdicts |> Enum.filter(&(&1.outcome in outcomes)) |> Enum.uniq_by(& &1.head_sha) |> length()

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

  @doc "The ticket a pull request belongs to: the identifier its title, else its branch, starts with."
  @spec pull_request_ticket(map()) :: String.t() | nil
  def pull_request_ticket(%{title: title, head_ref_name: branch}) do
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

  # The ticket's pull request, as the PR and CI watcher's record of it holds it.
  defp record_pull_request(%{pr_watch: %{pr_url: url}}) when is_binary(url) do
    if url =~ @pull_request_url, do: url
  end

  defp record_pull_request(_record), do: nil

  # Context

  defp context(_item, nil, _ctx), do: %{parent: nil, pull_request: nil, blocked_by: [], blocks: [], related: [], earlier_decisions: []}

  defp context(item, record, ctx) do
    %{
      parent: record.parent,
      pull_request: own_pull_request(record_pull_request(record), item, ctx),
      blocked_by: for(%{identifier: identifier} = blocker <- record.blockers, is_binary(identifier), do: link(identifier, blocker.state, ctx)),
      blocks: for(other <- ctx.records, blocks?(other, record), do: %{identifier: other.issue_identifier, title: other.title, state: other.phase}),
      related: [],
      earlier_decisions: earlier_decisions(record)
    }
  end

  defp link(identifier, state, ctx) do
    %{identifier: identifier, title: ctx.by_identifier |> Map.get(identifier, %{}) |> Map.get(:title), state: state}
  end

  defp blocks?(other, record) do
    is_binary(other.issue_identifier) and
      Enum.any?(other.blockers, &((is_binary(&1.id) and &1.id == record.issue_id) or (is_binary(&1.identifier) and &1.identifier == record.issue_identifier)))
  end

  defp own_pull_request(nil, _item, _ctx), do: nil

  defp own_pull_request(url, item, ctx) do
    %{
      number: pull_request_number(url),
      url: url,
      checks: checks(ctx, url),
      sent_back: item.repo_key |> ticket_verdicts(item.issue_id, ctx) |> rounds(["request_changes"])
    }
  end

  # The answers the ticket was given, newest first: a withdrawn Question was never answered.
  defp earlier_decisions(record) do
    record.questions
    |> Enum.filter(&match?(%{state: :answered, answer: %{text: text}} when is_binary(text), &1))
    |> Enum.sort_by(&DateTime.to_unix(&1.answer.at, :microsecond), :desc)
    |> Enum.take(@earlier_decisions)
    |> Enum.map(&%{at: &1.answer.at |> DateTime.truncate(:second) |> DateTime.to_iso8601(), title: &1.title, answer: Request.one_line(&1.answer.text)})
  end

  # Reads

  # Each pull request is read at most once per row, and at most `@pull_requests_max` of them.
  defp fetch_pull_requests(urls, fetched, ctx) do
    fetch = Keyword.get(ctx.opts, :pull_request, &PullRequest.fetch_summary(&1, []))

    urls
    |> Enum.uniq()
    |> Enum.reduce(fetched, fn url, acc ->
      if Map.has_key?(acc, url) or map_size(acc) >= @pull_requests_max, do: acc, else: Map.put(acc, url, {ctx.now, fetch_pull_request(fetch, url)})
    end)
  end

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
