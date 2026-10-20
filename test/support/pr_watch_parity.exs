defmodule SymphonyElixir.PrWatchParity do
  @moduledoc """
  Replays a PR incident against the PR and CI watcher (`SymphonyElixir.PrWatch.Repo`) two ways and
  returns what it did each way, so a test can assert both are the same: webhooks change how soon
  the watcher acts, never what it does.

  A fixture is `%{tickets: [{id, state, read_attrs}], steps: [step]}`, with `files: %{id =>
  paths}` when its PRs change files that matter (none by default) and `running: [id]` for the
  tickets a run works on throughout (the QA agent on a bystander, say). Each ticket is an issue in
  `state` with an open PR (`https://github.com/acme/app/pull/<id>`) whose read is a green, clean
  one with `read_attrs` over it; the repository's open PRs are the open ones among them, with their
  files. Each step is one change on GitHub or Linear:

    * `{:github, deliveries, changes}`: GitHub changed PRs (`changes`, `[{id, read_attrs}]`) and
      sent `deliveries` (`SymphonyElixir.GitHub.Webhook` deliveries; see `check_failed/2` and the
      other builders) about it.
    * `{:run, id, from, to}`: the run the ticket's phase dispatched (a CI Fix run, the QA agent)
      handed the ticket from `from` to `to`, as `SymphonyElixir.AgentRunner` does; it raises when
      the ticket isn't in `from`, so a fixture can't hide a person's move in it. Nothing reads it
      until the next GitHub step, except a move to `Merging`, which ticks the watcher at once in
      either mode (`SymphonyElixir.TransitionGuard` asks for it).
    * `{:fix_ticket_lands, identifier}`: the fix ticket the self-heal lane filed goes to Done, the
      orchestrator's hold sweep (`SymphonyElixir.BlockedHold.sync/3`) clears the holds waiting on
      it, and the watcher's next timed tick reads the tickets, in either mode: a hold that clears
      is no GitHub event.
    * `{:move, id, state}`: something else moved the ticket. Nothing reads it until the next
      GitHub step, in either mode.

  `run(fixture, :poll)` starts the watcher, ticks once, then ticks once more after each GitHub
  step, one poll interval later, as with webhooks off: the deliveries are lost. `run(fixture,
  :webhook)` ticks once too, then hands each GitHub step's deliveries to the watcher through
  `SymphonyElixir.PrWatch.Ingest` and fires the timers they arm (the 3 s confirm read, the 1 s
  rereads after a push) on a fake clock, with no timed tick. Both return
  `%{actions: actions, elapsed_ms: elapsed, tickets: tickets}`: the calls the watcher made to
  Linear and GitHub, in order, for each GitHub step the fake time from it to the watcher's last
  read of it, and how each ticket ended (`ending/1`).

  The fakes are `World` (the issues, PRs, fix tickets and calls), `Tracker`, `Linker` (Linear's
  blocked-by links), `GitHub`, `Fetch` and `Fixer`; a test using this module writes a workflow
  with `pr_review_mode: "polling"` first.
  """

  alias SymphonyElixir.{BlockedHold, Config, Hold, RunStore, TicketPullRequest, TicketState}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrWatch.{Ingest, Repo, SilentWait}

  @repo_key "default"
  @repo_url "https://github.com/acme/app"
  @interval_ms 30_000

  defmodule World do
    @moduledoc false
    use Agent

    def start_link(_opts), do: Agent.start_link(&initial/0, name: __MODULE__)
    def reset, do: Agent.update(__MODULE__, fn _world -> initial() end)

    defp initial, do: %{issues: %{}, prs: %{}, files: %{}, fix_tickets: %{}, calls: [], now: ~U[2026-10-16 12:00:00Z]}

    def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
    def update(key, fun), do: Agent.update(__MODULE__, &Map.update!(&1, key, fun))
    def call(name, args), do: update(:calls, &(&1 ++ [{name, args}]))
    def calls, do: get(:calls)
  end

  defmodule Tracker do
    @moduledoc false
    alias SymphonyElixir.PrWatchParity.World

    # Each issue's blockers carry their current state, as Linear reads them.
    def fetch_issues_by_states_with_failures(states) do
      wanted = MapSet.new(states, &String.downcase/1)
      issues = World.get(:issues)

      watched =
        for issue <- Map.values(issues), MapSet.member?(wanted, String.downcase(issue.state)) do
          %{issue | blocked_by: Enum.map(issue.blocked_by, &%{&1 | state: issues |> Map.get(&1.id, &1) |> Map.fetch!(:state)})}
        end

      {:ok, watched, []}
    end

    def update_issue_state(issue_id, state) do
      World.call(:move, {issue_id, state})
      World.update(:issues, &Map.update!(&1, issue_id, fn issue -> %{issue | state: state} end))
    end

    def create_comment(issue_id, body), do: World.call(:comment, {issue_id, body})
    def set_machine_label(issue_id, label), do: World.call(:label, {issue_id, label})
    def clear_machine_label(_issue_id, _label), do: :ok

    def fetch_issue_by_identifier(identifier) do
      case Map.fetch(World.get(:fix_tickets), identifier) do
        {:ok, state} -> {:ok, %Issue{id: "fix-#{identifier}", identifier: identifier, state: state}}
        :error -> {:error, :not_found}
      end
    end
  end

  defmodule Linker do
    @moduledoc false
    alias SymphonyElixir.PrWatchParity.World

    # Linear's blocked-by links: recorded, and shown on the blocked issue as Linear would.
    def add_blocked_by(blocker, issue_id) do
      World.call(:link, {blocker, issue_id})
      %{id: id, state: state} = World.get(:issues) |> Map.values() |> Enum.find(&(&1.identifier == blocker))
      World.update(:issues, &Map.update!(&1, issue_id, fn issue -> %{issue | blocked_by: issue.blocked_by ++ [%{id: id, identifier: blocker, state: state}]} end))
    end

    def remove_blocked_by(blocker, issue_id) do
      World.call(:unlink, {blocker, issue_id})
      World.update(:issues, &Map.update!(&1, issue_id, fn issue -> %{issue | blocked_by: Enum.reject(issue.blocked_by, fn b -> b.identifier == blocker end)} end))
    end
  end

  defmodule GitHub do
    @moduledoc false
    alias SymphonyElixir.PrWatchParity.World

    # The open PRs among the world's, with the files each one changes.
    def list_open_pull_requests(_pr_url, _opts) do
      files = World.get(:files)

      pulls =
        for {url, %{pr: pr} = read} <- World.get(:prs), pr in [:open, :draft] do
          %{number: read.pr_number, url: url, title: read.pr_title, head_sha: read.head_sha, files: Map.get(files, url, [])}
        end

      {:ok, Enum.sort_by(pulls, & &1.number)}
    end

    def rerun_failed(run_id, _opts), do: World.call(:rerun, run_id)
    def fetch_failed_log(_run_id, _opts), do: {:ok, "ERROR: specs failed"}
    def enable_auto_merge(pr_url, request, _opts), do: World.call(:arm, {pr_url, request.head_sha}) && set_pr(pr_url, auto_merge: :armed)
    def disable_auto_merge(pr_url, _node_id, _opts), do: World.call(:disarm, pr_url) && set_pr(pr_url, auto_merge: :off)
    def squash_merge(pr_url, request, _opts), do: World.call(:merge, {pr_url, request.head_sha})
    def update_branch(pr_url, head, _opts), do: World.call(:update_branch, {pr_url, head})
    def cancel_stale_runs(_pr_url, _head, _opts), do: {:ok, []}

    defp set_pr(pr_url, attrs), do: World.update(:prs, &Map.update!(&1, pr_url, fn pr -> Map.merge(pr, Map.new(attrs)) end))
  end

  defmodule Fetch do
    @moduledoc false
    alias SymphonyElixir.PrWatchParity.World

    def read(pr_url, _opts), do: {:ok, Map.fetch!(World.get(:prs), pr_url)}
  end

  defmodule Fixer do
    @moduledoc false
    alias SymphonyElixir.PrWatchParity.World

    def create(attrs, _opts) do
      identifier = "TP-FIX#{map_size(World.get(:fix_tickets)) + 1}"
      World.call(:fix_ticket, attrs)
      World.update(:fix_tickets, &Map.put(&1, identifier, "Todo"))
      {:ok, %{identifier: identifier, url: "https://linear.app/i/#{identifier}"}}
    end

    def attach(identifier, body, _opts), do: World.call(:evidence, {identifier, body})
    def block(issue, ticket, _opts), do: World.call(:blocked_by, {issue.id, ticket.identifier})
  end

  @doc "The repository's URL, as deliveries name it."
  def repo_url, do: @repo_url

  @doc "The PR URL of ticket `id`."
  def pr_url(id), do: "#{@repo_url}/pull/#{id}"

  @doc "Ticket `id`'s issue id."
  def issue_id(id), do: "issue-#{id}"

  @doc "The read of a green, clean, open PR `id` on `main`."
  def read(id) do
    %{
      pr_url: pr_url(id),
      pr_number: String.to_integer(id),
      pr: :open,
      base: :ok,
      base_ref: "main",
      base_sha: "base-1",
      head_sha: "head-#{id}-1",
      head_ref: "auto/TP-#{id}",
      auto_merge: :off,
      review_comments: :none,
      mergeable: :clean,
      ci: :green,
      missing_checks: [],
      red_kind: :failure,
      past_human_only: nil,
      failing_check: nil,
      failed_checks: [],
      check_names: ["specs"],
      pr_node_id: "PR_#{id}",
      pr_title: "Ticket #{id}",
      pr_description: "Body",
      rate_limit: %{remaining: 4000, reset_at: nil},
      required: nil
    }
  end

  @doc "A red head's read attributes: the `check` check (`specs` by default) failed."
  def red(check \\ "specs"), do: [ci: :red, failing_check: check, failed_checks: [%{name: check, run_id: "77", workflow_name: "ci", conclusion: "FAILURE"}]]

  @doc "A `check_run` that failed on `head` of PR `id`."
  def check_failed(id, head), do: check(id, head, "failure")

  @doc "A `check_suite` that passed on `head` of PR `id`."
  def check_passed(id, head) do
    {:ci, event} = check(id, head, "success")
    {:ci, %{event | event: "check_suite"}}
  end

  defp check(id, head, conclusion) do
    ci_event(id, event: "check_run", action: "completed", head_sha: head, conclusion: conclusion)
  end

  @doc "A push that moved PR `id`'s head to `head`."
  def synchronize(id, head) do
    ci_event(id, event: "pull_request", action: "synchronize", head_sha: head, base_ref: "main")
  end

  @doc "PR `id` closed by merging into `main`."
  def merged(id) do
    ci_event(id, event: "pull_request", action: "closed", merged: true, base_ref: "main")
  end

  defp ci_event(id, attrs) do
    {:ci, Map.merge(%{head_sha: nil, conclusion: nil, completed_at: nil, pr_urls: [pr_url(id)], merged: false, base_ref: nil}, Map.new(attrs))}
  end

  @doc """
  The steps of a CI Fix run of ticket `id` that pushed `head`, whose read is `attrs` (a pending,
  blocked head by default), and handed the ticket back to `origin`.
  """
  def fix_run(id, head, origin, attrs \\ [ci: :pending, mergeable: :blocked, failing_check: nil, failed_checks: []]) do
    [{:github, [synchronize(id, head)], [{id, [head_sha: head] ++ attrs}]}, {:run, id, "CI Fix", origin}]
  end

  @doc "A push to `branch` of the repository."
  def push(branch \\ "main"), do: {:push, %{repo_url: @repo_url, ref: branch, head_sha: "base-2"}}

  @doc "Starts the world: the fakes' agent. Call it from a test's setup."
  def child_spec(_opts), do: World.child_spec([])

  @doc "Sets up `fixture`'s tickets, their PRs and the files those change."
  def tickets!(fixture) do
    for {id, state, attrs} <- fixture.tickets do
      issue = %Issue{id: issue_id(id), identifier: "TP-#{id}", title: "Ticket #{id}", state: state, url: "https://linear.app/i/TP-#{id}", labels: []}
      World.update(:issues, &Map.put(&1, issue.id, issue))
      :ok = TicketPullRequest.record_created(@repo_key, issue.id, pr_url(id), "auto/TP-#{id}")
      World.update(:prs, &Map.put(&1, pr_url(id), Map.merge(read(id), Map.new(attrs))))
    end

    for {id, paths} <- Map.get(fixture, :files, %{}), do: World.update(:files, &Map.put(&1, pr_url(id), paths))

    for id <- Map.get(fixture, :running, []) do
      run = %{repo_key: @repo_key, run_id: "run-#{id}", issue_id: issue_id(id), status: "running", started_at: now()}
      :ok = RunStore.put_run(Map.put(run, :workspace_path, "/tmp/ws"))
    end

    :ok
  end

  @doc """
  Starts the watcher on the fakes and the fake clock, with a timer that hands the confirm reads and
  rereads it arms to the test process. `opts` override the watcher's.
  """
  def start!(opts \\ []) do
    test = self()

    defaults = [
      repo_key: @repo_key,
      name: nil,
      auto: false,
      tracker: Tracker,
      github: GitHub,
      fetch: Fetch,
      fixer: Fixer,
      linker: Linker,
      interval_ms: @interval_ms,
      now: fn -> World.get(:now) end,
      timer: fn message, delay_ms -> send(test, {:pr_watch_timer, message, delay_ms}) && make_ref() end
    ]

    ExUnit.Callbacks.start_supervised!({Repo, Keyword.merge(defaults, opts)})
  end

  @doc "Moves the fake clock on."
  def advance!(ms), do: World.update(:now, &DateTime.add(&1, ms, :millisecond))

  @doc "The fake clock."
  def now, do: World.get(:now)

  @doc "Ticks the watcher once, as its timer does."
  def tick!(pid) do
    {:ok, _summary} = Repo.poll(pid)
    :ok
  end

  @doc """
  Hands `deliveries` to the watcher, then fires every timer they arm, in order, on the fake clock.
  Returns the fake time the reads took.
  """
  def deliver!(pid, deliveries) do
    started = now()
    :ok = Enum.each(deliveries, &(:ok = Ingest.deliver(&1, @repo_url, watchers: [pid])))
    _state = :sys.get_state(pid)
    fire_timers!(pid)
    DateTime.diff(now(), started, :millisecond)
  end

  @doc "Fires the timers the watcher armed until none is left, moving the clock by each one's delay."
  def fire_timers!(pid) do
    receive do
      {:pr_watch_timer, message, delay_ms} ->
        advance!(delay_ms)
        send(pid, message)
        _state = :sys.get_state(pid)
        fire_timers!(pid)
    after
      0 -> :ok
    end
  end

  @doc "Changes the reads of PRs: `[{id, attrs}]`."
  def change!(changes) do
    for {id, attrs} <- changes, do: World.update(:prs, &Map.update!(&1, pr_url(id), fn pr -> Map.merge(pr, Map.new(attrs)) end))
    :ok
  end

  @doc "Moves ticket `id` to `state` in Linear, as a run or a person does."
  def move!(id, state), do: World.update(:issues, &Map.update!(&1, issue_id(id), fn issue -> %{issue | state: state} end))

  @doc "The watcher's record of ticket `id`."
  def watch(id), do: @repo_key |> RunStore.get_ticket_state(issue_id(id)) |> TicketState.pr_watch()

  @doc "The state of ticket `id` in Linear."
  def state(id), do: World.get(:issues) |> Map.fetch!(issue_id(id)) |> Map.fetch!(:state)

  @doc "The identifiers of the tickets Linear shows blocking ticket `id`."
  def blockers(id), do: World.get(:issues) |> Map.fetch!(issue_id(id)) |> Map.fetch!(:blocked_by) |> Enum.map(& &1.identifier)

  @doc "The fix tickets the self-heal lane filed, by identifier, with their state."
  def fix_tickets, do: World.get(:fix_tickets)

  @doc """
  How ticket `id` stands: its Linear state, the watcher's decision on it (`rule`, `kind`, `owner`
  and `reason`; nil once it left the watched states, as the watcher drops its record on its next
  read, which comes sooner by deliveries), its holds and whether the silent-wait detector lists it.
  """
  def ending(id) do
    watch = if watched_state?(state(id)), do: watch(id)
    decision = watch && watch.decision

    %{
      state: state(id),
      decision: decision && Map.take(decision, [:rule, :kind, :owner, :reason]),
      holds: Enum.filter([:blocked, :needs_decision], &Hold.held?(@repo_key, issue_id(id), &1)),
      silent: SilentWait.listed?(watch && Map.get(watch, :silent))
    }
  end

  defp watched_state?(state), do: state not in Config.settings!().tracker.terminal_states

  @doc "Forgets the world and the watcher's records, between two runs of a fixture in one test."
  def reset! do
    World.reset()
    :ok = RunStore.clear()
  end

  @doc "Replays `fixture` by polling (`:poll`) or by deliveries (`:webhook`); see the moduledoc."
  def run(fixture, mode) do
    tickets!(fixture)
    pid = start!()
    tick!(pid)

    elapsed =
      for step <- fixture.steps, ms <- List.wrap(step!(pid, step, mode)), do: ms

    tickets = Map.new(fixture.tickets, fn {id, _state, _attrs} -> {id, ending(id)} end)
    ExUnit.Callbacks.stop_supervised!({Repo, @repo_key})
    %{actions: World.calls(), elapsed_ms: elapsed, tickets: tickets}
  end

  defp step!(_pid, {:move, id, state}, _mode), do: move!(id, state) && nil

  defp step!(pid, {:run, id, from, to}, _mode) do
    if state(id) != from, do: raise(ArgumentError, "TP-#{id} is in #{state(id)}, not #{from}: no run of #{from} could move it")
    move!(id, to)
    if to == "Merging", do: tick!(pid)
    nil
  end

  defp step!(pid, {:fix_ticket_lands, identifier}, _mode) do
    World.update(:fix_tickets, &Map.replace!(&1, identifier, "Done"))
    settings = Config.settings!()

    for issue <- Map.values(World.get(:issues)) do
      BlockedHold.sync(issue, settings.tracker.terminal_states, repo_key: @repo_key, tracker: Tracker, build: %{sha: nil}, settings: settings)
    end

    advance!(@interval_ms) && tick!(pid) && nil
  end

  defp step!(pid, {:github, deliveries, changes}, mode) do
    change!(changes)

    case mode do
      :poll -> advance!(@interval_ms) && tick!(pid) && @interval_ms
      :webhook -> deliver!(pid, deliveries)
    end
  end
end
