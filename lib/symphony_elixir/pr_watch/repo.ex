defmodule SymphonyElixir.PrWatch.Repo do
  @moduledoc """
  The PR and CI watcher of one repository: each tick it reads every watched ticket's PR, decides
  what the ticket's phase and PR facts call for (`SymphonyElixir.PrDecision.decide/1`) and applies
  it (`SymphonyElixir.PrDecision.Apply`), and writes the facts, the decision, the actions applied
  and the attempts on the ticket's state record (`TicketState.pr_watch`). It serialises those writes
  for its repository.

  The watch set is read from Linear each tick, never from Symphony's runs: every ticket of the
  repository in `Code Review`, `QA`, `Rework`, `CI Fix` or `Merging`, and in `In Progress` once it
  has a PR. So a ticket a person moved by hand is watched from the next tick. A ticket that leaves
  the set loses its record.

  A tick reads each watched PR once (`SymphonyElixir.PrWatch.Fetch.read/2`) and, when two or more
  watched PRs are open, the repository's open PRs and their files once, for the landing order:
  `ahead` is the PR `SymphonyElixir.LandingOrder.waits/2` makes the ticket wait for (none for a
  forced ticket). The checks a base branch requires are kept 10 minutes.

  Before deciding, the read is completed with what Symphony knows: the attempts
  (`SymphonyElixir.PrWatch.Attempts`), a rerun whose checks haven't reported yet (the head reads as
  running), and, in `Merging`, a failed `protected paths` check that the ticket's unlock decisions
  cover (`SymphonyElixir.ProtectedPathsGate`; the head reads as green). The ticket's CI label
  (`SymphonyElixir.CiState`) is projected from the facts.

  It ticks every `pull_requests.poll_interval_ms`, and at once on `poll_now/1`. A GitHub error
  doubles the wait, up to 5 minutes; GitHub's rate limit stops the tick, marks the tickets it didn't
  read `github: {:rate_limited, reset_at}`, and waits for the reset.

  GitHub's webhook deliveries come in through `ingest/3` (`SymphonyElixir.PrWatch.Ingest`): a
  delivery patches the records it names (`source: :webhook`) and they are read again 3 seconds
  later (the confirm read), or, for a push to their base, one by one 1 second apart (a PR whose
  mergeability GitHub hasn't computed yet is read again after the others, up to 5 times). A confirm read
  is a tick of those PRs only: it decides and acts as a timed tick does, keeping the landing order
  of the last one. While deliveries are healthy (`SymphonyElixir.PrWatch.Health`) the timed tick is
  only the safety net, every `github.webhooks.fallback_poll_interval_ms`; one that finds a change
  no delivery reported marks them unhealthy, and the next tick is back at the poll interval. The
  watcher of the first repository also reads the app repository's newest release on each timed
  tick (`SymphonyElixir.PrWatch.Release.poll/1`).
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{
    AutoMerge,
    CiFix,
    CiState,
    Config,
    LandingOrder,
    PrDecision,
    ProtectedPathsGate,
    RunStore,
    TicketPullRequest,
    TicketState,
    Tracker
  }

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrDecision.{Action, Apply, Facts}
  alias SymphonyElixir.PrWatch.{Attempts, Fetch, Health, Ingest, Release}

  @registry SymphonyElixir.Repo.Registry
  @in_progress_state "In Progress"
  @rework_state "Rework"
  @merging_state "Merging"
  @required_checks_ttl_ms 10 * 60_000
  @max_backoff_ms 5 * 60_000
  @max_rate_limit_wait_ms 60 * 60_000
  @no_fix %{ci_failure: nil, pr_conflict: nil}
  # Coalesces the burst of deliveries a CI run sends (one per check run and suite) into one read.
  @confirm_delay_ms 3_000
  # GitHub computes a PR's mergeability again after its base moves: its PRs are read one at a time,
  # and one GitHub hasn't computed yet is read again, up to 5 times.
  @reread_gap_ms 1_000
  @max_rereads 5

  @typedoc "What one tick did."
  @type summary :: %{
          watched: non_neg_integer(),
          errors: non_neg_integer(),
          rate_limited: {:rate_limited, DateTime.t() | nil} | nil,
          next_tick_ms: pos_integer()
        }

  @doc """
  Starts the watcher of `opts[:repo_key]`. Other `opts`, for tests: `:tracker`, `:fetch`,
  `:github`, `:run_store`, `:self_heal`, `:fixer`, `:git` and `:settings` (the modules and settings
  it reads and acts through), `:now` (a clock function), `:timer` (`fn message, delay_ms -> ref`,
  in place of `Process.send_after/3` for the confirm reads), `:interval_ms`, `app_release: true` to
  read the app repository's newest release on each timed tick, and `auto: false` to tick only on
  `poll/2`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    repo_key = Keyword.fetch!(opts, :repo_key)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, name(repo_key)))
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: {__MODULE__, Keyword.fetch!(opts, :repo_key)}, start: {__MODULE__, :start_link, [opts]}}

  @doc "The registered name of `repo_key`'s watcher."
  @spec name(String.t()) :: GenServer.name()
  def name(repo_key), do: {:via, Registry, {@registry, {:pr_watch, repo_key}}}

  @doc "Runs a tick now and returns what it did."
  @spec poll(GenServer.server(), timeout()) :: {:ok, summary()} | {:error, term()}
  def poll(server, timeout \\ 120_000), do: GenServer.call(server, :poll, timeout)

  @doc """
  Hands the watcher a verified webhook delivery and the repository URL its payload names (see
  `SymphonyElixir.PrWatch.Ingest`).
  """
  @spec ingest(GenServer.server(), term(), String.t() | nil) :: :ok
  def ingest(server, delivery, repo_url), do: GenServer.cast(server, {:ingest, delivery, repo_url})

  @doc "Counts a delivery whose signature failed, when its payload names this watcher's repository."
  @spec reject(GenServer.server(), atom(), String.t() | nil) :: :ok
  def reject(server, reason, repo_url), do: GenServer.cast(server, {:reject, reason, repo_url})

  @doc "Asks the watcher to tick now instead of waiting for its timer; a no-op when it isn't running."
  @spec poll_now(GenServer.server()) :: :ok
  def poll_now(server) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> send(pid, :tick_now)
    end

    :ok
  end

  @impl true
  def init(opts) do
    repo_key = Keyword.fetch!(opts, :repo_key)

    state = %{
      repo_key: repo_key,
      opts: opts,
      timer: nil,
      failures: 0,
      required: %{},
      health: Health.load(Keyword.get(opts, :run_store, RunStore), repo_key),
      confirm: MapSet.new(),
      confirm_timer: nil,
      rereads: [],
      reread_tries: %{},
      reread_timer: nil
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    {reply, state} = tick(state)
    {:reply, reply, schedule(state, next_tick_ms(reply, state))}
  end

  @impl true
  def handle_cast({:ingest, delivery, repo_url}, state) do
    now = now(state)
    records = ticket_states(state)
    named = named(delivery, records)
    about? = about?(state, delivery, repo_url, named, records)
    state = if about?, do: put_health(state, &Health.delivered(&1, now)), else: state

    # GitHub pings a hook when it is created, which `gh webhook forward` does on every start: read
    # everything now, to catch up on what was missed while the relay was away.
    state =
      case delivery do
        :ping -> state |> tick() |> then(fn {reply, state} -> schedule(state, next_tick_ms(reply, state)) end)
        _delivery -> state
      end

    {pushed, confirmed} =
      case delivery do
        {:push, _push} -> {named, []}
        _delivery -> {behind_moved_base(delivery, repo_url, records, named), named}
      end

    confirmed = Enum.map(confirmed, &patch!(&1, delivery, now, state))
    pushed = Enum.map(pushed, &patch!(&1, {:push, nil}, now, state))
    {:noreply, state |> confirm(confirmed) |> reread(pushed)}
  end

  def handle_cast({:reject, _reason, repo_url}, state) do
    if about_url?(state, repo_url, ticket_states(state)) do
      now = now(state)
      {:noreply, put_health(state, &Health.rejected(&1, now))}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:tick_now, state), do: {:noreply, schedule(state, 0)}

  def handle_info(:confirm, state) do
    {_reply, state} = tick(%{state | confirm: MapSet.new(), confirm_timer: nil}, {:only, state.confirm})
    {:noreply, state}
  end

  def handle_info(:reread, %{rereads: [issue_id | rest]} = state) do
    {_reply, state} = tick(%{state | rereads: rest, reread_timer: nil}, {:only, MapSet.new([issue_id])})
    {:noreply, state |> reread_unknown(issue_id) |> arm_reread()}
  end

  def handle_info(:reread, state), do: {:noreply, %{state | reread_timer: nil}}

  def handle_info(:tick, state) do
    {reply, state} = tick(state)
    {:noreply, schedule(%{state | timer: nil}, next_tick_ms(reply, state))}
  end

  # The watched records a delivery names, as `{issue_id, issue_identifier, watch}`.
  defp named(delivery, records) do
    for {issue_id, %{pr_watch: %{} = watch} = record} <- records, Ingest.names?(delivery, watch), do: {issue_id, record.issue_identifier, watch}
  end

  # The other open PRs on the base a merged PR moved, when its delivery stands for that push.
  defp behind_moved_base(delivery, repo_url, records, named) do
    case Ingest.base_moved(delivery, repo_url) do
      nil -> []
      push -> Enum.reject(named({:push, push}, records), fn {issue_id, _identifier, _watch} -> List.keymember?(named, issue_id, 0) end)
    end
  end

  # A delivery is about this repository when it names one of its PRs or its payload names the
  # repository; a ping that names none (an organisation's hook) is about every one.
  defp about?(_state, _delivery, _repo_url, [_ | _], _records), do: true
  defp about?(_state, :ping, nil, [], _records), do: true
  defp about?(state, _delivery, repo_url, [], records), do: about_url?(state, repo_url, records)

  defp about_url?(state, repo_url, records) do
    Ingest.within?(state.health.github_url, repo_url) or
      Enum.any?(records, fn {_issue_id, record} -> match?(%{pr_watch: %{pr_url: url}} when is_binary(url), record) and Ingest.within?(record.pr_watch.pr_url, repo_url) end)
  end

  # The record as the delivery leaves it, until the confirm read: its fact patch, and when a
  # delivery last named it.
  defp patch!({issue_id, identifier, watch}, delivery, now, state) do
    watch = delivery |> Ingest.patch(watch) |> Map.merge(%{source: :webhook, delivered_at: now})
    result = store(state).put_ticket_pr_watch(state.repo_key, issue_id, identifier, watch)
    log_write(result, %{issue: %{id: issue_id, identifier: identifier}})
    issue_id
  end

  defp confirm(state, []), do: state

  defp confirm(state, issue_ids) do
    state = %{state | confirm: MapSet.union(state.confirm, MapSet.new(issue_ids))}
    if state.confirm_timer, do: state, else: %{state | confirm_timer: timer(state, :confirm, @confirm_delay_ms)}
  end

  defp reread(state, []), do: state

  defp reread(state, issue_ids) do
    tries = Map.merge(state.reread_tries, Map.new(issue_ids, &{&1, 0}))
    arm_reread(%{state | rereads: Enum.uniq(state.rereads ++ issue_ids), reread_tries: tries})
  end

  # A PR whose mergeability GitHub hadn't computed yet goes to the back of the queue, until its tries
  # run out; the timed tick reads it after that.
  defp reread_unknown(state, issue_id) do
    tries = Map.get(state.reread_tries, issue_id, 0) + 1

    with true <- tries < @max_rereads,
         %{} = record <- store(state).get_ticket_state(state.repo_key, issue_id),
         %{facts: %{mergeable: :unknown}} <- TicketState.pr_watch(record) do
      %{state | rereads: Enum.uniq(state.rereads ++ [issue_id]), reread_tries: Map.put(state.reread_tries, issue_id, tries)}
    else
      _settled -> %{state | reread_tries: Map.delete(state.reread_tries, issue_id)}
    end
  end

  defp arm_reread(%{rereads: [_ | _], reread_timer: nil} = state), do: %{state | reread_timer: timer(state, :reread, @reread_gap_ms)}
  defp arm_reread(state), do: state

  defp timer(state, message, delay_ms) do
    case Keyword.get(state.opts, :timer) do
      timer when is_function(timer, 2) -> timer.(message, delay_ms)
      nil -> Process.send_after(self(), message, delay_ms)
    end
  end

  defp put_health(state, fun) do
    case fun.(state.health) do
      health when health == state.health ->
        state

      health ->
        with {:error, reason} <- Health.save(store(state), state.repo_key, health) do
          Logger.warning("PR watch could not keep the GitHub delivery health repo_key=#{state.repo_key} reason=#{inspect(reason)}")
        end

        %{state | health: health}
    end
  end

  defp schedule(%{opts: opts} = state, delay_ms) do
    if state.timer, do: Process.cancel_timer(state.timer)

    if Keyword.get(opts, :auto, true),
      do: %{state | timer: Process.send_after(self(), :tick, delay_ms)},
      else: %{state | timer: nil}
  end

  defp next_tick_ms({:ok, %{next_tick_ms: ms}}, _state), do: ms
  defp next_tick_ms({:error, _reason}, state), do: backoff_ms(state)

  # A tick reads every watched PR (`:all`, the timed tick) or only those a delivery named
  # (`{:only, issue_ids}`, a confirm read), which keep the landing order of the last timed tick.
  defp tick(state, scope \\ :all) do
    now = now(state)

    with {:ok, settings} <- settings(state),
         {:ok, issues} <- watched_issues(state, settings) do
      records = ticket_states(state)
      running = running_issue_ids(state)
      watched = Enum.flat_map(issues, &watched(&1, settings, records, running, state))
      to_read = in_scope(watched, scope)
      {reads, state} = read_all(to_read, state, now)
      pulls = if scope == :all, do: open_pulls(watched, state), else: :stale
      ahead = landing(watched, reads, pulls, settings, now)
      seen = {if(scope == :all, do: :poll, else: :webhook), now}
      health = Enum.reduce(to_read, state.health, &write(&1, Map.get(reads, &1.issue.id), Map.get(ahead, &1.issue.id), seen, state, settings, &2))
      state = put_health(state, fn _health -> Health.learn_url(health, repository_url(watched)) end)
      clear_left(records, watched, state)
      if scope == :all and Keyword.get(state.opts, :app_release, false), do: poll_release(state, now)
      summarize(scope, watched, reads, settings, state, now)
    else
      {:error, reason} ->
        Logger.warning("PR watch tick failed repo_key=#{state.repo_key} reason=#{inspect(reason)}")
        {{:error, reason}, if(scope == :all, do: %{state | failures: state.failures + 1}, else: state)}
    end
  end

  defp in_scope(watched, :all), do: watched
  defp in_scope(watched, {:only, issue_ids}), do: Enum.filter(watched, &MapSet.member?(issue_ids, &1.issue.id))

  defp repository_url(watched), do: Enum.find_value(watched, &Ingest.repository_of(&1.pr_url))

  defp poll_release(state, now) do
    case Release.poll(run_store: store(state), now: fn -> now end, gh_runner: Keyword.get(state.opts, :gh_runner)) do
      {:error, reason} -> Logger.debug("PR watch could not read the newest release of #{Release.app_repo()} reason=#{inspect(reason)}")
      _read -> :ok
    end
  end

  # A confirm read leaves the timed tick's pace and backoff as they were.
  defp summarize(scope, watched, reads, settings, state, now) do
    errors = Enum.count(reads, &match?({_id, {:error, _reason}}, &1))
    limited = Enum.find_value(reads, fn {_id, read} -> match?({:rate_limited, _reset}, read) && read end)

    failures =
      cond do
        scope != :all -> state.failures
        errors > 0 or limited -> state.failures + 1
        true -> 0
      end

    state = %{state | failures: failures}

    next_tick_ms =
      cond do
        limited -> rate_limit_wait_ms(limited, state, settings, now)
        errors > 0 -> backoff_ms(state, settings)
        true -> tick_interval_ms(state, settings)
      end

    {{:ok, %{watched: length(watched), errors: errors, rate_limited: limited, next_tick_ms: next_tick_ms}}, state}
  end

  # The repository's tickets in the watched states, read from Linear; an error when its read failed,
  # so a missing answer never reads as tickets that left the set.
  defp watched_issues(state, settings) do
    tracker = Keyword.get(state.opts, :tracker, Tracker)

    with {:ok, issues, failures} <- tracker.fetch_issues_by_states_with_failures(Enum.map(phases(settings), &elem(&1, 0))) do
      if Enum.any?(failures, &(elem(&1, 0) == state.repo_key)),
        do: {:error, {:linear_read_failed, state.repo_key}},
        else: {:ok, for(%Issue{repo_key: key} = issue <- issues, key in [nil, state.repo_key], do: issue)}
    end
  end

  defp watched(issue, settings, records, running, state) do
    phase = phase(issue.state, settings)
    pr_url = TicketPullRequest.current_url(issue, state.repo_key)
    record = Map.get(records, issue.id)

    if is_nil(phase) or (phase == :in_progress and is_nil(pr_url)) do
      []
    else
      [
        %{
          issue: issue,
          phase: phase,
          pr_url: pr_url,
          record: record,
          ticket: %{
            phase: phase,
            origin: origin(record, settings),
            hold: hold(record),
            run: if(MapSet.member?(running, issue.id), do: :active, else: :none),
            max_red_attempts: settings.ci.max_retries,
            ahead: []
          }
        }
      ]
    end
  end

  # Reads each watched PR once, in order, until GitHub's rate limit stops the tick: the PRs left
  # unread are marked with it.
  defp read_all(watched, state, now) do
    required = Map.reject(state.required, fn {_base, {_names, at}} -> DateTime.diff(now, at, :millisecond) >= @required_checks_ttl_ms end)
    fetch = Keyword.get(state.opts, :fetch, Fetch)

    {reads, required} =
      Enum.reduce(watched, {%{}, required}, fn
        %{pr_url: nil}, acc ->
          acc

        %{issue: issue, pr_url: pr_url}, {reads, required} ->
          read_unless_limited(fetch, issue, pr_url, reads, required, state, now)
      end)

    {reads, %{state | required: required}}
  end

  defp read_unless_limited(fetch, issue, pr_url, reads, required, state, now) do
    case Enum.find_value(reads, fn {_id, read} -> match?({:rate_limited, _reset}, read) && read end) do
      nil -> read_one(fetch, issue, pr_url, reads, required, state, now)
      limited -> {Map.put(reads, issue.id, limited), required}
    end
  end

  defp read_one(fetch, issue, pr_url, reads, required, state, now) do
    known = Map.new(required, fn {base, {names, _at}} -> {base, names} end)

    case fetch.read(pr_url, Keyword.merge(gh_opts(state), required_checks: known)) do
      {:ok, read} ->
        {Map.put(reads, issue.id, {:ok, read}), cache_required(required, Map.get(read, :required), now)}

      {:error, reason} ->
        case Fetch.rate_limited(reason) do
          nil ->
            Logger.warning("PR watch read failed issue_id=#{issue.id} issue_identifier=#{issue.identifier} pr_url=#{pr_url} reason=#{inspect(reason)}")
            {Map.put(reads, issue.id, {:error, reason}), required}

          limited ->
            Logger.warning("PR watch hit GitHub's rate limit issue_id=#{issue.id} issue_identifier=#{issue.identifier} reset_at=#{inspect(elem(limited, 1))}")
            {Map.put(reads, issue.id, limited), required}
        end
    end
  end

  defp cache_required(required, {base, names}, now), do: Map.put(required, base, {names, now})
  defp cache_required(required, _none, _now), do: required

  # The repository's open PRs and their files, read once, when there are two watched PRs to order.
  defp open_pulls(watched, state) do
    case Enum.filter(watched, & &1.pr_url) do
      [first, _second | _rest] ->
        github = Keyword.get(state.opts, :github, PullRequest)

        case github.list_open_pull_requests(first.pr_url, gh_opts(state)) do
          {:ok, pulls} ->
            {:ok, for(%{number: number} = pull when is_integer(number) <- pulls, into: %{}, do: {number, pull})}

          {:error, reason} ->
            Logger.warning("PR watch could not read the open pull requests repo_key=#{state.repo_key} reason=#{inspect(reason)}")
            :stale
        end

      _fewer ->
        :off
    end
  end

  # Each watched ticket's landing: what the landing order keeps of it and the PR it waits for, as
  # `{landing, ahead}` by issue id. When the open PRs couldn't be read, a ticket keeps the files,
  # wait and `ahead` it had.
  defp landing(watched, reads, pulls, settings, now) do
    members =
      for entry <- watched, pull <- List.wrap(open_pull(entry, reads, pulls)) do
        landing = landing_of(entry, pull.head_sha, now)

        Map.merge(landing, %{
          issue_id: entry.issue.id,
          issue_identifier: entry.issue.identifier,
          pr_url: entry.pr_url,
          pr_number: pull.number,
          files: pull.files,
          rank: LandingOrder.rank(landing_state(entry), settings),
          conflicting: match?({:ok, %{mergeable: :dirty}}, Map.get(reads, entry.issue.id)),
          held: entry.ticket.hold != :none,
          forced: Issue.forced?(entry.issue, settings)
        })
      end

    waits = LandingOrder.waits(members, now)
    numbers = Map.new(members, &{&1.issue_id, &1.pr_number})
    files = Map.new(members, &{&1.issue_id, &1.files})

    Map.new(watched, fn entry ->
      wait = Map.get(waits, entry.issue.id)
      landing = landing_after(entry, Map.get(reads, entry.issue.id), {wait, Map.get(files, entry.issue.id)}, pulls, now)

      ahead =
        cond do
          pulls == :stale -> previous_ahead(entry)
          wait -> [%{issue_identifier: wait.issue_identifier, pr_number: Map.get(numbers, wait.issue_id), pr_url: wait.pr_url, files: wait.files}]
          true -> []
        end

      {entry.issue.id, {if(entry.pr_url, do: landing), ahead}}
    end)
  end

  defp open_pull(%{pr_url: nil}, _reads, _pulls), do: nil

  defp open_pull(entry, reads, {:ok, pulls}) do
    with {:ok, %{pr_number: number}} <- Map.get(reads, entry.issue.id),
         %{files: files} = pull when is_list(files) <- Map.get(pulls, number) do
      pull
    else
      _not_open -> nil
    end
  end

  defp open_pull(_entry, _reads, _pulls), do: nil

  defp landing_of(entry, head_sha, now) do
    previous = previous_landing(entry)
    state = landing_state(entry)
    same_state? = previous != nil and previous.state == state
    moved? = not same_state? or previous.head_sha != head_sha

    %{
      state: state,
      head_sha: head_sha,
      state_since: if(same_state?, do: previous.state_since, else: now),
      progress_at: if(moved?, do: now, else: previous.progress_at)
    }
  end

  # A ticket whose PR wasn't read this tick keeps its landing; waiting for its leader counts as
  # moving, so it doesn't lose its place the moment that one lands. Unread open PRs keep the files
  # and the wait last read.
  defp landing_after(entry, {:ok, read}, {wait, files}, pulls, now) do
    previous = previous_landing(entry) || %{}
    landing = landing_of(entry, read.head_sha, now)
    landing = if wait, do: %{landing | progress_at: now}, else: landing

    if pulls == :stale do
      Map.merge(landing, Map.take(previous, [:files, :waits_for, :waits_since]))
    else
      same_wait? = wait != nil and match?(%{waits_for: %{issue_id: id}} when id == wait.issue_id, previous)
      Map.merge(landing, %{files: files, waits_for: wait, waits_since: if(same_wait?, do: previous.waits_since, else: wait && now)})
    end
  end

  defp landing_after(entry, _unread, _wait, _pulls, _now), do: previous_landing(entry)

  # A PR keeps its place while its ticket sits in CI Fix: the state the stay returns to counts.
  defp landing_state(%{phase: :ci_fix, record: %{ci_fix_origin: origin}}) when is_binary(origin), do: origin
  defp landing_state(entry), do: entry.issue.state

  defp previous_landing(%{record: %{pr_watch: %{landing: %{} = landing}}}), do: landing
  defp previous_landing(_entry), do: nil

  defp previous_ahead(%{record: %{pr_watch: %{facts: %Facts{ahead: ahead}}}}), do: ahead
  defp previous_ahead(_entry), do: []

  defp write(entry, read, {landing, ahead}, {source, now}, state, settings, health) do
    ticket = %{entry.ticket | ahead: ahead}
    previous = previous_watch(entry)

    watch =
      case read do
        {:ok, read} ->
          entry
          |> decided(ticket, read, previous, now, state, settings)
          |> Map.merge(%{pr_url: entry.pr_url, head_sha: read.head_sha, read_at: now, github: :ok, rate_limit: read.rate_limit})

        nil ->
          entry
          |> decided(ticket, nil, previous, now, state, settings)
          |> Map.merge(%{pr_url: nil, head_sha: nil, read_at: now, github: :ok, rate_limit: nil})

        {:rate_limited, _reset_at} = limited ->
          rate_limited(entry, ticket, previous, limited, now)

        {:error, _reason} ->
          nil
      end

    if watch do
      watch =
        Map.merge(watch, %{
          source: source,
          landing: landing,
          links: [],
          delivered_at: carried(previous, :delivered_at, nil),
          read_ci: watch.facts.ci,
          base_ref: base_ref(read, previous)
        })

      store(state).put_ticket_pr_watch(state.repo_key, entry.issue.id, entry.issue.identifier, watch) |> log_write(entry)
      observe(health, entry, previous, watch, {source, now}, state, settings)
    else
      health
    end
  end

  defp base_ref({:ok, %{base_ref: base}}, _previous), do: base
  defp base_ref(_read, previous), do: carried(previous, :base_ref, nil)

  # What a read tells of the deliveries: a CI result it brought (a head the last read saw otherwise
  # that is now red or green), and, on a timed tick with webhooks on, a change of the PR no delivery
  # reported.
  defp observe(health, entry, previous, %{github: :ok} = watch, {source, now}, state, settings) do
    health = if previous && Health.new_result?(previous.read_ci || previous.facts.ci, watch.facts.ci), do: Health.result(health, source), else: health

    case source == :poll and settings.github.webhooks.enabled and Health.unreported_change(previous, watch) do
      change when change in [:head, :pr, :ci] ->
        Logger.warning(
          "PR watch found a change no GitHub delivery reported repo_key=#{state.repo_key} issue_identifier=#{entry.issue.identifier} " <>
            "pr_url=#{watch.pr_url} change=#{change}; it reads every pull_requests.poll_interval_ms again until a delivery arrives"
        )

        Health.missed(health, watch.pr_url, change, now)

      _none ->
        health
    end
  end

  defp observe(health, _entry, _previous, _watch, _source, _settings, _now), do: health

  # A read GitHub refused keeps what the record held, its facts marked rate limited: R1 waits.
  defp rate_limited(entry, ticket, previous, limited, now) do
    base =
      previous ||
        %{facts: Fetch.facts(ticket, nil), stay: entry.phase, pr_url: entry.pr_url, head_sha: nil, read_at: nil, rate_limit: nil, applied: [], attempts: Attempts.new(), fix: @no_fix}

    facts = %{base.facts | github: :rate_limited}

    # R1 matches every rate-limited read, so there is always a decision: the wait.
    decision = decision_record(PrDecision.decide(facts), :recorded, base.attempts, facts, base.head_sha, now)
    Map.merge(base, %{facts: facts, github: limited, decision: decision})
  end

  # The facts, completed with what the watcher keeps, the decision and what applying it did. A stay
  # in a new phase starts a new ledger; only the current head's actions are kept.
  defp decided(entry, ticket, read, previous, now, state, settings) do
    new_stay? = new_stay?(previous, entry)
    prior = carried(previous, :attempts, Attempts.new())
    read = complete(read, prior, entry, state)
    observed = Map.merge(ticket, %{new_stay: new_stay?, run_heads: run_heads(entry.record)})
    attempts = prior |> Attempts.observe(read, observed, now) |> cancel_stale_runs(read, state)
    facts = Fetch.facts(Map.merge(ticket, Attempts.facts(attempts, read, settings.ci, now)), read)
    head = read[:head_sha]
    applied = if new_stay?, do: [], else: Enum.filter(previous.applied, &(&1.head_sha == head))
    fix = settle_fix(carried(previous, :fix, @no_fix), facts)

    case decide(facts, entry) do
      {:ok, action} ->
        ctx = %{repo_key: state.repo_key, settings: settings, issue: entry.issue, read: read, facts: facts, now: now, opts: apply_opts(state)}
        result = Apply.apply(action, Map.merge(ctx, %{attempts: attempts, applied: applied, fix: fix}))
        attempts = result.attempts
        project_ci(entry, facts, head, now, state)

        %{
          facts: facts,
          stay: result.moved_to || entry.phase,
          decision: decision_record(result.action, result.outcome, attempts, facts, head, now),
          applied: result.applied,
          attempts: attempts,
          fix: result.fix
        }

      :none ->
        %{facts: facts, stay: entry.phase, decision: nil, applied: applied, attempts: attempts, fix: fix}
    end
  end

  defp new_stay?(nil, _entry), do: true
  defp new_stay?(previous, entry), do: stay(previous) != entry.phase

  # What the record from the last tick carries over, or `default` with none.
  defp carried(nil, _key, default), do: default
  defp carried(previous, key, default), do: Map.get(previous, key) || default

  # The phase of the record's stay: the one a move put the ticket in, else the one it was read in.
  defp stay(%{stay: stay}) when is_atom(stay) and not is_nil(stay), do: stay
  defp stay(previous), do: previous.facts.phase

  defp decide(facts, entry) do
    {:ok, PrDecision.decide(facts)}
  rescue
    error in PrDecision.NoRuleError ->
      Logger.error("PR watch has no rule for issue_id=#{entry.issue.id} issue_identifier=#{entry.issue.identifier}: #{Exception.message(error)}")
      :none
  end

  # What the read alone can't tell: a rerun whose checks haven't reported yet keeps the head
  # running, and in `Merging` a failed `protected paths` check the ticket's unlock decisions cover
  # doesn't hold the head back.
  defp complete(nil, _attempts, _entry, _state), do: nil

  defp complete(read, attempts, entry, state) do
    cond do
      read.ci in [:green, :none] and Attempts.rerun_pending?(attempts, read) -> %{read | ci: :pending}
      entry.phase == :merging and read.ci == :red and read.red_kind == :human_only -> unlocked(read, entry, state)
      true -> read
    end
  end

  defp unlocked(read, entry, state) do
    pr = %{workspace_path: workspace_path(state, entry.issue.id), base_sha: read.base_sha, head_sha: read.head_sha}
    names = Enum.map(read.failed_checks, & &1.name)

    case ProtectedPathsGate.check(names, pr, entry.issue, Keyword.take(state.opts, [:git])) do
      :ok -> %{read | ci: :green}
      {:blocked, _reason} -> read
    end
  end

  # The workspace of the ticket's newest run that had one; a store that can't be read has none.
  defp workspace_path(state, issue_id) do
    runs = for %{workspace_path: path} = run <- List.wrap(store(state).list_issue_runs(state.repo_key, issue_id)), is_binary(path), do: run

    case Enum.sort_by(runs, &(Map.get(&1, :started_at) || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime}) do
      [%{workspace_path: path} | _older] -> path
      [] -> nil
    end
  end

  # The heads the ticket's runs left, which Symphony put there.
  defp run_heads(%{dispatches: dispatches}) do
    for dispatch <- dispatches, head <- [dispatch.head, dispatch.outcome && dispatch.outcome.head], is_binary(head), uniq: true, do: head
  end

  defp run_heads(nil), do: []

  # A failure the head no longer has is no longer the fix run's to read.
  defp settle_fix(fix, facts) do
    %{
      ci_failure: if(facts.ci in [:green, :none], do: nil, else: fix.ci_failure),
      pr_conflict: if(facts.mergeable in [:clean, :behind, :unstable, :blocked], do: nil, else: fix.pr_conflict)
    }
  end

  # The runs an update-branch left on the head it replaced can't land: cancelled once the head moved.
  defp cancel_stale_runs(%{updated_from: stale} = attempts, %{head_sha: head} = read, state) when is_binary(stale) and is_binary(head) and head != stale do
    case AutoMerge.cancel_stale_runs(read, stale, Keyword.take(state.opts, [:github, :gh_runner])) do
      {:ok, []} -> :ok
      {:ok, run_ids} -> Logger.info("PR watch cancelled CI run(s) #{Enum.join(run_ids, ", ")} on #{stale}, which update-branch replaced with #{head} pr_url=#{read.pr_url}")
      {:error, reason} -> Logger.warning("PR watch could not cancel the CI runs on #{stale} after update-branch pr_url=#{read.pr_url}: #{inspect(reason)}")
    end

    Attempts.updated_from(attempts, nil)
  end

  defp cancel_stale_runs(attempts, _read, _state), do: attempts

  # The ticket's CI label follows its head's checks.
  defp project_ci(_entry, %Facts{pr: pr}, _head, _now, _state) when pr not in [:open, :draft], do: :ok

  defp project_ci(entry, facts, head, now, state) do
    status =
      case facts.ci do
        ci when ci in [:green, :none] -> "green"
        :red -> "red"
        _running -> "running"
      end

    CiState.record(state.repo_key, entry.issue.id, head, status, now, run_store: store(state), tracker: Keyword.get(state.opts, :tracker, Tracker))
  end

  # The decision as the record keeps it: the action, how applying it went, and what a wait is on.
  defp decision_record(%Action{} = action, outcome, attempts, facts, head, now) do
    action = with_fix_ticket(action, attempts, facts)

    %{
      rule: action.rule,
      kind: action.kind,
      reason: action.reason,
      owner: action.owner,
      clears_when: action.clears_when,
      args: action.args,
      waits_on: waits_on(action),
      head_sha: head,
      decided_at: now,
      outcome: outcome_name(outcome),
      error: outcome_error(outcome)
    }
  end

  # A Blocked hold the red backstop set reads as the fix ticket it waits on.
  defp with_fix_ticket(%Action{rule: "R4"} = action, %{fix_ticket: identifier} = attempts, %Facts{hold: :blocked} = facts) when is_binary(identifier) do
    check = attempts.fix_failures |> List.last(%{}) |> Map.get(:check) || facts.failing_check || "failing"
    %{action | reason: "CI keeps failing: waiting on #{identifier}, a fix ticket for the `#{check}` check", args: %{fix_ticket: identifier, check: check}}
  end

  defp with_fix_ticket(action, _attempts, _facts), do: action

  defp waits_on(%Action{args: %{fix_ticket: identifier}}) when is_binary(identifier), do: %{type: "fix_ticket", keys: [identifier]}

  defp waits_on(%Action{args: %{prs: [_ | _] = prs}}) do
    %{type: "pull_request", keys: Enum.map(prs, &(Map.get(&1, :issue_identifier) || Map.get(&1, :pr_url)))}
  end

  defp waits_on(_action), do: nil

  defp outcome_name({:error, _reason}), do: :error
  defp outcome_name(outcome), do: outcome

  defp outcome_error({:error, reason}), do: inspect(reason)
  defp outcome_error(_outcome), do: nil

  defp apply_opts(state), do: Keyword.take(state.opts, [:tracker, :github, :run_store, :self_heal, :fixer, :gh_runner, :symphony_repo_key, :terminal_states])

  # What the ticket's record held.
  defp previous_watch(%{record: %{pr_watch: %{} = watch}}), do: watch
  defp previous_watch(_entry), do: nil

  defp clear_left(records, watched, state) do
    watched_ids = MapSet.new(watched, & &1.issue.id)

    for {issue_id, %{pr_watch: %{}} = record} <- records, not MapSet.member?(watched_ids, issue_id) do
      result = store(state).put_ticket_pr_watch(state.repo_key, issue_id, record.issue_identifier, nil)
      log_write(result, %{issue: %{id: issue_id, identifier: record.issue_identifier}})
    end
  end

  defp log_write(:ok, _entry), do: :ok

  defp log_write({:error, reason}, %{issue: issue}) do
    Logger.warning("PR watch could not write the facts issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
  end

  defp ticket_states(state) do
    case store(state).list_ticket_states(state.repo_key) do
      records when is_list(records) -> Map.new(records, &{&1.issue_id, TicketState.normalize(&1)})
      {:error, _reason} -> %{}
    end
  end

  defp running_issue_ids(state) do
    case store(state).list_runs_with_status("running") do
      runs when is_list(runs) -> for(%{issue_id: id} = run <- runs, Map.get(run, :repo_key) in [nil, state.repo_key], into: MapSet.new(), do: id)
      {:error, _reason} -> MapSet.new()
    end
  end

  defp hold(%{holds: holds}) do
    cond do
      Enum.any?(holds, &(&1.kind == :needs_decision)) -> :needs_decision
      Enum.any?(holds, &(&1.kind == :blocked)) -> :blocked
      true -> :none
    end
  end

  defp hold(nil), do: :none

  # The watched Linear states and the phase each is.
  defp phases(settings) do
    [
      {@in_progress_state, :in_progress},
      {settings.tracker.code_review_state, :code_review},
      {settings.tracker.qa_state, :qa},
      {@rework_state, :rework},
      {CiFix.state(settings), :ci_fix},
      {@merging_state, :merging}
    ]
  end

  # The phase a CI Fix stay returns to, from the state name the record keeps.
  defp origin(%{ci_fix_origin: origin}, settings) do
    phase = phase(origin, settings)
    if phase in [:code_review, :qa, :rework, :merging], do: phase
  end

  defp origin(nil, _settings), do: nil

  defp phase(state, settings) when is_binary(state) do
    Enum.find_value(phases(settings), fn {name, phase} -> normalize(name) == normalize(state) && phase end)
  end

  defp phase(_state, _settings), do: nil

  defp normalize(state), do: state |> String.trim() |> String.downcase()

  defp settings(state) do
    case Keyword.fetch(state.opts, :settings) do
      {:ok, settings} -> {:ok, settings}
      :error -> Config.settings_for_repo(state.repo_key)
    end
  end

  defp poll_interval_ms(state, settings) do
    Keyword.get(state.opts, :interval_ms) || settings.pr_review.poll_interval_ms || settings.polling.interval_ms
  end

  # The safety net while deliveries are healthy, else the poll interval.
  defp tick_interval_ms(state, settings), do: Health.interval_ms(state.health, settings.github.webhooks, poll_interval_ms(state, settings))

  defp backoff_ms(state) do
    case settings(state) do
      {:ok, settings} -> backoff_ms(state, settings)
      {:error, _reason} -> @max_backoff_ms
    end
  end

  defp backoff_ms(state, settings) do
    interval = poll_interval_ms(state, settings)
    max(interval, min(interval * Integer.pow(2, min(state.failures, 10)), @max_backoff_ms))
  end

  defp rate_limit_wait_ms({:rate_limited, %DateTime{} = reset_at}, state, settings, now) do
    max(poll_interval_ms(state, settings), min(DateTime.diff(reset_at, now, :millisecond), @max_rate_limit_wait_ms))
  end

  defp rate_limit_wait_ms(_limited, state, settings, _now), do: backoff_ms(state, settings)

  defp gh_opts(state), do: Keyword.take(state.opts, [:gh_runner])
  defp store(state), do: Keyword.get(state.opts, :run_store, RunStore)
  defp now(state), do: Keyword.get(state.opts, :now, &DateTime.utc_now/0).()
end
