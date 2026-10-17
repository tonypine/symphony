defmodule SymphonyElixir.PrWatchParity do
  @moduledoc """
  Replays a PR incident against the PR and CI watcher (`SymphonyElixir.PrWatch.Repo`) two ways and
  returns what it did each way, so a test can assert both are the same: webhooks change how soon
  the watcher acts, never what it does.

  A fixture is `%{tickets: [{id, state, read_attrs}], steps: [step]}`. Each ticket is an issue in
  `state` with an open PR (`https://github.com/acme/app/pull/<id>`) whose read is a green, clean
  one with `read_attrs` over it. Each step is one change on GitHub or Linear:

    * `{:github, deliveries, changes}`: GitHub changed PRs (`changes`, `[{id, read_attrs}]`) and
      sent `deliveries` (`SymphonyElixir.GitHub.Webhook` deliveries; see `check_failed/2` and the
      other builders) about it.
    * `{:move, id, state}`: a run or a person moved the ticket. Nothing reads it until the next
      GitHub step, in either mode.

  `run(fixture, :poll)` starts the watcher, ticks once, then ticks once more after each GitHub
  step, one poll interval later, as with webhooks off: the deliveries are lost. `run(fixture,
  :webhook)` ticks once too, then hands each GitHub step's deliveries to the watcher through
  `SymphonyElixir.PrWatch.Ingest` and fires the timers they arm (the 3 s confirm read, the 1 s
  rereads after a push) on a fake clock, with no timed tick. Both return
  `%{actions: actions, elapsed_ms: elapsed}`: the calls the watcher made to Linear and GitHub, in
  order, and for each GitHub step, the fake time from it to the watcher's last read of it.

  The fakes are `World` (the issues, PRs and calls), `Tracker`, `GitHub`, `Fetch` and `Fixer`;
  a test using this module writes a workflow with `pr_review_mode: "polling"` first.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrWatch.{Ingest, Repo}
  alias SymphonyElixir.{RunStore, TicketPullRequest, TicketState}

  @repo_key "default"
  @repo_url "https://github.com/acme/app"
  @interval_ms 30_000

  defmodule World do
    @moduledoc false
    use Agent

    def start_link(_opts), do: Agent.start_link(&initial/0, name: __MODULE__)
    def reset, do: Agent.update(__MODULE__, fn _world -> initial() end)

    defp initial, do: %{issues: %{}, prs: %{}, calls: [], now: ~U[2026-10-16 12:00:00Z]}

    def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
    def update(key, fun), do: Agent.update(__MODULE__, &Map.update!(&1, key, fun))
    def call(name, args), do: update(:calls, &(&1 ++ [{name, args}]))
    def calls, do: get(:calls)
  end

  defmodule Tracker do
    @moduledoc false
    alias SymphonyElixir.PrWatchParity.World

    def fetch_issues_by_states_with_failures(states) do
      wanted = MapSet.new(states, &String.downcase/1)
      {:ok, World.get(:issues) |> Map.values() |> Enum.filter(&MapSet.member?(wanted, String.downcase(&1.state))), []}
    end

    def update_issue_state(issue_id, state) do
      World.call(:move, {issue_id, state})
      World.update(:issues, &Map.update!(&1, issue_id, fn issue -> %{issue | state: state} end))
    end

    def create_comment(issue_id, body), do: World.call(:comment, {issue_id, body})
    def set_machine_label(issue_id, label), do: World.call(:label, {issue_id, label})
    def clear_machine_label(_issue_id, _label), do: :ok
    def fetch_issue_by_identifier(_identifier), do: {:error, :not_found}
  end

  defmodule GitHub do
    @moduledoc false
    alias SymphonyElixir.PrWatchParity.World

    def list_open_pull_requests(_pr_url, _opts), do: {:ok, []}
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
      World.call(:fix_ticket, attrs)
      {:ok, %{identifier: "TP-FIX1", url: "https://linear.app/i/TP-FIX1"}}
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

  @doc "A red head's read attributes: the `specs` check failed."
  def red, do: [ci: :red, failing_check: "specs", failed_checks: [%{name: "specs", run_id: "77", workflow_name: "ci", conclusion: "FAILURE"}]]

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

  @doc "A push to `branch` of the repository."
  def push(branch \\ "main"), do: {:push, %{repo_url: @repo_url, ref: branch, head_sha: "base-2"}}

  @doc "Starts the world: the fakes' agent. Call it from a test's setup."
  def child_spec(_opts), do: World.child_spec([])

  @doc "Sets up `fixture`'s tickets and their PRs."
  def tickets!(fixture) do
    for {id, state, attrs} <- fixture.tickets do
      issue = %Issue{id: issue_id(id), identifier: "TP-#{id}", title: "Ticket #{id}", state: state, url: "https://linear.app/i/TP-#{id}", labels: []}
      World.update(:issues, &Map.put(&1, issue.id, issue))
      :ok = TicketPullRequest.record_created(@repo_key, issue.id, pr_url(id), "auto/TP-#{id}")
      World.update(:prs, &Map.put(&1, pr_url(id), Map.merge(read(id), Map.new(attrs))))
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

    ExUnit.Callbacks.stop_supervised!({Repo, @repo_key})
    %{actions: World.calls(), elapsed_ms: elapsed}
  end

  defp step!(_pid, {:move, id, state}, _mode), do: move!(id, state) && nil

  defp step!(pid, {:github, deliveries, changes}, mode) do
    change!(changes)

    case mode do
      :poll -> advance!(@interval_ms) && tick!(pid) && @interval_ms
      :webhook -> deliver!(pid, deliveries)
    end
  end
end
