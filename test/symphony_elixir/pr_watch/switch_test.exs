defmodule SymphonyElixir.PrWatch.SwitchTest do
  @moduledoc """
  The PR and CI watcher deciding and acting on every CI and merge row (TP-941), tick by tick: the
  incidents it replaces the pollers' stopgaps for, replayed as fixtures, and one test per deciding
  branch the switch deleted from `CiPoller`, `PrReviewPoller`, `AutoMerge` and the orchestrator,
  named after the rule that now covers it.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{BlockedHold, CiFix, Hold, PrWatch, TicketPullRequest, TicketState}
  alias SymphonyElixir.PrWatch.{Attempts, Repo}
  alias SymphonyElixirWeb.WatchPayload

  @repo_key "default"

  # What the fakes did, in order, and the issues and PRs they serve, kept in one agent.
  defmodule World do
    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{
            issues: %{},
            prs: %{},
            calls: [],
            fix_tickets: %{},
            open_pulls: nil,
            now: ~U[2026-10-16 12:00:00Z],
            cancel_result: {:ok, [1]},
            log: "setup\nERROR: specs failed at stub_test.exs:21\nstack"
          }
        end,
        name: __MODULE__
      )
    end

    def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
    def update(key, fun), do: Agent.update(__MODULE__, &Map.update!(&1, key, fun))
    def call(name, args), do: update(:calls, &(&1 ++ [{name, args}]))
    def calls(name), do: for({^name, args} <- get(:calls), do: args)
    def all_calls, do: get(:calls)
    def clear_calls, do: Agent.update(__MODULE__, &%{&1 | calls: []})
  end

  defmodule Tracker do
    alias SymphonyElixir.Linear.Issue
    alias SymphonyElixir.PrWatch.SwitchTest.World

    # Each issue's blockers carry their current state, as Linear reads them.
    def fetch_issues_by_states_with_failures(states) do
      wanted = MapSet.new(states, &String.downcase/1)
      issues = World.get(:issues)

      watched =
        for issue <- Map.values(issues), MapSet.member?(wanted, String.downcase(issue.state)) do
          %{issue | blocked_by: Enum.map(issue.blocked_by, &%{&1 | state: issues |> Map.get(&1.id, %{state: &1.state}) |> Map.fetch!(:state)})}
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

  # Linear's blocked-by links: recorded, and shown on the blocked issue as Linear would.
  defmodule Linker do
    alias SymphonyElixir.PrWatch.SwitchTest.World

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
    alias SymphonyElixir.PrWatch.SwitchTest.World

    def list_open_pull_requests(_pr_url, _opts) do
      case World.get(:open_pulls) do
        nil -> {:ok, []}
        :error -> {:error, :boom}
        pulls -> {:ok, pulls}
      end
    end

    def rerun_failed(run_id, _opts), do: World.call(:rerun, run_id)

    def rerun(run_id, opts) do
      World.call(:rerun_all, {run_id, opts[:repo]})
      if run_id == "41", do: {:error, :gone}, else: :ok
    end

    def fetch_failed_log(_run_id, _opts), do: {:ok, World.get(:log)}

    def enable_auto_merge(pr_url, request, _opts) do
      World.call(:arm, {pr_url, request.head_sha})
      set_pr(pr_url, auto_merge: :armed)
    end

    def disable_auto_merge(pr_url, _node_id, _opts) do
      World.call(:disarm, pr_url)
      set_pr(pr_url, auto_merge: :off)
    end

    def squash_merge(pr_url, request, _opts), do: World.call(:merge, {pr_url, request.head_sha})
    def update_branch(pr_url, head, _opts), do: World.call(:update_branch, {pr_url, head})

    def cancel_stale_runs(pr_url, head, _opts) do
      World.call(:cancel_stale_runs, {pr_url, head})
      World.get(:cancel_result)
    end

    defp set_pr(pr_url, attrs), do: World.update(:prs, &Map.update!(&1, pr_url, fn pr -> Map.merge(pr, Map.new(attrs)) end))
  end

  defmodule Fetch do
    alias SymphonyElixir.PrWatch.SwitchTest.World

    def read(pr_url, _opts), do: {:ok, Map.fetch!(World.get(:prs), pr_url)}
  end

  defmodule Fixer do
    alias SymphonyElixir.PrWatch.SwitchTest.World

    def create(attrs, _opts) do
      identifier = "TP-FIX#{length(World.calls(:fix_ticket)) + 1}"
      World.call(:fix_ticket, {identifier, attrs})
      World.update(:fix_tickets, &Map.put(&1, identifier, "Todo"))
      {:ok, %{identifier: identifier, url: "https://linear.app/i/#{identifier}"}}
    end

    def attach(identifier, body, _opts), do: World.call(:evidence, {identifier, body})
    def block(issue, ticket, _opts), do: World.call(:blocked_by, {issue.id, ticket.identifier})
  end

  setup do
    start_supervised!(World)
    workflow!()
    :ok
  end

  defp workflow!(ci \\ %{}) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: Map.merge(%{enabled: true, log_excerpt_lines: 20}, ci)
    )
  end

  # A ticket in `state` with an open PR whose read `attrs` override a green, clean one.
  defp ticket!(id, state, attrs \\ []) do
    pr_url = "https://github.com/acme/app/pull/#{id}"
    issue = %Issue{id: "issue-#{id}", identifier: "TP-#{id}", title: "Ticket #{id}", state: state, url: "https://linear.app/i/TP-#{id}", labels: []}
    World.update(:issues, &Map.put(&1, issue.id, issue))
    :ok = TicketPullRequest.record_created(@repo_key, issue.id, pr_url, "auto/TP-#{id}")
    World.update(:prs, &Map.put(&1, pr_url, Map.merge(read(id), Map.new(attrs))))
    issue.id
  end

  defp read(id) do
    %{
      pr_url: "https://github.com/acme/app/pull/#{id}",
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

  defp red, do: [ci: :red, failing_check: "specs", failed_checks: [%{name: "specs", run_id: "77", workflow_name: "ci", conclusion: "FAILURE"}]]
  defp dirty, do: [mergeable: :dirty]

  # Red only on `protected paths`, which a person clears; `past` is what the other checks say.
  defp human_only(past) do
    failed = [%{name: "protected paths", run_id: "5"}]
    [ci: :red, red_kind: :human_only, past_human_only: past, failing_check: "protected paths", failed_checks: failed]
  end

  defp pr!(id, attrs), do: World.update(:prs, &Map.update!(&1, "https://github.com/acme/app/pull/#{id}", fn pr -> Map.merge(pr, Map.new(attrs)) end))
  defp pr(id), do: Map.fetch!(World.get(:prs), "https://github.com/acme/app/pull/#{id}")
  defp state(issue_id), do: World.get(:issues) |> Map.fetch!(issue_id) |> Map.fetch!(:state)
  defp move!(issue_id, state), do: World.update(:issues, &Map.update!(&1, issue_id, fn issue -> %{issue | state: state} end))

  defp start!(opts \\ []) do
    defaults = [
      repo_key: @repo_key,
      name: nil,
      auto: false,
      tracker: Tracker,
      github: GitHub,
      fetch: Fetch,
      fixer: Fixer,
      linker: Linker,
      interval_ms: 30_000,
      now: fn -> now() end
    ]

    start_supervised!({Repo, Keyword.merge(defaults, opts)})
  end

  # The watcher's clock, which the test moves on.
  defp now, do: World.get(:now)
  defp advance!(ms), do: World.update(:now, &DateTime.add(&1, ms, :millisecond))

  defp tick!(pid, times \\ 1) do
    for _n <- 1..times, do: assert({:ok, _summary} = Repo.poll(pid))
    :ok
  end

  defp watch(issue_id), do: @repo_key |> RunStore.get_ticket_state(issue_id) |> TicketState.pr_watch()

  # The workspace of the ticket's run, where the watcher reads the protected paths its PR changes.
  defp workspace!(issue_id) do
    workspace = Path.join(System.tmp_dir!(), "switch-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    run = %{repo_key: @repo_key, run_id: "run-#{issue_id}", issue_id: issue_id, status: "success", started_at: now()}
    :ok = RunStore.put_run(Map.put(run, :workspace_path, workspace))
    workspace
  end

  # A git that has every commit and whose PRs change `WORKFLOW.md` only; it tells the test of each diff.
  defp changes_workflow_md do
    test_pid = self()

    fn
      ["diff" | _args], cwd ->
        send(test_pid, {:diff, cwd})
        {"WORKFLOW.md\n", 0}

      _args, _cwd ->
        {"", 0}
    end
  end

  defp diffs(workspace, count \\ 0) do
    receive do
      {:diff, ^workspace} -> diffs(workspace, count + 1)
    after
      0 -> count
    end
  end

  defp decision(issue_id), do: watch(issue_id).decision
  defp attempts(issue_id), do: watch(issue_id).attempts

  defp moves(issue_id), do: for({^issue_id, state} <- World.calls(:move), do: state)
  defp comments(issue_id), do: for({^issue_id, body} <- World.calls(:comment), do: body)

  defp run!(issue_id, status) do
    :ok =
      RunStore.put_run(%{
        repo_key: @repo_key,
        run_id: "run-#{issue_id}",
        issue_id: issue_id,
        status: status,
        started_at: now(),
        workspace_path: "/tmp/ws"
      })
  end

  # Every commit is there, and the PR changes `changed` among the protected paths each diff asks about.
  defp protected_git(changed) do
    fn
      ["diff", "--name-only", "--no-renames", _range, "--" | paths], _cwd -> {Enum.join(Enum.filter(changed, &(&1 in paths)), "\n"), 0}
      _args, _cwd -> {"", 0}
    end
  end

  # The CI Fix run pushed `head` and handed the ticket back to `origin`, as `AgentRunner` does.
  defp fix_run_returns!(issue_id, id, origin, head, attrs) do
    assert state(issue_id) == "CI Fix"
    move!(issue_id, origin)
    pr!(id, Keyword.merge([head_sha: head], attrs))
  end

  defp seed_attempts!(issue_id, attempts) do
    SymphonyElixir.PrWatchSupport.update_watch!(@repo_key, issue_id, &%{&1 | attempts: Map.merge(&1.attempts, attempts)})
  end

  defp open_pull(number, files, attrs \\ []) do
    Map.merge(
      %{number: number, url: "https://github.com/acme/app/pull/#{number}", title: "Ticket #{number}", head_sha: "head-#{number}-1", files: files},
      Map.new(attrs)
    )
  end

  defp open_pulls!(pulls), do: World.update(:open_pulls, fn _ -> pulls end)

  defp assert_waits!(issue_id, reason, keys) do
    assert %{reason: ^reason, waits_on: %{type: "landing", keys: ^keys}} = Hold.get(@repo_key, issue_id, :blocked)
  end

  # A Merging ticket whose conflict exhausted its 3 fix runs, back in Merging on a conflicting head.
  defp exhausted!(id, attrs \\ []) do
    issue_id = ticket!(id, "Merging", dirty() ++ attrs)
    pid = start!()
    tick!(pid)
    fix_run_returns!(issue_id, id, "Merging", "head-#{id}-2", dirty())
    seed_attempts!(issue_id, %{conflict: 3})
    {pid, issue_id}
  end

  defp clear_fix_ticket_hold!(issue_id) do
    issue = %{Map.fetch!(World.get(:issues), issue_id) | repo_key: @repo_key}
    assert :clear = BlockedHold.sync(issue, Config.settings!().tracker.terminal_states, tracker: Tracker, build: %{sha: nil}, settings: Config.settings!())
  end

  describe "the red head of a reviewed ticket (TP-920/TP-892, D15 (c))" do
    test "reruns once, goes to CI Fix with its origin, again for each red head, and at 10 red runs files a fix ticket for CI" do
      issue_id = ticket!("1", "Code Review", red())
      pid = start!()

      for run <- 1..10 do
        head = "head-1-#{run}"
        pr!("1", head_sha: head)
        # Each run fails differently, so no same-failure streak cuts the 10 runs short.
        World.update(:log, fn _log -> "setup\nERROR: specs failed at stub_test.exs:#{run}\nstack" end)

        # The first read of a red head reruns its failed check; the head still red goes to CI Fix.
        tick!(pid)
        assert %{rule: "R22", kind: :rerun_failed} = decision(issue_id)
        tick!(pid)
        assert %{rule: "R21", kind: :ci_fix, reason: reason} = decision(issue_id)
        assert reason == "The `specs` check failed on PR #1: CI Fix run #{run} of 10"
        assert state(issue_id) == "CI Fix"
        assert CiFix.origin(@repo_key, issue_id) == "Code Review"

        # The run fixed nothing: it pushed a new head, still red, and handed the ticket back.
        fix_run_returns!(issue_id, "1", "Code Review", "head-1-#{run + 1}", red())
      end

      assert length(World.calls(:rerun)) == 10
      assert moves(issue_id) == List.duplicate("CI Fix", 10)
      assert %{red: 10, fix_failures: failures} = attempts(issue_id)
      assert length(failures) == 10
      assert hd(failures) == %{check: "specs", error: "ERROR: specs failed at stub_test.exs:1", head_sha: "head-1-1"}

      # The backstop: one fix ticket for the failing check, linked as a blocker, and a Blocked hold.
      tick!(pid)
      assert [{"TP-FIX1", %{component: "ci:specs", scope: @repo_key, title: "Self-heal: CI keeps failing the specs check", description: description}}] = World.calls(:fix_ticket)
      assert description =~ "The failure may be that pull request's own rather than this repo's CI"
      assert description =~ "https://github.com/acme/app/pull/1"
      assert World.calls(:blocked_by) == [{issue_id, "TP-FIX1"}]
      assert %{waits_on: %{type: "fix_ticket", keys: ["TP-FIX1"]}} = Hold.get(@repo_key, issue_id, :blocked)
      refute Hold.held?(@repo_key, issue_id, :needs_decision)

      assert %{rule: "R20", kind: :file_fix_ticket, reason: "CI keeps failing: waiting on TP-FIX1, a fix ticket for the `specs` check", owner: :symphony} =
               decision(issue_id)

      assert decision(issue_id).waits_on == %{type: "fix_ticket", keys: ["TP-FIX1"]}
      assert state(issue_id) == "Code Review"
      assert moves(issue_id) == List.duplicate("CI Fix", 10)

      # Held, the ticket waits on its fix ticket, and nothing is filed or moved again.
      tick!(pid, 3)
      assert %{rule: "R4", reason: "CI keeps failing: waiting on TP-FIX1, a fix ticket for the `specs` check"} = decision(issue_id)
      assert decision(issue_id).waits_on == %{type: "fix_ticket", keys: ["TP-FIX1"]}
      assert length(World.calls(:fix_ticket)) == 1
      assert moves(issue_id) == List.duplicate("CI Fix", 10)

      # The R20 wait as the state API shows it.
      assert PrWatch.dispatch_reason(Map.fetch!(World.get(:issues), issue_id), Config.settings!()) =~ "waiting on TP-FIX1"
    end

    test "a second ticket at the backstop on the same check reuses the open fix ticket, with its own evidence" do
      first = ticket!("1", "Code Review", red())
      second = ticket!("2", "QA", red())
      pid = start!()
      tick!(pid)

      for issue_id <- [first, second], do: seed_attempts!(issue_id, %{red: 10, fix_failures: [%{check: "specs", error: "ERROR in #{issue_id}"}]})
      tick!(pid)

      assert [{"TP-FIX1", _attrs}] = World.calls(:fix_ticket)
      assert World.calls(:blocked_by) == [{first, "TP-FIX1"}, {second, "TP-FIX1"}]

      for issue_id <- [first, second] do
        assert %{waits_on: %{type: "fix_ticket", keys: ["TP-FIX1"]}} = Hold.get(@repo_key, issue_id, :blocked)
      end

      assert [{"TP-FIX1", evidence}] = World.calls(:evidence)
      assert evidence =~ "TP-2"
      assert evidence =~ "ERROR in #{second}"
      assert evidence =~ "https://github.com/acme/app/pull/2"
    end

    test "the fix ticket landing clears the hold and restarts the red count; the same failure after it escalates once" do
      issue_id = ticket!("1", "Code Review", red())
      pid = start!()
      tick!(pid)
      seed_attempts!(issue_id, %{red: 10})
      tick!(pid)
      assert Hold.held?(@repo_key, issue_id, :blocked)

      # The fix ticket goes to Done: the hold clears by itself and the red count restarts.
      World.update(:fix_tickets, &Map.put(&1, "TP-FIX1", "Done"))
      clear_fix_ticket_hold!(issue_id)
      refute Hold.held?(@repo_key, issue_id, :blocked)

      # The red count reads 0 of 10, and the head, still red (and rerun already), goes to CI Fix again.
      tick!(pid)
      assert %{red_attempts: 0, max_red_attempts: 10} = watch(issue_id).facts
      assert %{rule: "R21", reason: "The `specs` check failed on PR #1: CI Fix run 1 of 10"} = decision(issue_id)
      assert %{red: 1, fix_ticket: nil} = attempts(issue_id)
      assert state(issue_id) == "CI Fix"

      # The same failure reaches the backstop again on the next head: the lane asks a person, once.
      fix_run_returns!(issue_id, "1", "Code Review", "head-1-2", red())
      seed_attempts!(issue_id, %{red: 10})
      tick!(pid, 3)

      assert [{"TP-FIX1", _attrs}] = World.calls(:fix_ticket)
      assert %{decision: %{title: "Self-heal is stuck on the ci:specs block"}} = Hold.get(@repo_key, issue_id, :needs_decision)
      assert [_one] = Enum.filter(comments(issue_id), &String.starts_with?(&1, "## Decision needed: Self-heal is stuck"))
      assert %{rule: "R4", owner: :person} = decision(issue_id)
    end

    test "a Merging ticket at the backstop has auto-merge turned off before the hold is set" do
      issue_id = ticket!("1", "Merging", red() ++ [auto_merge: :armed])
      pid = start!()
      tick!(pid)
      World.clear_calls()
      seed_attempts!(issue_id, %{red: 10})
      tick!(pid)

      order = World.all_calls() |> Enum.map(&elem(&1, 0)) |> Enum.filter(&(&1 in [:disarm, :fix_ticket, :label]))
      assert [:disarm, :fix_ticket, :label | _rest] = order
      assert pr("1").auto_merge == :off
      assert Hold.held?(@repo_key, issue_id, :blocked)
      assert state(issue_id) == "Merging"
    end

    test "max_fix_attempts set to 4 files the fix ticket at 4, while a conflict still gets 3 fix runs" do
      workflow!(%{max_retries: 4})
      red_id = ticket!("1", "QA", red())
      conflict_id = ticket!("2", "QA", dirty())
      pid = start!()
      tick!(pid)

      assert %{max_red_attempts: 4} = watch(red_id).facts
      assert %{rule: "R14", reason: "PR #2 conflicts with main: conflict fix run 1 of 3"} = decision(conflict_id)
      seed_attempts!(red_id, %{red: 3})
      tick!(pid)
      assert %{rule: "R21", reason: "The `specs` check failed on PR #1: CI Fix run 4 of 4"} = decision(red_id)

      fix_run_returns!(red_id, "1", "QA", "head-1-2", red())
      tick!(pid)
      assert %{rule: "R20"} = decision(red_id)
      assert [{"TP-FIX1", _attrs}] = World.calls(:fix_ticket)

      # In CI Fix, the run sent for the conflict takes it: no second attempt.
      assert %{rule: "R14", reason: "The CI Fix run already sent for this head takes the fix"} = decision(conflict_id)
      assert %{conflict: 1} = attempts(conflict_id)
      fix_run_returns!(conflict_id, "2", "QA", "head-2-2", dirty())
      seed_attempts!(conflict_id, %{conflict: 3})
      tick!(pid)
      assert %{rule: "R15a", kind: :to_rework} = decision(conflict_id)
    end

    test "red and conflict keep separate counts: after 2 red and 1 conflict, a red head still goes to CI Fix as run 3 of 10" do
      issue_id = ticket!("1", "Code Review", red())
      pid = start!()
      tick!(pid)
      seed_attempts!(issue_id, %{red: 2, conflict: 1})
      tick!(pid)

      assert %{red_attempts: 2, conflict_attempts: 1} = watch(issue_id).facts
      assert %{rule: "R21", reason: "The `specs` check failed on PR #1: CI Fix run 3 of 10"} = decision(issue_id)
      assert %{red: 3, conflict: 1} = attempts(issue_id)
    end

    test "a conflicting PR whose checks read green resets neither count; a green, conflict-free head resets both" do
      issue_id = ticket!("1", "Code Review", dirty() ++ [head_sha: "head-1-9"])
      pid = start!()
      tick!(pid)
      assert state(issue_id) == "CI Fix"
      fix_run_returns!(issue_id, "1", "Code Review", "head-1-10", dirty())
      seed_attempts!(issue_id, %{red: 2, conflict: 2})

      tick!(pid)
      assert %{red: 2, conflict: 3} = attempts(issue_id)

      fix_run_returns!(issue_id, "1", "Code Review", "head-1-11", ci: :green, mergeable: :clean)
      tick!(pid)
      assert %{red: 0, conflict: 0} = attempts(issue_id)
      assert %{rule: "R27", kind: :dispatch} = decision(issue_id)

      # A later conflict starts again at attempt 1.
      pr!("1", dirty())
      tick!(pid)
      assert %{rule: "R14", reason: "PR #1 conflicts with main: conflict fix run 1 of 3"} = decision(issue_id)
    end
  end

  describe "CI cases nothing handled before (TP-943)" do
    defp timeout_ms, do: Config.settings!().ci.merging_wait_timeout_ms

    # A person answers the ticket's open question, as the Inbox records it: the answer in the
    # ticket's decisions, then the hold cleared.
    defp answer!(issue_id, key, title, answer) do
      entry = SymphonyElixir.Decisions.entry(key, ~D[2026-10-16], title, title, answer)
      {:ok, _decisions} = RunStore.record_ticket_decisions(@repo_key, issue_id, [entry], [])
      :ok = Hold.clear(@repo_key, issue_id, :needs_decision, tracker: Tracker)
    end

    defp asked(issue_id, title), do: Enum.count(comments(issue_id), &(&1 =~ "## Decision needed: #{title}"))

    test "walkthrough 1: a repo with no workflows gets its reviewer on a head with no checks (G1, D2)" do
      issue_id = ticket!("1", "Code Review", ci: :none, check_names: [])
      pid = start!()
      tick!(pid)

      assert %{rule: "R27", kind: :dispatch, reason: "No CI configured on main: counts as green, so the reviewer runs"} = decision(issue_id)
      assert PrWatch.dispatch_reason(Map.fetch!(World.get(:issues), issue_id), Config.settings!()) == nil
    end

    test "a head with no checks while the base has workflows waits for them, and goes on without them past the wait" do
      issue_id = ticket!("1", "QA", ci: :pending, awaiting_checks: true, check_names: [])
      pid = start!()
      tick!(pid)
      assert %{rule: "R24", kind: :wait, owner: :ci} = decision(issue_id)

      advance!(timeout_ms())
      tick!(pid)
      assert %{rule: "R27", reason: "No check reported on the head within the wait: counts as green, so the QA agent runs"} = decision(issue_id)
    end

    test "walkthrough 2–3: a required check that never reports asks a person past the wait; proceeding waives it for that head only (G2, D3)" do
      issue_id = ticket!("1", "Code Review", ci: :required_missing, missing_checks: ["build"], run_ids: ["40", "41"])
      title = "Check build never reported on TP-1"
      pid = start!()

      # Within the wait the head reads as running, in any phase.
      tick!(pid)
      assert %{rule: "R24", kind: :wait} = decision(issue_id)
      refute Hold.held?(@repo_key, issue_id, :needs_decision)

      advance!(timeout_ms())
      tick!(pid, 3)
      assert %{decision: %{title: ^title, options: options}} = Hold.get(@repo_key, issue_id, :needs_decision)
      assert Enum.map(options, & &1.label) == ["Proceed without it for this PR", "Rerun the checks", "Fix the workflow in Rework"]
      assert asked(issue_id, title) == 1
      assert %{rule: "R4", owner: :person} = decision(issue_id)
      assert state(issue_id) == "Code Review"

      # Proceed: the ticket continues on that head.
      answer!(issue_id, "c1", title, "Proceed without it for this PR")
      tick!(pid)
      assert %{rule: "R27", kind: :dispatch} = decision(issue_id)
      assert %{ci: :green} = watch(issue_id).facts

      # A new head waits for the check again, and asks again past the wait.
      pr!("1", head_sha: "head-1-2")
      tick!(pid)
      assert %{rule: "R24"} = decision(issue_id)
      advance!(timeout_ms())
      tick!(pid)
      assert asked(issue_id, title) == 2

      # Rerun: the head's runs run again (one GitHub refused is logged), and the wait starts over.
      answer!(issue_id, "c2", title, "2")
      assert capture_log(fn -> tick!(pid) end) =~ "PR watch could not rerun run 41"
      assert World.calls(:rerun_all) == [{"40", "acme/app"}, {"41", "acme/app"}]
      assert %{rule: "R24"} = decision(issue_id)
      advance!(timeout_ms())
      tick!(pid)
      assert asked(issue_id, title) == 3

      # Fix the workflow in Rework: the answer moved it there; the rework run goes ahead and nothing is asked again.
      answer!(issue_id, "c3", title, "Fix the workflow in Rework")
      move!(issue_id, "Rework")
      tick!(pid, 2)
      assert %{rule: "R26", kind: :dispatch} = decision(issue_id)
      assert asked(issue_id, title) == 3
    end

    test "an answer that picks no option asks again once the wait passes again" do
      issue_id = ticket!("1", "QA", ci: :required_missing, missing_checks: ["build"])
      pid = start!()
      tick!(pid)
      advance!(timeout_ms())
      tick!(pid, 2)
      assert asked(issue_id, "Check build never reported on TP-1") == 1
      answer!(issue_id, "c1", "Check build never reported on TP-1", "not sure")
      tick!(pid)
      assert %{rule: "R24"} = decision(issue_id)
      advance!(timeout_ms())
      tick!(pid)
      assert asked(issue_id, "Check build never reported on TP-1") == 2
    end

    test "a check red on the base too waits on CI, spends no CI Fix, is logged once per base and clears once the base is green" do
      first = ticket!("1", "QA", red() ++ [red_kind: :also_red_on_base])
      second = ticket!("2", "Code Review", red() ++ [red_kind: :also_red_on_base])
      pid = start!()

      log = capture_log(fn -> tick!(pid, 3) end)
      assert %{rule: "R23", kind: :wait, owner: :ci, reason: "The `specs` check is red on the base branch too"} = decision(first)
      assert %{rule: "R23"} = decision(second)
      assert [_once] = Regex.scan(~r/the `specs` check is red on main too/, log)
      assert moves(first) == [] and moves(second) == []
      assert World.calls(:rerun) == []
      assert %{red: 0} = attempts(first)
      assert PrWatch.red_bases() == [%{base: "main", check: "specs", issue_identifiers: ["TP-1", "TP-2"]}]

      # The base went green: the head is a plain failure again, and the wait is gone.
      pr!("1", red_kind: :failure)
      pr!("2", red_kind: :failure)
      log = capture_log(fn -> tick!(pid) end)
      assert log =~ "no PR waits on the `specs` check of main any more"
      assert PrWatch.red_bases() == []
      assert %{rule: "R22"} = decision(first)
    end

    test "a workflow whose every run was cancelled is rerun once per cancellation, with no attempt spent (R19)" do
      cancelled = [red_kind: :cancelled, failed_checks: [%{name: "specs", run_id: "77", workflow_name: "ci", conclusion: "CANCELLED"}]]
      issue_id = ticket!("1", "Code Review", red() ++ cancelled)
      pid = start!()
      tick!(pid)
      assert %{rule: "R19", kind: :rerun_failed, outcome: :applied} = decision(issue_id)

      # Reads before GitHub queues the rerun wait on it, and never rerun the same cancellation again.
      tick!(pid, 2)
      assert World.calls(:rerun) == ["77"]
      assert %{rule: "R19", kind: :wait, owner: :ci, clears_when: "the rerun reports"} = decision(issue_id)
      assert %{red: 0, fix_failures: []} = attempts(issue_id)
      assert moves(issue_id) == []

      # A rerun that never reports is a silent wait past the CI bound, its line naming what is stuck.
      advance!(Config.settings!().ci.merging_wait_timeout_ms + 1)
      log = capture_log(fn -> tick!(pid) end)
      assert log =~ "pr_watch.silent_wait issue_id=#{issue_id} issue_identifier=TP-1"
      assert log =~ "rule=R19 bound=ci.merging_wait_timeout_ms"
      assert log =~ ~s(action=wait decision="Symphony reran the `specs` check after GitHub cancelled it: waiting for the rerun to report")
    end

    # The head red only on `checks`, cancelled by GitHub; `names` are every check the head reports.
    defp cancelled(checks, names) do
      [ci: :red, red_kind: :cancelled, failing_check: hd(checks).name, failed_checks: checks]
      |> Keyword.merge(check_names: names, past_cancelled: nil)
    end

    test "walkthrough 1: two workflows cancelled minutes apart on one head are each rerun as they are cancelled (R19)" do
      e2e = %{name: "update, restart and rollback", run_id: "39571199789", job_id: 1, workflow_name: "macos-e2e", conclusion: "CANCELLED"}
      install = %{name: "install script", run_id: "39571199843", job_id: 2, workflow_name: "macos", conclusion: "CANCELLED"}
      names = ["specs", e2e.name, install.name]
      running = [ci: :pending, red_kind: :failure, failing_check: nil, failed_checks: []]
      issue_id = ticket!("1", "Code Review", cancelled([e2e], names))
      pid = start!()

      tick!(pid)
      assert World.calls(:rerun) == ["39571199789"]
      assert %{rule: "R19", kind: :rerun_failed, outcome: :applied} = decision(issue_id)

      # GitHub queues the rerun: the head reads as running.
      pr!("1", running)
      tick!(pid)
      assert %{rule: "R24", kind: :wait} = decision(issue_id)

      # Minutes later the other workflow's run is cancelled on the same head: rerun at the next read.
      pr!("1", cancelled([install], names))
      tick!(pid)
      assert World.calls(:rerun) == ["39571199789", "39571199843"]
      assert %{rule: "R19", kind: :rerun_failed, outcome: :applied} = decision(issue_id)

      # The first rerun is cancelled again by GitHub: a new attempt, so new job ids, rerun once more.
      pr!("1", cancelled([%{e2e | job_id: 3}], names))
      tick!(pid)
      assert World.calls(:rerun) == ["39571199789", "39571199843", "39571199789"]

      # Both pass: the reviewer runs, and no CI Fix attempt was spent.
      pr!("1", ci: :green, red_kind: :failure, failing_check: nil, failed_checks: [])
      tick!(pid)
      assert %{rule: "R27", kind: :dispatch} = decision(issue_id)
      assert %{red: 0, fix_failures: []} = attempts(issue_id)
      assert moves(issue_id) == []
    end

    test "a rerun of a cancelled check that dropped out of the rollup keeps the head running" do
      install = %{name: "install script", run_id: "22", job_id: 2, workflow_name: "macos", conclusion: "CANCELLED"}
      issue_id = ticket!("1", "QA", cancelled([install], ["specs", "install script"]))
      pid = start!()
      tick!(pid)

      pr!("1", ci: :green, red_kind: :failure, failing_check: nil, failed_checks: [], check_names: ["specs"])
      tick!(pid)
      assert %{rule: "R24", kind: :wait} = decision(issue_id)
      refute watch(issue_id).attempts.reruns |> Map.has_key?("head-1-1")
    end

    test "walkthrough 2: a check cancelled a third time in a row asks to keep retrying or wait, naming the check and the cause (R19a)" do
      install = %{name: "install script", run_id: "39571199843", job_id: 2, workflow_name: "macos", conclusion: "CANCELLED"}
      names = ["specs", "install script"]
      title = "Check install script keeps being cancelled on TP-1"
      cancel! = fn job -> pr!("1", cancelled([%{install | job_id: job}], names)) end
      issue_id = ticket!("1", "QA", cancelled([install], names))
      pid = start!()

      # Cancelled twice: rerun twice.
      tick!(pid)
      cancel!.(3)
      tick!(pid)
      assert World.calls(:rerun) == ["39571199843", "39571199843"]

      # A third time: the person is asked, and nothing is rerun or spent.
      cancel!.(4)
      tick!(pid, 2)
      assert World.calls(:rerun) == ["39571199843", "39571199843"]
      assert %{decision: %{title: ^title, question: question, why: why, options: options}} = Hold.get(@repo_key, issue_id, :needs_decision)
      assert question == "GitHub cancelled the install script check on PR #1 of TP-1 3 times in a row without running it. Should Symphony keep retrying it, or wait?"
      assert why =~ "GitHub cancels a check it can't find a machine for, as happens when its macOS machines are busy."
      assert Enum.map(options, & &1.label) == ["Keep retrying", "Wait"]
      assert asked(issue_id, title) == 1
      assert %{rule: "R4", owner: :person} = decision(issue_id)
      assert %{red: 0} = attempts(issue_id)
      assert state(issue_id) == "QA"

      # Keep retrying: rerun at once, and the bound starts again.
      answer!(issue_id, "c1", title, "Keep retrying")
      tick!(pid)
      assert length(World.calls(:rerun)) == 3
      cancel!.(5)
      tick!(pid)
      assert length(World.calls(:rerun)) == 4
      cancel!.(6)
      tick!(pid)
      assert asked(issue_id, title) == 2
      assert length(World.calls(:rerun)) == 4

      # Wait: nothing more is rerun or asked on the head, even when a person's rerun is cancelled again.
      answer!(issue_id, "c2", title, "Wait")
      tick!(pid)
      cancel!.(7)
      tick!(pid, 2)
      assert length(World.calls(:rerun)) == 4
      assert asked(issue_id, title) == 2
      assert %{rule: "R19a", kind: :wait, owner: :person} = decision(issue_id)

      # A new head starts afresh.
      pr!("1", [head_sha: "head-1-2"] ++ cancelled([%{install | job_id: 8}], names))
      tick!(pid)
      assert length(World.calls(:rerun)) == 5
    end

    test "a check the base doesn't require, cancelled again after its reruns, is set aside instead of holding the ticket" do
      install = %{name: "install script", run_id: "22", job_id: 2, workflow_name: "macos", conclusion: "CANCELLED"}
      names = ["specs", "install script"]
      issue_id = ticket!("1", "Code Review", cancelled([install], names) ++ [past_cancelled: :green])
      pid = start!()

      for job <- [3, 4] do
        tick!(pid)
        assert %{rule: "R19", kind: :rerun_failed} = decision(issue_id)
        pr!("1", cancelled([%{install | job_id: job}], names) ++ [past_cancelled: :green])
      end

      tick!(pid)
      assert %{rule: "R27", kind: :dispatch, reason: reason} = decision(issue_id)
      assert reason =~ "`install script`, cancelled again after 2 reruns, is set aside"
      refute Hold.held?(@repo_key, issue_id, :needs_decision)
      assert World.calls(:rerun) == ["22", "22"]
      assert %{ci: :green, set_aside: ["install script"]} = watch(issue_id).facts
    end

    test "walkthrough 4: the same failure 3 CI Fix runs in a row files a fix ticket and holds the ticket, with no question (D15 (c))" do
      heads = ["aaaaaaa1", "bbbbbbb2", "ccccccc3", "ddddddd4"]
      issue_id = ticket!("1", "Code Review", red() ++ [head_sha: hd(heads)])
      pid = start!()

      for {head, run} <- Enum.with_index(Enum.take(heads, 3), 1) do
        tick!(pid)
        assert %{rule: "R22"} = decision(issue_id)
        # Twice in a row is not enough: another CI Fix run.
        assert %{same_failure_streak: streak} = watch(issue_id).facts
        assert streak == run - 1

        tick!(pid)
        assert %{rule: "R21", reason: reason} = decision(issue_id)
        assert reason == "The `specs` check failed on PR #1: CI Fix run #{run} of 10"
        # The fix run reads what the runs before it failed on.
        assert %{ci_failure: %{earlier_failures: earlier}} = watch(issue_id).fix
        assert length(earlier) == run - 1
        assert attempts(issue_id).failure.head_sha == head

        fix_run_returns!(issue_id, "1", "Code Review", Enum.at(heads, run), red())
      end

      tick!(pid)
      assert %{same_failure_streak: 3, red_attempts: 3} = watch(issue_id).facts
      assert %{rule: "R20", kind: :file_fix_ticket, reason: "CI keeps failing: waiting on TP-FIX1, a fix ticket for the `specs` check"} = decision(issue_id)

      assert [{"TP-FIX1", %{component: "ci:specs", description: description}}] = World.calls(:fix_ticket)
      assert description =~ "after 3 of 10 CI Fix runs, the last 3 in a row with the same failure"

      for head <- Enum.take(heads, 3) do
        assert description =~ "specs at #{String.slice(head, 0, 7)}: ERROR: specs failed at stub_test.exs:21"
      end

      assert World.calls(:blocked_by) == [{issue_id, "TP-FIX1"}]
      assert %{waits_on: %{type: "fix_ticket", keys: ["TP-FIX1"]}} = Hold.get(@repo_key, issue_id, :blocked)
      refute Hold.held?(@repo_key, issue_id, :needs_decision)
      assert state(issue_id) == "Code Review"

      # The lane keeps the same signature the streak compared.
      lane = TicketState.self_heal(RunStore.get_ticket_state(@repo_key, issue_id))
      assert lane.signature == Attempts.signature(attempts(issue_id).failure)

      tick!(pid)
      assert %{rule: "R4", reason: "CI keeps failing: waiting on TP-FIX1, a fix ticket for the `specs` check"} = decision(issue_id)
    end

    test "a different failure in between resets the streak" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()

      for {error, run} <- Enum.with_index(["ERROR: one", "ERROR: two", "ERROR: one"], 1) do
        World.update(:log, fn _log -> "setup\n#{error}\nstack" end)
        tick!(pid, 2)
        assert %{rule: "R21"} = decision(issue_id)
        fix_run_returns!(issue_id, "1", "QA", "head-1-#{run + 1}", red())
      end

      tick!(pid)
      assert %{same_failure_streak: 1, red_attempts: 3} = watch(issue_id).facts
      assert %{rule: "R22"} = decision(issue_id)
    end
  end

  describe "Merging (TP-896, TP-921/TP-891, D4)" do
    test "a red, armed Merging PR has auto-merge turned off and goes to CI Fix; back on a new head, auto-merge is on again" do
      issue_id = ticket!("1", "Merging", red() ++ [auto_merge: :armed])
      pid = start!()

      tick!(pid)
      # A rerun of the same commit keeps auto-merge on.
      assert %{rule: "R22"} = decision(issue_id)
      assert World.calls(:disarm) == []

      tick!(pid)
      assert %{rule: "R21"} = decision(issue_id)
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
      assert state(issue_id) == "CI Fix"
      assert CiFix.origin(@repo_key, issue_id) == "Merging"
      assert %{ci_failure: %{approved: true}} = watch(issue_id).fix
      assert Enum.any?(comments(issue_id), &(&1 =~ "because CI failed and a fix run may push new code"))

      fix_run_returns!(issue_id, "1", "Merging", "head-1-2", ci: :pending, mergeable: :blocked, failed_checks: [])
      tick!(pid)
      assert %{rule: "R30", kind: :arm} = decision(issue_id)
      assert World.calls(:arm) == [{"https://github.com/acme/app/pull/1", "head-1-2"}]

      # Auto-merge lands it once the checks pass, and the ticket is Done.
      pr!("1", pr: :merged)
      tick!(pid)
      assert %{rule: "R2", kind: :close_out} = decision(issue_id)
      assert List.last(moves(issue_id)) == "Done"
      assert %{state: "merged"} = TicketPullRequest.get(@repo_key, issue_id)
    end

    test "a conflicting Merging PR waits for its run to end, then goes to CI Fix, with no arm/disarm flapping over 10 ticks" do
      issue_id = ticket!("1", "Merging", dirty() ++ [auto_merge: :armed])
      run!(issue_id, "running")
      pid = start!()

      tick!(pid, 3)
      assert %{rule: "R9", kind: :wait} = decision(issue_id)
      assert moves(issue_id) == []

      run!(issue_id, "success")
      tick!(pid, 10)

      assert moves(issue_id) == ["CI Fix"]
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
      assert World.calls(:arm) == []
      assert %{conflict: 1} = attempts(issue_id)
      assert %{pr_conflict: %{approved: true, retry_count: 1}} = watch(issue_id).fix
    end

    test "a Merging PR that conflicts while a PR sharing its files is ahead waits, auto-merge off, and gets one CI Fix once that one merged" do
      leader = ticket!("1", "Merging", ci: :pending, mergeable: :blocked)
      follower = ticket!("2", "Merging", dirty() ++ [auto_merge: :armed])

      World.update(:open_pulls, fn _ ->
        [%{number: 1, head_sha: "head-1-1", files: ["lib/a.ex"]}, %{number: 2, head_sha: "head-2-1", files: ["lib/a.ex", "lib/b.ex"]}]
      end)

      pid = start!()
      # The leader entered Merging first.
      tick!(pid)

      assert %{rule: "R14a", kind: :wait_for_competitors, reason: "Lands after TP-1: they change the same files (lib/a.ex)", owner: :symphony} =
               decision(follower)

      # The wait is a Blocked hold naming the leader, which reads as the wait on later ticks.
      tick!(pid, 2)
      reason = "Waiting on TP-1 to land: they change the same files (lib/a.ex)"
      assert %{rule: "R4", kind: :wait, reason: ^reason, owner: :symphony} = decision(follower)
      assert decision(follower).waits_on == %{type: "pull_request", keys: ["TP-1"]}
      assert moves(follower) == []
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/2"]
      assert World.calls(:link) == [{"TP-1", follower}]
      assert [%{issue_identifier: "TP-2", waits_for: %{issue_identifier: "TP-1"}, reason: ^reason}] = PrWatch.landing_waits()

      # The leader merged and left the open PRs: the follower's conflict gets one fix run.
      pr!("1", pr: :merged)
      World.update(:open_pulls, fn _ -> [%{number: 2, head_sha: "head-2-1", files: ["lib/a.ex", "lib/b.ex"]}] end)
      tick!(pid, 3)

      assert moves(leader) == ["Done"]
      assert moves(follower) == ["CI Fix"]
      assert %{rule: "R14"} = decision(follower)
      assert World.calls(:unlink) == []
    end

    test "a Merging PR that conflicts while a QA PR sharing SPEC.md is ahead waits on it as a blocked-by link and a landing hold (TP-989)" do
      leader = ticket!("1", "QA", ci: :pending, mergeable: :blocked)
      follower = ticket!("2", "Merging", dirty() ++ [auto_merge: :armed])
      World.update(:open_pulls, fn _ -> [open_pull(1, ["SPEC.md"]), open_pull(2, ["SPEC.md", "lib/b.ex"])] end)

      pid = start!()
      tick!(pid)

      # The conflicting PR can't land before a fix run, so the conflict-free QA PR goes first.
      assert %{rule: "R14a", kind: :wait_for_competitors, outcome: :applied} = decision(follower)
      assert decision(leader).rule != "R14a"
      assert_waits!(follower, "Waiting on TP-1 to land: they change the same files (SPEC.md)", ["TP-1"])
      assert World.calls(:link) == [{"TP-1", follower}]
      assert %{blocked_by: [%{identifier: "TP-1"}]} = World.get(:issues)[follower]
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/2"]
      assert {follower, "Blocked"} in World.calls(:label)
      assert [%{issue_identifier: "TP-1", linked: true, step_behind: false, files: ["SPEC.md"]}] = watch(follower).links

      tick!(pid, 2)
      assert moves(follower) == []
      assert state(follower) == "Merging"
      assert World.calls(:link) == [{"TP-1", follower}]

      # The leader lands: on the next tick the hold clears, the link stays, and one CI Fix runs for the conflict.
      pr!("1", pr: :merged)
      World.update(:open_pulls, fn _ -> [open_pull(2, ["SPEC.md", "lib/b.ex"])] end)
      tick!(pid)

      refute Hold.held?(@repo_key, follower, :blocked)
      assert World.calls(:unlink) == []
      assert %{blocked_by: [%{identifier: "TP-1"}]} = World.get(:issues)[follower]
      assert moves(follower) == ["CI Fix"]
      assert %{rule: "R14"} = decision(follower)
      assert CiFix.origin(@repo_key, follower) == "Merging"
      assert watch(follower).links == []

      tick!(pid, 2)
      assert moves(follower) == ["CI Fix"]
    end

    test "a PR keeps its landing place while its ticket sits in CI Fix: the state the stay returns to counts" do
      fixing = ticket!("1", "CI Fix", red())
      :ok = CiFix.record_origin(@repo_key, fixing, "Merging")
      reviewed = ticket!("2", "QA", dirty())

      World.update(:open_pulls, fn _ ->
        [%{number: 1, head_sha: "head-1-1", files: ["lib/a.ex"]}, %{number: 2, head_sha: "head-2-1", files: ["lib/a.ex"]}]
      end)

      pid = start!()
      tick!(pid)

      assert decision(fixing).rule != "R14a"
      assert %{rule: "R14a", reason: "Lands after TP-1: they change the same files (lib/a.ex)"} = decision(reviewed)
      assert moves(reviewed) == []
    end

    test "a third conflict fix run that leaves the PR conflicting, with nobody competing, sends it to Rework (D16), with no question" do
      issue_id = ticket!("1", "Merging", dirty() ++ [auto_merge: :armed])
      pid = start!()

      for run <- 1..3 do
        tick!(pid)
        assert %{rule: "R14", reason: reason} = decision(issue_id)
        assert reason == "PR #1 conflicts with main: conflict fix run #{run} of 3"
        fix_run_returns!(issue_id, "1", "Merging", "head-1-#{run + 1}", dirty())
      end

      tick!(pid)
      reason = "The conflict with main came back after 3 fix runs and no open PR competes"
      assert %{rule: "R15a", kind: :to_rework, reason: ^reason} = decision(issue_id)
      assert List.last(moves(issue_id)) == "Rework"
      assert Enum.any?(comments(issue_id), &(&1 =~ reason))
      assert pr("1").auto_merge == :off
      refute Hold.held?(@repo_key, issue_id, :needs_decision)
    end

    test "a person's push in Merging turns auto-merge off and sends the ticket back to Code Review (D4)" do
      issue_id = ticket!("1", "Merging", ci: :pending, mergeable: :clean, auto_merge: :armed)
      pid = start!()
      tick!(pid)
      assert %{rule: "R32"} = decision(issue_id)

      pr!("1", head_sha: "head-1-person")
      tick!(pid)

      assert %{rule: "R11", kind: :to_code_review} = decision(issue_id)
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
      assert moves(issue_id) == ["Code Review"]
    end

    test "BEHIND gets one update-branch per head, whose old head's runs are cancelled; BEHIND behind another PR waits" do
      issue_id = ticket!("1", "Merging", mergeable: :behind, ci: :green)
      pid = start!()

      tick!(pid, 3)
      assert %{rule: "R28", kind: :update_branch} = decision(issue_id)
      assert World.calls(:update_branch) == [{"https://github.com/acme/app/pull/1", "head-1-1"}]

      # GitHub merged the base in: a new head, behind again once the base moved on.
      pr!("1", head_sha: "head-1-2")
      tick!(pid, 2)
      assert World.calls(:cancel_stale_runs) == [{"https://github.com/acme/app/pull/1", "head-1-1"}]
      assert World.calls(:update_branch) == [{"https://github.com/acme/app/pull/1", "head-1-1"}, {"https://github.com/acme/app/pull/1", "head-1-2"}]
      # An update-branch's head is Symphony's, not a person's.
      assert moves(issue_id) == []

      follower = ticket!("2", "Merging", mergeable: :behind)
      World.update(:open_pulls, fn _ -> [%{number: 1, head_sha: "head-1-2", files: ["x"]}, %{number: 2, head_sha: "head-2-1", files: ["x"]}] end)
      tick!(pid, 2)
      assert %{rule: "R28", kind: :wait, reason: "PR #2 is behind main and lands after TP-1: they change the same files (x)"} = decision(follower)
      refute Enum.any?(World.calls(:update_branch), &match?({"https://github.com/acme/app/pull/2", _head}, &1))
    end

    test "CLEAN and green merges now, once" do
      issue_id = ticket!("1", "Merging")
      pid = start!()
      tick!(pid, 3)

      assert %{rule: "R29", kind: :merge_now} = decision(issue_id)
      assert World.calls(:merge) == [{"https://github.com/acme/app/pull/1", "head-1-1"}]
    end

    test "BLOCKED on a green head past the merge wait hands the PR to the landing agent" do
      issue_id = ticket!("1", "Merging", mergeable: :blocked, auto_merge: :armed)
      pid = start!()
      tick!(pid)
      assert %{rule: "R33"} = decision(issue_id)
      refute PrWatch.dispatch_reason(Map.fetch!(World.get(:issues), issue_id), Config.settings!()) == nil

      advance!(Config.settings!().ci.merging_wait_timeout_ms)
      tick!(pid, 2)

      assert %{rule: "R31", kind: :land_agent} = decision(issue_id)
      assert [_one] = Enum.filter(comments(issue_id), &(&1 =~ "so a landing agent will merge it instead"))
      assert PrWatch.dispatch_reason(Map.fetch!(World.get(:issues), issue_id), Config.settings!()) == nil
    end
  end

  describe "competing PRs wait as blocked-by links (TP-989, D14)" do
    # TP-2 (Merging) conflicts while TP-1 (QA), sharing SPEC.md, is ahead: it waits on TP-1.
    defp waiting!(attrs \\ []) do
      leader = ticket!("1", "QA", ci: :pending, mergeable: :blocked)
      follower = ticket!("2", "Merging", dirty())
      Enum.each(Keyword.get(attrs, :blocked_by, []), fn blocker -> World.update(:issues, &Map.update!(&1, follower, fn issue -> %{issue | blocked_by: [blocker]} end)) end)
      open_pulls!([open_pull(1, ["SPEC.md"]), open_pull(2, ["SPEC.md"])])
      pid = start!()
      tick!(pid)
      assert_waits!(follower, "Waiting on TP-1 to land: they change the same files (SPEC.md)", ["TP-1"])
      {pid, leader, follower}
    end

    defp left_race!(pid, follower) do
      tick!(pid)
      assert World.calls(:unlink) == [{"TP-1", follower}]
      assert World.get(:issues)[follower].blocked_by == []
      refute Hold.held?(@repo_key, follower, :blocked)
      assert moves(follower) == ["CI Fix"]
      assert watch(follower).links == []
    end

    test "the leader's PR closed without merging: Symphony removes the link it added and the hold clears" do
      {pid, _leader, follower} = waiting!()
      pr!("1", pr: :closed)
      open_pulls!([open_pull(2, ["SPEC.md"])])
      left_race!(pid, follower)
    end

    test "the leader gains a hold: it leaves the race" do
      {pid, leader, follower} = waiting!()
      :ok = Hold.set(@repo_key, leader, :needs_decision, %{reason: "A question"}, tracker: Tracker)
      left_race!(pid, follower)
    end

    test "the leader idle two hours leaves the race" do
      {pid, _leader, follower} = waiting!()
      advance!(2 * 60 * 60 * 1000)
      left_race!(pid, follower)
    end

    test "the leader no longer sharing a file leaves the race" do
      {pid, _leader, follower} = waiting!()
      open_pulls!([open_pull(1, ["lib/other.ex"]), open_pull(2, ["SPEC.md"])])
      left_race!(pid, follower)
    end

    test "a link a person added is never removed" do
      {pid, _leader, follower} = waiting!(blocked_by: [%{id: "issue-1", identifier: "TP-1", state: "QA"}])
      assert World.calls(:link) == []
      assert [%{linked: false}] = watch(follower).links

      pr!("1", pr: :closed)
      open_pulls!([open_pull(2, ["SPEC.md"])])
      tick!(pid)

      assert World.calls(:unlink) == []
      assert [%{identifier: "TP-1"}] = World.get(:issues)[follower].blocked_by
      refute Hold.held?(@repo_key, follower, :blocked)
    end

    test "a restart keeps the hold and the record of Symphony's links" do
      {_pid, _leader, follower} = waiting!()
      stop_supervised!({Repo, @repo_key})

      assert [%{issue_identifier: "TP-1", linked: true}] = @repo_key |> RunStore.get_ticket_state(follower) |> TicketState.pr_watch() |> Map.fetch!(:links)
      assert Hold.held?(@repo_key, follower, :blocked)

      pid = start!()
      tick!(pid)
      assert %{rule: "R4", reason: "Waiting on TP-1 to land" <> _} = decision(follower)

      pr!("1", pr: :closed)
      open_pulls!([open_pull(2, ["SPEC.md"])])
      left_race!(pid, follower)
    end

    test "open PRs that can't be read keep the wait as it is" do
      {pid, _leader, follower} = waiting!()
      open_pulls!(:error)
      capture_log(fn -> tick!(pid) end)

      assert Hold.held?(@repo_key, follower, :blocked)
      assert [%{linked: true}] = watch(follower).links
      assert World.calls(:unlink) == []
    end

    test "a ticket that leaves the watched states ends its wait" do
      {pid, _leader, follower} = waiting!()
      move!(follower, "Todo")
      tick!(pid)

      refute Hold.held?(@repo_key, follower, :blocked)
      assert World.calls(:unlink) == [{"TP-1", follower}]
    end

    test "a person's Unblock removes Symphony's links and the ticket no longer waits on those PRs" do
      {pid, _leader, follower} = waiting!()
      assert :ok = Repo.release(pid, follower)
      :ok = Hold.clear(@repo_key, follower, :blocked, tracker: Tracker)
      assert World.calls(:unlink) == [{"TP-1", follower}]
      assert [%{released: true, linked: false}] = watch(follower).links

      tick!(pid)
      assert moves(follower) == ["CI Fix"]
      assert World.calls(:link) == [{"TP-1", follower}]
      assert [%{released: true}] = watch(follower).links

      # The released PR merged: nothing is left to remember.
      pr!("1", pr: :merged)
      open_pulls!([open_pull(2, ["SPEC.md"])])
      tick!(pid)
      assert watch(follower).links == []
    end

    test "a conflict back after three fix runs steps behind every competing PR, so the one behind no longer waits for it" do
      {pid, stepping} = exhausted!("2")
      # TP-1's QA PR is in CI Fix with a run; TP-3's PR is In Progress: both conflict too, so both rank behind TP-2.
      ahead = ticket!("1", "CI Fix", dirty())
      :ok = CiFix.record_origin(@repo_key, ahead, "QA")
      run!(ahead, "running")
      behind = ticket!("3", "In Progress", dirty())
      open_pulls!([open_pull(1, ["SPEC.md"]), open_pull(2, ["SPEC.md", "lib/b.ex"]), open_pull(3, ["SPEC.md"])])

      # While TP-2's run works, TP-3 waits for it.
      run!(stepping, "running")
      tick!(pid)
      assert [%{issue_identifier: "TP-2"}] = watch(behind).facts.ahead

      run!(stepping, "completed")
      tick!(pid)

      assert %{rule: "R15", kind: :wait_for_competitors, outcome: :applied} = decision(stepping)
      assert_waits!(stepping, "Waiting on TP-1 and TP-3 to land: they change the same files (SPEC.md)", ["TP-1", "TP-3"])
      assert World.calls(:link) == [{"TP-1", stepping}, {"TP-3", stepping}]
      assert Enum.all?(watch(stepping).links, & &1.step_behind)
      assert moves(stepping) == ["CI Fix"]
      refute Enum.any?(watch(behind).facts.ahead, &(&1.issue_identifier == "TP-2"))

      tick!(pid)
      refute Enum.any?(watch(behind).facts.ahead, &(&1.issue_identifier == "TP-2"))
      refute match?(%{waits_for: %{issue_identifier: "TP-2"}}, watch(behind).landing)
      assert %{waits_for: %{issue_identifier: "TP-1"}} = watch(stepping).landing

      # Both land: the hold clears and the conflict count restarts.
      pr!("1", pr: :merged)
      pr!("3", pr: :merged)
      open_pulls!([open_pull(2, ["SPEC.md", "lib/b.ex"])])
      tick!(pid)

      refute Hold.held?(@repo_key, stepping, :blocked)
      assert World.calls(:unlink) == []
      assert %{rule: "R14", reason: "PR #2 conflicts with main: conflict fix run 1 of 3"} = decision(stepping)
      assert moves(stepping) == ["CI Fix", "CI Fix"]
    end

    test "a link that would close a cycle is not added: TP-1 is blocked by TP-2, so TP-2 doesn't wait on TP-1" do
      {pid, stepping} = exhausted!("2")
      blocked = ticket!("1", "In Progress", dirty())
      World.update(:issues, &Map.update!(&1, blocked, fn issue -> %{issue | blocked_by: [%{id: stepping, identifier: "TP-2", state: "Merging"}]} end))
      open_pulls!([open_pull(1, ["SPEC.md"]), open_pull(2, ["SPEC.md"])])
      tick!(pid)

      assert %{rule: "R15a"} = decision(stepping)
      assert watch(stepping).facts.competing == []
      assert World.calls(:link) == []
      assert List.last(moves(stepping)) == "Rework"
    end

    test "a competing PR without a ticket is named in the hold, with no Linear call, and the hold clears when it merges" do
      open_pulls!([open_pull(2, ["SPEC.md"]), open_pull(50, ["SPEC.md", "docs/a.md"], title: "Person change", head_sha: "p-1")])
      {pid, stepping} = exhausted!("2")
      tick!(pid)

      assert %{rule: "R15"} = decision(stepping)
      assert_waits!(stepping, "Waiting on PR #50 (Person change) to land: they change the same files (SPEC.md)", ["https://github.com/acme/app/pull/50"])
      assert World.calls(:link) == []
      assert [%{pr_number: 50, linked: false}] = watch(stepping).links

      # Its head moved: it is still racing two hours later.
      advance!(60 * 60 * 1000)
      open_pulls!([open_pull(2, ["SPEC.md"]), open_pull(50, ["SPEC.md"], title: "Person change", head_sha: "p-2")])
      tick!(pid)
      advance!(60 * 60 * 1000)
      tick!(pid)
      assert Hold.held?(@repo_key, stepping, :blocked)

      open_pulls!([open_pull(2, ["SPEC.md"])])
      tick!(pid)
      refute Hold.held?(@repo_key, stepping, :blocked)
      assert World.calls(:unlink) == []
      assert %{rule: "R14", reason: "PR #2 conflicts with main: conflict fix run 1 of 3"} = decision(stepping)
    end

    test "a competing PR without a ticket idle two hours leaves the race" do
      open_pulls!([open_pull(2, ["SPEC.md"]), open_pull(50, ["SPEC.md"], head_sha: "p-1")])
      {pid, stepping} = exhausted!("2")
      tick!(pid)
      assert Hold.held?(@repo_key, stepping, :blocked)

      advance!(2 * 60 * 60 * 1000)
      tick!(pid)
      refute Hold.held?(@repo_key, stepping, :blocked)
    end

    test "a forced ticket with a conflict and a competitor ahead goes to CI Fix, with no link" do
      ticket!("1", "QA", ci: :pending, mergeable: :blocked)
      forced = ticket!("2", "Merging", dirty())
      World.update(:issues, &Map.update!(&1, forced, fn issue -> %{issue | labels: ["expedite"]} end))
      open_pulls!([open_pull(1, ["SPEC.md"]), open_pull(2, ["SPEC.md"])])
      tick!(start!())

      assert %{rule: "R14"} = decision(forced)
      assert moves(forced) == ["CI Fix"]
      assert World.calls(:link) == []
      refute Hold.held?(@repo_key, forced, :blocked)
    end
  end

  describe "holds and phases (G7, G8)" do
    test "a ticket on a Needs Decision hold with a red head is not moved" do
      issue_id = ticket!("1", "Code Review", red())
      :ok = Hold.set(@repo_key, issue_id, :needs_decision, %{reason: "a question"}, tracker: Tracker)
      pid = start!()
      tick!(pid, 3)

      assert %{rule: "R4", owner: :person} = decision(issue_id)
      assert moves(issue_id) == []
      assert World.calls(:rerun) == []
    end

    test "a Rework ticket with a red head and no run goes to CI Fix" do
      issue_id = ticket!("1", "Rework", red())
      pid = start!()
      tick!(pid, 2)

      assert moves(issue_id) == ["CI Fix"]
      assert CiFix.origin(@repo_key, issue_id) == "Rework"
    end

    test "a ticket that left Merging with auto-merge on has it turned off (R3), once" do
      issue_id = ticket!("1", "QA", auto_merge: :armed)
      pid = start!()
      tick!(pid, 3)

      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
      assert Enum.any?(comments(issue_id), &(&1 =~ "because this ticket left Merging for QA"))
    end

    test "a repeated tick never repeats a move, a rerun, an update-branch or a fix-ticket filing" do
      red_id = ticket!("1", "Code Review", red())
      behind_id = ticket!("2", "Merging", mergeable: :behind)
      pid = start!()
      tick!(pid)
      seed_attempts!(red_id, %{red: 0})

      tick!(pid, 5)
      assert length(World.calls(:rerun)) == 1
      assert length(World.calls(:update_branch)) == 1
      assert moves(red_id) == ["CI Fix"]

      assert moves(behind_id) == []

      seed_attempts!(red_id, %{red: 10})
      tick!(pid, 4)
      assert length(World.calls(:fix_ticket)) == 1
    end
  end

  describe "each deleted deciding branch, and the rule that covers it now" do
    test "CiPoller.handle_ci_failure's first rerun of a red head → R22 rerun_failed, once per head" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid)
      assert %{rule: "R22"} = decision(issue_id)
      assert World.calls(:rerun) == ["77"]
      assert %{reruns: %{"head-1-1" => ["specs"]}} = attempts(issue_id)
    end

    test "CiPoller's rerun-pending mark → Attempts.rerun_pending?: a rerun whose checks left the rollup reads running (R24)" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid)

      pr!("1", ci: :green, failed_checks: [], check_names: [])
      tick!(pid)
      assert %{ci: :pending} = watch(issue_id).facts
      assert %{rule: "R24"} = decision(issue_id)
    end

    test "CiPoller.dispatch_ci_failure → R21 ci_fix: CI Fix with its origin, the failure kept for the run's prompt" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid, 2)
      assert %{ci_failure: %{commit_sha: "head-1-1", log_excerpt: "ERROR: specs failed at stub_test.exs:21\nstack"}} = watch(issue_id).fix
      assert PrWatch.pending_ci_failure(issue_id)[:commit_sha] == "head-1-1"
    end

    test "CiPoller.escalate_ci_failure (a question after max retries) → R20 file_fix_ticket, no Needs Decision hold" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid)
      seed_attempts!(issue_id, %{red: 10})
      tick!(pid)
      assert %{rule: "R20"} = decision(issue_id)
      refute Hold.held?(@repo_key, issue_id, :needs_decision)
    end

    test "CiPoller.back_from_ci_fix_on_red_head? → R21: a ticket back from CI Fix on the same red head goes to CI Fix again" do
      issue_id = ticket!("1", "Code Review", red())
      pid = start!()
      tick!(pid, 2)
      fix_run_returns!(issue_id, "1", "Code Review", "head-1-1", red())
      tick!(pid)
      assert moves(issue_id) == ["CI Fix", "CI Fix"]
      assert %{red: 2} = attempts(issue_id)
    end

    test "CiPoller.await_waiver: a protected paths check that only a person clears doesn't make the head red before Merging" do
      for {id, state, rule} <- [{"1", "Code Review", "R27"}, {"2", "QA", "R27"}, {"3", "Rework", "R26"}] do
        issue_id = ticket!(id, state, human_only(:green))
        pid = start!()
        tick!(pid, 3)
        assert %{rule: ^rule, kind: :dispatch} = decision(issue_id)
        assert PrWatch.dispatch_reason(Map.fetch!(World.get(:issues), issue_id), Config.settings!()) == nil
        refute Hold.held?(@repo_key, issue_id, :needs_decision)
        assert {issue_id, "CI green"} in World.calls(:label)
        assert %{facts: %{ci: :green, failing_check: "protected paths"}} = watch(issue_id)
        assert moves(issue_id) == []
        stop_supervised!({Repo, @repo_key})
      end

      assert World.calls(:rerun) == []
    end

    test "a protected paths check that only a person clears, with another check still running → R24: the reviewer waits for it" do
      issue_id = ticket!("1", "Code Review", human_only(:pending))
      pid = start!()
      tick!(pid)
      assert %{rule: "R24", kind: :wait} = decision(issue_id)
      assert {issue_id, "CI running"} in World.calls(:label)

      pr!("1", past_human_only: :green)
      tick!(pid)
      assert %{rule: "R27", kind: :dispatch} = decision(issue_id)
    end

    test "a CI Fix head left red only by a protected paths check → R25: back to its origin" do
      issue_id = ticket!("1", "CI Fix", human_only(:green))
      :ok = CiFix.record_origin(@repo_key, issue_id, "Code Review")
      pid = start!()
      tick!(pid)
      assert moves(issue_id) == ["Code Review"]
      refute Hold.held?(@repo_key, issue_id, :needs_decision)
    end

    test "R18's evidence: a head red only on protected paths lists the protected files its PR changes, read once per head, in every phase" do
      for {id, state} <- [{"1", "Code Review"}, {"2", "QA"}, {"3", "Rework"}, {"4", "CI Fix"}, {"5", "Merging"}] do
        issue_id = ticket!(id, state, human_only(:green))
        if state == "CI Fix", do: :ok = CiFix.record_origin(@repo_key, issue_id, "Code Review")
        workspace = workspace!(issue_id)
        pid = start!(git: changes_workflow_md())
        tick!(pid, 2)

        assert watch(issue_id).protected_files == %{head_sha: "head-#{id}-1", paths: ["WORKFLOW.md"]}
        assert %{facts: %{protected_files: ["WORKFLOW.md"]}} = @repo_key |> RunStore.get_ticket_state(issue_id) |> WatchPayload.watch()
        # In Merging R18 asks too, and reads once the protected-list entries its Allow option unlocks.
        assert diffs(workspace) == if(state == "Merging", do: 2, else: 1)
        stop_supervised!({Repo, @repo_key})
      end
    end

    test "R18's evidence is read again on a new head, and a read that fails lists none and says why, once" do
      issue_id = ticket!("1", "Code Review", human_only(:green))
      workspace = workspace!(issue_id)
      pid = start!(git: changes_workflow_md())
      tick!(pid)
      pr!("1", head_sha: "head-1-2")
      tick!(pid, 2)
      assert watch(issue_id).protected_files == %{head_sha: "head-1-2", paths: ["WORKFLOW.md"]}
      assert diffs(workspace) == 2

      # A green head lists none.
      pr!("1", head_sha: "head-1-3", ci: :green, red_kind: :failure, failing_check: nil, failed_checks: [])
      tick!(pid)
      assert watch(issue_id).protected_files == nil

      # The ticket's runs had no workspace: the read fails.
      stop_supervised!({Repo, @repo_key})
      issue_id = ticket!("2", "QA", human_only(:green))
      pid = start!(git: changes_workflow_md())
      log = capture_log(fn -> tick!(pid) end)
      assert log =~ "PR watch couldn't read the protected files a PR changes issue_id=#{issue_id} issue_identifier=TP-2 head_sha=head-2-1: the ticket has no workspace"
      assert watch(issue_id).protected_files == %{head_sha: "head-2-1", paths: []}
      refute capture_log(fn -> tick!(pid) end) =~ "couldn't read the protected files"
    end

    test "AutoMerge's protected paths gate → R18 in Merging: auto-merge off and a person asked, once" do
      issue_id =
        ticket!("1", "Merging",
          ci: :red,
          red_kind: :human_only,
          past_human_only: :green,
          auto_merge: :armed,
          failing_check: "protected paths",
          failed_checks: [%{name: "protected paths", run_id: "5"}]
        )

      workspace!(issue_id)
      pid = start!(git: protected_git(["WORKFLOW.md"]))
      tick!(pid, 3)
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
      assert %{decision: %{title: "Protected files changed on TP-1", options: options}} = Hold.get(@repo_key, issue_id, :needs_decision)
      assert Enum.map(options, & &1.label) == ["Allow the change", "Drop the change in Rework"]
      assert [%{unlocks: ["WORKFLOW.md"]}, drop] = options
      refute Map.has_key?(drop, :unlocks)
      assert [_one] = Enum.filter(comments(issue_id), &String.starts_with?(&1, "## Decision needed: Protected files"))
      assert moves(issue_id) == []
      # The check holds the merge back, yet the head's other checks passed: the label stays green.
      assert {issue_id, "CI green"} in World.calls(:label)
      refute {issue_id, "CI red"} in World.calls(:label)
    end

    test "R18 in Merging: picking Allow grants the PR's protected paths, and the head then reads as green to land" do
      issue_id =
        ticket!("1", "Merging",
          ci: :red,
          red_kind: :human_only,
          past_human_only: :green,
          failing_check: "protected paths",
          failed_checks: [%{name: "protected paths", run_id: "5"}]
        )

      workspace!(issue_id)
      pid = start!(git: protected_git(["WORKFLOW.md"]))
      tick!(pid)

      assert %{decision: decision} = Hold.get(@repo_key, issue_id, :needs_decision)
      unlocks = SymphonyElixir.PathUnlock.picked_paths(decision, ["Allow the change"])
      assert unlocks == ["WORKFLOW.md"]

      # The person picks Allow: the answer is recorded with its paths, and the hold clears.
      picked = SymphonyElixir.Decisions.entry("request-1", ~D[2026-10-20], decision.title, decision.question, "Allow the change", unlocks)
      {:ok, description} = SymphonyElixir.Decisions.put("Ship it.", [picked])
      World.update(:issues, &Map.update!(&1, issue_id, fn issue -> %{issue | description: description} end))
      :ok = Hold.clear(@repo_key, issue_id, :needs_decision, tracker: Tracker)

      pr!("1", head_sha: "head-1-2")
      tick!(pid)

      assert %{ci: :green} = watch(issue_id).facts
      refute Hold.held?(@repo_key, issue_id, :needs_decision)
      assert [_one] = Enum.filter(comments(issue_id), &String.starts_with?(&1, "## Decision needed: Protected files"))
    end

    test "R18 waits to ask until the protected paths the PR changes can be read" do
      issue_id =
        ticket!("1", "Merging",
          ci: :red,
          red_kind: :human_only,
          past_human_only: :green,
          failing_check: "protected paths",
          failed_checks: [%{name: "protected paths", run_id: "5"}]
        )

      pid = start!()
      capture_log(fn -> tick!(pid, 2) end)

      refute Hold.held?(@repo_key, issue_id, :needs_decision)
      assert Enum.filter(comments(issue_id), &String.starts_with?(&1, "## Decision needed: Protected files")) == []
    end

    test "CiPoller/PrReviewPoller parked_for_person → R4: a held ticket waits, whatever its PR" do
      issue_id = ticket!("1", "QA", dirty())
      :ok = Hold.set(@repo_key, issue_id, :blocked, %{reason: "waiting"}, tracker: Tracker)
      pid = start!()
      tick!(pid)
      assert %{rule: "R4", owner: :symphony} = decision(issue_id)
      assert moves(issue_id) == []
    end

    test "CiPoller.mark_ci_green → Attempts reset: a green, conflict-free head clears the counts and its failure" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid, 2)
      fix_run_returns!(issue_id, "1", "QA", "head-1-2", ci: :green, failed_checks: [])
      tick!(pid)
      assert %{red: 0} = attempts(issue_id)
      assert watch(issue_id).fix == %{ci_failure: nil, pr_conflict: nil}
    end

    test "CiPoller.hold_auto_merge_for_fix → R21 in Merging: auto-merge off before CI Fix" do
      issue_id = ticket!("1", "Merging", red() ++ [auto_merge: :armed])
      pid = start!()
      tick!(pid, 2)
      assert [{:disarm, _url}, {:move, {^issue_id, "CI Fix"}}] = Enum.filter(World.all_calls(), &(elem(&1, 0) in [:disarm, :move]))
    end

    test "CiPoller.track_landing_wait (land past pending checks after 15 minutes) → R30: auto-merge lands it" do
      issue_id = ticket!("1", "Merging", ci: :pending, mergeable: :unstable)
      pid = start!()
      tick!(pid)
      assert %{rule: "R30", kind: :arm} = decision(issue_id)
    end

    test "CiPoller.rework_in_progress? and PrReviewPoller's active-run check → R9: nothing while a run works on the ticket" do
      issue_id = ticket!("1", "QA", red())
      run!(issue_id, "running")
      pid = start!()
      tick!(pid, 2)
      assert %{rule: "R9"} = decision(issue_id)
      assert World.calls(:rerun) == []
    end

    test "PrReviewPoller.maybe_transition_conflict → R14 ci_fix: a conflict goes to CI Fix with its context" do
      issue_id = ticket!("1", "Code Review", dirty())
      pid = start!()
      tick!(pid)
      assert moves(issue_id) == ["CI Fix"]
      assert %{conflict_key: "head-1-1|base-1", retry_count: 1, approved: false} = PrWatch.pending_pr_conflict(issue_id)
    end

    test "PrReviewPoller.back_from_ci_fix_on_conflict? → R14: back from CI Fix on the same conflict, it goes to CI Fix again" do
      issue_id = ticket!("1", "QA", dirty())
      pid = start!()
      tick!(pid)
      fix_run_returns!(issue_id, "1", "QA", "head-1-1", dirty())
      tick!(pid)
      assert moves(issue_id) == ["CI Fix", "CI Fix"]
    end

    test "PrReviewPoller.escalate_conflict and its silent `conflict_escalated` record (G3) → R15a to_rework" do
      issue_id = ticket!("1", "QA", dirty())
      pid = start!()
      tick!(pid)
      fix_run_returns!(issue_id, "1", "QA", "head-1-2", dirty())
      seed_attempts!(issue_id, %{conflict: 3})
      tick!(pid)
      assert List.last(moves(issue_id)) == "Rework"
      refute Hold.held?(@repo_key, issue_id, :needs_decision)
    end

    test "PrReviewPoller.wait_to_land and AutoMerge's landing-order check → R14a and R28: wait for the PR ahead" do
      ticket!("1", "Merging", ci: :pending, mergeable: :blocked)
      follower = ticket!("2", "QA", dirty())
      World.update(:open_pulls, fn _ -> [%{number: 1, head_sha: "head-1-1", files: ["x"]}, %{number: 2, head_sha: "head-2-1", files: ["x"]}] end)
      pid = start!()
      tick!(pid)
      assert %{rule: "R14a"} = decision(follower)
      tick!(pid)
      assert %{rule: "R4", reason: "Waiting on TP-1 to land" <> _} = decision(follower)
      assert moves(follower) == []
    end

    test "PrReviewPoller.turn_off_auto_merge_on_exit → R3 disarm" do
      issue_id = ticket!("1", "Rework", auto_merge: :armed, ci: :pending)
      pid = start!()
      tick!(pid)
      assert %{rule: "R3"} = decision(issue_id)
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
    end

    test "PrReviewPoller.finish_merged's move to Done → R2 close_out" do
      issue_id = ticket!("1", "Merging", pr: :merged)
      pid = start!()
      tick!(pid, 2)
      assert moves(issue_id) == ["Done"]
    end

    test "AutoMerge.step's merge_if_ready and refused-merge path → R29 merge_now" do
      issue_id = ticket!("1", "Merging", mergeable: :unstable)
      pid = start!()
      tick!(pid)
      assert %{rule: "R29"} = decision(issue_id)
    end

    test "AutoMerge.step's enable once per head → R30 arm, once per head and stay" do
      issue_id = ticket!("1", "Merging", ci: :pending, mergeable: :clean)
      pid = start!()
      tick!(pid, 3)
      assert World.calls(:arm) == [{"https://github.com/acme/app/pull/1", "head-1-1"}]
      assert %{rule: "R32"} = decision(issue_id)
    end

    test "AutoMerge's head-moved retries → an error leaves the record re-decidable on the next tick" do
      issue_id = ticket!("1", "Merging", ci: :pending, mergeable: :clean)
      Process.put(:never, :used)

      defmodule MovingGitHub do
        alias SymphonyElixir.PrWatch.SwitchTest.{GitHub, World}
        defdelegate list_open_pull_requests(url, opts), to: GitHub

        def enable_auto_merge(_url, request, _opts) do
          World.call(:arm_attempt, request.head_sha)
          {:error, :head_moved}
        end
      end

      pid = start!(github: MovingGitHub)
      capture_log(fn -> tick!(pid, 2) end)
      assert World.calls(:arm_attempt) == ["head-1-1", "head-1-1"]
      assert %{rule: "R30", outcome: :error, error: ":head_moved"} = decision(issue_id)
      assert watch(issue_id).applied == []
    end

    test "AutoMerge.check_stalled and owns_issue? → R31 land_agent and the orchestrator's gate read from the decision" do
      issue_id = ticket!("1", "Merging", mergeable: :blocked)
      pid = start!()
      tick!(pid)
      issue = Map.fetch!(World.get(:issues), issue_id)
      assert PrWatch.dispatch_reason(issue, Config.settings!()) =~ "the PR watcher (R30)"
    end

    test "AutoMerge's held?/conflict? stopgaps (TP-896, TP-921) → R30 needs a conflict-free head: no re-arm while dirty" do
      issue_id = ticket!("1", "Merging", dirty())
      run!(issue_id, "running")
      pid = start!()
      tick!(pid, 5)
      assert World.calls(:arm) == []
    end

    test "the orchestrator's 'waits for its head to go green' gate → R27: a Code Review run on a green head only" do
      issue_id = ticket!("1", "Code Review", ci: :pending)
      pid = start!()
      tick!(pid)
      issue = Map.fetch!(World.get(:issues), issue_id)
      assert PrWatch.dispatch_reason(issue, Config.settings!()) =~ "the PR watcher (R24): Checks are running"

      pr!("1", ci: :green)
      tick!(pid)
      assert PrWatch.dispatch_reason(issue, Config.settings!()) == nil
    end

    test "a CI Fix ticket left in the lane on a green, conflict-free head → R25 return_to_origin" do
      issue_id = ticket!("1", "CI Fix")
      :ok = CiFix.record_origin(@repo_key, issue_id, "QA")
      pid = start!()
      tick!(pid)
      assert moves(issue_id) == ["QA"]
      assert CiFix.origin(@repo_key, issue_id) == nil
    end

    test "a ticket in CI Fix that entered it for its red head spends no second attempt on the run already sent" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid, 2)
      assert state(issue_id) == "CI Fix"
      tick!(pid, 2)
      assert %{red: 1} = attempts(issue_id)

      # A new red head the run pushed while the ticket stayed in the lane is another fix run, once
      # its rerun failed too.
      pr!("1", head_sha: "head-1-2")
      tick!(pid, 2)
      assert %{red: 2, sent: %{head_sha: "head-1-2", cause: :red}} = attempts(issue_id)
      assert moves(issue_id) == ["CI Fix"]
    end

    test "a cancel of the replaced head's runs that finds none, or fails, is only logged" do
      for {result, logged} <- [{{:ok, []}, nil}, {{:error, :forbidden}, "could not cancel the CI runs on head-1-1"}] do
        World.update(:cancel_result, fn _ -> result end)
        issue_id = ticket!("1", "Merging", mergeable: :behind, head_sha: "head-1-1")
        pid = start!()
        tick!(pid)

        pr!("1", head_sha: "head-1-2")
        log = capture_log(fn -> tick!(pid) end)
        if logged, do: assert(log =~ logged), else: refute(log =~ "cancel")
        assert %{updated_from: "head-1-2"} = attempts(issue_id)
        stop_supervised!({Repo, @repo_key})
      end
    end

    test "AutoMerge's protected paths gate with a decision covering the paths → R29: the head lands as if green" do
      issue_id =
        ticket!("1", "Merging",
          ci: :red,
          red_kind: :human_only,
          past_human_only: :green,
          mergeable: :unstable,
          failing_check: "protected paths",
          failed_checks: [%{name: "protected paths", run_id: "5"}]
        )

      ruling = SymphonyElixir.Decisions.entry("ruling-c1", ~D[2026-10-16], nil, nil, "Unlock WORKFLOW.md for TP-1")
      World.update(:issues, &Map.update!(&1, issue_id, fn issue -> %{issue | rulings: [ruling]} end))

      # The ticket's newest run with a workspace is where the changed paths are read.
      workspace = Path.join(System.tmp_dir!(), "switch-ws-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)
      :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "run-old", issue_id: issue_id, status: "success", workspace_path: "/tmp/old"})

      :ok =
        RunStore.put_run(%{
          repo_key: @repo_key,
          run_id: "run-new",
          issue_id: issue_id,
          status: "success",
          started_at: now(),
          workspace_path: workspace
        })

      test_pid = self()

      # Every commit is there and the PR changes no protected path but the unlocked one.
      git = fn args, cwd ->
        send(test_pid, {:git, args, cwd})
        {"", 0}
      end

      pid = start!(git: git)
      tick!(pid)

      assert %{ci: :green} = watch(issue_id).facts
      assert %{rule: "R29", kind: :merge_now} = decision(issue_id)
      assert_received {:git, _args, ^workspace}
      refute Hold.held?(@repo_key, issue_id, :needs_decision)
    end

    test "Attempts is the watcher's own: a ticket that left the watched phases starts again" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid)
      move!(issue_id, "Todo")
      tick!(pid)
      assert watch(issue_id) == nil
      assert Attempts.normalize(nil) == Attempts.new()
    end
  end
end
