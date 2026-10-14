defmodule SymphonyElixir.PullRequestPage do
  @moduledoc """
  What the Director app's pull request page shows (`GET /api/v1/pull_requests/:repo_key/:number`):
  a pull request's story, the verdicts Symphony recorded on it, what it changes and how healthy it
  is.

  `fetch/3` reads:

  1. GitHub, in one `gh pr view` (`SymphonyElixir.GitHub.PullRequest.fetch_page/2`): title, body,
     state, dates, changed files, commits and checks;
  2. Linear, in one query (`SymphonyPullRequestPage`): the ticket the pull request is attached to,
     else the ticket Symphony's PR review record names, else the one its title or branch starts
     with;
  3. Symphony's records: the ticket's Code Review and QA verdicts, with the reason its signals
     ledger keeps for each, and the overlap map of the PR review poller
     (`SymphonyElixir.LandingOrder`) for the other open pull requests it tracks.

  When GitHub can't be read, the page carries what Linear and Symphony's records know, with
  `github: "unavailable"`. A page GitHub answered is kept for one poll interval
  (`polling.interval_ms`) per pull request, in an ETS table this server owns; without the server
  nothing is kept. The ticket's `waiting_on` depends on what runs, so it is filled on each read from
  `:live`, as `SymphonyElixir.Inbox.References.live/2` does for the Inbox.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, RunStore, TicketState}
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Inbox.{Mentions, References}
  alias SymphonyElixir.Linear.Client

  @table __MODULE__
  @verdict_kinds ["code_review", "qa"]
  @review_outcomes ["approve", "request_changes", "block"]
  @relations_first 10
  @pull_request_url ~r{/pull/(\d+)(?:[/?#]|$)}
  @identifier ~r/^([A-Z][A-Z0-9]*)-(\d+)$/

  @ticket_fields """
  id identifier title url state { name type }
  inverseRelations(first: $relationsFirst) { nodes { type issue { identifier state { type } } } }
  """

  @query """
  query SymphonyPullRequestPage($url: String!, $filter: IssueFilter!, $withIdentifier: Boolean!, $relationsFirst: Int!) {
    attachmentsForURL(url: $url) { nodes { issue { #{@ticket_fields} } } }
    issues(filter: $filter, first: 1) @include(if: $withIdentifier) { nodes { #{@ticket_fields} } }
  }
  """

  # Where a changed file belongs, first match wins: `area/1`.
  @areas [
    {"Agent instructions", ["priv/playbook/", ".symphony/instructions/", ".agents/skills/"]},
    {"Tests", ["test/", "macos/Tests/"]},
    {"App", ["macos/"]},
    {"Server", ["lib/"]},
    {"Documentation", ["docs/"]}
  ]
  @area_order ["Agent instructions", "App", "Server", "Documentation", "Tests", "Other"]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc false
  @spec query() :: {String.t(), map()}
  def query, do: {@query, %{relationsFirst: @relations_first}}

  @doc """
  The page of pull request `number` of the repo `repo_key`. Options, each defaulting to the real
  thing:

  - `:github_repos`: each repo key's GitHub repository (`owner/repo`, or `host/owner/repo`);
  - `:pull_request`: `(url) -> {:ok, PullRequest.page()} | {:error, reason}`;
  - `:linear_client`: `(query, variables, opts) -> {:ok, body} | {:error, reason}`;
  - `:ticket_state`: `(repo_key, issue_id) -> record | nil`, the ticket's record;
  - `:pr_reviews`: `(repo_key) -> [record]`, the repo's PR review records;
  - `:live`: `() -> References.live()`, what runs and waits on the Director now;
  - `:now_ms` and `:ttl_ms`: the monotonic time now and how long a page is kept.

  `{:error, :unknown_repo}` when no configured repo with a GitHub repository has the key,
  `{:error, :not_found}` when GitHub doesn't have the pull request.
  """
  @spec fetch(String.t(), String.t() | integer(), keyword()) :: {:ok, map()} | {:error, :unknown_repo | :not_found}
  def fetch(repo_key, number, opts) when is_binary(repo_key) and is_list(opts) do
    github_repos = Keyword.get_lazy(opts, :github_repos, &configured_github_repos/0)

    with {:ok, slug} <- Map.fetch(github_repos, repo_key) |> ok_or(:unknown_repo),
         {:ok, number} <- parse_number(number),
         {:ok, url} <- github_url(slug, number) |> ok_or(:unknown_repo),
         {:ok, page} <- cached_page(repo_key, number, url, opts) do
      {:ok, live_page(page, opts)}
    end
  end

  defp ok_or({:ok, value}, _reason), do: {:ok, value}
  defp ok_or(:error, reason), do: {:error, reason}

  defp github_url(slug, number) do
    case String.split(slug, "/") do
      [owner, repo] -> {:ok, "https://github.com/#{owner}/#{repo}/pull/#{number}"}
      [host, owner, repo] -> {:ok, "https://#{host}/#{owner}/#{repo}/pull/#{number}"}
      _other -> :error
    end
  end

  defp parse_number(number) when is_integer(number) and number > 0, do: {:ok, number}

  defp parse_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {number, ""} when number > 0 -> {:ok, number}
      _invalid -> {:error, :not_found}
    end
  end

  defp parse_number(_number), do: {:error, :not_found}

  defp configured_github_repos do
    case Config.repos() do
      {:ok, repos} -> References.github_repos(repos)
      {:error, _reason} -> %{}
    end
  end

  # Cache

  defp cached_page(repo_key, number, url, opts) do
    key = {repo_key, number}
    now = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    ttl = Keyword.get_lazy(opts, :ttl_ms, fn -> Config.settings!().polling.interval_ms end)

    case lookup(key) do
      {at, page} when now - at < ttl -> {:ok, page}
      _stale_or_none -> repo_key |> build(number, url, opts) |> keep(key, now)
    end
  end

  defp keep({:ok, %{github: "available"} = page} = result, key, now) do
    insert(key, {now, page})
    result
  end

  defp keep(result, _key, _now), do: result

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, entry}] -> entry
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp insert(key, entry) do
    :ets.insert(@table, {key, entry})
  rescue
    ArgumentError -> false
  end

  # The page

  defp build(repo_key, number, url, opts) do
    case Keyword.get(opts, :pull_request, &PullRequest.fetch_page(&1, [])).(url) do
      {:ok, pr} ->
        {:ok, page(repo_key, number, url, pr, opts)}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("Pull request page: could not read #{url} from GitHub: #{inspect(reason)}")
        {:ok, page(repo_key, number, url, nil, opts)}
    end
  end

  defp page(repo_key, number, url, pr, opts) do
    reviews = pr_reviews(repo_key, opts)
    own_review = Enum.find(reviews, &(pull_request_number(Map.get(&1, :pr_url)) == number)) || %{}
    node = read_ticket(url, Map.get(own_review, :issue_identifier) || pull_request_ticket(pr), opts)
    record = ticket_record(repo_key, (node && node["id"]) || Map.get(own_review, :issue_id), opts)
    verdicts = verdicts(record, pr)
    code_review = Enum.filter(verdicts, &(&1.kind == "code_review"))

    %{
      number: number,
      url: url,
      title: nil,
      repo_key: repo_key,
      ticket: ticket(node),
      github: "unavailable",
      state: nil,
      review_state: References.review_state(%{}, Enum.reverse(code_review)),
      opened_at: nil,
      last_pushed_at: nil,
      merged_at: nil,
      summary: nil,
      review_history: Enum.map(verdicts, &history_entry(&1, record)),
      areas: [],
      health: %{
        checks: nil,
        code_review: code_review_health(code_review),
        qa: verdicts |> Enum.filter(&(&1.kind == "qa")) |> List.last() |> then(&(&1 && &1.outcome)),
        overlaps: overlaps(number, own_files(pr, own_review), reviews)
      },
      size: nil
    }
    |> put_github(pr, code_review)
  end

  defp pull_request_ticket(nil), do: nil
  defp pull_request_ticket(pr), do: References.pull_request_ticket(pr)

  # What only GitHub knows.
  defp put_github(page, nil, _code_review), do: page

  defp put_github(page, pr, code_review) do
    Map.merge(page, %{
      url: pr.url || page.url,
      title: pr.title,
      github: "available",
      state: pr_state(pr.state),
      review_state: References.review_state(pr, Enum.reverse(code_review)),
      opened_at: iso8601(pr.created_at),
      last_pushed_at: iso8601(pr.last_pushed_at),
      merged_at: iso8601(pr.merged_at),
      summary: summary(pr.body),
      areas: areas(pr.files),
      health: Map.put(page.health, :checks, Map.put(pr.check_counts, :state, pr.checks)),
      size: %{files: pr.changed_files, additions: pr.additions, deletions: pr.deletions, commits: length(pr.commits)}
    })
  end

  defp pr_state("MERGED"), do: "merged"
  defp pr_state("CLOSED"), do: "closed"
  defp pr_state(_open), do: "open"

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(nil), do: nil

  defp code_review_health([]), do: nil
  defp code_review_health(verdicts), do: %{verdict: List.last(verdicts).outcome, round: References.rounds(verdicts, @review_outcomes)}

  # The ticket

  defp ticket(nil), do: nil

  defp ticket(node) do
    %{
      identifier: node["identifier"],
      title: node["title"],
      state: get_in(node, ["state", "name"]),
      waiting_on: nil,
      facts: References.facts(node)
    }
  end

  defp live_page(%{ticket: %{facts: facts} = ticket} = page, opts) do
    live = Keyword.get(opts, :live, fn -> %{running: MapSet.new(), you: MapSet.new()} end).()
    %{page | ticket: ticket |> Map.delete(:facts) |> Map.put(:waiting_on, References.waiting_on(facts, live))}
  end

  defp live_page(page, _opts), do: page

  # The ticket the pull request is attached to in Linear, else the one Symphony's records or the
  # pull request name.
  defp read_ticket(url, identifier, opts) do
    {query, limits} = query()
    filter = identifier_filter(identifier)

    variables = Map.merge(limits, %{url: url, filter: filter || %{}, withIdentifier: filter != nil})

    case Keyword.get(opts, :linear_client, &Client.graphql/3).(query, variables, []) do
      {:ok, %{"data" => %{} = data}} ->
        attached = for %{"issue" => %{"id" => id} = issue} when is_binary(id) <- List.wrap(get_in(data, ["attachmentsForURL", "nodes"])), do: issue
        named = for %{"id" => id} = issue when is_binary(id) <- List.wrap(get_in(data, ["issues", "nodes"])), do: issue
        Enum.find(attached, &(&1["identifier"] == identifier)) || List.first(attached) || List.first(named)

      other ->
        Logger.warning("Pull request page: could not read the ticket of #{url} from Linear: #{inspect(other)}")
        nil
    end
  end

  defp identifier_filter(identifier) when is_binary(identifier) do
    case Regex.run(@identifier, identifier) do
      [_, team, number] -> %{"team" => %{"key" => %{"eq" => team}}, "number" => %{"eq" => String.to_integer(number)}}
      nil -> nil
    end
  end

  defp identifier_filter(_identifier), do: nil

  # Symphony's records

  defp pr_reviews(repo_key, opts) do
    case Keyword.get(opts, :pr_reviews, &RunStore.list_pr_reviews/1).(repo_key) do
      records when is_list(records) -> records
      _error -> []
    end
  end

  defp ticket_record(_repo_key, nil, _opts), do: nil

  defp ticket_record(repo_key, issue_id, opts) do
    case Keyword.get(opts, :ticket_state, &RunStore.get_ticket_state/2).(repo_key, issue_id) do
      %{} = record -> TicketState.normalize(record)
      _none_or_error -> nil
    end
  end

  # The ticket's Code Review and QA verdicts on this pull request, oldest first: a verdict bound to
  # a head that isn't one of its commits judged another pull request of the ticket.
  defp verdicts(nil, _pr), do: []

  defp verdicts(record, pr) do
    commits = if pr, do: MapSet.new(pr.commits)

    record.verdicts
    |> Enum.filter(&(&1.kind in @verdict_kinds and (commits == nil or &1.head_sha == nil or MapSet.member?(commits, &1.head_sha))))
    |> Enum.reverse()
  end

  defp history_entry(verdict, record) do
    %{at: iso8601(verdict.recorded_at), kind: verdict.kind, verdict: verdict.outcome, reason: reason(verdict, record)}
  end

  # A verdict's reason is in the signal of its kind the same run recorded right after it: the first
  # one at or after the verdict and before the next verdict of that kind.
  defp reason(%{recorded_at: %DateTime{} = at, kind: kind}, record) do
    next = record.verdicts |> Enum.filter(&(&1.kind == kind and after?(&1.recorded_at, at))) |> Enum.map(& &1.recorded_at) |> Enum.min(DateTime, fn -> nil end)

    record.signals
    |> Enum.filter(&(&1.name == kind and match?(%DateTime{}, &1.at) and not after?(at, &1.at) and (next == nil or after?(next, &1.at))))
    |> Enum.min_by(& &1.at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      signal -> Mentions.summary(detail(signal.details, :review_reason) || detail(signal.details, :reason))
    end
  end

  defp reason(_verdict, _record), do: nil

  defp after?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :gt
  defp after?(_a, _b), do: false

  defp detail(details, key), do: Map.get(details, key) || Map.get(details, Atom.to_string(key))

  # The other open pull requests Symphony tracks that change one of this one's files: the PR review
  # poller keeps the files of each open one (`landing.files`) and drops them once it closes.
  defp own_files(%{files: files}, _review), do: Enum.map(files, & &1.path)
  defp own_files(nil, %{landing: %{files: files}}) when is_list(files), do: files
  defp own_files(nil, _review), do: []

  defp overlaps(_number, [], _reviews), do: []

  defp overlaps(number, files, reviews) do
    for %{landing: %{files: [_ | _] = other}} = record <- reviews,
        other_number = pull_request_number(Map.get(record, :pr_url)),
        other_number not in [nil, number],
        Enum.any?(other, &(&1 in files)),
        do: %{number: other_number, ticket: Map.get(record, :issue_identifier)}
  end

  defp pull_request_number(url) when is_binary(url) do
    case Regex.run(@pull_request_url, url) do
      [_, number] -> String.to_integer(number)
      nil -> nil
    end
  end

  defp pull_request_number(_url), do: nil

  # The story

  @doc """
  A pull request's story: its body's `## This PR` section (up to the next heading) as plain text,
  else its first paragraph; nil when neither has any text.
  """
  @spec summary(String.t() | nil) :: String.t() | nil
  def summary(body) when is_binary(body) do
    case Regex.run(~r/^##\s+This PR\s*$(.*?)(?=^\#{2,3}\s|\z)/ms, body) do
      [_, section] -> blank_nil(Mentions.plain(section))
      nil -> body |> String.split(~r/\R\s*\R/) |> Enum.find_value(&blank_nil(Mentions.plain(&1)))
    end
  end

  def summary(_body), do: nil

  defp blank_nil(""), do: nil
  defp blank_nil(text), do: text

  # Areas

  @doc """
  The area a changed file belongs to: `Agent instructions` (`priv/playbook/`,
  `.symphony/instructions/`, `.agents/skills/`), `Tests` (`test/`, `macos/Tests/`), `App`
  (`macos/`), `Server` (`lib/`), `Documentation` (`docs/` and a `.md` file at the root), else
  `Other`.
  """
  @spec area(String.t()) :: String.t()
  def area(path) when is_binary(path) do
    Enum.find_value(@areas, fn {name, prefixes} -> if String.starts_with?(path, prefixes), do: name end) ||
      if(root_markdown?(path), do: "Documentation", else: "Other")
  end

  defp root_markdown?(path), do: not String.contains?(path, "/") and String.ends_with?(path, ".md")

  @doc """
  `files` grouped by `area/1`: each area's name, how many files it has and their line counts, in a
  fixed order (agent instructions, app, server, documentation, tests, other). No file is named.
  """
  @spec areas([PullRequest.changed_file()]) :: [map()]
  def areas(files) when is_list(files) do
    files
    |> Enum.group_by(&area(&1.path))
    |> Enum.sort_by(fn {name, _files} -> Enum.find_index(@area_order, &(&1 == name)) end)
    |> Enum.map(fn {name, files} ->
      %{
        name: name,
        files: length(files),
        additions: Enum.sum_by(files, & &1.additions),
        deletions: Enum.sum_by(files, & &1.deletions)
      }
    end)
  end
end
