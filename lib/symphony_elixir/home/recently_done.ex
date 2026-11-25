defmodule SymphonyElixir.Home.RecentlyDone do
  @moduledoc """
  The Recently done list of the Home read (`recently_done` of `GET /api/v1/home`,
  `docs/design/prototypes/home-queue/README.md`, section Recently done): the tickets of every repo
  Symphony saw reach done in a range, most recent first, read in pages, from the run records and the
  ticket records alone (no Linear request).

  - A ticket is done when Symphony noted its `issue_completed` event, as the Shipped read counts it
    (`SymphonyElixir.Shipped.done_runs/2`); a cancelled ticket is not. Its done time is when it was
    done, not when the completion was noted (`SymphonyElixir.Shipped.done_at/2`): the moment its
    pull request merged, or for a ticket with no pull request the moment it entered Done. The same
    time orders the list and decides the range a ticket counts in.
  - The ranges are `today`, the host's local day of the read, and `week`, the 7 local days ending
    today, today included. The counts of both come with every read, whichever range it gives.
  - An entry gives the ticket's issue id, identifier, title, repo, when it was done (`done_at`, whole
    seconds), its pull request number (`pull_request_number`, from its stored pull request,
    `SymphonyElixir.TicketPullRequest`, else the one its run kept; nil when none is known) and its
    epic (`epic`, the identifier and title of its parent, nil when it has none).
  """

  alias SymphonyElixir.{Shipped, TicketPullRequest, URLUtils}

  @ranges %{"today" => :today, "week" => :week}
  @week_days 7
  @default_limit 50
  @max_limit 500

  @typedoc "Which entries a read gives: the `range`'s, from `offset`, at most `limit`."
  @type page :: %{range: :today | :week, offset: non_neg_integer(), limit: pos_integer()}

  @doc "The page a read without `done_range`, `done_offset` and `done_limit` gets: today's first entries."
  @spec default_page() :: page()
  def default_page, do: %{range: :today, offset: 0, limit: @default_limit}

  @doc """
  The page `params` ask for: string keys `done_range` (`today` or `week`, default `today`),
  `done_offset` (from 0) and `done_limit` (from 1, at most #{@max_limit}), all optional; or
  `{:error, {:invalid, reason}}`.
  """
  @spec page(map()) :: {:ok, page()} | {:error, {:invalid, String.t()}}
  def page(params) when is_map(params) do
    with {:ok, range} <- range(Map.get(params, "done_range")),
         {:ok, offset} <- integer(params, "done_offset", 0, 0),
         {:ok, limit} <- integer(params, "done_limit", @default_limit, 1) do
      {:ok, %{range: range, offset: offset, limit: min(limit, @max_limit)}}
    end
  end

  defp range(blank) when blank in [nil, ""], do: {:ok, :today}

  defp range(value) do
    case Map.fetch(@ranges, to_string(value)) do
      {:ok, range} -> {:ok, range}
      :error -> {:error, {:invalid, "done_range must be today or week"}}
    end
  end

  defp integer(params, name, default, least) do
    case Map.get(params, name) do
      blank when blank in [nil, ""] ->
        {:ok, default}

      value ->
        case Integer.parse(to_string(value)) do
          {number, ""} when number >= least -> {:ok, number}
          _invalid -> {:error, {:invalid, "#{name} must be a whole number from #{least}"}}
        end
    end
  end

  @doc """
  The page's entries over the ticket `records` (normalized, `SymphonyElixir.TicketState`) and
  `parents`, each ticket's parent by issue id as its identifier
  (`SymphonyElixir.Dispatch.Queue.parents/1`): the `range`, `counts` (`today` and `week`), the
  entries, `offset`, `limit` and `next_offset` (nil on the last page). `opts`: `:now`, `:to_local`
  `:runs_started_on` and `:ticket_events`, as `SymphonyElixir.Shipped.done_runs/2` takes them.
  """
  @spec read([map()], %{String.t() => String.t()}, page(), keyword()) :: map()
  def read(records, parents, page, opts) do
    %{today: today, local_date: local_date, runs: week} = Shipped.done_runs(@week_days, Keyword.take(opts, [:now, :to_local, :runs_started_on, :ticket_events]))
    today_runs = Enum.filter(week, &(local_date.(&1.done_at) == today))
    runs = if page.range == :today, do: today_runs, else: week
    taken = runs |> Enum.drop(page.offset) |> Enum.take(page.limit)
    next = page.offset + length(taken)

    ctx = %{
      by_key: Map.new(records, &{{&1.repo_key, &1.issue_id}, &1}),
      by_identifier: Map.new(records, &{&1.issue_identifier, &1}),
      parents: parents
    }

    %{
      range: Atom.to_string(page.range),
      counts: %{today: length(today_runs), week: length(week)},
      entries: Enum.map(taken, &entry(&1, ctx)),
      offset: page.offset,
      limit: page.limit,
      next_offset: if(next < length(runs), do: next)
    }
  end

  defp entry(run, ctx) do
    repo_key = Map.get(run, :repo_key)
    record = Map.get(ctx.by_key, {repo_key, run.issue_id}, %{})

    %{
      issue_id: run.issue_id,
      identifier: Map.get(run, :issue_identifier) || Map.get(record, :issue_identifier),
      title: Map.get(run, :title) || Map.get(record, :title),
      repo_key: repo_key,
      done_at: run.done_at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      pull_request_number: pull_request_number(repo_key, run),
      epic: epic(run, record, ctx)
    }
  end

  # The stored pull request, which keeps its URL once merged, else the one the run kept.
  defp pull_request_number(repo_key, run) do
    stored =
      case TicketPullRequest.get(repo_key, run.issue_id) do
        %{pr_url: url} when is_binary(url) -> url
        _none -> nil
      end

    with url when is_binary(url) <- stored || URLUtils.pull_request_url(run),
         [_url, number] <- Regex.run(~r{/pull/(\d+)}, url) do
      String.to_integer(number)
    else
      _none -> nil
    end
  end

  # The parent the Home read knows (the record's, else the record that lists it), its title from the
  # parent's record, else the one the ticket's record keeps; else the plan ticket the run kept.
  defp epic(run, record, ctx) do
    case Map.get(ctx.parents, run.issue_id) do
      identifier when is_binary(identifier) ->
        parent = Map.get(ctx.by_identifier, identifier, %{})
        %{identifier: identifier, title: Map.get(parent, :title) || get_in(record, [:parent, :title])}

      nil ->
        with %{identifier: identifier} = initiative when is_binary(identifier) <- Map.get(run, :initiative) do
          %{identifier: identifier, title: Map.get(initiative, :title)}
        end
    end
  end
end
