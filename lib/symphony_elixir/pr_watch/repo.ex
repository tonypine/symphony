defmodule SymphonyElixir.PrWatch.Repo do
  @moduledoc """
  The PR and CI watcher of one repository: each tick it reads every watched ticket's PR, decides
  what the ticket's phase and PR facts call for (`SymphonyElixir.PrDecision.decide/1`) and applies
  it (`SymphonyElixir.PrDecision.Apply`), and writes the facts, the decision, the actions applied
  and the attempts on the ticket's state record (`TicketState.pr_watch`). It serialises those writes
  for its repository.

  The watch set is read each tick, never from Symphony's runs: every ticket of the repository in
  `In Progress`, `Code Review`, `QA`, `Rework`, `CI Fix` or `Merging`, except a plan parent with no
  PR, which never opens one. So a ticket a person moved by hand is watched from the next tick. A
  ticket that leaves the set loses its record. With `dispatch.source: poll` it is read from Linear;
  with `record`, from the repository's ticket records (`SymphonyElixir.Dispatch.Candidates`, the
  records' phase in place of Linear's state, the worker's tickets only), so neither the tick nor a
  confirm read makes a Linear request, and a move Symphony or the Director made, which writes the
  record first, is watched at the next tick. A record keeps no description and no rulings, so R18's
  question reads the ticket by id once, when it asks (`SymphonyElixir.PrDecision.Apply`).

  The facts follow the ticket's PR through its whole life: its open PR
  (`SymphonyElixir.TicketPullRequest`), else the one closed without merging (R8 sends the ticket to
  Rework, whose run opens a new PR the facts then follow), else the one merged while the watcher
  followed it (R2 closes the ticket out). A PR merged before the stay, as a reopened ticket's, is
  not followed: that ticket has no PR yet.

  A tick reads each watched PR once (`SymphonyElixir.PrWatch.Fetch.read/2`) and, when two or more
  watched PRs are open, or one conflicts or waits on its competitors, the repository's open PRs and
  their files once, for the landing order: `ahead` is the PR `SymphonyElixir.LandingOrder.waits/2`
  makes the ticket wait for (none for a forced ticket), and `competing` every open PR that shares a
  file with it (`SymphonyElixir.PrWatch.Competitors`). Neither names a PR whose wait would close a
  cycle of blocked-by links, or one a person released the ticket from. The checks a base branch
  requires, and whether it has workflow files, are kept 10 minutes.

  A ticket waiting on its competitors (a `Blocked` hold of the landing kind) has its wait judged
  before deciding (`SymphonyElixir.PrWatch.Competitors.settle/5`), so a hold that clears lets the
  same tick decide on the conflict. A ticket that leaves the watched set ends its wait.

  Before deciding, the read is completed with what Symphony knows: the attempts
  (`SymphonyElixir.PrWatch.Attempts`), a rerun whose checks haven't reported yet (the head reads as
  running), a failed `protected paths` check (before `Merging` the head reads as its other checks; in
  `Merging` as green when the ticket's unlock decisions cover it, `SymphonyElixir.ProtectedPathsGate`),
  a red head's failure
  (`SymphonyElixir.PrWatch.Fetch.failure/3`, read once per head, for the same-failure streak), the
  wait on a check that never reported (`SymphonyElixir.PrWatch.Attempts.settle/4`), with the
  person's answer when R17 asked one: a waiver for the head, a rerun of its checks, or Rework, the
  reviewer comments still to address, which the PR review poller keeps
  (`SymphonyElixir.PrReviewPoller.review_comments/5`), and a person's answer to R7's question about
  a PR on another base: accepted, the base reads as the repo's; put back, R7 asks GitHub to retarget
  the PR. The ticket's CI label (`SymphonyElixir.CiState`) is projected from the facts.

  A check red on the base branch too (R23) is logged once per base and check while PRs wait on it,
  and once more when it no longer holds any.

  It ticks every `pull_requests.poll_interval_ms`, and at once on `poll_now/1`. A GitHub error
  doubles the wait, up to 5 minutes; GitHub's rate limit stops the tick, marks the tickets it didn't
  read `github: {:rate_limited, reset_at}`, and waits for the reset. With under a tenth of the rate
  limit left, it waits up to four intervals, or until the reset when that comes sooner.

  Each tick also runs the silent-wait detector (`SymphonyElixir.PrWatch.SilentWait`) on every
  watched ticket and keeps its result on the record (`silent`); a ticket that turns silent logs one
  `pr_watch.silent_wait` line, naming the rule, its action and the decision's own reason. The record keeps since when the decision stands (`decision.since`)
  and the last five actions applied (`actions`). A head red only on a check a person clears
  (`protected paths`, R18), in any phase, has the protected paths its PR changes read once
  (`SymphonyElixir.ProtectedPathsGate.changed_paths/2`) and kept on the record (`protected_files`).
  When R18 asks, the protected-list entries the PR changes are read for its Allow option to unlock
  (`SymphonyElixir.ProtectedPathsGate.changed_entries/2`).

  GitHub's webhook deliveries come in through `ingest/3` (`SymphonyElixir.PrWatch.Ingest`): a
  delivery patches the records it names (`source: :webhook`) and they are read again 3 seconds
  later (the confirm read), or, for a push to their base, one by one 1 second apart (a PR whose
  mergeability GitHub hasn't computed yet is read again after the others, up to 5 times). A confirm read
  is a tick of those PRs only: it decides and acts as a timed tick does, keeping the landing order
  of the last one, unless one of them conflicts, waits on its competitors, or is `BEHIND` and last
  waited on a PR ahead of it: then it reads every watched PR and the open PRs, as a timed tick, so
  the landing order and the race are as fresh as a poll's, and a PR whose leader just landed gets
  its update-branch on its own read. While deliveries are healthy (`SymphonyElixir.PrWatch.Health`) the timed tick is
  only the safety net, every `github.webhooks.fallback_poll_interval_ms`; one that finds a change
  no delivery reported marks them unhealthy, and the next tick is back at the poll interval, as it
  is while the repository's `gh webhook forward` relay keeps stopping (`SymphonyElixir.GitHub.Relay`
  not `stable`, read once a tick). The watcher of the first repository also reads the app
  repository's newest release on each timed tick (`SymphonyElixir.PrWatch.Release.poll/1`).
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{
    AutoMerge,
    BlockedHold,
    CiFix,
    CiState,
    Config,
    LandingOrder,
    PrDecision,
    ProtectedPathsGate,
    PrReviewPoller,
    RunStore,
    TicketObservation,
    TicketPullRequest,
    TicketState,
    Tracker
  }

  alias SymphonyElixir.Dispatch.Candidates
  alias SymphonyElixir.GitHub.{PullRequest, RelaySupervisor}
  alias SymphonyElixir.Linear.{Client, Issue}
  alias SymphonyElixir.PrDecision.{Action, Apply, Facts}
  alias SymphonyElixir.PrWatch.{Attempts, Competitors, Fetch, Health, Ingest, Release, SilentWait}

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
  `:github`, `:run_store`, `:self_heal`, `:fixer`, `:linker`, `:git` and `:settings` (the modules
  and settings it reads and acts through), `:now` (a clock function), `:timer`
  (`fn message, delay_ms -> ref`, in place of `Process.send_after/3` for the confirm reads),
  `:interval_ms`, `:relay_status` (`fn repo_key -> relay status or nil`, in place of
  `SymphonyElixir.GitHub.RelaySupervisor.status/2`), `app_release: true` to read the app repository's newest release on each timed
  tick, and `auto: false` to tick only on `poll/2`.
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

  @doc """
  A person's `Unblock` of the issue's landing hold: the watcher removes the links it added and stops
  waiting on those PRs (`SymphonyElixir.PrWatch.Competitors.release/3`), between its ticks.
  """
  @spec release(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def release(server, issue_id), do: GenServer.call(server, {:release, issue_id})

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
      workflows: %{},
      comparisons: %{},
      red_bases: MapSet.new(),
      health: Health.load(Keyword.get(opts, :run_store, RunStore), repo_key),
      confirm: MapSet.new(),
      confirm_timer: nil,
      rereads: [],
      reread_tries: %{},
      reread_timer: nil,
      relay: nil
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    {reply, state} = tick(state)
    {:reply, reply, schedule(state, next_tick_ms(reply, state))}
  end

  def handle_call({:release, issue_id}, _from, state) do
    {:reply, Competitors.release(state.repo_key, issue_id, Keyword.take(state.opts, [:run_store, :linker])), state}
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

    base = Ingest.base_moved(delivery, repo_url)

    {pushed, confirmed} =
      case delivery do
        {:push, _push} -> {named, []}
        _delivery -> {behind_moved_base(base, records, named), named}
      end

    confirmed = Enum.map(confirmed, &patch!(&1, delivery, now, state))
    pushed = Enum.map(pushed, &patch!(&1, {:push, base}, now, state))
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
  defp behind_moved_base(nil, _records, _named), do: []

  defp behind_moved_base(push, records, named) do
    Enum.reject(named({:push, push}, records), fn {issue_id, _identifier, _watch} -> List.keymember?(named, issue_id, 0) end)
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
    state = %{state | relay: relay_status(state)}

    with {:ok, settings} <- settings(state),
         {:ok, issues} <- watched_issues(state, settings) do
      records = ticket_states(state)
      running = running_issue_ids(state)
      reviews = review_records(state)
      watched = Enum.flat_map(issues, &watched(&1, settings, {records, reviews}, running, state))
      {reads, state} = read_all(in_scope(watched, scope), state, now)
      {reads, state, decided} = widen(scope, watched, reads, state, now)
      pulls = if decided == :all, do: open_pulls(watched, reads, state), else: :stale
      {landings, members} = landing(watched, reads, pulls, settings, now)
      race = race(watched, reads, pulls, members, now)
      watched = Enum.map(watched, &settle(&1, pulls, Map.get(landings, &1.issue.id), race, state, settings))
      seen = {if(scope == :all, do: :poll, else: :webhook), now}
      {watches, health} = write_all(in_scope(watched, decided), {reads, landings, pulls}, race, seen, state, settings)
      state = put_health(state, fn _health -> Health.learn_url(health, repository_url(watched)) end)
      clear_left(records, watched, state)
      if scope == :all and Keyword.get(state.opts, :app_release, false), do: poll_release(state, now)
      summarize(scope, watched, reads, settings, report_red_bases(watches, state), now)
    else
      {:error, reason} ->
        Logger.warning("PR watch tick failed repo_key=#{state.repo_key} reason=#{inspect(reason)}")
        {{:error, reason}, if(scope == :all, do: %{state | failures: state.failures + 1}, else: state)}
    end
  end

  # A confirm read that finds a conflict, a ticket waiting on its competitors, or a PR behind its
  # base that last waited on a PR ahead of it, reads the other watched PRs and the repository's open
  # PRs too, and decides on all of them as a timed tick does: the landing order and the race need
  # every PR, so a delivery reaches the same decision a poll would, and a PR whose leader just landed
  # is updated on its own reread. Returns the reads and what the tick decides on.
  defp widen(:all, _watched, reads, state, _now), do: {reads, state, :all}

  defp widen(scope, watched, reads, state, now) do
    if Enum.any?(in_scope(watched, scope), &(competes?(&1, reads) or behind_a_leader?(&1, reads))) do
      {rest, state} = watched |> Enum.reject(&Map.has_key?(reads, &1.issue.id)) |> read_all(state, now)
      {Map.merge(reads, rest), state, :all}
    else
      {reads, state, scope}
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
    low = Enum.find_value(reads, fn {_id, read} -> low_rate_limit(read) end)
    state = %{state | failures: failures(scope, errors > 0 or limited != nil, state)}

    next_tick_ms =
      cond do
        limited -> rate_limit_wait_ms(limited, state, settings, now)
        errors > 0 -> backoff_ms(state, settings)
        low -> slow_ms(low, state, settings, now)
        true -> tick_interval_ms(state, settings)
      end

    {{:ok, %{watched: length(watched), errors: errors, rate_limited: limited, next_tick_ms: next_tick_ms}}, state}
  end

  defp failures(:all, true, state), do: state.failures + 1
  defp failures(:all, false, _state), do: 0
  defp failures(_scope, _failed?, state), do: state.failures

  # The repository's tickets in the watched states: from its records under `dispatch.source: record`,
  # else read from Linear. An error when they couldn't be read, so a missing answer never reads as
  # tickets that left the set.
  defp watched_issues(state, settings) do
    case Config.dispatch_source() do
      "record" -> recorded_issues(state, settings)
      _poll -> linear_issues(state, settings)
    end
  end

  # The records the dispatch candidates are rebuilt from (`Candidates.from_records/4`), filtered by the
  # watched states instead of the active ones and by the worker as the Linear read is: no Linear read.
  # With `assignee: me` before any poll learned the viewer, no record could count as assigned, so the
  # tick fails instead of dropping every watched ticket. A record keeps no description and no
  # rulings, so each issue says its rulings are unknown, as a webhook delivery's does: R18, the one
  # decision that reads that text, reads the ticket by id when it asks (`Apply`).
  defp recorded_issues(state, settings) do
    with records when is_list(records) <- store(state).list_ticket_states(state.repo_key),
         {:ok, route} <- Config.repo(state.repo_key),
         {:ok, opts} <- assignee_opts(route, settings) do
      opts = [route: route, states: Enum.map(phases(settings), &elem(&1, 0))] ++ opts
      %{candidates: issues} = Candidates.from_records(state.repo_key, records, settings, opts)
      {:ok, for(issue <- issues, do: %{issue | rulings: :unknown})}
    end
  end

  defp assignee_opts(route, settings) do
    case String.trim(route.assignee || settings.tracker.assignee || "") do
      "me" -> viewer_opts(Client.known_viewer_id())
      _assignee -> {:ok, []}
    end
  end

  defp viewer_opts(nil), do: {:error, :linear_viewer_unknown}
  defp viewer_opts(viewer_id), do: {:ok, [assignee_ids: [viewer_id]]}

  # The read covers every repo, and every repo's tickets it returned are written into their records.
  defp linear_issues(state, settings) do
    tracker = Keyword.get(state.opts, :tracker, Tracker)

    with {:ok, issues, failures} <- tracker.fetch_issues_by_states_with_failures(Enum.map(phases(settings), &elem(&1, 0))) do
      TicketObservation.observe_routed(issues, source: :watcher)

      if Enum.any?(failures, &(elem(&1, 0) == state.repo_key)),
        do: {:error, {:linear_read_failed, state.repo_key}},
        else: {:ok, for(%Issue{repo_key: key} = issue <- issues, key in [nil, state.repo_key], do: issue)}
    end
  end

  defp watched(issue, settings, {records, reviews}, running, state) do
    phase = phase(issue.state, settings)
    record = Map.get(records, issue.id)
    pr_url = pr_url(issue, record, state.repo_key)

    if is_nil(phase) or (is_nil(pr_url) and Issue.breakdown?(issue)) do
      []
    else
      [
        %{
          issue: issue,
          phase: phase,
          pr_url: pr_url,
          record: record,
          review: Map.get(reviews, issue.id),
          links: previous_links(record),
          blocked_hold: record && TicketState.get_hold(record, :blocked),
          landing_hold: nil,
          restart_conflicts: false,
          ticket: %{
            phase: phase,
            origin: origin(record, settings),
            hold: hold(record),
            run: if(MapSet.member?(running, issue.id), do: :active, else: :none),
            max_red_attempts: settings.ci.max_retries,
            ahead: [],
            competing: []
          }
        }
      ]
    end
  end

  # The PR the facts follow (see the moduledoc): the open one, else the closed one, else the merged
  # one the watcher's record already followed.
  defp pr_url(issue, record, repo_key) do
    TicketPullRequest.current_url(issue, repo_key) || finished_url(TicketPullRequest.get(repo_key, issue.id), record)
  end

  defp finished_url(%{state: "closed", pr_url: url}, _record), do: url
  defp finished_url(%{state: "merged", pr_url: url}, %{pr_watch: %{pr_url: url}}), do: url
  defp finished_url(_pr, _record), do: nil

  # Reads each watched PR once, in order, until GitHub's rate limit stops the tick: the PRs left
  # unread are marked with it.
  defp read_all(watched, state, now) do
    cache = Map.new([:required, :workflows, :comparisons], &{&1, fresh(Map.fetch!(state, &1), now)})
    fetch = Keyword.get(state.opts, :fetch, Fetch)

    {reads, cache} =
      Enum.reduce(watched, {%{}, cache}, fn
        %{pr_url: nil}, acc ->
          acc

        %{issue: issue, pr_url: pr_url}, {reads, cache} ->
          read_unless_limited(fetch, issue, pr_url, reads, cache, state, now)
      end)

    {reads, Map.merge(state, cache)}
  end

  # What a base branch was read to have (its required checks, whether it has workflow files), and how
  # a red head's failed log compared with the base's, kept for 10 minutes.
  defp fresh(cache, now), do: Map.reject(cache, fn {_base, {_value, at}} -> DateTime.diff(now, at, :millisecond) >= @required_checks_ttl_ms end)

  defp read_unless_limited(fetch, issue, pr_url, reads, cache, state, now) do
    case Enum.find_value(reads, fn {_id, read} -> match?({:rate_limited, _reset}, read) && read end) do
      nil -> read_one(fetch, issue, pr_url, reads, cache, state, now)
      limited -> {Map.put(reads, issue.id, limited), cache}
    end
  end

  defp read_one(fetch, issue, pr_url, reads, cache, state, now) do
    known = fn kind -> Map.new(Map.fetch!(cache, kind), fn {base, {value, _at}} -> {base, value} end) end

    opts =
      Keyword.merge(gh_opts(state) ++ base_opts(state),
        required_checks: known.(:required),
        base_workflows: known.(:workflows),
        base_comparisons: known.(:comparisons)
      )

    case fetch.read(pr_url, opts) do
      {:ok, read} ->
        cache = %{
          required: cache_base(cache.required, Map.get(read, :required), now),
          workflows: cache_base(cache.workflows, Map.get(read, :workflows), now),
          comparisons: Enum.reduce(Map.get(read, :comparisons, %{}), cache.comparisons, &cache_base(&2, &1, now))
        }

        {Map.put(reads, issue.id, {:ok, read}), cache}

      {:error, reason} ->
        case Fetch.rate_limited(reason) do
          nil ->
            Logger.warning("PR watch read failed issue_id=#{issue.id} issue_identifier=#{issue.identifier} pr_url=#{pr_url} reason=#{inspect(reason)}")
            {Map.put(reads, issue.id, {:error, reason}), cache}

          limited ->
            Logger.warning("PR watch hit GitHub's rate limit issue_id=#{issue.id} issue_identifier=#{issue.identifier} reset_at=#{inspect(elem(limited, 1))}")
            {Map.put(reads, issue.id, limited), cache}
        end
    end
  end

  defp cache_base(cache, {base, value}, now), do: Map.put(cache, base, {value, now})
  defp cache_base(cache, _none, _now), do: cache

  # The repository's open PRs and their files, read once, when there are two watched PRs to order, or
  # one that conflicts or waits on its competitors: a person's PR can compete with it.
  defp open_pulls(watched, reads, state) do
    case Enum.filter(watched, & &1.pr_url) do
      [first | _rest] = with_pr ->
        if match?([_, _ | _], with_pr) or Enum.any?(with_pr, &competes?(&1, reads)), do: read_open_pulls(first, state), else: :off

      [] ->
        :off
    end
  end

  defp competes?(entry, reads) do
    match?({:ok, %{mergeable: :dirty}}, Map.get(reads, entry.issue.id)) or entry.links != [] or BlockedHold.landing?(entry.blocked_hold)
  end

  # Upkeep updates a BEHIND PR only with nothing ahead of it, and the PR ahead it last waited on may
  # have just landed: only the open PRs tell.
  defp behind_a_leader?(entry, reads) do
    match?({:ok, %{mergeable: :behind}}, Map.get(reads, entry.issue.id)) and previous_ahead(entry) != []
  end

  defp read_open_pulls(entry, state) do
    github = Keyword.get(state.opts, :github, PullRequest)

    case github.list_open_pull_requests(entry.pr_url, gh_opts(state)) do
      {:ok, pulls} ->
        {:ok, for(%{number: number} = pull when is_integer(number) <- pulls, into: %{}, do: {number, pull})}

      {:error, reason} ->
        Logger.warning("PR watch could not read the open pull requests repo_key=#{state.repo_key} reason=#{inspect(reason)}")
        :stale
    end
  end

  # Each watched ticket's landing: what the landing order keeps of it and the PR it waits for, as
  # `{landing, ahead}` by issue id, and the members the landing order ranked. When the open PRs
  # couldn't be read, a ticket keeps the files, wait and `ahead` it had.
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
          forced: Issue.forced?(entry.issue, settings),
          behind: Competitors.behind(entry.links)
        })
      end

    waits = LandingOrder.waits(members, now)
    by_issue = Map.new(members, &{&1.issue_id, &1})

    landings =
      Map.new(watched, fn entry ->
        wait = Map.get(waits, entry.issue.id)
        landing = landing_after(entry, Map.get(reads, entry.issue.id), {wait, get_in(by_issue, [entry.issue.id, :files])}, pulls, now)

        ahead =
          cond do
            pulls == :stale -> previous_ahead(entry)
            wait -> [ahead_of(wait, Map.get(by_issue, wait.issue_id), pulls)]
            true -> []
          end

        {entry.issue.id, {if(entry.pr_url, do: landing), ahead}}
      end)

    {landings, members}
  end

  defp ahead_of(wait, leader, {:ok, pulls}) do
    pull = Map.get(pulls, leader.pr_number, %{})

    %{
      issue_id: wait.issue_id,
      issue_identifier: wait.issue_identifier,
      pr_number: leader.pr_number,
      pr_url: wait.pr_url,
      title: Map.get(pull, :title),
      head_sha: Map.get(pull, :head_sha),
      files: wait.files
    }
  end

  # What the tick knows of the race, for the competitors: the open PRs, the ones the landing order
  # ranked by number, each watched ticket's blockers (its Linear blocked-by links and the waits it
  # recorded), the tickets whose PR was read merged, and the clock.
  defp race(watched, reads, pulls, members, now) do
    %{
      pulls: if(match?({:ok, _pulls}, pulls), do: elem(pulls, 1), else: %{}),
      members: Map.new(members, &{&1.pr_number, &1}),
      blockers: Map.new(watched, &{&1.issue.id, blocker_ids(&1)}),
      merged: for({id, {:ok, %{pr: :merged}}} <- reads, into: MapSet.new(), do: id),
      now: now
    }
  end

  defp blocker_ids(entry) do
    linear = for %{id: id} <- List.wrap(entry.issue.blocked_by), is_binary(id), do: id
    Enum.uniq(linear ++ for(%{issue_id: id, released: false} <- entry.links, is_binary(id), do: id))
  end

  # A ticket waiting on its competitors has its wait judged on the open PRs just read; with none read,
  # the wait stays as it was.
  defp settle(entry, {:ok, _pulls}, {landing, _ahead}, race, state, settings) do
    if entry.links != [] or BlockedHold.landing?(entry.blocked_hold) do
      opts = [repo_key: state.repo_key, terminal_states: settings.tracker.terminal_states, store: store(state)] ++ Keyword.take(state.opts, [:tracker, :linker])
      settled = Competitors.settle(entry.issue, entry.blocked_hold, entry.links, Map.put(race, :files, landing && Map.get(landing, :files)), opts)
      cleared? = BlockedHold.landing?(entry.blocked_hold) and is_nil(settled.hold)
      hold = if cleared? and entry.ticket.hold == :blocked, do: :none, else: entry.ticket.hold

      %{entry | links: settled.links, landing_hold: settled.hold, restart_conflicts: settled.restart_conflicts, ticket: %{entry.ticket | hold: hold}}
    else
      entry
    end
  end

  defp settle(entry, _pulls, _landing, _race, _state, _settings) do
    %{entry | landing_hold: if(BlockedHold.landing?(entry.blocked_hold), do: entry.blocked_hold)}
  end

  # The ticket's `ahead` and `competing`, without a PR whose wait closes a cycle or that a person
  # released it from. With the open PRs unread, `competing` stays as it was.
  defp waits(entry, read, {landing, ahead}, pulls, race, settings) do
    own = %{
      issue_id: entry.issue.id,
      pr_number: pr_number(read),
      files: (landing && Map.get(landing, :files)) || [],
      forced: Issue.forced?(entry.issue, settings),
      links: entry.links
    }

    competing =
      case pulls do
        {:ok, pulls} -> Competitors.competing(own, Map.values(pulls), race)
        :stale -> previous_competing(entry)
        :off -> []
      end

    {landing, Enum.reject(ahead, &Competitors.excluded?(&1, own, race.blockers)), competing}
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

  defp pr_number({:ok, %{pr_number: number}}), do: number
  defp pr_number(_read), do: nil

  defp previous_competing(%{record: %{pr_watch: %{facts: %Facts{competing: competing}}}}), do: competing
  defp previous_competing(_entry), do: []

  defp previous_links(%{pr_watch: %{links: links}}) when is_list(links), do: links
  defp previous_links(_record), do: []

  # Writes each ticket in turn, and returns the records it wrote and the delivery health as the reads
  # leave it. A wait recorded for one is a dependency the next one's waits must not close a cycle
  # with.
  defp write_all(watched, {reads, landings, pulls}, race, seen, state, settings) do
    {_blockers, watches, health} =
      Enum.reduce(watched, {race.blockers, [], state.health}, fn entry, {blockers, watches, health} ->
        read = Map.get(reads, entry.issue.id)
        waits = waits(entry, read, Map.get(landings, entry.issue.id), pulls, %{race | blockers: blockers}, settings)
        watch = write(entry, read, waits, seen, state, settings)
        health = observe(health, read, {entry, previous_watch(entry), watch}, seen, state, settings)
        {add_waits(watch, blockers, entry.issue.id), [watch | watches], health}
      end)

    {Enum.reverse(watches), health}
  end

  # The competitors the ticket's record waits on join its blockers.
  defp add_waits(watch, blockers, issue_id) do
    links = if watch, do: Map.get(watch, :links, []), else: []
    waited_on = for %{issue_id: id, released: false} <- links, is_binary(id), do: id
    Map.update(blockers, issue_id, waited_on, &Enum.uniq(&1 ++ waited_on))
  end

  # Writes the ticket's record and returns it.
  defp write(entry, read, {landing, ahead, competing}, {source, now}, state, settings) do
    ticket = %{entry.ticket | ahead: ahead, competing: competing}
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

    # A read that failed keeps the record the ticket had; only its silence moves.
    watch =
      if watch do
        watch
        |> Map.merge(%{
          source: source,
          landing: landing,
          links: Map.get(watch, :links, entry.links),
          delivered_at: carried(previous, :delivered_at, nil),
          read_ci: watch.facts.ci,
          base_ref: base_ref(read, previous)
        })
        |> settled(previous)
        |> tap(&log_decision(&1, previous, entry, state))
      else
        previous
      end

    if watch do
      watch = silence(watch, entry, previous, now, state, settings)
      store(state).put_ticket_pr_watch(state.repo_key, entry.issue.id, entry.issue.identifier, watch) |> log_write(entry)
      watch
    end
  end

  defp base_ref({:ok, %{base_ref: base}}, _previous), do: base
  defp base_ref(_read, previous), do: carried(previous, :base_ref, nil)

  # What a read tells of the deliveries: a CI result it brought (a head the last read saw otherwise
  # that is now red or green), and, on a timed tick with webhooks on, a change of the PR no delivery
  # reported.
  defp observe(health, {:error, _reason}, _watches, _seen, _state, _settings), do: health

  defp observe(health, _read, {entry, previous, %{github: :ok} = watch}, {source, now}, state, settings) do
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

  defp observe(health, _read, _watches, _seen, _state, _settings), do: health

  # The decision keeps since when it stands while the watcher makes the same one on the same head,
  # and an action applied joins the last five.
  defp settled(watch, previous) do
    {upkept, watch} = Map.pop(watch, :upkept, [])

    watch
    |> Map.put(:decision, since(watch.decision, previous && previous.decision))
    |> Map.put(:actions, actions(watch, upkept, previous))
  end

  # A decision that changed (its rule, action or head) logs one `pr_watch.decision` line; the same
  # decision on the next tick logs none.
  defp log_decision(%{decision: %{} = decision} = watch, previous, entry, state) do
    unless same_decision?(decision, previous && previous.decision) do
      Logger.info(
        "pr_watch.decision issue_id=#{entry.issue.id} issue_identifier=#{entry.issue.identifier} repo_key=#{state.repo_key} " <>
          "phase=#{watch.facts.phase} rule=#{decision.rule} action=#{decision.kind} owner=#{decision.owner || "none"} " <>
          "head_sha=#{decision.head_sha || "none"} outcome=#{decision.outcome} reason=#{inspect(decision.reason)}"
      )
    end
  end

  defp log_decision(_watch, _previous, _entry, _state), do: :ok

  defp same_decision?(decision, %{} = previous), do: Map.take(previous, [:rule, :kind, :head_sha]) == Map.take(decision, [:rule, :kind, :head_sha])
  defp same_decision?(_decision, _previous), do: false

  defp since(nil, _previous), do: nil

  defp since(decision, %{since: %DateTime{} = since} = previous) do
    Map.put(decision, :since, if(same_decision?(decision, previous), do: since, else: decision.decided_at))
  end

  defp since(decision, _previous), do: Map.put(decision, :since, decision.decided_at)

  # The upkeep applied on the read comes before its flow action.
  defp actions(watch, upkept, previous) do
    flow = for %{outcome: :applied} = decision <- [watch.decision], do: %{rule: decision.rule, kind: decision.kind, head_sha: decision.head_sha, at: decision.decided_at}
    done = for action <- upkept ++ flow, do: Map.put(action, :source, watch.source)
    Enum.take(Enum.reverse(done) ++ carried(previous, :actions, []), 5)
  end

  defp silence(watch, entry, previous, now, state, settings) do
    before = previous && Map.get(previous, :silent)

    silent =
      SilentWait.check(watch, %{
        run: entry.ticket.run,
        hold: entry.ticket.hold,
        now: now,
        interval_ms: tick_interval_ms(state, settings),
        ci_wait_ms: settings.ci.merging_wait_timeout_ms,
        previous: before
      })

    if SilentWait.listed?(silent) and not SilentWait.listed?(before) do
      Logger.warning(
        "pr_watch.silent_wait issue_id=#{entry.issue.id} issue_identifier=#{entry.issue.identifier} repo_key=#{state.repo_key} " <>
          "phase=#{entry.phase} since=#{DateTime.to_iso8601(silent.since)} rule=#{rule(watch)} bound=#{silent.bound || "none"} reason=#{inspect(silent.reason)}" <>
          decided(watch)
      )
    end

    Map.put(watch, :silent, silent)
  end

  defp rule(%{decision: %{rule: rule}}), do: rule
  defp rule(_watch), do: "none"

  # What the stuck decision says it does or waits for, so the line names what a person can act on.
  defp decided(%{decision: %{kind: kind, reason: reason}}) when is_binary(reason), do: " action=#{kind} decision=#{inspect(reason)}"
  defp decided(_watch), do: ""

  # A read GitHub refused keeps what the record held, its facts marked rate limited: R1 waits. It
  # applied no upkeep, so it keeps no upkeep failure either.
  defp rate_limited(entry, ticket, previous, limited, now) do
    base =
      previous ||
        %{facts: Fetch.facts(ticket, nil), stay: entry.phase, pr_url: entry.pr_url, head_sha: nil, read_at: nil, rate_limit: nil, applied: [], attempts: Attempts.new(), fix: @no_fix}

    facts = %{base.facts | github: :rate_limited}

    # R1 matches every rate-limited read, so there is always a decision: the wait.
    decision = decision_record(PrDecision.decide(facts), :recorded, base.attempts, facts, base.head_sha, now)
    Map.merge(base, %{facts: facts, github: limited, decision: decision, links: entry.links, upkeep_failure: nil})
  end

  # The facts, completed with what the watcher keeps, the decision and what applying it did. A stay
  # in a new phase starts a new ledger; only the current head's actions are kept.
  defp decided(entry, ticket, read, previous, now, state, settings) do
    new_stay? = new_stay?(previous, entry)
    prior = carried(previous, :attempts, Attempts.new())
    protected_files = protected_files(read, previous, entry, state)
    read = read |> complete(prior, entry, state) |> with_failure(prior, settings, state)
    observed = Map.merge(ticket, %{new_stay: new_stay?, run_heads: run_heads(entry.record)})

    attempts =
      prior
      |> Attempts.observe(read, observed, now)
      |> cancel_stale_runs(read, state)
      |> restart_conflicts(entry)

    ticket = Map.put(ticket, :review_comments, review_comments(entry, read, settings, now))
    head = read[:head_sha]
    applied = if new_stay?, do: [], else: Enum.filter(previous.applied, &(&1.head_sha == head))
    {read, applied} = base_answer(read, applied, entry)
    {attempts, applied} = take_answer(attempts, applied, entry, read, now, state)
    read = Attempts.settle(read, attempts, settings.ci.merging_wait_timeout_ms, now)
    facts = Fetch.facts(Map.merge(ticket, Attempts.facts(attempts, read, settings.ci, now)), read)
    fix = settle_fix(carried(previous, :fix, @no_fix), facts)

    ctx = %{
      repo_key: state.repo_key,
      settings: settings,
      issue: entry.issue,
      read: read,
      facts: facts,
      now: now,
      decisions: decisions(entry.record),
      opts: apply_opts(state),
      fix: fix,
      links: entry.links
    }

    {upkept, upkeep_failure, attempts, applied} = upkeep(ctx, attempts, applied, entry, state)

    case decide(facts, entry) do
      {:ok, action} ->
        read = with_protected_entries(read, action, entry, state)
        result = Apply.apply(action, Map.merge(ctx, %{read: read, attempts: attempts, applied: applied}))
        attempts = result.attempts
        project_ci(entry, facts, read, now, state)

        %{
          facts: facts,
          stay: result.moved_to || entry.phase,
          decision: result.action |> with_landing_hold(entry, facts) |> decision_record(result.outcome, attempts, facts, head, now),
          upkept: upkept,
          upkeep_failure: upkeep_failure,
          applied: result.applied,
          attempts: attempts,
          fix: result.fix,
          links: result.links,
          protected_files: protected_files
        }

      :none ->
        %{
          facts: facts,
          stay: entry.phase,
          decision: nil,
          upkept: upkept,
          upkeep_failure: upkeep_failure,
          applied: applied,
          attempts: attempts,
          fix: fix,
          links: entry.links,
          protected_files: protected_files
        }
    end
  end

  # The upkeep the facts call for (`SymphonyElixir.PrDecision.upkeep/1`), applied before the flow
  # decision on the same read, which it never changes: each action's attempts and ledger carry into
  # the next and into the flow decision's. Returns what was applied, as `actions` keeps it, and the
  # last action GitHub refused on this read, which the record keeps until a read has none
  # (`upkeep_failure`): the silent-wait detector lists a ticket whose upkeep keeps failing.
  defp upkeep(ctx, attempts, applied, entry, state) do
    ctx.facts
    |> PrDecision.upkeep()
    |> Enum.reduce({[], nil, attempts, applied}, fn action, {upkept, failure, attempts, applied} ->
      result = Apply.apply(action, Map.merge(ctx, %{attempts: attempts, applied: applied}))
      log_upkeep(result, ctx, entry, state)
      {upkept ++ upkept(result, ctx), upkeep_failure(result, ctx) || failure, result.attempts, result.applied}
    end)
  end

  defp upkept(%{outcome: :applied, action: action}, ctx), do: [%{rule: action.rule, kind: action.kind, head_sha: ctx.read[:head_sha], at: ctx.now}]
  defp upkept(_result, _ctx), do: []

  defp upkeep_failure(%{outcome: {:error, reason}, action: action}, ctx),
    do: %{rule: action.rule, kind: action.kind, head_sha: ctx.read[:head_sha], error: inspect(reason), at: ctx.now}

  defp upkeep_failure(_result, _ctx), do: nil

  defp log_upkeep(%{outcome: :recorded}, _ctx, _entry, _state), do: :ok

  defp log_upkeep(%{action: action, outcome: outcome}, ctx, entry, state) do
    Logger.info(
      "pr_watch.upkeep issue_id=#{entry.issue.id} issue_identifier=#{entry.issue.identifier} repo_key=#{state.repo_key} " <>
        "phase=#{entry.phase} rule=#{action.rule} action=#{action.kind} head_sha=#{ctx.read[:head_sha]} " <>
        "outcome=#{outcome_name(outcome)} reason=#{inspect(action.reason)}"
    )
  end

  # The wait on competing PRs that stepped behind them (R15) is over: the conflict gets its fix runs
  # again.
  defp restart_conflicts(attempts, %{restart_conflicts: true}), do: Attempts.restart_conflict(attempts)
  defp restart_conflicts(attempts, _entry), do: attempts

  # A Blocked hold of the landing kind reads as the competitors it waits on.
  defp with_landing_hold(%Action{rule: "R4"} = action, %{landing_hold: %{reason: reason}} = entry, %Facts{hold: :blocked}) when is_binary(reason) do
    prs = for %{released: false} = link <- entry.links, do: Map.take(link, [:issue_id, :issue_identifier, :pr_number, :pr_url, :title, :files])
    %{action | reason: reason, args: %{prs: prs}, clears_when: "every competing pull request lands or leaves the race"}
  end

  defp with_landing_hold(action, _entry, _facts), do: action

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
  # running; a failed check only a person clears (`protected paths`) doesn't make the head red
  # before `Merging`, where the head reads as its other checks so the reviewer, QA and the rework
  # run go on; and in `Merging` that check holds the head back (R18) unless the ticket's unlock
  # decisions cover it. A check the base branch doesn't require, cancelled again after R19's reruns,
  # is set aside: the head reads as its other checks, never held on it.
  defp complete(nil, _attempts, _entry, _state), do: nil

  defp complete(read, attempts, entry, state) do
    cond do
      read.ci in [:green, :none] and Attempts.rerun_pending?(attempts, read) -> %{read | ci: :pending}
      read.ci == :red -> complete_red(read, attempts, entry, state)
      true -> read
    end
  end

  defp complete_red(%{red_kind: :human_only} = read, _attempts, %{phase: :merging} = entry, state), do: unlocked(read, entry, state)
  defp complete_red(%{red_kind: :human_only} = read, _attempts, _entry, _state), do: %{read | ci: read.past_human_only}
  defp complete_red(%{red_kind: :cancelled} = read, attempts, _entry, _state), do: if(set_aside?(read, attempts), do: set_aside(read), else: read)
  defp complete_red(read, _attempts, _entry, _state), do: read

  defp set_aside?(read, attempts) do
    Map.get(read, :past_cancelled) != nil and Attempts.cancel_reruns(attempts, read) >= PrDecision.max_cancel_reruns()
  end

  defp set_aside(read) do
    names = for %{name: name} <- read.failed_checks, is_binary(name), uniq: true, do: name
    read |> Map.put(:ci, read.past_cancelled) |> Map.put(:set_aside, names)
  end

  defp unlocked(read, entry, state) do
    names = Enum.map(read.failed_checks, & &1.name)

    case ProtectedPathsGate.check(names, gate_pr(read, entry, state), entry.issue, Keyword.take(state.opts, [:git])) do
      :ok -> %{read | ci: :green}
      {:blocked, _reason} -> read
    end
  end

  # R18's question offers to unlock the protected-list entries the PR changes, read when R18 is the
  # action to apply; a read that fails leaves them out, and R18 waits for the next tick.
  defp with_protected_entries(read, %Action{rule: "R18"}, entry, state) do
    case ProtectedPathsGate.changed_entries(gate_pr(read, entry, state), Keyword.take(state.opts, [:git])) do
      {:ok, paths} -> Map.put(read, :protected_paths, paths)
      {:error, _reason} -> read
    end
  end

  defp with_protected_entries(read, _action, _entry, _state), do: read

  # The ticket's workspace and the PR's commits, where the protected paths gate reads with git.
  defp gate_pr(read, entry, state), do: %{workspace_path: workspace_path(state, entry.issue.id), base_sha: read.base_sha, head_sha: read.head_sha}

  # The protected paths a head red only on a check a person clears changes (R18's evidence), read
  # once per head in the ticket's workspace; a read that fails lists none and logs why.
  defp protected_files(%{ci: :red, red_kind: :human_only, head_sha: head} = read, previous, entry, state) do
    case carried(previous, :protected_files, nil) do
      %{head_sha: ^head} = known -> known
      _other -> %{head_sha: head, paths: read_protected_files(read, entry, state)}
    end
  end

  defp protected_files(_read, _previous, _entry, _state), do: nil

  defp read_protected_files(read, entry, state) do
    case ProtectedPathsGate.changed_paths(gate_pr(read, entry, state), Keyword.take(state.opts, [:git])) do
      {:ok, paths} ->
        paths

      {:error, reason} ->
        Logger.warning(
          "PR watch couldn't read the protected files a PR changes issue_id=#{entry.issue.id} issue_identifier=#{entry.issue.identifier} " <>
            "head_sha=#{read.head_sha}: #{reason}"
        )

        []
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

  # The reviewer comments still to address on the head, as the PR review poller keeps them.
  defp review_comments(_entry, nil, _settings, _now), do: :none
  defp review_comments(entry, read, settings, now), do: PrReviewPoller.review_comments(entry.review, entry.pr_url, read.head_sha, settings, now)

  # A person's answer to R7's question about the PR's base, once recorded: accepted, the base reads
  # as the repo's; put back, R7 applies again to retarget the PR.
  defp base_answer(%{base: :changed} = read, applied, entry) do
    case Apply.base_answer(decisions(entry.record), entry.issue, read) do
      :accept -> {%{read | base: :ok}, applied}
      :put_back -> {Map.put(read, :base_answer, :put_back), Enum.reject(applied, &(&1.rule == "R7"))}
      nil -> {read, applied}
    end
  end

  defp base_answer(read, applied, _entry), do: {read, applied}

  # A red head's failure, read once per head: the same-failure streak compares it.
  defp with_failure(nil, _attempts, _settings, _state), do: nil

  defp with_failure(read, attempts, settings, state) do
    Fetch.failure(read, attempts.failure, [line_limit: settings.ci.log_excerpt_lines] ++ Keyword.take(state.opts, [:github, :gh_runner]))
  end

  # The person's answer to the question R17 asked about the head, once the hold it set has cleared:
  # a waiver for the head, a rerun of its checks (the question may come again, so R17 leaves the
  # ledger), or Rework, which the hold's answer already moved it to. Then the answer to R19a's
  # question about a run GitHub keeps cancelling: keep retrying starts the run's reruns again (R19
  # reruns it on this tick, and R19a may ask again), wait leaves it.
  defp take_answer(attempts, applied, %{ticket: %{hold: :none}} = entry, read, now, state) do
    {attempts, applied} =
      with %{title: title, prior: prior} <- Attempts.open_question(attempts),
           %{answer: answer} <- answer_to(entry, title, prior) do
        pick = Apply.unreported_answer(answer)
        log_answer(title, pick, entry)
        if pick == :rerun, do: rerun_head(read, state)
        applied = if pick in [:rerun, :other], do: Enum.reject(applied, &(&1.rule == "R17")), else: applied
        {Attempts.answer(attempts, pick, now), applied}
      else
        _unanswered -> {attempts, applied}
      end

    with %{title: title, prior: prior} <- Attempts.cancel_question(attempts),
         %{answer: answer} <- answer_to(entry, title, prior) do
      pick = Apply.cancelled_answer(answer)
      log_answer(title, pick, entry)
      applied = if pick == :rerun, do: Enum.reject(applied, &(&1.rule == "R19a")), else: applied
      {Attempts.cancel_answer(attempts, pick), applied}
    else
      _unanswered -> {attempts, applied}
    end
  end

  defp take_answer(attempts, applied, _entry, _read, _now, _state), do: {attempts, applied}

  # The answer to the question titled `title`, after the `prior` ones the ticket held when it was asked.
  defp answer_to(entry, title, prior), do: entry.record |> decisions() |> Enum.filter(&Apply.same_title?(&1, title)) |> Enum.at(prior)

  defp log_answer(title, pick, entry) do
    Logger.info("PR watch read the answer to #{title}: #{pick} issue_id=#{entry.issue.id} issue_identifier=#{entry.issue.identifier}")
  end

  # Reruns every workflow run of the head, so a check that never reported gets another chance.
  defp rerun_head(read, state) do
    github = Keyword.get(state.opts, :github, PullRequest)
    opts = gh_opts(state) ++ Fetch.repo_opts(read.pr_url)

    for run_id <- Map.get(read, :run_ids, []) do
      case github.rerun(run_id, opts) do
        :ok -> Logger.info("PR watch reran run #{run_id} of #{read.head_sha} pr_url=#{read.pr_url}")
        {:error, reason} -> Logger.warning("PR watch could not rerun run #{run_id} pr_url=#{read.pr_url} reason=#{inspect(reason)}")
      end
    end
  end

  defp decisions(%{decisions: decisions}) when is_list(decisions), do: decisions
  defp decisions(_record), do: []

  # A check red on the base too holds every PR it fails (R23): said once per base and check while it
  # holds any, and once when it no longer does. A tick GitHub's rate limit cut short tells nothing.
  defp report_red_bases(watches, state) do
    if Enum.any?(watches, &match?(%{github: {:rate_limited, _reset_at}}, &1)), do: state, else: report_red_bases!(watches, state)
  end

  defp report_red_bases!(watches, state) do
    compared =
      for %{decision: %{rule: "R23"}, facts: facts} <- watches, into: %{} do
        {{facts.base_ref || "the base branch", facts.failing_check || "a check"}, Map.get(facts, :base_red)}
      end

    red = compared |> Map.keys() |> MapSet.new()

    for {base, check} = key <- MapSet.difference(red, state.red_bases) do
      Logger.warning("PR watch: the `#{check}` check is red on #{base} too; the PRs it fails wait for #{base} to go green repo_key=#{state.repo_key}#{base_run(compared[key])}")
    end

    for {base, check} <- MapSet.difference(state.red_bases, red) do
      Logger.info("PR watch: no PR waits on the `#{check}` check of #{base} any more repo_key=#{state.repo_key}")
    end

    %{state | red_bases: red}
  end

  # The base's run and commit the check was compared with, and whether by its tests or its name only.
  defp base_run(%{run_id: run_id, sha: sha, basis: basis}), do: " base_run_id=#{run_id} base_sha=#{sha} compared_by=#{basis}"
  defp base_run(_unknown), do: ""

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

  # The ticket's CI label follows its head's checks. A check only a person clears never shows it
  # red, in `Merging` either: the label reads the head's other checks.
  defp project_ci(_entry, %Facts{pr: pr}, _read, _now, _state) when pr not in [:open, :draft], do: :ok

  defp project_ci(entry, facts, read, now, state) do
    ci = if facts.ci == :red and facts.red_kind == :human_only, do: read.past_human_only, else: facts.ci

    status =
      case ci do
        ci when ci in [:green, :none] -> "green"
        :red -> "red"
        _running -> "running"
      end

    CiState.record(state.repo_key, entry.issue.id, read[:head_sha], status, now, run_store: store(state), tracker: Keyword.get(state.opts, :tracker, Tracker))
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

  defp apply_opts(state), do: Keyword.take(state.opts, [:tracker, :github, :run_store, :self_heal, :fixer, :gh_runner, :symphony_repo_key, :terminal_states, :linker])

  # What the ticket's record held.
  defp previous_watch(%{record: %{pr_watch: %{} = watch}}), do: watch
  defp previous_watch(_entry), do: nil

  defp clear_left(records, watched, state) do
    watched_ids = MapSet.new(watched, & &1.issue.id)

    for {issue_id, %{pr_watch: %{}} = record} <- records, not MapSet.member?(watched_ids, issue_id) do
      Competitors.leave(state.repo_key, record, [store: store(state)] ++ Keyword.take(state.opts, [:tracker, :linker]))
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

  # The PR review poller's records, by issue: the reviewer comments it keeps for each ticket.
  defp review_records(state) do
    case store(state).list_pr_reviews(state.repo_key) do
      records when is_list(records) -> Map.new(records, &{&1.issue_id, &1})
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

  # The safety net while deliveries are healthy and the relay runs steadily, else the poll interval.
  defp tick_interval_ms(state, settings), do: Health.interval_ms(state.health, settings.github.webhooks, poll_interval_ms(state, settings), state.relay)

  # The repository's `gh webhook forward` relay, read once a tick; nil when it has none.
  defp relay_status(state) do
    Keyword.get(state.opts, :relay_status, &RelaySupervisor.status(RelaySupervisor, &1)).(state.repo_key)
  end

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

  # A read that left under a tenth of GitHub's rate limit.
  defp low_rate_limit({:ok, %{rate_limit: %{remaining: remaining, limit: limit} = rate_limit}})
       when is_integer(remaining) and is_integer(limit) and remaining * 10 < limit,
       do: rate_limit

  defp low_rate_limit(_read), do: nil

  # Up to four intervals, or until the reset when that comes sooner, never under one interval.
  defp slow_ms(rate_limit, state, settings, now) do
    interval = tick_interval_ms(state, settings)

    until_reset =
      case rate_limit.reset_at do
        %DateTime{} = reset_at -> DateTime.diff(reset_at, now, :millisecond)
        nil -> 4 * interval
      end

    wait_ms = max(interval, min(4 * interval, until_reset))
    Logger.info("pr_watch.rate_limit_low repo_key=#{state.repo_key} remaining=#{rate_limit.remaining} limit=#{rate_limit.limit} next_tick_ms=#{wait_ms}")
    wait_ms
  end

  defp gh_opts(state), do: Keyword.take(state.opts, [:gh_runner])

  # The branch the repo's PRs merge into, when its configuration names one.
  defp base_opts(state) do
    case Config.repo_base_branch(state.repo_key) do
      {:ok, branch} when is_binary(branch) and branch != "" -> [base_branch: branch]
      _none -> []
    end
  end

  defp store(state), do: Keyword.get(state.opts, :run_store, RunStore)
  defp now(state), do: Keyword.get(state.opts, :now, &DateTime.utc_now/0).()
end
